#!/bin/bash
set -euo pipefail

APP="/Applications/UURemote.app"
CLI="$APP/Contents/Helpers/uuyc-cli"
mode="${1:-configure}"
KEY_REPEAT_VALUE=2
INITIAL_KEY_REPEAT_VALUE=15

validate_uuremote_custom_code() {
    local custom_code="${1:-}"

    [[ "$custom_code" =~ ^[A-Za-z0-9]{8,16}$ ]]
}

if [ "$mode" = "validate-custom-code" ]; then
    if validate_uuremote_custom_code "${UUREMOTE_CUSTOM_CODE:-}"; then
        exit 0
    fi

    echo "UUREMOTE_CUSTOM_CODE must match ^[A-Za-z0-9]{8,16}$" >&2
    exit 2
fi

transform_terminal_preferences() {
    local input_path="$1"
    local output_path="$2"

    /usr/bin/python3 - "$input_path" "$output_path" <<'PYTHON'
import pathlib
import plistlib
import sys

input_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
preferences = plistlib.loads(input_path.read_bytes())
window_settings = preferences.get("Window Settings")

if not isinstance(window_settings, dict) or not window_settings:
    raise SystemExit("Terminal Window Settings profiles are unavailable")

profiles_updated = 0
for profile in window_settings.values():
    if isinstance(profile, dict):
        profile["shellExitAction"] = 0
        profiles_updated += 1

if profiles_updated == 0:
    raise SystemExit("Terminal Window Settings contains no editable profiles")

output_path.write_bytes(plistlib.dumps(preferences, fmt=plistlib.FMT_XML))
PYTHON
}

if [ "$mode" = "transform-terminal-preferences" ]; then
    if [ "$#" -ne 3 ]; then
        echo "Usage: apple.sh transform-terminal-preferences INPUT OUTPUT" >&2
        exit 2
    fi

    transform_terminal_preferences "$2" "$3"
    exit $?
fi

if [ "$mode" = "desktop-preference-contract" ]; then
    printf 'KeyRepeat=%s\n' "$KEY_REPEAT_VALUE"
    printf 'InitialKeyRepeat=%s\n' "$INITIAL_KEY_REPEAT_VALUE"
    exit 0
fi

encode_kcpassword() {
    local output_path="$1"

    /usr/bin/python3 -c '
import pathlib
import sys

key = bytes((0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F))
plain = sys.stdin.buffer.read()
padded_length = ((len(plain) + 12) // 12) * 12
plain += b"\0" * (padded_length - len(plain))
encoded = bytes(value ^ key[index % len(key)] for index, value in enumerate(plain))
pathlib.Path(sys.argv[1]).write_bytes(encoded)
' "$output_path"
}

decode_kcpassword() {
    local input_path="$1"

    if [ -r "$input_path" ]; then
        /bin/cat "$input_path"
    else
        sudo /bin/cat "$input_path"
    fi | /usr/bin/python3 -c '
import sys

key = bytes((0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F))
encoded = sys.stdin.buffer.read()
decoded = bytes(value ^ key[index % len(key)] for index, value in enumerate(encoded))
sys.stdout.buffer.write(decoded.split(b"\0", 1)[0])
'
}

self_test_kcpassword() {
    local codec_temp_dir
    local encoded_path
    local encoded_hex
    local decoded_value
    local index
    local sample
    local samples=(
        "john.doe"
        'space and $hell!'
        "12345678901"
        "123456789012"
        "1234567890123"
        "密码-SG"
    )
    local vector_passwords=("john.doe" "123456789012" "密码-SG")
    local vector_hex=(
        "17e63a4dfcd8b28fa3b91f7d"
        "4cbb6117e78aead29a892e4f895223d2bcddeaa3b91f7d89"
        "9826d4c4723df0b9e4b91f7d"
    )

    codec_temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uuremote-kcpassword-test.XXXXXX")"
    encoded_path="$codec_temp_dir/kcpassword"

    for sample in "${samples[@]}"; do
        printf '%s' "$sample" | encode_kcpassword "$encoded_path"

        if ! decoded_value="$(decode_kcpassword "$encoded_path")"; then
            /bin/rm -rf -- "$codec_temp_dir"
            echo "kcpassword codec self-test could not decode a sample" >&2
            return 1
        fi

        if [ "$decoded_value" != "$sample" ]; then
            /bin/rm -rf -- "$codec_temp_dir"
            echo "kcpassword codec self-test round trip failed" >&2
            return 1
        fi
    done

    for index in 0 1 2; do
        printf '%s' "${vector_passwords[$index]}" | encode_kcpassword "$encoded_path"
        encoded_hex="$(/usr/bin/python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).read_bytes().hex())' "$encoded_path")"

        if [ "$encoded_hex" != "${vector_hex[$index]}" ]; then
            /bin/rm -rf -- "$codec_temp_dir"
            echo "kcpassword codec self-test known vector failed" >&2
            return 1
        fi
    done

    /bin/rm -rf -- "$codec_temp_dir"
    echo "kcpassword codec self-test passed"
}

account_password=""
old_account_password=""
old_keychain_password=""
console_uid=""
console_user=""
console_home=""
user_login_keychain=""
bootstrap_temp_dir=""
original_kcpassword_existed=0
transaction_active=0
user_keychain_changed=0
user_password_changed=0
kcpassword_changed=0
root_login_keychain=""
root_keychain_backup=""
root_keychain_original_path=""
old_root_keychain_password=""
old_root_password=""
root_keychain_password_changed=0
root_keychain_replaced=0
root_password_changed=0
original_root_shadow_hash_existed=0
original_root_authentication_authority_existed=0

die() {
    echo "$*" >&2
    return 1
}

validate_wait_connections_seconds() {
    local wait_seconds="${1:-}"

    case "$wait_seconds" in
        ''|*[!0-9]*)
            echo "wait_connections_seconds must be an integer in the range 0-21000; got: $wait_seconds" >&2
            return 2
            ;;
    esac

    if [ "$wait_seconds" -gt 21000 ]; then
        echo "wait_connections_seconds must be an integer in the range 0-21000; got: $wait_seconds" >&2
        return 2
    fi
}

run_shutdown_waiter() (
    set -euo pipefail

    wait_seconds="$1"
    injected_event="${2:-none}"
    script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    watcher_source="$script_dir/uuremote-shutdown-wait.swift"

    resolve_console_account

    build_dir="$(
        run_as_console_user /usr/bin/mktemp -d \
            "/tmp/uuremote-shutdown-wait.XXXXXX"
    )"
    watcher_binary="$build_dir/uuremote-shutdown-wait"
    watcher_build_source="$build_dir/uuremote-shutdown-wait.swift"

    cleanup_shutdown_waiter() {
        sudo /bin/rm -f -- "$watcher_binary"
        sudo /bin/rm -f -- "$watcher_build_source"
        sudo /bin/rmdir "$build_dir" 2>/dev/null || true
    }

    trap cleanup_shutdown_waiter EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    run_as_console_user /bin/chmod 0700 "$build_dir"
    sudo /bin/cp "$watcher_source" "$watcher_build_source"
    sudo /usr/sbin/chown "$console_uid" "$watcher_build_source"
    sudo /bin/chmod 0600 "$watcher_build_source"
    run_as_console_user /usr/bin/xcrun swiftc -framework AppKit \
        "$watcher_build_source" -o "$watcher_binary"
    run_as_console_user "$watcher_binary" "$wait_seconds" "$injected_event"
)

self_test_wait_connections() {
    local result

    result="$(run_shutdown_waiter 1 none)"
    if [ "$result" != "WAIT_RESULT=timeout" ]; then
        echo "Timeout wait self-test failed: $result" >&2
        return 1
    fi

    result="$(run_shutdown_waiter 1 ordinary)"
    if [ "$result" != "WAIT_RESULT=timeout" ]; then
        echo "Ordinary-event wait self-test failed: $result" >&2
        return 1
    fi

    result="$(run_shutdown_waiter 2 power-off)"
    if [ "$result" != "WAIT_RESULT=shutdown/restart" ]; then
        echo "Power-off wait self-test failed: $result" >&2
        return 1
    fi

    echo "shutdown-aware wait self-test passed"
}

wait_connections() {
    local wait_seconds="${1:-}"

    validate_wait_connections_seconds "$wait_seconds" || return "$?"

    if [ "$wait_seconds" -eq 0 ]; then
        echo "WAIT_RESULT=timeout"
        return 0
    fi

    run_shutdown_waiter "$wait_seconds" none
}

capture_cli_diagnostics() {
    local cli_output=""
    local cli_status
    local cli_state

    if cli_output="$(run_in_gui "$CLI" status 2>/dev/null)"; then
        cli_status=0
        if printf '%s' "$cli_output" | /usr/bin/grep -Eq '"success"[[:space:]]*:[[:space:]]*true'; then
            cli_state="ready"
        else
            cli_state="unavailable"
        fi
    else
        cli_status="$?"
        cli_state="error"
    fi

    printf 'CLI_STATUS_STATE=%s\n' "$cli_state"
    printf 'CLI_STATUS_EXIT=%s\n' "$cli_status"
    unset cli_output

    if cli_output="$(run_in_gui "$CLI" assist id 2>/dev/null)"; then
        cli_status=0
        if [ -n "$cli_output" ]; then
            cli_state="ready"
        else
            cli_state="empty"
        fi
    else
        cli_status="$?"
        cli_state="error"
    fi

    printf 'DEVICE_ID_STATE=%s\n' "$cli_state"
    printf 'DEVICE_ID_EXIT=%s\n' "$cli_status"
    unset cli_output
}

self_test_diagnostic_redaction() {
    local test_cli="${UUREMOTE_DIAGNOSTIC_TEST_CLI:-}"

    if [ -z "$test_cli" ] || [ ! -r "$test_cli" ]; then
        echo "UUREMOTE_DIAGNOSTIC_TEST_CLI must name a readable Bash fixture" >&2
        return 2
    fi

    CLI="$test_cli"
    evidence_dir="${RUNNER_TEMP:-/tmp}/uuremote-diagnostics"
    diagnostic_log="$evidence_dir/diagnostics.log"

    run_in_gui() {
        local fixture_cli="$1"
        shift
        /bin/bash "$fixture_cli" "$@"
    }

    /bin/mkdir -p "$evidence_dir"
    capture_cli_diagnostics | /usr/bin/tee -a "$diagnostic_log"
}

run_as_console_user() {
    sudo /bin/launchctl asuser "$console_uid" \
        sudo -u "#$console_uid" \
        "$@"
}

resolve_console_account() {
    console_uid="$(/usr/bin/stat -f '%u' /dev/console)"
    console_user="$(/usr/bin/stat -f '%Su' /dev/console)"

    case "$console_uid" in
        ''|*[!0-9]*)
            die "Console UID is not numeric: $console_uid"
            return 1
            ;;
    esac

    if [ "$console_uid" -lt 501 ]; then
        die "Console UID is not a normal graphical user: $console_uid"
        return 1
    fi

    case "$console_user" in
        root|loginwindow|_mbsetupuser|'')
            die "Console account is not a normal graphical user: $console_user"
            return 1
            ;;
    esac

    console_home="$(
        /usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory |
            /usr/bin/sed 's/^NFSHomeDirectory: //'
    )"

    if [ -z "$console_home" ] || [ ! -d "$console_home" ]; then
        die "Could not resolve a valid home directory for $console_user"
        return 1
    fi

    if ! sudo /bin/launchctl print "gui/$console_uid" >/dev/null 2>&1; then
        die "GUI session gui/$console_uid does not exist"
        return 1
    fi
}

find_user_login_keychain() {
    if [ -f "$console_home/Library/Keychains/login.keychain-db" ]; then
        user_login_keychain="$console_home/Library/Keychains/login.keychain-db"
    elif [ -f "$console_home/Library/Keychains/login.keychain" ]; then
        user_login_keychain="$console_home/Library/Keychains/login.keychain"
    else
        die "The console user's login keychain does not exist"
        return 1
    fi
}

password_authenticates() {
    /usr/bin/dscl . -authonly "$1" "$2" >/dev/null 2>&1
}

user_keychain_unlocks() {
    run_as_console_user /usr/bin/security unlock-keychain \
        -p "$2" "$1" >/dev/null 2>&1
}

kcpassword_matches() {
    local decoded_password

    if ! sudo /bin/test -f /etc/kcpassword; then
        return 1
    fi

    if ! decoded_password="$(decode_kcpassword /etc/kcpassword)"; then
        return 1
    fi

    [ "$decoded_password" = "$1" ]
}

begin_bootstrap_transaction() {
    bootstrap_temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uuremote-bootstrap.XXXXXX")"
    /bin/chmod 0700 "$bootstrap_temp_dir"

    if sudo /bin/test -f /etc/kcpassword; then
        original_kcpassword_existed=1
        sudo /bin/cp -p /etc/kcpassword "$bootstrap_temp_dir/original-kcpassword"
    else
        original_kcpassword_existed=0
    fi

    if sudo /usr/bin/dscl . -read /Users/root ShadowHashData >/dev/null 2>&1; then
        original_root_shadow_hash_existed=1
    fi

    if sudo /usr/bin/dscl . -read /Users/root AuthenticationAuthority >/dev/null 2>&1; then
        original_root_authentication_authority_existed=1
    fi

    transaction_active=1
}

