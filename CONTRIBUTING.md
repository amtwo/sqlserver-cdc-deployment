# Contributing

Thanks for helping improve SQL Server CDC Deployment.

## Before you start

- For a bug or feature idea, open an issue or discussion first when practical so the scope can be agreed before implementation.
- Keep changes focused and preserve the documented input and output contract unless a change is intentional and documented.
- Do not include downloaded sample database content. The examples in this repository are small CDC configuration manifests only.

## Changes

- Keep the generator compatible with PowerShell 5.1 and PowerShell 7 unless the project explicitly changes its support policy.
- Preserve safety behavior: database-level CDC must already be enabled; the script must fail before attempting CDC changes when it is not.
- Escape SQL string literals, quote identifiers with `QUOTENAME`, and validate the full manifest before generating a deployment script.
- Update the README and examples when command-line parameters or generated SQL behavior change.
- Avoid adding runtime dependencies unless they materially improve the tool.

## Validation

Before opening a pull request:

1. Parse the PowerShell file with the target PowerShell version.
2. Generate SQL from both checked-in CSV examples and inspect the output.
3. If a disposable SQL Server is available, test deployment after schema creation, idempotent re-deployment, invalid source tables, capture-instance conflicts, and a target where CDC is disabled. Never test against production.
4. Run `git diff --check`.

A SQL Edge run is useful smoke coverage but is not a substitute for supported SQL Server versions; note compatibility gaps in the PR.

## Pull requests

- Explain the user-visible behavior and any compatibility impact.
- Include validation performed and identify runtime checks that could not be run.
- Keep generated artifacts out of commits unless the change specifically concerns a checked-in generated artifact.
