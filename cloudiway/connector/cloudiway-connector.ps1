#Requires -Version 7.2

<#
.SYNOPSIS
    Configure un tenant Microsoft 365 SOURCE pour un connecteur Cloudiway (Mail et OneDrive), puis cree ou met a jour le connecteur dans votre projet Cloudiway.

.DESCRIPTION
    Outil a lancer VOUS-MEME (DSI du client) dans une console pwsh (PowerShell 7.2 minimum), avec votre compte Administrateur general Microsoft 365 et
    votre compte Cloudiway (invitation recue par mail, role Contributor sur le projet). Sans parametre, l'outil pose des questions.
    Cette version ne couvre que le mode Source (tenant a migrer) et les charges Mail et OneDrive. Le mode Cible arrivera dans une version ulterieure.

    CET OUTIL MODIFIE LE TENANT ET VOTRE PROJET CLOUDIWAY. Lancer d'abord avec -WhatIf : le plan est affiche, rien n'est ecrit.

    Ce que l'outil fait, dans l'ordre :
      1. Controle le poste (PowerShell 7, module Microsoft Graph, reseau, dossier de resultats, domaine du tenant).
      2. Se connecte au portail Cloudiway avec VOTRE compte (mot de passe saisi masque), detecte le projet et lit le connecteur existant.
      3. Se connecte au tenant (controle strict du tenant et du compte -Admin365) et verifie vos droits.
      4. Lit l'etat actuel du tenant et affiche un PLAN (CREER / METTRE A JOUR / OK / BLOQUE / IGNORE, avec la raison).
      5. Demande confirmation, puis applique : application Entra, principal de service, permissions (moindre privilege, calculees d'apres les
         charges de travail), consentement administrateur, roles Exchange Administrator et Exchange Recipient Administrator de l'application,
         Exchange Online (charge Mail : AppID inscrit dans EwsAllowedAppIDs), certificat, connecteur.
      6. Relit chaque element pour verifier la conformite.
      7. Ecrit un rapport (Rapport-<TenantShort>-<Mode>.md) et un journal (run.log), SANS aucun secret, avec les prochaines actions.

    Les noms sont CODIFIES (application CLOUDIWAY-SOURCE-P<projet>, connecteur <prefixe du domaine>-source) : c'est ce qui rend les objets
    reutilisables d'une execution a l'autre (aucun doublon d'application ou de connecteur). CHAQUE execution (hors -WhatIf) RENOUVELLE les
    identifiants : nouveau certificat genere, ajoute a l'application et envoye au connecteur, puis anciens certificats de l'outil retires.
    Pour un simple controle de conformite sans rien renouveler : -KeepCredentials. Ne pas relancer l'outil pendant que des jobs de migration
    sont actifs.

    Securite : le certificat est genere EN MEMOIRE, envoye directement a Cloudiway, puis efface en fin d'execution. Aucun fichier de certificat,
    de mot de passe ou d'etat n'est ecrit ; rien n'est affiche ni journalise par l'outil (limite : journalisation PowerShell d'entreprise, voir plus bas).
    L'outil ne lit aucun contenu de messagerie et ne supprime rien dans Cloudiway ni dans le tenant, A UNE SEULE EXCEPTION : a chaque creation d'un
    nouveau certificat, l'application ne garde que le nouveau (anciens certificats retires avec une preuve de possession signee par le nouveau
    certificat, ou, si Microsoft refuse cette operation, par une mise a jour de la liste des cles qui ne garde que le nouveau). Les anciens
    certificats CREES PAR L'OUTIL (nom commencant par Cloudiway-SOURCE-P<projet>) sont retires de l'application APRES l'ecriture reussie du
    connecteur Cloudiway avec le nouveau certificat (jamais avant). Toute autre cle de l'application (posee a la main) est conservee. keyId et
    empreinte de chaque cle retiree figurent dans le rapport et le journal.
    Un objet existant au nom prevu mais sans l'etiquette CloudiwayConnector (application, connecteur cree a la main) n'est modifie qu'avec
    -AdoptExisting. Un connecteur existant n'est jamais degrade (produits en union, sens et region jamais modifies ; avec -KeepCredentials aucun
    certificat n'est renvoye et le connecteur n'est PAS mis a jour : le portail exige le certificat lors d'une mise a jour, la ligne est alors
    BLOQUEE), SAUF adoption d'un connecteur fait a la main : certificat et RestClientId sont alors REMPLACES (annonce dans le plan et
    confirmation supplementaire).

    Exchange Online (charge Mail) : l'outil se connecte avec le compte -Admin365 (module ExchangeOnlineManagement), LIT la configuration EWS
    (lecture seule, aussi avec -WhatIf) puis AJOUTE l'AppID de l'application a EwsAllowedAppIDs (ajout seul, jamais de remplacement ni de retrait).
    Si la liste est VIDE, la definir la rend RESTRICTIVE pour toutes les autres applications EWS du tenant : l'outil demande alors une
    confirmation explicite separee (defaut NON), ou ne fait rien avec -Yes (sauf -AllowEwsListCreation). Si EwsEnabled vaut False (EWS desactive
    pour l'organisation), rien n'est ecrit : decision du tenant. Tout echec Exchange (module absent, connexion, ecriture) est non bloquant :
    l'etape devient un "A faire" manuel avec les commandes exactes et le code de sortie est 2.

    Verification apres ecriture : le connecteur est RELU apres chaque POST / PUT (meme si la reponse est une erreur ou un delai depasse) ;
    l'ecriture n'est confirmee que si le nom de fichier du certificat relu est celui envoye (le portail remplace le certificat sur place).
    Sinon : echec, aucun ancien certificat retire, code de sortie 2.

    Codes de sortie : 0 = conforme ; 1 = arret avant toute ecriture (prerequis, acces, droits, refus, annulation, ou lignes bloquees sans
    rien d'applicable) ; 2 = applique avec des elements en echec, ignores, bloques ou non conformes (etape Exchange manuelle comprise).

    Journalisation PowerShell d'entreprise : si le poste active le Module Logging / Script Block Logging / Transcription, PowerShell peut
    enregistrer les parametres des commandes et le contenu des scripts, independamment de cet outil. L'outil n'ecrit jamais de secret
    dans ses propres fichiers, mais ne peut pas empecher cette journalisation systeme : verifier avec le service securite.

.PARAMETER Mode
    Source (tenant a migrer). Seule valeur acceptee dans cette version (defaut : Source) ; le mode Cible arrivera plus tard.

.PARAMETER Tenant
    Tenant du client : domaine xxxx.onmicrosoft.com (ou tout domaine verifie du tenant) OU identifiant GUID. Un domaine est resolu en GUID par
    la metadonnee publique de Microsoft (appel sans authentification). Demande si absent (exemple : contoso.onmicrosoft.com).

.PARAMETER Admin365
    Identifiant de connexion (adresse) du compte Administrateur general Microsoft 365 du tenant. Controle strict apres la connexion : si le
    compte choisi dans la fenetre Microsoft est different, l'outil s'arrete. Alias : -User. Demande si absent (exemple : admin365@contoso.com).

.PARAMETER Cloudiway
    Votre identifiant sur le portail Cloudiway (adresse e-mail de l'invitation). Le mot de passe est demande en saisie masquee (SecureString) :
    il n'est jamais passe en parametre, jamais stocke. Demande si absent (sauf avec -CloudiwayPat ou -SkipCloudiway ; exemple : paul.bernard@contoso.com).

.PARAMETER CloudiwayPat
    Alternative au mot de passe (usage scripte) : jeton PAT Cloudiway en [securestring] (portail : ACCOUNT > Security > NEW TOKEN).
    Jamais affiche, jamais ecrit.

.PARAMETER ProjectId
    Numero du projet Cloudiway (exemple : -ProjectId 12345). Facultatif : il est detecte automatiquement (un seul projet visible : retenu
    sans question ; plusieurs : liste a choisir ; aucun : erreur claire). Demande si absent UNIQUEMENT quand il n'est pas determinable
    (obligatoire avec -SkipCloudiway, car il sert a nommer les objets).

.PARAMETER Workloads
    Charges de travail a migrer : Mail, OneDrive, ou All (= Mail et OneDrive). Demande si absent (question en console interactive, exemple de
    reponse : 1,2 ou Mail,OneDrive). AUCUNE valeur par defaut : le choix est explicite (en mode questions, aucune charge n'est pre-selectionnee
    et chaque charge indique les privileges qu'elle ajoute ; sans console interactive, -Workloads est obligatoire). SharePoint, Teams, Archive,
    GalSync, Intune, FreeBusy, Signature et MailRouting ne sont pas disponibles dans cette version : ils sont refuses avec un message clair.
    Plusieurs valeurs separees par des virgules ; avec "pwsh -File", la forme -Workloads Mail,OneDrive est acceptee (l'outil separe lui-meme
    les valeurs). Les permissions demandees dependent uniquement de ce choix.

.PARAMETER AuthMethod
    Certificate (defaut, recommande par Cloudiway), Secret (secret client) ou Both. Le secret ou le certificat est genere en memoire.
    Seule la methode Certificate a ete validee en conditions reelles.

.PARAMETER ValidityDays
    Duree de validite des identifiants generes, de 45 a 730 jours (defaut 180, soit 6 mois). Minimum 45 : le renouvellement automatique intervient 30 jours avant l'echeance. Alias : -CertValidityDays.

.PARAMETER RotateCredentials
    Sans effet (conserve pour compatibilite) : le renouvellement des identifiants est le comportement PAR DEFAUT.
    Incompatible avec -KeepCredentials. Alias : -RotateCertificate.

.PARAMETER KeepCredentials
    Simple controle de conformite : si le marqueur du connecteur est coherent et que le certificat (ou secret) est valide plus de
    30 jours, rien n'est regenere ni renvoye ; le marqueur est le nom de fichier du certificat du connecteur
    (CIW1_<empreinte>_<AAAAMMJJ>.pfx). Si une mise a jour du connecteur etait necessaire (ex. produit manquant), la ligne Cloudiway est BLOQUEE :
    le portail exige le certificat lors d'une mise a jour, relancer sans -KeepCredentials. Sans cette option, CHAQUE execution renouvelle le
    certificat (ou secret) : le connecteur existant est mis a jour a chaque execution, puis les anciens certificats / secrets crees par l'outil
    sont retires de l'application (les cles posees a la main sont conservees). A ne pas relancer pendant que des jobs de migration sont actifs.
    Incompatible avec -RotateCredentials.

.PARAMETER AdoptExisting
    Autorise l'outil a modifier une application ou un connecteur Cloudiway deja existant au nom prevu mais sans l'etiquette
    CloudiwayConnector. Sans cette option, la ligne du plan est BLOQUE avec explication. ATTENTION : adopter un connecteur fait a la
    main REMPLACE son certificat et son RestClientId ; une confirmation supplementaire est demandee (sauf avec -Yes). Cette option leve aussi
    le blocage "collision de noms" (TenantName ou RestClientId du connecteur differents de ceux voulus).

.PARAMETER AppName
    Surcharge facultative du nom de l'application Entra (defaut codifie : CLOUDIWAY-SOURCE-P<projet>).

.PARAMETER ServiceAccountName
    Sans effet avec les charges Mail et OneDrive en mode Source (aucun compte de service n'est cree). Si un nom est fourni, sa partie locale
    doit commencer par "svc-ciw-".

.PARAMETER ConnectorName
    Surcharge facultative du nom du connecteur Cloudiway (defaut codifie : <TenantShort>-source).

.PARAMETER OutDir
    Dossier de base du rapport et du journal (defaut : connecteur-resultats a cote du script, ou %LOCALAPPDATA%\CloudiwayConnector si le
    dossier du script est sous OneDrive, Dropbox, Telechargements ou sur un partage reseau). Aucun secret n'y est ecrit, mais le rapport
    contient des identifiants de tenant : eviter un dossier synchronise ou partage (l'outil avertit).

.PARAMETER ProductIds
    Identifiants de produits Cloudiway (rawProductList) pour les charges dont le produit est inconnu. Plusieurs valeurs separees par des
    virgules (ex. 5,6). Connus : Mail = 5, Fichiers (OneDrive) = 6.

.PARAMETER ProductMapFile
    Fichier JSON de correspondance charges de travail / produits Cloudiway (produit par -Discover).

.PARAMETER Region
    Region serveur Cloudiway (ServerRegion) ecrite dans le connecteur. Defaut 1.

.PARAMETER CertificateTransport
    Facon d'envoyer le certificat a Cloudiway : Base64 (defaut, contenu du PFX encode dans la requete, aucun fichier) ou Path (fichier
    temporaire a acces restreint dans %TEMP%, ecrase puis supprime juste apres l'appel). Seul le transport Base64 est recommande.

.PARAMETER AllowEwsListCreation
    Charge Mail. Autorise, SANS question, la creation de la liste EwsAllowedAppIDs quand elle est VIDE ou absente sur le tenant. ATTENTION :
    definir cette liste la rend RESTRICTIVE, donc elle BLOQUE toutes les autres applications EWS du tenant qui n'y figurent pas (outils de
    sauvegarde, applications mobiles tiers, etc.). Sans cette option : confirmation explicite separee (defaut NON) en mode questions, et ligne
    IGNOREE (rien n'est ecrit, passage en "A verifier" avec la commande) avec -Yes. Si la liste contient deja des entrees, l'AppID y est
    simplement ajoute (aucune option necessaire) ; si EwsEnabled vaut False, rien n'est jamais ecrit.

.PARAMETER UseDeviceCode
    Connexion Microsoft Graph (et Exchange Online avec le parametre -Device du module, charge Mail) par code d'appareil (code a saisir sur https://microsoft.com/devicelogin) au lieu de la fenetre de connexion. Utile quand la meme personne enchaine plusieurs tenants et que la fenetre reprend le mauvais compte (saisir le code dans la fenetre de navigation privee de son choix), ou sur un poste sans navigateur. Certains tenants bloquent ce flux par acces conditionnel. Le tenant et le compte sont verifies de la meme facon.

.PARAMETER SkipCloudiway
    Configure le tenant seulement : aucun appel a Cloudiway, aucun mot de passe demande (-ProjectId devient obligatoire).

.PARAMETER Discover
    Mode decouverte : prerequis du poste et acces Cloudiway uniquement, puis liste des connecteurs du projet. Aucune connexion au tenant,
    aucune ecriture. Sert a relever les produits et la forme d'un connecteur cree a la main.

.PARAMETER ConnectorId
    Avec -Discover : identifiant d'un connecteur dont la configuration (masquee) est enregistree dans decouverte-<id>.json.

.PARAMETER InstallMissingModules
    Installe sans question le module PowerShell manquant (Microsoft.Graph.Authentication et, pour la charge Mail, ExchangeOnlineManagement ; profil utilisateur, sans droits administrateur).

.PARAMETER Yes
    Saute la confirmation interactive du plan (usage scriptable). Jamais active implicitement.

.PARAMETER WhatIf
    Simulation : affiche le plan sans rien ecrire dans le tenant ni dans Cloudiway (la lecture du tenant et du projet reste necessaire pour
    construire le plan). A faire en premier.

.EXAMPLE
    ./cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com
    Commande type : l'outil demande le mot de passe Cloudiway (masque), detecte le projet, affiche le plan puis demande confirmation.

.EXAMPLE
    ./cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -ProjectId 12345
    Commande complete : le numero de projet se passe en parametre (-ProjectId 12345), sans variable ; il est facultatif (detecte sinon).

.EXAMPLE
    ./cloudiway-connector.ps1
    Commande minimale : l'outil pose les questions une par une (tenant, compte administrateur, charges de travail, compte Cloudiway), avec un exemple et une validation immediate ; le projet n'est demande que s'il n'est pas determinable.

.EXAMPLE
    ./cloudiway-connector.ps1 -Mode Source -Tenant contoso.onmicrosoft.com -Admin365 admin365@contoso.com -Cloudiway paul.bernard@contoso.com -Workloads Mail,OneDrive -WhatIf
    Simulation recommandee en premier : affiche le plan complet sans rien creer ni modifier.

.EXAMPLE
    ./cloudiway-connector.ps1 -Discover -Cloudiway paul.bernard@contoso.com -ConnectorId 123
    Decouverte : liste les connecteurs du projet et enregistre la configuration masquee du connecteur 123 (aucune connexion au tenant).
#>
[CmdletBinding(SupportsShouldProcess, PositionalBinding = $false)]
param(
    [ValidateSet('Source')][string]$Mode = 'Source',
    [string]$Tenant,
    [Alias('User')][string]$Admin365,
    [string]$Cloudiway,
    [securestring]$CloudiwayPat,
    [ValidateRange(1, 2147483647)][int]$ProjectId,
    [string[]]$Workloads,
    [ValidateSet('Certificate', 'Secret', 'Both')][string]$AuthMethod = 'Certificate',
    [Alias('CertValidityDays')][ValidateRange(45, 730)][int]$ValidityDays = 180,
    [Alias('RotateCertificate')][switch]$RotateCredentials,
    [switch]$KeepCredentials,
    [switch]$AdoptExisting,
    [string]$AppName,
    [string]$ServiceAccountName,
    [string]$ConnectorName,
    [string]$OutDir,
    [string[]]$ProductIds,
    [string]$ProductMapFile,
    [ValidateRange(0, 99)][int]$Region = 1,
    [ValidateSet('Base64', 'Path')][string]$CertificateTransport = 'Base64',
    [switch]$UseDeviceCode,
    [switch]$AllowEwsListCreation,
    [switch]$SkipCloudiway,
    [switch]$Discover,
    [int]$ConnectorId,
    [switch]$InstallMissingModules,
    [switch]$Yes
)

# m9 : l'outil est ecrit sans mode strict ; une session qui l'aurait active (Set-StrictMode -Version Latest dans un profil) ne doit pas le casser.
Set-StrictMode -Off

# ATTENTION : le parametre -AppName et la variable $script:AppName de lib\common.ps1 (titre de l'outil) ont le meme nom de variable.
# La valeur du parametre est donc copiee dans $TenantAppName AVANT le chargement des bibliotheques, et seule cette copie est utilisee ensuite.
$TenantAppName = $AppName

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'   # rien d'autre que nos propres messages a l'ecran
$ScriptStart = Get-Date
$LibDir = Join-Path $PSScriptRoot 'lib'

# --- Chargement des bibliotheques (au niveau script : les fonctions restent visibles de tout le script) ---------
$libFiles = @('common.ps1', 'graphauth.ps1', 'ui.ps1', 'preflight.ps1', 'permissions.ps1', 'entra.ps1', 'exchange.ps1', 'cloudiway.ps1')
$missingLibs = @($libFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LibDir $_)) })
if ($missingLibs.Count -gt 0) {
    Write-Host "Fichier(s) manquant(s) dans '$LibDir' : $($missingLibs -join ', ')" -ForegroundColor Red
    Write-Host "Le package est incomplet : le dossier 'lib' doit rester a cote de cloudiway-connector.ps1. Recopier le package complet." -ForegroundColor Yellow
    exit 1
}
foreach ($lf in $libFiles) { . (Join-Path $LibDir $lf) }
# Identite de la version (prime sur les valeurs de lib\common.ps1)
$script:AppName = '3SR - Configuration du connecteur Cloudiway'
$script:AppVersion = '2.4'
$script:AppDate = '31/10/2026'
$ScriptVersion = [string]$script:AppVersion

# Proxy d'entreprise : les appels HTTP de la session utilisent les identifiants Windows de l'utilisateur pour s'authentifier aupres du proxy.
Enable-ProxyDefaultCredentials

# --- Simulation : l'etat -WhatIf est memorise puis neutralise pour les cmdlets LOCALES (journal, rapport) ; aucune ecriture tenant n'est
#     jamais tentee en simulation (la boucle d'application n'est pas executee).
$simulate = [bool]$WhatIfPreference
$shouldGo = $PSCmdlet.ShouldProcess('le tenant et le projet Cloudiway', 'Configurer le connecteur Cloudiway')
$WhatIfPreference = $false
if (-not $shouldGo -and -not $simulate) { Write-Host 'Operation annulee.' -ForegroundColor Yellow; exit 1 }

# ====================================================================================================
# Constantes et petites aides
# ====================================================================================================
# m10 : valeur entouree d'apostrophes (apostrophes doublees) dans une commande a copier : un nom contenant un espace, un $ ou une apostrophe reste valide.
function Format-QuotedArg([string]$Value) { return ("'" + ("$Value" -replace "'", "''") + "'") }
$AllWorkloads = @('Mail', 'OneDrive')
# Charges reconnues par l'outil mais NON disponibles dans cette version : refusees avec un message clair.
$script:UnavailableWorkloadNames = @('Archive', 'SharePoint', 'Teams', 'GalSync', 'Intune', 'FreeBusy', 'Signature', 'MailRouting')
# Chaque charge indique les PRIVILEGES qu'elle ajoute (l'ecran de choix n'a aucune valeur pre-cochee : le DSI sait ce qu'il accorde).
$WorkloadInfo = @(
    @{ Key = 'Mail'; Label = 'Mail'; Detail = 'boites aux lettres : lecture/ecriture des boites (full_access_as_app, Exchange.ManageAsApp), roles Exchange Administrator et Exchange Recipient Administrator pour l''application, ajout de l''application a la liste EWS d''Exchange Online' }
    @{ Key = 'OneDrive'; Label = 'OneDrive'; Detail = 'OneDrive : acces aux fichiers de tous les utilisateurs (Files.ReadWrite.All, Sites.FullControl.All)' }
)

# Scopes Graph d'ecriture demandes a la connexion de l'administrateur
$GraphScopes = @(
    'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All',
    'RoleManagement.ReadWrite.Directory', 'User.ReadWrite.All', 'Directory.Read.All', 'Policy.Read.All', 'Organization.Read.All'
)
# Ordre d'application et dependances entre zones
# ServiceAccountPwd : reinitialisation du mot de passe du compte de service, APRES l'ecriture du connecteur ; si Cloudiway est
# en echec, ignore ou bloque, le compte garde son mot de passe actuel (le connecteur existant reste coherent).
# Cleanup : retrait des anciens certificats / secrets CREES PAR L'OUTIL, SEULEMENT apres l'ecriture reussie du
# connecteur : si la ligne Cloudiway est en echec, ignoree ou bloquee, la ligne de nettoyage est ignoree et rien n'est retire.
$AreaOrder = @('Application', 'ServicePrincipal', 'Permissions', 'Consent', 'Roles', 'Exchange', 'Certificate', 'ServiceAccount', 'Cloudiway', 'ServiceAccountPwd', 'Cleanup')
$AreaDeps = @{
    Cleanup          = @('Cloudiway', 'Certificate')   # DEPENDANCE-CONNECTEUR
    ServicePrincipal = @('Application')
    Permissions      = @('Application')
    Consent          = @('ServicePrincipal', 'Permissions')
    Roles            = @('ServicePrincipal')
    Exchange         = @('Application')   # etape non bloquante : aucune autre zone n'en depend
    Certificate      = @('Application')
    ServiceAccount   = @()
    Cloudiway        = @('Application', 'Certificate', 'ServiceAccount')
    ServiceAccountPwd = @('Cloudiway')
}
$script:GraphConnected = $false
$script:CwPassword = $null          # mot de passe Cloudiway du DSI (SecureString, memoire seulement)
$script:PartialConsentNote = ''

# Efface tous les secrets detenus en memoire : identifiants generes, mot de passe Cloudiway, PAT, etat de session Cloudiway.
function Clear-RunSecrets {
    # Module Entra : efface certificat, secret et mot de passe du compte de service (le PFX temporaire du transport Path est supprime par le module Cloudiway)
    try { if (Get-Command -Name Clear-EntraCredentials -ErrorAction SilentlyContinue) { Clear-EntraCredentials 'All' } } catch { }
    try {
        $c = $script:Ctx
        if ($c -and $c.Credentials -is [System.Collections.IDictionary]) {
            foreach ($k in @($c.Credentials.Keys)) {
                $v = $c.Credentials[$k]
                try { if ($v -is [byte[]]) { [Array]::Clear($v, 0, $v.Length) } elseif ($v -is [System.IDisposable]) { $v.Dispose() } } catch { }
                $c.Credentials[$k] = $null
            }
            $c.Credentials.Clear()
        }
        if ($c) { $c.Credentials = @{} }
    } catch { }
    try { if ($script:CwPassword) { $script:CwPassword.Dispose() } } catch { }
    $script:CwPassword = $null
    $script:CloudiwayPat = $null
    try { if (Get-Command -Name Clear-CloudiwayState -ErrorAction SilentlyContinue) { Clear-CloudiwayState } } catch { }
}

# Fin de run unique : deconnexion Graph, effacement des secrets en memoire, code de sortie.
function Stop-Run([int]$Code) {
    try { if ($script:GraphConnected) { Disconnect-MgGraph | Out-Null } } catch { }
    $script:GraphConnected = $false
    try { Disconnect-Exchange } catch { }
    Clear-RunSecrets
    # La console de l'utilisateur est rendue telle qu'elle etait (encodage), et $Error (qui pourrait contenir des parametres de commandes)
    # est vide : tout ce qui devait etre affiche l'a deja ete.
    try { Restore-ConsoleEncoding } catch { }
    try { $global:Error.Clear() } catch { }
    exit $Code
}

# Statut affiche a l'ecran ET trace dans run.log (jamais de secret dans $Text / $Detail)
function Write-StatusLog([string]$Level, [string]$Text, [string]$Detail = '') {
    Write-Status $Level $Text $Detail
    Write-RunLog ('[{0}] {1} {2}' -f $Level, $Text, $Detail)
}

function Get-SafeProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    try {
        if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $null } }
        $p = $Obj.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    } catch { }
    return $null
}

