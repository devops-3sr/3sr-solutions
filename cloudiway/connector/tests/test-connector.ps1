#Requires -Version 7.2
<#
.SYNOPSIS
    Banc de test HORS LIGNE de CloudiwayConnector (mode Source, Mail et OneDrive) : le VRAI script principal cloudiway-connector.ps1 et les VRAIS modules lib\*.ps1
    contre un FAUX tenant Microsoft 365 en memoire et un FAUX portail Cloudiway (tests\mocks.ps1). Aucune connexion, aucun appel reseau.
.DESCRIPTION
    Usage : pwsh -NoProfile -File tests\test-connector.ps1 [-KeepOutput]
    Ecrit uniquement dans un dossier temporaire de session (supprime a la fin sauf -KeepOutput), jamais dans le package.
    Code de sortie = nombre d'assertions en echec.
    Si l'entree standard est redirigee (agent, CI), le banc se relance lui-meme dans une console masquee pour que les saisies masquees
    (mot de passe Cloudiway, mode questions) voient une console interactive ; le rapport est alors relaye ici.
    Mot de passe Cloudiway du DSI : fourni par un Read-Host simule (file de reponses, SecureString), jamais en parametre.
#>
param([switch]$KeepOutput, [switch]$InnerRun, [string]$ResultFile, [string]$PackageRoot)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

if (-not $InnerRun -and [Console]::IsInputRedirected) {
    $rf = Join-Path ([System.IO.Path]::GetTempPath()) ('cwconn-result-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $pwshExe = (Get-Process -Id $PID).Path
    $argl = @('-NoProfile', '-File', "`"$PSCommandPath`"", '-InnerRun', '-ResultFile', "`"$rf`"")
    if ($KeepOutput) { $argl += '-KeepOutput' }
    if ($PackageRoot) { $argl += @('-PackageRoot', "`"$PackageRoot`"") }
    $p = Start-Process -FilePath $pwshExe -ArgumentList $argl -WindowStyle Hidden -Wait -PassThru
    if (Test-Path -LiteralPath $rf) { Get-Content -LiteralPath $rf -Raw -Encoding utf8 | Write-Host; Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue; exit $p.ExitCode }
    Write-Host 'Console masquee indisponible : execution directe (les tests qui exigent une console interactive sont ignores).' -ForegroundColor Yellow
}

$pkg = if ($PackageRoot) { $PackageRoot } else { Split-Path -Parent $PSScriptRoot }   # -PackageRoot : banc contre une COPIE du package
$main = Join-Path $pkg 'cloudiway-connector.ps1'
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cwconn-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$report = [System.Text.StringBuilder]::new()
function Say([string]$Line = '', [string]$Color = '') {
    [void]$report.AppendLine($Line)
    if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line }
}

. (Join-Path $PSScriptRoot 'mocks.ps1')

# Garde-fou : tout ce qui se connecte ou touche le reseau doit etre un stub (Function)
$mustBeStub = 'Connect-MgGraph', 'Invoke-MgGraphRequest', 'Get-MgContext', 'Disconnect-MgGraph', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Import-Module',
'Get-Module', 'Install-Module', 'Read-Host', 'Start-Sleep', 'Get-PSRepository', 'Set-PSRepository', 'Get-PackageProvider', 'Install-PackageProvider',
'Connect-ExchangeOnline', 'Get-OrganizationConfig', 'Set-OrganizationConfig', 'Disconnect-ExchangeOnline'
$notStub = @($mustBeStub | Where-Object { (Get-Command $_ -ErrorAction SilentlyContinue | Select-Object -First 1).CommandType -ne 'Function' })
if ($notStub.Count) { Say "ARRET : commandes non simulees (risque de connexion reelle) : $($notStub -join ', ')" Red; exit 99 }

# ---------------------------------------------------------------------------------------------------
# Resultats
# ---------------------------------------------------------------------------------------------------
$Results = [System.Collections.Generic.List[object]]::new()
function T([string]$Point, [string]$Name, $Ok, [string]$Detail = '') {
    $Results.Add([pscustomobject]@{ Point = $Point; Test = $Name; Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Detail = $(if ($Ok) { '' } else { $Detail }) })
}
function Skip([string]$Point, [string]$Name, [string]$Why) { $Results.Add([pscustomobject]@{ Point = $Point; Test = $Name; Result = 'SKIP'; Detail = $Why }) }

# ---------------------------------------------------------------------------------------------------
# Constantes (noms codifies v2)
# ---------------------------------------------------------------------------------------------------
$PatSecure = New-TestSecure $global:MockPat
$AppSrc = 'CLOUDIWAY-SOURCE-P12345'
$ConnSrc = 'contoso-source'
$tempDir = [System.IO.Path]::GetTempPath()

function New-Base([string]$Tag) { $d = Join-Path $tmpRoot $Tag; New-Item -ItemType Directory -Path $d -Force | Out-Null; $d }

# Appel v2 : -Mode -Tenant <domaine> -Admin365 -Cloudiway <email> ; mot de passe Cloudiway saisi par Read-Host (file de reponses)
function Get-BaseParams([string]$Base, [string[]]$Workloads = @('Mail', 'OneDrive'), [string]$Mode = 'Source') {
    @{ Mode = $Mode; Tenant = 'contoso.onmicrosoft.com'; Admin365 = $global:MockUser; Cloudiway = $global:MockCwLogin; Workloads = $Workloads; Yes = $true; OutDir = $Base }
}
# Variante PAT : -CloudiwayPat (SecureString) a la place de -Cloudiway
function Use-Pat([hashtable]$P) { $P.Remove('Cloudiway'); $P['CloudiwayPat'] = $PatSecure; $P }
# v2.3 : le renouvellement des identifiants est le DEFAUT. Un passage qui doit etre idempotent (zero ecriture) utilise -KeepCredentials.
function Keep([hashtable]$P) { $c = $P.Clone(); $c.Remove('RotateCredentials'); $c.Remove('RotateCertificate'); $c['KeepCredentials'] = $true; $c }

$allSecretValues = [System.Collections.Generic.List[string]]::new()   # valeurs sensibles collectees (balayage final)
$allBases = [System.Collections.Generic.List[string]]::new()
$allConsoles = [System.Collections.Generic.List[string]]::new()

function Add-Secret($V) { if ($V -is [string] -and $V.Length -ge 8 -and -not $allSecretValues.Contains($V)) { $allSecretValues.Add($V) } }
# Releve, dans le faux Cloudiway et le faux tenant, toutes les valeurs sensibles recues pendant le passage
function Get-Settings($Conn) { if ($Conn -and $Conn.rawSettings) { try { $Conn.rawSettings | ConvertFrom-Json } catch { $null } } }
function Update-Secrets {
    foreach ($c in @($global:MockCiw.Connectors)) {
        $b = $c._body
        if ($b) {
            $cc = $b.connectorCertificate
            if ($cc) { Add-Secret "$($cc.secret)"; Add-Secret "$($cc.certificateFile)" }
            $raw = if ($b.ContainsKey('rawsettings')) { $b.rawsettings } else { $b.rawSettings }
            if ($raw -is [string]) { try { $st = $raw | ConvertFrom-Json; Add-Secret "$($st.MigrationAccountPassword)"; Add-Secret "$($st.RestClientSecret)" } catch { } }
        }
    }
    foreach ($u in @($global:MockTenant.Users)) { Add-Secret "$($u.PwdMarker)" }
    foreach ($v in @($global:MockTenant.Secrets.Values)) { Add-Secret "$v" }
    foreach ($v in @($global:MockTenant.ProofTokens)) { Add-Secret "$v" }   # v2.3 : jetons de preuve de possession (removeKey), jamais journalises
}
Add-Secret $global:MockCwPassword; Add-Secret $global:MockPat

# ---------------------------------------------------------------------------------------------------
# Pilotage du script principal
# ---------------------------------------------------------------------------------------------------
function Get-TempPfx { @(Get-ChildItem -LiteralPath $tempDir -Filter 'ciw-*.pfx' -File -ErrorAction SilentlyContinue | ForEach-Object FullName) }

# Lance le VRAI script ; retourne Exit, Console, Calls, compteurs d'ecritures, dossiers de sortie. -Queue : reponses simulees de Read-Host
# (defaut : le mot de passe Cloudiway du DSI, sauf si -CloudiwayPat ou -SkipCloudiway est utilise).
function Invoke-Connector([hashtable]$P, [string]$Base, $Queue = $null) {
    $from = $global:MockCalls.Count
    $t0 = (Microsoft.PowerShell.Utility\Get-Date).AddSeconds(-1)
    $before = @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
    $tmpBefore = Get-TempPfx
    $global:MockReadQueue.Clear(); $global:MockReadLog.Clear(); $global:MockReadExhausted = $false
    if ($null -ne $Queue) { foreach ($q in @($Queue)) { $global:MockReadQueue.Enqueue($q) } }
    elseif (-not $P.ContainsKey('CloudiwayPat') -and -not $P['SkipCloudiway']) { $global:MockReadQueue.Enqueue($global:MockCwPassword) }
    $global:LASTEXITCODE = -999
    $console = ''; $crash = ''
    $global:Error.Clear()
    try { $console = (& $main @P *>&1 | Out-String) }
    catch { $crash = "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"; $console += "`n[CRASH] $crash" }
    $errCount = $global:Error.Count   # $Error juste apres le run (Stop-Run doit l'avoir vide)
    $code = $global:LASTEXITCODE
    $calls = @($global:MockCalls | Select-Object -Skip $from)
    # Dossier de sortie du passage : nouveau dossier, OU dossier existant dont un fichier a ete (re)ecrit pendant le passage (meme minute que le precedent)
    $dirs = @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notin $before } | Sort-Object CreationTime)
    if ($dirs.Count -eq 0) {
        $dirs = @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue | Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0 }).Count -gt 0 } | Sort-Object LastWriteTime)
    }
    Update-Secrets
    $allConsoles.Add($console)
    [pscustomobject]@{
        Exit = $code; Console = $console; Crash = $crash; Calls = $calls; ErrorCount = $errCount
        GraphWrites = @($calls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite }).Count
        CiwWrites   = @($calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.IsWrite }).Count
        GraphCalls  = @($calls | Where-Object { $_.Kind -eq 'Graph' }).Count
        Connects    = @($calls | Where-Object { $_.Kind -eq 'Cmd' -and $_.Method -eq 'CONNECT' }).Count
        QueueLeft   = $global:MockReadQueue.Count; AskedCount = $global:MockReadLog.Count
        NewTempPfx  = @(Get-TempPfx | Where-Object { $_ -notin $tmpBefore })
        Dirs = $dirs; Dir = ($dirs | Select-Object -Last 1)
    }
}
function Get-RunFile($Run, [string]$Filter) { if (-not $Run.Dir) { return $null }; Get-ChildItem -LiteralPath $Run.Dir.FullName -Filter $Filter -File -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Read-RunFile($Run, [string]$Filter) { $f = Get-RunFile $Run $Filter; if ($f) { Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 } else { '' } }
# Fichiers du dossier de sortie d'un passage hors run.log et Rapport-*.md (doit rester vide)
function Get-ExtraFiles($Run, [string[]]$Allowed = @()) {
    if (-not $Run.Dir) { return @('<aucun dossier de sortie>') }
    @(Get-ChildItem -LiteralPath $Run.Dir.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'run.log' -and $_.Name -notlike 'Rapport-*.md' -and $_.Name -notin $Allowed } | ForEach-Object Name)
}

# Lignes du plan lues dans le rapport Markdown : @{ Id; Zone; Element; Action; Raison }
function Get-PlanRows($Run) {
    $md = Read-RunFile $Run 'Rapport-*.md'
    if (-not $md) { return @() }
    $in = $false; $rows = @()
    foreach ($l in ($md -split "\r?\n")) {
        if ($l -match '^## Plan') { $in = $true; continue }
        if ($in -and $l -match '^## ') { break }
        if ($in -and $l -match '^\| (\d+) \| (.*?) \| (.*?) \| (.*?) \| (.*) \|$') { $rows += [pscustomobject]@{ Id = $Matches[1]; Zone = $Matches[2]; Element = $Matches[3]; Action = $Matches[4]; Raison = $Matches[5] } }
    }
    $rows
}

function Get-WriteBrief($Calls) { (@($Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite } | ForEach-Object { $_.Method + ' ' + $_.Path }) -join ' ; ') }
function Get-PlanBrief($Rows) { (@($Rows | ForEach-Object { $_.Zone + '/' + $_.Element + '=' + $_.Action }) -join ' ; ') }
function Join-Names($List) { (@($List) | Sort-Object -Unique) -join ', ' }
function Compare-Sets($Actual, $Expected) {
    $a = @($Actual | Sort-Object -Unique); $e = @($Expected | Sort-Object -Unique)
    $missing = @($e | Where-Object { $_ -notin $a }); $extra = @($a | Where-Object { $_ -notin $e })
    [pscustomobject]@{ Equal = ($missing.Count -eq 0 -and $extra.Count -eq 0); Missing = $missing; Extra = $extra
        Text = "manquants=[$(Join-Names $missing)] en trop=[$(Join-Names $extra)]" }
}
function P([string]$Res, [string[]]$Names, [string]$Type = 'Application') { @($Names | ForEach-Object { "$Res|$_|$Type" }) }

# Consentement : chaque role d'application declare a une attribution ; chaque portee declaree figure dans un octroi AllPrincipals
function Get-ConsentGaps([string]$AppName) {
    $T_ = $global:MockTenant
    $app = @(Get-MockApp $AppName)[0]
    if (-not $app) { return @('application absente') }
    $sp = @($T_.Sps | Where-Object { $_.appId -eq $app.appId })[0]
    if (-not $sp) { return @('principal de service absent') }
    $gaps = @()
    foreach ($rra in @($app.requiredResourceAccess)) {
        $res = Get-MockResSp $rra.resourceAppId
        foreach ($ra in @($rra.resourceAccess)) {
            if ($ra.type -eq 'Role') {
                if (@($T_.ArAssign | Where-Object { $_.principalId -eq $sp.id -and $_.resourceId -eq $res.id -and $_.appRoleId -eq $ra.id }).Count -eq 0) { $gaps += "role $(@($res.appRoles | Where-Object id -EQ $ra.id)[0].value)" }
            } else {
                $n = @($res.oauth2PermissionScopes | Where-Object id -EQ $ra.id)[0].value
                $g = @($T_.Grants | Where-Object { $_.clientId -eq $sp.id -and $_.resourceId -eq $res.id -and $_.consentType -eq 'AllPrincipals' })[0]
                if (-not $g -or @("$($g.scope)" -split '\s+') -notcontains $n) { $gaps += "portee $n" }
            }
        }
    }
    $gaps
}
function Convert-MockThumb($v) { $s = "$v".Trim(); if ($s -match '^[0-9A-Fa-f]{40}$') { $s.ToUpperInvariant() } else { [Convert]::ToHexString([Convert]::FromBase64String($s)).ToUpperInvariant() } }
function Get-MockThumbs($App) { @(@($App.keyCredentials) | ForEach-Object { (Convert-MockThumb $_.customKeyIdentifier) }) }
function Get-MockSp([string]$AppName) { $app = @(Get-MockApp $AppName)[0]; if ($app) { @($global:MockTenant.Sps | Where-Object { $_.appId -eq $app.appId })[0] } }
function Test-MockRole([string]$PrincipalId, [string]$Tpl) { @($global:MockTenant.RoleAssign | Where-Object { $_.principalId -eq $PrincipalId -and $_.roleDefinitionId -eq $Tpl }).Count -gt 0 }
function Get-MockConnector([string]$Name) { @($global:MockCiw.Connectors | Where-Object { $_.name -eq $Name })[0] }
# v2.4 : le marqueur de SUIVI est le fileName du certificat (CIW1_<32 hex>_<AAAAMMJJ>.pfx) ; a defaut l'externalKey CIW1|..|.. (connecteurs anterieurs, secret seul)
function Get-MockMarker($Conn) {
    $fn = if ($Conn -and $Conn.connectorCertificate) { "$($Conn.connectorCertificate.fileName)" } else { '' }
    if ($fn -cmatch '^CIW1_(S?[0-9A-F]{1,33})_(\d{8})\.pfx$') { return [pscustomobject]@{ Id = $Matches[1]; Date = $Matches[2]; Source = 'fileName' } }
    if ($Conn -and "$($Conn.externalKey)" -match '^CIW1\|([^|]+)\|(\d{8})$') { return [pscustomobject]@{ Id = $Matches[1]; Date = $Matches[2]; Source = 'externalKey' } }
}
# externalKey seul (etiquette de propriete ecrite a la creation, jamais modifiee ensuite par un PUT)
function Get-MockExtMarker($Conn) { if ($Conn -and "$($Conn.externalKey)" -match '^CIW1\|([^|]+)\|(\d{8})$') { [pscustomobject]@{ Id = $Matches[1]; Date = $Matches[2] } } }
# Certificat envoye au connecteur : PFX Base64 + mot de passe -> empreinte, cle privee, sujet, expiration
function Get-ConnCert($Conn) {
    $cc = if ($Conn) { $Conn.connectorCertificate } else { $null }
    if (-not $cc -or -not $cc.certificateFile) { return $null }
    try {
        $raw = [Convert]::FromBase64String("$($cc.certificateFile)")
        $x = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($raw, [string]$cc.secret)
        $r = [pscustomobject]@{ Thumbprint = $x.Thumbprint.ToUpperInvariant(); HasKey = $x.HasPrivateKey; Subject = $x.Subject; NotAfter = $x.NotAfter.ToUniversalTime() }
        $x.Dispose(); $r
    } catch { $null }
}
# Coherence connecteur / application / compte de service (certificat, marqueur, RestClientId, mot de passe du compte). Retourne '' si tout concorde.
function Test-ConnCoherence([string]$ConnName, [string]$AppName, [string]$Upn = '') {
    $c = Get-MockConnector $ConnName; $app = @(Get-MockApp $AppName)[0]
    if (-not $c) { return 'connecteur absent' }
    if (-not $app) { return 'application absente' }
    $st = Get-Settings $c; $cert = Get-ConnCert $c; $mk = Get-MockMarker $c; $why = @()
    if ($st.RestClientId -ne $app.appId) { $why += 'RestClientId different' }
    if (-not $cert) { $why += 'certificat illisible' }
    else {
        if (-not $cert.HasKey) { $why += 'PFX sans cle privee' }
        if ((Get-MockThumbs $app) -notcontains $cert.Thumbprint) { $why += 'empreinte du certificat absente de l''application' }
        if (-not $mk -or -not $cert.Thumbprint.StartsWith($mk.Id)) { $why += "marqueur != empreinte ($($c.externalKey))" }
    }
    if ($Upn) { $u = Get-MockUser $Upn; if (-not $u -or $st.MigrationAccountPassword -ne $u.PwdMarker) { $why += 'mot de passe du compte de service different de celui du tenant' } }
    $why -join ' ; '
}
function Set-MockKeyEnd($App, [string]$Thumb, [int]$Days) {
    foreach ($k in @($App.keyCredentials)) {
        if (([string](Convert-MockThumb $k.customKeyIdentifier)).StartsWith($Thumb)) { $k.endDateTime = (Microsoft.PowerShell.Utility\Get-Date).ToUniversalTime().AddDays($Days).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    }
}

# Oracles (ecrits a la main, independants de lib\permissions.ps1)
$expSrcMailOd = @(P Graph 'MailboxSettings.ReadWrite', 'User.Read.All', 'Files.ReadWrite.All', 'Sites.FullControl.All', 'Directory.Read.All') +
@(P Exchange 'Exchange.ManageAsApp', 'full_access_as_app') + @(P SharePoint 'Sites.FullControl.All', 'User.Read.All') + @(P Graph 'User.Read' 'Delegated')

# ===================================================================================================
# SCENARIO A : points 1, 2, 10, 11, 16, 17, 18 (Source Mail + OneDrive, certificat par defaut, passages successifs)
# ===================================================================================================
Reset-MockState
$baseA = New-Base 'A'; $allBases.Add($baseA)
$pA = Get-BaseParams $baseA @('Mail', 'OneDrive'); $pA['ProductIds'] = '5,6'

$r1 = Invoke-Connector $pA $baseA
$app = @(Get-MockApp $AppSrc)[0]; $sp = Get-MockSp $AppSrc; $svc = Get-MockUser $SvcSrc
$conn = Get-MockConnector $ConnSrc; $cs = Get-Settings $conn; $cert1 = Get-ConnCert $conn; $mk1 = Get-MockMarker $conn
T 1 'pas de crash' ([string]::IsNullOrEmpty($r1.Crash)) $r1.Crash
T 1 'code de sortie 0' ($r1.Exit -eq 0) "exit=$($r1.Exit)"
T 1 'application CLOUDIWAY-SOURCE-P12345 creee, etiquetee CloudiwayConnector, locataire unique' ($app -and @($app.tags) -contains 'CloudiwayConnector' -and $app.signInAudience -eq 'AzureADMyOrg') "app=$($app.displayName) tags=$(@($app.tags) -join ',')"
T 1 'client public NON active (aucun compte de service necessaire)' ($app -and $app.isFallbackPublicClient -ne $true)
T 1 'principal de service cree' ([bool]$sp)
$cmp = Compare-Sets (Get-MockAppPerms $app) $expSrcMailOd
T 1 'permissions declarees = matrice Source (Mail+OneDrive)' $cmp.Equal $cmp.Text
$gaps = Get-ConsentGaps $AppSrc
T 1 'consentement accorde (roles + portees)' ($gaps.Count -eq 0) ($gaps -join '; ')
T 1 'roles Entra du principal de service (Exchange Admin + Recipient Admin)' ($sp -and (Test-MockRole $sp.id $global:MockRoleTpl.ExA) -and (Test-MockRole $sp.id $global:MockRoleTpl.ExRA)) 'roles Exchange absents'
T 1 'certificat dans keyCredentials (1), aucun secret client (AuthMethod Certificate par defaut)' ($app -and @($app.keyCredentials).Count -eq 1 -and @($app.passwordCredentials).Count -eq 0) "certs=$(@($app.keyCredentials).Count) secrets=$(@($app.passwordCredentials).Count)"
T 1 'AUCUN compte de service cree (Mail et OneDrive en Source)' (-not $svc -and @($global:MockTenant.Users | Where-Object { $_.userPrincipalName -like 'svc-*' }).Count -eq 0 -and @($r1.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Path -eq '/users' }).Count -eq 0) 'compte de service cree'
T 1 'connecteur cree dans Cloudiway (nom, sens, produits)' ($conn -and $conn.isTarget -eq $false -and $conn.rawProductList -eq '[5,6]') "connecteur=$($conn.name) produits=$($conn.rawProductList)"
T 1 'connecteur : RestClientId = AppId, domaine, aucun compte de migration, region 1, authentification 3' ($cs -and $cs.RestClientId -eq $app.appId -and @($cs.Domains) -contains 'contoso.onmicrosoft.com' -and -not $cs.MigrationAccount -and $cs.ServerRegion -eq 1 -and $cs.AuthenticationType -eq 3 -and $cs.TenantName -eq 'contoso') "settings=$($conn.rawSettings -replace '"MigrationAccountPassword":"[^"]*"','"MigrationAccountPassword":"***"')"
T 1 'connecteur : aucun mot de passe de compte, jamais RestClientSecret en mode Certificate' ($cs -and -not $cs.MigrationAccountPassword -and -not $cs.RestClientSecret) 'secret inattendu dans le connecteur'
T 1 'certificat envoye en Base64 : PFX ouvrable avec connectorCertificate.secret, cle privee, empreinte = keyCredentials, sujet codifie' ($cert1 -and $cert1.HasKey -and ((Get-MockThumbs $app) -contains $cert1.Thumbprint) -and $cert1.Subject -eq 'CN=Cloudiway-SOURCE-P12345') "cert=$($cert1.Thumbprint) subject=$($cert1.Subject)"
$certB1 = if ($conn -and $conn._body) { $conn._body.connectorCertificate } else { $null }
T 1 'connectorCertificate : fileName *.pfx, connectorId, pas de chemin local' ($certB1 -and $certB1.fileName -like '*.pfx' -and "$($certB1.certificateFile)" -notmatch '^[A-Za-z]:[\\/]|\.pfx$' -and $global:MockCiw.CertFileSeen -eq $null) "fileName=$($certB1.fileName)"
T 1 'marqueur de suivi = fileName du certificat CIW1_<32 hex de l''empreinte>_<AAAAMMJJ>.pfx ; externalKey ecrit a la CREATION seulement (etiquette CIW1|<empreinte>|<AAAAMMJJ>)' ($mk1 -and $mk1.Source -eq 'fileName' -and $cert1 -and $cert1.Thumbprint.StartsWith($mk1.Id) -and $mk1.Id.Length -eq 32 -and $mk1.Date -eq $cert1.NotAfter.ToString('yyyyMMdd') -and (Get-MockExtMarker $conn) -and (Get-MockExtMarker $conn).Id -eq $mk1.Id) "fileName=$($conn.connectorCertificate.fileName) externalKey=$($conn.externalKey)"

# --- Point 16 : noms codifies, projet detecte ---
$cmdl = @($r1.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Path -eq '/Projects' }).Count
T 16 'projet detecte automatiquement (un seul projet visible, aucun -ProjectId) : objets nommes P12345' ($app -and $conn -and $cmdl -ge 1) "GET /Projects=$cmdl"
T 16 'noms codifies : application, connecteur (<prefixe du domaine>-source)' ($app.displayName -eq $AppSrc -and $conn.name -eq $ConnSrc) "app=$($app.displayName) conn=$($conn.name)"
T 16 'aucune URI de redirection (reservee a une charge non disponible dans cette version)' ($app -and @($app.web.redirectUris).Count -eq 0) "uri=$(@($app.web.redirectUris) -join ',')"
T 16 'domaine resolu en GUID par la metadonnee OIDC publique (1 appel, sans authentification)' (@($r1.Calls | Where-Object { $_.Kind -eq 'Oidc' }).Count -eq 1 -and $r1.Console -match [regex]::Escape($global:MockTenantId)) "oidc=$(@($r1.Calls | Where-Object { $_.Kind -eq 'Oidc' }).Count)"
T 16 'ordre : connexion Cloudiway AVANT Connect-MgGraph, connecteur existant lu avant toute ecriture Graph' ((($r1.Calls | Where-Object { $_.Kind -eq 'Ciw' } | Select-Object -First 1).Seq) -lt (($r1.Calls | Where-Object { $_.Method -eq 'CONNECT' } | Select-Object -First 1).Seq) -and (($r1.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Path -match '^/Connectors' } | Select-Object -First 1).Seq) -lt (($r1.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite } | Select-Object -First 1).Seq)) 'ordre inattendu'

# --- Point 17 : identifiants en memoire, aucun fichier ---
$extra1 = Get-ExtraFiles $r1
T 17 'le dossier de sortie ne contient que run.log et Rapport-*.md (ni .pfx, ni .secret.json, ni etat-*.json)' ($extra1.Count -eq 0 -and (Get-RunFile $r1 'run.log') -and (Get-RunFile $r1 'Rapport-*.md')) "en trop : $($extra1 -join ', ')"
T 17 'aucun fichier sensible nulle part sous le dossier de test (.pfx, .secret.json, etat-*.json)' (@(Get-ChildItem -LiteralPath $tmpRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.pfx' -or $_.Name -like '*.secret.json' -or $_.Name -like 'etat-*.json' }).Count -eq 0) 'fichier sensible present'
T 17 'transport Base64 : aucun PFX temporaire cree dans %TEMP%' ($r1.NewTempPfx.Count -eq 0) "temp=$($r1.NewTempPfx -join ',')"

# --- Point 2 : second passage identique ---
$r2 = Invoke-Connector (Keep $pA) $baseA
$rows2 = Get-PlanRows $r2
$bad2 = @($rows2 | Where-Object { $_.Action -notin 'OK', 'IGNORE' })
T 2 'pas de crash' ([string]::IsNullOrEmpty($r2.Crash)) $r2.Crash
T 2 'code de sortie 0' ($r2.Exit -eq 0) "exit=$($r2.Exit)"
T 2 'ZERO ecriture Graph' ($r2.GraphWrites -eq 0) "ecritures=$($r2.GraphWrites) : $(Get-WriteBrief $r2.Calls)"
T 2 'ZERO POST/PUT Cloudiway (hors authentification et recherche)' ($r2.CiwWrites -eq 0) "ecritures=$($r2.CiwWrites)"
T 2 'plan uniquement OK/IGNORE' ($rows2.Count -gt 0 -and $bad2.Count -eq 0) "lignes non OK : $(Get-PlanBrief $bad2)"
T 2 'aucun fichier hors run.log / Rapport' ((Get-ExtraFiles $r2).Count -eq 0) "en trop : $((Get-ExtraFiles $r2) -join ', ')"
T 2 'un seul certificat toujours present, aucun identifiant regenere' (@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and $global:MockCiw.PutCount -eq 0) 'certificat ajoute au second passage'

# --- Point 10 : rotation (alias -RotateCertificate) ---
$oldKeyIds = @((@(Get-MockApp $AppSrc)[0]).keyCredentials | ForEach-Object { "$($_.keyId)" })
$oldThumbs = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])); $putBefore = $global:MockCiw.PutCount; 
$pRot = $pA.Clone(); $pRot['RotateCertificate'] = $true
$r10 = Invoke-Connector $pRot $baseA
$appAfter = @(Get-MockApp $AppSrc)[0]; $newThumbs = @(Get-MockThumbs $appAfter); $connAfter = Get-MockConnector $ConnSrc; $certAfter = Get-ConnCert $connAfter
T 10 'pas de crash, code de sortie 0' ([string]::IsNullOrEmpty($r10.Crash) -and $r10.Exit -eq 0) "exit=$($r10.Exit) $($r10.Crash)"
T 10 'nouveau certificat ajoute puis ancien retire : UN SEUL certificat actif' ($newThumbs.Count -eq 1 -and $newThumbs[0] -notin $oldThumbs) "n=$($newThumbs.Count)"
T 10 'ancien certificat de l''outil RETIRE apres transmission du nouveau (1 cle retiree, celle de l''ancien keyId)' (($oldThumbs | Where-Object { $_ -in $newThumbs }).Count -eq 0 -and $global:MockTenant.RemovedKeys -eq 1 -and $global:MockTenant.RemovedKeyIds -contains $oldKeyIds[0]) "anciens=$($oldThumbs -join ',') apres=$($newThumbs -join ',') retirees=$($global:MockTenant.RemovedKeys)"
T 10 'connecteur MIS A JOUR (PUT) avec le NOUVEAU certificat (Base64 + mot de passe) et un nouveau marqueur' ($global:MockCiw.PutCount -gt $putBefore -and $certAfter -and $certAfter.Thumbprint -ne $cert1.Thumbprint -and ($newThumbs -contains $certAfter.Thumbprint)) "PUT=$($global:MockCiw.PutCount - $putBefore) cert=$($certAfter.Thumbprint)"
T 10 'rotation : aucun fichier ecrit' ((Get-ExtraFiles $r10).Count -eq 0) "en trop : $((Get-ExtraFiles $r10) -join ', ')"

# --- Point 18 : renouvellement automatique (marqueur absent, empreinte inconnue, < 30 jours) ---
function Test-Renewal([string]$Label, [scriptblock]$Break) {
    $c0 = Get-MockConnector $ConnSrc; $oldC = Get-ConnCert $c0; $nBefore = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count; $put0 = $global:MockCiw.PutCount; $rk0 = $global:MockTenant.RemovedKeys
    & $Break
    $rr = Invoke-Connector (Keep $pA) $baseA
    $a2 = @(Get-MockApp $AppSrc)[0]; $nAfter = @(Get-MockThumbs $a2).Count; $c1 = Get-MockConnector $ConnSrc; $newC = Get-ConnCert $c1
    $coh = Test-ConnCoherence $ConnSrc $AppSrc
    T 18 "$Label : renouvellement automatique (exit 0, 1 seul certificat apres, ancien retire, PUT, nouveau marqueur CIW1 coherent)" ($rr.Exit -eq 0 -and $nAfter -eq 1 -and $global:MockCiw.PutCount -eq $put0 + 1 -and $newC -and $newC.Thumbprint -ne $oldC.Thumbprint -and $coh -eq '' -and $global:MockTenant.RemovedKeys -eq $rk0 + 1) "exit=$($rr.Exit) certs=$nBefore->$nAfter PUT=$($global:MockCiw.PutCount - $put0) retirees=$($global:MockTenant.RemovedKeys - $rk0) incoherence=$coh $($rr.Crash)"
    $rr
}
$rn1 = Test-Renewal 'marqueur absent (nom de certificat sans marqueur et externalKey ancienne)' { $c_ = Get-MockConnector $ConnSrc; $c_.externalKey = 'CloudiwayConnector'; $c_.connectorCertificate.fileName = 'cloudiway.pfx' }
$rn2 = Test-Renewal 'empreinte du marqueur (fileName) inconnue de l''application' { $c_ = Get-MockConnector $ConnSrc; $c_.connectorCertificate.fileName = 'CIW1_' + ('AB' * 16) + '_20270101.pfx' }
$rn3 = Test-Renewal 'moins de 30 jours de validite restants' { $mkx = Get-MockMarker (Get-MockConnector $ConnSrc); Set-MockKeyEnd (@(Get-MockApp $AppSrc)[0]) $mkx.Id 10 }
$r2b = Invoke-Connector (Keep $pA) $baseA
T 18 'apres renouvellements : nouveau passage = zero ecriture (Graph et Cloudiway), exit 0' ($r2b.Exit -eq 0 -and $r2b.GraphWrites -eq 0 -and $r2b.CiwWrites -eq 0) "exit=$($r2b.Exit) graph=$($r2b.GraphWrites) ciw=$($r2b.CiwWrites) $(Get-WriteBrief $r2b.Calls)"

# --- Point 11 : secrets (compte rendu du balayage a la fin) ---
T 11 'aucun mot de passe / PFX genere n''est lisible dans le dossier de sortie du scenario A (balayage detaille en fin de banc)' ($allSecretValues.Count -ge 6) "valeurs sensibles collectees : $($allSecretValues.Count)"

# ===================================================================================================
# POINT 3 : -WhatIf
# ===================================================================================================
Reset-MockState
$base3 = New-Base 'P3'; $allBases.Add($base3)
$p3 = Get-BaseParams $base3 @('Mail', 'OneDrive'); $p3['WhatIf'] = $true
$r3 = Invoke-Connector $p3 $base3
T 3 'pas de crash, code de sortie 0' ([string]::IsNullOrEmpty($r3.Crash) -and $r3.Exit -eq 0) "exit=$($r3.Exit) $($r3.Crash)"
T 3 'zero ecriture Graph' ($r3.GraphWrites -eq 0) "ecritures=$($r3.GraphWrites)"
T 3 'zero ecriture Cloudiway' ($r3.CiwWrites -eq 0) "ecritures=$($r3.CiwWrites)"
T 3 'plan affiche (CREER + Total)' ($r3.Console -match 'CREER' -and $r3.Console -match 'Total : \d+ action') 'plan absent de la console'
T 3 'rien cree dans le tenant ni le portail' ((@($global:MockTenant.Apps).Count -eq 0) -and (@($global:MockTenant.Users).Count -eq 0) -and (@($global:MockCiw.Connectors).Count -eq 0)) 'objets crees en simulation'
T 3 'aucun fichier hors run.log / Rapport, aucun PFX temporaire' ((Get-ExtraFiles $r3).Count -eq 0 -and $r3.NewTempPfx.Count -eq 0) 'fichier sensible ecrit en simulation'
T 3 'rapport marque SIMULATION' ((Read-RunFile $r3 'Rapport-*.md') -match 'SIMULATION') 'rapport sans mention de simulation'

