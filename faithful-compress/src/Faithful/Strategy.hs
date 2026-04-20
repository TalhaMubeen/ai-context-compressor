{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : Faithful.Strategy
-- Description : Compression strategies with enforced exact/approx boundary
--
-- The simple path keeps the original v4/v5 contract: transform only Approx text.
-- More ambitious strategies can now inspect full chunk structure, but they still
-- return a 'Seq Memory' so Exact anchors remain explicit and auditable.

module Faithful.Strategy
  ( -- * Strategy type
    Strategy(..)
  , ApproxTransform
  , mkApproxStrategy
  , mkChunkStrategy
  , runOnChunk

    -- * Combinators
  , (|>)
  , compose
  , withFallback
  , identity

    -- * Concrete strategies
  , anchorsOnly
  , noAnchors
  , lightFiller
  , tailRescueStatic

    -- * Readability metrics
  , readabilityRatio

    -- * Bridge to CompressedContext
  , compressChunk
  , compressChunkFull

    -- * Role-aware
  , roleAware

    -- * Budget-aware
  , AgeTier(..)
  , BudgetWeight
  , ageTier
  , chunkBudgetWeight
  , budgetAware
  ) where

import Faithful.Core
import Faithful.Anchor (classify)
import Faithful.Tokenizer (countTokens)

import Data.Char (isAlpha, isDigit, isSpace)
import Data.Foldable (toList)
import Data.List (foldl', sortBy)
import Data.Ord (comparing, Down(..))
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, diffUTCTime)


type ApproxTransform = Text -> Text

data Strategy = Strategy
  { strategyName      :: Text
  , strategyTransform :: ApproxTransform
  , strategyRun       :: Chunk -> Seq Memory
  }

mkApproxStrategy :: Text -> ApproxTransform -> Strategy
mkApproxStrategy name transform = Strategy
  { strategyName = name
  , strategyTransform = transform
  , strategyRun = \chunk -> fmap (applyToMemory transform) (chunkMemory chunk)
  }

mkChunkStrategy :: Text -> (Chunk -> Seq Memory) -> Strategy
mkChunkStrategy name run = Strategy
  { strategyName = name
  , strategyTransform = id
  , strategyRun = run
  }

identity :: Strategy
identity = mkApproxStrategy "identity" id

applyToMemory :: ApproxTransform -> Memory -> Memory
applyToMemory _ mem@(Exact _) = mem
applyToMemory f (Approx t)    = let !r = f t in Approx r
{-# INLINE applyToMemory #-}

runOnChunk :: Strategy -> Chunk -> Seq Memory
runOnChunk = strategyRun
{-# INLINE runOnChunk #-}


renderMemories :: Seq Memory -> Text
renderMemories = T.concat . map memoryText . toList
  where
    memoryText (Exact a)  = anchorText a
    memoryText (Approx t) = t

chunkWithMemory :: Chunk -> Seq Memory -> Chunk
chunkWithMemory chunk memories =
  chunk
    { chunkMemory = memories
    , chunkContent = renderMemories memories
    }


(|>) :: Strategy -> Strategy -> Strategy
a |> b = Strategy
  { strategyName = strategyName a <> " → " <> strategyName b
  , strategyTransform = strategyTransform b . strategyTransform a
  , strategyRun = \chunk ->
      let first = runOnChunk a chunk
      in runOnChunk b (chunkWithMemory chunk first)
  }

compose :: [Strategy] -> Strategy
compose []     = identity
compose [x]    = x
compose (x:xs) = foldl' (|>) x xs

withFallback :: Strategy -> Strategy -> Strategy
withFallback primary fallback = mkChunkStrategy
  (strategyName primary <> " // " <> strategyName fallback)
  choose
  where
    choose chunk =
      let primaryResult = runOnChunk primary chunk
          fallbackResult = runOnChunk fallback chunk
      in if T.length (renderMemories primaryResult) < T.length (chunkContent chunk)
         then primaryResult
         else fallbackResult


anchorsOnly :: Strategy
anchorsOnly = mkApproxStrategy "anchors-only" (const "")

noAnchors :: Strategy
noAnchors = mkApproxStrategy "no-anchors" id

lightFiller :: Strategy
lightFiller = mkApproxStrategy "light-filler" removeFiller
  where
    removeFiller t =
      let ws = T.words t
          filtered = filter (not . isFiller . T.toLower) ws
      in T.unwords filtered
    isFiller w = w `elem` fillerWords
    fillerWords =
      [ "basically", "essentially", "actually", "really", "very"
      , "just", "quite", "simply", "literally", "honestly"
      , "obviously", "clearly", "definitely", "certainly"
      , "anyway", "furthermore", "moreover", "however"
      , "nevertheless", "nonetheless", "subsequently"
      ]


data SegmentMode = SegmentBySentence | SegmentByLine

data RetainUnit = RetainUnit
  { unitStart :: !Int
  , unitEnd   :: !Int
  , unitText  :: !Text
  , unitScore :: !Double
  } deriving (Show, Eq)

tailRescueStatic :: Strategy
tailRescueStatic = mkChunkStrategy "tail-rescue-static" keepTailAndRescue

-- | Wrapper: run core at 1.0× budget, check readability, retry at 1.4× if
-- the output is anchor soup.  Fallback only fires on non-trivial chunks
-- where there is enough Approx text to redistribute.
-- For very large chunks (>15 000 chars), splits into windows to avoid
-- quadratic anchor scoring blowup.
keepTailAndRescue :: Chunk -> Seq Memory
keepTailAndRescue chunk
  | T.length (chunkContent chunk) > 15000 = keepTailAndRescueWindowed chunk
  | approxChars <= 0                      = postProcess (chunkMemory chunk)
  | T.length (chunkContent chunk) <= 160  = postProcess (chunkMemory chunk)
  | otherwise =
      let primary = keepTailAndRescueCore 1.0 chunk
      in if readabilityRatio primary < minReadability && approxChars > 160
         then keepTailAndRescueCore 1.4 chunk
         else primary
  where
    postProcess = glueAnchors . dedupAnchors
    approxChars = sum [T.length t | Approx t <- toList (chunkMemory chunk)]

-- | Split very large text into ~10 000 char windows at paragraph boundaries,
-- compress each independently, and concatenate.  Avoids O(lines × anchors)
-- blowup that makes 40KB+ SEC filings take minutes.
keepTailAndRescueWindowed :: Chunk -> Seq Memory
keepTailAndRescueWindowed chunk =
    postProcess (mconcat (map compressWindow windows))
  where
    postProcess = glueAnchors . dedupAnchors
    content = chunkContent chunk
    role = chunkRole chunk
    windowSize = 10000 :: Int
    -- Split at paragraph boundaries near the target window size
    windows = splitAtParagraphs windowSize content
    compressWindow :: Text -> Seq Memory
    compressWindow winText =
      let mem   = classify winText
          sub   = Chunk { chunkId       = chunkId chunk
                        , chunkRole     = role
                        , chunkContent  = winText
                        , chunkMemory   = mem
                        , chunkAge      = chunkAge chunk
                        , chunkPriority = chunkPriority chunk
                        , chunkTokens   = T.length winText `div` 4
                        }
          result = keepTailAndRescueCore 1.0 sub
      in if readabilityRatio result < minReadability
         then keepTailAndRescueCore 1.4 sub
         else result

-- | Split text into windows of approximately the target size,
-- breaking at paragraph boundaries ("\n\n") when possible.
splitAtParagraphs :: Int -> Text -> [Text]
splitAtParagraphs _ t | T.null t = []
splitAtParagraphs target t
  | T.length t <= target = [t]
  | otherwise =
      let prefix = T.take (target + 500) t  -- look slightly past target
          breakIdx = case T.breakOn "\n\n" (T.drop (target - 500) prefix) of
            (before, rest)
              | T.null rest -> target  -- no paragraph break found, hard split
              | otherwise   -> (target - 500) + T.length before + 2
          (window, remaining) = T.splitAt breakIdx t
      in window : splitAtParagraphs target remaining

-- | Parameterised core: budgetScale multiplies the retained budget so the
-- fallback wrapper can request more generous retention.
keepTailAndRescueCore :: Double -> Chunk -> Seq Memory
keepTailAndRescueCore budgetScale chunk = postProcess raw
  where
    postProcess = glueAnchors . dedupAnchors
    raw
      | null rawUnits = chunkMemory chunk
      | otherwise     = rebuildMemories selectedSpans annotated
    totalChars     = T.length (chunkContent chunk)
    approxChars    = sum [T.length t | Approx t <- toList (chunkMemory chunk)]
    retainedBudget = max 48 (floor (fromIntegral approxChars
                     * roleBudgetFraction (chunkRole chunk) * budgetScale))
    tailBudget     = max 24 (floor (fromIntegral retainedBudget
                     * roleTailShare (chunkRole chunk)))
    rescueBudget   = max 0 (retainedBudget - tailBudget)
    rawUnits       = buildUnits chunk          -- domain scoring baked into scoreUnit
    tailUnits      = selectTailUnits tailBudget rawUnits
    tailSpans      = map (\u -> (unitStart u, unitEnd u)) tailUnits
    tailStart      = minimumDefault totalChars (map fst tailSpans)
    rescueUnits    = selectRescueUnits rescueBudget tailStart rawUnits
    haloUnits      = expandHalos rescueUnits rawUnits tailStart  -- ±1 halo
    allRescueSpans = map (\u -> (unitStart u, unitEnd u)) haloUnits
    selectedSpans  = mergeSpans (tailSpans ++ allRescueSpans)
    annotated      = annotateMemories (chunkMemory chunk)

roleBudgetFraction :: ContextRole -> Double
roleBudgetFraction SystemPrompt      = 0.80
roleBudgetFraction UserMessage       = 0.52
roleBudgetFraction AssistantResponse = 0.48
roleBudgetFraction ToolResult        = 0.42
roleBudgetFraction Document          = 0.40

roleTailShare :: ContextRole -> Double
roleTailShare SystemPrompt      = 0.85
roleTailShare UserMessage       = 0.70
roleTailShare AssistantResponse = 0.65
roleTailShare ToolResult        = 0.50
roleTailShare Document          = 0.45

-- | Content-based domain hint, inferred from chunk structure.
-- Defaults to DHProse (backward-compatible: multiplier 1.0 everywhere).
data DomainHint = DHProse | DHCode | DHLegal | DHChat
  deriving (Show, Eq, Ord)

-- | Infer domain from structural signals in the chunk content.
-- Pure, O(lines + anchors).  Falls to DHProse on ambiguity.
inferDomain :: Chunk -> DomainHint
inferDomain chunk
  | codeRatio  >= 0.25 = DHCode
  | legalRatio >= 0.30 = DHLegal
  | chatLike           = DHChat
  | otherwise          = DHProse
  where
    content   = chunkContent chunk
    ls        = filter (not . T.null . T.strip) (T.lines content)
    lineCount = max 1 (length ls)
    anchors   = anchorsOf chunk
    aCount    = max 1 (length anchors)
    codeLines   = length [l | l <- ls, looksLikeCodeStructure l]
    codeAnchors = length [a | a <- anchors, anchorType a == ACodeSpan]
    codeRatio   = fromIntegral (codeLines + codeAnchors)
                / fromIntegral (lineCount + aCount) :: Double
    legalAnchors = length [ a | a <- anchors
                          , anchorType a `elem` [AConstraint, AField, AHeading] ]
    legalRatio   = fromIntegral legalAnchors / fromIntegral aCount :: Double
    avgLen     = fromIntegral (T.length content) / fromIntegral lineCount :: Double
    turnBreaks = T.count "\n\n" content
    chatLike   = avgLen < 80 && turnBreaks >= 3

-- | Content-aware scoring multiplier.  Applied on top of the base score.
-- DHProse returns 1.0 everywhere — backward-compatible identity.
domainMul :: DomainHint -> Text -> Double
domainMul DHCode txt
  | looksLikeCodeStructure txt = 1.8
  | looksLikeIdentifierish txt = 1.4
  | otherwise                  = 1.0
domainMul DHLegal txt
  | looksLikeHeadingLine txt   = 1.6
  | looksLikeFieldLine txt     = 1.5
  | otherwise                  = 1.0
domainMul DHChat _             = 1.0
domainMul DHProse _            = 1.0

buildUnits :: Chunk -> [RetainUnit]
buildUnits chunk =
  let domain = inferDomain chunk
      spans = case segmentMode chunk of
        SegmentByLine -> lineSpans (chunkContent chunk)
        SegmentBySentence -> sentenceSpans (chunkContent chunk)
  in map (scoreUnit domain chunk) spans

segmentMode :: Chunk -> SegmentMode
segmentMode chunk
  | chunkRole chunk == ToolResult = SegmentByLine
  | any (\a -> anchorType a == ACodeSpan) (anchorsOf chunk) = SegmentByLine
  | T.count "\n" (chunkContent chunk) >= 4 = SegmentByLine
  | otherwise = SegmentBySentence

scoreUnit :: DomainHint -> Chunk -> (Int, Int, Text) -> RetainUnit
scoreUnit domain chunk (start, end, txt) = RetainUnit
  { unitStart = start
  , unitEnd = end
  , unitText = txt
  , unitScore = score
  }
  where
    overlappingAnchors = filter (spansOverlap (start, end) . anchorSpan) (anchorsOf chunk)
    anchorScore = sum (map (anchorWeight . anchorType) overlappingAnchors)
    headingBonus = if looksLikeHeadingLine txt then 2.0 else 0.0
    fieldBonus = if looksLikeFieldLine txt then 2.5 else 0.0
    codeBonus = if looksLikeCodeStructure txt then 2.0 else 0.0
    digitBonus = if T.any isDigit txt then 0.5 else 0.0
    identifierBonus = if looksLikeIdentifierish txt then 0.75 else 0.0
    domainScore = domainBonus (chunkRole chunk) txt
    rawScore = anchorScore + headingBonus + fieldBonus + codeBonus
               + digitBonus + identifierBonus + domainScore
    score = rawScore * domainMul domain txt

anchorWeight :: AnchorType -> Double
anchorWeight ANegation     = 6.0
anchorWeight AConstraint   = 5.5
anchorWeight AField        = 5.0
anchorWeight AHeading      = 4.0
anchorWeight ACodeSpan     = 4.0
anchorWeight AIdentifier   = 3.5
anchorWeight ANumber       = 2.5
anchorWeight AQuotedString = 2.0
anchorWeight AProperNoun   = 2.0

-- | Role-specific scoring bonus.  Code-heavy roles (ToolResult, Document)
-- boost imports/signatures; SystemPrompt boosts structured fields.
domainBonus :: ContextRole -> Text -> Double
domainBonus ToolResult txt
  | looksLikeCodeStructure txt = 3.0
  | looksLikeFieldLine txt     = 2.0
  | otherwise                  = 0.0
domainBonus Document txt
  | looksLikeCodeStructure txt = 2.5
  | looksLikeHeadingLine txt   = 2.0
  | otherwise                  = 0.0
domainBonus SystemPrompt txt
  | looksLikeCodeStructure txt = 1.5
  | looksLikeFieldLine txt     = 1.0
  | otherwise                  = 0.0
domainBonus _ _ = 0.0

selectTailUnits :: Int -> [RetainUnit] -> [RetainUnit]
selectTailUnits budget units = reverse (go 0 [] (reverse units))
  where
    go _ acc [] = acc
    go used acc (u:rest)
      | used >= budget && not (null acc) = acc
      | otherwise = go (used + unitLength u) (u : acc) rest

selectRescueUnits :: Int -> Int -> [RetainUnit] -> [RetainUnit]
selectRescueUnits budget tailStart units
  | budget <= 0 = []
  | otherwise = reverse (go 0 [] sorted)
  where
    candidates =
      [ u
      | u <- units
      , unitEnd u <= tailStart
      , unitScore u > 0.0
      ]
    sorted = sortBy rescueOrdering candidates

    rescueOrdering a b =
      compare (Down (valueDensity a)) (Down (valueDensity b))
        <> compare (unitStart a) (unitStart b)

    valueDensity u = unitScore u / fromIntegral (max 1 (unitLength u))

    go _ acc [] = acc
    go used acc (u:rest)
      | used >= budget = acc
      | used + unitLength u > budget && not (null acc) = acc
      | otherwise = go (used + unitLength u) (u : acc) rest

unitLength :: RetainUnit -> Int
unitLength u = max 0 (unitEnd u - unitStart u)

-- | Expand rescue selection by ±1 unit for context around rescued anchors.
-- Prevents "orphaned" fragments that lack surrounding context.
expandHalos :: [RetainUnit] -> [RetainUnit] -> Int -> [RetainUnit]
expandHalos rescued allUnits tailStart
  | null rescued = []
  | otherwise =
      let rescueSet = Set.fromList [(unitStart u, unitEnd u) | u <- rescued]
          indexed  = zip [0 :: Int ..] allUnits
          rescueIxs = [i | (i, u) <- indexed
                         , (unitStart u, unitEnd u) `Set.member` rescueSet]
          haloIxs = Set.fromList (concatMap (\i -> [i-1, i, i+1]) rescueIxs)
      in [ u | (i, u) <- indexed
             , i `Set.member` haloIxs
             , unitEnd u <= tailStart
         ]

-- | Fraction of output that is Approx (context) text vs total.
-- Below ~0.15, output is anchor soup — isolated exact spans
-- with no surrounding context, which confuses LLMs.
readabilityRatio :: Seq Memory -> Double
readabilityRatio mems =
  let totalLen  = sum [memLen m | m <- toList mems]
      approxLen = sum [T.length t | Approx t <- toList mems]
  in if totalLen == 0 then 1.0
     else fromIntegral approxLen / fromIntegral totalLen
  where
    memLen (Exact a)  = T.length (anchorText a)
    memLen (Approx t) = T.length t

-- | Minimum acceptable readability before fallback activates.
minReadability :: Double
minReadability = 0.15

lineSpans :: Text -> [(Int, Int, Text)]
lineSpans input = go 0 input
  where
    go _ t | T.null t = []
    go offset t =
      let (line, rest) = T.breakOn "\n" t
          lineLen = T.length line
          consumed = if T.null rest then lineLen else lineLen + 1
          spanEnd = offset + consumed
          lineText = T.take consumed t
      in if T.null (T.strip lineText)
         then go spanEnd (T.drop consumed t)
         else (offset, spanEnd, lineText) : go spanEnd (T.drop consumed t)

sentenceSpans :: Text -> [(Int, Int, Text)]
sentenceSpans input = finalizeUnits (go 0 0 [] (T.unpack input))
  where
    go _ start acc [] =
      if start >= T.length input
      then reverse acc
      else reverse ((start, T.length input) : acc)
    go pos start acc (c:rest)
      | isBoundary c =
          let end = pos + 1
              acc' = if end > start then (start, end) : acc else acc
              nextStart = skipLeadingSpace end rest
          in go nextStart nextStart acc' (dropConsumed (nextStart - end) rest)
      | otherwise = go (pos + 1) start acc rest

    isBoundary c = c `elem` (".?!;\n" :: String)

    skipLeadingSpace idx [] = idx
    skipLeadingSpace idx (x:xs)
      | isSpace x = skipLeadingSpace (idx + 1) xs
      | otherwise = idx

    dropConsumed 0 xs = xs
    dropConsumed n xs = drop n xs

    finalizeUnits spans =
      [ (s, e, T.take (e - s) (T.drop s input))
      | (s, e) <- spans
      , let txt = T.take (e - s) (T.drop s input)
      , not (T.null (T.strip txt))
      ]

minimumDefault :: Int -> [Int] -> Int
minimumDefault fallback [] = fallback
minimumDefault _ xs = minimum xs

mergeSpans :: [(Int, Int)] -> [(Int, Int)]
mergeSpans [] = []
mergeSpans spans = reverse (foldl' step [] sorted)
  where
    sorted = sortBy (comparing fst <> comparing snd) spans
    step [] span' = [span']
    step ((s1, e1):rest) (s2, e2)
      | s2 <= e1 + 1 = (s1, max e1 e2) : rest
      | otherwise = (s2, e2) : (s1, e1) : rest

annotateMemories :: Seq Memory -> [(Int, Int, Memory)]
annotateMemories memories = reverse $ snd (foldl' step (0, []) (toList memories))
  where
    step (offset, acc) memory =
      let len = case memory of
            Exact a  -> T.length (anchorText a)
            Approx t -> T.length t
      in (offset + len, (offset, offset + len, memory) : acc)

rebuildMemories :: [(Int, Int)] -> [(Int, Int, Memory)] -> Seq Memory
rebuildMemories selected = foldl' step Seq.empty
  where
    step acc (_, _, Exact anchor) = acc Seq.|> Exact anchor
    step acc (start, end, Approx txt) =
      foldl' (\seqAcc piece -> seqAcc Seq.|> Approx piece) acc (selectedPieces start end txt selected)

selectedPieces :: Int -> Int -> Text -> [(Int, Int)] -> [Text]
selectedPieces start end txt spans =
  [ piece
  | (s, e) <- spans
  , let overlapStart = max start s
  , let overlapEnd = min end e
  , overlapStart < overlapEnd
  , let localStart = overlapStart - start
  , let localLen = overlapEnd - overlapStart
  , let piece = T.take localLen (T.drop localStart txt)
  , not (T.null piece)
  ]

spansOverlap :: (Int, Int) -> (Int, Int) -> Bool
spansOverlap (s1, e1) (s2, e2) = s1 < e2 && s2 < e1

-- | Insert minimal whitespace between consecutive Exact spans so anchors
-- don't fuse into unreadable soup. Pure post-filter on the output sequence.
glueAnchors :: Seq Memory -> Seq Memory
glueAnchors memories = case Seq.viewl memories of
  Seq.EmptyL     -> Seq.empty
  first Seq.:< rest -> foldl' step (Seq.singleton first) (toList rest)
  where
    step acc mem = case (lastIsExact acc, mem) of
      (True, Exact _) -> acc Seq.|> Approx " " Seq.|> mem
      _               -> acc Seq.|> mem

    lastIsExact s = case Seq.viewr s of
      _ Seq.:> Exact _ -> True
      _                -> False

-- | Drop duplicate Exact anchors (by text), keeping the first occurrence.
-- Saves budget when an identifier/import appears many times in a chunk.
dedupAnchors :: Seq Memory -> Seq Memory
dedupAnchors = snd . foldl' step (Set.empty, Seq.empty)
  where
    step (seen, acc) mem@(Exact a)
      | anchorText a `Set.member` seen = (seen, acc)
      | otherwise = (Set.insert (anchorText a) seen, acc Seq.|> mem)
    step (seen, acc) mem = (seen, acc Seq.|> mem)

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

looksLikeIdentifierish :: Text -> Bool
looksLikeIdentifierish txt =
  let stripped = T.strip txt
      hasDigit = T.any isDigit stripped
      hasSpecial = T.any (`elem` ("-_./:\\()[]{}" :: String)) stripped
      hasUpper = T.any (\c -> c >= 'A' && c <= 'Z') stripped
      hasLower = T.any (\c -> c >= 'a' && c <= 'z') stripped
  in hasSpecial || (hasDigit && (hasUpper || hasLower))

looksTitleWord :: Text -> Bool
looksTitleWord word =
  case T.uncons word of
    Nothing -> False
    Just (c, rest) ->
      c >= 'A' && c <= 'Z'
        && T.all (\x -> x == '.' || x == '\'' || (x >= 'a' && x <= 'z')) rest


compressChunk :: Strategy -> Chunk -> (Seq Memory, Text)
compressChunk strat chunk =
  let compressed = runOnChunk strat chunk
      rendered = renderMemories compressed
  in (compressed, rendered)

compressChunkFull :: UTCTime -> Strategy -> Chunk -> CompressedContext
compressChunkFull now strat chunk =
  let (memories, rendered) = compressChunk strat chunk
      compTok = countTokens rendered
      prov = Provenance
        { provStrategy = strategyName strat
        , provOrigTokens = chunkTokens chunk
        , provCompTokens = compTok
        , provAnchorsKept = length [() | Exact _ <- toList memories]
        , provAnchorsTotal = length (anchorsOf chunk)
        , provTimestamp = now
        }
  in CompressedContext
       { ccChunks = Seq.singleton (Seq.singleton (TLiteral rendered), prov)
       , ccRefTable = mempty
       , ccAnchors = Seq.fromList (anchorsOf chunk)
       , ccOrigTokens = chunkTokens chunk
       , ccCompTokens = compTok
       }


roleAware :: (ContextRole -> Strategy) -> Chunk -> Strategy
roleAware selector chunk = selector (chunkRole chunk)


data AgeTier = Recent | Medium | Old | Ancient
  deriving (Show, Eq, Ord, Enum, Bounded)

type BudgetWeight = Double

ageTier :: UTCTime -> UTCTime -> AgeTier
ageTier now chunkTime
  | age < 300 = Recent
  | age < 3600 = Medium
  | age < 86400 = Old
  | otherwise = Ancient
  where
    age = diffUTCTime now chunkTime

ageDefaultWeight :: AgeTier -> BudgetWeight
ageDefaultWeight Recent  = 1.0
ageDefaultWeight Medium  = 0.7
ageDefaultWeight Old     = 0.4
ageDefaultWeight Ancient = 0.2

contentOverride :: Chunk -> BudgetWeight -> BudgetWeight
contentOverride chunk baseWeight =
  let anchors = anchorsOf chunk
      constraints = length [a | a <- anchors, anchorType a == AConstraint]
      negations = length [a | a <- anchors, anchorType a == ANegation]
      numbers = length [a | a <- anchors, anchorType a == ANumber]
      codeSpans = length [a | a <- anchors, anchorType a == ACodeSpan]
      fields = length [a | a <- anchors, anchorType a == AField]
      headings = length [a | a <- anchors, anchorType a == AHeading]
      boost = fromIntegral (constraints * 3 + negations * 2 + numbers + codeSpans * 2 + fields * 2 + headings) * 0.05
  in min 1.0 (baseWeight + boost)

chunkBudgetWeight :: UTCTime -> Chunk -> BudgetWeight
chunkBudgetWeight now chunk =
  let tier = case chunkAge chunk of
        Just t  -> ageTier now t
        Nothing -> Medium
  in contentOverride chunk (ageDefaultWeight tier)

budgetAware :: UTCTime -> (BudgetWeight -> Strategy) -> Chunk -> Strategy
budgetAware now weightToStrategy chunk =
  weightToStrategy (chunkBudgetWeight now chunk)
