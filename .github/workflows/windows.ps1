[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$HelperMode = "configure",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-UURemoteCustomCode([string]$Value) {
    return $null -ne $Value -and $Value -cmatch '^[A-Za-z0-9]{8,16}$'
}

function Test-WaitSeconds([string]$Value) {
    if ($Value -notmatch '^[0-9]+$') { return $false }

    $parsed = 0
    return [int]::TryParse($Value, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 21000
}

function Get-UURemotePaths {
    $root = Join-Path $env:ProgramFiles 'Netease\GameViewer'
    [pscustomobject]@{
        InstallRoot = $root
        LauncherPath = Join-Path $root 'GameViewer.exe'
        CliPath = Join-Path $root 'bin\uuyc-cli.exe'
    }
}

function Get-UURemoteGameViewerProcess {
    return @(Get-Process -Name 'GameViewer' -ErrorAction SilentlyContinue)
}

function Start-UURemoteGameViewerProcess {
    param([pscustomobject]$Paths)

    $null = Start-Process -FilePath $Paths.LauncherPath -WorkingDirectory $Paths.InstallRoot
}

function Start-UURemoteDeviceIdProcess([string]$Path) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Path
    $startInfo.Arguments = '--device-id'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'UU Remote CLI failed to start.'
        }
        return $process
    }
    catch {
        $process.Dispose()
        throw
    }
}

function Invoke-UURemoteDeviceIdCli {
    param(
        [string]$Path,
        [int]$TimeoutMilliseconds = 60000
    )

    if ($TimeoutMilliseconds -lt 1) {
        return [pscustomobject]@{
            ExitCode = -1
            Output = @()
            TimedOut = $true
        }
    }

    $process = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = Start-UURemoteDeviceIdProcess -Path $Path
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $remainingMilliseconds = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        if ($remainingMilliseconds -lt 1 -or -not $process.WaitForExit($remainingMilliseconds)) {
            if (-not $process.HasExited) {
                $process.Kill()
            }
            return [pscustomobject]@{
                ExitCode = -1
                Output = @()
                TimedOut = $true
            }
        }

        $remainingMilliseconds = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        if ($remainingMilliseconds -lt 1 -or -not $stdoutTask.Wait($remainingMilliseconds)) {
            return [pscustomobject]@{
                ExitCode = -1
                Output = @()
                TimedOut = $true
            }
        }
        $remainingMilliseconds = $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        if ($remainingMilliseconds -lt 1 -or -not $stderrTask.Wait($remainingMilliseconds)) {
            return [pscustomobject]@{
                ExitCode = -1
                Output = @()
                TimedOut = $true
            }
        }

        $output = $stdoutTask.Result
        $null = $stderrTask.Result
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = @($output)
            TimedOut = $false
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = -1
            Output = @()
            TimedOut = $false
        }
    }
    finally {
        $stopwatch.Stop()
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-UURemoteNow {
    return Get-Date
}

function Wait-UURemotePoll([int]$Milliseconds) {
    Start-Sleep -Milliseconds $Milliseconds
}

function Assert-UURemotePaths([pscustomobject]$Paths) {
    if (-not (Test-Path -LiteralPath $Paths.LauncherPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Paths.CliPath -PathType Leaf)) {
        throw 'UU Remote required executables are unavailable.'
    }
}

function Get-UURemoteDeviceId {
    param(
        [string]$CliPath,
        [int]$TimeoutMilliseconds = 60000
    )

    $result = Invoke-UURemoteDeviceIdCli -Path $CliPath -TimeoutMilliseconds $TimeoutMilliseconds
    if ($result.ExitCode -ne 0) {
        return $null
    }

    $deviceId = (@($result.Output) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($deviceId)) {
        return $null
    }
    return $deviceId
}

function Start-UURemoteAndWaitDevice {
    param(
        [int]$TimeoutSeconds = 60,
        [int]$PollMilliseconds = 500
    )

    if ($TimeoutSeconds -lt 1 -or $PollMilliseconds -lt 1) {
        throw 'UU Remote readiness timing values are invalid.'
    }

    $paths = Get-UURemotePaths
    Assert-UURemotePaths -Paths $paths

    if (@(Get-UURemoteGameViewerProcess).Count -eq 0) {
        Start-UURemoteGameViewerProcess -Paths $paths
    }

    $deadline = (Get-UURemoteNow).AddSeconds($TimeoutSeconds)
    $attempts = 0
    while ($true) {
        $remainingMilliseconds = [int][Math]::Floor(($deadline - (Get-UURemoteNow)).TotalMilliseconds)
        if ($remainingMilliseconds -lt 1) {
            throw "UU Remote device readiness timed out after $attempts attempts."
        }

        $attempts++
        $deviceId = Get-UURemoteDeviceId -CliPath $paths.CliPath -TimeoutMilliseconds $remainingMilliseconds
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
            Write-Output 'DEVICE_ID_STATE=ready'
            return
        }

        $remainingAfterAttempt = [int][Math]::Floor(($deadline - (Get-UURemoteNow)).TotalMilliseconds)
        if ($remainingAfterAttempt -lt 1) {
            throw "UU Remote device readiness timed out after $attempts attempts."
        }
        Wait-UURemotePoll -Milliseconds ([Math]::Min($PollMilliseconds, $remainingAfterAttempt))
    }
}

