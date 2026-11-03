# cloudiway-connector: user guide

Version française : [cloudiway-connector-guide-fr.md](cloudiway-connector-guide-fr.md)

`cloudiway-connector` is a PowerShell script that **configures a "source" Microsoft 365 tenant** for a Cloudiway connector, then **creates or updates that connector** in your Cloudiway project. It replaces the series of manual steps described in the Cloudiway documentation (app registration, permissions, consent, Exchange roles, certificate, EWS list, entering the connector in the portal).

This version (2.4) only covers:

- the **Source mode** (the tenant being migrated);
- the **Mail** and **OneDrive** workloads.

The Target mode is not available yet: it will come in a later version. The other workloads (SharePoint, Teams, Archive, GalSync, Intune, FreeBusy, Signature, MailRouting) are not available in this version: the script rejects them with a clear message.

## Read this first: this script MODIFIES your tenant

**This is not a read-only tool.** Run without `-WhatIf`, it creates and modifies objects in your Microsoft 365 tenant, in Exchange Online and in your Cloudiway project. Here is the exact list, with the rights it gives to the application.

| # | Where | What is created or modified |
|---|---|---|
| 1 | Microsoft Entra | An **app registration** `CLOUDIWAY-SOURCE-P<project number>` (tag `CloudiwayConnector`, single tenant). |
| 2 | Microsoft Entra | Its **service principal** (enterprise application). |
| 3 | Microsoft Entra | The **application permissions** declared on the registration, and their **admin consent** (see the list below). |
| 4 | Microsoft Entra | A delegated consent limited to `User.Read` (Microsoft Graph). |
| 5 | Microsoft Entra | The directory roles **Exchange Administrator** and **Exchange Recipient Administrator**, assigned **to the application's service principal** (Mail workload only). |
| 6 | Microsoft Entra | A **certificate** (RSA 2048, SHA-256, subject `CN=Cloudiway-SOURCE-P<project>`), generated in memory, whose public part is added to the application's keys. |
| 7 | Exchange Online | The **application's AppID is added to `EwsAllowedAppIDs`** (Mail workload only; add-only, with a confirmation and a warning when the list is empty, see [section 9](#9-the-exchange-online-ews-list)). |
| 8 | Cloudiway | A **connector** `<prefix of the .onmicrosoft.com domain>-source` created or updated in your project (certificate, certificate password, application ID, domain, region, Cloudiway products). |
| 9 | Your workstation | A results folder (`run.log` and `Rapport-...md`, no secrets); missing PowerShell modules if you use `-InstallMissingModules`; the consent of the Microsoft application "Microsoft Graph Command Line Tools" (see [section 5](#5-step-by-step-execution)). |

**Application permissions granted to the application** (least privilege computed from the chosen workloads):

| Workload | Microsoft Graph | Exchange Online | SharePoint Online |
|---|---|---|---|
| Mail | `MailboxSettings.ReadWrite` | `Exchange.ManageAsApp`, `full_access_as_app` | (none) |
| OneDrive | `User.Read.All`, `Files.ReadWrite.All`, `Sites.FullControl.All`, `Directory.Read.All` | (none) | `Sites.FullControl.All`, `User.Read.All` |

These permissions are **broad** (access to the mailboxes and files of all users): they are the ones Cloudiway requires to migrate. They belong to the application, not to a named account; this is why the end of the project must include removing them ([section 11](#11-removing-the-objects-at-the-end-of-the-project)).

**What the script does not do**

- It **deletes nothing** in the tenant or in Cloudiway, with **one exception**: the **old certificates created by the tool itself** (name starting with `Cloudiway-SOURCE-P<project>`) are removed from the application, after the new certificate has been successfully written to the connector. Any other key on the application (added by hand) is kept.
- It **does not write, display or log any secret**: the certificate and its password are generated in memory, sent directly to Cloudiway, then erased. No `.pfx` file, no password, no state file is written to disk.
- It **does not read any mailbox or file content**. It reads configuration: organization, applications, service principals, roles, permission grants, the Exchange Online EWS configuration, the list of Cloudiway projects and connectors.
- It **assigns no license** and **creates no service account**: in Source mode with Mail and OneDrive, no user account is created or modified.
- It does not change or disable any Conditional Access policy, nor multifactor authentication.

**Always start with `-WhatIf`**: the script then displays the complete plan (what it would create or modify) without writing anything. See [section 5](#5-step-by-step-execution).

## Contents

1. [What the script does, in order](#1-what-the-script-does-in-order)
2. [Why a single person runs it](#2-why-a-single-person-runs-it)
3. [Prerequisites](#3-prerequisites)
4. [Preliminary step: the invitation to the Cloudiway project](#4-preliminary-step-the-invitation-to-the-cloudiway-project)
5. [Step-by-step execution](#5-step-by-step-execution)
6. [Objects created and coded names](#6-objects-created-and-coded-names)
7. [Renewal: every run renews the certificate](#7-renewal-every-run-renews-the-certificate)
8. [Reading the result](#8-reading-the-result)
9. [The Exchange Online EWS list](#9-the-exchange-online-ews-list)
10. [Files produced](#10-files-produced)
11. [Removing the objects at the end of the project](#11-removing-the-objects-at-the-end-of-the-project)
12. [Checking the script before running it](#12-checking-the-script-before-running-it)
13. [Troubleshooting](#13-troubleshooting)
14. [Exit codes](#14-exit-codes)
15. [Options reference](#15-options-reference)
16. [What has not yet been validated in real conditions](#16-what-has-not-yet-been-validated-in-real-conditions)
17. [Limits of this version](#17-limits-of-this-version)

## 1. What the script does, in order

1. **Checks the workstation**: PowerShell 7.2, Microsoft Graph module, Exchange Online module (Mail workload), network access, results folder, tenant domain.
2. **Signs in to the Cloudiway portal** with **your** account (masked password entry, or PAT token), detects the project and reads the existing connector. This is done **before** any write to the tenant: if Cloudiway is unreachable, nothing is modified.
3. **Signs in to the tenant** (Microsoft sign-in window, or device code) with the `-Admin365` account, and **strictly checks** that the signed-in tenant and account are the requested ones. On any mismatch it stops without reading or writing anything.
4. **Reads the tenant state** and **displays a plan**: for each item, `CREATE`, `UPDATE`, `OK`, `BLOCKED` or `IGNORED`, with the reason. With `-WhatIf`, the script stops here.
5. **Asks for confirmation**, then applies in this order: application, service principal, permissions, consent, Exchange roles, EWS list, certificate, Cloudiway connector, then cleanup of the tool's old certificates (only after the connector has been written successfully).
6. **Re-reads every item** to check compliance (including the Cloudiway connector, re-read after each write).
7. **Writes a report and a log**, without any secret, with the remaining actions.

Safeguards: a line whose dependency failed is **ignored** (never half-applied). An existing object with the expected name but without the `CloudiwayConnector` tag (created by hand) is **not modified** without `-AdoptExisting`. An existing connector is never degraded: products are merged (never removed), direction and region are never changed.

## 2. Why a single person runs it

The script needs **both** accesses at the same time:

- a **Global Administrator** account of the tenant being migrated (to create the application, grant consent, assign roles, change the Exchange configuration);
- an account **invited to the Cloudiway project**, with the **Contributor** role (to create or update the connector).

A single person (usually the customer's IT manager) therefore runs the script from start to finish, with both identities. This is a security choice: the certificate is generated **in memory on their workstation** and sent directly to Cloudiway. It goes through no file, no email, no instant message, and nobody else ever sees it.

## 3. Prerequisites

| Prerequisite | Detail |
|---|---|
| Workstation | Windows, Internet access (`graph.microsoft.com`, `login.microsoftonline.com`, `api-production.cloudiway.com`, and Exchange Online for the Mail workload). |
| PowerShell | **PowerShell 7.2 minimum** (`pwsh`). The `cloudiway-connector.cmd` launcher checks it and offers to install it with `winget`, after your confirmation. |
| `Microsoft.Graph.Authentication` module | Required. `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser`, or `-InstallMissingModules`. |
| `ExchangeOnlineManagement` module | Required for the **Mail** workload (EWS list registration). `Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser`, or `-InstallMissingModules`. |
| Microsoft 365 account | **Global Administrator** of the tenant being migrated. |
| Cloudiway account | Invited to the project with the **Contributor** role (see [section 4](#4-preliminary-step-the-invitation-to-the-cloudiway-project)). **The Cloudiway account used to run the script must not have two-factor authentication (2FA) enabled**; if it does, contact your 3SR contact before running the script (see [section 16](#16-what-has-not-yet-been-validated-in-real-conditions)). |
| Files | The whole folder (the `lib` folder must stay next to the script). Downloaded files: **unblock them** (see below). |

**Unblocking downloaded files.** Windows marks downloaded files as coming from the Internet. Before the first run, execute in PowerShell:

```powershell
Get-ChildItem -LiteralPath .\cloudiway-connector -Recurse -File | Unblock-File
```

The `cloudiway-connector.cmd` launcher does it automatically.

**The `cloudiway-connector.cmd` launcher.** Double-click it, or run it with the same options as the script (they are passed through unchanged). It works under Windows PowerShell 5.1 (the one shipped with Windows): it unblocks the files, checks that PowerShell 7.2 or later is installed, **offers to install it with `winget` after confirmation**, then starts `cloudiway-connector.ps1` under PowerShell 7. If you run `cloudiway-connector.ps1` directly from Windows PowerShell 5.1, you get a `#requires` error: use the launcher or open `pwsh`.

**Enterprise PowerShell logging.** If your workstation enables *Module Logging*, *Script Block Logging* or *Transcription*, PowerShell may record command parameters and script content, independently of this tool. The script never writes a secret to its own files, but cannot prevent that system logging: check it with your security team. As for memory, the certificate byte arrays are zeroed at the end of the run; .NET strings cannot be reliably erased and are released with the process: close the console when you are done.

## 4. Preliminary step: the invitation to the Cloudiway project

Before running the script, your 3SR contact has you invited to the Cloudiway project with the **Contributor** role.

1. You receive an invitation email from Cloudiway. Use the link it contains to **initialize your password**.
2. Sign in once to the Cloudiway portal to check that the project appears.
3. Note the email address of the invitation: it is your login (`-Cloudiway`). The project number (`-ProjectId`) is detected automatically when there is only one; with several projects, the script offers a list, or pass `-ProjectId 12345`.

**The Cloudiway account used to run the script must not have two-factor authentication (2FA) enabled.** Observed in real conditions (03/11/2026, at a customer): with 2FA, signing in to the portal from the script does not work. If it is enabled on your account, contact your 3SR contact before running the script.

## 5. Step-by-step execution

The examples use fictitious values: tenant `contoso.onmicrosoft.com`, administrator `admin365@contoso.com`, Cloudiway account `paul.bernard@contoso.com`, project `12345`. Replace them with yours. Commands are run from the script folder.

### 5.1 Optional: discover the project (`-Discover`)

Lists the connectors of the Cloudiway project, **with no tenant sign-in and no write**:

```powershell
.\cloudiway-connector.cmd -Discover -Cloudiway paul.bernard@contoso.com
```

With `-ConnectorId 123`, the configuration (secrets masked) of connector 123 is saved to `decouverte-123.json`. Useful to capture the shape of a connector created by hand.

### 5.2 First: simulate (`-WhatIf`)

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -ProjectId 12345 -Workloads Mail,OneDrive -WhatIf
```

The script signs in (Cloudiway, then the tenant), **reads** the current state, displays the **plan** and stops: **nothing is written** to the tenant or to Cloudiway. Reading the Exchange Online EWS configuration also happens during a simulation (read-only). Review the plan: each line says what would be created, updated, or blocked, and why.

### 5.3 Apply

Same command, without `-WhatIf`:

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -ProjectId 12345 -Workloads Mail,OneDrive
```

The script:

1. checks the workstation (displays a prerequisites table);
2. asks for the **Cloudiway password** (masked entry, never displayed or written);
3. opens the **Microsoft sign-in window**: sign in with the `-Admin365` account;
4. displays the plan and asks for **confirmation** (`O` to apply, as the prompts are in French);
5. applies, verifies, writes the report.

If the plan contains a `BLOCKED` line, read the reason before continuing: it says which right or option is missing.

**Consent of "Microsoft Graph Command Line Tools".** To act in your tenant, the script signs in with the Microsoft public application "Microsoft Graph Command Line Tools" and requests high delegated rights: `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `DelegatedPermissionGrant.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `User.ReadWrite.All`, `Directory.Read.All`, `Policy.Read.All`, `Organization.Read.All`. The consent you accept in the Microsoft window stays **recorded in the tenant** (for your account, or for the whole organization if you tick the corresponding box). To remove it at the end of the project: Entra > Enterprise applications > Microsoft Graph Command Line Tools > Permissions.

### 5.4 When the sign-in window picks the wrong account (`-UseDeviceCode`)

If you chain several tenants, the sign-in window may automatically pick another account. The script detects it (account or tenant different from those requested) and stops. Run again with `-UseDeviceCode`:

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -UseDeviceCode
```

The script displays an address and a code: open the address in a **private browsing window**, enter the code and sign in with `-Admin365`. For the Mail workload, the Exchange Online sign-in also uses a device code. Some tenants block this flow through Conditional Access; in that case, run again without `-UseDeviceCode`, from a clean browser session.

### 5.5 Questions mode

If a parameter is missing, **the script asks for it** (interactive console) with an example and immediate validation: tenant, administrator account, workloads, Cloudiway account. Nothing is preselected: for workloads, each one states the privileges it adds. Simply run:

```powershell
.\cloudiway-connector.cmd
```

Without an interactive console (scheduled task, pipeline), all essential parameters must be supplied (the script then displays the complete command to run again).

### 5.6 A simple check, renewing nothing (`-KeepCredentials`)

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -KeepCredentials
```

Without this option, **every run renews the certificate** (see [section 7](#7-renewal-every-run-renews-the-certificate)). With `-KeepCredentials`, the script regenerates and sends nothing as long as the connector certificate is consistent and valid for more than 30 days: it is a compliance check. If a connector update were needed (for example a missing product), the Cloudiway line is **BLOCKED**: the portal requires the certificate during an update, so run again without `-KeepCredentials`.

### 5.7 Without the Windows launcher: `pwsh` directly

The launcher is optional. From PowerShell 7:

```powershell
pwsh -NoProfile -File .\cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -WhatIf
```

With `-File`, several workloads are passed as a single comma-separated value (`Mail,OneDrive`).

## 6. Objects created and coded names

Names are **coded**: this is what makes objects reusable from one run to the next (no duplicate application or connector).

| Object | Name | Example |
|---|---|---|
| App registration and service principal | `CLOUDIWAY-SOURCE-P<project>` | `CLOUDIWAY-SOURCE-P12345` |
| Certificate (subject) | `CN=Cloudiway-SOURCE-P<project>` | `CN=Cloudiway-SOURCE-P12345` |
| Cloudiway connector | `<prefix of the .onmicrosoft.com domain>-source` | `contoso-source` |

The domain prefix is the full beginning of the tenant's `.onmicrosoft.com` domain (never truncated). The `-AppName` and `-ConnectorName` options let you choose other names. The connector carries a **tracking marker**: the file name of its certificate, of the form `CIW1_<thumbprint>_<YYYYMMDD>.pfx`, which lets the script recognize its own certificate and its expiry date.

The certificate is valid for **180 days** by default (`-ValidityDays`, from 45 to 730).

## 7. Renewal: every run renews the certificate

**Every run (outside `-WhatIf`) renews the certificate.** Concretely, at each run:

1. a **new certificate** is generated in memory and added to the application;
2. the **Cloudiway connector is updated** with this new certificate (the certificate is replaced in place);
3. the script **re-reads the connector** and only considers the write confirmed if the re-read certificate file name is the one that was sent;
4. only then are the **old certificates created by the tool** removed from the application (never before: a connector never loses its authentication). Keys added by hand are kept. The identifier (`keyId`) and thumbprint of each removed key appear in the report and the log.

**Warning: do not run the script again while migration jobs are active.** An existing connector is updated at every run; running jobs may fail while the certificate is replaced. Wait for the jobs to finish (or suspend them in the Cloudiway portal). For a simple compliance check, use `-KeepCredentials`.

If the connector write fails or cannot be confirmed, **no old certificate is removed** and the exit code is 2: run the same command again, the script resumes where it stopped.

## 8. Reading the result

On screen, then in the report:

- **Plan**: planned action for each item.
- **Application**: result of each action (`APPLIED`, `FAILED`, `IGNORED`; the tool prints these in French).
- **Verification**: re-reading of each object (`Compliant`, `To check`, `NON-COMPLIANT`).
- **To do** (`A faire`): real actions the script could not perform (for example missing admin consent, with the link to open, or the Exchange step to do by hand, with the exact commands). The group only appears when there is something to do.
- **To check** (`A verifier`): information and checks the script cannot automate (for example the certificate expiry date, or an empty EWS list).

The script only declares itself "compliant" if **everything** was re-read and confirmed. See [section 14](#14-exit-codes) for the exit codes.

## 9. The Exchange Online EWS list

For the **Mail** workload, Cloudiway uses EWS. If your organization restricts EWS to a list of applications (`EwsAllowedAppIDs`), the Cloudiway application must appear in it. The script:

1. signs in to Exchange Online with the `-Admin365` account;
2. **reads** the configuration (`Get-OrganizationConfig`), including during a simulation;
3. **adds** the application's AppID to `EwsAllowedAppIDs`: add-only, **never replacing or removing** existing entries.

**Warning: an empty list becomes restrictive.** If `EwsAllowedAppIDs` is **empty**, registering a first application in it makes it **restrictive for all the other EWS applications of the tenant** (backup tools, third-party mobile apps, etc.) that are not in it: they would be **blocked**. The script therefore asks for a **separate explicit confirmation** (default answer: no). Without confirmation, nothing is written and the line moves to "To check" with the exact commands; with `-Yes`, nothing is written either, unless you add `-AllowEwsListCreation`. If the list already contains entries, the AppID is simply added.

If `EwsEnabled` is `False` (EWS disabled for the organization), **nothing is written**: this is a tenant decision, reported under "To check".

Any Exchange failure (missing module, sign-in, read, write) is **non-blocking**: the rest is configured, the step becomes a manual "To do" with the exact commands, and the exit code is 2.

## 10. Files produced

The script writes into a `connecteur-resultats` folder next to the script (or, if the script folder is synchronized or shared, into `%LOCALAPPDATA%\CloudiwayConnector`, which it reports; `-OutDir` lets you choose). Each run creates a subfolder `<prefix>-Source-<YYYYMMDD-HHMM>` containing **only**:

| File | Content |
|---|---|
| `run.log` | Run log: prerequisites, plan, result of each step, verifications. **No secrets.** It contains the tenant name, its domain, object names and the administrator account. |
| `Rapport-<prefix>-Source.md` | Readable report: parameters, plan, result, verification, "To do" and "To check". **No secrets, no certificate content.** It contains tenant identifiers (application and service principal GUIDs, certificate thumbprint, expiry date). |
| `decouverte-<id>.json` | Only with `-Discover -ConnectorId <id>`: connector configuration, secrets masked. |

**No certificate, password or state file is written.** Since the report contains tenant identifiers, avoid a synchronized or shared folder.

## 11. Removing the objects at the end of the project

The script deletes nothing (except the tool's old certificates). **At the end of the migration project, remove the following objects yourself**, because the application has broad permissions on mailboxes and files.

**1. The Cloudiway connector.** In the Cloudiway portal, delete the connector `<prefix>-source` (or ask your 3SR contact to do it).

**2. The entry in the EWS list (Exchange Online).** Remove the application's AppID from `EwsAllowedAppIDs` (the AppID is in the report, "Valeurs a connaitre" section, and in Entra):

```powershell
Connect-ExchangeOnline -UserPrincipalName 'admin365@contoso.com'
Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs
$ids = @((Get-OrganizationConfig).EwsAllowedAppIDs) | Where-Object { $_ -and $_ -ne '<application AppID>' }
Set-OrganizationConfig -EwsAllowedAppIDs ($ids -join ',')
```

If the AppID was the only entry, the list ends up empty: refer to the Microsoft documentation of `Set-OrganizationConfig` for the procedure in that case. This case has not been exercised by the tool. If you had confirmed the creation of the list (initially empty list), keep in mind that the other EWS applications get their access back once the list is emptied.

**3. The Exchange role assignments.** In the Microsoft Entra admin center: **Roles and administrators** > **Exchange Administrator** > **Assignments**: remove the application `CLOUDIWAY-SOURCE-P<project>`. Do the same for **Exchange Recipient Administrator**.

**4. The application.** In Entra: **App registrations** > `CLOUDIWAY-SOURCE-P<project>` > **Delete**. Then check that the matching enterprise application (**Enterprise applications**) has disappeared; delete it otherwise. This deletion removes the application's permissions, consent and certificates.

**5. The consent of the Microsoft application "Microsoft Graph Command Line Tools"** (see [section 5](#5-step-by-step-execution)): Entra > Enterprise applications > Microsoft Graph Command Line Tools > Permissions: revoke the permissions granted for this project.

**6. The local results.** Delete the `connecteur-resultats` folder (it contains tenant identifiers).

## 12. Checking the script before running it

The script is delivered in **clear text**: read it before running it, in particular `lib\entra.ps1` (Entra writes), `lib\exchange.ps1` (Exchange writes) and `lib\cloudiway.ps1` (Cloudiway writes). It contains no `DELETE` call.

**SHA-256 hash.** Your 3SR contact gives you the SHA-256 hashes of the version intended for you (release notes). Compute those of your files and compare:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\cloudiway-connector.ps1, .\lib\entra.ps1, .\lib\exchange.ps1, .\lib\cloudiway.ps1 | Format-Table Hash, Path -AutoSize
```

Files are published as UTF-8 with BOM and CRLF line endings: an automatic line-ending conversion by your download tool (Git, archive) changes the hash.

**Offline tests.** `tests\run-tests.ps1` runs the script and its libraries against a fake tenant and a fake Cloudiway portal in memory (no connection, no network):

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

Allow about five minutes. The test bench checks in particular that no secret is written, that no `DELETE` request is issued, the order of operations, the verification of the certificate by file name before any removal, and the behavior of the EWS list (add-only, confirmation on an empty list).

## 13. Troubleshooting

| Symptom | Likely cause and action |
|---|---|
| `#requires` error at launch | The script is run from Windows PowerShell 5.1. Use `cloudiway-connector.cmd` or open `pwsh` (PowerShell 7.2 minimum). |
| `pwsh` not found or too old | The launcher offers installation with `winget` after confirmation; otherwise `winget install --id Microsoft.PowerShell -e`. |
| Missing module | `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser` (and `ExchangeOnlineManagement` for Mail), or `-InstallMissingModules`. |
| "Connexion refusee : le tenant ou le compte ne correspond pas" (sign-in refused: tenant or account does not match) | The sign-in window picked another account. Run again choosing exactly the `-Admin365` account, or with `-UseDeviceCode`. For a **guest** account (identifier containing `#EXT#`), `-Admin365` must be the exact identifier as the tenant displays it, and the guest must be Global Administrator **in that tenant**. |
| `AADSTS65001` | Consent was not given for "Microsoft Graph Command Line Tools": sign in again with a Global Administrator and accept the consent window. |
| `AADSTS90094` | Admin consent is required and the account is not Global Administrator (activate the role if you use PIM). |
| `AADSTS53003` | Access blocked by Conditional Access (device, location, application): use an allowed device or network, or request an exception. |
| `AADSTS50076` | Multifactor authentication required: complete the validation in the Microsoft window, then run again. |
| "Le compte n'est pas Administrateur general" (the account is not Global Administrator) | The actions that require it are **BLOCKED** in the plan and nothing is written (code 1). Use a Global Administrator account. |
| Cloudiway access impossible | Check the login, the password (initialized via the invitation), that the account is invited with the Contributor role, and `-ProjectId`. If two-factor authentication is enabled on the Cloudiway account, signing in does not work (limit observed in real conditions, see [section 16](#16-what-has-not-yet-been-validated-in-real-conditions)): contact your 3SR contact. |
| Several projects visible | Choose from the list, or pass `-ProjectId 12345`. |
| Cloudiway line `BLOCKED`: name collision | A connector with the same name designates another tenant or another application. Choose another `-ConnectorName`, or `-AdoptExisting` if you are sure. |
| Line `BLOCKED`: existing object without tag | Application or connector created by hand with the expected name. `-AdoptExisting` takes it over (the certificate and application identifier of an adopted connector are **replaced**; an extra confirmation is requested). |
| Exchange step under "To do" | Missing module, failed sign-in or write: run the commands shown under "To do", or run the same command again. Exit code 2. |
| Workstation behind a corporate proxy | The script uses the user's Windows credentials for the proxy; check the `HTTPS_PROXY` / `HTTP_PROXY` variables if the proxy requires a specific setting. Not validated in real conditions on an authenticated proxy (see [section 16](#16-what-has-not-yet-been-validated-in-real-conditions)). |
| Two launchers at the same time | Run **only one** launcher at a time: two simultaneous runs on the same project may produce duplicates (applications or connectors). Check in Entra and in the Cloudiway portal. |
| "Dossier de sortie a risque" (risky output folder) | The folder is synchronized or shared: use `-OutDir` to a local, non-synchronized folder. |

## 14. Exit codes

| Code | Meaning |
|---|---|
| `0` | Compliant: everything is applied and verified (or successful simulation). |
| `1` | Stop **before any write**: missing prerequisite, access impossible, insufficient rights, refusal, cancellation, or blocked lines with nothing applicable. |
| `2` | Applied **with items failed, ignored, blocked or non-compliant** (manual Exchange step included). Run the same command again after reading the report. |

The `cloudiway-connector.cmd` launcher passes these codes through. It adds its own: `10` (PowerShell 7.2 missing and not installed), `11` (installed but not found from this window: close it and run again), `12` (main script not found), `13` (launch impossible).

## 15. Options reference

| Option | Role |
|---|---|
| `-Mode Source` | Only value accepted in this version (default). The Target mode is not available yet. |
| `-Tenant` | `xxxx.onmicrosoft.com` domain (or verified domain) or tenant GUID. Asked if absent. |
| `-Admin365` (alias `-User`) | Global Administrator account of the tenant. The signed-in account must be exactly this one. Asked if absent. |
| `-Cloudiway` | Your login on the Cloudiway portal. The password is asked masked. Asked if absent. |
| `-CloudiwayPat` | Cloudiway personal access token (`SecureString`) instead of the password. **Not validated**: this workaround exists in the tool but has never been validated; do not rely on it as a solution to 2FA. |
| `-ProjectId` | Cloudiway project number. Detected automatically when possible. |
| `-Workloads` | `Mail`, `OneDrive`, or `All` (= both). No default value. Other workloads are rejected. |
| `-WhatIf` | Simulation: plan only, nothing is written. Do this first. |
| `-Discover` / `-ConnectorId` | Lists the project's connectors (read-only, no tenant sign-in); masked detail of one connector. |
| `-UseDeviceCode` | Graph (and Exchange) sign-in by device code. |
| `-KeepCredentials` | Compliance check: renews nothing as long as the certificate is consistent and valid for more than 30 days. |
| `-RotateCredentials` (alias `-RotateCertificate`) | No effect (renewal is the default behavior). Incompatible with `-KeepCredentials`. |
| `-AuthMethod` | `Certificate` (default, recommended), `Secret` or `Both`. Only the `Certificate` method has been validated in real conditions. |
| `-ValidityDays` | Validity of the generated credentials, 45 to 730 days (default 180). |
| `-AdoptExisting` | Allows taking over an existing application or connector without the tool's tag (replaces the connector's certificate and application identifier). |
| `-AppName`, `-ConnectorName` | Replace the coded names. |
| `-ServiceAccountName` | No effect with Mail and OneDrive in Source mode (no service account is created). |
| `-AllowEwsListCreation` | Allows, without a question, creating the EWS list when it is empty (makes it restrictive for the other EWS applications). |
| `-SkipCloudiway` | Configures the tenant only, with no Cloudiway call (`-ProjectId` required; no certificate is generated, as there is no way to send it). |
| `-ProductIds`, `-ProductMapFile` | Cloudiway product identifiers (Mail = 5, Files = 6); mapping file produced by `-Discover`. |
| `-Region` | Cloudiway server region (default 1). |
| `-CertificateTransport` | `Base64` (default) or `Path` (protected temporary file, deleted immediately). Only `Base64` is recommended. |
| `-OutDir` | Base folder of the report and the log. |
| `-InstallMissingModules` | Installs missing PowerShell modules without asking (user profile, no administrator rights). |
| `-Yes` | Skips the plan confirmation (scripted use). Never enabled implicitly. |

## 16. What has not yet been validated in real conditions

State as of 03/11/2026. This section is deliberately frank: the offline test bench covers these cases with a fake tenant and a fake portal, but a fake is not reality.

**Validated in real conditions**

- Creation and update of a **Mail + OneDrive connector in Source mode** with a certificate.
- Verification of the certificate by file name (re-reading the connector after the write).
- Cleanup of old certificates by `PATCH` (fallback, see below).
- Device code for Microsoft Graph.
- EWS write: registering the AppID in `EwsAllowedAppIDs` when the list was empty (list creation, with confirmation), on a test tenant.
- Exchange sign-in by device code.

**Not validated in real conditions, or failure observed**

- **Removal of old certificates by `POST removeKey`**: Microsoft answers `403` in real conditions. The tool then falls back to a `PATCH` that keeps only the new certificate, and **this fallback is validated in real conditions**; removal through `removeKey` is therefore not used in practice.
- **Adding the AppID to an EWS list that already contains other applications**: never exercised in real conditions (only the creation on an empty list was).
- **Password rotation of a service account**: `HTTP 403` observed on the target tenant during a trial; **not applicable** in Source with Mail and OneDrive, as no service account is created there.
- **Guest (B2B) account** as tenant administrator.
- **Workstation behind an authenticated proxy.**
- **Windows PowerShell 5.1 on a fresh workstation** (`.cmd` launcher).
- **Global Reader role**: the script requires a Global Administrator to write; the behavior with the Global Reader role alone has not been tested.

### Known limits observed

- **Two-factor authentication (2FA) on the Cloudiway account: signing in to the portal from the script DOES NOT WORK.** Observed in real conditions on 03/11/2026, at a customer. Explicit prerequisite: the Cloudiway account used to run the script must not have 2FA enabled; if it does, contact your 3SR contact. A workaround using a personal access token (`-CloudiwayPat`) exists in the tool, and the script mentions it in its error message, but it has **never been validated**: do not consider it a solution.

As a precaution, also consider as not validated in real conditions the options `-AuthMethod Secret` and `Both`, `-CertificateTransport Path` and a `-Region` other than 1: only the default configuration (certificate, Base64 transport, region 1) is described as validated above.

## 17. Limits of this version

- **Source mode only.** The Target mode is not available yet; it will come in a later version.
- **Mail and OneDrive workloads only.** The other workloads are rejected with a clear message.
- Every run renews the certificate and updates the existing connector: do not run again during active migration jobs (see [section 7](#7-renewal-every-run-renews-the-certificate)).
- The script does not remove its objects at the end of the project: the procedure is manual (see [section 11](#11-removing-the-objects-at-the-end-of-the-project)).
- No service account is created or used.
- The Cloudiway account must not have two-factor authentication enabled (see [section 16](#16-what-has-not-yet-been-validated-in-real-conditions)).
