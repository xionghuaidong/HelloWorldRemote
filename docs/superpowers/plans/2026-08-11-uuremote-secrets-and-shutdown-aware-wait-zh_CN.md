# UU Remote Secrets 与关机感知等待实施计划

[English](2026-08-11-uuremote-secrets-and-shutdown-aware-wait.md) | [简体中文](2026-08-11-uuremote-secrets-and-shutdown-aware-wait-zh_CN.md)

> **供智能体工作者使用：** 必须使用子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，逐项任务实施本计划。步骤使用复选框（`- [ ]`）语法进行跟踪。

**目标：** 仅从 GitHub Actions secret 获取 macOS 账户密码，并让 `Wait connections` 在超时或实际 macOS 关机/重启事件发生时结束。

**架构：** `macos.yml` 仅将 repository secret 注入主机配置，并将等待委托给 `apple.sh`。shell 验证持续时间，将一个专用 Swift/AppKit watcher 编译到私有临时目录，并在活跃 GUI 会话中运行它。只有 subtype 为 `powerOff` 的 `systemDefined` 事件才是提前成功信号。

**技术栈：** GitHub Actions YAML、Bash 3.2、Swift/AppKit、Python `unittest`。

## 全局约束

- secret 名称恰好为 `UUREMOTE_ACCOUNT_PASSWORD`。
- 不再保留明文密码输入、fallback 密码或密码日志输出。
- 同一个 secret 配置 console user、禁用的 root 账户、可用的 login keychain 和 `/etc/kcpassword`。
- 直接 root 登录保持禁用。
- `wait_connections_seconds` 默认为 300，并接受包含端点的 0 到 21000 之间的整数。
- 关机和重启会提前结束；注销、UU 状态、进程状态和网络状态不算作成功的提前完成。
- 现有 debug-level gating 保持不变；level 0 不承担诊断 self-test 开销。
- 按照用户对此临时任务的明确要求，直接在 `main` 上工作。

## 文件结构

- 修改 `.github/workflows/macos.yml`：secret 注入、诊断 watcher self-test 和 production wait 调用。
- 修改 `.github/workflows/apple.sh`：验证、路由、临时编译、GUI 执行和 self-test 路由。
- 创建 `.github/workflows/uuremote-shutdown-wait.swift`：专用 AppKit watcher 和内部 test-event 注入。
- 修改 `tests/test_uuremote_host_bootstrap.py`：secret-scoping 和 missing-secret contract。
- 创建 `tests/test_uuremote_wait.py`：workflow、路由、predicate、验证和 macOS 行为测试。

---

### 任务 1：用 Actions Secret 替换可见密码输入

**文件：**
- 修改：`tests/test_uuremote_host_bootstrap.py:17-46`
- 修改：`.github/workflows/macos.yml:21-56`

**接口：**
- 输入：repository secret `UUREMOTE_ACCOUNT_PASSWORD`。
- 输出：供 `apple.sh configure-host` 使用的同名 step-scoped 环境变量。

- [ ] **步骤 1：用失败的 secret 测试替换旧 password-input 测试**

```python
def test_password_is_not_a_workflow_dispatch_input(self):
    workflow = text(WORKFLOW_PATH)
    inputs = workflow[
        workflow.index("    inputs:\n") : workflow.index("\npermissions:\n")
    ]
    self.assertNotIn("account_password:", inputs)
    self.assertNotIn("john.doe", inputs)

def test_password_secret_is_scoped_masked_and_required(self):
    workflow = text(WORKFLOW_PATH)
    job_env = workflow[
        workflow.index("    env:\n") : workflow.index("\n    steps:\n")
    ]
    self.assertNotIn("UUREMOTE_ACCOUNT_PASSWORD", job_env)
    block = step_block(workflow, "Configure macOS host")
    self.assertIn(
        "UUREMOTE_ACCOUNT_PASSWORD: ${{ secrets.UUREMOTE_ACCOUNT_PASSWORD }}",
        block,
    )
    self.assertIn('if [ -z "${UUREMOTE_ACCOUNT_PASSWORD:-}" ]; then', block)
    self.assertIn("::add-mask::${UUREMOTE_ACCOUNT_PASSWORD}", block)
    self.assertIn(".github/workflows/apple.sh configure-host", block)
    self.assertNotIn("GITHUB_EVENT_PATH", block)
    self.assertNotIn("inputs.account_password", block)
```

- [ ] **步骤 2：运行聚焦测试并验证旧 workflow 失败**

运行：

```bash
python3 -m unittest tests.test_uuremote_host_bootstrap.WorkflowContractTests -v
```

预期：失败表明可见输入仍然存在，而 secret 不存在。

