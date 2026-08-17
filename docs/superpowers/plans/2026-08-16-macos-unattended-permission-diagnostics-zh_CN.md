# macOS 无人值守权限诊断实施计划

[English](2026-08-16-macos-unattended-permission-diagnostics.md) | [简体中文](2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md)

> **供 agentic worker 使用：** 必需 sub-skill：使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，逐项实施本计划。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 增加永久、安全的诊断，用于识别 macOS `uuyc-cli assist allow on` 未能到达 `enabled=true` 的原因，同时不削弱 fail-closed 权限 gate。

**架构：** 保留 `ensure_assist_allowed` 作为 shell orchestrator。将 child ownership 和 timeout 处理放在 bounded GUI-process boundary 后面，把每个私有 response 转换为一个固定安全类别，并聚合完整的 60 秒窗口。第一次原生 run 是 evidence gate；root-cause fix 必须依据该证据，在后续设计修订和计划中处理。

**技术栈：** Bash 3.2-compatible shell、来自 `/usr/bin/python3` 的 embedded Python 3、GitHub Actions YAML、Python `unittest` 和原生 macOS process/session tools。

## 全局约束

- 只能在现有的隔离 `fix/macos-device-id-readiness` worktree 中工作，并保留无关的用户修改。
- 每个 runtime behavior change 都使用 TDD：观察 RED，实施最小 GREEN，只在测试保持 green 时 refactor。
- 所有 source、test、workflow 和 code-example comments 都使用 English。
- 先更新 English documentation，并在同一 commit 中保持简体中文 counterpart 等义。
- 总 deadline 必须恰好为 60 秒，单次 call cap 必须恰好为 3,000 milliseconds，poll interval 必须恰好为 500 milliseconds。
- 只有 strict JSON 在 deadline 前包含 Boolean `success=true` 和 Boolean `enabled=true` 时才接受成功。
- 成功时打印 `ASSIST_STATE=enabled`；失败时保留 `Could not enable unattended control within 60 seconds` 和 exit `1`。
- 只有 `UUREMOTE_DEBUG` 为 `1`、`2` 或 `3`，且无人值守操作失败时才输出详细字段。
- 本诊断绝不打印或持久化原始 CLI stdout/stderr、custom code、密码、device ID 或其他远程设备连接数据。
- 诊断只写入当前 workflow step 日志；不得加入任何 artifact。
- 不修改 Windows runtime，不削弱 TCC 或其他 operating-system control，不猜测其他 vendor command，也不降级为较弱的 readiness check。
- 原始 response file 和 status file 保持 mode `0600`；分类后清空 response，并通过有界 fail-closed 清理策略尝试删除私有临时文件。
- helper 使用有界 fail-closed 清理策略：`TERM`→`KILL`→回收/PGID 探测，`TERM` grace 最多 500 milliseconds，`KILL`/回收/PGID-probe grace 最多 500 milliseconds。清理最多只能在一次 CLI attempt 之外增加已记录的固定清理宽限；绝不无限等待。
- 仅已确认的 cleanup 以及已确认的 handled-signal blocking 才能发布现有安全的 `timeout` 或 `unavailable` status。signal-block setup 返回 Boolean；callers 将 false value 或注入的 exception 防御性地按 false 处理，同时仍调用 no-throw owned-process cleanup。broad post-owned exception 始终不发布 status。任何未确认 prerequisite 或 cleanup exception 均以 `125` 退出；controller 只输出现有通用失败，后续 normal 或 provisioning operation 不继续。只有现有 `always()` finalization/artifact-upload step 和 hosted-runner teardown 可以执行。原始 assist payload、secrets、device connection data 和新的 `ASSIST_DIAGNOSTIC_*` fields 绝不进入 artifact；这些 fields 只保留在当前 step 日志。现有 sanitized CLI diagnostics 可以由 `always()` artifact step 上传。OS-level 残留可能仍无法确认；不得声称绝对清理。
- 确认清理后才发布现有安全 status。未确认清理或异常不发布最终 status，并以 `125` 退出。
- 当前 GitHub-hosted macOS runner 在 job 失败后的 teardown 属于外部遏制。如果将来采用 reused/self-hosted 执行，该 runner 必须被隔离，且在 operator 确认无残留前不得复用。
- 诊断性 live run 后停止。证据未经 review，且必要时未修订设计前，不实施 root-cause fix。
- 每个 implementation task 结束时进行独立 code-review gate。进入下一 task 前解决全部 Critical 和 Important findings。
- 使用 Conventional Commits。

---

## Review follow-up：deadline checkpoints 和 poll failure

每次 bounded child 返回后，必须先取得可读且符合 grammar 的安全 status。即使 absolute deadline 已过期，缺失或无效 status 也通过 caller 的 generic error fail-closed。完成该 validation 后再读取 monotonic clock。如果 deadline 已过期，将这一次 attempt 分类为 `timeout`/`timeout`，且不信任 child payload；classifier 只能在清空私有文件前保留安全的 byte count。随后在 classifier-record framing 以及 category/exit validation 后再次读取 clock，并在 accounting 和 cleanup 后、输出 `ASSIST_STATE=enabled` 前立即再读一次。任何 checkpoint 的 expiry 都把该 attempt 的 category 和 safe exit 替换为 `timeout`，恰好 accounting 一次，并在不接受 late success 的情况下结束窗口。`wait_uuremote_poll` 的 stderr 必须重定向到 `/dev/null`；非零 poll result 通过现有 outer generic failure fail-closed，且不得 hot-loop。

测试使用三个独立受控的 clock crossing（child 后、record validation 后和 enabled acceptance 前）、移除每个 checkpoint 的 isolated mutation，以及 hostile poll-failure fixture。runner-plan AST parity test 与 semantic-contract mutation 分开，因此每个 semantic mutation 都由 semantic assertion 评估，而不是只因 parity 失败。

---

### Task 1：增加严格的安全 response classifier

**文件：**
- 修改：`.github/workflows/apple.sh:820-915`
- 新建：`tests/macos_assist_allow_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py`