# ===================================================================================================
# POINT 5 : utilisateur NON Global Administrator
# ===================================================================================================
Reset-MockState; $global:MockOpts.IsGA = $false
$base5 = New-Base 'P5'; $allBases.Add($base5)
$r5 = Invoke-Connector (Get-BaseParams $base5 @('Mail', 'OneDrive')) $base5
$rows5 = Get-PlanRows $r5
T 5 'pas de crash' ([string]::IsNullOrEmpty($r5.Crash)) $r5.Crash
T 5 'aucune ecriture Graph' ($r5.GraphWrites -eq 0) "ecritures=$($r5.GraphWrites)"
T 5 'aucune ecriture Cloudiway' ($r5.CiwWrites -eq 0) "ecritures=$($r5.CiwWrites)"
T 5 'lignes BLOQUE dans le plan (Application, Consentement...)' (@($rows5 | Where-Object { $_.Action -eq 'BLOQUE' }).Count -ge 3) "bloquees=$(@($rows5 | ? { $_.Action -eq 'BLOQUE' }).Count)"
T 5 'code de sortie 1' ($r5.Exit -eq 1) "exit=$($r5.Exit)"
T 5 'message explicite sur l''absence du role Administrateur general' ($r5.Console -match 'pas Administrateur general') 'avertissement absent'
T 5 'aucun objet cree' (@($global:MockTenant.Apps).Count -eq 0 -and @($global:MockTenant.Users).Count -eq 0) 'objets crees malgre le blocage'

# ===================================================================================================
# POINT 6 : tenant ou compte different
# ===================================================================================================
Reset-MockState; $global:MockOpts.ConnectTenantId = '99999999-8888-7777-6666-555555555555'
$base6 = New-Base 'P6a'; $allBases.Add($base6)
$r6a = Invoke-Connector (Get-BaseParams $base6) $base6
T 6 'tenant different : exit 1' ($r6a.Exit -eq 1) "exit=$($r6a.Exit) $($r6a.Crash)"
T 6 'tenant different : zero requete Graph (lecture comprise) et zero ecriture Cloudiway' ($r6a.GraphCalls -eq 0 -and $r6a.CiwWrites -eq 0) "graph=$($r6a.GraphCalls) ciw=$($r6a.CiwWrites)"
T 6 'tenant different : message de refus' ($r6a.Console -match 'Connexion refusee') 'message absent'
Reset-MockState; $global:MockOpts.ConnectAccount = 'autre.admin@contoso.com'
$base6 = New-Base 'P6b'; $allBases.Add($base6)
$r6b = Invoke-Connector (Get-BaseParams $base6) $base6
T 6 'compte different de -Admin365 : exit 1, aucune requete Graph, aucune ecriture' ($r6b.Exit -eq 1 -and $r6b.GraphCalls -eq 0 -and $r6b.CiwWrites -eq 0) "exit=$($r6b.Exit) graph=$($r6b.GraphCalls) ciw=$($r6b.CiwWrites)"
Reset-MockState; $global:MockOpts.ConnectAccount = 'ADMIN@Contoso.com'
$base6 = New-Base 'P6c'; $allBases.Add($base6)
$r6c = Invoke-Connector (Get-BaseParams $base6) $base6
T 6 'compte identique a la casse pres : accepte (exit 0)' ($r6c.Exit -eq 0) "exit=$($r6c.Exit) $($r6c.Crash)"
Reset-MockState
$base6 = New-Base 'P6d'; $allBases.Add($base6)
$p6d = Get-BaseParams $base6; $p6d['User'] = $global:MockUser; $p6d.Remove('Admin365')
$r6d = Invoke-Connector $p6d $base6
T 6 'alias -User accepte pour -Admin365' ($r6d.Exit -eq 0) "exit=$($r6d.Exit) $($r6d.Crash)"

# ===================================================================================================
# POINT 7 : acces Cloudiway (portail inaccessible = arret AVANT toute ecriture tenant)
# ===================================================================================================
Reset-MockState
$base7 = New-Base 'P7a'; $allBases.Add($base7)
$p7 = Use-Pat (Get-BaseParams $base7); $p7['CloudiwayPat'] = (New-TestSecure 'pat-mauvais-pat')
$r7a = Invoke-Connector $p7 $base7
T 7 'PAT invalide : exit 1' ($r7a.Exit -eq 1) "exit=$($r7a.Exit) $($r7a.Crash)"
T 7 'PAT invalide : AUCUNE connexion ni requete Graph (arret avant le tenant)' ($r7a.Connects -eq 0 -and $r7a.GraphCalls -eq 0) "connect=$($r7a.Connects) graph=$($r7a.GraphCalls)"
T 7 'PAT invalide : aucune ecriture Cloudiway' ($r7a.CiwWrites -eq 0) "ecritures=$($r7a.CiwWrites)"
T 7 'PAT invalide : message "Acces au portail Cloudiway impossible"' ($r7a.Console -match 'portail Cloudiway impossible') 'message absent'
Reset-MockState
$base7 = New-Base 'P7b'; $allBases.Add($base7)
$p7 = Get-BaseParams $base7; $p7['ProjectId'] = 99999
$r7b = Invoke-Connector $p7 $base7
T 7 'projet absent : exit 1, aucune connexion/requete Graph, aucune ecriture' ($r7b.Exit -eq 1 -and $r7b.Connects -eq 0 -and $r7b.GraphCalls -eq 0 -and $r7b.CiwWrites -eq 0) "exit=$($r7b.Exit) connect=$($r7b.Connects) graph=$($r7b.GraphCalls) ciw=$($r7b.CiwWrites)"
T 7 'projet absent : message sur le projet' ($r7b.Console -match 'ne figure pas parmi') 'message absent'
Reset-MockState; $global:MockOpts.NetDown = @('api-production.cloudiway.com')
$base7 = New-Base 'P7c'; $allBases.Add($base7)
$r7c = Invoke-Connector (Get-BaseParams $base7) $base7
T 7 'hote Cloudiway injoignable (preflight) : exit 1 avant toute connexion ni saisie de mot de passe' ($r7c.Exit -eq 1 -and $r7c.Connects -eq 0 -and $r7c.GraphCalls -eq 0 -and $r7c.QueueLeft -eq 1) "exit=$($r7c.Exit) connect=$($r7c.Connects) file=$($r7c.QueueLeft)"
Reset-MockState
$base7 = New-Base 'P7d'; $allBases.Add($base7)
$r7d = Invoke-Connector (Get-BaseParams $base7) $base7 @('Mauvais-mot-de-passe-1!')
T 7 'mot de passe Cloudiway incorrect : exit 1, aucune connexion/requete Graph, aucune ecriture, message portail' ($r7d.Exit -eq 1 -and $r7d.Connects -eq 0 -and $r7d.GraphCalls -eq 0 -and $r7d.CiwWrites -eq 0 -and $r7d.Console -match 'portail Cloudiway impossible') "exit=$($r7d.Exit) connect=$($r7d.Connects) graph=$($r7d.GraphCalls)"
T 7 'mot de passe incorrect : le mot de passe saisi n''apparait nulle part dans la console' ($r7d.Console -notmatch 'Mauvais-mot-de-passe-1') 'mot de passe affiche'
Reset-MockState
$base7 = New-Base 'P7e'; $allBases.Add($base7)
$r7e = Invoke-Connector (Get-BaseParams $base7) $base7 @('')
T 7 'mot de passe Cloudiway vide : exit 1 propre, rien ecrit' ($r7e.Exit -eq 1 -and $r7e.Connects -eq 0 -and $r7e.GraphCalls -eq 0 -and $r7e.CiwWrites -eq 0 -and [string]::IsNullOrEmpty($r7e.Crash)) "exit=$($r7e.Exit) $($r7e.Crash)"

# ===================================================================================================
# POINT 22 : connexion Cloudiway (jeton, cookie, PAT, projets)
# ===================================================================================================
Reset-MockState; $global:MockCiw.LoginMode = 'cookie'
$base22 = New-Base 'C1'; $allBases.Add($base22)
$p22 = Get-BaseParams $base22; $p22['WhatIf'] = $true
$r22a = Invoke-Connector $p22 $base22
T 22 'login avec champ token = "token" : repli cookies (Set-Cookie) puis acces projets/connecteurs, exit 0' ($r22a.Exit -eq 0 -and [string]::IsNullOrEmpty($r22a.Crash) -and @($r22a.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Path -eq '/Authentication/Login' }).Count -ge 2 -and $r22a.Console -match 'cookies') "exit=$($r22a.Exit) logins=$(@($r22a.Calls | Where-Object { $_.Path -eq '/Authentication/Login' }).Count) $($r22a.Crash)"
Reset-MockState
$base22 = New-Base 'C2'; $allBases.Add($base22)
$r22b = Invoke-Connector (Use-Pat (Get-BaseParams $base22)) $base22
T 22 'variante -CloudiwayPat : aucun mot de passe demande, TechnicalLogin, connecteur cree, exit 0' ($r22b.Exit -eq 0 -and $r22b.AskedCount -eq 0 -and @($r22b.Calls | Where-Object { $_.Path -eq '/Authentication/TechnicalLogin' }).Count -eq 1 -and (Get-MockConnector $ConnSrc)) "exit=$($r22b.Exit) questions=$($r22b.AskedCount) $($r22b.Crash)"
T 22 'variante PAT : le mot de passe de login n''est jamais utilise (aucun appel /Authentication/Login)' (@($r22b.Calls | Where-Object { $_.Path -eq '/Authentication/Login' }).Count -eq 0) 'login mot de passe appele avec un PAT'
Reset-MockState; $global:MockCiw.Projects = @(12345, 12346)
$base22 = New-Base 'C3'; $allBases.Add($base22)
$r22c = Invoke-Connector (Get-BaseParams $base22) $base22 @($global:MockCwPassword, '2')
T 22 'plusieurs projets visibles, mode interactif : le choix est demande une seule fois (2 = 12346), objets nommes P12346' ($r22c.Exit -eq 0 -and (Get-MockApp 'CLOUDIWAY-SOURCE-P12346') -and (Get-MockConnector $ConnSrc).projectId -eq 12346 -and $r22c.AskedCount -eq 2) "exit=$($r22c.Exit) questions=$($r22c.AskedCount) $($r22c.Crash)"
Reset-MockState; $global:MockCiw.Projects = @(12345, 12346)
$base22 = New-Base 'C4'; $allBases.Add($base22)
$p22d = Get-BaseParams $base22; $p22d['ProjectId'] = 12345
$r22d = Invoke-Connector $p22d $base22
T 22 'plusieurs projets + -ProjectId 12345 : aucune question de projet, objets nommes P12345, exit 0' ($r22d.Exit -eq 0 -and $r22d.AskedCount -eq 1 -and (Get-MockApp $AppSrc)) "exit=$($r22d.Exit) questions=$($r22d.AskedCount) $($r22d.Crash)"
Reset-MockState; $global:MockCiw.Projects = @()
$base22 = New-Base 'C5'; $allBases.Add($base22)
$r22e = Invoke-Connector (Get-BaseParams $base22) $base22
T 22 'aucun projet visible : exit 1 avant toute connexion au tenant, aucune ecriture' ($r22e.Exit -eq 1 -and $r22e.Connects -eq 0 -and $r22e.GraphCalls -eq 0 -and $r22e.CiwWrites -eq 0 -and $r22e.Console -match 'aucun projet') "exit=$($r22e.Exit) connect=$($r22e.Connects)"

# ===================================================================================================
# POINT 23 : resolution du tenant (domaine -> GUID) et controles d'adresses AVANT toute saisie de mot de passe
# ===================================================================================================
Reset-MockState
$base23 = New-Base 'T1'; $allBases.Add($base23)
$p23 = Get-BaseParams $base23; $p23['Tenant'] = 'inconnu.onmicrosoft.com'
$r23a = Invoke-Connector $p23 $base23
T 23 'domaine inconnu de Microsoft Entra : exit 1, aucune connexion, mot de passe Cloudiway PAS demande (file intacte)' ($r23a.Exit -eq 1 -and $r23a.Connects -eq 0 -and $r23a.GraphCalls -eq 0 -and $r23a.QueueLeft -eq 1 -and $r23a.CiwWrites -eq 0 -and $r23a.Console -match 'inconnu') "exit=$($r23a.Exit) file=$($r23a.QueueLeft) connect=$($r23a.Connects)"
$p23['Tenant'] = 'pas un domaine'
$r23b = Invoke-Connector $p23 $base23
T 23 '-Tenant mal forme : exit 1 immediat, aucun appel' ($r23b.Exit -eq 1 -and $r23b.Calls.Count -eq 0) "exit=$($r23b.Exit) appels=$($r23b.Calls.Count)"
$p23 = Get-BaseParams $base23; $p23['Admin365'] = 'pas-une-adresse'
$r23c = Invoke-Connector $p23 $base23
T 23 '-Admin365 invalide : exit 1, mot de passe PAS demande, aucune connexion' ($r23c.Exit -eq 1 -and $r23c.Connects -eq 0 -and $r23c.QueueLeft -eq 1) "exit=$($r23c.Exit) file=$($r23c.QueueLeft)"
$p23 = Get-BaseParams $base23; $p23['Cloudiway'] = 'pas-une-adresse'
$r23d = Invoke-Connector $p23 $base23
T 23 '-Cloudiway invalide : exit 1, mot de passe PAS demande, aucune connexion' ($r23d.Exit -eq 1 -and $r23d.Connects -eq 0 -and $r23d.QueueLeft -eq 1) "exit=$($r23d.Exit) file=$($r23d.QueueLeft)"
Reset-MockState
$base23 = New-Base 'T2'; $allBases.Add($base23)
$p23 = Get-BaseParams $base23; $p23['Tenant'] = $global:MockTenantId.ToUpperInvariant(); $p23['WhatIf'] = $true
$r23e = Invoke-Connector $p23 $base23
T 23 '-Tenant = GUID : aucune resolution OIDC, exit 0, nom du connecteur deduit du domaine par defaut du tenant (contoso-source)' ($r23e.Exit -eq 0 -and @($r23e.Calls | Where-Object { $_.Kind -eq 'Oidc' }).Count -eq 0 -and $r23e.Console -match 'contoso-source') "exit=$($r23e.Exit) oidc=$(@($r23e.Calls | Where-Object { $_.Kind -eq 'Oidc' }).Count) $($r23e.Crash)"
Reset-MockState
$base23 = New-Base 'T3'; $allBases.Add($base23)
$p23 = Get-BaseParams $base23; $p23['Tenant'] = 'contoso.com'
$r23f = Invoke-Connector $p23 $base23
T 23 '-Tenant = domaine verifie personnalise : resolu, noms codifies sur le domaine .onmicrosoft.com par defaut, exit 0' ($r23f.Exit -eq 0 -and (Get-MockConnector $ConnSrc) -and (Get-MockApp $AppSrc)) "exit=$($r23f.Exit) $($r23f.Crash)"

