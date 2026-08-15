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


class AgentInstructionContractTests(unittest.TestCase):
    FILES = (
        "AGENTS.md",
        "AGENTS-zh_CN.md",
        "CLAUDE.md",
        "CLAUDE-zh_CN.md",
    )

    def test_instruction_files_exist_with_language_navigation(self):
        for name in self.FILES:
            with self.subTest(name=name):
                lines = text(ROOT / name).splitlines()
                self.assertTrue(lines[0].startswith("# "))
                self.assertEqual(lines[1], "")
                self.assertEqual(
                    lines[2],
                    (
                        "[English](AGENTS.md) | [简体中文](AGENTS-zh_CN.md)"
                        if name.startswith("AGENTS")
                        else "[English](CLAUDE.md) | [简体中文](CLAUDE-zh_CN.md)"
                    ),
                )
                self.assertEqual(lines[3], "")

    def test_device_id_is_loggable_while_credentials_remain_secret(self):
        english_policy = (
            "A UU Remote device ID is a loggable operational identifier"
        )
        chinese_policy = "UU Remote device ID 是可以记录到日志的 operational identifier"
        secret_token = "UUREMOTE_CUSTOM_CODE"

        for name in ("AGENTS.md", "CLAUDE.md"):
            contents = text(ROOT / name)
            self.assertIn(english_policy, contents)
            self.assertIn(secret_token, contents)
            self.assertIn("remains sensitive", contents)

        for name in ("AGENTS-zh_CN.md", "CLAUDE-zh_CN.md"):
            contents = text(ROOT / name)
            self.assertIn(chinese_policy, contents)
            self.assertIn(secret_token, contents)
            self.assertIn("仍然是敏感信息", contents)

        self.assertIn("DEVICE_ID=<complete device ID>", text(ROOT / "README.md"))
        self.assertIn("DEVICE_ID=<完整 device ID>", text(ROOT / "README-zh_CN.md"))


class EntryPointContractTests(unittest.TestCase):
    def test_readmes_have_navigation(self):
        for name in ("README.md", "README-zh_CN.md"):
            lines = text(ROOT / name).splitlines()
            self.assertEqual(lines[1], "")
            self.assertEqual(
                lines[2],
                "[English](README.md) | [简体中文](README-zh_CN.md)",
            )

    def test_capture_prompts_have_navigation(self):
        for name in (
            "capture-conversation.md",
            "capture-conversation-zh_CN.md",
        ):
            lines = text(ROOT / "docs/prompts" / name).splitlines()
            self.assertEqual(lines[1], "")
            self.assertEqual(
                lines[2],
                (
                    "[English](capture-conversation.md) | "
                    "[简体中文](capture-conversation-zh_CN.md)"
                ),
            )


class BilingualDocumentationContractTests(unittest.TestCase):
    def markdown_files(self) -> list[Path]:
        return sorted(ROOT.glob("*.md")) + sorted((ROOT / "docs").rglob("*.md"))

    def counterparts(self, path: Path) -> tuple[Path, Path]:
        if path.stem.endswith("-zh_CN"):
            english = path.with_name(path.stem.removesuffix("-zh_CN") + ".md")
            return english, path
        return path, path.with_name(path.stem + "-zh_CN.md")

    def test_every_markdown_file_has_exactly_one_counterpart(self):
        for path in self.markdown_files():
            english, chinese = self.counterparts(path)
            with self.subTest(path=path.relative_to(ROOT).as_posix()):
                self.assertTrue(english.is_file())
                self.assertTrue(chinese.is_file())
                self.assertNotIn("-zh_CN-zh_CN", path.name)

    def test_every_markdown_file_has_exact_navigation(self):
        checked: set[Path] = set()
        for path in self.markdown_files():
            english, chinese = self.counterparts(path)
            if english in checked:
                continue
            checked.add(english)
            expected = (
                f"[English]({english.name}) | "
                f"[简体中文]({chinese.name})"
            )
            for version in (english, chinese):
                lines = text(version).splitlines()
                with self.subTest(path=version.relative_to(ROOT).as_posix()):
                    self.assertGreaterEqual(len(lines), 5)
                    self.assertTrue(lines[0].startswith("# "))
                    self.assertEqual(lines[1], "")
                    self.assertEqual(lines[2], expected)
                    self.assertEqual(lines[3], "")
                    self.assertTrue(lines[4].strip())


if __name__ == "__main__":
    unittest.main()
