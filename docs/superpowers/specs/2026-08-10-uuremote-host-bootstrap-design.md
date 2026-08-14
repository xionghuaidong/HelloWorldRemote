# UU Remote macOS Host Bootstrap Design

[English](2026-08-10-uuremote-host-bootstrap-design.md) | [简体中文](2026-08-10-uuremote-host-bootstrap-design-zh_CN.md)

**Date:** 2026-08-10  
**Status:** Approved in conversation; awaiting written-spec review  
**Scope:** `.github/workflows/macos.yml` and `.github/workflows/apple.sh`

## 1. Objective

Extend the existing UU Remote macOS workflow so a newly provisioned GitHub Actions runner or remote physical Mac can be prepared before UU Remote permission automation runs.

The bootstrap must:

1. Set one caller-supplied password for the graphical user and root without enabling root login.
2. Keep the graphical user's login keychain and `/etc/kcpassword` synchronized with that password.
3. Update root's login keychain password only when a root login keychain already exists.
4. Configure Simplified Chinese as the first preferred language, English (Singapore) as the second language, and Singapore as the region, without restarting or logging out.
5. Preserve the existing UU Remote installation, permission, debugging, waiting, and artifact behavior.
6. Support both English and Simplified Chinese macOS permission interfaces.

## 2. Workflow Input and Secret Handling

Add one plaintext `workflow_dispatch` string input:

```yaml
account_password:
  description: Password for the console user, root, login keychains, and auto-login data
  required: true
  default: john.doe
  type: string
```

The input is intentionally plaintext for this temporary debugging workflow. The workflow must immediately register its value with GitHub Actions using `::add-mask::` before any operation that could echo it.

The password must be exposed only to the host-configuration step through a step-scoped environment variable named `UUREMOTE_ACCOUNT_PASSWORD`. It must not be placed in job-wide or workflow-wide environment variables and must never be printed.

## 3. Workflow Order and Script Entry Point

The workflow order is:

```text
Checkout
Configure accounts, keychains, kcpassword, languages, and region
Install UU Remote
Configure unattended access/code
Grant UU Remote permissions
Handle the private-window-picker prompt
Run the existing debug, idempotency, connection-wait, and artifact logic
```

Checkout remains first because it supplies `apple.sh`. Host configuration is the first step that mutates macOS state and must run before UU Remote installation.

`apple.sh` gains a dedicated `configure-host` mode. The normal invocation remains the UU Remote permission flow. Debug-level idempotency reruns must rerun only the permission flow; they must not repeat host configuration.

## 4. Account Discovery and Preconditions

The script must discover the graphical user from `/dev/console` and must not hardcode `runner`. It must obtain the user's home directory from Directory Services rather than from the invoking process's `$HOME`.

The configuration mode must fail safely if any of these conditions hold:

- The console UID is not a normal graphical-user UID.
- The console account cannot be resolved in Directory Services.
- `UUREMOTE_ACCOUNT_PASSWORD` is absent or empty.
- Required system tools or files cannot be accessed.

No failure path may enable root, enable SSH root login, restart macOS, or log out the console user.

## 5. Graphical User Password Transaction

The graphical user's account password, login keychain password, and `/etc/kcpassword` form one logical transaction.

### 5.1 Discovering the current state

The script first checks whether `account_password` already authenticates the graphical user. It also independently checks whether the user's login keychain already unlocks with that password and whether decoded `/etc/kcpassword` equals that password.

If the current account password is needed, the script may decode the existing `/etc/kcpassword`, but it must verify the decoded value with Directory Services before treating it as a valid old account password.

This state-first approach supports retries after a partially completed previous run.

### 5.2 Update order

Only mismatched components are changed:

1. Update the user's login keychain password when it does not already accept the new password.
2. Update the graphical user's Directory Services password when the new password does not already authenticate.
3. Replace `/etc/kcpassword` when its decoded value does not already match.

The script must verify each completed operation before proceeding.

### 5.3 Rollback

Before mutation, preserve enough in-memory state and a protected temporary copy of `/etc/kcpassword` to roll back changes made during this run.

- If the login keychain changes but the user password change fails, restore the login keychain password.
- If the user password changes but `/etc/kcpassword` replacement or verification fails, restore the user password, restore the keychain password, and restore the original `/etc/kcpassword`.
- If a later root update fails, roll back the graphical-user transaction where the original authenticated state permits it.

Temporary files must be removed on both success and failure.

## 6. `/etc/kcpassword` Encoding and Replacement

The script must encode and decode `/etc/kcpassword` using Apple's established static XOR key format, including correct block padding and termination behavior. The codec must handle punctuation and other password characters without shell interpolation or log disclosure.

Writes must use a protected temporary file followed by an atomic replacement. The final file must be owned by `root:wheel` and have mode `0600`.

After replacement, the script must decode the final file and compare it with `account_password`. A mismatch is a transaction failure and triggers rollback.

## 7. Root Password and Root Login Keychain

Root is updated after the graphical-user transaction.

The script must set root's account password to `account_password`, but it must preserve root's disabled-login state. It must not call any operation that enables the root user and must not change SSH `PermitRootLogin` or related SSH settings.

### 7.1 Existing root login keychain

If a root login keychain exists:

- If it already unlocks with `account_password`, leave it unchanged.
- If it can be unlocked with the verified previous password, change its password in place and verify the new password.
- If it cannot be unlocked, move it to a protected temporary backup and create a replacement login keychain using `account_password`.

