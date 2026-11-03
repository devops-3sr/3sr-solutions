# cloudiway-collector

Collecte **en lecture seule** d'un tenant Microsoft 365 : le script rassemble des donnees brutes (CSV et JSON) et produit **un seul fichier**, une archive zip, que le client remet a son contact 3SR. Il ne calcule rien et n'envoie rien.

Read-only collection of a Microsoft 365 tenant: the script gathers raw data (CSV and JSON) and produces **a single archive (zip)** that the customer hands to their 3SR contact. It computes nothing and uploads nothing.

| Langue / Language | Guide |
|---|---|
| Francais | [cloudiway-collector-guide-fr.md](cloudiway-collector-guide-fr.md) |
| English | [cloudiway-collector-guide-en.md](cloudiway-collector-guide-en.md) |

## Demarrage rapide / Quick start

```
cloudiway-collector.cmd -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com
```

ou, avec PowerShell 7 / or, with PowerShell 7:

```powershell
pwsh -NoProfile -File .\cloudiway-collector.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com
```

## Contenu / Contents

| Chemin / Path | Role |
|---|---|
| `cloudiway-collector.ps1` | Script principal (PowerShell 7) / main script (PowerShell 7) |
| `cloudiway-collector.cmd` | Lanceur (fonctionne sous Windows PowerShell 5.1) / launcher (works from Windows PowerShell 5.1) |
| `cloudiway-collector-launcher.ps1` | Verifie ou installe PowerShell 7, debloque les fichiers / checks or installs PowerShell 7, unblocks the files |
| `lib/` | Bibliotheques du script / script libraries |
| `tests/` | Tests hors ligne (`tests/run-tests.ps1`) / offline tests |

Tests : `pwsh -NoProfile -File .\tests\run-tests.ps1` (aucune connexion, aucun reseau / no connection, no network).
