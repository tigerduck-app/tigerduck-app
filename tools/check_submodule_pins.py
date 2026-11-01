#!/usr/bin/env python3
"""Decide whether a pull request leaves each submodule pin acceptable.

A pull request to `main` needs every pin at its submodule's upstream tip. A pull request to
any other branch needs every pin on the upstream branch's history and not behind the pin of the
branch it merges into, so a feature branch need not chase the tip.

Run in a checkout of the pull request head with its submodules:
    python3 tools/check_submodule_pins.py --base-ref dev
Exit status: 0 when every pin is acceptable, 1 when one is not, 2 on a git error.
"""

import argparse
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE_BRANCH = "main"


def decide(base_ref: str, head: str, base: str | None, tip: str,
           is_ancestor: Callable[[str, str], bool]) -> list[str]:
    """The reasons a pin is not acceptable; `is_ancestor(a, b)` tells whether `a` is reachable from `b`."""
    if base_ref == RELEASE_BRANCH:
        return [] if head == tip else [f"is not the upstream tip ({tip})"]
    problems = []
    if not is_ancestor(head, tip):
        problems.append(f"is not on the upstream branch (tip {tip})")
    if base and head != base and is_ancestor(head, base):
        problems.append(f"is behind the pin on {base_ref} ({base})")
    return problems


def git(cwd: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"git {args[0]} exited {proc.returncode}")
    return proc


def submodules(root: Path) -> list[tuple[str, str, str]]:
    """(name, path, upstream branch) for each entry of .gitmodules."""
    listed = git(root, "config", "--file", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$").stdout
    found = []
    for line in listed.splitlines():
        key, path = line.split(" ", 1)
        name = key[len("submodule."):-len(".path")]
        branch = git(root, "config", "--file", ".gitmodules", f"submodule.{name}.branch", check=False).stdout.strip()
        found.append((name, path, branch or "main"))
    return found


def ancestor_in(repo: Path) -> Callable[[str, str], bool]:
    def is_ancestor(a: str, b: str) -> bool:
        proc = git(repo, "merge-base", "--is-ancestor", a, b, check=False)
        if proc.returncode > 1:
            raise RuntimeError(proc.stderr.strip() or f"cannot compare {a} with {b}")
        return proc.returncode == 0
    return is_ancestor


def base_pin(root: Path, path: str) -> str | None:
    proc = git(root, "rev-parse", "--verify", "--quiet", f"FETCH_HEAD:{path}", check=False)
    return proc.stdout.strip() or None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base-ref", required=True, help="branch the pull request merges into")
    args = parser.parse_args(argv)
    try:
        if args.base_ref != RELEASE_BRANCH:
            shallow = git(ROOT, "rev-parse", "--is-shallow-repository").stdout.strip() == "true"
            git(ROOT, "fetch", "--quiet", *(["--depth=1"] if shallow else []), "origin", args.base_ref)
        failed = 0
        for name, path, branch in submodules(ROOT):
            repo = ROOT / path
            git(repo, "fetch", "--quiet", "origin", branch)
            if git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() == "true":
                git(repo, "fetch", "--quiet", "--unshallow", "origin", branch)
            head = git(repo, "rev-parse", "HEAD").stdout.strip()
            tip = git(repo, "rev-parse", f"origin/{branch}").stdout.strip()
            base = None if args.base_ref == RELEASE_BRANCH else base_pin(ROOT, path)
            if base and git(repo, "cat-file", "-e", f"{base}^{{commit}}", check=False).returncode != 0:
                git(repo, "fetch", "--quiet", "origin", base, check=False)
            problems = decide(args.base_ref, head, base, tip, ancestor_in(repo))
            for problem in problems:
                print(f"::error::Submodule '{name}' ({path}) pinned at {head} {problem}. Bump before merging.")
            if not problems:
                print(f"OK {name} pin {head}")
            failed += bool(problems)
        return 1 if failed else 0
    except RuntimeError as error:
        print(f"check_submodule_pins.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
