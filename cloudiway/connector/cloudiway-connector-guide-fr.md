# cloudiway-connector : guide d'utilisation

English version: [cloudiway-connector-guide-en.md](cloudiway-connector-guide-en.md)

`cloudiway-connector` est un script PowerShell qui **configure un tenant Microsoft 365** (« source » ou « cible ») pour un connecteur Cloudiway, puis **crée ou met à jour ce connecteur** dans votre projet Cloudiway. Il remplace la suite d'opérations manuelles décrites dans la documentation Cloudiway (inscription d'application, permissions, consentement, rôles Exchange, certificat, liste EWS, compte de service, saisie du connecteur dans le portail).

Cette version (2.7) couvre :

- le **mode Source** (le tenant que l'on migre) et le **mode Cible** (le tenant de destination) ;
- les charges de travail **Mail**, **OneDrive** et **SharePoint**.

Les autres charges de travail (Teams, Archive, GalSync, Intune, FreeBusy, Signature, MailRouting) ne sont pas disponibles dans cette version : le script les refuse (« non disponible dans cette version »), avant toute connexion.

**SharePoint : l'identifiant du produit Cloudiway est inconnu.** Tant qu'il n'est pas fourni (`-ProductIds` ou fichier `productmap.json`, voir [section 6](#6-la-charge-sharepoint-et-lidentifiant-de-produit-cloudiway)), le script **s'arrête au plus tôt** (code 1), **avant toute connexion et toute écriture** : rien n'est créé, ni dans le tenant, ni dans Cloudiway. Cela vaut aussi pour `-Workloads All`.

**UNE CONSOLE POWERSHELL PAR TENANT.** Si vous traitez plusieurs tenants, ouvrez une **nouvelle** console PowerShell pour chacun. Depuis la version 2.7, une session Exchange Online d'un autre tenant ouverte dans la console **arrête le script** (code 1) avant toute connexion et toute écriture (voir [section 5.8](#58-une-console-powershell-par-tenant)).

**Le compte de service est créé par défaut dès que Mail est demandé, même dans le tenant Source.** Cloudiway exige ensemble le certificat, le secret client et le compte administrateur (voir [section 7](#7-le-compte-de-service)).

## À lire d'abord : ce script MODIFIE votre tenant

**Ce n'est pas un outil de lecture seule.** Lancé sans `-WhatIf`, il crée et modifie des objets dans votre tenant Microsoft 365, dans Exchange Online et dans votre projet Cloudiway. Voici la liste exacte, avec les droits que cela donne à l'application.

| # | Où | Ce qui est créé ou modifié |
|---|---|---|
| 1 | Microsoft Entra | Une **inscription d'application** `CLOUDIWAY-SOURCE-P<numéro du projet>` ou `CLOUDIWAY-TARGET-P<numéro du projet>` (étiquette `CloudiwayConnector`, tenant unique). |
| 2 | Microsoft Entra | Son **principal de service** (application d'entreprise). |
| 3 | Microsoft Entra | Les **permissions d'application** déclarées sur l'inscription, et leur **consentement administrateur** (voir la liste ci-dessous). |
| 4 | Microsoft Entra | Un consentement délégué limité à `User.Read` (Microsoft Graph). |
| 5 | Microsoft Entra | Les rôles d'annuaire **Exchange Administrator** et **Exchange Recipient Administrator**, attribués **au principal de service de l'application** (charge Mail seulement). |
| 6 | Microsoft Entra | Un **certificat** (RSA 2048, SHA-256, sujet `CN=Cloudiway-SOURCE-P<projet>` ou `CN=Cloudiway-TARGET-P<projet>`) **et un secret client** (méthode `-AuthMethod Both`, par défaut : Cloudiway exige les deux), générés en mémoire ; la partie publique du certificat et le secret sont ajoutés à l'application. |
| 7 | Microsoft Entra | Un **compte de service** (utilisateur, compte administrateur du connecteur) dans les cas décrits à la [section 7](#7-le-compte-de-service) : **Mail (Source ET Cible, donc aussi dans le tenant Source)**, **OneDrive en mode Cible**, **SharePoint**. Ce compte reçoit le rôle d'annuaire **SharePoint Administrator**, et l'application est configurée pour accepter les flux de client public. Il n'est **jamais supprimé par l'outil** : le DSI le supprime en fin de projet. |
| 8 | Exchange Online | L'**AppID de l'application est ajouté à `EwsAllowedAppIDs`** (charge Mail seulement ; ajout seul, avec confirmation et avertissement si la liste est vide, voir [section 10](#10-la-liste-ews-dexchange-online)). |
| 9 | Cloudiway | Un **connecteur** `<préfixe du domaine .onmicrosoft.com>-source` ou `-target` créé ou mis à jour dans votre projet (certificat, mot de passe du certificat, secret client, identifiant de l'application, domaine, région, produits Cloudiway, et, avec un compte de service, son identifiant et son mot de passe). |
| 10 | Votre poste | Un dossier de résultats (`run.log` et `Rapport-...md`, sans secret) ; les modules PowerShell manquants si vous utilisez `-InstallMissingModules` ; le consentement de l'application Microsoft « Microsoft Graph Command Line Tools » (voir [section 5](#5-exécution-pas-à-pas)). |

**Permissions d'application accordées à l'application** (moindre privilège calculé d'après le mode et les charges choisies). En mode **Cible**, `Application.ReadWrite.All` et `Organization.Read.All` (Microsoft Graph) sont demandées dans tous les cas, en plus du tableau.

*Mode Source*

| Charge | Microsoft Graph | Exchange Online | SharePoint Online |
|---|---|---|---|
| Mail | `MailboxSettings.ReadWrite` | `Exchange.ManageAsApp`, `full_access_as_app` | (aucune) |
| OneDrive | `User.Read.All`, `Files.ReadWrite.All`, `Sites.FullControl.All`, `Directory.Read.All` | (aucune) | `Sites.FullControl.All`, `User.Read.All` |
| SharePoint | `Sites.FullControl.All`, `User.Read.All`, `Group.Read.All`, `Directory.Read.All` | (aucune) | `Sites.FullControl.All`, `User.Read.All` |

*Mode Cible*

| Charge | Microsoft Graph | Exchange Online | SharePoint Online |
|---|---|---|---|
| Mail | `MailboxSettings.ReadWrite` | `full_access_as_app`, `Exchange.ManageAsApp` | (aucune) |
| OneDrive | `User.Read.All`, `Files.ReadWrite.All`, `Sites.FullControl.All`, `InformationProtectionPolicy.Read.All`, `Group.ReadWrite.All`, `Directory.Read.All` | `Exchange.ManageAsApp` | `Sites.FullControl.All`, `User.ReadWrite.All` |
| SharePoint | `Sites.FullControl.All`, `User.ReadWrite.All`, `Group.ReadWrite.All`, `Application.ReadWrite.All`, `Directory.Read.All` | (aucune) | `Sites.FullControl.All`, `User.ReadWrite.All`, `TermStore.ReadWrite.All` |

Ces permissions sont **larges** (accès aux boîtes aux lettres, aux fichiers et aux sites de tous les utilisateurs, avec écriture en Cible) : ce sont celles que demande Cloudiway pour migrer. Elles sont portées par l'application, pas par un compte nominatif ; c'est pourquoi la fin du projet doit comprendre leur retrait ([section 12](#12-retirer-les-objets-en-fin-de-projet)).

**Ce que le script ne fait pas**

- Il **ne supprime rien** dans le tenant ni dans Cloudiway, à **une seule exception** : les **anciens certificats et anciens secrets clients créés par l'outil lui-même** (nom commençant par `Cloudiway-SOURCE-P<projet>` ou `Cloudiway-TARGET-P<projet>`) sont retirés de l'application, après l'écriture réussie et vérifiée du nouveau certificat et du nouveau secret dans le connecteur (certificats : preuve de possession ou repli `PATCH` ; secrets : `removePassword`, avec relecture et attente de propagation Entra). Toute autre clé de l'application (posée à la main) est conservée. Le compte de service n'est jamais supprimé par l'outil (le DSI le supprime en fin de projet, [section 12](#12-retirer-les-objets-en-fin-de-projet)).
- Il **n'écrit, n'affiche et ne journalise aucun secret** : le certificat, son mot de passe, le secret client et le mot de passe du compte de service sont générés en mémoire, envoyés directement à Cloudiway, puis effacés. Aucun fichier `.pfx`, aucun mot de passe, aucun état n'est écrit sur le disque.
- Il **ne lit aucun contenu de messagerie** ni de fichier. Il lit de la configuration : organisation, applications, principaux de service, utilisateurs et rôles, octrois de permissions, configuration EWS d'Exchange Online, liste des projets et connecteurs Cloudiway.
- Il **n'attribue aucune licence**, y compris au compte de service.
- Il ne modifie ni ne désactive aucune stratégie d'accès conditionnel, ni l'authentification multifacteur, ni les valeurs de sécurité par défaut du tenant.

**Commencez toujours par `-WhatIf`** : le script affiche alors le plan complet (ce qu'il créerait ou modifierait) sans rien écrire. Voir [section 5](#5-exécution-pas-à-pas).

## Sommaire

1. [Ce que fait le script, dans l'ordre](#1-ce-que-fait-le-script-dans-lordre)
2. [Pourquoi une seule personne l'exécute](#2-pourquoi-une-seule-personne-lexécute)
3. [Prérequis](#3-prérequis)
4. [Étape préalable : l'invitation au projet Cloudiway](#4-étape-préalable--linvitation-au-projet-cloudiway)
5. [Exécution pas à pas](#5-exécution-pas-à-pas)
6. [La charge SharePoint et l'identifiant de produit Cloudiway](#6-la-charge-sharepoint-et-lidentifiant-de-produit-cloudiway)
7. [Le compte de service](#7-le-compte-de-service)
8. [Objets créés et noms codifiés](#8-objets-créés-et-noms-codifiés)
9. [Renouvellement : chaque exécution renouvelle le certificat et le secret](#9-renouvellement--chaque-exécution-renouvelle-le-certificat-et-le-secret)
10. [La liste EWS d'Exchange Online](#10-la-liste-ews-dexchange-online)
11. [Lire le résultat et fichiers produits](#11-lire-le-résultat-et-fichiers-produits)
12. [Retirer les objets en fin de projet](#12-retirer-les-objets-en-fin-de-projet)
13. [Vérifier le script avant de l'exécuter](#13-vérifier-le-script-avant-de-lexécuter)
14. [Dépannage](#14-dépannage)
15. [Codes de sortie](#15-codes-de-sortie)
16. [Référence des options](#16-référence-des-options)
17. [Ce qui est validé en réel, et ce qui ne l'est pas](#17-ce-qui-est-validé-en-réel-et-ce-qui-ne-lest-pas)
18. [Limites de cette version](#18-limites-de-cette-version)

## 1. Ce que fait le script, dans l'ordre

1. **Contrôle le poste** : PowerShell 7.2, module Microsoft Graph, module Exchange Online (charge Mail), accès réseau, dossier de résultats, domaine du tenant. Il s'arrête dès ce stade (code 1) si une session Exchange Online d'un autre tenant est déjà ouverte dans la console.
2. **Se connecte au portail Cloudiway** avec **votre** compte (mot de passe saisi masqué, ou jeton PAT), détecte le projet et lit le connecteur existant. Cette étape se fait **avant** toute écriture dans le tenant : si Cloudiway est inaccessible, rien n'est modifié.
3. **Se connecte au tenant** (fenêtre de connexion Microsoft, ou code d'appareil) avec le compte `-Admin365`, et **vérifie strictement** que le tenant et le compte connectés sont ceux demandés. En cas d'écart, il s'arrête sans rien lire ni écrire.
4. **Lit l'état du tenant** et **affiche un plan** : pour chaque élément, `CRÉER`, `METTRE À JOUR`, `OK`, `BLOQUÉ` ou `IGNORÉ`, avec la raison. Avec `-WhatIf`, le script s'arrête ici.
5. **Demande confirmation**, puis applique dans cet ordre : application, principal de service, permissions, consentement, rôles Exchange, liste EWS, certificat, compte de service, mot de passe du compte de service (réinitialisé **avant** l'écriture du connecteur, voir [section 7](#7-le-compte-de-service)), connecteur Cloudiway, puis nettoyage des anciens certificats et secrets de l'outil (seulement après l'écriture réussie du connecteur).
6. **Relit chaque élément** pour vérifier la conformité (y compris le connecteur Cloudiway, relu après chaque écriture).
7. **Écrit un rapport et un journal**, sans aucun secret, avec les actions restant à faire.

Garde-fous : une ligne dont une dépendance a échoué est **ignorée** (jamais appliquée à moitié). Un objet existant au nom prévu mais sans l'étiquette `CloudiwayConnector` (créé à la main) n'est **pas modifié** sans `-AdoptExisting`. Un connecteur existant n'est jamais dégradé : les produits sont réunis (jamais retirés), le sens et la région ne sont jamais modifiés.

## 2. Pourquoi une seule personne l'exécute

Le script a besoin **en même temps** de deux accès :

- un compte **Administrateur général** du tenant à configurer (pour créer l'application, accorder le consentement, attribuer les rôles, créer le compte de service, modifier la configuration Exchange) ;
- un compte **invité sur le projet Cloudiway**, avec le rôle **Contributor** (pour créer ou mettre à jour le connecteur).

Une seule personne (en général le DSI du client) exécute donc le script du début à la fin, avec ses deux identités. C'est un choix de sécurité : le certificat et le mot de passe du compte de service sont générés **en mémoire sur son poste** et envoyés directement à Cloudiway. Ils ne passent par aucun fichier, aucun courrier, aucune messagerie instantanée, et personne d'autre n'en a connaissance.

## 3. Prérequis

| Prérequis | Détail |
|---|---|
| Poste | Windows, accès à Internet (`graph.microsoft.com`, `login.microsoftonline.com`, `api-production.cloudiway.com`, et Exchange Online pour la charge Mail). |
| PowerShell | **PowerShell 7.2 minimum** (`pwsh`). Le lanceur `cloudiway-connector.cmd` le vérifie et propose de l'installer avec `winget`, après votre confirmation. |
| Module `Microsoft.Graph.Authentication` | Obligatoire. `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser`, ou `-InstallMissingModules`. |
| Module `ExchangeOnlineManagement` | Obligatoire pour la charge **Mail** (inscription dans la liste EWS). `Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser`, ou `-InstallMissingModules`. |
| Compte Microsoft 365 | **Administrateur général** du tenant à configurer. |
| Compte Cloudiway | Invité sur le projet avec le rôle **Contributor** (voir [section 4](#4-étape-préalable--linvitation-au-projet-cloudiway)). **Le compte Cloudiway utilisé pour lancer le script ne doit pas avoir la double authentification (2FA) activée** ; si elle l'est, contactez votre contact 3SR avant de lancer le script (voir [section 17](#17-ce-qui-est-validé-en-réel-et-ce-qui-ne-lest-pas)). |
| Console | **Une console PowerShell par tenant** (voir [section 5.8](#58-une-console-powershell-par-tenant)). |
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

Les exemples utilisent des valeurs fictives : tenant `contoso.onmicrosoft.com`, administrateur `admin365@contoso.com`, compte Cloudiway `paul.bernard@contoso.com`, projet `12345`. Remplacez-les par les vôtres. Les commandes se lancent depuis le dossier du script. Pour un tenant **cible**, remplacez `-Mode Source` par `-Mode Target`.

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

**Après chaque exécution du script, soumettez de nouveau l'audit du connecteur dans le portail Cloudiway, et vérifiez que la limite de licences du projet n'est pas à 0** (« Project Settings »).

**Consentement de « Microsoft Graph Command Line Tools ».** Pour agir dans votre tenant, le script se connecte avec l'application publique de Microsoft « Microsoft Graph Command Line Tools » et demande des droits délégués élevés : `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `DelegatedPermissionGrant.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `User.ReadWrite.All`, `Directory.Read.All`, `Policy.Read.All`, `Organization.Read.All`. Le consentement que vous acceptez dans la fenêtre Microsoft reste **enregistré dans le tenant** (pour votre compte, ou pour toute l'organisation si vous cochez la case correspondante). Pour le retirer en fin de projet : Entra > Applications d'entreprise > Microsoft Graph Command Line Tools > Autorisations.

### 5.4 Quand la fenêtre de connexion reprend le mauvais compte (`-UseDeviceCode`)

Si vous enchaînez plusieurs tenants, la fenêtre de connexion peut reprendre automatiquement un autre compte. Le script le détecte (compte ou tenant différent de ceux demandés) et s'arrête. Relancez avec `-UseDeviceCode` :

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -UseDeviceCode
```

Le script affiche une adresse et un code : ouvrez l'adresse dans une **fenêtre de navigation privée**, saisissez le code et connectez-vous avec `-Admin365`. Pour la charge Mail, la connexion Exchange Online utilise aussi un code d'appareil. Certains tenants bloquent ce flux par accès conditionnel ; dans ce cas, relancez sans `-UseDeviceCode`, depuis une session de navigateur propre.

### 5.5 Mode questions

Si un paramètre manque, **le script pose la question** (console interactive) avec un exemple et une validation immédiate : source ou cible, tenant, compte administrateur, charges de travail, compte Cloudiway. Rien n'est présélectionné : pour les charges, chacune indique les privilèges qu'elle ajoute. Lancez simplement :

```powershell
.\cloudiway-connector.cmd
```

Sans console interactive (tâche planifiée, pipeline), tous les paramètres indispensables doivent être fournis (le script affiche alors la commande complète à relancer).

### 5.6 Un simple contrôle, sans rien renouveler (`-KeepCredentials`)

```powershell
.\cloudiway-connector.cmd -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -KeepCredentials
```

Sans cette option, **chaque exécution renouvelle le certificat** (voir [section 9](#9-renouvellement--chaque-exécution-renouvelle-le-certificat-et-le-secret)). Avec `-KeepCredentials`, le script ne régénère ni n'envoie rien tant que le certificat du connecteur est cohérent et valable plus de 30 jours : c'est un contrôle de conformité. Si une mise à jour du connecteur était nécessaire (par exemple un produit manquant), la ligne Cloudiway est **BLOQUÉE** : le portail exige le certificat lors d'une mise à jour, relancez alors sans `-KeepCredentials`.

### 5.7 Sans console Windows : `pwsh` directement

Le lanceur est facultatif. Depuis PowerShell 7 :

```powershell
pwsh -NoProfile -File .\cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -WhatIf
```

Avec `-File`, plusieurs charges se passent en une seule valeur séparée par des virgules (`Mail,OneDrive`).

### 5.8 Une console PowerShell par tenant

**Ouvrez une NOUVELLE console PowerShell pour chaque tenant** (par exemple trois sources et une cible : quatre consoles). Une session Exchange Online ouverte pour un tenant reste ouverte dans la console : le script ne la déconnecte volontairement pas (la commande de déconnexion peut faire planter le processus avec un code d'appareil) et ne peut pas la réutiliser pour un autre tenant.

Depuis la version 2.7, si une session Exchange Online d'**un autre tenant** (ou d'un autre compte) est déjà ouverte dans la console, le script **s'arrête net à l'étape des prérequis, avec le code de sortie `1`, avant toute connexion, toute écriture et toute question**, et vous demande d'ouvrir une **NOUVELLE** console pour ce tenant puis de relancer la même commande. Une session du **même** tenant et du **même** compte est réutilisée sans nouvelle connexion. Un contexte Microsoft Graph hérité d'un autre tenant est journalisé, signalé et déconnecté proprement : il n'est jamais utilisé pour écrire.

L'option avancée `-AllowForeignSession` (usage consultant, désactivée par défaut) rétablit l'ancien comportement non bloquant (avertissement, étape EWS manuelle, code 2) ; ne l'utilisez pas en exploitation normale. Fermez la console quand vous avez terminé un tenant.

## 6. La charge SharePoint et l'identifiant de produit Cloudiway

Un connecteur Cloudiway déclare ses charges par des **identifiants de produits** (`rawProductList`). Connus de l'outil : **Mail = 5** et **Fichiers (OneDrive) = 6**. L'identifiant du produit Cloudiway pour **SharePoint (Sites)** est **inconnu** à ce jour : l'outil ne le devine pas (le faire correspondre au produit 6 donnerait l'illusion d'un support SharePoint qui n'existe pas sur le connecteur). Il en va de même des autres charges dont le produit est inconnu (elles sont de toute façon refusées dans cette version).

**Conséquence : arrêt rapide.** Si vous demandez SharePoint (ou `-Workloads All`, qui l'inclut) sans fournir l'identifiant :

- le script **s'arrête à l'étape 1, avec le code de sortie `1`, avant toute connexion et toute écriture** ;
- le message est « l'identifiant du produit Cloudiway pour SharePoint n'est pas connu : relancez avec -ProductIds ou un fichier ProductMap.json, ou retirez SharePoint de -Workloads » ;
- **rien n'est créé ni modifié** : ni application, ni rôle, ni compte de service dans le tenant, ni connecteur dans Cloudiway, y compris pour Mail et OneDrive demandés en même temps ; aucun certificat ni secret n'est généré.

(Cette règle ne s'applique pas avec `-SkipCloudiway`, qui configure le tenant seulement et ne déclare aucun connecteur.)

**Fournir l'identifiant** (il vous est communiqué par Cloudiway ; demandez-le à votre contact 3SR) :

- `-ProductIds 5,6,<identifiant>` : liste **complète** des produits à déclarer sur le connecteur ;
- ou un fichier JSON : `-ProductMapFile .\productmap.json`, qui ne surcharge que les charges citées (Mail = 5 et OneDrive = 6 gardent leur valeur). Si un fichier nommé **`productmap.json`** est placé à côté du script, il est utilisé automatiquement.

Format du fichier (une charge de travail, puis un identifiant ou une liste d'identifiants) :

```json
{ "SharePoint": 12 }
```

Le fichier `productmap.example.json` livré avec le script est un **exemple dont les valeurs sont FICTIVES** (`99999`, et une clé `_exemple_fictif_...` ignorée par l'outil) : **ne le copiez pas tel quel** sous le nom `productmap.json`, remplacez la valeur par l'identifiant réel fourni par Cloudiway. Le fichier est contrôlé **avant toute connexion** (fichier introuvable, JSON invalide ou valeur non numérique : arrêt avec un message, code 1).

L'identifiant réel du produit SharePoint et la migration de SharePoint n'ont **pas été validés en réel** (voir [section 17](#17-ce-qui-est-validé-en-réel-et-ce-qui-ne-lest-pas)).

## 7. Le compte de service

Cloudiway exige **ensemble**, pour la charge Mail, **en Source comme en Cible** : le **certificat** (et le mot de passe du PFX), le **secret client** et le **compte administrateur** du connecteur. Constat réel du 04/11/2026 : l'audit d'un utilisateur n'a démarré qu'après avoir renseigné le compte administrateur sur le connecteur **Source**. Le script crée donc un **compte utilisateur de service** (le compte administrateur du connecteur) **par défaut** dans ces cas :

| Mode | Charges qui créent un compte de service |
|---|---|
| Source | **Mail**, SharePoint |
| Cible | **Mail**, OneDrive, SharePoint |

**Ce compte est donc créé dès que Mail est demandé, y compris dans le tenant Source.** Il n'est **jamais supprimé par l'outil** : le DSI le supprime en fin de projet ([section 12](#12-retirer-les-objets-en-fin-de-projet)). Avec **OneDrive en Source seul**, aucun compte de service n'est créé.

**Ce qui est créé**

- Un **utilisateur** `svc-ciw-<mode>-p<projet>@<domaine .onmicrosoft.com>` (par exemple `svc-ciw-source-p12345@contoso.onmicrosoft.com`), nom affiché `Cloudiway Source P12345`, étiqueté (`employeeType`) pour être reconnu par l'outil.
- Un **mot de passe généré** (24 caractères), **jamais affiché, jamais écrit**, envoyé directement au connecteur Cloudiway (compte de migration). Le mot de passe est **sans expiration**.
- **Aucune licence** : le script n'en attribue jamais.
- Le rôle d'annuaire **SharePoint Administrator** attribué à ce compte.
- Sur l'application : les **flux de client public** sont autorisés (nécessaire à l'authentification du compte de service).
- L'option avancée `-WithoutServiceAccount` (usage avancé, désactivée par défaut) permet de s'en passer pour Mail malgré tout, avec l'avertissement « Cloudiway exige le compte administrateur : l'audit ne démarrera pas » ; elle n'écarte pas le compte pour SharePoint ni pour OneDrive en Cible.
- Le nom (`-ServiceAccountName`) peut être changé, mais sa partie locale doit **toujours** commencer par `svc-ciw-`, même avec `-AdoptExisting` : le script ne crée ni ne modifie jamais un compte au nom quelconque (par exemple un vrai utilisateur).

**Valeurs de sécurité par défaut, authentification multifacteur (MFA) et accès conditionnel.** Le compte de service se connecte **sans interaction** : il ne peut pas répondre à une demande de MFA.

- Si les **valeurs de sécurité par défaut** sont **actives** sur le tenant, la MFA est imposée à tous les comptes, **compte de service compris** : les jobs **OneDrive et SharePoint** de ce tenant **échoueront** à l'authentification du compte de service ; le **courrier** (Mail) n'est pas concerné par cet échec. Le script affiche un **avertissement visible** au moment du plan et en **première ligne de « À vérifier »** dans le rapport. Options : (1) désactiver les valeurs de sécurité par défaut au profit d'un **accès conditionnel ciblé qui exclut le compte de service**, ou (2) renoncer à OneDrive et SharePoint pour ce tenant. Le script ne modifie **jamais** ce paramètre.
- Si une stratégie d'accès conditionnel impose la MFA à ce compte, excluez-le. Le script ne devine pas la politique de votre tenant et ne la modifie jamais ; ne désactivez jamais la MFA du tenant lui-même.

**À la relance : le mot de passe est réinitialisé AVANT d'être envoyé.** Quand une exécution doit renvoyer un mot de passe au connecteur (renouvellement par défaut), le script le réinitialise **d'abord dans Entra** et ne l'envoie au connecteur **que si Entra l'a accepté**.

- **Si Entra refuse** (par exemple `HTTP 403`) : **le connecteur n'est pas modifié**. L'outil **ne touche ni au connecteur, ni à l'ancien certificat** : le connecteur garde son ancien certificat et son ancien mot de passe, aucun `PUT` n'est émis, l'ancien certificat n'est pas retiré de l'application. Le nouveau certificat déjà ajouté à l'application est conservé pour la relance suivante. Le code de sortie est `2`.
- **Relancer avec `-KeepCredentials` n'y change rien.** Réinitialisez le mot de passe du compte de service à la main (centre d'administration Microsoft Entra), ressaisissez-le dans le portail Cloudiway (compte de migration du connecteur), puis relancez.
- **Validé une fois en réel** : sur un tenant de test en mode Cible, deux relances successives ont réinitialisé le mot de passe du compte de service avec succès (code de sortie `0`, connecteur mis à jour). La garde ci-dessus reste en place si Entra refuse, sans plus. Le script ne crée plus le compte de service quand l'exécution s'arrête pour un identifiant de produit inconnu. Si un compte existant a été **adopté** (`-AdoptExisting`), l'outil ne réinitialise jamais son mot de passe : saisissez-le dans le connecteur, sur le portail Cloudiway.

## 8. Objets créés et noms codifiés

Les noms sont **codifiés** : c'est ce qui rend les objets réutilisables d'une exécution à l'autre (aucun doublon d'application, de compte ou de connecteur). Ne les renommez pas.

| Objet | Nom | Exemple |
|---|---|---|
| Inscription d'application et principal de service | `CLOUDIWAY-SOURCE-P<projet>` ou `CLOUDIWAY-TARGET-P<projet>` | `CLOUDIWAY-SOURCE-P12345` |
| Certificat (sujet) | `CN=Cloudiway-SOURCE-P<projet>` ou `CN=Cloudiway-TARGET-P<projet>` | `CN=Cloudiway-SOURCE-P12345` |
| Secret client (nom) | `Cloudiway-SOURCE-P<projet> <date>` ou `Cloudiway-TARGET-P<projet> <date>` | `Cloudiway-SOURCE-P12345 20270430` |
| Compte de service (si créé) | `svc-ciw-<mode>-p<projet>@<domaine .onmicrosoft.com>` | `svc-ciw-source-p12345@contoso.onmicrosoft.com` |
| Connecteur Cloudiway | `<préfixe du domaine .onmicrosoft.com>-source` ou `-target` | `contoso-source` |

Le préfixe du domaine est le début complet du domaine `.onmicrosoft.com` du tenant (jamais tronqué). Les options `-AppName`, `-ServiceAccountName` et `-ConnectorName` permettent de choisir d'autres noms. Le connecteur porte un **marqueur de suivi** : le nom de fichier de son certificat, de la forme `CIW1_<empreinte>_<AAAAMMJJ>.pfx`, qui permet au script de reconnaître son propre certificat et sa date d'expiration.

Le certificat et le secret client sont valables **180 jours** par défaut (`-ValidityDays`, de 45 à 730).

## 9. Renouvellement : chaque exécution renouvelle le certificat et le secret

**Chaque exécution (hors `-WhatIf`) renouvelle les identifiants** : le certificat et, avec la méthode par défaut `Both`, le secret client. Concrètement, à chaque lancement :

1. un **nouveau certificat** et un **nouveau secret client** sont générés en mémoire et ajoutés à l'application ;
2. si un compte de service existe, son **mot de passe est réinitialisé dans Entra avant l'écriture du connecteur** (voir [section 7](#7-le-compte-de-service) pour le cas du refus) ;
3. le **connecteur Cloudiway est mis à jour** avec le nouveau certificat, son mot de passe et le nouveau secret (le certificat est remplacé sur place) ;
4. le script **relit le connecteur** et ne considère l'écriture confirmée que si le nom de fichier du certificat relu est bien celui envoyé ;
5. seulement alors, les **anciens certificats et anciens secrets créés par l'outil** sont retirés de l'application (jamais avant : un connecteur ne perd jamais son authentification) ; pour les secrets, le script relit l'application et attend la propagation côté Entra. Les clés posées à la main sont conservées. L'identifiant (`keyId`) et l'empreinte de chaque clé retirée figurent dans le rapport et le journal.

**Résultat attendu après une relance : un seul certificat et un seul secret client** dans l'application, un **marqueur** de certificat qui change (nom de fichier `CIW1_...`), et **le même connecteur** (il n'est pas recréé). Constaté en réel en Source et en Cible (voir [section 17](#17-ce-qui-est-validé-en-réel-et-ce-qui-ne-lest-pas)).

**Le secret client est masqué par le portail Cloudiway** : il n'est pas possible de le relire pour vérifier qu'il a été pris en compte. La preuve est le **démarrage de l'audit** du connecteur dans le portail : **re-soumettez l'audit après chaque mise à jour du connecteur**, et vérifiez que la limite de licences du projet n'est pas à 0 (« Project Settings »).

**Attention : ne relancez pas le script pendant que des jobs de migration sont actifs.** Un connecteur existant est mis à jour à chaque exécution ; des jobs en cours peuvent échouer pendant le remplacement du certificat, du secret (et du mot de passe du compte de service). Attendez la fin des jobs (ou suspendez-les dans le portail Cloudiway). Pour un simple contrôle de conformité, utilisez `-KeepCredentials`.

Si l'écriture du connecteur échoue ou ne peut pas être confirmée, **aucun ancien certificat ni secret n'est retiré** et le code de sortie est 2 : relancez la même commande, le script reprend là où il s'est arrêté.

## 10. La liste EWS d'Exchange Online

Pour la charge **Mail**, Cloudiway utilise EWS. Si votre organisation restreint EWS à une liste d'applications (`EwsAllowedAppIDs`), l'application Cloudiway doit y figurer. Le script :

1. se connecte à Exchange Online avec le compte `-Admin365` ;
2. **lit** la configuration (`Get-OrganizationConfig`), y compris en simulation ;
3. **ajoute** l'AppID de l'application à `EwsAllowedAppIDs` : ajout seul, **jamais de remplacement ni de retrait** des entrées existantes.

**Avertissement : une liste vide devient restrictive.** Si `EwsAllowedAppIDs` est **vide**, y inscrire une première application la rend **restrictive pour toutes les autres applications EWS du tenant** (outils de sauvegarde, applications mobiles tierces, etc.) qui n'y figurent pas : elles seraient **bloquées**. Le script demande donc une **confirmation explicite séparée** (réponse par défaut : non). Sans confirmation, rien n'est écrit et la ligne passe en « À vérifier » avec les commandes exactes ; avec `-Yes`, rien n'est écrit non plus, sauf si vous ajoutez `-AllowEwsListCreation`. Si la liste contient déjà des entrées, l'AppID y est simplement ajouté. **Par défaut, une liste vide n'est donc jamais créée** : l'étape EWS est ignorée (« À vérifier », code de sortie 2) sauf confirmation explicite ou `-AllowEwsListCreation`.

Si `EwsEnabled` vaut `False` (EWS désactivé pour l'organisation), **rien n'est écrit** : c'est une décision du tenant, signalée dans « À vérifier ».

Tout échec Exchange (module absent, connexion, lecture, écriture) est **non bloquant** : le reste est configuré, l'étape devient un « À faire » manuel avec les commandes exactes, et le code de sortie est 2. Les commandes manuelles se terminent par un conseil : fermez la console PowerShell après usage.

Compter 5 à 10 minutes de propagation côté Microsoft après l'ajout.

## 11. Lire le résultat et fichiers produits

À l'écran, puis dans le rapport :

- **Plan** : action prévue pour chaque élément.
- **Application** : résultat de chaque action (`APPLIQUÉ`, `ÉCHEC`, `IGNORÉ`).
- **Vérification** : relecture de chaque objet (`Conforme`, `À vérifier`, `NON CONFORME`).
- **À faire** : actions réelles que le script n'a pas pu réaliser (par exemple le consentement administrateur manquant, avec le lien à ouvrir, ou l'étape Exchange à faire à la main, avec les commandes exactes). Le groupe n'apparaît que s'il y a quelque chose à faire.
- **À vérifier** : informations et contrôles que le script ne peut pas automatiser (par exemple l'avertissement sur les valeurs de sécurité par défaut, en première ligne, la date d'expiration du certificat, ou une liste EWS vide).

Le script ne se déclare « conforme » que si **tout** a été relu et confirmé. Voir [section 15](#15-codes-de-sortie) pour les codes de sortie.

Le script écrit dans un dossier `connecteur-resultats` à côté du script (ou, si le dossier du script est synchronisé ou partagé, dans `%LOCALAPPDATA%\CloudiwayConnector`, ce qu'il signale ; `-OutDir` permet de choisir). Chaque exécution crée un sous-dossier `<préfixe>-<Source|Target>-<AAAAMMJJ-HHMM>` contenant **uniquement** :

| Fichier | Contenu |
|---|---|
| `run.log` | Journal de l'exécution : prérequis, plan, résultat de chaque étape, vérifications. **Aucun secret.** Il contient le nom du tenant, son domaine, les noms d'objets, le compte administrateur et le compte de migration. |
| `Rapport-<préfixe>-<Source\|Target>.md` | Rapport lisible : paramètres, plan, résultat, vérification, « À faire » et « À vérifier ». **Aucun secret, aucun contenu de certificat.** Il contient des identifiants du tenant (GUID de l'application et du principal de service, empreinte du certificat, date d'expiration). |
| `decouverte-<id>.json` | Seulement avec `-Discover -ConnectorId <id>` : configuration du connecteur, secrets masqués. |

**Aucun fichier de certificat, de mot de passe ou d'état n'est écrit.** Le rapport contenant des identifiants de tenant, évitez un dossier synchronisé ou partagé.

## 12. Retirer les objets en fin de projet

Le script ne supprime rien (hors anciens certificats de l'outil). **À la fin du projet de migration, retirez vous-même les objets suivants**, car l'application dispose de permissions étendues sur les boîtes aux lettres, les fichiers et les sites, et le compte de service dispose d'un rôle d'administration.

**1. Le connecteur Cloudiway.** Dans le portail Cloudiway, supprimez le connecteur `<préfixe>-source` ou `<préfixe>-target` (ou demandez à votre contact 3SR de le faire).

**2. L'entrée dans la liste EWS (Exchange Online)** (charge Mail). Retirez l'AppID de l'application de `EwsAllowedAppIDs` (l'AppID figure dans le rapport, section « Valeurs à connaître », et dans Entra) :

```powershell
Connect-ExchangeOnline -UserPrincipalName 'admin365@contoso.com'
Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs
$ids = @((Get-OrganizationConfig).EwsAllowedAppIDs) | Where-Object { $_ -and $_ -ne '<AppID de l''application>' }
Set-OrganizationConfig -EwsAllowedAppIDs ($ids -join ',')
```

Si l'AppID était la seule entrée, la liste se retrouve vide : consultez la documentation Microsoft de `Set-OrganizationConfig` pour la procédure à suivre dans ce cas. Ce cas n'a pas été exercé par l'outil. Si vous aviez confirmé la création de la liste (liste initialement vide), pensez que les autres applications EWS retrouvent leur accès une fois la liste vidée. Fermez ensuite la console (ne la réutilisez pas pour un autre tenant).

**3. Le compte de service** (créé dès que Mail est demandé, en Source comme en Cible, ainsi que pour OneDrive en Cible et SharePoint ; l'outil ne le supprime jamais). Dans le centre d'administration Microsoft Entra :

1. **Rôles et administrateurs** > **SharePoint Administrator** > **Attributions** : **retirez le compte de service** `svc-ciw-<mode>-p<projet>` du rôle ;
2. **Utilisateurs** : **supprimez le compte de service** `svc-ciw-<mode>-p<projet>`.

Retirez d'abord le rôle, puis le compte : le compte porte un mot de passe sans expiration et un rôle d'administration, il ne doit pas survivre au projet.

**4. L'attribution des rôles Exchange** (charge Mail). Dans le centre d'administration Microsoft Entra : **Rôles et administrateurs** > **Exchange Administrator** > **Attributions** : retirez l'application `CLOUDIWAY-<SOURCE|TARGET>-P<projet>`. Faites de même pour **Exchange Recipient Administrator**.

**5. L'application.** Dans Entra : **Inscriptions d'applications** > `CLOUDIWAY-<SOURCE|TARGET>-P<projet>` > **Supprimer**. Vérifiez ensuite que l'application d'entreprise correspondante (**Applications d'entreprise**) a disparu ; supprimez-la sinon. Cette suppression retire les permissions, le consentement et les certificats de l'application.

**6. Le consentement de l'application Microsoft « Microsoft Graph Command Line Tools »** (voir [section 5.3](#53-appliquer)) : Entra > Applications d'entreprise > Microsoft Graph Command Line Tools > Autorisations : révoquez les autorisations accordées pour ce projet.

**7. Les résultats locaux.** Supprimez le dossier `connecteur-resultats` (il contient des identifiants de tenant).

Répétez la procédure pour **chaque tenant** traité (sources et cible).

## 13. Vérifier le script avant de l'exécuter

Le script est livré en **clair** : lisez-le avant de l'exécuter, notamment `lib\entra.ps1` (écritures Entra), `lib\exchange.ps1` (écritures Exchange) et `lib\cloudiway.ps1` (écritures Cloudiway). Il ne contient aucun appel `DELETE`.

**Empreinte SHA-256.** Votre contact 3SR vous communique les empreintes SHA-256 de la version qui vous est destinée (notes de version). Calculez celles de vos fichiers et comparez :

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\cloudiway-connector.ps1, .\lib\entra.ps1, .\lib\exchange.ps1, .\lib\cloudiway.ps1 | Format-Table Hash, Path -AutoSize
```

Les fichiers sont publiés en UTF-8 avec BOM et fins de ligne CRLF : une conversion automatique de fins de ligne par votre outil de téléchargement (Git, archive) change l'empreinte.

**Tests hors ligne.** `tests\run-tests.ps1` exécute le script et ses bibliothèques contre un faux tenant et un faux portail Cloudiway en mémoire (aucune connexion, aucun réseau, ni module Microsoft Graph ni ExchangeOnlineManagement nécessaires) :

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

Compter une dizaine de minutes. Le banc vérifie notamment qu'aucun secret n'est écrit, qu'aucune requête `DELETE` n'est émise, l'ordre des opérations, la vérification du certificat par nom de fichier avant tout retrait, le comportement du compte de service (création, garde au refus de réinitialisation du mot de passe), la liste EWS (ajout seul, confirmation sur liste vide), les modes Source et Cible et l'arrêt rapide pour SharePoint sans identifiant de produit.

## 14. Dépannage

| Symptôme | Cause probable et action |
|---|---|
| Erreur `#requires` au lancement | Le script est lancé depuis Windows PowerShell 5.1. Utilisez `cloudiway-connector.cmd` ou ouvrez `pwsh` (PowerShell 7.2 minimum). |
| `pwsh` introuvable ou trop ancien | Le lanceur propose l'installation avec `winget` après confirmation ; sinon `winget install --id Microsoft.PowerShell -e`. |
| Module manquant | `Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser` (et `ExchangeOnlineManagement` pour Mail), ou `-InstallMissingModules`. |
| « Charge de travail non disponible dans cette version » | Teams, Archive, GalSync, Intune, FreeBusy, Signature et MailRouting sont refusées. Disponibles : Mail, OneDrive, SharePoint. Aucune connexion n'a été tentée. |
| « L'identifiant du produit Cloudiway pour SharePoint n'est pas connu » (code 1, avant toute connexion) | Voir [section 6](#6-la-charge-sharepoint-et-lidentifiant-de-produit-cloudiway) : fournissez `-ProductIds` ou `productmap.json`, ou retirez SharePoint de `-Workloads`. Rien n'a été créé. |
| L'audit ne démarre pas dans le portail Cloudiway | Le secret client est masqué par le portail : la preuve de sa prise en compte est le démarrage de l'audit. Re-soumettez l'audit après chaque mise à jour du connecteur. Vérifiez que `-AuthMethod` est `Both` (défaut) : `Certificate` ou `Secret` seuls sont non recommandés. |
| « Table de produits illisible » | Le fichier `productmap.json` ou `-ProductMapFile` est introuvable, n'est pas du JSON valide, ou contient une valeur non numérique. Arrêt avant toute connexion (code 1). |
| « Connexion refusée : le tenant ou le compte ne correspond pas » | La fenêtre de connexion a repris un autre compte. Relancez en choisissant exactement le compte `-Admin365`, ou avec `-UseDeviceCode`. Pour un compte **invité** (identifiant contenant `#EXT#`), `-Admin365` doit être l'identifiant exact tel que le tenant l'affiche, et l'invité doit être Administrateur général **dans ce tenant**. |
| Arrêt à l'étape des prérequis (code 1) : session Exchange Online d'un autre tenant | Une session Exchange Online d'un autre tenant (ou d'un autre compte) est ouverte dans la console. Fermez la console, ouvrez-en une **nouvelle** pour ce tenant, relancez la même commande (voir [section 5.8](#58-une-console-powershell-par-tenant)). |
| Avertissement « Valeurs de sécurité par défaut ACTIVES » | La MFA est imposée à tous les comptes, compte de service compris : les jobs OneDrive et SharePoint de ce tenant échoueront ; le courrier non. Voir [section 7](#7-le-compte-de-service). Le script ne modifie jamais ce paramètre. |
| « Le mot de passe du compte de service n'a pas pu être changé dans Entra » | Entra refuse la réinitialisation du mot de passe (par exemple HTTP 403). Le connecteur n'est pas modifié et l'ancien certificat n'est pas retiré ; `-KeepCredentials` n'y change rien. Réinitialisez le mot de passe à la main, ressaisissez-le dans le portail Cloudiway, puis relancez (voir [section 7](#7-le-compte-de-service)). |
| `AADSTS65001` | Le consentement n'a pas été donné pour « Microsoft Graph Command Line Tools » : reconnectez-vous avec un Administrateur général et acceptez la fenêtre de consentement. |
| `AADSTS90094` | Le consentement administrateur est requis et le compte n'est pas Administrateur général (activez le rôle si vous passez par PIM). |
| `AADSTS53003` | Accès bloqué par l'accès conditionnel (poste, localisation, application) : utilisez un poste ou un réseau autorisé, ou demandez une exception. |
| `AADSTS50076` | Authentification multifacteur exigée : terminez la validation dans la fenêtre Microsoft puis relancez. |
| « Le compte n'est pas Administrateur général » | Les actions qui l'exigent sont **BLOQUÉES** dans le plan et rien n'est écrit (code 1). Utilisez un compte Administrateur général. |
| Accès Cloudiway impossible | Vérifiez l'identifiant, le mot de passe (initialisé via l'invitation), que le compte est invité avec le rôle Contributor, et `-ProjectId`. Si la double authentification est activée sur le compte Cloudiway, la connexion ne fonctionne pas (limite constatée en réel, voir [section 17](#17-ce-qui-est-validé-en-réel-et-ce-qui-ne-lest-pas)) : contactez votre contact 3SR. |
| Plusieurs projets visibles | Choisissez dans la liste, ou passez `-ProjectId 12345`. |
| Ligne Cloudiway `BLOQUÉ` : collision de noms | Un connecteur du même nom désigne un autre tenant ou une autre application. Choisissez un autre `-ConnectorName`, ou `-AdoptExisting` si vous êtes sûr. |
| Ligne `BLOQUÉ` : objet existant sans étiquette | Application, compte de service ou connecteur créé à la main au nom prévu. `-AdoptExisting` le reprend (le certificat, l'identifiant d'application et le mot de passe du compte de migration d'un connecteur adopté sont **remplacés** ; confirmation supplémentaire demandée). |
| Étape Exchange en « À faire » | Module absent, connexion ou écriture en échec : exécutez les commandes affichées dans « À faire », ou relancez la même commande. Code de sortie 2. |
| Poste derrière un proxy d'entreprise | Le script utilise les identifiants Windows de l'utilisateur pour le proxy ; vérifiez les variables `HTTPS_PROXY` / `HTTP_PROXY` si le proxy impose un réglage particulier. Non validé en réel sur un proxy authentifié (voir [section 17](#17-ce-qui-est-validé-en-réel-et-ce-qui-ne-lest-pas)). |
| Deux lanceurs en même temps | Lancez **un seul** lanceur à la fois : deux exécutions simultanées sur le même projet peuvent produire des doublons (applications ou connecteurs). Vérifiez dans Entra et dans le portail Cloudiway. |
| « Dossier de sortie à risque » | Le dossier est synchronisé ou partagé : utilisez `-OutDir` vers un dossier local non synchronisé. |

## 15. Codes de sortie

| Code | Signification |
|---|---|
| `0` | Conforme : tout est appliqué et vérifié (ou simulation réussie). |
| `1` | Arrêt **avant toute écriture** : prérequis manquant, accès impossible, droits insuffisants, refus, annulation, ou lignes bloquées sans rien d'applicable. |
| `2` | Appliqué **avec des éléments en échec, ignorés, bloqués ou non conformes** (étape Exchange manuelle comprise, ligne Cloudiway bloquée comprise). Relancez la même commande après avoir lu le rapport. |

Le lanceur `cloudiway-connector.cmd` transmet ces codes. Il ajoute ses propres codes : `10` (PowerShell 7.2 absent et non installé), `11` (installé mais introuvable depuis cette fenêtre : fermez-la et relancez), `12` (script principal introuvable), `13` (lancement impossible).

## 16. Référence des options

| Option | Rôle |
|---|---|
| `-Mode` | `Source` (tenant à migrer) ou `Target` (tenant de destination). Demandé si absent. |
| `-Tenant` | Domaine `xxxx.onmicrosoft.com` (ou domaine vérifié) ou GUID du tenant. Demandé si absent. |
| `-Admin365` (alias `-User`) | Compte Administrateur général du tenant. Le compte connecté doit être exactement celui-là. Demandé si absent. |
| `-Cloudiway` | Votre identifiant sur le portail Cloudiway. Le mot de passe est demandé masqué. Demandé si absent. |
| `-CloudiwayPat` | Jeton d'accès personnel Cloudiway (`SecureString`) à la place du mot de passe. **Non validé** : ce contournement existe dans l'outil mais n'a jamais été validé ; ne pas s'en servir comme solution à la 2FA. |
| `-ProjectId` | Numéro du projet Cloudiway. Détecté automatiquement si possible. |
| `-Workloads` | `Mail`, `OneDrive`, `SharePoint`, ou `All` (= les trois). Aucune valeur par défaut. Les autres charges sont refusées. SharePoint (donc `All`) sans identifiant de produit : arrêt rapide, code 1. |
| `-WhatIf` | Simulation : plan seul, rien n'est écrit. À faire en premier. |
| `-Discover` / `-ConnectorId` | Liste les connecteurs du projet (lecture seule, sans connexion au tenant) ; détail masqué d'un connecteur. |
| `-UseDeviceCode` | Connexion Graph (et Exchange) par code d'appareil. |
| `-KeepCredentials` | Contrôle de conformité : ne renouvelle rien tant que le certificat est cohérent et valable plus de 30 jours. |
| `-RotateCredentials` (alias `-RotateCertificate`) | Sans effet (le renouvellement est le comportement par défaut). Incompatible avec `-KeepCredentials`. |
| `-AuthMethod` | `Both` (**défaut** : certificat ET secret client, que Cloudiway exige), `Certificate` ou `Secret`. Ces deux dernières sont possibles mais **non recommandées** (l'audit peut ne pas démarrer). |
| `-ValidityDays` | Validité des identifiants générés, de 45 à 730 jours (défaut 180). |
| `-AdoptExisting` | Autorise la reprise d'une application, d'un compte de service ou d'un connecteur existant sans l'étiquette de l'outil (remplace le certificat, l'identifiant d'application et le mot de passe du compte de migration du connecteur). |
| `-AppName`, `-ConnectorName` | Remplacent les noms codifiés. |
| `-WithoutServiceAccount` | Usage avancé : ne crée pas le compte de service pour Mail, malgré l'exigence de Cloudiway (l'audit ne démarrera pas). Voir [section 7](#7-le-compte-de-service). |
| `-AllowForeignSession` | Usage consultant (désactivé par défaut) : autorise une session Exchange Online d'un autre tenant dans la console au lieu d'arrêter le script. Voir [section 5.8](#58-une-console-powershell-par-tenant). |
| `-GraphAccessToken`, `-ExchangeAccessToken`, `-CloudiwayPassword` | Usage avancé (automatisation), inutile en utilisation normale ; voir `Get-Help .\cloudiway-connector.ps1 -Full`. |
| `-ServiceAccountName` | Remplace la partie locale du compte de service (doit commencer par `svc-ciw-`). Sans effet quand aucun compte de service n'est créé. |
| `-AllowEwsListCreation` | Autorise sans question la création de la liste EWS quand elle est vide (la rend restrictive pour les autres applications EWS). |
| `-SkipCloudiway` | Configure le tenant seulement, sans appel à Cloudiway (`-ProjectId` obligatoire ; aucun certificat n'est généré, faute de moyen de le transmettre). |
| `-ProductIds` | Liste **complète** des identifiants de produits Cloudiway à déclarer (Mail = 5, Fichiers = 6 ; SharePoint : à fournir, sinon arrêt rapide). |
| `-ProductMapFile` | Fichier JSON de correspondance charges / produits (ne surcharge que les charges citées). Par défaut, un fichier `productmap.json` à côté du script est utilisé s'il existe. |
| `-Region` | Région serveur Cloudiway (défaut 1). |
| `-CertificateTransport` | `Base64` (défaut) ou `Path` (fichier temporaire protégé, supprimé aussitôt). Seul `Base64` est recommandé. |
| `-OutDir` | Dossier de base du rapport et du journal. |
| `-InstallMissingModules` | Installe sans question les modules PowerShell manquants (profil utilisateur, sans droits administrateur). |
| `-Yes` | Saute la confirmation du plan (usage scripté). Jamais activé implicitement. |

## 17. Ce qui est validé en réel, et ce qui ne l'est pas

État au 04/11/2026, pour la version 2.7, **après validation en réel**. Cette section est volontairement franche : le banc de test hors ligne couvre ces cas avec un faux tenant et un faux portail, mais un faux n'est pas la réalité.

**Validé en réel**

- **Modes Source et Cible**, avec les charges **Mail** et **OneDrive** : création du connecteur avec certificat, secret client **et** compte administrateur (`-AuthMethod Both`, compte de service créé par défaut pour Mail), puis **audit réussi** et **migration de test lancée et en cours de traitement** (non terminée à la date de cet état).
- **La relance** : après une relance, **un seul certificat et un seul secret client** restent dans l'application, le marqueur du certificat change, et c'est **le même connecteur** (Source et Cible).
- **Vérification du certificat par nom de fichier** (relecture du connecteur après écriture).
- **Retrait des anciens certificats** par le repli `PATCH` et des anciens secrets par `removePassword`.
- **Code d'appareil** (Microsoft Graph et Exchange Online).
- **Écriture EWS** sur une liste vide (création, avec confirmation). Par défaut, une liste vide **n'est jamais créée** sans confirmation ou `-AllowEwsListCreation` : l'étape est ignorée (code de sortie 2).
- **Compte de service et rôle SharePoint Administrator créés** au premier passage, puis **mot de passe du compte de service renouvelé à la relance** : validé **une fois** sur un tenant de test en mode Cible (deux relances successives, code de sortie `0`, connecteur mis à jour).
- **Secret client accepté par le portail**, mais **non vérifiable à la lecture** (le portail le masque).

**Non validé en réel, ou échec constaté**

- **Migration de bout en bout** : la migration de test est lancée et en cours de traitement ; son résultat final n'est pas encore connu. Que le connecteur soit créé et l'audit réussi ne prouve pas que tous les jobs de migration aboutiront.
- **SharePoint** : identifiant de produit **inconnu** (voir [section 6](#6-la-charge-sharepoint-et-lidentifiant-de-produit-cloudiway)), charge **non validée** en réel.
- **Teams** : charge non disponible dans cette version, **non validée**.
- **Retrait des anciens certificats par `POST removeKey`** : Microsoft répond `403` en conditions réelles ; l'outil utilise le repli `PATCH` (validé).
- **Réinitialisation de ce mot de passe refusée par Entra** (par exemple `HTTP 403`) : cas géré par la garde (le connecteur n'est pas modifié, voir [section 7](#7-le-compte-de-service)) ; la réinitialisation manuelle est alors nécessaire.
- **Ajout de l'AppID à une liste EWS qui contient déjà d'autres applications** : jamais exercé en réel.
- **Compte invité (B2B)** comme administrateur du tenant.
- **Poste derrière un proxy authentifié.**
- **Windows PowerShell 5.1 sur un poste vierge** (lanceur `.cmd`).
- **Rôle Lecteur général** (Global Reader) : le comportement avec ce seul rôle n'a pas été éprouvé.
- **Options `-AuthMethod Certificate` ou `Secret` seuls, `-CertificateTransport Path`, `-Region` différent de 1.**

### Limite connue constatée

- **Double authentification (2FA) sur le compte Cloudiway : NON SUPPORTÉE.** La connexion au portail depuis le script **ne fonctionne pas** avec la 2FA (constaté en réel le 03/11/2026, chez un client). Prérequis explicite : le compte Cloudiway utilisé pour lancer le script ne doit pas avoir la 2FA activée ; si elle l'est, contactez votre contact 3SR. Un contournement par jeton d'accès personnel (`-CloudiwayPat`) existe dans l'outil, mais il n'a **jamais été validé** : ne le considérez pas comme une solution.

## 18. Limites de cette version

- **Charges Mail, OneDrive et SharePoint seulement.** Les autres charges de travail sont refusées avec un message clair.
- **SharePoint : arrêt rapide (code 1) tant que l'identifiant du produit n'est pas fourni**, avant toute connexion ; `-Workloads All` aussi (voir [section 6](#6-la-charge-sharepoint-et-lidentifiant-de-produit-cloudiway)).
- **Après chaque exécution du script**, re-soumettez l'audit du connecteur dans le portail Cloudiway (le secret client est masqué par le portail : la preuve est le démarrage de l'audit) et vérifiez que la limite de licences du projet n'est pas à 0 (« Project Settings »).
- Chaque exécution renouvelle le certificat et le secret et met à jour le connecteur existant : ne pas relancer pendant des jobs de migration actifs (voir [section 9](#9-renouvellement--chaque-exécution-renouvelle-le-certificat-et-le-secret)).
- Si Entra refuse la réinitialisation du mot de passe d'un compte de service existant (par exemple `HTTP 403`), la garde bloque l'écriture du connecteur : réinitialisation manuelle (voir [section 7](#7-le-compte-de-service)).
- **Une console PowerShell par tenant** : une session Exchange Online d'un autre tenant arrête le script (code 1) tant que `-AllowForeignSession` n'est pas utilisé (voir [section 5.8](#58-une-console-powershell-par-tenant)).
- Si les valeurs de sécurité par défaut sont actives, les jobs OneDrive et SharePoint échouent à l'authentification du compte de service (voir [section 7](#7-le-compte-de-service)).
- Le script ne retire pas ses objets en fin de projet : la procédure est manuelle (voir [section 12](#12-retirer-les-objets-en-fin-de-projet)).
- Le compte Cloudiway ne doit pas avoir la double authentification activée (voir [section 17](#17-ce-qui-est-validé-en-réel-et-ce-qui-ne-lest-pas)).
