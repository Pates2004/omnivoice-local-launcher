$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$isDesktop = Test-Path -LiteralPath (Join-Path $project 'desktop_launcher.ps1')
$batchName = if ($isDesktop) { 'start_desktop.bat' } else { 'start.bat' }
$launcherName = if ($isDesktop) { 'desktop_launcher.ps1' } else { 'launcher.ps1' }
$scratch = Join-Path $project ('trash\batch-path-tests-' + [Guid]::NewGuid().ToString('N'))
$originalDirectory = (Get-Location).Path
$originalLiteralVariable = $env:OMNISONIC_LITERAL_PATH_TEST
$stub = @'
param([switch]$QueryHiddenLaunch, [switch]$SelfTest, [switch]$HiddenLaunch)
# Match Invoke-Main: PowerShell 5.1 can otherwise reset cwd when it contains [].
Set-Location -LiteralPath $PSScriptRoot
if ($QueryHiddenLaunch) {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'request-hidden.txt')) { Write-Output 'HIDE' }
    else { Write-Output 'FOREGROUND' }
    exit 0
}
$result = @{ path = $PSScriptRoot; cwd = (Get-Location).Path; hidden = [bool]$HiddenLaunch }
$resultName = if ($HiddenLaunch) { 'hidden-result.json' } else { 'result.json' }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot $resultName), ($result | ConvertTo-Json -Compress))
Write-Output 'BATCH_PATH_OK'
'@
try {
    $env:OMNISONIC_LITERAL_PATH_TEST = 'unexpected-expansion'
    # Construct Unicode explicitly so Windows PowerShell 5.1 can read this test
    # without depending on the source file's BOM or the active ANSI code page.
    $unicode = 'za' + [char]0x17C + [char]0xF3 + [char]0x142 + [char]0x107
    $names = @('space ! & (folder)', "$unicode [source] ^ ' folder", '%OMNISONIC_LITERAL_PATH_TEST% ! & (folder)')
    foreach ($name in $names) {
        $fixture = Join-Path $scratch $name
        [IO.Directory]::CreateDirectory($fixture) | Out-Null
        Copy-Item -LiteralPath (Join-Path $project $batchName) -Destination (Join-Path $fixture $batchName)
        [IO.File]::WriteAllText((Join-Path $fixture $launcherName), $stub)
        # Percent expansion by an external cmd caller is outside the BAT's
        # control. Relative invocation isolates expansion inside the launcher.
        $literalPercent = $name.Contains('%')
        $command = if ($literalPercent) { $env:ComSpec } else { Join-Path $fixture $batchName }
        $prefixArguments = if ($literalPercent) { @('/d', '/c', ('.\' + $batchName)) } else { @() }
        foreach ($arguments in @(@('-SelfTest'), @())) {
            if ($literalPercent) { Set-Location -LiteralPath $fixture }
            else { Set-Location -LiteralPath $project }
            $result = & $command @prefixArguments @arguments
            if ($LASTEXITCODE -ne 0 -or ($result -join '\n') -notmatch 'BATCH_PATH_OK') {
                throw "Batch launcher failed for fixture: $name"
            }
            $details = Get-Content -LiteralPath (Join-Path $fixture 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($details.path -ne $fixture -or $details.cwd -ne $fixture -or $details.hidden) {
                throw "Batch launcher changed the literal project path or did not set its working directory: $name"
            }
        }
        if ($isDesktop) {
            [IO.File]::WriteAllText((Join-Path $fixture 'request-hidden.txt'), '')
            if ($literalPercent) { Set-Location -LiteralPath $fixture }
            else { Set-Location -LiteralPath $project }
            & $command @prefixArguments
            if ($LASTEXITCODE -ne 0) { throw "Hidden batch launch failed: $name" }
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $resultPath = Join-Path $fixture 'hidden-result.json'
            while (-not (Test-Path -LiteralPath $resultPath) -and $timer.Elapsed.TotalSeconds -lt 15) {
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $resultPath)) { throw "Hidden launch did not complete: $name" }
            $details = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $details.hidden -or $details.path -ne $fixture -or $details.cwd -ne $fixture) {
                throw "Hidden launch lost its mode or literal working directory: $name"
            }
        }
    }
}
finally {
    Set-Location -LiteralPath $originalDirectory
    $env:OMNISONIC_LITERAL_PATH_TEST = $originalLiteralVariable
}
Write-Host 'Batch path quoting and working-directory tests: OK'
