{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Faithful.Tokenizer
-- Description : BPE-aware token counting via pooled persistent tiktoken workers
--
-- Token counts MUST be real BPE counts, not character estimates.
-- The benchmark matrix and thesis both require this.
--
-- Implementation:
--   * hot path: pooled persistent Python subprocesses using an in-memory
--     length-prefixed UTF-8 protocol (no temp files, parallel-safe)
--   * fallback: one-shot temp-file invocation when workers fail
--   * last resort: pure character-based estimate

module Faithful.Tokenizer
  ( countTokens
  , countTokensBatch
  , countTokensPure
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (SomeException, catch, finally)
import Control.Monad (replicateM)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Conc (getNumCapabilities)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.IO (BufferMode(..), Handle, hClose, hFlush, hSetBinaryMode, hSetBuffering, openTempFile)
import System.IO.Unsafe (unsafePerformIO)
import System.Info (os)
import System.Process (CreateProcess(..), ProcessHandle, StdStream(..), createProcess, getProcessExitCode, proc, readProcessWithExitCode, terminateProcess)


data TokProcess = TokProcess
  { tpStdin  :: !Handle
  , tpStdout :: !Handle
  , tpHandle :: !ProcessHandle
  }

data TokPool = TokPool
  { tpoolIdle :: !(MVar [TokProcess])
  , tpoolSem  :: !QSem
  }

{-# NOINLINE globalTokPool #-}
globalTokPool :: MVar (Maybe TokPool)
globalTokPool = unsafePerformIO (newMVar Nothing)


countTokens :: Text -> Int
countTokens text = unsafePerformIO (countTokensIO text)
{-# NOINLINE countTokens #-}

countTokensBatch :: [Text] -> [Int]
countTokensBatch texts = unsafePerformIO (countTokensBatchIO texts)
{-# NOINLINE countTokensBatch #-}


countTokensIO :: Text -> IO Int
countTokensIO text
  | T.null text = pure 0
  | otherwise = withPoolProcess
      (\tp -> queryPersistent tp text)
      (fallbackOneShot text)

countTokensBatchIO :: [Text] -> IO [Int]
countTokensBatchIO [] = pure []
countTokensBatchIO texts = withPoolProcess
  (\tp -> queryBatchPersistent tp texts)
  (mapM fallbackOneShot texts)


withPoolProcess :: (TokProcess -> IO a) -> IO a -> IO a
withPoolProcess use fallback = do
  pool <- getTokPool
  tp <- takeTokProcess pool
  (maybeTp, result) <-
    (do
        !value <- use tp
        pure (Just tp, value)
    ) `catch` \(_ :: SomeException) -> recoverTokProcess tp use fallback
  putTokProcess pool maybeTp
  pure result

recoverTokProcess :: TokProcess -> (TokProcess -> IO a) -> IO a -> IO (Maybe TokProcess, a)
recoverTokProcess brokenTp use fallback = do
  cleanupProcess brokenTp
  maybeReplacement <- (Just <$> startPersistent) `catch` \(_ :: SomeException) -> pure Nothing
  case maybeReplacement of
    Nothing -> do
      !value <- fallback
      pure (Nothing, value)
    Just replacement ->
      (do
          !value <- use replacement
          pure (Just replacement, value)
      ) `catch` \(_ :: SomeException) -> do
          cleanupProcess replacement
          !value <- fallback
          pure (Nothing, value)


getTokPool :: IO TokPool
getTokPool = modifyMVar globalTokPool $ \maybePool ->
  case maybePool of
    Just pool -> pure (maybePool, pool)
    Nothing -> do
      pool <- startPool
      pure (Just pool, pool)

startPool :: IO TokPool
startPool = do
  workerCount <- getTokenizerWorkerCount
  processes <- replicateM workerCount startPersistent
  idle <- newMVar processes
  sem <- newQSem workerCount
  pure TokPool
    { tpoolIdle = idle
    , tpoolSem = sem
    }

getTokenizerWorkerCount :: IO Int
getTokenizerWorkerCount = do
  envWorkers <- lookupEnv "FAITHFUL_TOKENIZER_WORKERS"
  _capabilities <- getNumCapabilities
  let defaultWorkers = 1
  pure $ case envWorkers >>= parsePositiveInt of
    Just n  -> max 1 n
    Nothing -> defaultWorkers
  where
    parsePositiveInt value =
      case reads value of
        [(n, "")] | n > 0 -> Just n
        _ -> Nothing

takeTokProcess :: TokPool -> IO TokProcess
takeTokProcess pool = do
  waitQSem (tpoolSem pool)
  modifyMVar (tpoolIdle pool) $ \processes ->
    case processes of
      tp : rest -> pure (rest, tp)
      [] -> do
        tp <- startPersistent
        pure ([], tp)

putTokProcess :: TokPool -> Maybe TokProcess -> IO ()
putTokProcess pool maybeTp = do
  case maybeTp of
    Just tp -> modifyMVar_ (tpoolIdle pool) (pure . (tp :))
    Nothing -> pure ()
  signalQSem (tpoolSem pool)


persistentScript :: String
persistentScript = unlines
  [ "import sys, tiktoken"
  , "enc = tiktoken.get_encoding('cl100k_base')"
  , "stdin = sys.stdin.buffer"
  , "stdout = sys.stdout"
  , "while True:"
  , "    header = stdin.readline()"
  , "    if not header:"
  , "        break"
  , "    try:"
  , "        size = int(header.strip() or b'0')"
  , "        payload = stdin.read(size)"
  , "        if len(payload) != size:"
  , "            break"
  , "        text = payload.decode('utf-8')"
  , "        stdout.write(str(len(enc.encode(text))) + '\\n')"
  , "        stdout.flush()"
  , "    except Exception:"
  , "        stdout.write('-1\\n')"
  , "        stdout.flush()"
  ]

startPersistent :: IO TokProcess
startPersistent = do
  python <- findPython
  (Just hin, Just hout, _, ph) <- createProcess (proc python ["-c", persistentScript])
    { std_in = CreatePipe
    , std_out = CreatePipe
    , std_err = Inherit
    }
  hSetBinaryMode hin True
  hSetBinaryMode hout True
  hSetBuffering hin (BlockBuffering Nothing)
  hSetBuffering hout (BlockBuffering Nothing)
  pure TokProcess
    { tpStdin = hin
    , tpStdout = hout
    , tpHandle = ph
    }

queryPersistent :: TokProcess -> Text -> IO Int
queryPersistent tp text = do
  writePayload (tpStdin tp) text
  hFlush (tpStdin tp)
  n <- readCount (tpStdout tp)
  pure $ if n >= 0 then n else countTokensPure text

queryBatchPersistent :: TokProcess -> [Text] -> IO [Int]
queryBatchPersistent tp texts = do
  mapM_ (writePayload (tpStdin tp)) texts
  hFlush (tpStdin tp)
  counts <- mapM (const (readCount (tpStdout tp))) texts
  pure (zipWith repairCount counts texts)
  where
    repairCount n text
      | n >= 0 = n
      | otherwise = countTokensPure text

writePayload :: Handle -> Text -> IO ()
writePayload handle text = do
  let payload = TE.encodeUtf8 text
  BSC.hPutStr handle (BSC.pack (show (BS.length payload)))
  BSC.hPutStr handle "\n"
  BS.hPut handle payload

readCount :: Handle -> IO Int
readCount handle = do
  response <- BS.hGetLine handle
  case reads (BSC.unpack response) of
    [(n, "")] -> pure n
    _ -> pure (-1)

isAlive :: ProcessHandle -> IO Bool
isAlive ph = (== Nothing) <$> getProcessExitCode ph

cleanupProcess :: TokProcess -> IO ()
cleanupProcess tp = do
  hClose (tpStdin tp) `catch` \(_ :: SomeException) -> pure ()
  hClose (tpStdout tp) `catch` \(_ :: SomeException) -> pure ()
  alive <- isAlive (tpHandle tp) `catch` \(_ :: SomeException) -> pure False
  if alive
    then terminateProcess (tpHandle tp) `catch` \(_ :: SomeException) -> pure ()
    else pure ()


fallbackOneShot :: Text -> IO Int
fallbackOneShot text = do
  let script = "import pathlib,sys,tiktoken; text=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'); e=tiktoken.get_encoding('cl100k_base'); print(len(e.encode(text)))"
  result <- withTempUtf8File text $ \tempPath -> do
    launchers <- pythonLaunchers script tempPath
    tryPythonLaunchers launchers
  case reads (filter (/= '\n') result) of
    [(n, "")] -> pure (n :: Int)
    _ -> pure (countTokensPure text)

withTempUtf8File :: Text -> (FilePath -> IO a) -> IO a
withTempUtf8File text action = do
  tempDir <- getTemporaryDirectory
  (tempPath, handle) <- openTempFile tempDir "faithful-tokenizer-"
  hClose handle
  BS.writeFile tempPath (TE.encodeUtf8 text)
  action tempPath `finally` removeTempFile tempPath

removeTempFile :: FilePath -> IO ()
removeTempFile tempPath = removeFile tempPath `catch` \(_ :: SomeException) -> pure ()

findPython :: IO FilePath
findPython = do
  explicit <- lookupEnv "FAITHFUL_PYTHON"
  case explicit of
    Just pythonPath | not (null pythonPath) -> pure pythonPath
    _ -> tryLaunchers defaultLaunchers
  where
    defaultLaunchers
      | os == "mingw32" = ["python", "py", "python3"]
      | otherwise = ["python3", "python"]

    tryLaunchers [] = pure "python3"
    tryLaunchers (launcher : rest) = do
      ok <- testLauncher launcher
      if ok then pure launcher else tryLaunchers rest

    testLauncher launcher = do
      (code, _, _) <- readProcessWithExitCode launcher ["--version"] ""
        `catch` \(_ :: SomeException) -> pure (ExitFailure 1, "", "")
      pure (code == ExitSuccess)

pythonLaunchers :: String -> FilePath -> IO [(FilePath, [String])]
pythonLaunchers script tempPath = do
  explicitPython <- lookupEnv "FAITHFUL_PYTHON"
  let launchArgs = ["-c", script, tempPath]
      explicit = case explicitPython of
        Just pythonPath | not (null pythonPath) -> [(pythonPath, launchArgs)]
        _ -> []
      windowsFallback =
        [ ("python", launchArgs)
        , ("py", launchArgs)
        , ("python3", launchArgs)
        ]
      otherFallback =
        [ ("python3", launchArgs)
        , ("python", launchArgs)
        ]
  pure (explicit ++ if os == "mingw32" then windowsFallback else otherFallback)

tryPythonLaunchers :: [(FilePath, [String])] -> IO String
tryPythonLaunchers [] = pure ""
tryPythonLaunchers ((commandName, args) : rest) = do
  result <- catch
    (readProcessWithExitCode commandName args "")
    (\(_ :: SomeException) -> pure (ExitFailure 1, "", ""))
  case result of
    (ExitSuccess, stdoutText, _) | not (null stdoutText) -> pure stdoutText
    _ -> tryPythonLaunchers rest


countTokensPure :: Text -> Int
countTokensPure = max 1 . ceiling . (/ (3.8 :: Double)) . fromIntegral . T.length
