# faithful-compress

**Faithful context compression for LLMs.**

Designed to preserve exact anchors while compressing background aggressively. Role-aware and relevance-aware. Typed provenance. Property-tested classification invariants.

---

## What this is

A Haskell library exploring context compression for LLMs with a core design principle: separate context into **exact memory** (anchors that must survive verbatim) and **approximate memory** (background that may be compressed or dropped).

Compression strategies operate only on approximate spans. Exact spans are preserved by construction — the strategy interface makes it structurally impossible to modify an anchor.

Unlike LLM-based compressors (LLMLingua, etc.), this requires no inference call. The compressed output is extractive: it retains natural-language tokens from the original, not synthetic notation.

## Status

🔬 **Research prototype with live benchmark results.** The core data model, anchor extractor, strategy interface, tokenizer bridge, and evaluation harness are implemented. Current benchmarked methods are `anchors-only`, `light-filler`, `no-anchors`, `truncate-recent`, and `no-compression`. The system is much faster than the earlier prototype, but answer-quality results are still mixed and aggressive compression is not ready for a broad quality claim. **Do not use in production.**

The current research question is narrower and more honest: *"Can exact/approx separation buy useful speed and compression without breaking downstream answers too often on real tasks?"*

Measured snapshot as of 2026-04-06:

- Local throughput: the raw CLI path on `D7_chat` dropped from about `2.059s` to `0.401s` for the same anchors-only run, and the local `--skip-eval` dev slice dropped from `4.900s` to `1.003s` after the tokenizer/pipeline rewrite.
- Full paid path: the same live dev slice with OpenRouter `openai/gpt-4o-mini` dropped from `613.160s` serial to `130.856s` with the optimized pipeline, a measured `4.69x` wall-clock speedup.
- Stable public matrix: on the 3-trial live matrix under a fixed Anthropic judge, `anchors-only` reached `37.0%-46.9%` answer equivalence while saving `64.2%` tokens, `light-filler` reached `63.0%-90.1%` while saving `7.5%`, and `truncate-recent` reached up to `90.1%` while saving `24.8%`.

The strongest current claim is about performance and auditability, not about universal quality superiority over retention-heavy baselines.

See [`docs/THESIS.md`](docs/THESIS.md) for the research claim and falsification ablations.
See [`docs/BENCHMARK_MATRIX.md`](docs/BENCHMARK_MATRIX.md) for the evaluation plan.
See [`docs/WEEK1_PLAN.md`](docs/WEEK1_PLAN.md) for the concrete first-week implementation plan.

## Design ideas (under evaluation)

**Exact vs. approximate memory.** Every span of context is classified as either an exact anchor (numbers, identifiers, code, quotes, negations, constraints) or approximate background. The strategy interface enforces this: strategies receive only Approx spans and return compressed text. Extracted exact spans flow through untouched. End-to-end quality still depends on anchor recall, so missed anchors remain a real failure mode in the current benchmarks.

**Role-aware compression.** Different context roles (system prompt, user message, assistant response, tool result) may benefit from different compression strategies. This is a hypothesis to be tested, not a proven result.

**Relevance-weighted budget allocation.** Age affects default compression budget, but anchor density and constraint content can override age. A cold chunk full of binding commitments gets more budget than a hot chunk of filler.

**Selective expansion.** Archive originals alongside compressed versions. At query time, re-expand chunks relevant to the current question within a token budget.

**Typed provenance.** Every compressed chunk carries metadata: source, strategy applied, anchors extracted. Enables auditing and debugging.

## What this is NOT

- Not a learned compression method (no fine-tuning required)
- Not a KV-cache compression method (operates on text, not tensors)
- Not a storage/transport codec (targets context-window tokens, not disk)
- Not a symbolic-language compressor (output is natural language)
- Not production-ready; current live benchmark results are still mixed

## Building

```bash
cabal build
cabal test        # QuickCheck classification properties
```

## Development setup

Native Windows is the primary supported development path for this repository.
Use Docker only when you need isolation or a disposable environment.

### Native Windows

Required tools:

- GHC 9.6.x
- cabal-install 3.14+
- Python 3.11+
- Docker Desktop (optional, for containerized development)

Recommended install path on Windows is GHCup, which installs GHC, cabal, Stack,
HLS, and MSYS2 in one pass.

After the Haskell toolchain is installed, use the native bootstrap first:

```powershell
./scripts/bootstrap.ps1
```

That script loads the native Windows toolchain, creates `.venv`, installs the
Python dependencies into that virtual environment, updates the cabal index, and
runs a full build.

For day-to-day work without reinstalling dependencies every time:

```powershell
. .\scripts\native-env.ps1 -EnsureVenv
cabal build all
cabal test
```

VS Code tasks are available in `.vscode/tasks.json`:

- `native bootstrap`
- `native build`
- `native test`

The tokenizer prefers a real Python 3 interpreter with `tiktoken` installed.
On Windows it tries `python`, then `python3`, then `py -3`, so an activated
project `.venv` is used before the global launcher.

If you need the Python environment directly, use `.venv\Scripts\python.exe`.

### Local environment file

`.env` is gitignored. Copy `.env.example` to `.env` and fill in any secrets you
need locally.

