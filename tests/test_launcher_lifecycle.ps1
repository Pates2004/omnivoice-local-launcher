. (Join-Path $PSScriptRoot '..\project_materials.ps1')

$ErrorActionPreference = 'Stop'
$testProject = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $testProject 'desktop_launcher.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { $launcher = Join-Path $testProject 'launcher.ps1' }
. $launcher

function Assert-ProjectChildPath {
    param([string]$Path)
    return Assert-ProjectTestPath $Path $testProject
}
function Assert-Lifecycle {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Launcher lifecycle regression: $Message" }
}
function New-LifecycleTimeout {
    $failure = New-Object TimeoutException('ORIGINAL_MANAGED_PYTHON_TIMEOUT')
    $failure.Data['LauncherProbeTimeout'] = $true
    return $failure
}
$failures = New-Object 'Collections.Generic.List[string]'

foreach ($scenario in @('runtime', 'mode')) {
    try {
        & {
            function Invoke-TimedPythonProbe { throw (New-LifecycleTimeout) }
            function Write-WarningMessage {}
            function Get-SavedText { return 'System' }
            function Get-EnvironmentPython { return $launcher }
            function Find-SystemPython { throw 'UNEXPECTED_DISCOVERY_AFTER_MANAGED_TIMEOUT' }
            $profile = Get-BackendProfile (Get-BackendMatrix) 'cpu'
            $caught = $false
            try {
                if ($scenario -eq 'runtime') {
                    Test-Runtime $launcher 'cpu' $profile 'hardware' $ProjectRoot -Quick | Out-Null
                } else { Resolve-PythonMode 'System' $true $profile | Out-Null }
            }
            catch { $caught = Test-ProbeTimeoutError $_.Exception }
            Assert-Lifecycle $caught "$scenario keeps the existing environment timeout, not incompatible-Python repair/mode change"
        }
    } catch { $failures.Add($_.Exception.Message) }
}

