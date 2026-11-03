# Changelog: Cloudiway

All notable changes to this solution are documented here. Versions follow [Semantic Versioning](https://semver.org/). Release tags are named `cloudiway-collector-vX.Y.Z`.

## Connector [1.0.0] - 2026-11-03

First public release of the **Cloudiway connector** (`connector/`), tag `cloudiway-connector-v1.0.0`. The script version is 2.4.

This script **modifies the customer's tenant** (application registration, permissions and consent, Exchange roles, certificate, EWS list, Cloudiway connector). Read the guide first, and start with `-WhatIf` or `-Discover`.

- Scope: **Source mode** only, **Mail** and **OneDrive** workloads only. Other workloads are rejected with a message; Target mode is not available yet.
- Every run renews the certificate and removes the tool's previous certificates.
- Section 16 of the guides lists what has and has not been validated in real conditions.
- Offline tests: `connector/tests/run-tests.ps1`.

## Collector [1.2.0] - 2026-10-31

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
