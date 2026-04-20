# Dataset Sourcing Plan

This file turns the benchmark ideas into a concrete data collection plan.
The goal is not to gather the biggest corpus. The goal is to build a small,
credible, reproducible benchmark that is strong enough to support a paper or a
public technical report.

---

## What Counts As Publishable Evidence

For this project, results are worth publishing only if the evaluation set is:

- realistic enough to reflect actual long-context use cases
- reproducible from public or clearly documented sources
- legally safe to redistribute or re-create
- versioned and frozen before running final benchmarks
- broad enough that wins are not confined to one task family

That means we should prefer official benchmark releases and public-domain or
open-license corpora over scraped, provenance-unclear data.

---

## Recommended Source Stack

Use a two-layer benchmark:

1. **Canonical external benchmarks** for comparability with prior work
2. **Derived realistic corpora** for the exact product story we want to tell

### Layer 1: Canonical External Benchmarks

These are the strongest starting point because reviewers already recognize them.

| Family | Use First | Why | Notes |
|--------|-----------|-----|-------|
| Long-context QA | LongBench / LongBench-E | Standard long-context benchmark with multiple QA and summarization tasks | Official repo: `THUDM/LongBench`; official dataset card includes `hotpotqa`, `narrativeqa`, `qasper`, `qmsum`, `lcc`, `repobench-p` |
| Multi-hop QA | HotpotQA | Public, established, explainable QA benchmark with supporting facts | CC BY-SA 4.0 |
| Story / long narrative QA | NarrativeQA | Good for long document comprehension beyond retrieval-heavy QA | Official repo includes story metadata, question files, and download scripts |
| Conversation memory | OpenAssistant OASST1 | Public multi-turn assistant conversations with tree structure and message roles | Apache-2.0 |
| Stretch benchmark | LongBench v2 | Stronger realistic benchmark for long-context reasoning | Good supplementary benchmark after the main pipeline is stable |

### Layer 2: Derived Realistic Corpora

These are the datasets that support your novelty claims around anchors, roles,
and structured memory.

| Family | Best Public Source | Why It Fits | Constraint |
|--------|--------------------|-------------|------------|
| Policy / legal / obligations | SEC EDGAR filings | Dates, amounts, obligations, risk clauses, named entities | Must record exact filing URL and section extracted |
| Complaint / case narratives | CFPB Consumer Complaint Database | Real user-written narratives with exact facts and constraints | Use only published narratives; keep CFPB caveats in the paper |
| Multi-turn assistant chat | OASST1 | Public role-labeled conversations with real branching structure | Filter to English and usable turn depth |
| Wild prompts, optional | LMSYS Chatbot Arena Conversations | Real user prompts and model responses in the wild | Access-gated; prompts are CC-BY-4.0, outputs are CC-BY-NC-4.0 |
| Code repository context | LongBench `repobench-p` and `lcc` | Public long-context code tasks already normalized for evaluation | Better primary choice than ad hoc GitHub scraping |

---

## Sources To Prefer And Avoid

### Prefer

- **LongBench / LongBench-E** for the first paper-quality comparison set
- **HotpotQA** for multi-hop evidence retention
- **NarrativeQA** for long single-document QA
- **OASST1** for conversation history compression
- **SEC EDGAR** and **CFPB complaints** for anchor-heavy real-world text
- **RepoBench-P** and **LCC** for code-context tests

### Avoid As Primary Evidence

- **ShareGPT** as the main conversation benchmark: provenance and licensing are
  still messy enough that it weakens a publication story
- **Random GitHub scraping** without a provenance manifest: reproducibility and
  license review become fragile fast
- **The Stack** as a first-line benchmark for this repo: useful for sourcing
  code text, but the terms and attribution obligations are heavier than needed
  for a first paper

Use those only as supplemental stress tests, not as the backbone of the paper.

---

## Concrete Dataset Plan For This Repo

Build the first publishable benchmark around four families.

### A. General Long-Context QA

Use LongBench or LongBench-E as the main source.

Recommended subsets:

- `hotpotqa`
- `narrativeqa`
- `qasper`

