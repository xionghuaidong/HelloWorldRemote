# Device ID Workflow 日志输出实施计划

[English](2026-08-15-device-id-workflow-log-output.md) | [简体中文](2026-08-15-device-id-workflow-log-output-zh_CN.md)

> **面向 agentic workers：** 必须使用子技能 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，逐项实施本计划。所有步骤使用 checkbox（`- [ ]`）跟踪。

**目标：** 在 Windows 与 macOS 已批准的 launch/readiness 和 production wait 日志消息中打印完整 UU Remote device ID，同时继续保护 custom codes 与账户密码。

**架构：** 保留两个平台现有 CLI 与 wait boundaries。各平台增加一个本地 validated device-ID 消息 boundary；每次 run 在 launch/readiness 调用一次，并在 debug level `0` wait route 再调用一次；不向 diagnostic artifacts 添加 device ID，也不修改 watcher results。

**技术栈：** GitHub Actions YAML、PowerShell 5.1/pwsh 7.x、Bash 3.2+、Python `unittest`、现有 Swift 与 C# shutdown watchers、双语 Markdown。

## 全局约束

- 账户密码和 `UUREMOTE_CUSTOM_CODE` 仍然是 secrets；禁止打印其值或可能包含这些值的原始 CLI 输出。
- UU Remote device ID 是可以记录到日志的 operational identifier；除非另有批准，否则其他远程设备连接信息仍然禁止记录。
- Launch/readiness 在 debug level `0`、`1`、`2`、`3` 的每次成功 run 中精确输出一次 `DEVICE_ID=<完整 device ID>`，并立即输出 `DEVICE_ID_STATE=ready`。
- 现有 debug-level `0` `Wait connections` route 还要在不变的 `WAIT_RESULT=timeout|shutdown/restart` 前输出 `WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>`。
- 先去除首尾空白，再拒绝空值、多行、NUL、C0 控制字符或 DEL device IDs。
- 失败 polls 和原始 CLI stderr 不得进入日志；错误必须使用通用消息并 fail-closed。
- Diagnostic artifacts 不主动增加 device-ID 内容；screenshots 与 artifact behavior 保持不变。
- 必须继续支持 Windows PowerShell 5.1 与现代 pwsh；macOS Bash 不得依赖更新版本 Bash 才有的语言特性。
- 先更新英文，并在同一 commit 更新每份简体中文 counterpart；保持精确 H1/navigation/blank-line 结构。
- Source、script、test 与 configuration comments 全部使用英文。
- 每项 behavior change 都遵循 TDD：观察 RED、实施最小 GREEN、refactor、验证、commit，然后请求独立 review。

## 文件映射

- `AGENTS.md`、`AGENTS-zh_CN.md`：共享 repository 数据分类与 validation policy。
- `CLAUDE.md`、`CLAUDE-zh_CN.md`：alternate agent entry point 的等价共享政策。
- `README.md`、`README-zh_CN.md`：面向操作人员说明 device-ID 输出位置与频率。
- `docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md` 及 counterpart：修订被新设计取代的 sensitive-output 表述。
- `docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md` 及 counterpart：修订早期“不输出 device ID”的实现假设与验收检查。
- `tests/test_agent_work_environment.py`：可执行政策与双语文档 contract。
- `.github/workflows/windows.ps1`：Windows validation、launch/readiness 输出与 wait 输出。
- `tests/windows_helper_harness.ps1`：受控 Windows readiness CLI boundary。
- `tests/test_windows_parity.py`：Windows launch、validation、wait、debug gate 与 secret-preservation behavior。
- `.github/workflows/apple.sh`：macOS byte-safe CLI read、消息输出与 wait 输出。
- `.github/workflows/macos.yml`：在保留 step order 与 gates 的前提下，把 launch polling 委托给真实 macOS helper。
- `tests/test_uuremote_wait.py`：macOS workflow/wait contract 与 platform behavior。
- `tests/test_uuremote_desktop_finalization.py`：共享 macOS launch/readiness 与 artifact contract。
- `tests/test_macos_device_id_logging.sh`：针对合法和 hostile CLI 输出的可执行 Bash fixture。

---