foreach ($transaction in @('Runtime', 'Bootstrap')) {
    foreach ($scenario in @('existing', 'existing-older', 'orphan', 'first', 'busy-rollback', 'staging-timeout')) {
        try {
            & {
                $runtimeRoot = Join-ProjectMaterialPath $testProject ('trash\virtual-timeout-lifecycle-' + [Guid]::NewGuid().ToString('N'))
                $stagingRoot = "$runtimeRoot.new"
                $backupRoot = "$runtimeRoot.old"
                $paths = @{}
                if ($scenario -in @('existing', 'existing-older', 'busy-rollback', 'staging-timeout')) { $paths[$runtimeRoot] = 'previous' }
                if ($scenario -eq 'orphan') { $paths[$backupRoot] = 'previous' }
                if ($scenario -in @('existing-older', 'staging-timeout')) { $paths[$backupRoot] = 'older-working' }
                $state = @{ checks = 0; removals = 0 }
                function Get-EnvironmentRootForMode { return $runtimeRoot }
                function Test-Path { param($LiteralPath); return $paths.ContainsKey($LiteralPath) }
                function Assert-RuntimeNotInUse {
                    $state.checks++
                    if ($scenario -eq 'busy-rollback' -and $state.checks -eq 3) {
                        $failure = New-Object InvalidOperationException('NEW_EXTERNAL_USER_BLOCKS_ROLLBACK')
                        $failure.Data['OmniSonicRuntimeInUse'] = $true
                        throw $failure
                    }
                }
                function Remove-LauncherDirectory {
                    param($Path)
                    $state.removals++
                    $paths.Remove($Path)
                }
                function Move-Item {
                    param($LiteralPath, $Destination)
                    if (-not $paths.ContainsKey($LiteralPath) -or $paths.ContainsKey($Destination)) { throw 'Invalid mock move' }
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
                    if ($EnvironmentRoot -eq $stagingRoot -and $scenario -ne 'staging-timeout') { return $true }
                    throw (New-LifecycleTimeout)
                }
                function Test-CompatiblePython {
                    param($Python, $Profile, [switch]$ThrowOnTimeout)
                    if ($Python -eq (Get-EnvironmentPython 'Portable' $stagingRoot) -and $scenario -ne 'staging-timeout') { return $true }
                    throw (New-LifecycleTimeout)
                }
                function Repair-EnvironmentEntryPoints { throw 'Must not repair after compatibility timeout' }
                $caught = $null
                try {
                    if ($transaction -eq 'Runtime') {
                        Install-RuntimeTransaction 'Portable' $null 'auto' 'cpu' $null 'hardware' | Out-Null
                    } else { Install-PythonBootstrapTransaction 'Portable' $null $null $runtimeRoot | Out-Null }
                } catch { $caught = $_.Exception }
                Assert-Lifecycle ($null -ne $caught -and (Test-ProbeTimeoutError $caught)) "$transaction/$scenario preserves the timeout identity"
                Assert-Lifecycle ($caught.Message -match 'ORIGINAL_MANAGED_PYTHON_TIMEOUT') "$transaction/$scenario keeps original timeout diagnostics"
                if ($scenario -eq 'staging-timeout') {
                    Assert-Lifecycle ($paths[$runtimeRoot] -eq 'previous' -and $paths[$backupRoot] -eq 'older-working') "$transaction staging timeout leaves both existing environments unchanged"
                    Assert-Lifecycle ($state.checks -eq 1 -and $paths[$stagingRoot] -eq 'new') "$transaction staging timeout aborts before promotion"
                } elseif ($scenario -eq 'busy-rollback') {
                    Assert-Lifecycle ($paths[$runtimeRoot] -eq 'new' -and $paths[$backupRoot] -eq 'previous') "$transaction blocked rollback retains both environments"
                    Assert-Lifecycle ($caught.Message -match 'NEW_EXTERNAL_USER_BLOCKS_ROLLBACK' -and $caught.Message -match [Regex]::Escape($backupRoot)) "$transaction blocked rollback reports both the obstacle and recovery path"
                } elseif ($scenario -eq 'first') {
                    Assert-Lifecycle (-not $paths.ContainsKey($runtimeRoot) -and -not $paths.ContainsKey($backupRoot)) "$transaction first-install timeout does not invent a previous environment"
                    Assert-Lifecycle ($caught.Message -match 'No previous environment') "$transaction first-install diagnostic is truthful"
                } else {
                    $backupRestored = if ($scenario -eq 'existing-older') { $paths[$backupRoot] -eq 'older-working' } else { -not $paths.ContainsKey($backupRoot) }
                    Assert-Lifecycle ($paths[$runtimeRoot] -eq 'previous' -and $backupRestored) "$transaction/$scenario restores previous active environment and its original backup"
                    Assert-Lifecycle ($caught.Message -match 'previous environment was restored') "$transaction/$scenario confirms actual restoration"
                }
                if ($scenario -ne 'staging-timeout') {
                    Assert-Lifecycle ($state.checks -ge 3) "$transaction/$scenario checks external users again before rollback"
                }
            }
        } catch { $failures.Add($_.Exception.Message) }
    }
}