# Dependances PAR LIGNE de plan (et non par zone). Une ligne BLOCKED purement informative (permission introuvable) ne bloque personne.
function Test-InformativeBlock($Item) {
    return ([string]$Item.Area -eq 'Permissions' -and [string]$Item.Name -eq 'Permissions introuvables')
}
# Retourne les lignes en echec / ignorees / bloquees dont depend la ligne $It :
#  - zones precedentes (table $AreaDeps) : toute ligne mauvaise de la zone, sauf les roles du compte de service (la creation du connecteur n'en depend pas) ;
#  - meme zone : un role du compte de service depend de la creation / de l'etat du compte (lignes de la zone ne commencant pas par "Role ").
function Get-FailedDependency($It, $Bad) {
    $area = [string]$It.Area
    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($AreaDeps[$area])) {
        foreach ($b in @($Bad | Where-Object { [string]$_.Area -eq $d -and -not ($d -eq 'ServiceAccount' -and [string]$_.Name -like 'Role *') })) { $hits.Add($b) }
    }
    if ($area -eq 'ServiceAccount' -and [string]$It.Name -like 'Role *') {
        foreach ($b in @($Bad | Where-Object { [string]$_.Area -eq 'ServiceAccount' -and [string]$_.Name -notlike 'Role *' -and [int]$_.Id -lt [int]$It.Id })) { $hits.Add($b) }
    }
    return @($hits)
}

# Nom court du tenant d'apres son domaine : prefixe COMPLET (minuscules, [a-z0-9-]), jamais tronque.
function Get-TenantShort([string]$Domain, [string]$Fallback) {
    $s = ''
    if ($Domain) { $s = ($Domain.ToLowerInvariant() -split '\.')[0] }
    $s = ($s -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $s) { $s = $Fallback }
    return $s
}

function ConvertTo-MdCell($Text) { (("" + $Text) -replace '\|', '/' -replace '\r?\n', ' ').Trim() }

function Get-AppIdText {
    $id = Get-SafeProp $script:Ctx.Created 'AppId'
    if (-not $id) { $id = Get-SafeProp $script:EntraState 'AppId' }
    if (-not $id) { $id = Get-SafeProp (Get-SafeProp $script:EntraState 'Application') 'appId' }
    if (-not $id) { $id = Get-SafeProp (Get-SafeProp $script:EntraState 'App') 'appId' }
    if ($id) { return [string]$id }
    return ''
}

