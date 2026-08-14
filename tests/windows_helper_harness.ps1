[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('readiness-success', 'readiness-timeout', 'unattended-success', 'unattended-no-process', 'unattended-no-device')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.github\workflows\windows.ps1'
. $helperPath -Mode $Mode -ImportOnly

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

function Get-UURemoteGameViewerProcess {
    if ($script:HarnessProcessRunning) {
        return [pscustomobject]@{ ProcessName = 'GameViewer' }
    }
    return $null
}

function Start-UURemoteGameViewerProcess {
    $script:HarnessProcessRunning = $true
}

function Invoke-UURemoteDeviceIdCli([string]$Path) {
    $script:HarnessAttempts++
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

function Get-UURemoteNow {
    $current = $script:HarnessNow
    $script:HarnessNow = $script:HarnessNow.AddMilliseconds(400)
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
    $exitCode = 1
}
finally {
    if ($null -eq $previousProgramFiles) {
        Remove-Item Env:\ProgramFiles -ErrorAction SilentlyContinue
    }
    else {
        $env:ProgramFiles = $previousProgramFiles
    }
    Remove-Item -LiteralPath $fixtureProgramFiles -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
