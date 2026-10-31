<#
===============================================================================
 3SR - SSL MANAGED SOLUTION : révocation des accès accordés à 3SR
===============================================================================

 Ce script RETIRE les autorisations que vous aviez accordées à 3SR sur votre
 abonnement Azure. Il est le pendant de « 3sr-ssl-onboarding.ps1 ».

 CE QU'IL FAIT
   - recherche toutes les attributions de rôles dont l'application 3SR est
     bénéficiaire dans l'abonnement que vous désignez ;
   - vous les présente une par une ;
   - les supprime après votre confirmation explicite ;
   - produit un rapport de révocation.

 CE QU'IL NE FAIT PAS, JAMAIS
   - il ne SUPPRIME AUCUNE ressource : ni vos certificats, ni votre coffre de
     clés, ni votre compte de stockage, ni votre groupe de ressources ;
   - il ne touche à AUCUNE autorisation autre que celles de 3SR : les vôtres et
     celles de vos équipes sont laissées intactes ;
   - il ne modifie aucune propriété de vos ressources.

 Après exécution, vos certificats restent en votre possession, exploitables
 normalement. Seul le renouvellement automatique par 3SR cesse.

 LANCEMENT
   az login
   .\3sr-ssl-offboarding.ps1

 MODE SIMULATION (aucune modification)
   .\3sr-ssl-offboarding.ps1 -Simulation

 OPTION
   -RapportEmail <adresse> : adresse affichée comme destinataire de l'information de
        révocation. Facultatif : sans valeur, informez votre contact 3SR.

 CODES DE RETOUR
   0 = succès (ou rien à révoquer)   2 = succès partiel   1 = erreur bloquante
===============================================================================
#>

#Requires -Version 5.1

param(
    [switch]$Simulation,
    [string]$RapportEmail = ""
)

$ScriptVersion = "1.1.0"
$SpnAppId      = "aa2e6eae-63e0-4180-96f9-35a6c59c706a"   # Application 3SR (identifiant public)
# Destinataire affiché pour l'information de révocation : paramètre facultatif -RapportEmail.
$DestinataireRapport = if ([string]::IsNullOrWhiteSpace($RapportEmail)) { "votre contact 3SR" } else { $RapportEmail }

$ErrorActionPreference = "Stop"
$script:DerniereErreurAz = ""

function Write-Titre($Texte) {
    Write-Host ""
    Write-Host ("=" * 74) -ForegroundColor DarkCyan
    Write-Host "  $Texte" -ForegroundColor Cyan
    Write-Host ("=" * 74) -ForegroundColor DarkCyan
}
function Write-Etape($Texte)  { Write-Host "  > $Texte" -ForegroundColor Gray }
function Write-Ok($Texte)     { Write-Host "  [OK]    $Texte" -ForegroundColor Green }
function Write-Souci($Texte)  { Write-Host "  [!]     $Texte" -ForegroundColor Yellow }
function Write-Erreur($Texte) { Write-Host "  [ERREUR] $Texte" -ForegroundColor Red }
function Write-Simu($Texte)   { Write-Host "  [SIMU]  $Texte" -ForegroundColor Magenta }

function Invoke-Az {
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
        Write-Souci "Saisie invalide."
    }
}

# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "3SR - SSL MANAGED SOLUTION : révocation des accès accordés à 3SR"
Write-Host "  Version du script : $ScriptVersion" -ForegroundColor DarkGray
if ($Simulation) {
    Write-Host ""
    Write-Host "  ***************************************************************" -ForegroundColor Magenta
    Write-Host "  *  MODE SIMULATION : aucune révocation ne sera effectuée       *" -ForegroundColor Magenta
    Write-Host "  ***************************************************************" -ForegroundColor Magenta
}
Write-Host ""
Write-Host "  Ce script ne supprime AUCUNE ressource et ne touche à AUCUN accès" -ForegroundColor DarkGray
Write-Host "  autre que ceux de 3SR. Vos certificats restent en votre possession." -ForegroundColor DarkGray

try { $null = Get-Command az -ErrorAction Stop }
catch { Write-Erreur "Azure CLI (az) est introuvable. https://aka.ms/installazurecli" ; exit 1 }

Write-Titre "1. Choix de l'abonnement"

