# macOS Unattended Permission Diagnostics Design

[English](2026-08-16-macos-unattended-permission-diagnostics-design.md) | [简体中文](2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md)

## 1. Context

The macOS feature workflow now passes the native device-ID test and the GameViewer launch-readiness step. Two consecutive feature runs then fail in the unchanged `Configure UU Remote permissions` step. In both runs, `uuyc-cli status` reaches `CLI_STATUS_STATE=ready`, but `uuyc-cli assist allow on` does not produce an accepted `enabled=true` result within 60 seconds.

The current failure path exposes only a generic error. It cannot distinguish a hung child, a nonzero CLI exit, malformed output, a changed JSON schema, `success=false`, or `enabled=false`. Re-running without new evidence is prohibited. The next live run must first establish the failing boundary without exposing vendor payloads or weakening the unattended-access gate.

## 2. Goals

- Permanently add safe, debug-only diagnostics to the macOS unattended-permission boundary.
- Bound every `assist allow on` child process and the complete polling operation with monotonic deadlines.
- Classify every attempt into exactly one predefined safe state and aggregate the complete 60-second window.
- Keep successful output unchanged as `ASSIST_STATE=enabled`.
- Keep failures fail-closed and retain the existing generic error.
- Use one diagnostic live run to identify the root cause before implementing a root-cause-specific fix.
- Follow the Windows helper pattern of an owned bounded process boundary, strict parsing, fixed success output, and generic failure without forcing identical platform internals.

## 3. Non-goals

- Do not print or persist raw CLI stdout or stderr.
- Do not print a UU Remote custom code, account password, device ID, or other remote-device connection information in this diagnostic.
- Do not write the new diagnostic fields to `uuremote-diagnostics` or any other artifact.
- Do not weaken the requirement that macOS must prove `success=true` and `enabled=true`.
- Do not fall back to the weaker Windows readiness evidence when the macOS command fails.
- Do not guess a replacement vendor command, modify TCC directly, weaken macOS security controls, or add an unproven recovery action.
- Do not modify the Windows runtime implementation.

## 4. Two-Stage Delivery

### 4.1 Permanent diagnostic stage

The first implementation adds the bounded execution, strict classifier, aggregation, cleanup, and debug-only reporter described below. Local tests and review must pass before a live run is requested.

The first native macOS run after that commit is a diagnostic gate. The workflow may remain red, but the permission step must emit a complete safe summary that identifies the real failure class. A red diagnostic run is evidence gathering, not a completed fix.

### 4.2 Root-cause fix stage

No behavior fix is implemented until the diagnostic gate identifies the failure class.

- If the evidence shows a legal vendor response shape that the parser rejects, add that exact shape as a failing fixture and make the smallest strict parser change.
- If the evidence shows stable `enabled=false`, CLI failure, timeout, or another vendor or environment condition, keep the workflow fail-closed. Investigate that condition and amend this design before adding a recovery action or changing the permission contract.
- Do not treat improved diagnostics as proof that unattended access is enabled.

The fix gate requires the feature workflow to pass the permission step and all later unchanged steps.

## 5. Components and Data Flow

### 5.1 Bounded GUI CLI boundary

`run_bounded_gui_cli_to_file` executes the installed CLI in the graphical console user's launchd session. It owns the child process and process group, redirects stdout to a caller-provided mode-`0600` file, discards stderr, and accepts a timeout derived from the remaining overall deadline.

This is the bounded fail-closed cleanup policy (Option 2). The helper performs `TERM`→`KILL`→reap/PGID probe. The documented cleanup grace is at most 500 milliseconds for `TERM`, followed by at most 500 milliseconds for `KILL`, reaping, and the PGID probe. Cleanup may add only the documented fixed cleanup grace beyond a CLI attempt; it never waits indefinitely.

Only confirmed cleanup publishes the existing safe status. Unconfirmed cleanup or an exception publishes no final status and exits `125`. The controller emits only the existing generic failure; no subsequent normal or provisioning operation continues. Only the existing `always()` finalization/artifact-upload steps and hosted-runner teardown may execute. Raw assist payload, secrets, device connection data, and the new `ASSIST_DIAGNOSTIC_*` fields never enter artifacts; those fields remain in the current-step log only. The existing sanitized CLI diagnostics may be uploaded by the `always()` artifact step. OS-level residue may remain unconfirmed; no absolute cleanup claim is made.

### 5.2 Strict response classifier

`classify_assist_allow_response` receives only the response-file path and safe execution status. It decodes strict UTF-8 and parses strict JSON with duplicate-key rejection and rejection of nonstandard constants such as `NaN` and `Infinity`.

Every attempt produces exactly one category:

- `timeout`
- `cli-nonzero`
- `empty`
- `invalid-utf8`
- `invalid-json`
- `not-object`
- `success-missing`
- `success-wrong-type`
- `success-false`
- `enabled-missing`
- `enabled-wrong-type`
- `enabled-false`
- `enabled-true`

Only a JSON object whose `success` value is the Boolean `true` and whose `enabled` value is the Boolean `true` is successful.

