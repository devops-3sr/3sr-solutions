# cloudiway-connector

Configure un tenant Microsoft 365 **source** pour un connecteur Cloudiway (charges **Mail** et **OneDrive**), puis crée ou met à jour le connecteur dans votre projet Cloudiway. **Ce script modifie le tenant** (application Entra, permissions et consentement, rôles Exchange, certificat, liste EWS d'Exchange Online, connecteur Cloudiway) : lancez toujours `-WhatIf` d'abord. Mode Source uniquement dans cette version ; le mode Cible arrivera plus tard.

Configures a **source** Microsoft 365 tenant for a Cloudiway connector (**Mail** and **OneDrive** workloads), then creates or updates the connector in your Cloudiway project. **This script modifies the tenant** (Entra application, permissions and consent, Exchange roles, certificate, Exchange Online EWS list, Cloudiway connector): always run `-WhatIf` first. Source mode only in this version; the Target mode will come later.

| Langue / Language | Guide |
|---|---|
| Français | [cloudiway-connector-guide-fr.md](cloudiway-connector-guide-fr.md) |
| English | [cloudiway-connector-guide-en.md](cloudiway-connector-guide-en.md) |

## Démarrage rapide / Quick start

```
cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -WhatIf
```

ou, avec PowerShell 7.2 / or, with PowerShell 7.2:

```powershell
pwsh -NoProfile -File .\cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -WhatIf
```

## Contenu / Contents

| Chemin / Path | Rôle / Role |
|---|---|
| `cloudiway-connector.ps1` | Script principal (PowerShell 7.2) / main script (PowerShell 7.2) |
| `cloudiway-connector.cmd` | Lanceur (fonctionne sous Windows PowerShell 5.1) / launcher (works from Windows PowerShell 5.1) |
| `cloudiway-connector-launcher.ps1` | Débloque les fichiers, vérifie ou installe PowerShell 7.2 / unblocks the files, checks or installs PowerShell 7.2 |
| `lib/` | Bibliothèques du script / script libraries |
| `tests/` | Tests hors ligne (`tests/run-tests.ps1`) / offline tests |

Tests : `pwsh -NoProfile -File .\tests\run-tests.ps1` (aucune connexion, aucun réseau, environ 5 minutes / no connection, no network, about 5 minutes).
