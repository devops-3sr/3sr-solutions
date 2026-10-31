# SSL MANAGED SOLUTION : Préparation de votre environnement Azure

> English version: [3sr-ssl-onboarding-guide-en.md](3sr-ssl-onboarding-guide-en.md)

## 1. Ce que fait le script

`3sr-ssl-onboarding.ps1` prépare, **dans votre abonnement Azure**, les trois ressources nécessaires au service :

| Ressource | À quoi elle sert |
|---|---|
| Groupe de ressources | Regroupe les deux ressources ci-dessous |
| Compte de stockage + conteneur `ssl` | Contient la liste de vos certificats, un fichier JSON que vous maîtrisez |
| Coffre de clés (Key Vault) | Reçoit les certificats émis |

Puis il accorde à 3SR **deux accès**, et rien d'autre :

| Accès | Ce qu'il permet | Portée |
|---|---|---|
| `Key Vault Certificates Officer` | Créer et renouveler les certificats | Le coffre uniquement |
| `Storage Blob Data Reader` | Lire votre liste, sans pouvoir la modifier | Le conteneur `ssl` uniquement |

Ces deux rôles sont visibles dans le portail Azure et révocables par vos soins à tout moment. Aucun mot de passe, aucune clé, aucun jeton n'est créé ni échangé. Vos clés privées restent dans votre coffre.

Le script vous attribue enfin **vos propres accès**, plus larges que ceux de 3SR puisqu'il s'agit de vos ressources :

| Votre accès | Portée | Pourquoi |
|---|---|---|
| `Storage Blob Data Contributor` | Le conteneur `ssl` | Maintenir votre liste de certificats |
| `Key Vault Certificates Officer` | Le coffre | Gérer vos certificats |
| `Key Vault Secrets User` | Le coffre | **Exporter vos certificats au format PFX** |

Le troisième mérite une explication. `Key Vault Certificates Officer` ne donne pas accès au secret associé à un certificat : c'est exactement pour cette raison qu'il a été retenu pour 3SR, qui ne peut donc pas extraire vos clés privées. Mais le portail Azure a besoin de lire ce secret pour construire un PFX. Sans `Key Vault Secrets User`, le bouton **Download in PFX/PEM format** échoue avec un message trompeur, `Failed to dynamically fetch target download uri`.

En mode RBAC, être Propriétaire de l'abonnement ne donne pas accès au contenu du coffre ni du stockage : ce sont deux plans distincts, d'où ces attributions explicites.

**Durée : environ 5 minutes.** Le script ne supprime jamais rien, et peut être relancé sans risque.

---

## 2. Prérequis

- **Azure CLI**, à installer depuis <https://aka.ms/installazurecli>
- **PowerShell** 5.1 (intégré à Windows) ou PowerShell 7
- Être **Propriétaire (Owner)** de l'abonnement cible. Le rôle `Contributor` ne suffit pas, car il ne permet pas d'attribuer des rôles.
- L'application 3SR doit être autorisée dans votre annuaire Entra. Si ce n'est pas fait, le script s'arrête dès le début et affiche le lien exact à faire ouvrir par un administrateur général.

---

## 3. Exécution

```powershell
az login
.\3sr-ssl-onboarding.ps1
```

Si Windows bloque le script :

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### Étape 1. Choisir le locataire et l'abonnement

Le script liste vos locataires, puis les abonnements de celui que vous retenez. Au-delà de 15 entrées, il propose un filtre. Rien n'est créé sans votre confirmation.

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

### Étape 2. Choisir les noms

Trois noms vous sont proposés. **Entrée** accepte celui entre crochets. Chaque nom est vérifié deux fois : son format, puis sa disponibilité réelle dans Azure.

| Ressource | Règles |
|---|---|
| Groupe de ressources | 90 caractères maximum ; lettres, chiffres, `-`, `_`, `.` |
| Compte de stockage | 3 à 24 caractères, **minuscules et chiffres uniquement**, unique dans tout Azure |
| Coffre de clés | 3 à 24 caractères, commence par une lettre, lettres, chiffres et tirets, unique dans tout Azure |

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