function Assert-UURemoteReadiness {
    $paths = Get-UURemotePaths
    Assert-UURemotePaths -Paths $paths

    if (@(Get-UURemoteGameViewerProcess).Count -eq 0) {
        throw 'UU Remote unattended readiness failed.'
    }

    $deviceId = Get-UURemoteDeviceId -CliPath $paths.CliPath
    if ([string]::IsNullOrWhiteSpace($deviceId)) {
        throw 'UU Remote unattended readiness failed.'
    }

    Write-Output 'UNATTENDED_READINESS=verified'
}

function Initialize-UURemoteWindowInterop {
    if ($null -eq ('UURemote.DesktopWindowInterop' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace UURemote
{
    public static class DesktopWindowInterop
    {
        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr windowHandle, int command);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr windowHandle);
    }
}
'@
    }
}

function Get-UURemoteWindowHandles {
    return @(
        Get-UURemoteGameViewerProcess |
            ForEach-Object { $_.MainWindowHandle } |
            Where-Object { $_ -ne [IntPtr]::Zero }
    )
}

function Request-UURemoteWindowMinimize([IntPtr]$WindowHandle) {
    $null = [UURemote.DesktopWindowInterop]::ShowWindowAsync($WindowHandle, 6)
}

function Test-UURemoteWindowMinimized([IntPtr]$WindowHandle) {
    return [UURemote.DesktopWindowInterop]::IsIconic($WindowHandle)
}

function Minimize-UURemoteWindows {
    Initialize-UURemoteWindowInterop

    foreach ($windowHandle in @(Get-UURemoteWindowHandles)) {
        Request-UURemoteWindowMinimize -WindowHandle $windowHandle
    }

    $deadline = (Get-UURemoteNow).AddSeconds(5)
    while ($true) {
        $visibleHandles = @(
            Get-UURemoteWindowHandles |
                Where-Object { -not (Test-UURemoteWindowMinimized -WindowHandle $_) }
        )
        if ($visibleHandles.Count -eq 0) {
            break
        }
        if ((Get-UURemoteNow) -ge $deadline) {
            throw 'UU Remote desktop finalization failed.'
        }
        Wait-UURemotePoll -Milliseconds 100
    }

    Write-Output 'FINAL_DESKTOP_STATE=ready'
}

