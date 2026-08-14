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
    if ($Value -notmatch '^[0-9]+$') { return $false }

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
    default {
        [Console]::Error.WriteLine('Usage error.')
        exit 2
    }
}