$comptes = Invoke-Az @("account","list","--all","-o","json") -Silencieux
if ($null -eq $comptes -or @($comptes).Count -eq 0) {
    Write-Erreur "Aucune souscription accessible. Exécutez « az login » puis relancez."
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
    $nomTenant = $annuaireTenants[$g.Name]
    if ([string]::IsNullOrWhiteSpace($nomTenant)) { $nomTenant = $g.Group[0].tenantDefaultDomain }
    if ([string]::IsNullOrWhiteSpace($nomTenant) -and $g.Group[0].user.name -match '@(.+)$') { $nomTenant = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($nomTenant)) { $nomTenant = "(nom non communiqué)" }
    [PSCustomObject]@{ Id = $g.Name; Nom = $nomTenant; NbSubs = $g.Count }
}
$tenants = @($tenants | Sort-Object Nom)

$tenantChoisi = Read-Selection -Titre "Sélectionnez le locataire (tenant) Microsoft Entra :" -Elements $tenants -Libelle {
    param($t) "{0}   ({1})   {2} souscription(s)" -f $t.Nom, $t.Id, $t.NbSubs
}
$subsDuTenant = @($comptes | Where-Object { $_.tenantId -eq $tenantChoisi.Id } | Sort-Object name)
$subChoisie = Read-Selection -Titre "Sélectionnez la souscription à examiner :" -Elements $subsDuTenant -Libelle {
    param($s) "{0}   ({1})" -f $s.name, $s.id
}

$null = Invoke-Az @("account","set","--subscription",$subChoisie.id)
$compte = Invoke-Az @("account","show","-o","json")
if ($null -eq $compte) { Write-Erreur "Impossible d'activer cette souscription." ; exit 1 }

$TenantId       = $compte.tenantId
$SubscriptionId = $compte.id
$SubName        = $compte.name
$Utilisateur    = $compte.user.name

Write-Host ""
Write-Host "  Locataire    : $($tenantChoisi.Nom)  ($TenantId)"
Write-Host "  Souscription : $SubName  ($SubscriptionId)"
Write-Host "  Connecté en  : $Utilisateur"

# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "2. Recherche des accès accordés à 3SR"

$spn = Invoke-Az @("ad","sp","show","--id",$SpnAppId,"-o","json") -Silencieux
if ($null -eq $spn -or [string]::IsNullOrWhiteSpace($spn.id)) {
    Write-Ok "L'application 3SR n'est pas enregistrée dans ce locataire."
    Write-Host "          Il n'y a donc aucun accès 3SR à révoquer ici." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Remarque : si vous souhaitez également retirer l'application de votre" -ForegroundColor DarkGray
    Write-Host "  annuaire, cela se fait dans le portail Entra, section « Applications" -ForegroundColor DarkGray
    Write-Host "  d'entreprise ». Ce script ne le fait pas." -ForegroundColor DarkGray
    exit 0
}
$SpnObjectId = $spn.id
$SpnNom = if ($spn.displayName) { $spn.displayName } else { "(sans nom)" }
Write-Ok "Application 3SR trouvée : « $SpnNom »"
Write-Host "          Object ID : $SpnObjectId" -ForegroundColor DarkGray

Write-Etape "Inventaire des attributions de rôles dans cette souscription..."
$attributions = Invoke-Az @("role","assignment","list","--assignee",$SpnObjectId,"--all",
    "--subscription",$SubscriptionId,"-o","json") -Silencieux
$attributions = @($attributions | Where-Object { $_ -and $_.id })

if ($attributions.Count -eq 0) {
    Write-Ok "Aucune attribution de rôle 3SR dans cette souscription : rien à révoquer."
    Write-Host ""
    Write-Host "  Si vous pensiez qu'il devait y en avoir, vérifiez que vous avez bien" -ForegroundColor DarkGray
    Write-Host "  sélectionné la bonne souscription, et relancez." -ForegroundColor DarkGray
    exit 0
}

