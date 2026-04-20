#!/usr/bin/env python3
"""Small helpers for loading repo-local environment variables."""

from __future__ import annotations

import os
from pathlib import Path


def _strip_optional_quotes(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"\"", "'"}:
        return value[1:-1]
    return value


def load_repo_env(root: Path) -> dict[str, str]:
    env_path = root / ".env"
    loaded: dict[str, str] = {}
    if not env_path.exists():
        return loaded

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()

        key, separator, value = line.partition("=")
        if not separator:
            continue

        key = key.strip()
        if not key:
            continue

        parsed_value = _strip_optional_quotes(value.strip())
        current_value = os.environ.get(key)
        if current_value is None or current_value == "":
            os.environ[key] = parsed_value
        loaded[key] = parsed_value

    return loaded


def get_hf_token() -> str | None:
    for env_name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        token = os.environ.get(env_name)
        if token:
            return token
    return None


def hf_dataset_kwargs() -> dict[str, str]:
    token = get_hf_token()
    if not token:
        return {}
    return {"token": token}