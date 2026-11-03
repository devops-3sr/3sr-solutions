# mocks.ps1 - cmdlets SIMULEES pour le banc de test hors ligne de CloudiwayConnector.
# A dot-sourcer dans la portee du banc : les stubs sont definis en portee GLOBALE et priment sur les vrais cmdlets.
# Aucun appel reseau, aucune connexion reelle. Chaque appel est enregistre dans $global:MockCalls (et cumule dans $global:MockAllCalls).
#
# Etat global :
#   $global:MockTenant : faux tenant Microsoft 365 en memoire (applications, principaux de service, utilisateurs, attributions...)
#   $global:MockCiw    : faux portail Cloudiway (jeton, projets, connecteurs)
#   $global:MockCalls  : List[object] { Seq; Kind (Graph|Ciw|Cmd); Method; Path; Status; IsWrite; Body }
#   $global:MockOpts   : options de scenario (voir Reset-MockState)

$global:MockTenantId = '11111111-2222-3333-4444-555555555555'
$global:MockUser = 'admin@contoso.com'
$global:MockInitial = 'contoso.onmicrosoft.com'
$global:MockPat = 'pat-fake-fake-fake-fake'
$global:MockCwLogin = 'paul.bernard@contoso.com'          # identifiant Cloudiway du DSI (invite sur le projet)
$global:MockCwPassword = 'fake-password-fake-password'            # mot de passe Cloudiway du DSI (v2 : saisi masque par Read-Host)
# SecureString construit caractere par caractere (valeurs de test).
function New-TestSecure([string]$Text) { $s = [System.Security.SecureString]::new(); foreach ($ch in $Text.ToCharArray()) { $s.AppendChar($ch) }; $s.MakeReadOnly(); return $s }
$global:MockProjectId = 12345
$global:MockAllCalls = [System.Collections.Generic.List[object]]::new()

$global:MockRoleTpl = @{
    GA   = '62e90394-69f5-4237-9190-012177145e10'
    ExA  = '29232cdf-9323-42fd-ade2-1d097af3e4de'
    ExRA = '31392ffb-586c-42d1-9346-e59415a2cc4e'
    SPA  = 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c'
    GR   = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'   # Global Reader (role non GA)
}

# ----------------------------------------------------------------------------------------------
# Journal et erreurs
# ----------------------------------------------------------------------------------------------
function global:Add-MockCall([string]$Kind, [string]$Method, [string]$Path, [string]$Status = 'OK', [bool]$IsWrite = $false, [string]$Body = '') {
    $e = [pscustomobject]@{ Seq = $global:MockCalls.Count + 1; Kind = $Kind; Method = $Method; Path = $Path; Status = $Status; IsWrite = $IsWrite; Body = $Body }
    $global:MockCalls.Add($e)
    $global:MockAllCalls.Add($e)
}

