# macOS 设备 ID Readiness 对齐实施计划

[English](2026-08-16-macos-device-id-readiness.md) | [简体中文](2026-08-16-macos-device-id-readiness-zh_CN.md)

> **面向 agentic worker：** 必须使用子 skill：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，逐项执行本计划。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 将启动、单一 60 秒 deadline、bounded 设备 ID 轮询和 fail-closed 输出移入单一 `apple.sh launch-and-wait-device` route，使 macOS UU Remote launch readiness 与 Windows 对齐。

**架构：** `macos.yml` 变为薄委托层。`apple.sh` 保留既有设备 ID parser 与 bounded subprocess boundary，增加可注入的内部 clock/process/sleep functions，并负责完整 readiness state machine；测试只替换这些外部 boundaries，执行真实函数定义。

**技术栈：** GitHub Actions YAML、兼容 Bash 3.2 的 shell、Python 3 standard library、Python `unittest`、PowerShell 5.1/pwsh 兼容性检查、GitHub CLI。

## 全局约束

- Production readiness deadline 精确为 60 秒，poll interval 精确为 500 毫秒。
- 仅当不存在匹配进程时启动 UU Remote；绝不 restart 或替换既有进程。
- 不使用 `gtimeout` 或其他生命周期 timeout 包裹长期运行的 UU Remote 应用。
- 每个 CLI attempt 获得的时间不得超过剩余整体预算；owned hung child 必须被终止并回收。
- 成功 readiness stdout 精确输出一行 `DEVICE_ID=<validated ID>`，并立即精确输出一行 `DEVICE_ID_STATE=ready`。
- 除此之外，device ID 只允许出现在既有 `WAIT_CONNECTIONS DEVICE_ID=<validated ID>` 消息中。
- 账户密码和 `UUREMOTE_CUSTOM_CODE` 继续视为 secret；原始 CLI stdout 与 stderr 继续禁止记录。
- Debug diagnostics 在最终 readiness failure 后最多运行一次，并保持 metadata-only 输出。
- Windows production behavior 保持不变。
- 先写英文文档，并在同一 commit 中更新等义简体中文 counterpart。
- 使用 test-driven development、Conventional Commits、每项实现任务后的 independent review，并在 push 或声明完成前执行 fresh verification。

## 文件映射

- `.github/workflows/apple.sh`：macOS bounded CLI boundary、process launch/probe boundaries、monotonic deadline controller、routing 和 sanitized errors。
- `.github/workflows/macos.yml`：单一 production launch/readiness delegation 与 debug-only failure diagnostics。
- `tests/macos_readiness_harness.sh`：加载真实 readiness functions，仅替换外部 clock/process/CLI/sleep boundaries 的受控 executable harness。
- `tests/test_uuremote_desktop_finalization.py`：macOS workflow structure 与 readiness behavior entry tests。
- `tests/test_macos_device_id_logging.sh`：真实 parser/bounded-process fixtures，包括 hanging-child cleanup 与 unsafe-output non-leakage。
- `tests/test_agent_work_environment.py`：阻止过时 YAML-owned 120-attempt contract 回归的跨文档要求。
- `docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md` 与 `-zh_CN.md`：将较早的 public-log design wording 更新为 helper-owned controller。
- `docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md` 与 `-zh_CN.md`：标记较早 implementation plan wording 已被 2026-08-16 readiness design 取代。

---

### 任务 1：增加由 helper 负责的 readiness controller

**文件：**
- 新建：`tests/macos_readiness_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py`
- 修改：`tests/test_macos_device_id_logging.sh`
- 修改：`.github/workflows/apple.sh:4-9,313-486,2018-2075`

**接口：**
- 输入：`APP`、`CLI`、既有 strict `read_uuremote_device_id` parser，以及既有 Python process-group cleanup logic。
- 输出：`run_bounded_uuremote_cli_to_file <output> <timeout-ms> <command...>`、`read_uuremote_device_id [timeout-ms]`、`emit_current_device_id <readiness|wait> [timeout-ms]`、`uuremote_now_milliseconds`、`test_uuremote_application_running`、`start_uuremote_application`、`wait_uuremote_poll <milliseconds>`、`launch_and_wait_device [timeout-seconds] [poll-milliseconds]`，以及无参数 route `launch-and-wait-device`。

