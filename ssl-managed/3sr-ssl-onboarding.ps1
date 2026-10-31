<#
===============================================================================
 3SR - SSL MANAGED SOLUTION : préparation de votre environnement Azure
===============================================================================

 Ce script crée, dans VOTRE souscription Azure, les ressources nécessaires au
 service de gestion automatisée de vos certificats SSL :

   - un groupe de ressources
   - un compte de stockage + un conteneur « ssl » (liste de vos certificats)
   - un coffre de clés Key Vault (qui recevra les certificats émis)

 Il accorde ensuite à 3SR un accès strictement limité à ces ressources.

 CE QUE 3SR POURRA ET NE POURRA PAS FAIRE
   - lire la liste de vos certificats (lecture seule, sur le seul conteneur « ssl »)
   - créer et renouveler des certificats dans le coffre
   - AUCUNE extraction de clé privée, AUCUN accès à vos autres ressources

 RÉ-EXÉCUTABLE SANS RISQUE : ce qui existe déjà est réutilisé, jamais recréé.
 Aucune propriété d'une ressource préexistante n'est modifiée sans votre accord
 explicite.

-------------------------------------------------------------------------------
 PRÉREQUIS
-------------------------------------------------------------------------------
   - Azure CLI            https://aka.ms/installazurecli
   - PowerShell 5.1+ ou PowerShell 7
   - Être Propriétaire (Owner) de la souscription cible, ou disposer des droits
     de création de ressources ET d'attribution de rôles.

 LANCEMENT
   az login
   .\3sr-ssl-onboarding.ps1

 MODE SIMULATION (aucune modification)
   .\3sr-ssl-onboarding.ps1 -Simulation

 OPTION
   -RapportEmail <adresse> : adresse affichée comme destinataire du rapport en fin
        d'exécution. Facultatif : sans valeur, le rapport est à transmettre à
        votre contact 3SR.

 OPTIONS AVANCÉES (à n'utiliser que sur demande de 3SR)
   -AutoriserStorageExistant : autorise la réutilisation d'un compte de stockage
        qui n'a pas été créé par ce script. Ses propriétés de sécurité seront
        alors modifiées : à ne faire que si ce compte est dédié au service SSL.
   -AutoriserMigrationRbac   : autorise la bascule d'un coffre existant du modèle
        « stratégies d'accès » vers RBAC. ATTENTION : cela invalide les stratégies
        d'accès en place et peut couper les applications qui les utilisent.

 CODES DE RETOUR
   0 = succès       2 = succès avec avertissements       3 = contrôle critique en échec
   1 = erreur bloquante
===============================================================================
#>

#Requires -Version 5.1

param(
    [switch]$Simulation,
    [switch]$AutoriserStorageExistant,
    [switch]$AutoriserMigrationRbac,
    [string]$RapportEmail = ""
)

# ── Paramètres fixes ──────────────────────────────────────────────────────────
$ScriptVersion   = "2.1.0"
$Region          = "francecentral"
$RegionLabel     = "France Centre"
$SpnAppId        = "aa2e6eae-63e0-4180-96f9-35a6c59c706a"   # Application 3SR (identifiant public)
$ContainerName   = "ssl"
# Le nom du blob n'est PAS libre : l'automatisation 3SR lit un chemin precis,
# de la forme "ssl/<client>-ssl.json". On conserve donc le nom du fichier transmis
# par 3SR, apres controle de sa forme, plutot que d'imposer un nom arbitraire.
$MotifNomBlob    = '^[a-z0-9][a-z0-9-]{1,30}-ssl\.json$' 
# Destinataire affiché pour le rapport : paramètre facultatif -RapportEmail.
$DestinataireRapport = if ([string]::IsNullOrWhiteSpace($RapportEmail)) { "votre contact 3SR" } else { $RapportEmail }
$RoleKeyVault    = "Key Vault Certificates Officer"
$RoleStorageRead = "Storage Blob Data Reader"
$RoleStorageWrite= "Storage Blob Data Contributor"
# Rôle accordé au client uniquement. « Key Vault Certificates Officer » ne donne pas
# accès au secret sous-jacent d'un certificat (dataActions : certificates/* uniquement).
# Sans accès au secret, le client ne peut pas exporter le PFX de son propre certificat
# pour le déployer sur ses équipements : d'où ce rôle complémentaire.
$RoleKeyVaultSecret = "Key Vault Secrets User"
$TagMarqueur     = "3SR-SSL-Managed"

$ErrorActionPreference = "Stop"
$script:Warnings         = @()
$script:DerniereErreurAz = ""

# ── Affichage ─────────────────────────────────────────────────────────────────
function Write-Titre($Texte) {
    Write-Host ""
    Write-Host ("=" * 74) -ForegroundColor DarkCyan
    Write-Host "  $Texte" -ForegroundColor Cyan
    Write-Host ("=" * 74) -ForegroundColor DarkCyan
}
function Write-Etape($Texte)  { Write-Host "  > $Texte" -ForegroundColor Gray }
function Write-Ok($Texte)     { Write-Host "  [OK]    $Texte" -ForegroundColor Green }
function Write-Souci($Texte)  { Write-Host "  [!]     $Texte" -ForegroundColor Yellow; $script:Warnings += $Texte }
function Write-Erreur($Texte) { Write-Host "  [ERREUR] $Texte" -ForegroundColor Red }
function Write-Simu($Texte)   { Write-Host "  [SIMU]  $Texte" -ForegroundColor Magenta }

# ── Exécution Azure CLI ───────────────────────────────────────────────────────
function Invoke-Az {
    <# Renvoie l'objet JSON, une chaîne, $true, ou $null en cas d'échec.
       stderr est redirigé vers un fichier séparé et JAMAIS fusionné avec stdout :
       Azure CLI émet des avertissements sur stderr (dépréciations), et les fusionner
       corrompt le JSON : ConvertFrom-Json échoue alors silencieusement et la fonction
       renvoie une chaîne, d'où des propriétés vides en aval. #>
    param([string[]]$Arguments, [switch]$Silencieux)
    $fichierErreur = [System.IO.Path]::GetTempFileName()
    try {
        $sortie = & az @Arguments 2>$fichierErreur
        $codeRetour = $LASTEXITCODE
        $erreur = ""
        if (Test-Path $fichierErreur) { $erreur = (Get-Content $fichierErreur -Raw -ErrorAction SilentlyContinue) }
        if ($null -eq $erreur) { $erreur = "" }

        if ($codeRetour -ne 0) {
            $script:DerniereErreurAz = $erreur.Trim()
            if (-not $Silencieux) {
                Write-Erreur "Échec de : az $($Arguments -join ' ')"
                Write-Host "           $($erreur.Trim())" -ForegroundColor DarkRed
            }
            return $null
        }
        $script:DerniereErreurAz = ""
        $texte = ($sortie | Out-String).Trim()
        if (-not $texte) { return $true }
        try { return $texte | ConvertFrom-Json } catch { return $texte }
    }
    catch {
        $script:DerniereErreurAz = $_.Exception.Message
        if (-not $Silencieux) { Write-Erreur $_.Exception.Message }
        return $null
    }
    finally { Remove-Item $fichierErreur -Force -ErrorAction SilentlyContinue }
}

# ── Sélection interactive ─────────────────────────────────────────────────────
function Read-Selection {
    param([string]$Titre, [array]$Elements, [scriptblock]$Libelle)
    if ($Elements.Count -eq 0) { return $null }
    if ($Elements.Count -eq 1) {
        Write-Host ""
        Write-Host "  $Titre" -ForegroundColor White
        Write-Host "     Un seul choix disponible : $(& $Libelle $Elements[0])" -ForegroundColor Gray
        return $Elements[0]
    }
    $visibles = $Elements
    while ($true) {
        Write-Host ""
        Write-Host "  $Titre" -ForegroundColor White
        if ($visibles.Count -gt 15) {
            Write-Host "     $($visibles.Count) entrées disponibles." -ForegroundColor DarkGray
            $filtre = Read-Host "  Tapez une partie du nom pour filtrer (ou Entrée pour tout afficher)"
            if (-not [string]::IsNullOrWhiteSpace($filtre)) {
                $f = $filtre.Trim()
                $filtres = @($visibles | Where-Object { (& $Libelle $_) -like "*$f*" })
                if ($filtres.Count -eq 0) { Write-Souci "Aucune entrée ne correspond à « $f »." ; continue }
                $visibles = $filtres
                if ($visibles.Count -eq 1) {
                    Write-Host "     Une seule correspondance : $(& $Libelle $visibles[0])" -ForegroundColor Gray
                    return $visibles[0]
                }
                continue
            }
        }
        for ($i = 0; $i -lt $visibles.Count; $i++) {
            Write-Host ("     [{0}] {1}" -f ($i + 1), (& $Libelle $visibles[$i]))
        }
        Write-Host "     [0] Revenir à la liste complète / filtrer à nouveau" -ForegroundColor DarkGray
        $saisie = Read-Host "  Votre choix (1-$($visibles.Count))"
        $n = -1
        if ([int]::TryParse($saisie, [ref]$n)) {
            if ($n -eq 0) { $visibles = $Elements ; continue }
            if ($n -ge 1 -and $n -le $visibles.Count) { return $visibles[$n - 1] }
        }
        Write-Souci "Saisie invalide : indiquez un nombre entre 1 et $($visibles.Count)."
    }
}

# ── Validation de noms (fonctions pures, testables sans Azure) ────────────────
function Test-NomStorage {
    param([string]$Nom)
    # -cnotmatch (et non -notmatch) : les opérateurs de comparaison PowerShell sont
    # insensibles à la casse par défaut, et « stSSLmanaged » passerait alors le test
    # avant de se faire refuser par Azure.
    if ($Nom -cnotmatch '^[a-z0-9]{3,24}$') {
        return "Le nom doit contenir entre 3 et 24 caractères, uniquement des lettres minuscules et des chiffres (ni tiret, ni point, ni majuscule)."
    }
    return $null
}
function Test-NomKeyVault {
    param([string]$Nom)
    if ($Nom.Length -lt 3 -or $Nom.Length -gt 24) { return "Le nom doit contenir entre 3 et 24 caractères." }
    if ($Nom -notmatch '^[A-Za-z][A-Za-z0-9-]*$')  { return "Le nom doit commencer par une lettre et ne contenir que des lettres, chiffres et tirets." }
    if ($Nom.EndsWith('-'))                        { return "Le nom ne peut pas se terminer par un tiret." }
    if ($Nom -match '--')                          { return "Le nom ne peut pas contenir deux tirets consécutifs." }
    return $null
}
function Test-NomResourceGroup {
    param([string]$Nom)
    if ($Nom -notmatch '^[A-Za-z0-9._()-]{1,90}$') { return "Nom invalide (lettres, chiffres, point, tiret, souligné, parenthèses ; 90 caractères maximum)." }
    if ($Nom.EndsWith('.'))                        { return "Le nom ne peut pas se terminer par un point." }
    return $null
}

# ── Validation du fichier de configuration (fonction pure) ────────────────────
function Test-FichierSslList {
    <# Renvoie @{ Valide = $bool ; Message = "..." ; NbCertificats = n } #>
    param([string]$Contenu)
    if ([string]::IsNullOrWhiteSpace($Contenu)) {
        return @{ Valide = $false; Message = "Le fichier est vide."; NbCertificats = 0 }
    }
    try { $obj = $Contenu | ConvertFrom-Json -ErrorAction Stop }
    catch { return @{ Valide = $false; Message = "Le fichier n'est pas un JSON valide : $($_.Exception.Message)"; NbCertificats = 0 } }

    if ($null -eq $obj.ssl_list) {
        return @{ Valide = $false; Message = "Le fichier ne contient pas de propriété « ssl_list » à la racine."; NbCertificats = 0 }
    }
    $liste = @($obj.ssl_list)
    if ($liste.Count -eq 0) {
        return @{ Valide = $false; Message = "La liste « ssl_list » est vide."; NbCertificats = 0 }
    }
    $typesConnus = @("mono", "wildcard", "intranet")
    $i = 0
    $nbPlanifies = 0
    foreach ($entree in $liste) {
        $i++
        if ([string]::IsNullOrWhiteSpace($entree.cn)) {
            return @{ Valide = $false; Message = "Entrée n°$i : le champ « cn » est absent ou vide."; NbCertificats = 0 }
        }
        if ($entree.type -and ($entree.type -notin $typesConnus)) {
            return @{ Valide = $false; Message = "Entrée n°$i ($($entree.cn)) : type « $($entree.type) » inconnu (attendus : $($typesConnus -join ', '))."; NbCertificats = 0 }
        }
        # « create-after » diffère la première émission lors d'une reprise de parc.
        # Une date mal écrite doit être refusée ici : sinon elle ne se manifesterait
        # que le jour prévu de l'émission, par une absence de certificat.
        $planifie = $entree.'create-after'
        if (-not [string]::IsNullOrWhiteSpace($planifie)) {
            $d = [datetime]::MinValue
            $ok = [datetime]::TryParseExact([string]$planifie, 'yyyy-MM-dd',
                [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)
            if (-not $ok) {
                return @{ Valide = $false; Message = "Entrée n°$i ($($entree.cn)) : date « create-after » invalide (« $($planifie) »), format attendu AAAA-MM-JJ."; NbCertificats = 0 }
            }
            $nbPlanifies++
        }
    }
    $detail = if ($nbPlanifies -gt 0) { " dont $($nbPlanifies) à émission programmée" } else { "" }
    return @{ Valide = $true; Message = "$($liste.Count) certificat(s) déclaré(s)$($detail)."; NbCertificats = $liste.Count }
}

# ── État d'un nom de ressource ────────────────────────────────────────────────
# On interroge TOUJOURS l'existence réelle avant 'check-name' : 'az keyvault check-name'
# renvoie nameAvailable=true pour un coffre qui existe pourtant.
function Get-EtatNomStorage {
    param([string]$Nom, [string]$RgAttendu)
    $mien = Invoke-Az @("storage","account","show","--name",$Nom,"-o","json") -Silencieux
    if ($null -ne $mien) {
        return @{ Etat = "a-nous"; Objet = $mien; Rg = $mien.resourceGroup; Region = $mien.location;
                  Taggue = ($null -ne $mien.tags.$TagMarqueur) }
    }
    $r = Invoke-Az @("storage","account","check-name","--name",$Nom,"-o","json") -Silencieux
    if ($null -eq $r) { return @{ Etat = $null } }
    if ($r.nameAvailable) { return @{ Etat = "libre" } }
    return @{ Etat = "pris" }
}

function Get-EtatNomKeyVault {
    param([string]$Nom)
    $mien = Invoke-Az @("keyvault","show","--name",$Nom,"-o","json") -Silencieux
    if ($null -ne $mien) {
        return @{ Etat = "a-nous"; Objet = $mien; Rg = $mien.resourceGroup; Region = $mien.location;
                  Rbac = ($mien.properties.enableRbacAuthorization -eq $true);
                  Taggue = ($null -ne $mien.tags.$TagMarqueur) }
    }
    $efface = Invoke-Az @("keyvault","list-deleted","--query","[?name=='$Nom']","-o","json") -Silencieux
    if ($efface -and @($efface).Count -gt 0) { return @{ Etat = "supprime" } }
    $r = Invoke-Az @("keyvault","check-name","--name",$Nom,"-o","json") -Silencieux
    if ($null -eq $r) { return @{ Etat = $null } }
    if ($r.nameAvailable) { return @{ Etat = "libre" } }
    return @{ Etat = "pris" }
}

# ── Attribution de rôle ───────────────────────────────────────────────────────
function New-AttributionRole {
    <# Utilise --assignee-object-id + --assignee-principal-type : cela évite toute
       résolution d'annuaire côté client (un Owner n'est pas forcément lecteur de
       l'annuaire Entra, et --assignee échouerait alors de façon incompréhensible). #>
    param([string]$ObjectId, [string]$TypePrincipal, [string]$Role, [string]$Scope, [string]$Description)
    Write-Etape "Rôle « $Role » ($Description)"
    $existant = Invoke-Az @("role","assignment","list","--assignee",$ObjectId,"--role",$Role,"--scope",$Scope,"-o","json") -Silencieux
    if ($existant -and @($existant).Count -gt 0) { Write-Ok "Déjà en place." ; return $true }

    if ($Simulation) {
        Write-Simu "az role assignment create --assignee-object-id $ObjectId --assignee-principal-type $TypePrincipal --role `"$Role`" --scope $Scope"
        return $true
    }

    $tentatives = 4
    for ($essai = 1; $essai -le $tentatives; $essai++) {
        $r = Invoke-Az @("role","assignment","create","--assignee-object-id",$ObjectId,
            "--assignee-principal-type",$TypePrincipal,"--role",$Role,"--scope",$Scope,"-o","json") -Silencieux
        if ($null -ne $r) { Write-Ok "Attribué." ; return $true }
        $verif = Invoke-Az @("role","assignment","list","--assignee",$ObjectId,"--role",$Role,"--scope",$Scope,"-o","json") -Silencieux
        if ($verif -and @($verif).Count -gt 0) { Write-Ok "En place." ; return $true }
        if ($essai -lt $tentatives) {
            $attente = 8 * $essai
            Write-Host "          Échec temporaire, nouvelle tentative dans $attente s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $attente
        }
    }
    Write-Erreur "Impossible d'attribuer le rôle « $Role » après $tentatives tentatives."
    if ($script:DerniereErreurAz) {
        Write-Host "           Message renvoyé par Azure :" -ForegroundColor DarkRed
        foreach ($l in ($script:DerniereErreurAz -split "`n" | Select-Object -First 4)) {
            Write-Host "             $($l.Trim())" -ForegroundColor DarkRed
        }
    }
    if ($script:DerniereErreurAz -match "AuthorizationFailed|does not have authorization|Forbidden|privilege") {
        Write-Host "           Vos droits ne permettent pas d'attribuer des rôles : demandez à un" -ForegroundColor DarkRed
        Write-Host "           Propriétaire de la souscription d'exécuter ce script." -ForegroundColor DarkRed
    }
    return $false
}

# ── Contrôles de conformité (post-exécution) ──────────────────────────────────
$script:Controles = @()
function Add-Controle {
    param([string]$Libelle, [ValidateSet("PASS","WARN","FAIL")][string]$Etat, [string]$Detail, [switch]$Critique)
    $script:Controles += [PSCustomObject]@{ Libelle = $Libelle; Etat = $Etat; Detail = $Detail; Critique = [bool]$Critique }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  1. Contrôles préalables et choix de la cible
# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "3SR - SSL MANAGED SOLUTION : préparation de votre environnement Azure"
Write-Host "  Version du script : $ScriptVersion" -ForegroundColor DarkGray
if ($Simulation) {
    Write-Host ""
    Write-Host "  ***************************************************************" -ForegroundColor Magenta
    Write-Host "  *  MODE SIMULATION : aucune ressource créée ni modifiée        *" -ForegroundColor Magenta
    Write-Host "  ***************************************************************" -ForegroundColor Magenta
}
Write-Host "  Rien n'est créé avant votre validation explicite." -ForegroundColor DarkGray
Write-Host "  Ré-exécutable : ce qui existe déjà est réutilisé, jamais recréé." -ForegroundColor DarkGray

try { $null = Get-Command az -ErrorAction Stop }
catch {
    Write-Erreur "Azure CLI (az) est introuvable. Installez-le depuis https://aka.ms/installazurecli puis relancez."
    exit 1
}

Write-Titre "1. Connexion Azure"

$comptes = Invoke-Az @("account","list","--all","-o","json") -Silencieux
if ($null -eq $comptes -or @($comptes).Count -eq 0) {
    Write-Erreur "Aucune souscription accessible : vous n'êtes probablement pas connecté."
    Write-Host  "           Exécutez « az login » puis relancez ce script." -ForegroundColor DarkRed
    exit 1
}
$comptes = @($comptes) | Where-Object { $_.state -eq "Enabled" }
if ($comptes.Count -eq 0) { Write-Erreur "Aucune souscription active accessible." ; exit 1 }

$annuaireTenants = @{}
$listeTenants = Invoke-Az @("account","tenant","list","-o","json") -Silencieux
if ($listeTenants) {
    foreach ($t in @($listeTenants)) {
        $nom = $t.displayName
        if ([string]::IsNullOrWhiteSpace($nom)) { $nom = $t.defaultDomain }
        if (-not [string]::IsNullOrWhiteSpace($nom)) { $annuaireTenants[$t.tenantId] = $nom }
    }
}

$tenants = foreach ($g in ($comptes | Group-Object tenantId)) {
    $premier = $g.Group[0]
    $nomTenant = $annuaireTenants[$g.Name]
    if ([string]::IsNullOrWhiteSpace($nomTenant)) { $nomTenant = $premier.tenantDisplayName }
    if ([string]::IsNullOrWhiteSpace($nomTenant)) { $nomTenant = $premier.tenantDefaultDomain }
    # Dernier recours : le domaine du compte connecté. Certaines versions d'Azure CLI ne
    # renvoient aucun nom de locataire ; afficher le domaine reste plus parlant au client
    # qu'un GUID nu ou qu'un « nom non communiqué ».
    if ([string]::IsNullOrWhiteSpace($nomTenant) -and $premier.user.name -match '@(.+)$') { $nomTenant = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($nomTenant)) { $nomTenant = "(nom non communiqué)" }
    [PSCustomObject]@{ Id = $g.Name; Nom = $nomTenant; NbSubs = $g.Count }
}
$tenants = @($tenants | Sort-Object Nom)

$tenantChoisi = Read-Selection -Titre "Sélectionnez le locataire (tenant) Microsoft Entra :" -Elements $tenants -Libelle {
    param($t) "{0}   ({1})   {2} souscription(s)" -f $t.Nom, $t.Id, $t.NbSubs
}

$subsDuTenant = @($comptes | Where-Object { $_.tenantId -eq $tenantChoisi.Id } | Sort-Object name)
$subChoisie = Read-Selection -Titre "Sélectionnez la souscription dans laquelle créer les ressources :" -Elements $subsDuTenant -Libelle {
    param($s) "{0}   ({1})" -f $s.name, $s.id
}

Write-Etape "Activation de la souscription sélectionnée..."
$null = Invoke-Az @("account","set","--subscription",$subChoisie.id)
$compte = Invoke-Az @("account","show","-o","json")
if ($null -eq $compte) { Write-Erreur "Impossible d'activer cette souscription." ; exit 1 }

$TenantId       = $compte.tenantId
$SubscriptionId = $compte.id
$SubName        = $compte.name
$Utilisateur    = $compte.user.name

Write-Host ""
Write-Host "  Locataire      : $($tenantChoisi.Nom)  ($TenantId)"
Write-Host "  Souscription   : $SubName"
Write-Host "  Identifiant    : $SubscriptionId"
Write-Host "  Connecté en    : $Utilisateur"
Write-Host ""
Write-Host "  ATTENTION : les ressources seront créées dans CETTE souscription." -ForegroundColor Yellow
$ok = Read-Host "  Confirmez-vous ? (o/N)"
if ($ok -notmatch '^[oOyY]') { Write-Host "  Abandon, aucune ressource créée." -ForegroundColor Yellow ; exit 0 }

# ═══════════════════════════════════════════════════════════════════════════════
#  1 bis. Présence de l'application 3SR dans CE locataire
# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "1 bis. Vérification de l'application 3SR dans votre locataire"
Write-Etape "Recherche du principal de service $SpnAppId ..."

$spn = Invoke-Az @("ad","sp","show","--id",$SpnAppId,"-o","json") -Silencieux
$SpnObjectId = $null
if ($null -ne $spn -and -not [string]::IsNullOrWhiteSpace($spn.id)) {
    $SpnObjectId = $spn.id
    $spnNom = if ($spn.displayName) { $spn.displayName } else { "(sans nom)" }
    Write-Ok "Application 3SR présente : « $spnNom »"
    Write-Host "          Object ID dans votre locataire : $SpnObjectId" -ForegroundColor DarkGray
}
else {
    $urlConsentement = "https://login.microsoftonline.com/$TenantId/v2.0/adminconsent?client_id=$SpnAppId&redirect_uri=https://www.3sr.fr&scope=https://graph.microsoft.com/user.read"
    Write-Erreur "L'application 3SR n'est pas enregistrée dans votre locataire Microsoft Entra."
    Write-Host ""
    Write-Host "  Sans elle, aucun accès ne peut lui être accordé : le script s'arrête ici." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  DEUX CAUSES POSSIBLES :" -ForegroundColor White
    Write-Host ""
    Write-Host "  1. Le consentement administrateur n'a pas encore été donné." -ForegroundColor White
    Write-Host "     Un Administrateur général de votre locataire doit ouvrir ce lien une fois :" -ForegroundColor Gray
    Write-Host ""
    Write-Host "     $urlConsentement" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "     L'opération n'accorde aucun accès à vos ressources : elle ne fait" -ForegroundColor Gray
    Write-Host "     qu'enregistrer l'application 3SR dans votre annuaire. Les droits réels" -ForegroundColor Gray
    Write-Host "     sont attribués ensuite par ce script, et restent révocables." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Votre compte n'a pas le droit de lire l'annuaire Entra." -ForegroundColor White
    Write-Host "     L'application existe peut-être déjà, mais vous ne pouvez pas la voir." -ForegroundColor Gray
    Write-Host "     Demandez à un administrateur de vérifier, ou relancez avec un compte" -ForegroundColor Gray
    Write-Host "     disposant du rôle « Lecteurs d'annuaire »." -ForegroundColor Gray
    Write-Host ""
    if ($script:DerniereErreurAz) {
        Write-Host "  Message renvoyé par Azure :" -ForegroundColor DarkGray
        foreach ($l in ($script:DerniereErreurAz -split "`n" | Select-Object -First 3)) {
            Write-Host "    $($l.Trim())" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    exit 1
}

# Object ID de l'utilisateur courant (pour son rôle de dépôt)
$MonObjectId = $null
$moi = Invoke-Az @("ad","signed-in-user","show","--query","id","-o","tsv") -Silencieux
if ($moi -and "$moi".Trim()) { $MonObjectId = "$moi".Trim() }

# ═══════════════════════════════════════════════════════════════════════════════
#  2. Choix des noms
# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "2. Choix des noms de ressources"
Write-Host "  Entrée = accepter le nom proposé entre crochets."
Write-Host "  Région imposée : $RegionLabel ($Region)." -ForegroundColor DarkGray

$suffixe = -join ((48..57) + (97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ })

# --- Groupe de ressources ---
$NomRg = $null ; $RgExiste = $false
while ($null -eq $NomRg) {
    Write-Host ""
    $saisie = Read-Host "  Nom du groupe de ressources [RG-SSL-Managed]"
    if ([string]::IsNullOrWhiteSpace($saisie)) { $saisie = "RG-SSL-Managed" }
    $saisie = $saisie.Trim()
    $err = Test-NomResourceGroup $saisie
    if ($err) { Write-Souci $err ; continue }

    Write-Etape "Vérification de « $saisie »..."
    $existe = Invoke-Az @("group","exists","--name",$saisie,"-o","tsv") -Silencieux
    if ("$existe".Trim() -eq "true") {
        $rgInfo = Invoke-Az @("group","show","--name",$saisie,"-o","json") -Silencieux
        Write-Ok "Le groupe de ressources « $saisie » existe déjà : il sera réutilisé."
        if ($rgInfo -and $rgInfo.location -ne $Region) {
            Write-Souci "Il est déclaré en région « $($rgInfo.location) » et non « $Region ». Les ressources SSL seront tout de même créées en $RegionLabel."
        }
        $RgExiste = $true
    }
    else { Write-Ok "« $saisie » est disponible, il sera créé." }
    $NomRg = $saisie
}

# --- Compte de stockage ---
$NomStorage = $null ; $StorageExiste = $false ; $StorageObjet = $null
while ($null -eq $NomStorage) {
    Write-Host ""
    $defaut = "stsslmanaged$suffixe"
    $saisie = Read-Host "  Nom du compte de stockage (minuscules et chiffres) [$defaut]"
    if ([string]::IsNullOrWhiteSpace($saisie)) { $saisie = $defaut }
    $saisie = $saisie.Trim()
    $err = Test-NomStorage $saisie
    if ($err) { Write-Souci $err ; continue }

    Write-Etape "Vérification de « $saisie »..."
    $etat = Get-EtatNomStorage -Nom $saisie -RgAttendu $NomRg
    switch ($etat.Etat) {
        "libre"  { Write-Ok "« $saisie » est disponible, il sera créé." ; $NomStorage = $saisie }
        "pris"   { Write-Souci "« $saisie » est déjà utilisé ailleurs dans Azure (ces noms sont uniques au niveau mondial). Proposez-en un autre." }
        "a-nous" {
            # Le compte existe dans cette souscription : trois contrôles avant de l'accepter.
            if ($etat.Rg -ne $NomRg) {
                Write-Erreur "« $saisie » existe, mais dans le groupe de ressources « $($etat.Rg) » et non « $NomRg »."
                Write-Host "           Les ressources du service SSL doivent être regroupées dans le même" -ForegroundColor DarkRed
                Write-Host "           groupe de ressources. Choisissez un autre nom." -ForegroundColor DarkRed
            }
            elseif ($etat.Region -ne $Region) {
                Write-Erreur "« $saisie » existe, mais en région « $($etat.Region) » et non « $Region »."
                Write-Host "           Le service impose l'hébergement en $RegionLabel. Choisissez un autre nom." -ForegroundColor DarkRed
            }
            elseif (-not $etat.Taggue -and -not $AutoriserStorageExistant) {
                Write-Erreur "« $saisie » existe mais n'a pas été créé par ce script."
                Write-Host "           Il appartient probablement à une autre application. Le réutiliser" -ForegroundColor DarkRed
                Write-Host "           impliquerait de modifier ses propriétés de sécurité (désactivation de" -ForegroundColor DarkRed
                Write-Host "           l'accès par clé partagée), ce qui pourrait interrompre ses consommateurs." -ForegroundColor DarkRed
                Write-Host ""
                Write-Host "           Choisissez un nom dédié au service SSL. Si ce compte EST bien dédié" -ForegroundColor DarkRed
                Write-Host "           au service SSL, relancez avec -AutoriserStorageExistant." -ForegroundColor DarkRed
            }
            else {
                if (-not $etat.Taggue) {
                    Write-Souci "« $saisie » n'a pas été créé par ce script ; réutilisation forcée par -AutoriserStorageExistant."
                }
                Write-Ok "Le compte de stockage « $saisie » existe dans le bon groupe et la bonne région : il sera réutilisé."
                $NomStorage = $saisie ; $StorageExiste = $true ; $StorageObjet = $etat.Objet
            }
        }
        default {
            Write-Souci "Impossible de vérifier ce nom (réseau ou droits)."
            $f = Read-Host "  Conserver quand même ce nom ? (o/N)"
            if ($f -match '^[oOyY]') { $NomStorage = $saisie }
        }
    }
}

# --- Coffre de clés ---
$NomKeyVault = $null ; $KvExiste = $false ; $KvObjet = $null ; $KvMigrationRequise = $false
while ($null -eq $NomKeyVault) {
    Write-Host ""
    $defaut = "kv-sslmanaged-$suffixe"
    $saisie = Read-Host "  Nom du coffre de clés Key Vault [$defaut]"
    if ([string]::IsNullOrWhiteSpace($saisie)) { $saisie = $defaut }
    $saisie = $saisie.Trim()
    $err = Test-NomKeyVault $saisie
    if ($err) { Write-Souci $err ; continue }

    Write-Etape "Vérification de « $saisie »..."
    $etat = Get-EtatNomKeyVault -Nom $saisie
    switch ($etat.Etat) {
        "libre"    { Write-Ok "« $saisie » est disponible, il sera créé." ; $NomKeyVault = $saisie }
        "pris"     { Write-Souci "« $saisie » est déjà utilisé ailleurs dans Azure. Proposez-en un autre." }
        "supprime" { Write-Souci "Un coffre « $saisie » a été supprimé récemment et occupe encore ce nom (90 jours). Choisissez-en un autre, ou demandez à 3SR de vous aider à le restaurer." }
        "a-nous"   {
            if ($etat.Rg -ne $NomRg) {
                Write-Erreur "« $saisie » existe, mais dans le groupe de ressources « $($etat.Rg) » et non « $NomRg »."
                Write-Host "           Choisissez un autre nom." -ForegroundColor DarkRed
            }
            elseif ($etat.Region -ne $Region) {
                Write-Erreur "« $saisie » existe, mais en région « $($etat.Region) » et non « $Region »."
                Write-Host "           Le service impose l'hébergement en $RegionLabel." -ForegroundColor DarkRed
            }
            elseif (-not $etat.Rbac) {
                Write-Erreur "« $saisie » utilise le modèle « stratégies d'accès » et non Azure RBAC."
                Write-Host "           Le rôle dont 3SR a besoin ($RoleKeyVault) n'existe QUE dans le" -ForegroundColor DarkRed
                Write-Host "           modèle RBAC : en l'état, le service ne pourrait pas fonctionner." -ForegroundColor DarkRed
                Write-Host ""
                if ($AutoriserMigrationRbac) {
                    Write-Host "           -AutoriserMigrationRbac est actif." -ForegroundColor Yellow
                    Write-Host "           ATTENTION : basculer ce coffre en RBAC invalide TOUTES ses stratégies" -ForegroundColor Yellow
                    Write-Host "           d'accès actuelles et peut couper les applications qui les utilisent." -ForegroundColor Yellow
                    $c = Read-Host "  Tapez MIGRER pour confirmer la bascule de « $saisie » en RBAC"
                    if ($c.Trim().ToUpper() -eq "MIGRER") {
                        $NomKeyVault = $saisie ; $KvExiste = $true ; $KvObjet = $etat.Objet ; $KvMigrationRequise = $true
                        Write-Souci "Le coffre « $saisie » sera basculé en RBAC (stratégies d'accès invalidées)."
                    }
                    else { Write-Host "           Bascule refusée. Choisissez un autre nom." -ForegroundColor DarkRed }
                }
                else {
                    Write-Host "           Choisissez un autre nom (un coffre neuf sera créé en RBAC), ou," -ForegroundColor DarkRed
                    Write-Host "           en connaissance de cause, relancez avec -AutoriserMigrationRbac." -ForegroundColor DarkRed
                }
            }
            else {
                Write-Ok "Le coffre « $saisie » existe, en RBAC, dans le bon groupe et la bonne région : il sera réutilisé."
                $NomKeyVault = $saisie ; $KvExiste = $true ; $KvObjet = $etat.Objet
            }
        }
        default {
            Write-Souci "Impossible de vérifier ce nom (réseau ou droits)."
            $f = Read-Host "  Conserver quand même ce nom ? (o/N)"
            if ($f -match '^[oOyY]') { $NomKeyVault = $saisie }
        }
    }
}

# --- Fichier de configuration (facultatif, validé avant tout dépôt) ---
Write-Host ""
Write-Host "  3SR vous a transmis un fichier JSON listant vos certificats." -ForegroundColor DarkGray
Write-Host "  Vous pouvez le déposer maintenant, ou plus tard." -ForegroundColor DarkGray
$CheminJson = $null ; $NbCertificats = 0
while ($true) {
    $saisie = Read-Host "  Chemin du fichier JSON (laisser vide pour ignorer)"
    if ([string]::IsNullOrWhiteSpace($saisie)) { break }
    $chemin = $saisie.Trim().Trim('"')
    if (-not (Test-Path $chemin)) { Write-Souci "Fichier introuvable : $chemin" ; continue }
    $contenu = Get-Content $chemin -Raw -ErrorAction SilentlyContinue
    $verdict = Test-FichierSslList -Contenu $contenu
    if (-not $verdict.Valide) {
        Write-Erreur "Ce fichier ne peut pas être déposé : $($verdict.Message)"
        Write-Host "           Corrigez-le ou laissez vide pour le déposer plus tard." -ForegroundColor DarkRed
        continue
    }
    $nomFichier = (Split-Path $chemin -Leaf)
    if ($nomFichier -cnotmatch $MotifNomBlob) {
        Write-Erreur "Le nom du fichier « $($nomFichier) » ne correspond pas à celui attendu."
        Write-Host "           3SR vous a transmis un fichier nommé « <votre-code>-ssl.json »," -ForegroundColor DarkRed
        Write-Host "           par exemple « acme-ssl.json ». Ce nom n'est pas décoratif : c'est" -ForegroundColor DarkRed
        Write-Host "           celui que l'automatisation 3SR ira lire. Renommez le fichier tel" -ForegroundColor DarkRed
        Write-Host "           que 3SR vous l'a fourni, sans le modifier." -ForegroundColor DarkRed
        continue
    }
    Write-Ok "Fichier valide : $($verdict.Message)"
    $CheminJson = $chemin ; $NomBlobCanonique = $nomFichier ; $NbCertificats = $verdict.NbCertificats
    break
}
$NomBlob = if ($CheminJson) { $NomBlobCanonique } else { "<à déposer, sous le nom fourni par 3SR>" }

# ═══════════════════════════════════════════════════════════════════════════════
#  3. Récapitulatif et validation
# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "3. Récapitulatif à vérifier avant création"
function Etat($existe) { if ($existe) { "(existant, réutilisé)" } else { "(à créer)" } }

Write-Host ""
Write-Host "  CIBLE" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────────────────────────"
Write-Host "  Locataire              : $($tenantChoisi.Nom)"
Write-Host "  Souscription           : $SubName"
Write-Host "  Région                 : $RegionLabel ($Region)"
Write-Host ""
Write-Host "  RESSOURCES" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────────────────────────"
Write-Host "  Groupe de ressources   : $NomRg $(Etat $RgExiste)"
Write-Host "  Compte de stockage     : $NomStorage $(Etat $StorageExiste)"
Write-Host "     Conteneur           : $ContainerName"
Write-Host "     Fichier déposé      : $NomBlob$(if ($NbCertificats) { "  ($NbCertificats certificat(s))" })"
Write-Host "  Coffre de clés         : $NomKeyVault $(Etat $KvExiste)"
if ($KvMigrationRequise) {
    Write-Host "     ⚠ bascule en RBAC   : les stratégies d'accès actuelles seront invalidées" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  SÉCURITÉ" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────────────────────────"
Write-Host "  - Coffre en mode RBAC, suppression réversible 90 jours"
Write-Host "  - Stockage : clé partagée désactivée, HTTPS, TLS 1.2 minimum,"
Write-Host "    accès public anonyme interdit"
Write-Host "  - Authentification par identité uniquement : aucun secret n'est créé,"
Write-Host "    échangé ni stocké"
Write-Host ""
Write-Host "  ACCÈS ACCORDÉS À 3SR" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────────────────────────"
Write-Host "  Application 3SR : $SpnAppId"
Write-Host "  Object ID local : $SpnObjectId"
Write-Host "  - « $RoleKeyVault »"
Write-Host "      sur le coffre $NomKeyVault uniquement"
Write-Host "  - « $RoleStorageRead »"
Write-Host "      sur le conteneur « $ContainerName » uniquement, en LECTURE SEULE"
Write-Host ""
Write-Host "  3SR ne peut pas extraire vos clés privées, ne peut pas modifier votre" -ForegroundColor DarkGray
Write-Host "  liste, et n'a accès à aucune autre ressource. Ces accès sont révocables" -ForegroundColor DarkGray
Write-Host "  à tout moment par vos soins." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  VOS PROPRES ACCÈS" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────────────────────────────"
Write-Host "  - « $RoleStorageWrite »"
Write-Host "      sur le conteneur « $ContainerName », pour maintenir votre liste"
Write-Host "  - « $RoleKeyVault »"
Write-Host "      sur le coffre $NomKeyVault, pour gérer vos propres certificats"
Write-Host "  - « $RoleKeyVaultSecret »"
Write-Host "      sur le coffre $NomKeyVault, pour exporter vos certificats en PFX"
Write-Host ""
Write-Host "  En mode RBAC, être Propriétaire de l'abonnement ne donne pas accès au" -ForegroundColor DarkGray
Write-Host "  contenu du coffre : ces deux rôles vous sont donc attribués explicitement." -ForegroundColor DarkGray
Write-Host ""
if ($Simulation) { Write-Host "  MODE SIMULATION : rien ne sera créé." -ForegroundColor Magenta ; Write-Host "" }

$valider = Read-Host "  Confirmez-vous ? (tapez OUI)"
if ($valider.Trim().ToUpper() -ne "OUI") {
    Write-Host ""
    Write-Host "  Abandon. Aucune ressource n'a été créée ni modifiée." -ForegroundColor Yellow
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  4. Création
# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre $(if ($Simulation) { "4. Création des ressources (SIMULÉE)" } else { "4. Création des ressources" })

$ScopeRg        = "/subscriptions/$SubscriptionId/resourceGroups/$NomRg"
$ScopeStorage   = "$ScopeRg/providers/Microsoft.Storage/storageAccounts/$NomStorage"
$ScopeContainer = "$ScopeStorage/blobServices/default/containers/$ContainerName"
$ScopeKv        = "$ScopeRg/providers/Microsoft.KeyVault/vaults/$NomKeyVault"
$UriKv          = "https://$NomKeyVault.vault.azure.net/"
$TagsRessource  = @("$TagMarqueur=true")

# Vrai dès qu'un compte de stockage NEUF a été créé : garantit le durcissement en finally.
$script:StorageADurcir = $false

if ($Simulation) {
    Write-Simu "az group create --name $NomRg --location $Region"
    if (-not $StorageExiste) { Write-Simu "az storage account create --name $NomStorage --resource-group $NomRg --location $Region --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false" }
    Write-Simu "az storage container create --name $ContainerName --account-name $NomStorage"
    if ($CheminJson) { Write-Simu "az storage blob upload --name $NomBlobCanonique --file $CheminJson" }
    Write-Simu "az storage account update --allow-shared-key-access false"
    if (-not $KvExiste) { Write-Simu "az keyvault create --name $NomKeyVault --resource-group $NomRg --location $Region --enable-rbac-authorization true --retention-days 90" }
    if ($KvMigrationRequise) { Write-Simu "az keyvault update --name $NomKeyVault --enable-rbac-authorization true" }
}
else {
    try {
        # --- Groupe de ressources ---
        Write-Etape "Groupe de ressources « $NomRg »..."
        $argsRg = @("group","create","--name",$NomRg,"--location",$Region,"--tags") + $TagsRessource + @("-o","json")
        $rg = Invoke-Az $argsRg -Silencieux
        if ($null -eq $rg) {
            # Un groupe préexistant peut refuser l'écriture de tags (verrou, stratégie) : on réessaie sans.
            $rg = Invoke-Az @("group","create","--name",$NomRg,"--location",$Region,"-o","json")
        }
        if ($null -eq $rg) { Write-Erreur "Échec sur le groupe de ressources. Arrêt." ; exit 1 }
        Write-Ok "Groupe de ressources prêt."

        # --- Compte de stockage ---
        if ($StorageExiste) {
            Write-Etape "Compte de stockage « $NomStorage » existant, récupération..."
            $st = Invoke-Az @("storage","account","show","--name",$NomStorage,"-o","json")
        }
        else {
            Write-Etape "Création du compte de stockage « $NomStorage » (30 à 60 s)..."
            $argsSt = @("storage","account","create","--name",$NomStorage,"--resource-group",$NomRg,
                "--location",$Region,"--sku","Standard_LRS","--kind","StorageV2",
                "--min-tls-version","TLS1_2","--https-only","true",
                "--allow-blob-public-access","false","--tags") + $TagsRessource + @("-o","json")
            $st = Invoke-Az $argsSt
            if ($null -ne $st) { $script:StorageADurcir = $true }
        }
        if ($null -eq $st) { Write-Erreur "Échec sur le compte de stockage. Arrêt." ; exit 1 }
        Write-Ok "Compte de stockage prêt."
        if (-not [string]::IsNullOrWhiteSpace($st.id)) {
            $ScopeStorage   = $st.id
            $ScopeContainer = "$ScopeStorage/blobServices/default/containers/$ContainerName"
        }

        $cleActive = ($st.allowSharedKeyAccess -ne $false)

        # --- Conteneur + dépôt, puis durcissement IMMÉDIAT ---
        # Sur un compte neuf la clé partagée est encore active : on s'en sert pour ces
        # deux opérations (quelques secondes) puis on la désactive aussitôt. Le finally
        # garantit ce durcissement même si une erreur survient entre-temps.
        if ($cleActive) {
            Write-Etape "Conteneur « $ContainerName » (authentification : clé)..."
            $ct = Invoke-Az @("storage","container","create","--name",$ContainerName,
                "--account-name",$NomStorage,"--auth-mode","key","-o","json") -Silencieux
            if ($null -eq $ct) { Write-Souci "Conteneur non créé automatiquement, à contrôler dans le portail." }
            else { Write-Ok "Conteneur prêt." }

            if ($CheminJson) {
                Write-Etape "Dépôt du fichier sous le nom « $NomBlobCanonique »..."
                $up = Invoke-Az @("storage","blob","upload","--account-name",$NomStorage,
                    "--container-name",$ContainerName,"--name",$NomBlobCanonique,"--file",$CheminJson,
                    "--auth-mode","key","--overwrite","true","-o","json") -Silencieux
                if ($null -eq $up) { Write-Souci "Fichier non déposé, à déposer manuellement." }
                else { Write-Ok "Fichier déposé." }
            }
        }

        # --- Coffre de clés ---
        if ($KvExiste) {
            if ($KvMigrationRequise) {
                Write-Etape "Bascule du coffre « $NomKeyVault » en RBAC..."
                $mig = Invoke-Az @("keyvault","update","--name",$NomKeyVault,"--resource-group",$NomRg,
                    "--enable-rbac-authorization","true","-o","json") -Silencieux
                if ($null -eq $mig) { Write-Erreur "La bascule en RBAC a échoué. Arrêt." ; exit 1 }
                Write-Ok "Coffre basculé en RBAC."
            }
            Write-Etape "Coffre « $NomKeyVault » existant, récupération..."
            $kv = Invoke-Az @("keyvault","show","--name",$NomKeyVault,"-o","json")
        }
        else {
            Write-Etape "Création du coffre « $NomKeyVault » (30 à 60 s)..."
            $argsKv = @("keyvault","create","--name",$NomKeyVault,"--resource-group",$NomRg,
                "--location",$Region,"--enable-rbac-authorization","true","--retention-days","90","--tags") + $TagsRessource + @("-o","json")
            $kv = Invoke-Az $argsKv
        }
        if ($null -eq $kv) { Write-Erreur "Échec sur le coffre de clés. Arrêt." ; exit 1 }
        Write-Ok "Coffre de clés prêt."
        if (-not [string]::IsNullOrWhiteSpace($kv.id))                  { $ScopeKv = $kv.id }
        if (-not [string]::IsNullOrWhiteSpace($kv.properties.vaultUri)) { $UriKv   = $kv.properties.vaultUri }
    }
    finally {
        # GARANTIE : un compte de stockage créé par ce script ne reste jamais avec la clé
        # partagée active, quel que soit le chemin de sortie (erreur, exception, exit).
        if ($script:StorageADurcir) {
            Write-Etape "Désactivation de l'accès par clé partagée..."
            $hard = Invoke-Az @("storage","account","update","--name",$NomStorage,"--resource-group",$NomRg,
                "--allow-shared-key-access","false","-o","json") -Silencieux
            if ($null -eq $hard) { Write-Souci "Clé partagée NON désactivée. À faire manuellement, c'est important." }
            else { Write-Ok "Clé partagée désactivée : authentification par identité uniquement." ; $script:StorageADurcir = $false }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  5. Attribution des accès
# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "5. Attribution des accès"
Write-Host "  Portées minimales : le coffre, et le seul conteneur « $ContainerName »." -ForegroundColor DarkGray
Write-Host "  (les attributions déjà en place sont simplement confirmées)" -ForegroundColor DarkGray

$rolesOk = $true
$rolesOk = (New-AttributionRole -ObjectId $SpnObjectId -TypePrincipal "ServicePrincipal" -Role $RoleKeyVault `
    -Scope $ScopeKv -Description "3SR, sur le coffre") -and $rolesOk
$rolesOk = (New-AttributionRole -ObjectId $SpnObjectId -TypePrincipal "ServicePrincipal" -Role $RoleStorageRead `
    -Scope $ScopeContainer -Description "3SR, sur le conteneur (lecture seule)") -and $rolesOk

# Vos propres accès. En mode RBAC, être Propriétaire de l'abonnement ne donne AUCUN
# accès au contenu du coffre ni du stockage : ce sont deux plans distincts. Sans ces
# deux rôles, vous ne pourriez ni modifier votre liste, ni consulter ou déposer un
# certificat dans le coffre que vous venez pourtant de créer.
if ($MonObjectId) {
    $null = New-AttributionRole -ObjectId $MonObjectId -TypePrincipal "User" -Role $RoleStorageWrite `
        -Scope $ScopeContainer -Description "vous, pour mettre à jour la liste"
    $null = New-AttributionRole -ObjectId $MonObjectId -TypePrincipal "User" -Role $RoleKeyVault `
        -Scope $ScopeKv -Description "vous, pour gérer vos certificats dans le coffre"
    $null = New-AttributionRole -ObjectId $MonObjectId -TypePrincipal "User" -Role $RoleKeyVaultSecret `
        -Scope $ScopeKv -Description "vous, pour exporter vos certificats au format PFX"
}
else {
    Write-Souci "Votre compte n'a pas pu être identifié : attribuez-vous « $RoleStorageWrite » sur le conteneur, puis « $RoleKeyVault » et « $RoleKeyVaultSecret » sur le coffre."
}

# Compte préexistant dont la clé partagée est encore active : on ne touche RIEN sans accord.
if (-not $Simulation -and $StorageExiste -and ($StorageObjet.allowSharedKeyAccess -ne $false)) {
    Write-Host ""
    Write-Souci "Le compte de stockage « $NomStorage » autorise encore l'accès par clé partagée."
    Write-Host "          Le désactiver renforcerait la sécurité, mais couperait toute application" -ForegroundColor Yellow
    Write-Host "          qui l'utiliserait encore par clé. Ce compte n'ayant pas été créé par ce" -ForegroundColor Yellow
    Write-Host "          script, la décision vous revient." -ForegroundColor Yellow
    $rep = Read-Host "  Tapez DESACTIVER pour désactiver la clé partagée, ou Entrée pour la conserver"
    if ($rep.Trim().ToUpper() -eq "DESACTIVER") {
        $hard = Invoke-Az @("storage","account","update","--name",$NomStorage,"--resource-group",$NomRg,
            "--allow-shared-key-access","false","-o","json") -Silencieux
        if ($null -eq $hard) { Write-Souci "La désactivation a échoué." } else { Write-Ok "Clé partagée désactivée." }
    }
    else { Write-Souci "Clé partagée conservée active sur « $NomStorage » à votre demande." }
}

# Sur un compte préexistant déjà durci, le conteneur n'a pas encore été traité :
# on le fait maintenant, par identité, les rôles venant d'être attribués.
if (-not $Simulation -and $StorageExiste -and ($StorageObjet.allowSharedKeyAccess -eq $false)) {
    Write-Etape "Conteneur « $ContainerName » (authentification : identité)..."
    $okCt = $false
    for ($essai = 1; $essai -le 5; $essai++) {
        $ct = Invoke-Az @("storage","container","create","--name",$ContainerName,
            "--account-name",$NomStorage,"--auth-mode","login","-o","json") -Silencieux
        if ($null -ne $ct) { $okCt = $true ; break }
        if ($essai -lt 5) {
            Write-Host "          Propagation des droits en cours, nouvelle tentative dans 15 s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 15
        }
    }
    if ($okCt) { Write-Ok "Conteneur prêt." } else { Write-Souci "Conteneur non vérifié. La propagation des droits peut prendre quelques minutes ; relancez le script si besoin." }

    if ($CheminJson) {
        Write-Etape "Dépôt du fichier sous le nom « $NomBlobCanonique »..."
        $up = Invoke-Az @("storage","blob","upload","--account-name",$NomStorage,
            "--container-name",$ContainerName,"--name",$NomBlobCanonique,"--file",$CheminJson,
            "--auth-mode","login","--overwrite","true","-o","json") -Silencieux
        if ($null -eq $up) { Write-Souci "Fichier non déposé, relancez le script dans quelques minutes." }
        else { Write-Ok "Fichier déposé." }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  6. Contrôles de conformité : relecture de l'état réel dans Azure
# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "6. Contrôles de conformité"

if ($Simulation) {
    Write-Simu "Contrôles non exécutés en simulation (aucune ressource à relire)."
}
else {
    Write-Etape "Relecture de l'état réel des ressources dans Azure..."

    $rgReel = Invoke-Az @("group","show","--name",$NomRg,"-o","json") -Silencieux
    if ($rgReel) { Add-Controle "Groupe de ressources présent" "PASS" $NomRg }
    else         { Add-Controle "Groupe de ressources présent" "FAIL" "introuvable" -Critique }

    $stReel = Invoke-Az @("storage","account","show","--name",$NomStorage,"-o","json") -Silencieux
    if ($stReel) {
        Add-Controle "Compte de stockage présent" "PASS" $NomStorage
        if ($stReel.resourceGroup -eq $NomRg) { Add-Controle "Stockage dans le bon groupe" "PASS" $stReel.resourceGroup }
        else { Add-Controle "Stockage dans le bon groupe" "FAIL" "$($stReel.resourceGroup) au lieu de $NomRg" -Critique }

        if ($stReel.location -eq $Region) { Add-Controle "Stockage en $RegionLabel" "PASS" $stReel.location }
        else { Add-Controle "Stockage en $RegionLabel" "FAIL" $stReel.location -Critique }

        if ($stReel.allowSharedKeyAccess -eq $false) { Add-Controle "Clé partagée désactivée" "PASS" "allowSharedKeyAccess=false" }
        elseif ($StorageExiste)                      { Add-Controle "Clé partagée désactivée" "WARN" "conservée active sur un compte préexistant, à votre demande" }
        else                                         { Add-Controle "Clé partagée désactivée" "FAIL" "allowSharedKeyAccess=true sur un compte créé par ce script" -Critique }

        if ($stReel.enableHttpsTrafficOnly -eq $true) { Add-Controle "HTTPS obligatoire" "PASS" "" }
        else { Add-Controle "HTTPS obligatoire" "FAIL" "trafic HTTP autorisé" -Critique }

        if ($stReel.minimumTlsVersion -eq "TLS1_2" -or $stReel.minimumTlsVersion -eq "TLS1_3") { Add-Controle "TLS minimum" "PASS" $stReel.minimumTlsVersion }
        else { Add-Controle "TLS minimum" "WARN" "$($stReel.minimumTlsVersion)" }

        if ($stReel.allowBlobPublicAccess -eq $false) { Add-Controle "Accès public anonyme interdit" "PASS" "" }
        else { Add-Controle "Accès public anonyme interdit" "WARN" "allowBlobPublicAccess=true" }

        # Réseau : on constate, on ne modifie jamais.
        $pna = $stReel.publicNetworkAccess
        $defaultAction = $stReel.networkRuleSet.defaultAction
        if ($pna -eq "Disabled") {
            Add-Controle "Stockage joignable par 3SR" "FAIL" "accès public désactivé : l'automatisation 3SR ne pourra pas lire la liste" -Critique
        }
        elseif ($defaultAction -eq "Deny") {
            Add-Controle "Stockage joignable par 3SR" "WARN" "pare-feu actif (defaultAction=Deny) : les adresses de 3SR doivent être autorisées"
        }
        else { Add-Controle "Stockage joignable par 3SR" "PASS" "accès public autorisé" }

        $pe = Invoke-Az @("network","private-endpoint-connection","list","--id",$stReel.id,"-o","json") -Silencieux
        if ($pe -and @($pe).Count -gt 0) { Add-Controle "Points de terminaison privés (stockage)" "WARN" "$(@($pe).Count) détecté(s), à prendre en compte dans le routage" }
    }
    else { Add-Controle "Compte de stockage présent" "FAIL" "introuvable" -Critique }

    $kvReel = Invoke-Az @("keyvault","show","--name",$NomKeyVault,"-o","json") -Silencieux
    if ($kvReel) {
        Add-Controle "Coffre de clés présent" "PASS" $NomKeyVault
        if ($kvReel.resourceGroup -eq $NomRg) { Add-Controle "Coffre dans le bon groupe" "PASS" $kvReel.resourceGroup }
        else { Add-Controle "Coffre dans le bon groupe" "FAIL" "$($kvReel.resourceGroup) au lieu de $NomRg" -Critique }

        if ($kvReel.location -eq $Region) { Add-Controle "Coffre en $RegionLabel" "PASS" $kvReel.location }
        else { Add-Controle "Coffre en $RegionLabel" "FAIL" $kvReel.location -Critique }

        if ($kvReel.properties.enableRbacAuthorization -eq $true) { Add-Controle "Coffre en mode RBAC" "PASS" "" }
        else { Add-Controle "Coffre en mode RBAC" "FAIL" "stratégies d'accès : le rôle 3SR ne fonctionnera pas" -Critique }

        if ($kvReel.properties.enableSoftDelete -ne $false) { Add-Controle "Suppression réversible" "PASS" "$($kvReel.properties.softDeleteRetentionInDays) jours" }
        else { Add-Controle "Suppression réversible" "WARN" "désactivée" }

        if ($kvReel.properties.publicNetworkAccess -eq "Disabled") {
            Add-Controle "Coffre joignable par 3SR" "FAIL" "accès public désactivé : l'automatisation 3SR ne pourra pas déposer les certificats" -Critique
        }
        elseif ($kvReel.properties.networkAcls.defaultAction -eq "Deny") {
            Add-Controle "Coffre joignable par 3SR" "WARN" "pare-feu actif (defaultAction=Deny) : les adresses de 3SR doivent être autorisées"
        }
        else { Add-Controle "Coffre joignable par 3SR" "PASS" "accès public autorisé" }
    }
    else { Add-Controle "Coffre de clés présent" "FAIL" "introuvable" -Critique }

    # Conteneur et fichier.
    # Ces deux contrôles passent par le plan de données, avec les rôles attribués quelques
    # secondes plus tôt : la propagation RBAC n'est pas instantanée. On réessaie, et surtout
    # on distingue « la vérification a échoué » de « l'objet est absent » : les confondre
    # ferait annoncer « aucun fichier déposé » alors que le dépôt vient de réussir.
    $ctReel = $null
    for ($essai = 1; $essai -le 4; $essai++) {
        $ctReel = Invoke-Az @("storage","container","exists","--name",$ContainerName,"--account-name",$NomStorage,"--auth-mode","login","-o","json") -Silencieux
        if ($null -ne $ctReel) { break }
        if ($essai -lt 4) { Start-Sleep -Seconds 10 }
    }
    if ($null -eq $ctReel) {
        Add-Controle "Conteneur « $ContainerName » présent" "WARN" "non vérifiable propagation des droits en cours ; relancez le script dans quelques minutes"
    }
    elseif (-not $ctReel.exists) {
        Add-Controle "Conteneur « $ContainerName » présent" "FAIL" "absent" -Critique
    }
    else {
        Add-Controle "Conteneur « $ContainerName » présent" "PASS" ""
        $blobReel = $null
        for ($essai = 1; $essai -le 4; $essai++) {
            $nomAttendu = if ($NomBlobCanonique) { $NomBlobCanonique } else { "*-ssl.json" }
            $blobReel = Invoke-Az @("storage","blob","exists","--container-name",$ContainerName,"--name",$nomAttendu,"--account-name",$NomStorage,"--auth-mode","login","-o","json") -Silencieux
            if ($null -ne $blobReel) { break }
            if ($essai -lt 4) { Start-Sleep -Seconds 10 }
        }
        if ($null -eq $blobReel) {
            Add-Controle "Liste de certificats déposée" "WARN" "non vérifiable propagation des droits en cours ; relancez le script dans quelques minutes"
        }
        elseif ($blobReel.exists) {
            Add-Controle "Liste de certificats déposée" "PASS" $nomAttendu
        }
        elseif ($CheminJson) {
            Add-Controle "Liste de certificats déposée" "FAIL" "le dépôt était demandé mais le fichier est absent" -Critique
        }
        else {
            Add-Controle "Liste de certificats déposée" "WARN" "aucun fichier déposé à ce jour ; déposez le fichier fourni par 3SR dans le conteneur « $($ContainerName) », sans renommer"
        }
    }

    # Rôles : présence ET portée exacte
    $attributions = Invoke-Az @("role","assignment","list","--assignee",$SpnObjectId,"--all","-o","json") -Silencieux
    $attributions = @($attributions)
    $aKv = $attributions | Where-Object { $_.roleDefinitionName -eq $RoleKeyVault -and $_.scope -eq $ScopeKv }
    if ($aKv) { Add-Controle "Rôle 3SR sur le coffre" "PASS" "$RoleKeyVault, portée = le coffre" }
    else      { Add-Controle "Rôle 3SR sur le coffre" "FAIL" "absent à la portée attendue" -Critique }

    $aSt = $attributions | Where-Object { $_.roleDefinitionName -eq $RoleStorageRead -and $_.scope -eq $ScopeContainer }
    if ($aSt) { Add-Controle "Rôle 3SR sur le conteneur" "PASS" "$RoleStorageRead, portée = le conteneur" }
    else {
        $aStLarge = $attributions | Where-Object { $_.roleDefinitionName -eq $RoleStorageRead }
        if ($aStLarge) { Add-Controle "Rôle 3SR sur le conteneur" "WARN" "présent, mais à une portée plus large : $($aStLarge[0].scope)" }
        else           { Add-Controle "Rôle 3SR sur le conteneur" "FAIL" "absent" -Critique }
    }

    # Droits 3SR au-delà des deux rôles attendus. On sépare deux situations très
    # différentes : un droit supplémentaire SUR les ressources du service (anormal, il
    # sort du périmètre annoncé) et un droit AILLEURS dans la souscription (légitime si
    # 3SR y assure d'autres prestations, c'est au client d'en juger, avec la portée).
    $trop = @($attributions | Where-Object { $_.roleDefinitionName -notin @($RoleKeyVault, $RoleStorageRead) })
    $tropIci = @($trop | Where-Object { $_.scope -like "$ScopeRg*" })
    $tropAilleurs = @($trop | Where-Object { $_.scope -notlike "$ScopeRg*" })
    if ($tropIci.Count -gt 0) {
        $d = ($tropIci | ForEach-Object { "$($_.roleDefinitionName) sur $($_.scope)" }) -join " ; "
        Add-Controle "Aucun droit 3SR superflu sur ce service" "FAIL" $d -Critique
    }
    else { Add-Controle "Aucun droit 3SR superflu sur ce service" "PASS" "2 rôles, strictement" }
    if ($tropAilleurs.Count -gt 0) {
        $d = ($tropAilleurs | ForEach-Object { "$($_.roleDefinitionName) sur $($_.scope)" }) -join " ; "
        Add-Controle "Droits 3SR ailleurs dans la souscription" "WARN" "$($tropAilleurs.Count) attribution(s) hors périmètre du service SSL : $d"
    }

    if ($MonObjectId) {
        $aMoi = Invoke-Az @("role","assignment","list","--assignee",$MonObjectId,"--scope",$ScopeContainer,"--role",$RoleStorageWrite,"-o","json") -Silencieux
        if ($aMoi -and @($aMoi).Count -gt 0) { Add-Controle "Votre droit sur la liste" "PASS" "$RoleStorageWrite sur le conteneur" }
        else { Add-Controle "Votre droit sur la liste" "WARN" "absent : vous ne pourrez pas modifier la liste" }

        $aMoiKv = Invoke-Az @("role","assignment","list","--assignee",$MonObjectId,"--scope",$ScopeKv,"--role",$RoleKeyVault,"-o","json") -Silencieux
        if ($aMoiKv -and @($aMoiKv).Count -gt 0) { Add-Controle "Votre droit sur le coffre" "PASS" "$RoleKeyVault sur le coffre" }
        else { Add-Controle "Votre droit sur le coffre" "WARN" "absent : vous ne pourrez pas gérer vos certificats dans le coffre" }

        # Sans ce rôle, le portail Azure échoue sur « Download in PFX/PEM format » avec un
        # « Failed to dynamically fetch target download uri » qui ne dit pas sa vraie cause.
        $aMoiSec = Invoke-Az @("role","assignment","list","--assignee",$MonObjectId,"--scope",$ScopeKv,"--role",$RoleKeyVaultSecret,"-o","json") -Silencieux
        if ($aMoiSec -and @($aMoiSec).Count -gt 0) { Add-Controle "Votre droit d'export PFX" "PASS" "$RoleKeyVaultSecret sur le coffre" }
        else { Add-Controle "Votre droit d'export PFX" "WARN" "absent : le téléchargement au format PFX échouera dans le portail" }
    }

    foreach ($c in $script:Controles) {
        $couleur = switch ($c.Etat) { "PASS" { "Green" } "WARN" { "Yellow" } "FAIL" { "Red" } }
        $detail = if ($c.Detail) { " : $($c.Detail)" } else { "" }
        Write-Host ("  {0,-5} {1}{2}" -f $c.Etat, $c.Libelle, $detail) -ForegroundColor $couleur
    }
}

$nbFail     = @($script:Controles | Where-Object { $_.Etat -eq "FAIL" }).Count
$nbFailCrit = @($script:Controles | Where-Object { $_.Etat -eq "FAIL" -and $_.Critique }).Count
$nbWarn     = @($script:Controles | Where-Object { $_.Etat -eq "WARN" }).Count

# ═══════════════════════════════════════════════════════════════════════════════
#  7. Rapport
# ═══════════════════════════════════════════════════════════════════════════════

$horodatage = Get-Date -Format "yyyy-MM-dd HH:mm"
$empreinte = "(non calculée)"
try {
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        $empreinte = (Get-FileHash -Path $PSCommandPath -Algorithm SHA256).Hash
    }
} catch { }

$prefixe = if ($Simulation) { "simulation-" } else { "" }
$fichierRapport = Join-Path (Get-Location) ("3sr-ssl-onboarding-{0}{1}.txt" -f $prefixe, (Get-Date -Format "yyyyMMdd-HHmm"))

$entete = if ($Simulation) {
@"
 *** SIMULATION : AUCUNE RESSOURCE CRÉÉE NI MODIFIÉE ***
 *** Ce rapport n'est PAS à envoyer : il ne décrit rien d'existant. ***
"@
} else {
@"
 >>> MERCI D'ENVOYER CE RAPPORT PAR E-MAIL À : $DestinataireRapport
 >>>
 >>> Ce rapport ne contient aucun mot de passe, clé ni jeton d'authentification.
 >>> Il contient en revanche des informations techniques sur votre environnement
 >>> Azure : traitez-le comme un document interne.
"@
}

$lignesControles = if ($Simulation) { " (non exécutés en simulation)" } else {
    ($script:Controles | ForEach-Object {
        $d = if ($_.Detail) { " : $($_.Detail)" } else { "" }
        (" {0,-5} {1}{2}" -f $_.Etat, $_.Libelle, $d)
    }) -join "`r`n"
}

$rapport = @"
===============================================================================
 3SR - SSL MANAGED SOLUTION
 Rapport de configuration de l'environnement Azure
===============================================================================
 Généré le      : $horodatage
 Par            : $Utilisateur
 Script version : $ScriptVersion
 Empreinte SHA-256 du script exécuté :
   $empreinte

$entete

-------------------------------------------------------------------------------
 ENVIRONNEMENT
-------------------------------------------------------------------------------
 Locataire (nom)              : $($tenantChoisi.Nom)
 Locataire (Tenant ID)        : $TenantId
 Souscription (nom)           : $SubName
 Souscription (identifiant)   : $SubscriptionId
 Région                       : $RegionLabel ($Region)

-------------------------------------------------------------------------------
 RESSOURCES
-------------------------------------------------------------------------------
 Groupe de ressources         : $NomRg
 Compte de stockage           : $NomStorage
 Conteneur                    : $ContainerName
 Fichier de configuration     : $NomBlob
 Coffre de clés               : $NomKeyVault
 Adresse du coffre            : $UriKv

-------------------------------------------------------------------------------
 IDENTITÉ 3SR ET ACCÈS ACCORDÉS
-------------------------------------------------------------------------------
 Application (Client ID)      : $SpnAppId
 Object ID dans votre locataire : $SpnObjectId

 Rôle sur le coffre           : $RoleKeyVault
   portée                     : $ScopeKv
 Rôle sur le conteneur        : $RoleStorageRead (lecture seule)
   portée                     : $ScopeContainer

 Aucun autre droit n'est accordé à 3SR.

 Vos propres accès, attribués au compte $Utilisateur :
   $RoleStorageWrite sur le conteneur « $ContainerName »
   $RoleKeyVault sur le coffre $NomKeyVault
   $RoleKeyVaultSecret sur le coffre $NomKeyVault (export PFX)

-------------------------------------------------------------------------------
 CONTRÔLES DE CONFORMITÉ
-------------------------------------------------------------------------------
$lignesControles

 Bilan : $(@($script:Controles | Where-Object { $_.Etat -eq 'PASS' }).Count) PASS / $nbWarn WARN / $nbFail FAIL
===============================================================================
"@

try { $rapport | Out-File -FilePath $fichierRapport -Encoding UTF8 ; $rapportEcrit = $true }
catch { $rapportEcrit = $false }

Write-Titre $(if ($Simulation) { "7. Simulation terminée" } else { "7. Terminé" })
Write-Host $rapport
Write-Host ""
if ($rapportEcrit) { Write-Host "  Rapport enregistré : $fichierRapport" -ForegroundColor Green }
else { Write-Souci "Rapport non enregistré, copiez le texte ci-dessus." }
Write-Host ""

if ($Simulation) {
    Write-Host "  ***************************************************************" -ForegroundColor Magenta
    Write-Host "  *  SIMULATION terminée : rien n'a été créé ni modifié.        *" -ForegroundColor Magenta
    Write-Host "  *  Relancez sans -Simulation pour exécuter réellement.        *" -ForegroundColor Magenta
    Write-Host "  ***************************************************************" -ForegroundColor Magenta
    exit 0
}

if ($nbFailCrit -gt 0) {
    Write-Host "  ###############################################################" -ForegroundColor Red
    Write-Host "  #  $nbFailCrit contrôle(s) de sécurité CRITIQUE(S) en échec.               " -ForegroundColor Red
    Write-Host "  #  Transmettez ce rapport à 3SR : le service ne peut pas être  " -ForegroundColor Red
    Write-Host "  #  mis en service en l'état.                                   " -ForegroundColor Red
    Write-Host "  ###############################################################" -ForegroundColor Red
    exit 3
}

Write-Host "  ┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │  DERNIÈRE ÉTAPE : envoyez ce rapport par e-mail à 3SR        │" -ForegroundColor Cyan
Write-Host "  │  $($DestinataireRapport.PadRight(59))│" -ForegroundColor Cyan
Write-Host "  └─────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

if ($nbWarn -gt 0) { exit 2 }
exit 0
