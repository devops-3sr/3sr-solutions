# cloudiway.ps1 - API Cloudiway : authentification du DSI, projets, connecteur, marqueur, decouverte, conformite. Dot-sourcee apres common.ps1.
# Aucun DELETE, aucun secret journalise ou affiche.
# Les identifiants (certificat, secret, mot de passe du compte de service) vivent UNIQUEMENT en memoire dans $script:Ctx.Credentials.
# Toutes les fonctions publiques sont tolerantes aux erreurs : elles ne levent jamais, elles retournent des lignes ou $null/$false.

$script:Ciw = [pscustomobject]@{ Base = 'https://api-production.cloudiway.com/ap1'; Headers = @{}; ProjectId = 0; Authenticated = $false }
$script:CiwLastError = ''
$script:CiwSecrets = @()   # valeurs secretes connues (mot de passe, PAT, jeton) : uniquement pour filtrer les messages d'erreur
$script:CiwMarker = 'CloudiwayConnector'   # ancienne marque (V1) de externalKey : toujours reconnue comme "cree par l'outil"
$script:CiwMarkerPrefix = 'CIW1|'          # marqueur V2 : CIW1|<empreinte>|<AAAAMMJJ> (externalKey, ECRIT A LA CREATION SEULEMENT : etiquette de propriete)
# v2.4 : le MARQUEUR DE SUIVI du renouvellement est le nom de fichier du certificat envoye : CIW1_<32 premiers hex de l'empreinte>_<AAAAMMJJ>.pfx
# (ou CIW1_S<id du secret, 32>_<AAAAMMJJ>.pfx). Le portail remplace le certificat SUR PLACE a chaque PUT (meme id, nouveau fileName) mais ne
# modifie jamais externalKey apres la creation : le fileName est le seul indicateur observable qu'un nouveau certificat a ete pris en compte.
$script:CiwFileMarkerRx = '^CIW1_(S[0-9A-Fa-f]{1,32}|[0-9A-Fa-f]{1,32})_(\d{8})\.pfx$'
$script:CiwFileNameRx = '^[A-Za-z0-9_.-]+$'   # seuls caracteres admis dans le nom de fichier envoye
$script:CiwNeedCertMsg = 'le portail exige le certificat lors d''une mise a jour : relancer sans -KeepCredentials'
$script:CiwTempFiles = [System.Collections.Generic.List[string]]::new()
$script:CiwNotices = [System.Collections.Generic.List[string]]::new()
$script:CiwAuth = $null            # moyen de se reconnecter UNE fois si le jeton expire : @{ Kind = 'Login'|'Pat'; Login; Pat [securestring] } (memoire seulement)
$script:CiwReauthCount = 0         # une seule re-authentification par execution
$script:CiwTwoFactor = $false      # double authentification Cloudiway probable (connexion acceptee sans jeton, ou signal explicite)
$script:CiwPutCheck = $null        # instantane pris avant un PUT (compte, RestClientId, certificat) pour la verification apres coup
$script:CiwSessionExpiredMsg = 'session Cloudiway expiree ou refusee (HTTP 401) : relancer l''outil (le mot de passe Cloudiway est redemande). Aucune modification n''a ete appliquee par la requete refusee.'

# --- Aides internes ---

function ConvertFrom-SecureStringPlain([securestring]$Secure) {
    # Conversion au dernier moment ; le resultat ne doit jamais etre journalise.
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Get-CiwProp($Object, [string]$Name) {
    # Lecture tolerante d'une propriete (hashtable ou objet), insensible a la casse ; $null si absente.
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) { if ("$k" -ieq $Name) { return $Object[$k] } }
        return $null
    }
    foreach ($p in $Object.PSObject.Properties) { if ($p.Name -ieq $Name) { return $p.Value } }
    return $null
}

function Get-CiwBytes($Object, [string]$Name) {
    # Lecture d'un byte[] sans enumeration par le pipeline ($null si absent ou d'un autre type).
    $v = $null
    if ($Object -is [System.Collections.IDictionary]) { foreach ($k in $Object.Keys) { if ("$k" -ieq $Name) { $v = $Object[$k] } } }
    elseif ($null -ne $Object) { foreach ($p in $Object.PSObject.Properties) { if ($p.Name -ieq $Name) { $v = $p.Value } } }
    if ($v -is [byte[]]) { return ,$v }
    return $null
}