write_kcpassword_atomically() {
    local encoded_staging
    local kcpassword_temp
    local decoded_password

    encoded_staging="$bootstrap_temp_dir/kcpassword.new"
    printf '%s' "$account_password" | encode_kcpassword "$encoded_staging"

    if ! kcpassword_temp="$(sudo /usr/bin/mktemp /etc/.kcpassword.uuremote.XXXXXX)"; then
        return 1
    fi

    if ! sudo /bin/cp "$encoded_staging" "$kcpassword_temp" ||
        ! sudo /usr/sbin/chown root:wheel "$kcpassword_temp" ||
        ! sudo /bin/chmod 0600 "$kcpassword_temp" ||
        ! sudo /bin/mv -f "$kcpassword_temp" /etc/kcpassword
    then
        sudo /bin/rm -f -- "$kcpassword_temp"
        return 1
    fi

    kcpassword_changed=1

    if ! decoded_password="$(decode_kcpassword /etc/kcpassword)" ||
        [ "$decoded_password" != "$account_password" ]
    then
        unset decoded_password
        return 1
    fi

    unset decoded_password
    echo "/etc/kcpassword verified"
}

restore_original_kcpassword() {
    local kcpassword_temp

    if [ "$original_kcpassword_existed" -eq 0 ]; then
        sudo /bin/rm -f -- /etc/kcpassword
        return
    fi

    kcpassword_temp="$(sudo /usr/bin/mktemp /etc/.kcpassword.uuremote.XXXXXX)"

    if ! sudo /bin/cp "$bootstrap_temp_dir/original-kcpassword" "$kcpassword_temp" ||
        ! sudo /usr/sbin/chown root:wheel "$kcpassword_temp" ||
        ! sudo /bin/chmod 0600 "$kcpassword_temp" ||
        ! sudo /bin/mv -f "$kcpassword_temp" /etc/kcpassword
    then
        sudo /bin/rm -f -- "$kcpassword_temp"
        return 1
    fi
}

configure_console_user() {
    local account_already_configured=0
    local decoded_kcpassword=""

    if [ "$original_kcpassword_existed" -eq 1 ]; then
        decoded_kcpassword="$(decode_kcpassword "$bootstrap_temp_dir/original-kcpassword")"
    fi

    if password_authenticates "$console_user" "$account_password"; then
        account_already_configured=1
        echo "Console account password already configured"
    elif [ -n "$decoded_kcpassword" ] &&
        password_authenticates "$console_user" "$decoded_kcpassword"
    then
        old_account_password="$decoded_kcpassword"
    else
        echo "Neither the requested password nor decoded kcpassword authenticates $console_user" >&2
        unset decoded_kcpassword
        return 1
    fi

    if user_keychain_unlocks "$user_login_keychain" "$account_password"; then
        echo "Console login keychain password already configured"
    else
        if [ -n "$decoded_kcpassword" ] &&
            user_keychain_unlocks "$user_login_keychain" "$decoded_kcpassword"
        then
            old_keychain_password="$decoded_kcpassword"
        elif [ -n "$old_account_password" ] &&
            user_keychain_unlocks "$user_login_keychain" "$old_account_password"
        then
            old_keychain_password="$old_account_password"
        else
            echo "Could not unlock the console login keychain with a known password" >&2
            unset decoded_kcpassword
            return 1
        fi

        if ! run_as_console_user /usr/bin/security set-keychain-password \
            -o "$old_keychain_password" -p "$account_password" "$user_login_keychain"
        then
            unset decoded_kcpassword
            return 1
        fi

        user_keychain_changed=1

        if ! user_keychain_unlocks "$user_login_keychain" "$account_password"; then
            echo "Console login keychain did not accept the requested password" >&2
            rollback_console_user_transaction || true
            unset decoded_kcpassword
            return 1
        fi
    fi

    echo "console login keychain verified"

    if [ "$account_already_configured" -eq 0 ]; then
        if ! sudo /usr/bin/dscl . -passwd "/Users/$console_user" \
            "$old_account_password" "$account_password"
        then
            rollback_console_user_transaction || true
            unset decoded_kcpassword
            return 1
        fi

        user_password_changed=1

        if ! password_authenticates "$console_user" "$account_password"; then
            echo "Console account did not accept the requested password" >&2
            rollback_console_user_transaction || true
            unset decoded_kcpassword
            return 1
        fi
    fi

    echo "console account password verified"

    if kcpassword_matches "$account_password"; then
        echo "/etc/kcpassword already configured"
        echo "/etc/kcpassword verified"
    elif ! write_kcpassword_atomically; then
        echo "Could not replace and verify /etc/kcpassword" >&2
        rollback_console_user_transaction || true
        unset decoded_kcpassword
        return 1
    fi

    unset decoded_kcpassword
}

rollback_console_user_transaction() {
    local rollback_failed=0

    if [ "$kcpassword_changed" -eq 1 ]; then
        if restore_original_kcpassword; then
            kcpassword_changed=0
        else
            echo "Failed to restore /etc/kcpassword" >&2
            rollback_failed=1
        fi
    fi

    if [ "$user_password_changed" -eq 1 ]; then
        if sudo /usr/bin/dscl . -passwd "/Users/$console_user" \
            "$account_password" "$old_account_password" &&
            password_authenticates "$console_user" "$old_account_password"
        then
            user_password_changed=0
        else
            echo "Failed to restore the console account password" >&2
            rollback_failed=1
        fi
    fi

    if [ "$user_keychain_changed" -eq 1 ]; then
        if run_as_console_user /usr/bin/security set-keychain-password \
            -o "$account_password" -p "$old_keychain_password" "$user_login_keychain" &&
            user_keychain_unlocks "$user_login_keychain" "$old_keychain_password"
        then
            user_keychain_changed=0
        else
            echo "Failed to restore the console login keychain password" >&2
            rollback_failed=1
        fi
    fi

    return "$rollback_failed"
}

finish_bootstrap_transaction() {
    if [ "$root_keychain_replaced" -eq 1 ]; then
        echo "Preserving transaction directory because the root keychain backup still requires recovery: $bootstrap_temp_dir" >&2
        transaction_active=0
        return 1
    fi

    if [ -n "$bootstrap_temp_dir" ] && [ -d "$bootstrap_temp_dir" ]; then
        sudo /bin/rm -rf -- "$bootstrap_temp_dir"
    fi

    bootstrap_temp_dir=""
    transaction_active=0
}

root_is_disabled() {
    sudo /usr/bin/dscl -plist . -read /Users/root 2>/dev/null |
        /usr/bin/python3 -c '
import plistlib
import sys

record = plistlib.loads(sys.stdin.buffer.read())
authentication_authorities = None

for key, value in record.items():
    if key.endswith("AuthenticationAuthority"):
        authentication_authorities = value
        break

# A default disabled root record has no AuthenticationAuthority at all.
if authentication_authorities is None:
    raise SystemExit(0)

if isinstance(authentication_authorities, (str, bytes)):
    authentication_authorities = [authentication_authorities]

for authority in authentication_authorities:
    if isinstance(authority, bytes):
        authority = authority.decode("utf-8", errors="replace")
    if "DisabledUser" in authority:
        raise SystemExit(0)

raise SystemExit(1)
'
}

ensure_root_disabled_authentication() {
    if root_is_disabled; then
        return 0
    fi

    sudo /usr/bin/dscl . -append /Users/root \
        AuthenticationAuthority ';DisabledUser;' &&
        root_is_disabled
}

verify_root_password_hash() {
    local candidate_password="$1"
    local shadow_plist="$bootstrap_temp_dir/root-shadow-hash.plist"
    local verification_status=1

    if ! sudo /usr/bin/dscl -plist . -read /Users/root ShadowHashData >"$shadow_plist"; then
        echo "Root hash verifier: ShadowHashData is absent" >&2
        /bin/rm -f -- "$shadow_plist"
        return 1
    fi

    /bin/chmod 0600 "$shadow_plist"

    if printf '%s' "$candidate_password" | /usr/bin/python3 -c '
import hashlib
import hmac
import plistlib
import pathlib
import sys

outer = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
values = None
for key, value in outer.items():
    if key.endswith("ShadowHashData"):
        values = value
        break
if values is None:
    print("Root hash verifier: outer ShadowHashData value is absent", file=sys.stderr)
    raise SystemExit(1)
if isinstance(values, list):
    if not values:
        print("Root hash verifier: ShadowHashData list is empty", file=sys.stderr)
        raise SystemExit(1)
    values = values[0]
if isinstance(values, str):
    encoded_hex = "".join(values.strip().strip("<>").split())
    try:
        values = bytes.fromhex(encoded_hex)
    except ValueError:
        print("Root hash verifier: ShadowHashData text is not hexadecimal", file=sys.stderr)
        raise SystemExit(1)
if not isinstance(values, bytes):
    print("Root hash verifier: ShadowHashData is not binary plist data", file=sys.stderr)
    raise SystemExit(1)
inner = plistlib.loads(values)
hash_data = inner.get("SALTED-SHA512-PBKDF2")
if not isinstance(hash_data, dict):
    print("Root hash verifier: PBKDF2 dictionary is absent", file=sys.stderr)
    raise SystemExit(1)
password_bytes = sys.stdin.buffer.read()
derived = hashlib.pbkdf2_hmac(
    "sha512",
    password_bytes,
    hash_data["salt"],
    int(hash_data["iterations"]),
    dklen=len(hash_data["entropy"]),
)
if not hmac.compare_digest(derived, hash_data["entropy"]):
    print("Root hash verifier: candidate does not match PBKDF2 data", file=sys.stderr)
    raise SystemExit(1)
' "$shadow_plist"
    then
        verification_status=0
    fi

    /bin/rm -f -- "$shadow_plist"
    return "$verification_status"
}

find_root_login_keychain() {
    root_login_keychain=""

    if sudo /bin/test -f /var/root/Library/Keychains/login.keychain-db; then
        root_login_keychain="/var/root/Library/Keychains/login.keychain-db"
    elif sudo /bin/test -f /var/root/Library/Keychains/login.keychain; then
        root_login_keychain="/var/root/Library/Keychains/login.keychain"
    fi
}

root_keychain_unlocks() {
    sudo /usr/bin/security unlock-keychain -p "$2" "$1" >/dev/null 2>&1
}

configure_root_keychain() {
    local candidate
    local decoded_original=""
    local candidates=()

    find_root_login_keychain

    if [ -z "$root_login_keychain" ]; then
        echo "No root login keychain exists; leaving it absent"
        return 0
    fi

    if root_keychain_unlocks "$root_login_keychain" "$account_password"; then
        echo "Root login keychain password already configured"
        echo "root login keychain verified"
        return 0
    fi

    if [ "$original_kcpassword_existed" -eq 1 ]; then
        decoded_original="$(decode_kcpassword "$bootstrap_temp_dir/original-kcpassword")"
    fi

    candidates=("$old_root_password" "$old_account_password" "$old_keychain_password" "$decoded_original")

    for candidate in "${candidates[@]}"; do
        if [ -n "$candidate" ] &&
            root_keychain_unlocks "$root_login_keychain" "$candidate"
        then
            old_root_keychain_password="$candidate"
            break
        fi
    done

    if [ -n "$old_root_keychain_password" ]; then
        if ! sudo /usr/bin/security set-keychain-password \
            -o "$old_root_keychain_password" -p "$account_password" "$root_login_keychain"
        then
            unset decoded_original candidate
            return 1
        fi

        root_keychain_password_changed=1

        if ! root_keychain_unlocks "$root_login_keychain" "$account_password"; then
            unset decoded_original candidate
            return 1
        fi
    else
        root_keychain_original_path="$root_login_keychain"
        root_keychain_backup="$bootstrap_temp_dir/root-login-keychain.backup"

        if ! sudo /bin/mv "$root_login_keychain" "$root_keychain_backup"; then
            unset decoded_original candidate
            return 1
        fi

        root_keychain_replaced=1

        if ! sudo /usr/bin/security create-keychain \
            -p "$account_password" "$root_login_keychain" ||
            ! sudo /usr/sbin/chown root:wheel "$root_login_keychain" ||
            ! root_keychain_unlocks "$root_login_keychain" "$account_password"
        then
            unset decoded_original candidate
            return 1
        fi
    fi

    unset decoded_original candidate
    echo "root login keychain verified"
}

rollback_root_keychain() {
    local rollback_failed=0

    if [ "$root_keychain_replaced" -eq 1 ]; then
        if ! sudo /bin/rm -f -- "$root_keychain_original_path" ||
            ! sudo /bin/mv "$root_keychain_backup" "$root_keychain_original_path"
        then
            echo "Failed to restore the original root login keychain" >&2
            rollback_failed=1
        else
            root_keychain_replaced=0
            root_keychain_backup=""
        fi
    elif [ "$root_keychain_password_changed" -eq 1 ]; then
        if sudo /usr/bin/security set-keychain-password \
            -o "$account_password" -p "$old_root_keychain_password" "$root_login_keychain" &&
            root_keychain_unlocks "$root_login_keychain" "$old_root_keychain_password"
        then
            root_keychain_password_changed=0
        else
            echo "Failed to restore the root login keychain password" >&2
            rollback_failed=1
        fi
    fi

    return "$rollback_failed"
}

commit_root_keychain_backup() {
    if [ "$root_keychain_replaced" -eq 1 ] && [ -n "$root_keychain_backup" ]; then
        sudo /bin/rm -f -- "$root_keychain_backup"
        root_keychain_replaced=0
        root_keychain_backup=""
    fi

    root_keychain_password_changed=0
}