### Task 1：重新分类 Device ID，同时不削弱 Secret Policy

**文件：**
- 修改：`tests/test_agent_work_environment.py:27-44`
- 修改：`AGENTS.md:45-50`
- 修改：`AGENTS-zh_CN.md:45-50`
- 修改：`CLAUDE.md:45-50`
- 修改：`CLAUDE-zh_CN.md:45-50`
- 修改：`README.md:11-30,47-50`
- 修改：`README-zh_CN.md:11-30,47-50`
- 修改：`docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md:74-82,120-125,213-235`
- 修改：`docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design-zh_CN.md:74-82,120-125,213-235`
- 修改：`docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md:370-445,555-610,680-700`
- 修改：`docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md:360-437,549-604,674-694`

**接口：**
- 输入：`docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md` 中已批准的数据分类。
- 输出：一个一致政策：device ID 是可记录日志的 operational identifier；`UUREMOTE_CUSTOM_CODE`、账户密码和其他未经批准的连接信息仍禁止记录。

- [ ] **步骤 1：添加失败的共享政策测试**

在 `AgentInstructionContractTests` 添加：

```python
def test_device_id_is_loggable_while_credentials_remain_secret(self):
    english_policy = (
        "A UU Remote device ID is a loggable operational identifier"
    )
    chinese_policy = "UU Remote device ID 是可以记录到日志的 operational identifier"
    secret_token = "UUREMOTE_CUSTOM_CODE"

    for name in ("AGENTS.md", "CLAUDE.md"):
        contents = text(ROOT / name)
        self.assertIn(english_policy, contents)
        self.assertIn(secret_token, contents)
        self.assertIn("remains sensitive", contents)

    for name in ("AGENTS-zh_CN.md", "CLAUDE-zh_CN.md"):
        contents = text(ROOT / name)
        self.assertIn(chinese_policy, contents)
        self.assertIn(secret_token, contents)
        self.assertIn("仍然是敏感信息", contents)

    self.assertIn("DEVICE_ID=<complete device ID>", text(ROOT / "README.md"))
    self.assertIn("DEVICE_ID=<完整 device ID>", text(ROOT / "README-zh_CN.md"))
```

- [ ] **步骤 2：运行政策测试并观察 RED**

运行：

```powershell
python -m unittest tests.test_agent_work_environment.AgentInstructionContractTests.test_device_id_is_loggable_while_credentials_remain_secret -v
```

预期：FAIL，因为四份 instruction files 仍把全部 remote-device connection information 视为敏感信息，README 也尚未说明新输出。

- [ ] **步骤 3：更新四份共享 instruction files**

在两份英文文件中，用以下政策替换过宽的敏感数据 bullet：

```markdown
* Treat account passwords and UU Remote custom codes as secrets. A UU Remote device ID is a loggable operational identifier; other remote-device connection information remains sensitive unless an approved design says otherwise. In particular, `UUREMOTE_ACCOUNT_PASSWORD` and `UUREMOTE_CUSTOM_CODE` are secrets.
```

在两份中文文件中使用等义政策：

```markdown
* 将账户密码和 UU Remote custom codes 视为 secrets。UU Remote device ID 是可以记录到日志的 operational identifier；除非已批准设计另有规定，否则其他远程设备连接信息仍然是敏感信息。尤其是 `UUREMOTE_ACCOUNT_PASSWORD` 和 `UUREMOTE_CUSTOM_CODE` 属于 secrets。
```

不要修改现有 masking、step scope、custom-code placeholder、operating-system security 或 validation rules。

- [ ] **步骤 4：更新 README pair 与 governing parity documents**

在英文 README 的 secret requirements 后添加：

```markdown
- Every successful run prints `DEVICE_ID=<complete device ID>` during launch readiness. The debug-level `0` production wait also prints `WAIT_CONNECTIONS DEVICE_ID=<complete device ID>` immediately before waiting.
```

添加中文 counterpart：

```markdown
- 每次成功 run 都会在 launch readiness 阶段打印 `DEVICE_ID=<完整 device ID>`。Debug level `0` 的 production wait 还会在开始等待前打印 `WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>`。
```

