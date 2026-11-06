# SQL Server CDC Deployment

Generate an idempotent SQL script from a CSV manifest of source tables and capture instance names, then include that script in a SQL project's post-deployment script. The generated SQL configures table capture instances only; it never enables CDC for a database.

## Requirements

- PowerShell 7 (`pwsh`), the development and primary execution target
- A SQL Server database that already has CDC enabled
- Source tables created by the schema deployment before the post-deployment script runs

Windows PowerShell compatibility is recorded when tested, with the version and checks that passed. Development and required validation use PowerShell 7.

If database-level CDC is not enabled, the generated script throws before it reads CDC metadata or attempts any change. It does not run `sys.sp_cdc_enable_db`. Treat that error as a target/configuration mismatch and verify the deployment database.

## CSV manifest

Create a CSV with exactly these required columns:

```csv
SourceSchema,SourceName,CaptureInstanceName
dbo,orders,orders_capture
sales,Invoice,invoice_capture
```

The source schema and table identify the table passed to `sys.sp_cdc_enable_table`; the capture instance is the desired name. Each capture instance name must be unique in the manifest. SQL Server permits at most two capture instances per source table.

## Generate the deployment script

```powershell
./New-CdcConfigurationScript.ps1 `
    -CsvPath ./cdc/tables.csv `
    -OutputPath ./obj/cdc-configuration.sql
```

The output directory must already exist. The generator validates the CSV and writes UTF-8 without a byte order mark. It escapes SQL string literals and uses `QUOTENAME` when building table names for `OBJECT_ID`.

The generated T-SQL first verifies database-level CDC is enabled, then validates all source tables, existing capture-instance assignments, and per-table capture-instance limits before it enables any missing instances. Existing matching instances are skipped. It calls `sys.sp_cdc_enable_table` with `@role_name = NULL` and `@supports_net_changes = 0`.

## Include it in a SQL project

Add a SQLCMD include to the project's post-deployment script:

```sql
:r .\obj\cdc-configuration.sql
```

Ensure the generated file exists before the SQL project is built. For a project that uses SDK-style `.sqlproj`, a pre-build target can generate it:

```xml
<Target Name="GenerateCdcConfiguration" BeforeTargets="Build">
  <Exec Command="pwsh -NoProfile -File &quot;$(MSBuildThisFileDirectory)New-CdcConfigurationScript.ps1&quot; -CsvPath &quot;$(MSBuildThisFileDirectory)cdc\tables.csv&quot; -OutputPath &quot;$(MSBuildThisFileDirectory)obj\cdc-configuration.sql&quot;" />
</Target>
```

Create the `obj` directory before the target runs, or choose an existing output directory. Adapt the script and CSV paths to your repository layout. In CI/CD, run the generator before the SQL project build, package the resulting DACPAC, then publish it using your normal DACPAC deployment task. The post-deployment script runs after schema deployment, when the source tables should exist.

The generated script is deployment content. Keep it in the DACPAC build artifact and do not run it against a different database independently of the schema deployment.

## Example data

The CSV examples under [`examples/cdc`](examples/cdc/) demonstrate the manifest format. They contain configuration rows only; the sample database data and seed scripts are not included.

The restaurant example is the selected fixture for development/testing with the [Restaurant sample database](https://databasesample.com/datasets/restaurant-sample-database). The CSV has been used to verify SQL generation; database-side CDC deployment was not runtime-verified in this environment. That synthetic dataset is licensed CC0 1.0 and provides a small SQL Server seed option. The [Library sample database](https://databasesample.com/datasets/library-sample-database) is an alternate CC0 relational example. Verify schemas and table names against the version you download before using either manifest.

## Safety and limitations

- CDC must already be enabled at database level on the deployment target.
- This project never enables or disables database-level CDC.
- The generated script checks configuration errors before its first enable call. As with any multi-step deployment, an unexpected SQL Server error during a later stored procedure call can still leave earlier successful capture-instance enables in place.
- Review generated SQL and test in a disposable database before production use.
- SQL Server Agent and CDC capture jobs must be available and correctly configured for ongoing capture.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