# ===================================================================================================
# POINT 21 : -SkipCloudiway, puis echec Cloudiway apres creation du certificat, puis relance
# ===================================================================================================
Reset-MockState
$base21 = New-Base 'SK'; $allBases.Add($base21)
$pSk = Get-BaseParams $base21 @('Mail'); $pSk.Remove('Cloudiway'); $pSk['SkipCloudiway'] = $true; $pSk['ProjectId'] = 12345
$r21a = Invoke-Connector $pSk $base21
$appSk = @(Get-MockApp $AppSrc)[0]
T 21 '-SkipCloudiway (+ -ProjectId) : exit 0, aucun appel Cloudiway, aucun mot de passe demande' ($r21a.Exit -eq 0 -and @($r21a.Calls | Where-Object Kind -EQ 'Ciw').Count -eq 0 -and $r21a.AskedCount -eq 0) "exit=$($r21a.Exit) appels Ciw=$(@($r21a.Calls | ? Kind -EQ 'Ciw').Count) questions=$($r21a.AskedCount) $($r21a.Crash)"
T 21 '-SkipCloudiway : aucun certificat ni secret genere (aucun moyen de les transmettre), annonce clairement' ($appSk -and @($appSk.keyCredentials).Count -eq 0 -and @($appSk.passwordCredentials).Count -eq 0 -and $r21a.Console -match 'Aucun certificat ni secret ne sera genere') "certs=$(@($appSk.keyCredentials).Count)"
T 21 '-SkipCloudiway : Mail seul, isFallbackPublicClient NON active (pas de compte de service) ; rapport : relancer sans l''option' ($appSk -and $appSk.isFallbackPublicClient -ne $true -and (Read-RunFile $r21a 'Rapport-*.md') -match 'Declarer le connecteur dans Cloudiway') 'rapport/clientpublic'
$pSk2 = Get-BaseParams $base21 @('Mail')
$r21b = Invoke-Connector $pSk2 $base21
T 21 'relance SANS -SkipCloudiway : certificat genere ET connecteur cree dans le meme passage (sans -RotateCredentials), exit 0' ($r21b.Exit -eq 0 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '' -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1) "exit=$($r21b.Exit) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc) $($r21b.Crash)"
# echec de l'etape Cloudiway apres creation du certificat
Reset-MockState
$global:MockOpts.CiwFail = @(@{ Method = 'POST'; Pattern = '^/Connectors$'; Code = 503; Times = 1 })
$base21c = New-Base 'F1'; $allBases.Add($base21c)
$pF = Get-BaseParams $base21c @('Mail')
$r21c = Invoke-Connector $pF $base21c
$rk21c = $global:MockTenant.RemovedKeys
T 21 'Cloudiway indisponible apres creation du certificat : exit 2, certificat dans l''application, aucun connecteur, aucun fichier ecrit' ($r21c.Exit -eq 2 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and @($global:MockCiw.Connectors).Count -eq 0 -and (Get-ExtraFiles $r21c).Count -eq 0) "exit=$($r21c.Exit) certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count) connecteurs=$(@($global:MockCiw.Connectors).Count)"
$r21d = Invoke-Connector $pF $base21c
T 21 'relance : le certificat est REGENERE, le connecteur cree, coherent, exit 0, et l''orphelin du passage en echec est retire (1 seul certificat)' ($r21d.Exit -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and (Get-MockConnector $ConnSrc) -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '' -and $global:MockTenant.RemovedKeys -eq 1) "exit=$($r21d.Exit) certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count) retirees=$($global:MockTenant.RemovedKeys) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
T 21 'Cloudiway indisponible : aucune cle retiree au passage en echec (RemovedKeys = 0 avant la relance)' ($rk21c -eq 0) "retirees=$rk21c"
# echec du PUT lors d'un renouvellement : la relance regenere et met a jour
(Get-MockConnector $ConnSrc).externalKey = 'CloudiwayConnector'
$global:MockOpts.CiwFail = @(@{ Method = 'PUT'; Pattern = '^/Connectors/\d+$'; Code = 503; Times = 1 })
$putBefore = $global:MockCiw.PutCount
$rk21e0 = $global:MockTenant.RemovedKeys; $oldCert21e = Get-ConnCert (Get-MockConnector $ConnSrc)
$r21e = Invoke-Connector $pF $base21c
T 21 'PUT en echec (503) lors d''un renouvellement : exit 2, connecteur inchange, PUT non rejoue' ($r21e.Exit -eq 2 -and $global:MockCiw.PutCount -eq $putBefore -and @($r21e.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Method -eq 'PUT' }).Count -eq 1) "exit=$($r21e.Exit) PUT=$(@($r21e.Calls | Where-Object { $_.Method -eq 'PUT' }).Count)"
$app21e = @(Get-MockApp $AppSrc)[0]
$cl21e = @(Get-PlanRows $r21e | Where-Object { $_.Zone -eq 'Nettoyage' })
T 29 'connecteur en echec (PUT 503) : ANCIEN certificat CONSERVE (connecteur encore sur l''ancien), aucune cle retiree, aucun appel de retrait' ($global:MockTenant.RemovedKeys -eq $rk21e0 -and @(Get-MockThumbs $app21e).Count -eq 2 -and (Get-MockThumbs $app21e) -contains $oldCert21e.Thumbprint -and @($r21e.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite -and $_.Method -eq 'PATCH' -and $_.Body -match 'keyCredentials' -and $_.Body -notmatch '"key"' }).Count -eq 0) "certs=$(@(Get-MockThumbs $app21e).Count) retirees=$($global:MockTenant.RemovedKeys - $rk21e0)"
T 29 'connecteur en echec : la ligne de la zone Nettoyage est IGNOREE (dependance de la ligne Cloudiway) et le rapport l''explique' ($cl21e.Count -eq 1 -and $cl21e[0].Action -eq 'METTRE A JOUR' -and ((Read-RunFile $r21e 'Rapport-*.md') -match 'Nettoyage \| Anciens certificats de l''outil \| IGNORE \| depend d''une ligne en echec')) "lignes=$(Get-PlanBrief $cl21e)"
$r21f = Invoke-Connector $pF $base21c
T 21 'relance apres echec du PUT : nouveau certificat envoye, connecteur coherent, exit 0' ($r21f.Exit -eq 0 -and $global:MockCiw.PutCount -eq $putBefore + 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($r21f.Exit) PUT=$($global:MockCiw.PutCount - $putBefore) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
T 29 'relance reussie : le connecteur porte le nouveau certificat, ancien ET orphelin retires -> UN SEUL certificat' (@(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1 -and $global:MockTenant.RemovedKeys -eq $rk21e0 + 2) "certs=$(@(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count) retirees=$($global:MockTenant.RemovedKeys - $rk21e0)"

# ===================================================================================================
# POINT 19 : AuthMethod Secret et Both
# ===================================================================================================
Reset-MockState
$base19 = New-Base 'S'; $allBases.Add($base19)
$pS = Get-BaseParams $base19 @('Mail', 'OneDrive'); $pS['AuthMethod'] = 'Secret'
$r19a = Invoke-Connector $pS $base19
$appS = @(Get-MockApp $AppSrc)[0]; $connS = Get-MockConnector $ConnSrc; $stS = Get-Settings $connS; $mkS = Get-MockMarker $connS
$kidS = if ($appS -and @($appS.passwordCredentials).Count -gt 0) { "$($appS.passwordCredentials[0].keyId)" } else { '' }
T 19 'Secret seul : exit 0, 1 secret client (addPassword), AUCUN certificat' ($r19a.Exit -eq 0 -and @($appS.passwordCredentials).Count -eq 1 -and @($appS.keyCredentials).Count -eq 0) "exit=$($r19a.Exit) secrets=$(@($appS.passwordCredentials).Count) certs=$(@($appS.keyCredentials).Count) $($r19a.Crash)"
T 19 'Secret seul : RestClientSecret du connecteur = valeur generee par le tenant, aucun connectorCertificate' ($stS -and $kidS -and $stS.RestClientSecret -eq $global:MockTenant.Secrets[$kidS] -and -not $connS.connectorCertificate) "secret=$([bool]$stS.RestClientSecret) cert=$([bool]$connS.connectorCertificate)"
T 19 'Secret seul : marqueur CIW1|S<keyId du secret>|<AAAAMMJJ> (plus de "SECRET")' ($mkS -and $kidS -and $mkS.Id -eq ('S' + ($kidS -replace '-', '').ToUpperInvariant()) -and $connS.externalKey -notmatch 'SECRET') "externalKey=$($connS.externalKey)"
$r19b = Invoke-Connector (Keep $pS) $base19
T 19 'Secret seul : second passage = zero ecriture (Graph et Cloudiway), exit 0 (la decision de renouvellement reconnait le keyId du marqueur)' ($r19b.Exit -eq 0 -and $r19b.GraphWrites -eq 0 -and $r19b.CiwWrites -eq 0) "exit=$($r19b.Exit) graph=$($r19b.GraphWrites) ciw=$($r19b.CiwWrites) $(Get-WriteBrief $r19b.Calls)"
$pSr = $pS.Clone(); $pSr['RotateCredentials'] = $true
$r19c = Invoke-Connector $pSr $base19
$appS2 = @(Get-MockApp $AppSrc)[0]; $connS2 = Get-MockConnector $ConnSrc; $mkS2 = Get-MockMarker $connS2
T 19 'Secret seul : -RotateCredentials -> UN SEUL secret (l''ancien est retire par removePassword), nouvelle valeur envoyee ; l''externalKey de creation reste FIGE (le portail ne la modifie jamais ; secret seul = pas de fileName a suivre)' ($r19c.Exit -eq 0 -and @($appS2.passwordCredentials).Count -eq 1 -and $global:MockTenant.RemovedSecrets -eq 1 -and $global:MockTenant.RemovedSecretIds -contains $kidS -and $mkS2 -and $mkS2.Id -eq ('S' + ($kidS -replace '-', '').ToUpperInvariant()) -and $connS2.externalKey -eq $connS.externalKey -and (Get-Settings $connS2).RestClientSecret -ne $stS.RestClientSecret) "exit=$($r19c.Exit) secrets=$(@($appS2.passwordCredentials).Count) marqueur=$($connS2.externalKey)"
# Limite documentee (secret seul) : l'externalKey n'est jamais mise a jour, le marqueur designe donc un secret DEJA retire -> -KeepCredentials renouvelle
$kid2 = $mkS2.Id.Substring(1)
foreach ($pc in @($appS2.passwordCredentials)) { if ((("$($pc.keyId)" -replace '-', '').ToUpperInvariant()) -eq $kid2) { $pc.endDateTime = (Microsoft.PowerShell.Utility\Get-Date).ToUniversalTime().AddDays(10).ToString('yyyy-MM-ddTHH:mm:ssZ') } }
$r19d = Invoke-Connector (Keep $pS) $base19
T 19 'Secret seul : marqueur (externalKey de creation) obsolete apres une rotation -> -KeepCredentials renouvelle (toujours 1 seul secret), exit 0' ($r19d.Exit -eq 0 -and @(@(Get-MockApp $AppSrc)[0].passwordCredentials).Count -eq 1 -and $global:MockTenant.RemovedSecrets -eq 2) "exit=$($r19d.Exit) secrets=$(@(@(Get-MockApp $AppSrc)[0].passwordCredentials).Count)"
T 19 'Secret seul : aucun fichier hors run.log / Rapport' ((Get-ExtraFiles $r19a).Count -eq 0 -and (Get-ExtraFiles $r19c).Count -eq 0) "en trop : $((Get-ExtraFiles $r19a) -join ', ')"
# Both
Reset-MockState
$base19b = New-Base 'BO'; $allBases.Add($base19b)
$pBo = Get-BaseParams $base19b @('Mail', 'OneDrive'); $pBo['AuthMethod'] = 'Both'; $pBo['ValidityDays'] = 90
$r19e = Invoke-Connector $pBo $base19b
$appB = @(Get-MockApp $AppSrc)[0]; $connB = Get-MockConnector $ConnSrc; $stB = Get-Settings $connB; $certB = Get-ConnCert $connB; $mkB = Get-MockMarker $connB
$kidB = if ($appB -and @($appB.passwordCredentials).Count -gt 0) { "$($appB.passwordCredentials[0].keyId)" } else { '' }
T 19 'Both : exit 0, 1 certificat ET 1 secret client dans l''application' ($r19e.Exit -eq 0 -and @($appB.keyCredentials).Count -eq 1 -and @($appB.passwordCredentials).Count -eq 1) "exit=$($r19e.Exit) certs=$(@($appB.keyCredentials).Count) secrets=$(@($appB.passwordCredentials).Count) $($r19e.Crash)"
T 19 'Both : le connecteur recoit le certificat (Base64) ET RestClientSecret ; marqueur = empreinte du certificat' ($certB -and $certB.HasKey -and $kidB -and $stB.RestClientSecret -eq $global:MockTenant.Secrets[$kidB] -and $mkB -and $certB.Thumbprint.StartsWith($mkB.Id)) "externalKey=$($connB.externalKey)"
$daysCert = if ($certB) { ($certB.NotAfter - (Microsoft.PowerShell.Utility\Get-Date).ToUniversalTime()).TotalDays } else { 0 }
T 19 '-ValidityDays 90 : certificat valable ~90 jours' ($daysCert -gt 88 -and $daysCert -lt 91) "jours=$([math]::Round($daysCert, 1))"
$r19f = Invoke-Connector (Keep $pBo) $base19b
T 19 'Both : second passage = zero ecriture (Graph et Cloudiway), exit 0' ($r19f.Exit -eq 0 -and $r19f.GraphWrites -eq 0 -and $r19f.CiwWrites -eq 0) "exit=$($r19f.Exit) graph=$($r19f.GraphWrites) ciw=$($r19f.CiwWrites) $(Get-WriteBrief $r19f.Calls)"
$pBor = $pBo.Clone(); $pBor['RotateCredentials'] = $true
$r19g = Invoke-Connector $pBor $base19b
T 19 'Both : -RotateCredentials -> UN SEUL certificat ET UN SEUL secret (anciens retires), connecteur mis a jour (PUT), marqueur sur le nouveau certificat' ($r19g.Exit -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and @(@(Get-MockApp $AppSrc)[0].passwordCredentials).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($r19g.Exit) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"

# ===================================================================================================
# POINT 17 (suite) : transport Path (fichier temporaire supprime), aucun fichier au moment du PATCH keyCredentials
# ===================================================================================================
Reset-MockState
$base17 = New-Base 'PA'; $allBases.Add($base17)
$pPa = Get-BaseParams $base17 @('Mail'); $pPa['CertificateTransport'] = 'Path'
$r17a = Invoke-Connector $pPa $base17
$certPa = (Get-MockConnector $ConnSrc).connectorCertificate
T 17 'transport Path : chemin envoye a Cloudiway, fichier PRESENT au moment de l''appel, puis ecrase et SUPPRIME (aucun PFX temporaire restant)' ($r17a.Exit -eq 0 -and $certPa -and "$($certPa.certificateFile)" -match '\.pfx$' -and $global:MockCiw.CertFileSeen -eq $true -and -not (Test-Path -LiteralPath "$($certPa.certificateFile)") -and $r17a.NewTempPfx.Count -eq 0) "exit=$($r17a.Exit) vu=$($global:MockCiw.CertFileSeen) restant=$($r17a.NewTempPfx -join ',') $($r17a.Crash)"
T 17 'transport Path : aucun fichier sensible dans le dossier de sortie' ((Get-ExtraFiles $r17a).Count -eq 0) "en trop : $((Get-ExtraFiles $r17a) -join ', ')"
Reset-MockState
$base17b = New-Base 'NF'; $allBases.Add($base17b)
$global:HookFiles = -1
$global:MockOpts.OnWrite = {
    param($Method, $Path, $Body)
    if ($Method -eq 'PATCH' -and $Path -like '/applications/*' -and $Body -and $Body.ContainsKey('keyCredentials') -and @($Body.keyCredentials | Where-Object { $_.key }).Count -gt 0) {
        $global:HookFiles = @(Get-ChildItem -LiteralPath $tmpRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.pfx' -or $_.Name -like '*.secret.json' -or $_.Name -like 'etat-*.json' }).Count + @(Get-TempPfx).Count
    }
}
$r17b = Invoke-Connector (Get-BaseParams $base17b @('Mail')) $base17b
$global:MockOpts.OnWrite = $null
T 17 'au moment du PATCH qui ajoute le certificat : aucun .pfx / .secret.json / etat-*.json n''existe (identifiants en memoire seulement)' ($global:HookFiles -eq 0 -and $r17b.Exit -eq 0) "fichiers=$($global:HookFiles) exit=$($r17b.Exit)"

# ===================================================================================================
# POINT 15 : -Workloads en une seule chaine (pwsh -File)
# ===================================================================================================
Reset-MockState
$base15 = New-Base 'P15'; $allBases.Add($base15)
$p15 = Get-BaseParams $base15; $p15['Workloads'] = 'Mail,OneDrive'
$r15 = Invoke-Connector $p15 $base15
$app15 = @(Get-MockApp $AppSrc)[0]
$cmp15 = Compare-Sets (Get-MockAppPerms $app15) $expSrcMailOd
T 15 'chaine "Mail,OneDrive" : pas de crash, exit 0' ([string]::IsNullOrEmpty($r15.Crash) -and $r15.Exit -eq 0) "exit=$($r15.Exit) $($r15.Crash)"
T 15 'chaine "Mail,OneDrive" : permissions = celles de Mail + OneDrive' $cmp15.Equal $cmp15.Text
T 15 'chaine "Mail,OneDrive" : rapport liste Mail, OneDrive' ((Read-RunFile $r15 'Rapport-*.md') -match 'Charges de travail : Mail, OneDrive') 'charges mal normalisees'
Reset-MockState
$p15b = Get-BaseParams (New-Base 'P15b') @('Mail', 'bogus')
$r15b = Invoke-Connector $p15b $p15b.OutDir
T 15 'charge inconnue refusee (exit 1, aucune connexion)' ($r15b.Exit -eq 1 -and $r15b.Connects -eq 0) "exit=$($r15b.Exit)"
# charges non disponibles dans cette version : refusees avec un message clair, avant toute connexion
foreach ($wn in 'SharePoint', 'Teams', 'Archive', 'GalSync', 'Intune', 'FreeBusy', 'Signature', 'MailRouting') {
    Reset-MockState
    $b15x = New-Base ('P15-' + $wn); $allBases.Add($b15x)
    $r15x = Invoke-Connector (Get-BaseParams $b15x @('Mail', $wn)) $b15x
    T 15 "charge $wn : refusee avec « non disponible dans cette version » (exit 1, aucune connexion, aucune ecriture)" ($r15x.Exit -eq 1 -and $r15x.Connects -eq 0 -and $r15x.GraphCalls -eq 0 -and $r15x.CiwWrites -eq 0 -and $r15x.Console -match 'non disponible dans cette version') "exit=$($r15x.Exit) $($r15x.Crash)"
}
Reset-MockState
$b15y = New-Base 'P15-all'; $allBases.Add($b15y)
$p15y = Get-BaseParams $b15y @('All'); $p15y['WhatIf'] = $true
$r15y = Invoke-Connector $p15y $b15y
T 15 '-Workloads All = Mail et OneDrive seulement (rapport), exit 0' ($r15y.Exit -eq 0 -and (Read-RunFile $r15y 'Rapport-*.md') -match 'Charges de travail : Mail, OneDrive') "exit=$($r15y.Exit) $($r15y.Crash)"
# -Mode Cible : refuse a la liaison des parametres (ValidateSet), aucun appel
Reset-MockState
$b15z = New-Base 'P15-mode'
$p15z = Get-BaseParams $b15z @('Mail') 'Target'
$r15z = Invoke-Connector $p15z $b15z
T 15 '-Mode autre que Source : refuse a la liaison des parametres, aucun appel' ($r15z.Calls.Count -eq 0 -and $r15z.Crash -match 'Source') "appels=$($r15z.Calls.Count) crash=$($r15z.Crash)"
# charge non disponible tapee dans la question interactive : message explicite puis nouvelle question
if (-not [Console]::IsInputRedirected) {
    Reset-MockState
    $b15w = New-Base 'P15-ask'; $allBases.Add($b15w)
    $p15w = Get-BaseParams $b15w @(); $p15w.Remove('Workloads'); $p15w['WhatIf'] = $true
    $r15w = Invoke-Connector $p15w $b15w @('Teams', '1', $global:MockCwPassword)
    T 15 'question interactive : « Teams » refuse avec « non disponible dans cette version », puis choix Mail accepte, exit 0' ($r15w.Exit -eq 0 -and $r15w.Console -match 'non disponible dans cette version' -and $r15w.QueueLeft -eq 0) "exit=$($r15w.Exit) file=$($r15w.QueueLeft) $($r15w.Crash)"
}

# ===================================================================================================
# POINT 13 : mode questions (console interactive requise) : tout est demande, y compris le mot de passe masque
# ===================================================================================================
Reset-MockState
$base13 = New-Base 'P13'; $allBases.Add($base13)
if ([Console]::IsInputRedirected) {
    Skip 13 'mode questions' 'entree standard redirigee : Test-Interactive est faux (relancer depuis une console ou laisser le banc se relancer en console masquee)'
} else {
    $q13 = @('contoso.onmicrosoft.com', $global:MockUser, '1,2', $global:MockCwLogin, 'o', $global:MockCwPassword, 'o')   # mode, tenant, admin, charges, compte Cloudiway, demarrer, mot de passe, appliquer
    $r13 = Invoke-Connector @{ OutDir = $base13 } $base13 $q13
    $app13 = @(Get-MockApp $AppSrc)[0]
    $cmp13 = Compare-Sets (Get-MockAppPerms $app13) $expSrcMailOd
    T 13 'pas de crash, exit 0' ([string]::IsNullOrEmpty($r13.Crash) -and $r13.Exit -eq 0) "exit=$($r13.Exit) $($r13.Crash)"
    T 13 'toutes les reponses simulees consommees, file jamais vide' ($r13.QueueLeft -eq 0 -and -not $global:MockReadExhausted) "restant=$($r13.QueueLeft) epuisee=$($global:MockReadExhausted) questions=$($r13.AskedCount)"
    T 13 'meme resultat qu''avec les parametres : permissions Source Mail+OneDrive' $cmp13.Equal $cmp13.Text
    T 13 'connecteur cree, certificat present, coherent' ((Get-MockConnector $ConnSrc) -and @($app13.keyCredentials).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
    T 13 'mot de passe Cloudiway saisi masque (Read-Host -AsSecureString) : jamais dans la console ni dans le journal des questions' ($r13.Console -notmatch [regex]::Escape($global:MockCwPassword) -and (($global:MockReadLog -join "`n") -notmatch [regex]::Escape($global:MockCwPassword))) 'mot de passe affiche'
    $allConsoles.Add(($global:MockReadLog -join "`n"))
}

# ===================================================================================================
# POINT 14 : -Discover
# ===================================================================================================
Reset-MockState
$base14 = New-Base 'P14'; $allBases.Add($base14)
$seedSettings = @{ TenantName = 'contoso'; RestClientId = [guid]::NewGuid().ToString(); RestClientSecret = 'seed-client-secret-seed'; MigrationAccount = 'svc@contoso.onmicrosoft.com'
    MigrationAccountPassword = 'seed-svc-pass-seed'; Domains = @('contoso.onmicrosoft.com'); ServerRegion = 1; AuthenticationType = 3 } | ConvertTo-Json -Compress
$global:MockCiw.Connectors.Add(@{ id = 123; projectId = 12345; connectorTypeId = 2; name = 'Test-manuel'; isTarget = $false; rawProductList = '[5,6]'; rawSettings = $seedSettings; externalKey = 'CIW1|ABCDEF0123456789|20270101'
        connectorCertificate = @{ secret = 'seed-pfx-secret-seed'; certificateFile = 'C:\x.pfx'; connectorId = 123 } })
$p14 = @{ Discover = $true; Cloudiway = $global:MockCwLogin; Yes = $true; OutDir = $base14 }
$r14a = Invoke-Connector $p14 $base14
T 14 'liste : pas de crash, exit 0' ([string]::IsNullOrEmpty($r14a.Crash) -and $r14a.Exit -eq 0) "exit=$($r14a.Exit) $($r14a.Crash)"
T 14 'liste : le connecteur du projet est affiche' ($r14a.Console -match 'Test-manuel') 'connecteur absent de la sortie'
T 14 'liste : AUCUNE connexion au tenant (ni Connect-MgGraph ni requete Graph)' ($r14a.Connects -eq 0 -and $r14a.GraphCalls -eq 0) "connect=$($r14a.Connects) graph=$($r14a.GraphCalls)"
T 14 'liste : aucune ecriture' ($r14a.CiwWrites -eq 0 -and $r14a.GraphWrites -eq 0) 'ecriture en decouverte'
$base14b = New-Base 'P14b'; $allBases.Add($base14b)
$p14b = $p14.Clone(); $p14b['ConnectorId'] = 123; $p14b['OutDir'] = $base14b
$r14b = Invoke-Connector $p14b $base14b
$dj = Read-RunFile $r14b 'decouverte-123.json'
T 14 'detail : decouverte-123.json ecrit, exit 0' ($dj -and $r14b.Exit -eq 0) "exit=$($r14b.Exit) fichier=$([bool]$dj) $($r14b.Crash)"
T 14 'detail : secrets MASQUES (RestClientSecret, MigrationAccountPassword, secret du certificat)' ($dj -and $dj -notmatch 'seed-client-secret-seed' -and $dj -notmatch 'seed-svc-pass-seed' -and $dj -notmatch 'seed-pfx-secret-seed' -and $dj -match 'MASQUE') "fuite=$(@('seed-client-secret-seed', 'seed-svc-pass-seed', 'seed-pfx-secret-seed') | ? { $dj -match $_ })"
T 14 'detail : valeurs non sensibles conservees (RestClientId, produits)' ($dj -match 'RestClientId' -and $dj -match 'rawProductList') 'structure perdue'
T 14 'detail : externalKey (marqueur CIW1, non secret) NON masque dans decouverte-*.json, secrets toujours masques' ($dj -match 'CIW1\|ABCDEF0123456789\|20270101' -and $dj -notmatch 'seed-client-secret-seed') 'externalKey masque ou secret fuite'
T 14 'detail : aucune connexion au tenant, seul fichier supplementaire : decouverte-123.json' ($r14b.Connects -eq 0 -and $r14b.GraphCalls -eq 0 -and (Get-ExtraFiles $r14b @('decouverte-123.json')).Count -eq 0) 'connexion en decouverte'
$base14c = New-Base 'P14c'; $p14c = $p14.Clone(); $p14c['ConnectorId'] = 999; $p14c['OutDir'] = $base14c
$r14c = Invoke-Connector $p14c $base14c
T 14 'detail d''un connecteur inexistant : exit 1 propre' ($r14c.Exit -eq 1 -and [string]::IsNullOrEmpty($r14c.Crash)) "exit=$($r14c.Exit) $($r14c.Crash)"
$base14d = New-Base 'P14d'
$r14d = Invoke-Connector (Use-Pat @{ Discover = $true; Yes = $true; OutDir = $base14d }) $base14d
T 14 'liste avec -CloudiwayPat : aucun mot de passe demande, exit 0' ($r14d.Exit -eq 0 -and $r14d.AskedCount -eq 0 -and $r14d.Console -match 'Test-manuel') "exit=$($r14d.Exit) questions=$($r14d.AskedCount) $($r14d.Crash)"

# ===================================================================================================
# BONUS : robustesse (429, 403 cible, propagation Entra, -SkipCloudiway, module)
# ===================================================================================================
Reset-MockState; $global:MockOpts.Throttle = @(@{ Method = 'GET'; Pattern = '^/applications$'; Times = 2 }, @{ Method = 'POST'; Pattern = '^/applications$'; Times = 1 })
$baseB = New-Base 'B1'; $allBases.Add($baseB)
$rB1 = Invoke-Connector (Get-BaseParams $baseB) $baseB
T B 'B2 429 (lecture puis ecriture) puis succes : exit 0, application creee une seule fois' ($rB1.Exit -eq 0 -and @(Get-MockApp $AppSrc).Count -eq 1 -and $global:MockSleeps.Count -ge 3) "exit=$($rB1.Exit) apps=$(@(Get-MockApp $AppSrc).Count) pauses=$($global:MockSleeps.Count) $($rB1.Crash)"
Reset-MockState; $global:MockOpts.Forbid = @(@{ Method = 'POST'; Pattern = '^/applications$' })
$baseB = New-Base 'B3'; $allBases.Add($baseB)
$rB3 = Invoke-Connector (Get-BaseParams $baseB @('OneDrive')) $baseB
T B 'B3 403 sur POST /applications : exit 2, pas de crash, Cloudiway non touche' ($rB3.Exit -eq 2 -and [string]::IsNullOrEmpty($rB3.Crash) -and @($global:MockCiw.Connectors).Count -eq 0) "exit=$($rB3.Exit) connecteurs=$(@($global:MockCiw.Connectors).Count) $($rB3.Crash)"
T B 'B3b 403 : les etapes dependantes sont IGNOREES et le rapport l''indique' ($rB3.Console -match 'IGNORE' -and ((Read-RunFile $rB3 'Rapport-*.md') -match 'ECHEC')) 'rapport sans ECHEC/IGNORE'
Reset-MockState; $global:MockOpts.Replication404 = 2; $global:MockTenant.Rep404Left = 2
$baseB = New-Base 'B4'; $allBases.Add($baseB)
$rB4 = Invoke-Connector (Get-BaseParams $baseB) $baseB
T B 'B4 propagation Entra (404 sur POST /servicePrincipals x2) : reprise puis succes, exit 0' ($rB4.Exit -eq 0 -and (Get-MockSp $AppSrc)) "exit=$($rB4.Exit) $($rB4.Crash)"
Reset-MockState; $global:MockOpts.ModuleMissing = $true
$baseB = New-Base 'B6'; $allBases.Add($baseB)
$pB6 = Get-BaseParams $baseB; $pB6['InstallMissingModules'] = $true
$rB6 = Invoke-Connector $pB6 $baseB
T B 'B6 module Graph absent + -InstallMissingModules : installation simulee puis execution, exit 0' ($rB6.Exit -eq 0 -and @($rB6.Calls | Where-Object { $_.Method -eq 'INSTALL-MODULE' }).Count -eq 1) "exit=$($rB6.Exit) installs=$(@($rB6.Calls | ? { $_.Method -eq 'INSTALL-MODULE' }).Count) $($rB6.Crash)"
Reset-MockState
$baseB = New-Base 'B7'; $allBases.Add($baseB)
$pB7b = Get-BaseParams $baseB; $pB7b['ConnectorName'] = 'Mon-Connecteur'; $pB7b['AppName'] = 'MON-APP'; $pB7b['ServiceAccountName'] = 'svc-ciw-perso'
$rB7b = Invoke-Connector $pB7b $baseB
T B 'B7 -ConnectorName / -AppName explicites respectes (noms codifies surchargeables), connecteur coherent' ((Get-MockConnector 'Mon-Connecteur') -and (Get-MockApp 'MON-APP') -and $rB7b.Exit -eq 0 -and (Test-ConnCoherence 'Mon-Connecteur' 'MON-APP') -eq '') "exit=$($rB7b.Exit) $($rB7b.Crash)"

# ===================================================================================================
# BONUS : decisions de conception (adoption du connecteur, sens, 5xx, optionnel, SP de ressource, interruption)
# ===================================================================================================
function Add-SeedConnector([string]$Name, [bool]$IsTarget, [string]$Products, [string]$ExternalKey = '') {
    $st = @{ TenantName = 'contoso'; RestClientId = 'ffffffff-0000-0000-0000-000000000001'; Domains = @('autre.example.com'); ServerRegion = 1; AuthenticationType = 3; UnknownKey = 'cle-inconnue-a-conserver' } | ConvertTo-Json -Compress
    $c = @{ id = 777; projectId = $global:MockProjectId; connectorTypeId = 2; name = $Name; isTarget = $IsTarget; rawProductList = $Products; rawSettings = $st
        connectorCertificate = @{ secret = 'seed-cert-secret-seed'; certificateFile = 'SEED-CERT-FILE'; connectorId = 777 }; customTopKey = 'cle-haute-a-conserver' }
    if ($ExternalKey) { $c['externalKey'] = $ExternalKey }
    $global:MockCiw.Connectors.Add($c)
}

# --- Connecteur cree a la main -> BLOQUE (aucun identifiant genere) ; puis adoption sans perte ---
Reset-MockState
$baseN1 = New-Base 'N1'; $allBases.Add($baseN1)
Add-SeedConnector $ConnSrc $false '[6]'
$pN1 = Get-BaseParams $baseN1 @('Mail')
$rN1a = Invoke-Connector $pN1 $baseN1
$cwN1 = @(Get-PlanRows $rN1a | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T B 'connecteur cree a la main : ligne Cloudiway BLOQUE (mention -AdoptExisting), aucune ecriture Cloudiway' ($cwN1 -and $cwN1.Action -eq 'BLOQUE' -and $cwN1.Raison -match 'AdoptExisting' -and $rN1a.CiwWrites -eq 0 -and $global:MockCiw.PutCount -eq 0) "ligne=$($cwN1.Action) '$($cwN1.Raison)' ecritures=$($rN1a.CiwWrites)"
T B 'connecteur bloque : aucun certificat genere (il s''empilerait a chaque relance)' (@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 0) "certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count)"
$pN1b = $pN1.Clone(); $pN1b['AdoptExisting'] = $true
$rN1b = Invoke-Connector $pN1b $baseN1
$cN1 = Get-MockConnector $ConnSrc
$stN1 = Get-Settings $cN1
$appN1 = @(Get-MockApp $AppSrc)[0]
T B 'adoption : PUT unique, exit 0, marqueur CIW1 pose (remplace l''absence de marque)' ($rN1b.Exit -eq 0 -and $global:MockCiw.PutCount -eq 1 -and (Get-MockMarker $cN1)) "exit=$($rN1b.Exit) PUT=$($global:MockCiw.PutCount) externalKey=$($cN1.externalKey)"
T B 'adoption : produits en UNION ([6] + [5] = [5,6]), aucun retrait' ($cN1.rawProductList -eq '[5,6]') "produits=$($cN1.rawProductList)"
$sentN1 = try { $cN1._body.rawSettings | ConvertFrom-Json } catch { $null }
T B 'adoption : cle inconnue de rawSettings et cle haute ENVOYEES telles que lues (copie profonde) ; le portail re-serialise rawSettings et supprime la cle inconnue (fait mesure 3, banc fidele)' ($sentN1 -and $sentN1.UnknownKey -eq 'cle-inconnue-a-conserver' -and $cN1._body.customTopKey -eq 'cle-haute-a-conserver' -and $stN1 -and -not $stN1.UnknownKey) 'copie profonde ou fidelite du banc'
T B 'adoption : RestClientId mis a jour, domaine ajoute sans retirer l''ancien, region et authentification inchangees' ($stN1 -and $stN1.RestClientId -eq $appN1.appId -and @($stN1.Domains) -contains 'contoso.onmicrosoft.com' -and @($stN1.Domains) -contains 'autre.example.com' -and $stN1.ServerRegion -eq 1 -and $stN1.AuthenticationType -eq 3) "settings=$($cN1.rawSettings)"
T B 'adoption : sens inchange ; certificat remplace par le NOUVEAU (valeurs de graine absentes), coherent avec l''application' ($cN1.isTarget -eq $false -and $cN1.connectorCertificate.certificateFile -ne 'SEED-CERT-FILE' -and $cN1.connectorCertificate.secret -ne 'seed-cert-secret-seed' -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
$rN1c = Invoke-Connector (Keep $pN1b) $baseN1
T B 'adoption rejouee : zero ecriture (Graph et Cloudiway), exit 0' ($rN1c.Exit -eq 0 -and $rN1c.GraphWrites -eq 0 -and $rN1c.CiwWrites -eq 0) "exit=$($rN1c.Exit) graph=$($rN1c.GraphWrites) ciw=$($rN1c.CiwWrites) $(Get-WriteBrief $rN1c.Calls)"

# --- Sens different -> BLOQUE (meme marque, meme avec -AdoptExisting) ---
Reset-MockState
$baseN2 = New-Base 'N2'; $allBases.Add($baseN2)
Add-SeedConnector $ConnSrc $true '[5]' 'CloudiwayConnector'
$pN2 = Get-BaseParams $baseN2 @('Mail'); $pN2['AdoptExisting'] = $true
$rN2 = Invoke-Connector $pN2 $baseN2
$cwN2 = @(Get-PlanRows $rN2 | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T B 'sens different (Cible existante, Source demandee) : BLOQUE meme avec -AdoptExisting, aucune ecriture, connecteur intact, aucun certificat genere' ($cwN2 -and $cwN2.Action -eq 'BLOQUE' -and $cwN2.Raison -match 'sens' -and $rN2.CiwWrites -eq 0 -and (Get-MockConnector $ConnSrc).isTarget -eq $true -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 0) "ligne=$($cwN2.Action) '$($cwN2.Raison)'"

# --- Interruption simulee (exception hors des Apply) : aucun fichier sensible, aucun PFX temporaire ---
Reset-MockState
$baseN4 = New-Base 'N4'; $allBases.Add($baseN4)
$global:MockOpts.OnWrite = { param($Method, $Path, $Body) if ($Method -eq 'POST' -and $Path -eq '/roleManagement/directory/roleAssignments') { $global:MockThrowOnDate = $true } }   # arme apres le dernier role attribue
$pN4 = Get-BaseParams $baseN4 @('Mail'); $pN4['CertificateTransport'] = 'Path'
$rN4 = Invoke-Connector $pN4 $baseN4
$global:MockOpts.OnWrite = $null; $global:MockThrowOnDate = $false
T B 'exception simulee apres l''application : l''execution est interrompue (pas de code de sortie normal)' ($rN4.Crash -match 'interruption simulee') "crash='$($rN4.Crash)'"
T B 'exception simulee : aucun fichier sensible (ni .pfx, ni .secret.json) et aucun PFX temporaire laisse dans %TEMP%' ((Get-ExtraFiles $rN4).Count -eq 0 -and $rN4.NewTempPfx.Count -eq 0) "en trop : $((Get-ExtraFiles $rN4) -join ', ') temp=$($rN4.NewTempPfx -join ',')"

# --- 5xx : un POST n'est jamais rejoue, un GET l'est ---
Reset-MockState
$global:MockOpts.GraphFail = @(@{ Method = 'POST'; Pattern = '^/applications$'; Code = 504; Times = 1 }, @{ Method = 'GET'; Pattern = '^/organization$'; Code = 504; Times = 1 })
$baseN5 = New-Base 'N5'; $allBases.Add($baseN5)
$pN5 = Get-BaseParams $baseN5 @('Mail'); $pN5['SkipCloudiway'] = $true; $pN5.Remove('Cloudiway'); $pN5['ProjectId'] = 12345
$rN5 = Invoke-Connector $pN5 $baseN5
$postApp = @($rN5.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'POST' -and $_.Path -eq '/applications' })
$getOrg = @($rN5.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'GET' -and $_.Path -eq '/organization' })
T B '504 sur POST /applications : UNE seule tentative (non rejoue), aucune application creee, exit 2' ($postApp.Count -eq 1 -and $postApp[0].Status -eq '504' -and @(Get-MockApp $AppSrc).Count -eq 0 -and $rN5.Exit -eq 2) "POST=$($postApp.Count) exit=$($rN5.Exit)"
T B '504 sur GET /organization : rejoue (2 appels), le passage continue' ($getOrg.Count -ge 2 -and $getOrg[0].Status -eq '504') "GET=$($getOrg.Count)"
Reset-MockState
$global:MockOpts.CiwFail = @(@{ Method = 'POST'; Pattern = '^/Connectors$'; Code = 503; Times = 1 }, @{ Method = 'GET'; Pattern = '^/Projects$'; Code = 503; Times = 1 })
$baseN5b = New-Base 'N5b'; $allBases.Add($baseN5b)
$rN5b = Invoke-Connector (Get-BaseParams $baseN5b @('Mail')) $baseN5b
$postC = @($rN5b.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Method -eq 'POST' -and $_.Path -eq '/Connectors' })
$getP = @($rN5b.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Method -eq 'GET' -and $_.Path -eq '/Projects' })
T B 'Cloudiway : 503 sur POST /Connectors non rejoue (1 tentative, aucun connecteur, exit 2)' ($postC.Count -eq 1 -and $postC[0].Status -eq '503' -and @($global:MockCiw.Connectors).Count -eq 0 -and $rN5b.Exit -eq 2) "POST=$($postC.Count) connecteurs=$(@($global:MockCiw.Connectors).Count) exit=$($rN5b.Exit)"
T B 'Cloudiway : 503 sur GET /Projects rejoue (2 appels) et le portail reste utilisable' ($getP.Count -ge 2) "GET=$($getP.Count)"

# --- Principal de service de ressource absent : cree ---
Reset-MockState
$exSp = Get-MockResSp '00000002-0000-0ff1-ce00-000000000000'; [void]$global:MockTenant.Sps.Remove($exSp); $global:MockHidden.Add($exSp)
$baseN7 = New-Base 'N7'; $allBases.Add($baseN7)
$pN7 = Get-BaseParams $baseN7 @('Mail'); $pN7['SkipCloudiway'] = $true; $pN7.Remove('Cloudiway'); $pN7['ProjectId'] = 12345
$rN7 = Invoke-Connector $pN7 $baseN7
$spPosts = @($rN7.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'POST' -and $_.Path -eq '/servicePrincipals' })
T B 'principal de service de ressource absent (Exchange) : cree, consentement complet, exit 0' ($spPosts.Count -eq 2 -and @($spPosts | Where-Object { $_.Body -match '00000002-0000-0ff1-ce00-000000000000' }).Count -eq 1 -and (Get-ConsentGaps $AppSrc).Count -eq 0 -and $rN7.Exit -eq 0) "POST /servicePrincipals=$($spPosts.Count) exit=$($rN7.Exit) manques=$((Get-ConsentGaps $AppSrc) -join ';')"

# --- -Discover avec un faux PAT ---
Reset-MockState
$baseN9 = New-Base 'N9'; $allBases.Add($baseN9)
$pN9 = @{ Discover = $true; CloudiwayPat = (New-TestSecure 'pat-mauvais-pat'); Yes = $true; OutDir = $baseN9 }
$rN9 = Invoke-Connector $pN9 $baseN9
T B '-Discover avec faux PAT : exit 1 propre, aucune connexion au tenant, aucune ecriture, PAT absent de la sortie' ($rN9.Exit -eq 1 -and [string]::IsNullOrEmpty($rN9.Crash) -and $rN9.Connects -eq 0 -and $rN9.GraphCalls -eq 0 -and $rN9.CiwWrites -eq 0 -and $rN9.Console -notmatch 'pat-mauvais-pat') "exit=$($rN9.Exit) $($rN9.Crash)"
# ===================================================================================================
# CORRECTIFS V2.1 (2026-10-31) - points 25 a 28 : flux Cloudiway, Graph, mineurs, documentation
# ===================================================================================================
function Set-MockConnectorSetting($Conn, [string]$Key, $Value) {
    $s = $Conn.rawSettings | ConvertFrom-Json -AsHashtable
    $s[$Key] = $Value
    $Conn.rawSettings = ($s | ConvertTo-Json -Compress)
}
function Get-PutBodyJson($Conn) { if ($Conn -and $Conn._body) { $Conn._body | ConvertTo-Json -Depth 20 -Compress } else { '' } }
function New-SourceMailOd([string]$Tag, [hashtable]$Extra = @{}) {
    # Source Mail+OneDrive, produits 5,6 : cree le connecteur. Retourne @{ Base; Params; Run }
    Reset-MockState
    $b = New-Base $Tag; $allBases.Add($b)
    $p = Get-BaseParams $b @('Mail', 'OneDrive'); $p['ProductIds'] = '5,6'
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    @{ Base = $b; Params = $p; Run = (Invoke-Connector $p $b) }
}

# --- B1 (v2.4, faits mesures 4) : mise a jour necessaire SANS nouvel identifiant (-KeepCredentials) : le portail exige le certificat lors d'un PUT -> BLOQUE, aucun PUT ---
$q1 = New-SourceMailOd 'Q1'
$cQ1 = Get-MockConnector $ConnSrc; $stQ1 = Get-Settings $cQ1; $certQ1 = Get-ConnCert $cQ1; $fileQ1 = $cQ1.connectorCertificate.fileName
$global:MockOpts.CiwMaskSecrets = $true   # le portail masque secrets et contenu du certificat a la lecture
$pQ1b = $q1.Params.Clone(); $pQ1b['ProductIds'] = '5,6,7'; $pQ1b['KeepCredentials'] = $true
$putA0 = $global:MockCiw.PutAttempts
$rQ1b = Invoke-Connector $pQ1b $q1.Base
$cQ1b = Get-MockConnector $ConnSrc; $certQ1b = Get-ConnCert $cQ1b
$cwQ1 = @(Get-PlanRows $rQ1b | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T 25 'B1 (d) : -KeepCredentials + produit manquant sur un connecteur qui possede un certificat : ligne Cloudiway BLOQUE « le portail exige le certificat lors d''une mise a jour : relancer sans -KeepCredentials »' ($cwQ1 -and $cwQ1.Action -eq 'BLOQUE' -and $cwQ1.Raison -match 'le portail exige le certificat lors d.une mise a jour' -and $cwQ1.Raison -match 'relancer sans -KeepCredentials') "ligne=$($cwQ1.Action) $($cwQ1.Raison)"
T 25 'B1 (d) : AUCUN PUT n''est tente (pas de PUT sans certificat : HTTP 500 constate), aucune ecriture Graph, connecteur inchange (produits, certificat, fichier), code de sortie 1' ($rQ1b.Exit -eq 1 -and $global:MockCiw.PutAttempts -eq $putA0 -and $rQ1b.CiwWrites -eq 0 -and $rQ1b.GraphWrites -eq 0 -and $cQ1b.rawProductList -eq '[5,6]' -and $certQ1b.Thumbprint -eq $certQ1.Thumbprint -and $cQ1b.connectorCertificate.fileName -eq $fileQ1) "exit=$($rQ1b.Exit) tentatives=$($global:MockCiw.PutAttempts - $putA0) produits=$($cQ1b.rawProductList)"
$global:MockOpts.CiwMaskSecrets = $false
# meme situation mais le marqueur est incoherent (renouvellement decide par le module Entra) : le PUT part AVEC le certificat, produits en union
$cQ1c = Get-MockConnector $ConnSrc; $cQ1c.connectorCertificate.fileName = 'CIW1_' + ('AB' * 16) + '_20270101.pfx'
$global:MockOpts.CiwMaskSecrets = $true
$rQ1c = Invoke-Connector $pQ1b $q1.Base
$cQ1d = Get-MockConnector $ConnSrc; $stQ1d = Get-Settings $cQ1d; $certQ1d = Get-ConnCert $cQ1d
T 25 'B1 : -KeepCredentials avec marqueur incoherent (renouvellement) + produit manquant : un seul PUT AVEC le nouveau certificat, produits en union [5,6,7], aucun masque renvoye, connecteur coherent, exit 0' ($rQ1c.Exit -eq 0 -and $cQ1d.rawProductList -eq '[5,6,7]' -and $certQ1d.Thumbprint -ne $certQ1.Thumbprint -and $stQ1d.MigrationAccount -eq $SvcTgt -and $stQ1d.RestClientId -eq $stQ1.RestClientId -and (Get-PutBodyJson $cQ1d) -notmatch '\*{4}' -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rQ1c.Exit) produits=$($cQ1d.rawProductList) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
$global:MockOpts.CiwMaskSecrets = $false
# poolId / connectorTypeId : le corps du PUT reprend la lecture, sinon le portail les remet a 0 (fait mesure 5)
T 25 'B1 : poolId et connectorTypeId du connecteur NON remis a 0 par le PUT (le corps reprend la lecture)' ($cQ1d.poolId -eq 3 -and "$($cQ1d.connectorTypeId)" -eq '2') "poolId=$($cQ1d.poolId) connectorTypeId=$($cQ1d.connectorTypeId)"

# --- B2 : adoption d'un connecteur fait a la main : remplacements dits en clair, confirmation supplementaire (sauf -Yes) ---
Reset-MockState
$baseQ4 = New-Base 'Q4'; $allBases.Add($baseQ4)
Add-SeedConnector $ConnSrc $false '[6]'
$pQ4 = Get-BaseParams $baseQ4 @('Mail'); $pQ4['AdoptExisting'] = $true
$pQ4w = $pQ4.Clone(); $pQ4w['WhatIf'] = $true
$rQ4w = Invoke-Connector $pQ4w $baseQ4
$planQ4 = (Get-PlanRows $rQ4w | Where-Object { $_.Zone -eq 'Cloudiway' } | Select-Object -First 1).Raison
T 25 'B2 : le plan d''adoption dit en clair que certificat, RestClientId et mot de passe du compte seront REMPLACES' ($planQ4 -match 'ADOPTION' -and $planQ4 -match 'certificat' -and $planQ4 -match 'RestClientId' -and $planQ4 -match 'mot de passe' -and $planQ4 -match 'REMPLACES') "plan=$planQ4"
T 25 'B2 : avertissement affiche avant application (WARN ADOPTION ... REMPLACES)' ($rQ4w.Console -match 'ADOPTION d''un connecteur fait a la main' -and $rQ4w.Console -match 'REMPLACES') 'avertissement absent'
if ([Console]::IsInputRedirected) {
    Skip 25 'B2 : confirmation supplementaire de l''adoption' 'entree standard redirigee : Test-Interactive est faux'
} else {
    $pQ4n = $pQ4.Clone(); $pQ4n.Remove('Yes')
    $rQ4n = Invoke-Connector $pQ4n $baseQ4 @($global:MockCwPassword, 'n')
    T 25 'B2 : sans -Yes, refus de l''ADOPTION (reponse N) : exit 1, aucune ecriture Graph ni Cloudiway, connecteur intact' ($rQ4n.Exit -eq 1 -and $rQ4n.GraphWrites -eq 0 -and $rQ4n.CiwWrites -eq 0 -and $rQ4n.Console -match 'Adoption non confirmee' -and (Get-MockConnector $ConnSrc).rawProductList -eq '[6]') "exit=$($rQ4n.Exit) graph=$($rQ4n.GraphWrites) ciw=$($rQ4n.CiwWrites)"
    $rQ4o = Invoke-Connector $pQ4n $baseQ4 @($global:MockCwPassword, 'o', 'o')
    T 25 'B2 : sans -Yes, deux confirmations (adoption puis plan) : le connecteur est adopte (exit 0, marqueur pose)' ($rQ4o.Exit -eq 0 -and (Get-MockMarker (Get-MockConnector $ConnSrc)) -and $rQ4o.QueueLeft -eq 0) "exit=$($rQ4o.Exit) file=$($rQ4o.QueueLeft) $($rQ4o.Crash)"
}

# --- M1 : jeton (keepConnection = true), 401 en cours de route : une seule re-authentification, message actionnable ---
$srcCiw = Get-Content -LiteralPath (Join-Path $pkg 'lib\cloudiway.ps1') -Raw -Encoding utf8
T 25 'M1 : le login n''envoie plus keepConnection = $false (source) ; le faux Cloudiway refuse tout login sans keepConnection = true' ($srcCiw -match 'keepConnection = \$true' -and $srcCiw -notmatch 'keepConnection = \$false' -and $r1.Exit -eq 0) 'keepConnection'
Reset-MockState
$global:MockOpts.CiwExpire = @(@{ Method = 'POST'; Path = '^/Connectors$'; Nth = 1; Seen = 0 })
$baseM1 = New-Base 'M1a'; $allBases.Add($baseM1)
$rM1a = Invoke-Connector (Get-BaseParams $baseM1 @('Mail')) $baseM1 @($global:MockCwPassword, $global:MockCwPassword)
T 25 'M1 : jeton expire pendant l''ecriture du connecteur : mot de passe redemande UNE fois, requete rejouee, connecteur cree une seule fois, exit 0' ($rM1a.Exit -eq 0 -and @($global:MockCiw.Connectors).Count -eq 1 -and @($rM1a.Calls | Where-Object { $_.Path -eq '/Authentication/Login' }).Count -eq 2 -and $rM1a.Console -match 'Session Cloudiway expiree' -and $rM1a.QueueLeft -eq 0) "exit=$($rM1a.Exit) connecteurs=$(@($global:MockCiw.Connectors).Count) logins=$(@($rM1a.Calls | Where-Object { $_.Path -eq '/Authentication/Login' }).Count) $($rM1a.Crash)"
Reset-MockState
$global:MockOpts.CiwExpire = @(@{ Method = 'POST'; Path = '^/Connectors$'; Nth = 1; Seen = 0 })
$baseM1 = New-Base 'M1b'; $allBases.Add($baseM1)
$rM1b = Invoke-Connector (Use-Pat (Get-BaseParams $baseM1 @('Mail'))) $baseM1
T 25 'M1 : avec un PAT, la re-authentification est silencieuse (aucun mot de passe demande), connecteur cree, exit 0' ($rM1b.Exit -eq 0 -and $rM1b.AskedCount -eq 0 -and @($global:MockCiw.Connectors).Count -eq 1 -and @($rM1b.Calls | Where-Object { $_.Path -eq '/Authentication/TechnicalLogin' }).Count -eq 2) "exit=$($rM1b.Exit) questions=$($rM1b.AskedCount) $($rM1b.Crash)"
Reset-MockState
$global:MockOpts.CiwExpire = @(@{ Method = 'POST'; Path = '^/Connectors$'; Nth = 1; Seen = 0 })
$baseM1 = New-Base 'M1c'; $allBases.Add($baseM1)
$rM1c = Invoke-Connector (Get-BaseParams $baseM1 @('Mail')) $baseM1   # une seule reponse en file : la re-saisie est impossible
T 25 'M1 : re-authentification impossible : message clair "session Cloudiway expiree ... relancer" (pas "HTTP 401 : Unauthorized"), aucun connecteur, exit 2' ($rM1c.Exit -eq 2 -and $rM1c.Console -cmatch 'session Cloudiway expiree ou refusee' -and $rM1c.Console -notmatch 'Unauthorized' -and @($global:MockCiw.Connectors).Count -eq 0) "exit=$($rM1c.Exit)"

# --- M2 : le tenant n'est pas modifie avant de savoir que Cloudiway est joignable ; ordre mot de passe / connecteur ---
Reset-MockState
$global:MockOpts.CiwExpire = @(@{ Method = 'GET'; Path = '^/Projects$'; Nth = 3; Seen = 0 })   # 3e lecture = reverification juste avant l'application
$baseM2 = New-Base 'M2a'; $allBases.Add($baseM2)
$rM2a = Invoke-Connector (Get-BaseParams $baseM2 @('Mail')) $baseM2
T 25 'M2 : session Cloudiway expiree juste avant l''application (re-saisie impossible) : exit 1, AUCUNE ecriture dans le tenant ni dans Cloudiway' ($rM2a.Exit -eq 1 -and $rM2a.GraphWrites -eq 0 -and $rM2a.CiwWrites -eq 0 -and @($global:MockTenant.Apps).Count -eq 0 -and $rM2a.Console -match 'Session Cloudiway invalide juste avant') "exit=$($rM2a.Exit) graph=$($rM2a.GraphWrites) $($rM2a.Crash)"
Reset-MockState
$global:MockOpts.CiwExpire = @(@{ Method = 'GET'; Path = '^/Projects$'; Nth = 3; Seen = 0 })
$baseM2 = New-Base 'M2b'; $allBases.Add($baseM2)
$rM2b = Invoke-Connector (Get-BaseParams $baseM2 @('Mail')) $baseM2 @($global:MockCwPassword, $global:MockCwPassword)
T 25 'M2 : meme cas avec re-saisie du mot de passe : la session est renouvelee AVANT la premiere ecriture, tout est applique, exit 0' ($rM2b.Exit -eq 0 -and (Get-MockConnector $ConnSrc) -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rM2b.Exit) $($rM2b.Crash)"
# --- M3 : avertissement avant rotation sur connecteur existant ; certificat seul expire = PAS de reinitialisation du mot de passe ---
T 25 'M3 : rotation sur connecteur existant : avertissement "ne pas appliquer pendant que des jobs de migration sont actifs" avant application' ($r10.Console -match 'jobs de migration sont actifs') 'avertissement absent'
# --- M4 : collision de noms (TenantName / RestClientId differents) ---
$q8 = New-SourceMailOd 'Q8'
Set-MockConnectorSetting (Get-MockConnector $ConnSrc) 'TenantName' 'autre-tenant'
$certsQ8 = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count; $put8 = $global:MockCiw.PutCount
$rQ8 = Invoke-Connector $q8.Params $q8.Base
$cwQ8 = @(Get-PlanRows $rQ8 | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T 25 'M4 : connecteur marque CIW1 designant un AUTRE TenantName : ligne Cloudiway BLOQUE (collision), aucun PUT, aucun certificat genere' ($cwQ8 -and $cwQ8.Action -eq 'BLOQUE' -and $cwQ8.Raison -match 'collision' -and $cwQ8.Raison -match 'autre-tenant' -and $global:MockCiw.PutCount -eq $put8 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq $certsQ8) "ligne=$($cwQ8.Action) $($cwQ8.Raison)"
$pQ8a = $q8.Params.Clone(); $pQ8a['AdoptExisting'] = $true
$rQ8a = Invoke-Connector $pQ8a $q8.Base
T 25 'M4 : avec -AdoptExisting le blocage est leve et le TenantName est corrige (PUT), exit 0' ($rQ8a.Exit -eq 0 -and (Get-Settings (Get-MockConnector $ConnSrc)).TenantName -eq 'contoso') "exit=$($rQ8a.Exit) tenantName=$((Get-Settings (Get-MockConnector $ConnSrc)).TenantName)"
$q9 = New-SourceMailOd 'Q9'
Set-MockConnectorSetting (Get-MockConnector $ConnSrc) 'RestClientId' '99999999-0000-0000-0000-000000000009'
$certsQ9 = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count
$rQ9 = Invoke-Connector $q9.Params $q9.Base
$cwQ9 = @(Get-PlanRows $rQ9 | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T 25 'M4 : connecteur marque CIW1 designant une AUTRE application (RestClientId) : BLOQUE (collision), aucun identifiant genere' ($cwQ9 -and $cwQ9.Action -eq 'BLOQUE' -and $cwQ9.Raison -match 'application' -and $cwQ9.Raison -match '99999999' -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq $certsQ9) "ligne=$($cwQ9.Action) $($cwQ9.Raison)"
# application supprimee dans le tenant alors que le connecteur existe : meme collision, rien n'est genere
$null = $global:MockTenant.Apps.RemoveAll([Predicate[object]]{ param($x) $x.displayName -eq 'CLOUDIWAY-SOURCE-P12345' })
$rQ9b = Invoke-Connector $q9.Params $q9.Base
$cwQ9b = @(Get-PlanRows $rQ9b | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T 25 'M4 : application absente du tenant alors que le connecteur existe : Cloudiway BLOQUE (collision), AUCUN certificat genere pour l''application recreee' ($cwQ9b -and $cwQ9b.Action -eq 'BLOQUE' -and $cwQ9b.Raison -match 'n''existe pas' -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 0) "ligne=$($cwQ9b.Action) $($cwQ9b.Raison)"

# --- M5 : 2FA Cloudiway ---
Reset-MockState; $global:MockCiw.LoginMode = '2fa'
$baseM5 = New-Base 'M5'; $allBases.Add($baseM5)
$rM5 = Invoke-Connector (Get-BaseParams $baseM5 @('Mail')) $baseM5
T 25 'M5 : connexion acceptee sans jeton (2FA) : exit 1 avant toute connexion au tenant, message dedie PAT (ACCOUNT > Security, -CloudiwayPat, Read-Host -AsSecureString)' ($rM5.Exit -eq 1 -and $rM5.Connects -eq 0 -and $rM5.GraphCalls -eq 0 -and $rM5.Console -match 'ACCOUNT > Security' -and $rM5.Console -match '-CloudiwayPat' -and $rM5.Console -match 'Read-Host -AsSecureString') "exit=$($rM5.Exit)"

# --- M6 / M7 / M9 / M10 : lanceur, documentation ---
$cmdPath = Join-Path $pkg 'cloudiway-connector.cmd'
$launcherTxt = [System.IO.File]::ReadAllText((Join-Path $pkg 'cloudiway-connector-launcher.ps1'))
$cmdTxt = if (Test-Path -LiteralPath $cmdPath) { [System.IO.File]::ReadAllText($cmdPath) } else { '' }
T 28 'M6 : cloudiway-connector.cmd present a la racine : lance powershell.exe (5.1) sur le lanceur avec %*, pause ; le lanceur debloque (Unblock-File), verifie PowerShell 7.2 et propose winget apres confirmation' ($cmdTxt -match 'powershell\.exe' -and $cmdTxt -match 'cloudiway-connector-launcher\.ps1' -and $cmdTxt -match '%\*' -and $cmdTxt -match '(?im)^\s*pause' -and $launcherTxt -match 'Unblock-File' -and $launcherTxt -match 'winget install --id Microsoft\.PowerShell' -and $launcherTxt -match 'Read-YesNo' -and $launcherTxt -match 'cloudiway-connector\.ps1') 'lanceur absent ou incomplet'
T 28 'M6 : cloudiway-connector.cmd en CRLF, sans BOM (cmd.exe), sans emoji' ($cmdTxt -and $cmdTxt.Contains("`r`n") -and -not ($cmdTxt -match "(?<!`r)`n") -and [System.IO.File]::ReadAllBytes($cmdPath)[0] -ne 0xEF) 'fin de ligne ou BOM'

# --- 11 : propagation Entra : 400 "does not reference a valid application object" apres la creation de l'application ---
Reset-MockState; $global:MockOpts.Replication400 = 2; $global:MockTenant.Rep400Left = 2
$baseG1 = New-Base 'G1'; $allBases.Add($baseG1)
$rG1 = Invoke-Connector (Get-BaseParams $baseG1 @('Mail')) $baseG1
T 26 '11 creation du principal de service : 400 "does not reference a valid application object" x2 -> reessai puis succes, exit 0' ($rG1.Exit -eq 0 -and (Get-MockSp $AppSrc) -and @($rG1.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'POST' -and $_.Path -eq '/servicePrincipals' -and $_.Status -eq '400' }).Count -ge 2) "exit=$($rG1.Exit) $($rG1.Crash)"
# 11 : GET / PATCH keyCredentials et addPassword enveloppes dans le reessai (404 de propagation)
Reset-MockState
$global:MockOpts.GraphFail = @(
    @{ Method = 'GET'; Pattern = '^/applications/[^/]+$'; Query = 'keyCredentials'; Code = 404; Times = 3 },
    @{ Method = 'PATCH'; Pattern = '^/applications/[^/]+$'; Code = 404; Times = 1 },
    @{ Method = 'POST'; Pattern = '/addPassword$'; Code = 404; Times = 1 })
$baseG2 = New-Base 'G2'; $allBases.Add($baseG2)
$pG2 = Get-BaseParams $baseG2 @('Mail'); $pG2['AuthMethod'] = 'Both'
$rG2 = Invoke-Connector $pG2 $baseG2
$appG2 = @(Get-MockApp $AppSrc)[0]
T 26 '11 404 de propagation sur GET application, PATCH keyCredentials et addPassword : reessais, certificat ET secret ajoutes, exit 0' ($rG2.Exit -eq 0 -and @($appG2.keyCredentials).Count -eq 1 -and @($appG2.passwordCredentials).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rG2.Exit) certs=$(@($appG2.keyCredentials).Count) secrets=$(@($appG2.passwordCredentials).Count) $($rG2.Crash)"
# --- 12 : keyCredentials : keyId et empreinte des anciennes cles journalises AVANT le PATCH (sans secret) ---
$logR10 = Read-RunFile $r10 'run.log'
T 26 '12 rotation : run.log contient keyId et customKeyIdentifier de CHAQUE ancienne cle (ligne "keyCredentials AVANT PATCH"), pas de cle ni de secret' ($logR10 -match 'keyCredentials AVANT PATCH' -and $oldKeyIds.Count -ge 1 -and (@($oldKeyIds | Where-Object { $logR10 -notmatch [regex]::Escape($_) }).Count -eq 0) -and $logR10 -match 'customKeyIdentifier=') "keyId manquants : $(@($oldKeyIds | Where-Object { $logR10 -notmatch [regex]::Escape($_) }) -join ',')"

# --- 13 : plateforme des URI de redirection = UNE constante ; bascule sur 'spa' sans refonte (copie du package) ---
$entraSrc = Get-Content -LiteralPath (Join-Path $pkg 'lib\entra.ps1') -Encoding utf8
$webHard = @($entraSrc | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch 'CloudiwayRedirectPlatform\s*=' -and ($_ -match "\.web\b|'web'|\bweb\s*=") })
T 26 '13 plateforme des URI : une seule constante $script:CloudiwayRedirectPlatform ; plus de ".web" / ''web'' en dur dans entra.ps1' (@($entraSrc | Where-Object { $_ -match '^\$script:CloudiwayRedirectPlatform\s*=' }).Count -eq 1 -and $webHard.Count -eq 0) "occurrences en dur : $($webHard -join ' | ')"
# POINT 27 : mineurs (16 a 20)
# ===================================================================================================
# 16 : $global:Error vide en fin de run ; secrets de masquage ; corps JSON du login annule (AST)
Reset-MockState
$baseH1 = New-Base 'H1'; $allBases.Add($baseH1)
$rH1 = Invoke-Connector (Get-BaseParams $baseH1 @('Mail') 'Source') $baseH1
T 27 '16 fin de run : $global:Error vide (Stop-Run), sans avoir masque les erreurs affichees (exit 0)' ($rH1.Exit -eq 0 -and $rH1.ErrorCount -eq 0) "exit=$($rH1.Exit) Error=$($rH1.ErrorCount)"
$ciwAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pkg 'lib\cloudiway.ps1'), [ref]$null, [ref]$null)
$fnLogin = $ciwAst.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Get-CiwLoginToken' }, $true)
$fin = if ($fnLogin) { $fnLogin.Find({ param($a) $a -is [System.Management.Automation.Language.TryStatementAst] -and $a.Finally }, $true) } else { $null }
T 27 '16 Get-CiwLoginToken : le corps JSON contenant le mot de passe ($body) et le clair ($plain) sont annules dans le finally' ($fin -and $fin.Finally.Extent.Text -match '\$body\s*=\s*\$null' -and $fin.Finally.Extent.Text -match '\$plain\s*=\s*\$null') 'finally sans annulation de $body'
# Module de test : les bibliotheques sont chargees dans un module dynamique (portee `$script:` propre, aucun risque pour `$Results` du banc)
$unit = New-Module -Name CiwUnit -ArgumentList $pkg -ScriptBlock {
    param($PkgDir)
    foreach ($lf in 'common.ps1', 'ui.ps1', 'preflight.ps1', 'permissions.ps1', 'entra.ps1', 'cloudiway.ps1') { . (Join-Path $PkgDir "lib\$lf") }
    function Get-CiwInternal([string]$Name) { Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue }
    function Get-CiwCount([string]$Name) { $v = Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue; if ($null -eq $v) { 0 } else { $v.Count } }
    Export-ModuleMember -Function * -Variable @()
} | Out-Null
Reset-MockState
$secPw = New-TestSecure $global:MockCwPassword
$rowsU = @(Connect-CloudiwayApi -Login $global:MockCwLogin -Password $secPw)
$maskList = @(Get-CiwInternal 'CiwSecrets')
$hdrU = Get-CiwInternal 'Ciw'
T 27 '16 apres un login reussi, la liste de masquage ne contient que le JETON (plus le mot de passe)' (@($rowsU | Where-Object Status -EQ 'FAIL').Count -eq 0 -and $maskList.Count -eq 1 -and $maskList[0] -notmatch [regex]::Escape($global:MockCwPassword) -and "$($hdrU.Headers.Authorization)" -eq "Bearer $($maskList[0])") "liste=$($maskList.Count) elements"
Clear-CloudiwayState
T 27 '16 Clear-CloudiwayState vide la liste de masquage et la possibilite de reconnexion' ((Get-CiwCount 'CiwSecrets') -eq 0 -and $null -eq (Get-CiwInternal 'CiwAuth')) 'etat non vide'
# 20 (AADSTS) : conseils
$hintsOk = @('65001', '90094', '53003', '50076') | Where-Object { (Get-AadstsHint "AADSTS${_}: message") -match "AADSTS$_" }
T 28 'Doc : conseils pour AADSTS 65001, 90094, 53003, 50076 ; aucun conseil pour un code inconnu' (@($hintsOk).Count -eq 4 -and (Get-AadstsHint 'AADSTS99999: autre') -eq '') "conseils : $(@($hintsOk) -join ',')"
# 18 : ConvertTo-MaskedJson -KeepKeys
$mj = ConvertTo-MaskedJson ([ordered]@{ externalKey = 'CIW1|AA|20270101'; secretKey = 'S3CRET-VALUE' }) 5 -KeepKeys @('externalKey')
T 27 '18 ConvertTo-MaskedJson -KeepKeys : externalKey lisible, toute autre cle sensible masquee' ($mj -match 'CIW1\|AA\|20270101' -and $mj -notmatch 'S3CRET-VALUE' -and $mj -match 'MASQUE') $mj
Remove-Module CiwUnit -Force -ErrorAction SilentlyContinue

# 17 : notices affichees dans les prochaines actions (adoption : mot de passe du compte a saisir dans le portail)

# 19 : ValidityDays >= 45 ; delai de renouvellement = validite - 30 jours
Reset-MockState
$baseH2 = New-Base 'H2'; $allBases.Add($baseH2)
$pH2 = Get-BaseParams $baseH2 @('Mail'); $pH2['ValidityDays'] = 40
$rH2 = Invoke-Connector $pH2 $baseH2
T 27 '19 -ValidityDays 40 refuse (minimum 45) a la liaison des parametres : aucun appel, aucune ecriture' ($rH2.Crash -match '45' -and $rH2.Calls.Count -eq 0) "crash=$($rH2.Crash) appels=$($rH2.Calls.Count)"
T 27 '19 information d''expiration calculee sur l''expiration REELLE du certificat (v2.2) : 180 jours -> "dans 180 jours", 90 jours -> "dans 90 jours", jamais un delai en mois en dur' ($r1.Console -match 'expire le \d\d/\d\d/\d{4} \(dans 180 jours\)' -and $r19e.Console -match 'expire le \d\d/\d\d/\d{4} \(dans 90 jours\)' -and $r1.Console -notmatch 'environ 5 mois|dans environ') 'delai non calcule'
Reset-MockState
$baseH3 = New-Base 'H3'; $allBases.Add($baseH3)
$pH3 = Get-BaseParams $baseH3 @('Mail'); $pH3['ValidityDays'] = 45; $pH3['WhatIf'] = $false
$rH3 = Invoke-Connector $pH3 $baseH3
T 27 '19 -ValidityDays 45 accepte ; l''expiration est donnee en JOURS reels (45) et non en mois' ($rH3.Exit -eq 0 -and $rH3.Console -match '\(dans 45 jours\)') "exit=$($rH3.Exit)"

# 20 : messages de blocage region / type d'authentification
Reset-MockState
$baseH5 = New-Base 'H5'; $allBases.Add($baseH5)
Add-SeedConnector $ConnSrc $false '[5]' 'CloudiwayConnector'
Set-MockConnectorSetting (Get-MockConnector $ConnSrc) 'ServerRegion' 2
$rH5 = Invoke-Connector (Get-BaseParams $baseH5 @('Mail')) $baseH5
$cwH5 = @(Get-PlanRows $rH5 | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T 27 '20 region differente : le blocage dit quelle option passer (-Region 2)' ($cwH5 -and $cwH5.Action -eq 'BLOQUE' -and $cwH5.Raison -match '-Region 2') "ligne=$($cwH5.Raison)"
Reset-MockState
$baseH6 = New-Base 'H6'; $allBases.Add($baseH6)
Add-SeedConnector $ConnSrc $false '[5]' 'CloudiwayConnector'
Set-MockConnectorSetting (Get-MockConnector $ConnSrc) 'AuthenticationType' 5
$rH6 = Invoke-Connector (Get-BaseParams $baseH6 @('Mail')) $baseH6
$cwH6 = @(Get-PlanRows $rH6 | Where-Object { $_.Zone -eq 'Cloudiway' })[0]
T 27 '20 type d''authentification different : le blocage dit quoi faire (-ConnectorName ou portail)' ($cwH6 -and $cwH6.Action -eq 'BLOQUE' -and $cwH6.Raison -match '-ConnectorName') "ligne=$($cwH6.Raison)"
# 20 : compte invite B2B
Reset-MockState; $global:MockOpts.ConnectAccount = 'invite_fabrikam.com#EXT#@contoso.onmicrosoft.com'
$baseH7 = New-Base 'H7'; $allBases.Add($baseH7)
$rH7 = Invoke-Connector (Get-BaseParams $baseH7 @('Mail')) $baseH7
T 27 '20 compte invite B2B (#EXT#) different de -Admin365 : exit 1 avec message utile sur les invites' ($rH7.Exit -eq 1 -and $rH7.Console -match 'INVITE' -and $rH7.Console -match '#EXT#' -and $rH7.GraphCalls -eq 0) "exit=$($rH7.Exit)"
# 20 : encodage de la console restaure
$encOk = $false; $encDetail = 'non testable'
try {
    if (-not [Console]::IsOutputRedirected) {
        $enc0 = [System.Text.Encoding]::GetEncoding(850); [Console]::OutputEncoding = $enc0
        Reset-MockState
        $baseH8 = New-Base 'H8'; $allBases.Add($baseH8)
        $rH8 = Invoke-Connector (Get-BaseParams $baseH8 @('Mail')) $baseH8
        $encNow = [Console]::OutputEncoding.CodePage
        $encOk = ($encNow -eq 850); $encDetail = "codepage apres le run : $encNow (850 attendu)"
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    }
} catch { $encDetail = $_.Exception.Message }
if ([Console]::IsOutputRedirected) { Skip 27 '20 encodage de la console restaure en fin de run' 'sortie redirigee : Initialize-UI ne modifie pas l''encodage' } else { T 27 '20 [Console]::OutputEncoding restaure en fin de run' $encOk $encDetail }
# 20 : horloge du poste decalee
Reset-MockState; $global:MockOpts.ClockSkewMinutes = 20
$baseH9 = New-Base 'H9'; $allBases.Add($baseH9)
$pH9 = Get-BaseParams $baseH9 @('Mail'); $pH9['WhatIf'] = $true
$rH9 = Invoke-Connector $pH9 $baseH9
T 27 '20 horloge du poste decalee de 20 minutes : avertissement "Horloge du poste ... decalee", sans bloquer (exit 0)' ($rH9.Exit -eq 0 -and $rH9.Console -match 'Horloge du poste' -and $rH9.Console -match 'decalee') "exit=$($rH9.Exit)"
# 20 : AADSTS dans le message d'echec de connexion Graph
Reset-MockState; $global:MockOpts.ConnectFailMessage = 'AADSTS65001: The user or administrator has not consented to use the application.'
$baseHA = New-Base 'HA'; $allBases.Add($baseHA)
$rHA = Invoke-Connector (Get-BaseParams $baseHA @('Mail')) $baseHA
T 28 'AADSTS65001 a la connexion Graph : exit 1 et conseil actionnable (consentement) affiche' ($rHA.Exit -eq 1 -and $rHA.Console -match 'AADSTS65001' -and $rHA.Console -match 'consentement') "exit=$($rHA.Exit)"
# UseDeviceCode : transmis a Connect-MgGraph uniquement sur demande ; verification tenant/compte inchangee
Reset-MockState
$baseDC = New-Base 'DC'; $allBases.Add($baseDC)
$pDC = Get-BaseParams $baseDC @('Mail'); $pDC['WhatIf'] = $true; $pDC['UseDeviceCode'] = $true
$rDC = Invoke-Connector $pDC $baseDC
$connDC = @($global:MockCalls | Where-Object { $_.Name -eq 'Connect-MgGraph' -or $_.Path -eq 'Connect-MgGraph' })
T 28 'UseDeviceCode : exit 0, code ABCD1234 AFFICHE, jeton transmis a Connect-MgGraph (-AccessToken), jamais -UseDeviceCode du module' ($rDC.Exit -eq 0 -and $rDC.Console -match 'ABCD1234' -and (($connDC | Out-String) -match 'accesstoken=1')) "exit=$($rDC.Exit)"
Reset-MockState
$baseND = New-Base 'ND'; $allBases.Add($baseND)
$pND = Get-BaseParams $baseND @('Mail'); $pND['WhatIf'] = $true
$rND = Invoke-Connector $pND $baseND
$connND = @($global:MockCalls | Where-Object { $_.Name -eq 'Connect-MgGraph' -or $_.Path -eq 'Connect-MgGraph' })
T 28 'Sans UseDeviceCode : connexion normale (pas de code d''appareil)' ($rND.Exit -eq 0 -and -not (($connND | Out-String) -match 'devicecode=1|accesstoken=1')) "exit=$($rND.Exit)"
# UseDeviceCode : mauvais compte saisi dans la page de connexion -> refus avant toute ecriture ; code refuse ; attente puis succes
Reset-MockState; $global:MockOpts.ConnectAccount = 'autre.compte@contoso.com'
$baseDW = New-Base 'DW'; $allBases.Add($baseDW)
$pDW = Get-BaseParams $baseDW @('Mail'); $pDW['UseDeviceCode'] = $true
$rDW = Invoke-Connector $pDW $baseDW
T 28 'UseDeviceCode avec un AUTRE compte que -Admin365 : refus (exit 1), aucune ecriture tenant ni Cloudiway' ($rDW.Exit -eq 1 -and $rDW.GraphWrites -eq 0 -and $rDW.CiwWrites -eq 0 -and $rDW.Console -match 'ne correspond pas') "exit=$($rDW.Exit) graph=$($rDW.GraphWrites) ciw=$($rDW.CiwWrites)"
Reset-MockState; $global:MockDcPolls = 0; $global:MockOpts.DeviceDeclined = $true
$baseDX = New-Base 'DX'; $allBases.Add($baseDX)
$pDX = Get-BaseParams $baseDX @('Mail'); $pDX['UseDeviceCode'] = $true
$rDX = Invoke-Connector $pDX $baseDX
T 28 'UseDeviceCode refuse dans la page Microsoft : exit 1, message clair, aucune ecriture' ($rDX.Exit -eq 1 -and $rDX.GraphWrites -eq 0 -and $rDX.Console -match 'refus') "exit=$($rDX.Exit) $($rDX.Console.Substring([Math]::Max(0,$rDX.Console.Length - 300)))"
Reset-MockState; $global:MockDcPolls = 0; $global:MockOpts.DevicePendingPolls = 2
$baseDY = New-Base 'DY'; $allBases.Add($baseDY)
$pDY = Get-BaseParams $baseDY @('Mail'); $pDY['UseDeviceCode'] = $true
$rDY = Invoke-Connector $pDY $baseDY
T 28 'UseDeviceCode : 2 interrogations en attente puis succes : le script patiente et termine (exit 0)' ($rDY.Exit -eq 0 -and $global:MockDcPolls -ge 3) "exit=$($rDY.Exit) polls=$($global:MockDcPolls)"
# 9 : ecran de choix des charges : privileges nommes, Entree seule refusee (aucune valeur pre-cochee)
if ([Console]::IsInputRedirected) {
    Skip 28 'M9 : ecran de choix des charges sans valeur pre-cochee' 'entree standard redirigee : Test-Interactive est faux'
} else {
    Reset-MockState
    $baseHB = New-Base 'HB'; $allBases.Add($baseHB)
    $pHB = Get-BaseParams $baseHB @(); $pHB.Remove('Workloads'); $pHB['WhatIf'] = $true
    $rHB = Invoke-Connector $pHB $baseHB @('', '1', $global:MockCwPassword)
    T 28 'M9 : -Workloads absent : question sans valeur pre-cochee, privileges nommes (Exchange Administrator), Entree seule refusee, puis choix Mail, exit 0' ($rHB.Exit -eq 0 -and $rHB.Console -match 'Exchange Administrator' -and $rHB.Console -match 'Rien n''est pre-selectionne' -and $rHB.Console -match 'Au moins un element' -and $rHB.QueueLeft -eq 0 -and (Read-RunFile $rHB 'Rapport-*.md') -match 'Charges de travail : Mail\r?\n') "exit=$($rHB.Exit) file=$($rHB.QueueLeft) $($rHB.Crash)"
}
$mainSrc = Get-Content -LiteralPath $main -Raw -Encoding utf8
T 28 'M9 : sans console interactive, -Workloads est exige (plus de charges par defaut silencieuses) ; -ValidityDays valide de 45 a 730' ($mainSrc -match "aucune charge par defaut : indiquer explicitement" -and $mainSrc -match 'ValidateRange\(45, 730\)') 'defaut non supprime ou plage 30'

T B 'B8 aucune route non geree par les mocks (GET/POST/PATCH hors contrat)' ($global:MockUnrouted.Count -eq 0) "non routees : $($global:MockUnrouted -join ' ; ')"

# ===================================================================================================
# POINT 29 : UN SEUL certificat (ou secret) actif - nettoyage des anciens identifiants CREES PAR L'OUTIL, apres l'ecriture du connecteur
# ===================================================================================================
$futureIso = (Microsoft.PowerShell.Utility\Get-Date).ToUniversalTime().AddDays(300).ToString('yyyy-MM-ddTHH:mm:ssZ')
$pastIso = (Microsoft.PowerShell.Utility\Get-Date).ToUniversalTime().AddDays(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
function New-ManualKey([string]$Name, [string]$Thumb) { @{ keyId = [guid]::NewGuid().ToString(); type = 'AsymmetricX509Cert'; usage = 'Verify'; customKeyIdentifier = $Thumb; displayName = $Name; startDateTime = $pastIso; endDateTime = $futureIso; key = $null } }
Reset-MockState
$base29 = New-Base 'U1'; $allBases.Add($base29)
$p29 = Get-BaseParams $base29 @('Mail'); $p29['AuthMethod'] = 'Both'
$r29a = Invoke-Connector $p29 $base29
$app29 = @(Get-MockApp $AppSrc)[0]
$tool1Id = "$(@($app29.keyCredentials)[0].keyId)"; $tool1Thumb = (Get-MockThumbs $app29)[0]; $toolSecId = "$(@($app29.passwordCredentials)[0].keyId)"
$manKey = New-ManualKey 'Cle posee a la main par le DSI' ('AB' * 20)
$decoyKey = New-ManualKey 'Cloudiway-SOURCE-P123450 2026-01-01' ('EF' * 20)      # prefixe voisin (autre projet) : NE correspond PAS
$lowKey = New-ManualKey 'cloudiway-source-p12345 2025-01-01' ('CD' * 20)          # meme nom, casse differente : cle de l'outil
$manSec = @{ keyId = [guid]::NewGuid().ToString(); displayName = 'Secret pose a la main'; startDateTime = $pastIso; endDateTime = $futureIso; hint = 'abc' }
$app29.keyCredentials = @($app29.keyCredentials) + @($manKey, $decoyKey, $lowKey)
$app29.passwordCredentials = @($app29.passwordCredentials) + @($manSec)
$rk29 = $global:MockTenant.RemovedKeys; $rs29 = $global:MockTenant.RemovedSecrets
# --- -WhatIf : le plan annonce le nettoyage, rien n'est retire ---
$p29w = $p29.Clone(); $p29w['RotateCredentials'] = $true; $p29w['WhatIf'] = $true
$r29w = Invoke-Connector $p29w $base29
$rows29w = @(Get-PlanRows $r29w); $clw = @($rows29w | Where-Object { $_.Zone -eq 'Nettoyage' })
T 29 '-WhatIf : exit 0, aucune ecriture, AUCUNE cle retiree' ($r29w.Exit -eq 0 -and $r29w.GraphWrites -eq 0 -and $r29w.CiwWrites -eq 0 -and $global:MockTenant.RemovedKeys -eq $rk29 -and $global:MockTenant.RemovedSecrets -eq $rs29 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 4) "exit=$($r29w.Exit) graph=$($r29w.GraphWrites) ciw=$($r29w.CiwWrites) retirees=$($global:MockTenant.RemovedKeys - $rk29)"
T 29 '-WhatIf : la zone Nettoyage figure au plan APRES la ligne Cloudiway (certificats : 2 anciens de l''outil, secrets : 1), action METTRE A JOUR' ($clw.Count -eq 2 -and @($clw | Where-Object { $_.Action -eq 'METTRE A JOUR' }).Count -eq 2 -and (($clw | Where-Object { $_.Element -like '*certificats*' }).Raison -match '^2 ancien\(s\) certificat\(s\) de l''outil a retirer apres transmission du nouveau') -and (($clw | Where-Object { $_.Element -like '*secrets*' }).Raison -match '^1 ancien\(s\) secret\(s\) client de l''outil a retirer apres transmission du nouveau') -and ([array]::IndexOf(@($rows29w | ForEach-Object Zone), 'Nettoyage') -gt [array]::IndexOf(@($rows29w | ForEach-Object Zone), 'Cloudiway'))) "lignes=$(Get-PlanBrief $rows29w)"
# --- rotation reelle ---
$p29r = $p29.Clone(); $p29r['RotateCredentials'] = $true
$r29b = Invoke-Connector $p29r $base29
$app29b = @(Get-MockApp $AppSrc)[0]; $idsAfter = @($app29b.keyCredentials | ForEach-Object { "$($_.keyId)" }); $secAfter = @($app29b.passwordCredentials | ForEach-Object { "$($_.keyId)" })
$conn29 = Get-MockConnector $ConnSrc; $cert29 = Get-ConnCert $conn29; $st29 = Get-Settings $conn29
T 29 'rotation Both : pas de crash, exit 0, connecteur coherent avec le NOUVEAU certificat' ([string]::IsNullOrEmpty($r29b.Crash) -and $r29b.Exit -eq 0 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '' -and $cert29 -and $cert29.Thumbprint -ne $tool1Thumb) "exit=$($r29b.Exit) $($r29b.Crash) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
T 29 'seules les cles de l''outil sont retirees : ancien certificat ET cle "cloudiway-source-p12345 ..." (casse differente) ; la cle posee a la main et la cle au prefixe voisin (P123450) sont CONSERVEES' (($idsAfter -contains $manKey.keyId) -and ($idsAfter -contains $decoyKey.keyId) -and ($idsAfter -notcontains $tool1Id) -and ($idsAfter -notcontains $lowKey.keyId) -and $global:MockTenant.RemovedKeys -eq $rk29 + 2) "apres=$($idsAfter.Count) retirees=$($global:MockTenant.RemovedKeys - $rk29)"
T 29 'un seul certificat de l''OUTIL reste (le nouveau, celui du connecteur) + 2 cles hors outil = 3 cles' ($idsAfter.Count -eq 3 -and (Get-MockThumbs $app29b) -contains $cert29.Thumbprint) "cles=$($idsAfter.Count)"
T 29 'secret client (Both) : l''ancien secret de l''outil est retire par removePassword, le secret pose a la main est conserve, le nouveau est celui du connecteur' ($secAfter.Count -eq 2 -and ($secAfter -contains $manSec.keyId) -and ($secAfter -notcontains $toolSecId) -and $global:MockTenant.RemovedSecrets -eq $rs29 + 1 -and $global:MockTenant.RemovedSecretIds -contains $toolSecId -and $st29.RestClientSecret -and (@($global:MockTenant.Secrets.Values) -contains $st29.RestClientSecret)) "secrets=$($secAfter.Count) retires=$($global:MockTenant.RemovedSecrets - $rs29)"
$rep29 = Read-RunFile $r29b 'Rapport-*.md'; $log29 = Read-RunFile $r29b 'run.log'
T 29 'rapport : keyId et empreinte (customKeyIdentifier) de CHAQUE cle retiree, keyId du secret retire, jamais de secret' ($rep29 -match [regex]::Escape($tool1Id) -and $rep29 -match [regex]::Escape($tool1Thumb) -and $rep29 -match [regex]::Escape($lowKey.keyId) -and $rep29 -match ('CD' * 20) -and $rep29 -match [regex]::Escape($toolSecId) -and $rep29 -notmatch 'MockSecret~') 'keyId / empreinte absents du rapport'
T 29 'journal run.log : keyId et empreinte de chaque cle retiree (lignes "Nettoyage : retrait")' ($log29 -match [regex]::Escape($tool1Id) -and $log29 -match [regex]::Escape($tool1Thumb) -and $log29 -match [regex]::Escape($lowKey.keyId) -and $log29 -match [regex]::Escape($toolSecId) -and $log29 -match 'Nettoyage : retrait') 'journal incomplet'
$ciwWriteSeq = @($r29b.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.IsWrite } | ForEach-Object Seq)
$rmSeq = @($r29b.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite -and ($_.Method -eq 'POST' -and $_.Path -match '(removePassword|removeKey)$') } | ForEach-Object Seq)
T 29 'ORDRE : tout retrait (POST removeKey x2 certificats, POST removePassword x1 secret) vient APRES l''ecriture du connecteur Cloudiway' ($ciwWriteSeq.Count -ge 1 -and $rmSeq.Count -eq 3 -and (($rmSeq | Measure-Object -Minimum).Minimum -gt ($ciwWriteSeq | Measure-Object -Maximum).Maximum)) "ciw=$($ciwWriteSeq -join ',') retraits=$($rmSeq -join ',')"
$cl29 = @(Get-PlanRows $r29b | Where-Object { $_.Zone -eq 'Nettoyage' })
T 29 'rapport : la zone Nettoyage est appliquee (resultat APPLIQUE) pour certificats et secrets' ((($rep29 -split "`n") | Where-Object { $_ -match '^\| \d+ \| Nettoyage \|.*\| APPLIQUE \|' }).Count -eq 2 -and $cl29.Count -eq 2) 'lignes Nettoyage non appliquees'
# --- second passage identique : aucune suppression ---
$rk29b = $global:MockTenant.RemovedKeys; $rs29b = $global:MockTenant.RemovedSecrets
$r29c = Invoke-Connector (Keep $p29) $base29
T 29 'second passage sans changement : ZERO ecriture, aucune suppression, aucune ligne de nettoyage au plan' ($r29c.Exit -eq 0 -and $r29c.GraphWrites -eq 0 -and $r29c.CiwWrites -eq 0 -and $global:MockTenant.RemovedKeys -eq $rk29b -and $global:MockTenant.RemovedSecrets -eq $rs29b -and @(Get-PlanRows $r29c | Where-Object { $_.Zone -eq 'Nettoyage' }).Count -eq 0) "exit=$($r29c.Exit) graph=$($r29c.GraphWrites) ciw=$($r29c.CiwWrites) retirees=$($global:MockTenant.RemovedKeys - $rk29b)"

# --- -SkipCloudiway : aucun identifiant genere, donc rien a nettoyer ---
Reset-MockState
$base29s = New-Base 'U2'; $allBases.Add($base29s)
$r29s0 = Invoke-Connector (Get-BaseParams $base29s @('Mail')) $base29s
$pSk29 = Get-BaseParams $base29s @('Mail'); $pSk29.Remove('Cloudiway'); $pSk29['SkipCloudiway'] = $true; $pSk29['ProjectId'] = 12345; $pSk29['RotateCredentials'] = $true
$r29s = Invoke-Connector $pSk29 $base29s
T 29 '-SkipCloudiway (+ -RotateCredentials) : aucun identifiant genere, AUCUNE cle retiree, pas de ligne de nettoyage, le certificat du connecteur reste en place' ($r29s.Exit -eq 0 -and $global:MockTenant.RemovedKeys -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and @(Get-PlanRows $r29s | Where-Object { $_.Zone -eq 'Nettoyage' }).Count -eq 0 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($r29s.Exit) retirees=$($global:MockTenant.RemovedKeys) certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count)"

# --- echec du nettoyage : non bloquant, message clair, le nouveau certificat est en place et transmis ---
Reset-MockState
$base29f = New-Base 'U3'; $allBases.Add($base29f)
$p29f = Get-BaseParams $base29f @('Mail')
$null = Invoke-Connector $p29f $base29f
$global:MockOpts.OnWrite = {
    param($Method, $Path, $Body)
    if ($Method -eq 'POST' -and $Path -like '/applications/*/removeKey') { throw (New-MockError 500 'InternalServerError' 'echec simule du nettoyage') }
}
$p29fr = $p29f.Clone(); $p29fr['RotateCredentials'] = $true
$r29f = Invoke-Connector $p29fr $base29f
$global:MockOpts.OnWrite = $null
$rep29f = Read-RunFile $r29f 'Rapport-*.md'
T 29 'echec du nettoyage : non bloquant (exit 2), 2 certificats restent, message clair "deja en place et transmis", connecteur coherent avec le nouveau, aucune cle retiree' ($r29f.Exit -eq 2 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 2 -and $global:MockTenant.RemovedKeys -eq 0 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '' -and ($rep29f -match 'deja en place et transmis') -and ($rep29f -match 'Nettoyage \| Anciens certificats de l''outil \| ECHEC')) "exit=$($r29f.Exit) certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count) retirees=$($global:MockTenant.RemovedKeys)"
$r29g = Invoke-Connector $p29fr $base29f
T 29 'apres l''echec : la rotation suivante retire les 2 anciens certificats -> UN SEUL certificat, exit 0' ($r29g.Exit -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and $global:MockTenant.RemovedKeys -eq 2 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($r29g.Exit) certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count) retirees=$($global:MockTenant.RemovedKeys)"

# --- mutation de controle : sans la condition "connecteur ecrit", le test "ancien certificat conserve" doit ECHOUER (mutation detectee) ---
$mutDir = Join-Path $tmpRoot 'mutation'; New-Item -ItemType Directory -Path $mutDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $pkg 'cloudiway-connector.ps1') -Destination $mutDir
Copy-Item -LiteralPath (Join-Path $pkg 'lib') -Destination $mutDir -Recurse
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$mMain = Join-Path $mutDir 'cloudiway-connector.ps1'; $mEntra = Join-Path $mutDir 'lib\entra.ps1'
$tM = [System.IO.File]::ReadAllText($mMain); $tE = [System.IO.File]::ReadAllText($mEntra)
$nDep = ([regex]::Matches($tM, [regex]::Escape("@('Cloudiway', 'Certificate')   # DEPENDANCE-CONNECTEUR"))).Count
$nGuard = ([regex]::Matches($tE, [regex]::Escape("-not [bool](Get-EntraCtx 'ConnectorWriteOk')"))).Count
[System.IO.File]::WriteAllText($mMain, $tM.Replace("@('Cloudiway', 'Certificate')   # DEPENDANCE-CONNECTEUR", '@()'), $utf8Bom)
[System.IO.File]::WriteAllText($mEntra, $tE.Replace("-not [bool](Get-EntraCtx 'ConnectorWriteOk')", '$false'), $utf8Bom)
T 29 'mutation de controle : la dependance Cloudiway et la garde "connecteur ecrit" existent dans les sources (1 + 2 emplacements)' ($nDep -eq 1 -and $nGuard -eq 2) "dependance=$nDep garde=$nGuard"
Reset-MockState
$base29m = New-Base 'U4'; $allBases.Add($base29m)
$p29m = Get-BaseParams $base29m @('Mail')
$null = Invoke-Connector $p29m $base29m
(Get-MockConnector $ConnSrc).externalKey = 'CloudiwayConnector'
$global:MockOpts.CiwFail = @(@{ Method = 'PUT'; Pattern = '^/Connectors/\d+$'; Code = 503; Times = 1 })
$mainSaved = $main; $main = $mMain
$rMut = Invoke-Connector $p29m $base29m
$main = $mainSaved
$global:MockOpts.CiwFail = @()
$mutDetected = ($global:MockTenant.RemovedKeys -gt 0)
T 29 'mutation de controle : condition "connecteur ecrit" DESACTIVEE -> l''ancien certificat est retire alors que le connecteur n''a pas ete ecrit (le test "ancien certificat CONSERVE" echouerait : mutation detectee)' $mutDetected "retirees=$($global:MockTenant.RemovedKeys) exit=$($rMut.Exit)"
# meme scenario avec les VRAIES sources : ancien certificat conserve
Reset-MockState
$base29n = New-Base 'U5'; $allBases.Add($base29n)
$p29n = $p29m.Clone(); $p29n['OutDir'] = $base29n
$null = Invoke-Connector $p29n $base29n
(Get-MockConnector $ConnSrc).externalKey = 'CloudiwayConnector'
$global:MockOpts.CiwFail = @(@{ Method = 'PUT'; Pattern = '^/Connectors/\d+$'; Code = 503; Times = 1 })
$rReal = Invoke-Connector $p29n $base29n
$global:MockOpts.CiwFail = @()
T 29 'memes conditions avec les vraies sources : ancien certificat CONSERVE (aucune cle retiree, 2 certificats)' ($global:MockTenant.RemovedKeys -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 2 -and $rReal.Exit -eq 2) "retirees=$($global:MockTenant.RemovedKeys) exit=$($rReal.Exit)"
T 29 'aucune route Graph non geree par le mock (removePassword compris)' ($global:MockUnrouted.Count -eq 0) "non routees : $($global:MockUnrouted -join ' ; ')"

# ===================================================================================================
# POINT 30 : parametres - questions (interactif) et parametres manquants (non interactif), aide Get-Help
# ===================================================================================================
# Console NON interactive : processus fils a entree standard fermee, sur le VRAI script. Chaque cas manque d'au moins un parametre
# (jamais de PAT possible en ligne de commande), donc le script s'arrete AVANT toute connexion (aucun appel reseau).
function Invoke-NonInteractive([string[]]$ScriptArgs) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    foreach ($a in (@('-NoProfile', '-File', $main) + $ScriptArgs)) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
    [void]$proc.WaitForExit(120000)
    [pscustomobject]@{ Exit = $proc.ExitCode; Out = $out }
}
$niAll = @('-Mode', 'Source', '-Tenant', 'contoso.onmicrosoft.com', '-Admin365', 'admin365@contoso.com', '-Workloads', 'Mail', '-SkipCloudiway', '-ProjectId', '12345', '-Yes')
$niCases = @(
    @{ Name = '-Tenant'; Drop = '-Tenant'; Placeholder = '<contoso.onmicrosoft.com>' }
    @{ Name = '-Admin365'; Drop = '-Admin365'; Placeholder = '<admin365@contoso.com>' }
    @{ Name = '-Workloads'; Drop = '-Workloads'; Placeholder = '<Mail,OneDrive>' }
    @{ Name = '-ProjectId'; Drop = '-ProjectId'; Placeholder = '<12345>' }
    @{ Name = '-Yes'; Drop = '-Yes'; Placeholder = '-Yes' }
)
foreach ($case in $niCases) {
    $args2 = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $niAll.Count; $i++) {
        $a = $niAll[$i]
        if ($a -eq $case.Drop) { if ($a -in '-Mode', '-Tenant', '-Admin365', '-Workloads', '-ProjectId') { $i++ }; continue }
        $args2.Add($a)
    }
    $ni = Invoke-NonInteractive $args2.ToArray()
    $others = @($niCases | Where-Object { $_.Name -ne $case.Name } | ForEach-Object Name)
    $msgLines = @($ni.Out -split "\r?\n" | Where-Object { $_ -match 'Parametres manquants' })
    $listPart = ($msgLines -join ' ')
    $leaked = @($others | Where-Object { $listPart -match ('(^|[ ;:])' + [regex]::Escape($_) + '([ ;(,]|$)') })
    T 30 "console non interactive, $($case.Name) manquant : exit 1, UN message qui le liste seul, commande complete a relancer (valeurs deja donnees reprises, modele $($case.Placeholder))" ($ni.Exit -eq 1 -and $msgLines.Count -eq 1 -and $listPart -match [regex]::Escape($case.Name) -and $leaked.Count -eq 0 -and $ni.Out -match 'Commande complete a relancer' -and $ni.Out -match '\./cloudiway-connector\.ps1 ' -and $ni.Out.Contains($case.Placeholder) -and $ni.Out -notmatch 'Connexion Microsoft Graph|Connexion au portail') "exit=$($ni.Exit) lignes=$($msgLines.Count) en trop=[$($leaked -join ',')] sortie=$($ni.Out.Substring(0, [Math]::Min(300, $ni.Out.Length)))"
}
$niNone = Invoke-NonInteractive @()
$msgNone = @($niNone.Out -split "\r?\n" | Where-Object { $_ -match 'Parametres manquants' })
$missAll = @('-Tenant', '-Admin365', '-Workloads', '-CloudiwayPat', '-Yes' | Where-Object { ($msgNone -join ' ') -notmatch [regex]::Escape($_) })
T 30 'console non interactive, AUCUN parametre : un seul message liste TOUS les manquants (-Tenant, -Admin365, -Workloads, -CloudiwayPat, -Yes) + commande complete avec modeles et PAT' ($niNone.Exit -eq 1 -and $msgNone.Count -eq 1 -and $missAll.Count -eq 0 -and $niNone.Out -match 'Commande complete a relancer' -and $niNone.Out -match '-Mode Source' -and $niNone.Out -match '-CloudiwayPat \$pat' -and $niNone.Out -match 'Read-Host -AsSecureString') "exit=$($niNone.Exit) lignes=$($msgNone.Count) manquants non listes=[$($missAll -join ',')]"
$niDisc = Invoke-NonInteractive @('-Discover')
T 30 'console non interactive, -Discover sans PAT : le PAT est demande dans le message unique, commande avec -Discover -CloudiwayPat $pat' ($niDisc.Exit -eq 1 -and @($niDisc.Out -split "\r?\n" | Where-Object { $_ -match 'Parametres manquants' }).Count -eq 1 -and $niDisc.Out -match '-CloudiwayPat' -and $niDisc.Out -match '-Discover -CloudiwayPat \$pat') "exit=$($niDisc.Exit)"