在 2026-08-14 parity design 和 plan pairs 中，用上述精确 contract 替换所有禁止 device-ID logging 的要求。保留 artifact redaction、custom-code masking、password secrecy、raw-CLI suppression、debug gates 和 watcher behavior。更新旧 test examples：成功 readiness 应期待 fixture ID，而 timeout/failure examples 仍拒绝原始 attempt 输出。

- [ ] **步骤 5：运行文档 GREEN 与结构检查**

运行：

```powershell
python -m unittest tests.test_agent_work_environment -v
python -m json.tool .claude/settings.json
git diff --check
```

预期：8 项政策/文档 tests 通过，JSON 可解析，diff check 无 findings。

- [ ] **步骤 6：提交政策修改**

```powershell
git add AGENTS.md AGENTS-zh_CN.md CLAUDE.md CLAUDE-zh_CN.md README.md README-zh_CN.md tests/test_agent_work_environment.py docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design-zh_CN.md docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md
git commit -m "docs: classify UU Remote device IDs"
```

- [ ] **步骤 7：请求独立政策 review**

Reviewer 必须确认四份 instruction files meaning-equivalent，custom codes/passwords 仍为 secrets，每份修改的 Markdown 都有合法 counterpart/navigation line，且没有 runtime file 改动。在 Critical 与 Important findings 归零前不得开始 Task 2。

---

### Task 2：输出经过验证的 Windows Device-ID 消息

**文件：**
- 修改：`tests/windows_helper_harness.ps1:1-120`
- 修改：`tests/test_windows_parity.py:200-225,350-420`
- 修改：`.github/workflows/windows.ps1:152-225,703-720`

**接口：**
- 输入：`Get-UURemoteDeviceId -CliPath <string> [-TimeoutMilliseconds <int>]`、现有 bounded readiness polling 和 `Invoke-ShutdownWaiter`。
- 输出：`Get-UURemoteLoggableDeviceId([string]) -> string`、`Write-UURemoteDeviceIdMessage -DeviceId <string> -Context <Readiness|Wait>`、launch 输出 `DEVICE_ID=...` 与 `DEVICE_ID_STATE=ready`、wait 输出 `WAIT_CONNECTIONS DEVICE_ID=...`。

- [ ] **步骤 1：修改成功 readiness 预期并添加 hostile-value RED tests**

把现有 readiness success assertion 改为：

```python
self.assertEqual(
    [line for line in result.stdout.splitlines() if line.startswith("DEVICE_ID")],
    ["DEVICE_ID=device-id-fixture", "DEVICE_ID_STATE=ready"],
)
self.assertEqual(result.stdout.count("DEVICE_ID=device-id-fixture"), 1)
```

添加 `import base64`，并向 `WindowsWaitBehaviorTests` 添加以下 controlled runner。它 dot-source 真实 helper，只替换 CLI/path boundary；Base64 可以在不把换行、NUL 或 DEL 直接嵌入 PowerShell source 的情况下保留这些值：

```python
def run_controlled_device_id_route(self, device_id: str, seconds: str):
    helper = str(WINDOWS_HELPER).replace("'", "''")
    encoded = base64.b64encode(device_id.encode("utf-8")).decode("ascii")
    return run_windows_script(
        rf"""
. '{helper}'
function Get-UURemotePaths {{
    return [pscustomobject]@{{ LauncherPath = 'fixture'; CliPath = 'fixture' }}
}}
function Assert-UURemotePaths {{ param([pscustomobject]$Paths) }}
$script:FixtureDeviceId = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('{encoded}')
)
function Get-UURemoteDeviceId {{
    param([string]$CliPath, [int]$TimeoutMilliseconds = 60000)
    return $script:FixtureDeviceId
}}
$script:HelperMode = 'wait-connections'
$script:Arguments = @('{seconds}')
Invoke-WindowsHelperRoute
"""
    )
```

添加以下受控 behavior tests：

