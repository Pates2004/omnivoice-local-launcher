[CmdletBinding()]
param(
    [ValidateSet("Auto", "System", "Portable")]
    [string]$Mode = "Auto",
    [ValidateSet("Auto", "CUDA", "ROCm", "XPU", "CPU")]
    [string]$Backend = "Auto",
    [switch]$NoBrowser,
    [switch]$BootstrapOnly,
    [switch]$InstallOnly,
    [switch]$SelfTest
)

$ModeWasExplicit = $PSBoundParameters.ContainsKey("Mode")
$BackendWasExplicit = $PSBoundParameters.ContainsKey("Backend")

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Join-Path $ProjectRoot "env"
$VenvDir = Join-Path $ProjectRoot "venv"
$WorkDir = Join-Path $ProjectRoot ".launcher"
$ModeFile = Join-Path $WorkDir "python-mode.txt"
$BackendFile = Join-Path $WorkDir "backend.txt"
$BackendMatrixPath = Join-Path $ProjectRoot "installer_backends.json"
$RuntimeRequirementsPath = Join-Path $ProjectRoot "requirements-launcher.txt"
$PythonVersion = "3.12.10"
$PythonArchiveUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$PythonArchiveMd5 = "fe8ef205f2e9c3ba44d0cf9954e1abd3"
$GetPipUrl = "https://bootstrap.pypa.io/get-pip.py"
$LauncherRevision = 8
$script:LastRuntimeError = ""

function Write-Step {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarningMessage {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Assert-ProjectChildPath {
    param([string]$Path)
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $target = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($target -eq $root -or -not $target.StartsWith(
        $root + '\', [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to modify a directory outside OmniVoice: $target"
    }
    return $target
}

function Remove-LauncherDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $target = Assert-ProjectChildPath $Path
    Remove-Item -LiteralPath $target -Recurse -Force
}

function Invoke-Checked {
    param([string]$FilePath, [string[]]$Arguments, [string]$Description)
    Write-Step $Description
    & $FilePath @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Get-BackendMatrix {
    if (-not (Test-Path -LiteralPath $BackendMatrixPath)) {
        throw "Backend matrix is missing: $BackendMatrixPath"
    }
    try {
        $matrix = Get-Content -LiteralPath $BackendMatrixPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        throw "Backend matrix is not valid JSON: $($_.Exception.Message)"
    }
    if ($matrix.schema_version -ne 1) {
        throw "Unsupported backend matrix schema: $($matrix.schema_version)"
    }
    foreach ($name in @("cuda", "rocm", "xpu", "cpu")) {
        if ($null -eq $matrix.profiles.PSObject.Properties[$name]) {
            throw "Backend matrix does not define '$name'."
        }
    }
    return $matrix
}

function Get-BackendProfile {
    param([object]$Matrix, [string]$Name)
    $property = $Matrix.profiles.PSObject.Properties[$Name.ToLowerInvariant()]
    if ($null -eq $property) { throw "Unknown backend profile: $Name" }
    return $property.Value
}

function Get-StringSha256 {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    }
    finally { $sha.Dispose() }
}

function Get-ProjectFingerprint {
    $parts = foreach ($relativePath in @(
        "pyproject.toml", "requirements-launcher.txt", "installer_backends.json"
    )) {
        $path = Join-Path $ProjectRoot $relativePath
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required installer input is missing: $relativePath"
        }
        "$relativePath=$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)"
    }
    return Get-StringSha256 ($parts -join "|")
}

function Get-ProfileFingerprint {
    param([object]$Profile)
    return Get-StringSha256 ($Profile | ConvertTo-Json -Depth 8 -Compress)
}

function Get-VideoControllers {
    try {
        return @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Select-Object Name, PNPDeviceID)
    }
    catch {
        try {
            return @(Get-WmiObject Win32_VideoController -ErrorAction Stop |
                Select-Object Name, PNPDeviceID)
        }
        catch {
            Write-WarningMessage "Windows GPU inventory could not be read; CPU will be used in Auto mode."
            return @()
        }
    }
}

function Get-ProcessorName {
    try {
        return [string](Get-CimInstance Win32_Processor -ErrorAction Stop |
            Select-Object -First 1 -ExpandProperty Name)
    }
    catch {
        try {
            return [string](Get-WmiObject Win32_Processor -ErrorAction Stop |
                Select-Object -First 1 -ExpandProperty Name)
        }
        catch { return [Environment]::GetEnvironmentVariable("PROCESSOR_IDENTIFIER") }
    }
}

function Test-ProfileHardwareName {
    param([object]$Profile, [string]$Name)
    foreach ($pattern in @($Profile.supported_hardware_patterns)) {
        if ($Name -match $pattern) { return $true }
    }
    return $false
}

