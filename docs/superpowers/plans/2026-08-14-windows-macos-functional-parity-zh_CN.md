# Windows 与 macOS 功能对齐实施计划

[English](2026-08-14-windows-macos-functional-parity.md) | [简体中文](2026-08-14-windows-macos-functional-parity-zh_CN.md)

> **供 agentic workers 使用：** 必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，逐项实施本计划。各步骤使用 checkbox（`- [ ]`）跟踪。

**目标：** 在不更改 Windows 账户或操作系统安全策略的前提下，为 Windows UU Remote workflow 提供已批准的 macOS 等价公共 contract、安全自定义码处理、诊断、幂等性和 shutdown-aware wait。

**架构：** GitHub Actions 编排保留在两份 workflow 文件中，平台行为放入独立 helpers。新增 PowerShell Windows helper 和原生 C# shutdown watcher，同时保留现有 Bash/Swift macOS 实现；对齐它们的公共 inputs、debug 语义、结果 tokens 和诊断 artifact。

**技术栈：** GitHub Actions YAML、PowerShell 7、使用 Windows Forms/Win32 messages 的 C#、Bash、Swift/AppKit、Python `unittest`。

## 全局约束

- `debug_level` 是必需 choice，默认值为 `0`，精确 options 为 `0`、`1`、`2`、`3`。
- `wait_connections_seconds` 是必需 number，默认值为 `300`，有效范围包含 `0` 到 `21000` 两端。
- `UUREMOTE_CUSTOM_CODE` 必须是 step-scoped、必需、使用前 mask、绝不记录，并且只在匹配 `^[A-Za-z0-9]{8,16}$` 时有效。
- Windows 不得消费 `UUREMOTE_ACCOUNT_PASSWORD`，也不得更改用户、Administrator、autologin、UAC、firewall、SSH 或账户策略。
- 不得虚构 Windows 版 `assist allow on`；只使用已安装 CLI 能证明存在的能力。
- Debug levels 采用累积语义：`0` 生产等待、`1` 最终诊断、`2` 幂等性、`3` 幂等性加上每 15 秒一次、共 20 次的 live samples。
- 两个平台都使用 artifact 名称 `uuremote-diagnostics`；debug level `0` 不创建也不上传诊断 artifact。
- Wait results 必须精确为 `WAIT_RESULT=timeout` 和 `WAIT_RESULT=shutdown/restart`。
- Runtime retries 必须有边界；device-ID readiness deadline 为 60 秒。
- Automated tests 可以断言 machine-readable YAML structure。PowerShell 与 C# behavior tests 必须执行真实 helper 或 watcher，并断言 outputs、exit codes 或 filesystem effects；不得把 private source tokens 当作 behavior proxy。
- 无法在本地 host 安全执行的 native GUI 细节由聚焦 code review 和 live-validation matrix 验证，不使用 source-text change detectors。
- 所有 source、workflow、configuration 和 test comments 使用英文。
- 先更新英文文档，并在同一 commit 中保持简体中文 counterpart 含义等价。
- 每项 runtime 行为变更都使用 red-green-refactor，并采用 Conventional Commits。

## 文件结构

- `.github/workflows/windows.yml`：Windows 编排、inputs、conditions 和 step-scoped secret 注入。
- `.github/workflows/windows.ps1`：Windows 验证、readiness、自定义码、诊断、幂等性和 wait 编排。
- `.github/workflows/uuremote-shutdown-wait.cs`：用于 Windows shutdown/restart 观察的原生隐藏窗口 message loop。
- `.github/workflows/macos.yml`：现有 macOS 编排，采用对齐后的公共 artifact 和敏感输出策略。
- `.github/workflows/apple.sh`：现有 macOS 实现，采用对齐后的诊断目录。
- `tests/test_windows_parity.py`：跨 workflow、Windows helper/watcher contracts 和 Windows behavior tests。
- `tests/windows_helper_harness.ps1`：受控 external-boundary harness，通过 dot-source 真实 Windows helper，在不安装或启动 UU Remote 的情况下测试有边界 readiness。
- `tests/test_uuremote_desktop_finalization.py`：macOS artifact、敏感输出 contract 更新及 Bash platform gates。
- `tests/test_uuremote_host_bootstrap.py`：Bash-only behavior platform gate。
- `tests/test_uuremote_wait.py`：Bash-only behavior platform gate 和共享 wait-result assertions。
- `README.md` 与 `README-zh_CN.md`：当前对齐后的 workflow contract 和验证说明。

---

### Task 1：对齐 Windows dispatch 和 secret contract

**文件：**
- 创建：`tests/test_windows_parity.py`
- 修改：`.github/workflows/windows.yml`

