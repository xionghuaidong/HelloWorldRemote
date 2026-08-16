#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "fixture-hang" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; while :; do sleep 1; done' \
        fixture-child "${3:?}" &
    trap '' TERM
    while :; do sleep 1; done
fi

umask 077

root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/uuremote-assist-allow-test.XXXXXX")"
subject="$temporary_directory/subject.sh"
response_path="$temporary_directory/response"
trap 'rm -rf -- "$temporary_directory"' EXIT

awk '/^if \[ "\$mode" = "self-test-kcpassword" \]; then$/ { exit } { print }' \
    "$root/.github/workflows/apple.sh" >"$subject"
if [ ! -x /usr/bin/python3 ]; then
    python_command="$(command -v python3 || command -v python)"
    python_wrapper="$temporary_directory/python3"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$python_command" >"$python_wrapper"
    chmod 0700 "$python_wrapper"
    sed "s#/usr/bin/python3#$python_wrapper#g" "$subject" >"$subject.portable"
    mv "$subject.portable" "$subject"
fi

mode="${1:?}"
scenario="${2:?}"

if [ "$mode" = "process" ]; then
    status_path="$temporary_directory/status"
    output_path="$temporary_directory/output"
    parent_pid_path="$temporary_directory/parent.pid"
    child_pid_path="$temporary_directory/child.pid"

    . "$subject"
    case "$scenario" in
        completed)
            run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 /bin/true
            ;;
        nonzero)
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 /bin/bash -c 'exit 17'
            then
                echo "Nonzero fixture unexpectedly succeeded" >&2
                exit 1
            fi
            ;;
        timeout)
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-hang \
                "$parent_pid_path" "$child_pid_path"
            then
                echo "Hanging fixture unexpectedly succeeded" >&2
                exit 1
            fi
            for pid_path in "$parent_pid_path" "$child_pid_path"; do
                pid="$(cat "$pid_path")"
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Process group was not released" >&2
                    exit 1
                fi
            done
            printf 'STATUS=%s\n' "$(cat "$status_path")"
            printf 'PROCESS_GROUP_RELEASED=true\n'
            exit 0
            ;;
        *) exit 2 ;;
    esac
    printf 'STATUS=%s\n' "$(cat "$status_path")"
    exit 0
fi

if [ "$mode" != "classify" ]; then
    exit 2
fi

case "$scenario" in
    timeout) execution_state=timeout; cli_exit=unavailable; : >"$response_path" ;;
    unavailable) execution_state=unavailable; cli_exit=unavailable; : >"$response_path" ;;
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

case "$(uname -s)" in
    Darwin) response_mode="$(/usr/bin/stat -f '%Lp' "$response_path")" ;;
    *) response_mode="$(/usr/bin/stat -c '%a' "$response_path")" ;;
esac
if [ "$response_mode" != 600 ]; then
    echo "Response fixture permissions are not private" >&2
    exit 1
fi

. "$subject"
classify_assist_allow_response "$response_path" "$execution_state" "$cli_exit"
