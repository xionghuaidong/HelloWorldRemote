from pathlib import Path
import os
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


class CustomCodeWorkflowTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
