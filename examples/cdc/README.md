# CDC CSV examples

These CSVs show the input format expected by `New-CdcConfigurationScript.ps1`.
Each CSV has a matching generated `.sql` file so you can inspect the deployment
output. Both formats contain CDC configuration only; neither dataset is bundled
here, and the SQL files require the source tables and database-level CDC to
already exist.

The `.sql` files are literal generator output. Regenerate them instead of editing
them by hand. CI compares their bytes with fresh output, including encoding and
line endings.

Matching `.cleanup.sql` files demonstrate `-DropUnlistedCaptureInstances`. These
scripts disable every unlisted capture instance across the target database,
deleting its change table and captured history before enabling missing instances.

Regenerate both SQL examples from the repository root using PowerShell 7:

```powershell
foreach ($dataset in @('restaurant', 'library')) {
    ./New-CdcConfigurationScript.ps1 `
        -CsvPath "./examples/cdc/$dataset-sample-database.csv" `
        -OutputPath "./examples/cdc/$dataset-sample-database.sql"
    ./New-CdcConfigurationScript.ps1 `
        -CsvPath "./examples/cdc/$dataset-sample-database.csv" `
        -OutputPath "./examples/cdc/$dataset-sample-database.cleanup.sql" `
        -DropUnlistedCaptureInstances
}
```

## Restaurant sample database

`restaurant-sample-database.csv` is the configuration selected for testing the
CDC script with the Restaurant sample database. The external dataset is synthetic,
CC0 1.0, contains 23 related tables, and has a SQL Server seed script. The
1K CSV archive is 29 KB (2,321 rows total); larger versions are available.

Dataset and SQL Server download: <https://databasesample.com/datasets/restaurant-sample-database>

The CSV assumes the dataset's tables are installed in the `dbo` schema; confirm
the actual schema and table names before using it. The selected dataset is not
vendored in this repository.

## Library sample database

`library-sample-database.csv` is an additional CDC configuration example based
on a separate 30-table relational dataset. It is also synthetic and CC0 1.0;
its smallest published CSV archive is 47 KB (2,024 rows total).

Dataset and SQL Server download: <https://databasesample.com/datasets/library-sample-database>
