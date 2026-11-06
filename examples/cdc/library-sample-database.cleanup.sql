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

-- Validate every configured table and capture-instance name before making changes.
IF EXISTS ( SELECT 1 FROM
            (VALUES
                (N'dbo', N'loans', N'library_loans'),
                (N'dbo', N'fines', N'library_fines'),
                (N'dbo', N'audit_logs', N'library_audit_logs')
            ) AS requested(source_schema, source_name, capture_instance)
            GROUP BY requested.capture_instance
            HAVING COUNT(*) > 1
          )
BEGIN
    THROW 51004, N'The CSV configuration used to generate this script contains multiple capture instances with the same name. Capture instances must be unique under the target database collation.', 1;
END;
IF EXISTS ( SELECT 1 FROM
            (VALUES
                (N'dbo', N'loans', N'library_loans'),
                (N'dbo', N'fines', N'library_fines'),
                (N'dbo', N'audit_logs', N'library_audit_logs')
            ) AS requested(source_schema, source_name, capture_instance)
            WHERE OBJECT_ID(QUOTENAME(requested.source_schema) + N'.' + QUOTENAME(requested.source_name), N'U') IS NOT NULL
            GROUP BY OBJECT_ID(QUOTENAME(requested.source_schema) + N'.' + QUOTENAME(requested.source_name), N'U')
            HAVING COUNT(*) > 2
          )
BEGIN
    THROW 51003, N'The requested CDC configuration exceeds the maximum of two capture instances for a source table.', 1;
END;
IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'loans'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.loans', 1;
END;

IF EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
            WHERE ct.capture_instance = N'library_loans'
              AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'loans'), N'U')
          )
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: library_loans', 1;
END;

IF EXISTS ( SELECT 1 FROM sys.tables AS t
            WHERE t.object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'loans'), N'U')
              AND (t.schema_id = SCHEMA_ID(N'cdc') OR t.is_ms_shipped = 1)
          )
BEGIN
    THROW 51007, N'The CSV configuration specifies a source table that cannot be enabled for CDC: dbo.loans. CDC-schema and system tables are not supported.', 1;
END;
IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'fines'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.fines', 1;
END;

IF EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
            WHERE ct.capture_instance = N'library_fines'
              AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'fines'), N'U')
          )
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: library_fines', 1;
END;

IF EXISTS ( SELECT 1 FROM sys.tables AS t
            WHERE t.object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'fines'), N'U')
              AND (t.schema_id = SCHEMA_ID(N'cdc') OR t.is_ms_shipped = 1)
          )
BEGIN
    THROW 51007, N'The CSV configuration specifies a source table that cannot be enabled for CDC: dbo.fines. CDC-schema and system tables are not supported.', 1;
END;
IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'audit_logs'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.audit_logs', 1;
END;

IF EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
            WHERE ct.capture_instance = N'library_audit_logs'
              AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'audit_logs'), N'U')
          )
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: library_audit_logs', 1;
END;

IF EXISTS ( SELECT 1 FROM sys.tables AS t
            WHERE t.object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'audit_logs'), N'U')
              AND (t.schema_id = SCHEMA_ID(N'cdc') OR t.is_ms_shipped = 1)
          )
BEGIN
    THROW 51007, N'The CSV configuration specifies a source table that cannot be enabled for CDC: dbo.audit_logs. CDC-schema and system tables are not supported.', 1;
END;

-- Disable database capture instances absent from the CSV before creating replacements.
-- Disabling an instance deletes its change table and captured history.
DECLARE @cdc_source_schema sysname,
        @cdc_source_name sysname,
        @cdc_capture_instance sysname,
        @cdc_disable_result int;

DECLARE @cdc_unlisted_instances TABLE
(
    source_object_id int NOT NULL,
    source_schema sysname NOT NULL,
    source_name sysname NOT NULL,
    capture_instance sysname NOT NULL
);

INSERT INTO @cdc_unlisted_instances (source_object_id, source_schema, source_name, capture_instance)
    SELECT ct.source_object_id, s.name, t.name, ct.capture_instance
    FROM cdc.change_tables AS ct
    JOIN sys.tables AS t ON t.object_id = ct.source_object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE NOT EXISTS ( SELECT 1 FROM
                       (VALUES
                            (N'library_loans'),
                            (N'library_fines'),
                            (N'library_audit_logs')
                       ) AS configured(capture_instance)
                       WHERE configured.capture_instance = ct.capture_instance
                     );

-- SQL Server interprets 'all' as every instance on a table, not one instance.
IF EXISTS ( SELECT 1 FROM @cdc_unlisted_instances AS unlisted
            WHERE LOWER(unlisted.capture_instance) = N'all'
              AND EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                           WHERE ct.source_object_id = unlisted.source_object_id
                             AND NOT EXISTS ( SELECT 1 FROM @cdc_unlisted_instances AS pending
                                              WHERE pending.capture_instance = ct.capture_instance
                                            )
                         )
          )
BEGIN
    THROW 51006, N'Cannot safely remove a capture instance matching ''all'' while retaining another instance on its table. SQL Server uses ''all'' as a table-wide selector. Retain it in the CSV or remove every instance for its table.', 1;
END;

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

    DELETE pending
    FROM @cdc_unlisted_instances AS pending
    WHERE NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                       WHERE ct.source_object_id = pending.source_object_id
                         AND ct.capture_instance = pending.capture_instance
                     );
    IF @@ROWCOUNT = 0
        THROW 51005, N'CDC cleanup did not remove the requested capture instance. Stopping before enabling new instances.', 1;
END;

-- Enable only missing capture instances.
IF NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                WHERE ct.capture_instance = N'library_loans'
                  AND ct.source_object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'loans'), N'U')
              )
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'loans',
        @role_name = NULL,
        @capture_instance = N'library_loans',
        @supports_net_changes = 0;
END;
IF NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                WHERE ct.capture_instance = N'library_fines'
                  AND ct.source_object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'fines'), N'U')
              )
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'fines',
        @role_name = NULL,
        @capture_instance = N'library_fines',
        @supports_net_changes = 0;
END;
IF NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                WHERE ct.capture_instance = N'library_audit_logs'
                  AND ct.source_object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'audit_logs'), N'U')
              )
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'audit_logs',
        @role_name = NULL,
        @capture_instance = N'library_audit_logs',
        @supports_net_changes = 0;
END;