@echo off
setlocal
pushd "%~dp0"

where python >nul 2>nul
if %errorlevel% equ 0 (
    python "%~dp0mpv-youtube.py" --update %*
    set "MPV_EXIT=%errorlevel%"
    goto done
)

where python3 >nul 2>nul
if %errorlevel% equ 0 (
    python3 "%~dp0mpv-youtube.py" --update %*
    set "MPV_EXIT=%errorlevel%"
    goto done
)

where py >nul 2>nul
if %errorlevel% equ 0 (
    py -3 "%~dp0mpv-youtube.py" --update %*
    set "MPV_EXIT=%errorlevel%"
    goto done
)

echo Python 3 was not found. Install Python or add it to PATH.
set "MPV_EXIT=1"

:done
popd
exit /b %MPV_EXIT%
