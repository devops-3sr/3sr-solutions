# exchange.ps1 - Exchange Online (EWS) pour la charge Mail.
# Connexion Exchange Online avec le compte -Admin365 (module ExchangeOnlineManagement), lecture SEULE de
# Get-OrganizationConfig avant le plan, puis ajout de l'AppID de l'application dans EwsAllowedAppIDs (Set-OrganizationConfig, AJOUT seul).
# Regles : jamais de remplacement ni de retrait dans EwsAllowedAppIDs ; une liste VIDE n'est creee qu'avec une confirmation explicite
# (effet de bord : elle devient restrictive pour toutes les autres applications EWS du tenant) ; EwsEnabled = False n'est jamais modifie ;
# tout echec est NON BLOQUANT pour le reste (etape manuelle avec les commandes exactes). Aucun secret manipule ici.
# v2.9 (PRIORITE 1) : EwsAllowedAppIDs n'est renvoyee QUE par Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy (documentation Microsoft,
# lue le 2026-11-25). Sans ce commutateur la propriete sort VIDE meme quand la liste existe : la v2.8 croyait donc la liste vide et pouvait
# l'ECRASER (le parametre remplace toute la liste). Desormais : la liste est lue AVEC le commutateur (la lecture simple reste utilisee pour
# EwsEnabled et les champs annexes) ; commutateur indisponible ou lecture en echec = AUCUNE ecriture ; la valeur lue est sauvegardee dans run.log
# AVANT toute ecriture, avec la commande de retour arriere ; relecture apres ecriture AVEC le commutateur ; delai de prise d'effet : jusqu'a 24 h.
# Ce fichier ne contient volontairement aucune commande qui modifie le parametre d'activation d'EWS de l'organisation ni d'une boite.

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
        EwsList         = @()       # EwsAllowedAppIDs (chaines), lue AVEC -RetrieveEwsOperationAccessPolicy
        ListOk          = $false    # v2.9 : la liste a ete lue avec le commutateur (sinon AUCUNE ecriture)
        ListError       = ''        # v2.9 : raison de l'echec de la lecture avec le commutateur
        SwitchMissing   = $false    # v2.9 : le commutateur n'existe pas dans le module installe
        Backup          = $null     # v2.9 : @{ EwsEnabled; List; At } : valeur lue juste avant l'ecriture (sauvegardee dans run.log)
        Rollback        = ''        # v2.9 : commande de retour arriere (reecrit la valeur d'avant)
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
    foreach ($l in @(Get-ExoReadCommands)) { $c.Add($l) }
    if ($IncludeWrite) { foreach ($l in @(Get-ExoWriteCommands $app)) { $c.Add($l) } }
    $c.Add('# Conseil : fermez la console PowerShell apres usage.')
    return @($c)
}

# v2.9 : commandes de LECTURE de l'etat EWS reel (aucune ecriture). La liste se lit AVEC -RetrieveEwsOperationAccessPolicy : sans ce commutateur
# EwsAllowedAppIDs sort vide meme quand la liste existe. La forme renvoyee (chaine unique ou collection) n'est pas documentee : les deux sont traitees.
function Get-ExoReadCommands {
    return @(
        'Get-OrganizationConfig | Format-List EwsEnabled, EwsApplicationAccessPolicy',
        '$cfg = $null; $avant = $null; $cfg = Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy   # commutateur OBLIGATOIRE : sans lui EwsAllowedAppIDs sort VIDE meme si la liste existe',
        '$avant = @("$($cfg.EwsAllowedAppIDs)" -split ''[,;\s]+'' | Where-Object { $_ })',
        '"EwsEnabled = [$($cfg.EwsEnabled)] ; EwsAllowedAppIDs AVANT : $($avant.Count) entree(s) : $($avant -join '','')"   # a CONSERVER : valeur a reecrire pour un retour arriere'
    )
}

