# common.ps1 - contexte, journal, plan, appels Graph et utilitaires. Dot-sourcee par le script principal.
# Ne contient AUCUN DELETE : le package ne supprime rien.

$script:AppName = '3SR - Connecteurs Cloudiway'
$script:AppVersion = '2.4'
$script:AppDate = '31/10/2026'
$script:AppContact = 'votre contact 3SR'
$script:Plan = [System.Collections.Generic.List[object]]::new()
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:SecretPatterns = 'secret|password|passwd|pat$|^pat|token|key|certificatefile|authorization'

# Construit un SecureString caractere par caractere (le jeton vient de Microsoft, il n'est jamais saisi ni ecrit).
function New-SecureStringFromText([string]$Text) {
    $s = [System.Security.SecureString]::new()
    foreach ($ch in $Text.ToCharArray()) { $s.AppendChar($ch) }
    $s.MakeReadOnly()
    return $s
}

function Write-RunLog([string]$Msg) {
    # Ecrit dans run.log (jamais de secret : l'appelant ne doit pas passer de valeur sensible).
    try {
        if ($script:Ctx -and $script:Ctx.Out -and (Test-Path -LiteralPath $script:Ctx.Out)) {
            Add-Content -LiteralPath (Join-Path $script:Ctx.Out 'run.log') -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Msg) -Encoding utf8
        }
    } catch { }
}

# Ajoute une action au plan. $Apply = scriptblock sans parametre qui realise l'action et retourne $true/$false (ou leve une exception).
function Add-PlanItem([string]$Area, [string]$Name, [ValidateSet('CREATE', 'UPDATE', 'OK', 'BLOCKED', 'SKIP')][string]$Action, [string]$Reason = '', [scriptblock]$Apply = $null) {
    $item = [pscustomobject]@{ Id = ($script:Plan.Count + 1); Area = $Area; Name = $Name; Action = $Action; Reason = $Reason; Apply = $Apply }
    $script:Plan.Add($item)
    Write-RunLog ("PLAN {0} / {1} : {2} {3}" -f $Area, $Name, $Action, $Reason)
    return $item
}

# Masque recursivement toute cle sensible d'un objet (hashtable ou PSObject) et retourne le JSON.
function ConvertTo-MaskedJson($Object, [int]$Depth = 8, [string[]]$KeepKeys = @()) {
    # $KeepKeys : noms de cles (exacts, sans casse) qui ne sont PAS secretes malgre leur nom (ex. externalKey, marqueur lisible CIW1|...).
    $mask = {
        param($o)
        if ($null -eq $o) { return $null }
        if ($o -is [string] -or $o -is [ValueType]) { return $o }
        if ($o -is [System.Collections.IDictionary]) {
            $h = [ordered]@{}
            foreach ($k in $o.Keys) { $h[$k] = if ("$k" -match $script:SecretPatterns -and @($KeepKeys | Where-Object { $_ -ieq "$k" }).Count -eq 0) { '***MASQUE***' } else { & $mask $o[$k] } }
            return $h
        }
        if ($o -is [System.Collections.IEnumerable]) { return @($o | ForEach-Object { & $mask $_ }) }
        $h = [ordered]@{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = if ($p.Name -match $script:SecretPatterns -and @($KeepKeys | Where-Object { $_ -ieq $p.Name }).Count -eq 0) { '***MASQUE***' } else { & $mask $p.Value } }
        return $h
    }
    (& $mask $Object) | ConvertTo-Json -Depth $Depth
}

# Mot de passe fort (24 caracteres, 4 classes), genere avec un generateur cryptographique.
function New-StrongPassword([int]$Length = 24) {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%&*+-=?@_')
    $all = ($sets -join '')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = { param($chars) $b = [byte[]]::new(4); $rng.GetBytes($b); $chars[[BitConverter]::ToUInt32($b, 0) % $chars.Length] }
    $out = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $out.Add((& $pick $s)) }
    while ($out.Count -lt $Length) { $out.Add((& $pick $all)) }
    for ($i = $out.Count - 1; $i -gt 0; $i--) {
        $b = [byte[]]::new(4); $rng.GetBytes($b); $j = [BitConverter]::ToUInt32($b, 0) % ($i + 1)
        $t = $out[$i]; $out[$i] = $out[$j]; $out[$j] = $t
    }
    $rng.Dispose()
    -join $out
}

