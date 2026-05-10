@echo off
pushd %~dp0
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "mpv-youtube.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "mpv-youtube.ps1" %*
)
popd
