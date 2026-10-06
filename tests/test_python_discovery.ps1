$ErrorActionPreference = 'Stop'
$testProject = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $testProject 'desktop_launcher.ps1'
if (-not (Test-Path -LiteralPath $launcherPath)) { $launcherPath = Join-Path $testProject 'launcher.ps1' }
. $launcherPath

function Assert-DiscoveryTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Python discovery regression failed: $Message" }
}

$profile = Get-BackendProfile (Get-BackendMatrix) 'cpu'
$realPython = Find-SystemPython $profile
Assert-DiscoveryTest ([bool]$realPython) 'A real compatible interpreter is available for the test'
$scratch = Join-Path $testProject ('trash\python-discovery-' + [Guid]::NewGuid().ToString('N'))
Assert-ProjectChildPath $scratch | Out-Null
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$missingPython = Join-Path $scratch 'missing-python.cmd'
$noisyLauncher = Join-Path $scratch 'noisy-py.cmd'
$unicodeLauncher = Join-Path $scratch 'unicode-py.cmd'
[IO.File]::WriteAllText($missingPython,
    "@echo off`r`necho Nie znaleziono Python; uruchom bez argumentow, aby zainstalowac 1>&2`r`nexit /b 9009`r`n")
[IO.File]::WriteAllText($noisyLauncher, (@(
    '@echo off',
    'if not "%~2"=="-I" exit /b 8',
    'echo Benign launcher warning 1>&2',
    '"%OMNISONIC_DISCOVERY_TEST_PYTHON%" -I -c "import json,sys; print(json.dumps(sys.executable))"',
    'exit /b 0'
) -join "`r`n"))
[IO.File]::WriteAllText($unicodeLauncher, (@(
    '@echo off',
    '"%OMNISONIC_DISCOVERY_TEST_PYTHON%" -I -c "import json,os; print(json.dumps(os.environ[''OMNISONIC_DISCOVERY_TEST_UNICODE'']))"'
) -join "`r`n"))

