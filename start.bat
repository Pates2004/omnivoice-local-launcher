@echo off
setlocal
title OmniVoice Local Launcher
color 0b

cd /d "%~dp0"

if not exist "launcher.ps1" (
    echo [ERROR] Missing launcher.ps1.
    echo [ERROR] Brakuje pliku launcher.ps1.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" %*
set "LAUNCHER_EXIT=%ERRORLEVEL%"

if not "%LAUNCHER_EXIT%"=="0" (
    echo.
    echo [ERROR] OmniVoice launcher failed with code %LAUNCHER_EXIT%.
    echo [ERROR] Launcher OmniVoice zakonczyl sie bledem %LAUNCHER_EXIT%.
    pause
)

exit /b %LAUNCHER_EXIT%