**接口：**
- 输入：现有 Windows installer、launcher path、CLI path，以及当前 `--device-id` 和 `--reset-custom-code` commands。
- 输出：匹配的 dispatch inputs、job-level `UUREMOTE_DEBUG` 和 `UUREMOTE_WAIT_CONNECTIONS_SECONDS`，以及独立的 step-scoped 自定义码步骤，后续 tasks 会将其委派给 `windows.ps1`。

- [ ] **步骤 1：编写失败的 workflow contract tests**

创建读取两份 workflows 并提取具名 step 的 helpers：

```python
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MACOS_WORKFLOW = ROOT / ".github/workflows/macos.yml"
WINDOWS_WORKFLOW = ROOT / ".github/workflows/windows.yml"


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]


class SharedWorkflowContractTests(unittest.TestCase):
    def test_windows_exposes_the_shared_dispatch_inputs(self):
        workflow = text(WINDOWS_WORKFLOW)
        self.assertIn("      debug_level:\n", workflow)
        self.assertIn('        default: "0"\n', workflow)
        for value in ('          - "0"', '          - "1"', '          - "2"', '          - "3"'):
            self.assertIn(value, workflow)
        self.assertIn("      wait_connections_seconds:\n", workflow)
        self.assertIn("        default: 300\n", workflow)
        self.assertIn("0-21000", workflow)

    def test_windows_custom_code_is_required_masked_and_step_scoped(self):
        workflow = text(WINDOWS_WORKFLOW)
        job_environment = workflow[workflow.index("    env:\n"):workflow.index("\n    steps:\n")]
        block = step_block(workflow, "Configure UU Remote custom code")
        self.assertNotIn("UUREMOTE_CUSTOM_CODE", job_environment)
        self.assertIn("UUREMOTE_CUSTOM_CODE: ${{ secrets.UUREMOTE_CUSTOM_CODE }}", block)
        self.assertIn("::add-mask::$env:UUREMOTE_CUSTOM_CODE", block)
        self.assertNotIn("johnDOE123", workflow)
```

- [ ] **步骤 2：运行聚焦测试并观察 RED**

```powershell
python -m unittest tests.test_windows_parity.SharedWorkflowContractTests -v
```

预期：两项测试失败，因为 Windows 没有 inputs 或 step-scoped secret，并且仍包含旧 literal。

- [ ] **步骤 3：实施最小可工作 workflow contract**

添加与 macOS 相同的 input definitions 和 job environment。把自定义码设置从 `Launch GameViewer` 移到 `Configure UU Remote custom code`。该步骤必须验证存在性、mask 值、通过 variable 调用现有 CLI、抑制 CLI 输出、检查 `$LASTEXITCODE`，然后删除环境变量：

```powershell
if ([string]::IsNullOrWhiteSpace($env:UUREMOTE_CUSTOM_CODE)) {
    throw "Repository secret UUREMOTE_CUSTOM_CODE is required"
}
Write-Output "::add-mask::$env:UUREMOTE_CUSTOM_CODE"
$null = & $cliPath --reset-custom-code $env:UUREMOTE_CUSTOM_CODE 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "UU Remote custom-code configuration failed"
}
Remove-Item Env:\UUREMOTE_CUSTOM_CODE -ErrorAction SilentlyContinue
Write-Host "UU Remote custom code configured"
```

从 launch loop 删除固定 sleep。添加只在 debug level `0` 执行的临时 `Wait connections` step；在 `Start-Sleep` 前验证整数范围。Task 3 会用 watcher helper 替换该临时等待。

- [ ] **步骤 4：运行聚焦和安全检查并观察 GREEN**

```powershell
python -m unittest tests.test_windows_parity.SharedWorkflowContractTests -v
rg -n --fixed-strings "johnDOE123" .github tests README.md README-zh_CN.md
```

预期：测试通过；`rg` 只能命中 test 中刻意保留的 negative assertion，不得命中 workflow。

- [ ] **步骤 5：提交**

```powershell
git add .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: align Windows workflow interface"
```

---

### Task 2：新增 Windows validation 与安全自定义码 helper modes

**文件：**
- 创建：`.github/workflows/windows.ps1`
- 修改：`.github/workflows/windows.yml`
- 修改：`tests/test_windows_parity.py`

**接口：**
- 输入：位置参数 0 的 mode、其余 string arguments、`UUREMOTE_CUSTOM_CODE`，以及固定 install root `C:\Program Files\Netease\GameViewer`。
- 输出：`Test-UURemoteCustomCode`、`Test-WaitSeconds`、`Get-UURemotePaths`、`Set-UURemoteCustomCode`，以及 `validate-custom-code`、`validate-wait-seconds`、`set-custom-code` script modes。

- [ ] **步骤 1：编写失败的 helper behavior tests**

添加 subprocess helper 和 behavior tests。测试只使用示例值，不得包含真实 secret：

