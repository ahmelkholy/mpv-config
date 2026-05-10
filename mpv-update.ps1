[CmdletBinding()]
param(
    [switch]$YtDlpOnly,
    [switch]$SkipMpv,
    [switch]$SkipScripts,
    [switch]$ForceCloseMpv,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$UpdateYtDlpOnly = [bool]$YtDlpOnly
$OmitMpvUpdate = [bool]$SkipMpv
$OmitScriptUpdate = [bool]$SkipScripts
$CloseMpvForUpdate = [bool]$ForceCloseMpv
$PauseOnExit = -not [bool]$NoPause

$UserAgent = "mpv-portable-updater"
$RootDir = $PSScriptRoot
$InstallDir = if (Test-Path (Join-Path $RootDir "portable_config")) {
    Join-Path $RootDir "portable_config"
} else {
    $RootDir
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

function Write-Step {
    param([string]$Message)
    Write-ColorMessage -Message "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-ColorMessage -Message "OK  $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-ColorMessage -Message "WARN $Message" -ForegroundColor Yellow
}

function Get-OptionalCommandPath {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
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

function Invoke-TempTreeCleanup {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { return }

    $tempRoot = [IO.Path]::GetTempPath()
    if (-not $resolved.Path.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove non-temp path: $($resolved.Path)"
    }

    Remove-Item -LiteralPath $resolved.Path -Recurse -Force
}

function Get-LatestRelease {
    param([Parameter(Mandatory)][string]$Repo)
    Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UserAgent $UserAgent
}

function Get-7zr {
    $exe = Join-Path $InstallDir "7z\7zr.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Step "Installing 7zr extractor"
        Invoke-Download "https://www.7-zip.org/a/7zr.exe" $exe
    }
    $exe
}

function Expand-With7zr {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )

    $sevenZip = Get-7zr
    $sevenZipArgs = @("x", "-y", "-o$Destination", $Archive)
    $process = Start-Process -FilePath $sevenZip -ArgumentList $sevenZipArgs -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        throw "7zr failed with exit code $($process.ExitCode)"
    }
}

function Expand-ArchiveFile {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )

    if ([IO.Path]::GetExtension($Archive) -ieq ".zip") {
        Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
        return
    }

    Expand-With7zr -Archive $Archive -Destination $Destination
}

function Test-MpvRunning {
    [bool](Get-Process -Name "mpv" -ErrorAction SilentlyContinue)
}

function Invoke-MpvStopForUpdate {
    if (-not (Test-MpvRunning)) { return $true }

    if (-not $CloseMpvForUpdate) {
        Write-Warn "mpv is running. Close it or rerun with -ForceCloseMpv to update mpv.exe."
        return $false
    }

    Stop-Process -Name "mpv" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    -not (Test-MpvRunning)
}

