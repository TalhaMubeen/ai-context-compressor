#!/usr/bin/env python3
"""Download, normalize, and freeze the benchmark datasets."""

from __future__ import annotations

import argparse
import json
import os
import re
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable

import requests
from bs4 import BeautifulSoup
from datasets import load_dataset

from env_utils import hf_dataset_kwargs, load_repo_env
from eval import count_tokens, extract_anchor_strings


ROOT = Path(__file__).resolve().parent.parent
DATA_ROOT = ROOT / "test" / "data"
RAW_ROOT = DATA_ROOT / "raw"
PROCESSED_ROOT = DATA_ROOT / "processed"
MANIFEST_ROOT = DATA_ROOT / "manifests"


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

load_repo_env(ROOT)
HF_DATASET_KWARGS = hf_dataset_kwargs()

LONG_BENCH_QA_TARGET = 30
OASST1_TARGET = 40
CODE_TARGET = 25
SEC_TARGET = 20
CFPB_TARGET = 20

MIN_LONG_QA_TOKENS = 1500
MAX_MAIN_TOKENS = 32000
MIN_CHAT_HISTORY_TOKENS = 200
MIN_CODE_TOKENS = 700
MIN_SEC_TOKENS = 3500
MAX_SEC_TOKENS = 22000

CFPB_PRODUCTS = [
    "Mortgage",
    "Student loan",
    "Credit card or prepaid card",
]

SEC_COMPANIES = [
    ("AAPL", "technology"),
    ("MSFT", "technology"),
    ("AMZN", "retail"),
    ("JPM", "banking"),
    ("BAC", "banking"),
    ("WFC", "banking"),
    ("XOM", "energy"),
    ("CVX", "energy"),
    ("PFE", "pharma"),
    ("MRK", "pharma"),
    ("UNH", "healthcare"),
    ("CAT", "industrial"),
    ("GE", "industrial"),
    ("WMT", "retail"),
    ("COST", "retail"),
    ("T", "telecom"),
    ("VZ", "telecom"),
    ("DUK", "utilities"),
    ("NEE", "utilities"),
    ("F", "automotive"),
    ("GM", "automotive"),
    ("BA", "aerospace"),
    ("LMT", "aerospace"),
    ("KO", "consumer"),
    ("PEP", "consumer"),
]

SEC_HEADERS = {
    "Accept-Encoding": "gzip, deflate",
}

LONG_BENCH_LICENSES = {
    "hotpotqa_e": "CC BY-SA 4.0 (HotpotQA component)",
    "narrativeqa": "Apache-2.0 (NarrativeQA component)",
    "qasper_e": "CC BY 4.0 (Qasper component)",
    "repobench-p": "Mixed public repository licenses via LongBench",
    "lcc": "Mixed public repository licenses via LongBench",
}


@dataclass(frozen=True)
class PreparedFamily:
    family_name: str
    dataset_path: Path
    questions_path: Path
    doc_ids: list[str]
    source_entries: list[dict]


def now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def ensure_dirs() -> None:
    for path in [RAW_ROOT, PROCESSED_ROOT, MANIFEST_ROOT]:
        path.mkdir(parents=True, exist_ok=True)


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=True) + "\n")


