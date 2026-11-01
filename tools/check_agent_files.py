#!/usr/bin/env python3
"""Fail when the tree tracks a CLAUDE.md, .claude/CLAUDE.md or CLAUDE.local.md at any depth.

Claude Code loads only CLAUDE.md files when one exists and skips every AGENTS.md, so AGENTS.md
files are the only rule files.

Run manually:  python3 tools/check_agent_files.py
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = ("CLAUDE.md", "CLAUDE.local.md")


def forbidden(paths: list[str]) -> list[str]:
    """The tracked paths whose file name is a CLAUDE rule file; `.claude/CLAUDE.md` is one too."""
    return sorted(p for p in paths if p.rsplit("/", 1)[-1] in FORBIDDEN)


def main() -> int:
    tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, text=True,
                             check=True).stdout.split("\0")
    found = forbidden([p for p in tracked if p])
    for path in found:
        print(f"{path}: tracked rule file for Claude Code; move the rules into the nearest AGENTS.md "
              "(AGENTS.md, Agent files)")
    print(f"{len(found)} forbidden agent file(s)")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
