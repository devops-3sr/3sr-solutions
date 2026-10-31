#Requires -Version 7.0

<#
.SYNOPSIS
    Collecte LECTURE SEULE d'un tenant Microsoft 365 : donnees brutes (CSV et JSON), sans aucun calcul.

.DESCRIPTION
    A lancer par un administrateur du tenant, dans une console pwsh (PowerShell 7).
    - Aucune commande d'ecriture sur le tenant : uniquement des lectures (Get-*, requetes Graph GET).
    - Aucune lecture de contenu (mails, fichiers, messages Teams) : metadonnees, tailles et comptages.
    - Aucun jeton ni mot de passe ecrit ou affiche. Aucun envoi : les fichiers restent sur le poste.
    - Sortie : un dossier de CSV (separateur ';', UTF-8 avec BOM) + un fichier .zip a transmettre a votre contact 3SR.
    Trois fenetres de connexion s'ouvrent successivement (Graph, SharePoint, Exchange). Les deux dernieres s'ouvrent
    automatiquement apres un decompte de 10 secondes (constante $WorkerCountdownSeconds en haut du script) : aucune validation n'est attendue.
    Modules requis : Microsoft.Graph.Authentication, ExchangeOnlineManagement, Microsoft.Online.SharePoint.PowerShell.

    ROLES SOURCE / CIBLE (option -Role)
    - Source (defaut) : tenant a migrer, volumetries completes. Collecte en plus : statistiques de boites et archives, permissions,
      listes de distribution avec membres, contacts, invites, nombre de membres des groupes, canaux Teams, rapports d'usage,
      OneDrive et sites avec tailles.
    - Target : tenant de destination, collecte allegee pour detecter les conflits : liste legere des boites, tous les destinataires
      (recipients.csv), URL et titres de sites sans tailles ni OneDrive.
    - Commun aux deux roles : identites, licences, groupes, domaines, postes, securite, DNS, flux de messagerie, EWS.

.PARAMETER TenantId
    GUID du tenant a collecter (obligatoire).
.PARAMETER User
    UPN du compte administrateur qui doit se connecter (obligatoire). Toute autre identite est refusee.
.PARAMETER Role
    Source (defaut) : tenant a migrer, volumetries completes. Target : tenant de destination, conflits et securite, sans
    volumetries detaillees (voir ROLES SOURCE / CIBLE dans la description). Le role choisi est rappele dans la banniere.
.PARAMETER Parts
    Identity, Devices, Security, Dns, Exchange, SharePoint (defaut : tout).
    ATTENTION : pour passer plusieurs parties, utiliser
    pwsh -NoProfile -Command "& '.\cloudiway-collector.ps1' -Parts Exchange,SharePoint -TenantId <GUID> -User <UPN> -OutDir '<dossier existant>'"
    (la syntaxe -File ne gere pas les tableaux).
.PARAMETER OutDir
    Dossier de sortie (defaut : .\collecte-resultats a cote du script). Si ce dossier est une collecte existante
    (contient tenant.csv), elle est reprise : seules les parties demandees sont relancees et capabilities.csv est fusionne.
.PARAMETER InstallMissingModules
    Installe les modules manquants (scope utilisateur courant) sans poser de question.
.EXAMPLE
    pwsh -NoProfile -File .\cloudiway-collector.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com
    Collecte complete d'un tenant SOURCE (role par defaut).
.EXAMPLE
    pwsh -NoProfile -File .\cloudiway-collector.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com -Role Target
    Collecte allegee d'un tenant CIBLE.
