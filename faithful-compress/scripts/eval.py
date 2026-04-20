#!/usr/bin/env python3
"""
eval.py v5 — Answer Equivalence Evaluation

Fixes from v4 audit:
- Preserves role structure when loading documents
- Supports in-loop compression via --compressor-cmd (for selective expansion)
- Runs N trials (default 3) for variance estimation
- Computes anchor retention from extracted anchors, not just gold_anchors
- Does not truncate stored answers

Usage:
    # Static compressed files (M6–M13):
    python scripts/eval.py \
        --dataset test/data/D7_chat.jsonl \
        --questions test/data/D7_chat_questions.jsonl \
        --compressed results/compressed/D7/ \
        --output results/eval/D7.csv

    # In-loop compression via CLI (M14–M16, selective expansion):
    python scripts/eval.py \
        --dataset test/data/D7_chat.jsonl \
        --questions test/data/D7_chat_questions.jsonl \
        --compressor-cmd "cabal run faithful-compress-cli -- compress --strategy anchors-only" \
        --output results/eval/D7_anchors.csv
"""

import argparse
import concurrent.futures
import csv
import json
import os
import random
import re
import shlex
import sys
import time
import subprocess
import tempfile
import threading
from pathlib import Path
from dataclasses import dataclass

from env_utils import load_repo_env


ROOT = Path(__file__).resolve().parent.parent
load_repo_env(ROOT)


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and os.environ.get(key, "") == "":
            os.environ[key] = value


@dataclass
class EvalResult:
    doc_id: str
    method: str
    question: str
    trial: int
    answer_equivalence: str
    anchor_retention: float
    original_tokens: int
    compressed_tokens: int
    token_reduction_pct: float
    answer_original: str = ""
    answer_compressed: str = ""
    judge_explanation: str = ""


@dataclass(frozen=True)
class PreparedDoc:
    doc_id: str
    original: str
    original_source_text: str
    original_tokens: int
    compressed_methods: dict[str, str]
    compressed_tokens: dict[str, int]


@dataclass(frozen=True)
class QuestionJob:
    doc_id: str
    question: str
    gold_anchors: tuple[str, ...]
    trial: int


THREAD_LOCAL = threading.local()
ABORT_EVENT = threading.Event()
RETRYABLE_ERROR_MARKERS = (
    "429",
    "500",
    "502",
    "503",
    "504",
    "529",
    "api connection",
    "connection",
    "deadline",
    "gateway",
    "overloaded",
    "rate limit",
    "resource exhausted",
    "service unavailable",
    "temporarily unavailable",
    "timeout",
    "timed out",
    "too many requests",
)
FATAL_ERROR_MARKERS = (
    "account_deactivated",
    "api key",
    "authentication",
    "billing",
    "credit balance",
    "insufficient credits",
    "invalid api key",
    "plans & billing",
    "purchase credits",
    "quota",
    "unauthorized",
)


class EvaluationAborted(RuntimeError):
    pass


class FatalProviderFailure(EvaluationAborted):
    pass


class JudgeFailure(EvaluationAborted):
    pass


def abort_if_requested() -> None:
    if ABORT_EVENT.is_set():
        raise EvaluationAborted("Evaluation aborted after an earlier fatal failure")


def is_fatal_error_message(message: str) -> bool:
    lowered = message.lower()
    return any(marker in lowered for marker in FATAL_ERROR_MARKERS)


def count_tokens(text: str) -> int:
    try:
        import tiktoken
        enc = tiktoken.get_encoding("cl100k_base")
        return len(enc.encode(text))
    except ImportError:
        return max(1, int(len(text) / 3.8))


def get_thread_local_client(name, factory):
    client = getattr(THREAD_LOCAL, name, None)
    if client is None:
        client = factory()
        setattr(THREAD_LOCAL, name, client)
    return client


def get_anthropic_client():
    import anthropic

    return get_thread_local_client("anthropic_client", anthropic.Anthropic)


def get_openai_client():
    import openai

    return get_thread_local_client("openai_client", openai.OpenAI)


def get_openrouter_client():
    import openai

    api_key = os.environ.get("OPEN_ROUTER_API_KEY")
    if not api_key:
        raise RuntimeError("OPEN_ROUTER_API_KEY is not set")

    def build_client():
        return openai.OpenAI(
            api_key=api_key,
            base_url="https://openrouter.ai/api/v1",
        )

    return get_thread_local_client("openrouter_client", build_client)


