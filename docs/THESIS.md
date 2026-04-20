# Thesis: Faithful Context Compression with Typed Provenance

## Current Evidence (2026-04-07)

The repository is no longer at the "pure proposal" stage. Current live evidence supports a narrower claim than the original thesis draft:

- Systems result: the tokenizer/pipeline rewrite produced a measured `4.9x` local `--skip-eval` speedup and a measured `4.69x` end-to-end speedup on the paid OpenRouter path.
- Stable public matrix: on the 3-trial 5-model dev matrix (`3` docs per family, fixed Anthropic judge), `anchors-only` saved `64.2%` tokens but only reached `37.0%-46.9%` answer equivalence; `light-filler` reached `63.0%-90.1%` at `7.5%` reduction; `truncate-recent` reached up to `90.1%` at `24.8%` reduction.
- Larger-slice confirmation: on a follow-up run over `5` dev docs per family and `3` trials, using `qwen` and `grok` with an OpenRouter GPT judge, the same pattern held. `grok` led on quality (`light-filler 90.9%`, `truncate-recent 90.2%`, `no-compression 92.5%`) but took `1515.8s`; `qwen` was faster at `727.8s` with weaker quality (`light-filler 77.3%`, `truncate-recent 84.9%`, `no-compression 82.6%`). `anchors-only` remained weak for both (`44.7%-49.2%` at `62.2%` reduction).
- Current honest claim: the project now demonstrates a real performance result and useful auditability, but it does not yet justify a broad claim that aggressive exact/approx compression beats strong retention-heavy baselines on answer quality.

### Publication-Ready Results Snapshot

| Headline | Strongest current evidence | Why it matters |
|---|---|---|
| Systems result | `4.9x` local `--skip-eval` speedup and `4.69x` paid-path wall-clock speedup | The engineering claim is already defensible. |
| Best compressed quality | `grok + light-filler = 90.9%` answer equivalence at `6.4%` token reduction on the larger-slice follow-up | The current best implemented compressor can stay close to the retention-heavy baselines, but only with modest savings. |
| Best speed/quality tradeoff | `qwen + truncate-recent = 84.9% @ 18.2%` on the larger slice, and `qwen + truncate-recent = 90.1% @ 24.8%` on the 5-model matrix | The most practical public deployment point is a faster, retention-heavy method, not the aggressive extractor. |
| Hard-compression floor | `anchors-only = 44.7%-49.2%` at `62.2%` reduction on the larger-slice follow-up | Exact/approx separation alone is not enough; the current extractor misses too much. |
| Honest publication claim | Performance and auditability: `yes`. Broad quality superiority over strong baselines: `no`. | This is the claim the current evidence can support without overreach. |

If this becomes a paper or public report, this is the shortest faithful version of the results section: the pipeline is now fast and auditable, `light-filler` is the best current compressor, `qwen` is the best speed/quality tradeoff, and `anchors-only` is currently a useful failure floor rather than a publishable end method.

## The Claim

We are building and evaluating a context compression system for LLMs that separates context
into **exact memory** (anchors that must survive verbatim: numbers,
identifiers, code, negations, constraints, quoted commitments) and
**approximate memory** (background that may be compressed or dropped),
enforced by a typed data model with full provenance.

Current live results support the typed exact/approx boundary as an auditable design constraint, but they do not yet support a broad claim that aggressive compression preserves downstream answers across tasks.

The system is **extractive, not synthetic**: it compresses by selecting
and retaining natural-language tokens, not by inventing new notation.
It does not require the target LLM to interpret reference tables,
symbolic shorthand, or private-use Unicode. The compressed output is
ordinary text that any LLM reads without special training.

Compression policy is intended to adapt to **context role** (system prompt, user
message, assistant response, tool result, document) and **relevance**
(anchors, contradictions, unresolved tasks, and quoted commitments
override age-based defaults). At query time, a **selective expansion**
layer should re-expand compressed chunks relevant to the current question,
operating within a token budget. This remains the target architecture; the current public results cover only the earlier extractive strategies and baselines.

The current Haskell core provides:
- Type-level Exact|Approx boundary (no anchor is accidentally compressed)
- Provenance tracking (every chunk knows what strategy was applied)
- Anchor extraction via parser combinators (Megaparsec)
- Property-tested invariants (QuickCheck)
- A CLI-oriented compression pipeline with a persistent tokenizer bridge

The current product surface is a **CLI**. An HTTP sidecar remains a possible packaging layer, but it is not the current public artifact.

**What this is NOT:**
- Not a learned compression method (no fine-tuning required)
- Not a KV-cache compression method (operates on text, not tensors)
- Not a storage/transport codec (saves context-window tokens, not disk)
- Not a symbolic-language compressor (output is natural language)

---

## The Benchmark Matrix

Three task families, chosen to avoid building something that only wins
on a toy "needle" test:

