#requires -Version 7.0
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$generator = Join-Path $repoRoot 'New-CdcConfigurationScript.ps1'
$outputDirectory = Join-Path $repoRoot "obj/integration/generator-modes/$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$outputPath = Join-Path $outputDirectory 'configuration.sql'
$header = "SourceSchema,SourceName,CaptureInstanceName`n"
$emptyManifest = Join-Path $outputDirectory 'empty.csv'
[IO.File]::WriteAllText($emptyManifest, $header)

foreach ($case in @(
    @{ Name = 'empty-default'; Content = $header; Cleanup = $false },
    @{ Name = 'zero-byte'; Content = ''; Cleanup = $true },
    @{ Name = 'wrong-header'; Content = "Other,Columns`n"; Cleanup = $true },
    @{ Name = 'blank-row'; Content = "$header,,`n"; Cleanup = $true }
)) {
    $inputPath = Join-Path $outputDirectory "$($case.Name).csv"
    [IO.File]::WriteAllText($inputPath, $case.Content)
    [IO.File]::WriteAllText($outputPath, 'original-output')
    $rejected = $false
    try { & $generator -CsvPath $inputPath -OutputPath $outputPath -DropUnlistedCaptureInstances:$case.Cleanup | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid generator input was accepted: $($case.Name)" }
    if ([IO.File]::ReadAllText($outputPath) -cne 'original-output') { throw 'Rejected input overwrote output.' }
    Write-Host "PASS: $($case.Name) is rejected without overwriting output."
}

& $generator -CsvPath $emptyManifest -OutputPath $outputPath -DropUnlistedCaptureInstances | Out-Null
$sql = [IO.File]::ReadAllText($outputPath)
if (-not $sql.Contains('sys.sp_cdc_disable_table') -or $sql.Contains('sys.sp_cdc_enable_table') -or $sql.Contains('(VALUES')) {
    throw 'Header-only cleanup must produce a disable-only script with no empty VALUES list.'
}
Write-Host 'PASS: a valid header-only manifest produces database-wide disable-only SQL.'

$normalManifest = Join-Path $repoRoot 'examples/cdc/library-sample-database.csv'
& $generator -CsvPath $normalManifest -OutputPath $outputPath | Out-Null
$defaultSql = [IO.File]::ReadAllText($outputPath)
if (-not $defaultSql.Contains('SET LOCK_TIMEOUT 5000;')) {
    throw 'The default generated SQL must set a 5000 millisecond lock timeout.'
}

& $generator -CsvPath $normalManifest -OutputPath $outputPath -LockTimeout 1250 | Out-Null
$overrideSql = [IO.File]::ReadAllText($outputPath)
if (-not $overrideSql.Contains('SET LOCK_TIMEOUT 1250;')) {
    throw 'The generated SQL did not use the requested lock timeout.'
}

$rejectedNegativeTimeout = $false
try { & $generator -CsvPath $normalManifest -OutputPath $outputPath -LockTimeout -1 | Out-Null }
catch { $rejectedNegativeTimeout = $true }
if (-not $rejectedNegativeTimeout) { throw 'A negative lock timeout must be rejected.' }
Write-Host 'PASS: the lock timeout defaults to 5000 milliseconds, accepts overrides, and rejects negative values.'
