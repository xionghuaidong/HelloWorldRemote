#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "fixture-hang" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; while :; do sleep 1; done' \
        fixture-child "${3:?}" &
    trap '' TERM
    while :; do sleep 1; done
fi

if [ "${1:-}" = "fixture-leader-exits" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; while :; do sleep 1; done' \
        fixture-child "${3:?}" &
    while :; do sleep 1; done
fi

if [ "${1:-}" = "fixture-term-observed" ]; then
    printf '%s\n' "$$" >"${2:?}"
    term_observed_path="${3:?}"
    trap 'printf "TERM\n" >"$term_observed_path"; exit 0' TERM
    while :; do sleep 1; done
fi

if [ "${1:-}" = "fixture-leader-completes" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; while :; do sleep 1; done' \
        fixture-child "${3:?}" &
    while [ ! -s "${3:?}" ]; do sleep 0.01; done
    exit 0
fi

umask 077

root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:?}"
source_script="${MACOS_ASSIST_ALLOW_SUBJECT_SOURCE:-$root/.github/workflows/apple.sh}"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/uuremote-assist-allow-test.XXXXXX")"
subject="$temporary_directory/subject.sh"
response_path="$temporary_directory/response"
fixture_pids=""
fixture_pid_paths=""
fixture_groups=""

cleanup_harness() {
    local pid pid_path group cleanup_attempt

    for pid in $fixture_pids; do
        case "$pid" in
            ''|*[!0-9]*) ;;
            *) /bin/kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true ;;
        esac
    done
    for pid_path in $fixture_pid_paths; do
        if [ -r "$pid_path" ]; then
            pid="$(cat "$pid_path")"
            case "$pid" in
                ''|*[!0-9]*) ;;
                *) /bin/kill -KILL "$pid" 2>/dev/null || true ;;
            esac
        fi
    done
    for group in $fixture_groups; do
        case "$group" in
            ''|*[!0-9]*) ;;
            *) /bin/kill -KILL -- "-$group" 2>/dev/null || true ;;
        esac
    done
    cleanup_attempt=0
    while [ "$cleanup_attempt" -lt 20 ]; do
        if rm -rf -- "$temporary_directory" 2>/dev/null; then
            return
        fi
        cleanup_attempt="$((cleanup_attempt + 1))"
        sleep 0.05
    done
    rm -rf -- "$temporary_directory" 2>/dev/null || true
}
trap cleanup_harness EXIT

awk '/^if \[ "\$mode" = "self-test-kcpassword" \]; then$/ { exit } { print }' \
    "$source_script" >"$subject"
case "$mode" in
    fault-*)
        awk -v fault_mode="$mode" '
            /^def cleanup_owned_process\(\):$/ {
                print "def cleanup_owned_process_real():"
                next
            }
            /^cleanup_in_progress = False$/ {
                print "def cleanup_owned_process():"
                print "    cleanup_owned_process_real()"
                if (fault_mode == "fault-raises") {
                    print "    raise RuntimeError"
                } else {
                    print "    return False"
                }
            }
            { print }
        ' "$subject" >"$subject.fault"
        mv "$subject.fault" "$subject"
        ;;
esac
if [ ! -x /usr/bin/python3 ]; then
    python_command="$(command -v python3 || command -v python)"
    python_wrapper="$temporary_directory/python3"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$python_command" >"$python_wrapper"
    chmod 0700 "$python_wrapper"
    sed "s#/usr/bin/python3#$python_wrapper#g" "$subject" >"$subject.portable"
    mv "$subject.portable" "$subject"
fi

scenario="${2:?}"

case "$mode" in
    process|fault-*) ;;
    *) false ;;