function Get-HardwareInventory {
    param([object[]]$Controllers, [string]$ProcessorName, [object]$Matrix)
    $items = @()
    foreach ($controller in @($Controllers)) {
        $name = [string]$controller.Name
        $pnp = [string]$controller.PNPDeviceID
        $vendor = "other"
        $backend = "cpu"
        if ($name -match "NVIDIA" -or $pnp -match "VEN_10DE") {
            $vendor = "nvidia"; $backend = "cuda"
        }
        elseif ($name -match "AMD|Radeon" -or $pnp -match "VEN_1002") {
            $vendor = "amd"; $backend = "rocm"
        }
        elseif ($name -match "Intel" -or $pnp -match "VEN_8086") {
            $vendor = "intel"; $backend = "xpu"
        }
        $profile = Get-BackendProfile $Matrix $backend
        $matchText = "$name $ProcessorName"
        $supported = $backend -eq "cuda" -or (
            $backend -ne "cpu" -and (Test-ProfileHardwareName $profile $matchText)
        )
        $items += [pscustomobject]@{
            Name = $name
            PNPDeviceID = $pnp
            Vendor = $vendor
            Backend = $backend
            Supported = [bool]$supported
        }
    }
    return $items
}

function Get-HardwareBackend {
    param(
        [object[]]$Inventory,
        [object]$Matrix,
        [int]$WindowsBuild = [Environment]::OSVersion.Version.Build
    )
    foreach ($candidate in @("cuda", "rocm", "xpu")) {
        $profile = Get-BackendProfile $Matrix $candidate
        if ($WindowsBuild -lt [int]$profile.windows_min_build) { continue }
        if (@($Inventory | Where-Object {
            $_.Backend -eq $candidate -and $_.Supported
        }).Count -gt 0) { return $candidate }
    }
    return "cpu"
}

function Get-HardwareFingerprint {
    param([object[]]$Controllers, [string]$ProcessorName)
    $devices = foreach ($controller in @($Controllers) | Sort-Object Name, PNPDeviceID) {
        "$([string]$controller.Name)|$([string]$controller.PNPDeviceID)"
    }
    return Get-StringSha256 ((@($ProcessorName) + @($devices)) -join "||")
}

function Resolve-RequestedBackend {
    param(
        [bool]$CliExplicit,
        [string]$CliValue,
        [string]$EnvironmentValue,
        [string]$SavedValue
    )
    $allowed = @("auto", "cuda", "rocm", "xpu", "cpu")
    if ($CliExplicit) { return $CliValue.ToLowerInvariant() }
    if (-not [string]::IsNullOrWhiteSpace($EnvironmentValue)) {
        $environmentBackend = $EnvironmentValue.Trim().ToLowerInvariant()
        if ($environmentBackend -notin $allowed) {
            throw "OMNIVOICE_BACKEND must be one of: auto, cuda, rocm, xpu, cpu."
        }
        return $environmentBackend
    }
    if (-not [string]::IsNullOrWhiteSpace($SavedValue)) {
        $savedBackend = $SavedValue.Trim().ToLowerInvariant()
        if ($savedBackend -in $allowed) { return $savedBackend }
    }
    return "auto"
}

function Get-SavedText {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return (Get-Content -LiteralPath $Path -Raw).Trim()
    }
    return ""
}

function Save-BackendPreference {
    param([string]$RequestedBackend)
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $RequestedBackend | Set-Content -LiteralPath $BackendFile -Encoding ASCII
}

function Test-CompatiblePython {
    param([string]$Python, [object]$Profile = $null)
    if (-not (Test-Path -LiteralPath $Python)) { return $false }
    & $Python -c "import sys; raise SystemExit(0 if (3, 10) <= sys.version_info[:2] < (3, 14) and sys.maxsize > 2**32 else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    if ($null -ne $Profile) {
        $minimum = [Version]$Profile.python_min
        $maximum = [Version]$Profile.python_max_exclusive
        $versionText = (& $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null |
            Select-Object -Last 1)
        if (-not $versionText) { return $false }
        $version = [Version]$versionText.Trim()
        if ($version -lt $minimum -or $version -ge $maximum) { return $false }
    }
    return $true
}