- [ ] **步骤 1：增加 Python behavior entry tests**

在 `tests/test_uuremote_desktop_finalization.py` 中增加 `MACOS_READINESS_HARNESS_PATH` 和 Bash-gated class：

```python
MACOS_READINESS_HARNESS_PATH = ROOT / "tests/macos_readiness_harness.sh"

@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")
class MacOSReadinessBehaviorTests(unittest.TestCase):
    def run_scenario(self, scenario: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(MACOS_READINESS_HARNESS_PATH), scenario],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_absent_application_is_started_once_before_transient_success(self):
        result = self.run_scenario("absent-transient-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "DEVICE_ID=device-id-fixture",
                "DEVICE_ID_STATE=ready",
                "ATTEMPTS=3",
                "STARTS=1",
                "SLEEPS=2",
            ],
        )

    def test_existing_application_is_not_restarted(self):
        result = self.run_scenario("existing-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STARTS=0", result.stdout.splitlines())

    def test_deadline_fails_closed_without_late_attempt_or_sleep(self):
        result = self.run_scenario("deadline")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "UU Remote device readiness timed out after 2 attempts.",
                "ATTEMPTS=2 STARTS=0 SLEEPS=1 TIMEOUTS=1000,600",
            ],
        )

    def test_configuration_and_launch_failures_do_not_poll(self):
        cases = {
            "invalid-timing": (
                "UU Remote readiness timing values are invalid.",
                "ATTEMPTS=0 STARTS=0 SLEEPS=0 TIMEOUTS=",
            ),
            "missing-paths": (
                "UU Remote readiness paths are unavailable.",
                "ATTEMPTS=0 STARTS=0 SLEEPS=0 TIMEOUTS=",
            ),
            "launch-failure": (
                "UU Remote application launch failed.",
                "ATTEMPTS=0 STARTS=1 SLEEPS=0 TIMEOUTS=",
            ),
        }
        for scenario, expected in cases.items():
            with self.subTest(scenario=scenario):
                result = self.run_scenario(scenario)
                self.assertEqual(result.returncode, 1 if scenario != "invalid-timing" else 2)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.splitlines(), list(expected))

class MacOSReadinessSourceTests(unittest.TestCase):
    def test_production_route_uses_fixed_windows_aligned_defaults(self):
        script = text(SCRIPT_PATH)
        route = shell_if_block(
            script,
            'if [ "$mode" = "launch-and-wait-device" ]; then',
        )
        self.assertIn('launch_and_wait_device 60 500', route)
        self.assertIn('/usr/bin/pgrep -x UURemote', script)
        self.assertIn('if [ "$#" -ne 1 ]; then', route)
        self.assertIn('Usage: apple.sh launch-and-wait-device', route)
```

- [ ] **步骤 2：创建 controlled harness 并观察 RED**

创建 `tests/macos_readiness_harness.sh`。只复制 production source 至底部第一个 `if [ "$mode" = "self-test-kcpassword" ]` route 之前的行，追加以下 boundary overrides，并调用真实 `launch_and_wait_device` function。harness 不得复制 readiness decisions：

```bash
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
attempts=0
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
    attempts="$((attempts + 1))"
    if [ -n "$timeouts" ]; then
        timeouts="$timeouts,$2"
    else
        timeouts="$2"
    fi
    case "$scenario" in
        absent-transient-success)
            [ "$attempts" -ge 3 ] || return 1
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
            "$attempts" "$starts" "$sleeps"
        ;;
    deadline)
        printf 'ATTEMPTS=%s STARTS=%s SLEEPS=%s TIMEOUTS=%s\n' \
            "$attempts" "$starts" "$sleeps" "$timeouts" >&2
        ;;
    invalid-timing|missing-paths|launch-failure)
        printf 'ATTEMPTS=%s STARTS=%s SLEEPS=%s TIMEOUTS=%s\n' \
            "$attempts" "$starts" "$sleeps" "$timeouts" >&2
        ;;
esac
exit "$status"
SUBJECT

UUREMOTE_READINESS_FIXTURE_APP="$fixture_app" \
UUREMOTE_READINESS_CLOCK_STATE="$clock_state" \
    /bin/bash "$subject" "${1:?}"
```