function global:New-MockError([int]$Status = 403, [string]$Code = 'Authorization_RequestDenied', [string]$Msg = 'Insufficient privileges to complete the operation.') {
    $ex = [System.Net.Http.HttpRequestException]::new("Response status code does not indicate success: $Status ($Code).", $null, [System.Net.HttpStatusCode]$Status)
    $er = [System.Management.Automation.ErrorRecord]::new($ex, "MockHttp$Status", [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
    $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new((@{ error = @{ code = $Code; message = $Msg } } | ConvertTo-Json -Compress))
    $er
}

# Erreur OAuth2 du point de terminaison /token de Microsoft : corps { error, error_description } (et non la forme { error: { code, message } } de Graph).
function global:New-MockOAuthError([string]$OAuthError, [string]$Description) {
    $er = New-MockError 400 $OAuthError $Description
    $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new((@{ error = $OAuthError; error_description = $Description } | ConvertTo-Json -Compress))
    $er
}
# Copie profonde par aller-retour JSON : le script ne doit jamais tenir de reference vers l'etat interne du faux tenant.
function global:Copy-Mock($Object) {
    if ($null -eq $Object) { return $null }
    ($Object | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json -Depth 50
}

# ----------------------------------------------------------------------------------------------
# Etat de scenario
# ----------------------------------------------------------------------------------------------
function global:Reset-MockState {
    $global:MockCalls = [System.Collections.Generic.List[object]]::new()
    $global:MockUnrouted = [System.Collections.Generic.List[string]]::new()
    $global:MockSleeps = [System.Collections.Generic.List[int]]::new()
    $global:MockReadQueue = [System.Collections.Generic.Queue[object]]::new()
    $global:MockReadLog = [System.Collections.Generic.List[string]]::new()
    $global:MockReadExhausted = $false
    $global:MockMgCtx = $null
    $global:MockExoCtx = $null
    $global:MockHidden = [System.Collections.Generic.List[object]]::new()   # principaux de service de ressource "absents" (crees a la demande)
    $global:MockThrowOnDate = $false
    $global:MockGraphExpired = $false
    $global:MockGraphHeaders = [System.Collections.Generic.List[object]]::new()   # v2.4 : en-tetes ConsistencyLevel observes par appel Graph
    $global:MockOpts = @{
        IsGA              = $true         # le compte connecte est Administrateur general
        ConnectTenantId   = $null         # tenant reellement obtenu par Connect-MgGraph (defaut : celui demande)
        ConnectAccount    = $null         # compte reellement obtenu (defaut : admin@contoso.com)
        ConnectFails      = $false
        Forbid            = @()           # @{ Method; Pattern } : 403 ciblé (regex sur le chemin)
        Throttle          = @()           # @{ Method; Pattern; Times } : 429 les N premieres fois puis succes
        Replication404    = 0             # POST /servicePrincipals : 404 les N premieres fois (propagation Entra)
        ConditionalAccess = 'mfa-all'     # 'mfa-all' | 'none'
        ModuleMissing     = $false        # Microsoft.Graph.Authentication absent du poste
        NetDown           = @()           # hotes HTTPS injoignables (preflight)
        CiwDown           = @()           # regex de chemins Cloudiway en erreur 500
        GraphFail         = @()           # @{ Method; Pattern; Code; Times } : erreur HTTP <Code> les N premieres fois puis succes (ex. 504)
        CiwFail           = @()           # idem cote Cloudiway (ex. 503 sur POST /Connectors)
        OidcDomains       = @{ 'contoso.onmicrosoft.com' = $global:MockTenantId; 'contoso.com' = $global:MockTenantId }   # domaine -> GUID (metadonnee OIDC publique)
        CiwExpire         = @()           # @{ Method (facultatif); Path (regex); Nth } : le Nieme appel correspondant expire le jeton (401) ; un nouveau login donne un nouveau jeton
        CiwMaskSecrets    = $false       # les LECTURES du connecteur masquent secrets et contenu du certificat (********)
        CiwPutWipes       = $false       # (herite) un PUT sans certificat efface le certificat stocke ; inatteignable si le connecteur en possede un (HTTP 500, voir ci-dessous)
        CiwPutIgnoresCert = $false       # v2.4 : un PUT AVEC connectorCertificate repond isSuccess = vrai mais le certificat stocke (id, fileName...) reste INCHANGE
        CiwHideFileName   = $false       # v2.4 : les LECTURES du connecteur ne renvoient plus connectorCertificate.fileName (prise en compte non verifiable)
        CiwLoseResponse   = @()          # v2.4 : @{ Method; Pattern; Times; Code } : l'ecriture est APPLIQUEE puis l'appel leve une erreur (reponse perdue : timeout / 5xx), Code defaut 504
        GraphExpire       = @()          # v2.4 : @{ Method (facultatif); Pattern; Nth } : a partir du Nieme appel Graph correspondant, TOUT appel Graph repond 401 (jeton expire)
        DeviceTokenLifetimeSec = 3600    # v2.4 : duree de vie (claim exp) du jeton Graph obtenu par code d'appareil
        DeviceNoUpn       = $false       # v2.4 : le jeton du code d'appareil ne porte pas upn (invite B2B) : seulement preferred_username
        ClockSkewMinutes  = 0             # decalage de l'horloge du poste par rapport a l'en-tete Date des serveurs
        ConnectFailMessage = $null       # message de l'echec de Connect-MgGraph (ex. AADSTS65001)
        DevicePendingPolls = 0           # nombre d'interrogations /token qui repondent authorization_pending avant le succes (code d'appareil)
        DeviceDeclined = $false          # le code d'appareil est refuse dans la page Microsoft
        Replication400    = 0             # POST /servicePrincipals : 400 'does not reference a valid application object' les N premieres fois
        ForbidPolicy      = @()           # @{ Method; Pattern } : 403 'not allowed as per assigned policy'
        SecurityDefaults  = $false       # valeurs de securite par defaut activees
        ExoModuleMissing  = $false        # v2.2 : module ExchangeOnlineManagement absent du poste
        ExoConnectFails   = $false        # v2.2 : Connect-ExchangeOnline echoue
        ExoConnectMessage = 'MOCK: connexion Exchange Online refusee par l''utilisateur.'
        ExoTenantId       = $null         # v2.2 : tenant reellement obtenu par Connect-ExchangeOnline (defaut : celui du faux tenant)
        ExoReadFails      = $false        # v2.2 : Get-OrganizationConfig echoue
        ExoSetFails       = $false        # v2.2 : Set-OrganizationConfig echoue
        EwsEnabled        = $true         # v2.2 : EwsEnabled de l'organisation ($true | $false | $null)
        EwsList           = @('0000aaaa-0000-0000-0000-000000000001')   # v2.2 : EwsAllowedAppIDs de l'organisation (une autre application deja inscrite par defaut ; @() pour tester la liste vide)
        ExoOnSet          = $null         # v2.2 : scriptblock { param($Hash) } appele avant chaque Set-OrganizationConfig
        OnWrite           = $null         # scriptblock { param($Method, $Path, $Body) } appele avant chaque ecriture Graph (verifie l'ORDRE des operations)
    }
    Reset-MockTenant
    Reset-MockCiw
}

function global:New-MockResource([string]$AppId, [string]$Name, [string[]]$Roles, [string[]]$Scopes) {
    @{
        id = [guid]::NewGuid().ToString(); appId = $AppId; displayName = $Name
        appRoles = @($Roles | ForEach-Object { @{ id = [guid]::NewGuid().ToString(); value = $_; isEnabled = $true; allowedMemberTypes = @('Application'); displayName = $_ } })
        oauth2PermissionScopes = @($Scopes | ForEach-Object { @{ id = [guid]::NewGuid().ToString(); value = $_; isEnabled = $true; type = 'Admin' } })
    }
}

function global:Reset-MockTenant {
    $t = @{
        Apps = [System.Collections.Generic.List[object]]::new(); Sps = [System.Collections.Generic.List[object]]::new()
        Users = [System.Collections.Generic.List[object]]::new(); RoleAssign = [System.Collections.Generic.List[object]]::new()
        ArAssign = [System.Collections.Generic.List[object]]::new(); Grants = [System.Collections.Generic.List[object]]::new()
        RemovedKeys = 0; RemovedKeyIds = [System.Collections.Generic.List[string]]::new(); RemovedSecrets = 0; RemovedSecretIds = [System.Collections.Generic.List[string]]::new(); Rep404Left = 0; Secrets = @{}
        KeyPubs = @{}; ProofTokens = [System.Collections.Generic.List[string]]::new(); RemoveKeyCalls = 0
    }
    # Noms de permissions ECRITS A LA MAIN d'apres le catalogue Microsoft (independants de la matrice du package :
    # une faute de frappe dans la matrice doit apparaitre comme "Permissions introuvables").
    $graphRoles = 'MailboxSettings.ReadWrite', 'User.Read.All', 'User.ReadWrite.All', 'User.Invite.All', 'Files.ReadWrite.All', 'Sites.FullControl.All',
    'Directory.Read.All', 'Group.Read.All', 'Group.ReadWrite.All', 'ChannelMessage.Read.All', 'ChannelMember.ReadWrite.All', 'Chat.Read.All',
    'Chat.ReadWrite.All', 'Tasks.Read.All', 'Tasks.ReadWrite.All', 'Teamwork.Migrate.All', 'Application.ReadWrite.All', 'Organization.Read.All',
    'OrgContact.Read.All', 'InformationProtectionPolicy.Read.All', 'DeviceManagementApps.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All', 'Policy.ReadWrite.ConditionalAccess', 'Agreement.ReadWrite.All', 'Device.ReadWrite.All'
    $graphScopes = 'User.Read', 'MailboxSettings.ReadWrite', 'User.Read.All', 'User.ReadWrite.All', 'User.Invite.All', 'Files.ReadWrite.All', 'Sites.FullControl.All',
    'Directory.Read.All', 'Group.Read.All', 'Group.ReadWrite.All', 'ChannelMember.ReadWrite.All', 'Application.ReadWrite.All', 'Organization.Read.All',
    'Agreement.ReadWrite.All', 'Device.ReadWrite.All', 'Policy.ReadWrite.ConditionalAccess'
    $t.Sps.Add((New-MockResource '00000003-0000-0000-c000-000000000000' 'Microsoft Graph' $graphRoles $graphScopes))
    $t.Sps.Add((New-MockResource '00000002-0000-0ff1-ce00-000000000000' 'Office 365 Exchange Online' @('full_access_as_app', 'Exchange.ManageAsApp') @('Exchange.Manage', 'EWS.AccessAsUser.All')))
    $t.Sps.Add((New-MockResource '00000003-0000-0ff1-ce00-000000000000' 'Office 365 SharePoint Online' @('Sites.FullControl.All', 'User.Read.All', 'User.ReadWrite.All', 'TermStore.ReadWrite.All', 'Sites.ReadWrite.All') @('AllSites.FullControl', 'MyFiles.Read')))
    $t.Org = @{
        id = $global:MockTenantId; displayName = 'Contoso'
        verifiedDomains = @(
            @{ name = 'contoso.com'; isInitial = $false; isDefault = $true },
            @{ name = $global:MockInitial; isInitial = $true; isDefault = $false },
            @{ name = 'contoso.mail.onmicrosoft.com'; isInitial = $false; isDefault = $false })
    }
    $global:MockTenant = $t
    $global:MockTenant.Rep404Left = [int]$global:MockOpts.Replication404
    $global:MockTenant.Rep400Left = [int]$global:MockOpts.Replication400
}

function global:Reset-MockCiw {
    $global:MockCiw = @{
        ValidPat = $global:MockPat; ValidLogin = $global:MockCwLogin; ValidPassword = $global:MockCwPassword
        LoginMode = 'token'   # 'token' : vrai jeton dans la reponse ; 'cookie' : champ token = litteralement "token", vrai jeton dans Set-Cookie
        Token = ('MOCKJWT.' + [guid]::NewGuid().ToString('N') + '.SIG'); Projects = @(12345)
        Connectors = [System.Collections.Generic.List[object]]::new(); NextId = 1000; NextCertId = 5000; PutCount = 0; PutAttempts = 0; PostCount = 0; CertFileSeen = $null; CertFilePath = ''
    }
}

# ----------------------------------------------------------------------------------------------
# Aides de lecture de l'etat (utilisees par le banc, pas par le script)
# ----------------------------------------------------------------------------------------------
function global:Get-MockResSp([string]$AppId) { @($global:MockTenant.Sps | Where-Object { $_.appId -eq $AppId })[0] }
function global:Get-MockApp([string]$Name) { @($global:MockTenant.Apps | Where-Object { $_.displayName -eq $Name }) }
function global:Get-MockUser([string]$Upn) { @($global:MockTenant.Users | Where-Object { $_.userPrincipalName -eq $Upn })[0] }

# "Resource|Name|Type" de toutes les permissions declarees dans requiredResourceAccess d'une application.
function global:Get-MockAppPerms($App) {
    $out = [System.Collections.Generic.List[string]]::new()
    $label = @{ '00000003-0000-0000-c000-000000000000' = 'Graph'; '00000002-0000-0ff1-ce00-000000000000' = 'Exchange'; '00000003-0000-0ff1-ce00-000000000000' = 'SharePoint' }
    foreach ($rra in @($App.requiredResourceAccess)) {
        $sp = Get-MockResSp $rra.resourceAppId
        foreach ($ra in @($rra.resourceAccess)) {
            if ($ra.type -eq 'Role') { $n = @($sp.appRoles | Where-Object { $_.id -eq $ra.id })[0].value; $ty = 'Application' }
            else { $n = @($sp.oauth2PermissionScopes | Where-Object { $_.id -eq $ra.id })[0].value; $ty = 'Delegated' }
            $out.Add("$($label[$rra.resourceAppId])|$n|$ty")
        }
    }
    , @($out | Sort-Object -Unique)
}

# ----------------------------------------------------------------------------------------------
# Microsoft Graph (faux tenant)
# ----------------------------------------------------------------------------------------------
function global:Test-MockPattern($List, [string]$Method, [string]$Path) {
    foreach ($f in @($List)) { if ($f -and ($f.Method -eq '*' -or $f.Method -eq $Method) -and $Path -match $f.Pattern) { return $f } }
    return $null
}

function global:Invoke-MgGraphRequest {
    [CmdletBinding()]
    param($Method = 'GET', $Uri, $Headers, $OutputType, $Body, $ContentType)
    $T = $global:MockTenant
    $u = [uri]$Uri
    if ($u.Host -ne 'graph.microsoft.com') { Add-MockCall 'Graph' $Method $Uri 'HOST-INTERDIT' $true; throw "MOCK: hote non autorise '$($u.Host)'" }
    $path = $u.AbsolutePath -replace '^/(v1\.0|beta)', ''
    $q = [uri]::UnescapeDataString($u.Query)
    $isWrite = ($Method -ne 'GET')
    if ($null -eq $global:MockMgCtx) { Add-MockCall 'Graph' $Method $path 'NON-CONNECTE' $isWrite; throw (New-MockError 401 'InvalidAuthenticationToken' 'Pas de contexte Graph : Connect-MgGraph non appele.') }

    $bodyTxt = if ($Body) { [string]$Body } else { '' }
    $global:MockGraphHeaders.Add([pscustomobject]@{ Method = $Method; Path = $path; Consistency = "$($Headers.ConsistencyLevel)" })
    # Jeton Graph expire (v2.4) : a partir du Nieme appel correspondant, tout appel repond 401 jusqu'a une nouvelle connexion
    foreach ($xr in @($global:MockOpts.GraphExpire)) {
        if ($xr -and (-not $xr.Method -or $xr.Method -eq $Method) -and $path -match $xr.Pattern) {
            $xr.Seen = 1 + [int]$xr.Seen
            if ($xr.Seen -ge [int]$xr.Nth) { $global:MockGraphExpired = $true }
        }
    }
    if ($global:MockGraphExpired) { Add-MockCall 'Graph' $Method $path '401' $isWrite $bodyTxt; throw (New-MockError 401 'InvalidAuthenticationToken' 'Access token has expired or is not yet valid.') }
    $thr = Test-MockPattern $global:MockOpts.Throttle $Method $path
    if ($thr -and $thr.Times -gt 0) { $thr.Times--; Add-MockCall 'Graph' $Method $path '429' $isWrite $bodyTxt; throw (New-MockError 429 'TooManyRequests' 'Too many requests.') }
    if (Test-MockPattern $global:MockOpts.ForbidPolicy $Method $path) { Add-MockCall 'Graph' $Method $path '403' $isWrite $bodyTxt; throw (New-MockError 403 'Authorization_RequestDenied' 'The requested operation is not allowed as per assigned policy.') }
    if (Test-MockPattern $global:MockOpts.Forbid $Method $path) { Add-MockCall 'Graph' $Method $path '403' $isWrite $bodyTxt; throw (New-MockError 403 'Authorization_RequestDenied' 'Insufficient privileges to complete the operation.') }
    $gf = Test-MockPattern $global:MockOpts.GraphFail $Method $path
    if ($gf -and $gf.Query -and $q -notmatch $gf.Query) { $gf = $null }   # Query (regex facultative) : cible un GET precis par son $select
    if ($gf -and $gf.Times -gt 0) { $gf.Times--; Add-MockCall 'Graph' $Method $path "$($gf.Code)" $isWrite $bodyTxt; throw (New-MockError ([int]$gf.Code) $(if ($gf.ErrCode) { "$($gf.ErrCode)" } else { 'GatewayTimeout' }) $(if ($gf.Msg) { "$($gf.Msg)" } else { 'Gateway timeout simule.' })) }
    if ($Method -notin 'GET', 'POST', 'PATCH') { Add-MockCall 'Graph' $Method $path '405' $true $bodyTxt; throw (New-MockError 405 'MethodNotAllowed' "Methode $Method non prevue par le contrat (GET, POST, PATCH).") }

    $b = $null
    if ($bodyTxt) { $b = $bodyTxt | ConvertFrom-Json -AsHashtable -DateKind String -Depth 50 }
    $wrap = { param($items) Copy-Mock @{ value = @($items) } }
    if ($Method -ne 'GET' -and $global:MockOpts.OnWrite) { & $global:MockOpts.OnWrite $Method $path $b }
    $filterVal = { param($re) $m = [regex]::Match($q, $re); if ($m.Success) { $m.Groups[1].Value.Replace("''", "'") } else { $null } }
    $bad = { param($msg) Add-MockCall 'Graph' $Method $path '400' $isWrite $bodyTxt; throw (New-MockError 400 'Request_BadRequest' $msg) }
    $notFound = { param($msg) Add-MockCall 'Graph' $Method $path '404' $isWrite $bodyTxt; throw (New-MockError 404 'Request_ResourceNotFound' $msg) }
    $ok = { Add-MockCall 'Graph' $Method $path 'OK' $isWrite $bodyTxt }

    if ($Method -eq 'GET') {
        switch -Regex ($path) {
            '^/organization$' { & $ok; return (& $wrap @($T.Org)) }
            '^/me/transitiveMemberOf/microsoft\.graph\.directoryRole$' {
                & $ok
                $tpl = if ($global:MockOpts.IsGA) { $global:MockRoleTpl.GA } else { $global:MockRoleTpl.GR }
                $nm = if ($global:MockOpts.IsGA) { 'Global Administrator' } else { 'Global Reader' }
                return (& $wrap @(@{ '@odata.type' = '#microsoft.graph.directoryRole'; id = [guid]::NewGuid().ToString(); displayName = $nm; roleTemplateId = $tpl }))
            }
            '^/servicePrincipals$' {
                & $ok; $id = & $filterVal "appId eq '([^']+)'"
                return (& $wrap @($T.Sps | Where-Object { $_.appId -eq $id }))
            }
            '^/servicePrincipals/([^/]+)/appRoleAssignments$' {
                $id = $Matches[1]; & $ok
                return (& $wrap @($T.ArAssign | Where-Object { $_.principalId -eq $id }))
            }
            '^/oauth2PermissionGrants$' {
                & $ok; $id = & $filterVal "clientId eq '([^']+)'"
                return (& $wrap @($T.Grants | Where-Object { $_.clientId -eq $id }))
            }
            '^/roleManagement/directory/roleAssignments$' {
                & $ok; $id = & $filterVal "principalId eq '([^']+)'"
                return (& $wrap @($T.RoleAssign | Where-Object { $_.principalId -eq $id }))
            }
            '^/applications$' {
                & $ok; $n = & $filterVal "displayName eq '((?:[^']|'')+)'"
                return (& $wrap @($T.Apps | Where-Object { $_.displayName -eq $n }))
            }
            '^/applications/([^/]+)$' {
                $id = $Matches[1]; $a = @($T.Apps | Where-Object { $_.id -eq $id })[0]
                if (-not $a) { & $notFound "Resource '$id' does not exist or one of its queried reference-property objects are not present." }
                & $ok; return (Copy-Mock $a)
            }
            '^/users$' {
                & $ok; $n = & $filterVal "userPrincipalName eq '((?:[^']|'')+)'"
                return (& $wrap @($T.Users | Where-Object { $_.userPrincipalName -eq $n } | ForEach-Object { $c = @{}; foreach ($k in $_.Keys) { if ($k -ne 'passwordProfile' -and $k -ne 'PwdMarker') { $c[$k] = $_[$k] } }; $c }))
            }
            '^/policies/identitySecurityDefaultsEnforcementPolicy$' { & $ok; return (Copy-Mock @{ id = 'sd'; isEnabled = [bool]$global:MockOpts.SecurityDefaults }) }
            '^/identity/conditionalAccess/policies$' {
                & $ok
                if ($global:MockOpts.ConditionalAccess -eq 'none') { return (& $wrap @()) }
                return (& $wrap @(@{ id = 'pol-1'; displayName = 'MFA pour tous'; state = 'enabled'; grantControls = @{ builtInControls = @('mfa') }; conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = @(); includeGroups = @(); includeRoles = @() } } }))
            }
        }
        $global:MockUnrouted.Add("GET $path"); Add-MockCall 'Graph' $Method $path '404-NONROUTE' $false
        throw (New-MockError 404 'Request_ResourceNotFound' "MOCK: GET non route $path")
    }

    # --- Ecritures ---
    if ($Method -eq 'POST') {
        switch -Regex ($path) {
            '^/applications$' {
                if (-not $b.displayName) { & $bad 'displayName requis.' }
                $a = @{ id = [guid]::NewGuid().ToString(); appId = [guid]::NewGuid().ToString(); displayName = $b.displayName; tags = @($b.tags); signInAudience = $b.signInAudience
                    isFallbackPublicClient = [bool]$b.isFallbackPublicClient; requiredResourceAccess = @($b.requiredResourceAccess); keyCredentials = @(); passwordCredentials = @()
                    web = @{ redirectUris = @($b.web.redirectUris | Where-Object { $_ }) }; spa = @{ redirectUris = @($b.spa.redirectUris | Where-Object { $_ }) }; publicClient = @{ redirectUris = @($b.publicClient.redirectUris | Where-Object { $_ }) } }
                foreach ($rra in $a.requiredResourceAccess) {
                    $sp = Get-MockResSp $rra.resourceAppId
                    if (-not $sp) { & $bad "resourceAppId inconnu $($rra.resourceAppId)" }
                    foreach ($ra in $rra.resourceAccess) {
                        $found = if ($ra.type -eq 'Role') { @($sp.appRoles | Where-Object { $_.id -eq $ra.id }) } else { @($sp.oauth2PermissionScopes | Where-Object { $_.id -eq $ra.id }) }
                        if ($found.Count -eq 0) { & $bad "Permission $($ra.id) ($($ra.type)) introuvable sur $($rra.resourceAppId)." }
                    }
                }
                $T.Apps.Add($a); & $ok; return (Copy-Mock $a)
            }
            '^/applications/([^/]+)/addPassword$' {
                $id = $Matches[1]; $a = @($T.Apps | Where-Object { $_.id -eq $id })[0]
                if (-not $a) { & $notFound "application $id inconnue" }
                if (-not $b.passwordCredential.endDateTime) { & $bad 'passwordCredential.endDateTime requis.' }
                $kid = [guid]::NewGuid().ToString(); $txt = 'MockSecret~' + [guid]::NewGuid().ToString('N') + '_Zz9'
                $T.Secrets[$kid] = $txt
                $pc = @{ keyId = $kid; displayName = $b.passwordCredential.displayName; startDateTime = (Microsoft.PowerShell.Utility\Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); endDateTime = $b.passwordCredential.endDateTime; hint = $txt.Substring(0, 3) }
                $a.passwordCredentials = @(@($a.passwordCredentials) + $pc)
                & $ok; $r = Copy-Mock $pc; $r | Add-Member -NotePropertyName secretText -NotePropertyValue $txt -Force; return $r
            }
            '^/applications/([^/]+)/removeKey$' {
                # Graph : retire UN certificat par son keyId. Exige une PREUVE DE POSSESSION : JWT signe (RS256) par la cle privee d'un certificat
                # DEJA enregistre et valide dans l'application. Le mock valide : 3 segments base64url, alg RS256, x5t = empreinte d'une cle existante,
                # aud et iss (object id de l'application) corrects, nbf/exp coherents et exp dans les 10 minutes, signature (cle publique connue).
                $id = $Matches[1]; $a = @($T.Apps | Where-Object { $_.id -eq $id })[0]
                if (-not $a) { & $notFound "application $id inconnue" }
                $T.RemoveKeyCalls++
                if ($global:MockOpts.RemoveKeyForbidden) { throw (New-MockError 403 'Authorization_RequestDenied' 'Insufficient privileges to complete the operation.') }
                if (-not $b.keyId) { & $bad 'keyId requis.' }
                $proof = "$($b.proof)"
                if (-not $proof) { & $bad 'proof requis (jeton de preuve de possession).' }
                $segs = @($proof -split '\.')
                if ($segs.Count -ne 3 -or @($segs | Where-Object { $_ -notmatch '^[A-Za-z0-9_-]+$' }).Count -gt 0) { & $bad 'Proof validation failed : 3 segments base64url attendus.' }
                $b64d = { param($s) $s = $s.Replace('-', '+').Replace('_', '/'); switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }; [Convert]::FromBase64String($s) }
                try {
                    $hdr = [System.Text.Encoding]::UTF8.GetString((& $b64d $segs[0])) | ConvertFrom-Json -AsHashtable
                    $pl = [System.Text.Encoding]::UTF8.GetString((& $b64d $segs[1])) | ConvertFrom-Json -AsHashtable
                    $sig = & $b64d $segs[2]
                } catch { & $bad "Proof validation failed : jeton illisible ($($_.Exception.Message))." }
                if ("$($hdr.alg)" -ne 'RS256') { & $bad 'Proof validation failed : alg doit valoir RS256.' }
                if ("$($hdr.typ)" -ne 'JWT') { & $bad 'Proof validation failed : typ doit valoir JWT.' }
                try { $x5t = [Convert]::ToHexString((& $b64d "$($hdr.x5t)")).ToUpperInvariant() } catch { $x5t = '' }
                $signer = @($a.keyCredentials | Where-Object { $x5t -and "$($_.customKeyIdentifier)".ToUpperInvariant() -eq $x5t })[0]
                if (-not $signer) { & $bad 'Proof validation failed : x5t ne correspond a aucun certificat enregistre dans l''application.' }
                if ("$($pl.aud)" -ne '00000002-0000-0000-c000-000000000000') { & $bad 'Proof validation failed : aud incorrect.' }
                if ("$($pl.iss)" -ne "$($a.id)") { & $bad 'Proof validation failed : iss incorrect (object id de l''application attendu).' }
                $nowE = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                if ($null -eq $pl.exp -or $null -eq $pl.nbf) { & $bad 'Proof validation failed : nbf et exp requis.' }
                $exp = [long]$pl.exp; $nbf = [long]$pl.nbf
                if ($exp -le $nowE) { & $bad 'Proof validation failed : jeton expire.' }
                if ($exp -gt $nowE + 600) { & $bad 'Proof validation failed : exp depasse 10 minutes.' }
                if ($nbf -gt $nowE + 60) { & $bad 'Proof validation failed : nbf dans le futur.' }
                if ($exp -le $nbf -or ($exp - $nbf) -gt 600) { & $bad 'Proof validation failed : nbf / exp incoherents (duree maximale 10 minutes).' }
                $pub = $T.KeyPubs["$($signer.keyId)"]
                if ($pub) {
                    $c0 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($pub))
                    try {
                        $rsaPub = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($c0)
                        $okSig = $rsaPub.VerifyData([System.Text.Encoding]::ASCII.GetBytes($segs[0] + '.' + $segs[1]), $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                    } finally { $c0.Dispose() }
                    if (-not $okSig) { & $bad 'Proof validation failed : signature invalide.' }
                }
                $kc = @($a.keyCredentials | Where-Object { $_.keyId -eq $b.keyId })[0]
                if (-not $kc) { & $bad "No key credential found with keyId $($b.keyId)." }
                $a.keyCredentials = @(@($a.keyCredentials) | Where-Object { $_.keyId -ne $b.keyId })
                $T.RemovedKeys += 1; $T.RemovedKeyIds.Add("$($b.keyId)"); $T.ProofTokens.Add($proof)
                & $ok; return $null
            }
            '^/applications/([^/]+)/removePassword$' {
                # Graph : retire UN secret client par son keyId ; 400 si le keyId est inconnu de l'application
                $id = $Matches[1]; $a = @($T.Apps | Where-Object { $_.id -eq $id })[0]
                if (-not $a) { & $notFound "application $id inconnue" }
                if (-not $b.keyId) { & $bad 'keyId requis.' }
                $pc = @($a.passwordCredentials | Where-Object { $_.keyId -eq $b.keyId })[0]
                if (-not $pc) { & $bad "No password credential found with keyId $($b.keyId)." }
                $a.passwordCredentials = @(@($a.passwordCredentials) | Where-Object { $_.keyId -ne $b.keyId })
                $T.RemovedSecrets += 1; $T.RemovedSecretIds.Add("$($b.keyId)")
                & $ok; return $null
            }
            '^/servicePrincipals$' {
                if ($T.Rep404Left -gt 0) { $T.Rep404Left--; & $notFound "Resource '$($b.appId)' does not exist or one of its queried reference-property objects are not present." }
                if ($T.Rep400Left -gt 0) { $T.Rep400Left--; & $bad "The appId '$($b.appId)' of the service principal does not reference a valid application object." }
                $hid = @($global:MockHidden | Where-Object { $_.appId -eq $b.appId })[0]
                if ($hid) { $global:MockHidden.Remove($hid) | Out-Null; $hid.id = [guid]::NewGuid().ToString(); $T.Sps.Add($hid); & $ok; return (Copy-Mock $hid) }
                $app = @($T.Apps | Where-Object { $_.appId -eq $b.appId })[0]
                if (-not $app) { & $bad "The appId '$($b.appId)' of the service principal does not reference a valid application object." }
                if (@($T.Sps | Where-Object { $_.appId -eq $b.appId }).Count -gt 0) { & $bad 'A service principal with the same appId already exists.' }
                $s = @{ id = [guid]::NewGuid().ToString(); appId = $b.appId; displayName = $app.displayName; appRoles = @(); oauth2PermissionScopes = @() }
                $T.Sps.Add($s); & $ok; return (Copy-Mock $s)
            }
            '^/servicePrincipals/([^/]+)/appRoleAssignedTo$' {
                $resId = $Matches[1]
                $res = @($T.Sps | Where-Object { $_.id -eq $resId })[0]
                if (-not $res) { & $notFound "ressource $resId inconnue" }
                if ($b.resourceId -ne $resId) { & $bad 'resourceId different de la ressource du chemin.' }
                $prin = @($T.Sps | Where-Object { $_.id -eq $b.principalId })[0]
                if (-not $prin) { & $notFound "principalId $($b.principalId) inconnu" }
                if (@($res.appRoles | Where-Object { $_.id -eq $b.appRoleId }).Count -eq 0) { & $bad "appRoleId $($b.appRoleId) inconnu sur la ressource." }
                if (@($T.ArAssign | Where-Object { $_.principalId -eq $b.principalId -and $_.resourceId -eq $resId -and $_.appRoleId -eq $b.appRoleId }).Count -gt 0) { & $bad 'Permission being assigned already exists on the object' }
                $x = @{ id = [guid]::NewGuid().ToString(); principalId = $b.principalId; resourceId = $resId; appRoleId = $b.appRoleId }
                $T.ArAssign.Add($x); & $ok; return (Copy-Mock $x)
            }
            '^/oauth2PermissionGrants$' {
                $cl = @($T.Sps | Where-Object { $_.id -eq $b.clientId })[0]; $rs = @($T.Sps | Where-Object { $_.id -eq $b.resourceId })[0]
                if (-not $cl -or -not $rs) { & $bad 'clientId ou resourceId inconnu.' }
                if ($b.consentType -ne 'AllPrincipals') { & $bad 'consentType inattendu.' }
                foreach ($s in @("$($b.scope)" -split '\s+' | Where-Object { $_ })) { if (@($rs.oauth2PermissionScopes | Where-Object { $_.value -eq $s }).Count -eq 0) { & $bad "scope '$s' non publie par la ressource." } }
                if (@($T.Grants | Where-Object { $_.clientId -eq $b.clientId -and $_.resourceId -eq $b.resourceId -and $_.consentType -eq 'AllPrincipals' }).Count -gt 0) { & $bad 'Entity already exists (permission grant)' }
                $g = @{ id = [guid]::NewGuid().ToString(); clientId = $b.clientId; consentType = $b.consentType; resourceId = $b.resourceId; scope = $b.scope }
                $T.Grants.Add($g); & $ok; return (Copy-Mock $g)
            }
            '^/roleManagement/directory/roleAssignments$' {
                if ($b.roleDefinitionId -notin $global:MockRoleTpl.Values) { & $bad "roleDefinitionId inconnu $($b.roleDefinitionId)" }
                if ($b.directoryScopeId -ne '/') { & $bad 'directoryScopeId attendu : /' }
                $isSp = @($T.Sps | Where-Object { $_.id -eq $b.principalId }).Count -gt 0
                $isUser = @($T.Users | Where-Object { $_.id -eq $b.principalId }).Count -gt 0
                if (-not ($isSp -or $isUser)) { & $bad "principalId $($b.principalId) inconnu" }
                if (@($T.RoleAssign | Where-Object { $_.principalId -eq $b.principalId -and $_.roleDefinitionId -eq $b.roleDefinitionId }).Count -gt 0) { & $bad 'The role assignment already exists.' }
                $r = @{ id = [guid]::NewGuid().ToString(); principalId = $b.principalId; roleDefinitionId = $b.roleDefinitionId; directoryScopeId = '/' }
                $T.RoleAssign.Add($r); & $ok; return (Copy-Mock $r)
            }
            '^/users$' {
                foreach ($f in 'accountEnabled', 'displayName', 'mailNickname', 'userPrincipalName', 'passwordProfile') { if ($null -eq $b[$f]) { & $bad "propriete requise manquante : $f" } }
                $pw = "$($b.passwordProfile.password)"
                $cls = 0; foreach ($rx in '[A-Z]', '[a-z]', '\d', '[^A-Za-z0-9]') { if ($pw -cmatch $rx) { $cls++ } }
                if ($pw.Length -lt 8 -or $cls -lt 3) { & $bad 'The specified password does not comply with password complexity requirements.' }
                $dom = ($b.userPrincipalName -split '@')[1]
                if (@($T.Org.verifiedDomains | Where-Object { $_.name -eq $dom }).Count -eq 0) { & $bad "domaine '$dom' non verifie." }
                if (@($T.Users | Where-Object { $_.userPrincipalName -eq $b.userPrincipalName }).Count -gt 0) { & $bad 'Another object with the same value for property userPrincipalName already exists.' }
                $us = @{ id = [guid]::NewGuid().ToString(); userPrincipalName = $b.userPrincipalName; displayName = $b.displayName; mailNickname = $b.mailNickname
                    accountEnabled = [bool]$b.accountEnabled; passwordPolicies = $b.passwordPolicies; employeeType = $b.employeeType; assignedLicenses = @(); PwdMarker = $pw }
                $T.Users.Add($us); & $ok
                $c = @{}; foreach ($k in $us.Keys) { if ($k -ne 'PwdMarker') { $c[$k] = $us[$k] } }; return (Copy-Mock $c)
            }
        }
        $global:MockUnrouted.Add("POST $path"); Add-MockCall 'Graph' $Method $path '404-NONROUTE' $true $bodyTxt
        throw (New-MockError 404 'Request_ResourceNotFound' "MOCK: POST non route $path")
    }

    # PATCH
    switch -Regex ($path) {
        '^/applications/([^/]+)$' {
            $id = $Matches[1]; $a = @($T.Apps | Where-Object { $_.id -eq $id })[0]
            if (-not $a) { & $notFound "application $id inconnue" }
            foreach ($k in @($b.Keys)) {
                if ($k -eq 'keyCredentials') {
                    $new = [System.Collections.Generic.List[object]]::new()
                    $keptIds = @()
                    foreach ($kc in @($b.keyCredentials)) {
                        if ($kc.keyId) {
                            $old = @($a.keyCredentials | Where-Object { $_.keyId -eq $kc.keyId })[0]
                            if (-not $old) { & $bad "keyId $($kc.keyId) inconnu : une cle existante ne peut pas etre recreee sans sa valeur." }
                            $new.Add($old); $keptIds += $kc.keyId
                        } else {
                            if ($kc.type -ne 'AsymmetricX509Cert' -or $kc.usage -ne 'Verify' -or -not $kc.key) { & $bad 'keyCredential invalide (type/usage/key).' }
                            try { $raw = [Convert]::FromBase64String($kc.key); $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($raw) } catch { & $bad "certificat illisible : $($_.Exception.Message)" }
                            $thumb = [Convert]::ToHexString([System.Security.Cryptography.SHA1]::HashData($raw)); $cert.Dispose()   # Graph reel : empreinte en hexadecimal (constate 2026-10-31)
                            $nkid = [guid]::NewGuid().ToString(); $T.KeyPubs[$nkid] = "$($kc.key)"
                            $new.Add(@{ keyId = $nkid; type = $kc.type; usage = $kc.usage; customKeyIdentifier = $thumb; displayName = $kc.displayName; startDateTime = $kc.startDateTime; endDateTime = $kc.endDateTime; key = $null })
                        }
                    }
                    $gone = @($a.keyCredentials | Where-Object { $_.keyId -notin $keptIds })
                    # Graph reel (constate 2026-10-31) : un PATCH qui RETIRE une cle existante est refuse si les cles restantes ne portent pas leur contenu (key).
                    # L'AJOUT (anciennes cles sans key + nouvelle avec key) est accepte ; le retrait passe par POST removeKey.
                    if ($gone.Count -gt 0 -and @($b.keyCredentials | Where-Object { $_.keyId -and -not $_.key }).Count -gt 0) { & $bad 'KeyValue cannot be null or empty.' }
                    $T.RemovedKeys += $gone.Count
                    foreach ($g0 in $gone) { $T.RemovedKeyIds.Add("$($g0.keyId)") }
                    $a.keyCredentials = @($new.ToArray())
                }
                elseif ($k -eq 'requiredResourceAccess') { $a.requiredResourceAccess = @($b.requiredResourceAccess) }
                elseif ($k -in 'web', 'spa', 'publicClient') { $a[$k] = @{ redirectUris = @($b[$k].redirectUris | Where-Object { $_ }) } }
                elseif ($k -in 'tags', 'isFallbackPublicClient', 'displayName', 'signInAudience') { $a[$k] = $b[$k] }
                else { & $bad "propriete non geree par le mock : $k" }
            }
            & $ok; return $null
        }
        '^/oauth2PermissionGrants/([^/]+)$' {
            $id = $Matches[1]; $g = @($T.Grants | Where-Object { $_.id -eq $id })[0]
            if (-not $g) { & $notFound "grant $id inconnu" }
            $g.scope = $b.scope; & $ok; return $null
        }
        '^/users/([^/]+)$' {
            $id = $Matches[1]; $us = @($T.Users | Where-Object { $_.id -eq $id })[0]
            if (-not $us) { & $notFound "utilisateur $id inconnu" }
            foreach ($k in @($b.Keys)) {
                if ($k -eq 'passwordProfile') { $us.PwdMarker = "$($b.passwordProfile.password)" }
                elseif ($k -in 'passwordPolicies', 'employeeType', 'accountEnabled', 'displayName') { $us[$k] = $b[$k] }
                else { & $bad "propriete non geree par le mock : $k" }
            }
            & $ok; return $null
        }
    }
    $global:MockUnrouted.Add("PATCH $path"); Add-MockCall 'Graph' $Method $path '404-NONROUTE' $true $bodyTxt
    throw (New-MockError 404 'Request_ResourceNotFound' "MOCK: PATCH non route $path")
}

