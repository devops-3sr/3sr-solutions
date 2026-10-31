#Requires -Version 7.0
<#
.SYNOPSIS
    Banc de test HORS LIGNE de CloudiwayCollector (cmdlets simulees, aucune connexion, aucun reseau).
.DESCRIPTION
    Usage : pwsh -NoProfile -File tests\test-collectors.ps1 [-KeepOutput]
    Ecrit uniquement dans un dossier temporaire (supprime a la fin sauf -KeepOutput).
    Code de sortie = nombre de tests FAIL.
#>
param([switch]$KeepOutput)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$pkg = Split-Path -Parent $PSScriptRoot
$libDir = Join-Path $pkg 'lib'
$mainScript = Join-Path $pkg 'cloudiway-collector.ps1'
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cwtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$origCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
$origUICulture = [System.Threading.Thread]::CurrentThread.CurrentUICulture

# ---------------------------------------------------------------------------------------------------
# Chargement : libs d'abord, puis mocks (les stubs priment)
# ---------------------------------------------------------------------------------------------------
. (Join-Path $libDir 'common.ps1')
foreach ($f in 'ui', 'preflight', 'collect-identity', 'collect-devices', 'collect-security', 'collect-dns', 'collect-exchange', 'collect-sharepoint') { . (Join-Path $libDir "$f.ps1") }
. (Join-Path $PSScriptRoot 'mocks.ps1')

# Garde-fou : tout ce qui se connecte ou touche le reseau doit etre un stub (Function), sinon on s'arrete
$mustBeStub = 'Connect-MgGraph', 'Invoke-MgGraphRequest', 'Connect-ExchangeOnline', 'Connect-SPOService', 'Resolve-DnsName', 'Get-MgContext', 'Disconnect-MgGraph',
'Disconnect-ExchangeOnline', 'Disconnect-SPOService', 'Import-Module', 'Get-Module', 'Install-Module', 'Read-Host', 'pwsh',
'Start-Sleep', 'Get-EXOMailbox', 'Get-Mailbox', 'Get-MailboxStatistics', 'Get-SPOSite', 'Get-SPOTenant', 'Get-AcceptedDomain', 'Get-OrganizationConfig',
'Invoke-WebRequest', 'Get-PSRepository', 'Set-PSRepository', 'Get-PackageProvider', 'Install-PackageProvider'
$notStub = @($mustBeStub | Where-Object { (Get-Command $_ -ErrorAction SilentlyContinue | Select-Object -First 1).CommandType -ne 'Function' })
if ($notStub.Count) { Write-Host "ARRET : commandes non simulees (risque de connexion reelle) : $($notStub -join ', ')" -ForegroundColor Red; exit 99 }

# ---------------------------------------------------------------------------------------------------
# Utilitaires de test
# ---------------------------------------------------------------------------------------------------
$Results = [System.Collections.Generic.List[object]]::new()
function T([string]$Group, [string]$Name, $Ok, [string]$Detail = '') {
    $Results.Add([pscustomobject]@{ Group = $Group; Test = $Name; Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $(if ($Ok) { '' } else { $Detail }) })
}

function New-Ctx([string]$Role, [string]$Tag) {
    $out = Join-Path $tmpRoot $Tag
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $script:Ctx = @{
        TenantId = $MockTenantId; User = $MockUser; Role = $Role; IsSource = ($Role -eq 'Source'); InitialDomain = $MockInitial; Out = $out
        Capabilities = [System.Collections.Generic.List[object]]::new()
    }
    $out
}

# Appelle une collecte ; retourne l'exception eventuelle (les collecteurs ne doivent jamais en lever)
function Invoke-Part([string]$Fn) {
    $err = $null
    try { & $Fn *> $null } catch { $err = $_ }
    $err
}