function Set-CiwCtx([string]$Name, $Value) {
    # Ecrit une valeur dans $script:Ctx (table de hachage ou objet).
    if ($null -eq $script:Ctx) { return }
    if ($script:Ctx -is [System.Collections.IDictionary]) { $script:Ctx[$Name] = $Value }
    else { $script:Ctx | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function ConvertTo-CiwPlain($Value) {
    if ($Value -is [securestring]) { return (ConvertFrom-SecureStringPlain $Value) }
    return $Value
}

# m3 : retire des textes (erreurs, journal) toute valeur secrete connue : mot de passe, PAT, jeton, identifiants en memoire.
function Protect-CiwText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $vals = [System.Collections.Generic.List[string]]::new()
    foreach ($v in @($script:CiwSecrets)) { if ($v) { $vals.Add([string]$v) } }
    try {
        foreach ($bag in @((Get-CiwProp $script:Ctx 'Secrets'), (Get-CiwProp $script:Ctx 'Credentials'))) {
            if ($bag -is [System.Collections.IDictionary]) {
                foreach ($k in $bag.Keys) {
                    $v = $bag[$k]
                    if ($v -is [byte[]]) {
                        if ($v.Length -gt 0) { $vals.Add([Convert]::ToBase64String($v)) }
                        continue
                    }
                    if ($k -match 'Thumbprint|NotAfter') { continue }
                    if ($v -is [securestring]) { $v = ConvertFrom-SecureStringPlain $v }
                    if ($v -is [string] -and $v) { $vals.Add([string]$v) }
                }
            }
        }
    } catch { }
    foreach ($v in ($vals | Sort-Object Length -Descending)) {
        if ($v.Length -ge 4) { $Text = $Text.Replace($v, '***MASQUE***') }
    }
    return $Text
}

# Message d'erreur lisible, filtre des secrets connus.
function Get-CiwErrMsg($e) { Protect-CiwText (Get-ErrMsg $e) }

function Set-CiwError([string]$Message) {
    # M5 : message d'echec lisible, lu par le script principal ; jamais de secret.
    $script:CiwLastError = Protect-CiwText $Message
    Write-RunLog ("CIW {0}" -f $script:CiwLastError)
}

function Add-CiwNotice([string]$Message) {
    # Information non bloquante a afficher dans le rapport (ex. mot de passe du compte de service a saisir dans le portail).
    $m = Protect-CiwText $Message
    if (-not $script:CiwNotices.Contains($m)) { $script:CiwNotices.Add($m) }
    Write-RunLog ("CIW info : {0}" -f $m)
}
function Get-CloudiwayNotices { return @($script:CiwNotices) }

# Appel REST Cloudiway : ErrorAction Stop, TimeoutSec 60, reessai sur 429 (toute methode) et sur 5xx (GET seulement). Leve en cas d'echec final (les appelants captent).
$script:CiwProxyOk = $false
try { $script:CiwProxyOk = [bool](Get-Command Invoke-RestMethod -ErrorAction Stop).Parameters.ContainsKey('ProxyUseDefaultCredentials') } catch { }
function Invoke-CiwRest([ValidateSet('GET', 'POST', 'PUT')][string]$Method, [string]$Path, $Body = $null, [hashtable]$Headers = $null) {
    $uri = "$($script:Ciw.Base)$Path"
    $isAuthPath = ($Path -like '/Authentication/*')
    $attempt = 0
    while ($true) {
        $hdr = if ($null -ne $Headers) { $Headers } else { $script:Ciw.Headers }   # relu a chaque essai : le jeton peut avoir ete renouvele
        $params = @{ Method = $Method; Uri = $uri; Headers = $hdr; TimeoutSec = 60; ErrorAction = 'Stop' }
        if ($null -ne $Body) {
            $params['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
            $params['ContentType'] = 'application/json'
        }
        # m6 : proxys d'entreprise a authentification integree : gere globalement par Enable-ProxyDefaultCredentials (preflight.ps1).
        # (-ProxyUseDefaultCredentials exige -Proxy : ne pas le passer ici.)
        try {
            Write-RunLog ("CIW {0} {1} (essai {2})" -f $Method, $Path, ($attempt + 1))
            return (Invoke-RestMethod @params)
        } catch {
            $code = Get-ErrCode $_
            # M1 : 401 hors authentification = jeton expire ou refuse. UNE seule re-authentification par execution, puis la requete (refusee,
            # donc non traitee) est rejouee. Sinon message actionnable au lieu de "HTTP 401 : Unauthorized".
            if ($code -eq 401 -and -not $isAuthPath) {
                if ($script:Ciw.Authenticated) {
                    if ($null -eq $Headers -and $script:CiwReauthCount -lt 1 -and (Invoke-CiwReauth)) { continue }
                    throw [System.InvalidOperationException]::new($script:CiwSessionExpiredMsg)
                }
                throw [System.InvalidOperationException]::new('acces refuse par Cloudiway (HTTP 401) : identifiant, mot de passe ou jeton PAT incorrect, expire ou sans droit sur ce projet.')
            }
            # 429 : requete non traitee, rejeu sur toute methode. 5xx : rejeu UNIQUEMENT pour GET (un POST/PUT peut avoir abouti).
            $retryable = ($code -eq 429) -or ($code -in 502, 503, 504 -and $Method -eq 'GET')
            if ($retryable -and $attempt -lt 3) {
                $attempt++
                $wait = 2 * $attempt
                try { $ra = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds; if ($ra) { $wait = [Math]::Min(60, [int]$ra) } } catch { }
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}

# Deballe l'enveloppe { isSuccess, responseData } si presente.
function Get-CiwData($Response) {
    if ($null -eq $Response) { return $null }
    if ($null -ne (Get-CiwProp $Response 'isSuccess') -or $null -ne (Get-CiwProp $Response 'responseData')) { return (Get-CiwProp $Response 'responseData') }
    return $Response
}

function New-CiwLine([string]$Name, [string]$Status, [string]$Detail, [string]$Impact = '') {
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Impact = $Impact }
}

function Get-CiwTokenFromResponse($Resp) {
    # Forme de la reponse de login inconnue : on essaie les emplacements usuels.
    if ($null -eq $Resp) { return $null }
    if ($Resp -is [string]) { if ($Resp.Trim().Length -gt 20 -and $Resp -notmatch '\s') { return $Resp.Trim() } else { return $null } }
    foreach ($n in 'token', 'accessToken', 'access_token', 'jwt') {
        $v = Get-CiwProp $Resp $n
        if ($v -is [string] -and $v) { return $v }
    }
    $d = Get-CiwProp $Resp 'responseData'
    if ($null -ne $d) { return (Get-CiwTokenFromResponse $d) }
    return $null
}

# Repli "cookies" (comportement de l'ancien script) : le champ token de la reponse vaut litteralement "token" ;
# le vrai jeton est alors dans l'en-tete Set-Cookie de la reponse de login.
function Get-CiwTokenFromSetCookie($Cookies) {
    $cands = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($Cookies)) {
        if (-not $c) { continue }
        $first = ("$c" -split ';')[0]
        $i = $first.IndexOf('=')
        if ($i -lt 1) { continue }
        $name = $first.Substring(0, $i).Trim()
        $val = $first.Substring($i + 1).Trim().Trim('"')
        try { $val = [uri]::UnescapeDataString($val) } catch { }
        if ($val) { $cands.Add([pscustomobject]@{ Name = $name; Value = $val }) }
    }
    if ($cands.Count -eq 0) { return $null }
    $jwt = @($cands | Where-Object { $_.Value -match '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$' })
    if ($jwt.Count -gt 0) { return $jwt[0].Value }
    $named = @($cands | Where-Object { $_.Name -match '(?i)token|auth|jwt|access|session' })
    if ($named.Count -gt 0) { return $named[0].Value }
    return (@($cands | Sort-Object { $_.Value.Length } -Descending))[0].Value
}

function Get-CiwTokenViaCookies([string]$Body) {
    $wr = Invoke-WebRequest -Uri "$($script:Ciw.Base)/Authentication/Login" -Method POST -Body $Body -ContentType 'application/json' -Headers @{ accept = '*/*' } -TimeoutSec 60 -ErrorAction Stop
    $hdrs = Get-CiwProp $wr 'Headers'
    $sc = Get-CiwProp $hdrs 'Set-Cookie'
    $t = Get-CiwTokenFromSetCookie $sc
    if ($t) { return $t }
    # Dernier recours : un jeton different de "token" dans le corps de la reponse.
    try {
        $j = "$(Get-CiwProp $wr 'Content')" | ConvertFrom-Json -ErrorAction Stop
        $t = Get-CiwTokenFromResponse $j
        if ($t -and $t -cne 'token') { return $t }
    } catch { }
    return $null
}

# --- Projets ---

# Liste des projets visibles : { id; name }. Echec : liste vide et $script:CiwLastError renseignee.
function Get-CloudiwayProjects {
    [CmdletBinding()]
    param()
    $script:CiwLastError = ''
    try {
        $r = Invoke-CiwRest -Method GET -Path '/Projects'
        if (Test-CiwFailure $r) { Set-CiwError ("lecture des projets impossible (isSuccess = false) {0}" -f (Get-CiwFailText $r)); return @() }
        $rows = foreach ($p in @(Get-CiwData $r)) {
            if ($null -eq $p) { continue }
            $id = Get-CiwProp $p 'id'
            if ($null -eq $id) { continue }
            $iv = 0
            [pscustomobject]@{ id = $(if ([int]::TryParse("$id", [ref]$iv)) { $iv } else { $id }); name = "$(Get-CiwProp $p 'name')" }
        }
        return @($rows)
    } catch {
        Set-CiwError ("lecture des projets impossible : {0}" -f (Get-CiwErrMsg $_))
        return @()
    }
}

# Selection du projet. Retourne { Ok; ProjectId; Name; Message } ; met a jour $script:Ciw (en-tete projectId) et $script:Ctx.ProjectId.
function Select-CloudiwayProject {
    [CmdletBinding()]
    param([Nullable[int]]$ProjectId = $null, [switch]$Interactive, [object[]]$Projects = $null)
    $fail = { param($m) [pscustomobject]@{ Ok = $false; ProjectId = 0; Name = ''; Message = $m } }
    try {
        if ($null -eq $Projects) {
            $Projects = @(Get-CloudiwayProjects)
            if ($script:CiwLastError) { return (& $fail $script:CiwLastError) }
        }
        $list = @($Projects | Where-Object { $null -ne $_ })
        if ($list.Count -eq 0) { return (& $fail 'aucun projet visible : verifier l''invitation Contributor.') }
        $chosen = $null
        if ($null -ne $ProjectId -and $ProjectId -gt 0) {
            $chosen = @($list | Where-Object { "$(Get-CiwProp $_ 'id')" -eq "$ProjectId" }) | Select-Object -First 1
            if (-not $chosen) {
                return (& $fail ("le projet $ProjectId ne figure pas parmi les $($list.Count) projet(s) accessibles ($(@($list | ForEach-Object { Get-CiwProp $_ 'id' }) -join ', ')) : verifier l'identifiant et l'invitation Contributor."))
            }
        } elseif ($list.Count -eq 1) {
            $chosen = $list[0]
        } elseif (-not $Interactive) {
            $names = (@($list | ForEach-Object { "$(Get-CiwProp $_ 'id') ($(Get-CiwProp $_ 'name'))" }) -join ', ')
            return (& $fail ("$($list.Count) projets visibles ($names) : preciser -ProjectId (console non interactive)."))
        } else {
            Write-Host ''
            Write-Host 'Projets Cloudiway visibles :'
            for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ('  {0}. [{1}] {2}' -f ($i + 1), (Get-CiwProp $list[$i] 'id'), (Get-CiwProp $list[$i] 'name')) }
            Write-Host "Plusieurs projets sont visibles : indiquer le numero de la LISTE (1 a $($list.Count), exemple : 1), pas le numero du projet."
            # Re-question jusqu'a une saisie valide (pas d'arret brutal) ; seule une saisie impossible (console fermee) interrompt.
            while (-not $chosen) {
                $ans = ''
                try { $ans = Read-Host "Numero du projet dans la liste (1 a $($list.Count))" } catch { return (& $fail 'aucun projet choisi (saisie impossible).') }
                $n = 0
                if ([int]::TryParse("$ans".Trim(), [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { $chosen = $list[$n - 1] }
                else { Write-Host ("  Choix invalide : saisir un nombre entre 1 et {0} (exemple : 1)." -f $list.Count) }
            }
        }
        $pid2 = [int](Get-CiwProp $chosen 'id')
        $script:Ciw.ProjectId = $pid2
        if ($script:Ciw.Headers -isnot [hashtable]) { $script:Ciw.Headers = @{} }
        $script:Ciw.Headers['projectId'] = [string]$pid2
        Set-CiwCtx 'ProjectId' $pid2
        return [pscustomobject]@{ Ok = $true; ProjectId = $pid2; Name = "$(Get-CiwProp $chosen 'name')"; Message = '' }
    } catch {
        return (& $fail (Get-CiwErrMsg $_))
    }
}

# --- Connexion ---

# Signal de double authentification dans une reponse de login (champ explicite ou texte d'erreur).
function Test-CiwTwoFactorSignal($Response) {
    try {
        $d = Get-CiwData $Response
        foreach ($o in @($Response, $d)) {
            if ($null -eq $o -or $o -is [string]) { continue }
            $names = if ($o -is [System.Collections.IDictionary]) { @($o.Keys) } else { @($o.PSObject.Properties | ForEach-Object { $_.Name }) }
            foreach ($n in $names) {
                if ("$n" -match '(?i)two.?factor|2fa|mfa|otp|totp') {
                    $v = Get-CiwProp $o "$n"
                    if ($v -is [bool] -and $v) { return $true }
                    if ($v -is [string] -and $v -and $v -notmatch '(?i)^(false|0|no|non)$') { return $true }
                }
            }
        }
        $txt = "$(Get-CiwFailText $Response)"
        if ($txt -match '(?i)two.?factor|2fa|double authentification|verification code|code de verification|authenticator') { return $true }
    } catch { }
    return $false
}

function Test-CloudiwayTwoFactorSuspected { return [bool]$script:CiwTwoFactor }

# Connexion de bas niveau : retourne { Token; Mode; Warn } ou leve. Login+mot de passe (SecureString) ou PAT (SecureString).
# Le mot de passe en clair n'existe que le temps de l'appel (corps JSON annule dans le finally) ; apres un login reussi, la liste de
# masquage ne conserve que le jeton (le mot de passe n'est plus utilise).
function Get-CiwLoginToken {
    param([string]$Login, [securestring]$Password, [securestring]$Pat)
    $plain = $null; $token = $null; $body = $null; $mode = ''; $warn = ''
    try {
        if ($Pat) {
            $plain = ConvertFrom-SecureStringPlain $Pat
            $script:CiwSecrets = @($plain)
            if ([string]::IsNullOrWhiteSpace($plain)) { throw 'jeton d''acces personnel (PAT) vide' }
            $loginErr = ''
            try {
                $body = @{ name = 'CloudiwayConnector'; pat = $plain } | ConvertTo-Json -Compress
                $r = Invoke-CiwRest -Method POST -Path '/Authentication/TechnicalLogin' -Body $body -Headers @{ accept = '*/*' }
                $token = Get-CiwTokenFromResponse $r
                if ($token -and $token -ceq 'token') { $token = $null }
                if ($token) { $mode = 'jeton obtenu par TechnicalLogin' } else { $loginErr = 'reponse TechnicalLogin sans jeton exploitable' }
            } catch {
                $loginErr = Get-CiwErrMsg $_
            }
            if (-not $token) {
                $token = $plain
                $mode = 'PAT utilise directement en Bearer'
                $warn = "Echange TechnicalLogin impossible ($loginErr) ; repli : $mode."
            }
            $script:CiwSecrets = @($plain, $token)
        } else {
            $plain = ConvertFrom-SecureStringPlain $Password
            $script:CiwSecrets = @($plain)
            if ([string]::IsNullOrWhiteSpace($Login) -or [string]::IsNullOrWhiteSpace($plain)) { throw 'identifiant ou mot de passe Cloudiway vide' }
            $body = @{ login = $Login; password = $plain; keepConnection = $true } | ConvertTo-Json -Compress
            $r = Invoke-CiwRest -Method POST -Path '/Authentication/Login' -Body $body -Headers @{ accept = '*/*' }
            if (Test-CiwTwoFactorSignal $r) { $script:CiwTwoFactor = $true }
            if (Test-CiwFailure $r) { throw ("connexion refusee par Cloudiway {0}" -f (Get-CiwFailText $r)) }
            $token = Get-CiwTokenFromResponse $r
            if ($token -and $token -cne 'token') {
                $mode = 'connexion par identifiant et mot de passe'
            } else {
                # Le champ token vaut litteralement "token" (ou est absent) : repli "cookies" comme l'ancien script.
                $token = $null
                try { $token = Get-CiwTokenViaCookies $body } catch { throw ("repli cookies en echec : {0}" -f (Get-CiwErrMsg $_)) }
                if (-not $token) { $script:CiwTwoFactor = $true; throw 'connexion acceptee mais aucun jeton exploitable (reponse et cookies) : la double authentification (2FA) est probablement activee sur ce compte' }
                $mode = 'connexion par identifiant et mot de passe (jeton lu dans les cookies)'
            }
            $script:CiwSecrets = @($token)   # le mot de passe n'est plus utile : seul le jeton reste a masquer
        }
        return [pscustomobject]@{ Token = $token; Mode = $mode; Warn = $warn }
    } finally {
        $plain = $null
        $body = $null
    }
}

# Reconnexion unique apres un 401 : PAT -> nouvel echange silencieux ; mot de passe -> redemande masquee. Retourne $true si le jeton est renouvele.
function Invoke-CiwReauth {
    $script:CiwReauthCount = 1 + [int]$script:CiwReauthCount
    $a = $script:CiwAuth
    if ($null -eq $a) { return $false }
    $pwd2 = $null
    try {
        $tok = $null
        if ("$($a.Kind)" -eq 'Pat') {
            $tok = Get-CiwLoginToken -Pat $a.Pat
        } else {
            Write-Status WARN 'Session Cloudiway expiree : reconnexion necessaire.' 'le mot de passe est redemande une seule fois (saisie masquee)'
            $pwd2 = Read-SecretText ("Mot de passe Cloudiway de {0} (session expiree, saisie masquee)" -f $a.Login)
            if (-not $pwd2) { return $false }
            $tok = Get-CiwLoginToken -Login $a.Login -Password $pwd2
        }
        if (-not $tok -or -not $tok.Token) { return $false }
        if ($script:Ciw.Headers -isnot [hashtable]) { $script:Ciw.Headers = @{} }
        $script:Ciw.Headers['Authorization'] = "Bearer $($tok.Token)"
        Write-RunLog 'CIW session renouvelee (re-authentification unique)'
        return $true
    } catch {
        Write-RunLog ("CIW re-authentification impossible : {0}" -f (Get-CiwErrMsg $_))
        return $false
    } finally {
        try { if ($pwd2) { $pwd2.Dispose() } } catch { }
    }
}

# Reverifie la session JUSTE AVANT la premiere modification du tenant (M2) : lecture seule (GET /Projects). Le droit d'ecriture (Contributor)
# ne peut pas etre sonde sans effet de bord : aucune route d'ecriture neutre n'est connue (a valider sur le projet de test).
# Retourne { Ok; Message }. Ne leve jamais.
function Confirm-CloudiwaySession {
    [CmdletBinding()]
    param()
    try {
        if (-not $script:Ciw.Authenticated) { return [pscustomobject]@{ Ok = $false; Message = 'session Cloudiway non ouverte' } }
        $r = Invoke-CiwRest -Method GET -Path '/Projects'
        if (Test-CiwFailure $r) { return [pscustomobject]@{ Ok = $false; Message = ("lecture des projets refusee {0}" -f (Get-CiwFailText $r)) } }
        return [pscustomobject]@{ Ok = $true; Message = 'session Cloudiway valide' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = (Get-CiwErrMsg $_) }
    }
}

# Jeux de parametres : -Login/-Password (mot de passe du DSI, SecureString) ou -Pat. Retourne des lignes { Name; Status; Detail; Impact }.
function Connect-CloudiwayApi {
    [CmdletBinding(DefaultParameterSetName = 'Login')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Login')][string]$Login,
        [Parameter(Mandatory, ParameterSetName = 'Login')][securestring]$Password,
        [Parameter(Mandatory, ParameterSetName = 'Pat')][securestring]$Pat,
        [Nullable[int]]$ProjectId = $null,
        [switch]$Interactive
    )
    $lines = [System.Collections.Generic.List[object]]::new()
    $script:Ciw.Headers = @{}
    $script:Ciw.ProjectId = 0
    $script:Ciw.Authenticated = $false
    $script:CiwAuth = $null
    $script:CiwReauthCount = 0
    $script:CiwTwoFactor = $false
    $noWrite = 'Aucune ecriture ne sera tentee cote Cloudiway ni cote tenant.'
    $twoFaHelp = 'Double authentification probable : creer un jeton PAT dans le portail (ACCOUNT > Security > NEW TOKEN), puis relancer avec -CloudiwayPat (commande ci-dessous).'
    $t = $null
    try {
        $t = if ($PSCmdlet.ParameterSetName -eq 'Login') { Get-CiwLoginToken -Login $Login -Password $Password } else { Get-CiwLoginToken -Pat $Pat }
        $mode = $t.Mode
        if ($t.Warn) { $lines.Add((New-CiwLine 'Authentification Cloudiway' 'WARN' $t.Warn 'Si 401 ensuite, le PAT est invalide (ou sans droit sur le projet) : le verifier.')) }
        $script:Ciw.Headers = @{ accept = '*/*'; Authorization = "Bearer $($t.Token)" }
        $script:CiwAuth = if ($PSCmdlet.ParameterSetName -eq 'Login') { @{ Kind = 'Login'; Login = $Login; Pat = $null } } else { @{ Kind = 'Pat'; Login = ''; Pat = $Pat } }
        $t = $null

        # Validation du jeton : liste des projets, puis selection.
        $projects = @(Get-CloudiwayProjects)
        if ($script:CiwLastError) {
            $lines.Add((New-CiwLine 'Authentification Cloudiway' 'FAIL' "Jeton non accepte ou projets illisibles : $($script:CiwLastError)" $noWrite))
        } else {
            $script:Ciw.Authenticated = $true
            if (-not ($lines | Where-Object { $_.Name -eq 'Authentification Cloudiway' })) {
                $lines.Add((New-CiwLine 'Authentification Cloudiway' 'OK' "Acces accepte ($mode)." 'Aucune donnee n''est ecrite dans le portail par cette etape.'))
            }
            $sel = Select-CloudiwayProject -ProjectId $ProjectId -Interactive:$Interactive -Projects $projects
            if ($sel.Ok) {
                $lines.Add((New-CiwLine 'Projet Cloudiway' 'OK' "Projet $($sel.ProjectId) ($($sel.Name)) retenu."))
                try {
                    $r = Invoke-CiwRest -Method GET -Path '/Connectors'
                    if (Test-CiwFailure $r) { throw ("reponse sans succes {0}" -f (Get-CiwFailText $r)) }
                    $n = @(Get-CiwData $r | Where-Object { $null -ne $_ }).Count
                    $lines.Add((New-CiwLine 'Lecture des connecteurs' 'OK' "$n connecteur(s) lisible(s) dans le projet."))
                } catch {
                    $lines.Add((New-CiwLine 'Lecture des connecteurs' 'FAIL' (Get-CiwErrMsg $_) 'Droits insuffisants sur le projet (Contributor attendu).'))
                }
            } else {
                $lines.Add((New-CiwLine 'Projet Cloudiway' 'FAIL' $sel.Message $noWrite))
            }
        }
    } catch {
        $imp = if ($script:CiwTwoFactor) { "$noWrite $twoFaHelp" } else { $noWrite }
        $lines.Add((New-CiwLine 'Authentification Cloudiway' 'FAIL' (Get-CiwErrMsg $_) $imp))
    } finally {
        $t = $null
    }
    if (@($lines | Where-Object Status -eq 'FAIL').Count -gt 0) { $script:Ciw.Authenticated = $false }
    return $lines
}

# --- Etat (m2) ---

function Remove-CiwTempFiles {
    # Fichiers temporaires du transport 'Path' : ecrases puis supprimes (suppression d'un fichier local temporaire, jamais d'un objet distant).
    foreach ($f in @($script:CiwTempFiles)) {
        try {
            if (Test-Path -LiteralPath $f) {
                $len = (Get-Item -LiteralPath $f).Length
                if ($len -gt 0) { [System.IO.File]::WriteAllBytes($f, [byte[]]::new($len)) }
                [System.IO.File]::Delete($f)
            }
        } catch { }
    }
    $script:CiwTempFiles.Clear()
}

# Vide l'etat de session (jeton, en-tetes, secrets connus, identifiants en memoire, connecteur lu). A appeler par le principal en fin de run.
function Clear-CloudiwayState {
    [CmdletBinding()]
    param()
    try { Remove-CiwTempFiles } catch { }
    try {
        $cred = Get-CiwProp $script:Ctx 'Credentials'
        if ($cred -is [System.Collections.IDictionary]) {
            foreach ($k in @($cred.Keys)) { if ($cred[$k] -is [byte[]]) { try { [Array]::Clear($cred[$k], 0, $cred[$k].Length) } catch { } } }
            $cred.Clear()
        } elseif ($null -ne $cred) {
            Set-CiwCtx 'Credentials' $null
        }
        if ($null -ne (Get-CiwProp $script:Ctx 'ExistingConnector')) { Set-CiwCtx 'ExistingConnector' $null }
    } catch { }
    $script:Ciw = [pscustomobject]@{ Base = 'https://api-production.cloudiway.com/ap1'; Headers = @{}; ProjectId = 0; Authenticated = $false }
    $script:CiwSecrets = @()
    $script:CiwLastError = ''
    $script:CiwNotices.Clear()
    $script:CiwAuth = $null
    $script:CiwReauthCount = 0
    $script:CiwPutCheck = $null
    $script:CiwTwoFactor = $false
}

# --- Aides dictionnaire (insensibles a la casse) ---

function Get-CiwKey($Dict, [string]$Name) {
    foreach ($k in @($Dict.Keys)) { if ("$k" -ieq $Name) { return $k } }
    return $null
}
function Set-CiwValue($Dict, [string]$Name, $Value) {
    $k = Get-CiwKey $Dict $Name
    if ($null -eq $k) { $k = $Name }
    $Dict[$k] = $Value
}
function Test-CiwFilled($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return (-not [string]::IsNullOrWhiteSpace($Value)) }
    return $true
}
function Test-CiwMasked($Value) {
    # Valeur d'une lecture masquee par le serveur (etoiles, marqueur) : ne doit jamais etre renvoyee telle quelle.
    if ($Value -isnot [string]) { return $false }
    return ($Value -match '^\s*\*+\s*$' -or $Value -match 'MASQUE')
}
function ConvertTo-CiwTable($Object) {
    # Copie profonde (aller-retour JSON) en table de hachage, toutes les cles conservees.
    return ($Object | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json -AsHashtable -Depth 50)
}

# --- Marqueur (externalKey) ---

# Marqueur non secret : CIW1|<empreinte du certificat, ou S<keyId> du secret client (Secret seul)>|<AAAAMMJJ d'expiration, UTC>.
function New-ConnectorMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Thumbprint, [Parameter(Mandatory)][datetime]$NotAfter)
    $t = ($Thumbprint -replace '[\s|-]', '').ToUpperInvariant()
    # La colonne ExternalKey du portail est limitee a 50 caracteres (erreur "String or binary data would be truncated", constate 2026-10-31) :
    # empreinte de certificat tronquee a 32 caracteres hexadecimaux, identifiant de secret "S"+32 ; les comparaisons se font par prefixe.
    $max = if ($t.StartsWith('S')) { 33 } else { 32 }
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }
    return ('{0}{1}|{2}' -f $script:CiwMarkerPrefix, $t, $NotAfter.ToUniversalTime().ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture))
}

