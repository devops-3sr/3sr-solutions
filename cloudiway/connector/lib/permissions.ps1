# permissions.ps1 - matrice charges de travail -> permissions / roles Entra / produits Cloudiway.
# Dot-sourcee par le script principal.
#
# SOURCES de la matrice :
#   - documentation Cloudiway "Connectors and prerequisites" du 2026-09-23 (articles help.cloudiway.com 2025-01 a 2026-09) ;
#   - verifiee dans la documentation en ligne le 2026-10-31 : help.cloudiway.com
#     "How to Create an EntraID Application" (2025-01-08), "Assign Exchange Role to an Entra ID Application" (2025-01-15),
#     "Compliance with mandatory MFA" (2026-09-09).
# Cette table est volontairement une DONNEE : pour ajouter ou retirer une permission, modifier uniquement
# les listes ci-dessous. Les identifiants de roles d'application ne sont JAMAIS codes en dur : ils sont
# resolus a l'execution par NOM depuis appRoles / oauth2PermissionScopes du principal de service de la ressource.
# Pas de DELETE, pas d'appel reseau dans ce fichier.

# --- Ressources (appId publics Microsoft) ---
$script:ResourceAppIds = [ordered]@{
    Graph      = '00000003-0000-0000-c000-000000000000'
    Exchange   = '00000002-0000-0ff1-ce00-000000000000'   # Office 365 Exchange Online
    SharePoint = '00000003-0000-0ff1-ce00-000000000000'   # Office 365 SharePoint Online
}

# --- Charges de travail reconnues ---
# FreeBusy, Signature et MailRouting sont des charges OPTIONNELLES (V2), jamais cochees par defaut.
$script:KnownWorkloads = @('Mail', 'Archive', 'OneDrive', 'SharePoint', 'Teams', 'GalSync', 'Intune', 'FreeBusy', 'Signature', 'MailRouting')

