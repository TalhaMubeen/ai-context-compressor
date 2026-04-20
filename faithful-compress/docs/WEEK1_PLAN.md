# Week 1: Prove the Idea

Everything in this week is about **measuring before building**.
No compression strategy code until the harness works end-to-end.

---

## Day 1–2: Data

### Curate minimum viable corpus

**D1 — chat-multiturn (5 conversations)**
- Source: ShareGPT or manually construct
- Each: 10-20 turns, mixed roles (system/user/assistant)
- Format: `test/data/D1_chat.jsonl`
- Write 5 questions per conversation → `test/data/D1_chat_questions.jsonl`
- Manually tag gold anchors in each question

**D4 — system-prompts (10 prompts)**
- Source: collect from public repos, your own projects
- Format: `test/data/D4_system.jsonl`
- Questions: "What format should the output be in?", "What is the model not allowed to do?"

**D7 — adversarial (5 dense passages)**
- Source: Wikipedia technical articles, math proofs
- Dense, no repetition — this is the hardness floor
- Format: `test/data/D7_adversarial.jsonl`

### Data schema

```jsonl
{"id": "D1_001", "role": "system", "content": "You are a helpful assistant..."}
{"id": "D1_001", "role": "user", "content": "Can you help me debug..."}
{"id": "D1_001", "role": "assistant", "content": "Sure, the issue is..."}
```

```jsonl
{"doc_id": "D1_001", "question": "What error was the user seeing?", "gold_anchors": ["TypeError", "line 42", "not callable"]}
```

---

## Day 2–3: Token Counter

### Set up real BPE counting

Do NOT use `len(text) / 3.8`. That's a lie that will invalidate all results.

**Python side:**
```bash
pip install tiktoken
```
```python
import tiktoken
enc = tiktoken.get_encoding("cl100k_base")
tokens = enc.encode(text)
print(len(tokens))
```

**Haskell side (bridge):**

Option A — shell out to Python (quick and dirty, fine for week 1):
```haskell
tokenCount :: Text -> IO Int
tokenCount text = do
  let script = "import tiktoken; print(len(tiktoken.get_encoding('cl100k_base').encode('" 
               <> T.unpack (escapeForPython text) <> "')))"
  result <- readProcess "python3" ["-c", script] ""
  return (read (strip result))
```

Option B — Use tiktoken-hs or build FFI (week 2+).

---

## Day 3–4: Anchor Extractor

### Build and test Faithful.Anchor

This is the first real Haskell code. Get the `classify` function working:

```haskell
classify :: Text -> Seq Memory
```

**Test manually on each dataset:**
```bash
cabal run faithful-compress-cli -- anchors --input test/data/D1_chat.jsonl
```

Expected output:
```
Document D1_001: 47 anchors extracted
  ANumber:      12 (dates, counts, line numbers)
  AIdentifier:   8 (function names, variable names)
  ANegation:     6 ("not", "don't", "cannot")
  AQuotedString: 5 (error messages, string literals)
  AConstraint:   4 ("must", "required")
  ACodeSpan:     7 (inline code)
  AProperNoun:   5 (library names, API names)
```

**Run QuickCheck:**
```bash
cabal test
```

The critical property: `prop_classify_covers_input` must pass 1000 cases.

---

## Day 4–5: Baseline Measurements

### Measure M0 (no compression) and M1 (truncation)

**M0 — No compression:**
For each document, just record token count. This is the denominator.

**M1 — Truncation:**
Keep last 4096 tokens, drop the rest. Measure answer equivalence.
This is the "dumb baseline" — if we can't beat this, nothing else matters.

```python
python scripts/eval.py \
  --dataset test/data/D1_chat.jsonl \
  --questions test/data/D1_chat_questions.jsonl \
  --compressed results/compressed/D1/ \
  --output results/eval/D1_baselines.csv \
  --model claude-3-5-sonnet-20241022 \
  --judge gpt-4o
```

### Record results in the matrix

```
| Dataset | Method      | Tokens_orig | Tokens_comp | Reduction% | Equiv% | Anchor% |
|---------|-------------|-------------|-------------|------------|--------|---------|
| D1      | no-compress | 12,450      | 12,450      | 0.0%       | 100.0% | 100.0%  |
| D1      | truncate    | 12,450      | 4,096       | 67.1%      | ???%   | ???%    |
```

The `???` values are what we're here to fill in.

---

## Day 5–6: First Compression Strategy

### Implement M8 — Anchors Only

The simplest useful strategy: extract anchors, output them as a structured list.

```
[ANCHORS]
ANumber: 42, 3.14, 2025-01-15, 99.9%
AIdentifier: processUserData, userId, TypeError
ANegation: "does not", "cannot"
ACodeSpan: `user.email.toLowerCase()`
[/ANCHORS]

[BACKGROUND]
User discussed debugging a function that processes user data.
Function validates email and username. Issue with database updates.
[/BACKGROUND]
```

The background section is just the Approx text concatenated and lightly cleaned.
No fancy compression yet — just the Exact/Approx split rendered as text.

**Measure this against baselines.** If anchor extraction alone gives us 15-25% reduction
with 100% anchor retention and >85% answer equivalence, we have a viable core.

---

## Day 6–7: End-to-End Pipeline

### Wire everything together

```bash
# 1. Classify anchors for all documents
cabal run faithful-compress-cli -- compress \
  --strategy anchors-only \
  --input test/data/D1_chat.jsonl \
  --output results/compressed/D1/

# 2. Run evaluation
python scripts/eval.py \
  --dataset test/data/D1_chat.jsonl \
  --questions test/data/D1_chat_questions.jsonl \
  --compressed results/compressed/D1/ \
  --output results/eval/D1_anchors.csv

# 3. Generate summary table
python scripts/report.py results/eval/D1_*.csv
```

### Week 1 Definition of Done

- [ ] 3 datasets curated (D1, D4, D7) with questions and gold anchors
- [ ] Token counter uses real tiktoken (not character estimates)
- [ ] Anchor extractor passes 1000 QuickCheck cases
- [ ] Baseline M0 and M1 measured end-to-end
- [ ] Anchors-only strategy (M8) measured end-to-end
- [ ] Results CSV exists with real numbers
- [ ] We know the answer to: "Does separating exact from approximate memory help?"

If the answer to that last question is yes, proceed to Week 2 (structural + ERT).
If no, we need to rethink the approach before writing more code.

---

## What NOT to Do in Week 1

- Do not write the structural compressor yet
- Do not write the entity reference compressor yet
- Do not set up CI/CD
- Do not write the README for public consumption
- Do not optimize anything
- Do not think about FFI, CUDA, or llama.cpp
- Do not write blog posts

The only question week 1 answers: **does the core idea work?**