foreach ($transaction in @('Runtime', 'Bootstrap')) {
    foreach ($scenario in @('success', 'cleanup-failure', 'retained-in-use', 'reserve-move-failure', 'active-move-failure', 'active-move-and-restore-failure', 'active-move-and-restore-in-use', 'activation-and-restore-failure', 'rollback-in-use')) {
        try {
            & {
                $runtimeRoot = Join-ProjectMaterialPath $testProject ('trash\virtual-backup-lifecycle-' + [Guid]::NewGuid().ToString('N'))
                $stagingRoot = "$runtimeRoot.new"
                $backupRoot = "$runtimeRoot.old"
                $paths = @{ $runtimeRoot = 'previous'; $backupRoot = 'older-working' }
                $state = @{ retained = ''; warnings = @(); activationChecks = 0; guardedRetained = $false; activeMoveFailed = $false }
                function Get-EnvironmentRootForMode { return $runtimeRoot }
                function Test-Path { param($LiteralPath); return $paths.ContainsKey($LiteralPath) }
                function Assert-RuntimeNotInUse {
                    param([string[]]$EnvironmentRoots)
                    if (@($EnvironmentRoots | Where-Object { $_ -like '*.retained-*' }).Count -gt 0) { $state.guardedRetained = $true }
                    if (($scenario -eq 'retained-in-use' -and $EnvironmentRoots.Count -eq 1 -and $EnvironmentRoots[0] -like '*.retained-*') -or
                        ($scenario -eq 'rollback-in-use' -and $state.activationChecks -gt 0) -or
                        ($scenario -eq 'active-move-and-restore-in-use' -and $state.activeMoveFailed)) {
                        $failure = New-Object InvalidOperationException('NEW_EXTERNAL_USER_BLOCKS_RECOVERY')
                        $failure.Data['OmniSonicRuntimeInUse'] = $true
                        throw $failure
                    }
                }
                function Write-WarningMessage { param($Message); $state.warnings += $Message }
                function Remove-LauncherDirectory {
                    param($Path)
                    if ($scenario -eq 'cleanup-failure' -and $Path -like '*.retained-*') { throw 'OBSOLETE_BACKUP_CLEANUP_FAILED' }
                    $paths.Remove($Path)
                }
                function Move-Item {
                    param($LiteralPath, $Destination)
                    if ($Destination -like '*.retained-*') {
                        $state.retained = $Destination
                        if ($scenario -eq 'reserve-move-failure') { throw 'ORIGINAL_RESERVE_MOVE_FAILED' }
                    }
                    if ($LiteralPath -eq $runtimeRoot -and $Destination -eq $backupRoot -and $scenario -like 'active-move-*') {
                        $state.activeMoveFailed = $true
                        throw 'ORIGINAL_ACTIVE_MOVE_FAILED'
                    }
                    if ($LiteralPath -like '*.retained-*' -and $Destination -eq $backupRoot -and $scenario -in @('active-move-and-restore-failure', 'activation-and-restore-failure')) { throw 'ORIGINAL_BACKUP_RESTORE_FAILED' }
                    if (-not $paths.ContainsKey($LiteralPath) -or $paths.ContainsKey($Destination)) { throw 'Invalid mock backup move' }
                    $paths[$Destination] = $paths[$LiteralPath]
                    $paths.Remove($LiteralPath)
                }
                function New-PythonEnvironmentAt {
                    param($SelectedMode, $TargetRoot, $SystemPython, $Profile)
                    $paths[$TargetRoot] = 'new'
                    return Get-EnvironmentPython $SelectedMode $TargetRoot
                }
                function Install-BackendRuntime {}
                function Repair-EnvironmentEntryPoints { return $false }
                function Assert-ActivatedFixture {
                    $state.activationChecks++
                    if ($scenario -in @('activation-and-restore-failure', 'rollback-in-use')) { throw 'ORIGINAL_ACTIVATION_CHECK_FAILED' }
                    return $true
                }
                function Test-Runtime {
                    param($Python, $ExpectedBackend, $Profile, $HardwareFingerprint, $EnvironmentRoot)
                    if ($EnvironmentRoot -eq $stagingRoot) { return $true }
                    return Assert-ActivatedFixture
                }
                function Test-CompatiblePython {
                    param($Python, $Profile, [switch]$ThrowOnTimeout)
                    if ($Python -eq (Get-EnvironmentPython 'Portable' $stagingRoot)) { return $true }
                    return Assert-ActivatedFixture
                }
                $caught = $null
                $result = $null
                try {
                    if ($transaction -eq 'Runtime') {
                        $result = Install-RuntimeTransaction 'Portable' $null 'auto' 'cpu' $null 'hardware'
                    } else { $result = Install-PythonBootstrapTransaction 'Portable' $null $null $runtimeRoot }
                } catch { $caught = $_.Exception }
                $label = "$transaction/$scenario"
                if ($scenario -in @('success', 'cleanup-failure', 'retained-in-use')) {
                    Assert-Lifecycle ($null -eq $caught -and $result -eq (Get-EnvironmentPython 'Portable' $runtimeRoot)) "$label returns the validated active interpreter"
                    Assert-Lifecycle ($paths[$runtimeRoot] -eq 'new' -and $paths[$backupRoot] -eq 'previous') "$label keeps the newly validated runtime and immediate rollback reserve"
                    if ($scenario -eq 'success') {
                        Assert-Lifecycle (-not $paths.ContainsKey($state.retained) -and $state.warnings.Count -eq 0) "$label removes only now-obsolete older reserve"
                    } else {
                        Assert-Lifecycle ($paths[$state.retained] -eq 'older-working' -and $state.warnings.Count -eq 1 -and $state.warnings[0] -match [Regex]::Escape($state.retained)) "$label warns and retains exact older backup without failing working runtime"
                    }
                } elseif ($scenario -eq 'reserve-move-failure') {
                    Assert-Lifecycle ($caught.Message -match 'ORIGINAL_RESERVE_MOVE_FAILED' -and $paths[$runtimeRoot] -eq 'previous' -and $paths[$backupRoot] -eq 'older-working') "$label fails before touching active or older backup"
                } elseif ($scenario -eq 'active-move-failure') {
                    Assert-Lifecycle ($caught.Message -match 'ORIGINAL_ACTIVE_MOVE_FAILED' -and $paths[$runtimeRoot] -eq 'previous' -and $paths[$backupRoot] -eq 'older-working') "$label restores original backup after failed active move"
                } else {
                    $originalCause = if ($scenario -in @('active-move-and-restore-failure', 'active-move-and-restore-in-use')) { 'ORIGINAL_ACTIVE_MOVE_FAILED' } else { 'ORIGINAL_ACTIVATION_CHECK_FAILED' }
                    Assert-Lifecycle ($caught.Message -match $originalCause -and $caught.Message -match [Regex]::Escape($state.retained)) "$label includes original failure and exact retained backup path"
                    Assert-Lifecycle ($paths[$state.retained] -eq 'older-working') "$label preserves the older usable backup"
                    if ($scenario -eq 'active-move-and-restore-in-use') {
                        Assert-Lifecycle ((Test-RuntimeInUseError $caught) -and $caught.Message -match 'NEW_EXTERNAL_USER_BLOCKS_RECOVERY' -and $paths[$runtimeRoot] -eq 'previous') "$label preserves busy identity before activation and avoids backend fallback"
                    } elseif ($scenario -eq 'rollback-in-use') {
                        Assert-Lifecycle ((Test-RuntimeInUseError $caught) -and $paths[$runtimeRoot] -eq 'new' -and $paths[$backupRoot] -eq 'previous') "$label does not mutate environments used by another process"
                    } else {
                        Assert-Lifecycle ($caught.Message -match 'ORIGINAL_BACKUP_RESTORE_FAILED' -and $paths[$runtimeRoot] -eq 'previous') "$label keeps restored active and both error causes"
                    }
                }
                Assert-Lifecycle $state.guardedRetained "$label checks renamed-backup runtime users"
            }
        } catch { $failures.Add($_.Exception.Message) }
    }
}

