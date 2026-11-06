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
                (N'dbo', N'orders', N'restaurant_orders'),
                (N'dbo', N'order_items', N'restaurant_order_items'),
                (N'dbo', N'payments', N'restaurant_payments')
            ) AS requested(source_schema, source_name, capture_instance)
            GROUP BY requested.capture_instance
            HAVING COUNT(*) > 1
          )
BEGIN
    THROW 51004, N'The CSV configuration used to generate this script contains multiple capture instances with the same name. Capture instances must be unique under the target database collation.', 1;
END;
IF EXISTS ( SELECT 1 FROM
            (VALUES
                (N'dbo', N'orders', N'restaurant_orders'),
                (N'dbo', N'order_items', N'restaurant_order_items'),
                (N'dbo', N'payments', N'restaurant_payments')
            ) AS requested(source_schema, source_name, capture_instance)
            WHERE OBJECT_ID(QUOTENAME(requested.source_schema) + N'.' + QUOTENAME(requested.source_name), N'U') IS NOT NULL
            GROUP BY OBJECT_ID(QUOTENAME(requested.source_schema) + N'.' + QUOTENAME(requested.source_name), N'U')
            HAVING COUNT(*) > 2
          )
BEGIN
    THROW 51003, N'The requested CDC configuration exceeds the maximum of two capture instances for a source table.', 1;
END;
IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'orders'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.orders', 1;
END;

IF EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
            WHERE ct.capture_instance = N'restaurant_orders'
              AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'orders'), N'U')
          )
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: restaurant_orders', 1;
END;

IF EXISTS ( SELECT 1 FROM sys.tables AS t
            WHERE t.object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'orders'), N'U')
              AND (t.schema_id = SCHEMA_ID(N'cdc') OR t.is_ms_shipped = 1)
          )
BEGIN
    THROW 51007, N'The CSV configuration specifies a source table that cannot be enabled for CDC: dbo.orders. CDC-schema and system tables are not supported.', 1;
END;
IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'order_items'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.order_items', 1;
END;

IF EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
            WHERE ct.capture_instance = N'restaurant_order_items'
              AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'order_items'), N'U')
          )
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: restaurant_order_items', 1;
END;

IF EXISTS ( SELECT 1 FROM sys.tables AS t
            WHERE t.object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'order_items'), N'U')
              AND (t.schema_id = SCHEMA_ID(N'cdc') OR t.is_ms_shipped = 1)
          )
BEGIN
    THROW 51007, N'The CSV configuration specifies a source table that cannot be enabled for CDC: dbo.order_items. CDC-schema and system tables are not supported.', 1;
END;
IF OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'payments'), N'U') IS NULL
BEGIN
    THROW 51001, N'CDC configuration source table does not exist: dbo.payments', 1;
END;

IF EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
            WHERE ct.capture_instance = N'restaurant_payments'
              AND ct.source_object_id <> OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'payments'), N'U')
          )
BEGIN
    THROW 51002, N'CDC capture instance name is already assigned to another table: restaurant_payments', 1;
END;

IF EXISTS ( SELECT 1 FROM sys.tables AS t
            WHERE t.object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'payments'), N'U')
              AND (t.schema_id = SCHEMA_ID(N'cdc') OR t.is_ms_shipped = 1)
          )
BEGIN
    THROW 51007, N'The CSV configuration specifies a source table that cannot be enabled for CDC: dbo.payments. CDC-schema and system tables are not supported.', 1;
END;

-- Disable database capture instances absent from the CSV before creating replacements.
-- Disabling an instance deletes its change table and captured history.
DECLARE @cdc_source_schema sysname,
        @cdc_source_name sysname,
        @cdc_capture_instance sysname,
        @cdc_source_object_id int,
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
                            (N'restaurant_orders'),
                            (N'restaurant_order_items'),
                            (N'restaurant_payments')
                       ) AS configured(capture_instance)
                       WHERE configured.capture_instance = ct.capture_instance
                     );

-- SQL Server interprets 'all' as every instance on a table, not one instance.
IF EXISTS ( SELECT 1 FROM @cdc_unlisted_instances AS unlisted
            WHERE unlisted.capture_instance = N'all'
              AND EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                           WHERE ct.source_object_id = unlisted.source_object_id
                             AND NOT EXISTS ( SELECT 1 FROM @cdc_unlisted_instances AS pending
                                              WHERE pending.capture_instance = ct.capture_instance
                                            )
                         )
          )
BEGIN
    THROW 51006, N'Cannot safely remove a capture instance named ''all'' while retaining another instance on its table. SQL Server treats ''all'' as every instance on that table. Retain it in the CSV or remove every instance for its table.', 1;
END;

WHILE EXISTS ( SELECT 1 FROM @cdc_unlisted_instances )
BEGIN
    SELECT TOP (1)
        @cdc_source_schema = source_schema,
        @cdc_source_name = source_name,
        @cdc_capture_instance = capture_instance,
        @cdc_source_object_id = source_object_id
    FROM @cdc_unlisted_instances
    ORDER BY capture_instance;

    EXEC @cdc_disable_result = sys.sp_cdc_disable_table
        @source_schema = @cdc_source_schema,
        @source_name = @cdc_source_name,
        @capture_instance = @cdc_capture_instance;
    IF @cdc_disable_result <> 0
        THROW 51005, N'Failed to disable an unlisted CDC capture instance. Stopping before enabling new instances.', 1;

    DELETE FROM @cdc_unlisted_instances
    WHERE capture_instance = @cdc_capture_instance
       OR (@cdc_capture_instance = N'all' AND source_object_id = @cdc_source_object_id);
END;

-- Enable only missing capture instances.
IF NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                WHERE ct.capture_instance = N'restaurant_orders'
                  AND ct.source_object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'orders'), N'U')
              )
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'orders',
        @role_name = NULL,
        @capture_instance = N'restaurant_orders',
        @supports_net_changes = 0;
END;
IF NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                WHERE ct.capture_instance = N'restaurant_order_items'
                  AND ct.source_object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'order_items'), N'U')
              )
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'order_items',
        @role_name = NULL,
        @capture_instance = N'restaurant_order_items',
        @supports_net_changes = 0;
END;
IF NOT EXISTS ( SELECT 1 FROM cdc.change_tables AS ct
                WHERE ct.capture_instance = N'restaurant_payments'
                  AND ct.source_object_id = OBJECT_ID(QUOTENAME(N'dbo') + N'.' + QUOTENAME(N'payments'), N'U')
              )
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'payments',
        @role_name = NULL,
        @capture_instance = N'restaurant_payments',
        @supports_net_changes = 0;
END;