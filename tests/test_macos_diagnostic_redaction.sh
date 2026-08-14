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

echo "diagnostic redaction self-test passed"
