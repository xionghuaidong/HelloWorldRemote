import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
MACOS_WORKFLOW = ROOT / ".github/workflows/macos.yml"
WINDOWS_WORKFLOW = ROOT / ".github/workflows/windows.yml"
WINDOWS_HELPER = ROOT / ".github/workflows/windows.ps1"
WINDOWS_HELPER_HARNESS = ROOT / "tests/windows_helper_harness.ps1"
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell.exe") or shutil.which("powershell")


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]


def run_windows_helper(mode: str, *args: str, environment: dict[str, str] | None = None):
    if POWERSHELL is None:
        raise RuntimeError("A PowerShell runtime is required to run the Windows helper tests.")

    return subprocess.run(
        [
            POWERSHELL,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(WINDOWS_HELPER),
            mode,
            *args,
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


class SharedWorkflowContractTests(unittest.TestCase):
    def test_windows_exposes_the_shared_dispatch_inputs(self):
        workflow = text(WINDOWS_WORKFLOW)
        self.assertIn("      debug_level:\n", workflow)
        self.assertIn('        default: "0"\n', workflow)
        for value in ('          - "0"', '          - "1"', '          - "2"', '          - "3"'):
            self.assertIn(value, workflow)
        self.assertIn("      wait_connections_seconds:\n", workflow)
        self.assertIn("        default: 300\n", workflow)
        self.assertIn("0-21000", workflow)

    def test_windows_custom_code_is_required_masked_and_step_scoped(self):
        workflow = text(WINDOWS_WORKFLOW)
        job_environment = workflow[workflow.index("    env:\n"):workflow.index("\n    steps:\n")]
        block = step_block(workflow, "Configure UU Remote custom code")
        self.assertNotIn("UUREMOTE_CUSTOM_CODE", job_environment)
        self.assertIn("UUREMOTE_CUSTOM_CODE: ${{ secrets.UUREMOTE_CUSTOM_CODE }}", block)
        self.assertIn("::add-mask::$env:UUREMOTE_CUSTOM_CODE", block)
        self.assertNotIn("johnDOE123", workflow)


class WindowsValidationBehaviorTests(unittest.TestCase):
    def test_custom_code_accepts_only_ascii_alphanumeric_8_through_16(self):
        for value in ("Abcdef12", "12345678", "A1b2C3d4E5f6G7h8"):
            environment = os.environ.copy()
            environment["UUREMOTE_CUSTOM_CODE"] = value
            self.assertEqual(
                run_windows_helper("validate-custom-code", environment=environment).returncode,
                0,
            )

    def test_invalid_custom_code_returns_two_without_echoing_the_value(self):
        for value in ("", "Abc1234", "A" * 17, "Abcd-123", "Abcd 123"):
            environment = os.environ.copy()
            environment["UUREMOTE_CUSTOM_CODE"] = value
            result = run_windows_helper("validate-custom-code", environment=environment)
            self.assertEqual(result.returncode, 2)
            if value:
                self.assertNotIn(value, result.stdout + result.stderr)

    def test_wait_validation_accepts_bounds_and_rejects_invalid_values(self):
        for value in ("0", "300", "21000"):
            self.assertEqual(run_windows_helper("validate-wait-seconds", value).returncode, 0)
        for value in ("-1", "21001", "1.5", "text", ""):
            self.assertEqual(run_windows_helper("validate-wait-seconds", value).returncode, 2)


class WindowsWaitBehaviorTests(unittest.TestCase):
    def test_zero_wait_returns_without_loading_the_watcher(self):
        result = run_windows_helper("wait-connections", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WAIT_RESULT=timeout", result.stdout)

    def test_injected_wait_self_test_passes(self):
        result = run_windows_helper("self-test-wait-connections")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shutdown-aware wait self-test passed", result.stdout)


class WindowsReadinessContractTests(unittest.TestCase):
    def test_workflow_delegates_launch_and_readiness(self):
        workflow = text(WINDOWS_WORKFLOW)
        self.assertIn("      - name: Verify unattended readiness\n", workflow)
        launch = step_block(workflow, "Launch GameViewer")
        readiness = step_block(workflow, "Verify unattended readiness")
        self.assertIn("windows.ps1 launch-and-wait-device", launch)
        self.assertIn("windows.ps1 verify-unattended-readiness", readiness)
        self.assertLess(workflow.index("Launch GameViewer"), workflow.index("Configure UU Remote custom code"))
        self.assertLess(
            workflow.index("Configure UU Remote custom code"),
            workflow.index("Verify unattended readiness"),
        )


class WindowsReadinessBehaviorTests(unittest.TestCase):
    def run_harness(self, mode: str):
        if POWERSHELL is None:
            self.skipTest("A PowerShell runtime is required to run the readiness harness.")

        return subprocess.run(
            [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(WINDOWS_HELPER_HARNESS),
                mode,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_readiness_retries_transient_failures_without_exposing_device_id(self):
        result = self.run_harness("readiness-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DEVICE_ID_STATE=ready", result.stdout)
        self.assertIn("ATTEMPTS=3", result.stdout)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_readiness_timeout_is_bounded_and_sanitized(self):
        result = self.run_harness("readiness-timeout")
        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_unattended_readiness_requires_a_running_process(self):
        result = self.run_harness("unattended-no-process")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unattended readiness failed", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_unattended_readiness_requires_a_nonempty_device_id(self):
        result = self.run_harness("unattended-no-device")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unattended readiness failed", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_unattended_readiness_reports_only_sanitized_success(self):
        result = self.run_harness("unattended-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UNATTENDED_READINESS=verified", result.stdout)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