```python
def test_wait_message_contains_current_device_id_before_zero_timeout(self):
    result = self.run_controlled_device_id_route("device-id-fixture", "0")
    self.assertEqual(result.returncode, 0, result.stderr)
    self.assertEqual(
        result.stdout.splitlines(),
        [
            "WAIT_CONNECTIONS DEVICE_ID=device-id-fixture",
            "WAIT_RESULT=timeout",
        ],
    )

def test_multiline_device_id_fails_closed_without_log_injection(self):
    result = self.run_controlled_device_id_route(
        "device-id-fixture`nFORGED_OUTPUT=true",
        "0",
    )
    self.assertEqual(result.returncode, 1)
    self.assertEqual(result.stdout, "")
    self.assertEqual(result.stderr.strip(), "Shutdown-aware wait failed.")
    self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
    self.assertNotIn("FORGED_OUTPUT", result.stdout + result.stderr)

def test_control_characters_in_device_id_fail_closed(self):
    for value in ("device\x00id", "device\tid", "device\x7fid"):
        with self.subTest(value=repr(value)):
            result = self.run_controlled_device_id_route(value, "0")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr.strip(), "Shutdown-aware wait failed.")
```

`run_controlled_device_id_route` 必须在只 override `Get-UURemotePaths`、`Assert-UURemotePaths` 和 `Get-UURemoteDeviceId` 后，调用真实 helper 的 `Invoke-WindowsHelperRoute`。

- [ ] **步骤 2：为不安全 readiness 添加 harness mode，并观察 RED**

向 harness `ValidateSet` 添加 `readiness-unsafe-device`。CLI fixture 返回：

```powershell
return [pscustomobject]@{
    ExitCode = 0
    Output = @('device-id-fixture', 'FORGED_OUTPUT=true')
}
```

添加 test，要求 exit `1`、无 stdout，并且 stderr 不包含 fixture/forged value。运行：

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessBehaviorTests tests.test_windows_parity.WindowsWaitBehaviorTests -v
```

预期：RED，因为 readiness 仍隐藏合法 ID，wait route 不读取 ID，而且多行值未在输出前被拒绝。

- [ ] **步骤 3：实施 Windows validated message boundary**

在 `Get-UURemoteDeviceId` 后添加：

```powershell
function Get-UURemoteLoggableDeviceId([string]$DeviceId) {
    $normalized = if ($null -eq $DeviceId) { '' } else { $DeviceId.Trim() }
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        $normalized -match '[\x00-\x1F\x7F]') {
        throw 'UU Remote device ID is invalid.'
    }
    return $normalized
}

function Write-UURemoteDeviceIdMessage {
    param(
        [string]$DeviceId,
        [ValidateSet('Readiness', 'Wait')]
        [string]$Context
    )

    $normalized = Get-UURemoteLoggableDeviceId -DeviceId $DeviceId
    if ($Context -eq 'Readiness') {
        Write-Output "DEVICE_ID=$normalized"
        Write-Output 'DEVICE_ID_STATE=ready'
        return
    }
    Write-Output "WAIT_CONNECTIONS DEVICE_ID=$normalized"
}
```

在 `Start-UURemoteAndWaitDevice` 中，用以下内容替换仅输出通用 success 的代码：

```powershell
Write-UURemoteDeviceIdMessage -DeviceId $deviceId -Context 'Readiness'
Remove-Variable -Name deviceId -ErrorAction SilentlyContinue
return
```

保持 `Assert-UURemoteReadiness` 通用，避免 idempotency/finalization 产生额外 device-ID 消息。

- [ ] **步骤 4：添加 wait 消息，但不修改 watcher results**

在真实 `wait-connections` route 内，验证 seconds 后、zero-wait branch 前获取 paths 与当前 ID，并输出 wait context：

```powershell
try {
    $paths = Get-UURemotePaths
    Assert-UURemotePaths -Paths $paths
    $deviceId = Get-UURemoteDeviceId -CliPath $paths.CliPath
    Write-UURemoteDeviceIdMessage -DeviceId $deviceId -Context 'Wait'

    if ($seconds -eq 0) {
        Write-Output 'WAIT_RESULT=timeout'
        exit 0
    }

    Invoke-ShutdownWaiter -Seconds $seconds -InjectedEvent 'none'
}
catch {
    [Console]::Error.WriteLine('Shutdown-aware wait failed.')
    exit 1
}
finally {
    Remove-Variable -Name deviceId -ErrorAction SilentlyContinue
}
```

