<#
.SYNOPSIS
Exports the current CDC capture-instance configuration from a SQL Server database to CSV.

.DESCRIPTION
Reads source schema, source table, and capture-instance names from CDC metadata and writes a
manifest compatible with New-CdcConfigurationScript.ps1. The database is queried read-only.
Database-level CDC must already be enabled. A database with no table-level capture instances
is rejected because the deployment generator requires at least one manifest row.

.PARAMETER ServerInstance
SQL Server instance name, optionally including a TCP port such as localhost,1433.

.PARAMETER Database
Name of the CDC-enabled database to inspect.

.PARAMETER OutputPath
Path to the CSV file. Its parent directory must already exist.

.PARAMETER Credential
Optional SQL Server credential. When omitted, the connection uses Windows integrated
authentication where supported by the host and server.

.PARAMETER TrustServerCertificate
Trust the server certificate while keeping the connection encrypted. Use this for local
development instances that do not have a certificate trusted by the client.

.EXAMPLE
./Export-CdcConfigurationCsv.ps1 `
    -ServerInstance 'sql01,1433' `
    -Database 'Library' `
    -OutputPath ./cdc/tables.csv

.EXAMPLE
$credential = Get-Credential
./Export-CdcConfigurationCsv.ps1 `
    -ServerInstance 'localhost,1433' `
    -Database 'Library' `
    -OutputPath ./cdc/tables.csv `
    -Credential $credential `
    -TrustServerCertificate
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerInstance,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Database,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$TrustServerCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-CsvField {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return '"' + $Value.Replace('"', '""') + '"'
}

$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}

$connectionStringBuilder = [System.Data.Common.DbConnectionStringBuilder]::new()
$connectionStringBuilder['Data Source'] = $ServerInstance
$connectionStringBuilder['Initial Catalog'] = $Database
$connectionStringBuilder['Application Name'] = 'SQL Server CDC Configuration CSV Export'
$connectionStringBuilder['Connect Timeout'] = 15
$connectionStringBuilder['Encrypt'] = $true
$connectionStringBuilder['Trust Server Certificate'] = $TrustServerCertificate.IsPresent
$connectionStringBuilder['Persist Security Info'] = $false

if ($null -ne $Credential) {
    $connectionStringBuilder['Integrated Security'] = $false
    $connectionStringBuilder['User ID'] = $Credential.UserName
    $connectionStringBuilder['Password'] = $Credential.GetNetworkCredential().Password
}
else {
    $connectionStringBuilder['Integrated Security'] = $true
}

$connection = [System.Data.SqlClient.SqlConnection]::new($connectionStringBuilder.ConnectionString)
$rows = [System.Collections.Generic.List[object]]::new()

try {
    $connection.Open()

    $cdcEnabledCommand = $connection.CreateCommand()
    $cdcEnabledCommand.CommandText = @'
SELECT d.is_cdc_enabled
FROM sys.databases AS d
WHERE d.database_id = DB_ID();
'@
    $cdcEnabledCommand.CommandTimeout = 15
    $cdcEnabled = $cdcEnabledCommand.ExecuteScalar()
    $cdcEnabledCommand.Dispose()

    if ($null -eq $cdcEnabled -or [System.DBNull]::Value.Equals($cdcEnabled) -or -not [bool]$cdcEnabled) {
        throw "CDC is not enabled for database '$Database'. No CSV was written."
    }

    $captureInstancesCommand = $connection.CreateCommand()
    $captureInstancesCommand.CommandText = @'
SELECT ct.source_object_id,
       s.name AS SourceSchema,
       t.name AS SourceName,
       ct.capture_instance AS CaptureInstanceName
FROM cdc.change_tables AS ct
LEFT JOIN sys.tables AS t
    ON t.object_id = ct.source_object_id
LEFT JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
ORDER BY s.name,
         t.name,
         ct.capture_instance;
'@
    $captureInstancesCommand.CommandTimeout = 30
    $reader = $captureInstancesCommand.ExecuteReader()
    try {
        while ($reader.Read()) {
            if ($reader.IsDBNull(1) -or $reader.IsDBNull(2) -or $reader.IsDBNull(3)) {
                throw "CDC metadata references source object id $($reader.GetInt32(0)) without a resolvable schema, table, and capture-instance name. No CSV was written."
            }

            $rows.Add([pscustomobject]@{
                SourceSchema        = $reader.GetString(1)
                SourceName          = $reader.GetString(2)
                CaptureInstanceName = $reader.GetString(3)
            })
        }
    }
    finally {
        $reader.Dispose()
        $captureInstancesCommand.Dispose()
    }
}
finally {
    $connection.Dispose()
}

if ($rows.Count -eq 0) {
    throw "No table-level CDC capture instances were found in database '$Database'. No CSV was written."
}

$csvLines = [System.Collections.Generic.List[string]]::new()
$csvLines.Add('"SourceSchema","SourceName","CaptureInstanceName"')
foreach ($row in $rows) {
    $csvLines.Add((@(
        (ConvertTo-CsvField $row.SourceSchema),
        (ConvertTo-CsvField $row.SourceName),
        (ConvertTo-CsvField $row.CaptureInstanceName)
    ) -join ','))
}

[System.IO.File]::WriteAllText(
    $resolvedOutputPath,
    (($csvLines -join "`n") + "`n"),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Output $resolvedOutputPath