# v2.9 : commandes d'ECRITURE a la main, a la suite de Get-ExoReadCommands. Le parametre REMPLACE toute la liste (GUID separes par des virgules ;
# la syntaxe d'ajout incremental est refusee) : on reecrit donc la liste lue (variable $avant) plus l'AppID. Rien n'est ecrit si la lecture a echoue.
function Get-ExoWriteCommands([string]$AppId) {
    $app = if ($AppId) { $AppId } else { '<AppID>' }
    # Garde et ecriture sur UNE SEULE ligne. Collees dans une console, les lignes sont des commandes independantes : un throw
    # sur une ligne a part n'empechait pas la ligne Set suivante de s'executer (liste remplacee par le seul AppID quand la lecture avait echoue).
    return @(
        ('if ($null -eq $cfg -or -not $cfg.PSObject.Properties[''EwsAllowedAppIDs'']) { Write-Warning ''Lecture avec -RetrieveEwsOperationAccessPolicy impossible (mettre a jour le module ExchangeOnlineManagement) : NE RIEN ECRIRE.'' } else { $ids = @($avant) + ''' + $app + '''; Set-OrganizationConfig -EwsAllowedAppIDs (($ids | Where-Object { $_ } | Select-Object -Unique) -join '','') }'),
        'Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs   # relecture ; prise d''effet : jusqu''a 24 h selon Microsoft'
    )
}

# v2.9 : commande de RETOUR ARRIERE = reecrire la valeur d'avant (lue avec le commutateur). Valeur d'avant vide : $null (documente par Microsoft, non
# teste en reel) ; a n'executer qu'avec l'accord du client quand EWS est active pour l'organisation (une liste vide peut alors bloquer tout EWS).
function Get-ExoRollbackCommand([string[]]$Prior) {
    $p = @($Prior | Where-Object { $_ })
    if ($p.Count -gt 0) { return ("Set-OrganizationConfig -EwsAllowedAppIDs '" + ($p -join ',') + "'") }
    return 'Set-OrganizationConfig -EwsAllowedAppIDs $null'
}

# v2.9 : application tierce bloquee apres un changement de liste. L'outil ne propose AUCUNE commande qui modifie l'activation d'EWS de
# l'organisation (la mesure d'urgence a retenir est en cours de verification dans les sources Microsoft au 2026-11-25) : le retour arriere de
# l'outil est de reecrire exactement la valeur lue avant l'ecriture ; pour le reste, renvoi a la fiche de reference et decision de l'administrateur.
function Get-ExoEmergencyText {
    return 'Si une application tierce du client cesse de fonctionner apres le changement de liste : le retour arriere est de reecrire exactement la valeur d''avant (commande ci-dessous), puis de completer la liste avec les applications manquantes (rapport d''usage EWS du centre d''administration). Pour toute autre mesure d''urgence, se reporter a la documentation Microsoft sur la liste EwsAllowedAppIDs : la decision et l''action reviennent a l''administrateur Exchange du client, jamais a l''outil. Ne pas modifier la liste et l''activation d''EWS dans la meme commande.'
}

# v2.9 : sauvegarde de la valeur lue AVANT toute ecriture, dans run.log (aucun secret : des AppID). Retourne $true seulement si la ligne est
# REELLEMENT presente dans le journal apres l'ecriture du fichier : sans sauvegarde verifiee, l'appelant n'ecrit rien dans Exchange.
function Save-ExoEwsBackup($Enabled, [string[]]$List, [string]$Rollback) {
    $en = if ($null -eq $Enabled) { 'Null' } else { "$Enabled" }
    $l = @($List | Where-Object { $_ })
    $line = ("EWS SAUVEGARDE avant ecriture : EwsEnabled=[{0}] EwsAllowedAppIDs=[{1}] ({2} entree(s), lue avec -RetrieveEwsOperationAccessPolicy) ; retour arriere : {3}" -f $en, ($l -join ','), $l.Count, $Rollback)
    try {
        $out = ''
        try { $out = [string]$script:Ctx.Out } catch { }
        if (-not $out -or -not (Test-Path -LiteralPath $out)) { return $false }
        $f = Join-Path $out 'run.log'
        Add-Content -LiteralPath $f -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $line) -Encoding utf8 -ErrorAction Stop
        return [bool]((Get-Content -LiteralPath $f -Raw -Encoding utf8 -ErrorAction Stop).Contains($line))
    } catch { return $false }
}

# v2.9 : texte court de l'effet de la liste selon EwsEnabled (plan, verification, rapport).
function Get-ExoEnabledNote($Enabled) {
    if ($null -eq $Enabled) { return 'EwsEnabled = Null : la liste est IGNOREE pour l''instant (tout EWS autorise) ; Microsoft fait passer les tenants Null a False depuis le 2026-10-01' }
    if ($Enabled -eq $false) { return 'EwsEnabled = False : tout EWS est bloque, la liste ne sert a rien' }
    return 'EwsEnabled = True : la liste est APPLIQUEE (seules les applications inscrites accedent a EWS)'
}

# Normalise la liste EwsAllowedAppIDs lue (MultiValuedProperty, tableau, chaine unique "a,b" ou $null) en tableau de chaines non vides.
# v2.9 : la forme renvoyee par Exchange n'est pas documentee ; une chaine unique de GUID separes par des virgules est decoupee.
function ConvertTo-ExoList($Value) {
    return @(@($Value) | ForEach-Object { if ($null -ne $_) { "$_" -split '[,;]' } } | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
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

# Lecture SEULE de la configuration EWS de l'organisation. Ne leve jamais.
# Retourne { Ok; Error; EwsEnabled; Legacy ; ListOk; ListError; SwitchMissing; EwsList }.
#   Ok      : la lecture SIMPLE a reussi (EwsEnabled et champs annexes, qui se lisent sans commutateur) ;
#   ListOk  : la liste EwsAllowedAppIDs a ete lue AVEC -RetrieveEwsOperationAccessPolicy. v2.9 : c'est la SEULE lecture valable de la liste.
#             ListOk faux (commutateur absent du module, lecture refusee, propriete absente de la reponse) : EwsList est vide ET NE DOIT PAS etre
#             interpretee comme « liste vide » : l'appelant n'ecrit rien.
function Read-ExchangeEws {
    [CmdletBinding()]
    param()
    $res = [pscustomobject]@{ Ok = $false; Error = ''; EwsEnabled = $null; Legacy = ''; ListOk = $false; ListError = ''; SwitchMissing = $false; EwsList = @() }
    try {
        $o = Get-OrganizationConfig -ErrorAction Stop
        $res.EwsEnabled = ConvertTo-ExoBool $o.EwsEnabled
        # Champs EWS annexes (anciens controles par user agent) : journal seulement, ils ne pilotent aucune decision. Vides = etat normal.
        $res.Legacy = "EwsApplicationAccessPolicy=$($o.EwsApplicationAccessPolicy) EwsAllowList=$(@(ConvertTo-ExoList $o.EwsAllowList).Count) EwsBlockList=$(@(ConvertTo-ExoList $o.EwsBlockList).Count)"
        $res.Ok = $true
    } catch {
        $res.Error = (("" + $_.Exception.Message) -replace '\s+', ' ')
        return $res
    }
    try {
        $p = Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy -ErrorAction Stop
        if ($null -eq $p) { throw 'reponse vide' }
        if (-not $p.PSObject.Properties['EwsAllowedAppIDs']) { throw 'la reponse ne contient pas la propriete EwsAllowedAppIDs' }
        $res.EwsList = @(ConvertTo-ExoList $p.EwsAllowedAppIDs)
        $res.ListOk = $true
    } catch {
        $m = (("" + $_.Exception.Message) -replace '\s+', ' ')
        $res.ListError = $m
        $res.SwitchMissing = [bool]($m -match '(?i)parameter cannot be found|param.tre.*introuvable|RetrieveEwsOperationAccessPolicy')
        $res.EwsList = @()
    }
    return $res
}

# v2.9 : texte unique « liste illisible » (console, plan, rapport).
function Get-ExoListUnreadableText {
    $ex = $script:Exo
    $why = if ($ex.SwitchMissing) { 'le commutateur -RetrieveEwsOperationAccessPolicy est indisponible dans le module ExchangeOnlineManagement installe' } else { 'la lecture avec -RetrieveEwsOperationAccessPolicy a echoue' }
    return "$why : la liste EwsAllowedAppIDs n'a PAS pu etre lue. Sans ce commutateur la propriete sort vide meme quand la liste existe, et l'ecriture REMPLACE toute la liste : l'outil n'ecrit donc RIEN dans Exchange."
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
    $ex.ListOk = [bool]$rd.ListOk
    $ex.ListError = [string]$rd.ListError
    $ex.SwitchMissing = [bool]$rd.SwitchMissing
    $ex.Legacy = [string]$rd.Legacy
    $en = if ($null -eq $rd.EwsEnabled) { 'non defini (Null)' } else { "$($rd.EwsEnabled)" }
    if (-not $rd.ListOk) {
        # v2.9 : liste illisible = AUCUNE ecriture (jamais « liste vide »). Etape manuelle, code de sortie 2.
        $ex.PlanFailure = $true
        $out.Add([pscustomobject]@{ Level = 'WARN'; Text = 'Liste EwsAllowedAppIDs illisible : l''outil n''ecrira RIEN dans Exchange (etape a faire a la main).'; Detail = ("EwsEnabled = {0} ; {1} Detail : {2}" -f $en, (Get-ExoListUnreadableText), [string]$rd.ListError) })
        return @($out)
    }
    $out.Add([pscustomobject]@{ Level = 'INFO'; Text = 'Configuration EWS de l''organisation lue.'; Detail = ("EwsEnabled = {0} ; EwsAllowedAppIDs : {1} entree(s), lue avec -RetrieveEwsOperationAccessPolicy" -f $en, @($rd.EwsList).Count) })
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
        Add-ExoManual 'Exchange Online : une session d''un autre tenant est ouverte dans cette console (une console par tenant)' ((Get-ExoForeignSessionText) + " Session trouvee : $($ex.ForeignSession). Si vous preferez faire l'etape a la main, dans une console NOUVELLE : lire d'abord EwsAllowedAppIDs AVEC -RetrieveEwsOperationAccessPolicy (si elle est deja renseignee, la reecrire complete de l'AppID ; si elle est VIDE, la definir la rend restrictive pour toutes les autres applications EWS du tenant). AppID a autoriser : $appTxt.") (Get-ExoManualCommands $appId -IncludeInstall:(-not $ex.ModuleOk) -IncludeWrite)
        return
    }
    if ($ex.PlanFailure -and $ex.Read -and -not $ex.ListOk) {
        # v2.9 : la liste n'a pas pu etre lue avec le commutateur : AUCUNE ecriture, meme avec -AllowEwsListCreation (une liste illisible n'est pas une liste vide).
        $lu = Get-ExoListUnreadableText
        [void](Add-PlanItem 'Exchange' $name 'SKIP' ("liste EwsAllowedAppIDs illisible (-RetrieveEwsOperationAccessPolicy) : AUCUNE ecriture, etape a faire a la main (voir A faire)"))
        Add-ExoManual 'Mail : liste EwsAllowedAppIDs illisible, application NON inscrite (aucune ecriture)' ("$lu Detail : $($ex.ListError). Mettre a jour le module (Update-Module ExchangeOnlineManagement) dans une console NOUVELLE puis relancer la meme commande ; ou faire l'etape a la main avec les commandes ci-dessous, qui s'arretent d'elles-memes si la lecture echoue. Ne JAMAIS ecrire la liste sans l'avoir lue avec le commutateur. $(Get-ExoEnabledNote $ex.EwsEnabled). AppID a autoriser : $appTxt. Un changement de liste prend effet en 24 h au plus selon Microsoft.") (Get-ExoManualCommands $appId -IncludeWrite)
        return
    }
    if ($ex.PlanFailure) {
        $why = if (-not $ex.ModuleOk) { "module $($script:ExoModule) absent" } elseif ($ex.ConnectError) { 'connexion Exchange Online impossible' } else { 'lecture de la configuration EWS impossible' }
        $detail = if ($ex.ConnectError) { " ($($ex.ConnectError))" } elseif ($ex.ReadError) { " ($($ex.ReadError))" } else { '' }
        [void](Add-PlanItem 'Exchange' $name 'SKIP' ("$why$detail : etape a faire a la main (voir A faire)"))
        Add-ExoManual "Mail : autoriser l'application dans Exchange Online (EWS) a la main" ("L'etape automatique n'a pas pu etre realisee ($why). A executer dans PowerShell par un administrateur Exchange. D'abord LIRE la liste AVEC -RetrieveEwsOperationAccessPolicy (sans ce commutateur elle sort vide meme si elle existe) : la valeur ecrite REMPLACE toute la liste, les commandes ci-dessous reecrivent donc la liste lue plus l'AppID, sans rien retirer ; si la liste est VIDE, la definir la rend restrictive pour toutes les autres applications EWS du tenant. Prise d'effet : jusqu'a 24 h selon Microsoft. AppID a autoriser : $appTxt.") (Get-ExoManualCommands $appId -IncludeInstall:(-not $ex.ModuleOk) -IncludeWrite)
        return
    }

    # EWS desactive pour l'organisation : decision du tenant, jamais modifiee
    if ($ex.EwsEnabled -eq $false) {
        [void](Add-PlanItem 'Exchange' $name 'SKIP' 'EWS desactive pour l''organisation (EwsEnabled = False) : decision a l''echelle du tenant, non modifiee par l''outil (voir A verifier)')
        Add-ExoVerify 'Mail : EWS est desactive pour l''organisation (EwsEnabled = False)' ("Le courrier migre par Cloudiway passe par EWS : avec EwsEnabled = False tout EWS est bloque et la liste EwsAllowedAppIDs ne sert a rien ($(@($ex.EwsList).Count) entree(s) lue(s)). L'outil n'ecrit RIEN : reactiver EWS est une decision a l'echelle du tenant (a prendre par l'administrateur Exchange, en connaissance de la fin d'EWS annoncee par Microsoft pour le 2027-04-01). Ordre conseille par Microsoft : inscrire d'abord l'AppID dans la liste, attendre 24 h, puis seulement activer EWS (environ 1 h, jusqu'a 4 h) ; ne pas changer les deux en meme temps. Apres la decision, relancer la meme commande pour inscrire l'AppID $appTxt.") (Get-ExoReadCommands)
        return
    }
    if ($null -eq $ex.EwsEnabled) {
        Add-ExoVerify 'Mail : EwsEnabled n''est pas defini pour l''organisation' ('EwsEnabled vaut Null : la liste EwsAllowedAppIDs est IGNOREE pour l''instant (tout EWS est autorise), mais Microsoft fait passer les tenants Null a False (blocage d''EWS, deploiement commence le 2026-10-01) : etat instable. Ordre conseille par Microsoft : definir la liste pendant que EwsEnabled vaut Null (ce que fait l''outil), verifier, attendre 24 h, puis passer EwsEnabled a True (environ 1 h, jusqu''a 4 h), sans changer les deux en meme temps. ATTENTION : une fois a True, SEULES les applications de la liste accedent a EWS ; faire l''inventaire des autres applications EWS du tenant avant. Decision et action de l''administrateur Exchange, jamais faites par l''outil.') (Get-ExoReadCommands)
    }

    $list = @($ex.EwsList)
    if ($appId -and (@($list | Where-Object { $_ -ieq $appId }).Count -gt 0)) {
        [void](Add-PlanItem 'Exchange' $name 'OK' ("AppID deja present dans EwsAllowedAppIDs ({0} entree(s) ; {1})" -f $list.Count, (Get-ExoEnabledNote $ex.EwsEnabled)))
        return
    }
    if ($list.Count -gt 0) {
        $it = Add-PlanItem 'Exchange' $name 'UPDATE' ("ajout seul de l'AppID dans EwsAllowedAppIDs ({0} entree(s) existante(s) conservee(s), aucun retrait ; valeur d'avant sauvegardee dans run.log avec la commande de retour arriere ; prise d'effet : jusqu'a 24 h ; {1})" -f $list.Count, (Get-ExoEnabledNote $ex.EwsEnabled)) { Invoke-ExchangeEwsApply }
        return
    }
    # Liste VIDE (lue avec le commutateur) : la definir la rend RESTRICTIVE pour toutes les autres applications EWS du tenant
    $effect = 'EwsAllowedAppIDs est VIDE : la definir rend la liste RESTRICTIVE, donc bloque toutes les autres applications EWS du tenant qui n''y figurent pas'
    $effect += $(if ($null -eq $ex.EwsEnabled) { ' (EwsEnabled = Null : sans effet tant que le tenant n''est pas passe a True, restrictive ensuite)' } else { ' (EwsEnabled = True : au plus tard 24 h apres ; selon Microsoft une liste vide bloque deja tout EWS depuis octobre 2026)' })
    if ($allow) {
        $ex.CreateApproved = $true
        [void](Add-PlanItem 'Exchange' $name 'UPDATE' ("$effect ; creation autorisee par -AllowEwsListCreation") { Invoke-ExchangeEwsApply })
    } elseif ($yes) {
        [void](Add-PlanItem 'Exchange' $name 'SKIP' ("$effect ; ignoree avec -Yes (ajouter -AllowEwsListCreation pour l'autoriser sans question)"))
        Add-ExoVerify 'Mail : EwsAllowedAppIDs est vide, AppID non inscrit' ("L'outil n'a RIEN ecrit : definir une liste vide la rend restrictive pour toutes les autres applications EWS du tenant (Outlook pour Mac classique, outils de sauvegarde, etc.). $(Get-ExoEnabledNote $ex.EwsEnabled). Decision de l'administrateur Exchange : soit inscrire aussi les autres applications utiles, soit relancer l'outil avec -AllowEwsListCreation pour l'autoriser. Prise d'effet : jusqu'a 24 h. AppID : $appTxt.") (@(Get-ExoReadCommands) + @(Get-ExoWriteCommands $appTxt))
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
    $sent = $false
    try {
        # Relecture juste avant l'ecriture : la decision repose sur l'etat REEL (jamais sur le plan seul), lu AVEC le commutateur (v2.9).
        $guidRe = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
        if ($appId -notmatch $guidRe) { throw "l'AppID '$appId' n'est pas un GUID : aucune ecriture" }
        $cur = Read-ExchangeEws
        if (-not $cur.Ok) { throw "relecture impossible avant l'ecriture : $($cur.Error)" }
        if (-not $cur.ListOk) { throw "liste EwsAllowedAppIDs illisible avant l'ecriture (lecture avec -RetrieveEwsOperationAccessPolicy : $($cur.ListError)) : AUCUNE ecriture, une liste illisible n'est pas une liste vide" }
        if ($cur.EwsEnabled -eq $false) { throw 'EwsEnabled vaut False : aucune ecriture (decision a l''echelle du tenant)' }
        if (@($cur.EwsList | Where-Object { $_ -ieq $appId }).Count -gt 0) { Write-RunLog 'EWS : AppID deja present a la relecture, aucune ecriture'; return $true }
        if (@($cur.EwsList).Count -eq 0 -and -not $ex.CreateApproved) { throw 'liste vide : la creation n''est pas autorisee (confirmation absente)' }
        # v2.9 : la liste lue au plan et la relecture doivent concorder. Une entree vue au plan et absente maintenant = lecture incoherente ou
        # modification concurrente : rien n'est ecrit (ecrire remplacerait la liste par une version qui a peut-etre perdu des entrees).
        $gonePlan = @(@($ex.EwsList) | Where-Object { $p0 = $_; @($cur.EwsList | Where-Object { $_ -ieq $p0 }).Count -eq 0 })
        if ($gonePlan.Count -gt 0) { throw ("{0} entree(s) lue(s) au moment du plan sont absentes de la relecture ({1}) : lecture incoherente ou liste modifiee entre-temps, AUCUNE ecriture ; relancer la meme commande" -f $gonePlan.Count, ($gonePlan -join ', ')) }
        # Syntaxe REELLE (constate sur un vrai tenant le 2026-10-31) : le parametre attend des GUID separes par des virgules ; la syntaxe d'ajout
        # incremental est refusee (« Please provide comma separated values of valid GUIDs »). La valeur REMPLACE la liste : on reecrit donc la liste
        # existante COMPLETE plus l'AppID (ajout seul, aucune entree retiree). Une entree existante qui n'est pas un GUID arrete l'ecriture.
        $notGuid = @($cur.EwsList | Where-Object { $_ -notmatch $guidRe })
        if ($notGuid.Count -gt 0) { throw ('la liste existante contient des valeurs qui ne sont pas des GUID (' + ($notGuid -join ', ') + ') : aucune ecriture, pour ne rien alterer') }
        $prior = @($cur.EwsList)
        $merged = [System.Collections.Generic.List[string]]::new()
        foreach ($e in @($prior) + @($appId)) { if (-not ($merged | Where-Object { $_ -ieq $e })) { $merged.Add([string]$e) } }
        $lostMerge = @($prior | Where-Object { $p0 = $_; @($merged | Where-Object { $_ -ieq $p0 }).Count -eq 0 })
        if ($lostMerge.Count -gt 0 -or $merged.Count -lt ($prior | Select-Object -Unique).Count) { throw 'controle interne : la liste a ecrire ne contient pas toutes les entrees existantes : aucune ecriture' }
        # Sauvegarde de la valeur lue AVANT l'ecriture + commande de retour arriere (run.log, puis rapport). Sans sauvegarde verifiee : rien n'est ecrit.
        $rb = Get-ExoRollbackCommand $prior
        if (-not (Save-ExoEwsBackup $cur.EwsEnabled $prior $rb)) { throw 'sauvegarde de la valeur actuelle impossible (run.log non ecrit) : AUCUNE ecriture dans Exchange' }
        $ex.Backup = @{ EwsEnabled = $cur.EwsEnabled; List = $prior; At = (Get-Date) }
        $ex.Rollback = $rb
        Set-OrganizationConfig -EwsAllowedAppIDs ($merged -join ',') -ErrorAction Stop | Out-Null
        $sent = $true
        Write-RunLog ("EWS : AppID {0} ajoute a EwsAllowedAppIDs ({1} entree(s) avant, {2} ecrite(s))" -f $appId, $prior.Count, $merged.Count)
        $rbWarn = if ($prior.Count -eq 0) { ' ATTENTION : la valeur d''avant etait VIDE ; la commande de retour arriere remet la liste a vide ($null). Avec EwsEnabled = True, une liste vide peut bloquer TOUT EWS sous 24 h (sources Microsoft contradictoires) : ne pas l''executer sans accord ecrit du client ; avec EwsEnabled = Null elle est sans effet pratique.' } else { ' La commande de retour arriere reecrit exactement la valeur d''avant (' + $prior.Count + ' entree(s)).' }
        Add-ExoVerify 'Mail : EwsAllowedAppIDs modifiee (delai de prise d''effet et retour arriere)' ("L'AppID $appId a ete AJOUTE a la liste ; les $($prior.Count) entree(s) existante(s) sont conservees. $(Get-ExoEnabledNote $cur.EwsEnabled). Prise d'effet : jusqu'a 24 h selon Microsoft (et non quelques minutes) : un succes ou un echec immediat d'un job Cloudiway ne prouve rien. La valeur d'avant est sauvegardee dans run.log (ligne « EWS SAUVEGARDE »).$rbWarn $(Get-ExoEmergencyText)") @(('# 1. Retour arriere de la liste (reecrit exactement la valeur d''avant) :'), $rb, '# 2. Relecture (commutateur obligatoire) :', 'Get-OrganizationConfig -RetrieveEwsOperationAccessPolicy | Format-List EwsEnabled, EwsAllowedAppIDs')
        # Relecture APRES ecriture, AVEC le commutateur : toutes les entrees d'avant ET l'AppID doivent etre presents.
        $after = $null
        foreach ($w in 0, 5, 10) {
            if ($w -gt 0) { Start-Sleep -Seconds $w }
            $after = Read-ExchangeEws
            if ($after.Ok -and $after.ListOk -and (@($after.EwsList | Where-Object { $_ -ieq $appId }).Count -gt 0)) { break }
        }
        if (-not ($after.Ok -and $after.ListOk)) { throw ("ecriture envoyee sans erreur mais relecture impossible avec -RetrieveEwsOperationAccessPolicy ($($after.Error)$($after.ListError)) : resultat NON verifie ; retour arriere si besoin : $rb") }
        $lostAfter = @($prior | Where-Object { $p0 = $_; @($after.EwsList | Where-Object { $_ -ieq $p0 }).Count -eq 0 })
        if ($lostAfter.Count -gt 0) { throw ("ATTENTION : {0} entree(s) existante(s) sont ABSENTES de la liste apres l'ecriture ({1}). Retablir la valeur d'avant : {2}" -f $lostAfter.Count, ($lostAfter -join ', '), $rb) }
        if (@($after.EwsList | Where-Object { $_ -ieq $appId }).Count -eq 0) { throw "ecriture acceptee sans erreur mais l'AppID n'apparait pas a la relecture (avec le commutateur) : resultat NON confirme ; relire plus tard avant toute nouvelle ecriture" }
        Write-RunLog ("EWS : relecture apres ecriture conforme ({0} entree(s), toutes les entrees d'avant presentes)" -f @($after.EwsList).Count)
        return $true
    } catch {
        $m = ("" + $_.Exception.Message) -replace '\s+', ' '
        $script:EntraLastError = "ecriture Exchange impossible : $m"
        if ($sent) {
            $script:EntraLastError = "ecriture Exchange NON confirmee : $m"
            Add-ExoManual "Mail : verifier la liste EwsAllowedAppIDs a la main (ecriture non confirmee)" ("L'ecriture a ete envoyee mais la relecture ne la confirme pas ($m). NE PAS relancer d'ecriture sans avoir relu la liste avec -RetrieveEwsOperationAccessPolicy. Valeur d'avant : voir run.log (ligne « EWS SAUVEGARDE ») et la commande de retour arriere dans « A verifier ». AppID : $appId.") (Get-ExoReadCommands)
        } else {
            Add-ExoManual "Mail : autoriser l'application dans Exchange Online (EWS) a la main" ("L'ecriture automatique a echoue ($m). A executer dans PowerShell par un administrateur Exchange (la liste est lue d'abord AVEC -RetrieveEwsOperationAccessPolicy ; l'ajout reecrit la liste lue plus l'AppID, sans rien retirer ; prise d'effet : jusqu'a 24 h). AppID : $appId.") (Get-ExoManualCommands $appId -IncludeWrite)
        }
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
    # v2.9 : la presence de l'AppID ne se verifie QUE sur une liste lue avec le commutateur (sans lui elle sort vide).
    if (-not $rd.ListOk) { $rows.Add([pscustomobject]@{ Name = $nm; Status = 'WARN'; Detail = "liste illisible avec -RetrieveEwsOperationAccessPolicy ($($rd.ListError)) : presence de l'AppID NON verifiee" }); return @($rows) }
    if ($appId -and (@($rd.EwsList | Where-Object { $_ -ieq $appId }).Count -gt 0)) {
        $nullTxt = if ($null -eq $rd.EwsEnabled) { ' ; EwsEnabled = Null : liste ignoree pour l''instant' } else { '' }
        $rows.Add([pscustomobject]@{ Name = $nm; Status = 'OK'; Detail = "AppID present ($(@($rd.EwsList).Count) entree(s) dans la liste, relue avec -RetrieveEwsOperationAccessPolicy) ; prise d'effet : jusqu'a 24 h selon Microsoft$nullTxt" })
    } else {
        $rows.Add([pscustomobject]@{ Name = $nm; Status = 'WARN'; Detail = 'AppID non present dans EwsAllowedAppIDs (liste relue avec -RetrieveEwsOperationAccessPolicy : non ecrit). Rappel : un changement de liste prend effet en 24 h au plus selon Microsoft' })
    }
    return @($rows)
}