function global:Connect-MgGraph {
    [CmdletBinding()]
    param($TenantId, $Scopes, $ContextScope, [switch]$NoWelcome, [switch]$UseDeviceCode, [securestring]$AccessToken)
    Add-MockCall 'Cmd' 'CONNECT' 'Connect-MgGraph' 'OK' $false ("tenant=$TenantId scopes=" + (@($Scopes) -join ',') + $(if ($UseDeviceCode) { ' devicecode=1' } else { '' }) + $(if ($AccessToken) { ' accesstoken=1' } else { '' }))
    if ($global:MockOpts.ConnectFailMessage) { throw $global:MockOpts.ConnectFailMessage }
    if ($global:MockOpts.ConnectFails) { throw 'MOCK: connexion refusee par l''utilisateur.' }
    $tid = if ($global:MockOpts.ConnectTenantId) { $global:MockOpts.ConnectTenantId } else { $TenantId }
    $acc = if ($global:MockOpts.ConnectAccount) { $global:MockOpts.ConnectAccount } else { $global:MockUser }
    $global:MockGraphExpired = $false   # nouvelle connexion = nouveau jeton
    $global:MockMgCtx = [pscustomobject]@{ TenantId = $tid; Account = $acc; Scopes = @($Scopes); ContextScope = $ContextScope }
}
function global:Get-MgContext { [CmdletBinding()] param() $global:MockMgCtx }
function global:Disconnect-MgGraph { [CmdletBinding()] param() Add-MockCall 'Cmd' 'DISCONNECT' 'Disconnect-MgGraph'; $global:MockMgCtx = $null }

