from pathlib import Path
import ast
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/macos.yml"
SCRIPT_PATH = ROOT / ".github/workflows/apple.sh"
DIAGNOSTIC_HARNESS_PATH = ROOT / "tests/test_macos_diagnostic_redaction.sh"
MACOS_READINESS_HARNESS_PATH = ROOT / "tests/macos_readiness_harness.sh"
MACOS_ASSIST_ALLOW_HARNESS_PATH = ROOT / "tests/macos_assist_allow_harness.sh"
BASH_AVAILABLE = Path("/bin/bash").exists()
NATIVE_MACOS_BASH_AVAILABLE = BASH_AVAILABLE and sys.platform == "darwin"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]


def shell_if_block(script: str, gate: str) -> str:
    lines = script.splitlines()
    start = next(index for index, line in enumerate(lines) if line.strip() == gate)
    depth = 0

    for index in range(start, len(lines)):
        statement = lines[index].strip()
        if statement.startswith("if "):
            depth += 1
        elif statement == "fi":
            depth -= 1
            if depth == 0:
                return "\n".join(lines[start : index + 1])

    raise ValueError(f"Unterminated shell if block: {gate}")


class CustomCodeWorkflowTests(unittest.TestCase):
    def assert_failed_diagnostic_contract(self, launch: str):
        outer_gate = "if .github/workflows/apple.sh launch-and-wait-device"
        debug_gate = 'if [ "${UUREMOTE_DEBUG:-0}" != "0" ]; then'
        diagnostic = ".github/workflows/apple.sh diagnose-device-id || true"
        outer = shell_if_block(launch, outer_gate)
        outer_lines = outer.splitlines()
        else_index = next(
            index
            for index, line in enumerate(outer_lines)
            if line.strip() == "else"
        )
        self.assertEqual(
            outer_lines[else_index + 1].strip(),
            'launch_status="$?"',
        )
        failure = "\n".join(outer_lines[else_index + 1 : -1])
        debug = shell_if_block(failure, debug_gate)

        self.assertEqual(failure.count(diagnostic), 1)
        self.assertEqual(debug.count(diagnostic), 1)
        self.assertEqual(failure.count('exit "$launch_status"'), 1)
        self.assertLess(
            failure.index(debug) + len(debug),
            failure.index('exit "$launch_status"'),
        )

    def test_custom_code_is_required_masked_and_step_scoped(self):
        workflow = text(WORKFLOW_PATH)
        job_environment = workflow[
            workflow.index("    env:\n") : workflow.index("\n    steps:\n")
        ]
        self.assertIn("      - name: Configure UU Remote custom code\n", workflow)
        block = step_block(workflow, "Configure UU Remote custom code")

        self.assertNotIn("UUREMOTE_CUSTOM_CODE", job_environment)
        self.assertIn(
            "UUREMOTE_CUSTOM_CODE: ${{ secrets.UUREMOTE_CUSTOM_CODE }}",
            block,
        )
        self.assertIn("::add-mask::${UUREMOTE_CUSTOM_CODE}", block)
        self.assertIn("apple.sh set-custom-code", block)

    def test_hard_coded_custom_code_and_cli_echo_are_absent(self):
        combined = text(WORKFLOW_PATH) + text(SCRIPT_PATH)
        self.assertNotIn("johnDOE123", combined)
        self.assertNotIn('echo "customCode: $output"', combined)

    def test_launch_delegates_the_complete_readiness_contract_once(self):
        launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
        self.assertEqual(launch.count("apple.sh launch-and-wait-device"), 1)
        for obsolete in (
            "device_id_ready",
            "for ((i=1; i<=120; i++))",
            "apple.sh report-device-id readiness",
            "gtimeout",
            "brew install coreutils",
        ):
            self.assertNotIn(obsolete, launch)

    def test_failed_delegation_runs_diagnostics_only_inside_the_debug_gate(self):
        launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
        self.assert_failed_diagnostic_contract(launch)

    def test_failed_diagnostic_contract_rejects_command_before_status_capture(self):
        invalid_launch = """
            if .github/workflows/apple.sh launch-and-wait-device
            then
                :
            else
                echo "failure"
                launch_status="$?"
                if [ "${UUREMOTE_DEBUG:-0}" != "0" ]; then
                    .github/workflows/apple.sh diagnose-device-id || true
                fi
                exit "$launch_status"
            fi
        """

        with self.assertRaises(AssertionError):
            self.assert_failed_diagnostic_contract(invalid_launch)

    def test_failed_diagnostic_contract_rejects_call_after_debug_gate(self):
        invalid_launch = """
            if .github/workflows/apple.sh launch-and-wait-device
            then
                :
            else
                launch_status="$?"
                if [ "${UUREMOTE_DEBUG:-0}" != "0" ]; then
                    echo "debug enabled"
                fi
                .github/workflows/apple.sh diagnose-device-id || true
                exit "$launch_status"
            fi
        """

        with self.assertRaises(AssertionError):
            self.assert_failed_diagnostic_contract(invalid_launch)


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class CustomCodeValidationTests(unittest.TestCase):
    def validate(self, value: str | None) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()

        if value is None:
            environment.pop("UUREMOTE_CUSTOM_CODE", None)
        else:
            environment["UUREMOTE_CUSTOM_CODE"] = value

        return subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), "validate-custom-code"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_ascii_alphanumeric_codes_from_8_through_16_characters(self):
        for value in ("Abcdef12", "A1b2C3d4E5f6G7h8", "12345678"):
            with self.subTest(value=value):
                result = self.validate(value)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_wrong_length_and_non_alphanumeric_codes(self):
        for value in (
            None,
            "",
            "Abc1234",
            "A" * 17,
            "Abcd-123",
            "Abcd 123",
            "密码Abcd1234",
        ):
            with self.subTest(value=value):
                result = self.validate(value)
                self.assertEqual(result.returncode, 2)

                if value:
                    self.assertNotIn(value, result.stdout + result.stderr)

