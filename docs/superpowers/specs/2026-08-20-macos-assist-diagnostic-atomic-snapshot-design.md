# macOS Assist Diagnostic Atomic Snapshot Design

[English](2026-08-20-macos-assist-diagnostic-atomic-snapshot-design.md) | [简体中文](2026-08-20-macos-assist-diagnostic-atomic-snapshot-design-zh_CN.md)

## 1. Context

The macOS unattended-permission controller must finish within one 60-second hard deadline. When permission enablement fails and `debug_level != 0`, the current workflow step must print the existing fixed 19-field diagnostic summary. Raw vendor output, credentials, and remote-connection data must never appear in logs or artifacts.

The current implementation asks the worker to classify attempts, aggregate the result, render the summary, exit, and have the supervisor replay captured output near the end of the same deadline. Native runs showed that this makes diagnostic delivery depend on the remaining scheduling and startup time. Increasing finalization or post-attempt reserves changes the timing but does not establish a stable ownership boundary.

This design replaces end-of-window report generation with an incrementally committed, supervisor-owned diagnostic snapshot. It supersedes the uncommitted timing-reserve candidate based on `ASSIST_ALLOW_POST_ATTEMPT_RESERVE_MILLISECONDS`.

## 2. Goals

- Preserve the existing successful output: `ASSIST_STATE=enabled`.
- Preserve the existing 19 diagnostic field names, count, and meanings.
- Print those 19 fields only when permission enablement fails, `debug_level != 0`, cleanup is confirmed, and a valid attempt snapshot exists.
- Represent an attempt interrupted by the deadline as one safe `timeout` attempt with current response bytes equal to `0`.
- Include worker termination, descendant cleanup, snapshot validation, and log submission inside one 60-second hard deadline.
- Make diagnostic availability independent of a final worker reporting window.
- Keep all failures fail-closed and prevent later normal workflow steps from continuing.

## 3. Non-goals

- Do not change `.github/workflows/macos.yml` step ordering or artifact behavior.
- Do not change the Windows workflow or helper implementation.
- Do not add new externally visible diagnostic fields.
- Do not log raw CLI stdout or stderr, a UU Remote custom code, an account password, a device ID, or other remote-device connection information in this diagnostic.
- Do not guarantee structured diagnostics when cleanup is unconfirmed, no attempt started, the snapshot is invalid, or an external signal interrupts the operation.
- Do not extend the operation beyond 60 seconds to improve logging.

## 4. Architecture

### 4.1 Absolute-deadline supervisor

The supervisor is the sole owner of:

- the absolute deadline;
- the worker process tree and process groups;
- the private diagnostic state directory;
- cleanup confirmation;
- final success or diagnostic log output.

The supervisor creates the private state directory before starting the worker, passes only the state-file path and the worker cutoff to the worker, and never reads raw CLI response files.

### 4.2 Attempt worker

The worker owns bounded CLI execution, strict response classification, and aggregate calculation. It emits no final failure summary. Before an attempt begins and after it is classified, it atomically commits diagnostic state.

The worker continues to keep raw CLI output in its own mode-`0600` temporary files. It clears those files after classification and removes its private temporary tree before returning when cleanup succeeds.

### 4.3 Atomic diagnostic state

The state file is a strict ASCII tab-separated record:

```text
v1<TAB>generation<TAB>state<TAB>19 diagnostic values
```

`generation` is a positive decimal integer for every started attempt. `state` is exactly `open` or `committed`.

The 19 diagnostic values correspond, in order, to the existing external fields:

1. attempts
2. timeout count
3. CLI-nonzero count
4. empty count
5. invalid-UTF-8 count
6. invalid-JSON count
7. not-object count
8. success-missing count
9. success-wrong-type count
10. success-false count
11. enabled-missing count
12. enabled-wrong-type count
13. enabled-false count
14. enabled-true count
15. response-bytes minimum
16. response-bytes maximum
17. response-bytes final
18. final category
19. final CLI exit

An `open` record contains the last committed aggregate before the current attempt. For the first attempt, it may contain the internal zero-attempt baseline with final category and exit set to `unavailable`; that baseline is never externally printable. A `committed` record contains the current attempt and must satisfy every external 19-field invariant.

The worker writes a complete record to a mode-`0600` sibling temporary file, validates it, and atomically replaces the state file on the same filesystem. Partial records are never accepted.

## 5. State Transitions

1. The supervisor creates a mode-`0700` state directory. No printable snapshot exists yet.
2. Before attempt N invokes the CLI, the worker atomically writes generation N as `open` with the previous committed aggregate.
3. The worker runs the bounded CLI, reads its safe status, strictly classifies the response, and clears the raw response.
4. The worker calculates the new aggregate and atomically replaces the record with generation N as `committed`.
5. A subsequent attempt repeats the transition with generation N+1.
6. An accepted `enabled-true` result is committed before the worker returns success.

