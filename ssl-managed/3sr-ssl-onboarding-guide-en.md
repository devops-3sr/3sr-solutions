# SSL MANAGED SOLUTION: Preparing your Azure environment

> Version française : [3sr-ssl-onboarding-guide-fr.md](3sr-ssl-onboarding-guide-fr.md)
>
> **Note:** the script and its messages are in French. The console examples below show the actual output and are kept as is; each step is explained in English.

## 1. What the script does

`3sr-ssl-onboarding.ps1` prepares, **in your Azure subscription**, the three resources required by the service:

| Resource | Purpose |
|---|---|
| Resource group | Groups the two resources below |
| Storage account + `ssl` container | Holds the list of your certificates, a JSON file that you control |
| Key Vault | Receives the issued certificates |

It then grants 3SR **two accesses**, and nothing else:

| Access | What it allows | Scope |
|---|---|---|
| `Key Vault Certificates Officer` | Create and renew certificates | The vault only |
| `Storage Blob Data Reader` | Read your list, without being able to modify it | The `ssl` container only |

Both roles are visible in the Azure portal and you can revoke them at any time. No password, key or token is created or exchanged. Your private keys stay in your vault.

Finally, the script gives **you** access to your own resources, which is broader than the access given to 3SR:

| Your access | Scope | Why |
|---|---|---|
| `Storage Blob Data Contributor` | The `ssl` container | Maintain your certificate list |
| `Key Vault Certificates Officer` | The vault | Manage your certificates |
| `Key Vault Secrets User` | The vault | **Export your certificates as PFX** |

The third one deserves an explanation. `Key Vault Certificates Officer` does not grant access to the secret associated with a certificate, so 3SR cannot extract your private keys. However, the Azure portal needs to read that secret to build a PFX. Without `Key Vault Secrets User`, the **Download in PFX/PEM format** button fails with a misleading message, `Failed to dynamically fetch target download uri`.

In RBAC mode, being Owner of the subscription does not grant access to the contents of the vault or of the storage account: these are two separate planes, hence these explicit assignments.

**Duration: about 5 minutes.** The script never deletes anything and can be run again safely.

---

## 2. Prerequisites

- **Azure CLI**, to install from <https://aka.ms/installazurecli>
- **PowerShell** 5.1 (built into Windows) or PowerShell 7
- Be **Owner** of the target subscription. The `Contributor` role is not enough because it cannot assign roles.
- The 3SR application must be authorized in your Entra directory. If it is not, the script stops at the very beginning and displays the exact link a Global Administrator must open.

---

## 3. Running the script

```powershell
az login
.\3sr-ssl-onboarding.ps1
```

If Windows blocks the script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### Step 1. Choose the tenant and the subscription

The script lists your tenants, then the subscriptions of the one you select. Beyond 15 entries, it offers a filter. Nothing is created without your confirmation.

```console
  Sélectionnez le locataire (tenant) Microsoft Entra :
     [1] contoso.fr   (a1b2c3d4-9f01-4c7e-b3aa-5d2e10f4c8b7)   2 souscription(s)

  Sélectionnez la souscription dans laquelle créer les ressources :
     [1] Production   (8e5f1a20-6c34-4b19-9e7d-2f81ab55c390)
     [2] Bac a sable  (1c77b904-2d55-41a8-8b60-7ee3f9012d44)
  Votre choix (1-2) : 1

  Locataire      : contoso.fr
  Souscription   : Production
  Connecté en    : admin@contoso.fr

  ATTENTION : les ressources seront créées dans CETTE souscription.
  Confirmez-vous ? (o/N) : o
```

### Step 2. Choose the names

Three names are suggested. **Enter** accepts the one in brackets. Each name is checked twice: its format, then its actual availability in Azure.

| Resource | Rules |
|---|---|
| Resource group | 90 characters maximum; letters, digits, `-`, `_`, `.` |
| Storage account | 3 to 24 characters, **lowercase letters and digits only**, unique across all of Azure |
| Key Vault | 3 to 24 characters, starts with a letter, letters, digits and hyphens, unique across all of Azure |

```console
  Nom du groupe de ressources [RG-SSL-Managed] :
  > Vérification de « RG-SSL-Managed »...
  [OK]    « RG-SSL-Managed » est disponible, il sera créé.

  Nom du compte de stockage (minuscules et chiffres) [stsslmanagedk3p9x] :
  > Vérification de « stsslmanagedk3p9x »...
  [OK]    « stsslmanagedk3p9x » est disponible, il sera créé.

  Nom du coffre de clés Key Vault [kv-sslmanaged-k3p9x] :
  > Vérification de « kv-sslmanaged-k3p9x »...
  [OK]    « kv-sslmanaged-k3p9x » est disponible, il sera créé.
```