不要修改 `self-test-wait-connections`；它继续独立于已安装 CLI，normalized diagnostic allowlist 保持不变。

- [ ] **步骤 5：运行 Windows GREEN 与兼容性检查**

运行：

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessContractTests tests.test_windows_parity.WindowsReadinessBehaviorTests tests.test_windows_parity.WindowsWaitBehaviorTests -v
python -m unittest tests.test_windows_parity -v
powershell.exe -NoLogo -NoProfile -Command "$errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.github/workflows/windows.ps1'),[ref]$null,[ref]$errors) | Out-Null; if($errors.Count){$errors | Out-String; exit 1}"
git diff --check
```

预期：focused 与完整 Windows parity tests 在每个发现的 PowerShell runtime 下通过；parser 与 diff check 通过。现有 interactive screenshot tests 只能在 Windows interactive desktop 运行，不能在 isolated desktop sandbox 中运行。

- [ ] **步骤 6：验证 secret preservation**

运行：

```powershell
rg -n "Write-(Output|Host).*UUREMOTE_CUSTOM_CODE|WAIT_CONNECTIONS.*CUSTOM_CODE|DEVICE_ID=.*CUSTOM_CODE" .github/workflows/windows.ps1 .github/workflows/windows.yml tests
```

预期：无匹配。重新运行现有 invalid custom-code 与 wait self-test exception-category tests；所有 custom-code fixtures 仍不可见。

- [ ] **步骤 7：提交并 review Windows behavior**

```powershell
git add .github/workflows/windows.ps1 tests/windows_helper_harness.ps1 tests/test_windows_parity.py
git commit -m "feat: log Windows UU Remote device IDs"
```

独立 reviewer 必须使用合法、多行、控制字符、zero-wait 和 self-test inputs 执行真实 helper；确认 readiness 消息精确出现一次、存在附加 wait 消息、失败原始输出不可见、watcher tokens 不变，并确认 PowerShell 5.1/pwsh 兼容。Critical 与 Important findings 归零前不得开始 Task 3。

---

### Task 3：输出等价的 macOS Device-ID 消息

**文件：**
- 新建：`tests/test_macos_device_id_logging.sh`
- 修改：`tests/test_uuremote_wait.py:15-70`
- 修改：`tests/test_uuremote_desktop_finalization.py:35-65`
- 修改：`.github/workflows/apple.sh:1-20,190-285,1439-1465`
- 修改：`.github/workflows/macos.yml:65-100,137-155`

**接口：**
- 输入：返回 legacy 单行 ID 或 macOS JSON envelope 的已安装 CLI command `assist id`、现有 `wait_connections`、`run_shutdown_waiter` 与 debug-level `0` wait gate。
- 输出：`read_uuremote_device_id() -> validated stdout`、`emit_current_device_id(readiness|wait)`、early helper mode `report-device-id readiness`、与 Windows 相同的 launch 输出及 wait 输出。

- [ ] **步骤 1：编写可执行 Bash fixture 与 RED assertions**

新建 `tests/test_macos_device_id_logging.sh`，其中包含临时 executable CLI fixture。Fixture 接受 `assist id`，并按 `DEVICE_ID_FIXTURE_MODE` 选择输出：

```bash
case "${DEVICE_ID_FIXTURE_MODE:?}" in
    valid) printf '%s\n' 'device-id-fixture' ;;
    json-valid) printf '%s\n' '{"success":true,"data":{"deviceId":"123456789"}}' ;;
    json-false) printf '%s\n' '{"success":false,"data":{"deviceId":"device-id-fixture"}}' ;;
    json-duplicate) printf '%s\n' '{"success":true,"data":{"deviceId":"device-id-fixture","deviceId":"FORGED_OUTPUT=true"}}' ;;
    empty) printf '\n' ;;
    multiline) printf 'device-id-fixture\nFORGED_OUTPUT=true\n' ;;
    control) printf 'device-id-fixture\tFORGED_OUTPUT=true\n' ;;
    nul) printf 'device-id-fixture\000FORGED_OUTPUT=true\n' ;;
    del) printf 'device-id-fixture\177FORGED_OUTPUT=true\n' ;;
    failure)
        printf '%s\n' 'raw-cli-device-output' >&2
        exit 7
        ;;