function Test-UURemoteSnapshotLabel([string]$Value) {
    return $null -ne $Value -and $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

function Write-UURemoteDesktopSnapshot([string]$SnapshotPath) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $virtualScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($virtualScreen.Width -lt 1 -or $virtualScreen.Height -lt 1) {
        throw 'Desktop snapshot dimensions are invalid.'
    }

    $bitmap = $null
    $graphics = $null
    try {
        $bitmap = New-Object System.Drawing.Bitmap($virtualScreen.Width, $virtualScreen.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen(
            $virtualScreen.Left,
            $virtualScreen.Top,
            0,
            0,
            $virtualScreen.Size
        )
        $bitmap.Save($SnapshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($null -ne $graphics) {
            $graphics.Dispose()
        }
        if ($null -ne $bitmap) {
            $bitmap.Dispose()
        }
    }
}

function Save-DesktopSnapshot([string]$Label) {
    if (-not (Test-UURemoteSnapshotLabel $Label)) {
        throw 'Invalid desktop snapshot label.'
    }
    if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        throw 'Runner temporary directory is unavailable.'
    }

    $diagnosticDirectory = Join-Path $env:RUNNER_TEMP 'uuremote-diagnostics'
    $null = New-Item -ItemType Directory -Path $diagnosticDirectory -Force
    $snapshotPath = Join-Path $diagnosticDirectory "$Label.png"
    $temporaryName = ".$Label.$([Guid]::NewGuid().ToString('N')).tmp.png"
    $temporaryPath = Join-Path $diagnosticDirectory $temporaryName
    try {
        Write-UURemoteDesktopSnapshot -SnapshotPath $temporaryPath
        if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
            $nullBackupPath = [System.Management.Automation.Language.NullString]::Value
            [System.IO.File]::Replace($temporaryPath, $snapshotPath, $nullBackupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $snapshotPath)
        }
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-UURemoteIdempotencyCheck {
    Assert-UURemoteReadiness
    Set-UURemoteCustomCode
    Assert-UURemoteReadiness
    Minimize-UURemoteWindows
}

function Set-UURemoteCustomCode {
    $customCode = $env:UUREMOTE_CUSTOM_CODE
    if (-not (Test-UURemoteCustomCode $customCode)) {
        throw 'Invalid UU Remote custom code.'
    }

    $paths = Get-UURemotePaths
    if (-not (Test-Path -LiteralPath $paths.CliPath -PathType Leaf)) {
        throw 'UU Remote CLI is unavailable.'
    }

    $null = & $paths.CliPath --reset-custom-code $customCode 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'UU Remote custom-code configuration failed.'
    }

    Write-Output 'CUSTOM_CODE_STATE=configured'
}

function Invoke-ShutdownWaiter {
    param(
        [int]$Seconds,
        [string]$InjectedEvent
    )

    if ($Seconds -lt 1) {
        throw 'Wait seconds must be positive before starting the shutdown watcher.'
    }
    if ($InjectedEvent -notin @('none', 'ordinary', 'shutdown')) {
        throw 'Unsupported injected event.'
    }

    $watcherSource = Join-Path $PSScriptRoot 'uuremote-shutdown-wait.cs'
    if (-not (Test-Path -LiteralPath $watcherSource -PathType Leaf)) {
        throw 'Shutdown watcher source is unavailable.'
    }

    if ($null -eq ('UURemote.ShutdownWaiter' -as [type])) {
        Add-Type -Path $watcherSource -ReferencedAssemblies 'System.Windows.Forms.dll'
    }

    try {
        $result = [UURemote.ShutdownWaiter]::Run($Seconds, $InjectedEvent)
        Write-Output "WAIT_RESULT=$result"
    }
    finally {
        [System.Windows.Forms.Application]::ExitThread()
        Remove-Variable -Name result -ErrorAction SilentlyContinue
    }
}

function Get-SafeWaitSelfTestObservation([object]$Value) {
    if ($null -eq $Value) {
        return 'not-observed'
    }

    $values = @($Value)
    if ($values.Count -ne 1) {
        return 'unexpected'
    }

    switch ($values[0]) {
        'WAIT_RESULT=timeout' { return 'timeout' }
        'WAIT_RESULT=shutdown/restart' { return 'shutdown/restart' }
        default { return 'unexpected' }
    }
}

function Get-SafeWaitSelfTestExceptionCategory([System.Exception]$Exception) {
    if ($Exception -is [System.InvalidOperationException]) {
        return 'invalid-operation'
    }
    if ($Exception -is [System.Management.Automation.RuntimeException]) {
        return 'runtime'
    }
    if ($Exception -is [System.IO.FileNotFoundException]) {
        return 'file-not-found'
    }
    return 'unexpected'
}

function Invoke-WindowsHelperRoute {
    $argumentCount = if ($null -eq $Arguments) { 0 } else { $Arguments.Count }

    switch ($HelperMode) {
    'validate-custom-code' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
        if (-not (Test-UURemoteCustomCode $env:UUREMOTE_CUSTOM_CODE)) {
            [Console]::Error.WriteLine('Invalid UU Remote custom code.')
            exit 2
        }
        exit 0
    }
    'validate-wait-seconds' {
        if ($argumentCount -ne 1 -or -not (Test-WaitSeconds $Arguments[0])) {
            [Console]::Error.WriteLine('Invalid wait connections seconds.')
            exit 2
        }
        exit 0
    }
    'set-custom-code' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
        if (-not (Test-UURemoteCustomCode $env:UUREMOTE_CUSTOM_CODE)) {
            [Console]::Error.WriteLine('Invalid UU Remote custom code.')
            exit 2
        }
        try {
            Set-UURemoteCustomCode
        }
        catch {
            [Console]::Error.WriteLine('UU Remote custom-code configuration failed.')
            exit 1
        }
        exit 0
    }
    'launch-and-wait-device' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
        try {
            Start-UURemoteAndWaitDevice
        }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            exit 1
        }
        exit 0
    }
    'verify-unattended-readiness' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
        try {
            Assert-UURemoteReadiness
        }
        catch {
            [Console]::Error.WriteLine('UU Remote unattended readiness failed.')
            exit 1
        }
        exit 0
    }
    'verify-idempotency' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
        if (-not (Test-UURemoteCustomCode $env:UUREMOTE_CUSTOM_CODE)) {
            [Console]::Error.WriteLine('Invalid UU Remote custom code.')
            exit 2
        }
        try {
            Invoke-UURemoteIdempotencyCheck
        }
        catch {
            [Console]::Error.WriteLine('UU Remote configuration idempotency check failed.')
            exit 1
        }
        exit 0
    }
    'finalize-desktop' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
        try {
            Minimize-UURemoteWindows
        }
        catch {
            [Console]::Error.WriteLine('UU Remote desktop finalization failed.')
            exit 1
        }
        exit 0
    }
    'snapshot' {
        if ($argumentCount -ne 1 -or -not (Test-UURemoteSnapshotLabel $Arguments[0])) {
            [Console]::Error.WriteLine('Invalid desktop snapshot label.')
            exit 2
        }
        try {
            Save-DesktopSnapshot -Label $Arguments[0]
        }
        catch {
            [Console]::Error.WriteLine('Desktop snapshot failed.')
            exit 1
        }
        exit 0
    }
    'self-test-wait-connections' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
        $timeout = $null
        $ordinary = $null
        $shutdown = $null
        try {
            $timeout = Invoke-ShutdownWaiter -Seconds 1 -InjectedEvent 'none'
            $ordinary = Invoke-ShutdownWaiter -Seconds 1 -InjectedEvent 'ordinary'
            $shutdown = Invoke-ShutdownWaiter -Seconds 2 -InjectedEvent 'shutdown'
            if ($timeout -ne 'WAIT_RESULT=timeout' -or
                $ordinary -ne 'WAIT_RESULT=timeout' -or
                $shutdown -ne 'WAIT_RESULT=shutdown/restart') {
                throw 'shutdown-aware wait self-test failed'
            }
            Write-Output 'shutdown-aware wait self-test passed'
        }
        catch {
            [Console]::Error.WriteLine('shutdown-aware wait self-test failed')
            [Console]::Error.WriteLine("WAIT_SELF_TEST_TIMEOUT=$(Get-SafeWaitSelfTestObservation $timeout)")
            [Console]::Error.WriteLine("WAIT_SELF_TEST_ORDINARY=$(Get-SafeWaitSelfTestObservation $ordinary)")
            [Console]::Error.WriteLine("WAIT_SELF_TEST_SHUTDOWN=$(Get-SafeWaitSelfTestObservation $shutdown)")
            if ($null -eq $timeout -or $null -eq $ordinary -or $null -eq $shutdown) {
                [Console]::Error.WriteLine("WAIT_SELF_TEST_EXCEPTION=$(Get-SafeWaitSelfTestExceptionCategory $_.Exception)")
            }
            exit 1
        }
        exit 0
    }
    'wait-connections' {
        if ($argumentCount -ne 1 -or -not (Test-WaitSeconds $Arguments[0])) {
            [Console]::Error.WriteLine('Invalid wait connections seconds.')
            exit 2
        }

        $seconds = [int]$Arguments[0]
        if ($seconds -eq 0) {
            Write-Output 'WAIT_RESULT=timeout'
            exit 0
        }

        try {
            Invoke-ShutdownWaiter -Seconds $seconds -InjectedEvent 'none'
        }
        catch {
            [Console]::Error.WriteLine('Shutdown-aware wait failed.')
            exit 1
        }
        exit 0
    }
    default {
        [Console]::Error.WriteLine('Usage error.')
        exit 2
    }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WindowsHelperRoute
}
