#!/bin/bash
set -euo pipefail

if [ "${UUREMOTE_CLI_OUTPUT_FIXTURE:-0}" = "1" ]; then
    case "${*:-}" in
        status)
            count_path="${UUREMOTE_STATUS_COUNT_PATH:?}"
            response_prefix='"success" : true'
            ;;
        "assist allow on")
            count_path="${UUREMOTE_ASSIST_COUNT_PATH:?}"
            response_prefix='"success" : true, "enabled" : true'
            ;;
        *)
            exit 2
            ;;
    esac

    count=0
    if [ -f "$count_path" ]; then
        read -r count <"$count_path"
    fi
    count="$((count + 1))"
    printf '%s\n' "$count" >"$count_path"

    if [ "$count" -eq 1 ]; then
        printf '{%s, "deviceId" : "%s", "customCode" : "%s"\n' \
            "$response_prefix" \
            "${UUREMOTE_FIXTURE_DEVICE_ID:?}" \
            "${UUREMOTE_FIXTURE_CUSTOM_CODE:?}"
    else
        printf '{%s, "deviceId" : "%s", "customCode" : "%s"}\n' \
            "$response_prefix" \
            "${UUREMOTE_FIXTURE_DEVICE_ID:?}" \
            "${UUREMOTE_FIXTURE_CUSTOM_CODE:?}"
    fi
    exit 0
fi

root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
apple_script="${UUREMOTE_CLI_OUTPUT_APPLE_SCRIPT:-$root/.github/workflows/apple.sh}"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/uuremote-cli-output-test.XXXXXX")"
mutation_pid=""
mutation_watchdog_pid=""
stdout_path="$temporary_directory/stdout"
stderr_path="$temporary_directory/stderr"
status_count_path="$temporary_directory/status-count"
assist_count_path="$temporary_directory/assist-count"
artifact_root="$temporary_directory/artifacts"
fixture_device_id="device-id-fixture-3187"
fixture_custom_code="CustomCodeFixture3187"

