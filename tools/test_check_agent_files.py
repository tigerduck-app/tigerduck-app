"""Tests for tools/check_agent_files.py: python3 -m unittest discover -s tools -p 'test_*.py'"""
import unittest

import check_agent_files as caf


class AgentFilesTests(unittest.TestCase):
    def test_claude_rule_files_fail_at_any_depth(self) -> None:
        paths = ["CLAUDE.md", ".claude/CLAUDE.md", "swift/TigerDuck/CLAUDE.local.md", "a/b/c/CLAUDE.md", "x/claude.md"]
        self.assertEqual(caf.forbidden(paths), sorted(paths))

    def test_agents_files_and_lookalikes_pass(self) -> None:
        paths = ["AGENTS.md", "swift/AGENTS.md", ".claude/settings.json", "docs/CLAUDE.md.txt",
                 "docs/MYCLAUDE.md", ".claude/skills/x/SKILL.md"]
        self.assertEqual(caf.forbidden(paths), [])

    def test_the_repository_tracks_none(self) -> None:
        self.assertEqual(caf.main(), 0)


if __name__ == "__main__":
    unittest.main()
