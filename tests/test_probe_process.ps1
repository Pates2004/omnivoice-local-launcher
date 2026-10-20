. (Join-Path $PSScriptRoot '..\project_materials.ps1')

$ErrorActionPreference = 'Stop'
$testProject = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $testProject 'desktop_launcher.ps1'
if (-not (Test-Path -LiteralPath $launcherPath)) { $launcherPath = Join-Path $testProject 'launcher.ps1' }
. $launcherPath

function Assert-ProbeTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Owned probe regression failed: $Message" }
}
$ProjectRoot = Join-ProjectMaterialPath $testProject ('trash\owned-probes-' + [Guid]::NewGuid().ToString('N'))
Assert-ProjectTestPath $ProjectRoot $testProject | Out-Null
[IO.Directory]::CreateDirectory($ProjectRoot) | Out-Null
$WorkDir = Join-Path $ProjectRoot '.launcher'
$python = Find-SystemPython (Get-BackendProfile (Get-BackendMatrix) 'cpu')
Assert-ProbeTest ([bool]$python) 'A compatible system Python is available'
$unicode = 'text-' + [char]0x017C + [char]0x00F3 + [char]0x1F63
$arguments = @('', 'C:\folder with spaces\', 'a"b', 'backslash\"quote', "' & ! % ^ (literal)", $unicode)
$result = Invoke-TimedPythonProbe $python (@('-I', '-X', 'utf8', '-c', 'import json,sys; print(json.dumps(sys.argv[1:]))') + $arguments) 'Argument quoting' 10
Assert-ProbeTest ($result.ExitCode -eq 0) 'Quoted command succeeds'
$decoded = $result.Output[0] | ConvertFrom-Json
Assert-ProbeTest ($decoded.Count -eq $arguments.Count) 'Empty and spaced arguments remain distinct'
for ($index = 0; $index -lt $arguments.Count; $index++) {
    Assert-ProbeTest ($decoded[$index] -ceq $arguments[$index]) "Argument $index is byte-for-byte equivalent"
}

$result = Invoke-TimedPythonProbe $python @('-I', '-X', 'utf8', '-c', 'import sys; print(chr(380)); print(chr(243),file=sys.stderr); raise SystemExit(9)') 'Stderr and status' 10
Assert-ProbeTest ($result.ExitCode -eq 9 -and $global:LASTEXITCODE -eq 9) 'Native nonzero status is preserved'
Assert-ProbeTest ($result.Output[0] -ceq ([string][char]380) -and $result.Errors[0] -ceq ([string][char]243)) 'UTF-8 stdout and stderr stay separate'
Assert-ProbeTest ($ErrorActionPreference -eq 'Stop') 'Native stderr does not change caller error policy'
$result = Invoke-TimedPythonProbe $python @('-I', '-X', 'utf8', '-c', 'import sys; print("a"*200000); print("b"*200000,file=sys.stderr)') 'Full streams' 10
Assert-ProbeTest ($result.Output[0].Length -eq 200000 -and $result.Errors[0].Length -eq 200000) 'Both large streams drain without deadlock'

& {
    $ProjectRoot = Join-Path $ProjectRoot ($unicode + " [literal] & '!% ^ (project)")
    [IO.Directory]::CreateDirectory($ProjectRoot) | Out-Null
    $WorkDir = Join-Path $ProjectRoot '.launcher'
    $result = Invoke-TimedPythonProbe $python @('-I', '-X', 'utf8', '-c', 'import json,os; print(json.dumps(os.getcwd()))') 'Literal Unicode project path' 10
    $reportedDirectory = $result.Output[0] | ConvertFrom-Json
    Assert-ProbeTest ($reportedDirectory -ceq $ProjectRoot) 'Native working directory and log paths preserve literal special characters'
}

$failed = $false
try { Invoke-TimedPythonProbe (Join-Path $ProjectRoot 'missing-python.exe') @('-I') 'Missing interpreter' 10 | Out-Null }
catch { $failed = $_.Exception.Message -match 'Could not create the read-only probe' }
Assert-ProbeTest $failed 'Creation failure aborts instead of using an unowned fallback'
$shim = Join-Path $ProjectRoot 'shim.cmd'
[IO.File]::WriteAllText($shim, "@echo off`r`necho SHIM_OK`r`nexit /b 0`r`n")
$result = Invoke-TimedPythonProbe $shim @('-I', '-c', 'a > b & (c)') 'Literal command shim' 10
Assert-ProbeTest ($result.ExitCode -eq 0 -and $result.Output[0] -eq 'SHIM_OK') 'Literal safe CMD shims remain supported'
$failed = $false
try { Invoke-TimedPythonProbe $shim @('" & echo UNSAFE') 'Unsafe command shim' 10 | Out-Null }
catch { $failed = $_.Exception.Message -match 'Unsupported characters' }
Assert-ProbeTest $failed 'Shell-breaking shim arguments are refused before any child starts'

# This child starts its own sleeping child. Both are generated test processes;
# only their private job may be terminated, never Python selected by name.
$pidPath = Join-Path $ProjectRoot 'owned-pids.txt'
$code = 'import os,pathlib,subprocess,sys,time; child=subprocess.Popen([sys.executable,"-I","-c","import time; time.sleep(60)"]); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())+","+str(child.pid)); print("BEFORE_TIMEOUT",flush=True); time.sleep(60)'
$failed = $false
$timer = [Diagnostics.Stopwatch]::StartNew()
try { Invoke-TimedPythonProbe $python @('-I', '-X', 'utf8', '-c', $code, $pidPath) 'Synthetic sleeping tree' 1 | Out-Null }
catch {
    $failed = Test-ProbeTimeoutError $_.Exception
    Assert-ProbeTest ($_.Exception.Message -match 'Synthetic sleeping tree' -and $_.Exception.Message -match '1 seconds' -and $_.Exception.Message -match 'stdout.log') 'Timeout identifies phase, deadline and retained details'
}
Assert-ProbeTest ($failed -and $timer.Elapsed.TotalSeconds -lt 10) 'Sleeping process is bounded'
$ownedIds = @(([IO.File]::ReadAllText($pidPath)) -split ',' | ForEach-Object { [int]$_ })
Assert-ProbeTest ($ownedIds.Count -eq 2) 'Both owned processes started before timeout'
$wait = [Diagnostics.Stopwatch]::StartNew()
do {
    $remaining = @($ownedIds | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 50 }
} while ($remaining.Count -gt 0 -and $wait.Elapsed.TotalSeconds -lt 5)
Assert-ProbeTest ($remaining.Count -eq 0) 'The complete owned tree exited after timeout'
$retained = @(Get-ChildItem -LiteralPath (Join-Path $WorkDir 'probes') -File)
Assert-ProbeTest ($retained.Count -eq 2) 'Only timed-out probe logs remain'
Assert-ProbeTest ((Get-Content -LiteralPath ($retained | Where-Object { $_.Name -like '*.stdout.log' }).FullName -Raw) -match 'BEFORE_TIMEOUT') 'Partial output is preserved after timeout'

# Timeouts are not package corruption: do not start a reinstall or an
# accelerator-fallback prompt because a read-only driver probe stalled.
& {
    function New-TestProbeTimeout {
        $failure = New-Object TimeoutException('SYNTHETIC_READ_ONLY_TIMEOUT')
        $failure.Data['LauncherProbeTimeout'] = $true
        return $failure
    }
    function Test-CompatiblePython { return $true }
    function Read-ReadyMarker { return [pscustomobject]@{ revision = 8 } }
    function Repair-EnvironmentEntryPoints { return $false }
    function Test-ReadyMarkerData { return $true }
    function Get-ProjectFingerprint { return 'project' }
    function Get-ProfileFingerprint { return 'profile' }
    function Invoke-AcceleratorProbe { throw (New-TestProbeTimeout) }
    $failed = $false
    try { Test-Runtime $python 'cpu' (Get-BackendProfile (Get-BackendMatrix) 'cpu') 'hardware' $ProjectRoot -Quick | Out-Null }
    catch { $failed = Test-ProbeTimeoutError $_.Exception }
    Assert-ProbeTest $failed 'Runtime validation propagates timeout without declaring packages broken'
    function Install-RuntimeTransaction { throw (New-TestProbeTimeout) }
    function Read-Host { throw 'Unexpected fallback prompt' }
    $failed = $false
    try { Install-WithRecoveryChoice 'Portable' $null 'auto' 'cuda' (Get-BackendMatrix) 'hardware' | Out-Null }
    catch { $failed = Test-ProbeTimeoutError $_.Exception }
    Assert-ProbeTest $failed 'A timed-out staged probe does not enter accelerator reinstall/fallback'
}

# A hung launcher is skipped once (not retried for all five Python versions),
# allowing a working interpreter later on PATH to be selected.
& {
    $DiscoveryTimeoutSeconds = 1
    $shim = Join-Path $ProjectRoot 'sleeping-py.cmd'
    $escapedPython = '"' + $python + '"'
    [IO.File]::WriteAllText($shim, "@echo off`r`n$escapedPython -I -c ""import time; time.sleep(60)""`r`n")
    $warnings = New-Object 'Collections.Generic.List[string]'
    function Write-WarningMessage { param($Message); $warnings.Add($Message) }
    function Get-Command {
        param($Name, [switch]$All, $CommandType, $ErrorAction)
        return [pscustomobject]@{ Source = $(if ($Name -eq 'py.exe') { $shim } else { $python }) }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $selected = Find-SystemPython (Get-BackendProfile (Get-BackendMatrix) 'cpu')
    Assert-ProbeTest ($selected -eq $python) 'Discovery reaches a healthy later candidate after timeout'
    Assert-ProbeTest ($warnings.Count -eq 1 -and $timer.Elapsed.TotalSeconds -lt 5) 'One warning and one deadline per hung launcher'
}
Write-Host 'Owned read-only probe tests: OK (quoting, UTF-8, streams, failures, deadline and child cleanup)'
