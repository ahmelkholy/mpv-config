[CmdletBinding()]
param(
    [ValidateSet(720, 1080, 1440, 2160, 4320)]
    [int]$Height = 2160,

    [string]$CookiesFromBrowser = "",

    [switch]$NoUpdate,

    [switch]$DryRun,

    [switch]$Wait,

    [string]$IpcName = "mpv-youtube-queue",

    [string[]]$MpvArgs = @(),

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PythonLauncher = Join-Path $PSScriptRoot "mpv-youtube.py"
if (-not (Test-Path -LiteralPath $PythonLauncher)) {
    throw "Python launcher was not found: $PythonLauncher"
}

$Python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Python) {
    $Python = Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $Python) {
    $Python = Get-Command py -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $Python) {
    throw "Python was not found. Install Python 3 or add it to PATH."
}

$PythonPrefixArgs = @()
if ($Python.Name -match '^py(\.exe)?$') {
    $PythonPrefixArgs += "-3"
}
$PythonCommand = if ($Python.CommandType -eq "Application") {
    $Python.Source
} else {
    $Python.Name
}

$LauncherArgs = @(
    $PythonLauncher,
    "--height", $Height,
    "--ipc-name", $IpcName
)

if ($CookiesFromBrowser) {
    $LauncherArgs += @("--cookies-from-browser", $CookiesFromBrowser)
}
if ($NoUpdate) {
    $LauncherArgs += "--no-update"
}
if ($DryRun) {
    $LauncherArgs += "--dry-run"
}
if ($Wait) {
    $LauncherArgs += "--wait"
}

$LauncherArgs += @($MpvArgs) + @($RemainingArgs)

& $PythonCommand @PythonPrefixArgs @LauncherArgs
exit $LASTEXITCODE
