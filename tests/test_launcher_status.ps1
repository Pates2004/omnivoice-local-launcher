. (Join-Path $PSScriptRoot '..\project_materials.ps1')

$ErrorActionPreference = 'Stop'
$testProject = Split-Path -Parent $PSScriptRoot
$lifecyclePath = Join-Path $PSScriptRoot 'test_launcher_lifecycle.ps1'
$scratch = Join-ProjectMaterialPath $testProject ('trash\hosted-status-' + [Guid]::NewGuid().ToString('N'))
Assert-ProjectTestPath $scratch $testProject | Out-Null
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$failurePath = Join-Path $scratch 'assertion-failure.ps1'
[IO.File]::WriteAllText($failurePath, (@(
    '$ErrorActionPreference = ''Stop''',
    '$global:LASTEXITCODE = 0',
    'throw ''EXPECTED_HOSTED_ASSERTION_FAILURE''',
    '$global:LASTEXITCODE = 0'
) -join "`r`n"))
$hostPath = Join-Path $PSHOME 'powershell.exe'
foreach ($case in @(
    @{ Path = $lifecyclePath; Expected = 0 },
    @{ Path = $failurePath; Expected = 1 }
)) {
    $literalPath = "'" + $case.Path.Replace("'", "''") + "'"
    $command = '$ErrorActionPreference = ''Stop''; & ' + $literalPath + '; exit $LASTEXITCODE'
    $priorErrorAction = $ErrorActionPreference
    try {
        # Windows PowerShell represents the intentionally failing assertion's
        # stderr as ErrorRecords; inspect its real exit status, not that wrapper.
        $ErrorActionPreference = 'Continue'
        $output = @(& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $priorErrorAction }
    if ($exitCode -ne $case.Expected) {
        throw "Hosted launcher status regression failed: expected $($case.Expected), got $exitCode. $($output -join ' ')"
    }
    if ($case.Expected -eq 1 -and ($output -join ' ') -notmatch 'EXPECTED_HOSTED_ASSERTION_FAILURE') {
        throw 'Hosted status failure did not exercise the expected assertion.'
    }
}
$global:LASTEXITCODE = 0
Write-Host 'Hosted launcher status tests: OK (successful assertions return zero, real assertion failure remains nonzero)'
