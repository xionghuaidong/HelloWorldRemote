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
        self.assertNotIn("inputs.account_password", block)
        self.assertIn("GITHUB_EVENT_PATH", block)
        self.assertIn("::add-mask::", block)
        self.assertIn('export UUREMOTE_ACCOUNT_PASSWORD="$account_password"', block)
        self.assertIn(".github/workflows/apple.sh configure-host", block)

    def test_permission_idempotency_does_not_repeat_host_configuration(self):
        workflow = text(WORKFLOW_PATH)
        block = step_block(workflow, "Verify permission idempotency")
        self.assertNotIn("configure-host", block)


class ScriptRoutingAndCodecTests(unittest.TestCase):
    def test_configure_host_is_dispatched_before_uuremote_app_preflight(self):
        script = text(SCRIPT_PATH)
        dispatch_marker = 'if [ "$mode" = "configure-host" ]'
        self.assertIn(dispatch_marker, script)
        self.assertLess(
            script.index(dispatch_marker),
            script.index('if [ ! -d "$APP" ]'),
        )

    def test_codec_self_test_is_side_effect_free_and_passes(self):
        completed = subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), "self-test-kcpassword"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), "kcpassword codec self-test passed")


class AccountTransactionContractTests(unittest.TestCase):
    def test_macos_uses_the_available_test_binary(self):
        script = text(SCRIPT_PATH)
        self.assertNotIn("/usr/bin/test", script)
        self.assertIn("/bin/test", script)

    def test_console_account_is_discovered_without_runner_or_home_shortcuts(self):
        script = text(SCRIPT_PATH)
        self.assertIn("resolve_console_account()", script)
        self.assertIn("stat -f '%Su' /dev/console", script)
        self.assertIn("NFSHomeDirectory", script)
        self.assertNotIn('console_user="runner"', script)
        self.assertNotIn('console_home="$HOME"', script)

    def test_user_transaction_has_verification_and_reverse_rollback(self):
        script = text(SCRIPT_PATH)
        for function_name in (
            "password_authenticates",
            "user_keychain_unlocks",
            "configure_console_user",
            "rollback_console_user_transaction",
            "write_kcpassword_atomically",
            "restore_original_kcpassword",
        ):
            self.assertIn(f"{function_name}()", script)
        self.assertIn("user_keychain_changed", script)
        self.assertIn("user_password_changed", script)
        self.assertIn("kcpassword_changed", script)

    def test_kcpassword_write_is_atomic_and_protected(self):
        script = text(SCRIPT_PATH)
        self.assertIn('chown root:wheel "$kcpassword_temp"', script)
        self.assertIn('chmod 0600 "$kcpassword_temp"', script)
        self.assertIn('mv -f "$kcpassword_temp" /etc/kcpassword', script)
        self.assertIn('decode_kcpassword /etc/kcpassword', script)


class RootSafetyContractTests(unittest.TestCase):
    def test_script_never_enables_root_or_changes_sshd(self):
        script = text(SCRIPT_PATH)
        for token in ("dsenableroot", "PermitRootLogin", "sshd_config"):
            self.assertNotIn(token, script)

    def test_root_disabled_state_and_password_hash_are_verified(self):
        script = text(SCRIPT_PATH)
        for function_name in (
            "root_is_disabled",
            "verify_root_password_hash",
            "configure_root",
        ):
            self.assertIn(f"{function_name}()", script)
        self.assertIn("DisabledUser", script)
        self.assertIn("authentication_authorities is None", script)
        self.assertIn("plistlib.loads", script)
        self.assertIn("bytes.fromhex", script)
        self.assertIn("SALTED-SHA512-PBKDF2", script)
        self.assertIn("hashlib.pbkdf2_hmac", script)

    def test_root_keychain_is_optional_transactional_and_cleaned(self):
        script = text(SCRIPT_PATH)
        for function_name in (
            "find_root_login_keychain",
            "rollback_root_keychain",
            "commit_root_keychain_backup",
        ):
            self.assertIn(f"{function_name}()", script)
        self.assertIn("root_keychain_backup", script)
        self.assertIn(
            "No root login keychain exists; leaving it absent", script
        )


class LocaleContractTests(unittest.TestCase):
    def test_language_order_fallback_and_singapore_locale_are_explicit(self):
        script = text(SCRIPT_PATH)
        for token in ("zh-Hans-SG", "zh-Hans-CN", "en-SG", "zh_SG"):
            self.assertIn(token, script)
        self.assertIn("language_settings_match()", script)
        self.assertIn("configure_language_and_region()", script)

    def test_only_known_negative_restart_actions_are_clickable(self):
        script = text(SCRIPT_PATH)
        for title in (
            "Not Now",
            "Later",
            "Restart Later",
            "稍后",
            "暂不",
            "以后再说",
        ):
            self.assertIn(title, script)
        self.assertNotIn('{"Restart Now"', script)
        self.assertNotIn('{"现在重新启动"', script)

    def test_prompt_scan_is_conditional_on_real_preference_changes(self):
        script = text(SCRIPT_PATH)
        self.assertIn("dismiss_safe_restart_prompt()", script)
        self.assertRegex(
            script,
            r'if \[ "\$language_or_region_changed" = "1" \]; then\s+'
            r'dismiss_safe_restart_prompt',
        )


class BilingualPermissionContractTests(unittest.TestCase):
    def test_permission_vocabulary_contains_english_and_chinese(self):
        script = text(SCRIPT_PATH)
        for english, chinese in (
            ("Accessibility", "辅助功能"),
            ("Screen & System Audio Recording", "录屏与系统录音"),
            ("Allow", "允许"),
            ("Open System Settings", "打开系统设置"),
        ):
            self.assertIn(english, script)
            self.assertIn(chinese, script)

    def test_private_picker_requires_bundle_id_and_two_known_actions(self):
        script = text(SCRIPT_PATH)
        self.assertIn("com.netease.uuremote.agent", script)
        self.assertIn("allowButton", script)
        self.assertIn("openSettingsButton", script)
        self.assertNotIn('contextText contains "private window picker"', script)

    def test_server_is_not_a_permission_target(self):
        script = text(SCRIPT_PATH)
        permission_calls = re.findall(r"^run_permission ([^\n]+)$", script, re.MULTILINE)
        self.assertEqual(
            permission_calls,
            ["accessibility-main", "screen-capture", "agent-private-picker"],
        )


if __name__ == "__main__":
    unittest.main()