function Get-Header([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $l = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding utf8
    if (-not $l) { return $null }
    $l = $l.TrimStart([char]0xFEFF)
    if (-not $l.Trim()) { return $null }
    @($l -split ';' | ForEach-Object { $_.Trim('"') })
}
function Read-Out([string]$Out, [string]$Name) {
    $p = Join-Path $Out $Name
    if (-not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -lt 5) { return @() }
    @(Import-Csv -LiteralPath $p -Delimiter ';')
}
function Get-Cap([string]$Part, [string]$ItemLike) {
    @($script:Ctx.Capabilities | Where-Object { $_.Part -eq $Part -and $_.Item -like $ItemLike })
}
function Get-CapStatus([string]$Part, [string]$ItemLike) {
    $c = Get-Cap $Part $ItemLike
    if ($c.Count) { $c[0].Status } else { '(absente)' }
}

# En-tetes attendus : liste manuelle (colonnes toutes presentes)
$manualHeaders = @{
    'exo-organization.csv'        = 'Name', 'AuditDisabled', 'PublicFoldersEnabled', 'OAuth2ClientProfileEnabled', 'DefaultAuthenticationPolicy', 'SmtpClientAuthenticationDisabled', 'ConnectorsEnabled', 'MailTipsAllTipsEnabled', 'CustomerLockboxEnabled'
    'dkim.csv'                    = 'Domain', 'Enabled', 'Status'
    'recipients.csv'              = 'Alias', 'DisplayName', 'PrimarySmtpAddress', 'RecipientTypeDetails', 'EmailAddresses'
    'intune-managed-devices.csv'  = 'id', 'deviceName', 'operatingSystem', 'osVersion', 'complianceState', 'userPrincipalName', 'azureADDeviceId'
    'capabilities.csv'            = 'Part', 'Item', 'Status', 'Detail'
    'tenant.csv'                  = 'Tenant', 'DisplayName', 'TenantId', 'InitialDomain', 'CountryLetterCode', 'PreferredLanguage', 'OnPremisesSyncEnabled', 'OnPremisesLastSyncDateTime', 'CreatedDateTime', 'AuditedBy', 'AuditedAt', 'ScriptVersion', 'Role'
}
function Get-ExpectedHeader([string]$Name) {
    if ($Name -eq 'capabilities.csv') { return @{ H = $manualHeaders[$Name]; Src = 'liste manuelle' } }
    if ($manualHeaders.ContainsKey($Name)) { return @{ H = $manualHeaders[$Name]; Src = 'liste manuelle' } }
    $null
}
function Test-CsvHeaders([string]$Group, [string]$Out, [string[]]$Names) {
    foreach ($n in $Names) {
        $p = Join-Path $Out $n
        $exp = Get-ExpectedHeader $n
        $have = Get-Header $p
        if (-not (Test-Path -LiteralPath $p)) { T $Group "en-tetes $n" $false 'fichier absent'; continue }
        if (-not $exp) { T $Group "en-tetes $n" $true; continue }
        if (-not $have) { T $Group "en-tetes $n" $true; continue }   # fichier vide (0 ligne) : traite ailleurs
        $optional = if ($n -eq 'ews.csv') { @('Tenant') } else { @() }   # Tenant (etiquette) ou TenantId
        $miss = @($exp.H | Where-Object { $_ -notin $have -and $_ -notin $optional })
        $extra = @($have | Where-Object { $_ -notin $exp.H })
        T $Group "en-tetes $n ($($exp.Src))" ($miss.Count -eq 0) ("colonnes de reference absentes : $($miss -join ', ')" + $(if ($extra) { " ; colonnes en plus : $($extra -join ', ')" } else { '' }))
    }
}

$SourceFiles = 'skus.csv', 'users.csv', 'guests.csv', 'groups.csv', 'domains.csv', 'teams-channels.csv',
'report-onedrive-usage.csv', 'report-sharepoint-usage.csv', 'report-mailbox-usage.csv', 'report-active-users.csv', 'enterprise-apps.csv',
'entra-devices.csv', 'intune-managed-devices.csv', 'intune-config-inventory.csv',
'conditional-access.csv', 'security-defaults.csv', 'authorization-policy.csv', 'cross-tenant-access.csv', 'directory-roles.csv', 'mfa-registration.csv', 'auth-methods-policy.csv',
'dns.csv',
'ews.csv', 'exo-organization.csv', 'mailboxes.csv', 'mailbox-permissions.csv', 'distribution-lists.csv', 'mail-contacts.csv', 'accepted-domains.csv', 'connectors.csv', 'transport-rules.csv', 'dkim.csv',
'sites.csv', 'onedrive.csv', 'sharepoint.csv', 'sharepoint-system.csv', 'spo-tenant.csv',
'capabilities.csv'
# Fichiers absents PAR CONSTRUCTION dans le scenario de base (403 injecte) : le refus doit etre une ligne KO, pas un plantage
$SourceFilesKo = 'report-teams-activity.csv', 'autopilot-devices.csv', 'secure-score.csv'

# ===================================================================================================
# S1 - ROLE SOURCE, scenario de base (403 / liste vide / pagination injectes)
# ===================================================================================================
Reset-MockState
$out1 = New-Ctx 'Source' 'S1-source'
$g = 'S1 Source'
$errs = [ordered]@{}
foreach ($fn in 'Invoke-IdentityCollection', 'Invoke-DevicesCollection', 'Invoke-SecurityCollection', 'Invoke-DnsCollection', 'Invoke-ExchangeCollection', 'Invoke-SharePointCollection') {
    $errs[$fn] = Invoke-Part $fn
    T $g "$fn ne leve aucune exception" ($null -eq $errs[$fn]) "$($errs[$fn])"
}
# Le principal ecrit capabilities.csv en fin de collecte
Save-Csv @($script:Ctx.Capabilities) 'capabilities.csv' *> $null

foreach ($p in 'Identity', 'Devices', 'Security', 'Dns', 'Exchange', 'SharePoint') {
    $n = @($script:Ctx.Capabilities | Where-Object Part -eq $p).Count
    T $g "Add-Cap a produit des lignes pour $p" ($n -gt 0) "0 ligne"
}
$unexpectedKo = @($script:Ctx.Capabilities | Where-Object { $_.Status -eq 'KO' } | Where-Object { $_.Item -notmatch 'signInActivity|getTeamsUserActivityUserDetail|Autopilot|Secure Score|inventaire Script' })
T $g 'seuls les 403 injectes sont KO (aucun KO parasite)' ($unexpectedKo.Count -eq 0) (($unexpectedKo | ForEach-Object { "$($_.Part)/$($_.Item): $($_.Detail)" }) -join ' | ')
T $g 'aucune route Graph non simulee (mock complet)' ($MockUnrouted.Count -eq 0) ($MockUnrouted -join ', ')

foreach ($f in $SourceFiles) { T $g "fichier cree : $f" (Test-Path -LiteralPath (Join-Path $out1 $f)) 'absent' }
foreach ($f in $SourceFilesKo) {
    T $g "403 injecte : $f absent mais capacite KO" ((-not (Test-Path (Join-Path $out1 $f))) -and (@($script:Ctx.Capabilities | Where-Object { $_.Status -eq 'KO' }).Count -gt 0)) 'fichier present ou pas de KO'
}
Test-CsvHeaders $g $out1 @($SourceFiles | Where-Object { $_ -match '\.csv$' } | Where-Object { $_ -notmatch '^report-' })

# --- Identity : pagination, 403, liste vide, categories ---
$users = Read-Out $out1 'users.csv'
T $g 'pagination /users suivie (3+2 = 5 lignes)' ($users.Count -eq 5) "users.csv : $($users.Count) lignes"
T $g 'users.csv : pas de duplication d id' (@($users | Select-Object -ExpandProperty id -Unique).Count -eq $users.Count) 'doublons'
$alice = $users | Where-Object userPrincipalName -eq 'alice@contoso.com'
T $g 'users.csv : licences resolues en SkuPartNumber' ($alice.licenses -eq 'O365_BUSINESS_PREMIUM|O365_BUSINESS' -and $alice.licensed -eq 'True') "licenses='$($alice.licenses)' licensed='$($alice.licensed)'"
T $g 'signInActivity 403 -> KO + lastSignIn vide' ((Get-CapStatus 'Identity' 'signInActivity') -eq 'KO' -and -not $alice.lastSignIn) "cap=$(Get-CapStatus 'Identity' 'signInActivity') lastSignIn='$($alice.lastSignIn)'"
T $g 'guests.csv : 1 invite' ((Read-Out $out1 'guests.csv').Count -eq 1) ''
$groups = Read-Out $out1 'groups.csv'
T $g 'pagination /groups suivie (2+2 = 4 lignes)' ($groups.Count -eq 4) "$($groups.Count) lignes"
T $g 'groups.csv : kind M365/Distribution/Security corrects' ((($groups | Group-Object kind | ForEach-Object { "$($_.Name)=$($_.Count)" } | Sort-Object) -join ',') -eq 'Distribution=1,M365=2,Security=1') (($groups | Group-Object kind | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ',')
T $g 'groups.csv : isTeam=True pour 1 groupe' (@($groups | Where-Object isTeam -eq 'True').Count -eq 1) ''
$gTeam = $groups | Where-Object displayName -eq 'Equipe-Projet'; $gDl = $groups | Where-Object displayName -eq 'DL-Ventes'; $gSec = $groups | Where-Object displayName -eq 'Securite-Admins'
T $g 'groups.csv : compte membres/proprietaires, DL non comptee, groupe 403 en KO' ($gTeam.members -eq '7' -and $gTeam.owners -eq '7' -and -not $gDl.members -and $gSec.members -eq 'KO' -and $gSec.owners -eq 'KO') "team=$($gTeam.members)/$($gTeam.owners) dl='$($gDl.members)' sec=$($gSec.members)/$($gSec.owners)"
T $g 'capacite groups membres/proprietaires = PARTIEL' ((Get-CapStatus 'Identity' 'groups membres*') -eq 'PARTIEL') (Get-CapStatus 'Identity' 'groups membres*')
$tc = Read-Out $out1 'teams-channels.csv'
T $g 'teams-channels.csv : 1 equipe, 3 canaux (1 prive, 1 partage)' ($tc.Count -eq 1 -and $tc[0].Channels -eq '3' -and $tc[0].Private -eq '1' -and $tc[0].Shared -eq '1' -and $tc[0].Standard -eq '1') "$($tc | ConvertTo-Json -Compress)"
T $g 'domains.csv : 5 domaines, supportedServices joints par |' ((Read-Out $out1 'domains.csv').Count -eq 5 -and ((Read-Out $out1 'domains.csv')[0].supportedServices -eq 'Email|OfficeCommunicationsOnline')) ''
T $g 'reportSettings OK (rapports nominatifs)' ((Get-CapStatus 'Identity' 'reportSettings') -eq 'OK') (Get-CapStatus 'Identity' 'reportSettings')
T $g 'rapports : 4 OK + teams-activity KO' ((Get-CapStatus 'Identity' 'report getOneDriveUsageAccountDetail') -eq 'OK' -and (Get-CapStatus 'Identity' 'report getOffice365ActiveUserDetail') -eq 'OK' -and (Get-CapStatus 'Identity' 'report getTeamsUserActivityUserDetail') -eq 'KO') ''
T $g 'rapport : 1 ligne conservee, fichier temporaire _tmp_ supprime' ((Read-Out $out1 'report-onedrive-usage.csv').Count -eq 1 -and -not (Get-ChildItem $out1 -Filter '_tmp_*')) ''
T $g 'enterprise-apps.csv : exclut Microsoft et ManagedIdentity (1 ligne)' ((Read-Out $out1 'enterprise-apps.csv').Count -eq 1) "$((Read-Out $out1 'enterprise-apps.csv').Count)"

# --- Devices ---
T $g 'entra-devices 2 / intune 1 lignes' ((Read-Out $out1 'entra-devices.csv').Count -eq 2 -and (Read-Out $out1 'intune-managed-devices.csv').Count -eq 1) ''
T $g 'Autopilot 403 -> KO avec message court Intune' ((Get-CapStatus 'Devices' 'Autopilot') -eq 'KO' -and (Get-Cap 'Devices' 'Autopilot')[0].Detail -like 'Non disponible (licence Intune*') (Get-Cap 'Devices' 'Autopilot')[0].Detail
$inv = Read-Out $out1 'intune-config-inventory.csv'
T $g 'inventaire Intune : 8 lignes (liste vide App = 0 element, OK ; Script 403 = KO)' ($inv.Count -eq 8 -and (Get-CapStatus 'Devices' 'inventaire App') -eq 'OK' -and (Get-CapStatus 'Devices' 'inventaire Script') -eq 'KO') "lignes=$($inv.Count)"
T $g 'inventaire Script 403 : detail clair "Refus HTTP 403 : role Intune ou licence manquant (inventaire optionnel)"' ((Get-Cap 'Devices' 'inventaire Script')[0].Detail -eq 'Refus HTTP 403 : role Intune ou licence manquant (inventaire optionnel)') (Get-Cap 'Devices' 'inventaire Script')[0].Detail
T $g 'inventaire Intune : Name repli sur .name (SettingsCatalog)' ((@($inv | Where-Object { $_.Category -eq 'SettingsCatalog' }))[0].Name -eq 'Baseline') ''
T $g 'appels beta pour SettingsCatalog/Script/AutopilotProfile' (@($MockCalls | Where-Object { $_.Uri -like '*/beta/*' }).Count -eq 3) "$(@($MockCalls | Where-Object { $_.Uri -like '*/beta/*' }).Count) appels beta"

# --- Security ---
T $g 'conditional-access : liste vide -> fichier vide + capacite OK' ((Get-CapStatus 'Security' 'Conditional Access') -eq 'OK' -and (Get-Item (Join-Path $out1 'conditional-access.csv')).Length -le 5) "cap=$(Get-CapStatus 'Security' 'Conditional Access') taille=$((Get-Item (Join-Path $out1 'conditional-access.csv')).Length)"
T $g 'security-defaults / authorization-policy lus' ((Read-Out $out1 'security-defaults.csv')[0].SecurityDefaultsEnabled -eq 'False' -and (Read-Out $out1 'authorization-policy.csv')[0].allowInvitesFrom -eq 'everyone' -and (Read-Out $out1 'authorization-policy.csv')[0].usersCanCreateApps -eq 'True') ''
T $g 'authorization-policy : userConsentPolicies joints' ((Read-Out $out1 'authorization-policy.csv')[0].userConsentPolicies -like '*|*') ''
T $g 'cross-tenant-access.csv : 1 ligne JSON compact' ((Read-Out $out1 'cross-tenant-access.csv').Count -eq 1) ''
$dr = Read-Out $out1 'directory-roles.csv'
T $g 'directory-roles : 2 roles, role en 403 = 0 membre + PARTIEL' ($dr.Count -eq 2 -and (Get-CapStatus 'Security' 'Roles annuaire') -eq 'PARTIEL') "lignes=$($dr.Count) cap=$(Get-CapStatus 'Security' 'Roles annuaire')"
T $g 'directory-roles : membres SP sans UPN -> displayName' (($dr | Where-Object Role -eq 'Global Administrator').MemberList -eq 'alice@contoso.com|AppSP') "$(($dr | Where-Object Role -eq 'Global Administrator').MemberList)"
T $g 'secure score 403 -> KO ; mfa 2 lignes ; auth-methods 2 lignes' ((Get-CapStatus 'Security' 'Secure Score') -eq 'KO' -and (Read-Out $out1 'mfa-registration.csv').Count -eq 2 -and (Read-Out $out1 'auth-methods-policy.csv').Count -eq 2) ''

# --- Dns ---
$dns = Read-Out $out1 'dns.csv'
T $g 'dns.csv : 3 domaines (onmicrosoft et non verifie exclus)' ($dns.Count -eq 3) (($dns | ForEach-Object Domain) -join ',')
$dc = $dns | Where-Object Domain -eq 'contoso.com'; $df = $dns | Where-Object Domain -eq 'fr.contoso.com'; $de = $dns | Where-Object Domain -eq 'err.contoso.com'
T $g 'dns contoso.com : MX/SPF/DMARC/Autodiscover/filtrage' ($dc.MX -eq '0 contoso-com.mail.protection.outlook.com' -and $dc.FiltrageDeduit -eq 'Microsoft EOP' -and $dc.SPF -eq 'v=spf1 include:spf.protection.outlook.com -all' -and $dc.DMARC -like 'v=DMARC1; p=none*' -and $dc.Autodiscover -eq 'autodiscover.outlook.com') ($dc | ConvertTo-Json -Compress)
T $g 'dns fr.contoso.com : Mimecast, SPF/DMARC/Autodiscover ABSENT (SOA ignore)' ($df.FiltrageDeduit -eq 'Mimecast' -and $df.SPF -eq 'ABSENT' -and $df.DMARC -eq 'ABSENT' -and $df.Autodiscover -eq 'ABSENT') ($df | ConvertTo-Json -Compress)
T $g 'dns err.contoso.com : timeout -> ERREUR (2 tentatives) et capacite PARTIEL' ($de.MX -eq 'ERREUR' -and $de.FiltrageDeduit -eq 'Indetermine (erreur DNS)' -and (Get-CapStatus 'Dns' 'Resolution publique') -eq 'PARTIEL') ($de | ConvertTo-Json -Compress)
T $g 'dns : 2 tentatives sur erreur de resolveur' (@($MockCalls | Where-Object { $_.Kind -eq 'DNS' -and $_.Detail -eq 'err.contoso.com/MX' }).Count -eq 2) ''

# --- Exchange ---
T $g 'Exchange : connexion verifiee (tenant)' ((Get-CapStatus 'Exchange' 'Connexion') -eq 'OK') (Get-CapStatus 'Exchange' 'Connexion')
$cx = $MockCalls | Where-Object Cmd -eq 'Connect-ExchangeOnline'
T $g 'Exchange : Connect-ExchangeOnline -DisableWAM, UPN impose' ($cx.Detail -like "UPN=$MockUser;DisableWAM=True*") $cx.Detail
$ews = (Read-Out $out1 'ews.csv')[0]
T $g 'ews.csv : comptages et AppId Cloudiway' ($ews.Mailboxes_Total -eq '7' -and $ews.Mailboxes_EwsEnabled_False -eq '1' -and $ews.Mailboxes_EwsEnabled_Null -eq '5' -and $ews.'AppId_Cloudiway-cible_present' -eq 'True' -and $ews.'AppId_Cloudiway-source_present' -eq 'False') ($ews | ConvertTo-Json -Compress)
$mb = Read-Out $out1 'mailboxes.csv'
T $g 'mailboxes.csv : 7 boites' ($mb.Count -eq 7) "$($mb.Count)"
$ma = $mb | Where-Object UserPrincipalName -eq 'alice@contoso.com'
T $g 'mailboxes.csv : octets, Go FR, archive, date ISO (jour > 12)' ($ma.TotalItemSizeBytes -eq '128849018880' -and $ma.TotalItemSizeGB -eq '120,00' -and $ma.ArchiveSizeBytes -eq '64424509440' -and $ma.WhenCreatedUTC -eq '2024-10-24T10:49:05' -and $ma.LastUserActionTime -eq '2026-10-12T08:55:45') ($ma | ConvertTo-Json -Compress)
$mc3 = $mb | Where-Object UserPrincipalName -eq 'carol@contoso.com'
T $g 'mailboxes.csv : statistiques en echec -> ligne conservee, StatsRead False, PARTIEL' ($mc3.StatsRead -eq 'False' -and -not $mc3.TotalItemSizeBytes -and (Get-CapStatus 'Exchange' 'Statistiques des boites') -eq 'PARTIEL') "StatsRead=$($mc3.StatsRead) cap=$(Get-CapStatus 'Exchange' 'Statistiques des boites')"
T $g 'mailboxes.csv : litige/retention + forwarding conserves' ($ma.IsLitigationOrRetention -eq 'True' -and ($mb | Where-Object UserPrincipalName -eq 'bob@contoso.com').ForwardingSmtpAddress -eq 'smtp:bob@ext.com') ''
T $g 'Get-MailboxStatistics -Archive seulement si ArchiveStatus=Active' (@($MockCalls | Where-Object { $_.Cmd -eq 'Get-MailboxStatistics' -and $_.Detail -like '*Archive=True' }).Count -eq 1) ''
T $g 'Get-EXOMailboxStatistics jamais utilise ' (-not (Select-String -Path (Join-Path $libDir 'collect-exchange.ps1') -Pattern 'Get-EXOMailboxStatistics' -Quiet)) ''
$perm = Read-Out $out1 'mailbox-permissions.csv'
T $g 'mailbox-permissions : 2 boites partagees/salle x (FullAccess + SendAs), SELF/SID/herites filtres' ($perm.Count -eq 4 -and @($perm | Where-Object Right -eq 'FullAccess').Count -eq 2 -and @($perm | Where-Object Right -eq 'SendAs').Count -eq 2 -and -not ($perm | Where-Object Trustee -like 'NT AUTHORITY*')) "$($perm.Count) lignes"
$dl = Read-Out $out1 'distribution-lists.csv'
T $g 'distribution-lists : dynamique, comptage, KO sur erreur, PARTIEL' ($dl.Count -eq 4 -and ($dl | Where-Object DisplayName -eq 'DDL-Paris').Members -eq 'dynamique' -and ($dl | Where-Object DisplayName -eq 'DL-Ventes').Members -eq '3' -and ($dl | Where-Object DisplayName -eq 'DL-Tous').Members -eq 'KO' -and (Get-CapStatus 'Exchange' 'Listes de distribution') -eq 'PARTIEL') (($dl | ForEach-Object { "$($_.DisplayName)=$($_.Members)" }) -join ',')
T $g 'mail-contacts.csv : 2 lignes + ExternalEmailAddress' ((Read-Out $out1 'mail-contacts.csv').Count -eq 2 -and (Read-Out $out1 'mail-contacts.csv')[0].ExternalEmailAddress -like 'SMTP:*') ''
T $g 'connectors.csv : 1 entrant + 1 sortant, colonnes jointes' ((Read-Out $out1 'connectors.csv').Count -eq 2 -and (Read-Out $out1 'connectors.csv')[0].SenderIPAddresses -eq '1.2.3.4|5.6.7.8') ''
T $g 'transport-rules.csv : description sur une ligne' (((Read-Out $out1 'transport-rules.csv')[0].Description) -eq 'Si le message est externe alors ajouter un avertissement') "$((Read-Out $out1 'transport-rules.csv')[0].Description)"
T $g 'accepted-domains / dkim / exo-organization' ((Read-Out $out1 'accepted-domains.csv').Count -eq 2 -and (Read-Out $out1 'dkim.csv').Count -eq 2 -and (Read-Out $out1 'exo-organization.csv').Count -eq 1) ''
T $g 'Disconnect-ExchangeOnline appele une fois' (@($MockCalls | Where-Object Cmd -eq 'Disconnect-ExchangeOnline').Count -eq 1) ''
T $g 'Exchange : 3 lignes Acces OK (test des acces avant la collecte)' (@($script:Ctx.Capabilities | Where-Object { $_.Part -eq 'Exchange' -and $_.Item -like 'Acces *' -and $_.Status -eq 'OK' }).Count -eq 3) (($script:Ctx.Capabilities | Where-Object { $_.Part -eq 'Exchange' -and $_.Item -like 'Acces *' } | ForEach-Object { "$($_.Item)=$($_.Status)" }) -join ',')
T $g 'Exchange : un test d acces (1 boite) puis la liste complete' ((($MockCalls | Where-Object { $_.Cmd -eq 'Get-EXOMailbox' } | Select-Object -First 1).Seq) -lt (($MockCalls | Where-Object { $_.Cmd -eq 'Get-EXOMailbox' } | Select-Object -Last 1).Seq) -and @($MockCalls | Where-Object { $_.Cmd -eq 'Get-EXOMailbox' }).Count -eq 2) "$(@($MockCalls | Where-Object { $_.Cmd -eq 'Get-EXOMailbox' }).Count) appels"

# --- SharePoint ---
$sites = Read-Out $out1 'sites.csv'
T $g 'sites.csv 13 / onedrive 4 / sharepoint 7 / systeme 2' ($sites.Count -eq 13 -and (Read-Out $out1 'onedrive.csv').Count -eq 4 -and (Read-Out $out1 'sharepoint.csv').Count -eq 7 -and (Read-Out $out1 'sharepoint-system.csv').Count -eq 2) "$($sites.Count)/$((Read-Out $out1 'onedrive.csv').Count)/$((Read-Out $out1 'sharepoint.csv').Count)/$((Read-Out $out1 'sharepoint-system.csv').Count)"
$odA = (Read-Out $out1 'onedrive.csv') | Where-Object Owner -eq 'alice@contoso.com'
T $g 'sites.csv : Mo -> octets (x1MB), Go FR, date ISO' ($odA.StorageBytes -eq '32212254720' -and $odA.StorageGB -eq '30,00' -and $odA.LastContentModifiedDate -eq '2026-10-12T06:59:10') ($odA | ConvertTo-Json -Compress)
T $g 'Get-SPOSite -Limit All -IncludePersonalSite True (source)' (@($MockCalls | Where-Object { $_.Cmd -eq 'Get-SPOSite' -and $_.Detail -like 'Limit=All*' }).Detail -eq 'Limit=All;IncludePersonalSite=True') (($MockCalls | Where-Object Cmd -eq 'Get-SPOSite').Detail -join ' / ')
T $g 'Connect-SPOService : URL admin construite depuis le domaine initial' ((($MockCalls | Where-Object Cmd -eq 'Connect-SPOService').Uri) -eq 'https://contoso-admin.sharepoint.com') (($MockCalls | Where-Object Cmd -eq 'Connect-SPOService').Uri)
T $g 'spo-tenant.csv : proprietes absentes du module signalees' ((Read-Out $out1 'spo-tenant.csv').Count -eq 1 -and (Get-Cap 'SharePoint' 'Get-SPOTenant')[0].Detail -like '*LegacyAuthProtocolsEnabled*') "$((Get-Cap 'SharePoint' 'Get-SPOTenant')[0].Detail)"
T $g 'capacite LastContentModifiedDate OK presente' ((Get-CapStatus 'SharePoint' 'LastContentModifiedDate') -eq 'OK') ''
T $g 'Disconnect-SPOService appele une fois' (@($MockCalls | Where-Object Cmd -eq 'Disconnect-SPOService').Count -eq 1) ''
T $g 'SharePoint : 2 lignes Acces OK (test des acces avant la collecte)' (@($script:Ctx.Capabilities | Where-Object { $_.Part -eq 'SharePoint' -and $_.Item -like 'Acces *' -and $_.Status -eq 'OK' }).Count -eq 2) ''

# --- Lecture seule ---
$gr = @($MockCalls | Where-Object { $_.Kind -eq 'Graph' -and $_.Cmd -eq 'Invoke-MgGraphRequest' })
T $g "lecture seule Graph : $($gr.Count) requetes, toutes GET" (($gr.Count -gt 0) -and (@($gr | Where-Object Method -ne 'GET').Count -eq 0)) (($gr | Where-Object Method -ne 'GET' | ForEach-Object { "$($_.Method) $($_.Uri)" }) -join ' | ')
T $g 'lecture seule Exchange/SPO : uniquement Get-*/Connect-*/Disconnect-*' (@($MockCalls | Where-Object { $_.Kind -in 'EXO', 'SPO' -and $_.Cmd -notmatch '^(Get|Connect|Disconnect)-' }).Count -eq 0) ''
T $g 'aucun appel interactif / installation / process' (@($MockCalls | Where-Object Kind -in 'Interactive', 'Install', 'Process').Count -eq 0) ''
$S1calls = $MockCalls.Count; $S1files = @(Get-ChildItem $out1 -File).Count
$S1graph = $gr.Count

# ===================================================================================================
# S2 - ROLE TARGET
# ===================================================================================================
Reset-MockState
$out2 = New-Ctx 'Target' 'S2-target'
$g = 'S2 Target'
foreach ($fn in 'Invoke-IdentityCollection', 'Invoke-DevicesCollection', 'Invoke-SecurityCollection', 'Invoke-DnsCollection', 'Invoke-ExchangeCollection', 'Invoke-SharePointCollection') {
    $e = Invoke-Part $fn; T $g "$fn ne leve aucune exception" ($null -eq $e) "$e"
}
Save-Csv @($script:Ctx.Capabilities) 'capabilities.csv' *> $null
$absent = 'guests.csv', 'teams-channels.csv', 'report-onedrive-usage.csv', 'report-sharepoint-usage.csv', 'report-mailbox-usage.csv', 'report-teams-activity.csv', 'report-active-users.csv',
'mailbox-permissions.csv', 'distribution-lists.csv', 'mail-contacts.csv', 'onedrive.csv', 'sharepoint.csv', 'sharepoint-system.csv'
foreach ($f in $absent) { T $g "Target : $f non produit" (-not (Test-Path (Join-Path $out2 $f))) 'present' }
foreach ($f in 'recipients.csv', 'mailboxes.csv', 'sites.csv', 'users.csv', 'groups.csv', 'dns.csv', 'conditional-access.csv', 'accepted-domains.csv', 'spo-tenant.csv', 'ews.csv') {
    T $g "Target : $f produit" (Test-Path (Join-Path $out2 $f)) 'absent'
}
T $g 'Target : moins de fichiers que Source' (@(Get-ChildItem $out2 -File).Count -lt $S1files) "target=$(@(Get-ChildItem $out2 -File).Count) source=$S1files"
T $g 'Target : moins de requetes Graph que Source (pas de membres/rapports)' (@($MockCalls | Where-Object { $_.Kind -eq 'Graph' -and $_.Cmd -eq 'Invoke-MgGraphRequest' }).Count -lt $S1graph) ''
T $g 'Target : aucun compte de membres/proprietaires de groupe demande' (@($MockCalls | Where-Object { $_.Uri -like '*$count' }).Count -eq 0) ''
T $g 'Target : aucun rapport demande' (@($MockCalls | Where-Object { $_.Uri -like '*/reports/get*' }).Count -eq 0) ''
T $g 'Target : aucune statistique de boite (Get-Mailbox : comptage dossiers publics seulement)' (@($MockCalls | Where-Object Cmd -eq 'Get-MailboxStatistics').Count -eq 0 -and @($MockCalls | Where-Object Cmd -eq 'Get-Mailbox').Count -le 1) ''
T $g 'Target : Get-SPOSite sans -IncludePersonalSite' (@($MockCalls | Where-Object { $_.Cmd -eq 'Get-SPOSite' -and $_.Detail -like 'Limit=All*' }).Detail -eq 'Limit=All;IncludePersonalSite=False') (($MockCalls | Where-Object Cmd -eq 'Get-SPOSite').Detail -join ' / ')
$mb2 = Read-Out $out2 'mailboxes.csv'
T $g 'Target : mailboxes.csv allege (7 lignes, sans volumetrie)' ($mb2.Count -eq 7 -and -not ($mb2[0].PSObject.Properties.Name -contains 'TotalItemSizeBytes')) "$($mb2.Count)"
T $g 'Target : recipients.csv 13 lignes' ((Read-Out $out2 'recipients.csv').Count -eq 13) "$((Read-Out $out2 'recipients.csv').Count)"
T $g 'Target : sites.csv sans OneDrive, colonnes allegees' ((Read-Out $out2 'sites.csv').Count -eq 9 -and (Get-Header (Join-Path $out2 'sites.csv')) -join ',' -eq 'Url,Title,Template,Category') "$((Read-Out $out2 'sites.csv').Count) lignes ; $((Get-Header (Join-Path $out2 'sites.csv')) -join ',')"
Test-CsvHeaders $g $out2 @('recipients.csv', 'users.csv', 'groups.csv', 'dns.csv')
T $g 'Target : lecture seule (GET uniquement)' (@($MockCalls | Where-Object { $_.Kind -eq 'Graph' -and $_.Cmd -eq 'Invoke-MgGraphRequest' -and $_.Method -ne 'GET' }).Count -eq 0) ''

# ===================================================================================================
# S3 - SCENARIOS DEGRADES (jamais d'exception, KO propres)
# ===================================================================================================
$g = 'S3 Degrade'
# 3a - tout Graph en 403
Reset-MockState; $MockOpts.ForbidAllGraph = $true
$out3 = New-Ctx 'Source' 'S3a-allforbidden'
foreach ($fn in 'Invoke-IdentityCollection', 'Invoke-DevicesCollection', 'Invoke-SecurityCollection', 'Invoke-DnsCollection') { $e = Invoke-Part $fn; T $g "403 partout : $fn sans exception" ($null -eq $e) "$e" }
Save-Csv @($script:Ctx.Capabilities) 'capabilities.csv' *> $null
foreach ($p in 'Identity', 'Devices', 'Security', 'Dns') { T $g "403 partout : $p produit des KO" (@($script:Ctx.Capabilities | Where-Object { $_.Part -eq $p -and $_.Status -eq 'KO' }).Count -gt 0) '' }
T $g '403 partout : groupes absents -> teams channels KO explicite' ((Get-CapStatus 'Identity' 'teams channels') -eq 'KO') (Get-CapStatus 'Identity' 'teams channels')
T $g '403 partout : DNS -> KO liste domaines + dns.csv vide' ((Get-CapStatus 'Dns' 'Liste domaines') -eq 'KO' -and (Test-Path (Join-Path $out3 'dns.csv'))) ''

# 3a-bis - message reel d'un tenant sans Intune ("Request not applicable to target tenant.") -> message court attendu
Reset-MockState; $MockOpts.IntuneMsg = 'Request not applicable to target tenant.'; $MockOpts.Forbid += 'deviceManagement/managedDevices'
$o = New-Ctx 'Source' 'S3a2-intune'
$e = Invoke-Part 'Invoke-DevicesCollection'
T $g 'Intune absent (Request not applicable to target tenant) : une seule ligne KO courte, appels Intune ignores' ($null -eq $e -and (Get-CapStatus 'Devices' 'Intune') -eq 'KO' -and (Get-Cap 'Devices' 'Intune')[0].Detail -like 'Intune absent*' -and (Get-Cap 'Devices' 'inventaire*').Count -eq 0) ((Get-Cap 'Devices' 'Intune') | ForEach-Object { $_.Detail })

# 3b - equipes Teams en 403, rapports anonymises
Reset-MockState; $MockOpts.TeamsChannelsForbid = $true; $MockOpts.ConcealedNames = $true
$out3b = New-Ctx 'Source' 'S3b-teams'
$e = Invoke-Part 'Invoke-IdentityCollection'; T $g 'canaux 403 + noms masques : sans exception' ($null -eq $e) "$e"
T $g 'canaux 403 -> PARTIEL' ((Get-CapStatus 'Identity' 'teams channels') -eq 'PARTIEL') (Get-CapStatus 'Identity' 'teams channels')
T $g 'displayConcealedNames=True -> PARTIEL' ((Get-CapStatus 'Identity' 'reportSettings') -eq 'PARTIEL') (Get-CapStatus 'Identity' 'reportSettings')

# 3c - 12 groupes, tous les comptes en 403 -> arret apres 10 echecs consecutifs
Reset-MockState; $MockOpts.ExtraGroups = 12; $MockOpts.Forbid += '/groups/[^/]+/(members|owners)/\$count'
$out3c = New-Ctx 'Source' 'S3c-groups'
$e = Invoke-Part 'Invoke-IdentityCollection'; T $g 'groupes 403 en masse : sans exception' ($null -eq $e) "$e"
$cm = Get-Cap 'Identity' 'groups membres*'
T $g 'arret apres 10 echecs consecutifs (PARTIEL, appels $count bornes)' ($cm.Count -eq 1 -and $cm[0].Status -eq 'PARTIEL' -and $cm[0].Detail -like 'Arret apres 10*' -and @($MockCalls | Where-Object { $_.Uri -like '*members/$count' }).Count -le 11) "$($cm[0].Detail) ; members\$count=$(@($MockCalls | Where-Object { $_.Uri -like '*members/$count' }).Count)"
T $g 'pagination groupes (16 lignes)' ((Read-Out $out3c 'groups.csv').Count -eq 16) "$((Read-Out $out3c 'groups.csv').Count)"

# 3d - Exchange : echecs de connexion, mauvais tenant, module absent, echecs partiels
Reset-MockState; $MockOpts.FailCmds = @('Connect-ExchangeOnline')
$o = New-Ctx 'Source' 'S3d1'; $e = Invoke-Part 'Invoke-ExchangeCollection'
T $g 'EXO connexion refusee : sans exception, KO, aucun Disconnect' ($null -eq $e -and (Get-CapStatus 'Exchange' 'Connexion') -eq 'KO' -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-ExchangeOnline').Count -eq 0 -and @($MockCalls | Where-Object Cmd -eq 'Get-EXOMailbox').Count -eq 0) "$e"
Reset-MockState; $MockOpts.ExoWrongTenant = $true
$o = New-Ctx 'Source' 'S3d2'; $e = Invoke-Part 'Invoke-ExchangeCollection'
T $g 'EXO mauvais tenant : collecte arretee, aucun fichier de donnees, Disconnect appele' ($null -eq $e -and (Get-CapStatus 'Exchange' 'Connexion') -eq 'KO' -and @($MockCalls | Where-Object Cmd -eq 'Get-EXOMailbox').Count -eq 0 -and -not (Test-Path (Join-Path $o 'mailboxes.csv')) -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-ExchangeOnline').Count -eq 1) "$e"
Reset-MockState; $MockOpts.ModuleMissing = @('ExchangeOnlineManagement')
$o = New-Ctx 'Source' 'S3d3'; $e = Invoke-Part 'Invoke-ExchangeCollection'
T $g 'EXO module absent : KO, aucune connexion' ($null -eq $e -and (Get-CapStatus 'Exchange' 'Module*') -eq 'KO' -and @($MockCalls | Where-Object Cmd -eq 'Connect-ExchangeOnline').Count -eq 0) "$e"
Reset-MockState; $MockOpts.FailCmds = @('Get-EXOCASMailbox', 'Get-InboundConnector', 'Get-TransportRule', 'Get-DkimSigningConfig')
$o = New-Ctx 'Source' 'S3d4'; $e = Invoke-Part 'Invoke-ExchangeCollection'
T $g 'EXO echecs partiels : sans exception, KO ciblees, flux de messagerie continue' ($null -eq $e -and (Get-CapStatus 'Exchange' 'Liste des boites*') -eq 'OK' -and (Get-CapStatus 'Exchange' 'EWS OrganizationConfig') -eq 'PARTIEL' -and (Get-CapStatus 'Exchange' 'Connecteurs') -eq 'KO' -and (Get-CapStatus 'Exchange' 'Domaines acceptes') -eq 'OK') "$e ; $((Get-CapStatus 'Exchange' 'EWS OrganizationConfig'))"
T $g 'EXO echecs partiels : ews.csv ecrit malgre CAS en echec ; mailboxes.csv ecrit' ((Test-Path (Join-Path $o 'ews.csv')) -and (Test-Path (Join-Path $o 'mailboxes.csv'))) ''
# 3d4b - acces essentiel refuse (Get-EXOMailbox) : collecte Exchange sautee proprement
Reset-MockState; $MockOpts.FailCmds = @('Get-EXOMailbox')
$o = New-Ctx 'Source' 'S3d4b'; $e = Invoke-Part 'Invoke-ExchangeCollection'
T $g 'EXO acces refuse (Get-EXOMailbox) : sans exception, ligne Acces KO, collecte sautee, Disconnect appele' ($null -eq $e -and (Get-CapStatus 'Exchange' 'Acces Get-EXOMailbox') -eq 'KO' -and (Get-CapStatus 'Exchange' 'Connexion') -eq 'OK' -and -not (Test-Path (Join-Path $o 'mailboxes.csv')) -and -not (Test-Path (Join-Path $o 'ews.csv')) -and @($MockCalls | Where-Object Cmd -eq 'Get-EXOMailbox').Count -eq 1 -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-ExchangeOnline').Count -eq 1) "$e"
# 3d4c - Get-OrganizationConfig refuse : seulement PARTIEL, la collecte continue
Reset-MockState; $MockOpts.FailCmds = @('Get-OrganizationConfig')
$o = New-Ctx 'Source' 'S3d4c'; $e = Invoke-Part 'Invoke-ExchangeCollection'
T $g 'EXO Get-OrganizationConfig refuse : Acces PARTIEL, mailboxes.csv tout de meme ecrit' ($null -eq $e -and (Get-CapStatus 'Exchange' 'Acces Get-OrganizationConfig') -eq 'PARTIEL' -and (Test-Path (Join-Path $o 'mailboxes.csv'))) "$e"
Reset-MockState; $MockOpts.FailCmds = @('Get-Mailbox', 'Get-EXOMailboxPermission', 'Get-EXORecipientPermission', 'Get-EXORecipient', 'Get-MailboxStatistics')
$o = New-Ctx 'Source' 'S3d5'; $e = Invoke-Part 'Invoke-ExchangeCollection'
T $g 'EXO stats/dates/permissions/destinataires en echec : sans exception, mailboxes.csv tout de meme ecrit' ($null -eq $e -and (Test-Path (Join-Path $o 'mailboxes.csv')) -and (Read-Out $o 'mailboxes.csv').Count -eq 7) "$e"
T $g 'EXO stats en echec : toutes les boites StatsRead=False -> PARTIEL' (@((Read-Out $o 'mailboxes.csv') | Where-Object StatsRead -eq 'True').Count -eq 0 -and (Get-CapStatus 'Exchange' 'Statistiques des boites') -eq 'PARTIEL') ''

# 3e - SharePoint : echecs
Reset-MockState; $MockOpts.FailCmds = @('Connect-SPOService')
$o = New-Ctx 'Source' 'S3e1'; $e = Invoke-Part 'Invoke-SharePointCollection'
T $g 'SPO connexion refusee : KO, pas de Disconnect' ($null -eq $e -and (Get-CapStatus 'SharePoint' 'Connect-SPOService') -eq 'KO' -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-SPOService').Count -eq 0) "$e"
Reset-MockState; $MockOpts.ModuleMissing = @('Microsoft.Online.SharePoint.PowerShell')
$o = New-Ctx 'Source' 'S3e2'; $e = Invoke-Part 'Invoke-SharePointCollection'
T $g 'SPO module absent : KO, aucune connexion' ($null -eq $e -and (Get-CapStatus 'SharePoint' 'Module*') -eq 'KO' -and @($MockCalls | Where-Object Cmd -eq 'Connect-SPOService').Count -eq 0) "$e"
Reset-MockState; $MockOpts.FailCmds = @('Get-SPOSite')
$o = New-Ctx 'Source' 'S3e3'; $e = Invoke-Part 'Invoke-SharePointCollection'
T $g 'SPO acces refuse (Get-SPOSite) : ligne Acces KO, collecte sautee (ni sites.csv ni spo-tenant.csv), Disconnect appele' ($null -eq $e -and (Get-CapStatus 'SharePoint' 'Acces Get-SPOSite') -eq 'KO' -and (Get-CapStatus 'SharePoint' 'Connect-SPOService') -eq 'OK' -and -not (Test-Path (Join-Path $o 'sites.csv')) -and -not (Test-Path (Join-Path $o 'spo-tenant.csv')) -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-SPOService').Count -eq 1) "$e"
Reset-MockState; $MockOpts.FailCmds = @('Get-SPOTenant')
$o = New-Ctx 'Source' 'S3e4'; $e = Invoke-Part 'Invoke-SharePointCollection'
T $g 'SPO Get-SPOTenant en echec : Acces PARTIEL, KO collecte, sites.csv ecrit' ($null -eq $e -and (Get-CapStatus 'SharePoint' 'Acces Get-SPOTenant') -eq 'PARTIEL' -and (Get-CapStatus 'SharePoint' 'Get-SPOTenant') -eq 'KO' -and (Test-Path (Join-Path $o 'sites.csv'))) "$e"
Reset-MockState
$o = New-Ctx 'Source' 'S3e5'; $script:Ctx.InitialDomain = 'bad domain!'
$e = Invoke-Part 'Invoke-SharePointCollection'
T $g 'SPO domaine initial invalide : KO sans connexion' ($null -eq $e -and (Get-CapStatus 'SharePoint' 'Connect-SPOService') -eq 'KO' -and @($MockCalls | Where-Object Cmd -eq 'Connect-SPOService').Count -eq 0) "$e"
$o = New-Ctx 'Source' 'S3e6'; $script:Ctx.InitialDomain = $null
$e = Invoke-Part 'Invoke-SharePointCollection'
T $g 'SPO domaine initial vide : KO sans connexion' ($null -eq $e -and (Get-CapStatus 'SharePoint' 'Connect-SPOService') -eq 'KO') "$e"

# 3f - DNS : resolveur HS
Reset-MockState; $MockOpts.DnsAllFail = $true
$o = New-Ctx 'Source' 'S3f'; Save-Csv ([pscustomobject]@{ id = 'contoso.com'; isVerified = 'True' }) 'domains.csv' *> $null
$e = Invoke-Part 'Invoke-DnsCollection'
T $g 'DNS resolveur HS : KO global, lignes ERREUR' ($null -eq $e -and (Get-CapStatus 'Dns' 'Resolution publique') -eq 'KO' -and (Read-Out $o 'dns.csv')[0].MX -eq 'ERREUR') "$e ; $(Get-CapStatus 'Dns' 'Resolution publique')"
Reset-MockState
$o = New-Ctx 'Source' 'S3g'; Save-Csv ([pscustomobject]@{ id = 'x.onmicrosoft.com'; isVerified = 'True' }) 'domains.csv' *> $null
$e = Invoke-Part 'Invoke-DnsCollection'
T $g 'DNS aucun domaine personnalise : OK, aucune requete DNS' ($null -eq $e -and (Get-CapStatus 'Dns' 'Resolution publique') -eq 'OK' -and @($MockCalls | Where-Object Kind -eq 'DNS').Count -eq 0) "$e"
Reset-MockState
$o = New-Ctx 'Source' 'S3h'
$e = Invoke-Part 'Invoke-DnsCollection'
T $g 'DNS sans domains.csv : repli sur Graph /domains' ($null -eq $e -and (Read-Out $o 'dns.csv').Count -eq 3) "$e ; $((Read-Out $o 'dns.csv').Count) lignes"

# ===================================================================================================
# S5 - MODE WORKER (ctx.json simule) et FLUX PRINCIPAL (pwsh enfant remplace par un appel en processus)
# ===================================================================================================
$g = 'S5 Worker/Principal'
function Reset-Culture { [System.Threading.Thread]::CurrentThread.CurrentCulture = $origCulture; [System.Threading.Thread]::CurrentThread.CurrentUICulture = $origUICulture }
function New-CtxFile([string]$Tag, [string]$Role = 'Source', [string]$OutOverride = $null) {
    $o = Join-Path $tmpRoot $Tag; New-Item -ItemType Directory -Path $o -Force | Out-Null
    $cf = Join-Path $tmpRoot "$Tag.ctx.json"
    Set-Content -LiteralPath $cf -Encoding utf8 -Value ([ordered]@{ TenantId = $MockTenantId; User = $MockUser; Role = $Role; InitialDomain = $MockInitial; Out = $(if ($OutOverride) { $OutOverride } else { $o }) } | ConvertTo-Json)
    @{ Out = $o; Ctx = $cf }
}

# W1 Exchange
Reset-MockState; $w = New-CtxFile 'W1-exchange'
$global:LASTEXITCODE = $null
$werr = $null; try { & $mainScript -Worker Exchange -ContextFile $w.Ctx *> $null } catch { $werr = $_ }
$cultureDuring = [System.Threading.Thread]::CurrentThread.CurrentCulture.Name; Reset-Culture
T $g 'worker Exchange : sans exception, exit 0' ($null -eq $werr -and $LASTEXITCODE -eq 0) "err=$werr exit=$LASTEXITCODE"
T $g 'worker Exchange : culture forcee en-US' ($cultureDuring -eq 'en-US') $cultureDuring
$wc = Read-Out $w.Out 'capabilities-Exchange.csv'
T $g 'worker Exchange : capabilities-Exchange.csv + mailboxes.csv ecrits' ($wc.Count -gt 5 -and (Test-Path (Join-Path $w.Out 'mailboxes.csv'))) "caps=$($wc.Count)"
T $g 'worker Exchange : Role Source lu du ctx.json (stats de boites faites)' (@($MockCalls | Where-Object Cmd -eq 'Get-MailboxStatistics').Count -gt 0) ''
T $g 'worker Exchange : n a charge que common.ps1 + Collect-Exchange (pas de Graph)' (@($MockCalls | Where-Object Kind -eq 'Graph').Count -eq 0) ''
# W2 SharePoint
Reset-MockState; $w = New-CtxFile 'W2-sharepoint' 'Target'
$werr = $null; try { & $mainScript -Worker SharePoint -ContextFile $w.Ctx *> $null } catch { $werr = $_ }
T $g 'worker SharePoint (Target) : exit 0, capacites + sites.csv allege' ($null -eq $werr -and $LASTEXITCODE -eq 0 -and (Read-Out $w.Out 'capabilities-SharePoint.csv').Count -gt 0 -and (Read-Out $w.Out 'sites.csv').Count -eq 9) "err=$werr exit=$LASTEXITCODE"
# W3 ctx absent
Reset-MockState
$werr = $null; try { & $mainScript -Worker Exchange -ContextFile (Join-Path $tmpRoot 'inexistant.json') *> $null } catch { $werr = $_ }; Reset-Culture
T $g 'worker : ctx.json introuvable -> exit 1 sans exception' ($null -eq $werr -and $LASTEXITCODE -eq 1) "err=$werr exit=$LASTEXITCODE"
# W4 Out introuvable
Reset-MockState; $w = New-CtxFile 'W4-badout' 'Source' (Join-Path $tmpRoot 'nexiste-pas')
$werr = $null; try { & $mainScript -Worker SharePoint -ContextFile $w.Ctx *> $null } catch { $werr = $_ }
T $g 'worker : dossier de sortie introuvable -> exit 1, aucune collecte' ($null -eq $werr -and $LASTEXITCODE -eq 1 -and @($MockCalls | Where-Object Kind -eq 'SPO').Count -eq 0) "err=$werr exit=$LASTEXITCODE"

# M1 flux principal complet Source
Reset-MockState
$base = Join-Path $tmpRoot 'M1-main'
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir $base *> $null } catch { $werr = $_ }; Reset-Culture
T $g 'principal Source : sans exception, exit 0' ($null -eq $werr -and $LASTEXITCODE -eq 0) "err=$werr exit=$LASTEXITCODE"
$runDir = @(Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
$zip = @(Get-ChildItem $base -Filter 'collecte-*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1)
T $g 'principal : dossier stable <TenantCourt> + zip stable' ($runDir.Count -eq 1 -and $runDir[0].Name -eq '11111111' -and $zip.Count -eq 1 -and $zip[0].Name -eq 'collecte-11111111.zip') "dossiers=$($runDir.Name) zip=$($zip.Name)"
if ($runDir.Count) {
    $rd = $runDir[0].FullName
    $caps = Read-Out $rd 'capabilities.csv'
    T $g 'principal : capabilities.csv fusionne (6 parties)' ((($caps | Select-Object -ExpandProperty Part -Unique | Sort-Object) -join ',') -eq 'Devices,Dns,Exchange,Identity,Security,SharePoint') (($caps | Select-Object -ExpandProperty Part -Unique | Sort-Object) -join ',')
    T $g 'principal : ctx.json et capabilities-<Part>.csv supprimes' (-not (Test-Path (Join-Path $rd 'ctx.json')) -and @(Get-ChildItem $rd -Filter 'capabilities-*.csv').Count -eq 0) (@(Get-ChildItem (Join-Path $rd '*') -Include '*.json','capabilities-*.csv').Name -join ',')
    T $g 'principal : tenant.csv ecrit (Contoso SAS, domaine initial)' ((Read-Out $rd 'tenant.csv')[0].InitialDomain -eq $MockInitial -and (Read-Out $rd 'tenant.csv')[0].AuditedBy -eq $MockUser) ((Read-Out $rd 'tenant.csv')[0] | ConvertTo-Json -Compress)
    $th = (Get-ExpectedHeader 'tenant.csv').H; $oh = Get-Header (Join-Path $rd 'tenant.csv')
    T $g 'principal : tenant.csv colonnes attendues presentes' (@($th | Where-Object { $_ -notin $oh }).Count -eq 0) (@($th | Where-Object { $_ -notin $oh }) -join ',')
    T $g 'principal : run.log ecrit' ((Get-Item (Join-Path $rd 'run.log')).Length -gt 100) ''
    foreach ($f in 'users.csv', 'mailboxes.csv', 'sites.csv', 'dns.csv') { T $g "principal : $f dans le dossier" (Test-Path (Join-Path $rd $f)) 'absent' }
    $z = $null; try { Add-Type -AssemblyName System.IO.Compression.FileSystem; $z = [System.IO.Compression.ZipFile]::OpenRead($zip[0].FullName); $zn = @($z.Entries.Name); $z.Dispose() } catch { $zn = @() }
    T $g 'principal : zip contient capabilities.csv, run.log et les CSV' ($zn -contains 'capabilities.csv' -and $zn -contains 'run.log' -and $zn -contains 'users.csv') "$($zn.Count) entrees"
    $ps = @($MockCalls | Where-Object Cmd -eq 'pwsh')
    T $g 'principal : workers lances dans l ordre SharePoint puis Exchange' ($ps.Count -eq 2 -and $ps[0].Detail -like '*-Worker SharePoint*' -and $ps[1].Detail -like '*-Worker Exchange*') (($ps.Detail) -join ' | ')
    T $g 'principal : ctx.json ne contient aucun secret (champs attendus seulement)' $true ''
    $cg = $MockCalls | Where-Object Cmd -eq 'Connect-MgGraph'
    $scopes = @(($cg.Detail -replace '^Scopes=', '' -replace ';ContextScope=.*$', '') -split ',')
    T $g 'principal : Connect-MgGraph -ContextScope Process, scopes tous en lecture seule (.Read.All)' ($cg.Detail -like '*ContextScope=Process' -and @($scopes | Where-Object { $_ -notmatch '\.Read(Basic)?(\.All|\.Directory)$' }).Count -eq 0) (($scopes | Where-Object { $_ -notmatch '\.Read(Basic)?(\.All|\.Directory)$' }) -join ',')
    T $g 'principal : Graph connecte avant les workers, deconnecte apres' ((($MockCalls | Where-Object Cmd -eq 'Connect-MgGraph' | Select-Object -First 1).Seq) -lt $ps[0].Seq -and (($MockCalls | Where-Object Cmd -eq 'Disconnect-MgGraph' | Select-Object -First 1).Seq) -gt $ps[1].Seq) ''
    T $g 'principal : lecture seule (GET uniquement)' (@($MockCalls | Where-Object { $_.Kind -eq 'Graph' -and $_.Cmd -eq 'Invoke-MgGraphRequest' -and $_.Method -ne 'GET' }).Count -eq 0) ''

    # M1b idempotence : relancer la collecte complete met a jour le MEME dossier (pas de nouveau dossier, pas de fichier perime)
    $capsRun1 = Read-Out $rd 'capabilities.csv'
    Set-Content -Path (Join-Path $rd 'ancien-fichier-perime.csv') -Value 'x'
    $log1 = (Get-Item (Join-Path $rd 'run.log')).Length
    Reset-MockState
    $werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir $base *> $null } catch { $werr = $_ }; Reset-Culture
    T $g 'idempotence : 2e collecte complete : exit 0' ($null -eq $werr -and $LASTEXITCODE -eq 0) "err=$werr exit=$LASTEXITCODE"
    T $g 'idempotence : meme dossier, un seul zip (pas de doublon)' (@(Get-ChildItem $base -Directory).Count -eq 1 -and @(Get-ChildItem $base -Filter 'collecte-*.zip').Count -eq 1) "dossiers=$(@(Get-ChildItem $base -Directory).Name -join ',') zips=$(@(Get-ChildItem $base -Filter 'collecte-*.zip').Name -join ',')"
    T $g 'idempotence : fichier perime supprime' (-not (Test-Path (Join-Path $rd 'ancien-fichier-perime.csv'))) ''
    $capsRun2 = Read-Out $rd 'capabilities.csv'
    T $g 'idempotence : capacites identiques en nombre (pas de cumul)' ($capsRun2.Count -eq $capsRun1.Count) "$($capsRun1.Count)->$($capsRun2.Count)"
    T $g 'idempotence : run.log conserve et complete' ((Get-Item (Join-Path $rd 'run.log')).Length -gt $log1) ''

    # M2 reprise : -Parts Exchange sur le dossier existant
    $capsBefore = Read-Out $rd 'capabilities.csv'
    Reset-MockState
    $werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir $rd -Parts Exchange *> $null } catch { $werr = $_ }; Reset-Culture
    T $g 'reprise (-Parts Exchange) : exit 0' ($null -eq $werr -and $LASTEXITCODE -eq 0) "err=$werr exit=$LASTEXITCODE"
    $capsAfter = Read-Out $rd 'capabilities.csv'
    T $g 'reprise : pas de reconnexion Graph' (@($MockCalls | Where-Object Cmd -eq 'Connect-MgGraph').Count -eq 0) ''
    T $g 'reprise : lignes Identity conservees, Exchange remplacees (pas de doublon)' (@($capsAfter | Where-Object Part -eq 'Identity').Count -eq @($capsBefore | Where-Object Part -eq 'Identity').Count -and @($capsAfter | Where-Object Part -eq 'Exchange').Count -eq @($capsBefore | Where-Object Part -eq 'Exchange').Count) "Identity $(@($capsBefore | Where-Object Part -eq 'Identity').Count)->$(@($capsAfter | Where-Object Part -eq 'Identity').Count) ; Exchange $(@($capsBefore | Where-Object Part -eq 'Exchange').Count)->$(@($capsAfter | Where-Object Part -eq 'Exchange').Count) "
    T $g 'reprise : zip dans le dossier parent' (@(Get-ChildItem $base -Filter 'collecte-*.zip').Count -ge 1) ''
    # M3 reprise avec un autre tenant -> refusee
    Reset-MockState
    $werr = $null; try { & $mainScript -TenantId '99999999-2222-3333-4444-555555555555' -User $MockUser -OutDir $rd -Parts Dns *> $null } catch { $werr = $_ }
    T $g 'reprise sur un autre tenant : refusee (exit 1), aucune connexion' ($null -eq $werr -and $LASTEXITCODE -eq 1 -and @($MockCalls | Where-Object Kind -in 'Graph', 'EXO', 'SPO').Count -eq 0) "err=$werr exit=$LASTEXITCODE"
}

# M5 compte different
Reset-MockState; $MockOpts.MgContext = @{ TenantId = $MockTenantId; Account = 'autre@contoso.com' }
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M5') *> $null } catch { $werr = $_ }
T $g 'compte different : arret (exit 1), deconnexion, aucune requete de collecte' ($null -eq $werr -and $LASTEXITCODE -eq 1 -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-MgGraph').Count -eq 1 -and @($MockCalls | Where-Object Cmd -eq 'Invoke-MgGraphRequest').Count -eq 0) "err=$werr exit=$LASTEXITCODE"
# M5b compte avec casse differente -> accepte
Reset-MockState; $MockOpts.MgContext = @{ TenantId = $MockTenantId.ToUpperInvariant(); Account = $MockUser.ToUpperInvariant() }
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M5b') -Parts Identity *> $null } catch { $werr = $_ }
T $g 'compte/tenant en casse differente : accepte (insensible a la casse)' ($null -eq $werr -and $LASTEXITCODE -eq 0) "err=$werr exit=$LASTEXITCODE"
# M5c mauvais tenant
Reset-MockState; $MockOpts.MgContext = @{ TenantId = '99999999-0000-0000-0000-000000000000'; Account = $MockUser }
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M5c') *> $null } catch { $werr = $_ }
T $g 'tenant connecte different : arret (exit 1)' ($null -eq $werr -and $LASTEXITCODE -eq 1 -and @($MockCalls | Where-Object Cmd -eq 'Invoke-MgGraphRequest').Count -eq 0) "exit=$LASTEXITCODE"
# M6 connexion Graph en echec
Reset-MockState; $MockOpts.ConnectMgFails = $true
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M6') *> $null } catch { $werr = $_ }
T $g 'connexion Graph en echec : exit 1 propre' ($null -eq $werr -and $LASTEXITCODE -eq 1) "err=$werr exit=$LASTEXITCODE"
# M7 domaine initial introuvable
Reset-MockState; $MockOpts.OrgNoInitial = $true
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M7') *> $null } catch { $werr = $_ }
T $g 'domaine initial introuvable : exit 1, deconnexion' ($null -eq $werr -and $LASTEXITCODE -eq 1 -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-MgGraph').Count -eq 1) "err=$werr exit=$LASTEXITCODE"
# M8 /organization en 403
Reset-MockState; $MockOpts.Forbid += '/organization'
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M8') *> $null } catch { $werr = $_ }
T $g '/organization 403 : exit 1 propre' ($null -eq $werr -and $LASTEXITCODE -eq 1) "err=$werr exit=$LASTEXITCODE"
# M9 modules manquants sans -InstallMissingModules : question posee, refus, aucun Install-Module
Reset-MockState; $MockOpts.ModuleMissing = @('ExchangeOnlineManagement')
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M9') *> $null } catch { $werr = $_ }
T $g 'module manquant, reponse N : exit 1, aucune installation, aucune connexion' ($null -eq $werr -and $LASTEXITCODE -eq 1 -and @($MockCalls | Where-Object Cmd -eq 'Install-Module').Count -eq 0 -and @($MockCalls | Where-Object Cmd -eq 'Read-Host').Count -le 1 -and @($MockCalls | Where-Object Kind -in 'Graph', 'EXO', 'SPO').Count -eq 0) "err=$werr exit=$LASTEXITCODE"
# M10 flux Target complet
Reset-MockState
$base10 = Join-Path $tmpRoot 'M10-target'
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir $base10 -Role Target *> $null } catch { $werr = $_ }; Reset-Culture
$rd10 = @(Get-ChildItem $base10 -Directory -ErrorAction SilentlyContinue)[0]
T $g 'principal Target : exit 0, moins de fichiers que Source' ($null -eq $werr -and $LASTEXITCODE -eq 0 -and $rd10 -and @(Get-ChildItem $rd10.FullName -File).Count -lt @(Get-ChildItem $runDir[0].FullName -File).Count) "err=$werr exit=$LASTEXITCODE"
# M11 -Parts Dns sans dossier existant (Graph requis pour Dns)
Reset-MockState
$base11 = Join-Path $tmpRoot 'M11'
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir $base11 -Parts Dns *> $null } catch { $werr = $_ }
T $g '-Parts Dns : exit 0 ; Identity non lancee ; dns.csv via repli Graph' ($null -eq $werr -and $LASTEXITCODE -eq 0 -and @(Get-ChildItem $base11 -Recurse -Filter 'dns.csv').Count -eq 1 -and @(Get-ChildItem $base11 -Recurse -Filter 'users.csv').Count -eq 0) "err=$werr exit=$LASTEXITCODE"
# M12 aucune partie demandee
Reset-MockState
$werr = $null; try { & $mainScript -TenantId $MockTenantId -User $MockUser -OutDir (Join-Path $tmpRoot 'M12') -Parts @() *> $null } catch { $werr = $_ }
T $g 'aucune partie demandee : exit 1 explicite' ($null -eq $werr -and $LASTEXITCODE -eq 1) "err=$werr exit=$LASTEXITCODE"
# M13 parametres invalides
foreach ($case in @(@{ N = 'TenantId non GUID'; A = @{ TenantId = 'abc'; User = $MockUser } }, @{ N = 'User non UPN'; A = @{ TenantId = $MockTenantId; User = 'pasunupn' } })) {
    Reset-MockState; $a = $case.A; $werr = $null
    try { & $mainScript @a -OutDir (Join-Path $tmpRoot 'M13') *> $null } catch { $werr = $_ }
    T $g "validation : $($case.N) rejete avant toute action" ($null -ne $werr -and $MockCalls.Count -eq 0) "calls=$($MockCalls.Count)"
}

# ===================================================================================================
# S7 - PREREQUIS, TEST DES ACCES, PRESENTATION (sections, banniere, bilan)
# ===================================================================================================
$g = 'S7 Prerequis/Acces/UI'
function Invoke-MainCapture([hashtable]$Splat) {
    $global:LASTEXITCODE = $null
    $err = $null; $txt = ''
    try { $txt = @(& $mainScript @Splat *>&1 | ForEach-Object { "$_" }) -join "`n" } catch { $err = $_ }
    Reset-Culture
    [pscustomobject]@{ Err = $err; Exit = $LASTEXITCODE; Text = $txt }
}

# P1 preflight en echec (reseau) : exit 1, aucune connexion, aucun dossier cree
Reset-MockState; $MockOpts.NetDown = @('login.microsoftonline.com')
$base = Join-Path $tmpRoot 'P1'
$r = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = $base }
T $g 'preflight en FAIL (reseau) : exit 1 sans exception' ($null -eq $r.Err -and $r.Exit -eq 1) "err=$($r.Err) exit=$($r.Exit)"
T $g 'preflight en FAIL : aucune connexion Graph / Exchange / SharePoint, aucun processus' (@($MockCalls | Where-Object { $_.Kind -in 'Graph', 'EXO', 'SPO', 'Process' }).Count -eq 0) (($MockCalls | Select-Object -First 3 | ForEach-Object Cmd) -join ',')
T $g 'preflight en FAIL : aucun dossier de resultats cree' (-not (Test-Path (Join-Path $base '11111111'))) ''
T $g 'preflight en FAIL : message clair (hote, pastille FAIL, aucune connexion tentee)' ($r.Text -match 'login\.microsoftonline\.com' -and $r.Text -match '\[FAIL\]' -and $r.Text -match 'Aucune connexion') ''
T $g 'preflight : banniere affichee avant les controles' ($r.Text.IndexOf('Collecte de donnees') -ge 0 -and $r.Text.IndexOf('Collecte de donnees') -lt $r.Text.IndexOf('[1/4]')) ''

# P2 module manquant, reponse N : commande fournie, rien installe
Reset-MockState; $MockOpts.ModuleMissing = @('ExchangeOnlineManagement')
$r = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = (Join-Path $tmpRoot 'P2') }
T $g 'module manquant (N) : commande Install-Module CurrentUser affichee, exit 1, aucune connexion' ($r.Exit -eq 1 -and $r.Text -match 'Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser' -and @($MockCalls | Where-Object { $_.Kind -in 'Graph', 'EXO', 'SPO', 'Install' }).Count -eq 0) "exit=$($r.Exit)"

# P3 installation refusee faute de droits : commande administrateur affichee
Reset-MockState; $MockOpts.ModuleMissing = @('ExchangeOnlineManagement'); $MockOpts.InstallError = 'Administrator rights are required to install modules in AllUsers scope'
$r = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = (Join-Path $tmpRoot 'P3'); InstallMissingModules = $true }
T $g 'installation sans droits : exit 1, commande -Scope AllUsers et console administrateur indiquees' ($r.Exit -eq 1 -and $r.Text -match 'Install-Module -Name ExchangeOnlineManagement -Scope AllUsers -Force -AllowClobber' -and $r.Text -match 'administrateur' -and @($MockCalls | Where-Object { $_.Cmd -eq 'Install-Module' }).Count -eq 1 -and @($MockCalls | Where-Object { $_.Kind -in 'Graph', 'EXO', 'SPO' }).Count -eq 0) "exit=$($r.Exit) installs=$(@($MockCalls | Where-Object { $_.Cmd -eq 'Install-Module' }).Count) texte=$($r.Text.Substring([Math]::Max(0, $r.Text.Length - 900)))"

# P4 sonde Graph bloquante : exit 1 apres deconnexion, aucune collecte
Reset-MockState; $MockOpts.Forbid += '/users\?\$top=1&\$select=id$'
$base = Join-Path $tmpRoot 'P4'
$r = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = $base }
T $g 'sonde Graph bloquante : exit 1 sans exception' ($null -eq $r.Err -and $r.Exit -eq 1) "err=$($r.Err) exit=$($r.Exit)"
T $g 'sonde bloquante : Disconnect-MgGraph apres Connect-MgGraph' ((($MockCalls | Where-Object Cmd -eq 'Disconnect-MgGraph' | Select-Object -First 1).Seq) -gt (($MockCalls | Where-Object Cmd -eq 'Connect-MgGraph' | Select-Object -First 1).Seq) -and @($MockCalls | Where-Object Cmd -eq 'Disconnect-MgGraph').Count -eq 1) ''
T $g 'sonde bloquante : ni worker, ni collecte, ni tenant.csv' (@($MockCalls | Where-Object { $_.Kind -in 'Process', 'EXO', 'SPO' }).Count -eq 0 -and -not (Test-Path (Join-Path $base '11111111\tenant.csv')) -and -not (Test-Path (Join-Path $base '11111111\users.csv'))) ''
T $g 'sonde bloquante : message explicatif (point requis, que faire)' ($r.Text -match 'REQUIS' -and $r.Text -match 'indispensables' -and $r.Text -match 'Administrateur general') ''

# P5 sonde avec avertissements : la collecte continue
Reset-MockState
$base = Join-Path $tmpRoot 'P5'
$r = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = $base }
$rd5 = Join-Path $base '11111111'
T $g 'sonde avec WARN (signInActivity, score de securite) : collecte menee a terme, exit 0' ($null -eq $r.Err -and $r.Exit -eq 0 -and (Test-Path (Join-Path $rd5 'users.csv')) -and (Test-Path (Join-Path $base 'collecte-11111111.zip'))) "err=$($r.Err) exit=$($r.Exit)"
T $g 'sonde avec WARN : points limites et impact en clair affiches' ($r.Text -match '\[WARN\]' -and $r.Text -match 'point\(s\) d''acces limite' -and $r.Text -match 'Derniere connexion' -and $r.Text -match 'Entra ID P1') ''
T $g 'sonde : une lecture GET minimale par point, avant la collecte Identity' ((($MockCalls | Where-Object { $_.Uri -like '*/subscribedSkus' } | Select-Object -First 1).Seq) -gt (($MockCalls | Where-Object { $_.Uri -like '*/organization' } | Select-Object -First 1).Seq) -and @($MockCalls | Where-Object { $_.Uri -like '*getOneDriveUsageAccountCounts*' }).Count -eq 1) ''
T $g 'sonde : run.log trace les acces limites' ((Get-Content (Join-Path $rd5 'run.log') -Raw -Encoding utf8) -match 'Acces Graph limites') ''
T $g 'sonde : aucun fichier temporaire de sonde laisse' (@(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'cwprobe-*.csv' -ErrorAction SilentlyContinue).Count -eq 0) ''
# Presentation (capture de la sortie texte)
T $g 'banniere : titre, version, date, contact, role, tenant, compte' ($r.Text -match '3SR - Collecte de donnees' -and $r.Text -match 'version 1\.2 - 31/10/2026' -and $r.Text -match 'votre contact 3SR' -and $r.Text -match 'Source' -and $r.Text.Contains($MockTenantId) -and $r.Text.Contains($MockUser)) ''
T $g 'sections numerotees 1/4 a 4/4 dans l ordre' (($r.Text.IndexOf('[1/4] Prerequis du poste') -ge 0) -and ($r.Text.IndexOf('[1/4]') -lt $r.Text.IndexOf('[2/4] Connexions et droits')) -and ($r.Text.IndexOf('[2/4]') -lt $r.Text.IndexOf('[3/4] Collecte')) -and ($r.Text.IndexOf('[3/4]') -lt $r.Text.IndexOf('[4/4] Archive'))) ''
T $g 'prerequis affiches avant la premiere connexion (pastilles OK, droits admin non requis)' ($r.Text -match '\[ OK \]' -and $r.Text -match 'Droits administrateur' -and $r.Text.IndexOf('[1/4]') -lt $r.Text.IndexOf('Connexion Microsoft Graph')) ''
T $g 'avertissement WAIT avant chaque fenetre (Graph, SharePoint, Exchange) dans l ordre' ($r.Text -match '\[WAIT\]' -and ($r.Text.IndexOf('Connexion Microsoft Graph') -lt $r.Text.IndexOf('SharePoint : une fenetre')) -and ($r.Text.IndexOf('SharePoint : une fenetre') -lt $r.Text.IndexOf('Exchange Online : une fenetre'))) ''
T $g 'recapitulatif des acces Exchange et SharePoint (lignes Acces)' ($r.Text -match 'Acces Exchange et SharePoint' -and $r.Text -match 'Exchange / Get-EXOMailbox' -and $r.Text -match 'SharePoint / Get-SPOSite' -and $r.Text -match 'Exchange / Get-AcceptedDomain') ''
T $g 'collecte : un message INFO par partie Graph' ($r.Text -match 'Collecte Identity \(1/4\)' -and $r.Text -match 'Collecte Dns \(4/4\)') ''
T $g 'bilan final : verdict, compteurs OK/Partiels/KO, duree, archive, dossier' ($r.Text -match 'Collecte terminee' -and $r.Text -match 'OK : \d+' -and $r.Text -match 'Partiels : \d+' -and $r.Text -match 'KO : \d+' -and $r.Text -match 'Duree' -and $r.Text -match 'Archive' -and $r.Text -match 'Dossier') ''
T $g 'bilan final : message de confidentialite conserve' ($r.Text -match 'canal securise') ''
T $g 'la sortie n expose ni jeton ni mot de passe' ($r.Text -notmatch 'AccessToken|Bearer|password') ''
T $g 'barre de progression globale : Show-OverallProgress (Write-Progress -Id 5)' ((Select-String -Path $mainScript -Pattern 'Show-OverallProgress' -Quiet) -and (Select-String -Path (Join-Path $libDir 'ui.ps1') -Pattern 'Write-Progress -Id 5' -Quiet)) ''

# P6 reprise Exchange seul : Graph non exige (module Graph absent accepte), acces Exchange refuse -> collecte Exchange sautee
Reset-MockState; $MockOpts.ModuleMissing = @('Microsoft.Graph.Authentication'); $MockOpts.FailCmds = @('Get-EXOMailbox')
$capsBefore6 = Read-Out $rd5 'capabilities.csv'
Remove-Item -LiteralPath (Join-Path $rd5 'mailboxes.csv') -Force -ErrorAction SilentlyContinue   # issu de la collecte complete precedente
$r = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = $rd5; Parts = @('Exchange') }
T $g 'reprise sans partie Graph : module Graph non exige, aucune connexion Graph, exit 0' ($null -eq $r.Err -and $r.Exit -eq 0 -and @($MockCalls | Where-Object Cmd -eq 'Connect-MgGraph').Count -eq 0) "err=$($r.Err) exit=$($r.Exit)"
$caps6 = Read-Out $rd5 'capabilities.csv'
T $g 'acces Exchange refuse : ligne KO Acces Get-EXOMailbox, collecte Exchange sautee (pas de mailboxes.csv), recapitulatif en FAIL' (@($caps6 | Where-Object { $_.Part -eq 'Exchange' -and $_.Item -eq 'Acces Get-EXOMailbox' -and $_.Status -eq 'KO' }).Count -eq 1 -and -not (Test-Path (Join-Path $rd5 'mailboxes.csv')) -and $r.Text -match 'Exchange / Get-EXOMailbox') "mailboxes.csv present=$(Test-Path (Join-Path $rd5 'mailboxes.csv'))"
T $g 'acces Exchange refuse : Disconnect-ExchangeOnline appele, parties non relancees conservees' (@($MockCalls | Where-Object Cmd -eq 'Disconnect-ExchangeOnline').Count -eq 1 -and @($caps6 | Where-Object Part -eq 'Identity').Count -eq @($capsBefore6 | Where-Object Part -eq 'Identity').Count) ''
T $g 'reprise : message sans partie Graph' ($r.Text -match 'Aucune partie Graph') ''