rollback_root_password() {
    if [ "$root_password_changed" -eq 0 ]; then
        return 0
    fi

    if [ -z "$old_root_password" ] &&
        [ "$original_root_shadow_hash_existed" -eq 0 ]
    then
        sudo /usr/bin/dscl . -delete /Users/root ShadowHashData >/dev/null 2>&1 || true

        if [ "$original_root_authentication_authority_existed" -eq 0 ]; then
            sudo /usr/bin/dscl . -delete /Users/root AuthenticationAuthority \
                >/dev/null 2>&1 || true
        fi

        if root_is_disabled &&
            ! sudo /usr/bin/dscl . -read /Users/root ShadowHashData >/dev/null 2>&1
        then
            root_password_changed=0
            return 0
        fi

        echo "Failed to restore the original passwordless disabled-root state" >&2
        return 1
    fi

    if [ -z "$old_root_password" ]; then
        echo "The previous root password was not discoverable; root remains set to the requested password" >&2
        return 1
    fi

    if sudo /usr/bin/dscl . -passwd /Users/root "$old_root_password" &&
        verify_root_password_hash "$old_root_password" &&
        root_is_disabled
    then
        root_password_changed=0
        return 0
    fi

    echo "Failed to restore the previous disabled-root password" >&2
    return 1
}

configure_root() {
    local candidate
    local decoded_original=""
    local candidates=()

    if ! root_is_disabled; then
        echo "Root is not disabled before password configuration" >&2
        return 1
    fi

    if [ "$original_kcpassword_existed" -eq 1 ]; then
        decoded_original="$(decode_kcpassword "$bootstrap_temp_dir/original-kcpassword")"
    fi

    candidates=("$old_account_password" "$old_keychain_password" "$decoded_original")

    if ! verify_root_password_hash "$account_password"; then
        for candidate in "${candidates[@]}"; do
            if [ -n "$candidate" ] && verify_root_password_hash "$candidate"; then
                old_root_password="$candidate"
                break
            fi
        done
    fi

    if ! configure_root_keychain; then
        rollback_root_keychain || true
        unset decoded_original candidate
        return 1
    fi

    if verify_root_password_hash "$account_password"; then
        echo "Root password already configured"
    else
        if ! sudo /usr/bin/dscl . -passwd /Users/root "$account_password"; then
            rollback_root_keychain || true
            unset decoded_original candidate
            return 1
        fi

        root_password_changed=1

        if ! ensure_root_disabled_authentication; then
            echo "Could not restore disabled-root authentication after setting its password" >&2
            rollback_root_password || true
            rollback_root_keychain || true
            unset decoded_original candidate
            return 1
        fi

        if ! verify_root_password_hash "$account_password"; then
            echo "Root password hash did not accept the requested password" >&2
            rollback_root_password || true
            rollback_root_keychain || true
            unset decoded_original candidate
            return 1
        fi
    fi

    echo "root password hash verified"

    if ! root_is_disabled; then
        echo "Root was enabled unexpectedly during password configuration" >&2
        rollback_root_password || true
        rollback_root_keychain || true
        unset decoded_original candidate
        return 1
    fi

    echo "root remains disabled"
    unset decoded_original candidate
}

language_settings_match() {
    local expected_first_language="$1"

    run_as_console_user /usr/bin/defaults export NSGlobalDomain - 2>/dev/null |
        /usr/bin/python3 -c '
import plistlib
import sys

expected_first = sys.argv[1]
preferences = plistlib.loads(sys.stdin.buffer.read())
languages = preferences.get("AppleLanguages")
locale = preferences.get("AppleLocale")
measurement = preferences.get("AppleMeasurementUnits")
metric = preferences.get("AppleMetricUnits")

if languages != [expected_first, "en-SG"]:
    raise SystemExit(1)
if locale != "zh_SG":
    raise SystemExit(1)
if measurement != "Centimeters":
    raise SystemExit(1)
if metric not in (True, 1):
    raise SystemExit(1)
' "$expected_first_language"
}

dismiss_safe_restart_prompt() {
    local prompt_result

    if ! prompt_result="$(run_as_console_user /usr/bin/osascript <<'APPLESCRIPT'
on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem
            if attributeValue is not missing value then return attributeValue as text
        end try
    end tell
    return ""
end attributeText

on isRestartContext(contextText)
    ignoring case
        if contextText contains "restart" then return true
        if contextText contains "log out" then return true
    end ignoring

    if contextText contains "重新启动" then return true
    if contextText contains "重启" then return true
    if contextText contains "退出登录" then return true
    return false
end isRestartContext

on inspectProcess(processName)
    tell application "System Events"
        if not (exists application process processName) then return "NONE"
        set targetProcess to application process processName

        repeat with targetWindow in windows of targetProcess
            set contextText to my attributeText(targetWindow, "AXTitle") & " " & my attributeText(targetWindow, "AXDescription")

            repeat with uiText in static texts of targetWindow
                set contextText to contextText & " " & my attributeText(uiText, "AXValue")
            end repeat

            if my isRestartContext(contextText) then
                set safeButton to missing value
                set safeTitle to ""

                repeat with uiButton in buttons of targetWindow
                    set buttonTitle to my attributeText(uiButton, "AXTitle")
                    set buttonDescription to my attributeText(uiButton, "AXDescription")

                    repeat with acceptedTitle in {"Not Now", "Later", "Restart Later", "稍后", "暂不", "以后再说"}
                        set acceptedText to contents of acceptedTitle as text
                        if buttonTitle is acceptedText or buttonDescription is acceptedText then
                            set safeButton to contents of uiButton
                            set safeTitle to acceptedText
                            exit repeat
                        end if
                    end repeat
                end repeat

                if safeButton is missing value then return "UNSAFE|" & contextText
                perform action "AXPress" of safeButton
                return "DISMISSED|" & safeTitle
            end if
        end repeat
    end tell

    return "NONE"
end inspectProcess

repeat 8 times
    repeat with processName in {"System Settings", "UserNotificationCenter"}
        set inspectionResult to my inspectProcess(contents of processName as text)
        if inspectionResult starts with "DISMISSED|" then return inspectionResult
        if inspectionResult starts with "UNSAFE|" then error "Restart-related dialog has no recognized safe negative action: " & inspectionResult
    end repeat
    delay 0.25
end repeat

return "No restart-related prompt appeared"
APPLESCRIPT
)"; then
        echo "Could not safely dismiss the language or region restart prompt" >&2
        return 1
    fi

    echo "$prompt_result"
}

configure_language_and_region() {
    local effective_first_language
    local language_or_region_changed=0

    if language_settings_match "zh-Hans-SG"; then
        effective_first_language="zh-Hans-SG"
        echo "Language and region settings already configured"
    elif language_settings_match "zh-Hans-CN"; then
        effective_first_language="zh-Hans-CN"
        echo "Language and region settings already configured with the supported fallback"
    else
        language_or_region_changed=1
        run_as_console_user /usr/bin/defaults write NSGlobalDomain AppleLanguages \
            -array "zh-Hans-SG" "en-SG"
        run_as_console_user /usr/bin/defaults write NSGlobalDomain AppleLocale \
            -string "zh_SG"
        run_as_console_user /usr/bin/defaults write NSGlobalDomain AppleMeasurementUnits \
            -string "Centimeters"
        run_as_console_user /usr/bin/defaults write NSGlobalDomain AppleMetricUnits \
            -bool true

        if language_settings_match "zh-Hans-SG"; then
            effective_first_language="zh-Hans-SG"
        else
            run_as_console_user /usr/bin/defaults write NSGlobalDomain AppleLanguages \
                -array "zh-Hans-CN" "en-SG"

            if ! language_settings_match "zh-Hans-CN"; then
                echo "Could not verify Simplified Chinese, English Singapore, and Singapore region settings" >&2
                return 1
            fi

            effective_first_language="zh-Hans-CN"
        fi
    fi

    echo "language order verified: $effective_first_language, en-SG"
    echo "Singapore locale and region verified: zh_SG"

    if [ "$language_or_region_changed" = "1" ]; then
        dismiss_safe_restart_prompt
    fi
}

terminal_preferences_have_profiles() {
    run_as_console_user /usr/bin/defaults export com.apple.Terminal - 2>/dev/null |
        /usr/bin/python3 -c '
import plistlib
import sys

preferences = plistlib.loads(sys.stdin.buffer.read())
profiles = preferences.get("Window Settings")
raise SystemExit(0 if isinstance(profiles, dict) and bool(profiles) else 1)
'
}

initialize_terminal_preferences_if_needed() {
    local terminal_was_running=0
    local attempt

    if terminal_preferences_have_profiles; then
        return 0
    fi

    if run_as_console_user /usr/bin/pgrep -x Terminal >/dev/null 2>&1; then
        terminal_was_running=1
        echo "Terminal is already running; waiting for its initial profiles without closing it"
    else
        echo "Initializing the fresh Terminal preference domain in the background"
        run_as_console_user /usr/bin/open -gj -a Terminal
    fi

    for ((attempt=1; attempt<=20; attempt++)); do
        if terminal_preferences_have_profiles; then
            break
        fi
        /bin/sleep 0.25
    done

    if [ "$terminal_was_running" -eq 0 ]; then
        run_as_console_user /usr/bin/osascript \
            -e 'tell application "Terminal" to quit' >/dev/null 2>&1 || true

        for ((attempt=1; attempt<=20; attempt++)); do
            if ! run_as_console_user /usr/bin/pgrep -x Terminal >/dev/null 2>&1; then
                break
            fi
            /bin/sleep 0.25
        done

        if run_as_console_user /usr/bin/pgrep -x Terminal >/dev/null 2>&1; then
            run_as_console_user /usr/bin/killall Terminal >/dev/null 2>&1 || true
        fi
    fi

    for ((attempt=1; attempt<=20; attempt++)); do
        if terminal_preferences_have_profiles; then
            echo "Terminal default profiles initialized"
            return 0
        fi
        /bin/sleep 0.25
    done

    echo "Terminal Window Settings profiles are unavailable after initialization" >&2
    return 1
}

terminal_preferences_match() {
    run_as_console_user /usr/bin/defaults export com.apple.Terminal - 2>/dev/null |
        /usr/bin/python3 -c '
import plistlib
import sys

preferences = plistlib.loads(sys.stdin.buffer.read())
profiles = preferences.get("Window Settings")
valid = isinstance(profiles, dict) and bool(profiles)
valid = valid and all(
    not isinstance(profile, dict) or profile.get("shellExitAction") == 0
    for profile in profiles.values()
)
raise SystemExit(0 if valid else 1)
'
}

configure_terminal_preferences() {
    local terminal_before="$bootstrap_temp_dir/com.apple.Terminal.before.plist"
    local terminal_after="$bootstrap_temp_dir/com.apple.Terminal.after.plist"

    initialize_terminal_preferences_if_needed

    if ! run_as_console_user /usr/bin/defaults export com.apple.Terminal - \
        >"$terminal_before" 2>/dev/null; then
        echo "Could not export Terminal preferences" >&2
        return 1
    fi

    transform_terminal_preferences "$terminal_before" "$terminal_after"

    if ! run_as_console_user /usr/bin/defaults import com.apple.Terminal - \
        <"$terminal_after"; then
        echo "Could not import Terminal preferences" >&2
        return 1
    fi

    if ! terminal_preferences_match; then
        echo "Terminal close-on-shell-exit preference verification failed" >&2
        return 1
    fi

    echo "Terminal profiles verified: close the window when the shell exits"
}

desktop_preferences_match() {
    local key_repeat
    local initial_key_repeat

    key_repeat="$(run_as_console_user /usr/bin/defaults read NSGlobalDomain KeyRepeat 2>/dev/null || true)"
    initial_key_repeat="$(run_as_console_user /usr/bin/defaults read NSGlobalDomain InitialKeyRepeat 2>/dev/null || true)"

    [ "$key_repeat" = "$KEY_REPEAT_VALUE" ] &&
        [ "$initial_key_repeat" = "$INITIAL_KEY_REPEAT_VALUE" ] &&
        terminal_preferences_match
}

