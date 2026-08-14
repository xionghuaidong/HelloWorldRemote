# UU Remote macOS Host Bootstrap Implementation Plan

[English](2026-08-10-uuremote-host-bootstrap.md) | [简体中文](2026-08-10-uuremote-host-bootstrap-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare the active macOS graphical account, root password state, login keychains, automatic-login password, Singapore language/region preferences, and bilingual UU Remote permissions from one idempotent workflow input.

**Architecture:** Add an early `configure-host` mode to the existing `apple.sh`, before any UU Remote application preflight. That mode runs an explicit account transaction, root-keychain transaction, and locale transaction; the existing default mode remains responsible for UU Remote and receives bilingual selectors. `macos.yml` supplies the password only to the bootstrap step and retains the existing diagnostic and connection-wait behavior.

**Tech Stack:** Bash 3.2, AppleScript/System Events, macOS Directory Services (`dscl`), Keychain CLI (`security`), `defaults`, Python 3 standard library, GitHub Actions YAML, Python `unittest`.

## Global Constraints

- Add exactly one plaintext `workflow_dispatch` string input named `account_password`, required, default `john.doe`.
- Mask the input immediately with GitHub `::add-mask::`; never print the password.
- Scope `UUREMOTE_ACCOUNT_PASSWORD` only to the host-configuration step.
- Detect the graphical account from `/dev/console`; never hardcode `runner` or derive its home from `$HOME`.
- Use `zh-Hans-SG` first when macOS accepts it, otherwise `zh-Hans-CN`; use `en-SG` second, locale `zh_SG`, and region Singapore.
- Never restart or log out macOS. Click only exact recognized negative restart actions.
- Change root's password but never enable root and never change SSH root-login configuration.
- Do not create a root login keychain when none exists.
- Delete an unusable old root-keychain backup only after complete success; restore it on failure.
- Replace `/etc/kcpassword` atomically as `root:wheel` mode `0600` and verify it by decoding.
- Grant permissions only to the main UU Remote application; never restore `UURemoteServer` permissions.
- Preserve debug levels `0`–`3`, wait range `0`–`21000`, and their current semantics.
- Do not modify `.github/workflows/a.sh` or unrelated files.

## File Structure

- Modify: `.github/workflows/macos.yml` — workflow input, ordered bootstrap step, and integration verification.
- Modify: `.github/workflows/apple.sh` — routing, codec, account/keychain transaction, locale transaction, and bilingual permission UI.
- Create: `tests/test_uuremote_host_bootstrap.py` — static contracts plus the side-effect-free codec self-test launcher.

---

### Task 1: Lock the Workflow Contract

**Files:**
- Create: `tests/test_uuremote_host_bootstrap.py`
- Modify: `.github/workflows/macos.yml:3-44`

**Interfaces:**
- Consumes: Existing `Checkout` and `Install GameViewer` steps.
- Produces: `inputs.account_password`; step-scoped `UUREMOTE_ACCOUNT_PASSWORD`; call to `apple.sh configure-host`.

- [ ] **Step 1: Write the failing workflow tests**

Create a standard-library `unittest` file with `ROOT`, `WORKFLOW_PATH`, `SCRIPT_PATH`, a UTF-8 `text(path)` reader, and a `step_block(workflow, name)` helper. Add assertions that:

```python
self.assertRegex(workflow, r"(?ms)^      account_password:.*?^        required: true$.*?^        default: [\"']?john\.doe[\"']?$.*?^        type: string$")
self.assertLess(workflow.index("- name: Configure macOS host"), workflow.index("- name: Install GameViewer"))
self.assertNotRegex(workflow, r"(?ms)^    env:.*UUREMOTE_ACCOUNT_PASSWORD")
self.assertIn("UUREMOTE_ACCOUNT_PASSWORD: ${{ inputs.account_password }}", configure_step)
self.assertIn("::add-mask::", configure_step)
self.assertIn(".github/workflows/apple.sh configure-host", configure_step)
self.assertNotIn("configure-host", idempotency_step)
```

- [ ] **Step 2: Run the test and observe the expected failure**

Run `python3 -m unittest tests/test_uuremote_host_bootstrap.py -v`.

Expected: input and configuration-step assertions fail; the idempotency assertion passes.

- [ ] **Step 3: Add the input and bootstrap step**

Add after `wait_connections_seconds`:

```yaml
      account_password:
        description: Password for the console user, root, login keychains, and auto-login data
        required: true
        default: john.doe
        type: string
```

Add immediately after Checkout:

```yaml
      - name: Configure macOS host
        shell: bash
        env:
          UUREMOTE_ACCOUNT_PASSWORD: ${{ inputs.account_password }}
        run: |
            echo "::add-mask::${UUREMOTE_ACCOUNT_PASSWORD}"
            .github/workflows/apple.sh configure-host
```

- [ ] **Step 4: Verify and commit**

Run `python3 -m unittest tests/test_uuremote_host_bootstrap.py -v` and `git diff --check`; both must pass. Then:

```bash
git add tests/test_uuremote_host_bootstrap.py .github/workflows/macos.yml
git commit -m "test: define macOS host bootstrap contract"
```

---

### Task 2: Add Early Routing and a Tested kcpassword Codec

**Files:**
- Modify: `.github/workflows/apple.sh:4-37,235-247,303-317`
- Modify: `tests/test_uuremote_host_bootstrap.py`

**Interfaces:**
- Consumes: First positional mode argument.
- Produces: `encode_kcpassword OUTPUT_PATH` reading stdin; `decode_kcpassword INPUT_PATH` writing stdout; `self-test-kcpassword` mode.

- [ ] **Step 1: Add failing tests**

Assert that `if [ "$mode" = "configure-host" ]` appears before `if [ ! -d "$APP" ]`. Launch `/bin/bash apple.sh self-test-kcpassword` with `subprocess.run`; require exit 0 and `kcpassword codec self-test passed`.

- [ ] **Step 2: Run and observe failure**

Run the focused test class. Expected: early routing is absent and self-test encounters existing macOS/UURemote preflight or usage failure.

- [ ] **Step 3: Implement the codec before macOS preflight**

Use Python 3 with the static XOR key `7d 89 52 23 d2 bc dd ea a3 b9 1f`. `encode_kcpassword` reads bytes from stdin, appends at least one NUL, pads to a 12-byte boundary, XORs, and writes the requested file. `decode_kcpassword` reads the file, XORs it, and emits bytes before the first NUL. Password bytes must never be command-line arguments or logs.

The self-test uses a mode-0700 temporary directory and round-trips these values without printing them:

```text
john.doe
space and $hell!
12345678901
123456789012
1234567890123
密码-SG
```

Dispatch `self-test-kcpassword` and `configure-host` before reading `/dev/console`, checking `$APP`, or calling macOS-only UI commands. Until Tasks 3–5 finish, `configure_host` must fail explicitly with `Host bootstrap implementation is incomplete`.

- [ ] **Step 4: Reuse the decoder in permission mode**

Replace the existing inline Python decoder with:

```bash
runner_password="$(sudo decode_kcpassword /etc/kcpassword)"
```

Retain the existing nonempty and `dscl -authonly` checks.

- [ ] **Step 5: Verify and commit**

Run `/bin/bash -n .github/workflows/apple.sh`, the focused tests, and `git diff --check`. Then:

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: add kcpassword codec and bootstrap routing"
```

---

### Task 3: Implement the Graphical-User Transaction

**Files:**
- Modify: `.github/workflows/apple.sh:4-345`
- Modify: `tests/test_uuremote_host_bootstrap.py`

**Interfaces:**
- Consumes: `UUREMOTE_ACCOUNT_PASSWORD` only inside `configure_host`.
- Produces: `resolve_console_account`, `password_authenticates`, `keychain_unlocks`, `configure_console_user`, `write_kcpassword_atomically`, `restore_original_kcpassword`, and `rollback_console_user_transaction`.

- [ ] **Step 1: Add failing transaction tests**

Add assertions for all produced function names and these exact safety markers:

```python
self.assertIn("stat -f '%Su' /dev/console", script)
self.assertIn("NFSHomeDirectory", script)
self.assertNotIn('console_user="runner"', configure_host_body)
self.assertNotIn('console_home="$HOME"', configure_host_body)
self.assertIn('chown root:wheel "$kcpassword_temp"', script)
self.assertIn('chmod 0600 "$kcpassword_temp"', script)
self.assertIn('mv -f "$kcpassword_temp" /etc/kcpassword', script)
self.assertIn('decode_kcpassword /etc/kcpassword', script)
```

- [ ] **Step 2: Run and observe failure**

Run the focused transaction test class. Expected: home lookup, transaction helpers, rollback, and atomic replacement assertions fail.

- [ ] **Step 3: Implement graphical-account discovery and probes**

`resolve_console_account` sets global `console_uid`, `console_user`, and `console_home`. Reject UID below 501 and accounts `root`, `loginwindow`, `_mbsetupuser`. Read the home using:

```bash
console_home="$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory |
    /usr/bin/sed 's/^NFSHomeDirectory: //')"
