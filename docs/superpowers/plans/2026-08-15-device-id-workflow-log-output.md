# Device ID Workflow Log Output Implementation Plan

[English](2026-08-15-device-id-workflow-log-output.md) | [简体中文](2026-08-15-device-id-workflow-log-output-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Print the complete UU Remote device ID in the approved launch/readiness and production wait log messages on Windows and macOS while keeping custom codes and account passwords secret.

**Architecture:** Keep each platform's existing CLI and wait boundaries. Add one platform-local validated device-ID message boundary, call it once from launch/readiness on every run, and call it again from the debug-level `0` wait route; do not add device IDs to diagnostic artifacts or change watcher results.

**Tech Stack:** GitHub Actions YAML, PowerShell 5.1/pwsh 7.x, Bash 3.2+, Python `unittest`, existing Swift and C# shutdown watchers, bilingual Markdown.

## Global Constraints

- Account passwords and `UUREMOTE_CUSTOM_CODE` remain secrets; never print their values or raw CLI output that can contain them.
- A UU Remote device ID is a loggable operational identifier; other remote-device connection information remains non-loggable unless separately approved.
- Launch/readiness prints `DEVICE_ID=<complete device ID>` immediately followed by `DEVICE_ID_STATE=ready` exactly once for every successful run at debug levels `0`, `1`, `2`, and `3`.
- The existing debug-level `0` `Wait connections` route additionally prints `WAIT_CONNECTIONS DEVICE_ID=<complete device ID>` before the unchanged `WAIT_RESULT=timeout|shutdown/restart` line.
- Trim surrounding whitespace and reject empty, multiline, NUL, C0-control, and DEL-containing device IDs before logging.
- Failed polls and raw CLI stderr never reach logs; errors remain generic and fail closed.
- Diagnostic artifacts do not deliberately acquire device-ID content; screenshot and artifact behavior remains unchanged.
- Windows PowerShell 5.1 and modern pwsh must remain supported; macOS Bash must not require a newer Bash language feature.
- Update English first and every Simplified Chinese counterpart in the same commit; preserve exact H1/navigation/blank-line structure.
- All source, script, test, and configuration comments are English.
- Use TDD for every behavior change: observe RED, implement minimal GREEN, refactor, verify, commit, then request independent review.

## File Map

- `AGENTS.md`, `AGENTS-zh_CN.md`: shared repository data-classification and validation policy.
- `CLAUDE.md`, `CLAUDE-zh_CN.md`: meaning-equivalent shared policy for the alternate agent entry point.
- `README.md`, `README-zh_CN.md`: operator-facing locations and frequency of device-ID output.
- `docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md` and counterpart: revise the superseded sensitive-output statements.
- `docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md` and counterpart: revise the earlier no-device-ID implementation assumptions and acceptance checks.
- `tests/test_agent_work_environment.py`: executable policy and bilingual documentation contract.
- `.github/workflows/windows.ps1`: Windows validation, launch/readiness output, and wait output.
- `tests/windows_helper_harness.ps1`: controlled Windows readiness CLI boundary.
- `tests/test_windows_parity.py`: Windows launch, validation, wait, debug-gate, and secret-preservation behavior.
- `.github/workflows/apple.sh`: macOS byte-safe CLI read, message output, and wait output.
- `.github/workflows/macos.yml`: delegate launch polling to the real macOS helper while preserving the existing step order and gates.
- `tests/test_uuremote_wait.py`: macOS workflow/wait contract and platform behavior.
- `tests/test_uuremote_desktop_finalization.py`: shared macOS launch/readiness and artifact contract.
- `tests/test_macos_device_id_logging.sh`: executable Bash fixture for valid and hostile CLI outputs.

---

### Task 1: Reclassify Device IDs Without Weakening Secret Policy

**Files:**
- Modify: `tests/test_agent_work_environment.py:27-44`
- Modify: `AGENTS.md:45-50`
- Modify: `AGENTS-zh_CN.md:45-50`
- Modify: `CLAUDE.md:45-50`
- Modify: `CLAUDE-zh_CN.md:45-50`
- Modify: `README.md:11-30,47-50`
- Modify: `README-zh_CN.md:11-30,47-50`
- Modify: `docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md:74-82,120-125,213-235`
- Modify: `docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design-zh_CN.md:74-82,120-125,213-235`
- Modify: `docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md:370-445,555-610,680-700`
- Modify: `docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md:360-437,549-604,674-694`

**Interfaces:**
- Consumes: the approved data classification in `docs/superpowers/specs/2026-08-15-device-id-workflow-log-output-design.md`.
- Produces: one consistent policy: device IDs are loggable operational identifiers; `UUREMOTE_CUSTOM_CODE`, account passwords, and other unapproved connection information remain non-loggable.

- [ ] **Step 1: Add the failing shared-policy test**

Add this method to `AgentInstructionContractTests`:

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

- [ ] **Step 2: Run the policy test and observe RED**

Run:

```powershell
python -m unittest tests.test_agent_work_environment.AgentInstructionContractTests.test_device_id_is_loggable_while_credentials_remain_secret -v
```

Expected: FAIL because the four instruction files still classify all remote-device connection information as sensitive and the READMEs do not describe the new output.

- [ ] **Step 3: Update the four shared instruction files**

Replace the broad sensitive-data bullet with this English policy in both English files:

```markdown
* Treat account passwords and UU Remote custom codes as secrets. A UU Remote device ID is a loggable operational identifier; other remote-device connection information remains sensitive unless an approved design says otherwise. In particular, `UUREMOTE_ACCOUNT_PASSWORD` and `UUREMOTE_CUSTOM_CODE` are secrets.
```

Use this meaning-equivalent Chinese policy in both Chinese files:

```markdown
* 将账户密码和 UU Remote custom codes 视为 secrets。UU Remote device ID 是可以记录到日志的 operational identifier；除非已批准设计另有规定，否则其他远程设备连接信息仍然是敏感信息。尤其是 `UUREMOTE_ACCOUNT_PASSWORD` 和 `UUREMOTE_CUSTOM_CODE` 属于 secrets。
```

Do not change the existing masking, step-scope, custom-code placeholder, operating-system security, or validation rules.

- [ ] **Step 4: Update the README pair and governing parity documents**

Add the following operator contract to the English README after the secret requirements:

```markdown
- Every successful run prints `DEVICE_ID=<complete device ID>` during launch readiness. The debug-level `0` production wait also prints `WAIT_CONNECTIONS DEVICE_ID=<complete device ID>` immediately before waiting.
```

Add this Chinese counterpart:

```markdown
- 每次成功 run 都会在 launch readiness 阶段打印 `DEVICE_ID=<完整 device ID>`。Debug level `0` 的 production wait 还会在开始等待前打印 `WAIT_CONNECTIONS DEVICE_ID=<完整 device ID>`。
```

In the 2026-08-14 parity design and plan pairs, replace every requirement that forbids device-ID logging with the exact contract above. Retain artifact redaction, custom-code masking, password secrecy, raw-CLI suppression, debug gates, and watcher behavior. Update old test examples so successful readiness expects the fixture ID while timeout/failure examples still reject raw attempt output.

- [ ] **Step 5: Run documentation GREEN and structure checks**

Run:

```powershell
python -m unittest tests.test_agent_work_environment -v
python -m json.tool .claude/settings.json
git diff --check
```

Expected: 8 policy/documentation tests pass, JSON parses, and diff check returns no findings.

- [ ] **Step 6: Commit the policy change**

```powershell
git add AGENTS.md AGENTS-zh_CN.md CLAUDE.md CLAUDE-zh_CN.md README.md README-zh_CN.md tests/test_agent_work_environment.py docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design-zh_CN.md docs/superpowers/plans/2026-08-14-windows-macos-functional-parity.md docs/superpowers/plans/2026-08-14-windows-macos-functional-parity-zh_CN.md
git commit -m "docs: classify UU Remote device IDs"
```

- [ ] **Step 7: Request independent policy review**

The reviewer must confirm the four instruction files are meaning-equivalent, custom codes/passwords remain secrets, every modified Markdown file has a valid counterpart/navigation line, and no runtime file changed. Do not start Task 2 until Critical and Important findings are zero.

---

### Task 2: Emit Validated Windows Device-ID Messages

**Files:**
- Modify: `tests/windows_helper_harness.ps1:1-120`
- Modify: `tests/test_windows_parity.py:200-225,350-420`
- Modify: `.github/workflows/windows.ps1:152-225,703-720`

**Interfaces:**
- Consumes: `Get-UURemoteDeviceId -CliPath <string> [-TimeoutMilliseconds <int>]`, existing bounded readiness polling, and `Invoke-ShutdownWaiter`.
- Produces: `Get-UURemoteLoggableDeviceId([string]) -> string`, `Write-UURemoteDeviceIdMessage -DeviceId <string> -Context <Readiness|Wait>`, launch output `DEVICE_ID=...` plus `DEVICE_ID_STATE=ready`, and wait output `WAIT_CONNECTIONS DEVICE_ID=...`.

- [ ] **Step 1: Change successful readiness expectations and add hostile-value RED tests**

Change the existing readiness success assertion to:

```python
self.assertEqual(
    [line for line in result.stdout.splitlines() if line.startswith("DEVICE_ID")],
    ["DEVICE_ID=device-id-fixture", "DEVICE_ID_STATE=ready"],
)
self.assertEqual(result.stdout.count("DEVICE_ID=device-id-fixture"), 1)
```

Add `import base64` and this controlled runner to `WindowsWaitBehaviorTests`. It dot-sources the real helper and replaces only the CLI/path boundary; Base64 preserves newlines, NUL, and DEL without embedding them in PowerShell source:

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

Add these controlled behavior tests:

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

`run_controlled_device_id_route` must invoke `Invoke-WindowsHelperRoute` from the real helper after overriding only `Get-UURemotePaths`, `Assert-UURemotePaths`, and `Get-UURemoteDeviceId`.

- [ ] **Step 2: Add a harness mode for unsafe readiness and observe RED**

Extend the harness `ValidateSet` with `readiness-unsafe-device`. In its CLI fixture return:

```powershell
return [pscustomobject]@{
    ExitCode = 0
    Output = @('device-id-fixture', 'FORGED_OUTPUT=true')
}
```

Add a test requiring exit `1`, no stdout, and no fixture/forged value in stderr. Run:

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessBehaviorTests tests.test_windows_parity.WindowsWaitBehaviorTests -v
```

Expected: RED because readiness still hides the valid ID, the wait route does not read an ID, and multiline values are not rejected before output.

- [ ] **Step 3: Implement the Windows validated message boundary**

Add these functions immediately after `Get-UURemoteDeviceId`:

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

In `Start-UURemoteAndWaitDevice`, replace the generic success-only write with:

```powershell
Write-UURemoteDeviceIdMessage -DeviceId $deviceId -Context 'Readiness'
Remove-Variable -Name deviceId -ErrorAction SilentlyContinue
return
```

Keep `Assert-UURemoteReadiness` generic so idempotency/finalization do not create extra device-ID messages.

- [ ] **Step 4: Add the wait message without changing watcher results**

Inside the real `wait-connections` route, after validating the seconds and before the zero-wait branch, obtain paths and the current ID, then emit the wait context:

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

Do not alter `self-test-wait-connections`; it stays independent of the installed CLI and its normalized diagnostic allowlist remains unchanged.

- [ ] **Step 5: Run Windows GREEN and compatibility checks**

Run:

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessContractTests tests.test_windows_parity.WindowsReadinessBehaviorTests tests.test_windows_parity.WindowsWaitBehaviorTests -v
python -m unittest tests.test_windows_parity -v
powershell.exe -NoLogo -NoProfile -Command "$errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.github/workflows/windows.ps1'),[ref]$null,[ref]$errors) | Out-Null; if($errors.Count){$errors | Out-String; exit 1}"
git diff --check
```

Expected: focused and full Windows parity tests pass under every discovered PowerShell runtime; parser and diff check pass. The existing interactive screenshot tests may run only on a Windows interactive desktop, not inside an isolated desktop sandbox.

- [ ] **Step 6: Verify secret preservation**

Run:

```powershell
rg -n "Write-(Output|Host).*UUREMOTE_CUSTOM_CODE|WAIT_CONNECTIONS.*CUSTOM_CODE|DEVICE_ID=.*CUSTOM_CODE" .github/workflows/windows.ps1 .github/workflows/windows.yml tests
```

Expected: no matches. Re-run the existing invalid custom-code and wait self-test exception-category tests; all custom-code fixtures remain absent.

- [ ] **Step 7: Commit and review Windows behavior**

```powershell
git add .github/workflows/windows.ps1 tests/windows_helper_harness.ps1 tests/test_windows_parity.py
git commit -m "feat: log Windows UU Remote device IDs"
```

The independent reviewer must execute the real helper with valid, multiline, control-character, zero-wait, and self-test inputs; confirm exactly one readiness message, the additional wait message, no raw failed output, unchanged watcher tokens, and PowerShell 5.1/pwsh compatibility. Do not start Task 3 until Critical and Important findings are zero.

---

### Task 3: Emit Equivalent macOS Device-ID Messages

**Files:**
- Create: `tests/test_macos_device_id_logging.sh`
- Modify: `tests/test_uuremote_wait.py:15-70`
- Modify: `tests/test_uuremote_desktop_finalization.py:35-65`
- Modify: `.github/workflows/apple.sh:1-20,190-285,1439-1465`
- Modify: `.github/workflows/macos.yml:65-100,137-155`

**Interfaces:**
- Consumes: installed CLI command `assist id` returning either a legacy single-line ID or the macOS JSON envelope, existing `wait_connections`, `run_shutdown_waiter`, and the debug-level `0` wait gate.
- Produces: `read_uuremote_device_id() -> validated stdout`, `emit_current_device_id(readiness|wait)`, early helper mode `report-device-id readiness`, launch output identical to Windows, and wait output identical to Windows.

- [ ] **Step 1: Write an executable Bash fixture and RED assertions**

Create `tests/test_macos_device_id_logging.sh` with a temporary executable CLI fixture. The fixture accepts `assist id` and selects output by `DEVICE_ID_FIXTURE_MODE`:

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

The harness must set `UUREMOTE_CLI_PATH` to the fixture and assert exact valid outputs:

```text
DEVICE_ID=device-id-fixture
DEVICE_ID_STATE=ready
```

and:

```text
WAIT_CONNECTIONS DEVICE_ID=device-id-fixture
WAIT_RESULT=timeout
```

It must also assert that empty, multiline, control, NUL, DEL, failed CLI output, malformed JSON, nonstandard JSON constants, false/missing/wrong-type envelope fields, duplicate keys, and unsafe extracted IDs return nonzero without exposing `device-id-fixture`, `FORGED_OUTPUT`, the raw JSON envelope, or `raw-cli-device-output`.

- [ ] **Step 2: Add Python workflow contracts and observe RED**

Update `WaitWorkflowContractTests` and the launch contract to require:

```python
launch = step_block(text(WORKFLOW_PATH), "Launch GameViewer")
self.assertIn("apple.sh report-device-id readiness", launch)

wait = step_block(text(WORKFLOW_PATH), "Wait connections")
self.assertIn("apple.sh wait-connections", wait)
self.assertIn("env.UUREMOTE_DEBUG == '0'", wait)
```

Run on macOS or with an available Bash runtime:

```bash
/bin/bash tests/test_macos_device_id_logging.sh
python -m unittest tests.test_uuremote_wait tests.test_uuremote_desktop_finalization -v
```

Expected: RED because `UUREMOTE_CLI_PATH`, `report-device-id`, byte-safe validation, and the wait message do not exist.

- [ ] **Step 3: Add a byte-safe, JSON-aware macOS CLI boundary**

Change the CLI assignment without changing its default:

```bash
CLI="${UUREMOTE_CLI_PATH:-$APP/Contents/Helpers/uuyc-cli}"
```

Add these functions before `wait_connections`:

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

JSON-looking output must never fall back to legacy single-line validation. The parser rejects malformed JSON, duplicate keys, a non-object root, false/missing/wrong-type required fields, nonstandard constants, and unsafe extracted IDs. Because the script already uses `set -o pipefail`, a nonzero CLI exit cannot be converted into a successful empty read by the Python validator.

- [ ] **Step 4: Add the early report route and wait output**

Before application/bootstrap preflight, add:

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

At the start of `wait_connections`, after seconds validation, require the wait message:

```bash
if ! emit_current_device_id wait; then
    echo "UU Remote wait device ID is unavailable." >&2
    return 1
fi
```

Keep the zero-wait and watcher result lines unchanged after this message. Keep `self_test_wait_connections` independent of the CLI.

- [ ] **Step 5: Delegate the macOS launch loop to the helper**

Replace the inline `assist id` capture with:

```bash
if .github/workflows/apple.sh report-device-id readiness
then
    device_id_ready=1
    break
fi
echo "UU Remote device ID is unavailable, retrying in 500 ms" >&2
```

Do not store or print raw CLI output in YAML. Preserve 120 attempts, the 500 ms interval, fail-closed exhaustion, step ordering, and every existing debug gate.

- [ ] **Step 6: Run macOS GREEN, syntax, and artifact-redaction checks**

Run:

```bash
/bin/bash tests/test_macos_device_id_logging.sh
/bin/bash tests/test_macos_diagnostic_redaction.sh
/bin/bash -n .github/workflows/apple.sh
python -m unittest tests.test_uuremote_wait tests.test_uuremote_desktop_finalization -v
```

Expected: valid readiness/wait messages pass exactly; hostile values fail without leakage; existing diagnostic artifact contains only sanitized state/exit fields; Bash syntax and Python tests pass.

- [ ] **Step 7: Commit and review macOS behavior**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_macos_device_id_logging.sh tests/test_uuremote_wait.py tests/test_uuremote_desktop_finalization.py
git commit -m "feat: log macOS UU Remote device IDs"
```

The independent reviewer must execute the real helper against the fixture modes, confirm the launch and wait prefixes match Windows exactly, verify the `debug_level=0` wait gate did not broaden, and confirm custom-code/account-password handling and diagnostic artifact content are unchanged. Do not start Task 4 until Critical and Important findings are zero.

---

### Task 4: Verify the Unified Contract and Run Live Acceptance

**Files:**
- Verify only: all files modified by Tasks 1-3.
- Update only if required by an observed contract mismatch: the corresponding English/Chinese pair and its executable test in the same fix commit.
- Coordination evidence: `.superpowers/sdd/2026-08-15-device-id-workflow-log-output/` (ignored; never commit).

**Interfaces:**
- Consumes: the exact launch/readiness and wait messages from Tasks 2 and 3, the unchanged artifact contract, existing repository secrets, and the existing GitHub Actions dispatch inputs.
- Produces: fresh local, independent-review, and live evidence that every debug level exposes a usable device ID while secrets remain absent.

- [ ] **Step 1: Run the complete local regression suite**

Run:

```powershell
python -m unittest discover -s tests -v
python -m json.tool .claude/settings.json
git diff --check e30a65b..HEAD
git status --short
```

Also run both Bash harnesses using `/bin/bash` on macOS or the installed Git Bash executable on Windows. Expected: every runnable test passes, only documented platform skips remain, JSON and diff checks pass, and the tracked worktree is clean.

- [ ] **Step 2: Run platform parser/runtime compatibility checks**

On Windows, parse `.github/workflows/windows.ps1` with Windows PowerShell 5.1 and run `tests.test_windows_parity` once with Windows PowerShell and once with a PATH-visible modern pwsh. Run interactive PNG tests outside an isolated desktop sandbox.

On macOS, run `/bin/bash -n .github/workflows/apple.sh`, the device-ID Bash fixture, the diagnostic-redaction Bash fixture, and the native AppKit watcher self-test.

Expected: both PowerShell editions, Bash syntax/behavior, real PNG capture, and the watcher self-tests pass.

- [ ] **Step 3: Run targeted secret and output scans**

Run:

```powershell
rg -n "DEVICE_ID=|WAIT_CONNECTIONS DEVICE_ID=" .github/workflows tests README.md README-zh_CN.md docs/superpowers
rg -n "Write-(Output|Host).*CUSTOM_CODE|echo .*CUSTOM_CODE|assist set-code.*\$|--reset-custom-code.*Write" .github/workflows tests
```

Expected: device-ID value output occurs only in the approved readiness and wait boundaries plus tests/docs; no custom-code or account-password value output exists. Manually confirm artifacts are not populated with a device-ID text file.

- [ ] **Step 4: Request final whole-branch review**

The reviewer must compare `1fee8c7..HEAD` with the approved 2026-08-15 spec, inspect both platform implementations and all policy files, and report Critical/Important/Minor findings. Critical and Important must be zero before any live dispatch. Minor findings must be either fixed in a focused Conventional Commit or explicitly recorded with user approval.

- [ ] **Step 5: Push the reviewed branch and dispatch the automatic live matrix**

With current user authorization, push `codex/windows-macos-functional-parity`, then manually dispatch:

1. Windows `debug_level=0`, `wait_connections_seconds=0`.
2. Windows `debug_level=1`, `wait_connections_seconds=0`.
3. Windows `debug_level=2`, `wait_connections_seconds=0`.
4. Windows `debug_level=3`, `wait_connections_seconds=0`.
5. macOS `debug_level=0`, `wait_connections_seconds=0`.
6. macOS `debug_level=1`, `wait_connections_seconds=0`.

For every successful run, inspect the launch step for exactly one `DEVICE_ID=<value>` immediately followed by `DEVICE_ID_STATE=ready`. For both debug-level `0` runs, inspect `Wait connections` for `WAIT_CONNECTIONS DEVICE_ID=<value>` before exact `WAIT_RESULT=timeout`. Confirm debug levels `1`-`3` do not execute the wait step.

- [ ] **Step 6: Inspect live artifacts and secret handling**

Download debug artifacts only to an exact temporary directory. Confirm the existing names/file counts, inspect representative screenshots for unexpected foreground UU Remote/System Settings windows, and scan text artifacts for custom-code/account-password values. Device IDs may appear in designated workflow logs but must not be added as a diagnostic text file. Delete the exact downloaded ZIPs and temporary extraction directories after inspection; retain GitHub artifacts.

- [ ] **Step 7: Run the manual mobile-client and shutdown/restart acceptance**

Dispatch a Windows debug-level `0` run with a user-approved positive wait duration. Tell the user the run has entered `Wait connections`; the user copies the visible device ID and connects with the separately held custom code. Record only whether connection succeeded, never the custom code.

The executable injected shutdown-wait self-test is the deterministic acceptance for exact `WAIT_RESULT=shutdown/restart` output and the cleanup contract. Run it before live acceptance and require it to pass.

Live acceptance requires a successful mobile-client connection and observation of the requested real shutdown/offline effect. Run a separate positive-wait acceptance for shutdown/restart. The user initiates the remote shutdown/restart action; the agent must not issue an operating-system shutdown command.

Final GitHub log, result, and cleanup evidence after real shutdown are best-effort because the runner may lose networking before reporting them. Missing post-shutdown reporting must not be treated as a watcher failure and does not block acceptance when the deterministic self-test has passed and the live connection and shutdown/offline effect were observed.

- [ ] **Step 8: Final verification and handoff**

Re-run the complete local suite, bilingual navigation/counterpart checks, parser/runtime checks, custom-code/password scans, `git diff --check e30a65b..HEAD`, and clean-status check. Do not create an empty verification commit. Use `superpowers:verification-before-completion`, then `superpowers:finishing-a-development-branch` to present integration options; do not create a PR or merge without the user's explicit choice.
