from pathlib import Path
import json
import unittest


ROOT = Path(__file__).resolve().parents[1]


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class BaseConfigurationContractTests(unittest.TestCase):
    def test_claude_settings_enable_only_superpowers(self):
        settings = json.loads(text(ROOT / ".claude/settings.json"))
        self.assertEqual(
            settings,
            {
                "enabledPlugins": {
                    "superpowers@claude-plugins-official": True,
                }
            },
        )

    def test_generated_agent_state_is_ignored(self):
        entries = set(text(ROOT / ".gitignore").splitlines())
        self.assertTrue(
            {
                ".superpowers/",
                ".worktrees/",
                ".venv/",
                "__pycache__/",
                "*.pyc",
            }.issubset(entries)
        )


if __name__ == "__main__":
    unittest.main()
