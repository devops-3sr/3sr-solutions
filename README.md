# 3SR Solutions

Public scripts and documentation for the solutions that [3SR](https://3sr.fr) operates on Microsoft Azure and Microsoft 365.

*Scripts et documentation publics des solutions que [3SR](https://3sr.fr) opère sur Microsoft Azure et Microsoft 365. Version française plus bas.*

3SR is a Microsoft Azure pure player based in Andernos-les-Bains, France, since 2012. This repository is **not** a replacement for [our website](https://3sr.fr): it exists so that you can read, review and version the scripts we ask you to run in your own environment.

## Solutions

| Folder | Solution | Status |
|---|---|---|
| [`ssl-managed/`](ssl-managed/) | **SSL Managed**: scripts that prepare your Azure Key Vault, role assignments (RBAC) and storage so that 3SR can issue and renew your certificates without ever holding your private keys | Available |
| [`cloudiway/`](cloudiway/) | **Cloudiway collector**: read-only collection of a Microsoft 365 tenant, used to size the licences for a tenant-to-tenant migration | Available |

Each solution lives in its own folder with its own `README.md`, `CHANGELOG.md` and release notes.

## Read before you run

Some of these scripts run with administrator rights in **your** tenant. We want you to be able to check them first:

- Scripts that change your environment provide a **simulation mode** that shows what would change without changing anything (documented in each solution's `README.md`).
- Every release lists the **SHA-256** of each script. Check it before running:
  ```powershell
  Get-FileHash .\script.ps1 -Algorithm SHA256
  ```
- The repository contains **no secret, no key and no customer data**. If you find one, please tell us (see Support).
- Review the script, run the simulation, then run it for real. If you have questions, ask us first.

## Versioning

- One semantic version per solution (`MAJOR.MINOR.PATCH`), tagged `<solution>-vX.Y.Z`, for example `ssl-managed-v1.0.0`.
- Changes go through branches and pull requests. Each release has release notes and a per-solution `CHANGELOG.md`.
- This repository is a **published copy**: the source of truth is maintained by 3SR, and releases are published here after review.

## Support

This repository is not a support channel and issues are not monitored. Customers: contact 3SR through your usual support channel or via https://3sr.fr.

## License

[MIT](LICENSE). The 3SR name and logo are trademarks of 3SR and are not covered by this license.

---

# Version française

Dépôt public des scripts et de la documentation des solutions opérées par [3SR](https://3sr.fr) sur Microsoft Azure et Microsoft 365. Il ne remplace pas notre [site web](https://3sr.fr) : il vous permet de lire, vérifier et suivre les versions des scripts que nous vous demandons d'exécuter dans votre environnement.

## À lire avant d'exécuter

- Les scripts qui modifient votre environnement proposent un **mode simulation** qui montre ce qui serait modifié, sans rien modifier (précisé dans le `README.md` de chaque solution).
- Chaque version publie l'**empreinte SHA-256** de chaque script : vérifiez-la avant exécution (`Get-FileHash`).
- Le dépôt ne contient **aucun secret, aucune clé et aucune donnée client**. Si vous en trouvez un, prévenez-nous.
- Relisez le script, lancez la simulation, puis l'exécution réelle. En cas de doute, contactez-nous avant.

## Versions

Une version sémantique par solution, étiquetée `<solution>-vX.Y.Z`, avec notes de version et `CHANGELOG.md`. Ce dépôt est une **copie publiée** : la source de référence est maintenue par 3SR et les versions sont publiées ici après relecture.

## Support

Ce dépôt n'est pas un canal de support et les tickets (issues) ne sont pas surveillés. Clients : contactez 3SR par votre canal habituel ou via https://3sr.fr.

## Licence

[MIT](LICENSE). Le nom et le logo 3SR sont des marques de 3SR et ne sont pas couverts par cette licence.