esac && {
    status_path="$temporary_directory/status"
    output_path="$temporary_directory/output"
    parent_pid_path="$temporary_directory/parent.pid"
    child_pid_path="$temporary_directory/child.pid"
    fixture_pid_paths="$parent_pid_path $child_pid_path"

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
            if [ "$mode" = fault-timeout ] || [ "$mode" = fault-raises ]; then
                if [ -s "$status_path" ]; then
                    echo "Unconfirmed cleanup wrote a status" >&2
                    exit 1
                fi
                printf 'STATUS=absent\n'
                exit 0
            fi
            for pid_path in "$parent_pid_path" "$child_pid_path"; do
                pid="$(cat "$pid_path")"
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Process group was not released" >&2
                    exit 1
                fi
            done
            parent_pid="$(cat "$parent_pid_path")"
            if kill -0 -- "-$parent_pid" 2>/dev/null; then
                echo "Process group was not released" >&2
                exit 1
            fi
            printf 'STATUS=%s\n' "$(cat "$status_path")"
            printf 'PROCESS_GROUP_RELEASED=true\n'
            exit 0
            ;;
        leader-exits)
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-leader-exits \
                "$parent_pid_path" "$child_pid_path"
            then
                echo "Terminating leader fixture unexpectedly succeeded" >&2
                exit 1
            fi
            for pid_path in "$parent_pid_path" "$child_pid_path"; do
                pid="$(cat "$pid_path")"
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Process group was not released" >&2
                    exit 1
                fi
            done
            parent_pid="$(cat "$parent_pid_path")"
            if kill -0 -- "-$parent_pid" 2>/dev/null; then
                echo "Process group was not released" >&2
                exit 1
            fi
            printf 'STATUS=%s\n' "$(cat "$status_path")"
            printf 'PROCESS_GROUP_RELEASED=true\n'
            exit 0
            ;;
        gui-wrapper)
            sudo_stub=/bin/bash
            launchctl_stub="$temporary_directory/launchctl"
            command_capture="$temporary_directory/gui-command"
            printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s"\n' "$command_capture" >"$launchctl_stub"
            chmod 0700 "$launchctl_stub"
            sed \
                -e "s#/usr/bin/sudo#$sudo_stub#g" \
                -e "s#/bin/launchctl#$launchctl_stub#g" \
                "$subject" >"$subject.gui"
            . "$subject.gui"
            console_uid=501
            run_bounded_gui_cli_to_file \
                "$output_path" "$status_path" 3000 /bin/true
            gui_command="sudo|launchctl|$(
                while IFS= read -r argument; do
                    case "$argument" in
                        "$sudo_stub"|*/bin/bash) printf 'sudo|' ;;
                        */bin/true) printf '/bin/true|' ;;
                        *) printf '%s|' "$argument" ;;
                    esac
                done <"$command_capture"
            )"
            printf 'STATUS=%s\n' "$(cat "$status_path")"
            printf 'GUI_COMMAND=%s\n' "${gui_command%|}"
            exit 0
            ;;
        signal-term|signal-int|signal-hup)
            runner_status_path="$temporary_directory/runner-status"
            (
                . "$subject"
                run_bounded_uuremote_cli_to_file_with_status \
                    "$output_path" "$runner_status_path" 30000 /bin/bash "$0" fixture-hang \
                    "$parent_pid_path" "$child_pid_path"
            ) &
            runner_shell_pid="$!"
            fixture_pids="$runner_shell_pid"
            runner_python_pid=""
            signal_wait_attempt=0
            while [ "$signal_wait_attempt" -lt 40 ]; do
                if [ -s "$parent_pid_path" ] && [ -s "$child_pid_path" ]; then
                    case "$(uname -s)" in
                        MINGW*|MSYS*)
                            runner_python_pid="$(powershell.exe -NoProfile -Command \
                                "\$child = Get-CimInstance Win32_Process -Filter 'ParentProcessId = $runner_shell_pid' | Select-Object -First 1 -ExpandProperty ProcessId; if (\$child) { [Console]::Write(\$child) }" 2>/dev/null)"
                            ;;
                        *) runner_python_pid="$(/usr/bin/pgrep -P "$runner_shell_pid" | head -n 1)" ;;
                    esac
                    if [ -n "$runner_python_pid" ]; then
                        break
                    fi
                fi
                signal_wait_attempt="$((signal_wait_attempt + 1))"
                sleep 0.05
            done
            if [ -z "$runner_python_pid" ]; then
                echo "Timed runner PID was unavailable" >&2
                exit 1
            fi
            case "$scenario" in
                signal-int) signal_name=INT ;;
                signal-term) signal_name=TERM ;;
                signal-hup) signal_name=HUP ;;
            esac
            /bin/kill -"$signal_name" "$runner_python_pid"
            if wait "$runner_shell_pid"; then
                runner_exit=0
            else
                runner_exit="$?"
            fi
            if [ "$runner_exit" -ne 125 ]; then
                echo "Interrupted runner did not fail closed" >&2
                exit 1
            fi
            if [ "$mode" = fault-signal ]; then
                if [ -s "$runner_status_path" ]; then
                    echo "Unconfirmed cleanup wrote a status" >&2
                    exit 1
                fi
            elif [ "$(cat "$runner_status_path")" != unavailable ]; then
                echo "Interrupted runner status was not unavailable" >&2
                exit 1
            fi
            for pid_path in "$parent_pid_path" "$child_pid_path"; do
                pid="$(cat "$pid_path")"
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Process group was not released" >&2
                    exit 1
                fi
            done
            parent_pid="$(cat "$parent_pid_path")"
            if kill -0 -- "-$parent_pid" 2>/dev/null; then
                echo "Process group was not released" >&2
                exit 1
            fi
            if [ "$mode" = fault-signal ]; then
                printf 'STATUS=absent\n'
            else
                printf 'STATUS=unavailable\n'
            fi
            printf 'PROCESS_GROUP_RELEASED=true\n'
            exit 0
            ;;
        term-observed)
            term_observed_path="$temporary_directory/term-observed"
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-term-observed \
                "$parent_pid_path" "$term_observed_path"
            then
                echo "TERM observation fixture unexpectedly succeeded" >&2
                exit 1
            fi
            if [ "$(cat "$term_observed_path")" != TERM ]; then
                echo "Spawned child did not observe TERM" >&2
                exit 1
            fi
            parent_pid="$(cat "$parent_pid_path")"
            if kill -0 "$parent_pid" 2>/dev/null || kill -0 -- "-$parent_pid" 2>/dev/null; then
                echo "Process group was not released" >&2
                exit 1
            fi
            printf 'STATUS=%s\n' "$(cat "$status_path")"
            printf 'TERM_OBSERVED=true\n'
            printf 'PROCESS_GROUP_RELEASED=true\n'
            exit 0
            ;;
        leader-completes)
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-leader-completes \
                "$parent_pid_path" "$child_pid_path"
            then
                echo "Completed leader fixture unexpectedly succeeded" >&2
                exit 1
            fi
            for pid_path in "$parent_pid_path" "$child_pid_path"; do
                pid="$(cat "$pid_path")"
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Process group was not released" >&2
                    exit 1
                fi
            done
            parent_pid="$(cat "$parent_pid_path")"
            if kill -0 -- "-$parent_pid" 2>/dev/null; then
                echo "Process group was not released" >&2
                exit 1
            fi
            if [ "$(cat "$status_path")" != unavailable ]; then
                echo "Completed leader status was not unavailable" >&2
                exit 1
            fi
            printf 'STATUS=unavailable\n'
            printf 'PROCESS_GROUP_RELEASED=true\n'
            exit 0
            ;;
        leader-fault)
            if [ "$mode" != fault-leader ]; then
                exit 2
            fi
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-leader-completes \
                "$parent_pid_path" "$child_pid_path"
            then
                echo "Fault leader unexpectedly succeeded" >&2
                exit 1
            fi
            if [ -s "$status_path" ]; then
                echo "Unconfirmed cleanup wrote a status" >&2
                exit 1
            fi
            printf 'STATUS=absent\n'
            exit 0
            ;;
        cleanup-fallback)
            /bin/bash -c 'trap "" TERM; while :; do sleep 1; done' &
            fixture_pids="$!"
            printf 'FALLBACK_PID=%s\n' "$fixture_pids"
            exit 0
            ;;
        *) exit 2 ;;
    esac
    printf 'STATUS=%s\n' "$(cat "$status_path")"
    exit 0
}

