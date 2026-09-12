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

# Empty preference files can be left by an interrupted write. They must behave
# like a missing preference, not call Trim() on PowerShell's null result.
& {
    $scratch = Join-Path $ProjectRoot ('trash\empty-preference-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch | Out-Null
    $emptyFile = Join-Path $scratch 'backend.txt'
    New-Item -ItemType File -Path $emptyFile | Out-Null
    Assert-Test ((Get-SavedText $emptyFile) -eq '') 'Empty backend preference'
    Assert-Test ((Get-SavedText (Join-Path $scratch 'missing.txt')) -eq '') 'Missing preference'
    '  cpu  ' | Set-Content -LiteralPath $emptyFile -Encoding ASCII
    Assert-Test ((Get-SavedText $emptyFile) -eq 'cpu') 'Whitespace is trimmed'
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

# Failed backend repair must not change the saved working Python/backend choice.
& {
    $WorkDir = Join-Path $ProjectRoot ('trash\preference-tests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
    $ModeFile = Join-Path $WorkDir 'mode.txt'
    $BackendFile = Join-Path $WorkDir 'backend.txt'
    'System' | Set-Content -LiteralPath $ModeFile -Encoding ASCII
    'cuda' | Set-Content -LiteralPath $BackendFile -Encoding ASCII
    $BackendWasExplicit = $true
    $Backend = 'CPU'
    $InstallOnly = $true
    function Get-VideoControllers { return @() }
    function Get-ProcessorName { return 'Test CPU' }
    function Show-HardwareSummary {}
    function Get-HideConsolePreference { return $false }
    function Test-HiddenLaunchReady { return $false }
    function Show-LauncherConsole {}
    function Resolve-PythonMode { return [pscustomobject]@{ Mode = 'Portable'; SystemPython = $null } }
    function Test-Runtime { return $false }
    function Install-WithRecoveryChoice { throw 'Simulated failed repair' }
    $failed = $false
    try { Invoke-Main } catch {
        if ($_.Exception.Message -notmatch 'Simulated failed repair') { throw }
        $failed = $true
    }
    Assert-Test $failed 'Failed repair was exercised'
    Assert-Test ((Get-Content -LiteralPath $ModeFile).Trim() -eq 'System') 'Python preference retained on failure'
    Assert-Test ((Get-Content -LiteralPath $BackendFile).Trim() -eq 'cuda') 'Backend preference retained on failure'
    function Install-WithRecoveryChoice {
        return [pscustomobject]@{
            Python = 'test-python'; Backend = 'cpu'; RequestedBackend = 'cpu'
            Profile = (Get-BackendProfile $matrix 'cpu')
        }
    }
    Invoke-Main
    Assert-Test ((Get-Content -LiteralPath $ModeFile).Trim() -eq 'Portable') 'Successful Python choice saved'
    Assert-Test ((Get-Content -LiteralPath $BackendFile).Trim() -eq 'cpu') 'Successful backend choice saved'
}

# stderr warnings must not override the structured probe result in PowerShell 5.1.
& {
    function Invoke-FakeProbePython {
        Write-Error 'Benign device warning'
        $global:LASTEXITCODE = 0
        Write-Output '{"ok":true,"backend":"cpu"}'
    }
    $result = Invoke-AcceleratorProbe 'Invoke-FakeProbePython' 'cpu'
    Assert-Test ($result.ok -and $result.backend -eq 'cpu') 'Warnings do not abort probe parsing'
    Assert-Test ($ErrorActionPreference -eq 'Stop') 'Error policy restored after probe'
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
