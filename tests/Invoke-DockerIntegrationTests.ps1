#requires -Version 7.0
<#
.SYNOPSIS
Runs CDC integration tests in a new disposable SQL Server Docker container.
.DESCRIPTION
Downloads the hash-pinned CC0 restaurant fixture into obj, creates an isolated
SQL Server Developer container, executes generated SQL, and removes the owned
container in finally. Requires PowerShell 7 and an x64 Linux Docker engine.
No existing SQL Server or Docker container is used or changed.
#>
[CmdletBinding()]
param (
    [string]$Image = 'mcr.microsoft.com/mssql/server:2022-latest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path $PSScriptRoot -Parent
$runId = [guid]::NewGuid().ToString('N')
$outputDirectory = Join-Path $repoRoot "obj/integration/$runId"
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$containerName = "sqlserver-cdc-test-$runId"
$networkName = "sqlserver-cdc-network-$runId"
$containerCreated = $false
$networkCreated = $false
$script:sqlServerAddress = $null
$script:sqlFileNumber = 0
$script:sqlcmdPath = $null
$script:passed = [System.Collections.Generic.List[string]]::new()
$savedSaPassword = $env:MSSQL_SA_PASSWORD
$savedSqlcmdPassword = $env:SQLCMDPASSWORD

function Invoke-TestDocker {
    param ([string[]]$DockerArguments)
    $output = & docker @DockerArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

function Invoke-TestSql {
    [CmdletBinding(DefaultParameterSetName = 'SqlText')]
    param (
        [string]$Database = 'master',
        [Parameter(Mandatory, ParameterSetName = 'SqlText')][string]$Sql,
        [Parameter(Mandatory, ParameterSetName = 'SqlFile')][string]$SqlFile,
        [int]$ExpectedError = 0
    )
    if ($PSCmdlet.ParameterSetName -eq 'SqlFile') {
        $localFile = (Resolve-Path -LiteralPath $SqlFile).Path
        $fileName = Split-Path $localFile -Leaf
    }
    else {
        $script:sqlFileNumber++
        $fileName = "query-$($script:sqlFileNumber).sql"
        $localFile = Join-Path $outputDirectory $fileName
        [IO.File]::WriteAllText($localFile, "SET NOCOUNT ON;`nGO`n$Sql", [Text.UTF8Encoding]::new($false))
    }
    Invoke-TestDocker -DockerArguments @('cp', $localFile, "${containerName}:/tmp/$fileName") | Out-Null
    $output = & docker exec --env SQLCMDPASSWORD $containerName $script:sqlcmdPath `
        -S 'tcp:127.0.0.1,1433' -U sa -C -b -r 1 -l 15 -t 90 -f 65001 -h -1 -W -d $Database -i "/tmp/$fileName" 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output -join [Environment]::NewLine).Trim()
    [IO.File]::WriteAllText((Join-Path $outputDirectory "$fileName.log"), $text)
    if ($ExpectedError -gt 0) {
        if ($exitCode -eq 0 -or $text -notmatch "Msg $ExpectedError,") {
            throw "Expected SQL error $ExpectedError, received exit code ${exitCode}: $text"
        }
    }
    elseif ($exitCode -ne 0) {
        throw "SQL failed in ${Database}: $text"
    }
    return $text
}

function Invoke-TestCsvExport {
    param ([string]$Database, [string]$OutputPath)
    $securePassword = ConvertTo-SecureString $env:MSSQL_SA_PASSWORD -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('sa', $securePassword)
    & (Join-Path $repoRoot 'Export-CdcConfigurationCsv.ps1') `
        -ServerInstance "$script:sqlServerAddress,1433" `
        -Database $Database `
        -OutputPath $OutputPath `
        -Credential $credential `
        -TrustServerCertificate | Out-Null
}

function New-TestManifestSql {
    param ([object[]]$Rows, [string]$Name)
    $csvPath = Join-Path $outputDirectory "$Name.csv"
    $sqlPath = Join-Path $outputDirectory "$Name.sql"
    $Rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    & (Join-Path $repoRoot 'New-CdcConfigurationScript.ps1') -CsvPath $csvPath -OutputPath $sqlPath | Out-Null
    return [IO.File]::ReadAllText($sqlPath)
}

function New-TestRow {
    param ([string]$Table, [string]$Capture, [string]$Schema = 'dbo')
    return [pscustomobject]@{ SourceSchema = $Schema; SourceName = $Table; CaptureInstanceName = $Capture }
}

function Get-CaptureSnapshot {
    param ([string]$Database = 'CdcRestaurant')
    return Invoke-TestSql -Database $Database -Sql @'
SELECT capture_instance, source_object_id, object_id, CONVERT(varchar(33), create_date, 126)
FROM cdc.change_tables ORDER BY capture_instance;
'@
}

function Assert-Unchanged {
    param ([string]$Before)
    if ((Get-CaptureSnapshot) -ne $Before) { throw 'A rejected manifest changed CDC configuration.' }
}

function Complete-Test {
    param ([string]$Name)
    $script:passed.Add($Name)
    Write-Host "PASS: $Name"
}

try {
    $architecture = Invoke-TestDocker -DockerArguments @('info', '--format', '{{.Architecture}}')
    if ($architecture.Trim() -notin @('x86_64', 'amd64')) {
        throw "SQL Server integration tests require an x64 Linux Docker engine; found '$architecture'. The GitHub Actions integration job provides one."
    }

    $fixturePath = Join-Path $outputDirectory 'restaurant.sql'
    $fixtureUrl = 'https://database-sample-website.s3.eu-north-1.amazonaws.com/datasets/restaurant-sample-database/v2/sql/mssql.sql'
    Invoke-WebRequest -Uri $fixtureUrl -OutFile $fixturePath -TimeoutSec 60
    $expectedHash = '1393A2A564D2C1F759F85A58003C2242BD0656A72709EB2C73C684BD66A56561'
    if ((Get-FileHash $fixturePath -Algorithm SHA256).Hash -ne $expectedHash) {
        throw 'Restaurant fixture SHA-256 changed. Review the upstream SQL before updating the pinned hash.'
    }

    $env:MSSQL_SA_PASSWORD = "Cdc!$([guid]::NewGuid().ToString('N'))aA7"
    $env:SQLCMDPASSWORD = $env:MSSQL_SA_PASSWORD
    Write-Host "Creating isolated container from $Image..."
    Invoke-TestDocker -DockerArguments @(
        'network', 'create', '--internal',
        '--label', 'io.amtwo.sqlserver-cdc-deployment.test=true', $networkName
    ) | Out-Null
    $networkCreated = $true
    Invoke-TestDocker -DockerArguments @(
        'create', '--name', $containerName, '--platform', 'linux/amd64', '--network', $networkName,
        '--label', 'io.amtwo.sqlserver-cdc-deployment.test=true',
        '--env', 'ACCEPT_EULA=Y', '--env', 'MSSQL_PID=Developer',
        '--env', 'MSSQL_AGENT_ENABLED=true', '--env', 'MSSQL_SA_PASSWORD', $Image
    ) | Out-Null
    $containerCreated = $true
    Invoke-TestDocker -DockerArguments @('start', $containerName) | Out-Null
    $script:sqlServerAddress = Invoke-TestDocker -DockerArguments @(
        'inspect', '--format', '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', $containerName
    )
    if ($script:sqlServerAddress.Trim() -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw "Could not resolve the SQL Server container address on the internal network: $script:sqlServerAddress"
    }
    foreach ($candidate in @('/opt/mssql-tools18/bin/sqlcmd', '/opt/mssql-tools/bin/sqlcmd')) {
        $toolOutput = & docker exec $containerName $candidate '-?' 2>&1
        if ($LASTEXITCODE -eq 0) { $script:sqlcmdPath = $candidate; break }
    }
    if (-not $script:sqlcmdPath) { throw "No working sqlcmd in the test image: $toolOutput" }
    Write-Host 'Waiting for SQL Server to accept connections...'

    $ready = $false
    $deadline = [DateTime]::UtcNow.AddMinutes(2)
    do {
        $readinessOutput = & docker exec --env SQLCMDPASSWORD $containerName $script:sqlcmdPath `
            -S 'tcp:127.0.0.1,1433' -U sa -C -b -l 2 -Q 'SELECT 1' 2>&1
        $readinessExitCode = $LASTEXITCODE
        ($readinessOutput -join [Environment]::NewLine) | Set-Content (Join-Path $outputDirectory 'readiness.log')
        if ($readinessExitCode -eq 0) { $ready = $true; break }
        $state = Invoke-TestDocker -DockerArguments @('inspect', '--format', '{{.State.Running}}', $containerName)
        if ($state.Trim() -ne 'true') { throw 'SQL Server container exited before becoming ready.' }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw "SQL Server readiness failed within two minutes: $readinessOutput" }

    $version = Invoke-TestSql -Sql 'SELECT @@VERSION;'
    $digest = Invoke-TestDocker -DockerArguments @('image', 'inspect', $Image, '--format', '{{json .RepoDigests}}')
    Write-Host $version
    Write-Host "Image: $digest"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"

    Invoke-TestSql -Sql 'CREATE DATABASE CdcRestaurant COLLATE Latin1_General_100_CI_AS; CREATE DATABASE CdcDisabled;' | Out-Null
    Invoke-TestSql -Database CdcRestaurant -SqlFile $fixturePath | Out-Null
    Invoke-TestSql -Database CdcRestaurant -Sql @'
IF (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) <> 23
    THROW 52000, 'Restaurant seed must create 23 tables.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.orders) OR NOT EXISTS (SELECT 1 FROM dbo.order_items) OR NOT EXISTS (SELECT 1 FROM dbo.payments)
    THROW 52000, 'Restaurant seed did not load the selected tables.', 1;
EXEC sys.sp_cdc_enable_db;
'@ | Out-Null

    $restaurantSqlPath = Join-Path $outputDirectory 'restaurant-cdc.sql'
    & (Join-Path $repoRoot 'New-CdcConfigurationScript.ps1') `
        -CsvPath (Join-Path $repoRoot 'examples/cdc/restaurant-sample-database.csv') -OutputPath $restaurantSqlPath | Out-Null
    $restaurantSql = [IO.File]::ReadAllText($restaurantSqlPath)

    Invoke-TestSql -Database CdcDisabled -Sql $restaurantSql -ExpectedError 51000 | Out-Null
    Invoke-TestSql -Database CdcDisabled -Sql @'
IF EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_cdc_enabled = 1)
   OR SCHEMA_ID(N'cdc') IS NOT NULL
    THROW 52000, 'CDC-disabled target was changed.', 1;
'@ | Out-Null
    Complete-Test 'CDC-disabled target fails with 51000 and remains disabled'

    Invoke-TestSql -Database CdcRestaurant -Sql $restaurantSql | Out-Null
    Invoke-TestSql -Database CdcRestaurant -Sql @'
IF (SELECT COUNT(*) FROM cdc.change_tables) <> 3
    THROW 52000, 'Expected three restaurant capture instances.', 1;
IF EXISTS
(
    SELECT capture_instance, source_object_id
    FROM (VALUES
        (N'restaurant_orders', OBJECT_ID(N'dbo.orders')),
        (N'restaurant_order_items', OBJECT_ID(N'dbo.order_items')),
        (N'restaurant_payments', OBJECT_ID(N'dbo.payments'))
    ) AS expected(capture_instance, source_object_id)
    EXCEPT
    SELECT capture_instance, source_object_id FROM cdc.change_tables
)
    THROW 52000, 'Restaurant capture-instance mappings do not match the manifest.', 1;
'@ | Out-Null
    Complete-Test 'Restaurant seed schema and data followed by generated CDC deployment'

    $exportPath = Join-Path $outputDirectory 'restaurant-export.csv'
    Invoke-TestCsvExport -Database CdcRestaurant -OutputPath $exportPath
    $exportedRows = @(Import-Csv -LiteralPath $exportPath | Sort-Object SourceSchema, SourceName, CaptureInstanceName)
    $expectedRows = @(Import-Csv -LiteralPath (Join-Path $repoRoot 'examples/cdc/restaurant-sample-database.csv') | Sort-Object SourceSchema, SourceName, CaptureInstanceName)
    if ($exportedRows.Count -ne $expectedRows.Count) { throw 'The CDC CSV export returned an unexpected number of capture instances.' }
    for ($index = 0; $index -lt $expectedRows.Count; $index++) {
        foreach ($column in @('SourceSchema', 'SourceName', 'CaptureInstanceName')) {
            if ($exportedRows[$index].$column -cne $expectedRows[$index].$column) {
                throw "The CDC CSV export returned an unexpected $column at sorted row $index."
            }
        }
    }
    $exportBytes = [IO.File]::ReadAllBytes($exportPath)
    if ($exportBytes.Length -ge 3 -and $exportBytes[0] -eq 0xEF -and $exportBytes[1] -eq 0xBB -and $exportBytes[2] -eq 0xBF) {
        throw 'The CDC CSV export unexpectedly contains a UTF-8 byte order mark.'
    }
    Complete-Test 'Read-only CDC CSV export matches the configured table and capture-instance mappings'

    $disabledDatabaseOutput = Join-Path $outputDirectory 'cdc-disabled.csv'
    try {
        Invoke-TestCsvExport -Database master -OutputPath $disabledDatabaseOutput
        throw 'The CDC CSV export unexpectedly succeeded for a database with CDC disabled.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'CDC is not enabled for database') { throw }
    }
    if (Test-Path -LiteralPath $disabledDatabaseOutput) {
        throw 'The CDC CSV exporter wrote output for a database with CDC disabled.'
    }
    Complete-Test 'CDC CSV export rejects a database with CDC disabled without writing a file'

    $before = Get-CaptureSnapshot
    Invoke-TestSql -Database CdcRestaurant -Sql $restaurantSql | Out-Null
    Assert-Unchanged $before
    Complete-Test 'Repeat deployment preserves capture instances and change-table identities'

    Invoke-TestSql -Database CdcRestaurant -Sql 'UPDATE dbo.orders SET total_amount = total_amount + 1 WHERE order_id = (SELECT MIN(order_id) FROM dbo.orders);' | Out-Null
    $captured = $false
    $deadline = [DateTime]::UtcNow.AddMinutes(1)
    do {
        $status = Invoke-TestSql -Database CdcRestaurant -Sql "SELECT CASE WHEN EXISTS (SELECT 1 FROM cdc.restaurant_orders_CT WHERE __`$operation = 4) THEN N'captured' ELSE N'pending' END;"
        if ($status.Trim() -eq 'captured') { $captured = $true; break }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $captured) { throw 'SQL Server Agent did not capture the restaurant order update within one minute.' }
    Complete-Test 'A real restaurant order update appears in its CDC change table'

    Invoke-TestSql -Database CdcRestaurant -Sql 'CREATE TABLE dbo.EarlierProbe (id int PRIMARY KEY); CREATE TABLE dbo.CapacityProbe (id int PRIMARY KEY);' | Out-Null
    $missingSql = New-TestManifestSql -Name missing -Rows @(
        (New-TestRow EarlierProbe earlier_capture), (New-TestRow MissingTable missing_capture)
    )
    $before = Get-CaptureSnapshot
    Invoke-TestSql -Database CdcRestaurant -Sql $missingSql -ExpectedError 51001 | Out-Null
    Assert-Unchanged $before
    Complete-Test 'Missing source fails before an earlier valid manifest row is enabled'

    $conflictSql = New-TestManifestSql -Name conflict -Rows @(
        (New-TestRow EarlierProbe earlier_capture), (New-TestRow CapacityProbe restaurant_orders)
    )
    Invoke-TestSql -Database CdcRestaurant -Sql $conflictSql -ExpectedError 51002 | Out-Null
    Assert-Unchanged $before
    Complete-Test 'Capture-instance conflict fails before any manifest changes'

    $secondSql = New-TestManifestSql -Name second -Rows @((New-TestRow orders restaurant_orders_v2))
    Invoke-TestSql -Database CdcRestaurant -Sql $secondSql | Out-Null
    Invoke-TestSql -Database CdcRestaurant -Sql "IF (SELECT COUNT(*) FROM cdc.change_tables WHERE source_object_id = OBJECT_ID(N'dbo.orders')) <> 2 THROW 52000, 'Second instance was not created.', 1;" | Out-Null
    $before = Get-CaptureSnapshot
    Invoke-TestSql -Database CdcRestaurant -Sql $secondSql | Out-Null
    Assert-Unchanged $before
    Complete-Test 'A second capture instance is allowed and repeat deployment is idempotent'

    Invoke-TestSql -Database CdcRestaurant -Sql "EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'CapacityProbe', @role_name=NULL, @capture_instance=N'capacity_existing', @supports_net_changes=0;" | Out-Null
    $capacitySql = New-TestManifestSql -Name capacity -Rows @(
        (New-TestRow EarlierProbe earlier_capture),
        (New-TestRow CapacityProbe capacity_new_one), (New-TestRow capacityprobe capacity_new_two)
    )
    $before = Get-CaptureSnapshot
    Invoke-TestSql -Database CdcRestaurant -Sql $capacitySql -ExpectedError 51003 | Out-Null
    Assert-Unchanged $before
    Complete-Test 'Combined plan respects existing capacity and case-insensitive table aliases'

    $thirdSql = New-TestManifestSql -Name third -Rows @((New-TestRow orders restaurant_orders_v3))
    Invoke-TestSql -Database CdcRestaurant -Sql $thirdSql -ExpectedError 51003 | Out-Null
    Assert-Unchanged $before
    Complete-Test 'An existing pair of capture instances rejects a third instance'

    Invoke-TestSql -Database CdcRestaurant -Sql "CREATE SCHEMA [odd'schema]]];" | Out-Null
    Invoke-TestSql -Database CdcRestaurant -Sql "CREATE TABLE [odd'schema]]].[odd'table]]] (id int PRIMARY KEY); CREATE TABLE dbo.InjectionSentinel (id int);" | Out-Null
    $quotedSql = New-TestManifestSql -Name quoted -Rows @((New-TestRow "odd'table]" quoted_capture "odd'schema]"))
    Invoke-TestSql -Database CdcRestaurant -Sql $quotedSql | Out-Null
    Invoke-TestSql -Database CdcRestaurant -Sql "IF NOT EXISTS (SELECT 1 FROM cdc.change_tables WHERE capture_instance=N'quoted_capture') THROW 52000, 'Quoted source was not captured.', 1;" | Out-Null
    Complete-Test 'QUOTENAME nested inside OBJECT_ID resolves apostrophes and closing brackets'

    $hostileSql = New-TestManifestSql -Name hostile -Rows @((New-TestRow "absent'; DROP TABLE dbo.InjectionSentinel;--" hostile_capture))
    $before = Get-CaptureSnapshot
    Invoke-TestSql -Database CdcRestaurant -Sql $hostileSql -ExpectedError 51001 | Out-Null
    Assert-Unchanged $before
    Invoke-TestSql -Database CdcRestaurant -Sql "IF OBJECT_ID(N'dbo.InjectionSentinel', N'U') IS NULL THROW 52000, 'CSV value escaped its SQL literal.', 1;" | Out-Null
    Complete-Test 'Hostile CSV text stays data in lookup and error-message literals'

    Invoke-TestSql -Sql 'CREATE DATABASE CdcCaseSensitive COLLATE Latin1_General_100_CS_AS;' | Out-Null
    Invoke-TestSql -Database CdcCaseSensitive -Sql 'CREATE TABLE dbo.Foo (id int PRIMARY KEY); CREATE TABLE dbo.foo (id int PRIMARY KEY); EXEC sys.sp_cdc_enable_db;' | Out-Null
    $caseSql = New-TestManifestSql -Name case-sensitive -Rows @(
        (New-TestRow Foo upper_one), (New-TestRow Foo upper_two),
        (New-TestRow foo lower_one), (New-TestRow foo lower_two)
    )
    Invoke-TestSql -Database CdcCaseSensitive -Sql $caseSql | Out-Null
    Invoke-TestSql -Database CdcCaseSensitive -Sql "IF (SELECT COUNT(*) FROM cdc.change_tables) <> 4 THROW 52000, 'Distinct case-sensitive tables were combined.', 1;" | Out-Null
    Complete-Test 'Case-sensitive source tables have independent two-instance limits'

    Invoke-TestSql -Sql 'CREATE DATABASE CdcAccentInsensitive COLLATE Latin1_General_100_CI_AI;' | Out-Null
    Invoke-TestSql -Database CdcAccentInsensitive -Sql 'CREATE TABLE dbo.A (id int PRIMARY KEY); CREATE TABLE dbo.B (id int PRIMARY KEY); EXEC sys.sp_cdc_enable_db;' | Out-Null
    foreach ($secondTable in @('B', 'A')) {
        $collisionSql = New-TestManifestSql -Name "accent-collision-$secondTable" -Rows @(
            (New-TestRow A cafe), (New-TestRow $secondTable 'café')
        )
        $probeSql = @"
BEGIN TRY
$collisionSql
END TRY
BEGIN CATCH
    DECLARE @instance_count int = (SELECT COUNT(*) FROM cdc.change_tables);
    PRINT N'Capture instances after rejected manifest: ' + CONVERT(nvarchar(10), @instance_count);
    THROW;
END CATCH;
"@
        Invoke-TestSql -Database CdcAccentInsensitive -Sql $probeSql -ExpectedError 51004 | Out-Null
        Invoke-TestSql -Database CdcAccentInsensitive -Sql "IF EXISTS (SELECT 1 FROM cdc.change_tables) THROW 52000, 'Colliding manifest changed CDC configuration.', 1;" | Out-Null
    }
    Complete-Test 'Target-collation capture-instance collisions fail before any changes'

    [ordered]@{
        engine = $version; image = $digest; powershell = $PSVersionTable.PSVersion.ToString()
        fixtureUrl = $fixtureUrl; fixtureSha256 = $expectedHash; passed = @($script:passed)
    } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outputDirectory 'results.json') -Encoding utf8
    Write-Host "All $($script:passed.Count) integration checks passed. Results: $outputDirectory"
}
finally {
    if ($containerCreated) {
        & docker logs $containerName *> (Join-Path $outputDirectory 'container.log')
        & docker cp "${containerName}:/var/opt/mssql/log/sqlagent.out" (Join-Path $outputDirectory 'sqlagent.log') 2>$null
        $cleanupOutput = & docker rm --force $containerName 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warning "Unable to remove owned test container ${containerName}: $cleanupOutput" }
    }
    if ($networkCreated) {
        $networkCleanupOutput = & docker network rm $networkName 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warning "Unable to remove owned test network ${networkName}: $networkCleanupOutput" }
    }
    $env:MSSQL_SA_PASSWORD = $savedSaPassword
    $env:SQLCMDPASSWORD = $savedSqlcmdPassword
}
