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
$containerCreated = $false
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
        [int]$ExpectedError = 0,
        [switch]$ExpectedLockTimeout
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
    elseif ($ExpectedLockTimeout) {
        if ($exitCode -eq 0 -or $text -notmatch '(?i)(1222|lock request time out period exceeded)') {
            throw "Expected a SQL Server lock timeout, received exit code ${exitCode}: $text"
        }
    }
    elseif ($exitCode -ne 0) {
        throw "SQL failed in ${Database}: $text"
    }
    return $text
}

function New-TestManifestSql {
    param ([object[]]$Rows, [string]$Name, [switch]$DropUnlistedCaptureInstances, [int]$LockTimeout = 5000)
    $csvPath = Join-Path $outputDirectory "$Name.csv"
    $sqlPath = Join-Path $outputDirectory "$Name.sql"
    $Rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    & (Join-Path $repoRoot 'New-CdcConfigurationScript.ps1') -CsvPath $csvPath -OutputPath $sqlPath `
        -DropUnlistedCaptureInstances:$DropUnlistedCaptureInstances -LockTimeout $LockTimeout | Out-Null
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
    param ([string]$Before, [string]$Database = 'CdcRestaurant')
    if ((Get-CaptureSnapshot -Database $Database) -ne $Before) { throw 'A rejected manifest changed CDC configuration.' }
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
        'create', '--name', $containerName, '--platform', 'linux/amd64', '--network', 'none',
        '--label', 'io.amtwo.sqlserver-cdc-deployment.test=true',
        '--env', 'ACCEPT_EULA=Y', '--env', 'MSSQL_PID=Developer',
        '--env', 'MSSQL_AGENT_ENABLED=true', '--env', 'MSSQL_SA_PASSWORD', $Image
    ) | Out-Null
    $containerCreated = $true
    Invoke-TestDocker -DockerArguments @('start', $containerName) | Out-Null
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

    Invoke-TestSql -Sql 'CREATE DATABASE CdcCleanup COLLATE Latin1_General_100_CI_AS;' | Out-Null
    Invoke-TestSql -Database CdcCleanup -Sql @'
CREATE TABLE dbo.Stuff (id int PRIMARY KEY);
CREATE TABLE dbo.Omitted (id int PRIMARY KEY);
INSERT dbo.Omitted VALUES (42);
EXEC sys.sp_cdc_enable_db;
EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'Stuff', @role_name=NULL, @capture_instance=N'dbo_stuff', @supports_net_changes=0;
EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'Stuff', @role_name=NULL, @capture_instance=N'dbo_stuff_2', @supports_net_changes=0;
EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'Omitted', @role_name=NULL, @capture_instance=N'legacy''capture', @supports_net_changes=0;
'@ | Out-Null
    $rotationRows = @((New-TestRow Stuff dbo_stuff_2), (New-TestRow Stuff dbo_stuff_3))
    $defaultRotation = New-TestManifestSql -Name default-rotation -Rows $rotationRows
    if ($defaultRotation.Contains('sys.sp_cdc_disable_table')) { throw 'Default generation unexpectedly contains cleanup.' }
    $before = Get-CaptureSnapshot -Database CdcCleanup
    Invoke-TestSql -Database CdcCleanup -Sql $defaultRotation -ExpectedError 51003 | Out-Null
    Assert-Unchanged $before -Database CdcCleanup
    Complete-Test 'Default mode preserves unlisted instances and rejects occupied slots'

    $lockTimeoutSql = New-TestManifestSql -Name lock-timeout -Rows $rotationRows -DropUnlistedCaptureInstances -LockTimeout 500
    $lockTimeoutProbe = $lockTimeoutSql.Replace(
        'SET LOCK_TIMEOUT 500;',
        "SET LOCK_TIMEOUT 500;`nIF @@LOCK_TIMEOUT <> 500 THROW 52000, N'Configured lock timeout is not active for this session.', 1;"
    )
    if ($lockTimeoutProbe -ceq $lockTimeoutSql) { throw 'Unable to insert the session lock-timeout assertion.' }
    $before = Get-CaptureSnapshot -Database CdcCleanup
    $blockerSql = "BEGIN TRAN; SELECT COUNT(*) FROM cdc.dbo_stuff_CT WITH (TABLOCKX, HOLDLOCK); WAITFOR DELAY '00:00:15'; ROLLBACK;"
    Invoke-TestDocker -DockerArguments @('exec', '-d', '--env', 'SQLCMDPASSWORD', $containerName, $script:sqlcmdPath,
        '-S', 'tcp:127.0.0.1,1433', '-U', 'sa', '-C', '-b', '-d', 'CdcCleanup', '-Q', $blockerSql) | Out-Null
    $blockerReady = $false
    $blockerDeadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $blockerReady = [int](Invoke-TestSql -Database CdcCleanup -Sql "SELECT COUNT(*) FROM sys.dm_tran_locks WHERE resource_database_id=DB_ID() AND resource_associated_entity_id=OBJECT_ID(N'cdc.dbo_stuff_CT') AND request_mode=N'X' AND request_status=N'GRANT' AND request_session_id <> @@SPID;") -gt 0
        if ($blockerReady) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $blockerDeadline)
    if (-not $blockerReady) { throw 'The disposable blocker did not acquire an exclusive lock on the CDC change table.' }
    Invoke-TestSql -Database CdcCleanup -Sql $lockTimeoutProbe -ExpectedLockTimeout | Out-Null
    Assert-Unchanged $before -Database CdcCleanup
    Complete-Test 'A blocked CDC cleanup fails at the configured lock timeout without changing capture instances'
    do {
        $blockerReady = [int](Invoke-TestSql -Database CdcCleanup -Sql "SELECT COUNT(*) FROM sys.dm_tran_locks WHERE resource_database_id=DB_ID() AND resource_associated_entity_id=OBJECT_ID(N'cdc.dbo_stuff_CT') AND request_mode=N'X' AND request_status=N'GRANT' AND request_session_id <> @@SPID;") -gt 0
        if (-not $blockerReady) { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $blockerDeadline.AddSeconds(12))
    if ($blockerReady) { throw 'The disposable lock blocker did not release its test lock.' }

    $rotationSql = New-TestManifestSql -Name cleanup-rotation -Rows $rotationRows -DropUnlistedCaptureInstances
    if ($rotationSql.Contains("N'dbo_stuff'")) { throw 'Cleanup SQL explicitly embeds the removed capture name.' }
    if ($rotationSql.IndexOf('sys.sp_cdc_disable_table') -gt $rotationSql.IndexOf('sys.sp_cdc_enable_table')) { throw 'Cleanup is after creation.' }
    Invoke-TestSql -Database CdcDisabled -Sql $rotationSql -ExpectedError 51000 | Out-Null
    Complete-Test 'Cleanup mode also refuses a CDC-disabled target'

    foreach ($case in @(
        @{ Name = 'cleanup-missing'; Error = 51001; Rows = @((New-TestRow Stuff dbo_stuff_2), (New-TestRow Missing missing_capture)) },
        @{ Name = 'cleanup-conflict'; Error = 51002; Rows = @((New-TestRow Stuff "legacy'capture")) },
        @{ Name = 'cleanup-cdc-source'; Error = 51007; Rows = @((New-TestRow change_tables invalid_cdc_source cdc)) },
        @{ Name = 'cleanup-over-capacity'; Error = 51003; Rows = @((New-TestRow Stuff new_one), (New-TestRow stuff new_two), (New-TestRow Stuff new_three)) }
    )) {
        $invalidSql = New-TestManifestSql -Name $case.Name -Rows $case.Rows -DropUnlistedCaptureInstances
        Invoke-TestSql -Database CdcCleanup -Sql $invalidSql -ExpectedError $case.Error | Out-Null
        Assert-Unchanged $before -Database CdcCleanup
    }
    Complete-Test 'Invalid cleanup manifests fail before dropping any existing instance'

    $retainedBefore = Invoke-TestSql -Database CdcCleanup -Sql "SELECT object_id, CONVERT(varchar(33), create_date, 126) FROM cdc.change_tables WHERE capture_instance=N'dbo_stuff_2';"
    Invoke-TestSql -Database CdcCleanup -Sql $rotationSql | Out-Null
    Invoke-TestSql -Database CdcCleanup -Sql @'
IF (SELECT COUNT(*) FROM cdc.change_tables) <> 2
   OR NOT EXISTS (SELECT 1 FROM cdc.change_tables WHERE capture_instance=N'dbo_stuff_2')
   OR NOT EXISTS (SELECT 1 FROM cdc.change_tables WHERE capture_instance=N'dbo_stuff_3')
    THROW 52000, 'Cleanup did not replace the obsolete instance at full capacity.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Omitted WHERE id=42)
   OR EXISTS (SELECT 1 FROM sys.tables WHERE object_id=OBJECT_ID(N'dbo.Omitted') AND is_tracked_by_cdc=1)
    THROW 52000, 'Omitted-table cleanup changed source data or retained its instance.', 1;
'@ | Out-Null
    $retainedAfter = Invoke-TestSql -Database CdcCleanup -Sql "SELECT object_id, CONVERT(varchar(33), create_date, 126) FROM cdc.change_tables WHERE capture_instance=N'dbo_stuff_2';"
    if ($retainedAfter -cne $retainedBefore) { throw 'Cleanup recreated a retained instance.' }
    Complete-Test 'Generic database-wide cleanup frees a slot and preserves retained instances and source data'

    $before = Get-CaptureSnapshot -Database CdcCleanup
    Invoke-TestSql -Database CdcCleanup -Sql $rotationSql | Out-Null
    Assert-Unchanged $before -Database CdcCleanup
    Complete-Test 'Repeating cleanup mode preserves the desired instances'

    $replaceBothSql = New-TestManifestSql -Name replace-both -Rows @((New-TestRow Stuff dbo_stuff_4), (New-TestRow Stuff dbo_stuff_5)) -DropUnlistedCaptureInstances
    Invoke-TestSql -Database CdcCleanup -Sql $replaceBothSql | Out-Null
    Invoke-TestSql -Database CdcCleanup -Sql "IF (SELECT COUNT(*) FROM cdc.change_tables WHERE capture_instance IN (N'dbo_stuff_4', N'dbo_stuff_5')) <> 2 OR (SELECT COUNT(*) FROM cdc.change_tables) <> 2 THROW 52000, 'Replacing both occupied instances failed.', 1;" | Out-Null
    Complete-Test 'Both occupied slots can be replaced in one deployment'

    $removeRowSql = New-TestManifestSql -Name remove-row -Rows @((New-TestRow Stuff dbo_stuff_5)) -DropUnlistedCaptureInstances
    Invoke-TestSql -Database CdcCleanup -Sql $removeRowSql | Out-Null
    Invoke-TestSql -Database CdcCleanup -Sql "IF (SELECT COUNT(*) FROM cdc.change_tables) <> 1 OR NOT EXISTS (SELECT 1 FROM cdc.change_tables WHERE capture_instance=N'dbo_stuff_5') THROW 52000, 'Removing a CSV row did not drop the omitted instance.', 1;" | Out-Null
    Complete-Test 'Removing a row removes its capture instance on the next deployment'

    $emptyCsv = Join-Path $outputDirectory 'empty.csv'
    $emptySqlPath = Join-Path $outputDirectory 'empty.sql'
    [IO.File]::WriteAllText($emptyCsv, "SourceSchema,SourceName,CaptureInstanceName`n")
    & (Join-Path $repoRoot 'New-CdcConfigurationScript.ps1') -CsvPath $emptyCsv -OutputPath $emptySqlPath -DropUnlistedCaptureInstances | Out-Null
    $emptySql = [IO.File]::ReadAllText($emptySqlPath)
    Invoke-TestSql -Database CdcCleanup -Sql $emptySql | Out-Null
    Invoke-TestSql -Database CdcCleanup -Sql $emptySql | Out-Null
    Invoke-TestSql -Database CdcCleanup -Sql @'
IF EXISTS (SELECT 1 FROM cdc.change_tables)
   OR NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id=DB_ID() AND is_cdc_enabled=1)
   OR OBJECT_ID(N'dbo.Stuff', N'U') IS NULL
    THROW 52000, 'Empty desired configuration must remove instances while retaining database CDC and source tables.', 1;