```python
import os
import subprocess

WINDOWS_HELPER = ROOT / ".github/workflows/windows.ps1"


def run_windows_helper(mode: str, *args: str, environment: dict[str, str] | None = None):
    return subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(WINDOWS_HELPER), mode, *args],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


class WindowsValidationBehaviorTests(unittest.TestCase):
    def test_custom_code_accepts_only_ascii_alphanumeric_8_through_16(self):
        for value in ("Abcdef12", "12345678", "A1b2C3d4E5f6G7h8"):
            environment = os.environ.copy()
            environment["UUREMOTE_CUSTOM_CODE"] = value
            self.assertEqual(run_windows_helper("validate-custom-code", environment=environment).returncode, 0)

    def test_invalid_custom_code_returns_two_without_echoing_the_value(self):
        for value in ("", "Abc1234", "A" * 17, "Abcd-123", "Abcd 123"):
            environment = os.environ.copy()
            environment["UUREMOTE_CUSTOM_CODE"] = value
            result = run_windows_helper("validate-custom-code", environment=environment)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn(value, result.stdout + result.stderr) if value else None

    def test_wait_validation_accepts_bounds_and_rejects_invalid_values(self):
        for value in ("0", "300", "21000"):
            self.assertEqual(run_windows_helper("validate-wait-seconds", value).returncode, 0)
        for value in ("-1", "21001", "1.5", "text", ""):
            self.assertEqual(run_windows_helper("validate-wait-seconds", value).returncode, 2)
```

- [ ] **步骤 2：运行 tests 并观察 RED**

```powershell
python -m unittest tests.test_windows_parity.WindowsValidationBehaviorTests -v
```

预期：由于 `windows.ps1` 不存在而 error 或 failure。

- [ ] **步骤 3：实施 validation 与 custom-code modes**

使用以下 param block、strict mode 和基础 functions：

```powershell
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mode = "configure",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-UURemoteCustomCode([string]$Value) {
    return $null -ne $Value -and $Value -cmatch '^[A-Za-z0-9]{8,16}$'
}

function Test-WaitSeconds([string]$Value) {
    if ($Value -notmatch '^\d+$') { return $false }
    $parsed = 0
    return [int]::TryParse($Value, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 21000
}

function Get-UURemotePaths {
    $root = 'C:\Program Files\Netease\GameViewer'
    [pscustomobject]@{
        InstallRoot = $root
        LauncherPath = Join-Path $root 'GameViewer.exe'
        CliPath = Join-Path $root 'bin\uuyc-cli.exe'
    }
}
```

`Set-UURemoteCustomCode` 验证环境值、验证 CLI path、调用 `--reset-custom-code`、丢弃 command output、检查 exit code，并且只输出 `CUSTOM_CODE_STATE=configured`。每个 validation route 显式退出 `0` 或 `2`。未知 mode 使用通用 usage error 退出 `2`。

更新 workflow 自定义码步骤，依次调用 `validate-custom-code` 和 `set-custom-code`，然后删除环境变量。

- [ ] **步骤 4：运行聚焦 tests 和 syntax checks 并观察 GREEN**

```powershell
python -m unittest tests.test_windows_parity.WindowsValidationBehaviorTests -v
pwsh -NoProfile -Command '$errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile(".github/workflows/windows.ps1", [ref]$null, [ref]$errors); if ($errors) { $errors; exit 1 }'
```

预期：全部 tests 通过，parser 退出 `0`。

- [ ] **步骤 5：提交**

```powershell
git add .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: secure Windows UU Remote custom code"
```

---

### Task 3：实施原生 Windows shutdown-aware wait

**文件：**
- 创建：`.github/workflows/uuremote-shutdown-wait.cs`
- 修改：`.github/workflows/windows.ps1`
- 修改：`.github/workflows/windows.yml`
- 修改：`tests/test_windows_parity.py`

**接口：**
- 输入：`ShutdownWaiter.Run(int seconds, string injectedEvent)`，injected values 为 `none`、`ordinary` 和 `shutdown`。
- 输出：精确 strings `WAIT_RESULT=timeout` 和 `WAIT_RESULT=shutdown/restart`；helper modes `self-test-wait-connections` 与 `wait-connections SECONDS`。

- [ ] **步骤 1：编写失败的 wait behavior tests**

添加要求 `WM_QUERYENDSESSION`、不取消关机、zero fast path 和 injected self-test 的 tests：

```python
class WindowsWaitBehaviorTests(unittest.TestCase):
    def test_zero_wait_returns_without_loading_the_watcher(self):
        result = run_windows_helper("wait-connections", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WAIT_RESULT=timeout", result.stdout)

    def test_injected_wait_self_test_passes(self):
        result = run_windows_helper("self-test-wait-connections")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shutdown-aware wait self-test passed", result.stdout)
```

- [ ] **步骤 2：运行 wait tests 并观察 RED**

