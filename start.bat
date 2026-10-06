@echo off
setlocal EnableExtensions DisableDelayedExpansion
title OmniVoice Local Launcher
color 0b

cd /d "%~dp0"
if errorlevel 1 (
    echo [ERROR] Cannot access the program folder. Move the launcher to an accessible local folder.
    echo [ERROR] Nie mozna otworzyc folderu programu. Przenies launcher do dostepnego folderu lokalnego.
    pause
    exit /b 1
)

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