def is_retryable_error(exc: Exception) -> bool:
    message = f"{type(exc).__name__}: {exc}".lower()
    return any(marker in message for marker in RETRYABLE_ERROR_MARKERS)


def call_with_retries(operation, description: str, max_retries: int, backoff_seconds: float, jitter_seconds: float):
    attempt = 0
    while True:
        abort_if_requested()
        try:
            return operation()
        except Exception as exc:
            attempt += 1
            if attempt > max_retries or not is_retryable_error(exc):
                raise
            delay = backoff_seconds * (2 ** (attempt - 1)) + random.uniform(0.0, max(0.0, jitter_seconds))
            print(f"      [retry {attempt}/{max_retries}] {description}: {exc}")
            time.sleep(delay)


def call_llm(
    prompt: str,
    context: str,
    model: str,
    *,
    max_retries: int,
    backoff_seconds: float,
    jitter_seconds: float,
    raise_on_error: bool = False,
    call_role: str = "answer",
) -> str:
    if model.startswith("openrouter:"):
        operation = lambda: _call_openrouter(prompt, context, model.split(":", 1)[1])
    elif "claude" in model:
        operation = lambda: _call_anthropic(prompt, context, model)
    elif "gpt" in model:
        operation = lambda: _call_openai(prompt, context, model)
    else:
        raise ValueError(f"Unknown model: {model}")

    try:
        return call_with_retries(
            operation,
            description=f"model={model}",
            max_retries=max_retries,
            backoff_seconds=backoff_seconds,
            jitter_seconds=jitter_seconds,
        )
    except Exception as exc:
        detail = f"{type(exc).__name__}: {exc}"
        if is_fatal_error_message(detail):
            ABORT_EVENT.set()
            raise FatalProviderFailure(f"Fatal {call_role} call failed for {model}: {detail}") from exc
        if raise_on_error:
            ABORT_EVENT.set()
            raise JudgeFailure(f"{call_role.capitalize()} call failed for {model}: {detail}") from exc
        return f"[ERROR: {exc}]"


def _call_anthropic(prompt, context, model):
    client = get_anthropic_client()
    msg = client.messages.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": f"Context:\n{context}\n\nQuestion: {prompt}"}],
    )
    return msg.content[0].text


def _call_openai(prompt, context, model):
    client = get_openai_client()
    resp = client.chat.completions.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": f"Context:\n{context}\n\nQuestion: {prompt}"}],
    )
    return resp.choices[0].message.content


def _call_openrouter(prompt, context, model):
    client = get_openrouter_client()
    headers = {
        "HTTP-Referer": os.environ.get("OPENROUTER_HTTP_REFERER", "https://localhost/faithful-compress"),
        "X-Title": os.environ.get("OPENROUTER_APP_TITLE", "faithful-compress"),
    }
    resp = client.chat.completions.create(
        model=model,
        max_tokens=1024,
        messages=[{"role": "user", "content": f"Context:\n{context}\n\nQuestion: {prompt}"}],
        extra_headers=headers,
    )
    return resp.choices[0].message.content


JUDGE_PROMPT = """You are evaluating whether two answers to the same question are equivalent.

Question: {question}

Reference answer (from original context):
{answer_original}

Candidate answer (from compressed context):
{answer_compressed}

Classify the candidate as one of:
- "exact": same key details
- "semantic": same meaning, minor wording differences
- "degraded": partially correct but missing important information
- "wrong": incorrect or contradicts reference

Respond with ONLY a JSON object: {{"verdict": "...", "explanation": "..."}}"""


def judge_equivalence(
    question,
    answer_orig,
    answer_comp,
    judge_model,
    *,
    max_retries: int,
    backoff_seconds: float,
    jitter_seconds: float,
):
    prompt = JUDGE_PROMPT.format(
        question=question, answer_original=answer_orig, answer_compressed=answer_comp
    )
    response = call_llm(
        prompt,
        "",
        judge_model,
        max_retries=max_retries,
        backoff_seconds=backoff_seconds,
        jitter_seconds=jitter_seconds,
        raise_on_error=True,
        call_role="judge",
    )
    if is_error_response(response):
        ABORT_EVENT.set()
        raise JudgeFailure(f"Judge model {judge_model} returned an error response: {response}")
    try:
        cleaned = response.strip()
        if cleaned.startswith("```"):
            cleaned = cleaned.split("\n", 1)[1].rsplit("```", 1)[0]
        result = json.loads(cleaned)
        return result.get("verdict", "unknown"), result.get("explanation", "")
    except (json.JSONDecodeError, KeyError):
        for v in ["exact", "semantic", "degraded", "wrong"]:
            if v in response.lower():
                return v, response
        ABORT_EVENT.set()
        snippet = response.strip().replace("\n", " ")[:240]
        raise JudgeFailure(f"Judge model {judge_model} returned an unparseable verdict: {snippet}")