# Aide Get-Help : chaque parametre demande si absent le dit
$helpBad = @()
foreach ($hn in 'Tenant', 'Admin365', 'Cloudiway', 'Workloads', 'ProjectId') {
    $ht = ''
    try { $ht = ((Get-Help $main -Parameter $hn -ErrorAction Stop).description | ForEach-Object Text) -join ' ' } catch { $ht = "ERREUR $($_.Exception.Message)" }
    if ($ht -notmatch '(?i)demande si absent') { $helpBad += $hn }
}
T 30 'Get-Help : -Tenant, -Admin365, -Cloudiway, -Workloads, -ProjectId indiquent "demande si absent"' ($helpBad.Count -eq 0) ("sans mention : " + ($helpBad -join ', '))
$helpFull = ''
try { $helpFull = (Get-Help $main -Full -ErrorAction Stop | Out-String) } catch { $helpFull = '' }
T 32 'Get-Help -Full : -KeepCredentials documente (renouvelle a chaque execution), -RotateCredentials sans effet, mention des jobs de migration actifs' ($helpFull -match '-KeepCredentials' -and $helpFull -match '(?i)CHAQUE execution' -and $helpFull -match '(?i)Sans effet' -and $helpFull -match '(?i)jobs de migration') 'aide du nouveau parametre absente'
T 30 'Get-Help -Full : correct (synopsis, exemple de commande complete avec -ProjectId 12345, commande minimale sans parametre, 14+ parametres documentes)' ($helpFull.Length -gt 3000 -and $helpFull -match '-ProjectId 12345' -and $helpFull -match 'Commande minimale' -and $helpFull -match 'Commande complete' -and (@('Mode', 'Tenant', 'Admin365', 'Cloudiway', 'CloudiwayPat', 'ProjectId', 'Workloads', 'AuthMethod', 'ValidityDays', 'RotateCredentials', 'AdoptExisting', 'OutDir', 'SkipCloudiway', 'Discover') | Where-Object { $helpFull -notmatch ('-' + $_ + ' ') }).Count -eq 0) "longueur=$($helpFull.Length)"

