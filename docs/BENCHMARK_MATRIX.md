# Benchmark Matrix

This file defines what we measure, how we measure it, and what "winning" looks like.
**Read this before writing any compression code.**

This document started as the benchmark plan. The sections below still describe the target matrix, but the repository now has real live results on a smaller public dev slice. Treat the snapshot below as the authoritative current status.

---

## Current Snapshot (2026-04-06)

Scope of the current measured run:

- Datasets: `D1_longbench_qa`, `D4_code`, `D6_policy_legal`, `D7_chat`
- Slice: `--split dev --max-docs-per-family 3`
- Questions: `27` total, run for `3` trials each
- Judge: fixed `claude-haiku-4-5`
- Answer models: OpenRouter `anthropic/claude-3.5-haiku`, `openai/gpt-4o-mini`, `x-ai/grok-3-mini`, `qwen/qwen-turbo`, `google/gemini-2.0-flash-001`

Pipeline performance after the tokenizer and orchestration rewrite:

- Local `--skip-eval` dev slice: `4.900s -> 1.003s` (`4.9x` faster)
- Full paid dev slice with OpenRouter `gpt-4o-mini`: `613.160s -> 130.856s` (`4.69x` faster)

Stable public 3-trial matrix (`answer equivalence @ token reduction`):

| Answer model | Runtime (3 trials) | Anchors-only | Light-filler | Truncate-recent | No-compression |
|---|---:|---:|---:|---:|---:|
| gemini | `232.5s` | `37.0% @ 64.2%` | `63.0% @ 7.5%` | `67.9% @ 24.8%` | `71.6%` |
| qwen | `240.1s` | `43.2% @ 64.2%` | `83.9% @ 7.5%` | `90.1% @ 24.8%` | `92.6%` |
| gpt | `279.6s` | `42.0% @ 64.2%` | `72.8% @ 7.5%` | `77.8% @ 24.8%` | `74.1%` |
| claude | `404.3s` | `38.3% @ 64.2%` | `77.8% @ 7.5%` | `80.3% @ 24.8%` | `81.5%` |
| grok | `1036.0s` | `46.9% @ 64.2%` | `90.1% @ 7.5%` | `80.3% @ 24.8%` | `91.3%` |

Current interpretation:

- `anchors-only` is not yet ready for a broad quality claim. It compresses aggressively, but on this stable matrix it only reaches `37.0%-46.9%` answer equivalence.
- `light-filler` is the best implemented compressor today, but its savings are still modest at `7.5%` on this slice.
- `qwen` is the strongest current speed/quality tradeoff. `grok` is often strongest on quality, but it is roughly `4x` slower than the `qwen` and `gemini` runs.
- The type-level design still preserves extracted anchors by construction, but current end-to-end anchor retention is well below the original goal because extractor recall is incomplete.

Artifacts for this snapshot live under `results/public-model-matrix-t3/*/eval/benchmark-summary.md` and `results/dev3-openrouter-live-opt`.

### Larger-Slice Confirmation (2026-04-07)

Follow-up scope:

- Answer models: `qwen/qwen-turbo` and `x-ai/grok-3-mini`
- Judge: `openrouter:openai/gpt-4o-mini`
- Slice: `--split dev --max-docs-per-family 5`
- Trials: `3`
- Results root: `results/public-model-confirmation-m5-t3-gptjudge`

This follow-up used a different judge from the 5-model matrix because the Anthropic account used for the earlier fixed judge ran out of credits mid-rerun. The slice is also not family-balanced in question count: `D6_policy_legal` contributes `87` of the `132` total question-trial rows, so treat this as a confirmation pass, not as a replacement for the cross-model matrix above.

Weighted overall follow-up summary:

| Answer model | Runtime | Anchors-only | Light-filler | Truncate-recent | No-compression |
|---|---:|---:|---:|---:|---:|
| qwen | `727.8s` | `44.7% @ 62.2%` | `77.3% @ 6.4%` | `84.9% @ 18.2%` | `82.6%` |
| grok | `1515.8s` | `49.2% @ 62.2%` | `90.9% @ 6.4%` | `90.2% @ 18.2%` | `92.5%` |

What changed and what did not:

- The same high-level conclusion held: `anchors-only` still compresses hard but is not good enough on answer quality.
- `grok` again led on quality, especially for `light-filler`, but it was about `2.1x` slower than `qwen`.
- `qwen` remained the better speed/quality tradeoff if latency matters more than squeezing out the last quality points.

## Datasets

Organized into three task families to avoid building something that
only wins on a single test type.

For a concrete sourcing and curation workflow, see `docs/DATASET_SOURCING.md`.

