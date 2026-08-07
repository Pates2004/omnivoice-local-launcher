@echo off
title OmniVoice Local Launcher
color 0b

echo ===================================================
echo               OmniVoice Local Launcher
echo                 Applio-like Edition
echo ===================================================
echo.

cd /d "%~dp0"

python --version >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Warning, Python is missing on your system!
    echo Press ENTER to open the download page or ESCAPE to cancel.
    echo.
    echo [BLAD] Uwaga, w twoim systemie brakuje Pythona!
    echo Wcisnij ENTER, by otworzyc strone jego pobierania lub ESCAPE, by anulowac.
    powershell -NoProfile -Command "while(1){$k=[System.Console]::ReadKey(1); if($k.Key -eq 'Enter'){Start-Process 'https://www.python.org/downloads/'; exit 1} elseif($k.Key -eq 'Escape'){exit 0}}"
    exit /b
)

IF EXIST venv GOTO ActivateVenv

echo [INFO] First run detected! Creating Virtual Environment...
python -m venv venv
call venv\Scripts\activate.bat

echo [INFO] Upgrading pip...
python -m pip install --upgrade pip

echo [INFO] Installing PyTorch [CUDA]...
pip install torch==2.8.0+cu128 torchaudio==2.8.0+cu128 --extra-index-url https://download.pytorch.org/whl/cu128

echo [INFO] Installing OmniVoice and its dependencies...
pip install -e .

echo [INFO] Installation completed successfully!
GOTO StartApp

:ActivateVenv
echo [INFO] Activating Virtual Environment...
call venv\Scripts\activate.bat

:StartApp
echo.
echo [INFO] Starting OmniVoice Web Interface...
echo [INFO] The application will automatically open in your browser shortly [http://127.0.0.1:7860]
echo.

start "" /b powershell -WindowStyle Hidden -Command "while (!(Test-NetConnection -ComputerName 127.0.0.1 -Port 7860 -WarningAction SilentlyContinue).TcpTestSucceeded) { Start-Sleep -Seconds 1 }; Start-Process 'http://127.0.0.1:7860'"
omnivoice-demo --ip 127.0.0.1 --port 7860

pause
