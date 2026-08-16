# macOS Device ID Readiness Alignment Implementation Plan

[English](2026-08-16-macos-device-id-readiness.md) | [简体中文](2026-08-16-macos-device-id-readiness-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align macOS UU Remote launch readiness with Windows by moving launch, one 60-second deadline, bounded device-ID polling, and fail-closed output into one `apple.sh launch-and-wait-device` route.

**Architecture:** `macos.yml` becomes a thin delegate. `apple.sh` retains the existing device-ID parser and bounded subprocess boundary, adds injectable internal clock/process/sleep functions, and owns the complete readiness state machine; tests execute the real function definitions with only those external boundaries replaced.

**Tech Stack:** GitHub Actions YAML, Bash 3.2-compatible shell, Python 3 standard library, Python `unittest`, PowerShell 5.1/pwsh compatibility checks, GitHub CLI.

## Global Constraints

- The production readiness deadline is exactly 60 seconds and the poll interval is exactly 500 milliseconds.
- Start UU Remote only when no matching process is running; never restart or replace an existing process.
- Do not wrap the long-running UU Remote application in `gtimeout` or another lifetime timeout.
- Every CLI attempt receives no more than the remaining overall budget; an owned hung child is terminated and reaped.
- Successful readiness stdout is exactly one `DEVICE_ID=<validated ID>` line immediately followed by one `DEVICE_ID_STATE=ready` line.
- A device ID may otherwise appear only in the existing `WAIT_CONNECTIONS DEVICE_ID=<validated ID>` message.
- Account passwords and `UUREMOTE_CUSTOM_CODE` remain secrets; raw CLI stdout and stderr remain non-loggable.
- Debug diagnostics run at most once after final readiness failure and retain their metadata-only output.
- Keep Windows production behavior unchanged.
- Write English documentation first and update the meaning-equivalent Simplified Chinese counterpart in the same commit.
- Use test-driven development, Conventional Commits, independent review after every implementation task, and fresh verification before any push or completion claim.

## File map

- `.github/workflows/apple.sh`: macOS bounded CLI boundary, process launch/probe boundaries, monotonic deadline controller, routing, and sanitized errors.
- `.github/workflows/macos.yml`: single production launch/readiness delegation and debug-only failure diagnostics.
- `tests/macos_readiness_harness.sh`: controlled executable harness that loads the real readiness functions and replaces only external clock/process/CLI/sleep boundaries.
- `tests/test_uuremote_desktop_finalization.py`: macOS workflow structure and readiness behavior entry tests.
- `tests/test_macos_device_id_logging.sh`: real parser/bounded-process fixtures, including hanging-child cleanup and unsafe-output non-leakage.
- `tests/test_agent_work_environment.py`: cross-document requirements preventing the obsolete YAML-owned 120-attempt contract from returning.
- `docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md` and `-zh_CN.md`: earlier public-log design wording updated to the helper-owned controller.
- `docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md` and `-zh_CN.md`: earlier implementation-plan wording marked as superseded by the 2026-08-16 readiness design.

---

### Task 1: Add the helper-owned readiness controller

**Files:**
- Create: `tests/macos_readiness_harness.sh`
- Modify: `tests/test_uuremote_desktop_finalization.py`
- Modify: `tests/test_macos_device_id_logging.sh`
- Modify: `.github/workflows/apple.sh:4-9,313-486,2018-2075`

**Interfaces:**
- Consumes: `APP`, `CLI`, the existing strict `read_uuremote_device_id` parser, and the existing Python process-group cleanup logic.
- Produces: `run_bounded_uuremote_cli_to_file <output> <timeout-ms> <command...>`, `read_uuremote_device_id [timeout-ms]`, `emit_current_device_id <readiness|wait> [timeout-ms]`, `uuremote_now_milliseconds`, `test_uuremote_application_running`, `start_uuremote_application`, `wait_uuremote_poll <milliseconds>`, `launch_and_wait_device [timeout-seconds] [poll-milliseconds]`, and the zero-argument route `launch-and-wait-device`.

- [ ] **Step 1: Add Python behavior entry tests**

Add `MACOS_READINESS_HARNESS_PATH` and a Bash-gated class to `tests/test_uuremote_desktop_finalization.py`:

```python
MACOS_READINESS_HARNESS_PATH = ROOT / "tests/macos_readiness_harness.sh"

@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSReadinessBehaviorTests(unittest.TestCase):
    def run_scenario(self, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_READINESS_HARNESS_PATH), scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_absent_application_is_started_once_before_transient_success(self):
        result = self.run_scenario("absent-transient-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "DEVICE_ID=device-id-fixture",
                "DEVICE_ID_STATE=ready",
                "ATTEMPTS=3",
                "STARTS=1",
                "SLEEPS=2",
            ],
        )

    def test_existing_application_is_not_restarted(self):
        result = self.run_scenario("existing-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STARTS=0", result.stdout.splitlines())

    def test_deadline_fails_closed_without_late_attempt_or_sleep(self):
        result = self.run_scenario("deadline")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "UU Remote device readiness timed out after 2 attempts.",
                "ATTEMPTS=2 STARTS=0 SLEEPS=1 TIMEOUTS=1000,600",
            ],
        )

    def test_configuration_and_launch_failures_do_not_poll(self):
        cases = {
            "invalid-timing": (
                "UU Remote readiness timing values are invalid.",
                "ATTEMPTS=0 STARTS=0 SLEEPS=0 TIMEOUTS=",
            ),
            "missing-paths": (
                "UU Remote readiness paths are unavailable.",
                "ATTEMPTS=0 STARTS=0 SLEEPS=0 TIMEOUTS=",
            ),
            "launch-failure": (
                "UU Remote application launch failed.",
                "ATTEMPTS=0 STARTS=1 SLEEPS=0 TIMEOUTS=",
            ),
        }
        for scenario, expected in cases.items():
            with self.subTest(scenario=scenario):
                result = self.run_scenario(scenario)
                self.assertEqual(result.returncode, 1 if scenario != "invalid-timing" else 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.splitlines(), list(expected))

class MacOSReadinessSourceTests(unittest.TestCase):
    def test_production_route_uses_fixed_windows_aligned_defaults(self):
        script = text(SCRIPT_PATH)
        route = shell_if_block(
            script,
            'if [ "$mode" = "launch-and-wait-device" ]; then',
        )
        self.assertIn('launch_and_wait_device 60 500', route)
        self.assertIn('/usr/bin/pgrep -x UURemote', script)
        self.assertIn('if [ "$#" -ne 1 ]; then', route)
        self.assertIn('Usage: apple.sh launch-and-wait-device', route)
```

- [ ] **Step 2: Create the controlled harness and observe RED**

Create `tests/macos_readiness_harness.sh`. Copy the production source only through the line before the first bottom-level `if [ "$mode" = "self-test-kcpassword" ]` route, append the following boundary overrides, and invoke the real `launch_and_wait_device` function. The harness must not copy readiness decisions:

```bash
#!/bin/bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/uuremote-readiness-test.XXXXXX")"
subject="$temporary_directory/subject.sh"
fixture_app="$temporary_directory/UURemote.app"
clock_state="$temporary_directory/clock-index"
trap 'rm -rf -- "$temporary_directory"' EXIT

mkdir -p "$fixture_app/Contents/MacOS" "$fixture_app/Contents/Helpers"
printf '#!/bin/bash\nexit 0\n' >"$fixture_app/Contents/MacOS/UURemote"
printf '#!/bin/bash\nexit 0\n' >"$fixture_app/Contents/Helpers/uuyc-cli"
chmod 0700 "$fixture_app/Contents/MacOS/UURemote" \
    "$fixture_app/Contents/Helpers/uuyc-cli"
printf '0\n' >"$clock_state"

awk '/^if \[ "\$mode" = "self-test-kcpassword" \]; then$/ { exit } { print }' \
    "$root/.github/workflows/apple.sh" >"$subject"
cat >>"$subject" <<'SUBJECT'
APP="${UUREMOTE_READINESS_FIXTURE_APP:?}"
CLI="$APP/Contents/Helpers/uuyc-cli"
scenario="${1:?}"
clock_state="${UUREMOTE_READINESS_CLOCK_STATE:?}"
attempts=0
starts=0
sleeps=0
timeouts=""

case "$scenario" in
    absent-transient-success) clock_values=(0 0 100 100 200 200) ;;
    existing-success) clock_values=(0 0) ;;
    deadline) clock_values=(0 0 400 400 1000) ;;
    invalid-timing|missing-paths|launch-failure) clock_values=() ;;
    *) echo "Unknown readiness scenario" >&2; exit 2 ;;
esac

uuremote_now_milliseconds() {
    local index
    index="$(/bin/cat "$clock_state")"
    if [ "$index" -ge "${#clock_values[@]}" ]; then
        echo "Controlled readiness clock was exhausted" >&2
        return 97
    fi
    printf '%s\n' "${clock_values[$index]}"
    printf '%s\n' "$((index + 1))" >"$clock_state"
}

test_uuremote_application_running() {
    [ "$scenario" != "absent-transient-success" ] &&
        [ "$scenario" != "launch-failure" ]
}

start_uuremote_application() {
    starts="$((starts + 1))"
    [ "$scenario" != "launch-failure" ]
}

wait_uuremote_poll() {
    sleeps="$((sleeps + 1))"
}

emit_current_device_id() {
    [ "$1" = "readiness" ] || return 96
    attempts="$((attempts + 1))"
    if [ -n "$timeouts" ]; then
        timeouts="$timeouts,$2"
    else
        timeouts="$2"
    fi
    case "$scenario" in
        absent-transient-success)
            [ "$attempts" -ge 3 ] || return 1
            ;;
        existing-success)
            ;;
        deadline)
            return 1
            ;;
    esac
    printf 'DEVICE_ID=device-id-fixture\n'
    printf 'DEVICE_ID_STATE=ready\n'
}

set +e
case "$scenario" in
    invalid-timing)
        launch_and_wait_device 0 500
        ;;
    missing-paths)
        /bin/rm -f -- "$CLI"
        launch_and_wait_device 1 500
        ;;
    *)
        launch_and_wait_device 1 500
        ;;
esac
status="$?"
set -e
case "$scenario" in
    absent-transient-success|existing-success)
        printf 'ATTEMPTS=%s\nSTARTS=%s\nSLEEPS=%s\n' \
            "$attempts" "$starts" "$sleeps"
        ;;
    deadline)
        printf 'ATTEMPTS=%s STARTS=%s SLEEPS=%s TIMEOUTS=%s\n' \
            "$attempts" "$starts" "$sleeps" "$timeouts" >&2
        ;;
    invalid-timing|missing-paths|launch-failure)
        printf 'ATTEMPTS=%s STARTS=%s SLEEPS=%s TIMEOUTS=%s\n' \
            "$attempts" "$starts" "$sleeps" "$timeouts" >&2
        ;;
esac
exit "$status"
SUBJECT

UUREMOTE_READINESS_FIXTURE_APP="$fixture_app" \
UUREMOTE_READINESS_CLOCK_STATE="$clock_state" \
    /bin/bash "$subject" "${1:?}"
```

The file-backed clock index survives command-substitution subshells. `absent-transient-success` returns no ID twice and emits the exact pair on attempt 3; `existing-success` reports an already-running process; `deadline` supplies clock values `0,0,400,400,1000`, records timeouts `1000,600`, and exposes any third attempt or second sleep through the exact counter assertion. The three immediate-failure scenarios have no clock values, so any poll fails the harness in addition to failing the counter assertion.

Run:

```bash
/bin/bash tests/macos_readiness_harness.sh absent-transient-success
python -m unittest tests.test_uuremote_desktop_finalization.MacOSReadinessBehaviorTests -v
```

Expected: RED because `launch_and_wait_device` and its external-boundary functions do not exist.

- [ ] **Step 3: Make the bounded CLI timeout consume milliseconds**

Change the boundary signature and Python conversion:

```bash
ASSIST_ID_TIMEOUT_MILLISECONDS=3000

run_bounded_uuremote_cli_to_file() {
    local output_path="$1"
    local timeout_milliseconds="$2"
    shift 2

    if ! [[ "$timeout_milliseconds" =~ ^[0-9]+$ ]] ||
        [ "$timeout_milliseconds" -lt 1 ] || [ "$#" -eq 0 ]; then
        return 2
    fi

    /usr/bin/python3 - "$output_path" "$timeout_milliseconds" "$@" <<'PYTHON'
import os
import signal
import subprocess
import sys

output_path = sys.argv[1]
timeout_seconds = int(sys.argv[2]) / 1000
command = sys.argv[3:]
```

Keep the existing start-new-session, TERM, 0.5-second grace, KILL, wait, and exit normalization code unchanged. Update every production caller found by:

```bash
rg -n "run_bounded_uuremote_cli_to_file" .github/workflows/apple.sh
```

Normal diagnostics and status probes pass `"$ASSIST_ID_TIMEOUT_MILLISECONDS"`; readiness passes its calculated remaining milliseconds.

- [ ] **Step 4: Thread the attempt budget through the existing parser**

Use defaulted optional parameters without changing parser rules:

```bash
read_uuremote_device_id() (
    local timeout_milliseconds="${1:-$ASSIST_ID_TIMEOUT_MILLISECONDS}"
    local device_id_temp_dir=""
    local output_path=""
)

if ! run_bounded_uuremote_cli_to_file \
    "$output_path" "$timeout_milliseconds" "$CLI" assist id
then
    return 1
fi

emit_current_device_id() {
    local context="$1"
    local timeout_milliseconds="${2:-$ASSIST_ID_TIMEOUT_MILLISECONDS}"
    local device_id

    if ! device_id="$(read_uuremote_device_id "$timeout_milliseconds")"; then
        return 1
    fi
}
```

The first fragment replaces the three declarations at the start of `read_uuremote_device_id`; the second replaces only its existing bounded-runner call. The third adds one timeout declaration and replaces only the existing `read_uuremote_device_id` command substitution in `emit_current_device_id`. Leave lines from the cleanup trap through the Python parser, and the complete readiness/wait `case` plus final `unset device_id`, byte-for-byte unchanged.

- [ ] **Step 5: Implement the Windows-aligned controller**

Add Bash 3.2-compatible boundaries and controller before the route table:

```bash
uuremote_now_milliseconds() {
    /usr/bin/python3 -c 'import time; print(time.monotonic_ns() // 1000000)'
}

test_uuremote_application_running() {
    /usr/bin/pgrep -x UURemote >/dev/null 2>&1
}

start_uuremote_application() {
    "$APP/Contents/MacOS/UURemote" >/dev/null 2>&1 &
}

wait_uuremote_poll() {
    /usr/bin/python3 - "$1" <<'PYTHON'
import sys
import time
time.sleep(int(sys.argv[1]) / 1000)
PYTHON
}

launch_and_wait_device() {
    local timeout_seconds="${1:-60}"
    local poll_milliseconds="${2:-500}"
    local deadline now remaining timeout_for_attempt sleep_for_attempt
    local attempts=0

    if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] ||
        ! [[ "$poll_milliseconds" =~ ^[0-9]+$ ]] ||
        [ "$timeout_seconds" -lt 1 ] || [ "$poll_milliseconds" -lt 1 ]; then
        echo "UU Remote readiness timing values are invalid." >&2
        return 2
    fi
    if [ ! -x "$APP/Contents/MacOS/UURemote" ] || [ ! -x "$CLI" ]; then
        echo "UU Remote readiness paths are unavailable." >&2
        return 1
    fi
    if ! test_uuremote_application_running; then
        if ! start_uuremote_application; then
            echo "UU Remote application launch failed." >&2
            return 1
        fi
    fi

    now="$(uuremote_now_milliseconds)"
    deadline="$((now + timeout_seconds * 1000))"
    while true; do
        now="$(uuremote_now_milliseconds)"
        remaining="$((deadline - now))"
        if [ "$remaining" -lt 1 ]; then
            break
        fi
        attempts="$((attempts + 1))"
        timeout_for_attempt="$remaining"
        if emit_current_device_id readiness "$timeout_for_attempt"; then
            return 0
        fi
        now="$(uuremote_now_milliseconds)"
        remaining="$((deadline - now))"
        if [ "$remaining" -lt 1 ]; then
            break
        fi
        sleep_for_attempt="$poll_milliseconds"
        if [ "$remaining" -lt "$sleep_for_attempt" ]; then
            sleep_for_attempt="$remaining"
        fi
        wait_uuremote_poll "$sleep_for_attempt"
    done

    echo "UU Remote device readiness timed out after $attempts attempts." >&2
    return 1
}
```

The production `launch-and-wait-device` route accepts no additional arguments by requiring the script argument count to equal one, prints `Usage: apple.sh launch-and-wait-device` and returns `2` otherwise, and calls `launch_and_wait_device 60 500`. Place it before global application/bootstrap preflight, exactly as the early `report-device-id` and `wait-connections` routes are placed.

- [ ] **Step 6: Extend real CLI cleanup and hostile-output coverage**

In `tests/test_macos_device_id_logging.sh`, update the fixture runner for the new millisecond boundary and keep these real routes executable:

```bash
assert_bounded_hanging_route 1 report-device-id readiness
assert_bounded_hanging_route 1 wait-connections 0
assert_bounded_hanging_route 0 diagnose-device-id
```

Assert every hanging child disappears within two seconds after its route returns, temp roots are empty, and none of `device-id-fixture`, `FORGED_OUTPUT=true`, or `custom-code-fixture` appears in stdout or stderr. Retain every strict JSON, invalid UTF-8, multiline, control, Unicode separator, and mode-`0600` case.

- [ ] **Step 7: Run GREEN and commit**

Run on macOS:

```bash
/bin/bash tests/macos_readiness_harness.sh absent-transient-success
/bin/bash tests/macos_readiness_harness.sh existing-success
/bin/bash tests/macos_readiness_harness.sh deadline
/bin/bash tests/macos_readiness_harness.sh invalid-timing
/bin/bash tests/macos_readiness_harness.sh missing-paths
/bin/bash tests/macos_readiness_harness.sh launch-failure
/bin/bash tests/test_macos_device_id_logging.sh
/bin/bash -n .github/workflows/apple.sh
python -m unittest tests.test_uuremote_desktop_finalization.MacOSReadinessBehaviorTests -v
```

Expected: all scenarios pass, success output is exact and unique, deadline output is generic, hanging children are absent, and Bash syntax passes.

Commit:

```bash
git add .github/workflows/apple.sh tests/macos_readiness_harness.sh tests/test_macos_device_id_logging.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: add bounded macOS device readiness"
```

Request independent review of Task 1. Do not start Task 2 until Critical and Important findings are zero.

---

### Task 2: Delegate the workflow and remove obsolete readiness contracts

**Files:**
- Modify: `.github/workflows/macos.yml:72-100`
- Modify: `tests/test_uuremote_desktop_finalization.py:35-125`
- Modify: `tests/test_agent_work_environment.py`
- Modify: `docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md:89-97`
- Modify: `docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design-zh_CN.md:89-97`
- Modify: `docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md:562-593`
- Modify: `docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md:562-593`

**Interfaces:**
- Consumes: the zero-argument `apple.sh launch-and-wait-device` route and unchanged `diagnose-device-id` route from Task 1.
- Produces: one workflow delegation, exact exit-status propagation, debug-only post-failure diagnostics, and bilingual governing documents with no active 120-attempt/YAML-owned instruction.

- [ ] **Step 1: Replace old workflow assertions with RED contracts**

Replace the 120-attempt expectations in `CustomCodeWorkflowTests` with:

```python
def test_launch_delegates_the_complete_readiness_contract_once(self):
    launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
    self.assertEqual(launch.count("apple.sh launch-and-wait-device"), 1)
    for obsolete in (
        "device_id_ready",
        "for ((i=1; i<=120; i++))",
        "apple.sh report-device-id readiness",
        "gtimeout",
        "brew install coreutils",
    ):
        self.assertNotIn(obsolete, launch)

def test_failed_delegation_runs_diagnostics_only_inside_the_debug_gate(self):
    launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
    outer = shell_if_block(
        launch,
        "if .github/workflows/apple.sh launch-and-wait-device",
    )
    debug = shell_if_block(
        outer,
        'if [ "${UUREMOTE_DEBUG:-0}" != "0" ]; then',
    )
    self.assertEqual(outer.count("apple.sh diagnose-device-id || true"), 1)
    self.assertEqual(debug.count("apple.sh diagnose-device-id || true"), 1)
    self.assertIn('exit "$launch_status"', outer)
```

Retain the existing mutation test, but mutate the new outer block by moving the diagnostic call after the matching debug `fi`; require `assert_failed_diagnostic_contract` to reject it.

Run:

```bash
python -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests -v
```

Expected: RED because YAML still owns launch, `gtimeout`, 120 retries, and readiness state.

- [ ] **Step 2: Add the cross-document RED contract**

In `tests/test_agent_work_environment.py`, read both 2026-08-15 design and plan pairs plus the 2026-08-16 design pair. Require each active description to contain `launch-and-wait-device`, `60-second` or `60 秒`, and `500-millisecond` or `500 毫秒`; reject `Preserve 120 attempts`, `保留 120 attempts`, and statements assigning the production polling loop to `macos.yml`.

Run:

```bash
python -m unittest tests.test_agent_work_environment -v
```

Expected: RED on the earlier bilingual design/plan pair.

- [ ] **Step 3: Replace the YAML-owned loop with one delegation**

Set the Launch GameViewer step body to:

```bash
if .github/workflows/apple.sh launch-and-wait-device
then
    :
else
    launch_status="$?"
    if [ "${UUREMOTE_DEBUG:-0}" != "0" ]; then
        .github/workflows/apple.sh diagnose-device-id || true
    fi
    exit "$launch_status"
fi
```

Remove `ls`, `brew install coreutils`, the direct executable launch, `device_id_ready`, the 120-attempt loop, and its final generic YAML error. Do not alter step order, debug gates, custom-code handling, unattended-readiness verification, diagnostics, finalization, artifacts, or wait-connections behavior.

- [ ] **Step 4: Align the earlier bilingual contracts**

Update English first, then the meaning-equivalent Simplified Chinese counterparts:

- In the 2026-08-15 design §7.2, replace “The `Launch GameViewer` polling loop” with the `apple.sh launch-and-wait-device` ownership, 60-second overall deadline, 500-millisecond poll, launch-if-absent behavior, and persistent application lifetime.
- In the 2026-08-15 plan Task 3 Step 5, state that its former 120-attempt YAML composition is superseded by the approved 2026-08-16 readiness design and point implementation to this plan.
- Preserve the existing public device-ID, wait, diagnostic, secret, and parser requirements word-for-word except where grammar requires changing the owner from YAML to the helper.

- [ ] **Step 5: Run GREEN, bilingual checks, and commit**

Run:

```bash
python -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests tests.test_agent_work_environment -v
/bin/bash -n .github/workflows/apple.sh
git diff --check
```

Expected: workflow and document contracts pass; both language pairs retain exact navigation and counterparts; Bash syntax and diff check pass.

Commit:

```bash
git add .github/workflows/macos.yml tests/test_uuremote_desktop_finalization.py tests/test_agent_work_environment.py docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design-zh_CN.md docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md
git commit -m "feat: delegate macOS device readiness"
```

Request independent review of Task 2. Do not start Task 3 until Critical and Important findings are zero.

---

### Task 3: Verify and review the complete feature branch

**Files:**
- Verify: every file changed since `9542924`
- Write coordination evidence only: `.superpowers/sdd/2026-08-16-macos-device-id-readiness/` (ignored; never commit)
- Modify tracked files only to resolve a reproduced review finding, with its failing test in the same focused commit

**Interfaces:**
- Consumes: Tasks 1-2 commits and the approved 2026-08-16 bilingual design.
- Produces: fresh local evidence, exact platform limitations, security scan results, and a whole-branch review verdict with zero Critical and Important findings.

- [ ] **Step 1: Run macOS-focused behavior and syntax**

On macOS run:

```bash
/bin/bash tests/macos_readiness_harness.sh absent-transient-success
/bin/bash tests/macos_readiness_harness.sh existing-success
/bin/bash tests/macos_readiness_harness.sh deadline
/bin/bash tests/test_macos_device_id_logging.sh
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh
python -m unittest tests.test_uuremote_wait tests.test_uuremote_desktop_finalization -v
```

Expected: every Bash behavior test passes; AppKit-only tests run on macOS; output, cleanup, diagnostics, and workflow contracts are green.

- [ ] **Step 2: Run cross-platform regression checks**

Run:

```powershell
python -m unittest tests.test_windows_parity -v
python -m unittest discover -s tests -v
python -m json.tool .claude/settings.json
git diff --check e30a65b..HEAD
git status --short
```

On Windows, run the three real PNG tests outside an isolated desktop sandbox and parse `windows.ps1` with both Windows PowerShell 5.1 and a PATH-visible pwsh. Expected: all runnable tests pass; only documented `/bin/bash`/AppKit platform skips remain; JSON, parsers, diff, and tracked status are clean.

- [ ] **Step 3: Run security and scope scans**

Run:

```powershell
rg -n "UUREMOTE_ACCOUNT_PASSWORD|UUREMOTE_CUSTOM_CODE|assist set-code" .github/workflows tests
rg -n "DEVICE_ID=|WAIT_CONNECTIONS DEVICE_ID=" .github/workflows tests README.md README-zh_CN.md docs/superpowers
git diff --name-only 9542924..HEAD
```

Manually classify every match. Expected: password/custom-code values are never printed; device IDs appear only at the approved readiness/wait boundaries and fixtures/docs; raw CLI output is absent from retry/error/diagnostic paths; changed files match Tasks 1-2.

- [ ] **Step 4: Request whole-branch review**

Ask an independent reviewer to compare `9542924..HEAD` with both 2026-08-16 design files, execute the real controller harness and hanging-child regression, inspect Bash 3.2 compatibility, check the `if/else` status propagation, and report Critical/Important/Minor findings. Resolve each Critical or Important finding with `superpowers:receiving-code-review`, a reproduced RED, minimal GREEN, a focused Conventional Commit, and re-review. Record any deferred Minor only with explicit user approval.

- [ ] **Step 5: Run verification-before-completion**

Re-run every command from Steps 1-3 after the final review fix. Record exact test counts, skips, runtime versions, commit SHAs, and any host limitation in `.superpowers/sdd/2026-08-16-macos-device-id-readiness/final-review-report.md`. Do not claim readiness for live validation unless the tracked worktree is clean and Critical/Important findings are zero.

---

### Task 4: Run feature-branch and main live acceptance

**Files:**
- No planned tracked changes
- Update coordination evidence only: `.superpowers/sdd/2026-08-16-macos-device-id-readiness/live-report.md` (ignored; never commit)

**Interfaces:**
- Consumes: reviewed feature branch, GitHub CLI authentication, existing repository secrets, and workflow inputs `debug_level=1`, `wait_connections_seconds=0`.
- Produces: one accepted feature-branch macOS run, one accepted `main` macOS run, integrated `main`, and removal of obsolete remote backup branches only after the main run is green.

- [ ] **Step 1: Push the reviewed feature branch**

Run:

```powershell
git push -u origin fix/macos-device-id-readiness
```

Verify the remote SHA equals local `HEAD` before dispatch.

- [ ] **Step 2: Dispatch and inspect feature-branch macOS acceptance**

Run:

```powershell
gh workflow run macos.yml --ref fix/macos-device-id-readiness -f debug_level=1 -f wait_connections_seconds=0
$featureSha = git rev-parse HEAD
$featureRun = gh run list --workflow macos.yml --branch fix/macos-device-id-readiness --event workflow_dispatch --limit 10 --json databaseId,headSha,createdAt | ConvertFrom-Json | Where-Object { $_.headSha -eq $featureSha } | Sort-Object createdAt -Descending | Select-Object -First 1
if ($null -eq $featureRun) { throw "Feature workflow run was not discovered." }
gh run watch $featureRun.databaseId --exit-status
gh run view $featureRun.databaseId --log
```

Accept only when the device-ID test module passes, Launch GameViewer completes within the 60-second contract, the readiness pair occurs exactly once, the workflow advances beyond launch, and logs/artifacts contain no custom code, password, or raw CLI payload. If GitHub's eventual consistency has not exposed the run yet, repeat only the read-only `gh run list` assignment after a short interval. On workflow failure, stop repeated dispatches, retain the branch and safe diagnostics, and use systematic debugging before another run.

- [ ] **Step 3: Finish and integrate the branch**

Use `superpowers:finishing-a-development-branch`. Because the approved design selects direct integration after live acceptance, verify `main` still contains the feature base, then fast-forward it in the primary checkout:

```powershell
git switch main
git merge --ff-only fix/macos-device-id-readiness
git push origin main
```

Do not force-push. Verify local `main`, `origin/main`, and the reviewed feature SHA are identical.

- [ ] **Step 4: Dispatch and inspect main macOS acceptance**

Run:

```powershell
gh workflow run macos.yml --ref main -f debug_level=1 -f wait_connections_seconds=0
$mainSha = git rev-parse HEAD
$mainRun = gh run list --workflow macos.yml --branch main --event workflow_dispatch --limit 10 --json databaseId,headSha,createdAt | ConvertFrom-Json | Where-Object { $_.headSha -eq $mainSha } | Sort-Object createdAt -Descending | Select-Object -First 1
if ($null -eq $mainRun) { throw "Main workflow run was not discovered." }
gh run watch $mainRun.databaseId --exit-status
gh run view $mainRun.databaseId --log
```

Apply the same acceptance criteria as Step 2. The main run, not merely local tests or the feature run, is the release gate.

- [ ] **Step 5: Delete remote backups only after the main run is green**

First verify the exact remote refs and that their commits remain reachable from `origin/main`:

```powershell
git fetch origin --prune
git branch -r --contains origin/fix/macos-diagnostic-exit-code
git branch -r --contains origin/codex/windows-macos-functional-parity
git branch -r --contains origin/fix/macos-device-id-readiness
```

When all three are contained by `origin/main`, delete only these exact remote branches:

```powershell
git push origin --delete fix/macos-diagnostic-exit-code
git push origin --delete codex/windows-macos-functional-parity
git push origin --delete fix/macos-device-id-readiness
```

Remove the local worktree and local feature branch only after confirming `main` is clean and the remote deletions succeeded.

- [ ] **Step 6: Final handoff**

Report both GitHub run links, final `main` SHA, exact test counts, reviewer verdict, deleted branch names, and any remaining external concern. Never include the custom code or account password in the report.