### Family A: General Long-Context QA
| ID | Name | Source | Tokens (approx) | Why It Matters |
|----|------|--------|-----------------|----------------|
| D1 | `longbench-qa` | LongBench subset (50 examples) | 4K–32K | Standard long-context QA benchmark. If we fail here, nothing else matters. |
| D2 | `rag-passages` | Wikipedia + curated Q&A contexts (100 examples) | 4K–16K | RAG is the #1 use case for context compression. Lots of background, few anchors. |
| D3 | `adversarial` | Dense technical writing, no repetition (20 passages) | 2K–8K | Lower bound. This is where we prove the floor. |

### Family B: Tool/Schema/Code Tasks
| ID | Name | Source | Tokens (approx) | Why It Matters |
|----|------|--------|-----------------|----------------|
| D4 | `code-review` | GitHub PR threads (30 PRs with inline comments) | 3K–20K | Code spans are exact anchors. Comments are compressible. |
| D5 | `tool-results` | Synthetic API/tool call JSON responses (40 examples) | 1K–10K | Structured data. Identifier and parameter preservation is critical. |
| D6 | `policy-legal` | Terms of service, contracts, compliance docs (15) | 4K–20K | Anchor-heavy (dates, amounts, obligations). Where anchor extraction must prove its value. |

### Family C: Conversation/Agent Memory
| ID | Name | Source | Tokens (approx) | Why It Matters |
|----|------|--------|-----------------|----------------|
| D7 | `chat-multiturn` | ShareGPT (50 conversations, 5-30 turns each) | 2K–30K | Tests role-aware policy and relevance-based expansion. |
| D8 | `agent-traces` | Multi-turn agent traces with tool calls (20 traces) | 8K–64K | Tests commitment retention across long agent runs. Old binding constraints must survive. |
| D9 | `mixed-context` | Full context windows: system + user + assistant + tools (20) | 16K–128K | End-to-end realistic context. The real test. |

### Dataset Preparation Rules

- All datasets stored as JSONL with schema: `{"id": str, "role": str, "content": str, "meta": {}}`
- Role field: `system | user | assistant | tool_result | document`
- Token counts verified with `tiktoken` (cl100k_base) — NOT character estimates
- Each dataset has a companion `_questions.jsonl`: downstream tasks to measure quality

---

## Methods

| ID | Method | Type | Description |
|----|--------|------|-------------|
| M0 | `no-compression` | Baseline | Full original context. Upper bound on quality, lower bound on savings. |
| M1 | `truncate-recent` | Baseline | Keep last N tokens, drop the rest. The "dumb" baseline. |
| M2 | `top-k-retrieval` | Baseline | Embed question, retrieve top-K chunks by cosine similarity. |
| M3 | `naive-summary` | Baseline | One LLM call to summarize entire context. Expensive but common. |
| M4 | `chunk-summary` | Baseline | Split into chunks, summarize each, concatenate. |
| M5 | `llmlingua` | SOTA | Microsoft LLMLingua-2. The benchmark to beat on quality. |
| M6 | `structural` | Ours | Filler removal + symbolic notation only. |
| M7 | `entity-ref` | Ours | Entity Reference Table compression only. |
| M8 | `anchors-only` | Ours | Exact anchor extraction (numbers, identifiers, quotes, code, negations). |
| M9 | `anchors+structural` | Ours | M8 → M6 pipeline. |
| M10 | `full-pipeline` | Ours | Anchors → Structural → Entity Ref → Semantic Priority. |
| M11 | `role-aware` | Ours | Different strategy per context role (the novel contribution). |
| M12 | `tiered-recency` | Ours | Age-based compression tiers (the second novel contribution). |
| M13 | `adaptive` | Ours | Role-aware + tiered recency combined. The flagship compressor. |
| M14 | `adaptive+expand-kw` | Ours | M13 with selective expansion via keyword relevance scoring. |
| M15 | `adaptive+expand-anchor` | Ours | M13 with selective expansion via anchor overlap scoring. |
| M16 | `adaptive+expand-embed` | Ours | M13 with selective expansion via embedding similarity (Python bridge). |

Note: M14–M16 are the **selective expansion** variants (Layer 4).
These are query-aware: they compress aggressively then re-expand chunks
relevant to the current question. This is the 4th novel contribution.

---

## Metrics

### Primary (these decide if we publish)

| Metric | How Measured | Hypothesis (to be validated) |
|--------|-------------|------------------------------|
| **Token Reduction %** | `1 - (compressed_tokens / original_tokens)` via tiktoken | We expect 20–40% on D1/D2/D6. Actual range will emerge from experiments. |
| **Answer Equivalence** | LLM answers same question with original vs compressed context. Judge with GPT-4o or human eval. Score: exact match, semantic match, or degraded. | Target remains ≥85% semantic match. Current public dev results show that only retention-heavy baselines and the best `light-filler` runs approach that threshold consistently. |
| **Anchor Retention** | Extract all numbers, identifiers, quoted strings, code spans, negations from original. Check presence in compressed output. | Target is 100% for extracted anchors. Current public dev results are materially lower end-to-end, which means extractor recall is still incomplete even though extracted anchors are preserved structurally. |

