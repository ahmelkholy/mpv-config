param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @()
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

& $PythonCommand @PythonPrefixArgs $PythonLauncher @Arguments
exit $LASTEXITCODE
