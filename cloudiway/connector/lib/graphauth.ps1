# graphauth.ps1 - connexion Microsoft Graph par code d'appareil (flux OAuth2 "device code", appels REST directs).
# Raison d'etre (constate le 2026-10-31) : Connect-MgGraph -UseDeviceCode n'affichait aucun code et ouvrait le navigateur par defaut
# avec la session en cours. Ce flux affiche lui-meme le code et l'adresse, puis ne depend plus du module pour l'authentification.
# Ne contient AUCUN secret ; le jeton obtenu reste en memoire (transmis a Connect-MgGraph -AccessToken) et n'est ni affiche ni journalise.

# Client public Microsoft "Microsoft Graph Command Line Tools" : le meme que celui utilise par Connect-MgGraph.
$script:GraphPsClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

# Revendications (claims) d'un jeton JWT, sans verification de signature (lecture locale du jeton que l'on vient de recevoir de Microsoft).
function ConvertFrom-JwtPayload([string]$Jwt) {
    try {
        $p = ("$Jwt" -split '\.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json)
    }
    catch { return $null }
}

# Compte (UPN) porte par un jeton Graph : upn, a defaut preferred_username, a defaut unique_name.
function Get-JwtAccount($Claims) {
    if (-not $Claims) { return '' }
    foreach ($n in 'upn', 'preferred_username', 'unique_name') {
        $v = $Claims.PSObject.Properties[$n]
        if ($v -and "$($v.Value)") { return "$($v.Value)" }
    }
    return ''
}

# Expiration (claim exp, secondes epoch) d'un jeton : [datetime] UTC, ou $null si absente / illisible.
function Get-JwtExpiry($Claims) {
    if (-not $Claims) { return $null }
    $v = $Claims.PSObject.Properties['exp']
    if (-not $v) { return $null }
    $s = 0L
    if (-not [long]::TryParse("$($v.Value)", [ref]$s) -or $s -le 0) { return $null }
    try { return [DateTimeOffset]::FromUnixTimeSeconds($s).UtcDateTime } catch { return $null }
}

# Flux device code. Retourne le jeton d'acces (chaine) ; leve une exception au texte clair en cas d'echec, de refus ou d'expiration.
function Get-DeviceCodeToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string[]]$Scopes,
        [int]$TimeoutSec = 900
    )
    $base = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
    $form = 'application/x-www-form-urlencoded'
    $dc = Invoke-RestMethod -Method POST -Uri "$base/devicecode" -ContentType $form -ErrorAction Stop `
        -Body @{ client_id = $script:GraphPsClientId; scope = (@($Scopes) -join ' ') }
    if (-not $dc.device_code -or -not $dc.user_code) { throw 'Microsoft n''a pas renvoye de code d''appareil.' }
    $uri = if ($dc.verification_uri) { "$($dc.verification_uri)" } else { 'https://microsoft.com/devicelogin' }
    Write-Host ''
    Write-Host '  ==================== CONNEXION PAR CODE D''APPAREIL ====================' -ForegroundColor Yellow
    Write-Host "   1. Ouvrir cette adresse dans un navigateur (navigation privee conseillee) :  $uri" -ForegroundColor Yellow
    Write-Host "   2. Saisir ce code :  $($dc.user_code)" -ForegroundColor Yellow
    Write-Host '   3. Se connecter avec le compte Administrateur general du tenant a configurer.' -ForegroundColor Yellow
    Write-Host '  =========================================================================' -ForegroundColor Yellow
    Write-Host ''
    $interval = [Math]::Max(2, [int]$dc.interval)
    $life = if ([int]$dc.expires_in -gt 0) { [int]$dc.expires_in } else { $TimeoutSec }
    $deadline = (Get-Date).AddSeconds([Math]::Min($TimeoutSec, $life))
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $t = Invoke-RestMethod -Method POST -Uri "$base/token" -ContentType $form -ErrorAction Stop `
                -Body @{ grant_type = 'urn:ietf:params:oauth:grant-type:device_code'; client_id = $script:GraphPsClientId; device_code = $dc.device_code }
            if ($t.access_token) { return [string]$t.access_token }
            throw 'Microsoft a repondu sans jeton d''acces.'
        }
        catch {
            $err = ''; $desc = ''
            try { $j = "$($_.ErrorDetails.Message)" | ConvertFrom-Json -ErrorAction Stop; $err = "$($j.error)"; $desc = "$($j.error_description)" } catch { }
            if ($err -eq 'authorization_pending') { continue }
            if ($err -eq 'slow_down') { $interval += 5; continue }
            if ($err) {
                $d1 = ($desc -split "`r?`n")[0]
                if ($err -in 'authorization_declined', 'access_denied') { throw "connexion refusee dans la page de connexion Microsoft. $d1" }
                if ($err -eq 'expired_token') { throw 'le code d''appareil a expire avant la connexion : relancer la commande.' }
                throw "$err : $d1"
            }
            throw
        }
    }
    throw 'delai depasse : le code d''appareil n''a pas ete saisi a temps. Relancer la commande.'
}
