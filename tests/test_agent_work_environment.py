import ast
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

    def test_unattended_cleanup_policy_is_bounded_fail_closed_in_both_languages(self):
        english_documents = (
            "docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design.md",
            "docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics.md",
        )
        chinese_documents = (
            "docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md",
            "docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md",
        )
        english_requirements = (
            "bounded fail-closed cleanup policy",
            "`TERM`→`KILL`→reap/PGID probe",
            "confirmed cleanup publishes the existing safe status",
            "Unconfirmed cleanup or an exception publishes no final status and exits `125`",
            "no subsequent normal or provisioning operation continues",
            "Only the existing `always()` finalization/artifact-upload steps and hosted-runner teardown may execute.",
            "Raw assist payload, secrets, device connection data, and the new `ASSIST_DIAGNOSTIC_*` fields never enter artifacts; those fields remain in the current-step log only. The existing sanitized CLI diagnostics may be uploaded by the `always()` artifact step.",
            "Cleanup may add only the documented fixed cleanup grace beyond a CLI attempt; it never waits indefinitely.",
            "Current GitHub-hosted macOS runner teardown is external containment after job failure.",
            "the runner must be quarantined and not reused until an operator confirms no residue",
            "OS-level residue may remain unconfirmed; no absolute cleanup claim is made.",
        )
        chinese_requirements = (
            "有界 fail-closed 清理策略",
            "`TERM`→`KILL`→回收/PGID 探测",
            "确认清理后才发布现有安全 status",
            "未确认清理或异常不发布最终 status，并以 `125` 退出",
            "后续 normal 或 provisioning operation 不继续",
            "只有现有 `always()` finalization/artifact-upload step 和 hosted-runner teardown 可以执行。",
            "原始 assist payload、secrets、device connection data 和新的 `ASSIST_DIAGNOSTIC_*` fields 绝不进入 artifact；这些 fields 只保留在当前 step 日志。现有 sanitized CLI diagnostics 可以由 `always()` artifact step 上传。",
            "清理最多只能在一次 CLI attempt 之外增加已记录的固定清理宽限；绝不无限等待。",
            "当前 GitHub-hosted macOS runner 在 job 失败后的 teardown 属于外部遏制。",
            "该 runner 必须被隔离，且在 operator 确认无残留前不得复用",
            "OS-level 残留可能仍无法确认；不得声称绝对清理。",
        )
        obsolete_requirements = (
            "It must not return while an owned child or descendant remains.",
            "owned child 或 descendant 仍存在时不得返回。",
            "workflow/job does not continue",
            "workflow/job 不继续",
        )

        for name in english_documents:
            contents = text(ROOT / name)
            with self.subTest(name=name):
                for requirement in english_requirements:
                    self.assertIn(requirement, contents)
                for obsolete_requirement in obsolete_requirements:
                    self.assertNotIn(obsolete_requirement, contents)

        for name in chinese_documents:
            contents = text(ROOT / name)
            with self.subTest(name=name):
                for requirement in chinese_requirements:
                    self.assertIn(requirement, contents)
                for obsolete_requirement in obsolete_requirements:
                    self.assertNotIn(obsolete_requirement, contents)

    def test_diagnostic_design_limits_temporary_tree_cleanup_claims(self):
        contracts = (
            (
                "docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design.md",
                "Private temporary files are truncated or removal is attempted immediately.",
                "Confirmed paths remove private temporary files before return.",
                "A cleanup failure makes no absence-of-residue claim.",
                "Hosted-runner teardown is external containment, and a self-hosted runner is quarantined until an operator confirms no residue.",
                "the complete temporary tree is removed before return",
            ),
            (
                "docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md",
                "立即清空私有临时文件或尝试将其删除。",
                "确认的路径会在返回前删除私有临时文件。",
                "清理失败时不得声称不存在残留。",
                "hosted-runner teardown 属于外部遏制；self-hosted runner 必须被隔离，直至 operator 确认无残留。",
                "返回前删除完整 temporary tree",
            ),
        )

        for name, immediate, confirmed, no_claim, containment, obsolete in contracts:
            with self.subTest(name=name):
                contents = text(ROOT / name)

                def assert_cleanup_claim_contract(candidate: str) -> None:
                    for required in (immediate, confirmed, no_claim, containment):
                        self.assertIn(required, candidate)
                    self.assertNotIn(obsolete, candidate)

                assert_cleanup_claim_contract(contents)
                with self.assertRaises(AssertionError):
                    assert_cleanup_claim_contract(contents.replace(no_claim, "", 1))

    def test_unattended_plan_documents_atomic_late_success_timeout(self):
        contracts = (
            (
                "docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics.md",
                "ASSIST_DIAGNOSTIC_ATTEMPTS=1",
                "ASSIST_DIAGNOSTIC_TIMEOUT_COUNT=1",
                "ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=0",
                "ASSIST_DIAGNOSTIC_FINAL_CATEGORY=timeout",
                "ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=timeout",
                "ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=1",
            ),
            (
                "docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md",
                "ASSIST_DIAGNOSTIC_ATTEMPTS=1",
                "ASSIST_DIAGNOSTIC_TIMEOUT_COUNT=1",
                "ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=0",
                "ASSIST_DIAGNOSTIC_FINAL_CATEGORY=timeout",
                "ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=timeout",
                "ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=1",
            ),
        )
        for name, *required, obsolete in contracts:
            with self.subTest(name=name):
                contents = text(ROOT / name)

                def assert_atomic_late_success_contract(candidate: str) -> None:
                    for field in required:
                        self.assertIn(field, candidate)
                    self.assertNotIn(obsolete, candidate)

                assert_atomic_late_success_contract(contents)
                with self.assertRaises(AssertionError):
                    assert_atomic_late_success_contract(
                        contents.replace(required[1], obsolete, 1)
                    )

    def test_unattended_cleanup_source_fails_closed_without_a_status(self):
        script = text(ROOT / ".github/workflows/apple.sh")
        runner_start = script.index("def cleanup_owned_process():")
        runner_end = script.index("raise SystemExit(exit_code)", runner_start)
        runner = script[runner_start:runner_end]
        outer_start = script.index("enable_assist_or_fail()")
        outer_end = script.index("self_test_cli_output_redaction()", outer_start)
        outer = script[outer_start:outer_end]

        self.assertIn("process_group_id = process.pid\n        owned_cleanup_required = True", runner)
        self.assertIn("cleanup_owned_process_no_throw", runner)
        self.assertIn("release_owned_process_if_confirmed", runner)
        self.assertIn("cleanup_owned_process_after_signal_block", runner)
        self.assertIn("cleanup_confirmed = release_owned_process_if_confirmed(", runner)
        self.assertIn("except Exception:", runner)
        self.assertIn("exit_code = 125", runner)
        self.assertIn("Could not enable unattended control within 60 seconds", outer)
        self.assertIn("return 1", outer)

        continuation_guard = "enable_assist_or_fail || exit 1"

        def assert_continuation_guard(source: str) -> None:
            self.assertIn(continuation_guard, source)
            self.assertLess(
                source.index(continuation_guard),
                source.index('runner_password="$(decode_kcpassword /etc/kcpassword)"'),
            )

        assert_continuation_guard(script)
        mutated_script = script.replace(
            continuation_guard,
            "enable_assist_or_fail",
            1,
        )
        with self.assertRaises(AssertionError):
            assert_continuation_guard(mutated_script)

    def test_unattended_plan_runner_matches_the_bounded_fail_closed_source(self):
        def extract_runner(source: str) -> str:
            wrapper_start = source.index("run_bounded_uuremote_cli_to_file_with_status() {")
            heredoc_start = source.index("<<'PYTHON'\n", wrapper_start)
            python_start = heredoc_start + len("<<'PYTHON'\n")
            python_end = source.index("\nPYTHON\n}", python_start)
            return source[python_start:python_end]

        def assert_runner_ast_parity(plan_runner: str, production_runner: str) -> None:
            plan_tree = ast.parse(plan_runner)
            production_tree = ast.parse(production_runner)
            self.assertEqual(
                ast.dump(plan_tree, include_attributes=False),
                ast.dump(production_tree, include_attributes=False),
            )

        def assert_runner_semantic_contract(plan_runner: str) -> None:
            plan_tree = ast.parse(plan_runner)
            imports = {
                alias.name
                for node in plan_tree.body
                if isinstance(node, ast.Import)
                for alias in node.names
            }
            self.assertIn("time", imports)

            functions = {
                node.name: node
                for node in plan_tree.body
                if isinstance(node, ast.FunctionDef)
            }
            self.assertIn("process_group_alive", functions)
            self.assertIn("cleanup_owned_process", functions)
            self.assertIn("block_handled_signals_for_cleanup", functions)
            self.assertIn("cleanup_owned_process_after_signal_block", functions)
            self.assertIn("restore_child_signal_mask", ast.dump(plan_tree))

            half_second_constants = [
                node.value
                for node in ast.walk(plan_tree)
                if isinstance(node, ast.Constant) and node.value == 0.5
            ]
            self.assertEqual(half_second_constants, [0.5, 0.5])

            probe_dump = ast.dump(functions["process_group_alive"], include_attributes=False)
            self.assertIn("Call(func=Attribute(value=Name(id='os'", probe_dump)
            self.assertIn("attr='killpg'", probe_dump)
            self.assertIn("Name(id='process_group_id'", probe_dump)
            self.assertIn("Constant(value=0)", probe_dump)

            cleanup_dump = ast.dump(functions["cleanup_owned_process"], include_attributes=False)
            self.assertIn("attr='SIGTERM'", cleanup_dump)
            self.assertIn("attr='SIGKILL'", cleanup_dump)
            self.assertIn("Name(id='cleanup_deadline'", cleanup_dump)

            generic_handler = next(
                handler
                for node in ast.walk(plan_tree)
                if isinstance(node, ast.Try)
                for handler in node.handlers
                if isinstance(handler.type, ast.Name) and handler.type.id == "Exception"
            )
            generic_body = ast.dump(
                ast.Module(body=generic_handler.body, type_ignores=[]),
                include_attributes=False,
            )
            self.assertIn("cleanup_owned_process_after_signal_block", generic_body)
            self.assertNotIn("write_status", generic_body)

            signal_blocker_dump = ast.dump(
                functions["block_handled_signals_for_cleanup"],
                include_attributes=False,
            )
            self.assertIn("Return(value=Constant(value=False))", signal_blocker_dump)
            self.assertIn("Return(value=Constant(value=True))", signal_blocker_dump)

            cleanup_gate_dump = ast.dump(
                functions["cleanup_owned_process_after_signal_block"],
                include_attributes=False,
            )
            self.assertIn("cleanup_owned_process_no_throw", cleanup_gate_dump)
            self.assertIn("release_owned_process_if_confirmed", cleanup_gate_dump)
            self.assertIn("signal_blocked", cleanup_gate_dump)
            self.assertIn(
                "Return(value=BoolOp(op=And(), values=[Name(id='signal_blocked'",
                cleanup_gate_dump,
            )
            self.assertIn(
                "process_group_id = process.pid\n        owned_cleanup_required = True",
                plan_runner,
            )
            self.assertIn(
                "signal_blocked = block_handled_signals_for_cleanup() is True",
                plan_runner,
            )

        def extract_assist_helper(source: str) -> str:
            start = source.index("ensure_assist_allowed() (")
            try:
                end = source.index("\n)\n\n", start) + 3
            except ValueError:
                end = source.index("\n)\n```", start) + 3
            return source[start:end]

        def extract_assist_supervisor(source: str) -> str:
            wrapper_start = source.index(
                "run_assist_allow_with_absolute_deadline() ("
            )
            heredoc_marker = "<<'PYTHON' &\n"
            heredoc_start = source.index(heredoc_marker, wrapper_start)
            python_start = heredoc_start + len(heredoc_marker)
            python_end = source.index("\nPYTHON\n", python_start)
            return source[python_start:python_end]

        def extract_assist_supervisor_wrapper(source: str) -> str:
            start = source.index("run_assist_allow_with_absolute_deadline() (")
            end = source.index("\n)\n", start) + 3
            return source[start:end]

        def assert_supervisor_shell_contract(wrapper: str) -> None:
            self.assertIn("trap cleanup_assist_supervisor EXIT\n", wrapper)
            self.assertIn(
                "trap forward_assist_supervisor_signal HUP INT TERM", wrapper
            )
            self.assertIn("<<'PYTHON' &", wrapper)
            self.assertIn("    /usr/bin/python3 - \\\n", wrapper)
            self.assertNotIn("    uuremote_python3 - \\\n", wrapper)
            self.assertIn('/bin/kill -TERM "$supervisor_pid"', wrapper)
            self.assertIn('if wait "$supervisor_pid"; then', wrapper)
            self.assertIn(
                'supervisor_pid=""\n    trap - HUP INT TERM\n'
                '    if [ "$supervisor_interrupted" -eq 1 ] &&\n'
                '        ! [ "$supervisor_decision_path" -ef '
                '"$supervisor_commit_source" ]; then\n'
                "        supervisor_status=125",
                wrapper,
            )
            self.assertIn(
                '/bin/ln "$supervisor_interrupt_source"',
                wrapper,
            )
            self.assertIn(
                'elif [ "$supervisor_decision_path" -ef \\\n'
                '                "$supervisor_commit_source" ]; then',
                wrapper,
            )
            self.assertIn('return "$supervisor_status"', wrapper)
            self.assertNotIn(
                "trap cleanup_assist_supervisor EXIT HUP INT TERM", wrapper
            )

        def assert_supervisor_semantic_contract(supervisor: str) -> None:
            tree = ast.parse(supervisor)
            normalized_supervisor = ast.unparse(tree)
            functions = {
                node.name: node
                for node in tree.body
                if isinstance(node, ast.FunctionDef)
            }
            for name in (
                "claim_interruption",
                "descendant_snapshot",
                "signal_owned_processes",
                "cleanup_worker",
                "remove_capture_files",
            ):
                self.assertIn(name, functions)

            fork = "worker_pid = os.fork()"
            deadline = "deadline = time.monotonic() + timeout_seconds"
            signal_block = (
                "previous_mask = signal.pthread_sigmask("
                "signal.SIG_BLOCK, handled_signals)"
            )
            parent_unmask = (
                "signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)"
            )
            for required in (signal_block, deadline, fork, parent_unmask):
                self.assertIn(required, supervisor)
            self.assertLess(supervisor.index(signal_block), supervisor.index(fork))
            self.assertLess(supervisor.index(deadline), supervisor.index(fork))
            handler_install = (
                "for handled_signal_number in handled_signals:\n"
                "        signal.signal(handled_signal_number, handled_signal)"
            )
            self.assertIn(handler_install, supervisor)
            self.assertLess(supervisor.index(signal_block), supervisor.index(handler_install))
            self.assertLess(supervisor.index(handler_install), supervisor.index(fork))
            self.assertGreater(
                supervisor.index(parent_unmask, supervisor.index(fork)),
                supervisor.index(fork),
            )
            self.assertIn("os.setsid()", supervisor)
            self.assertIn("for signal_number in (signal.SIGTERM, signal.SIGKILL):", supervisor)
            self.assertIn(
                '"UUREMOTE_ASSIST_INTERNAL_DEADLINE_MILLISECONDS"',
                supervisor,
            )
            self.assertIn("str(\n                    worker_deadline_milliseconds", supervisor)
            self.assertIn(
                "worker_deadline_milliseconds = deadline_milliseconds - "
                "finalization_reserve_milliseconds",
                normalized_supervisor,
            )
            self.assertIn(
                "'UUREMOTE_ASSIST_INTERNAL_DEADLINE_MILLISECONDS': "
                "str(worker_deadline_milliseconds)",
                normalized_supervisor,
            )

            handler = ast.dump(
                functions["handled_signal"], include_attributes=False
            )
            self.assertIn("claim_interruption", handler)
            self.assertIn("attr='pthread_sigmask'", handler)
            self.assertIn("attr='SIG_BLOCK'", handler)
            self.assertIn("Name(id='handled_signals'", handler)

            signaler = ast.dump(
                functions["signal_owned_processes"], include_attributes=False
            )
            self.assertIn("attr='killpg'", signaler)
            self.assertIn("attr='kill'", signaler)
            cleanup = ast.dump(functions["cleanup_worker"], include_attributes=False)
            self.assertIn("observe_worker_descendants", cleanup)
            self.assertIn("signal_owned_processes", cleanup)
            self.assertIn("Name(id='phase_deadline'", cleanup)
            self.assertIn("Name(id='recorded_pids'", cleanup)
            self.assertIn("Name(id='recorded_groups'", cleanup)
            cleanup_source = ast.unparse(functions["cleanup_worker"])
            self.assertIn(
                "for signal_number in (signal.SIGTERM, signal.SIGKILL):",
                cleanup_source,
            )
            self.assertEqual(
                cleanup_source.count(
                    "phase_deadline = min(time.monotonic() + 0.5, "
                    "absolute_cleanup_deadline)"
                ),
                1,
            )
            self.assertIn(
                "signal_owned_processes(recorded_pids, recorded_groups, "
                "signal_number)",
                cleanup_source,
            )

            main_snapshot = "observe_worker_descendants(snapshot_timeout)"
            main_reap = "wait_status = reap_worker_nonblocking()"
            self.assertIn(main_snapshot, supervisor)
            self.assertIn(main_reap, supervisor)
            self.assertLess(
                supervisor.index(main_snapshot), supervisor.index(main_reap)
            )
            self.assertIn("while time.monotonic() < cleanup_start:", supervisor)
            self.assertIn("cleanup_worker(deadline)", supervisor)
            observation_loop_start = supervisor.index(
                "while time.monotonic() < cleanup_start:"
            )
            observation_loop_end = supervisor.index(
                "    if wait_status is None:", observation_loop_start
            )
            self.assertIn(
                "time.sleep(min(0.01, remaining))",
                supervisor[observation_loop_start:observation_loop_end],
            )

            final_deadline = "if time.monotonic() >= deadline or"
            stdout_read = "stdout_bytes = stdout_path.read_bytes()"
            capture_cleanup = "if not remove_capture_files():"
            commit_marker = "os.link(commit_source_path, decision_path)"
            stdout_write = "sys.stdout.buffer.write(stdout_bytes)"
            self.assertLess(supervisor.index(final_deadline), supervisor.index(stdout_read))
            self.assertLess(supervisor.index(stdout_read), supervisor.index(capture_cleanup))
            capture_cleanup_index = supervisor.index(capture_cleanup)
            self.assertIn(
                "if time.monotonic() >= deadline:",
                supervisor[capture_cleanup_index:],
            )
            commit_deadline = supervisor.index(
                "if time.monotonic() >= deadline:",
                capture_cleanup_index,
            )
            self.assertLess(capture_cleanup_index, commit_deadline)
            precommit_block = (
                "precommit_mask = signal.pthread_sigmask("
                "signal.SIG_BLOCK, handled_signals)"
            )
            precommit_unblock = (
                "signal.pthread_sigmask(signal.SIG_SETMASK, precommit_mask)"
            )
            self.assertEqual(supervisor.count(precommit_block), 1)
            first_block = supervisor.index(precommit_block, commit_deadline)
            self.assertIn(precommit_unblock, supervisor[first_block:])
            first_unblock = supervisor.index(precommit_unblock, first_block)
            self.assertLess(commit_deadline, first_block)
            self.assertLess(first_block, first_unblock)
            self.assertLess(first_unblock, supervisor.index(commit_marker))
            self.assertLess(supervisor.index(commit_marker), supervisor.index(stdout_write))

        def assert_assist_deadline_contract(helper: str) -> None:
            status_read = 'status_record="$(/bin/cat "$status_path" 2>/dev/null)" || return 1'
            child_clock = helper.index("read_assist_now || return 1", helper.index(status_read))
            classification = helper.index("classify_assist_allow_response")
            record_validation = helper.index(
                '*) [ "$safe_exit" -le 255 ] || return 1 ;;',
                classification,
            )
            after_record_clock = helper.index(
                "read_assist_now || return 1", record_validation
            )
            self.assertLess(helper.index(status_read), child_clock)
            self.assertLess(child_clock, classification)
            self.assertLess(classification, record_validation)
            self.assertIn('wait_uuremote_poll "$sleep_timeout" 2>/dev/null || return 1', helper)

            accounting = helper.index('final_cli_exit="$safe_exit"')
            cleanup = helper.index("cleanup_assist_attempt || return 1", accounting)
            acceptance_clock = helper.index("read_assist_now || return 1", cleanup)
            success_output = helper.index("printf 'ASSIST_STATE=enabled\\n'", acceptance_clock)
            self.assertLess(record_validation, after_record_clock)
            self.assertLess(after_record_clock, accounting)
            self.assertLess(accounting, cleanup)
            self.assertLess(cleanup, acceptance_clock)
            self.assertLess(acceptance_clock, success_output)
            self.assertIn('enabled_true_count="$((enabled_true_count - 1))"', helper)
            self.assertIn('timeout_count="$((timeout_count + 1))"', helper)

        production_source = text(ROOT / ".github/workflows/apple.sh")
        self.assertIn(
            "ASSIST_ALLOW_FINALIZATION_RESERVE_MILLISECONDS=1500",
            production_source,
        )
        self.assertIn(
            'deadline="${assist_allow_absolute_deadline_milliseconds:-'
            '$((now + ASSIST_ALLOW_DEADLINE_MILLISECONDS))}"',
            production_source,
        )
        self.assertIn(
            "UUREMOTE_ASSIST_INTERNAL_DEADLINE_MILLISECONDS",
            production_source,
        )
        production_runner = extract_runner(production_source)
        production_supervisor_wrapper = extract_assist_supervisor_wrapper(
            production_source
        )
        production_supervisor = extract_assist_supervisor(production_source)
        assert_supervisor_shell_contract(production_supervisor_wrapper)
        assert_supervisor_semantic_contract(production_supervisor)
        assert_assist_deadline_contract(extract_assist_helper(production_source))
        for name in (
            "docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics.md",
            "docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md",
        ):
            plan_runner = extract_runner(text(ROOT / name))
            plan_source = text(ROOT / name)
            plan_supervisor_wrapper = extract_assist_supervisor_wrapper(plan_source)
            plan_supervisor = extract_assist_supervisor(plan_source)
            plan_helper = extract_assist_helper(plan_source)
            with self.subTest(name=name):
                assert_runner_ast_parity(plan_runner, production_runner)
                self.assertEqual(
                    plan_supervisor_wrapper, production_supervisor_wrapper
                )
                assert_runner_ast_parity(plan_supervisor, production_supervisor)
                assert_runner_semantic_contract(plan_runner)
                assert_supervisor_shell_contract(plan_supervisor_wrapper)
                assert_supervisor_semantic_contract(plan_supervisor)
                assert_assist_deadline_contract(plan_helper)
                with self.assertRaises(AssertionError):
                    assert_assist_deadline_contract(
                        plan_helper.replace(
                            "read_assist_now || return 1\n"
                            '        remaining=\"$((deadline - now))\"\n'
                            '        if [ \"$remaining\" -le 0 ]; then\n'
                            "            category=timeout\n"
                            "            safe_exit=timeout\n"
                            "        fi\n\n",
                            "",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_runner_semantic_contract(
                        plan_runner.replace("timeout=0.5", "timeout=0.75", 1),
                    )
                with self.assertRaises(AssertionError):
                    assert_runner_semantic_contract(
                        plan_runner.replace(
                            "os.killpg(process_group_id, 0)",
                            "return None",
                            1,
                        ),
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "deadline = time.monotonic() + timeout_seconds",
                            "deadline = time.monotonic() - timeout_seconds",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "deadline_milliseconds - finalization_reserve_milliseconds",
                            "deadline_milliseconds",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "for signal_number in (signal.SIGTERM, signal.SIGKILL):",
                            "for signal_number in (signal.SIGTERM,):",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "time.monotonic() + 0.5,",
                            "time.monotonic() + 0.75,",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "        observe_worker_descendants(snapshot_timeout)",
                            "        wait_status = reap_worker_nonblocking()",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "    if not claim_interruption():\n"
                            "        return\n"
                            "    signal.pthread_sigmask(signal.SIG_BLOCK, handled_signals)",
                            "    signal.pthread_sigmask(signal.SIG_BLOCK, handled_signals)",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_shell_contract(
                        plan_supervisor_wrapper.replace("<<'PYTHON' &", "<<'PYTHON'", 1)
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_shell_contract(
                        plan_supervisor_wrapper.replace(
                            "    /usr/bin/python3 - \\\n",
                            "    uuremote_python3 - \\\n",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_shell_contract(
                        plan_supervisor_wrapper.replace(
                            'if [ "$supervisor_interrupted" -eq 1 ] &&\n'
                            '        ! [ "$supervisor_decision_path" -ef '
                            '"$supervisor_commit_source" ]; then\n'
                            "        supervisor_status=125",
                            "if false; then\n        supervisor_status=125",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "    try:\n"
                            "        os.link(commit_source_path, decision_path)",
                            "    sys.stdout.buffer.write(stdout_bytes)\n"
                            "    try:\n"
                            "        os.link(commit_source_path, decision_path)",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "        remaining = cleanup_start - time.monotonic()\n"
                            "        if remaining <= 0:\n"
                            "            break\n"
                            "        time.sleep(min(0.01, remaining))",
                            "        remaining = cleanup_start - time.monotonic()\n"
                            "        if remaining <= 0:\n"
                            "            break\n"
                            "        time.sleep(min(0.1, remaining))",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "    if time.monotonic() >= deadline:\n"
                            "        raise SystemExit(125)\n"
                            "    precommit_mask = signal.pthread_sigmask",
                            "    if False:\n"
                            "        raise SystemExit(125)\n"
                            "    precommit_mask = signal.pthread_sigmask",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_supervisor_semantic_contract(
                        plan_supervisor.replace(
                            "    signal.pthread_sigmask(signal.SIG_SETMASK, precommit_mask)\n"
                            "    try:\n"
                            "        os.link(commit_source_path, decision_path)",
                            "    try:\n"
                            "        os.link(commit_source_path, decision_path)",
                            1,
                        )
                    )
                with self.assertRaises(AssertionError):
                    assert_runner_semantic_contract(
                        plan_runner.replace(
                            "return signal_blocked and cleanup_confirmed",
                            "return cleanup_confirmed",
                            1,
                        ),
                    )
                with self.assertRaises(AssertionError):
                    assert_runner_semantic_contract(
                        plan_runner.replace(
                            "process_group_id = process.pid\n        owned_cleanup_required = True",
                            "process_group_id = process.pid",
                            1,
                        ),
                    )
                with self.assertRaises(AssertionError):
                    assert_runner_semantic_contract(
                        plan_runner.replace(
                            "signal_blocked = block_handled_signals_for_cleanup() is True",
                            "signal_blocked = True",
                            1,
                        ),
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