refresh_localized_desktop() {
    local process_name
    local attempt

    run_as_console_user /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
    run_as_console_user /usr/bin/killall Finder >/dev/null 2>&1 || true
    run_as_console_user /usr/bin/killall SystemUIServer >/dev/null 2>&1 || true
    run_as_console_user /usr/bin/killall ControlCenter >/dev/null 2>&1 || true

    for process_name in Finder SystemUIServer ControlCenter; do
        for ((attempt=1; attempt<=40; attempt++)); do
            if run_as_console_user /usr/bin/pgrep -x "$process_name" >/dev/null 2>&1; then
                break
            fi
            /bin/sleep 0.25
        done

        if ! run_as_console_user /usr/bin/pgrep -x "$process_name" >/dev/null 2>&1; then
            echo "$process_name did not relaunch after the localization refresh" >&2
            return 1
        fi
    done

    if ! run_as_console_user /usr/bin/osascript <<'APPLESCRIPT'
on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem
            if attributeValue is not missing value then return attributeValue as text
        end try
    end tell
    return ""
end attributeText

on delimitedText(textItems)
    set oldDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to "|"
    set outputText to textItems as text
    set AppleScript's text item delimiters to oldDelimiters
    return "|" & outputText & "|"
end delimitedText

tell application "System Events"
    if not (exists application process "Finder") then error "Finder is not running"
    tell application process "Finder"
        if not (exists menu bar 1) then error "Finder menu bar is unavailable"
        set finderTitles to {}
        repeat with menuItem in menu bar items of menu bar 1
            set end of finderTitles to my attributeText(menuItem, "AXTitle")
        end repeat
    end tell

    set clockText to ""
    repeat with processName in {"ControlCenter", "SystemUIServer"}
        if exists application process (contents of processName) then
            tell application process (contents of processName)
                try
                    repeat with menuItem in menu bar items of menu bar 1
                        set clockText to clockText & " " & my attributeText(menuItem, "AXTitle")
                        set clockText to clockText & " " & my attributeText(menuItem, "AXDescription")
                        set clockText to clockText & " " & my attributeText(menuItem, "AXValue")
                    end repeat
                end try
            end tell
        end if
    end repeat
end tell

set finderText to my delimitedText(finderTitles)
repeat with englishMenu in {"File", "Edit", "View", "Go", "Window", "Help"}
    if finderText contains ("|" & (contents of englishMenu) & "|") then
        error "Finder still exposes English menus: " & finderText
    end if
end repeat

set chineseMenuCount to 0
repeat with chineseMenu in {"文件", "编辑", "显示", "查看", "前往", "窗口", "帮助"}
    if finderText contains ("|" & (contents of chineseMenu) & "|") then set chineseMenuCount to chineseMenuCount + 1
end repeat
if chineseMenuCount < 2 then error "Finder Simplified Chinese menus were not verified: " & finderText

repeat with englishDateToken in {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "AM", "PM"}
    ignoring case
        if clockText contains (contents of englishDateToken) then error "Menu-bar clock still exposes English date text: " & clockText
    end ignoring
end repeat

set chineseClockVerified to false
repeat with chineseDateToken in {"月", "周", "星期", "上午", "下午"}
    if clockText contains (contents of chineseDateToken) then set chineseClockVerified to true
end repeat
if not chineseClockVerified then error "Simplified Chinese menu-bar clock was not verified: " & clockText

return "Finder and menu-bar clock localization verified"
APPLESCRIPT
    then
        echo "Could not verify the live Finder and menu-bar clock localization" >&2
        return 1
    fi
}

configure_desktop_preferences() {
    run_as_console_user /usr/bin/defaults write NSGlobalDomain KeyRepeat \
        -int "$KEY_REPEAT_VALUE"
    run_as_console_user /usr/bin/defaults write NSGlobalDomain InitialKeyRepeat \
        -int "$INITIAL_KEY_REPEAT_VALUE"
    configure_terminal_preferences

    if ! desktop_preferences_match; then
        echo "Desktop preference verification failed" >&2
        return 1
    fi

    echo "Keyboard repeat settings verified: fastest rate and shortest delay"
    refresh_localized_desktop
}

rollback_host_transaction_on_exit() {
    local exit_status="$1"
    trap - EXIT

    if [ "$exit_status" -ne 0 ] && [ "$transaction_active" -eq 1 ]; then
        echo "Host bootstrap failed; rolling back credential changes" >&2
        rollback_root_password || true
        rollback_root_keychain || true
        rollback_console_user_transaction || true
        finish_bootstrap_transaction || true
    fi

    unset account_password old_account_password old_keychain_password
    unset old_root_password old_root_keychain_password UUREMOTE_ACCOUNT_PASSWORD
    exit "$exit_status"
}

configure_host() {
    account_password="${UUREMOTE_ACCOUNT_PASSWORD:-}"

    if [ -z "$account_password" ]; then
        die "UUREMOTE_ACCOUNT_PASSWORD is required"
        return 1
    fi

    unset UUREMOTE_ACCOUNT_PASSWORD
    resolve_console_account
    find_user_login_keychain
    begin_bootstrap_transaction
    trap 'rollback_host_transaction_on_exit $?' EXIT

    echo "=== Configuring console account ==="
    configure_console_user
    echo "=== Configuring disabled root account ==="
    configure_root
    echo "=== Configuring language and region ==="
    configure_language_and_region
    echo "=== Configuring desktop preferences ==="
    configure_desktop_preferences

    commit_root_keychain_backup
    root_password_changed=0
    user_keychain_changed=0
    user_password_changed=0
    kcpassword_changed=0
    finish_bootstrap_transaction
    trap - EXIT

    unset account_password old_account_password old_keychain_password
    unset old_root_password old_root_keychain_password
    echo "macOS host bootstrap completed"
}

if [ "$mode" = "self-test-kcpassword" ]; then
    self_test_kcpassword
    exit 0
fi

if [ "$mode" = "self-test-wait-connections" ]; then
    self_test_wait_connections
    exit 0
fi

if [ "$mode" = "self-test-diagnostic-redaction" ]; then
    self_test_diagnostic_redaction
    exit $?
fi

if [ "$mode" = "configure-host" ]; then
    configure_host
    exit 0
fi

if [ "$mode" = "wait-connections" ]; then
    wait_connections "${2:-}"
    exit $?
fi

debug_level="${UUREMOTE_DEBUG:-0}"
evidence_dir="${RUNNER_TEMP:-/tmp}/uuremote-diagnostics"
diagnostic_log="$evidence_dir/diagnostics.log"

case "$debug_level" in
    0|1|2|3)
        ;;
    *)
        echo "Invalid UUREMOTE_DEBUG level: $debug_level (expected 0, 1, 2, or 3)" >&2
        exit 2
        ;;
esac

console_uid="$(stat -f '%u' /dev/console)"
console_user="$(stat -f '%Su' /dev/console)"

echo "=== Environment ==="
/usr/bin/sw_vers
echo "Console UID: $console_uid"
echo "Console user: $console_user"

if [ ! -d "$APP" ]; then
    echo "UURemote does not exist: $APP" >&2
    exit 1
fi

if ! sudo launchctl print "gui/$console_uid" >/dev/null 2>&1; then
    echo "GUI session gui/$console_uid does not exist" >&2
    exit 1
fi

run_in_gui() {
    sudo launchctl asuser "$console_uid" \
        sudo -u "#$console_uid" \
        "$@"
}

set_uuremote_custom_code() {
    local custom_code="${UUREMOTE_CUSTOM_CODE:-}"
    local attempt
    local status

    if ! validate_uuremote_custom_code "$custom_code"; then
        unset custom_code UUREMOTE_CUSTOM_CODE
        echo "UUREMOTE_CUSTOM_CODE must match ^[A-Za-z0-9]{8,16}$" >&2
        return 2
    fi

    unset UUREMOTE_CUSTOM_CODE

    for ((attempt=1; attempt<=120; attempt++)); do
        echo "Waiting to configure UU Remote custom code [$attempt/120] ..."

        if run_in_gui "$CLI" assist set-code "$custom_code" >/dev/null 2>&1; then
            unset custom_code
            echo "UU Remote custom code configured successfully"
            return 0
        else
            status="$?"
        fi

        echo "UU Remote CLI failed with exit code $status; retrying in 500 milliseconds" >&2
        sleep 0.5
    done

    unset custom_code
    echo "UU Remote custom code could not be configured after 120 attempts" >&2
    return 1
}

if [ "$mode" = "set-custom-code" ]; then
    set_uuremote_custom_code
    exit $?
fi

debug_sleep() {
    local diagnostic_seconds="$1"
    local fast_seconds="$2"

    if [ "$debug_level" -ge 1 ]; then
        sleep "$diagnostic_seconds"
    elif [ "$fast_seconds" != "0" ]; then
        sleep "$fast_seconds"
    fi
}

capture_tcc_database() {
    local database_path="$1"
    local database_label="$2"
    local query

    query="SELECT service, client, client_type, auth_value, auth_reason, flags, last_modified FROM access WHERE service LIKE '%Accessibility%' OR service LIKE '%ScreenCapture%' OR service LIKE '%ListenEvent%' OR service LIKE '%PostEvent%' ORDER BY service, client;"

    echo "--- TCC $database_label: $database_path ---"

    if [ ! -e "$database_path" ]; then
        echo "TCC database unavailable: file does not exist"
        return 0
    fi

    if [ "$database_label" = "system" ]; then
        if ! sudo /usr/bin/sqlite3 -header -tabs "$database_path" "$query"; then
            echo "TCC database unavailable: query failed"
        fi
    elif ! /usr/bin/sqlite3 -header -tabs "$database_path" "$query"; then
        echo "TCC database unavailable: query failed"
    fi
}

capture_uuremote_process_states() {
    local process_output=""
    local process_status

    if process_output="$(/bin/ps -axo comm=,state= 2>/dev/null)"; then
        process_status=0
    else
        process_status="$?"
    fi

    if [ "$process_status" -eq 0 ]; then
        if ! printf '%s\n' "$process_output" | /usr/bin/grep -Ei '[U]URemote|[u]uyc-cli'; then
            echo "No UU process matched"
        fi
    else
        echo "UU process state unavailable"
    fi

    printf 'PROCESS_LIST_EXIT=%s\n' "$process_status"
    unset process_output
}

capture_snapshot() {
    local requested_label="${1:-manual}"
    local safe_label
    local timestamp
    local png_path
    local jpeg_path
    local user_tcc_database
    local executable

    if [ "$debug_level" -eq 0 ]; then
        echo "Snapshot skipped because UUREMOTE_DEBUG=0"
        return 0
    fi

    safe_label="$(printf '%s' "$requested_label" | /usr/bin/tr -cd 'A-Za-z0-9._-')"
    if [ -z "$safe_label" ]; then
        safe_label="manual"
    fi

    timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
    /bin/mkdir -p "$evidence_dir"
    png_path="$evidence_dir/${safe_label}-${timestamp}.png"
    jpeg_path="$evidence_dir/${safe_label}-${timestamp}.jpg"
    user_tcc_database="/Users/$console_user/Library/Application Support/com.apple.TCC/TCC.db"

    {
        echo
        echo "========== SNAPSHOT $safe_label $timestamp =========="
        echo "--- UU process states ---"
        capture_uuremote_process_states

        echo "--- Code signing ---"
        for executable in \
            "$APP/Contents/MacOS/UURemote" \
            "$APP/Contents/MacOS/UURemoteService" \
            "$APP/Contents/MacOS/UURemoteDaemon" \
            "$APP/Contents/Helpers/UURemoteServer"
        do
            echo "executable=$executable"
            if [ -e "$executable" ]; then
                /usr/bin/codesign -dv --verbose=4 "$executable" 2>&1 | /usr/bin/grep -E '^(Identifier|TeamIdentifier|CodeDirectory)=' || true
                /usr/bin/codesign -dr - "$executable" 2>&1 || true
            else
                echo "missing"
            fi
        done

        capture_tcc_database "$user_tcc_database" "user"
        capture_tcc_database "/Library/Application Support/com.apple.TCC/TCC.db" "system"

        echo "--- Sanitized CLI state ---"
        capture_cli_diagnostics
    } | /usr/bin/tee -a "$diagnostic_log"

    if ! run_in_gui /usr/sbin/screencapture -x -t png "$png_path"; then
        echo "Snapshot failed: $safe_label" | /usr/bin/tee -a "$diagnostic_log" >&2
        return 1
    fi

    /usr/bin/sips -s format jpeg -s formatOptions 70 "$png_path" --out "$jpeg_path" >/dev/null
    /bin/rm -f "$png_path"
    echo "UUREMOTE_SNAPSHOT_SAVED:$jpeg_path" | /usr/bin/tee -a "$diagnostic_log"
}

dismiss_uuremote_private_window_prompt() {
    local prompt_result

    if ! prompt_result="$(run_in_gui /usr/bin/osascript <<'APPLESCRIPT'
on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem
            if attributeValue is not missing value then return attributeValue as text
        end try
    end tell

    return ""
end attributeText

on inspectPrompt(shouldPressAllow)
    tell application "System Events"
        if not (exists application process "UserNotificationCenter") then return ""
        set notificationProcess to application process "UserNotificationCenter"

        repeat with promptWindow in windows of notificationProcess
            set contextText to my attributeText(promptWindow, "AXDescription")
            set allowButton to missing value
            set openSettingsButton to missing value

            repeat with uiText in static texts of promptWindow
                set textValue to my attributeText(uiText, "AXValue")
                if textValue is not "" then set contextText to contextText & " " & textValue
            end repeat

            repeat with uiButton in buttons of promptWindow
                set buttonTitle to my attributeText(uiButton, "AXTitle")
                set buttonDescription to my attributeText(uiButton, "AXDescription")

                if buttonTitle is "Allow" or buttonDescription is "Allow" or buttonTitle is "允许" or buttonDescription is "允许" then
                    set allowButton to contents of uiButton
                end if

                if buttonTitle is "Open System Settings" or buttonDescription is "Open System Settings" or buttonTitle is "打开系统设置" or buttonDescription is "打开系统设置" then
                    set openSettingsButton to contents of uiButton
                end if
            end repeat

            ignoring case
                if contextText contains "com.netease.uuremote.agent" then
                    if allowButton is missing value or openSettingsButton is missing value then
                        return "MISSING_STRUCTURE|context=[" & contextText & "]"
                    end if

                    if shouldPressAllow then perform action "AXPress" of allowButton
                    return "MATCHED|context=[" & contextText & "]"
                end if
            end ignoring
        end repeat
    end tell

    return ""
end inspectPrompt

set promptDetails to ""
repeat 4 times
    set promptDetails to my inspectPrompt(false)
    if promptDetails is not "" then exit repeat
    delay 0.25
end repeat

if promptDetails is "" then return "UURemote private window picker was not present during snapshot"

set pressedDetails to my inspectPrompt(true)
if pressedDetails starts with "MISSING_STRUCTURE|" then error "Matched the UURemote screen-sharing prompt but its recognized action structure is incomplete: " & pressedDetails
if pressedDetails is "" then error "UURemote private window picker disappeared before its Allow button could be pressed"

repeat 20 times
    if my inspectPrompt(false) is "" then return "UURemote private window picker allowed during snapshot; " & pressedDetails
    delay 0.1
end repeat

error "UURemote private window picker remained visible after pressing Allow during snapshot"
APPLESCRIPT
)"; then
        echo "UUREMOTE_PERMISSION: failed to handle the UURemote private window picker during snapshot" >&2
        return 1
    fi

    echo "UUREMOTE_PERMISSION: $prompt_result"
}

