# cloudiway-collector : guide d'utilisation

English version: [cloudiway-collector-guide-en.md](cloudiway-collector-guide-en.md)

`cloudiway-collector` est un script PowerShell qui **collecte en lecture seule** la configuration et les volumes d'un tenant Microsoft 365, en vue de préparer une migration de tenant à tenant avec Cloudiway. Il est conçu pour être lancé par un administrateur du tenant, sans accompagnement technique.

Le script **ne fait que collecter** : il produit des données brutes (CSV et JSON) regroupées dans **un seul fichier, une archive zip**, que vous remettez ensuite à votre contact 3SR. Il ne calcule, n'estime ni ne chiffre rien.

## Sommaire

1. [Ce que fait le script, ce qu'il ne fait pas](#1-ce-que-fait-le-script-ce-quil-ne-fait-pas)
2. [Droits exigés](#2-droits-exigés)
3. [Prérequis](#3-prérequis)
4. [Exécution pas à pas](#4-exécution-pas-à-pas)
5. [Fichiers produits et leur contenu](#5-fichiers-produits-et-leur-contenu)
6. [Ce qu'il faut envoyer à 3SR](#6-ce-quil-faut-envoyer-à-3sr)
7. [Supprimer les données ensuite](#7-supprimer-les-données-ensuite)
8. [Vérifier le script avant de l'exécuter](#8-vérifier-le-script-avant-de-lexécuter)
9. [Dépannage](#9-dépannage)
10. [Référence des options](#10-référence-des-options)

## 1. Ce que fait le script, ce qu'il ne fait pas

**Ce qu'il fait**

- Il se connecte au tenant avec **votre** compte administrateur, dans trois fenêtres de connexion successives : Microsoft Graph, SharePoint Online, Exchange Online.
- Il lit la configuration (identités, licences, groupes, domaines, postes, sécurité, DNS public, flux de messagerie, état d'EWS) et les volumes (tailles de boîtes aux lettres, de sites SharePoint et de comptes OneDrive).
- Il écrit des fichiers CSV et JSON dans un dossier local, puis les regroupe dans une archive zip.

**Ce qu'il ne fait pas**

- **Il est en lecture seule sur le tenant** : il n'exécute que des lectures (requêtes Graph `GET`, cmdlets `Get-*`). Il ne crée, ne modifie et ne supprime rien dans votre tenant. Aucune cmdlet d'écriture sur le tenant n'est présente dans le code, et le banc de tests le vérifie ; les seules écritures sont locales (fichiers de résultats et, avec votre accord, installation de modules dans votre profil).
- Il ne lit **aucun contenu** : ni courriers, ni fichiers, ni messages Teams. Il collecte des noms, des adresses, des tailles, des comptages et des paramètres de configuration.
- Il n'écrit et n'affiche **aucun mot de passe ni jeton**.
- Il n'envoie **rien** sur Internet : les fichiers restent sur le poste qui exécute le script, **sous votre contrôle, jusqu'à ce que vous les transmettiez vous-même** (voir [section 6](#6-ce-quil-faut-envoyer-à-3sr)).
- Il ne couvre ni Google Workspace, ni les migrations hors Microsoft 365.

Garde-fous : le script vérifie que le tenant et le compte qui se connectent sont exactement ceux que vous avez indiqués (`-TenantId`, `-User`) ; en cas d'écart, il se déconnecte et s'arrête. Avant toute connexion, il contrôle le poste (PowerShell, modules, réseau, droits d'écriture) ; si un prérequis manque, il s'arrête sans avoir tenté la moindre connexion.

## 2. Droits exigés

### Rôle du compte

Le compte qui se connecte doit être :

- **Administrateur général** (recommandé : c'est le rôle avec lequel le script a été éprouvé, et c'est lui qui peut accorder le consentement demandé à la première connexion) ; ou
- **Lecteur général** (Global Reader), suffisant en principe pour les lectures ; le script teste les accès au démarrage et signale précisément ce qui manque.

Pour les parties Exchange et SharePoint, les lectures exigent en pratique : Administrateur Exchange, Lecteur général ou Administrateur général pour Exchange Online ; Administrateur SharePoint ou Administrateur général pour SharePoint Online. Un rôle éligible mais non activé (PIM) n'est pas pris en compte : activez-le avant de lancer la collecte.

### Consentement à la première connexion

À la première connexion Microsoft Graph, Microsoft demande à un administrateur général de **consentir à des autorisations en lecture seule** pour l'application d'entreprise **« Microsoft Graph Command Line Tools »**. Cette application reste dans votre tenant ; elle peut être supprimée après la collecte (voir [section 7](#7-supprimer-les-données-ensuite)). Sans consentement, la collecte s'arrête dès la première étape avec un message explicite.

### Les 18 autorisations Microsoft Graph demandées

Toutes sont des autorisations de **lecture** (`.Read.*` ; aucune autorisation d'écriture n'est demandée) :

| # | Autorisation | # | Autorisation |
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

La liste figure dans `lib/common.ps1` (variable `GraphScopes`) ; vous pouvez la relire avant d'exécuter quoi que ce soit. Le contexte de connexion Graph est limité au processus : il disparaît à la fermeture de la console.

### Ce que le script teste avant de collecter

Juste après la connexion, le script effectue une lecture minimale sur chaque point d'accès utile. Si un point **requis** est refusé (organisation, domaines, utilisateurs, groupes), la collecte s'arrête avant de commencer, avec l'indication du rôle ou du consentement manquant. Un point **optionnel** refusé n'arrête rien : il est signalé en `[WARN]` avec son impact. Exemples de limites liées à une licence : sans Entra ID P1 ou P2, les dernières connexions, l'accès conditionnel et l'état MFA ne sont pas disponibles ; sans Intune, les appareils gérés et les profils Intune sont absents (c'est normal si Intune n'est pas utilisé).

## 3. Prérequis

1. **Un poste Windows** avec accès Internet HTTPS vers `login.microsoftonline.com`, `graph.microsoft.com`, `outlook.office365.com` et `sharepoint.com` (le script teste ces accès avant de commencer, et détecte un proxy ou une inspection de certificat). Environ 200 Mo d'espace libre pour le dossier de sortie.
2. **PowerShell 7** (commande `pwsh`). Le PowerShell intégré à Windows (version 5.1) ne convient pas pour le script lui-même ; en revanche le **lanceur** `cloudiway-collector.cmd` fonctionne depuis Windows PowerShell 5.1 : il débloque les fichiers, vérifie que PowerShell 7 est installé et, s'il manque, **propose** de l'installer avec `winget` (après confirmation ; Windows peut demander les droits administrateur).
3. **Trois modules PowerShell** :
   - `Microsoft.Graph.Authentication` (version 2.0.0 minimum) ;
   - `ExchangeOnlineManagement` (version 3.7.0 minimum) ;
   - `Microsoft.Online.SharePoint.PowerShell`.

   S'ils manquent, le script propose de les installer pour l'utilisateur courant (sans droits administrateur), après confirmation. Pour les installer vous-même :

   ```powershell
   Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement, Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser
   ```

4. **Un compte administrateur** du tenant à collecter (voir [section 2](#2-droits-exigés)).
5. **Débloquer les fichiers** téléchargés (Windows marque les fichiers reçus par Internet ou par zip). Le lanceur le fait pour vous ; sinon, dans le dossier du script :

   ```powershell
   Get-ChildItem -Path . -Recurse -File | Unblock-File
   ```

Le dossier `lib` doit rester à côté du script principal : ne copiez pas `cloudiway-collector.ps1` seul.

## 4. Exécution pas à pas

Les exemples utilisent le tenant fictif **Contoso** : remplacez les valeurs par celles de votre tenant.

**Étape 1. Repérez l'identifiant (GUID) du tenant.** Portail Microsoft Entra, page « Vue d'ensemble », champ « ID de locataire ». À défaut, à partir d'un nom de domaine du tenant :

```powershell
(Invoke-RestMethod "https://login.microsoftonline.com/contoso.onmicrosoft.com/.well-known/openid-configuration").token_endpoint
```

L'URL renvoyée contient le GUID du tenant.

**Étape 2. Ouvrez une console** dans le dossier du script (invite de commandes ou PowerShell).

**Étape 3. Lancez la collecte.** Méthode principale, avec le lanceur :

```
cloudiway-collector.cmd -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com
```

(sous PowerShell : `.\cloudiway-collector.cmd -TenantId ... -User ...`). Si PowerShell 7 est déjà installé, vous pouvez appeler directement le script :

```powershell
pwsh -NoProfile -File .\cloudiway-collector.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com
```

Pour un tenant **de destination** (collecte allégée, pour détecter les conflits), ajoutez `-Role Target`. Sans cette option, le rôle est `Source` (tenant à migrer, volumes complets).

Le lanceur utilise `-ExecutionPolicy Bypass` **pour cette seule exécution** (il ne modifie pas la politique d'exécution du poste).

**Étape 4. Répondez aux fenêtres de connexion.** Le script ouvre trois fenêtres, toujours avec le même compte :

1. **Microsoft Graph** (utilisateurs, licences, groupes, sécurité, postes) ;
2. **SharePoint** (sites et OneDrive), après un décompte de 10 secondes ;
3. **Exchange Online** (boîtes aux lettres, flux de messagerie), après un décompte de 10 secondes.

Aucune validation n'est attendue avant l'ouverture : restez devant l'écran pendant les premières minutes, car chaque fenêtre expire au bout de 2 minutes environ. Les trois connexions sont demandées au début ; la collecte proprement dite se déroule ensuite sans intervention.

**Étape 5. Attendez la fin.** Comptez de 10 à 40 minutes selon la taille du tenant (la lecture des statistiques de boîtes aux lettres est la partie la plus longue). Le script affiche sa progression (étapes 1/4 à 4/4), puis un bilan : nombre d'éléments OK, partiels et KO, durée, chemin de l'archive. Ne fermez pas la console.

**Étape 6. Lisez le bilan.** Des lignes « KO » ou « NON DISPO » sont fréquentes et en général sans gravité : elles signalent une information inaccessible (licence absente, droit non accordé, fonction non activée). Le script continue et les liste, avec un conseil, dans le bilan et dans `capabilities.csv`. Un KO « en erreur » (accès Exchange ou SharePoint refusé, connexion annulée) mérite en revanche d'être relancé avec un compte disposant du rôle indiqué.

**Relancer.** Le script est **idempotent** : relancer la même commande met à jour le même dossier et la même archive (les anciens fichiers de résultats sont supprimés, `run.log` est conservé et complété). On peut donc le rejouer sans risque après un refus de droit ou une fenêtre expirée.

**Relancer seulement une partie.** Les parties sont `Identity`, `Devices`, `Security`, `Dns`, `Exchange`, `SharePoint`. Avec `-OutDir` pointant sur le sous-dossier de la collecte existante (celui qui contient `tenant.csv`), seules les parties demandées sont refaites et `capabilities.csv` est fusionné. Une seule partie : `-Parts Exchange`. Plusieurs parties : `-File` ne gère pas les listes, utilisez `-Command` :

```powershell
pwsh -NoProfile -Command "& '.\cloudiway-collector.ps1' -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com -Parts Exchange,SharePoint -OutDir '.\collecte-resultats\00000000'"
```

## 5. Fichiers produits et leur contenu

Le script écrit, dans le dossier de sortie (par défaut `collecte-resultats`, à côté du script ; option `-OutDir`) :

- un dossier nommé d'après les 8 premiers caractères du GUID du tenant (par exemple `collecte-resultats\00000000\`) contenant les fichiers ci-dessous ;
- **l'archive `collecte-<8 premiers caractères du GUID>.zip`**, qui regroupe ces fichiers (par exemple `collecte-resultats\collecte-00000000.zip`).

Les CSV utilisent le séparateur `;` et l'encodage UTF-8 avec BOM.

> **Ces fichiers contiennent des données nominatives** : adresses e-mail et noms d'utilisateurs (UPN), noms et adresses des groupes et des boîtes, tailles de boîtes aux lettres, propriétaires des OneDrive et des sites, invités externes, noms de sites et de stratégies. Ils ne contiennent **aucun contenu** de courrier, de fichier ou de message. Traitez-les comme des données personnelles.

| Fichier | Contenu | Source / rôle |
|---|---|---|
| `tenant.csv` | Nom, identifiant et domaine initial du tenant, pays, langue, état de synchronisation, compte ayant lancé la collecte, date, version du script, rôle | tous |
| `capabilities.csv` | Journal des contrôles : pour chaque partie et chaque élément, le statut (OK, PARTIEL, KO) et un détail | tous |
| `run.log` | Journal d'exécution horodaté (étapes, statuts, messages d'erreur courts) ; mentionne le compte utilisé et le chemin local du dossier de sortie | tous |
| `skus.csv` | Abonnements de licences : référence, état, quantités achetées et consommées | tous |
| `users.csv` | Comptes : identifiant, UPN, noms, adresses (dont alias), type (membre ou invité), activé ou non, licences attribuées, dates de création, localisation, service, fonction, synchronisation locale, dernières connexions (si la licence le permet) | tous |
| `guests.csv` | Invités externes : UPN, adresse, date de création | Source |
| `groups.csv` | Groupes : nom, adresses, nature (Microsoft 365, sécurité, distribution), équipe Teams ou non, visibilité, nombre de membres et de propriétaires | tous (comptages : Source) |
| `teams-channels.csv` | Par équipe Teams : nombre de canaux standard, privés et partagés | Source |
| `domains.csv` | Domaines du tenant : vérifié, par défaut, initial, type d'authentification, services | tous |
| `enterprise-apps.csv` | Applications d'entreprise : nom, appId, mode d'authentification unique, activée ou non, organisation propriétaire | tous |
| `entra-devices.csv` | Appareils Entra : nom, système, version, type de jointure, géré, conforme, dernière connexion | tous |
| `intune-managed-devices.csv` | Appareils gérés par Intune : nom, système, conformité, inscription, utilisateur, chiffrement | tous (si Intune) |
| `intune-config-inventory.csv` | Inventaire des profils Intune : catégorie, nom, type, date de création (aucun contenu de configuration) | tous (si Intune) |
| `autopilot-devices.csv` | Appareils Autopilot (si accessibles) | tous |
| `secure-score.csv` | Score de sécurité Microsoft (si accessible) | tous |
| `conditional-access.csv` | Stratégies d'accès conditionnel : nom, état, conditions et contrôles résumés | tous (Entra ID P1 ou P2) |
| `security-defaults.csv` | Paramètres de sécurité par défaut activés ou non | tous |
| `authorization-policy.csv` | Paramètres d'invitation et de consentement du tenant | tous |
| `cross-tenant-access.csv` | Paramètres d'accès inter-tenants | tous |
| `directory-roles.csv` | Rôles d'administration actifs et leurs membres (UPN) | tous |
| `mfa-registration.csv` | Par utilisateur : méthodes MFA enregistrées (UPN, méthode par défaut) | tous (Entra ID P1 ou P2) |
| `auth-methods-policy.csv` | Méthodes d'authentification autorisées | tous |
| `report-onedrive-usage.csv`, `report-sharepoint-usage.csv`, `report-mailbox-usage.csv`, `report-active-users.csv`, `report-teams-activity.csv` | Rapports d'usage Microsoft 365 sur 180 jours (stockage, nombre de fichiers, dernière activité, propriétaires). Si le tenant masque les noms, les identifiants sont anonymisés | Source |
| `dns.csv` | Par domaine vérifié : enregistrements MX, SPF, DMARC, Autodiscover tels que résolus depuis le poste (DNS public), et le filtrage de messagerie qui en est déduit | tous |
| `ews.csv` | État d'EWS dans l'organisation, applications autorisées, comptage des boîtes avec EWS désactivé, présence des applications Cloudiway | tous |
| `exo-organization.csv` | Quelques paramètres de l'organisation Exchange (journalisation, dossiers publics, authentification moderne...) | tous |
| `mailboxes.csv` | Boîtes aux lettres : type, nom, UPN, adresses, alias, archive, conservation, transferts, date de création ; en Source, **tailles et nombre d'éléments** de la boîte et de l'archive | tous (volumes : Source) |
| `recipients.csv` | Tous les destinataires (nom, adresse principale, alias, type, adresses) | Cible |
| `mailbox-permissions.csv` | Droits sur les boîtes (contrôle total, envoyer en tant que...) : boîte, type, droit, bénéficiaire | Source |
| `distribution-lists.csv` | Listes de distribution : nom, adresse, type, nombre de membres, adresses | Source |
| `mail-contacts.csv` | Contacts et utilisateurs de messagerie : nom, adresses | Source |
| `accepted-domains.csv` | Domaines acceptés | tous |
| `connectors.csv` | Connecteurs de messagerie entrants et sortants (hôtes, domaines, adresses IP) | tous |
| `transport-rules.csv` | Règles de transport : nom, état, priorité, mode, description | tous |
| `dkim.csv` | État DKIM par domaine | tous |
| `sites.csv` | Tous les sites SharePoint et comptes OneDrive : URL, titre, modèle, propriétaire, stockage (octets et Go), dernière modification, groupe lié, partage, catégorie. En Cible : URL, titre, modèle, catégorie seulement | tous (volumes : Source) |
| `onedrive.csv`, `sharepoint.csv`, `sharepoint-system.csv` | Le contenu de `sites.csv` réparti par catégorie (comptes OneDrive, sites SharePoint, sites système) | Source |
| `spo-tenant.csv` | Paramètres de partage et de stockage du tenant SharePoint | tous |

Certains fichiers peuvent être absents ou vides selon les licences et les droits ; `capabilities.csv` en donne la raison.

## 6. Ce qu'il faut envoyer à 3SR

Envoyez **un seul fichier** : l'archive **`collecte-<8 premiers caractères du GUID>.zip`**, située dans le dossier de sortie. Ne renvoyez ni le dossier décompressé, ni les modules, ni les captures d'écran.

- Transmettez-la par **un canal sécurisé** convenu avec votre contact 3SR (espace de dépôt sécurisé, lien protégé) et non par un courrier non chiffré : elle contient des données nominatives.
- Tant que vous ne l'avez pas transmise, les données **restent sur votre poste et sous votre contrôle** : le script n'envoie rien, et rien ne part sans une action de votre part. Vous pouvez ouvrir les CSV (par exemple dans Excel) pour les relire avant l'envoi.
- Pour votre information, le script n'effectue aucune analyse : c'est 3SR qui exploitera ces données brutes.

## 7. Supprimer les données ensuite

1. **Supprimez les résultats** à la fin de l'usage convenu avec 3SR (au plus tard à la fin du projet) : le dossier de sortie (`collecte-resultats` par défaut) et l'archive `collecte-<8 caractères>.zip`, ainsi que tout exemplaire copié ailleurs (messagerie, dossier de téléchargement, corbeille). Exemple :

   ```powershell
   Remove-Item -Recurse -Force .\collecte-resultats
   ```

2. **Supprimez le script** et son dossier `lib` si vous n'en avez plus l'usage.
3. **Retirez l'application d'entreprise « Microsoft Graph Command Line Tools »** du tenant si vous ne l'utilisez pas par ailleurs : Microsoft Entra, Applications d'entreprise, sélectionnez l'application, puis Supprimer. D'autres outils Microsoft de connexion (Exchange Online, SharePoint Online) peuvent apparaître de la même façon.
4. Facultatif : désinstallez les modules (`Uninstall-Module Microsoft.Graph.Authentication`, etc.) si vous ne les utilisez pas.

Le script se déconnecte de Graph à la fin de la collecte. Fermer la console termine les sessions restantes.

## 8. Vérifier le script avant de l'exécuter

Les notes de version publient l'**empreinte SHA-256** de chaque fichier. Pour calculer l'empreinte du script principal et la comparer à celle des notes de version :

```powershell
Get-FileHash -Algorithm SHA256 .\cloudiway-collector.ps1
```

Pour calculer l'empreinte de tous les fichiers du dossier :

```powershell
Get-ChildItem -Recurse -File | Get-FileHash -Algorithm SHA256 | Select-Object Hash, Path
```

Une empreinte différente signifie que le fichier n'est pas celui qui a été publié : ne l'exécutez pas et prévenez votre contact 3SR. Calculez l'empreinte sur les fichiers tels que téléchargés dans l'archive de la version publiée (une récupération par `git clone` avec conversion automatique des fins de ligne peut modifier les fichiers et donc leur empreinte). Le script étant un fichier texte, vous pouvez aussi le lire avant de l'exécuter.

Le script peut être testé sans aucune connexion avec le banc de tests fourni (cmdlets simulées, sans réseau) :

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

## 9. Dépannage

| Symptôme | Cause probable et action |
|---|---|
| `cloudiway-collector.cmd` propose d'installer PowerShell 7 | PowerShell 7 est absent. Acceptez (O), ou téléchargez-le sur https://aka.ms/powershell-release?tag=stable puis relancez. |
| Fichiers « bloqués » / erreur de politique d'exécution | Le lanceur débloque les fichiers. Sinon : `Get-ChildItem -Path . -Recurse -File \| Unblock-File`. |
| Message « Des prérequis manquent » | Lisez le tableau : réseau, module, droits d'écriture. Aucune connexion n'a été tentée ; corrigez puis relancez. Pour un module : la commande d'installation exacte est affichée. |
| Droits administrateur du poste demandés pour un module | Ouvrez PowerShell 7 **en tant qu'administrateur**, exécutez la commande `Install-Module ... -Scope AllUsers` affichée, puis relancez dans une console normale. |
| « Connexion refusée : le tenant ou le compte ne correspond pas » | Le compte choisi dans la fenêtre n'est pas celui de `-User` (ou son alias diffère de l'UPN). Relancez et choisissez exactement le compte demandé ; utilisez l'UPN exact. |
| Arrêt dès la première étape, lecture de l'organisation impossible | Consentement administrateur manquant. Connectez-vous avec un Administrateur général et acceptez le consentement. |
| « Le compte n'a pas les accès indispensables » | Rôle insuffisant (voir [section 2](#2-droits-exigés)) ; le point refusé et le rôle attendu sont indiqués. |
| La fenêtre SharePoint ou Exchange a expiré | Relancez la même commande (la collecte complète est refaite), ou relancez la seule partie concernée (`-Parts SharePoint`). |
| `[KO]` Exchange ou SharePoint « accès refusé » | Le compte n'a pas le rôle Exchange ou SharePoint requis ; la partie est ignorée proprement. Relancez avec un compte adéquat. |
| `[NON DISPO]` | Licence ou rôle absent (Entra ID P1 ou P2, Intune...) : sans gravité, rien à faire. |
| « Fichier verrouillé : fermez Excel » | Un CSV est ouvert dans Excel. Fermez-le puis relancez. |
| Rapports d'usage anonymisés | Le tenant masque les noms dans les rapports (paramètre Microsoft 365). Information, pas une erreur. |
| La création du zip a échoué (code de sortie 2) | Compressez le dossier de résultats à la main (tous les fichiers à la racine de l'archive). |
| Mise à jour du module Exchange demandée | Un module trop ancien est traité comme manquant ; acceptez la mise à jour, puis ouvrez une nouvelle console si un module plus ancien était déjà chargé. |

Codes de sortie : **0** l'archive a été créée ; **1** arrêt avant ou pendant la connexion (prérequis, accès, refus de compte) ; **2** la création de l'archive a échoué. Le code de sortie des processus Exchange et SharePoint est consigné dans `capabilities.csv`.

## 10. Référence des options

| Option | Obligatoire | Description |
|---|---|---|
| `-TenantId <GUID>` | oui | Identifiant (GUID) du tenant à collecter. |
| `-User <UPN>` | oui | Compte administrateur qui se connecte ; toute autre identité est refusée. |
| `-Role Source\|Target` | non (défaut `Source`) | `Source` : tenant à migrer, volumes complets. `Target` : tenant de destination, collecte allégée (conflits et sécurité). |
| `-Parts <liste>` | non (défaut : toutes) | `Identity`, `Devices`, `Security`, `Dns`, `Exchange`, `SharePoint`. |
| `-OutDir <dossier>` | non | Dossier de sortie (défaut `collecte-resultats` à côté du script). Un dossier de collecte existant est repris. |
| `-InstallMissingModules` | non | Installe sans question les modules manquants (profil de l'utilisateur). |

Avec le lanceur, une seule valeur par option est transmise : `-Parts Exchange` fonctionne, une liste (`-Parts Exchange,SharePoint`) exige l'appel direct du script avec `-Command` (voir [section 4](#4-exécution-pas-à-pas)).
