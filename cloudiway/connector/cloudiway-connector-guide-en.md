# cloudiway-connector: user guide

Version française : [cloudiway-connector-guide-fr.md](cloudiway-connector-guide-fr.md)

`cloudiway-connector` is a PowerShell script that **configures a Microsoft 365 tenant** (a "source" or a "target") for a Cloudiway connector, then **creates or updates that connector** in your Cloudiway project. It replaces the series of manual steps described in the Cloudiway documentation (app registration, permissions, consent, Exchange roles, certificate, EWS list, service account, entering the connector in the portal).

This version (2.7) covers:

- the **Source mode** (the tenant being migrated) and the **Target mode** (the destination tenant);
- the **Mail**, **OneDrive** and **SharePoint** workloads.

The other workloads (Teams, Archive, GalSync, Intune, FreeBusy, Signature, MailRouting) are not available in this version: the script rejects them ("non disponible dans cette version", i.e. "not available in this version") before any sign-in.

**SharePoint: the Cloudiway product identifier is unknown.** Until it is supplied (`-ProductIds` or a `productmap.json` file, see [section 6](#6-the-sharepoint-workload-and-the-cloudiway-product-identifier)), the script **stops as early as possible** (code 1), **before any sign-in and any write**: nothing is created, neither in the tenant nor in Cloudiway. This also applies to `-Workloads All`.

**ONE POWERSHELL CONSOLE PER TENANT.** If you process several tenants, open a **new** PowerShell console for each one. Since version 2.7, an Exchange Online session of another tenant left open in the console **stops the script** (code 1) before any sign-in and any write (see [section 5.8](#58-one-powershell-console-per-tenant)).

**The service account is created by default as soon as Mail is requested, even in the Source tenant.** Cloudiway requires the certificate, the client secret and the administrator account together (see [section 7](#7-the-service-account)).

## Read this first: this script MODIFIES your tenant

**This is not a read-only tool.** Run without `-WhatIf`, it creates and modifies objects in your Microsoft 365 tenant, in Exchange Online and in your Cloudiway project. Here is the exact list, with the rights it gives to the application.

| # | Where | What is created or modified |
|---|---|---|
| 1 | Microsoft Entra | An **app registration** `CLOUDIWAY-SOURCE-P<project number>` or `CLOUDIWAY-TARGET-P<project number>` (tag `CloudiwayConnector`, single tenant). |
| 2 | Microsoft Entra | Its **service principal** (enterprise application). |
| 3 | Microsoft Entra | The **application permissions** declared on the registration, and their **admin consent** (see the list below). |
| 4 | Microsoft Entra | A delegated consent limited to `User.Read` (Microsoft Graph). |
| 5 | Microsoft Entra | The directory roles **Exchange Administrator** and **Exchange Recipient Administrator**, assigned **to the application's service principal** (Mail workload only). |
| 6 | Microsoft Entra | A **certificate** (RSA 2048, SHA-256, subject `CN=Cloudiway-SOURCE-P<project>` or `CN=Cloudiway-TARGET-P<project>`) **and a client secret** (`-AuthMethod Both`, the default: Cloudiway requires both), generated in memory; the public part of the certificate and the secret are added to the application. |
| 7 | Microsoft Entra | A **service account** (user, the connector's administrator account) in the cases described in [section 7](#7-the-service-account): **Mail (Source AND Target, hence also in the Source tenant)**, **OneDrive in Target mode**, **SharePoint**. This account receives the **SharePoint Administrator** directory role, and the application is set to accept public client flows. It is **never deleted by the tool**: the IT manager deletes it at the end of the project. |
| 8 | Exchange Online | The **application AppID is added to `EwsAllowedAppIDs`** (Mail workload only; add only, with confirmation and a warning if the list is empty, see [section 10](#10-the-exchange-online-ews-list)). |
| 9 | Cloudiway | A **connector** `<prefix of the .onmicrosoft.com domain>-source` or `-target` created or updated in your project (certificate, certificate password, client secret, application identifier, domain, region, Cloudiway products, and, with a service account, its identifier and password). |
| 10 | Your workstation | A results folder (`run.log` and `Rapport-...md`, no secrets); missing PowerShell modules if you use `-InstallMissingModules`; the consent of the Microsoft application "Microsoft Graph Command Line Tools" (see [section 5](#5-step-by-step-execution)). |

**Application permissions granted to the application** (least privilege computed from the mode and the chosen workloads). In **Target** mode, `Application.ReadWrite.All` and `Organization.Read.All` (Microsoft Graph) are requested in every case, in addition to the tables.

*Source mode*

| Workload | Microsoft Graph | Exchange Online | SharePoint Online |
|---|---|---|---|
| Mail | `MailboxSettings.ReadWrite` | `Exchange.ManageAsApp`, `full_access_as_app` | (none) |
| OneDrive | `User.Read.All`, `Files.ReadWrite.All`, `Sites.FullControl.All`, `Directory.Read.All` | (none) | `Sites.FullControl.All`, `User.Read.All` |
| SharePoint | `Sites.FullControl.All`, `User.Read.All`, `Group.Read.All`, `Directory.Read.All` | (none) | `Sites.FullControl.All`, `User.Read.All` |

*Target mode*

| Workload | Microsoft Graph | Exchange Online | SharePoint Online |
|---|---|---|---|
| Mail | `MailboxSettings.ReadWrite` | `full_access_as_app`, `Exchange.ManageAsApp` | (none) |
| OneDrive | `User.Read.All`, `Files.ReadWrite.All`, `Sites.FullControl.All`, `InformationProtectionPolicy.Read.All`, `Group.ReadWrite.All`, `Directory.Read.All` | `Exchange.ManageAsApp` | `Sites.FullControl.All`, `User.ReadWrite.All` |
| SharePoint | `Sites.FullControl.All`, `User.ReadWrite.All`, `Group.ReadWrite.All`, `Application.ReadWrite.All`, `Directory.Read.All` | (none) | `Sites.FullControl.All`, `User.ReadWrite.All`, `TermStore.ReadWrite.All` |

These permissions are **broad** (access to the mailboxes, files and sites of all users, with write access in Target mode): they are the ones Cloudiway requests in order to migrate. They are carried by the application, not by a named account; this is why the end of the project must include removing them ([section 12](#12-removing-the-objects-at-the-end-of-the-project)).

**What the script does not do**

- It **deletes nothing** in the tenant or in Cloudiway, with **one single exception**: the **old certificates and old client secrets created by the tool itself** (name starting with `Cloudiway-SOURCE-P<project>` or `Cloudiway-TARGET-P<project>`) are removed from the application, after the new certificate and the new secret have been successfully written to the connector and verified (certificates: proof of possession or `PATCH` fallback; secrets: `removePassword`, with a re-read and a wait for Entra propagation). Any other application key (added by hand) is kept. The service account is never deleted by the tool (the IT manager deletes it at the end of the project, [section 12](#12-removing-the-objects-at-the-end-of-the-project)).
- It **does not write, display or log any secret**: the certificate, its password, the client secret and the service account password are generated in memory, sent directly to Cloudiway, then erased. No `.pfx` file, no password, no state is written to disk.
- It **reads no mailbox or file content**. It reads configuration: organization, applications, service principals, users and roles, permission grants, the Exchange Online EWS configuration, the list of Cloudiway projects and connectors.
- It **assigns no license**, including to the service account.
- It does not modify or disable any conditional access policy, multifactor authentication, or the tenant's security defaults.

**Always start with `-WhatIf`**: the script then displays the complete plan (what it would create or modify) without writing anything. See [section 5](#5-step-by-step-execution).

## Contents

1. [What the script does, in order](#1-what-the-script-does-in-order)
2. [Why a single person runs it](#2-why-a-single-person-runs-it)
3. [Prerequisites](#3-prerequisites)
4. [Preliminary step: the invitation to the Cloudiway project](#4-preliminary-step-the-invitation-to-the-cloudiway-project)
5. [Step-by-step execution](#5-step-by-step-execution)
6. [The SharePoint workload and the Cloudiway product identifier](#6-the-sharepoint-workload-and-the-cloudiway-product-identifier)
7. [The service account](#7-the-service-account)
8. [Objects created and coded names](#8-objects-created-and-coded-names)
9. [Renewal: every run renews the certificate and the secret](#9-renewal-every-run-renews-the-certificate-and-the-secret)
10. [The Exchange Online EWS list](#10-the-exchange-online-ews-list)
11. [Reading the result and files produced](#11-reading-the-result-and-files-produced)
12. [Removing the objects at the end of the project](#12-removing-the-objects-at-the-end-of-the-project)
13. [Checking the script before running it](#13-checking-the-script-before-running-it)
14. [Troubleshooting](#14-troubleshooting)
15. [Exit codes](#15-exit-codes)
16. [Options reference](#16-options-reference)
17. [What is validated in real conditions, and what is not](#17-what-is-validated-in-real-conditions-and-what-is-not)
18. [Limits of this version](#18-limits-of-this-version)

## 1. What the script does, in order

1. **Checks the workstation**: PowerShell 7.2, Microsoft Graph module, Exchange Online module (Mail workload), network access, results folder, tenant domain. It stops at this stage (code 1) if an Exchange Online session of another tenant is already open in the console.
2. **Signs in to the Cloudiway portal** with **your** account (masked password, or PAT token), detects the project and reads the existing connector. This step happens **before** any write to the tenant: if Cloudiway is unreachable, nothing is modified.
3. **Signs in to the tenant** (Microsoft sign-in window, or device code) with the `-Admin365` account, and **strictly checks** that the signed-in tenant and account are the requested ones. In case of mismatch, it stops without reading or writing anything.
4. **Reads the tenant state** and **displays a plan**: for each item, `CREATE`, `UPDATE`, `OK`, `BLOCKED` or `IGNORED`, with the reason. With `-WhatIf`, the script stops here.
5. **Asks for confirmation**, then applies in this order: application, service principal, permissions, consent, Exchange roles, EWS list, certificate, service account, service account password (reset **before** the connector is written, see [section 7](#7-the-service-account)), Cloudiway connector, then cleanup of the tool's old certificates and secrets (only after the connector has been successfully written).
6. **Re-reads each item** to check compliance (including the Cloudiway connector, re-read after each write).
7. **Writes a report and a log**, without any secret, with the remaining actions.

Safeguards: a line whose dependency failed is **ignored** (never half-applied). An existing object with the expected name but without the `CloudiwayConnector` tag (created by hand) is **not modified** without `-AdoptExisting`. An existing connector is never degraded: products are merged (never removed), direction and region are never modified.

## 2. Why a single person runs it

The script needs **two accesses at the same time**:

- a **Global Administrator** account of the tenant to configure (to create the application, grant consent, assign roles, create the service account, change the Exchange configuration);
- a **guest account on the Cloudiway project**, with the **Contributor** role (to create or update the connector).

A single person (usually the customer's IT manager) therefore runs the script from start to finish, with both identities. This is a security choice: the certificate and the service account password are generated **in memory on their workstation** and sent directly to Cloudiway. They go through no file, no e-mail, no instant messaging, and nobody else knows them.

## 3. Prerequisites

| Prerequisite | Detail |
|---|---|
| Workstation | Windows, Internet access (`graph.microsoft.com`, `login.microsoftonline.com`, `api-production.cloudiway.com`, and Exchange Online for the Mail workload). |
| PowerShell | **PowerShell 7.2 minimum** (`pwsh`). The `cloudiway-connector.cmd` launcher checks it and offers to install it with `winget`, after your confirmation. |
| `Microsoft.Graph.Authentication` module | Required. `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser`, or `-InstallMissingModules`. |
| `ExchangeOnlineManagement` module | Required for the **Mail** workload (EWS list registration). `Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser`, or `-InstallMissingModules`. |
| Microsoft 365 account | **Global Administrator** of the tenant to configure. |
| Cloudiway account | Guest on the project with the **Contributor** role (see [section 4](#4-preliminary-step-the-invitation-to-the-cloudiway-project)). **The Cloudiway account used to run the script must not have two-factor authentication (2FA) enabled**; if it does, contact your 3SR contact before running the script (see [section 17](#17-what-is-validated-in-real-conditions-and-what-is-not)). |
| Console | **One PowerShell console per tenant** (see [section 5.8](#58-one-powershell-console-per-tenant)). |
| Files | The complete folder (the `lib` folder must stay next to the script). Downloaded files: **unblock them** (see below). |

**Unblocking downloaded files.** Windows marks downloaded files as coming from the Internet. Before the first run, execute in PowerShell:

```powershell
Get-ChildItem -LiteralPath .\cloudiway-connector -Recurse -File | Unblock-File
```

The `cloudiway-connector.cmd` launcher does it automatically.

**The `cloudiway-connector.cmd` launcher.** Double-click it, or run it with the same options as the script (they are passed through unchanged). It works from Windows PowerShell 5.1 (the one shipped with Windows): it unblocks the files, checks that PowerShell 7.2 or later is installed, **offers to install it with `winget` after confirmation**, then runs `cloudiway-connector.ps1` under PowerShell 7. If you run `cloudiway-connector.ps1` directly from Windows PowerShell 5.1, you get a `#requires` error: use the launcher or open `pwsh`.

**Enterprise PowerShell logging.** If your workstation enables *Module Logging*, *Script Block Logging* or *Transcription*, PowerShell may record command parameters and script contents, independently of this tool. The script never writes a secret to its own files, but cannot prevent this system logging: check it with your security team. As for memory, the certificate byte arrays are zeroed at the end of the run; .NET strings cannot be reliably erased and are released with the process: close the console when you are done.

## 4. Preliminary step: the invitation to the Cloudiway project

Before running the script, your 3SR contact has you invited to the Cloudiway project with the **Contributor** role.

1. You receive an invitation e-mail from Cloudiway. Use the link it contains to **initialize your password**.
2. Sign in once to the Cloudiway portal to check that the project appears.
3. Note the e-mail address of the invitation: it is your identifier (`-Cloudiway`). The project number (`-ProjectId`) is detected automatically when there is only one; with several projects, the script offers a list, or pass `-ProjectId 12345`.

**The Cloudiway account used to run the script must not have two-factor authentication (2FA) enabled.** Observed in real conditions (03/11/2026, at a customer): with 2FA, signing in to the portal from the script does not work. If it is enabled on your account, contact your 3SR contact before running the script.

## 5. Step-by-step execution

The examples use fictitious values: tenant `contoso.onmicrosoft.com`, administrator `admin365@contoso.com`, Cloudiway account `paul.bernard@contoso.com`, project `12345`. Replace them with yours. Commands are run from the script folder. For a **target** tenant, replace `-Mode Source` with `-Mode Target`.

### 5.1 Optional: discover the project (`-Discover`)

Lists the connectors of the Cloudiway project, **without any sign-in to the tenant and without any write**:

```powershell
.\cloudiway-connector.cmd -Discover -Cloudiway paul.bernard@contoso.com
```

With `-ConnectorId 123`, the (masked) configuration of connector 123 is saved to `decouverte-123.json`. Useful to record the shape of a connector created by hand.

### 5.2 First: simulate (`-WhatIf`)

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -ProjectId 12345 -Workloads Mail,OneDrive -WhatIf
```

The script signs in (Cloudiway, then the tenant), **reads** the current state, displays the **plan** and stops: **nothing is written** to the tenant or to Cloudiway. The Exchange Online EWS configuration is also read during the simulation (read only). Read the plan: each line says what would be created, updated, or blocked, and why.

### 5.3 Apply

Same command, without `-WhatIf`:

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -ProjectId 12345 -Workloads Mail,OneDrive
```

The script:

1. checks the workstation (displays a prerequisites table);
2. asks for the **Cloudiway password** (masked input, never displayed or written);
3. opens the **Microsoft sign-in window**: sign in with the `-Admin365` account;
4. displays the plan and asks for **confirmation** (`O` to apply);
5. applies, verifies, writes the report.

If the plan contains a `BLOCKED` line, read the reason before continuing: it says which right or option is missing.

**After each run of the script, resubmit the connector audit in the Cloudiway portal, and check that the project license limit is not 0** ("Project Settings").

**Consent of "Microsoft Graph Command Line Tools".** To act in your tenant, the script signs in with the public Microsoft application "Microsoft Graph Command Line Tools" and requests high delegated rights: `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `DelegatedPermissionGrant.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `User.ReadWrite.All`, `Directory.Read.All`, `Policy.Read.All`, `Organization.Read.All`. The consent you accept in the Microsoft window stays **recorded in the tenant** (for your account, or for the whole organization if you tick the corresponding box). To remove it at the end of the project: Entra > Enterprise applications > Microsoft Graph Command Line Tools > Permissions.

### 5.4 When the sign-in window picks the wrong account (`-UseDeviceCode`)

If you process several tenants one after another, the sign-in window may automatically pick another account. The script detects it (account or tenant different from the requested ones) and stops. Run again with `-UseDeviceCode`:

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -UseDeviceCode
```

The script displays an address and a code: open the address in a **private browsing window**, enter the code and sign in with `-Admin365`. For the Mail workload, the Exchange Online sign-in also uses a device code. Some tenants block this flow through conditional access; in that case, run again without `-UseDeviceCode`, from a clean browser session.

### 5.5 Questions mode

If a parameter is missing, **the script asks the question** (interactive console) with an example and immediate validation: source or target, tenant, administrator account, workloads, Cloudiway account. Nothing is preselected: for the workloads, each one states the privileges it adds. Simply run:

```powershell
.\cloudiway-connector.cmd
```

Without an interactive console (scheduled task, pipeline), all the essential parameters must be supplied (the script then displays the complete command to run again).

### 5.6 A simple check, renewing nothing (`-KeepCredentials`)

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -KeepCredentials
```

Without this option, **every run renews the certificate** (see [section 9](#9-renewal-every-run-renews-the-certificate-and-the-secret)). With `-KeepCredentials`, the script regenerates and sends nothing as long as the connector certificate is consistent and valid for more than 30 days: it is a compliance check. If a connector update were needed (for example a missing product), the Cloudiway line is **BLOCKED**: the portal requires the certificate during an update, so run again without `-KeepCredentials`.

### 5.7 Without the Windows launcher: `pwsh` directly

The launcher is optional. From PowerShell 7:

```powershell
pwsh -NoProfile -File .\cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -WhatIf
```

With `-File`, several workloads are passed as a single comma-separated value (`Mail,OneDrive`).

### 5.8 One PowerShell console per tenant

**Open a NEW PowerShell console for each tenant** (for example three sources and one target: four consoles). An Exchange Online session opened for a tenant stays open in the console: the script deliberately does not disconnect it (the disconnect command can crash the process with a device code) and cannot reuse it for another tenant.

Since version 2.7, if an Exchange Online session of **another tenant** (or another account) is already open in the console, the script **stops dead at the prerequisites step, with exit code `1`, before any sign-in, any write and any question**, and asks you to open a **NEW** console for this tenant and run the same command again. A session of the **same** tenant and the **same** account is reused without a new sign-in. A Microsoft Graph context inherited from another tenant is logged, reported and cleanly disconnected: it is never used to write.

The advanced option `-AllowForeignSession` (consultant use, off by default) restores the former non-blocking behavior (warning, manual EWS step, code 2); do not use it in normal operation. Close the console when you are done with a tenant.

## 6. The SharePoint workload and the Cloudiway product identifier

A Cloudiway connector declares its workloads through **product identifiers** (`rawProductList`). Known to the tool: **Mail = 5** and **Files (OneDrive) = 6**. The Cloudiway product identifier for **SharePoint (Sites)** is **unknown** to date: the tool does not guess it (mapping it to product 6 would give the illusion of SharePoint support that does not exist on the connector). The same applies to the other workloads whose product is unknown (they are rejected in this version anyway).

**Consequence: fast stop.** If you request SharePoint (or `-Workloads All`, which includes it) without supplying the identifier:

- the script **stops at step 1, with exit code `1`, before any sign-in and any write**;
- the message is "l'identifiant du produit Cloudiway pour SharePoint n'est pas connu : relancez avec -ProductIds ou un fichier ProductMap.json, ou retirez SharePoint de -Workloads" (the product identifier for SharePoint is not known: run again with -ProductIds or a ProductMap.json file, or remove SharePoint from -Workloads);
- **nothing is created or modified**: no application, no role, no service account in the tenant, no connector in Cloudiway, including for Mail and OneDrive requested at the same time; no certificate or secret is generated.

(This rule does not apply with `-SkipCloudiway`, which configures the tenant only and declares no connector.)

**Supplying the identifier** (it is given to you by Cloudiway; ask your 3SR contact):

- `-ProductIds 5,6,<identifier>`: the **complete** list of products to declare on the connector;
- or a JSON file: `-ProductMapFile .\productmap.json`, which only overrides the workloads it names (Mail = 5 and OneDrive = 6 keep their value). If a file named **`productmap.json`** is placed next to the script, it is used automatically.

File format (a workload, then an identifier or a list of identifiers):

```json
{ "SharePoint": 12 }
```

The `productmap.example.json` file shipped with the script is an **example whose values are FICTITIOUS** (`99999`, and an `_exemple_fictif_...` key ignored by the tool): **do not copy it as is** to `productmap.json`, replace the value with the real identifier supplied by Cloudiway. The file is checked **before any sign-in** (file not found, invalid JSON or non-numeric value: stop with a message, code 1).

The real SharePoint product identifier and SharePoint migration have **not been validated in real conditions** (see [section 17](#17-what-is-validated-in-real-conditions-and-what-is-not)).

## 7. The service account

Cloudiway requires **together**, for the Mail workload, **in Source as in Target**: the **certificate** (and the PFX password), the **client secret** and the connector's **administrator account**. Real finding of 04/11/2026: the audit of a user only started after the administrator account was entered on the **Source** connector. The script therefore creates a **service user account** (the connector's administrator account) **by default** in these cases:

| Mode | Workloads that create a service account |
|---|---|
| Source | **Mail**, SharePoint |
| Target | **Mail**, OneDrive, SharePoint |

**This account is therefore created as soon as Mail is requested, including in the Source tenant.** It is **never deleted by the tool**: the IT manager deletes it at the end of the project ([section 12](#12-removing-the-objects-at-the-end-of-the-project)). With **OneDrive in Source alone**, no service account is created.

**What is created**

- A **user** `svc-ciw-<mode>-p<project>@<.onmicrosoft.com domain>` (for example `svc-ciw-source-p12345@contoso.onmicrosoft.com`), display name `Cloudiway Source P12345`, tagged (`employeeType`) so that the tool recognizes it.
- A **generated password** (24 characters), **never displayed, never written**, sent directly to the Cloudiway connector (migration account). The password **never expires**.
- **No license**: the script never assigns one.
- The **SharePoint Administrator** directory role assigned to this account.
- On the application: **public client flows** are allowed (needed for the service account to authenticate).
- The advanced option `-WithoutServiceAccount` (advanced use, off by default) lets you do without it for Mail anyway, with the warning "Cloudiway exige le compte administrateur : l'audit ne démarrera pas" (Cloudiway requires the administrator account: the audit will not start); it does not remove the account for SharePoint nor for OneDrive in Target.
- The name (`-ServiceAccountName`) can be changed, but its local part must **always** start with `svc-ciw-`, even with `-AdoptExisting`: the script never creates or modifies an account with an arbitrary name (for example a real user).

**Security defaults, multifactor authentication (MFA) and conditional access.** The service account signs in **without interaction**: it cannot answer an MFA prompt.

- If the tenant's **security defaults** are **enabled**, MFA is imposed on all accounts, **service account included**: the **OneDrive and SharePoint** jobs of that tenant **will fail** at the service account authentication; **mail** (Mail) is not affected. The script displays a **visible warning** when showing the plan and as the **first line of "To check"** in the report. Options: (1) disable the security defaults in favor of a **targeted conditional access policy that excludes the service account**, or (2) give up OneDrive and SharePoint for this tenant. The script **never** modifies this setting.
- If a conditional access policy imposes MFA on this account, exclude it. The script does not guess your tenant's policy and never modifies it; never disable MFA for the tenant itself.

**On a re-run: the password is reset BEFORE it is sent.** When a run must send a password to the connector (default renewal), the script resets it **in Entra first** and sends it to the connector **only if Entra accepted it**.

- **If Entra refuses** (for example `HTTP 403`): **the connector is not modified**. The tool **touches neither the connector nor the old certificate**: the connector keeps its old certificate and its old password, no `PUT` is sent, the old certificate is not removed from the application. The new certificate already added to the application is kept for the next run. The exit code is `2`.
- **Running again with `-KeepCredentials` changes nothing.** Reset the service account password by hand (Microsoft Entra admin center), enter it again in the Cloudiway portal (migration account of the connector), then run again.
- **Validated once in real conditions**: on a test tenant in Target mode, two successive re-runs reset the service account password successfully (exit code `0`, connector updated). The guard above stays in place if Entra refuses, no more. The script no longer creates the service account when the run stops for an unknown product identifier. If an existing account was **adopted** (`-AdoptExisting`), the tool never resets its password: enter it in the connector, on the Cloudiway portal.

## 8. Objects created and coded names

Names are **coded**: this is what makes objects reusable from one run to the next (no duplicate application, account or connector). Do not rename them.

| Object | Name | Example |
|---|---|---|
| App registration and service principal | `CLOUDIWAY-SOURCE-P<project>` or `CLOUDIWAY-TARGET-P<project>` | `CLOUDIWAY-SOURCE-P12345` |
| Certificate (subject) | `CN=Cloudiway-SOURCE-P<project>` or `CN=Cloudiway-TARGET-P<project>` | `CN=Cloudiway-SOURCE-P12345` |
| Client secret (name) | `Cloudiway-SOURCE-P<project> <date>` or `Cloudiway-TARGET-P<project> <date>` | `Cloudiway-SOURCE-P12345 20270430` |
| Service account (if created) | `svc-ciw-<mode>-p<project>@<.onmicrosoft.com domain>` | `svc-ciw-source-p12345@contoso.onmicrosoft.com` |
| Cloudiway connector | `<prefix of the .onmicrosoft.com domain>-source` or `-target` | `contoso-source` |

The domain prefix is the full beginning of the tenant's `.onmicrosoft.com` domain (never truncated). The `-AppName`, `-ServiceAccountName` and `-ConnectorName` options let you choose other names. The connector carries a **tracking marker**: the file name of its certificate, of the form `CIW1_<thumbprint>_<YYYYMMDD>.pfx`, which lets the script recognize its own certificate and its expiry date.

The certificate and the client secret are valid for **180 days** by default (`-ValidityDays`, 45 to 730).

## 9. Renewal: every run renews the certificate and the secret

**Every run (except `-WhatIf`) renews the credentials**: the certificate and, with the default `Both` method, the client secret. Concretely, at each run:

1. a **new certificate** and a **new client secret** are generated in memory and added to the application;
2. if a service account exists, its **password is reset in Entra before the connector is written** (see [section 7](#7-the-service-account) for the refusal case);
3. the **Cloudiway connector is updated** with the new certificate, its password and the new secret (the certificate is replaced in place);
4. the script **re-reads the connector** and only considers the write confirmed if the re-read certificate file name is the one that was sent;
5. only then, the **old certificates and old secrets created by the tool** are removed from the application (never before: a connector never loses its authentication); for secrets, the script re-reads the application and waits for Entra propagation. Keys added by hand are kept. The identifier (`keyId`) and thumbprint of each removed key appear in the report and the log.

**Expected result after a re-run: a single certificate and a single client secret** in the application, a certificate **marker** that changes (file name `CIW1_...`), and **the same connector** (it is not recreated). Observed in real conditions in Source and in Target (see [section 17](#17-what-is-validated-in-real-conditions-and-what-is-not)).

**The client secret is masked by the Cloudiway portal**: it cannot be read back to check that it was taken into account. The proof is the **start of the connector audit** in the portal: **resubmit the audit after each update of the connector**, and check that the project license limit is not 0 ("Project Settings").

**Warning: do not run the script again while migration jobs are active.** An existing connector is updated at each run; running jobs may fail during the replacement of the certificate, of the secret (and of the service account password). Wait for the jobs to finish (or suspend them in the Cloudiway portal). For a simple compliance check, use `-KeepCredentials`.

If writing the connector fails or cannot be confirmed, **no old certificate or secret is removed** and the exit code is 2: run the same command again, the script resumes where it stopped.

## 10. The Exchange Online EWS list

For the **Mail** workload, Cloudiway uses EWS. If your organization restricts EWS to a list of applications (`EwsAllowedAppIDs`), the Cloudiway application must be in it. The script:

1. signs in to Exchange Online with the `-Admin365` account;
2. **reads** the configuration (`Get-OrganizationConfig`), including during simulation;
3. **adds** the application AppID to `EwsAllowedAppIDs`: add only, **never replacing or removing** existing entries.

**Warning: an empty list becomes restrictive.** If `EwsAllowedAppIDs` is **empty**, registering a first application in it makes it **restrictive for all the other EWS applications of the tenant** (backup tools, third-party mobile apps, etc.) that are not in it: they would be **blocked**. The script therefore asks for a **separate explicit confirmation** (default answer: no). Without confirmation, nothing is written and the line moves to "To check" with the exact commands; with `-Yes`, nothing is written either, unless you add `-AllowEwsListCreation`. If the list already contains entries, the AppID is simply added. **By default, an empty list is therefore never created**: the EWS step is ignored ("To check", exit code 2) unless explicitly confirmed or `-AllowEwsListCreation` is used.

If `EwsEnabled` is `False` (EWS disabled for the organization), **nothing is written**: this is a tenant decision, reported under "To check".

Any Exchange failure (missing module, sign-in, read, write) is **non-blocking**: the rest is configured, the step becomes a manual "To do" with the exact commands, and the exit code is 2. The manual commands end with a tip: close the PowerShell console after use.

Allow 5 to 10 minutes for propagation on the Microsoft side after the addition.

## 11. Reading the result and files produced

On screen, then in the report:

- **Plan**: planned action for each item.
- **Application**: result of each action (`APPLIED`, `FAILED`, `IGNORED`; the tool prints these in French).
- **Verification**: re-reading of each object (`Compliant`, `To check`, `NON-COMPLIANT`).
- **To do** (`A faire`): real actions the script could not perform (for example missing admin consent, with the link to open, or the Exchange step to do by hand, with the exact commands). The group only appears when there is something to do.
- **To check** (`A verifier`): information and checks the script cannot automate (for example the security defaults warning, as the first line, the certificate expiry date, or an empty EWS list).

The script only declares itself "compliant" if **everything** has been re-read and confirmed. See [section 15](#15-exit-codes) for the exit codes.

The script writes to a `connecteur-resultats` folder next to the script (or, if the script folder is synchronized or shared, to `%LOCALAPPDATA%\CloudiwayConnector`, which it reports; `-OutDir` lets you choose). Each run creates a `<prefix>-<Source|Target>-<YYYYMMDD-HHMM>` subfolder containing **only**:

| File | Content |
|---|---|
| `run.log` | Run log: prerequisites, plan, result of each step, verifications. **No secret.** It contains the tenant name, its domain, object names, the administrator account and the migration account. |
| `Rapport-<prefix>-<Source\|Target>.md` | Readable report: parameters, plan, result, verification, "To do" and "To check". **No secret, no certificate content.** It contains tenant identifiers (GUIDs of the application and service principal, certificate thumbprint, expiry date). |
| `decouverte-<id>.json` | Only with `-Discover -ConnectorId <id>`: connector configuration, secrets masked. |

**No certificate, password or state file is written.** Since the report contains tenant identifiers, avoid a synchronized or shared folder.

## 12. Removing the objects at the end of the project

The script deletes nothing (apart from the tool's old certificates). **At the end of the migration project, remove the following objects yourself**, because the application has extended permissions on mailboxes, files and sites, and the service account has an administration role.

**1. The Cloudiway connector.** In the Cloudiway portal, delete the connector `<prefix>-source` or `<prefix>-target` (or ask your 3SR contact to do it).

**2. The EWS list entry (Exchange Online)** (Mail workload). Remove the application AppID from `EwsAllowedAppIDs` (the AppID is in the report, "Valeurs à connaître" section, and in Entra):

```powershell
Connect-ExchangeOnline -UserPrincipalName 'admin365@contoso.com'
Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs
$ids = @((Get-OrganizationConfig).EwsAllowedAppIDs) | Where-Object { $_ -and $_ -ne '<application AppID>' }
Set-OrganizationConfig -EwsAllowedAppIDs ($ids -join ',')
```

If the AppID was the only entry, the list ends up empty: consult the Microsoft documentation of `Set-OrganizationConfig` for the procedure to follow in that case. This case has not been exercised by the tool. If you had confirmed the creation of the list (initially empty list), note that the other EWS applications regain their access once the list is emptied. Then close the console (do not reuse it for another tenant).

**3. The service account** (created as soon as Mail is requested, in Source as in Target, as well as for OneDrive in Target and SharePoint; the tool never deletes it). In the Microsoft Entra admin center:

1. **Roles and administrators** > **SharePoint Administrator** > **Assignments**: **remove the service account** `svc-ciw-<mode>-p<project>` from the role;
2. **Users**: **delete the service account** `svc-ciw-<mode>-p<project>`.

Remove the role first, then the account: the account carries a never-expiring password and an administration role, it must not outlive the project.

**4. The Exchange role assignments** (Mail workload). In the Microsoft Entra admin center: **Roles and administrators** > **Exchange Administrator** > **Assignments**: remove the application `CLOUDIWAY-<SOURCE|TARGET>-P<project>`. Do the same for **Exchange Recipient Administrator**.

**5. The application.** In Entra: **App registrations** > `CLOUDIWAY-<SOURCE|TARGET>-P<project>` > **Delete**. Then check that the corresponding enterprise application (**Enterprise applications**) is gone; delete it otherwise. This deletion removes the application permissions, consent and certificates.

**6. The consent of the Microsoft application "Microsoft Graph Command Line Tools"** (see [section 5.3](#53-apply)): Entra > Enterprise applications > Microsoft Graph Command Line Tools > Permissions: revoke the permissions granted for this project.

**7. The local results.** Delete the `connecteur-resultats` folder (it contains tenant identifiers).

Repeat the procedure for **each tenant** processed (sources and target).

## 13. Checking the script before running it

The script is delivered in **clear text**: read it before running it, in particular `lib\entra.ps1` (Entra writes), `lib\exchange.ps1` (Exchange writes) and `lib\cloudiway.ps1` (Cloudiway writes). It contains no `DELETE` call.

**SHA-256 hash.** Your 3SR contact gives you the SHA-256 hashes of the version intended for you (release notes). Compute those of your files and compare:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\cloudiway-connector.ps1, .\lib\entra.ps1, .\lib\exchange.ps1, .\lib\cloudiway.ps1 | Format-Table Hash, Path -AutoSize
```

The files are published as UTF-8 with BOM and CRLF line endings: an automatic line-ending conversion by your download tool (Git, archive) changes the hash.

**Offline tests.** `tests\run-tests.ps1` runs the script and its libraries against a fake tenant and a fake Cloudiway portal in memory (no sign-in, no network, neither the Microsoft Graph nor the ExchangeOnlineManagement module required):

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

Allow about ten minutes. The test suite checks in particular that no secret is written, that no `DELETE` request is sent, the order of operations, the certificate verification by file name before any removal, the service account behavior (creation, guard on a refused password reset), the EWS list (add only, confirmation on an empty list), the Source and Target modes, and the fast stop for SharePoint without a product identifier.

## 14. Troubleshooting

| Symptom | Probable cause and action |
|---|---|
| `#requires` error at launch | The script is run from Windows PowerShell 5.1. Use `cloudiway-connector.cmd` or open `pwsh` (PowerShell 7.2 minimum). |
| `pwsh` not found or too old | The launcher offers installation with `winget` after confirmation; otherwise `winget install --id Microsoft.PowerShell -e`. |
| Missing module | `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser` (and `ExchangeOnlineManagement` for Mail), or `-InstallMissingModules`. |
| "Charge de travail non disponible dans cette version" (workload not available in this version) | Teams, Archive, GalSync, Intune, FreeBusy, Signature and MailRouting are rejected. Available: Mail, OneDrive, SharePoint. No sign-in was attempted. |
| "L'identifiant du produit Cloudiway pour SharePoint n'est pas connu" (code 1, before any sign-in) | See [section 6](#6-the-sharepoint-workload-and-the-cloudiway-product-identifier): supply `-ProductIds` or `productmap.json`, or remove SharePoint from `-Workloads`. Nothing was created. |
| The audit does not start in the Cloudiway portal | The client secret is masked by the portal: the proof that it was taken into account is the start of the audit. Resubmit the audit after each update of the connector. Check that `-AuthMethod` is `Both` (default): `Certificate` or `Secret` alone are not recommended. |
| "Table de produits illisible" (product table unreadable) | The `productmap.json` file or `-ProductMapFile` is not found, is not valid JSON, or contains a non-numeric value. Stop before any sign-in (code 1). |
| "Connexion refusée : le tenant ou le compte ne correspond pas" (sign-in refused: tenant or account mismatch) | The sign-in window picked another account. Run again choosing exactly the `-Admin365` account, or with `-UseDeviceCode`. For a **guest** account (identifier containing `#EXT#`), `-Admin365` must be the exact identifier as the tenant displays it, and the guest must be Global Administrator **in that tenant**. |
| Stop at the prerequisites step (code 1): Exchange Online session of another tenant | An Exchange Online session of another tenant (or another account) is open in the console. Close the console, open a **new** one for this tenant, run the same command again (see [section 5.8](#58-one-powershell-console-per-tenant)). |
| Warning "Valeurs de sécurité par défaut ACTIVES" (security defaults ACTIVE) | MFA is imposed on all accounts, service account included: the OneDrive and SharePoint jobs of this tenant will fail; mail will not. See [section 7](#7-the-service-account). The script never modifies this setting. |
| "Le mot de passe du compte de service n'a pas pu être changé dans Entra" (the service account password could not be changed in Entra) | Entra refuses the password reset (for example HTTP 403). The connector is not modified and the old certificate is not removed; `-KeepCredentials` changes nothing. Reset the password by hand, enter it again in the Cloudiway portal, then run again (see [section 7](#7-the-service-account)). |
| `AADSTS65001` | Consent was not given for "Microsoft Graph Command Line Tools": sign in again with a Global Administrator and accept the consent window. |
| `AADSTS90094` | Admin consent is required and the account is not a Global Administrator (activate the role if you go through PIM). |
| `AADSTS53003` | Access blocked by conditional access (device, location, application): use an allowed device or network, or request an exception. |
| `AADSTS50076` | Multifactor authentication required: complete the validation in the Microsoft window then run again. |
| "Le compte n'est pas Administrateur général" (the account is not Global Administrator) | The actions that require it are **BLOCKED** in the plan and nothing is written (code 1). Use a Global Administrator account. |
| Cloudiway access impossible | Check the identifier, the password (initialized via the invitation), that the account is invited with the Contributor role, and `-ProjectId`. If two-factor authentication is enabled on the Cloudiway account, sign-in does not work (limit observed in real conditions, see [section 17](#17-what-is-validated-in-real-conditions-and-what-is-not)): contact your 3SR contact. |
| Several projects visible | Choose from the list, or pass `-ProjectId 12345`. |
| Cloudiway line `BLOCKED`: name collision | A connector with the same name designates another tenant or another application. Choose another `-ConnectorName`, or `-AdoptExisting` if you are sure. |
| Line `BLOCKED`: existing object without tag | Application, service account or connector created by hand with the expected name. `-AdoptExisting` takes it over (the certificate, application identifier and migration account password of an adopted connector are **replaced**; an extra confirmation is requested). |
| Exchange step under "To do" | Missing module, failed sign-in or write: run the commands shown under "To do", or run the same command again. Exit code 2. |
| Workstation behind a corporate proxy | The script uses the user's Windows credentials for the proxy; check the `HTTPS_PROXY` / `HTTP_PROXY` variables if the proxy requires a particular setting. Not validated in real conditions on an authenticated proxy (see [section 17](#17-what-is-validated-in-real-conditions-and-what-is-not)). |
| Two launchers at the same time | Run **only one** launcher at a time: two simultaneous runs on the same project can produce duplicates (applications or connectors). Check in Entra and in the Cloudiway portal. |
| "Dossier de sortie à risque" (risky output folder) | The folder is synchronized or shared: use `-OutDir` towards a local, non-synchronized folder. |

## 15. Exit codes

| Code | Meaning |
|---|---|
| `0` | Compliant: everything is applied and verified (or successful simulation). |
| `1` | Stop **before any write**: missing prerequisite, access impossible, insufficient rights, refusal, cancellation, or blocked lines with nothing applicable. |
| `2` | Applied **with items failed, ignored, blocked or non-compliant** (manual Exchange step included, blocked Cloudiway line included). Run the same command again after reading the report. |

The `cloudiway-connector.cmd` launcher passes these codes through. It adds its own codes: `10` (PowerShell 7.2 absent and not installed), `11` (installed but not found from this window: close it and run again), `12` (main script not found), `13` (launch impossible).

## 16. Options reference

| Option | Role |
|---|---|
| `-Mode` | `Source` (tenant to migrate) or `Target` (destination tenant). Asked if absent. |
| `-Tenant` | `xxxx.onmicrosoft.com` domain (or verified domain) or tenant GUID. Asked if absent. |
| `-Admin365` (alias `-User`) | Global Administrator account of the tenant. The signed-in account must be exactly this one. Asked if absent. |
| `-Cloudiway` | Your identifier on the Cloudiway portal. The password is asked masked. Asked if absent. |
| `-CloudiwayPat` | Cloudiway personal access token (`SecureString`) instead of the password. **Not validated**: this workaround exists in the tool but has never been validated; do not use it as a solution to 2FA. |
| `-ProjectId` | Cloudiway project number. Detected automatically if possible. |
| `-Workloads` | `Mail`, `OneDrive`, `SharePoint`, or `All` (= the three). No default value. Other workloads are rejected. SharePoint (hence `All`) without a product identifier: fast stop, code 1. |
| `-WhatIf` | Simulation: plan only, nothing is written. Do it first. |
| `-Discover` / `-ConnectorId` | Lists the project connectors (read only, no sign-in to the tenant); masked detail of a connector. |
| `-UseDeviceCode` | Graph (and Exchange) sign-in by device code. |
| `-KeepCredentials` | Compliance check: renews nothing as long as the certificate is consistent and valid for more than 30 days. |
| `-RotateCredentials` (alias `-RotateCertificate`) | No effect (renewal is the default behavior). Incompatible with `-KeepCredentials`. |
| `-AuthMethod` | `Both` (**default**: certificate AND client secret, which Cloudiway requires), `Certificate` or `Secret`. The last two are possible but **not recommended** (the audit may not start). |
| `-ValidityDays` | Validity of the generated credentials, 45 to 730 days (default 180). |
| `-AdoptExisting` | Allows taking over an existing application, service account or connector without the tool's tag (replaces the certificate, application identifier and migration account password of the connector). |
| `-AppName`, `-ConnectorName` | Replace the coded names. |
| `-WithoutServiceAccount` | Advanced: does not create the service account for Mail, despite Cloudiway's requirement (the audit will not start). See [section 7](#7-the-service-account). |
| `-AllowForeignSession` | Consultant use (off by default): allows an Exchange Online session of another tenant in the console instead of stopping the script. See [section 5.8](#58-one-powershell-console-per-tenant). |
| `-GraphAccessToken`, `-ExchangeAccessToken`, `-CloudiwayPassword` | Advanced (automation), not needed in normal use; see `Get-Help .\cloudiway-connector.ps1 -Full`. |
| `-ServiceAccountName` | Replaces the local part of the service account name (must start with `svc-ciw-`). No effect when no service account is created. |
| `-AllowEwsListCreation` | Allows creating the EWS list without a question when it is empty (makes it restrictive for the other EWS applications). |
| `-SkipCloudiway` | Configures the tenant only, with no call to Cloudiway (`-ProjectId` required; no certificate is generated, since there is no way to send it). |
| `-ProductIds` | **Complete** list of Cloudiway product identifiers to declare (Mail = 5, Files = 6; SharePoint: to be supplied, otherwise fast stop). |
| `-ProductMapFile` | JSON file mapping workloads to products (only overrides the workloads it names). By default, a `productmap.json` file next to the script is used if it exists. |
| `-Region` | Cloudiway server region (default 1). |
| `-CertificateTransport` | `Base64` (default) or `Path` (protected temporary file, deleted immediately). Only `Base64` is recommended. |
| `-OutDir` | Base folder of the report and the log. |
| `-InstallMissingModules` | Installs missing PowerShell modules without asking (user profile, no administrator rights). |
| `-Yes` | Skips the plan confirmation (scripted use). Never enabled implicitly. |

## 17. What is validated in real conditions, and what is not

State on 04/11/2026, for version 2.7, **after real-world validation**. This section is deliberately frank: the offline test suite covers these cases with a fake tenant and a fake portal, but a fake is not reality.

**Validated in real conditions**

- **Source and Target modes**, with the **Mail** and **OneDrive** workloads: creation of the connector with certificate, client secret **and** administrator account (`-AuthMethod Both`, service account created by default for Mail), then **successful audit** and **test migration started and being processed** (not finished at the date of this state).
- **The re-run**: after a re-run, **a single certificate and a single client secret** remain in the application, the certificate marker changes, and it is **the same connector** (Source and Target).
- **Certificate verification by file name** (re-reading of the connector after writing).
- **Removal of the old certificates** through the `PATCH` fallback and of the old secrets through `removePassword`.
- **Device code** (Microsoft Graph and Exchange Online).
- **EWS write** on an empty list (creation, with confirmation). By default, an empty list is **never created** without confirmation or `-AllowEwsListCreation`: the step is ignored (exit code 2).
- **Service account and SharePoint Administrator role created** at the first run, then **service account password renewed on the re-run**: validated **once** on a test tenant in Target mode (two successive re-runs, exit code `0`, connector updated).
- **Client secret accepted by the portal**, but **not verifiable when read back** (the portal masks it).

**Not validated in real conditions, or failure observed**

- **End-to-end migration**: the test migration is started and being processed; its final result is not yet known. That the connector is created and the audit successful does not prove that all migration jobs will succeed.
- **SharePoint**: product identifier **unknown** (see [section 6](#6-the-sharepoint-workload-and-the-cloudiway-product-identifier)), workload **not validated** in real conditions.
- **Teams**: workload not available in this version, **not validated**.
- **Removal of old certificates through `POST removeKey`**: Microsoft answers `403` in real conditions; the tool uses the `PATCH` fallback (validated).
- **Password reset refused by Entra** (for example `HTTP 403`): case handled by the guard (the connector is not modified, see [section 7](#7-the-service-account)); a manual reset is then needed.
- **Adding the AppID to an EWS list that already contains other applications**: never exercised in real conditions.
- **Guest account (B2B)** as tenant administrator.
- **Workstation behind an authenticated proxy.**
- **Windows PowerShell 5.1 on a fresh workstation** (`.cmd` launcher).
- **Global Reader role**: behavior with this role alone has not been tested.
- **Options `-AuthMethod Certificate` or `Secret` alone, `-CertificateTransport Path`, `-Region` other than 1.**

### Known limit observed

- **Two-factor authentication (2FA) on the Cloudiway account: NOT SUPPORTED.** Signing in to the portal from the script **does not work** with 2FA (observed in real conditions on 03/11/2026, at a customer). Explicit prerequisite: the Cloudiway account used to run the script must not have 2FA enabled; if it does, contact your 3SR contact. A workaround using a personal access token (`-CloudiwayPat`) exists in the tool, but it has **never been validated**: do not consider it a solution.

## 18. Limits of this version

- **Mail, OneDrive and SharePoint workloads only.** Other workloads are rejected with a clear message.
- **SharePoint: fast stop (code 1) until the product identifier is supplied**, before any sign-in; `-Workloads All` too (see [section 6](#6-the-sharepoint-workload-and-the-cloudiway-product-identifier)).
- **After each run of the script**, resubmit the connector audit in the Cloudiway portal (the client secret is masked by the portal: the proof is the start of the audit) and check that the project license limit is not 0 ("Project Settings").
- Every run renews the certificate and the secret and updates the existing connector: do not run again during active migration jobs (see [section 9](#9-renewal-every-run-renews-the-certificate-and-the-secret)).
- If Entra refuses the password reset of an existing service account (for example `HTTP 403`), the guard blocks the connector write: manual reset (see [section 7](#7-the-service-account)).
- **One PowerShell console per tenant**: an Exchange Online session of another tenant stops the script (code 1) unless `-AllowForeignSession` is used (see [section 5.8](#58-one-powershell-console-per-tenant)).
- If the security defaults are enabled, the OneDrive and SharePoint jobs fail at the service account authentication (see [section 7](#7-the-service-account)).
- The script does not remove its objects at the end of the project: the procedure is manual (see [section 12](#12-removing-the-objects-at-the-end-of-the-project)).
- The Cloudiway account must not have two-factor authentication enabled (see [section 17](#17-what-is-validated-in-real-conditions-and-what-is-not)).