@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSDiagnosticRedactionTests(unittest.TestCase):
    def test_diagnostic_artifact_redacts_device_and_custom_code_values(self):
        result = subprocess.run(
            ["/bin/bash", str(DIAGNOSTIC_HARNESS_PATH)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("diagnostic redaction self-test passed", result.stdout)


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSCliOutputRedactionEntrypointTests(unittest.TestCase):
    def test_actual_cli_output_redaction_entrypoint_contract(self):
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "tests/test_macos_cli_output_redaction.sh")],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(result.stdout, "macOS CLI output redaction contract passed\n")
        self.assertEqual(result.stderr, "")


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSAssistAllowClassifierTests(unittest.TestCase):
    def run_scenario(self, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), "classify", scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_every_response_shape_has_one_safe_category(self):
        cases = {
            "timeout": ("timeout", "timeout"),
            "unavailable": ("cli-nonzero", "unavailable"),
            "cli-nonzero": ("cli-nonzero", "17"),
            "empty": ("empty", "0"),
            "invalid-utf8": ("invalid-utf8", "0"),
            "invalid-json": ("invalid-json", "0"),
            "not-object": ("not-object", "0"),
            "success-missing": ("success-missing", "0"),
            "success-wrong-type": ("success-wrong-type", "0"),
            "success-false": ("success-false", "0"),
            "enabled-missing": ("enabled-missing", "0"),
            "enabled-wrong-type": ("enabled-wrong-type", "0"),
            "enabled-false": ("enabled-false", "0"),
            "enabled-true": ("enabled-true", "0"),
            "duplicate-key": ("invalid-json", "0"),
            "nan": ("invalid-json", "0"),
        }
        for scenario, (category, safe_exit) in cases.items():
            with self.subTest(scenario=scenario):
                result = self.run_scenario(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                fields = result.stdout.strip().split("\t")
                self.assertEqual(fields[0], category)
                self.assertTrue(fields[1].isdigit())
                self.assertEqual(fields[2], safe_exit)
                self.assertEqual(len(fields), 3)

    def test_classifier_never_emits_fixture_values(self):
        result = self.run_scenario("hostile-enabled-false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split("\t", 1)[0], "enabled-false")
        self.assertNotIn("CustomCodeFixture", result.stdout + result.stderr)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
        self.assertNotIn("FORGED_OUTPUT", result.stdout + result.stderr)


class MacOSAssistAllowSignalFinalizationSourceTests(unittest.TestCase):
    @staticmethod
    def assert_guarded_handler_precedes_only_after_mask_restore(runner: str) -> None:
        finalization_start = runner.index("finally:\n")
        finalization_end = runner.index("\nraise SystemExit(exit_code)", finalization_start)
        finalization = runner[finalization_start:finalization_end]
        cleanup_guard = finalization.index("cleanup_in_progress = True")
        mask_restore = finalization.index("if cleanup_signal_mask is not None:")
        handler_restore = finalization.index(
            "for handled_signal, previous_handler in previous_handlers.items():"
        )
        if not cleanup_guard < mask_restore < handler_restore:
            raise AssertionError("runner restores a prior handler before unmasking")

    def test_runner_keeps_guarded_handlers_until_after_signal_mask_restoration(self):
        runner = text(SCRIPT_PATH)
        self.assert_guarded_handler_precedes_only_after_mask_restore(runner)

        finalization_start = runner.index("finally:\n")
        finalization_end = runner.index("\nraise SystemExit(exit_code)", finalization_start)
        finalization = runner[finalization_start:finalization_end]
        mask_start = finalization.index("    if cleanup_signal_mask is not None:")
        handler_start = finalization.index(
            "    for handled_signal, previous_handler in previous_handlers.items():"
        )
        swapped_finalization = (
            finalization[:mask_start]
            + finalization[handler_start:]
            + finalization[mask_start:handler_start]
        )
        swapped_runner = (
            runner[:finalization_start]
            + swapped_finalization
            + runner[finalization_end:]
        )
        with self.assertRaises(AssertionError):
            self.assert_guarded_handler_precedes_only_after_mask_restore(swapped_runner)

    def test_recorded_group_fixtures_do_not_spawn_untracked_sleep_loops(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        fixture_region = harness[
            harness.index('"fixture-hang"')
            : harness.index('"fixture-term-observed"')
        ]
        leader_region = harness[
            harness.index('"fixture-leader-completes"')
            : harness.index("umask 077")
        ]
        self.assertNotIn("while :; do sleep 1; done", fixture_region)
        self.assertNotIn("while :; do sleep 1; done", leader_region)
        self.assertIn('wait "$child_pid"', fixture_region)
        self.assertIn("exec /bin/sleep 30", fixture_region + leader_region)

    def test_gui_wrapper_normalization_avoids_bash_32_command_substitution_case(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        gui_region = harness[
            harness.index("        gui-wrapper)")
            : harness.index("        signal-term|signal-int|signal-hup)")
        ]
        self.assertNotIn('gui_command="sudo|launchctl|$(', gui_region)
        self.assertNotIn('case "$argument"', gui_region)
        self.assertIn('while IFS= read -r argument; do', gui_region)

    def test_completed_failure_diagnostic_is_fixed_field_and_identifier_free(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        start = harness.index("emit_completed_failure_diagnostic()")
        diagnostic_region = harness[
            start : harness.index('case "$mode" in', start)
        ]
        for field in (
            "BOUNDARY_STAGE=",
            "EXCEPTION_KIND=",
            "INITIAL_PROBE_KIND=",
            "FINAL_PROBE_KIND=",
            "WAIT_RETURN_CODE=",
            "PROBE_COUNT=",
            "ELAPSED_BUCKET=",
        ):
            self.assertIn(field, diagnostic_region)
        lowered = diagnostic_region.lower()
        for forbidden in ("pid=", "pgid=", "traceback", "repr("):
            self.assertNotIn(forbidden, lowered)
        self.assertNotIn("str(diagnostic_exception)", diagnostic_region)

    def test_residue_failure_diagnostic_has_only_fixed_state_fields(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        start = harness.index("emit_recorded_residue_diagnostic()")
        diagnostic_region = harness[
            start : harness.index("run_recorded_bounded_fixture()", start)
        ]
        for field in (
            "RECORDED_PARENT_STATE=%s",
            "RECORDED_CHILD_STATE=%s",
            "GROUP_SIGNAL_STATE=%s",
            "GROUP_MEMBERSHIP=%s",
            "GROUP_ACTIVITY=%s",
        ):
            self.assertIn(field, diagnostic_region)
        for forbidden_field in ("PID=", "PGID=", "COMMAND=", "ERROR="):
            self.assertNotIn(forbidden_field, diagnostic_region)

    def test_completed_fixture_uses_the_macos_true_executable(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        completed_start = harness.index("        completed)")
        completed_end = harness.index("        nonzero)", completed_start)
        completed_region = harness[completed_start:completed_end]
        self.assertIn("completed_command=/usr/bin/true", completed_region)
        self.assertNotIn("completed_command=/bin/true", completed_region)

    def test_recorded_faults_wait_for_group_recording_before_injection(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        self.assertIn("UUREMOTE_TEST_GROUP_RECORDED_PATH", harness)
        self.assertIn("wait_for_test_group_recording()", harness)
        self.assertIn("fixture-leader-completes-recorded", harness)

    def test_recorded_leader_handshake_does_not_poll_with_untracked_children(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        start = harness.index(
            'if [ "${1:-}" = "fixture-leader-completes-recorded" ]'
        )
        fixture = harness[start : harness.index("\numask 077", start)]
        self.assertNotIn("do sleep", fixture)
        self.assertIn("trap 'exit 0' USR1", fixture)
        self.assertIn('wait "$child_pid"', fixture)

    def test_shell_signal_relay_waits_for_owned_blocker_metadata(self):
        harness = text(MACOS_ASSIST_ALLOW_HARNESS_PATH)
        blocker_pid_write = "pathlib.Path(sys.argv[1]).write_text"
        blocker_ready_write = "pathlib.Path(blocker_ready_path).write_text"
        self.assertLess(
            harness.index(blocker_pid_write),
            harness.index(blocker_ready_write),
        )
        relay_region_start = harness.index(
            'if [ "$mode" = "absolute-shell-signal-relay" ]'
        )
        relay_region_end = harness.index(
            'if [ "$mode" = "absolute-precommit-signal" ]',
            relay_region_start,
        )
        relay_region = harness[relay_region_start:relay_region_end]
        self.assertIn("observe_worker_descendants", relay_region)
        self.assertIn("blocker_ready.exists()", relay_region)
        self.assertIn("UUREMOTE_TEST_RELAY_READY_PATH", relay_region)
        self.assertLess(
            relay_region.index("observe_worker_descendants"),
            relay_region.index("UUREMOTE_TEST_RELAY_READY_PATH"),
        )
        self.assertIn(
            "ASSIST_ALLOW_DEADLINE_MILLISECONDS=6000",
            harness,
        )


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSAssistAllowProcessTests(unittest.TestCase):
    def run_harness(
        self,
        mode: str,
        scenario: str,
        subject_source=None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if subject_source is not None:
            environment["MACOS_ASSIST_ALLOW_SUBJECT_SOURCE"] = str(subject_source)
        return subprocess.run(
            ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), mode, scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def test_completed_process_records_exact_safe_status(self):
        result = self.run_harness("process-completed-diagnostic", "completed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "STATUS=completed:0\n")

    def test_completed_failure_reports_only_fixed_safe_probe_fields(self):
        started = time.monotonic()
        result = self.run_harness(
            "process-completed-diagnostic-failure",
            "completed",
        )
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertLess(elapsed, 5)
        diagnostic = result.stderr.splitlines()
        self.assertEqual(diagnostic[0], "BOUNDARY_STAGE=wait-returned")
        self.assertEqual(diagnostic[1], "EXCEPTION_KIND=none")
        self.assertEqual(diagnostic[2], "INITIAL_PROBE_KIND=alive")
        self.assertEqual(diagnostic[3], "FINAL_PROBE_KIND=alive")
        self.assertEqual(diagnostic[4], "WAIT_RETURN_CODE=0")
        self.assertRegex(diagnostic[5], r"^PROBE_COUNT=[1-9][0-9]*$")
        self.assertLessEqual(int(diagnostic[5].partition("=")[2]), 100)
        self.assertIn(
            diagnostic[6],
            (
                "ELAPSED_BUCKET=fast",
                "ELAPSED_BUCKET=bounded",
                "ELAPSED_BUCKET=extended",
            ),
        )
        self.assertEqual(len(diagnostic), 7)

    def test_completed_failure_diagnostic_identifies_the_failing_boundary(self):
        cases = (
            (
                "process-completed-diagnostic-popen-failure",
                "popen-entered",
                "os-error",
            ),
            (
                "process-completed-diagnostic-preexec-failure",
                "popen-entered",
                "subprocess-error",
            ),
            (
                "process-completed-diagnostic-ownership-failure",
                "group-recorded",
                "runtime-error",
            ),
            (
                "process-completed-diagnostic-parent-restore-failure",
                "restoring-parent-mask",
                "runtime-error",
            ),
        )
        for mode, stage, exception_kind in cases:
            with self.subTest(mode=mode):
                started = time.monotonic()
                result = self.run_harness(mode, "completed")
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertLess(elapsed, 5)
                diagnostic = result.stderr.splitlines()
                self.assertEqual(diagnostic[0], f"BOUNDARY_STAGE={stage}")
                self.assertEqual(
                    diagnostic[1],
                    f"EXCEPTION_KIND={exception_kind}",
                )
                self.assertRegex(
                    diagnostic[2],
                    r"^INITIAL_PROBE_KIND=(absent|alive|unknown|error|unavailable)$",
                )
                self.assertRegex(
                    diagnostic[3],
                    r"^FINAL_PROBE_KIND=(absent|alive|unknown|error|unavailable)$",
                )
                self.assertEqual(diagnostic[4], "WAIT_RETURN_CODE=unavailable")
                self.assertRegex(diagnostic[5], r"^PROBE_COUNT=[0-9]+$")
                self.assertLessEqual(int(diagnostic[5].partition("=")[2]), 100)
                self.assertRegex(
                    diagnostic[6],
                    r"^ELAPSED_BUCKET=(fast|bounded|extended)$",
                )
                self.assertEqual(len(diagnostic), 7)

    @unittest.skipUnless(
        NATIVE_MACOS_BASH_AVAILABLE,
        "requires native macOS process-group residue observation",
    )
    def test_residue_failure_reports_only_fixed_group_state_fields(self):
        result = self.run_harness("fault-residue-diagnostic", "timeout")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "RECORDED_PARENT_STATE=live",
                "RECORDED_CHILD_STATE=live",
                "GROUP_SIGNAL_STATE=present",
                "GROUP_MEMBERSHIP=recorded-only",
                "GROUP_ACTIVITY=live-only",
                "Unconfirmed cleanup left a recorded process",
            ],
        )

    @unittest.skipUnless(
        NATIVE_MACOS_BASH_AVAILABLE,
        "requires native macOS process-group residue observation",
    )
    def test_residue_observer_failure_reports_unknown_without_raw_stderr(self):
        result = self.run_harness(
            "fault-residue-observer-diagnostic",
            "timeout",
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "RECORDED_PARENT_STATE=unknown",
                "RECORDED_CHILD_STATE=unknown",
                "GROUP_SIGNAL_STATE=unknown",
                "GROUP_MEMBERSHIP=unknown",
                "GROUP_ACTIVITY=unknown",
                "Unconfirmed cleanup left a recorded process",
            ],
        )

    def test_missing_residue_metadata_still_emits_fixed_unknown_fields(self):
        cases = (
            (
                "fault-residue-metadata-diagnostic",
                "unknown",
                "unknown",
                "unknown",
                "unknown",
            ),
            (
                "fault-residue-partial-diagnostic",
                "absent",
                "unknown",
                "absent",
                "absent",
            ),
            (
                "fault-residue-invalid-group-diagnostic",
                "absent",
                "absent",
                "unknown",
                "unknown",
            ),
            (
                "fault-residue-invalid-pid-diagnostic",
                "unknown",
                "absent",
                "absent",
                "absent",
            ),
            (
                "fault-residue-read-diagnostic",
                "unknown",
                "unknown",
                "absent",
                "absent",
            ),
        )
        for (
            mode,
            parent_state,
            child_state,
            group_signal_state,
            group_activity,
        ) in cases:
            with self.subTest(mode=mode):
                result = self.run_harness(mode, "residue-metadata-failure")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "ASSERTION=failed\n")
                self.assertEqual(
                    result.stderr.splitlines(),
                    [
                        f"RECORDED_PARENT_STATE={parent_state}",
                        f"RECORDED_CHILD_STATE={child_state}",
                        f"GROUP_SIGNAL_STATE={group_signal_state}",
                        "GROUP_MEMBERSHIP=unknown",
                        f"GROUP_ACTIVITY={group_activity}",
                    ],
                )

    def test_nonzero_process_records_exact_safe_status(self):
        result = self.run_harness("process", "nonzero")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "STATUS=completed:17\n")

    def test_hanging_process_group_is_terminated_and_reaped(self):
        started = time.monotonic()
        result = self.run_harness("process", "timeout")
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 5)
        self.assertEqual(result.stdout, "STATUS=timeout\nPROCESS_GROUP_RELEASED=true\n")

    def test_transient_process_group_probe_error_is_retried_before_confirmation(self):
        result = self.run_harness(
            "probe-transient-error", "transient-probe-error"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "STATUS=timeout\n")

    def test_persistent_process_group_probe_error_stops_at_cleanup_deadline(self):
        started = time.monotonic()
        result = self.run_harness(
            "probe-persistent-error", "persistent-probe-error"
        )
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 2)
        self.assertEqual(
            result.stdout,
            "EXIT=125\nSTATUS=absent\nPROBES_RETRIED=true\nLATE_PROBE=false\n",
        )

    def test_persistent_probe_started_before_deadline_is_not_reported_late(self):
        started = time.monotonic()
        result = self.run_harness(
            "probe-persistent-oracle-delay",
            "persistent-probe-error",
        )
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 2)
        self.assertEqual(
            result.stdout,
            "EXIT=125\nSTATUS=absent\nPROBES_RETRIED=true\nLATE_PROBE=false\n",
        )

    def test_persistent_probe_oracle_rejects_a_post_deadline_probe(self):
        source = text(SCRIPT_PATH)
        target = "    return cleanup_confirmed\n\ncleanup_in_progress = False"
        replacement = (
            "    try:\n"
            "        cleanup_confirmed = not process_group_alive()\n"
            "    except OSError:\n"
            "        pass\n"
            "    return cleanup_confirmed\n\n"
            "cleanup_in_progress = False"
        )
        mutated = source.replace(target, replacement, 1)
        self.assertNotEqual(mutated, source)
        with tempfile.TemporaryDirectory() as temporary_directory:
            subject = Path(temporary_directory) / "apple.sh"
            subject.write_text(mutated, encoding="utf-8")
            result = self.run_harness(
                "probe-persistent-error",
                "persistent-probe-error",
                subject,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Process group was probed after the cleanup deadline",
            result.stderr,
        )

    def test_term_exiting_group_leader_does_not_leave_a_descendant(self):
        started = time.monotonic()
        result = self.run_harness("process", "leader-exits")
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 5)
        self.assertEqual(result.stdout, "STATUS=timeout\nPROCESS_GROUP_RELEASED=true\n")

    def test_gui_wrapper_builds_the_expected_console_session_command(self):
        result = self.run_harness("process", "gui-wrapper")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "STATUS=completed:0\n"
            "GUI_COMMAND=sudo|launchctl|asuser|501|sudo|-u|#501|/usr/bin/true\n",
        )

    def test_term_interrupt_reaps_the_owned_process_group_fail_closed(self):
        started = time.monotonic()
        result = self.run_harness("process", "signal-term")
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(elapsed, 5)
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            result.stdout,
            "STATUS=unavailable\nPROCESS_GROUP_RELEASED=true\n",
        )

    def test_spawned_child_receives_term_after_signal_masked_launch(self):
        result = self.run_harness("process", "term-observed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "STATUS=timeout\nTERM_OBSERVED=true\nPROCESS_GROUP_RELEASED=true\n",
        )

    def test_completed_leader_with_live_descendant_fails_closed(self):
        result = self.run_harness("process", "leader-completes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "STATUS=unavailable\nPROCESS_GROUP_RELEASED=true\n",
        )

    @unittest.skipUnless(
        NATIVE_MACOS_BASH_AVAILABLE,
        "requires native macOS pending-signal finalization",
    )
    def test_pending_second_handled_signal_is_guarded_through_finalization(self):
        for scenario in (
            "pending-signal-int",
            "pending-signal-term",
            "pending-signal-hup",
        ):
            with self.subTest(scenario=scenario):
                started = time.monotonic()
                result = self.run_harness("process", scenario)
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(elapsed, 5)
                self.assertEqual(result.stderr, "")
                self.assertEqual(
                    result.stdout,
                    "EXIT=125\nSTATUS=unavailable\nPROCESS_GROUP_RELEASED=true\n",
                )
                self.assertNotIn("Traceback", result.stdout + result.stderr)
                self.assertNotIn("pending-cleanup-started", result.stdout + result.stderr)

    @unittest.skipUnless(
        NATIVE_MACOS_BASH_AVAILABLE,
        "requires native macOS pending-signal finalization",
    )
    def test_pending_signal_finalization_rejects_swapped_handler_restore_order(self):
        result = self.run_harness("pending-finalization-swapped", "pending-signal-term")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_timeout_cleanup_false_and_raises_fail_closed(self):
        for mode in ("fault-timeout", "fault-raises"):
            with self.subTest(mode=mode):
                started = time.monotonic()
                result = self.run_harness(mode, "timeout")
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(elapsed, 5)
                self.assertEqual(result.stderr, "")
                expected = "EXIT=125\nSTATUS=absent\n"
                if NATIVE_MACOS_BASH_AVAILABLE:
                    expected += "PROCESS_GROUP_RELEASED=true\n"
                self.assertEqual(result.stdout, expected)

    def test_signal_block_setup_faults_reap_owned_processes_without_status(self):
        cases = (
            ("block-false", "timeout"),
            ("block-raises", "timeout"),
            ("block-false", "leader-fault"),
            ("block-raises", "leader-fault"),
            ("block-false", "signal-int"),
            ("block-false", "signal-term"),
            ("block-false", "signal-hup"),
            ("block-raises", "signal-int"),
            ("block-raises", "signal-term"),
            ("block-raises", "signal-hup"),
            ("block-false-post-fault", "post-ownership-fault"),
            ("block-raises-post-fault", "post-ownership-fault"),
        )
        for mode, scenario in cases:
            with self.subTest(mode=mode, scenario=scenario):
                started = time.monotonic()
                result = self.run_harness(mode, scenario)
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(elapsed, 5)
                self.assertEqual(result.stderr, "")
                expected = "EXIT=125\nSTATUS=absent\n"
                if NATIVE_MACOS_BASH_AVAILABLE:
                    expected += "PROCESS_GROUP_RELEASED=true\n"
                self.assertEqual(result.stdout, expected)

    def test_runner_marks_ownership_before_parent_unmask_and_wait(self):
        runner = text(SCRIPT_PATH)
        ownership = runner.index("process_group_id = process.pid\n        owned_cleanup_required = True")
        parent_unmask = runner.index(
            "if previous_signal_mask is not None:\n        signal.pthread_sigmask",
            ownership,
        )
        first_wait = runner.index("return_code = process.wait(timeout=timeout_seconds)", ownership)
        self.assertLess(ownership, parent_unmask)
        self.assertLess(parent_unmask, first_wait)

    def test_runner_post_ownership_exception_cleans_without_status(self):
        def assert_generic_handler_contract(runner: str) -> None:
            wrapper_start = runner.index(
                "run_bounded_uuremote_cli_to_file_with_status() {"
            )
            heredoc_start = runner.index("<<'PYTHON'\n", wrapper_start)
            python_start = heredoc_start + len("<<'PYTHON'\n")
            python_end = runner.index("\nPYTHON\n}", python_start)
            tree = ast.parse(runner[python_start:python_end])
            runner_try = next(node for node in tree.body if isinstance(node, ast.Try))
            generic_handler = next(
                handler
                for handler in runner_try.handlers
                if isinstance(handler.type, ast.Name)
                and handler.type.id == "Exception"
            )
            exception_body = ast.dump(
                ast.Module(body=generic_handler.body, type_ignores=[]),
                include_attributes=False,
            )
            self.assertIn("cleanup_owned_process_after_signal_block", exception_body)
            self.assertNotIn("write_status", exception_body)

        runner = text(SCRIPT_PATH)
        assert_generic_handler_contract(runner)
        mutation_target = (
            "except Exception:\n"
            "    cleanup_in_progress = True\n"
            "    cleanup_owned_process_after_signal_block()"
        )
        mutated = runner.replace(
            mutation_target,
            "except Exception:\n"
            "    write_status(\"unavailable\")\n"
            "    cleanup_in_progress = True\n"
            "    cleanup_owned_process_after_signal_block()",
            1,
        )
        self.assertNotEqual(mutated, runner)
        with self.assertRaises(AssertionError):
            assert_generic_handler_contract(mutated)

    def test_post_popen_exceptions_fail_closed_without_a_status(self):
        for mode in ("fault-post-unmask", "fault-first-wait"):
            with self.subTest(mode=mode):
                started = time.monotonic()
                result = self.run_harness(mode, "post-ownership-fault")
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(elapsed, 5)
                self.assertEqual(result.stderr, "")
                expected = "EXIT=125\nSTATUS=absent\n"
                if NATIVE_MACOS_BASH_AVAILABLE:
                    expected += "PROCESS_GROUP_RELEASED=true\n"
                self.assertEqual(result.stdout, expected)

    @unittest.skipUnless(
        NATIVE_MACOS_BASH_AVAILABLE,
        "requires native macOS process-group cleanup and reaping",
    )
    def test_cleanup_faults_reap_real_groups_before_return(self):
        cases = (
            ("fault-timeout", "timeout"),
            ("fault-raises", "timeout"),
            ("fault-leader", "leader-fault"),
            ("fault-leader-raises", "leader-fault"),
            ("fault-signal", "signal-int"),
            ("fault-signal", "signal-term"),
            ("fault-signal", "signal-hup"),
            ("fault-signal-raises", "signal-int"),
            ("fault-signal-raises", "signal-term"),
            ("fault-signal-raises", "signal-hup"),
        )
        for mode, scenario in cases:
            with self.subTest(mode=mode, scenario=scenario):
                started = time.monotonic()
                result = self.run_harness(mode, scenario)
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLess(elapsed, 5)
                self.assertEqual(result.stderr, "")
                self.assertEqual(
                    result.stdout,
                    "EXIT=125\nSTATUS=absent\nPROCESS_GROUP_RELEASED=true\n",
                )

    def test_exit_cleanup_kills_a_recorded_fixture_child(self):
        result = self.run_harness("process", "cleanup-fallback")
        self.assertEqual(result.returncode, 0, result.stderr)
        _, value = result.stdout.strip().split("=", 1)
        with self.assertRaises(ProcessLookupError):
            os.kill(int(value), 0)


