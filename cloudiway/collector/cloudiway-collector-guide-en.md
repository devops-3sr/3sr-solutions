# cloudiway-collector: user guide

Version française : [cloudiway-collector-guide-fr.md](cloudiway-collector-guide-fr.md)

`cloudiway-collector` is a PowerShell script that **collects, read-only,** the configuration and volumes of a Microsoft 365 tenant, in order to prepare a tenant-to-tenant migration with Cloudiway. It is designed to be run by a tenant administrator, without technical assistance.

The script **only collects**: it produces raw data (CSV and JSON) bundled into **a single file, a zip archive**, which you then hand to your 3SR contact. It does not compute, estimate or price anything.

## Contents

1. [What the script does and does not do](#1-what-the-script-does-and-does-not-do)
2. [Required permissions](#2-required-permissions)
3. [Prerequisites](#3-prerequisites)
4. [Step-by-step execution](#4-step-by-step-execution)
5. [Files produced and their content](#5-files-produced-and-their-content)
6. [What to send to 3SR](#6-what-to-send-to-3sr)
7. [Deleting the data afterwards](#7-deleting-the-data-afterwards)
8. [Verifying the script before running it](#8-verifying-the-script-before-running-it)
9. [Troubleshooting](#9-troubleshooting)
10. [Option reference](#10-option-reference)

## 1. What the script does and does not do

**What it does**

- It signs in to the tenant with **your** administrator account, through three successive sign-in windows: Microsoft Graph, SharePoint Online, Exchange Online.
- It reads the configuration (identities, licenses, groups, domains, devices, security, public DNS, mail flow, EWS status) and the volumes (mailbox sizes, SharePoint site sizes and OneDrive account sizes).
- It writes CSV and JSON files to a local folder, then bundles them into a zip archive.

**What it does not do**

- **It is read-only on the tenant**: it only runs reads (Graph `GET` requests, `Get-*` cmdlets). It creates, modifies and deletes nothing in your tenant. No cmdlet that writes to the tenant exists in the code, and the test suite checks this; the only writes are local (result files and, with your consent, installation of modules in your profile).
- It reads **no content**: no emails, no files, no Teams messages. It collects names, addresses, sizes, counts and configuration settings.
- It writes and displays **no password and no token**.
- It uploads **nothing** to the Internet: the files stay on the machine that runs the script, **under your control until you send them yourself** (see [section 6](#6-what-to-send-to-3sr)).
- It does not cover Google Workspace or migrations outside Microsoft 365.

Safeguards: the script checks that the tenant and the account that sign in are exactly the ones you specified (`-TenantId`, `-User`); on any mismatch it disconnects and stops. Before any sign-in it checks the machine (PowerShell, modules, network, write access); if a prerequisite is missing it stops without having attempted any connection.

## 2. Required permissions

### Account role

The signed-in account must be:

- **Global Administrator** (recommended: this is the role the script has been proven with, and the one able to grant the consent requested at first sign-in); or
- **Global Reader**, which is in principle sufficient for reads; the script tests access at startup and reports exactly what is missing.

For the Exchange and SharePoint parts, the reads in practice require: Exchange Administrator, Global Reader or Global Administrator for Exchange Online; SharePoint Administrator or Global Administrator for SharePoint Online. An eligible but not activated role (PIM) is not taken into account: activate it before starting the collection.

### Consent at first sign-in

At the first Microsoft Graph sign-in, Microsoft asks a Global Administrator to **consent to read-only permissions** for the enterprise application **"Microsoft Graph Command Line Tools"**. This application stays in your tenant; it can be deleted after the collection (see [section 7](#7-deleting-the-data-afterwards)). Without consent, the collection stops at the very first step with an explicit message.

### The 18 Microsoft Graph permissions requested

All are **read** permissions (`.Read.*`; no write permission is requested):

| # | Permission | # | Permission |
|---|---|---|---|
| 1 | `Organization.Read.All` | 10 | `AuditLog.Read.All` |
| 2 | `Directory.Read.All` | 11 | `Policy.Read.All` |
| 3 | `User.Read.All` | 12 | `RoleManagement.Read.Directory` |
| 4 | `Group.Read.All` | 13 | `SecurityEvents.Read.All` |
| 5 | `Application.Read.All` | 14 | `Device.Read.All` |
| 6 | `Team.ReadBasic.All` | 15 | `DeviceManagementManagedDevices.Read.All` |
| 7 | `Channel.ReadBasic.All` | 16 | `DeviceManagementConfiguration.Read.All` |
| 8 | `Reports.Read.All` | 17 | `DeviceManagementApps.Read.All` |
| 9 | `ReportSettings.Read.All` | 18 | `DeviceManagementServiceConfig.Read.All` |

The list is in `lib/common.ps1` (variable `GraphScopes`); you can read it before running anything. The Graph sign-in context is limited to the process: it disappears when the console is closed.

### What the script tests before collecting

Right after sign-in, the script performs a minimal read on each relevant access point. If a **required** point is denied (organization, domains, users, groups), the collection stops before starting, naming the missing role or consent. A denied **optional** point stops nothing: it is reported as `[WARN]` with its impact. Examples of license-related limits: without Entra ID P1 or P2, last sign-ins, Conditional Access and MFA status are unavailable; without Intune, managed devices and Intune profiles are absent (normal if Intune is not used).

## 3. Prerequisites

1. **A Windows machine** with HTTPS access to `login.microsoftonline.com`, `graph.microsoft.com`, `outlook.office365.com` and `sharepoint.com` (the script tests these before starting and detects a proxy or certificate inspection). About 200 MB of free space for the output folder.
2. **PowerShell 7** (the `pwsh` command). The PowerShell built into Windows (version 5.1) is not suitable for the script itself; the **launcher** `cloudiway-collector.cmd`, however, works from Windows PowerShell 5.1: it unblocks the files, checks that PowerShell 7 is installed and, if it is missing, **offers** to install it with `winget` (after confirmation; Windows may ask for administrator rights).
3. **Three PowerShell modules**:
   - `Microsoft.Graph.Authentication` (version 2.0.0 minimum);
   - `ExchangeOnlineManagement` (version 3.7.0 minimum);
   - `Microsoft.Online.SharePoint.PowerShell`.

   If they are missing, the script offers to install them for the current user (no administrator rights), after confirmation. To install them yourself:

   ```powershell
   Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement, Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser
   ```

4. **An administrator account** of the tenant to be collected (see [section 2](#2-required-permissions)).
5. **Unblock the downloaded files** (Windows marks files received over the Internet or in a zip). The launcher does it for you; otherwise, in the script folder:

   ```powershell
   Get-ChildItem -Path . -Recurse -File | Unblock-File
   ```

The `lib` folder must stay next to the main script: do not copy `cloudiway-collector.ps1` alone.

## 4. Step-by-step execution

The examples use the fictitious **Contoso** tenant: replace the values with those of your tenant.

**Step 1. Find the tenant identifier (GUID).** Microsoft Entra admin center, "Overview" page, "Tenant ID" field. Alternatively, from a domain name of the tenant:

```powershell
(Invoke-RestMethod "https://login.microsoftonline.com/contoso.onmicrosoft.com/.well-known/openid-configuration").token_endpoint
```

The returned URL contains the tenant GUID.

**Step 2. Open a console** in the script folder (Command Prompt or PowerShell).

**Step 3. Start the collection.** Main method, using the launcher:

```
cloudiway-collector.cmd -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com
```

(from PowerShell: `.\cloudiway-collector.cmd -TenantId ... -User ...`). If PowerShell 7 is already installed, you can call the script directly:

```powershell
pwsh -NoProfile -File .\cloudiway-collector.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com
```

For a **destination** tenant (lighter collection, to detect conflicts), add `-Role Target`. Without this option the role is `Source` (tenant to migrate, full volumes).

The launcher uses `-ExecutionPolicy Bypass` **for this one execution only** (it does not change the machine's execution policy).

**Step 4. Answer the sign-in windows.** The script opens three windows, always with the same account:

1. **Microsoft Graph** (users, licenses, groups, security, devices);
2. **SharePoint** (sites and OneDrive), after a 10-second countdown;
3. **Exchange Online** (mailboxes, mail flow), after a 10-second countdown.

No confirmation is awaited before they open: stay in front of the screen for the first minutes, because each window expires after about 2 minutes. The three sign-ins are requested up front; the collection itself then runs unattended.

**Step 5. Wait for the end.** Allow 10 to 40 minutes depending on the tenant size (reading mailbox statistics is the longest part). The script shows its progress (steps 1/4 to 4/4), then a final report: number of OK, partial and KO items, duration, archive path. Do not close the console.

**Step 6. Read the final report.** "KO" or "NON DISPO" lines are common and usually harmless: they flag information that cannot be reached (missing license, permission not granted, feature not enabled). The script carries on and lists them, with advice, in the final report and in `capabilities.csv`. A genuine "error" KO (Exchange or SharePoint access denied, sign-in cancelled) is worth re-running with an account holding the indicated role.

**Re-running.** The script is **idempotent**: re-running the same command updates the same folder and the same archive (old result files are removed, `run.log` is kept and appended to). It can therefore be replayed safely after a permission denial or an expired window.

**Re-running only one part.** The parts are `Identity`, `Devices`, `Security`, `Dns`, `Exchange`, `SharePoint`. With `-OutDir` pointing to the subfolder of the existing collection (the one containing `tenant.csv`), only the requested parts are redone and `capabilities.csv` is merged. One part: `-Parts Exchange`. Several parts: `-File` does not handle lists, use `-Command`:

```powershell
pwsh -NoProfile -Command "& '.\cloudiway-collector.ps1' -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com -Parts Exchange,SharePoint -OutDir '.\collecte-resultats\00000000'"
```

## 5. Files produced and their content

The script writes, in the output folder (by default `collecte-resultats`, next to the script; option `-OutDir`):

- a folder named after the first 8 characters of the tenant GUID (for example `collecte-resultats\00000000\`) containing the files below;
- **the archive `collecte-<first 8 characters of the GUID>.zip`**, which bundles these files (for example `collecte-resultats\collecte-00000000.zip`).

CSV files use the `;` separator and UTF-8 with BOM encoding.

> **These files contain personal data**: email addresses and user names (UPN), names and addresses of groups and mailboxes, mailbox sizes, OneDrive and site owners, external guests, site and policy names. They contain **no content** of any email, file or message. Treat them as personal data.

| File | Content | Source / role |
|---|---|---|
| `tenant.csv` | Tenant name, identifier and initial domain, country, language, directory sync status, account that ran the collection, date, script version, role | all |
| `capabilities.csv` | Log of checks: for each part and item, the status (OK, PARTIEL, KO) and a detail | all |
| `run.log` | Timestamped run log (steps, statuses, short error messages); mentions the account used and the local path of the output folder | all |
| `skus.csv` | License subscriptions: part number, state, purchased and consumed quantities | all |
| `users.csv` | Accounts: identifier, UPN, names, addresses (including aliases), type (member or guest), enabled or not, assigned licenses, creation dates, usage location, department, job title, on-premises sync, last sign-ins (if the license allows) | all |
| `guests.csv` | External guests: UPN, address, creation date | Source |
| `groups.csv` | Groups: name, addresses, kind (Microsoft 365, security, distribution), Teams team or not, visibility, number of members and owners | all (counts: Source) |
| `teams-channels.csv` | Per Teams team: number of standard, private and shared channels | Source |
| `domains.csv` | Tenant domains: verified, default, initial, authentication type, services | all |
| `enterprise-apps.csv` | Enterprise applications: name, appId, single sign-on mode, enabled or not, owning organization | all |
| `entra-devices.csv` | Entra devices: name, operating system, version, join type, managed, compliant, last sign-in | all |
| `intune-managed-devices.csv` | Intune-managed devices: name, operating system, compliance, enrollment, user, encryption | all (if Intune) |
| `intune-config-inventory.csv` | Inventory of Intune profiles: category, name, type, creation date (no configuration content) | all (if Intune) |
| `autopilot-devices.csv` | Autopilot devices (if accessible) | all |
| `secure-score.csv` | Microsoft Secure Score (if accessible) | all |
| `conditional-access.csv` | Conditional Access policies: name, state, summarized conditions and controls | all (Entra ID P1 or P2) |
| `security-defaults.csv` | Whether security defaults are enabled | all |
| `authorization-policy.csv` | Tenant invitation and consent settings | all |
| `cross-tenant-access.csv` | Cross-tenant access settings | all |
| `directory-roles.csv` | Active administrator roles and their members (UPN) | all |
| `mfa-registration.csv` | Per user: registered MFA methods (UPN, default method) | all (Entra ID P1 or P2) |
| `auth-methods-policy.csv` | Allowed authentication methods | all |
| `report-onedrive-usage.csv`, `report-sharepoint-usage.csv`, `report-mailbox-usage.csv`, `report-active-users.csv`, `report-teams-activity.csv` | Microsoft 365 usage reports over 180 days (storage, file counts, last activity, owners). If the tenant conceals names, identifiers are anonymized | Source |
| `dns.csv` | Per verified domain: MX, SPF, DMARC and Autodiscover records as resolved from the machine (public DNS), and the mail filtering deduced from them | all |
| `ews.csv` | EWS status in the organization, allowed applications, count of mailboxes with EWS disabled, presence of the Cloudiway applications | all |
| `exo-organization.csv` | A few Exchange organization settings (logging, public folders, modern authentication...) | all |
| `mailboxes.csv` | Mailboxes: type, name, UPN, addresses, alias, archive, holds, forwarding, creation date; for Source, **sizes and item counts** of the mailbox and its archive | all (volumes: Source) |
| `recipients.csv` | All recipients (name, primary address, alias, type, addresses) | Target |
| `mailbox-permissions.csv` | Mailbox permissions (full access, send as...): mailbox, type, right, trustee | Source |
| `distribution-lists.csv` | Distribution lists: name, address, type, number of members, addresses | Source |
| `mail-contacts.csv` | Mail contacts and mail users: name, addresses | Source |
| `accepted-domains.csv` | Accepted domains | all |
| `connectors.csv` | Inbound and outbound mail connectors (hosts, domains, IP addresses) | all |
| `transport-rules.csv` | Transport rules: name, state, priority, mode, description | all |
| `dkim.csv` | DKIM status per domain | all |
| `sites.csv` | All SharePoint sites and OneDrive accounts: URL, title, template, owner, storage (bytes and GB), last modification, linked group, sharing, category. For Target: URL, title, template, category only | all (volumes: Source) |
| `onedrive.csv`, `sharepoint.csv`, `sharepoint-system.csv` | The content of `sites.csv` split by category (OneDrive accounts, SharePoint sites, system sites) | Source |
| `spo-tenant.csv` | SharePoint tenant sharing and storage settings | all |

Some files may be absent or empty depending on licenses and permissions; `capabilities.csv` gives the reason.

## 6. What to send to 3SR

Send **a single file**: the archive **`collecte-<first 8 characters of the GUID>.zip`**, located in the output folder. Do not send the extracted folder, the modules or screenshots.

- Transmit it through **a secure channel** agreed with your 3SR contact (secure drop space, protected link) and not by unencrypted email: it contains personal data.
- Until you send it, the data **stays on your machine and under your control**: the script uploads nothing, and nothing leaves without an action on your part. You can open the CSV files (for example in Excel) to review them before sending.
- For your information, the script performs no analysis: 3SR will process this raw data.

## 7. Deleting the data afterwards

1. **Delete the results** at the end of the use agreed with 3SR (at the latest at the end of the project): the output folder (`collecte-resultats` by default) and the archive `collecte-<8 characters>.zip`, as well as any copy made elsewhere (mailbox, downloads folder, recycle bin). Example:

   ```powershell
   Remove-Item -Recurse -Force .\collecte-resultats
   ```

2. **Delete the script** and its `lib` folder if you no longer need them.
3. **Remove the enterprise application "Microsoft Graph Command Line Tools"** from the tenant if you do not use it otherwise: Microsoft Entra, Enterprise applications, select the application, then Delete. Other Microsoft sign-in tools (Exchange Online, SharePoint Online) may appear in the same way.
4. Optional: uninstall the modules (`Uninstall-Module Microsoft.Graph.Authentication`, etc.) if you do not use them.

The script disconnects from Graph at the end of the collection. Closing the console ends any remaining session.

## 8. Verifying the script before running it

The release notes publish the **SHA-256 hash** of each file. To compute the hash of the main script and compare it with the release notes:

```powershell
Get-FileHash -Algorithm SHA256 .\cloudiway-collector.ps1
```

To compute the hash of every file in the folder:

```powershell
Get-ChildItem -Recurse -File | Get-FileHash -Algorithm SHA256 | Select-Object Hash, Path
```

A different hash means the file is not the one that was published: do not run it, and tell your 3SR contact. Compute the hash on the files as downloaded from the published release archive (a `git clone` with automatic line-ending conversion can alter the files and therefore their hash). Since the script is a text file, you can also read it before running it.

The script can be tested without any connection with the supplied test suite (simulated cmdlets, no network):

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

## 9. Troubleshooting

| Symptom | Likely cause and action |
|---|---|
| `cloudiway-collector.cmd` offers to install PowerShell 7 | PowerShell 7 is missing. Accept (O), or download it from https://aka.ms/powershell-release?tag=stable and run again. |
| "Blocked" files / execution policy error | The launcher unblocks the files. Otherwise: `Get-ChildItem -Path . -Recurse -File \| Unblock-File`. |
| Message "Des prerequis manquent" (prerequisites missing) | Read the table: network, module, write access. No connection was attempted; fix and run again. For a module, the exact install command is displayed. |
| Machine administrator rights requested for a module | Open PowerShell 7 **as administrator**, run the displayed `Install-Module ... -Scope AllUsers` command, then run again in a normal console. |
| "Connexion refusee : le tenant ou le compte ne correspond pas" (connection refused: tenant or account mismatch) | The account chosen in the window is not the `-User` one (or its alias differs from the UPN). Run again and pick exactly the requested account; use the exact UPN. |
| Stops at the first step, organization cannot be read | Administrator consent missing. Sign in with a Global Administrator and accept the consent. |
| "Le compte n'a pas les acces indispensables" (the account lacks essential access) | Insufficient role (see [section 2](#2-required-permissions)); the denied point and the expected role are shown. |
| The SharePoint or Exchange window expired | Run the same command again (the full collection is redone), or re-run only the part concerned (`-Parts SharePoint`). |
| `[KO]` Exchange or SharePoint "access denied" | The account lacks the required Exchange or SharePoint role; the part is skipped cleanly. Run again with a suitable account. |
| `[NON DISPO]` | License or role absent (Entra ID P1 or P2, Intune...): harmless, nothing to do. |
| "Fichier verrouille : fermez Excel" (file locked: close Excel) | A CSV is open in Excel. Close it and run again. |
| Anonymized usage reports | The tenant conceals names in reports (a Microsoft 365 setting). Information, not an error. |
| Zip creation failed (exit code 2) | Compress the results folder by hand (all files at the root of the archive). |
| Exchange module update requested | A module that is too old is treated as missing; accept the update, then open a new console if an older module was already loaded. |

Exit codes: **0** the archive was created; **1** stopped before or during sign-in (prerequisites, access, account refusal); **2** archive creation failed. The exit code of the Exchange and SharePoint processes is recorded in `capabilities.csv`.

The script's console messages are in French.

## 10. Option reference

| Option | Required | Description |
|---|---|---|
| `-TenantId <GUID>` | yes | Identifier (GUID) of the tenant to collect. |
| `-User <UPN>` | yes | Administrator account that signs in; any other identity is refused. |
| `-Role Source\|Target` | no (default `Source`) | `Source`: tenant to migrate, full volumes. `Target`: destination tenant, lighter collection (conflicts and security). |
| `-Parts <list>` | no (default: all) | `Identity`, `Devices`, `Security`, `Dns`, `Exchange`, `SharePoint`. |
| `-OutDir <folder>` | no | Output folder (default `collecte-resultats` next to the script). An existing collection folder is resumed. |
| `-InstallMissingModules` | no | Installs missing modules without asking (user profile). |

With the launcher, only one value per option is passed: `-Parts Exchange` works, a list (`-Parts Exchange,SharePoint`) requires calling the script directly with `-Command` (see [section 4](#4-step-by-step-execution)).
