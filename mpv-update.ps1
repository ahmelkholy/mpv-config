$ErrorActionPreference = "Stop"
$useragent = "mpv-smart-updater"

# --- Intelligent Root Detection ---
# The script is running from the root of the repo (C:\Users\ahm_e\mpv\
# We need to find where mpv.exe and the 'scripts' folder are located.

# Check 1: Is mpv.exe in the same folder as this script? (Standard Layout)
if (Test-Path "$PSScriptRoot\mpv.exe") {
    $install_dir = $PSScriptRoot
    Write-Host "Detected Standard Layout: mpv.exe found in root." -ForegroundColor Cyan
}
# Check 2: Is mpv.exe inside portable_config? (Current User Layout)
elseif (Test-Path "$PSScriptRoot\portable_config\mpv.exe") {
    $install_dir = "$PSScriptRoot\portable_config"
    Write-Host "Detected Portable Layout: mpv.exe found in portable_config." -ForegroundColor Cyan
}
else {
    # Fallback: Assume portable_config is the target for scripts even if bin is missing
    $install_dir = "$PSScriptRoot\portable_config"
    Write-Host "mpv.exe not found. Defaulting target to portable_config." -ForegroundColor Yellow
}

Write-Host "Target Installation Directory: $install_dir" -ForegroundColor Gray

# --- Pre-Update Checks ---

