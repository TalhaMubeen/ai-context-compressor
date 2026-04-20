{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : Faithful.Core
-- Description : Core types for faithful context compression
-- 
-- The central design decision: every piece of context is classified as
-- either 'Exact' (must survive compression verbatim) or 'Approx'
-- (can be compressed, summarized, or dropped).
--
-- The boundary is enforced at the strategy layer:
-- simple strategies receive only Approx spans via 'ApproxTransform' (Text -> Text),
-- while chunk-aware strategies still return 'Seq Memory' so Exact spans remain
-- explicit and auditable. See "Faithful.Strategy" for the contract.

module Faithful.Core
  ( -- * The Exact/Approximate boundary
    Memory(..)
  , Anchor(..)
  , AnchorType(..)
    
    -- * Context structure
  , ContextRole(..)
  , Chunk(..)
  , Priority(..)
    
    -- * Compressed representation
  , CompressedContext(..)
  , Token(..)
  , RefTable
  , Provenance(..)
    
    -- * Smart constructors
  , mkExact
  , mkApprox
  , mkChunk
    
    -- * Queries
  , anchorsOf
  , isExact
  , originalTokens
  , compressedTokens
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.HashMap.Strict (HashMap)
import Data.Sequence (Seq)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Control.DeepSeq (NFData)


-- ════════════════════════════════════════════════════════════════════
-- § THE EXACT / APPROXIMATE BOUNDARY
-- ════════════════════════════════════════════════════════════════════
--
-- This is the key type. A Memory value is either:
--   Exact anchor  → guaranteed to appear verbatim in compressed output
--   Approx text   → may be compressed, summarized, or dropped
--
-- There is no third option. Every token must be classified.

-- | A piece of memory that is either exactly preserved or approximately compressed.
data Memory
  = Exact Anchor        -- ^ Must survive compression verbatim
  | Approx Text         -- ^ Can be compressed or dropped
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (NFData)

-- | An anchor is a piece of text with a classification.
-- The text field is the *exact original bytes* — never modified.
data Anchor = Anchor
  { anchorType :: AnchorType
  , anchorText :: Text              -- ^ The exact original text. Immutable.
  , anchorSpan :: {-# UNPACK #-} !(Int, Int) -- ^ Character offset (start, end) in original
  } deriving stock (Show, Eq, Ord, Generic)
    deriving anyclass (NFData)

-- | Classification of anchors.
-- These are the things that, if lost, cause factual errors in LLM output.
data AnchorType
  = ANumber          -- ^ Numeric values: prices, dates, counts, percentages
  | AIdentifier      -- ^ IDs, SKUs, model names, variable names, URLs
  | AQuotedString    -- ^ Anything in quotes — direct speech, string literals
  | ACodeSpan        -- ^ Code blocks, inline code, commands
  | ANegation        -- ^ "not", "never", "don't", "cannot" — flipping these is catastrophic
  | AConstraint      -- ^ "must", "shall", "required", "at least", "no more than"
  | AProperNoun      -- ^ Named entities: people, places, organizations
  | AHeading         -- ^ Section titles, headings, title-case document labels
  | AField           -- ^ Key: value style fields and metadata lines
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving anyclass (NFData)


-- ════════════════════════════════════════════════════════════════════
-- § CONTEXT STRUCTURE
-- ════════════════════════════════════════════════════════════════════

-- | The role of a context chunk. Different roles get different compression.
data ContextRole
  = SystemPrompt         -- ^ Compress aggressively (rarely changes)
  | UserMessage          -- ^ Preserve intent, strip filler
  | AssistantResponse    -- ^ High entity repetition, ERT works well
  | ToolResult           -- ^ Structured data, n-gram/structural compression
  | Document             -- ^ RAG passages, reference material
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving anyclass (NFData)

-- | Semantic priority for compression decisions.
data Priority = PHigh | PMedium | PLow
  deriving stock (Show, Eq, Ord, Enum, Bounded, Generic)
  deriving anyclass (NFData)

-- | A chunk of context with full provenance.
data Chunk = Chunk
  { chunkId       :: Text            -- ^ Unique identifier
  , chunkRole     :: !ContextRole    -- ^ What kind of context this is
  , chunkContent  :: Text            -- ^ The raw text
  , chunkMemory   :: Seq Memory      -- ^ Classified as Exact/Approx spans
  , chunkAge      :: !(Maybe UTCTime) -- ^ When this chunk was created (for tiered recency)
  , chunkPriority :: !Priority       -- ^ Computed importance score
  , chunkTokens   :: {-# UNPACK #-} !Int -- ^ BPE token count (measured, not estimated)
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (NFData)


-- ════════════════════════════════════════════════════════════════════
-- § COMPRESSED REPRESENTATION
-- ════════════════════════════════════════════════════════════════════
--
-- DESIGN NOTE (informed by literature review):
--
-- The primary compression mode is EXTRACTIVE: we select and retain
-- natural-language tokens from the original text. The output is
-- ordinary text that any LLM reads without special training.
--
-- The hard prompt compression literature shows that methods keeping
-- natural-language tokens work with closed API models and require
-- no retraining. Synthetic approaches (reference tables, symbolic
-- shorthand, private-use Unicode) require the model to interpret
-- notation it was not trained on, which is unreliable.
--
-- TRef and TSymbol are retained as OPTIONAL modes for specific use
-- cases (storage/caching, not model-facing compression). They should
-- NOT be used in the default pipeline.

-- | A token in the compressed stream.
data Token
  = TLiteral Text            -- ^ Retained natural-language text (primary mode)
  | TAnchorMarker AnchorType -- ^ Marks the start of an exact anchor
  | TPriorityTag Priority    -- ^ [H], [M], [L] — for selective expansion
  -- Optional synthetic modes (for storage/caching only, NOT model-facing):
  | TRef Char                -- ^ §A, §B — pointer into RefTable (storage only)
  | TSymbol Text             -- ^ Structural shorthand (storage only)
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (NFData)

-- | Entity reference table: short token → full entity text.
-- Used only in storage/caching mode, not in model-facing compression.
type RefTable = HashMap Text Text

-- | Provenance: what happened to this chunk during compression.
-- This is what makes the system auditable.
data Provenance = Provenance
  { provStrategy    :: Text                    -- ^ Which strategy was applied
  , provOrigTokens  :: {-# UNPACK #-} !Int     -- ^ Token count before compression
  , provCompTokens  :: {-# UNPACK #-} !Int     -- ^ Token count after compression
  , provAnchorsKept :: {-# UNPACK #-} !Int     -- ^ Number of exact anchors preserved
  , provAnchorsTotal:: {-# UNPACK #-} !Int     -- ^ Total anchors in original
  , provTimestamp   :: !UTCTime                 -- ^ When compression happened
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (NFData)

-- | The compressed context. Self-describing, auditable, decompressible.
data CompressedContext = CompressedContext
  { ccChunks     :: Seq (Seq Token, Provenance)     -- ^ Compressed chunks with provenance
  , ccRefTable   :: RefTable                         -- ^ Shared entity reference table
  , ccAnchors    :: Seq Anchor                       -- ^ All extracted anchors (for verification)
  , ccOrigTokens :: {-# UNPACK #-} !Int              -- ^ Total original token count
  , ccCompTokens :: {-# UNPACK #-} !Int              -- ^ Total compressed token count
  } deriving stock (Show, Eq, Generic)
    deriving anyclass (NFData)


-- ════════════════════════════════════════════════════════════════════
-- § SMART CONSTRUCTORS
-- ════════════════════════════════════════════════════════════════════

-- | Mark text as an exact anchor. The text will never be modified.
mkExact :: AnchorType -> Text -> (Int, Int) -> Memory
mkExact atype txt span' = Exact (Anchor atype txt span')

-- | Mark text as approximate — available for compression.
mkApprox :: Text -> Memory
mkApprox = Approx

-- | Create a chunk with automatic memory classification.
-- (The actual classification is done by Faithful.Anchor.classify)
mkChunk :: Text -> ContextRole -> Maybe UTCTime -> Int -> Seq Memory -> Chunk
mkChunk cid role time tokens mem = Chunk
  { chunkId       = cid
  , chunkRole     = role
  , chunkContent  = renderMemory mem
  , chunkMemory   = mem
  , chunkAge      = time
  , chunkPriority = PMedium  -- default; overridden by Semantic strategy
  , chunkTokens   = tokens
  }
  where
    renderMemory = T.concat . fmap memText . toList'
    memText (Exact a)  = anchorText a
    memText (Approx t) = t
    toList' = foldr (:) []


-- ════════════════════════════════════════════════════════════════════
-- § QUERIES
-- ════════════════════════════════════════════════════════════════════

-- | Extract all exact anchors from a chunk.
anchorsOf :: Chunk -> [Anchor]
anchorsOf = foldr go [] . chunkMemory
  where
    go (Exact a) acc = a : acc
    go _         acc = acc

-- | Check if a Memory value is exact.
isExact :: Memory -> Bool
isExact (Exact _) = True
isExact _         = False

-- | Total original tokens across all chunks.
originalTokens :: CompressedContext -> Int
originalTokens = ccOrigTokens

-- | Total compressed tokens.
compressedTokens :: CompressedContext -> Int
compressedTokens = ccCompTokens