#>
[CmdletBinding(DefaultParameterSetName = 'Main')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Main')]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory, ParameterSetName = 'Main')]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$User,

    [ValidateSet('Source', 'Target')][string]$Role = 'Source',

    [ValidateSet('Identity', 'Devices', 'Security', 'Dns', 'Exchange', 'SharePoint')]
    [string[]]$Parts = @('Identity', 'Devices', 'Security', 'Dns', 'Exchange', 'SharePoint'),

    [string]$OutDir,
    [switch]$InstallMissingModules,

    # --- usage interne (processus enfants) : ne pas renseigner a la main ---
    [Parameter(Mandatory, ParameterSetName = 'Worker')][ValidateSet('Exchange', 'SharePoint')][string]$Worker,
    [Parameter(Mandatory, ParameterSetName = 'Worker')][string]$ContextFile
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'   # rien d'autre que nos propres messages a l'ecran (les vrais problemes remontent via Add-Cap)
# Decompte (en secondes) affiche avant l'ouverture automatique de chaque fenetre de connexion Exchange / SharePoint (aucune attente de validation).
$WorkerCountdownSeconds = 10
$ScriptStart = Get-Date
$SelfPath = $PSCommandPath
$LibDir = Join-Path $PSScriptRoot 'lib'
$IsWorker = ($PSCmdlet.ParameterSetName -eq 'Worker')

# Le module Exchange perd les dates dont le jour est > 12 en culture fr-FR : culture forcee pour tout le processus worker Exchange.
if ($IsWorker -and $Worker -eq 'Exchange') {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]'en-US'
    [cultureinfo]::DefaultThreadCurrentCulture = [cultureinfo]'en-US'
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = [cultureinfo]'en-US'
    [cultureinfo]::DefaultThreadCurrentUICulture = [cultureinfo]'en-US'
}

# --- Chargement des bibliotheques (au niveau script : les fonctions restent visibles de tout le script) ---------
$PartLib = [ordered]@{
    Identity   = @{ File = 'collect-identity.ps1'; Fn = 'Invoke-IdentityCollection' }
    Devices    = @{ File = 'collect-devices.ps1'; Fn = 'Invoke-DevicesCollection' }
    Security   = @{ File = 'collect-security.ps1'; Fn = 'Invoke-SecurityCollection' }
    Dns        = @{ File = 'collect-dns.ps1'; Fn = 'Invoke-DnsCollection' }
    Exchange   = @{ File = 'collect-exchange.ps1'; Fn = 'Invoke-ExchangeCollection' }
    SharePoint = @{ File = 'collect-sharepoint.ps1'; Fn = 'Invoke-SharePointCollection' }
}
$CanonicalParts = @($PartLib.Keys)
$wanted = if ($IsWorker) { @($Worker) } else { @($CanonicalParts | Where-Object { $_ -in $Parts }) }
$libFiles = @('common.ps1', 'ui.ps1', 'preflight.ps1') + @($wanted | ForEach-Object { $PartLib[$_].File })
$missingLibs = @($libFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LibDir $_)) })
if ($missingLibs.Count -gt 0) {
    Write-Host "Fichier(s) manquant(s) dans '$LibDir' : $($missingLibs -join ', ')" -ForegroundColor Red
    Write-Host "Le package est incomplet : le dossier 'lib' doit rester a cote de cloudiway-collector.ps1. Recopier le package complet." -ForegroundColor Yellow
    exit 1
}
foreach ($lf in $libFiles) { . (Join-Path $LibDir $lf) }
$ScriptVersion = if ($script:AppVersion) { [string]$script:AppVersion } else { '1.2' }

$script:Ctx = @{
    TenantId = $null; User = $null; Role = $Role; IsSource = ($Role -eq 'Source'); InitialDomain = $null; Out = $null
    Capabilities = [System.Collections.Generic.List[object]]::new()
}

