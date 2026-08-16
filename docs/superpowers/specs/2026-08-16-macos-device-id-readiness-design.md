# macOS Device ID Readiness Alignment Design

[English](2026-08-16-macos-device-id-readiness-design.md) | [简体中文](2026-08-16-macos-device-id-readiness-design-zh_CN.md)

## 1. Context

The Windows workflow delegates UU Remote launch and device-ID readiness to one helper route, `launch-and-wait-device`. That helper starts GameViewer only when it is absent, owns one 60-second deadline, bounds every CLI attempt by the remaining deadline, polls at 500-millisecond intervals, and fails closed if no validated device ID becomes available.

The macOS workflow currently owns a separate 120-attempt polling loop in YAML and launches the long-running UU Remote application through `gtimeout 60s`. The application can therefore be terminated when the timeout expires even though later workflow stages still require it. The YAML loop also splits deadline, process, diagnostic, and output responsibilities between the workflow and `apple.sh`.

Live macOS runs proved that the device-ID parser and diagnostic tests pass, but the production launch stage can exhaust all readiness attempts without obtaining an ID. This design aligns macOS with the established Windows ownership and lifetime model without speculatively adding restart behavior or changing the public device-ID log contract.

## 2. Goals

- Make `apple.sh` the single owner of macOS UU Remote launch and device-ID readiness.
- Use one 60-second overall readiness deadline and a 500-millisecond polling interval, matching Windows.
- Keep every `assist id` subprocess within the remaining overall budget and deterministically terminate and reap a hung child.
- Launch UU Remote only when it is absent, and do not automatically restart an existing process.
- Keep the long-running UU Remote application alive beyond the readiness deadline.
- Preserve the approved device-ID, wait-result, secret-handling, and diagnostic log contracts.
- Add executable regressions for process lifetime, deadline behavior, output validation, cleanup, and non-leakage.
- Validate the change first on a feature branch and then on `main` with a real macOS workflow run.

## 3. Non-goals

- Do not modify the stable Windows implementation.
- Do not introduce automatic restart, relaunch, or recovery loops.
- Do not change the accepted device-ID formats or the existing strict JSON and legacy single-line parsers.
- Do not change the `WAIT_CONNECTIONS DEVICE_ID=...` or `WAIT_RESULT=...` contracts.
- Do not expose the UU Remote custom code, account password, raw CLI stdout, or raw CLI stderr.
- Do not add a cross-platform supervisor or replace the platform-native PowerShell and Bash implementations.
- Do not change the macOS execution user or GUI-session context unless comparison evidence and a failing regression prove that such a change is necessary.

## 4. Considered approaches

### 4.1 Workflow-owned polling

The YAML loop could be converted from a fixed attempt count to a 60-second deadline while retaining separate launch, polling, and diagnostic commands. This is a small textual change, but it leaves responsibility split between YAML and Bash and makes future Windows/macOS drift likely.

### 4.2 Helper-owned launch and readiness

`macos.yml` delegates once to `apple.sh launch-and-wait-device`. The helper owns process detection, launch, deadline accounting, bounded CLI calls, validation, success output, and failure status. This mirrors the Windows boundary while retaining platform-specific internals.

This is the approved approach.

### 4.3 Shared cross-platform supervisor

A new Python controller could be shared by Windows and macOS. Although this would maximize internal uniformity, it would rewrite a verified Windows path, enlarge the risk surface, and add no necessary user-visible capability.

## 5. Architecture and control flow

The macOS workflow launch step becomes a thin delegate:

```text
macos.yml
  -> apple.sh launch-and-wait-device
       -> validate application and CLI paths
       -> detect whether UU Remote is already running
       -> launch it once if absent
       -> establish one monotonic 60-second deadline
       -> call bounded assist-id attempts within the remaining budget
       -> parse and validate the first successful device ID
       -> emit the readiness pair exactly once
       -> otherwise fail closed at the deadline
```

The workflow must not contain its own retry loop or readiness state variable. `report-device-id readiness` may remain as a compatible internal route, but the production launch step no longer composes readiness from repeated route calls.

Process detection must identify the intended UU Remote application without treating an unrelated process as ready. If no matching process exists, the helper launches the application once. If one already exists, the helper reuses it. The readiness loop never restarts or replaces the application.

The application launch is not wrapped in `gtimeout`. The 60-second deadline belongs to the readiness controller, not to the long-running GUI application. A readiness failure does not terminate a process that predated the helper call, and this design does not require terminating a process started by the current call. Retaining the failed state supports safe diagnostics and matches the Windows no-recovery behavior.

## 6. Deadline and subprocess semantics

The controller uses a monotonic clock. It computes a single deadline when readiness begins and derives a fresh remaining duration before each attempt and sleep.