使用 file-backed clock index，使 index 可以跨 command-substitution subshell 保留。`absent-transient-success` 两次返回无 ID，并在 attempt 3 输出精确 pair；`existing-success` 报告进程已经运行；`deadline` 提供 clock values `0,0,400,400,1000`、记录 timeouts `1000,600`，并通过精确 counter assertion 暴露任何第三次 attempt 或第二次 sleep。三个 immediate-failure scenarios 不提供 clock value，因此任何 poll 除了导致 counter assertion 失败，还会直接使 harness 失败。

运行：

```bash
/bin/bash tests/macos_readiness_harness.sh absent-transient-success
python -m unittest tests.test_uuremote_desktop_finalization.MacOSReadinessBehaviorTests -v
```

预期：RED，因为 `launch_and_wait_device` 及其 external-boundary functions 尚不存在。

- [ ] **步骤 3：让 bounded CLI timeout 使用毫秒**

修改 boundary signature 与 Python conversion：

```bash
ASSIST_ID_TIMEOUT_MILLISECONDS=3000

run_bounded_uuremote_cli_to_file() {
    local output_path="$1"
    local timeout_milliseconds="$2"
    shift 2

    if ! [[ "$timeout_milliseconds" =~ ^[0-9]+$ ]] ||
        [ "$timeout_milliseconds" -lt 1 ] || [ "$#" -eq 0 ]; then
        return 2
    fi

    /usr/bin/python3 - "$output_path" "$timeout_milliseconds" "$@" <<'PYTHON'
import os
import signal
import subprocess
import sys

output_path = sys.argv[1]
timeout_seconds = int(sys.argv[2]) / 1000
command = sys.argv[3:]
```

保持既有 start-new-session、TERM、0.5 秒 grace、KILL、wait 与 exit normalization code 不变。更新以下命令找到的每个 production caller：

```bash
rg -n "run_bounded_uuremote_cli_to_file" .github/workflows/apple.sh
```

普通 diagnostics 与 status probes 传入 `"$ASSIST_ID_TIMEOUT_MILLISECONDS"`；readiness 传入计算出的剩余毫秒。

- [ ] **步骤 4：将 attempt budget 传入既有 parser**

使用有默认值的 optional parameters，不改变 parser rules：

```bash
read_uuremote_device_id() (
    local timeout_milliseconds="${1:-$ASSIST_ID_TIMEOUT_MILLISECONDS}"
    local device_id_temp_dir=""
    local output_path=""
)

if ! run_bounded_uuremote_cli_to_file \
    "$output_path" "$timeout_milliseconds" "$CLI" assist id
then
    return 1
fi

emit_current_device_id() {
    local context="$1"
    local timeout_milliseconds="${2:-$ASSIST_ID_TIMEOUT_MILLISECONDS}"
    local device_id

    if ! device_id="$(read_uuremote_device_id "$timeout_milliseconds")"; then
        return 1
    fi
}
```

第一个 fragment 替换 `read_uuremote_device_id` 开头的三个 declarations；第二个只替换其既有 bounded-runner call；第三个增加一个 timeout declaration，并且只替换 `emit_current_device_id` 中既有的 `read_uuremote_device_id` command substitution。从 cleanup trap 到 Python parser 的各行，以及完整 readiness/wait `case` 与结尾 `unset device_id`，均保持 byte-for-byte 不变。

- [ ] **步骤 5：实现与 Windows 对齐的 controller**

在 route table 前增加兼容 Bash 3.2 的 boundaries 与 controller：