The native PowerShell workflow and the Python benchmark scripts load `.env`
automatically when it exists. Set `HF_TOKEN` there to authenticate Hugging Face
Hub downloads during `scripts/prepare_datasets.py`, which removes the
unauthenticated-request warning and gives you higher rate limits. The same file
can also hold `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, and
`OPEN_ROUTER_API_KEY` for benchmark evaluation.

### Docker

Docker is secondary here. Prefer the native workflow above unless you need a
clean Linux environment.

Build the development container:

```bash
docker compose build faithful-dev
```

Open a shell in the container:

```bash
docker compose run --rm faithful-dev
```

Inside the container, use the standard workflow:

```bash
cabal update
cabal build all
cabal test
```

### Python evaluation dependencies

The evaluation harness expects these packages locally or in the container:

- `tiktoken`
- `openai`
- `anthropic`

If you want to run model-based evaluation, provide API keys via environment
variables documented in `.env.example`. The Python benchmark entry points load
`.env` automatically if you keep the keys there.

## Benchmarking

Prepare the official-source datasets first:

```powershell
. .\scripts\native-env.ps1 -EnsureVenv
python .\scripts\prepare_datasets.py
```

Run a fast local-only smoke benchmark with parallel compression and no paid API calls:

```powershell
python .\scripts\run_benchmark.py --skip-eval --split dev --max-docs-per-family 2 --strategy-workers 4 --family-workers 2
```

Run a live benchmark with threaded API evaluation:

```powershell
python .\scripts\run_benchmark.py --split dev --max-docs-per-family 3 --strategy-workers 4 --api-workers 4
```

`--family-workers` parallelizes dataset families, `--strategy-workers` parallelizes local compression strategies, and `--api-workers` parallelizes question/trial API calls inside `scripts/eval.py`. Start with modest values because total live concurrency is roughly `family-workers * api-workers`.

### Current benchmark snapshot

The most useful public artifacts today are the optimized paid-path run in `results/dev3-openrouter-live-opt` and the stable 3-trial cross-model matrix in `results/public-model-matrix-t3`.

The 3-trial matrix used four dev families (`D1`, `D4`, `D6`, `D7`), `3` documents per family, `27` questions total, and a fixed judge model (`claude-haiku-4-5`) so the answer-model comparison stays controlled.

| Answer model | Runtime (3 trials) | Anchors-only | Light-filler | Truncate-recent | No-compression |
|---|---:|---:|---:|---:|---:|
| gemini (`google/gemini-2.0-flash-001`) | `232.5s` | `37.0% @ 64.2%` | `63.0% @ 7.5%` | `67.9% @ 24.8%` | `71.6%` |
| qwen (`qwen/qwen-turbo`) | `240.1s` | `43.2% @ 64.2%` | `83.9% @ 7.5%` | `90.1% @ 24.8%` | `92.6%` |
| gpt (`openai/gpt-4o-mini`) | `279.6s` | `42.0% @ 64.2%` | `72.8% @ 7.5%` | `77.8% @ 24.8%` | `74.1%` |
| claude (`anthropic/claude-3.5-haiku`) | `404.3s` | `38.3% @ 64.2%` | `77.8% @ 7.5%` | `80.3% @ 24.8%` | `81.5%` |
| grok (`x-ai/grok-3-mini`) | `1036.0s` | `46.9% @ 64.2%` | `90.1% @ 7.5%` | `80.3% @ 24.8%` | `91.3%` |

Each cell above is `answer equivalence @ token reduction` for that method. The current takeaway is straightforward: `anchors-only` compresses hard but is not yet reliable enough, `light-filler` is the best implemented compressor, `qwen` gives the best speed/quality balance, and `grok` is usually strongest on quality but far slower.

A larger follow-up on 2026-04-07 ran only `qwen` and `grok` over `5` dev docs per family with `3` trials and an OpenRouter GPT judge after the Anthropic judge account ran out of credits. It preserved the same pattern: `anchors-only` remained weak (`44.7%-49.2% @ 62.2%`), `grok` led on quality (`light-filler 90.9%`, `no-compression 92.5%`), and `qwen` stayed materially faster (`727.8s` vs `1515.8s`).

### Publication-ready results

| Headline | Strongest current evidence |
|---|---|
| Systems speedup | `4.9x` local `--skip-eval`; `4.69x` paid live path |
| Best compressed quality | `grok + light-filler = 90.9%` answer equivalence at `6.4%` reduction |
| Best speed/quality tradeoff | `qwen + truncate-recent = 84.9% @ 18.2%` on the larger slice; `90.1% @ 24.8%` on the 5-model matrix |
| Hard-compression limit | `anchors-only = 44.7%-49.2% @ 62.2%` on the larger follow-up |

Public claim worth defending: the project now has a real systems result and an auditable compression pipeline, with `light-filler` as the best current compressor. What the evidence still does not justify is a broad claim that aggressive compression beats strong retention-heavy baselines on answer quality.

## Current project structure

```
app/
  Main.hs           -- CLI entry point and concurrent document compression

src/Faithful/
  Core.hs           -- Memory (Exact | Approx), Anchor, Chunk, Provenance
  Anchor.hs         -- Anchor extraction (numbers, IDs, quotes, code, negations)
  Strategy.hs       -- Compression strategies and combinators
  Expansion.hs      -- Selective expansion engine (WIP)
  Tokenizer.hs      -- Persistent Python tokenizer bridge and batch token counting

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
