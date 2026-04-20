# faithful-compress

**Faithful context compression for LLMs.**

Designed to preserve exact anchors while compressing background aggressively. Role-aware and relevance-aware. Typed provenance. Property-tested classification invariants.

---

## What this is

A Haskell library exploring context compression for LLMs with a core design principle: separate context into **exact memory** (anchors that must survive verbatim) and **approximate memory** (background that may be compressed or dropped).

Compression strategies operate only on approximate spans. Exact spans are preserved by construction — the strategy interface makes it structurally impossible to modify an anchor.

Unlike LLM-based compressors (LLMLingua, etc.), this requires no inference call. The compressed output is extractive: it retains natural-language tokens from the original, not synthetic notation.

## Status

🔬 **Research stage / design prototype.** The core data model, anchor extractor, strategy interface, and evaluation harness exist. Compression strategies beyond identity are not yet implemented. Benchmarks have not been run. **Do not use in production.**

The first milestone is to answer: *"Does exact/approx separation actually preserve downstream answers better than dumb baselines?"*

See [`docs/THESIS.md`](docs/THESIS.md) for the research claim and falsification ablations.
See [`docs/BENCHMARK_MATRIX.md`](docs/BENCHMARK_MATRIX.md) for the evaluation plan.
See [`docs/WEEK1_PLAN.md`](docs/WEEK1_PLAN.md) for the concrete first-week implementation plan.

## Design ideas (under evaluation)

**Exact vs. approximate memory.** Every span of context is classified as either an exact anchor (numbers, identifiers, code, quotes, negations, constraints) or approximate background. The strategy interface enforces this: strategies receive only Approx spans and return compressed text. Exact spans flow through untouched.

**Role-aware compression.** Different context roles (system prompt, user message, assistant response, tool result) may benefit from different compression strategies. This is a hypothesis to be tested, not a proven result.

**Relevance-weighted budget allocation.** Age affects default compression budget, but anchor density and constraint content can override age. A cold chunk full of binding commitments gets more budget than a hot chunk of filler.

**Selective expansion.** Archive originals alongside compressed versions. At query time, re-expand chunks relevant to the current question within a token budget.

**Typed provenance.** Every compressed chunk carries metadata: source, strategy applied, anchors extracted. Enables auditing and debugging.

## What this is NOT

- Not a learned compression method (no fine-tuning required)
- Not a KV-cache compression method (operates on text, not tensors)
- Not a storage/transport codec (targets context-window tokens, not disk)
- Not a symbolic-language compressor (output is natural language)
- Not yet benchmarked or validated

## Building

```bash
cabal build
cabal test        # QuickCheck classification properties
```

## Current project structure

```
src/Faithful/
  Core.hs           -- Memory (Exact | Approx), Anchor, Chunk, Provenance
  Anchor.hs         -- Anchor extraction (numbers, IDs, quotes, code, negations)
  Strategy.hs       -- Strategy type (Approx-only transform), combinators
  Expansion.hs      -- Selective expansion engine (WIP)

test/
  Properties.hs     -- QuickCheck: classification coverage, anchor preservation

scripts/
  eval.py           -- Answer equivalence evaluation harness

docs/
  THESIS.md         -- Research claim + falsification ablations
  BENCHMARK_MATRIX.md -- Datasets, methods, metrics
  WEEK1_PLAN.md     -- First-week implementation plan
```

## License

BSD-3-Clause