# --- Matrice des permissions d'APPLICATION : Mode -> Charge -> Ressource -> noms ---
# Seules les permissions d'APPLICATION figurent ici. Les portees deleguees sont limitees a User.Read et a la liste
# explicite $script:ExplicitDelegatedScopes ci-dessous (pas de copie automatique des permissions d'application).
$script:PermissionMatrix = @{
    Source = @{
        Mail       = @{ Graph = @('MailboxSettings.ReadWrite'); Exchange = @('Exchange.ManageAsApp', 'full_access_as_app'); SharePoint = @() }
        Archive    = @{ Graph = @('MailboxSettings.ReadWrite'); Exchange = @('Exchange.ManageAsApp', 'full_access_as_app'); SharePoint = @() }
        OneDrive   = @{ Graph = @('User.Read.All', 'Files.ReadWrite.All', 'Sites.FullControl.All', 'Directory.Read.All'); Exchange = @(); SharePoint = @('Sites.FullControl.All', 'User.Read.All') }
        SharePoint = @{ Graph = @('Sites.FullControl.All', 'User.Read.All', 'Group.Read.All', 'Directory.Read.All'); Exchange = @(); SharePoint = @('Sites.FullControl.All', 'User.Read.All') }
        Teams      = @{ Graph = @('Group.Read.All', 'ChannelMessage.Read.All', 'ChannelMember.ReadWrite.All', 'Chat.Read.All', 'Tasks.Read.All', 'Files.ReadWrite.All', 'Sites.FullControl.All', 'Directory.Read.All', 'User.Read.All'); Exchange = @(); SharePoint = @() }
        GalSync    = @{ Graph = @('User.ReadWrite.All', 'Group.Read.All', 'OrgContact.Read.All', 'Directory.Read.All', 'User.Invite.All'); Exchange = @(); SharePoint = @() }
        Intune     = @{ Graph = @('DeviceManagementApps.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'Policy.ReadWrite.ConditionalAccess', 'Agreement.ReadWrite.All', 'Device.ReadWrite.All', 'Group.Read.All', 'Organization.Read.All'); Exchange = @(); SharePoint = @() }
        FreeBusy   = @{ Graph = @('Calendars.Read'); Exchange = @(); SharePoint = @() }
        Signature  = @{ Graph = @(); Exchange = @(); SharePoint = @() }
        MailRouting = @{ Graph = @(); Exchange = @(); SharePoint = @() }
    }
    Target = @{
        Mail       = @{ Graph = @('MailboxSettings.ReadWrite'); Exchange = @('full_access_as_app', 'Exchange.ManageAsApp'); SharePoint = @() }
        Archive    = @{ Graph = @('MailboxSettings.ReadWrite'); Exchange = @('full_access_as_app', 'Exchange.ManageAsApp'); SharePoint = @() }
        OneDrive   = @{ Graph = @('User.Read.All', 'Files.ReadWrite.All', 'Sites.FullControl.All', 'InformationProtectionPolicy.Read.All', 'Group.ReadWrite.All', 'Directory.Read.All'); Exchange = @('Exchange.ManageAsApp'); SharePoint = @('Sites.FullControl.All', 'User.ReadWrite.All') }
        SharePoint = @{ Graph = @('Sites.FullControl.All', 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Application.ReadWrite.All', 'Directory.Read.All'); Exchange = @(); SharePoint = @('Sites.FullControl.All', 'User.ReadWrite.All', 'TermStore.ReadWrite.All') }
        Teams      = @{ Graph = @('Group.ReadWrite.All', 'Application.ReadWrite.All', 'Teamwork.Migrate.All', 'ChannelMember.ReadWrite.All', 'Chat.ReadWrite.All', 'Tasks.ReadWrite.All', 'Sites.FullControl.All', 'Directory.Read.All', 'User.Read.All'); Exchange = @(); SharePoint = @() }
        GalSync    = @{ Graph = @('User.ReadWrite.All', 'User.Invite.All', 'Group.ReadWrite.All', 'Directory.Read.All'); Exchange = @('Exchange.ManageAsApp'); SharePoint = @() }
        # V2 : Intune Cible = permissions de la Source (application) + Device.ReadWrite.All en DELEGUEE (flux ROPC),
        # voir $script:DelegatedMatrix.
        Intune     = @{ Graph = @('DeviceManagementApps.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'Policy.ReadWrite.ConditionalAccess', 'Agreement.ReadWrite.All', 'Device.ReadWrite.All', 'Group.Read.All', 'Organization.Read.All'); Exchange = @(); SharePoint = @() }
        FreeBusy   = @{ Graph = @(); Exchange = @(); SharePoint = @() }
        Signature  = @{ Graph = @(); Exchange = @('Exchange.ManageAsApp'); SharePoint = @() }
        MailRouting = @{ Graph = @(); Exchange = @('Exchange.ManageAsApp'); SharePoint = @() }
    }
}

# Portees DELEGUEES par mode et par charge (V2) : s'ajoutent a Graph User.Read (toujours) et a ExplicitDelegatedScopes.
$script:DelegatedMatrix = @{
    Source = @{}
    Target = @{
        Intune = @{ Graph = @('Device.ReadWrite.All'); Exchange = @(); SharePoint = @() }
    }
}

# Permissions demandees dans tous les cas (quelles que soient les charges), par mode.
$script:PermissionAlways = @{
    Source = @{ Graph = @(); Exchange = @(); SharePoint = @() }
    Target = @{ Graph = @('Application.ReadWrite.All', 'Organization.Read.All'); Exchange = @(); SharePoint = @() }   # inter-tenant
}

# Portees DELEGUEES explicites par mode et par ressource (en plus de Graph User.Read, toujours demandee).
# VIDE volontairement : la doc Cloudiway dit "Application et Deleguee" pour la Cible sans lister les portees deleguees
# attendues. A VALIDER avec Cloudiway avant d'y ajouter quoi que ce soit (un consentement delegue AllPrincipals trop large
# est un risque inutile).
$script:ExplicitDelegatedScopes = @{
    Source = @{ Graph = @(); Exchange = @(); SharePoint = @() }
    Target = @{ Graph = @(); Exchange = @(); SharePoint = @() }
}

# Permissions OPTIONNELLES ("Ressource|Nom", tous types) : la ressource peut ne pas publier le role dans certains tenants
# (ex. Tasks.* de Graph). Non resolue, une permission optionnelle donne une information et ne bloque ni le plan ni la verification.
# V2 : User.Invite.All (GalSync Source) est optionnel ; la liste est par nom, donc valable aussi en Cible (la ressource le publie toujours).
$script:OptionalPermissions = @('Graph|Tasks.Read.All', 'Graph|Tasks.ReadWrite.All', 'Graph|User.Invite.All')

# --- Roles Entra (identifiants de modeles de roles integres, stables et publics) ---
$script:EntraRoleTemplates = @{
    GlobalAdministrator            = '62e90394-69f5-4237-9190-012177145e10'
    ExchangeAdministrator          = '29232cdf-9323-42fd-ade2-1d097af3e4de'
    ExchangeRecipientAdministrator = '31392ffb-586c-42d1-9346-e59415a2cc4e'
    SharePointAdministrator        = 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'
}
# V2 : roles Exchange Administrator et Exchange Recipient Administrator sur l'APPLICATION, pour le Mail seulement.
$script:WorkloadsNeedingExchangeRoles = @('Mail')
# V2 : compte de service (utilisateur, role SharePoint Administrator) requis, par mode :
#   OneDrive en CIBLE seulement (flux ROPC) ; Teams et SharePoint en source et en cible.
$script:WorkloadsNeedingServiceAccount = @{
    Source = @('SharePoint', 'Teams')
    Target = @('OneDrive', 'SharePoint', 'Teams')
}

# --- Produits Cloudiway (rawProductList). $null = inconnu ---
$script:ProductTable = [ordered]@{
    Mail       = 5
    Archive    = $null
    OneDrive   = 6      # "Fichiers"
    SharePoint = 6      # "Fichiers" ; a distinguer si le portail le fait (inconnu)
    Teams      = $null
    GalSync    = $null
    Intune     = $null
    FreeBusy   = $null   # fonctions du Mail a priori, mais produit non confirme : non devine
    Signature  = $null
    MailRouting = $null
}

# --- Fonctions ---

# Normalise la liste des charges : casse canonique, sans doublon, charges inconnues ignorees.
function ConvertTo-CanonicalWorkloads([string[]]$Workloads) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($w in @($Workloads)) {
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        $canon = $script:KnownWorkloads | Where-Object { $_ -ieq $w.Trim() } | Select-Object -First 1
        if ($canon -and -not $out.Contains($canon)) { $out.Add($canon) }
    }
    return $out.ToArray()
}

# Retourne l'ensemble des permissions { Resource; Name; Type; Optional } sans doublon.
# Toujours Graph User.Read (Delegated) ; les autres portees deleguees viennent de $script:ExplicitDelegatedScopes (vide) et de $script:DelegatedMatrix.
function Get-PermissionSet {
    param(
        [Parameter(Mandatory)][ValidateSet('Source', 'Target')][string]$Mode,
        [string[]]$Workloads = @()
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $list = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($res, $name, $type)
        if ($seen.Add("$res|$name|$type")) { $list.Add([pscustomobject]@{ Resource = $res; Name = $name; Type = $type; Optional = ($script:OptionalPermissions -contains "$res|$name") }) }
    }
    & $add 'Graph' 'User.Read' 'Delegated'
    $blocks = [System.Collections.Generic.List[object]]::new()
    $blocks.Add($script:PermissionAlways[$Mode])
    foreach ($w in (ConvertTo-CanonicalWorkloads $Workloads)) {
        $blocks.Add($script:PermissionMatrix[$Mode][$w])
    }
    foreach ($res in $script:ResourceAppIds.Keys) {
        foreach ($b in $blocks) {
            foreach ($n in @($b[$res])) {
                if (-not $n) { continue }
                & $add $res $n 'Application'
            }
        }
        foreach ($n in @($script:ExplicitDelegatedScopes[$Mode][$res])) {
            if ($n) { & $add $res $n 'Delegated' }
        }
        foreach ($w in (ConvertTo-CanonicalWorkloads $Workloads)) {
            $dm = $script:DelegatedMatrix[$Mode][$w]
            if ($dm) { foreach ($n in @($dm[$res])) { if ($n) { & $add $res $n 'Delegated' } } }
        }
    }
    return $list.ToArray()
}

# Retourne les roles Entra requis { Name; TemplateId; Target ('ServicePrincipal'|'ServiceAccount') }.
function Get-RequiredEntraRoles {
    param(
        [Parameter(Mandatory)][ValidateSet('Source', 'Target')][string]$Mode,
        [string[]]$Workloads = @()
    )
    $w = ConvertTo-CanonicalWorkloads $Workloads
    $list = [System.Collections.Generic.List[object]]::new()
    if (@($w | Where-Object { $_ -in $script:WorkloadsNeedingExchangeRoles }).Count -gt 0) {
        $list.Add([pscustomobject]@{ Name = 'Exchange Administrator'; TemplateId = $script:EntraRoleTemplates.ExchangeAdministrator; Target = 'ServicePrincipal' })
        $list.Add([pscustomobject]@{ Name = 'Exchange Recipient Administrator'; TemplateId = $script:EntraRoleTemplates.ExchangeRecipientAdministrator; Target = 'ServicePrincipal' })
    }
    if (Test-NeedServiceAccount -Mode $Mode -Workloads $w) {
        $list.Add([pscustomobject]@{ Name = 'SharePoint Administrator'; TemplateId = $script:EntraRoleTemplates.SharePointAdministrator; Target = 'ServiceAccount' })
    }
    return $list.ToArray()
}

# Vrai si une charge impose un compte de service pour ce mode (V2 : OneDrive en Cible, SharePoint et Teams dans les deux sens).
# Mode absent : repris du contexte ; toujours inconnu, on retient le cas le plus large (Cible).
function Test-NeedServiceAccount {
    param([string]$Mode = '', [string[]]$Workloads = @())
    if (-not $Mode) { try { $Mode = "$($script:Ctx.Mode)" } catch { $Mode = '' } }
    $key = if ($Mode -ieq 'Source') { 'Source' } else { 'Target' }
    $need = $script:WorkloadsNeedingServiceAccount[$key]
    return (@(ConvertTo-CanonicalWorkloads $Workloads | Where-Object { $_ -in $need }).Count -gt 0)
}

# Noms codifies. Surchargeables par parametres.
# Retourne { App; ServiceAccountLocal; ServiceAccountDisplay; Connector; CertificateSubject }.
#   App                   CLOUDIWAY-<MODE>-P<ProjectId>     (MODE en majuscules)
#   ServiceAccountLocal   svc-ciw-<mode>-p<ProjectId>       (partie locale ; UPN = local@domaine .onmicrosoft.com ;
#                                                            une surcharge contenant '@' est un UPN complet)
#   ServiceAccountDisplay Cloudiway <Mode> P<ProjectId>
#   Connector             <TenantShort>-<mode>
#   CertificateSubject    CN=Cloudiway-<MODE>-P<ProjectId>
function Get-CodedNames {
    param(
        [Parameter(Mandatory)][ValidateSet('Source', 'Target')][string]$Mode,
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$TenantShort = '',
        [string]$AppName = '',
        [string]$ServiceAccountName = '',
        [string]$ConnectorName = ''
    )
    $m = $Mode.Substring(0, 1).ToUpperInvariant() + $Mode.Substring(1).ToLowerInvariant()
    $up = $m.ToUpperInvariant(); $lo = $m.ToLowerInvariant()
    $short = "$TenantShort".Trim().ToLowerInvariant()
    return [pscustomobject]@{
        App                   = $(if ($AppName) { $AppName } else { "CLOUDIWAY-$up-P$ProjectId" })
        ServiceAccountLocal   = $(if ($ServiceAccountName) { $ServiceAccountName } else { "svc-ciw-$lo-p$ProjectId" })
        ServiceAccountDisplay = "Cloudiway $m P$ProjectId"
        Connector             = $(if ($ConnectorName) { $ConnectorName } elseif ($short) { "$short-$lo" } else { "connecteur-$lo" })
        CertificateSubject    = "CN=Cloudiway-$up-P$ProjectId"
    }
}

# Produits Cloudiway : { Ids [int[]]; Unknown [string[]]; Source 'defaut'|'override'|'fichier' }.
# Priorite : -Override, puis -MapFile (JSON { "Teams": 12, "Archive": [7] }), puis la table par defaut.
function Get-ProductIds {
    param(
        [string[]]$Workloads = @(),
        [int[]]$Override = @(),
        [string]$MapFile = ''
    )
    $w = ConvertTo-CanonicalWorkloads $Workloads
    if (@($Override).Count -gt 0) {
        return [pscustomobject]@{ Ids = [int[]]@($Override | Sort-Object -Unique); Unknown = [string[]]@(); Source = 'override' }
    }
    $map = @{}
    $source = 'defaut'
    if ($MapFile) {
        try {
            if (-not (Test-Path -LiteralPath $MapFile)) { throw "fichier introuvable : $MapFile" }
            $j = Get-Content -LiteralPath $MapFile -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $j.PSObject.Properties) {
                $canon = $script:KnownWorkloads | Where-Object { $_ -ieq $p.Name } | Select-Object -First 1
                if (-not $canon) { continue }
                $vals = @($p.Value | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
                if ($vals.Count -gt 0) { $map[$canon] = $vals }
            }
            $source = 'fichier'
        } catch {
            if (Get-Command Write-RunLog -ErrorAction SilentlyContinue) { Write-RunLog ("Table produits : fichier ignore ({0})" -f $_.Exception.Message) }
            $map = @{}
            $source = 'defaut'
        }
    }
    $ids = [System.Collections.Generic.List[int]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $w) {
        $vals = $null
        if ($map.ContainsKey($name)) { $vals = $map[$name] }
        elseif ($null -ne $script:ProductTable[$name]) { $vals = @([int]$script:ProductTable[$name]) }
        if ($null -eq $vals) { $unknown.Add($name) }
        else { foreach ($v in $vals) { if (-not $ids.Contains([int]$v)) { $ids.Add([int]$v) } } }
    }
    return [pscustomobject]@{ Ids = [int[]]@($ids | Sort-Object); Unknown = [string[]]$unknown.ToArray(); Source = $source }
}
