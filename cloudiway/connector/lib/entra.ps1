# entra.ps1 - etat, plan, application et verification cote tenant (Microsoft Graph). VERSION 2 (2026-10-31).
# Dot-sourcee par le script principal apres common.ps1 et permissions.ps1.
# Regles : GET/POST/PATCH uniquement (aucun DELETE HTTP, aucune suppression de permission, d'application ni d'utilisateur) ;
# SEULE EXCEPTION (decision de conception) : le nettoyage des anciens identifiants CREES PAR L'OUTIL
# (certificats : POST removeKey avec preuve de possession signee par le NOUVEAU certificat ; secrets client : POST removePassword),
# uniquement APRES l'ecriture reussie du connecteur
# Cloudiway avec le nouvel identifiant. Toute autre cle de l'application (posee a la main) est conservee.
# Aucune fonction ne leve d'exception vers l'appelant ; aucun secret dans Write-RunLog.
#
# IDENTIFIANTS EN MEMOIRE SEULEMENT : le certificat (PFX en [byte[]]), son mot de passe, le secret client et le mot de
# passe du compte de service vivent dans $script:Ctx.Credentials et nulle part ailleurs : aucun fichier .pfx, aucun etat local,
# aucun .secret.json. (Le transport -CertificateTransport Path, fichier temporaire a ACL restreinte, est entierement gere cote Cloudiway :
# lib\cloudiway.ps1, New-CiwTempPfx / Remove-CiwTempFiles ; ce module n'ecrit AUCUN fichier.)
# Credentials : PfxBytes, PfxPassword, CertThumbprint, CertNotAfter, ClientSecret, SecretKeyId,
# SecretNotAfter, ServiceAccountPassword. Created (aucune valeur secrete) : AppId, AppObjectId, SpObjectId, ServiceAccountUpn,
# ServiceAccountObjectId, AppCertificateCount, AppSecretCount (totaux dans l application).
# Indicateurs de contexte ecrits : CredentialsRotation (bool), CredentialsRotationReason, ServiceAccountPasswordManual (bool ;
# compte adopte : le mot de passe doit etre saisi dans le portail Cloudiway).
#
# Une etape qui echoue apres la generation d'un identifiant ne le conserve pas : il est efface de la memoire (il n'est pas, ou pas
# prouve, dans le tenant) et le passage suivant regenere ce qui manque.
#
# COHERENCE A TERME D'ENTRA : l'annuaire est eventuellement coherent. Un objet qui vient d'etre cree (application,
# principal de service, utilisateur) ou modifie peut mettre jusqu'a ~1 minute a etre visible partout. Attendre environ
# une minute entre deux passages rapproches ; un second passage trop tot peut voir un etat incomplet (le plan reste sur,
# il n'ecrit que ce qui manque). Invoke-EntraRetry absorbe les delais courts a l'interieur d'un passage.

$script:EntraTag = 'CloudiwayConnector'
$script:EntraApplyData = @{}
$script:EntraLastError = ''
$script:EntraResCreated = @()   # ressources dont le principal de service vient d'etre cree (attente de propagation)
$script:CloudiwayRedirectUris = @('https://portal.cloudiway.com/teams/callback', 'https://portal.cloudiway.com/connector')
# Plateforme de l'application sous laquelle les URI de redirection Cloudiway sont declarees : web | spa | publicClient.
# Seule constante a changer pour basculer (creation, lecture, plan et verification suivent).
$script:CloudiwayRedirectPlatform = 'web'
$script:RenewalWindowDays = 30   # en dessous, un identifiant est renouvele

# ----------------------------------------------------------------------------------------------
# Aides contexte
# ----------------------------------------------------------------------------------------------

function Set-EntraCtx([string]$Name, $Value) {
    if ($script:Ctx -is [System.Collections.IDictionary]) { $script:Ctx[$Name] = $Value }
    else { $script:Ctx | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Get-EntraCtx([string]$Name) {
    if ($script:Ctx -is [System.Collections.IDictionary]) { return $script:Ctx[$Name] }
    return $script:Ctx.$Name
}

# Retourne la table Created ou Credentials du contexte (creee si absente).
function Get-EntraBag([ValidateSet('Created', 'Credentials')][string]$Which) {
    $bag = Get-EntraCtx $Which
    if ($null -eq $bag -or $bag -isnot [System.Collections.IDictionary]) {
        $bag = @{}
        Set-EntraCtx $Which $bag
    }
    return $bag
}

# Noms codifies du contexte ($script:Ctx.Names) ; a defaut, calcules par Get-CodedNames depuis le contexte.
function Get-EntraNames {
    $n = Get-EntraCtx 'Names'
    if ($n -and $n.App) { return $n }
    $mode = "$(Get-EntraCtx 'Mode')"
    $pid2 = "$(Get-EntraCtx 'ProjectId')"
    if ($mode -and $pid2) {
        return (Get-CodedNames -Mode $mode -ProjectId $pid2 -TenantShort "$(Get-EntraCtx 'TenantShort')" -AppName "$(Get-EntraCtx 'AppName')" -ServiceAccountName "$(Get-EntraCtx 'ServiceAccountName')" -ConnectorName "$(Get-EntraCtx 'ConnectorName')")
    }
    return [pscustomobject]@{ App = "$(Get-EntraCtx 'AppName')"; ServiceAccountLocal = "$(Get-EntraCtx 'ServiceAccountName')"; ServiceAccountDisplay = "$(Get-EntraCtx 'ServiceAccountName')"; Connector = "$(Get-EntraCtx 'ConnectorName')"; CertificateSubject = '' }
}

# v2.6 : portees Graph requises ABSENTES du jeton fourni (-GraphAccessToken), calculees par le script principal depuis la revendication scp. Jamais devinees.
function Test-TokenScopeMissing([string]$Scope) {
    try { return (@(Get-EntraCtx 'GraphTokenMissingScopes') | Where-Object { $_ -ieq $Scope }).Count -gt 0 } catch { return $false }
}

function Get-EntraAuthMethod {
    $a = "$(Get-EntraCtx 'AuthMethod')"
    if ($a -in 'Certificate', 'Secret', 'Both') { return $a }
    return 'Both'
}

function Get-EntraValidityDays {
    $d = 0
    try { $d = [int](Get-EntraCtx 'ValidityDays') } catch { }
    if ($d -le 0) { try { $d = [int](Get-EntraCtx 'CertValidityDays') } catch { } }
    if ($d -le 0) { $d = 180 }
    return $d
}

function Get-ServiceAccountUpn {
    $name = "$((Get-EntraNames).ServiceAccountLocal)"
    if (-not $name) { return '' }
    if ($name -match '@') { return $name }
    $dom = "$(Get-EntraCtx 'DefaultDomain')"
    if (-not $dom) { return '' }
    return "$name@$dom"
}

function New-GraphFilterPath([string]$Base, [string]$Filter, [string]$Select = '') {
    $p = $Base + '?$filter=' + [uri]::EscapeDataString($Filter)
    if ($Select) { $p += '&$select=' + $Select }
    return $p
}

function ConvertTo-EntraDate($Value) {
    try { if ($null -eq $Value -or "$Value" -eq '') { return $null }; return ([datetime]$Value).ToUniversalTime() } catch { return $null }
}

# URI de redirection de l'application sous la plateforme configuree ($script:CloudiwayRedirectPlatform). Tableau (eventuellement vide).
function Get-AppRedirectUris($App) {
    if ($null -eq $App) { return @() }
    $plat = $null
    try { $plat = $App.($script:CloudiwayRedirectPlatform) } catch { }
    if ($null -eq $plat) { return @() }
    return @($plat.redirectUris | Where-Object { $_ })
}

function ConvertTo-HexThumbprint($Base64) {
    # Graph v1.0 renvoie customKeyIdentifier d'un certificat en HEXADECIMAL (40 caracteres, constate sur un tenant reel le 2026-10-31) ;
    # d'autres versions/clients le renvoient en Base64 de l'empreinte binaire : les deux formes sont acceptees.
    $s = "$Base64".Trim()
    if ($s -match '^[0-9A-Fa-f]{40}$') { return $s.ToUpperInvariant() }
    try { return [Convert]::ToHexString([Convert]::FromBase64String($s)).ToUpperInvariant() } catch { return '' }
}

# Date au format Graph sans fractions de seconde.
function ConvertTo-GraphDate([datetime]$Value) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }

# Prefixe de displayName des cles creees par l'outil : sujet codifie sans "CN=" (Cloudiway-<MODE>-P<ProjectId>).
function Get-ToolKeyPrefix {
    $s = ("$((Get-EntraNames).CertificateSubject)" -replace '^CN=', '')
    if (-not $s) { $s = 'Cloudiway-{0}-P{1}' -f "$(Get-EntraCtx 'Mode')".ToUpperInvariant(), (Get-EntraCtx 'ProjectId') }
    return $s
}

# Une cle (certificat ou secret) a-t-elle ete creee par l'outil ? displayName = prefixe codifie, suivi d'un espace ou de la fin
# (comparaison insensible a la casse ; "Cloudiway-SOURCE-P123" ne correspond pas a "Cloudiway-SOURCE-P12345").
function Test-ToolKeyName($DisplayName, [string]$Prefix) {
    if (-not $Prefix -or $null -eq $DisplayName) { return $false }
    return ("$DisplayName" -imatch ('^' + [regex]::Escape($Prefix) + '(\s|$)'))
}

# Entree de keyCredentials a renvoyer pour une cle EXISTANTE : sans le champ 'key' (Graph l'identifie par son keyId et la conserve).
function ConvertTo-KeepKeyEntry($Key) {
    $o = [ordered]@{}
    foreach ($p in 'type', 'usage', 'keyId', 'customKeyIdentifier', 'displayName', 'startDateTime', 'endDateTime') { if ($null -ne $Key.$p) { $o[$p] = $Key.$p } }
    return $o
}

function ConvertTo-Base64Url([byte[]]$Bytes) { return ([Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')) }

# JWT de preuve de possession pour POST /applications/{id}/removeKey (Graph exige un jeton signe par la cle privee d'un certificat
# DEJA enregistre et valide dans l'application). En-tete { alg RS256, typ JWT, x5t = base64url(SHA1 du certificat), kid = x5t } ; charge
# { aud 00000002-0000-0000-c000-000000000000, iss = object id de l'application, nbf = maintenant - 1 min, exp = maintenant + 8 min }
# (epoch secondes) ; signature RSA SHA-256 PKCS#1 v1.5. Le jeton est retourne a l'appelant, JAMAIS journalise ni affiche ; la cle privee
# et l'objet certificat sont liberes avant le retour.
function New-KeyRemovalProof {
    param(
        [Parameter(Mandatory)][byte[]]$PfxBytes,
        [Parameter(Mandatory)][string]$PfxPassword,
        [Parameter(Mandatory)][string]$AppObjectId
    )
    $x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]
    $cert = $null; $rsa = $null
    try {
        $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        try {
            $cert = if ($loader) { $loader::LoadPkcs12($PfxBytes, $PfxPassword, $flags) } else { $x509::new($PfxBytes, $PfxPassword, $flags) }
        }
        catch {
            $cert = if ($loader) { $loader::LoadPkcs12($PfxBytes, $PfxPassword) } else { $x509::new($PfxBytes, $PfxPassword) }
        }
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        if (-not $rsa) { throw 'cle privee du nouveau certificat indisponible' }
        $x5t = ConvertTo-Base64Url ([System.Security.Cryptography.SHA1]::HashData($cert.RawData))
        $now = [DateTimeOffset]::UtcNow
        $hdr = [ordered]@{ alg = 'RS256'; typ = 'JWT'; x5t = $x5t; kid = $x5t } | ConvertTo-Json -Compress
        $pl = [ordered]@{ aud = '00000002-0000-0000-c000-000000000000'; iss = "$AppObjectId"; nbf = $now.AddMinutes(-1).ToUnixTimeSeconds(); exp = $now.AddMinutes(8).ToUnixTimeSeconds() } | ConvertTo-Json -Compress
        $signing = (ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($hdr))) + '.' + (ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($pl)))
        $sig = $rsa.SignData([System.Text.Encoding]::ASCII.GetBytes($signing), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        return ($signing + '.' + (ConvertTo-Base64Url $sig))
    }
    finally {
        if ($rsa) { $rsa.Dispose() }
        if ($cert) { $cert.Dispose() }
    }
}

# Contenu PUBLIC (base64 du certificat, sans cle privee) d'un PFX en memoire : sert au repli de nettoyage par PATCH keyCredentials.
function Get-PfxPublicBase64([byte[]]$PfxBytes, [string]$PfxPassword) {
    $cert = $null
    try {
        $loader = 'System.Security.Cryptography.X509Certificates.X509CertificateLoader' -as [type]
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        $cert = if ($loader) { $loader::LoadPkcs12($PfxBytes, $PfxPassword, $flags) } else { [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxBytes, $PfxPassword, $flags) }
        return [Convert]::ToBase64String($cert.RawData)
    }
    finally { if ($cert) { $cert.Dispose() } }
}

# Appartenance d'une portee a une liste, insensible a la casse.
function Test-ScopeIn($List, [string]$Name) { return (@($List | Where-Object { "$_" -ieq $Name }).Count -gt 0) }

# Efface de la memoire les identifiants d'un type ('Cert', 'Secret', 'ServiceAccount' ou 'All') ; supprime le PFX temporaire.
function Clear-EntraCredentials([ValidateSet('Cert', 'Secret', 'ServiceAccount', 'All')][string]$Which = 'All') {
    $cr = Get-EntraCtx 'Credentials'
    if ($null -eq $cr -or $cr -isnot [System.Collections.IDictionary]) { return }
    $keys = switch ($Which) {
        'Cert' { @('PfxBytes', 'PfxPassword', 'CertThumbprint', 'CertNotAfter') }
        'Secret' { @('ClientSecret', 'SecretKeyId', 'SecretNotAfter') }
        'ServiceAccount' { @('ServiceAccountPassword') }
        default { @('PfxBytes', 'PfxPassword', 'CertThumbprint', 'CertNotAfter', 'ClientSecret', 'SecretKeyId', 'SecretNotAfter', 'ServiceAccountPassword') }
    }
    foreach ($k in $keys) {
        if ($cr.Contains($k)) {
            if ($k -eq 'PfxBytes' -and $cr[$k] -is [byte[]]) { [Array]::Clear($cr[$k], 0, $cr[$k].Length) }
            $cr.Remove($k)
        }
    }
}

# ----------------------------------------------------------------------------------------------
# Contexte du tenant et droits
# ----------------------------------------------------------------------------------------------

function Get-TenantContext {
    $info = [pscustomobject]@{ TenantId = ''; DisplayName = ''; DefaultDomain = ''; TenantShort = ''; Domains = @(); Error = '' }
    try {
        $o = @(Invoke-GraphGet '/organization') | Select-Object -First 1
        if (-not $o) { throw 'organisation introuvable dans la reponse Graph' }
        $info.TenantId = "$($o.id)"
        $info.DisplayName = "$($o.displayName)"
        $domains = @($o.verifiedDomains)
        $info.Domains = @($domains | ForEach-Object { "$($_.name)" })
        $cands = @($domains | Where-Object { "$($_.name)" -like '*.onmicrosoft.com' -and "$($_.name)" -notlike '*.mail.onmicrosoft.com' })
        $pick = $cands | Where-Object { $_.isInitial -eq $true } | Select-Object -First 1
        if (-not $pick) { $pick = $cands | Select-Object -First 1 }
        if ($pick) {
            $info.DefaultDomain = "$($pick.name)"
            $info.TenantShort = $info.DefaultDomain.Split('.')[0]
        }
        else { $info.Error = 'aucun domaine .onmicrosoft.com verifie' }
    }
    catch {
        $info.Error = Get-ErrMsg $_
        Write-RunLog ("Get-TenantContext : {0}" -f $info.Error)
    }
    Set-EntraCtx 'DefaultDomain' $info.DefaultDomain
    Set-EntraCtx 'TenantShort' $info.TenantShort
    Set-EntraCtx 'DisplayName' $info.DisplayName
    return $info
}

function Test-AdminRights {
    $rows = [System.Collections.Generic.List[object]]::new()
    $gaTemplate = $script:EntraRoleTemplates.GlobalAdministrator
    $roles = @()
    $readOk = $true
    try {
        $roles = @(Invoke-GraphGet '/me/transitiveMemberOf/microsoft.graph.directoryRole' -All)
    }
    catch {
        $readOk = $false
        $msg = Get-ErrMsg $_
        Write-RunLog ("Test-AdminRights : {0}" -f $msg)
        $rows.Add([pscustomobject]@{ Name = 'Roles Entra'; Status = 'FAIL'; Detail = "Lecture impossible : $msg"; Impact = 'Droits non verifiables : toute ecriture sera consideree comme non garantie.' })
    }
    $names = @($roles | ForEach-Object { "$($_.displayName)" } | Where-Object { $_ } | Sort-Object -Unique)
    $isGa = $false
    if ($readOk) { $isGa = (@($roles | Where-Object { "$($_.roleTemplateId)" -ieq $gaTemplate }).Count -gt 0) }
    Set-EntraCtx 'IsGlobalAdmin' $isGa
    Set-EntraCtx 'Roles' $names
    if ($readOk) {
        if ($isGa) {
            $rows.Add([pscustomobject]@{ Name = 'Administrateur general'; Status = 'OK'; Detail = 'Role Administrateur general actif pour le compte connecte.'; Impact = '' })
        }
        else {
            $detail = if ($names.Count -gt 0) { 'Roles actifs : ' + ($names -join ', ') + ' (un role PIM seulement eligible n''apparait pas ici : l''activer puis relancer).' } else { 'Aucun role d''annuaire actif pour le compte connecte.' }
            $rows.Add([pscustomobject]@{
                    Name   = 'Administrateur general'; Status = 'WARN'; Detail = $detail
                    Impact = 'BLOQUE : creation de l''application, consentement administrateur, attribution de roles Entra, creation du compte de service.'
                })
        }
    }
    return $rows.ToArray()
}

# ----------------------------------------------------------------------------------------------
# Permissions : resolution par nom, requiredResourceAccess
# ----------------------------------------------------------------------------------------------

# Lit le principal de service d'une ressource (Graph, Exchange, SharePoint) et indexe appRoles / portees par NOM.
function Get-EntraResourceInfo([string]$Key) {
    $appId = $script:ResourceAppIds[$Key]
    $info = [pscustomobject]@{ Key = $Key; AppId = $appId; Found = $false; Absent = $false; SpId = ''; Roles = @{}; Scopes = @{}; Error = '' }
    try {
        $path = New-GraphFilterPath '/servicePrincipals' "appId eq '$appId'" 'id,appId,displayName,appRoles,oauth2PermissionScopes'
        $sp = @(Invoke-GraphGet $path) | Select-Object -First 1
        if ($sp) {
            $info.Found = $true
            $info.SpId = "$($sp.id)"
            foreach ($r in @($sp.appRoles)) {
                if (-not $r.value) { continue }
                if ($r.isEnabled -eq $false) { continue }
                if (@($r.allowedMemberTypes) -contains 'Application') { $info.Roles["$($r.value)"] = "$($r.id)" }
            }
            foreach ($s in @($sp.oauth2PermissionScopes)) {
                if (-not $s.value) { continue }
                if ($s.isEnabled -eq $false) { continue }
                $info.Scopes["$($s.value)"] = "$($s.id)"
            }
        }
        else { $info.Absent = $true }   # absent : le plan le cree (POST /servicePrincipals { appId }), ce n'est pas une erreur de lecture
    }
    catch {
        $info.Error = Get-ErrMsg $_
        Write-RunLog ("Ressource {0} : {1}" -f $Key, $info.Error)
    }
    return $info
}

# Calcule les permissions attendues, resolues en identifiants.
# Retourne { Resolved [list]; Unresolved [string[]] (obligatoires, bloquantes); OptionalSkipped [string[]] (informatives);
# PendingResources [string[]] (principal de service de ressource absent : sera cree, resolution apres) }.
# Resolved : { Resource; ResourceAppId; Name; Type; Id }.
function Get-EntraDesired($State) {
    $resolved = [System.Collections.Generic.List[object]]::new()
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $optional = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.List[string]]::new()
    $set = @(Get-PermissionSet -Mode (Get-EntraCtx 'Mode') -Workloads @(Get-EntraCtx 'Workloads'))
    foreach ($p in $set) {
        $res = $State.Resources[$p.Resource]
        $id = $null
        if ($res -and $res.Found) {
            if ($p.Type -eq 'Application') { $id = $res.Roles[$p.Name] } else { $id = $res.Scopes[$p.Name] }
        }
        if ($id) {
            $resolved.Add([pscustomobject]@{ Resource = $p.Resource; ResourceAppId = $script:ResourceAppIds[$p.Resource]; Name = $p.Name; Type = $p.Type; Id = "$id" })
            continue
        }
        if ($res -and -not $res.Found -and $res.Absent) {
            if (-not $pending.Contains($p.Resource)) { $pending.Add($p.Resource) }
            continue
        }
        $label = "$($p.Resource) : $($p.Name)" + $(if ($p.Type -ne 'Application') { ' (deleguee)' } else { '' })
        if ($p.Optional) { $optional.Add($label) } else { $unresolved.Add($label) }
    }
    return [pscustomobject]@{ Resolved = $resolved; Unresolved = $unresolved.ToArray(); OptionalSkipped = $optional.ToArray(); PendingResources = $pending.ToArray() }
}

# Relit une ressource avec attente (propagation apres creation de son principal de service).
function Get-EntraResourceInfoWait([string]$Key) {
    $delays = @(2, 4, 8, 12, 16)
    $i = 0
    while ($true) {
        $ri = Get-EntraResourceInfo $Key
        if ($ri.Found -or $i -ge $delays.Count) { return $ri }
        Start-Sleep -Seconds $delays[$i]
        $i++
    }
}

# Fusionne les entrees demandees dans un requiredResourceAccess existant SANS jamais retirer d'entree.
# Retourne { Value [object[]]; Added [int] }.
function Merge-RequiredResourceAccess($Existing, $Resolved) {
    $map = [ordered]@{}
    foreach ($ex in @($Existing)) {
        if (-not $ex) { continue }
        $rid = "$($ex.resourceAppId)"
        if (-not $map.Contains($rid)) { $map[$rid] = [System.Collections.Generic.List[object]]::new() }
        foreach ($ra in @($ex.resourceAccess)) { $map[$rid].Add(@{ id = "$($ra.id)"; type = "$($ra.type)" }) }
    }
    $added = 0
    foreach ($d in @($Resolved)) {
        $rid = "$($d.ResourceAppId)"
        $type = if ($d.Type -eq 'Application') { 'Role' } else { 'Scope' }
        if (-not $map.Contains($rid)) { $map[$rid] = [System.Collections.Generic.List[object]]::new() }
        $exists = @($map[$rid] | Where-Object { $_.id -ieq $d.Id -and $_.type -ieq $type }).Count -gt 0
        if (-not $exists) { $map[$rid].Add(@{ id = $d.Id; type = $type }); $added++ }
    }
    $value = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $map.Keys) { $value.Add(@{ resourceAppId = $k; resourceAccess = @($map[$k].ToArray()) }) }
    return [pscustomobject]@{ Value = @($value.ToArray()); Added = $added }
}