The script then asks for the **JSON file provided by 3SR**, the list of your certificates. It checks the content before uploading it and rejects a malformed file, pointing out the faulty entry.

> **Do not rename this file.** Its name, in the form `<your-code>-ssl.json`, is the one the 3SR automation will read. The script uploads it as is into the `ssl` container.

You can skip this step and upload the file later from the Azure portal: `ssl` container of the storage account that was created, keeping the original name.

### Step 3. Confirm

Everything that will be created and every access that will be granted is summarized. **Nothing is created until you type `OUI` (yes).**

```console
  RESSOURCES
  ──────────────────────────────────────────────────────────────────
  Groupe de ressources   : RG-SSL-Managed (à créer)
  Compte de stockage     : stsslmanagedk3p9x (à créer)
     Conteneur           : ssl
     Fichier déposé      : contoso-ssl.json  (21 certificat(s))
  Coffre de clés         : kv-sslmanaged-k3p9x (à créer)

  ACCÈS ACCORDÉS À 3SR
  ──────────────────────────────────────────────────────────────────
  - « Key Vault Certificates Officer »
      sur le coffre kv-sslmanaged-k3p9x uniquement
  - « Storage Blob Data Reader »
      sur le conteneur « ssl » uniquement, en LECTURE SEULE

  Confirmez-vous ? (tapez OUI) : OUI
```

### Step 4. Creation and checks

Allow one to two minutes. The script then re-reads the actual state of your resources in Azure and displays about twenty checks.

```console
  > Création du compte de stockage « stsslmanagedk3p9x » (30 à 60 s)...
  [OK]    Compte de stockage prêt.
  [OK]    Conteneur prêt.
  [OK]    Fichier déposé.
  [OK]    Coffre de clés prêt.
  [OK]    Clé partagée désactivée : authentification par identité uniquement.

  PASS  Stockage en France Centre : francecentral
  PASS  Clé partagée désactivée : allowSharedKeyAccess=false
  PASS  HTTPS obligatoire
  PASS  Coffre en mode RBAC
  PASS  Rôle 3SR sur le coffre : portée = le coffre
  PASS  Rôle 3SR sur le conteneur : portée = le conteneur

  Bilan : 21 PASS / 0 WARN / 0 FAIL
```

### Step 5. Send the report back

A file named `3sr-ssl-onboarding-<date>.txt` is written in the current folder.

> **Send it to your 3SR contact.** Without it, 3SR cannot activate the automation.

It contains the identifiers of your resources (tenant, subscription, created names) and the result of the checks. It contains no secret.

---

## 4. Arguments

| Argument | Effect |
|---|---|
| *(none)* | Normal run |
| `-Simulation` | Goes through the whole procedure **without creating or modifying anything**, and displays the commands that would be run. Use it for a first trial. |
| `-RapportEmail <address>` | Address displayed as the recipient of the report at the end of the run. Optional: without a value, the script says "votre contact 3SR" (your 3SR contact). |
| `-AutoriserStorageExistant` | Allows reusing a storage account that was not created by this script. Its security properties will be modified. **Use only when instructed by 3SR.** |
| `-AutoriserMigrationRbac` | Allows switching an existing vault from "access policies" to RBAC. This invalidates the existing access policies. **Use only when instructed by 3SR.** |

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | Success, with warnings in the report |
| `3` | A critical security check failed |
| `1` | Blocking error |

---

## 5. Troubleshooting

The messages are displayed in French. Equivalent in English:

| Message | What to do |
|---|---|
| `Azure CLI (az) est introuvable` (Azure CLI not found) | Install Azure CLI, then reopen the terminal |
| `Aucune souscription accessible` (no accessible subscription) | Run `az login` |
| `L'application 3SR n'est pas enregistrée dans votre locataire` (the 3SR application is not registered in your tenant) | Have a Global Administrator open the link displayed by the script |
| `« nom » est déjà utilisé ailleurs dans Azure` (name already used elsewhere in Azure) | Storage and vault names are globally unique: choose another one |
| `existe mais n'a pas été créé par ce script` (exists but was not created by this script) | Choose a name dedicated to the SSL service |
| `Impossible d'attribuer le rôle` (cannot assign the role) | Have the script run by an Owner of the subscription |
| `Ce fichier ne peut pas être déposé` (this file cannot be uploaded) | The message points out the faulty entry of the JSON file. Fix the file, or upload it later. |

The script can be run again: what exists is reused, and a role that is already assigned is simply confirmed. In case of a partial failure, send the report as is to your 3SR contact.

---

## 6. Ending the service

The `3sr-ssl-offboarding.ps1` script removes the accesses granted to 3SR. It presents them to you, you choose which ones to revoke, and **it deletes no resource**. Your certificates remain yours and stay valid until they expire. You can also remove these roles directly from the Azure portal.

---

*Any question: contact your 3SR representative.*