Target size:

- 30 examples from `hotpotqa`
- 30 examples from `narrativeqa`
- 30 examples from `qasper`

Why this is enough:

- You get multi-document QA, narrative comprehension, and document QA without
  building your own labels from scratch.
- These tasks are already recognized in long-context evaluation.

### B. Conversation / Agent Memory

Use OASST1 as the primary conversation source.

Target size:

- 40 English conversation trees
- keep only conversations with 8-20 turns on one root-to-leaf path
- keep only `ready_for_export` trees

Add a small optional supplement from LMSYS only if you are willing to accept the
dataset gate and the non-commercial restriction on model outputs.

### C. Code / Structured Context

Use LongBench code tasks first.

Recommended subsets:

- `repobench-p`
- `lcc`

Target size:

- 25 examples from `repobench-p`
- 25 examples from `lcc`

This gives you realistic identifiers, imports, function names, and cross-file
dependencies without creating a brittle custom GitHub scraper.

### D. Policy / Legal / Compliance

Build a derived corpus from official public sources.

Recommended sources:

- SEC EDGAR filings: 10-K Risk Factors, MD&A, and material agreements
- CFPB complaint narratives with public consumer narratives enabled

Target size:

- 20 SEC sections
- 20 CFPB narratives

This family is where anchor retention should matter most because dates, dollar
amounts, product names, account terms, and negations are all mission-critical.

---

## Step-By-Step Collection Workflow

### Step 1: Freeze The Benchmark Design Before Downloading Anything

Freeze these choices in writing:

- dataset families
- target sample count per family
- length buckets: `4k-8k`, `8k-16k`, `16k-32k`, and one `32k+` stress slice
- primary metrics
- exclusion rules

Do this first so you do not unconsciously cherry-pick easy examples after seeing
early wins.

### Step 2: Download Only From Official Sources

Use official pages or official mirrors:

- LongBench: official GitHub repo or Hugging Face dataset card
- HotpotQA: official website downloads
- NarrativeQA: official repository
- OASST1: official Hugging Face dataset card
- CFPB: official API or bulk JSON/CSV export
- SEC EDGAR: official search or EDGAR APIs

For every source, store:

- source URL
- retrieval date
- dataset version or commit hash
- license or reuse terms
- citation string

### Step 3: Preserve Raw Data Separately

Use a three-stage layout:

```text
test/data/
  raw/
    longbench/
    hotpotqa/
    narrativeqa/
    oasst1/
    sec/
    cfpb/
  processed/
    D1_longbench_qa/
    D4_code/
    D6_policy_legal/
    D7_chat/
  manifests/
    sources.json
    splits.json
```

Never hand-edit raw files.

### Step 4: Normalize Everything Into The Repo Schema

Convert all datasets into the project JSONL schema:

```jsonl
{"id":"D1_001","role":"document","content":"...","meta":{"source":"longbench","dataset":"hotpotqa"}}
{"id":"D7_001","role":"system","content":"...","meta":{"source":"oasst1"}}
{"id":"D7_001","role":"user","content":"...","meta":{"source":"oasst1"}}
{"id":"D7_001","role":"assistant","content":"...","meta":{"source":"oasst1"}}
```

Rules:

- one logical document or conversation per `id`
- preserve original roles when present
- include source metadata in `meta`
- store original source IDs in `meta.source_id`
- add `meta.license` and `meta.url` where possible

### Step 5: Filter For Length And Realism

Only keep examples that actually stress long-context handling.

Suggested rules:

- exclude anything under 4k tokens for the main benchmark
- cap the first benchmark at 32k tokens for operational simplicity
- keep a separate stress split for longer inputs
- exclude corrupt, empty, or heavily templated examples
- exclude examples whose answer is trivial from the question alone

For OASST1 specifically:

- keep English only for the first paper
- require at least 8 turns in one path
- require at least one factual carry-over question or constraint reminder

For SEC / CFPB specifically:

- prefer sections with dates, names, constraints, amounts, or quoted clauses
- avoid boilerplate sections that can be answered from generic world knowledge

