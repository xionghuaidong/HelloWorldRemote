from pathlib import Path
import os
import platform
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/macos.yml"
SCRIPT_PATH = ROOT / ".github/workflows/apple.sh"
WATCHER_PATH = ROOT / ".github/workflows/uuremote-shutdown-wait.swift"
DEVICE_ID_LOGGING_HARNESS_PATH = ROOT / "tests/test_macos_device_id_logging.sh"
CLI_OUTPUT_REDACTION_HARNESS_PATH = ROOT / "tests/test_macos_cli_output_redaction.sh"
BASH_AVAILABLE = Path("/bin/bash").exists()


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]


class WaitWorkflowContractTests(unittest.TestCase):
    def test_input_range_debug_gate_and_delegation(self):
        workflow = text(WORKFLOW_PATH)
        self.assertIn("default: 300", workflow)
        self.assertIn("0-21000", workflow)

        block = step_block(workflow, "Wait connections")
        self.assertIn("if: success() && env.UUREMOTE_DEBUG == '0'", block)
        self.assertIn(
            '.github/workflows/apple.sh wait-connections "$wait_seconds"',
            block,
        )
        self.assertNotIn('sleep "$wait_seconds"', block)

    def test_wait_delegation_keeps_the_debug_zero_gate(self):
        wait = step_block(text(WORKFLOW_PATH), "Wait connections")
        self.assertIn("apple.sh wait-connections", wait)
        self.assertIn("env.UUREMOTE_DEBUG == '0'", wait)

    def test_appkit_self_test_is_diagnostic_only(self):
        workflow = text(WORKFLOW_PATH)
        block = step_block(workflow, "Test shutdown-aware wait")
        self.assertIn("if: env.UUREMOTE_DEBUG != '0'", block)
        self.assertIn(
            ".github/workflows/apple.sh self-test-wait-connections",
            block,
        )

    def test_device_id_logging_evidence_is_diagnostic_only_and_precedes_provisioning(self):
        workflow = text(WORKFLOW_PATH)
        self.assertIn("      - name: Test device ID logging\n", workflow)
        block = step_block(workflow, "Test device ID logging")
        commands = [
            line.strip()
            for line in block.split("        run: |\n", 1)[1].splitlines()
            if line.strip()
        ]

        self.assertIn("if: env.UUREMOTE_DEBUG != '0'", block)
        self.assertEqual(
            commands,
            [
                "/bin/bash tests/test_macos_device_id_logging.sh",
                "/bin/bash tests/test_macos_cli_output_redaction.sh",
                "python -m unittest tests.test_uuremote_wait tests.test_uuremote_desktop_finalization -v",
            ],
        )
        self.assertLess(
            workflow.index("      - name: Test device ID logging"),
            workflow.index("      - name: Configure macOS host"),
        )


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class WaitShellContractTests(unittest.TestCase):
    def run_script(
        self, *args: str, environment: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), *args],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_zero_returns_without_watcher_or_app_preflight(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture_path = Path(temporary_directory) / "uuyc-cli"
            fixture_path.write_text(
                "#!/bin/bash\nprintf '%s\\n' 'device-id-fixture'\n",
                encoding="utf-8",
            )
            fixture_path.chmod(0o700)
            environment = os.environ.copy()
            environment["UUREMOTE_CLI_PATH"] = str(fixture_path)

            result = self.run_script(
                "wait-connections", "0", environment=environment
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            ["WAIT_CONNECTIONS DEVICE_ID=device-id-fixture", "WAIT_RESULT=timeout"],
        )

    def test_invalid_values_return_two(self):
        for value in ("-1", "21001", "1.5", "text", ""):
            with self.subTest(value=value):
                result = self.run_script("wait-connections", value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("integer in the range 0-21000", result.stderr)

    def test_wait_route_precedes_uuremote_app_preflight(self):
        script = text(SCRIPT_PATH)
        route = 'if [ "$mode" = "wait-connections" ]'
        self.assertLess(
            script.index(route),
            script.index('if [ ! -d "$APP" ]'),
        )


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class DeviceIdLoggingHarnessTests(unittest.TestCase):
    def test_real_helper_rejects_unsafe_device_id_output(self):
        result = subprocess.run(
            ["/bin/bash", str(DEVICE_ID_LOGGING_HARNESS_PATH)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("macOS device ID logging contract passed", result.stdout)

    def test_real_helpers_redact_status_and_assist_output(self):
        result = subprocess.run(
            ["/bin/bash", str(CLI_OUTPUT_REDACTION_HARNESS_PATH)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("macOS CLI output redaction contract passed", result.stdout)


class WaitWatcherSourceTests(unittest.TestCase):
    def test_waiter_lifetime_is_extended_through_app_event_loop(self):
        source = text(WATCHER_PATH)
        self.assertIn("let waiter = ShutdownWaiter(", source)
        self.assertIn("withExtendedLifetime(waiter)", source)
        self.assertNotIn(
            "ShutdownWaiter(seconds: seconds, injectedEvent: injectedEvent).run()",
            source,
        )

    def test_only_exact_power_off_event_finishes_early(self):
        source = text(WATCHER_PATH)
        self.assertIn("event.type == .systemDefined", source)
        self.assertIn("event.subtype == .powerOff", source)
        self.assertNotIn("willPowerOffNotification", source)

        for forbidden in ("UURemote", "uuyc", "NWPathMonitor", "URLSession"):
            self.assertNotIn(forbidden, source)


@unittest.skipUnless(platform.system() == "Darwin", "requires AppKit")
class WaitWatcherBehaviorTests(unittest.TestCase):
    def test_shell_self_test_passes(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment = os.environ.copy()
            environment["UUREMOTE_SHUTDOWN_WAITER_SELF_TEST_ROOT"] = (
                temporary_directory
            )
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT_PATH), "self-test-wait-connections"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            remaining_paths = list(Path(temporary_directory).iterdir())
            process_probe = subprocess.run(
                ["/usr/bin/pgrep", "-f", f"{temporary_directory}/uuremote-shutdown-wait"],
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "WAIT_SELF_TEST_CLEANUP=released",
                "shutdown-aware wait self-test passed",
            ],
        )
        self.assertEqual(remaining_paths, [])
        self.assertEqual(process_probe.returncode, 1, process_probe.stdout)


if __name__ == "__main__":
    unittest.main()
