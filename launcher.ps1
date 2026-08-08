[CmdletBinding()]
param(
    [ValidateSet("Auto", "System", "Portable")]
    [string]$Mode = "Auto",
    [switch]$NoBrowser,
    [switch]$BootstrapOnly,
    [switch]$InstallOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Join-Path $ProjectRoot "env"
$VenvDir = Join-Path $ProjectRoot "venv"
$WorkDir = Join-Path $ProjectRoot ".launcher"
$ModeFile = Join-Path $WorkDir "python-mode.txt"
$PythonVersion = "3.12.10"
$PythonArchiveUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$PythonArchiveMd5 = "fe8ef205f2e9c3ba44d0cf9954e1abd3"
$GetPipUrl = "https://bootstrap.pypa.io/get-pip.py"
$TorchVersion = "2.8.0"
$LauncherRevision = "2"

function Write-Step {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Remove-LauncherDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a directory outside the launcher: $target"
    }
    Remove-Item -LiteralPath $target -Recurse -Force
}

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Description
    )

    Write-Step $Description
    & $FilePath @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Test-CompatiblePython {
    param([string]$Python)

    if (-not (Test-Path -LiteralPath $Python)) {
        return $false
    }
    & $Python -c "import sys; raise SystemExit(0 if (3, 10) <= sys.version_info[:2] < (3, 14) and sys.maxsize > 2**32 else 1)" 2>$null
    return $LASTEXITCODE -eq 0
}

function Find-SystemPython {
    $seen = @{}
    $launchers = @()
    $py = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($null -ne $py) {
        foreach ($selector in @("-3.13", "-3.12", "-3.11", "-3.10", "-3")) {
            try {
                $path = (& $py.Source $selector -c "import sys; print(sys.executable)" 2>$null | Select-Object -Last 1)
                if ($LASTEXITCODE -eq 0 -and $path) {
                    $launchers += $path.Trim()
                }
            }
            catch {
                continue
            }
        }
    }
    $python = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        $launchers += $python.Source
    }

    foreach ($candidate in $launchers) {
        if ($seen.ContainsKey($candidate)) {
            continue
        }
        $seen[$candidate] = $true
        if (Test-CompatiblePython $candidate) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Test-NvidiaGpu {
    $nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if ($null -eq $nvidiaSmi) {
        return $false
    }
    & $nvidiaSmi.Source -L *> $null
    return $LASTEXITCODE -eq 0
}

function Get-ProjectFingerprint {
    return (Get-FileHash -LiteralPath (Join-Path $ProjectRoot "pyproject.toml") -Algorithm SHA256).Hash
}

function Get-EnvironmentRoot {
    param([string]$Python)

    $full = [IO.Path]::GetFullPath($Python)
    if ($full.StartsWith([IO.Path]::GetFullPath($PortableDir), [StringComparison]::OrdinalIgnoreCase)) {
        return $PortableDir
    }
    return $VenvDir
}

function Test-Runtime {
    param([string]$Python)

    if (-not (Test-CompatiblePython $Python)) {
        return $false
    }
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        & $Python -c "import accelerate, gradio, librosa, numpy, soundfile, torch, torchaudio, transformers, webdataset; import omnivoice; assert torch.__version__" 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        & $Python -m pip check *> $null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }

    $environmentRoot = Get-EnvironmentRoot $Python
    $marker = Join-Path $environmentRoot ".omnivoice-ready"
    if (-not (Test-Path -LiteralPath $marker)) {
        return $false
    }
    $gpuMode = if (Test-NvidiaGpu) { "cuda" } else { "cpu" }
    $expected = "revision=$LauncherRevision;project=$(Get-ProjectFingerprint);torch=$gpuMode"
    return (Get-Content -LiteralPath $marker -Raw).Trim() -eq $expected
}

