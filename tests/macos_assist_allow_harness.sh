#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "fixture-hang" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; exec /bin/sleep 30' \
        fixture-child "${3:?}" &
    child_pid="$!"
    trap '' TERM
    wait "$child_pid"
fi

if [ "${1:-}" = "fixture-leader-exits" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; exec /bin/sleep 30' \
        fixture-child "${3:?}" &
    child_pid="$!"
    wait "$child_pid"
fi

if [ "${1:-}" = "fixture-term-observed" ]; then
    printf '%s\n' "$$" >"${2:?}"
    term_observed_path="${3:?}"
    trap 'printf "TERM\n" >"$term_observed_path"; exit 0' TERM
    while :; do sleep 1; done
fi

if [ "${1:-}" = "fixture-pending-signal" ]; then
    printf '%s\n' "$$" >"${2:?}"
    cleanup_started_path="${3:?}"
    trap 'printf "pending-cleanup-started\n" >"$cleanup_started_path"; sleep 0.2; exit 0' TERM
    while :; do sleep 1; done
fi

if [ "${1:-}" = "fixture-leader-completes" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; exec /bin/sleep 30' \
        fixture-child "${3:?}" &
    while [ ! -s "${3:?}" ]; do sleep 0.01; done
    exit 0
fi

if [ "${1:-}" = "fixture-leader-completes-recorded" ]; then
    printf '%s\n' "$$" >"${2:?}"
    trap 'exit 0' USR1
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; exec /bin/sleep 30' \
        fixture-child "${3:?}" &
    child_pid="$!"
    wait "$child_pid"
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
group_recorded_path="$temporary_directory/group-recorded"
export UUREMOTE_TEST_GROUP_RECORDED_PATH="$group_recorded_path"
release_recorded_fixture_leader=0

is_native_macos() {
    [ "$(uname -s)" = Darwin ]
}

record_fixture_group_when_known() {
    local pid group

    if ! is_native_macos || [ ! -s "$parent_pid_path" ]; then
        return 0
    fi
    if ! pid="$(read_recorded_pid_file "$parent_pid_path" 2>/dev/null)"; then
        return 1
    fi
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    group="$(/bin/ps -o pgid= -p "$pid" | /usr/bin/tr -d '[:space:]')"
    case "$group" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$group" = "$pid" ] || return 1
    fixture_groups="$group"
}

read_recorded_pid_file() {
    if [ "$mode" = fault-residue-read-diagnostic ]; then
        return 1
    fi
    /bin/cat "$1"
}

assert_recorded_fixture_teardown() {
    local pid pid_path group wait_attempt released

    if ! is_native_macos; then
        # Windows owns only the direct child; native macOS proves group teardown.
        return 0
    fi
    [ -n "$fixture_groups" ] || {
        emit_recorded_residue_diagnostic || true
        return 1
    }
    wait_attempt=0
    while [ "$wait_attempt" -lt 40 ]; do
        released=1
        for pid_path in $fixture_pid_paths; do
            [ -s "$pid_path" ] || {
                emit_recorded_residue_diagnostic || true
                return 1
            }
            if ! pid="$(read_recorded_pid_file "$pid_path" 2>/dev/null)"; then
                emit_recorded_residue_diagnostic || true
                return 1
            fi
            case "$pid" in
                ''|*[!0-9]*)
                    emit_recorded_residue_diagnostic || true
                    return 1
                    ;;
            esac
            if /bin/kill -0 "$pid" 2>/dev/null; then
                released=0
            fi
        done
        for group in $fixture_groups; do
            case "$group" in
                ''|*[!0-9]*)
                    emit_recorded_residue_diagnostic || true
                    return 1
                    ;;
            esac
            if /bin/kill -0 -- "-$group" 2>/dev/null; then
                released=0
            fi
        done
        [ "$released" -eq 0 ] || return 0
        wait_attempt="$((wait_attempt + 1))"
        sleep 0.05
    done
    emit_recorded_residue_diagnostic || true
    return 1
}

run_residue_ps() {
    if [ "$mode" = fault-residue-observer-diagnostic ]; then
        return 1
    fi
    /bin/ps "$@"
}

probe_recorded_group_signal() {
    if [ "$mode" = fault-residue-observer-diagnostic ]; then
        return 1
    fi
    /bin/kill -0 -- "-$1"
}

recorded_process_state() {
    local pid="$1"
    local state

    case "$pid" in
        ''|*[!0-9]*)
            printf 'unknown\n'
            return
            ;;
    esac
    if ! state="$(run_residue_ps -o state= -p "$pid" 2>/dev/null)"; then
        printf 'unknown\n'
        return
    fi
    state="$(printf '%s' "$state" | /usr/bin/tr -d '[:space:]')"
    case "$state" in
        '') printf 'absent\n' ;;
        Z*) printf 'zombie\n' ;;
        *) printf 'live\n' ;;
    esac
}

emit_recorded_residue_diagnostic() {
    local parent_pid child_pid group group_signal_state group_observation
    local membership activity

    parent_pid=""
    child_pid=""
    if [ -s "$parent_pid_path" ]; then
        parent_pid="$(read_recorded_pid_file "$parent_pid_path" 2>/dev/null || true)"
    fi
    if [ -s "$child_pid_path" ]; then
        child_pid="$(read_recorded_pid_file "$child_pid_path" 2>/dev/null || true)"
    fi
    case "$parent_pid" in *[!0-9]*) parent_pid="" ;; esac
    case "$child_pid" in *[!0-9]*) child_pid="" ;; esac
    set -- $fixture_groups
    group="${1:-}"
    case "$group" in *[!0-9]*) group="" ;; esac

    if [ -n "$group" ] && \
        group_observation="$(run_residue_ps -axo pid=,pgid=,state= 2>/dev/null | /usr/bin/awk \
        -v group="$group" -v parent="$parent_pid" -v child="$child_pid" '
            $2 == group {
                total += 1
                if ($1 != parent && $1 != child) unrecorded += 1
                if ($3 ~ /^Z/) zombies += 1
                else live += 1
            }
            END {
                if (total == 0) membership = "absent"
                else if (unrecorded == 0) membership = "recorded-only"
                else if (unrecorded == total) membership = "unrecorded-only"
                else membership = "mixed"
                if (total == 0) activity = "absent"
                else if (live > 0 && zombies > 0) activity = "mixed"
                else if (live > 0) activity = "live-only"
                else activity = "zombie-only"
                print membership, activity
            }
        ')"; then
        set -- $group_observation
        membership="${1:-unknown}"
        activity="${2:-unknown}"
    else
        membership=unknown
        activity=unknown
    fi
    if [ -z "$parent_pid" ] || [ -z "$child_pid" ]; then
        membership=unknown
    fi
    case "$membership" in absent|recorded-only|unrecorded-only|mixed|unknown) ;; *) return 1 ;; esac
    case "$activity" in absent|live-only|zombie-only|mixed|unknown) ;; *) return 1 ;; esac
    if [ -n "$group" ] && probe_recorded_group_signal "$group" 2>/dev/null; then
        group_signal_state=present
    elif [ "$activity" = absent ]; then
        group_signal_state=absent
    else
        group_signal_state=unknown
    fi

    printf 'RECORDED_PARENT_STATE=%s\n' "$(recorded_process_state "$parent_pid")" >&2
    printf 'RECORDED_CHILD_STATE=%s\n' "$(recorded_process_state "$child_pid")" >&2
    printf 'GROUP_SIGNAL_STATE=%s\n' "$group_signal_state" >&2
    printf 'GROUP_MEMBERSHIP=%s\n' "$membership" >&2
    printf 'GROUP_ACTIVITY=%s\n' "$activity" >&2
}

run_recorded_bounded_fixture() {
    local output_path="$1"
    local status_path="$2"
    local timeout_milliseconds="$3"
    local recorded_leader_pid runner_pid wait_attempt runner_exit
    shift 3

    (
        run_bounded_uuremote_cli_to_file_with_status \
            "$output_path" "$status_path" "$timeout_milliseconds" "$@"
    ) &
    runner_pid="$!"
    fixture_pids="$fixture_pids $runner_pid"
    wait_attempt=0
    while [ "$wait_attempt" -lt 40 ]; do
        if [ -s "$parent_pid_path" ] && [ -s "$child_pid_path" ]; then
            if record_fixture_group_when_known; then
                : >"$group_recorded_path"
                if [ "$release_recorded_fixture_leader" -eq 1 ]; then
                    if ! recorded_leader_pid="$(read_recorded_pid_file "$parent_pid_path" 2>/dev/null)" || \
                        ! /bin/kill -USR1 "$recorded_leader_pid" 2>/dev/null
                    then
                        /bin/kill -KILL "$runner_pid" 2>/dev/null || true
                        wait "$runner_pid" 2>/dev/null || true
                        return 125
                    fi
                fi
                break
            fi
            if is_native_macos; then
                /bin/kill -KILL "$runner_pid" 2>/dev/null || true
                wait "$runner_pid" 2>/dev/null || true
                return 125
            fi
        fi
        wait_attempt="$((wait_attempt + 1))"
        sleep 0.05
    done
    if [ ! -s "$parent_pid_path" ] || [ ! -s "$child_pid_path" ]; then
        /bin/kill -KILL "$runner_pid" 2>/dev/null || true
        wait "$runner_pid" 2>/dev/null || true
        return 125
    fi
    if wait "$runner_pid"; then
        runner_exit=0
    else
        runner_exit="$?"
    fi
    return "$runner_exit"
}