esac
```

Harness 必须把 `UUREMOTE_CLI_PATH` 指向 fixture，并断言合法输出精确为：

```text
DEVICE_ID=device-id-fixture
DEVICE_ID_STATE=ready
```

以及：

```text
WAIT_CONNECTIONS DEVICE_ID=device-id-fixture
WAIT_RESULT=timeout
```

它还必须断言 empty、multiline、control、NUL、DEL、失败的 CLI output、malformed JSON、nonstandard JSON constants、false/missing/wrong-type envelope fields、duplicate keys 和不安全的 extracted IDs 返回非零，且不暴露 `device-id-fixture`、`FORGED_OUTPUT`、原始 JSON envelope 或 `raw-cli-device-output`。

- [ ] **步骤 2：添加 Python workflow contracts 并观察 RED**

更新 `WaitWorkflowContractTests` 与 launch contract，要求：

```python
launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
self.assertIn("apple.sh report-device-id readiness", launch)

wait = step_block(text(WORKFLOW_PATH), "Wait connections")
self.assertIn("apple.sh wait-connections", wait)
self.assertIn("env.UUREMOTE_DEBUG == '0'", wait)
```

在 macOS 或可用 Bash runtime 中运行：

```bash
/bin/bash tests/test_macos_device_id_logging.sh
python -m unittest tests.test_uuremote_wait tests.test_uuremote_desktop_finalization -v
```

预期：RED，因为 `UUREMOTE_CLI_PATH`、`report-device-id`、byte-safe validation 与 wait 消息尚不存在。

- [ ] **步骤 3：添加 byte-safe、JSON-aware macOS CLI boundary**

修改 CLI assignment，但不改变其默认值：

```bash
CLI="${UUREMOTE_CLI_PATH:-$APP/Contents/Helpers/uuyc-cli}"
```

在 `wait_connections` 前添加：

```bash
read_uuremote_device_id() {
    "$CLI" assist id 2>/dev/null | /usr/bin/python3 -c '
import json
import sys
import unicodedata

raw = sys.stdin.buffer.read()
try:
    decoded = raw.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError
        result[key] = value
    return result

def reject_nonstandard_constant(_value):
    raise ValueError

def validate_device_id(value):
    if not isinstance(value, str):
        raise ValueError
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValueError

    value = value.strip(" ")
    if not value or any(unicodedata.category(character)[0] in {"C", "Z"} for character in value):
        raise ValueError
    return value

json_candidate = decoded.lstrip(" \t\r\n")
try:
    if json_candidate.startswith(("{", "[")):
        payload = json.loads(
            decoded,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonstandard_constant,
        )
        if not isinstance(payload, dict) or payload.get("success") is not True:
            raise ValueError
        data = payload.get("data")
        if not isinstance(data, dict):
            raise ValueError
        value = validate_device_id(data.get("deviceId"))
    else:
        if decoded.endswith("\r\n"):
            decoded = decoded[:-2]
        elif decoded.endswith("\n"):
            decoded = decoded[:-1]
        value = validate_device_id(decoded)
except (json.JSONDecodeError, ValueError):
    raise SystemExit(1)

sys.stdout.write(value)
'
}

emit_current_device_id() {
    local context="$1"
    local device_id

    if ! device_id="$(read_uuremote_device_id)"; then
        return 1
    fi

    case "$context" in
        readiness)
            printf 'DEVICE_ID=%s\n' "$device_id"
            printf 'DEVICE_ID_STATE=ready\n'
            ;;
        wait)
            printf 'WAIT_CONNECTIONS DEVICE_ID=%s\n' "$device_id"
            ;;
        *)
            unset device_id
            return 2
            ;;
    esac
    unset device_id
}
```

JSON-looking output 绝不允许回退到 legacy single-line validation。Parser 拒绝 malformed JSON、duplicate keys、非 object root、false/missing/wrong-type required fields、nonstandard constants 和不安全的 extracted IDs。脚本已经启用 `set -o pipefail`，因此 CLI 非零退出不会被 Python validator 转换成成功的空读取。

- [ ] **步骤 4：添加 early report route 与 wait 输出**

在 application/bootstrap preflight 前添加：

```bash
if [ "$mode" = "report-device-id" ]; then
    if [ "$#" -ne 2 ] || [ "$2" != "readiness" ]; then
        echo "Usage: apple.sh report-device-id readiness" >&2
        exit 2
    fi
    emit_current_device_id "${2:-}"
    exit $?
