[CmdletBinding()]
param(
    [ValidateSet(720, 1080, 1440, 2160, 4320)]
    [int]$Height = 2160,

    [string]$CookiesFromBrowser = "",

    [switch]$NoUpdate,

    [switch]$DryRun,

    [string[]]$MpvArgs = @(),

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$BrowserCookies = $CookiesFromBrowser
$UseDryRun = [bool]$DryRun

$UserAgent = "mpv-youtube-launcher"
$RootDir = $PSScriptRoot
$ConfigDir = Join-Path $RootDir "portable_config"
$Mpv = Join-Path $ConfigDir "mpv.com"
$YtDlp = Join-Path $ConfigDir "yt-dlp.exe"
$LaunchArgs = @($MpvArgs) + @($RemainingArgs)

if (-not (Test-Path -LiteralPath $Mpv)) {
    $Mpv = Join-Path $ConfigDir "mpv.exe"
}

function Write-ColorMessage {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][ConsoleColor]$ForegroundColor
    )

    try {
        $Host.UI.WriteLine($ForegroundColor, $Host.UI.RawUI.BackgroundColor, $Message)
    } catch {
        Write-Output $Message
    }
}

function Test-YouTubeUrl {
    param([string]$Value)
    $Value -match '^https?://([^/]+\.)?(youtube\.com|youtu\.be|music\.youtube\.com)/'
}

function Get-FirstYouTubeUrl {
    foreach ($arg in $LaunchArgs) {
        if (Test-YouTubeUrl $arg) { return $arg }
    }
    $null
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )

    $parent = Split-Path -Parent $OutFile
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    Invoke-WebRequest -Uri $Uri -UserAgent $UserAgent -OutFile $OutFile -UseBasicParsing
}

function Install-YtDlp {
    Write-ColorMessage -Message "Installing yt-dlp..." -ForegroundColor Yellow
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" -UserAgent $UserAgent
    $asset = $release.assets | Where-Object { $_.name -eq "yt-dlp.exe" } | Select-Object -First 1
    if (-not $asset) { throw "Could not find yt-dlp.exe in the latest yt-dlp release." }
    Invoke-Download -Uri $asset.browser_download_url -OutFile $YtDlp
}

function Repair-YtDlp {
    if (Test-Path -LiteralPath $YtDlp) {
        $backup = Join-Path $ConfigDir ("yt-dlp.failed.{0}.exe" -f (Get-Date -Format "yyyyMMddHHmmss"))
        Move-Item -LiteralPath $YtDlp -Destination $backup -Force
        Write-ColorMessage -Message "Moved failed yt-dlp to $backup" -ForegroundColor Yellow
    }
    Install-YtDlp
}

function Invoke-YtDlpUpdate {
    if (-not (Test-Path -LiteralPath $YtDlp)) {
        Install-YtDlp
    }

    Write-ColorMessage -Message "Checking yt-dlp update..." -ForegroundColor Cyan
    & $YtDlp -U
    if ($LASTEXITCODE -ne 0) {
        Write-ColorMessage -Message "yt-dlp self-update failed; reinstalling latest release..." -ForegroundColor Yellow
        Repair-YtDlp
    }

    $version = (& $YtDlp --version).Trim()
    Write-ColorMessage -Message "yt-dlp $version" -ForegroundColor Green
}

function Get-OptionalCommandPath {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    $null
}

function Get-YtDlpRawOption {
    $raw = @()

    $runtime = Get-OptionalCommandPath @("deno", "node", "bun", "qjs", "quickjs")
    if ($runtime) {
        $runtimeName = [IO.Path]::GetFileNameWithoutExtension($runtime)
        if ($runtimeName -eq "qjs") { $runtimeName = "quickjs" }
        $raw += "--ytdl-raw-options-append=js-runtimes=$runtimeName`:$($runtime.Replace('\', '/'))"
    }

    $ffmpeg = Get-OptionalCommandPath @("ffmpeg")
    if ($ffmpeg) {
        $raw += "--ytdl-raw-options-append=ffmpeg-location=$($ffmpeg.Replace('\', '/'))"
    }

    if ($BrowserCookies) {
        $raw += "--ytdl-raw-options-append=cookies-from-browser=$BrowserCookies"
    }

    $raw
}

function Get-MpvArgument {
    param([int]$MaxHeight)

    $portableYtDlp = $YtDlp.Replace("\", "/")
    $format = "bv*[height<=$MaxHeight]+ba/b[height<=$MaxHeight]/bv*+ba/b"

    @(
        "--config-dir=$ConfigDir",
        "--ytdl=yes",
        "--script-opts-append=ytdl_hook-ytdl_path=$portableYtDlp",
        "--script-opts-append=ytdl_hook-try_ytdl_first=yes",
        "--ytdl-format=$format",
        "--cache=yes",
        "--demuxer-readahead-secs=20",
        "--demuxer-max-bytes=512MiB",
        "--demuxer-max-back-bytes=128MiB"
    ) + (Get-YtDlpRawOption) + $LaunchArgs
}

function Invoke-MpvOnce {
    param([int]$MaxHeight)
    $mpvArguments = @(Get-MpvArgument -MaxHeight $MaxHeight) | Where-Object { $_ -ne $null -and $_ -ne "" }
    if ($UseDryRun) {
        Write-Output $Mpv
        $mpvArguments | ForEach-Object { Write-Output $_ }
        return 0
    }

    $process = Start-Process -FilePath $Mpv -ArgumentList $mpvArguments -Wait -NoNewWindow -PassThru
    $process.ExitCode
}

if (-not (Test-Path -LiteralPath $Mpv)) {
    throw "mpv was not found in $ConfigDir"
}

$youtubeUrl = Get-FirstYouTubeUrl

if ($youtubeUrl -and -not $NoUpdate) {
    Invoke-YtDlpUpdate
} elseif ($youtubeUrl -and -not (Test-Path -LiteralPath $YtDlp)) {
    Install-YtDlp
}

$exitCode = Invoke-MpvOnce -MaxHeight $Height

if ($youtubeUrl -and $exitCode -ne 0) {
    Write-ColorMessage -Message "mpv failed for YouTube. Refreshing yt-dlp and retrying at 1080p..." -ForegroundColor Yellow
    Invoke-YtDlpUpdate
    $exitCode = Invoke-MpvOnce -MaxHeight 1080
}

exit $exitCode