cleanup_harness() {
    local pid pid_path group cleanup_attempt

    for group in $fixture_groups; do
        case "$group" in
            ''|*[!0-9]*) ;;
            *) /bin/kill -KILL -- "-$group" 2>/dev/null || true ;;
        esac
    done
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
                *) /bin/kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true ;;
            esac
        fi
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

emit_completed_failure_diagnostic() {
    local diagnostic_path="${UUREMOTE_TEST_COMPLETED_DIAGNOSTIC_PATH:-}"
    local field value numeric_value

    [ -s "$diagnostic_path" ] || return 0
    [ "$(/usr/bin/wc -l <"$diagnostic_path" | /usr/bin/tr -d '[:space:]')" = 7 ] || return 1
    for field in \
        BOUNDARY_STAGE= EXCEPTION_KIND= INITIAL_PROBE_KIND= FINAL_PROBE_KIND= \
        WAIT_RETURN_CODE= PROBE_COUNT= ELAPSED_BUCKET=
    do
        value="$(/usr/bin/sed -n "s/^${field}//p" "$diagnostic_path")"
        case "$field" in
            BOUNDARY_STAGE=)
                case "$value" in
                    initialized|opening-output|output-opened|popen-entered|popen-returned|group-recorded|ownership-recorded|restoring-parent-mask|parent-mask-restored|waiting|wait-returned) ;;
                    *) return 1 ;;
                esac
                ;;
            EXCEPTION_KIND=)
                case "$value" in none|os-error|subprocess-error|runtime-error|handled-signal|other) ;; *) return 1 ;; esac
                ;;
            INITIAL_PROBE_KIND=|FINAL_PROBE_KIND=)
                case "$value" in absent|alive|unknown|error|unavailable) ;; *) return 1 ;; esac
                ;;
            WAIT_RETURN_CODE=)
                case "$value" in
                    unavailable) ;;
                    -*|[0-9]*)
                        numeric_value="${value#-}"
                        case "$numeric_value" in ''|*[!0-9]*) return 1 ;; esac
                        ;;
                    *) return 1 ;;
                esac
                ;;
            PROBE_COUNT=)
                case "$value" in ''|*[!0-9]*) return 1 ;; esac
                ;;
            ELAPSED_BUCKET=)
                case "$value" in fast|bounded|extended) ;; *) return 1 ;; esac
                ;;
        esac
        printf '%s%s\n' "$field" "$value" >&2
    done
}

awk '/^if \[ "\$mode" = "self-test-kcpassword" \]; then$/ { exit } { print }' \
    "$source_script" >"$subject"
case "$mode" in
    fault-timeout|fault-raises|fault-leader|fault-leader-raises|fault-signal|fault-signal-raises|fault-residue-diagnostic|fault-residue-observer-diagnostic|outer-cleanup-false|outer-cleanup-raises)
        awk -v fault_mode="$mode" '
            /^def cleanup_owned_process\(\):$/ {
                print "def cleanup_owned_process_real():"
                next
            }
            /^cleanup_in_progress = False$/ {
                print "def cleanup_owned_process():"
                if (fault_mode != "fault-residue-diagnostic" && fault_mode != "fault-residue-observer-diagnostic") {
                    print "    cleanup_owned_process_real()"
                }
                if (fault_mode == "fault-raises" || fault_mode == "fault-leader-raises" || fault_mode == "fault-signal-raises" || fault_mode == "outer-cleanup-raises") {
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
case "$mode" in
    block-false|block-raises|block-false-post-fault|block-raises-post-fault|outer-block-false|outer-block-raises)
        awk -v fault_mode="$mode" '
            /^def block_handled_signals_for_cleanup\(\):$/ {
                print
                if (fault_mode == "block-raises" || fault_mode == "block-raises-post-fault" || fault_mode == "outer-block-raises") {
                    print "    raise RuntimeError"
                } else {
                    print "    return False"
                }
                skipping = 1
                next
            }
            skipping && /^$/ {
                skipping = 0
                print
                next
            }
            !skipping { print }
        ' "$subject" >"$subject.fault"
        mv "$subject.fault" "$subject"
        ;;
esac
case "$mode" in
    probe-transient-error)
        awk '
            /^def process_group_alive\(\):$/ {
                print "def process_group_alive_real():"
                next
            }
            /^def cleanup_owned_process\(\):$/ {
                print "process_group_probe_calls = 0"
                print "if not hasattr(signal, \"SIGKILL\"):"
                print "    signal.SIGKILL = signal.SIGTERM"
                print ""
                print "def process_group_alive():"
                print "    global process_group_probe_calls"
                print "    process_group_probe_calls += 1"
                print "    if process_group_probe_calls == 1:"
                print "        raise OSError"
                print "    return False"
                print ""
                print
                next
            }
            { print }
        ' "$subject" >"$subject.probe"
        mv "$subject.probe" "$subject"
        ;;
    probe-persistent-error|probe-persistent-oracle-delay)
        awk -v probe_mode="$mode" '
            /^def process_group_alive\(\):$/ {
                print "def process_group_alive_real():"
                next
            }
            /^    cleanup_deadline = time\.monotonic\(\) \+ 0\.5$/ {
                print
                print "    globals()[\"UUREMOTE_TEST_CLEANUP_DEADLINE\"] = cleanup_deadline"
                next
            }
            /^            if not process_group_alive\(\):$/ {
                print "            globals()[\"UUREMOTE_TEST_PROBE_IN_RETRY\"] = True"
                print "            globals()[\"UUREMOTE_TEST_PROBE_AUTHORIZED\"] = time.monotonic() < cleanup_deadline"
                print "            try:"
                print "                group_absent = not process_group_alive()"
                print "            finally:"
                print "                globals()[\"UUREMOTE_TEST_PROBE_IN_RETRY\"] = False"
                print "                globals()[\"UUREMOTE_TEST_PROBE_AUTHORIZED\"] = False"
                print "            if group_absent:"
                next
            }
            /^def cleanup_owned_process\(\):$/ {
                print "process_group_probe_calls = 0"
                print "if not hasattr(signal, \"SIGKILL\"):"
                print "    signal.SIGKILL = signal.SIGTERM"
                print ""
                print "def process_group_alive():"
                print "    global process_group_probe_calls"
                print "    process_group_probe_calls += 1"
                print "    pathlib.Path(os.environ[\"UUREMOTE_TEST_PROBE_COUNT_PATH\"]).write_text(str(process_group_probe_calls))"
                print "    if \"" probe_mode "\" == \"probe-persistent-oracle-delay\" and globals().get(\"UUREMOTE_TEST_PROBE_IN_RETRY\", False):"
                print "        time.sleep(0.55)"
                print "    cleanup_deadline = globals().get(\"UUREMOTE_TEST_CLEANUP_DEADLINE\")"
                print "    if cleanup_deadline is not None and not globals().get(\"UUREMOTE_TEST_PROBE_AUTHORIZED\", False):"
                print "        pathlib.Path(os.environ[\"UUREMOTE_TEST_LATE_PROBE_MARKER\"]).touch()"
                print "    raise OSError"
                print ""
                print
                next
            }
            { print }
        ' "$subject" >"$subject.probe"
        mv "$subject.probe" "$subject"
        ;;
    process-completed-diagnostic|process-completed-diagnostic-*)
        awk '
            /^def process_group_alive\(\):$/ {
                print "def process_group_alive_real():"
                next
            }
            /^def cleanup_owned_process\(\):$/ {
                print "process_group_probe_kinds = []"
                print ""
                print "def process_group_alive():"
                print "    try:"
                print "        group_alive = process_group_alive_real()"
                print "    except OSError:"
                print "        process_group_probe_kinds.append(\"error\")"
                print "        raise"
                print "    if group_alive is True:"
                print "        process_group_probe_kinds.append(\"alive\")"
                print "    elif group_alive is False:"
                print "        process_group_probe_kinds.append(\"absent\")"
                print "    else:"
                print "        process_group_probe_kinds.append(\"unknown\")"
                print "    return group_alive"
                print ""
                print
                next
            }
            /^exit_code = 125$/ {
                print
                print "observed_wait_return_code = \"unavailable\""
                print "diagnostic_boundary_stage = \"initialized\""
                print "diagnostic_exception_kind = \"none\""
                print "diagnostic_started_at = time.monotonic()"
                next
            }
            /^    output_descriptor = os\.open\($/ {
                print "    diagnostic_boundary_stage = \"opening-output\""
                print
                in_output_open = 1
                next
            }
            in_output_open && /^    \)$/ {
                print
                print "    diagnostic_boundary_stage = \"output-opened\""
                in_output_open = 0
                next
            }
            /^        process = subprocess\.Popen\($/ {
                print "        diagnostic_boundary_stage = \"popen-entered\""
                print
                in_popen = 1
                next
            }
            in_popen && /^        \)$/ {
                print
                print "        diagnostic_boundary_stage = \"popen-returned\""
                in_popen = 0
                next
            }
            /^        process_group_id = process\.pid$/ {
                print
                print "        diagnostic_boundary_stage = \"group-recorded\""
                next
            }
            /^        owned_cleanup_required = True$/ {
                print
                print "        diagnostic_boundary_stage = \"ownership-recorded\""
                next
            }
            /^        signal\.pthread_sigmask\(signal\.SIG_SETMASK, previous_signal_mask\)$/ {
                print "        diagnostic_boundary_stage = \"restoring-parent-mask\""
                print
                next
            }
            /^        previous_signal_mask = None$/ {
                print
                print "        diagnostic_boundary_stage = \"parent-mask-restored\""
                next
            }
            /^        return_code = process\.wait\(timeout=timeout_seconds\)$/ {
                print "        diagnostic_boundary_stage = \"waiting\""
                print
                print "        observed_wait_return_code = str(return_code)"
                print "        diagnostic_boundary_stage = \"wait-returned\""
                next
            }
            /^except HandledSignal:$/ {
                print
                print "    diagnostic_exception_kind = \"handled-signal\""
                next
            }
            /^except Exception:$/ {
                print "except Exception as diagnostic_exception:"
                print "    if isinstance(diagnostic_exception, subprocess.SubprocessError):"
                print "        diagnostic_exception_kind = \"subprocess-error\""
                print "    elif isinstance(diagnostic_exception, OSError):"
                print "        diagnostic_exception_kind = \"os-error\""
                print "    elif isinstance(diagnostic_exception, RuntimeError):"
                print "        diagnostic_exception_kind = \"runtime-error\""
                print "    else:"
                print "        diagnostic_exception_kind = \"other\""
                next
            }
            /^raise SystemExit\(exit_code\)$/ {
                print "diagnostic_elapsed = time.monotonic() - diagnostic_started_at"
                print "if diagnostic_elapsed < 0.05:"
                print "    diagnostic_elapsed_bucket = \"fast\""
                print "elif diagnostic_elapsed < 0.5:"
                print "    diagnostic_elapsed_bucket = \"bounded\""
                print "else:"
                print "    diagnostic_elapsed_bucket = \"extended\""
                print "diagnostic_initial_probe = process_group_probe_kinds[0] if process_group_probe_kinds else \"unavailable\""
                print "diagnostic_final_probe = process_group_probe_kinds[-1] if process_group_probe_kinds else \"unavailable\""
                print "pathlib.Path(os.environ[\"UUREMOTE_TEST_COMPLETED_DIAGNOSTIC_PATH\"]).write_text("
                print "    f\"BOUNDARY_STAGE={diagnostic_boundary_stage}\\n\""
                print "    f\"EXCEPTION_KIND={diagnostic_exception_kind}\\n\""
                print "    f\"INITIAL_PROBE_KIND={diagnostic_initial_probe}\\n\""
                print "    f\"FINAL_PROBE_KIND={diagnostic_final_probe}\\n\""
                print "    f\"WAIT_RETURN_CODE={observed_wait_return_code}\\n\""
                print "    f\"PROBE_COUNT={len(process_group_probe_kinds)}\\n\""
                print "    f\"ELAPSED_BUCKET={diagnostic_elapsed_bucket}\\n\","
                print "    encoding=\"ascii\","
                print ")"
                print
            }
            { print }
        ' "$subject" >"$subject.diagnostic"
        mv "$subject.diagnostic" "$subject"
        ;;
