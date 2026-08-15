# Windows and macOS Functional Parity Design

[English](2026-08-14-windows-macos-functional-parity-design.md) | [简体中文](2026-08-14-windows-macos-functional-parity-design-zh_CN.md)

## 1. Context

The macOS workflow currently provides a mature UU Remote lifecycle: validated dispatch inputs, step-scoped secrets, host preparation, application readiness, custom-code configuration, privacy-permission automation, idempotency diagnostics, desktop finalization, screenshot artifacts, live sampling, and a shutdown-aware connection wait.

The Windows workflow currently installs and launches UU Remote, polls for a device ID, assigns a hard-coded custom code, and sleeps for a fixed interval. It does not expose the same dispatch contract, diagnostic levels, secret handling, idempotency checks, desktop finalization, or shutdown-aware wait.

This design implements the approved functional-parity option: align the externally visible workflow contract and user experience while retaining platform-specific internals.

## 2. Goals

- Give both workflows the same `debug_level` and `wait_connections_seconds` inputs.
- Give debug levels `0` through `3` the same meaning on both platforms.
- Configure the UU Remote custom code from the step-scoped `UUREMOTE_CUSTOM_CODE` repository secret on both platforms.
- Align installation, launch readiness, device-ID discovery, unattended-readiness verification, diagnostics, idempotency, desktop finalization, and wait outcomes.
- Provide a testable Windows implementation in a dedicated PowerShell helper.
- Use a native Windows shutdown watcher whose public result contract matches the macOS watcher.
- Keep platform-specific mechanisms isolated behind equivalent workflow steps.
- Fail closed when a capability cannot be verified without relying on undocumented commands or weakened operating-system controls.

## 3. Non-goals

- Do not change Windows user or Administrator passwords.
- Do not enable Windows automatic login.
- Do not make Windows consume `UUREMOTE_ACCOUNT_PASSWORD`.
- Do not reproduce macOS root, login-keychain, or `/etc/kcpassword` behavior on Windows.
- Do not weaken UAC, Windows Firewall, SSH, macOS privacy controls, or any other operating-system permission boundary.
- Do not force identical package versions, installation paths, CLI syntax, or internal implementation languages.
- Do not rewrite the mature macOS helper into a cross-platform orchestrator.
- Do not invent undocumented Windows UU Remote CLI options.

## 4. Shared workflow contract

Both `macos.yml` and `windows.yml` expose these required `workflow_dispatch` inputs:

| Input | Type | Default | Valid values |
| --- | --- | --- | --- |
| `debug_level` | choice | `0` | `0`, `1`, `2`, `3` |
| `wait_connections_seconds` | number | `300` | integers from `0` through `21000` |

Both workflows keep only these non-sensitive values at job scope:

- `UUREMOTE_DEBUG`
- `UUREMOTE_WAIT_CONNECTIONS_SECONDS`

`UUREMOTE_CUSTOM_CODE` remains step-scoped. `UUREMOTE_ACCOUNT_PASSWORD` remains step-scoped and macOS-only.

The shared semantic step order is:

1. Checkout.
2. Test the shutdown-aware wait when diagnostics are enabled.
3. Perform platform-specific host preparation.
4. Install UU Remote.
5. Launch UU Remote and wait for a non-empty device ID.
6. Configure the custom code.
7. Configure or verify platform-specific unattended-access prerequisites.
8. Repeat the configuration check for idempotency at debug levels `2` and `3`.
9. Finalize the desktop and capture the final diagnostic state when enabled.
10. Capture live samples at debug level `3`.
11. Wait for connections at debug level `0`.
12. Upload diagnostics whenever debug is non-zero, including after a failure when files exist.

Platform-specific step names may identify the host operation, but their ordering and externally visible outcomes remain equivalent.

## 5. Debug-level semantics

Debug levels are cumulative:

| Level | Behavior |
| --- | --- |
| `0` | Fast production path, no screenshots or diagnostic artifact, run the connection wait. |
| `1` | Run diagnostic self-tests and capture the finalized desktop. |
| `2` | Level 1 plus repeat configuration and verify idempotency. |
| `3` | Level 2 plus 20 state-preserving live samples at 15-second intervals. |

The artifact name is `uuremote-diagnostics` on both platforms. Each platform writes only to its runner temporary directory. Diagnostic capture must not expose secrets, device IDs, or other remote-device connection data.

## 6. Architecture

The macOS implementation remains in:

- `.github/workflows/macos.yml`
- `.github/workflows/apple.sh`
- `.github/workflows/uuremote-shutdown-wait.swift`

The Windows implementation is split into:

- `.github/workflows/windows.yml` for orchestration and step-scoped secret injection.
- `.github/workflows/windows.ps1` for validation, launch readiness, custom-code configuration, unattended-readiness checks, desktop finalization, screenshots, idempotency, and wait orchestration.
- `.github/workflows/uuremote-shutdown-wait.cs` for the native Windows message loop and shutdown signal.