# Check if MPV is running
$mpv_processes = Get-Process -Name "mpv" -ErrorAction SilentlyContinue
if ($mpv_processes) {
    Write-Host "MPV is currently running." -ForegroundColor Red
    Write-Host "Please close MPV to allow updates to proceed." -ForegroundColor Yellow
    $result = Read-Host "Press Enter to retry (or Ctrl+C to cancel)"
    
    $mpv_processes = Get-Process -Name "mpv" -ErrorAction SilentlyContinue
    if ($mpv_processes) {
        Write-Host "MPV is still running. Terminating processes..." -ForegroundColor Red
        Stop-Process -Name "mpv" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

# --- Helper Functions ---

function Get-7z {
    # Check for 7z relative to the install dir
    $7z_exe = Join-Path $install_dir "7z\7zr.exe"
    if (-not (Test-Path $7z_exe)) {
        Write-Host "Downloading 7zr..." -ForegroundColor Yellow
        $dir = Split-Path $7z_exe
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -UserAgent $useragent -OutFile $7z_exe
    }
    return $7z_exe
}

function Extract-Zip ($zipFile, $destDir) {
    $7z = Get-7z
    # x: extract with full paths
    # -y: assume yes on all queries
    # -o: output directory
    $args = "x -y -o`"$destDir`" `"$zipFile`""
    Start-Process -FilePath $7z -ArgumentList $args -Wait -NoNewWindow
}

function Download-File ($url, $dest) {
    Write-Host "Downloading $url..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $url -UserAgent $useragent -OutFile $dest
}

function Get-GitHub-Latest-Release ($repo) {
    $api_url = "https://api.github.com/repos/$repo/releases/latest"
    try {
        $json = Invoke-RestMethod -Uri $api_url -UserAgent $useragent
        return $json
    } catch {
        Write-Host "Error fetching release for $repo" -ForegroundColor Red
        return $null
    }
}

# --- Update Binaries ---

function Update-Mpv {
    Write-Host "`n--- Updating MPV ---" -ForegroundColor Magenta
    $rss_url = "https://sourceforge.net/projects/mpv-player-windows/rss?path=/64bit"
    try {
        [xml]$rss = (New-Object System.Net.WebClient).DownloadString($rss_url)
        $latest_item = $rss.rss.channel.item | Select-Object -First 1
        $latest_file = ($latest_item.link -split "/")[-2] 
        $download_url = "https://download.sourceforge.net/mpv-player-windows/$latest_file"
        
        $dest_zip = Join-Path $install_dir "mpv_update.7z"
        Download-File $download_url $dest_zip
        
        Write-Host "Extracting MPV..." -ForegroundColor Yellow
        Extract-Zip $dest_zip $install_dir
        
        Remove-Item $dest_zip -Force
        Write-Host "MPV Updated." -ForegroundColor Green
    } catch {
        Write-Host "Failed to update MPV: $_" -ForegroundColor Red
    }
}

function Update-YtDlp {
    Write-Host "`n--- Updating yt-dlp ---" -ForegroundColor Magenta
    $exe = Join-Path $install_dir "yt-dlp.exe"
    if (Test-Path $exe) {
        Write-Host "Running internal update..." -ForegroundColor Yellow
        Start-Process -FilePath $exe -ArgumentList "-U" -Wait -NoNewWindow
    } else {
        $release = Get-GitHub-Latest-Release "yt-dlp/yt-dlp"
        if ($release) {
            $asset = $release.assets | Where-Object { $_.name -eq "yt-dlp.exe" }
            Download-File $asset.browser_download_url $exe
            Write-Host "yt-dlp Installed." -ForegroundColor Green
        }
    }
}

# --- Update Scripts ---

function Update-Uosc {
    Write-Host "`n--- Updating uosc ---" -ForegroundColor Magenta
    $release = Get-GitHub-Latest-Release "darsain/uosc"
    if ($release) {
        $asset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
        $zip_path = Join-Path $install_dir "uosc_update.zip"
        Download-File $asset.browser_download_url $zip_path
        
        Write-Host "Extracting uosc..." -ForegroundColor Yellow
        Extract-Zip $zip_path $install_dir
        
        Remove-Item $zip_path -Force
        Write-Host "uosc Updated." -ForegroundColor Green
    }
}

function Update-Script-File ($repo, $file_path, $local_subpath) {
    # $local_subpath is relative to $install_dir
    Write-Host "`n--- Updating $local_subpath ---" -ForegroundColor Magenta
    try {
        $url = ""
        $branches = @("master", "main")
        foreach ($branch in $branches) {
            $test_url = "https://raw.githubusercontent.com/$repo/$branch/$file_path"
            try {
                $test = Invoke-WebRequest -Uri $test_url -Method Head -ErrorAction SilentlyContinue
                if ($test.StatusCode -eq 200) {
                    $url = $test_url
                    break
                }
            } catch {}
        }
        
        if ($url) {
            $dest = Join-Path $install_dir $local_subpath
            # Ensure directory exists
            $parent = Split-Path $dest
            if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
            
            Download-File $url $dest
            return $dest
        } else {
            Write-Host "Could not find file in repo $repo" -ForegroundColor Red
        }
    } catch {
        Write-Host "Failed to update $local_subpath" -ForegroundColor Red
    }
    return $null
}

function Update-Thumbfast {
    $dest = Update-Script-File "po5/thumbfast" "thumbfast.lua" "scripts\thumbfast.lua"
    if ($dest) {
        Write-Host "Applying portable path fix to thumbfast..." -ForegroundColor Yellow
        $content = Get-Content $dest -Raw
        
        # IMPROVED PATCH: Uses backslashes for Windows path safety and prints debug info
        $patch_logic = @"

-- Intelligent Portable Detection (Auto-Patch):
if options.mpv_path == "mpv" then
    local candidates = {
        "~~/mpv.exe",
        "~~/mpv.com",
        "~~/../mpv.exe",
        "~~/../mpv.com"
    }
    for _, path in ipairs(candidates) do
        local expanded = mp.command_native({"expand-path", path})
        local info = mp.utils.file_info(expanded)
        if info and info.is_file then
            -- Use backslashes for Windows compatibility
            options.mpv_path = expanded:gsub("/", "\\")
            mp.msg.info("Thumbfast found mpv at: " .. options.mpv_path)
            break
        end
    end
end
"@
        $needle = 'mp.options.read_options(options, "thumbfast")'
        
        if ($content.Contains($needle) -and -not $content.Contains("Intelligent Portable Detection")) {
            $content = $content.Replace($needle, $needle + $patch_logic)
            Set-Content -Path $dest -Value $content -Encoding UTF8
            Write-Host "Thumbfast patched successfully." -ForegroundColor Green
        } elseif ($content.Contains("Intelligent Portable Detection")) {
             Write-Host "Thumbfast is already patched." -ForegroundColor Green
        } else {
            Write-Host "Could not patch thumbfast: anchor not found." -ForegroundColor Red
        }
    }
}

# --- Execution ---

Write-Host "Starting Comprehensive Update..." -ForegroundColor Cyan

Update-Mpv
Update-YtDlp
Update-Uosc
Update-Thumbfast
Update-Script-File "po5/memo" "memo.lua" "scripts\memo.lua"
Update-Script-File "po5/evafast" "evafast.lua" "scripts\evafast.lua"
Update-Script-File "mpv-player/mpv" "TOOLS/lua/autoload.lua" "scripts\autoload.lua"
Update-Script-File "mpv-player/mpv" "TOOLS/lua/autodeint.lua" "scripts\autodeint.lua"

if (Test-Path (Join-Path $install_dir "scripts\webtorrent.js")) {
    Update-Script-File "mrxdst/webtorrent-mpv-hook" "webtorrent.js" "scripts\webtorrent.js"
}

# --- Cleanup Legacy Files ---
Write-Host "`n--- Cleaning up legacy files ---" -ForegroundColor Magenta
$legacy_files = @(
    "$install_dir\updater.bat",
    "$install_dir\installer\updater.ps1",
    "$install_dir\installer\smart_updater.ps1"
)

foreach ($file in $legacy_files) {
    if (Test-Path $file) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
        Write-Host "Removed legacy file: $file" -ForegroundColor DarkGray
    }
}

# Remove installer directory if empty
$installer_dir = "$install_dir\installer"
if (Test-Path $installer_dir) {
    if ((Get-ChildItem $installer_dir).Count -eq 0) {
        Remove-Item $installer_dir -Force -ErrorAction SilentlyContinue
        Write-Host "Removed empty legacy folder: $installer_dir" -ForegroundColor DarkGray
    }
}

Write-Host "`nAll updates completed!" -ForegroundColor Cyan
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")