### Secondary (these decide if we're competitive)

| Metric | How Measured | Hypothesis (to be validated) |
|--------|-------------|------------------------------|
| **Compression Latency** | Wall clock time for compression, measured via Criterion | Expected <100ms for 10K tokens. Actual will depend on anchor extraction cost. |
| **Decompression Latency** | Wall clock for reversible modes (ERT) | Expected <10ms. |
| **Peak Memory** | Max RSS during compression of D6 (128K tokens) | Expected <200MB with streaming. |
| **ROUGE-L** | Between original and compressed text (for non-exact modes) | Baseline expectation ≥0.65 for M10–M13. |
| **Critical Fact F1** | Manually annotated "must-retain" facts per dataset. Precision/recall of retention. | Anchor-preserving modes should achieve ≥0.95. |
| **BPE Efficiency** | Ratio of token reduction to character reduction. >1.0 means we're BPE-friendly. | Expected >0.85. If below, our compression is fighting the tokenizer. |

### Diagnostic (these help us debug)

| Metric | Purpose |
|--------|---------|
| Compression ratio by role | Does system prompt compress more than user messages? |
| Compression ratio by age | Does tiered recency actually help? |
| Anchor type distribution | Which anchor types dominate which datasets? |
| Strategy selection frequency | In adaptive mode, which strategy wins most often? |
| Failure cases | Collect all examples where answer equivalence < semantic match |
| Expansion confidence calibration | Does HighConfidence actually correlate with higher answer equivalence? |
| Expansion rate by query type | Which query types trigger the most chunk expansion? |
| Budget utilization | What % of token budget is actually used in budgeted expansion? |

---

## Evaluation Protocol

### Answer Equivalence (the make-or-break metric)

```
For each (dataset, question) pair:
  1. Send original context + question to target LLM → answer_original
  2. Send compressed context + question to target LLM → answer_compressed
  3. Send both answers to judge LLM:
     "Given this question and reference answer, is the candidate answer
      (a) exactly equivalent, (b) semantically equivalent, (c) degraded, (d) wrong?"
  4. Record: exact_match_rate, semantic_match_rate, degradation_rate, error_rate
```

**Target LLMs for evaluation:** Claude Sonnet, GPT-4o-mini, Llama-3-70B (at least two)
**Judge LLM:** GPT-4o (or Claude Opus if available)
**Trials:** 3 runs per method×dataset×question to measure variance

### Anchor Retention (the hard guarantee)

```
For each document:
  1. Extract anchors: numbers, identifiers, quoted strings, code blocks, negations
  2. Compress document
  3. For each anchor:
     - Check: is anchor present verbatim in compressed output?
     - If not: is anchor recoverable from decompression?
  4. Report: anchor_retention_rate (must be 1.0 for exact modes)
```

### Latency Protocol

- Warm up: 10 iterations discarded
- Measured: 100 iterations via Criterion
- Report: mean, std, p50, p99
- Machine: document exact CPU, RAM, GHC version

---

## Results Table Template

When benchmarks run, produce this exact table:

```
| Dataset | Method       | Tokens_orig | Tokens_comp | Reduction% | Answer_Equiv% | Anchor_Ret% | Latency_ms | Memory_MB |
|---------|------------- |-------------|-------------|------------|----------------|-------------|------------|-----------|
| D1      | no-compress  | 12,450      | 12,450      | 0.0%       | 100.0%         | 100.0%      | 0          | 0         |
| D1      | truncate     | 12,450      | 4,096       | 67.1%      | 62.3%          | 41.0%       | 0          | 0         |
| D1      | llmlingua    | 12,450      | 7,200       | 42.2%      | 91.5%          | 87.0%       | 2,340      | 1,200     |
| D1      | adaptive     | 12,450      | 7,800       | 37.3%      | 94.1%          | 100.0%      | 45         | 85        |
```

The original target story was: **comparable compression to LLMLingua, 100% anchor retention, 50x faster (no LLM call needed), and 10x less memory.** Current measured results do not support that full claim yet; use the snapshot above as the honest state of the project.

---

## Week 1 Milestone

Before ANY strategy code is written:

- [ ] D1, D4, D7 datasets curated (minimum viable corpus)
- [ ] Question sets for D1, D4, D7 written (5 questions per document)
- [ ] Anchor extractor working (numbers, identifiers, quotes, code, negations)
- [ ] Baseline M0, M1 measured
- [ ] Token counter using real tiktoken (not char/3.8 estimate)
- [ ] Results table pipeline: dataset in → CSV row out
- [ ] All metrics computed end-to-end for at least one dataset × one method
