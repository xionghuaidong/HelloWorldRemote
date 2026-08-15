import base64
import os
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
MACOS_WORKFLOW = ROOT / ".github/workflows/macos.yml"
WINDOWS_WORKFLOW = ROOT / ".github/workflows/windows.yml"
WINDOWS_HELPER = ROOT / ".github/workflows/windows.ps1"
WINDOWS_HELPER_HARNESS = ROOT / "tests/windows_helper_harness.ps1"


def path_powershell_runtimes() -> tuple[str, ...]:
    runtimes = []
    for command in ("pwsh", "powershell.exe", "powershell"):
        runtime = shutil.which(command)
        if runtime is not None and runtime not in runtimes:
            runtimes.append(runtime)
    return tuple(runtimes)


POWERSHELL_RUNTIMES = path_powershell_runtimes()
POWERSHELL = POWERSHELL_RUNTIMES[0] if POWERSHELL_RUNTIMES else None


def powershell_runtime_available(powershell_path: str | None) -> bool:
    return powershell_path is not None


def native_windows_capability_available(system_name: str, powershell_path: str | None) -> bool:
    return system_name == "Windows" and powershell_runtime_available(powershell_path)


POWERSHELL_AVAILABLE = powershell_runtime_available(POWERSHELL)
WINDOWS_NATIVE_CAPABILITY_AVAILABLE = native_windows_capability_available(
    platform.system(), POWERSHELL
)


class WindowsCapabilitySignalTests(unittest.TestCase):
    def test_powershell_and_native_windows_availability_are_distinct(self):
        self.assertTrue(powershell_runtime_available("pwsh"))
        self.assertFalse(powershell_runtime_available(None))
        self.assertTrue(native_windows_capability_available("Windows", "pwsh"))
        self.assertFalse(native_windows_capability_available("Linux", "pwsh"))
        self.assertFalse(native_windows_capability_available("Windows", None))


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]