# Nom de fichier du certificat envoye = marqueur de suivi du renouvellement (v2.4) : CIW1_<32 premiers hex de l'empreinte>_<AAAAMMJJ UTC>.pfx.
# Secret client seul : CIW1_S<id du secret, 32>_<AAAAMMJJ>.pfx. Que des caracteres [A-Za-z0-9_.-].
function New-ConnectorCertFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Thumbprint, [Parameter(Mandatory)][datetime]$NotAfter)
    $t = ($Thumbprint -replace '[^0-9A-Za-z]', '').ToUpperInvariant()
    $max = if ($t.StartsWith('S')) { 33 } else { 32 }
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }
    $name = ('CIW1_{0}_{1}.pfx' -f $t, $NotAfter.ToUniversalTime().ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture))
    if ($name -notmatch $script:CiwFileNameRx -or $name -cnotmatch $script:CiwFileMarkerRx) { throw 'nom de fichier du certificat non conforme au marqueur CIW1_<empreinte>_<date>.pfx' }
    return $name
}

function ConvertFrom-CiwMarkerDate([string]$Text) {
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) { return $d }
    return $null
}

# Lit le marqueur d'un connecteur (objet, ou directement une chaine : nom de fichier ou externalKey) : { Thumbprint; NotAfter [datetime, UTC]; Source }
# ou $null. v2.4 : lit d'ABORD connectorCertificate.fileName (motif CIW1_<hex>_<date>.pfx), sinon l'externalKey CIW1|..|.. (connecteurs
# anterieurs a la v2.4, dont le fileName vaut cloudiway.pfx). Source = 'fileName' | 'externalKey'.
function Get-ConnectorMarker {
    [CmdletBinding()]
    param($Connector)
    if ($null -eq $Connector) { return $null }
    $fn = ''; $key = ''
    if ($Connector -is [string]) {
        if ($Connector -cmatch '\.pfx$') { $fn = $Connector } else { $key = $Connector }
    } else {
        $fn = "$(Get-CiwProp (Get-CiwProp $Connector 'connectorCertificate') 'fileName')"
        $key = "$(Get-CiwProp $Connector 'externalKey')"
    }
    if ($fn -cmatch $script:CiwFileMarkerRx) {
        $d = ConvertFrom-CiwMarkerDate $Matches[2]
        if ($d) { return [pscustomobject]@{ Thumbprint = $Matches[1].ToUpperInvariant(); NotAfter = $d; Source = 'fileName' } }
    }
    if ($key -cmatch '^CIW1\|([^|\s]+)\|(\d{8})$') {
        $d = ConvertFrom-CiwMarkerDate $Matches[2]
        if ($d) { return [pscustomobject]@{ Thumbprint = $Matches[1]; NotAfter = $d; Source = 'externalKey' } }
    }
    return $null
}

# Connecteur "cree par l'outil" ? (marqueur V2 CIW1| ou ancienne marque)
function Test-CiwOwnedKey([string]$Key) {
    return ($Key -clike "$($script:CiwMarkerPrefix)*" -or $Key -ceq $script:CiwMarker)
}

# v2.4 : propriete d'un connecteur lu : etiquette externalKey (ecrite a la creation) OU nom de fichier du certificat au motif CIW1_ (un connecteur
# adopte ne peut pas recevoir d'etiquette externalKey, le portail la fige a la creation : son certificat renomme CIW1_...pfx porte la marque).
function Test-CiwOwnedConnector($Detail) {
    if ($null -eq $Detail) { return $false }
    if (Test-CiwOwnedKey "$(Get-CiwProp $Detail 'externalKey')") { return $true }
    return ("$(Get-CiwProp (Get-CiwProp $Detail 'connectorCertificate') 'fileName')" -cmatch $script:CiwFileMarkerRx)
}

# --- Connecteurs : lecture ---

# Reponse en echec ? $true si l'enveloppe indique isSuccess = false.
function Test-CiwFailure($Response) {
    $ok = Get-CiwProp $Response 'isSuccess'
    return ($null -ne $ok -and $ok -eq $false)
}
function Get-CiwFailText($Response) {
    $m = Get-CiwProp $Response 'message'
    if (-not $m) { $m = Get-CiwProp $Response 'errors' }
    if ($m -isnot [string]) { try { $m = ($m | ConvertTo-Json -Depth 4 -Compress) } catch { $m = '' } }
    return (Protect-CiwText (("$m" -replace '\s+', ' ').Trim()))
}