if ([Console]::IsInputRedirected) {
    Skip 30 'questions interactives (parametres manquants un a un, saisie invalide puis valide, choix du projet)' 'entree standard redirigee : Test-Interactive est faux'
} else {
    # Chaque parametre manquant, un a un : exactement UNE question (plus le mot de passe masque), puis execution complete
    $oneByOne = @(
        @{ Drop = 'Tenant'; Answer = 'contoso.onmicrosoft.com' }, @{ Drop = 'Admin365'; Answer = $global:MockUser },
        @{ Drop = 'Workloads'; Answer = '1' }, @{ Drop = 'Cloudiway'; Answer = $global:MockCwLogin }
    )
    foreach ($c in $oneByOne) {
        Reset-MockState
        $b30 = New-Base ('Q' + $c.Drop); $allBases.Add($b30)
        $pq = Get-BaseParams $b30 @('Mail'); $pq.Remove($c.Drop)
        $q = @($c.Answer)
        if ($c.Drop -eq 'Cloudiway') { $q = @($c.Answer, $global:MockCwPassword) } else { $q = @($c.Answer, $global:MockCwPassword) }
        $rq = Invoke-Connector $pq $b30 $q
        T 30 "interactif, $($c.Drop) manquant : une seule question posee (+ mot de passe masque), exit 0, file de reponses consommee" ($rq.Exit -eq 0 -and $rq.AskedCount -eq 2 -and $rq.QueueLeft -eq 0 -and (Get-MockConnector $ConnSrc)) "exit=$($rq.Exit) questions=$($rq.AskedCount) restant=$($rq.QueueLeft) $($rq.Crash)"
    }
    # Tout manque + saisies invalides puis valides (re-question, pas d'arret brutal) + exemples affiches
    Reset-MockState
    $b30a = New-Base 'Q-ALL'; $allBases.Add($b30a)
    $q30 = @('pas-un-domaine', 'contoso.onmicrosoft.com', 'pasunemail', $global:MockUser, '99', 'foo', '1', 'x', $global:MockCwLogin, 'o', $global:MockCwPassword, 'o')
    $r30a = Invoke-Connector @{ OutDir = $b30a } $b30a $q30
    $invalidCount = ([regex]::Matches($r30a.Console, 'Saisie non valide|Saisie non reconnue')).Count
    T 30 'interactif, tout manque : saisies invalides (mode, tenant, compte, charges, Cloudiway) puis valides : re-questions, pas d''arret brutal, exit 0, file consommee' ($r30a.Exit -eq 0 -and $r30a.QueueLeft -eq 0 -and -not $global:MockReadExhausted -and $invalidCount -ge 5 -and (Get-MockConnector $ConnSrc)) "exit=$($r30a.Exit) invalides=$invalidCount restant=$($r30a.QueueLeft) $($r30a.Crash)"
    $prompts30 = $global:MockReadLog -join "`n"
    T 30 'interactif : chaque question donne un exemple (mode, tenant, compte, charges, Cloudiway)' ($prompts30 -match 'exemple : contoso\.onmicrosoft\.com' -and $prompts30 -match 'admin365@contoso\.com' -and $prompts30 -match 'exemple : paul\.bernard@contoso\.com' -and $r30a.Console -match 'ex\. 1,2 ou Mail,OneDrive') 'exemple absent'
    $allConsoles.Add(($global:MockReadLog -join "`n"))
    # Projet : plusieurs visibles -> liste, re-question sur saisie invalide
    Reset-MockState; $global:MockCiw.Projects = @(12345, 12346)
    $b30p = New-Base 'Q-PRJ'; $allBases.Add($b30p)
    $r30p = Invoke-Connector (Get-BaseParams $b30p @('Mail')) $b30p @($global:MockCwPassword, 'abc', '0', '9', '2')
    T 30 'projet non determinable (2 projets) : liste, saisies invalides re-questionnees (abc, 0, 9) puis 2 retenu (12346), exit 0' ($r30p.Exit -eq 0 -and $r30p.QueueLeft -eq 0 -and (Get-MockApp 'CLOUDIWAY-SOURCE-P12346') -and ([regex]::Matches($r30p.Console, 'Choix invalide')).Count -eq 3 -and $r30p.Console -match 'exemple : 1') "exit=$($r30p.Exit) restant=$($r30p.QueueLeft) $($r30p.Crash)"
    # Projet : un seul visible -> retenu SANS question
    Reset-MockState
    $b30q = New-Base 'Q-ONE'; $allBases.Add($b30q)
    $r30q = Invoke-Connector (Get-BaseParams $b30q @('Mail')) $b30q
    T 30 'un seul projet visible : retenu sans aucune question de projet (seul le mot de passe masque est demande)' ($r30q.Exit -eq 0 -and $r30q.AskedCount -eq 1 -and (Get-MockApp $AppSrc)) "exit=$($r30q.Exit) questions=$($r30q.AskedCount)"
}


# ===================================================================================================
# V2.2 (point 31) : prochaines actions (A faire / A verifier), Exchange (EWS), version, affichage
# ===================================================================================================
function Get-ExoCmdCount($Run, [string]$Method) { @($Run.Calls | Where-Object { $_.Kind -eq 'Cmd' -and $_.Method -eq $Method }).Count }
function Get-ExoSets($Run) { @($Run.Calls | Where-Object { $_.Kind -eq 'Exo' -and $_.Method -eq 'SET' }) }
function Get-ExoAnyCalls($Run) { @($Run.Calls | Where-Object { $_.Kind -eq 'Exo' -or ($_.Kind -eq 'Cmd' -and $_.Method -in 'CONNECT-EXO', 'DISCONNECT-EXO') -or ($_.Kind -eq 'Cmd' -and $_.Method -eq 'IMPORT' -and $_.Path -eq 'ExchangeOnlineManagement') }) }
# Titres numerotes d'un groupe de la section "Prochaines actions" : console (lignes "A faire" / "A verifier") ou rapport ("## A faire")
function Get-ConsoleNsTitles([string]$Text, [string]$Group) {
    $lines = @($Text -split "\r?\n"); $in = $false; $out = @()
    foreach ($l in $lines) {
        if ($l -match '^(A faire|A verifier)\s*$') { $in = ($Matches[1] -eq $Group); continue }
        if ($in -and $l -match '^\s{2}\d+\. (.+?)\s*$') { $out += $Matches[1] }
        elseif ($in -and $l -match '^\S' -and $l -notmatch '^[─-╿\-]+\s*$') { $in = $false }
    }
    $out
}
function Get-ReportNsTitles([string]$Md, [string]$Group) {
    $in = $false; $out = @()
    foreach ($l in ($Md -split "\r?\n")) {
        if ($l -match '^## (.+?)\s*$') { $in = ($Matches[1] -eq $Group); continue }
        if ($in -and $l -match '^\d+\. \*\*(.+?)\*\*') { $out += $Matches[1] }
    }
    $out
}
function Get-ExoAppIdOf([string]$AppName) { "$((@(Get-MockApp $AppName)[0]).appId)" }

# --- V1 : Source Mail + OneDrive, liste EwsAllowedAppIDs deja renseignee (autre application) ---
Reset-MockState
$global:MockOpts.EwsList = @('0000aaaa-0000-0000-0000-00000000dddd')
$baseV1 = New-Base 'V1'; $allBases.Add($baseV1)
$pV1 = Get-BaseParams $baseV1 @('Mail', 'OneDrive'); $pV1['ProductIds'] = '5,6'
$rV1 = Invoke-Connector $pV1 $baseV1
$mdV1 = Read-RunFile $rV1 'Rapport-*.md'
$appV1 = Get-ExoAppIdOf $AppSrc
$setsV1 = Get-ExoSets $rV1
T 31 'Exchange : pas de crash, code de sortie 0' ([string]::IsNullOrEmpty($rV1.Crash) -and $rV1.Exit -eq 0) "exit=$($rV1.Exit) $($rV1.Crash)"
T 31 'Exchange : liste non vide sans l''AppID -> UN Set-OrganizationConfig, ajout seul (liste existante + AppID)' ($setsV1.Count -eq 1 -and $setsV1[0].Body -eq "Add=$appV1") "sets=$($setsV1.Count) body=$($setsV1 | ForEach-Object Body)"
T 31 'Exchange : l''entree existante est conservee, l''AppID est ajoute (jamais de remplacement ni de retrait)' ((@($global:MockOpts.EwsList).Count -eq 2) -and (@($global:MockOpts.EwsList) -contains '0000aaaa-0000-0000-0000-00000000dddd') -and (@($global:MockOpts.EwsList) -contains $appV1)) "liste=$(@($global:MockOpts.EwsList) -join ',')"
T 31 'Exchange : connexion avec -Admin365 (UPN), UNE connexion et AUCUN Disconnect-ExchangeOnline (il fait planter le processus)' ((Get-ExoCmdCount $rV1 'CONNECT-EXO') -eq 1 -and (Get-ExoCmdCount $rV1 'DISCONNECT-EXO') -eq 0 -and @($rV1.Calls | Where-Object { $_.Method -eq 'CONNECT-EXO' -and $_.Body -match [regex]::Escape("upn=$($global:MockUser)") }).Count -eq 1) "connect=$(Get-ExoCmdCount $rV1 'CONNECT-EXO') disconnect=$(Get-ExoCmdCount $rV1 'DISCONNECT-EXO')"
T 31 'Exchange : lecture (Get-OrganizationConfig) AVANT toute ecriture Graph et Exchange' ((($rV1.Calls | Where-Object { $_.Kind -eq 'Exo' } | Select-Object -First 1).Method -eq 'GET') -and (($rV1.Calls | Where-Object { $_.Kind -eq 'Exo' } | Select-Object -First 1).Seq) -lt (($rV1.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite } | Select-Object -First 1).Seq)) 'ordre'
$exRowV1 = @(Get-PlanRows $rV1 | Where-Object { $_.Zone -eq 'Exchange' })
$roleRowV1 = @(Get-PlanRows $rV1 | Where-Object { $_.Zone -eq 'Roles' } | Select-Object -Last 1)
T 31 'Exchange : ligne de plan de zone Exchange (METTRE A JOUR) placee apres les Roles' ($exRowV1.Count -eq 1 -and $exRowV1[0].Action -eq 'METTRE A JOUR' -and $roleRowV1.Count -eq 1 -and [int]$exRowV1[0].Id -gt [int]$roleRowV1[0].Id) "exchange=$($exRowV1.Count) $(Get-PlanBrief $exRowV1)"
T 31 'Exchange : verification relue (AppID present dans EwsAllowedAppIDs, Conforme)' ($mdV1 -match 'Exchange : AppID dans EwsAllowedAppIDs \| Conforme') 'ligne de verification absente'
T 31 'Exchange : aucun secret ni valeur sensible n''est impose a Exchange (aucun fichier en plus)' ((Get-ExtraFiles $rV1).Count -eq 0) "en trop : $((Get-ExtraFiles $rV1) -join ', ')"

# --- V1 : section "Prochaines actions" (console ET rapport) ---
$cTodo = @(Get-ConsoleNsTitles $rV1.Console 'A faire'); $rTodo = @(Get-ReportNsTitles $mdV1 'A faire')
$cChk = @(Get-ConsoleNsTitles $rV1.Console 'A verifier'); $rChk = @(Get-ReportNsTitles $mdV1 'A verifier')
T 31 'Prochaines actions : plus de section « Prochaines actions » (ni console, ni rapport) ; titre « A verifier »' ($rV1.Console -notmatch 'Prochaines actions' -and $mdV1 -notmatch 'Prochaines actions' -and $mdV1 -match '(?m)^## A verifier\s*$' -and $rV1.Console -match '(?m)^A verifier\s*$') 'titres'
T 31 'Prochaines actions : aucune ligne sans action (pas de « Consentement administrateur : deja accorde » ni « Rien a faire. »)' ($rV1.Console -notmatch 'Consentement administrateur : deja accorde' -and $mdV1 -notmatch 'Consentement administrateur : deja accorde' -and $mdV1 -notmatch '(?m)^\d+\. \*\*.*\*\* - Rien a faire' -and ($rV1.Console -split "\r?\n" | Where-Object { $_ -match '^\s+\d+\. ' -and $_ -match 'deja accorde' }).Count -eq 0) 'ligne sans action presente'
T 31 'Prochaines actions : console et rapport strictement coherents (memes titres, meme ordre, dans « A faire » et « A verifier »)' ($cChk.Count -gt 0 -and (($cTodo -join '|') -eq ($rTodo -join '|')) -and (($cChk -join '|') -eq ($rChk -join '|'))) "console faire=[$($cTodo -join '|')] verifier=[$($cChk -join '|')] ; rapport faire=[$($rTodo -join '|')] verifier=[$($rChk -join '|')]"
T 31 '« A faire » : vide quand tout est applique (aucune licence, aucun MFA, aucun renouvellement a faire)' ($rTodo.Count -eq 0 -and $cTodo.Count -eq 0) "faire=$($rTodo -join '|')"
T 31 '« A verifier » : aucune mention MFA / acces conditionnel (pas de compte de service)' (($rChk -join '|') -notmatch 'MFA') "verifier=$($rChk -join '|')"
$mkV1 = Get-MockMarker (Get-MockConnector $ConnSrc)
$nV1 = ([datetime]::ParseExact($mkV1.Date, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture).Date - [datetime]::UtcNow.Date).Days
T 31 'Renouvellement : simple information, N jours calcule sur l''expiration reelle du certificat transmis (pas de « 5 mois » en dur)' ($mdV1 -match ("Le certificat du connecteur expire le \d\d/\d\d/\d{4} \(dans $nV1 jours\)\. Chaque relance de l'outil renouvelle le certificat") -and $mdV1 -notmatch '5 mois|environ \d+ mois|Relancer la meme commande dans') "N attendu=$nV1"
T 31 'Renouvellement : aucune mention « les anciens ne sont pas supprimes »' ($mdV1 -notmatch 'anciens[^.]{0,40}(ne sont pas|pas) supprim' -and $rV1.Console -notmatch 'anciens[^.]{0,40}(ne sont pas|pas) supprim') 'mention presente'
T 31 'Renouvellement : l''information s''affiche aussi dans la console avec le meme N' ($rV1.Console -match "dans $nV1 jours") "N=$nV1"
T 31 '« Valeurs a connaitre » : presente quand elle contient des valeurs (AppID reel, expiration)' ($mdV1 -match '## Valeurs a connaitre' -and $mdV1 -match [regex]::Escape("AppID de l'application : ``$appV1``") -and $mdV1 -match 'Expiration du certificat du connecteur : \d{4}-\d\d-\d\d') 'section ou valeurs absentes'
T 31 '« Valeurs a connaitre » : plus de consigne manuelle « a inscrire dans EwsAllowedAppIDs »' ($mdV1 -notmatch 'a inscrire dans EwsAllowedAppIDs') 'consigne presente'

# --- V1 : version, affichage ---
T 31 'Version 2.4 (31/10/2026) dans la banniere console et dans le rapport, jamais « 2.0 »' ($rV1.Console -match 'version 2\.4 - 31/10/2026' -and $mdV1 -match 'version 2\.4 \(31/10/2026\)' -and $rV1.Console -notmatch 'version 2\.0' -and $mdV1 -notmatch 'version 2\.0') 'version'
$verBad = [System.Collections.Generic.List[string]]::new()
foreach ($vf in 'cloudiway-connector.ps1', 'lib\common.ps1', 'lib\ui.ps1') { $vt = [System.IO.File]::ReadAllText((Join-Path $pkg $vf)); if ($vt -notmatch "AppVersion(?: = |' ')'?2\.4'" -and $vt -notmatch "'AppVersion' '2\.4'") { $verBad.Add($vf) } }
T 31 'Coherence de version : 2.4 dans common.ps1, script principal, ui.ps1 (defaut)' ($verBad.Count -eq 0) ($verBad -join ', ')
T 31 'Affichage : aucun tableau parasite « Name Status Detail » en fin d''execution, ni « Connecteur Cloudiway existant » dans la console' ($rV1.Console -notmatch '(?m)^\s*Name\s+Status\s+Detail' -and $rV1.Console -notmatch 'Connecteur Cloudiway existant') 'tableau parasite'
T 31 'Affichage : la lecture du connecteur existant reste tracee dans run.log (rien de perdu)' ((Read-RunFile $rV1 'run.log') -match 'CONNECTEUR Connecteur Cloudiway existant') 'trace absente'
T 31 'Affichage : les rapports s''ouvrent sur Prochaines actions sans table parasite apres le bloc (fin de console = A verifier / A faire)' (($rV1.Console.TrimEnd() -split "\r?\n" | Select-Object -Last 1) -notmatch 'Name\s+Status|----') 'derniere ligne'

# --- V1 : second passage = tout OK, aucune ecriture, information d'expiration relue du marqueur ---
$rV2 = Invoke-Connector (Keep $pV1) $baseV1
$mdV2 = Read-RunFile $rV2 'Rapport-*.md'
$exRowV2 = @(Get-PlanRows $rV2 | Where-Object { $_.Zone -eq 'Exchange' })
T 31 'Exchange idempotent : second passage = ligne OK, AUCUNE ecriture Exchange (ni Graph, ni Cloudiway), exit 0' ($rV2.Exit -eq 0 -and (Get-ExoSets $rV2).Count -eq 0 -and $exRowV2.Count -eq 1 -and $exRowV2[0].Action -eq 'OK' -and $exRowV2[0].Raison -match 'deja present' -and $rV2.GraphWrites -eq 0 -and $rV2.CiwWrites -eq 0) "exit=$($rV2.Exit) sets=$((Get-ExoSets $rV2).Count) plan=$(Get-PlanBrief $exRowV2)"
T 31 'Exchange : AppID deja present -> aucune entree ajoutee, la liste reste a 2 entrees' (@($global:MockOpts.EwsList).Count -eq 2) "liste=$(@($global:MockOpts.EwsList) -join ',')"
T 31 'Renouvellement (second passage) : N relu du marqueur du connecteur existant, pas du certificat (aucun nouveau certificat genere)' ($mdV2 -match ("expire le \d\d/\d\d/\d{4} \(dans $nV1 jours\)") -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1) "N=$nV1"

# --- V3 : Source OneDrive seul : ni Exchange, ni MFA (pas de compte de service) ; section « A faire » absente quand elle est vide ---
Reset-MockState
$baseV3 = New-Base 'V3'; $allBases.Add($baseV3)
$rV3 = Invoke-Connector (Get-BaseParams $baseV3 @('OneDrive')) $baseV3
$mdV3 = Read-RunFile $rV3 'Rapport-*.md'
T 31 'Charge sans Mail (OneDrive Source) : AUCUN appel Exchange (ni module, ni connexion, ni lecture), aucune ligne Exchange au plan' ($rV3.Exit -eq 0 -and (Get-ExoAnyCalls $rV3).Count -eq 0 -and @(Get-PlanRows $rV3 | Where-Object { $_.Zone -eq 'Exchange' }).Count -eq 0 -and $rV3.Console -notmatch 'Exchange Online') "exit=$($rV3.Exit) appels=$((Get-ExoAnyCalls $rV3).Count)"
T 31 'Section vide non affichee : pas de « A faire » (console et rapport) quand il n''y a rien a faire ; pas de MFA sans compte de service' ($mdV3 -notmatch '(?m)^## A faire' -and $rV3.Console -notmatch '(?m)^A faire\s*$' -and $mdV3 -notmatch 'MFA') 'section vide affichee'
T 31 '« A verifier » : expiration du certificat (information) affichee seule' ($mdV3 -match '(?m)^## A verifier' -and $mdV3 -match 'expire le' -and $mdV3 -notmatch 'Le compte de service, lui') 'information absente ou phrase compte de service sans compte'

# --- V4 : -WhatIf (Mail + liste vide, sans -Yes) : lecture seule, plan avec confirmation annoncee, aucune question ---
Reset-MockState
$global:MockOpts.EwsList = @()
$baseV4 = New-Base 'V4'; $allBases.Add($baseV4)
$pV4 = Get-BaseParams $baseV4 @('Mail'); $pV4.Remove('Yes'); $pV4['WhatIf'] = $true
$rV4 = Invoke-Connector $pV4 $baseV4
$exRowV4 = @(Get-PlanRows $rV4 | Where-Object { $_.Zone -eq 'Exchange' })
$mdV4 = Read-RunFile $rV4 'Rapport-*.md'
T 31 'Exchange -WhatIf : connexion et LECTURE seules (CONNECT + GET), aucun Set, aucune ecriture Graph ni Cloudiway, exit 0' ($rV4.Exit -eq 0 -and (Get-ExoCmdCount $rV4 'CONNECT-EXO') -eq 1 -and @($rV4.Calls | Where-Object { $_.Kind -eq 'Exo' -and $_.Method -eq 'GET' }).Count -ge 1 -and (Get-ExoSets $rV4).Count -eq 0 -and $rV4.GraphWrites -eq 0 -and $rV4.CiwWrites -eq 0 -and (Get-ExoCmdCount $rV4 'DISCONNECT-EXO') -eq 0) "exit=$($rV4.Exit) sets=$((Get-ExoSets $rV4).Count)"
T 31 'Exchange -WhatIf : le plan affiche la ligne UPDATE avec l''effet restrictif et la confirmation separee, sans poser de question' ($exRowV4.Count -eq 1 -and $exRowV4[0].Action -eq 'METTRE A JOUR' -and $exRowV4[0].Raison -match 'RESTRICTIVE' -and $exRowV4[0].Raison -match 'confirmation' -and $rV4.AskedCount -eq 1) "plan=$(Get-PlanBrief $exRowV4) questions=$($rV4.AskedCount)"
T 31 'Exchange -WhatIf : liste du tenant inchangee, « Valeurs a connaitre » absente en simulation (rien de cree)' (@($global:MockOpts.EwsList).Count -eq 0 -and $mdV4 -notmatch '## Valeurs a connaitre' -and $mdV4 -notmatch 'AppObjectId') 'section Valeurs presente ou liste modifiee'