### Family A: General Long-Context QA
- Datasets: LongBench subset, HotpotQA, NarrativeQA
- Tests: factual recall, multi-hop reasoning, summarization
- Why: the baseline case. If we fail here, nothing else matters.

### Family B: Tool/Schema/Code Tasks
- Datasets: API-call conversations, GitHub PR reviews, SQL-over-docs
- Tests: identifier preservation, parameter accuracy, code correctness
- Why: this is where anchor extraction must prove its value.
  Exact identifiers, function names, and config keys are the things
  naive compression destroys. Our hard guarantee lives here.

### Family C: Conversation/Agent Memory
- Datasets: Multi-turn agent traces, ShareGPT conversations
- Tests: selective expansion quality, commitment/constraint retention
- Why: this tests role-aware policy, relevance-based expansion,
  and the claim that old binding commitments override age defaults.

### Baselines (minimum set)
| ID | Method | What it tests |
|----|--------|---------------|
| B0 | No compression | Quality ceiling |
| B1 | Truncate-recent | The "dumb" baseline every method must beat |
| B2 | Top-K retrieval (embedding) | Standard RAG approach |
| B3 | LLMLingua-2 | Current SOTA hard-prompt compressor |

### Primary Metrics
| Metric | Measured by |
|--------|-------------|
| Token reduction % | tiktoken (cl100k_base), exact BPE count |
| Answer equivalence | LLM-as-judge (semantic match rate) |
| Anchor retention | Exact string match of extracted anchors |
| Critical fact F1 | Human-annotated must-retain facts |

### The Story We Can Tell Today

What the current evidence supports:

1. **A real systems win**: the Haskell/Python pipeline is now materially faster on both local and paid live paths.
2. **Auditable extractive compression**: extracted anchors are preserved structurally, provenance is tracked, and the output remains ordinary text.
3. **`light-filler` is the best implemented compressor today**: it is usually the strongest current compressed method, although its token savings are still modest.
4. **`anchors-only` alone is not enough**: the hard-compression variant remains too weak on answer equivalence to carry the thesis by itself.

What the current evidence does not yet support:

1. A broad quality-superiority claim over strong retention-heavy baselines.
2. The full role-aware/selective-expansion thesis.
3. A measured argument that Haskell itself is a research contribution rather than an implementation choice.

---

## Ablations That Would Falsify the Claim

Each ablation tests whether a specific component actually contributes.
If it does not, the component should be removed from the thesis.

### Ablation 1: Does exact/approx separation matter?
- **Compare:** Full pipeline WITH anchor preservation vs. the same
  pipeline with anchor extraction disabled (treat everything as Approx).
- **Falsified if:** Answer equivalence and critical fact F1 are
  statistically indistinguishable between the two.
- **Implication:** If anchors don't help, the typed boundary is
  aesthetic, not functional.

### Ablation 2: Does role-aware policy matter?
- **Compare:** Role-aware strategy selection vs. uniform strategy
  applied to all roles equally.
- **Falsified if:** The uniform strategy achieves the same compression
  ratio and answer quality across all three task families.
- **Implication:** If role doesn't matter, the adaptation is wasted
  complexity. (Note: we expect role to matter most in Family B and C,
  less in Family A.)

### Ablation 3: Does selective expansion matter?
- **Compare:** Static compressed context (no expansion) vs. query-aware
  selective expansion within the same token budget.
- **Falsified if:** Answer equivalence is the same with and without
  expansion.
- **Implication:** If expansion doesn't help, the archive layer is
  overhead.

### Ablation 4: Does relevance override age?
- **Compare:** Rigid age-based tiers (Hot/Warm/Cool/Cold) vs.
  relevance-weighted budget allocation where anchors and commitments
  override age.
- **Falsified if:** Rigid tiers match or beat relevance-weighted
  allocation on Family C tasks.
- **Implication:** If age alone is sufficient, the relevance override
  is unnecessary complexity.

### Ablation 5: Does Haskell buy anything measurable?
- **Compare:** The Haskell implementation vs. a Python reimplementation
  of the same algorithm.
- **Measure:** Property test coverage (do QuickCheck tests catch bugs
  the Python version misses?), peak memory on 128K contexts, latency.
- **Falsified if:** The Python version has equivalent correctness,
  memory, and speed.
- **Implication:** If Haskell provides no measurable advantage, the
  language choice is preference, not contribution.

---

## Current Decision Gate

The first decisive experiment has effectively been run in spirit, even if not yet as a publication-grade ablation table.

1. `anchors-only` demonstrates that exact/approx separation can compress very hard while preserving a subset of extracted anchors.
2. The same results also show that exact/approx separation by itself is not enough to preserve downstream answer quality.
3. The next thesis-critical step is therefore not "more anchors-only runs" but a balanced ablation showing where `light-filler`, stronger extraction, and selective expansion recover quality beyond retention-heavy baselines.

That is the experiment that now decides whether this becomes a paper claim or remains a strong systems-oriented repository.