try {
    & {
        # A real same-volume move/restore with generated sentinel files verifies
        # the filesystem path, not merely the in-memory transaction model.
        $ProjectRoot = Join-ProjectMaterialPath $testProject ('trash\backup-move-lifecycle-' + [Guid]::NewGuid().ToString('N'))
        Assert-ProjectTestPath $ProjectRoot $testProject | Out-Null
        $active = Join-Path $ProjectRoot 'env'
        $backup = "$active.old"
        [IO.Directory]::CreateDirectory($active) | Out-Null
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        [IO.File]::WriteAllText((Join-Path $active 'identity.txt'), 'PREVIOUS_ACTIVE_SENTINEL')
        [IO.File]::WriteAllText((Join-Path $backup 'identity.txt'), 'OLDER_WORKING_SENTINEL')
        $reserved = Move-ActiveRuntimeToBackup $active $backup
        Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $backup 'identity.txt')) -ceq 'PREVIOUS_ACTIVE_SENTINEL') 'Real active move keeps its original bytes'
        Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $reserved 'identity.txt')) -ceq 'OLDER_WORKING_SENTINEL') 'Real reserve move keeps older backup bytes'
        Move-Item -LiteralPath $backup -Destination $active
        Restore-ReservedRuntimeBackup $backup $reserved
        Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $active 'identity.txt')) -ceq 'PREVIOUS_ACTIVE_SENTINEL') 'Real rollback restores active path'
        Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $backup 'identity.txt')) -ceq 'OLDER_WORKING_SENTINEL') 'Real rollback restores original old path'
        $reserved = Move-ActiveRuntimeToBackup $active $backup
        [IO.Directory]::CreateDirectory($active) | Out-Null
        [IO.File]::WriteAllText((Join-Path $active 'identity.txt'), 'NEW_VALIDATED_SENTINEL')
        Complete-ReservedRuntimeBackup $reserved
        Assert-Lifecycle (-not (Test-Path -LiteralPath $reserved)) 'Real successful completion removes only obsolete generated reserve'
        Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $active 'identity.txt')) -ceq 'NEW_VALIDATED_SENTINEL') 'New active sentinel remains after cleanup'
        Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $backup 'identity.txt')) -ceq 'PREVIOUS_ACTIVE_SENTINEL') 'Immediate rollback sentinel remains after cleanup'
    }
} catch { $failures.Add($_.Exception.Message) }

if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
Write-Host 'Launcher lifecycle tests: OK (managed timeout, mode, activation rollback and external-use guard)'
