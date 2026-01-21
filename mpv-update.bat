@echo OFF
:: This batch file is a wrapper to run the PowerShell update script.
:: Its roles are:
:: 1. To provide a double-clickable file (Windows doesn't execute .ps1 by default).
:: 2. To bypass the PowerShell execution policy which blocks unsigned scripts.
:: 3. To handle cases where 'pwsh' (Core) is installed vs 'powershell' (Standard).

pushd %~dp0
echo Starting Updater...

:: Check for PowerShell Core (pwsh) or Standard (powershell)
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "mpv-update.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "mpv-update.ps1"
)
popd
