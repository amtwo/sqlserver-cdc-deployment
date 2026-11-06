# CDC CSV examples

These CSVs show the input format expected by `New-CdcConfigurationScript.ps1`.
They contain CDC configuration only; neither dataset is bundled here, and the
CSV files do not create the source tables.

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
