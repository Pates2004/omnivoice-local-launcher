$ErrorActionPreference = 'Stop'
$testProject = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $testProject 'desktop_launcher.ps1'
if (-not (Test-Path -LiteralPath $launcherPath)) { $launcherPath = Join-Path $testProject 'launcher.ps1' }
. $launcherPath
function Assert-RecoveryTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Recovery regression failed: $Message" }
}
& {
    $scratch = Join-Path $testProject ('trash\native-probe-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $probePath = Join-Path $scratch 'python-probe.cmd'
    [IO.File]::WriteAllText($probePath,
        "@echo off`r`necho Native compatibility diagnostic 1>&2`r`nexit /b %OMNISONIC_TEST_PROBE_EXIT%`r`n")
    $profile = Get-BackendProfile (Get-BackendMatrix) 'cpu'
    $previousProbeExit = $env:OMNISONIC_TEST_PROBE_EXIT
    try {
        $env:OMNISONIC_TEST_PROBE_EXIT = '0'
        Assert-RecoveryTest (Test-CompatiblePython $probePath $profile) 'Native stderr and exit zero remain compatible'
        Assert-RecoveryTest ($ErrorActionPreference -eq 'Stop') 'Error policy restored after warning'
        $env:OMNISONIC_TEST_PROBE_EXIT = '1'
        Assert-RecoveryTest (-not (Test-CompatiblePython $probePath $profile)) 'Native stderr failure returns false'
        Assert-RecoveryTest ($ErrorActionPreference -eq 'Stop') 'Error policy restored after failure'
        function Get-EnvironmentPython { return $probePath }
        function Find-SystemPython { $script:replacementReached = $true; return 'replacement-python.exe' }
        $script:replacementReached = $false
        $selection = Resolve-PythonMode 'System' $true $profile
        Assert-RecoveryTest $script:replacementReached 'Broken Python does not prevent replacement discovery'
        Assert-RecoveryTest ($selection.SystemPython -eq 'replacement-python.exe') 'Replacement Python is selected'
    }
    finally { $env:OMNISONIC_TEST_PROBE_EXIT = $previousProbeExit }
}
foreach ($transaction in @('Runtime', 'Bootstrap')) {
    foreach ($scenario in @('orphan-failure', 'orphan-success', 'first-failure', 'existing-failure', 'restore-failure', 'cleanup-failure')) {
        if ($transaction -eq 'Bootstrap' -and $scenario -eq 'cleanup-failure') { continue }
        & {
            $runtimeRoot = Join-Path $testProject ('trash\virtual-recovery-' + [Guid]::NewGuid().ToString('N'))
            $backupRoot = "$runtimeRoot.old"
            $paths = @{}
            if ($scenario -eq 'existing-failure') {
                $paths[$runtimeRoot] = 'previous'
                $paths[$backupRoot] = 'older'
            } elseif ($scenario -ne 'first-failure') { $paths[$backupRoot] = 'previous' }
            function Get-EnvironmentRootForMode { return $runtimeRoot }
            function Assert-RuntimeNotInUse {}
            function Repair-EnvironmentEntryPoints { return $false }
            function Test-Path { param([string]$LiteralPath); return $paths.ContainsKey($LiteralPath) }
            function Remove-LauncherDirectory {
                param([string]$Path)
                if ($scenario -eq 'cleanup-failure' -and $Path -eq "$runtimeRoot.failed" -and
                    $paths[$runtimeRoot] -eq 'previous') { throw 'Simulated cleanup failure' }
                $paths.Remove($Path)
            }
            function Move-Item {
                param([string]$LiteralPath, [string]$Destination)
                if ($scenario -eq 'restore-failure' -and $LiteralPath -eq $backupRoot) { throw 'Simulated restoration failure' }
                if (-not $paths.ContainsKey($LiteralPath)) { throw "Missing mock source: $LiteralPath" }
                if ($paths.ContainsKey($Destination)) { throw "Mock destination exists: $Destination" }
                $paths[$Destination] = $paths[$LiteralPath]
                $paths.Remove($LiteralPath)
            }
            function New-PythonEnvironmentAt {
                param($SelectedMode, $TargetRoot, $SystemPython, $Profile)
                $paths[$TargetRoot] = 'new'
                return Get-EnvironmentPython $SelectedMode $TargetRoot
            }
            function Install-BackendRuntime {}
            function Test-Runtime {
                param($Python, $ExpectedBackend, $Profile, $HardwareFingerprint, $EnvironmentRoot)
                $script:LastRuntimeError = 'Simulated activated runtime failure'
                return $EnvironmentRoot -eq "$runtimeRoot.new" -or $scenario -eq 'orphan-success'
            }
            function Test-CompatiblePython {
                param([string]$Python, $Profile)
                return $Python.StartsWith($runtimeRoot + '.new' + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $scenario -eq 'orphan-success'
            }
            $errorMessage = $null
            try {
                if ($transaction -eq 'Runtime') {
                    Install-RuntimeTransaction 'Portable' $null 'auto' 'cpu' $null 'hardware' | Out-Null
                } else { Install-PythonBootstrapTransaction 'Portable' $null $null $runtimeRoot | Out-Null }
            } catch { $errorMessage = $_.Exception.Message }
            $label = "$transaction/$scenario"
            switch ($scenario) {
                'orphan-success' {
                    Assert-RecoveryTest (-not $errorMessage) "$label succeeds"
                    Assert-RecoveryTest ($paths[$runtimeRoot] -eq 'new') "$label activates the new runtime"
                    Assert-RecoveryTest ($paths[$backupRoot] -eq 'previous') "$label retains the only old backup"
                }
                'first-failure' {
                    Assert-RecoveryTest ($errorMessage -match 'No previous environment was available') "$label reports no prior runtime"
                    Assert-RecoveryTest (-not $paths.ContainsKey($runtimeRoot)) "$label removes failed active runtime"
                }
                'restore-failure' {
                    Assert-RecoveryTest ($errorMessage -match 'automatic recovery failed') "$label reports failed restoration"
                    Assert-RecoveryTest ($errorMessage -match [Regex]::Escape($backupRoot)) "$label identifies the backup"
                    Assert-RecoveryTest ($errorMessage -match 'Simulated restoration failure') "$label retains original recovery error"
                    Assert-RecoveryTest ($paths[$backupRoot] -eq 'previous') "$label retains recoverable data"
                }
                'cleanup-failure' {
                    Assert-RecoveryTest ($errorMessage -match 'previous environment was restored, but failed-runtime cleanup failed') "$label distinguishes restoration and cleanup"
                    Assert-RecoveryTest ($paths[$runtimeRoot] -eq 'previous') "$label keeps restored runtime"
                    Assert-RecoveryTest ($paths["$runtimeRoot.failed"] -eq 'new') "$label retains failed runtime for cleanup"
                }
                default {
                    Assert-RecoveryTest ($errorMessage -match 'previous environment was restored') "$label confirms restoration"
                    Assert-RecoveryTest ($paths[$runtimeRoot] -eq 'previous') "$label restores previous runtime"
                    Assert-RecoveryTest (-not $paths.ContainsKey($backupRoot)) "$label moves rather than duplicates backup"
                }
            }
        }
    }
}
foreach ($scenario in @('interrupted-download', 'bad-checksum', 'extraction-failure', 'extraction-and-cleanup-failure', 'cleanup-failure', 'success')) {
    & {
        # All mutations are in-memory mocks; no archive/runtime is downloaded.
        $WorkDir = Join-Path $testProject 'trash\virtual-bootstrap-errors'
        $targetRoot = Join-Path $WorkDir 'env.new'
        $archive = Join-Path $WorkDir "python-$PythonVersion-nuget-amd64.zip"
        $state = @{ download = 0; extract = 0; promote = 0; cleanup = 0; pip = 0; unpack = '' }
        function New-Item {}
        function Test-Path {
            param([string]$LiteralPath)
            if ($LiteralPath -eq $targetRoot) { return $false }
            if ($LiteralPath -eq $archive) {
                return $scenario -notin @('interrupted-download', 'bad-checksum')
            }
            return $true
        }
        function Get-FileHash {
            return [pscustomobject]@{ Hash = $(if ($scenario -eq 'bad-checksum') { 'bad' } else { $PythonArchiveSha256 }) }
        }
        function Invoke-WebRequest {
            $state.download++
            if ($scenario -eq 'interrupted-download') { throw 'BOOTSTRAP_DOWNLOAD_INTERRUPTED' }
        }
        function Expand-Archive {
            param($LiteralPath, $DestinationPath)
            $state.extract++
            $state.unpack = $DestinationPath
            if ($scenario -like 'extraction*') { throw 'BOOTSTRAP_EXTRACTION_FAILED' }
        }
        function Move-Item { $state.promote++ }
        function Remove-LauncherDirectory {
            $state.cleanup++
            if ($scenario -like '*cleanup-failure') { throw 'BOOTSTRAP_CLEANUP_FAILED' }
        }
        function Test-CompatiblePython { return $true }
        function Invoke-Checked { $state.pip++ }
        $failure = $null
        $result = @()
        try { $result = @(Install-PortablePythonAt $targetRoot) }
        catch { $failure = $_.Exception.Message }
        switch ($scenario) {
            'interrupted-download' {
                Assert-RecoveryTest ($failure -match 'BOOTSTRAP_DOWNLOAD_INTERRUPTED') 'Interrupted download remains the cause'
                Assert-RecoveryTest ($state.extract -eq 0 -and $state.promote -eq 0) 'Interrupted download is never extracted or promoted'
            }
            'bad-checksum' {
                Assert-RecoveryTest ($failure -match 'checksum mismatch') 'Invalid archive checksum aborts bootstrap'
                Assert-RecoveryTest ($state.extract -eq 0 -and $state.promote -eq 0) 'Invalid archive never reaches extraction'
            }
            'extraction-failure' {
                Assert-RecoveryTest ($failure -match 'BOOTSTRAP_EXTRACTION_FAILED') 'Extraction failure remains the cause'
                Assert-RecoveryTest ($state.cleanup -eq 1 -and $state.promote -eq 0) 'Failed extraction is cleaned but never promoted'
            }
            'extraction-and-cleanup-failure' {
                Assert-RecoveryTest ($failure -match 'BOOTSTRAP_EXTRACTION_FAILED') 'Cleanup failure does not hide the extraction error'
                Assert-RecoveryTest ($failure -match 'BOOTSTRAP_CLEANUP_FAILED') 'Combined error includes cleanup cause'
                Assert-RecoveryTest ($failure -match [Regex]::Escape($state.unpack)) 'Combined error identifies retained extraction files'
            }
            'cleanup-failure' {
                Assert-RecoveryTest ($failure -match 'BOOTSTRAP_CLEANUP_FAILED') 'Cleanup failure is not reported as successful bootstrap'
            }
            'success' {
                Assert-RecoveryTest (-not $failure) 'Bootstrap succeeds after validation'
                Assert-RecoveryTest ($result.Count -eq 1 -and $result[0] -eq (Join-Path $targetRoot 'python.exe')) 'Only the interpreter path reaches the success pipeline'
                Assert-RecoveryTest ($state.download -eq 0 -and $state.promote -eq 1 -and $state.pip -eq 1) 'Validated cached archive is reused and prepared once'
            }
        }
        if ($scenario -ne 'success') { Assert-RecoveryTest ($state.pip -eq 0) 'Failed preparation does not run pip' }
    }
}
Write-Host 'Launcher recovery tests: OK (native stderr, Python replacement, rollback and bootstrap failures)'