def write_json(path: Path, payload: dict | list) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def safe_id(text: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", text.strip())
    return cleaned.strip("_") or "item"


def make_session(user_agent: str) -> requests.Session:
    session = requests.Session()
    session.headers.update(SEC_HEADERS)
    session.headers["User-Agent"] = user_agent
    return session


def first_answer(row: dict) -> str:
    answers = row.get("answers") or []
    if isinstance(answers, list) and answers:
        return str(answers[0])
    if answers:
        return str(answers)
    return ""


def answer_anchors(row: dict) -> list[str]:
    answers = row.get("answers") or []
    if not isinstance(answers, list):
        answers = [answers]
    anchors = set()
    for answer in answers:
        anchors.update(extract_anchor_strings(str(answer)))
        if answer:
            anchors.add(str(answer))
    return sorted(anchors)


def extract_numeric_anchor(text: str) -> str | None:
    patterns = [
        r"\$\d[\d,]*(?:\.\d+)?",
        r"\b\d+(?:\.\d+)?%",
        r"\b\d{4}-\d{2}-\d{2}\b",
        r"\b\d{4}\b",
    ]
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return match.group(0)
    return None


def extract_negation_anchor(text: str) -> str | None:
    pattern = re.compile(
        r"\b(?:must not|shall not|do not|does not|did not|should not|would not|could not|cannot|can't|won't|never|not)\b",
        flags=re.IGNORECASE,
    )
    match = pattern.search(text)
    if match:
        return match.group(0)
    return None


def longbench_family() -> PreparedFamily:
    output_dir = PROCESSED_ROOT / "D1_longbench_qa"
    dataset_path = output_dir / "D1_longbench_qa.jsonl"
    questions_path = output_dir / "D1_longbench_qa_questions.jsonl"
    family_rows: list[dict] = []
    family_questions: list[dict] = []
    raw_sources: list[dict] = []
    doc_ids: list[str] = []

    specs = [
        ("hotpotqa_e", "hotpotqa", LONG_BENCH_QA_TARGET),
        ("narrativeqa", "narrativeqa", LONG_BENCH_QA_TARGET),
        ("qasper_e", "qasper", LONG_BENCH_QA_TARGET),
    ]

    for subset_name, dataset_name, target_count in specs:
        selected_raw: list[dict] = []
        selected_count = 0
        subset = load_dataset(
            "THUDM/LongBench",
            subset_name,
            split="test",
            trust_remote_code=True,
            **HF_DATASET_KWARGS,
        )
        for row in subset:
            context = str(row.get("context", "")).strip()
            question = str(row.get("input", "")).strip()
            if dataset_name == "lcc" and not question:
                language = str(row.get("language", "code")).strip() or "code"
                question = f"Predict the next line of {language} code for the provided context."
            if not context or not question:
                continue
            token_count = count_tokens(context)
            if token_count < MIN_LONG_QA_TOKENS or token_count > MAX_MAIN_TOKENS:
                continue
            source_id = safe_id(str(row.get("_id", selected_count + 1)))
            doc_id = f"D1_{dataset_name}_{selected_count + 1:03d}_{source_id[:24]}"
            meta = {
                "source": "longbench",
                "dataset": dataset_name,
                "subset": subset_name,
                "source_id": str(row.get("_id", "")),
                "license": LONG_BENCH_LICENSES[subset_name],
                "url": "https://huggingface.co/datasets/THUDM/LongBench",
                "retrieved_at": now_iso(),
                "tokens": token_count,
                "language": row.get("language", "en"),
                "original_length": row.get("length"),
            }
            family_rows.append({"id": doc_id, "role": "document", "content": context, "meta": meta})
            family_questions.append(
                {
                    "doc_id": doc_id,
                    "question": question,
                    "gold_answer": first_answer(row),
                    "gold_answers": row.get("answers", []),
                    "gold_anchors": answer_anchors(row),
                    "meta": {
                        "source": "longbench",
                        "dataset": dataset_name,
                        "subset": subset_name,
                    },
                }
            )
            selected_raw.append(row)
            raw_sources.append(
                {
                    "family": "D1_longbench_qa",
                    "dataset": dataset_name,
                    "subset": subset_name,
                    "url": "https://huggingface.co/datasets/THUDM/LongBench",
                    "license": LONG_BENCH_LICENSES[subset_name],
                    "retrieved_at": now_iso(),
                    "raw_path": str((RAW_ROOT / "longbench" / f"{subset_name}.sample.jsonl").relative_to(ROOT)).replace("\\", "/"),
                    "processed_dataset": str(dataset_path.relative_to(ROOT)).replace("\\", "/"),
                    "processed_questions": str(questions_path.relative_to(ROOT)).replace("\\", "/"),
                    "sample_count": 0,
                }
            )
            doc_ids.append(doc_id)
            selected_count += 1
            if selected_count >= target_count:
                break

        if selected_count < target_count:
            raise RuntimeError(f"Only found {selected_count} rows for {subset_name}; expected {target_count}")

        raw_path = RAW_ROOT / "longbench" / f"{subset_name}.sample.jsonl"
        write_jsonl(raw_path, selected_raw)
        raw_sources[-1]["sample_count"] = len(selected_raw)

    write_jsonl(dataset_path, family_rows)
    write_jsonl(questions_path, family_questions)
    return PreparedFamily("D1_longbench_qa", dataset_path, questions_path, doc_ids, raw_sources)


def code_family() -> PreparedFamily:
    output_dir = PROCESSED_ROOT / "D4_code"
    dataset_path = output_dir / "D4_code.jsonl"
    questions_path = output_dir / "D4_code_questions.jsonl"
    family_rows: list[dict] = []
    family_questions: list[dict] = []
    raw_sources: list[dict] = []
    doc_ids: list[str] = []

    specs = [
        ("repobench-p", "repobench-p", CODE_TARGET),
        ("lcc", "lcc", CODE_TARGET),
    ]

    for subset_name, dataset_name, target_count in specs:
        selected_raw: list[dict] = []
        selected_count = 0
        subset = load_dataset(
            "THUDM/LongBench",
            subset_name,
            split="test",
            trust_remote_code=True,
            **HF_DATASET_KWARGS,
        )
        for row in subset:
            context = str(row.get("context", "")).strip()
            question = str(row.get("input", "")).strip()
            if dataset_name == "lcc" and not question:
                language = str(row.get("language", "code")).strip() or "code"
                question = f"Predict the next line of {language} code for the provided context."
            if not context or not question:
                continue
            token_count = count_tokens(context)
            if token_count < MIN_CODE_TOKENS or token_count > MAX_MAIN_TOKENS:
                continue
            source_id = safe_id(str(row.get("_id", selected_count + 1)))
            doc_id = f"D4_{dataset_name.replace('-', '_')}_{selected_count + 1:03d}_{source_id[:20]}"
            meta = {
                "source": "longbench",
                "dataset": dataset_name,
                "subset": subset_name,
                "source_id": str(row.get("_id", "")),
                "license": LONG_BENCH_LICENSES[subset_name],
                "url": "https://huggingface.co/datasets/THUDM/LongBench",
                "retrieved_at": now_iso(),
                "tokens": token_count,
                "language": row.get("language", "code"),
            }
            family_rows.append({"id": doc_id, "role": "document", "content": context, "meta": meta})
            family_questions.append(
                {
                    "doc_id": doc_id,
                    "question": question,
                    "gold_answer": first_answer(row),
                    "gold_answers": row.get("answers", []),
                    "gold_anchors": answer_anchors(row),
                    "meta": {
                        "source": "longbench",
                        "dataset": dataset_name,
                        "subset": subset_name,
                    },
                }
            )
            selected_raw.append(row)
            doc_ids.append(doc_id)
            selected_count += 1
            if selected_count >= target_count:
                break

        if selected_count < target_count:
            raise RuntimeError(f"Only found {selected_count} rows for {subset_name}; expected {target_count}")

        raw_path = RAW_ROOT / "longbench" / f"{subset_name}.code.sample.jsonl"
        write_jsonl(raw_path, selected_raw)
        raw_sources.append(
            {
                "family": "D4_code",
                "dataset": dataset_name,
                "subset": subset_name,
                "url": "https://huggingface.co/datasets/THUDM/LongBench",
                "license": LONG_BENCH_LICENSES[subset_name],
                "retrieved_at": now_iso(),
                "raw_path": str(raw_path.relative_to(ROOT)).replace("\\", "/"),
                "processed_dataset": str(dataset_path.relative_to(ROOT)).replace("\\", "/"),
                "processed_questions": str(questions_path.relative_to(ROOT)).replace("\\", "/"),
                "sample_count": len(selected_raw),
            }
        )

    write_jsonl(dataset_path, family_rows)
    write_jsonl(questions_path, family_questions)
    return PreparedFamily("D4_code", dataset_path, questions_path, doc_ids, raw_sources)


def choose_best_path(messages: list[dict]) -> list[dict]:
    by_parent: dict[str | None, list[dict]] = defaultdict(list)
    by_id = {message["message_id"]: message for message in messages}
    root_id = None
    for message in messages:
        parent_id = message.get("parent_id")
        if parent_id is None:
            root_id = message["message_id"]
        by_parent[parent_id].append(message)
    if root_id is None:
        return []

    path = [by_id[root_id]]
    current_id = root_id
    while True:
        children = by_parent.get(current_id, [])
        if not children:
            break
        children = sorted(
            children,
            key=lambda item: (
                item.get("rank") if item.get("rank") is not None else 10_000,
                item["message_id"],
            ),
        )
        next_message = children[0]
        path.append(next_message)
        current_id = next_message["message_id"]
    return path


def render_history(turns: list[dict]) -> str:
    parts = []
    for turn in turns:
        role = turn["role"].upper()
        parts.append(f"[{role}]\n{turn['content']}")
    return "\n\n".join(parts)


def chat_family() -> PreparedFamily:
    output_dir = PROCESSED_ROOT / "D7_chat"
    dataset_path = output_dir / "D7_chat.jsonl"
    questions_path = output_dir / "D7_chat_questions.jsonl"
    family_rows: list[dict] = []
    family_questions: list[dict] = []
    raw_rows: list[dict] = []
    doc_ids: list[str] = []

    split_data = load_dataset("OpenAssistant/oasst1", **HF_DATASET_KWARGS)
    trees: dict[str, list[dict]] = defaultdict(list)
    for split_name in ["train", "validation"]:
        for row in split_data[split_name]:
            if row.get("deleted"):
                continue
            if row.get("lang") != "en":
                continue
            if row.get("tree_state") != "ready_for_export":
                continue
            trees[str(row["message_tree_id"])].append(dict(row))

    selected = 0
    for tree_id in sorted(trees):
        path = choose_best_path(trees[tree_id])
        if len(path) < 4 or len(path) > 8:
            continue
        if path[-2].get("role") != "prompter" or path[-1].get("role") != "assistant":
            continue

        history_messages = path[:-2]
        turns = []
        for message in history_messages:
            role = "user" if message["role"] == "prompter" else "assistant"
            turns.append({"role": role, "content": str(message["text"]).strip()})
        if len(turns) < 2:
            continue
        history_text = render_history(turns)
        history_tokens = count_tokens(history_text)
        if history_tokens < MIN_CHAT_HISTORY_TOKENS or history_tokens > MAX_MAIN_TOKENS:
            continue

        prompt_text = str(path[-2]["text"]).strip()
        answer_text = str(path[-1]["text"]).strip()
        if len(prompt_text) < 20 or len(answer_text) < 20:
            continue

        doc_id = f"D7_oasst1_{selected + 1:03d}_{safe_id(tree_id)[:24]}"
        base_meta = {
            "source": "oasst1",
            "tree_id": tree_id,
            "license": "Apache-2.0",
            "url": "https://huggingface.co/datasets/OpenAssistant/oasst1",
            "retrieved_at": now_iso(),
            "history_tokens": history_tokens,
            "turn_count": len(turns),
        }
        for index, turn in enumerate(turns):
            turn_meta = dict(base_meta)
            turn_meta["turn_index"] = index
            family_rows.append({"id": doc_id, "role": turn["role"], "content": turn["content"], "meta": turn_meta})

        family_questions.append(
            {
                "doc_id": doc_id,
                "question": prompt_text,
                "gold_answer": answer_text,
                "gold_anchors": sorted(extract_anchor_strings(answer_text)),
                "meta": {
                    "source": "oasst1",
                    "tree_id": tree_id,
                    "withheld_prompt_message_id": path[-2]["message_id"],
                    "withheld_answer_message_id": path[-1]["message_id"],
                },
            }
        )
        raw_rows.append(
            {
                "tree_id": tree_id,
                "history": history_messages,
                "question": path[-2],
                "answer": path[-1],
            }
        )
        doc_ids.append(doc_id)
        selected += 1
        if selected >= OASST1_TARGET:
            break

    if selected < OASST1_TARGET:
        raise RuntimeError(f"Only found {selected} OASST1 paths; expected {OASST1_TARGET}")

    raw_path = RAW_ROOT / "oasst1" / "oasst1.selected_trees.jsonl"
    write_jsonl(raw_path, raw_rows)
    write_jsonl(dataset_path, family_rows)
    write_jsonl(questions_path, family_questions)
    return PreparedFamily(
        "D7_chat",
        dataset_path,
        questions_path,
        doc_ids,
        [
            {
                "family": "D7_chat",
                "dataset": "oasst1",
                "subset": "ready_for_export_en",
                "url": "https://huggingface.co/datasets/OpenAssistant/oasst1",
                "license": "Apache-2.0",
                "retrieved_at": now_iso(),
                "raw_path": str(raw_path.relative_to(ROOT)).replace("\\", "/"),
                "processed_dataset": str(dataset_path.relative_to(ROOT)).replace("\\", "/"),
                "processed_questions": str(questions_path.relative_to(ROOT)).replace("\\", "/"),
                "sample_count": selected,
            }
        ],
    )


def extract_hits(payload: dict) -> list[dict]:
    hits = payload.get("hits")
    if isinstance(hits, dict):
        hits = hits.get("hits", [])
    if not isinstance(hits, list):
        return []
    items = []
    for hit in hits:
        if isinstance(hit, dict) and "_source" in hit:
            items.append(hit["_source"])
        elif isinstance(hit, dict) and "source" in hit:
            items.append(hit["source"])
        elif isinstance(hit, dict):
            items.append(hit)
    return items


def build_cfpb_content(record: dict) -> str:
    narrative = str(
        record.get("consumer_complaint_narrative")
        or record.get("complaint_what_happened")
        or ""
    ).strip()
    sections = [
        f"Product: {record.get('product', '')}",
        f"Sub-product: {record.get('sub_product', '')}",
        f"Company: {record.get('company', '')}",
        f"Date received: {record.get('date_received', '')}",
        f"Issue: {record.get('issue', '')}",
        f"Sub-issue: {record.get('sub_issue', '')}",
        f"Company response: {record.get('company_response', record.get('company_public_response', ''))}",
        "Narrative:",
        narrative,
    ]
    return "\n".join(line for line in sections if line and not line.endswith(": "))


def complaint_questions(doc_id: str, record: dict, content: str) -> list[dict]:
    questions = [
        {
            "doc_id": doc_id,
            "question": "What company is named in this complaint?",
            "gold_answer": str(record.get("company", "")).strip(),
            "gold_anchors": [str(record.get("company", "")).strip()],
        },
        {
            "doc_id": doc_id,
            "question": "What financial product is involved in this complaint?",
            "gold_answer": str(record.get("product", "")).strip(),
            "gold_anchors": [str(record.get("product", "")).strip()],
        },
        {
            "doc_id": doc_id,
            "question": "On what date was this complaint received?",
            "gold_answer": str(record.get("date_received", "")).strip(),
            "gold_anchors": [str(record.get("date_received", "")).strip()],
        },
    ]
    issue = str(record.get("issue", "")).strip()
    if issue:
        questions.append(
            {
                "doc_id": doc_id,
                "question": "What issue is recorded for this complaint?",
                "gold_answer": issue,
                "gold_anchors": [issue],
            }
        )
    negation = extract_negation_anchor(content)
    if negation:
        questions.append(
            {
                "doc_id": doc_id,
                "question": "Which exact negation phrase appears in this complaint narrative?",
                "gold_answer": negation,
                "gold_anchors": [negation],
            }
        )
    amount = extract_numeric_anchor(content)
    if amount:
        questions.append(
            {
                "doc_id": doc_id,
                "question": "Which exact numeric or monetary anchor appears in this complaint record?",
                "gold_answer": amount,
                "gold_anchors": [amount],
            }
        )
    return questions


def cfpb_records(session: requests.Session) -> list[dict]:
    selected: list[dict] = []
    company_counts: dict[str, int] = defaultdict(int)
    seen_ids: set[str] = set()
    url = "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/"

    for product in CFPB_PRODUCTS:
        page = 1
        while len(selected) < CFPB_TARGET and page <= 20:
            response = session.get(
                url,
                params={
                    "has_narrative": "true",
                    "product": product,
                    "date_received_min": "2018-01-01",
                    "date_received_max": "2023-12-31",
                    "size": 100,
                    "page": page,
                    "sort": "created_date_desc",
                },
                timeout=90,
            )
            response.raise_for_status()
            payload = response.json()
            hits = extract_hits(payload)
            if not hits:
                break
            for record in hits:
                complaint_id = str(
                    record.get("complaint_id")
                    or record.get("complaint_what_happened_id")
                    or record.get("id")
                    or ""
                )
                narrative = str(
                    record.get("consumer_complaint_narrative")
                    or record.get("complaint_what_happened")
                    or ""
                ).strip()
                company = str(record.get("company", "")).strip()
                if not complaint_id or complaint_id in seen_ids or not narrative or not company:
                    continue
                word_count = len(narrative.split())
                if word_count < 120 or word_count > 3000:
                    continue
                if company_counts[company] >= 4:
                    continue
                if "[xxxx]" in narrative.lower() and narrative.lower().count("[xxxx]") > 8:
                    continue
                if not record.get("consumer_consent_provided"):
                    continue
                selected.append(record)
                seen_ids.add(complaint_id)
                company_counts[company] += 1
                if len(selected) >= CFPB_TARGET:
                    break
            page += 1

    if len(selected) < CFPB_TARGET:
        raise RuntimeError(f"Only found {len(selected)} CFPB complaints; expected {CFPB_TARGET}")
    return selected[:CFPB_TARGET]


def cfpb_family(session: requests.Session) -> tuple[list[dict], list[dict], list[dict], list[str]]:
    dataset_rows: list[dict] = []
    questions: list[dict] = []
    doc_ids: list[str] = []
    records = cfpb_records(session)

    for index, record in enumerate(records, start=1):
        complaint_id = str(record.get("complaint_id") or record.get("id"))
        doc_id = f"D6_cfpb_{index:03d}_{safe_id(complaint_id)[:18]}"
        content = build_cfpb_content(record)
        meta = {
            "source": "cfpb",
            "source_id": complaint_id,
            "license": "Public CFPB complaint data; narratives are unverified consumer statements",
            "url": "https://www.consumerfinance.gov/data-research/consumer-complaints/",
            "retrieved_at": now_iso(),
            "product": record.get("product"),
            "company": record.get("company"),
            "issue": record.get("issue"),
            "tokens": count_tokens(content),
        }
        dataset_rows.append({"id": doc_id, "role": "document", "content": content, "meta": meta})
        questions.extend(complaint_questions(doc_id, record, content))
        doc_ids.append(doc_id)

    raw_path = RAW_ROOT / "cfpb" / "cfpb.selected_complaints.jsonl"
    write_jsonl(raw_path, records)
    return (
        dataset_rows,
        questions,
        [
            {
                "family": "D6_policy_legal",
                "dataset": "cfpb",
                "subset": "complaints_with_narratives",
                "url": "https://www.consumerfinance.gov/data-research/consumer-complaints/",
                "license": "Public CFPB complaint data; narratives are unverified consumer statements",
                "retrieved_at": now_iso(),
                "raw_path": str(raw_path.relative_to(ROOT)).replace("\\", "/"),
                "sample_count": len(records),
            }
        ],
        doc_ids,
    )


def company_ticker_map(session: requests.Session) -> dict[str, dict]:
    response = session.get("https://www.sec.gov/files/company_tickers.json", timeout=90)
    response.raise_for_status()
    payload = response.json()
    mapping = {}
    for item in payload.values():
        mapping[str(item["ticker"]).upper()] = item
    return mapping


def normalize_sec_text(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style"]):
        tag.decompose()
    text = soup.get_text("\n")
    lines = [re.sub(r"\s+", " ", line).strip() for line in text.splitlines()]
    lines = [line for line in lines if line]
    return "\n".join(lines)


def extract_sec_section(text: str) -> tuple[str, str] | None:
    compact = re.sub(r"\s+", " ", text)
    lower = compact.lower()
    section_specs = [
        (
            "Item 1A Risk Factors",
            re.compile(r"\bitem\s+1a\b.{0,80}?risk factors", flags=re.IGNORECASE),
            [
                re.compile(r"\bitem\s+1b\b", flags=re.IGNORECASE),
                re.compile(r"\bitem\s+2\b", flags=re.IGNORECASE),
            ],
        ),
        (
            "Item 7 Management Discussion and Analysis",
            re.compile(r"\bitem\s+7\b.{0,160}?management.{0,80}?discussion.{0,80}?analysis", flags=re.IGNORECASE),
            [
                re.compile(r"\bitem\s+7a\b", flags=re.IGNORECASE),
                re.compile(r"\bitem\s+8\b", flags=re.IGNORECASE),
            ],
        ),
    ]

    for section_name, start_pattern, end_patterns in section_specs:
        for start_match in start_pattern.finditer(lower):
            for end_pattern in end_patterns:
                end_match = end_pattern.search(lower, start_match.end() + 1500)
                if not end_match:
                    continue
                candidate = compact[start_match.start() : end_match.start()].strip()
                token_count = count_tokens(candidate)
                if token_count < MIN_SEC_TOKENS or token_count > MAX_SEC_TOKENS:
                    continue
                if not extract_negation_anchor(candidate):
                    continue
                if not extract_numeric_anchor(candidate):
                    continue
                return section_name, candidate
    return None


def sec_content(company: str, ticker: str, filing_date: str, section_name: str, section_text: str) -> str:
    header = [
        f"Company: {company} ({ticker})",
        f"Form: 10-K",
        f"Filing date: {filing_date}",
        f"Section: {section_name}",
        "Text:",
    ]
    return "\n".join(header) + "\n" + section_text


def sec_questions(doc_id: str, company: str, filing_date: str, section_name: str, content: str) -> list[dict]:
    questions = [
        {
            "doc_id": doc_id,
            "question": "What company does this filing section belong to?",
            "gold_answer": company,
            "gold_anchors": [company],
        },
        {
            "doc_id": doc_id,
            "question": "On what date was this 10-K filed?",
            "gold_answer": filing_date,
            "gold_anchors": [filing_date],
        },
        {
            "doc_id": doc_id,
            "question": "Which filing section is shown in this excerpt?",
            "gold_answer": section_name,
            "gold_anchors": [section_name],
        },
    ]
    negation = extract_negation_anchor(content)
    if negation:
        questions.append(
            {
                "doc_id": doc_id,
                "question": "Which exact negation phrase appears in this filing section?",
                "gold_answer": negation,
                "gold_anchors": [negation],
            }
        )
    amount = extract_numeric_anchor(content)
    if amount:
        questions.append(
            {
                "doc_id": doc_id,
                "question": "Which exact numeric or percentage anchor appears in this filing section?",
                "gold_answer": amount,
                "gold_anchors": [amount],
            }
        )
    return questions


def latest_10k_filing(session: requests.Session, cik: int) -> dict | None:
    cik_padded = f"{cik:010d}"
    response = session.get(f"https://data.sec.gov/submissions/CIK{cik_padded}.json", timeout=90)
    response.raise_for_status()
    recent = response.json().get("filings", {}).get("recent", {})
    forms = recent.get("form", [])
    filing_dates = recent.get("filingDate", [])
    accession_numbers = recent.get("accessionNumber", [])
    primary_documents = recent.get("primaryDocument", [])
    for index, form in enumerate(forms):
        if form != "10-K":
            continue
        filing_date = str(filing_dates[index])
        if filing_date < "2019-01-01" or filing_date > "2023-12-31":
            continue
        return {
            "filing_date": filing_date,
            "accession_number": accession_numbers[index],
            "primary_document": primary_documents[index],
        }
    return None


def sec_family(session: requests.Session) -> tuple[list[dict], list[dict], list[dict], list[str]]:
    dataset_rows: list[dict] = []
    questions: list[dict] = []
    doc_ids: list[str] = []
    raw_rows: list[dict] = []
    ticker_map = company_ticker_map(session)

    for index, (ticker, sector) in enumerate(SEC_COMPANIES, start=1):
        if len(dataset_rows) >= SEC_TARGET:
            break
        company_info = ticker_map.get(ticker)
        if not company_info:
            continue
        filing = latest_10k_filing(session, int(company_info["cik_str"]))
        if not filing:
            continue

        accession_nodash = filing["accession_number"].replace("-", "")
        filing_url = (
            f"https://www.sec.gov/Archives/edgar/data/{int(company_info['cik_str'])}/"
            f"{accession_nodash}/{filing['primary_document']}"
        )
        response = session.get(filing_url, timeout=90)
        response.raise_for_status()
        text = normalize_sec_text(response.text)
        section = extract_sec_section(text)
        time.sleep(0.11)
        if not section:
            continue
        section_name, section_text = section
        content = sec_content(str(company_info["title"]), ticker, filing["filing_date"], section_name, section_text)
        doc_id = f"D6_sec_{len(dataset_rows) + 1:03d}_{ticker.lower()}"
        meta = {
            "source": "sec-edgar",
            "source_id": filing["accession_number"],
            "license": "Public SEC EDGAR filing",
            "url": filing_url,
            "retrieved_at": now_iso(),
            "ticker": ticker,
            "company": company_info["title"],
            "sector": sector,
            "section": section_name,
            "filing_date": filing["filing_date"],
            "tokens": count_tokens(content),
        }
        dataset_rows.append({"id": doc_id, "role": "document", "content": content, "meta": meta})
        questions.extend(sec_questions(doc_id, str(company_info["title"]), filing["filing_date"], section_name, content))
        raw_rows.append(
            {
                "ticker": ticker,
                "company": company_info["title"],
                "sector": sector,
                "filing_date": filing["filing_date"],
                "accession_number": filing["accession_number"],
                "url": filing_url,
                "section": section_name,
                "content": section_text,
            }
        )
        doc_ids.append(doc_id)

    if len(dataset_rows) < SEC_TARGET:
        raise RuntimeError(f"Only found {len(dataset_rows)} SEC filings; expected {SEC_TARGET}")

    raw_path = RAW_ROOT / "sec" / "sec.selected_sections.jsonl"
    write_jsonl(raw_path, raw_rows)
    return (
        dataset_rows,
        questions,
        [
            {
                "family": "D6_policy_legal",
                "dataset": "sec-edgar",
                "subset": "10-K-risk-and-mda",
                "url": "https://www.sec.gov/search-filings",
                "license": "Public SEC EDGAR filing",
                "retrieved_at": now_iso(),
                "raw_path": str(raw_path.relative_to(ROOT)).replace("\\", "/"),
                "sample_count": len(raw_rows),
            }
        ],
        doc_ids,
    )


def policy_family(session: requests.Session) -> PreparedFamily:
    output_dir = PROCESSED_ROOT / "D6_policy_legal"
    dataset_path = output_dir / "D6_policy_legal.jsonl"
    questions_path = output_dir / "D6_policy_legal_questions.jsonl"

    sec_rows, sec_questions_rows, sec_sources, sec_doc_ids = sec_family(session)
    cfpb_rows, cfpb_questions_rows, cfpb_sources, cfpb_doc_ids = cfpb_family(session)

    dataset_rows = sec_rows + cfpb_rows
    question_rows = sec_questions_rows + cfpb_questions_rows
    doc_ids = sec_doc_ids + cfpb_doc_ids

    write_jsonl(dataset_path, dataset_rows)
    write_jsonl(questions_path, question_rows)
    return PreparedFamily(
        "D6_policy_legal",
        dataset_path,
        questions_path,
        doc_ids,
        sec_sources
        + cfpb_sources
        + [
            {
                "family": "D6_policy_legal",
                "dataset": "combined",
                "subset": "sec-plus-cfpb",
                "url": "https://www.sec.gov/search-filings ; https://www.consumerfinance.gov/data-research/consumer-complaints/",
                "license": "Mixed public source texts",
                "retrieved_at": now_iso(),
                "processed_dataset": str(dataset_path.relative_to(ROOT)).replace("\\", "/"),
                "processed_questions": str(questions_path.relative_to(ROOT)).replace("\\", "/"),
                "sample_count": len(dataset_rows),
            }
        ],
    )


def build_splits(families: list[PreparedFamily]) -> dict:
    payload = {"generated_at": now_iso(), "splits": {}}
    for family in families:
        ids = sorted(family.doc_ids)
        dev_count = max(1, round(len(ids) * 0.2))
        payload["splits"][family.family_name] = {
            "dataset": str(family.dataset_path.relative_to(ROOT)).replace("\\", "/"),
            "questions": str(family.questions_path.relative_to(ROOT)).replace("\\", "/"),
            "dev": ids[:dev_count],
            "test": ids[dev_count:],
        }
    return payload


def build_sources_manifest(families: list[PreparedFamily]) -> dict:
    entries: list[dict] = []
    for family in families:
        entries.extend(family.source_entries)
    return {"generated_at": now_iso(), "sources": entries}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare the faithful-compress benchmark datasets")
    parser.add_argument("--data-root", default=str(DATA_ROOT), help="Root output directory for test data")
    parser.add_argument(
        "--sec-user-agent",
        default="faithful-compress-benchmark/0.1 contact@example.com",
        help="User-Agent sent to SEC endpoints",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    del args.data_root

    load_env_file(ROOT / ".env")
    ensure_dirs()
    session = make_session(args.sec_user_agent)

    families = [
        longbench_family(),
        code_family(),
        chat_family(),
        policy_family(session),
    ]

    write_json(MANIFEST_ROOT / "sources.json", build_sources_manifest(families))
    write_json(MANIFEST_ROOT / "splits.json", build_splits(families))

    print("Prepared benchmark families:")
    for family in families:
        print(f"  - {family.family_name}: {len(family.doc_ids)} documents")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())