def load_dataset_with_roles(path):
    """Load dataset preserving role structure per document."""
    docs = {}  # doc_id -> [(role, content)]
    with open(path, encoding="utf-8") as f:
        for line in f:
            row = json.loads(line)
            doc_id = row["id"]
            role = row.get("role", "unknown")
            content = row["content"]
            if doc_id not in docs:
                docs[doc_id] = []
            docs[doc_id].append({"role": role, "content": content})
    return docs


def render_context_with_roles(turns):
    """Render a document preserving role tags."""
    parts = []
    for turn in turns:
        role = turn["role"].upper()
        parts.append(f"[{role}]\n{turn['content']}")
    return "\n\n".join(parts)


def render_context_flat(turns):
    """Render as flat text (for baselines that don't use roles)."""
    return "\n".join(t["content"] for t in turns)


def load_questions(path):
    questions = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            questions.append(json.loads(line))
    return questions


def safe_file_stem(text):
    if text and all(ch.isalnum() or ch in "-_." for ch in text):
        return text
    normalized = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in text.strip())
    return (normalized or "chunk")[:40]


def extract_anchor_strings(text):
    anchors = set()

    patterns = [
        r'```.*?```',
        r'`[^`\n]+`',
        r'"[^"\n]{1,500}"',
        r'\$\d[\d,]*(?:\.\d+)?',
        r'\b\d{4}-\d{2}-\d{2}\b',
        r'\b\d+(?:[\.,]\d+)*(?:%|\b)',
        r'\b(?:must not|shall not|do not|does not|did not|should not|would not|could not|cannot|can\'t|won\'t|never|not)\b',
        r'\b(?:must|shall|required|mandatory|at least|at most|no more than|exactly|minimum|maximum)\b',
        r'\b[A-Za-z_][A-Za-z0-9_]*-[A-Za-z0-9._-]+\b',
        r'\b[A-Za-z_][A-Za-z0-9_]{2,}\b',
    ]

    for pattern in patterns:
        for match in re.findall(pattern, text, flags=re.IGNORECASE | re.DOTALL):
            candidate = match.strip()
            if candidate:
                anchors.add(candidate)

    return anchors