# ====================================================================================================
# MODE WORKER (processus enfant Exchange ou SharePoint)
# ====================================================================================================
if ($IsWorker) {
    $code = 0
    try {
        $j = Get-Content -LiteralPath $ContextFile -Raw -Encoding utf8 | ConvertFrom-Json
        $script:Ctx.TenantId = "$($j.TenantId)"
        $script:Ctx.User = "$($j.User)"
        $script:Ctx.Role = "$($j.Role)"
        $script:Ctx.IsSource = ($script:Ctx.Role -eq 'Source')
        $script:Ctx.InitialDomain = "$($j.InitialDomain)"
        $script:Ctx.Out = "$($j.Out)"
        if (-not (Test-Path -LiteralPath $script:Ctx.Out)) { throw "Dossier de sortie introuvable : $($script:Ctx.Out)" }
        $fn = $PartLib[$Worker].Fn
        if (-not (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { throw "Fonction $fn introuvable" }
        Write-Log "=== $Worker : processus separe (domaine $($script:Ctx.InitialDomain)) ===" 'Cyan'
        & $fn | Out-Null
    } catch {
        $code = 1
        if ($script:Ctx.Out) { Add-Cap $Worker 'Processus' 'KO' ("Erreur inattendue : " + (Get-ErrMsg $_)) }
        else { Write-Host ("Worker $Worker : " + $_.Exception.Message) -ForegroundColor Red }
    } finally {
        if ($script:Ctx.Out -and (Test-Path -LiteralPath $script:Ctx.Out)) {
            try { Save-Capabilities $Worker } catch { Write-Host "Ecriture des capacites impossible : $($_.Exception.Message)" -ForegroundColor Red }
        }
    }
    exit $code
}

# ====================================================================================================
# MODE PRINCIPAL
# ====================================================================================================
$TenantId = $TenantId.ToLowerInvariant()
$Parts = @($CanonicalParts | Where-Object { $_ -in $Parts })
$GraphParts = @($Parts | Where-Object { $_ -in 'Identity', 'Devices', 'Security', 'Dns' })
$ChildParts = @($Parts | Where-Object { $_ -in 'Exchange', 'SharePoint' })
$ShortId = $TenantId.Substring(0, 8)


Initialize-UI

# --- Dossier de sortie (idempotent : un tenant = un dossier, mis a jour a chaque lancement) ---
$OutBase = if ($OutDir) { [System.IO.Path]::GetFullPath($OutDir, (Get-Location).ProviderPath) } else { Join-Path $PSScriptRoot 'collecte-resultats' }
$Resume = $false
$ResumeInitial = $null
$FullRun = (@($CanonicalParts | Where-Object { $_ -notin $Parts }).Count -eq 0)
$ZipDir = $OutBase
$OtherTenantDir = $false
function Get-PriorTenant([string]$Dir) {
    try { return @(Import-Csv -LiteralPath (Join-Path $Dir 'tenant.csv') -Delimiter ';')[0] } catch { return $null }
}
if (Test-Path -LiteralPath (Join-Path $OutBase 'tenant.csv')) {
    # -OutDir designe directement un dossier de collecte existant
    $Out = $OutBase
    $ZipDir = Split-Path -Parent $Out
} else {
    $Out = Join-Path $OutBase $ShortId
}
if (Test-Path -LiteralPath (Join-Path $Out 'tenant.csv')) {
    $prev = Get-PriorTenant $Out
    if (-not $prev -or "$($prev.TenantId)".ToLowerInvariant() -ne $TenantId) { $OtherTenantDir = $true }
    else {
        $Resume = $true
        $ResumeInitial = "$($prev.InitialDomain)"
    }
}

# --- Quelles parties exigent Graph ? ---
$NeedGraph = ($GraphParts.Count -gt 0) -or ((-not $Resume) -and ($ChildParts.Count -gt 0))

Show-Banner -Role $Role -TenantId $TenantId -User $User -OutDir $Out -RoleExplicit:($PSBoundParameters.ContainsKey('Role'))
Show-Usage

if ($OtherTenantDir) {
    Write-Status FAIL "Le dossier '$Out' contient une collecte d'un autre tenant (ou un tenant.csv illisible)." 'Arret.'
    exit 1
}
if (-not $NeedGraph -and -not $Resume) {
    Write-Status FAIL 'Rien a collecter : aucune partie demandee.' '(voir -Parts)'
    exit 1
}
if (-not $NeedGraph -and $ChildParts.Count -gt 0 -and -not $ResumeInitial) {
    Write-Status FAIL 'tenant.csv ne contient pas InitialDomain.' 'Relancer avec au moins une partie Graph (Identity) pour le determiner.'
    exit 1
}

# ====================================================================================================
# [1/4] Prerequis du poste (aucune connexion tant que tout n'est pas en ordre)
# ====================================================================================================
Write-Section 1 4 'Prerequis du poste'
$pf = Invoke-LocalPreflight -Parts $Parts -OutBase $OutBase -InstallMissingModules:$InstallMissingModules -NoGraph:(-not $NeedGraph)
Write-CheckTable $pf.Rows
foreach ($r in @($pf.Rows | Where-Object { $_.Status -in 'FAIL', 'WARN' -and $_.Impact })) { Write-Hint ("{0} : {1}" -f $r.Name, $r.Impact) }
if (-not $pf.Ok) {
    Write-Host ''
    Write-Status FAIL 'Des prerequis manquent : la collecte ne peut pas demarrer.' 'Aucune connexion n''a ete tentee.'
    # Commandes d'installation sur UNE ligne (jamais coupees, pour pouvoir etre copiees)
    $installCmds = @($pf.Rows | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object {
            if ("$($_.Impact) $($_.Detail)" -match 'Install-Module -Name \S+ -Scope (CurrentUser|AllUsers) -Force -AllowClobber') { $Matches[0] }
        } | Select-Object -Unique)
    if ($pf.NeedsAdmin) {
        Write-Status WARN 'Des droits administrateur du poste sont necessaires pour installer un module.'
        Write-Hint 'Ouvrir PowerShell 7 en tant qu''administrateur (clic droit, Executer en tant qu''administrateur), executer la commande ci-dessous, puis relancer la collecte :'
    } elseif ($installCmds.Count -gt 0) {
        Write-Hint 'Pour installer vous-meme (dans PowerShell 7, sans droits administrateur), puis relancer la collecte :'
    }
    foreach ($c in $installCmds) { Write-ConsolePart ("    " + $c) 'Cyan' }
    exit 1
}
Write-Status OK 'Prerequis du poste valides.'

# --- Dossier de sortie et contexte ---
try { New-Item -ItemType Directory -Force -Path $Out | Out-Null } catch { Write-Status FAIL "Impossible de creer '$Out'" $_.Exception.Message; exit 1 }
$script:Ctx.TenantId = $TenantId
$script:Ctx.User = $User
$script:Ctx.InitialDomain = $ResumeInitial
$script:Ctx.Out = $Out

# Capacites d'une collecte precedente (reprise) : seules les lignes des parties NON relancees sont conservees.
$PriorCaps = @()
$capFile = Join-Path $Out 'capabilities.csv'
if ($Resume -and -not $FullRun -and (Test-Path -LiteralPath $capFile)) {
    try { $PriorCaps = @(Import-Csv -LiteralPath $capFile -Delimiter ';' | Where-Object { $_.Part -notin $Parts }) } catch { $PriorCaps = @() }
}

Write-Log ("Debut collecte v{0}. Role={1} Parts={2} Out={3}{4}" -f $ScriptVersion, $Role, ($Parts -join ','), $Out, $(if ($Resume -and $FullRun) { ' (mise a jour complete d''une collecte existante)' } elseif ($Resume) { ' (mise a jour partielle)' } else { '' })) 'Cyan'

function Save-MergedCapabilities {
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $PriorCaps) { $all.Add($r) }
    foreach ($r in $script:Ctx.Capabilities) { $all.Add($r) }
    try { Save-Csv @($all) 'capabilities.csv' }
    catch { Write-Host 'Fichier verrouille : fermez Excel puis relancez (capabilities.csv non ecrit, la collecte continue).' -ForegroundColor Red }
    return $all
}

function Invoke-CollectPart([string]$Part) {
    $fn = $PartLib[$Part].Fn
    Write-Log "=== $Part ===" 'Cyan'
    try {
        if (-not (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) { throw "Fonction $fn introuvable" }
        & $fn | Out-Null
    } catch { Add-Cap $Part 'Collecte' 'KO' ("Erreur inattendue : " + (Get-ErrMsg $_)) }
}

# Decompte visible avant l'ouverture automatique d'une fenetre de connexion (on n'attend pas de validation du client).
# Console interactive : compteur mis a jour sur la meme ligne ; sortie redirigee : lignes simples (debut, mi-parcours). Meme duree dans les deux cas.
function Wait-WorkerCountdown([string]$Part) {
    $n = [Math]::Max(0, [int]$WorkerCountdownSeconds)
    $label = if ($Part -eq 'Exchange') { 'Exchange Online' } else { $Part }
    $live = $false
    try { $live = -not [Console]::IsOutputRedirected } catch { $live = $false }
    $width = 80
    try { $width = [int](Get-UIState).Width } catch { }
    if ($n -le 0) { return }
    if ($live) {
        for ($s = $n; $s -ge 1; $s--) {
            $txt = "  Une nouvelle fenetre de connexion ($label) va s'ouvrir dans $s s..."
            if ($txt.Length -gt $width - 1) { $txt = "  Connexion ($label) dans $s s..." }
            Write-UIText ("`r" + $txt.PadRight([Math]::Min($width - 1, 90))) 'Yellow' -NoNewline
            Start-Sleep -Seconds 1
        }
        Write-UIText ("`r" + (' ' * [Math]::Min($width - 1, 90)) + "`r") '' -NoNewline
        Write-UIText "  Ouverture de la fenetre de connexion ($label) : y repondre dans les 2 minutes." 'Yellow'
    } else {
        Write-UIText "  Une nouvelle fenetre de connexion ($label) va s'ouvrir dans $n s..." 'Yellow'
        for ($s = $n; $s -ge 1; $s--) {
            if ($s -eq [int]($n / 2) -and $s -lt $n) { Write-UIText "  ... $s s" 'Yellow' }
            Start-Sleep -Seconds 1
        }
        Write-UIText "  Ouverture de la fenetre de connexion ($label) : y repondre dans les 2 minutes." 'Yellow'
    }
}

function Start-CollectWorker([string]$Part, [string]$CtxFile) {
    $cf = Join-Path $script:Ctx.Out ("capabilities-{0}.csv" -f $Part)
    if (Test-Path -LiteralPath $cf) { Remove-Item -LiteralPath $cf -Force }
    # Executable courant (pas 'pwsh' via le PATH) et politique d'execution du processus heritee (package recu par zip).
    $pwshExe = (Get-Process -Id $PID).Path
    # Point d'injection pour le banc de test hors ligne : une fonction 'pwsh' definie dans la session remplace le processus reel.
    if ($env:CLOUDIWAY_TESTS -eq '1' -and (Get-Command pwsh -CommandType Function -ErrorAction SilentlyContinue)) { $pwshExe = 'pwsh' }
    $workerArgs = @('-NoProfile')
    $ep = "$(Get-ExecutionPolicy -Scope Process)"
    if ($ep -and $ep -ne 'Undefined') { $workerArgs += @('-ExecutionPolicy', $ep) }
    $workerArgs += @('-File', $SelfPath, '-Worker', $Part, '-ContextFile', $CtxFile)
    $workerExit = $null
    try {
        Wait-WorkerCountdown $Part
        & $pwshExe @workerArgs | Out-Host
        $workerExit = $LASTEXITCODE
    } catch { Add-Cap $Part 'Processus' 'KO' ("Lancement impossible : " + (Get-ErrMsg $_)) }
    if (Test-Path -LiteralPath $cf) {
        try {
            Import-Csv -LiteralPath $cf -Delimiter ';' | ForEach-Object { $script:Ctx.Capabilities.Add($_) }
        } catch { Add-Cap $Part 'Processus' 'KO' ("Capacites illisibles : " + (Get-ErrMsg $_)) }
        Remove-Item -LiteralPath $cf -Force
    } else {
        Add-Cap $Part 'Processus' 'KO' ("Le processus enfant n'a produit aucun resultat (code de sortie : {0}). Causes possibles : connexion annulee ou fenetre expiree, script bloque (Unblock-File / politique d'execution), module absent ou trop ancien. Voir la console et run.log." -f $(if ($null -eq $workerExit) { 'inconnu' } else { $workerExit }))
    }
    if ($null -ne $workerExit) { Add-Cap $Part 'CodeSortieWorker' $(if ($workerExit -eq 0) { 'OK' } else { 'PARTIEL' }) "code $workerExit" }
}

# Statut affiche a l'ecran ET trace dans run.log
function Write-StatusLog([string]$Level, [string]$Text, [string]$Detail = '') {
    Write-Status $Level $Text $Detail
    Write-RunLogLine ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2} {3}' -f (Get-Date), $Level, $Text, $Detail)
}

# ====================================================================================================
# [2/4] Connexion Graph, garde-fous tenant / compte, puis test des acces AVANT toute collecte
# ====================================================================================================
Write-Section 2 4 'Connexions et droits'
$GraphConnected = $false
if ($NeedGraph) {
    Write-StatusLog WAIT 'Connexion Microsoft Graph (lecture seule) : une fenetre de connexion va s''ouvrir.' "compte attendu : $User"
    try {
        Import-Module Microsoft.Graph.Authentication -WarningAction SilentlyContinue -ErrorAction Stop
        Connect-MgGraph -TenantId $TenantId -Scopes $script:GraphScopes -ContextScope Process -NoWelcome -WarningAction SilentlyContinue -InformationAction SilentlyContinue -ErrorAction Stop | Out-Null
        $GraphConnected = $true
    } catch {
        Write-StatusLog FAIL 'Connexion Graph impossible.' (Get-ErrMsg $_)
        Write-Host "La collecte s'arrete : sans connexion Graph, le domaine du tenant est inconnu." -ForegroundColor Red
        exit 1
    }
    $mc = Get-MgContext
    $badTenant = (-not $mc) -or ("$($mc.TenantId)".ToLowerInvariant() -ne $TenantId)
    $badAccount = (-not $mc) -or ("$($mc.Account)" -ne $User -and "$($mc.Account)".ToLowerInvariant() -ne $User.ToLowerInvariant())
    if ($badTenant -or $badAccount) {
        $got = if ($mc) { "tenant $($mc.TenantId), compte $($mc.Account)" } else { 'aucun contexte' }
        Disconnect-MgGraph | Out-Null
        Write-StatusLog FAIL 'Connexion refusee : le tenant ou le compte ne correspond pas.' "attendu tenant $TenantId et compte $User ; obtenu $got"
        Write-Host ("Compte obtenu : '{0}' (attendu : '{1}')." -f $(if ($mc) { $mc.Account } else { 'aucun' }), $User) -ForegroundColor Red
        Write-Host "Cause probable : compte different de celui demande, ou alias different de l'UPN saisi (utiliser exactement l'UPN du compte)." -ForegroundColor Yellow
        Write-Host 'Relancer la commande et choisir, dans la fenetre de connexion, exactement le compte demande.' -ForegroundColor Yellow
        exit 1
    }
    try {
        $org = @(Invoke-G '/organization')[0]
        $initial = "$((@($org.verifiedDomains) | Where-Object { $_.isInitial } | Select-Object -First 1).name)"
        if (-not $initial) { throw 'domaine initial introuvable dans /organization' }
    } catch {
        Disconnect-MgGraph | Out-Null
        Write-StatusLog FAIL 'Lecture de l''organisation impossible.' (Get-ErrMsg $_)
        Write-Host "Cause probable : consentement administrateur manquant (voir le guide). Arret." -ForegroundColor Red
        exit 1
    }
    $script:Ctx.InitialDomain = $initial
    Write-StatusLog OK ("Tenant connecte : {0}" -f $org.displayName) ("{0} | {1} | compte {2}" -f $initial, $mc.TenantId, $mc.Account)
    Write-StatusLog INFO 'Type de collecte' $(if ($script:Ctx.IsSource) { 'tenant SOURCE (volumetries completes)' } else { 'tenant CIBLE (conflits et securite)' })

    # Test des acces du compte AVANT toute collecte
    Write-Host ''
    Write-Host '  Test des acces du compte (lectures minimales) :'
    $probe = Invoke-GraphAccessProbe
    Write-CheckTable $probe.Rows
    $probeWarn = @($probe.Rows | Where-Object { $_.Status -eq 'WARN' })
    if ($probe.Blocking) {
        $blockers = @($probe.Rows | Where-Object { $_.Status -eq 'FAIL' })
        Write-Host ''
        Write-StatusLog FAIL 'Le compte n''a pas les acces indispensables : la collecte s''arrete avant de commencer.'
        foreach ($b in $blockers) { Write-Hint ("{0} : {1}" -f $b.Name, $b.Detail); if ($b.Impact) { Write-Hint $b.Impact } }
        Write-Hint 'Que faire : se connecter avec un compte Administrateur general (ou Lecteur general) et accepter le consentement demande a la premiere connexion (voir le guide, section Droits necessaires), puis relancer la meme commande.'
        Disconnect-MgGraph | Out-Null
        exit 1
    }
    if ($probeWarn.Count -gt 0) {
        Write-Host ''
        Write-StatusLog WARN ("{0} point(s) d'acces limite(s) : la collecte continue, avec ces impacts :" -f $probeWarn.Count)
        foreach ($w in $probeWarn) { if ($w.Impact) { Write-Hint ("{0} : {1}" -f $w.Name, $w.Impact) } }
        Write-RunLogLine ('{0:yyyy-MM-dd HH:mm:ss} Acces Graph limites : {1}' -f (Get-Date), (($probeWarn | ForEach-Object { $_.Name }) -join ' ; '))
    } else {
        Write-StatusLog OK 'Acces Graph valides.'
    }
    Save-Csv ([pscustomobject]@{
            Tenant = $org.displayName; DisplayName = $org.displayName; TenantId = $mc.TenantId; InitialDomain = $initial
            CountryLetterCode = $org.countryLetterCode; PreferredLanguage = $org.preferredLanguage
            OnPremisesSyncEnabled = $org.onPremisesSyncEnabled; OnPremisesLastSyncDateTime = $org.onPremisesLastSyncDateTime
            CreatedDateTime = $org.createdDateTime; AuditedBy = $mc.Account; AuditedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
            ScriptVersion = $ScriptVersion; Role = $Role
        }) 'tenant.csv'
}

# --- Collecte complete : repartir d'un dossier propre (idempotence), run.log conserve ---
if ($FullRun -and $Resume) {
    $locked = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Out -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'run.log', 'tenant.csv' })) {
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $locked++ }
    }
    if ($locked -gt 0) { Write-Status WARN "$locked ancien(s) fichier(s) verrouille(s) (ouverts dans Excel ?)" 'ils seront ecrases s''ils sont recollectes.' }
}