case "$mode" in
    configure)
        ;;
    snapshot)
        dismiss_uuremote_private_window_prompt
        capture_snapshot "${2:-manual}"
        exit 0
        ;;
    *)
        echo "Usage: $0 [configure | snapshot LABEL]" >&2
        exit 2
        ;;
esac

wait_for_cli() {
    local output
    local attempt

    for ((attempt=1; attempt<=40; attempt++)); do
        if output="$(run_in_gui "$CLI" status 2>/dev/null)" &&
            printf '%s' "$output" | /usr/bin/grep -q '"success" : true'
        then
            printf '%s\n' "$output"
            return 0
        fi

        sleep 0.5
    done

    return 1
}

ensure_assist_allowed() {
    local output
    local attempt

    for ((attempt=1; attempt<=120; attempt++)); do
        if output="$(run_in_gui "$CLI" assist allow on 2>/dev/null)" &&
            printf '%s' "$output" | /usr/bin/grep -q '"enabled" : true'
        then
            printf '%s\n' "$output"
            return 0
        fi

        sleep 0.5
    done

    return 1
}

echo "=== Starting UURemote and enabling unattended access ==="
run_in_gui /usr/bin/open "$APP"

if ! cli_status="$(wait_for_cli)"; then
    echo "UURemote CLI did not become ready within 20 seconds" >&2
    exit 1
fi

printf '%s\n' "$cli_status"

if ! assist_status="$(ensure_assist_allowed)"; then
    echo "Could not enable unattended control within 60 seconds" >&2
    exit 1
fi

printf '%s\n' "$assist_status"
echo "Unattended control is enabled"

if [ ! -f /etc/kcpassword ]; then
    echo "Automatic-login password file /etc/kcpassword does not exist" >&2
    exit 1
fi

runner_password="$(decode_kcpassword /etc/kcpassword)"

if [ -z "$runner_password" ]; then
    echo "Could not decode the automatic-login password" >&2
    exit 1
fi

if ! /usr/bin/dscl . -authonly "$console_user" "$runner_password"; then
    echo "The decoded automatic-login password is not valid for $console_user" >&2
    unset runner_password
    exit 1
fi

echo "=== Opening Privacy & Security settings ==="

run_in_gui /usr/bin/killall "System Settings" >/dev/null 2>&1 || true
debug_sleep 2 0.5
run_in_gui /usr/bin/open -a "System Settings"
debug_sleep 2 0.5

echo "=== Adding UURemote and enabling privacy permissions ==="

screenshot_dir="$evidence_dir"
if [ "$debug_level" -ge 1 ]; then
    /bin/mkdir -p "$screenshot_dir"
else
    screenshot_dir=""
fi

run_permission() {
    local permission_kind="$1"
    local permission_target_path

    case "$permission_kind" in
        accessibility-main)
            # The main process checks and reports the keyboard/mouse
            # permission state to the remote client.
            permission_target_path="$APP"
            ;;
        screen-capture)
            permission_target_path="$APP"
            ;;
        agent-private-picker)
            permission_target_path="$APP"
            ;;
        *)
            echo "Unsupported permission kind: $permission_kind" >&2
            return 1
            ;;
    esac

    run_in_gui /usr/bin/osascript - "$runner_password" "$screenshot_dir" "$permission_kind" "$permission_target_path" "$debug_level" <<'APPLESCRIPT'
property settingsProcessName : "System Settings"
property targetApplicationPath : ""
property targetApplicationNames : {}
property activeDebugLevel : 0

on settleDelay(diagnosticSeconds, fastSeconds)
    if activeDebugLevel is greater than or equal to 1 then
        delay diagnosticSeconds
    else if fastSeconds is greater than 0 then
        delay fastSeconds
    end if
end settleDelay

on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem

            if attributeValue is not missing value then
                return attributeValue as text
            end if
        end try
    end tell

    return ""
end attributeText

on isSwitchControl(uiItem)
    tell application "System Events"
        try
            set itemRole to role of uiItem as text
            set itemSubrole to my attributeText(uiItem, "AXSubrole")

            if itemRole is "AXCheckBox" then return true
            if itemRole is "AXSwitch" then return true
            if itemSubrole is "AXSwitch" then return true
        end try
    end tell

    return false
end isSwitchControl

on switchIsEnabled(uiItem)
    tell application "System Events"
        try
            set itemValue to value of uiItem

            if itemValue is true then return true
            if itemValue is 1 then return true
            if (itemValue as text) is "1" then return true
            if (itemValue as text) is "true" then return true
        end try
    end tell

    return false
end switchIsEnabled

on textMatchesTarget(textValue)
    ignoring case
        repeat with candidateName in targetApplicationNames
            set candidateText to contents of candidateName as text

            if textValue is candidateText then return true
        end repeat
    end ignoring

    return false
end textMatchesTarget

on listContainsText(textValues, targetText)
    ignoring case
        repeat with existingText in textValues
            if (contents of existingText as text) is targetText then return true
        end repeat
    end ignoring

    return false
end listContainsText

on getPermissionOutline(settingsProcess)
    try
        -- System Settings occasionally stops answering a recursive AX query
        -- while rebuilding a Privacy & Security page. Let the caller retry
        -- instead of allowing one Apple event to hold the workflow forever.
        with timeout of 10 seconds
            tell application "System Events"
                set candidateOutline to missing value
                set candidateTop to 1000000
                set allItems to entire contents of window 1 of settingsProcess

                repeat with uiItem in allItems
                    try
                        if (role of uiItem as text) is "AXOutline" then
                            set itemPosition to position of uiItem
                            set itemSize to size of uiItem
                            set itemWidth to item 1 of itemSize
                            set itemHeight to item 2 of itemSize
                            set itemTop to item 2 of itemPosition

                            -- A privacy permission list is the first wide,
                            -- non-empty outline in the main settings pane.
                            if itemWidth is greater than or equal to 300 and itemHeight is greater than or equal to 40 then
                                if itemTop is less than candidateTop then
                                    set candidateOutline to contents of uiItem
                                    set candidateTop to itemTop
                                end if
                            end if
                        end if
                    end try
                end repeat

                return candidateOutline
            end tell
        end timeout
    on error errorMessage number errorNumber
        if errorNumber is -1712 then return missing value
    end try

    return missing value
end getPermissionOutline

on getOutlineRows(targetOutline)
    tell application "System Events"
        return rows of targetOutline
    end tell
end getOutlineRows

on getRowTitle(targetRow)
    tell application "System Events"
        set rowItems to entire contents of targetRow

        repeat with uiItem in rowItems
            try
                if (role of uiItem as text) is "AXStaticText" then
                    set rowTitle to my attributeText(uiItem, "AXValue")

                    if rowTitle is not "" then return rowTitle
                end if
            end try
        end repeat
    end tell

    return ""
end getRowTitle

on getRowSwitch(targetRow)
    tell application "System Events"
        set rowItems to entire contents of targetRow

        repeat with uiItem in rowItems
            if my isSwitchControl(uiItem) then return contents of uiItem
        end repeat
    end tell

    return missing value
end getRowSwitch

on getRowTitles(targetOutline)
    set rowTitles to {}
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set rowTitle to my getRowTitle(contents of targetRow)

        if rowTitle is not "" then set end of rowTitles to rowTitle
    end repeat

    return rowTitles
end getRowTitles

on findTargetSwitch(targetOutline)
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set actualRow to contents of targetRow
        set rowTitle to my getRowTitle(actualRow)

        if my textMatchesTarget(rowTitle) then
            return my getRowSwitch(actualRow)
        end if
    end repeat

    return missing value
end findTargetSwitch

on findNewSwitch(targetOutline, previousTitles)
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set actualRow to contents of targetRow
        set rowTitle to my getRowTitle(actualRow)

        if rowTitle is not "" and not my listContainsText(previousTitles, rowTitle) then
            return my getRowSwitch(actualRow)
        end if
    end repeat

    return missing value
end findNewSwitch

on findAddButton(settingsProcess, targetOutline)
    tell application "System Events"
        set outlinePosition to position of targetOutline
        set outlineSize to size of targetOutline
        set outlineLeft to item 1 of outlinePosition
        set outlineBottom to (item 2 of outlinePosition) + (item 2 of outlineSize)
        set addCandidates to {}
        set allItems to entire contents of window 1 of settingsProcess

        repeat with uiItem in allItems
            try
                if (role of uiItem as text) is "AXButton" then
                    set itemPosition to position of uiItem
                    set itemSize to size of uiItem
                    set itemLeft to item 1 of itemPosition
                    set itemTop to item 2 of itemPosition
                    set itemWidth to item 1 of itemSize
                    set itemHeight to item 2 of itemSize

                    -- On macOS 26 this plus button is intentionally unlabeled.
                    -- It is the square AXPress button immediately below the
                    -- first outline. The adjacent minus button is only 2 px high.
                    if itemLeft is greater than or equal to outlineLeft and itemLeft is less than or equal to outlineLeft + 25 then
                        if itemTop is greater than or equal to outlineBottom and itemTop is less than or equal to outlineBottom + 25 then
                            if itemWidth is greater than or equal to 8 and itemWidth is less than or equal to 20 then
                                if itemHeight is greater than or equal to 8 and itemHeight is less than or equal to 20 then
                                    set end of addCandidates to contents of uiItem
                                end if
                            end if
                        end if
                    end if
                end if
            end try
        end repeat

        if (count of addCandidates) is 1 then return item 1 of addCandidates
    end tell

    return missing value
end findAddButton

on pressExactButtonInProcess(targetProcess, candidateTitles)
    tell application "System Events"
        repeat with processWindow in windows of targetProcess
            repeat with uiItem in buttons of processWindow
                try
                    if my attributeText(uiItem, "AXRole") is "AXButton" then
                        set itemTitle to my attributeText(uiItem, "AXTitle")

                        repeat with candidateTitle in candidateTitles
                            if itemTitle is (contents of candidateTitle) then
                                perform action "AXPress" of uiItem
                                return itemTitle
                            end if
                        end repeat
                    end if
                end try
            end repeat
        end repeat
    end tell

    return ""
end pressExactButtonInProcess

on processHasWindowTitle(settingsProcess, desiredTitles)
    tell application "System Events"
        set settingsWindows to windows of settingsProcess

        repeat with settingsWindow in settingsWindows
            if my listContainsText(desiredTitles, my attributeText(settingsWindow, "AXTitle")) then return true
        end repeat
    end tell

    return false
end processHasWindowTitle

on isPasswordField(uiItem)
    if my attributeText(uiItem, "AXRole") is not "AXTextField" then return false
    set fieldDescription to my attributeText(uiItem, "AXDescription")
    set fieldTitle to my attributeText(uiItem, "AXTitle")
    if my listContainsText({"Password", "密码"}, fieldDescription) then return true
    if my listContainsText({"Password", "密码"}, fieldTitle) then return true
    return false
end isPasswordField

on visibleWindowDiagnostics()
    tell application "System Events"
        set diagnosticMessages to {}

        repeat with appProcess in application processes
            try
                if visible of appProcess is true and (count of windows of appProcess) is greater than 0 then
                    set processName to name of appProcess as text
                    set focusedRole to ""
                    set focusedDescription to ""

                    try
                        set focusedItem to value of attribute "AXFocusedUIElement" of appProcess
                        set focusedRole to my attributeText(focusedItem, "AXRole")
                        set focusedDescription to my attributeText(focusedItem, "AXDescription")
                    end try

                    repeat with processWindow in windows of appProcess
                        set windowTitle to my attributeText(processWindow, "AXTitle")
                        set end of diagnosticMessages to "process=" & processName & "; window=[" & windowTitle & "]; focusedRole=" & focusedRole & "; focusedDescription=[" & focusedDescription & "]"
                    end repeat
                end if
            end try
        end repeat

        return my joinText(diagnosticMessages)
    end tell
end visibleWindowDiagnostics

on joinText(textValues)
    set savedDelimiters to AppleScript's text item delimiters
    set AppleScript's text item delimiters to ", "
    set joinedText to textValues as text
    set AppleScript's text item delimiters to savedDelimiters
    return joinedText
end joinText

on outlineDiagnostics(targetOutline)
    set diagnosticMessages to {}
    set outlineRows to my getOutlineRows(targetOutline)

    repeat with targetRow in outlineRows
        set actualRow to contents of targetRow
        set rowTitle to my getRowTitle(actualRow)
        set rowSwitch to my getRowSwitch(actualRow)
        set switchText to "missing"

        if rowSwitch is not missing value then
            if my switchIsEnabled(rowSwitch) then
                set switchText to "on"
            else
                set switchText to "off"
            end if
        end if

        set end of diagnosticMessages to "[" & rowTitle & ":" & switchText & "]"
    end repeat

    return my joinText(diagnosticMessages)
end outlineDiagnostics

on stopTargetProcesses()
    do shell script "/usr/bin/pkill -f '/Applications/UURemote.app/' >/dev/null 2>&1 || true"
end stopTargetProcesses

on progressMessage(messageText)
    log "UUREMOTE_PERMISSION: " & messageText
end progressMessage