- [ ] **步骤 3：移除输入并仅向主机配置注入 secret**

使用以下精确步骤结构：

```yaml
      - name: Configure macOS host
        shell: bash
        env:
          UUREMOTE_ACCOUNT_PASSWORD: ${{ secrets.UUREMOTE_ACCOUNT_PASSWORD }}
        run: |
            if [ -z "${UUREMOTE_ACCOUNT_PASSWORD:-}" ]; then
                echo "Repository secret UUREMOTE_ACCOUNT_PASSWORD is required" >&2
                exit 2
            fi

            echo "::add-mask::${UUREMOTE_ACCOUNT_PASSWORD}"
            .github/workflows/apple.sh configure-host
            unset UUREMOTE_ACCOUNT_PASSWORD
```

不得将 secret 放入 job-level `env`，也不得保留默认密码。

- [ ] **步骤 4：运行聚焦测试并验证其通过**

运行步骤 2 的命令。预期：所有 `WorkflowContractTests` 均通过。

- [ ] **步骤 5：提交 secret 迁移**

```bash
git add .github/workflows/macos.yml tests/test_uuremote_host_bootstrap.py
git commit -m "security: source macOS password from Actions secret"
```

### 任务 2：定义等待 Contract 和 Shell 路由

**文件：**
- 创建：`tests/test_uuremote_wait.py`
- 修改：`.github/workflows/apple.sh:4-6,982-990`
- 修改：`.github/workflows/macos.yml:125-142`

**接口：**
- 输入：`apple.sh wait-connections <seconds>`，其中整数在 `0...21000` 范围内。
- 输出：值为零时不使用 AppKit 并退出 0；无效输入时退出 2；正值时执行 watcher。

- [ ] **步骤 1：添加失败的 workflow 和 shell-routing 测试**

创建 `tests/test_uuremote_wait.py`：

```python
from pathlib import Path
import platform
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/macos.yml"
SCRIPT_PATH = ROOT / ".github/workflows/apple.sh"
WATCHER_PATH = ROOT / ".github/workflows/uuremote-shutdown-wait.swift"

def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")

def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]

class WaitWorkflowContractTests(unittest.TestCase):
    def test_input_range_debug_gate_and_delegation(self):
        workflow = text(WORKFLOW_PATH)
        self.assertIn("default: 300", workflow)
        self.assertIn("0-21000", workflow)
        block = step_block(workflow, "Wait connections")
        self.assertIn("if: success() && env.UUREMOTE_DEBUG == '0'", block)
        self.assertIn(
            '.github/workflows/apple.sh wait-connections "$wait_seconds"',
            block,
        )
        self.assertNotIn('sleep "$wait_seconds"', block)

class WaitShellContractTests(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), *args], cwd=ROOT,
            text=True, capture_output=True, check=False,
        )

    def test_zero_returns_without_watcher_or_app_preflight(self):
        result = self.run_script("wait-connections", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("disabled (0 seconds)", result.stdout)

    def test_invalid_values_return_two(self):
        for value in ("-1", "21001", "1.5", "text", ""):
            with self.subTest(value=value):
                result = self.run_script("wait-connections", value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("integer in the range 0-21000", result.stderr)

    def test_wait_route_precedes_uuremote_app_preflight(self):
        script = text(SCRIPT_PATH)
        route = 'if [ "$mode" = "wait-connections" ]'
        self.assertLess(
            script.index(route), script.index('if [ ! -d "$APP" ]')
        )
```

- [ ] **步骤 2：运行测试并验证其因缺失路由而失败**

```bash
python3 -m unittest tests.test_uuremote_wait -v
```

预期：workflow、zero、invalid-value 和 routing assertion 失败。

- [ ] **步骤 3：添加验证、零值处理和 preflight 路由**

添加：

```bash
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

run_shutdown_waiter() {
    echo "Shutdown watcher is not available" >&2
    return 1
}

wait_connections() {
    local wait_seconds="${1:-}"
    validate_wait_connections_seconds "$wait_seconds" || return "$?"
    if [ "$wait_seconds" -eq 0 ]; then
        echo "Wait connections disabled (0 seconds)"
        return 0
    fi
    run_shutdown_waiter "$wait_seconds" none
}
```

在 application preflight 前路由：

```bash
if [ "$mode" = "wait-connections" ]; then
    wait_connections "${2:-}"
    exit $?
fi
```

- [ ] **步骤 4：仅用委托替换固定 workflow sleep**

```bash
echo "Waiting connections for $wait_seconds seconds ..."
.github/workflows/apple.sh wait-connections "$wait_seconds"
```

- [ ] **步骤 5：运行任务 2 测试和 Bash 语法检查**