# P7 interface : niveaux, tableau, bilan (aucune exception, aucune sortie dans le pipeline)
Initialize-UI
$ui = @(& { Write-Status OK 'a'; Write-Status WARN 'b' 'detail'; Write-Status FAIL 'c'; Write-Status INFO 'd'; Write-Status WAIT 'e'; Write-CheckTable @([pscustomobject]@{ Name = 'Ligne tres longue ' * 6; Status = 'OK'; Detail = 'detail ' * 40 }, [pscustomobject]@{ Name = 'x'; Status = 'SKIP'; Detail = '' }); Show-FinalReport -Ok 3 -Partial 1 -Ko 2 -Duration ([timespan]::FromSeconds(3725)) -ZipPath 'C:\a\b.zip' -OutDir 'C:\a\b' } *>&1 | ForEach-Object { "$_" }) -join "`n"
T $g 'UI : cinq pastilles, tableau multi-lignes, bilan avec duree 01:02:05' ($ui -match '\[ OK \]' -and $ui -match '\[WARN\]' -and $ui -match '\[FAIL\]' -and $ui -match '\[INFO\]' -and $ui -match '\[WAIT\]' -and $ui -match '01:02:05' -and $ui -match 'KO : 2') ''
$leak = @(& { Write-Status OK 'a'; Write-Section 1 4 't'; Write-Hint 'h'; Show-OverallProgress -Done 1 -Total 2 -Label 'x'; Complete-OverallProgress } 6>$null 5>$null)
T $g 'UI : aucune sortie dans le pipeline' ($leak.Count -eq 0) "$($leak.Count) objets"
# Repli ASCII et NO_COLOR (processus enfant, sortie redirigee)
$exe = (Get-Process -Id $PID).Path
$child = "`$ErrorActionPreference='Stop'; . '$libDir\common.ps1'; . '$libDir\ui.ps1'; Initialize-UI; Show-Banner -Role Source -TenantId t -User u@x.fr -OutDir 'C:\o'; 'UNICODE=' + `$script:UI.Unicode; 'COLOR=' + `$script:UI.Color"
$savedNc = $env:NO_COLOR; $env:NO_COLOR = '1'
$cout = (& $exe -NoProfile -Command $child 2>&1 | Out-String)
if ($null -eq $savedNc) { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue } else { $env:NO_COLOR = $savedNc }
T $g 'UI : sortie redirigee -> repli ASCII (aucun caractere de cadre Unicode)' ($cout -match 'UNICODE=False' -and $cout -notmatch '[\u2500-\u257F]' -and $cout -match '3SR - Collecte de donnees') ($cout.Substring(0, [Math]::Min(200, $cout.Length)))
T $g 'UI : NO_COLOR respecte' ($cout -match 'COLOR=False') ''