fi
```

在 `wait_connections` 开头、seconds validation 后要求 wait 消息：

```bash
if ! emit_current_device_id wait; then
    echo "UU Remote wait device ID is unavailable." >&2
    return 1
fi
```

保持其后的 zero-wait 与 watcher result lines 不变。保持 `self_test_wait_connections` 独立于 CLI。

- [ ] **步骤 5：把 macOS launch loop 委托给 helper**

把 inline `assist id` capture 替换为：

```bash
if .github/workflows/apple.sh report-device-id readiness
then
    device_id_ready=1
    break
fi
echo "UU Remote device ID is unavailable, retrying in 500 ms" >&2
```

不要在 YAML 中保存或打印原始 CLI 输出。保留 120 attempts、500 ms interval、fail-closed exhaustion、step ordering 与每个现有 debug gate。

- [ ] **步骤 6：运行 macOS GREEN、syntax 与 artifact-redaction 检查**

运行：

```bash
/bin/bash tests/test_macos_device_id_logging.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh
python -m unittest tests.test_uuremote_wait tests.test_uuremote_desktop_finalization -v
```

预期：合法 readiness/wait 消息精确通过；hostile values 失败且无泄漏；现有 diagnostic artifact 只包含 sanitized state/exit fields；Bash syntax 与 Python tests 通过。

- [ ] **步骤 7：提交并 review macOS behavior**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_macos_device_id_logging.sh tests/test_uuremote_wait.py tests/test_uuremote_desktop_finalization.py
git commit -m "feat: log macOS UU Remote device IDs"
```

独立 reviewer 必须针对 fixture modes 执行真实 helper，确认 launch 与 wait prefixes 精确匹配 Windows、`debug_level=0` wait gate 未扩大，并确认 custom-code/account-password handling 与 diagnostic artifact content 不变。Critical 与 Important findings 归零前不得开始 Task 4。

---

### Task 4：验证统一 Contract 并运行 Live Acceptance

**文件：**
- 仅验证：Tasks 1-3 修改的所有文件。
- 只有观察到 contract mismatch 时才修改：同一 focused fix commit 中的对应英文/中文 pair 及其 executable test。
- Coordination evidence：`.superpowers/sdd/2026-08-15-device-id-workflow-log-output/`（ignored；禁止提交）。

**接口：**
- 输入：Tasks 2 与 3 的精确 launch/readiness 和 wait 消息、不变的 artifact contract、现有 repository secrets 与 GitHub Actions dispatch inputs。
- 输出：fresh local、独立 review 与 live evidence，证明每个 debug level 都暴露可用 device ID，同时 secrets 仍不可见。

- [ ] **步骤 1：运行完整本地 regression suite**

运行：

```powershell
python -m unittest discover -s tests -v
python -m json.tool .claude/settings.json
git diff --check e30a65b..HEAD
git status --short
```

在 macOS 使用 `/bin/bash`，或在 Windows 使用已安装 Git Bash executable，运行两份 Bash harnesses。预期：所有可运行 tests 通过，仅保留已记录的 platform skips，JSON 与 diff checks 通过，tracked worktree clean。

- [ ] **步骤 2：运行 platform parser/runtime 兼容性检查**

Windows：用 Windows PowerShell 5.1 解析 `.github/workflows/windows.ps1`，并分别以 Windows PowerShell 与 PATH-visible modern pwsh 运行一次 `tests.test_windows_parity`。Interactive PNG tests 必须在 isolated desktop sandbox 外执行。

macOS：运行 `/bin/bash -n .github/workflows/apple.sh`、device-ID Bash fixture、diagnostic-redaction Bash fixture 与 native AppKit watcher self-test。

预期：两个 PowerShell editions、Bash syntax/behavior、真实 PNG capture 与 watcher self-tests 全部通过。