function Get-MpvConsole {
    $candidates = @(
        (Join-Path $InstallDir "mpv.com"),
        (Join-Path $InstallDir "mpv.exe"),
        (Join-Path $RootDir "mpv.com"),
        (Join-Path $RootDir "mpv.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $null
}

function Invoke-YtDlpUpdate {
    Write-Step "Updating yt-dlp"
    $exe = Join-Path $InstallDir "yt-dlp.exe"

    if (-not (Test-Path -LiteralPath $exe)) {
        $release = Get-LatestRelease "yt-dlp/yt-dlp"
        $asset = $release.assets | Where-Object { $_.name -eq "yt-dlp.exe" } | Select-Object -First 1
        if (-not $asset) { throw "yt-dlp.exe asset was not found in latest release." }
        Invoke-Download $asset.browser_download_url $exe
        Write-Ok "installed yt-dlp.exe"
    }

    & $exe -U
    $version = (& $exe --version).Trim()
    Write-Ok "yt-dlp $version"
}

function Invoke-MpvUpdate {
    if ($OmitMpvUpdate -or $UpdateYtDlpOnly) { return }
    Write-Step "Updating mpv"

    if (-not (Invoke-MpvStopForUpdate)) { return }

    $rssUrl = "https://sourceforge.net/projects/mpv-player-windows/rss?path=/64bit"
    $rssResponse = Invoke-WebRequest -Uri $rssUrl -UserAgent $UserAgent -UseBasicParsing
    [xml]$rss = $rssResponse.Content
    $latestItem = $rss.rss.channel.item | Select-Object -First 1
    if (-not $latestItem) { throw "Could not read mpv release feed." }

    $latestFile = ($latestItem.link -split "/")[-2]
    $downloadUrl = "https://download.sourceforge.net/mpv-player-windows/$latestFile"
    $archive = Join-Path $InstallDir "mpv_update.7z"

    Invoke-Download $downloadUrl $archive
    Expand-ArchiveFile -Archive $archive -Destination $InstallDir
    Remove-Item -LiteralPath $archive -Force

    $mpv = Get-MpvConsole
    if ($mpv) {
        $firstLine = (& $mpv --version 2>&1 | Select-Object -First 1).ToString()
        Write-Ok $firstLine
    } else {
        Write-Warn "mpv binary was not found after extraction."
    }
}

function Get-RawGitHubFile {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Path
    )

    foreach ($branch in @("master", "main")) {
        $url = "https://raw.githubusercontent.com/$Repo/$branch/$Path"
        try {
            Invoke-WebRequest -Uri $url -Method Head -UserAgent $UserAgent -UseBasicParsing | Out-Null
            return $url
        } catch {
            continue
        }
    }

    throw "Could not locate $Path in $Repo."
}

function Invoke-ScriptFileUpdate {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$LocalPath
    )

    $dest = Join-Path $InstallDir $LocalPath
    $url = Get-RawGitHubFile $Repo $RemotePath
    Backup-File $dest
    Invoke-Download $url $dest
    Write-Ok $LocalPath
    $dest
}