esac
case "$mode" in
    process-completed-diagnostic-failure)
        awk '
            /^def process_group_alive_real\(\):$/ {
                print "def process_group_alive_original():"
                next
            }
            /^def cleanup_owned_process\(\):$/ {
                print "def process_group_alive_real():"
                print "    return True"
                print ""
                print
                next
            }
            { print }
        ' "$subject" >"$subject.diagnostic-failure"
        mv "$subject.diagnostic-failure" "$subject"
        ;;
esac
case "$mode" in
    process-completed-diagnostic-preexec-failure)
        awk '
            /^        def restore_child_signal_mask\(\):$/ {
                print
                print "            raise RuntimeError"
                next
            }
            { print }
        ' "$subject" >"$subject.diagnostic-boundary"
        mv "$subject.diagnostic-boundary" "$subject"
        ;;
    process-completed-diagnostic-ownership-failure)
        awk '
            /^        diagnostic_boundary_stage = "group-recorded"$/ {
                print
                print "        raise RuntimeError"
                next
            }
            { print }
        ' "$subject" >"$subject.diagnostic-boundary"
        mv "$subject.diagnostic-boundary" "$subject"
        ;;
    process-completed-diagnostic-parent-restore-failure)
        awk '
            /^        diagnostic_boundary_stage = "ownership-recorded"$/ {
                parent_restore_pending = 1
                print
                next
            }
            parent_restore_pending && /^    if previous_signal_mask is not None:$/ {
                print "    if True:"
                parent_restore_pending = 0
                next
            }
            /^        signal\.pthread_sigmask\(signal\.SIG_SETMASK, previous_signal_mask\)$/ {
                print "        raise RuntimeError"
                next
            }
            { print }
        ' "$subject" >"$subject.diagnostic-boundary"
        mv "$subject.diagnostic-boundary" "$subject"
        ;;
esac
case "$mode" in
    fault-post-unmask|outer-post-unmask|fault-first-wait|outer-first-wait|block-false-post-fault|block-raises-post-fault)
        awk '
            /^exit_code = 125$/ {
                print "def wait_for_test_group_recording():"
                print "    marker = pathlib.Path(os.environ[\"UUREMOTE_TEST_GROUP_RECORDED_PATH\"])"
                print "    marker_deadline = time.monotonic() + 2"
                print "    while time.monotonic() < marker_deadline:"
                print "        if marker.exists():"
                print "            return"
                print "        time.sleep(0.01)"
                print "    raise RuntimeError"
                print ""
                print
                next
            }
            { print }
        ' "$subject" >"$subject.group-handshake"
        mv "$subject.group-handshake" "$subject"
        ;;
esac
case "$mode" in
    fault-post-unmask|outer-post-unmask)
        awk '
            /^        previous_signal_mask = None$/ {
                print
                print "    wait_for_test_group_recording()"
                print "    raise RuntimeError"
                next
            }
            { print }
        ' "$subject" >"$subject.injected"
        mv "$subject.injected" "$subject"
        ;;
    fault-first-wait|outer-first-wait|block-false-post-fault|block-raises-post-fault)
        awk '
            /^        return_code = process\.wait\(timeout=timeout_seconds\)$/ {
                print "        wait_for_test_group_recording()"
                print "        raise RuntimeError"
            }
            { print }
        ' "$subject" >"$subject.injected"
        mv "$subject.injected" "$subject"
        ;;
esac
case "$mode" in
    pending-finalization-swapped)
        awk '
            /^finally:$/ {
                in_finalization = 1
                print
                next
            }
            in_finalization && /^    if cleanup_signal_mask is not None:$/ {
                collecting_mask = 1
            }
            in_finalization && /^    for handled_signal, previous_handler in previous_handlers.items\(\):$/ {
                collecting_mask = 0
                collecting_handlers = 1
            }
            in_finalization && /^raise SystemExit\(exit_code\)$/ {
                printf "%s%s", handler_block, mask_block
                in_finalization = 0
                collecting_handlers = 0
                print
                next
            }
            in_finalization && collecting_mask {
                mask_block = mask_block $0 "\n"
                next
            }
            in_finalization && collecting_handlers {
                handler_block = handler_block $0 "\n"
                next
            }
            { print }
        ' "$subject" >"$subject.swapped"
        mv "$subject.swapped" "$subject"
        ;;
    startup-preexec-block)
        awk '
            /^        def restore_child_signal_mask\(\):$/ {
                print
                print "            pathlib.Path(os.environ[\"UUREMOTE_TEST_PYTHON_STAGE_PATH\"]).write_text(\"startup-preexec-block\")"
                print "            pathlib.Path(os.environ[\"UUREMOTE_TEST_PYTHON_PID_PATH\"]).write_text(f\"{os.getpid()} {os.getpgrp()}\")"
                print "            while True:"
                print "                time.sleep(30)"
                next
            }
            { print }
        ' "$subject" >"$subject.startup-block"
        mv "$subject.startup-block" "$subject"
        ;;
esac
case "$mode" in
    startup-preexec-block|absolute-clock-block|absolute-poll-block|absolute-root-reap|absolute-precommit-signal|absolute-shell-signal-relay)
        sed 's/ASSIST_ALLOW_DEADLINE_MILLISECONDS=60000/ASSIST_ALLOW_DEADLINE_MILLISECONDS=2500/' \
            "$subject" >"$subject.short-deadline"
        mv "$subject.short-deadline" "$subject"
        ;;
esac
if [ "$mode" = "absolute-shell-signal-relay" ]; then
    sed 's/ASSIST_ALLOW_DEADLINE_MILLISECONDS=2500/ASSIST_ALLOW_DEADLINE_MILLISECONDS=6000/' \
        "$subject" >"$subject.signal-relay-deadline"
    mv "$subject.signal-relay-deadline" "$subject"
