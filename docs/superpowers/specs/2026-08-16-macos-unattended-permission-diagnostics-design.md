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

### 4.3 Native run #155 wall-clock amendment

Native run #155 reached `CLI_STATUS_STATE=ready` and then produced no further
output for more than the documented permission window. The run was canceled
after 1 hour 53 minutes. Phase-1 causal tests proved that the original
deadline was sampled only after synchronous boundaries returned: child startup
and `preexec_fn`, the initial monotonic-clock read, and the poll helper could
each block before another deadline check.

The approved Option 2 policy therefore includes an outer wall-clock
supervisor. It starts the 60-second deadline before forking an isolated worker
that runs the complete `ensure_assist_allowed` route. The worker receives that
same absolute deadline with a fixed 4,000-millisecond finalization reserve, so
its business/classification window ends at 56 seconds. The first three seconds
of the reserve are available for bounded inner `TERM`→`KILL` cleanup,
fixed-field reporting, and private capture closure before forced supervisor
cleanup begins at 59 seconds. The last second remains available for the
supervisor's bounded cleanup. The supervisor begins forced cleanup no later than 59 seconds and
caps both cleanup phases at the outer deadline; the reserve never extends the
outer 60-second hard deadline. Signals are blocked until
the parent records worker ownership. On expiry or interruption, the supervisor
repeatedly snapshots the worker's descendant PID/PPID/PGID relationships,
sends `TERM` and then `KILL` to every recorded direct PID and process group,
reaps the worker, and confirms absence with direct PID and PGID probes. Each
signal phase is bounded to 500 milliseconds. An observation or cleanup failure
remains fail-closed.

### 4.4 Native run #159 diagnostic-finalization amendment

Native run #159 proved that a real enabled-false polling route could reach the
worker cutoff yet lose all 19 safe diagnostic fields before the supervisor's
59-second forced-cleanup boundary. With the earlier 1,500-millisecond reserve,
only about 500 milliseconds remained between the worker cutoff and forced
supervisor cleanup. That window had to cover the final clock/poll subprocess,
fixed-field report generation, worker exit, capture reading, capture removal,
and the atomic replay decision.

The 4,000-millisecond reserve moves only the worker business/classification
cutoff to 56 seconds. It leaves the outer 60-second hard deadline, the
59-second forced-cleanup boundary, and both 500-millisecond supervisor cleanup
phases unchanged. The additional bounded time is solely for cleanup, safe
report finalization, and private capture closure; it does not expose raw CLI
payload, device IDs, custom codes, or secrets.

The shell backgrounds the resolved external Python executable directly, with
no shell-function or subshell indirection, so `$!` is the actual supervisor PID
that receives relayed signals and owns worker cleanup. Test shims replace that
explicit executable path rather than wrapping the background command.

Worker stdout and stderr remain in private mode-`0600` files. The supervisor
replays them only after the worker exits before the wall-clock deadline and the
capture files are removed successfully. Before replay commits, timeout, interruption, startup
failure, unconfirmed cleanup, or capture cleanup failure discards the worker
output; the existing outer caller prints only its generic failure.

Replay has one explicit commit point. After reading and removing both capture
files, the supervisor blocks handled signals, rechecks the outer deadline,
then safely restores the prior mask while the fail-closed handler remains
installed so a pending pre-commit signal is handled synchronously. It does not
block handled signals again; while they remain unblocked, either the handler or
the main path atomically links the mode-`0600` interrupt source or mode-`0600`
commit source to one private decision path. The first link wins and linearizes
interruption against replay. Before the commit-source link wins,
every handled signal or exception discards all worker output. After it wins,
replay is committed: handled signals do not reclassify the result, and a replay
I/O failure cannot add a second supervisor failure. The shell preserves the
worker status only when the decision path names the commit source, then removes
all private decision files and the directory on exit. This prevents a partial
replay from being followed by a contradictory supervisor failure.

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

- Establish the outer 60-second monotonic deadline before worker creation; pass the same absolute value to the worker and subtract the fixed 4,000-millisecond finalization reserve from only the worker's business/classification cutoff.
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

Raw response data exists only in a private temporary file owned by the current attempt. The directory and file use restrictive permissions. Private temporary files are truncated or removal is attempted immediately. Confirmed paths remove private temporary files before return. A cleanup failure makes no absence-of-residue claim. Hosted-runner teardown is external containment, and a self-hosted runner is quarantined until an operator confirms no residue.

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
- native causal blocks at child startup/`preexec_fn`, the initial clock read, and polling; each must return through the generic failure within the external wall-clock bound and leave every recorded PID and PGID absent;
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
