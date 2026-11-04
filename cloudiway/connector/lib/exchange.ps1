# exchange.ps1 - Exchange Online (EWS) pour la charge Mail.
# Connexion Exchange Online avec le compte -Admin365 (module ExchangeOnlineManagement), lecture SEULE de
# Get-OrganizationConfig avant le plan, puis ajout de l'AppID de l'application dans EwsAllowedAppIDs (Set-OrganizationConfig, AJOUT seul).
# Regles : jamais de remplacement ni de retrait dans EwsAllowedAppIDs ; une liste VIDE n'est creee qu'avec une confirmation explicite
# (effet de bord : elle devient restrictive pour toutes les autres applications EWS du tenant) ; EwsEnabled = False n'est jamais modifie ;
# tout echec est NON BLOQUANT pour le reste (etape manuelle avec les commandes exactes). Aucun secret manipule ici.

$script:ExoModule = 'ExchangeOnlineManagement'
$script:ExoMinVersion = [version]'3.0.0'
$script:Exo = $null

function Reset-ExoState {
    $script:Exo = @{
        Needed          = $false    # Charge Mail choisies
        ModuleOk        = $false    # module present (version suffisante)
        ModuleDetail    = ''
        Connected       = $false
        Reused          = $false    # v2.5 : session Exchange Online EXISTANTE du meme tenant et du meme compte, reutilisee (aucune nouvelle connexion)
        ForeignSession  = ''        # v2.5 : description d'une session Exchange Online d'un AUTRE tenant / compte ouverte dans la console ('' = aucune)
        Session         = $null     # v2.5 : resultat de Get-ExoSessionState (controle precoce du script principal)
        ConnectError    = ''
        Read            = $false    # Get-OrganizationConfig lu avec succes
        ReadError       = ''
        EwsEnabled      = $null     # $true / $false / $null (non defini)
        EwsList         = @()       # EwsAllowedAppIDs (chaines)
        Legacy          = ''        # champs EWS annexes (journal seulement)
        CreateApproved  = $false    # creation d'une liste vide autorisee (-AllowEwsListCreation ou confirmation)
        PlanFailure     = $false    # etape manuelle decidee au moment du plan (module, connexion, lecture) : code de sortie 2
        Manual          = [System.Collections.Generic.List[object]]::new()   # "A faire" : @{ Title; Text; Command }
        Verify          = [System.Collections.Generic.List[object]]::new()   # "A verifier"
    }
}
Reset-ExoState

# Charges qui exigent Exchange Online : Mail uniquement.
function Test-ExchangeNeeded($Workloads) {
    $w = @($Workloads)
    return [bool](($w -contains 'Mail') -or ($w -contains 'Archive'))
}

function Add-ExoManual([string]$Title, [string]$Text, [string[]]$Command = @()) {
    if (@($script:Exo.Manual | Where-Object { $_.Title -eq $Title }).Count -eq 0) { $script:Exo.Manual.Add(@{ Title = $Title; Text = $Text; Command = @($Command) }) }
}
function Add-ExoVerify([string]$Title, [string]$Text, [string[]]$Command = @()) {
    if (@($script:Exo.Verify | Where-Object { $_.Title -eq $Title }).Count -eq 0) { $script:Exo.Verify.Add(@{ Title = $Title; Text = $Text; Command = @($Command) }) }
}

# AppID de l'application : valeur creee pendant ce passage, sinon application deja existante lue dans le tenant.
function Get-ExoAppId {
    $id = $null
    try { $id = $script:Ctx.Created['AppId'] } catch { }
    if (-not $id) { try { $id = $script:EntraState.App.appId } catch { } }
    if (-not $id) { try { $id = $script:EntraState.Application.appId } catch { } }
    if ($id) { return [string]$id }
    return ''
}