# ----------------------------------------------------------------------------------------------
# Faux Exchange Online (v2.2) : Kind 'Exo' pour les lectures / ecritures, Kind 'Cmd' pour connexion / deconnexion.
# ----------------------------------------------------------------------------------------------
$global:MockExoCtx = $null
function global:Connect-ExchangeOnline {
    [CmdletBinding()]
    param([string]$UserPrincipalName, [switch]$ShowBanner, [switch]$Device)
    Add-MockCall 'Cmd' 'CONNECT-EXO' 'Connect-ExchangeOnline' 'OK' $false ("upn=$UserPrincipalName" + $(if ($Device) { ' device=1' } else { '' }))
    if ($global:MockOpts.ExoConnectFails) { throw $global:MockOpts.ExoConnectMessage }
    $tid = if ($global:MockOpts.ExoTenantId) { $global:MockOpts.ExoTenantId } else { $global:MockTenantId }
    $global:MockExoCtx = [pscustomobject]@{ TenantID = $tid; UserPrincipalName = $UserPrincipalName }
}
function global:Get-ConnectionInformation { [CmdletBinding()] param() if ($global:MockExoCtx) { $global:MockExoCtx } }
function global:Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess)] param() Add-MockCall 'Cmd' 'DISCONNECT-EXO' 'Disconnect-ExchangeOnline'; $global:MockExoCtx = $null }
function global:Get-OrganizationConfig {
    [CmdletBinding()]
    param()
    if ($null -eq $global:MockExoCtx) { Add-MockCall 'Exo' 'GET' 'Get-OrganizationConfig' 'NON-CONNECTE'; throw 'MOCK: pas de session Exchange Online.' }
    if ($global:MockOpts.ExoReadFails) { Add-MockCall 'Exo' 'GET' 'Get-OrganizationConfig' 'ECHEC'; throw 'MOCK: Get-OrganizationConfig refuse (droits insuffisants).' }
    Add-MockCall 'Exo' 'GET' 'Get-OrganizationConfig'
    [pscustomobject]@{ EwsEnabled = $global:MockOpts.EwsEnabled; EwsAllowedAppIDs = @($global:MockOpts.EwsList); EwsApplicationAccessPolicy = $null; EwsAllowList = $null; EwsBlockList = $null }
}
function global:Set-OrganizationConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$EwsAllowedAppIDs)
    # Comportement REEL (2026-10-31) : liste de GUID separes par des virgules qui REMPLACE la liste ; tout autre format est refuse.
    $prior = @($global:MockOpts.EwsList)
    $new = @("$EwsAllowedAppIDs" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $notGuid = @($new | Where-Object { $_ -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' })
    $removed = @($prior | Where-Object { $p = $_; @($new | Where-Object { $_ -ieq $p }).Count -eq 0 })
    $added = @($new | Where-Object { $n = $_; @($prior | Where-Object { $_ -ieq $n }).Count -eq 0 })
    $bodyTxt = if ($removed.Count -gt 0) { 'REMOVE=' + ($removed -join ',') } else { 'Add=' + ($added -join ',') }
    Add-MockCall 'Exo' 'SET' 'Set-OrganizationConfig' $(if ($global:MockOpts.ExoSetFails) { 'ECHEC' } else { 'OK' }) $true $bodyTxt
    if ($null -eq $global:MockExoCtx) { throw 'MOCK: pas de session Exchange Online.' }
    if ($global:MockOpts.ExoOnSet) { & $global:MockOpts.ExoOnSet $EwsAllowedAppIDs }
    if ($global:MockOpts.ExoSetFails) { throw 'MOCK: Set-OrganizationConfig refuse (droits insuffisants).' }
    if ($new.Count -eq 0 -or $notGuid.Count -gt 0) { throw "||Invalid value provided for parameter EwsAllowedAppIDs '$EwsAllowedAppIDs'. Please provide comma separated values of valid GUIDs." }
    $global:MockOpts.EwsList = $new
}


# ----------------------------------------------------------------------------------------------
# Faux Cloudiway
# ----------------------------------------------------------------------------------------------
# rawsettings re-serialise par le portail : seules les cles connues sont conservees (fait mesure 3 : toute cle inconnue est supprimee).
$global:MockRawKnown = @('TenantName', 'RestClientId', 'RestClientSecret', 'Domains', 'MigrationAccount', 'MigrationAccountPassword', 'ServerRegion', 'AuthenticationType')
function global:ConvertTo-MockRawSettings($Raw) {
    if ($Raw -isnot [string]) { return $Raw }
    try {
        $h = $Raw | ConvertFrom-Json -AsHashtable
        $o = [ordered]@{}
        foreach ($k in @($h.Keys)) { if ($global:MockRawKnown -contains "$k") { $o[$k] = $h[$k] } }
        return ($o | ConvertTo-Json -Compress -Depth 8)
    } catch { return $Raw }
}
# Reponse perdue : l'ecriture est appliquee, l'appel leve (option CiwLoseResponse, Times decremente)
function global:Test-MockLostResponse([string]$Method, [string]$Path) {
    $l = Test-MockPattern $global:MockOpts.CiwLoseResponse $Method $Path
    if ($l -and [int]$l.Times -gt 0) { $l.Times = [int]$l.Times - 1; return $true }
    return $false
}
function global:Get-MockLostCode([string]$Method, [string]$Path) {
    $l = Test-MockPattern $global:MockOpts.CiwLoseResponse $Method $Path
    if ($l -and $l.Code) { return [int]$l.Code }
    return 504
}
function global:Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method = 'GET', $Headers, $Body, $ContentType, $TimeoutSec)
    $CW = $global:MockCiw
    $u = [uri]$Uri
    # Metadonnee OIDC PUBLIQUE de Microsoft (resolution domaine -> GUID, sans authentification) : seul appel autorise vers login.microsoftonline.com
    if ($u.Host -eq 'login.microsoftonline.com' -and $u.AbsolutePath -match '^/([^/]+)/v2\.0/\.well-known/openid-configuration$' -and $Method -eq 'GET') {
        $dom = $Matches[1].ToLowerInvariant()
        $guid = $global:MockOpts.OidcDomains[$dom]
        if (-not $guid) { Add-MockCall 'Oidc' 'GET' $dom '400' $false; throw (New-MockError 400 'AADSTS90002' "AADSTS90002: Tenant '$dom' not found.") }
        Add-MockCall 'Oidc' 'GET' $dom 'OK' $false
        return ([pscustomobject]@{ issuer = "https://login.microsoftonline.com/$guid/v2.0"; token_endpoint = "https://login.microsoftonline.com/$guid/oauth2/v2.0/token"; authorization_endpoint = "https://login.microsoftonline.com/$guid/oauth2/v2.0/authorize" })
    }
    # Flux "code d'appareil" (login.microsoftonline.com/<tenant>/oauth2/v2.0/devicecode puis /token) : jeton factice portant tid et upn.
    if ($u.Host -eq 'login.microsoftonline.com' -and $u.AbsolutePath -match '^/([^/]+)/oauth2/v2\.0/(devicecode|token)$' -and $Method -eq 'POST') {
        $tid = $Matches[1]; $ep = $Matches[2]
        if ($ep -eq 'devicecode') {
            Add-MockCall 'DeviceCode' 'POST' 'devicecode' 'OK' $false
            return ([pscustomobject]@{ device_code = 'DEVCODE-MOCK'; user_code = 'ABCD1234'; verification_uri = 'https://microsoft.com/devicelogin'; expires_in = 900; interval = 2 })
        }
        $global:MockDcPolls++
        if ($global:MockOpts.DevicePendingPolls -and $global:MockDcPolls -le [int]$global:MockOpts.DevicePendingPolls) { Add-MockCall 'DeviceCode' 'POST' 'token' 'pending' $false; throw (New-MockOAuthError 'authorization_pending' 'AADSTS70016: OAuth 2.0 device flow error. Authorization is pending.') }
        if ($global:MockOpts.DeviceDeclined) { Add-MockCall 'DeviceCode' 'POST' 'token' 'declined' $false; throw (New-MockOAuthError 'authorization_declined' 'AADSTS70000: The user declined the authorization.') }
        Add-MockCall 'DeviceCode' 'POST' 'token' 'OK' $false
        $gt = if ($global:MockOpts.ConnectTenantId) { $global:MockOpts.ConnectTenantId } else { $tid }
        $ga = if ($global:MockOpts.ConnectAccount) { $global:MockOpts.ConnectAccount } else { $global:MockUser }
        $b64 = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $claims = @{ tid = $gt; scp = 'Application.ReadWrite.All'; exp = [DateTimeOffset]::UtcNow.AddSeconds([int]$global:MockOpts.DeviceTokenLifetimeSec).ToUnixTimeSeconds() }
        if ($global:MockOpts.DeviceNoUpn) { $claims['preferred_username'] = $ga } else { $claims['upn'] = $ga }   # invite B2B : pas d'upn
        $jwt = (& $b64 @{ alg = 'none' }) + '.' + (& $b64 $claims) + '.sig'
        return ([pscustomobject]@{ access_token = $jwt; token_type = 'Bearer'; expires_in = 3600 })
    }    if ($u.Host -ne 'api-production.cloudiway.com') { Add-MockCall 'Ciw' $Method $Uri 'HOST-INTERDIT' $true; throw "MOCK: hote non autorise '$($u.Host)'" }
    $path = $u.AbsolutePath -replace '^/ap1', ''
    $bodyTxt = if ($Body) { [string]$Body } else { '' }
    $isTech = ($path -eq '/Authentication/TechnicalLogin')
    $isLogin = $isTech -or ($path -eq '/Authentication/Login')
    $isWrite = ($Method -in 'POST', 'PUT') -and -not $isLogin -and ($path -ne '/Connectors/Search')
    $fail = { param($code, $msg) Add-MockCall 'Ciw' $Method $path "$code" $isWrite ($(if ($isLogin) { '' } else { $bodyTxt })); throw (New-MockError $code 'CiwError' $msg) }
    $okr = { param($data) Add-MockCall 'Ciw' $Method $path 'OK' $isWrite ($(if ($isLogin) { '' } else { $bodyTxt })); return (Copy-Mock @{ isSuccess = $true; responseData = $data }) }
    if ($Method -notin 'GET', 'POST', 'PUT') { Add-MockCall 'Ciw' $Method $path '405' $true; throw (New-MockError 405 'CiwError' 'methode non prevue') }
    $cf = Test-MockPattern $global:MockOpts.CiwFail $Method $path
    if ($cf -and [int]$cf.Skip -gt 0) { $cf.Skip = [int]$cf.Skip - 1; $cf = $null }   # v2.4 : Skip = nombre d'appels correspondants laisses passer avant la panne
    if ($cf -and $cf.Times -gt 0) { $cf.Times--; & $fail ([int]$cf.Code) 'Service indisponible simule.' }
    foreach ($rx in @($global:MockOpts.CiwDown)) { if ($rx -and $path -match $rx) { & $fail 500 'Erreur interne simulee.' } }

    if ($isTech) {
        $j = $bodyTxt | ConvertFrom-Json -AsHashtable
        if ($Method -ne 'POST' -or $j.pat -ne $CW.ValidPat) { & $fail 401 'PAT invalide ou expire.' }
        return (& $okr @{ token = $CW.Token })
    }
    if ($isLogin) {
        # v2 : identifiant + mot de passe du DSI. Mode 'cookie' : le champ token vaut litteralement "token" (le vrai jeton est dans Set-Cookie).
        $j = $bodyTxt | ConvertFrom-Json -AsHashtable
        # keepConnection doit valoir $true (un jeton non persistant expirerait pendant l'execution)
        if ($Method -ne 'POST' -or $j.login -ne $CW.ValidLogin -or $j.password -ne $CW.ValidPassword -or $j.keepConnection -ne $true) { & $fail 401 'Identifiant ou mot de passe incorrect.' }
        if ($CW.LoginMode -eq '2fa') { return (& $okr @{ twoFactorRequired = $true; login = $j.login }) }   # 2FA : aucun jeton exploitable
        $tok = if ($CW.LoginMode -eq 'cookie') { 'token' } else { $CW.Token }
        return (& $okr @{ token = $tok; login = $j.login })
    }
    # Expiration simulee du jeton : le Nieme appel authentifie correspondant est refuse (401) et le jeton change (un nouveau login redonne un jeton valide)
    foreach ($xr in @($global:MockOpts.CiwExpire)) {
        if ($xr -and (-not $xr.Method -or $xr.Method -eq $Method) -and $path -match $xr.Path) {
            $xr.Seen = 1 + [int]$xr.Seen
            if ($xr.Seen -eq [int]$xr.Nth) { $CW.Token = 'MOCKJWT.' + [guid]::NewGuid().ToString('N') + '.SIG'; & $fail 401 'Jeton expire.' }
        }
    }
    $auth = "$($Headers.Authorization)"
    if ($auth -ne "Bearer $($CW.Token)") { & $fail 401 'Jeton absent ou invalide.' }
    if ($path -eq '/Projects') { return (& $okr @($CW.Projects | ForEach-Object { @{ id = $_; name = "Projet $_" } })) }
    $pid_ = [int]("$($Headers.projectId)" -replace '\D', '0')
    if ($CW.Projects -notcontains $pid_) { & $fail 403 "Acces refuse au projet '$($Headers.projectId)'." }
    $mine = @($CW.Connectors | Where-Object { $_.projectId -eq $pid_ })
    # Lecture d'un connecteur : copie sans _body ; avec CiwMaskSecrets, secrets et contenu du certificat sont masques (comme un portail qui cache ses secrets)
    $view = {
        param($src)
        $c = @{}; foreach ($k in $src.Keys) { if ($k -ne '_body') { $c[$k] = $src[$k] } }
        if ($global:MockOpts.CiwMaskSecrets) {
            if ($c.connectorCertificate) { $cc = @{}; foreach ($k in $c.connectorCertificate.Keys) { $cc[$k] = $c.connectorCertificate[$k] }; $cc.secret = '********'; $cc.certificateFile = '********'; $c.connectorCertificate = $cc }
        }
        if ($global:MockOpts.CiwHideFileName -and $c.connectorCertificate) {
            $cc = @{}; foreach ($k in $c.connectorCertificate.Keys) { if ($k -ne 'fileName') { $cc[$k] = $c.connectorCertificate[$k] } }; $c.connectorCertificate = $cc
        }
        if ($global:MockOpts.CiwMaskSecrets) {
            if ($c.rawSettings) {
                try { $s = $c.rawSettings | ConvertFrom-Json -AsHashtable; foreach ($k in @($s.Keys)) { if ("$k" -match 'Password|Secret') { $s[$k] = '********' } }; $c.rawSettings = ($s | ConvertTo-Json -Compress) } catch { }
            }
        }
        $c
    }
    switch -Regex ($path) {
        '^/Connectors$' {
            if ($Method -eq 'GET') { return (& $okr @($mine | ForEach-Object { & $view $_ })) }
            if ($Method -eq 'POST') {
                $b = $bodyTxt | ConvertFrom-Json -AsHashtable -Depth 50
                foreach ($f in 'connectorTypeId', 'name', 'rawsettings', 'rawProductList') { if ($null -eq $b[$f]) { & $fail 400 "champ requis : $f" } }
                try { $null = $b.rawsettings | ConvertFrom-Json } catch { & $fail 400 'rawsettings n''est pas un JSON valide.' }
                if (@($mine | Where-Object { $_.name -eq $b.name }).Count -gt 0) { & $fail 400 "Un connecteur nomme '$($b.name)' existe deja." }
                if ("$($b.externalKey)".Length -gt 50) { & $fail 500 "Posting connector failed : String or binary data would be truncated in table 'Project_Connectors', column 'ExternalKey'." }
                $CW.PostCount++
                $cfp = "$($b.connectorCertificate.certificateFile)"; if ($cfp -match '\.pfx$') { $CW.CertFileSeen = (Test-Path -LiteralPath $cfp); $CW.CertFilePath = $cfp }   # transport Path : le fichier doit exister au moment de l'appel
                $newId = $CW.NextId++
                # Le portail re-serialise rawsettings : toute cle INCONNUE est supprimee (fait mesure 3)
                $cert0 = $null
                if ($b.ContainsKey('connectorCertificate') -and $b.connectorCertificate) {
                    $cert0 = @{ id = $CW.NextCertId++; connectorId = $newId; fileName = $b.connectorCertificate.fileName; secret = $b.connectorCertificate.secret; certificateFile = $b.connectorCertificate.certificateFile }
                }
                $c = @{ id = $newId; projectId = $pid_; poolId = $(if ($b.ContainsKey('poolId') -and $null -ne $b.poolId) { [int]$b.poolId } else { 3 }); connectorTypeId = $b.connectorTypeId; name = $b.name; isTarget = [bool]$b.isTarget; rawProductList = $b.rawProductList
                    rawSettings = (ConvertTo-MockRawSettings $b.rawsettings); externalKey = $b.externalKey; connectorCertificate = $cert0; _body = $b }
                $CW.Connectors.Add($c)
                if (Test-MockLostResponse $Method $path) { Add-MockCall 'Ciw' $Method $path 'REPONSE-PERDUE' $true $bodyTxt; throw (New-MockError (Get-MockLostCode $Method $path) 'GatewayTimeout' 'Delai depasse : la reponse du portail est perdue (l''ecriture a ete traitee).') }
                return (& $okr @{ id = $c.id; name = $c.name })
            }
        }
        '^/Connectors/Search$' {
            $b = $bodyTxt | ConvertFrom-Json -AsHashtable
            return (& $okr @{ items = @($mine | Where-Object { $_.name -like "*$($b.name)*" } | ForEach-Object { & $view $_ }) })
        }
        '^/Connectors/(\d+)$' {
            $id = [int]$Matches[1]; $c = @($mine | Where-Object { $_.id -eq $id })[0]
            if (-not $c) { & $fail 404 "connecteur $id introuvable" }
            if ($Method -eq 'GET') { return (& $okr (& $view $c)) }
            if ($Method -eq 'PUT') {
                $b = $bodyTxt | ConvertFrom-Json -AsHashtable -Depth 50
                $CW.PutAttempts++
                if ($b.id -ne $id) { & $fail 400 'id du corps different de celui de l''URL.' }
                if ("$($b.externalKey)".Length -gt 50) { & $fail 500 "Posting connector failed : String or binary data would be truncated in table 'Project_Connectors', column 'ExternalKey'." }
                $sentCert = ($b.ContainsKey('connectorCertificate') -and $b.connectorCertificate)
                # Fait mesure 4 : un PUT SANS connectorCertificate sur un connecteur qui en possede un echoue (HTTP 500) ; le connecteur reste inchange.
                if ($c.connectorCertificate -and -not $sentCert -and -not $global:MockOpts.CiwPutWipes) { & $fail 500 'Object reference not set to an instance of an object.' }
                $CW.PutCount++
                $cfp = "$($b.connectorCertificate.certificateFile)"; if ($cfp -match '\.pfx$') { $CW.CertFileSeen = (Test-Path -LiteralPath $cfp); $CW.CertFilePath = $cfp }
                $old0 = $null; try { $old0 = $c.rawSettings | ConvertFrom-Json -AsHashtable } catch { }
                $c.name = $b.name; $c.isTarget = [bool]$b.isTarget; $c.rawProductList = $b.rawProductList
                $rawIn = $(if ($b.ContainsKey('rawSettings')) { $b.rawSettings } else { $b.rawsettings })
                $c.rawSettings = (ConvertTo-MockRawSettings $rawIn)   # cles inconnues supprimees (fait mesure 3)
                # Fait mesure 5 : un PUT sans poolId / connectorTypeId les remet a 0
                if ($c.ContainsKey('poolId')) { $c.poolId = $(if ($b.ContainsKey('poolId') -and $null -ne $b.poolId) { [int]$b.poolId } else { 0 }) }
                $c.connectorTypeId = $(if ($b.ContainsKey('connectorTypeId') -and $null -ne $b.connectorTypeId) { $b.connectorTypeId } else { 0 })
                # Fait mesure 3 : externalKey n'est JAMAIS modifie par un PUT (fige a la creation) ; $c.externalKey reste tel quel.
                $c._body = $b
                if ($sentCert -and -not $global:MockOpts.CiwPutIgnoresCert) {
                    # Fait mesure 2 : le certificat est remplace SUR PLACE (meme id, nouveau fileName)
                    $cid0 = $(if ($c.connectorCertificate -and $c.connectorCertificate.id) { $c.connectorCertificate.id } else { $CW.NextCertId++ })
                    $c.connectorCertificate = @{ id = $cid0; connectorId = $c.id; fileName = $b.connectorCertificate.fileName; secret = $b.connectorCertificate.secret; certificateFile = $b.connectorCertificate.certificateFile }
                }
                elseif ($global:MockOpts.CiwPutWipes -and -not $sentCert) { $c.connectorCertificate = $null }
                # Mot de passe du compte de migration / secret client : conserves s'ils sont omis du corps
                try { $old = $old0; $ns = $c.rawSettings | ConvertFrom-Json -AsHashtable; foreach ($k in @($old.Keys)) { if ("$k" -match 'Password|Secret' -and -not $ns.ContainsKey($k)) { $ns[$k] = $old[$k] } }; $c.rawSettings = ($ns | ConvertTo-Json -Compress) } catch { }
                if (Test-MockLostResponse $Method $path) { Add-MockCall 'Ciw' $Method $path 'REPONSE-PERDUE' $true $bodyTxt; throw (New-MockError (Get-MockLostCode $Method $path) 'GatewayTimeout' 'Delai depasse : la reponse du portail est perdue (l''ecriture a ete traitee).') }
                return (& $okr @{ id = $c.id })
            }
        }
    }
    $global:MockUnrouted.Add("CIW $Method $path"); & $fail 404 "MOCK: route Cloudiway non geree : $Method $path"
}