**接口：**
- 输入：response file path、execution state `completed|timeout|unavailable` 和 CLI exit `0..255|unavailable`。
- 输出：`classify_assist_allow_response OUTPUT_PATH EXECUTION_STATE CLI_EXIT`，它恰好写出一条 tab-separated record：`CATEGORY<TAB>RESPONSE_BYTES<TAB>SAFE_EXIT`。
- 类别：`timeout`、`cli-nonzero`、`empty`、`invalid-utf8`、`invalid-json`、`not-object`、`success-missing`、`success-wrong-type`、`success-false`、`enabled-missing`、`enabled-wrong-type`、`enabled-false`、`enabled-true`。

- [ ] **Step 1：编写 failing table-driven classifier tests**

在 `tests/test_uuremote_desktop_finalization.py` 中加入 harness constant 和 test class：

```python
MACOS_ASSIST_ALLOW_HARNESS_PATH = ROOT / "tests/macos_assist_allow_harness.sh"


@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSAssistAllowClassifierTests(unittest.TestCase):
    def run_scenario(self, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_ASSIST_ALLOW_HARNESS_PATH), "classify", scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_every_response_shape_has_one_safe_category(self):
        cases = {
            "timeout": ("timeout", "timeout"),
            "cli-nonzero": ("cli-nonzero", "17"),
            "empty": ("empty", "0"),
            "invalid-utf8": ("invalid-utf8", "0"),
            "invalid-json": ("invalid-json", "0"),
            "not-object": ("not-object", "0"),
            "success-missing": ("success-missing", "0"),
            "success-wrong-type": ("success-wrong-type", "0"),
            "success-false": ("success-false", "0"),
            "enabled-missing": ("enabled-missing", "0"),
            "enabled-wrong-type": ("enabled-wrong-type", "0"),
            "enabled-false": ("enabled-false", "0"),
            "enabled-true": ("enabled-true", "0"),
            "duplicate-key": ("invalid-json", "0"),
            "nan": ("invalid-json", "0"),
        }
        for scenario, (category, safe_exit) in cases.items():
            with self.subTest(scenario=scenario):
                result = self.run_scenario(scenario)
                self.assertEqual(result.returncode, 0, result.stderr)
                fields = result.stdout.strip().split("\t")
                self.assertEqual(fields[0], category)
                self.assertTrue(fields[1].isdigit())
                self.assertEqual(fields[2], safe_exit)
                self.assertEqual(len(fields), 3)

    def test_classifier_never_emits_fixture_values(self):
        result = self.run_scenario("hostile-enabled-false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split("\t", 1)[0], "enabled-false")
        self.assertNotIn("CustomCodeFixture", result.stdout + result.stderr)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
        self.assertNotIn("FORGED_OUTPUT", result.stdout + result.stderr)
```

新建 `tests/macos_assist_allow_harness.sh`。像 `tests/macos_readiness_harness.sh` 一样，从 `apple.sh` 提取 production-function prefix；只有 host 缺少该 absolute path 时才替换 `/usr/bin/python3`；构造每个精确 byte fixture，并调用真实 production classifier。scenario table 必须使用以下 payload：

```bash
case "$scenario" in
    timeout) execution_state=timeout; cli_exit=unavailable; : >"$response_path" ;;
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

classify_assist_allow_response "$response_path" "$execution_state" "$cli_exit"
```

- [ ] **Step 2：运行 classifier tests 并验证 RED**

运行：

```bash
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests -v
```

预期：FAIL，因为 `classify_assist_allow_response` 尚不存在。

- [ ] **Step 3：实施最小 strict classifier**

在 `.github/workflows/apple.sh` 的 `wait_for_uuremote_cli_true_field` 前加入以下 Bash/Python boundary：

```bash
classify_assist_allow_response() {
    local output_path="$1"
    local execution_state="$2"
    local cli_exit="$3"
    local response_bytes

    response_bytes="$(/usr/bin/wc -c <"$output_path" | /usr/bin/tr -d '[:space:]')"
    case "$response_bytes" in
        ''|*[!0-9]*) return 2 ;;
    esac

    case "$execution_state" in
        timeout)
            printf 'timeout\t%s\ttimeout\n' "$response_bytes"
            return 0
            ;;
        unavailable)
            printf 'cli-nonzero\t%s\tunavailable\n' "$response_bytes"
            return 0
            ;;
        completed)
            ;;
        *)
            return 2
            ;;
    esac

    case "$cli_exit" in
        ''|*[!0-9]*) return 2 ;;
    esac
    if [ "$cli_exit" -gt 255 ]; then
        return 2
    fi
    if [ "$cli_exit" -ne 0 ]; then
        printf 'cli-nonzero\t%s\t%s\n' "$response_bytes" "$cli_exit"
        return 0
    fi

    /usr/bin/python3 - "$output_path" "$response_bytes" <<'PYTHON'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
response_bytes = sys.argv[2]
raw = path.read_bytes()

def emit(category):
    print(f"{category}\t{response_bytes}\t0")
    raise SystemExit(0)

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result

def reject_nonstandard_constant(_value):
    raise ValueError

if not raw:
    emit("empty")
try:
    decoded = raw.decode("utf-8")
except UnicodeDecodeError:
    emit("invalid-utf8")
try:
    payload = json.loads(
        decoded,
        object_pairs_hook=reject_duplicate_keys,
        parse_constant=reject_nonstandard_constant,
    )
except (json.JSONDecodeError, ValueError):
    emit("invalid-json")
if not isinstance(payload, dict):
    emit("not-object")
if "success" not in payload:
    emit("success-missing")
if type(payload["success"]) is not bool:
    emit("success-wrong-type")
if payload["success"] is not True:
    emit("success-false")
if "enabled" not in payload:
    emit("enabled-missing")
if type(payload["enabled"]) is not bool:
    emit("enabled-wrong-type")
if payload["enabled"] is not True:
    emit("enabled-false")
emit("enabled-true")
PYTHON
}
```

- [ ] **Step 4：运行 focused 和现有 redaction tests，验证 GREEN**

