# UU Remote Desktop Finalization and Custom Code Secret Implementation Plan

[English](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret.md) | [简体中文](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the active macOS desktop immediately ready for UU Remote control with all permission dialogs closed, UU Remote minimized, System Settings closed, localized Finder and clock UI, productive Terminal and keyboard preferences, and a validated secret-backed custom code.

**Architecture:** Extend `apple.sh` with three bounded responsibilities: console-user desktop preference configuration, exact UU Remote permission-dialog handling, and final desktop normalization. Move custom-code validation and CLI invocation behind an `apple.sh` interface and scope its GitHub secret to one workflow step. Keep debug levels as orchestration policy: fast runs use condition polling, diagnostic runs add evidence without changing the final UI state.

**Tech Stack:** Bash 3.2, AppleScript/System Events accessibility APIs, Python 3 `plistlib`, macOS `defaults` and `launchctl`, UU Remote CLI, GitHub Actions YAML, Python `unittest`.

## Global Constraints

- Work directly on `main`; do not create a feature branch or worktree.
- Do not restart macOS.
- Do not log out the active graphical user.
- Do not terminate the UU Remote background service needed for unattended control.
- Continue to support English and Simplified Chinese macOS interfaces.
- Preserve debug meanings: `0` fast, `1` screenshots, `2` idempotency, `3` live sampling.
- Use exact localized security-dialog actions; never use screen coordinates or blind Return-key submission.
- Keep direct root login disabled and preserve `UUREMOTE_ACCOUNT_PASSWORD` behavior.
- Use `KeyRepeat=2` and `InitialKeyRepeat=15` exactly.
- Accept `UUREMOTE_CUSTOM_CODE` only when it matches `^[A-Za-z0-9]{8,16}$`.
- Run each red test before its production change, then rerun it green before committing.

---

### Task 1: Secret-backed UU Remote custom code

**Files:**
- Modify: `.github/workflows/macos.yml:64-104`
- Modify: `.github/workflows/apple.sh:1-120, 1071-1103, 1123-1335`
- Create: `tests/test_uuremote_desktop_finalization.py`

**Interfaces:**
- Consumes: step-scoped `UUREMOTE_CUSTOM_CODE`.
- Produces: `validate_uuremote_custom_code(value: string) -> shell status`, `set_uuremote_custom_code() -> shell status`, and the `apple.sh set-custom-code` command.

- [ ] **Step 1: Write failing workflow secret-contract tests**

Add to `tests/test_uuremote_desktop_finalization.py`:

```python
from pathlib import Path
import os
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/macos.yml"
SCRIPT = ROOT / ".github/workflows/apple.sh"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    end = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if end < 0 else workflow[start:end]


class CustomCodeWorkflowTests(unittest.TestCase):
    def test_custom_code_is_required_masked_and_step_scoped(self):
        workflow = read(WORKFLOW)
        job_env = workflow[workflow.index("    env:\n"):workflow.index("\n    steps:\n")]
        block = step_block(workflow, "Configure UU Remote custom code")

        self.assertNotIn("UUREMOTE_CUSTOM_CODE", job_env)
        self.assertIn(
            "UUREMOTE_CUSTOM_CODE: ${{ secrets.UUREMOTE_CUSTOM_CODE }}",
            block,
        )
        self.assertIn("::add-mask::${UUREMOTE_CUSTOM_CODE}", block)
        self.assertIn("apple.sh set-custom-code", block)

    def test_hard_coded_custom_code_and_cli_echo_are_absent(self):
        combined = read(WORKFLOW) + read(SCRIPT)
        self.assertNotIn("johnDOE123", combined)
        self.assertNotIn("echo \"customCode: $output\"", combined)
```

- [ ] **Step 2: Run the secret-contract tests and verify RED**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests -v
```

Expected: FAIL because the dedicated workflow step and `set-custom-code` route do not exist and `johnDOE123` is still present.

- [ ] **Step 3: Write failing executable validation tests**

Add:

```python
class CustomCodeValidationTests(unittest.TestCase):
    def validate(self, value: str | None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        if value is None:
            env.pop("UUREMOTE_CUSTOM_CODE", None)
        else:
            env["UUREMOTE_CUSTOM_CODE"] = value
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), "validate-custom-code"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_accepts_only_ascii_alphanumeric_codes_of_length_8_through_16(self):
        for value in ("Abcdef12", "A1b2C3d4E5f6G7h8", "12345678"):
            with self.subTest(value=value):
                self.assertEqual(self.validate(value).returncode, 0)

        for value in (None, "", "Abc1234", "A" * 17, "Abcd-123", "密码Abcd1234"):
            with self.subTest(value=value):
                result = self.validate(value)
                self.assertEqual(result.returncode, 2)
                if value:
                    self.assertNotIn(value, result.stdout + result.stderr)
```

- [ ] **Step 4: Run validation tests and verify RED**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeValidationTests -v
```

Expected: FAIL because `validate-custom-code` is not implemented.

- [ ] **Step 5: Implement validation and CLI retry without logging the value**

Add an early platform-independent validator and route before any macOS preflight:

```bash
validate_uuremote_custom_code() {
    local value="${1:-}"
    [[ "$value" =~ ^[A-Za-z0-9]{8,16}$ ]]
}

if [ "$mode" = "validate-custom-code" ]; then
    if validate_uuremote_custom_code "${UUREMOTE_CUSTOM_CODE:-}"; then
        exit 0
    fi
    echo "UUREMOTE_CUSTOM_CODE must match ^[A-Za-z0-9]{8,16}$" >&2
    exit 2
fi
```

After `run_in_gui` is available, implement `set_uuremote_custom_code` so it validates before the first CLI call, retries at 500 ms up to 120 times, discards CLI stdout, logs only attempt counts and a generic success message, and unsets its local copy and the environment variable before returning.

Split `Launch GameViewer` so it only starts UU Remote and waits for the device ID. Add immediately afterward:

```yaml
      - name: Configure UU Remote custom code
        shell: bash
        env:
          UUREMOTE_CUSTOM_CODE: ${{ secrets.UUREMOTE_CUSTOM_CODE }}
        run: |
            if [ -z "${UUREMOTE_CUSTOM_CODE:-}" ]; then
                echo "Repository secret UUREMOTE_CUSTOM_CODE is required" >&2
                exit 2
            fi
            echo "::add-mask::${UUREMOTE_CUSTOM_CODE}"
            .github/workflows/apple.sh set-custom-code
            unset UUREMOTE_CUSTOM_CODE
```

Move the existing permission invocation into a following `Configure UU Remote permissions` step with no custom-code environment variable.

- [ ] **Step 6: Run focused and full tests GREEN**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests -v
python3 -m unittest tests.test_uuremote_desktop_finalization.CustomCodeValidationTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

Expected: all tests and checks pass with no secret value in output.

- [ ] **Step 7: Commit Task 1**

```bash
git add .github/workflows/macos.yml .github/workflows/apple.sh tests/test_uuremote_desktop_finalization.py
git commit -m "security: source UU Remote custom code from secret"
git push origin main
```

---

### Task 2: Desktop preferences and no-restart localization refresh

**Files:**
- Modify: `.github/workflows/apple.sh:858-1068`
- Modify: `tests/test_uuremote_desktop_finalization.py`

**Interfaces:**
- Consumes: existing `console_uid`, `console_user`, `console_home`, `run_as_console_user`.
- Produces: `configure_desktop_preferences()`, `desktop_preferences_match()`, and `refresh_localized_desktop()`.

- [ ] **Step 1: Write failing preference contract tests**

Add:

```python
class DesktopPreferenceContractTests(unittest.TestCase):
    def test_keyboard_uses_system_settings_visible_extremes(self):
        script = read(SCRIPT)
        self.assertIn("KeyRepeat", script)
        self.assertIn("InitialKeyRepeat", script)
        self.assertRegex(script, r"KeyRepeat.*(?:-int|integer).*2")
        self.assertRegex(script, r"InitialKeyRepeat.*(?:-int|integer).*15")

    def test_every_terminal_profile_gets_shell_exit_action_zero(self):
        script = read(SCRIPT)
        self.assertIn('preferences.get("Window Settings")', script)
        self.assertIn('profile["shellExitAction"] = 0', script)
        self.assertNotIn('"Window Settings":Basic:shellExitAction', script)

    def test_localization_refresh_never_restarts_or_logs_out(self):
        script = read(SCRIPT)
        self.assertIn("refresh_localized_desktop()", script)
        self.assertIn('killall Finder', script)
        self.assertIn('killall SystemUIServer', script)
        self.assertNotIn("shutdown -r", script)
        self.assertNotIn("osascript -e 'tell application \"System Events\" to log out'", script)
```

- [ ] **Step 2: Run preference tests and verify RED**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DesktopPreferenceContractTests -v
```

Expected: FAIL because the desktop preference unit does not exist.

- [ ] **Step 3: Implement deterministic preference writes and read-back**

Implement `configure_desktop_preferences` directly after
`configure_language_and_region`:

- write `NSGlobalDomain KeyRepeat -int 2` and `InitialKeyRepeat -int 15` as the console user;
- export `com.apple.Terminal` to a temporary plist owned by the console user;
- use Python `plistlib` to require a dictionary at `Window Settings`, iterate every profile dictionary, and set `shellExitAction` to integer `0`;
- import the modified plist through the console user's `defaults` process;
- remove the exact temporary plist using the existing bootstrap temporary directory;
- read both domains back and fail unless every value matches.

The Python mutation core must be equivalent to:

```python
window_settings = preferences.get("Window Settings")
if not isinstance(window_settings, dict) or not window_settings:
    raise SystemExit("Terminal Window Settings profiles are unavailable")
for profile in window_settings.values():
    if isinstance(profile, dict):
        profile["shellExitAction"] = 0
```

- [ ] **Step 4: Implement targeted localization refresh and UI verification**

Implement `refresh_localized_desktop` to:

- stop the console user's `cfprefsd` so new global preferences are loaded;
- terminate only Finder, SystemUIServer, and ControlCenter when present;
- wait conditionally for Finder and the menu-bar owner to return;
- inspect Finder's accessibility menu bar for Chinese menu titles and reject the English set `File`, `Edit`, `View`, `Go`, `Window`, `Help`;
- inspect SystemUIServer and ControlCenter menu-bar items and reject English weekday/month tokens while requiring at least one Chinese date marker such as `月`, `周`, `星期`, `上午`, or `下午`.

Do not call reboot, shutdown, or logout APIs. Call `configure_desktop_preferences` from `configure_host` after language and region configuration and before committing the host transaction.

- [ ] **Step 5: Run focused and full tests GREEN**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DesktopPreferenceContractTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

Expected: all checks pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add .github/workflows/apple.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: configure macOS remote desktop preferences"
git push origin main
```

---

### Task 3: Exact restart prompt handling and final desktop normalization

**Files:**
- Modify: `.github/workflows/apple.sh:1425-2386`
- Modify: `tests/test_uuremote_desktop_finalization.py`

**Interfaces:**
- Consumes: existing target application names, debug level, screenshot directory, and CLI readiness helper.
- Produces: AppleScript `dismissUURemoteRestartPrompt`, shell `normalize_remote_desktop()`, and a final-state verifier.

- [ ] **Step 1: Write failing permission and ordering tests**

Add:

```python
class PermissionFinalizationContractTests(unittest.TestCase):
    def test_permission_dialogs_use_exact_bilingual_actions(self):
        script = read(SCRIPT)
        for token in (
            "com.netease.uuremote.agent",
            "Allow",
            "允许",
            "Quit & Reopen",
            "Quit and Reopen",
            "退出并重新打开",
        ):
            self.assertIn(token, script)

    def test_old_blind_post_add_return_is_absent(self):
        script = read(SCRIPT)
        self.assertNotIn(
            "accepted the default post-add confirmation, if present",
            script,
        )

    def test_final_order_is_picker_then_minimize_then_close_settings(self):
        script = read(SCRIPT)
        picker = script.rindex("run_permission agent-private-picker")
        normalize = script.index("normalize_remote_desktop", picker)
        self.assertLess(picker, normalize)
        self.assertLess(
            script.index("minimizeUURemoteWindows", normalize),
            script.index("closeSystemSettings", normalize),
        )

    def test_normalizer_verifies_cli_dialogs_minimized_app_and_closed_settings(self):
        script = read(SCRIPT)
        for token in (
            "AXMinimized",
            "UserNotificationCenter",
            "System Settings",
            "wait_for_cli",
            "FINAL_DESKTOP_STATE=ready",
        ):
            self.assertIn(token, script)
```

- [ ] **Step 2: Run permission tests and verify RED**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.PermissionFinalizationContractTests -v
```

Expected: FAIL because no desktop normalizer exists and the blind post-add Return path remains.

- [ ] **Step 3: Replace blind restart acceptance with dialog-specific matching**

Inside the permission AppleScript:

- remove the unconditional `key code 36` and its generic success message;
- build a dialog context string from window title, description, and static text;
- require the context to contain the UU Remote name plus the recording-until-quit meaning in English or Simplified Chinese;
- search only that window for `Quit & Reopen`, `Quit and Reopen`, or `退出并重新打开`;
- press the exact action, wait for that specific dialog to disappear, wait for UU Remote and its CLI to return, then re-read the screen-recording switch;
- treat an absent prompt as the idempotent path, but fail if a matched prompt has no recognized action.

- [ ] **Step 4: Implement final desktop normalization**

Add a shell `normalize_remote_desktop` after the final private-picker handler.
Its AppleScript must expose and call these handlers in order:

- `assertKnownPromptsAbsent()` calls the existing private-picker inspector with
  `shouldPressAllow=false`, scans every System Settings window for the bilingual
  UU Remote recording-until-quit text, and raises an error when either inspector
  returns a match;
- `minimizeUURemoteWindows()` iterates every existing process whose name matches
  the bilingual UU Remote target-name list, sets each ordinary window's
  `AXMinimized` attribute to `true`, and re-reads the attribute before returning;
- `closeSystemSettings()` sends the normal application quit event, polls until
  the process is absent or has zero windows, and uses the existing GUI-session
  `killall` fallback only if a window remains after the bounded graceful wait.

After UI cleanup, call `wait_for_cli`, verify that all remaining UU Remote ordinary windows report `AXMinimized=true`, verify System Settings has no window, rescan both known dialogs, and print exactly `FINAL_DESKTOP_STATE=ready`.

Install an EXIT trap around permission configuration that captures a diagnostic screenshot when debug is enabled and attempts only the non-clicking parts of normalization. Clear the trap after successful final verification.

- [ ] **Step 5: Run focused and full tests GREEN**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.PermissionFinalizationContractTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

Expected: all checks pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add .github/workflows/apple.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: finalize UU Remote macOS desktop state"
git push origin main
```

---

### Task 4: Preserve the final state across diagnostics and idempotency

**Files:**
- Modify: `.github/workflows/apple.sh:1163-1235, 2361-2386`
- Modify: `.github/workflows/macos.yml:105-149`
- Modify: `tests/test_uuremote_desktop_finalization.py`

**Interfaces:**
- Consumes: final desktop contract from Task 3 and existing debug level.
- Produces: state-preserving `capture_snapshot(label)` and workflow ordering guarantees.

- [ ] **Step 1: Write failing diagnostics-state tests**

Add:

```python
class DiagnosticStateContractTests(unittest.TestCase):
    def test_final_and_live_snapshots_do_not_open_uuremote(self):
        script = read(SCRIPT)
        capture = script[
            script.index("capture_snapshot()"):
            script.index("dismiss_uuremote_private_window_prompt()")
        ]
        self.assertNotIn('run_in_gui /usr/bin/open "$APP"', capture)
        self.assertNotIn("live-*|final-app*", capture)

    def test_normalization_precedes_wait_connections(self):
        workflow = read(WORKFLOW)
        permission = workflow.index("      - name: Configure UU Remote permissions")
        wait = workflow.index("      - name: Wait connections")
        self.assertLess(permission, wait)

    def test_debug_zero_keeps_screenshot_and_artifact_paths_disabled(self):
        workflow = read(WORKFLOW)
        upload = step_block(workflow, "Upload permission screenshots")
        self.assertIn("env.UUREMOTE_DEBUG != '0'", upload)
```

- [ ] **Step 2: Run diagnostic-state tests and verify RED**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DiagnosticStateContractTests -v
```

Expected: FAIL because `capture_snapshot` still opens UU Remote for `live-*` and `final-app*`.

- [ ] **Step 3: Make evidence capture observational only**

Remove the `live-*|final-app*` open-app case from `capture_snapshot`. Rename the final label to `final-desktop`, invoke it only after normalization, and ensure level 1 captures:

- restart prompt before and after;
- private picker before and after Allow;
- Finder/clock localization verification;
- final clean desktop after UU Remote is minimized and System Settings is closed.

Keep level 0 screenshot-free. Keep the level 2 second permission run and level 3 live sampler, but make every sample observe the already normalized state.

- [ ] **Step 4: Run focused and full tests GREEN**

Run:

```bash
python3 -m unittest tests.test_uuremote_desktop_finalization.DiagnosticStateContractTests -v
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

Expected: all checks pass.

- [ ] **Step 5: Commit Task 4**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_uuremote_desktop_finalization.py
git commit -m "test: preserve finalized desktop during diagnostics"
git push origin main
```

---

### Task 5: macOS Actions validation and final handoff

**Files:**
- Verify: `.github/workflows/apple.sh`
- Verify: `.github/workflows/macos.yml`
- Verify: `tests/test_uuremote_desktop_finalization.py`
- Verify: `tests/test_uuremote_host_bootstrap.py`

**Interfaces:**
- Consumes: repository secrets `UUREMOTE_ACCOUNT_PASSWORD` and `UUREMOTE_CUSTOM_CODE`.
- Produces: two successful Actions runs and evidence that the final desktop contract holds.

- [ ] **Step 1: Run complete repository verification**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
git status --short --branch
```

Expected: all tests pass, Bash syntax succeeds, no whitespace errors, and the worktree is clean.

- [ ] **Step 2: Confirm both repository secrets exist without reading values**

Use the GitHub Actions secrets page and verify the names
`UUREMOTE_ACCOUNT_PASSWORD` and `UUREMOTE_CUSTOM_CODE` are listed. If the custom-code secret is missing, stop and ask the user to create it; never invent or display its value.

- [ ] **Step 3: Run diagnostic Actions validation**

Dispatch `macOS` with:

```text
debug_level=1
wait_connections_seconds=0
```

Verify logs contain generic custom-code success, persisted permissions, localized Finder/clock verification, Terminal and keyboard read-back, `FINAL_DESKTOP_STATE=ready`, and no secret value. Inspect the artifact's final screenshot to confirm UU Remote and System Settings are not visible in front.

- [ ] **Step 4: Fix any macOS-only failure through a new RED/GREEN cycle**

For each real runner failure, add the smallest contract or behavior test that reproduces the observed cause, run it RED, implement one root-cause fix, run it GREEN, then rerun the complete suite before dispatching again. Do not stack speculative fixes.

- [ ] **Step 5: Run fast-path Actions validation**

Dispatch `macOS` with:

```text
debug_level=0
wait_connections_seconds=5
```

Verify diagnostic self-test, idempotency, live sampling, screenshot capture, and artifact upload remain skipped; verify the desktop finalizer succeeds and the wait ends with `WAIT_RESULT=timeout`.

- [ ] **Step 6: Perform final main synchronization check**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

Expected: all checks pass, the tree is clean, and both hashes match.
