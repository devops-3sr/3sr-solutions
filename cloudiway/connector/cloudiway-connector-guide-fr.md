# cloudiway-connector : guide d'utilisation

English version: [cloudiway-connector-guide-en.md](cloudiway-connector-guide-en.md)

`cloudiway-connector` est un script PowerShell qui **configure un tenant Microsoft 365 « source »** pour un connecteur Cloudiway, puis **crée ou met à jour ce connecteur** dans votre projet Cloudiway. Il remplace la suite d'opérations manuelles décrites dans la documentation Cloudiway (inscription d'application, permissions, consentement, rôles Exchange, certificat, liste EWS, saisie du connecteur dans le portail).

Cette version (2.4) ne couvre que :

- le **mode Source** (le tenant que l'on migre) ;
- les charges de travail **Mail** et **OneDrive**.

Le mode Cible n'est pas encore disponible : il arrivera dans une version ultérieure. Les autres charges de travail (SharePoint, Teams, Archive, GalSync, Intune, FreeBusy, Signature, MailRouting) ne sont pas disponibles dans cette version : le script les refuse avec un message clair.

## À lire d'abord : ce script MODIFIE votre tenant

**Ce n'est pas un outil de lecture seule.** Lancé sans `-WhatIf`, il crée et modifie des objets dans votre tenant Microsoft 365, dans Exchange Online et dans votre projet Cloudiway. Voici la liste exacte, avec les droits que cela donne à l'application.

| # | Où | Ce qui est créé ou modifié |
|---|---|---|
| 1 | Microsoft Entra | Une **inscription d'application** `CLOUDIWAY-SOURCE-P<numéro du projet>` (étiquette `CloudiwayConnector`, tenant unique). |
| 2 | Microsoft Entra | Son **principal de service** (application d'entreprise). |
| 3 | Microsoft Entra | Les **permissions d'application** déclarées sur l'inscription, et leur **consentement administrateur** (voir la liste ci-dessous). |
| 4 | Microsoft Entra | Un consentement délégué limité à `User.Read` (Microsoft Graph). |
| 5 | Microsoft Entra | Les rôles d'annuaire **Exchange Administrator** et **Exchange Recipient Administrator**, attribués **au principal de service de l'application** (charge Mail seulement). |
| 6 | Microsoft Entra | Un **certificat** (RSA 2048, SHA-256, sujet `CN=Cloudiway-SOURCE-P<projet>`), généré en mémoire, dont la partie publique est ajoutée aux clés de l'application. |
| 7 | Exchange Online | L'**AppID de l'application est ajouté à `EwsAllowedAppIDs`** (charge Mail seulement ; ajout seul, avec confirmation et avertissement si la liste est vide, voir [section 9](#9-la-liste-ews-exchange-online)). |
| 8 | Cloudiway | Un **connecteur** `<préfixe du domaine .onmicrosoft.com>-source` créé ou mis à jour dans votre projet (certificat, mot de passe du certificat, identifiant de l'application, domaine, région, produits Cloudiway). |
| 9 | Votre poste | Un dossier de résultats (`run.log` et `Rapport-...md`, sans secret) ; les modules PowerShell manquants si vous utilisez `-InstallMissingModules` ; le consentement de l'application Microsoft « Microsoft Graph Command Line Tools » (voir [section 5](#5-exécution-pas-à-pas)). |

**Permissions d'application accordées à l'application** (moindre privilège calculé d'après les charges choisies) :

| Charge | Microsoft Graph | Exchange Online | SharePoint Online |
|---|---|---|---|
| Mail | `MailboxSettings.ReadWrite` | `Exchange.ManageAsApp`, `full_access_as_app` | (aucune) |
| OneDrive | `User.Read.All`, `Files.ReadWrite.All`, `Sites.FullControl.All`, `Directory.Read.All` | (aucune) | `Sites.FullControl.All`, `User.Read.All` |

Ces permissions sont **larges** (accès aux boîtes aux lettres et aux fichiers de tous les utilisateurs) : ce sont celles que demande Cloudiway pour migrer. Elles sont portées par l'application, pas par un compte nominatif ; c'est pourquoi la fin du projet doit comprendre leur retrait ([section 11](#11-retirer-les-objets-en-fin-de-projet)).

**Ce que le script ne fait pas**

- Il **ne supprime rien** dans le tenant ni dans Cloudiway, à **une seule exception** : les **anciens certificats créés par l'outil lui-même** (nom commençant par `Cloudiway-SOURCE-P<projet>`) sont retirés de l'application, après l'écriture réussie du nouveau certificat dans le connecteur. Toute autre clé de l'application (posée à la main) est conservée.
- Il **n'écrit, n'affiche et ne journalise aucun secret** : le certificat et son mot de passe sont générés en mémoire, envoyés directement à Cloudiway, puis effacés. Aucun fichier `.pfx`, aucun mot de passe, aucun état n'est écrit sur le disque.
- Il **ne lit aucun contenu de messagerie** ni de fichier. Il lit de la configuration : organisation, applications, principaux de service, rôles, octrois de permissions, configuration EWS d'Exchange Online, liste des projets et connecteurs Cloudiway.
- Il **n'attribue aucune licence** et **ne crée aucun compte de service** : en mode Source avec Mail et OneDrive, aucun compte utilisateur n'est créé ni modifié.
- Il ne modifie ni ne désactive aucune stratégie d'accès conditionnel, ni l'authentification multifacteur.

**Commencez toujours par `-WhatIf`** : le script affiche alors le plan complet (ce qu'il créerait ou modifierait) sans rien écrire. Voir [section 5](#5-exécution-pas-à-pas).

## Sommaire

1. [Ce que fait le script, dans l'ordre](#1-ce-que-fait-le-script-dans-lordre)
2. [Pourquoi une seule personne l'exécute](#2-pourquoi-une-seule-personne-lexécute)
3. [Prérequis](#3-prérequis)
4. [Étape préalable : l'invitation au projet Cloudiway](#4-étape-préalable--linvitation-au-projet-cloudiway)
5. [Exécution pas à pas](#5-exécution-pas-à-pas)
6. [Objets créés et noms codifiés](#6-objets-créés-et-noms-codifiés)
7. [Renouvellement : chaque exécution renouvelle le certificat](#7-renouvellement--chaque-exécution-renouvelle-le-certificat)
8. [Lire le résultat](#8-lire-le-résultat)
9. [La liste EWS d'Exchange Online](#9-la-liste-ews-exchange-online)
10. [Fichiers produits](#10-fichiers-produits)
11. [Retirer les objets en fin de projet](#11-retirer-les-objets-en-fin-de-projet)
12. [Vérifier le script avant de l'exécuter](#12-vérifier-le-script-avant-de-lexécuter)
13. [Dépannage](#13-dépannage)
14. [Codes de sortie](#14-codes-de-sortie)
15. [Référence des options](#15-référence-des-options)
16. [Ce qui n'a pas encore été validé en réel](#16-ce-qui-na-pas-encore-été-validé-en-réel)
17. [Limites de cette version](#17-limites-de-cette-version)

## 1. Ce que fait le script, dans l'ordre

1. **Contrôle le poste** : PowerShell 7.2, module Microsoft Graph, module Exchange Online (charge Mail), accès réseau, dossier de résultats, domaine du tenant.
2. **Se connecte au portail Cloudiway** avec **votre** compte (mot de passe saisi masqué, ou jeton PAT), détecte le projet et lit le connecteur existant. Cette étape se fait **avant** toute écriture dans le tenant : si Cloudiway est inaccessible, rien n'est modifié.
3. **Se connecte au tenant** (fenêtre de connexion Microsoft, ou code d'appareil) avec le compte `-Admin365`, et **vérifie strictement** que le tenant et le compte connectés sont ceux demandés. En cas d'écart, il s'arrête sans rien lire ni écrire.
4. **Lit l'état du tenant** et **affiche un plan** : pour chaque élément, `CRÉER`, `METTRE À JOUR`, `OK`, `BLOQUÉ` ou `IGNORÉ`, avec la raison. Avec `-WhatIf`, le script s'arrête ici.
5. **Demande confirmation**, puis applique dans cet ordre : application, principal de service, permissions, consentement, rôles Exchange, liste EWS, certificat, connecteur Cloudiway, puis nettoyage des anciens certificats de l'outil (seulement après l'écriture réussie du connecteur).
6. **Relit chaque élément** pour vérifier la conformité (y compris le connecteur Cloudiway, relu après chaque écriture).
7. **Écrit un rapport et un journal**, sans aucun secret, avec les actions restant à faire.

Garde-fous : une ligne dont une dépendance a échoué est **ignorée** (jamais appliquée à moitié). Un objet existant au nom prévu mais sans l'étiquette `CloudiwayConnector` (créé à la main) n'est **pas modifié** sans `-AdoptExisting`. Un connecteur existant n'est jamais dégradé : les produits sont réunis (jamais retirés), le sens et la région ne sont jamais modifiés.

## 2. Pourquoi une seule personne l'exécute

Le script a besoin **en même temps** de deux accès :

- un compte **Administrateur général** du tenant à migrer (pour créer l'application, accorder le consentement, attribuer les rôles, modifier la configuration Exchange) ;
- un compte **invité sur le projet Cloudiway**, avec le rôle **Contributor** (pour créer ou mettre à jour le connecteur).

Une seule personne (en général le DSI du client) exécute donc le script du début à la fin, avec ses deux identités. C'est un choix de sécurité : le certificat est généré **en mémoire sur son poste** et envoyé directement à Cloudiway. Il ne passe par aucun fichier, aucun courrier, aucune messagerie instantanée, et personne d'autre n'en a connaissance.

## 3. Prérequis

| Prérequis | Détail |
|---|---|
| Poste | Windows, accès à Internet (`graph.microsoft.com`, `login.microsoftonline.com`, `api-production.cloudiway.com`, et Exchange Online pour la charge Mail). |
| PowerShell | **PowerShell 7.2 minimum** (`pwsh`). Le lanceur `cloudiway-connector.cmd` le vérifie et propose de l'installer avec `winget`, après votre confirmation. |
| Module `Microsoft.Graph.Authentication` | Obligatoire. `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser`, ou `-InstallMissingModules`. |
| Module `ExchangeOnlineManagement` | Obligatoire pour la charge **Mail** (inscription dans la liste EWS). `Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser`, ou `-InstallMissingModules`. |
| Compte Microsoft 365 | **Administrateur général** du tenant à migrer. |
| Compte Cloudiway | Invité sur le projet avec le rôle **Contributor** (voir [section 4](#4-étape-préalable--linvitation-au-projet-cloudiway)). **Le compte Cloudiway utilisé pour lancer le script ne doit pas avoir la double authentification (2FA) activée** ; si elle l'est, contactez votre contact 3SR avant de lancer le script (voir [section 16](#16-ce-qui-na-pas-encore-été-validé-en-réel)). |
| Fichiers | Le dossier complet (le dossier `lib` doit rester à côté du script). Fichiers téléchargés : **débloquez-les** (voir ci-dessous). |

**Débloquer les fichiers téléchargés.** Windows marque les fichiers téléchargés comme provenant d'Internet. Avant le premier lancement, exécutez dans PowerShell :

```powershell
Get-ChildItem -LiteralPath .\cloudiway-connector -Recurse -File | Unblock-File
```

Le lanceur `cloudiway-connector.cmd` le fait automatiquement.

**Le lanceur `cloudiway-connector.cmd`.** Double-cliquez dessus, ou lancez-le avec les mêmes options que le script (elles sont transmises telles quelles). Il fonctionne sous Windows PowerShell 5.1 (celui fourni avec Windows) : il débloque les fichiers, vérifie qu'une version 7.2 ou plus récente de PowerShell est installée, **propose de l'installer avec `winget` après confirmation**, puis lance `cloudiway-connector.ps1` sous PowerShell 7. Si vous lancez directement `cloudiway-connector.ps1` depuis Windows PowerShell 5.1, vous obtenez une erreur `#requires` : utilisez le lanceur ou ouvrez `pwsh`.

**Journalisation PowerShell d'entreprise.** Si votre poste active le *Module Logging*, le *Script Block Logging* ou la *Transcription*, PowerShell peut enregistrer les paramètres des commandes et le contenu des scripts, indépendamment de cet outil. Le script n'écrit jamais de secret dans ses propres fichiers, mais ne peut pas empêcher cette journalisation système : vérifiez-la avec votre service sécurité. Côté mémoire, les tableaux d'octets du certificat sont remis à zéro en fin d'exécution ; les chaînes .NET ne sont pas effaçables de façon fiable et sont libérées avec le processus : fermez la console en fin de travail.

## 4. Étape préalable : l'invitation au projet Cloudiway

Avant de lancer le script, votre contact 3SR vous fait inviter sur le projet Cloudiway avec le rôle **Contributor**.

1. Vous recevez un courrier d'invitation de Cloudiway. Utilisez le lien qu'il contient pour **initialiser votre mot de passe**.
2. Connectez-vous une fois au portail Cloudiway pour vérifier que le projet apparaît.
3. Notez l'adresse e-mail de l'invitation : c'est votre identifiant (`-Cloudiway`). Le numéro du projet (`-ProjectId`) est détecté automatiquement s'il n'y en a qu'un ; avec plusieurs projets, le script propose une liste, ou passez `-ProjectId 12345`.

**Le compte Cloudiway utilisé pour lancer le script ne doit pas avoir la double authentification (2FA) activée.** Constaté en réel (03/11/2026, chez un client) : avec la 2FA, la connexion au portail depuis le script ne fonctionne pas. Si elle est activée sur votre compte, contactez votre contact 3SR avant de lancer le script.

## 5. Exécution pas à pas

Les exemples utilisent des valeurs fictives : tenant `contoso.onmicrosoft.com`, administrateur `admin365@contoso.com`, compte Cloudiway `paul.bernard@contoso.com`, projet `12345`. Remplacez-les par les vôtres. Les commandes se lancent depuis le dossier du script.

### 5.1 Optionnel : découvrir le projet (`-Discover`)

Liste les connecteurs du projet Cloudiway, **sans aucune connexion au tenant et sans aucune écriture** :

```powershell
.\cloudiway-connector.cmd -Discover -Cloudiway paul.bernard@contoso.com
```

Avec `-ConnectorId 123`, la configuration (secrets masqués) du connecteur 123 est enregistrée dans `decouverte-123.json`. Utile pour relever la forme d'un connecteur créé à la main.

### 5.2 D'abord : simuler (`-WhatIf`)

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -ProjectId 12345 -Workloads Mail,OneDrive -WhatIf
```

Le script se connecte (Cloudiway, puis le tenant), **lit** l'état actuel, affiche le **plan** et s'arrête : **rien n'est écrit** dans le tenant ni dans Cloudiway. La lecture de la configuration EWS d'Exchange Online a lieu aussi en simulation (lecture seule). Relisez le plan : chaque ligne dit ce qui serait créé, mis à jour, ou bloqué, et pourquoi.

### 5.3 Appliquer

Même commande, sans `-WhatIf` :

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -ProjectId 12345 -Workloads Mail,OneDrive
```

Le script :

1. contrôle le poste (affiche un tableau de prérequis) ;
2. vous demande le **mot de passe Cloudiway** (saisie masquée, jamais affichée ni écrite) ;
3. ouvre la **fenêtre de connexion Microsoft** : connectez-vous avec le compte `-Admin365` ;
4. affiche le plan et demande **confirmation** (`O` pour appliquer) ;
5. applique, vérifie, écrit le rapport.

Si le plan contient une ligne `BLOQUÉ`, lisez la raison avant de continuer : elle indique quel droit ou quelle option manque.

**Consentement de « Microsoft Graph Command Line Tools ».** Pour agir dans votre tenant, le script se connecte avec l'application publique de Microsoft « Microsoft Graph Command Line Tools » et demande des droits délégués élevés : `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `DelegatedPermissionGrant.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `User.ReadWrite.All`, `Directory.Read.All`, `Policy.Read.All`, `Organization.Read.All`. Le consentement que vous acceptez dans la fenêtre Microsoft reste **enregistré dans le tenant** (pour votre compte, ou pour toute l'organisation si vous cochez la case correspondante). Pour le retirer en fin de projet : Entra > Applications d'entreprise > Microsoft Graph Command Line Tools > Autorisations.

### 5.4 Quand la fenêtre de connexion reprend le mauvais compte (`-UseDeviceCode`)

Si vous enchaînez plusieurs tenants, la fenêtre de connexion peut reprendre automatiquement un autre compte. Le script le détecte (compte ou tenant différent de ceux demandés) et s'arrête. Relancez avec `-UseDeviceCode` :

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -UseDeviceCode
```

Le script affiche une adresse et un code : ouvrez l'adresse dans une **fenêtre de navigation privée**, saisissez le code et connectez-vous avec `-Admin365`. Pour la charge Mail, la connexion Exchange Online utilise aussi un code d'appareil. Certains tenants bloquent ce flux par accès conditionnel ; dans ce cas, relancez sans `-UseDeviceCode`, depuis une session de navigateur propre.

### 5.5 Mode questions

Si un paramètre manque, **le script pose la question** (console interactive) avec un exemple et une validation immédiate : tenant, compte administrateur, charges de travail, compte Cloudiway. Rien n'est présélectionné : pour les charges, chacune indique les privilèges qu'elle ajoute. Lancez simplement :

```powershell
.\cloudiway-connector.cmd
```

Sans console interactive (tâche planifiée, pipeline), tous les paramètres indispensables doivent être fournis (le script affiche alors la commande complète à relancer).

### 5.6 Un simple contrôle, sans rien renouveler (`-KeepCredentials`)

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -KeepCredentials
```

Sans cette option, **chaque exécution renouvelle le certificat** (voir [section 7](#7-renouvellement--chaque-exécution-renouvelle-le-certificat)). Avec `-KeepCredentials`, le script ne régénère ni n'envoie rien tant que le certificat du connecteur est cohérent et valable plus de 30 jours : c'est un contrôle de conformité. Si une mise à jour du connecteur était nécessaire (par exemple un produit manquant), la ligne Cloudiway est **BLOQUÉE** : le portail exige le certificat lors d'une mise à jour, relancez alors sans `-KeepCredentials`.

### 5.7 Sans console Windows : `pwsh` directement

Le lanceur est facultatif. Depuis PowerShell 7 :

```powershell
pwsh -NoProfile -File .\cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -WhatIf
```

Avec `-File`, plusieurs charges se passent en une seule valeur séparée par des virgules (`Mail,OneDrive`).

## 6. Objets créés et noms codifiés

Les noms sont **codifiés** : c'est ce qui rend les objets réutilisables d'une exécution à l'autre (aucun doublon d'application ou de connecteur).

| Objet | Nom | Exemple |
|---|---|---|
| Inscription d'application et principal de service | `CLOUDIWAY-SOURCE-P<projet>` | `CLOUDIWAY-SOURCE-P12345` |
| Certificat (sujet) | `CN=Cloudiway-SOURCE-P<projet>` | `CN=Cloudiway-SOURCE-P12345` |
| Connecteur Cloudiway | `<préfixe du domaine .onmicrosoft.com>-source` | `contoso-source` |

Le préfixe du domaine est le début complet du domaine `.onmicrosoft.com` du tenant (jamais tronqué). Les options `-AppName` et `-ConnectorName` permettent de choisir d'autres noms. Le connecteur porte un **marqueur de suivi** : le nom de fichier de son certificat, de la forme `CIW1_<empreinte>_<AAAAMMJJ>.pfx`, qui permet au script de reconnaître son propre certificat et sa date d'expiration.

Le certificat est valable **180 jours** par défaut (`-ValidityDays`, de 45 à 730).

## 7. Renouvellement : chaque exécution renouvelle le certificat

**Chaque exécution (hors `-WhatIf`) renouvelle le certificat.** Concrètement, à chaque lancement :

1. un **nouveau certificat** est généré en mémoire et ajouté à l'application ;
2. le **connecteur Cloudiway est mis à jour** avec ce nouveau certificat (le certificat est remplacé sur place) ;
3. le script **relit le connecteur** et ne considère l'écriture confirmée que si le nom de fichier du certificat relu est bien celui envoyé ;
4. seulement alors, les **anciens certificats créés par l'outil** sont retirés de l'application (jamais avant : un connecteur ne perd jamais son authentification). Les clés posées à la main sont conservées. L'identifiant (`keyId`) et l'empreinte de chaque clé retirée figurent dans le rapport et le journal.

**Attention : ne relancez pas le script pendant que des jobs de migration sont actifs.** Un connecteur existant est mis à jour à chaque exécution ; des jobs en cours peuvent échouer pendant le remplacement du certificat. Attendez la fin des jobs (ou suspendez-les dans le portail Cloudiway). Pour un simple contrôle de conformité, utilisez `-KeepCredentials`.

Si l'écriture du connecteur échoue ou ne peut pas être confirmée, **aucun ancien certificat n'est retiré** et le code de sortie est 2 : relancez la même commande, le script reprend là où il s'est arrêté.

## 8. Lire le résultat

À l'écran, puis dans le rapport :

- **Plan** : action prévue pour chaque élément.
- **Application** : résultat de chaque action (`APPLIQUÉ`, `ÉCHEC`, `IGNORÉ`).
- **Vérification** : relecture de chaque objet (`Conforme`, `À vérifier`, `NON CONFORME`).
- **À faire** : actions réelles que le script n'a pas pu réaliser (par exemple le consentement administrateur manquant, avec le lien à ouvrir, ou l'étape Exchange à faire à la main, avec les commandes exactes). Le groupe n'apparaît que s'il y a quelque chose à faire.
- **À vérifier** : informations et contrôles que le script ne peut pas automatiser (par exemple la date d'expiration du certificat, ou une liste EWS vide).

Le script ne se déclare « conforme » que si **tout** a été relu et confirmé. Voir [section 14](#14-codes-de-sortie) pour les codes de sortie.

## 9. La liste EWS d'Exchange Online

Pour la charge **Mail**, Cloudiway utilise EWS. Si votre organisation restreint EWS à une liste d'applications (`EwsAllowedAppIDs`), l'application Cloudiway doit y figurer. Le script :

1. se connecte à Exchange Online avec le compte `-Admin365` ;
2. **lit** la configuration (`Get-OrganizationConfig`), y compris en simulation ;
3. **ajoute** l'AppID de l'application à `EwsAllowedAppIDs` : ajout seul, **jamais de remplacement ni de retrait** des entrées existantes.

**Avertissement : une liste vide devient restrictive.** Si `EwsAllowedAppIDs` est **vide**, y inscrire une première application la rend **restrictive pour toutes les autres applications EWS du tenant** (outils de sauvegarde, applications mobiles tierces, etc.) qui n'y figurent pas : elles seraient **bloquées**. Le script demande donc une **confirmation explicite séparée** (réponse par défaut : non). Sans confirmation, rien n'est écrit et la ligne passe en « À vérifier » avec les commandes exactes ; avec `-Yes`, rien n'est écrit non plus, sauf si vous ajoutez `-AllowEwsListCreation`. Si la liste contient déjà des entrées, l'AppID y est simplement ajouté.

Si `EwsEnabled` vaut `False` (EWS désactivé pour l'organisation), **rien n'est écrit** : c'est une décision du tenant, signalée dans « À vérifier ».

Tout échec Exchange (module absent, connexion, lecture, écriture) est **non bloquant** : le reste est configuré, l'étape devient un « À faire » manuel avec les commandes exactes, et le code de sortie est 2.

## 10. Fichiers produits

Le script écrit dans un dossier `connecteur-resultats` à côté du script (ou, si le dossier du script est synchronisé ou partagé, dans `%LOCALAPPDATA%\CloudiwayConnector`, ce qu'il signale ; `-OutDir` permet de choisir). Chaque exécution crée un sous-dossier `<préfixe>-Source-<AAAAMMJJ-HHMM>` contenant **uniquement** :

| Fichier | Contenu |
|---|---|
| `run.log` | Journal de l'exécution : prérequis, plan, résultat de chaque étape, vérifications. **Aucun secret.** Il contient le nom du tenant, son domaine, les noms d'objets et le compte administrateur. |
| `Rapport-<préfixe>-Source.md` | Rapport lisible : paramètres, plan, résultat, vérification, « À faire » et « À vérifier ». **Aucun secret, aucun contenu de certificat.** Il contient des identifiants du tenant (GUID de l'application et du principal de service, empreinte du certificat, date d'expiration). |
| `decouverte-<id>.json` | Seulement avec `-Discover -ConnectorId <id>` : configuration du connecteur, secrets masqués. |

**Aucun fichier de certificat, de mot de passe ou d'état n'est écrit.** Le rapport contenant des identifiants de tenant, évitez un dossier synchronisé ou partagé.

## 11. Retirer les objets en fin de projet

Le script ne supprime rien (hors anciens certificats de l'outil). **À la fin du projet de migration, retirez vous-même les objets suivants**, car l'application dispose de permissions étendues sur les boîtes aux lettres et les fichiers.

**1. Le connecteur Cloudiway.** Dans le portail Cloudiway, supprimez le connecteur `<préfixe>-source` (ou demandez à votre contact 3SR de le faire).

**2. L'entrée dans la liste EWS (Exchange Online).** Retirez l'AppID de l'application de `EwsAllowedAppIDs` (l'AppID figure dans le rapport, section « Valeurs à connaître », et dans Entra) :

```powershell
Connect-ExchangeOnline -UserPrincipalName 'admin365@contoso.com'
Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs
$ids = @((Get-OrganizationConfig).EwsAllowedAppIDs) | Where-Object { $_ -and $_ -ne '<AppID de l''application>' }
Set-OrganizationConfig -EwsAllowedAppIDs ($ids -join ',')
```

Si l'AppID était la seule entrée, la liste se retrouve vide : consultez la documentation Microsoft de `Set-OrganizationConfig` pour la procédure à suivre dans ce cas. Ce cas n'a pas été exercé par l'outil. Si vous aviez confirmé la création de la liste (liste initialement vide), pensez que les autres applications EWS retrouvent leur accès une fois la liste vidée.

**3. L'attribution des rôles Exchange.** Dans le centre d'administration Microsoft Entra : **Rôles et administrateurs** > **Exchange Administrator** > **Attributions** : retirez l'application `CLOUDIWAY-SOURCE-P<projet>`. Faites de même pour **Exchange Recipient Administrator**.

**4. L'application.** Dans Entra : **Inscriptions d'applications** > `CLOUDIWAY-SOURCE-P<projet>` > **Supprimer**. Vérifiez ensuite que l'application d'entreprise correspondante (**Applications d'entreprise**) a disparu ; supprimez-la sinon. Cette suppression retire les permissions, le consentement et les certificats de l'application.

**5. Le consentement de l'application Microsoft « Microsoft Graph Command Line Tools »** (voir [section 5](#5-exécution-pas-à-pas)) : Entra > Applications d'entreprise > Microsoft Graph Command Line Tools > Autorisations : révoquez les autorisations accordées pour ce projet.

**6. Les résultats locaux.** Supprimez le dossier `connecteur-resultats` (il contient des identifiants de tenant).

## 12. Vérifier le script avant de l'exécuter

Le script est livré en **clair** : lisez-le avant de l'exécuter, notamment `lib\entra.ps1` (écritures Entra), `lib\exchange.ps1` (écritures Exchange) et `lib\cloudiway.ps1` (écritures Cloudiway). Il ne contient aucun appel `DELETE`.

**Empreinte SHA-256.** Votre contact 3SR vous communique les empreintes SHA-256 de la version qui vous est destinée (notes de version). Calculez celles de vos fichiers et comparez :

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\cloudiway-connector.ps1, .\lib\entra.ps1, .\lib\exchange.ps1, .\lib\cloudiway.ps1 | Format-Table Hash, Path -AutoSize
```

Les fichiers sont publiés en UTF-8 avec BOM et fins de ligne CRLF : une conversion automatique de fins de ligne par votre outil de téléchargement (Git, archive) change l'empreinte.

**Tests hors ligne.** `tests\run-tests.ps1` exécute le script et ses bibliothèques contre un faux tenant et un faux portail Cloudiway en mémoire (aucune connexion, aucun réseau) :

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

Compter environ cinq minutes. Le banc vérifie notamment qu'aucun secret n'est écrit, qu'aucune requête `DELETE` n'est émise, l'ordre des opérations, la vérification du certificat par nom de fichier avant tout retrait, et le comportement de la liste EWS (ajout seul, confirmation sur liste vide).

## 13. Dépannage

| Symptôme | Cause probable et action |
|---|---|
| Erreur `#requires` au lancement | Le script est lancé depuis Windows PowerShell 5.1. Utilisez `cloudiway-connector.cmd` ou ouvrez `pwsh` (PowerShell 7.2 minimum). |
| `pwsh` introuvable ou trop ancien | Le lanceur propose l'installation avec `winget` après confirmation ; sinon `winget install --id Microsoft.PowerShell -e`. |
| Module manquant | `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser` (et `ExchangeOnlineManagement` pour Mail), ou `-InstallMissingModules`. |
| « Connexion refusée : le tenant ou le compte ne correspond pas » | La fenêtre de connexion a repris un autre compte. Relancez en choisissant exactement le compte `-Admin365`, ou avec `-UseDeviceCode`. Pour un compte **invité** (identifiant contenant `#EXT#`), `-Admin365` doit être l'identifiant exact tel que le tenant l'affiche, et l'invité doit être Administrateur général **dans ce tenant**. |
| `AADSTS65001` | Le consentement n'a pas été donné pour « Microsoft Graph Command Line Tools » : reconnectez-vous avec un Administrateur général et acceptez la fenêtre de consentement. |
| `AADSTS90094` | Le consentement administrateur est requis et le compte n'est pas Administrateur général (activez le rôle si vous passez par PIM). |
| `AADSTS53003` | Accès bloqué par l'accès conditionnel (poste, localisation, application) : utilisez un poste ou un réseau autorisé, ou demandez une exception. |
| `AADSTS50076` | Authentification multifacteur exigée : terminez la validation dans la fenêtre Microsoft puis relancez. |
| « Le compte n'est pas Administrateur général » | Les actions qui l'exigent sont **BLOQUÉES** dans le plan et rien n'est écrit (code 1). Utilisez un compte Administrateur général. |
| Accès Cloudiway impossible | Vérifiez l'identifiant, le mot de passe (initialisé via l'invitation), que le compte est invité avec le rôle Contributor, et `-ProjectId`. Si la double authentification est activée sur le compte Cloudiway, la connexion ne fonctionne pas (limite constatée en réel, voir [section 16](#16-ce-qui-na-pas-encore-été-validé-en-réel)) : contactez votre contact 3SR. |
| Plusieurs projets visibles | Choisissez dans la liste, ou passez `-ProjectId 12345`. |
| Ligne Cloudiway `BLOQUÉ` : collision de noms | Un connecteur du même nom désigne un autre tenant ou une autre application. Choisissez un autre `-ConnectorName`, ou `-AdoptExisting` si vous êtes sûr. |
| Ligne `BLOQUÉ` : objet existant sans étiquette | Application ou connecteur créé à la main au nom prévu. `-AdoptExisting` le reprend (le certificat et l'identifiant d'application d'un connecteur adopté sont **remplacés** ; confirmation supplémentaire demandée). |
| Étape Exchange en « À faire » | Module absent, connexion ou écriture en échec : exécutez les commandes affichées dans « À faire », ou relancez la même commande. Code de sortie 2. |
| Poste derrière un proxy d'entreprise | Le script utilise les identifiants Windows de l'utilisateur pour le proxy ; vérifiez les variables `HTTPS_PROXY` / `HTTP_PROXY` si le proxy impose un réglage particulier. Non validé en réel sur un proxy authentifié (voir [section 16](#16-ce-qui-na-pas-encore-été-validé-en-réel)). |
| Deux lanceurs en même temps | Lancez **un seul** lanceur à la fois : deux exécutions simultanées sur le même projet peuvent produire des doublons (applications ou connecteurs). Vérifiez dans Entra et dans le portail Cloudiway. |
| « Dossier de sortie à risque » | Le dossier est synchronisé ou partagé : utilisez `-OutDir` vers un dossier local non synchronisé. |

## 14. Codes de sortie

| Code | Signification |
|---|---|
| `0` | Conforme : tout est appliqué et vérifié (ou simulation réussie). |
| `1` | Arrêt **avant toute écriture** : prérequis manquant, accès impossible, droits insuffisants, refus, annulation, ou lignes bloquées sans rien d'applicable. |
| `2` | Appliqué **avec des éléments en échec, ignorés, bloqués ou non conformes** (étape Exchange manuelle comprise). Relancez la même commande après avoir lu le rapport. |

Le lanceur `cloudiway-connector.cmd` transmet ces codes. Il ajoute ses propres codes : `10` (PowerShell 7.2 absent et non installé), `11` (installé mais introuvable depuis cette fenêtre : fermez-la et relancez), `12` (script principal introuvable), `13` (lancement impossible).

## 15. Référence des options

| Option | Rôle |
|---|---|
| `-Mode Source` | Seule valeur acceptée dans cette version (défaut). Le mode Cible n'est pas encore disponible. |
| `-Tenant` | Domaine `xxxx.onmicrosoft.com` (ou domaine vérifié) ou GUID du tenant. Demandé si absent. |
| `-Admin365` (alias `-User`) | Compte Administrateur général du tenant. Le compte connecté doit être exactement celui-là. Demandé si absent. |
| `-Cloudiway` | Votre identifiant sur le portail Cloudiway. Le mot de passe est demandé masqué. Demandé si absent. |
| `-CloudiwayPat` | Jeton d'accès personnel Cloudiway (`SecureString`) à la place du mot de passe. **Non validé** : ce contournement existe dans l'outil mais n'a jamais été validé ; ne pas s'en servir comme solution à la 2FA. |
| `-ProjectId` | Numéro du projet Cloudiway. Détecté automatiquement si possible. |
| `-Workloads` | `Mail`, `OneDrive`, ou `All` (= les deux). Aucune valeur par défaut. Les autres charges sont refusées. |
| `-WhatIf` | Simulation : plan seul, rien n'est écrit. À faire en premier. |
| `-Discover` / `-ConnectorId` | Liste les connecteurs du projet (lecture seule, sans connexion au tenant) ; détail masqué d'un connecteur. |
| `-UseDeviceCode` | Connexion Graph (et Exchange) par code d'appareil. |
| `-KeepCredentials` | Contrôle de conformité : ne renouvelle rien tant que le certificat est cohérent et valable plus de 30 jours. |
| `-RotateCredentials` (alias `-RotateCertificate`) | Sans effet (le renouvellement est le comportement par défaut). Incompatible avec `-KeepCredentials`. |
| `-AuthMethod` | `Certificate` (défaut, recommandé), `Secret` ou `Both`. Seule la méthode `Certificate` a été validée en réel. |
| `-ValidityDays` | Validité des identifiants générés, de 45 à 730 jours (défaut 180). |
| `-AdoptExisting` | Autorise la reprise d'une application ou d'un connecteur existant sans l'étiquette de l'outil (remplace le certificat et l'identifiant d'application du connecteur). |
| `-AppName`, `-ConnectorName` | Remplacent les noms codifiés. |
| `-ServiceAccountName` | Sans effet avec Mail et OneDrive en mode Source (aucun compte de service n'est créé). |
| `-AllowEwsListCreation` | Autorise sans question la création de la liste EWS quand elle est vide (la rend restrictive pour les autres applications EWS). |
| `-SkipCloudiway` | Configure le tenant seulement, sans appel à Cloudiway (`-ProjectId` obligatoire ; aucun certificat n'est généré, faute de moyen de le transmettre). |
| `-ProductIds`, `-ProductMapFile` | Identifiants de produits Cloudiway (Mail = 5, Fichiers = 6) ; fichier de correspondance produit par `-Discover`. |
| `-Region` | Région serveur Cloudiway (défaut 1). |
| `-CertificateTransport` | `Base64` (défaut) ou `Path` (fichier temporaire protégé, supprimé aussitôt). Seul `Base64` est recommandé. |
| `-OutDir` | Dossier de base du rapport et du journal. |
| `-InstallMissingModules` | Installe sans question les modules PowerShell manquants (profil utilisateur, sans droits administrateur). |
| `-Yes` | Saute la confirmation du plan (usage scripté). Jamais activé implicitement. |

## 16. Ce qui n'a pas encore été validé en réel

État au 03/11/2026. Cette section est volontairement franche : le banc de test hors ligne couvre ces cas avec un faux tenant et un faux portail, mais un faux n'est pas la réalité.

**Validé en réel**

- Création et mise à jour d'un connecteur **Mail + OneDrive en Source** avec certificat.
- Vérification du certificat par nom de fichier (relecture du connecteur après écriture).
- Nettoyage des anciens certificats par `PATCH` (repli, voir ci-dessous).
- Code d'appareil pour Microsoft Graph.
- Écriture EWS : inscription de l'AppID dans `EwsAllowedAppIDs` quand la liste était vide (création de la liste, avec confirmation), sur un tenant de test.
- Connexion Exchange par code d'appareil.

**Non validé en réel, ou échec constaté**

- **Retrait des anciens certificats par `POST removeKey`** : Microsoft répond `403` en conditions réelles. L'outil retombe alors sur un `PATCH` qui ne garde que le nouveau certificat, et **ce repli est validé en réel** ; le retrait par `removeKey` n'est donc pas utilisé en pratique.
- **Ajout de l'AppID à une liste EWS qui contient déjà d'autres applications** : jamais exercé en réel (seule la création sur liste vide l'a été).
- **Rotation du mot de passe d'un compte de service** : `HTTP 403` constaté sur le tenant cible lors d'un essai ; **non applicable** en Source avec Mail et OneDrive, car aucun compte de service n'y est créé.
- **Compte invité (B2B)** comme administrateur du tenant.
- **Poste derrière un proxy authentifié.**
- **Windows PowerShell 5.1 sur un poste vierge** (lanceur `.cmd`).
- **Rôle Lecteur général** (Global Reader) : le script exige un Administrateur général pour écrire ; le comportement avec le seul rôle Lecteur général n'a pas été éprouvé.

### Limites connues constatées

- **Double authentification (2FA) sur le compte Cloudiway : la connexion au portail depuis le script NE FONCTIONNE PAS.** Constaté en réel le 03/11/2026, chez un client. Prérequis explicite : le compte Cloudiway utilisé pour lancer le script ne doit pas avoir la 2FA activée ; si elle l'est, contactez votre contact 3SR. Un contournement par jeton d'accès personnel (`-CloudiwayPat`) existe dans l'outil, et le script l'évoque dans son message d'erreur, mais il n'a **jamais été validé** : ne le considérez pas comme une solution.

Par prudence, considérez aussi comme non validés en réel les options `-AuthMethod Secret` et `Both`, `-CertificateTransport Path` et un `-Region` différent de 1 : seule la configuration par défaut (certificat, transport Base64, région 1) est décrite comme validée ci-dessus.

## 17. Limites de cette version

- **Mode Source seulement.** Le mode Cible n'est pas encore disponible ; il arrivera dans une version ultérieure.
- **Charges Mail et OneDrive seulement.** Les autres charges de travail sont refusées avec un message clair.
- Chaque exécution renouvelle le certificat et met à jour le connecteur existant : ne pas relancer pendant des jobs de migration actifs (voir [section 7](#7-renouvellement--chaque-exécution-renouvelle-le-certificat)).
- Le script ne retire pas ses objets en fin de projet : la procédure est manuelle (voir [section 11](#11-retirer-les-objets-en-fin-de-projet)).
- Aucun compte de service n'est créé ni utilisé.
- Le compte Cloudiway ne doit pas avoir la double authentification activée (voir [section 16](#16-ce-qui-na-pas-encore-été-validé-en-réel)).
