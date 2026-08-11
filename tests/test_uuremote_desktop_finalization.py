from pathlib import Path
import os
import plistlib
import subprocess
import tempfile
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


if __name__ == "__main__":
    unittest.main()