运行：

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests \
  tests.test_uuremote_desktop_finalization.MacOSDiagnosticRedactionTests -v
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
```

预期：所有 focused tests PASS；两个 shell script 均可解析；不输出 fixture marker。

- [ ] **Step 5：请求独立 review 并 commit**

只 review Task 1 的 strict JSON behavior、one-category output、Bash 3.2 compatibility 和 nonleakage。解决 Critical 与 Important findings，重新运行 Step 4，然后 commit：

```bash
git add .github/workflows/apple.sh tests/macos_assist_allow_harness.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: classify macOS unattended responses"
```

---

### Task 2：增加 bounded GUI child-process boundary

**文件：**
- 修改：`.github/workflows/apple.sh:300-410`
- 修改：`tests/macos_assist_allow_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py`

**接口：**
- 输入：现有 `run_bounded_uuremote_cli_to_file`、已解析的 `console_uid`、output path、safe-status path、timeout milliseconds 和 command arguments。
- 输出：`run_bounded_uuremote_cli_to_file_with_status OUTPUT STATUS TIMEOUT COMMAND...` 和 `run_bounded_gui_cli_to_file OUTPUT STATUS TIMEOUT COMMAND...`。
- Safe status file 恰好包含 `completed:0..255`、`timeout` 或 `unavailable`。

- [ ] **Step 1：增加 failing completed、nonzero 和 hanging-child behavior tests**

扩展 harness，加入 `process completed`、`process nonzero` 和 `process timeout`。timeout fixture 必须把自己的 PID 和 descendant PID 写入 caller-provided files，忽略 `TERM` 并阻塞：

```bash
if [ "${1:-}" = "fixture-hang" ]; then
    printf '%s\n' "$$" >"${2:?}"
    /bin/bash -c 'trap "" TERM; printf "%s\n" "$$" >"$1"; while :; do sleep 1; done' \
        fixture-child "${3:?}" &
    trap '' TERM
    while :; do sleep 1; done
fi
```

增加以下 assertions：

```python
def test_completed_process_records_exact_safe_status(self):
    result = self.run_harness("process", "completed")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(result.stdout, "STATUS=completed:0\n")

def test_nonzero_process_records_exact_safe_status(self):
    result = self.run_harness("process", "nonzero")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(result.stdout, "STATUS=completed:17\n")

def test_hanging_process_group_is_terminated_and_reaped(self):
    started = time.monotonic()
    result = self.run_harness("process", "timeout")
    elapsed = time.monotonic() - started
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertLess(elapsed, 5)
    self.assertEqual(result.stdout, "STATUS=timeout\nPROCESS_GROUP_RELEASED=true\n")