# Recherche par nom : retourne { Items; Error }. Error non vide = lecture douteuse (ne jamais creer).
function Find-CiwConnectors([string]$Name) {
    $err = ''
    try {
        $r = Invoke-CiwRest -Method GET -Path '/Connectors'
        if (Test-CiwFailure $r) {
            $err = 'reponse sans succes (isSuccess = false) {0}' -f (Get-CiwFailText $r)
        } else {
            $items = @(@(Get-CiwData $r) | Where-Object { $null -ne $_ -and (Get-CiwProp $_ 'name') -ieq $Name })
            if ($items.Count -gt 0) { return [pscustomobject]@{ Items = $items; Error = '' } }
        }
    } catch {
        $err = Get-CiwErrMsg $_
    }
    # Repli : recherche serveur.
    try {
        $body = @{ name = $Name; page = 1; pageSize = 50; projectId = $script:Ciw.ProjectId } | ConvertTo-Json -Compress
        $r = Invoke-CiwRest -Method POST -Path '/Connectors/Search' -Body $body
        if (-not (Test-CiwFailure $r)) {
            $data = Get-CiwData $r
            $items = if ($null -ne (Get-CiwProp $data 'items')) { @(Get-CiwProp $data 'items') } elseif ($null -ne (Get-CiwProp $data 'data')) { @(Get-CiwProp $data 'data') } else { @($data) }
            $found = @($items | Where-Object { $null -ne $_ -and (Get-CiwProp $_ 'name') -ieq $Name })
            if ($found.Count -gt 0) { return [pscustomobject]@{ Items = $found; Error = '' } }
        }
    } catch {
        if (-not $err) { $err = Get-CiwErrMsg $_ }
    }
    # GET en erreur et Search sans resultat : l'absence n'est pas prouvee, l'erreur reste signalee.
    return [pscustomobject]@{ Items = @(); Error = $err }
}

# Detail d'un connecteur : GET /Connectors/{id} (la liste peut masquer rawSettings). $null + CiwLastError si impossible.
function Get-CiwConnectorDetail([int]$Id) {
    try {
        $r = Invoke-CiwRest -Method GET -Path "/Connectors/$Id"
        if (Test-CiwFailure $r) { Set-CiwError ("lecture du detail du connecteur $Id impossible (isSuccess = false) {0}" -f (Get-CiwFailText $r)); return $null }
        $d = Get-CiwData $r
        if ($null -eq $d) { Set-CiwError "lecture du detail du connecteur $Id impossible (reponse vide)"; return $null }
        return $d
    } catch {
        Set-CiwError ("lecture du detail du connecteur $Id impossible : {0}" -f (Get-CiwErrMsg $_))
        return $null
    }
}

$script:CiwHomonyms = 0

function Get-CloudiwayConnector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [switch]$Detail)
    $script:CiwLastError = ''
    $script:CiwHomonyms = 0
    $f = Find-CiwConnectors $Name
    if (@($f.Items).Count -eq 0) {
        if ($f.Error) { Set-CiwError ("lecture du connecteur impossible, creation refusee : {0}" -f $f.Error) }
        return $null
    }
    $script:CiwHomonyms = @($f.Items).Count
    $first = @($f.Items)[0]
    if (-not $Detail) { return $first }
    $id = Get-CiwProp $first 'id'
    if ($null -eq $id) { return $first }
    $d = Get-CiwConnectorDetail ([int]$id)
    if ($null -eq $d) { return $null }
    return $d
}

# Etat d'un connecteur existant, avec garde-fous. State : Absent | Found | Multiple | Error.
function Get-CiwExisting([string]$Name) {
    $script:CiwLastError = ''
    $f = Find-CiwConnectors $Name
    if (@($f.Items).Count -eq 0) {
        if ($f.Error) {
            Set-CiwError ("lecture du connecteur impossible, creation refusee : {0}" -f $f.Error)
            return [pscustomobject]@{ State = 'Error'; Item = $null; Detail = $null; Error = $script:CiwLastError }
        }
        return [pscustomobject]@{ State = 'Absent'; Item = $null; Detail = $null; Error = '' }
    }
    if (@($f.Items).Count -gt 1) {
        return [pscustomobject]@{ State = 'Multiple'; Item = $null; Detail = $null; Error = "$(@($f.Items).Count) connecteurs portent le nom '$Name'" }
    }
    $item = @($f.Items)[0]
    $id = Get-CiwProp $item 'id'
    $d = $null
    if ($null -ne $id) { $d = Get-CiwConnectorDetail ([int]$id) }
    if ($null -eq $d) {
        return [pscustomobject]@{ State = 'Error'; Item = $item; Detail = $null; Error = "$($script:CiwLastError)" }
    }
    return [pscustomobject]@{ State = 'Found'; Item = $item; Detail = $d; Error = '' }
}

# Lit le connecteur existant (nom codifie $script:Ctx.Names.Connector) AVANT le plan Entra et renseigne $script:Ctx.ExistingConnector
# (detail, ou $null) ainsi que ExistingConnectorState (Absent|Found|Multiple|Error|Skipped) et ExistingConnectorError.
# Retourne des lignes { Name; Status; Detail; Impact }. Ne leve jamais.
function Initialize-CloudiwayConnectorState {
    [CmdletBinding()]
    param()
    $lines = [System.Collections.Generic.List[object]]::new()
    $title = 'Connecteur Cloudiway existant'
    Set-CiwCtx 'ExistingConnector' $null
    Set-CiwCtx 'ExistingConnectorState' 'Skipped'
    Set-CiwCtx 'ExistingConnectorError' ''
    try {
        $names = Get-CiwProp $script:Ctx 'Names'
        $name = [string](Get-CiwProp $names 'Connector')
        if (-not $name) { $name = [string](Get-CiwProp $script:Ctx 'ConnectorName') }
        if ([bool](Get-CiwProp $script:Ctx 'SkipCloudiway') -or -not $script:Ciw.Authenticated -or -not $name) {
            $lines.Add((New-CiwLine $title 'WARN' 'Lecture ignoree (option -SkipCloudiway, acces non valide ou nom absent).'))
            return $lines
        }
        $ex = Get-CiwExisting $name
        Set-CiwCtx 'ExistingConnectorState' $ex.State
        switch ($ex.State) {
            'Absent' { $lines.Add((New-CiwLine $title 'OK' "Aucun connecteur '$name' dans le projet : il sera cree.")) }
            'Multiple' {
                Set-CiwCtx 'ExistingConnectorError' $ex.Error
                $lines.Add((New-CiwLine $title 'FAIL' "$($ex.Error) : aucun n'est modifie." 'Choisir un nom unique ou regler les doublons dans le portail.'))
            }
            'Error' {
                $why = if ($ex.Error) { $ex.Error } else { $script:CiwLastError }
                Set-CiwCtx 'ExistingConnectorError' $why
                $lines.Add((New-CiwLine $title 'FAIL' "Lecture impossible : $why" 'Le connecteur ne sera ni cree ni modifie.'))
            }
            default {
                Set-CiwCtx 'ExistingConnector' $ex.Detail
                $mk = Get-ConnectorMarker $ex.Detail
                $blk = Get-CiwBlockReason $ex.Detail (Get-CiwDesired)
                $txt = if ($mk) { "Connecteur $(Get-CiwProp $ex.Detail 'id') lu (marqueur $($mk.Source) : empreinte $($mk.Thumbprint), expiration $($mk.NotAfter.ToString('yyyy-MM-dd')))." } else { "Connecteur $(Get-CiwProp $ex.Detail 'id') lu (sans marqueur CIW1)." }
                if ($blk) {
                    Set-CiwCtx 'ExistingConnectorError' $blk
                    $lines.Add((New-CiwLine $title 'WARN' "$txt Bloque : $blk"))
                } else {
                    $lines.Add((New-CiwLine $title 'OK' $txt))
                }
            }
        }
    } catch {
        Set-CiwCtx 'ExistingConnector' $null
        Set-CiwCtx 'ExistingConnectorState' 'Error'
        $lines.Add((New-CiwLine $title 'FAIL' (Get-CiwErrMsg $_)))
    }
    return $lines
}

# --- Corps de connecteur ---