fi
case "$mode" in
    absolute-clock-block|absolute-poll-block|absolute-shell-signal-relay)
        awk -v block_mode="$mode" '
            /^uuremote_now_milliseconds\(\) \{$/ {
                print "record_absolute_deadline_test_block() {"
                print "    local stage=\"$1\""
                print "    local blocker_pid"
                print "    printf \047%s\\n\047 \"$stage\" >\"${UUREMOTE_TEST_SHELL_STAGE_PATH:?}\""
                print "    uuremote_python3 - \"${UUREMOTE_TEST_PYTHON_PID_PATH:?}\" <<\047PYTHON\047 &"
                print "import os"
                print "import pathlib"
                print "import sys"
                print "import time"
                print "pathlib.Path(sys.argv[1]).write_text(f\"{os.getpid()} {os.getpgrp()}\", encoding=\"ascii\")"
                print "blocker_ready_path = os.environ.get(\"UUREMOTE_TEST_BLOCKER_READY_PATH\")"
                print "if blocker_ready_path:"
                print "    pathlib.Path(blocker_ready_path).write_text(\"blocker-ready\", encoding=\"ascii\")"
                print "time.sleep(30)"
                print "PYTHON"
                print "    blocker_pid=\"$!\""
                print "    wait \"$blocker_pid\""
                print "}"
                print ""
                if (block_mode == "absolute-clock-block") {
                    print "uuremote_now_milliseconds() {"
                    print "    record_absolute_deadline_test_block clock-block"
                    print "    return 1"
                    print "}"
                    skipping_clock = 1
                    next
                }
            }
            skipping_clock && /^}$/ {
                skipping_clock = 0
                next
            }
            skipping_clock { next }
            (block_mode == "absolute-poll-block" || block_mode == "absolute-shell-signal-relay") && /^wait_uuremote_poll\(\) \{$/ {
                print "wait_uuremote_poll() {"
                print "    record_absolute_deadline_test_block poll-block"
                print "    return 1"
                print "}"
                skipping_poll = 1
                next
            }
            skipping_poll && /^}$/ {
                skipping_poll = 0
                next
            }
            skipping_poll { next }
            { print }
        ' "$subject" >"$subject.absolute-block"
        mv "$subject.absolute-block" "$subject"
        ;;
esac
case "$mode" in
    startup-preexec-block|absolute-poll-block|absolute-precommit-signal|absolute-shell-signal-relay)
        awk -v boundary_mode="$mode" '
            /^run_bounded_gui_cli_to_file\(\) \{$/ {
                print
                if (boundary_mode == "startup-preexec-block") {
                    print "    run_bounded_uuremote_cli_to_file_with_status \"$1\" \"$2\" \"$3\" /usr/bin/true"
                } else if (boundary_mode == "absolute-precommit-signal") {
                    print "    printf \047%s\\n\047 \047{\"success\":true,\"enabled\":true}\047 >\"$1\""
                    print "    printf \047completed:0\\n\047 >\"$2\""
                } else {
                    print "    printf \047%s\\n\047 \047{\"success\":true,\"enabled\":false}\047 >\"$1\""
                    print "    printf \047completed:0\\n\047 >\"$2\""
                }
                print "}"
                skipping = 1
                next
            }
            skipping && /^}$/ {
                skipping = 0
                next
            }
            !skipping { print }
        ' "$subject" >"$subject.absolute-boundary"
        mv "$subject.absolute-boundary" "$subject"
        ;;
esac
if [ "$mode" = "absolute-shell-signal-relay" ]; then
    awk '
        /^    supervisor_pid="\$!"$/ {
            print
            print "    supervisor_group=\"$(/bin/ps -o pgid= -p \"$supervisor_pid\" | tr -d \047 \047)\""
            print "    printf \047%s %s\\n\047 \"$supervisor_pid\" \"$supervisor_group\" >\"${UUREMOTE_TEST_SUPERVISOR_PID_PATH:?}\""
            next
        }
        /^        observe_worker_descendants\(snapshot_timeout\)$/ && !ready_injected {
            print
            print "        blocker_ready = pathlib.Path(os.environ[\"UUREMOTE_TEST_BLOCKER_READY_PATH\"])"
            print "        if blocker_ready.exists():"
            print "            pathlib.Path(os.environ[\"UUREMOTE_TEST_RELAY_READY_PATH\"]).write_text(\"relay-ready\", encoding=\"ascii\")"
            ready_injected = 1
            next
        }
        { print }
    ' "$subject" >"$subject.signal-relay"
    mv "$subject.signal-relay" "$subject"
fi
if [ "$mode" = "absolute-precommit-signal" ]; then
    awk '
        /^    precommit_mask = signal\.pthread_sigmask\(signal\.SIG_BLOCK, handled_signals\)$/ && !injected {
            print
            print "    os.kill(os.getpid(), signal.SIGTERM)"
            injected = 1
            next
        }
        { print }
        END {
            if (!injected) {
                exit 1
            }
        }
    ' "$subject" >"$subject.precommit-signal"
    mv "$subject.precommit-signal" "$subject"
fi
if [ "$mode" = "absolute-root-reap" ]; then
    awk '
        /^if \[ "\$mode" = "assist-allow-worker" \]; then$/ {
            print
            print "    if [ \"${UUREMOTE_TEST_ROOT_REAP_MODE:-0}\" = 1 ]; then"
            print "        trap \047exit 0\047 USR1"
            print "        uuremote_python3 - \"${UUREMOTE_TEST_PYTHON_STAGE_PATH:?}\" \"${UUREMOTE_TEST_PYTHON_PID_PATH:?}\" \"$$\" <<\047PYTHON\047 &"
            print "import os"
            print "import pathlib"
            print "import signal"
            print "import sys"
            print "import time"
            print "os.setsid()"
            print "signal.signal(signal.SIGTERM, signal.SIG_IGN)"
            print "signal.signal(signal.SIGHUP, signal.SIG_IGN)"
            print "pathlib.Path(sys.argv[1]).write_text(\047root-exit-descendant\047, encoding=\047ascii\047)"
            print "pathlib.Path(sys.argv[2]).write_text(f\047{os.getpid()} {os.getpgrp()}\047, encoding=\047ascii\047)"
            print "time.sleep(0.2)"
            print "os.kill(int(sys.argv[3]), signal.SIGUSR1)"
            print "time.sleep(30)"
            print "PYTHON"
            print "        wait \"$!\""
            print "    fi"
            next
        }
        { print }
    ' "$subject" >"$subject.root-reap"
    mv "$subject.root-reap" "$subject"
fi
case "$mode" in
    startup-preexec-block|absolute-clock-block|absolute-poll-block|absolute-root-reap|absolute-precommit-signal|absolute-shell-signal-relay)
        awk '
            /^if \[ "\$mode" = "assist-allow-worker" \]; then$/ {
                print
                print "    fixture_group=\"$(/bin/ps -o pgid= -p \"$$\" | tr -d \047 \047)\""
                print "    printf \047%s %s\\n\047 \"$$\" \"$fixture_group\" >\"${UUREMOTE_TEST_PYTHON_PID_PATH:?}\""
                next
            }
            { print }
        ' "$subject" >"$subject.absolute-metadata"
        mv "$subject.absolute-metadata" "$subject"
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

