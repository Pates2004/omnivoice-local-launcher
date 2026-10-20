$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\project_materials.ps1')
$project = Split-Path -Parent $PSScriptRoot
$workRoot = Get-ProjectMaterialsRoot $project
$projectName = Split-Path -Leaf $project
function Assert-MaterialTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Material path regression failed: $Message" }
}
foreach ($category in @('Forme', 'Workspace', 'Trash', 'Snapshots')) {
    $expected = Join-Path (Join-Path $workRoot $category) $projectName
    $directory = Get-ProjectMaterialDirectory $project $category.ToLowerInvariant()
    Assert-MaterialTest ($directory -eq $expected) "$category uses category/project order"
    $child = Join-ProjectMaterialPath $project ($category + '\nested\result.txt')
    Assert-MaterialTest ($child -eq (Join-Path $expected 'nested\result.txt')) "$category preserves the relative path"
    Assert-MaterialTest (Test-ProjectMaterialPath $child $project) "$category is inside this project's material scope"
    Assert-MaterialTest (-not (Test-ProjectMaterialPath ($expected + '-other\file') $project)) 'Similar project names are rejected'
}
foreach ($relative in @('Installfiles\release.zip', 'config\settings.json', 'desktop_launcher.ps1')) {
    Assert-MaterialTest ((Join-ProjectMaterialPath $project $relative) -eq (Join-Path $project $relative)) "$relative remains project-local"
}
foreach ($relative in @('..\escape', 'Trash\..\other-project', 'Trash\..\..\escape', 'C:\escape', '\escape', 'Trash\file:stream')) {
    $failed = $false
    try { Join-ProjectMaterialPath $project $relative | Out-Null }
    catch { $failed = $true }
    Assert-MaterialTest $failed "Unsafe path is rejected: $relative"
}
$other = Join-Path (Join-Path $workRoot 'Trash') 'other-project\file'
Assert-MaterialTest (-not (Test-ProjectMaterialPath $other $project)) 'A different project is outside the test scope'
Assert-MaterialTest (-not (Test-ProjectMaterialPath (Join-Path $workRoot 'Trash') $project)) 'The category parent itself is outside the test scope'
Write-Host 'Project material path tests: OK (category order, local app data and traversal rejection)'
