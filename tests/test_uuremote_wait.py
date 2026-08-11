from pathlib import Path
import platform
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/macos.yml"
SCRIPT_PATH = ROOT / ".github/workflows/apple.sh"
WATCHER_PATH = ROOT / ".github/workflows/uuremote-shutdown-wait.swift"


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


class WaitShellContractTests(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), *args],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_zero_returns_without_watcher_or_app_preflight(self):
        result = self.run_script("wait-connections", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("disabled (0 seconds)", result.stdout)

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


if __name__ == "__main__":
    unittest.main()
