#requires -Version 7.0
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$outputDirectory = Join-Path $repoRoot "obj/integration/example-output/$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

foreach ($dataset in @('restaurant', 'library')) {
  foreach ($cleanup in @($false, $true)) {
    $suffix = if ($cleanup) { '.cleanup' } else { '' }
    $freshPath = Join-Path $outputDirectory "$dataset$suffix.sql"
    $examplePath = Join-Path $repoRoot "examples/cdc/$dataset-sample-database$suffix.sql"
    & (Join-Path $repoRoot 'New-CdcConfigurationScript.ps1') `
        -CsvPath (Join-Path $repoRoot "examples/cdc/$dataset-sample-database.csv") `
        -OutputPath $freshPath -DropUnlistedCaptureInstances:$cleanup | Out-Null

    $freshBytes = [IO.File]::ReadAllBytes($freshPath)
    $exampleBytes = [IO.File]::ReadAllBytes($examplePath)
    if ([Convert]::ToBase64String($freshBytes) -cne [Convert]::ToBase64String($exampleBytes)) {
        throw "$dataset$suffix SQL example is not literal generator output. Regenerate it; byte comparison includes encoding and line endings."
    }
    Write-Host "PASS: $dataset$suffix example matches literal generator output ($($freshBytes.Length) bytes, SHA-256 $((Get-FileHash $freshPath -Algorithm SHA256).Hash))."
  }
}
