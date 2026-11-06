#requires -Version 7.0
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path $PSScriptRoot -Parent
$projectDirectory = Join-Path $repoRoot "obj/integration/dacpac-build/$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path (Join-Path $projectDirectory 'cdc') | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'sqlproject/*') -Destination $projectDirectory
Copy-Item -LiteralPath (Join-Path $repoRoot 'New-CdcConfigurationScript.ps1') -Destination $projectDirectory
$csvPath = Join-Path $projectDirectory 'cdc/tables.csv'
Copy-Item -LiteralPath (Join-Path $repoRoot 'examples/cdc/restaurant-sample-database.csv') -Destination $csvPath
$projectPath = Join-Path $projectDirectory 'CdcBuild.sqlproj'

function Get-PackagedPostDeploy {
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $projectDirectory 'bin/Debug/CdcBuild.dacpac'))
    try {
        $entry = $archive.GetEntry('postdeploy.sql')
        if (-not $entry) { throw 'DACPAC contains no post-deployment script.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $archive.Dispose() }
}

foreach ($revision in @('restaurant_orders', 'restaurant_orders_build_v2')) {
    if ($revision -eq 'restaurant_orders_build_v2') {
        $csv = [IO.File]::ReadAllText($csvPath).Replace('restaurant_orders', $revision)
        [IO.File]::WriteAllText($csvPath, $csv, [Text.UTF8Encoding]::new($false))
    }
    & dotnet build $projectPath --nologo
    if ($LASTEXITCODE -ne 0) { throw "DACPAC build failed for manifest revision $revision." }
    $postDeploy = Get-PackagedPostDeploy
    if (-not $postDeploy.Contains("@capture_instance = N'$revision'")) {
        throw "DACPAC is missing current generated configuration for $revision."
    }
    if ($revision -eq 'restaurant_orders_build_v2' -and $postDeploy.Contains("@capture_instance = N'restaurant_orders'")) {
        throw 'DACPAC retained stale configuration after the CSV changed.'
    }
    Write-Host "PASS: DACPAC packages the current $revision manifest."
}

[xml]$project = [IO.File]::ReadAllText($projectPath)
$command = $project.Project.Target.Exec.GetAttribute('Command')
$project.Project.Target.Exec.SetAttribute('Command', "$command -DropUnlistedCaptureInstances")
$project.Save($projectPath)
& dotnet build $projectPath --nologo
if ($LASTEXITCODE -ne 0) { throw 'DACPAC cleanup-mode build failed.' }
$postDeploy = Get-PackagedPostDeploy
if (-not $postDeploy.Contains('sys.sp_cdc_disable_table') -or
    $postDeploy.IndexOf('sys.sp_cdc_disable_table') -gt $postDeploy.IndexOf('sys.sp_cdc_enable_table')) {
    throw 'DACPAC is missing cleanup before capture-instance creation.'
}
Write-Host 'PASS: DACPAC packages opt-in cleanup before creation.'
