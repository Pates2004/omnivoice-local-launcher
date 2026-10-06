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
    function Repair-EnvironmentEntryPoints { return $false }
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

& {
    $scratch = Join-Path $ProjectRoot ('trash\full-runtime-check-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $probePath = Join-Path $scratch 'runtime-check.cmd'
    [IO.File]::WriteAllText($probePath, (@(
        '@echo off',
        'if "%~1"=="-E" goto imports',
        'echo PIP_CHECK_DETAIL 1>&2',
        'exit /b %OMNISONIC_TEST_PIP_EXIT%',
        ':imports',
        'echo IMPORT_CHECK_DETAIL 1>&2',
        'exit /b %OMNISONIC_TEST_IMPORT_EXIT%'
    ) -join "`r`n"))
    $profile = Get-BackendProfile $matrix 'cpu'
    function Test-CompatiblePython { return $true }
    function Read-ReadyMarker { return [pscustomobject]@{ revision = 8 } }
    function Assert-PipRuntimeSettings {
        param($Python, $Command)
        Assert-Test ($Python -eq $probePath -and $Command -eq 'check') 'Full validation checks pip interpreter settings'
    }
    function Repair-EnvironmentEntryPoints { return $false }
    function Test-ReadyMarkerData { return $true }
    function Get-ProjectFingerprint { return 'project' }
    function Get-ProfileFingerprint { return 'profile' }
    function Invoke-AcceleratorProbe {
        return [pscustomobject]@{
            torch_version = $profile.torch_version
            torchaudio_version = $profile.torchaudio_version
        }
    }
    $previousImportExit = $env:OMNISONIC_TEST_IMPORT_EXIT
    $previousPipExit = $env:OMNISONIC_TEST_PIP_EXIT
    try {
        $env:OMNISONIC_TEST_IMPORT_EXIT = '0'
        $env:OMNISONIC_TEST_PIP_EXIT = '0'
        Assert-Test (Test-Runtime $probePath 'cpu' $profile 'hardware' $scratch) 'Full validation accepts native stderr with successful exit codes'
        Assert-Test ($ErrorActionPreference -eq 'Stop') 'Full validation restores error policy after warnings'
        $env:OMNISONIC_TEST_IMPORT_EXIT = '5'
        Assert-Test (-not (Test-Runtime $probePath 'cpu' $profile 'hardware' $scratch)) 'Full validation rejects failed imports'
        Assert-Test ($script:LastRuntimeError -match 'IMPORT_CHECK_DETAIL' -and $script:LastRuntimeError -match 'exit code 5') 'Import failure retains stderr and native status'
        Assert-Test ($ErrorActionPreference -eq 'Stop') 'Import failure restores error policy'
        $env:OMNISONIC_TEST_IMPORT_EXIT = '0'
        $env:OMNISONIC_TEST_PIP_EXIT = '7'
        Assert-Test (-not (Test-Runtime $probePath 'cpu' $profile 'hardware' $scratch)) 'Full validation rejects failed dependency checks'
        Assert-Test ($script:LastRuntimeError -match 'PIP_CHECK_DETAIL' -and $script:LastRuntimeError -match 'exit code 7') 'Dependency failure retains stderr and native status'
        Assert-Test ($ErrorActionPreference -eq 'Stop') 'Dependency failure restores error policy'
        function Invoke-UnlaunchablePython { throw 'Simulated interpreter invocation failure' }
        $failed = $false
        try { Invoke-QuietRuntimeCheck 'Invoke-UnlaunchablePython' @('-I') 'Interpreter check failed' }
        catch {
            Assert-Test ($_.Exception.Message -match 'Simulated interpreter invocation failure') 'Invocation exceptions retain their cause'
            $failed = $true
        }
        Assert-Test $failed 'An unlaunchable interpreter is not accepted'
        Assert-Test ($ErrorActionPreference -eq 'Stop') 'Invocation exceptions restore error policy'
    }
    finally {
        $env:OMNISONIC_TEST_IMPORT_EXIT = $previousImportExit
        $env:OMNISONIC_TEST_PIP_EXIT = $previousPipExit
    }
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

& {
    function Invoke-VersionPython {
        Assert-Test ($args[0] -eq '-I') 'Marker version probe uses isolated Python'
        $global:LASTEXITCODE = $versionExitCode
        if ($null -ne $versionText) { Write-Output $versionText }
    }
    $versionExitCode = 0
    $versionText = ' 3.12.10 '
    Assert-Test ((Get-RuntimePythonVersion 'Invoke-VersionPython') -eq '3.12.10') 'Marker version is trimmed'
    foreach ($scenario in @('exit', 'empty')) {
        $versionExitCode = if ($scenario -eq 'exit') { 7 } else { 0 }
        $versionText = if ($scenario -eq 'exit') { '3.12.10' } else { $null }
        $failed = $false
        try { Get-RuntimePythonVersion 'Invoke-VersionPython' | Out-Null }
        catch {
            Assert-Test ($_.Exception.Message -match 'Could not determine the runtime Python version') 'Marker rejects an invalid version probe'
            $failed = $true
        }
        Assert-Test $failed "Marker rejected $scenario"
    }
    $runtimePython = Find-SystemPython (Get-BackendProfile $matrix 'cpu')
    Assert-Test ([bool]$runtimePython) 'System Python is available for the isolated version test'
    $previousPythonHome = $env:PYTHONHOME
    try {
        $env:PYTHONHOME = Join-Path $ProjectRoot 'missing-python-home-regression'
        Assert-Test ((Get-RuntimePythonVersion $runtimePython) -match '^3\.[0-9]+\.[0-9]+') 'Marker ignores an unrelated PYTHONHOME'
    }
    finally { $env:PYTHONHOME = $previousPythonHome }
}

& {
    $WorkDir = Join-Path $ProjectRoot ('trash\launcher-lock-' + [Guid]::NewGuid().ToString('N'))
    $heldLock = Enter-LauncherLock
    function Invoke-LauncherSession { throw 'The busy launcher must not enter the session' }
    try {
        $failed = $false
        try { Invoke-Main }
        catch {
            Assert-Test ($_.Exception.Message -match 'Another .* launcher') 'A concurrent start reports the held project lock'
            $failed = $true
        }
        Assert-Test $failed 'A concurrent start cannot enter validation or repair'
    }
    finally { $heldLock.Dispose() }
    Assert-Test (Test-Path -LiteralPath (Join-Path $WorkDir 'runtime.lock')) 'Lock file remains after release'
    function Invoke-LauncherSession {
        $failed = $false
        try {
            $unexpectedLock = Enter-LauncherLock
            $unexpectedLock.Dispose()
        }
        catch {
            Assert-Test ($_.Exception.Message -match 'Another .* launcher') 'The session keeps the project lock'
            $failed = $true
        }
        Assert-Test $failed 'The lock covers the complete launcher session'
        throw 'Simulated session failure'
    }
    $failed = $false
    try { Invoke-Main }
    catch {
        Assert-Test ($_.Exception.Message -match 'Simulated session failure') 'A released lock file does not block the next start'
        $failed = $true
    }
    Assert-Test $failed 'Session failure was exercised'
    $recoveredLock = Enter-LauncherLock
    $recoveredLock.Dispose()
}

& {
    $previousNoBrowser = $env:OMNIVOICE_NO_BROWSER
    function Invoke-DemoPython {
        Assert-Test (($args[0..3] -join ' ') -eq '-E -s -m omnivoice.cli.demo') 'Web startup keeps the isolated application command'
        Assert-Test (($args[4..9] -join ' ') -eq '--ip 127.0.0.1 --port 7860 --device xpu:0') 'Web startup forwards the selected device and local server address'
        Assert-Test (($args -contains '--open-browser') -eq $expectedBrowser) 'Web startup forwards the browser preference'
        $global:LASTEXITCODE = $demoExitCode
    }
    $demoExitCode = 0
    try {
        foreach ($scenario in @(
            @{ Disabled = $false; Environment = $null; Expected = $true },
            @{ Disabled = $true; Environment = $null; Expected = $false },
            @{ Disabled = $false; Environment = '1'; Expected = $false },
            @{ Disabled = $true; Environment = '1'; Expected = $false },
            @{ Disabled = $false; Environment = '0'; Expected = $true }
        )) {
            $NoBrowser = $scenario.Disabled
            $env:OMNIVOICE_NO_BROWSER = $scenario.Environment
            $expectedBrowser = $scenario.Expected
            Start-WebInterface 'Invoke-DemoPython' 'xpu:0'
        }
        $demoExitCode = 9
        $failed = $false
        try { Start-WebInterface 'Invoke-DemoPython' 'xpu:0' }
        catch {
            Assert-Test ($_.Exception.Message -match 'web interface exited with code 9') 'Web startup still reports process failure'
            $failed = $true
        }
        Assert-Test $failed 'Failed web startup is not accepted'
    }
    finally { $env:OMNIVOICE_NO_BROWSER = $previousNoBrowser }
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
    Repair-EnvironmentEntryPoints $python $activeRoot $null | Out-Null
    $pipEntryPoint = Join-Path $activeRoot 'Scripts\pip.exe'
    $pipOutput = Invoke-WithIsolatedPythonEnvironment { & $pipEntryPoint --version }
    Assert-Test ($LASTEXITCODE -eq 0 -and ($pipOutput -join ' ') -match [Regex]::Escape($activeRoot)) 'Generated pip.exe works after activation'
    Invoke-Checked $python @("-m", "pip", "--version") "Validating pip after activation"
    Invoke-Checked $python @('-B', (Join-Path $PSScriptRoot 'smoke_runtime_relocation.py'), '--root', $activeRoot) 'Testing generated entry points and metadata after relocation'
}
& (Join-Path $PSScriptRoot 'test_launcher_recovery.ps1')
& (Join-Path $PSScriptRoot 'test_python_discovery.ps1')
if ($Portable) { & (Join-Path $PSScriptRoot 'test_python_isolation.ps1') -Python $python }
else { & (Join-Path $PSScriptRoot 'test_python_isolation.ps1') }
& (Join-Path $PSScriptRoot 'test_runtime_in_use.ps1')
& (Join-Path $PSScriptRoot 'test_runtime_relocation.ps1')
Write-Host "Launcher regression tests: OK"