Le script demande ensuite le **fichier JSON transmis par 3SR**, la liste de vos certificats. Il en vérifie le contenu avant de le déposer, et refuse un fichier mal formé en indiquant l'entrée fautive.

> **Ne renommez pas ce fichier.** Son nom, de la forme `<votre-code>-ssl.json`, est celui que l'automatisation 3SR ira lire. Le script le dépose tel quel dans le conteneur `ssl`.

Vous pouvez laisser l'étape vide et déposer le fichier plus tard, depuis le portail Azure : conteneur `ssl` du compte de stockage créé, en conservant le nom d'origine.

### Étape 3. Valider

Tout ce qui va être créé et tous les accès accordés sont récapitulés. **Rien n'est créé tant que vous n'avez pas tapé `OUI`.**

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

### Étape 4. Création et contrôles

Comptez une à deux minutes. Le script relit ensuite l'état réel de vos ressources dans Azure et affiche une vingtaine de contrôles.

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

### Étape 5. Renvoyer le rapport

Un fichier `3sr-ssl-onboarding-<date>.txt` est déposé dans le dossier courant.

> **Transmettez-le à votre contact 3SR.** Sans lui, 3SR ne peut pas activer l'automatisation.

Il contient les identifiants de vos ressources (locataire, abonnement, noms créés) et le résultat des contrôles. Il ne contient aucun secret.

---

## 4. Arguments

| Argument | Effet |
|---|---|
| *(aucun)* | Exécution normale |
| `-Simulation` | Déroule tout le parcours **sans rien créer ni modifier**, et affiche les commandes qui seraient lancées. À utiliser pour un premier essai. |
| `-RapportEmail <adresse>` | Adresse affichée comme destinataire du rapport en fin d'exécution. Facultatif : sans valeur, le script indique « votre contact 3SR ». |
| `-AutoriserStorageExistant` | Autorise la réutilisation d'un compte de stockage qui n'a pas été créé par ce script. Ses propriétés de sécurité seront modifiées. **À n'utiliser que sur indication de 3SR.** |
| `-AutoriserMigrationRbac` | Autorise la bascule d'un coffre existant des « stratégies d'accès » vers RBAC. Cela invalide les stratégies d'accès en place. **À n'utiliser que sur indication de 3SR.** |

Codes de retour :

| Code | Signification |
|---|---|
| `0` | Succès |
| `2` | Succès, avec des avertissements dans le rapport |
| `3` | Un contrôle de sécurité critique a échoué |
| `1` | Erreur bloquante |

---

## 5. En cas de problème

| Message | Que faire |
|---|---|
| `Azure CLI (az) est introuvable` | Installer Azure CLI, puis rouvrir le terminal |
| `Aucune souscription accessible` | Lancer `az login` |
| `L'application 3SR n'est pas enregistrée dans votre locataire` | Faire ouvrir par un administrateur général le lien affiché par le script |
| `« nom » est déjà utilisé ailleurs dans Azure` | Les noms de stockage et de coffre sont uniques mondialement, en choisir un autre |
| `existe mais n'a pas été créé par ce script` | Choisir un nom dédié au service SSL |
| `Impossible d'attribuer le rôle` | Faire exécuter le script par un Propriétaire de l'abonnement |
| `Ce fichier ne peut pas être déposé` | Le message indique l'entrée fautive du JSON. Corriger le fichier, ou le déposer plus tard. |

Le script est relançable : ce qui existe est réutilisé, un rôle déjà attribué est simplement confirmé. En cas d'échec partiel, transmettez le rapport tel quel à 3SR.

---

## 6. Mettre fin au service

Le script `3sr-ssl-offboarding.ps1` retire les accès accordés à 3SR. Il vous les présente, vous choisissez ceux à révoquer, et **il ne supprime aucune ressource**. Vos certificats restent en votre possession et valides jusqu'à leur expiration. Vous pouvez aussi retirer ces rôles directement depuis le portail Azure.

---

*Une question : contactez votre interlocuteur 3SR.*