case "$mode" in
    native-atomic|native-transform-check)
        native_scenario="${2:?}"
        /usr/bin/sed 's/ASSIST_ALLOW_DEADLINE_MILLISECONDS=60000/ASSIST_ALLOW_DEADLINE_MILLISECONDS=4000/' \
            "$subject" >"$subject.native-deadline"
        mv "$subject.native-deadline" "$subject"
        awk '
            /^if \[ "\$mode" = "assist-allow-worker" \]; then$/ {
                print "native_fixture_record() {"
                print "    local child_pid child_group"
                print "    /bin/bash -c \047trap \"\" TERM; exec /bin/sleep 30\047 &"
                print "    child_pid=\"$!\""
                print "    child_group=\"$(/bin/ps -o pgid= -p \"$child_pid\" | /usr/bin/tr -d \047[:space:]\047)\""
                print "    printf \047%s %s\\n\047 \"$child_pid\" \"$child_group\" >>\"${UUREMOTE_TEST_NATIVE_PID_PATH:?}\""
                print "    wait \"$child_pid\""
                print "}"
                print "native_fixture_record_completed() {"
                print "    local child_pid child_group"
                print "    /bin/sleep 0.05 &"
                print "    child_pid=\"$!\""
                print "    child_group=\"$(/bin/ps -o pgid= -p \"$child_pid\" | /usr/bin/tr -d \047[:space:]\047)\""
                print "    printf \047%s %s\\n\047 \"$child_pid\" \"$child_group\" >>\"${UUREMOTE_TEST_NATIVE_PID_PATH:?}\""
                print "    wait \"$child_pid\""
                print "}"
                print "native_require_state() {"
                print "    [ \"$(/bin/cat \"${UUREMOTE_ASSIST_INTERNAL_STATE_PATH:?}\")\" = \"$1\" ]"
                print "}"
                print "native_observe_first_open() {"
                print "    if native_require_state $\047v1\\t1\\topen\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\tunavailable\\tunavailable\047; then"
                print "        printf \047open\\n\047 >\"${UUREMOTE_TEST_NATIVE_STATE_PATH:?}\""
                print "    else"
                print "        printf \047missing-or-invalid\\n\047 >\"${UUREMOTE_TEST_NATIVE_STATE_PATH:?}\""
                print "    fi"
                print "    printf \047cli-blocking-path-entered\\n\047 >\"${UUREMOTE_TEST_NATIVE_ROUTE_PATH:?}\""
                print "}"
                print "run_bounded_gui_cli_to_file() {"
                print "    local output_path=\"$1\" status_path=\"$2\""
                print "    native_attempt=\"${native_attempt:-0}\""
                print "    native_attempt=\"$((native_attempt + 1))\""
                print "    case \"${UUREMOTE_TEST_NATIVE_SCENARIO:?}:$native_attempt\" in"
                print "        first-open-timeout:1|cleanup-unconfirmed:1)"
                print "            native_observe_first_open"
                print "            native_fixture_record"
                print "            ;;"
                print "        committed-then-open:1|committed-failure:1)"
                print "            native_fixture_record_completed"
                print "            printf \047{\\\"success\\\":true,\\\"enabled\\\":false}\047 >\"$output_path\""
                print "            printf \047completed:0\\n\047 >\"$status_path\""
                print "            ;;"
                print "        committed-then-open:2)"
                print "            native_require_state $\047v1\\t2\\topen\\t1\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t0\\t1\\t0\\t32\\t32\\t32\\tenabled-false\\t0\047 || return 125"
                print "            native_fixture_record"
                print "            ;;"
                print "        enabled-success:1)"
                print "            native_fixture_record_completed"
                print "            printf \047{\\\"success\\\":true,\\\"enabled\\\":true}\047 >\"$output_path\""
                print "            printf \047completed:0\\n\047 >\"$status_path\""
                print "            ;;"
                print "        *) return 125 ;;"
                print "    esac"
                print "}"
                print "wait_uuremote_poll() {"
                print "    [ \"${UUREMOTE_TEST_NATIVE_SCENARIO:-}\" != committed-failure ] || return 1"
                print "    /usr/bin/python3 - \"$1\" <<\047PYTHON\047"
                print "import sys"
                print "import time"
                print "time.sleep(int(sys.argv[1]) / 1000)"
                print "PYTHON"
                print "}"
                print
                next
            }
            { print }
        ' "$subject" >"$subject.native-fixture"
        mv "$subject.native-fixture" "$subject"
        awk '
            /^        stream = sys\.stdout\.buffer if output_stream == "stdout" else sys\.stderr\.buffer$/ {
                print "        pathlib.Path(os.environ[\"UUREMOTE_TEST_NATIVE_OUTPUT_PROBE_PATH\"]).write_text(\"absent\" if not diagnostic_state_path.exists() else \"present\", encoding=\"ascii\")"
            }
            { print }
        ' "$subject" >"$subject.native-output-probe"
        mv "$subject.native-output-probe" "$subject"
        case "${UUREMOTE_TEST_NATIVE_MUTATION:-}" in
            '') ;;
            open)
                awk '
                    /^[[:space:]]*write_assist_diagnostic_state \\$/ {
                        first_line = $0
                        getline
                        if ($0 ~ /"\$diagnostic_state_path" "\$generation" open/) {
                            print "        printf \047open-commit-bypassed\\n\047 >\"${UUREMOTE_TEST_NATIVE_MUTATION_PATH:?}\""
                            print "        :"
                            skipping = 1
                            next
                        }
                        print first_line
                        print
                        next
                    }
                    skipping {
                        if (/^        attempts="\$generation"$/) {
                            print
                            skipping = 0
                        }
                        next
                    }
                    { print }
                ' "$subject" >"$subject.native-open"
                mv "$subject.native-open" "$subject"
                ;;
            atomic)
                awk '
                    /^[[:space:]]*\/bin\/mv -f -- "\$temporary_path" "\$state_path" \|\| \{$/ {
                        print "    if ! /bin/mv -f -- \"$temporary_path\" \"$state_path\"; then"
                        print "        /bin/rm -f -- \"$temporary_path\" 2>/dev/null"
                        print "        return 1"
                        print "    fi"
                        print "    if [ \"$state\" = committed ]; then"
                        print "        printf \047atomic-replacement-bypassed\\n\047 >\"${UUREMOTE_TEST_NATIVE_MUTATION_PATH:?}\""
                        print "        printf \047\\tpartial\047 >>\"$state_path\" || return 1"
                        print "    fi"
                        skipping_move_failure = 1
                        next
                    }
                    skipping_move_failure {
                        if (/^    }$/) {
                            skipping_move_failure = 0
                        }
                        next
                    }
                    { print }
                ' "$subject" >"$subject.native-atomic"
                mv "$subject.native-atomic" "$subject"
                ;;
            cleanup-unconfirmed|cleanup-bypass)
                awk '
                    /cleanup_confirmed = cleanup_worker\(cleanup_deadline\)/ {
                        print
                        print "        pathlib.Path(os.environ[\"UUREMOTE_TEST_NATIVE_MUTATION_PATH\"]).write_text(\"cleanup-confirmation-forced\\n\", encoding=\"ascii\")"
                        print "        cleanup_confirmed = False"
                        next
                    }
                    /if not cleanup_confirmed or not recorded_owned_processes_absent\(\):/ && ENVIRON["UUREMOTE_TEST_NATIVE_MUTATION"] == "cleanup-bypass" {
                        print "    if False:"
                        next
                    }
                    { print }
                ' "$subject" >"$subject.native-cleanup"
                mv "$subject.native-cleanup" "$subject"
                ;;
            synthesis)
                /usr/bin/sed \
                    's#snapshot = synthesize_open_timeout(snapshot)#pathlib.Path(os.environ["UUREMOTE_TEST_NATIVE_MUTATION_PATH"]).write_text("open-timeout-synthesis-bypassed\\n", encoding="ascii"); raise ValueError#' \
                    "$subject" >"$subject.native-synthesis"
                mv "$subject.native-synthesis" "$subject"
                ;;
            deletion)
                /usr/bin/sed \
                    's#    state_path.unlink()#    pathlib.Path(os.environ["UUREMOTE_TEST_NATIVE_MUTATION_PATH"]).write_text("state-removal-bypassed\\n", encoding="ascii")\n    return#' \
                    "$subject" >"$subject.native-deletion"
                mv "$subject.native-deletion" "$subject"
                ;;
            *) exit 2 ;;
        esac
        ;;
esac

scenario="${2:?}"

if [ "$mode" = native-transform-check ]; then
    /bin/bash -n "$subject"
    for native_wiring in \
        'native_observe_first_open()' \
        'cli-blocking-path-entered' \
        'UUREMOTE_TEST_NATIVE_OUTPUT_PROBE_PATH'
    do
        [ "$(/usr/bin/grep -F -c "$native_wiring" "$subject")" -eq 1 ] || exit 1
    done
    for native_marker in \
        open-commit-bypassed \
        atomic-replacement-bypassed \
        cleanup-confirmation-forced \
        open-timeout-synthesis-bypassed \
        state-removal-bypassed
    do
        case "${UUREMOTE_TEST_NATIVE_MUTATION:-}" in
            '') continue ;;
            open) [ "$native_marker" = open-commit-bypassed ] || continue ;;
            atomic) [ "$native_marker" = atomic-replacement-bypassed ] || continue ;;
            cleanup-unconfirmed|cleanup-bypass) [ "$native_marker" = cleanup-confirmation-forced ] || continue ;;
            synthesis) [ "$native_marker" = open-timeout-synthesis-bypassed ] || continue ;;
            deletion) [ "$native_marker" = state-removal-bypassed ] || continue ;;
        esac
        [ "$(/usr/bin/grep -F -c "$native_marker" "$subject")" -eq 1 ] || exit 1
    done
    printf 'NATIVE_TRANSFORM=valid\n'
    exit 0
fi

if [ "$mode" = native-atomic ]; then
    export UUREMOTE_TEST_NATIVE_SCENARIO="$scenario"
    . "$subject"
    debug_level=1
    console_uid=501
    if [ "$scenario" = enabled-success ]; then
        run_assist_allow_with_absolute_deadline
        exit "$?"
    fi
    if enable_assist_or_fail; then
        exit 0
    fi
    exit "$?"
fi

case "$mode" in
    startup-preexec-block|absolute-clock-block|absolute-poll-block|absolute-root-reap|absolute-precommit-signal|absolute-shell-signal-relay)
        . "$subject"
        debug_level=0
        console_uid=501
        if [ "$mode" = absolute-root-reap ]; then
            export UUREMOTE_TEST_ROOT_REAP_MODE=1
        fi
        if enable_assist_or_fail; then
            exit 0
        else
            exit "$?"
        fi
        ;;
esac

case "$mode" in
    process|process-completed-diagnostic|process-completed-diagnostic-*|fault-*|block-*|probe-transient-error|probe-persistent-error|probe-persistent-oracle-delay|pending-finalization-swapped) ;;
    *) false ;;
