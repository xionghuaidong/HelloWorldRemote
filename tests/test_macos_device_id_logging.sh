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
    valid-crlf) printf 'device-id-fixture\r\n' ;;
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
    ansi-wrapped) printf '\033[31mdevice-id-fixture\033[0m\n' ;;
    utf16le-style) printf '\377\376d\000e\000v\000i\000c\000e\000-\000i\000d\000-\000f\000i\000x\000t\000u\000r\000e\000\n' ;;
    mixed-controls) printf 'device\tid\rfixture\177X\n' ;;
    seven-run-protocol)
        printf 'X\177RAW-MARKER12\003'
        printf 'A%.0s' {1..28}
        printf '\0011234\005'
        printf ' %.0s' {1..19}
        printf '\002'
        printf '!%.0s' {1..38}
        printf '\004Z\n'
        ;;
    category-rle-bound)
        printf 'A1%.0s' {1..10}
        printf '\n'
        ;;
    mode-0600)
        if ! /usr/bin/python3 -c 'import os, stat; raise SystemExit(0 if stat.S_IMODE(os.fstat(1).st_mode) == 0o600 else 9)'; then
            exit 9
        fi
        printf '%s\n' 'device-id-fixture'
        ;;
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

diagnostic_temp_root="$temporary_directory/diagnostic-temp"
mkdir -p "$diagnostic_temp_root"