Generation must increase by exactly one. A repeated, skipped, decreasing, non-decimal, or mismatched generation makes the state invalid and forces generic-only failure.

## 6. Deadline and Finalization

The supervisor establishes one monotonic deadline at `T0 + 60s`.

- Normal worker activity may continue until `T0 + 58s`.
- At `T0 + 58s`, the supervisor begins bounded cleanup.
- TERM receives at most 500ms.
- KILL receives at most 500ms.
- The supervisor must confirm owned PID and process-group absence before using diagnostic state.
- Cleanup must finish by `T0 + 59s`.
- The final second is reserved only for snapshot validation, state removal, and fixed output; those operations must complete before `T0 + 60s`.

The worker's attempt timeout is `min(3000ms, remaining time before cleanup starts)`. There is no worker-report reserve and no post-attempt reserve. The supervisor has a fixed one-second finalization phase because cleanup and output must both remain inside the hard deadline. If the worker cannot finish an attempt, the already committed `open` state supplies the safe timeout projection after cleanup.

## 7. Final Result Rules

### 7.1 Success

The supervisor may print `ASSIST_STATE=enabled` only when all of the following are true:

- the worker returned success before the deadline;
- the final state is a valid `committed` record;
- its final category is `enabled-true`;
- owned descendants are confirmed absent;
- private worker and state files are removed successfully.

### 7.2 Committed failure

When the final state is valid `committed`, cleanup is confirmed, and `debug_level` is `1`, `2`, or `3`, the supervisor prints the unchanged 19 fields from that state, followed by the existing generic failure from the caller.

At `debug_level=0`, it prints no structured diagnostic and retains only the generic failure.

### 7.3 Open attempt at the deadline

After cleanup is confirmed, the supervisor validates the `open` baseline and synthesizes one timeout attempt:

- increment attempts and timeout count by one;
- set response-bytes final to `0`;
- include `0` in response-bytes minimum and maximum calculation;
- set final category and final CLI exit to `timeout`;
- leave every other category count unchanged.

The synthesized record must pass the same 19-field validator before it is printed.

### 7.4 Generic-only failure

The supervisor prints no structured diagnostic when any of the following is true:

- cleanup or owned-process absence is unconfirmed;
- no attempt reached `open`;
- state version, generation, field count, numeric value, enum, or aggregate relationship is invalid;
- state-file creation, atomic replacement, reading, validation, or deletion fails;
- HUP, INT, or TERM wins the existing atomic interruption decision;
- the 60-second deadline leaves insufficient time to validate and submit the complete result.

Normal later workflow steps do not continue after these failures. Existing hosted teardown and already-authorized `always()` artifact behavior remain unchanged.

## 8. Security and Privacy

- The state directory is mode `0700`; state and temporary files are mode `0600`.
- The state record accepts only its fixed version, fixed state enums, decimal integers, and existing safe category/exit enums.
- The supervisor never reads or copies raw CLI stdout or stderr.
- State validation happens only after the worker is stopped and owned cleanup is confirmed.
- State removal must succeed before success or structured diagnostics are committed to logs.
- Cleanup-unconfirmed and malformed-state paths publish no structured status.
- External logs remain confined to the current workflow step; no new artifact fields are added.

## 9. Testing Strategy

### 9.1 Portable state-machine tests

Tests invoke the real state writer and validator and cover:

- first attempt left `open`;
- a committed attempt followed by an `open` attempt;
- committed failure;
- committed success;
- malformed versions, generations, states, fields, values, enums, and aggregate relationships;
- atomic-write failure;
- `debug_level=0` suppression;
- hostile raw markers absent from state, stdout, and stderr.

### 9.2 Targeted native macOS gate

One native gate invokes only the real supervisor, worker, and controlled fixture. It does not provision the host. It proves:

- a CLI or classifier hang produces the synthesized timeout summary after strict cleanup;
- cleanup-unconfirmed mutation produces generic-only failure;
- normal failure produces the exact 19 fields;
- enabled success retains exact output;
- the private temporary tree is empty and owned PID/process groups are absent before the test returns.

Causal mutations must fail when the `open` commit, atomic replacement, cleanup gate, snapshot validation, or debug gate is removed or bypassed.

### 9.3 Remote validation gates

After local verification and independent review, remote actions require separate user authorization:

1. Push and dispatch one targeted native gate.
2. Stop and report its evidence.
3. Only after another explicit authorization, run one complete macOS workflow.

Any failure stops the sequence. There is no automatic repair, rerun, push, dispatch, or merge.

## 10. Migration and Scope

Implementation removes the uncommitted post-attempt timing-reserve candidate and replaces it with the atomic state boundary. Expected tracked scope is limited to:

- `.github/workflows/apple.sh`;
- the focused macOS assist harness and tests;
- the governing English and Simplified Chinese design/plan counterparts.

No workflow YAML, Windows implementation, credential handling, artifact schema, or unrelated provisioning behavior changes are authorized by this design.
