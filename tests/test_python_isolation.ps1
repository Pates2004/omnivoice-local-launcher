[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$testProject = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $testProject 'desktop_launcher.ps1'
if (-not (Test-Path -LiteralPath $launcherPath)) { $launcherPath = Join-Path $testProject 'launcher.ps1' }
. $launcherPath

function Assert-IsolationTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Python isolation regression failed: $Message" }
}

if (-not $Python) { $Python = Find-SystemPython (Get-BackendProfile (Get-BackendMatrix) 'cpu') }
Assert-IsolationTest (Test-Path -LiteralPath $Python) 'A test interpreter is available'
$scratch = Join-Path $testProject ('trash\python-isolation-' + [Guid]::NewGuid().ToString('N'))
Assert-ProjectChildPath $scratch | Out-Null
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$poisonPath = Join-Path $scratch 'foreign-modules'
[IO.Directory]::CreateDirectory($poisonPath) | Out-Null
[IO.File]::WriteAllText((Join-Path $poisonPath 'foreign_python_poison.py'), 'VALUE = 42')
$childScript = Join-Path $scratch 'child.py'
[IO.File]::WriteAllText($childScript, (@(
    'import importlib.util, os, site',
    "assert importlib.util.find_spec('foreign_python_poison') is None, 'Foreign PYTHONPATH reached child'",
    "assert site.ENABLE_USER_SITE is False, 'Child user site is enabled'",
    "assert os.environ.get('PYTHONNOUSERSITE') == '1', 'Missing inherited user-site isolation'",
    "assert not any(os.environ.get(k) for k in ('PYTHONHOME', 'PYTHONPATH', 'PYTHONUSERBASE', 'PYTHONSTARTUP', 'PYTHONINSPECT', 'PYTHONPLATLIBDIR', 'PYTHONPYCACHEPREFIX')), 'Foreign Python paths reached child'"
) -join "`n"))
$parentScript = Join-Path $scratch 'parent.py'
[IO.File]::WriteAllText($parentScript, (@(
    'import pathlib, subprocess, sys',
    "raise SystemExit(subprocess.call([sys.executable, str(pathlib.Path(__file__).with_name('child.py'))]))"
) -join "`n"))
$pipConfig = Join-Path $scratch 'pip.ini'
$names = @('PYTHONHOME', 'PYTHONPATH', 'PYTHONUSERBASE', 'PYTHONSTARTUP', 'PYTHONINSPECT',
    'PYTHONPLATLIBDIR', 'PYTHONPYCACHEPREFIX', 'PYTHONNOUSERSITE',
    'PIP_CONFIG_FILE', 'PIP_TARGET', 'PIP_PREFIX', 'PIP_ROOT', 'PIP_USER', 'PIP_PYTHON', 'PIP_REQUIRE_VIRTUALENV', 'PIP_REQUIRE_VENV')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    # This test-only child configuration never changes real pip.ini files.
    [IO.File]::WriteAllText($pipConfig, '')
    $env:PIP_CONFIG_FILE = $pipConfig
    $env:PYTHONPATH = $poisonPath
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $beforeOutput = @(& $Python -I $parentScript 2>&1)
        $beforeExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-IsolationTest ($beforeExit -ne 0) 'Plain -I reproduces inherited-child contamination'
    Assert-IsolationTest (($beforeOutput -join ' ') -match 'Foreign PYTHONPATH reached child') 'The failing child imported the synthetic foreign module'

    $env:PYTHONHOME = Join-Path $scratch 'missing-python-home'
    $env:PYTHONUSERBASE = Join-Path $scratch 'foreign-user-site'
    $env:PYTHONSTARTUP = Join-Path $poisonPath 'foreign_python_poison.py'
    $env:PYTHONPLATLIBDIR = 'foreign-lib'
    $env:PYTHONPYCACHEPREFIX = Join-Path $scratch 'unexpected-bytecode'
    Invoke-Checked $Python @($parentScript) 'Checking inherited Python process isolation'
    Assert-IsolationTest ($env:PYTHONHOME -eq (Join-Path $scratch 'missing-python-home')) 'Parent PYTHONHOME restored'
    Assert-IsolationTest ($env:PYTHONPATH -eq $poisonPath) 'Parent PYTHONPATH restored'
    Assert-IsolationTest (-not (Test-Path -LiteralPath $env:PYTHONPYCACHEPREFIX)) 'No external bytecode directory created'
    Invoke-QuietRuntimeCheck $Python @('-E', '-s', $parentScript) 'Checking validation subprocess isolation'
    Assert-IsolationTest (Test-CompatiblePython $Python) 'Compatibility check ignores contaminated Python settings'
    Assert-IsolationTest ((Get-RuntimePythonVersion $Python) -match '^3\.') 'Version check ignores contaminated Python settings'

    $threw = $false
    try { Invoke-WithIsolatedPythonEnvironment { throw 'ISOLATION_TEST_FAILURE' } }
    catch { $threw = $_.Exception.Message -eq 'ISOLATION_TEST_FAILURE' }
    Assert-IsolationTest $threw 'Isolation propagates original invocation failure'
    Assert-IsolationTest ($env:PYTHONPATH -eq $poisonPath) 'Failed invocation restores parent environment'

    # Effective pip option parsing performs no package install or download.
    $env:PIP_TARGET = Join-Path $scratch 'external-packages'
    $parsed = Invoke-WithIsolatedPythonEnvironment {
        & $Python -I -c "from pip._internal.commands import create_command; o,_=create_command('install').parse_args([]); print(bool(o.target_dir))"
    }
    Assert-IsolationTest ($parsed -eq 'True') 'Python -I does not isolate pip destination settings'
    foreach ($variable in @('PIP_TARGET', 'PIP_PREFIX', 'PIP_ROOT', 'PIP_USER')) {
        foreach ($other in @('PIP_TARGET', 'PIP_PREFIX', 'PIP_ROOT', 'PIP_USER')) {
            [Environment]::SetEnvironmentVariable($other, $null, 'Process')
        }
        $value = if ($variable -eq 'PIP_USER') { '1' } else { Join-Path $scratch 'external-packages' }
        [Environment]::SetEnvironmentVariable($variable, $value, 'Process')
        $message = ''
        try { Assert-PipRuntimeSettings $Python 'install' }
        catch { $message = $_.Exception.Message }
        Assert-IsolationTest ($message -match 'External pip settings redirect package installation') "Reject $variable before installation"
        Assert-IsolationTest ([Environment]::GetEnvironmentVariable($variable, 'Process') -eq $value) "Do not change $variable permanently"
    }
    $env:PIP_USER = $null
    [IO.File]::WriteAllText($pipConfig, "[install]`r`ntarget = $scratch\external-packages`r`n")
    $message = ''
    try { Assert-PipRuntimeSettings $Python 'wheel' }
    catch { $message = $_.Exception.Message }
    Assert-IsolationTest ($message -match 'External pip settings redirect package installation') 'Reject pip.ini placement before build dependency installation'
    Assert-IsolationTest (-not (Test-Path -LiteralPath (Join-Path $scratch 'external-packages'))) 'No package was installed outside the environment'

    [IO.File]::WriteAllText($pipConfig, '')
    $env:PIP_PYTHON = Join-Path $scratch 'foreign-python.exe'
    foreach ($command in @('install', 'check', '--version')) {
        $message = ''
        try { Assert-PipRuntimeSettings $Python $command }
        catch { $message = $_.Exception.Message }
        Assert-IsolationTest ($message -match 'different Python interpreter') "Reject interpreter redirection for $command"
        Assert-IsolationTest ($message -notmatch 'foreign-python.exe') 'Do not expose the configured interpreter value'
    }
    $env:PIP_PYTHON = $null
    [IO.File]::WriteAllText($pipConfig, "[global]`r`npython = $scratch\foreign-python.exe`r`n")
    $message = ''
    try { Invoke-QuietRuntimeCheck $Python @('-I', '-m', 'pip', 'check') 'Expected preflight failure' }
    catch { $message = $_.Exception.Message }
    Assert-IsolationTest ($message -match 'different Python interpreter') 'Read-only validation refuses pip.ini interpreter redirection'

    [IO.File]::WriteAllText($pipConfig, "[global]`r`nindex-url = https://example.invalid/simple`r`ncert = test-policy.pem`r`nrequire-virtualenv = true`r`n")
    $isVenv = Invoke-WithIsolatedPythonEnvironment {
        & $Python -I -c 'from pip._internal.utils.virtualenv import running_under_virtualenv; print(running_under_virtualenv())'
    }
    $message = ''
    try { Assert-PipRuntimeSettings $Python 'install' }
    catch { $message = $_.Exception.Message }
    if ($isVenv -eq 'True') {
        Assert-IsolationTest (-not $message) 'A real venv satisfies require-virtualenv policy'
    }
    else {
        Assert-IsolationTest ($message -match 'Pip policy requires a virtual environment' -and $message -match '\-Mode System') 'Standalone Python receives actionable policy refusal'
    }
    $policy = Invoke-WithIsolatedPythonEnvironment {
        & $Python -I -c "from pip._internal.commands import create_command; o,_=create_command('install').parse_args([]); print(bool(o.index_url == 'https://example.invalid/simple' and o.cert == 'test-policy.pem' and o.require_venv))"
    }
    Assert-IsolationTest ($policy -eq 'True') 'Network, TLS and virtualenv requirements remain effective'
    Assert-IsolationTest ($env:PIP_CONFIG_FILE -eq $pipConfig) 'Original pip configuration remains selected'

    [IO.File]::WriteAllText($pipConfig, '')
    $env:PIP_REQUIRE_VIRTUALENV = '1'
    $message = ''
    try { Assert-PipRuntimeSettings $Python 'install' }
    catch {
        Assert-IsolationTest (Test-PipConfigurationError $_.Exception) 'Policy refusal is distinguishable from runtime corruption'
        $message = $_.Exception.Message
    }
    Assert-IsolationTest (($isVenv -eq 'True' -and -not $message) -or ($isVenv -ne 'True' -and $message -match 'requires a virtual environment')) 'Environment policy has the same virtualenv semantics'
    Assert-IsolationTest ($env:PIP_REQUIRE_VIRTUALENV -eq '1') 'Virtualenv policy was not disabled'
    $env:PIP_REQUIRE_VIRTUALENV = $null
    [IO.File]::WriteAllText($pipConfig, 'INVALID_SYNTHETIC_PRIVATE_CONFIG_VALUE')
    $message = ''
    try { Assert-PipRuntimeSettings $Python 'install' }
    catch {
        Assert-IsolationTest (Test-PipConfigurationError $_.Exception) 'Invalid external config is tagged as configuration failure'
        $message = $_.Exception.Message
    }
    Assert-IsolationTest ($message -match 'configuration could not be parsed') 'Malformed pip config has an actionable explanation'
    Assert-IsolationTest ($message -notmatch 'INVALID_SYNTHETIC_PRIVATE_CONFIG_VALUE') 'Malformed configuration values are not exposed'
    [IO.File]::WriteAllText($pipConfig, '')

    $message = ''
    try { Invoke-Checked $Python @('-c', 'raise SystemExit(17)') 'Expected native failure' }
    catch { $message = $_.Exception.Message }
    Assert-IsolationTest ($message -match 'exit code 17') 'Environment restoration preserves native failure status'
    Assert-IsolationTest ($env:PYTHONPATH -eq $poisonPath) 'Native failure restores parent Python settings'

    & {
        function Invoke-IsolationMockPython {
            Assert-IsolationTest (-not $env:PYTHONHOME -and -not $env:PYTHONPATH) 'Application receives clean Python paths'
            Assert-IsolationTest ($env:PYTHONNOUSERSITE -eq '1') 'Application descendants exclude user site'
            $global:LASTEXITCODE = 0
        }
        if (Get-Command Start-DesktopGui -ErrorAction SilentlyContinue) {
            Start-DesktopGui 'Invoke-IsolationMockPython' $false
            function Get-GuiPython { return 'test-pythonw.exe' }
            function Start-Process {
                param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru)
                Assert-IsolationTest (-not $env:PYTHONHOME -and -not $env:PYTHONPATH) 'Hidden application receives clean Python paths'
                Assert-IsolationTest ($env:PYTHONNOUSERSITE -eq '1') 'Hidden descendants exclude user site'
                Assert-IsolationTest ($WindowStyle -eq 'Hidden') 'Background helper starts hidden'
                throw 'EXPECTED_HIDDEN_TEST_EXIT'
            }
            $WorkDir = Join-Path $scratch '.launcher'
            $message = ''
            try { Start-DesktopGui 'Invoke-IsolationMockPython' $true -LogDirectory (Join-Path $scratch 'logs') }
            catch { $message = $_.Exception.Message }
            Assert-IsolationTest ($message -eq 'EXPECTED_HIDDEN_TEST_EXIT') 'Hidden launch reached process creation'
        }
        else { Start-WebInterface 'Invoke-IsolationMockPython' 'cpu' }
        Assert-IsolationTest ($env:PYTHONPATH -eq $poisonPath) 'Application startup restores launcher environment'
    }

    & {
        $profile = Get-BackendProfile (Get-BackendMatrix) 'cpu'
        function Test-CompatiblePython { return $true }
        function Read-ReadyMarker { return [pscustomobject]@{ revision = 8 } }
        function Repair-EnvironmentEntryPoints { return $false }
        function Test-ReadyMarkerData { return $true }
        function Get-ProjectFingerprint { return 'project' }
        function Get-ProfileFingerprint { return 'profile' }
        function Invoke-QuietRuntimeCheck { throw (New-PipConfigurationError 'SYNTHETIC_PIP_POLICY') }
        $blocked = $false
        try { Test-Runtime $launcherPath 'cpu' $profile 'hardware' $scratch | Out-Null }
        catch { $blocked = Test-PipConfigurationError $_.Exception }
        Assert-IsolationTest $blocked 'Validation propagates policy failure instead of requesting runtime repair'
        if (Get-Command Test-RuntimeInUseError -ErrorAction SilentlyContinue) {
            function Invoke-QuietRuntimeCheck {
                $failure = New-Object InvalidOperationException('SYNTHETIC_RUNTIME_IN_USE')
                $failure.Data['OmniSonicRuntimeInUse'] = $true
                throw $failure
            }
            $blocked = $false
            try { Test-Runtime $launcherPath 'cpu' $profile 'hardware' $scratch | Out-Null }
            catch { $blocked = Test-RuntimeInUseError $_.Exception }
            Assert-IsolationTest $blocked 'A busy runtime is not mistaken for corruption requiring repair'
        }
        function Install-RuntimeTransaction { throw (New-PipConfigurationError 'SYNTHETIC_PIP_POLICY') }
        function Read-Host { throw 'Unexpected accelerator fallback prompt' }
        $blocked = $false
        try { Install-WithRecoveryChoice 'Portable' '' 'auto' 'cuda' (Get-BackendMatrix) 'hardware' | Out-Null }
        catch { $blocked = Test-PipConfigurationError $_.Exception }
        Assert-IsolationTest $blocked 'Policy failure never enters GPU retry or CPU fallback'
    }

    foreach ($phase in @('staging', 'activation', 'restore-failure')) {
        & {
            $profile = Get-BackendProfile (Get-BackendMatrix) 'cpu'
            $virtualRoot = Join-Path $scratch 'virtual-runtime'
            $paths = @{ $virtualRoot = 'previous' }
            function Get-EnvironmentRootForMode { return $virtualRoot }
            function Assert-RuntimeNotInUse {}
            function Test-Path { param($LiteralPath); return $paths.ContainsKey($LiteralPath) }
            function Remove-LauncherDirectory { param($Path); $paths.Remove($Path) }
            function New-PythonEnvironmentAt {
                param($SelectedMode, $TargetRoot)
                $paths[$TargetRoot] = 'new'
                return Get-EnvironmentPython $SelectedMode $TargetRoot
            }
            function Install-BackendRuntime {
                if ($phase -eq 'staging') { throw (New-PipConfigurationError 'SYNTHETIC_PIP_POLICY') }
            }
            function Test-Runtime {
                param($Python, $ExpectedBackend, $Profile, $HardwareFingerprint, $EnvironmentRoot)
                if ($EnvironmentRoot -eq "$virtualRoot.new") { return $true }
                throw (New-PipConfigurationError 'SYNTHETIC_PIP_POLICY')
            }
            function Move-Item {
                param($LiteralPath, $Destination)
                if ($phase -eq 'restore-failure' -and $LiteralPath -eq "$virtualRoot.old") { throw 'SYNTHETIC_RESTORE_FAILURE' }
                $paths[$Destination] = $paths[$LiteralPath]
                $paths.Remove($LiteralPath)
            }
            $blocked = $false
            $message = ''
            try { Install-RuntimeTransaction 'Portable' '' 'auto' 'cpu' $profile 'hardware' | Out-Null }
            catch {
                $blocked = Test-PipConfigurationError $_.Exception
                $message = $_.Exception.Message
            }
            Assert-IsolationTest $blocked "Transaction preserves policy classification after $phase"
            if ($phase -eq 'restore-failure') {
                Assert-IsolationTest ($paths["$virtualRoot.old"] -eq 'previous') 'Failed restoration preserves the recoverable previous runtime'
                Assert-IsolationTest ($message -match 'SYNTHETIC_RESTORE_FAILURE') 'Recovery failure remains visible'
            }
            else { Assert-IsolationTest ($paths[$virtualRoot] -eq 'previous') "Previous runtime remains available after $phase policy refusal" }
        }
    }
}
finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
Write-Host 'Python isolation regression tests: OK'
