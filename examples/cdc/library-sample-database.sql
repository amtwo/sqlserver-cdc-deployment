/*
Generated CDC table configuration.
This script intentionally does not enable CDC for the database.
*/
SET NOCOUNT ON;

IF NOT EXISTS
(
    SELECT 1
    FROM sys.databases AS d
    WHERE d.name = DB_NAME()
      AND d.is_cdc_enabled = 1
)
BEGIN
    THROW 51000, N'CDC is not enabled for the current database. Refusing to configure capture instances; verify the deployment target.', 1;
END;

-- Validate every configured table and capture-instance name before making changes.
IF EXISTS
(
    SELECT 1
    FROM (VALUES
                (N'dbo', N'loans', N'library_loans'),
                (N'dbo', N'fines', N'library_fines'),
                (N'dbo', N'audit_logs', N'library_audit_logs')
    ) AS requested(source_schema, source_name, capture_instance)
    GROUP BY requested.capture_instance
    HAVING COUNT(*) > 1
)
BEGIN
    THROW 51004, N'Capture instance names must be unique under the target database collation.', 1;
END;
IF EXISTS
(
    SELECT 1
    FROM
    (
        SELECT requested.source_object_id,
               SUM(CASE WHEN existing.object_id IS NULL THEN 1 ELSE 0 END) AS missing_instance_count
        FROM
        (
            SELECT OBJECT_ID(QUOTENAME(requestedInput.source_schema) + N'.' + QUOTENAME(requestedInput.source_name), N'U') AS source_object_id,
                   requestedInput.capture_instance
            FROM (VALUES
                (N'dbo', N'loans', N'library_loans'),
                (N'dbo', N'fines', N'library_fines'),
                (N'dbo', N'audit_logs', N'library_audit_logs')
            ) AS requestedInput(source_schema, source_name, capture_instance)
        ) AS requested
        LEFT JOIN cdc.change_tables AS existing
            ON existing.source_object_id = requested.source_object_id
           AND existing.capture_instance = requested.capture_instance
        WHERE requested.source_object_id IS NOT NULL
        GROUP BY requested.source_object_id
    ) AS planned
    WHERE
    (
        SELECT COUNT(*)
        FROM cdc.change_tables AS ct
        WHERE ct.source_object_id = planned.source_object_id
    ) + planned.missing_instance_count > 2
)
BEGIN
    THROW 51003, N'The requested CDC configuration exceeds the maximum of two capture instances for a source table.', 1;
END;
IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'loans'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.loans', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM cdc.change_tables AS ct
    WHERE ct.capture_instance = N'library_loans'
      AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'loans'), N'U')
)
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: library_loans', 1;
END;

IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'fines'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.fines', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM cdc.change_tables AS ct
    WHERE ct.capture_instance = N'library_fines'
      AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'fines'), N'U')
)
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: library_fines', 1;
END;

IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'audit_logs'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.audit_logs', 1;
END;

IF EXISTS
(
    SELECT 1
    FROM cdc.change_tables AS ct
    WHERE ct.capture_instance = N'library_audit_logs'
      AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'audit_logs'), N'U')
)
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: library_audit_logs', 1;
END;


-- Enable only missing capture instances.
IF NOT EXISTS
(
    SELECT 1
    FROM cdc.change_tables AS ct
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
IF NOT EXISTS
(
    SELECT 1
    FROM cdc.change_tables AS ct
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
IF NOT EXISTS
(
    SELECT 1
    FROM cdc.change_tables AS ct
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