'@ | Out-Null
    Complete-Test 'Header-only cleanup removes all instances and is repeatable without disabling database CDC'

    Invoke-TestSql -Database CdcCleanup -Sql @'
EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'Stuff', @role_name=NULL, @capture_instance=N'all', @supports_net_changes=0;
EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'Stuff', @role_name=NULL, @capture_instance=N'all_keep', @supports_net_changes=0;
'@ | Out-Null
    $reservedSql = New-TestManifestSql -Name reserved-all -Rows @((New-TestRow Stuff all_keep)) -DropUnlistedCaptureInstances
    $before = Get-CaptureSnapshot -Database CdcCleanup
    Invoke-TestSql -Database CdcCleanup -Sql $reservedSql -ExpectedError 51006 | Out-Null
    Assert-Unchanged $before -Database CdcCleanup
    Invoke-TestSql -Database CdcCleanup -Sql $emptySql | Out-Null
    Invoke-TestSql -Database CdcCleanup -Sql "IF EXISTS (SELECT 1 FROM cdc.change_tables) THROW 52000, 'Header-only cleanup failed with a reserved-name instance.', 1;" | Out-Null
    Complete-Test 'Reserved all instance cannot accidentally remove a retained instance'

    foreach ($case in @(
        @{ Database = 'CdcReservedCS'; Collation = 'Latin1_General_100_CS_AS'; Capture = 'ALL' },
        @{ Database = 'CdcReservedAI'; Collation = 'Latin1_General_100_CI_AI'; Capture = 'áll' }
    )) {
        Invoke-TestSql -Sql "CREATE DATABASE $($case.Database) COLLATE $($case.Collation);" | Out-Null
        Invoke-TestSql -Database $case.Database -Sql @"
CREATE TABLE dbo.Probe (id int PRIMARY KEY);
EXEC sys.sp_cdc_enable_db;
EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'Probe', @role_name=NULL, @capture_instance=N'$($case.Capture)', @supports_net_changes=0;
EXEC sys.sp_cdc_enable_table @source_schema=N'dbo', @source_name=N'Probe', @role_name=NULL, @capture_instance=N'keep_case', @supports_net_changes=0;
"@ | Out-Null
        $retainedBefore = Invoke-TestSql -Database $case.Database -Sql "SELECT object_id, CONVERT(varchar(33), create_date, 126) FROM cdc.change_tables WHERE capture_instance=N'keep_case';"
        $caseCleanupSql = New-TestManifestSql -Name $case.Database -Rows @((New-TestRow Probe keep_case)) -DropUnlistedCaptureInstances
        $probeSql = @"
BEGIN TRY
$caseCleanupSql
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() <> 51006 THROW;
END CATCH;
"@
        Invoke-TestSql -Database $case.Database -Sql $probeSql | Out-Null
        $retainedAfter = Invoke-TestSql -Database $case.Database -Sql "SELECT object_id, CONVERT(varchar(33), create_date, 126) FROM cdc.change_tables WHERE capture_instance=N'keep_case';"
        if ($retainedAfter -cne $retainedBefore) { throw 'A selector variant removed and recreated a retained instance.' }
        Invoke-TestSql -Database $case.Database -Sql $emptySql | Out-Null
        Invoke-TestSql -Database $case.Database -Sql "IF EXISTS (SELECT 1 FROM cdc.change_tables) THROW 52000, 'Selector-variant cleanup left unlisted instances.', 1;" | Out-Null
    }
    Complete-Test 'Case and accent selector variants preserve retained captures and fully clean an empty desired set'

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
    $env:MSSQL_SA_PASSWORD = $savedSaPassword
    $env:SQLCMDPASSWORD = $savedSqlcmdPassword
}