$priorTestPython = $env:OMNISONIC_DISCOVERY_TEST_PYTHON
$priorUnicodePath = $env:OMNISONIC_DISCOVERY_TEST_UNICODE
$modeVariable = if ((Split-Path -Leaf $launcherPath) -eq 'desktop_launcher.ps1') { 'OMNISONIC_PYTHON_MODE' } else { 'OMNIVOICE_PYTHON_MODE' }
$priorMode = [Environment]::GetEnvironmentVariable($modeVariable)
try {
    $env:OMNISONIC_DISCOVERY_TEST_PYTHON = $realPython
    [Environment]::SetEnvironmentVariable($modeVariable, $null)

    # Reproduce the pre-fix native invocation under Windows PowerShell 5.1.
    # The fixture cannot open the Store or install Python.
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        $oldProbeFailed = $false
        try { & $missingPython -I -c 'import sys' 2>$null | Out-Null }
        catch {
            $oldProbeFailed = $_.Exception.Message -match 'Nie znaleziono Python'
        }
        Assert-DiscoveryTest $oldProbeFailed 'Native stderr reproduces the original terminating error'
    }
    Assert-DiscoveryTest (-not (Test-CompatiblePython $missingPython $profile)) 'Missing-Python alias is incompatible, not fatal'
    Assert-DiscoveryTest ($ErrorActionPreference -eq 'Stop') 'Compatibility probe restores the error policy'

    & {
        $launcherCandidates = @([pscustomobject]@{ Source = $missingPython })
        $pythonCandidates = @([pscustomobject]@{ Source = $missingPython })
        function Get-Command {
            param([string]$Name, [string]$CommandType, [switch]$All, $ErrorAction)
            $items = if ($Name -eq 'py.exe') { $launcherCandidates } else { $pythonCandidates }
            if ($All) { return $items }
            return @($items)[0]
        }
        Assert-DiscoveryTest ($null -eq (Find-SystemPython $profile)) 'Broken py and python aliases yield no interpreter'
        Assert-DiscoveryTest ($ErrorActionPreference -eq 'Stop') 'Discovery restores the error policy'
        function Get-SavedText { return $savedMode }
        function Get-EnvironmentPython { return $missingPython }
        function Select-FirstRunMode {
            param($SystemPython, $Profile)
            Assert-DiscoveryTest ($null -eq $SystemPython) 'First-run prompt gets no bogus interpreter'
            return 'Portable'
        }
        $savedMode = ''
        $selection = Resolve-PythonMode 'Auto' $false $profile
        Assert-DiscoveryTest ($selection.Mode -eq 'Portable') 'No-Python first run can choose Portable'
        $savedMode = 'System'
        $selection = Resolve-PythonMode 'Auto' $false $profile
        Assert-DiscoveryTest ($selection.Mode -eq 'Portable') 'Unavailable remembered System mode falls back to Portable'
        foreach ($explicit in @($true, $false)) {
            $modeOverride = if ($explicit) { $null } else { 'System' }
            [Environment]::SetEnvironmentVariable($modeVariable, $modeOverride)
            $message = ''
            try { Resolve-PythonMode 'System' $explicit $profile | Out-Null }
            catch { $message = $_.Exception.Message }
            Assert-DiscoveryTest ($message -match 'System mode requires a compatible Python') 'Explicit System fails with the launcher explanation'
            Assert-DiscoveryTest ($message -match '\-Mode Portable') 'Explicit System error explains the portable alternative'
        }
        [Environment]::SetEnvironmentVariable($modeVariable, $null)
    }

    & {
        function Get-Command {
            param([string]$Name, [string]$CommandType, [switch]$All, $ErrorAction)
            if ($Name -eq 'py.exe') { return }
            $items = @([pscustomobject]@{ Source = $missingPython }, [pscustomobject]@{ Source = $realPython })
            if ($All -and $CommandType -eq 'Application') { return $items }
            return $items[0]
        }
        Assert-DiscoveryTest ((Find-SystemPython $profile) -eq $realPython) 'Working python behind a broken first PATH alias is found'
    }

    & {
        function Get-Command {
            param([string]$Name, [string]$CommandType, [switch]$All, $ErrorAction)
            if ($Name -eq 'python.exe') { return }
            $items = @([pscustomobject]@{ Source = $missingPython }, [pscustomobject]@{ Source = $noisyLauncher })
            if ($All -and $CommandType -eq 'Application') { return $items }
            return $items[0]
        }
        Assert-DiscoveryTest ((Find-SystemPython $profile) -eq $realPython) 'Later py launcher is probed in isolation and tolerates native warnings'
        Assert-DiscoveryTest ($ErrorActionPreference -eq 'Stop') 'Successful py discovery restores the error policy'
    }

    & {
        $unicodeName = 'python-' + [char]0x017C + [char]0x00F3 + [char]0x0142 + [char]0x0107 + '.exe'
        $unicodePath = Join-Path $scratch $unicodeName
        $env:OMNISONIC_DISCOVERY_TEST_UNICODE = $unicodePath
        function Get-Command {
            param([string]$Name, [string]$CommandType, [switch]$All, $ErrorAction)
            if ($Name -eq 'py.exe') { return [pscustomobject]@{ Source = $unicodeLauncher } }
        }
        function Test-CompatiblePython {
            param([string]$Python, $Profile)
            return $Python -ceq $unicodePath
        }
        Assert-DiscoveryTest ((Find-SystemPython $profile) -ceq $unicodePath) 'ASCII JSON preserves non-ASCII interpreter paths through native pipes'
    }

    & {
        function Get-Command {
            param([string]$Name, [string]$CommandType, [switch]$All, $ErrorAction)
            if ($Name -eq 'py.exe') { return [pscustomobject]@{ Source = (Join-Path $scratch 'vanished-py.exe') } }
            return [pscustomobject]@{ Source = $realPython }
        }
        Assert-DiscoveryTest ((Find-SystemPython $profile) -eq $realPython) 'A vanished py launcher does not hide a valid Python'
        Assert-DiscoveryTest ($ErrorActionPreference -eq 'Stop') 'A throwing py invocation restores the error policy'
    }
}
finally {
    $env:OMNISONIC_DISCOVERY_TEST_PYTHON = $priorTestPython
    $env:OMNISONIC_DISCOVERY_TEST_UNICODE = $priorUnicodePath
    [Environment]::SetEnvironmentVariable($modeVariable, $priorMode)
}
Write-Host 'Python discovery regression tests: OK'
