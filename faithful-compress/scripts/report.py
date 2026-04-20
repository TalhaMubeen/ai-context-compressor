#!/usr/bin/env python3
"""Aggregate evaluation CSV files into a benchmark summary table."""

from __future__ import annotations

import argparse
import csv
import glob
from collections import defaultdict
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aggregate faithful-compress eval CSV files")
    parser.add_argument("inputs", nargs="+", help="CSV files or glob patterns")
    parser.add_argument("--output", help="Optional path for the markdown report")
    return parser.parse_args()


def expand_inputs(patterns: list[str]) -> list[Path]:
    resolved: list[Path] = []
    for pattern in patterns:
        path = Path(pattern)
        if any(char in pattern for char in "*?[]"):
            if path.is_absolute():
                resolved.extend(sorted(Path(match) for match in glob.glob(pattern)))
            else:
                resolved.extend(sorted(Path().glob(pattern)))
        elif path.exists():
            resolved.append(path)
    unique = []
    seen = set()
    for path in resolved:
        if path.resolve() in seen:
            continue
        unique.append(path)
        seen.add(path.resolve())
    return unique


def percentage(value: float) -> str:
    return f"{value:.1f}%"


def aggregate(csv_paths: list[Path]) -> str:
    buckets: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for path in csv_paths:
        dataset_name = path.stem
        with path.open(encoding="utf-8") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                buckets[(dataset_name, row["method"])].append(row)

    lines = [
        "| Dataset | Method | Tokens_orig | Tokens_comp | Reduction% | Answer_Equiv% | Exact% | Anchor_Ret% | N |",
        "|---------|--------|-------------|-------------|------------|----------------|--------|-------------|---|",
    ]

    for (dataset_name, method), rows in sorted(buckets.items()):
        n = len(rows)
        original_tokens = sum(int(row["original_tokens"]) for row in rows) / n
        compressed_tokens = sum(int(row["compressed_tokens"]) for row in rows) / n
        reduction_pct = sum(float(row["token_reduction_pct"]) for row in rows) / n
        exact_pct = sum(1 for row in rows if row["answer_equivalence"] == "exact") / n * 100.0
        semantic_or_exact = sum(
            1 for row in rows if row["answer_equivalence"] in {"exact", "semantic"}
        ) / n * 100.0
        anchor_retention = sum(float(row["anchor_retention"]) for row in rows) / n * 100.0
        lines.append(
            "| {dataset} | {method} | {orig:.0f} | {comp:.0f} | {reduction} | {equiv} | {exact} | {anchor} | {n} |".format(
                dataset=dataset_name,
                method=method,
                orig=original_tokens,
                comp=compressed_tokens,
                reduction=percentage(reduction_pct),
                equiv=percentage(semantic_or_exact),
                exact=percentage(exact_pct),
                anchor=percentage(anchor_retention),
                n=n,
            )
        )

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    csv_paths = expand_inputs(args.inputs)
    if not csv_paths:
        raise SystemExit("No CSV inputs matched")
    report = aggregate(csv_paths)
    if args.output:
        Path(args.output).write_text(report, encoding="utf-8")
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())