```

- [ ] **Step 2：运行 process tests 并验证 RED**

运行：

```bash
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests -v
```

预期：FAIL，因为 status-aware 和 GUI-bounded functions 尚不存在。

- [ ] **Step 3：把现有 runner refactor 为 status-aware core 和 GUI wrapper**

保留现有 Python subprocess implementation，但增加 safe status-path argument。safe-status publisher 无法发布时返回 `False`。launch 或其他无 owned process 的 failure 可以发布 `unavailable`；一旦需要 owned cleanup，只有确认清理的 branch 可以发布 `timeout` 或 `unavailable`，未确认 cleanup 或 cleanup exception 不发布最终 status，并以 `125` 退出。

```python
def write_status(value):
    try:
        if str(status_path) == os.devnull:
            with open(os.devnull, "w", encoding="ascii") as status:
                status.write(value + "\n")
            return True
        temporary_status_path = status_path.with_name(status_path.name + ".tmp")
        descriptor = os.open(
            temporary_status_path,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as status:
            status.write(value + "\n")
        os.replace(temporary_status_path, status_path)
    except OSError:
        return False
    return True
```

公开以下 Bash wrappers：

```bash
run_bounded_uuremote_cli_to_file_with_status() {
    local output_path="$1"
    local status_path="$2"
    local timeout_milliseconds="$3"
    shift 3

    if ! [[ "$timeout_milliseconds" =~ ^[0-9]+$ ]] ||
        [ "$timeout_milliseconds" -lt 1 ] || [ "$#" -eq 0 ]; then
        return 2
    fi

    /usr/bin/python3 - \
        "$output_path" "$status_path" "$timeout_milliseconds" "$@" <<'PYTHON'
import os
import pathlib
import signal
import subprocess
import sys
import time

output_path = sys.argv[1]
status_path = pathlib.Path(sys.argv[2])
timeout_seconds = int(sys.argv[3]) / 1000
command = sys.argv[4:]

def write_status(value):
    try:
        if str(status_path) == os.devnull:
            with open(os.devnull, "w", encoding="ascii") as status:
                status.write(value + "\n")
            return True
        temporary_status_path = status_path.with_name(status_path.name + ".tmp")
        descriptor = os.open(
            temporary_status_path,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as status:
            status.write(value + "\n")
        os.replace(temporary_status_path, status_path)
    except OSError:
        return False
    return True

class HandledSignal(Exception):
    pass

process = None
process_group_id = None
previous_handlers = {}
previous_signal_mask = None
handled_signals = tuple(
    getattr(signal, name)
    for name in ("SIGINT", "SIGTERM", "SIGHUP")
    if hasattr(signal, name)
)

def signal_process_group(signal_number):
    if os.name == "nt":
        if signal_number == signal.SIGTERM:
            process.terminate()
        else:
            process.kill()
    else:
        os.killpg(process_group_id, signal_number)

def process_group_alive():
    if os.name == "nt":
        return None
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    return True

def cleanup_owned_process():
    cleanup_confirmed = False
    try:
        signal_process_group(signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass

    try:
        group_remains = process_group_alive()
    except OSError:
        group_remains = None

    if group_remains is False:
        return process.poll() is not None

    try:
        signal_process_group(signal.SIGKILL)
    except ProcessLookupError:
        pass
    cleanup_deadline = time.monotonic() + 0.5
    try:
        process.wait(timeout=max(0, cleanup_deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        return False

    if group_remains is None:
        return False
    while time.monotonic() < cleanup_deadline:
        try:
            if not process_group_alive():
                cleanup_confirmed = True
                break
        except OSError:
            break
        time.sleep(0.01)
    else:
        try:
            cleanup_confirmed = not process_group_alive()
        except OSError:
            pass
    return cleanup_confirmed

cleanup_in_progress = False
cleanup_signal_mask = None
owned_cleanup_required = False

def cleanup_owned_process_no_throw():
    try:
        return cleanup_owned_process()
    except Exception:
        return False

def release_owned_process_if_confirmed(cleanup_confirmed):
    global owned_cleanup_required
    if cleanup_confirmed:
        owned_cleanup_required = False
    return cleanup_confirmed

def interrupt_handler(_signum, _frame):
    if cleanup_in_progress:
        return
    raise HandledSignal

def block_handled_signals_for_cleanup():
    global cleanup_signal_mask
    try:
        if os.name != "nt" and hasattr(signal, "pthread_sigmask"):
            cleanup_signal_mask = signal.pthread_sigmask(
                signal.SIG_BLOCK,
                handled_signals,
            )
    except Exception:
        return False
    return True

def cleanup_owned_process_after_signal_block():
    try:
        signal_blocked = block_handled_signals_for_cleanup() is True
    except Exception:
        signal_blocked = False
    cleanup_confirmed = release_owned_process_if_confirmed(
        cleanup_owned_process_no_throw(),
    )
    return signal_blocked and cleanup_confirmed

exit_code = 125

try:
    if os.name != "nt" and hasattr(signal, "pthread_sigmask"):
        previous_signal_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK,
            handled_signals,
        )
    for handled_signal in handled_signals:
        try:
            previous_handlers[handled_signal] = signal.signal(
                handled_signal,
                interrupt_handler,
            )
        except ValueError:
            pass
    output_descriptor = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
        0o600,
    )
    popen_options = {}
    if previous_signal_mask is not None:
        def restore_child_signal_mask():
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        popen_options["preexec_fn"] = restore_child_signal_mask
    with os.fdopen(output_descriptor, "wb") as output:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            **popen_options,
        )
        process_group_id = process.pid
        owned_cleanup_required = True
    if previous_signal_mask is not None:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        previous_signal_mask = None
    try:
        return_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        cleanup_in_progress = True
        if cleanup_owned_process_after_signal_block():
            write_status("timeout")
            exit_code = 124
        else:
            exit_code = 125
    else:
        try:
            group_remains = process_group_alive()
        except OSError:
            group_remains = True
        if group_remains is True:
            cleanup_in_progress = True
            if cleanup_owned_process_after_signal_block():
                write_status("unavailable")
            exit_code = 125
        else:
            safe_return_code = return_code if 0 <= return_code <= 255 else 1
            owned_cleanup_required = False
            write_status(f"completed:{safe_return_code}")
            exit_code = safe_return_code
except HandledSignal:
    cleanup_in_progress = True
    if cleanup_owned_process_after_signal_block():
        write_status("unavailable")
    exit_code = 125
except Exception:
    cleanup_in_progress = True
    cleanup_owned_process_after_signal_block()
    exit_code = 125
finally:
    cleanup_in_progress = True
    if cleanup_signal_mask is not None:
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, cleanup_signal_mask)
        except Exception:
            pass
    elif previous_signal_mask is not None:
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)
        except Exception:
            pass
    for handled_signal, previous_handler in previous_handlers.items():
        try:
            signal.signal(handled_signal, previous_handler)
        except Exception:
            pass

raise SystemExit(exit_code)
PYTHON
}

run_bounded_uuremote_cli_to_file() {
    local output_path="$1"
    local timeout_milliseconds="$2"
    shift 2
    run_bounded_uuremote_cli_to_file_with_status \
        "$output_path" /dev/null "$timeout_milliseconds" "$@"
}

run_bounded_gui_cli_to_file() {
    local output_path="$1"
    local status_path="$2"
    local timeout_milliseconds="$3"
    shift 3
    run_bounded_uuremote_cli_to_file_with_status \
        "$output_path" "$status_path" "$timeout_milliseconds" \
        /usr/bin/sudo /bin/launchctl asuser "$console_uid" \
        /usr/bin/sudo -u "#$console_uid" "$@"
}
```

`/dev/null` branch 直接写入，而不能尝试 atomic replacement。保留所有当前 device-ID runner exit behavior。

- [ ] **Step 4：运行新的 process tests 和现有 bounded-runner regressions**

运行：

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests \
  tests.test_uuremote_desktop_finalization.MacOSReadinessBehaviorTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests -v
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
```

预期：所有 tests PASS；真实 hanging process group 在 harness 返回前消失。

- [ ] **Step 5：请求独立 review 并 commit**

review Task 2 的精确 process ownership、timeout、`TERM`/`KILL`、bounded post-kill waits、atomic safe-status writes、`/dev/null` compatibility、GUI session invocation 和 device-ID behavior preservation。解决 Critical 与 Important findings，重新运行 Step 4，然后 commit：

```bash
git add .github/workflows/apple.sh tests/macos_assist_allow_harness.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: bound macOS unattended CLI calls"
```

---

### Task 3：聚合 60 秒窗口，并输出仅 debug 启用的安全诊断

**文件：**
- 修改：`.github/workflows/apple.sh:860-915, 2489-2500`
- 修改：`tests/macos_assist_allow_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py`

**接口：**
- 输入：Task 1 classifier、Task 2 GUI boundary、`uuremote_now_milliseconds`、`wait_uuremote_poll`、`debug_level`、已安装的 `$CLI` 和已解析的 `console_uid`。
- 输出：`report_assist_allow_diagnostics` 和使用固定 defaults `60`、`3000`、`500` 重写的 `ensure_assist_allowed`。
- 成功输出：helper 恰好输出 `ASSIST_STATE=enabled`。
- 失败输出：只有 debug `1|2|3` 输出完整固定汇总；现有 caller 随后打印现有通用错误。

