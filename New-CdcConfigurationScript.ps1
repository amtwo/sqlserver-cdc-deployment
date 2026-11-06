<#
.SYNOPSIS
Generates an idempotent SQL Server CDC table-configuration script from CSV.

.DESCRIPTION
Reads one source table and capture instance name per CSV row, then writes a
T-SQL script suitable for inclusion in a SQL project's post-deployment script.
The generated script requires CDC to already be enabled in the target database.
It never enables CDC at the database level.

The generated T-SQL checks the current database before making any CDC changes,
validates all configured tables and existing capture-instance conflicts before
the first change, and skips capture instances that are already configured.

.PARAMETER CsvPath
Path to a CSV file with SourceSchema, SourceName, and CaptureInstanceName columns.

.PARAMETER OutputPath
Path to the generated T-SQL file. The parent directory must already exist.

.PARAMETER DropUnlistedCaptureInstances
Include database-wide cleanup that disables capture instances absent from the
CSV before enabling missing instances. Disabling an instance deletes its change
table and captured history. The CSV is the complete desired configuration;
a valid header-only CSV removes all capture instances in this mode.

.EXAMPLE
./New-CdcConfigurationScript.ps1 `
    -CsvPath ./cdc/tables.csv `
    -OutputPath ./obj/cdc-configuration.sql

.NOTES
The CSV column names map to the source schema, source table, and capture
instance parameters accepted by sys.sp_cdc_enable_table. The generated script
uses @role_name = NULL and @supports_net_changes = 0.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [switch]$DropUnlistedCaptureInstances
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SqlUnicodeLiteral {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "N'$( $Value.Replace("'", "''") )'"
}

$resolvedCsvPath = (Resolve-Path -LiteralPath $CsvPath).Path
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutputPath)

if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}

