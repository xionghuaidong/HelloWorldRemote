from pathlib import Path
import os
import plistlib
import subprocess
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


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSAssistAllowProcessTests(unittest.TestCase):
    def run_harness(self, mode: str, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), mode, scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_completed_process_records_exact_safe_status(self):
        result = self.run_harness("process", "completed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "STATUS=completed:0\n")

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
            "GUI_COMMAND=sudo|launchctl|asuser|501|sudo|-u|#501|/bin/true\n",
        )


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSAssistAllowAggregationTests(unittest.TestCase):
    def run_harness(self, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), "aggregate", scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

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
        self.assertIn("ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=1", result.stderr)
        self.assertIn("TEMPORARY_TREE_EMPTY=true", result.stdout)

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
        ):
            with self.subTest(scenario=scenario):
                result = self.run_harness(scenario)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(
                    result.stderr,
                    "Could not enable unattended control within 60 seconds\n",
                )

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