# Identifiant (entier) d'un projet Cloudiway quelle que soit la forme retournee (entier, ou objet id / ProjectId).
function Get-ProjectIdFrom($Value) {
    if ($null -eq $Value) { return 0 }
    $first = @($Value) | Select-Object -First 1
    if ($first -is [int] -or $first -is [long]) { return [int]$first }
    foreach ($n in 'ProjectId', 'projectId', 'Id', 'id') {
        $v = Get-SafeProp $first $n
        if ($null -ne $v) { $i = 0; if ([int]::TryParse("$v", [ref]$i) -and $i -gt 0) { return $i } }
    }
    return 0
}

# Calcule les noms codifies (Get-CodedNames, module Permissions) et les memorise dans le contexte.
function Set-CodedNames([string]$Short) {
    if (-not (Get-Command -Name Get-CodedNames -ErrorAction SilentlyContinue)) {
        throw 'Get-CodedNames est introuvable : lib\permissions.ps1 n''est pas a jour (package incomplet).'
    }
    $a = @{ Mode = $Mode; ProjectId = [int]$script:Ctx.ProjectId; TenantShort = $Short }
    if ($TenantAppName) { $a['AppName'] = $TenantAppName }
    if ($ServiceAccountName) { $a['ServiceAccountName'] = $ServiceAccountName }
    if ($ConnectorName) { $a['ConnectorName'] = $ConnectorName }
    $n = Get-CodedNames @a
    $script:Ctx.Names = $n
    $script:Ctx.AppName = [string]$n.App
    $script:Ctx.ServiceAccountName = [string]$n.ServiceAccountLocal
    $script:Ctx.ConnectorName = [string]$n.Connector
    Write-RunLog ("Noms codifies : application={0} compte={1} connecteur={2}" -f $n.App, $n.ServiceAccountLocal, $n.Connector)
}

# Lit le connecteur existant (renseigne $script:Ctx.ExistingConnector) : doit preceder New-EntraPlan. Les noms codifies doivent etre fixes.
function Read-ExistingConnector {
    # Initialize-CloudiwayConnectorState RETOURNE des lignes { Name; Status; Detail } : elles doivent etre capturees (journal), sinon elles
    # s'affichent en fin d'execution sous forme d'un tableau parasite "Name Status Detail".
    foreach ($ln in @(Initialize-CloudiwayConnectorState)) { if ($ln) { Write-RunLog ("CONNECTEUR {0} : {1} {2}" -f $ln.Name, $ln.Status, $ln.Detail) } }
    $ex = $script:Ctx.ExistingConnector
    if ($null -eq $ex) {
        Write-StatusLog INFO 'Connecteur existant : aucun' ("le connecteur '{0}' sera cree" -f $script:Ctx.ConnectorName)
    } else {
        $exId = Get-SafeProp $ex 'id'; if ($null -eq $exId) { $exId = Get-SafeProp $ex 'Id' }
        Write-StatusLog INFO 'Connecteur existant trouve' ("'{0}'{1} : il sera mis a jour si necessaire" -f $script:Ctx.ConnectorName, $(if ($null -ne $exId) { " (id $exId)" } else { '' }))
    }
}

# Date d'expiration des identifiants du connecteur, memorisee AVANT l'effacement des secrets (Clear-RunSecrets) :
#  - nouveaux identifiants transmis au connecteur dans CE passage (ConnectorWriteOk) : leur expiration reelle ;
#  - sinon : marqueur (CIW1|...|AAAAMMJJ) du connecteur existant lu a l'etape 2. Jamais une duree en dur.
function Save-CredentialExpiry {
    $script:CredExpiry = $null
    $script:CredKind = 'certificat'
    try {
        $c = $script:Ctx
        if ($c.SkipCloudiway -or $c.Discover) { return }
        $d = $null
        if ($c.ConnectorWriteOk -and $c.Credentials -is [System.Collections.IDictionary]) {
            if ($c.AuthMethod -eq 'Secret') { $d = $c.Credentials['SecretNotAfter']; $script:CredKind = 'secret client' }
            else { $d = $c.Credentials['CertNotAfter'] }
        }
        if ($d -is [datetime]) { $script:CredExpiry = $d.ToUniversalTime(); return }
        $mk = Get-ConnectorMarker $c.ExistingConnector
        if ($mk -and $mk.NotAfter) {
            $script:CredExpiry = ([datetime]$mk.NotAfter).ToUniversalTime()
            if ([string]$mk.Thumbprint -clike 'S*') { $script:CredKind = 'secret client' }
        }
    } catch { $script:CredExpiry = $null }
}

# Les textes Exchange sont ecrits au moment du plan, parfois AVANT la creation de l'application : "<AppID>" est remplace par l'AppID reel
# des que celui-ci est connu (commandes a copier exactes dans "A faire" / "A verifier").
function Expand-AppIdToken([string]$Text) {
    $id = Get-AppIdText
    if ($id -and $Text) { return $Text.Replace('<AppID>', $id) }
    return $Text
}

# Prochaines actions (console ET rapport). Deux groupes, une ligne n'apparait QUE si elle demande quelque chose :
#   Todo  = "A faire"    : actions reelles que l'outil n'a pas pu faire ;
#   Check = "A verifier" : informations et controles non automatisables (l'outil ne devine pas, ne modifie pas).
# Un groupe vide n'est pas affiche. Rien n'est execute par cette fonction.
function Get-NextSteps {
    $todo = [System.Collections.Generic.List[object]]::new()
    $check = [System.Collections.Generic.List[object]]::new()
    $appId = Get-AppIdText
    $appTxt = if ($appId) { $appId } else { '<AppID>' }
    $wl = @($script:Ctx.Workloads)
    $isTarget = ($script:Ctx.Mode -eq 'Target')

    # --- A faire ---
    $consentItems = @($script:Plan | Where-Object { $_.Area -eq 'Consent' })
    $consentOk = $true
    foreach ($ci in $consentItems) {
        $res = @($script:Results | Where-Object { $_.Id -eq $ci.Id } | Select-Object -First 1)
        $state = if ($res.Count -gt 0) { [string]$res[0].Outcome } else { '' }
        if (-not ($ci.Action -eq 'OK' -or $state -eq 'APPLIQUE')) { $consentOk = $false }
    }
    # Le consentement n'est mentionne QUE s'il manque (jamais de ligne "deja accorde / rien a faire")
    if ($consentItems.Count -gt 0 -and -not $consentOk) {
        $todo.Add(@{ Title = 'Accorder le consentement administrateur'; Text = 'Le consentement n''est pas (ou pas completement) accorde. Un Administrateur general peut l''accorder en ouvrant ce lien :'; Command = @("https://login.microsoftonline.com/$($script:Ctx.TenantId)/adminconsent?client_id=$appTxt") })
    }
    if ($script:Exo) { foreach ($m in @($script:Exo.Manual)) { $todo.Add(@{ Title = (Expand-AppIdToken ([string]$m.Title)); Text = (Expand-AppIdToken ([string]$m.Text)); Command = @($m.Command | ForEach-Object { Expand-AppIdToken ([string]$_) }) }) } }
    if ($script:Ctx.NeedServiceAccount) {
        if ($wl -contains 'Teams') {
            $todo.Add(@{ Title = 'Teams : attribuer une licence Teams au compte de service'; Text = 'Aucune licence n''est jamais attribuee par l''outil. Attribuer au compte de service une licence incluant Teams.' })
        }
        if ($script:Ctx.ServiceAccountPasswordManual) {
            $todo.Add(@{ Title = 'Compte de service adopte : saisir son mot de passe dans le portail Cloudiway'; Text = 'Le mot de passe d''un compte existant n''est jamais reinitialise par l''outil : si le plan indique un compte adopte, renseigner son mot de passe directement dans le connecteur (portail Cloudiway).' })
        }
    }
    if ($script:Ctx.SkipCloudiway) {
        $todo.Add(@{ Title = 'Declarer le connecteur dans Cloudiway'; Text = 'Option -SkipCloudiway : seul le tenant a ete configure. Relancer sans cette option pour creer le connecteur dans le projet.' })
    }
    foreach ($ds in @($script:FinalDesyncNotes)) { if ($ds) { $todo.Add(@{ Title = 'ATTENTION : mot de passe du compte de service desynchronise'; Text = [string]$ds }) } }

    # --- A verifier ---
    if ($script:PartialConsentNote) {
        $check.Add(@{ Title = 'Consentement partiel : permissions introuvables dans ce tenant'; Text = [string]$script:PartialConsentNote })
    }
    if ($script:Exo) { foreach ($m in @($script:Exo.Verify)) { $check.Add(@{ Title = (Expand-AppIdToken ([string]$m.Title)); Text = (Expand-AppIdToken ([string]$m.Text)); Command = @($m.Command | ForEach-Object { Expand-AppIdToken ([string]$_) }) }) } }
    if ($script:Ctx.NeedServiceAccount) {
        $upn = Get-SafeProp $script:Ctx.Created 'ServiceAccountUpn'
        $upnTxt = if ($upn) { [string]$upn } else { [string]$script:Ctx.ServiceAccountName }
        if ($isTarget -and ($wl -contains 'Teams')) {
            $check.Add(@{ Title = "Compte de service $upnTxt : MFA / acces conditionnel (Teams en Cible)"; Text = 'Information : pendant la migration des chats 1:1 et des canaux Teams, le compte de service Cible se connecte sans interaction ; si une strategie d''acces conditionnel lui impose la MFA, l''en exclure pendant la migration, puis remettre l''exclusion a zero. L''outil ne devine pas la politique de votre tenant et ne la modifie jamais ; ne jamais desactiver la MFA du tenant lui-meme.' })
        } else {
            $check.Add(@{ Title = "Compte de service $upnTxt : MFA / acces conditionnel"; Text = 'Information : le compte de service se connecte sans interaction ; si une strategie d''acces conditionnel lui impose la MFA, l''en exclure. L''outil ne devine pas la politique de votre tenant et ne la modifie jamais.' })
        }
    }
    # Renouvellement : simple information (pas une action), calculee sur l'expiration REELLE du certificat transmis ou du marqueur lu
    if ($script:CredExpiry -is [datetime]) {
        $exp = [datetime]$script:CredExpiry
        $days = [int][Math]::Floor(($exp.Date - [datetime]::UtcNow.Date).TotalDays)
        $inTxt = if ($days -gt 1) { "dans $days jours" } elseif ($days -eq 1) { 'dans 1 jour' } elseif ($days -eq 0) { 'aujourd''hui' } elseif ($days -eq -1) { 'depuis 1 jour' } else { "depuis $([Math]::Abs($days)) jours" }
        $what = if ($script:CredKind -eq 'secret client') { 'Le secret client du connecteur' } else { 'Le certificat du connecteur' }
        $verb = if ($days -lt 0) { 'a expire le' } else { 'expire le' }
        $expTxt = $exp.ToString('dd/MM/yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($script:Ctx.KeepCredentials) {
            $txt = ("{0} {1} {2} ({3}). Mode -KeepCredentials : rien n'est renouvele tant que l'identifiant est valide plus de 30 jours ; relancer sans cette option pour renouveler." -f $what, $verb, $expTxt, $inTxt)
            if ($script:Ctx.NeedServiceAccount) { $txt += ' Le compte de service n''expire pas (mot de passe sans expiration) et son mot de passe n''est reinitialise que si le connecteur doit en recevoir un nouveau.' }
        }
        else {
            $txt = ("{0} {1} {2} ({3}). Chaque relance de l'outil renouvelle le certificat (nouveau certificat envoye au connecteur, anciens retires) ; ne pas relancer pendant que des jobs de migration sont actifs." -f $what, $verb, $expTxt, $inTxt)
            if ($script:Ctx.NeedServiceAccount) { $txt += ' Le compte de service n''expire pas (mot de passe sans expiration), mais chaque relance reinitialise aussi son mot de passe et le renvoie au connecteur.' }
        }
        $check.Add(@{ Title = ('Expiration des identifiants du connecteur : ' + $expTxt); Text = $txt })
    }
    # Informations non bloquantes relevees pendant l'application (capturees avant l'effacement de l'etat Cloudiway)
    foreach ($nt in @($script:FinalNotices)) { if ($nt) { $check.Add(@{ Title = 'A savoir (Cloudiway)'; Text = [string]$nt }) } }
    return @{ Todo = @($todo); Check = @($check) }
}