# --- Connexions interactives d'abord (SharePoint puis Exchange, un processus chacun) : l'utilisateur est devant l'ecran ---
if ($ChildParts.Count -gt 0) {
    $ctxFile = Join-Path $Out 'ctx.json'
    try {
        Set-Content -LiteralPath $ctxFile -Encoding utf8 -Value ([ordered]@{
                TenantId = $TenantId; User = $User; Role = $Role; InitialDomain = $script:Ctx.InitialDomain; Out = $Out
            } | ConvertTo-Json)
        if ('SharePoint' -in $ChildParts) {
            Write-Host ''
            Write-StatusLog WAIT 'SharePoint : une fenetre de connexion va s''ouvrir.' 'y repondre dans les 2 minutes, sinon elle expire'
            Start-CollectWorker 'SharePoint' $ctxFile
        }
        if ('Exchange' -in $ChildParts) {
            Write-Host ''
            Write-StatusLog WAIT 'Exchange Online : une fenetre de connexion va s''ouvrir.' "compte attendu : $User"
            Start-CollectWorker 'Exchange' $ctxFile
        }
    } catch {
        foreach ($cp in $ChildParts) { Add-Cap $cp 'Processus' 'KO' ("Erreur inattendue : " + (Get-ErrMsg $_)) }
    } finally {
        if (Test-Path -LiteralPath $ctxFile) { Remove-Item -LiteralPath $ctxFile -Force }
    }

    # Recapitulatif des acces Exchange / SharePoint
    $accessRows = @($script:Ctx.Capabilities | Where-Object {
            $_.Part -in 'Exchange', 'SharePoint' -and ($_.Item -like 'Acces *' -or ($_.Status -ne 'OK' -and $_.Item -match '^(Connexion|Connect-SPOService|Processus|Module |Compte connecte)'))
        } | ForEach-Object {
            [pscustomobject]@{
                Name   = ("{0} / {1}" -f $_.Part, ($_.Item -replace '^Acces ', ''))
                Status = $(switch ($_.Status) { 'OK' { 'OK' } 'KO' { 'FAIL' } default { 'WARN' } })
                Detail = $_.Detail
            }
        })
    if ($accessRows.Count -gt 0) {
        Write-Host ''
        Write-Host '  Acces Exchange et SharePoint :'
        Write-CheckTable $accessRows
    }
}