This mirrors the macOS separation without forcing a shared implementation language.

## 7. Windows helper interface

`windows.ps1` exposes explicit modes suitable for direct contract tests:

- `validate-custom-code`
- `validate-wait-seconds`
- `launch-and-wait-device`
- `set-custom-code`
- `verify-unattended-readiness`
- `verify-idempotency`
- `finalize-desktop`
- `snapshot`
- `self-test-wait-connections`
- `wait-connections`

Unknown modes and invalid argument counts return exit code `2`. Validation modes do not require UU Remote to be installed. Runtime modes resolve and verify the expected installation paths before invoking binaries.

## 8. Installation and launch readiness

The Windows workflow retains the platform-specific installer and silent installation mechanism. It verifies the installer exit code and required installed files before continuing.

Launch readiness is idempotent:

- Reuse an already-running UU Remote process instead of launching a duplicate.
- Otherwise launch the verified executable with its installation directory as the working directory.
- Poll the CLI for a non-empty device ID for at most 60 seconds.
- Treat non-zero CLI results as transient only until the deadline.
- Every successful run at debug levels `0`, `1`, `2`, and `3` prints `DEVICE_ID=<complete device ID>` immediately followed by `DEVICE_ID_STATE=ready` during launch readiness. The debug-level `0` production wait also prints `WAIT_CONNECTIONS DEVICE_ID=<complete device ID>` immediately before waiting.
- After trimming, a successful device ID must be one non-empty printable line. Reject CR, LF, NUL, every other C0 control character, and DEL before logging.
- Fail closed with a generic readiness or device-ID validation error without emitting an unsafe value.
- Never print custom codes, account passwords, failed CLI attempts, raw CLI stderr, or other unapproved remote-device connection information.
- Fail after the deadline with a generic readiness error and attempt count.

## 9. Custom-code security and configuration

Both platforms require `UUREMOTE_CUSTOM_CODE` and accept it only when it matches `^[A-Za-z0-9]{8,16}$`.

The Windows workflow:

1. Injects the secret only into the custom-code step.
2. Rejects a missing secret with exit code `2`.
3. Masks the value before invoking helper logic.
4. Passes the value through the environment to `windows.ps1`.
5. Invokes the installed CLI using a variable reference rather than interpolating the value into workflow source or logs.
6. Reports only a generic success message.
7. Removes the value from the step environment as soon as practical.

No source, test, default, log, screenshot, or artifact may contain the real value.

## 10. Fail-closed unattended-readiness verification

No authoritative public Windows CLI documentation was found for an explicit `assist allow on` equivalent. The implementation therefore does not guess a command.

The automated Windows readiness gate verifies evidence available from the installed product:

- Required executables exist.
- The UU Remote process and expected supporting service or process are healthy when the installed product exposes them.
- The CLI returns a non-empty device ID.
- The documented-in-repository custom-code command completes successfully.
- Any extra unattended-access command is used only after the installed CLI itself proves support, with sanitized evidence captured during implementation or live validation.

Failure to establish this evidence stops the workflow. The implementation must not compensate by disabling UAC, opening broad firewall rules, enabling Administrator login, or changing account policy.

A real mobile-client connection during the Windows live run is a release acceptance requirement, not a substitute for automated checks.

## 11. Desktop finalization and diagnostics

Windows desktop finalization is state-preserving:

- Minimize existing UU Remote top-level windows without launching or foregrounding the application.
- Do not synthesize clicks in security dialogs.
- Verify the resulting window state when it is observable.
- Capture the desktop without changing focus.
- Store PNG files under `${RUNNER_TEMP}/uuremote-diagnostics/`.
- Use sanitized labels and deterministic filename prefixes.

At debug level `3`, each of the 20 live samples observes the already-finalized state and must not reactivate UU Remote.

macOS retains its established privacy-permission and desktop-finalization implementation, but its workflow artifact name and shared debug contract are aligned with Windows.

## 12. Shutdown-aware wait

Both platforms validate `wait_connections_seconds` as an integer from `0` through `21000` inclusive. A value of `0` returns immediately without application preflight or watcher startup.

The public result contract is:

- `WAIT_RESULT=timeout`
- `WAIT_RESULT=shutdown/restart`

The Windows watcher uses a hidden native top-level window and a message loop to observe `WM_QUERYENDSESSION`. It does not cancel shutdown. A separate injected-event argument drives deterministic self-tests without shutting down the test host.

The implementation does not rely solely on `Win32_ComputerShutdownEvent`: Microsoft documents that a local application can be terminated before that WMI event is delivered. PowerShell owns compilation or startup of the watcher, validates its exit and output, and removes temporary binaries and event resources in `finally` blocks.