- [ ] **Step 1：增加 failing aggregation、debug-gate、deadline、cleanup 和 redaction tests**

使用 controlled clock 和 boundary functions 扩展 harness。只 stub time、sleep 和 process execution；调用真实 production classifier、accumulator 和 reporter。增加以下 scenarios：

```text
transient-success: invalid-json, enabled-false, enabled-true before deadline
debug0-failure: enabled-false until deadline
debug1-failure: invalid-json, enabled-false until deadline
debug2-failure: same sequence under debug 2
debug3-failure: same sequence under debug 3
late-success: enabled-true returned after the controlled deadline
internal-invalid-record: boundary supplies a classifier record with an invalid enum
hostile-failure: responses contain custom-code/device-ID/forged-log markers
```

增加使用 exact success/failure contract 的 tests：

```python
def test_transient_failures_then_success_emit_only_success(self):
    result = self.run_harness("aggregate", "transient-success")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(result.stdout, "ASSIST_STATE=enabled\n")

def test_debug_zero_failure_is_generic_only(self):
    result = self.run_harness("aggregate", "debug0-failure")
    self.assertEqual(result.returncode, 1)
    self.assertEqual(result.stdout, "")
    self.assertEqual(
        result.stderr,
        "Could not enable unattended control within 60 seconds\n",
    )

def test_debug_levels_emit_complete_fixed_summary(self):
    field_names = [
        "ASSIST_DIAGNOSTIC_ATTEMPTS",
        "ASSIST_DIAGNOSTIC_TIMEOUT_COUNT",
        "ASSIST_DIAGNOSTIC_CLI_NONZERO_COUNT",
        "ASSIST_DIAGNOSTIC_EMPTY_COUNT",
        "ASSIST_DIAGNOSTIC_INVALID_UTF8_COUNT",
        "ASSIST_DIAGNOSTIC_INVALID_JSON_COUNT",
        "ASSIST_DIAGNOSTIC_NOT_OBJECT_COUNT",
        "ASSIST_DIAGNOSTIC_SUCCESS_MISSING_COUNT",
        "ASSIST_DIAGNOSTIC_SUCCESS_WRONG_TYPE_COUNT",
        "ASSIST_DIAGNOSTIC_SUCCESS_FALSE_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_MISSING_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_WRONG_TYPE_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_FALSE_COUNT",
        "ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT",
        "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MIN",
        "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MAX",
        "ASSIST_DIAGNOSTIC_RESPONSE_BYTES_FINAL",
        "ASSIST_DIAGNOSTIC_FINAL_CATEGORY",
        "ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT",
    ]
    for level in (1, 2, 3):
        result = self.run_harness("aggregate", f"debug{level}-failure")
        self.assertEqual(result.returncode, 1)
        lines = result.stderr.splitlines()
        self.assertEqual([line.split("=", 1)[0] for line in lines[:-1]], field_names)
        self.assertEqual(lines[-1], "Could not enable unattended control within 60 seconds")
        counts = {
            line.split("=", 1)[0]: line.split("=", 1)[1]
            for line in lines[:-1]
        }
        category_total = sum(
            int(value) for key, value in counts.items() if key.endswith("_COUNT")
        )
        self.assertEqual(category_total, int(counts["ASSIST_DIAGNOSTIC_ATTEMPTS"]))

def test_late_success_fails_and_temporary_tree_is_empty(self):
    result = self.run_harness("aggregate", "late-success")
    self.assertEqual(result.returncode, 1)
    self.assertIn("ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=1", result.stderr)
    self.assertIn("TEMPORARY_TREE_EMPTY=true", result.stdout)

def test_hostile_responses_never_reach_logs_or_artifacts(self):
    result = self.run_harness("aggregate", "hostile-failure")
    self.assertEqual(result.returncode, 1)
    combined = result.stdout + result.stderr
    for marker in ("CustomCodeFixture", "device-id-fixture", "FORGED_OUTPUT"):
        self.assertNotIn(marker, combined)
```

增加 workflow/source contract，证明 `UUREMOTE_DEBUG` 仍为 job-scoped、权限 step 只调用 `apple.sh`，且 `ASSIST_DIAGNOSTIC_` token 不会出现在 upload step 或 artifact path construction 中。

- [ ] **Step 2：运行 aggregation suite 并验证 RED**

运行：

```bash
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
```

预期：FAIL，因为 `ensure_assist_allowed` 仍使用 attempt count，而不是 absolute deadline，也不聚合或报告安全字段。

- [ ] **Step 3：使用显式 validation 实施 safe reporter**

使用 exact field order 中的显式 positional integer arguments 实施 `report_assist_allow_diagnostics`。使用 `case "$value" in ''|*[!0-9]*) return 2 ;; esac` 验证每个 count；使用 13 个 allowed enums 验证 final category；在第一个 `printf` 前验证 final exit 为 `timeout|unavailable|0..255`。

按以下方式实施完整 reporter：

