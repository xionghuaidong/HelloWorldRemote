import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
MACOS_WORKFLOW = ROOT / ".github/workflows/macos.yml"
WINDOWS_WORKFLOW = ROOT / ".github/workflows/windows.yml"
WINDOWS_HELPER = ROOT / ".github/workflows/windows.ps1"
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