def run_windows_helper(
    mode: str,
    *args: str,
    environment: dict[str, str] | None = None,
    powershell: str | None = None,
):
    runtime = POWERSHELL if powershell is None else powershell
    if runtime is None:
        raise RuntimeError("A PowerShell runtime is required to run the Windows helper tests.")

    return subprocess.run(
        [
            runtime,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(WINDOWS_HELPER),
            mode,
            *args,
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


def run_windows_script(script: str, environment: dict[str, str] | None = None):
    if POWERSHELL is None:
        raise RuntimeError("A PowerShell runtime is required to run the Windows helper tests.")

    return subprocess.run(
        [
            POWERSHELL,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ],
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


class SharedWorkflowContractTests(unittest.TestCase):
    def test_both_workflows_use_the_shared_artifact_contract(self):
        for path in (MACOS_WORKFLOW, WINDOWS_WORKFLOW):
            workflow = text(path)
            self.assertIn("name: uuremote-diagnostics", workflow)
            self.assertIn("${{ runner.temp }}/uuremote-diagnostics/", workflow)

    def test_both_workflows_keep_the_shared_lifecycle_order(self):
        workflow_steps = {
            MACOS_WORKFLOW: (
                "Checkout",
                "Test shutdown-aware wait",
                "Configure macOS host",
                "Install GameViewer",
                "Launch GameViewer",
                "Configure UU Remote custom code",
                "Configure UU Remote permissions",
                "Verify permission idempotency",
                "Wait connections",
                "Upload UU Remote diagnostics",
            ),
            WINDOWS_WORKFLOW: (
                "Checkout",
                "Test shutdown-aware wait",
                "Install GameViewer",
                "Launch GameViewer",
                "Configure UU Remote custom code",
                "Verify unattended readiness",
                "Verify configuration idempotency",
                "Finalize desktop and capture diagnostics",
                "Wait connections",
                "Upload UU Remote diagnostics",
            ),
        }

        for path, steps in workflow_steps.items():
            workflow = text(path)
            positions = [workflow.index(f"      - name: {step}") for step in steps]
            self.assertEqual(positions, sorted(positions), path.name)

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


@unittest.skipUnless(POWERSHELL_AVAILABLE, "requires a PowerShell runtime")
class WindowsValidationBehaviorTests(unittest.TestCase):
    def test_custom_code_accepts_only_ascii_alphanumeric_8_through_16(self):
        for value in ("Abcdef12", "12345678", "A1b2C3d4E5f6G7h8"):
            environment = os.environ.copy()
            environment["UUREMOTE_CUSTOM_CODE"] = value
            self.assertEqual(
                run_windows_helper("validate-custom-code", environment=environment).returncode,
                0,
            )

    def test_invalid_custom_code_returns_two_without_echoing_the_value(self):
        for value in ("", "Abc1234", "A" * 17, "Abcd-123", "Abcd 123"):
            environment = os.environ.copy()
            environment["UUREMOTE_CUSTOM_CODE"] = value
            result = run_windows_helper("validate-custom-code", environment=environment)
            self.assertEqual(result.returncode, 2)
            if value:
                self.assertNotIn(value, result.stdout + result.stderr)

    def test_wait_validation_accepts_bounds_and_rejects_invalid_values(self):
        for value in ("0", "300", "21000"):
            self.assertEqual(run_windows_helper("validate-wait-seconds", value).returncode, 0)
        for value in ("-1", "21001", "1.5", "text", ""):
            self.assertEqual(run_windows_helper("validate-wait-seconds", value).returncode, 2)


class WindowsWaitBehaviorTests(unittest.TestCase):
    def run_real_injected_watcher(self, injected_event: str, seconds: int):
        helper = str(WINDOWS_HELPER).replace("'", "''")
        return run_windows_script(
            rf"""
. '{helper}'
Invoke-ShutdownWaiter -Seconds {seconds} -InjectedEvent '{injected_event}'
"""
        )

    def run_controlled_device_id_cli_route(self, device_id: str, seconds: str):
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
function Invoke-UURemoteDeviceIdCli {{
    param([string]$Path, [int]$TimeoutMilliseconds = 60000)
    return [pscustomobject]@{{
        ExitCode = 0
        Output = @($script:FixtureDeviceId)
        TimedOut = $false
    }}
}}
$script:HelperMode = 'wait-connections'
$script:Arguments = @('{seconds}')
Invoke-WindowsHelperRoute
"""
        )

    def test_wait_message_contains_current_device_id_before_zero_timeout(self):
        result = self.run_controlled_device_id_cli_route("device-id-fixture", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "WAIT_CONNECTIONS DEVICE_ID=device-id-fixture",
                "WAIT_RESULT=timeout",
            ],
        )

    def test_surrounding_ascii_spaces_are_normalized_before_logging(self):
        result = self.run_controlled_device_id_cli_route(
            "  device-id-fixture  \r\n",
            "0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "WAIT_CONNECTIONS DEVICE_ID=device-id-fixture",
                "WAIT_RESULT=timeout",
            ],
        )

    def test_multiline_device_id_fails_closed_without_log_injection(self):
        result = self.run_controlled_device_id_cli_route(
            "device-id-fixture\nFORGED_OUTPUT=true",
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
                result = self.run_controlled_device_id_cli_route(value, "0")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.strip(), "Shutdown-aware wait failed.")

    def test_unicode_control_character_fails_closed_without_log_injection(self):
        result = self.run_controlled_device_id_cli_route(
            "device-id-fixture\u0085FORGED_OUTPUT=true",
            "0",
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), "Shutdown-aware wait failed.")
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
        self.assertNotIn("FORGED_OUTPUT", result.stdout + result.stderr)

    def test_unicode_separator_fails_closed_without_log_injection(self):
        result = self.run_controlled_device_id_cli_route(
            "device-id-fixture\u2028FORGED_OUTPUT=true",
            "0",
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), "Shutdown-aware wait failed.")
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)
        self.assertNotIn("FORGED_OUTPUT", result.stdout + result.stderr)

    def test_cli_boundary_rejects_unsafe_trailing_characters_before_normalization(self):
        for value in (
            "device-id-fixture\u0085\r\n",
            "device-id-fixture\u2028\r\n",
            "device-id-fixture\r\n\r\n",
        ):
            with self.subTest(value=repr(value)):
                result = self.run_controlled_device_id_cli_route(value, "0")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr.strip(), "Shutdown-aware wait failed.")
                self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def run_self_test_with_injected_waiter(self, body: str):
        helper = str(WINDOWS_HELPER).replace("'", "''")
        return run_windows_script(
            f"""
. '{helper}'
function Invoke-ShutdownWaiter {{
    param([int]$Seconds, [string]$InjectedEvent)
    {body}
}}
$script:HelperMode = 'self-test-wait-connections'
$script:Arguments = @()
Invoke-WindowsHelperRoute
"""
        )

    @unittest.skipUnless(
        WINDOWS_NATIVE_CAPABILITY_AVAILABLE,
        "requires Windows and a PowerShell runtime",
    )
    def test_real_injected_watcher_distinguishes_logout_from_shutdown(self):
        cases = (
            ("logout", 1, "WAIT_RESULT=timeout"),
            ("shutdown", 2, "WAIT_RESULT=shutdown/restart"),
        )
        for injected_event, seconds, expected in cases:
            with self.subTest(injected_event=injected_event):
                result = self.run_real_injected_watcher(injected_event, seconds)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [expected])
                self.assertEqual(result.stderr, "")

    @unittest.skipUnless(
        WINDOWS_NATIVE_CAPABILITY_AVAILABLE,
        "requires Windows and a PowerShell runtime",
    )
    def test_injected_wait_self_test_passes(self):
        result = run_windows_helper("self-test-wait-connections")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shutdown-aware wait self-test passed", result.stdout)

    @unittest.skipUnless(POWERSHELL_AVAILABLE, "requires a PowerShell runtime")
    def test_self_test_passes_for_each_path_discovered_runtime(self):
        for runtime in POWERSHELL_RUNTIMES:
            with self.subTest(runtime=runtime):
                result = run_windows_helper("self-test-wait-connections", powershell=runtime)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("shutdown-aware wait self-test passed", result.stdout)

    @unittest.skipUnless(POWERSHELL_AVAILABLE, "requires a PowerShell runtime")
    def test_self_test_requires_logout_to_reach_timeout(self):
        result = self.run_self_test_with_injected_waiter(
            r"""
switch ($InjectedEvent) {
    'none' { 'WAIT_RESULT=timeout'; break }
    'ordinary' { 'WAIT_RESULT=timeout'; break }
    'logout' { 'WAIT_RESULT=shutdown/restart'; break }
    'shutdown' { 'WAIT_RESULT=shutdown/restart'; break }
}
"""
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "shutdown-aware wait self-test failed",
                "WAIT_SELF_TEST_TIMEOUT=timeout",
                "WAIT_SELF_TEST_ORDINARY=timeout",
                "WAIT_SELF_TEST_LOGOUT=shutdown/restart",
                "WAIT_SELF_TEST_SHUTDOWN=shutdown/restart",
            ],
        )
        self.assertEqual(result.stdout, "")

    @unittest.skipUnless(POWERSHELL_AVAILABLE, "requires a PowerShell runtime")
    def test_self_test_mismatch_reports_only_normalized_observations(self):
        result = self.run_self_test_with_injected_waiter(
            r"""
switch ($InjectedEvent) {
    'none' { 'WAIT_RESULT=timeout'; break }
    'ordinary' { 'device-id-fixture custom-code-fixture arbitrary-external-output'; break }
    'logout' { 'WAIT_RESULT=timeout'; break }
    'shutdown' { 'WAIT_RESULT=shutdown/restart'; break }
}
"""
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "shutdown-aware wait self-test failed",
                "WAIT_SELF_TEST_TIMEOUT=timeout",
                "WAIT_SELF_TEST_ORDINARY=unexpected",
                "WAIT_SELF_TEST_LOGOUT=timeout",
                "WAIT_SELF_TEST_SHUTDOWN=shutdown/restart",
            ],
        )
        self.assertEqual(result.stdout, "")
        for value in ("device-id-fixture", "custom-code-fixture", "arbitrary-external-output"):
            self.assertNotIn(value, result.stdout + result.stderr)

    @unittest.skipUnless(POWERSHELL_AVAILABLE, "requires a PowerShell runtime")
    def test_self_test_catch_reports_safe_exception_category_without_raw_message(self):
        result = self.run_self_test_with_injected_waiter(
            "throw [System.InvalidOperationException]::new('device-id-fixture custom-code-fixture arbitrary-external-output')"
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "shutdown-aware wait self-test failed",
                "WAIT_SELF_TEST_TIMEOUT=not-observed",
                "WAIT_SELF_TEST_ORDINARY=not-observed",
                "WAIT_SELF_TEST_LOGOUT=not-observed",
                "WAIT_SELF_TEST_SHUTDOWN=not-observed",
                "WAIT_SELF_TEST_EXCEPTION=invalid-operation",
            ],
        )
        self.assertEqual(result.stdout, "")
        for value in ("device-id-fixture", "custom-code-fixture", "arbitrary-external-output"):
            self.assertNotIn(value, result.stdout + result.stderr)

    @unittest.skipUnless(POWERSHELL_AVAILABLE, "requires a PowerShell runtime")
    def test_self_test_unwraps_real_method_invocation_exception_safely(self):
        result = self.run_self_test_with_injected_waiter(
            r"""
Add-Type @'
using System;
public static class WaiterFailureFixture {
    public static string Run() {
        throw new InvalidOperationException("device-id-fixture custom-code-fixture arbitrary-external-output");
    }
}
'@
[WaiterFailureFixture]::Run()
"""
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "shutdown-aware wait self-test failed",
                "WAIT_SELF_TEST_TIMEOUT=not-observed",
                "WAIT_SELF_TEST_ORDINARY=not-observed",
                "WAIT_SELF_TEST_LOGOUT=not-observed",
                "WAIT_SELF_TEST_SHUTDOWN=not-observed",
                "WAIT_SELF_TEST_EXCEPTION=method-invocation/invalid-operation",
            ],
        )
        self.assertEqual(result.stdout, "")
        for value in ("device-id-fixture", "custom-code-fixture", "arbitrary-external-output"):
            self.assertNotIn(value, result.stdout + result.stderr)


class WindowsWaitCompilationContractTests(unittest.TestCase):
    def test_core_watcher_compilation_adds_required_primitives_references(self):
        helper = text(WINDOWS_HELPER)
        start = helper.index("if ($null -eq ('UURemote.ShutdownWaiter' -as [type])) {")
        compilation = helper[start : helper.index("    try {", start)]

        self.assertIn("$references = @('System.Windows.Forms.dll')", compilation)
        self.assertIn("if ($PSVersionTable.PSEdition -eq 'Core')", compilation)
        self.assertIn("'System.Windows.Forms.Primitives.dll'", compilation)
        self.assertIn("'System.ComponentModel.Primitives.dll'", compilation)
        self.assertIn("Add-Type -Path $watcherSource -ReferencedAssemblies $references", compilation)


class WindowsReadinessContractTests(unittest.TestCase):
    def test_workflow_delegates_launch_and_readiness(self):
        workflow = text(WINDOWS_WORKFLOW)
        self.assertIn("      - name: Verify unattended readiness\n", workflow)
        launch = step_block(workflow, "Launch GameViewer")
        readiness = step_block(workflow, "Verify unattended readiness")
        self.assertIn("windows.ps1 launch-and-wait-device", launch)
        self.assertIn("windows.ps1 verify-unattended-readiness", readiness)
        self.assertLess(workflow.index("Launch GameViewer"), workflow.index("Configure UU Remote custom code"))
        self.assertLess(
            workflow.index("Configure UU Remote custom code"),
            workflow.index("Verify unattended readiness"),
        )


@unittest.skipUnless(POWERSHELL_AVAILABLE, "requires a PowerShell runtime")
class WindowsReadinessBehaviorTests(unittest.TestCase):
    def run_harness(self, mode: str):
        if POWERSHELL is None:
            self.skipTest("A PowerShell runtime is required to run the readiness harness.")

        return subprocess.run(
            [
                POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(WINDOWS_HELPER_HARNESS),
                mode,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_readiness_retries_transient_failures_and_reports_device_id_once(self):
        result = self.run_harness("readiness-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [line for line in result.stdout.splitlines() if line.startswith("DEVICE_ID")],
            ["DEVICE_ID=device-id-fixture", "DEVICE_ID_STATE=ready"],
        )
        self.assertEqual(result.stdout.count("DEVICE_ID=device-id-fixture"), 1)
        self.assertIn("ATTEMPTS=3", result.stdout)

    def test_readiness_timeout_is_bounded_and_sanitized(self):
        result = self.run_harness("readiness-timeout")
        self.assertEqual(result.returncode, 1)
        self.assertIn("timed out", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_unsafe_readiness_device_id_fails_closed_without_log_injection(self):
        result = self.run_harness("readiness-unsafe-device")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("device-id-fixture", result.stderr)
        self.assertNotIn("FORGED_OUTPUT", result.stderr)

    def test_hanging_cli_is_terminated_within_the_overall_deadline(self):
        started = time.monotonic()
        result = self.run_harness("readiness-cli-hang")
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 1)
        self.assertLess(elapsed, 5)
        self.assertIn("timed out", result.stderr.lower())
        self.assertIn("CLI_PROCESS_TERMINATED=true", result.stdout)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_direct_import_only_cannot_bypass_routing(self):
        result = run_windows_helper("launch-and-wait-device", "-ImportOnly")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("DEVICE_ID_STATE=ready", result.stdout)

    def test_unattended_readiness_requires_a_running_process(self):
        result = self.run_harness("unattended-no-process")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unattended readiness failed", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_unattended_readiness_requires_a_nonempty_device_id(self):
        result = self.run_harness("unattended-no-device")
        self.assertEqual(result.returncode, 1)
        self.assertIn("unattended readiness failed", result.stderr.lower())
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)

    def test_unattended_readiness_reports_only_sanitized_success(self):
        result = self.run_harness("unattended-success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UNATTENDED_READINESS=verified", result.stdout)
        self.assertNotIn("device-id-fixture", result.stdout + result.stderr)


class WindowsDiagnosticContractTests(unittest.TestCase):
    def test_debug_conditions_and_artifact_are_aligned(self):
        workflow = text(WINDOWS_WORKFLOW)
        idempotency = step_block(workflow, "Verify configuration idempotency")
        live = step_block(workflow, "Capture live diagnostics")
        upload = step_block(workflow, "Upload UU Remote diagnostics")

        self.assertIn("env.UUREMOTE_DEBUG == '2' || env.UUREMOTE_DEBUG == '3'", idempotency)
        self.assertIn("env.UUREMOTE_DEBUG == '3'", live)
        self.assertIn("always() && env.UUREMOTE_DEBUG != '0'", upload)
        self.assertIn("name: uuremote-diagnostics", upload)
        self.assertIn("${{ runner.temp }}/uuremote-diagnostics/", upload)

    def test_finalization_and_live_sampling_delegate_to_the_helper(self):
        workflow = text(WINDOWS_WORKFLOW)
        finalization = step_block(workflow, "Finalize desktop and capture diagnostics")
        live = step_block(workflow, "Capture live diagnostics")

        self.assertIn("if: success()", finalization)
        self.assertIn("windows.ps1 finalize-desktop", finalization)
        self.assertIn("$env:UUREMOTE_DEBUG -ne '0'", finalization)
        self.assertIn("windows.ps1 snapshot final-desktop", finalization)
        self.assertIn("1..20", live)
        self.assertIn("'live-{0:D2}' -f $_", live)
        self.assertIn("windows.ps1 snapshot $label", live)
        self.assertIn("Start-Sleep -Seconds 15", live)

@unittest.skipUnless(
    WINDOWS_NATIVE_CAPABILITY_AVAILABLE,
    "requires Windows and a PowerShell runtime",
)
class WindowsDiagnosticBehaviorTests(unittest.TestCase):
    def run_controlled_helper(self, body: str, environment: dict[str, str] | None = None):
        helper = str(WINDOWS_HELPER).replace("'", "''")
        return run_windows_script(f". '{helper}'\n{body}", environment=environment)

    def run_managed_window_enumeration(self, body: str):
        return self.run_controlled_helper(
            r"""
Initialize-UURemoteWindowInterop
$interopType = [UURemote.DesktopWindowInterop]
$methodFlags = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Static
$beginEnumeration = $interopType.GetMethod('BeginWindowEnumeration', $methodFlags)
$observeWindow = $interopType.GetMethod('ObserveWindow', $methodFlags)
$completeEnumeration = $interopType.GetMethod('CompleteWindowEnumeration', $methodFlags)
"""
            + body
        )

    def assert_fixed_enumeration_failure(self, result, prefix: list[str] | None = None):
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stdout.splitlines(),
            (prefix or [])
            + [
                "FAILURE_TYPE=System.InvalidOperationException",
                "FAILURE_MESSAGE=UU Remote window enumeration failed.",
            ],
        )
        self.assertEqual(result.stderr, "")

    def test_managed_enumeration_false_fails_closed(self):
        result = self.run_managed_window_enumeration(
            r"""
try {
    $state = $beginEnumeration.Invoke($null, [object[]]@(,[int[]]@(41)))
    $null = $completeEnumeration.Invoke($null, [object[]]@($state, $false))
    Write-Output 'UNEXPECTED=ready'
    exit 0
}
catch {
    $failure = $_.Exception
    while ($null -ne $failure.InnerException) {
        $failure = $failure.InnerException
    }
    Write-Output "FAILURE_TYPE=$($failure.GetType().FullName)"
    Write-Output "FAILURE_MESSAGE=$($failure.Message)"
    exit 1
}
"""
        )
        self.assert_fixed_enumeration_failure(result)

    def test_managed_process_lookup_failure_for_a_valid_window_stops_and_fails(self):
        result = self.run_managed_window_enumeration(
            r"""
try {
    $state = $beginEnumeration.Invoke($null, [object[]]@(,[int[]]@(41)))
    $continue = $observeWindow.Invoke(
        $null,
        [object[]]@($state, [IntPtr]101, [uint32]0, [uint32]0, $true, $false)
    )
    Write-Output "CONTINUE=$continue"
    $null = $completeEnumeration.Invoke($null, [object[]]@($state, $continue))
    Write-Output 'UNEXPECTED=ready'
    exit 0
}
catch {
    $failure = $_.Exception
    while ($null -ne $failure.InnerException) {
        $failure = $failure.InnerException
    }
    Write-Output "FAILURE_TYPE=$($failure.GetType().FullName)"
    Write-Output "FAILURE_MESSAGE=$($failure.Message)"
    exit 1
}
"""
        )
        self.assert_fixed_enumeration_failure(result, ["CONTINUE=False"])

    def test_managed_process_lookup_failure_for_a_disappeared_window_continues(self):
        result = self.run_managed_window_enumeration(
            r"""
$state = $beginEnumeration.Invoke($null, [object[]]@(,[int[]]@(41)))
$continue = $observeWindow.Invoke(
    $null,
    [object[]]@($state, [IntPtr]101, [uint32]0, [uint32]0, $false, $false)
)
$handles = $completeEnumeration.Invoke($null, [object[]]@($state, $true))
Write-Output "CONTINUE=$continue"
Write-Output "HANDLE_COUNT=$($handles.Count)"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["CONTINUE=True", "HANDLE_COUNT=0"])

    def test_managed_empty_enumeration_is_a_valid_zero_window_result(self):
        result = self.run_managed_window_enumeration(
            r"""
$state = $beginEnumeration.Invoke($null, [object[]]@(,[int[]]@(41)))
$handles = $completeEnumeration.Invoke($null, [object[]]@($state, $true))
Write-Output "HANDLE_COUNT=$($handles.Count)"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "HANDLE_COUNT=0")

    def test_minimization_reenumerates_and_verifies_a_replacement_handle(self):
        result = self.run_controlled_helper(
            r"""
$script:enumerations = 0
$script:requests = @()
$script:checks = @()
$script:minimized = @{}
$script:now = [DateTime]'2026-08-14T00:00:00Z'
function Initialize-UURemoteWindowInterop {}
function Get-UURemoteWindowHandles {
    $script:enumerations++
    if ($script:enumerations -eq 1) {
        return [IntPtr]101
    }
    return [IntPtr]202
}
function Request-UURemoteWindowMinimize([IntPtr]$WindowHandle) {
    $value = $WindowHandle.ToInt64()
    $script:requests += $value
    $script:minimized[$value] = $true
}
function Test-UURemoteWindowMinimized([IntPtr]$WindowHandle) {
    $value = $WindowHandle.ToInt64()
    $script:checks += $value
    return $script:minimized.ContainsKey($value)
}
function Get-UURemoteNow { return $script:now }
function Wait-UURemotePoll([int]$Milliseconds) {
    $script:now = $script:now.AddMilliseconds($Milliseconds)
}
Minimize-UURemoteWindows
Write-Output "ENUMERATIONS=$script:enumerations"
Write-Output "REQUESTS=$($script:requests -join ',')"
Write-Output "CHECKS=$($script:checks -join ',')"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FINAL_DESKTOP_STATE=ready", result.stdout)
        self.assertIn("ENUMERATIONS=3", result.stdout)
        self.assertIn("REQUESTS=101,202", result.stdout)
        self.assertIn("CHECKS=101,202,202", result.stdout)

    def test_window_enumeration_passes_every_process_id_to_the_interop(self):
        helper = str(WINDOWS_HELPER).replace("'", "''")
        result = run_windows_script(
            rf"""
Add-Type @'
using System;

namespace UURemote
{{
    public static class DesktopWindowInterop
    {{
        public static int[] RequestedProcessIds = new int[0];

        public static IntPtr[] GetVisibleTopLevelWindowHandles(int[] processIds)
        {{
            RequestedProcessIds = processIds;
            return new[] {{ new IntPtr(101), new IntPtr(202), new IntPtr(303) }};
        }}
    }}
}}
'@
. '{helper}'
function Get-UURemoteGameViewerProcess {{
    return @(
        [pscustomobject]@{{ Id = 41; MainWindowHandle = [IntPtr]901 }},
        [pscustomobject]@{{ Id = 42; MainWindowHandle = [IntPtr]902 }}
    )
}}
$handles = @(Get-UURemoteWindowHandles)
$requestedIds = [UURemote.DesktopWindowInterop]::RequestedProcessIds
Write-Output "PROCESS_IDS=$($requestedIds -join ',')"
Write-Output "HANDLES=$(@($handles | ForEach-Object {{ $_.ToInt64() }}) -join ',')"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PROCESS_IDS=41,42", result.stdout)
        self.assertIn("HANDLES=101,202,303", result.stdout)
        self.assertNotIn("901", result.stdout)
        self.assertNotIn("902", result.stdout)

    def test_finalization_rejects_a_null_interop_enumeration_result(self):
        helper = str(WINDOWS_HELPER).replace("'", "''")
        result = run_windows_script(
            rf"""
Add-Type @'
using System;

namespace UURemote
{{
    public static class DesktopWindowInterop
    {{
        public static IntPtr[] GetVisibleTopLevelWindowHandles(int[] processIds)
        {{
            return null;
        }}
    }}
}}
'@
. '{helper}'
function Get-UURemoteGameViewerProcess {{
    return [pscustomobject]@{{ Id = 41 }}
}}
function Test-UURemoteWindowMinimized {{
    param([AllowNull()]$WindowHandle)
    return $true
}}
$HelperMode = 'finalize-desktop'
$Arguments = @()
Invoke-WindowsHelperRoute
"""
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.strip(), "UU Remote desktop finalization failed.")

    def test_minimization_accepts_no_current_top_level_window(self):
        result = self.run_controlled_helper(
            r"""
$script:enumerations = 0
$script:requests = @()
$script:checks = 0
function Initialize-UURemoteWindowInterop {}
function Get-UURemoteWindowHandles {
    $script:enumerations++
    if ($script:enumerations -eq 1) {
        return [IntPtr]101
    }
    return
}
function Request-UURemoteWindowMinimize([IntPtr]$WindowHandle) {
    $script:requests += $WindowHandle.ToInt64()
}
function Test-UURemoteWindowMinimized([IntPtr]$WindowHandle) {
    $script:checks++
    return $false
}
Minimize-UURemoteWindows
Write-Output "ENUMERATIONS=$script:enumerations"
Write-Output "REQUESTS=$($script:requests -join ',')"
Write-Output "CHECKS=$script:checks"
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("FINAL_DESKTOP_STATE=ready", result.stdout)
        self.assertIn("ENUMERATIONS=2", result.stdout)
        self.assertIn("REQUESTS=101", result.stdout)
        self.assertIn("CHECKS=1", result.stdout)

    def test_failed_snapshot_removes_final_and_temporary_png_files(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = directory
            result = self.run_controlled_helper(
                r"""
$script:captureAttempts = 0
function Write-UURemoteDesktopSnapshot([string]$SnapshotPath) {
    $script:captureAttempts++
    [System.IO.File]::WriteAllText($SnapshotPath, 'partial')
    throw 'injected capture failure'
}
$caught = $false
try {
    Save-DesktopSnapshot -Label 'failure-test'
}
catch {
    $caught = $true
}
$diagnosticDirectory = Join-Path $env:RUNNER_TEMP 'uuremote-diagnostics'
$pngFiles = @(Get-ChildItem -LiteralPath $diagnosticDirectory -Filter '*.png' -ErrorAction SilentlyContinue)
Write-Output "CAPTURE_ATTEMPTS=$script:captureAttempts"
Write-Output "CAUGHT=$caught"
Write-Output "PNG_COUNT=$($pngFiles.Count)"
if ($script:captureAttempts -ne 1 -or -not $caught -or $pngFiles.Count -ne 0) {
    exit 1
}
""",
                environment=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CAPTURE_ATTEMPTS=1", result.stdout)
            self.assertIn("CAUGHT=True", result.stdout)
            self.assertIn("PNG_COUNT=0", result.stdout)

    def test_snapshot_writes_a_real_png_under_runner_temp(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = directory
            result = run_windows_helper("snapshot", "contract-test", environment=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            image = Path(directory, "uuremote-diagnostics", "contract-test.png")
            self.assertTrue(image.is_file())
            self.assertEqual(image.read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

    def test_repeated_snapshot_label_replaces_with_a_real_png(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = directory
            for _ in range(2):
                result = run_windows_helper("snapshot", "repeat", environment=environment)
                self.assertEqual(result.returncode, 0, result.stderr)

            images = list(Path(directory, "uuremote-diagnostics").glob("*.png"))
            self.assertEqual([image.name for image in images], ["repeat.png"])
            self.assertEqual(images[0].read_bytes()[:8], b"\x89PNG\r\n\x1a\n")

    def test_invalid_snapshot_label_returns_two_without_creating_a_file(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = directory
            baseline = run_windows_helper("snapshot", "baseline", environment=environment)
            self.assertEqual(baseline.returncode, 0, baseline.stderr)
            Path(directory, "uuremote-diagnostics", "baseline.png").unlink()

            result = run_windows_helper("snapshot", "../escape", environment=environment)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(list(Path(directory).rglob("*.png")), [])