def run_compressor_cmd(cmd, dataset_path, output_dir):
    os.makedirs(output_dir, exist_ok=True)
    result = subprocess.run(
        shlex.split(cmd) + ["--input", dataset_path, "--output", str(output_dir)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "Compressor command failed:\n"
            f"stdout:\n{result.stdout}\n\n"
            f"stderr:\n{result.stderr}"
        )


def prepare_compressed_dir(args):
    if not args.compressed and not args.compressor_cmd:
        raise ValueError("Provide either --compressed or --compressor-cmd")

    temp_dir = None
    output_dir = Path(args.compressed) if args.compressed else None

    if args.compressor_cmd:
        if output_dir is None:
            temp_dir = tempfile.TemporaryDirectory(prefix="faithful-compressed-")
            output_dir = Path(temp_dir.name)
        print(f"Preparing compressed outputs in: {output_dir}")
        run_compressor_cmd(args.compressor_cmd, args.dataset, output_dir)

    return output_dir, temp_dir


def load_compressed_methods(compressed_dir, doc_id):
    methods = {}
    if compressed_dir is None:
        return methods

    patterns = [doc_id]
    safe_doc_id = safe_file_stem(doc_id)
    if safe_doc_id != doc_id:
        patterns.append(safe_doc_id)

    seen = set()
    for pattern in patterns:
        for path in compressed_dir.glob(f"{pattern}.*"):
            if path in seen:
                continue
            seen.add(path)
            method = path.stem.split(".", 1)[1] if "." in path.stem else "unknown"
            methods[method] = path.read_text(encoding="utf-8")

    return methods


def check_anchor_retention(compressed_text, source_text, gold_anchors):
    anchors = set(gold_anchors)
    anchors.update(extract_anchor_strings(source_text))
    anchors = {anchor for anchor in anchors if anchor}

    if not anchors:
        return 1.0
    retained = sum(1 for anchor in anchors if anchor in compressed_text)
    return retained / len(anchors)


def is_error_response(text: str) -> bool:
    return text.startswith("[ERROR:")


def prepare_documents(docs, questions, compressed_dir):
    prepared = {}
    for doc_id in sorted({question["doc_id"] for question in questions}):
        if doc_id not in docs:
            print(f"  [SKIP] No document for {doc_id}")
            continue

        turns = docs[doc_id]
        original = render_context_with_roles(turns)
        compressed_methods = load_compressed_methods(compressed_dir, doc_id)
        if not compressed_methods:
            print(f"  [SKIP] No compressed files for {doc_id}")
            continue

        prepared[doc_id] = PreparedDoc(
            doc_id=doc_id,
            original=original,
            original_source_text=render_context_flat(turns),
            original_tokens=count_tokens(original),
            compressed_methods=compressed_methods,
            compressed_tokens={method: count_tokens(text) for method, text in compressed_methods.items()},
        )
    return prepared


def evaluate_question_job(job: QuestionJob, prepared: PreparedDoc, args) -> tuple[list[EvalResult], list[str]]:
    abort_if_requested()
    log_lines = [f"  [{job.doc_id}] Trial {job.trial}/{args.trials} Q: {job.question[:60]}..."]
    answer_original = call_llm(
        job.question,
        prepared.original,
        args.model,
        max_retries=args.max_retries,
        backoff_seconds=args.retry_backoff_seconds,
        jitter_seconds=args.retry_jitter_seconds,
        call_role="answer",
    )

    results = []
    for method, compressed in sorted(prepared.compressed_methods.items()):
        abort_if_requested()
        answer_compressed = call_llm(
            job.question,
            compressed,
            args.model,
            max_retries=args.max_retries,
            backoff_seconds=args.retry_backoff_seconds,
            jitter_seconds=args.retry_jitter_seconds,
            call_role="answer",
        )
        if is_error_response(answer_original):
            verdict, explanation = "error", answer_original
        elif is_error_response(answer_compressed):
            verdict, explanation = "error", answer_compressed
        else:
            verdict, explanation = judge_equivalence(
                job.question,
                answer_original,
                answer_compressed,
                args.judge,
                max_retries=args.max_retries,
                backoff_seconds=args.retry_backoff_seconds,
                jitter_seconds=args.retry_jitter_seconds,
            )

        retention = check_anchor_retention(compressed, prepared.original_source_text, job.gold_anchors)
        comp_tokens = prepared.compressed_tokens[method]
        reduction = (1 - comp_tokens / max(1, prepared.original_tokens)) * 100

        results.append(
            EvalResult(
                doc_id=job.doc_id,
                method=method,
                question=job.question,
                trial=job.trial,
                answer_equivalence=verdict,
                anchor_retention=retention,
                original_tokens=prepared.original_tokens,
                compressed_tokens=comp_tokens,
                token_reduction_pct=round(reduction, 1),
                answer_original=answer_original,
                answer_compressed=answer_compressed,
                judge_explanation=explanation,
            )
        )

        status = "ok" if verdict in ("exact", "semantic") else ("err" if verdict == "error" else "bad")
        log_lines.append(f"    [{status}] {method}: {verdict} | {reduction:.1f}% | anchors: {retention:.0%}")

    return results, log_lines


def run_evaluation(args):
    ABORT_EVENT.clear()
    load_env_file(ROOT / ".env")
    print(f"Loading dataset: {args.dataset}")
    docs = load_dataset_with_roles(args.dataset)
    print(f"  -> {len(docs)} documents")

    print(f"Loading questions: {args.questions}")
    questions = load_questions(args.questions)
    print(f"  -> {len(questions)} questions")

    compressed_dir, temp_dir = prepare_compressed_dir(args)
    results = []
    n_trials = args.trials

    try:
        prepared_docs = prepare_documents(docs, questions, compressed_dir)
        jobs = []
        for question in questions:
            if question["doc_id"] not in prepared_docs:
                continue
            for trial in range(1, n_trials + 1):
                jobs.append(
                    QuestionJob(
                        doc_id=question["doc_id"],
                        question=question["question"],
                        gold_anchors=tuple(question.get("gold_anchors", [])),
                        trial=trial,
                    )
                )

        if not jobs:
            return results

        workers = max(1, args.workers)
        print(f"Running {len(jobs)} question/trial jobs with {workers} API worker(s)")

        if workers == 1:
            for index, job in enumerate(jobs, start=1):
                try:
                    job_results, log_lines = evaluate_question_job(job, prepared_docs[job.doc_id], args)
                except Exception as exc:
                    ABORT_EVENT.set()
                    raise RuntimeError(
                        f"Evaluation failed for {job.doc_id} trial {job.trial}: {job.question[:80]}"
                    ) from exc
                results.extend(job_results)
                print(f"Completed {index}/{len(jobs)} jobs")
                for line in log_lines:
                    print(line)
        else:
            with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
                future_to_job = {
                    executor.submit(evaluate_question_job, job, prepared_docs[job.doc_id], args): job
                    for job in jobs
                }
                for index, future in enumerate(concurrent.futures.as_completed(future_to_job), start=1):
                    job = future_to_job[future]
                    try:
                        job_results, log_lines = future.result()
                    except Exception as exc:
                        ABORT_EVENT.set()
                        for pending in future_to_job:
                            if pending is not future:
                                pending.cancel()
                        raise RuntimeError(
                            f"Evaluation failed for {job.doc_id} trial {job.trial}: {job.question[:80]}"
                        ) from exc
                    results.extend(job_results)
                    print(f"Completed {index}/{len(jobs)} jobs")
                    for line in log_lines:
                        print(line)
    finally:
        if temp_dir is not None:
            temp_dir.cleanup()
        ABORT_EVENT.clear()

    return results


def write_results(results, output):
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    with open(output, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "doc_id", "method", "question", "trial",
            "answer_equivalence", "anchor_retention",
            "original_tokens", "compressed_tokens", "token_reduction_pct",
            "judge_explanation"
        ])
        for r in sorted(results, key=lambda item: (item.doc_id, item.question, item.trial, item.method)):
            writer.writerow([
                r.doc_id, r.method, r.question, r.trial,
                r.answer_equivalence, f"{r.anchor_retention:.3f}",
                r.original_tokens, r.compressed_tokens, r.token_reduction_pct,
                r.judge_explanation
            ])
    print(f"\nResults written to {output}")