```

Implement probes that discard output:

```bash
password_authenticates() {
    /usr/bin/dscl . -authonly "$1" "$2" >/dev/null 2>&1
}

keychain_unlocks() {
    /usr/bin/security unlock-keychain -p "$2" "$1" >/dev/null 2>&1
}
```

Prefer `$console_home/Library/Keychains/login.keychain-db`, then `login.keychain`; fail before mutation when neither exists.

- [ ] **Step 4: Capture rollback state and implement atomic kcpassword replacement**

Create `/tmp/uuremote-bootstrap.XXXXXX` with mode `0700`. Copy an existing `/etc/kcpassword` into it as root and record whether the original existed.

The writer order is exact:

```bash
kcpassword_temp="$bootstrap_temp_dir/kcpassword.new"
printf '%s' "$account_password" | encode_kcpassword "$kcpassword_temp"
sudo /usr/sbin/chown root:wheel "$kcpassword_temp"
sudo /bin/chmod 0600 "$kcpassword_temp"
sudo /bin/mv -f "$kcpassword_temp" /etc/kcpassword
decoded_password="$(sudo decode_kcpassword /etc/kcpassword)"
[ "$decoded_password" = "$account_password" ] || return 1
unset decoded_password
```

`restore_original_kcpassword` restores the saved copy atomically when one existed; otherwise it removes the newly created final file.

- [ ] **Step 5: Implement mutation, verification, and reverse rollback**

Decode the original kcpassword and accept it as `old_account_password` only after `dscl -authonly` verifies it. Probe the desired password independently against the account, keychain, and kcpassword, then skip already-correct components.

For mismatched components, mutate in this order:

```bash
/usr/bin/security set-keychain-password \
  -o "$old_account_password" -p "$account_password" "$user_login_keychain"