esac && {
    status_path="$temporary_directory/status"
    output_path="$temporary_directory/output"
    parent_pid_path="$temporary_directory/parent.pid"
    child_pid_path="$temporary_directory/child.pid"
    fixture_pid_paths="$parent_pid_path $child_pid_path"
    late_probe_marker="$temporary_directory/late-probe"
    probe_count_path="$temporary_directory/probe-count"
    completed_diagnostic_path="$temporary_directory/completed-diagnostic"
    export UUREMOTE_TEST_LATE_PROBE_MARKER="$late_probe_marker"
    export UUREMOTE_TEST_PROBE_COUNT_PATH="$probe_count_path"
    export UUREMOTE_TEST_COMPLETED_DIAGNOSTIC_PATH="$completed_diagnostic_path"

    . "$subject"
    case "$scenario" in
        residue-metadata-failure)
            case "$mode" in
                fault-residue-metadata-diagnostic)
                    fixture_groups=""
                    ;;
                fault-residue-partial-diagnostic)
                    printf '99999991\n' >"$parent_pid_path"
                    fixture_groups="99999991"
                    ;;
                fault-residue-invalid-group-diagnostic)
                    printf '99999992\n' >"$parent_pid_path"
                    printf '99999993\n' >"$child_pid_path"
                    fixture_groups="invalid"
                    ;;
                fault-residue-invalid-pid-diagnostic)
                    printf 'invalid\n' >"$parent_pid_path"
                    printf '99999996\n' >"$child_pid_path"
                    fixture_groups="99999996"
                    ;;
                fault-residue-read-diagnostic)
                    printf '99999994\n' >"$parent_pid_path"
                    printf '99999995\n' >"$child_pid_path"
                    fixture_groups="99999994"
                    ;;
                *) exit 2 ;;
            esac
            is_native_macos() {
                return 0
            }
            run_residue_ps() {
                return 0
            }
            probe_recorded_group_signal() {
                return 1
            }
            fixture_pid_paths="$parent_pid_path $child_pid_path"
            if assert_recorded_fixture_teardown; then
                echo "Missing residue metadata unexpectedly passed" >&2
                exit 1
            fi
            printf 'ASSERTION=failed\n'
            exit 0
            ;;
        transient-probe-error)
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 100 /bin/sleep 30
            then
                echo "Transient probe fixture unexpectedly succeeded" >&2
                exit 1
            fi
            printf 'STATUS=%s\n' "$(cat "$status_path")"
            exit 0
            ;;
        persistent-probe-error)
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 100 /bin/sleep 30
            then
                echo "Persistent probe fixture unexpectedly succeeded" >&2
                exit 1
            else
                bounded_exit="$?"
            fi
            if [ "$bounded_exit" -ne 125 ] || [ -s "$status_path" ]; then
                echo "Persistent probe error did not fail closed" >&2
                exit 1
            fi
            if [ -e "$late_probe_marker" ]; then
                echo "Process group was probed after the cleanup deadline" >&2
                exit 1
            fi
            if [ "$(cat "$probe_count_path")" -lt 2 ]; then
                echo "Persistent process-group error was not retried" >&2
                exit 1
            fi
            printf 'EXIT=125\nSTATUS=absent\nPROBES_RETRIED=true\nLATE_PROBE=false\n'
            exit 0
            ;;
        completed)
            completed_command=/usr/bin/true
            if [ "$mode" = process-completed-diagnostic-popen-failure ]; then
                completed_command=/uuremote-test-command-that-does-not-exist
            fi
            if run_bounded_uuremote_cli_to_file_with_status \
                "$output_path" "$status_path" 3000 "$completed_command"
            then
                bounded_exit=0
            else
                bounded_exit="$?"
            fi
            if [ "$bounded_exit" -ne 0 ]; then
                emit_completed_failure_diagnostic || true
                exit "$bounded_exit"
            fi
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
            if [ "$mode" = fault-timeout ] || [ "$mode" = fault-raises ] || \
                [ "$mode" = fault-residue-diagnostic ] || \
                [ "$mode" = fault-residue-observer-diagnostic ] || \
                [ "$mode" = block-false ] || [ "$mode" = block-raises ]; then
                run_boundary=run_recorded_bounded_fixture
            else
                run_boundary=run_bounded_uuremote_cli_to_file_with_status
            fi
            if "$run_boundary" \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-hang \
                "$parent_pid_path" "$child_pid_path"
            then
                echo "Hanging fixture unexpectedly succeeded" >&2
                exit 1
            else
                bounded_exit="$?"
            fi
            if [ "$mode" = fault-timeout ] || [ "$mode" = fault-raises ] || \
                [ "$mode" = fault-residue-diagnostic ] || \
                [ "$mode" = fault-residue-observer-diagnostic ] || \
                [ "$mode" = block-false ] || [ "$mode" = block-raises ]; then
                if [ "$bounded_exit" -ne 125 ]; then
                    echo "Unconfirmed cleanup did not fail closed" >&2
                    exit 1
                fi
                if [ -s "$status_path" ]; then
                    echo "Unconfirmed cleanup wrote a status" >&2
                    exit 1
                fi
                if ! assert_recorded_fixture_teardown; then
                    echo "Unconfirmed cleanup left a recorded process" >&2
                    exit 1
                fi
                printf 'EXIT=125\nSTATUS=absent\n'
                if is_native_macos; then
                    printf 'PROCESS_GROUP_RELEASED=true\n'
                fi
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
        post-ownership-fault)
            if [ "$mode" != fault-post-unmask ] && [ "$mode" != fault-first-wait ] && \
                [ "$mode" != block-false-post-fault ] && [ "$mode" != block-raises-post-fault ]; then
                exit 2
            fi
            if run_recorded_bounded_fixture \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-hang \
                "$parent_pid_path" "$child_pid_path"
            then
                echo "Post-ownership fault unexpectedly succeeded" >&2
                exit 1
            else
                bounded_exit="$?"
            fi
            if [ "$bounded_exit" -ne 125 ] || [ -s "$status_path" ]; then
                echo "Post-ownership fault did not fail closed" >&2
                exit 1
            fi
            if ! assert_recorded_fixture_teardown; then
                echo "Post-ownership cleanup left a recorded process" >&2
                exit 1
            fi
            printf 'EXIT=125\nSTATUS=absent\n'
            if is_native_macos; then
                printf 'PROCESS_GROUP_RELEASED=true\n'
            fi
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
                "$output_path" "$status_path" 3000 /usr/bin/true
            gui_command="sudo|launchctl|"
            while IFS= read -r argument; do
                if [ "$argument" = "$sudo_stub" ] || \
                    [ "${argument%/bin/bash}" != "$argument" ]; then
                    gui_command="${gui_command}sudo|"
                elif [ "${argument%/usr/bin/true}" != "$argument" ]; then
                    gui_command="${gui_command}/usr/bin/true|"
                else
                    gui_command="${gui_command}${argument}|"
                fi
            done <"$command_capture"
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
                    if ! record_fixture_group_when_known && is_native_macos; then
                        echo "Fixture process group was unavailable" >&2
                        exit 1
                    fi
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
            if [ "$mode" = fault-signal ] || [ "$mode" = fault-signal-raises ] || \
                [ "$mode" = block-false ] || [ "$mode" = block-raises ]; then
                if [ -s "$runner_status_path" ]; then
                    echo "Unconfirmed cleanup wrote a status" >&2
                    exit 1
                fi
            elif [ "$(cat "$runner_status_path")" != unavailable ]; then
                echo "Interrupted runner status was not unavailable" >&2
                exit 1
            fi
            if [ "$mode" = fault-signal ] || [ "$mode" = fault-signal-raises ] || \
                [ "$mode" = block-false ] || [ "$mode" = block-raises ]; then
                if ! assert_recorded_fixture_teardown; then
                    echo "Unconfirmed signal cleanup left a recorded process" >&2
                    exit 1
                fi
                printf 'EXIT=125\nSTATUS=absent\n'
                if is_native_macos; then
                    printf 'PROCESS_GROUP_RELEASED=true\n'
                fi
            else
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
                printf 'STATUS=unavailable\n'
                printf 'PROCESS_GROUP_RELEASED=true\n'
            fi
            exit 0
            ;;
        pending-signal-int|pending-signal-term|pending-signal-hup)
            if ! is_native_macos; then
                echo "Pending-signal finalization requires native macOS" >&2
                exit 2
            fi
            runner_status_path="$temporary_directory/runner-status"
            cleanup_started_path="$temporary_directory/pending-cleanup-started"
            fixture_pid_paths="$parent_pid_path"
            (
                . "$subject"
                run_bounded_uuremote_cli_to_file_with_status \
                    "$output_path" "$runner_status_path" 30000 /bin/bash "$0" fixture-pending-signal \
                    "$parent_pid_path" "$cleanup_started_path"
            ) &
            runner_shell_pid="$!"
            fixture_pids="$runner_shell_pid"
            runner_python_pid=""
            signal_wait_attempt=0
            while [ "$signal_wait_attempt" -lt 80 ]; do
                if [ -s "$parent_pid_path" ] && record_fixture_group_when_known; then
                    runner_python_pid="$(/usr/bin/pgrep -P "$runner_shell_pid" 2>/dev/null || true)"
                    case "$runner_python_pid" in
                        ''|*[!0-9]*) runner_python_pid="" ;;
                    esac
                    if [ -n "$runner_python_pid" ]; then
                        break
                    fi
                fi
                signal_wait_attempt="$((signal_wait_attempt + 1))"
                sleep 0.05
            done
            if [ -z "$runner_python_pid" ]; then
                echo "Exact Python runner PID was unavailable" >&2
                exit 1
            fi
            /bin/kill -TERM "$runner_python_pid"
            cleanup_wait_attempt=0
            while [ "$cleanup_wait_attempt" -lt 40 ] && [ ! -s "$cleanup_started_path" ]; do
                cleanup_wait_attempt="$((cleanup_wait_attempt + 1))"
                sleep 0.01
            done
            if [ ! -s "$cleanup_started_path" ]; then
                echo "Pending-signal cleanup marker was unavailable" >&2
                exit 1
            fi
            case "$scenario" in
                pending-signal-int) signal_name=INT ;;
                pending-signal-term) signal_name=TERM ;;
                pending-signal-hup) signal_name=HUP ;;
            esac
            /bin/kill -"$signal_name" "$runner_python_pid"
            if wait "$runner_shell_pid"; then
                runner_exit=0
            else
                runner_exit="$?"
            fi
            if [ "$runner_exit" -ne 125 ]; then
                echo "Pending signal changed runner finalization" >&2
                exit 1
            fi
            if [ ! -s "$runner_status_path" ] || [ "$(cat "$runner_status_path")" != unavailable ]; then
                echo "Pending signal produced an unsafe status" >&2
                exit 1
            fi
            if ! assert_recorded_fixture_teardown; then
                echo "Pending signal left a recorded process" >&2
                exit 1
            fi
            printf 'EXIT=125\nSTATUS=unavailable\nPROCESS_GROUP_RELEASED=true\n'
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
            if [ "$mode" != fault-leader ] && [ "$mode" != fault-leader-raises ] && \
                [ "$mode" != block-false ] && [ "$mode" != block-raises ]; then
                exit 2
            fi
            release_recorded_fixture_leader=1
            if run_recorded_bounded_fixture \
                "$output_path" "$status_path" 3000 /bin/bash "$0" fixture-leader-completes-recorded \
                "$parent_pid_path" "$child_pid_path"
            then
                echo "Fault leader unexpectedly succeeded" >&2
                exit 1
            else
                bounded_exit="$?"
            fi
            if [ "$bounded_exit" -ne 125 ]; then
                echo "Unconfirmed leader cleanup did not fail closed" >&2
                exit 1
            fi
            if [ -s "$status_path" ]; then
                echo "Unconfirmed cleanup wrote a status" >&2
                exit 1
            fi
            if ! assert_recorded_fixture_teardown; then
                echo "Unconfirmed leader cleanup left a recorded process" >&2
                exit 1
            fi
            printf 'EXIT=125\nSTATUS=absent\n'
            if is_native_macos; then
                printf 'PROCESS_GROUP_RELEASED=true\n'
            fi
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

