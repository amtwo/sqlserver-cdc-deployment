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
- Capture-instance names that collide under an accent-insensitive collation are rejected before changes, for both the same and different source tables.
- Apostrophes and closing brackets in identifiers work with `QUOTENAME` inside `OBJECT_ID`.
- Hostile CSV text remains data in both lookup expressions and error messages.
- Cleanup frees occupied slots before replacement, drops instances on omitted tables, and preserves retained capture identities and source data.
- Missing/conflicting/ineligible sources and excessive desired counts fail before cleanup.
- Header-only cleanup removes every instance, retains database-level CDC, and is idempotent.
- Reserved `all` selectors and their case/accent variants cannot silently remove retained instances or skip pending drops.

This Docker suite exercises generated SQL directly after schema creation. The build checks below verify DACPAC packaging separately; DACPAC publish itself is not exercised.

The test environment has run SQL Server **2022 Developer, RTM-CU27-GDR (16.0.4305.5)** with PowerShell **7.6.9** on an x64 Linux GitHub runner. Each successful run's `results.json` records the exact image digest and checks that passed.

## Example and build checks

These checks also run in CI and can run without Docker:

```powershell
pwsh -NoProfile -File ./tests/Test-ExampleOutput.ps1
pwsh -NoProfile -File ./tests/Test-GeneratorModes.ps1
pwsh -NoProfile -File ./tests/Test-DacpacBuild.ps1
```

The example check compares all four SQL files (default and cleanup modes) with fresh output byte for byte, including encoding and line endings. It does not normalize or rewrite either file before comparing. The generator-mode check verifies that valid header-only cleanup is accepted while empty/malformed inputs are rejected without overwriting output.

The build check requires the .NET SDK (8 or later). It copies the small SQL project fixture into ignored test output, then builds with Microsoft.Build.Sql 2.3.0 using the README's generation hook. It opens the DACPAC to verify that the generated post-deployment script is present, changes a capture-instance name in the CSV, rebuilds, and verifies that the packaged SQL reflects the new value. A further build verifies that opt-in cleanup is packaged before enable calls.

## Windows PowerShell compatibility

Both checked-in CSV examples generated SQL successfully with Windows PowerShell **5.1.26100.9711**, and their output matched PowerShell **7.6.9** after line-ending normalization. This was a generator compatibility check; the Docker integration suite runs with PowerShell 7.