```powershell
python -m unittest tests.test_windows_parity.WindowsWaitBehaviorTests -v
```

预期：可执行 wait modes 不存在，因此失败。

- [ ] **步骤 3：实施 watcher 与 helper orchestration**

实施 namespace `UURemote` 和 public static class `ShutdownWaiter`。内部 `NativeWindow` 创建隐藏的 top-level handle，处理 `WM_QUERYENDSESSION = 0x0011`，记录 `shutdown/restart`，设置 `m.Result = new IntPtr(1)`，并退出 Windows Forms message loop，但不取消关机。Forms timer 在 `seconds` 后记录 `timeout`。Injected `ordinary` 发布 private no-op message；injected `shutdown` 向 watcher handle 发布 `WM_QUERYENDSESSION`。

公共 method 使用以下精确 C# signature 与 argument validation：

```csharp
public static string Run(int seconds, string injectedEvent)
{
    if (seconds < 1) throw new ArgumentOutOfRangeException(nameof(seconds));
    if (injectedEvent != "none" && injectedEvent != "ordinary" && injectedEvent != "shutdown")
        throw new ArgumentException("Unsupported injected event", nameof(injectedEvent));
    using (var context = new WaitContext(seconds, injectedEvent))
    {
        Application.Run(context);
        return context.Result;
    }
}
```

PowerShell 只在验证 positive wait 后使用 `Add-Type -Path` 加载 source。Zero 直接返回 `WAIT_RESULT=timeout`。Watcher invocation 位于 `try/finally`，清理 helper 拥有的 resources。Self-test 使用以下三个精确结果检查：

```powershell
$timeout = Invoke-ShutdownWaiter -Seconds 1 -InjectedEvent 'none'
$ordinary = Invoke-ShutdownWaiter -Seconds 1 -InjectedEvent 'ordinary'
$shutdown = Invoke-ShutdownWaiter -Seconds 2 -InjectedEvent 'shutdown'
if ($timeout -ne 'WAIT_RESULT=timeout' -or
    $ordinary -ne 'WAIT_RESULT=timeout' -or
    $shutdown -ne 'WAIT_RESULT=shutdown/restart') {
    throw 'shutdown-aware wait self-test failed'
}
Write-Output 'shutdown-aware wait self-test passed'
```

用 `windows.ps1 wait-connections "$env:UUREMOTE_WAIT_CONNECTIONS_SECONDS"` 替换临时 workflow sleep，并在安装前添加 diagnostic-only self-test。

- [ ] **步骤 4：运行 behavior 与 contract tests 并观察 GREEN**

```powershell
python -m unittest tests.test_windows_parity.WindowsWaitBehaviorTests tests.test_windows_parity.WindowsValidationBehaviorTests -v
```

预期：所有 tests 在大约四秒内通过，不执行真实关机。

- [ ] **步骤 5：提交**

```powershell
git add .github/workflows/uuremote-shutdown-wait.cs .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: add Windows shutdown-aware wait"
```

---

### Task 4：将 launch 与 unattended-readiness checks 移入 helper

**文件：**
- 修改：`.github/workflows/windows.ps1`
- 修改：`.github/workflows/windows.yml`
- 修改：`tests/test_windows_parity.py`
- 创建：`tests/windows_helper_harness.ps1`

**接口：**
- 输入：`Get-UURemotePaths`、已安装 `GameViewer.exe`、已安装 `uuyc-cli.exe` 和 60 秒 deadline。
- 输出：`Get-UURemoteDeviceId`、`Start-UURemoteAndWaitDevice`、`Assert-UURemoteReadiness`、modes `launch-and-wait-device` 与 `verify-unattended-readiness`、在 debug levels `0`、`1`、`2` 和 `3` 的获批准 readiness output：`DEVICE_ID=<完整 device ID>`，紧接着打印 `DEVICE_ID_STATE=ready`，以及 `UNATTENDED_READINESS=verified`。

- [ ] **步骤 1：编写失败的 bounded-readiness behavior tests**

添加要求 60 秒 deadline、500 ms interval、获批准的 device-ID readiness output 和正确 workflow 顺序的 tests：