- [ ] **步骤 3：运行定向 secret 与 output scans**

运行：

```powershell
rg -n "DEVICE_ID=|WAIT_CONNECTIONS DEVICE_ID=" .github/workflows tests README.md README-zh_CN.md docs/superpowers
rg -n "Write-(Output|Host).*CUSTOM_CODE|echo .*CUSTOM_CODE|assist set-code.*\$|--reset-custom-code.*Write" .github/workflows tests
```

预期：device-ID value output 只出现在已批准的 readiness/wait boundaries 以及 tests/docs；不存在 custom-code 或 account-password value output。人工确认 artifacts 未增加 device-ID text file。

- [ ] **步骤 4：请求最终 whole-branch review**

Reviewer 必须把 `1fee8c7..HEAD` 与已批准的 2026-08-15 spec 对比，检查两平台实现与全部 policy files，并报告 Critical/Important/Minor findings。Live dispatch 前 Critical 与 Important 必须为零。Minor findings 必须由 focused Conventional Commit 修复，或在获得用户批准后明确记录。

- [ ] **步骤 5：推送已 review 分支并 dispatch 自动 live matrix**

在当前用户授权下，push `codex/windows-macos-functional-parity`，然后手动 dispatch：

1. Windows `debug_level=0`、`wait_connections_seconds=0`。
2. Windows `debug_level=1`、`wait_connections_seconds=0`。
3. Windows `debug_level=2`、`wait_connections_seconds=0`。
4. Windows `debug_level=3`、`wait_connections_seconds=0`。
5. macOS `debug_level=0`、`wait_connections_seconds=0`。
6. macOS `debug_level=1`、`wait_connections_seconds=0`。

每个成功 run 的 launch step 必须精确包含一次 `DEVICE_ID=<value>`，并立即跟随 `DEVICE_ID_STATE=ready`。两次 debug-level `0` run 的 `Wait connections` 必须在精确 `WAIT_RESULT=timeout` 前包含 `WAIT_CONNECTIONS DEVICE_ID=<value>`。确认 debug level `1`-`3` 不执行 wait step。

- [ ] **步骤 6：检查 live artifacts 与 secret handling**

只把 debug artifacts 下载到精确临时目录。确认现有 names/file counts，抽查 screenshots 是否意外显示前台 UU Remote/System Settings windows，并扫描 text artifacts 中的 custom-code/account-password values。Device IDs 可以出现在指定 workflow logs，但不得新增为 diagnostic text file。检查后删除精确 downloaded ZIPs 与 temporary extraction directories；保留 GitHub artifacts。

- [ ] **步骤 7：运行手动 mobile-client 与 shutdown/restart acceptance**

使用用户批准的正 wait duration dispatch Windows debug-level `0` run。通知用户 run 已进入 `Wait connections`；用户复制可见 device ID，并使用单独持有的 custom code 连接。只记录是否连接成功，绝不记录 custom code。

Executable injected shutdown-wait self-test 是确定性验收，用于验证精确 `WAIT_RESULT=shutdown/restart` 输出与 cleanup contract。在 live acceptance 前运行并要求它通过。

Live acceptance 要求 mobile-client 连接成功，并观察到所请求的真实 shutdown/offline effect。使用独立 positive-wait run 验收 shutdown/restart。由用户发起 remote shutdown/restart action；agent 禁止执行 operating-system shutdown command。

由于 runner 可能在回传前失去网络，真实关机后的最终 GitHub log、result 与 cleanup evidence 仅作 best-effort。缺少关机后的回传不得被判定为 watcher failure；当确定性 self-test 已通过，且已观察到 live connection 与 shutdown/offline effect 时，该回传缺失不阻塞验收。

- [ ] **步骤 8：最终验证与 handoff**

重新运行完整本地 suite、双语 navigation/counterpart checks、parser/runtime checks、custom-code/password scans、`git diff --check e30a65b..HEAD` 与 clean-status check。不得创建空 verification commit。使用 `superpowers:verification-before-completion`，随后使用 `superpowers:finishing-a-development-branch` 展示 integration options；没有用户明确选择时不得创建 PR 或 merge。
