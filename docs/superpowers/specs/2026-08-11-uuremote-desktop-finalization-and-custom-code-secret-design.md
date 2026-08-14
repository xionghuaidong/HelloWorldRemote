# UU Remote Desktop Finalization and Custom Code Secret Design

[English](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design.md) | [简体中文](2026-08-11-uuremote-desktop-finalization-and-custom-code-secret-design-zh_CN.md)

## Goal

Leave the active macOS graphical session ready for immediate UU Remote control
without restarting or logging out. All permission dialogs and System Settings
windows must be closed, UU Remote must remain running with its ordinary windows
minimized, Finder and the menu-bar clock must use Simplified Chinese with the
Singapore region, Terminal windows must close when their shells exit, and the
keyboard repeat controls must use their fastest values available in System
Settings.

Replace the hard-coded UU Remote custom code with a required, validated GitHub
Actions repository secret.

## Global Constraints

- Do not restart macOS.
- Do not log out the active graphical user.
- Do not terminate the UU Remote background service needed for unattended
  control.
- Continue to support English and Simplified Chinese macOS interfaces.
- Preserve the existing debug-level meanings and permission idempotency.
- Use accessibility structure and exact localized button titles for security
  prompts; do not use screen coordinates or blind Return-key submission.
- Keep direct root login disabled and do not change the existing account-secret
  behavior.

## Final Desktop Contract

After `apple.sh` completes successfully and before `Wait connections` begins:

1. the private-window-picker prompt whose requester is
   `com.netease.uuremote.agent` has had its exact `Allow` or `允许` action
   pressed and is no longer visible;
2. any screen-recording restart prompt stating that UU Remote cannot record
   until it quits has had its exact `Quit & Reopen`, `Quit and Reopen`, or
   `退出并重新打开` action pressed and is no longer visible;
3. UU Remote is running, unattended control is enabled, and every ordinary UU
   Remote window is minimized;
4. System Settings has no visible windows and the Screen & System Audio
   Recording page is closed;
5. Finder menus are Simplified Chinese rather than `File`, `Edit`, `View`,
   `Go`, `Window`, and `Help`;
6. the menu-bar clock contains no English weekday or month name and reflects
   the Singapore Simplified Chinese locale;
7. every existing Terminal `Window Settings` profile has
   `shellExitAction=0`, so Ctrl+D or another clean shell exit closes its window;
8. `NSGlobalDomain KeyRepeat` is `2` and `InitialKeyRepeat` is `15`, matching
   the fastest repeat rate and shortest delay exposed by System Settings.

## Architecture

The existing host and permission script will gain three bounded units.

### Desktop Preference Configuration

`configure_desktop_preferences` runs as part of `configure-host`, after the
language and region values have been selected. It will:

- keep the existing preferred-language order of `zh-Hans-SG`, then `en-SG`,
  with the existing `zh-Hans-CN` fallback;
- keep `AppleLocale=zh_SG` and the Singapore metric settings;
- set `KeyRepeat=2` and `InitialKeyRepeat=15` in the graphical user's global
  preferences;
- update every dictionary below `Window Settings` in the graphical user's
  `com.apple.Terminal.plist` so `shellExitAction` is integer `0`;
- verify the persisted plist and global-preference values before continuing;
- reload only the graphical user's preference cache, Finder, and SystemUIServer
  so the new localization is visible without a machine restart or user logout;
- wait for Finder and SystemUIServer to return, then verify the visible Finder
  menu vocabulary and menu-bar clock vocabulary through the accessibility tree.

The routine must discover the console user and home directory through the
existing account-resolution functions. It must not assume the user is named
`runner`.

### Permission Transaction

`ensure_uuremote_permissions` retains the existing Accessibility and Screen &
System Audio Recording row checks. An already-enabled row is not toggled.

When a screen-recording change produces a restart prompt, the script will match
the dialog by its UU Remote recording text and press only a recognized localized
restart action. It will then wait for the dialog to disappear, UU Remote to
return, its CLI to recover, and the permission row to remain enabled.

The existing unconditional Return-key submission after adding an application
will be removed. Authentication and file-picker submissions may still use their
specific verified controls, but no generic keystroke may accept a permission or
restart dialog.

After permissions have persisted, the script will trigger or observe the
private-window-picker request, match it by the exact requester bundle identifier,
press only `Allow` or `允许`, and wait until the matching UserNotificationCenter
window disappears.

### Desktop Normalization

`normalize_remote_desktop` is the final UI operation. It will:

- rescan for both known dialogs and fail if either is present with an unknown
  action structure;