# ----------------------------------------------------------------------------------------------
# Poste de travail : preflight, modules, questions, sommeil
# ----------------------------------------------------------------------------------------------
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $Method, $Body, $ContentType, $Headers, $TimeoutSec, [switch]$UseBasicParsing, [switch]$SkipHttpErrorCheck)
    $u = [uri]$Uri
    $h = $u.Host
    # Repli "cookies" du login Cloudiway (v2) : POST /Authentication/Login, le vrai jeton est dans l'en-tete Set-Cookie
    if ($h -eq 'api-production.cloudiway.com' -and $u.AbsolutePath -eq '/ap1/Authentication/Login' -and $Method -eq 'POST') {
        $CW = $global:MockCiw
        $j = ([string]$Body) | ConvertFrom-Json -AsHashtable
        if ($j.login -ne $CW.ValidLogin -or $j.password -ne $CW.ValidPassword) { Add-MockCall 'Ciw' 'POST' '/Authentication/Login' '401' $false ''; throw (New-MockError 401 'CiwError' 'Identifiant ou mot de passe incorrect.') }
        Add-MockCall 'Ciw' 'POST' '/Authentication/Login' 'OK' $false ''
        if ($CW.LoginMode -eq '2fa') { return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{"isSuccess":true,"responseData":{"twoFactorRequired":true}}' } }
        return [pscustomobject]@{ StatusCode = 200; Headers = @{ 'Set-Cookie' = @("ciw-session=$($CW.Token); path=/; secure; httponly") }; Content = '{"isSuccess":true,"responseData":{"token":"token"}}' }
    }
    Add-MockCall 'Cmd' 'HTTPS' $h
    if ($global:MockOpts.NetDown -contains $h) { throw [System.Net.Http.HttpRequestException]::new("No such host is known. ($h)") }
    if ([int]$global:MockOpts.ClockSkewMinutes -ne 0) {
        # le poste est en avance de N minutes : les serveurs annoncent une date N minutes dans le passe
        $srv = [datetime]::UtcNow.AddMinutes(-[int]$global:MockOpts.ClockSkewMinutes)
        return [pscustomobject]@{ StatusCode = 200; Headers = @{ Date = $srv.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture) } }
    }
    [pscustomobject]@{ StatusCode = 200 }
}
function global:Get-Module {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name, [switch]$ListAvailable)
    if ($ListAvailable -and -not $global:MockOpts.ModuleMissing -and $Name -eq 'Microsoft.Graph.Authentication') { return [pscustomobject]@{ Name = $Name; Version = [version]'2.25.0' } }
    if ($ListAvailable -and -not $global:MockOpts.ExoModuleMissing -and $Name -eq 'ExchangeOnlineManagement') { return [pscustomobject]@{ Name = $Name; Version = [version]'3.7.0' } }
    return $null
}
function global:Import-Module {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    Add-MockCall 'Cmd' 'IMPORT' $Name
    if ($Name -eq 'ExchangeOnlineManagement') { if ($global:MockOpts.ExoModuleMissing) { throw "MOCK: module $Name introuvable." }; return }
    if ($global:MockOpts.ModuleMissing) { throw "MOCK: module $Name introuvable." }
}
function global:Install-Module { [CmdletBinding()] param([Parameter(Position = 0)][string]$Name, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber) Add-MockCall 'Cmd' 'INSTALL-MODULE' $Name; if ($Name -eq 'ExchangeOnlineManagement') { $global:MockOpts.ExoModuleMissing = $false } else { $global:MockOpts.ModuleMissing = $false } }
function global:Get-PSRepository { [CmdletBinding()] param($Name) [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = 'Trusted' } }
function global:Set-PSRepository { [CmdletBinding()] param($Name, $InstallationPolicy) Add-MockCall 'Cmd' 'SET-PSREPOSITORY' $Name }
function global:Get-PackageProvider { [CmdletBinding()] param($Name, [switch]$ListAvailable) [pscustomobject]@{ Name = 'NuGet'; Version = [version]'2.8.5.208' } }
function global:Install-PackageProvider { [CmdletBinding()] param($Name, $Scope, [switch]$Force) Add-MockCall 'Cmd' 'INSTALL-PKGPROVIDER' $Name }
function global:Start-Sleep { [CmdletBinding()] param([int]$Seconds, [int]$Milliseconds) $global:MockSleeps.Add($Seconds) }

function global:Read-Host {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Prompt, [switch]$AsSecureString, [switch]$MaskInput)
    $global:MockReadLog.Add($Prompt)
    if ($global:MockReadQueue.Count -eq 0) { $global:MockReadExhausted = $true; throw "MOCK Read-Host : file de reponses vide pour la question '$Prompt'" }
    $v = $global:MockReadQueue.Dequeue()
    if ($AsSecureString) { return (New-TestSecure ([string]$v)) }
    return [string]$v
}

# Interruption simulee (Ctrl+C / exception hors des Apply) : Get-Date leve quand $global:MockThrowOnDate est arme ET que l'appel vient
# du CODE PRINCIPAL du script (pas d'une fonction qui capte ses erreurs). Arme par le banc via OnWrite, apres la derniere ecriture.
function global:Get-Date {
    [CmdletBinding()]
    param([Parameter(Position = 0)][datetime]$Date, [string]$Format, [string]$UFormat)
    if ($global:MockThrowOnDate -and "$((Get-PSCallStack)[1].Command)" -like '*cloudiway-connector.ps1') { $global:MockThrowOnDate = $false; throw 'MOCK: interruption simulee' }
    Microsoft.PowerShell.Utility\Get-Date @PSBoundParameters
}
