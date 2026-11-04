# Changelog: Cloudiway

All notable changes to this solution are documented here. Versions follow [Semantic Versioning](https://semver.org/). Release tags are named `cloudiway-collector-vX.Y.Z`.

## Connector [1.0.0] - 2026-11-04

First public release of the **Cloudiway connector** (`connector/`), tag `cloudiway-connector-v1.0.0`. The script version is 2.7.

This script **modifies the customer's tenant** (application registration, permissions and consent, Exchange roles, certificate and client secret, EWS list, a service account, Cloudiway connector). Read the guide first, and start with `-WhatIf` or `-Discover`.

- Modes: **Source** and **Target**.
- Workloads: **Mail**, **OneDrive** and **SharePoint** (SharePoint needs the Cloudiway product identifier, see `productmap.example.json`). The other workloads are rejected with a message before any sign-in.
- `-AuthMethod Both` is the default: certificate and client secret, both required by Cloudiway. Every run renews the credentials and removes the tool's previous ones after the connector write has been verified.
- The **service account** (the connector's administrator account) is created **by default as soon as Mail is requested, in Source as well as in Target**: Cloudiway requires the certificate, the client secret and the administrator account together. The advanced option `-WithoutServiceAccount` skips it.
- The script **stops** (exit code 1, before any sign-in or write) if an Exchange Online session of another tenant or account is open in the console: one PowerShell console per tenant. The advanced option `-AllowForeignSession` restores the former behavior (consultant use only).
- Automation parameters `-GraphAccessToken`, `-ExchangeAccessToken` and `-CloudiwayPassword` exist for scripted runs (one line in the guides, no example).
- The guides give the validation state of 2026-11-04 and remind you to resubmit the connector audit after each run.
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