on windowContext(processWindow)
    tell application "System Events"
        set contextText to my attributeText(processWindow, "AXTitle") & " " & my attributeText(processWindow, "AXDescription")
        set allItems to entire contents of processWindow

        repeat with uiItem in allItems
            try
                if (role of uiItem as text) is "AXStaticText" then
                    set textValue to my attributeText(uiItem, "AXValue")
                    if textValue is not "" then set contextText to contextText & " " & textValue
                end if
            end try
        end repeat
    end tell

    return contextText
end windowContext

on isUURemoteRestartContext(contextText)
    set targetMatched to false

    ignoring case
        repeat with candidateName in targetApplicationNames
            if contextText contains (contents of candidateName as text) then
                set targetMatched to true
                exit repeat
            end if
        end repeat

        if targetMatched is false then return false

        if contextText contains "will not be able to record" and contextText contains "until it quits" then return true
    end ignoring

    if contextText contains "无法录制屏幕" and contextText contains "直至退出" then return true
    return false
end isUURemoteRestartContext

on inspectUURemoteRestartPrompt(shouldPressRestart)
    try
        -- The recording restart confirmation is an attached sheet. Scanning
        -- every descendant of the main System Settings window is both
        -- unnecessary and can block for minutes on macOS 26.
        with timeout of 2 seconds
            tell application "System Events"
                if not (exists application process settingsProcessName) then return ""
                set settingsProcess to application process settingsProcessName

                repeat with processWindow in windows of settingsProcess
                    repeat with promptSheet in sheets of processWindow
                        set actualSheet to contents of promptSheet
                        set contextText to my windowContext(actualSheet)

                        if my isUURemoteRestartContext(contextText) then
                            set restartButton to missing value
                            set restartButtonTitle to ""
                            set allItems to entire contents of actualSheet

                            repeat with uiItem in allItems
                                try
                                    if (role of uiItem as text) is "AXButton" then
                                        set buttonTitle to my attributeText(uiItem, "AXTitle")

                                        if buttonTitle is "Quit & Reopen" or buttonTitle is "Quit and Reopen" or buttonTitle is "退出并重新打开" then
                                            set restartButton to contents of uiItem
                                            set restartButtonTitle to buttonTitle
                                            exit repeat
                                        end if
                                    end if
                                end try
                            end repeat

                            if restartButton is missing value then return "MISSING_STRUCTURE|context=[" & contextText & "]"
                            if shouldPressRestart then perform action "AXPress" of restartButton
                            return "MATCHED|button=[" & restartButtonTitle & "]; context=[" & contextText & "]"
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
    on error errorMessage number errorNumber
        if errorNumber is -1712 then return ""
    end try

    return ""
end inspectUURemoteRestartPrompt

on waitForUURemoteCLI()
    repeat 40 times
        try
            set cliOutput to do shell script "/Applications/UURemote.app/Contents/Helpers/uuyc-cli status"
            if cliOutput contains "\"success\" : true" then return true
        end try
        delay 0.5
    end repeat

    error "UURemote CLI did not recover after Quit & Reopen"
end waitForUURemoteCLI

on dismissUURemoteRestartPrompt(screenshotPrefix, screenshotDirectory)
    set waitAttempts to 8
    if activeDebugLevel is greater than or equal to 1 then set waitAttempts to 20

    set promptDetails to ""
    repeat waitAttempts times
        set promptDetails to my inspectUURemoteRestartPrompt(false)
        if promptDetails is not "" then exit repeat
        delay 0.25
    end repeat

    if promptDetails is "" then return "UURemote recording restart prompt was not present"
    if promptDetails starts with "MISSING_STRUCTURE|" then error "Matched the UURemote recording restart prompt but its recognized action is missing: " & promptDetails

    if activeDebugLevel is greater than or equal to 1 then
        try
            my emitScreenshot(screenshotPrefix & "-restart-before", screenshotDirectory)
        on error screenshotError
            my progressMessage("UURemote restart prompt pre-action screenshot failed: " & screenshotError)
        end try
    end if

    set pressedDetails to my inspectUURemoteRestartPrompt(true)
    if pressedDetails is "" then error "UURemote recording restart prompt disappeared before its exact action could be pressed"
    if pressedDetails starts with "MISSING_STRUCTURE|" then error "Matched the UURemote recording restart prompt but its recognized action is missing: " & pressedDetails
    my progressMessage("UURemote recording restart action pressed; " & pressedDetails)

    repeat 40 times
        if my inspectUURemoteRestartPrompt(false) is "" then
            my waitForUURemoteCLI()

            if activeDebugLevel is greater than or equal to 1 then
                my settleDelay(1, 0)
                try
                    my emitScreenshot(screenshotPrefix & "-restart-after", screenshotDirectory)
                on error screenshotError
                    my progressMessage("UURemote restart prompt post-action screenshot failed: " & screenshotError)
                end try
            end if

            return "UURemote recording restart prompt accepted and closed"
        end if

        delay 0.25
    end repeat

    error "UURemote recording restart prompt remained visible after pressing its exact action"
end dismissUURemoteRestartPrompt

on inspectPrivateWindowPickerPrompt(requesterText, shouldPressAllow)
    try
        -- AX calls into UserNotificationCenter can block indefinitely on
        -- macOS 26 while a protected-window prompt is being constructed.
        -- Bound every probe so a diagnostic screenshot cannot stall the job.
        with timeout of 2 seconds
            tell application "System Events"
                if not (exists application process "UserNotificationCenter") then return ""
                set appProcess to application process "UserNotificationCenter"

                if (count of windows of appProcess) is greater than 0 then
                    set processName to name of appProcess as text

                    repeat with processWindow in windows of appProcess
                        set allowButton to missing value
                        set openSettingsButton to missing value
                        set contextText to my attributeText(processWindow, "AXDescription")

                        repeat with uiText in static texts of processWindow
                            set textValue to my attributeText(uiText, "AXValue")
                            if textValue is not "" then set contextText to contextText & " " & textValue
                        end repeat

                        repeat with uiButton in buttons of processWindow
                            set buttonTitle to my attributeText(uiButton, "AXTitle")
                            set buttonDescription to my attributeText(uiButton, "AXDescription")

                            if buttonTitle is "Allow" or buttonDescription is "Allow" or buttonTitle is "允许" or buttonDescription is "允许" then
                                set allowButton to contents of uiButton
                            end if

                            if buttonTitle is "Open System Settings" or buttonDescription is "Open System Settings" or buttonTitle is "打开系统设置" or buttonDescription is "打开系统设置" then
                                set openSettingsButton to contents of uiButton
                            end if
                        end repeat

                        ignoring case
                            if contextText contains requesterText then
                                if allowButton is missing value or openSettingsButton is missing value then
                                    return "MISSING_STRUCTURE|process=" & processName & "; context=[" & contextText & "]"
                                end if

                                if shouldPressAllow then
                                perform action "AXPress" of allowButton
                                end if

                                return "process=" & processName & "; context=[" & contextText & "]"
                            end if
                        end ignoring
                    end repeat
                end if
            end tell
        end timeout
    on error errorMessage number errorNumber
        if errorNumber is -1712 then return ""
    end try

    return ""
end inspectPrivateWindowPickerPrompt

on dismissPrivateWindowScreenshotPrompt()
    set promptDetails to my inspectPrivateWindowPickerPrompt("bash", true)
    if promptDetails starts with "MISSING_STRUCTURE|" then error "Matched the bash screen-sharing prompt but its recognized action structure is incomplete: " & promptDetails
    return promptDetails
end dismissPrivateWindowScreenshotPrompt

on dismissUURemotePrivateWindowPrompt(screenshotDirectory)
    set waitAttempts to 12
    if activeDebugLevel is greater than or equal to 1 then set waitAttempts to 40

    set promptDetails to ""
    repeat waitAttempts times
        set promptDetails to my inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", false)
        if promptDetails is not "" then exit repeat
        delay 0.25
    end repeat

    if promptDetails is "" then
        my progressMessage("UURemote private window picker did not appear")
        return "UURemote private window picker was not present"
    end if

    my progressMessage("UURemote private window picker detected; " & promptDetails)

    if activeDebugLevel is greater than or equal to 1 then
        try
            my emitScreenshot("agent-private-picker-before", screenshotDirectory)
        on error screenshotError
            my progressMessage("UURemote private window picker pre-Allow screenshot failed: " & screenshotError)
        end try
    end if

    set pressedDetails to my inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", true)
    if pressedDetails is "" then error "UURemote private window picker disappeared before its Allow button could be pressed"
    if pressedDetails starts with "MISSING_STRUCTURE|" then error "Matched the UURemote screen-sharing prompt but its recognized action structure is incomplete: " & pressedDetails
    my progressMessage("UURemote private window picker Allow pressed; " & pressedDetails)

    repeat 40 times
        if my inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", false) is "" then
            if activeDebugLevel is greater than or equal to 1 then
                my settleDelay(1, 0)
                try
                    my emitScreenshot("agent-private-picker-after", screenshotDirectory)
                on error screenshotError
                    my progressMessage("UURemote private window picker post-Allow screenshot failed: " & screenshotError)
                end try
            end if

            return "UURemote private window picker allowed"
        end if

        delay 0.25
    end repeat

    error "UURemote private window picker remained visible after pressing Allow"
end dismissUURemotePrivateWindowPrompt

on emitScreenshot(captureLabel, screenshotDirectory)
    if activeDebugLevel is 0 then return ""

    tell application "System Events"
        tell process settingsProcessName
            set windowPosition to position of window 1
            set windowSize to size of window 1
        end tell
    end tell

    set captureRegion to (item 1 of windowPosition as text) & "," & (item 2 of windowPosition as text) & "," & (item 1 of windowSize as text) & "," & (item 2 of windowSize as text)
    set captureTimestamp to do shell script "/bin/date '+%Y%m%d-%H%M%S'"
    set pngPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-" & captureTimestamp & ".png"
    set jpegPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-" & captureTimestamp & ".jpg"
    do shell script "/usr/sbin/screencapture -x -t png -R" & quoted form of captureRegion & " " & quoted form of pngPath & " && /usr/bin/sips -s format jpeg -s formatOptions 55 " & quoted form of pngPath & " --out " & quoted form of jpegPath & " >/dev/null"
    log "UUREMOTE_SCREENSHOT_SAVED:" & jpegPath
    do shell script "/bin/rm -f " & quoted form of pngPath

    -- macOS 26 protects Privacy & Security windows with a separate prompt.
    -- Dismiss only the exact bash/private-window-picker prompt, then capture
    -- an unobscured copy. Any other Allow button is left untouched.
    set promptOwner to ""
    repeat 8 times
        -- UU Remote can raise its own protected-window prompt while a debug
        -- capture is being taken. Do not spend every retry waiting behind it:
        -- preserve it for dismissUURemotePrivateWindowPrompt, which validates
        -- the exact bundle id and button structure before pressing Allow.
        set pendingUURemotePrompt to my inspectPrivateWindowPickerPrompt("com.netease.uuremote.agent", false)
        if pendingUURemotePrompt is not "" then
            my progressMessage("UURemote private window picker is pending; leaving it for the exact handler")
            return jpegPath
        end if

        set promptOwner to my dismissPrivateWindowScreenshotPrompt()
        if promptOwner is not "" then exit repeat
        delay 0.25
    end repeat

    if promptOwner is not "" then
        my progressMessage("Screenshot prerequisite allowed; " & promptOwner)
        delay 1
        set confirmedPngPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-confirmed-" & captureTimestamp & ".png"
        set confirmedJpegPath to screenshotDirectory & "/uuremote-permission-" & captureLabel & "-confirmed-" & captureTimestamp & ".jpg"
        do shell script "/usr/sbin/screencapture -x -t png -R" & quoted form of captureRegion & " " & quoted form of confirmedPngPath & " && /usr/bin/sips -s format jpeg -s formatOptions 55 " & quoted form of confirmedPngPath & " --out " & quoted form of confirmedJpegPath & " >/dev/null"
        log "UUREMOTE_SCREENSHOT_SAVED:" & confirmedJpegPath
        do shell script "/bin/rm -f " & quoted form of confirmedPngPath
    end if
end emitScreenshot

