$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$isDesktop = Test-Path -LiteralPath (Join-Path $project 'desktop_launcher.ps1')
$batchName = if ($isDesktop) { 'start_desktop.bat' } else { 'start.bat' }
$launcherName = if ($isDesktop) { 'desktop_launcher.ps1' } else { 'launcher.ps1' }
$fixture = Join-Path $project ('trash\batch-path-tests-' + [Guid]::NewGuid().ToString('N') + '\space ! & (folder)')
[IO.Directory]::CreateDirectory($fixture) | Out-Null
Copy-Item -LiteralPath (Join-Path $project $batchName) -Destination (Join-Path $fixture $batchName)
$stub = @'
param([switch]$QueryHiddenLaunch, [switch]$SelfTest)
if ($QueryHiddenLaunch) { Write-Output 'FOREGROUND' }
else { Write-Output ('BATCH_PATH_OK:' + $PSScriptRoot) }
'@
[IO.File]::WriteAllText((Join-Path $fixture $launcherName), $stub)
try {
    foreach ($arguments in @(@('-SelfTest'), @())) {
        $result = & (Join-Path $fixture $batchName) @arguments
        if ($LASTEXITCODE -ne 0 -or ($result -join '\n') -notmatch [Regex]::Escape('BATCH_PATH_OK:' + $fixture)) {
            throw 'Batch launcher did not preserve the path containing spaces, !, & and parentheses.'
        }
    }
} finally { Set-Location -LiteralPath $project }
Write-Host 'Batch path quoting tests: OK'
