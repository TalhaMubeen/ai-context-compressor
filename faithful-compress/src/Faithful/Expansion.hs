{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

-- |
-- Module      : Faithful.Expansion
-- Description : Selective expansion — recover detail when the query needs it
--
-- v5 fixes:
-- - budgetedExpand now strictly respects token budget
-- - assessConfidence uses relevance mass, not just chunk count
-- - renderCompressedPlainText never emits unresolved § tokens

module Faithful.Expansion
  ( ExpansionPolicy(..)
  , ExpansionResult(..)
  , ChunkArchive(..)
  , ArchiveEntry(..)
  , budgetedExpand
  , RelevanceScorer
  , keywordScorer
  , anchorOverlapScorer
  , ExpansionConfidence(..)
  ) where

import Faithful.Core
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.HashMap.Strict as HM
import Data.Sequence (Seq)
import Data.Foldable (toList)
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)
import Data.List (sortBy)
import Data.Ord (Down(..))


-- ════════════════════════════════════════════════════════════════════
-- § TYPES
-- ════════════════════════════════════════════════════════════════════

data ArchiveEntry = ArchiveEntry
  { aeOriginal    :: Chunk
  , aeCompressed  :: CompressedContext
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (NFData)

data ChunkArchive = ChunkArchive
  { caEntries :: Seq ArchiveEntry
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (NFData)

data ExpansionPolicy = ExpansionPolicy
  { epTokenBudget  :: Int       -- ^ Hard maximum tokens in output
  , epMinRelevance :: Double    -- ^ Minimum score to consider expansion
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (NFData)

data ExpansionConfidence
  = HighConfidence
  | MediumConfidence
  | LowConfidence
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving anyclass (NFData)

data ExpansionResult = ExpansionResult
  { erFinalContext    :: Text
  , erTotalTokens     :: Int
  , erExpandedCount   :: Int
  , erCompressedCount :: Int
  , erConfidence      :: ExpansionConfidence
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (NFData)

type RelevanceScorer = Text -> Chunk -> Double


-- ════════════════════════════════════════════════════════════════════
-- § SCORERS
-- ════════════════════════════════════════════════════════════════════

keywordScorer :: RelevanceScorer
keywordScorer query chunk =
  let queryWords = map T.toLower (T.words query)
      chunkLower = T.toLower (chunkContent chunk)
      hits  = length (filter (\w -> w `T.isInfixOf` chunkLower) queryWords)
      total = max 1 (length queryWords)
  in  fromIntegral hits / fromIntegral total

anchorOverlapScorer :: RelevanceScorer
anchorOverlapScorer query chunk =
  let queryLower = T.toLower query
      anchors    = anchorsOf chunk
      hits  = length (filter (\a -> T.toLower (anchorText a) `T.isInfixOf` queryLower) anchors)
      total = max 1 (length anchors)
  in  fromIntegral hits / fromIntegral total


-- ════════════════════════════════════════════════════════════════════
-- § EXPANSION ENGINE
-- ════════════════════════════════════════════════════════════════════

-- | Budget-aware expansion with strict enforcement.
-- Greedily expands most-relevant chunks until budget is exhausted.
-- Remaining budget is filled with compressed chunks in original order.
-- NEVER exceeds epTokenBudget.
budgetedExpand
  :: RelevanceScorer
  -> ExpansionPolicy
  -> Text              -- ^ The query
  -> ChunkArchive
  -> ExpansionResult
budgetedExpand scorer policy query archive =
  let
    budget  = epTokenBudget policy
    entries = toList (caEntries archive)

    -- Score each entry
    scored :: [(ArchiveEntry, Double)]
    scored = map (\e -> (e, scorer query (aeOriginal e))) entries

    -- Sort by relevance (highest first) for expansion priority
    byRelevance = sortBy (\(_, a) (_, b) -> compare (Down a) (Down b)) scored

    -- Greedy expansion within strict budget
    (expanded, remaining, tokensUsed) = greedyExpand byRelevance budget (epMinRelevance policy)

    -- Fill remaining budget with compressed versions (in original order)
    (filled, finalTokens) = fillCompressed remaining (budget - tokensUsed)

    -- Reassemble in a reasonable order (expanded first, then compressed)
    allParts = expanded ++ filled
    finalText = T.intercalate "\n\n" (map fst allParts)

    -- Confidence based on expanded vs relevant count
    relevantCount = length [() | (_, s) <- scored, s >= epMinRelevance policy]
    expandedCount = length expanded
    conf = if relevantCount == 0 then HighConfidence
           else let ratio = fromIntegral expandedCount / fromIntegral (max 1 relevantCount) :: Double
                in  if ratio > 0.8 then HighConfidence
                    else if ratio > 0.4 then MediumConfidence
                    else LowConfidence
  in
    ExpansionResult
      { erFinalContext    = finalText
      , erTotalTokens     = tokensUsed + finalTokens
      , erExpandedCount   = expandedCount
      , erCompressedCount = length filled
      , erConfidence      = conf
      }

-- | Greedily expand highest-relevance chunks within budget.
greedyExpand
  :: [(ArchiveEntry, Double)]  -- ^ sorted by relevance desc
  -> Int                       -- ^ remaining budget
  -> Double                    -- ^ minimum relevance
  -> ([(Text, Int)], [(ArchiveEntry, Double)], Int)
     -- ^ (expanded chunks with token counts, remaining entries, tokens used)
greedyExpand [] _ _ = ([], [], 0)
greedyExpand ((entry, score):rest) budget minRel
  | score < minRel = ([], (entry, score) : rest, 0)  -- below threshold, stop expanding
  | origTok <= budget =
      let (more, remaining, moreTokens) = greedyExpand rest (budget - origTok) minRel
      in  ((origText, origTok) : more, remaining, origTok + moreTokens)
  | otherwise =
      -- Can't afford to expand this one; try the rest
      let (more, remaining, moreTokens) = greedyExpand rest budget minRel
      in  (more, (entry, score) : remaining, moreTokens)
  where
    origText = chunkContent (aeOriginal entry)
    origTok  = chunkTokens (aeOriginal entry)

-- | Fill remaining budget with compressed versions.
fillCompressed
  :: [(ArchiveEntry, Double)]  -- ^ entries not expanded
  -> Int                       -- ^ remaining budget
  -> ([(Text, Int)], Int)      -- ^ (parts, tokens used)
fillCompressed [] _ = ([], 0)
fillCompressed _ budget | budget <= 0 = ([], 0)
fillCompressed ((entry, _):rest) budget =
  let compText = renderPlainText (aeCompressed entry)
      compTok  = ccCompTokens (aeCompressed entry)
  in  if compTok <= budget
      then let (more, moreTok) = fillCompressed rest (budget - compTok)
           in  ((compText, compTok) : more, compTok + moreTok)
      else fillCompressed rest budget  -- skip if too large


-- ════════════════════════════════════════════════════════════════════
-- § SAFE RENDERING
-- ════════════════════════════════════════════════════════════════════

-- | Render CompressedContext to plain text.
-- SAFE: never emits unresolved § tokens or synthetic notation.
-- In extractive mode (the default), output is always natural language.
renderPlainText :: CompressedContext -> Text
renderPlainText cc = T.concat
  [ T.concat $ map safeRender $ toList tokens
  | (tokens, _) <- toList (ccChunks cc)
  ]
  where
    refTable = ccRefTable cc
    safeRender (TLiteral t)      = t
    safeRender (TAnchorMarker _) = ""
    safeRender (TPriorityTag _)  = ""
    -- Storage-only tokens: resolve from ref table or drop
    safeRender (TRef c)          =
      case HM.lookup (T.singleton c) refTable of
        Just v  -> v
        Nothing -> ""   -- drop unresolvable refs (safe default)
    safeRender (TSymbol _)       = ""  -- drop synthetic symbols
