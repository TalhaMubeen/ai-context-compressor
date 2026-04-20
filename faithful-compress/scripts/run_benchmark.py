#!/usr/bin/env python3
"""Run the local benchmark pipeline across prepared dataset families."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

from env_utils import load_repo_env
from eval import load_dataset_with_roles, render_context_with_roles


ROOT = Path(__file__).resolve().parent.parent
PROCESSED_ROOT = ROOT / "test" / "data" / "processed"
RESULTS_ROOT = ROOT / "results"
SPLITS_PATH = ROOT / "test" / "data" / "manifests" / "splits.json"


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the faithful-compress benchmark")
    parser.add_argument("--prepare-datasets", action="store_true", help="Run dataset preparation first")
    parser.add_argument("--skip-eval", action="store_true", help="Only build compressed outputs")
    parser.add_argument("--model", default="claude-haiku-4-5", help="Answer model used by scripts/eval.py")
    parser.add_argument("--judge", default="claude-haiku-4-5", help="Judge model used by scripts/eval.py")
    parser.add_argument("--trials", type=int, default=1, help="Number of trials per question")
    parser.add_argument("--truncate-tokens", type=int, default=4096, help="Token budget for truncate-recent")
    parser.add_argument(
        "--strategies",
        default="anchors-only,no-anchors,light-filler,tail-rescue-static",
        help="Comma-separated faithful-compress-cli strategies",
    )
    parser.add_argument(
        "--compressor-prefix",
        default="cabal run faithful-compress-cli --",
        help="Command prefix used to invoke faithful-compress-cli",
    )
    parser.add_argument(
        "--processed-root",
        default=str(PROCESSED_ROOT),
        help="Directory containing prepared dataset families",
    )
    parser.add_argument(
        "--results-root",
        default=str(RESULTS_ROOT),
        help="Directory where compressed outputs and eval CSVs are written",
    )
    parser.add_argument(
        "--split",
        choices=["all", "dev", "test"],
        default="all",
        help="Use only a frozen split from test/data/manifests/splits.json",
    )
    parser.add_argument(
        "--families",
        help="Optional comma-separated family names to run, e.g. D1_longbench_qa,D6_policy_legal",
    )
    parser.add_argument(
        "--max-docs-per-family",
        type=int,
        default=0,
        help="Optional cap on the number of documents per family after split filtering",
    )
    parser.add_argument(
        "--confirm-full-run",
        action="store_true",
        help="Required for a live `--split all` run without a doc cap because it can make thousands of paid model calls",
    )
    parser.add_argument(
        "--family-workers",
        type=int,
        default=1,
        help="Number of dataset families to process in parallel. Total live API concurrency is roughly family-workers * api-workers.",
    )
    parser.add_argument(
        "--strategy-workers",
        type=int,
        default=max(1, min(4, os.cpu_count() or 1)),
        help="Number of local compression strategies to run in parallel per family.",
    )
    parser.add_argument(
        "--api-workers",
        type=int,
        default=4,
        help="Concurrent question/trial jobs passed through to scripts/eval.py.",
    )
    parser.add_argument(
        "--api-max-retries",
        type=int,
        default=4,
        help="Retries for transient live API failures inside scripts/eval.py.",
    )
    parser.add_argument(
        "--api-backoff-seconds",
        type=float,
        default=1.5,
        help="Base exponential backoff in seconds for transient live API failures.",
    )
    parser.add_argument(
        "--api-jitter-seconds",
        type=float,
        default=0.25,
        help="Random jitter added to live API retry sleeps.",
    )
    parser.add_argument("--force", action="store_true", help="Rebuild outputs even if they already exist")
    return parser.parse_args()


def truncate_to_last_tokens(text: str, max_tokens: int) -> str:
    try:
        import tiktoken

        enc = tiktoken.get_encoding("cl100k_base")
        tokens = enc.encode(text)
        if len(tokens) <= max_tokens:
            return text
        return enc.decode(tokens[-max_tokens:])
    except ImportError:
        return text[-max_tokens * 4 :]


def family_files(processed_root: Path) -> list[tuple[str, Path, Path]]:
    families = []
    for path in sorted(processed_root.iterdir()):
        if not path.is_dir():
            continue
        dataset_files = [item for item in path.glob("*.jsonl") if not item.name.endswith("_questions.jsonl")]
        question_files = list(path.glob("*_questions.jsonl"))
        if len(dataset_files) != 1 or len(question_files) != 1:
            continue
        families.append((path.name, dataset_files[0], question_files[0]))
    return families


def require_credentials(model: str, judge: str) -> None:
    required = set()
    for name in [model, judge]:
        lowered = name.lower()
        if lowered.startswith("openrouter:"):
            required.add("OPEN_ROUTER_API_KEY")
            continue
        if "gpt" in lowered:
            required.add("OPENAI_API_KEY")
        if "claude" in lowered:
            required.add("ANTHROPIC_API_KEY")
    missing = [name for name in sorted(required) if not os.environ.get(name)]
    if missing:
        raise SystemExit(
            "Missing API credentials for live evaluation: " + ", ".join(missing) + ". "
            "Set them in the environment or run with --skip-eval."
        )


def build_baselines(docs: dict[str, list[dict]], output_dir: Path, truncate_tokens: int, force: bool) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    doc_ids = list(docs.keys())
    if not force:
        have_all = all(
            (output_dir / f"{doc_id}.no-compression.txt").exists()
            and (output_dir / f"{doc_id}.truncate-recent.txt").exists()
            for doc_id in doc_ids
        )
        if have_all:
            print(f"  Baselines already exist in {output_dir.name}; skipping")
            return
    for doc_id, turns in docs.items():
        rendered = render_context_with_roles(turns)
        (output_dir / f"{doc_id}.no-compression.txt").write_text(rendered, encoding="utf-8")
        truncated = truncate_to_last_tokens(rendered, truncate_tokens)
        (output_dir / f"{doc_id}.truncate-recent.txt").write_text(truncated, encoding="utf-8")


def resolve_cli_command(prefix: str) -> list[str]:
    if prefix.strip() != "cabal run faithful-compress-cli --":
        return shlex.split(prefix)

    subprocess.run(["cabal", "build", "faithful-compress-cli"], check=True)
    result = subprocess.run(
        ["cabal", "list-bin", "faithful-compress-cli"],
        check=True,
        capture_output=True,
        text=True,
    )
    cli_path = result.stdout.strip()
    if not cli_path:
        raise RuntimeError("Could not resolve faithful-compress-cli binary path")
    return [cli_path]


def run_cli_strategy(
    cli_command: list[str],
    strategy: str,
    dataset_path: Path,
    output_dir: Path,
    doc_ids: list[str],
    force: bool,
) -> None:
    if not force:
        existing = all((output_dir / f"{doc_id}.{strategy}.txt").exists() for doc_id in doc_ids)
        if existing:
            print(f"  Strategy {strategy} already exists in {output_dir.name}; skipping")
            return

    cmd = cli_command + [
        "compress",
        "--strategy",
        strategy,
        "--input",
        str(dataset_path),
        "--output",
        str(output_dir),
    ]
    env = os.environ.copy()
    env.setdefault("FAITHFUL_PYTHON", sys.executable)
    subprocess.run(cmd, check=True, env=env)


def run_eval(dataset_path: Path, questions_path: Path, compressed_dir: Path, output_csv: Path, args: argparse.Namespace) -> None:
    cmd = [
        sys.executable,
        str(ROOT / "scripts" / "eval.py"),
        "--dataset",
        str(dataset_path),
        "--questions",
        str(questions_path),
        "--compressed",
        str(compressed_dir),
        "--output",
        str(output_csv),
        "--model",
        args.model,
        "--judge",
        args.judge,
        "--trials",
        str(args.trials),
        "--workers",
        str(args.api_workers),
        "--max-retries",
        str(args.api_max_retries),
        "--retry-backoff-seconds",
        str(args.api_backoff_seconds),
        "--retry-jitter-seconds",
        str(args.api_jitter_seconds),
    ]
    subprocess.run(cmd, check=True)


def run_report(eval_dir: Path) -> None:
    cmd = [
        sys.executable,
        str(ROOT / "scripts" / "report.py"),
        str(eval_dir / "*.csv"),
        "--output",
        str(eval_dir / "benchmark-summary.md"),
    ]
    subprocess.run(cmd, check=True)


def load_split_manifest() -> dict:
    if not SPLITS_PATH.exists():
        return {"splits": {}}
    return json.loads(SPLITS_PATH.read_text(encoding="utf-8"))


def selected_families(args: argparse.Namespace) -> set[str] | None:
    if not args.families:
        return None
    return {item.strip() for item in args.families.split(",") if item.strip()}


def choose_doc_ids(
    family_name: str,
    all_doc_ids: list[str],
    split_manifest: dict,
    split_name: str,
    max_docs_per_family: int,
) -> list[str]:
    if split_name == "all":
        selected = list(all_doc_ids)
    else:
        split_entry = split_manifest.get("splits", {}).get(family_name)
        if not split_entry:
            raise SystemExit(f"Split manifest missing family {family_name}")
        allowed = split_entry[split_name]
        allowed_set = set(allowed)
        selected = [doc_id for doc_id in all_doc_ids if doc_id in allowed_set]

    if max_docs_per_family > 0:
        selected = selected[:max_docs_per_family]
    return selected


def filter_questions(questions_path: Path, selected_doc_ids: set[str], output_path: Path) -> None:
    with questions_path.open(encoding="utf-8") as source, output_path.open("w", encoding="utf-8", newline="\n") as dest:
        for line in source:
            row = json.loads(line)
            if row["doc_id"] in selected_doc_ids:
                dest.write(json.dumps(row, ensure_ascii=True) + "\n")


def filter_dataset(dataset_path: Path, selected_doc_ids: set[str], output_path: Path) -> None:
    with dataset_path.open(encoding="utf-8") as source, output_path.open("w", encoding="utf-8", newline="\n") as dest:
        for line in source:
            row = json.loads(line)
            if row["id"] in selected_doc_ids:
                dest.write(json.dumps(row, ensure_ascii=True) + "\n")


def subset_suffix(args: argparse.Namespace) -> str:
    parts = []
    if args.split != "all":
        parts.append(args.split)
    if args.max_docs_per_family > 0:
        parts.append(f"limit{args.max_docs_per_family}")
    return ("." + ".".join(parts)) if parts else ""


def run_strategies(
    cli_command: list[str],
    strategies: list[str],
    dataset_path: Path,
    output_dir: Path,
    selected_ids: list[str],
    strategy_workers: int,
    force: bool,
) -> None:
    max_workers = max(1, min(strategy_workers, len(strategies)))
    if max_workers == 1:
        for strategy in strategies:
            run_cli_strategy(cli_command, strategy, dataset_path, output_dir, selected_ids, force)
        return

    print(f"  Running {len(strategies)} strategies with {max_workers} local workers")
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_strategy = {
            executor.submit(run_cli_strategy, cli_command, strategy, dataset_path, output_dir, selected_ids, force): strategy
            for strategy in strategies
        }
        for future in concurrent.futures.as_completed(future_to_strategy):
            strategy = future_to_strategy[future]
            try:
                future.result()
            except Exception as exc:
                raise RuntimeError(f"Strategy {strategy} failed") from exc
            print(f"  Finished strategy {strategy}")


def process_family(
    family_entry: tuple[str, Path, Path],
    *,
    args: argparse.Namespace,
    cli_command: list[str],
    split_manifest: dict,
    compressed_root: Path,
    eval_root: Path,
    strategies: list[str],
) -> None:
    family_name, dataset_path, questions_path = family_entry
    family_compressed = compressed_root / family_name
    family_compressed.mkdir(parents=True, exist_ok=True)
    all_docs = load_dataset_with_roles(str(dataset_path))
    selected_ids = choose_doc_ids(
        family_name,
        list(all_docs.keys()),
        split_manifest,
        args.split,
        args.max_docs_per_family,
    )
    if not selected_ids:
        print(f"Skipping {family_name}: no documents selected")
        return

    docs = {doc_id: all_docs[doc_id] for doc_id in selected_ids}
    print(
        f"Preparing methods for {family_name} ({len(selected_ids)} docs, split={args.split}, "
        f"strategy-workers={max(1, args.strategy_workers)})"
    )

    with tempfile.TemporaryDirectory(prefix=f"faithful-{family_name}-") as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        temp_dataset = temp_dir / dataset_path.name
        temp_questions = temp_dir / questions_path.name
        selected_id_set = set(selected_ids)
        filter_dataset(dataset_path, selected_id_set, temp_dataset)
        filter_questions(questions_path, selected_id_set, temp_questions)

        build_baselines(docs, family_compressed, args.truncate_tokens, args.force)
        run_strategies(
            cli_command,
            strategies,
            temp_dataset,
            family_compressed,
            selected_ids,
            args.strategy_workers,
            args.force,
        )

        if args.skip_eval:
            return

        output_csv = eval_root / f"{family_name}{subset_suffix(args)}.csv"
        if output_csv.exists() and not args.force:
            print(f"  Eval CSV {output_csv.name} already exists; skipping")
            return
        print(
            f"Evaluating {family_name} -> {output_csv.name} "
            f"(api-workers={max(1, args.api_workers)}, retries={args.api_max_retries})"
        )
        run_eval(temp_dataset, temp_questions, family_compressed, output_csv, args)


def main() -> int:
    args = parse_args()
    load_env_file(ROOT / ".env")
    processed_root = Path(args.processed_root)
    results_root = Path(args.results_root)
    compressed_root = results_root / "compressed"
    eval_root = results_root / "eval"
    compressed_root.mkdir(parents=True, exist_ok=True)
    eval_root.mkdir(parents=True, exist_ok=True)

    if args.prepare_datasets:
        subprocess.run([sys.executable, str(ROOT / "scripts" / "prepare_datasets.py")], check=True)

    families = family_files(processed_root)
    if not families:
        raise SystemExit("No prepared dataset families found. Run scripts/prepare_datasets.py first.")

    strategies = [item.strip() for item in args.strategies.split(",") if item.strip()]
    cli_command = resolve_cli_command(args.compressor_prefix)
    split_manifest = load_split_manifest()
    family_filter = selected_families(args)
    if not args.skip_eval:
        if args.split == "all" and args.max_docs_per_family == 0 and not args.confirm_full_run:
            raise SystemExit(
                "Refusing to launch a full live benchmark without confirmation. "
                "Use `--confirm-full-run` for the full paid run or start with "
                "`--split dev --max-docs-per-family 1`."
            )
        require_credentials(args.model, args.judge)

    target_families = [
        family_entry for family_entry in families if not family_filter or family_entry[0] in family_filter
    ]
    if not target_families:
        raise SystemExit("No dataset families matched the requested filters")

    family_workers = max(1, min(args.family_workers, len(target_families)))
    if family_workers == 1:
        for family_entry in target_families:
            process_family(
                family_entry,
                args=args,
                cli_command=cli_command,
                split_manifest=split_manifest,
                compressed_root=compressed_root,
                eval_root=eval_root,
                strategies=strategies,
            )
    else:
        print(f"Processing {len(target_families)} families with {family_workers} family workers")
        with concurrent.futures.ThreadPoolExecutor(max_workers=family_workers) as executor:
            future_to_family = {
                executor.submit(
                    process_family,
                    family_entry,
                    args=args,
                    cli_command=cli_command,
                    split_manifest=split_manifest,
                    compressed_root=compressed_root,
                    eval_root=eval_root,
                    strategies=strategies,
                ): family_entry[0]
                for family_entry in target_families
            }
            for future in concurrent.futures.as_completed(future_to_family):
                family_name = future_to_family[future]
                try:
                    future.result()
                except Exception as exc:
                    raise RuntimeError(f"Family {family_name} failed") from exc
                print(f"Finished family {family_name}")

    if not args.skip_eval:
        run_report(eval_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