```python
class WindowsReadinessContractTests(unittest.TestCase):
    def test_workflow_delegates_launch_and_readiness(self):
        workflow = text(WINDOWS_WORKFLOW)
        launch = step_block(workflow, "Launch GameViewer")
        readiness = step_block(workflow, "Verify unattended readiness")
        self.assertIn("windows.ps1 launch-and-wait-device", launch)
        self.assertIn("windows.ps1 verify-unattended-readiness", readiness)
        self.assertLess(workflow.index("Launch GameViewer"), workflow.index("Configure UU Remote custom code"))
        self.assertLess(workflow.index("Configure UU Remote custom code"), workflow.index("Verify unattended readiness"))


class WindowsReadinessBehaviorTests(unittest.TestCase):
    def run_harness(self, mode: str):
        return subprocess.run(
            ["pwsh", "-NoProfile", "-File", str(ROOT / "tests/windows_helper_harness.ps1"), mode],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_readiness_retries_transient_failures_and_reports_the_device_id_after_success(self):
        result = self.run_harness("readiness-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [line for line in result.stdout.splitlines() if line.startswith("DEVICE_ID")],
            ["DEVICE_ID=device-id-fixture", "DEVICE_ID_STATE=ready"],
        )
        self.assertIn("ATTEMPTS=3", result.stdout)

    def test_readiness_timeout_is_bounded_and_sanitized(self):
        result = self.run_harness("readiness-timeout")
        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_invalid_device_id_output_fails_closed_without_raw_output(self):
        for mode, unsafe_output in (
            ("readiness-empty", ""),
            ("readiness-multiline", "FORGED_OUTPUT=true"),
            ("readiness-nul", "device\x00id"),
            ("readiness-c0", "device\tid"),
            ("readiness-del", "device\x7fid"),
            ("readiness-cli-failure", "raw-cli-device-output"),
        ):
            with self.subTest(mode=mode):
                result = self.run_harness(mode)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertNotEqual(result.stderr.strip(), "")
                if unsafe_output:
                    self.assertNotIn(unsafe_output, result.stdout + result.stderr)
```

- [ ] **步骤 2：运行 readiness tests 并观察 RED**

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessContractTests tests.test_windows_parity.WindowsReadinessBehaviorTests -v
```

预期：launch logic 仍为 inline，helper modes 不存在，因此失败。

- [ ] **步骤 3：实施有边界的 readiness**

`Get-UURemoteDeviceId` 调用 `--device-id`，仅在 CLI 退出 zero 时返回 trimmed non-empty string，且绝不输出原始 CLI output。修剪后，成功的 device ID 必须是一个非空可打印行。在记录前拒绝 CR、LF、NUL、所有其他 C0 control character 和 DEL。`Start-UURemoteAndWaitDevice` 接受内部 parameters `TimeoutSeconds = 60` 和 `PollMilliseconds = 500`，验证两条 paths，复用 `Get-Process -Name GameViewer`；否则启动 launcher，并轮询到 deadline。Runtime route 始终使用 defaults。每次在 debug levels `0`、`1`、`2` 和 `3` 成功 run 都会打印 `DEVICE_ID=<完整 device ID>`，紧接着打印 `DEVICE_ID_STATE=ready`；validation failure 必须 fail closed，并返回通用 readiness 或 device-ID validation error，且不输出原始不安全 output。

Harness 通过 dot-source 加载真实 helper 但不执行 route，只把 external process/CLI boundaries 替换为 deterministic functions，并使用 `TimeoutSeconds = 1`、`PollMilliseconds = 10` 调用 `Start-UURemoteAndWaitDevice`。`readiness-success` 只在 attempt 3 返回 fixture 并输出 `ATTEMPTS=3`；`readiness-timeout` 永不返回 ID，并退出 `1`。空值、multiline、NUL、C0-control、DEL 和 failed-CLI fixtures 都以通用 error 退出 `1`，且 stdout 和 stderr 不包含其不安全 raw output。Harness 不得复制 readiness logic。

`Assert-UURemoteReadiness` 验证 launcher 和 CLI paths、要求正在运行的 `GameViewer` process，并要求 `Get-UURemoteDeviceId` 返回非空。它只输出 `UNATTENDED_READINESS=verified`，不得调用未公开命令或修改系统安全设置。

用 helper mode 替换 inline launch loop，并在自定义码配置后增加具名 readiness step。

- [ ] **步骤 4：运行聚焦 tests 并观察 GREEN**

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessContractTests tests.test_windows_parity.WindowsReadinessBehaviorTests tests.test_windows_parity.SharedWorkflowContractTests -v
```

预期：所有 tests 通过；每个 debug level 的成功 readiness 输出 `DEVICE_ID=device-id-fixture`，紧接着输出 `DEVICE_ID_STATE=ready`，而无效值和失败尝试必须 fail closed，且不输出原始 output。

- [ ] **步骤 5：提交**

```powershell
git add .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py tests/windows_helper_harness.ps1
git commit -m "feat: add bounded Windows readiness checks"
```

---

### Task 5：新增 Windows desktop finalization、diagnostics 与 idempotency

**文件：**
- 修改：`.github/workflows/windows.ps1`
- 修改：`.github/workflows/windows.yml`
- 修改：`tests/test_windows_parity.py`