# Rapport Markdown SANS secret.
function New-ReportMarkdown($PlanItems, $ResultItems, $VerifRows, [bool]$IsSimulation, $Counts) {
    $c = $script:Ctx
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# Rapport - connecteur Cloudiway ($($c.Mode)) - $($c.TenantShort)")
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("- Outil : $($script:AppName) version $ScriptVersion ($($script:AppDate))")
    $null = $sb.AppendLine("- Date : {0:yyyy-MM-dd HH:mm}" -f (Get-Date))
    $null = $sb.AppendLine("- Mode d'execution : " + $(if ($IsSimulation) { 'SIMULATION (-WhatIf) : aucune ecriture dans le tenant ni dans Cloudiway' } else { 'application reelle' }))
    $null = $sb.AppendLine("- Role : $(Get-ModeLabel $c.Mode)")
    $null = $sb.AppendLine("- Tenant : $($c.TenantId) ($($c.DefaultDomain))")
    if ($c.Admin365) { $null = $sb.AppendLine("- Compte administrateur Microsoft 365 : $($c.Admin365)") }
    if ($c.CloudiwayLogin) { $null = $sb.AppendLine("- Compte Cloudiway : $($c.CloudiwayLogin)") }
    $null = $sb.AppendLine("- Charges de travail : $(@($c.Workloads) -join ', ')")
    $null = $sb.AppendLine("- Authentification du connecteur : $($c.AuthMethod), validite $($c.ValidityDays) jours")
    $null = $sb.AppendLine("- Application : $($c.AppName)")
    $null = $sb.AppendLine("- Compte de service : " + $(if ($c.NeedServiceAccount) { $c.ServiceAccountName } else { 'non necessaire pour ces charges' }))
    $null = $sb.AppendLine("- Projet Cloudiway : " + $(if ($c.SkipCloudiway) { "$($c.ProjectId) (appel a Cloudiway ignore : -SkipCloudiway)" } else { "$($c.ProjectId), connecteur $($c.ConnectorName)" }))
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('## Resultat')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine("Appliques : $($Counts.Applied) - En echec : $($Counts.Failed) - Ignores : $($Counts.Ignored) - Bloques : $($Counts.Blocked) - Verification : $($Counts.Compliant) conforme(s), $($Counts.NonCompliant) non conforme(s).")
    if ($script:PartialConsentNote) { $null = $sb.AppendLine(''); $null = $sb.AppendLine("**Attention - $($script:PartialConsentNote)**") }
    $null = $sb.AppendLine('')
    # "Valeurs a connaitre" : affichee SEULEMENT si elle contient des valeurs (AppID, compte de service, empreinte, expiration...)
    $valLines = [System.Collections.Generic.List[string]]::new()
    $appId = Get-AppIdText
    if ($appId) { $valLines.Add("- AppID de l'application : ``$appId``") }
    foreach ($k in 'AppObjectId', 'SpObjectId', 'CertThumbprint', 'ServiceAccountUpn') {
        $v = Get-SafeProp $c.Created $k
        if ($v) { $valLines.Add("- ${k} : ``$v``") }
    }
    if ($script:CredExpiry -is [datetime]) { $valLines.Add(("- Expiration du {0} du connecteur : {1:yyyy-MM-dd}" -f $(if ($script:CredKind -eq 'secret client') { 'secret client' } else { 'certificat' }), $script:CredExpiry)) }
    $removed = @(Get-SafeProp $c.Created 'CleanupRemoved' | Where-Object { $_ })
    if ($removed.Count -gt 0) {
        $valLines.Add("- Anciens identifiants de l'outil RETIRES de l'application apres transmission du nouveau au connecteur ($($removed.Count)) :")
        foreach ($rm in $removed) { $valLines.Add("  - ``$rm``") }
    }
    if ($valLines.Count -gt 0) {
        $null = $sb.AppendLine('## Valeurs a connaitre (aucun secret)')
        $null = $sb.AppendLine('')
        foreach ($vl in $valLines) { $null = $sb.AppendLine($vl) }
        $null = $sb.AppendLine('')
    }
    $null = $sb.AppendLine('## Plan')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| Id | Zone | Element | Action | Raison |')
    $null = $sb.AppendLine('|---|---|---|---|---|')
    foreach ($p in $PlanItems) {
        $null = $sb.AppendLine("| $($p.Id) | $(Get-ZoneLabel ([string]$p.Area)) | $(ConvertTo-MdCell $p.Name) | $((Get-ActionStyle ([string]$p.Action)).Label) | $(ConvertTo-MdCell $p.Reason) |")
    }
    $null = $sb.AppendLine('')
    if (@($ResultItems).Count -gt 0) {
        $null = $sb.AppendLine('## Application')
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| Id | Zone | Element | Resultat | Detail |')
        $null = $sb.AppendLine('|---|---|---|---|---|')
        foreach ($r in $ResultItems) {
            $null = $sb.AppendLine("| $($r.Id) | $(Get-ZoneLabel ([string]$r.Area)) | $(ConvertTo-MdCell $r.Name) | $((Get-ActionStyle ([string]$r.Outcome)).Label) | $(ConvertTo-MdCell $r.Detail) |")
        }
        $null = $sb.AppendLine('')
    }
    if (@($VerifRows).Count -gt 0) {
        $null = $sb.AppendLine('## Verification')
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('| Controle | Etat | Detail |')
        $null = $sb.AppendLine('|---|---|---|')
        foreach ($v in $VerifRows) {
            $null = $sb.AppendLine("| $(ConvertTo-MdCell $v.Name) | $(switch (Get-UILevel ([string]$v.Status)) { 'OK' { 'Conforme' } 'WARN' { 'A verifier' } default { 'NON CONFORME' } }) | $(ConvertTo-MdCell $v.Detail) |")
        }
        $null = $sb.AppendLine('')
    }
    # Memes groupes et memes textes que la console (Show-NextSteps) : une section vide n'est pas ecrite
    $ns = Get-NextSteps
    foreach ($grp in @(@{ Key = 'Todo'; Title = 'A faire'; Note = 'actions a realiser par vous : l''outil ne les a pas executees' }, @{ Key = 'Check'; Title = 'A verifier'; Note = 'informations et controles que l''outil ne peut pas automatiser ni deviner' })) {
        $list = @($ns[$grp.Key])
        if ($list.Count -eq 0) { continue }
        $null = $sb.AppendLine("## $($grp.Title)")
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine("_$($grp.Note)_")
        $null = $sb.AppendLine('')
        $i = 0
        foreach ($s in $list) {
            $i++
            $null = $sb.AppendLine("$i. **$($s.Title)**" + $(if ($s.Text) { " - $($s.Text)" } else { '' }))
            foreach ($cmd in @($s.Command | Where-Object { $_ })) { $null = $sb.AppendLine("   - ``$cmd``") }
        }
        $null = $sb.AppendLine('')
    }
    $null = $sb.AppendLine('## Fichiers')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('- `run.log` : journal (aucun secret)')
    $null = $sb.AppendLine('- Ce rapport : aucun secret, aucun contenu de certificat')
    $null = $sb.AppendLine('- Aucun fichier de certificat, de mot de passe ou d''etat n''est ecrit : les identifiants generes sont restes en memoire et ont ete transmis directement a Cloudiway.')
    return $sb.ToString()
}

# ====================================================================================================
# Banniere et questions (mode interactif)
# ====================================================================================================
Initialize-UI
$interactive = Test-Interactive
Show-Banner -Simulation:$simulate -Discover:$Discover

if ($Discover -and $SkipCloudiway) {
    Write-Status FAIL 'Options incompatibles : -Discover et -SkipCloudiway.' 'Arret.'
    Stop-Run 1
}
if (-not $Discover) {
    # Normalisation des charges de travail (la forme "Mail,OneDrive" arrive en une seule chaine avec pwsh -File)
    $wlIn = @($Workloads | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })
    $wlNorm = [System.Collections.Generic.List[string]]::new()
    foreach ($w in $wlIn) {
        if ($w -ieq 'All' -or $w -ieq 'Tout') { foreach ($a in $AllWorkloads) { if (-not $wlNorm.Contains($a)) { $wlNorm.Add($a) } }; continue }
        $hit = $AllWorkloads | Where-Object { $_ -ieq $w } | Select-Object -First 1
        if (-not $hit -and @($script:UnavailableWorkloadNames | Where-Object { $_ -ieq $w }).Count -gt 0) {
            Write-Status FAIL "Charge de travail non disponible dans cette version : '$w'." ("Disponibles : " + ($AllWorkloads -join ', ') + '. Aucune connexion n''a ete tentee.'); Stop-Run 1
        }
        if (-not $hit) { Write-Status FAIL "Charge de travail inconnue : '$w'." ("Valeurs possibles : " + ($AllWorkloads -join ', ') + ', All'); Stop-Run 1 }
        if (-not $wlNorm.Contains($hit)) { $wlNorm.Add($hit) }
    }
    $Workloads = @($AllWorkloads | Where-Object { $wlNorm.Contains($_) })
}
$prodIn = @($ProductIds | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })
$ProductIdList = @()
foreach ($p in $prodIn) {
    $n = 0
    if (-not [int]::TryParse($p, [ref]$n)) { Write-Status FAIL "Identifiant de produit non numerique : '$p'." '-ProductIds attend des entiers (ex. 5,6).'; Stop-Run 1 }
    $ProductIdList += $n
}
if ($Tenant) {
    $Tenant = $Tenant.Trim()
    if (-not (Get-TenantInputKind $Tenant)) {
        Write-Status FAIL "Valeur -Tenant non reconnue : '$Tenant'." 'Indiquer un domaine (xxxx.onmicrosoft.com) ou un identifiant GUID.'
        Stop-Run 1
    }
}

# -KeepCredentials et -RotateCredentials sont contradictoires (v2.3) : refus avant toute connexion.
if ($KeepCredentials -and $RotateCredentials) {
    Write-Status FAIL 'Options incompatibles : -KeepCredentials et -RotateCredentials.' '-KeepCredentials garde les identifiants actuels s''ils sont valides ; -RotateCredentials (comportement par defaut depuis la version 2.3) les renouvelle. Retirer l''une des deux options.'
    Stop-Run 1
}

