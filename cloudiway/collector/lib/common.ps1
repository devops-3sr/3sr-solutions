# common.ps1 - fonctions et constantes partagees. Dot-sourcee par cloudiway-collector.ps1.
# Ne se connecte a rien.

# Contexte d'execution (renseigne par le script principal, relu dans les processus workers via ctx.json) :
#   $script:Ctx = @{ TenantId; User; Role ('Source'|'Target'); IsSource; InitialDomain; Out; Capabilities = [List[object]] }

$script:GraphScopes = @(
    'Organization.Read.All', 'Directory.Read.All', 'User.Read.All', 'Group.Read.All', 'Application.Read.All',
    'Team.ReadBasic.All', 'Channel.ReadBasic.All', 'Reports.Read.All', 'ReportSettings.Read.All', 'AuditLog.Read.All',
    'Policy.Read.All', 'RoleManagement.Read.Directory', 'SecurityEvents.Read.All',
    'Device.Read.All', 'DeviceManagementManagedDevices.Read.All', 'DeviceManagementConfiguration.Read.All',
    'DeviceManagementApps.Read.All', 'DeviceManagementServiceConfig.Read.All'
)
$script:CloudiwayAppIds = @{ '5f7eb765-974a-45c6-8f93-43a417abdedd' = 'Cloudiway-source'; 'ac1e5a45-2177-412c-ac06-09ba04df530a' = 'Cloudiway-cible' }
$script:SystemSiteTemplates = @('APPCATALOG#0', 'SRCHCEN#0', 'SPSMSITEHOST#0', 'POINTPUBLISHINGHUB#0', 'POINTPUBLISHINGTOPIC#0', 'REDIRECTSITE#0', 'EDISC#0', 'TENANTADMIN#0', 'SPSPERS#10')
$script:MicrosoftTenantId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'

$script:AppName = '3SR - Collecte de donnees'
$script:AppVersion = '1.2'
$script:AppDate = '31/10/2026'
$script:AppContact = 'votre contact 3SR'

# Ecrit un fragment sur la console (couleur ignoree si NO_COLOR). N'echoue jamais.
function Write-ConsolePart([string]$Text, [string]$Color = '', [switch]$NoNewline) {
    try {
        if ($Color -and -not $env:NO_COLOR) {
            if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
        } else {
            if ($NoNewline) { Write-Host $Text -NoNewline } else { Write-Host $Text }
        }
    } catch { }
}

# Ajoute une ligne brute a run.log (meme format qu'avant). N'echoue jamais.
function Write-RunLogLine([string]$Line) {
    if ($script:Ctx.Out -and (Test-Path -LiteralPath $script:Ctx.Out)) { Add-Content -Path (Join-Path $script:Ctx.Out 'run.log') -Value $Line -Encoding utf8 }
}

function Write-Log([string]$Msg, [string]$Color = 'Gray') {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Msg
    Write-ConsolePart ((Get-Date).ToString('HH:mm:ss') + ' ') 'DarkGray' -NoNewline
    Write-ConsolePart $Msg $Color
    Write-RunLogLine $line
}

# Enregistre le resultat d'un controle : Status = OK | KO | PARTIEL. Ne leve jamais d'exception.
function Add-Cap([string]$Part, [string]$Item, [string]$Status, [string]$Detail = '') {
    $script:Ctx.Capabilities.Add([pscustomobject]@{ Part = $Part; Item = $Item; Status = $Status; Detail = $Detail })
    $c = switch ($Status) { 'OK' { 'Green' } 'KO' { 'Red' } default { 'Yellow' } }
    $tag = switch ($Status) { 'OK' { '[OK]' } 'KO' { '[KO]' } default { '[PARTIEL]' } }
    Write-RunLogLine ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), "$Part / $Item : $Status $Detail")
    Write-ConsolePart ((Get-Date).ToString('HH:mm:ss') + ' ') 'DarkGray' -NoNewline
    Write-ConsolePart $tag.PadRight(9) $c -NoNewline
    Write-ConsolePart " $Part / $Item" '' -NoNewline
    if ($Detail) { Write-ConsolePart "  $Detail" 'DarkGray' -NoNewline }
    Write-ConsolePart ''
}

# CSV ';' UTF-8 avec BOM. Fichier vide (0 octet de donnees) si aucune ligne, pour que la presence du fichier prouve que la collecte a eu lieu.
function Save-Csv($Data, [string]$Name) {
    $path = Join-Path $script:Ctx.Out $Name
    if ($null -eq $Data -or @($Data).Count -eq 0) { Set-Content -Path $path -Value '' -Encoding utf8BOM; Write-Log "$Name : 0 ligne"; return }
    $rows = foreach ($o in @($Data)) {
        foreach ($p in $o.PSObject.Properties) { if ($p.Value -is [datetime]) { try { $p.Value = $p.Value.ToString('yyyy-MM-ddTHH:mm:ss') } catch { } } }
        $o
    }
    @($rows) | Export-Csv -Path $path -Delimiter ';' -Encoding utf8BOM -NoTypeInformation
    Write-Log ("{0} : {1} lignes" -f $Name, @($Data).Count)
}

