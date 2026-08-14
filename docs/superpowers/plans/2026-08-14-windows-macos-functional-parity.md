# Windows and macOS Functional Parity Implementation Plan

[English](2026-08-14-windows-macos-functional-parity.md) | [简体中文](2026-08-14-windows-macos-functional-parity-zh_CN.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Windows UU Remote workflow the approved macOS-equivalent public contract, secure custom-code handling, diagnostics, idempotency, and shutdown-aware wait without changing Windows account or operating-system security policy.

**Architecture:** Keep GitHub Actions orchestration in the two workflow files and platform behavior in dedicated helpers. Add a PowerShell Windows helper and a native C# shutdown watcher while retaining the existing Bash/Swift macOS implementation; align their public inputs, debug semantics, result tokens, and diagnostic artifact.

**Tech Stack:** GitHub Actions YAML, PowerShell 7, C# with Windows Forms/Win32 messages, Bash, Swift/AppKit, Python `unittest`.

## Global Constraints

- `debug_level` is a required choice with default `0` and exact options `0`, `1`, `2`, `3`.
- `wait_connections_seconds` is a required number with default `300` and valid inclusive range `0` through `21000`.
- `UUREMOTE_CUSTOM_CODE` is step-scoped, required, masked before use, never logged, and valid only when it matches `^[A-Za-z0-9]{8,16}$`.
- Windows must not consume `UUREMOTE_ACCOUNT_PASSWORD` or change user, Administrator, autologin, UAC, firewall, SSH, or account policy.
- Do not invent a Windows equivalent of `assist allow on`; use only capabilities proven by the installed CLI.
- Debug levels are cumulative: `0` production wait, `1` final diagnostics, `2` idempotency, `3` idempotency plus 20 live samples at 15-second intervals.
- Both platforms use artifact name `uuremote-diagnostics`; debug level `0` creates and uploads no diagnostic artifact.
- Wait results are exactly `WAIT_RESULT=timeout` and `WAIT_RESULT=shutdown/restart`.
- Runtime retries are bounded; device-ID readiness has a 60-second deadline.
- Automated tests may assert machine-readable YAML structure. PowerShell and C# behavior tests must execute the real helper or watcher and assert outputs, exit codes, or filesystem effects; they must not use private source tokens as behavior proxies.
- Native GUI details that cannot be exercised safely on the local host are verified by focused code review and the live-validation matrix, not by source-text change detectors.
- All source, workflow, configuration, and test comments are English.
- Update English documentation first and keep the Simplified Chinese counterpart meaning-equivalent in the same commit.
- Use red-green-refactor for every runtime behavior change and commit with Conventional Commits.

## File structure

- `.github/workflows/windows.yml`: Windows orchestration, inputs, conditions, and step-scoped secret injection.
- `.github/workflows/windows.ps1`: Windows validation, readiness, custom-code, diagnostics, idempotency, and wait orchestration.
- `.github/workflows/uuremote-shutdown-wait.cs`: native hidden-window message loop for Windows shutdown/restart observation.
- `.github/workflows/macos.yml`: existing macOS orchestration with aligned public artifact and sensitive-output policy.
- `.github/workflows/apple.sh`: existing macOS implementation with aligned diagnostic directory.
- `tests/test_windows_parity.py`: cross-workflow and Windows helper/watcher contracts and Windows behavior tests.
- `tests/windows_helper_harness.ps1`: controlled external-boundary harness that dot-sources the real Windows helper for bounded readiness tests without installing or launching UU Remote.
- `tests/test_uuremote_desktop_finalization.py`: macOS artifact and sensitive-output contract updates plus Bash platform gates.
- `tests/test_uuremote_host_bootstrap.py`: Bash-only behavior platform gate.
- `tests/test_uuremote_wait.py`: Bash-only behavior platform gate and shared wait-result assertions.
- `README.md` and `README-zh_CN.md`: current aligned workflow contract and validation instructions.

---

### Task 1: Align the Windows dispatch and secret contract

**Files:**
- Create: `tests/test_windows_parity.py`
- Modify: `.github/workflows/windows.yml`

**Interfaces:**
- Consumes: the existing Windows installer, launcher path, CLI path, and current `--device-id` and `--reset-custom-code` commands.
- Produces: matching dispatch inputs, job-level `UUREMOTE_DEBUG` and `UUREMOTE_WAIT_CONNECTIONS_SECONDS`, and a separate step-scoped custom-code step that later tasks delegate to `windows.ps1`.

- [ ] **Step 1: Write the failing workflow contract tests**

Create helpers that read both workflows and extract a named step. Add tests with these exact assertions:

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

- [ ] **Step 2: Run the focused tests and observe RED**

Run:

```powershell
python -m unittest tests.test_windows_parity.SharedWorkflowContractTests -v
```

Expected: both tests fail because Windows has no inputs or step-scoped secret and still contains the old literal.

- [ ] **Step 3: Implement the minimum working workflow contract**

Add the same input definitions and job environment used by macOS. Move custom-code assignment out of `Launch GameViewer` into `Configure UU Remote custom code`. The step must validate presence, mask the value, invoke the existing CLI via a variable, suppress CLI output, check `$LASTEXITCODE`, and remove the environment variable:

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

Remove the fixed sleep from the launch loop. Add a temporary `Wait connections` step gated by debug level `0`; validate an integer in range before `Start-Sleep`. Task 3 replaces this temporary wait with the watcher helper.

- [ ] **Step 4: Run focused and security checks and observe GREEN**

Run:

```powershell
python -m unittest tests.test_windows_parity.SharedWorkflowContractTests -v
rg -n --fixed-strings "johnDOE123" .github tests README.md README-zh_CN.md
```

Expected: the tests pass; `rg` may find only a deliberate negative assertion in a test and must find no workflow occurrence.

- [ ] **Step 5: Commit**

```powershell
git add .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: align Windows workflow interface"
```

---

### Task 2: Add Windows validation and secure custom-code helper modes

**Files:**
- Create: `.github/workflows/windows.ps1`
- Modify: `.github/workflows/windows.yml`
- Modify: `tests/test_windows_parity.py`

**Interfaces:**
- Consumes: mode in positional argument 0, remaining string arguments, `UUREMOTE_CUSTOM_CODE`, and the fixed install root `C:\Program Files\Netease\GameViewer`.
- Produces: `Test-UURemoteCustomCode`, `Test-WaitSeconds`, `Get-UURemotePaths`, `Set-UURemoteCustomCode`, and script modes `validate-custom-code`, `validate-wait-seconds`, and `set-custom-code`.

- [ ] **Step 1: Write failing helper behavior tests**

Add a subprocess helper and tests. The tests must never include a real secret:

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

- [ ] **Step 2: Run tests and observe RED**

Run:

```powershell
python -m unittest tests.test_windows_parity.WindowsValidationBehaviorTests -v
```

Expected: error or failure because `windows.ps1` does not exist.

- [ ] **Step 3: Implement validation and custom-code modes**

Start the helper with strict error behavior and exact routing:

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

`Set-UURemoteCustomCode` validates the environment value, verifies the CLI path, invokes `--reset-custom-code`, discards command output, checks the exit code, and emits only `CUSTOM_CODE_STATE=configured`. Each validation route exits `0` or `2` explicitly. Unknown modes exit `2` with a generic usage error.

Update the workflow custom-code step to call:

```powershell
.github/workflows/windows.ps1 validate-custom-code
.github/workflows/windows.ps1 set-custom-code
Remove-Item Env:\UUREMOTE_CUSTOM_CODE -ErrorAction SilentlyContinue
```

- [ ] **Step 4: Run focused tests and syntax checks and observe GREEN**

```powershell
python -m unittest tests.test_windows_parity.WindowsValidationBehaviorTests -v
pwsh -NoProfile -Command '$errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile(".github/workflows/windows.ps1", [ref]$null, [ref]$errors); if ($errors) { $errors; exit 1 }'
```

Expected: all tests pass and the parser exits `0`.

- [ ] **Step 5: Commit**

```powershell
git add .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: secure Windows UU Remote custom code"
```

---

### Task 3: Implement the native Windows shutdown-aware wait

**Files:**
- Create: `.github/workflows/uuremote-shutdown-wait.cs`
- Modify: `.github/workflows/windows.ps1`
- Modify: `.github/workflows/windows.yml`
- Modify: `tests/test_windows_parity.py`

**Interfaces:**
- Consumes: `ShutdownWaiter.Run(int seconds, string injectedEvent)` with injected values `none`, `ordinary`, and `shutdown`.
- Produces: exact strings `WAIT_RESULT=timeout` and `WAIT_RESULT=shutdown/restart`; helper modes `self-test-wait-connections` and `wait-connections SECONDS`.

- [ ] **Step 1: Write failing wait behavior tests**

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

- [ ] **Step 2: Run the wait tests and observe RED**

```powershell
python -m unittest tests.test_windows_parity.WindowsWaitBehaviorTests -v
```

Expected: failures because the executable wait modes do not exist.

- [ ] **Step 3: Implement the watcher and helper orchestration**

Implement namespace `UURemote` with public static class `ShutdownWaiter`. Its internal `NativeWindow` creates a hidden top-level handle, handles `WM_QUERYENDSESSION = 0x0011`, records `shutdown/restart`, sets `m.Result = new IntPtr(1)`, and exits the Windows Forms message loop without cancelling shutdown. A Forms timer records `timeout` after `seconds`. Injected `ordinary` posts a private no-op message; injected `shutdown` posts `WM_QUERYENDSESSION` to the watcher handle.

The public method is exact:

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

In PowerShell, load the source with `Add-Type -Path` only after validating a positive wait. Route zero directly to `WAIT_RESULT=timeout`. Wrap watcher invocation in `try/finally`; remove loaded event subscribers and temporary resources owned by the helper. The self-test requires these exact outcomes:

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

Replace the temporary workflow sleep with `windows.ps1 wait-connections "$env:UUREMOTE_WAIT_CONNECTIONS_SECONDS"`. Add diagnostic-only self-test before installation.

- [ ] **Step 4: Run behavior and contract tests and observe GREEN**

```powershell
python -m unittest tests.test_windows_parity.WindowsWaitBehaviorTests tests.test_windows_parity.WindowsValidationBehaviorTests -v
```

Expected: all tests pass in approximately four seconds; no real shutdown occurs.

- [ ] **Step 5: Commit**

```powershell
git add .github/workflows/uuremote-shutdown-wait.cs .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: add Windows shutdown-aware wait"
```

---

### Task 4: Move launch and unattended-readiness checks into the helper

**Files:**
- Modify: `.github/workflows/windows.ps1`
- Modify: `.github/workflows/windows.yml`
- Modify: `tests/test_windows_parity.py`
- Create: `tests/windows_helper_harness.ps1`

**Interfaces:**
- Consumes: `Get-UURemotePaths`, installed `GameViewer.exe`, installed `uuyc-cli.exe`, and a 60-second deadline.
- Produces: `Get-UURemoteDeviceId`, `Start-UURemoteAndWaitDevice`, `Assert-UURemoteReadiness`, modes `launch-and-wait-device` and `verify-unattended-readiness`, and sanitized tokens `DEVICE_ID_STATE=ready` and `UNATTENDED_READINESS=verified`.

- [ ] **Step 1: Write failing bounded-readiness behavior tests**

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

    def test_readiness_retries_transient_failures_without_exposing_device_id(self):
        result = self.run_harness("readiness-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DEVICE_ID_STATE=ready", result.stdout)
        self.assertIn("ATTEMPTS=3", result.stdout)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_readiness_timeout_is_bounded_and_sanitized(self):
        result = self.run_harness("readiness-timeout")
        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
```

- [ ] **Step 2: Run the readiness tests and observe RED**

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessContractTests tests.test_windows_parity.WindowsReadinessBehaviorTests -v
```

Expected: failures because launch logic remains inline and the helper modes are absent.

- [ ] **Step 3: Implement bounded readiness**

`Get-UURemoteDeviceId` invokes `--device-id`, returns a trimmed non-empty string only when the CLI exits zero, and never writes it. `Start-UURemoteAndWaitDevice` accepts internal parameters `TimeoutSeconds = 60` and `PollMilliseconds = 500`, verifies both paths, reuses `Get-Process -Name GameViewer`, otherwise starts the launcher, and polls until the deadline. The runtime route always uses the defaults. Success prints only `DEVICE_ID_STATE=ready`; deadline failure throws a generic message with the attempt count.

The harness dot-sources the real helper without executing its route, replaces only the external process/CLI boundaries with deterministic functions, and calls `Start-UURemoteAndWaitDevice` with `TimeoutSeconds = 1` and `PollMilliseconds = 10`. `readiness-success` returns the fixture only on attempt 3 and prints `ATTEMPTS=3`; `readiness-timeout` never returns an ID and exits `1`. The harness must not copy readiness logic.

`Assert-UURemoteReadiness` verifies the launcher and CLI paths, requires a running `GameViewer` process, and requires `Get-UURemoteDeviceId` to return non-empty. It prints only `UNATTENDED_READINESS=verified`. It must not invoke undocumented commands or modify system security settings.

Replace the inline launch loop with the helper mode and add the named readiness step after custom-code configuration.

- [ ] **Step 4: Run focused tests and observe GREEN**

```powershell
python -m unittest tests.test_windows_parity.WindowsReadinessContractTests tests.test_windows_parity.WindowsReadinessBehaviorTests tests.test_windows_parity.SharedWorkflowContractTests -v
```

Expected: all tests pass; workflow contains no device ID output.

- [ ] **Step 5: Commit**

```powershell
git add .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py tests/windows_helper_harness.ps1
git commit -m "feat: add bounded Windows readiness checks"
```

---

### Task 5: Add Windows desktop finalization, diagnostics, and idempotency

**Files:**
- Modify: `.github/workflows/windows.ps1`
- Modify: `.github/workflows/windows.yml`
- Modify: `tests/test_windows_parity.py`

**Interfaces:**
- Consumes: `${RUNNER_TEMP}`, `UUREMOTE_DEBUG`, step-scoped `UUREMOTE_CUSTOM_CODE`, and readiness/custom-code functions.
- Produces: `Minimize-UURemoteWindows`, `Save-DesktopSnapshot`, `Invoke-UURemoteIdempotencyCheck`, modes `finalize-desktop`, `snapshot LABEL`, and `verify-idempotency`, plus `FINAL_DESKTOP_STATE=ready`.

- [ ] **Step 1: Write failing diagnostic and idempotency contracts**

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

- [ ] **Step 2: Run diagnostic tests and observe RED**

```powershell
python -m unittest tests.test_windows_parity.WindowsDiagnosticContractTests tests.test_windows_parity.WindowsDiagnosticBehaviorTests -v
```

Expected: failures because the steps and helper functions are absent.

- [ ] **Step 3: Implement state-preserving diagnostics**

Use `Add-Type` for a small `ShowWindowAsync`/`IsIconic` Win32 interop type. `Minimize-UURemoteWindows` iterates existing `GameViewer` processes, minimizes non-zero main-window handles with command `6`, then verifies observable handles are iconic. No existing top-level window is a valid finalized state. Print `FINAL_DESKTOP_STATE=ready` only after verification.

`Save-DesktopSnapshot` accepts only labels matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`, creates `${RUNNER_TEMP}/uuremote-diagnostics`, reads `SystemInformation.VirtualScreen`, and uses a `System.Drawing.Bitmap` plus `Graphics.CopyFromScreen` inside `try/finally` disposal. It writes `<label>.png` and never activates an application.

`Invoke-UURemoteIdempotencyCheck` calls readiness, applies the same environment custom code, verifies readiness again, and finalizes the desktop. It does not install, alter accounts, or launch duplicates.

Add workflow steps with exact gates:

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

The live step loops exactly 20 times, formats labels `live-01` through `live-20`, calls the snapshot mode, and sleeps 15 seconds between samples. The finalization step always minimizes; it calls `snapshot final-desktop` only for non-zero debug.

- [ ] **Step 4: Run focused tests and observe GREEN**

```powershell
python -m unittest tests.test_windows_parity -v
```

Expected: all Windows parity tests pass.

- [ ] **Step 5: Commit**

```powershell
git add .github/workflows/windows.ps1 .github/workflows/windows.yml tests/test_windows_parity.py
git commit -m "feat: align Windows diagnostics and idempotency"
```

---

### Task 6: Align macOS public diagnostics and make tests platform-correct

**Files:**
- Modify: `.github/workflows/macos.yml`
- Modify: `.github/workflows/apple.sh`
- Modify: `tests/test_windows_parity.py`
- Modify: `tests/test_uuremote_desktop_finalization.py`
- Modify: `tests/test_uuremote_host_bootstrap.py`
- Modify: `tests/test_uuremote_wait.py`

**Interfaces:**
- Consumes: established macOS behavior and the shared workflow contract from Tasks 1 through 5.
- Produces: common artifact name/path, no device-ID logging, cross-workflow ordering checks, and clean platform skips for `/bin/bash`/AppKit behavior tests.

- [ ] **Step 1: Write failing cross-platform and platform-gate tests**

Extend `SharedWorkflowContractTests`:

```python
    def test_both_workflows_use_the_shared_artifact_contract(self):
        for path in (MACOS_WORKFLOW, WINDOWS_WORKFLOW):
            workflow = text(path)
            self.assertIn("name: uuremote-diagnostics", workflow)
            self.assertIn("${{ runner.temp }}/uuremote-diagnostics/", workflow)

```

Add `BASH_AVAILABLE = Path("/bin/bash").exists()` and `@unittest.skipUnless(BASH_AVAILABLE, "requires /bin/bash")` to exactly these behavior classes:

- `CustomCodeValidationTests`
- `DesktopPreferenceBehaviorTests`
- `ScriptRoutingAndCodecTests`
- `WaitShellContractTests`

Keep `WaitWatcherBehaviorTests` under its existing Darwin gate. Do not skip source/workflow contract classes.

- [ ] **Step 2: Run tests and observe RED**

```powershell
python -m unittest tests.test_windows_parity.SharedWorkflowContractTests -v
python -m unittest discover -s tests -v
```

Expected before implementation: the shared artifact/device-output assertions fail; on Windows the full suite still reports `/bin/bash` errors.

- [ ] **Step 3: Align macOS and apply exact platform gates**

Change the macOS artifact name to `uuremote-diagnostics`, its workflow path to `${{ runner.temp }}/uuremote-diagnostics/`, and `apple.sh` evidence directory to `${RUNNER_TEMP:-/tmp}/uuremote-diagnostics`. Replace the device-ID value output with generic `DEVICE_ID_STATE=ready` while retaining the non-empty check.

Update existing artifact assertions and apply the four exact Bash gates listed in Step 1. Do not skip static contract tests that run correctly on Windows.

Remove device-ID value logging from both workflows. This sensitive-output requirement is checked by the task reviewer and by the explicit security scan below; it is not represented as a source-token behavior test.

- [ ] **Step 4: Run the full local suite and observe GREEN**

```powershell
python -m unittest discover -s tests -v
rg -n -e 'echo "deviceId:' -e 'Write-Host "deviceId:' .github/workflows/macos.yml .github/workflows/windows.yml
```

Expected on Windows: all runnable tests pass; Bash/AppKit-only behavior tests are reported as skips, not errors; the security scan has no matches. Expected on macOS: Bash tests execute normally and AppKit behavior remains active.

- [ ] **Step 5: Commit**

```powershell
git add .github/workflows/macos.yml .github/workflows/apple.sh tests/test_windows_parity.py tests/test_uuremote_desktop_finalization.py tests/test_uuremote_host_bootstrap.py tests/test_uuremote_wait.py
git commit -m "refactor: align UU Remote workflow contracts"
```

---

### Task 7: Update bilingual entry-point documentation and run final local verification

**Files:**
- Modify: `README.md`
- Modify: `README-zh_CN.md`
- Test: `tests/test_agent_work_environment.py`
- Test: `tests/test_windows_parity.py`

**Interfaces:**
- Consumes: the final shared workflow contract and platform exceptions.
- Produces: accurate bilingual operator documentation and a locally verified branch ready for code review and external validation.

- [ ] **Step 1: Update the English README, then its Simplified Chinese counterpart**

State these exact facts in both languages:

- Both workflows expose `debug_level` values `0` through `3` and `wait_connections_seconds` from `0` through `21000`, default `300`.
- Both workflows require `UUREMOTE_CUSTOM_CODE`; only macOS requires `UUREMOTE_ACCOUNT_PASSWORD`.
- Debug levels have the cumulative meanings defined in the design.
- Both platforms upload `uuremote-diagnostics` only when debug is non-zero.
- Windows does not change user, Administrator, autologin, UAC, firewall, or SSH policy.
- Local validation uses `python -m unittest discover -s tests -v`; platform-only behavior is skipped only on incompatible hosts.
- End-to-end acceptance requires repository secrets and a manually dispatched platform workflow.

- [ ] **Step 2: Run bilingual and workflow tests**

```powershell
python -m unittest tests.test_agent_work_environment tests.test_windows_parity -v
```

Expected: all tests pass; every root and `docs/**` Markdown file has one counterpart and exact navigation spacing.

- [ ] **Step 3: Run full local verification**

```powershell
python -m unittest discover -s tests -v
python -m json.tool .claude/settings.json
git diff --check b1d194b..HEAD
git status --short
```

Expected: all applicable tests pass, platform-only tests are skips rather than errors, JSON parsing succeeds, diff-check has no output, and status shows only the intended tracked changes before commit.

- [ ] **Step 4: Review security and scope mechanically**

```powershell
rg -n --fixed-strings "johnDOE123" .github README.md README-zh_CN.md
rg -n -e "UUREMOTE_ACCOUNT_PASSWORD" .github/workflows/windows.yml .github/workflows/windows.ps1
git diff --name-only b1d194b..HEAD
```

Expected: no active workflow literal, no Windows account-password reference, and only files named by this plan.

- [ ] **Step 5: Commit**

```powershell
git add README.md README-zh_CN.md
git commit -m "docs: document unified UU Remote workflows"
```

---

## External live-validation checkpoint

Do not dispatch workflows or expose repository secrets without current user authorization. After task reviews and final branch review are clean, request authorization and run this matrix through GitHub Actions:

1. Windows with `debug_level=1`, `wait_connections_seconds=0`: require generic custom-code success, `FINAL_DESKTOP_STATE=ready`, artifact upload, a clean final screenshot, and a real mobile-client connection.
2. Windows with `debug_level=2`, `wait_connections_seconds=0`: require the second pass to report readiness and finalization without duplicate application instances.
3. Windows with `debug_level=3`, `wait_connections_seconds=0`: require 20 files named `live-01.png` through `live-20.png` and no foreground UU Remote window.
4. Windows with `debug_level=0`, `wait_connections_seconds=5`: require `WAIT_RESULT=timeout` and no diagnostic artifact.
5. A dedicated Windows remote shutdown or restart run: require `WAIT_RESULT=shutdown/restart` when the workflow remains alive long enough to record it; if GitHub terminates the runner first, record the platform limitation without weakening shutdown behavior.
6. macOS smoke runs at debug levels `0` and `1`: verify the renamed artifact contract and absence of device-ID values in logs while preserving established permissions and desktop finalization.

If a live run fails, use `superpowers:systematic-debugging`, preserve only sanitized logs/artifacts, add a failing repository test that captures the discovered contract, and repeat review before another live run.

## Final branch gate

Request a whole-branch review against `docs/superpowers/specs/2026-08-14-windows-macos-functional-parity-design.md`. Resolve all Critical and Important findings. Then use `superpowers:verification-before-completion` and `superpowers:finishing-a-development-branch`; never merge or push without the user's integration choice.