@unittest.skipUnless(NATIVE_MACOS_BASH_AVAILABLE, "requires native macOS Bash")
class MacOSAssistAbsoluteDeadlineBoundaryTests(unittest.TestCase):
    def harness_command(self, mode: str, scenario: str) -> list[str]:
        return ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), mode, scenario]

    @staticmethod
    def process_exists(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    @staticmethod
    def process_group_exists(process_group: int) -> bool:
        try:
            os.killpg(process_group, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def cleanup_supervised_process(
        self,
        process: subprocess.Popen[str],
        recorded_pids: list[int],
        recorded_groups: set[int],
    ) -> bool:
        cleanup_confirmed = True
        for pid in recorded_pids:
            try:
                recorded_groups.add(os.getpgid(pid))
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_confirmed = False
        recorded_groups.add(process.pid)
        for process_group in recorded_groups:
            if process_group == os.getpgrp():
                continue
            try:
                os.killpg(process_group, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_confirmed = False
        for pid in recorded_pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_confirmed = False

        try:
            process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
        for process_group in recorded_groups:
            if process_group == os.getpgrp():
                continue
            try:
                os.killpg(process_group, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_confirmed = False
        for pid in recorded_pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_confirmed = False
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except OSError:
                cleanup_confirmed = False
            try:
                process.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                cleanup_confirmed = False

        return cleanup_confirmed and self.wait_for_recorded_release(
            recorded_pids, recorded_groups
        )

    def snapshot_supervised_tree(
        self, root_pid: int
    ) -> tuple[list[int], set[int], bool]:
        try:
            result = subprocess.run(
                ["/bin/ps", "-axo", "pid=,ppid=,pgid="],
                text=True,
                capture_output=True,
                check=False,
                timeout=0.5,
            )
        except (OSError, subprocess.SubprocessError):
            return [root_pid], {root_pid}, False
        if result.returncode != 0:
            return [root_pid], {root_pid}, False
        records: dict[int, tuple[int, int]] = {}
        try:
            for line in result.stdout.splitlines():
                pid, parent_pid, process_group = (
                    int(value) for value in line.split()
                )
                records[pid] = (parent_pid, process_group)
        except ValueError:
            return [root_pid], {root_pid}, False
        descendants = {root_pid}
        changed = True
        while changed:
            changed = False
            for pid, (parent_pid, _process_group) in records.items():
                if parent_pid in descendants and pid not in descendants:
                    descendants.add(pid)
                    changed = True
        groups = {
            records[pid][1]
            for pid in descendants
            if pid in records and records[pid][1] != os.getpgrp()
        }
        groups.add(root_pid)
        return sorted(descendants), groups, True

    def wait_for_recorded_release(
        self,
        recorded_pids: list[int],
        recorded_groups: set[int],
        timeout_seconds: float = 2,
    ) -> bool:
        cleanup_deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < cleanup_deadline:
            pids_released = all(
                not self.process_exists(pid) for pid in recorded_pids
            )
            groups_released = all(
                not self.process_group_exists(process_group)
                for process_group in recorded_groups
            )
            if pids_released and groups_released:
                return True
            time.sleep(0.01)
        return False

    def run_with_external_supervisor(
        self,
        mode: str,
        scenario: str,
        expected_stage: str,
        signal_supervisor: bool = False,
    ) -> tuple[str, str, str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_root = Path(temporary_directory)
            stage_path = temporary_root / "stage"
            pid_path = temporary_root / "pids"
            supervisor_pid_path = temporary_root / "supervisor-pid"
            blocker_ready_path = temporary_root / "blocker-ready"
            relay_ready_path = temporary_root / "relay-ready"
            environment = os.environ.copy()
            environment.update(
                {
                    "UUREMOTE_TEST_PYTHON_STAGE_PATH": str(stage_path),
                    "UUREMOTE_TEST_PYTHON_PID_PATH": str(pid_path),
                    "UUREMOTE_TEST_SHELL_STAGE_PATH": str(stage_path),
                    "UUREMOTE_TEST_SUPERVISOR_PID_PATH": str(
                        supervisor_pid_path
                    ),
                    "UUREMOTE_TEST_BLOCKER_READY_PATH": str(
                        blocker_ready_path
                    ),
                    "UUREMOTE_TEST_RELAY_READY_PATH": str(relay_ready_path),
                }
            )
            popen_options = {
                "cwd": ROOT,
                "text": True,
                "stdout": subprocess.PIPE,
                "stderr": subprocess.PIPE,
                "env": environment,
            }
            popen_options["start_new_session"] = True
            process = subprocess.Popen(
                self.harness_command(mode, scenario),
                **popen_options,
            )
            try:
                runner_group = os.getpgid(process.pid)
            except OSError:
                runner_group = 0
            supervisor_state = "unavailable"
            stdout = ""
            stderr = ""
            cleanup_released = False
            metadata_confirmed = False
            relay_metadata_confirmed = not signal_supervisor
            pre_signal_pids: list[int] = []
            pre_signal_groups: set[int] = set()
            try:
                if signal_supervisor:
                    relay_deadline = time.monotonic() + 2
                    while (
                        not (
                            supervisor_pid_path.exists()
                            and relay_ready_path.exists()
                        )
                        and time.monotonic() < relay_deadline
                    ):
                        time.sleep(0.01)
                    try:
                        supervisor_values = tuple(
                            int(value)
                            for value in supervisor_pid_path.read_text(
                                encoding="ascii"
                            ).split()
                        )
                        if (
                            len(supervisor_values) != 2
                            or min(supervisor_values) <= 0
                        ):
                            raise ValueError
                        supervisor_process, supervisor_group = supervisor_values
                        pre_signal_pids, pre_signal_groups, snapshot_confirmed = (
                            self.snapshot_supervised_tree(process.pid)
                        )
                        pre_signal_pids.append(supervisor_process)
                        pre_signal_groups.add(supervisor_group)
                        relay_metadata_confirmed = snapshot_confirmed
                        os.kill(supervisor_process, signal.SIGTERM)
                    except (OSError, ValueError):
                        relay_metadata_confirmed = False
                try:
                    stdout, stderr = process.communicate(timeout=3)
                    supervisor_state = "completed"
                except subprocess.TimeoutExpired:
                    supervisor_state = "timeout"
            finally:
                records = [(process.pid, runner_group)]
                fixture_metadata_confirmed = False
                if pid_path.exists():
                    try:
                        fixture_records = []
                        for line in pid_path.read_text(
                            encoding="ascii"
                        ).splitlines():
                            values = tuple(
                                int(value) for value in line.split()
                            )
                            if len(values) != 2:
                                raise ValueError
                            pid, process_group = values
                            if pid <= 0 or process_group <= 0:
                                raise ValueError
                            fixture_records.append(values)
                        if not fixture_records:
                            raise ValueError
                        records.extend(fixture_records)
                        fixture_metadata_confirmed = True
                    except (OSError, ValueError):
                        fixture_metadata_confirmed = False
                recorded_pids = [pid for pid, _group in records]
                recorded_pids.extend(pre_signal_pids)
                recorded_groups = {
                    group for _pid, group in records if group > 0
                }
                recorded_groups.update(pre_signal_groups)
                snapshot_confirmed = True
                if process.poll() is None:
                    tree_pids, tree_groups, snapshot_confirmed = (
                        self.snapshot_supervised_tree(process.pid)
                    )
                    recorded_pids.extend(tree_pids)
                    recorded_groups.update(tree_groups)
                metadata_confirmed = (
                    runner_group > 0
                    and fixture_metadata_confirmed
                    and snapshot_confirmed
                    and relay_metadata_confirmed
                )
                production_cleanup_released = self.wait_for_recorded_release(
                    sorted(set(recorded_pids)),
                    recorded_groups,
                    timeout_seconds=1.25 if signal_supervisor else 2,
                )
                fallback_cleanup_released = self.cleanup_supervised_process(
                    process, sorted(set(recorded_pids)), recorded_groups
                )
                cleanup_released = (
                    production_cleanup_released
                    and fallback_cleanup_released
                    and metadata_confirmed
                )
            self.assertTrue(
                metadata_confirmed,
                "validated runner and fixture PID/PGID metadata is required",
            )
            if supervisor_state == "completed":
                self.assertEqual(process.returncode, 1, stdout + stderr)
            else:
                self.assertTrue(recorded_pids)
            stage = (
                stage_path.read_text(encoding="ascii").strip()
                if stage_path.exists()
                else "unavailable"
            )
            diagnostic = (
                f"BOUNDARY_STAGE={stage}\n"
                f"SUPERVISOR_STATE={supervisor_state}\n"
                f"PROCESS_CLEANUP={'released' if cleanup_released else 'unconfirmed'}\n"
            )
            return diagnostic, stdout, stderr

    def assert_boundary_obeys_absolute_deadline(
        self, mode: str, scenario: str, expected_stage: str
    ) -> None:
        diagnostic, stdout, stderr = self.run_with_external_supervisor(
            mode, scenario, expected_stage
        )
        self.assertEqual(
            diagnostic,
            f"BOUNDARY_STAGE={expected_stage}\n"
            "SUPERVISOR_STATE=completed\n"
            "PROCESS_CLEANUP=released\n",
            stdout + stderr,
        )
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "Could not enable unattended control within 60 seconds\n",
        )

    def test_startup_preexec_block_is_bounded_by_attempt_deadline(self):
        self.assert_boundary_obeys_absolute_deadline(
            "startup-preexec-block", "startup-boundary", "startup-preexec-block"
        )

    def test_initial_clock_block_is_bounded_by_absolute_deadline(self):
        self.assert_boundary_obeys_absolute_deadline(
            "absolute-clock-block", "clock-block", "clock-block"
        )

    def test_poll_block_is_bounded_by_absolute_deadline(self):
        self.assert_boundary_obeys_absolute_deadline(
            "absolute-poll-block", "poll-block", "poll-block"
        )

    def test_worker_uses_reserved_shared_deadline_to_emit_safe_summary(self):
        diagnostic, stdout, stderr = self.run_with_external_supervisor(
            "absolute-worker-summary", "worker-summary", "unavailable"
        )
        self.assertEqual(
            diagnostic,
            "BOUNDARY_STAGE=unavailable\n"
            "SUPERVISOR_STATE=completed\n"
            "PROCESS_CLEANUP=released\n",
            stdout + stderr,
        )
        self.assertEqual(stdout, "")
        lines = stderr.splitlines()
        self.assertEqual(
            lines[-1], "Could not enable unattended control within 60 seconds"
        )
        self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CATEGORY=enabled-false", lines)
        self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=0", lines)
        self.assertTrue(
            all(
                line.startswith("ASSIST_DIAGNOSTIC_")
                or line == "Could not enable unattended control within 60 seconds"
                for line in lines
            )
        )

    def test_timely_worker_exit_cleans_recorded_new_session_descendant(self):
        self.assert_boundary_obeys_absolute_deadline(
            "absolute-root-reap",
            "root-reap",
            "root-exit-descendant",
        )

    def test_pending_signal_before_replay_commit_fails_closed(self):
        self.assert_boundary_obeys_absolute_deadline(
            "absolute-precommit-signal",
            "precommit-signal",
            "unavailable",
        )

    def test_shell_signal_relay_owns_the_python_supervisor(self):
        diagnostic, stdout, stderr = self.run_with_external_supervisor(
            "absolute-shell-signal-relay",
            "shell-signal-relay",
            "poll-block",
            signal_supervisor=True,
        )
        self.assertEqual(
            diagnostic,
            "BOUNDARY_STAGE=poll-block\n"
            "SUPERVISOR_STATE=completed\n"
            "PROCESS_CLEANUP=released\n",
            stdout + stderr,
        )
        self.assertEqual(stdout, "")
        self.assertEqual(
            stderr,
            "Could not enable unattended control within 60 seconds\n",
        )


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSAssistAllowAggregationTests(unittest.TestCase):
    def run_harness(
        self, scenario: str, extra_environment: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        if extra_environment:
            environment.update(extra_environment)
        return subprocess.run(
            ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), "aggregate", scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def assert_timeout_checkpoint_contract(
        self, result: subprocess.CompletedProcess[str]
    ) -> None:
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "TEMPORARY_TREE_EMPTY=true\n")
        self.assertIn("ASSIST_DIAGNOSTIC_ATTEMPTS=1", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_TIMEOUT_COUNT=1", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=0", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CATEGORY=timeout", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=timeout", result.stderr)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
        self.assertNotIn("CustomCodeFixture", result.stdout + result.stderr)

    def test_real_enable_assist_helper_reports_success_exactly(self):
        result = self.run_harness("outer-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Unattended control is enabled\n")
        self.assertEqual(result.stderr, "")

    def test_outer_caller_hides_mutated_real_cleanup_failures(self):
        for mode in (
            "outer-cleanup-false",
            "outer-cleanup-raises",
            "outer-post-unmask",
            "outer-first-wait",
            "outer-block-false",
            "outer-block-raises",
        ):
            with self.subTest(mode=mode):
                started = time.monotonic()
                result = subprocess.run(
                    ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), mode, mode],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                elapsed = time.monotonic() - started
                self.assertEqual(result.returncode, 1)
                self.assertLess(elapsed, 5)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    "Could not enable unattended control within 60 seconds\n",
                )
                for marker in (
                    "ASSIST_DIAGNOSTIC_",
                    "STATUS=",
                    "Traceback",
                    "device-id-fixture",
                    "CustomCodeFixture",
                    "FORGED_OUTPUT",
                ):
                    self.assertNotIn(marker, result.stdout + result.stderr)

    def test_transient_failures_then_success_emit_only_success(self):
        result = self.run_harness("transient-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "ASSIST_STATE=enabled\n")

    def test_debug_zero_failure_is_generic_only(self):
        result = self.run_harness("debug0-failure")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr,
            "Could not enable unattended control within 60 seconds\n",
        )

    def test_debug_levels_emit_complete_fixed_summary(self):
        field_names = [
            "ASSIST_DIAGNOSTIC_ATTEMPTS",
            "ASSIST_DIAGNOSTIC_TIMEOUT_COUNT",
            "ASSIST_DIAGNOSTIC_CLI_NONZERO_COUNT",
            "ASSIST_DIAGNOSTIC_EMPTY_COUNT",
            "ASSIST_DIAGNOSTIC_INVALID_UTF8_COUNT",
            "ASSIST_DIAGNOSTIC_INVALID_JSON_COUNT",
            "ASSIST_DIAGNOSTIC_NOT_OBJECT_COUNT",
            "ASSIST_DIAGNOSTIC_SUCCESS_MISSING_COUNT",
            "ASSIST_DIAGNOSTIC_SUCCESS_WRONG_TYPE_COUNT",
            "ASSIST_DIAGNOSTIC_SUCCESS_FALSE_COUNT",
            "ASSIST_DIAGNOSTIC_ENABLED_MISSING_COUNT",
            "ASSIST_DIAGNOSTIC_ENABLED_WRONG_TYPE_COUNT",
            "ASSIST_DIAGNOSTIC_ENABLED_FALSE_COUNT",
            "ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT",
            "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MIN",
            "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MAX",
            "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_FINAL",
            "ASSIST_DIAGNOSTIC_FINAL_CATEGORY",
            "ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT",
        ]
        for level in (1, 2, 3):
            with self.subTest(level=level):
                result = self.run_harness(f"debug{level}-failure")
                self.assertEqual(result.returncode, 1)
                lines = result.stderr.splitlines()
                self.assertEqual(
                    [line.split("=", 1)[0] for line in lines[:-1]], field_names
                )
                self.assertEqual(
                    lines[-1], "Could not enable unattended control within 60 seconds"
                )
                counts = {
                    line.split("=", 1)[0]: line.split("=", 1)[1]
                    for line in lines[:-1]
                }
                category_total = sum(
                    int(value)
                    for key, value in counts.items()
                    if key.endswith("_COUNT")
                )
                self.assertEqual(category_total, int(counts["ASSIST_DIAGNOSTIC_ATTEMPTS"]))

    def test_late_success_fails_and_temporary_tree_is_empty(self):
        result = self.run_harness("late-success")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ASSIST_DIAGNOSTIC_ATTEMPTS=1", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_TIMEOUT_COUNT=1", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=0", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CATEGORY=timeout", result.stderr)
        self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=timeout", result.stderr)
        counts = [
            int(line.split("=", 1)[1])
            for line in result.stderr.splitlines()
            if line.startswith("ASSIST_DIAGNOSTIC_") and "_COUNT=" in line
        ]
        self.assertEqual(sum(counts), 1)
        self.assertIn("TEMPORARY_TREE_EMPTY=true", result.stdout)

    def test_deadline_checkpoints_sanitize_expired_attempts_as_timeout(self):
        for scenario in (
            "deadline-after-child",
            "deadline-after-record",
            "deadline-before-enabled",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_harness(scenario)
                self.assert_timeout_checkpoint_contract(result)

    def test_expired_child_without_a_safe_status_is_generic_only(self):
        result = self.run_harness("expired-no-status")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr,
            "Could not enable unattended control within 60 seconds\n",
        )
        for marker in (
            "ASSIST_DIAGNOSTIC_",
            "device-id-fixture",
            "CustomCodeFixture",
        ):
            self.assertNotIn(marker, result.stdout + result.stderr)

    def test_deadline_checkpoint_mutations_break_the_timeout_contract(self):
        source = text(SCRIPT_PATH)
        mutations = (
            (
                "deadline-after-child",
                'if [ "$remaining" -le 0 ]; then\n'
                "            execution_state=timeout\n"
                "            execution_exit=timeout",
                "if false; then\n"
                "            execution_state=timeout\n"
                "            execution_exit=timeout",
            ),
            (
                "deadline-after-record",
                'read_assist_now || return 1\n'
                '        remaining="$((deadline - now))"\n'
                '        if [ "$remaining" -le 0 ]; then\n'
                "            category=timeout\n"
                "            safe_exit=timeout\n"
                "        fi",
                'read_assist_now || return 1\n'
                '        remaining="$((deadline - now))"\n'
                "        if false; then\n"
                "            category=timeout\n"
                "            safe_exit=timeout\n"
                "        fi",
            ),
            (
                "deadline-before-enabled",
                'if [ "$remaining" -gt 0 ]; then\n'
                "                trap - EXIT HUP INT TERM\n"
                "                printf 'ASSIST_STATE=enabled\\n'",
                "if true; then\n"
                "                trap - EXIT HUP INT TERM\n"
                "                printf 'ASSIST_STATE=enabled\\n'",
            ),
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            for scenario, old, new in mutations:
                with self.subTest(scenario=scenario):
                    mutated = source.replace(old, new, 1)
                    self.assertNotEqual(mutated, source)
                    subject = Path(temporary_directory) / f"{scenario}.sh"
                    subject.write_text(mutated, encoding="utf-8")
                    result = self.run_harness(
                        scenario,
                        {"MACOS_ASSIST_ALLOW_SUBJECT_SOURCE": str(subject)},
                    )
                    with self.assertRaises(AssertionError):
                        self.assert_timeout_checkpoint_contract(result)

    def test_poll_failure_stops_after_one_attempt_without_leaking_stderr(self):
        result = self.run_harness("poll-failure")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stdout,
            "TEMPORARY_TREE_EMPTY=true\nBOUNDARY_CALLS=1\n",
        )
        self.assertEqual(
            result.stderr,
            "Could not enable unattended control within 60 seconds\n",
        )
        self.assertNotIn("FORGED_POLL_STDERR", result.stdout + result.stderr)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_per_call_timeout_and_poll_are_bounded_by_remaining_deadline(self):
        result = self.run_harness("deadline-bounds")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ASSIST_DIAGNOSTIC_ATTEMPTS=2", result.stderr)

    def test_invalid_diagnostic_record_fails_closed(self):
        result = self.run_harness("internal-invalid-record")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr,
            "Could not enable unattended control within 60 seconds\n",
        )

    def test_reporter_emits_only_validated_fixed_fields(self):
        result = self.run_harness("report-valid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 19)
        self.assertEqual(result.stderr, "")

    def test_reporter_rejects_invalid_counts_arity_and_exit_values(self):
        for scenario in (
            "report-invalid-count",
            "report-invalid-arity",
            "report-invalid-exit",
            "report-count-exceeds-attempts",
            "report-count-sum-mismatch",
            "report-byte-order",
            "report-zero-attempts",
            "report-final-category-without-evidence",
            "report-exit-relation",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_harness(scenario)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")

    def test_malformed_classifier_records_fail_closed_before_accounting(self):
        for scenario in (
            "record-trailing-newline",
            "record-trailing-tab",
            "record-extra-field",
            "record-embedded-cr",
            "record-enabled-unavailable",
            "record-timeout-zero",
            "record-cli-nonzero-zero",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_harness(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    "Could not enable unattended control within 60 seconds\n",
                )

    def test_nonzero_monotonic_clock_fails_closed_and_cleans_up(self):
        for scenario in (
            "clock-status-start",
            "clock-status-loop",
            "clock-status-post-call",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_harness(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "TEMPORARY_TREE_EMPTY=true\n")
                self.assertEqual(
                    result.stderr,
                    "Could not enable unattended control within 60 seconds\n",
                )

    def test_internal_boundary_failures_are_generic_only_and_cleaned_up(self):
        for scenario in (
            "fault-mktemp",
            "fault-chmod",
            "fault-truncate",
            "fault-status-write",
            "fault-cleanup",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_harness(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "TEMPORARY_TREE_EMPTY=true\n")
                self.assertEqual(
                    result.stderr,
                    "Could not enable unattended control within 60 seconds\n",
                )
                self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
                self.assertNotIn("CustomCodeFixture", result.stdout + result.stderr)

    def test_invalid_monotonic_clock_fails_closed_and_cleans_up(self):
        for scenario in (
            "invalid-clock",
            "invalid-clock-loop",
            "invalid-clock-post-call",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_harness(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertIn("TEMPORARY_TREE_EMPTY=true", result.stdout)
                self.assertEqual(
                    result.stderr,
                    "Could not enable unattended control within 60 seconds\n",
                )

    def test_hostile_responses_never_reach_logs_or_artifacts(self):
        result = self.run_harness("hostile-failure")
        self.assertEqual(result.returncode, 1)
        combined = result.stdout + result.stderr
        for marker in ("CustomCodeFixture", "device-id-fixture", "FORGED_OUTPUT"):
            self.assertNotIn(marker, combined)


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSReadinessBehaviorTests(unittest.TestCase):
    def run_scenario(self, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_READINESS_HARNESS_PATH), scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_absent_application_is_started_once_before_transient_success(self):
        result = self.run_scenario("absent-transient-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "DEVICE_ID=device-id-fixture",
                "DEVICE_ID_STATE=ready",
                "ATTEMPTS=3",
                "STARTS=1",
                "SLEEPS=2",
            ],
        )

    def test_existing_application_is_not_restarted(self):
        result = self.run_scenario("existing-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STARTS=0", result.stdout.splitlines())

    def test_deadline_fails_closed_without_late_attempt_or_sleep(self):
        result = self.run_scenario("deadline")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "UU Remote device readiness timed out after 2 attempts.",
                "ATTEMPTS=2 STARTS=0 SLEEPS=1 TIMEOUTS=1000,600",
            ],
        )

    def test_late_success_is_not_emitted_after_the_absolute_deadline(self):
        result = self.run_scenario("late-success")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "UU Remote device readiness timed out after 1 attempts.",
                "ATTEMPTS=1 STARTS=0 SLEEPS=0 TIMEOUTS=600",
            ],
        )

    def test_configuration_and_launch_failures_do_not_poll(self):
        cases = {
            "invalid-timing": (
                "UU Remote readiness timing values are invalid.",
                "ATTEMPTS=0 STARTS=0 SLEEPS=0 TIMEOUTS=",
            ),
            "missing-paths": (
                "UU Remote readiness paths are unavailable.",
                "ATTEMPTS=0 STARTS=0 SLEEPS=0 TIMEOUTS=",
            ),
            "launch-failure": (
                "UU Remote application launch failed.",
                "ATTEMPTS=0 STARTS=1 SLEEPS=0 TIMEOUTS=",
            ),
        }
        for scenario, expected in cases.items():
            with self.subTest(scenario=scenario):
                result = self.run_scenario(scenario)
                self.assertEqual(result.returncode, 1 if scenario != "invalid-timing" else 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.splitlines(), list(expected))


class MacOSReadinessSourceTests(unittest.TestCase):
    def test_production_route_uses_fixed_windows_aligned_defaults(self):
        script = text(SCRIPT_PATH)
        route = shell_if_block(
            script,
            'if [ "$mode" = "launch-and-wait-device" ]; then',
        )
        self.assertIn('launch_and_wait_device 60 500', route)
        self.assertIn('/usr/bin/pgrep -x UURemote', script)
        self.assertIn('if [ "$#" -ne 1 ]; then', route)
        self.assertIn('Usage: apple.sh launch-and-wait-device', route)


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class DesktopPreferenceBehaviorTests(unittest.TestCase):
    def test_terminal_transform_updates_every_profile_and_preserves_other_data(self):
        source_preferences = {
            "Default Window Settings": "Basic",
            "Window Settings": {
                "Basic": {"shellExitAction": 2, "rowCount": 24},
                "Pro": {"rowCount": 40},
            },
            "SecureKeyboardEntry": False,
        }

        with tempfile.TemporaryDirectory() as temporary_directory:
            input_path = Path(temporary_directory) / "input.plist"
            output_path = Path(temporary_directory) / "output.plist"
            input_path.write_bytes(plistlib.dumps(source_preferences))

            result = subprocess.run(
                [
                    "/bin/bash",
                    str(SCRIPT_PATH),
                    "transform-terminal-preferences",
                    str(input_path),
                    str(output_path),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            transformed = plistlib.loads(output_path.read_bytes())
            self.assertEqual(
                {
                    name: profile["shellExitAction"]
                    for name, profile in transformed["Window Settings"].items()
                },
                {"Basic": 0, "Pro": 0},
            )
            self.assertEqual(transformed["Window Settings"]["Basic"]["rowCount"], 24)
            self.assertEqual(transformed["SecureKeyboardEntry"], False)

    def test_terminal_transform_rejects_missing_window_settings_profiles(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            input_path = Path(temporary_directory) / "input.plist"
            output_path = Path(temporary_directory) / "output.plist"
            input_path.write_bytes(plistlib.dumps({"Window Settings": {}}))

            result = subprocess.run(
                [
                    "/bin/bash",
                    str(SCRIPT_PATH),
                    "transform-terminal-preferences",
                    str(input_path),
                    str(output_path),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output_path.exists())

    def test_missing_terminal_profiles_are_initialized_without_touching_an_existing_session(self):
        script = text(SCRIPT_PATH)
        initializer_start = script.index("initialize_terminal_preferences_if_needed()")
        initializer_end = script.index("configure_terminal_preferences()", initializer_start)
        initializer = script[initializer_start:initializer_end]

        self.assertIn("terminal_preferences_have_profiles", initializer)
        self.assertIn("terminal_was_running", initializer)
        self.assertIn("open -gj -a Terminal", initializer)
        self.assertIn('tell application "Terminal" to quit', initializer)
        self.assertIn('[ "$terminal_was_running" -eq 0 ]', initializer)

    def test_terminal_profile_probe_reads_nonseekable_defaults_pipe(self):
        script = text(SCRIPT_PATH)
        probe_start = script.index("terminal_preferences_have_profiles()")
        probe_end = script.index(
            "initialize_terminal_preferences_if_needed()",
            probe_start,
        )
        probe = script[probe_start:probe_end]

        self.assertIn("plistlib.loads(sys.stdin.buffer.read())", probe)
        self.assertNotIn("plistlib.load(sys.stdin.buffer)", script)

    def test_keyboard_contract_uses_system_settings_visible_extremes(self):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), "desktop-preference-contract"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["KeyRepeat=2", "InitialKeyRepeat=15"],
        )

    def test_localization_refresh_has_no_restart_or_logout_commands(self):
        script = text(SCRIPT_PATH)
        self.assertIn("refresh_localized_desktop()", script)
        self.assertIn('killall Finder', script)
        self.assertIn('killall SystemUIServer', script)
        self.assertNotIn("shutdown -r", script)
        self.assertNotIn(" to log out", script)


class PermissionFinalizationContractTests(unittest.TestCase):
    def test_permission_outline_probe_and_retries_are_bounded(self):
        script = text(SCRIPT_PATH)
        probe = script[
            script.index("on getPermissionOutline") :
            script.index("end getPermissionOutline")
        ]
        ensure = script[
            script.index("on ensurePermission") : script.index("end ensurePermission")
        ]

        self.assertIn("with timeout of 10 seconds", probe)
        self.assertIn("if errorNumber is -1712 then return missing value", probe)
        self.assertIn("set outlineWaitAttempts to 3", ensure)
        self.assertIn(
            "if activeDebugLevel is greater than or equal to 1 then set outlineWaitAttempts to 12",
            ensure,
        )
        self.assertGreaterEqual(ensure.count("repeat outlineWaitAttempts times"), 3)

    def test_permission_page_probe_retries_transient_apple_event_failures(self):
        script = text(SCRIPT_PATH)
        ensure = script[
            script.index("on ensurePermission") : script.index("end ensurePermission")
        ]

        self.assertIn("set pageWaitAttempts to 20", ensure)
        self.assertIn(
            "if activeDebugLevel is greater than or equal to 1 then set pageWaitAttempts to 120",
            ensure,
        )
        self.assertGreaterEqual(ensure.count("repeat pageWaitAttempts times"), 2)
        self.assertGreaterEqual(ensure.count("on error pageProbeError"), 2)

    def test_go_to_folder_waits_for_the_focused_text_field(self):
        script = text(SCRIPT_PATH)
        chooser = script[
            script.index("-- Use the standard macOS file chooser's Go to Folder command.") :
            script.index("-- Assign the accessibility value directly.")
        ]

        self.assertIn("set goToFolderField to missing value", chooser)
        self.assertIn("repeat 40 times", chooser)
        self.assertIn("set focusedItem to value of attribute \"AXFocusedUIElement\"", chooser)
        self.assertIn("set goToFolderField to focusedItem", chooser)
        self.assertIn("if goToFolderField is missing value then", chooser)

    def test_restart_prompt_probe_scans_only_sheets_with_a_hard_timeout(self):
        script = text(SCRIPT_PATH)
        probe = script[
            script.index("on inspectUURemoteRestartPrompt") :
            script.index("end inspectUURemoteRestartPrompt")
        ]

        self.assertIn("with timeout of 2 seconds", probe)
        self.assertIn("repeat with promptSheet in sheets of processWindow", probe)
        self.assertIn("windowContext(actualSheet)", probe)
        self.assertNotIn("windowContext(processWindow)", probe)
        self.assertIn("if errorNumber is -1712 then return \"\"", probe)

    def test_private_picker_ax_probe_has_a_hard_apple_event_timeout(self):
        script = text(SCRIPT_PATH)
        probe = script[
            script.index("on inspectPrivateWindowPickerPrompt") :
            script.index("end inspectPrivateWindowPickerPrompt")
        ]

        self.assertIn("with timeout of 2 seconds", probe)
        self.assertIn("if errorNumber is -1712 then return \"\"", probe)

    def test_screenshot_probe_does_not_wait_behind_uuremote_picker(self):
        script = text(SCRIPT_PATH)
        screenshot = script[
            script.index("on emitScreenshot") : script.index("end emitScreenshot")
        ]

        uuremote_probe = (
            'inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", false)'
        )
        bash_probe = "dismissPrivateWindowScreenshotPrompt()"
        self.assertIn("repeat 8 times", screenshot)
        self.assertLess(screenshot.index(uuremote_probe), screenshot.index(bash_probe))
        self.assertIn(
            "UURemote private window picker is pending; leaving it for the exact handler",
            screenshot,
        )

    def test_permission_dialogs_use_exact_bilingual_actions(self):
        script = text(SCRIPT_PATH)

        for token in (
            "com.netease.uuremote.agent",
            "Allow",
            "允许",
            "Quit & Reopen",
            "Quit and Reopen",
            "退出并重新打开",
        ):
            with self.subTest(token=token):
                self.assertIn(token, script)

    def test_old_blind_post_add_return_is_absent(self):
        script = text(SCRIPT_PATH)
        self.assertNotIn(
            "accepted the default post-add confirmation, if present",
            script,
        )

    def test_final_order_is_picker_then_minimize_then_close_settings(self):
        script = text(SCRIPT_PATH)
        normalize_definition = script.index("normalize_remote_desktop()")
        picker = script.rindex("run_permission agent-private-picker")
        normalize_call = script.index("normalize_remote_desktop normalize", picker)

        self.assertLess(normalize_definition, picker)
        self.assertLess(picker, normalize_call)
        self.assertLess(
            script.index("minimizeUURemoteWindows", normalize_definition),
            script.index("closeSystemSettings", normalize_definition),
        )

    def test_normalizer_verifies_cli_dialogs_minimized_app_and_closed_settings(self):
        script = text(SCRIPT_PATH)

        for token in (
            "AXMinimized",
            "UserNotificationCenter",
            "System Settings",
            "wait_for_cli",
            "FINAL_DESKTOP_STATE=ready",
        ):
            with self.subTest(token=token):
                self.assertIn(token, script)

    def test_no_ordinary_uuremote_window_is_an_already_hidden_success_state(self):
        script = text(SCRIPT_PATH)

        self.assertNotIn(
            "No UU Remote ordinary window was available to minimize",
            script,
        )
        self.assertNotIn(
            "No UU Remote ordinary window was available for final verification",
            script,
        )
        self.assertIn("ordinary windows minimized or absent", script)


class DiagnosticStateContractTests(unittest.TestCase):
    def test_assist_diagnostics_stay_in_the_step_log(self):
        workflow = text(WORKFLOW_PATH)
        permission = step_block(workflow, "Configure UU Remote permissions")
        upload = step_block(workflow, "Upload UU Remote diagnostics")

        self.assertIn("UUREMOTE_DEBUG:", workflow)
        self.assertEqual(permission.count(".github/workflows/apple.sh"), 1)
        self.assertNotIn("ASSIST_DIAGNOSTIC_", upload)

    def test_final_and_live_snapshots_do_not_open_uuremote(self):
        script = text(SCRIPT_PATH)
        capture = script[
            script.index("capture_snapshot()") :
            script.index("dismiss_uuremote_private_window_prompt()")
        ]

        self.assertNotIn('run_in_gui /usr/bin/open "$APP"', capture)
        self.assertNotIn("live-*|final-app*", capture)

    def test_normalization_precedes_wait_connections(self):
        workflow = text(WORKFLOW_PATH)
        permission = workflow.index("      - name: Configure UU Remote permissions")
        wait_connections = workflow.index("      - name: Wait connections")

        self.assertLess(permission, wait_connections)

    def test_debug_zero_keeps_screenshot_and_artifact_paths_disabled(self):
        workflow = text(WORKFLOW_PATH)
        upload = step_block(workflow, "Upload UU Remote diagnostics")

        self.assertIn("env.UUREMOTE_DEBUG != '0'", upload)
        self.assertIn("name: uuremote-diagnostics", upload)
        self.assertIn("${{ runner.temp }}/uuremote-diagnostics/", upload)


if __name__ == "__main__":
    unittest.main()
