[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('readiness-success', 'readiness-timeout', 'readiness-cli-hang', 'readiness-unsafe-device', 'unattended-success', 'unattended-no-process', 'unattended-no-device')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.github\workflows\windows.ps1'
. $helperPath
$script:RealInvokeUURemoteDeviceIdCli = ${function:Invoke-UURemoteDeviceIdCli}

$fixtureProgramFiles = Join-Path ([System.IO.Path]::GetTempPath()) ("uuremote-readiness-{0}" -f [guid]::NewGuid())
$fixtureRoot = Join-Path $fixtureProgramFiles 'Netease\GameViewer'
$launcherPath = Join-Path $fixtureRoot 'GameViewer.exe'
$cliPath = Join-Path $fixtureRoot 'bin\uuyc-cli.exe'
$previousProgramFiles = $env:ProgramFiles
$env:ProgramFiles = $fixtureProgramFiles
$script:HarnessAttempts = 0
$script:HarnessNow = [datetime]'2026-08-14T00:00:00Z'
$script:HarnessProcessRunning = $Mode -in @('unattended-success', 'unattended-no-device')
$script:HarnessCliSucceeds = $Mode -in @('readiness-success', 'unattended-success')
$script:HarnessCliProcessId = $null

function Get-UURemoteGameViewerProcess {
    if ($script:HarnessProcessRunning) {
        return [pscustomobject]@{ ProcessName = 'GameViewer' }
    }
    return $null
}

function Start-UURemoteGameViewerProcess {
    $script:HarnessProcessRunning = $true
}

function Invoke-UURemoteDeviceIdCli {
    param(
        [string]$Path,
        [int]$TimeoutMilliseconds
    )

    if ($Mode -eq 'readiness-cli-hang') {
        return & $script:RealInvokeUURemoteDeviceIdCli -Path $Path -TimeoutMilliseconds $TimeoutMilliseconds
    }

    $script:HarnessAttempts++
    if ($Mode -eq 'readiness-unsafe-device') {
        return [pscustomobject]@{
            ExitCode = 0
            Output = @('device-id-fixture', 'FORGED_OUTPUT=true')
        }
    }

    if ($script:HarnessCliSucceeds -and
        ($Mode -eq 'unattended-success' -or $script:HarnessAttempts -ge 3)) {
        return [pscustomobject]@{
            ExitCode = 0
            Output = @('device-id-fixture')
        }
    }

    return [pscustomobject]@{
        ExitCode = 1
        Output = @()
    }
}

function Start-UURemoteDeviceIdProcess([string]$Path) {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Process -Id $PID).Path
    $startInfo.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 30"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Unable to start controlled CLI process.'
    }
    $script:HarnessCliProcessId = $process.Id
    return $process
}

function Get-UURemoteNow {
    if ($Mode -eq 'readiness-cli-hang') {
        return Get-Date
    }
    $current = $script:HarnessNow
    $script:HarnessNow = $script:HarnessNow.AddMilliseconds(150)
    return $current
}

function Wait-UURemotePoll([int]$Milliseconds) {
}

$exitCode = 0
try {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $cliPath) -Force
    $null = New-Item -ItemType File -Path $launcherPath -Force
    $null = New-Item -ItemType File -Path $cliPath -Force

    switch ($Mode) {
        'readiness-success' {
            Start-UURemoteAndWaitDevice -TimeoutSeconds 1 -PollMilliseconds 10
            Write-Output "ATTEMPTS=$script:HarnessAttempts"
        }
        'readiness-timeout' {
            Start-UURemoteAndWaitDevice -TimeoutSeconds 1 -PollMilliseconds 10
        }
        'readiness-cli-hang' {
            Start-UURemoteAndWaitDevice -TimeoutSeconds 1 -PollMilliseconds 10
        }
        'readiness-unsafe-device' {
            Start-UURemoteAndWaitDevice -TimeoutSeconds 1 -PollMilliseconds 10
        }
        'unattended-success' {
            Assert-UURemoteReadiness
        }
        'unattended-no-process' {
            Assert-UURemoteReadiness
        }
        'unattended-no-device' {
            Assert-UURemoteReadiness
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($Mode -eq 'readiness-cli-hang' -and $null -ne $script:HarnessCliProcessId) {
        for ($probe = 0; $probe -lt 50; $probe++) {
            if ($null -eq (Get-Process -Id $script:HarnessCliProcessId -ErrorAction SilentlyContinue)) {
                Write-Output 'CLI_PROCESS_TERMINATED=true'
                break
            }
            Start-Sleep -Milliseconds 20
        }
    }
    $exitCode = 1
}
finally {
    if ($null -ne $script:HarnessCliProcessId) {
        Stop-Process -Id $script:HarnessCliProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previousProgramFiles) {
        Remove-Item Env:\ProgramFiles -ErrorAction SilentlyContinue
    }
    else {
        $env:ProgramFiles = $previousProgramFiles
    }
    Remove-Item -LiteralPath $fixtureProgramFiles -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
