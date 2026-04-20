# Project Status Matrix (Realistic + Performance + Benchmarking)

_Last updated: 2026-04-20_

This is the current, honest status snapshot for the repository after the root-level restructure.

## 1) Realistic Matrix (public 5-model, 3 trials, dev slice)

Scope: D1/D4/D6/D7, 27 total questions, fixed judge (`claude-haiku-4-5`).

| Answer model | Runtime (3 trials) | Anchors-only | Light-filler | Truncate-recent | No-compression |
|---|---:|---:|---:|---:|---:|
| gemini | 232.5s | 37.0% @ 64.2% | 63.0% @ 7.5% | 67.9% @ 24.8% | 71.6% |
| qwen | 240.1s | 43.2% @ 64.2% | 83.9% @ 7.5% | 90.1% @ 24.8% | 92.6% |
| gpt | 279.6s | 42.0% @ 64.2% | 72.8% @ 7.5% | 77.8% @ 24.8% | 74.1% |
| claude | 404.3s | 38.3% @ 64.2% | 77.8% @ 7.5% | 80.3% @ 24.8% | 81.5% |
| grok | 1036.0s | 46.9% @ 64.2% | 90.1% @ 7.5% | 80.3% @ 24.8% | 91.3% |

## 2) Performance Matrix

### Runtime + pipeline speedup

| Scenario | Before | After | Speedup |
|---|---:|---:|---:|
| Local `--skip-eval` dev slice | 4.900s | 1.003s | 4.9x |
| Paid dev slice (`gpt-4o-mini`) | 613.160s | 130.856s | 4.69x |

### Confirmation slice (max-docs-per-family=5, 3 trials, GPT judge)

| Model | Runtime | Anchors-only | Light-filler | Truncate-recent | No-compression |
|---|---:|---:|---:|---:|---:|
| qwen | 727.8s | 44.7% @ 62.2% | 77.3% @ 6.4% | 84.9% @ 18.2% | 82.6% |
| grok | 1515.8s | 49.2% @ 62.2% | 90.9% @ 6.4% | 90.2% @ 18.2% | 92.5% |

## 3) Benchmarking Scorecard (what we achieved)

From `results/eval/benchmark-summary.md` (current dev slices):

- **Anchors-only**
  - Strength: highest token reduction (typically ~56% to ~81%).
  - Weakness: answer-equivalence and anchor retention are still too low for deployment claims.
- **Light-filler**
  - Strength: strongest current quality/safety profile among implemented compression methods.
  - Weakness: token savings are modest (often low single digits).
- **Tail-rescue / truncate-recent**
  - Useful baseline comparators, but not consistently superior to light-filler on quality-risk tradeoffs.

## 4) What’s achieved ✅

- Root-level benchmark harness and reporting artifacts are now structured for direct execution from repository root.
- Measured, reproducible public matrix exists across multiple answer models.
- Concrete runtime gains are demonstrated (~4.7x to ~4.9x pipeline speedup in measured runs).
- We have a clear practical tradeoff map:
  - `qwen`: best speed/quality balance in current runs.
  - `grok`: best quality in several runs, but significantly slower.

## 5) What’s pending ⏳

- Raise **anchors-only** answer quality to publication-grade levels.
- Improve **end-to-end anchor retention** (extractor recall gap remains).
- Reach stronger compression while preserving quality (beyond current light-filler savings).
- Expand and rebalance evaluation slices so one family (e.g., policy/legal) does not dominate weighted totals.
- Run larger, cost-stable multi-judge confirmations and finalize publication-ready aggregate metrics.

## Source references

- `docs/BENCHMARK_MATRIX.md`
- `results/eval/benchmark-summary.md`
- `results/public-model-matrix-t3/*/eval/benchmark-summary.md`
- `results/public-model-confirmation-m5-t3-gptjudge/*`
