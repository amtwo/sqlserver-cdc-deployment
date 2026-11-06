# SQL Server Docker integration tests

Run from a checkout using PowerShell 7 and a running **x64 Linux Docker engine**:

```powershell
pwsh -NoProfile -File ./tests/Invoke-DockerIntegrationTests.ps1
```

The script downloads the SQL Server 2022 Developer image, creates a uniquely named container with a random password, and waits for SQL Server to accept connections. SQL Server Agent is enabled for the change-capture check. The database container has no published ports, external network access, or mounted volumes. The script connects using `sqlcmd` inside that container and removes its container in `finally`, including on failure.

The default image is `mcr.microsoft.com/mssql/server:2022-latest`. To reproduce a particular image or check another SQL Server release with the same tools layout, pass `-Image` with an image tag or digest. Successful runs record `@@VERSION`, the image digest, PowerShell version, and passed checks in `obj/integration/<run-id>/results.json`. Generated manifests, SQL, query results, and server logs are retained beside it.

Microsoft's SQL Server container requires x64; see the [container deployment documentation](https://learn.microsoft.com/en-us/sql/linux/containers/deploy?view=sql-server-ver16). On an ARM64 development machine, use the **SQL Server integration** GitHub Actions job, which runs this same script on an x64 Ubuntu runner. The workflow uploads its test output even when a check fails.

## Restaurant fixture

The harness downloads the [CC0 Restaurant sample database](https://databasesample.com/datasets/restaurant-sample-database) SQL Server seed at runtime. Its URL and SHA-256 are pinned in the test script. A changed upstream file fails the test before any SQL is executed; inspect that change before updating the hash. The dataset is downloaded into ignored `obj` output and is not committed to this repository.

The seed creates 23 tables and loads data before the generated CDC configuration is applied. Database-level CDC is enabled by the test fixture. The generator remains responsible only for table capture instances.

## Checks

- A CDC-disabled database rejects deployment with error 51000 and stays disabled.
- The real restaurant schema and data accept the checked-in CDC manifest.
- Reapplying configuration preserves capture-instance and change-table identities.
- An update to a restaurant order appears in the CDC change table through SQL Server Agent.
- Missing tables and capture-instance conflicts fail before an earlier valid manifest row is enabled.
- A second capture instance succeeds; a third is rejected.
- Multiple planned instances are counted together, including case aliases in a case-insensitive database.
- Distinct case-sensitive tables get independent capture-instance limits.
- Apostrophes and closing brackets in identifiers work with `QUOTENAME` inside `OBJECT_ID`.
- Hostile CSV text remains data in both lookup expressions and error messages.

This suite exercises generated SQL directly after schema creation. DACPAC build and publish integration is documented in the project README and is not exercised by this suite.