```bash
report_assist_allow_diagnostics() {
    [ "$#" -eq 19 ] || return 2
    local attempts="$1" timeout_count="$2" cli_nonzero_count="$3"
    local empty_count="$4" invalid_utf8_count="$5" invalid_json_count="$6"
    local not_object_count="$7" success_missing_count="$8"
    local success_wrong_type_count="$9"
    shift 9
    local success_false_count="$1" enabled_missing_count="$2"
    local enabled_wrong_type_count="$3" enabled_false_count="$4"
    local enabled_true_count="$5" response_bytes_min="$6"
    local response_bytes_max="$7" response_bytes_final="$8"
    local final_category="$9"
    shift 9
    local final_cli_exit="$1" value

    for value in \
        "$attempts" "$timeout_count" "$cli_nonzero_count" "$empty_count" \
        "$invalid_utf8_count" "$invalid_json_count" "$not_object_count" \
        "$success_missing_count" "$success_wrong_type_count" "$success_false_count" \
        "$enabled_missing_count" "$enabled_wrong_type_count" \
        "$enabled_false_count" "$enabled_true_count" \
        "$response_bytes_min" "$response_bytes_max" "$response_bytes_final"
    do
        case "$value" in
            ''|*[!0-9]*) return 2 ;;
        esac
    done
    case "$final_category" in
        timeout|cli-nonzero|empty|invalid-utf8|invalid-json|not-object|\
        success-missing|success-wrong-type|success-false|enabled-missing|\
        enabled-wrong-type|enabled-false|enabled-true)
            ;;
        *) return 2 ;;
    esac
    case "$final_cli_exit" in
        timeout|unavailable) ;;
        ''|*[!0-9]*) return 2 ;;
        *) [ "$final_cli_exit" -le 255 ] || return 2 ;;
    esac

    printf 'ASSIST_DIAGNOSTIC_ATTEMPTS=%s\n' "$attempts"
    printf 'ASSIST_DIAGNOSTIC_TIMEOUT_COUNT=%s\n' "$timeout_count"
    printf 'ASSIST_DIAGNOSTIC_CLI_NONZERO_COUNT=%s\n' "$cli_nonzero_count"
    printf 'ASSIST_DIAGNOSTIC_EMPTY_COUNT=%s\n' "$empty_count"
    printf 'ASSIST_DIAGNOSTIC_INVALID_UTF8_COUNT=%s\n' "$invalid_utf8_count"
    printf 'ASSIST_DIAGNOSTIC_INVALID_JSON_COUNT=%s\n' "$invalid_json_count"
    printf 'ASSIST_DIAGNOSTIC_NOT_OBJECT_COUNT=%s\n' "$not_object_count"
    printf 'ASSIST_DIAGNOSTIC_SUCCESS_MISSING_COUNT=%s\n' "$success_missing_count"
    printf 'ASSIST_DIAGNOSTIC_SUCCESS_WRONG_TYPE_COUNT=%s\n' "$success_wrong_type_count"
    printf 'ASSIST_DIAGNOSTIC_SUCCESS_FALSE_COUNT=%s\n' "$success_false_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_MISSING_COUNT=%s\n' "$enabled_missing_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_WRONG_TYPE_COUNT=%s\n' "$enabled_wrong_type_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_FALSE_COUNT=%s\n' "$enabled_false_count"
    printf 'ASSIST_DIAGNOSTIC_ENABLED_TRUE_COUNT=%s\n' "$enabled_true_count"
    printf 'ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MIN=%s\n' "$response_bytes_min"
    printf 'ASSIST_DIAGNOSTIC_RESPONSE_BYTES_MAX=%s\n' "$response_bytes_max"
    printf 'ASSIST_DIAGNOSTIC_RESPONSE_BYTES_FINAL=%s\n' "$response_bytes_final"
    printf 'ASSIST_DIAGNOSTIC_FINAL_CATEGORY=%s\n' "$final_category"
    printf 'ASSIST_DIAGNOSTIC_FINAL_CLI_EXIT=%s\n' "$final_cli_exit"
}
```

- [ ] **Step 4：围绕一个 monotonic deadline 重写 `ensure_assist_allowed`**

把函数改为 subshell，避免 cleanup trap 泄漏。创建一个私有临时目录，其中包含 mode `0600` 的 `response` 和 `status`。使用 Bash 3.2-compatible scalar counters，不使用 associative arrays。

control flow 必须为：