sudo /usr/bin/dscl . -passwd "/Users/$console_user" \
  "$old_account_password" "$account_password"
write_kcpassword_atomically
```

Verify each mutation before continuing. Track `user_keychain_changed`, `user_password_changed`, and `kcpassword_changed`. Roll back in reverse order: kcpassword, Directory Services password, then login keychain password. Continue all rollback attempts after one fails, and return nonzero if any restoration fails.

- [ ] **Step 6: Verify and commit**

Run Bash syntax, focused transaction tests, codec tests, and `git diff --check`. Then:

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: configure macOS console account atomically"
```

---

### Task 4: Update Disabled Root and Its Existing Keychain

**Files:**
- Modify: `.github/workflows/apple.sh:4-430`
- Modify: `tests/test_uuremote_host_bootstrap.py`

**Interfaces:**
- Consumes: `account_password`, verified previous password if available, and the bootstrap rollback directory.
- Produces: `root_is_disabled`, `verify_root_password_hash`, `find_root_login_keychain`, `configure_root`, `rollback_root_keychain`, and `commit_root_keychain_backup`.

- [ ] **Step 1: Add failing root-safety tests**

Require every produced function name, `SALTED-SHA512-PBKDF2`, and `hashlib.pbkdf2_hmac`. Forbid all of:

```python
for token in ("dsenableroot", "PermitRootLogin", "sshd_config"):
    self.assertNotIn(token, script)
```

Also require the exact absent-keychain status `No root login keychain exists; leaving it absent` and transaction markers `root_keychain_backup`, `rollback_root_keychain`, and `commit_root_keychain_backup`.

- [ ] **Step 2: Run and observe failure**

Run the root-safety test class. Expected: state/hash/keychain helper assertions fail; forbidden-operation assertions pass.

- [ ] **Step 3: Implement disabled-state and root-password verification**

`root_is_disabled` reads `/Users/root` `AuthenticationAuthority` and requires the Open Directory `DisabledUser` authority. Require it both before and after:

```bash
sudo /usr/bin/dscl . -passwd /Users/root "$account_password"
```

Never call `dsenableroot` and never alter SSH configuration.

Because disabled root cannot be verified with an ordinary login, `verify_root_password_hash` reads root's `ShadowHashData` plist as root, extracts `SALTED-SHA512-PBKDF2`, and passes the candidate password through stdin to Python. Verify with:

```python
derived = hashlib.pbkdf2_hmac(
    "sha512",
    password_bytes,
    hash_data["salt"],
    int(hash_data["iterations"]),
    dklen=len(hash_data["entropy"]),
)
if not hmac.compare_digest(derived, hash_data["entropy"]):
    raise SystemExit(1)
```

Never log the password, salt, entropy, or derived key.

- [ ] **Step 4: Implement the optional root-keychain transaction**

Search in order:

