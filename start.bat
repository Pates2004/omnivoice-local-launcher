@echo off
title OmniVoice Local Launcher
color 0b

echo ===================================================
echo               OmniVoice Local Launcher
echo                 Applio-like Edition
echo ===================================================
echo.

cd /d "%~dp0"

set "USE_ENV=0"
set "PYTHON_CMD="

IF EXIST env\python.exe (
    set "PYTHON_CMD=env\python.exe"
    set "USE_ENV=1"
    GOTO RunApp
)

IF EXIST venv\Scripts\python.exe (
    set "PYTHON_CMD=venv\Scripts\python.exe"
    GOTO RunApp
)

:: Ani env, ani venv nie istnieje. Sprawdzamy instalację w systemie.
python --version >nul 2>&1
IF %ERRORLEVEL% EQU 0 (
    GOTO PromptHasPython
) ELSE (
    GOTO PromptNoPython
)

:PromptNoPython
echo [INFO] Python is not installed on your system.
echo [INFO] Python nie jest zainstalowany w twoim systemie.
echo.
echo Please choose an option / Wybierz opcje:
echo [1] Download Python only for this application (Portable) / Pobierz Pythona tylko dla tej aplikacji (Wersja przenosna)
echo [2] Download Python for the whole system (Opens website) / Pobierz Pythona dla calego systemu (Otwiera strone WWW)
echo.
choice /C 12 /N /M "Choice / Wybor (1-2): "
IF ERRORLEVEL 2 GOTO OpenWebsite
IF ERRORLEVEL 1 GOTO InstallPortable

:PromptHasPython
echo [INFO] Python is already installed on your system.
echo [INFO] Python jest juz zainstalowany w twoim systemie.
echo.
echo Please choose an option / Wybierz opcje:
echo [1] Download Python only for this application (Portable) / Pobierz Pythona tylko dla tej aplikacji (Wersja przenosna)
echo [2] Use the Python installed on your system / Uzywaj srodowiska Python zainstalowanego w systemie
echo.
choice /C 12 /N /M "Choice / Wybor (1-2): "
IF ERRORLEVEL 2 GOTO UseSystem
IF ERRORLEVEL 1 GOTO InstallPortable

:OpenWebsite
powershell -NoProfile -Command "Start-Process 'https://www.python.org/downloads/'"
exit /b

:UseSystem
echo [INFO] Creating Virtual Environment using System Python...
python -m venv venv
set "PYTHON_CMD=venv\Scripts\python.exe"

echo [INFO] Upgrading pip...
%PYTHON_CMD% -m pip install --upgrade pip

echo [INFO] Installing PyTorch [CUDA]...
%PYTHON_CMD% -m pip install torch==2.8.0+cu128 torchaudio==2.8.0+cu128 --extra-index-url https://download.pytorch.org/whl/cu128

echo [INFO] Installing OmniVoice and its dependencies...
%PYTHON_CMD% -m pip install -e .

echo [INFO] Installation completed successfully!
GOTO RunApp

:InstallPortable
echo [INFO] Downloading Portable Python 3.10...
echo [INFO] Pobieranie przenosnej wersji Python 3.10...
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip' -OutFile 'python_embed.zip'"
echo [INFO] Extracting... / Rozpakowywanie...
powershell -NoProfile -Command "Expand-Archive -Path 'python_embed.zip' -DestinationPath 'env' -Force"
del python_embed.zip

echo [INFO] Configuring Portable Python... / Konfigurowanie...
powershell -NoProfile -Command "(Get-Content 'env\python310._pth') -replace '#import site', 'import site' | Set-Content 'env\python310._pth'"

echo [INFO] Downloading get-pip.py...
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile 'env\get-pip.py'"
echo [INFO] Installing pip...
env\python.exe env\get-pip.py
del env\get-pip.py

echo [INFO] Installing Core Dependencies... / Instalowanie zaleznosci...
env\python.exe -m pip install torch==2.8.0+cu128 torchaudio==2.8.0+cu128 --extra-index-url https://download.pytorch.org/whl/cu128
env\python.exe -m pip install -e .

set "PYTHON_CMD=env\python.exe"
set "USE_ENV=1"
GOTO RunApp

:RunApp
echo.
echo [INFO] Starting OmniVoice Web Interface...
echo [INFO] The application will automatically open in your browser shortly [http://127.0.0.1:7860]
echo.

if "%USE_ENV%"=="0" (
    call venv\Scripts\activate.bat
)

start "" /b powershell -WindowStyle Hidden -Command "while (!(Test-NetConnection -ComputerName 127.0.0.1 -Port 7860 -WarningAction SilentlyContinue).TcpTestSucceeded) { Start-Sleep -Seconds 1 }; Start-Process 'http://127.0.0.1:7860'"
%PYTHON_CMD% -m omnivoice.cli.demo --ip 127.0.0.1 --port 7860

pause
