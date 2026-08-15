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

    def test_device_id_documents_require_exact_safe_launch_output(self):
        english_launch_pair = (
            "`DEVICE_ID=<complete device ID>` immediately followed by "
            "`DEVICE_ID_STATE=ready`"
        )
        chinese_launch_pair = (
            "`DEVICE_ID=<完整 device ID>`，紧接着打印 "
            "`DEVICE_ID_STATE=ready`"
        )
        english_validation = (
            "After trimming, a successful device ID must be one non-empty "
            "printable line."
        )
        chinese_validation = "修剪后，成功的 device ID 必须是一个非空可打印行。"

        for name in (
            "README.md",
            "docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md",
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md",
        ):
            contents = text(ROOT / name)
            self.assertIn(english_launch_pair, contents)
            self.assertIn("debug levels `0`, `1`, `2`, and `3`", contents)

        for name in (
            "README-zh_CN.md",
            "docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design-zh_CN.md",
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md",
        ):
            contents = text(ROOT / name)
            self.assertIn(chinese_launch_pair, contents)
            self.assertIn("debug levels `0`、`1`、`2` 和 `3`", contents)

        for name in (
            "docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md",
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md",
        ):
            contents = text(ROOT / name)
            self.assertIn(english_validation, contents)
            self.assertIn(
                "Reject CR, LF, NUL, every other C0 control character, and DEL "
                "before logging.",
                contents,
            )

        for name in (
            "docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design-zh_CN.md",
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md",
        ):
            contents = text(ROOT / name)
            self.assertIn(chinese_validation, contents)
            self.assertIn(
                "在记录前拒绝 CR、LF、NUL、所有其他 C0 control character 和 DEL。",
                contents,
            )

        english_pair = (
            "`DEVICE_ID=<complete device ID>` immediately followed by "
            "`DEVICE_ID_STATE=ready`"
        )
        chinese_pair = (
            "`DEVICE_ID=<完整 device ID>`，紧接着输出 "
            "`DEVICE_ID_STATE=ready`"
        )
        for name in (
            "docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md",
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md",
        ):
            contents = text(ROOT / name)
            for level in range(4):
                matrix_line = next(
                    line
                    for line in contents.splitlines()
                    if f"`debug_level={level}`" in line
                )
                self.assertIn(english_pair, matrix_line)

        for name in (
            "docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design-zh_CN.md",
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md",
        ):
            contents = text(ROOT / name)
            for level in range(4):
                matrix_line = next(
                    line
                    for line in contents.splitlines()
                    if f"`debug_level={level}`" in line
                )
                self.assertIn(chinese_pair, matrix_line)

        for name in (
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md",
            "docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md",
        ):
            contents = text(ROOT / name)
            for fixture in (
                "readiness-empty",
                "readiness-multiline",
                "readiness-nul",
                "readiness-c0",
                "readiness-del",
                "readiness-cli-failure",
            ):
                self.assertIn(fixture, contents)
            self.assertIn("self.assertEqual(result.returncode, 1)", contents)
            self.assertIn('self.assertEqual(result.stdout, "")', contents)
            self.assertIn("self.assertNotIn(unsafe_output", contents)

    def assert_shutdown_acceptance_contract(
        self,
        english_plan: str,
        chinese_plan: str,
    ):
        english_step = english_plan[
            english_plan.index("- [ ] **Step 7: Run the manual mobile-client") :
            english_plan.index("- [ ] **Step 8: Final verification")
        ]
        chinese_step = chinese_plan[
            chinese_plan.index("- [ ] **步骤 7：运行手动 mobile-client") :
            chinese_plan.index("- [ ] **步骤 8：最终验证")
        ]

        for requirement in (
            "The executable injected shutdown-wait self-test is the deterministic acceptance",
            "Live acceptance requires a successful mobile-client connection and observation of the requested real shutdown/offline effect.",
            "Once real shutdown/restart begins, final GitHub log, result, and cleanup evidence are best-effort",
            "Missing reporting after shutdown/restart begins must not be treated as a watcher failure",
        ):
            self.assertIn(requirement, english_step)

        for requirement in (
            "Executable injected shutdown-wait self-test 是确定性验收",
            "Live acceptance 要求 mobile-client 连接成功，并观察到所请求的真实 shutdown/offline effect。",
            "真实 shutdown/restart 开始后，最终 GitHub log、result 与 cleanup evidence 仅作 best-effort",
            "shutdown/restart 开始后缺少回传不得被判定为 watcher failure",
        ):
            self.assertIn(requirement, chinese_step)

        self.assertNotIn(
            "Require exact `WAIT_RESULT=shutdown/restart` and verify cleanup completes.",
            english_step,
        )
        self.assertNotIn(
            "要求精确 `WAIT_RESULT=shutdown/restart`，并验证 cleanup 完成。",
            chinese_step,
        )

    def test_shutdown_acceptance_separates_deterministic_and_live_evidence(self):
        english_design = text(
            ROOT
            / "docs/superpowers/specs/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design.md"
        )
        chinese_design = text(
            ROOT
            / "docs/superpowers/specs/2026-08-11-uuremote-secrets-and-shutdown-aware-wait-design-zh_CN.md"
        )
        english_plan = text(
            ROOT
            / "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md"
        )
        chinese_plan = text(
            ROOT
            / "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md"
        )

        self.assertIn(
            "the runner may lose networking before it can send\nthe final step result",
            english_design,
        )
        self.assertIn(
            "runner 可能在向 GitHub 发送最终步骤结果前失去网络",
            chinese_design,
        )
        self.assert_shutdown_acceptance_contract(english_plan, chinese_plan)

    def test_shutdown_acceptance_rejects_historical_live_only_guarantee(self):
        english_plan = text(
            ROOT
            / "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md"
        )
        chinese_plan = text(
            ROOT
            / "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md"
        )
        english_mutation = english_plan.replace(
            "- [ ] **Step 8: Final verification",
            "Require exact `WAIT_RESULT=shutdown/restart` and verify cleanup completes.\n\n"
            "- [ ] **Step 8: Final verification",
            1,
        )
        chinese_mutation = chinese_plan.replace(
            "- [ ] **步骤 8：最终验证",
            "要求精确 `WAIT_RESULT=shutdown/restart`，并验证 cleanup 完成。\n\n"
            "- [ ] **步骤 8：最终验证",
            1,
        )

        for language, mutated_english, mutated_chinese in (
            ("English", english_mutation, chinese_plan),
            ("Simplified Chinese", english_plan, chinese_mutation),
        ):
            with self.subTest(language=language):
                with self.assertRaises(AssertionError):
                    self.assert_shutdown_acceptance_contract(
                        mutated_english,
                        mutated_chinese,
                    )


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