```text
/var/root/Library/Keychains/login.keychain-db
/var/root/Library/Keychains/login.keychain
```

If absent, log the exact absent message and do not create one. If present, skip when it unlocks with the new password. Otherwise update in place when it unlocks with the verified old password. If neither password unlocks it, move it to a protected transaction backup, create a replacement at the exact original path, set root ownership, and verify it with the new password.

`rollback_root_keychain` deletes the replacement and restores the backup. `commit_root_keychain_backup` permanently deletes the backup only after every bootstrap phase succeeds.

- [ ] **Step 5: Connect root failures to the outer rollback**

After graphical-user success, call `configure_root`. On failure, call `rollback_root_keychain` and `rollback_console_user_transaction` in reverse order. Install an EXIT trap for unexpected failure; transaction flags prevent double rollback.

- [ ] **Step 6: Verify and commit**

Run Bash syntax, all root/transaction/codec tests, and `git diff --check`. Then:

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: update disabled root and existing keychain"
```

---

### Task 5: Configure Singapore Languages and Decline Restart Safely

**Files:**
- Modify: `.github/workflows/apple.sh:4-530`
- Modify: `tests/test_uuremote_host_bootstrap.py`

**Interfaces:**
- Consumes: `console_uid`, `console_user`, `console_home`, and `run_in_gui`.
- Produces: `language_settings_match`, `configure_language_and_region`, and `dismiss_safe_restart_prompt`.

- [ ] **Step 1: Add failing locale-safety tests**

Require `zh-Hans-SG`, `zh-Hans-CN`, `en-SG`, `zh_SG`, and `SG`. Require the safe labels `Not Now`, `Later`, `Restart Later`, `稍后`, `暂不`, and `以后再说`. Assert that `Restart Now` and `现在重新启动` are not members of a list passed to any button-press helper. Require prompt dismissal to be nested under this exact guard:

```bash
if [ "$language_or_region_changed" = "1" ]; then
    dismiss_safe_restart_prompt
fi
```

- [ ] **Step 2: Run and observe failure**

Run the locale test class. Expected: language, fallback, prompt-vocabulary, and conditional-scan assertions fail.

- [ ] **Step 3: Implement read-before-write preferences**

Use `run_in_gui defaults` so values belong to the console user. Read `AppleLanguages`, `AppleLocale`, metric units, and region before writing. If already correct, log a skip and leave `language_or_region_changed=0`.

First write `AppleLanguages` as the array `zh-Hans-SG`, `en-SG`; write `AppleLocale=zh_SG`, `AppleMeasurementUnits=Centimeters`, and `AppleMetricUnits=true`. Read the language array back. Keep `zh-Hans-SG` only when it is the effective first value; otherwise rewrite only the language array as `zh-Hans-CN`, `en-SG`. Verify exact order, locale, metric settings, and Singapore region semantics.

- [ ] **Step 4: Implement narrow restart-prompt handling**

Inspect both `System Settings` and `UserNotificationCenter`. Confirm surrounding text represents a restart or re-login prompt in English or Simplified Chinese. Press only an exact member of:

```applescript
{"Not Now", "Later", "Restart Later", "稍后", "暂不", "以后再说"}
```

If a restart-related dialog is visible without an exact safe negative action, fail without clicking. If no relevant dialog appears during the bounded wait, return success. Call this handler only after a real preference change.

- [ ] **Step 5: Complete configure-host orchestration**

Replace the temporary failure body with the following call order: validate nonempty `UUREMOTE_ACCOUNT_PASSWORD`; resolve the console account; begin transaction; configure console user; configure root; configure language and region; commit the root-keychain backup; finish transaction; unset password variables.

Locale or prompt failure triggers root-keychain rollback, then graphical-user rollback. Complete success removes the transaction directory, clears the EXIT trap, and prints only non-secret status.

- [ ] **Step 6: Verify and commit**

Run Bash syntax, the entire Python suite, codec self-test, and `git diff --check`. Then:

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: configure Singapore language and region"
```

---

### Task 6: Support English and Simplified Chinese Permission UI

**Files:**
- Modify: `.github/workflows/apple.sh:151-233,346-1267`
- Modify: `tests/test_uuremote_host_bootstrap.py`

**Interfaces:**
- Consumes: Existing `run_permission` kinds and accepted UU Remote display names.
- Produces: Bilingual title lists and structural matching for requester `com.netease.uuremote.agent`.

- [ ] **Step 1: Add failing bilingual tests**

Require the pairs `Accessibility`/`辅助功能`, `Screen & System Audio Recording`/`录屏与系统录音`, `Allow`/`允许`, and `Open System Settings`/`打开系统设置`.

