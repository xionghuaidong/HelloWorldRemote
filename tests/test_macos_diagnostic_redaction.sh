#!/bin/bash
set -euo pipefail
PATH="/usr/bin:/bin:${PATH:-}"

if [ "${UUREMOTE_DIAGNOSTIC_FIXTURE_CLI:-0}" = "1" ]; then
    case "${*:-}" in
        status)
            printf '{"success" : true, "device" : "%s", "customCode" : "%s"}\n' \
                "${UUREMOTE_DIAGNOSTIC_FIXTURE_DEVICE_ID:?}" \
                "${UUREMOTE_DIAGNOSTIC_FIXTURE_CUSTOM_CODE:?}"
            ;;
        "assist id")
            if [ "${UUREMOTE_DIAGNOSTIC_FIXTURE_HANG:-0}" = "1" ]; then
                printf '%s\n' "$$" >"${UUREMOTE_DIAGNOSTIC_FIXTURE_PID_PATH:?}"
                printf '%s %s\n' \
                    "${UUREMOTE_DIAGNOSTIC_FIXTURE_DEVICE_ID:?}" \
                    "${UUREMOTE_DIAGNOSTIC_FIXTURE_CUSTOM_CODE:?}"
                while true; do
                    sleep 30
                done
            fi
            printf '%s\n' "${UUREMOTE_DIAGNOSTIC_FIXTURE_DEVICE_ID:?}"
            ;;
        *)
            exit 2
            ;;
    esac
    exit 0
fi

root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/uuremote-diagnostic-test.XXXXXX")"
fixture_device_id="device-id-fixture-9472"
fixture_custom_code="CodeFixture9472"
diagnostic_log="$temporary_directory/uuremote-diagnostics/diagnostics.log"

cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

RUNNER_TEMP="$temporary_directory" \
UUREMOTE_DIAGNOSTIC_TEST_CLI="$0" \
UUREMOTE_DIAGNOSTIC_FIXTURE_CLI=1 \
UUREMOTE_DIAGNOSTIC_FIXTURE_DEVICE_ID="$fixture_device_id" \
UUREMOTE_DIAGNOSTIC_FIXTURE_CUSTOM_CODE="$fixture_custom_code" \
    /bin/bash "$root/.github/workflows/apple.sh" self-test-diagnostic-redaction

if [ ! -f "$diagnostic_log" ]; then
    echo "Diagnostic redaction self-test did not create the expected artifact" >&2
    exit 1
fi

if grep -Fq -- "$fixture_device_id" "$diagnostic_log"; then
    echo "Diagnostic artifact exposed the fixture device ID" >&2
    exit 1
fi

if grep -Fq -- "$fixture_custom_code" "$diagnostic_log"; then
    echo "Diagnostic artifact exposed the fixture custom code" >&2
    exit 1
fi

grep -Fxq 'CLI_STATUS_STATE=ready' "$diagnostic_log"
grep -Fxq 'CLI_STATUS_EXIT=0' "$diagnostic_log"
grep -Fxq 'DEVICE_ID_STATE=ready' "$diagnostic_log"
grep -Fxq 'DEVICE_ID_EXIT=0' "$diagnostic_log"

hanging_directory="$temporary_directory/hanging"
hanging_pid_path="$temporary_directory/hanging-cli.pid"
mkdir -p "$hanging_directory"
RUNNER_TEMP="$hanging_directory" \
UUREMOTE_DIAGNOSTIC_TEST_CLI="$0" \
UUREMOTE_DIAGNOSTIC_FIXTURE_CLI=1 \
UUREMOTE_DIAGNOSTIC_FIXTURE_HANG=1 \
UUREMOTE_DIAGNOSTIC_FIXTURE_PID_PATH="$hanging_pid_path" \
UUREMOTE_DIAGNOSTIC_FIXTURE_DEVICE_ID="$fixture_device_id" \
UUREMOTE_DIAGNOSTIC_FIXTURE_CUSTOM_CODE="$fixture_custom_code" \
    /usr/bin/python3 - "$root/.github/workflows/apple.sh" "$hanging_pid_path" "$fixture_device_id" "$fixture_custom_code" <<'PYTHON'
import os
import pathlib
import signal
import subprocess
import sys
import time

helper_path = sys.argv[1]
fixture_pid_path = pathlib.Path(sys.argv[2])
forbidden_markers = tuple(value.encode() for value in sys.argv[3:])
bash_path = os.environ.get("UUREMOTE_TEST_BASH_PATH", "/bin/bash")
process = subprocess.Popen(
    [bash_path, helper_path, "self-test-diagnostic-redaction"],
    env=os.environ.copy(),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    start_new_session=True,
)
try:
    stdout, stderr = process.communicate(timeout=8)
except subprocess.TimeoutExpired:
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    else:
        os.killpg(process.pid, signal.SIGKILL)
    process.communicate()
    raise SystemExit("diagnostic assist id exceeded its owned timeout")

if process.returncode != 0:
    raise SystemExit("diagnostic assist id returned an unexpected status")
if any(marker in stdout + stderr for marker in forbidden_markers):
    raise SystemExit("diagnostic assist id exposed raw CLI output")

fixture_pid = int(fixture_pid_path.read_text(encoding="ascii").strip())
deadline = time.monotonic() + 2
while time.monotonic() < deadline:
    try:
        os.kill(fixture_pid, 0)
    except ProcessLookupError:
        break
    time.sleep(0.05)
else:
    raise SystemExit("diagnostic assist id child was not terminated and reaped")
PYTHON

hanging_log="$hanging_directory/uuremote-diagnostics/diagnostics.log"
grep -Fxq 'DEVICE_ID_STATE=error' "$hanging_log"
grep -Fxq 'DEVICE_ID_EXIT=124' "$hanging_log"
if grep -Fq -- "$fixture_device_id" "$hanging_log" ||
    grep -Fq -- "$fixture_custom_code" "$hanging_log"; then
    echo "Hanging diagnostic artifact exposed fixture output" >&2
    exit 1
fi

echo "diagnostic redaction self-test passed"