function New-RequiredResourceAccess($Resolved) {
    return (Merge-RequiredResourceAccess -Existing @() -Resolved $Resolved).Value
}

# ----------------------------------------------------------------------------------------------
# Certificat auto-signe (EN MEMOIRE)
# ----------------------------------------------------------------------------------------------

# Genere un certificat auto-signe RSA 2048 / SHA256 (classe .NET CertificateRequest) et exporte le PFX EN MEMOIRE, protege par mot de passe.
# Retourne { Thumbprint; NotBefore; NotAfter; CerBase64; PfxBytes [byte[]] }. Aucun fichier. Peut lever une exception (l'appelant la capture).
function New-ConnectorCertificate {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][int]$ValidityDays,
        [Parameter(Mandatory)][string]$Password
    )
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $cert = $null
    try {
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            $Subject, $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $notBefore = [DateTimeOffset]::UtcNow.AddMinutes(-5)
        $notAfter = [DateTimeOffset]::UtcNow.AddDays($ValidityDays)
        $cert = $req.CreateSelfSigned($notBefore, $notAfter)
        $pfx = [byte[]]$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $Password)
        return [pscustomobject]@{
            Thumbprint = $cert.Thumbprint.ToUpperInvariant()
            NotBefore  = $cert.NotBefore.ToUniversalTime()    # dates du certificat lui-meme (resolution seconde)
            NotAfter   = $cert.NotAfter.ToUniversalTime()
            CerBase64  = [Convert]::ToBase64String($cert.RawData)
            PfxBytes   = $pfx
        }
    }
    finally {
        if ($cert) { $cert.Dispose() }
        $rsa.Dispose()
    }
}

# ----------------------------------------------------------------------------------------------
# Inventaire (LECTURE SEULE)
# ----------------------------------------------------------------------------------------------

function Get-EntraState {
    $errors = [System.Collections.Generic.List[string]]::new()
    if (-not "$(Get-EntraCtx 'DefaultDomain')") { [void](Get-TenantContext) }
    $state = [pscustomobject]@{
        Resources        = @{}
        AppMatches       = @()
        App              = $null
        AppTagged        = $false
        AppReadOk        = $true
        AppAmbiguous     = $false
        Sp               = $null
        AppRoleGrants    = @()
        Oauth2Grants     = @()
        EntraRoles       = @()
        KeyCredentials   = @()
        PasswordCredentials = @()
        ServiceAccount   = $null
        ServiceAccountOk = $true
        ServiceAccountRoles = @()
        ConditionalAccess = @()
        CaError          = ''
        SecurityDefaults = $null     # $true / $false / $null (illisible) : valeurs de securite par defaut (MFA imposee a tous)
        Errors           = $errors
    }

    # Ressources (par NOM)
    foreach ($k in $script:ResourceAppIds.Keys) {
        $ri = Get-EntraResourceInfo $k
        $state.Resources[$k] = $ri
        if ($ri.Error) { $errors.Add("Ressource ${k} : $($ri.Error)") }
    }

    # Application par nom codifie + etiquette
    $appName = "$((Get-EntraNames).App)"
    try {
        $path = New-GraphFilterPath '/applications' ("displayName eq '{0}'" -f $appName.Replace("'", "''")) ('id,appId,displayName,tags,signInAudience,isFallbackPublicClient,requiredResourceAccess,keyCredentials,passwordCredentials,' + $script:CloudiwayRedirectPlatform)
        $found = @(Invoke-GraphGet $path -All)
        $state.AppMatches = $found
        $tagged = @($found | Where-Object { @($_.tags) -contains $script:EntraTag })
        if ($found.Count -eq 1) { $state.App = $found[0]; $state.AppTagged = (@($found[0].tags) -contains $script:EntraTag) }
        elseif ($tagged.Count -eq 1) { $state.App = $tagged[0]; $state.AppTagged = $true }
        elseif ($found.Count -gt 1) { $state.AppAmbiguous = $true }
    }
    catch {
        $state.AppReadOk = $false
        $errors.Add('Application : ' + (Get-ErrMsg $_))
    }

    if ($state.App) {
        $state.KeyCredentials = @($state.App.keyCredentials)
        $state.PasswordCredentials = @($state.App.passwordCredentials)
        # Principal de service
        try {
            $state.Sp = @(Invoke-GraphGet (New-GraphFilterPath '/servicePrincipals' "appId eq '$($state.App.appId)'" 'id,appId,displayName')) | Select-Object -First 1
        }
        catch { $errors.Add('Principal de service : ' + (Get-ErrMsg $_)) }
        if ($state.Sp) {
            $spId = "$($state.Sp.id)"
            try { $state.AppRoleGrants = @(Invoke-GraphGet "/servicePrincipals/$spId/appRoleAssignments" -All) }
            catch { $errors.Add('appRoleAssignments : ' + (Get-ErrMsg $_)) }
            try { $state.Oauth2Grants = @(Invoke-GraphGet (New-GraphFilterPath '/oauth2PermissionGrants' "clientId eq '$spId'") -All) }
            catch { $errors.Add('oauth2PermissionGrants : ' + (Get-ErrMsg $_)) }
            try {
                $ra = @(Invoke-GraphGet (New-GraphFilterPath '/roleManagement/directory/roleAssignments' "principalId eq '$spId'") -All)
                $state.EntraRoles = @($ra | ForEach-Object { "$($_.roleDefinitionId)" })
            }
            catch { $errors.Add('Roles Entra du principal de service : ' + (Get-ErrMsg $_)) }
        }
        Set-EntraCreatedFromState $state
    }

    # Compte de service
    if ([bool](Get-EntraCtx 'NeedServiceAccount')) {
        $upn = Get-ServiceAccountUpn
        if ($upn) {
            try {
                $u = @(Invoke-GraphGet (New-GraphFilterPath '/users' ("userPrincipalName eq '{0}'" -f $upn.Replace("'", "''")) 'id,userPrincipalName,displayName,accountEnabled,passwordPolicies,employeeType,assignedLicenses')) | Select-Object -First 1
                $state.ServiceAccount = $u
                if ($u) {
                    try {
                        $ra = @(Invoke-GraphGet (New-GraphFilterPath '/roleManagement/directory/roleAssignments' "principalId eq '$($u.id)'") -All)
                        $state.ServiceAccountRoles = @($ra | ForEach-Object { "$($_.roleDefinitionId)" })
                    }
                    catch { $errors.Add('Roles du compte de service : ' + (Get-ErrMsg $_)) }
                }
            }
            catch { $state.ServiceAccountOk = $false; $errors.Add('Compte de service : ' + (Get-ErrMsg $_)) }
        }
        else { $state.ServiceAccountOk = $false; $errors.Add('Compte de service : domaine par defaut inconnu, UPN non calculable') }

        # Acces conditionnel (AVERTISSEMENT seulement)
        try {
            if (Test-TokenScopeMissing 'Policy.Read.All') { throw 'portee Policy.Read.All absente du jeton fourni (-GraphAccessToken) : politiques d''acces conditionnel non lues, verifier a la main que le compte de service est exclu de la MFA' }
            $pol = @(Invoke-GraphGet '/identity/conditionalAccess/policies' -All)
            $saId = if ($state.ServiceAccount) { "$($state.ServiceAccount.id)" } else { '' }
            $hits = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $pol) {
                if ("$($p.state)" -ne 'enabled') { continue }
                $gc = $p.grantControls
                $needsMfa = ($gc -and ((@($gc.builtInControls) -contains 'mfa') -or $gc.authenticationStrength))
                if (-not $needsMfa) { continue }
                $us = $p.conditions.users
                $all = (@($us.includeUsers) -contains 'All')
                $other = (@($us.includeGroups).Count -gt 0 -or @($us.includeRoles).Count -gt 0 -or ($saId -and @($us.includeUsers) -contains $saId))
                $excluded = ($saId -and (@($us.excludeUsers) -contains $saId))
                if (($all -or $other) -and -not $excluded) {
                    $hits.Add([pscustomobject]@{ Name = "$($p.displayName)"; Id = "$($p.id)"; Scope = $(if ($all) { 'tous les utilisateurs' } else { 'groupes ou roles cibles (a verifier)' }) })
                }
            }
            $state.ConditionalAccess = $hits.ToArray()
        }
        catch { $state.CaError = Get-ErrMsg $_; Write-RunLog ("Acces conditionnel illisible : {0}" -f $state.CaError) }
        # Valeurs de securite par defaut (AVERTISSEMENT seulement) : si actives, la MFA est imposee a tous, compte de service compris.
        try {
            if (Test-TokenScopeMissing 'Policy.Read.All') { throw 'portee Policy.Read.All absente du jeton fourni (-GraphAccessToken) : etat des valeurs de securite par defaut NON lu (ni suppose)' }
            $sd = Invoke-GraphGet '/policies/identitySecurityDefaultsEnforcementPolicy'
            if ($null -ne $sd -and $null -ne $sd.isEnabled) { $state.SecurityDefaults = [bool]$sd.isEnabled }
        }
        catch { Write-RunLog ("Valeurs de securite par defaut illisibles : {0}" -f (Get-ErrMsg $_)) }
    }
    # Created doit refleter aussi le compte de service existant (role SharePoint Administrator, rapport final).
    Set-EntraCreatedFromState $state
    foreach ($e in $errors) { Write-RunLog ("ETAT lecture partielle : {0}" -f $e) }
    return $state
}