if ([string]::Equals(
        $resolvedCsvPath,
        $resolvedOutputPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'CsvPath and OutputPath must refer to different files.'
}

$rows = @(Import-Csv -LiteralPath $resolvedCsvPath)
if ($rows.Count -eq 0 -and -not $DropUnlistedCaptureInstances) {
    throw "CSV contains no data rows: $resolvedCsvPath"
}

$requiredColumns = @('SourceSchema', 'SourceName', 'CaptureInstanceName')
if ($rows.Count -eq 0) {
    # Import-Csv returns no objects for a header-only manifest. Parse a dummy
    # row solely to inspect its headers; never treat that row as configuration.
    $csvText = [IO.File]::ReadAllText($resolvedCsvPath)
    if ([string]::IsNullOrWhiteSpace($csvText)) {
        throw 'CSV must contain the SourceSchema, SourceName, and CaptureInstanceName header, even when no capture instances are desired.'
    }
    $headerProbe = @(ConvertFrom-Csv -InputObject ($csvText + "`n__cdc_header_probe__"))
    $actualColumns = if ($headerProbe.Count -eq 1) { @($headerProbe[0].PSObject.Properties.Name) } else { @() }
}
else {
    $actualColumns = @($rows[0].PSObject.Properties.Name)
}
foreach ($column in $requiredColumns) {
    if ($column -notin $actualColumns) {
        throw "CSV is missing required column '$column'. Required columns: $($requiredColumns -join ', ')."
    }
}

$seenRows = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$seenCaptureInstances = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$entries = [System.Collections.Generic.List[object]]::new()

foreach ($row in $rows) {
    $sourceSchema = ([string]$row.SourceSchema).Trim()
    $sourceName = ([string]$row.SourceName).Trim()
    $captureInstanceName = ([string]$row.CaptureInstanceName).Trim()

    if ([string]::IsNullOrWhiteSpace($sourceSchema) -or
        [string]::IsNullOrWhiteSpace($sourceName) -or
        [string]::IsNullOrWhiteSpace($captureInstanceName)) {
        throw 'CSV values SourceSchema, SourceName, and CaptureInstanceName must not be empty.'
    }

    if ($sourceSchema.Length -gt 128 -or $sourceName.Length -gt 128) {
        throw "SourceSchema and SourceName must each be at most 128 characters: $sourceSchema.$sourceName"
    }

    if ($captureInstanceName.Length -gt 100) {
        throw "CaptureInstanceName must be at most 100 characters: $captureInstanceName"
    }

    $rowKey = "$sourceSchema`0$sourceName`0$captureInstanceName"
    if (-not $seenRows.Add($rowKey)) {
        throw "Duplicate CDC configuration row: $sourceSchema.$sourceName / $captureInstanceName"
    }

    if (-not $seenCaptureInstances.Add($captureInstanceName)) {
        throw "CaptureInstanceName must be unique in the CSV: $captureInstanceName"
    }

    $entries.Add([pscustomobject]@{
        SourceSchema        = $sourceSchema
        SourceName          = $sourceName
        CaptureInstanceName = $captureInstanceName
    })
}

$preflight = [System.Collections.Generic.List[string]]::new()
$enableStatements = [System.Collections.Generic.List[string]]::new()

# Resolve requested tables inside SQL Server so the capacity check follows
# the target database's identifier collation and actual table identities.
$requestedConfigurationRows = @($entries | ForEach-Object {
    $schemaLiteral = ConvertTo-SqlUnicodeLiteral $_.SourceSchema
    $sourceLiteral = ConvertTo-SqlUnicodeLiteral $_.SourceName
    $captureLiteral = ConvertTo-SqlUnicodeLiteral $_.CaptureInstanceName
    "($schemaLiteral, $sourceLiteral, $captureLiteral)"
})
$requestedConfigurations = $requestedConfigurationRows -join ",`n                "
$capacityConfigurations = $requestedConfigurationRows -join ",`n                        "
$capacityErrorLiteral = ConvertTo-SqlUnicodeLiteral 'The requested CDC configuration exceeds the maximum of two capture instances for a source table.'

if ($entries.Count -gt 0) {
    $preflight.Add(@"
IF EXISTS ( SELECT 1 FROM
            (VALUES
                $requestedConfigurations
            ) AS requested(source_schema, source_name, capture_instance)
            GROUP BY requested.capture_instance
            HAVING COUNT(*) > 1
          )
BEGIN
    THROW 51004, N'The CSV configuration used to generate this script contains multiple capture instances with the same name. Capture instances must be unique under the target database collation.', 1;
END;
"@)

if ($DropUnlistedCaptureInstances) {
    # Old, unlisted instances will be removed before enabling replacements.
    # Validate the desired count rather than counting the slots they occupy.
    $preflight.Add(@"
IF EXISTS ( SELECT 1 FROM
            (VALUES
                $requestedConfigurations
            ) AS requested(source_schema, source_name, capture_instance)
            WHERE OBJECT_ID(QUOTENAME(requested.source_schema) + N'.' + QUOTENAME(requested.source_name), N'U') IS NOT NULL
            GROUP BY OBJECT_ID(QUOTENAME(requested.source_schema) + N'.' + QUOTENAME(requested.source_name), N'U')
            HAVING COUNT(*) > 2
          )
BEGIN
    THROW 51003, $capacityErrorLiteral, 1;
END;
"@)
}
else {
    $preflight.Add(@"
IF EXISTS ( SELECT 1 FROM
            (
                SELECT requested.source_object_id,
                       SUM(CASE WHEN existing.object_id IS NULL THEN 1 ELSE 0 END) AS missing_instance_count
                FROM
                (
                    SELECT OBJECT_ID(QUOTENAME(requestedInput.source_schema) + N'.' + QUOTENAME(requestedInput.source_name), N'U') AS source_object_id,
                           requestedInput.capture_instance
                    FROM (VALUES
                        $capacityConfigurations
                    ) AS requestedInput(source_schema, source_name, capture_instance)
                ) AS requested
                LEFT JOIN cdc.change_tables AS existing
                    ON existing.source_object_id = requested.source_object_id
                   AND existing.capture_instance = requested.capture_instance
                WHERE requested.source_object_id IS NOT NULL
                GROUP BY requested.source_object_id
            ) AS planned
            WHERE ( SELECT COUNT(*) FROM cdc.change_tables AS ct
                    WHERE ct.source_object_id = planned.source_object_id
                  ) + planned.missing_instance_count > 2
          )
BEGIN
    THROW 51003, $capacityErrorLiteral, 1;
END;
"@)
}
}

foreach ($entry in $entries) {
    $schemaLiteral = ConvertTo-SqlUnicodeLiteral $entry.SourceSchema
    $sourceLiteral = ConvertTo-SqlUnicodeLiteral $entry.SourceName
    $captureLiteral = ConvertTo-SqlUnicodeLiteral $entry.CaptureInstanceName
    $qualifiedExpression = "QUOTENAME($schemaLiteral) + N'.' + QUOTENAME($sourceLiteral)"
    $sourceErrorMessageLiteral = ConvertTo-SqlUnicodeLiteral "CDC configuration source table does not exist: $($entry.SourceSchema).$($entry.SourceName)"
    $captureErrorMessageLiteral = ConvertTo-SqlUnicodeLiteral "CDC capture instance name is already assigned to another table: $($entry.CaptureInstanceName)"

    $preflight.Add(@"
IF OBJECT_ID($qualifiedExpression, N'U') IS NULL
BEGIN
    THROW 51001, $sourceErrorMessageLiteral, 1;
END;

IF EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
            WHERE ct.capture_instance = $captureLiteral
              AND ct.source_object_id <> OBJECT_ID($qualifiedExpression, N'U')
          )
BEGIN
    THROW 51002, $captureErrorMessageLiteral, 1;
END;

"@)

    $enableStatements.Add(@"
IF NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                WHERE ct.capture_instance = $captureLiteral
                  AND ct.source_object_id = OBJECT_ID($qualifiedExpression, N'U')
              )
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = $schemaLiteral,
        @source_name = $sourceLiteral,
        @role_name = NULL,
        @capture_instance = $captureLiteral,
        @supports_net_changes = 0;
END;
"@)
}

$cleanupBody = ''
if ($DropUnlistedCaptureInstances) {
    $cleanupPredicate = ''
    if ($entries.Count -gt 0) {
        $requestedCaptureInstances = ($entries | ForEach-Object {
            "($(ConvertTo-SqlUnicodeLiteral $_.CaptureInstanceName))"
        }) -join ",`n                            "
        $cleanupPredicate = @"
    WHERE NOT EXISTS ( SELECT 1 FROM
                       (VALUES
                            $requestedCaptureInstances
                       ) AS configured(capture_instance)
                       WHERE configured.capture_instance = ct.capture_instance
                     )
"@
        $cleanupPredicate = "`n" + $cleanupPredicate
    }
    $cleanupBody = @"
-- Disable database capture instances absent from the CSV before creating replacements.
-- Disabling an instance deletes its change table and captured history.
DECLARE @cdc_source_schema sysname,
        @cdc_source_name sysname,
        @cdc_capture_instance sysname,
        @cdc_disable_result int;

DECLARE @cdc_unlisted_instances TABLE
(
    source_schema sysname NOT NULL,
    source_name sysname NOT NULL,
    capture_instance sysname NOT NULL
);

INSERT INTO @cdc_unlisted_instances (source_schema, source_name, capture_instance)
    SELECT s.name, t.name, ct.capture_instance
    FROM cdc.change_tables AS ct
    JOIN sys.tables AS t ON t.object_id = ct.source_object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id$cleanupPredicate;

WHILE EXISTS ( SELECT 1 FROM @cdc_unlisted_instances )
BEGIN
    SELECT TOP (1)
        @cdc_source_schema = source_schema,
        @cdc_source_name = source_name,
        @cdc_capture_instance = capture_instance
    FROM @cdc_unlisted_instances
    ORDER BY capture_instance;

    EXEC @cdc_disable_result = sys.sp_cdc_disable_table
        @source_schema = @cdc_source_schema,
        @source_name = @cdc_source_name,
        @capture_instance = @cdc_capture_instance;
    IF @cdc_disable_result <> 0
        THROW 51005, N'Failed to disable an unlisted CDC capture instance. Stopping before enabling new instances.', 1;

    DELETE FROM @cdc_unlisted_instances
    WHERE capture_instance = @cdc_capture_instance;
END;
"@
    $cleanupBody += "`n`n"
}

$configurationBody = @"
-- Validate every configured table and capture-instance name before making changes.
$($preflight -join "`n")

$($cleanupBody)-- Enable only missing capture instances.
$($enableStatements -join "`n")
"@

$sql = @"
/*
Generated CDC table configuration.
This script intentionally does not enable CDC for the database.
*/
SET NOCOUNT ON;

IF NOT EXISTS ( SELECT 1 FROM sys.databases AS d
                WHERE d.name = DB_NAME()
                  AND d.is_cdc_enabled = 1
              )
BEGIN
    THROW 51000, N'CDC is not enabled for the current database. Refusing to configure capture instances; verify the deployment target.', 1;
END;

$configurationBody
"@

[System.IO.File]::WriteAllText(
    $resolvedOutputPath,
    $sql,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Output $resolvedOutputPath
