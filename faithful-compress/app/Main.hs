{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

-- |
-- CLI for faithful-compress.
-- Supports two modes needed for the Decision Gate:
--   compress   — compress a JSONL dataset with a named strategy
--   anchors    — show extracted anchors for inspection
--
-- Compile with -threaded -rtsopts and run with +RTS -N for parallel
-- document compression. Documents are processed concurrently (IO-bound
-- on the tiktoken subprocess), while anchor extraction within each
-- document uses spark-based parallelism via Control.Parallel.Strategies.

module Main where

import Faithful.Core
import Faithful.Anchor
import Faithful.Strategy
import Faithful.Tokenizer (countTokens, countTokensBatch)

import Control.Concurrent.Async (mapConcurrently)
import Data.Aeson ((.:), (.:?), (.!=), FromJSON(..), eitherDecodeStrict', withObject)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum)
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import GHC.Conc (getNumCapabilities)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout)
import GHC.IO.Encoding (utf8)


data InputTurn = InputTurn
  { inputDocId   :: Text
  , inputRole    :: Text
  , inputContent :: Text
  }

instance FromJSON InputTurn where
  parseJSON = withObject "InputTurn" $ \obj -> do
    inputDocId <- obj .: "id"
    inputRole <- obj .:? "role" .!= "document"
    inputContent <- obj .: "content"
    pure (InputTurn inputDocId inputRole inputContent)

data InputDocument = InputDocument
  { docId   :: Text
  , docTurns :: [InputTurn]
  }

data InputSource
  = JsonlDocuments [InputDocument]
  | PlainTexts [Text]


main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- getArgs
  case args of
    ["compress", "--strategy", stratName, "--input", inputFile, "--output", outputDir] ->
      runCompress stratName inputFile outputDir
    ["anchors", "--input", inputFile] ->
      runAnchors inputFile
    ["help"] -> printUsage
    _ -> printUsage >> exitFailure


printUsage :: IO ()
printUsage = do
  hPutStrLn stderr "Usage:"
  hPutStrLn stderr "  faithful-compress-cli compress --strategy <name> --input <file> --output <dir>"
  hPutStrLn stderr "  faithful-compress-cli anchors --input <file>"
  hPutStrLn stderr ""
  hPutStrLn stderr "Input can be either:"
  hPutStrLn stderr "  - JSONL with fields id, role, content"
  hPutStrLn stderr "  - plain text (one document per non-empty line)"
  hPutStrLn stderr ""
  hPutStrLn stderr "Strategies: identity, anchors-only, no-anchors, light-filler, tail-rescue-static"


lookupStrategy :: String -> Maybe Strategy
lookupStrategy "identity"      = Just identity
lookupStrategy "anchors-only"  = Just anchorsOnly
lookupStrategy "no-anchors"    = Just noAnchors
lookupStrategy "light-filler"  = Just lightFiller
lookupStrategy "tail-rescue-static" = Just tailRescueStatic
lookupStrategy _               = Nothing


runCompress :: String -> FilePath -> FilePath -> IO ()
runCompress stratName inputFile outputDir = do
  case lookupStrategy stratName of
    Nothing -> do
      hPutStrLn stderr $ "Unknown strategy: " ++ stratName
      exitFailure
    Just strat -> do
      inputSource <- loadInputSource inputFile
      createDirectoryIfMissing True outputDir
      caps <- getNumCapabilities
      case inputSource of
        JsonlDocuments docs
          | caps > 1 -> do
              -- Parallel document compression: each doc on its own thread.
              -- Anchor extraction within each doc also parallelises via parMap sparks.
              hPutStrLn stderr $ "Compressing " ++ show (length docs) ++ " documents on " ++ show caps ++ " capabilities"
              _ <- mapConcurrently (writeCompressedDocument strat stratName outputDir) docs
              pure ()
          | otherwise ->
              mapM_ (writeCompressedDocument strat stratName outputDir) docs
        PlainTexts texts ->
          mapM_ (uncurry (writeCompressedPlainText strat stratName outputDir)) (zip [(1 :: Int)..] texts)


runAnchors :: FilePath -> IO ()
runAnchors inputFile = do
  inputSource <- loadInputSource inputFile
  case inputSource of
    JsonlDocuments docs -> mapM_ printDocumentAnchors docs
    PlainTexts texts -> do
      let content = T.intercalate "\n" texts
          memories = classify content
          anchors = [a | Exact a <- toList memories]
      TIO.putStrLn $ T.concat ["Total anchors: ", T.pack (show (length anchors))]
      mapM_ (\a -> TIO.putStrLn $ T.concat
        [ "  [", T.pack (show (anchorType a)), "] "
        , anchorText a
        ]) anchors


loadInputSource :: FilePath -> IO InputSource
loadInputSource inputFile = do
  content <- BS.readFile inputFile
  let textLines = filter (not . T.null . T.strip) (T.lines (TE.decodeUtf8 content))
  if null textLines
    then pure (PlainTexts [])
    else case traverse parseJsonlTurn textLines of
      Right turns -> pure (JsonlDocuments (groupTurns turns))
      Left _ -> pure (PlainTexts textLines)

parseJsonlTurn :: Text -> Either String InputTurn
parseJsonlTurn = eitherDecodeStrict' . TE.encodeUtf8

groupTurns :: [InputTurn] -> [InputDocument]
groupTurns turns =
  let (orderRev, grouped) = foldl' step ([], Map.empty) turns
  in [ InputDocument key (reverse (Map.findWithDefault [] key grouped))
     | key <- reverse orderRev
     ]
  where
    step (orderRev, grouped) turn =
      let key = inputDocId turn
          seen = Map.member key grouped
          grouped' = Map.insertWith (++) key [turn] grouped
          orderRev' = if seen then orderRev else key : orderRev
      in (orderRev', grouped')

writeCompressedDocument :: Strategy -> String -> FilePath -> InputDocument -> IO ()
writeCompressedDocument strat stratName outputDir doc = do
  let original = renderDocumentOriginal doc
      !rendered =
        if stratName == "tail-rescue-static"
        then compressWholeDocumentChunked strat doc
        else T.intercalate "\n\n" (map (compressRenderedTurn strat) (docTurns doc))
      -- Batch token counting: count original + compressed in one burst
      batchCounts = countTokensBatch [original, rendered]
      (!origTok, !compTok) = case batchCounts of
        [origCount, compCount] -> (origCount, compCount)
        _ -> (countTokens original, countTokens rendered)
      !ratio = reductionPercent origTok compTok
      fileName = outputFileStem (docId doc) ++ "." ++ stratName ++ ".txt"
      outFile = outputDir </> fileName
  TIO.putStrLn $ T.concat
    [ "doc=", docId doc
    , " orig=", T.pack (show origTok)
    , " comp=", T.pack (show compTok)
    , " reduction=", T.pack (show (round ratio :: Int)), "%"
    ]
  BS.writeFile outFile (TE.encodeUtf8 rendered)

compressWholeDocument :: Strategy -> InputDocument -> Text
compressWholeDocument strat doc =
  let chunk = textToChunk (docId doc) Document (renderDocumentOriginal doc)
      (_, rendered) = compressChunk strat chunk
  in rendered

-- | Compress per-turn for large documents, whole-document for small ones.
-- For huge turns (>15K chars), uses the windowed path in Strategy directly
-- by creating a lightweight chunk that defers classification to the windows.
compressWholeDocumentChunked :: Strategy -> InputDocument -> Text
compressWholeDocumentChunked strat doc
  | T.length fullText > 30000 =
      T.intercalate "\n\n" (map (compressLargeTurn strat) (docTurns doc))
  | otherwise = compressWholeDocument strat doc
  where
    fullText = renderDocumentOriginal doc

-- | Compress a single turn that may be very large.  For turns >15K chars,
-- creates a "shell" chunk with empty memory so that keepTailAndRescueWindowed
-- can handle classification per-window instead of up front.
compressLargeTurn :: Strategy -> InputTurn -> Text
compressLargeTurn strat turn =
  let content = inputContent turn
      role    = parseContextRole (inputRole turn)
      roleLabel = "[" <> T.toUpper (inputRole turn) <> "]"
  in if T.length content > 15000
     then
       -- Build a shell chunk with empty memory; keepTailAndRescueWindowed
       -- will call classify on each ~10K window instead of the whole text.
       let shell = Chunk
             { chunkId       = inputDocId turn
             , chunkRole     = role
             , chunkContent  = content
             , chunkMemory   = Seq.empty  -- windowed path reclassifies per window
             , chunkAge      = Nothing
             , chunkPriority = PMedium
             , chunkTokens   = 0
             }
           (_, rendered) = compressChunk strat shell
       in if T.null (T.strip rendered) then roleLabel
          else roleLabel <> "\n" <> rendered
     else
       -- Normal path for small turns
       let chunk = textToChunkFast (inputDocId turn) role content
           (_, rendered) = compressChunk strat chunk
       in if T.null (T.strip rendered) then roleLabel
          else roleLabel <> "\n" <> rendered

writeCompressedPlainText :: Strategy -> String -> FilePath -> Int -> Text -> IO ()
writeCompressedPlainText strat stratName outputDir index inputText = do
  let chunk = textToChunk (plainTextId index inputText) UserMessage inputText
      (_, rendered) = compressChunk strat chunk
      origTok = chunkTokens chunk
      compTok = countTokens rendered
      ratio = reductionPercent origTok compTok
      fileName = outputFileStem (chunkId chunk) ++ "." ++ stratName ++ ".txt"
      outFile = outputDir </> fileName
  TIO.putStrLn $ T.concat
    [ "doc=", chunkId chunk
    , " orig=", T.pack (show origTok)
    , " comp=", T.pack (show compTok)
    , " reduction=", T.pack (show (round ratio :: Int)), "%"
    ]
  BS.writeFile outFile (TE.encodeUtf8 rendered)

printDocumentAnchors :: InputDocument -> IO ()
printDocumentAnchors doc = do
  let anchors = concatMap documentTurnAnchors (docTurns doc)
      counts = foldl' (\acc anchor -> Map.insertWith (+) (anchorType anchor) 1 acc) Map.empty anchors
  TIO.putStrLn $ T.concat
    [ "Document ", docId doc, ": ", T.pack (show (length anchors)), " anchors extracted" ]
  mapM_ (printAnchorCount counts) [minBound .. maxBound]

documentTurnAnchors :: InputTurn -> [Anchor]
documentTurnAnchors turn =
  [ anchor
  | Exact anchor <- toList (classify (inputContent turn))
  ]

printAnchorCount :: Map.Map AnchorType Int -> AnchorType -> IO ()
printAnchorCount counts anchorKind =
  case Map.lookup anchorKind counts of
    Just n | n > 0 ->
      TIO.putStrLn $ T.concat
        [ "  ", T.justifyLeft 14 ' ' (T.pack (show anchorKind) <> ":")
        , T.pack (show n)
        ]
    _ -> pure ()

compressRenderedTurn :: Strategy -> InputTurn -> Text
compressRenderedTurn strat turn =
  let chunk = textToChunkFast (inputDocId turn) (parseContextRole (inputRole turn)) (inputContent turn)
      (_, rendered) = compressChunk strat chunk
      roleLabel = "[" <> T.toUpper (inputRole turn) <> "]"
  in if T.null (T.strip rendered)
      then roleLabel
      else roleLabel <> "\n" <> rendered

renderDocumentOriginal :: InputDocument -> Text
renderDocumentOriginal doc = T.intercalate "\n\n" (map renderOriginalTurn (docTurns doc))

renderOriginalTurn :: InputTurn -> Text
renderOriginalTurn turn = "[" <> T.toUpper (inputRole turn) <> "]\n" <> inputContent turn

parseContextRole :: Text -> ContextRole
parseContextRole role =
  case T.toLower role of
    "system" -> SystemPrompt
    "system_prompt" -> SystemPrompt
    "user" -> UserMessage
    "assistant" -> AssistantResponse
    "tool" -> ToolResult
    "tool_result" -> ToolResult
    "tool-result" -> ToolResult
    _ -> Document

textToChunk :: Text -> ContextRole -> Text -> Chunk
textToChunk identifier role t =
  let !mem = classify t
      !tok = countTokens t
  in Chunk
    { chunkId       = identifier
    , chunkRole     = role
    , chunkContent  = t
    , chunkMemory   = mem
    , chunkAge      = Nothing
    , chunkPriority = PMedium
    , chunkTokens   = tok
    }

-- | Fast chunk constructor for paths that never consult chunkTokens.
-- Avoids redundant tokenizer work when compressing document turns.
textToChunkFast :: Text -> ContextRole -> Text -> Chunk
textToChunkFast identifier role t =
  let !mem = classify t
  in Chunk
    { chunkId       = identifier
    , chunkRole     = role
    , chunkContent  = t
    , chunkMemory   = mem
    , chunkAge      = Nothing
    , chunkPriority = PMedium
    , chunkTokens   = 0
    }

plainTextId :: Int -> Text -> Text
plainTextId index inputText =
  T.pack ("line-" ++ show index ++ "-") <> T.take 20 (T.strip inputText)

reductionPercent :: Int -> Int -> Double
reductionPercent origTok compTok
  | origTok > 0 = (1.0 - fromIntegral compTok / fromIntegral origTok) * 100.0
  | otherwise = 0.0

outputFileStem :: Text -> String
outputFileStem rawText
  | isSafeStem rawText = T.unpack rawText
  | otherwise = safeChunkId rawText

isSafeStem :: Text -> Bool
isSafeStem rawText = not (T.null rawText) && T.all isSafeStemChar rawText

isSafeStemChar :: Char -> Bool
isSafeStemChar c = isAlphaNum c || c `elem` ("-_." :: String)

safeChunkId :: Text -> String
safeChunkId rawText =
  let normalized = T.map normalizeChar (T.strip rawText)
      shortened = T.take 40 normalized
      candidate = if T.null shortened then "chunk" else shortened
  in T.unpack candidate
  where
    normalizeChar c
      | isAlphaNum c = c
      | c `elem` ("-_" :: String) = c
      | otherwise = '_'