if [ "$mode" = "aggregate" ]; then
    . "$subject"

    debug_level=0
    console_uid=501
    controlled_now=0
    clock_count_path="$temporary_directory/clock-count"
    printf '0\n' >"$clock_count_path"
    boundary_calls=0
    temporary_tree="$temporary_directory/assist-tree"
    mkdir -m 700 "$temporary_tree"
    TMPDIR="$temporary_tree"

    uuremote_now_milliseconds() {
        clock_calls="$(cat "$clock_count_path")"
        clock_calls="$((clock_calls + 1))"
        printf '%s\n' "$clock_calls" >"$clock_count_path"
        case "$scenario" in
            invalid-clock) printf 'not-a-decimal-clock\n' ;;
            invalid-clock-loop)
                if [ "$clock_calls" -eq 1 ]; then
                    printf '%s\n' "$controlled_now"
                else
                    printf 'not-a-decimal-clock\n'
                fi
                ;;
            invalid-clock-post-call)
                if [ "$clock_calls" -le 2 ]; then
                    printf '%s\n' "$controlled_now"
                else
                    printf 'not-a-decimal-clock\n'
                fi
                ;;
            clock-status-start) return 7 ;;
            clock-status-loop)
                if [ "$clock_calls" -eq 1 ]; then
                    printf '%s\n' "$controlled_now"
                else
                    return 7
                fi
                ;;
            clock-status-post-call)
                if [ "$clock_calls" -le 2 ]; then
                    printf '%s\n' "$controlled_now"
                else
                    return 7
                fi
                ;;
            *) printf '%s\n' "$controlled_now" ;;
        esac
    }

    wait_uuremote_poll() {
        if [ "$scenario" = "deadline-bounds" ] && [ "$1" -ne 500 ]; then
            echo "Polling interval exceeded the remaining deadline" >&2
            exit 1
        fi
        controlled_now="$((controlled_now + $1))"
    }

    run_bounded_gui_cli_to_file() {
        local output_path="$1"
        local status_path="$2"
        local timeout_milliseconds="$3"
        shift 3
        boundary_calls="$((boundary_calls + 1))"
        printf 'completed:0\n' >"$status_path"
        case "$scenario:$boundary_calls" in
            deadline-bounds:1)
                [ "$timeout_milliseconds" -eq 3000 ] || exit 1
                printf '{"success":true,"enabled":false}' >"$output_path"
                controlled_now=59000
                ;;
            deadline-bounds:2)
                [ "$timeout_milliseconds" -eq 500 ] || exit 1
                printf '{"success":true,"enabled":false}' >"$output_path"
                controlled_now=60000
                ;;
            transient-success:1) printf '{' >"$output_path"; controlled_now=100 ;;
            transient-success:2) printf '{"success":true,"enabled":false}' >"$output_path"; controlled_now=700 ;;
            transient-success:3) printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=1300 ;;
            debug0-failure:1|debug1-failure:1|debug2-failure:1|debug3-failure:1)
                printf '{' >"$output_path"; controlled_now=100 ;;
            debug0-failure:*|debug1-failure:*|debug2-failure:*|debug3-failure:*)
                printf '{"success":true,"enabled":false}' >"$output_path"; controlled_now=60000 ;;
            late-success:1)
                printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=60000 ;;
            internal-invalid-record:1)
                printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=100 ;;
            record-trailing-newline:1|record-trailing-tab:1|record-extra-field:1)
                printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=100 ;;
            record-embedded-cr:1|record-enabled-unavailable:1|record-timeout-zero:1|record-cli-nonzero-zero:1)
                printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=100 ;;
            invalid-clock-post-call:1)
                printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=100 ;;
            clock-status-post-call:1)
                printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=100 ;;
            fault-mktemp:1|fault-chmod:1|fault-truncate:1)
                printf '{"success":true,"enabled":true}' >"$output_path"; controlled_now=100 ;;
            fault-cleanup:1)
                printf '{"success":true,"enabled":true,"deviceId":"device-id-fixture","customCode":"CustomCodeFixture"}' >"$output_path"
                controlled_now=100
                ;;
            hostile-failure:1)
                printf '{"success":true,"enabled":false,"deviceId":"device-id-fixture\\nFORGED_OUTPUT=true","customCode":"CustomCodeFixture"}' >"$output_path"
                controlled_now=60000
                ;;
            outer-false:1|outer-raises:1)
                : >"$output_path"
                : >"$status_path"
                return 125
                ;;
            *) exit 2 ;;
        esac
    }

    case "$scenario" in
        deadline-bounds|debug1-failure|hostile-failure|late-success|invalid-clock|invalid-clock-loop|invalid-clock-post-call|clock-status-start|clock-status-loop|clock-status-post-call) debug_level=1 ;;
        debug2-failure) debug_level=2 ;;
        debug3-failure) debug_level=3 ;;
        internal-invalid-record)
            debug_level=1
            eval "$(declare -f classify_assist_allow_response | \
                /usr/bin/sed '1s/classify_assist_allow_response/classify_assist_allow_response_real/')"
            classify_assist_allow_response() {
                classify_assist_allow_response_real "$@" >/dev/null || return "$?"
                printf 'invalid-category\t0\t0\n'
            }
            ;;
        record-trailing-newline|record-trailing-tab|record-extra-field)
            debug_level=1
            eval "$(declare -f classify_assist_allow_response | \
                /usr/bin/sed '1s/classify_assist_allow_response/classify_assist_allow_response_real/')"
            classify_assist_allow_response() {
                local record
                record="$(classify_assist_allow_response_real "$@")" || return "$?"
                case "$scenario" in
                    record-trailing-newline) printf '%s\n\n' "$record" ;;
                    record-trailing-tab) printf '%s\t\n' "$record" ;;
                    record-extra-field) printf '%s\textra\n' "$record" ;;
                esac
            }
            ;;
        record-embedded-cr|record-enabled-unavailable|record-timeout-zero|record-cli-nonzero-zero)
            debug_level=1
            eval "$(declare -f classify_assist_allow_response | \
                /usr/bin/sed '1s/classify_assist_allow_response/classify_assist_allow_response_real/')"
            classify_assist_allow_response() {
                local record
                record="$(classify_assist_allow_response_real "$@")" || return "$?"
                case "$scenario" in
                    record-embedded-cr) printf 'enabled-true\r\t31\t0\n' ;;
                    record-enabled-unavailable) printf 'enabled-true\t31\tunavailable\n' ;;
                    record-timeout-zero) printf 'timeout\t0\t0\n' ;;
                    record-cli-nonzero-zero) printf 'cli-nonzero\t0\t0\n' ;;
                esac
            }
            ;;
        report-valid)
            report_assist_allow_diagnostics \
                2 0 0 0 0 1 0 0 0 0 0 0 1 0 1 32 32 enabled-false 0
            exit "$?"
            ;;
        report-invalid-count)
            report_assist_allow_diagnostics \
                invalid 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 enabled-false 0
            exit "$?"
            ;;
        report-invalid-arity)
            report_assist_allow_diagnostics
            exit "$?"
            ;;
        report-invalid-exit)
            report_assist_allow_diagnostics \
                1 0 0 0 0 0 0 0 0 0 0 0 1 0 1 32 32 enabled-false 256
            exit "$?"
            ;;
        report-count-exceeds-attempts)
            report_assist_allow_diagnostics \
                1 0 0 0 0 2 0 0 0 0 0 0 0 0 1 32 32 invalid-json 0
            exit "$?"
            ;;
        report-count-sum-mismatch)
            report_assist_allow_diagnostics \
                2 0 0 0 0 1 0 0 0 0 0 0 0 0 1 32 32 invalid-json 0
            exit "$?"
            ;;
        report-byte-order)
            report_assist_allow_diagnostics \
                1 0 0 0 0 0 0 0 0 0 0 0 1 0 33 32 32 enabled-false 0
            exit "$?"
            ;;
        report-zero-attempts)
            report_assist_allow_diagnostics \
                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 enabled-false 0
            exit "$?"
            ;;
        report-final-category-without-evidence)
            report_assist_allow_diagnostics \
                1 0 0 0 0 1 0 0 0 0 0 0 0 0 1 1 1 enabled-false 0
            exit "$?"
            ;;
        report-exit-relation)
            report_assist_allow_diagnostics \
                1 0 1 0 0 0 0 0 0 0 0 0 0 0 1 1 1 cli-nonzero 0
            exit "$?"
            ;;
        fault-mktemp)
            uuremote_assist_mktemp_directory() {
                return 1
            }
            ;;
        fault-chmod)
            uuremote_assist_chmod() {
                return 1
            }
            ;;
        fault-truncate)
            truncate_calls=0
            uuremote_assist_truncate_file() {
                truncate_calls="$((truncate_calls + 1))"
                [ "$truncate_calls" -lt 4 ] || return 1
                : >"$1"
            }
            ;;
        fault-status-write)
            uuremote_python3() {
                python3 "$@"
            }
            run_bounded_gui_cli_to_file() {
                local output_path="$1"
                local status_path="$2"
                local timeout_milliseconds="$3"
                local status_directory
                status_directory="$(/usr/bin/dirname "$status_path")"
                /bin/chmod 0500 "$status_directory"
                run_bounded_uuremote_cli_to_file_with_status \
                    "$output_path" "$status_path" "$timeout_milliseconds" \
                    /bin/echo '{"success":true,"enabled":true,"deviceId":"device-id-fixture","customCode":"CustomCodeFixture"}'
                local bounded_status="$?"
                /bin/chmod 0700 "$status_directory"
                return "$bounded_status"
            }
            ;;
        fault-cleanup)
            uuremote_assist_remove_files() {
                return 1
            }
            ;;
        transient-success|debug0-failure|outer-false|outer-raises) ;;
        *) exit 2 ;;
    esac

    if [ "$scenario" = outer-false ] || [ "$scenario" = outer-raises ]; then
        enable_assist_or_fail
        exit "$?"
    fi

    if ensure_assist_allowed; then
        exit 0
    else
        status="$?"
    fi
    if [ ! -d "$temporary_tree" ] || [ -n "$(find "$temporary_tree" -mindepth 1 -print -quit)" ]; then
        echo "Temporary tree was not empty" >&2
        exit 1
    fi
    case "$scenario" in
        late-success|invalid-clock|invalid-clock-loop|invalid-clock-post-call|clock-status-start|clock-status-loop|clock-status-post-call|fault-mktemp|fault-chmod|fault-truncate|fault-status-write|fault-cleanup)
        printf 'TEMPORARY_TREE_EMPTY=true\n'
            ;;
    esac
    echo "Could not enable unattended control within 60 seconds" >&2
    exit "$status"
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
