# cloudiway-connector: release notes 2.9

- **Version**: 2.9 (2026-11-25). It replaces all earlier versions. **Do not use versions earlier than 2.9.**
- **Validation**: offline test suite only. **Version 2.9 has never been run against a real Microsoft 365 tenant or the real Cloudiway portal.**

## Exchange Online: the `EwsAllowedAppIDs` list

**Defect in earlier versions.** According to the Microsoft documentation, `EwsAllowedAppIDs` is only returned by `Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy`. Earlier versions read it without that switch, so an existing list could be seen as empty. Because the parameter replaces the whole list, a run with the explicit confirmation or with `-AllowEwsListCreation` could overwrite an existing list with the tool's single AppID.

| Topic | Version 2.9 |
|---|---|
| Read | The list is read with the switch; a collection or a single "a,b" string are both handled |
| Switch unavailable or read failure | Nothing is written, even with `-AllowEwsListCreation`; manual step, exit code 2 |
| Before writing | Re-read; stop if an entry seen at plan time is gone; the value read is saved to `run.log` and verified, otherwise nothing is written |
| Write | Always the list read plus the AppID; a value that would drop an existing entry is refused |
| Rollback | A command that rewrites exactly the previous value is written to the report and `run.log` (`$null`, with a warning, if the previous value was empty) |
| After writing | Re-read: previous entries and the AppID must be present, otherwise the step fails and the rollback is shown |
| `EwsEnabled` | Null: the list is written but ignored for now; True: enforced; False: nothing is written. The tool never changes it |
| Delay | Up to 24 hours according to Microsoft |
| Manual commands | Read with the switch; the guard and the write are on a single line, so pasting them line by line cannot write after a failed read |

**After upgrading**: on tenants processed by an earlier version, read the real state with the switch (read only) and, if `EwsEnabled` is True and the list only holds the tool's AppID, check with the tenant owner that no other EWS application was cut off.

## Re-running on an already configured tenant

| Issue | Change | Status |
|---|---|---|
| HTTP 403 when resetting the service account password | The Graph sign-in now requests the missing scope `User-PasswordProfile.ReadWrite.All`; the operator must be Global Administrator or Privileged Authentication Administrator. If the scope is missing, the password line is blocked in the plan | The effect on the HTTP 403 has not been measured |
| Extra certificate and secret left after a failed re-run | Service account and password are processed before the certificate and secret; a refusal creates no credential | Offline tests only |
| Connector update sent without the migration account password or client secret | Blocked. New advanced parameters `-ServiceAccountPassword` (enter it with `Read-Host -AsSecureString`) and `-AllowConnectorUpdateWithoutPassword` | Portal behaviour for such an update: not measured |
| Secrets returned by the portal when a connector is read | Registered as secrets and removed from any output; the update never sends back the certificate that was read | Offline tests only |

## Minor changes

Cleanup note shown in the report; `-Region` restricted to 1-99; portal token no longer guessed from an arbitrary cookie; output folder stamped to the second.

## Behaviour changes for the operator

1. A new consent prompt (`User-PasswordProfile.ReadWrite.All`) on the first 2.9 run.
2. The output folder name includes seconds (`yyyyMMdd-HHmmss`).
3. `-WhatIf` exits with 1 when the plan contains a blocked line.
4. `-Region 0` is rejected.
5. A re-run with fewer workloads, `-WithoutServiceAccount` or `-AuthMethod Certificate` on an existing connector may be blocked.

Available workloads: Mail, OneDrive, SharePoint and Teams. Archive remains unavailable in this package.

## Also new for users of 2.7 (introduced in 2.8)

- Teams is now accepted; no real Teams or SharePoint migration has been run to date.
- Cloudiway product identifiers are built in: Mail 5, OneDrive 6, SharePoint 7, Teams 8 (provisional). SharePoint no longer stops for a missing identifier.
- The old certificate and secret cleanup re-reads the application with successive waits; the fallback for a refused certificate removal only applies to a real refusal (HTTP 403 or equivalent).

## Known limits

- The rollback command also removes any entry added by someone else after the backup; the backup only exists on the workstation that ran the tool.
- A password changed in Entra followed by a failed connector write leaves the connector with the old password; run the same command again without `-KeepCredentials`.
- With `-ServiceAccountPassword`, the manual-step list may still ask to enter the password in the portal.