```bash
uuremote_now_milliseconds() {
    /usr/bin/python3 -c 'import time; print(time.monotonic_ns() // 1000000)'
}

test_uuremote_application_running() {
    /usr/bin/pgrep -x UURemote >/dev/null 2>&1
}

start_uuremote_application() {
    "$APP/Contents/MacOS/UURemote" >/dev/null 2>&1 &
}

wait_uuremote_poll() {
    /usr/bin/python3 - "$1" <<'PYTHON'
import sys
import time
time.sleep(int(sys.argv[1]) / 1000)
PYTHON
}

launch_and_wait_device() {
    local timeout_seconds="${1:-60}"
    local poll_milliseconds="${2:-500}"
    local deadline now remaining timeout_for_attempt sleep_for_attempt
    local attempts=0

    if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] ||
        ! [[ "$poll_milliseconds" =~ ^[0-9]+$ ]] ||
        [ "$timeout_seconds" -lt 1 ] || [ "$poll_milliseconds" -lt 1 ]; then
        echo "UU Remote readiness timing values are invalid." >&2
        return 2
    fi
    if [ ! -x "$APP/Contents/MacOS/UURemote" ] || [ ! -x "$CLI" ]; then
        echo "UU Remote readiness paths are unavailable." >&2
        return 1
    fi
    if ! test_uuremote_application_running; then
        if ! start_uuremote_application; then
            echo "UU Remote application launch failed." >&2
            return 1
        fi
    fi

    now="$(uuremote_now_milliseconds)"
    deadline="$((now + timeout_seconds * 1000))"
    while true; do
        now="$(uuremote_now_milliseconds)"
        remaining="$((deadline - now))"
        if [ "$remaining" -lt 1 ]; then
            break
        fi
        attempts="$((attempts + 1))"
        timeout_for_attempt="$remaining"
        if emit_current_device_id readiness "$timeout_for_attempt"; then
            return 0
        fi
        now="$(uuremote_now_milliseconds)"
        remaining="$((deadline - now))"
        if [ "$remaining" -lt 1 ]; then
            break
        fi
        sleep_for_attempt="$poll_milliseconds"
        if [ "$remaining" -lt "$sleep_for_attempt" ]; then
            sleep_for_attempt="$remaining"
        fi
        wait_uuremote_poll "$sleep_for_attempt"
    done

    echo "UU Remote device readiness timed out after $attempts attempts." >&2
    return 1
}
```

production `launch-and-wait-device` route 通过要求 script argument count 等于一来拒绝额外参数；否则打印 `Usage: apple.sh launch-and-wait-device` 并返回 `2`；合法调用执行 `launch_and_wait_device 60 500`。将其放在 global application/bootstrap preflight 之前，与 early `report-device-id` 和 `wait-connections` routes 的位置相同。

- [ ] **步骤 6：扩展真实 CLI cleanup 与 hostile-output coverage**

在 `tests/test_macos_device_id_logging.sh` 中为新的 millisecond boundary 更新 fixture runner，并保持以下 real routes 可执行：

```bash
assert_bounded_hanging_route 1 report-device-id readiness
assert_bounded_hanging_route 1 wait-connections 0
assert_bounded_hanging_route 0 diagnose-device-id
```

断言每个 hanging child 都在 route 返回后两秒内消失，temp roots 为空，并且 stdout 或 stderr 均不包含 `device-id-fixture`、`FORGED_OUTPUT=true` 或 `custom-code-fixture`。保留全部 strict JSON、invalid UTF-8、multiline、control、Unicode separator 和 mode-`0600` cases。

- [ ] **步骤 7：运行 GREEN 并提交**

在 macOS 上运行：

```bash
/bin/bash tests/macos_readiness_harness.sh absent-transient-success
/bin/bash tests/macos_readiness_harness.sh existing-success
/bin/bash tests/macos_readiness_harness.sh deadline
/bin/bash tests/macos_readiness_harness.sh invalid-timing
/bin/bash tests/macos_readiness_harness.sh missing-paths
/bin/bash tests/macos_readiness_harness.sh launch-failure
/bin/bash tests/test_macos_device_id_logging.sh
/bin/bash -n .github/workflows/apple.sh
python -m unittest tests.test_uuremote_desktop_finalization.MacOSReadinessBehaviorTests -v
```

预期：所有 scenarios 通过，success output 精确且唯一，deadline output 通用，hanging children 不存在，且 Bash syntax 通过。

提交：

```bash
git add .github/workflows/apple.sh tests/macos_readiness_harness.sh tests/test_macos_device_id_logging.sh tests/test_uuremote_desktop_finalization.py
git commit -m "feat: add bounded macOS device readiness"
```

请求 Task 1 independent review。Critical 与 Important findings 归零前不得开始 Task 2。

---

### 任务 2：委托 workflow 并移除过时 readiness 契约

**文件：**
- 修改：`.github/workflows/macos.yml:72-100`
- 修改：`tests/test_uuremote_desktop_finalization.py:35-125`
- 修改：`tests/test_agent_work_environment.py`
- 修改：`docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md:89-97`
- 修改：`docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design-zh_CN.md:89-97`
- 修改：`docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md:562-593`
- 修改：`docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md:562-593`