# M4 : la partie locale du nom du compte de service (avec ou sans "@") commence TOUJOURS par "svc-ciw-" (adoption comprise) : jamais un utilisateur quelconque du tenant.
if ($ServiceAccountName) {
    $saLocal = $ServiceAccountName.Split('@')[0]
    if (-not $saLocal.StartsWith('svc-ciw-', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Status FAIL "-ServiceAccountName '$ServiceAccountName' refuse : la partie locale du nom doit commencer par 'svc-ciw-'." 'L''outil ne cree ni ne modifie un compte au nom quelconque, meme avec -AdoptExisting. Passer une partie locale du type svc-ciw-source-p1234, ou un UPN dont la partie locale commence par svc-ciw-.'
        Stop-Run 1
    }
}

$missing = [System.Collections.Generic.List[string]]::new()
if (-not $Discover) {
    if (-not $Tenant) { $missing.Add('-Tenant') }
    if (-not $Admin365) { $missing.Add('-Admin365') }
    if ($SkipCloudiway -and -not $ProjectId) { $missing.Add('-ProjectId') }
    # Aucune charge par defaut : sans console interactive, le choix doit etre explicite (un defaut cacherait la creation d'un compte de service
    # et l'attribution du role SharePoint Administrator).
    if (@($Workloads).Count -eq 0 -and -not $interactive) { $missing.Add('-Workloads (aucune charge par defaut : indiquer explicitement les charges, ex. -Workloads Mail,OneDrive)') }
}
if ($Discover -or -not $SkipCloudiway) {
    if (-not $CloudiwayPat -and -not $Cloudiway -and $interactive) { $missing.Add('-Cloudiway') }
    if (-not $CloudiwayPat -and -not $interactive) { $missing.Add('-CloudiwayPat (le mot de passe Cloudiway ne peut pas etre saisi sans console interactive)') }
}
# Console non interactive sans -Yes : la confirmation du plan serait impossible. Le manque est ajoute a LA MEME liste (un seul message,
# tous les parametres manquants d'un coup), avant l'etape 1 et toute fenetre de connexion.
if (-not $interactive -and -not $Yes -and -not $simulate -and -not $Discover) {
    $missing.Add('-Yes (la confirmation du plan est impossible sans console interactive ; ou -WhatIf pour une simulation)')
}
if ($missing.Count -gt 0 -and -not $interactive) {
    # Commande complete a relancer : les valeurs deja fournies sont reprises, les manquantes sont des modeles <...> a remplacer.
    $cmdParts = [System.Collections.Generic.List[string]]::new()
    $needPat = $false
    if ($Discover) { $cmdParts.Add('-Discover'); if ($ConnectorId) { $cmdParts.Add("-ConnectorId $ConnectorId") } }
    else {
        $cmdParts.Add('-Mode Source')
        $cmdParts.Add('-Tenant ' + $(if ($Tenant) { Format-QuotedArg $Tenant } else { '<contoso.onmicrosoft.com>' }))
        $cmdParts.Add('-Admin365 ' + $(if ($Admin365) { Format-QuotedArg $Admin365 } else { '<admin365@contoso.com>' }))
        $cmdParts.Add('-Workloads ' + $(if (@($Workloads).Count -gt 0) { (@($Workloads) | ForEach-Object { Format-QuotedArg $_ }) -join ',' } else { '<Mail,OneDrive>' }))
    }
    if ($SkipCloudiway) {
        $cmdParts.Add('-SkipCloudiway')
        if (-not $Discover) { $cmdParts.Add('-ProjectId ' + $(if ($ProjectId) { $ProjectId } else { '<12345>' })) }
    } else {
        if ($ProjectId) { $cmdParts.Add("-ProjectId $ProjectId") }
        $needPat = $true
        $cmdParts.Add('-CloudiwayPat $pat')
    }
    if ($PSBoundParameters.ContainsKey('AuthMethod')) { $cmdParts.Add("-AuthMethod $AuthMethod") }
    if ($PSBoundParameters.ContainsKey('ValidityDays')) { $cmdParts.Add("-ValidityDays $ValidityDays") }
    if ($KeepCredentials) { $cmdParts.Add('-KeepCredentials') }
    if ($AdoptExisting) { $cmdParts.Add('-AdoptExisting') }
    if (-not $Discover) { $cmdParts.Add($(if ($simulate) { '-WhatIf' } else { '-Yes' })) }
    Write-Status FAIL ("Parametres manquants (console non interactive) : {0}" -f ($missing -join ' ; ')) 'Console sans possibilite de poser des questions : tous les parametres indispensables doivent etre fournis. Arret avant toute connexion.'
    Write-Hint 'Commande complete a relancer (remplacer les valeurs entre < >) ; ou lancer l''outil depuis une console interactive, qui pose les questions une par une :'
    if ($needPat) { Write-Command '$pat = Read-Host -AsSecureString "PAT Cloudiway (portail : ACCOUNT > Security > NEW TOKEN)"' }
    Write-Command ('./cloudiway-connector.ps1 ' + ($cmdParts -join ' '))
    Stop-Run 1
}

$askedAny = ($missing.Count -gt 0)
if ($interactive -and ($missing.Count -gt 0 -or (-not $Yes -and -not $Discover -and @($Workloads).Count -eq 0))) {
    Write-UIText '  Quelques questions pour preparer la configuration. Les valeurs entre crochets sont proposees : Entree pour les accepter.' 'Gray'
}

$mailRx = { param($v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' }
if (-not $Discover) {
    if (-not $Tenant) {
        Write-UIText '' ''
        Write-UIText '  Indiquer le domaine du tenant (xxxx.onmicrosoft.com, visible dans le centre d''administration Microsoft 365 > Parametres > Domaines) ou son identifiant GUID.' 'DarkGray'
        $Tenant = Read-Text 'Tenant du client (domaine .onmicrosoft.com ou GUID ; exemple : contoso.onmicrosoft.com)' -Validate { param($v) [bool](Get-TenantInputKind $v) } -ErrorText 'Saisie non valide : un domaine (exemple : contoso.onmicrosoft.com) ou un GUID est attendu. Nouvelle question.'
    }
    if (-not $Admin365) {
        Write-UIText '' ''
        Write-UIText '  Le compte Administrateur general Microsoft 365 qui va se connecter. S''il est different dans la fenetre de connexion, l''outil s''arrete.' 'DarkGray'
        $Admin365 = Read-Text 'Compte administrateur Microsoft 365 (ex. admin365@contoso.com)' -Validate $mailRx -ErrorText 'Saisie non valide : adresse de connexion attendue (exemple : admin365@contoso.com). Nouvelle question.'
    }
    if (@($Workloads).Count -eq 0) {
        # AUCUNE valeur pre-cochee : Entree seule est refusee, chaque charge nomme les privileges qu'elle ajoute.
        Write-UIText '' ''
        Write-UIText '  Chaque charge ajoute des privileges dans votre tenant (detailles ci-dessous). Rien n''est pre-selectionne. SharePoint, Teams, Archive, GalSync, Intune, FreeBusy, Signature et MailRouting ne sont pas disponibles dans cette version.' 'Yellow'
        $Workloads = @(Read-MultiChoice 'Quelles charges de travail faut-il migrer ? (les permissions demandees en dependent)' $WorkloadInfo @())
        $askedAny = $true
    }
}
if ($Discover -or -not $SkipCloudiway) {
    if (-not $Cloudiway -and -not $CloudiwayPat) {
        Write-UIText '' ''
        Write-UIText '  Votre identifiant sur le portail Cloudiway : l''adresse e-mail de l''invitation que vous avez recue. Le mot de passe sera demande masque a l''etape suivante.' 'DarkGray'
        $Cloudiway = Read-Text 'Identifiant Cloudiway (adresse e-mail ; exemple : paul.bernard@contoso.com)' -Validate $mailRx -ErrorText 'Saisie non valide : adresse e-mail attendue (exemple : paul.bernard@contoso.com). Nouvelle question.'
    }
}
if ($SkipCloudiway -and -not $ProjectId -and -not $Discover) {
    $ProjectId = [int](Read-Text 'Numero du projet Cloudiway (sert a nommer les objets ; exemple : 12345)' -Validate { param($v) $v -match '^\d{1,9}$' -and [int]$v -gt 0 } -ErrorText 'Saisie non valide : un entier positif est attendu (exemple : 12345). Nouvelle question.')
}
if ($Tenant) { $Tenant = $Tenant.Trim() }
if ($Admin365) { $Admin365 = $Admin365.Trim() }
if ($Cloudiway) { $Cloudiway = $Cloudiway.Trim() }

# ====================================================================================================
# Contexte, dossier de sortie
# ====================================================================================================
# Le dossier de sortie ne contient que le rapport et le journal (aucun secret). Un dossier synchronise (OneDrive, Dropbox), Telechargements
# ou un partage reseau reste deconseille : avertissement, et repli sur un dossier local si -OutDir est absent.
$OutRisk = ''
$OutFallback = $false
if ($OutDir) {
    $OutBase = [System.IO.Path]::GetFullPath($OutDir, (Get-Location).ProviderPath)
    $OutRisk = Test-RiskyOutputFolder $OutBase
} else {
    $OutBase = Join-Path $PSScriptRoot 'connecteur-resultats'
    $OutRisk = Test-RiskyOutputFolder $OutBase
    if ($OutRisk) {
        $localRoot = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $localRoot) { $localRoot = Join-Path $HOME '.local/share' }
        $OutBase = Join-Path $localRoot 'CloudiwayConnector'
        $OutFallback = $true
        $OutRisk = Test-RiskyOutputFolder $OutBase
    }
}
$Stamp = Get-Date -Format 'yyyyMMdd-HHmm'
# Nom court provisoire (le vrai nom court vient du domaine par defaut du tenant, connu apres la connexion)
$EarlyShort = ''
if (-not $Discover -and $Tenant) {
    if ((Get-TenantInputKind $Tenant) -eq 'Domain' -and $Tenant.ToLowerInvariant().EndsWith('.onmicrosoft.com')) { $EarlyShort = Get-TenantShort $Tenant '' }
}
$ProvShort = if ($Discover) { 'decouverte' }
elseif ($EarlyShort) { $EarlyShort }
elseif ($Tenant -and (Get-TenantInputKind $Tenant) -eq 'Guid') { $Tenant.Substring(0, 8).ToLowerInvariant() }
elseif ($Tenant) { Get-TenantShort $Tenant 'tenant' }
else { 'tenant' }
$ModeTag = if ($Discover) { 'Discover' } else { $Mode }
$Out = Join-Path $OutBase ("{0}-{1}-{2}" -f $ProvShort, $ModeTag, $Stamp)

$script:Ctx = @{
    Tenant               = $Tenant            # tel que saisi (domaine ou GUID)
    TenantId             = $null              # GUID resolu (etape 1)
    Admin365             = $Admin365
    CloudiwayLogin       = $Cloudiway
    Mode                 = $Mode
    Workloads            = @($Workloads)
    Names                = $null              # { App; ServiceAccountLocal; ServiceAccountDisplay; Connector } (Get-CodedNames)
    AppName              = $null
    ServiceAccountName   = $null
    NeedServiceAccount   = $(if ($Discover) { $false } else { [bool](Test-NeedServiceAccount -Mode $Mode -Workloads $Workloads) })
    ProjectId            = $(if ($ProjectId) { $ProjectId } else { $null })
    ConnectorName        = $null
    AuthMethod           = $AuthMethod
    ValidityDays         = $ValidityDays
    RotateCredentials    = (-not [bool]$KeepCredentials)   # v2.3 : renouvellement a chaque execution par defaut ; -KeepCredentials = ancien comportement idempotent
    KeepCredentials      = [bool]$KeepCredentials
    AdoptExisting        = [bool]$AdoptExisting
    Out                  = $Out
    OutBase              = $OutBase
    WhatIf               = $simulate
    AllowEwsListCreation = [bool]$AllowEwsListCreation   # v2.2 : liste EwsAllowedAppIDs vide -> creation autorisee sans question
    Yes                  = [bool]$Yes
    DefaultDomain        = $null
    TenantShort          = $ProvShort         # prefixe complet du domaine .onmicrosoft.com (apres connexion)
    TenantName           = $null              # idem : valeur du champ TenantName du connecteur Cloudiway
    Plan                 = $script:Plan
    Results              = $script:Results
    Created              = @{}                # valeurs creees, jamais secretes (AppId, empreinte, UPN...)
    Credentials          = @{}                # identifiants generes EN MEMOIRE (Entra), vides en fin de run
    ExistingConnector    = $null              # lu par Initialize-CloudiwayConnectorState avant New-EntraPlan
    ConnectorAdoption    = $false             # vrai si le plan adopte un connecteur fait a la main (confirmation supplementaire)
    ServiceAccountResetPending = $false       # vrai si le mot de passe du compte sera reinitialise APRES l'ecriture du connecteur
    IsGlobalAdmin        = $false
    ProductIds           = @($ProductIdList)
    ProductMapFile       = $ProductMapFile
    Region               = $Region
    CertificateTransport = $CertificateTransport
    SkipCloudiway        = [bool]$SkipCloudiway
    Discover             = [bool]$Discover
    ConnectorId          = $(if ($ConnectorId) { $ConnectorId } else { $null })
    ConnectorWriteOk     = $false             # vrai quand le connecteur Cloudiway a ete ecrit avec succes dans CE passage (condition du nettoyage)
}

# Exchange Online (v2.2) : etat de l'etape EWS (charges Mail / Archive seulement)
Reset-ExoState
$script:Exo.Needed = ((-not $Discover) -and (Test-ExchangeNeeded $Workloads))

# Produits Cloudiway inconnus : avertir des le recapitulatif (le cote tenant reste applique, le cote Cloudiway sera BLOQUE)
$unknownProducts = @()
if (-not $Discover -and -not $SkipCloudiway) {
    try {
        $gp = @{ Workloads = $Workloads }
        if ($ProductIdList.Count -gt 0) { $gp['Override'] = [int[]]$ProductIdList }
        if ($ProductMapFile) { $gp['MapFile'] = $ProductMapFile }
        $prod = Get-ProductIds @gp
        $unknownProducts = @($prod.Unknown | Where-Object { $_ })
    } catch { $unknownProducts = @() }
    if ($unknownProducts.Count -gt 0) {
        # Le connecteur ne pourra pas etre declare : le module Entra ne genere alors aucun identifiant (il s'accumulerait a chaque relance).
        $script:Ctx.CloudiwayBlockReason = 'produit(s) Cloudiway inconnu(s) : ' + ($unknownProducts -join ', ')
    }
}

# --- Recapitulatif et confirmation ---
$recap = [System.Collections.Generic.List[object]]::new()
$projTxt = if ($ProjectId) { "$ProjectId" } else { 'detecte automatiquement a l''etape 2' }
if ($Discover) {
    $recap.Add(@('Mode', 'Decouverte (lecture seule du projet Cloudiway)'))
    $recap.Add(@('Compte Cloudiway', $(if ($Cloudiway) { $Cloudiway } else { '(jeton PAT)' })))
    $recap.Add(@('Projet Cloudiway', $projTxt))
    if ($ConnectorId) { $recap.Add(@('Connecteur a detailler', "$ConnectorId")) }
} else {
    $recap.Add(@('Role', (Get-ModeLabel $Mode)))
    $recap.Add(@('Tenant', $Tenant))
    $recap.Add(@('Compte administrateur', $Admin365))
    $recap.Add(@('Charges de travail', (@($Workloads) -join ', ')))
    $recap.Add(@('Compte de service', $(if ($script:Ctx.NeedServiceAccount) { 'sera cree (les charges choisies l''exigent)' } else { 'non necessaire pour ces charges' })))
    if ($script:Exo.Needed) { $recap.Add(@('Exchange Online (EWS)', $(if ($AllowEwsListCreation) { 'connexion Exchange avec le compte administrateur ; AppID ajoute a EwsAllowedAppIDs (creation d''une liste vide autorisee : -AllowEwsListCreation)' } else { 'connexion Exchange avec le compte administrateur ; AppID ajoute a EwsAllowedAppIDs (liste vide : confirmation separee)' }))) }
    if ($SkipCloudiway) {
        $recap.Add(@('Cloudiway', "ignore (-SkipCloudiway) : tenant seulement, projet $ProjectId. Aucun certificat ni secret n'est genere (aucun moyen de les transmettre)."))
    } else {
        $recap.Add(@('Compte Cloudiway', $(if ($Cloudiway) { "$Cloudiway (mot de passe demande masque a l'etape 2)" } else { 'jeton PAT fourni' })))
        $recap.Add(@('Projet Cloudiway', $projTxt))
        $recap.Add(@('Connecteur', ('nom codifie <tenant>-' + $Mode.ToLowerInvariant() + ' (affiche a l''etape 4)')))
    }
    $authTxt = switch ($AuthMethod) { 'Secret' { 'secret client' } 'Both' { 'certificat et secret client' } default { 'certificat' } }
    $recap.Add(@('Authentification', ("{0}, valable {1}{2}" -f $authTxt, (Format-Validity $ValidityDays), $(if ($KeepCredentials) { ', renouvellement seulement si necessaire (-KeepCredentials)' } else { ', renouvelee a chaque execution' }))))
    $recap.Add(@('Objets existants', $(if ($AdoptExisting) { 'adoption autorisee (-AdoptExisting)' } else { 'jamais modifies sans l''etiquette CloudiwayConnector' })))
    $recap.Add(@('Execution', $(if ($simulate) { 'SIMULATION (-WhatIf) : aucune ecriture' } else { 'application reelle apres confirmation du plan' })))
}
$recap.Add(@('Dossier du rapport', $OutBase))
Show-Recap @($recap)
if ($OutFallback) {
    Write-Status WARN 'Le dossier du script est synchronise ou partage : le rapport et le journal vont dans un dossier local.' $OutBase
}
if ($OutRisk) {
    Write-Status WARN ('Dossier de sortie a risque : ' + $OutRisk) 'Aucun secret n''est ecrit, mais le rapport contient des identifiants du tenant. Utiliser -OutDir vers un dossier local non synchronise.'
}
if ($unknownProducts.Count -gt 0) {
    Write-Status WARN ("Charge(s) sans produit Cloudiway connu : {0}" -f ($unknownProducts -join ', ')) 'Cote Cloudiway ces lignes seront BLOQUEES (le tenant est configure quand meme). Voir -Discover, -ProductIds ou -ProductMapFile.'
}
if ($askedAny -and -not $Yes) {
    if (-not (Confirm-Action 'Demarrer avec ces parametres ?' -DefaultYes)) {
        Write-Status INFO 'Annule : rien n''a ete fait.'
        Stop-Run 1
    }
}

$total = if ($Discover) { 3 } else { 7 }

# Tout ce qui suit est protege : en cas d'erreur, de sortie anticipee ou de Ctrl+C, les identifiants detenus en memoire sont effaces.
try {

# ====================================================================================================
# [1] Prerequis du poste
# ====================================================================================================
Write-Section 1 $total 'Prerequis du poste'
$pf = Invoke-LocalPreflight -NeedGraph:(-not $Discover) -NeedExchange:([bool]$script:Exo.Needed) -SkipCloudiway:$SkipCloudiway -InstallMissingModules:$InstallMissingModules -OutBase $OutBase -Tenant $(if ($Discover) { '' } else { $Tenant }) -Admin365 $(if ($Discover) { '' } else { $Admin365 }) -CloudiwayLogin $(if ($SkipCloudiway) { '' } else { $Cloudiway })
Write-CheckTable $pf.Rows
foreach ($r in @($pf.Rows | Where-Object { $_.Status -in 'FAIL', 'WARN' -and $_.Impact })) { Write-Hint ("{0} : {1}" -f $r.Name, $r.Impact) }
if (-not $pf.Ok) {
    Write-Host ''
    Write-Status FAIL 'Des prerequis manquent : l''outil ne peut pas demarrer.' 'Aucune connexion n''a ete tentee.'
    $installCmds = @($pf.Rows | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
            if ("$($_.Impact) $($_.Detail)" -match 'Install-Module -Name \S+ -Scope (CurrentUser|AllUsers) -Force -AllowClobber') { $Matches[0] }
        } | Select-Object -Unique)
    if ($pf.NeedsAdmin) {
        Write-Status WARN 'Des droits administrateur du poste sont necessaires pour installer le module.'
        Write-Hint 'Ouvrir PowerShell 7 en tant qu''administrateur (clic droit, Executer en tant qu''administrateur), executer la commande ci-dessous, puis relancer l''outil :'
    } elseif ($installCmds.Count -gt 0) {
        Write-Hint 'Pour installer vous-meme (dans PowerShell 7, sans droits administrateur), puis relancer l''outil :'
    }
    foreach ($cmd in $installCmds) { Write-Command $cmd }
    Stop-Run 1
}
Write-Status OK 'Prerequis du poste valides.'
if ($script:Exo.Needed) {
    $exoRow = @($pf.Rows | Where-Object { $_.Name -eq "Module $($script:ExoModule)" } | Select-Object -First 1)
    $script:Exo.ModuleOk = ($exoRow.Count -gt 0 -and $exoRow[0] -and $exoRow[0].Status -eq 'OK')
    $script:Exo.ModuleDetail = $(if ($exoRow.Count -gt 0 -and $exoRow[0]) { [string]$exoRow[0].Detail } else { 'verification du module non effectuee' })
}
$TenantGuid = ''
if (-not $Discover) {
    $TenantGuid = [string]$pf.TenantId
    $script:Ctx.TenantId = $TenantGuid
}
try { New-Item -ItemType Directory -Force -Path $Out | Out-Null } catch { Write-Status FAIL "Impossible de creer '$Out'" $_.Exception.Message; Stop-Run 1 }
Write-RunLog ("Debut v{0}. Mode={1} Discover={2} Simulation={3} Workloads={4} SkipCloudiway={5} AuthMethod={6} ValidityDays={7} Keep={8}" -f $ScriptVersion, $Mode, [bool]$Discover, $simulate, (@($Workloads) -join ','), [bool]$SkipCloudiway, $AuthMethod, $ValidityDays, [bool]$KeepCredentials)
if ($OutFallback) { Write-RunLog ("Dossier de sortie replie sur un dossier local : {0}" -f $OutBase) }
if ($OutRisk) { Write-RunLog ("AVERTISSEMENT dossier de sortie a risque : {0}" -f $OutRisk) }
foreach ($r in $pf.Rows) { Write-RunLog ("PREREQ {0} : {1} {2}" -f $r.Name, $r.Status, $r.Detail) }

# ====================================================================================================
# [2] Acces au portail Cloudiway (arret avant toute ecriture tenant si KO)
# ====================================================================================================
Write-Section 2 $total 'Acces au portail Cloudiway'
if ($SkipCloudiway) {
    Write-Status SKIP 'Portail Cloudiway ignore (-SkipCloudiway).' 'seul le tenant sera configure'
    Write-Status WARN 'Aucun certificat ni secret ne sera genere avec -SkipCloudiway (ils ne pourraient pas etre transmis au connecteur).' 'Relancer sans -SkipCloudiway pour declarer le connecteur : les identifiants seront alors generes et envoyes.'
    Write-RunLog '-SkipCloudiway : aucun identifiant genere.'
    $script:Ctx.ProjectId = [int]$ProjectId
} else {
    if (-not $CloudiwayPat) {
        Write-UIText '' ''
        Write-UIText '  Connexion au portail Cloudiway avec VOTRE compte. Le mot de passe est saisi masque, utilise une seule fois puis efface : il n''est ni affiche, ni stocke, ni journalise.' 'DarkGray'
        Write-UIText '  Mot de passe pas encore initialise ? Utiliser le lien du mail d''invitation Cloudiway (voir le guide).' 'DarkGray'
        $script:CwPassword = Read-SecretText ("Mot de passe Cloudiway de {0} (saisie masquee)" -f $Cloudiway)
        if (-not $script:CwPassword) {
            Write-StatusLog FAIL 'Aucun mot de passe Cloudiway fourni.' 'Arret avant toute ecriture.'
            Stop-Run 1
        }
    }
    Write-StatusLog WAIT 'Connexion au portail Cloudiway.' $(if ($Cloudiway) { $Cloudiway } else { 'jeton PAT' })
    $cwRows = @()
    try {
        $ca = @{}
        if ($ProjectId) { $ca['ProjectId'] = [int]$ProjectId } elseif ($interactive) { $ca['Interactive'] = $true }   # plusieurs projets : choix guide
        if ($CloudiwayPat) { $ca['Pat'] = $CloudiwayPat } else { $ca['Login'] = $Cloudiway; $ca['Password'] = $script:CwPassword }
        $cwRows = @(Connect-CloudiwayApi @ca | Where-Object { $_ -and $_.PSObject.Properties['Status'] })
    } catch {
        $cwRows = @([pscustomobject]@{ Name = 'Connexion a l''API Cloudiway'; Status = 'FAIL'; Detail = (Get-ErrMsg $_); Impact = '' })
    }
    # Le mot de passe a servi : il est efface tout de suite
    try { if ($script:CwPassword) { $script:CwPassword.Dispose() } } catch { }
    $script:CwPassword = $null
    Write-CheckTable $cwRows
    foreach ($r in $cwRows) { Write-RunLog ("CLOUDIWAY {0} : {1} {2}" -f $r.Name, $r.Status, $r.Detail) }
    foreach ($r in @($cwRows | Where-Object { $_.Status -in 'FAIL', 'WARN' -and $_.Impact })) { Write-Hint ("{0} : {1}" -f $r.Name, $r.Impact) }
    if (@($cwRows | Where-Object { (Get-UILevel ([string]$_.Status)) -eq 'FAIL' }).Count -gt 0 -or $cwRows.Count -eq 0) {
        Write-Host ''
        Write-Status FAIL 'Acces au portail Cloudiway impossible.' 'Arret avant toute ecriture dans le tenant.'
        Write-Hint 'Verifier : l''identifiant et le mot de passe (mot de passe initialise via le mail d''invitation), que le compte est invite sur le projet avec le role Contributor, et le numero de projet si -ProjectId est utilise.'
        if (Test-CloudiwayTwoFactorSuspected) {
            # M5 : double authentification Cloudiway -> PAT (ACCOUNT > Security), commande copiable avec saisie masquee du PAT
            Write-Status WARN 'Double authentification (2FA) probable sur votre compte Cloudiway : la connexion par mot de passe ne donne pas de jeton.' 'utiliser un PAT'
            Write-Hint 'Dans le portail Cloudiway : ACCOUNT > Security > NEW TOKEN, copier le jeton, puis relancer avec -CloudiwayPat (le PAT est saisi masque, jamais ecrit). Commandes a copier :'
            Write-Command '$pat = Read-Host -AsSecureString "PAT Cloudiway"'
            $wlTxt = ((@($Workloads) | ForEach-Object { Format-QuotedArg $_ }) -join ',')
            if ($Discover) { Write-Command './cloudiway-connector.ps1 -Discover -CloudiwayPat $pat' }
            else { Write-Command ("./cloudiway-connector.ps1 -Mode Source -Tenant {0} -Admin365 {1} -Workloads {2} -CloudiwayPat `$pat" -f (Format-QuotedArg $Tenant), (Format-QuotedArg $Admin365), $wlTxt) }
        }
        Write-Hint 'Pour configurer le tenant sans Cloudiway : relancer avec -SkipCloudiway -ProjectId <numero>.'
        Stop-Run 1
    }
    Write-Status OK 'Connexion au portail Cloudiway validee.'

    # Projet : detection automatique (un seul projet visible : retenu ; plusieurs : choix ; aucun : arret)
    try {
        # Connect-CloudiwayApi a deja retenu le projet (et pose l'en-tete projectId) : on relit son nom avec l'identifiant retenu, sans nouvelle question.
        $pid2 = [int]$(if ($script:Ctx.ProjectId) { $script:Ctx.ProjectId } else { 0 })
        if ($pid2 -le 0 -and $ProjectId) { $pid2 = [int]$ProjectId }
        if ($pid2 -le 0) { throw 'aucun projet Cloudiway selectionne' }
        $sel = Select-CloudiwayProject -ProjectId $pid2
        if (-not $sel.Ok) { throw $sel.Message }
        $ProjectId = $pid2
        $script:Ctx.ProjectId = $pid2
        $projName = Get-SafeProp $sel 'name'; if (-not $projName) { $projName = Get-SafeProp $sel 'Name' }
        Write-StatusLog OK 'Projet Cloudiway retenu.' ("numero {0}{1}" -f $pid2, $(if ($projName) { " ($projName)" } else { '' }))
    } catch {
        Write-StatusLog FAIL 'Projet Cloudiway introuvable.' (Get-ErrMsg $_)
        Write-Hint 'Verifier que votre compte est bien invite sur un projet (role Contributor) ; en cas de plusieurs projets, passer -ProjectId <numero>.'
        Stop-Run 1
    }

    # Connecteur existant : possible des maintenant si le nom court du tenant est deja connu (domaine .onmicrosoft.com fourni)
    if ($Discover) {
        # rien d'autre a lire en decouverte
    } elseif ($EarlyShort) {
        try { Set-CodedNames $EarlyShort; Read-ExistingConnector }
        catch { Write-StatusLog FAIL 'Lecture du connecteur existant impossible.' (Get-ErrMsg $_); Stop-Run 1 }
    } else {
        Write-StatusLog INFO 'Connecteur existant : lecture apres la connexion au tenant' 'son nom depend du domaine .onmicrosoft.com, encore inconnu'
    }
}

# ====================================================================================================
# Mode -Discover : decouverte du projet, aucune connexion au tenant
# ====================================================================================================
if ($Discover) {
    Write-Section 3 $total 'Decouverte du projet Cloudiway (lecture seule)'
    $code = 0
    try {
        # Invoke-CloudiwayDiscover affiche lui-meme la liste des connecteurs (ou ecrit decouverte-<id>.json) et retourne les lignes / le chemin, ou $null.
        $da = @{}
        if ($ConnectorId) { $da['ConnectorId'] = $ConnectorId }
        $disc = Invoke-CloudiwayDiscover @da
        if ($ConnectorId -and -not $disc) { throw "connecteur $ConnectorId introuvable ou illisible (voir le message ci-dessus)" }
        Write-Status OK 'Decouverte terminee.' $Out
    } catch {
        $code = 1
        Write-StatusLog FAIL 'Decouverte impossible.' (Get-ErrMsg $_)
    }
    Show-FinalReport -Applied 0 -Failed $(if ($code) { 1 } else { 0 }) -Ignored 0 -Blocked 0 -Compliant 0 -NonCompliant 0 -Duration ((Get-Date) - $ScriptStart) -OutDir $Out -ReportPath '' -Simulation:$false
    Stop-Run $code
}

# ====================================================================================================
# [3] Connexion au tenant et controle des droits
# ====================================================================================================
Write-Section 3 $total 'Connexion au tenant et droits'
Write-StatusLog INFO 'Tenant a configurer' $(if ($Tenant -ieq $TenantGuid) { "GUID $TenantGuid" } else { "{0} (GUID {1})" -f $Tenant, $TenantGuid })
if ($UseDeviceCode) {
    Write-StatusLog WAIT 'Connexion Microsoft Graph par code d''appareil : un code va s''afficher, a saisir sur https://microsoft.com/devicelogin (fenetre de navigation privee conseillee).' "compte attendu : $Admin365"
} else {
    Write-StatusLog WAIT 'Connexion Microsoft Graph : une fenetre de connexion va s''ouvrir.' "compte attendu : $Admin365"
}
Write-Hint 'Se connecter avec le compte Administrateur general indique. Des permissions d''ecriture sont demandees : elles servent uniquement a creer l''application et ses droits.'
try {
    Import-Module Microsoft.Graph.Authentication -WarningAction SilentlyContinue -ErrorAction Stop
    # Depart propre : aucun contexte Graph herite d'un lancement precedent (autre tenant ou autre compte).
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    $connectParams = @{ TenantId = $TenantGuid; Scopes = $GraphScopes; ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
    # Le code d'appareil est ecrit par le module dans le flux d'information : ne PAS le masquer en mode -UseDeviceCode (sinon la connexion semble figee).
    if ($UseDeviceCode) { $connectParams['UseDeviceCode'] = $true; $InformationPreference = 'Continue' } else { $connectParams['WarningAction'] = 'SilentlyContinue'; $connectParams['InformationAction'] = 'SilentlyContinue' }
    if ($UseDeviceCode) {
        # Flux "code d'appareil" realise par l'outil (lib\graphauth.ps1) : il affiche lui-meme l'adresse et le code ; le jeton obtenu est
        # transmis a Graph. (Connect-MgGraph -UseDeviceCode n'affichait aucun code et ouvrait le navigateur par defaut : constate le 2026-10-31.)
        $dcToken = Get-DeviceCodeToken -TenantId $TenantGuid -Scopes $GraphScopes
        $script:DeviceClaims = ConvertFrom-JwtPayload $dcToken
        Connect-MgGraph -AccessToken (New-SecureStringFromText $dcToken) -NoWelcome -ErrorAction Stop | Out-Null
        $dcToken = $null
    } else {
        Connect-MgGraph @connectParams | Out-Null
    }
    $script:GraphConnected = $true
} catch {
    $gMsg = Get-ErrMsg $_
    Write-StatusLog FAIL 'Connexion Graph impossible.' $gMsg
    $gHint = Get-AadstsHint "$gMsg $($_.Exception.Message)"
    if ($gHint) { Write-Hint $gHint }
    if (-not $UseDeviceCode -and "$gMsg $($_.Exception.Message)" -match 'AADSTS(53003|50076|50058|50055|65001)|popup|browser|navigateur') { Write-Hint 'Si la fenetre de connexion pose probleme (mauvais compte repris, pas de navigateur), relancer avec -UseDeviceCode.' }
    if ($UseDeviceCode -and "$gMsg $($_.Exception.Message)" -match 'AADSTS(53003|50020|7000218|70002)|device') { Write-Hint 'Le flux par code d''appareil est peut-etre interdit par l''acces conditionnel de ce tenant : relancer sans -UseDeviceCode.' }
    Write-Host 'L''outil s''arrete : sans connexion au tenant rien ne peut etre configure.' -ForegroundColor Red
    Stop-Run 1
}
$mc = Get-MgContext
# Connexion par code d'appareil : le contexte du module ne porte pas toujours tenant et compte ; ils sont lus dans le jeton recu de Microsoft.
$ctxTenant = "$($mc.TenantId)"; $ctxAccount = "$($mc.Account)"; $haveCtx = [bool]$mc
if ($UseDeviceCode -and $script:DeviceClaims) { $ctxTenant = "$($script:DeviceClaims.tid)"; $ctxAccount = Get-JwtAccount $script:DeviceClaims; $haveCtx = $true }
$badTenant = (-not $haveCtx) -or ($ctxTenant.ToLowerInvariant() -ne $TenantGuid)
$badAccount = (-not $haveCtx) -or ($ctxAccount.ToLowerInvariant() -ne $Admin365.ToLowerInvariant())
if ($badTenant -or $badAccount) {
    $got = if ($haveCtx) { "tenant $ctxTenant, compte $ctxAccount" } else { 'aucun contexte' }
    Write-StatusLog FAIL 'Connexion refusee : le tenant ou le compte ne correspond pas.' "attendu tenant $TenantGuid et compte $Admin365 ; obtenu $got"
    Write-Host "Cause probable : compte different de celui demande, ou alias different de l'identifiant saisi (utiliser exactement l'identifiant de connexion du compte)." -ForegroundColor Yellow
    if ($haveCtx -and ("$ctxAccount" -match '#EXT#' -or $Admin365 -match '#EXT#')) {
        Write-Host "Compte INVITE (B2B, identifiant contenant #EXT#) : l'invite doit etre Administrateur general DANS CE tenant, et -Admin365 doit etre son identifiant exact tel que ce tenant l'affiche (forme nom_contoso.com#EXT#@xxxx.onmicrosoft.com). Verifier dans Entra > Utilisateurs (utilisateur invite) et lancer l'outil dans le tenant du client, pas dans celui de 3SR." -ForegroundColor Yellow
    }
    Write-Host 'Relancer la commande et choisir, dans la fenetre de connexion, exactement le compte et le tenant demandes.' -ForegroundColor Yellow
    Stop-Run 1
}
Write-StatusLog OK 'Connecte.' ("tenant {0} | compte {1}" -f $ctxTenant, $ctxAccount)

try {
    $tc = Get-TenantContext
    if (-not $script:Ctx.DefaultDomain) {
        $dd = Get-SafeProp $tc 'DefaultDomain'
        if ($dd) { $script:Ctx.DefaultDomain = [string]$dd }
    }
    if (-not $script:Ctx.DefaultDomain) {
        $org = @(Invoke-GraphGet '/organization')[0]
        $init = @($org.verifiedDomains) | Where-Object { $_.isInitial } | Select-Object -First 1
        if ($init) { $script:Ctx.DefaultDomain = [string]$init.name }
    }
    if (-not $script:Ctx.DefaultDomain) { throw 'domaine .onmicrosoft.com par defaut introuvable dans /organization' }
} catch {
    Write-StatusLog FAIL 'Lecture de l''organisation impossible.' (Get-ErrMsg $_)
    Stop-Run 1
}
$short = Get-TenantShort $script:Ctx.DefaultDomain $TenantGuid.Substring(0, 8)
$script:Ctx.TenantShort = $short
$script:Ctx.TenantName = ([string]$script:Ctx.DefaultDomain).Split('.')[0]   # valeur complete, jamais tronquee
Write-StatusLog INFO 'Domaine par defaut du tenant' ("{0} (nom court : {1})" -f $script:Ctx.DefaultDomain, $short)

# Noms codifies et connecteur existant (si l'etape 2 n'a pas pu les calculer faute de nom court)
try {
    $namesKnown = [bool]$script:Ctx.Names -and (-not $EarlyShort -or $EarlyShort -eq $short)
    if (-not $namesKnown) { Set-CodedNames $short }
    if (-not $SkipCloudiway -and -not ($EarlyShort -and $EarlyShort -eq $short)) { Read-ExistingConnector }
} catch {
    Write-StatusLog FAIL 'Calcul des noms ou lecture du connecteur existant impossible.' (Get-ErrMsg $_)
    Stop-Run 1
}

# Le dossier de sortie prend le vrai nom court du tenant
$finalOut = Join-Path $OutBase ("{0}-{1}-{2}" -f $short, $Mode, $Stamp)
if ($finalOut -ne $Out) {
    try {
        if (Test-Path -LiteralPath $finalOut) { $finalOut = $finalOut + '-' + (Get-Date -Format 'ss') }
        Rename-Item -LiteralPath $Out -NewName (Split-Path -Leaf $finalOut) -ErrorAction Stop
        $Out = $finalOut
        $script:Ctx.Out = $Out
    } catch {
        Write-Status WARN 'Dossier de sortie non renomme (nom provisoire conserve).' (Get-ErrMsg $_)
    }
}

Write-Host ''
Write-Host '  Controle des droits du compte :'
$rightRows = @()
try { $rightRows = @(Test-AdminRights | Where-Object { $_ -and $_.PSObject.Properties['Status'] }) }
catch { $rightRows = @([pscustomobject]@{ Name = 'Droits du compte'; Status = 'FAIL'; Detail = (Get-ErrMsg $_); Impact = 'Impossible de savoir ce que le compte peut faire : les actions seront probablement bloquees.' }) }
Write-CheckTable $rightRows
foreach ($r in $rightRows) { Write-RunLog ("DROITS {0} : {1} {2}" -f $r.Name, $r.Status, $r.Detail) }
foreach ($r in @($rightRows | Where-Object { $_.Status -in 'FAIL', 'WARN' -and $_.Impact })) { Write-Hint ("{0} : {1}" -f $r.Name, $r.Impact) }
if ($script:Ctx.IsGlobalAdmin) {
    Write-StatusLog OK 'Le compte est Administrateur general.'
} else {
    Write-StatusLog WARN 'Le compte n''est pas Administrateur general.' 'les actions qui l''exigent seront BLOQUEES dans le plan'
}

# Exchange Online (charges Mail / Archive) : connexion avec le meme compte, LECTURE SEULE de la configuration EWS avant le plan.
# Tout echec est non bloquant : l'etape devient un "A faire" manuel (jamais d'arret du reste de la configuration).
if ($script:Exo.Needed) {
    Write-Host ''
    Write-Host '  Exchange Online (charges Mail / Archive) :'
    foreach ($ln in @(Initialize-ExchangeState -Admin $Admin365 -TenantId $TenantGuid -UseDeviceCode:$UseDeviceCode)) { Write-StatusLog ([string]$ln.Level) ([string]$ln.Text) ([string]$ln.Detail) }
    if ($script:Exo.Read) { Write-RunLog ("EXO config EWS : EwsEnabled={0} liste={1} entree(s) ; {2}" -f $script:Exo.EwsEnabled, @($script:Exo.EwsList).Count, $script:Exo.Legacy) }
}

# ====================================================================================================
# [4] Inventaire (lecture seule) et plan
# ====================================================================================================
Write-Section 4 $total 'Inventaire et plan'
$script:Plan.Clear()
$script:Results.Clear()
$script:EntraState = $null
Show-CodedNames -Names $script:Ctx.Names -Mode $Mode -ProjectId ([string]$script:Ctx.ProjectId) -Domain ([string]$script:Ctx.DefaultDomain) -NeedServiceAccount ([bool]$script:Ctx.NeedServiceAccount) -ValidityDays $ValidityDays -AuthMethod $AuthMethod
Write-StatusLog WAIT 'Lecture de l''etat actuel du tenant (lecture seule).'
try {
    $script:EntraState = Get-EntraState
    New-EntraPlan -State $script:EntraState | Out-Null
} catch {
    Write-StatusLog FAIL 'Inventaire du tenant impossible.' (Get-ErrMsg $_)
    Stop-Run 1
}
if (-not $SkipCloudiway) {
    try { New-CloudiwayConnectorPlan | Out-Null }
    catch { Add-PlanItem 'Cloudiway' "Connecteur $($script:Ctx.ConnectorName)" 'BLOCKED' ("lecture du projet impossible : " + (Get-ErrMsg $_)) | Out-Null }
    # Zone Nettoyage (apres la zone Cloudiway) : anciens certificats / secrets de l'outil a retirer apres transmission du nouveau
    try { New-EntraCleanupPlan -State $script:EntraState }
    catch { Write-RunLog ("Plan de nettoyage impossible : " + (Get-ErrMsg $_)) }
}
Write-Host ''
Show-PlanTable $script:Plan
Write-Host ''

# ====================================================================================================
# [5] Confirmation puis application
# ====================================================================================================
$applied = 0; $failed = 0; $ignored = 0
Write-Section 5 $total 'Confirmation et application'
# Exchange : liste EwsAllowedAppIDs VIDE. La definir la rend RESTRICTIVE pour toutes les autres applications EWS du tenant : confirmation
# explicite SEPAREE (defaut NON), distincte de la confirmation globale. Refus = la ligne est IGNOREE (rien n'est ecrit), le reste continue.
foreach ($exIt in @($script:Plan | Where-Object { [string]$_.Area -eq 'Exchange' -and [string]$_.Action -eq 'UPDATE' -and $_.PSObject.Properties['NeedsConfirm'] })) {
    if ($simulate) {
        Write-StatusLog WARN 'EWS : EwsAllowedAppIDs est VIDE. Une confirmation explicite separee (defaut NON) serait demandee avant d''y inscrire l''AppID.' 'effet de bord : la liste deviendrait restrictive pour toutes les autres applications EWS du tenant'
        continue
    }
    Write-StatusLog WARN 'EWS : EwsAllowedAppIDs est VIDE sur ce tenant.' 'y inscrire l''AppID la rend RESTRICTIVE : toutes les autres applications EWS du tenant qui n''y figurent pas seront BLOQUEES'
    $okEws = $false
    if ($interactive -and -not $Yes) { $okEws = Confirm-Action 'Creer la liste EwsAllowedAppIDs avec cette seule application (les autres applications EWS du tenant seront bloquees) ?' }
    if ($okEws) {
        $script:Exo.CreateApproved = $true
        Write-RunLog 'EWS : creation de la liste vide CONFIRMEE'
    } else {
        $exIt.Action = 'SKIP'
        $exIt.Apply = $null
        $exIt.Reason = 'liste vide : creation non confirmee, rien n''est ecrit (voir A verifier)'
        $exApp = Get-AppIdText; if (-not $exApp) { $exApp = '<AppID>' }
        Add-ExoVerify 'Mail : EwsAllowedAppIDs est vide, AppID non inscrit' ("Creation de la liste non confirmee : l'outil n'a RIEN ecrit. Definir une liste vide la rend restrictive pour toutes les autres applications EWS du tenant. Decision de l'administrateur Exchange : inscrire aussi les autres applications utiles, ou relancer avec -AllowEwsListCreation. AppID : $exApp.") @('Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs', ('$ids = @((Get-OrganizationConfig).EwsAllowedAppIDs) + ''' + $exApp + ''''), 'Set-OrganizationConfig -EwsAllowedAppIDs (($ids | Where-Object { $_ } | Select-Object -Unique) -join '','')')
        Write-StatusLog INFO 'EWS : creation de la liste non confirmee, rien n''est ecrit.'
    }
}
$actionable = @($script:Plan | Where-Object { $_.Action -in 'CREATE', 'UPDATE' })
$blockedItems = @($script:Plan | Where-Object { $_.Action -eq 'BLOCKED' })
foreach ($b in $blockedItems) { Write-Hint ("BLOQUE - {0} : {1}" -f $b.Name, $b.Reason) }
# Lignes BLOQUE purement informatives (permission introuvable) : n'empechent pas les consentements des permissions resolues.
$infoBlocked = @($blockedItems | Where-Object { Test-InformativeBlock $_ })
if ($infoBlocked.Count -gt 0) {
    $script:PartialConsentNote = 'Consentement PARTIEL : ' + (($infoBlocked | ForEach-Object { [string]$_.Reason }) -join ' ; ') + ' Le consentement porte uniquement sur les permissions resolues dans ce tenant.'
    Write-StatusLog WARN 'Consentement partiel : certaines permissions n''existent pas dans ce tenant.' 'les consentements des permissions resolues seront appliques'
}

# Avertissements avant application (affiches aussi en simulation)
$cwActionable = @($actionable | Where-Object { [string]$_.Area -eq 'Cloudiway' })
if ($cwActionable.Count -gt 0 -and $script:Ctx.ExistingConnector -and $script:Ctx.CredentialsRotation) {
    Write-StatusLog WARN 'Un connecteur Cloudiway EXISTANT va etre mis a jour : ne pas relancer l''outil pendant que des jobs de migration sont actifs.' 'le certificat et le mot de passe du compte de service sont remplaces (chaque execution renouvelle les identifiants ; -KeepCredentials pour un simple controle). Des jobs en cours peuvent echouer : attendre leur fin (ou les suspendre dans le portail Cloudiway). La confirmation du plan vaut accord.'
}
if ($cwActionable.Count -gt 0 -and $script:Ctx.ConnectorAdoption) {
    Write-StatusLog WARN 'ADOPTION d''un connecteur fait a la main : son certificat, son RestClientId et le mot de passe de son compte de migration seront REMPLACES.' 'ce n''est PAS une simple reprise ; le connecteur actuel cessera de fonctionner avec ses anciens identifiants'
}

if ($simulate) {
    Write-StatusLog INFO ("Simulation (-WhatIf) : {0} action(s) seraient appliquees." -f $actionable.Count) 'aucune ecriture dans le tenant ni dans Cloudiway'
} elseif ($actionable.Count -eq 0) {
    if ($blockedItems.Count -gt 0) { Write-StatusLog WARN 'Aucune action applicable : les lignes bloquees demandent une decision ou des droits supplementaires.' }
    else { Write-StatusLog OK 'Rien a faire : tout est deja conforme.' }
} else {
    if ($Yes) {
        Write-StatusLog INFO 'Confirmation ignoree (-Yes).'
    } else {
        if (-not $interactive) {
            Write-StatusLog FAIL 'Confirmation impossible : console non interactive.' 'relancer avec -Yes pour appliquer sans question'
            Stop-Run 1
        }
        if ($cwActionable.Count -gt 0 -and $script:Ctx.ConnectorAdoption) {
            # B2 : confirmation SUPPLEMENTAIRE (reponse par defaut : non) pour l'adoption d'un connecteur fait a la main
            if (-not (Confirm-Action 'ADOPTION : le certificat, le RestClientId et le mot de passe du compte de migration du connecteur existant seront REMPLACES. Confirmer l''adoption ?')) {
                Write-StatusLog INFO 'Adoption non confirmee : rien n''a ete modifie.'
                Stop-Run 1
            }
        }
        if (-not (Confirm-Action ("Appliquer ces {0} modification(s) au tenant {1} ?" -f $actionable.Count, $script:Ctx.DefaultDomain))) {
            Write-StatusLog INFO 'Annule : rien n''a ete modifie.'
            Stop-Run 1
        }
    }
    # M3 : session Microsoft Graph verifiee JUSTE AVANT la premiere ecriture (la confirmation a pu durer longtemps). Jeton de code d'appareil :
    # claim exp lu dans le jeton, refus s'il reste moins de 15 minutes ; toute connexion : un GET /organization (lecture seule) doit reussir.
    $graphExpMsg = 'session Graph expiree ou presque : relancer l''outil (aucune modification n''a ete faite)'
    if ($UseDeviceCode -and $script:DeviceClaims) {
        $gExp = Get-JwtExpiry $script:DeviceClaims
        if ($gExp) {
            $gLeft = $gExp - [datetime]::UtcNow
            if ($gLeft.TotalMinutes -lt 15) {
                Write-StatusLog FAIL 'Session Graph expiree ou presque : relancer.' ("le jeton de connexion par code d'appareil expire dans {0} min (15 min minimum exigees avant la premiere ecriture)" -f [Math]::Max(0, [int][Math]::Floor($gLeft.TotalMinutes)))
                Write-Hint 'Aucune modification n''a ete faite dans le tenant ni dans Cloudiway. Relancer l''outil (nouveau code d''appareil) et confirmer sans tarder.'
                Stop-Run 1
            }
        }
    }
    try { [void](Invoke-GraphGet '/organization') }
    catch {
        $gEm = Get-ErrMsg $_
        $gTxt = if ((Get-ErrCode $_) -eq 401 -or $gEm -match 'InvalidAuthenticationToken|expired|Lifetime') { 'Session Graph expiree ou presque : relancer.' } else { 'Session Graph non verifiable juste avant l''application : relancer.' }
        Write-StatusLog FAIL $gTxt $gEm
        Write-Hint 'Aucune modification n''a ete faite dans le tenant ni dans Cloudiway. Relancer l''outil (nouvelle connexion).'
        Stop-Run 1
    }
    Write-StatusLog OK 'Session Graph reverifiee avant la premiere ecriture.' 'lecture seule (GET /organization)'
    # M2 : le tenant ne doit pas etre modifie avant de savoir que la session Cloudiway est encore valide. Verification juste avant la
    # premiere ecriture (la confirmation a pu durer longtemps). Lecture seule : le droit d'ecriture (Contributor) ne peut pas etre sonde
    # sans effet de bord.
    if ($cwActionable.Count -gt 0) {
        $sess = Confirm-CloudiwaySession
        if (-not $sess.Ok) {
            Write-StatusLog FAIL 'Session Cloudiway invalide juste avant l''application.' $sess.Message
            Write-Hint 'Aucune modification n''a ete faite dans le tenant ni dans Cloudiway. Relancer l''outil (le mot de passe Cloudiway est redemande).'
            Stop-Run 1
        }
        Write-StatusLog OK 'Session Cloudiway reverifiee avant la premiere ecriture.' 'lecture seule ; le droit d''ecriture sera confirme par l''ecriture du connecteur'
    }
    # Dependances PAR LIGNE : $bad = lignes BLOQUE (non informatives), en echec ou ignorees. Une ligne ne s'execute pas si une ligne dont elle
    # depend (voir Get-FailedDependency) est dans $bad ; une ligne independante s'execute quand meme.
    $bad = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $blockedItems) { if (-not (Test-InformativeBlock $b)) { $bad.Add($b) } }
    $ordered = @($actionable | Sort-Object @{ Expression = { $i = [array]::IndexOf($AreaOrder, [string]$_.Area); if ($i -lt 0) { 99 } else { $i } } }, Id)
    foreach ($it in $ordered) {
        $area = [string]$it.Area
        $label = "{0} : {1}" -f (Get-ZoneLabel $area), $it.Name
        $style = (Get-ActionStyle ([string]$it.Action)).Label
        $depHits = @(Get-FailedDependency $it $bad)
        if ($depHits.Count -gt 0) {
            $ignored++
            $detail = 'depend d''une ligne en echec, ignoree ou bloquee : ' + ((@($depHits | ForEach-Object { '{0} ({1})' -f $_.Name, (Get-ZoneLabel ([string]$_.Area)) }) | Select-Object -Unique) -join ' ; ')
            $script:Results.Add([pscustomobject]@{ Id = $it.Id; Area = $area; Name = $it.Name; Action = $it.Action; Outcome = 'IGNORE'; Detail = $detail })
            $bad.Add($it)
            Write-StatusLog SKIP $label $detail
            continue
        }
        $outcome = 'APPLIQUE'; $detail = ''
        $script:EntraLastError = ''; $script:CiwLastError = ''; $script:EntraApplyNote = ''
        try {
            if ($null -eq $it.Apply) { throw 'aucune procedure d''application fournie pour cette action' }
            $applyOut = @(& $it.Apply)
            $okFlag = $true
            if ($applyOut.Count -gt 0 -and $applyOut[-1] -is [bool]) { $okFlag = [bool]$applyOut[-1] }
            if (-not $okFlag) { $outcome = 'ECHEC'; $detail = 'l''action a retourne un echec' }
        } catch {
            $outcome = 'ECHEC'; $detail = Get-ErrMsg $_
        }
        if ($outcome -eq 'ECHEC') {
            # Detail lisible : derniere erreur du module Entra, sinon du module Cloudiway, sinon le message generique
            if ($script:EntraLastError) { $detail = [string]$script:EntraLastError }
            elseif ($script:CiwLastError) { $detail = [string]$script:CiwLastError }
        }
        $script:Results.Add([pscustomobject]@{ Id = $it.Id; Area = $area; Name = $it.Name; Action = $it.Action; Outcome = $outcome; Detail = $detail })
        if ($outcome -eq 'APPLIQUE') {
            if ($script:EntraApplyNote) { $detail = [string]$script:EntraApplyNote }   # ex. cles retirees : keyId et empreinte (jamais de secret)
            $applied++
            Write-StatusLog OK $label "($style)"
        } else {
            $failed++
            $bad.Add($it)
            Write-StatusLog FAIL $label $detail
        }
    }
    if ($failed -gt 0 -or $ignored -gt 0) {
        Write-Hint 'Aucune perte definitive : relancer la meme commande, l''outil regenere ce qui manque (identifiants, connecteur) et ne refait que cela.'
    }
}

# Etape Exchange impossible (module absent, connexion ou lecture en echec) : etape manuelle, comptee comme ignoree (code de sortie 2)
if ($script:Exo -and $script:Exo.PlanFailure) { $ignored++ }

# ====================================================================================================
# [6] Verification (relecture de chaque objet)
# ====================================================================================================
Write-Section 6 $total 'Verification'
$verif = [System.Collections.Generic.List[object]]::new()
if ($simulate) {
    Write-Status SKIP 'Simulation : verification non executee (rien n''a ete applique).'
} else {
    Write-StatusLog WAIT 'Relecture du tenant et du connecteur.'
    # Entra est coherent a terme : une lecture juste apres les ecritures peut ne pas encore montrer le consentement ou le certificat.
    # Releve jusqu'a 3 fois (attentes 6 s puis 12 s) tant que des lignes sont KO ; seul le dernier resultat est retenu.
    $entraRows = @()
    foreach ($wait in 0, 6, 12) {
        if ($wait -gt 0) { Start-Sleep -Seconds $wait; Write-RunLog ("Verification Entra : relecture apres {0} s (lignes KO possiblement dues a la propagation)" -f $wait) }
        try { $entraRows = @(Test-EntraCompliance | Where-Object { $_ -and $_.PSObject.Properties['Status'] }) }
        catch { $entraRows = @([pscustomobject]@{ Name = 'Verification du tenant'; Status = 'KO'; Detail = (Get-ErrMsg $_) }); break }
        if (@($entraRows | Where-Object { $_.Status -eq 'KO' }).Count -eq 0) { break }
    }
    foreach ($r in $entraRows) { $verif.Add($r) }
    try { foreach ($r in @(Test-ExchangeCompliance | Where-Object { $_ -and $_.PSObject.Properties['Status'] })) { $verif.Add($r) } }
    catch { $verif.Add([pscustomobject]@{ Name = 'Verification Exchange (EWS)'; Status = 'WARN'; Detail = (Get-ErrMsg $_) }) }
    Disconnect-Exchange
    if (-not $SkipCloudiway) {
        try { foreach ($r in @(Test-CloudiwayCompliance | Where-Object { $_ -and $_.PSObject.Properties['Status'] })) { $verif.Add($r) } }
        catch { $verif.Add([pscustomobject]@{ Name = 'Verification du connecteur Cloudiway'; Status = 'KO'; Detail = (Get-ErrMsg $_) }) }
    }
    Write-CheckTable @($verif)
    foreach ($r in $verif) { Write-RunLog ("VERIF {0} : {1} {2}" -f $r.Name, $r.Status, $r.Detail) }
}
$compliant = @($verif | Where-Object { (Get-UILevel ([string]$_.Status)) -eq 'OK' }).Count
$nonCompliant = @($verif | Where-Object { (Get-UILevel ([string]$_.Status)) -eq 'FAIL' }).Count
if (-not $simulate) {
    if ($nonCompliant -eq 0 -and $verif.Count -gt 0) { Write-StatusLog OK ("Tout est conforme ({0}/{0})." -f $compliant) }
    elseif ($nonCompliant -gt 0) { Write-StatusLog WARN ("{0} element(s) non conforme(s) sur {1}." -f $nonCompliant, ($compliant + $nonCompliant)) }
}

# ====================================================================================================
# [7] Rapport et journal (aucun secret)
# ====================================================================================================
Write-Section 7 $total 'Rapport et journal'
$counts = @{ Applied = $applied; Failed = $failed; Ignored = $ignored; Blocked = $blockedItems.Count; Compliant = $compliant; NonCompliant = $nonCompliant }

# Expiration reelle des identifiants du connecteur : lue AVANT l'effacement des secrets (information du groupe "A verifier")
Save-CredentialExpiry

# Informations a afficher dans les "prochaines actions" : capturees AVANT l'effacement de l'etat Cloudiway (notices non bloquantes,
# desynchronisation eventuelle du mot de passe du compte de service)
$script:FinalNotices = @(try { Get-CloudiwayNotices } catch { @() })
$script:FinalDesyncNotes = @($script:Results | Where-Object { [string]$_.Area -eq 'ServiceAccountPwd' -and [string]$_.Outcome -eq 'ECHEC' } | ForEach-Object { [string]$_.Detail })

# Les identifiants generes ne servent plus : effaces de la memoire AVANT d'ecrire le rapport
Clear-RunSecrets

$reportPath = Join-Path $Out ("Rapport-{0}-{1}.md" -f $short, $Mode)
try {
    Set-Content -LiteralPath $reportPath -Value (New-ReportMarkdown -PlanItems @($script:Plan) -ResultItems @($script:Results) -VerifRows @($verif) -IsSimulation $simulate -Counts $counts) -Encoding utf8BOM
    Write-StatusLog OK 'Rapport ecrit (sans secret).' $reportPath
} catch {
    Write-StatusLog FAIL 'Ecriture du rapport impossible.' (Get-ErrMsg $_)
    $reportPath = ''
}
Write-RunLog ("Fin. Appliques={0} Echecs={1} Ignores={2} Bloques={3} Conformes={4} NonConformes={5}" -f $applied, $failed, $ignored, $blockedItems.Count, $compliant, $nonCompliant)

Show-FinalReport -Applied $applied -Failed $failed -Ignored $ignored -Blocked $blockedItems.Count -Compliant $compliant -NonCompliant $nonCompliant -Duration ((Get-Date) - $ScriptStart) -OutDir $Out -ReportPath $reportPath -Simulation:$simulate
Show-NextSteps (Get-NextSteps)

# Code de sortie : 0 conforme ; 1 aucune ecriture et lignes bloquees ; 2 applique avec elements en echec / bloques / non conformes
$exitCode = 0
if (-not $simulate) {
    $dirty = ($failed -gt 0 -or $ignored -gt 0 -or $blockedItems.Count -gt 0 -or $nonCompliant -gt 0)
    if ($dirty) { $exitCode = if ((($applied + $failed) -eq 0) -and $blockedItems.Count -gt 0) { 1 } else { 2 } }
}
Stop-Run $exitCode

} finally {
    # Filet : erreur imprevue, sortie anticipee ou Ctrl+C -> sessions Exchange / Graph fermees, identifiants encore en memoire effaces
    try { Disconnect-Exchange } catch { }
    try { if ($script:GraphConnected) { Disconnect-MgGraph | Out-Null; $script:GraphConnected = $false } } catch { }
    Clear-RunSecrets
    try { Restore-ConsoleEncoding } catch { }
}