Require `allowButton`, `openSettingsButton`, and `com.netease.uuremote.agent`; forbid the old `contextText contains "private window picker"` dependency. Extract all `run_permission` calls and require exactly `accessibility-main`, `screen-capture`, and `agent-private-picker`.

- [ ] **Step 2: Run and observe failure**

Run the bilingual-permission test class. Expected: Chinese vocabulary and structural picker checks fail while the full-English phrase is still present.

- [ ] **Step 3: Convert permission titles to accepted exact lists**

Change `ensurePermission` to receive `permissionWindowTitles` and accept a page only when its AX title exactly matches one value. Pass these lists:

```applescript
{"Accessibility", "辅助功能"}
{"Screen & System Audio Recording", "录屏与系统录音"}
```

Extend exact localized values for Password, Open, and Quit & Reopen only where the current algorithm already validates AX role and layout. Localization must not broaden control selection.

- [ ] **Step 4: Narrow and bilingualize both private-picker handlers**

In the snapshot-time handler and embedded permission AppleScript:

1. Require exact requester text `com.netease.uuremote.agent` in the dialog context.
2. Capture `allowButton` only for exact title or description `Allow` or `允许`.
3. Capture `openSettingsButton` only for exact title or description `Open System Settings` or `打开系统设置`.
4. Match only when both buttons exist.
5. Press only `allowButton`.
6. Remove the full English explanatory-phrase dependency.

If the requester matches but either structural action is absent, emit diagnostics and fail without clicking.

- [ ] **Step 5: Verify and commit**

Run Bash syntax, all Python tests, codec self-test, and `git diff --check`. Then:

```bash
git add .github/workflows/apple.sh tests/test_uuremote_host_bootstrap.py
git commit -m "feat: support bilingual UU Remote permissions"
```

---

### Task 7: Run macOS Integration and Rerun Verification

**Files:**
- Modify: `.github/workflows/macos.yml` only for evidence-backed integration corrections.
- Modify: `.github/workflows/apple.sh` only for evidence-backed integration corrections.
- Test: GitHub Actions workflow `macOS`.

**Interfaces:**
- Consumes: `account_password=john.doe`, `debug_level=0`, `wait_connections_seconds=0`.
- Produces: A successful Actions run proving bootstrap, permissions, and client control without reboot or logout.

- [ ] **Step 1: Run the complete preflight**

Run these commands individually: `git status --short`, `/bin/bash -n .github/workflows/apple.sh`, `python3 -m unittest tests/test_uuremote_host_bootstrap.py -v`, and `git diff --check`.

Expected: only intended files are changed and every check passes.

- [ ] **Step 2: Push and dispatch the workflow**

Dispatch `macOS` with `account_password=john.doe`, `debug_level=0`, and `wait_connections_seconds=0`. Use the signed-in GitHub form or a masked API mechanism; do not place the password in an echoed command.

- [ ] **Step 3: Require non-secret bootstrap evidence**

The log must confirm all of:

```text
console account password verified
console login keychain verified
/etc/kcpassword verified
root password hash verified
root remains disabled
language order verified
Singapore locale and region verified
```

It must additionally report either `root login keychain verified` or `No root login keychain exists; leaving it absent`. Confirm the GUI session survives and no restart or logout occurs.

- [ ] **Step 4: Verify UU Remote behavior**

Confirm unattended access succeeds, Accessibility and Screen & System Audio Recording persist, the private-picker prompt is accepted only for `com.netease.uuremote.agent`, and the mobile client can view and control the runner.

- [ ] **Step 5: Verify host idempotency**

On a retained target, mask the value and run `apple.sh configure-host` again. On an ephemeral runner, add a temporary second invocation in the same diagnostic run and remove it after evidence is captured. Require skip results for user password, user keychain, kcpassword, root keychain, languages, locale, and region; root must stay disabled and prompt scanning must be skipped.

- [ ] **Step 6: Apply only evidence-backed fixes**

For every runtime failure, preserve the exact non-secret diagnostic and state, add a failing regression assertion first, implement the smallest correction, rerun the complete preflight, and dispatch again.

- [ ] **Step 7: Commit final corrections if needed**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_uuremote_host_bootstrap.py
git commit -m "fix: validate macOS host bootstrap integration"
git push origin main
```

Skip this commit if no final correction exists. Never create an empty commit.

- [ ] **Step 8: Record final evidence**

Report the final commit hash, successful Actions run URL, non-secret input values, test results, root-disabled confirmation, effective first language (`zh-Hans-SG` or fallback `zh-Hans-CN`), and whether the root keychain was updated or correctly left absent.