**接口：**
- 输入：任务 1 的无参数 `apple.sh launch-and-wait-device` route 与不变的 `diagnose-device-id` route。
- 输出：单一 workflow delegation、精确 exit-status propagation、debug-only post-failure diagnostics，以及不存在 active 120-attempt/YAML-owned instruction 的双语 governing documents。

- [ ] **步骤 1：用 RED contracts 替换旧 workflow assertions**

使用以下内容替换 `CustomCodeWorkflowTests` 中的 120-attempt expectations：

```python
def test_launch_delegates_the_complete_readiness_contract_once(self):
    launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
    self.assertEqual(launch.count("apple.sh launch-and-wait-device"), 1)
    for obsolete in (
        "device_id_ready",
        "for ((i=1; i<=120; i++))",
        "apple.sh report-device-id readiness",
        "gtimeout",
        "brew install coreutils",
    ):
        self.assertNotIn(obsolete, launch)

def test_failed_delegation_runs_diagnostics_only_inside_the_debug_gate(self):
    launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
    outer = shell_if_block(
        launch,
        "if .github/workflows/apple.sh launch-and-wait-device",
    )
    debug = shell_if_block(
        outer,
        'if [ "${UUREMOTE_DEBUG:-0}" != "0" ]; then',
    )
    self.assertEqual(outer.count("apple.sh diagnose-device-id || true"), 1)
    self.assertEqual(debug.count("apple.sh diagnose-device-id || true"), 1)
    self.assertIn('exit "$launch_status"', outer)
```

保留既有 mutation test，但修改新的 outer block：将 diagnostic call 移到匹配的 debug `fi` 后；要求 `assert_failed_diagnostic_contract` 拒绝它。

运行：

```bash
python -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests -v
```

预期：RED，因为 YAML 仍负责 launch、`gtimeout`、120 retries 与 readiness state。

- [ ] **步骤 2：增加跨文档 RED contract**

在 `tests/test_agent_work_environment.py` 中读取 2026-08-15 design 与 plan pairs，以及 2026-08-16 design pair。要求每个 active description 包含 `launch-and-wait-device`、`60-second` 或 `60 秒`，以及 `500-millisecond` 或 `500 毫秒`；拒绝 `Preserve 120 attempts`、`保留 120 attempts`，以及将 production polling loop 分配给 `macos.yml` 的语句。

运行：

```bash
python -m unittest tests.test_agent_work_environment -v
```

预期：在较早的双语 design/plan pair 上出现 RED。

- [ ] **步骤 3：使用单一 delegation 替换 YAML-owned loop**

将 Launch GameViewer step body 设为：

```bash
if .github/workflows/apple.sh launch-and-wait-device
then
    :
else
    launch_status="$?"
    if [ "${UUREMOTE_DEBUG:-0}" != "0" ]; then
        .github/workflows/apple.sh diagnose-device-id || true
    fi
    exit "$launch_status"
fi
```

删除 `ls`、`brew install coreutils`、直接 executable launch、`device_id_ready`、120-attempt loop 和最终通用 YAML error。不要改变 step order、debug gates、custom-code handling、unattended-readiness verification、diagnostics、finalization、artifacts 或 wait-connections behavior。

- [ ] **步骤 4：对齐较早双语契约**

先更新英文，再更新等义简体中文 counterparts：

- 在 2026-08-15 design §7.2 中，将“The `Launch GameViewer` polling loop”替换为 `apple.sh launch-and-wait-device` ownership、60 秒整体 deadline、500 毫秒 poll、launch-if-absent behavior 与 persistent application lifetime。
- 在 2026-08-15 plan Task 3 Step 5 中，说明其原 120-attempt YAML composition 已被批准的 2026-08-16 readiness design 取代，并将实现指向本计划。
- 除了将 owner 从 YAML 改为 helper 所需的语法调整外，逐字保持既有 public device-ID、wait、diagnostic、secret 与 parser requirements。

- [ ] **步骤 5：运行 GREEN、双语检查并提交**

运行：

```bash
python -m unittest tests.test_uuremote_desktop_finalization.CustomCodeWorkflowTests tests.test_agent_work_environment -v
/bin/bash -n .github/workflows/apple.sh
git diff --check
```

预期：workflow 与 document contracts 通过；两个 language pairs 保留精确 navigation 与 counterparts；Bash syntax 与 diff check 通过。