The classifier emits only a predefined category and numeric metadata to its caller. It never emits the parsed object, string values, response fragments, or stderr.

### 5.3 Attempt accumulator

`ensure_assist_allowed` owns the overall deadline and accumulator. It tracks:

- total attempts;
- one counter for every predefined category;
- minimum, maximum, and final response byte counts;
- final category; and
- final safe CLI exit value.

After each attempt is classified, the raw response file is immediately truncated. A successful `enabled-true` result prints only `ASSIST_STATE=enabled` and returns success. Otherwise polling continues until the deadline.

### 5.4 Safe reporter

When the deadline expires and `UUREMOTE_DEBUG` is `1`, `2`, or `3`, the reporter writes fixed lines to the current workflow step log. It prints every category counter, including zero-valued counters, plus the numeric aggregate fields and final enum.

The final CLI exit field is limited to an integer from `0` through `255`, `timeout`, or `unavailable`. The reporter validates every integer and enum before writing anything. Invalid internal state produces no detailed diagnostic and fails closed.

The reporter does not run when debug is `0`, and no new diagnostic data is written to an artifact.

## 6. Timing and Error Handling

- Establish one 60-second monotonic deadline immediately before the first attempt.
- Limit each CLI call to the smaller of 3,000 milliseconds and the remaining overall time.
- After a failed attempt, wait for the smaller of 500 milliseconds and the remaining overall time.
- Recheck the deadline after child completion, after parsing, and immediately before accepting `enabled-true`.
- Reject a result that becomes available only after the deadline.
- Treat launch failure, temp-file failure, parser failure, cleanup failure, signal interruption, or an invalid accumulator invariant as fail-closed.
- On each applicable path, perform the bounded cleanup policy and remove private temporary files when that removal can be confirmed. Do not claim that all operating-system residue is absent when cleanup confirmation fails.

After a debug-only summary, the existing caller still prints:

```text
Could not enable unattended control within 60 seconds
```

and exits with status `1`. With debug `0`, only the generic error is printed.

## 7. Security and Logging Contract

Raw response data exists only in a private temporary file owned by the current attempt. The directory and file use restrictive permissions, the response is truncated immediately after classification, and the complete temporary tree is removed before return.

The diagnostic log contains only predefined field names, validated integers, and predefined enums. Fixture values containing a custom code, device ID, newlines, control characters, Unicode separators, or forged workflow tokens must not appear in stdout, stderr, temporary leftovers, or artifacts.

The custom-code secret remains step-scoped to the earlier custom-code step and is not read by the permission diagnostic. The design does not change account, TCC, firewall, login, or operating-system security policy.

## 8. Tests

The implementation must add executable tests for:

- every response category, including duplicate keys and nonstandard JSON constants;
- exactly-one-category accounting and `sum(category counts) == attempts`;
- transient failures followed by success, with only `ASSIST_STATE=enabled` emitted;
- debug `0` generic-only failure;
- debug `1`, `2`, and `3` complete fixed summaries;
- a real controlled hanging child, per-call timeout, total deadline, the bounded `TERM`→`KILL`→reap/PGID probe, and confirmed cleanup;
- native-macOS matrix cases where cleanup is false or raises for timeout, a completed leader with a live descendant, and handled signals; each must produce exit `125`, no final status, and the outer generic failure only; no subsequent normal or provisioning operation may continue, while only the existing `always()` finalization/artifact-upload steps and hosted-runner teardown may execute;
- late-success rejection;
- response-file and temporary-directory cleanup;
- hostile fixture markers and log-injection attempts producing no leakage;
- workflow structure proving that the permission step receives `UUREMOTE_DEBUG` and that the new fields are not written to an artifact.

The production helper, rather than copied test logic, must own classification and aggregation decisions.

## 9. Live Validation and Completion

After local verification and independent review, request explicit authorization before pushing or dispatching the diagnostic live run. The run uses `debug_level=1` and records only the safe workflow-log fields.

The diagnostic run establishes the root-cause category. A root-cause-specific failing test must then precede the smallest behavior fix. Completion requires a later feature run to pass the permission step and all subsequent workflow steps.

Before branch completion, run the relevant macOS and Windows contract suites, bilingual documentation validation, JSON validation, secret and forbidden-output scans, `git diff --check e30a65b..HEAD`, and independent code review. Integration into `main` remains a separate finishing decision.

Current GitHub-hosted macOS runner teardown is external containment after job failure. If reused/self-hosted execution is ever adopted, the runner must be quarantined and not reused until an operator confirms no residue.

## 10. Scope

Expected implementation files are:

- `.github/workflows/apple.sh`
- focused files under `tests/`
- this English design and its meaning-equivalent Simplified Chinese counterpart
- the later English implementation plan and its Simplified Chinese counterpart

`.github/workflows/macos.yml` should remain unchanged because `UUREMOTE_DEBUG` already reaches the permission step at job scope. A minimal workflow change is allowed only if an executable contract demonstrates that the existing structure cannot enforce this design.