# Renseigne Created avec ce qui existe deja (permet aux etapes suivantes de fonctionner quand tout est OK).
function Set-EntraCreatedFromState($State) {
    $c = Get-EntraBag 'Created'
    if ($State.App) {
        $c['AppId'] = "$($State.App.appId)"; $c['AppObjectId'] = "$($State.App.id)"
        $c['AppCertificateCount'] = @($State.KeyCredentials).Count
        $c['AppSecretCount'] = @($State.PasswordCredentials).Count
    }
    if ($State.Sp) { $c['SpObjectId'] = "$($State.Sp.id)" }
    if ($State.ServiceAccount) { $c['ServiceAccountUpn'] = "$($State.ServiceAccount.userPrincipalName)"; $c['ServiceAccountObjectId'] = "$($State.ServiceAccount.id)" }
}

# ----------------------------------------------------------------------------------------------
# Decision de renouvellement des identifiants - sans etat local
# ----------------------------------------------------------------------------------------------

# Compare une empreinte (certificat) ou un keyId (secret) en ignorant casse, tirets et espaces.
function ConvertTo-KeyToken([string]$Value) { return (("$Value") -replace '[^0-9A-Za-z]', '').ToUpperInvariant() }

# Retourne { Skip; Rotate; Reason; Marker; AuthMethod; UseCert; UseSecret }.
# Un nouvel identifiant est genere A CHAQUE EXECUTION (defaut v2.3) ; avec -KeepCredentials seulement si : application a creer, connecteur inexistant, marqueur absent,
# empreinte du marqueur absente des certificats VALIDES de l'application, ou moins de 30 jours de validite. Sinon rien.
function Get-CredentialDecision($State) {
    $auth = Get-EntraAuthMethod
    $d = [pscustomobject]@{ Skip = $false; Rotate = $false; Reason = ''; Marker = $null; AuthMethod = $auth; UseCert = ($auth -in 'Certificate', 'Both'); UseSecret = ($auth -in 'Secret', 'Both') }
    if ([bool](Get-EntraCtx 'SkipCloudiway')) { $d.Skip = $true; $d.Reason = '-SkipCloudiway : aucun connecteur a alimenter, aucun identifiant genere'; return $d }
    # Connecteur Cloudiway non declarable dans ce passage (homonyme non etiquete, doublons, lecture impossible, produit inconnu) :
    # generer un identifiant qui ne partira nulle part l'empilerait dans l'application a chaque relance.
    $blockWhy = "$(Get-EntraCtx 'CloudiwayBlockReason')"
    if (-not $blockWhy) { $blockWhy = "$(Get-EntraCtx 'ExistingConnectorError')" }
    if ($blockWhy) {
        if ($blockWhy.Length -gt 140) { $blockWhy = $blockWhy.Substring(0, 140) + '...' }
        $d.Skip = $true; $d.Reason = "connecteur Cloudiway non declarable dans ce passage ($blockWhy) : aucun identifiant genere, relancer apres correction"
        return $d
    }
    $existing = Get-EntraCtx 'ExistingConnector'
    # M4 : le connecteur etiquete designe une autre application (ou une application absente de ce tenant) : rien n'est genere.
    if ($existing -and (Get-Command Get-CiwRestClientMismatch -ErrorAction SilentlyContinue)) {
        $mm = ''
        try { $mm = if ($State.App) { Get-CiwRestClientMismatch $existing "$($State.App.appId)" } else { Get-CiwMissingAppReason $existing '' } } catch { $mm = '' }
        if ($mm) {
            if ($mm.Length -gt 140) { $mm = $mm.Substring(0, 140) + '...' }
            $d.Skip = $true; $d.Reason = "connecteur Cloudiway non declarable dans ce passage ($mm) : aucun identifiant genere, relancer apres correction"
            return $d
        }
    }
    $now = (Get-Date).ToUniversalTime()
    $limit = $now.AddDays($script:RenewalWindowDays)
    $marker = $null
    if ($existing -and (Get-Command Get-ConnectorMarker -ErrorAction SilentlyContinue)) {
        try { $marker = Get-ConnectorMarker -Connector $existing } catch { $marker = $null }
    }
    $d.Marker = $marker
    $markerAfter = $null
    if ($marker -and $marker.NotAfter) {
        $markerAfter = [datetime]$marker.NotAfter
        if ($markerAfter.Kind -eq 'Unspecified') { $markerAfter = [datetime]::SpecifyKind($markerAfter, 'Utc') } else { $markerAfter = $markerAfter.ToUniversalTime() }
    }
    $app = $State.App
    if ([bool](Get-EntraCtx 'RotateCredentials')) { $d.Rotate = $true; $d.Reason = 'renouvellement a chaque execution'; return $d }
    if (-not $app) { $d.Rotate = $true; $d.Reason = 'application a creer'; return $d }
    if (-not $existing) { $d.Rotate = $true; $d.Reason = 'le connecteur n''existe pas encore'; return $d }
    if (-not $marker -or -not $marker.Thumbprint) { $d.Rotate = $true; $d.Reason = 'marqueur absent du connecteur (nom du certificat et externalKey)'; return $d }
    $tok = ConvertTo-KeyToken $marker.Thumbprint
    if ($d.UseCert) {
        $key = @($State.KeyCredentials | Where-Object { ([string](ConvertTo-HexThumbprint $_.customKeyIdentifier)).StartsWith($tok) -and ((ConvertTo-EntraDate $_.endDateTime) -gt $now) }) | Select-Object -First 1
        if (-not $key) { $d.Rotate = $true; $d.Reason = "l'empreinte du marqueur ($tok) ne figure pas parmi les certificats valides de l'application"; return $d }
        $end = ConvertTo-EntraDate $key.endDateTime
        if ($markerAfter -and $markerAfter -lt $end) { $end = $markerAfter }
        if ($end -lt $limit) { $d.Rotate = $true; $d.Reason = ('moins de {0} jours de validite restants (expiration {1:yyyy-MM-dd})' -f $script:RenewalWindowDays, $end); return $d }
    }
    if ($d.UseSecret) {
        $pcs = @($State.PasswordCredentials | Where-Object { (ConvertTo-EntraDate $_.endDateTime) -gt $limit })
        if ($d.UseCert) {
            if ($pcs.Count -eq 0) { $d.Rotate = $true; $d.Reason = 'aucun secret client valide plus de 30 jours dans l''application'; return $d }
        }
        else {
            # Secret seul : le marqueur designe le keyId du secret precede de S (CIW1|S<keyId>|<AAAAMMJJ>)
            $hit = @($State.PasswordCredentials | Where-Object { ('S' + (ConvertTo-KeyToken $_.keyId)).StartsWith($tok) -and ((ConvertTo-EntraDate $_.endDateTime) -gt $now) }) | Select-Object -First 1
            if (-not $hit) { $d.Rotate = $true; $d.Reason = "l'identifiant du marqueur ($tok) ne figure pas parmi les secrets valides de l'application"; return $d }
            $end = ConvertTo-EntraDate $hit.endDateTime
            if ($markerAfter -and $markerAfter -lt $end) { $end = $markerAfter }
            if ($end -lt $limit) { $d.Rotate = $true; $d.Reason = ('moins de {0} jours de validite restants (expiration {1:yyyy-MM-dd})' -f $script:RenewalWindowDays, $end); return $d }
        }
    }
    $d.Reason = "marqueur coherent ($tok), identifiant valide plus de $($script:RenewalWindowDays) jours"
    return $d
}

# M3 : le connecteur doit-il REELLEMENT recevoir un nouveau mot de passe de compte de service ? Oui seulement s'il n'existe pas encore,
# si le renouvellement est actif (defaut v2.3, sauf -KeepCredentials), si c'est une adoption (connecteur fait a la main), ou si son compte de
# migration n'est pas celui-ci. Un certificat qui expire seul NE reinitialise PAS le mot de passe du compte (le connecteur garde le sien).
function Test-ConnectorNeedsAccountPassword {
    $ex = Get-EntraCtx 'ExistingConnector'
    if ($null -eq $ex) { return $true }
    if ([bool](Get-EntraCtx 'RotateCredentials')) { return $true }
    if (-not (Get-Command Test-CiwOwnedKey -ErrorAction SilentlyContinue)) { return $true }
    if (-not (Test-CiwOwnedKey "$(Get-CiwProp $ex 'externalKey')")) { return $true }
    $st = ConvertTo-CiwSettings $ex
    if (-not $st) { return $true }
    $acc = "$(Get-CiwProp $st 'MigrationAccount')"
    return ($acc -ine (Get-ServiceAccountUpn))
}

# v2.5 (C) : texte unique de l'avertissement « valeurs de securite par defaut actives » (console, ligne du plan, rapport). L'outil ne les modifie JAMAIS.
function Get-SecurityDefaultsEffectText {
    return 'les valeurs de securite par defaut sont ACTIVES dans ce tenant : la MFA est imposee a tous les comptes, y compris le compte de service cree par l''outil. EFFET : les jobs OneDrive et SharePoint de ce tenant ECHOUERONT a l''authentification du compte de service (flux sans interaction) ; le courrier (Mail) n''est pas concerne. OPTIONS : (1) desactiver les valeurs de securite par defaut au profit d''un acces conditionnel cible qui EXCLUT le compte de service, ou (2) renoncer a OneDrive / SharePoint pour ce tenant. L''outil ne modifie jamais ces parametres.'
}

# Liste des URI de redirection a declarer : Teams en Source uniquement.
function Get-WantedRedirectUris {
    $mode = "$(Get-EntraCtx 'Mode')"
    $wl = @(ConvertTo-CanonicalWorkloads @(Get-EntraCtx 'Workloads'))
    if ($mode -ieq 'Source' -and $wl -contains 'Teams') { return @($script:CloudiwayRedirectUris) }
    return @()
}

# ----------------------------------------------------------------------------------------------
# Plan
# ----------------------------------------------------------------------------------------------

function Get-EntraRightsBlock {
    if ((Get-EntraCtx 'IsGlobalAdmin') -eq $false) { return 'Droits insuffisants : le role Administrateur general est requis.' }
    return ''
}

# Ajoute une ligne au plan. $Data (hashtable) active un Apply execute par Invoke-EntraApply.
function Add-EntraItem([string]$Area, [string]$Name, [string]$Action, [string]$Reason, $Data = $null) {
    $apply = $null
    if ($Action -in 'CREATE', 'UPDATE') {
        $block = Get-EntraRightsBlock
        if ($block) { $Action = 'BLOCKED'; $Reason = "$block ($Reason)" }
        elseif ($null -ne $Data) {
            $key = 'E{0}' -f ($script:EntraApplyData.Count + 1)
            $script:EntraApplyData[$key] = $Data
            $apply = [scriptblock]::Create("Invoke-EntraApply '$key'")
        }
    }
    return Add-PlanItem -Area $Area -Name $Name -Action $Action -Reason $Reason -Apply $apply
}

