from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
MACOS_WORKFLOW = ROOT / ".github/workflows/macos.yml"
WINDOWS_WORKFLOW = ROOT / ".github/workflows/windows.yml"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]


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
