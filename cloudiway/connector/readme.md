# cloudiway-connector

Configure un tenant Microsoft 365 **source** ou **cible** pour un connecteur Cloudiway (charges **Mail**, **OneDrive** et **SharePoint**), puis crée ou met à jour le connecteur dans votre projet Cloudiway. **Ce script modifie le tenant** (application Entra, permissions et consentement, rôles Exchange, certificat, compte de service, liste EWS d'Exchange Online, connecteur Cloudiway) : lancez toujours `-WhatIf` d'abord. Version 2.7. UNE CONSOLE POWERSHELL PAR TENANT (une session Exchange d'un autre tenant arrête le script). Authentification par défaut : certificat ET secret client ; le compte de service (compte administrateur exigé par Cloudiway) est créé par défaut dès que Mail est demandé, même dans le tenant Source. SharePoint : arrêt rapide tant que l'identifiant du produit Cloudiway n'est pas fourni (voir le guide). Après chaque exécution : re-soumettre l'audit du connecteur dans le portail Cloudiway et vérifier que la limite de licences du projet n'est pas à 0 (« Project Settings »).

Configures a **source** or **target** Microsoft 365 tenant for a Cloudiway connector (**Mail**, **OneDrive** and **SharePoint** workloads), then creates or updates the connector in your Cloudiway project. **This script modifies the tenant** (Entra application, permissions and consent, Exchange roles, certificate, service account, Exchange Online EWS list, Cloudiway connector): always run `-WhatIf` first. Version 2.7. ONE POWERSHELL CONSOLE PER TENANT (an Exchange session of another tenant stops the script). Default authentication: certificate AND client secret; the service account (administrator account required by Cloudiway) is created by default as soon as Mail is requested, even in the Source tenant. SharePoint: fast stop until the Cloudiway product identifier is supplied (see the guide). After each run: resubmit the connector audit in the Cloudiway portal and check that the project license limit is not 0 ("Project Settings").

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
| `productmap.example.json` | Exemple (valeurs FICTIVES) de table de produits Cloudiway / example (FICTITIOUS values) of a Cloudiway product table |
| `lib/` | Bibliothèques du script / script libraries |
| `tests/` | Tests hors ligne (`tests/run-tests.ps1`) / offline tests |

Tests : `pwsh -NoProfile -File .\tests\run-tests.ps1` (aucune connexion, aucun réseau, environ 10 minutes / no connection, no network, about 10 minutes).