function Install-PortablePython {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $archive = Join-Path $WorkDir "python-embed.zip"
    $staging = Join-Path $WorkDir "python-staging"
    Remove-LauncherDirectory $staging

    Write-Step "Downloading portable Python $PythonVersion from python.org..."
    Invoke-WebRequest -UseBasicParsing -Uri $PythonArchiveUrl -OutFile $archive
    $actualMd5 = (Get-FileHash -LiteralPath $archive -Algorithm MD5).Hash.ToLowerInvariant()
    if ($actualMd5 -ne $PythonArchiveMd5) {
        throw "Portable Python archive checksum mismatch. Expected $PythonArchiveMd5, got $actualMd5."
    }

    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
    Remove-Item -LiteralPath $archive -Force

    $pth = @(Get-ChildItem -LiteralPath $staging -Filter "python*._pth")
    if ($pth.Count -ne 1) {
        throw "Could not locate the portable Python _pth configuration file."
    }
    (Get-Content -LiteralPath $pth[0].FullName) -replace '^#import site$', 'import site' |
        Set-Content -LiteralPath $pth[0].FullName -Encoding ASCII

    Remove-LauncherDirectory $PortableDir
    Move-Item -LiteralPath $staging -Destination $PortableDir
    $portablePython = Join-Path $PortableDir "python.exe"
    if (-not (Test-CompatiblePython $portablePython)) {
        throw "The downloaded portable Python is not compatible."
    }

    $getPip = Join-Path $PortableDir "get-pip.py"
    Write-Step "Downloading the official pip bootstrap script..."
    Invoke-WebRequest -UseBasicParsing -Uri $GetPipUrl -OutFile $getPip
    try {
        Invoke-Checked $portablePython @(
            $getPip,
            "--disable-pip-version-check",
            "--no-warn-script-location"
        ) "Installing pip"
    }
    finally {
        if (Test-Path -LiteralPath $getPip) {
            Remove-Item -LiteralPath $getPip -Force
        }
    }
    return $portablePython
}

function New-SystemEnvironment {
    param([string]$SystemPython)

    if (-not (Test-CompatiblePython $SystemPython)) {
        throw "A 64-bit Python version from 3.10 through 3.13 is required."
    }
    Remove-LauncherDirectory $VenvDir
    Invoke-Checked $SystemPython @("-m", "venv", $VenvDir) "Creating the local virtual environment"
    $venvPython = Join-Path $VenvDir "Scripts\python.exe"
    if (-not (Test-CompatiblePython $venvPython)) {
        throw "The newly created virtual environment is not usable."
    }
    return $venvPython
}

function Install-Or-RepairRuntime {
    param([string]$Python)

    Invoke-Checked $Python @("-m", "pip", "install", "--upgrade", "pip") "Updating pip"

    if (Test-NvidiaGpu) {
        $torchIndex = "https://download.pytorch.org/whl/cu128"
        $torchLabel = "Installing PyTorch $TorchVersion with NVIDIA CUDA 12.8 support"
    }
    else {
        $torchIndex = "https://download.pytorch.org/whl/cpu"
        $torchLabel = "Installing the CPU build of PyTorch $TorchVersion"
    }
    Invoke-Checked $Python @(
        "-m", "pip", "install",
        "torch==$TorchVersion", "torchaudio==$TorchVersion",
        "--index-url", $torchIndex,
        "--no-warn-script-location"
    ) $torchLabel
    Invoke-Checked $Python @(
        "-m", "pip", "install", "hatchling", "editables", "--no-warn-script-location"
    ) "Installing the local build backend"
    Invoke-Checked $Python @(
        "-m", "pip", "install", "--no-build-isolation", "--no-warn-script-location",
        "-e", $ProjectRoot
    ) "Installing OmniVoice and its dependencies"
    Invoke-Checked $Python @("-m", "pip", "check") "Checking installed dependencies"
    Invoke-Checked $Python @(
        "-c",
        "import accelerate, gradio, librosa, numpy, soundfile, torch, torchaudio, transformers, webdataset; import omnivoice"
    ) "Validating the OmniVoice runtime"

    $environmentRoot = Get-EnvironmentRoot $Python
    $marker = Join-Path $environmentRoot ".omnivoice-ready"
    $gpuMode = if (Test-NvidiaGpu) { "cuda" } else { "cpu" }
    "revision=$LauncherRevision;project=$(Get-ProjectFingerprint);torch=$gpuMode" |
        Set-Content -LiteralPath $marker -Encoding ASCII
}

function Select-FirstRunMode {
    param(
        [string]$SystemPython,
        [string]$RequestedMode
    )

    if ($RequestedMode -ne "Auto") {
        return $RequestedMode
    }
    if ($env:OMNIVOICE_PYTHON_MODE -in @("System", "Portable")) {
        return $env:OMNIVOICE_PYTHON_MODE
    }

    Write-Host ""
    if ($SystemPython) {
        Write-Host "A compatible system Python was found: $SystemPython"
        Write-Host "Znaleziono zgodnego Pythona systemowego: $SystemPython"
        Write-Host "[1] Portable Python inside this application (recommended)"
        Write-Host "    Wlasny Python wewnatrz aplikacji (zalecane)"
        Write-Host "[2] Local venv based on the system Python"
        Write-Host "    Lokalne venv oparte na Pythonie systemowym"
        do {
            $answer = Read-Host "Choice / Wybor [1-2]"
        } while ($answer -notin @("1", "2"))
        if ($answer -eq "2") { return "System" }
        return "Portable"
    }

    Write-Host "No compatible 64-bit Python 3.10-3.13 installation was found."
    Write-Host "Nie znaleziono zgodnego 64-bitowego Pythona 3.10-3.13."
    Write-Host "[1] Download portable Python for this application (recommended)"
    Write-Host "    Pobierz wlasnego Pythona dla tej aplikacji (zalecane)"
    Write-Host "[2] Open the official Python download page and exit"
    Write-Host "    Otworz oficjalna strone Pythona i zakoncz"
    do {
        $answer = Read-Host "Choice / Wybor [1-2]"
    } while ($answer -notin @("1", "2"))
    if ($answer -eq "2") {
        Start-Process "https://www.python.org/downloads/windows/"
        return "Website"
    }
    return "Portable"
}

