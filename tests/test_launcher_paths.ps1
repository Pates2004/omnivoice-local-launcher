. (Join-Path $PSScriptRoot '..\project_materials.ps1')

$ErrorActionPreference = 'Stop'
$testProject = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $testProject 'desktop_launcher.ps1'
if (-not (Test-Path -LiteralPath $launcherPath)) { $launcherPath = Join-Path $testProject 'launcher.ps1' }
. $launcherPath

function Assert-PathTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Launcher path regression failed: $Message" }
}
function Assert-UnsafeLauncherPath {
    param([scriptblock]$Action)
    try { & $Action | Out-Null }
    catch {
        Assert-PathTest ($_.Exception.Message -match 'links/junctions') 'Unsafe path explains link rejection'
        Assert-PathTest (Test-UnsafeLauncherPathError $_.Exception) 'Unsafe status remains identifiable'
        return
    }
    throw 'Launcher path regression failed: a managed link/junction was accepted.'
}

# The complete generated tree stays in this project's central Trash. The
# junction target is a synthetic sibling, never an existing user directory.
$scratch = Join-ProjectMaterialPath $testProject ('trash\launcher-paths-' + [Guid]::NewGuid().ToString('N'))
Assert-ProjectTestPath $scratch $testProject | Out-Null
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$ProjectRoot = Join-Path $scratch 'project'
$externalRoot = Join-Path $scratch 'target'
[IO.Directory]::CreateDirectory($ProjectRoot) | Out-Null
[IO.Directory]::CreateDirectory($externalRoot) | Out-Null
$sentinel = Join-Path $externalRoot 'keep.txt'
[IO.File]::WriteAllText($sentinel, 'Generated target must remain untouched.')
$linkedRoot = Join-Path $ProjectRoot 'env.new'
New-Item -ItemType Junction -Path $linkedRoot -Target $externalRoot | Out-Null
Assert-UnsafeLauncherPath { Assert-ProjectChildPath $linkedRoot }
Assert-UnsafeLauncherPath { Assert-ProjectChildPath (Join-Path $linkedRoot 'missing\future-file.txt') }
Assert-UnsafeLauncherPath { Remove-LauncherDirectory $linkedRoot }
Assert-PathTest ([IO.File]::ReadAllText($sentinel) -eq 'Generated target must remain untouched.') 'Junction target survives cleanup rejection'

$ordinaryRoot = Join-Path $ProjectRoot 'ordinary'
[IO.Directory]::CreateDirectory($ordinaryRoot) | Out-Null
New-Item -ItemType Junction -Path (Join-Path $ordinaryRoot 'nested') -Target $externalRoot | Out-Null
Assert-UnsafeLauncherPath { Remove-LauncherDirectory $ordinaryRoot }
Assert-PathTest (Test-Path -LiteralPath $ordinaryRoot) 'Rejected recursive cleanup does not remove its root'
Assert-PathTest (Test-Path -LiteralPath $sentinel) 'Nested junction target survives cleanup rejection'

# Non-name-surrogate cloud placeholders must not be treated as links. Mock
# metadata only; no OneDrive configuration or actual placeholder is changed.
& {
    function Get-LauncherReparseTag { return [Convert]::ToUInt32('9000001A', 16) }
    Assert-LauncherNonRedirectingEntry 'cloud-placeholder' ([IO.FileAttributes]::ReparsePoint)
}
& {
    function Get-LauncherReparseTag { throw 'Cannot read reparse metadata' }
    $failed = $false
    try { Assert-LauncherNonRedirectingEntry 'unreadable-entry' ([IO.FileAttributes]::ReparsePoint) }
    catch {
        $failed = $true
        Assert-PathTest ($_.Exception.Message -match 'Cannot read reparse metadata') 'Unreadable tag error remains visible'
    }
    Assert-PathTest $failed 'Unreadable tags fail closed'
}

$safeRoot = Join-Path $ProjectRoot 'safe [literal]'
[IO.Directory]::CreateDirectory((Join-Path $safeRoot 'child')) | Out-Null
[IO.File]::WriteAllText((Join-Path $safeRoot 'child\file.txt'), 'Disposable ordinary fixture.')
Assert-PathTest ((Assert-ProjectChildPath (Join-Path $safeRoot 'missing\file.txt')) -eq (Join-Path $safeRoot 'missing\file.txt')) 'Missing ordinary descendants remain valid'
Remove-LauncherDirectory $safeRoot
Assert-PathTest (-not (Test-Path -LiteralPath $safeRoot)) 'Ordinary recursive cleanup remains supported'
Write-Host 'Launcher managed-path tests: OK (direct/nested junctions, future paths and ordinary cleanup)'
