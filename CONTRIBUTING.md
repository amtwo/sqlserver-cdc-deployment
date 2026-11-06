# Contributing

Thanks for helping improve SQL Server CDC Deployment.

## Before you start

- For a bug or feature idea, open an issue or discussion first when practical so the scope can be agreed before implementation.
- Keep changes focused and preserve the documented input and output contract unless a change is intentional and documented.
- Do not include downloaded sample database content. The examples in this repository contain CDC configuration manifests and their generated SQL only.

## Changes

- Develop and validate the generator using PowerShell 7 (`pwsh`). When also checking Windows PowerShell compatibility, report its version and the checks that passed.
- Preserve safety behavior: database-level CDC must already be enabled; the script must fail before attempting CDC changes when it is not.
- Escape SQL string literals, quote identifiers with `QUOTENAME`, and validate the full manifest before generating a deployment script.
- Update the README and examples when command-line parameters or generated SQL behavior change.
- Avoid adding runtime dependencies unless they materially improve the tool.

## Validation

Before opening a pull request:

1. Parse the PowerShell file and run generation using PowerShell 7 (`pwsh`). Record any additional Windows PowerShell compatibility checks separately, including the version and results.
2. Run `pwsh -NoProfile -File ./tests/Test-ExampleOutput.ps1`. All SQL examples, in default and cleanup modes, must match fresh output byte for byte, including encoding and line endings. Regenerate examples after changing the generator; do not edit generated SQL by hand.
3. Run `pwsh -NoProfile -File ./tests/Invoke-DockerIntegrationTests.ps1` using an x64 Linux Docker engine, or verify the GitHub Actions integration job. See [the test guide](tests/README.md) for setup and coverage. Never test against production.
4. Run `git diff --check`.
5. Run `pwsh -NoProfile -File ./tests/Test-DacpacBuild.ps1` with the .NET SDK installed to verify clean and incremental SQL project packaging.
6. Run `pwsh -NoProfile -File ./tests/Test-GeneratorModes.ps1` to verify opt-in header-only cleanup and rejection of invalid CSV input.

The integration workflow runs on an x64 Linux runner so ARM64 contributors can get real SQL Server coverage. Report the engine version, image digest, and result when citing a run.

## Pull requests

- Explain the user-visible behavior and any compatibility impact.
- Include validation performed and identify runtime checks that could not be run.
- Keep generated artifacts out of commits unless the change specifically concerns a checked-in generated artifact.