# Relit un CSV produit par Save-Csv ; retourne @() si absent ou vide.
function Import-CollectedCsv([string]$Name, [string]$Dir) {
    if (-not $Dir) { $Dir = $script:Ctx.Out }
    $p = Join-Path $Dir $Name
    if (-not (Test-Path $p) -or (Get-Item $p).Length -le 5) { return @() }
    @(Import-Csv -Path $p -Delimiter ';')
}

# Go au format francais ('0,00') pour Excel FR. Les calculs se font TOUJOURS sur les colonnes en octets, jamais sur ces chaines.
function ConvertTo-GB($Bytes) { if ($null -eq $Bytes -or $Bytes -eq '') { return $null }; ([math]::Round([double]$Bytes / 1GB, 2)).ToString('0.00', [cultureinfo]'fr-FR') }

# "11.05 GB (11,864,090,092 bytes)" -> 11864090092 ; $null si format inconnu.
function Get-BytesFromSize($Size) {
    if ($null -eq $Size) { return $null }
    if ("$Size" -match '\(([\d,\.\s]+) bytes\)') { return [int64]($Matches[1] -replace '[^\d]', '') }
    return $null
}

# Date ISO sans fuseau ; laisse inchangee toute valeur non-DateTime.
function Format-Date($d) { if ($d -is [datetime]) { $d.ToString('yyyy-MM-ddTHH:mm:ss') } else { $d } }

# Code HTTP d'une erreur (Exception.Response.StatusCode, Exception.StatusCode, sinon lu dans le message) ; $null si illisible.
function Get-ErrCode($e) {
    $code = $null
    try { $sc = $e.Exception.Response.StatusCode; if ($null -ne $sc) { $code = [int]$sc } } catch { }
    if ($null -eq $code) { try { $sc = $e.Exception.StatusCode; if ($null -ne $sc) { $code = [int]$sc } } catch { } }
    if ($null -eq $code) { try { if ("$($e.Exception.Message)" -match 'status code[^:\d]*:?\s*(\d{3})\b') { $code = [int]$Matches[1] } } catch { } }
    if ($null -ne $code -and ($code -lt 100 -or $code -gt 599)) { $code = $null }
    return $code
}

# Message d'erreur court et lisible, max 220 caracteres, sans retour ligne. Extrait error.message du corps JSON de Graph quand il est
# lisible (ConvertFrom-Json, sinon regex), prefixe "HTTP <code> : " quand le code est connu, et ajoute le type de l'exception quand
# le message extrait est trop court (< 20 caracteres) ou vide (corps d'erreur vide ou reduit a "{").
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

# GET Graph avec pagination (-All). Retourne la liste des elements 'value', ou l'objet unique si la reponse n'a pas de 'value'.
# GET uniquement : aucune methode d'ecriture n'existe dans ce package.
function Invoke-G([string]$Path, [switch]$All, [string]$Version = 'v1.0') {
    $uri = if ($Path -like 'https://*') { $Path } else { "https://graph.microsoft.com/$Version$Path" }
    $res = [System.Collections.Generic.List[object]]::new()
    do {
        $r = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ ConsistencyLevel = 'eventual' } -OutputType PSObject
        if ($null -ne $r.value) { $r.value | ForEach-Object { $res.Add($_) } } else { return $r }
        $uri = if ($All) { $r.'@odata.nextLink' } else { $null }
    } while ($uri)
    return $res
}

# Valeur de /$count (ConsistencyLevel: eventual requis). Repli : pagination sur id seulement si la reponse $count est inexploitable.
function Get-GCount([string]$Path) {
    $h = @{ ConsistencyLevel = 'eventual' }
    try {
        $r = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0" + $Path) -Headers $h
        if ($r -is [byte[]]) { $r = [System.Text.Encoding]::UTF8.GetString($r) }
        $n = 0
        if ([int]::TryParse(("$r").Trim().TrimStart([char]0xFEFF), [ref]$n)) { return $n }
        throw 'reponse $count inattendue'
    } catch {
        $n = 0
        $u = 'https://graph.microsoft.com/v1.0' + ($Path -replace '/\$count$', '') + '?$select=id&$top=999'
        do {
            $p = Invoke-MgGraphRequest -Method GET -Uri $u -Headers $h -OutputType PSObject
            $n += @($p.value).Count
            $u = $p.'@odata.nextLink'
        } while ($u)
        return $n
    }
}

# Rapport d'usage Graph (CSV) -> fichier $Name au format ';'. Periode D180. Ne leve pas d'exception.
function Save-Report([string]$Report, [string]$Name) {
    $tmp = Join-Path $script:Ctx.Out ("_tmp_{0}" -f $Name)
    try {
        Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/reports/$Report(period='D180')" -OutputFilePath $tmp
        Save-Csv (Import-Csv $tmp) $Name
        Add-Cap 'Identity' "report $Report" 'OK'
    } catch { Add-Cap 'Identity' "report $Report" 'KO' (Get-ErrMsg $_) }
    finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
}

# Ecrit les capacites d'un worker dans capabilities-<Part>.csv (fusionne ensuite par le script principal).
function Save-Capabilities([string]$Part) { Save-Csv @($script:Ctx.Capabilities) ("capabilities-{0}.csv" -f $Part) }
