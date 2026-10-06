$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'launcher.ps1')

function Assert-UsageTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Runtime usage regression failed: $Message" }
}
function New-BusyTestError {
    $failure = New-Object InvalidOperationException('Close the application / Zamknij aplikacje')
    $failure.Data['OmniSonicRuntimeInUse'] = $true
    return $failure
}
function Assert-Busy {
    param([scriptblock]$Body)
    try { & $Body | Out-Null }
    catch {
        Assert-UsageTest (Test-RuntimeInUseError $_.Exception) 'Busy status remains identifiable'
        Assert-UsageTest ($_.Exception.Message -match 'Zamknij') 'Busy message includes Polish guidance'
        return
    }
    throw 'Expected an in-use runtime to be rejected.'
}
$runtimeRoot = Join-Path $ProjectRoot 'trash\virtual-usage-runtime'
& {
    function Get-CimInstance { return $processes }
    $roots = @($runtimeRoot, "$runtimeRoot.old", "$runtimeRoot.new", "$runtimeRoot.failed")
    foreach ($root in $roots) {
        $executable = Join-Path $root 'pythonw.exe'
        $processes = @([pscustomobject]@{
            ProcessId = 12345; ExecutablePath = $executable
            CommandLine = ('"' + $executable + '" -E -s -m omnivoice.cli.demo')
        })
        Assert-Busy { Assert-RuntimeNotInUse $roots }
    }
    $venvExecutable = Join-Path $runtimeRoot 'Scripts\pythonw.exe'
    $processes = @([pscustomobject]@{
        ProcessId = 12345; ExecutablePath = 'C:\BasePython\pythonw.exe'
        CommandLine = ('"' + $venvExecutable + '" -E -s -m omnivoice.cli.demo')
    })
    Assert-Busy { Assert-RuntimeNotInUse @($runtimeRoot) }
    $processes = @(
        [pscustomobject]@{
            ProcessId = 12346; ExecutablePath = 'C:\OtherPython\python.exe'
            CommandLine = ('C:\OtherPython\python.exe -c "print(' + $venvExecutable + ')"')
        },
        [pscustomobject]@{
            ProcessId = 12347; ExecutablePath = (Join-Path "$runtimeRoot-other" 'python.exe')
            CommandLine = $null
        }
    )
    Assert-RuntimeNotInUse $roots
}
foreach ($transaction in @('Runtime', 'Bootstrap')) {
    & {
        function Get-EnvironmentRootForMode { return $runtimeRoot }
        function Get-CimInstance {
            return [pscustomobject]@{
                ProcessId = 12345; ExecutablePath = (Join-Path $runtimeRoot 'pythonw.exe')
                CommandLine = $null
            }
        }
        function Remove-LauncherDirectory { throw 'Deletion must not start while the runtime is busy' }
        function New-PythonEnvironmentAt { throw 'Creation must not start while the runtime is busy' }
        Assert-Busy {
            if ($transaction -eq 'Runtime') {
                Install-RuntimeTransaction 'Portable' $null 'cpu' 'cpu' $null 'hardware'
            } else { Install-PythonBootstrapTransaction 'Portable' $null $null $runtimeRoot }
        }
    }
    & {
        $script:usageChecks = 0
        function Assert-RuntimeNotInUse {
            $script:usageChecks++
            if ($script:usageChecks -eq 2) { throw (New-BusyTestError) }
        }
        function Get-EnvironmentRootForMode { return $runtimeRoot }
        function Remove-LauncherDirectory {
            param($Path)
            Assert-UsageTest ($Path -eq "$runtimeRoot.new") 'Only staging cleanup is allowed before the second check'
        }
        function New-PythonEnvironmentAt { return 'staged-python.exe' }
        function Install-BackendRuntime {}
        function Test-Runtime { return $true }
        function Test-CompatiblePython { return $true }
        function Move-Item { throw 'Activation must not start while the runtime is busy' }
        Assert-Busy {
            if ($transaction -eq 'Runtime') {
                Install-RuntimeTransaction 'Portable' $null 'cpu' 'cpu' $null 'hardware'
            } else { Install-PythonBootstrapTransaction 'Portable' $null $null $runtimeRoot }
        }
        Assert-UsageTest ($script:usageChecks -eq 2) 'The runtime is checked again before activation'
    }
}
& {
    function Install-RuntimeTransaction { throw (New-BusyTestError) }
    function Read-Host { throw 'Busy runtime must not enter the CPU fallback menu' }
    Assert-Busy { Install-WithRecoveryChoice 'Portable' $null 'cuda' 'cuda' (Get-BackendMatrix) 'hardware' }
}
& {
    $BootstrapOnly = $false
    $InstallOnly = $false
    $BackendWasExplicit = $false
    $script:ordinaryLaunches = 0
    $previousBackend = $env:OMNIVOICE_ACTIVE_BACKEND
    function Get-VideoControllers { return @() }
    function Get-ProcessorName { return 'Test CPU' }
    function Get-HardwareInventory { return @() }
    function Get-HardwareFingerprint { return 'hardware' }
    function Get-SavedText { return 'cpu' }
    function Resolve-RequestedBackend { return 'cpu' }
    function Show-HardwareSummary {}
    function Resolve-PythonMode { return [pscustomobject]@{ Mode = 'Portable'; SystemPython = $null } }
    function New-Item {}
    function Set-Content {}
    function Test-Path { return $true }
    function Test-Runtime { return $true }
    function Assert-RuntimeNotInUse { throw 'Normal launches must not inspect or reject running users of the runtime' }
    function Start-WebInterface { $script:ordinaryLaunches++ }
    try {
        Invoke-LauncherSession
        Invoke-LauncherSession
        Assert-UsageTest ($script:ordinaryLaunches -eq 2) 'Multiple validated launches remain allowed'
    }
    finally {
        $env:OMNIVOICE_ACTIVE_BACKEND = $previousBackend
    }
}
Write-Host 'Runtime usage tests: OK (portable, venv redirectors, transaction guards and ordinary launches)'
