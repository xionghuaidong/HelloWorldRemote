#!/bin/bash
set -euo pipefail

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

scenario="${2:?}"
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
