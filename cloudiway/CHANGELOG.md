# Changelog: Cloudiway

All notable changes to this solution are documented here. Versions follow [Semantic Versioning](https://semver.org/). Release tags are named `cloudiway-collector-vX.Y.Z`.

## [1.2.0] - 2026-10-31

First public release of the collector. The version number is the one the script writes in `tenant.csv`.

### Content

| File | Role |
|---|---|
| `collector/cloudiway-collector.ps1` | Read-only collection of a Microsoft 365 tenant (PowerShell 7) |
| `collector/cloudiway-collector.cmd` | Launcher that works from Windows PowerShell 5.1 |
| `collector/cloudiway-collector-guide-fr.md` / `-en.md` | User guides |
| `collector/tests/` | Offline tests (`tests/run-tests.ps1`) |

### Notes

- The script collects raw data and produces a single archive. It computes nothing and uploads nothing.
- Output names are lowercase: `collecte-resultats/` and `collecte-<first 8 characters of the tenant id>.zip`.