on ensurePermission(permissionURL, permissionWindowTitles, permissionLabel, screenshotPrefix, authorizationPassword, screenshotDirectory)
    set pageWaitAttempts to 20
    if activeDebugLevel is greater than or equal to 1 then set pageWaitAttempts to 120
    set outlineWaitAttempts to 3
    if activeDebugLevel is greater than or equal to 1 then set outlineWaitAttempts to 12

    my progressMessage(permissionLabel & ": restarting System Settings for an isolated permission session")
    do shell script "/usr/bin/killall " & quoted form of "System Settings" & " >/dev/null 2>&1 || true"
    my settleDelay(2, 0.5)
    do shell script "/usr/bin/open -a " & quoted form of "System Settings"
    my settleDelay(1, 0.25)
    do shell script "/usr/bin/open " & quoted form of permissionURL
    my settleDelay(5, 0.5)

    tell application "System Events"
    my progressMessage(permissionLabel & ": waiting for the permission window")
    set pageReady to false

    repeat pageWaitAttempts times
        try
            if exists application process settingsProcessName then
                set settingsProcess to application process settingsProcessName

                if exists window 1 of settingsProcess then
                    if my listContainsText(permissionWindowTitles, my attributeText(window 1 of settingsProcess, "AXTitle")) then
                        set pageReady to true
                        exit repeat
                    end if
                end if
            end if
        on error pageProbeError
            -- System Settings can transiently return -10000 while its first
            -- window is being attached. The next probe normally succeeds.
        end try

        delay 0.25
    end repeat

    if pageReady is false then
        my progressMessage(permissionLabel & ": permission window timeout; visible windows: " & my visibleWindowDiagnostics())

        try
            my emitScreenshot(screenshotPrefix & "-page-timeout", screenshotDirectory)
        on error screenshotError
            my progressMessage(permissionLabel & ": timeout screenshot failed: " & screenshotError)
        end try

        error permissionLabel & " window did not become ready within 30 seconds"
    end if

    my progressMessage(permissionLabel & ": waiting for the primary permission outline")
    set settingsReady to false
    set permissionOutline to missing value

    repeat outlineWaitAttempts times
        set permissionOutline to my getPermissionOutline(settingsProcess)

        if permissionOutline is not missing value then
            set settingsReady to true
            exit repeat
        end if

        delay 0.25
    end repeat

    if settingsReady is false then
        error permissionLabel & " list did not become ready within 30 seconds"
    end if

    set initialRows to my getOutlineRows(permissionOutline)
    my progressMessage(permissionLabel & ": primary outline ready; rows=" & (count of initialRows))
    my progressMessage(permissionLabel & ": state before action: " & my outlineDiagnostics(permissionOutline))
    my emitScreenshot(screenshotPrefix & "-before", screenshotDirectory)
    set targetSwitch to my findTargetSwitch(permissionOutline)

    if targetSwitch is missing value then
        set previousTitles to my getRowTitles(permissionOutline)
        my progressMessage(permissionLabel & ": UURemote row absent; existing rows=" & my joinText(previousTitles))
        set addButton to my findAddButton(settingsProcess, permissionOutline)

        if addButton is missing value then
            error permissionLabel & ": could not identify the add button. Rows: " & my outlineDiagnostics(permissionOutline)
        end if

        my progressMessage(permissionLabel & ": add button identified")
        perform action "AXPress" of addButton
        my settleDelay(2, 0.5)
        set fileChooserReady to my processHasWindowTitle(settingsProcess, {"Open", "打开"})

        if fileChooserReady is false then
            my progressMessage(permissionLabel & ": submitting the default Modify Settings confirmation")
            try
                set frontmost of settingsProcess to true
            end try
            key code 36
            my settleDelay(5, 0.5)
            my progressMessage(permissionLabel & ": windows after Modify Settings: " & my visibleWindowDiagnostics())

            -- The authorization sheet can become visible before its password
            -- field receives keyboard focus. Wait on the actual UI condition
            -- so fast mode returns immediately when ready without racing it.
            set authenticationField to missing value

            repeat 40 times
                try
                    set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

                    if my isPasswordField(focusedItem) then
                        set authenticationField to focusedItem
                        exit repeat
                    end if
                end try

                delay 0.25
            end repeat

            if authenticationField is missing value then
                error permissionLabel & ": the system authentication password field did not receive keyboard focus. Windows: " & my visibleWindowDiagnostics()
            end if

            set value of authenticationField to authorizationPassword

            if my attributeText(authenticationField, "AXValue") is "" then
                error permissionLabel & ": the system authentication password field remained empty"
            end if

            my progressMessage(permissionLabel & ": administrator password field populated")
            my settleDelay(1, 0.25)
            key code 36
            my progressMessage(permissionLabel & ": administrator authorization submitted with the default button")
        end if

        repeat 80 times
            if my processHasWindowTitle(settingsProcess, {"Open", "打开"}) then
                set fileChooserReady to true
                exit repeat
            end if

            delay 0.25
        end repeat

        if fileChooserReady is false then
            error permissionLabel & ": the file chooser did not appear after administrator authorization. Windows: " & my visibleWindowDiagnostics()
        end if

        my progressMessage(permissionLabel & ": file chooser ready")
        my emitScreenshot(screenshotPrefix & "-file-chooser-ready", screenshotDirectory)

        -- Use the standard macOS file chooser's Go to Folder command.
        keystroke "g" using {command down, shift down}
        my settleDelay(1, 0.25)
        set goToFolderField to missing value

        -- The Go to Folder sheet can be visible before its text field becomes
        -- the focused accessibility element, especially in fast mode. Wait on
        -- the actual focus condition instead of relying on a fixed delay.
        repeat 40 times
            try
                set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

                if my attributeText(focusedItem, "AXRole") is "AXTextField" then
                    set goToFolderField to focusedItem
                    exit repeat
                end if
            end try

            delay 0.25
        end repeat

        if goToFolderField is missing value then
            error permissionLabel & ": the Go to Folder text field did not receive keyboard focus. Windows: " & my visibleWindowDiagnostics()
        end if

        -- Assign the accessibility value directly. Sending a long path as
        -- synthetic keystrokes is intermittent on hosted macOS runners and
        -- can leave this sheet open forever with an incomplete path.
        set value of goToFolderField to targetApplicationPath

        if my attributeText(goToFolderField, "AXValue") is not targetApplicationPath then
            error permissionLabel & ": the Go to Folder path was not populated completely"
        end if

        my progressMessage(permissionLabel & ": Go to Folder path populated: " & targetApplicationPath)
        my settleDelay(1, 0.25)

        -- macOS 26 may consume a variable number of Returns while accepting
        -- autocomplete, navigating to the app, and submitting it. Keep going
        -- until the top-level Open window is actually gone.
        repeat with submissionNumber from 1 to 12
            key code 36
            my settleDelay(1, 0.25)
            set openWindowPresent to my processHasWindowTitle(settingsProcess, {"Open", "打开"})
            my progressMessage(permissionLabel & ": file chooser submission " & submissionNumber & "; openWindowPresent=" & openWindowPresent)

            if openWindowPresent is false then exit repeat
        end repeat

        if my processHasWindowTitle(settingsProcess, {"Open", "打开"}) then
            error permissionLabel & ": the file chooser remained open after 12 submissions. Windows: " & my visibleWindowDiagnostics()
        end if

        my emitScreenshot(screenshotPrefix & "-file-chooser-selected", screenshotDirectory)

        -- The application has been submitted. A recording restart prompt is
        -- accepted only when both its UU Remote context and exact localized
        -- action are recognized.
        my settleDelay(1, 0.25)
        set postAddRestartResult to my dismissUURemoteRestartPrompt(screenshotPrefix & "-post-add", screenshotDirectory)
        my progressMessage(permissionLabel & ": " & postAddRestartResult)
        my settleDelay(1, 0.25)

        set settingsProcess to application process settingsProcessName
        set permissionOutline to missing value

        repeat outlineWaitAttempts times
            set permissionOutline to my getPermissionOutline(settingsProcess)

            if permissionOutline is not missing value then exit repeat
            delay 0.25
        end repeat

        if permissionOutline is missing value then
            error permissionLabel & ": the permission list disappeared after adding UURemote"
        end if

        -- The newly added row is unambiguous even if a future release
        -- changes the localized bundle display name.
        set targetSwitch to my findNewSwitch(permissionOutline, previousTitles)
    end if

    if targetSwitch is missing value then
        error permissionLabel & ": UURemote was not added to the permission list. Rows: " & my outlineDiagnostics(permissionOutline)
    end if

    my progressMessage(permissionLabel & ": UURemote switch identified")

    if my switchIsEnabled(targetSwitch) then
        set alreadyEnabledRestartResult to my dismissUURemoteRestartPrompt(screenshotPrefix & "-already-enabled", screenshotDirectory)
        my progressMessage(permissionLabel & ": " & alreadyEnabledRestartResult)
        my progressMessage(permissionLabel & ": state after action: " & my outlineDiagnostics(permissionOutline))
        my emitScreenshot(screenshotPrefix & "-after-already-enabled", screenshotDirectory)
        return "UURemote " & permissionLabel & " permission is already enabled"
    end if

    -- Killing every process inside the app bundle also kills the launch agent.
    -- launchd immediately relaunches UU Remote in the foreground, interrupting
    -- the TCC transaction and leaving the row denied. Keep the app stable while
    -- System Settings commits the switch, then accept its exact restart prompt.
    try
        set frontmost of settingsProcess to true
    end try
    my settleDelay(1, 0.25)
    perform action "AXPress" of targetSwitch
    my progressMessage(permissionLabel & ": permission switch pressed")

    -- On macOS 26 the switch can appear on before the administrator sheet is
    -- completed. Treating that transient visual state as success leaves the
    -- TCC row denied (auth_value=0), so explicitly complete the sheet first.
    my settleDelay(2, 0.5)
    my emitScreenshot(screenshotPrefix & "-after-switch-pressed", screenshotDirectory)

    set preAuthenticationRestartResult to my dismissUURemoteRestartPrompt(screenshotPrefix & "-post-toggle", screenshotDirectory)
    my progressMessage(permissionLabel & ": " & preAuthenticationRestartResult)

    set authenticationField to missing value

    repeat 40 times
        try
            set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

            if my isPasswordField(focusedItem) then
                set authenticationField to focusedItem
                exit repeat
            end if
        end try

        delay 0.25
    end repeat

    if authenticationField is not missing value then
        my progressMessage(permissionLabel & ": administrator authorization required after toggling permission")
        set value of authenticationField to authorizationPassword

        if my attributeText(authenticationField, "AXValue") is "" then
            error permissionLabel & ": the post-toggle authentication password field remained empty"
        end if

        my settleDelay(1, 0.25)
        key code 36
        my progressMessage(permissionLabel & ": administrator authorization submitted after toggling permission")

        repeat 80 times
            try
                set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

                if my isPasswordField(focusedItem) is false then
                    exit repeat
                end if
            on error
                exit repeat
            end try

            delay 0.25
        end repeat

        try
            set focusedItem to value of attribute "AXFocusedUIElement" of settingsProcess

            if my isPasswordField(focusedItem) then
                error permissionLabel & ": administrator authorization remained open after password submission"
            end if
        end try

        my emitScreenshot(screenshotPrefix & "-after-authentication", screenshotDirectory)
    else
        my progressMessage(permissionLabel & ": no administrator authorization sheet appeared after toggling permission")
    end if

    set postAuthenticationRestartResult to my dismissUURemoteRestartPrompt(screenshotPrefix & "-post-authentication", screenshotDirectory)
    my progressMessage(permissionLabel & ": " & postAuthenticationRestartResult)

    repeat 40 times
        if my switchIsEnabled(targetSwitch) then
            my progressMessage(permissionLabel & ": permission switch is on")
            my progressMessage(permissionLabel & ": state after action: " & my outlineDiagnostics(permissionOutline))
            my emitScreenshot(screenshotPrefix & "-after-enabled", screenshotDirectory)
            exit repeat
        end if

        delay 0.25
    end repeat

    if my switchIsEnabled(targetSwitch) is false then
        error permissionLabel & ": UURemote switch was pressed but did not turn on. Rows: " & my outlineDiagnostics(permissionOutline)
    end if

    -- A visual on-state is not sufficient: restart System Settings and read
    -- the row again so the script only succeeds after TCC has persisted it.
    my progressMessage(permissionLabel & ": reopening System Settings to verify persistence")
    my progressMessage(permissionLabel & ": stopping System Settings")
    do shell script "/usr/bin/killall " & quoted form of "System Settings" & " >/dev/null 2>&1 || true"
    my progressMessage(permissionLabel & ": System Settings stop command completed")
    my settleDelay(2, 0.5)
    my progressMessage(permissionLabel & ": launching System Settings")
    do shell script "/usr/bin/open -a " & quoted form of "System Settings"
    my progressMessage(permissionLabel & ": System Settings launch command completed")
    my settleDelay(1, 0.25)
    my progressMessage(permissionLabel & ": opening permission URL for persistence verification")
    do shell script "/usr/bin/open " & quoted form of permissionURL
    my progressMessage(permissionLabel & ": permission URL open command completed")
    my settleDelay(5, 0.5)

    set persistedPageReady to false
    my progressMessage(permissionLabel & ": waiting for the persistence verification page")

    repeat pageWaitAttempts times
        try
            if exists application process settingsProcessName then
                set settingsProcess to application process settingsProcessName

                if exists window 1 of settingsProcess then
                    if my listContainsText(permissionWindowTitles, my attributeText(window 1 of settingsProcess, "AXTitle")) then
                        set persistedPageReady to true
                        exit repeat
                    end if
                end if
            end if
        on error pageProbeError
            -- Retry the same transient launch-time AppleEvent failure here.
        end try

        delay 0.25
    end repeat

    if persistedPageReady is false then
        error permissionLabel & ": could not reopen the permission page for persistence verification"
    end if

    set persistedOutline to missing value

    repeat outlineWaitAttempts times
        set persistedOutline to my getPermissionOutline(settingsProcess)
        if persistedOutline is not missing value then exit repeat
        delay 0.25
    end repeat

    if persistedOutline is missing value then
        error permissionLabel & ": permission list did not reappear for persistence verification"
    end if

    set persistedSwitch to my findTargetSwitch(persistedOutline)

    if persistedSwitch is missing value then
        my emitScreenshot(screenshotPrefix & "-persistence-row-missing", screenshotDirectory)
        error permissionLabel & ": UURemote row disappeared after reopening System Settings"
    end if

    if my switchIsEnabled(persistedSwitch) is false then
        my progressMessage(permissionLabel & ": state after reopening: " & my outlineDiagnostics(persistedOutline))
        my emitScreenshot(screenshotPrefix & "-persistence-failed", screenshotDirectory)
        error permissionLabel & ": permission did not persist after reopening System Settings"
    end if

    my progressMessage(permissionLabel & ": permission persisted after reopening System Settings")
    my progressMessage(permissionLabel & ": persisted state: " & my outlineDiagnostics(persistedOutline))
    my emitScreenshot(screenshotPrefix & "-after-reopened", screenshotDirectory)
    return "UURemote " & permissionLabel & " permission enabled and persisted"
    end tell
