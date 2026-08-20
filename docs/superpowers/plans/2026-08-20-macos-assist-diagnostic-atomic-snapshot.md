# macOS Assist Diagnostic Atomic Snapshot Implementation Plan

[English](2026-08-20-macos-assist-diagnostic-atomic-snapshot.md) | [简体中文](2026-08-20-macos-assist-diagnostic-atomic-snapshot-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the existing safe 19-field macOS unattended-permission diagnostic through an atomic supervisor-owned snapshot without relying on end-of-window worker reporting time.

**Architecture:** The Bash worker atomically commits an `open` or `committed` state after every attempt transition. The Python absolute-deadline supervisor owns the state directory, process cleanup, validation, timeout synthesis, and all fixed external output.

**Tech Stack:** Bash 3.2-compatible shell, macOS `/usr/bin/python3`, Python `unittest`, GitHub Actions macOS runner.

**Spec:** `docs/superpowers/specs/2026-08-20-macos-assist-diagnostic-atomic-snapshot-design.md`

## Global Constraints

- The complete operation, including cleanup and fixed output, has one 60-second hard deadline.
- Worker activity stops at 58 seconds, cleanup occupies at most the next second, and final validation/removal/output occupies at most the last second.
- The external success output remains exactly `ASSIST_STATE=enabled`.
- The existing 19 diagnostic names, count, order, and meanings remain unchanged.
- An interrupted `open` attempt becomes one timeout attempt with current response bytes `0` only after cleanup is confirmed.
- Cleanup-unconfirmed, no-attempt, malformed-state, external-signal, or finalization-deadline failures are generic-only.
- `debug_level=0` never prints `ASSIST_DIAGNOSTIC_*` fields.
- Raw CLI stdout/stderr, credentials, custom code, device ID, and other connection data never enter the state, logs, screenshots, or artifacts.
- State directories are mode `0700`; state and temporary files are mode `0600`.
- `.github/workflows/macos.yml`, Windows files, credential handling, and artifact schema do not change.
- English documentation changes precede meaning-equivalent Simplified Chinese changes.
- Every implementation task uses TDD and ends with an independent review before the next task.

## Pre-execution Gate: Remove the Superseded Candidate

The implementation worktree currently contains exactly eight unstaged timing-reserve candidate files. Before Task 1:

1. Obtain explicit user approval to discard those eight unstaged changes.
2. Preserve their exact diff under the ignored `.superpowers/` report directory for audit.
3. Restore only these paths to the committed state:
   - `.github/workflows/apple.sh`
   - `docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics.md`
   - `docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md`
   - `docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design.md`
   - `docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md`
   - `tests/macos_assist_allow_harness.sh`
   - `tests/test_agent_work_environment.py`
   - `tests/test_uuremote_desktop_finalization.py`
4. Verify that no `ASSIST_ALLOW_POST_ATTEMPT_RESERVE_MILLISECONDS` change remains and that the tracked worktree is clean.

Do not use `git reset --hard`. Do not remove the new atomic-snapshot spec or this plan.

---

### Task 1: Atomic Diagnostic State Contract

**Files:**
- Modify: `.github/workflows/apple.sh:1180-1297`
- Modify: `tests/macos_assist_allow_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py:226-610`

**Interfaces:**
- Produces: `validate_assist_allow_diagnostics <19 values>` returning `0` for a valid printable summary and `2` otherwise.
- Produces: `validate_assist_diagnostic_state_values <generation> <open|committed> <19 values>` returning `0` only for a valid internal state transition.
- Produces: `write_assist_diagnostic_state <path> <generation> <open|committed> <19 values>` returning `0` only after atomic replacement.
- Produces: strict record `v1<TAB>generation<TAB>state<TAB>19 values<LF>`.

- [ ] **Step 1: Write source and executable failing tests**

Add a portable harness route that sources the real helper and writes into a caller-owned temporary directory. Add tests named:

- `test_first_open_state_is_atomic_private_and_strict`: invoke generation `1`, state `open`, the zero baseline, and assert the exact 22 fields, LF framing, and file modes.
- `test_committed_state_preserves_the_exact_19_value_order`: invoke generation `1`, state `committed`, with attempts `1`, enabled-false count `1`, bytes `84/84/84`, category `enabled-false`, exit `0`; assert exact field positions.
- `test_state_writer_rejects_invalid_generation_state_and_values`: table-drive generation `0`, `01`, `2` with attempts `0`, state `pending`, negative counts, invalid category, mismatched totals, and category/exit mismatch; every case returns nonzero without replacing the baseline file.
- `test_state_writer_failure_leaves_no_partial_record`: inject chmod, write, and move failures separately; assert the previous state bytes remain exact and `${state_path}.tmp` is absent.
- `test_hostile_payload_markers_never_enter_state_or_output`: use device/custom-code/raw-response markers only in the fixture payload and assert each marker is absent from the state bytes, stdout, and stderr.

The successful first-open fixture must produce one LF-terminated record with 22 tab-separated fields, generation `1`, state `open`, attempts `0`, all counts and byte values `0`, final category `unavailable`, and final exit `unavailable`. Assert directory mode `0700`, state mode `0600`, and absence of `.tmp` files after return.

- [ ] **Step 2: Run RED**

Run:

```text
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests -v
```

Expected: the new tests fail because the validator/state writer routes do not exist.

- [ ] **Step 3: Separate validation from rendering**

Move the existing validation in `report_assist_allow_diagnostics` into:

Create `validate_assist_allow_diagnostics` by moving, without weakening, the current `report_assist_allow_diagnostics` checks for: argument count `19`; nonnegative decimal counters and byte sizes; allowed final category and exit; attempts at least `1`; every category count no greater than attempts; category total equal to attempts; `min <= final <= max`; final-category/count consistency; and category/exit consistency. It returns `0` without output or `2` on invalid input.

Make `report_assist_allow_diagnostics` call that validator first, then retain the current 19 `printf` statements byte-for-byte and in their current order.

Do not weaken any current invariant. Add an internal validator branch that permits only `state=open`, generation `1`, attempts `0`, zero counts/bytes, and `unavailable/unavailable` as the first-attempt baseline; this branch is never accepted by the external reporter.

For every non-baseline state, reuse the printable-value validator. Require `open` generation to equal `attempts + 1`; require `committed` generation to equal `attempts`. These relationships make skipped, repeated, or mismatched generations invalid from the final record alone.

- [ ] **Step 4: Implement atomic state writing**

Use this boundary:

```bash
write_assist_diagnostic_state() {
    local state_path="$1" generation="$2" state="$3"
    shift 3
    local temporary_path="${state_path}.tmp"

    validate_assist_diagnostic_state_values "$generation" "$state" "$@" || return 1
    umask 077
    : >"$temporary_path" || return 1
    /bin/chmod 0600 "$temporary_path" || {
        /bin/rm -f -- "$temporary_path" 2>/dev/null
        return 1
    }
    {
        printf 'v1\t%s\t%s' "$generation" "$state"
        printf '\t%s' "$@"
        printf '\n'
    } >"$temporary_path" || {
        /bin/rm -f -- "$temporary_path" 2>/dev/null
        return 1
    }
    /bin/mv -f -- "$temporary_path" "$state_path" || {
        /bin/rm -f -- "$temporary_path" 2>/dev/null
        return 1
    }
}
```

The state path and temporary path must be in the same supervisor-owned directory. A write failure removes the temporary file and never changes the previous committed state.

- [ ] **Step 5: Run GREEN and mutation checks**

Run the focused class. Then run isolated-copy mutations that remove `/bin/chmod 0600`, replace the final `/bin/mv` with a direct write, and append a hostile marker. Each mutation must make its corresponding test fail.

- [ ] **Step 6: Commit**

Stage only the three Task 1 files and commit:

```text
feat: add macOS assist diagnostic snapshots
```

Request an independent task review and resolve every Critical or Important finding before Task 2.

---

### Task 2: Worker State Transitions

**Files:**
- Modify: `.github/workflows/apple.sh:1361-1597,3203-3221`
- Modify: `tests/macos_assist_allow_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py:1630-1979`

**Interfaces:**
- Consumes: Task 1 `write_assist_diagnostic_state`.
- Produces: `ensure_assist_allowed <state-path>` with no final stdout/stderr output.
- Consumes environment: `UUREMOTE_ASSIST_INTERNAL_STATE_PATH` in `assist-allow-worker` mode.

- [ ] **Step 1: Write worker transition failing tests**

Add real-helper scenarios and tests:

- `test_worker_commits_open_before_invoking_the_cli`: have the fixture read the state on entry and require generation `1`, state `open`, attempts `0`.
- `test_worker_replaces_open_with_committed_after_classification`: return one valid enabled-false response and require generation `1`, state `committed`, attempts `1`, enabled-false count `1`.
- `test_second_open_contains_only_the_previous_committed_aggregate`: block the second fixture call and require generation `2`, state `open`, attempts `1`, with only the first category counted.
- `test_enabled_true_is_committed_before_worker_success`: make the fixture return enabled-true, inspect the final state after exit `0`, and require committed enabled-true count `1`.
- `test_open_write_failure_prevents_cli_invocation`: fail the state move before attempt one and require CLI call count `0`.
- `test_committed_write_failure_leaves_open_timeout_projection`: allow the open move, fail the committed move, and require the state bytes to remain the exact open record.
- `test_worker_never_prints_the_failure_summary`: run committed enabled-false under debug `1` and require empty worker stdout/stderr.

Use a fixture call counter to prove the CLI is not invoked when the `open` write fails. Use a controlled atomic-replace failure after classification to prove the file remains `open`.

- [ ] **Step 2: Run RED**

Run:

```text
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
```

Expected: failures show that `ensure_assist_allowed` does not accept a state path and does not commit transitions.

- [ ] **Step 3: Commit `open` before every attempt**

Before invoking `run_bounded_gui_cli_to_file`, call:

```bash
generation="$((attempts + 1))"
write_assist_diagnostic_state \
    "$diagnostic_state_path" "$generation" open \
    "$attempts" "$timeout_count" "$cli_nonzero_count" "$empty_count" \
    "$invalid_utf8_count" "$invalid_json_count" "$not_object_count" \
    "$success_missing_count" "$success_wrong_type_count" "$success_false_count" \
    "$enabled_missing_count" "$enabled_wrong_type_count" \
    "$enabled_false_count" "$enabled_true_count" \
    "${response_bytes_min:-0}" "$response_bytes_max" "$response_bytes_final" \
    "$final_category" "$final_cli_exit" || return 1
```

For generation `1`, the initial internal baseline is the sole allowed `unavailable/unavailable` state.

- [ ] **Step 4: Commit `committed` after strict classification**

After category accounting and byte statistics are complete, atomically write generation equal to `attempts` and state `committed`. Only then may `enabled-true` return success.

Remove the worker call to `report_assist_allow_diagnostics`; failed workers return nonzero without final output. Preserve raw response clearing and worker temporary-tree cleanup.

- [ ] **Step 5: Validate the internal entrypoint**

In `assist-allow-worker` mode, strictly validate `UUREMOTE_ASSIST_INTERNAL_STATE_PATH` as an absolute path inside the supervisor-created directory, copy it to a local variable, and unset the environment variable before calling:

```bash
ensure_assist_allowed "$assist_diagnostic_state_path"
```

Do not accept a missing, relative, newline-containing, or NUL-containing path.

- [ ] **Step 6: Run GREEN and causal mutations**

Run the aggregation class and the CLI redaction entrypoint test. Mutate away the pre-CLI `open` write and the pre-success `committed` write independently; each mutation must fail for its own behavioral assertion.

- [ ] **Step 7: Commit**

Stage only the Task 2 files and commit:

```text
refactor: commit macOS assist attempt states
```

Request independent spec and quality reviews. Resolve Critical and Important findings before Task 3.

---

### Task 3: Supervisor Validation and Fixed Output

**Files:**
- Modify: `.github/workflows/apple.sh:1621-2051`
- Modify: `tests/macos_assist_allow_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py:274-610,1119-1629`

**Interfaces:**
- Consumes: the Task 1 state record and Task 2 worker transitions.
- Produces Python helpers: `parse_diagnostic_state(path)`, `synthesize_open_timeout(snapshot)`, `render_diagnostics(snapshot)`.
- Produces supervisor outcomes: exact success, exact 19-field debug failure, or generic-only failure.

- [ ] **Step 1: Write supervisor failing tests**

Add portable controlled scenarios:

- `test_supervisor_renders_committed_failure_from_state`: provide one committed enabled-false record and require exactly the 19 existing lines plus caller generic failure.
- `test_supervisor_synthesizes_open_as_timeout`: provide first-generation open baseline and require attempts `1`, timeout `1`, bytes `0/0/0`, and final `timeout/timeout`.
- `test_supervisor_suppresses_diagnostics_at_debug_zero`: reuse the committed failure with debug `0` and require only the caller generic failure.
- `test_supervisor_rejects_malformed_or_missing_state`: table-drive missing file, extra LF, CR, NUL, non-ASCII, 21/23 fields, invalid generation/state/totals; every case is generic-only.
- `test_supervisor_rejects_state_until_cleanup_is_confirmed`: force the cleanup result false while leaving a valid committed record and require generic-only.
- `test_supervisor_outputs_success_only_from_committed_enabled_true`: require exact success for exit `0` plus committed enabled-true, and generic-only for exit `0` plus every other state.
- `test_supervisor_removes_state_before_external_output`: make state removal fail and require generic-only; on success, have the output probe verify the state path and directory are already absent.

The first-open timeout expected values are attempts `1`, timeout count `1`, all other counts `0`, byte min/max/final `0`, final category `timeout`, and final exit `timeout`.

- [ ] **Step 2: Run RED**

Run the supervisor source and absolute-deadline classes. Expected failures must identify missing parsing/synthesis and continued worker-output replay.

- [ ] **Step 3: Implement strict Python parsing**

Inside the existing supervisor heredoc, implement:

Implement `parse_diagnostic_state(path)` to read bytes once; require exactly one terminal LF and no other LF; split into exactly 22 tab-separated fields; require ASCII decoding, version `v1`, canonical positive generation, state `open|committed`, and all Task 1 numeric/enum/aggregate invariants; then return a dictionary with keys `generation`, `state`, `attempts`, every category count, the three byte statistics, `final_category`, and `final_cli_exit`.

Implement `synthesize_open_timeout(snapshot)` to copy that dictionary, increment attempts and timeout count exactly once, set final bytes to `0`, include `0` in min/max, set final category/exit to `timeout`, change state to `committed`, and pass the result through the same value validator before returning it.

Implement `render_diagnostics(snapshot)` to return ASCII bytes containing exactly the existing 19 `ASSIST_DIAGNOSTIC_*` names, values, order, and terminal LF.

The parser must reject non-ASCII, CR, NUL, extra whitespace, leading-zero generation, invalid state, invalid totals, and the zero-attempt baseline unless state is `open` generation `1`.

- [ ] **Step 4: Replace capture replay with state-based finalization**

Create the state path in the supervisor mode-`0700` directory, initialize no printable snapshot, and pass it as `UUREMOTE_ASSIST_INTERNAL_STATE_PATH` to the worker.

Redirect worker stdout/stderr away from external logs. After worker exit or deadline cleanup:

1. confirm all owned PID/process groups are absent;
2. parse the state;
3. synthesize timeout only for `open`;
4. validate worker success only with committed `enabled-true`;
5. render failure bytes only for debug `1|2|3`;
6. remove all state, worker, and temporary data before external output; retain only the supervisor's decision hard-links until the atomic interruption/output decision is complete;
7. recheck the absolute deadline;
8. atomically honor the existing interruption decision;
9. print fixed success or diagnostic bytes;
10. after output is atomically committed, let the supervisor cleanup trap remove the decision hard-links and the now-empty private directory before the shell helper returns.

If any step fails, return `125` without structured output so `enable_assist_or_fail` prints only the generic failure.

- [ ] **Step 5: Set the fixed deadline phases**

Use the single supervisor deadline:

```python
deadline = time.monotonic() + 60.0
cleanup_start = deadline - 2.0
cleanup_deadline = deadline - 1.0
finalization_deadline = deadline
```

The worker cutoff passed to Bash is `cleanup_start`. TERM and KILL remain capped at 500ms each. Remove the worker finalization-reserve and post-attempt-reserve constants and every test-only rewrite of them.

- [ ] **Step 6: Run GREEN and mutations**

Run the focused supervisor/process/aggregation classes. Independently mutate cleanup confirmation to false, relax the state parser, bypass state deletion, remove debug gating, and replace atomic interruption ownership. Each mutation must fail without leaking hostile markers.

- [ ] **Step 7: Commit**

Stage only Task 3 files and commit:

```text
fix: deliver macOS assist diagnostics atomically
```

Request independent review with explicit focus on deadline arithmetic, cleanup ownership, signal races, state validation, and raw-output privacy. Resolve all Critical and Important findings.

---

### Task 4: Targeted Native macOS Causal Gate

**Files:**
- Modify: `tests/macos_assist_allow_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py:1119-1629`

**Interfaces:**
- Consumes: the real production supervisor, worker, state writer, parser, and cleanup logic.
- Produces: one native test class whose scenarios are isolated from host provisioning.

- [ ] **Step 1: Write native failing scenarios**

Add these Darwin-only tests, using caller-owned temporary roots and real production entrypoints:

- `test_native_first_open_timeout_is_reported_and_reaped`: block the first CLI after observing state `open`; require synthesized attempt `1` timeout and strict release.
- `test_native_committed_then_open_preserves_counts_and_adds_timeout`: complete enabled-false once, block attempt two, and require attempts `2`, enabled-false `1`, timeout `1`.
- `test_native_committed_failure_outputs_exact_19_fields`: complete one non-success category and require exact fixed output and generic caller failure.
- `test_native_cleanup_unconfirmed_is_generic_only`: run the real cleanup side effects, force its confirmation result false, and require no structured fields.
- `test_native_enabled_success_is_exact_and_clean`: complete enabled-true and require exact single success line, empty stderr, empty tree, and absent PID/PGID.

Each test must assert bounded elapsed time, exact stdout/stderr, exact field count/order, empty temporary root, and absence of every recorded PID and PGID before returning.

- [ ] **Step 2: Prove RED causally**

Run the native class against an isolated source copy with each of these mutations:

- remove the `open` commit;
- write state non-atomically;
- accept output before cleanup confirmation;
- skip open-timeout synthesis;
- skip state removal before output.

Each mutation must fail its dedicated assertion. The unmodified implementation must then pass all five scenarios.

- [ ] **Step 3: Remove obsolete timing diagnostics**

Delete the superseded `absolute-real-poll-summary`, checkpoint-counter, classifier-delay, and reserve-budget test routes. Retain independently useful startup/preexec, clock, poll, signal, cleanup, and process-group regressions.

- [ ] **Step 4: Run local portable coverage**

On non-Darwin hosts, confirm that the native class is explicitly skipped while source contracts and portable state scenarios execute. Run Bash syntax and Python compile checks.

- [ ] **Step 5: Commit**

Stage only the two test files and commit:

```text
test: cover atomic macOS assist finalization
```

Request an independent test-quality review. Reject token-only or vacuous mutations; all native mutations must execute the real production boundary.

---

### Task 5: Governing Documentation and Final Local Gate

**Files:**
- Modify: `docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics.md`
- Modify: `docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md`
- Modify: `docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design.md`
- Modify: `docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md`
- Modify: `tests/test_agent_work_environment.py`

**Interfaces:**
- Consumes: final production function names, deadline constants, state schema, and output rules from Tasks 1-4.
- Produces: meaning-equivalent English/Chinese governing contracts and executable parity assertions.

- [ ] **Step 1: Write documentation contract RED tests**

Add assertions that both language pairs require:

- supervisor-owned `v1` atomic state;
- `open` and `committed` transitions;
- 58s worker, 1s cleanup, 1s finalization inside 60s;
- unchanged 19 fields;
- synthesized timeout bytes `0`;
- cleanup-unconfirmed generic-only behavior;
- separate authorization for targeted native and full workflow runs;
- absence of the superseded post-attempt and worker-report reserve design.

Add a semantic mutation that removes open-timeout synthesis from each language independently and prove each counterpart fails on its own.

- [ ] **Step 2: Run RED**

Run:

```text
python -m unittest tests.test_agent_work_environment -v
```

Expected: new assertions fail against the old governing documents.

- [ ] **Step 3: Update English documents, then Simplified Chinese counterparts**

Mark the old timing-report sections as superseded by the 2026-08-20 spec. Update executable snippets and matrices to match the final production state schema and deadline phases. Keep English and Chinese requirements meaning-equivalent and preserve navigation structure.

- [ ] **Step 4: Run GREEN and repository validation**

Run fresh:

```text
python -m unittest tests.test_agent_work_environment -v
python -m unittest tests.test_uuremote_desktop_finalization tests.test_uuremote_wait -v
python -m unittest discover -s tests -v
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
git diff --check e30a65b..HEAD
```

On a host without native `/bin/bash`, run the repository's Git Bash syntax-equivalent check and record the native test skips accurately. Run the full discovery once in an approved real-desktop context if and only if the known screenshot tests fail solely because the sandbox has no interactive desktop.

Also verify:

- every root and `docs/**` Markdown file has exactly one counterpart and valid navigation;
- no `-zh_CN-zh_CN.md` path exists;
- `.claude/settings.json` parses and enables only Superpowers;
- the final diff contains no account password, custom code, raw payload, PID/PGID, command line, or new artifact field;
- `.github/workflows/macos.yml` and all Windows files have no diff.

- [ ] **Step 5: Commit documentation contracts**

Stage only the five Task 5 files and commit:

```text
docs: align macOS assist snapshot contracts
```

- [ ] **Step 6: Final independent whole-branch review**

Generate an ignored review package from the pre-implementation base through HEAD. Request a fresh read-only review against the approved 2026-08-20 spec. Resolve every Critical and Important finding, rerun the affected focused tests, then rerun the complete final gate. Do not push or dispatch.

## Post-implementation Remote Gates

Remote actions are not automatically authorized by plan approval.

1. Obtain explicit approval to push the reviewed feature branch.
2. Obtain explicit approval to dispatch one debug-enabled macOS run.
3. Treat the existing `Test device ID logging` step as the targeted native gate. Monitor it and cancel the run before host provisioning if a preflight failure occurs; do not rerun automatically.
4. If every targeted atomic-snapshot scenario passes, stop and report exact run/job/step evidence.
5. Obtain separate explicit approval for one complete macOS workflow validation.
6. Accept only exact success or the required fixed 19-field debug failure, with no raw payload and no cleanup residue evidence.
7. Any failure stops the sequence pending a new reviewed plan; do not automatically patch, push, rerun, merge, or delete branches.