**接口：**
- 输入：`${RUNNER_TEMP}`、`UUREMOTE_DEBUG`、step-scoped `UUREMOTE_CUSTOM_CODE` 以及 readiness/custom-code functions。
- 输出：`Minimize-UURemoteWindows`、`Save-DesktopSnapshot`、`Invoke-UURemoteIdempotencyCheck`、modes `finalize-desktop`、`snapshot LABEL`、`verify-idempotency`，以及 `FINAL_DESKTOP_STATE=ready`。

- [ ] **步骤 1：编写失败的 diagnostic 与 idempotency contracts**

添加要求精确 debug gates、公共 artifact、runner temp path，并确保 snapshot function 不启动或 foreground UU Remote 的 tests：

```python
import platform
import tempfile


class WindowsDiagnosticContractTests(unittest.TestCase):
    def test_debug_conditions_and_artifact_are_aligned(self):
        workflow = text(WINDOWS_WORKFLOW)
        self.assertIn("env.UUREMOTE_DEBUG == '2' || env.UUREMOTE_DEBUG == '3'", step_block(workflow, "Verify configuration idempotency"))
        self.assertIn("env.UUREMOTE_DEBUG == '3'", step_block(workflow, "Capture live diagnostics"))
        upload = step_block(workflow, "Upload UU Remote diagnostics")
        self.assertIn("always() && env.UUREMOTE_DEBUG != '0'", upload)
        self.assertIn("name: uuremote-diagnostics", upload)
        self.assertIn("${{ runner.temp }}/uuremote-diagnostics/", upload)



@unittest.skipUnless(platform.system() == "Windows", "requires a Windows desktop")
class WindowsDiagnosticBehaviorTests(unittest.TestCase):
    def test_snapshot_writes_a_real_png_under_runner_temp(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = directory
            result = run_windows_helper("snapshot", "contract-test", environment=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            image = Path(directory, "uuremote-diagnostics", "contract-test.png")
            self.assertTrue(image.is_file())
            self.assertEqual(image.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

    def test_invalid_snapshot_label_returns_two_without_creating_a_file(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = directory
            result = run_windows_helper("snapshot", "../escape", environment=environment)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(list(Path(directory).rglob("*.png")), [])
```

- [ ] **步骤 2：运行 diagnostic tests 并观察 RED**

```powershell
python -m unittest tests.test_windows_parity.WindowsDiagnosticContractTests tests.test_windows_parity.WindowsDiagnosticBehaviorTests -v
```

预期：steps 和 helper functions 不存在，因此失败。

- [ ] **步骤 3：实施保持状态的 diagnostics**

使用 `Add-Type` 提供小型 `ShowWindowAsync`/`IsIconic` Win32 interop type。`Minimize-UURemoteWindows` 遍历现有 `GameViewer` processes，使用 command `6` 最小化非零 main-window handles，然后验证可观察 handles 为 iconic。不存在 top-level window 是合法的 finalized state。只有验证后才输出 `FINAL_DESKTOP_STATE=ready`。

`Save-DesktopSnapshot` 只接受匹配 `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` 的 labels，创建 `${RUNNER_TEMP}/uuremote-diagnostics`，读取 `SystemInformation.VirtualScreen`，并在 `try/finally` disposal 中使用 `System.Drawing.Bitmap` 和 `Graphics.CopyFromScreen`。输出 `<label>.png`，且绝不激活应用。

`Invoke-UURemoteIdempotencyCheck` 调用 readiness、应用相同的 environment custom code、再次验证 readiness，并收尾桌面。它不执行安装、不更改账户，也不启动重复实例。

添加以下四个精确 workflow steps 和 gates：

```yaml
      - name: Verify configuration idempotency
        if: success() && (env.UUREMOTE_DEBUG == '2' || env.UUREMOTE_DEBUG == '3')
      - name: Finalize desktop and capture diagnostics
        if: success()
      - name: Capture live diagnostics
        if: success() && env.UUREMOTE_DEBUG == '3'
      - name: Upload UU Remote diagnostics
        if: always() && env.UUREMOTE_DEBUG != '0'
```

Live step 精确循环 20 次，使用 `live-01` 到 `live-20` labels，每次调用 snapshot mode，并在 samples 间等待 15 秒。Finalization step 始终执行最小化，只在 non-zero debug 时调用 `snapshot final-desktop`。

- [ ] **步骤 4：运行聚焦 tests 并观察 GREEN**

```powershell
python -m unittest tests.test_windows_parity -v
```

预期：所有 Windows parity tests 通过。

- [ ] **步骤 5：提交**

```powershell
git add .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: align Windows diagnostics and idempotency"
```

---

### Task 6：对齐 macOS 公共 diagnostics 并让 tests 正确处理平台

**文件：**
- 修改：`.github/workflows/macos.yml`
- 修改：`.github/workflows/apple.sh`
- 修改：`tests/test_windows_parity.py`
- 修改：`tests/test_uuremote_desktop_finalization.py`
- 修改：`tests/test_uuremote_host_bootstrap.py`
- 修改：`tests/test_uuremote_wait.py`

