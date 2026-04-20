# ROADMAP_NEXT: From Honest Prototype to Publication-Grade Evidence

_Last updated: 2026-04-20_

This roadmap converts current external feedback into executable milestones with measurable exits.

## Current baseline (starting point)

- Strongest validated claim today: **systems speed + auditability**, not broad quality superiority.
- Measured speedups: `4.9x` local `--skip-eval`, `4.69x` paid-path wall-clock.
- Current quality/compression envelope:
  - `anchors-only`: high savings, weak equivalence (`~37-49%` at `~62-64%` reduction)
  - `light-filler`: best current compressor quality, modest savings (`~6-8%`)
  - `truncate-recent`: strongest retention-heavy baseline on several slices

---

## Phase 1 — Anchor Recall Recovery (highest leverage)

### Objective
Improve end-to-end anchor retention by fixing extractor recall gaps (the main bottleneck for aggressive compression quality).

### Deliverables
- Anchor gold set for D1/D4/D6/D7 with per-anchor-type labels:
  - number, identifier, quote, code span, negation, constraint
- Per-type recall report and confusion categories in benchmark output
- Error taxonomy for misses (parser miss, normalization mismatch, boundary split, etc.)

### Metrics / KPIs
- Overall extracted-anchor recall (gold vs extracted)
- Per-anchor-type recall
- End-to-end anchor retention for extracted anchors

### Exit criteria (must pass)
- Per-type extractor recall: **no type below 0.92** on the curated dev gold set
- Overall extractor recall: **>= 0.95**
- End-to-end retention of extracted anchors remains **>= 0.99**

---

## Phase 2 — Quality-Gated Compression Policy

### Objective
Prevent catastrophic answer-quality drops by routing risky inputs to safer strategies.

### Deliverables
- Confidence/risk scoring per chunk/document (anchor density, unresolved constraints, contradiction cues, parser confidence)
- Policy gate in strategy selection:
  - high risk -> safer mode (`light-filler` or retention-heavy)
  - low risk -> allow aggressive mode candidates
- Failure-audit logs showing gate decisions and reason codes

### Metrics / KPIs
- Tail-risk reduction: degraded/wrong answer rates on risky slices
- Delta vs always-on aggressive mode for answer equivalence
- Token reduction retained after gating

### Exit criteria (must pass)
- On risky subset, wrong/degraded rate reduced by **>= 30%** relative to ungated aggressive mode
- Aggregate equivalence improves by **>= 8 percentage points** vs ungated aggressive mode
- Net token reduction remains **>= 12%** on the same evaluation slice

---

## Phase 3 — Selective Expansion (thesis-critical)

### Objective
Recover quality at fixed budget by re-expanding only query-relevant chunks.

### Deliverables
- Query-aware expansion variants:
  - keyword overlap
  - anchor overlap
  - embedding similarity
- Budgeted expansion controller with utilization telemetry
- Comparative report: static compressed vs selective expansion under equal token budget

### Metrics / KPIs
- Answer equivalence gain at fixed budget
- Expansion precision (expanded chunks that contribute to judged-correct answers)
- Budget utilization and confidence calibration

### Exit criteria (must pass)
- At matched token budget, selective expansion beats static compression by **>= 6 points** answer equivalence
- Expansion precision **>= 0.65** on curated audit set
- Budget utilization in target band **[85%, 100%]** for production-like runs

---

## Phase 4 — Publication-Grade Benchmark Protocol

### Objective
Produce stable, non-fragile evidence that is robust to model/judge/slice variance.

### Deliverables
- Rebalanced family weighting (avoid single-family dominance)
- Multi-judge runs with fixed protocol and cost-aware reruns
- Confidence intervals and variance reporting across trials
- Final matrix summary suitable for external publication

### Metrics / KPIs
- Variance of answer-equivalence across runs/judges
- Cross-model stability for key conclusions
- Cost + runtime per matrix refresh

### Exit criteria (must pass)
- Key claim directions hold across at least **2 judges** and **>= 2 answer-model groups**
- 95% CI width for headline methods is operationally useful (target: **<= 8 points**)
- Final report explicitly separates:
  - defensible claims
  - open risks
  - non-claims

---

## Phase 5 — Adoption Surface (optional but high leverage)

### Objective
Lower integration friction for users who are not Haskell-native.

### Deliverables
- Minimal HTTP service wrapper around current CLI/core pipeline
- Basic CI matrix (Windows + Linux): build, tests, benchmark smoke
- One copy-paste integration example (agent pipeline / RAG preprocessor)

### Metrics / KPIs
- Time-to-first-run for new user
- CI pass rate and flake rate
- API smoke benchmark latency

### Exit criteria (must pass)
- New user can run end-to-end smoke in **<= 15 minutes**
- CI green on both target OSes for 2 consecutive weeks

---

## Suggested sequencing and ownership

1. **P1 Anchor recall** (foundation)
2. **P2 Quality gate** (risk control)
3. **P3 Selective expansion** (thesis differentiator)
4. **P4 Benchmark protocol hardening** (publication readiness)
5. **P5 Adoption layer** (distribution)

If timelines are tight, complete P1+P2 first; those deliver immediate quality-risk improvement without changing the core thesis.

---

## Definition of success for the next public update

A credible next release should be able to say all of the following at once:

- We kept the systems speed and auditability wins.
- We materially improved anchor recall (documented by type).
- We reduced quality tail-risk with gated compression.
- We showed selective expansion improves equivalence at fixed budget.
- We reported results with stable protocol and explicit uncertainty.

That update would move the project from "promising prototype" to "serious research artifact with externally defensible claims."