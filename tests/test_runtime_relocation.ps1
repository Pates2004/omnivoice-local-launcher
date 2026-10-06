$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $project 'desktop_launcher.ps1'
if (-not (Test-Path -LiteralPath $launcher)) { $launcher = Join-Path $project 'launcher.ps1' }
. $launcher

function Assert-RelocationTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Runtime relocation regression failed: $Message" }
}

& {
    $root = Join-Path $project 'trash\virtual-relocation-runtime'
    $events = New-Object 'System.Collections.Generic.List[string]'
    $needsRepair = $false
    $busy = $false
    function Get-RuntimeRepairFingerprint { return 'helper-v1' }
    function Invoke-EntryPointRepair {
        param($Python, $EnvironmentRoot, [switch]$Apply)
        Assert-RelocationTest ($Python -eq 'managed-python.exe' -and $EnvironmentRoot -eq $root) 'Helper receives the exact managed runtime'
        $events.Add($(if ($Apply) { 'repair' } else { 'check' }))
        return [pscustomobject]@{ needs_repair = $needsRepair; backup_directory = $null }
    }
    function Assert-RuntimeNotInUse {
        $events.Add('busy-check')
        if ($busy) {
            $failure = New-Object InvalidOperationException('SYNTHETIC_BUSY_RUNTIME')
            $failure.Data['OmniSonicRuntimeInUse'] = $true
            throw $failure
        }
    }
    $marker = [pscustomobject]@{ entrypoint_root = $root; entrypoint_fingerprint = 'helper-v1' }
    Assert-RelocationTest (-not (Repair-EnvironmentEntryPoints 'managed-python.exe' $root $marker)) 'Matching stamp skips the scan'
    Assert-RelocationTest ($events.Count -eq 0) 'Unchanged startup launches no helper and needs no exclusive runtime access'
    $marker.entrypoint_root = "$root.new"
    Assert-RelocationTest (Repair-EnvironmentEntryPoints 'managed-python.exe' $root $marker) 'Promotion invalidates the path stamp'
    Assert-RelocationTest (($events -join ',') -eq 'check') 'Correct wrappers need no write or busy check'
    $events.Clear()
    $marker.entrypoint_root = $root
    $marker.entrypoint_fingerprint = 'outdated-helper'
    $needsRepair = $true
    Assert-RelocationTest (Repair-EnvironmentEntryPoints 'managed-python.exe' $root $marker) 'Helper update requires validation'
    Assert-RelocationTest (($events -join ',') -eq 'check,busy-check,repair') 'Repair checks other runtime users before writing'
    $events.Clear()
    $busy = $true
    $blocked = $false
    try { Repair-EnvironmentEntryPoints 'managed-python.exe' $root $null | Out-Null }
    catch { $blocked = Test-RuntimeInUseError $_.Exception }
    Assert-RelocationTest $blocked 'A busy runtime is refused with the identifiable error'
    Assert-RelocationTest (($events -join ',') -eq 'check,busy-check') 'A busy runtime is not rewritten'
}

& {
    $profile = Get-BackendProfile (Get-BackendMatrix) 'cpu'
    $events = New-Object 'System.Collections.Generic.List[string]'
    $probeFails = $false
    function Test-CompatiblePython { return $true }
    function Read-ReadyMarker { return [pscustomobject]@{ revision = 8 } }
    function Test-ReadyMarkerData { return $true }
    function Get-ProjectFingerprint { return 'project' }
    function Get-ProfileFingerprint { return 'profile' }
    function Repair-EnvironmentEntryPoints { $events.Add('repair'); return $true }
    function Invoke-AcceleratorProbe {
        $events.Add('probe')
        if ($probeFails) { throw 'SYNTHETIC_PROBE_FAILURE' }
        return [pscustomobject]@{ torch_version = $profile.torch_version; torchaudio_version = $profile.torchaudio_version }
    }
    function Write-ReadyMarker { $events.Add('marker') }
    function Invoke-QuietRuntimeCheck { throw 'Quick validation must not reimport the application' }
    Assert-RelocationTest (Test-Runtime $launcher 'cpu' $profile 'hardware' $project -Quick) 'Quick validation can repair an older installation'
    Assert-RelocationTest (($events -join ',') -eq 'repair,probe,marker') 'Successful repair is marked only after real accelerator validation'
    $events.Clear()
    $probeFails = $true
    Assert-RelocationTest (-not (Test-Runtime $launcher 'cpu' $profile 'hardware' $project -Quick)) 'Failed validation is not marked ready'
    Assert-RelocationTest (($events -join ',') -eq 'repair,probe') 'No stamp is written after accelerator failure'
}
Write-Host 'Runtime relocation integration tests: OK'