Write-Host ""
Write-Host "  $($attributions.Count) attribution(s) de rôle trouvée(s) au bénéfice de 3SR :" -ForegroundColor White
Write-Host ""
$i = 0
foreach ($a in $attributions) {
    $i++
    Write-Host "     [$i] $($a.roleDefinitionName)" -ForegroundColor White
    Write-Host "         portée : $($a.scope)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Conséquence de la révocation :" -ForegroundColor Yellow
Write-Host "    - 3SR ne renouvellera plus vos certificats." -ForegroundColor Yellow
Write-Host "    - Les certificats déjà émis restent dans votre coffre et restent" -ForegroundColor Yellow
Write-Host "      valides jusqu'à leur date d'expiration." -ForegroundColor Yellow
Write-Host "    - AUCUNE ressource ni AUCUN certificat n'est supprimé." -ForegroundColor Yellow
Write-Host ""

# Sélection. La révocation en bloc est le cas courant, mais l'application 3SR peut
# porter d'autres rôles sans rapport avec le service SSL si 3SR assure d'autres
# prestations dans cette souscription : les emporter serait exactement la
# « modification surprise » que ces scripts s'interdisent. D'où le choix explicite.
$aRevoquer = $attributions
if ($attributions.Count -gt 1) {
    Write-Host "  Vous pouvez tout révoquer, ou ne désigner que certaines lignes." -ForegroundColor Gray
    Write-Host ""
}
$valider = Read-Host "  Tapez REVOQUER pour tout révoquer, ou les numéros à révoquer (ex. 1,3)"
$valider = $valider.Trim()

if ($valider.ToUpper() -eq "REVOQUER") {
    $aRevoquer = $attributions
}
elseif ($valider -match '^[0-9]+(\s*,\s*[0-9]+)*$') {
    $indices = @($valider -split ',' | ForEach-Object { [int]$_.Trim() } | Sort-Object -Unique)
    $hors = @($indices | Where-Object { $_ -lt 1 -or $_ -gt $attributions.Count })
    if ($hors.Count -gt 0) {
        Write-Erreur "Numéro(s) hors liste : $($hors -join ', '). Abandon, aucun accès n'a été révoqué."
        exit 0
    }
    $aRevoquer = @($indices | ForEach-Object { $attributions[$_ - 1] })
    Write-Host ""
    Write-Host "  Seront révoquées :" -ForegroundColor White
    foreach ($a in $aRevoquer) { Write-Host "     $($a.roleDefinitionName) sur $($a.scope)" -ForegroundColor Gray }
    Write-Host ""
    $c = Read-Host "  Confirmez-vous ? (o/N)"
    if ($c -notmatch '^[oOyY]') {
        Write-Host "  Abandon. Aucun accès n'a été révoqué." -ForegroundColor Yellow
        exit 0
    }
}
else {
    Write-Host ""
    Write-Host "  Abandon. Aucun accès n'a été révoqué." -ForegroundColor Yellow
    exit 0
}

if ($Simulation) {
    Write-Host ""
    foreach ($a in $aRevoquer) { Write-Simu "az role assignment delete --ids $($a.id)" }
    Write-Host ""
    Write-Host "  SIMULATION terminée : aucune révocation effectuée." -ForegroundColor Magenta
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════

Write-Titre "3. Révocation"

$resultats = @()
foreach ($a in $aRevoquer) {
    Write-Etape "$($a.roleDefinitionName) sur $($a.scope)"
    $r = Invoke-Az @("role","assignment","delete","--ids",$a.id) -Silencieux
    if ($null -ne $r) {
        Write-Ok "Révoqué."
        $resultats += [PSCustomObject]@{ Role = $a.roleDefinitionName; Scope = $a.scope; Etat = "REVOQUE"; Detail = "" }
    }
    else {
        # Peut-être déjà supprimé entre l'inventaire et maintenant : on revérifie.
        $reste = Invoke-Az @("role","assignment","list","--assignee",$SpnObjectId,"--scope",$a.scope,
            "--role",$a.roleDefinitionName,"-o","json") -Silencieux
        if ($null -ne $reste -and @($reste).Count -eq 0) {
            Write-Ok "Déjà absent."
            $resultats += [PSCustomObject]@{ Role = $a.roleDefinitionName; Scope = $a.scope; Etat = "REVOQUE"; Detail = "déjà absent" }
        }
        else {
            Write-Erreur "Échec de la révocation."
            $msg = ($script:DerniereErreurAz -split "`n" | Select-Object -First 2) -join " "
            if ($msg) { Write-Host "           $($msg.Trim())" -ForegroundColor DarkRed }
            if ($script:DerniereErreurAz -match "AuthorizationFailed|does not have authorization|Forbidden") {
                Write-Host "           Vos droits ne permettent pas de retirer des rôles : faites exécuter" -ForegroundColor DarkRed
                Write-Host "           ce script par un Propriétaire de la souscription." -ForegroundColor DarkRed
            }
            $resultats += [PSCustomObject]@{ Role = $a.roleDefinitionName; Scope = $a.scope; Etat = "ECHEC"; Detail = $msg }
        }
    }
}

Write-Titre "4. Contrôle final"
Write-Etape "Nouvelle lecture des attributions de rôles 3SR..."
$restantes = Invoke-Az @("role","assignment","list","--assignee",$SpnObjectId,"--all",
    "--subscription",$SubscriptionId,"-o","json") -Silencieux
$restantes = @($restantes | Where-Object { $_ -and $_.id })

# Une attribution qui subsiste n'est un problème que si sa révocation avait été demandée.
$idsDemandes = @($aRevoquer | ForEach-Object { $_.id })
$nonRevoquees = @($restantes | Where-Object { $_.id -in $idsDemandes })
$conservees   = @($restantes | Where-Object { $_.id -notin $idsDemandes })

if ($restantes.Count -eq 0) { Write-Ok "Plus aucune attribution de rôle 3SR dans cette souscription." }
else {
    if ($conservees.Count -gt 0) {
        Write-Ok "$($conservees.Count) attribution(s) conservée(s) à votre demande :"
        foreach ($r in $conservees) { Write-Host "          $($r.roleDefinitionName) sur $($r.scope)" -ForegroundColor Gray }
    }
    if ($nonRevoquees.Count -gt 0) {
        Write-Souci "$($nonRevoquees.Count) attribution(s) dont la révocation était demandée subsiste(nt) :"
        foreach ($r in $nonRevoquees) { Write-Host "          $($r.roleDefinitionName) sur $($r.scope)" -ForegroundColor Yellow }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════

$horodatage = Get-Date -Format "yyyy-MM-dd HH:mm"
$nbEchec = @($resultats | Where-Object { $_.Etat -eq "ECHEC" }).Count

$lignes = ($resultats | ForEach-Object {
    $d = if ($_.Detail) { " ($($_.Detail))" } else { "" }
    " {0,-8} {1} : {2}{3}" -f $_.Etat, $_.Role, $_.Scope, $d
}) -join "`r`n"

$lignesRestantes = if ($restantes.Count -eq 0) { " (aucune)" } else {
    ($restantes | ForEach-Object {
        $etiquette = if ($_.id -in $idsDemandes) { "NON REVOQUEE" } else { "conservée à votre demande" }
        " [{0}] {1} : {2}" -f $etiquette, $_.roleDefinitionName, $_.scope
    }) -join "`r`n"
}

$rapport = @"
===============================================================================
 3SR - SSL MANAGED SOLUTION
 Rapport de révocation des accès
===============================================================================
 Généré le      : $horodatage
 Par            : $Utilisateur
 Script version : $ScriptVersion

 Locataire      : $($tenantChoisi.Nom) ($TenantId)
 Souscription   : $SubName ($SubscriptionId)
 Application 3SR: $SpnAppId (Object ID $SpnObjectId)

-------------------------------------------------------------------------------
 ATTRIBUTIONS TRAITÉES
-------------------------------------------------------------------------------
$lignes

-------------------------------------------------------------------------------
 ATTRIBUTIONS 3SR RESTANTES APRÈS EXÉCUTION
-------------------------------------------------------------------------------
$lignesRestantes

-------------------------------------------------------------------------------
 CE QUI N'A PAS ÉTÉ TOUCHÉ
-------------------------------------------------------------------------------
 Aucune ressource n'a été supprimée ni modifiée : groupe de ressources, compte
 de stockage, coffre de clés et certificats sont intacts. Aucune autorisation
 autre que celles de l'application 3SR n'a été retirée.

 L'application 3SR reste enregistrée dans votre annuaire Microsoft Entra ; son
 retrait éventuel se fait depuis le portail Entra, section « Applications
 d'entreprise ». Sans attribution de rôle, elle n'a plus aucun accès.
===============================================================================
"@

$fichierRapport = Join-Path (Get-Location) ("3sr-ssl-offboarding-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmm"))
try { $rapport | Out-File -FilePath $fichierRapport -Encoding UTF8 ; $ecrit = $true } catch { $ecrit = $false }

Write-Titre "Terminé"
Write-Host $rapport
Write-Host ""
if ($ecrit) { Write-Host "  Rapport enregistré : $fichierRapport" -ForegroundColor Green }
Write-Host ""
Write-Host "  Merci d'informer 3SR de cette révocation : $DestinataireRapport" -ForegroundColor Cyan
Write-Host ""

if ($nbEchec -gt 0 -or $nonRevoquees.Count -gt 0) { exit 2 }
exit 0