# Commandes exactes a copier pour faire l'etape a la main (module, connexion, lecture, ecriture).
function Get-ExoManualCommands([string]$AppId, [switch]$IncludeInstall, [switch]$IncludeWrite) {
    $app = if ($AppId) { $AppId } else { '<AppID>' }
    $admin = ''
    try { $admin = [string]$script:Ctx.Admin365 } catch { }
    if (-not $admin) { $admin = '<admin365@contoso.com>' }
    $c = [System.Collections.Generic.List[string]]::new()
    if ($IncludeInstall) { $c.Add("Install-Module -Name $($script:ExoModule) -Scope CurrentUser -Force -AllowClobber") }
    $c.Add("Connect-ExchangeOnline -UserPrincipalName '" + ($admin -replace "'", "''") + "'")   # m10 : valeur entre apostrophes (doublees)
    $c.Add('Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs')
    if ($IncludeWrite) {
        # Syntaxe reelle : liste de GUID separes par des virgules (et non @{Add=...}) qui REMPLACE la liste : on reecrit donc la liste existante + l'AppID.
        $c.Add('$ids = @((Get-OrganizationConfig).EwsAllowedAppIDs) + ''' + $app + '''')
        $c.Add('Set-OrganizationConfig -EwsAllowedAppIDs (($ids | Where-Object { $_ } | Select-Object -Unique) -join '','')')
    }
    $c.Add('# Conseil : fermez la console PowerShell apres usage.')
    return @($c)
}

# Normalise la liste EwsAllowedAppIDs lue (MultiValuedProperty, tableau, chaine ou $null) en tableau de chaines non vides.
function ConvertTo-ExoList($Value) {
    return @(@($Value) | ForEach-Object { if ($null -ne $_) { "$_".Trim() } } | Where-Object { $_ })
}

# EwsEnabled lu : $true / $false / $null (non defini ou illisible).
function ConvertTo-ExoBool($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [bool]$Value }
    $s = "$Value".Trim()
    if ($s -ieq 'true') { return $true }
    if ($s -ieq 'false') { return $false }
    return $null
}

# v2.5 (A) : sessions Exchange Online DEJA ouvertes dans cette console (Get-ConnectionInformation). Lecture seule, ne leve jamais.
# Retourne { Foreign (bool : au moins une session d'un AUTRE tenant ou compte) ; Match (bool : une session du MEME tenant et du MEME compte, et aucune
# autre) ; Detail (tenant / compte de la session etrangere, jamais de secret) }. On ne tente JAMAIS de reutiliser une session etrangere ni de la
# fermer (Disconnect-ExchangeOnline fait planter le processus) : la regle est « une console PowerShell par tenant ».
function Get-ExoSessionState {
    [CmdletBinding()]
    param([string]$Admin, [string]$TenantId)
    $res = [pscustomobject]@{ Foreign = $false; Match = $false; Detail = '' }
    try {
        if (-not (Get-Command -Name Get-ConnectionInformation -ErrorAction SilentlyContinue)) { return $res }
        $all = @(Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_ })
        $foreign = [System.Collections.Generic.List[string]]::new()
        $same = 0
        foreach ($ci in $all) {
            $st = ''
            try { $st = "$($ci.State)".Trim() } catch { }
            if ($st -ieq 'Disconnected') { continue }
            $gotTenant = "$($ci.TenantID)".Trim().ToLowerInvariant()
            $gotUser = "$($ci.UserPrincipalName)".Trim().ToLowerInvariant()
            $badTenant = ($TenantId -and $gotTenant -and $gotTenant -ne $TenantId.Trim().ToLowerInvariant())
            $badUser = ($Admin -and $gotUser -and $gotUser -ne $Admin.Trim().ToLowerInvariant())
            if ($badTenant -or $badUser) { $foreign.Add(("tenant {0}, compte {1}" -f $(if ($gotTenant) { $gotTenant } else { '?' }), $(if ($gotUser) { $gotUser } else { '?' }))) }
            elseif ($gotTenant -or $gotUser) { $same++ }
        }
        if ($foreign.Count -gt 0) { $res.Foreign = $true; $res.Detail = ($foreign | Select-Object -Unique) -join ' ; ' }
        elseif ($same -gt 0) { $res.Match = $true }
    } catch { }
    return $res
}

# Texte unique (console, plan, rapport) de l'etape Exchange impossible a cause d'une session d'un autre tenant.
function Get-ExoForeignSessionText {
    return 'une session Exchange Online d''un autre tenant est ouverte dans cette console : fermez cette console, ouvrez-en une NOUVELLE pour ce tenant (une console par tenant) puis relancez la meme commande.'
}

# Connexion Exchange Online avec le compte administrateur. Retourne { Ok; Error }. Ne leve jamais.
# -UseDeviceCode : parametre -Device du module (code d'appareil). Controle du tenant (et du compte) si Get-ConnectionInformation existe.
function Connect-ExchangeAdmin {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Admin, [string]$TenantId, [switch]$UseDeviceCode, [securestring]$AccessToken, [string]$Organization)
    $exoTokPlain = $null
    try {
        Import-Module $script:ExoModule -WarningAction SilentlyContinue -ErrorAction Stop
        $p = @{ UserPrincipalName = $Admin; ShowBanner = $false; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
        if ($AccessToken) {
            # v2.6 (automatisation) : jeton Exchange Online fourni. Tenant et compte controles dans SES revendications AVANT toute connexion (comme Graph) ;
            # refus aussi s'il expire dans moins de 15 minutes (la session issue d'un jeton ne se renouvelle pas). Le texte du jeton n'est jamais journalise.
            $exoTokPlain = ConvertFrom-SecureStringPlain $AccessToken
            $cl = ConvertFrom-JwtPayload $exoTokPlain
            $tTok = if ($cl) { "$($cl.tid)".Trim().ToLowerInvariant() } else { '' }
            $aTok = (Get-JwtAccount $cl).Trim().ToLowerInvariant()
            if (-not $cl -or -not $tTok) { throw 'jeton Exchange fourni illisible (revendications absentes) : refuse' }
            if ($TenantId -and $tTok -ne $TenantId.Trim().ToLowerInvariant()) { throw ("jeton Exchange fourni refuse : tenant different de celui demande (attendu {0} ; jeton {1})" -f $TenantId, $tTok) }
            if ($aTok -and $aTok -ne $Admin.Trim().ToLowerInvariant()) { throw ("jeton Exchange fourni refuse : compte different de celui demande (attendu {0} ; jeton {1})" -f $Admin, $aTok) }
            $xe = Get-JwtExpiry $cl
            if (-not $xe -or ($xe - [datetime]::UtcNow).TotalMinutes -lt 15) { throw 'jeton Exchange fourni expire ou presque (moins de 15 minutes, ou expiration illisible) : refuse' }
            if (-not $Organization) { throw 'domaine .onmicrosoft.com initial du tenant inconnu : -Organization requis avec un jeton Exchange' }
            $p['AccessToken'] = $exoTokPlain
            $p['Organization'] = $Organization
        }
        elseif ($UseDeviceCode) { $p['Device'] = $true }
        Connect-ExchangeOnline @p | Out-Null
        $script:Exo.Connected = $true
    } catch {
        $m = ("" + $_.Exception.Message) -replace '\s+', ' '
        $script:Exo.Connected = $false
        return [pscustomobject]@{ Ok = $false; Error = $m }
    } finally {
        $exoTokPlain = $null; $p = $null
    }
    # Controle strict : le tenant (et le compte) obtenus doivent etre ceux demandes (meme logique que pour Graph).
    try {
        if (Get-Command -Name Get-ConnectionInformation -ErrorAction SilentlyContinue) {
            $ci = @(Get-ConnectionInformation -ErrorAction Stop | Select-Object -First 1)
            if ($ci.Count -gt 0 -and $ci[0]) {
                $gotTenant = "$($ci[0].TenantID)".Trim().ToLowerInvariant()
                $gotUser = "$($ci[0].UserPrincipalName)".Trim().ToLowerInvariant()
                $badTenant = ($TenantId -and $gotTenant -and $gotTenant -ne $TenantId.ToLowerInvariant())
                $badUser = ($gotUser -and $gotUser -ne $Admin.ToLowerInvariant())
                if ($badTenant -or $badUser) {
                    Disconnect-Exchange
                    return [pscustomobject]@{ Ok = $false; Error = ("connexion refusee : tenant ou compte different de celui demande (attendu tenant {0} et compte {1} ; obtenu tenant {2}, compte {3})" -f $TenantId, $Admin, $gotTenant, $gotUser) }
                }
            }
        }
    } catch { }
    return [pscustomobject]@{ Ok = $true; Error = '' }
}

# Fin de session Exchange (idempotente, ne leve jamais). Appelee en fin de run et dans le finally global (Ctrl+C compris).
# ATTENTION : on n'appelle volontairement PAS Disconnect-ExchangeOnline. Constate le 2026-10-31 avec une session ouverte par code d'appareil :
# ce cmdlet efface les jetons dans une tache de fond (MSALTokenProvider.ClearAllTokensAsync) et leve une exception NON GEREE
# (MsalRuntimeException AccountNotFound) qui arrete tout le processus PowerShell, impossible a intercepter. La session Exchange vit dans le
# processus et disparait avec la console ; l'outil ne laisse rien sur disque.
function Disconnect-Exchange {
    if ($script:Exo -and $script:Exo.Connected) {
        $script:Exo.Connected = $false
    }
}

# Lecture SEULE de la configuration EWS de l'organisation. Retourne { Ok; Error; EwsEnabled; EwsList; Legacy }. Ne leve jamais.
function Read-ExchangeEws {
    [CmdletBinding()]
    param()
    try {
        $o = Get-OrganizationConfig -ErrorAction Stop
        $en = ConvertTo-ExoBool $o.EwsEnabled
        $list = ConvertTo-ExoList $o.EwsAllowedAppIDs
        # Champs EWS annexes documentes (docs\microsoft-365\03) : journal seulement, ils ne pilotent aucune decision.
        $legacy = "EwsApplicationAccessPolicy=$($o.EwsApplicationAccessPolicy) EwsAllowList=$(@(ConvertTo-ExoList $o.EwsAllowList).Count) EwsBlockList=$(@(ConvertTo-ExoList $o.EwsBlockList).Count)"
        return [pscustomobject]@{ Ok = $true; Error = ''; EwsEnabled = $en; EwsList = $list; Legacy = $legacy }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = (("" + $_.Exception.Message) -replace '\s+', ' '); EwsEnabled = $null; EwsList = @(); Legacy = '' }
    }
}

# Etape "Exchange" du script principal, avant le plan : module, connexion, lecture. Retourne des lignes { Level; Text; Detail } a afficher.
function Initialize-ExchangeState {
    [CmdletBinding()]
    param([string]$Admin, [string]$TenantId, [switch]$UseDeviceCode, [securestring]$AccessToken, [string]$Organization)
    $out = [System.Collections.Generic.List[object]]::new()
    $ex = $script:Exo
    if (-not $ex.Needed) { return @($out) }
    if (-not $ex.ModuleOk) {
        $ex.PlanFailure = $true
        $out.Add([pscustomobject]@{ Level = 'WARN'; Text = "Module $($script:ExoModule) absent : l'etape Exchange (EWS) sera a faire a la main."; Detail = "le reste de la configuration continue ; $($ex.ModuleDetail)" })
        return @($out)
    }
    # v2.5 (A) : session deja ouverte dans la console. Autre tenant / autre compte : ni reutilisation ni deconnexion, etape manuelle. Meme tenant et
    # meme compte : session reutilisee (pas de nouvelle connexion).
    $ss = $ex.Session
    if ($null -eq $ss) { $ss = Get-ExoSessionState -Admin $Admin -TenantId $TenantId }
    if ($ss.Foreign) {
        $ex.ForeignSession = [string]$ss.Detail
        $ex.PlanFailure = $true
        $out.Add([pscustomobject]@{ Level = 'WARN'; Text = ('Etape Exchange (EWS) ignoree : ' + (Get-ExoForeignSessionText)); Detail = ('session trouvee : ' + [string]$ss.Detail + ' ; le reste de la configuration continue') })
        return @($out)
    }
    $cn = $null
    if ($ss.Match) {
        $ex.Connected = $true
        $ex.Reused = $true
        $out.Add([pscustomobject]@{ Level = 'OK'; Text = 'Session Exchange Online existante (meme tenant, meme compte) reutilisee.'; Detail = 'aucune nouvelle connexion' })
    } else {
        $out.Add([pscustomobject]@{ Level = 'WAIT'; Text = $(if ($AccessToken) { 'Connexion Exchange Online par jeton d''acces fourni (-ExchangeAccessToken) : aucune fenetre.' } elseif ($UseDeviceCode) { 'Connexion Exchange Online par code d''appareil : un code va s''afficher, a saisir sur https://microsoft.com/devicelogin.' } else { 'Connexion Exchange Online : une fenetre de connexion peut s''ouvrir.' }); Detail = "compte attendu : $Admin" })
        $cn = Connect-ExchangeAdmin -Admin $Admin -TenantId $TenantId -UseDeviceCode:$UseDeviceCode -AccessToken $AccessToken -Organization $Organization
        if (-not $cn.Ok) {
            $ex.ConnectError = [string]$cn.Error
            $ex.PlanFailure = $true
            $out.Add([pscustomobject]@{ Level = 'WARN'; Text = 'Connexion Exchange Online impossible : l''etape Exchange (EWS) sera a faire a la main.'; Detail = [string]$cn.Error })
            return @($out)
        }
        $out.Add([pscustomobject]@{ Level = 'OK'; Text = 'Connecte a Exchange Online.'; Detail = 'lecture seule avant le plan' })
    }
    $rd = Read-ExchangeEws
    if (-not $rd.Ok -and $ex.Reused) {
        # La session reutilisee est inutilisable (jeton expire ?) : une connexion normale, une seule fois.
        $ex.Reused = $false
        $out.Add([pscustomobject]@{ Level = 'WAIT'; Text = 'La session existante ne repond pas : nouvelle connexion Exchange Online.'; Detail = "compte attendu : $Admin" })
        $cn = Connect-ExchangeAdmin -Admin $Admin -TenantId $TenantId -UseDeviceCode:$UseDeviceCode -AccessToken $AccessToken -Organization $Organization
        if (-not $cn.Ok) {
            $ex.ConnectError = [string]$cn.Error
            $ex.PlanFailure = $true
            $out.Add([pscustomobject]@{ Level = 'WARN'; Text = 'Connexion Exchange Online impossible : l''etape Exchange (EWS) sera a faire a la main.'; Detail = [string]$cn.Error })
            return @($out)
        }
        $rd = Read-ExchangeEws
    }
    if (-not $rd.Ok) {
        $ex.ReadError = [string]$rd.Error
        $ex.PlanFailure = $true
        $out.Add([pscustomobject]@{ Level = 'WARN'; Text = 'Lecture de la configuration EWS impossible (Get-OrganizationConfig) : l''etape Exchange (EWS) sera a faire a la main.'; Detail = [string]$rd.Error })
        return @($out)
    }
    $ex.Read = $true
    $ex.EwsEnabled = $rd.EwsEnabled
    $ex.EwsList = @($rd.EwsList)
    $ex.Legacy = [string]$rd.Legacy
    $en = if ($null -eq $rd.EwsEnabled) { 'non defini' } else { "$($rd.EwsEnabled)" }
    $out.Add([pscustomobject]@{ Level = 'INFO'; Text = 'Configuration EWS de l''organisation lue.'; Detail = ("EwsEnabled = {0} ; EwsAllowedAppIDs : {1} entree(s)" -f $en, @($rd.EwsList).Count) })
    return @($out)
}

# Plan de la zone "Exchange" (apres Roles). Appele par New-EntraPlan. Ajoute AU PLUS une ligne.
function New-ExchangePlan {
    [CmdletBinding()]
    param()
    $ex = $script:Exo
    if (-not $ex -or -not $ex.Needed) { return }
    $name = 'EWS : AppID dans EwsAllowedAppIDs'
    $appId = Get-ExoAppId
    $appTxt = if ($appId) { $appId } else { '<AppID>' }
    $yes = $false; $allow = $false
    try { $yes = [bool]$script:Ctx.Yes } catch { }
    try { $allow = [bool]$script:Ctx.AllowEwsListCreation } catch { }

    # Etape impossible (module, connexion, lecture) : ligne IGNOREE, etape manuelle, code de sortie 2
    if ($ex.PlanFailure -and $ex.ForeignSession) {
        [void](Add-PlanItem 'Exchange' $name 'SKIP' ('session Exchange Online d''un autre tenant ouverte dans cette console : etape a faire a la main (voir A faire)'))
        Add-ExoManual 'Exchange Online : une session d''un autre tenant est ouverte dans cette console (une console par tenant)' ((Get-ExoForeignSessionText) + " Session trouvee : $($ex.ForeignSession). Si vous preferez faire l'etape a la main, dans une console NOUVELLE : lire d'abord EwsAllowedAppIDs (si elle est deja renseignee, la reecrire complete de l'AppID ; si elle est VIDE, la definir la rend restrictive pour toutes les autres applications EWS du tenant). AppID a autoriser : $appTxt.") (Get-ExoManualCommands $appId -IncludeInstall:(-not $ex.ModuleOk) -IncludeWrite)
        return
    }
    if ($ex.PlanFailure) {
        $why = if (-not $ex.ModuleOk) { "module $($script:ExoModule) absent" } elseif ($ex.ConnectError) { 'connexion Exchange Online impossible' } else { 'lecture de la configuration EWS impossible' }
        $detail = if ($ex.ConnectError) { " ($($ex.ConnectError))" } elseif ($ex.ReadError) { " ($($ex.ReadError))" } else { '' }
        [void](Add-PlanItem 'Exchange' $name 'SKIP' ("$why$detail : etape a faire a la main (voir A faire)"))
        Add-ExoManual "Mail : autoriser l'application dans Exchange Online (EWS) a la main" ("L'etape automatique n'a pas pu etre realisee ($why). A executer dans PowerShell par un administrateur Exchange. D'abord LIRE la liste : si EwsAllowedAppIDs est deja renseignee, l'ajout (@{Add=...}) la complete sans rien retirer ; si elle est VIDE, la definir rend la liste restrictive pour toutes les autres applications EWS du tenant. AppID a autoriser : $appTxt.") (Get-ExoManualCommands $appId -IncludeInstall:(-not $ex.ModuleOk) -IncludeWrite)
        return
    }

    # EWS desactive pour l'organisation : decision du tenant, jamais modifiee
    if ($ex.EwsEnabled -eq $false) {
        [void](Add-PlanItem 'Exchange' $name 'SKIP' 'EWS desactive pour l''organisation (EwsEnabled = False) : decision a l''echelle du tenant, non modifiee par l''outil (voir A verifier)')
        Add-ExoVerify 'Mail : EWS est desactive pour l''organisation (EwsEnabled = False)' ("Le courrier migre par Cloudiway passe par EWS. L'outil n'ecrit RIEN : reactiver EWS est une decision a l'echelle du tenant (a prendre par l'administrateur Exchange, en connaissance de la fin d'EWS annoncee par Microsoft pour le 2027-04-01), puis relancer la meme commande pour inscrire l'AppID $appTxt.") @('Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs')
        return
    }
    if ($null -eq $ex.EwsEnabled) {
        Add-ExoVerify 'Mail : EwsEnabled n''est pas defini pour l''organisation' 'EwsEnabled vaut Null : Microsoft le fait passer a False pour les tenants qui n''ont rien decide (blocage d''EWS annonce a partir du 2026-10-01). Decision a l''echelle du tenant, jamais modifiee par l''outil : a confirmer avec l''administrateur Exchange avant la migration du courrier.' @('Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs')
    }

    $list = @($ex.EwsList)
    if ($appId -and (@($list | Where-Object { $_ -ieq $appId }).Count -gt 0)) {
        [void](Add-PlanItem 'Exchange' $name 'OK' 'AppID deja present dans EwsAllowedAppIDs')
        return
    }
    if ($list.Count -gt 0) {
        $it = Add-PlanItem 'Exchange' $name 'UPDATE' ("ajout seul de l'AppID dans EwsAllowedAppIDs ({0} entree(s) existante(s) conservee(s), aucun retrait)" -f $list.Count) { Invoke-ExchangeEwsApply }
        return
    }
    # Liste VIDE ou absente : la definir la rend RESTRICTIVE pour toutes les autres applications EWS du tenant
    $effect = 'EwsAllowedAppIDs est VIDE : la definir rend la liste RESTRICTIVE, donc bloque toutes les autres applications EWS du tenant qui n''y figurent pas'
    if ($allow) {
        $ex.CreateApproved = $true
        [void](Add-PlanItem 'Exchange' $name 'UPDATE' ("$effect ; creation autorisee par -AllowEwsListCreation") { Invoke-ExchangeEwsApply })
    } elseif ($yes) {
        [void](Add-PlanItem 'Exchange' $name 'SKIP' ("$effect ; ignoree avec -Yes (ajouter -AllowEwsListCreation pour l'autoriser sans question)"))
        Add-ExoVerify 'Mail : EwsAllowedAppIDs est vide, AppID non inscrit' ("L'outil n'a RIEN ecrit : definir une liste vide la rend restrictive pour toutes les autres applications EWS du tenant (Outlook mobile tiers, outils de sauvegarde, etc.). Decision de l'administrateur Exchange : soit inscrire aussi les autres applications utiles, soit relancer l'outil avec -AllowEwsListCreation pour l'autoriser. AppID : $appTxt.") @('Get-OrganizationConfig | Select-Object EwsEnabled, EwsAllowedAppIDs', ('$ids = @((Get-OrganizationConfig).EwsAllowedAppIDs) + ''' + $appTxt + ''''), 'Set-OrganizationConfig -EwsAllowedAppIDs (($ids | Where-Object { $_ } | Select-Object -Unique) -join '','')')
    } else {
        $it = Add-PlanItem 'Exchange' $name 'UPDATE' ("$effect ; confirmation explicite separee demandee avant l'application (defaut NON)") { Invoke-ExchangeEwsApply }
        Add-Member -InputObject $it -NotePropertyName NeedsConfirm -NotePropertyValue $true -Force
    }
}

# Application : ajout de l'AppID (jamais de remplacement ni de retrait). Retourne $true / $false ; ajoute une etape manuelle en cas d'echec.
function Invoke-ExchangeEwsApply {
    $ex = $script:Exo
    $appId = Get-ExoAppId
    if (-not $appId) {
        $script:EntraLastError = 'AppID de l''application introuvable : impossible d''inscrire l''application dans EwsAllowedAppIDs'
        Add-ExoManual "Mail : autoriser l'application dans Exchange Online (EWS) a la main" 'L''AppID n''a pas pu etre determine. Relancer la meme commande ; sinon inscrire a la main l''AppID de l''application CLOUDIWAY dans EwsAllowedAppIDs.' (Get-ExoManualCommands '' -IncludeWrite)
        return $false
    }
    try {
        # Relecture juste avant l'ecriture : la decision repose sur l'etat REEL (jamais sur le plan seul).
        $cur = Read-ExchangeEws
        if (-not $cur.Ok) { throw "relecture impossible avant l'ecriture : $($cur.Error)" }
        if ($cur.EwsEnabled -eq $false) { throw 'EwsEnabled vaut False : aucune ecriture (decision a l''echelle du tenant)' }
        if (@($cur.EwsList | Where-Object { $_ -ieq $appId }).Count -gt 0) { Write-RunLog 'EWS : AppID deja present a la relecture, aucune ecriture'; return $true }
        if (@($cur.EwsList).Count -eq 0 -and -not $ex.CreateApproved) { throw 'liste vide : la creation n''est pas autorisee (confirmation absente)' }
        # Syntaxe REELLE (constate sur un vrai tenant le 2026-10-31) : -EwsAllowedAppIDs attend des GUID separes par des virgules ; @{Add=...} est
        # refuse (« Please provide comma separated values of valid GUIDs »). La valeur REMPLACE la liste : on reecrit donc la liste existante COMPLETE
        # plus l'AppID (ajout seul, aucune entree retiree). Une entree existante qui n'est pas un GUID arrete l'ecriture (rien n'est altere).
        $guidRe = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
        $notGuid = @($cur.EwsList | Where-Object { $_ -notmatch $guidRe })
        if ($notGuid.Count -gt 0) { throw ('la liste existante contient des valeurs qui ne sont pas des GUID (' + ($notGuid -join ', ') + ') : aucune ecriture, pour ne rien alterer') }
        $merged = [System.Collections.Generic.List[string]]::new()
        foreach ($e in @($cur.EwsList) + @($appId)) { if (-not ($merged | Where-Object { $_ -ieq $e })) { $merged.Add([string]$e) } }
        Set-OrganizationConfig -EwsAllowedAppIDs ($merged -join ',') -ErrorAction Stop | Out-Null
        Write-RunLog ("EWS : AppID {0} ajoute a EwsAllowedAppIDs ({1} entree(s) avant)" -f $appId, @($cur.EwsList).Count)
        return $true
    } catch {
        $m = ("" + $_.Exception.Message) -replace '\s+', ' '
        $script:EntraLastError = "ecriture Exchange impossible : $m"
        Add-ExoManual "Mail : autoriser l'application dans Exchange Online (EWS) a la main" ("L'ecriture automatique a echoue ($m). A executer dans PowerShell par un administrateur Exchange (la liste est lue d'abord ; l'ajout complete la liste sans rien retirer). AppID : $appId.") (Get-ExoManualCommands $appId -IncludeWrite)
        return $false
    }
}

# Verification (etape 6) : relit EwsAllowedAppIDs. Lignes { Name; Status (OK | WARN | KO); Detail }.
function Test-ExchangeCompliance {
    [CmdletBinding()]
    param()
    $rows = [System.Collections.Generic.List[object]]::new()
    $ex = $script:Exo
    if (-not $ex -or -not $ex.Needed -or -not $ex.Connected) { return @($rows) }
    $nm = 'Exchange : AppID dans EwsAllowedAppIDs'
    $appId = Get-ExoAppId
    $rd = Read-ExchangeEws
    if (-not $rd.Ok) { $rows.Add([pscustomobject]@{ Name = $nm; Status = 'WARN'; Detail = "relecture impossible : $($rd.Error)" }); return @($rows) }
    if ($rd.EwsEnabled -eq $false) { $rows.Add([pscustomobject]@{ Name = $nm; Status = 'WARN'; Detail = 'EwsEnabled = False (EWS desactive pour l''organisation) : decision du tenant, non modifiee' }); return @($rows) }
    if ($appId -and (@($rd.EwsList | Where-Object { $_ -ieq $appId }).Count -gt 0)) {
        $rows.Add([pscustomobject]@{ Name = $nm; Status = 'OK'; Detail = "AppID present ($(@($rd.EwsList).Count) entree(s) dans la liste)" })
    } else {
        $rows.Add([pscustomobject]@{ Name = $nm; Status = 'WARN'; Detail = 'AppID non present dans EwsAllowedAppIDs (non ecrit, ou propagation en cours : jusqu''a 10 minutes selon Cloudiway)' })
    }
    return @($rows)
}