提交：

```bash
git add .github/workflows/macos.yml tests/test_uuremote_desktop_finalization.py tests/test_agent_work_environment.py docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design-zh_CN.md docs/superpowers/plans/2026-08-15-device-id-workflow-log-output.md docs/superpowers/plans/2026-08-15-device-id-workflow-log-output-zh_CN.md
git commit -m "feat: delegate macOS device readiness"
```

请求 Task 2 independent review。Critical 与 Important findings 归零前不得开始 Task 3。

---

### 任务 3：验证并 review 完整 feature branch

**文件：**
- 验证：自 `9542924` 后修改的所有文件
- 只写 coordination evidence：`.superpowers/sdd/2026-08-16-macos-device-id-readiness/`（已 ignored；绝不提交）
- 仅为解决已复现 review finding 而修改 tracked files，并在同一 focused commit 中包含其 failing test

**接口：**
- 输入：任务 1-2 commits 与已批准的 2026-08-16 双语 design。
- 输出：fresh local evidence、精确 platform limitations、security scan results，以及 Critical 和 Important findings 均为零的 whole-branch review verdict。

- [ ] **步骤 1：运行 macOS-focused behavior 与 syntax**

在 macOS 上运行：

```bash
/bin/bash tests/macos_readiness_harness.sh absent-transient-success
/bin/bash tests/macos_readiness_harness.sh existing-success
/bin/bash tests/macos_readiness_harness.sh deadline
/bin/bash tests/test_macos_device_id_logging.sh
/bin/bash tests/test_macos_cli_output_redaction.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh
python -m unittest tests.test_uuremote_wait tests.test_uuremote_desktop_finalization -v
```

预期：所有 Bash behavior tests 通过；AppKit-only tests 在 macOS 上运行；output、cleanup、diagnostics 与 workflow contracts 均为 green。

- [ ] **步骤 2：运行 cross-platform regression checks**

运行：

```powershell
python -m unittest tests.test_windows_parity -v
python -m unittest discover -s tests -v
python -m json.tool .claude/settings.json
git diff --check e30a65b..HEAD
git status --short
```

在 Windows 上，在 isolated desktop sandbox 外运行三个真实 PNG tests，并使用 Windows PowerShell 5.1 与 PATH-visible pwsh 解析 `windows.ps1`。预期：所有 runnable tests 通过；仅保留已记录的 `/bin/bash`/AppKit platform skips；JSON、parsers、diff 与 tracked status 均 clean。

- [ ] **步骤 3：运行 security 与 scope scans**

运行：

```powershell
rg -n "UUREMOTE_ACCOUNT_PASSWORD|UUREMOTE_CUSTOM_CODE|assist set-code" .github/workflows tests
rg -n "DEVICE_ID=|WAIT_CONNECTIONS DEVICE_ID=" .github/workflows tests README.md README-zh_CN.md docs/superpowers
git diff --name-only 9542924..HEAD
```

人工分类每个 match。预期：password/custom-code values 绝不打印；device IDs 只出现在已批准 readiness/wait boundaries 与 fixtures/docs；raw CLI output 不出现在 retry/error/diagnostic paths；changed files 与任务 1-2 一致。

- [ ] **步骤 4：请求 whole-branch review**

要求 independent reviewer 对比 `9542924..HEAD` 与两份 2026-08-16 design，执行真实 controller harness 与 hanging-child regression，检查 Bash 3.2 compatibility 和 `if/else` status propagation，并报告 Critical/Important/Minor findings。使用 `superpowers:receiving-code-review` 处理每个 Critical 或 Important finding：先复现 RED，再实现 minimal GREEN，以 focused Conventional Commit 提交并 re-review。只有获得用户明确批准时才能 defer Minor。

- [ ] **步骤 5：运行 verification-before-completion**

最终 review fix 后重新运行步骤 1-3 的每个命令。在 `.superpowers/sdd/2026-08-16-macos-device-id-readiness/final-review-report.md` 中记录精确 test counts、skips、runtime versions、commit SHAs 与任何 host limitation。tracked worktree 不 clean 或 Critical/Important findings 未归零时，不得声明可进行 live validation。

---

### 任务 4：运行 feature-branch 与 main live 验收

