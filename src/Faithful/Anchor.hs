{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : Faithful.Anchor
-- Description : Extract exact anchors from text

module Faithful.Anchor
  ( -- * Classification
    classify
  , classifyWithConfig
  , AnchorConfig(..)
  , defaultConfig

    -- * Individual extractors
  , extractNumbers
  , extractIdentifiers
  , extractQuotedStrings
  , extractCodeSpans
  , extractNegations
  , extractConstraints
  , extractProperNouns
  , extractHeadingLines
  , extractFieldLines
  , extractCodeStructure
  ) where

import Faithful.Core

import Control.Parallel.Strategies (parMap, rdeepseq)
import Data.Char (isAlpha, isAlphaNum, isDigit, isLower, isUpper)
import Data.List (sortBy)
import Data.Ord (comparing)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T


data AnchorConfig = AnchorConfig
  { cfgExtractNumbers       :: Bool
  , cfgExtractIdentifiers   :: Bool
  , cfgExtractQuotes        :: Bool
  , cfgExtractCode          :: Bool
  , cfgExtractNegations     :: Bool
  , cfgExtractConstraints   :: Bool
  , cfgExtractProperNouns   :: Bool
  , cfgExtractHeadings      :: Bool
  , cfgExtractFields        :: Bool
  , cfgExtractCodeStructure :: Bool
  , cfgIdPatterns           :: [Text]
  , cfgMinNumberLength      :: Int
  } deriving (Show, Eq)

defaultConfig :: AnchorConfig
defaultConfig = AnchorConfig
  { cfgExtractNumbers       = True
  , cfgExtractIdentifiers   = True
  , cfgExtractQuotes        = True
  , cfgExtractCode          = True
  , cfgExtractNegations     = True
  , cfgExtractConstraints   = True
  , cfgExtractProperNouns   = True
  , cfgExtractHeadings      = True
  , cfgExtractFields        = True
  , cfgExtractCodeStructure = True
  , cfgIdPatterns           = []
  , cfgMinNumberLength      = 1
  }


classify :: Text -> Seq Memory
classify = classifyWithConfig defaultConfig

classifyWithConfig :: AnchorConfig -> Text -> Seq Memory
classifyWithConfig cfg input
  | T.null input = Seq.empty
  | otherwise =
      let extractors = concat
            [ [extractNumbers | cfgExtractNumbers cfg]
            , [extractIdentifiers | cfgExtractIdentifiers cfg]
            , [extractQuotedStrings | cfgExtractQuotes cfg]
            , [extractCodeSpans | cfgExtractCode cfg]
            , [extractNegations | cfgExtractNegations cfg]
            , [extractConstraints | cfgExtractConstraints cfg]
            , [extractProperNouns | cfgExtractProperNouns cfg]
            , [extractHeadingLines | cfgExtractHeadings cfg]
            , [extractFieldLines | cfgExtractFields cfg]
            , [extractCodeStructure | cfgExtractCodeStructure cfg]
            ]
          spanLists :: [[(Int, Int, AnchorType)]]
          spanLists = parMap rdeepseq (\f -> f input) extractors
          spans = concat spanLists
          sorted = sortBy (comparing (\(s, _, _) -> s)) spans
          merged = mergeOverlapping sorted
      in fillGaps input 0 merged


extractNumbers :: Text -> [(Int, Int, AnchorType)]
extractNumbers input = go 0 input
  where
    go !pos !t = case T.uncons t of
      Nothing -> []
      Just (c, rest)
        | isDigit c -> spanNum pos t
        | c == '$', Just (d, _) <- T.uncons rest, isDigit d -> spanNum pos t
        | otherwise -> go (pos + 1) rest

    spanNum !pos !t =
      let (numSpan, remaining) = T.span isNumChar t
          len = T.length numSpan
          digitCount = T.length (T.filter isDigit numSpan)
      in if digitCount >= 1
         then (pos, pos + len, ANumber) : go (pos + len) remaining
         else go (pos + 1) (T.drop 1 t)

    isNumChar c = isDigit c || c `elem` (".,:%$/-" :: String)


extractIdentifiers :: Text -> [(Int, Int, AnchorType)]
extractIdentifiers input = go 0 input
  where
    go !pos !t = case T.uncons t of
      Nothing -> []
      Just (c, _)
        | isIdentStart c ->
            let (ident, remaining) = T.span isIdentChar t
                len = T.length ident
            in if looksLikeIdentifier ident
               then (pos, pos + len, AIdentifier) : go (pos + len) remaining
               else go (pos + 1) (T.drop 1 t)
        | otherwise -> go (pos + 1) (T.drop 1 t)

    isIdentStart c = isAlphaNum c || c == '/' || c == '_'
    isIdentChar c = isAlphaNum c || c `elem` ("-_./:\\@#" :: String)

    looksLikeIdentifier s =
      let hasDigit = T.any isDigit s
          hasUpper = T.any isUpper s
          hasLower = T.any isLower s
          hasSpecial = T.any (`elem` ("-_./:\\@#" :: String)) s
          len = T.length s
      in len >= 3
          && ((hasDigit && (hasUpper || hasLower)) || hasSpecial || (hasUpper && hasLower && len >= 6))


extractQuotedStrings :: Text -> [(Int, Int, AnchorType)]
extractQuotedStrings input = go 0 input
  where
    go !pos !t = case T.breakOn "\"" t of
      (before, match)
        | T.null match -> []
        | otherwise ->
            let qPos = pos + T.length before
                afterOpen = T.drop 1 match
            in case T.breakOn "\"" afterOpen of
              (quoted, close)
                | T.null close -> []
                | T.length quoted > 0 && T.length quoted < 500 ->
                    let end = qPos + T.length quoted + 2
                    in (qPos, end, AQuotedString) : go end (T.drop 1 close)
                | otherwise ->
                    go (qPos + 1) afterOpen


extractCodeSpans :: Text -> [(Int, Int, AnchorType)]
extractCodeSpans = go 0
  where
    go !pos !t = case T.breakOn "`" t of
      (before, match)
        | T.null match -> []
        | otherwise ->
            let bPos = pos + T.length before
            in if T.isPrefixOf "```" match
               then handleTriple bPos (T.drop 3 match)
               else handleInline bPos (T.drop 1 match)

    handleTriple !pos !afterOpen = case T.breakOn "```" afterOpen of
      (code, close)
        | T.null close -> []
        | otherwise ->
            let end = pos + T.length code + 6
            in (pos, end, ACodeSpan) : go end (T.drop 3 close)

    handleInline !pos !afterOpen = case T.breakOn "`" afterOpen of
      (code, close)
        | T.null close -> []
        | T.length code > 0 && T.length code < 200 ->
            let end = pos + T.length code + 2
            in (pos, end, ACodeSpan) : go end (T.drop 1 close)
        | otherwise ->
            go (pos + 1) afterOpen


extractNegations :: Text -> [(Int, Int, AnchorType)]
extractNegations input =
  let lowered = T.toLower input
      rawMatches = concatMap (findAllOccurrences lowered ANegation) negationPatterns
  in map (expandToLineHalo input) rawMatches

negationPatterns :: [Text]
negationPatterns =
  [ "not ", "never ", "don't ", "doesn't ", "didn't ", "won't "
  , "can't ", "cannot ", "shouldn't ", "wouldn't ", "couldn't "
  , "no longer ", "no more ", "neither ", "nor "
  , "isn't ", "aren't ", "wasn't ", "weren't ", "hasn't ", "haven't "
  , "must not ", "shall not ", "may not ", "do not ", "does not "
  , "will not ", "would not ", "could not ", "should not "
  ]


extractConstraints :: Text -> [(Int, Int, AnchorType)]
extractConstraints input =
  let lowered = T.toLower input
  in concatMap (findAllOccurrences lowered AConstraint) constraintPatterns

constraintPatterns :: [Text]
constraintPatterns =
  [ "must ", "shall ", "required ", "mandatory "
  , "at least ", "at most ", "no more than ", "no fewer than "
  , "minimum ", "maximum ", "exactly ", "only if "
  , "prerequisite ", "depends on ", "blocked by "
  ]


extractProperNouns :: Text -> [(Int, Int, AnchorType)]
extractProperNouns input =
  sequenceSpans ++ allCapsSpans
  where
    wordsWithSpans = wordSpans input
    sequenceSpans = collectTitleSequences wordsWithSpans
    allCapsSpans =
      [ (s, e, AProperNoun)
      | (s, e, token) <- wordsWithSpans
      , looksLikeAllCapsEntity token
      ]


extractHeadingLines :: Text -> [(Int, Int, AnchorType)]
extractHeadingLines input =
  [ (start, end, AHeading)
  | (start, end, lineTxt) <- lineSpans input
  , looksLikeHeadingLine lineTxt
  ]


extractFieldLines :: Text -> [(Int, Int, AnchorType)]
extractFieldLines input =
  [ (start, end, AField)
  | (start, end, lineTxt) <- lineSpans input
  , looksLikeFieldLine lineTxt
  ]


extractCodeStructure :: Text -> [(Int, Int, AnchorType)]
extractCodeStructure input =
  [ (start, end, ACodeSpan)
  | (start, end, lineTxt) <- lineSpans input
  , looksLikeCodeStructure lineTxt
  ]


findAllOccurrences :: Text -> AnchorType -> Text -> [(Int, Int, AnchorType)]
findAllOccurrences haystack atype needle = go 0 haystack
  where
    !nLen = T.length needle
    go !offset !remaining
      | T.null remaining = []
      | otherwise =
          let (before, match) = T.breakOn needle remaining
          in if T.null match
             then []
             else let pos = offset + T.length before
                  in (pos, pos + nLen, atype) : go (pos + nLen) (T.drop nLen match)


lineSpans :: Text -> [(Int, Int, Text)]
lineSpans input = go 0 input
  where
    go _ t | T.null t = []
    go offset t =
      let (line, rest) = T.breakOn "\n" t
          lineLen = T.length line
          consumed = if T.null rest then lineLen else lineLen + 1
          lineText = T.take consumed t
          spanEnd = offset + consumed
      in (offset, spanEnd, lineText) : go spanEnd (T.drop consumed t)


wordSpans :: Text -> [(Int, Int, Text)]
wordSpans input = go 0 input
  where
    go !pos !t = case T.uncons t of
      Nothing -> []
      Just (c, rest)
        | isWordChar c ->
            let (wordTxt, remaining) = T.span isWordChar t
                len = T.length wordTxt
            in (pos, pos + len, wordTxt) : go (pos + len) remaining
        | otherwise -> go (pos + 1) rest

    isWordChar c = isAlphaNum c || c `elem` ("'&-" :: String)


collectTitleSequences :: [(Int, Int, Text)] -> [(Int, Int, AnchorType)]
collectTitleSequences [] = []
collectTitleSequences (w:ws)
  | looksTitleWord (third w) =
      let (sequenceWords, rest) = span (adjacentTitleWord w) ws
          allWords = w : sequenceWords
      in if length allWords >= 2
         then (first w, second (last allWords), AProperNoun) : collectTitleSequences rest
         else collectTitleSequences ws
  | otherwise = collectTitleSequences ws
  where
    adjacentTitleWord (_, prevEnd, _) (s, _, token) =
      s - prevEnd <= 2 && looksTitleWord token

    first (a, _, _) = a
    second (_, b, _) = b
    third (_, _, c) = c


expandToLineHalo :: Text -> (Int, Int, AnchorType) -> (Int, Int, AnchorType)
expandToLineHalo input (start, end, atype) =
  let lineStart = findLineStart input start
      lineEnd = findLineEnd input end
  in (lineStart, lineEnd, atype)

findLineStart :: Text -> Int -> Int
findLineStart input idx = go idx
  where
    go pos
      | pos <= 0 = 0
      | T.index input (pos - 1) == '\n' = pos
      | otherwise = go (pos - 1)

findLineEnd :: Text -> Int -> Int
findLineEnd input idx = go idx
  where
    inputLen = T.length input
    go pos
      | pos >= inputLen = inputLen
      | T.index input pos == '\n' = pos
      | otherwise = go (pos + 1)


looksTitleWord :: Text -> Bool
looksTitleWord token =
  case T.uncons token of
    Nothing -> False
    Just (c, rest) ->
      not (T.toLower token `elem` stopWords)
        && isUpper c
        && T.all (\x -> isLower x || x == '.' || x == '-') rest
        && T.length token >= 2
  where
    stopWords =
      [ "a", "an", "and", "or", "the", "for", "of", "to", "in", "on", "with" ]

looksLikeAllCapsEntity :: Text -> Bool
looksLikeAllCapsEntity token =
  let stripped = T.filter (/= '.') token
      alpha = T.filter isAlpha stripped
  in T.length stripped >= 2
      && not (T.null alpha)
      && T.all (\c -> isUpper c || isDigit c || c `elem` ("&-" :: String)) stripped

looksLikeHeadingLine :: Text -> Bool
looksLikeHeadingLine txt =
  let stripped = T.strip txt
      words' = T.words stripped
      titleWords = length (filter looksTitleWord words')
      alphaChars = T.length (T.filter isAlpha stripped)
      punctuationHeavy = T.any (`elem` ("{}[]<>" :: String)) stripped
  in not punctuationHeavy
      && T.length stripped >= 4
      && T.length stripped <= 120
      && alphaChars >= 4
      && (
           T.isPrefixOf "Item " stripped
        || T.isPrefixOf "Section " stripped
        || T.isPrefixOf "Article " stripped
        || T.isSuffixOf ":" stripped
        || (length words' >= 2 && titleWords >= max 2 (length words' - 1))
         )

looksLikeFieldLine :: Text -> Bool
looksLikeFieldLine txt =
  case T.breakOn ":" (T.strip txt) of
    (key, rest) ->
      let keyWords = T.words key
      in not (T.null rest)
          && T.length key >= 2
          && T.length key <= 40
          && not (null keyWords)
          && T.any isAlpha key
          && T.length (T.strip (T.drop 1 rest)) >= 1

looksLikeCodeStructure :: Text -> Bool
looksLikeCodeStructure txt =
  let stripped = T.strip txt
      lowered = T.toLower stripped
  in any (`T.isPrefixOf` lowered)
       [ "import ", "from ", "def ", "class ", "function ", "const "
       , "let ", "var ", "public ", "private ", "protected ", "fn "
       , "type ", "interface ", "module ", "export ", "return "
       ]


mergeOverlapping :: [(Int, Int, AnchorType)] -> [(Int, Int, AnchorType)]
mergeOverlapping [] = []
mergeOverlapping [x] = [x]
mergeOverlapping ((s1, e1, t1) : (s2, e2, t2) : rest)
  | s2 < e1 =
      if e1 >= e2
      then mergeOverlapping ((s1, e1, chooseType (s1, e1, t1) (s2, e2, t2)) : rest)
      else mergeOverlapping ((s1, e2, chooseType (s1, e2, t1) (s2, e2, t2)) : rest)
  | otherwise = (s1, e1, t1) : mergeOverlapping ((s2, e2, t2) : rest)

chooseType :: (Int, Int, AnchorType) -> (Int, Int, AnchorType) -> AnchorType
chooseType (s1, e1, t1) (s2, e2, t2)
  | (e1 - s1) >= (e2 - s2) = t1
  | otherwise = t2

fillGaps :: Text -> Int -> [(Int, Int, AnchorType)] -> Seq Memory
fillGaps input pos [] =
  let remaining = T.drop pos input
  in if T.null remaining then Seq.empty else Seq.singleton (Approx remaining)
fillGaps input pos ((start, end, atype) : rest) =
  let gap = T.take (start - pos) (T.drop pos input)
      anchorTxt = T.take (end - start) (T.drop start input)
      anchor = Anchor atype anchorTxt (start, end)
      gapMem = if T.null gap then Seq.empty else Seq.singleton (Approx gap)
      exactMem = Seq.singleton (Exact anchor)
  in gapMem <> exactMem <> fillGaps input end rest