def print_summary(results):
    if not results:
        print("No results.")
        return

    methods = sorted(set(r.method for r in results))
    print("\n" + "=" * 80)
    print("SUMMARY (averaged across trials)")
    print("=" * 80)
    print(f"{'Method':<20} {'Equiv%':>8} {'Anchor%':>8} {'Reduction%':>10} {'N':>5}")
    print("-" * 55)

    for method in methods:
        mrs = [r for r in results if r.method == method]
        n = len(mrs)
        equiv = sum(1 for r in mrs if r.answer_equivalence in ("exact", "semantic")) / n * 100
        anchor = sum(r.anchor_retention for r in mrs) / n * 100
        reduction = sum(r.token_reduction_pct for r in mrs) / n
        print(f"{method:<20} {equiv:>7.1f}% {anchor:>7.1f}% {reduction:>9.1f}% {n:>5}")

    print("=" * 80)


def main():
    parser = argparse.ArgumentParser(description="Evaluate context compression quality")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--questions", required=True)
    parser.add_argument("--compressed", default=None, help="Dir with static compressed files")
    parser.add_argument("--compressor-cmd", default=None, help="CLI command for in-loop compression")
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default="claude-haiku-4-5")
    parser.add_argument("--judge", default="claude-haiku-4-5")
    parser.add_argument("--trials", type=int, default=3, help="Number of trials per question")
    parser.add_argument("--workers", type=int, default=4, help="Concurrent question/trial jobs for live API calls")
    parser.add_argument("--max-retries", type=int, default=4, help="Retries for transient API failures")
    parser.add_argument(
        "--retry-backoff-seconds",
        type=float,
        default=1.5,
        help="Base exponential backoff in seconds for transient API failures",
    )
    parser.add_argument(
        "--retry-jitter-seconds",
        type=float,
        default=0.25,
        help="Random jitter added to retry sleeps",
    )
    args = parser.parse_args()

    results = run_evaluation(args)
    write_results(results, args.output)
    print_summary(results)


if __name__ == "__main__":
    main()