# --- V5 : liste VIDE avec -Yes : rien d'ecrit, IGNOREE, passage en « A verifier » avec la commande ---
Reset-MockState
$global:MockOpts.EwsList = @()
$baseV5 = New-Base 'V5'; $allBases.Add($baseV5)
$rV5 = Invoke-Connector (Get-BaseParams $baseV5 @('Mail')) $baseV5
$mdV5 = Read-RunFile $rV5 'Rapport-*.md'; $appV5 = Get-ExoAppIdOf $AppSrc
$exRowV5 = @(Get-PlanRows $rV5 | Where-Object { $_.Zone -eq 'Exchange' })
T 31 'Liste vide + -Yes : AUCUN Set-OrganizationConfig, ligne IGNOREE, liste du tenant inchangee, exit 0' ($rV5.Exit -eq 0 -and (Get-ExoSets $rV5).Count -eq 0 -and @($global:MockOpts.EwsList).Count -eq 0 -and $exRowV5.Count -eq 1 -and $exRowV5[0].Action -eq 'IGNORE' -and $exRowV5[0].Raison -match 'VIDE' -and $exRowV5[0].Raison -match 'AllowEwsListCreation') "exit=$($rV5.Exit) plan=$(Get-PlanBrief $exRowV5)"
T 31 'Liste vide + -Yes : « A verifier » avec la commande exacte (AppID reel) et l''explication de l''effet de bord' ((@(Get-ReportNsTitles $mdV5 'A verifier') -join '|') -match 'EwsAllowedAppIDs est vide' -and $mdV5 -match [regex]::Escape("Set-OrganizationConfig -EwsAllowedAppIDs (($ids") -and $mdV5 -match [regex]::Escape("'$appV5'") -and $mdV5 -match 'restrictive pour toutes les autres applications EWS' -and (@(Get-ConsoleNsTitles $rV5.Console 'A verifier') -join '|') -match 'EwsAllowedAppIDs est vide') 'A verifier absent'
T 31 'Liste vide + -Yes : la verification le dit (« A verifier »), pas de faux conforme' ($mdV5 -match 'Exchange : AppID dans EwsAllowedAppIDs \| A verifier') 'ligne de verification'

# --- V6 : -AllowEwsListCreation : creation autorisee sans question ---
Reset-MockState
$global:MockOpts.EwsList = @()
$baseV6 = New-Base 'V6'; $allBases.Add($baseV6)
$pV6 = Get-BaseParams $baseV6 @('Mail'); $pV6['AllowEwsListCreation'] = $true
$rV6 = Invoke-Connector $pV6 $baseV6
$appV6 = Get-ExoAppIdOf $AppSrc; $setsV6 = Get-ExoSets $rV6
$exRowV6 = @(Get-PlanRows $rV6 | Where-Object { $_.Zone -eq 'Exchange' })
T 31 '-AllowEwsListCreation + liste vide : UN Set (liste existante + AppID), liste = [AppID], aucune question, exit 0' ($rV6.Exit -eq 0 -and $setsV6.Count -eq 1 -and $setsV6[0].Body -eq "Add=$appV6" -and @($global:MockOpts.EwsList).Count -eq 1 -and @($global:MockOpts.EwsList)[0] -eq $appV6 -and $rV6.AskedCount -eq 1) "exit=$($rV6.Exit) sets=$($setsV6.Count) liste=$(@($global:MockOpts.EwsList) -join ',') questions=$($rV6.AskedCount)"
T 31 '-AllowEwsListCreation : le plan explique l''effet restrictif ET que la creation est autorisee par l''option' ($exRowV6.Count -eq 1 -and $exRowV6[0].Action -eq 'METTRE A JOUR' -and $exRowV6[0].Raison -match 'RESTRICTIVE' -and $exRowV6[0].Raison -match 'autorisee par -AllowEwsListCreation') "plan=$(Get-PlanBrief $exRowV6)"
$rV6b = Invoke-Connector $pV6 $baseV6
T 31 '-AllowEwsListCreation : second passage idempotent (OK, aucun Set)' ((Get-ExoSets $rV6b).Count -eq 0 -and @(Get-PlanRows $rV6b | Where-Object { $_.Zone -eq 'Exchange' })[0].Action -eq 'OK' -and $rV6b.Exit -eq 0) "sets=$((Get-ExoSets $rV6b).Count)"

# --- V7 : liste vide, mode questions : confirmation separee (oui / non) ---
if ([Console]::IsInputRedirected) {
    Skip 31 'Liste vide : confirmation explicite separee (oui / non)' 'entree standard redirigee : Test-Interactive est faux'
} else {
    Reset-MockState
    $global:MockOpts.EwsList = @()
$baseV7 = New-Base 'V7'; $allBases.Add($baseV7)
    $pV7 = Get-BaseParams $baseV7 @('Mail'); $pV7.Remove('Yes')
    $rV7n = Invoke-Connector $pV7 $baseV7 @($global:MockCwPassword, 'n', 'o')
    $mdV7n = Read-RunFile $rV7n 'Rapport-*.md'
    $exRowV7n = @(Get-PlanRows $rV7n | Where-Object { $_.Zone -eq 'Exchange' })
    T 31 'Liste vide, confirmation separee REFUSEE (N) : aucun Set, ligne IGNOREE, le reste est applique (application creee), « A verifier » avec la commande, exit 0' ($rV7n.Exit -eq 0 -and (Get-ExoSets $rV7n).Count -eq 0 -and $rV7n.GraphWrites -gt 0 -and $rV7n.QueueLeft -eq 0 -and $exRowV7n.Count -eq 1 -and $exRowV7n[0].Action -eq 'IGNORE' -and $mdV7n -match [regex]::Escape('Set-OrganizationConfig -EwsAllowedAppIDs (($ids') -and $rV7n.Console -match 'RESTRICTIVE') "exit=$($rV7n.Exit) sets=$((Get-ExoSets $rV7n).Count) file=$($rV7n.QueueLeft) plan=$(Get-PlanBrief $exRowV7n)"
    $rV7o = Invoke-Connector $pV7 $baseV7 @($global:MockCwPassword, 'o', 'o')
    T 31 'Liste vide, confirmation separee ACCEPTEE (O) puis confirmation du plan : UN Set (liste existante + AppID), exit 0, deux questions apres le mot de passe' ($rV7o.Exit -eq 0 -and (Get-ExoSets $rV7o).Count -eq 1 -and (Get-ExoSets $rV7o)[0].Body -eq "Add=$(Get-ExoAppIdOf $AppSrc)" -and $rV7o.QueueLeft -eq 0 -and $rV7o.AskedCount -eq 3) "exit=$($rV7o.Exit) sets=$((Get-ExoSets $rV7o).Count) questions=$($rV7o.AskedCount) file=$($rV7o.QueueLeft)"
}

# --- V8 : EwsEnabled = False -> aucune ecriture, « A verifier » (decision a l'echelle du tenant), meme avec -AllowEwsListCreation ---
Reset-MockState
$global:MockOpts.EwsEnabled = $false; $global:MockOpts.EwsList = @('0000aaaa-0000-0000-0000-00000000dddd')
$baseV8 = New-Base 'V8'; $allBases.Add($baseV8)
$pV8 = Get-BaseParams $baseV8 @('Mail'); $pV8['AllowEwsListCreation'] = $true
$rV8 = Invoke-Connector $pV8 $baseV8
$mdV8 = Read-RunFile $rV8 'Rapport-*.md'; $exRowV8 = @(Get-PlanRows $rV8 | Where-Object { $_.Zone -eq 'Exchange' })
T 31 'EwsEnabled = False : AUCUNE ecriture Exchange (meme avec -AllowEwsListCreation), ligne IGNOREE, liste inchangee, exit 0' ($rV8.Exit -eq 0 -and (Get-ExoSets $rV8).Count -eq 0 -and @($global:MockOpts.EwsList).Count -eq 1 -and $exRowV8.Count -eq 1 -and $exRowV8[0].Action -eq 'IGNORE' -and $exRowV8[0].Raison -match 'EwsEnabled = False') "exit=$($rV8.Exit) plan=$(Get-PlanBrief $exRowV8)"
T 31 'EwsEnabled = False : « A verifier » (decision du tenant, non modifiee par l''outil) et verification en avertissement' ((@(Get-ReportNsTitles $mdV8 'A verifier') -join '|') -match 'EWS est desactive pour l''organisation' -and $mdV8 -match 'decision a l''echelle du tenant|echelle du tenant' -and $mdV8 -match 'Exchange : AppID dans EwsAllowedAppIDs \| A verifier') 'A verifier absent'
# EwsEnabled non defini (Null) : l'ecriture a lieu, l'information passe en « A verifier »
Reset-MockState
$global:MockOpts.EwsEnabled = $null; $global:MockOpts.EwsList = @('0000aaaa-0000-0000-0000-00000000dddd')
$baseV8b = New-Base 'V8b'; $allBases.Add($baseV8b)
$rV8b = Invoke-Connector (Get-BaseParams $baseV8b @('Mail')) $baseV8b
T 31 'EwsEnabled non defini (Null) : l''AppID est ajoute (liste non vide) et un « A verifier » signale la decision du tenant' ($rV8b.Exit -eq 0 -and (Get-ExoSets $rV8b).Count -eq 1 -and (@(Get-ReportNsTitles (Read-RunFile $rV8b 'Rapport-*.md') 'A verifier') -join '|') -match 'EwsEnabled n''est pas defini') "exit=$($rV8b.Exit) sets=$((Get-ExoSets $rV8b).Count)"

# --- V9 : module ExchangeOnlineManagement absent -> etape manuelle, le reste continue, exit 2 ; -InstallMissingModules ---
Reset-MockState
$global:MockOpts.ExoModuleMissing = $true; $global:MockOpts.EwsList = @('0000aaaa-0000-0000-0000-00000000dddd')
$baseV9 = New-Base 'V9'; $allBases.Add($baseV9)
$rV9 = Invoke-Connector (Get-BaseParams $baseV9 @('Mail')) $baseV9
$mdV9 = Read-RunFile $rV9 'Rapport-*.md'
T 31 'Module Exchange absent : aucune connexion Exchange, le RESTE est configure (application, connecteur), code de sortie 2' ($rV9.Exit -eq 2 -and (Get-ExoAnyCalls $rV9).Count -eq 0 -and @(Get-MockApp $AppSrc).Count -eq 1 -and (Get-MockConnector $ConnSrc) -and $rV9.GraphWrites -gt 0) "exit=$($rV9.Exit) appels=$((Get-ExoAnyCalls $rV9).Count)"
T 31 'Module Exchange absent : message clair a l''ecran et « A faire » manuel avec les commandes exactes (Install-Module, Connect, lecture, Set liste existante + AppID reel)' ($rV9.Console -match 'Module ExchangeOnlineManagement' -and $rV9.Console -match 'sera a faire a la main' -and (@(Get-ReportNsTitles $mdV9 'A faire') -join '|') -match 'a la main' -and $mdV9 -match 'Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser' -and $mdV9 -match [regex]::Escape("Connect-ExchangeOnline -UserPrincipalName 'admin@contoso.com'") -and $mdV9 -match [regex]::Escape("Set-OrganizationConfig -EwsAllowedAppIDs (($ids") -and $mdV9 -match [regex]::Escape("'$(Get-ExoAppIdOf $AppSrc)'")) 'message ou commandes absents'
T 31 'Module Exchange absent : la ligne de plan est IGNOREE (voir A faire) et console = rapport pour « A faire »' (@(Get-PlanRows $rV9 | Where-Object { $_.Zone -eq 'Exchange' })[0].Action -eq 'IGNORE' -and ((@(Get-ConsoleNsTitles $rV9.Console 'A faire') -join '|') -eq (@(Get-ReportNsTitles $mdV9 'A faire') -join '|'))) 'plan ou coherence'
$rV9b = Invoke-Connector ((Get-BaseParams $baseV9 @('Mail')) + @{ InstallMissingModules = $true }) $baseV9
T 31 'Module Exchange absent + -InstallMissingModules : installation du module, connexion, ajout de l''AppID, exit 0' ($rV9b.Exit -eq 0 -and @($rV9b.Calls | Where-Object { $_.Method -eq 'INSTALL-MODULE' -and $_.Path -eq 'ExchangeOnlineManagement' }).Count -eq 1 -and (Get-ExoSets $rV9b).Count -eq 1 -and @($global:MockOpts.EwsList).Count -eq 2) "exit=$($rV9b.Exit) sets=$((Get-ExoSets $rV9b).Count)"

# --- V10 : echec de connexion Exchange -> non bloquant, A faire, exit 2 ; puis reprise ---
Reset-MockState
$global:MockOpts.ExoConnectFails = $true; $global:MockOpts.EwsList = @('0000aaaa-0000-0000-0000-00000000dddd')
$baseV10 = New-Base 'V10'; $allBases.Add($baseV10)
$rV10 = Invoke-Connector (Get-BaseParams $baseV10 @('Mail')) $baseV10
$mdV10 = Read-RunFile $rV10 'Rapport-*.md'
T 31 'Echec de connexion Exchange : NON bloquant (application et connecteur crees), aucun Set, code de sortie 2' ($rV10.Exit -eq 2 -and (Get-ExoSets $rV10).Count -eq 0 -and @(Get-MockApp $AppSrc).Count -eq 1 -and (Get-MockConnector $ConnSrc) -and $rV10.Console -match 'Connexion Exchange Online impossible') "exit=$($rV10.Exit)"
T 31 'Echec de connexion Exchange : « A faire » avec les commandes exactes (Connect, lecture, Set liste existante + AppID)' ((@(Get-ReportNsTitles $mdV10 'A faire') -join '|') -match 'a la main' -and $mdV10 -match [regex]::Escape("Connect-ExchangeOnline -UserPrincipalName 'admin@contoso.com'") -and $mdV10 -match 'Get-OrganizationConfig \| Select-Object EwsEnabled, EwsAllowedAppIDs' -and $mdV10 -match [regex]::Escape('Set-OrganizationConfig -EwsAllowedAppIDs (($ids')) 'commandes absentes'
$global:MockOpts.ExoConnectFails = $false
$rV10b = Invoke-Connector (Keep (Get-BaseParams $baseV10 @('Mail'))) $baseV10
T 31 'Reprise apres echec de connexion : le meme appel inscrit l''AppID (UN Set), exit 0, aucune ecriture Graph (deja conforme)' ($rV10b.Exit -eq 0 -and (Get-ExoSets $rV10b).Count -eq 1 -and $rV10b.GraphWrites -eq 0) "exit=$($rV10b.Exit) sets=$((Get-ExoSets $rV10b).Count) gw=$($rV10b.GraphWrites)"

# --- V11 : tenant Exchange different -> refus, deconnexion, A faire ; lecture impossible ---
Reset-MockState
$global:MockOpts.ExoTenantId = '99999999-8888-7777-6666-555555555555'; $global:MockOpts.EwsList = @('0000aaaa-0000-0000-0000-00000000dddd')
$baseV11 = New-Base 'V11'; $allBases.Add($baseV11)
$rV11 = Invoke-Connector (Get-BaseParams $baseV11 @('Mail')) $baseV11
T 31 'Exchange : connexion sur un AUTRE tenant -> refusee, deconnexion, aucune lecture ni ecriture, A faire, exit 2' ($rV11.Exit -eq 2 -and (Get-ExoSets $rV11).Count -eq 0 -and @($rV11.Calls | Where-Object { $_.Kind -eq 'Exo' }).Count -eq 0 -and (Get-ExoCmdCount $rV11 'DISCONNECT-EXO') -eq 0 -and $rV11.Console -match 'tenant ou compte different') "exit=$($rV11.Exit)"
Reset-MockState
$global:MockOpts.ExoReadFails = $true
$baseV11b = New-Base 'V11b'; $allBases.Add($baseV11b)
$rV11b = Invoke-Connector (Get-BaseParams $baseV11b @('Mail')) $baseV11b
T 31 'Exchange : lecture de la configuration impossible -> A faire manuel, aucun Set, deconnexion propre, exit 2' ($rV11b.Exit -eq 2 -and (Get-ExoSets $rV11b).Count -eq 0 -and (Get-ExoCmdCount $rV11b 'DISCONNECT-EXO') -eq 0 -and (@(Get-ReportNsTitles (Read-RunFile $rV11b 'Rapport-*.md') 'A faire') -join '|') -match 'a la main') "exit=$($rV11b.Exit)"

# --- V12 : echec d'ecriture Exchange -> non bloquant, A faire avec la commande, exit 2 ; puis reprise ---
Reset-MockState
$global:MockOpts.ExoSetFails = $true; $global:MockOpts.EwsList = @('0000aaaa-0000-0000-0000-00000000dddd')
$baseV12 = New-Base 'V12'; $allBases.Add($baseV12)
$rV12 = Invoke-Connector (Get-BaseParams $baseV12 @('Mail')) $baseV12
$mdV12 = Read-RunFile $rV12 'Rapport-*.md'
T 31 'Echec d''ecriture Exchange : le reste est configure (connecteur cree), liste inchangee, exit 2, ECHEC dans l''application' ($rV12.Exit -eq 2 -and (Get-ExoSets $rV12).Count -eq 1 -and @($global:MockOpts.EwsList).Count -eq 1 -and (Get-MockConnector $ConnSrc) -and $mdV12 -match '\| Exchange \| EWS : AppID dans EwsAllowedAppIDs \| (ECHEC|Echec|En echec)') "exit=$($rV12.Exit) sets=$((Get-ExoSets $rV12).Count)"
T 31 'Echec d''ecriture Exchange : « A faire » avec la commande exacte (Set liste existante + AppID reel) et le message d''erreur' ((@(Get-ReportNsTitles $mdV12 'A faire') -join '|') -match 'a la main' -and $mdV12 -match [regex]::Escape("Set-OrganizationConfig -EwsAllowedAppIDs (($ids") -and $mdV12 -match [regex]::Escape("'$(Get-ExoAppIdOf $AppSrc)'") -and $mdV12 -match 'ecriture automatique a echoue') 'A faire absent'
$global:MockOpts.ExoSetFails = $false
$rV12b = Invoke-Connector (Get-BaseParams $baseV12 @('Mail')) $baseV12
T 31 'Reprise apres echec d''ecriture : le meme appel ajoute l''AppID (liste = 2 entrees), exit 0' ($rV12b.Exit -eq 0 -and @($global:MockOpts.EwsList).Count -eq 2) "exit=$($rV12b.Exit) liste=$(@($global:MockOpts.EwsList).Count)"

Reset-MockState
$baseV15 = New-Base 'V15'; $allBases.Add($baseV15)
$pV15 = Get-BaseParams $baseV15 @('Mail'); $pV15['WhatIf'] = $true; $pV15['UseDeviceCode'] = $true
$rV15 = Invoke-Connector $pV15 $baseV15
T 31 '-UseDeviceCode : Connect-ExchangeOnline recoit -Device (code d''appareil)' (@($rV15.Calls | Where-Object { $_.Method -eq 'CONNECT-EXO' -and $_.Body -match 'device=1' }).Count -eq 1) 'device absent'
$baseV15n = New-Base 'V15n'; $allBases.Add($baseV15n)
$pV15n = Get-BaseParams $baseV15n @('Mail'); $pV15n['WhatIf'] = $true
$rV15n = Invoke-Connector $pV15n $baseV15n
T 31 'Sans -UseDeviceCode : connexion Exchange interactive normale (pas de -Device)' (@($rV15n.Calls | Where-Object { $_.Method -eq 'CONNECT-EXO' -and $_.Body -notmatch 'device=1' }).Count -eq 1) 'device present'
Reset-MockState
$global:MockOpts.OnWrite = { param($Method, $Path, $Body) if ($Method -eq 'POST' -and $Path -eq '/roleManagement/directory/roleAssignments') { $global:MockThrowOnDate = $true } }
$baseV16 = New-Base 'V16'; $allBases.Add($baseV16)
$rV16 = Invoke-Connector (Get-BaseParams $baseV16 @('Mail')) $baseV16
$global:MockOpts.OnWrite = $null; $global:MockThrowOnDate = $false
T 31 'exchange.ps1 : aucun appel reel a Disconnect-ExchangeOnline (hors liste de commandes manuelles affichees) : il fait planter le processus avec un code d''appareil' ((@((Get-Content (Join-Path $pkg 'lib\exchange.ps1')) | Where-Object { $_ -match 'Disconnect-ExchangeOnline' -and $_ -notmatch '^\s*#' -and $_ -notmatch '\$c\.Add\(' }).Count) -eq 0) 'appel a Disconnect-ExchangeOnline dans lib\exchange.ps1'T 31 'Interruption (exception / Ctrl+C) : la session Exchange est marquee fermee SANS appeler Disconnect-ExchangeOnline (exception non geree du module)' ($rV16.Crash -match 'interruption simulee' -and (Get-ExoCmdCount $rV16 'CONNECT-EXO') -eq 1 -and (Get-ExoCmdCount $rV16 'DISCONNECT-EXO') -eq 0) "crash='$($rV16.Crash)' connect=$(Get-ExoCmdCount $rV16 'CONNECT-EXO') disconnect=$(Get-ExoCmdCount $rV16 'DISCONNECT-EXO')"

# --- V17 : consentement manquant -> « A faire » avec le lien ; consentement accorde -> jamais mentionne ---
Reset-MockState
$global:MockOpts.Forbid = @(@{ Method = 'POST'; Pattern = '^/servicePrincipals/[^/]+/appRoleAssignedTo$' })
$baseV17 = New-Base 'V17'; $allBases.Add($baseV17)
$rV17 = Invoke-Connector (Get-BaseParams $baseV17 @('OneDrive')) $baseV17
$mdV17 = Read-RunFile $rV17 'Rapport-*.md'
$global:MockOpts.Forbid = @()
T 31 'Consentement manquant : « A faire » (console ET rapport) avec le lien de consentement administrateur (tenant + AppID reels)' ((@(Get-ReportNsTitles $mdV17 'A faire') -join '|') -match 'Accorder le consentement administrateur' -and (@(Get-ConsoleNsTitles $rV17.Console 'A faire') -join '|') -match 'Accorder le consentement administrateur' -and $mdV17 -match [regex]::Escape("https://login.microsoftonline.com/$($global:MockTenantId)/adminconsent?client_id=$(Get-ExoAppIdOf $AppSrc)")) "exit=$($rV17.Exit)"

# --- Garde-fous statiques : ajout seul, aucune suppression, aide, documents ---
# --- REPLI de nettoyage : removeKey refuse en 403 (constate en reel) -> PATCH ne gardant que le nouveau certificat avec son contenu public ---
Reset-MockState
$baseRF = New-Base 'RF'; $allBases.Add($baseRF)
$pRF = Get-BaseParams $baseRF @('Mail')
$rRF1 = Invoke-Connector $pRF $baseRF
$global:MockOpts.RemoveKeyForbidden = $true
$rRF2 = Invoke-Connector $pRF $baseRF
$thRF = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])); $logRF = Read-RunFile $rRF2 'run.log'
T 34 'removeKey refuse (403) : repli par PATCH, un seul certificat actif, connecteur coherent, exit 0' ($rRF1.Exit -eq 0 -and $rRF2.Exit -eq 0 -and $thRF.Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '' -and $logRF -match 'repli par PATCH accepte') "exit1=$($rRF1.Exit) exit2=$($rRF2.Exit) certs=$($thRF.Count) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
Reset-MockState
$baseRG = New-Base 'RG'; $allBases.Add($baseRG)
$pRG = Get-BaseParams $baseRG @('Mail')
$rRG1 = Invoke-Connector $pRG $baseRG
$manRG = New-ManualKey 'Cle posee a la main par le DSI' ('CD' * 20)
$appRG = @(Get-MockApp $AppSrc)[0]; $appRG.keyCredentials = @($appRG.keyCredentials) + @($manRG)
$global:MockOpts.RemoveKeyForbidden = $true
$rRG2 = Invoke-Connector $pRG $baseRG
$idsRG = @((@(Get-MockApp $AppSrc)[0]).keyCredentials | ForEach-Object { "$($_.keyId)" })
T 34 'removeKey refuse (403) avec une cle hors outil : AUCUN repli (la cle manuelle est conservee), echec signale, exit 2' ($rRG2.Exit -eq 2 -and ($idsRG -contains $manRG.keyId) -and $idsRG.Count -ge 3) "exit=$($rRG2.Exit) ids=$($idsRG.Count)"
$exSrc = [System.IO.File]::ReadAllText((Join-Path $pkg 'lib\exchange.ps1'))
$codeLines = @($exSrc -split "\r?\n" | Where-Object { $_ -notmatch '^\s*#' })
$allSetLines = @($codeLines | Where-Object { $_ -match 'Set-OrganizationConfig' })
$badSet = @($allSetLines | Where-Object { $_ -notmatch 'Set-OrganizationConfig -EwsAllowedAppIDs \(' })
T 31 'Securite : toutes les ecritures Exchange sont des Set-OrganizationConfig -EwsAllowedAppIDs (liste existante + AppID, GUID separes par des virgules : ajout seul, jamais de retrait)' ($allSetLines.Count -ge 2 -and $badSet.Count -eq 0 -and $exSrc -notmatch '(?i)Remove-|Remove\s*=|Clear-|Set-CASMailbox|-EwsEnabled' ) "lignes non conformes : $($badSet -join ' || ')"
T 31 'Securite : toutes les ecritures Exchange observees sur l''ensemble des scenarios V sont des AJOUTS (la liste existante est conservee en entier)' (@($global:MockAllCalls | Where-Object { $_.Kind -eq 'Exo' -and $_.Method -eq 'SET' -and $_.Body -notmatch '^Add=[0-9a-f-]{36}$' }).Count -eq 0 -and @($global:MockAllCalls | Where-Object { $_.Kind -eq 'Exo' -and $_.Method -eq 'SET' }).Count -ge 5) 'ecriture hors Add'
$hlp = (Get-Help $main -Parameter AllowEwsListCreation | Out-String)
$hlpFull = (Get-Help $main -Full | Out-String)
T 31 'Get-Help : -AllowEwsListCreation documente (switch, effet RESTRICTIF, confirmation, -Yes, EwsEnabled)' ($hlp -match 'AllowEwsListCreation' -and $hlp -match 'RESTRICTIVE' -and $hlp -match 'EwsAllowedAppIDs' -and $hlp -match '-Yes' -and $hlp -match 'EwsEnabled' -and $hlp -match 'SwitchParameter|switch') "aide: $hlp"
T 31 'Get-Help -Full : Exchange Online decrit (connexion, lecture seule, ajout seul), -UseDeviceCode mentionne -Device' ($hlpFull -match 'Exchange Online \(charge Mail' -and $hlpFull -match 'ajout seul' -and $hlpFull -match '-Device' -and $hlpFull -match 'AllowEwsListCreation') 'aide complete'

# ===================================================================================================
# POINT 32 (v2.3) : retrait des certificats par removeKey (preuve de possession) ET renouvellement PAR DEFAUT (-KeepCredentials)
# ===================================================================================================
# --- 32a : deux passages consecutifs SANS option = deux renouvellements (Cible Mail+OneDrive, compte de service) ---
$w1 = New-SourceMailOd 'W1'
$thumbW0 = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])); $oldIdW = "$(@((@(Get-MockApp $AppSrc)[0]).keyCredentials)[0].keyId)"
$putW0 = $global:MockCiw.PutCount; $rkW0 = $global:MockTenant.RemovedKeys; $tokW0 = $global:MockTenant.ProofTokens.Count
$rW2 = Invoke-Connector $w1.Params $w1.Base
$repW2 = Read-RunFile $rW2 'Rapport-*.md'; $logW2 = Read-RunFile $rW2 'run.log'   # lus AVANT le passage suivant (meme minute = meme nom de dossier)
$thumbW2 = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])); 
$rW3 = Invoke-Connector $w1.Params $w1.Base
$thumbW3 = @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])); 
T 32 'defaut : deux passages consecutifs sans option = deux renouvellements (exit 0, un seul certificat actif a la fin, connecteur mis a jour deux fois, connecteur coherent)' ($w1.Run.Exit -eq 0 -and $rW2.Exit -eq 0 -and $rW3.Exit -eq 0 -and $thumbW2.Count -eq 1 -and $thumbW3.Count -eq 1 -and $thumbW2[0] -ne $thumbW0[0] -and $thumbW3[0] -ne $thumbW2[0] -and $global:MockCiw.PutCount -eq $putW0 + 2 -and $global:MockTenant.RemovedKeys -eq $rkW0 + 2 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rW2.Exit)/$($rW3.Exit) certs=$($thumbW2.Count)/$($thumbW3.Count) PUT=$($global:MockCiw.PutCount - $putW0) retirees=$($global:MockTenant.RemovedKeys - $rkW0) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
$mutW2 = @($rW2.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite -and $_.Status -eq 'OK' })
T 32 'removeKey : l''ancien certificat est retire par POST /applications/{id}/removeKey (1 appel), le PATCH keyCredentials ne sert qu''a l''ajout (une entree avec key), aucun PATCH de retrait' (@($mutW2 | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '^/applications/[^/]+/removeKey$' }).Count -eq 1 -and @($mutW2 | Where-Object { $_.Method -eq 'PATCH' -and $_.Body -match 'keyCredentials' }).Count -eq 1 -and @($mutW2 | Where-Object { $_.Method -eq 'PATCH' -and $_.Body -match 'keyCredentials' -and $_.Body -notmatch '"key"\s*:\s*"' }).Count -eq 0 -and $global:MockTenant.RemovedKeyIds -contains $oldIdW) "retraits=$(@($mutW2 | Where-Object { $_.Path -match 'removeKey$' }).Count)"
T 32 'removeKey : le mock a recu et valide un jeton de preuve par retrait (2 jetons sur les deux passages)' ($global:MockTenant.ProofTokens.Count -eq $tokW0 + 2) "jetons=$($global:MockTenant.ProofTokens.Count - $tokW0)"
$conW2 = ($rW2.Console -replace '\s+', ' ')
$chkW2 = [System.Collections.Generic.List[string]]::new()
if ($repW2 -notmatch [regex]::Escape($oldIdW)) { $chkW2.Add('keyId retire absent du rapport') }
if ($repW2 -notmatch [regex]::Escape($thumbW0[0])) { $chkW2.Add('empreinte retiree absente du rapport') }
if ($logW2 -notmatch 'Nettoyage : retrait') { $chkW2.Add('journal sans ligne de retrait') }
if ($repW2 -notmatch 'renouvellement a chaque execution') { $chkW2.Add('raison absente du rapport') }
if ($conW2 -notmatch 'va etre mis a jour') { $chkW2.Add('avertissement connecteur existant absent') }
if ($conW2 -notmatch 'jobs de migration') { $chkW2.Add('mention des jobs de migration absente') }
if ($conW2 -notmatch 'mot de passe du compte de service') { $chkW2.Add('mention du mot de passe du compte absente') }
if (@($repW2, $logW2, $rW2.Console | Where-Object { $_ -match '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}' }).Count -gt 0) { $chkW2.Add('JWT detecte') }
if (@($global:MockTenant.ProofTokens | Where-Object { $repW2.Contains($_) -or $logW2.Contains($_) -or $rW2.Console.Contains($_) }).Count -gt 0) { $chkW2.Add('jeton de preuve present') }
T 32 'rapport et journal : keyId et empreinte de la cle retiree, raison « renouvellement a chaque execution », avertissement « connecteur existant mis a jour », JAMAIS le jeton de preuve (ni aucun JWT) dans la console, le rapport ou le journal' ($chkW2.Count -eq 0) ($chkW2 -join ' ; ')
T 32 'prochaines actions : l''expiration reste une information (« A verifier »), plus de consigne « relancer avant l''echeance », precise que chaque relance renouvelle le certificat' ($repW2 -match 'Chaque relance de l''outil renouvelle le certificat' -and $repW2 -notmatch '(?i)pour rester a jour|avant l''echeance') 'texte de renouvellement'
# --- 32b : -KeepCredentials = zero ecriture ; -WhatIf n'ecrit rien ; -KeepCredentials + -RotateCredentials = erreur ---
$putW4 = $global:MockCiw.PutCount; $rkW4 = $global:MockTenant.RemovedKeys
$rW4 = Invoke-Connector (Keep $w1.Params) $w1.Base
T 32 '-KeepCredentials : second passage idempotent (exit 0, zero ecriture Graph et Cloudiway, aucun retrait, aucun PUT)' ($rW4.Exit -eq 0 -and $rW4.GraphWrites -eq 0 -and $rW4.CiwWrites -eq 0 -and $global:MockCiw.PutCount -eq $putW4 -and $global:MockTenant.RemovedKeys -eq $rkW4) "exit=$($rW4.Exit) $(Get-WriteBrief $rW4.Calls)"
$pWw = $w1.Params.Clone(); $pWw['WhatIf'] = $true
$rkW5 = $global:MockTenant.RemovedKeys
$rW5 = Invoke-Connector $pWw $w1.Base
$clW5 = @(Get-PlanRows $rW5 | Where-Object { $_.Zone -eq 'Nettoyage' })
T 32 '-WhatIf (defaut = renouvellement) : n''ecrit rien (zero ecriture Graph et Cloudiway, aucun retrait, un seul certificat), le plan annonce le renouvellement et le nettoyage' ($rW5.Exit -eq 0 -and $rW5.GraphWrites -eq 0 -and $rW5.CiwWrites -eq 0 -and $global:MockTenant.RemovedKeys -eq $rkW5 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1 -and $clW5.Count -eq 1 -and $clW5[0].Action -eq 'METTRE A JOUR' -and @(Get-PlanRows $rW5 | Where-Object { $_.Raison -match 'renouvellement a chaque execution' }).Count -ge 1) "exit=$($rW5.Exit) $(Get-WriteBrief $rW5.Calls) nettoyage=$($clW5.Count)"
$pBoth = Keep $w1.Params; $pBoth['RotateCredentials'] = $true
$rW6 = Invoke-Connector $pBoth $w1.Base
T 32 '-KeepCredentials + -RotateCredentials : erreur claire, exit 1, avant toute connexion (aucun appel Graph ni Cloudiway)' ($rW6.Exit -eq 1 -and $rW6.Console -match 'Options incompatibles : -KeepCredentials et -RotateCredentials' -and $rW6.GraphCalls -eq 0 -and $rW6.CiwWrites -eq 0 -and $rW6.Connects -eq 0) "exit=$($rW6.Exit) graph=$($rW6.GraphCalls)"
$pRotOnly = $w1.Params.Clone(); $pRotOnly['RotateCredentials'] = $true; $pRotOnly['WhatIf'] = $true
$rW7 = Invoke-Connector $pRotOnly $w1.Base
T 32 '-RotateCredentials / -RotateCertificate restent acceptes (sans effet, compatibilite) : meme plan que le defaut' ($rW7.Exit -eq 0 -and $rW7.Console -notmatch 'Options incompatibles' -and @(Get-PlanRows $rW7 | Where-Object { $_.Zone -eq 'Nettoyage' }).Count -eq 1) "exit=$($rW7.Exit)"
# --- 32c : -SkipCloudiway inchange : aucun identifiant genere, aucun retrait, meme sans option de renouvellement ---
Reset-MockState
$baseW8 = New-Base 'W8'; $allBases.Add($baseW8)
$null = Invoke-Connector (Get-BaseParams $baseW8 @('Mail')) $baseW8
$pW8 = Get-BaseParams $baseW8 @('Mail'); $pW8.Remove('Cloudiway'); $pW8['SkipCloudiway'] = $true; $pW8['ProjectId'] = 12345
$rW8 = Invoke-Connector $pW8 $baseW8
T 32 '-SkipCloudiway (sans option de renouvellement) : inchange, aucun identifiant genere, aucune cle retiree, pas de ligne de nettoyage, connecteur coherent' ($rW8.Exit -eq 0 -and $global:MockTenant.RemovedKeys -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and @(Get-PlanRows $rW8 | Where-Object { $_.Zone -eq 'Nettoyage' }).Count -eq 0 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rW8.Exit) retirees=$($global:MockTenant.RemovedKeys)"
# --- 32d : echec ISOLE d'une cle : les autres sont retirees, message avec les keyId restants, exit 2, le nouvel identifiant est en place ---
Reset-MockState
$baseW9 = New-Base 'W9'; $allBases.Add($baseW9)
$pW9 = Get-BaseParams $baseW9 @('Mail')
$null = Invoke-Connector $pW9 $baseW9
$global:MockOpts.OnWrite = { param($Method, $Path, $Body) if ($Method -eq 'POST' -and $Path -like '/applications/*/removeKey') { throw (New-MockError 500 'InternalServerError' 'echec simule du retrait') } }
$null = Invoke-Connector $pW9 $baseW9    # retrait en echec : l'ancien (A) reste, le nouveau (B) est en place
$global:MockOpts.OnWrite = $null
$idsW9 = @((@(Get-MockApp $AppSrc)[0]).keyCredentials | ForEach-Object { "$($_.keyId)" })
$global:FailKeyId = $idsW9[0]; $okKeyIdW9 = $idsW9[1]
$global:MockOpts.OnWrite = { param($Method, $Path, $Body) if ($Method -eq 'POST' -and $Path -like '/applications/*/removeKey' -and "$($Body.keyId)" -eq $global:FailKeyId) { throw (New-MockError 500 'InternalServerError' 'echec simule du retrait d''une seule cle') } }
$rkW9 = $global:MockTenant.RemovedKeys
$rW9 = Invoke-Connector $pW9 $baseW9      # 3e passage : 2 anciens (A refuse, B retire) + le nouveau (C)
$global:MockOpts.OnWrite = $null
$idsW9b = @((@(Get-MockApp $AppSrc)[0]).keyCredentials | ForEach-Object { "$($_.keyId)" }); $repW9 = Read-RunFile $rW9 'Rapport-*.md'
T 32 'echec isole d''une cle : l''autre ancienne cle est retiree (continue), la cle refusee reste, exit 2, message avec le keyId restant et « deja en place et transmis », connecteur coherent avec le nouveau certificat' ($rW9.Exit -eq 2 -and ($idsW9b -contains $global:FailKeyId) -and ($idsW9b -notcontains $okKeyIdW9) -and $idsW9b.Count -eq 2 -and $global:MockTenant.RemovedKeys -eq $rkW9 + 1 -and $repW9 -match [regex]::Escape($global:FailKeyId) -and $repW9 -match 'keyId restants' -and $repW9 -match 'deja en place et transmis' -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rW9.Exit) cles=$($idsW9b.Count) retirees=$($global:MockTenant.RemovedKeys - $rkW9)"
$rW9b = Invoke-Connector $pW9 $baseW9
T 32 'apres l''echec partiel : le passage suivant retire la cle restante -> UN SEUL certificat, exit 0' ($rW9b.Exit -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rW9b.Exit) cles=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count)"