run_diagnostic() {
    DEVICE_ID_FIXTURE_MODE="$1" \
    UUREMOTE_CLI_PATH="$fixture_cli" \
    TMPDIR="$diagnostic_temp_root" \
        /bin/bash "$root/.github/workflows/apple.sh" diagnose-device-id
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

assert_diagnostic_fields() {
    local mode="$1"
    shift
    local actual
    local expected_field
    local line_count

    actual="$(run_diagnostic "$mode")"
    line_count="$(printf '%s\n' "$actual" | wc -l | tr -d ' ')"
    if [ "$line_count" -ne 23 ]; then
        echo "Device ID diagnostic output has an unexpected field count" >&2
        exit 1
    fi

    for expected_field in "$@"; do
        if ! printf '%s\n' "$actual" | grep -Fxq "DEVICE_ID_DIAGNOSTIC_$expected_field"; then
            echo "Device ID diagnostic output is missing expected structural metadata" >&2
            exit 1
        fi
    done

    if printf '%s' "$actual" | grep -aEq 'raw-cli-device-output|FORGED_OUTPUT|device-id-fixture|RAW-MARKER12'; then
        echo "Device ID diagnostic output exposed raw CLI bytes" >&2
        exit 1
    fi
}

assert_exact_output $'DEVICE_ID=device-id-fixture\nDEVICE_ID_STATE=ready' \
    run_helper valid report-device-id readiness
assert_exact_output $'DEVICE_ID=device-id-fixture\nDEVICE_ID_STATE=ready' \
    run_helper valid-crlf report-device-id readiness
assert_exact_output $'DEVICE_ID=device-id-fixture\nDEVICE_ID_STATE=ready' \
    run_helper leading-space report-device-id readiness
assert_exact_output $'DEVICE_ID=device-id-fixture\nDEVICE_ID_STATE=ready' \
    run_helper trailing-space report-device-id readiness
assert_exact_output $'WAIT_CONNECTIONS DEVICE_ID=device-id-fixture\nWAIT_RESULT=timeout' \
    run_helper valid wait-connections 0

assert_diagnostic_fields valid \
    CLI_EXIT=0 STDOUT_BYTES=18 FRAMING=LF FRAMING_COUNT=1 UTF8=valid SHAPE=structurally-valid \
    NUL_COUNT=0 TAB_COUNT=0 CR_COUNT=0 ESC_COUNT=0 OTHER_C0_DEL_COUNT=0 \
    ASCII_DIGIT_COUNT=0 ASCII_LETTER_COUNT=15 ASCII_SPACE_COUNT=0 \
    ASCII_OTHER_PRINTABLE_COUNT=2 NON_ASCII_CODEPOINT_COUNT=0 BOM_KIND=none \
    UTF16LE_PRINTABLE=false UTF16BE_PRINTABLE=false PRINTABLE_RUN_COUNT=1 \
    PRINTABLE_RUN_LENGTHS_FIRST_8=17 OTHER_C0_DEL_HISTOGRAM=none \
    PRINTABLE_RUN_CATEGORY_RLE_FIRST_8_SEGMENTS_16=L6,O1,L2,O1,L7
assert_diagnostic_fields valid-crlf \
    CLI_EXIT=0 STDOUT_BYTES=19 FRAMING=CRLF FRAMING_COUNT=1 UTF8=valid SHAPE=structurally-valid
assert_diagnostic_fields extra-newline \
    CLI_EXIT=0 STDOUT_BYTES=19 FRAMING=extra FRAMING_COUNT=2 UTF8=valid SHAPE=ASCII-control
assert_diagnostic_fields unicode-separator \
    CLI_EXIT=0 STDOUT_BYTES=39 FRAMING=LF FRAMING_COUNT=1 UTF8=valid SHAPE=Unicode-nonprintable-separator
assert_diagnostic_fields invalid-utf8 \
    CLI_EXIT=0 STDOUT_BYTES=19 FRAMING=LF FRAMING_COUNT=1 UTF8=invalid SHAPE=unavailable
assert_diagnostic_fields failure \
    CLI_EXIT=7 STDOUT_BYTES=0 FRAMING=none FRAMING_COUNT=0 UTF8=valid SHAPE=empty
assert_diagnostic_fields mode-0600 \
    CLI_EXIT=0 STDOUT_BYTES=18 FRAMING=LF FRAMING_COUNT=1 UTF8=valid SHAPE=structurally-valid
assert_diagnostic_fields ansi-wrapped \
    CLI_EXIT=0 STDOUT_BYTES=27 FRAMING=LF FRAMING_COUNT=1 UTF8=valid SHAPE=ASCII-control \
    NUL_COUNT=0 TAB_COUNT=0 CR_COUNT=0 ESC_COUNT=2 OTHER_C0_DEL_COUNT=0 \
    ASCII_DIGIT_COUNT=3 ASCII_LETTER_COUNT=17 ASCII_SPACE_COUNT=0 \
    ASCII_OTHER_PRINTABLE_COUNT=4 NON_ASCII_CODEPOINT_COUNT=0 BOM_KIND=none \
    UTF16LE_PRINTABLE=true UTF16BE_PRINTABLE=true PRINTABLE_RUN_COUNT=2 \
    PRINTABLE_RUN_LENGTHS_FIRST_8=21,3
assert_diagnostic_fields utf16le-style \
    CLI_EXIT=0 STDOUT_BYTES=37 FRAMING=LF FRAMING_COUNT=1 UTF8=invalid SHAPE=unavailable \
    NUL_COUNT=17 TAB_COUNT=0 CR_COUNT=0 ESC_COUNT=0 OTHER_C0_DEL_COUNT=0 \
    ASCII_DIGIT_COUNT=0 ASCII_LETTER_COUNT=15 ASCII_SPACE_COUNT=0 \
    ASCII_OTHER_PRINTABLE_COUNT=2 NON_ASCII_CODEPOINT_COUNT=0 BOM_KIND=UTF16LE \
    UTF16LE_PRINTABLE=true UTF16BE_PRINTABLE=false PRINTABLE_RUN_COUNT=0 \
    PRINTABLE_RUN_LENGTHS_FIRST_8=
assert_diagnostic_fields mixed-controls \
    CLI_EXIT=0 STDOUT_BYTES=20 FRAMING=LF FRAMING_COUNT=1 UTF8=valid SHAPE=ASCII-control \
    NUL_COUNT=0 TAB_COUNT=1 CR_COUNT=1 ESC_COUNT=0 OTHER_C0_DEL_COUNT=1 \
    ASCII_DIGIT_COUNT=0 ASCII_LETTER_COUNT=16 ASCII_SPACE_COUNT=0 \
    ASCII_OTHER_PRINTABLE_COUNT=0 NON_ASCII_CODEPOINT_COUNT=0 BOM_KIND=none \
    UTF16LE_PRINTABLE=false UTF16BE_PRINTABLE=false PRINTABLE_RUN_COUNT=4 \
    PRINTABLE_RUN_LENGTHS_FIRST_8=6,2,7,1
assert_diagnostic_fields seven-run-protocol \
    CLI_EXIT=0 STDOUT_BYTES=110 FRAMING=LF FRAMING_COUNT=1 UTF8=valid SHAPE=ASCII-control \
    NUL_COUNT=0 TAB_COUNT=0 CR_COUNT=0 ESC_COUNT=0 OTHER_C0_DEL_COUNT=6 \
    ASCII_DIGIT_COUNT=6 ASCII_LETTER_COUNT=39 ASCII_SPACE_COUNT=19 \
    ASCII_OTHER_PRINTABLE_COUNT=39 NON_ASCII_CODEPOINT_COUNT=0 BOM_KIND=none \
    UTF16LE_PRINTABLE=false UTF16BE_PRINTABLE=false PRINTABLE_RUN_COUNT=7 \
    PRINTABLE_RUN_LENGTHS_FIRST_8=1,12,28,4,19,38,1 \
    OTHER_C0_DEL_HISTOGRAM=01:1,02:1,03:1,04:1,05:1,7F:1 \
    PRINTABLE_RUN_CATEGORY_RLE_FIRST_8_SEGMENTS_16=L1\;L3,O1,L6,D2\;L28\;D4\;S19\;O38\;L1
assert_diagnostic_fields category-rle-bound \
    CLI_EXIT=0 STDOUT_BYTES=21 FRAMING=LF FRAMING_COUNT=1 UTF8=valid SHAPE=structurally-valid \
    NUL_COUNT=0 TAB_COUNT=0 CR_COUNT=0 ESC_COUNT=0 OTHER_C0_DEL_COUNT=0 \
    ASCII_DIGIT_COUNT=10 ASCII_LETTER_COUNT=10 ASCII_SPACE_COUNT=0 \
    ASCII_OTHER_PRINTABLE_COUNT=0 NON_ASCII_CODEPOINT_COUNT=0 BOM_KIND=none \
    UTF16LE_PRINTABLE=true UTF16BE_PRINTABLE=true PRINTABLE_RUN_COUNT=1 \
    PRINTABLE_RUN_LENGTHS_FIRST_8=20 OTHER_C0_DEL_HISTOGRAM=none \
    PRINTABLE_RUN_CATEGORY_RLE_FIRST_8_SEGMENTS_16=L1,D1,L1,D1,L1,D1,L1,D1,L1,D1,L1,D1,L1,D1,L1,D1

diagnostic_output="$(run_diagnostic failure-stdout)"
if printf '%s' "$diagnostic_output" | grep -aEq 'raw-cli-device-output|FORGED_OUTPUT|device-id-fixture'; then
    echo "Device ID diagnostic output exposed raw CLI bytes" >&2
    exit 1
fi

if find "$diagnostic_temp_root" -mindepth 1 -print -quit | grep -q .; then
    echo "Device ID diagnostic temporary files were not cleaned up" >&2
    exit 1
fi

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