case "$mode" in
    aggregate|outer-cleanup-*|outer-post-unmask|outer-first-wait|outer-block-false|outer-block-raises) ;;
    *) false ;;
esac && {
    . "$subject"
    run_assist_allow_with_absolute_deadline() {
        ensure_assist_allowed
    }

    debug_level=0
    console_uid=501
    controlled_now=0
    clock_count_path="$temporary_directory/clock-count"
    printf '0\n' >"$clock_count_path"
    boundary_calls=0
    boundary_count_path="$temporary_directory/boundary-count"
    printf '0\n' >"$boundary_count_path"
    diagnostic_state_path="$temporary_directory/diagnostic-state"
    temporary_tree="$temporary_directory/assist-tree"
    mkdir -m 700 "$temporary_tree"
    TMPDIR="$temporary_tree"
    if [ "$mode" = outer-cleanup-false ] || [ "$mode" = outer-cleanup-raises ] || \
        [ "$mode" = outer-post-unmask ] || [ "$mode" = outer-first-wait ] || \
        [ "$mode" = outer-block-false ] || [ "$mode" = outer-block-raises ]; then
        parent_pid_path="$temporary_directory/outer-parent.pid"
        child_pid_path="$temporary_directory/outer-child.pid"
        outer_teardown_marker="$temporary_directory/outer-teardown-confirmed"
        fixture_pid_paths="$parent_pid_path $child_pid_path"
    fi

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
            deadline-after-child)
                if [ "$clock_calls" -le 2 ]; then printf '0\n'; else printf '60000\n'; fi
                ;;
            expired-no-status)
                if [ "$clock_calls" -le 2 ]; then printf '0\n'; else printf '60000\n'; fi
                ;;
            deadline-after-record)
                if [ "$clock_calls" -le 2 ]; then printf '0\n'; elif [ "$clock_calls" -eq 3 ]; then printf '100\n'; else printf '60000\n'; fi
                ;;
            deadline-before-enabled)
                if [ "$clock_calls" -le 2 ]; then printf '0\n'; elif [ "$clock_calls" -eq 3 ]; then printf '100\n'; elif [ "$clock_calls" -eq 4 ]; then printf '200\n'; else printf '60000\n'; fi
                ;;
            *) printf '%s\n' "$controlled_now" ;;
        esac
    }

    wait_uuremote_poll() {
        if [ "$scenario" = "poll-failure" ]; then
            echo 'FORGED_POLL_STDERR=device-id-fixture CustomCodeFixture' >&2
            return 7
        fi
        if [ "$scenario" = "deadline-bounds" ] && [ "$1" -ne 500 ]; then
            echo "Polling interval exceeded the remaining deadline" >&2
            exit 1
        fi
        case "$scenario:$boundary_calls" in
            worker-commits-enabled-false:1|worker-failure-output-empty:1|worker-committed-write-failure:1)
                controlled_now=60000
                ;;
            worker-second-open-aggregate:2)
                controlled_now=60000
                ;;
            *) controlled_now="$((controlled_now + $1))" ;;
        esac
    }

    require_worker_state() {
        local expected_state actual_state

        expected_state="$1"
        actual_state="$(/bin/cat "$diagnostic_state_path" 2>/dev/null)" || return 1
        [ "$actual_state" = "$expected_state" ]
    }

    worker_first_open_state=$'v1\t1\topen\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\tunavailable\tunavailable'
    worker_first_enabled_false_state=$'v1\t1\tcommitted\t1\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t1\t0\t32\t32\t32\tenabled-false\t0'
    worker_second_open_state=$'v1\t2\topen\t1\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t1\t0\t32\t32\t32\tenabled-false\t0'
    worker_second_enabled_false_state=$'v1\t2\tcommitted\t2\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t2\t0\t32\t32\t32\tenabled-false\t0'
    worker_enabled_true_state=$'v1\t1\tcommitted\t1\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t1\t31\t31\t31\tenabled-true\t0'

    run_bounded_gui_cli_to_file() {
        local output_path="$1"
        local status_path="$2"
        local timeout_milliseconds="$3"
        shift 3
        boundary_calls="$((boundary_calls + 1))"
        printf '%s\n' "$boundary_calls" >"$boundary_count_path"
        if [ "$mode" = outer-cleanup-false ] || [ "$mode" = outer-cleanup-raises ] || \
            [ "$mode" = outer-post-unmask ] || [ "$mode" = outer-first-wait ] || \
            [ "$mode" = outer-block-false ] || [ "$mode" = outer-block-raises ]; then
            if run_recorded_bounded_fixture \
                "$output_path" "$status_path" "$timeout_milliseconds" \
                /bin/bash "$0" fixture-hang "$parent_pid_path" "$child_pid_path"
            then
                return 0
            else
                bounded_exit="$?"
            fi
            if [ -s "$status_path" ]; then
                return 124
            fi
            if is_native_macos && [ "$bounded_exit" -ne 125 ]; then
                return 124
            fi
            if ! assert_recorded_fixture_teardown; then
                return 124
            fi
            : >"$outer_teardown_marker"
            return 125
        fi
        printf 'completed:0\n' >"$status_path"
        case "$scenario:$boundary_calls" in
            worker-open-before-cli:1)
                require_worker_state "$worker_first_open_state" || return 1
                printf '{"success":true,"enabled":true}' >"$output_path"
                controlled_now=100
                ;;
            worker-commits-enabled-false:1|worker-committed-write-failure:1|worker-failure-output-empty:1)
                printf '{"success":true,"enabled":false}' >"$output_path"
                controlled_now=100
                ;;
            worker-second-open-aggregate:1)
                printf '{"success":true,"enabled":false}' >"$output_path"
                controlled_now=100
                ;;
            worker-second-open-aggregate:2)
                require_worker_state "$worker_second_open_state" || return 1
                printf '{"success":true,"enabled":false}' >"$output_path"
                controlled_now=700
                ;;
            worker-enabled-true-committed:1)
                printf '{"success":true,"enabled":true}' >"$output_path"
                controlled_now=100
                ;;
            worker-open-write-failure:*) exit 2 ;;
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
            deadline-after-child:1)
                printf '{"success":true,"enabled":true,"deviceId":"device-id-fixture","customCode":"CustomCodeFixture"}' >"$output_path"
                ;;
            expired-no-status:1)
                /bin/rm -f -- "$status_path"
                printf '{"success":true,"enabled":true,"deviceId":"device-id-fixture","customCode":"CustomCodeFixture"}' >"$output_path"
                return 125
                ;;
            deadline-after-record:1)
                printf '{"success":true,"enabled":false}' >"$output_path"
                ;;
            deadline-before-enabled:1)
                printf '{"success":true,"enabled":true}' >"$output_path"
                ;;
            poll-failure:1)
                printf '{"success":true,"enabled":false}' >"$output_path"
                ;;
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
            *) exit 2 ;;
        esac
    }

    case "$scenario" in
        worker-failure-output-empty) debug_level=1 ;;
        deadline-bounds|debug1-failure|hostile-failure|late-success|expired-no-status|deadline-after-record|deadline-before-enabled|invalid-clock|invalid-clock-loop|invalid-clock-post-call|clock-status-start|clock-status-loop|clock-status-post-call) debug_level=1 ;;
        debug2-failure) debug_level=2 ;;
        debug3-failure) debug_level=3 ;;
        deadline-after-child)
            debug_level=1
            eval "$(declare -f classify_assist_allow_response | \
                /usr/bin/sed '1s/classify_assist_allow_response/classify_assist_allow_response_real/')"
            classify_assist_allow_response() {
                [ "$2" = timeout ] || return 1
                classify_assist_allow_response_real "$@"
            }
            ;;
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
        outer-success)
            ensure_assist_allowed() {
                return 0
            }
            ;;
        transient-success|debug0-failure|poll-failure|worker-open-before-cli|worker-commits-enabled-false|worker-second-open-aggregate|worker-enabled-true-committed|worker-open-write-failure|worker-committed-write-failure|outer-cleanup-false|outer-cleanup-raises|outer-post-unmask|outer-first-wait|outer-block-false|outer-block-raises) ;;
        *) exit 2 ;;
    esac

    if [ "$scenario" = outer-success ] || \
        [ "$mode" = outer-cleanup-false ] || [ "$mode" = outer-cleanup-raises ] || \
        [ "$mode" = outer-post-unmask ] || [ "$mode" = outer-first-wait ] || \
        [ "$mode" = outer-block-false ] || [ "$mode" = outer-block-raises ]; then
        if enable_assist_or_fail; then
            status=0
        else
            status="$?"
        fi
        if is_native_macos || [ "$scenario" = outer-success ]; then
            if [ ! -d "$temporary_tree" ] || [ -n "$(find "$temporary_tree" -mindepth 1 -print -quit)" ]; then
                exit 125
            fi
        fi
        if [ "$mode" = outer-cleanup-false ] || [ "$mode" = outer-cleanup-raises ] || \
            [ "$mode" = outer-post-unmask ] || [ "$mode" = outer-first-wait ] || \
            [ "$mode" = outer-block-false ] || [ "$mode" = outer-block-raises ]; then
            if is_native_macos; then
                if [ ! -f "$outer_teardown_marker" ]; then
                    exit 125
                fi
                if [ ! -s "$parent_pid_path" ] || [ ! -s "$child_pid_path" ]; then
                    exit 125
                fi
            fi
        fi
        exit "$status"
    fi

    case "$scenario" in
        worker-open-before-cli|worker-commits-enabled-false|worker-second-open-aggregate|worker-enabled-true-committed|worker-open-write-failure|worker-committed-write-failure|worker-failure-output-empty)
            worker_stdout="$temporary_directory/worker-stdout"
            worker_stderr="$temporary_directory/worker-stderr"
            if ensure_assist_allowed "$diagnostic_state_path" >"$worker_stdout" 2>"$worker_stderr"; then
                status=0
            else
                status="$?"
            fi
            case "$scenario" in
                worker-open-before-cli|worker-enabled-true-committed)
                    [ "$status" -eq 0 ] || exit 1
                    [ "$(/bin/cat "$worker_stdout")" = "ASSIST_STATE=enabled" ] || exit 1
                    [ ! -s "$worker_stderr" ] || exit 1
                    require_worker_state "$worker_enabled_true_state" || exit 1
                    /bin/cat "$worker_stdout"
                    printf 'WORKER_STATE=committed-enabled-true\n'
                    ;;
                worker-commits-enabled-false)
                    [ "$status" -eq 1 ] || exit 1
                    [ ! -s "$worker_stdout" ] || exit 1
                    [ ! -s "$worker_stderr" ] || exit 1
                    require_worker_state "$worker_first_enabled_false_state" || exit 1
                    printf 'WORKER_STATE=committed-enabled-false\n'
                    ;;
                worker-second-open-aggregate)
                    [ "$status" -eq 1 ] || exit 1
                    [ ! -s "$worker_stdout" ] || exit 1
                    [ ! -s "$worker_stderr" ] || exit 1
                    require_worker_state "$worker_second_enabled_false_state" || exit 1
                    printf 'WORKER_STATE=committed-second-enabled-false\n'
                    ;;
                worker-open-write-failure)
                    [ "$status" -eq 1 ] || exit 1
                    [ ! -s "$worker_stdout" ] || exit 1
                    [ ! -s "$worker_stderr" ] || exit 1
                    [ "$(/bin/cat "$boundary_count_path")" -eq 0 ] || exit 1
                    printf 'WORKER_CLI_CALLS=0\n'
                    ;;
                worker-committed-write-failure)
                    [ "$status" -eq 1 ] || exit 1
                    [ ! -s "$worker_stdout" ] || exit 1
                    [ ! -s "$worker_stderr" ] || exit 1
                    require_worker_state "$worker_first_open_state" || exit 1
                    printf 'WORKER_STATE=open-timeout-projection\n'
                    ;;
                worker-failure-output-empty)
                    [ "$status" -eq 1 ] || exit 1
                    [ ! -s "$worker_stdout" ] || exit 1
                    [ ! -s "$worker_stderr" ] || exit 1
                    printf 'WORKER_OUTPUT=empty\n'
                    ;;
            esac
            exit "$status"
            ;;
    esac

    if ensure_assist_allowed "$diagnostic_state_path"; then
        exit 0
    else
        status="$?"
    fi
    if [ ! -d "$temporary_tree" ] || [ -n "$(find "$temporary_tree" -mindepth 1 -print -quit)" ]; then
        echo "Temporary tree was not empty" >&2
        exit 1
    fi
    if [ "$scenario" = expired-no-status ] && [ "$(cat "$boundary_count_path")" -ne 1 ]; then
        exit 1
    fi
    case "$scenario" in
        late-success|deadline-after-child|deadline-after-record|deadline-before-enabled|poll-failure|invalid-clock|invalid-clock-loop|invalid-clock-post-call|clock-status-start|clock-status-loop|clock-status-post-call|fault-mktemp|fault-chmod|fault-truncate|fault-status-write|fault-cleanup)
        printf 'TEMPORARY_TREE_EMPTY=true\n'
        if [ "$scenario" = poll-failure ]; then
            printf 'BOUNDARY_CALLS=%s\n' "$(cat "$boundary_count_path")"
        fi
            ;;
    esac
    echo "Could not enable unattended control within 60 seconds" >&2
    exit "$status"
}