cleanup() {
    if [ -n "$mutation_watchdog_pid" ]; then
        /bin/kill -TERM "$mutation_watchdog_pid" 2>/dev/null || true
        wait "$mutation_watchdog_pid" 2>/dev/null || true
    fi
    if [ -n "$mutation_pid" ]; then
        /bin/kill -TERM "$mutation_pid" 2>/dev/null || true
        wait "$mutation_pid" 2>/dev/null || true
    fi
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

mkdir -p "$artifact_root"
if ! env -u console_uid \
    RUNNER_TEMP="$artifact_root" \
    UUREMOTE_CLI_OUTPUT_TEST_CLI="$0" \
    UUREMOTE_CLI_OUTPUT_FIXTURE=1 \
    UUREMOTE_STATUS_COUNT_PATH="$status_count_path" \
    UUREMOTE_ASSIST_COUNT_PATH="$assist_count_path" \
    UUREMOTE_FIXTURE_DEVICE_ID="$fixture_device_id" \
    UUREMOTE_FIXTURE_CUSTOM_CODE="$fixture_custom_code" \
        /bin/bash "$apple_script" self-test-cli-output-redaction \
        >"$stdout_path" 2>"$stderr_path"
then
    echo "CLI output redaction self-test route failed" >&2
    exit 1
fi

expected_output=$'CLI_STATUS_STATE=ready\nASSIST_STATE=enabled\nCLI output redaction self-test passed'
actual_output="$(<"$stdout_path")"
if [ "$actual_output" != "$expected_output" ]; then
    echo "CLI output redaction self-test emitted unexpected output" >&2
    exit 1
fi
if [ -s "$stderr_path" ]; then
    echo "CLI output redaction self-test emitted stderr" >&2
    exit 1
fi

for marker in "$fixture_device_id" "$fixture_custom_code"; do
    if grep -FRq -- "$marker" "$stdout_path" "$stderr_path" "$artifact_root"; then
        echo "CLI output redaction self-test exposed a fixture marker" >&2
        exit 1
    fi
done

if [ "$(<"$status_count_path")" -ne 2 ] ||
    [ "$(<"$assist_count_path")" -ne 2 ]; then
    echo "Malformed CLI output was not rejected before the valid response" >&2
    exit 1
fi

mutation_script="$temporary_directory/apple-failing-self-test-gui-wrapper.sh"
mutation_timeout_path="$temporary_directory/mutation-timeout"
mutation_reached_path="$temporary_directory/mutation-reached"
mutation_status_count_before="$(<"$status_count_path")"
mutation_assist_count_before="$(<"$assist_count_path")"
awk '
    $0 == "self_test_cli_output_redaction() {" { in_self_test = 1 }
    in_self_test && $0 == "    run_bounded_gui_cli_to_file() {" {
        print
        print "        printf \"%s\\n\" \"bounded-gui-override-reached\" >\"${UUREMOTE_CLI_OUTPUT_MUTATION_REACHED_PATH:?}\""
        print "        return 1"
        mutation_count++
        next
    }
    { print }
    END { if (mutation_count != 1) exit 2 }
' "$apple_script" >"$mutation_script"
chmod 0700 "$mutation_script"

env -u console_uid \
    RUNNER_TEMP="$artifact_root" \
    UUREMOTE_CLI_OUTPUT_TEST_CLI="$0" \
    UUREMOTE_CLI_OUTPUT_FIXTURE=1 \
    UUREMOTE_STATUS_COUNT_PATH="$status_count_path" \
    UUREMOTE_ASSIST_COUNT_PATH="$assist_count_path" \
    UUREMOTE_FIXTURE_DEVICE_ID="$fixture_device_id" \
    UUREMOTE_FIXTURE_CUSTOM_CODE="$fixture_custom_code" \
    UUREMOTE_CLI_OUTPUT_MUTATION_REACHED_PATH="$mutation_reached_path" \
        /bin/bash "$mutation_script" self-test-cli-output-redaction \
        >"$temporary_directory/mutation-stdout" 2>"$temporary_directory/mutation-stderr" &
mutation_pid="$!"
(
    mutation_ticks=0
    while [ "$mutation_ticks" -lt 50 ]; do
        sleep 0.1
        /bin/kill -0 "$mutation_pid" 2>/dev/null || exit 0
        mutation_ticks="$((mutation_ticks + 1))"
    done
    /bin/kill -TERM "$mutation_pid" 2>/dev/null && : >"$mutation_timeout_path"
) &
mutation_watchdog_pid="$!"
if wait "$mutation_pid"; then
    mutation_status=0
else
    mutation_status="$?"
fi
mutation_pid=""
/bin/kill -TERM "$mutation_watchdog_pid" 2>/dev/null || true
wait "$mutation_watchdog_pid" 2>/dev/null || true
mutation_watchdog_pid=""

if [ "$mutation_status" -eq 0 ]; then
    echo "Self-test mutation did not exercise the bounded GUI override" >&2
    exit 1
fi

if [ -e "$mutation_timeout_path" ]; then
    echo "Self-test bounded GUI override mutation exceeded its timeout" >&2
    exit 1
fi

if [ ! -f "$mutation_reached_path" ] ||
    [ "$(<"$mutation_reached_path")" != "bounded-gui-override-reached" ]
then
    echo "Self-test mutation did not reach the bounded GUI override" >&2
    exit 1
fi

if [ "$mutation_status" -ne 1 ] ||
    [ "$(<"$status_count_path")" -ne "$((mutation_status_count_before + 1))" ] ||
    [ "$(<"$assist_count_path")" -ne "$mutation_assist_count_before" ]
then
    echo "Self-test mutation did not stop at the bounded GUI override" >&2
    exit 1
fi

if [ "$(<"$temporary_directory/mutation-stdout")" != "CLI_STATUS_STATE=ready" ] ||
    [ -s "$temporary_directory/mutation-stderr" ]
then
    echo "Self-test mutation emitted an unexpected boundary result" >&2
    exit 1
fi

for marker in "$fixture_device_id" "$fixture_custom_code"; do
    if grep -FRq -- "$marker" "$temporary_directory/mutation-stdout" "$temporary_directory/mutation-stderr"; then
        echo "Self-test mutation exposed a fixture marker" >&2
        exit 1
    fi
done

echo "macOS CLI output redaction contract passed"