- minimize all ordinary UU Remote windows through `AXMinimized`, while leaving
  the application and its background services running;
- quit System Settings and wait until it has no visible windows;
- verify that UU Remote remains available through its CLI;
- verify that no matching permission dialog remains;
- verify the minimized UU Remote state, closed System Settings state, localized
  Finder and clock, Terminal profile values, and keyboard values.

Normal success and error paths both attempt safe desktop normalization. On an
error with debug enabled, diagnostic evidence is captured before cleanup.
Cleanup never clicks an ambiguous security action.

## Debug-Level Behavior

- Level `0`: use condition-based polling and only short necessary waits; do not
  create screenshots or upload artifacts.
- Level `1`: use longer diagnostic allowances and capture each important prompt
  before and after its action plus the final clean desktop.
- Level `2`: repeat permission configuration to prove idempotency; the second
  execution must end in the same final desktop state.
- Level `3`: retain the existing live sampler, but snapshots must not reopen,
  unminimize, or foreground UU Remote and must not reopen System Settings.

The existing `capture_snapshot` special handling for `live-*` and `final-app*`
must therefore stop opening UU Remote. Final evidence represents the real state
seen by a newly connected remote client.

## Custom Code Secret

Remove the hard-coded `xxxxxx` value. The workflow will require this
repository Actions secret:

```text
UUREMOTE_CUSTOM_CODE
```

The secret is valid only when it matches:

```regex
^[A-Za-z0-9]{8,16}$
```

It therefore contains only uppercase ASCII letters, lowercase ASCII letters,
and digits, with an inclusive length of 8 through 16 characters.

The workflow will expose the value only to the step that calls the UU Remote
CLI. That step will:

- reject a missing, empty, too-short, too-long, or non-alphanumeric value before
  calling the CLI;
- register the value with the GitHub Actions log masker;
- pass it to `uuyc-cli assist set-code` without printing the command or value;
- report only a generic success message rather than echoing the secret or a CLI
  response that might contain it;
- unset the environment variable immediately after use.

The value must not be a workflow-dispatch input, job-level environment variable,
checked-in default, or diagnostic field.

## Failure Behavior

- Missing or invalid `UUREMOTE_CUSTOM_CODE`: fail before invoking
  `uuyc-cli assist set-code`.
- A target prompt is detected without its exact expected action: capture
  diagnostics when enabled and fail without clicking.
- A recognized action is pressed but its dialog remains visible: fail.
- UU Remote does not return after `Quit & Reopen`: fail.
- A permission does not persist after reopening System Settings: fail.
- Finder or SystemUIServer does not return after its targeted reload: fail.
- Finder menus or the menu-bar clock remain English: fail.
- Terminal or keyboard preference read-back differs from the contract: fail.
- UU Remote cannot be minimized or its CLI is unavailable during final
  verification: fail.
- System Settings retains a visible window after cleanup: fail.

No failure path restarts or logs out the machine.

## Testing

Python contract tests will verify that:

- `xxxxxx` is absent from the workflow and scripts;
- `UUREMOTE_CUSTOM_CODE` is a step-scoped required secret and is masked;
- the exact validation expression accepts only 8-16 ASCII alphanumeric
  characters;
- no permission flow contains the old unconditional post-add Return action;
- the three new bounded units exist and execute in the required order;
- all Terminal profiles are targeted rather than one hard-coded profile;
- the requested keyboard values are exactly `2` and `15`;
- Finder and SystemUIServer are reloaded without restart or logout commands;
- final and live snapshots do not open or foreground UU Remote;
- desktop normalization follows private-picker handling and precedes the
  workflow connection wait.

macOS Actions verification will run in two modes:

1. `debug=1`, `wait=0`: inspect detailed logs and screenshot artifacts for both
   prompt transitions and the final clean desktop;
2. `debug=0` with a short or user-selected wait: prove the fast path, connect a
   real remote client when required, and verify that diagnostics and artifacts
   remain disabled.

The macOS run must read back all persisted preferences and inspect the UI
accessibility tree for the final desktop contract. The complete Python test
suite, Bash syntax check, `git diff --check`, clean worktree check, and matching
local/remote `main` commit hashes are required before completion.

## Rollout

Before running the updated workflow, configure both repository Actions secrets:

```text
UUREMOTE_ACCOUNT_PASSWORD
UUREMOTE_CUSTOM_CODE
```

The first diagnostic run will use the disposable GitHub-hosted macOS runner.
After the artifact and accessibility assertions pass, the fast path can be used
on the remote physical Mac without restarting or logging out that machine.
