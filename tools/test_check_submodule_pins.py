"""Tests for tools/check_submodule_pins.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import subprocess
import tempfile
import unittest
from pathlib import Path

import check_submodule_pins as csp

# a -> b -> c is the upstream history, `x` is a commit outside it.
PARENTS = {"a": [], "b": ["a"], "c": ["b"], "x": ["a"]}


def ancestor(a: str, b: str) -> bool:
    seen, todo = set(), [b]
    while todo:
        commit = todo.pop()
        if commit == a:
            return True
        if commit not in seen:
            seen.add(commit)
            todo.extend(PARENTS[commit])
    return False


def decide(base_ref: str, head: str, base: str | None, tip: str = "c") -> list[str]:
    return csp.decide(base_ref, head, base, tip, ancestor)


class DecideTests(unittest.TestCase):
    def test_a_pull_request_to_main_needs_the_upstream_tip(self) -> None:
        self.assertEqual(decide("main", "c", "c"), [])
        self.assertEqual(len(decide("main", "b", "b")), 1)

    def test_a_pull_request_to_main_ignores_the_base_pin(self) -> None:
        self.assertEqual(decide("main", "c", "x"), [])

    def test_a_pull_request_to_dev_may_stay_behind_the_tip(self) -> None:
        self.assertEqual(decide("dev", "b", "b"), [])
        self.assertEqual(decide("dev", "b", "a"), [])

    def test_a_pull_request_to_dev_may_not_fall_behind_the_base_pin(self) -> None:
        problems = decide("dev", "a", "b")
        self.assertEqual(len(problems), 1)
        self.assertIn("behind the pin on dev", problems[0])

    def test_a_pin_off_the_upstream_branch_fails(self) -> None:
        problems = decide("dev", "x", "a")
        self.assertEqual(len(problems), 1)
        self.assertIn("not on the upstream branch", problems[0])

    def test_a_pin_both_off_the_branch_and_behind_reports_each(self) -> None:
        self.assertEqual(len(decide("dev", "b", "c", tip="x")), 2)

    def test_a_new_submodule_has_no_base_pin(self) -> None:
        self.assertEqual(decide("dev", "b", None), [])

    def test_an_unchanged_pin_passes(self) -> None:
        self.assertEqual(decide("dev", "c", "c"), [])


class GitTests(unittest.TestCase):
    def test_ancestor_in_reads_a_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            def run(*args: str) -> str:
                return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
                                       "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args], cwd=repo, check=True,
                                      capture_output=True, text=True).stdout.strip()
            run("init", "-q")
            run("commit", "-q", "--allow-empty", "-m", "one")
            first = run("rev-parse", "HEAD")
            run("commit", "-q", "--allow-empty", "-m", "two")
            second = run("rev-parse", "HEAD")
            is_ancestor = csp.ancestor_in(repo)
            self.assertTrue(is_ancestor(first, second))
            self.assertFalse(is_ancestor(second, first))
            with self.assertRaises(RuntimeError):
                is_ancestor("0" * 40, second)


if __name__ == "__main__":
    unittest.main()
