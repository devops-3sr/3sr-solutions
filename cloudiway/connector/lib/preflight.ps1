# preflight.ps1 - prerequis du poste.
# Ne fait que RETOURNER des donnees (lignes { Name; Status; Detail; Impact }) : l'affichage est assure par l'appelant.
# Aucune ecriture sur un tenant ni sur Cloudiway. Seules ecritures : un fichier temporaire jetable dans le dossier de sortie (supprime
# aussitot), un appel PUBLIC sans authentification pour resoudre le domaine du tenant en GUID (metadonnee OIDC), et Install-Module / Install-PackageProvider / Set-PSRepository sur le poste, uniquement apres accord de l'utilisateur
# (ou -InstallMissingModules pour le module). Statut d'une ligne : OK | WARN | FAIL | SKIP.

function New-CheckRow([string]$Name, [string]$Status, [string]$Detail = '', [string]$Impact = '') {
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Impact = $Impact }
}

# Question O/N. Sans console interactive (entree redirigee), la reponse est NON : rien n'est jamais accepte par defaut.
function Confirm-Preflight([string]$Question) {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        $rep = Read-Host $Question
        return [bool]("$rep" -match '^(o|oui|y|yes)$')
    } catch { return $false }
}

# Proxy d'entreprise : les appels HTTP de la session s'authentifient aupres du proxy avec les identifiants Windows de l'utilisateur.
# Invoke-RestMethod / Invoke-WebRequest : -ProxyUseDefaultCredentials exige -Proxy (erreur sinon), donc pas de $PSDefaultParameterValues ;
# on regle le proxy par defaut de .NET (HttpClient.DefaultProxy), utilise par ces cmdlets quand aucun -Proxy n'est fourni. Ne leve jamais.
function Enable-ProxyDefaultCredentials {
    try { [System.Net.Http.HttpClient]::DefaultProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials } catch { }
    try { [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials } catch { }
}

# Dossier de sortie a risque ? Retourne le motif (texte) ou '' : dossier synchronise (OneDrive, Dropbox), Telechargements, partage reseau.
function Test-RiskyOutputFolder([string]$Path) {
    if (-not $Path) { return '' }
    try {
        $full = [System.IO.Path]::GetFullPath($Path, (Get-Location).ProviderPath)
        if ($full.StartsWith('\\') -or $full.StartsWith('//')) { return 'partage reseau (UNC)' }
        if ($full -match '(?i)[\\/]OneDrive[^\\/]*([\\/]|$)') { return 'dossier OneDrive (synchronise dans le cloud)' }
        if ($full -match '(?i)[\\/]Dropbox[^\\/]*([\\/]|$)') { return 'dossier Dropbox (synchronise dans le cloud)' }
        if ($full -match '(?i)[\\/](Downloads|T.l.chargements)([\\/]|$)') { return 'dossier Telechargements' }
        foreach ($ev in 'OneDrive', 'OneDriveCommercial', 'OneDriveConsumer') {
            $root = [Environment]::GetEnvironmentVariable($ev)
            if ($root -and $full.StartsWith($root.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { return 'dossier OneDrive (synchronise dans le cloud)' }
        }
        $pr = [System.IO.Path]::GetPathRoot($full)
        if ($pr -and $pr.Length -ge 2 -and $pr[1] -eq ':') {
            try { if (([System.IO.DriveInfo]::new($pr)).DriveType -eq [System.IO.DriveType]::Network) { return 'lecteur reseau' } } catch { }
        }
    } catch { }
    return ''
}

# Version la plus haute installee + version eventuellement deja chargee dans la session.
function Get-PreflightModuleState([string]$Name) {
    $inst = $null; $loaded = $null
    try {
        $m = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue | Sort-Object { [version]"$($_.Version)" } -Descending | Select-Object -First 1)
        if ($m.Count -gt 0 -and $m[0]) { $inst = [version]"$($m[0].Version)" }
    } catch { }
    try {
        $l = @(Get-Module -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($l.Count -gt 0 -and $l[0]) { $loaded = [version]"$($l[0].Version)" }
    } catch { }
    [pscustomobject]@{ Installed = $inst; Loaded = $loaded }
}

# Date du serveur (en-tete HTTP Date) d'une reponse, ou $null. Sert a detecter une horloge de poste decalee. Ne leve jamais.
function Get-ServerDateHeader($Response) {
    try {
        $h = $Response.Headers
        if ($null -eq $h) { return $null }
        $v = $h['Date']
        if ($null -eq $v) { return $null }
        $s = [string](@($v)[0])
        $dto = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { return $dto.UtcDateTime }
    } catch { }
    return $null
}

# Teste une URL HTTPS (HEAD, delai 5 s). State : Ok | Proxy | Cert | Down. Ne leve jamais ; ne lit ni n'ecrit aucun jeton.
function Get-HttpsReach([string]$Url, [int]$TimeoutSec = 5) {
    $via = ''
    try {
        $u = [uri]$Url
        $px = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($u)
        if ($px -and $px.Host -ne $u.Host) { $via = " (via proxy $($px.Host))" }
    } catch { }
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop
        if ($r -and [int]$r.StatusCode -eq 407) {
            return [pscustomobject]@{ State = 'Proxy'; Detail = "le proxy exige une authentification (HTTP 407)$via" }
        }
        return [pscustomobject]@{ State = 'Ok'; Detail = "joignable$via"; ServerDate = (Get-ServerDateHeader $r) }
    } catch {
        $e = $_
        $msg = "$($e.Exception.Message)"
        $code = $null
        try { if ($e.Exception.Response -and $e.Exception.Response.StatusCode) { $code = [int]$e.Exception.Response.StatusCode } } catch { }
        if ($null -eq $code -and $msg -match 'Proxy Authentication|\b407\b') { $code = 407 }
        if ($code -eq 407) { return [pscustomobject]@{ State = 'Proxy'; Detail = "le proxy exige une authentification (HTTP 407)$via" } }
        if ($null -ne $code) { return [pscustomobject]@{ State = 'Ok'; Detail = "joignable (reponse HTTP $code)$via" } }
        if ($msg -match 'certificate|certificat|SSL|TLS|trust|revocation|Authentication failed') {
            return [pscustomobject]@{ State = 'Cert'; Detail = "joignable mais certificat non reconnu (inspection TLS du reseau ou date du poste incorrecte ?)$via" }
        }
        if ($msg -match 'timed out|timeout|delai|canceled|annul') { return [pscustomobject]@{ State = 'Down'; Detail = "aucune reponse en $TimeoutSec s$via" } }
        if ($msg -match 'No such host|nodename|resolve|DNS|introuvable|name or service') { return [pscustomobject]@{ State = 'Down'; Detail = "nom de serveur introuvable (DNS)$via" } }
        $short = ($msg -replace '\s+', ' ')
        return [pscustomobject]@{ State = 'Down'; Detail = ("echec de connexion : " + $short.Substring(0, [Math]::Min(120, $short.Length)) + $via) }
    }
}

# Test local et jetable de generation d'un certificat auto-signe EN MEMOIRE (aucun magasin touche, aucun fichier ecrit). Retourne { Ok; Detail }.
function Test-CertificateCapability {
    $rsa = $null; $cert = $null
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=cloudiway-preflight', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays(1))
        $bytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, [guid]::NewGuid().ToString('N'))
        if ($bytes -and $bytes.Length -gt 0) { return [pscustomobject]@{ Ok = $true; Detail = 'certificat auto-signe RSA 2048 genere et exporte en memoire (test jetable)' } }
        return [pscustomobject]@{ Ok = $false; Detail = 'export PFX vide' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = ("$($_.Exception.Message)" -replace '\s+', ' ') }
    } finally {
        if ($cert) { try { $cert.Dispose() } catch { } }
        if ($rsa) { try { $rsa.Dispose() } catch { } }
    }
}