function Find-SystemPython {
    param([object]$Profile)
    $seen = @{}
    $candidates = @()
    $py = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($null -ne $py) {
        foreach ($selector in @("-3.13", "-3.12", "-3.11", "-3.10", "-3")) {
            try {
                $path = (& $py.Source $selector -c "import sys; print(sys.executable)" 2>$null |
                    Select-Object -Last 1)
                if ($LASTEXITCODE -eq 0 -and $path) { $candidates += $path.Trim() }
            }
            catch { continue }
        }
    }
    $python = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($null -ne $python) { $candidates += $python.Source }
    foreach ($candidate in $candidates) {
        if ($seen.ContainsKey($candidate)) { continue }
        $seen[$candidate] = $true
        if (Test-CompatiblePython $candidate $Profile) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-EnvironmentRootForMode {
    param([string]$SelectedMode)
    if ($SelectedMode -eq "Portable") { return $PortableDir }
    return $VenvDir
}

function Get-EnvironmentPython {
    param([string]$SelectedMode, [string]$EnvironmentRoot)
    if ($SelectedMode -eq "Portable") { return Join-Path $EnvironmentRoot "python.exe" }
    return Join-Path $EnvironmentRoot "Scripts\python.exe"
}

function Select-FirstRunMode {
    param([string]$SystemPython, [object]$Profile)
    Write-Host ""
    if ($SystemPython) {
        Write-Host "A compatible system Python was found: $SystemPython"
        Write-Host "Znaleziono zgodnego Pythona systemowego: $SystemPython"
        Write-Host "[1] Portable Python inside OmniVoice (recommended)"
        Write-Host "    Wlasny Python wewnatrz OmniVoice (zalecane)"
        Write-Host "[2] Local venv based on the system Python"
        Write-Host "    Lokalne venv oparte na Pythonie systemowym"
        do { $answer = Read-Host "Choice / Wybor [1-2]" } while ($answer -notin @("1", "2"))
        if ($answer -eq "2") { return "System" }
        return "Portable"
    }
    Write-Host "No compatible system Python was found for $($Profile.display_name)."
    Write-Host "Nie znaleziono zgodnego Pythona systemowego dla $($Profile.display_name)."
    Write-Host "[1] Download portable Python $PythonVersion for OmniVoice (recommended)"
    Write-Host "    Pobierz wlasnego Pythona $PythonVersion dla OmniVoice (zalecane)"
    Write-Host "[2] Open the official Python download page and exit"
    Write-Host "    Otworz oficjalna strone Pythona i zakoncz"
    do { $answer = Read-Host "Choice / Wybor [1-2]" } while ($answer -notin @("1", "2"))
    if ($answer -eq "2") {
        Start-Process "https://www.python.org/downloads/windows/"
        return "Website"
    }
    return "Portable"
}

function Resolve-PythonMode {
    param([string]$RequestedMode, [bool]$WasExplicit, [object]$Profile)
    $savedMode = Get-SavedText $ModeFile
    $preferred = $RequestedMode
    if ($preferred -eq "Auto" -and $env:OMNIVOICE_PYTHON_MODE -in @("System", "Portable")) {
        $preferred = $env:OMNIVOICE_PYTHON_MODE
    }
    if ($preferred -eq "Auto" -and $savedMode -in @("System", "Portable")) {
        $preferred = $savedMode
    }
    $systemPython = Find-SystemPython $Profile
    if ($preferred -eq "System" -and -not $systemPython) {
        $existingVenvPython = Get-EnvironmentPython "System" $VenvDir
        if (Test-CompatiblePython $existingVenvPython $Profile) {
            return [pscustomobject]@{ Mode = "System"; SystemPython = $null }
        }
        if ($WasExplicit -or $env:OMNIVOICE_PYTHON_MODE -eq "System") {
            throw "System mode requires a compatible Python $($Profile.python_min)-$($Profile.python_max_exclusive)."
        }
        Write-WarningMessage "The saved system Python mode is incompatible with this backend; switching to portable Python $PythonVersion."
        $preferred = "Portable"
    }
    if ($preferred -eq "System") {
        return [pscustomobject]@{ Mode = "System"; SystemPython = $systemPython }
    }
    if ($preferred -eq "Portable") {
        return [pscustomobject]@{ Mode = "Portable"; SystemPython = $systemPython }
    }
    $portablePython = Get-EnvironmentPython "Portable" $PortableDir
    if (Test-CompatiblePython $portablePython $Profile) {
        return [pscustomobject]@{ Mode = "Portable"; SystemPython = $systemPython }
    }
    $venvPython = Get-EnvironmentPython "System" $VenvDir
    if (Test-CompatiblePython $venvPython $Profile) {
        return [pscustomobject]@{ Mode = "System"; SystemPython = $systemPython }
    }
    $selected = Select-FirstRunMode $systemPython $Profile
    return [pscustomobject]@{ Mode = $selected; SystemPython = $systemPython }
}

function Install-PortablePythonAt {
    param([string]$TargetRoot)
    Assert-ProjectChildPath $TargetRoot | Out-Null
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $archive = Join-Path $WorkDir "python-$PythonVersion-embed-amd64.zip"
    $needsDownload = $true
    if (Test-Path -LiteralPath $archive) {
        $actualMd5 = (Get-FileHash -LiteralPath $archive -Algorithm MD5).Hash.ToLowerInvariant()
        $needsDownload = $actualMd5 -ne $PythonArchiveMd5
        if ($needsDownload) { Remove-Item -LiteralPath $archive -Force }
    }
    if ($needsDownload) {
        Write-Step "Downloading portable Python $PythonVersion from python.org..."
        Invoke-WebRequest -UseBasicParsing -Uri $PythonArchiveUrl -OutFile $archive
    }
    $actualMd5 = (Get-FileHash -LiteralPath $archive -Algorithm MD5).Hash.ToLowerInvariant()
    if ($actualMd5 -ne $PythonArchiveMd5) {
        throw "Portable Python checksum mismatch. Expected $PythonArchiveMd5, got $actualMd5."
    }
    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $TargetRoot -Force
    $pth = @(Get-ChildItem -LiteralPath $TargetRoot -Filter "python*._pth")
    if ($pth.Count -ne 1) { throw "Could not locate portable Python _pth configuration." }
    (Get-Content -LiteralPath $pth[0].FullName) -replace '^#import site$', 'import site' |
        Set-Content -LiteralPath $pth[0].FullName -Encoding ASCII
    $python = Get-EnvironmentPython "Portable" $TargetRoot
    if (-not (Test-CompatiblePython $python)) { throw "Portable Python is not compatible." }
    $getPip = Join-Path $TargetRoot "get-pip.py"
    Write-Step "Downloading the official pip bootstrap script..."
    Invoke-WebRequest -UseBasicParsing -Uri $GetPipUrl -OutFile $getPip
    try {
        Invoke-Checked -FilePath $python -Arguments @(
            $getPip, "--disable-pip-version-check", "--no-warn-script-location"
        ) -Description "Installing pip"
    }
    finally {
        if (Test-Path -LiteralPath $getPip) { Remove-Item -LiteralPath $getPip -Force }
    }
    return $python
}

function New-SystemEnvironmentAt {
    param([string]$SystemPython, [string]$TargetRoot, [object]$Profile)
    if (-not (Test-CompatiblePython $SystemPython $Profile)) {
        throw "A compatible 64-bit system Python is required for $($Profile.display_name)."
    }
    Assert-ProjectChildPath $TargetRoot | Out-Null
    Invoke-Checked -FilePath $SystemPython -Arguments @(
        "-m", "venv", $TargetRoot
    ) -Description "Creating the local virtual environment"
    $python = Get-EnvironmentPython "System" $TargetRoot
    if (-not (Test-CompatiblePython $python $Profile)) {
        throw "The new virtual environment is not usable for this backend."
    }
    return $python
}

function New-PythonEnvironmentAt {
    param(
        [string]$SelectedMode, [string]$TargetRoot,
        [string]$SystemPython, [object]$Profile
    )
    Remove-LauncherDirectory $TargetRoot
    if ($SelectedMode -eq "Portable") { return Install-PortablePythonAt $TargetRoot }
    if (-not $SystemPython) { $SystemPython = Find-SystemPython $Profile }
    return New-SystemEnvironmentAt $SystemPython $TargetRoot $Profile
}

function Install-PythonBootstrapTransaction {
    param(
        [string]$SelectedMode, [string]$SystemPython,
        [object]$Profile, [string]$ActiveRoot
    )
    $stagingRoot = "$ActiveRoot.new"
    $backupRoot = "$ActiveRoot.old"
    $stagingPython = New-PythonEnvironmentAt $SelectedMode $stagingRoot $SystemPython $Profile
    if (-not (Test-CompatiblePython $stagingPython $Profile)) {
        throw "The staged Python bootstrap is not compatible with this backend."
    }
    Remove-LauncherDirectory $backupRoot
    if (Test-Path -LiteralPath $ActiveRoot) {
        Move-Item -LiteralPath $ActiveRoot -Destination $backupRoot
    }
    try {
        Move-Item -LiteralPath $stagingRoot -Destination $ActiveRoot
        $python = Get-EnvironmentPython $SelectedMode $ActiveRoot
        if (-not (Test-CompatiblePython $python $Profile)) {
            throw "The activated Python bootstrap is not usable."
        }
        return $python
    }
    catch {
        Remove-LauncherDirectory $ActiveRoot
        if (Test-Path -LiteralPath $backupRoot) {
            Move-Item -LiteralPath $backupRoot -Destination $ActiveRoot
        }
        throw "The previous environment was restored after bootstrap failure. $($_.Exception.Message)"
    }
}

function Invoke-AcceleratorProbe {
    param([string]$Python, [string]$ExpectedBackend)
    $output = @(& $Python -m omnivoice.accelerator --validate $ExpectedBackend --json 2>&1)
    $exitCode = $LASTEXITCODE
    $textOutput = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $jsonLine = $output | ForEach-Object { $_.ToString() } |
        Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1
    if (-not $jsonLine) { throw "Accelerator validation returned no diagnostics. $textOutput" }
    try { $result = $jsonLine | ConvertFrom-Json }
    catch { throw "Accelerator validation returned invalid diagnostics. $textOutput" }
    if ($exitCode -ne 0 -or -not $result.ok) {
        throw "Accelerator validation failed: $($result.error)"
    }
    return $result
}

function Test-ReadyMarkerData {
    param(
        [object]$Marker, [string]$ExpectedBackend, [string]$HardwareFingerprint,
        [string]$ProjectFingerprint, [string]$ProfileFingerprint, [object]$Profile
    )
    if ($null -eq $Marker) { return $false }
    if ([int]$Marker.revision -ne $LauncherRevision) { return $false }
    if ([string]$Marker.project -ne $ProjectFingerprint) { return $false }
    if ([string]$Marker.backend -ne $ExpectedBackend) { return $false }
    if ([string]$Marker.hardware_fingerprint -ne $HardwareFingerprint) { return $false }
    if ([string]$Marker.profile_fingerprint -ne $ProfileFingerprint) { return $false }
    if ([string]$Marker.torch_version -ne [string]$Profile.torch_version) { return $false }
    if ([string]$Marker.torchaudio_version -ne [string]$Profile.torchaudio_version) {
        return $false
    }
    return $true
}

function Read-ReadyMarker {
    param([string]$EnvironmentRoot)
    $path = Join-Path $EnvironmentRoot ".omnivoice-ready"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Test-Runtime {
    param(
        [string]$Python, [string]$ExpectedBackend, [object]$Profile,
        [string]$HardwareFingerprint, [string]$EnvironmentRoot
    )
    $script:LastRuntimeError = ""
    try {
        if (-not (Test-CompatiblePython $Python $Profile)) {
            throw "The environment uses an incompatible Python version."
        }
        $marker = Read-ReadyMarker $EnvironmentRoot
        $markerValid = Test-ReadyMarkerData -Marker $marker `
            -ExpectedBackend $ExpectedBackend -HardwareFingerprint $HardwareFingerprint `
            -ProjectFingerprint (Get-ProjectFingerprint) `
            -ProfileFingerprint (Get-ProfileFingerprint $Profile) -Profile $Profile
        if (-not $markerValid) {
            throw "The ready marker is missing, stale, or belongs to different hardware."
        }
        & $Python -c "import accelerate, gradio, librosa, numpy, pydub, soundfile, tensorboardX, torch, torchaudio, transformers, webdataset; import omnivoice" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "One or more OmniVoice runtime imports failed." }
        & $Python -m pip check *> $null
        if ($LASTEXITCODE -ne 0) { throw "pip check found an inconsistent environment." }
        $probe = Invoke-AcceleratorProbe $Python $ExpectedBackend
        if ([string]$probe.torch_version -ne [string]$Profile.torch_version) {
            throw "Installed torch $($probe.torch_version) does not match $($Profile.torch_version)."
        }
        if ([string]$probe.torchaudio_version -ne [string]$Profile.torchaudio_version) {
            throw "Installed torchaudio $($probe.torchaudio_version) does not match $($Profile.torchaudio_version)."
        }
        return $true
    }
    catch {
        $script:LastRuntimeError = $_.Exception.Message
        return $false
    }
}

function Write-ReadyMarker {
    param(
        [string]$EnvironmentRoot, [string]$RequestedBackend,
        [string]$SelectedBackend, [object]$Profile, [string]$HardwareFingerprint,
        [string]$Python, [object]$Probe
    )
    $pythonVersion = (& $Python -c "import platform; print(platform.python_version())" |
        Select-Object -Last 1).Trim()
    $payload = [ordered]@{
        revision = $LauncherRevision
        project = Get-ProjectFingerprint
        profile_fingerprint = Get-ProfileFingerprint $Profile
        requested_backend = $RequestedBackend
        backend = $SelectedBackend
        torch_version = [string]$Probe.torch_version
        torchaudio_version = [string]$Probe.torchaudio_version
        runtime_version = [string]$Probe.runtime_version
        device_name = [string]$Probe.name
        device = [string]$Probe.device
        python_version = $pythonVersion
        hardware_fingerprint = $HardwareFingerprint
        created_utc = [DateTime]::UtcNow.ToString("o")
    }
    $marker = Join-Path $EnvironmentRoot ".omnivoice-ready"
    $temporaryMarker = "$marker.tmp"
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryMarker -Encoding UTF8
    Move-Item -LiteralPath $temporaryMarker -Destination $marker -Force
}

function Install-BackendRuntime {
    param(
        [string]$Python, [string]$RequestedBackend, [string]$SelectedBackend,
        [object]$Profile, [string]$HardwareFingerprint, [string]$EnvironmentRoot
    )
    Invoke-Checked -FilePath $Python -Arguments @(
        "-m", "pip", "install", "--upgrade", "pip", "--no-warn-script-location"
    ) -Description "Updating pip"
    $prerequisites = @($Profile.prerequisite_packages)
    if ($prerequisites.Count -gt 0) {
        $arguments = @("-m", "pip", "install", "--no-cache-dir", "--no-warn-script-location")
        $arguments += $prerequisites
        Invoke-Checked -FilePath $Python -Arguments $arguments `
            -Description "Installing prerequisites for $($Profile.display_name)"
    }
    $torchArguments = @(
        "-m", "pip", "install", "--no-cache-dir", "--no-warn-script-location"
    )
    $torchArguments += @($Profile.packages)
    if ($null -ne $Profile.index_url -and -not [string]::IsNullOrWhiteSpace($Profile.index_url)) {
        $torchArguments += @("--index-url", [string]$Profile.index_url)
    }
    Invoke-Checked -FilePath $Python -Arguments $torchArguments `
        -Description "Installing PyTorch for $($Profile.display_name)"
    Invoke-Checked -FilePath $Python -Arguments @(
        "-m", "pip", "install", "-r", $RuntimeRequirementsPath, "--no-warn-script-location"
    ) -Description "Installing OmniVoice web dependencies"
    Invoke-Checked -FilePath $Python -Arguments @(
        "-m", "pip", "install", "--no-deps", "--no-build-isolation",
        "--no-warn-script-location", "-e", $ProjectRoot
    ) -Description "Installing OmniVoice without replacing the selected PyTorch build"
    Invoke-Checked -FilePath $Python -Arguments @(
        "-m", "pip", "check"
    ) -Description "Checking installed dependencies"
    Invoke-Checked -FilePath $Python -Arguments @(
        "-c", "import accelerate, gradio, librosa, numpy, pydub, soundfile, tensorboardX, torch, torchaudio, transformers, webdataset; import omnivoice"
    ) -Description "Validating the complete OmniVoice web runtime"
    Write-Step "Testing $($Profile.display_name) with a real tensor operation"
    $probe = Invoke-AcceleratorProbe $Python $SelectedBackend
    if ([string]$probe.torch_version -ne [string]$Profile.torch_version) {
        throw "The PyTorch installer returned $($probe.torch_version), expected $($Profile.torch_version)."
    }
    if ([string]$probe.torchaudio_version -ne [string]$Profile.torchaudio_version) {
        throw "The TorchAudio installer returned $($probe.torchaudio_version), expected $($Profile.torchaudio_version)."
    }
    Write-ReadyMarker $EnvironmentRoot $RequestedBackend $SelectedBackend $Profile `
        $HardwareFingerprint $Python $probe
}

function Install-RuntimeTransaction {
    param(
        [string]$SelectedMode, [string]$SystemPython, [string]$RequestedBackend,
        [string]$SelectedBackend, [object]$Profile, [string]$HardwareFingerprint
    )
    $activeRoot = Get-EnvironmentRootForMode $SelectedMode
    $stagingRoot = "$activeRoot.new"
    $backupRoot = "$activeRoot.old"
    Assert-ProjectChildPath $activeRoot | Out-Null
    Assert-ProjectChildPath $stagingRoot | Out-Null
    Assert-ProjectChildPath $backupRoot | Out-Null
    Remove-LauncherDirectory $stagingRoot
    $stagingPython = New-PythonEnvironmentAt $SelectedMode $stagingRoot $SystemPython $Profile
    try {
        Install-BackendRuntime $stagingPython $RequestedBackend $SelectedBackend $Profile `
            $HardwareFingerprint $stagingRoot
        if (-not (Test-Runtime $stagingPython $SelectedBackend $Profile `
            $HardwareFingerprint $stagingRoot)) {
            throw "Staged runtime validation failed: $script:LastRuntimeError"
        }
    }
    catch { throw "The staged environment was not activated. $($_.Exception.Message)" }
    Remove-LauncherDirectory $backupRoot
    if (Test-Path -LiteralPath $activeRoot) {
        Move-Item -LiteralPath $activeRoot -Destination $backupRoot
    }
    try {
        Move-Item -LiteralPath $stagingRoot -Destination $activeRoot
        $activePython = Get-EnvironmentPython $SelectedMode $activeRoot
        if (-not (Test-Runtime $activePython $SelectedBackend $Profile `
            $HardwareFingerprint $activeRoot)) {
            throw "Activated runtime validation failed: $script:LastRuntimeError"
        }
        return $activePython
    }
    catch {
        $failedRoot = "$activeRoot.failed"
        Remove-LauncherDirectory $failedRoot
        if (Test-Path -LiteralPath $activeRoot) {
            Move-Item -LiteralPath $activeRoot -Destination $failedRoot
        }
        if (Test-Path -LiteralPath $backupRoot) {
            Move-Item -LiteralPath $backupRoot -Destination $activeRoot
        }
        Remove-LauncherDirectory $failedRoot
        throw "The previous environment was restored. $($_.Exception.Message)"
    }
}

function Show-HardwareSummary {
    param([object[]]$Inventory, [string]$SelectedBackend, [object]$Profile)
    Write-Step "Detecting hardware..."
    foreach ($item in @($Inventory)) {
        $support = if ($item.Supported) { "supported candidate" } else { "not supported by this profile" }
        Write-Host "  $($item.Name) [$($item.Vendor), $support]"
    }
    if (@($Inventory).Count -eq 0) { Write-Host "  No physical video controller was detected." }
    if ($SelectedBackend -eq "cpu") {
        Write-WarningMessage "No supported GPU accelerator was selected. OmniVoice will use CPU and generation can be substantially slower."
        Write-Host "Nie wybrano obslugiwanego akceleratora GPU. OmniVoice uzyje CPU, wiec generowanie moze byc znacznie wolniejsze."
    }
    else {
        Write-Step "$($Profile.display_name) selected."
        if ($Profile.experimental) {
            Write-WarningMessage "$($Profile.display_name) support is experimental until OmniVoice inference is verified on real hardware."
        }
    }
}

function Install-WithRecoveryChoice {
    param(
        [string]$SelectedMode, [string]$SystemPython, [string]$RequestedBackend,
        [string]$SelectedBackend, [object]$Matrix, [string]$HardwareFingerprint
    )
    while ($true) {
        $profile = Get-BackendProfile $Matrix $SelectedBackend
        try {
            $python = Install-RuntimeTransaction $SelectedMode $SystemPython `
                $RequestedBackend $SelectedBackend $profile $HardwareFingerprint
            return [pscustomobject]@{
                Python = $python
                Backend = $SelectedBackend
                Profile = $profile
                RequestedBackend = $RequestedBackend
            }
        }
        catch {
            $details = $_.Exception.Message
            if ($SelectedBackend -eq "cpu") { throw $details }
            Write-Host ""
            Write-Host "[ERROR] $($profile.display_name) could not be activated." -ForegroundColor Red
            Write-Host "Nie udalo sie uruchomic akceleracji $($profile.display_name)." -ForegroundColor Red
            Write-WarningMessage "CPU fallback is much slower and will never be selected silently."
            while ($true) {
                Write-Host "[1] Retry $($profile.display_name) / Sprobuj ponownie"
                Write-Host "[2] Use CPU / Uzyj CPU"
                Write-Host "[3] Show details / Pokaz szczegoly"
                Write-Host "[4] Abort / Przerwij"
                $answer = Read-Host "Choice / Wybor [1-4]"
                if ($answer -eq "1") { break }
                if ($answer -eq "2") {
                    $SelectedBackend = "cpu"
                    $RequestedBackend = "cpu"
                    Save-BackendPreference "cpu"
                    break
                }
                if ($answer -eq "3") {
                    Write-Host ""; Write-Host $details -ForegroundColor DarkYellow; Write-Host ""
                    continue
                }
                if ($answer -eq "4") { throw $details }
            }
        }
    }
}

function Start-BrowserWatcher {
    if ($NoBrowser -or $env:OMNIVOICE_NO_BROWSER -eq "1") { return $null }
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
                # The web server is not ready yet.
            }
            finally { $client.Dispose() }
            Start-Sleep -Seconds 1
        }
    }
}