Each `assist id` attempt receives a timeout no greater than the remaining overall duration. A timed-out CLI process is sent TERM, then KILL if needed, and is always waited for and reaped. Its stdout is captured only in a mode-`0600` temporary file owned by the current call; stderr is not echoed. Temporary files are removed on every return path.

After an unsuccessful attempt, the controller sleeps for the smaller of 500 milliseconds and the remaining duration. It does not begin another attempt or sleep after the deadline. Invalid timing values and missing application or CLI paths are configuration errors and fail immediately.

The total controller duration is bounded by the 60-second deadline plus only the small deterministic cleanup allowance required to terminate and reap an owned child.

## 7. Device-ID and log contract

The existing macOS parser remains the only extraction and validation boundary. A successful value must be either the approved strict JSON envelope or the approved legacy single printable line, followed by the shared validated device-ID rules. Empty output, nonzero CLI exit, invalid UTF-8, malformed JSON, `success:false`, duplicate keys, multiline values, C0 or DEL controls, and Unicode control or separator characters are unsuccessful attempts.

On the first validated value, stdout contains exactly these readiness lines once:

```text
DEVICE_ID=<validated device ID>
DEVICE_ID_STATE=ready
```

The production wait route retains:

```text
WAIT_CONNECTIONS DEVICE_ID=<validated device ID>
```

No other message gains a device ID. In particular, retry, timeout, diagnostic, and error messages do not include raw or unvalidated CLI output.

The UU Remote custom code and account password remain secrets. They must not appear in stdout, stderr, screenshots, artifacts, process arguments captured by diagnostics, or test fixtures that represent real credentials.

## 8. Errors and diagnostics

Transient CLI failures are silent at the raw-data boundary and remain eligible for another attempt while time remains. A final timeout returns a nonzero status and emits a generic error that may include safe elapsed-time and attempt-count metadata but no CLI payload.

When `UUREMOTE_DEBUG` is nonzero, the workflow invokes the existing safe device-ID diagnostic route once after final readiness failure. The diagnostic retains its fixed metadata-only contract and must not print a device ID, custom code, password, raw stdout, or raw stderr. Debug level does not change readiness timing, validation, or success output.

An application or CLI path error fails immediately. An unexpected controller or cleanup error also fails closed with a generic message.

## 9. Testing strategy

Implementation follows test-driven development. Tests exercise the real production helper through controlled process, clock, sleep, launch, and CLI boundaries rather than copying its decision logic.

Workflow contract tests prove:

- the Launch GameViewer step delegates exactly once to `apple.sh launch-and-wait-device`;
- the YAML-owned 120-attempt loop and readiness state variable are absent;
- the long-running application is not wrapped in `gtimeout`;
- safe diagnostics run at most once, only after final failure, and only when debug is nonzero.

Executable helper tests prove:

- an absent application is launched exactly once, transient failures may precede success, and the readiness pair is exact and unique;
- an existing application is reused without another launch;
- a hanging CLI is bounded by the remaining deadline, terminated, and reaped;
- no attempt or sleep begins after the deadline;
- a final failure returns nonzero and emits only generic output;
- invalid JSON, invalid UTF-8, multiline and control-character values never leak;
- temporary output is mode `0600` and leaves no file or child process behind;
- debug diagnostics execute once and preserve the existing fixed safe-field contract.

Regression verification includes the macOS device-ID, diagnostics, wait, and workflow-contract tests; the complete Windows parity suite; full repository test discovery; Bash syntax; PowerShell parsing; JSON validation; bilingual Markdown counterpart and navigation checks; sensitive-value scans; and `git diff --check`.

## 10. Implementation and review workflow

After this design is approved and committed, implementation occurs in an isolated worktree on a new feature branch. A written implementation plan identifies exact files, tests, RED and GREEN commands, review checkpoints, and live validation steps.

The change is expected to touch only the bilingual design and plan documents, `macos.yml`, `apple.sh`, and focused tests unless evidence establishes a necessary additional file. Every behavior change is introduced by a failing test. Independent review resolves all Critical and Important findings before integration.

## 11. Live acceptance

The feature branch is pushed only after local verification and review. A real macOS workflow is dispatched with `debug=1` and `wait=0`. Acceptance requires:

- the device-ID test module passes;
- Launch GameViewer completes within the 60-second readiness contract;
- the readiness pair appears exactly once with a validated device ID;
- no custom code, password, or raw CLI payload appears in logs or artifacts;
- the workflow advances beyond the Launch GameViewer stage.

If that run fails, the feature branch and safe diagnostic evidence are retained for systematic debugging; the workflow is not repeatedly retried without a new hypothesis.

After local verification, independent review, and feature-branch live acceptance pass, the branch is integrated into `main`. The same `debug=1`, `wait=0` workflow is dispatched on `main` and must reproduce the result. Only after this main run is green may the previously retained remote backup branches be deleted.