# Mot de passe alphanumerique (A-Z a-z 0-9) : pour le PFX transmis a Cloudiway, dont le serveur peut mal supporter les symboles (constate 2026-10-31).
function New-AlnumPassword([int]$Length = 32) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $out = [System.Text.StringBuilder]::new()
    $b = [byte[]]::new(4)
    while ($out.Length -lt $Length) { $rng.GetBytes($b); [void]$out.Append($chars[[BitConverter]::ToUInt32($b, 0) % $chars.Length]) }
    $rng.Dispose()
    $out.ToString()
}

# Appels Graph. GET (pagination avec -All), POST et PATCH ; jamais de DELETE. Reessaie les GET sur 429/503/504 et les POST/PATCH sur 429 seulement, en respectant Retry-After.
function Invoke-GraphRaw([string]$Method, [string]$Path, $Body = $null, [string]$Version = 'v1.0', [switch]$All) {
    $uri = if ($Path -like 'https://*') { $Path } else { "https://graph.microsoft.com/$Version$Path" }
    $res = [System.Collections.Generic.List[object]]::new()
    $attempt = 0
    do {
        $params = @{ Method = $Method; Uri = $uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
        # ConsistencyLevel: eventual uniquement sur les LECTURES (m12) : jamais sur un POST / PATCH.
        if ($Method -eq 'GET') { $params['Headers'] = @{ ConsistencyLevel = 'eventual' } }
        if ($null -ne $Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress); $params['ContentType'] = 'application/json' }
        try {
            $r = Invoke-MgGraphRequest @params
        } catch {
            $code = Get-ErrCode $_
            # GET : rejeu sur 429/503/504. POST/PATCH : rejeu UNIQUEMENT sur 429 (requete non traitee) ; sur 5xx l'erreur remonte
            # (un 504 apres une creation reussie rejoue creerait un doublon ; l'idempotence du plan reprend au passage suivant).
            $retryable = if ($Method -eq 'GET') { $code -in 429, 503, 504 } else { $code -eq 429 }
            if ($retryable -and $attempt -lt 4) {
                $attempt++
                $wait = 2 * $attempt
                try { $ra = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds; if ($ra) { $wait = [Math]::Min(60, [int]$ra) } } catch { }
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
        if ($Method -ne 'GET') { return $r }
        if ($null -ne $r.value) { $r.value | ForEach-Object { $res.Add($_) } } else { return $r }
        $uri = if ($All) { $r.'@odata.nextLink' } else { $null }
    } while ($uri)
    return $res
}
function Invoke-GraphGet([string]$Path, [switch]$All, [string]$Version = 'v1.0') { Invoke-GraphRaw -Method GET -Path $Path -Version $Version -All:$All }
function Invoke-GraphPost([string]$Path, $Body, [string]$Version = 'v1.0') { Invoke-GraphRaw -Method POST -Path $Path -Body $Body -Version $Version }
function Invoke-GraphPatch([string]$Path, $Body, [string]$Version = 'v1.0') { Invoke-GraphRaw -Method PATCH -Path $Path -Body $Body -Version $Version }

# --- Erreurs : reprises du collecteur (verifiees en reel) ---

function Get-ErrCode($e) {
    $code = $null
    try { $sc = $e.Exception.Response.StatusCode; if ($null -ne $sc) { $code = [int]$sc } } catch { }
    if ($null -eq $code) { try { $sc = $e.Exception.StatusCode; if ($null -ne $sc) { $code = [int]$sc } } catch { } }
    if ($null -eq $code) { try { if ("$($e.Exception.Message)" -match 'status code[^:\d]*:?\s*(\d{3})\b') { $code = [int]$Matches[1] } } catch { } }
    if ($null -ne $code -and ($code -lt 100 -or $code -gt 599)) { $code = $null }
    return $code
}

function Get-ErrMsg($e) {
    $body = ''
    try { $body = "$($e.ErrorDetails.Message)" } catch { }
    $exMsg = ''
    try { $exMsg = "$($e.Exception.Message)" } catch { }
    if (-not $exMsg -and -not $body) { try { $exMsg = "$e" } catch { } }
    $code = Get-ErrCode $e
    $m = ''
    if ($body.Trim()) {
        try {
            $j = $body | ConvertFrom-Json -ErrorAction Stop
            $jm = $null
            if ($j.error -is [string]) { $jm = $j.error } else { $jm = $j.error.message }
            if (-not $jm) { $jm = $j.message }
            if (-not $jm) { $jm = $j.error_description }
            if ($jm) { $m = "$jm" }
        } catch { }
        if (-not $m) {
            $flat = $body -replace '\s+', ' '
            if ($flat -match '\\?"message\\?"\s*:\s*\\?"([^"\\]+)') { $m = $Matches[1] }
            elseif ($flat.Trim() -match '^[\{\}\[\]\s]*$') { $m = '' }
            elseif ($flat -match '^\s*\{') { $m = 'Reponse HTTP d''erreur sans message (droit ou licence manquant probable) : ' + $flat }
            else { $m = $flat }
        }
    }
    if (-not $m) {
        # Corps vide : repli sur le message de l'exception (libelle HTTP lisible quand c'est le texte standard de .NET)
        $m = $exMsg -replace '\s+', ' '
        if ($m -match 'status code does not indicate success:\s*\d{3}\s*\(([^)]+)\)') { $m = $Matches[1] + ' (reponse sans detail)' }
    }
    $m = ($m -replace '\s+', ' ').Trim()
    if ($m.Length -lt 20) {
        $tn = ''
        try { $tn = $e.Exception.GetType().Name } catch { }
        if ($tn -and $m -notmatch [regex]::Escape($tn)) { $m = if ($m) { "$m [$tn]" } else { "erreur sans message [$tn]" } }
    }
    if ($null -ne $code -and $m -notmatch '^HTTP \d{3}') { $m = "HTTP $code : $m" }
    $m.Substring(0, [Math]::Min(220, $m.Length))
}

# Conseil actionnable pour les codes d'erreur Microsoft Entra (AADSTS) les plus courants lors de la connexion de l'administrateur.
# Retourne '' si le message ne contient aucun code connu. Le texte du conseil ne contient jamais de secret.
function Get-AadstsHint([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $hints = [ordered]@{
        '65001' = 'AADSTS65001 : le consentement n''a pas ete donne pour l''application Microsoft Graph Command Line Tools. Se reconnecter avec un Administrateur general et ACCEPTER la fenetre de consentement (case "Consentement de la part de votre organisation" si elle est proposee).'
        '90094' = 'AADSTS90094 : le consentement administrateur est requis et le compte utilise n''est pas Administrateur general. Se connecter avec un Administrateur general (activer le role PIM avant), ou demander a un Administrateur general d''accorder le consentement.'
        '53003' = 'AADSTS53003 : l''acces est bloque par une strategie d''acces conditionnel (poste non conforme, localisation, application non autorisee...). Utiliser un poste ou un reseau autorise, ou demander a l''equipe securite d''autoriser cette connexion.'
        '50076' = 'AADSTS50076 : une authentification multifacteur (MFA) est exigee. Terminer la validation MFA dans la fenetre de connexion Microsoft (application d''authentification, SMS...), puis relancer.'
    }
    foreach ($k in $hints.Keys) { if ($Text -match "AADSTS$k\b") { return [string]$hints[$k] } }
    return ''
}