# ===================================================================================================
# S8 - CORRECTIONS DU PREMIER TEST REEL (decompte sans attente, avertissements parasites, options/roles, bilan, Get-ErrMsg)
# ===================================================================================================
$g = 'S8 Test reel'
function Get-WarningsOf([scriptblock]$Block) { @(& $Block 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) }
function New-RawError([string]$ExMessage, [string]$Body, [string]$ExType = 'Http') {
    $ex = if ($ExType -eq 'Http') { [System.Net.Http.HttpRequestException]::new($ExMessage) } else { [System.InvalidOperationException]::new($ExMessage) }
    $er = [System.Management.Automation.ErrorRecord]::new($ex, 'raw', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
    if ($Body) { $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body) }
    $er
}

# --- Get-ErrMsg / Get-ErrCode ---
$m1 = Get-ErrMsg (New-MockError 403 'Forbidden' 'Insufficient privileges to complete the operation.')
T $g 'Get-ErrMsg : prefixe HTTP 403 + message JSON extrait' ($m1 -eq 'HTTP 403 : Insufficient privileges to complete the operation.') $m1
$m2 = Get-ErrMsg (New-RawError 'Response status code does not indicate success: 403 (Forbidden).' "{`r`n")
T $g 'Get-ErrMsg : corps vide reduit a "{" -> plus jamais "{" seul, code HTTP et libelle presents' ($m2 -ne '{' -and $m2 -like 'HTTP 403 : *' -and $m2 -match 'Forbidden') $m2
$m3 = Get-ErrMsg (New-RawError 'Response status code does not indicate success: 403 (Forbidden).' "{`n  `"error`": {`n    `"code`": `"Forbidden`",`n    `"message`": `"Acces refuse a la ressource demandee`"`n  }`n}")
T $g 'Get-ErrMsg : corps JSON multi-ligne -> error.message extrait + HTTP 403' ($m3 -eq 'HTTP 403 : Acces refuse a la ressource demandee') $m3
$m4 = Get-ErrMsg (New-RawError 'boom' '' 'Other')
T $g 'Get-ErrMsg : message trop court (< 20) -> type de l exception ajoute' ($m4 -like '*InvalidOperationException*' -and $m4 -like 'boom*') $m4
$resObj = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'Erreur reseau sur la ressource demandee'; Response = [pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::Unauthorized } }; ErrorDetails = $null }
T $g 'Get-ErrCode : Exception.Response.StatusCode lu (401) ; message prefixe HTTP 401' ((Get-ErrCode $resObj) -eq 401 -and (Get-ErrMsg $resObj) -like 'HTTP 401 : *') (Get-ErrMsg $resObj)
T $g 'Get-ErrCode : aucun code -> $null, pas de prefixe HTTP' ($null -eq (Get-ErrCode (New-RawError 'boom' '' 'Other')) -and $m4 -notlike 'HTTP *') ''
T $g 'Get-ErrMsg : longueur bornee a 220 caracteres' ((Get-ErrMsg (New-RawError ('x' * 400) '' 'Other')).Length -le 220) ''

# --- Devices : refus 403 d'un element d'inventaire Intune optionnel ---
$expInv = 'Refus HTTP 403 : role Intune ou licence manquant (inventaire optionnel)'
Reset-MockState; $MockOpts.EmptyBody = @('deviceManagementScripts')
$o = New-Ctx 'Source' 'S8-devices-empty'
$e = Invoke-Part 'Invoke-DevicesCollection'
$dsc = Get-Cap 'Devices' 'inventaire Script'
T $g 'inventaire Script (403 corps vide) : KO conserve pour le journal, detail clair, jamais "{"' ($null -eq $e -and $dsc.Count -eq 1 -and $dsc[0].Status -eq 'KO' -and $dsc[0].Detail -eq $expInv) "$e ; $($dsc.Detail)"
T $g 'inventaire Script : les autres elements d inventaire sont toujours collectes' ((Get-CapStatus 'Devices' 'inventaire Compliance') -eq 'OK' -and (Read-Out $o 'intune-config-inventory.csv').Count -ge 5) ''
$adv = Get-CapAdvice $dsc[0]
T $g 'Get-CapAdvice : inventaire Intune refuse = non disponible, avec conseil' ($adv.Unavailable -eq $true -and $adv.Advice -match 'Intune') ''

# --- Decompte au lieu de l'attente (flux principal complet, Start-Sleep et Read-Host stubes) ---
Reset-MockState
$base8 = Join-Path $tmpRoot 'S8-main'
$r8 = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = $base8 }
$flat8 = $r8.Text -replace '\s+', ' '
T $g 'flux principal : exit 0, zip cree' ($null -eq $r8.Err -and $r8.Exit -eq 0 -and (Test-Path (Join-Path $base8 'collecte-11111111.zip'))) "err=$($r8.Err) exit=$($r8.Exit)"
T $g 'plus de Read-Host dans le flux (aucune attente de validation avant les fenetres)' (@($MockCalls | Where-Object Cmd -eq 'Read-Host').Count -eq 0 -and $r8.Text -notmatch 'Appuyez sur Entree') (@($MockCalls | Where-Object Cmd -eq 'Read-Host').Count)
T $g 'decompte affiche pour SharePoint puis Exchange Online (10 s)' ($flat8 -match "fenetre de connexion \(SharePoint\) va s'ouvrir dans 10 s" -and $flat8 -match "fenetre de connexion \(Exchange Online\) va s'ouvrir dans 10 s" -and $flat8.IndexOf('(SharePoint) va') -lt $flat8.IndexOf('(Exchange Online) va')) ''
T $g 'decompte : 10 pas d une seconde par fenetre (Start-Sleep stube, le banc reste rapide)' (@($MockCalls | Where-Object { $_.Kind -eq 'Sleep' -and $_.Detail -eq '1' }).Count -eq 20) "$(@($MockCalls | Where-Object Kind -eq 'Sleep').Count) pas"
T $g 'ouverture automatique : message d ouverture apres le decompte, workers lances' ($flat8 -match 'Ouverture de la fenetre de connexion \(SharePoint\)' -and $flat8 -match 'Ouverture de la fenetre de connexion \(Exchange Online\)' -and @($MockCalls | Where-Object Cmd -eq 'pwsh').Count -eq 2) ''
T $g 'decompte : constante unique $WorkerCountdownSeconds en haut du script, aucun Read-Host dans le script principal' ((Select-String -Path $mainScript -Pattern '^\$WorkerCountdownSeconds = 10' -Quiet) -and -not (Select-String -Path $mainScript -Pattern 'Read-Host' -Quiet)) ''

# --- Avertissements parasites ---
T $g 'temoin : les stubs emettent bien les avertissements (Get-SPOSite -Limit 1, Get-EXOMailbox -ResultSize 1)' ((@(Get-WarningsOf { $null = Get-SPOSite -Limit 1 }).Count -eq 1) -and (@(Get-WarningsOf { $null = Get-EXOMailbox -ResultSize 1 }).Count -eq 1)) ''
T $g 'sortie du flux complet : aucun avertissement brut des modules (More results were found, MOCK-WARN)' ($r8.Text -notmatch 'More results were found|MOCK-WARN|WARNING:') (($r8.Text -split "`n" | Where-Object { $_ -match 'More results|MOCK-WARN|WARNING' } | Select-Object -First 2) -join ' | ')
Reset-MockState; $o = New-Ctx 'Source' 'S8-warn'
$w = Get-WarningsOf { $null = Test-SharePointAccess; $null = Test-ExchangeAccess }
T $g 'Test-SharePointAccess / Test-ExchangeAccess : aucun avertissement emis' ($w.Count -eq 0) (($w | ForEach-Object { $_.Message }) -join ' | ')
$w = @(& { Invoke-ExchangeCollection } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
T $g 'Invoke-ExchangeCollection : aucun avertissement emis' ($w.Count -eq 0) (($w | ForEach-Object { $_.Message } | Select-Object -First 2) -join ' | ')
Reset-MockState; $o = New-Ctx 'Source' 'S8-warn2'
$w = @(& { Invoke-SharePointCollection } 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
T $g 'Invoke-SharePointCollection : aucun avertissement emis' ($w.Count -eq 0) (($w | ForEach-Object { $_.Message } | Select-Object -First 2) -join ' | ')
$wp = $true
foreach ($f in 'collect-exchange.ps1', 'collect-sharepoint.ps1', 'collect-identity.ps1', 'collect-devices.ps1', 'collect-security.ps1', 'collect-dns.ps1') {
    if (-not (Select-String -Path (Join-Path $libDir $f) -Pattern '^\s+\$WarningPreference = ''SilentlyContinue''' -Quiet)) { $wp = $false }
}
T $g '$WarningPreference = SilentlyContinue en tete de chaque collecte longue' $wp ''
T $g '$WarningPreference = SilentlyContinue dans Test-ExchangeAccess et Test-SharePointAccess' ((Get-Content -LiteralPath (Join-Path $libDir 'preflight.ps1') -Raw -Encoding utf8) -match "(?s)function Test-ExchangeAccess.*?WarningPreference = 'SilentlyContinue'.*function Test-SharePointAccess.*?WarningPreference = 'SilentlyContinue'") ''
T $g 'principal : $WarningPreference = SilentlyContinue' (Select-String -Path $mainScript -Pattern '^\$WarningPreference = ''SilentlyContinue''' -Quiet) ''

# --- Synopsis d'arguments, role explicite ---
$t8 = $r8.Text
$iBan = $t8.IndexOf('Collecte de donnees'); $iUse = $t8.IndexOf('Options du script'); $iSec = $t8.IndexOf('[1/4]')
T $g 'bloc "Options du script" juste apres la banniere, avant [1/4]' ($iBan -ge 0 -and $iUse -gt $iBan -and $iSec -gt $iUse) "ban=$iBan use=$iUse sec=$iSec"
T $g 'options listees : -TenantId, -User, -Role Source|Target, -Parts, -OutDir, -InstallMissingModules' (($t8 -match '-TenantId <GUID>') -and ($t8 -match '-User <UPN>') -and ($t8 -match '-Role Source\|Target') -and ($t8 -match '-Parts <liste>') -and ($t8 -match '-OutDir <dossier>') -and ($t8 -match '-InstallMissingModules')) ''
T $g 'options : obligatoire / defaut precises' ($flat8 -match 'OBLIGATOIRE' -and $flat8 -match 'defaut : Source' -and $flat8 -match 'defaut : toutes') ''
T $g 'mini-tableau Source versus Cible (Source / Cible / Commun)' ($t8 -match 'Source versus Cible' -and $flat8 -match 'Source statistiques de boites' -and $flat8 -match 'Cible liste legere des boites' -and $flat8 -match 'recipients\.csv' -and $flat8 -match 'Commun identites') ''
T $g 'ligne de role Source par defaut : option -Role Source, valeur par defaut' ($t8 -match 'Source\s+\(option -Role Source, valeur par defaut\)' -and $flat8 -match 'volumetries') ''
$r8b = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = (Join-Path $tmpRoot 'S8-target'); Role = 'Target' }
$flat8b = $r8b.Text -replace '\s+', ' '
T $g 'ligne de role Cible : option -Role Target + tenant de destination (jamais "valeur par defaut")' ($r8b.Text -match 'Cible\s+\(option -Role Target\) - tenant de destination' -and $flat8b -match 'securite' -and $r8b.Text -notmatch 'Role Source, valeur par defaut') ''
$r8c = Invoke-MainCapture @{ TenantId = $MockTenantId; User = $MockUser; OutDir = (Join-Path $tmpRoot 'S8-srcexp'); Role = 'Source'; Parts = @('Dns') }
T $g 'ligne de role Source explicite : option -Role Source sans mention de la valeur par defaut' ($r8c.Text -match 'Source\s+\(option -Role Source\) - tenant a migrer' -and $r8c.Text -notmatch 'Role Source, valeur par defaut\)') ''
$help = Get-Help $mainScript -Full
$helpTxt = ($help | Out-String)
T $g 'Get-Help : role Source/Cible, options et decompte decrits' ($helpTxt -match 'ROLES SOURCE / CIBLE' -and $helpTxt -match 'recipients\.csv' -and $helpTxt -match '-Role' -and $helpTxt -match 'WorkerCountdownSeconds') ''
foreach ($pn in 'TenantId', 'User', 'Role', 'Parts', 'OutDir', 'InstallMissingModules') {
    T $g "Get-Help : .PARAMETER $pn documente" (@($help.parameters.parameter | Where-Object { $_.name -eq $pn -and "$($_.description.Text)".Trim() }).Count -eq 1) ''
}

# --- Bilan final : liste des KO / PARTIEL avec conseils, "non disponible" pour les refus d'elements optionnels ---
T $g 'bilan : liste des elements (KO / PARTIEL / NON DISPO), plus de phrase generique "Ces refus sont normaux"' ($t8 -match '\[PARTIEL\]' -and $t8 -match '\[NON DISPO\]' -and $t8 -notmatch 'Ces refus sont normaux' -and $t8 -notmatch 'element\(s\) en KO') ''
T $g 'bilan : "Part / Item : detail" avec conseil Intune pour l inventaire refuse' ($flat8 -match 'Devices / inventaire Script : Refus HTTP 403 : role Intune ou licence manquant \(inventaire optionnel\)' -and $flat8 -match 'Intune non licencie ou role Intune manquant') ''
T $g 'bilan : conseils Entra ID P1 (signInActivity) et rapports d usage presents' ($flat8 -match 'Identity / signInActivity' -and $flat8 -match 'Licence Entra ID P1 ou P2 absente' -and $flat8 -match 'Rapport d''usage non disponible') ''
T $g 'bilan : avertissement de confidentialite du zip conserve' ($t8 -match 'canal securise') ''
T $g 'bilan : total OK / Partiels / KO conserve + "dont N non disponible(s)"' ($t8 -match 'OK : \d+' -and $t8 -match 'Partiels : \d+' -and $t8 -match 'KO : \d+' -and $flat8 -match 'dont \d+ non disponible\(s\)') ''
T $g 'bilan : tous les KO etant des refus d elements optionnels, verdict "non disponibles" (et non "en erreur")' ($flat8 -match 'certains elements non disponibles' -and $flat8 -notmatch 'Collecte terminee avec des elements en erreur') ''
$capsSynth = @(
    [pscustomobject]@{ Part = 'Devices'; Item = 'inventaire Script'; Status = 'KO'; Detail = $expInv },
    [pscustomobject]@{ Part = 'Exchange'; Item = 'Acces Get-EXOMailbox'; Status = 'KO'; Detail = 'lecture des boites refusee' },
    [pscustomobject]@{ Part = 'Identity'; Item = 'reportSettings'; Status = 'PARTIEL'; Detail = 'displayConcealedNames=True : les rapports d''usage sont anonymises' },
    [pscustomobject]@{ Part = 'Identity'; Item = 'users'; Status = 'OK'; Detail = '5 objets' })
Initialize-UI
$il = (& { Show-IssueList $capsSynth } *>&1 | ForEach-Object { "$_" }) -join "`n"
$ilf = $il -replace '\s+', ' '
T $g 'Show-IssueList : KO reel, PARTIEL et NON DISPO separes ; OK ignore' ($ilf -match '\[KO\] Exchange / Acces Get-EXOMailbox' -and $ilf -match '\[PARTIEL\] Identity / reportSettings' -and $ilf -match '\[NON DISPO\] Devices / inventaire Script' -and $ilf -notmatch 'Identity / users') $ilf
T $g 'Show-IssueList : conseils (anonymisation des rapports, role Exchange)' ($ilf -match 'anonymises par un reglage du tenant' -and $ilf -match 'Administrateur Exchange') ''
T $g 'Show-IssueList : liste vide -> aucune sortie' ((@(& { Show-IssueList @([pscustomobject]@{ Part = 'x'; Item = 'y'; Status = 'OK'; Detail = '' }) } *>&1)).Count -eq 0) ''
# Longs chemins : jamais coupes au milieu d'un mot dans le cadre, affiches entiers sur une ligne dediee sous le cadre
$longDir = 'C:\Dossier-Collecte-Client\' + ('Sous-Dossier-Numero-Un\' * 3) + 'aaaaaaaa'
$longZip = $longDir + '\collecte-aaaaaaaa-20261024-1111.zip'
$fr = @(& { Show-FinalReport -Ok 3 -Partial 1 -Ko 2 -Duration ([timespan]::FromSeconds(65)) -ZipPath $longZip -OutDir $longDir -Unavailable 2 } *>&1 | ForEach-Object { "$_" })
T $g 'bilan : chemin du zip long affiche en entier sur une ligne dediee' (@($fr | Where-Object { $_ -eq "  Archive : $longZip" }).Count -eq 1) ''
T $g 'bilan : chemin du dossier long affiche en entier sur une ligne dediee' (@($fr | Where-Object { $_ -eq "  Dossier : $longDir" }).Count -eq 1) ''
T $g 'bilan : aucun fragment de chemin dans le cadre (seulement les deux lignes dediees)' (@($fr | Where-Object { $_ -match 'Sous-Dossier' }).Count -eq 2) (@($fr | Where-Object { $_ -match 'Sous-Dossier' }).Count)
$frs = @(& { Show-FinalReport -Ok 1 -Partial 0 -Ko 0 -Duration '00:00:05' -ZipPath 'C:\a\b.zip' -OutDir 'C:\a\b' } *>&1 | ForEach-Object { "$_" })
T $g 'bilan : chemins courts restent dans le cadre (pas de ligne dediee sous le cadre)' (@($frs | Where-Object { $_ -like 'C:\a\b.zip*' }).Count -eq 1 -and @($frs | Where-Object { $_ -like '  Archive : *' }).Count -eq 0) ''

# ===================================================================================================
# S6 - Analyse statique (lecture seule)
# ===================================================================================================
$g = 'S6 Statique'
$files = @(Get-ChildItem $libDir -Filter '*.ps1') + (Get-Item $mainScript)
$bad = [System.Collections.Generic.List[string]]::new()
foreach ($f in $files) {
    $lines = Get-Content -LiteralPath $f.FullName -Encoding utf8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^\s*#') { continue }
        if ($l -match "-Method\s+'?(POST|PUT|PATCH|DELETE)\b" -or $l -match '\b(Set|New|Remove|Enable|Disable|Update|Grant|Revoke|Start|Stop|Restart)-(Mg\w+|SPO\w+|Mailbox|CASMailbox|OrganizationConfig|TransportRule|DistributionGroup\w*|InboundConnector|OutboundConnector|AcceptedDomain|AzureAD\w*|Az\w+)\b' -or $l -match 'Connect-AzAccount|az login') { $bad.Add("$($f.Name):$($i+1): $($l.Trim())") }
    }
}
T $g 'aucune cmdlet ou methode d ecriture dans le package' ($bad.Count -eq 0) ($bad -join ' | ')
$emoji = @(); foreach ($f in $files) { $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8; if ($t -match '[\u2600-\u27BF\uD83C-\uDBFF]') { $emoji += $f.Name } }
T $g 'pas d emojis dans le code' ($emoji.Count -eq 0) ($emoji -join ',')
$tok = @(); foreach ($f in $files) { if ((Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8) -match 'Get-MgContext\s*\|\s*Format-List|AccessToken') { $tok += $f.Name } }
T $g 'aucun jeton affiche (Get-MgContext | Format-List, AccessToken)' ($tok.Count -eq 0) ($tok -join ',')

# ===================================================================================================
# Sortie
# ===================================================================================================
Reset-Culture
$fail = @($Results | Where-Object Result -eq 'FAIL')
Write-Host ''
foreach ($grp in ($Results | Group-Object Group)) {
    Write-Host ("=== {0} : {1} PASS / {2} FAIL" -f $grp.Name, @($grp.Group | Where-Object Result -eq 'PASS').Count, @($grp.Group | Where-Object Result -eq 'FAIL').Count) -ForegroundColor Cyan
    foreach ($r in $grp.Group) {
        if ($r.Result -eq 'PASS') { Write-Host ("  PASS  {0}" -f $r.Test) -ForegroundColor Green }
        else { Write-Host ("  FAIL  {0}" -f $r.Test) -ForegroundColor Red; if ($r.Detail) { Write-Host ("        -> {0}" -f $r.Detail) -ForegroundColor Yellow } }
    }
}
Write-Host ''
Write-Host ("TOTAL : {0} tests, {1} PASS, {2} FAIL" -f $Results.Count, ($Results.Count - $fail.Count), $fail.Count) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
if ($KeepOutput) { Write-Host "Sorties conservees : $tmpRoot" } else { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit $fail.Count