# --- 32e : preuve de possession (JWT) : construction et validation par le mock, Graph reel simule (PATCH de retrait refuse) ---
$astE = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pkg 'lib\entra.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in 'ConvertTo-Base64Url', 'New-KeyRemovalProof', 'New-ConnectorCertificate') {
    $fd = $astE.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    . ([scriptblock]::Create($fd.Extent.Text))
}
Reset-MockState
$global:MockMgCtx = [pscustomobject]@{ TenantId = $global:MockTenantId; Account = $global:MockUser; Scopes = @(); ContextScope = 'Process' }
function Invoke-MockGraph([string]$Method, [string]$Path, $Body = $null) {
    $pp = @{ Method = $Method; Uri = "https://graph.microsoft.com/v1.0$Path" }
    if ($null -ne $Body) { $pp['Body'] = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    try { $r = Invoke-MgGraphRequest @pp; return @{ Ok = $true; Msg = ''; Result = $r } }
    catch { return @{ Ok = $false; Msg = "$($_.ErrorDetails.Message) $($_.Exception.Message)"; Result = $null } }
}
function New-TestJwt($Hdr, $Pl, [string]$Sig = 'c2lnbmF0dXJl') { (ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes(($Hdr | ConvertTo-Json -Compress)))) + '.' + (ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes(($Pl | ConvertTo-Json -Compress)))) + '.' + $Sig }
function New-TestKeyBody($Cert, [string]$Name) { [ordered]@{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $Cert.CerBase64; displayName = $Name; startDateTime = $Cert.NotBefore.ToString('yyyy-MM-ddTHH:mm:ssZ'); endDateTime = $Cert.NotAfter.ToString('yyyy-MM-ddTHH:mm:ssZ') } }
function ConvertTo-TestKeepEntry($K) { [ordered]@{ type = $K.type; usage = $K.usage; keyId = $K.keyId; customKeyIdentifier = $K.customKeyIdentifier; displayName = $K.displayName; startDateTime = $K.startDateTime; endDateTime = $K.endDateTime } }
$gApp = Invoke-MockGraph POST '/applications' @{ displayName = 'UT-PROOF'; signInAudience = 'AzureADMyOrg'; tags = @('CloudiwayConnector'); requiredResourceAccess = @() }
$appIdP = "$($gApp.Result.id)"
$pwA = 'PwA-' + [guid]::NewGuid().ToString('N'); $pwB = 'PwB-' + [guid]::NewGuid().ToString('N'); $pwC = 'PwC-' + [guid]::NewGuid().ToString('N')
$cA = New-ConnectorCertificate -Subject 'CN=UT-A' -ValidityDays 30 -Password $pwA
$cB = New-ConnectorCertificate -Subject 'CN=UT-B' -ValidityDays 30 -Password $pwB
$cC = New-ConnectorCertificate -Subject 'CN=UT-C' -ValidityDays 30 -Password $pwC   # JAMAIS enregistre dans l'application
$r1p = Invoke-MockGraph PATCH "/applications/$appIdP" @{ keyCredentials = @((New-TestKeyBody $cA 'UT-A')) }
$kA = @((Invoke-MockGraph GET "/applications/$appIdP").Result.keyCredentials)
$r2p = Invoke-MockGraph PATCH "/applications/$appIdP" @{ keyCredentials = @((ConvertTo-TestKeepEntry $kA[0]), (New-TestKeyBody $cB 'UT-B')) }
$kAB = @((Invoke-MockGraph GET "/applications/$appIdP").Result.keyCredentials)
$keyIdA = "$($kAB[0].keyId)"; $keyIdB = "$($kAB[1].keyId)"
T 32 'mock fidele a Graph : l''AJOUT d''un certificat (anciennes cles sans key + nouvelle avec key) est accepte' ($r1p.Ok -and $r2p.Ok -and $kAB.Count -eq 2) "ajout A=$($r1p.Ok) ajout B=$($r2p.Ok) cles=$($kAB.Count) $($r2p.Msg)"
$rPatchRm = Invoke-MockGraph PATCH "/applications/$appIdP" @{ keyCredentials = @((ConvertTo-TestKeepEntry $kAB[1])) }
$stillTwo = @((Invoke-MockGraph GET "/applications/$appIdP").Result.keyCredentials).Count -eq 2
T 32 'mock fidele a Graph : un PATCH keyCredentials qui RETIRE une cle SANS fournir key pour les cles restantes renvoie 400 « KeyValue cannot be null or empty » (rien n''est retire)' (-not $rPatchRm.Ok -and $rPatchRm.Msg -match 'KeyValue cannot be null or empty' -and $stillTwo -and $global:MockTenant.RemovedKeys -eq 0) "ok=$($rPatchRm.Ok) msg=$($rPatchRm.Msg)"
$proofOk = New-KeyRemovalProof -PfxBytes $cB.PfxBytes -PfxPassword $pwB -AppObjectId $appIdP
$segP = $proofOk -split '\.'
$decP = { param($s) $s = $s.Replace('-', '+').Replace('_', '/'); switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }; [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) }
$hdrP = (& $decP $segP[0]) | ConvertFrom-Json; $plP = (& $decP $segP[1]) | ConvertFrom-Json
$x5tWant = (ConvertTo-Base64Url ([System.Security.Cryptography.SHA1]::HashData([Convert]::FromBase64String($cB.CerBase64))))
$nowP = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
T 32 'jeton de preuve : 3 segments base64url sans remplissage, en-tete { RS256, JWT, x5t = base64url(SHA1 du nouveau certificat), kid = x5t (m1) }, charge { aud, iss = object id, nbf = -1 min, exp = +8 min }' ($segP.Count -eq 3 -and $proofOk -notmatch '[=+/]' -and $hdrP.alg -eq 'RS256' -and $hdrP.typ -eq 'JWT' -and $hdrP.x5t -eq $x5tWant -and $hdrP.kid -eq $x5tWant -and $plP.aud -eq '00000002-0000-0000-c000-000000000000' -and $plP.iss -eq $appIdP -and ($nowP - [long]$plP.nbf) -in 55..70 -and ([long]$plP.exp - $nowP) -in 470..485) "x5t=$($hdrP.x5t) attendu=$x5tWant"
$badCases = [ordered]@{
    'segments'  = 'abc'
    'RS256'     = (New-TestJwt @{ alg = 'none'; typ = 'JWT'; x5t = $x5tWant } @{ aud = '00000002-0000-0000-c000-000000000000'; iss = $appIdP; nbf = $nowP - 60; exp = $nowP + 480 })
    'x5t'       = (New-TestJwt @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-Base64Url ([byte[]](1..20))) } @{ aud = '00000002-0000-0000-c000-000000000000'; iss = $appIdP; nbf = $nowP - 60; exp = $nowP + 480 })
    'aud'       = (New-TestJwt @{ alg = 'RS256'; typ = 'JWT'; x5t = $x5tWant } @{ aud = '00000003-0000-0000-c000-000000000000'; iss = $appIdP; nbf = $nowP - 60; exp = $nowP + 480 })
    'iss'       = (New-KeyRemovalProof -PfxBytes $cB.PfxBytes -PfxPassword $pwB -AppObjectId ([guid]::NewGuid().ToString()))
    'expire'    = (New-TestJwt @{ alg = 'RS256'; typ = 'JWT'; x5t = $x5tWant } @{ aud = '00000002-0000-0000-c000-000000000000'; iss = $appIdP; nbf = $nowP - 600; exp = $nowP - 30 })
    '10 minutes' = (New-TestJwt @{ alg = 'RS256'; typ = 'JWT'; x5t = $x5tWant } @{ aud = '00000002-0000-0000-c000-000000000000'; iss = $appIdP; nbf = $nowP - 60; exp = $nowP + 3600 })
    'signature' = ($segP[0] + '.' + $segP[1] + '.' + ('AAAAAAAAAAAA' + $segP[2].Substring(12)))
}
$badOut = [System.Collections.Generic.List[string]]::new()
foreach ($bk in $badCases.Keys) {
    $gr = Invoke-MockGraph POST "/applications/$appIdP/removeKey" @{ keyId = $keyIdA; proof = $badCases[$bk] }
    if ($gr.Ok -or $gr.Msg -notmatch [regex]::Escape($bk)) { $badOut.Add("$bk (ok=$($gr.Ok) $($gr.Msg))") }
}
$proofC = New-KeyRemovalProof -PfxBytes $cC.PfxBytes -PfxPassword $pwC -AppObjectId $appIdP   # signe par un certificat NON enregistre dans l'application
$grC = Invoke-MockGraph POST "/applications/$appIdP/removeKey" @{ keyId = $keyIdA; proof = $proofC }
$grNoProof = Invoke-MockGraph POST "/applications/$appIdP/removeKey" @{ keyId = $keyIdA }
T 32 'preuve invalide REFUSEE par le mock : mauvais nombre de segments, alg autre que RS256, x5t inconnu, aud ou iss incorrect, jeton expire, exp au-dela de 10 minutes, signature alteree, certificat non enregistre, preuve absente (aucune cle retiree)' ($badOut.Count -eq 0 -and -not $grC.Ok -and $grC.Msg -match 'x5t' -and -not $grNoProof.Ok -and $global:MockTenant.RemovedKeys -eq 0 -and @((Invoke-MockGraph GET "/applications/$appIdP").Result.keyCredentials).Count -eq 2) "refus manques : $($badOut -join ' ; ') C=$($grC.Msg)"
$grOk = Invoke-MockGraph POST "/applications/$appIdP/removeKey" @{ keyId = $keyIdA; proof = $proofOk }
$leftP = @((Invoke-MockGraph GET "/applications/$appIdP").Result.keyCredentials)
T 32 'preuve valide (signee par la cle privee du certificat B enregistre) : la cle A est retiree, B reste' ($grOk.Ok -and $leftP.Count -eq 1 -and "$($leftP[0].keyId)" -eq $keyIdB -and $global:MockTenant.RemovedKeyIds -contains $keyIdA) "ok=$($grOk.Ok) $($grOk.Msg) restantes=$($leftP.Count)"
$global:MockMgCtx = $null
foreach ($cx in $cA, $cB, $cC) { $cx.PfxBytes = $null }

# --- 32f : mutation de controle : remettre l'ancien PATCH de retrait doit faire echouer (le mock fidele a Graph le refuse) ---
$mutDir2 = Join-Path $tmpRoot 'mutation-removekey'; New-Item -ItemType Directory -Path $mutDir2 -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $pkg 'cloudiway-connector.ps1') -Destination $mutDir2
Copy-Item -LiteralPath (Join-Path $pkg 'lib') -Destination $mutDir2 -Recurse
$mMain2 = Join-Path $mutDir2 'cloudiway-connector.ps1'; $mEntra2 = Join-Path $mutDir2 'lib\entra.ps1'
$tE2 = [System.IO.File]::ReadAllText($mEntra2)
$oldCall = 'Invoke-GraphPost "/applications/$AppObjectId/removeKey" @{ keyId = $KeyId; proof = $Proof }'
$oldPatch = 'Invoke-GraphPatch "/applications/$AppObjectId" @{ keyCredentials = @((Invoke-GraphGet (''/applications/{0}?$select=id,keyCredentials'' -f $AppObjectId)).keyCredentials | Where-Object { "$($_.keyId)" -ne $KeyId } | ForEach-Object { ConvertTo-KeepKeyEntry $_ }) }'
$nOld = ([regex]::Matches($tE2, [regex]::Escape($oldCall))).Count
[System.IO.File]::WriteAllText($mEntra2, $tE2.Replace($oldCall, $oldPatch), [System.Text.UTF8Encoding]::new($true))
T 32 'mutation de controle : l''appel removeKey existe une seule fois dans les sources (remplacable par l''ancien PATCH de retrait)' ($nOld -eq 1) "occurrences=$nOld"
Reset-MockState
$baseW10 = New-Base 'W10'; $allBases.Add($baseW10)
$pW10 = Get-BaseParams $baseW10 @('Mail')
$null = Invoke-Connector $pW10 $baseW10
$mainSaved2 = $main; $main = $mMain2
$rMut2 = Invoke-Connector $pW10 $baseW10
$main = $mainSaved2
$mutDetected2 = ($rMut2.Exit -eq 2 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 2 -and $global:MockTenant.RemovedKeys -eq 0)
T 32 'mutation de controle : avec l''ANCIEN PATCH de retrait le nettoyage ECHOUE (Graph refuse : KeyValue cannot be null or empty), 2 certificats restent : le test « un seul certificat actif » echouerait, mutation detectee' $mutDetected2 "exit=$($rMut2.Exit) certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count) retirees=$($global:MockTenant.RemovedKeys)"
# memes conditions avec les vraies sources : un seul certificat
$rReal2 = Invoke-Connector $pW10 $baseW10
T 32 'memes conditions avec les vraies sources : removeKey retire les anciens -> UN SEUL certificat, exit 0' ($rReal2.Exit -eq 0 -and @(@(Get-MockApp $AppSrc)[0].keyCredentials).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rReal2.Exit) certs=$(@(@(Get-MockApp $AppSrc)[0].keyCredentials).Count)"

$srcTok = @()
foreach ($sf in @((Join-Path $pkg 'cloudiway-connector.ps1')) + @(Get-ChildItem -LiteralPath (Join-Path $pkg 'lib') -Filter '*.ps1' -File | ForEach-Object FullName)) {
    $ln = 0; foreach ($l in [System.IO.File]::ReadAllLines($sf)) { $ln++; if ($l -notmatch '^\s*#' -and $l -match '(Write-RunLog|Write-Status|Write-StatusLog|Write-Host|Write-Output|Out-File|Add-Content|Set-Content)\b[^|]*\$(proof|prf)\b') { $srcTok += "$(Split-Path -Leaf $sf):$ln" } }
}
T 32 'sources : le jeton de preuve ($proof / $prf) n''est jamais passe a une fonction d''affichage, de journal ou d''ecriture' ($srcTok.Count -eq 0) ($srcTok -join ', ')

# ===================================================================================================
# POINT 33 (v2.4) : fileName du certificat = marqueur de suivi, relecture apres ecriture (B1 / M1 / M2), garde-fou (d),
#                   session Graph (M3), svc-ciw- (M4), removeKey avec reessais (M5), PowerShell 7.2 (M6), m1 a m13, banc fidele au portail
# ===================================================================================================
function Invoke-MockCiw([string]$Method, [string]$Path, $Body = $null) {
    $pp = @{ Method = $Method; Uri = "https://api-production.cloudiway.com/ap1$Path"; Headers = @{ Authorization = "Bearer $($global:MockCiw.Token)"; projectId = "$($global:MockProjectId)"; accept = '*/*' } }
    if ($null -ne $Body) { $pp['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress); $pp['ContentType'] = 'application/json' }
    try { $r = Invoke-RestMethod @pp; return @{ Ok = $true; Msg = ''; Result = $r } }
    catch { return @{ Ok = $false; Msg = "$($_.ErrorDetails.Message) $($_.Exception.Message)"; Result = $null } }
}
function Get-MockConnectorFile([string]$Name) { $cc = (Get-MockConnector $Name).connectorCertificate; if ($cc) { "$($cc.fileName)" } else { '' } }
function Get-MockSleepCount([int]$Seconds) { @($global:MockSleeps | Where-Object { $_ -eq $Seconds }).Count }

# --- 33a : creation, renouvellement sur place, second passage, connecteur anterieur ---
Reset-MockState
$b33a = New-Base 'Z1'; $allBases.Add($b33a)
$p33a = Get-BaseParams $b33a @('Mail', 'OneDrive'); $p33a['ProductIds'] = '5,6'
$z1 = Invoke-Connector $p33a $b33a
$cZ1 = Get-MockConnector $ConnSrc; $certZ1 = Get-ConnCert $cZ1; $fnZ1 = "$($cZ1.connectorCertificate.fileName)"; $extZ1 = "$($cZ1.externalKey)"; $idCertZ1 = $cZ1.connectorCertificate.id
$repZ1 = Read-RunFile $z1 'Rapport-*.md'
T 33 'creation : fileName du certificat = CIW1_<32 premiers hex de l''empreinte>_<AAAAMMJJ expiration>.pfx, uniquement [A-Za-z0-9_.-]' ($z1.Exit -eq 0 -and $certZ1 -and $fnZ1 -ceq ('CIW1_' + $certZ1.Thumbprint.Substring(0, 32) + '_' + $certZ1.NotAfter.ToString('yyyyMMdd') + '.pfx') -and $fnZ1 -match '^[A-Za-z0-9_.-]+$') "exit=$($z1.Exit) fileName=$fnZ1"
T 33 'creation : externalKey = etiquette de propriete CIW1|<empreinte 32>|<AAAAMMJJ> ecrite UNE fois a la creation (46 caracteres, limite portail 50)' ($extZ1 -ceq ('CIW1|' + $certZ1.Thumbprint.Substring(0, 32) + '|' + $certZ1.NotAfter.ToString('yyyyMMdd')) -and $extZ1.Length -le 50) "externalKey=$extZ1"
T 33 'creation : relecture apres ecriture (GET du connecteur) puis verification : lignes « certificat » et « marqueur » Conformes (nom de fichier relu = nom envoye)' ($repZ1 -match 'Connecteur Cloudiway : certificat \| Conforme' -and $repZ1 -match 'Connecteur Cloudiway : marqueur \| Conforme') 'lignes de verification du certificat / marqueur'
$z2 = Invoke-Connector $p33a $b33a
$cZ2 = Get-MockConnector $ConnSrc; $certZ2 = Get-ConnCert $cZ2; $fnZ2 = "$($cZ2.connectorCertificate.fileName)"
$repZ2 = Read-RunFile $z2 'Rapport-*.md'
T 33 'renouvellement (PUT) : le certificat est remplace SUR PLACE (meme id), le fileName devient le nouveau marqueur, l''externalKey de creation reste INCHANGEE' ($z2.Exit -eq 0 -and $cZ2.connectorCertificate.id -eq $idCertZ1 -and $fnZ2 -ne $fnZ1 -and $fnZ2 -ceq ('CIW1_' + $certZ2.Thumbprint.Substring(0, 32) + '_' + $certZ2.NotAfter.ToString('yyyyMMdd') + '.pfx') -and "$($cZ2.externalKey)" -ceq $extZ1) "exit=$($z2.Exit) id=$idCertZ1->$($cZ2.connectorCertificate.id) fileName=$fnZ2 externalKey=$($cZ2.externalKey)"
T 33 'renouvellement : relecture apres le PUT = ecriture CONFIRMEE : anciens certificats retires (1 seul), verification « certificat » Conforme' ($z2.Exit -eq 0 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '' -and $repZ2 -match 'Connecteur Cloudiway : certificat \| Conforme') "incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
$z3 = Invoke-Connector (Keep $p33a) $b33a
$repZ3 = Read-RunFile $z3 'Rapport-*.md'
T 33 'marqueur par fileName, -KeepCredentials : marqueur coherent (empreinte de l''application, valide > 30 jours) = RIEN a faire (zero ecriture, exit 0), expiration affichee lue dans le fileName' ($z3.Exit -eq 0 -and $z3.GraphWrites -eq 0 -and $z3.CiwWrites -eq 0 -and $repZ3 -match [regex]::Escape('Expiration des identifiants du connecteur : ' + $certZ2.NotAfter.ToString('dd/MM/yyyy', [System.Globalization.CultureInfo]::InvariantCulture))) "exit=$($z3.Exit) graph=$($z3.GraphWrites) ciw=$($z3.CiwWrites) attendu=$($certZ2.NotAfter.ToString('dd/MM/yyyy', [System.Globalization.CultureInfo]::InvariantCulture)) rapport=$(($repZ3 -split "`n" | Where-Object { $_ -match 'Expiration' } | Select-Object -First 2) -join ' // ') len=$($repZ3.Length)"
# connecteur anterieur a la v2.4 : fileName cloudiway.pfx + externalKey CIW1|..|..
$cZ3 = Get-MockConnector $ConnSrc; $mkZ3 = Get-MockMarker $cZ3
$cZ3.connectorCertificate.fileName = 'cloudiway.pfx'; $cZ3.externalKey = "CIW1|$($mkZ3.Id)|$($mkZ3.Date)"
$z4 = Invoke-Connector (Keep $p33a) $b33a
$repZ4 = Read-RunFile $z4 'Rapport-*.md'
T 33 'connecteur anterieur (fileName cloudiway.pfx + externalKey CIW1|..|..) : marqueur lu dans l''externalKey, -KeepCredentials = zero ecriture, exit 0, expiration affichee' ($z4.Exit -eq 0 -and $z4.GraphWrites -eq 0 -and $z4.CiwWrites -eq 0 -and $repZ4 -match [regex]::Escape('Expiration des identifiants du connecteur : ' + $certZ2.NotAfter.ToString('dd/MM/yyyy', [System.Globalization.CultureInfo]::InvariantCulture))) "exit=$($z4.Exit) graph=$($z4.GraphWrites) ciw=$($z4.CiwWrites)"
$cZ3.connectorCertificate.fileName = 'cloudiway.pfx'; $cZ3.externalKey = 'CIW1|' + ('CD' * 16) + '|20270101'
$z5 = Invoke-Connector (Keep $p33a) $b33a
T 33 'connecteur anterieur dont l''empreinte (externalKey) est INCONNUE de l''application : renouvellement, le fileName devient le marqueur CIW1_..., connecteur coherent, exit 0' ($z5.Exit -eq 0 -and (Get-MockConnectorFile $ConnSrc) -cmatch '^CIW1_[0-9A-F]{32}_\d{8}\.pfx$' -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($z5.Exit) fileName=$(Get-MockConnectorFile $ConnSrc)"

# --- 33b : B1 - le portail repond « succes » mais n'a pas pris le certificat (PUT ignore le certificat) ---
$x2 = New-SourceMailOd 'Z2'
$cX2 = Get-MockConnector $ConnSrc; $fnX2 = "$($cX2.connectorCertificate.fileName)"; $idX2 = $cX2.connectorCertificate.id; $rkX2 = $global:MockTenant.RemovedKeys; $tokX2 = $global:MockTenant.ProofTokens.Count
$global:MockOpts.CiwPutIgnoresCert = $true
$rX2 = Invoke-Connector $x2.Params $x2.Base
$global:MockOpts.CiwPutIgnoresCert = $false
$repX2 = Read-RunFile $rX2 'Rapport-*.md'
T 33 'B1 : PUT annonce reussi (isSuccess) mais fileName inchange : ECHEC « le portail n''a pas pris en compte le nouveau certificat », ConnectorWriteOk faux, code de sortie 2' ($rX2.Exit -eq 2 -and $rX2.Console -match 'le portail n''a pas pris en compte le nouveau certificat' -and (Get-MockConnectorFile $ConnSrc) -ceq $fnX2) "exit=$($rX2.Exit) fileName=$(Get-MockConnectorFile $ConnSrc)"
T 33 'B1 : AUCUN retrait (aucun removeKey, aucun jeton de preuve, ancien certificat conserve = 2 certificats dans l''application)' ($global:MockTenant.RemovedKeys -eq $rkX2 -and $global:MockTenant.ProofTokens.Count -eq $tokX2 -and @($rX2.Calls | Where-Object { $_.Path -match 'removeKey$' }).Count -eq 0 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 2) "retirees=$($global:MockTenant.RemovedKeys - $rkX2) certs=$(@(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count)"
T 33 'B1 : ligne « Nettoyage » IGNOREE (dependance de la ligne Cloudiway), message actionnable (relancer), verification « certificat » NON CONFORME' ($repX2 -match 'Nettoyage \| Anciens certificats de l''outil \| IGNORE' -and $repX2 -match 'Relancer l''outil' -and $repX2 -match 'Connecteur Cloudiway : certificat \| NON CONFORME') 'lignes du rapport'
$rX2b = Invoke-Connector $x2.Params $x2.Base
T 33 'B1 : relance (portail corrige) : le connecteur prend le certificat, mot de passe resynchronise, orphelin et ancien retires (1 seul certificat), coherent, exit 0' ($rX2b.Exit -eq 0 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '' -and (Get-MockConnectorFile $ConnSrc) -cne $fnX2) "exit=$($rX2b.Exit) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"

# --- 33c : M1 - reponse perdue apres traitement (timeout / 5xx) mais fileName conforme : ecriture CONFIRMEE ---
$x3 = New-SourceMailOd 'Z3'
$rkX3 = $global:MockTenant.RemovedKeys; $fnX3 = Get-MockConnectorFile $ConnSrc
$global:MockOpts.CiwLoseResponse = @(@{ Method = 'PUT'; Pattern = '^/Connectors/\d+$'; Times = 1; Code = 504 })
$rX3 = Invoke-Connector $x3.Params $x3.Base
$global:MockOpts.CiwLoseResponse = @()
$repX3 = Read-RunFile $rX3 'Rapport-*.md'
T 33 'M1 : reponse du PUT perdue (504) mais fileName conforme a la relecture : ecriture CONFIRMEE (exit 0, PUT non rejoue), nettoyage effectue, connecteur coherent' ($rX3.Exit -eq 0 -and @($rX3.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Method -eq 'PUT' }).Count -eq 1 -and $global:MockTenant.RemovedKeys -eq $rkX3 + 1 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1 -and (Get-MockConnectorFile $ConnSrc) -cne $fnX3 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rX3.Exit) PUT=$(@($rX3.Calls | Where-Object { $_.Method -eq 'PUT' }).Count) retirees=$($global:MockTenant.RemovedKeys - $rkX3) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"
T 33 'M1 : l''erreur de reponse est signalee dans le rapport (« la relecture confirme le nouveau certificat »)' ($repX3 -match 'la relecture confirme le nouveau certificat') 'information absente'
Reset-MockState
$global:MockOpts.CiwLoseResponse = @(@{ Method = 'POST'; Pattern = '^/Connectors$'; Times = 1; Code = 504 })
$b33c = New-Base 'Z3b'; $allBases.Add($b33c)
$rX3b = Invoke-Connector (Get-BaseParams $b33c @('Mail')) $b33c
$global:MockOpts.CiwLoseResponse = @()
T 33 'M1 : reponse du POST (creation) perdue : connecteur retrouve par son nom, fileName conforme = ecriture confirmee, un seul POST, exit 0, coherent' ($rX3b.Exit -eq 0 -and @($rX3b.Calls | Where-Object { $_.Kind -eq 'Ciw' -and $_.Method -eq 'POST' -and $_.Path -eq '/Connectors' }).Count -eq 1 -and @($global:MockCiw.Connectors).Count -eq 1 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rX3b.Exit) connecteurs=$(@($global:MockCiw.Connectors).Count) incoherence=$(Test-ConnCoherence $ConnSrc $AppSrc)"

# --- 33d : M2 - relecture impossible / fileName illisible = etat « non verifiable » traite comme NON confirme ---
$x4 = New-SourceMailOd 'Z4'
$rkX4 = $global:MockTenant.RemovedKeys
$global:MockOpts.CiwHideFileName = $true
$rX4 = Invoke-Connector $x4.Params $x4.Base
$global:MockOpts.CiwHideFileName = $false
$repX4 = Read-RunFile $rX4 'Rapport-*.md'
T 33 'M2 : nom de fichier du certificat illisible apres l''ecriture = « NON verifiable », traite comme NON confirme : exit 2, aucun retrait' ($rX4.Exit -eq 2 -and $rX4.Console -match 'NON verifiable' -and $global:MockTenant.RemovedKeys -eq $rkX4 -and @($rX4.Calls | Where-Object { $_.Path -match 'removeKey$' }).Count -eq 0) "exit=$($rX4.Exit) retirees=$($global:MockTenant.RemovedKeys - $rkX4)"
T 33 'M2 : controle post-ecriture : « certificat » et « marqueur » marques A verifier (WARN), jamais un faux « conforme »' ($repX4 -match 'Connecteur Cloudiway : certificat \| A verifier' -and $repX4 -match 'Connecteur Cloudiway : marqueur \| A verifier') 'lignes WARN absentes'
# relecture impossible (GET du detail en panne apres l'ecriture) : meme traitement
$x5 = New-SourceMailOd 'Z5'
$rkX5 = $global:MockTenant.RemovedKeys; 
$global:MockOpts.CiwFail = @(@{ Method = 'GET'; Pattern = '^/Connectors/\d+$'; Code = 503; Times = 4; Skip = 3 })   # lectures de l'etape 2, du plan et de l'application passent ; les 4 essais de la relecture echouent
$rX5 = Invoke-Connector $x5.Params $x5.Base
$global:MockOpts.CiwFail = @()
T 33 'M2 : relecture du connecteur IMPOSSIBLE apres l''ecriture (GET en 503) : etat non verifiable = NON confirme (exit 2, aucun retrait)' ($rX5.Exit -eq 2 -and $rX5.Console -match 'NON verifiable' -and $global:MockTenant.RemovedKeys -eq $rkX5) "exit=$($rX5.Exit) retirees=$($global:MockTenant.RemovedKeys - $rkX5)"

# --- 33e : mutation de controle : sans la verification par fileName, le test B1 (aucun retrait) ECHOUE ---
$mutDir3 = Join-Path $tmpRoot 'mutation-filename'; New-Item -ItemType Directory -Path $mutDir3 -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $pkg 'cloudiway-connector.ps1') -Destination $mutDir3
Copy-Item -LiteralPath (Join-Path $pkg 'lib') -Destination $mutDir3 -Recurse
$mMain3 = Join-Path $mutDir3 'cloudiway-connector.ps1'; $mCiw3 = Join-Path $mutDir3 'lib\cloudiway.ps1'
$tC3 = [System.IO.File]::ReadAllText($mCiw3)
$okLine = "if (`$fn -ceq `$ExpectedFileName) { `$res.State = 'Confirmed'"
$nOk = ([regex]::Matches($tC3, [regex]::Escape($okLine))).Count
[System.IO.File]::WriteAllText($mCiw3, $tC3.Replace($okLine, "if (`$true) { `$res.State = 'Confirmed'"), [System.Text.UTF8Encoding]::new($true))
T 33 'mutation de controle : la comparaison du fileName relu au nom envoye existe une seule fois dans les sources' ($nOk -eq 1) "occurrences=$nOk"
$x6 = New-SourceMailOd 'Z6'
$rkX6 = $global:MockTenant.RemovedKeys
$global:MockOpts.CiwPutIgnoresCert = $true
$mainSaved3 = $main; $main = $mMain3
$rMut3 = Invoke-Connector $x6.Params $x6.Base
$main = $mainSaved3
$global:MockOpts.CiwPutIgnoresCert = $false
T 33 'mutation de controle : verification par fileName DESACTIVEE -> l''ancien certificat est retire alors que le portail n''a pas pris le nouveau (le test B1 « aucun retrait » echouerait : mutation detectee)' ($global:MockTenant.RemovedKeys -gt $rkX6) "retirees=$($global:MockTenant.RemovedKeys - $rkX6) exit=$($rMut3.Exit)"

# --- 33f : banc fidele au portail (faits mesures 1 a 7) ---
$f1 = New-SourceMailOd 'Z7'
$cF = Get-MockConnector $ConnSrc
$gF = (Invoke-MockCiw GET "/Connectors/$($cF.id)").Result.responseData
T 33 'banc fidele (fait 1) : le GET renvoie connectorCertificate { id, connectorId, fileName, secret et certificateFile non vides } et poolId / connectorTypeId' ($gF.connectorCertificate.id -gt 0 -and $gF.connectorCertificate.connectorId -eq $cF.id -and $gF.connectorCertificate.fileName -and $gF.connectorCertificate.secret -and $gF.connectorCertificate.certificateFile -and $gF.poolId -eq 3 -and "$($gF.connectorTypeId)" -eq '2') 'forme du GET'
$certIdF = $gF.connectorCertificate.id
$rawF = ($gF.rawSettings | ConvertFrom-Json -AsHashtable); $rawF['CleInconnue'] = 'a-supprimer'
$putF = @{ id = $gF.id; name = $gF.name; isTarget = $gF.isTarget; poolId = $gF.poolId; connectorTypeId = $gF.connectorTypeId; rawProductList = $gF.rawProductList; rawSettings = ($rawF | ConvertTo-Json -Compress); externalKey = 'CIW1|ZZ|20300101'
    connectorCertificate = @{ secret = 'pwdtest-pwdtest'; certificateFile = ([Convert]::ToBase64String([byte[]](1..40))); fileName = 'CIW1_AAAA_20300101.pfx'; connectorId = $gF.id } }
$rF1 = Invoke-MockCiw PUT "/Connectors/$($cF.id)" $putF
$gF2 = (Invoke-MockCiw GET "/Connectors/$($cF.id)").Result.responseData
$rawF2 = $gF2.rawSettings | ConvertFrom-Json -AsHashtable
T 33 'banc fidele (faits 2 et 3) : un PUT AVEC connectorCertificate remplace l''enregistrement SUR PLACE (meme id, nouveau fileName) ; externalKey n''est JAMAIS modifie ; rawSettings est re-serialise (cle inconnue supprimee)' ($rF1.Ok -and $gF2.connectorCertificate.id -eq $certIdF -and $gF2.connectorCertificate.fileName -ceq 'CIW1_AAAA_20300101.pfx' -and "$($gF2.externalKey)" -ceq "$($gF.externalKey)" -and -not $rawF2.ContainsKey('CleInconnue') -and $rawF2.ContainsKey('RestClientId')) "ok=$($rF1.Ok) fileName=$($gF2.connectorCertificate.fileName) externalKey=$($gF2.externalKey) $($rF1.Msg)"
$putNoCert = @{ id = $gF.id; name = $gF.name; isTarget = $gF.isTarget; poolId = $gF.poolId; connectorTypeId = $gF.connectorTypeId; rawProductList = '[1,2,3]'; rawSettings = $gF.rawSettings; externalKey = $gF.externalKey }
$rF3 = Invoke-MockCiw PUT "/Connectors/$($cF.id)" $putNoCert
$gF3 = (Invoke-MockCiw GET "/Connectors/$($cF.id)").Result.responseData
T 33 'banc fidele (fait 4) : un PUT SANS connectorCertificate sur un connecteur qui en possede un renvoie HTTP 500 « Object reference not set to an instance of an object » et ne modifie RIEN' (-not $rF3.Ok -and $rF3.Msg -match 'Object reference not set to an instance of an object' -and $rF3.Msg -match '500' -and $gF3.rawProductList -eq $gF2.rawProductList -and $gF3.connectorCertificate.fileName -ceq 'CIW1_AAAA_20300101.pfx') "ok=$($rF3.Ok) $($rF3.Msg) produits=$($gF3.rawProductList)"
$putNoPool = @{ id = $gF.id; name = $gF.name; isTarget = $gF.isTarget; rawProductList = $gF.rawProductList; rawSettings = $gF.rawSettings; connectorCertificate = $putF.connectorCertificate }
$rF4 = Invoke-MockCiw PUT "/Connectors/$($cF.id)" $putNoPool
$gF4 = (Invoke-MockCiw GET "/Connectors/$($cF.id)").Result.responseData
T 33 'banc fidele (fait 5) : un PUT sans poolId / connectorTypeId les remet a 0' ($rF4.Ok -and $gF4.poolId -eq 0 -and "$($gF4.connectorTypeId)" -eq '0') "poolId=$($gF4.poolId) connectorTypeId=$($gF4.connectorTypeId)"
$extLong = Invoke-MockCiw POST '/Connectors' @{ connectorTypeId = 2; name = 'x-long'; rawsettings = '{}'; rawProductList = '[5]'; externalKey = ('X' * 51) }
T 33 'banc fidele (fait 6) : externalKey limite a 50 caracteres (51 refuses en HTTP 500 « would be truncated »)' (-not $extLong.Ok -and $extLong.Msg -match 'truncated') "ok=$($extLong.Ok) $($extLong.Msg)"
Set-MockConnectorSetting $cF 'MigrationAccountPassword' 'seed-pwd-seed'
$global:MockOpts.CiwMaskSecrets = $true
$gF5 = (Invoke-MockCiw GET "/Connectors/$($cF.id)").Result.responseData
$rawF5 = $gF5.rawSettings | ConvertFrom-Json -AsHashtable
$global:MockOpts.CiwMaskSecrets = $false
T 33 'banc fidele (fait 7) : le portail masque RestClientSecret / MigrationAccountPassword dans rawSettings a la lecture (option CiwMaskSecrets)' ("$($rawF5.MigrationAccountPassword)" -match '^\*+$') "valeur=$($rawF5.MigrationAccountPassword)"

# --- 33g : garde-fou (d) en execution : un PUT n'est JAMAIS tente sans certificat sur un connecteur qui en possede un ---
$staticCiw = Get-Content -LiteralPath (Join-Path $pkg 'lib\cloudiway.ps1') -Raw -Encoding utf8
T 33 'garde-fou (d) dans les sources : message « le portail exige le certificat lors d''une mise a jour : relancer sans -KeepCredentials » dans le plan ET a l''application ; New-CiwUpdateBody refuse un PUT sans certificat' ($staticCiw -match "le portail exige le certificat lors d''une mise a jour : relancer sans -KeepCredentials" -and ([regex]::Matches($staticCiw, 'CiwNeedCertMsg')).Count -ge 4) 'garde-fou absent'

# --- 33h : M3 - session Microsoft Graph juste avant la premiere ecriture ---
Reset-MockState; $global:MockDcPolls = 0; $global:MockOpts.DeviceTokenLifetimeSec = 600
$b33h = New-Base 'Z8'; $allBases.Add($b33h)
$pH = Get-BaseParams $b33h @('Mail'); $pH['UseDeviceCode'] = $true
$rH = Invoke-Connector $pH $b33h
T 33 'M3 : jeton du code d''appareil expirant dans 10 minutes (< 15) : refus « Session Graph expiree ou presque : relancer », exit 1, AUCUNE ecriture (Graph, Cloudiway), rien cree' ($rH.Exit -eq 1 -and $rH.Console -match 'Session Graph expiree ou presque' -and $rH.GraphWrites -eq 0 -and $rH.CiwWrites -eq 0 -and @($global:MockTenant.Apps).Count -eq 0) "exit=$($rH.Exit) graph=$($rH.GraphWrites)"
Reset-MockState; $global:MockDcPolls = 0
$b33h2 = New-Base 'Z8b'; $allBases.Add($b33h2)
$rH2 = Invoke-Connector $pH $b33h2
T 33 'M3 : jeton du code d''appareil valable 1 h : l''application se deroule (exit 0) et la session Graph est verifiee par un GET /organization juste avant la premiere ecriture' ($rH2.Exit -eq 0 -and @($rH2.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'GET' -and $_.Path -eq '/organization' }).Count -ge 2 -and $rH2.Console -match 'Session Graph reverifiee') "exit=$($rH2.Exit) organization=$(@($rH2.Calls | Where-Object { $_.Path -eq '/organization' }).Count)"
Reset-MockState
$global:MockOpts.GraphExpire = @(@{ Method = 'GET'; Pattern = '^/organization$'; Nth = 2; Seen = 0 })   # 1er = lecture du tenant (etape 3), 2e = verification avant la premiere ecriture
$b33h3 = New-Base 'Z8c'; $allBases.Add($b33h3)
$rH3 = Invoke-Connector (Get-BaseParams $b33h3 @('Mail')) $b33h3
T 33 'M3 : jeton Graph expire (401) entre la confirmation et la premiere ecriture : « session Graph expiree ou presque », exit 1, AUCUNE ecriture, aucun connecteur' ($rH3.Exit -eq 1 -and $rH3.Console -match 'Session Graph expiree ou presque' -and $rH3.GraphWrites -eq 0 -and $rH3.CiwWrites -eq 0 -and @($global:MockCiw.Connectors).Count -eq 0) "exit=$($rH3.Exit) graph=$($rH3.GraphWrites) ciw=$($rH3.CiwWrites)"
Reset-MockState; $global:MockDcPolls = 0; $global:MockOpts.DeviceNoUpn = $true
$b33h4 = New-Base 'Z8d'; $allBases.Add($b33h4)
$rH4 = Invoke-Connector $pH $b33h4
T 33 'M3 : jeton du code d''appareil SANS upn (invite B2B : preferred_username seulement) : compte reconnu, exit 0' ($rH4.Exit -eq 0 -and $rH4.Console -notmatch 'ne correspond pas' -and (Get-MockConnector $ConnSrc)) "exit=$($rH4.Exit) $($rH4.Crash)"
$astG = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $pkg 'lib\graphauth.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in 'ConvertFrom-JwtPayload', 'Get-JwtAccount', 'Get-JwtExpiry') {
    $fd = $astG.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    . ([scriptblock]::Create($fd.Extent.Text))
}
$jb64 = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
$jwtG = (& $jb64 @{ alg = 'none' }) + '.' + (& $jb64 @{ unique_name = 'invite_ext#EXT#@contoso.onmicrosoft.com'; exp = 4102444800 }) + '.sig'
$clG = ConvertFrom-JwtPayload $jwtG
T 33 'M3 : Get-JwtAccount se rabat sur unique_name quand upn et preferred_username manquent ; Get-JwtExpiry lit exp (secondes epoch, UTC) et rend $null si absent' ((Get-JwtAccount $clG) -eq 'invite_ext#EXT#@contoso.onmicrosoft.com' -and (Get-JwtExpiry $clG) -eq [datetime]::new(2100, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc) -and $null -eq (Get-JwtExpiry ([pscustomobject]@{ tid = 'x' })) -and $null -eq (Get-JwtExpiry $null)) "compte=$(Get-JwtAccount $clG) exp=$(Get-JwtExpiry $clG)"

