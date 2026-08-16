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
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/uuremote-cli-output-test.XXXXXX")"
stdout_path="$temporary_directory/stdout"
stderr_path="$temporary_directory/stderr"
status_count_path="$temporary_directory/status-count"
assist_count_path="$temporary_directory/assist-count"
artifact_root="$temporary_directory/artifacts"
fixture_device_id="device-id-fixture-3187"
fixture_custom_code="CustomCodeFixture3187"

cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

mkdir -p "$artifact_root"
if ! RUNNER_TEMP="$artifact_root" \
    UUREMOTE_CLI_OUTPUT_TEST_CLI="$0" \
    UUREMOTE_CLI_OUTPUT_FIXTURE=1 \
    UUREMOTE_STATUS_COUNT_PATH="$status_count_path" \
    UUREMOTE_ASSIST_COUNT_PATH="$assist_count_path" \
    UUREMOTE_FIXTURE_DEVICE_ID="$fixture_device_id" \
    UUREMOTE_FIXTURE_CUSTOM_CODE="$fixture_custom_code" \
        /bin/bash "$root/.github/workflows/apple.sh" self-test-cli-output-redaction \
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

echo "macOS CLI output redaction contract passed"