**接口：**
- 输入：已建立的 macOS 行为，以及 Tasks 1 到 5 的共享 workflow contract。
- 输出：公共 artifact name/path、获批准的 device-ID log output、跨 workflow ordering checks，以及 `/bin/bash`/AppKit behavior tests 的干净 platform skips。

- [ ] **步骤 1：编写失败的跨平台与 platform-gate tests**

向 `SharedWorkflowContractTests` 添加以下两个 tests，要求两份 workflows 使用公共 artifact：

```python
    def test_both_workflows_use_the_shared_artifact_contract(self):
        for path in (MACOS_WORKFLOW, WINDOWS_WORKFLOW):
            workflow = text(path)
            self.assertIn("name: uuremote-diagnostics", workflow)
            self.assertIn("${{ runner.temp }}/uuremote-diagnostics/", workflow)

```

新增 `BASH_AVAILABLE = Path("/bin/bash").exists()`，并只向以下 behavior classes 添加 `@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")`：

- `CustomCodeValidationTests`
- `DesktopPreferenceBehaviorTests`
- `ScriptRoutingAndCodecTests`
- `WaitShellContractTests`

`WaitWatcherBehaviorTests` 保留现有 Darwin gate。不得跳过可以在 Windows 运行的 source/workflow contract classes。

- [ ] **步骤 2：运行 tests 并观察 RED**

```powershell
python -m unittest tests.test_windows_parity.SharedWorkflowContractTests -v
python -m unittest discover -s tests -v
```

实施前预期：共享 artifact/device-output assertions 失败；Windows 上 full suite 仍报告 `/bin/bash` errors。

- [ ] **步骤 3：对齐 macOS 并应用精确 platform gates**

把 macOS artifact name 改为 `uuremote-diagnostics`，workflow path 改为 `${{ runner.temp }}/uuremote-diagnostics/`，`apple.sh` evidence directory 改为 `${RUNNER_TEMP:-/tmp}/uuremote-diagnostics`。每次在 debug levels `0`、`1`、`2` 和 `3` 成功 run 都会在 launch readiness 阶段打印 `DEVICE_ID=<完整 device ID>`，紧接着打印 `DEVICE_ID_STATE=ready`。debug level `0` 的 production wait 还会在开始等待前打印 `WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>`。

更新现有 artifact assertions，并应用步骤 1 列出的四个精确 Bash gates。不得跳过 static contract tests。

保持 device-ID values 不出现在 diagnostic artifacts 中，但从两份 workflows 输出获批准的日志 contract：每次在 debug levels `0`、`1`、`2` 和 `3` 成功 run 都会在 launch readiness 阶段打印 `DEVICE_ID=<完整 device ID>`，紧接着打印 `DEVICE_ID_STATE=ready`，debug level `0` 的 production wait 会在开始等待前打印 `WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>`。修剪后，成功的 device ID 必须是一个非空可打印行。在记录前拒绝 CR、LF、NUL、所有其他 C0 control character 和 DEL；validation failure 必须 fail closed，使用通用 error，并且不输出原始不安全 output。task reviewer 和显式 security scan 仍必须确认自定义码、帐户密码、原始 CLI output 和其他未经批准的连接信息绝不出现在 logs 中。

- [ ] **步骤 4：运行完整本地 suite 并观察 GREEN**

```powershell
python -m unittest discover -s tests -v
rg -n "DEVICE_ID=|WAIT_CONNECTIONS DEVICE_ID=" .github/workflows tests
```

Windows 预期：全部可运行 tests 通过，Bash/AppKit-only behavior tests 报告 skips 而不是 errors，scan 只在获批准的 readiness 和 wait boundaries 中找到 device-ID output。macOS 预期：Bash tests 正常执行，AppKit behavior 仍处于 active 状态。

- [ ] **步骤 5：提交**

```powershell
git add .github/workflows/macos.yml .github/workflows/apple.sh tests/test_windows_parity.py tests/test_uuremote_desktop_finalization.py tests/test_uuremote_host_bootstrap.py tests/test_uuremote_wait.py
git commit -m "refactor: align UU Remote workflow contracts"
```

---

### Task 7：更新双语入口文档并运行最终本地验证

**文件：**
- 修改：`README.md`
- 修改：`README-zh_CN.md`
- 测试：`tests/test_agent_work_environment.py`
- 测试：`tests/test_windows_parity.py`

**接口：**
- 输入：最终共享 workflow contract 和平台例外。
- 输出：准确的双语 operator 文档，以及可供 code review 和外部验证的本地已验证分支。

- [ ] **步骤 1：先更新英文 README，再更新其简体中文 counterpart**

两种语言都必须陈述以下精确信息：