**文件：**
- 不计划修改 tracked files
- 只更新 coordination evidence：`.superpowers/sdd/2026-08-16-macos-device-id-readiness/live-report.md`（已 ignored；绝不提交）

**接口：**
- 输入：reviewed feature branch、GitHub CLI authentication、既有 repository secrets，以及 workflow inputs `debug_level=1`、`wait_connections_seconds=0`。
- 输出：一个 accepted feature-branch macOS run、一个 accepted `main` macOS run、已集成的 `main`，以及仅在 main run 为 green 后删除过时 remote backup branches。

- [ ] **步骤 1：推送 reviewed feature branch**

运行：

```powershell
git push -u origin fix/macos-device-id-readiness
```

dispatch 前验证 remote SHA 等于 local `HEAD`。

- [ ] **步骤 2：Dispatch 并检查 feature-branch macOS 验收**

运行：

```powershell
gh workflow run macos.yml --ref fix/macos-device-id-readiness -f debug_level=1 -f wait_connections_seconds=0
$featureSha = git rev-parse HEAD
$featureRun = gh run list --workflow macos.yml --branch fix/macos-device-id-readiness --event workflow_dispatch --limit 10 --json databaseId,headSha,createdAt | ConvertFrom-Json | Where-Object { $_.headSha -eq $featureSha } | Sort-Object createdAt -Descending | Select-Object -First 1
if ($null -eq $featureRun) { throw "Feature workflow run was not discovered." }
gh run watch $featureRun.databaseId --exit-status
gh run view $featureRun.databaseId --log
```

只有 device-ID test module 通过、Launch GameViewer 在 60 秒契约内完成、readiness pair 精确出现一次、workflow 继续通过 launch，并且 logs/artifacts 不包含 custom code、password 或 raw CLI payload 时才接受。如果 GitHub eventual consistency 尚未显示该 run，只按较短间隔重复 read-only `gh run list` assignment。workflow 失败时停止重复 dispatch，保留 branch 与安全 diagnostics，并在下一次 run 前使用 systematic debugging。

- [ ] **步骤 3：完成并集成 branch**

使用 `superpowers:finishing-a-development-branch`。由于已批准设计选择 live acceptance 后 direct integration，先验证 `main` 仍包含 feature base，再在 primary checkout 中 fast-forward：

```powershell
git switch main
git merge --ff-only fix/macos-device-id-readiness
git push origin main
```

不得 force-push。验证 local `main`、`origin/main` 与 reviewed feature SHA 相同。

- [ ] **步骤 4：Dispatch 并检查 main macOS 验收**

运行：

```powershell
gh workflow run macos.yml --ref main -f debug_level=1 -f wait_connections_seconds=0
$mainSha = git rev-parse HEAD
$mainRun = gh run list --workflow macos.yml --branch main --event workflow_dispatch --limit 10 --json databaseId,headSha,createdAt | ConvertFrom-Json | Where-Object { $_.headSha -eq $mainSha } | Sort-Object createdAt -Descending | Select-Object -First 1
if ($null -eq $mainRun) { throw "Main workflow run was not discovered." }
gh run watch $mainRun.databaseId --exit-status
gh run view $mainRun.databaseId --log
```

应用与步骤 2 相同的 acceptance criteria。main run，而不是仅依赖 local tests 或 feature run，才是 release gate。

- [ ] **步骤 5：仅在 main run 为 green 后删除 remote backups**

首先验证精确 remote refs，且其 commits 仍可从 `origin/main` 到达：

```powershell
git fetch origin --prune
git branch -r --contains origin/fix/macos-diagnostic-exit-code
git branch -r --contains origin/codex/windows-macos-functional-parity
git branch -r --contains origin/fix/macos-device-id-readiness
```

三个分支都被 `origin/main` 包含后，只删除以下精确 remote branches：

```powershell
git push origin --delete fix/macos-diagnostic-exit-code
git push origin --delete codex/windows-macos-functional-parity
git push origin --delete fix/macos-device-id-readiness
```

只有确认 `main` clean 且 remote deletions 成功后，才移除 local worktree 与 local feature branch。

- [ ] **步骤 6：最终 handoff**

报告两个 GitHub run links、final `main` SHA、精确 test counts、reviewer verdict、已删除 branch names 与任何 remaining external concern。报告中绝不能包含 custom code 或账户密码。