function New-EntraPlan {
    param([Parameter(Mandatory)]$State)
    $script:EntraApplyData = @{}
    $mode = "$(Get-EntraCtx 'Mode')"
    $workloads = @(Get-EntraCtx 'Workloads')
    $names = Get-EntraNames
    $appName = "$($names.App)"
    $adopt = [bool](Get-EntraCtx 'AdoptExisting')
    $desired = Get-EntraDesired $State
    $app = $State.App
    $appBlocked = $false
    $needSa = [bool](Get-EntraCtx 'NeedServiceAccount')
    $skipDep = 'application bloquee ou absente de l''etat : etape ignoree'
    $dec = Get-CredentialDecision $State
    Set-EntraCtx 'CredentialsRotation' ([bool]($dec.Rotate -and -not $dec.Skip))
    Set-EntraCtx 'CredentialsRotationReason' $dec.Reason
    Set-EntraCtx 'ServiceAccountPasswordManual' $false
    Set-EntraCtx 'ServiceAccountResetPending' $false
    Set-EntraCtx 'ServiceAccountResetDone' $false
    Set-EntraCtx 'ServiceAccountResetFailed' $false
    Set-EntraCtx 'SecurityDefaultsActive' $false
    $wantUris = @(Get-WantedRedirectUris)

    # ---- Application ----
    if (-not $State.AppReadOk) {
        [void](Add-EntraItem 'Application' $appName 'BLOCKED' 'lecture des applications impossible (droits Graph ?) : voir run.log')
        $appBlocked = $true
    }
    elseif ($State.AppAmbiguous) {
        [void](Add-EntraItem 'Application' $appName 'BLOCKED' ("{0} applications portent ce nom sans qu'une seule porte l'etiquette {1} : choisir un autre -AppName" -f @($State.AppMatches).Count, $script:EntraTag))
        $appBlocked = $true
    }
    elseif (-not $app) {
        $rra = New-RequiredResourceAccess $desired.Resolved
        $pubTxt = if ($needSa) { 'client public (compte de service)' } else { 'sans flux client public' }
        $uriTxt = if ($wantUris.Count -gt 0) { ', URI de redirection Cloudiway' } else { '' }
        [void](Add-EntraItem 'Application' $appName 'CREATE' "application inexistante (locataire unique, $pubTxt$uriTxt, etiquette CloudiwayConnector)" @{ Kind = 'AppCreate'; Name = $appName; RRA = $rra; Public = $needSa; Uris = $wantUris })
    }
    elseif (-not $State.AppTagged -and -not $adopt) {
        [void](Add-EntraItem 'Application' $appName 'BLOCKED' ("une application de meme nom existe sans l'etiquette {0} : relancer avec -AdoptExisting pour l'adopter" -f $script:EntraTag))
        $appBlocked = $true
    }
    else {
        $fix = [System.Collections.Generic.List[string]]::new()
        if (-not $State.AppTagged) { $fix.Add("ajout de l'etiquette $($script:EntraTag) (adoption)") }
        # isFallbackPublicClient : uniquement si un compte de service est necessaire ; jamais modifie sinon (application adoptee comprise).
        $setPublic = ($needSa -and $app.isFallbackPublicClient -ne $true)
        if ($setPublic) { $fix.Add('activation du flux client public (isFallbackPublicClient, compte de service)') }
        $haveUris = @(Get-AppRedirectUris $app)
        $missUris = @($wantUris | Where-Object { $u = $_; -not (@($haveUris | Where-Object { "$_" -ieq $u }).Count -gt 0) })
        if ($missUris.Count -gt 0) { $fix.Add(("ajout de {0} URI de redirection Cloudiway (les existantes sont conservees)" -f $missUris.Count)) }
        if ($fix.Count -gt 0) {
            [void](Add-EntraItem 'Application' $appName 'UPDATE' ($fix -join ' ; ') @{ Kind = 'AppPatch'; AppObjectId = "$($app.id)"; AddTag = (-not $State.AppTagged); SetPublic = $setPublic; ExistingTags = @($app.tags); Uris = $missUris })
        }
        else {
            $r = "AppId $($app.appId)"
            if ("$($app.signInAudience)" -ne 'AzureADMyOrg') { $r += " (attention : signInAudience = $($app.signInAudience), non modifie)" }
            [void](Add-EntraItem 'Application' $appName 'OK' $r)
        }
    }

    # ---- Principal de service ----
    if ($appBlocked) { [void](Add-EntraItem 'ServicePrincipal' $appName 'SKIP' $skipDep) }
    elseif ($State.Sp) { [void](Add-EntraItem 'ServicePrincipal' $appName 'OK' "principal de service $($State.Sp.id)") }
    else { [void](Add-EntraItem 'ServicePrincipal' $appName 'CREATE' 'principal de service inexistant' @{ Kind = 'SpCreate' }) }

    # ---- Principaux de service de ressource absents du tenant (Exchange Online, SharePoint Online) ----
    foreach ($k in @($desired.PendingResources)) {
        if ($appBlocked) { [void](Add-EntraItem 'ServicePrincipal' "Ressource $k" 'SKIP' $skipDep) }
        else { [void](Add-EntraItem 'ServicePrincipal' "Ressource $k" 'CREATE' "principal de service de la ressource $k absent du tenant : a creer (POST /servicePrincipals { appId }), permissions resolues ensuite" @{ Kind = 'ResSpCreate'; ResourceKey = $k }) }
    }

    # ---- Permissions (requiredResourceAccess) ----
    if ($appBlocked) { [void](Add-EntraItem 'Permissions' 'requiredResourceAccess' 'SKIP' $skipDep) }
    else {
        $existing = if ($app) { @($app.requiredResourceAccess) } else { @() }
        $merge = Merge-RequiredResourceAccess -Existing $existing -Resolved $desired.Resolved
        $nApp = @($desired.Resolved | Where-Object Type -EQ 'Application').Count
        $nDel = @($desired.Resolved | Where-Object Type -EQ 'Delegated').Count
        $label = "{0} permission(s) d'application, {1} deleguee(s)" -f $nApp, $nDel
        if (-not $app) { [void](Add-EntraItem 'Permissions' 'requiredResourceAccess' 'CREATE' "$label (declarees a la creation, verifiees ensuite)" @{ Kind = 'Rra' }) }
        elseif ($merge.Added -gt 0) { [void](Add-EntraItem 'Permissions' 'requiredResourceAccess' 'UPDATE' ("{0} entree(s) a ajouter sur {1} ; les entrees existantes sont conservees" -f $merge.Added, $label) @{ Kind = 'Rra' }) }
        elseif (@($desired.PendingResources).Count -gt 0) { [void](Add-EntraItem 'Permissions' 'requiredResourceAccess' 'UPDATE' ("permissions des ressources {0} a declarer apres creation de leur principal de service ; les entrees existantes sont conservees" -f (@($desired.PendingResources) -join ', ')) @{ Kind = 'Rra' }) }
        else { [void](Add-EntraItem 'Permissions' 'requiredResourceAccess' 'OK' $label) }
        if (@($desired.Unresolved).Count -gt 0) {
            [void](Add-EntraItem 'Permissions' 'Permissions introuvables' 'BLOCKED' ("permission(s) obligatoire(s) non publiee(s) par la ressource dans ce tenant : " + ($desired.Unresolved -join ' ; ')))
        }
        if (@($desired.OptionalSkipped).Count -gt 0) {
            [void](Add-EntraItem 'Permissions' 'Permissions optionnelles' 'OK' ("ignoree : non publiee par la ressource (information, non bloquant) : " + ($desired.OptionalSkipped -join ' ; ')))
        }
    }

    # ---- Consentement administrateur (par ressource) ----
    foreach ($k in $script:ResourceAppIds.Keys) {
        $res = $State.Resources[$k]
        $apps = @($desired.Resolved | Where-Object { $_.Resource -eq $k -and $_.Type -eq 'Application' })
        $dels = @($desired.Resolved | Where-Object { $_.Resource -eq $k -and $_.Type -eq 'Delegated' })
        $nm = "Consentement $k"
        if (@($desired.PendingResources) -contains $k) {
            # Ressource creee pendant l'Apply : le consentement est recalcule a l'execution (roles et portees resolus apres creation).
            if ($appBlocked) { [void](Add-EntraItem 'Consent' $nm 'SKIP' $skipDep) }
            else { [void](Add-EntraItem 'Consent' $nm 'CREATE' 'ressource a creer : roles et portees a accorder, resolus apres creation de son principal de service' @{ Kind = 'Consent'; ResourceKey = $k; Deferred = $true }) }
            continue
        }
        if (($apps.Count + $dels.Count) -eq 0) { continue }
        if ($appBlocked) { [void](Add-EntraItem 'Consent' $nm 'SKIP' $skipDep); continue }
        $missRoles = @($apps | Where-Object {
                $rid = $_.Id
                @($State.AppRoleGrants | Where-Object { "$($_.resourceId)" -eq $res.SpId -and "$($_.appRoleId)" -ieq $rid }).Count -eq 0
            })
        $grant = @($State.Oauth2Grants | Where-Object { "$($_.resourceId)" -eq $res.SpId -and "$($_.consentType)" -eq 'AllPrincipals' }) | Select-Object -First 1
        $haveScopes = if ($grant) { @("$($grant.scope)" -split '\s+' | Where-Object { $_ }) } else { @() }
        $missScopes = @($dels | Where-Object { -not (Test-ScopeIn $haveScopes $_.Name) })
        if ($missRoles.Count -eq 0 -and $missScopes.Count -eq 0) {
            [void](Add-EntraItem 'Consent' $nm 'OK' ("{0} role(s) et {1} portee(s) deja accordes" -f $apps.Count, $dels.Count))
            continue
        }
        $act = if ($State.Sp -and ($State.AppRoleGrants.Count -gt 0 -or $grant)) { 'UPDATE' } else { 'CREATE' }
        $rs = "{0} role(s) d'application et {1} portee(s) deleguee(s) a accorder" -f $missRoles.Count, $missScopes.Count
        [void](Add-EntraItem 'Consent' $nm $act $rs @{
                Kind = 'Consent'; ResourceKey = $k; ResSpId = "$($res.SpId)"
                Roles = @($missRoles | ForEach-Object { @{ Name = $_.Name; Id = $_.Id } })
                Scopes = @($missScopes | ForEach-Object { $_.Name }); GrantId = $(if ($grant) { "$($grant.id)" } else { '' }); HaveScopes = $haveScopes
            })
    }

    # ---- Roles Entra du principal de service (Exchange, Mail seulement) ----
    foreach ($r in @(Get-RequiredEntraRoles -Mode $mode -Workloads $workloads | Where-Object Target -EQ 'ServicePrincipal')) {
        $nm = "Role $($r.Name)"
        if ($appBlocked) { [void](Add-EntraItem 'Roles' $nm 'SKIP' $skipDep) }
        elseif (@($State.EntraRoles | Where-Object { $_ -ieq $r.TemplateId }).Count -gt 0) { [void](Add-EntraItem 'Roles' $nm 'OK' 'deja attribue au principal de service') }
        else { [void](Add-EntraItem 'Roles' $nm 'CREATE' 'a attribuer au principal de service de l''application' @{ Kind = 'EntraRole'; RoleName = $r.Name; TemplateId = $r.TemplateId; Target = 'ServicePrincipal' }) }
    }

    # ---- Exchange Online (EWS), Charge Mail : zone du plan placee apres les roles (v2.2) ----
    if (Get-Command -Name New-ExchangePlan -ErrorAction SilentlyContinue) {
        if ($appBlocked) { if ($script:Exo -and $script:Exo.Needed) { [void](Add-EntraItem 'Exchange' 'EWS : AppID dans EwsAllowedAppIDs' 'SKIP' $skipDep) } }
        else { New-ExchangePlan }
    }

    # ---- Identifiants de l'application : certificat et/ou secret client ----
    $days = Get-EntraValidityDays
    $nCert = @($State.KeyCredentials).Count
    $nSec = @($State.PasswordCredentials).Count
    if ($appBlocked) { [void](Add-EntraItem 'Certificate' 'Identifiants de l''application' 'SKIP' $skipDep) }
    elseif ($dec.Skip) { [void](Add-EntraItem 'Certificate' 'Identifiants de l''application' 'SKIP' $dec.Reason) }
    elseif (-not $dec.Rotate) {
        [void](Add-EntraItem 'Certificate' 'Identifiants de l''application' 'OK' ("{0} ; rien a generer ni a renvoyer au connecteur ({1} certificat(s), {2} secret(s) dans l'application)" -f $dec.Reason, $nCert, $nSec))
    }
    else {
        if ($dec.UseCert) {
            $act = if ($nCert -gt 0) { 'UPDATE' } else { 'CREATE' }
            $transport = if ("$(Get-EntraCtx 'CertificateTransport')" -ieq 'Path') { 'fichier temporaire supprime apres usage' } else { 'transmis en memoire' }
            [void](Add-EntraItem 'Certificate' 'Certificat de l''application' $act ("nouveau certificat : {0} ; RSA 2048 / SHA256, sujet {1}, validite {2} jours, {3} ; {4} certificat(s) existant(s) dans l'application (les anciens certificats de l'outil sont retires APRES l'ecriture du connecteur par removeKey : voir la zone Nettoyage), aucun fichier ecrit" -f $dec.Reason, $names.CertificateSubject, $days, $transport, $nCert) @{ Kind = 'CertCreate'; Days = $days; Subject = "$($names.CertificateSubject)" })
        }
        if ($dec.UseSecret) {
            $act = if ($nSec -gt 0) { 'UPDATE' } else { 'CREATE' }
            [void](Add-EntraItem 'Certificate' 'Secret client de l''application' $act ("nouveau secret client : {0} ; validite {1} jours, valeur gardee en memoire seulement ; {2} secret(s) existant(s) dans l'application (les anciens secrets de l'outil sont retires APRES l'ecriture du connecteur : voir la zone Nettoyage)" -f $dec.Reason, $days, $nSec) @{ Kind = 'SecretCreate'; Days = $days })
        }
    }

    # ---- Compte de service ----
    if ($needSa) {
        $upn = Get-ServiceAccountUpn
        $u = $State.ServiceAccount
        $nm = if ($upn) { $upn } else { "$($names.ServiceAccountLocal)" }
        $saBlocked = $false
        $resetPw = [bool]($dec.Rotate -and -not $dec.Skip -and (Test-ConnectorNeedsAccountPassword))
        $saLocalPart = $(if ($upn) { "$upn".Split('@')[0] } else { "$($names.ServiceAccountLocal)".Split('@')[0] })
        if ($saLocalPart -and -not $saLocalPart.StartsWith('svc-ciw-', [System.StringComparison]::OrdinalIgnoreCase)) {
            # M4 : la partie locale du compte de service commence TOUJOURS par svc-ciw- (adoption comprise) : l'outil ne cree ni ne modifie un compte au nom quelconque.
            [void](Add-EntraItem 'ServiceAccount' $nm 'BLOCKED' ("le nom du compte de service ('{0}') doit commencer par 'svc-ciw-' (adoption comprise) : l'outil ne cree ni ne modifie jamais un compte au nom quelconque" -f $saLocalPart))
            $saBlocked = $true
        }
        elseif (-not $upn -or -not $State.ServiceAccountOk) {
            [void](Add-EntraItem 'ServiceAccount' $nm 'BLOCKED' 'lecture ou calcul du compte de service impossible : voir run.log')
            $saBlocked = $true
        }
        elseif (-not $u) {
            [void](Add-EntraItem 'ServiceAccount' $nm 'CREATE' 'utilisateur inexistant ; mot de passe genere (transmis au connecteur, jamais affiche), expiration desactivee, etiquette employeeType = CloudiwayConnector, AUCUNE licence attribuee' @{ Kind = 'SaCreate'; Upn = $upn; DisplayName = "$($names.ServiceAccountDisplay)" })
        }
        elseif ("$($u.employeeType)" -ne '' -and "$($u.employeeType)" -ne $script:EntraTag) {
            [void](Add-EntraItem 'ServiceAccount' $nm 'BLOCKED' ("un utilisateur de meme nom existe avec employeeType = '{0}' (ni vide ni '{1}') : adoption refusee, ce champ n'est pas ecrase ; choisir un autre -ServiceAccountName" -f $u.employeeType, $script:EntraTag))
            $saBlocked = $true
        }
        elseif ("$($u.employeeType)" -ne $script:EntraTag -and -not $adopt) {
            [void](Add-EntraItem 'ServiceAccount' $nm 'BLOCKED' 'un utilisateur de meme nom existe et n''a pas ete cree par cet outil (non etiquete) : son mot de passe n''est JAMAIS reinitialise ; relancer avec -AdoptExisting pour l''adopter (le mot de passe devra alors etre saisi dans le portail Cloudiway)')
            $saBlocked = $true
        }
        elseif ("$($u.employeeType)" -ne $script:EntraTag) {
            # Adoption : etiquetage et expiration seulement ; le mot de passe n'est JAMAIS reinitialise ni connu de l'outil.
            $fix = [System.Collections.Generic.List[string]]::new()
            $fix.Add('marquage de l''utilisateur adopte (employeeType)')
            if ("$($u.passwordPolicies)" -notmatch 'DisablePasswordExpiration') { $fix.Add('expiration du mot de passe a desactiver') }
            Set-EntraCtx 'ServiceAccountPasswordManual' $true
            [void](Add-EntraItem 'ServiceAccount' $nm 'UPDATE' (($fix -join ' ; ') + ' ; mot de passe NON modifie : le mot de passe de ce compte devra etre saisi par le DSI dans le portail Cloudiway (connecteur, champ compte de migration)') @{ Kind = 'SaPatch'; UserId = "$($u.id)"; Mark = $true; Policies = "$($u.passwordPolicies)" })
        }
        else {
            $fix = [System.Collections.Generic.List[string]]::new()
            if ("$($u.passwordPolicies)" -notmatch 'DisablePasswordExpiration') { $fix.Add('expiration du mot de passe a desactiver (les autres strategies du compte sont conservees)') }
            if ($fix.Count -gt 0) {
                [void](Add-EntraItem 'ServiceAccount' $nm 'UPDATE' (($fix -join ' ; ') + ' ; mot de passe NON modifie ici') @{ Kind = 'SaPatch'; UserId = "$($u.id)"; Mark = $false; Policies = "$($u.passwordPolicies)" })
            }
            else { [void](Add-EntraItem 'ServiceAccount' $nm 'OK' $(if ($resetPw) { 'compte existant, etiquete et conforme (son mot de passe est traite avant l''ecriture du connecteur : voir la ligne suivante)' } else { 'compte existant, etiquete et conforme ; mot de passe inchange (le connecteur n''a pas besoin d''en recevoir un)' })) }
            # M2/M3 (v2.5, retour du premier client reel) : le mot de passe n'est reinitialise QUE si le connecteur doit en recevoir un, et dans Entra
            # D'ABORD ; le connecteur ne le recoit que si Entra l'a accepte (un compte qui detient un role d'administrateur peut refuser : HTTP 403).
            if ($resetPw) {
                Set-EntraCtx 'ServiceAccountResetPending' $true
                [void](Add-EntraItem 'ServiceAccountPwd' $nm 'UPDATE' ('nouveau mot de passe, reinitialise dans Entra AVANT l''ecriture du connecteur (le connecteur ne le recoit que si Entra l''a accepte ; si Entra refuse, le connecteur n''est pas modifie et garde son mot de passe) : ' + $dec.Reason) @{ Kind = 'SaPwdReset'; UserId = "$($u.id)" })
            }
        }
        foreach ($r in @(Get-RequiredEntraRoles -Mode $mode -Workloads $workloads -WithoutServiceAccount:([bool](Get-EntraCtx 'WithoutServiceAccount')) | Where-Object Target -EQ 'ServiceAccount')) {
            $rn = "Role $($r.Name) du compte de service"
            if ($saBlocked) { [void](Add-EntraItem 'ServiceAccount' $rn 'SKIP' 'compte de service bloque : etape ignoree') }
            elseif ($u -and @($State.ServiceAccountRoles | Where-Object { $_ -ieq $r.TemplateId }).Count -gt 0) { [void](Add-EntraItem 'ServiceAccount' $rn 'OK' 'deja attribue') }
            else { [void](Add-EntraItem 'ServiceAccount' $rn 'CREATE' 'a attribuer au compte de service' @{ Kind = 'EntraRole'; RoleName = $r.Name; TemplateId = $r.TemplateId; Target = 'ServiceAccount' }) }
        }
        # Avertissements MFA / licence (jamais bloquants, jamais appliques)
        $mfaHint = 'Exclure le compte des politiques d''acces conditionnel pendant les migrations de chats 1:1 et de canaux Teams (en Cible) ; ne jamais desactiver la MFA du tenant.'
        if ($State.CaError) { [void](Add-EntraItem 'ServiceAccount' 'Acces conditionnel (MFA)' 'OK' ("AVERTISSEMENT : politiques illisibles ({0}) ; verifier a la main que le compte de service est exclu de la MFA. {1}" -f $State.CaError, $mfaHint)) }
        elseif (@($State.ConditionalAccess).Count -gt 0) {
            $list = ($State.ConditionalAccess | ForEach-Object { "$($_.Name) [$($_.Scope)]" }) -join ' ; '
            [void](Add-EntraItem 'ServiceAccount' 'Acces conditionnel (MFA)' 'OK' "AVERTISSEMENT : politique(s) exigeant la MFA susceptible(s) de viser le compte de service : $list. $mfaHint")
        }
        if ($State.SecurityDefaults -eq $true) {
            Set-EntraCtx 'SecurityDefaultsActive' $true
            [void](Add-EntraItem 'ServiceAccount' 'Valeurs de securite par defaut (MFA)' 'OK' ('AVERTISSEMENT : ' + (Get-SecurityDefaultsEffectText)))
        }
    }
}