- 两份 workflows 都公开 `0` 到 `3` 的 `debug_level` 和 `0` 到 `21000` 的 `wait_connections_seconds`，后者默认值为 `300`。
- 两份 workflows 都要求 `UUREMOTE_CUSTOM_CODE`；只有 macOS 要求 `UUREMOTE_ACCOUNT_PASSWORD`。
- Debug levels 采用设计中定义的累积含义。
- 每次在 debug levels `0`、`1`、`2` 和 `3` 成功 run 都会在 launch readiness 阶段打印 `DEVICE_ID=<完整 device ID>`，紧接着打印 `DEVICE_ID_STATE=ready`。
- 两个平台只在 debug non-zero 时上传 `uuremote-diagnostics`。
- Windows 不更改用户、Administrator、autologin、UAC、firewall 或 SSH policy。
- 本地验证使用 `python -m unittest discover -s tests -v`；platform-only behavior 只在不兼容 hosts 上 skip。
- End-to-end acceptance 需要 repository secrets 和手动 dispatch 的平台 workflow。

- [ ] **步骤 2：运行双语与 workflow tests**

```powershell
python -m unittest tests.test_agent_work_environment tests.test_windows_parity -v
```

预期：全部 tests 通过；每个 root 和 `docs/**` Markdown file 都有一个 counterpart 和精确 navigation spacing。

- [ ] **步骤 3：运行完整本地验证**

```powershell
python -m unittest discover -s tests -v
python -m json.tool .claude/settings.json
git diff --check b1d194b..HEAD
git status --short
```

预期：所有适用 tests 通过，platform-only tests 为 skips 而不是 errors，JSON parsing 成功，diff-check 无输出，commit 前 status 只显示预期 tracked changes。

- [ ] **步骤 4：机械检查安全与 scope**

```powershell
rg -n --fixed-strings "johnDOE123" .github README.md README-zh_CN.md
rg -n -e "UUREMOTE_ACCOUNT_PASSWORD" .github/workflows/windows.yml .github/workflows/windows.ps1
git diff --name-only b1d194b..HEAD
```

预期：active workflow 中没有 literal，Windows 中没有 account-password reference，并且只包含本计划命名的文件。

- [ ] **步骤 5：提交**

```powershell
git add README.md README-zh_CN.md
git commit -m "docs: document unified UU Remote workflows"
```

---

## 外部 live-validation checkpoint

没有当前用户授权时，不得 dispatch workflows 或访问 repository secrets。Task reviews 和最终 branch review 均干净后，请求授权并通过 GitHub Actions 运行以下 matrix：

1. Windows，`debug_level=1`、`wait_connections_seconds=0`：要求输出 `DEVICE_ID=<完整 device ID>`，紧接着输出 `DEVICE_ID_STATE=ready`、通用 custom-code success、`FINAL_DESKTOP_STATE=ready`、artifact upload、干净 final screenshot 和真实手机客户端连接。
2. Windows，`debug_level=2`、`wait_connections_seconds=0`：要求输出 `DEVICE_ID=<完整 device ID>`，紧接着输出 `DEVICE_ID_STATE=ready`，第二次 pass 报告 readiness 和 finalization，且不存在重复 application instances。
3. Windows，`debug_level=3`、`wait_connections_seconds=0`：要求输出 `DEVICE_ID=<完整 device ID>`，紧接着输出 `DEVICE_ID_STATE=ready`、20 个名为 `live-01.png` 到 `live-20.png` 的文件，并且不存在 foreground UU Remote window。
4. Windows，`debug_level=0`、`wait_connections_seconds=5`：要求输出 `DEVICE_ID=<完整 device ID>`，紧接着输出 `DEVICE_ID_STATE=ready`，并在 `WAIT_RESULT=timeout` 前立即输出 `WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>`，且没有 diagnostic artifact。
5. 一次专用 Windows remote shutdown 或 restart run：当 workflow 存活到足以记录时，要求 `WAIT_RESULT=shutdown/restart`；如果 GitHub 先终止 runner，记录平台限制，但不得削弱 shutdown behavior。
6. macOS 在 debug level `0` 和 `1` 的 smoke runs：验证重命名后的 artifact contract、在 launch readiness 期间输出 `DEVICE_ID=<完整 device ID>`，紧接着输出 `DEVICE_ID_STATE=ready`、debug level `0` 在开始等待前立即输出 `WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>`，以及保留已有 permissions 和 desktop finalization。

如果 live run 失败，使用 `superpowers:systematic-debugging`，只保留经过脱敏的 logs/artifacts，增加能够捕获已发现 contract 的失败 repository test，并在再次 live run 前重复 review。

## 最终 branch gate

依据 `docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md` 请求整分支 review。解决所有 Critical 和 Important findings。然后使用 `superpowers:verification-before-completion` 与 `superpowers:finishing-a-development-branch`；没有用户的集成选择时绝不 merge 或 push。
