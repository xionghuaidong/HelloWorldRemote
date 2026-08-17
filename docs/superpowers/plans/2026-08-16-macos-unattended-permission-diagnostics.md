# macOS Unattended Permission Diagnostics Implementation Plan

[English](2026-08-16-macos-unattended-permission-diagnostics.md) | [简体中文](2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add permanent, safe diagnostics that identify why macOS `uuyc-cli assist allow on` does not reach `enabled=true`, without weakening the fail-closed permission gate.

**Architecture:** Keep `ensure_assist_allowed` as the shell orchestrator. Put child ownership and timeout handling behind a bounded GUI-process boundary, convert every private response into one fixed safe category, and aggregate the complete 60-second window. The first native run is an evidence gate; a root-cause fix requires a later design amendment and plan based on that evidence.

**Tech Stack:** Bash 3.2-compatible shell, embedded Python 3 from `/usr/bin/python3`, GitHub Actions YAML, Python `unittest`, and native macOS process/session tools.

## Global Constraints

- Work only in the existing isolated `fix/macos-device-id-readiness` worktree and preserve unrelated user changes.
- Use TDD for every runtime behavior change: observe RED, implement the minimum GREEN, refactor only while tests stay green.
- Keep all source, test, workflow, and code-example comments in English.
- Update English documentation first and keep the Simplified Chinese counterpart meaning-equivalent in the same commit.
- Keep the overall deadline at exactly 60 seconds, the per-call cap at exactly 3,000 milliseconds, and the poll interval at exactly 500 milliseconds.
- Accept success only when strict JSON has Boolean `success=true` and Boolean `enabled=true` before the deadline.
- Print `ASSIST_STATE=enabled` on success and retain `Could not enable unattended control within 60 seconds` plus exit `1` on failure.
- Emit detailed fields only when `UUREMOTE_DEBUG` is `1`, `2`, or `3` and the unattended operation fails.
- Never print or persist raw CLI stdout/stderr, custom codes, passwords, device IDs, or other remote-device connection data in this diagnostic.
- Write the diagnostic only to the current workflow step log; do not add it to any artifact.
- Do not modify the Windows runtime, weaken TCC or other operating-system controls, guess another vendor command, or fall back to a weaker readiness check.
- Keep raw response files and status files mode `0600`, truncate the response after classification, and attempt private temporary-file removal through the bounded fail-closed cleanup policy.
- The helper uses the bounded fail-closed cleanup policy: `TERM`→`KILL`→reap/PGID probe, with at most 500 milliseconds of `TERM` grace and at most 500 milliseconds of `KILL`/reap/PGID-probe grace. Cleanup may add only the documented fixed cleanup grace beyond a CLI attempt; it never waits indefinitely.
- Only confirmed cleanup publishes the existing safe status. Publishing `timeout` or `unavailable` also requires confirmed handled-signal blocking. Signal-block setup returns a Boolean and callers defensively treat a false value or injected exception as false, while still invoking no-throw owned-process cleanup. A broad post-owned exception always publishes no status. Unconfirmed cleanup or an exception publishes no final status and exits `125`; any unconfirmed prerequisite also exits `125`. The controller emits only the existing generic failure, and no subsequent normal or provisioning operation continues. Only the existing `always()` finalization/artifact-upload steps and hosted-runner teardown may execute. Raw assist payload, secrets, device connection data, and the new `ASSIST_DIAGNOSTIC_*` fields never enter artifacts; those fields remain in the current-step log only. The existing sanitized CLI diagnostics may be uploaded by the `always()` artifact step. OS-level residue may remain unconfirmed; no absolute cleanup claim is made.
- Current GitHub-hosted macOS runner teardown is external containment after job failure. If reused/self-hosted execution is ever adopted, the runner must be quarantined and not reused until an operator confirms no residue.
- Stop after the diagnostic live run. Do not implement a root-cause fix until the evidence is reviewed and the design is amended when required.
- End each implementation task with an independent code-review gate. Resolve all Critical and Important findings before the next task.
- Use Conventional Commits.

---

## Review follow-up: deadline checkpoints and poll failure

After every bounded child returns, first require a readable, grammar-valid safe
status. An absent or invalid status fails closed through the caller's generic
error even if the deadline has expired. After that validation, read the
monotonic clock. If the absolute deadline has expired, classify that one
attempt as `timeout`/`timeout` without trusting the child payload; the
classifier may retain only the safe byte count before private-file truncation.
Read the clock again after classifier-record framing and category/exit
validation, and again after accounting and cleanup immediately before emitting
`ASSIST_STATE=enabled`. An expiry at any checkpoint replaces that attempt's
category with `timeout` and safe exit with `timeout`, accounts for it exactly
once, and stops the window without a late success. `wait_uuremote_poll` must have stderr
redirected to `/dev/null`; a nonzero poll result fails closed through the
existing outer generic failure and cannot hot-loop.

Tests use three independently controlled clock crossings (after child, after
record validation, and before enabled acceptance), isolated mutations removing
each checkpoint, and a hostile poll-failure fixture. The runner-plan AST parity
test is separate from semantic-contract mutations, so each semantic mutation
is evaluated by the semantic assertions rather than failing only parity.

---

### Task 1: Add the strict safe response classifier

**Files:**
- Modify: `.github/workflows/apple.sh:820-915`
- Create: `tests/macos_assist_allow_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py`

**Interfaces:**
- Consumes: response file path, execution state `completed|timeout|unavailable`, and CLI exit `0..255|unavailable`.
- Produces: `classify_assist_allow_response OUTPUT_PATH EXECUTION_STATE CLI_EXIT`, which writes exactly one tab-separated record: `CATEGORY<TAB>RESPONSE_BYTES<TAB>SAFE_EXIT`.
- Categories: `timeout`, `cli-nonzero`, `empty`, `invalid-utf8`, `invalid-json`, `not-object`, `success-missing`, `success-wrong-type`, `success-false`, `enabled-missing`, `enabled-wrong-type`, `enabled-false`, `enabled-true`.

- [ ] **Step 1: Write the failing table-driven classifier tests**

Add the harness constant and test class to `tests/test_uuremote_desktop_finalization.py`:

```python
MACOS_ASSIST_ALLOW_HARNESS_PATH = ROOT / "tests/macos_assist_allow_harness.sh"


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSAssistAllowClassifierTests(unittest.TestCase):
    def run_scenario(self, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), "classify", scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_every_response_shape_has_one_safe_category(self):
        cases = {
            "timeout": ("timeout", "timeout"),
            "cli-nonzero": ("cli-nonzero", "17"),
            "empty": ("empty", "0"),
            "invalid-utf8": ("invalid-utf8", "0"),
            "invalid-json": ("invalid-json", "0"),
            "not-object": ("not-object", "0"),
            "success-missing": ("success-missing", "0"),
            "success-wrong-type": ("success-wrong-type", "0"),
            "success-false": ("success-false", "0"),
            "enabled-missing": ("enabled-missing", "0"),
            "enabled-wrong-type": ("enabled-wrong-type", "0"),
            "enabled-false": ("enabled-false", "0"),
            "enabled-true": ("enabled-true", "0"),
            "duplicate-key": ("invalid-json", "0"),
            "nan": ("invalid-json", "0"),
        }
        for scenario, (category, safe_exit) in cases.items():
            with self.subTest(scenario=scenario):
                result = self.run_scenario(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                fields = result.stdout.strip().split("\t")
                self.assertEqual(fields[0], category)
                self.assertTrue(fields[1].isdigit())
                self.assertEqual(fields[2], safe_exit)
                self.assertEqual(len(fields), 3)

    def test_classifier_never_emits_fixture_values(self):
        result = self.run_scenario("hostile-enabled-false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split("\t", 1)[0], "enabled-false")
        self.assertNotIn("CustomCodeFixture", result.stdout + result.stderr)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
        self.assertNotIn("FORGED_OUTPUT", result.stdout + result.stderr)
```

Create `tests/macos_assist_allow_harness.sh`. Like `tests/macos_readiness_harness.sh`, extract the production-function prefix from `apple.sh`, replace `/usr/bin/python3` only when the host lacks that absolute path, build each exact byte fixture, and call the real production classifier. The scenario table must use these payloads:

```bash
case "$scenario" in
    timeout) execution_state=timeout; cli_exit=unavailable; : >"$response_path" ;;
    cli-nonzero) execution_state=completed; cli_exit=17; printf 'vendor failure' >"$response_path" ;;
    empty) execution_state=completed; cli_exit=0; : >"$response_path" ;;
    invalid-utf8) execution_state=completed; cli_exit=0; printf '\377' >"$response_path" ;;
    invalid-json) execution_state=completed; cli_exit=0; printf '{' >"$response_path" ;;
    not-object) execution_state=completed; cli_exit=0; printf '[]' >"$response_path" ;;
    success-missing) execution_state=completed; cli_exit=0; printf '{"enabled":true}' >"$response_path" ;;
    success-wrong-type) execution_state=completed; cli_exit=0; printf '{"success":"true","enabled":true}' >"$response_path" ;;
    success-false) execution_state=completed; cli_exit=0; printf '{"success":false,"enabled":true}' >"$response_path" ;;
    enabled-missing) execution_state=completed; cli_exit=0; printf '{"success":true}' >"$response_path" ;;
    enabled-wrong-type) execution_state=completed; cli_exit=0; printf '{"success":true,"enabled":1}' >"$response_path" ;;
    enabled-false) execution_state=completed; cli_exit=0; printf '{"success":true,"enabled":false}' >"$response_path" ;;
    enabled-true) execution_state=completed; cli_exit=0; printf '{"success":true,"enabled":true}' >"$response_path" ;;
    duplicate-key) execution_state=completed; cli_exit=0; printf '{"success":true,"success":false,"enabled":true}' >"$response_path" ;;
    nan) execution_state=completed; cli_exit=0; printf '{"success":true,"enabled":NaN}' >"$response_path" ;;
    hostile-enabled-false)
        execution_state=completed
        cli_exit=0
        printf '{"success":true,"enabled":false,"deviceId":"device-id-fixture\\nFORGED_OUTPUT=true","customCode":"CustomCodeFixture"}' >"$response_path"
        ;;
    *) exit 2 ;;
esac

classify_assist_allow_response "$response_path" "$execution_state" "$cli_exit"
```

- [ ] **Step 2: Run the classifier tests to verify RED**

Run:

```bash
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests -v
```

Expected: FAIL because `classify_assist_allow_response` does not exist.

- [ ] **Step 3: Implement the minimum strict classifier**

Add this Bash/Python boundary before `wait_for_uuremote_cli_true_field` in `.github/workflows/apple.sh`:

```bash
classify_assist_allow_response() {
    local output_path="$1"
    local execution_state="$2"
    local cli_exit="$3"
    local response_bytes

    response_bytes="$(/usr/bin/wc -c <"$output_path" | /usr/bin/tr -d '[:space:]')"
    case "$response_bytes" in
        ''|*[!0-9]*) return 2 ;;
    esac

    case "$execution_state" in
        timeout)
            printf 'timeout\t%s\ttimeout\n' "$response_bytes"
            return 0
            ;;
        unavailable)
            printf 'cli-nonzero\t%s\tunavailable\n' "$response_bytes"
            return 0
            ;;
        completed)
            ;;
        *)
            return 2
            ;;
    esac

    case "$cli_exit" in
        ''|*[!0-9]*) return 2 ;;
    esac
    if [ "$cli_exit" -gt 255 ]; then
        return 2
    fi
    if [ "$cli_exit" -ne 0 ]; then
        printf 'cli-nonzero\t%s\t%s\n' "$response_bytes" "$cli_exit"
        return 0
    fi

    /usr/bin/python3 - "$output_path" "$response_bytes" <<'PYTHON'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
response_bytes = sys.argv[2]
raw = path.read_bytes()

def emit(category):
    print(f"{category}\t{response_bytes}\t0")
    raise SystemExit(0)

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result

def reject_nonstandard_constant(_value):
    raise ValueError

if not raw:
    emit("empty")
try:
    decoded = raw.decode("utf-8")
except UnicodeDecodeError:
    emit("invalid-utf8")
try:
    payload = json.loads(
        decoded,
        object_pairs_hook=reject_duplicate_keys,
        parse_constant=reject_nonstandard_constant,
    )
except (json.JSONDecodeError, ValueError):
    emit("invalid-json")
if not isinstance(payload, dict):
    emit("not-object")
if "success" not in payload:
    emit("success-missing")
if type(payload["success"]) is not bool:
    emit("success-wrong-type")
if payload["success"] is not True:
    emit("success-false")
if "enabled" not in payload:
    emit("enabled-missing")
if type(payload["enabled"]) is not bool:
    emit("enabled-wrong-type")
if payload["enabled"] is not True:
    emit("enabled-false")
emit("enabled-true")
PYTHON
}
```

- [ ] **Step 4: Run focused and existing redaction tests to verify GREEN**

Run:

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests \
  tests.test_uuremote_desktop_finalization.MacOSDiagnosticRedactionTests -v
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
```

Expected: all focused tests PASS, both shell scripts parse, and no fixture marker is emitted.

- [ ] **Step 5: Request independent review and commit**

Review only Task 1 for strict JSON behavior, one-category output, Bash 3.2 compatibility, and nonleakage. Resolve Critical and Important findings, rerun Step 4, then commit:

```bash
git add .github/workflows/apple.sh tests/macos_assist_allow_harness.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: classify macOS unattended responses"
```

---

### Task 2: Add the bounded GUI child-process boundary

**Files:**
- Modify: `.github/workflows/apple.sh:300-410`
- Modify: `tests/macos_assist_allow_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py`

**Interfaces:**
- Consumes: existing `run_bounded_uuremote_cli_to_file`, resolved `console_uid`, an output path, a safe-status path, timeout milliseconds, and command arguments.
- Produces: `run_bounded_uuremote_cli_to_file_with_status OUTPUT STATUS TIMEOUT COMMAND...` and `run_bounded_gui_cli_to_file OUTPUT STATUS TIMEOUT COMMAND...`.
- Safe status file contains exactly `completed:0..255`, `timeout`, or `unavailable`.

- [ ] **Step 1: Add failing completed, nonzero, and hanging-child behavior tests**

Extend the harness with `process completed`, `process nonzero`, and `process timeout`. The timeout fixture must write its PID and a descendant PID to caller-provided files, ignore `TERM`, and block:

```bash
if [ "${1:-}" = "fixture-hang" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; while :; do sleep 1; done' \
        fixture-child "${3:?}" &
    trap '' TERM
    while :; do sleep 1; done
fi
```

Add tests that assert:

```python
def test_completed_process_records_exact_safe_status(self):
    result = self.run_harness("process", "completed")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(result.stdout, "STATUS=completed:0\n")

def test_nonzero_process_records_exact_safe_status(self):
    result = self.run_harness("process", "nonzero")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(result.stdout, "STATUS=completed:17\n")

def test_hanging_process_group_is_terminated_and_reaped(self):
    started = time.monotonic()
    result = self.run_harness("process", "timeout")
    elapsed = time.monotonic() - started
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertLess(elapsed, 5)
    self.assertEqual(result.stdout, "STATUS=timeout\nPROCESS_GROUP_RELEASED=true\n")
```

- [ ] **Step 2: Run the process tests to verify RED**

Run:

```bash
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests -v
```

Expected: FAIL because the status-aware and GUI-bounded functions do not exist.

- [ ] **Step 3: Refactor the existing runner into a status-aware core and GUI wrapper**

Keep the current Python subprocess implementation, but add a safe status-path argument. The safe-status publisher returns `False` if it cannot publish. Launch or other no-owned-process failures may publish `unavailable`; after owned cleanup is required, only a confirmed cleanup branch may publish `timeout` or `unavailable`, and an unconfirmed cleanup or cleanup exception publishes no final status and exits `125`.

```python
def write_status(value):
    try:
        if str(status_path) == os.devnull:
            with open(os.devnull, "w", encoding="ascii") as status:
                status.write(value + "\n")
            return True
        temporary_status_path = status_path.with_name(status_path.name + ".tmp")
        descriptor = os.open(
            temporary_status_path,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as status:
            status.write(value + "\n")
        os.replace(temporary_status_path, status_path)
    except OSError:
        return False
    return True
```

Expose these Bash wrappers:

```bash
run_bounded_uuremote_cli_to_file_with_status() {
    local output_path="$1"
    local status_path="$2"
    local timeout_milliseconds="$3"
    shift 3

    if ! [[ "$timeout_milliseconds" =~ ^[0-9]+$ ]] ||
        [ "$timeout_milliseconds" -lt 1 ] || [ "$#" -eq 0 ]; then
        return 2
    fi

    /usr/bin/python3 - \
        "$output_path" "$status_path" "$timeout_milliseconds" "$@" <<'PYTHON'
import os
import pathlib
import signal
import subprocess
import sys
import time

output_path = sys.argv[1]
status_path = pathlib.Path(sys.argv[2])
timeout_seconds = int(sys.argv[3]) / 1000
command = sys.argv[4:]

def write_status(value):
    try:
        if str(status_path) == os.devnull:
            with open(os.devnull, "w", encoding="ascii") as status:
                status.write(value + "\n")
            return True
        temporary_status_path = status_path.with_name(status_path.name + ".tmp")
        descriptor = os.open(
            temporary_status_path,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as status:
            status.write(value + "\n")
        os.replace(temporary_status_path, status_path)
    except OSError:
        return False
    return True

class HandledSignal(Exception):
    pass

process = None
process_group_id = None
previous_handlers = {}
previous_signal_mask = None
handled_signals = tuple(
    getattr(signal, name)
    for name in ("SIGINT", "SIGTERM", "SIGHUP")
    if hasattr(signal, name)
)

def signal_process_group(signal_number):
    if os.name == "nt":
        if signal_number == signal.SIGTERM:
            process.terminate()
        else:
            process.kill()
    else:
        os.killpg(process_group_id, signal_number)

def process_group_alive():
    if os.name == "nt":
        return None
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    return True

def cleanup_owned_process():
    cleanup_confirmed = False
    try:
        signal_process_group(signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass

    try:
        group_remains = process_group_alive()
    except OSError:
        group_remains = None

    if group_remains is False:
        return process.poll() is not None

    try:
        signal_process_group(signal.SIGKILL)
    except ProcessLookupError:
        pass
    cleanup_deadline = time.monotonic() + 0.5
    try:
        process.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        return False

    if group_remains is None:
        return False
    while time.monotonic() < cleanup_deadline:
        try:
            if not process_group_alive():
                cleanup_confirmed = True
                break
        except OSError:
            break
        time.sleep(0.01)
    else:
        try:
            cleanup_confirmed = not process_group_alive()
        except OSError:
            pass
    return cleanup_confirmed

cleanup_in_progress = False
cleanup_signal_mask = None
owned_cleanup_required = False

def cleanup_owned_process_no_throw():
    try:
        return cleanup_owned_process()
    except Exception:
        return False

def release_owned_process_if_confirmed(cleanup_confirmed):
    global owned_cleanup_required
    if cleanup_confirmed:
        owned_cleanup_required = False
    return cleanup_confirmed

def interrupt_handler(_signum, _frame):
    if cleanup_in_progress:
        return
    raise HandledSignal

def block_handled_signals_for_cleanup():
    global cleanup_signal_mask
    try:
        if os.name != "nt" and hasattr(signal, "pthread_sigmask"):
            cleanup_signal_mask = signal.pthread_sigmask(
                signal.SIG_BLOCK,
                handled_signals,
            )
    except Exception:
        return False
    return True

def cleanup_owned_process_after_signal_block():
    try:
        signal_blocked = block_handled_signals_for_cleanup() is True
    except Exception:
        signal_blocked = False
    cleanup_confirmed = release_owned_process_if_confirmed(
        cleanup_owned_process_no_throw(),
    )
    return signal_blocked and cleanup_confirmed

exit_code = 125

try:
    if os.name != "nt" and hasattr(signal, "pthread_sigmask"):
        previous_signal_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK,
            handled_signals,
        )
    for handled_signal in handled_signals:
        try:
            previous_handlers[handled_signal] = signal.signal(
                handled_signal,
                interrupt_handler,
            )
        except ValueError:
            pass
    output_descriptor = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o600,
    )
    popen_options = {}
    if previous_signal_mask is not None:
        def restore_child_signal_mask():
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        popen_options["preexec_fn"] = restore_child_signal_mask
    with os.fdopen(output_descriptor, "wb") as output:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            **popen_options,
        )
        process_group_id = process.pid
        owned_cleanup_required = True
    if previous_signal_mask is not None:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        previous_signal_mask = None
    try:
        return_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        cleanup_in_progress = True
        if cleanup_owned_process_after_signal_block():
            write_status("timeout")
            exit_code = 124
        else:
            exit_code = 125
    else:
        try:
            group_remains = process_group_alive()
        except OSError:
            group_remains = True
        if group_remains is True:
            cleanup_in_progress = True
            if cleanup_owned_process_after_signal_block():
                write_status("unavailable")
            exit_code = 125
        else:
            safe_return_code = return_code if 0 <= return_code <= 255 else 1
            owned_cleanup_required = False
            write_status(f"completed:{safe_return_code}")
            exit_code = safe_return_code
except HandledSignal:
    cleanup_in_progress = True
    if cleanup_owned_process_after_signal_block():
        write_status("unavailable")
    exit_code = 125
except Exception:
    cleanup_in_progress = True
    cleanup_owned_process_after_signal_block()
    exit_code = 125
finally:
    cleanup_in_progress = True
    if cleanup_signal_mask is not None:
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, cleanup_signal_mask)
        except Exception:
            pass
    elif previous_signal_mask is not None:
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        except Exception:
            pass
    for handled_signal, previous_handler in previous_handlers.items():
        try:
            signal.signal(handled_signal, previous_handler)
        except Exception:
            pass

raise SystemExit(exit_code)
PYTHON
}

run_bounded_uuremote_cli_to_file() {
    local output_path="$1"
    local timeout_milliseconds="$2"
    shift 2
    run_bounded_uuremote_cli_to_file_with_status \
        "$output_path" /dev/null "$timeout_milliseconds" "$@"
}

run_bounded_gui_cli_to_file() {
    local output_path="$1"
    local status_path="$2"
    local timeout_milliseconds="$3"
    shift 3
    run_bounded_uuremote_cli_to_file_with_status \
        "$output_path" "$status_path" "$timeout_milliseconds" \
        /usr/bin/sudo /bin/launchctl asuser "$console_uid" \
        /usr/bin/sudo -u "#$console_uid" "$@"
}
```

The `/dev/null` branch writes directly instead of attempting atomic replacement. Preserve all current device-ID runner exit behavior.

- [ ] **Step 4: Run new process tests and existing bounded-runner regressions**

Run:

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests \
  tests.test_uuremote_desktop_finalization.MacOSReadinessBehaviorTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests -v
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
```

Expected: all tests PASS; the real hanging process group is gone before the harness returns.

- [ ] **Step 5: Request independent review and commit**

Review Task 2 for exact process ownership, timeout, `TERM`/`KILL`, bounded post-kill waits, atomic safe-status writes, `/dev/null` compatibility, GUI session invocation, and preservation of device-ID behavior. Resolve Critical and Important findings, rerun Step 4, then commit:

```bash
git add .github/workflows/apple.sh tests/macos_assist_allow_harness.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: bound macOS unattended CLI calls"
```

---

### Task 3: Aggregate the 60-second window and emit debug-only safe diagnostics

**Files:**
- Modify: `.github/workflows/apple.sh:860-915, 2489-2500`
- Modify: `tests/macos_assist_allow_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py`

**Interfaces:**
- Consumes: Task 1 classifier, Task 2 GUI boundary, `uuremote_now_milliseconds`, `wait_uuremote_poll`, `debug_level`, installed `$CLI`, and resolved `console_uid`.
- Produces: `report_assist_allow_diagnostics` and a rewritten `ensure_assist_allowed` with fixed defaults `60`, `3000`, and `500`.
- Success output: exactly `ASSIST_STATE=enabled` from the helper.
- Failure output: full fixed summary only for debug `1|2|3`; the existing caller then prints the existing generic error.

- [ ] **Step 1: Add failing aggregation, debug-gate, deadline, cleanup, and redaction tests**

Extend the harness with controlled clock and boundary functions. Stub only time, sleep, and process execution; call the real production classifier, accumulator, and reporter. Add these scenarios:

```text
transient-success: invalid-json, enabled-false, enabled-true before deadline
debug0-failure: enabled-false until deadline
debug1-failure: invalid-json, enabled-false until deadline
debug2-failure: same sequence under debug 2
debug3-failure: same sequence under debug 3
late-success: enabled-true returned after the controlled deadline
internal-invalid-record: boundary supplies a classifier record with an invalid enum
hostile-failure: responses contain custom-code/device-ID/forged-log markers
```

Add tests with exact success and failure contracts:

```python
def test_transient_failures_then_success_emit_only_success(self):
    result = self.run_harness("aggregate", "transient-success")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(result.stdout, "ASSIST_STATE=enabled\n")

def test_debug_zero_failure_is_generic_only(self):
    result = self.run_harness("aggregate", "debug0-failure")
    self.assertEqual(result.returncode, 1)
    self.assertEqual(result.stdout, "")
    self.assertEqual(
        result.stderr,
        "Could not enable unattended control within 60 seconds\n",
    )

def test_debug_levels_emit_complete_fixed_summary(self):
    field_names = [
        "ASSIST_DIAGNOSTIC_ATTEMPTS",
        "ASSIST_DIAGNOSTIC_TIMEOUT_COUNT",
        "ASSIST_DIAGNOSTIC_CLI_NONZERO_COUNT",
        "ASSIST_DIAGNOSTIC_EMPTY_COUNT",
        "ASSIST_DIAGNOSTIC_INVALID_UTF8_COUNT",
        "ASSIST_DIAGNOSTIC_INVALID_JSON_COUNT",
        "ASSIST_DIAGNOSTIC_NOT_OBJECT_COUNT",
        "ASSIST_DIAGNOSTIC_SUCCESS_MISSING_COUNT",
        "ASSIST_DIAGNOSTIC_SUCCESS_WRONG_TYPE_COUNT",
        "ASSIST_DIAGNOSTIC_SUCCESS_FALSE_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_MISSING_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_WRONG_TYPE_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_FALSE_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT",
        "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MIN",
        "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MAX",
        "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_FINAL",
        "ASSIST_DIAGNOSTIC_FINAL_CATEGORY",
        "ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT",
    ]
    for level in (1, 2, 3):
        result = self.run_harness("aggregate", f"debug{level}-failure")
        self.assertEqual(result.returncode, 1)
        lines = result.stderr.splitlines()
        self.assertEqual([line.split("=", 1)[0] for line in lines[:-1]], field_names)
        self.assertEqual(lines[-1], "Could not enable unattended control within 60 seconds")
        counts = {
            line.split("=", 1)[0]: line.split("=", 1)[1]
            for line in lines[:-1]
        }
        category_total = sum(
            int(value) for key, value in counts.items() if key.endswith("_COUNT")
        )
        self.assertEqual(category_total, int(counts["ASSIST_DIAGNOSTIC_ATTEMPTS"]))

def test_late_success_fails_and_temporary_tree_is_empty(self):
    result = self.run_harness("aggregate", "late-success")
    self.assertEqual(result.returncode, 1)
    self.assertIn("ASSIST_DIAGNOSTIC_ATTEMPTS=1", result.stderr)
    self.assertIn("ASSIST_DIAGNOSTIC_TIMEOUT_COUNT=1", result.stderr)
    self.assertIn("ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=0", result.stderr)
    self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CATEGORY=timeout", result.stderr)
    self.assertIn("ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=timeout", result.stderr)
    self.assertIn("TEMPORARY_TREE_EMPTY=true", result.stdout)

def test_hostile_responses_never_reach_logs_or_artifacts(self):
    result = self.run_harness("aggregate", "hostile-failure")
    self.assertEqual(result.returncode, 1)
    combined = result.stdout + result.stderr
    for marker in ("CustomCodeFixture", "device-id-fixture", "FORGED_OUTPUT"):
        self.assertNotIn(marker, combined)
```

Add a workflow/source contract proving that `UUREMOTE_DEBUG` remains job-scoped, the permission step invokes only `apple.sh`, and no `ASSIST_DIAGNOSTIC_` token occurs in the upload step or artifact path construction.

- [ ] **Step 2: Run the aggregation suite to verify RED**

Run:

```bash
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
```

Expected: FAIL because `ensure_assist_allowed` still uses attempt count rather than an absolute deadline and does not aggregate or report safe fields.

- [ ] **Step 3: Implement the safe reporter with explicit validation**

Implement `report_assist_allow_diagnostics` with explicit positional integer arguments in the exact field order asserted above. Validate every count with `case "$value" in ''|*[!0-9]*) return 2 ;; esac`, validate final category against the 13 allowed enums, and validate final exit against `timeout|unavailable|0..255` before the first `printf`.

Implement the complete reporter as follows:

```bash
report_assist_allow_diagnostics() {
    [ "$#" -eq 19 ] || return 2
    local attempts="$1" timeout_count="$2" cli_nonzero_count="$3"
    local empty_count="$4" invalid_utf8_count="$5" invalid_json_count="$6"
    local not_object_count="$7" success_missing_count="$8"
    local success_wrong_type_count="$9"
    shift 9
    local success_false_count="$1" enabled_missing_count="$2"
    local enabled_wrong_type_count="$3" enabled_false_count="$4"
    local enabled_true_count="$5" response_bytes_min="$6"
    local response_bytes_max="$7" response_bytes_final="$8"
    local final_category="$9"
    shift 9
    local final_cli_exit="$1" value

    for value in \
        "$attempts" "$timeout_count" "$cli_nonzero_count" "$empty_count" \
        "$invalid_utf8_count" "$invalid_json_count" "$not_object_count" \
        "$success_missing_count" "$success_wrong_type_count" "$success_false_count" \
        "$enabled_missing_count" "$enabled_wrong_type_count" \
        "$enabled_false_count" "$enabled_true_count" \
        "$response_bytes_min" "$response_bytes_max" "$response_bytes_final"
    do
        case "$value" in
            ''|*[!0-9]*) return 2 ;;
        esac
    done
    case "$final_category" in
        timeout|cli-nonzero|empty|invalid-utf8|invalid-json|not-object|\
        success-missing|success-wrong-type|success-false|enabled-missing|\
        enabled-wrong-type|enabled-false|enabled-true)
            ;;
        *) return 2 ;;
    esac
    case "$final_cli_exit" in
        timeout|unavailable) ;;
        ''|*[!0-9]*) return 2 ;;
        *) [ "$final_cli_exit" -le 255 ] || return 2 ;;
    esac

    printf 'ASSIST_DIAGNOSTIC_ATTEMPTS=%s\n' "$attempts"
    printf 'ASSIST_DIAGNOSTIC_TIMEOUT_COUNT=%s\n' "$timeout_count"
    printf 'ASSIST_DIAGNOSTIC_CLI_NONZERO_COUNT=%s\n' "$cli_nonzero_count"
    printf 'ASSIST_DIAGNOSTIC_EMPTY_COUNT=%s\n' "$empty_count"
    printf 'ASSIST_DIAGNOSTIC_INVALID_UTF8_COUNT=%s\n' "$invalid_utf8_count"
    printf 'ASSIST_DIAGNOSTIC_INVALID_JSON_COUNT=%s\n' "$invalid_json_count"
    printf 'ASSIST_DIAGNOSTIC_NOT_OBJECT_COUNT=%s\n' "$not_object_count"
    printf 'ASSIST_DIAGNOSTIC_SUCCESS_MISSING_COUNT=%s\n' "$success_missing_count"
    printf 'ASSIST_DIAGNOSTIC_SUCCESS_WRONG_TYPE_COUNT=%s\n' "$success_wrong_type_count"
    printf 'ASSIST_DIAGNOSTIC_SUCCESS_FALSE_COUNT=%s\n' "$success_false_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_MISSING_COUNT=%s\n' "$enabled_missing_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_WRONG_TYPE_COUNT=%s\n' "$enabled_wrong_type_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_FALSE_COUNT=%s\n' "$enabled_false_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=%s\n' "$enabled_true_count"
    printf 'ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MIN=%s\n' "$response_bytes_min"
    printf 'ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MAX=%s\n' "$response_bytes_max"
    printf 'ASSIST_DIAGNOSTIC_RESPONSE_BYTES_FINAL=%s\n' "$response_bytes_final"
    printf 'ASSIST_DIAGNOSTIC_FINAL_CATEGORY=%s\n' "$final_category"
    printf 'ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=%s\n' "$final_cli_exit"
}
```

- [ ] **Step 4: Rewrite `ensure_assist_allowed` around one monotonic deadline**

Make the function a subshell so cleanup traps cannot leak. Create one private temporary directory containing `response` and `status`, both mode `0600`. Use Bash 3.2-compatible scalar counters, not associative arrays.

The control flow must be:

```bash
ensure_assist_allowed() (
    local deadline now remaining attempt_timeout sleep_timeout record
    local category response_bytes safe_exit extra_field category_total
    local execution_state execution_exit status_record
    local assist_temp_dir="" response_path="" status_path=""
    local attempts=0
    local timeout_count=0 cli_nonzero_count=0 empty_count=0
    local invalid_utf8_count=0 invalid_json_count=0 not_object_count=0
    local success_missing_count=0 success_wrong_type_count=0 success_false_count=0
    local enabled_missing_count=0 enabled_wrong_type_count=0
    local enabled_false_count=0 enabled_true_count=0
    local response_bytes_min="" response_bytes_max=0 response_bytes_final=0
    local final_category=unavailable final_cli_exit=unavailable

    cleanup_assist_attempt() {
        local cleanup_status=0
        if [ -n "$response_path" ]; then
            /bin/rm -f -- "$response_path" || cleanup_status=1
        fi
        if [ -n "$status_path" ]; then
            /bin/rm -f -- "$status_path" "$status_path.tmp" || cleanup_status=1
        fi
        if [ -n "$assist_temp_dir" ]; then
            /bin/rmdir "$assist_temp_dir" 2>/dev/null || cleanup_status=1
        fi
        return "$cleanup_status"
    }

    umask 077
    assist_temp_dir="$(/usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/uuremote-assist-allow.XXXXXX")" || return 1
    trap 'cleanup_assist_attempt || exit 1' EXIT
    /bin/chmod 0700 "$assist_temp_dir" || return 1
    response_path="$assist_temp_dir/response"
    status_path="$assist_temp_dir/status"
    : >"$response_path"
    : >"$status_path"
    /bin/chmod 0600 "$response_path" "$status_path" || return 1

    read_assist_now() {
        now="$(uuremote_now_milliseconds)" || return 1
        case "$now" in
            0) ;;
            [1-9]* ) case "$now" in *[!0-9]*) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    }

    read_assist_now || return 1
    deadline="$((now + 60000))"
    while :; do
        read_assist_now || return 1
        remaining="$((deadline - now))"
        [ "$remaining" -gt 0 ] || break
        attempts="$((attempts + 1))"
        attempt_timeout=3000
        [ "$remaining" -ge "$attempt_timeout" ] || attempt_timeout="$remaining"
        : >"$response_path"
        : >"$status_path"
        run_bounded_gui_cli_to_file \
            "$response_path" "$status_path" "$attempt_timeout" \
            "$CLI" assist allow on >/dev/null 2>/dev/null || true

        status_record="$(/bin/cat "$status_path" 2>/dev/null)" || return 1
        case "$status_record" in
            timeout)
                execution_state=timeout
                execution_exit=unavailable
                ;;
            unavailable)
                execution_state=unavailable
                execution_exit=unavailable
                ;;
            completed:*)
                execution_state=completed
                execution_exit="${status_record#completed:}"
                case "$execution_exit" in
                    ''|*[!0-9]*) return 1 ;;
                esac
                [ "$execution_exit" -le 255 ] || return 1
                ;;
            *)
                return 1
                ;;
        esac

        read_assist_now || return 1
        remaining="$((deadline - now))"
        if [ "$remaining" -le 0 ]; then
            execution_state=timeout
            execution_exit=timeout
        fi

        record="$(classify_assist_allow_response \
            "$response_path" "$execution_state" "$execution_exit")" || return 1
        : >"$response_path"
        IFS=$'\t' read -r category response_bytes safe_exit extra_field <<<"$record"
        [ -z "$extra_field" ] || return 1
        case "$response_bytes" in
            ''|*[!0-9]*) return 1 ;;
        esac
        case "$safe_exit" in
            timeout|unavailable) ;;
            ''|*[!0-9]*) return 1 ;;
            *) [ "$safe_exit" -le 255 ] || return 1 ;;
        esac

        read_assist_now || return 1
        remaining="$((deadline - now))"
        if [ "$remaining" -le 0 ]; then
            category=timeout
            safe_exit=timeout
        fi

        case "$category" in
            timeout) timeout_count="$((timeout_count + 1))" ;;
            cli-nonzero) cli_nonzero_count="$((cli_nonzero_count + 1))" ;;
            empty) empty_count="$((empty_count + 1))" ;;
            invalid-utf8) invalid_utf8_count="$((invalid_utf8_count + 1))" ;;
            invalid-json) invalid_json_count="$((invalid_json_count + 1))" ;;
            not-object) not_object_count="$((not_object_count + 1))" ;;
            success-missing) success_missing_count="$((success_missing_count + 1))" ;;
            success-wrong-type) success_wrong_type_count="$((success_wrong_type_count + 1))" ;;
            success-false) success_false_count="$((success_false_count + 1))" ;;
            enabled-missing) enabled_missing_count="$((enabled_missing_count + 1))" ;;
            enabled-wrong-type) enabled_wrong_type_count="$((enabled_wrong_type_count + 1))" ;;
            enabled-false) enabled_false_count="$((enabled_false_count + 1))" ;;
            enabled-true) enabled_true_count="$((enabled_true_count + 1))" ;;
            *) return 1 ;;
        esac

        if [ "$attempts" -eq 1 ] || [ "$response_bytes" -lt "$response_bytes_min" ]; then
            response_bytes_min="$response_bytes"
        fi
        if [ "$response_bytes" -gt "$response_bytes_max" ]; then
            response_bytes_max="$response_bytes"
        fi
        response_bytes_final="$response_bytes"
        final_category="$category"
        final_cli_exit="$safe_exit"

        if [ "$category" = enabled-true ]; then
            cleanup_assist_attempt || return 1
            read_assist_now || return 1
            remaining="$((deadline - now))"
            if [ "$remaining" -gt 0 ]; then
                trap - EXIT HUP INT TERM
                printf 'ASSIST_STATE=enabled\n'
                return 0
            fi
            enabled_true_count="$((enabled_true_count - 1))"
            timeout_count="$((timeout_count + 1))"
            category=timeout
            safe_exit=timeout
            final_category=timeout
            final_cli_exit=timeout
        fi
        [ "$remaining" -gt 0 ] || break
        sleep_timeout=500
        [ "$remaining" -ge "$sleep_timeout" ] || sleep_timeout="$remaining"
        wait_uuremote_poll "$sleep_timeout" 2>/dev/null || return 1
    done

    [ "$attempts" -gt 0 ] || return 1
    category_total="$((
        timeout_count + cli_nonzero_count + empty_count +
        invalid_utf8_count + invalid_json_count + not_object_count +
        success_missing_count + success_wrong_type_count + success_false_count +
        enabled_missing_count + enabled_wrong_type_count +
        enabled_false_count + enabled_true_count
    ))"
    [ "$category_total" -eq "$attempts" ] || return 1

    if [ "$debug_level" != 0 ]; then
        report_assist_allow_diagnostics \
            "$attempts" "$timeout_count" "$cli_nonzero_count" "$empty_count" \
            "$invalid_utf8_count" "$invalid_json_count" "$not_object_count" \
            "$success_missing_count" "$success_wrong_type_count" "$success_false_count" \
            "$enabled_missing_count" "$enabled_wrong_type_count" \
            "$enabled_false_count" "$enabled_true_count" \
            "$response_bytes_min" "$response_bytes_max" "$response_bytes_final" \
            "$final_category" "$final_cli_exit" >&2 || return 1
    fi
    cleanup_assist_attempt || return 1
    trap - EXIT
    return 1
)
```

Use the exact explicit validation and counter updates above. Do not introduce a test-only cleanup function or copy production classification into the harness.

- [ ] **Step 5: Run focused GREEN, mutation RED/GREEN, and full local regressions**

Run the focused suite:

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
```

Then make two temporary mutations in isolated copies, not the worktree source:

1. Move reporter invocation outside the debug gate; verify the debug-0 test fails.
2. Accept `enabled-true` without the final deadline check; verify the late-success test fails.

Restore the unmodified worktree and run:

```bash
python -m unittest tests.test_uuremote_desktop_finalization tests.test_uuremote_wait -v
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
```

Expected: focused and related suites PASS; both mutations produce the expected RED; shell syntax and redaction harnesses PASS.

- [ ] **Step 6: Request independent review and commit**

Review Task 3 for deadline enforcement, exactly-one-category accounting, Bash 3.2 compatibility, late-success rejection, debug gating, fixed output order, response truncation, cleanup, no artifact write, and preservation of the generic caller failure. Resolve Critical and Important findings, rerun Step 5, then commit:

```bash
git add .github/workflows/apple.sh tests/macos_assist_allow_harness.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: diagnose macOS unattended failures"
```

---

### Task 4: Verify and review the complete diagnostic branch

**Files:**
- Verify: all files changed from `e844ba9..HEAD`
- Create ignored report: `.superpowers/sdd/2026-08-16-macos-unattended-permission-diagnostics/final-review-report.md`

**Interfaces:**
- Consumes: committed Tasks 1 through 3.
- Produces: a clean reviewed commit range ready for an explicitly authorized native diagnostic run.

- [ ] **Step 1: Run fresh focused and full verification**

Run:

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
python -m unittest discover -s tests -v
python -m unittest tests.test_agent_work_environment -v
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
python -m json.tool .claude/settings.json >/dev/null
git diff --check e30a65b..HEAD
```

Expected: currently runnable tests PASS with only explicit platform skips; shell and JSON parsing succeed; diff check has no output.

Run the native macOS cleanup matrix separately. For confirmed timeout cleanup, a completed leader with a live descendant, and handled-signal cleanup, require the existing safe status only after the bounded `TERM`→`KILL`→reap/PGID probe confirms cleanup. For the matching false/raises cleanup-injection cases, require exit `125`, no final status, and the outer caller's existing generic error only; no subsequent normal or provisioning operation continues, while only the existing `always()` finalization/artifact-upload steps and hosted-runner teardown may execute. Record that this proves bounded helper behavior, not absolute absence of OS-level residue.

- [ ] **Step 2: Run security, output, and scope scans**

Run fixed-string and pattern scans over the changed runtime/test files for real credential material, raw vendor payload printing, device-ID output inside assist diagnostics, artifact writes containing `ASSIST_DIAGNOSTIC_`, unbounded `assist allow on`, and forbidden policy changes. Confirm the diff changes only approved helper, focused tests, and bilingual design/plan files.

Record exact commands and outputs in the ignored report. Any ambiguous match must be reviewed manually rather than suppressed.

- [ ] **Step 3: Request whole-branch code review**

Ask an independent reviewer to read the approved design, this plan, the complete `e844ba9..HEAD` diff, and the verification report. The reviewer must report Critical, Important, and Minor findings; validate that the tests execute production decisions; verify the bounded fail-closed cleanup policy and native matrix; and explicitly state whether the branch is safe for a diagnostic live run.

Resolve Critical and Important findings with `superpowers:receiving-code-review`, TDD, a new Conventional Commit, and a fresh rerun of Steps 1 and 2. Repeat review until no Critical or Important findings remain.

- [ ] **Step 4: Verify final commit identity and clean state**

Run:

```bash
git log -1 --oneline
git status --short
git rev-list --count e844ba9..HEAD
```

Expected: exact reviewed HEAD recorded in the report, no tracked worktree changes, and the expected diagnostic commit count.

---

### Task 5: Run the explicitly authorized native diagnostic gate

**Files:**
- Update ignored report: `.superpowers/sdd/2026-08-16-macos-unattended-permission-diagnostics/live-report.md`
- Do not modify tracked files during evidence collection.

**Interfaces:**
- Consumes: exact reviewed feature HEAD and explicit user authorization for both push and workflow dispatch.
- Produces: one native macOS run URL and a safe root-cause category summary. This task does not produce a root-cause fix.

- [ ] **Step 1: Stop and request external-action authorization**

Present the exact branch, commit SHA, remote repository, workflow, and inputs. Obtain explicit user authorization before either external action:

```text
push fix/macos-device-id-readiness to origin
dispatch macos.yml with debug_level=1 and wait_connections_seconds=0
```

Do not infer authorization from plan approval.

- [ ] **Step 2: Reverify and push the exact reviewed commit**

Run:

```bash
git status --short
git log -1 --format=%H
git push -u origin fix/macos-device-id-readiness
```

Expected: clean tracked status and remote branch updated to the exact reviewed SHA. Do not force-push.

- [ ] **Step 3: Dispatch exactly one diagnostic run**

Use the authenticated GitHub Actions interface or:

```bash
gh workflow run macos.yml \
  --ref fix/macos-device-id-readiness \
  -f debug_level=1 \
  -f wait_connections_seconds=0
```

Record the run URL and ID. Do not rerun automatically.

- [ ] **Step 4: Inspect only safe evidence and validate the contract**

If the permission step fails, verify:

- `CLI_STATUS_STATE=ready` occurred before the assist failure;
- all 19 `ASSIST_DIAGNOSTIC_` fields occur exactly once and in fixed order;
- category counts sum to attempts;
- final category and final safe exit are valid enums/numbers;
- the existing generic error follows the summary;
- no raw JSON, custom code, password, forged fixture token, or unrelated connection information appears;
- no diagnostic artifact contains the new fields.

If the step succeeds, verify only `ASSIST_STATE=enabled` appears and no detailed diagnostic field appears.

- [ ] **Step 5: Record the root-cause evidence and stop**

Write the exact safe fields, run URL, commit SHA, step outcome, and cleanup/artifact observations to the ignored live report. Mark one of these outcomes:

```text
PARSER_SHAPE_EVIDENCE
CLI_OR_ENVIRONMENT_EVIDENCE
UNEXPECTED_DIAGNOSTIC_CONTRACT_FAILURE
UNATTENDED_ENABLED
```

Then stop execution and report the evidence to the user. If the result is `PARSER_SHAPE_EVIDENCE`, return to TDD with the observed safe shape and write a root-cause-specific plan amendment. For `CLI_OR_ENVIRONMENT_EVIDENCE` or an unexpected contract failure, return to `superpowers:brainstorming` before proposing any recovery. Do not merge, push `main`, delete the branch, or run another workflow without a new approved hypothesis and explicit authorization.
