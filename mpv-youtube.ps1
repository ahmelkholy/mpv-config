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

$UserAgent = "mpv-youtube-launcher"
$RootDir = $PSScriptRoot
$ConfigDir = Join-Path $RootDir "portable_config"
$Mpv = Join-Path $ConfigDir "mpv.com"
$YtDlp = Join-Path $ConfigDir "yt-dlp.exe"
$LaunchArgs = @($MpvArgs) + @($RemainingArgs)

if (-not (Test-Path -LiteralPath $Mpv)) {
    $Mpv = Join-Path $ConfigDir "mpv.exe"
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
    Write-Host "Installing yt-dlp..." -ForegroundColor Yellow
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest" -UserAgent $UserAgent
    $asset = $release.assets | Where-Object { $_.name -eq "yt-dlp.exe" } | Select-Object -First 1
    if (-not $asset) { throw "Could not find yt-dlp.exe in the latest yt-dlp release." }
    Invoke-Download $asset.browser_download_url $YtDlp
}

function Repair-YtDlp {
    if (Test-Path -LiteralPath $YtDlp) {
        $backup = Join-Path $ConfigDir ("yt-dlp.failed.{0}.exe" -f (Get-Date -Format "yyyyMMddHHmmss"))
        Move-Item -LiteralPath $YtDlp -Destination $backup -Force
        Write-Host "Moved failed yt-dlp to $backup" -ForegroundColor Yellow
    }
    Install-YtDlp
}

function Update-YtDlp {
    if (-not (Test-Path -LiteralPath $YtDlp)) {
        Install-YtDlp
    }

    Write-Host "Checking yt-dlp update..." -ForegroundColor Cyan
    & $YtDlp -U
    if ($LASTEXITCODE -ne 0) {
        Write-Host "yt-dlp self-update failed; reinstalling latest release..." -ForegroundColor Yellow
        Repair-YtDlp
    }

    $version = (& $YtDlp --version).Trim()
    Write-Host "yt-dlp $version" -ForegroundColor Green
}

function Get-OptionalCommandPath {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    $null
}

function Get-YtDlpRawOptions {
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

    if ($CookiesFromBrowser) {
        $raw += "--ytdl-raw-options-append=cookies-from-browser=$CookiesFromBrowser"
    }

    $raw
}

function Get-MpvArgs {
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
    ) + (Get-YtDlpRawOptions) + $LaunchArgs
}

function Start-MpvOnce {
    param([int]$MaxHeight)
    $mpvArguments = @(Get-MpvArgs -MaxHeight $MaxHeight) | Where-Object { $_ -ne $null -and $_ -ne "" }
    if ($DryRun) {
        Write-Host $Mpv
        $mpvArguments | ForEach-Object { Write-Host $_ }
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
    Update-YtDlp
} elseif ($youtubeUrl -and -not (Test-Path -LiteralPath $YtDlp)) {
    Install-YtDlp
}

$exitCode = Start-MpvOnce -MaxHeight $Height

if ($youtubeUrl -and $exitCode -ne 0) {
    Write-Host "mpv failed for YouTube. Refreshing yt-dlp and retrying at 1080p..." -ForegroundColor Yellow
    Update-YtDlp
    $exitCode = Start-MpvOnce -MaxHeight 1080
}

exit $exitCode