end ensurePermission

on run argv
    if (count of argv) is not 5 then error "Expected the runner login password, screenshot directory, permission kind, permission target path, and debug level arguments"
    set authorizationPassword to item 1 of argv as text
    set screenshotDirectory to item 2 of argv as text
    set permissionKind to item 3 of argv as text
    set targetApplicationPath to item 4 of argv as text
    set activeDebugLevel to item 5 of argv as integer

    if permissionKind is "accessibility-main" then
        set targetApplicationNames to {"UU远程", "UURemote", "UU Remote", "网易UU远程", "网易 UU 远程"}
        return my ensurePermission(¬
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", ¬
            {"Accessibility", "辅助功能"}, ¬
            "Accessibility (UURemote)", ¬
            "accessibility-main", ¬
            authorizationPassword, ¬
            screenshotDirectory)
    else if permissionKind is "screen-capture" then
        set targetApplicationNames to {"UU远程", "UURemote", "UU Remote", "网易UU远程", "网易 UU 远程"}
        return my ensurePermission(¬
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", ¬
            {"Screen & System Audio Recording", "录屏与系统录音"}, ¬
            "Screen & System Audio Recording", ¬
            "screen-capture", ¬
            authorizationPassword, ¬
            screenshotDirectory)
    else if permissionKind is "agent-private-picker" then
        return my dismissUURemotePrivateWindowPrompt(screenshotDirectory)
    end if

    error "Unsupported permission kind: " & permissionKind
end run
APPLESCRIPT
}

normalize_remote_desktop() {
    local normalization_mode="${1:-normalize}"
    local normalization_result

    if ! normalization_result="$(run_in_gui /usr/bin/osascript - "$normalization_mode" <<'APPLESCRIPT'
property settingsProcessName : "System Settings"
property targetApplicationNames : {"UU远程", "UURemote", "UU Remote", "网易UU远程", "网易 UU 远程"}

on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem
            if attributeValue is not missing value then return attributeValue as text
        end try
    end tell
    return ""
end attributeText

on processMatchesUURemote(appProcess)
    tell application "System Events"
        set processName to name of appProcess as text
    end tell

    ignoring case
        repeat with candidateName in targetApplicationNames
            if processName is (contents of candidateName as text) then return true
        end repeat
    end ignoring

    return false
end processMatchesUURemote

on windowContext(processWindow)
    tell application "System Events"
        set contextText to my attributeText(processWindow, "AXTitle") & " " & my attributeText(processWindow, "AXDescription")
        set allItems to entire contents of processWindow

        repeat with uiItem in allItems
            try
                if (role of uiItem as text) is "AXStaticText" then
                    set textValue to my attributeText(uiItem, "AXValue")
                    if textValue is not "" then set contextText to contextText & " " & textValue
                end if
            end try
        end repeat
    end tell

    return contextText
end windowContext

on isUURemoteRestartContext(contextText)
    set targetMatched to false

    ignoring case
        repeat with candidateName in targetApplicationNames
            if contextText contains (contents of candidateName as text) then
                set targetMatched to true
                exit repeat
            end if
        end repeat

        if targetMatched is false then return false
        if contextText contains "will not be able to record" and contextText contains "until it quits" then return true
    end ignoring

    if contextText contains "无法录制屏幕" and contextText contains "直至退出" then return true
    return false
end isUURemoteRestartContext

on inspectUURemoteRestartPrompt()
    tell application "System Events"
        if not (exists application process settingsProcessName) then return ""
        set settingsProcess to application process settingsProcessName

        repeat with processWindow in windows of settingsProcess
            set contextText to my windowContext(processWindow)
            if my isUURemoteRestartContext(contextText) then return "context=[" & contextText & "]"
        end repeat
    end tell

    return ""
end inspectUURemoteRestartPrompt

on inspectUURemotePrivateWindowPrompt()
    tell application "System Events"
        if not (exists application process "UserNotificationCenter") then return ""
        set notificationProcess to application process "UserNotificationCenter"

        repeat with promptWindow in windows of notificationProcess
            set contextText to my windowContext(promptWindow)

            ignoring case
                if contextText contains "com.netease.uuremote.agent" then return "context=[" & contextText & "]"
            end ignoring
        end repeat
    end tell

    return ""
end inspectUURemotePrivateWindowPrompt

on assertKnownPromptsAbsent()
    set privatePrompt to my inspectUURemotePrivateWindowPrompt()
    if privatePrompt is not "" then error "UURemote private window picker is still visible: " & privatePrompt

    set restartPrompt to my inspectUURemoteRestartPrompt()
    if restartPrompt is not "" then error "UURemote recording restart prompt is still visible: " & restartPrompt
end assertKnownPromptsAbsent

on isOrdinaryWindow(appWindow)
    set windowSubrole to my attributeText(appWindow, "AXSubrole")
    if windowSubrole is "AXDialog" or windowSubrole is "AXSystemDialog" or windowSubrole is "AXSheet" then return false
    return true
end isOrdinaryWindow

on verifyUURemoteWindowsMinimized(requireOrdinaryWindow)
    set ordinaryWindowCount to 0

    tell application "System Events"
        repeat with appProcess in application processes
            if my processMatchesUURemote(appProcess) then
                repeat with appWindow in windows of appProcess
                    if my isOrdinaryWindow(appWindow) then
                        set ordinaryWindowCount to ordinaryWindowCount + 1
                        set minimizedValue to my attributeText(appWindow, "AXMinimized")
                        if minimizedValue is not "true" and minimizedValue is not "1" then
                            error "A UU Remote ordinary window is not minimized"
                        end if
                    end if
                end repeat
            end if
        end repeat
    end tell

    return ordinaryWindowCount
end verifyUURemoteWindowsMinimized

on minimizeUURemoteWindows(requireOrdinaryWindow)
    set ordinaryWindowCount to 0

    tell application "System Events"
        repeat with appProcess in application processes
            if my processMatchesUURemote(appProcess) then
                repeat with appWindow in windows of appProcess
                    if my isOrdinaryWindow(appWindow) then
                        set ordinaryWindowCount to ordinaryWindowCount + 1
                        try
                            set value of attribute "AXMinimized" of appWindow to true
                        on error errorMessage
                            error "Could not minimize a UU Remote ordinary window: " & errorMessage
                        end try
                    end if
                end repeat
            end if
        end repeat
    end tell

    repeat 20 times
        try
            return my verifyUURemoteWindowsMinimized(requireOrdinaryWindow)
        end try
        delay 0.1
    end repeat

    return my verifyUURemoteWindowsMinimized(requireOrdinaryWindow)
end minimizeUURemoteWindows

on systemSettingsHasWindows()
    tell application "System Events"
        if not (exists application process settingsProcessName) then return false
        return (count of windows of application process settingsProcessName) is greater than 0
    end tell
end systemSettingsHasWindows

on closeSystemSettings()
    if not my systemSettingsHasWindows() then return "System Settings already closed"

    try
        tell application "System Settings" to quit
    end try

    repeat 40 times
        if not my systemSettingsHasWindows() then return "System Settings closed gracefully"
        delay 0.25
    end repeat

    do shell script "/usr/bin/killall " & quoted form of settingsProcessName & " >/dev/null 2>&1 || true"

    repeat 20 times
        if not my systemSettingsHasWindows() then return "System Settings closed with fallback"
        delay 0.25
    end repeat

    error "System Settings still has a visible window after cleanup"
end closeSystemSettings

on run argv
    if (count of argv) is not 1 then error "Expected one desktop normalization mode"
    set normalizationMode to item 1 of argv as text

    if normalizationMode is "cleanup" then
        my minimizeUURemoteWindows(false)
        return my closeSystemSettings()
    end if

    if normalizationMode is "normalize" then
        my assertKnownPromptsAbsent()
        my minimizeUURemoteWindows(true)
        return my closeSystemSettings()
    end if

    if normalizationMode is "verify" then
        my assertKnownPromptsAbsent()
        my verifyUURemoteWindowsMinimized(true)
        if my systemSettingsHasWindows() then error "System Settings still has a visible window"
        return "UU Remote windows minimized; System Settings closed; known dialogs absent"
    end if

    error "Unsupported desktop normalization mode: " & normalizationMode
end run
APPLESCRIPT
)"; then
        echo "Could not complete UU Remote desktop normalization ($normalization_mode)" >&2
        return 1
    fi

    echo "UUREMOTE_DESKTOP: $normalization_result"

    if [ "$normalization_mode" != "normalize" ]; then
        return 0
    fi

    if ! wait_for_cli >/dev/null; then
        echo "UU Remote CLI became unavailable during desktop normalization" >&2
        return 1
    fi

    if ! normalization_result="$(run_in_gui /usr/bin/osascript - "verify" <<'APPLESCRIPT'
property settingsProcessName : "System Settings"
property targetApplicationNames : {"UU远程", "UURemote", "UU Remote", "网易UU远程", "网易 UU 远程"}

on attributeText(uiItem, attributeName)
    tell application "System Events"
        try
            set attributeValue to value of attribute attributeName of uiItem
            if attributeValue is not missing value then return attributeValue as text
        end try
    end tell
    return ""
end attributeText

on processMatchesUURemote(appProcess)
    tell application "System Events" to set processName to name of appProcess as text
    ignoring case
        repeat with candidateName in targetApplicationNames
            if processName is (contents of candidateName as text) then return true
        end repeat
    end ignoring
    return false
end processMatchesUURemote

on windowContext(processWindow)
    tell application "System Events"
        set contextText to my attributeText(processWindow, "AXTitle") & " " & my attributeText(processWindow, "AXDescription")
        repeat with uiItem in entire contents of processWindow
            try
                if (role of uiItem as text) is "AXStaticText" then
                    set textValue to my attributeText(uiItem, "AXValue")
                    if textValue is not "" then set contextText to contextText & " " & textValue
                end if
            end try
        end repeat
    end tell
    return contextText
end windowContext

on knownPromptDetails()
    tell application "System Events"
        if exists application process "UserNotificationCenter" then
            repeat with promptWindow in windows of application process "UserNotificationCenter"
                set contextText to my windowContext(promptWindow)
                ignoring case
                    if contextText contains "com.netease.uuremote.agent" then return "private picker: " & contextText
                end ignoring
            end repeat
        end if

        if exists application process settingsProcessName then
            repeat with processWindow in windows of application process settingsProcessName
                set contextText to my windowContext(processWindow)
                set targetMatched to false
                ignoring case
                    repeat with candidateName in targetApplicationNames
                        if contextText contains (contents of candidateName as text) then set targetMatched to true
                    end repeat
                    if targetMatched and contextText contains "will not be able to record" and contextText contains "until it quits" then return "restart prompt: " & contextText
                end ignoring
                if targetMatched and contextText contains "无法录制屏幕" and contextText contains "直至退出" then return "restart prompt: " & contextText
            end repeat
        end if
    end tell
    return ""
end knownPromptDetails

on run argv
    set promptDetails to my knownPromptDetails()
    if promptDetails is not "" then error "A known UU Remote permission dialog remains visible: " & promptDetails

    set ordinaryWindowCount to 0
    tell application "System Events"
        repeat with appProcess in application processes
            if my processMatchesUURemote(appProcess) then
                repeat with appWindow in windows of appProcess
                    set windowSubrole to my attributeText(appWindow, "AXSubrole")
                    if windowSubrole is not "AXDialog" and windowSubrole is not "AXSystemDialog" and windowSubrole is not "AXSheet" then
                        set ordinaryWindowCount to ordinaryWindowCount + 1
                        set minimizedValue to my attributeText(appWindow, "AXMinimized")
                        if minimizedValue is not "true" and minimizedValue is not "1" then error "A UU Remote ordinary window is not minimized"
                    end if
                end repeat
            end if
        end repeat

        if exists application process settingsProcessName then
            if (count of windows of application process settingsProcessName) is greater than 0 then error "System Settings still has a visible window"
        end if
    end tell

    return "UU Remote CLI ready; dialogs absent; ordinary windows minimized or absent; System Settings closed"
end run
APPLESCRIPT
)"; then
        echo "Could not verify the final UU Remote desktop state" >&2
        return 1
    fi

    echo "UUREMOTE_DESKTOP: $normalization_result"
    echo "FINAL_DESKTOP_STATE=ready"
}

permission_cleanup_on_exit() {
    local exit_status="$?"
    trap - EXIT

    if [ "$exit_status" -ne 0 ]; then
        if [ "$debug_level" -ge 1 ]; then
            capture_snapshot "permission-error" || true
        fi

        normalize_remote_desktop cleanup || true
    fi

    unset runner_password
    exit "$exit_status"
}

trap permission_cleanup_on_exit EXIT

run_permission accessibility-main
run_permission screen-capture

echo "=== Restarting UURemote ==="

debug_sleep 2 0.5
run_in_gui /usr/bin/open "$APP"

echo "=== Waiting for CLI ==="

if ! cli_status="$(wait_for_cli)"; then
    echo "UURemote started, but its CLI did not recover within 20 seconds" >&2
    exit 1
fi

printf '%s\n' "$cli_status"
echo "UURemote restarted successfully"

echo "=== Handling UURemote screen-sharing confirmation ==="
run_permission agent-private-picker

echo "=== Finalizing remote desktop ==="
normalize_remote_desktop normalize

unset runner_password

if [ "$debug_level" -ge 1 ]; then
    capture_snapshot "final-desktop"
fi

trap - EXIT