When a replacement was required:

- On complete bootstrap success, permanently delete the old backup.
- On any later bootstrap failure, delete the replacement and restore the old keychain to its original location.

If no root login keychain exists, do not create an empty one solely for this workflow.

The root account password change must be verified while still confirming that root direct login remains disabled.

## 8. Language, Locale, and Region

Language and region are configured independently.

The desired language order is:

1. Simplified Chinese for Singapore, attempted as `zh-Hans-SG`.
2. English (Singapore), `en-SG`.

After writing the first choice, read the value back. If macOS rejects it or normalizes it to an unusable value, use `zh-Hans-CN` as the first language instead. English (Singapore) remains second.

Set the region to Singapore and the locale to `zh_SG`. Read all settings back and verify the effective language order, locale, and region. If they are already correct, do not rewrite them.

No step may restart macOS or log out the console user.

### 8.1 Restart prompts

Only after an actual language or region change, inspect System Settings and system notification dialogs for a restart prompt. Click only an exact, known negative action:

- `Not Now`
- `Later`
- `Restart Later`
- `稍后`
- `暂不`
- `以后再说`

Never click `Restart Now`, `现在重新启动`, an unlabeled default button, or any ambiguous action. If no exact safe negative action is found, report the dialog and fail without clicking it.

## 9. Bilingual UU Remote Permission Automation

The existing permission automation must continue to target only the main UU Remote application, in accordance with the official macOS help page. It must not grant separate permission to `UURemoteServer`.

The selector vocabulary must support at least:

| Purpose | English | Simplified Chinese |
|---|---|---|
| Accessibility pane | `Accessibility` | `辅助功能` |
| Screen recording pane | `Screen & System Audio Recording` | `录屏与系统录音` |
| Allow action | `Allow` | `允许` |
| Open settings action | `Open System Settings` | `打开系统设置` |

The existing accepted app labels remain valid: `UU远程`, `UURemote`, `UU Remote`, `网易UU远程`, and `网易 UU 远程`.

The private-window-picker confirmation must not depend on its full English explanatory sentence. It must identify the dialog narrowly by all of the following:

- The requester is exactly `com.netease.uuremote.agent`.
- The dialog offers the recognized bilingual Allow action.
- The dialog structure also offers the recognized bilingual Open System Settings action.

Only after all conditions match may the script click Allow. This prevents an unrelated authorization dialog from being accepted.

The permission flow may restart System Settings. Therefore the same workflow run must tolerate the interface switching from English to Chinese after language preferences are changed.

## 10. Idempotency and Recovery

Host configuration must be safe to rerun after success or interruption:

- A graphical-user password that already authenticates is not reset.
- A user login keychain that already unlocks is not changed.
- A matching `/etc/kcpassword` is not rewritten.
- A root keychain that already unlocks is not changed.
- An absent root keychain is not created.
- Root remains disabled on every run.
- Correct language, locale, and region values are not rewritten.
- Restart-prompt scanning occurs only after a real language or region change.

The existing debug-level meanings remain unchanged, including whether permission idempotency and connection keepalive diagnostics run. Host configuration itself is not tied to those debug levels.

## 11. Validation Strategy

Implementation follows test-first development.

### 11.1 Static workflow and script tests

Create failing checks first for:

- `account_password` exists, is a string, and defaults to `john.doe`.
- Host configuration runs before UU Remote installation.
- The password environment variable is scoped only to the configuration step.
- No command enables root or changes SSH root-login settings.
- `/etc/kcpassword` replacement is atomic and has the required ownership and mode.
- Root keychain fallback, restoration, and success cleanup are represented.
- English and Simplified Chinese selectors are present.
- Permission idempotency does not call `configure-host` again.

### 11.2 Codec and syntax tests

Test `/etc/kcpassword` encoding and decoding round trips for:

- The default password.
- Passwords containing spaces and shell punctuation.
- Lengths around the codec block boundary.
- Correct padding and termination.

Run Bash and YAML syntax/static validation before triggering GitHub Actions.

### 11.3 GitHub Actions integration run

Use:

```text
account_password = john.doe
debug_level = 0
wait_connections_seconds = 0
```

The run must verify, without printing the password:

- The graphical user authenticates with the configured password.
- The graphical user's login keychain unlocks with it.
- `/etc/kcpassword` decodes to it.
- Root's account password was updated while root remains disabled.
- An existing root login keychain unlocks with it.
- The effective language order and Singapore region/locale are correct.
- No restart or logout occurred.
- The UU Remote permission flow completes in the current graphical session.

## 12. Non-Goals

This change does not:

- Enable direct root login.
- Enable SSH root login.
- Install or configure SSH.
- Reboot or log out the Mac.
- Grant permissions to every application.
- Grant separate permissions to `UURemoteServer`.
- Persist the plaintext password beyond the workflow input and required macOS state.
- Change the established debug-level or connection-wait semantics.

## 13. Reference Material

- [Apple: Change Language & Region settings on Mac](https://support.apple.com/en-gb/guide/mac-help/intl163/mac)
- [Apple: How to enable the root user or change the root password on Mac](https://support.apple.com/en-au/102367)
- [Apple Developer: About the user defaults system](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html)
- [security keychain settings command reference](https://ss64.com/mac/security-keychain-settings.html)
- [Apple: If automatic login is unavailable on Mac](https://support.apple.com/en-la/102316)
- [GitHub Actions macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md)