```bash
ensure_assist_allowed() (
    local deadline now remaining attempt_timeout sleep_timeout record
    local category response_bytes safe_exit extra_field category_total
    local execution_state execution_exit status_record
    local assist_temp_dir="" response_path="" status_path=""
    local attempts=0
    local timeout_count=0 cli_nonzero_count=0 empty_count=0
    local invalid_utf8_count=0 invalid_json_count=0 not_object_count=0
    local success_missing_count=0 success_wrong_type_count=0 success_false_count=0
    local enabled_missing_count=0 enabled_wrong_type_count=0
    local enabled_false_count=0 enabled_true_count=0
    local response_bytes_min="" response_bytes_max=0 response_bytes_final=0
    local final_category=unavailable final_cli_exit=unavailable

    cleanup_assist_attempt() {
        local cleanup_status=0
        if [ -n "$response_path" ]; then
            /bin/rm -f -- "$response_path" || cleanup_status=1
        fi
        if [ -n "$status_path" ]; then
            /bin/rm -f -- "$status_path" "$status_path.tmp" || cleanup_status=1
        fi
        if [ -n "$assist_temp_dir" ]; then
            /bin/rmdir "$assist_temp_dir" 2>/dev/null || cleanup_status=1
        fi
        return "$cleanup_status"
    }

    umask 077
    assist_temp_dir="$(/usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/uuremote-assist-allow.XXXXXX")" || return 1
    trap 'cleanup_assist_attempt || exit 1' EXIT
    /bin/chmod 0700 "$assist_temp_dir" || return 1
    response_path="$assist_temp_dir/response"
    status_path="$assist_temp_dir/status"
    : >"$response_path"
    : >"$status_path"
    /bin/chmod 0600 "$response_path" "$status_path" || return 1

    read_assist_now() {
        now="$(uuremote_now_milliseconds)" || return 1
        case "$now" in
            0) ;;
            [1-9]* ) case "$now" in *[!0-9]*) return 1 ;; esac ;;
            *) return 1 ;;
        esac
    }

    read_assist_now || return 1
    deadline="$((now + 60000))"
    while :; do
        read_assist_now || return 1
        remaining="$((deadline - now))"
        [ "$remaining" -gt 0 ] || break
        attempts="$((attempts + 1))"
        attempt_timeout=3000
        [ "$remaining" -ge "$attempt_timeout" ] || attempt_timeout="$remaining"
        : >"$response_path"
        : >"$status_path"
        run_bounded_gui_cli_to_file \
            "$response_path" "$status_path" "$attempt_timeout" \
            "$CLI" assist allow on >/dev/null 2>/dev/null || true

        status_record="$(/bin/cat "$status_path" 2>/dev/null)" || return 1
        case "$status_record" in
            timeout)
                execution_state=timeout
                execution_exit=unavailable
                ;;
            unavailable)
                execution_state=unavailable
                execution_exit=unavailable
                ;;
            completed:*)
                execution_state=completed
                execution_exit="${status_record#completed:}"
                case "$execution_exit" in
                    ''|*[!0-9]*) return 1 ;;
                esac
                [ "$execution_exit" -le 255 ] || return 1
                ;;
            *)
                return 1
                ;;
        esac

        read_assist_now || return 1
        remaining="$((deadline - now))"
        if [ "$remaining" -le 0 ]; then
            execution_state=timeout
            execution_exit=timeout
        fi

        record="$(classify_assist_allow_response \
            "$response_path" "$execution_state" "$execution_exit")" || return 1
        : >"$response_path"
        IFS=$'\t' read -r category response_bytes safe_exit extra_field <<<"$record"
        [ -z "$extra_field" ] || return 1
        case "$response_bytes" in
            ''|*[!0-9]*) return 1 ;;
        esac
        case "$safe_exit" in
            timeout|unavailable) ;;
            ''|*[!0-9]*) return 1 ;;
            *) [ "$safe_exit" -le 255 ] || return 1 ;;
        esac

        case "$category" in
            timeout) timeout_count="$((timeout_count + 1))" ;;
            cli-nonzero) cli_nonzero_count="$((cli_nonzero_count + 1))" ;;
            empty) empty_count="$((empty_count + 1))" ;;
            invalid-utf8) invalid_utf8_count="$((invalid_utf8_count + 1))" ;;
            invalid-json) invalid_json_count="$((invalid_json_count + 1))" ;;
            not-object) not_object_count="$((not_object_count + 1))" ;;
            success-missing) success_missing_count="$((success_missing_count + 1))" ;;
            success-wrong-type) success_wrong_type_count="$((success_wrong_type_count + 1))" ;;
            success-false) success_false_count="$((success_false_count + 1))" ;;
            enabled-missing) enabled_missing_count="$((enabled_missing_count + 1))" ;;
            enabled-wrong-type) enabled_wrong_type_count="$((enabled_wrong_type_count + 1))" ;;
            enabled-false) enabled_false_count="$((enabled_false_count + 1))" ;;
            enabled-true) enabled_true_count="$((enabled_true_count + 1))" ;;
            *) return 1 ;;
        esac

        if [ "$attempts" -eq 1 ] || [ "$response_bytes" -lt "$response_bytes_min" ]; then
            response_bytes_min="$response_bytes"
        fi
        if [ "$response_bytes" -gt "$response_bytes_max" ]; then
            response_bytes_max="$response_bytes"
        fi
        response_bytes_final="$response_bytes"
        final_category="$category"
        final_cli_exit="$safe_exit"

        if [ "$category" = enabled-true ]; then
            cleanup_assist_attempt || return 1
            read_assist_now || return 1
            remaining="$((deadline - now))"
            if [ "$remaining" -gt 0 ]; then
                trap - EXIT HUP INT TERM
                printf 'ASSIST_STATE=enabled\n'
                return 0
            fi
            enabled_true_count="$((enabled_true_count - 1))"
            timeout_count="$((timeout_count + 1))"
            category=timeout
            safe_exit=timeout
            final_category=timeout
            final_cli_exit=timeout
        fi
        [ "$remaining" -gt 0 ] || break
        sleep_timeout=500
        [ "$remaining" -ge "$sleep_timeout" ] || sleep_timeout="$remaining"
        wait_uuremote_poll "$sleep_timeout" 2>/dev/null || return 1
    done

    [ "$attempts" -gt 0 ] || return 1
    category_total="$((
        timeout_count + cli_nonzero_count + empty_count +
        invalid_utf8_count + invalid_json_count + not_object_count +
        success_missing_count + success_wrong_type_count + success_false_count +
        enabled_missing_count + enabled_wrong_type_count +
        enabled_false_count + enabled_true_count
    ))"
    [ "$category_total" -eq "$attempts" ] || return 1

    if [ "$debug_level" != 0 ]; then
        report_assist_allow_diagnostics \
            "$attempts" "$timeout_count" "$cli_nonzero_count" "$empty_count" \
            "$invalid_utf8_count" "$invalid_json_count" "$not_object_count" \
            "$success_missing_count" "$success_wrong_type_count" "$success_false_count" \
            "$enabled_missing_count" "$enabled_wrong_type_count" \
            "$enabled_false_count" "$enabled_true_count" \
            "$response_bytes_min" "$response_bytes_max" "$response_bytes_final" \
            "$final_category" "$final_cli_exit" >&2 || return 1
    fi
    cleanup_assist_attempt || return 1
    trap - EXIT
    return 1
)
```

使用上面的精确显式 validation 和 counter updates。不得引入 test-only cleanup method，也不得把 production classification 复制到 harness。

- [ ] **Step 5：运行 focused GREEN、mutation RED/GREEN 和完整 local regressions**

运行 focused suite：

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
```

然后只在隔离 copy 中做两个临时 mutation，不修改 worktree source：

1. 把 reporter invocation 移到 debug gate 外；验证 debug-0 test 失败。
2. 在没有 final deadline check 时接受 `enabled-true`；验证 late-success test 失败。

恢复未修改的 worktree，并运行：

```bash
python -m unittest tests.test_uuremote_desktop_finalization tests.test_uuremote_wait -v
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
```

预期：focused 和相关 suites PASS；两个 mutation 都产生预期 RED；shell syntax 和 redaction harnesses PASS。

- [ ] **Step 6：请求独立 review 并 commit**

review Task 3 的 deadline enforcement、exactly-one-category accounting、Bash 3.2 compatibility、late-success rejection、debug gating、fixed output order、response truncation、cleanup、无 artifact write 以及 generic caller failure preservation。解决 Critical 与 Important findings，重新运行 Step 5，然后 commit：

```bash
git add .github/workflows/apple.sh tests/macos_assist_allow_harness.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: diagnose macOS unattended failures"
```

---

### Task 4：验证并 review 完整 diagnostic branch

**文件：**
- 验证：从 `e844ba9..HEAD` 改动的全部文件
- 新建 ignored report：`.superpowers/sdd/2026-08-16-macos-unattended-permission-diagnostics/final-review-report.md`

**接口：**
- 输入：已 commit 的 Tasks 1 到 3。
- 输出：clean、已 review、可以进行明确授权的原生 diagnostic run 的 commit range。

- [ ] **Step 1：运行 fresh focused 和 full verification**

运行：

```bash
python -m unittest \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowProcessTests \
  tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
