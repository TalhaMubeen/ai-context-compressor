{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : Faithful.Strategy
-- Description : Compression strategies with enforced exact/approx boundary
--
-- DESIGN (v3 — post-audit):
--
-- The core contract: strategies transform ONLY Approx spans.
-- Exact spans are carried separately and reinserted mechanically.
-- A strategy literally cannot modify an Exact anchor because it
-- never receives one.
--
-- Previous design flaw: the (|>) combinator rendered compressed
-- output to text, replaced chunkContent, but did NOT recompute
-- chunkMemory. Downstream strategies operated on stale Memory
-- that no longer matched the text. This broke the exact/approx
-- invariant mechanically.
--
-- New design: strategies receive Approx text spans (just Text values)
-- and return compressed Text values. The pipeline reassembles the
-- chunk with Exact spans untouched by construction.

module Faithful.Strategy
  ( -- * Strategy type
    Strategy(..)
  , ApproxTransform
  , runOnChunk
    
    -- * Combinators
  , (|>)
  , compose
  , withFallback
  , identity
    
    -- * Role-aware
  , roleAware
    
    -- * Budget-aware (replaces rigid tiers)
  , AgeTier(..)
  , BudgetWeight
  , ageTier
  , chunkBudgetWeight
  , budgetAware
    
    -- * Running the full pipeline
  , compressChunk
  ) where

import Faithful.Core

import Data.Text (Text)
import qualified Data.Text as T
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Foldable (toList)
import Data.Time (UTCTime, NominalDiffTime, diffUTCTime)


-- ════════════════════════════════════════════════════════════════════
-- § THE CORE CONTRACT
-- ════════════════════════════════════════════════════════════════════
--
-- A strategy is a function that transforms Approx text spans.
-- It NEVER sees Exact spans. It CANNOT modify anchors.
--
-- The pipeline extracts Approx spans from a Chunk, hands them
-- to the strategy, gets back compressed spans, and reassembles
-- the chunk with Exact spans untouched.

-- | Transform a single Approx text span into a (possibly shorter) text.
-- This is the primitive operation. Strategies compose over this.
type ApproxTransform = Text -> Text

-- | A named compression strategy that operates on Approx spans only.
data Strategy = Strategy
  { strategyName :: Text
  , strategyTransform :: ApproxTransform
  }

-- | Identity: pass Approx spans through unchanged.
identity :: Strategy
identity = Strategy "identity" id


-- ════════════════════════════════════════════════════════════════════
-- § COMBINATORS
-- ════════════════════════════════════════════════════════════════════
--
-- Because ApproxTransform is just Text -> Text, composition is
-- plain function composition. No stale chunkMemory. No broken spans.
-- No invariant violations. The bug in v1/v2 is structurally impossible.

-- | Compose two strategies: run A on each Approx span, then run B.
(|>) :: Strategy -> Strategy -> Strategy
a |> b = Strategy
  { strategyName = strategyName a <> " → " <> strategyName b
  , strategyTransform = strategyTransform b . strategyTransform a
  }

-- | Compose a list of strategies left-to-right.
compose :: [Strategy] -> Strategy
compose []     = identity
compose [x]    = x
compose (x:xs) = foldl (|>) x xs

-- | Try primary; if the result is not shorter, use fallback.
withFallback :: Strategy -> Strategy -> Strategy
withFallback primary fallback = Strategy
  { strategyName = strategyName primary <> " // " <> strategyName fallback
  , strategyTransform = \t ->
      let result = strategyTransform primary t
      in  if T.length result < T.length t
          then result
          else strategyTransform fallback t
  }


-- ════════════════════════════════════════════════════════════════════
-- § RUNNING A STRATEGY ON A CHUNK
-- ════════════════════════════════════════════════════════════════════

-- | Apply a strategy to a Chunk. Exact spans are preserved by
-- construction — the transform function never receives them.
runOnChunk :: Strategy -> Chunk -> Seq Memory
runOnChunk strat chunk =
  fmap (applyToMemory (strategyTransform strat)) (chunkMemory chunk)

-- | The core enforcement: Exact is untouched, Approx is transformed.
applyToMemory :: ApproxTransform -> Memory -> Memory
applyToMemory _ mem@(Exact _) = mem      -- structurally unreachable by strategy
applyToMemory f (Approx t)    = Approx (f t)

-- | Full pipeline: apply strategy, render to text, return both.
-- The rendered text is guaranteed to contain all Exact anchor text
-- in its original form, because applyToMemory never modifies Exact.
compressChunk :: Strategy -> Chunk -> (Seq Memory, Text)
compressChunk strat chunk =
  let compressed = runOnChunk strat chunk
      rendered   = T.concat (map memoryToText (toList compressed))
  in  (compressed, rendered)
  where
    memoryToText (Exact a)  = anchorText a
    memoryToText (Approx t) = t


-- ════════════════════════════════════════════════════════════════════
-- § ROLE-AWARE COMPRESSION
-- ════════════════════════════════════════════════════════════════════

-- | Select strategy based on chunk's role.
-- Returns a Strategy, not a CompressedContext — the caller runs it.
roleAware :: (ContextRole -> Strategy) -> Chunk -> Strategy
roleAware selector chunk = selector (chunkRole chunk)


-- ════════════════════════════════════════════════════════════════════
-- § BUDGET-AWARE ALLOCATION (replaces rigid tiers)
-- ════════════════════════════════════════════════════════════════════

data AgeTier = Recent | Medium | Old | Ancient
  deriving (Show, Eq, Ord, Enum, Bounded)

type BudgetWeight = Double

ageTier :: UTCTime -> UTCTime -> AgeTier
ageTier now chunkTime
  | age < 300    = Recent
  | age < 3600   = Medium
  | age < 86400  = Old
  | otherwise    = Ancient
  where
    age :: NominalDiffTime
    age = diffUTCTime now chunkTime

ageDefaultWeight :: AgeTier -> BudgetWeight
ageDefaultWeight Recent  = 1.0
ageDefaultWeight Medium  = 0.7
ageDefaultWeight Old     = 0.4
ageDefaultWeight Ancient = 0.2

-- | Boost weight based on anchor density.
contentOverride :: Chunk -> BudgetWeight -> BudgetWeight
contentOverride chunk baseWeight =
  let anchors = anchorsOf chunk
      constraints = length [a | a <- anchors, anchorType a == AConstraint]
      negations   = length [a | a <- anchors, anchorType a == ANegation]
      numbers     = length [a | a <- anchors, anchorType a == ANumber]
      codeSpans   = length [a | a <- anchors, anchorType a == ACodeSpan]
      boost = fromIntegral (constraints * 3 + negations * 2 + numbers + codeSpans) * 0.05
  in  min 1.0 (baseWeight + boost)

chunkBudgetWeight :: UTCTime -> Chunk -> BudgetWeight
chunkBudgetWeight now chunk =
  let tier = case chunkAge chunk of
        Just t  -> ageTier now t
        Nothing -> Medium
      base = ageDefaultWeight tier
  in  contentOverride chunk base

-- | Choose compression aggressiveness based on budget weight.
budgetAware :: UTCTime -> (BudgetWeight -> Strategy) -> Chunk -> Strategy
budgetAware now weightToStrategy chunk =
  weightToStrategy (chunkBudgetWeight now chunk)
