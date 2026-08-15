#!/bin/bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/uuremote-device-id-test.XXXXXX")"
fixture_cli="$temporary_directory/uuyc-cli"

cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

cat >"$fixture_cli" <<'FIXTURE'
#!/bin/bash
set -euo pipefail

if [ "${*:-}" != "assist id" ]; then
    exit 2
fi

case "${DEVICE_ID_FIXTURE_MODE:?}" in
    valid) printf '%s\n' 'device-id-fixture' ;;
    leading-space) printf ' device-id-fixture\n' ;;
    trailing-space) printf 'device-id-fixture \n' ;;
    empty) printf '\n' ;;
    multiline) printf 'device-id-fixture\nFORGED_OUTPUT=true\n' ;;
    control) printf 'device-id-fixture\tFORGED_OUTPUT=true\n' ;;
    leading-control) printf '\tdevice-id-fixture\n' ;;
    trailing-control) printf 'device-id-fixture\t\n' ;;
    extra-newline) printf 'device-id-fixture\n\n' ;;
    nul) printf 'device-id-fixture\000FORGED_OUTPUT=true\n' ;;
    del) printf 'device-id-fixture\177FORGED_OUTPUT=true\n' ;;
    invalid-utf8) printf 'device-id-fixture\377\n' ;;
    unicode-control) printf 'device-id-fixture\302\205FORGED_OUTPUT=true\n' ;;
    unicode-separator) printf 'device-id-fixture\342\200\250FORGED_OUTPUT=true\n' ;;
    failure)
        printf '%s\n' 'raw-cli-device-output' >&2
        exit 7
        ;;
    failure-stdout)
        printf '%s\n' 'raw-cli-device-output'
        exit 7
        ;;
esac
FIXTURE
chmod 0700 "$fixture_cli"

run_helper() {
    DEVICE_ID_FIXTURE_MODE="$1" \
    UUREMOTE_CLI_PATH="$fixture_cli" \
        /bin/bash "$root/.github/workflows/apple.sh" "${@:2}"
}

assert_exact_output() {
    local expected="$1"
    shift
    local actual

    actual="$("$@")"
    if [ "$actual" != "$expected" ]; then
        echo "Unexpected helper output" >&2
        printf 'expected: %s\n' "$expected" >&2
        printf 'actual: %s\n' "$actual" >&2
        exit 1
    fi
}

assert_exact_output $'DEVICE_ID=device-id-fixture\nDEVICE_ID_STATE=ready' \
    run_helper valid report-device-id readiness
assert_exact_output $'DEVICE_ID=device-id-fixture\nDEVICE_ID_STATE=ready' \
    run_helper leading-space report-device-id readiness
assert_exact_output $'DEVICE_ID=device-id-fixture\nDEVICE_ID_STATE=ready' \
    run_helper trailing-space report-device-id readiness
assert_exact_output $'WAIT_CONNECTIONS DEVICE_ID=device-id-fixture\nWAIT_RESULT=timeout' \
    run_helper valid wait-connections 0

for mode in empty multiline control leading-control trailing-control extra-newline nul del invalid-utf8 unicode-control unicode-separator failure failure-stdout; do
    output_path="$temporary_directory/$mode.output"
    if run_helper "$mode" report-device-id readiness >"$output_path" 2>&1; then
        echo "Fixture mode $mode unexpectedly succeeded" >&2
        exit 1
    fi

    if grep -aEq 'device-id-fixture|FORGED_OUTPUT|raw-cli-device-output' "$output_path"; then
        echo "Fixture mode $mode exposed unsafe CLI output" >&2
        exit 1
    fi
done

echo "macOS device ID logging contract passed"