# ----------------------------------------------------------------------------------------------
# Zone Nettoyage (apres la zone Cloudiway) : un seul identifiant actif
# ----------------------------------------------------------------------------------------------

# Appele par le script principal APRES New-CloudiwayConnectorPlan. Ajoute une ligne UPDATE par type d'identifiant renouvele ce passage
# (certificat, secret client) s'il existe des anciennes cles CREEES PAR L'OUTIL (displayName = prefixe codifie). Les autres cles de
# l'application (posees a la main) ne sont jamais comptees ni retirees. La ligne depend de la ligne Cloudiway (table de dependances du
# script principal) : si le connecteur n'est pas ecrit, rien n'est retire.
function New-EntraCleanupPlan {
    param([Parameter(Mandatory)]$State)
    if (-not $State.App) { return }
    if (-not [bool](Get-EntraCtx 'CredentialsRotation')) { return }
    $prefix = Get-ToolKeyPrefix
    $auth = Get-EntraAuthMethod
    $newCert = @($script:Plan | Where-Object { [string]$_.Area -eq 'Certificate' -and [string]$_.Name -like 'Certificat de*' -and [string]$_.Action -in 'CREATE', 'UPDATE' }).Count -gt 0
    $newSec = @($script:Plan | Where-Object { [string]$_.Area -eq 'Certificate' -and [string]$_.Name -like 'Secret client*' -and [string]$_.Action -in 'CREATE', 'UPDATE' }).Count -gt 0
    if ($auth -in 'Certificate', 'Both' -and $newCert) {
        $old = @($State.KeyCredentials | Where-Object { Test-ToolKeyName $_.displayName $prefix })
        $kept = @($State.KeyCredentials).Count - $old.Count
        if ($old.Count -gt 0) {
            [void](Add-EntraItem 'Cleanup' 'Anciens certificats de l''outil' 'UPDATE' ("{0} ancien(s) certificat(s) de l'outil a retirer apres transmission du nouveau (nom commencant par {1} ; {2} autre(s) cle(s) de l'application conservee(s))" -f $old.Count, $prefix, $kept) @{ Kind = 'CleanupCerts' })
        }
    }
    if ($auth -in 'Secret', 'Both' -and $newSec) {
        $old = @($State.PasswordCredentials | Where-Object { Test-ToolKeyName $_.displayName $prefix })
        $kept = @($State.PasswordCredentials).Count - $old.Count
        if ($old.Count -gt 0) {
            [void](Add-EntraItem 'Cleanup' 'Anciens secrets client de l''outil' 'UPDATE' ("{0} ancien(s) secret(s) client de l'outil a retirer apres transmission du nouveau (nom commencant par {1} ; {2} autre(s) secret(s) de l'application conserve(s))" -f $old.Count, $prefix, $kept) @{ Kind = 'CleanupSecrets' })
        }
    }
}

# ----------------------------------------------------------------------------------------------
# Application (dispatcher des scriptblocks du plan)
# ----------------------------------------------------------------------------------------------

# Texte brut d'une erreur Graph (code JSON + message), pour DETECTER un cas (jamais affiche tel quel).
function Get-GraphErrText($e) {
    $t = ''
    try { $t += " $($e.ErrorDetails.Message)" } catch { }
    try { $t += " $($e.Exception.Message)" } catch { }
    return $t
}

# M5 : POST /applications/{id}/removeKey avec reessais. Un 400 Authentication_MissingOrMalformed (le nouveau certificat qui signe la preuve n'est pas
# encore propage) ou une erreur de propagation / indisponibilite est reessaye jusqu'a 3 fois (attentes 10 s, 20 s, 30 s). Une cle DEJA ABSENTE
# ("No credentials found" ou 404 sur removeKey) compte comme retiree. Retourne 'Removed' | 'AlreadyGone' ; leve apres le dernier essai.
function Invoke-RemoveKey([string]$AppObjectId, [string]$KeyId, [string]$Proof) {
    $waits = @(10, 20, 30)
    $n = 0
    while ($true) {
        try {
            [void](Invoke-GraphPost "/applications/$AppObjectId/removeKey" @{ keyId = $KeyId; proof = $Proof })
            return 'Removed'
        }
        catch {
            $code = Get-ErrCode $_
            $raw = Get-GraphErrText $_
            if ($code -eq 404 -or $raw -match 'No credentials found|No key credential found') { return 'AlreadyGone' }
            $transient = ($raw -match 'Authentication_MissingOrMalformed|propagat|replicat' -or $code -in 429, 500, 502, 503, 504)
            if (-not $transient -or $n -ge $waits.Count) { throw }
            Write-RunLog ("removeKey {0} : erreur transitoire ({1}), nouvel essai dans {2} s ({3}/{4})" -f $KeyId, $(if ($code) { "HTTP $code" } else { 'erreur' }), $waits[$n], ($n + 1), $waits.Count)
            Start-Sleep -Seconds $waits[$n]
            $n++
        }
    }
}

# Appel avec reprise : la propagation Entra peut retarder la visibilite d'un objet qui vient d'etre cree
# (principal de service, utilisateur, application). 7 tentatives, delais croissants 2+4+8+12+16+18 = 60 s au total (plafond).
function Invoke-EntraRetry([scriptblock]$Action, [int]$Max = 7) {
    $delays = @(2, 4, 8, 12, 16, 18)
    $n = 0
    while ($true) {
        try { return (& $Action) }
        catch {
            $n++
            $code = Get-ErrCode $_
            $msg = Get-ErrMsg $_
            # 404 (objet pas encore visible) et 400 "does not reference a valid application object" (principal de service cree juste apres l'application) :
            # propagation Entra, meme remede (reessai ~60 s au plus).
            if ($n -ge $Max -or ($code -ne 404 -and $msg -notmatch 'does not exist|not found|Request_ResourceNotFound|replication|Invalid object identifier|does not reference a valid application object|Not a valid reference update')) { throw }
            Start-Sleep -Seconds $delays[[Math]::Min($n - 1, $delays.Count - 1)]
        }
    }
}