```bash
python3 -m unittest tests.test_uuremote_wait -v
bash -n .github/workflows/apple.sh
```

预期：所有任务 2 测试和语法检查均通过；正值等待仍通过临时 stub 明确失败。

- [ ] **步骤 6：提交等待 contract 和路由**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_uuremote_wait.py
git commit -m "feat: route connection waits through apple script"
```

### 任务 3：实施并对 AppKit Watcher 进行行为测试

**文件：**
- 创建：`.github/workflows/uuremote-shutdown-wait.swift`
- 修改：`.github/workflows/apple.sh` 等待 helper 函数
- 修改：`tests/test_uuremote_wait.py`

**接口：**
- 输入：watcher 参数 `<seconds> [none|ordinary|power-off]`；production 传递 `none`。
- 输出：一行 `WAIT_RESULT=timeout` 或 `WAIT_RESULT=shutdown/restart`，并退出 0。
- 输出：用于 timeout、unrelated-event 和 power-off 场景的 `apple.sh self-test-wait-connections`。

- [ ] **步骤 1：添加失败的 predicate 和 macOS 行为测试**

追加：

```python
class WaitWatcherSourceTests(unittest.TestCase):
    def test_only_exact_power_off_event_finishes_early(self):
        source = text(WATCHER_PATH)
        self.assertIn("event.type == .systemDefined", source)
        self.assertIn("event.subtype == .powerOff", source)
        self.assertNotIn("willPowerOffNotification", source)
        for forbidden in ("UURemote", "uuyc", "NWPathMonitor", "URLSession"):
            self.assertNotIn(forbidden, source)

@unittest.skipUnless(platform.system() == "Darwin", "requires AppKit")
class WaitWatcherBehaviorTests(unittest.TestCase):
    def test_shell_self_test_passes(self):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), "self-test-wait-connections"],
            cwd=ROOT, text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shutdown-aware wait self-test passed", result.stdout)
```

- [ ] **步骤 2：运行测试并验证缺失 Swift 源文件导致失败**

运行任务 2 测试命令。预期：源文件测试报错；非 macOS 上跳过 AppKit 行为。

- [ ] **步骤 3：创建具有精确事件 predicate 的 Swift watcher**

使用以下核心操作实施 `ShutdownWaiter`：

```swift
import AppKit
import Foundation

enum InjectedEvent: String { case none, ordinary; case powerOff = "power-off" }

final class ShutdownWaiter {
    private let seconds: Int
    private let injectedEvent: InjectedEvent
    private var finished = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(seconds: Int, injectedEvent: InjectedEvent) {
        self.seconds = seconds
        self.injectedEvent = injectedEvent
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .systemDefined && event.subtype == .powerOff {
            finish("shutdown/restart")
        }
        return event
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        print("WAIT_RESULT=\(reason)")
        fflush(stdout)
        NSApplication.shared.stop(nil)
        let wake = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0
        )!
        NSApplication.shared.postEvent(wake, atStart: false)
    }

    private func scheduleInjectedEvent(on app: NSApplication) {
        guard injectedEvent != .none else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            [weak self] in
            guard let self else { return }
            let subtype: NSEvent.EventSubtype =
                self.injectedEvent == .powerOff ? .powerOff : .mouseEvent
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, subtype: subtype.rawValue, data1: 0, data2: 0
            )!
            app.postEvent(event, atStart: false)
        }
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in self?.handle(event) ?? event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in _ = self?.handle(event)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            [weak self] in self?.finish("timeout")
        }
        scheduleInjectedEvent(on: app)
        app.run()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 || arguments.count == 2,
      let seconds = Int(arguments[0]),
      (0...21000).contains(seconds)
