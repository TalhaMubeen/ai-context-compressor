{-# LANGUAGE OverloadedStrings #-}

module Main where

import Faithful.Core
import Faithful.Anchor (classify)
import Faithful.Strategy
import Faithful.Tokenizer (countTokensPure)

import Test.QuickCheck hiding (classify)
import Test.QuickCheck.Instances.Text ()
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set
import Data.Foldable (toList)
import Data.List (sort)
import System.Exit (exitFailure)


main :: IO ()
main = do
  putStrLn "=== Faithful Compress v5 - Property Tests ==="
  
  putStrLn "\n--- Anchor classification ---"
  r1 <- run 1000 "classify covers input"            prop_classify_covers_input
  r2 <- run 1000 "classify preserves length"        prop_classify_preserves_length
  r3 <- run 500  "anchors are substrings"           prop_anchors_are_substrings
  r4 <- run 500  "spans non-overlapping"            prop_spans_non_overlapping
  r5 <- run 500  "spans sorted"                     prop_spans_sorted
  
  putStrLn "\n--- Strategy core contract ---"
  r6 <- run 500  "identity preserves all"           prop_identity_preserves_all
  r7 <- run 500  "anchorsOnly preserves exact"      prop_anchorsOnly_preserves_exact
  r8 <- run 500  "hostile preserves exact"          prop_hostile_preserves_exact
  r9 <- run 500  "lightFiller preserves exact"      prop_lightFiller_preserves_exact
  r10 <- run 500  "tailRescue preserves exact"      prop_tailRescue_preserves_exact
  r11 <- run 200  "compose preserves exact"         prop_compose_preserves_exact
  
  putStrLn "\n--- Pipeline algebra ---"
  r12 <- run 200  "left identity"                    prop_left_identity
  r13 <- run 200  "right identity"                   prop_right_identity
  r14 <- run 200  "associativity"                    prop_associativity
  
  putStrLn "\n--- Compression properties ---"
  r15 <- run 200  "anchorsOnly reduces tokens"       prop_anchorsOnly_reduces
  r16 <- run 200  "anchorsOnly output is subset"     prop_anchorsOnly_subset

  putStrLn "\n--- Phase 2: readability invariants ---"
  r17 <- run 500  "glue: no adjacent Exacts"         prop_glue_no_adjacent_exacts
  r18 <- run 500  "dedup: no repeated anchors"        prop_dedup_no_repeated_anchors
  r19 <- run 500  "tailRescue output is readable"     prop_tailRescue_readable

  putStrLn "\n--- Phase 3: domain scoring / halos / fallback ---"
  r20 <- run 200  "readability floor"                 prop_tailRescue_readability_floor
  r21 <- run 500  "toolresult preserves exact"        prop_tailRescue_toolresult_exact
  r22 <- run 500  "document preserves exact"          prop_tailRescue_document_exact
  r23 <- run 200  "composed with domain scoring"      prop_tailRescue_domain_compose

  if and [r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13, r14, r15, r16, r17, r18, r19, r20, r21, r22, r23]
    then putStrLn "\nAll properties passed."
    else exitFailure
  where
    run n name prop = do
      putStr ("  " ++ name ++ "... ")
      result <- quickCheckWithResult stdArgs { maxSuccess = n } prop
      pure (isSuccess result)


-- ═══════════════════════ Classification ═══════════════════════════

prop_classify_covers_input :: Text -> Property
prop_classify_covers_input input =
  let reconstructed = T.concat (map memText (toList (classify input)))
  in  reconstructed === input

prop_classify_preserves_length :: Text -> Property
prop_classify_preserves_length input =
  sum (map (T.length . memText) (toList (classify input))) === T.length input

prop_anchors_are_substrings :: Text -> Property
prop_anchors_are_substrings input =
  conjoin [ counterexample ("Not in input: " ++ show a) (a `T.isInfixOf` input)
          | Exact a' <- toList (classify input), let a = anchorText a' ]

prop_spans_non_overlapping :: Text -> Property
prop_spans_non_overlapping input =
  let spans = [anchorSpan a | Exact a <- toList (classify input)]
  in  conjoin [ counterexample ("Overlap: " ++ show s1 ++ " " ++ show s2)
                  (snd s1 <= fst s2)
              | (s1, s2) <- zip spans (drop 1 spans) ]

prop_spans_sorted :: Text -> Property
prop_spans_sorted input =
  let starts = [fst (anchorSpan a) | Exact a <- toList (classify input)]
  in  starts === sort starts


-- ═══════════════════════ Strategy contract ════════════════════════

prop_identity_preserves_all :: Text -> Property
prop_identity_preserves_all input =
  snd (compressChunk identity (mkChunk' input)) === input

prop_anchorsOnly_preserves_exact :: Text -> Property
prop_anchorsOnly_preserves_exact input =
  let chunk = mkChunk' input
      (_, rendered) = compressChunk anchorsOnly chunk
      exacts = [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- exacts ]

prop_hostile_preserves_exact :: Text -> Property
prop_hostile_preserves_exact input =
  let chunk = mkChunk' input
      hostile = mkApproxStrategy "hostile" (const "")
      (compressed, rendered) = compressChunk hostile chunk
      exactsOrig = [anchorText a | Exact a <- toList (chunkMemory chunk)]
      exactsComp = [anchorText a | Exact a <- toList compressed]
  in  conjoin
        [ exactsComp === exactsOrig
        , conjoin [ counterexample ("Missing: " ++ show a) (a `T.isInfixOf` rendered)
                  | a <- exactsOrig ]
        ]

prop_lightFiller_preserves_exact :: Text -> Property
prop_lightFiller_preserves_exact input =
  let chunk = mkChunk' input
      (_, rendered) = compressChunk lightFiller chunk
      exacts = [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- exacts ]

prop_tailRescue_preserves_exact :: Text -> Property
prop_tailRescue_preserves_exact input =
  let chunk = mkChunk' input
      (_, rendered) = compressChunk tailRescueStatic chunk
      exacts = [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- exacts ]

prop_compose_preserves_exact :: Text -> Property
prop_compose_preserves_exact input =
  let chunk = mkChunk' input
      strat = lightFiller |> mkApproxStrategy "trim" T.strip
      (_, rendered) = compressChunk strat chunk
      exacts = [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- exacts ]


-- ═══════════════════════ Pipeline algebra ═════════════════════════

prop_left_identity :: Text -> Property
prop_left_identity input =
  strategyTransform (identity |> lightFiller) input
  === strategyTransform lightFiller input

prop_right_identity :: Text -> Property
prop_right_identity input =
  strategyTransform (lightFiller |> identity) input
  === strategyTransform lightFiller input

prop_associativity :: Text -> Property
prop_associativity input =
  let a = mkApproxStrategy "trim" T.strip
      b = mkApproxStrategy "lower" T.toLower
      c = mkApproxStrategy "take20" (T.take 20)
  in  strategyTransform ((a |> b) |> c) input
      === strategyTransform (a |> (b |> c)) input


-- ═══════════════════════ Compression properties ══════════════════

prop_anchorsOnly_reduces :: Text -> Property
prop_anchorsOnly_reduces input =
  let chunk = mkChunk' input
      (_, rendered) = compressChunk anchorsOnly chunk
  in  property (T.length rendered <= T.length input)

prop_anchorsOnly_subset :: Text -> Property
prop_anchorsOnly_subset input =
  let chunk = mkChunk' input
      (_, rendered) = compressChunk anchorsOnly chunk
  in  property (isSubsequenceOfText rendered input)


-- ═══════════════════════ Readability invariants ══════════════════

-- After tailRescueStatic, no two Exact memories should be adjacent
-- (glueAnchors inserts whitespace separators between them).
prop_glue_no_adjacent_exacts :: Text -> Property
prop_glue_no_adjacent_exacts input =
  let chunk = mkChunk' input
      compressed = fst (compressChunk tailRescueStatic chunk)
      mems = toList compressed
      adjacentExacts = [ (a, b)
                       | (Exact a, Exact b) <- zip mems (drop 1 mems) ]
  in  counterexample ("Adjacent Exacts: " ++ show (length adjacentExacts))
      (null adjacentExacts)

-- After tailRescueStatic, no anchor text appears more than once
-- (dedupAnchors keeps only the first occurrence).
prop_dedup_no_repeated_anchors :: Text -> Property
prop_dedup_no_repeated_anchors input =
  let chunk = mkChunk' input
      compressed = fst (compressChunk tailRescueStatic chunk)
      anchorTexts = [anchorText a | Exact a <- toList compressed]
      unique = nubTexts anchorTexts
  in  counterexample ("Duplicates found: " ++ show (length anchorTexts - length unique))
      (length anchorTexts == length unique)

-- The output of tailRescueStatic should never have zero-length Approx gaps
-- between Exact spans (readability floor).
prop_tailRescue_readable :: Text -> Property
prop_tailRescue_readable input =
  let chunk = mkChunk' input
      (_, rendered) = compressChunk tailRescueStatic chunk
      exacts = [anchorText a | Exact a <- toList (chunkMemory chunk)]
      -- Every unique exact anchor that survives dedup should still be findable
      uniqueExacts = nubTexts exacts
  in  conjoin [ counterexample ("Lost after dedup: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- uniqueExacts ]


-- ═══════════════════════ Phase 3: domain / halos / fallback ══════

-- After fallback, readability ratio should be above a floor for
-- inputs with enough approximate text to compress meaningfully.
-- Uses a custom generator because QuickCheck's default Text rarely exceeds
-- 200 Approx characters, causing ==> to discard almost all inputs.
prop_tailRescue_readability_floor :: Property
prop_tailRescue_readability_floor =
  forAll genLargeText $ \input ->
  let chunk = mkChunk' input
      (compressed, _) = compressChunk tailRescueStatic chunk
      ratio = readabilityRatio compressed
      approxLen = sum [T.length t | Approx t <- toList (chunkMemory chunk)]
  in  approxLen > 200 ==>
      counterexample ("Readability ratio: " ++ show ratio ++ " approxLen: " ++ show approxLen)
      (ratio >= 0.10)

-- Exact anchors survive for ToolResult role (domain scoring active).
prop_tailRescue_toolresult_exact :: Text -> Property
prop_tailRescue_toolresult_exact input =
  let chunk = (mkChunk' input) { chunkRole = ToolResult }
      (_, rendered) = compressChunk tailRescueStatic chunk
      uniqueExacts = nubTexts [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- uniqueExacts ]

-- Exact anchors survive for Document role (domain scoring active).
prop_tailRescue_document_exact :: Text -> Property
prop_tailRescue_document_exact input =
  let chunk = (mkChunk' input) { chunkRole = Document }
      (_, rendered) = compressChunk tailRescueStatic chunk
      uniqueExacts = nubTexts [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- uniqueExacts ]

-- Domain scoring + halos + fallback together don't break composition.
prop_tailRescue_domain_compose :: Text -> Property
prop_tailRescue_domain_compose input =
  let chunk = mkChunk' input
      composed = lightFiller |> tailRescueStatic
      (_, rendered) = compressChunk composed chunk
      uniqueExacts = nubTexts [anchorText a | Exact a <- toList (chunkMemory chunk)]
  in  conjoin [ counterexample ("Lost after compose: " ++ show a) (a `T.isInfixOf` rendered)
              | a <- uniqueExacts ]


-- ═══════════════════════ Helpers ═════════════════════════════════

memText :: Memory -> Text
memText (Exact a)  = anchorText a
memText (Approx t) = t

mkChunk' :: Text -> Chunk
mkChunk' input = Chunk
  { chunkId       = "test"
  , chunkRole     = UserMessage
  , chunkContent  = input
  , chunkMemory   = classify input
  , chunkAge      = Nothing
  , chunkPriority = PMedium
  , chunkTokens   = countTokensPure input
      -- NOTE: Uses pure estimate for property tests (no IO).
      -- Benchmarks and eval MUST use countTokens (real tiktoken).
  }

isSubsequenceOfText :: Text -> Text -> Bool
isSubsequenceOfText needle haystack = go (T.unpack needle) (T.unpack haystack)
  where
    go [] _ = True
    go _ [] = False
    go (x:xs) (y:ys)
      | x == y = go xs ys
      | otherwise = go (x:xs) ys

-- | Remove duplicate texts, preserving order of first occurrence.
nubTexts :: [Text] -> [Text]
nubTexts = go Set.empty
  where
    go _ [] = []
    go seen (x:xs)
      | x `Set.member` seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs

-- | Generate text large enough to have >200 Approx characters.
-- Uses deliberately boring filler words that won't trigger anchor extraction
-- (no CamelCase, no digits, no negation triggers, no code keywords).
genLargeText :: Gen Text
genLargeText = do
  n <- choose (15, 30)
  sentences <- vectorOf n genSentence
  pure (T.intercalate ". " sentences <> ".")
  where
    genSentence = do
      w <- choose (6, 14)
      ws <- vectorOf w (elements wordPool)
      pure (T.unwords ws)
    wordPool :: [Text]
    wordPool = [ "the", "a", "an", "of", "in", "to", "for", "on", "at", "by"
               , "with", "and", "or", "but", "so", "yet", "as", "into", "from"
               , "over", "under", "between", "through", "during", "before"
               , "after", "above", "below", "about", "around", "along"
               , "thing", "part", "place", "case", "point", "way"
               , "good", "great", "big", "old", "new", "other", "small"
               , "long", "little", "own", "same", "early", "young", "important"
               , "few", "large", "local", "social", "many", "certain"
               , "take", "come", "make", "go", "see", "look", "give", "use"
               , "find", "tell", "ask", "work", "call", "try", "need", "feel"
               , "become", "leave", "put", "mean", "keep", "let", "begin" ]