function Invoke-EntraApply([string]$Key) {
    $d = $script:EntraApplyData[$Key]
    $script:EntraLastError = ''
    $script:EntraApplyNote = ''
    # Echec du nettoyage : NON bloquant, le nouvel identifiant est deja en place et transmis au connecteur.
    $cleanTail = ' Le nouvel identifiant est deja en place et transmis au connecteur Cloudiway : rien n''est casse ; les anciens identifiants de l''outil restent dans l''application jusqu''a la prochaine execution (chaque execution renouvelle les identifiants et retire les anciens), ou peuvent etre retires a la main dans Entra.'
    if ($null -eq $d) { $script:EntraLastError = "action inconnue ($Key)"; return $false }
    try {
        $created = Get-EntraBag 'Created'
        $cred = Get-EntraBag 'Credentials'
        switch ($d.Kind) {

            'AppCreate' {
                $body = @{ displayName = $d.Name; signInAudience = 'AzureADMyOrg'; tags = @($script:EntraTag); requiredResourceAccess = @($d.RRA) }
                if ($d.Public) { $body['isFallbackPublicClient'] = $true }   # seulement si un compte de service est necessaire
                if (@($d.Uris).Count -gt 0) { $body[$script:CloudiwayRedirectPlatform] = @{ redirectUris = @($d.Uris) } }
                $r = Invoke-GraphPost '/applications' $body
                if (-not $r.id) { throw 'reponse sans identifiant' }
                $created['AppId'] = "$($r.appId)"; $created['AppObjectId'] = "$($r.id)"
                Write-RunLog ("Application creee : AppId {0}" -f $r.appId)
                return $true
            }

            'AppPatch' {
                $body = @{}
                if ($d.AddTag) { $body['tags'] = @(@($d.ExistingTags | Where-Object { $_ }) + $script:EntraTag | Sort-Object -Unique) }
                if ($d.SetPublic) { $body['isFallbackPublicClient'] = $true }
                if (@($d.Uris).Count -gt 0) {
                    # Relecture fraiche : les URI existantes sont reprises telles quelles, les manquantes ajoutees (aucun retrait).
                    $cur = Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,{1}' -f $d.AppObjectId, $script:CloudiwayRedirectPlatform) }
                    $all = [System.Collections.Generic.List[string]]::new()
                    foreach ($x in (@(Get-AppRedirectUris $cur) + @($d.Uris))) { if ($x -and -not (Test-ScopeIn $all "$x")) { $all.Add("$x") } }
                    $body[$script:CloudiwayRedirectPlatform] = @{ redirectUris = @($all.ToArray()) }
                }
                [void](Invoke-GraphPatch "/applications/$($d.AppObjectId)" $body)
                return $true
            }

            'SpCreate' {
                $appId = "$($created['AppId'])"
                if (-not $appId) { throw 'application indisponible (etape precedente en echec)' }
                $ex = @(Invoke-GraphGet (New-GraphFilterPath '/servicePrincipals' "appId eq '$appId'" 'id,appId')) | Select-Object -First 1
                if ($ex) { $created['SpObjectId'] = "$($ex.id)"; return $true }
                $r = Invoke-EntraRetry { Invoke-GraphPost '/servicePrincipals' @{ appId = $appId } }
                if (-not $r.id) { throw 'reponse sans identifiant' }
                $created['SpObjectId'] = "$($r.id)"
                Write-RunLog ("Principal de service cree : {0}" -f $r.id)
                return $true
            }

            'ResSpCreate' {
                $appId = "$($script:ResourceAppIds[$d.ResourceKey])"
                if (-not $appId) { throw "ressource inconnue : $($d.ResourceKey)" }
                $ex = @(Invoke-GraphGet (New-GraphFilterPath '/servicePrincipals' "appId eq '$appId'" 'id,appId')) | Select-Object -First 1
                if (-not $ex) {
                    $r = Invoke-GraphPost '/servicePrincipals' @{ appId = $appId }
                    if (-not $r.id) { throw 'reponse sans identifiant' }
                    Write-RunLog ("Principal de service de la ressource {0} cree : {1}" -f $d.ResourceKey, $r.id)
                }
                $script:EntraResCreated = @($script:EntraResCreated) + $d.ResourceKey
                return $true
            }

            'Rra' {
                $oid = "$($created['AppObjectId'])"
                if (-not $oid) { throw 'application indisponible (etape precedente en echec)' }
                $cur = Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,requiredResourceAccess' -f $oid) }
                # Les permissions resolues sont recalculees depuis une lecture fraiche des ressources.
                $st = [pscustomobject]@{ Resources = @{} }
                foreach ($k in $script:ResourceAppIds.Keys) { $st.Resources[$k] = $(if (@($script:EntraResCreated) -contains $k) { Get-EntraResourceInfoWait $k } else { Get-EntraResourceInfo $k }) }
                $des = Get-EntraDesired $st
                $m = Merge-RequiredResourceAccess -Existing @($cur.requiredResourceAccess) -Resolved $des.Resolved
                if ($m.Added -eq 0) { return $true }
                [void](Invoke-GraphPatch "/applications/$oid" @{ requiredResourceAccess = @($m.Value) })
                Write-RunLog ("requiredResourceAccess : {0} entree(s) ajoutee(s)" -f $m.Added)
                return $true
            }

            'Consent' {
                $sp = "$($created['SpObjectId'])"
                if (-not $sp) { throw 'principal de service indisponible (etape precedente en echec)' }
                $resSpId = "$($d.ResSpId)"; $roles = @($d.Roles); $scopes = @($d.Scopes); $grantId = "$($d.GrantId)"; $haveScopes = @($d.HaveScopes)
                if ($d.Deferred) {
                    # Ressource dont le principal de service vient d'etre cree : tout est relu et recalcule maintenant.
                    $ri = Get-EntraResourceInfoWait $d.ResourceKey
                    if (-not $ri.Found) { throw "principal de service de la ressource $($d.ResourceKey) toujours introuvable apres creation (coherence a terme : relancer dans une minute)" }
                    $resSpId = "$($ri.SpId)"
                    $want = @(Get-PermissionSet -Mode (Get-EntraCtx 'Mode') -Workloads @(Get-EntraCtx 'Workloads') | Where-Object { $_.Resource -eq $d.ResourceKey })
                    $curRoles = @(Invoke-EntraRetry { Invoke-GraphGet "/servicePrincipals/$sp/appRoleAssignments" -All })
                    $roles = @(); $scopes = @(); $skipped = @()
                    foreach ($w in $want) {
                        $wid = if ($w.Type -eq 'Application') { $ri.Roles[$w.Name] } else { $ri.Scopes[$w.Name] }
                        if (-not $wid) { if (-not $w.Optional) { $script:EntraLastError = "permission obligatoire $($w.Name) non publiee par $($d.ResourceKey)"; $skipped += $w.Name }; continue }
                        if ($w.Type -eq 'Application') {
                            if (@($curRoles | Where-Object { "$($_.resourceId)" -eq $resSpId -and "$($_.appRoleId)" -ieq "$wid" }).Count -eq 0) { $roles += @{ Name = $w.Name; Id = "$wid" } }
                        }
                        else { $scopes += $w.Name }
                    }
                    if ($scopes.Count -gt 0) {
                        $g = @(Invoke-GraphGet (New-GraphFilterPath '/oauth2PermissionGrants' "clientId eq '$sp'") -All) | Where-Object { "$($_.resourceId)" -eq $resSpId -and "$($_.consentType)" -eq 'AllPrincipals' } | Select-Object -First 1
                        if ($g) { $grantId = "$($g.id)"; $haveScopes = @("$($g.scope)" -split '\s+' | Where-Object { $_ }) }
                        $scopes = @($scopes | Where-Object { -not (Test-ScopeIn $haveScopes $_) })
                    }
                    if ($skipped.Count -gt 0) { return $false }
                }
                if (-not $resSpId) { throw "principal de service de la ressource $($d.ResourceKey) introuvable" }
                $ok = $true
                $errs = [System.Collections.Generic.List[string]]::new()
                foreach ($r in $roles) {
                    try {
                        [void](Invoke-EntraRetry { Invoke-GraphPost "/servicePrincipals/$resSpId/appRoleAssignedTo" @{ principalId = $sp; resourceId = $resSpId; appRoleId = $r.Id } })
                        Write-RunLog ("Consentement role {0} / {1}" -f $d.ResourceKey, $r.Name)
                    }
                    catch {
                        $m = Get-ErrMsg $_
                        if ($m -match 'already exists|Permission being assigned already exists') { continue }
                        $ok = $false; $errs.Add("role $($r.Name) : $m")
                        Write-RunLog ("Consentement role {0} / {1} : ECHEC {2}" -f $d.ResourceKey, $r.Name, $m)
                    }
                }
                if ($scopes.Count -gt 0) {
                    try {
                        $all = [System.Collections.Generic.List[string]]::new()
                        foreach ($x in @($haveScopes) + @($scopes)) { if ($x -and -not (Test-ScopeIn $all $x)) { $all.Add("$x") } }
                        $allTxt = $all -join ' '
                        if ($grantId) { [void](Invoke-GraphPatch "/oauth2PermissionGrants/$grantId" @{ scope = $allTxt }) }
                        else {
                            try { [void](Invoke-EntraRetry { Invoke-GraphPost '/oauth2PermissionGrants' @{ clientId = $sp; consentType = 'AllPrincipals'; resourceId = $resSpId; scope = $allTxt } }) }
                            catch {
                                # m11 : l'octroi existe deja (cree entre la lecture et l'ecriture, ou invisible a la lecture) : on le relit puis PATCH avec fusion.
                                if ((Get-ErrMsg $_) -notmatch 'already exists') { throw }
                                $g2 = @(Invoke-GraphGet (New-GraphFilterPath '/oauth2PermissionGrants' "clientId eq '$sp'") -All) | Where-Object { "$($_.resourceId)" -eq $resSpId -and "$($_.consentType)" -eq 'AllPrincipals' } | Select-Object -First 1
                                if (-not $g2) { throw }
                                $all2 = [System.Collections.Generic.List[string]]::new()
                                foreach ($x in @("$($g2.scope)" -split '\s+') + @($scopes)) { if ($x -and -not (Test-ScopeIn $all2 $x)) { $all2.Add("$x") } }
                                $allTxt = $all2 -join ' '
                                [void](Invoke-GraphPatch "/oauth2PermissionGrants/$($g2.id)" @{ scope = $allTxt })
                                Write-RunLog 'Consentement portees : octroi deja existant, fusionne par PATCH'
                            }
                        }
                        Write-RunLog ("Consentement portees {0} : {1}" -f $d.ResourceKey, $allTxt)
                    }
                    catch {
                        $ok = $false; $errs.Add("portees $($d.ResourceKey) : " + (Get-ErrMsg $_))
                        Write-RunLog ("Consentement portees {0} : ECHEC {1}" -f $d.ResourceKey, $errs[$errs.Count - 1])
                    }
                }
                if (-not $ok) { $script:EntraLastError = "Consentement $($d.ResourceKey) en echec : " + ($errs -join ' ; ') }
                return $ok
            }

            'EntraRole' {
                $principal = if ($d.Target -eq 'ServiceAccount') { "$($created['ServiceAccountObjectId'])" } else { "$($created['SpObjectId'])" }
                if (-not $principal) { throw 'beneficiaire du role indisponible (etape precedente en echec)' }
                try {
                    [void](Invoke-EntraRetry { Invoke-GraphPost '/roleManagement/directory/roleAssignments' @{ principalId = $principal; roleDefinitionId = $d.TemplateId; directoryScopeId = '/' } })
                }
                catch {
                    $m = Get-ErrMsg $_
                    if ($m -notmatch 'already exists|ExistingRoleAssignment|conflict') {
                        if (Test-TokenScopeMissing 'RoleManagement.ReadWrite.Directory') { throw ("portee RoleManagement.ReadWrite.Directory absente du jeton fourni (-GraphAccessToken) : le role '{0}' n'a pas pu etre attribue ({1}). L'attribuer a la main (Entra > Roles et administrateurs) ou fournir un jeton portant cette portee." -f $d.RoleName, $m) }
                        throw
                    }
                }
                Write-RunLog ("Role {0} attribue ({1})" -f $d.RoleName, $d.Target)
                return $true
            }

            'CertCreate' {
                $oid = "$($created['AppObjectId'])"
                if (-not $oid) { throw 'application indisponible (etape precedente en echec)' }
                $pass = New-AlnumPassword 32
                $subject = "$($d.Subject)"
                if (-not $subject) { $subject = "CN=Cloudiway-" + "$(Get-EntraCtx 'Mode')".ToUpperInvariant() + "-P$(Get-EntraCtx 'ProjectId')" }
                $c = New-ConnectorCertificate -Subject $subject -ValidityDays $d.Days -Password $pass   # EN MEMOIRE : aucun fichier
                # Les cles existantes sont reprises SANS le champ 'key' (comportement attendu de Graph : une entree existante est
                # identifiee par son keyId et conservee). A TESTER sur une application jetable avant usage en production ;
                # c'est pourquoi la verification ci-dessous refuse tout resultat ou un certificat existant aurait disparu.
                $cur = Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,keyCredentials' -f $oid) }
                $before = @($cur.keyCredentials)
                # Reconstitution possible si le PATCH efface des cles : keyId et empreinte (customKeyIdentifier) de chaque ancienne cle, SANS secret ni cle.
                foreach ($k0 in $before) { Write-RunLog ("keyCredentials AVANT PATCH : keyId={0} customKeyIdentifier={1} fin={2}" -f $k0.keyId, $k0.customKeyIdentifier, $k0.endDateTime) }
                if (@($before).Count -eq 0) { Write-RunLog 'keyCredentials AVANT PATCH : aucune cle' }
                $keep = [System.Collections.Generic.List[object]]::new()
                foreach ($k in $before) { $keep.Add((ConvertTo-KeepKeyEntry $k)) }
                # Dates : secondes entieres, UTC, issues du certificat ; le NotAfter du PATCH ne depasse jamais celui du certificat.
                $keep.Add([ordered]@{
                        type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $c.CerBase64
                        displayName = ('{0} {1:yyyy-MM-dd}' -f ($subject -replace '^CN=', ''), (Get-Date))
                        startDateTime = (ConvertTo-GraphDate $c.NotBefore); endDateTime = (ConvertTo-GraphDate $c.NotAfter)
                    })
                $keepArr = @($keep.ToArray())
                [void](Invoke-EntraRetry { Invoke-GraphPatch "/applications/$oid" @{ keyCredentials = $keepArr } })
                # Verification : nouvelle empreinte presente ET aucun certificat precedent perdu (comparaison par keyId).
                # Entra est coherent a terme : la relecture juste apres le PATCH peut encore montrer l'ancienne liste. On attend (jusqu'a ~45 s) l'apparition de la nouvelle empreinte.
                $hasNew = $false; $after = @()
                foreach ($w in 0, 2, 4, 8, 12, 18) {
                    if ($w -gt 0) { Start-Sleep -Seconds $w }
                    $after = @((Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,keyCredentials' -f $oid) }).keyCredentials)
                    $hasNew = @($after | Where-Object { (ConvertTo-HexThumbprint $_.customKeyIdentifier) -eq $c.Thumbprint }).Count -gt 0
                    if ($hasNew) { break }
                    Write-RunLog ("Certificat {0} pas encore visible dans l'application (propagation), nouvelle lecture..." -f $c.Thumbprint)
                }
                $afterIds = @($after | ForEach-Object { "$($_.keyId)" })
                $lost = @($before | Where-Object { $_.keyId -and ($afterIds -notcontains "$($_.keyId)") })
                if ($lost.Count -gt 0) {
                    $script:EntraLastError = "ATTENTION : $($lost.Count) certificat(s) precedent(s) de l'application ont DISPARU apres le PATCH keyCredentials (keyId : " + (($lost | ForEach-Object { $_.keyId }) -join ', ') + "). Verifier l'application dans le portail Entra ; le nouveau certificat n'est pas transmis au connecteur, un nouveau passage en regenerera un."
                    Write-RunLog $script:EntraLastError
                    return $false
                }
                if (-not $hasNew) { throw 'le nouveau certificat n''apparait pas dans l''application apres le PATCH (non transmis au connecteur ; un nouveau passage en regenerera un)' }
                # Succes prouve : les identifiants passent en memoire (Credentials) pour le module Cloudiway.
                $cred['PfxBytes'] = $c.PfxBytes; $cred['PfxPassword'] = $pass
                $cred['CertThumbprint'] = $c.Thumbprint; $cred['CertNotAfter'] = $c.NotAfter
                Write-RunLog ("Certificat ajoute : empreinte {0}, expire le {1:yyyy-MM-dd}" -f $c.Thumbprint, $c.NotAfter)
                return $true
            }

            'SecretCreate' {
                $oid = "$($created['AppObjectId'])"
                if (-not $oid) { throw 'application indisponible (etape precedente en echec)' }
                $end = ConvertTo-GraphDate ((Get-Date).ToUniversalTime().AddDays($d.Days))
                $modeUp = "$(Get-EntraCtx 'Mode')".ToUpperInvariant()
                $nm = 'Cloudiway-{0}-P{1} {2:yyyy-MM-dd}' -f $modeUp, (Get-EntraCtx 'ProjectId'), (Get-Date)
                $r = Invoke-EntraRetry { Invoke-GraphPost "/applications/$oid/addPassword" @{ passwordCredential = @{ displayName = $nm; endDateTime = $end } } }
                if (-not $r.secretText) { throw 'reponse sans valeur de secret' }
                $cred['ClientSecret'] = "$($r.secretText)"
                $cred['SecretKeyId'] = "$($r.keyId)"
                $cred['SecretNotAfter'] = (ConvertTo-EntraDate $r.endDateTime)
                Write-RunLog ("Secret client ajoute : keyId {0}, expire le {1:yyyy-MM-dd}" -f $r.keyId, (ConvertTo-EntraDate $r.endDateTime))
                return $true
            }

            'CleanupCerts' {
                # Retire les ANCIENS certificats crees par l'outil, apres l'ecriture reussie du connecteur, par POST /applications/{id}/removeKey
                # { keyId, proof } (le PATCH keyCredentials qui retire des cles est refuse par Graph : "KeyValue cannot be null or empty").
                # La preuve est un JWT signe par la cle privee du NOUVEAU certificat (deja ajoute et verifie visible), jamais journalise.
                # Echec isole par cle, non bloquant : le nouveau certificat est deja en place et transmis.
                $oid = "$($created['AppObjectId'])"
                if (-not $oid) { throw 'application indisponible (etape precedente en echec)' }
                $newThumb = "$($cred['CertThumbprint'])".ToUpperInvariant()
                if (-not $newThumb) { $script:EntraLastError = 'nettoyage refuse : aucun nouveau certificat n''a ete genere dans ce passage. Aucune cle retiree.'; return $false }
                if (-not [bool](Get-EntraCtx 'ConnectorWriteOk')) { $script:EntraLastError = 'nettoyage refuse : l''ecriture du connecteur Cloudiway n''est pas confirmee dans ce passage (le connecteur doit porter le nouveau certificat avant tout retrait). Aucune cle retiree.'; return $false }   # GARDE-CONNECTEUR
                $prefix = Get-ToolKeyPrefix
                $cur = Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,keyCredentials' -f $oid) }
                $before = @($cur.keyCredentials)
                if (@($before | Where-Object { (ConvertTo-HexThumbprint $_.customKeyIdentifier) -eq $newThumb }).Count -eq 0) {
                    $script:EntraLastError = "nettoyage refuse : le nouveau certificat ($newThumb) n'est pas visible dans l'application. Aucune cle retiree."
                    return $false
                }
                $old = @($before | Where-Object { (Test-ToolKeyName $_.displayName $prefix) -and (ConvertTo-HexThumbprint $_.customKeyIdentifier) -ne $newThumb })
                if ($old.Count -eq 0) { Write-RunLog 'Nettoyage des certificats : aucun ancien certificat de l''outil'; return $true }
                if (-not $cred['PfxBytes'] -or -not $cred['PfxPassword']) { $script:EntraLastError = 'nettoyage refuse : le nouveau certificat (cle privee de la preuve de possession) n''est plus disponible en memoire. Aucune cle retiree.'; return $false }
                $oldIds = @($old | ForEach-Object { "$($_.keyId)" })
                $keepIds = @($before | Where-Object { $oldIds -notcontains "$($_.keyId)" } | ForEach-Object { "$($_.keyId)" })
                $info = [System.Collections.Generic.List[string]]::new()
                $errs = [System.Collections.Generic.List[string]]::new()
                $failedIds = [System.Collections.Generic.List[string]]::new()
                foreach ($k0 in $old) {
                    $line = 'certificat keyId={0} empreinte={1} fin={2}' -f $k0.keyId, (ConvertTo-HexThumbprint $k0.customKeyIdentifier), $k0.endDateTime
                    Write-RunLog ("Nettoyage : retrait de l'ancien " + $line + ' (removeKey, preuve signee par le nouveau certificat)')
                    $proof = $null; $prf = $null
                    try {
                        $proof = New-KeyRemovalProof -PfxBytes ([byte[]]$cred['PfxBytes']) -PfxPassword "$($cred['PfxPassword'])" -AppObjectId $oid
                        $kid = "$($k0.keyId)"; $prf = $proof
                        $rk = Invoke-RemoveKey -AppObjectId $oid -KeyId $kid -Proof $prf
                        $info.Add($(if ($rk -eq 'AlreadyGone') { $line + ' (deja absente : comptee comme retiree)' } else { $line }))
                    }
                    catch {
                        $em = Get-ErrMsg $_
                        $errs.Add(("{0} : {1}" -f $k0.keyId, $em)); $failedIds.Add("$($k0.keyId)")
                        # Diagnostic : message d'erreur renvoye (HTTP + texte Graph ; jamais le jeton de preuve) et type de l'exception locale.
                        Write-RunLog ("removeKey {0} : ECHEC [{1}] {2}" -f $k0.keyId, $_.Exception.GetType().Name, $em)
                        try { $raw = Get-GraphErrText $_; if ($raw) { Write-RunLog ("removeKey {0} : detail Graph : {1}" -f $k0.keyId, ($raw -replace '\s+', ' ')) } } catch { }
                    }
                    finally { $proof = $null; $prf = $null }
                }
                # REPLI (constate en reel le 2026-11-03 : removeKey repond 403 « Insufficient privileges » pour toutes les cles) : si TOUS les retraits
                # ont ete refuses avec un 403 et qu'il n'existe aucune cle hors outil a preserver, PATCH keyCredentials ne gardant que le NOUVEAU
                # certificat avec son contenu public (c'est l'absence de contenu qui avait fait echouer l'ancien PATCH : « KeyValue cannot be null or empty »).
                # Echec du PATCH : rien ne change (les anciennes cles restent) et l'echec est signale comme avant.
                if ($failedIds.Count -gt 0 -and $failedIds.Count -eq $old.Count -and @($errs | Where-Object { $_ -match '403|Authorization_RequestDenied|Insufficient privileges' }).Count -eq $errs.Count) {
                    $others = @($before | Where-Object { $oldIds -notcontains "$($_.keyId)" -and (ConvertTo-HexThumbprint $_.customKeyIdentifier) -ne $newThumb })
                    $newKey = @($before | Where-Object { (ConvertTo-HexThumbprint $_.customKeyIdentifier) -eq $newThumb }) | Select-Object -First 1
                    if ($others.Count -eq 0 -and $newKey) {
                        Write-RunLog 'Nettoyage : removeKey refuse (403) ; repli par PATCH keyCredentials ne gardant que le nouveau certificat (contenu public fourni).'
                        try {
                            $entry = ConvertTo-KeepKeyEntry $newKey
                            $entry['key'] = Get-PfxPublicBase64 -PfxBytes ([byte[]]$cred['PfxBytes']) -PfxPassword "$($cred['PfxPassword'])"
                            [void](Invoke-EntraRetry { Invoke-GraphPatch "/applications/$oid" @{ keyCredentials = @($entry) } })
                            foreach ($k0 in $old) { $info.Add(('certificat keyId={0} empreinte={1} fin={2} (retire par PATCH)' -f $k0.keyId, (ConvertTo-HexThumbprint $k0.customKeyIdentifier), $k0.endDateTime)) }
                            $errs.Clear(); $failedIds.Clear()
                            Write-RunLog 'Nettoyage : repli par PATCH accepte.'
                        }
                        catch { Write-RunLog ("Nettoyage : repli par PATCH refuse : " + (Get-ErrMsg $_)); $errs.Add('repli PATCH : ' + (Get-ErrMsg $_)) }
                    }
                    else { Write-RunLog 'Nettoyage : repli par PATCH non applique (cle hors outil a preserver ou nouveau certificat introuvable).' }
                }
                # Relecture : toutes les anciennes cles de l'outil ont disparu (propagation : jusqu'a ~45 s), le nouveau certificat et les cles
                # non outil sont presents.
                $after = @(); $gone = $false
                foreach ($w in 0, 2, 4, 8, 12, 18) {
                    if ($w -gt 0) { Start-Sleep -Seconds $w }
                    $after = @((Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,keyCredentials' -f $oid) }).keyCredentials)
                    $afterIds = @($after | ForEach-Object { "$($_.keyId)" })
                    $gone = (@($oldIds | Where-Object { $afterIds -contains $_ }).Count -eq 0)
                    if ($gone -or $errs.Count -gt 0) { break }
                    Write-RunLog 'Nettoyage : anciens certificats encore visibles (propagation), nouvelle lecture...'
                }
                $afterIds = @($after | ForEach-Object { "$($_.keyId)" })
                $rem = Get-EntraBag 'Created'
                $lst = [System.Collections.Generic.List[string]]::new(); if ($rem['CleanupRemoved']) { foreach ($x in @($rem['CleanupRemoved'])) { $lst.Add("$x") } }
                foreach ($x in $info) { $lst.Add($x) }
                $rem['CleanupRemoved'] = @($lst.ToArray())
                $lost = @($keepIds | Where-Object { $afterIds -notcontains $_ })
                if ($lost.Count -gt 0) {
                    $script:EntraLastError = "ATTENTION : $($lost.Count) cle(s) qui devaient etre conservee(s) ont DISPARU apres removeKey (keyId : " + ($lost -join ', ') + "). Verifier l'application dans le portail Entra." + $cleanTail
                    Write-RunLog $script:EntraLastError
                    return $false
                }
                if (@($after | Where-Object { (ConvertTo-HexThumbprint $_.customKeyIdentifier) -eq $newThumb }).Count -eq 0) {
                    $script:EntraLastError = "ATTENTION : le nouveau certificat ($newThumb) n'apparait plus dans l'application apres le nettoyage. Verifier l'application dans le portail Entra." + $cleanTail
                    Write-RunLog $script:EntraLastError
                    return $false
                }
                if ($errs.Count -gt 0) { throw ('{0} ancien(s) certificat(s) non retire(s) (keyId restants : {1}) : {2}' -f $errs.Count, ($failedIds -join ', '), ($errs -join ' ; ')) }
                if (-not $gone) { throw ('des anciens certificats de l''outil apparaissent encore dans l''application apres removeKey (propagation ?) : keyId ' + ((@($oldIds | Where-Object { $afterIds -contains $_ })) -join ', ')) }
                Set-EntraCtx 'CleanupCertsDone' $true
                $script:EntraApplyNote = ('{0} ancien(s) certificat(s) retire(s) : {1}' -f $old.Count, ($info -join ' ; '))
                return $true
            }

            'CleanupSecrets' {
                $oid = "$($created['AppObjectId'])"
                if (-not $oid) { throw 'application indisponible (etape precedente en echec)' }
                $newKid = ConvertTo-KeyToken "$($cred['SecretKeyId'])"
                if (-not $newKid) { $script:EntraLastError = 'nettoyage refuse : aucun nouveau secret client n''a ete genere dans ce passage. Aucun secret retire.'; return $false }
                if (-not [bool](Get-EntraCtx 'ConnectorWriteOk')) { $script:EntraLastError = 'nettoyage refuse : l''ecriture du connecteur Cloudiway n''est pas confirmee dans ce passage (le connecteur doit porter le nouveau secret avant tout retrait). Aucun secret retire.'; return $false }   # GARDE-CONNECTEUR
                $prefix = Get-ToolKeyPrefix
                # Propagation Entra (constate en reel le 2026-11-03 a la relance) : le secret ajoute quelques secondes plus tot peut ne pas etre encore
                # lisible ; relire avec attente, comme pour les certificats, avant de conclure qu'il est absent.
                $before = @()
                foreach ($w in 0, 2, 4, 8, 12, 18) {
                    if ($w -gt 0) { Start-Sleep -Seconds $w }
                    $cur = Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,passwordCredentials' -f $oid) }
                    $before = @($cur.passwordCredentials)
                    if (@($before | Where-Object { (ConvertTo-KeyToken $_.keyId) -eq $newKid }).Count -gt 0) { break }
                    Write-RunLog 'Nettoyage des secrets : nouveau secret pas encore visible (propagation), nouvelle lecture...'
                }
                if (@($before | Where-Object { (ConvertTo-KeyToken $_.keyId) -eq $newKid }).Count -eq 0) {
                    $script:EntraLastError = 'nettoyage refuse : le nouveau secret client n''est pas visible dans l''application. Aucun secret retire.'
                    return $false
                }
                $old = @($before | Where-Object { (Test-ToolKeyName $_.displayName $prefix) -and (ConvertTo-KeyToken $_.keyId) -ne $newKid })
                if ($old.Count -eq 0) { Write-RunLog 'Nettoyage des secrets : aucun ancien secret client de l''outil'; return $true }
                $info = [System.Collections.Generic.List[string]]::new()
                $errs = [System.Collections.Generic.List[string]]::new()
                foreach ($k0 in $old) {
                    $line = 'secret client keyId={0} fin={1}' -f $k0.keyId, $k0.endDateTime
                    Write-RunLog ("Nettoyage : retrait de l'ancien " + $line)
                    try { [void](Invoke-GraphPost "/applications/$oid/removePassword" @{ keyId = "$($k0.keyId)" }); $info.Add($line) }
                    catch { $errs.Add(("{0} : {1}" -f $k0.keyId, (Get-ErrMsg $_))) }
                }
                $oldIds = @($old | ForEach-Object { "$($_.keyId)" })
                $after = @(); $gone = $false
                foreach ($w in 0, 2, 4, 8, 12, 18) {
                    if ($w -gt 0) { Start-Sleep -Seconds $w }
                    $after = @((Invoke-EntraRetry { Invoke-GraphGet ('/applications/{0}?$select=id,passwordCredentials' -f $oid) }).passwordCredentials)
                    $afterIds = @($after | ForEach-Object { "$($_.keyId)" })
                    $gone = (@($oldIds | Where-Object { $afterIds -contains $_ }).Count -eq 0)
                    if ($gone -or $errs.Count -gt 0) { break }
                }
                if (@($after | Where-Object { (ConvertTo-KeyToken $_.keyId) -eq $newKid }).Count -eq 0) {
                    $script:EntraLastError = 'ATTENTION : le nouveau secret client n''apparait plus dans l''application apres le nettoyage. Verifier l''application dans le portail Entra.' + $cleanTail
                    Write-RunLog $script:EntraLastError
                    return $false
                }
                $rem = Get-EntraBag 'Created'
                $lst = [System.Collections.Generic.List[string]]::new(); if ($rem['CleanupRemoved']) { foreach ($x in @($rem['CleanupRemoved'])) { $lst.Add("$x") } }
                foreach ($x in $info) { $lst.Add($x) }
                $rem['CleanupRemoved'] = @($lst.ToArray())
                if ($errs.Count -gt 0) {
                    # removePassword refuse (403) : contrairement aux certificats (repli par PATCH), les secrets n'ont AUCUN repli (passwordCredentials n'est pas modifiable par PATCH).
                    $hint403 = ''
                    if (@($errs | Where-Object { $_ -match '403|Authorization_RequestDenied|Insufficient privileges' }).Count -eq $errs.Count) { $hint403 = ' removePassword est refuse (403) et aucun repli par PATCH n''existe pour les secrets : retirer ces secrets a la main dans Entra (Inscriptions d''applications > Certificats et secrets). Le nouveau secret est en place et transmis.' }
                    throw ('{0} secret(s) non retire(s) : {1}{2}' -f $errs.Count, ($errs -join ' ; '), $hint403)
                }
                if (-not $gone) { throw 'les anciens secrets de l''outil apparaissent encore dans l''application apres removePassword (propagation ?)' }
                Set-EntraCtx 'CleanupSecretsDone' $true
                $script:EntraApplyNote = ('{0} ancien(s) secret(s) client retire(s) : {1}' -f $old.Count, ($info -join ' ; '))
                return $true
            }

            'SaCreate' {
                $pass = New-StrongPassword
                $local = "$($d.Upn)".Split('@')[0]
                $nick = ($local -replace '[^A-Za-z0-9._-]', '')
                if (-not $nick) { $nick = 'svc-cloudiway' }
                $body = @{
                    accountEnabled = $true; displayName = $d.DisplayName; mailNickname = $nick; userPrincipalName = $d.Upn
                    passwordProfile = @{ password = $pass; forceChangePasswordNextSignIn = $false }
                    passwordPolicies = 'DisablePasswordExpiration'; employeeType = $script:EntraTag
                }
                $r = Invoke-GraphPost '/users' $body
                if (-not $r.id) { throw 'reponse sans identifiant' }
                $created['ServiceAccountUpn'] = "$($r.userPrincipalName)"; $created['ServiceAccountObjectId'] = "$($r.id)"
                $cred['ServiceAccountPassword'] = $pass
                Write-RunLog ("Compte de service cree : {0}" -f $r.userPrincipalName)
                return $true
            }

            'SaPatch' {
                # Compte etiquete (ou adopte : etiquetage). JAMAIS de mot de passe ici (voir SaPwdReset). passwordPolicies : FUSION avec les
                # strategies existantes (DisableStrongPassword n'est jamais retire) ; aucune ecriture de cette cle si DisablePasswordExpiration est deja la.
                $body = @{}
                $curPol = @("$($d.Policies)" -split '[,;\s]+' | Where-Object { $_ })
                if ($curPol -notcontains 'DisablePasswordExpiration') {
                    $body['passwordPolicies'] = ((@($curPol) + 'DisablePasswordExpiration') | Select-Object -Unique) -join ', '
                }
                if ($d.Mark) { $body['employeeType'] = $script:EntraTag }
                if ($body.Count -gt 0) { [void](Invoke-GraphPatch "/users/$($d.UserId)" $body) }
                return $true
            }

            'SaPwdReset' {
                # v2.5 (D) : reinitialisation dans Entra D'ABORD. Le mot de passe n'est depose dans les identifiants en memoire (donc envoye au connecteur)
                # QUE si Entra l'a accepte. Refus (typiquement HTTP 403 : compte qui detient un role d'administrateur) : aucun mot de passe n'est conserve,
                # le connecteur ne recoit rien et n'est pas modifie (voir Invoke-CiwApplyConnector), l'ancien certificat n'est pas retire.
                $pass = New-StrongPassword
                try {
                    [void](Invoke-GraphPatch "/users/$($d.UserId)" @{ passwordProfile = @{ password = $pass; forceChangePasswordNextSignIn = $false } })
                }
                catch {
                    $pass = $null
                    $cred.Remove('ServiceAccountPassword')
                    Set-EntraCtx 'ServiceAccountResetFailed' $true
                    $script:EntraLastError = ("le mot de passe du compte de service n'a pas pu etre change dans Entra ({0}) : le connecteur garde l'ancien mot de passe et n'est PAS modifie (aucun nouveau mot de passe ni nouveau certificat ne lui est envoye ; le nouveau certificat deja ajoute a l'application est conserve pour la relance, l'ancien n'est pas retire). Relancer avec -KeepCredentials n'y change rien : reinitialisez le mot de passe du compte de service a la main (centre d'administration Microsoft Entra), puis ressaisissez-le dans le portail Cloudiway (champ du compte de migration du connecteur)." -f (Get-ErrMsg $_))
                    Write-RunLog $script:EntraLastError
                    return $false
                }
                $cred['ServiceAccountPassword'] = $pass
                Set-EntraCtx 'ServiceAccountResetDone' $true
                Write-RunLog 'Mot de passe du compte de service reinitialise dans Entra (avant l''ecriture du connecteur)'
                return $true
            }

            default { throw "type d'action inconnu : $($d.Kind)" }
        }
    }
    catch {
        $script:EntraLastError = Get-ErrMsg $_
        if ("$($d.Kind)" -like 'Cleanup*') { $script:EntraLastError = 'Nettoyage non termine : ' + $script:EntraLastError + $cleanTail }
        # Conseil quand une strategie du tenant refuse l'operation (acces conditionnel, valeurs de securite par defaut, strategie d'attribution...)
        if ($script:EntraLastError -match 'not allowed as per assigned policy') {
            $script:EntraLastError += ' | CONSEIL : une strategie du tenant refuse cette operation (acces conditionnel, valeurs de securite par defaut, ou strategie d''attribution / de creation d''utilisateurs). Verifier dans Entra > Securite > Acces conditionnel et Proprietes > Gerer les valeurs de securite par defaut, ou l''exclusion du compte administrateur, puis relancer.'
        }
        Write-RunLog ("Apply {0} ({1}) : ECHEC {2}" -f $Key, $d.Kind, $script:EntraLastError)
        # Un identifiant dont l'ecriture a echoue ne doit jamais partir vers le connecteur.
        try {
            switch ($d.Kind) {
                'CertCreate' { Clear-EntraCredentials 'Cert' }
                'SecretCreate' { Clear-EntraCredentials 'Secret' }
                { $_ -in 'SaCreate', 'SaPatch' } { Clear-EntraCredentials 'ServiceAccount' }
            }
        } catch { }
        return $false
    }
}

# ----------------------------------------------------------------------------------------------
# Verification (relecture)
# ----------------------------------------------------------------------------------------------

function Test-EntraCompliance {
    param($State = $null)
    $rows = [System.Collections.Generic.List[object]]::new()
    $row = { param($n, $ok, $detail) $rows.Add([pscustomobject]@{ Name = $n; Status = $(if ($ok) { 'OK' } else { 'KO' }); Detail = $detail }) }
    try {
        if ($null -eq $State) { $State = Get-EntraState }
        $app = $State.App
        $desired = Get-EntraDesired $State
        & $row 'Application' ([bool]($app -and $State.AppTagged)) $(if ($app) { if ($State.AppTagged) { "AppId $($app.appId)" } else { 'presente mais sans l''etiquette CloudiwayConnector' } } else { 'application absente' })
        & $row 'Principal de service' ([bool]$State.Sp) $(if ($State.Sp) { "$($State.Sp.id)" } else { 'absent' })

        # Client public (seulement si un compte de service est necessaire) et URI de redirection (Teams en Source)
        if ([bool](Get-EntraCtx 'NeedServiceAccount')) {
            $pub = [bool]($app -and $app.isFallbackPublicClient -eq $true)
            & $row 'Client public' $pub $(if ($pub) { 'flux client public actif (compte de service)' } else { 'isFallbackPublicClient non active' })
        }
        $wantUris = @(Get-WantedRedirectUris)
        if ($wantUris.Count -gt 0) {
            $haveUris = if ($app) { @(Get-AppRedirectUris $app) } else { @() }
            $missU = @($wantUris | Where-Object { $u = $_; -not (@($haveUris | Where-Object { "$_" -ieq $u }).Count -gt 0) })
            & $row 'URI de redirection' ($missU.Count -eq 0) $(if ($missU.Count -eq 0) { "{0} URI Cloudiway declaree(s)" -f $wantUris.Count } else { 'manquante(s) : ' + ($missU -join ', ') })
        }

        # Permissions declarees
        $existing = if ($app) { @($app.requiredResourceAccess) } else { @() }
        $m = Merge-RequiredResourceAccess -Existing $existing -Resolved $desired.Resolved
        $pend = @($desired.PendingResources)
        $permOk = ($app -and $m.Added -eq 0 -and @($desired.Unresolved).Count -eq 0 -and $pend.Count -eq 0)
        $pd = if (-not $app) { 'application absente' } elseif ($m.Added -gt 0) { "$($m.Added) entree(s) manquante(s)" } elseif (@($desired.Unresolved).Count -gt 0) { 'non resolues : ' + ($desired.Unresolved -join ' ; ') } elseif ($pend.Count -gt 0) { 'principal de service de ressource absent : ' + ($pend -join ', ') } else { 'completes' }
        & $row 'Permissions declarees' $permOk $pd
        if (@($desired.OptionalSkipped).Count -gt 0) { & $row 'Permissions optionnelles' $true ('ignoree : non publiee par la ressource : ' + ($desired.OptionalSkipped -join ' ; ')) }

        # Consentement
        foreach ($k in $script:ResourceAppIds.Keys) {
            $res = $State.Resources[$k]
            $apps = @($desired.Resolved | Where-Object { $_.Resource -eq $k -and $_.Type -eq 'Application' })
            $dels = @($desired.Resolved | Where-Object { $_.Resource -eq $k -and $_.Type -eq 'Delegated' })
            if (($apps.Count + $dels.Count) -eq 0) { continue }
            $miss = @($apps | Where-Object { $rid = $_.Id; @($State.AppRoleGrants | Where-Object { "$($_.resourceId)" -eq $res.SpId -and "$($_.appRoleId)" -ieq $rid }).Count -eq 0 })
            $grant = @($State.Oauth2Grants | Where-Object { "$($_.resourceId)" -eq $res.SpId -and "$($_.consentType)" -eq 'AllPrincipals' }) | Select-Object -First 1
            $have = if ($grant) { @("$($grant.scope)" -split '\s+' | Where-Object { $_ }) } else { @() }
            $missS = @($dels | Where-Object { -not (Test-ScopeIn $have $_.Name) })
            $ok = ($State.Sp -and $miss.Count -eq 0 -and $missS.Count -eq 0)
            $dt = if ($ok) { "{0} role(s), {1} portee(s) accordes" -f $apps.Count, $dels.Count } else { "manquants : {0} role(s) ({1}) ; {2} portee(s) ({3})" -f $miss.Count, (($miss | ForEach-Object Name) -join ', '), $missS.Count, (($missS | ForEach-Object Name) -join ', ') }
            & $row "Consentement $k" ([bool]$ok) $dt
        }

        # Roles Entra
        $mode = "$(Get-EntraCtx 'Mode')"; $wl = @(Get-EntraCtx 'Workloads')
        foreach ($r in @(Get-RequiredEntraRoles -Mode $mode -Workloads $wl | Where-Object Target -EQ 'ServicePrincipal')) {
            $has = (@($State.EntraRoles | Where-Object { $_ -ieq $r.TemplateId }).Count -gt 0)
            & $row "Role $($r.Name)" $has $(if ($has) { 'attribue au principal de service' } else { 'non attribue' })
        }

        # Identifiants : certificat et/ou secret client (coherents avec la decision de renouvellement)
        if (-not [bool](Get-EntraCtx 'SkipCloudiway')) {
            $auth = Get-EntraAuthMethod
            $now = (Get-Date).ToUniversalTime()
            $cr = Get-EntraCtx 'Credentials'
            $marker = $null
            $ex = Get-EntraCtx 'ExistingConnector'
            if ($ex -and (Get-Command Get-ConnectorMarker -ErrorAction SilentlyContinue)) { try { $marker = Get-ConnectorMarker -Connector $ex } catch { } }
            if ($auth -in 'Certificate', 'Both') {
                $valid = @($State.KeyCredentials | Where-Object { (ConvertTo-EntraDate $_.endDateTime) -gt $now })
                $want = if ($cr -is [System.Collections.IDictionary] -and $cr['CertThumbprint']) { "$($cr['CertThumbprint'])".ToUpperInvariant() } elseif ($marker -and $marker.Thumbprint) { ConvertTo-KeyToken $marker.Thumbprint } else { '' }
                $hasWant = if ($want) { @($valid | Where-Object { ([string](ConvertTo-HexThumbprint $_.customKeyIdentifier)).StartsWith($want) }).Count -gt 0 } else { $true }
                $cd = if ($valid.Count -eq 0) { 'aucun certificat valide dans l''application' } elseif (-not $hasWant) { "empreinte $want absente de l'application" } else { "{0} certificat(s) valide(s) dans l'application" -f $valid.Count }
                & $row 'Certificat' ($valid.Count -gt 0 -and $hasWant) $cd
                if ([bool](Get-EntraCtx 'CleanupCertsDone')) {
                    $toolNow = @($State.KeyCredentials | Where-Object { Test-ToolKeyName $_.displayName (Get-ToolKeyPrefix) })
                    & $row 'Un seul certificat de l''outil' ($toolNow.Count -eq 1) ("{0} certificat(s) de l'outil dans l'application apres le nettoyage" -f $toolNow.Count)
                }
            }
            if ($auth -in 'Secret', 'Both') {
                $validS = @($State.PasswordCredentials | Where-Object { (ConvertTo-EntraDate $_.endDateTime) -gt $now })
                $wantId = if ($cr -is [System.Collections.IDictionary] -and $cr['SecretKeyId']) { ConvertTo-KeyToken $cr['SecretKeyId'] } else { '' }
                $hasS = if ($wantId) { @($validS | Where-Object { (ConvertTo-KeyToken $_.keyId) -eq $wantId }).Count -gt 0 } else { $true }
                $sd = if ($validS.Count -eq 0) { 'aucun secret client valide dans l''application' } elseif (-not $hasS) { 'le secret genere est absent de l''application' } else { "{0} secret(s) client valide(s) dans l'application" -f $validS.Count }
                & $row 'Secret client' ($validS.Count -gt 0 -and $hasS) $sd
            }
        }

        # Compte de service
        if ([bool](Get-EntraCtx 'NeedServiceAccount')) {
            $u = $State.ServiceAccount
            & $row 'Compte de service' ([bool]$u) $(if ($u) { "$($u.userPrincipalName)" } else { 'absent' })
            if ($u) { & $row 'Etiquette du compte de service' ("$($u.employeeType)" -eq $script:EntraTag) $(if ("$($u.employeeType)" -eq $script:EntraTag) { 'employeeType = CloudiwayConnector' } else { 'compte non etiquete (adoption non appliquee)' }) }
            foreach ($r in @(Get-RequiredEntraRoles -Mode $mode -Workloads $wl -WithoutServiceAccount:([bool](Get-EntraCtx 'WithoutServiceAccount')) | Where-Object Target -EQ 'ServiceAccount')) {
                $has = ($u -and @($State.ServiceAccountRoles | Where-Object { $_ -ieq $r.TemplateId }).Count -gt 0)
                & $row "Role $($r.Name) du compte de service" ([bool]$has) $(if ($has) { 'attribue' } else { 'non attribue' })
            }
        }
    }
    catch {
        $msg = Get-ErrMsg $_
        Write-RunLog ("Test-EntraCompliance : {0}" -f $msg)
        $rows.Add([pscustomobject]@{ Name = 'Verification'; Status = 'KO'; Detail = "Relecture impossible : $msg" })
    }
    return $rows.ToArray()
}
