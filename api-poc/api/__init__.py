"""Shared constants and helpers for backend/api POC scripts."""

from __future__ import annotations

import os
from pathlib import Path

RUNTIME_DIR = Path(__file__).parent / "runtime"
RUNTIME_DIR.mkdir(exist_ok=True)

ENV_FILE = Path(__file__).parent / ".env"


def load_env_file(path: Path = ENV_FILE) -> dict[str, str]:
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def load_creds() -> tuple[str, str]:
    """Return (STUDENT_ID, PASSWORD) from .env or env vars; raise if missing."""
    env = load_env_file()
    sid = env.get("STUDENT_ID") or os.getenv("STUDENT_ID") or ""
    pwd = env.get("PASSWORD") or os.getenv("PASSWORD") or ""
    if not sid or not pwd:
        raise RuntimeError(
            "Missing STUDENT_ID or PASSWORD in backend/api/.env or environment"
        )
    return sid, pwd