python -m unittest discover -s tests -v
python -m unittest tests.test_agent_work_environment -v
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
python -m json.tool .claude/settings.json >/dev/null
git diff --check e30a65b..HEAD
```

预期：当前可运行 tests PASS，只有明确的 platform skips；shell 与 JSON parsing 成功；diff check 无输出。

单独运行 native macOS cleanup matrix。对于已确认的 timeout cleanup、leader 已完成但 descendant 仍存活，以及已处理 signal cleanup，要求仅在有界 `TERM`→`KILL`→回收/PGID 探测确认清理后发布现有安全 status。对于相应的 cleanup-injection false/raises case，要求 exit `125`、无最终 status 和 outer caller 只输出其现有通用错误；后续 normal 或 provisioning operation 不继续，只有现有 `always()` finalization/artifact-upload step 和 hosted-runner teardown 可以执行。记录这证明的是有界 helper behavior，而不是 OS-level 残留绝对不存在。

- [ ] **Step 2：运行 security、output 和 scope scans**

对变更的 runtime/test files 运行 fixed-string 和 pattern scans，查找真实 credential material、原始 vendor payload printing、assist diagnostics 中的 device-ID output、包含 `ASSIST_DIAGNOSTIC_` 的 artifact writes、unbounded `assist allow on` 以及 forbidden policy changes。确认 diff 只改变已批准的 helper、focused tests 和双语 design/plan files。

在 ignored report 中记录精确 command 和 output。任何 ambiguous match 都必须 manual review，不能直接 suppress。

- [ ] **Step 3：请求 whole-branch code review**

请独立 reviewer 阅读 approved design、本 plan、完整 `e844ba9..HEAD` diff 和 verification report。reviewer 必须报告 Critical、Important、Minor findings；验证 tests 执行 production decisions；验证有界 fail-closed 清理策略和 native matrix；并明确说明 branch 是否可安全进行 diagnostic live run。

使用 `superpowers:receiving-code-review`、TDD、新 Conventional Commit 和 Steps 1、2 的 fresh rerun 解决 Critical 与 Important findings。重复 review，直到没有 Critical 或 Important finding。

- [ ] **Step 4：验证最终 commit identity 和 clean state**

运行：

```bash
git log -1 --oneline
git status --short
git rev-list --count e844ba9..HEAD
```

预期：report 记录精确 reviewed HEAD，没有 tracked worktree change，diagnostic commit count 符合预期。

---

### Task 5：运行明确授权的原生 diagnostic gate

**文件：**
- 更新 ignored report：`.superpowers/sdd/2026-08-16-macos-unattended-permission-diagnostics/live-report.md`
- 证据收集期间不修改 tracked files。

**接口：**
- 输入：精确 reviewed feature HEAD，以及用户对 push 和 workflow dispatch 的明确授权。
- 输出：一个原生 macOS run URL 和安全 root-cause category summary。本 task 不产生 root-cause fix。

- [ ] **Step 1：停止并请求 external-action authorization**

展示精确 branch、commit SHA、remote repository、workflow 和 inputs。在执行任一 external action 前获得用户明确授权：

```text
push fix/macos-device-id-readiness to origin
dispatch macos.yml with debug_level=1 and wait_connections_seconds=0
```

不得从 plan approval 推断授权。

- [ ] **Step 2：重新验证并 push 精确 reviewed commit**

运行：

```bash
git status --short
git log -1 --format=%H
git push -u origin fix/macos-device-id-readiness
```

预期：tracked status clean，remote branch 更新到精确 reviewed SHA。不得 force-push。

- [ ] **Step 3：dispatch 恰好一次 diagnostic run**

使用 authenticated GitHub Actions interface 或：

```bash
gh workflow run macos.yml \
  --ref fix/macos-device-id-readiness \
  -f debug_level=1 \
  -f wait_connections_seconds=0
```

记录 run URL 和 ID。不得自动 rerun。

- [ ] **Step 4：只检查安全证据并验证 contract**

如果权限 step 失败，验证：

- `CLI_STATUS_STATE=ready` 发生在 assist failure 前；
- 19 个 `ASSIST_DIAGNOSTIC_` fields 各出现恰好一次，并保持固定顺序；
- category counts 总和等于 attempts；
- final category 和 final safe exit 为有效 enums/numbers；
- 现有 generic error 紧跟汇总；
- 不出现原始 JSON、custom code、密码、伪造 fixture token 或无关连接信息；
- 没有 diagnostic artifact 包含新字段。

如果 step 成功，验证只出现 `ASSIST_STATE=enabled`，不出现详细 diagnostic field。

- [ ] **Step 5：记录 root-cause evidence 并停止**

把精确 safe fields、run URL、commit SHA、step outcome 和 cleanup/artifact observations 写入 ignored live report。标记以下结果之一：

```text
PARSER_SHAPE_EVIDENCE
CLI_OR_ENVIRONMENT_EVIDENCE
UNEXPECTED_DIAGNOSTIC_CONTRACT_FAILURE
UNATTENDED_ENABLED
```

然后停止执行并向用户报告证据。如果结果为 `PARSER_SHAPE_EVIDENCE`，使用观察到的 safe shape 返回 TDD，并编写 root-cause-specific plan amendment。对于 `CLI_OR_ENVIRONMENT_EVIDENCE` 或 unexpected contract failure，在提出任何 recovery 前返回 `superpowers:brainstorming`。未经新的已批准 hypothesis 和明确授权，不得 merge、push `main`、删除 branch 或运行另一次 workflow。