function Invoke-SelfTest {
    $matrix = Get-BackendMatrix
    foreach ($requiredPath in @(
        "pyproject.toml", "requirements-launcher.txt", "installer_backends.json",
        "omnivoice\cli\demo.py", "omnivoice\accelerator.py", "start.bat"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $requiredPath))) {
            throw "$requiredPath is missing."
        }
    }
    if ($PythonArchiveUrl -notmatch '^https://www\.python\.org/') {
        throw "Portable Python must be downloaded from python.org."
    }
    if ($PythonArchiveMd5 -notmatch '^[0-9a-f]{32}$') {
        throw "Portable Python checksum is malformed."
    }
    $projectMetadata = Get-Content -LiteralPath (Join-Path $ProjectRoot "pyproject.toml") -Raw
    if ($projectMetadata -match '\[tool\.uv\.sources\]' -or
        $projectMetadata -match 'download\.pytorch\.org/whl/cu') {
        throw "pyproject.toml still selects a binary PyTorch backend."
    }
    $runtimeRequirements = Get-Content -LiteralPath $RuntimeRequirementsPath
    if ($runtimeRequirements | Where-Object { $_ -match '^\s*torch(audio)?\s*[=<>]' }) {
        throw "requirements-launcher.txt must not install torch or torchaudio."
    }
    $nvidia = @([pscustomobject]@{ Name = "NVIDIA GeForce RTX"; PNPDeviceID = "PCI\VEN_10DE" })
    $amd = @([pscustomobject]@{ Name = "AMD Radeon RX 7900 XTX"; PNPDeviceID = "PCI\VEN_1002" })
    $intel = @([pscustomobject]@{ Name = "Intel(R) Arc(TM) Graphics"; PNPDeviceID = "PCI\VEN_8086" })
    $oldAmd = @([pscustomobject]@{ Name = "AMD Radeon RX 580"; PNPDeviceID = "PCI\VEN_1002" })
    $oldIntel = @([pscustomobject]@{ Name = "Intel(R) UHD Graphics 630"; PNPDeviceID = "PCI\VEN_8086" })
    $nvidiaInventory = Get-HardwareInventory $nvidia "Test CPU" $matrix
    $amdInventory = Get-HardwareInventory $amd "Test CPU" $matrix
    $intelInventory = Get-HardwareInventory $intel "Intel Core Ultra" $matrix
    if ((Get-HardwareBackend $nvidiaInventory $matrix 26000) -ne "cuda") { throw "NVIDIA detection test failed." }
    if ((Get-HardwareBackend $amdInventory $matrix 26000) -ne "rocm") { throw "AMD ROCm detection test failed." }
    if ((Get-HardwareBackend $intelInventory $matrix 26000) -ne "xpu") { throw "Intel XPU detection test failed." }
    if ((Get-HardwareBackend @() $matrix 26000) -ne "cpu") { throw "CPU detection test failed." }
    if ((Get-HardwareBackend $amdInventory $matrix 19045) -ne "cpu") {
        throw "Native Windows ROCm must not be selected on Windows 10."
    }
    if ((Get-HardwareBackend $intelInventory $matrix 19045) -ne "cpu") {
        throw "Intel client XPU must not be selected on Windows 10."
    }
    if ((Get-HardwareBackend (Get-HardwareInventory $oldAmd "Test CPU" $matrix) $matrix 26000) -ne "cpu") {
        throw "Unsupported AMD hardware must not select ROCm."
    }
    if ((Get-HardwareBackend (Get-HardwareInventory $oldIntel "Test CPU" $matrix) $matrix 26000) -ne "cpu") {
        throw "Unsupported Intel hardware must not select XPU."
    }
    $mixed = @($amdInventory) + @($nvidiaInventory) + @($intelInventory)
    if ((Get-HardwareBackend $mixed $matrix 26000) -ne "cuda") { throw "Multi-GPU priority test failed." }
    if ((Resolve-RequestedBackend $true "CPU" "rocm" "cuda") -ne "cpu") {
        throw "CLI backend override priority test failed."
    }
    if ((Resolve-RequestedBackend $false "Auto" "xpu" "cuda") -ne "xpu") {
        throw "Environment backend override priority test failed."
    }
    if ((Resolve-RequestedBackend $false "Auto" "" "rocm") -ne "rocm") {
        throw "Saved backend preference test failed."
    }
    $profile = Get-BackendProfile $matrix "cuda"
    $marker = [pscustomobject]@{
        revision = $LauncherRevision
        project = "project"
        backend = "cuda"
        hardware_fingerprint = "hardware"
        profile_fingerprint = "profile"
        torch_version = $profile.torch_version
        torchaudio_version = $profile.torchaudio_version
    }
    if (-not (Test-ReadyMarkerData $marker "cuda" "hardware" "project" "profile" $profile)) {
        throw "Valid marker test failed."
    }
    if (Test-ReadyMarkerData $marker "cuda" "changed" "project" "profile" $profile) {
        throw "Hardware changes must invalidate the ready marker."
    }
    $batchLauncher = Get-Content -LiteralPath (Join-Path $ProjectRoot "start.bat") -Raw
    if ($batchLauncher -notmatch 'launcher\.ps1' -or $batchLauncher -notmatch '%\*') {
        throw "The batch launcher does not forward arguments to launcher.ps1."
    }
    Write-Host "OmniVoice launcher self-test: OK (CUDA, ROCm, XPU, CPU)"
}

