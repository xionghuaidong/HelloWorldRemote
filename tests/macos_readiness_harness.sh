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
observed_attempts=0
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
    observed_attempts="$((observed_attempts + 1))"
    if [ -n "$timeouts" ]; then
        timeouts="$timeouts,$2"
    else
        timeouts="$2"
    fi
    case "$scenario" in
        absent-transient-success)
            [ "$observed_attempts" -ge 3 ] || return 1
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
            "$observed_attempts" "$starts" "$sleeps"
        ;;
    deadline)
        printf 'ATTEMPTS=%s STARTS=%s SLEEPS=%s TIMEOUTS=%s\n' \
            "$observed_attempts" "$starts" "$sleeps" "$timeouts" >&2
        ;;
    invalid-timing|missing-paths|launch-failure)
        printf 'ATTEMPTS=%s STARTS=%s SLEEPS=%s TIMEOUTS=%s\n' \
            "$observed_attempts" "$starts" "$sleeps" "$timeouts" >&2
        ;;
esac
exit "$status"
SUBJECT

UUREMOTE_READINESS_FIXTURE_APP="$fixture_app" \
UUREMOTE_READINESS_CLOCK_STATE="$clock_state" \
    /bin/bash "$subject" "${1:?}"