### Step 6: Create Questions And Gold Anchors

This step determines whether the benchmark actually tests your thesis.

For each document or conversation, write 3-5 questions:

- 1 factual recall question
- 1 anchor-sensitive question
- 1 constraint / negation question
- 1 cross-turn or cross-section synthesis question when possible

For each question, record:

```jsonl
{"doc_id":"D7_001","question":"What exact output format did the system require?","gold_answer":"JSON array","gold_anchors":["JSON array","must","do not include markdown"]}
```

Do not rely only on auto-extracted anchors. Manually review and add missing
must-retain spans.

### Step 7: Freeze Splits And Stop Curating

Once the dataset passes a sanity check, freeze it.

Create:

- `dev` split for pipeline debugging
- `test` split for final reporting

Do not keep adding examples after seeing method performance. That turns the
benchmark into a moving target and weakens the paper.

### Step 8: Write A Provenance Manifest

Create one manifest entry per processed dataset with:

- benchmark family name
- raw source name
- raw file path or URL
- retrieval date
- license
- transformation script used
- inclusion and exclusion criteria
- final document count
- final question count

This will matter when you write the methods section.

### Step 9: Run Baselines Before Claiming Wins

At minimum, report:

- `no-compression`
- `truncate-recent`
- one retrieval baseline if query-aware expansion is part of the claim
- your best anchor-preserving method

For the first public report, do not publish only your own methods. That reads as
benchmark tailoring.

### Step 10: Publish The Data Recipe, Not Necessarily Every Raw File

Depending on source terms, the safest public artifact may be:

- transformation scripts
- split manifests
- question files
- gold anchor files
- processed JSONL for redistributable sources
- download instructions for non-redistributable sources

That is enough for reproducibility if the recipe is exact.

---

## Minimal First Benchmark That Is Good Enough To Publish

If you want the fastest credible route, build this exact set first:

| Family | Source | Count |
|--------|--------|-------|
| Long-context QA | LongBench-E `hotpotqa` | 30 |
| Long-context QA | LongBench-E `narrativeqa` | 30 |
| Long-context QA | LongBench-E `qasper` | 30 |
| Conversation memory | OASST1 English trees | 40 |
| Code context | LongBench `repobench-p` + `lcc` | 50 total |
| Policy/legal | SEC EDGAR + CFPB | 40 total |

This is large enough to show breadth and still small enough to curate manually.

---

## What To Put In The Paper Or Technical Report

Include:

- exact source names and citations
- dataset licenses and restrictions
- conversion rules into your JSONL schema
- sample counts by family and length bucket
- question-writing protocol
- anchor-labeling protocol
- split freeze date
- all baselines and failure cases

Do not publish only aggregate win numbers. Include representative failures where
anchor retention was perfect but answer quality still dropped. That makes the
work more credible.

---

## Suggested Order Of Execution

1. Build the benchmark first from LongBench-E + OASST1 + SEC/CFPB.
2. Freeze the dev/test split and provenance manifest.
3. Run `no-compression` and `truncate-recent` baselines.
4. Run `anchors-only` and `anchors+structural`.
5. Only after that add LongBench v2 or LMSYS as supplementary evidence.

This keeps the project focused on a benchmark that is realistic, defensible, and
lightweight enough to finish.

---

## Official Source Notes

- LongBench and LongBench-E are available through the official THUDM LongBench
  repository and Hugging Face dataset card.
- HotpotQA is distributed from the official project site under CC BY-SA 4.0.
- NarrativeQA is distributed from the official Google DeepMind repository.
- OASST1 is distributed from the official OpenAssistant Hugging Face dataset card
  under Apache-2.0.
- LMSYS Chatbot Arena Conversations is access-gated and includes licensing
  differences between prompts and model outputs; treat it as optional.
- CFPB complaint data is officially published for public use via bulk download
  and API, but the CFPB explicitly warns that complaints are not a statistical
  sample and narratives are consumer statements, not independently verified fact.
- SEC EDGAR filings are publicly accessible through official SEC search tools and
  APIs; store filing URLs and accession identifiers in `meta`.