# --- 33i : M4 - la partie locale du compte de service commence TOUJOURS par svc-ciw- (adoption comprise) ---
foreach ($case in @(@{ N = 'admin'; Adopt = $false }, @{ N = 'jdoe@contoso.onmicrosoft.com'; Adopt = $false }, @{ N = 'jdoe'; Adopt = $true }, @{ N = 'Svc-Perso-1'; Adopt = $true })) {
    Reset-MockState
    $b33i = New-Base 'Z9'; $allBases.Add($b33i)
    $pI = Get-BaseParams $b33i @('Mail'); $pI['ServiceAccountName'] = $case.N; if ($case.Adopt) { $pI['AdoptExisting'] = $true }
    $rI = Invoke-Connector $pI $b33i
    T 33 "M4 : -ServiceAccountName '$($case.N)'$(if ($case.Adopt) { ' + -AdoptExisting' }) refuse (partie locale sans svc-ciw-) : exit 1 avant toute connexion, aucun utilisateur cree" ($rI.Exit -eq 1 -and $rI.Console -match 'svc-ciw-' -and $rI.Calls.Count -eq 0 -and @($global:MockTenant.Users).Count -eq 0) "exit=$($rI.Exit) appels=$($rI.Calls.Count)"
}
Reset-MockState
# --- 33j : M5 - removeKey avec reessais (10 / 20 / 30 s) ; cle deja absente = retiree ---
Reset-MockState
$b33j = New-Base 'ZA'; $allBases.Add($b33j)
$pJ = Get-BaseParams $b33j @('Mail')
$null = Invoke-Connector $pJ $b33j
$global:MockSleeps.Clear()
$global:MockOpts.GraphFail = @(@{ Method = 'POST'; Pattern = '/removeKey$'; Code = 400; Times = 2; ErrCode = 'Authentication_MissingOrMalformed'; Msg = 'Proof of possession token is not valid yet (propagation).' })
$rJ1 = Invoke-Connector $pJ $b33j
$global:MockOpts.GraphFail = @()
$rkCalls1 = @($rJ1.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'POST' -and $_.Path -match '/removeKey$' })
T 33 'M5 : removeKey en 400 Authentication_MissingOrMalformed deux fois puis succes : reessais apres 10 s puis 20 s, ancien certificat retire (1 seul), exit 0' ($rJ1.Exit -eq 0 -and $rkCalls1.Count -eq 3 -and (Get-MockSleepCount 10) -ge 1 -and (Get-MockSleepCount 20) -ge 1 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1) "exit=$($rJ1.Exit) appels=$($rkCalls1.Count) pauses=$($global:MockSleeps -join ',')"
$global:MockSleeps.Clear()
$global:MockOpts.GraphFail = @(@{ Method = 'POST'; Pattern = '/removeKey$'; Code = 400; Times = 20; ErrCode = 'Authentication_MissingOrMalformed'; Msg = 'Proof of possession token is not valid yet (propagation).' })
$rkJ2 = $global:MockTenant.RemovedKeys
$rJ2 = Invoke-Connector $pJ $b33j
$global:MockOpts.GraphFail = @()
$rkCalls2 = @($rJ2.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'POST' -and $_.Path -match '/removeKey$' })
T 33 'M5 : erreur de propagation persistante : 1 essai + 3 reessais (10, 20, 30 s), puis ECHEC non bloquant (exit 2), le nouveau certificat est en place, aucune cle retiree' ($rJ2.Exit -eq 2 -and $rkCalls2.Count -eq 4 -and (Get-MockSleepCount 10) -ge 1 -and (Get-MockSleepCount 20) -ge 1 -and (Get-MockSleepCount 30) -ge 1 -and $global:MockTenant.RemovedKeys -eq $rkJ2 -and (Test-ConnCoherence $ConnSrc $AppSrc) -eq '') "exit=$($rJ2.Exit) appels=$($rkCalls2.Count) pauses=$($global:MockSleeps -join ',')"
$global:MockOpts.OnWrite = { param($Method, $Path, $Body) if ($Method -eq 'POST' -and $Path -like '/applications/*/removeKey') { $aJ = @(Get-MockApp $AppSrc)[0]; $aJ.keyCredentials = @($aJ.keyCredentials | Where-Object { "$($_.keyId)" -ne "$($Body.keyId)" }) } }   # la cle disparait juste avant le retrait (retiree entre-temps)
$rJ3 = Invoke-Connector $pJ $b33j
$global:MockOpts.OnWrite = $null
T 33 'M5 : cle DEJA ABSENTE au moment de removeKey (« No credentials found ») = comptee comme retiree : exit 0, un seul certificat, mention « deja absente » dans le rapport' ($rJ3.Exit -eq 0 -and @(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count -eq 1 -and (Read-RunFile $rJ3 'Rapport-*.md') -match 'deja absente') "exit=$($rJ3.Exit) certs=$(@(Get-MockThumbs (@(Get-MockApp $AppSrc)[0])).Count)"

# --- 33k : M6 - PowerShell 7.2 minimum ---
$mainTxt33 = [System.IO.File]::ReadAllText($main); $pfTxt33 = [System.IO.File]::ReadAllText((Join-Path $pkg 'lib\preflight.ps1'))
$cmdTxt33 = [System.IO.File]::ReadAllText((Join-Path $pkg 'cloudiway-connector-launcher.ps1'))
T 33 'M6 : #Requires -Version 7.2 en tete du script principal ET controle de prerequis en FAIL sous 7.2 (message), le lanceur verifie la version' ($mainTxt33.TrimStart([char]0xFEFF) -match '^#Requires -Version 7\.2' -and $pfTxt33 -match "\[version\]'7\.2'" -and $pfTxt33 -match 'PowerShell 7\.2 minimum' -and $cmdTxt33 -match "\[version\]'7\.2'") 'exigence 7.2 absente'

# --- 33l : m1, m2, m9, m10, m11, m12, m13 ---
$entraTxt33 = [System.IO.File]::ReadAllText((Join-Path $pkg 'lib\entra.ps1'))
T 33 'm2 : plus d''ecriture de PFX temporaire cote Entra (Write-TempPfx, Remove-TempPfx, PfxTempPath absents de lib\entra.ps1 et du script principal)' ($entraTxt33 -notmatch 'Write-TempPfx|Remove-TempPfx|PfxTempPath' -and $mainTxt33 -notmatch 'Remove-TempPfx|PfxTempPath') 'residus'
T 33 'm9 : Set-StrictMode -Off en tete du script principal (avant toute fonction)' ($mainTxt33 -match '(?m)^Set-StrictMode -Off\s*$' -and $mainTxt33.IndexOf('Set-StrictMode -Off') -lt $mainTxt33.IndexOf('function Clear-RunSecrets')) 'Set-StrictMode -Off absent'
$niQ = Invoke-NonInteractive @('-Mode', 'Source', '-Tenant', 'contoso.onmicrosoft.com', '-Admin365', "o'brien@contoso.com", '-Workloads', 'Mail,OneDrive', '-SkipCloudiway', '-Yes')
T 33 'm10 : commande copiable affichee : valeurs entre apostrophes, apostrophe DOUBLEE (-Admin365 ''o''''brien@contoso.com''), -Tenant et -Workloads entre apostrophes' ($niQ.Exit -eq 1 -and $niQ.Out.Contains("-Admin365 'o''brien@contoso.com'") -and $niQ.Out.Contains("-Tenant 'contoso.onmicrosoft.com'") -and $niQ.Out.Contains("-Workloads 'Mail','OneDrive'")) "sortie=$($niQ.Out.Substring(0, [Math]::Min(500, $niQ.Out.Length)))"
$cmdExo = (Get-Content -LiteralPath (Join-Path $pkg 'lib\exchange.ps1') -Raw -Encoding utf8)
T 33 'm10 : commande Exchange manuelle : -UserPrincipalName entre apostrophes (source)' ($cmdExo -match "Connect-ExchangeOnline -UserPrincipalName '") 'commande Exchange non quotee'
# m11 : POST oauth2PermissionGrants « already exists » absorbe puis PATCH avec fusion des portees
Reset-MockState
$global:MockOpts.OnWrite = { param($Method, $Path, $Body)
    if ($Method -eq 'POST' -and $Path -eq '/oauth2PermissionGrants' -and -not $global:GrantSeeded) {
        $global:GrantSeeded = $true
        $global:MockTenant.Grants.Add(@{ id = [guid]::NewGuid().ToString(); clientId = $Body.clientId; consentType = 'AllPrincipals'; resourceId = $Body.resourceId; scope = 'User.Read' })   # octroi cree entre la lecture et l'ecriture
    }
}
$global:GrantSeeded = $false
$b33m = New-Base 'ZB'; $allBases.Add($b33m)
$rM = Invoke-Connector (Get-BaseParams $b33m @('Mail', 'OneDrive')) $b33m
$global:MockOpts.OnWrite = $null
T 33 'm11 : POST oauth2PermissionGrants « already exists » (octroi cree entre-temps) : absorbe, relecture puis PATCH avec fusion des portees, consentement complet, exit 0' ($rM.Exit -eq 0 -and $global:GrantSeeded -and (Get-ConsentGaps $AppSrc).Count -eq 0 -and @($rM.Calls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -eq 'PATCH' -and $_.Path -like '/oauth2PermissionGrants/*' }).Count -ge 1) "exit=$($rM.Exit) manques=$((Get-ConsentGaps $AppSrc) -join ';') $($rM.Crash)"
# m12 : ConsistencyLevel eventual uniquement sur les GET
$hdrs = @($global:MockGraphHeaders)
T 33 'm12 : ConsistencyLevel: eventual present sur les lectures (GET) et ABSENT de tout POST / PATCH' (@($hdrs | Where-Object { $_.Method -eq 'GET' -and $_.Consistency -eq 'eventual' }).Count -ge 5 -and @($hdrs | Where-Object { $_.Method -eq 'GET' -and $_.Consistency -ne 'eventual' }).Count -eq 0 -and @($hdrs | Where-Object { $_.Method -ne 'GET' }).Count -ge 5 -and @($hdrs | Where-Object { $_.Method -ne 'GET' -and $_.Consistency }).Count -eq 0) "GET=$(@($hdrs | Where-Object Method -EQ 'GET').Count) ecritures=$(@($hdrs | Where-Object { $_.Method -ne 'GET' }).Count) avec en-tete=$(@($hdrs | Where-Object { $_.Method -ne 'GET' -and $_.Consistency }).Count)"

# POINT 11 (suite) : balayage des secrets (v2 : AUCUNE valeur sensible dans un fichier ni dans la console)
# ===================================================================================================
$secretValues = @($allSecretValues | Where-Object { $_ } | Sort-Object -Unique)
$leaks = [System.Collections.Generic.List[string]]::new()
$nFiles = 0
foreach ($base in $allBases) {
    foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File -ErrorAction SilentlyContinue)) {
        $nFiles++
        $txt = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8 -ErrorAction SilentlyContinue
        if (-not $txt) { continue }
        foreach ($sv in $secretValues) { if ($txt.Contains($sv)) { $leaks.Add("secret dans $($f.FullName.Substring($tmpRoot.Length))") } }
    }
}
T 11 "ni PAT, ni mot de passe Cloudiway, ni mot de passe PFX / compte de service / secret client / contenu PFX dans run.log, Rapport ou decouverte ($nFiles fichiers, $($secretValues.Count) valeurs)" ($leaks.Count -eq 0 -and $nFiles -gt 20) ($leaks -join ' ; ')
$leakC = @()
foreach ($c in $allConsoles) {
    foreach ($sv in $secretValues) { if ($c.Contains($sv)) { $leakC += $(if ($sv.Length -gt 12) { $sv.Substring(0, 6) + '...' } else { $sv }) } }
    foreach ($sv in 'seed-client-secret-seed', 'seed-svc-pass-seed', 'seed-pfx-secret-seed') { if ($c.Contains($sv)) { $leakC += $sv } }
}
T 11 'ni PAT, ni mot de passe Cloudiway, ni identifiant genere dans la sortie console capturee (tous les passages)' ($leakC.Count -eq 0) (($leakC | Select-Object -Unique) -join ', ')
$sensFiles = @($allBases | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.pfx' -or $_.Name -like '*.secret.json' -or $_.Name -like 'etat-*.json' -or $_.Name -like '*.cer' } })
T 11 'aucun .pfx / .secret.json / etat-*.json / .cer produit sur l''ensemble des scenarios (v2)' ($sensFiles.Count -eq 0) (($sensFiles | ForEach-Object Name) -join ', ')
T 11 'aucun PFX temporaire oublie dans %TEMP% (transport Path)' ((Get-TempPfx).Count -eq 0) ((Get-TempPfx) -join ', ')
$reportLeak = @()
foreach ($base in $allBases) { foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File -Filter 'Rapport-*.md' -ErrorAction SilentlyContinue)) { $t = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8; if ($t -match 'MOCKJWT|BEGIN |MIIK|MockSecret~') { $reportLeak += $f.Name } } }
T 11 'rapports : aucun jeton, contenu de certificat ni secret client' ($reportLeak.Count -eq 0) ($reportLeak -join ', ')

# ===================================================================================================
# POINT 12 : aucune requete DELETE (tous scenarios) + sources
# ===================================================================================================
$del = @($global:MockAllCalls | Where-Object { $_.Method -in 'DELETE', 'PUT-DELETE' })
$nonContract = @($global:MockAllCalls | Where-Object { $_.Kind -eq 'Graph' -and $_.Method -notin 'GET', 'POST', 'PATCH' })
T 12 'aucune requete DELETE (Graph ni Cloudiway) sur l''ensemble des scenarios' ($del.Count -eq 0) "DELETE=$($del.Count)"
T 12 'Graph : uniquement GET/POST/PATCH' ($nonContract.Count -eq 0) "hors contrat=$($nonContract.Count)"
T 12 'Graph : uniquement graph.microsoft.com, Cloudiway : uniquement api-production.cloudiway.com, Entra : uniquement la metadonnee publique' (@($global:MockAllCalls | Where-Object { $_.Status -eq 'HOST-INTERDIT' }).Count -eq 0) 'hote non autorise appele'
$srcDel = @(Select-String -Path (Join-Path $pkg 'cloudiway-connector.ps1'), (Join-Path $pkg 'lib\*.ps1') -Pattern '\bDELETE\b|\bRemove-(Mg|Az|Item)\b' -CaseSensitive -ErrorAction SilentlyContinue | Where-Object { $_.Line -notmatch '^\s*#' })
T 12 'sources : aucun DELETE / Remove-Mg / Remove-Az / Remove-Item hors commentaires' ($srcDel.Count -eq 0) (($srcDel | ForEach-Object { "$($_.Path | Split-Path -Leaf):$($_.LineNumber)" }) -join ', ')
# Exception documentee : le SEUL retrait autorise est le nettoyage des anciens identifiants de l'outil
# (POST removeKey et POST removePassword ; PATCH keyCredentials seulement pour l'ajout), tous dans lib\entra.ps1. Ni DELETE HTTP, ni Remove-* generique, ni methode Delete.
$srcFiles = @((Join-Path $pkg 'cloudiway-connector.ps1')) + @(Get-ChildItem -LiteralPath (Join-Path $pkg 'lib') -Filter '*.ps1' -File | ForEach-Object FullName)
$srcCode = foreach ($sf in $srcFiles) { $ln = 0; foreach ($l in [System.IO.File]::ReadAllLines($sf)) { $ln++; if ($l -notmatch '^\s*#') { [pscustomobject]@{ File = (Split-Path -Leaf $sf); Line = $ln; Text = $l } } } }
$genericRemove = @($srcCode | Where-Object { $_.Text -cmatch '\bRemove-(?!TempPfx\b|CiwTempFiles\b)[A-Za-z]+' })
$httpDelete = @($srcCode | Where-Object { $_.Text -match "(?i)-Method\s+['""]?Delete|Invoke-Graph(Delete|Remove)|HttpMethod\]::Delete|\.Delete\s*\(\s*['""]" })
T 12 'sources : aucun Remove-* generique (seuls Remove-TempPfx / Remove-CiwTempFiles, fichiers temporaires locaux), aucune methode HTTP Delete' ($genericRemove.Count -eq 0 -and $httpDelete.Count -eq 0) ((@($genericRemove) + @($httpDelete) | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ')
$rmPwd = @($srcCode | Where-Object { $_.Text -match 'removePassword' })
$patchKeys = @($srcCode | Where-Object { $_.Text -match 'Invoke-GraphPatch' -and $_.Text -match 'keyCredentials' })
$rmKey = @($srcCode | Where-Object { $_.Text -match 'removeKey' })
T 12 'sources : seuls removeKey (certificats) et removePassword (secrets) retirent des identifiants, UNIQUEMENT dans lib\entra.ps1 (1 appel POST chacun) ; PATCH keyCredentials UNIQUEMENT pour l''AJOUT du nouveau certificat (2 appels dans lib\entra.ps1 : l''ajout et le repli de nettoyage si removeKey est refuse en 403)' ($rmPwd.Count -ge 1 -and @($rmPwd | Where-Object { $_.File -ne 'entra.ps1' }).Count -eq 0 -and @($rmPwd | Where-Object { $_.Text -match 'Invoke-GraphPost' }).Count -eq 1 -and $rmKey.Count -ge 1 -and @($rmKey | Where-Object { $_.File -ne 'entra.ps1' }).Count -eq 0 -and @($rmKey | Where-Object { $_.Text -match 'Invoke-GraphPost' }).Count -eq 1 -and $patchKeys.Count -eq 2 -and @($patchKeys | Where-Object { $_.Text -notmatch 'keyCredentials = (\$keepArr|@\(\$entry\))' }).Count -eq 0 -and @($patchKeys | Where-Object { $_.File -ne 'entra.ps1' }).Count -eq 0) "removePassword=$($rmPwd.Count) patchKeys=$($patchKeys.Count) : $((@($rmPwd) + @($patchKeys) | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', ')"
$writesGraph = @($global:MockAllCalls | Where-Object { $_.Kind -eq 'Graph' -and $_.IsWrite -and $_.Status -eq 'OK' })
$removalCalls = @($writesGraph | Where-Object { ($_.Method -eq 'POST' -and $_.Path -match '(removePassword|removeKey)$') })
T 12 'execution : les seuls POST de retrait vus sur l''ensemble des scenarios sont /applications/{id}/removePassword et /applications/{id}/removeKey (aucun autre chemin de suppression)' (@($removalCalls | Where-Object { $_.Path -notmatch '^/applications/[^/]+/(removePassword|removeKey)$' }).Count -eq 0 -and @($removalCalls | Where-Object { $_.Path -match 'removeKey$' }).Count -ge 1 -and @($removalCalls | Where-Object { $_.Path -match 'removePassword$' }).Count -ge 1) "retraits=$($removalCalls.Count)"
$srcOld = @(Select-String -Path (Join-Path $pkg 'cloudiway-connector.ps1'), (Join-Path $pkg 'lib\*.ps1') -Pattern 'Save-ConnectorSecrets|\.secret\.json|etat-\$|CertValidityDays\s*=|\$script:Ctx\.Secrets|Created\.PfxPath' -ErrorAction SilentlyContinue | Where-Object { $_.Line -notmatch '^\s*#' })
T 12 'sources : plus de trace du contrat v1 (Save-ConnectorSecrets, .secret.json, Ctx.Secrets, Created.PfxPath)' ($srcOld.Count -eq 0) (($srcOld | ForEach-Object { "$($_.Path | Split-Path -Leaf):$($_.LineNumber) $($_.Line.Trim())" }) -join ' | ')

# ===================================================================================================
# POINT 24 : qualite des sources (syntaxe, BOM, emojis)
# ===================================================================================================
$allPs1 = @(Get-ChildItem -LiteralPath $pkg -Recurse -File -Filter '*.ps1')
$parseErr = @()
foreach ($f in $allPs1) { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e); if ($e.Count) { $parseErr += "$($f.Name):$($e.Count)" } }
T 24 "ParseFile : 0 erreur sur les $($allPs1.Count) scripts du package" ($parseErr.Count -eq 0 -and $allPs1.Count -ge 9) ($parseErr -join ', ')
$noBom = @($allPs1 | Where-Object { $b = [System.IO.File]::ReadAllBytes($_.FullName); -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) } | ForEach-Object Name)
T 24 'tous les .ps1 sont en UTF-8 avec BOM' ($noBom.Count -eq 0) ($noBom -join ', ')
$emoji = @()
foreach ($f in @(Get-ChildItem -LiteralPath $pkg -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.md' })) {
    $txt = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($ch in $txt.EnumerateRunes()) { if (($ch.Value -ge 0x2600 -and $ch.Value -le 0x27BF) -or ($ch.Value -ge 0x1F000) -or $ch.Value -eq 0x2705 -or $ch.Value -eq 0x274C) { $emoji += "$($f.Name):U+$('{0:X}' -f $ch.Value)"; break } }
}
T 24 'aucun emoji dans les .ps1 / .md du package' ($emoji.Count -eq 0) ($emoji -join ', ')

# ===================================================================================================
# Rapport
# ===================================================================================================
Say ''
Say '================================================================================'
Say ' BANC DE TEST HORS LIGNE - CloudiwayConnector v2.4'
Say '================================================================================'
$labels = [ordered]@{
    '1' = 'Premier passage Source (Mail + OneDrive)'; '2' = 'Second passage identique : zero ecriture'; '3' = '-WhatIf'
    '5' = 'Non Global Administrator'; '6' = 'Tenant / compte different'; '7' = 'Portail Cloudiway inaccessible'
    '10' = '-RotateCredentials'; '11' = 'Secrets'
    '12' = 'Aucun DELETE'; '13' = 'Mode questions'; '14' = '-Discover'; '15' = '-Workloads en une chaine'
    '16' = 'Noms codifies / projet detecte / redirections'; '17' = 'Identifiants en memoire (aucun fichier)'; '18' = 'Renouvellement automatique'
    '19' = 'AuthMethod Secret / Both'; '21' = '-SkipCloudiway / echec Cloudiway puis relance'
    '22' = 'Connexion Cloudiway (jeton, cookie, PAT, projets)'; '23' = 'Resolution du tenant / adresses'; '24' = 'Qualite des sources'; 'B' = 'Bonus (robustesse)'
    '25' = 'V2.1 flux Cloudiway (PUT, adoption, jeton, ordre, collisions, 2FA)'; '26' = 'V2.1 Graph (propagation, keyCredentials, plateforme, policies, MFA)'
    '27' = 'V2.1 mineurs (secrets, validite, noms, horloge, encodage)'; '28' = 'V2.1 documentation, lanceur, conseils'
    '29' = 'Un seul certificat / secret actif (nettoyage apres le connecteur)'; '30' = 'Parametres : questions, manquants, aide Get-Help'
    '31' = 'V2.2 prochaines actions (A faire / A verifier), Exchange EWS, version, affichage'
    '32' = 'V2.3 removeKey (preuve de possession), renouvellement par defaut, -KeepCredentials'
    '33' = 'V2.4 fileName = marqueur, relecture apres ecriture, session Graph, svc-ciw-, removeKey avec reessais, banc fidele'
}
$fails = 0
foreach ($k in $labels.Keys) {
    $rs = @($Results | Where-Object { "$($_.Point)" -eq $k })
    $nf = @($rs | Where-Object Result -EQ 'FAIL').Count; $ns = @($rs | Where-Object Result -EQ 'SKIP').Count; $np = @($rs | Where-Object Result -EQ 'PASS').Count
    $fails += $nf
    $verdict = if ($rs.Count -eq 0) { 'N/A ' } elseif ($nf -gt 0) { 'FAIL' } elseif ($ns -gt 0 -and $np -eq 0) { 'SKIP' } else { 'PASS' }
    $col = switch ($verdict) { 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'Green' } }
    Say ("[{0}] {1,-3} {2,-52} {3} pass / {4} fail / {5} skip" -f $verdict, $k, $labels[$k], $np, $nf, $ns) $col
}
Say ''
Say 'DETAIL'
foreach ($r in $Results) {
    $col = switch ($r.Result) { 'FAIL' { 'Red' } 'SKIP' { 'Yellow' } default { 'DarkGray' } }
    Say ("  {0} [{1,-3}] {2}" -f $r.Result, $r.Point, $r.Test) $col
    if ($r.Result -ne 'PASS' -and $r.Detail) { Say ("         -> {0}" -f $r.Detail) $col }
}
Say ''
Say ("TOTAL : {0} PASS, {1} FAIL, {2} SKIP" -f @($Results | ? Result -EQ 'PASS').Count, $fails, @($Results | ? Result -EQ 'SKIP').Count) $(if ($fails) { 'Red' } else { 'Green' })

if ($KeepOutput) { Say "Sorties conservees dans : $tmpRoot" } else { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($ResultFile) { [System.IO.File]::WriteAllText($ResultFile, $report.ToString(), [System.Text.UTF8Encoding]::new($false)) }
exit $fails
