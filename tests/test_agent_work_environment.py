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

        self.assertEqual(
            english_step.strip().split("\n\n"),
            [
                "- [ ] **Step 7: Run the manual mobile-client and shutdown/restart acceptance**",
                "Dispatch a Windows debug-level `0` run with a user-approved positive wait duration. Tell the user the run has entered `Wait connections`; the user copies the visible device ID and connects with the separately held custom code. Record only whether connection succeeded, never the custom code.",
                "The executable injected shutdown-wait self-test is the deterministic acceptance for exact `WAIT_RESULT=shutdown/restart` output and the cleanup contract. Run it before live acceptance and require it to pass.",
                "Live acceptance requires a successful mobile-client connection and observation of the requested real shutdown/offline effect. Run a separate positive-wait acceptance for shutdown/restart. The user initiates the remote shutdown/restart action; the agent must not issue an operating-system shutdown command.",
                "Once real shutdown/restart begins, final GitHub log, result, and cleanup evidence are best-effort because the runner may lose networking before reporting them. Missing reporting after shutdown/restart begins must not be treated as a watcher failure and does not block acceptance when the deterministic self-test has passed and the live connection and shutdown/offline effect were observed.",
            ],
        )
        self.assertEqual(
            chinese_step.strip().split("\n\n"),
            [
                "- [ ] **步骤 7：运行手动 mobile-client 与 shutdown/restart acceptance**",
                "使用用户批准的正 wait duration dispatch Windows debug-level `0` run。通知用户 run 已进入 `Wait connections`；用户复制可见 device ID，并使用单独持有的 custom code 连接。只记录是否连接成功，绝不记录 custom code。",
                "Executable injected shutdown-wait self-test 是确定性验收，用于验证精确 `WAIT_RESULT=shutdown/restart` 输出与 cleanup contract。在 live acceptance 前运行并要求它通过。",
                "Live acceptance 要求 mobile-client 连接成功，并观察到所请求的真实 shutdown/offline effect。使用独立 positive-wait run 验收 shutdown/restart。由用户发起 remote shutdown/restart action；agent 禁止执行 operating-system shutdown command。",
                "真实 shutdown/restart 开始后，最终 GitHub log、result 与 cleanup evidence 仅作 best-effort，因为 runner 可能在回传前失去网络。shutdown/restart 开始后缺少回传不得被判定为 watcher failure；当确定性 self-test 已通过，且已观察到 live connection 与 shutdown/offline effect 时，该回传缺失不阻塞验收。",
            ],
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
        english_device_id_design = text(
            ROOT
            / "docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md"
        )
        chinese_device_id_design = text(
            ROOT
            / "docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design-zh_CN.md"
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

        for requirement in (
            "The executable injected shutdown-wait self-test provides deterministic evidence for the exact `WAIT_RESULT=shutdown/restart` result and cleanup contract.",
            "Live acceptance is separate: it requires a successful mobile-client connection and observation of the requested real shutdown/offline effect.",
            "Post-shutdown/restart GitHub log, result, and cleanup reporting is best-effort and non-blocking.",
        ):
            self.assertIn(requirement, english_device_id_design)

        for requirement in (
            "Executable injected shutdown-wait self-test 为精确 `WAIT_RESULT=shutdown/restart` 结果与 cleanup contract 提供确定性 evidence。",
            "Live acceptance 与此分开：它要求 mobile-client 连接成功，并观察到所请求的真实 shutdown/offline effect。",
            "Shutdown/restart 后的 GitHub log、result 与 cleanup reporting 仅作 best-effort，且不阻塞验收。",
        ):
            self.assertIn(requirement, chinese_device_id_design)

    def test_shutdown_acceptance_rejects_any_additional_contradictory_requirement(self):
        english_plan = text(
            ROOT
            / "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md"
        )
        chinese_plan = text(
            ROOT
            / "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md"
        )
        contradictory_requirements = (
            (
                "Require exact `WAIT_RESULT=shutdown/restart` and verify cleanup completes.",
                "要求精确 `WAIT_RESULT=shutdown/restart`，并验证 cleanup 完成。",
            ),
            (
                "Require the live run to report its final GitHub result and cleanup evidence after shutdown/restart.",
                "要求 live run 在 shutdown/restart 后回传最终 GitHub result 与 cleanup evidence。",
            ),
            (
                "Treat missing post-shutdown GitHub reporting as a watcher failure.",
                "将 shutdown 后缺少 GitHub 回传判定为 watcher failure。",
            ),
        )

        for index, (english_requirement, chinese_requirement) in enumerate(
            contradictory_requirements
        ):
            english_mutation = english_plan.replace(
                "- [ ] **Step 8: Final verification",
                f"{english_requirement}\n\n- [ ] **Step 8: Final verification",
                1,
            )
            chinese_mutation = chinese_plan.replace(
                "- [ ] **步骤 8：最终验证",
                f"{chinese_requirement}\n\n- [ ] **步骤 8：最终验证",
                1,
            )
            for language, mutated_english, mutated_chinese in (
                ("English", english_mutation, chinese_plan),
                ("Simplified Chinese", english_plan, chinese_mutation),
            ):
                with self.subTest(index=index, language=language):
                    with self.assertRaises(AssertionError):
                        self.assert_shutdown_acceptance_contract(
                            mutated_english,
                            mutated_chinese,
                        )

    def test_active_macos_readiness_documents_delegate_timing_to_the_helper(self):
        documents = (
            "docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md",
            "docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design-zh_CN.md",
            "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md",
            "docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md",
            "docs/superpowers/specs/2026-08-16-macos-device-id-readiness-design.md",
            "docs/superpowers/specs/2026-08-16-macos-device-id-readiness-design-zh_CN.md",
        )
        obsolete_requirements = (
            "Preserve 120 attempts",
            "保留 120 attempts",
            "The `Launch GameViewer` polling loop",
            "`Launch GameViewer` polling loop",
            "macos.yml owns the production polling loop",
            "macos.yml 负责 production polling loop",
        )

        for name in documents:
            with self.subTest(name=name):
                contents = text(ROOT / name)
                self.assertIn("launch-and-wait-device", contents)
                self.assertTrue("60-second" in contents or "60 秒" in contents)
                self.assertTrue("500-millisecond" in contents or "500 毫秒" in contents)
                for obsolete_requirement in obsolete_requirements:
                    self.assertNotIn(obsolete_requirement, contents)


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