# ====================================================================================================
# [3/4] Collecte Graph (processus principal)
# ====================================================================================================
Write-Section 3 4 'Collecte'
if ($GraphParts.Count -eq 0) {
    Write-Status INFO 'Aucune partie Graph a collecter pour ce lancement.'
} else {
    $doneParts = 0
    foreach ($p in $GraphParts) {
        Show-OverallProgress -Done $doneParts -Total $GraphParts.Count -Label $p
        Write-Status INFO ("Collecte {0} ({1}/{2})" -f $p, ($doneParts + 1), $GraphParts.Count)
        Invoke-CollectPart $p
        $doneParts++
        Show-OverallProgress -Done $doneParts -Total $GraphParts.Count -Label $p
    }
    Complete-OverallProgress
    Write-Status OK ("{0} partie(s) de collecte terminee(s)." -f $GraphParts.Count)
}
if ($GraphConnected) {
    try { Disconnect-MgGraph | Out-Null } catch { }
    $GraphConnected = $false
}

# ====================================================================================================
# [4/4] Synthese et archive
# ====================================================================================================
Write-Section 4 4 'Archive'
$final = @(Save-MergedCapabilities)
$ko = @($final | Where-Object { $_.Status -eq 'KO' }).Count
$partial = @($final | Where-Object { $_.Status -eq 'PARTIEL' }).Count
$okCount = @($final | Where-Object { $_.Status -eq 'OK' }).Count

