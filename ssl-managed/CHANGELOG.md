# Changelog: SSL Managed

All notable changes to this solution are documented here. Versions follow [Semantic Versioning](https://semver.org/). Release tags are named `ssl-managed-vX.Y.Z`.

## [1.0.0] - 2026-10-31

First public release.

### Content

| File | Version |
|---|---|
| `3sr-ssl-onboarding.ps1` | 2.1.0 |
| `3sr-ssl-offboarding.ps1` | 1.1.0 |
| `3sr-ssl-onboarding-guide-fr.md` / `-en.md` | n/a |

### Notes

- New optional parameter `-RapportEmail <address>` on both scripts: address displayed as the report recipient. Without a value, the scripts tell the user to contact their 3SR representative.
- Report files are now written with lowercase names (`3sr-ssl-onboarding-<date>.txt`, `3sr-ssl-offboarding-<date>.txt`, prefix `simulation-` in simulation mode).
- Script comments reviewed to describe the technical flow only.
- The resources created by the onboarding script carry a single tag, `3SR-SSL-Managed=true`, used to recognize them when the script is run again. The traceability tag `3SR-CreePar` is no longer written.