case "$mode" in
    state|state-fault-*)
        state_path="${3:?}"
        . "$subject"
        baseline_values=(
            1 0 0 0 0 0 0 0 0 0 0 0 1 0 84 84 84 enabled-false 0
        )
        case "$scenario" in
            first-open)
                write_assist_diagnostic_state \
                    "$state_path" 1 open \
                    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 unavailable unavailable
                exit "$?"
                ;;
            hostile-rejected)
                fixture_payload=(device-id-fixture CustomCodeFixture FORGED_OUTPUT)
                write_assist_diagnostic_state \
                    "$state_path" 1 committed "${baseline_values[@]}" || exit "$?"
                for fixture_marker in "${fixture_payload[@]}"; do
                    if write_assist_diagnostic_state \
                        "$state_path" "$fixture_marker" committed "${baseline_values[@]}"
                    then
                        exit 1
                    fi
                    if write_assist_diagnostic_state \
                        "$state_path" 1 "$fixture_marker" "${baseline_values[@]}"
                    then
                        exit 1
                    fi
                    if write_assist_diagnostic_state \
                        "$state_path" 1 committed \
                        1 0 0 0 0 0 0 0 0 0 0 0 1 0 84 84 84 "$fixture_marker" 0
                    then
                        exit 1
                    fi
                done
                exit 1
                ;;
            committed)
                write_assist_diagnostic_state \
                    "$state_path" 1 committed "${baseline_values[@]}"
                exit "$?"
                ;;
            invalid-generation-zero|invalid-generation-leading-zero|invalid-open-generation|invalid-state|invalid-negative-count|invalid-category|invalid-total|invalid-exit)
                write_assist_diagnostic_state \
                    "$state_path" 1 committed "${baseline_values[@]}" || exit "$?"
                case "$scenario" in
                    invalid-generation-zero)
                        write_assist_diagnostic_state "$state_path" 0 committed "${baseline_values[@]}"
                        ;;
                    invalid-generation-leading-zero)
                        write_assist_diagnostic_state "$state_path" 01 committed "${baseline_values[@]}"
                        ;;
                    invalid-open-generation)
                        write_assist_diagnostic_state \
                            "$state_path" 2 open \
                            0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 unavailable unavailable
                        ;;
                    invalid-state)
                        write_assist_diagnostic_state "$state_path" 1 pending "${baseline_values[@]}"
                        ;;
                    invalid-negative-count)
                        write_assist_diagnostic_state \
                            "$state_path" 1 committed \
                            1 0 0 0 0 0 0 0 0 0 0 0 -1 0 84 84 84 enabled-false 0
                        ;;
                    invalid-category)
                        write_assist_diagnostic_state \
                            "$state_path" 1 committed \
                            1 0 0 0 0 0 0 0 0 0 0 0 1 0 84 84 84 unavailable 0
                        ;;
                    invalid-total)
                        write_assist_diagnostic_state \
                            "$state_path" 1 committed \
                            1 0 0 0 0 0 0 0 0 0 0 0 0 0 84 84 84 enabled-false 0
                        ;;
                    invalid-exit)
                        write_assist_diagnostic_state \
                            "$state_path" 1 committed \
                            1 0 0 0 0 0 0 0 0 0 0 0 1 0 84 84 84 enabled-false 1
                        ;;
                esac
                exit "$?"
                ;;
            baseline)
                write_assist_diagnostic_state \
                    "$state_path" 1 committed "${baseline_values[@]}" || exit "$?"
                case "$mode" in
                    state-fault-chmod)
                        /usr/bin/sed 's#/bin/chmod 0600 "\$temporary_path"#/bin/false#' \
                            "$subject" >"$subject.state-fault"
                        ;;
                    state-fault-write)
                        /usr/bin/sed 's#} >"\$temporary_path" || {#} >"\$temporary_path/" || {#' \
                            "$subject" >"$subject.state-fault"
                        ;;
                    state-fault-move)
                        /usr/bin/sed 's#/bin/mv -f -- "\$temporary_path" "\$state_path"#/bin/false#' \
                            "$subject" >"$subject.state-fault"
                        ;;
                esac
                . "$subject.state-fault"
                write_assist_diagnostic_state \
                    "$state_path" 1 committed "${baseline_values[@]}"
                exit "$?"
                ;;
            *) exit 2 ;;
        esac
        ;;
esac

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