$zip = Join-Path $ZipDir ("collecte-{0}.zip" -f $ShortId)
$zipOk = $false
try {
    Write-Log "Fin de collecte. Dossier : $Out" 'Green'
    Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $zip -Force -ErrorAction Stop
    $zipOk = $true
    Write-Status OK 'Archive creee.' $zip
} catch { Write-Status FAIL 'Creation du zip impossible.' "$($_.Exception.Message). Compresser manuellement le dossier : $Out" }

# KO d'elements optionnels (licence / role) : comptes dans le total KO, mais presentes comme "non disponibles" au bilan
$unavailable = @($final | Where-Object { $_.Status -eq 'KO' -and (Get-CapAdvice $_).Unavailable }).Count
Show-FinalReport -Ok $okCount -Partial $partial -Ko $ko -Duration ((Get-Date) - $ScriptStart) -ZipPath $(if ($zipOk) { $zip } else { '' }) -OutDir $Out -Unavailable $unavailable
Show-IssueList $final
Write-Host '  Ce fichier contient des noms et adresses e-mail : a transmettre par un canal securise. Il ne contient aucun contenu de mails ou de fichiers.' -ForegroundColor Yellow
if ($ko -eq 0 -and $partial -eq 0) { Write-Host '  Aucun element en KO.' -ForegroundColor Green }
if ($zipOk) { exit 0 } else { exit 2 }