## 13. Idempotency

At debug levels `2` and `3`, Windows repeats the safe configuration checks in the same runner session:

- An already-running application is reused.
- Device-ID readiness still succeeds.
- Applying the same custom code succeeds without logging it.
- Readiness evidence remains healthy.
- Desktop finalization remains a no-op when windows are already minimized.

The second pass must not install another copy, start duplicate processes, change account policy, or broaden permissions.

## 14. Error handling and cleanup

- Invalid user-controlled values or missing required secrets return exit code `2`.
- Installation, CLI, watcher, readiness, screenshot, or desktop-finalization failures return exit code `1`.
- No retry loop is unbounded.
- A failed configuration step prevents the production wait from starting.
- Event subscriptions, watcher processes, temporary compiled files, and screenshot resources are cleaned in `finally` blocks.
- Debug artifact upload uses `if: always()` together with a non-zero debug gate and tolerates only the explicitly configured missing-file behavior.
- Error messages identify the failed stage and sanitized exit status, never secret values.

## 15. Automated testing

Add `tests/test_windows_parity.py` with tests that read real repository files and, on Windows, invoke validation and self-test modes directly.

The suite covers:

- Matching workflow inputs, defaults, debug meanings, and wait bounds.
- Shared semantic step ordering and conditions.
- Step-scoped custom-code secret handling and absence of hard-coded values.
- Windows helper mode dispatch and validation exit codes.
- Bounded application and device-ID readiness.
- The exact launch/readiness pair at every debug level and production-wait device-ID message, without raw failed CLI output.
- Empty, multiline, NUL, C0-control, DEL, and failed-CLI device-ID cases that fail closed without raw unsafe output.
- State-preserving desktop finalization and diagnostic paths.
- Wait timeout, zero, invalid input, injected ordinary event, and injected shutdown event.
- Six-commit documentation rules and existing agent-environment contracts remain unaffected.

Existing macOS contract tests continue to run. Bash and AppKit behavior tests remain platform-gated where required; they must not be reported as passing on an incompatible Windows host.

All behavior changes follow red-green-refactor: add the focused failing contract first, observe the expected failure, implement the minimum behavior, then refactor while green.

## 16. Live validation matrix

After local and review gates pass, validate the Windows workflow using repository secrets without displaying their values:

1. `debug_level=1`, `wait_connections_seconds=0`: verify `DEVICE_ID=<complete device ID>` immediately followed by `DEVICE_ID_STATE=ready`, custom-code configuration, final screenshot, artifact upload, and a real mobile-client connection.
2. `debug_level=2`, `wait_connections_seconds=0`: verify `DEVICE_ID=<complete device ID>` immediately followed by `DEVICE_ID_STATE=ready` and that the second configuration pass is idempotent.
3. `debug_level=3`, `wait_connections_seconds=0`: verify `DEVICE_ID=<complete device ID>` immediately followed by `DEVICE_ID_STATE=ready` and 20 state-preserving live samples.
4. `debug_level=0`, `wait_connections_seconds=5`: verify `DEVICE_ID=<complete device ID>` immediately followed by `DEVICE_ID_STATE=ready`, no artifact, `WAIT_CONNECTIONS DEVICE_ID=<complete device ID>` immediately before waiting, and a timeout result.
5. A dedicated remote shutdown or restart run: verify the shutdown-aware path when the host remains alive long enough to report it.

Any live failure enters systematic debugging using sanitized logs and diagnostics. It does not authorize weakening operating-system protections.

## 17. Documentation and rollout

Update both README languages to describe the now-aligned public contract and platform-specific exceptions. Add bilingual implementation-plan documents. Update existing tests and historical facts only where the runtime contract actually changes; do not rewrite historical records to imply that Windows parity existed earlier.

Implementation occurs in an isolated worktree on a feature branch. Each plan task receives focused tests and code review. Final completion requires applicable local tests, clean structural documentation checks, revision-scoped `git diff --check`, a full branch review, and the live validation matrix or an explicit record of any external validation still awaiting authorization.

## 18. Acceptance criteria

The work is complete when:

- Both workflows expose the approved inputs and debug semantics.
- Both workflows use `UUREMOTE_CUSTOM_CODE` securely and no hard-coded custom code remains in active runtime configuration.
- Windows runtime behavior is implemented in the dedicated helper and native watcher.
- Windows performs bounded readiness checks, state-preserving diagnostics, idempotency verification, and the shared wait contract.
- Windows does not consume the account-password secret or alter user, Administrator, autologin, UAC, firewall, or SSH policy.
- Automated tests pass on applicable hosts and platform-only limitations are stated accurately.
- The Windows live acceptance run establishes real remote connectivity and the approved diagnostic behavior.
- English and Simplified Chinese documentation remain meaning-equivalent and structurally valid.