function Start-BrowserWatcher {
    if ($NoBrowser -or $env:OMNIVOICE_NO_BROWSER -eq "1") {
        return $null
    }
    return Start-Job -ArgumentList "http://127.0.0.1:7860" -ScriptBlock {
        param($Url)
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            $client = New-Object Net.Sockets.TcpClient
            try {
                $task = $client.ConnectAsync("127.0.0.1", 7860)
                if ($task.Wait(500) -and $client.Connected) {
                    Start-Process $Url
                    return
                }
            }
            catch {
                # The server is not ready yet.
            }
            finally {
                $client.Dispose()
            }
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-SelfTest {
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "pyproject.toml"))) {
        throw "pyproject.toml is missing."
    }
    if ($PythonArchiveUrl -notmatch '^https://www\.python\.org/') {
        throw "Portable Python must be downloaded from python.org."
    }
    if ($PythonArchiveMd5 -notmatch '^[0-9a-f]{32}$') {
        throw "Portable Python checksum is malformed."
    }
    if ($TorchVersion -ne "2.8.0") {
        throw "Unexpected PyTorch version."
    }
    $systemPython = Find-SystemPython
    if ($systemPython) {
        Write-Host "Compatible system Python: $systemPython"
    }
    else {
        Write-Host "Compatible system Python: not found (portable mode remains available)"
    }
    Write-Host "Launcher self-test: OK"
}

function Invoke-Main {
    Set-Location -LiteralPath $ProjectRoot
    if ($SelfTest) {
        Invoke-SelfTest
        return
    }

    $portablePython = Join-Path $PortableDir "python.exe"
    $venvPython = Join-Path $VenvDir "Scripts\python.exe"
    $python = $null
    $requestedMode = $Mode

    if ($requestedMode -eq "Auto" -and (Test-Path -LiteralPath $ModeFile)) {
        $savedMode = (Get-Content -LiteralPath $ModeFile -Raw).Trim()
        if ($savedMode -in @("System", "Portable")) {
            $requestedMode = $savedMode
        }
    }

    if ($requestedMode -in @("Auto", "Portable") -and (Test-CompatiblePython $portablePython)) {
        $python = $portablePython
    }
    elseif ($requestedMode -in @("Auto", "System") -and (Test-CompatiblePython $venvPython)) {
        $python = $venvPython
    }

    if (-not $python) {
        $systemPython = Find-SystemPython
        $selectedMode = Select-FirstRunMode $systemPython $requestedMode
        if ($selectedMode -eq "Website") {
            return
        }
        if ($selectedMode -eq "Portable") {
            $python = Install-PortablePython
        }
        else {
            if (-not $systemPython) {
                throw "System mode was selected, but no compatible Python installation was found."
            }
            $python = New-SystemEnvironment $systemPython
        }
    }

    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $selectedRuntime = if ((Get-EnvironmentRoot $python) -eq $PortableDir) { "Portable" } else { "System" }
    $selectedRuntime | Set-Content -LiteralPath $ModeFile -Encoding ASCII

    if ($BootstrapOnly) {
        Write-Host "Bootstrap test completed with $selectedRuntime Python: $python"
        return
    }

    if (-not (Test-Runtime $python)) {
        Install-Or-RepairRuntime $python
    }

    if ($InstallOnly) {
        Write-Host "Runtime installation and validation completed successfully: $python"
        return
    }

    Write-Host ""
    Write-Step "Starting the OmniVoice web interface at http://127.0.0.1:7860"
    $browserJob = Start-BrowserWatcher
    try {
        & $python -m omnivoice.cli.demo --ip 127.0.0.1 --port 7860
        if ($LASTEXITCODE -ne 0) {
            throw "The OmniVoice web interface exited with code $LASTEXITCODE."
        }
    }
    finally {
        if ($null -ne $browserJob) {
            Stop-Job -Job $browserJob -ErrorAction SilentlyContinue
            Remove-Job -Job $browserJob -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Invoke-Main
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Installation or startup failed. You can run start.bat again to repair it." -ForegroundColor Red
    Write-Host "Instalacja lub uruchomienie nie powiodlo sie. Uruchom start.bat ponownie, aby naprawic srodowisko." -ForegroundColor Red
    exit 1
}
