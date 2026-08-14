[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mode = "configure",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments,
    [switch]$ImportOnly
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

function Invoke-UURemoteDeviceIdCli([string]$Path) {
    $output = @(& $Path --device-id 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
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

function Get-UURemoteDeviceId([string]$CliPath) {
    $result = Invoke-UURemoteDeviceIdCli -Path $CliPath
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
        $attempts++
        $deviceId = Get-UURemoteDeviceId -CliPath $paths.CliPath
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
            Write-Output 'DEVICE_ID_STATE=ready'
            return
        }

        if ((Get-UURemoteNow) -ge $deadline) {
            throw "UU Remote device readiness timed out after $attempts attempts."
        }
        Wait-UURemotePoll -Milliseconds $PollMilliseconds
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

function Invoke-WindowsHelperRoute {
    $argumentCount = if ($null -eq $Arguments) { 0 } else { $Arguments.Count }

    switch ($Mode) {
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
    'self-test-wait-connections' {
        if ($argumentCount -ne 0) {
            [Console]::Error.WriteLine('Usage error.')
            exit 2
        }
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

if (-not $ImportOnly) {
    Invoke-WindowsHelperRoute
}