# Transport 'Path' : fichier temporaire a ACL restreinte ; supprime (apres ecrasement) par Remove-CiwTempFiles.
function New-CiwTempPfx([byte[]]$Bytes) {
    $dir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $path = Join-Path $dir ("ciw-{0}.pfx" -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllBytes($path, [byte[]]::new(0))
    $script:CiwTempFiles.Add($path)
    try {
        $acl = Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($me, 'FullControl', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl
    } catch { }
    [System.IO.File]::WriteAllBytes($path, $Bytes)
    return $path
}

# Objet connectorCertificate. Base64 (defaut) : CONTENU du PFX encode en memoire, aucun fichier ; Path : fichier temporaire (ci-dessus).
# Le contenu n'est jamais journalise.
function New-CiwCertificateObject([byte[]]$PfxBytes, [string]$PfxPassword, [int]$ConnectorId, [string]$Transport = 'Base64', [string]$FileName = 'cloudiway.pfx') {
    if (-not $PfxBytes -or $PfxBytes.Length -eq 0) { throw 'contenu PFX absent : impossible de declarer le certificat' }
    if ($FileName -notmatch $script:CiwFileNameRx) { throw 'nom de fichier du certificat invalide (seuls A-Z a-z 0-9 _ . - sont admis)' }
    if ($Transport -eq 'Path') {
        $p = New-CiwTempPfx $PfxBytes
        return [ordered]@{ secret = $PfxPassword; certificateFile = $p; fileName = $FileName; connectorId = $ConnectorId }
    }
    return [ordered]@{ secret = $PfxPassword; certificateFile = [Convert]::ToBase64String($PfxBytes); fileName = $FileName; connectorId = $ConnectorId }
}

# Fonction pure (hors fichier temporaire du transport Path) : aucun appel reseau. rawsettings est une chaine JSON (forme du script de 2023).
function New-ConnectorBody {
    [CmdletBinding()]
    param(
        [ValidateSet('Source', 'Target')][string]$Mode = 'Source',
        [string[]]$Workloads = @(),
        [int[]]$ProductIds = @(),
        [string]$TenantShort,
        [string]$TenantName,
        [string]$DefaultDomain,
        [string]$AppId,
        [string]$ServiceAccountUpn,
        [string]$ServiceAccountPassword,
        [int]$Region = 1,
        [ValidateSet('Certificate', 'Secret', 'Both')][string]$AuthMethod = 'Certificate',
        [byte[]]$PfxBytes,
        [string]$PfxPassword,
        [string]$PfxFileName = 'cloudiway.pfx',
        [string]$ClientSecret,
        [int]$ConnectorId = 0,
        [string]$Name,
        [ValidateSet('Base64', 'Path')][string]$CertificateTransport = 'Base64',
        [string]$ExternalKey = ''
    )
    $tn = if ($TenantName) { $TenantName } else { $TenantShort }
    $settings = [ordered]@{
        TenantName   = $tn
        RestClientId = $AppId
    }
    if ($AuthMethod -in 'Secret', 'Both' -and $ClientSecret) { $settings['RestClientSecret'] = $ClientSecret }
    $settings['Domains'] = @($DefaultDomain)
    if ($ServiceAccountUpn) { $settings['MigrationAccount'] = $ServiceAccountUpn }
    if ($ServiceAccountUpn -and $ServiceAccountPassword) { $settings['MigrationAccountPassword'] = $ServiceAccountPassword }
    $settings['ServerRegion'] = $Region
    $settings['AuthenticationType'] = 3

    $body = [ordered]@{
        connectorTypeId = 2
        name            = $Name
        isTarget        = ($Mode -eq 'Target')
        rawProductList  = ('[' + ((@($ProductIds) | ForEach-Object { [string][int]$_ }) -join ',') + ']')
        rawsettings     = ($settings | ConvertTo-Json -Depth 6 -Compress)
    }
    if ($ExternalKey) { $body['externalKey'] = $ExternalKey }
    if ($ConnectorId -gt 0) { $body['id'] = $ConnectorId }
    if ($AuthMethod -in 'Certificate', 'Both' -and $PfxBytes -and $PfxBytes.Length -gt 0) {
        $body['connectorCertificate'] = New-CiwCertificateObject -PfxBytes $PfxBytes -PfxPassword $PfxPassword -ConnectorId $ConnectorId -Transport $CertificateTransport -FileName $PfxFileName
    }
    return $body
}

# Version affichable/journalisable d'un payload : rawsettings (chaine JSON) est deplie pour que le masquage s'applique a ses cles.
function ConvertTo-MaskedConnectorBody($Body) {
    $copy = [ordered]@{}
    foreach ($k in $Body.Keys) { $copy[$k] = $Body[$k] }
    foreach ($k in @($copy.Keys)) {
        if ("$k" -ieq 'rawsettings' -and $copy[$k] -is [string]) {
            try { $copy[$k] = ($copy[$k] | ConvertFrom-Json -ErrorAction Stop) } catch { $copy[$k] = '***MASQUE***' }
        }
    }
    ConvertTo-MaskedJson $copy
}

function ConvertTo-CiwSettings($Connector) {
    # Lit rawSettings / rawsettings (chaine JSON ou objet) ; $null si illisible.
    $raw = Get-CiwProp $Connector 'rawSettings'
    if ($null -eq $raw) { return $null }
    if ($raw -is [string]) { try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null } }
    return $raw
}

function ConvertTo-CiwProductSet($Connector) {
    $raw = Get-CiwProp $Connector 'rawProductList'
    if ($null -eq $raw) { return @() }
    $arr = $raw
    if ($raw -is [string]) { try { $arr = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return @() } }
    return @(@($arr) | ForEach-Object { [int]$_ } | Sort-Object -Unique)
}

# Valeurs attendues cote Cloudiway, relues dans le contexte AU MOMENT DE L'APPEL (les identifiants viennent d'etre generes par le module Entra).
function Get-CiwDesired {
    $ctx = $script:Ctx
    $created = Get-CiwProp $ctx 'Created'
    $cred = Get-CiwProp $ctx 'Credentials'
    $names = Get-CiwProp $ctx 'Names'
    $region = Get-CiwProp $ctx 'Region'
    $pids = $null
    $unknown = @()
    $source = ''
    try {
        $gp = @{ Workloads = @($ctx.Workloads) }
        $ov = Get-CiwProp $ctx 'ProductIds'
        $mf = Get-CiwProp $ctx 'ProductMapFile'
        if ($ov) { $gp['Override'] = [int[]]@($ov) }
        if ($mf) { $gp['MapFile'] = [string]$mf }
        $res = Get-ProductIds @gp
        $pids = @(Get-CiwProp $res 'Ids')
        $unknown = @(Get-CiwProp $res 'Unknown') | Where-Object { $_ }
        $source = "$(Get-CiwProp $res 'Source')"
    } catch {
        $unknown = @("(Get-ProductIds en erreur : $(Get-CiwErrMsg $_))")
    }
    $transport = "$(Get-CiwProp $ctx 'CertificateTransport')"
    if ($transport -notin 'Base64', 'Path') { $transport = 'Base64' }
    $auth = "$(Get-CiwProp $ctx 'AuthMethod')"
    if ($auth -notin 'Certificate', 'Secret', 'Both') { $auth = 'Certificate' }
    $bytes = Get-CiwBytes $cred 'PfxBytes'
    if ($bytes -isnot [byte[]] -or $bytes.Length -eq 0) { $bytes = $null }
    $notAfter = Get-CiwProp $cred 'CertNotAfter'
    $thumb = "$(Get-CiwProp $cred 'CertThumbprint')"
    $tenantName = "$(Get-CiwProp $ctx 'TenantName')"
    if (-not $tenantName) { $tenantName = "$(Get-CiwProp $ctx 'TenantShort')" }
    $appName = "$(Get-CiwProp $names 'App')"
    # v2.4 : le nom de fichier du certificat envoye est le marqueur de suivi (CIW1_<empreinte 32>_<AAAAMMJJ>.pfx) ; sans certificat genere : valeur neutre.
    $certFile = 'cloudiway.pfx'
    if ($bytes -and $thumb -and $notAfter -is [datetime]) { try { $certFile = New-ConnectorCertFileName -Thumbprint $thumb -NotAfter $notAfter } catch { $certFile = 'cloudiway.pfx' } }
    [pscustomobject]@{
        ProductIds        = @($pids | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        Unknown           = @($unknown)
        Source            = $source
        AppId             = Get-CiwProp $created 'AppId'
        ServiceAccountUpn = Get-CiwProp $created 'ServiceAccountUpn'
        ServiceAccountPwd = ConvertTo-CiwPlain (Get-CiwProp $cred 'ServiceAccountPassword')
        PfxBytes          = $bytes
        PfxPassword       = ConvertTo-CiwPlain (Get-CiwProp $cred 'PfxPassword')
        PfxFileName       = $certFile
        ClientSecret      = ConvertTo-CiwPlain (Get-CiwProp $cred 'ClientSecret')
        Thumbprint        = $thumb
        NotAfter          = $(if ($notAfter -is [datetime]) { $notAfter } else { $null })
        SecretKeyId       = "$(Get-CiwProp $cred 'SecretKeyId')"
        SecretNotAfter    = $(if ((Get-CiwProp $cred 'SecretNotAfter') -is [datetime]) { Get-CiwProp $cred 'SecretNotAfter' } else { $null })
        AuthMethod        = $auth
        Region            = $(if ($region) { [int]$region } else { 1 })
        Transport         = $transport
        TenantName        = $tenantName
    }
}

# Une ligne du plan dans l'une des zones, en CREATE/UPDATE ?
function Test-CiwPlanArea([string[]]$Areas) {
    foreach ($it in @($script:Plan)) {
        if ($null -ne $it -and "$($it.Area)" -in $Areas -and "$($it.Action)" -in 'CREATE', 'UPDATE') { return $true }
    }
    return $false
}

# De nouveaux identifiants sont-ils a declarer ? (renouvellement actif : defaut v2.3 sauf -KeepCredentials, ou ligne Certificate CREATE/UPDATE decidee par le module Entra)
function Test-CiwCertificateChange {
    if ([bool](Get-CiwProp $script:Ctx 'RotateCredentials') -or [bool](Get-CiwProp $script:Ctx 'RotateCertificate')) { return $true }
    return (Test-CiwPlanArea @('Certificate', 'Secret', 'Credentials'))
}

# Identifiants requis mais absents ? Retourne le texte d'echec, ou ''. $Needed = declaration de nouveaux identifiants attendue.
function Test-CiwMissingCredentials($Want, [bool]$Needed) {
    if (-not $Needed) { return '' }
    if ($Want.AuthMethod -in 'Certificate', 'Both') {
        if (-not $Want.PfxBytes) { return 'certificat indisponible : le contenu PFX aurait du etre genere dans ce passage (Credentials.PfxBytes absent). Relancer la meme commande (sans -KeepCredentials).' }
        if (-not $Want.PfxPassword) { return 'mot de passe du PFX indisponible : il aurait du etre genere dans ce passage. Relancer la meme commande (sans -KeepCredentials).' }
    }
    if ($Want.AuthMethod -in 'Secret', 'Both' -and -not $Want.ClientSecret) {
        return 'secret client indisponible : il aurait du etre genere dans ce passage (Credentials.ClientSecret absent). Relancer la meme commande (sans -KeepCredentials).'
    }
    return ''
}

# Garde-fous sur un connecteur existant (detail lu). Retourne le texte de blocage, ou '' si on peut continuer.
function Get-CiwBlockReason($Detail, $Want) {
    $ctx = $script:Ctx
    $id = Get-CiwProp $Detail 'id'
    $tid = Get-CiwProp $Detail 'connectorTypeId'
    if ($null -ne $tid -and "$tid" -ne '2') { return "le connecteur $id est de type $tid (type 2 attendu) : jamais modifie." }
    $isT = Get-CiwProp $Detail 'isTarget'
    $wantT = ("$(Get-CiwProp $ctx 'Mode')" -eq 'Target')
    if ($null -ne $isT -and [bool]$isT -ne $wantT) {
        $have = if ([bool]$isT) { 'Cible' } else { 'Source' }
        $wantTxt = if ($wantT) { 'Cible' } else { 'Source' }
        return "le connecteur $id est de sens $have alors que $wantTxt est demande : le sens d'un connecteur existant n'est jamais modifie ; choisir un autre nom."
    }
    $marked = Test-CiwOwnedConnector $Detail
    if (-not $marked -and -not [bool](Get-CiwProp $ctx 'AdoptExisting')) {
        return "connecteur $id cree a la main (sans marqueur $($script:CiwMarkerPrefix)...) : utilisez -AdoptExisting pour l'adopter."
    }
    $st = ConvertTo-CiwSettings $Detail
    if ($st) {
        $reg = Get-CiwProp $st 'ServerRegion'
        if ($null -ne $reg -and "$reg" -ne '' -and "$reg" -ne "$($Want.Region)") { return "le connecteur $id utilise la region $reg (region $($Want.Region) demandee) : la region d'un connecteur existant n'est jamais modifiee ; relancer avec -Region $reg pour la conserver, ou choisir un autre -ConnectorName." }
        $au = Get-CiwProp $st 'AuthenticationType'
        if ($null -ne $au -and "$au" -ne '' -and "$au" -ne '3') { return "le connecteur $id utilise le type d'authentification $au (3 attendu : certificat) : jamais modifie par l'outil ; choisir un autre -ConnectorName, ou le corriger dans le portail Cloudiway (aucune option de l'outil ne change ce type)." }
        # M4 : collision de noms. Un connecteur de meme nom qui designe un AUTRE tenant ou une AUTRE application n'est pas le notre.
        if (-not [bool](Get-CiwProp $ctx 'AdoptExisting')) {
            $tn = "$(Get-CiwProp $st 'TenantName')"
            if ($tn -and $Want.TenantName -and $tn -ine "$($Want.TenantName)") {
                return "le connecteur $id (nom '$(Get-CiwProp $Detail 'name')') designe le tenant '$tn' alors que le tenant voulu est '$($Want.TenantName)' : collision de noms, rien n'est modifie. Choisir un autre -ConnectorName, ou -AdoptExisting si ce connecteur doit bien etre repris."
            }
            $mm = Get-CiwRestClientMismatch $Detail "$($Want.AppId)"
            if ($mm) { return $mm }
        }
    }
    return ''
}

# M4 : le RestClientId du connecteur existant differe de l'application de ce tenant. '' si identique, inconnu, ou -AdoptExisting.
function Get-CiwRestClientMismatch($Detail, [string]$AppId) {
    if ([bool](Get-CiwProp $script:Ctx 'AdoptExisting')) { return '' }
    if (-not $AppId) { return '' }
    $st = ConvertTo-CiwSettings $Detail
    $rc = if ($st) { "$(Get-CiwProp $st 'RestClientId')" } else { '' }
    if ($rc -and $rc -ine $AppId) {
        return "le connecteur $(Get-CiwProp $Detail 'id') designe l'application $rc alors que celle de ce tenant est $AppId : collision de noms ou application recreee, rien n'est modifie. Choisir un autre -ConnectorName, ou -AdoptExisting si ce connecteur doit etre rattache a l'application actuelle."
    }
    return ''
}

# M4 (cas particulier) : le connecteur etiquete designe une application (RestClientId) alors que l'application de ce tenant n'existe pas
# (elle va etre creee) : meme collision. $AppId vide = application absente. Retourne le texte de blocage, ou ''.
function Get-CiwMissingAppReason($Detail, [string]$AppId) {
    if ([bool](Get-CiwProp $script:Ctx 'AdoptExisting')) { return '' }
    if ($AppId) { return '' }
    $st = ConvertTo-CiwSettings $Detail
    $rc = if ($st) { "$(Get-CiwProp $st 'RestClientId')" } else { '' }
    if (-not $rc) { return '' }
    if (-not (Test-CiwOwnedConnector $Detail)) { return '' }
    return "le connecteur $(Get-CiwProp $Detail 'id') designe l'application $rc, qui n'existe pas dans ce tenant (supprimee, ou connecteur d'un autre tenant) : rien n'est modifie. Choisir un autre -ConnectorName, ou -AdoptExisting pour rattacher ce connecteur a une nouvelle application."
}

# Marqueur a ecrire : nouveau (CIW1) si de nouveaux identifiants sont envoyes, sinon marqueur existant conserve, sinon ancienne marque.
function Get-CiwMarkerToWrite($Want, [string]$ExistingKey, [bool]$SendingNew) {
    if ($SendingNew) {
        # Certificat (Certificate, Both) : empreinte du certificat. Secret seul : "S" + keyId du secret (identifiant lu par le module Entra
        # pour decider du renouvellement). Jamais la valeur du secret.
        $na = $Want.NotAfter
        if ($Want.Thumbprint) { $th = $Want.Thumbprint }
        elseif ($Want.SecretKeyId) { $th = 'S' + $Want.SecretKeyId; $na = $Want.SecretNotAfter }
        else { $th = 'SECRET' }
        if ($null -eq $na) {
            $days = 180
            $v = Get-CiwProp $script:Ctx 'ValidityDays'
            if (-not $v) { $v = Get-CiwProp $script:Ctx 'CertValidityDays' }
            if ($v) { $days = [int]$v }
            $na = (Get-Date).ToUniversalTime().AddDays($days)
        }
        return (New-ConnectorMarker -Thumbprint $th -NotAfter $na)
    }
    if (Test-CiwOwnedKey $ExistingKey) { return $ExistingKey }
    return $script:CiwMarker
}

# Corps d'un PUT (B2) : copie profonde du detail lu, seules les cles gerees sont modifiees. Leve un texte clair si impossible.
function New-CiwUpdateBody($Detail, $Want) {
    $ctx = $script:Ctx
    $body = ConvertTo-CiwTable $Detail
    $rsKey = Get-CiwKey $body 'rawSettings'
    if ($null -eq $rsKey -or -not (Test-CiwFilled $body[$rsKey])) { throw 'parametres (rawSettings) illisibles : mise a jour refusee pour ne rien degrader. Corriger depuis le portail.' }
    $rsWasString = ($body[$rsKey] -is [string])
    if ($rsWasString) {
        try { $st = $body[$rsKey] | ConvertFrom-Json -AsHashtable -Depth 50 -ErrorAction Stop } catch { throw 'parametres (rawSettings) illisibles (JSON invalide) : mise a jour refusee pour ne rien degrader.' }
    } else { $st = $body[$rsKey] }
    if ($st -isnot [System.Collections.IDictionary]) { throw 'parametres (rawSettings) de forme inattendue : mise a jour refusee pour ne rien degrader.' }

    # Cles gerees
    if ($Want.AppId -and "$(Get-CiwProp $st 'RestClientId')" -ne "$($Want.AppId)") { Set-CiwValue $st 'RestClientId' ([string]$Want.AppId) }
    if ($Want.TenantName -and "$(Get-CiwProp $st 'TenantName')" -ine "$($Want.TenantName)") { Set-CiwValue $st 'TenantName' ([string]$Want.TenantName) }
    $dd = Get-CiwProp $ctx 'DefaultDomain'
    if ($dd) {
        $doms = @(@(Get-CiwProp $st 'Domains') | Where-Object { Test-CiwFilled $_ })
        if (@($doms | Where-Object { "$_" -ieq "$dd" }).Count -eq 0) { Set-CiwValue $st 'Domains' @($doms + [string]$dd) }
    }
    if ($Want.ServiceAccountUpn) {
        $curUpn = "$(Get-CiwProp $st 'MigrationAccount')"
        if ($curUpn -ine "$($Want.ServiceAccountUpn)") {
            Set-CiwValue $st 'MigrationAccount' ([string]$Want.ServiceAccountUpn)
            $pk = Get-CiwKey $st 'MigrationAccountPassword'
            if ($pk -and -not $Want.ServiceAccountPwd) { $st.Remove($pk) }   # jamais l'ancien mot de passe pour un autre compte
        }
        if ($Want.ServiceAccountPwd) {
            Set-CiwValue $st 'MigrationAccountPassword' ([string]$Want.ServiceAccountPwd)
        } elseif ([bool](Get-CiwProp $ctx 'ServiceAccountPasswordManual')) {
            Add-CiwNotice "Compte de service $($Want.ServiceAccountUpn) : mot de passe non genere dans ce passage (compte adopte) ; le saisir dans le portail Cloudiway pour ce connecteur."
        }
        # B1 : sans nouveau mot de passe, celui du connecteur n'est PAS touche (cle conservee telle que lue, ou omise si le GET la masque).
    }
    if ($Want.AuthMethod -in 'Secret', 'Both' -and $Want.ClientSecret) { Set-CiwValue $st 'RestClientSecret' ([string]$Want.ClientSecret) }
    # Secrets deja presents dans la lecture : conserves s'ils sont reels, retires s'ils sont masques ou vides (jamais renvoyer un masque).
    foreach ($k in @($st.Keys)) {
        if ("$k" -match 'password|secret' -and (-not (Test-CiwFilled $st[$k]) -or (Test-CiwMasked $st[$k]))) { $st.Remove($k) }
    }
    $body[$rsKey] = if ($rsWasString) { ($st | ConvertTo-Json -Depth 20 -Compress) } else { $st }

    # Produits : union (jamais de retrait)
    $plKey = Get-CiwKey $body 'rawProductList'
    $have = ConvertTo-CiwProductSet $Detail
    $union = @(@($have) + @($Want.ProductIds) | Sort-Object -Unique)
    if ($null -eq $plKey) { $plKey = 'rawProductList'; $plString = $true } else { $plString = ($body[$plKey] -is [string]) }
    $body[$plKey] = if ($plString) { '[' + (($union | ForEach-Object { [string]$_ }) -join ',') + ']' } else { @($union) }

    # Certificat (v2.4, faits mesures sur le vrai portail le 2026-10-31) : un PUT SANS connectorCertificate sur un connecteur qui possede un certificat
    # echoue (HTTP 500 "Object reference not set to an instance of an object", connecteur inchange). Un PUT AVEC connectorCertificate REMPLACE
    # l'enregistrement SUR PLACE (meme id, nouveau fileName). Un nouveau PFX est donc toujours envoye ; sans nouvel identifiant dans ce passage
    # (-KeepCredentials) la mise a jour est refusee en amont (ligne de plan BLOQUE) et, par securite, ici.
    $ccKey = Get-CiwKey $body 'connectorCertificate'
    $cid = [int](Get-CiwProp $Detail 'id')
    $sendingCert = ($Want.AuthMethod -in 'Certificate', 'Both' -and $Want.PfxBytes)
    if ($sendingCert) {
        Set-CiwValue $body 'connectorCertificate' (New-CiwCertificateObject -PfxBytes $Want.PfxBytes -PfxPassword ([string]$Want.PfxPassword) -ConnectorId $cid -Transport $Want.Transport -FileName $Want.PfxFileName)
    } elseif ($null -ne $ccKey -and $null -ne $body[$ccKey]) {
        throw $script:CiwNeedCertMsg
    }

    # externalKey : JAMAIS modifie par un PUT (le portail le fige a la creation) ; reste tel que lu. Le marqueur de suivi est le fileName du certificat.
    return $body
}

# Relit le connecteur APRES un POST/PUT (meme quand la reponse etait une erreur reseau, un timeout ou un 5xx : resultat ambigu) et decide d'apres
# l'etat REEL. Seul indicateur observable fiable : connectorCertificate.fileName == le nom envoye. Retourne { State; FileName; Id; Detail } avec
# State = Confirmed (le portail porte le nouveau certificat) | NotTaken (relu, mais ancien nom ou pas de certificat) | Unverifiable (lecture impossible).
# Ne leve jamais ; aucun secret dans Detail.
function Confirm-CiwConnectorWrite {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [int]$Id = 0, [Parameter(Mandatory)][string]$ExpectedFileName)
    $res = [pscustomobject]@{ State = 'Unverifiable'; FileName = ''; Id = $Id; Detail = '' }
    try {
        $d = $null
        if ($Id -gt 0) {
            $d = Get-CiwConnectorDetail $Id
            if ($null -eq $d) { $res.Detail = "relecture impossible : $($script:CiwLastError)"; return $res }
        } else {
            $ex = Get-CiwExisting $Name
            if ($ex.State -eq 'Absent') { $res.State = 'NotTaken'; $res.Detail = "connecteur '$Name' absent apres l'ecriture"; return $res }
            if ($ex.State -ne 'Found') { $res.Detail = "relecture impossible : $($ex.Error)"; return $res }
            $d = $ex.Detail
            $res.Id = [int](Get-CiwProp $d 'id')
        }
        $cc = Get-CiwProp $d 'connectorCertificate'
        if ($null -eq $cc) { $res.State = 'NotTaken'; $res.Detail = 'le connecteur ne porte aucun certificat'; return $res }
        $fn = "$(Get-CiwProp $cc 'fileName')"
        $res.FileName = $fn
        if (-not $fn) { $res.Detail = 'nom de fichier du certificat non lisible'; return $res }
        if ($fn -ceq $ExpectedFileName) { $res.State = 'Confirmed'; $res.Detail = 'nom de fichier du certificat conforme a l''envoi'; return $res }
        $res.State = 'NotTaken'
        $res.Detail = 'le certificat du connecteur porte toujours un autre nom de fichier'
        return $res
    } catch {
        $res.State = 'Unverifiable'
        $res.Detail = "relecture impossible : $(Get-CiwErrMsg $_)"
        return $res
    }
}

# Application commune du plan (CREATE ou UPDATE) ; retourne $true/$false et place le message dans $script:CiwLastError.
# v2.4 : l'ecriture n'est CONFIRMEE (ConnectorWriteOk) qu'apres relecture : connectorCertificate.fileName == nom envoye. Une reponse en erreur dont la
# relecture est conforme est une ecriture confirmee ; un succes annonce dont le nom de fichier n'a pas change est un ECHEC (le portail n'a pas pris
# le certificat en compte) ; une relecture impossible est traitee comme NON confirmee (aucun retrait, aucune reinitialisation du mot de passe).
function Invoke-CiwApplyConnector {
    $script:CiwLastError = ''
    $script:CiwPutCheck = $null
    $b = $null
    try {
        $c = $script:Ctx
        # M2 : le nouveau mot de passe du compte de service est genere ICI (en memoire) pour etre envoye au connecteur d'abord ; le compte
        # lui-meme n'est reinitialise qu'APRES le succes de l'ecriture du connecteur (ligne de plan "mot de passe", zone ServiceAccountPwd).
        if ([bool](Get-CiwProp $c 'ServiceAccountResetPending')) {
            $crd = Get-CiwProp $c 'Credentials'
            if ($crd -is [System.Collections.IDictionary] -and -not $crd['ServiceAccountPassword']) { $crd['ServiceAccountPassword'] = New-StrongPassword }
        }
        $d = Get-CiwDesired
        $cname = [string](Get-CiwProp (Get-CiwProp $c 'Names') 'Connector')
        if (-not $cname) { $cname = [string](Get-CiwProp $c 'ConnectorName') }
        if (-not $d.AppId) { Set-CiwError 'application impossible : identifiant d''application absent du contexte.'; return $false }
        $ex = Get-CiwExisting $cname
        switch ($ex.State) {
            'Error' { if (-not $script:CiwLastError) { Set-CiwError ("lecture du connecteur impossible, creation refusee : {0}" -f $ex.Error) }; return $false }
            'Multiple' { Set-CiwError ("{0} : application refusee." -f $ex.Error); return $false }
        }
        $sendCert = [bool]($d.AuthMethod -in 'Certificate', 'Both' -and $d.PfxBytes)
        $expectFile = $(if ($sendCert) { [string]$d.PfxFileName } else { '' })
        $verifyId = 0
        $method = 'POST'; $path = '/Connectors'
        if ($ex.State -eq 'Found') {
            $blk = Get-CiwBlockReason $ex.Detail $d
            if ($blk) { Set-CiwError "application refusee : $blk"; return $false }
            $miss = Test-CiwMissingCredentials $d (Test-CiwCertificateChange)
            if ($miss) { Set-CiwError "$miss Connecteur non modifie."; return $false }
            # v2.4 (d) : le portail exige le certificat lors d'une mise a jour d'un connecteur qui en possede un (HTTP 500 sinon).
            if (-not $sendCert -and $null -ne (Get-CiwProp $ex.Detail 'connectorCertificate')) {
                Set-CiwError "$($script:CiwNeedCertMsg). Connecteur non modifie (aucun PUT tente)."
                return $false
            }
            $b = New-CiwUpdateBody $ex.Detail $d
            $id = [int](Get-CiwProp $ex.Detail 'id')
            # B1 : instantane de ce que la lecture donnait, pour la verification apres coup (Test-CloudiwayCompliance).
            $stPre = ConvertTo-CiwSettings $ex.Detail
            $ccPre = Get-CiwProp $ex.Detail 'connectorCertificate'
            $script:CiwPutCheck = [pscustomobject]@{
                Id = $id; Create = $false; ExpectedAccount = $(if ($d.ServiceAccountUpn) { "$($d.ServiceAccountUpn)" } else { "$(Get-CiwProp $stPre 'MigrationAccount')" })
                ExpectedClientId = $(if ($d.AppId) { "$($d.AppId)" } else { "$(Get-CiwProp $stPre 'RestClientId')" })
                CertSent = $sendCert; ExpectedFileName = $expectFile; CertId = "$(Get-CiwProp $ccPre 'id')"; CertFileName = "$(Get-CiwProp $ccPre 'fileName')"
            }
            $verifyId = $id
            $method = 'PUT'; $path = "/Connectors/$id"
        } else {
            # Creation : les identifiants du mode d'authentification doivent exister (generes dans ce passage).
            $miss = Test-CiwMissingCredentials $d $true
            if ($miss) { Set-CiwError "$miss Connecteur non cree."; return $false }
            if ($d.ServiceAccountUpn -and -not $d.ServiceAccountPwd) {
                Add-CiwNotice "Compte de service $($d.ServiceAccountUpn) : mot de passe non genere dans ce passage (compte adopte) ; le saisir dans le portail Cloudiway pour ce connecteur."
            }
            # externalKey : etiquette de propriete, ECRITE A LA CREATION SEULEMENT (le portail ne la modifie plus ensuite).
            $mk = Get-CiwMarkerToWrite $d '' $true
            $b = New-ConnectorBody -Mode $c.Mode -Workloads @($c.Workloads) -ProductIds $d.ProductIds -TenantShort (Get-CiwProp $c 'TenantShort') -TenantName $d.TenantName `
                -DefaultDomain (Get-CiwProp $c 'DefaultDomain') -AppId $d.AppId -ServiceAccountUpn $d.ServiceAccountUpn -ServiceAccountPassword $d.ServiceAccountPwd `
                -Region $d.Region -AuthMethod $d.AuthMethod -PfxBytes $d.PfxBytes -PfxPassword $d.PfxPassword -PfxFileName $d.PfxFileName -ClientSecret $d.ClientSecret `
                -ConnectorId 0 -Name $cname -CertificateTransport $d.Transport -ExternalKey $mk
            $script:CiwPutCheck = [pscustomobject]@{ Id = 0; Create = $true; CertSent = $sendCert; ExpectedFileName = $expectFile; CertId = ''; CertFileName = '' }
        }

        # Ecriture. Une erreur (reseau, timeout, 5xx, isSuccess faux) n'est PAS decisive : l'ecriture a pu aboutir (POST/PUT non rejoues).
        $resp = $null; $respErr = ''
        try { $resp = Invoke-CiwRest -Method $method -Path $path -Body ($b | ConvertTo-Json -Depth 20 -Compress) }
        catch { $respErr = Get-CiwErrMsg $_ }
        if (-not $respErr -and (Get-CiwProp $resp 'isSuccess') -ne $true) { $respErr = "reponse Cloudiway sans succes : $(Get-CiwFailText $resp)" }
        if ($respErr) {
            # Diagnostic : forme du corps envoye, secrets et certificat MASQUES (ConvertTo-MaskedConnectorBody).
            try { Write-RunLog ('CIW corps envoye (masque) : ' + ((ConvertTo-MaskedConnectorBody $b) -replace '\s+', ' ')) } catch { }
        }

        if ($sendCert) {
            # Relecture decisive (B1 / M1 / M2 de la relecture v2.3).
            $v = Confirm-CiwConnectorWrite -Name $cname -Id $verifyId -ExpectedFileName $expectFile
            if ($v.Id -gt 0 -and $script:CiwPutCheck) { $script:CiwPutCheck.Id = $v.Id }
            Write-RunLog ("CIW relecture apres {0} : etat {1} (fichier relu '{2}', attendu '{3}') {4}" -f $method, $v.State, $v.FileName, $expectFile, $v.Detail)
            $respTxt = $(if ($respErr) { " Reponse du portail : $respErr" } else { '' })
            # Si un nouveau mot de passe de compte de service accompagnait le certificat, le portail a pu le prendre sans le certificat : le dire.
            $pwTxt = $(if ([bool](Get-CiwProp $c 'ServiceAccountResetPending')) { ' Le nouveau mot de passe du compte de service a pu etre transmis au connecteur sans etre applique au compte : relancer la meme commande resynchronise les deux (certificat et mot de passe).' } else { '' })
            switch ($v.State) {
                'Confirmed' {
                    if ($respErr) {
                        Add-CiwNotice "Cloudiway a repondu par une erreur lors de l'ecriture du connecteur, mais la relecture confirme le nouveau certificat (fichier $expectFile) : ecriture consideree comme reussie ($respErr)."
                    }
                    Set-CiwCtx 'ConnectorWriteOk' $true
                    return $true
                }
                'NotTaken' {
                    Set-CiwError ("le portail n'a pas pris en compte le nouveau certificat (nom de fichier relu '{0}', attendu '{1}' ; {2}). Connecteur NON confirme : aucun ancien certificat n'est retire et le mot de passe du compte de service n'est pas reinitialise. Relancer l'outil ; si cela persiste, controler le connecteur dans le portail Cloudiway.{3}{4}" -f $v.FileName, $expectFile, $v.Detail, $respTxt, $pwTxt)
                    return $false
                }
                default {
                    Set-CiwError ("ecriture du connecteur NON verifiable : {0}. Traitee comme NON confirmee : aucun ancien certificat n'est retire et le mot de passe du compte de service n'est pas reinitialise. Controler le connecteur dans le portail Cloudiway puis relancer l'outil.{1}{2}" -f $v.Detail, $respTxt, $pwTxt)
                    return $false
                }
            }
        }

        # Sans certificat envoye (secret client seul) : aucun fileName a verifier, le succes de la reponse fait foi.
        if (-not $respErr) {
            Set-CiwCtx 'ConnectorWriteOk' $true
            return $true
        }
        $script:CiwPutCheck = $null
        Set-CiwError ("erreur a l'application : {0}" -f $respErr)
        return $false
    } catch {
        $script:CiwPutCheck = $null
        $errText = Get-CiwErrMsg $_
        # Diagnostic : forme du corps envoye, secrets et certificat MASQUES (ConvertTo-MaskedConnectorBody).
        try { if ($b) { Write-RunLog ('CIW corps envoye (masque) : ' + ((ConvertTo-MaskedConnectorBody $b) -replace '\s+', ' ')) } } catch { }
        Set-CiwError ("erreur a l'application : {0}" -f $errText)
        return $false
    } finally {
        # Transport Path : le fichier temporaire est ecrase puis supprime juste apres l'appel.
        try { Remove-CiwTempFiles } catch { }
    }
}

function New-CloudiwayConnectorPlan {
    [CmdletBinding()]
    param()
    $ctx = $script:Ctx
    $area = 'Cloudiway'
    $name = [string](Get-CiwProp (Get-CiwProp $ctx 'Names') 'Connector')
    if (-not $name) { $name = [string](Get-CiwProp $ctx 'ConnectorName') }
    try {
        if ([bool](Get-CiwProp $ctx 'SkipCloudiway')) {
            [void](Add-PlanItem $area $name 'SKIP' 'Option -SkipCloudiway : aucune declaration du connecteur dans le portail Cloudiway.')
            return
        }
        if (-not $script:Ciw.Authenticated) {
            [void](Add-PlanItem $area $name 'BLOCKED' 'Acces Cloudiway non valide : relancer apres correction de l''identifiant, du mot de passe ou du projet, ou utiliser -SkipCloudiway.')
            return
        }
        $want = Get-CiwDesired
        if (@($want.Unknown).Count -gt 0) {
            $msg = "Produit(s) Cloudiway inconnu(s) pour : $(@($want.Unknown) -join ', '). Creer a la main un connecteur de test dans le portail avec toutes les charges cochees, lancer -Discover -ConnectorId <id> pour produire la table, puis relancer avec -ProductMapFile <fichier.json> ou -ProductIds <entiers>. Le cote tenant reste applique."
            [void](Add-PlanItem $area $name 'BLOCKED' $msg)
            return
        }
        if (@($want.ProductIds).Count -eq 0) {
            [void](Add-PlanItem $area $name 'BLOCKED' 'Aucun produit Cloudiway determine pour les charges choisies : utiliser -Discover, -ProductIds ou -ProductMapFile.')
            return
        }

        $ex = Get-CiwExisting $name
        if ($ex.State -eq 'Error') {
            $why = if ($ex.Error) { $ex.Error } else { $script:CiwLastError }
            [void](Add-PlanItem $area $name 'BLOCKED' "Lecture du connecteur impossible, creation refusee : $why")
            return
        }
        if ($ex.State -eq 'Multiple') {
            [void](Add-PlanItem $area $name 'BLOCKED' "$($ex.Error) dans le projet : aucun n'est modifie, choisir un nom unique ou regler les doublons dans le portail.")
            return
        }

        $apply = { Invoke-CiwApplyConnector }

        if ($ex.State -eq 'Absent') {
            [void](Add-PlanItem $area $name 'CREATE' ("Connecteur absent du projet {0} : sera cree (type 2, {1}, authentification {2}, produits [{3}], marqueur {4}...)." -f (Get-CiwProp $ctx 'ProjectId'), (Get-CiwProp $ctx 'Mode'), $want.AuthMethod, (@($want.ProductIds) -join ','), $script:CiwMarkerPrefix) $apply)
            return
        }

        $existing = $ex.Detail
        $eid = Get-CiwProp $existing 'id'
        $blk = Get-CiwBlockReason $existing $want
        if (-not $blk) { $blk = Get-CiwMissingAppReason $existing "$($want.AppId)" }
        if ($blk) {
            [void](Add-PlanItem $area $name 'BLOCKED' $blk)
            return
        }
        # B2 : adoption d'un connecteur fait a la main (sans marqueur, -AdoptExisting) : ce qui est REMPLACE est dit en clair ici,
        # et le script principal demande une confirmation supplementaire (sauf -Yes).
        $adopting = (-not (Test-CiwOwnedConnector $existing))
        Set-CiwCtx 'ConnectorAdoption' $adopting

        # Comparaison avec le DETAIL lu (M2/D3). Aucun secret exige : il n'est necessaire que s'il vient d'etre regenere.
        $diff = [System.Collections.Generic.List[string]]::new()
        $warn = ''
        $have = ConvertTo-CiwProductSet $existing
        $missing = @($want.ProductIds | Where-Object { $have -notcontains $_ })
        if ($missing.Count -gt 0) { $diff.Add("produits [$(@($have) -join ',')] -> union avec [$(@($want.ProductIds) -join ',')] (aucun retrait)") }
        if (-not (Test-CiwOwnedConnector $existing)) { $diff.Add("marqueur de suivi CIW1_<empreinte>_<date>.pfx a inscrire dans le nom du certificat (adoption ; externalKey ne peut plus etre modifie)") }
        $st = ConvertTo-CiwSettings $existing
        if ($st) {
            if (-not $want.AppId) { $diff.Add('application encore a creer : identifiant a inscrire') }
            elseif ((Get-CiwProp $st 'RestClientId') -ne $want.AppId) { $diff.Add('RestClientId different') }
            $dd = Get-CiwProp $ctx 'DefaultDomain'
            if ($dd -and (@(Get-CiwProp $st 'Domains') -notcontains $dd)) { $diff.Add('domaine par defaut absent') }
            if ($want.TenantName -and "$(Get-CiwProp $st 'TenantName')" -ine $want.TenantName) { $diff.Add('TenantName different') }
            if ($want.ServiceAccountUpn -and (Get-CiwProp $st 'MigrationAccount') -ne $want.ServiceAccountUpn) { $diff.Add('compte de service different') }
            if ($want.ServiceAccountUpn -and (Test-CiwPlanArea @('ServiceAccount'))) { $diff.Add('compte de service modifie dans ce passage : mot de passe a retransmettre si regenere') }
        } else {
            $warn = ' Avertissement : parametres (rawSettings) illisibles, conformite des parametres non verifiee.'
        }
        if (Test-CiwCertificateChange) {
            $mk = Get-ConnectorMarker $existing
            $diff.Add($(if ($mk) { "marqueur a renouveler (empreinte actuelle $($mk.Thumbprint), lue dans $($mk.Source)) : nouveaux identifiants a declarer" } else { 'nouveaux identifiants a declarer (marqueur absent ou ancien)' }))
            $diff.Add('ATTENTION : le certificat actuel du connecteur sera REMPLACE ; ne pas appliquer pendant que des jobs de migration sont actifs')
        } elseif ($diff.Count -gt 0) {
            $diff.Add('le certificat et les mots de passe du connecteur ne sont PAS renvoyes (ni modifies)')
        }
        if ($adopting -and $diff.Count -gt 0) {
            $diff.Insert(0, 'ADOPTION d''un connecteur fait a la main : son certificat, son RestClientId et le mot de passe de son compte de migration seront REMPLACES par ceux generes par l''outil (le certificat, le RestClientId, et le mot de passe quand un compte de service est gere par l''outil)')
        }
        # v2.4 (d) : le portail exige le certificat lors d'une mise a jour (HTTP 500 sinon, constate le 2026-10-31). Sans nouvel identifiant dans ce passage
        # (-KeepCredentials), aucun PUT n'est tente sur un connecteur qui possede un certificat.
        if ($diff.Count -gt 0 -and -not (Test-CiwCertificateChange) -and $null -ne (Get-CiwProp $existing 'connectorCertificate')) {
            [void](Add-PlanItem $area $name 'BLOCKED' ("Connecteur {0} : une mise a jour est necessaire ({1}) mais aucun nouvel identifiant n'est genere dans ce passage : {2}." -f $eid, ($diff -join ' ; '), $script:CiwNeedCertMsg))
            return
        }
        if ($diff.Count -gt 0) {
            [void](Add-PlanItem $area $name 'UPDATE' ("Connecteur {0} existant, ecarts : {1}.{2}" -f $eid, ($diff -join ' ; '), $warn) $apply)
        } else {
            [void](Add-PlanItem $area $name 'OK' ("Connecteur {0} conforme (produits [{1}])." -f $eid, (@($have) -join ',') + $warn))
        }
    } catch {
        [void](Add-PlanItem $area $name 'BLOCKED' ("Erreur lors de la preparation du plan Cloudiway : {0}" -f (Get-CiwErrMsg $_)))
    }
}

# --- Decouverte ---

function Invoke-CloudiwayDiscover {
    [CmdletBinding()]
    param([int]$ConnectorId = 0)
    try {
        if ($ConnectorId -le 0) {
            $r = Invoke-CiwRest -Method GET -Path '/Connectors'
            $rows = @(Get-CiwData $r) | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject]@{ Id = Get-CiwProp $_ 'id'; Nom = Get-CiwProp $_ 'name'; ConnectorTypeId = Get-CiwProp $_ 'connectorTypeId'; IsTarget = Get-CiwProp $_ 'isTarget'; RawProductList = Get-CiwProp $_ 'rawProductList' }
            }
            Write-Host ''
            Write-Host "Connecteurs du projet $($script:Ciw.ProjectId) : $(@($rows).Count)"
            if (@($rows).Count -gt 0) { $rows | Format-Table -AutoSize | Out-String | Write-Host }
            Write-RunLog "CIW decouverte : liste de $(@($rows).Count) connecteur(s)"
            return @($rows)
        }
        $r = Invoke-CiwRest -Method GET -Path "/Connectors/$ConnectorId"
        $d = Get-CiwData $r
        if ($null -eq $d) { Write-Host "Connecteur $ConnectorId introuvable ou reponse vide."; return $null }
        # rawSettings est une chaine JSON : on la deplie pour que le masquage s'applique a ses cles.
        $copy = [ordered]@{}
        if ($d -is [System.Collections.IDictionary]) { foreach ($k in $d.Keys) { $copy[$k] = $d[$k] } }
        else { foreach ($p in $d.PSObject.Properties) { $copy[$p.Name] = $p.Value } }
        foreach ($k in @($copy.Keys)) {
            # m1 : si rawSettings n'est pas du JSON, la chaine brute n'est jamais ecrite.
            if ("$k" -ieq 'rawSettings' -and $copy[$k] -is [string]) { try { $copy[$k] = ($copy[$k] | ConvertFrom-Json -ErrorAction Stop) } catch { $copy[$k] = '***MASQUE***' } }
        }
        $note = 'Mode d''emploi : creer a la main dans le portail un connecteur de test avec TOUTES les charges cochees, puis lire ici rawProductList (liste des produits) et rawSettings (forme exacte des parametres). Pour fabriquer la table des produits, ecrire un fichier JSON { "Mail": 5, "Fichiers": 6, ... } (un entier par charge : Mail, Archive, OneDrive, SharePoint, Teams, GalSync, Intune) et le passer avec -ProductMapFile. Les valeurs sensibles sont masquees.'
        $doc = [ordered]@{ _note = $note; connecteur = $copy }
        $file = if ($script:Ctx -and (Get-CiwProp $script:Ctx 'Out')) { Join-Path (Get-CiwProp $script:Ctx 'Out') "decouverte-$ConnectorId.json" } else { Join-Path (Get-Location).Path "decouverte-$ConnectorId.json" }
        $json = ConvertTo-MaskedJson $doc 10 -KeepKeys @('externalKey')   # externalKey = marqueur CIW1|empreinte|date, lisible et non secret
        Set-Content -LiteralPath $file -Value $json -Encoding utf8
        Write-Host "Decouverte ecrite : $file"
        Write-RunLog "CIW decouverte : connecteur $ConnectorId ecrit dans $file"
        return $file
    } catch {
        Write-Host ("Decouverte impossible : {0}" -f (Get-CiwErrMsg $_))
        Write-RunLog ("CIW decouverte en erreur : {0}" -f (Get-CiwErrMsg $_))
        return $null
    }
}

# --- Conformite ---

function Test-CloudiwayCompliance {
    [CmdletBinding()]
    param()
    $out = [System.Collections.Generic.List[object]]::new()
    $ctx = $script:Ctx
    $name = [string](Get-CiwProp (Get-CiwProp $ctx 'Names') 'Connector')
    if (-not $name) { $name = [string](Get-CiwProp $ctx 'ConnectorName') }
    try {
        if ([bool](Get-CiwProp $ctx 'SkipCloudiway')) { return $out }
        $cur = Get-CloudiwayConnector -Name $name -Detail
        if (-not $cur) {
            $d = if ($script:CiwLastError) { "Lecture impossible : $($script:CiwLastError)" } else { 'Connecteur introuvable dans le projet.' }
            $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : existence'; Status = 'KO'; Detail = $d })
            return $out
        }
        $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : existence'; Status = 'OK'; Detail = "Identifiant $(Get-CiwProp $cur 'id')." })
        $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : nom'; Status = $(if ((Get-CiwProp $cur 'name') -ieq $name) { 'OK' } else { 'KO' }); Detail = "$(Get-CiwProp $cur 'name')" })
        $isT = Get-CiwProp $cur 'isTarget'
        $wantT = ("$(Get-CiwProp $ctx 'Mode')" -eq 'Target')
        $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : sens'; Status = $(if ($null -ne $isT -and [bool]$isT -eq $wantT) { 'OK' } else { 'KO' }); Detail = "isTarget=$isT, attendu=$wantT" })
        $mk = Get-ConnectorMarker $cur
        $owned = Test-CiwOwnedConnector $cur
        $pc = $script:CiwPutCheck
        $pcHere = [bool]($pc -and "$($pc.Id)" -eq "$(Get-CiwProp $cur 'id')")
        $fnNow = "$(Get-CiwProp (Get-CiwProp $cur 'connectorCertificate') 'fileName')"
        if ($pcHere -and $pc.CertSent -and $pc.ExpectedFileName) {
            # v2.4 : le marqueur de suivi est le nom de fichier du certificat ; apres une ecriture de ce passage il doit etre celui envoye.
            $mkSt = $(if (-not $fnNow) { 'WARN' } elseif ($fnNow -ceq $pc.ExpectedFileName) { 'OK' } else { 'KO' })
            $mkDt = $(if (-not $fnNow) { 'nom de fichier du certificat non lisible : marqueur NON verifiable' } elseif ($mkSt -eq 'OK') { "marqueur lu dans le nom du certificat : empreinte $($mk.Thumbprint), expiration $($mk.NotAfter.ToString('yyyy-MM-dd'))" } else { "marqueur du nom du certificat : '$fnNow' (attendu '$($pc.ExpectedFileName)')" })
            $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : marqueur'; Status = $mkSt; Detail = $mkDt })
        } else {
            $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : marqueur'; Status = $(if ($owned) { 'OK' } else { 'KO' }); Detail = $(if ($mk) { "empreinte $($mk.Thumbprint), expiration $($mk.NotAfter.ToString('yyyy-MM-dd')) (lu dans $($mk.Source))" } elseif ($owned) { 'ancienne marque (V1)' } else { 'marqueur absent' }) })
        }
        $want = Get-CiwDesired
        $have = ConvertTo-CiwProductSet $cur
        if (@($want.Unknown).Count -gt 0) {
            $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : produits'; Status = 'KO'; Detail = "Produit(s) inconnu(s) : $(@($want.Unknown) -join ', ')" })
        } else {
            $ok = (@($want.ProductIds | Where-Object { $have -notcontains $_ }).Count -eq 0)   # union : les produits en plus sont tolerees
            $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : produits'; Status = $(if ($ok) { 'OK' } else { 'KO' }); Detail = "present [$(@($have) -join ',')], attendu (au moins) [$(@($want.ProductIds) -join ',')]" })
        }
        # B1 : controle post-PUT par GET. Le comportement exact du PUT (cles omises, secrets masques a la lecture) est INCONNU : a valider sur le
        # projet de test. Ce qui ne peut pas etre verifie est signale (WARN), jamais passe sous silence.
        if ($pcHere) {
            $stNow = ConvertTo-CiwSettings $cur
            if ($pc.Create) {
                # creation : seul le certificat est controle ici (parametres deja relus par les lignes precedentes)
            } elseif (-not $stNow) {
                $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : verification apres mise a jour'; Status = 'WARN'; Detail = 'parametres (rawSettings) illisibles apres le PUT : compte de migration et RestClientId NON verifiables ; controler le connecteur dans le portail' })
            } else {
                if ($pc.ExpectedAccount) {
                    $accNow = "$(Get-CiwProp $stNow 'MigrationAccount')"
                    $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : compte de migration'; Status = $(if ($accNow -ieq $pc.ExpectedAccount) { 'OK' } else { 'KO' }); Detail = $(if ($accNow -ieq $pc.ExpectedAccount) { 'compte de migration conforme apres la mise a jour' } else { "compte de migration apres la mise a jour : '$accNow' (attendu '$($pc.ExpectedAccount)')" }) })
                }
                if ($pc.ExpectedClientId) {
                    $rcNow = "$(Get-CiwProp $stNow 'RestClientId')"
                    $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : RestClientId'; Status = $(if ($rcNow -ieq $pc.ExpectedClientId) { 'OK' } else { 'KO' }); Detail = $(if ($rcNow -ieq $pc.ExpectedClientId) { 'RestClientId conforme apres la mise a jour' } else { "RestClientId apres la mise a jour : '$rcNow' (attendu '$($pc.ExpectedClientId)')" }) })
                }
            }
            $ccNow = Get-CiwProp $cur 'connectorCertificate'
            $idNow = "$(Get-CiwProp $ccNow 'id')"; $fnNow = "$(Get-CiwProp $ccNow 'fileName')"
            if ($pc.CertSent) {
                # v2.4 : le nom de fichier relu doit etre celui envoye dans ce passage (le portail remplace le certificat sur place).
                if (-not $fnNow) {
                    $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : certificat'; Status = 'WARN'; Detail = 'nom de fichier du certificat non lisible apres l''ecriture : prise en compte du nouveau certificat NON verifiable ; tester la connexion du connecteur dans le portail' })
                } elseif ($fnNow -ceq $pc.ExpectedFileName) {
                    $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : certificat'; Status = 'OK'; Detail = "le portail porte le certificat envoye (nom de fichier $fnNow)" })
                } else {
                    $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : certificat'; Status = 'KO'; Detail = "le portail n'a pas pris en compte le nouveau certificat : nom de fichier relu '$fnNow', attendu '$($pc.ExpectedFileName)'" })
                }
            } elseif ($pc.Create) {
                # creation sans certificat (secret client seul) : rien a comparer
            } elseif (-not $pc.CertId -and -not $pc.CertFileName -and -not $idNow -and -not $fnNow) {
                $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : certificat inchange'; Status = 'WARN'; Detail = 'identifiant et nom du certificat non lisibles (avant comme apres) : conservation du certificat NON verifiable ; tester la connexion du connecteur dans le portail' })
            } else {
                $same = ($idNow -eq $pc.CertId -and $fnNow -eq $pc.CertFileName)
                $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway : certificat inchange'; Status = $(if ($same) { 'OK' } else { 'KO' }); Detail = $(if ($same) { 'certificat (id, nom de fichier) inchange apres la mise a jour' } else { "certificat modifie ou efface par le PUT : avant id='$($pc.CertId)' fichier='$($pc.CertFileName)', apres id='$idNow' fichier='$fnNow'" }) })
            }
        }
    } catch {
        $out.Add([pscustomobject]@{ Name = 'Connecteur Cloudiway'; Status = 'KO'; Detail = (Get-CiwErrMsg $_) })
    }
    return $out
}
