[CmdletBinding()]
param([switch]$Portable)

$ErrorActionPreference = "Stop"
$testProject = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $testProject "desktop_launcher.ps1"
if (-not (Test-Path -LiteralPath $launcherPath)) {
    $launcherPath = Join-Path $testProject "launcher.ps1"
}
. $launcherPath

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Regression failed: $Message" }
}

$matrix = Get-BackendMatrix
$profile = Get-BackendProfile $matrix "rocm"
$apu = @([pscustomobject]@{
    Name = "AMD Radeon(TM) 8060S Graphics"
    PNPDeviceID = "PCI\VEN_1002"
})
$inventory = Get-HardwareInventory $apu "AMD Ryzen AI MAX+ 395" $matrix
Assert-Test ((Get-HardwareBackend $inventory $matrix 26100) -eq "rocm") "Radeon 8060S"
Assert-Test (-not $profile.experimental) "ROCm is supported"
Assert-Test (-not (Test-CompatiblePython "" $profile)) "Missing Python path"
Assert-Test (-not (Test-ReadyMarkerData ([pscustomobject]@{}) "rocm" "h" "p" "v" $profile)) "Malformed marker"

# A working selected interpreter must not enumerate installed system Pythons.
& {
    function Get-SavedText { return "Portable" }
    function Find-SystemPython { throw "Unexpected system Python enumeration" }
    $selection = Resolve-PythonMode "Portable" $true $profile
    Assert-Test ($selection.Mode -eq "Portable") "Portable mode does not enumerate Python"
}
& {
    function Get-SavedText { return "System" }
    function Test-CompatiblePython { return $true }
    function Find-SystemPython { throw "Unexpected system Python enumeration" }
    $selection = Resolve-PythonMode "System" $true $profile
    Assert-Test ($selection.Mode -eq "System") "Existing venv does not enumerate Python"
}

# A valid quick start must only invoke the backend probe, not full imports or pip.
& {
    $profile = Get-BackendProfile $matrix "cpu"
    function Test-CompatiblePython { return $true }
    function Read-ReadyMarker { return [pscustomobject]@{ revision = 8 } }
    function Test-ReadyMarkerData { return $true }
    function Get-ProjectFingerprint { return "project" }
    function Get-ProfileFingerprint { return "profile" }
    $script:probeCalls = 0
    function Invoke-AcceleratorProbe {
        $script:probeCalls++
        return [pscustomobject]@{
            torch_version = $profile.torch_version
            torchaudio_version = $profile.torchaudio_version
        }
    }
    # An existing non-executable file deliberately fails if Python is launched here.
    $ok = Test-Runtime $launcherPath "cpu" $profile "hardware" $ProjectRoot -Quick
    Assert-Test $ok "Quick startup only uses the probe"
    Assert-Test ($script:probeCalls -eq 1) "Exactly one accelerator probe"
    function Invoke-AcceleratorProbe { throw "GPU unavailable" }
    $ok = Test-Runtime $launcherPath "cpu" $profile "hardware" $ProjectRoot -Quick
    Assert-Test (-not $ok) "Failed backend validation rejects quick startup"
    Assert-Test ($script:LastRuntimeError -match "GPU unavailable") "Backend error retained"
}

if ($Portable) {
    # Network integration regression: no GPU or global HIP SDK is needed to
    # build the small ROCm Python package that failed under embedded Python.
    $scratch = Join-Path $ProjectRoot ("trash\portable-regression-" + [Guid]::NewGuid().ToString("N"))
    Assert-ProjectChildPath $scratch | Out-Null
    $WorkDir = Join-Path $scratch ".launcher"
    $pythonRoot = Join-Path $scratch "python.new"
    $python = Install-PortablePythonAt $pythonRoot
    Invoke-Checked $python @("-m", "pip", "install", "--upgrade", "pip") "Updating the test pip"
    $rocmProfile = Get-BackendProfile $matrix "rocm"
    $sourcePackages = @($rocmProfile.prerequisite_packages | Where-Object { $_ -match '\.tar\.gz$' })
    Assert-Test ($sourcePackages.Count -eq 1) "ROCm source distribution is exercised"
    Invoke-Checked $python @(
        "-m", "pip", "wheel", "--no-deps", "--no-cache-dir",
        "--wheel-dir", (Join-Path $scratch "wheels"), $sourcePackages[0]
    ) "Building the ROCm source package in portable Python"
    # Standalone Python must still work after transaction activation/renaming.
    $activeRoot = Join-Path $scratch "python"
    Assert-ProjectChildPath $pythonRoot | Out-Null
    Assert-ProjectChildPath $activeRoot | Out-Null
    Move-Item -LiteralPath $pythonRoot -Destination $activeRoot
    $python = Get-EnvironmentPython "Portable" $activeRoot
    Assert-Test (Test-CompatiblePython $python $rocmProfile) "Renamed portable Python"
    Invoke-Checked $python @("-m", "pip", "--version") "Validating pip after activation"
}
Write-Host "Launcher regression tests: OK"