function Backup-File {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    $base = (Resolve-Path -LiteralPath $InstallDir).Path.TrimEnd('\') + '\'
    $full = (Resolve-Path -LiteralPath $Path).Path
    $relative = if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        $full.Substring($base.Length)
    } else {
        Split-Path -Leaf $full
    }
    $backupRoot = Join-Path $InstallDir ("cache\update-backups\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $backupPath = Join-Path $backupRoot $relative
    $parent = Split-Path -Parent $backupPath

    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
}

function Invoke-ThumbfastPortablePathPatch {
    param([Parameter(Mandatory)][string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $needle = 'mp.options.read_options(options, "thumbfast")'

    if ($content.Contains("Portable mpv path detection")) {
        return
    }

    if (-not $content.Contains($needle)) {
        Write-Warn "thumbfast portable path patch anchor was not found."
        return
    }

    $patch = @'

-- Portable mpv path detection.
if options.mpv_path == "mpv" then
    for _, candidate in ipairs({"~~/mpv.exe", "~~/mpv.com", "~~/../mpv.exe", "~~/../mpv.com"}) do
        local path = mp.command_native({"expand-path", candidate})
        local info = mp.utils.file_info(path)
        if info and info.is_file then
            options.mpv_path = path:gsub("\\", "/")
            break
        end
    end
end
'@

    Set-Content -LiteralPath $Path -Value $content.Replace($needle, $needle + $patch) -Encoding UTF8
    Write-Ok "patched thumbfast portable mpv path"
}

function Invoke-LuaScriptUpdate {
    if ($OmitScriptUpdate -or $UpdateYtDlpOnly) { return }

    Write-Step "Updating selected Lua scripts"
    $thumbfast = Invoke-ScriptFileUpdate -Repo "po5/thumbfast" -RemotePath "thumbfast.lua" -LocalPath "scripts\thumbfast.lua"
    Invoke-ThumbfastPortablePathPatch -Path $thumbfast

    Invoke-ScriptFileUpdate -Repo "po5/memo" -RemotePath "memo.lua" -LocalPath "scripts\memo.lua" | Out-Null
    Invoke-ScriptFileUpdate -Repo "po5/evafast" -RemotePath "evafast.lua" -LocalPath "scripts\evafast.lua" | Out-Null
    Invoke-ScriptFileUpdate -Repo "mpv-player/mpv" -RemotePath "TOOLS/lua/autoload.lua" -LocalPath "scripts\autoload.lua" | Out-Null
    Invoke-ScriptFileUpdate -Repo "mpv-player/mpv" -RemotePath "TOOLS/lua/autodeint.lua" -LocalPath "scripts\autodeint.lua" | Out-Null

    Invoke-SponsorBlockUpdateIfPresent
}

function Invoke-UoscUpdate {
    if ($OmitScriptUpdate -or $UpdateYtDlpOnly) { return }

    Write-Step "Updating uosc without touching settings"
    $release = Get-LatestRelease "tomasklaen/uosc"
    $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "Could not find uosc zip asset in latest release." }

    $workDir = Join-Path ([IO.Path]::GetTempPath()) ("mpv-uosc-{0}" -f ([guid]::NewGuid()))
    $archive = Join-Path $workDir "uosc.zip"
    New-Item -ItemType Directory -Path $workDir | Out-Null

    try {
        Invoke-Download $asset.browser_download_url $archive
        Expand-ArchiveFile -Archive $archive -Destination $workDir

        $sourceUosc = Get-ChildItem -LiteralPath $workDir -Recurse -Directory |
            Where-Object { $_.FullName -match '\\scripts\\uosc$' } |
            Select-Object -First 1

        if (-not $sourceUosc) { throw "uosc archive did not contain scripts\uosc." }

        $destUosc = Join-Path $InstallDir "scripts\uosc"
        if (Test-Path -LiteralPath $destUosc) {
            $backupRoot = Join-Path $InstallDir ("cache\update-backups\{0}\scripts" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
            if (-not (Test-Path -LiteralPath $backupRoot)) {
                New-Item -ItemType Directory -Path $backupRoot | Out-Null
            }
            Copy-Item -LiteralPath $destUosc -Destination $backupRoot -Recurse -Force
        }

        if (-not (Test-Path -LiteralPath (Split-Path -Parent $destUosc))) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $destUosc) | Out-Null
        }
        Copy-Item -LiteralPath $sourceUosc.FullName -Destination (Split-Path -Parent $destUosc) -Recurse -Force

        foreach ($font in @("uosc_icons.otf", "uosc_textures.ttf")) {
            $sourceFont = Get-ChildItem -LiteralPath $workDir -Recurse -Filter $font | Select-Object -First 1
            if ($sourceFont) {
                Copy-Item -LiteralPath $sourceFont.FullName -Destination (Join-Path $InstallDir "fonts\$font") -Force
            }
        }

        Write-Ok "uosc updated; script-opts\uosc.conf was preserved"
    } finally {
        Invoke-TempTreeCleanup -Path $workDir
    }
}

function Invoke-SponsorBlockUpdateIfPresent {
    $scriptPath = Join-Path $InstallDir "scripts\sponsorblock.lua"
    $sharedPath = Join-Path $InstallDir "scripts\sponsorblock_shared"
    if (-not (Test-Path -LiteralPath $scriptPath) -and -not (Test-Path -LiteralPath $sharedPath)) {
        Write-Warn "SponsorBlock is not installed; skipping optional update."
        return
    }

    Write-Step "Updating installed SponsorBlock script"
    $script = Invoke-ScriptFileUpdate -Repo "po5/mpv_sponsorblock" -RemotePath "sponsorblock.lua" -LocalPath "scripts\sponsorblock.lua"
    Invoke-ScriptFileUpdate -Repo "po5/mpv_sponsorblock" -RemotePath "sponsorblock_shared/main.lua" -LocalPath "scripts\sponsorblock_shared\main.lua" | Out-Null
    Invoke-ScriptFileUpdate -Repo "po5/mpv_sponsorblock" -RemotePath "sponsorblock_shared/sponsorblock.py" -LocalPath "scripts\sponsorblock_shared\sponsorblock.py" | Out-Null
    Invoke-SponsorBlockCompatibilityPatch -Path $script
}

function Invoke-SponsorBlockCompatibilityPatch {
    param([Parameter(Mandatory)][string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $replacements = @{
        'mp.add_key_binding("g", "set_segment", set_segment)' = 'mp.add_key_binding(nil, "set_segment", set_segment)'
        'mp.add_key_binding("G", "submit_segment", submit_segment)' = 'mp.add_key_binding(nil, "submit_segment", submit_segment)'
        'mp.add_key_binding("h", "upvote_segment", function() return vote("1") end)' = 'mp.add_key_binding(nil, "upvote_segment", function() return vote("1") end)'
        'mp.add_key_binding("H", "downvote_segment", function() return vote("0") end)' = 'mp.add_key_binding(nil, "downvote_segment", function() return vote("0") end)'
        "local speed_timer = nil`nlocal fade_timer = nil" = "---@type any`nlocal speed_timer = nil`n---@type any`nlocal fade_timer = nil"
        '        speed_timer:kill()' = '        if speed_timer ~= nil then speed_timer:kill() end'
        'if not youtube_id or string.len(youtube_id) < 11 or (local_pattern and string.len(youtube_id) ~= 11) then return end' = 'if not youtube_id or string.len(youtube_id) < 11 or (options.local_pattern ~= "" and string.len(youtube_id) ~= 11) then return end'
        'local cur_time = os.time(os.date("*t"))' = 'local cur_time = os.time()'
    }

    foreach ($old in $replacements.Keys) {
        $content = $content.Replace($old, $replacements[$old])
    }

    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
    Write-Ok "patched SponsorBlock compatibility fixes"
}

function Invoke-ConfigFolderRepair {
    Write-Step "Repairing local folders"
    foreach ($path in @(
        "cache",
        "cache\watch_later",
        "cache\shaders_cache",
        "subtitles",
        "script-opts",
        "scripts"
    )) {
        $fullPath = Join-Path $InstallDir $path
        if (-not (Test-Path -LiteralPath $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath | Out-Null
            Write-Ok "created $path"
        }
    }
}

function Test-MpvConfig {
    Write-Step "Checking mpv config"
    $mpv = Get-MpvConsole
    if (-not $mpv) {
        Write-Warn "mpv binary was not found; config parse check skipped."
        return
    }

    $output = & $mpv --version 2>&1
    $errors = $output | Select-String -Pattern "Error parsing option|setting option .* failed|Error loading script"
    if ($errors) {
        $errors | ForEach-Object { Write-Warn $_.Line }
        throw "mpv reported config errors."
    }

    Write-Ok ($output | Select-Object -First 1)
}

function Show-ToolStatus {
    Write-Step "Checking helper tools"
    $ffmpeg = Get-OptionalCommandPath @("ffmpeg")
    $node = Get-OptionalCommandPath @("deno", "node", "bun", "qjs", "quickjs")

    if ($ffmpeg) {
        Write-Ok "ffmpeg found: $ffmpeg"
    } else {
        Write-Warn "external ffmpeg not found; mpv playback still uses bundled FFmpeg libraries"
    }

    if ($node) {
        Write-Ok "JavaScript runtime for yt-dlp found: $node"
    } else {
        Write-Warn "no JS runtime found; YouTube extraction can miss formats"
    }
}

try {
    Write-ColorMessage -Message "Target: $InstallDir" -ForegroundColor DarkGray
    Invoke-ConfigFolderRepair
    Show-ToolStatus
    Invoke-YtDlpUpdate
    Invoke-MpvUpdate
    Invoke-UoscUpdate
    Invoke-LuaScriptUpdate
    Test-MpvConfig
    Write-ColorMessage -Message "`nAll requested updates completed." -ForegroundColor Cyan
} catch {
    Write-ColorMessage -Message "`nUpdate failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($PauseOnExit -and $Host.Name -ne "ConsoleHost") {
        Start-Sleep -Seconds 2
    } elseif ($PauseOnExit) {
        Write-ColorMessage -Message "Press any key to exit..." -ForegroundColor Gray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
}