else {
    fputs("usage: uuremote-shutdown-wait <0-21000> [none|ordinary|power-off]\n", stderr)
    exit(2)
}
let eventText = arguments.count == 2 ? arguments[1] : "none"
guard let injectedEvent = InjectedEvent(rawValue: eventText) else {
    fputs("invalid injected event: \(eventText)\n", stderr)
    exit(2)
}
ShutdownWaiter(seconds: seconds, injectedEvent: injectedEvent).run()
```

injected-event 参数只能通过 shell self-test 触达；production `wait-connections` 始终传递 `none`。

- [ ] **步骤 4：用私有编译和 GUI 执行替换 shell stub**

实施 subshell 函数，以确保 cleanup 始终运行：

```bash
run_shutdown_waiter() (
    set -euo pipefail
    wait_seconds="$1"
    injected_event="${2:-none}"
    script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    watcher_source="$script_dir/uuremote-shutdown-wait.swift"
    build_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uuremote-shutdown-wait.XXXXXX")"
    watcher_binary="$build_dir/uuremote-shutdown-wait"
    /bin/chmod 0700 "$build_dir"
    cleanup_shutdown_waiter() {
        /bin/rm -f -- "$watcher_binary"
        /bin/rmdir "$build_dir" 2>/dev/null || true
    }
    trap cleanup_shutdown_waiter EXIT HUP INT TERM
    /usr/bin/xcrun swiftc -framework AppKit "$watcher_source" -o "$watcher_binary"
    resolve_console_account
    run_as_console_user "$watcher_binary" "$wait_seconds" "$injected_event"
)
```

- [ ] **步骤 5：添加 shell self-test 路由**

添加：

```bash
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
```

在 UU application/debug preflight 前、`self-test-kcpassword` 旁边路由 `self-test-wait-connections`。

- [ ] **步骤 6：在非 macOS 上运行静态测试和 Bash 语法检查**

```bash
python3 -m unittest tests.test_uuremote_wait -v
bash -n .github/workflows/apple.sh
```

预期：source/routing 测试通过，非 macOS 上跳过 AppKit 测试，并且 Bash 语法通过。

- [ ] **步骤 7：提交 watcher 实施**

```bash
git add .github/workflows/apple.sh .github/workflows/uuremote-shutdown-wait.swift tests/test_uuremote_wait.py
git commit -m "feat: stop connection wait on macOS power off"
```

### 任务 4：添加诊断 macOS 覆盖并进行端到端验证

**文件：**
- 修改：`.github/workflows/macos.yml` 中 Checkout 之后的位置
- 修改：`tests/test_uuremote_wait.py`

**接口：**
- 输入：`UUREMOTE_DEBUG` 和 `self-test-wait-connections`。
- 输出：debug level 1–3 下的 AppKit 行为覆盖，且 level 0 没有额外开销。

- [ ] **步骤 1：添加失败的 diagnostic-step contract**

```python
def test_appkit_self_test_is_diagnostic_only(self):
    workflow = text(WORKFLOW_PATH)
    block = step_block(workflow, "Test shutdown-aware wait")
    self.assertIn("if: env.UUREMOTE_DEBUG != '0'", block)
    self.assertIn(".github/workflows/apple.sh self-test-wait-connections", block)
```

- [ ] **步骤 2：运行聚焦测试并验证该步骤不存在**

```bash
python3 -m unittest tests.test_uuremote_wait.WaitWorkflowContractTests.test_appkit_self_test_is_diagnostic_only -v
```

预期：查找缺失步骤时出错。

- [ ] **步骤 3：紧接 Checkout 后添加仅用于诊断的 workflow 步骤**

```yaml
      - name: Test shutdown-aware wait
        if: env.UUREMOTE_DEBUG != '0'
        shell: bash
        run: |
            .github/workflows/apple.sh self-test-wait-connections
```

- [ ] **步骤 4：运行完整本地验证集**

```bash
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

预期：所有非 AppKit 测试通过，非 macOS 上跳过 Darwin 行为测试，并且 syntax/whitespace 检查通过。

- [ ] **步骤 5：配置 repository Actions secret 且不记录其值**

在 GitHub repository Actions secrets 中，使用所有者已批准的临时密码创建或更新 `UUREMOTE_ACCOUNT_PASSWORD`。不得将其值放入命令行、commit、workflow 输入、截图或回复中。

- [ ] **步骤 6：提交并推送诊断覆盖**

```bash
git add .github/workflows/macos.yml tests/test_uuremote_wait.py
git commit -m "test: exercise shutdown watcher on diagnostic runs"
git push origin main
```

- [ ] **步骤 7：分派一次诊断 workflow run**

使用 `debug_level=1` 和 `wait_connections_seconds=0` 运行 `macOS`。`Test shutdown-aware wait` 中预期出现：

```text
WAIT_RESULT=timeout
WAIT_RESULT=timeout
WAIT_RESULT=shutdown/restart
shutdown-aware wait self-test passed
```

完整 workflow 必须成功；如果密码有任何表示，也只能显示为 `***`。

- [ ] **步骤 8：分派默认快速 workflow run**

使用 `debug_level=0` 和 `wait_connections_seconds=5` 运行 `macOS`。预期：

- 跳过 watcher self-test；
- UU 安装和权限配置成功；
- `Wait connections` 在约五秒后打印 `WAIT_RESULT=timeout`；
- 不上传截图 artifact。

- [ ] **步骤 9：执行最终 repository 验证**

```bash
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

预期：测试和语法检查通过，`main...origin/main` 上的工作树干净，并且两个 hash 相匹配。