function Invoke-Main {
    Set-Location -LiteralPath $ProjectRoot
    if ($SelfTest) { Invoke-SelfTest; return }
    $matrix = Get-BackendMatrix
    $controllers = Get-VideoControllers
    $processorName = Get-ProcessorName
    $inventory = Get-HardwareInventory $controllers $processorName $matrix
    $hardwareFingerprint = Get-HardwareFingerprint $controllers $processorName
    $savedBackend = Get-SavedText $BackendFile
    $requestedBackend = Resolve-RequestedBackend $BackendWasExplicit $Backend `
        $env:OMNIVOICE_BACKEND $savedBackend
    if ($BackendWasExplicit) { Save-BackendPreference $requestedBackend }
    $selectedBackend = if ($requestedBackend -eq "auto") {
        Get-HardwareBackend $inventory $matrix
    }
    else { $requestedBackend }
    $profile = Get-BackendProfile $matrix $selectedBackend
    if ([Environment]::OSVersion.Version.Build -lt [int]$profile.windows_min_build) {
        if ($requestedBackend -ne "auto") {
            throw "$($profile.display_name) requires Windows build $($profile.windows_min_build) or newer."
        }
        $selectedBackend = "cpu"
        $profile = Get-BackendProfile $matrix "cpu"
    }
    Show-HardwareSummary $inventory $selectedBackend $profile
    if ($requestedBackend -ne "auto" -and $selectedBackend -ne "cpu") {
        $matchingHardware = @($inventory | Where-Object {
            $_.Backend -eq $selectedBackend -and $_.Supported
        })
        if ($matchingHardware.Count -eq 0) {
            Write-WarningMessage "$($profile.display_name) was forced without a supported matching GPU. Runtime validation will decide whether it can be used."
        }
    }
    $modeSelection = Resolve-PythonMode $Mode $ModeWasExplicit $profile
    if ($modeSelection.Mode -eq "Website") { return }
    $selectedMode = $modeSelection.Mode
    $systemPython = $modeSelection.SystemPython
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $selectedMode | Set-Content -LiteralPath $ModeFile -Encoding ASCII
    $activeRoot = Get-EnvironmentRootForMode $selectedMode
    $python = Get-EnvironmentPython $selectedMode $activeRoot
    if ($BootstrapOnly) {
        if (-not (Test-CompatiblePython $python $profile)) {
            $python = Install-PythonBootstrapTransaction $selectedMode $systemPython `
                $profile $activeRoot
        }
        Write-Host "Bootstrap test completed with $selectedMode Python: $python"
        return
    }
    if (-not (Test-Runtime $python $selectedBackend $profile $hardwareFingerprint $activeRoot)) {
        if ($script:LastRuntimeError) { Write-Step "Runtime repair required: $script:LastRuntimeError" }
        $installed = Install-WithRecoveryChoice $selectedMode $systemPython `
            $requestedBackend $selectedBackend $matrix $hardwareFingerprint
        $python = $installed.Python
        $selectedBackend = $installed.Backend
        $profile = $installed.Profile
        $requestedBackend = $installed.RequestedBackend
    }
    if ($InstallOnly) {
        Write-Host "Runtime installation and validation completed successfully: $python"
        Write-Host "Backend: $($profile.display_name)"
        return
    }
    Write-Host ""
    Write-Step "Starting OmniVoice with $($profile.display_name) at http://127.0.0.1:7860"
    $env:OMNIVOICE_ACTIVE_BACKEND = $selectedBackend
    $device = if ($selectedBackend -in @("cuda", "rocm")) { "cuda:0" }
        elseif ($selectedBackend -eq "xpu") { "xpu:0" }
        else { "cpu" }
    $browserJob = Start-BrowserWatcher
    try {
        & $python -m omnivoice.cli.demo --ip 127.0.0.1 --port 7860 --device $device
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
    Write-Host "Installation or startup failed. Run start.bat again to repair it." -ForegroundColor Red
    Write-Host "Instalacja lub uruchomienie nie powiodlo sie. Uruchom start.bat ponownie, aby naprawic srodowisko." -ForegroundColor Red
    exit 1
}
