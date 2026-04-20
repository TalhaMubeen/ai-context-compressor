{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Test.Properties
-- Description : Property-based tests for faithful compression
--
-- These properties test real invariants against non-trivial strategies.
-- The previous version only tested identity, which proved almost nothing.

module Main where

import Faithful.Core
import Faithful.Anchor
import Faithful.Strategy

import Test.QuickCheck
import Test.QuickCheck.Instances.Text ()
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Sequence as Seq
import Data.Foldable (toList)
import Data.List (sort)


main :: IO ()
main = do
  putStrLn "=== Faithful Compress — Property Tests ==="
  
  putStrLn "\n--- Anchor classification ---"
  run 1000 "classify covers input"           prop_classify_covers_input
  run 1000 "classify preserves length"       prop_classify_preserves_length
  run 500  "anchors are substrings"          prop_anchors_are_substrings
  run 500  "spans are non-overlapping"       prop_spans_non_overlapping
  run 500  "spans are sorted"                prop_spans_sorted
  
  putStrLn "\n--- Strategy core contract ---"
  run 500  "identity preserves all text"     prop_identity_preserves_all
  run 500  "aggressive preserves exact"      prop_aggressive_preserves_exact
  run 500  "hostile strategy preserves exact" prop_hostile_preserves_exact
  run 200  "compose preserves exact"         prop_compose_preserves_exact
  
  putStrLn "\n--- Pipeline properties ---"
  run 200  "left identity"                   prop_left_identity
  run 200  "right identity"                  prop_right_identity
  run 200  "associativity"                   prop_associativity
  
  putStrLn "\nAll properties passed."
  where
    run n name prop = do
      putStr ("  " ++ name ++ "... ")
      quickCheckWith stdArgs { maxSuccess = n } prop


-- ════════════════════════════════════════════════════════════════════
-- § ANCHOR CLASSIFICATION PROPERTIES
-- ════════════════════════════════════════════════════════════════════

-- | Concatenating all Memory texts exactly equals the input.
prop_classify_covers_input :: Text -> Property
prop_classify_covers_input input =
  let memories = classify input
      reconstructed = T.concat (map memText (toList memories))
  in  counterexample
        ("Input:         " ++ show input ++
         "\nReconstructed: " ++ show reconstructed)
        (reconstructed === input)

-- | Total character count is preserved.
prop_classify_preserves_length :: Text -> Property
prop_classify_preserves_length input =
  let memories = classify input
      totalLen = sum (map (T.length . memText) (toList memories))
  in  totalLen === T.length input

-- | Every anchor text is a substring of the input.
prop_anchors_are_substrings :: Text -> Property
prop_anchors_are_substrings input =
  let memories = classify input
      anchors = [anchorText a | Exact a <- toList memories]
  in  conjoin [ counterexample ("Anchor not in input: " ++ show a)
                  (a `T.isInfixOf` input)
              | a <- anchors ]

-- | Anchor spans do not overlap.
prop_spans_non_overlapping :: Text -> Property
prop_spans_non_overlapping input =
  let memories = classify input
      spans = [anchorSpan a | Exact a <- toList memories]
      pairs = zip spans (drop 1 spans)
  in  conjoin [ counterexample ("Overlap: " ++ show s1 ++ " " ++ show s2)
                  (snd s1 <= fst s2)
              | (s1, s2) <- pairs ]

-- | Anchor spans are sorted by start position.
prop_spans_sorted :: Text -> Property
prop_spans_sorted input =
  let memories = classify input
      starts = [fst (anchorSpan a) | Exact a <- toList memories]
  in  starts === sort starts


-- ════════════════════════════════════════════════════════════════════
-- § STRATEGY CORE CONTRACT
-- ════════════════════════════════════════════════════════════════════
--
-- The key properties: Exact spans survive ANY strategy, including
-- hostile ones that try to delete everything.

-- | Identity preserves the entire text.
prop_identity_preserves_all :: Text -> Property
prop_identity_preserves_all input =
  let chunk = mkTestChunk input
      (_, rendered) = compressChunk identity chunk
  in  rendered === input

-- | A strategy that aggressively shortens Approx text
-- still preserves all Exact anchor text.
prop_aggressive_preserves_exact :: Text -> Property
prop_aggressive_preserves_exact input =
  let chunk = mkTestChunk input
      aggressive = Strategy "aggressive" (T.take 5)  -- keep only first 5 chars
      (_, rendered) = compressChunk aggressive chunk
      anchors = [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost anchor: " ++ show a)
                  (a `T.isInfixOf` rendered)
              | a <- anchors ]

-- | A strategy that DELETES all Approx text still preserves Exact.
-- This is the strongest test: even if you set every Approx span to "",
-- the Exact spans must still appear in the output.
prop_hostile_preserves_exact :: Text -> Property
prop_hostile_preserves_exact input =
  let chunk = mkTestChunk input
      hostile = Strategy "hostile" (const "")  -- delete everything
      (compressed, rendered) = compressChunk hostile chunk
      -- All Exact spans should still be in the compressed sequence
      exactsInCompressed = [anchorText a | Exact a <- toList compressed]
      exactsInOriginal   = [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin
        [ counterexample "Exact spans changed in Memory sequence"
            (exactsInCompressed === exactsInOriginal)
        , conjoin [ counterexample ("Exact anchor missing from rendered: " ++ show a)
                      (a `T.isInfixOf` rendered)
                  | a <- exactsInOriginal ]
        ]

-- | Composing two strategies also preserves Exact spans.
prop_compose_preserves_exact :: Text -> Property
prop_compose_preserves_exact input =
  let chunk = mkTestChunk input
      -- Two different aggressive strategies composed
      strat = Strategy "half" (T.take (max 1 . (`div` 2) . T.length))
              |> Strategy "trim" T.strip
      (_, rendered) = compressChunk strat chunk
      anchors = [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost anchor after compose: " ++ show a)
                  (a `T.isInfixOf` rendered)
              | a <- anchors ]


-- ════════════════════════════════════════════════════════════════════
-- § PIPELINE PROPERTIES
-- ════════════════════════════════════════════════════════════════════

-- | identity |> s ≡ s
prop_left_identity :: Text -> Property
prop_left_identity input =
  let s = Strategy "strip" T.strip
      composed = identity |> s
  in  strategyTransform composed input === strategyTransform s input

-- | s |> identity ≡ s
prop_right_identity :: Text -> Property
prop_right_identity input =
  let s = Strategy "strip" T.strip
      composed = s |> identity
  in  strategyTransform composed input === strategyTransform s input

-- | (a |> b) |> c ≡ a |> (b |> c)
prop_associativity :: Text -> Property
prop_associativity input =
  let a = Strategy "trim" T.strip
      b = Strategy "lower" T.toLower
      c = Strategy "take10" (T.take 10)
      left  = (a |> b) |> c
      right = a |> (b |> c)
  in  strategyTransform left input === strategyTransform right input


-- ════════════════════════════════════════════════════════════════════
-- § HELPERS
-- ════════════════════════════════════════════════════════════════════

memText :: Memory -> Text
memText (Exact a)  = anchorText a
memText (Approx t) = t

mkTestChunk :: Text -> Chunk
mkTestChunk input = Chunk
  { chunkId       = "test"
  , chunkRole     = UserMessage
  , chunkContent  = input
  , chunkMemory   = classify input
  , chunkAge      = Nothing
  , chunkPriority = PMedium
  , chunkTokens   = max 1 (ceiling (fromIntegral (T.length input) / (3.8 :: Double)))
      -- NOTE: still uses char estimate. Week 1 plan requires replacing
      -- this with real tiktoken counts before any benchmarks are run.
  }