# --- Adresses et tenant (v2) ------------------------------------------------------------------------------

# Vrai si la valeur ressemble a une adresse e-mail / un identifiant de connexion (nom@contoso.com).
function Test-MailAddress([string]$Value) {
    return [bool](("" + $Value).Trim() -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

# Nature de la valeur -Tenant : 'Guid', 'Domain' ou '' (invalide).
function Get-TenantInputKind([string]$Value) {
    $v = ("" + $Value).Trim()
    if ($v -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return 'Guid' }
    if ($v -match '^(?=.{4,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$') { return 'Domain' }
    return ''
}

# Appel PUBLIC (sans authentification) a la metadonnee OIDC d'un domaine. Isole dans une fonction pour pouvoir etre remplace par un faux
# dans les tests. Leve une exception en cas d'echec.
function Invoke-OidcMetadata([string]$Domain, [int]$TimeoutSec = 8) {
    $url = "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration"
    return (Invoke-RestMethod -Uri $url -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop)
}

# Resout -Tenant en GUID. GUID fourni : retourne tel quel (aucun appel). Domaine : metadonnee OIDC publique, delai court.
# Retourne { Ok; TenantId; Domain; Kind; Detail }. Ne leve jamais.
function Resolve-TenantGuid([string]$Tenant, [int]$TimeoutSec = 8) {
    $t = ("" + $Tenant).Trim()
    $res = [pscustomobject]@{ Ok = $false; TenantId = ''; Domain = ''; Kind = ''; Detail = '' }
    $kind = Get-TenantInputKind $t
    $res.Kind = $kind
    if (-not $kind) { $res.Detail = "'$t' n'est ni un domaine (xxxx.onmicrosoft.com) ni un identifiant (GUID)."; return $res }
    if ($kind -eq 'Guid') { $res.Ok = $true; $res.TenantId = $t.ToLowerInvariant(); $res.Detail = 'identifiant fourni (aucune resolution necessaire)'; return $res }
    $res.Domain = $t.ToLowerInvariant()
    try {
        $m = Invoke-OidcMetadata -Domain $res.Domain -TimeoutSec $TimeoutSec
        $text = ''
        foreach ($n in 'issuer', 'token_endpoint', 'authorization_endpoint') {
            $v = $null
            try { $v = $m.$n } catch { }
            if ($v) { $text += " $v" }
        }
        if ($text -match 'login\.microsoftonline\.com/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/') {
            $res.Ok = $true; $res.TenantId = $Matches[1].ToLowerInvariant(); $res.Detail = "domaine $($res.Domain) resolu (metadonnee publique Microsoft)"
        } else {
            $res.Detail = "reponse Microsoft sans identifiant de tenant pour le domaine $($res.Domain)"
        }
    } catch {
        $msg = ("" + $_.Exception.Message) -replace '\s+', ' '
        $body = ''
        try { $body = "$($_.ErrorDetails.Message)" } catch { }
        $code = $null
        try { if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        if (($code -in 400, 404) -or ("$msg $body" -match 'AADSTS90002|AADSTS50034|not found|introuvable|\b40[04]\b')) {
            $res.Detail = "le domaine '$($res.Domain)' est inconnu de Microsoft Entra : verifier l'orthographe (ex. societe.onmicrosoft.com) ou fournir directement l'identifiant (GUID) du tenant."
        } elseif ($msg -match 'timed out|timeout|delai|canceled|annul') {
            $res.Detail = "aucune reponse de login.microsoftonline.com en $TimeoutSec s : verifier la connexion Internet et le proxy."
        } else {
            $res.Detail = "resolution impossible : " + $msg.Substring(0, [Math]::Min(140, $msg.Length))
        }
    }
    return $res
}

function Invoke-LocalPreflight {
    [CmdletBinding()]
    param(
        [switch]$NeedGraph,                 # connexion au tenant prevue : module Graph, hotes Microsoft, certificat
        [switch]$NeedExchange,              # v2.2 : Charge Mail -> module ExchangeOnlineManagement (avertissement, jamais bloquant)
        [switch]$InstallMissingModules,
        [string]$OutBase,                   # dossier de sortie (defaut : $script:Ctx.OutBase)
        [switch]$SkipCloudiway,             # pas d'appel a l'API Cloudiway : hote non teste
        [string]$Tenant,                    # v2 : domaine ou GUID du tenant a configurer (resolu en GUID, appel public sans authentification)
        [string]$Admin365,                  # v2 : compte administrateur Microsoft 365 attendu (adresse valide)
        [string]$CloudiwayLogin             # v2 : identifiant Cloudiway du DSI (adresse valide)
    )
    $WarningPreference = 'SilentlyContinue'   # aucun avertissement brut (Install-Module, NuGet...) : nos propres messages seulement
    $rows = [System.Collections.Generic.List[object]]::new()
    $needsAdmin = $false
    if (-not $OutBase -and $script:Ctx) { try { $OutBase = [string]$script:Ctx.OutBase } catch { } }

    # --- 1. PowerShell ---
    try {
        $v = $PSVersionTable.PSVersion
        if ($v -lt [version]'7.2') {
            $rows.Add((New-CheckRow 'PowerShell' 'FAIL' "version $v : PowerShell 7.2 minimum" 'L''outil ne peut pas s''executer. Installer ou mettre a jour PowerShell 7 (winget install --id Microsoft.PowerShell -e) puis relancer avec pwsh.'))
        } elseif ($v -lt [version]'7.4') {
            $rows.Add((New-CheckRow 'PowerShell' 'WARN' "version $v (7.4 recommandee)" 'Fonctionne, mais une mise a jour de PowerShell 7 est conseillee.'))
        } else {
            $rows.Add((New-CheckRow 'PowerShell' 'OK' "version $v"))
        }
    } catch { $rows.Add((New-CheckRow 'PowerShell' 'WARN' 'version non determinable')) }

    # --- 2. Systeme ---
    try {
        $isWin = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { [bool]$IsWindows } else { $true }
        if ($isWin) {
            $rows.Add((New-CheckRow 'Systeme' 'OK' ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)))
        } else {
            $rows.Add((New-CheckRow 'Systeme' 'WARN' ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) 'Outil valide sous Windows uniquement : la restriction des droits des fichiers sensibles (ACL) n''est pas appliquee ailleurs.'))
        }
    } catch { $rows.Add((New-CheckRow 'Systeme' 'WARN' 'systeme non determinable')) }

    # --- 3. Dossier de sortie : ecriture + espace ---
    if ($OutBase) {
        try {
            $full = [System.IO.Path]::GetFullPath($OutBase, (Get-Location).ProviderPath)
            $probe = $full
            while ($probe -and -not (Test-Path -LiteralPath $probe -PathType Container)) {
                $parent = Split-Path -Parent $probe
                if (-not $parent -or $parent -eq $probe) { $probe = $null; break }
                $probe = $parent
            }
            if (-not $probe) {
                $rows.Add((New-CheckRow 'Dossier de sortie' 'FAIL' "aucun dossier parent existant pour '$full'" 'Aucun resultat ne pourra etre ecrit. Choisir un autre emplacement avec -OutDir.'))
            } else {
                $tmp = Join-Path $probe (".cwtest-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
                try {
                    [System.IO.File]::WriteAllText($tmp, 'x')
                    $rows.Add((New-CheckRow 'Dossier de sortie' 'OK' "ecriture possible ($full)"))
                } catch {
                    $rows.Add((New-CheckRow 'Dossier de sortie' 'FAIL' "ecriture impossible dans '$probe'" 'Aucun resultat ne pourra etre enregistre. Choisir un dossier accessible en ecriture avec -OutDir (ex. le Bureau).'))
                } finally {
                    try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } } catch { }
                }
                $root = [System.IO.Path]::GetPathRoot($full)
                if (-not $root -or $root.StartsWith('\\')) {
                    $rows.Add((New-CheckRow 'Espace disque' 'SKIP' 'chemin reseau : espace non verifiable'))
                } else {
                    try {
                        $freeMB = [math]::Floor(([System.IO.DriveInfo]::new($root)).AvailableFreeSpace / 1MB)
                        if ($freeMB -lt 50) {
                            $rows.Add((New-CheckRow 'Espace disque' 'FAIL' "$freeMB Mo libres sur $root (50 Mo requis)" 'Les fichiers de resultat (rapport, journal) risquent de ne pas pouvoir etre ecrits. Liberer de l''espace ou choisir un autre disque (-OutDir).'))
                        } else {
                            $rows.Add((New-CheckRow 'Espace disque' 'OK' "$freeMB Mo libres sur $root"))
                        }
                    } catch { $rows.Add((New-CheckRow 'Espace disque' 'SKIP' 'non verifiable')) }
                }
            }
        } catch {
            $rows.Add((New-CheckRow 'Dossier de sortie' 'FAIL' "chemin invalide : $($_.Exception.Message)" 'Indiquer un chemin valide avec -OutDir.'))
        }
    } else {
        $rows.Add((New-CheckRow 'Dossier de sortie' 'SKIP' 'non precise'))
        $rows.Add((New-CheckRow 'Espace disque' 'SKIP' 'non precise'))
    }

    # --- 3 bis. Dossier de sortie synchronise / partage : le rapport et le journal y seraient copies (aucun secret n'est ecrit en v2) ---
    if ($OutBase) {
        $risk = Test-RiskyOutputFolder $OutBase
        if ($risk) {
            $rows.Add((New-CheckRow 'Dossier de sortie sensible' 'WARN' $risk 'Le rapport et le journal (aucun secret, mais des noms et identifiants du tenant) risquent d''etre synchronises dans le cloud ou vus d''autres postes. Choisir un dossier local non synchronise avec -OutDir (ex. %LOCALAPPDATA%\CloudiwayConnector).'))
        }
    }

    # --- 3 ter. Proxy d'entreprise (detection ; identifiants Windows utilises automatiquement) ---
    if ($NeedGraph -or -not $SkipCloudiway) {
        Enable-ProxyDefaultCredentials
        $pxFound = [System.Collections.Generic.List[string]]::new()
        try {
            foreach ($h in 'login.microsoftonline.com', 'graph.microsoft.com', 'api-production.cloudiway.com') {
                $u = [uri]("https://$h/")
                $px = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($u)
                if ($px -and $px.Host -ne $u.Host -and -not $pxFound.Contains($px.Authority)) { $pxFound.Add($px.Authority) }
            }
        } catch { }
        $envPx = @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY') | Where-Object { [Environment]::GetEnvironmentVariable($_) } | Select-Object -First 1
        if ($pxFound.Count -gt 0) {
            $rows.Add((New-CheckRow 'Proxy' 'OK' ("proxy detecte : {0} (identifiants Windows de l'utilisateur utilises)" -f ($pxFound -join ', '))))
        } elseif ($envPx) {
            $rows.Add((New-CheckRow 'Proxy' 'OK' "variable d'environnement $envPx definie (identifiants Windows de l'utilisateur utilises)"))
        } else {
            $rows.Add((New-CheckRow 'Proxy' 'OK' 'aucun proxy detecte (connexion directe)'))
        }
    }

    # --- 4. Reseau HTTPS (delai 5 s) ---
    $hosts = @(
        @{ Host = 'login.microsoftonline.com'; Need = [bool]$NeedGraph; Impact = 'Aucune connexion au tenant Microsoft 365 possible depuis ce poste.' }
        @{ Host = 'graph.microsoft.com'; Need = [bool]$NeedGraph; Impact = 'Le tenant ne peut pas etre lu ni configure (Microsoft Graph).' }
        @{ Host = 'api-production.cloudiway.com'; Need = (-not $SkipCloudiway); Impact = 'Le connecteur ne peut pas etre declare dans le projet Cloudiway. Pour preparer le tenant seulement : -SkipCloudiway.' }
    )
    $skewMin = $null
    foreach ($h in $hosts) {
        $nm = "Reseau $($h.Host)"
        if (-not $h.Need) { $rows.Add((New-CheckRow $nm 'SKIP' 'non necessaire pour ce lancement')); continue }
        $r = Get-HttpsReach ("https://{0}/" -f $h.Host)
        if ($r.State -eq 'Ok' -and $r.ServerDate -is [datetime] -and $null -eq $skewMin) { $skewMin = ([datetime]::UtcNow - $r.ServerDate).TotalMinutes }
        switch ($r.State) {
            'Ok' { $rows.Add((New-CheckRow $nm 'OK' $r.Detail)) }
            'Cert' { $rows.Add((New-CheckRow $nm 'WARN' $r.Detail 'La connexion peut etre refusee si le reseau intercepte le trafic chiffre. Tester depuis un autre reseau ou demander a l''equipe reseau d''autoriser ce domaine.')) }
            'Proxy' { $rows.Add((New-CheckRow $nm 'FAIL' $r.Detail ("Un proxy est a configurer ou a authentifier. " + $h.Impact))) }
            default { $rows.Add((New-CheckRow $nm 'FAIL' $r.Detail ("Verifier la connexion Internet, le pare-feu et le proxy (HTTPS 443 vers $($h.Host)). " + $h.Impact))) }
        }
    }

    # --- 4 ter. Horloge du poste (comparee a la date des serveurs ; le certificat est deja antidate de 5 minutes) ---
    if ($null -ne $skewMin) {
        if ([Math]::Abs($skewMin) -gt 5) {
            $rows.Add((New-CheckRow 'Horloge du poste' 'WARN' ("decalee d'environ {0} minute(s) par rapport aux serveurs" -f [Math]::Round([Math]::Abs($skewMin))) 'Une horloge decalee de plus de quelques minutes provoque des echecs de connexion Microsoft (jetons refuses) et rend le certificat genere invalide ou pas encore valide. Resynchroniser l''heure Windows (Parametres > Heure et langue > Synchroniser) puis relancer.'))
        } else {
            $rows.Add((New-CheckRow 'Horloge du poste' 'OK' 'synchronisee avec les serveurs'))
        }
    }

    # --- 4 bis. Adresses saisies et tenant (v2) ---
    $tenantId = ''; $tenantDomain = ''
    if ($NeedGraph -and $Admin365) {
        if (Test-MailAddress $Admin365) { $rows.Add((New-CheckRow 'Compte Microsoft 365' 'OK' "adresse valide : $Admin365")) }
        else { $rows.Add((New-CheckRow 'Compte Microsoft 365' 'FAIL' "'$Admin365' n'est pas une adresse valide" 'Indiquer l''identifiant de connexion du compte administrateur sous la forme nom@contoso.com (-Admin365).')) }
    }
    if (-not $SkipCloudiway -and $CloudiwayLogin) {
        if (Test-MailAddress $CloudiwayLogin) { $rows.Add((New-CheckRow 'Compte Cloudiway' 'OK' "adresse valide : $CloudiwayLogin")) }
        else { $rows.Add((New-CheckRow 'Compte Cloudiway' 'FAIL' "'$CloudiwayLogin' n'est pas une adresse valide" 'Indiquer l''adresse e-mail utilisee pour l''invitation Cloudiway (-Cloudiway).')) }
    }
    if ($NeedGraph -and $Tenant) {
        $rt = Resolve-TenantGuid $Tenant
        if ($rt.Ok) {
            $tenantId = $rt.TenantId; $tenantDomain = $rt.Domain
            $rows.Add((New-CheckRow 'Tenant du client' 'OK' ("{0} (GUID {1})" -f $(if ($rt.Domain) { $rt.Domain } else { 'identifiant fourni' }), $rt.TenantId)))
        } else {
            $rows.Add((New-CheckRow 'Tenant du client' 'FAIL' $rt.Detail 'Aucune connexion ne sera tentee tant que le tenant n''est pas identifie. Corriger -Tenant (domaine .onmicrosoft.com ou GUID).'))
        }
    }

    # --- 5. Module Microsoft.Graph.Authentication ---
    $modName = 'Microsoft.Graph.Authentication'
    $modMin = [version]'2.0.0'
    if (-not $NeedGraph) {
        $rows.Add((New-CheckRow "Module $modName" 'SKIP' 'non necessaire (aucune connexion au tenant)'))
    } else {
        $st = Get-PreflightModuleState $modName
        $bad = (-not $st.Installed) -or ($st.Installed -lt $modMin)
        $cmdUser = "Install-Module -Name $modName -Scope CurrentUser -Force -AllowClobber"
        $cmdAdmin = "Install-Module -Name $modName -Scope AllUsers -Force -AllowClobber"
        $failRow = { param($detail, $impact) New-CheckRow "Module $modName" 'FAIL' $detail ("Sans ce module, aucune connexion au tenant n'est possible. $impact") }
        $modRow = $null

        if ($bad) {
            $detailTodo = if ($st.Installed) { "version $($st.Installed), minimum $modMin" } else { 'absent' }
            $galleryOk = $true
            $repo = $null
            try { $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop } catch { $repo = $null }
            if (-not $repo) {
                $rows.Add((New-CheckRow 'PSGallery' 'FAIL' 'depot PSGallery non enregistre' 'Le module manquant ne peut pas etre installe. Commande : Register-PSRepository -Default'))
                $galleryOk = $false
            } else {
                $g = Get-HttpsReach 'https://www.powershellgallery.com/api/v2'
                if ($g.State -in 'Ok', 'Cert') {
                    $rows.Add((New-CheckRow 'PSGallery' 'OK' $g.Detail))
                } else {
                    $rows.Add((New-CheckRow 'PSGallery' 'FAIL' $g.Detail 'Impossible de telecharger le module depuis ce poste. L''installer depuis un autre reseau, ou le copier manuellement.'))
                    $galleryOk = $false
                }
            }
            if (-not $galleryOk) {
                $modRow = & $failRow "module absent ou trop ancien ($detailTodo), telechargement impossible" "Commande a lancer depuis un reseau autorise : $cmdUser"
            } else {
                $go = [bool]$InstallMissingModules
                if (-not $go) {
                    Write-Host ''
                    Write-Host "Module PowerShell a installer ou mettre a jour : $modName ($detailTodo)" -ForegroundColor Yellow
                    $go = Confirm-Preflight 'L''installer maintenant dans votre profil utilisateur (sans droits administrateur) ? [O/N]'
                }
                if (-not $go) {
                    $modRow = & $failRow "module absent ou trop ancien ($detailTodo) ; installation refusee" "Pour l'installer vous-meme : $cmdUser"
                } else {
                    $nuget = $null
                    try { $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1 } catch { }
                    if ($nuget -and [version]"$($nuget.Version)" -ge [version]'2.8.5.201') {
                        $rows.Add((New-CheckRow 'Fournisseur NuGet' 'OK' "version $($nuget.Version)"))
                    } else {
                        try {
                            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                            $rows.Add((New-CheckRow 'Fournisseur NuGet' 'OK' 'installe dans le profil utilisateur'))
                        } catch {
                            $rows.Add((New-CheckRow 'Fournisseur NuGet' 'WARN' ("installation impossible : " + $_.Exception.Message) 'L''installation du module va tout de meme etre tentee ; si elle echoue, utiliser la commande proposee pour une console administrateur.'))
                        }
                    }
                    $forceNote = ''
                    if ("$($repo.InstallationPolicy)" -ne 'Trusted') {
                        $trusted = $false
                        if (Confirm-Preflight 'PSGallery n''est pas un depot approuve. L''approuver sur ce poste (Set-PSRepository -Name PSGallery -InstallationPolicy Trusted) ? [O/N]') {
                            try {
                                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
                                $trusted = $true
                                $rows.Add((New-CheckRow 'PSGallery approuve' 'OK' 'depot marque comme approuve sur ce poste'))
                            } catch {
                                $rows.Add((New-CheckRow 'PSGallery approuve' 'WARN' ("changement impossible : " + $_.Exception.Message) 'L''installation sera forcee sans modifier la configuration.'))
                            }
                        }
                        if (-not $trusted) {
                            $forceNote = ' (depot non approuve : installation forcee, sans modifier votre configuration)'
                            $rows.Add((New-CheckRow 'PSGallery approuve' 'WARN' 'depot non approuve, configuration inchangee' 'Le module est installe avec -Force, ce qui supprime l''invite de confirmation. Rien d''autre n''est modifie.'))
                        }
                    }
                    try {
                        Write-Host "Installation de $modName (peut prendre une a deux minutes) ..." -ForegroundColor Cyan
                        Install-Module -Name $modName -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                        $st = Get-PreflightModuleState $modName
                        if ((-not $st.Installed) -or ($st.Installed -lt $modMin)) {
                            $modRow = & $failRow "installation terminee mais version $(if ($st.Installed) { $st.Installed } else { 'introuvable' }) detectee (minimum $modMin)" 'Fermer cette console, ouvrir une nouvelle fenetre pwsh et relancer.'
                        } else {
                            $modRow = New-CheckRow "Module $modName" 'OK' ("installe ou mis a jour : version $($st.Installed)" + $forceNote)
                        }
                    } catch {
                        $m = "$($_.Exception.Message)"
                        if ($m -match 'administrator|administrateur|UnauthorizedAccess|Access to the path|Acces au chemin|denied|refus|elevat|privilege') {
                            $needsAdmin = $true
                            $modRow = & $failRow "installation refusee faute de droits : $($m.Substring(0, [Math]::Min(120, $m.Length)))" "A lancer dans une console PowerShell ouverte en tant qu'administrateur : $cmdAdmin (puis relancer l'outil)."
                        } else {
                            $modRow = & $failRow ("installation echouee : " + $m.Substring(0, [Math]::Min(160, $m.Length))) "Essayer manuellement : $cmdUser"
                        }
                    }
                }
            }
        } else {
            $modRow = New-CheckRow "Module $modName" 'OK' "version $($st.Installed)"
            if ($st.Loaded -and $st.Loaded -lt $modMin) {
                $modRow = & $failRow "version $($st.Loaded) deja chargee dans cette session (minimum $modMin)" 'Fermer cette console, ouvrir une nouvelle fenetre pwsh et relancer.'
            }
        }
        $rows.Add($modRow)
    }

    # --- 5 bis. Module ExchangeOnlineManagement (v2.2, Mail) : jamais bloquant, l'etape Exchange devient manuelle s'il manque ---
    if ($NeedExchange) {
        $exoName = 'ExchangeOnlineManagement'
        $exoMin = [version]'3.0.0'
        $exoCmd = "Install-Module -Name $exoName -Scope CurrentUser -Force -AllowClobber"
        $exoSt = Get-PreflightModuleState $exoName
        $exoBad = (-not $exoSt.Installed) -or ($exoSt.Installed -lt $exoMin)
        if ($exoBad -and [bool]$InstallMissingModules) {
            try {
                Write-Host "Installation de $exoName (peut prendre une a deux minutes) ..." -ForegroundColor Cyan
                Install-Module -Name $exoName -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                $exoSt = Get-PreflightModuleState $exoName
                $exoBad = (-not $exoSt.Installed) -or ($exoSt.Installed -lt $exoMin)
            } catch {
                $em = "$($_.Exception.Message)"
                $rows.Add((New-CheckRow "Module $exoName" 'WARN' ("installation echouee : " + $em.Substring(0, [Math]::Min(140, $em.Length))) "Le reste de la configuration continue ; l'etape Exchange (EWS) du courrier sera a faire a la main. Pour l'installer vous-meme : $exoCmd"))
                $exoBad = $null
            }
        }
        if ($null -eq $exoBad) { }
        elseif ($exoBad) {
            $exoDet = if ($exoSt.Installed) { "version $($exoSt.Installed), minimum $exoMin" } else { 'absent' }
            $rows.Add((New-CheckRow "Module $exoName" 'WARN' "$exoDet (necessaire pour inscrire l'application dans EwsAllowedAppIDs, Charge Mail)" "Le reste de la configuration continue ; l'etape Exchange (EWS) sera a faire a la main. Pour que l'outil la fasse : installer le module ($exoCmd) puis relancer, ou relancer avec -InstallMissingModules."))
        } else {
            $rows.Add((New-CheckRow "Module $exoName" 'OK' "version $($exoSt.Installed)"))
        }
    }

    # --- 6. Generation d'un certificat auto-signe (test local jetable, en memoire seulement) ---
    if (-not $NeedGraph) {
        $rows.Add((New-CheckRow 'Certificat auto-signe' 'SKIP' 'non necessaire (aucune connexion au tenant)'))
    } else {
        $cc = Test-CertificateCapability
        if ($cc.Ok) { $rows.Add((New-CheckRow 'Certificat auto-signe' 'OK' $cc.Detail)) }
        else { $rows.Add((New-CheckRow 'Certificat auto-signe' 'FAIL' ("generation impossible : " + $cc.Detail) 'Le certificat d''authentification du connecteur ne pourra pas etre genere sur ce poste (cryptographie .NET indisponible ou bloquee par une politique de securite).')) }
    }

    $ok = (@($rows | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0)
    [pscustomobject]@{ Ok = $ok; Rows = @($rows); NeedsAdmin = $needsAdmin; TenantId = $tenantId; TenantDomain = $tenantDomain }
}
