from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/macos.yml"
SCRIPT_PATH = ROOT / ".github/workflows/apple.sh"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]


class WorkflowContractTests(unittest.TestCase):
    def test_password_input_is_required_string_with_expected_default(self):
        workflow = text(WORKFLOW_PATH)
        match = re.search(
            r"(?ms)^      account_password:\n"
            r"(?:(?!^      \S).)*?^        required: true\n"
            r"(?:(?!^      \S).)*?^        default: [\"']?john\.doe[\"']?\n"
            r"(?:(?!^      \S).)*?^        type: string$",
            workflow,
        )
        self.assertIsNotNone(match)

    def test_host_configuration_precedes_uuremote_install(self):
        workflow = text(WORKFLOW_PATH)
        self.assertIn("      - name: Configure macOS host", workflow)
        self.assertLess(
            workflow.index("      - name: Configure macOS host"),
            workflow.index("      - name: Install GameViewer"),
        )

    def test_password_is_scoped_and_masked_in_configuration_step(self):
        workflow = text(WORKFLOW_PATH)
        job_environment = workflow[
            workflow.index("    env:\n") : workflow.index("\n    steps:\n")
        ]
        self.assertNotIn("UUREMOTE_ACCOUNT_PASSWORD", job_environment)

        self.assertIn("      - name: Configure macOS host", workflow)
        block = step_block(workflow, "Configure macOS host")
        self.assertIn(
            "UUREMOTE_ACCOUNT_PASSWORD: ${{ inputs.account_password }}", block
        )
        self.assertIn("::add-mask::", block)
        self.assertIn(".github/workflows/apple.sh configure-host", block)

    def test_permission_idempotency_does_not_repeat_host_configuration(self):
        workflow = text(WORKFLOW_PATH)
        block = step_block(workflow, "Verify permission idempotency")
        self.assertNotIn("configure-host", block)


if __name__ == "__main__":
    unittest.main()
