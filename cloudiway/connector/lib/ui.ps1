# ui.ps1 - presentation console et questions interactives.
# Affichage via Write-Host uniquement : aucune sortie dans le pipeline (sauf la valeur retournee par les fonctions Read-* / Confirm-*).
# Ne se connecte a rien. Aucune fonction ne leve d'exception d'affichage.
# Depend de $script:AppName / AppVersion / AppDate / AppContact (lib\common.ps1), avec valeurs de repli.

$script:UI = $null

function Initialize-UI {
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }

    $unicode = $false
    if (-not $redirected) {
        # L'encodage d'origine de la console est memorise pour etre RESTAURE en fin d'execution (Restore-ConsoleEncoding).
        if ($null -eq $script:OriginalOutputEncoding) { try { $script:OriginalOutputEncoding = [Console]::OutputEncoding } catch { } }
        try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
        try { $unicode = ([Console]::OutputEncoding.CodePage -eq 65001) } catch { $unicode = $false }
        $hn = ''
        try { $hn = [string]$Host.Name } catch { }
        if ($hn -in @('Default Host', 'ServerRemoteHost')) { $unicode = $false }
    }

    $color = -not [string]::IsNullOrEmpty($Host.Name) -and -not $env:NO_COLOR
    if ($env:NO_COLOR) { $color = $false }

    $width = 80
    try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -gt 0) { $width = $w - 1 } } catch { }
    $width = [Math]::Max(60, [Math]::Min(100, $width))

    $chars = if ($unicode) {
        @{ ML = '╟'; MR = '╢'; TL = '╔'; TR = '╗'; BL = '╚'; BR = '╝'; H = '═'; V = '║'; Line = '─'; Bullet = '›'; Ell = '…' }
    } else {
        @{ ML = '+'; MR = '+'; TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|'; Line = '-'; Bullet = '>'; Ell = '...' }
    }
    $script:UI = @{ Unicode = $unicode; Color = $color; Width = $width; C = $chars }
}

# Restaure l'encodage de sortie de la console tel qu'il etait avant Initialize-UI (la console de l'utilisateur reste utilisable apres l'outil).
function Restore-ConsoleEncoding {
    try { if ($null -ne $script:OriginalOutputEncoding) { [Console]::OutputEncoding = $script:OriginalOutputEncoding } } catch { }
}

function Get-UIState {
    if ($null -eq $script:UI) { Initialize-UI }
    $script:UI
}

function Get-UIApp([string]$Name, [string]$Default) {
    $v = Get-Variable -Name $Name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($v) { [string]$v } else { $Default }
}

# Ecrit un fragment (couleur ignoree si NO_COLOR). Ne leve jamais.
function Write-UIText([string]$Text, [string]$Color = '', [switch]$NoNewline) {
    $ui = Get-UIState
    try {
        if ($ui.Color -and $Color) {
            if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline } else { Write-Host $Text -ForegroundColor $Color }
        } else {
            if ($NoNewline) { Write-Host $Text -NoNewline } else { Write-Host $Text }
        }
    } catch { }
}

# Decoupe un texte en lignes de largeur maximale $Max (coupe aux espaces, sinon a la dure).
function Split-UIText([string]$Text, [int]$Max) {
    if ($Max -lt 10) { $Max = 10 }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($para in (("$Text") -split "\r?\n")) {
        $cur = ''
        foreach ($word in ($para -split ' ')) {
            while ($word.Length -gt $Max) {
                if ($cur) { $out.Add($cur); $cur = '' }
                $out.Add($word.Substring(0, $Max)); $word = $word.Substring($Max)
            }
            if ($cur -eq '') { $cur = $word }
            elseif (($cur.Length + 1 + $word.Length) -le $Max) { $cur = "$cur $word" }
            else { $out.Add($cur); $cur = $word }
        }
        $out.Add($cur)
    }
    , @($out)
}

function Get-UILevel([string]$Status) {
    switch -Regex (("$Status").Trim().ToUpperInvariant()) {
        '^(OK|SUCCESS|PASS)$'                { 'OK'; break }
        '^(KO|FAIL|FAILED|ERROR|ERREUR)$'    { 'FAIL'; break }
        '^(WARN|WARNING|PARTIEL|PARTIAL)$'   { 'WARN'; break }
        '^(WAIT|ATTENTE)$'                   { 'WAIT'; break }
        '^(SKIP|IGNORE|IGNORED)$'            { 'SKIP'; break }
        default                              { 'INFO' }
    }
}

$script:UILevels = @{
    OK   = @{ Label = '[ OK ]'; Color = 'Green' }
    WARN = @{ Label = '[WARN]'; Color = 'Yellow' }
    FAIL = @{ Label = '[FAIL]'; Color = 'Red' }
    INFO = @{ Label = '[INFO]'; Color = 'Cyan' }
    WAIT = @{ Label = '[WAIT]'; Color = 'Magenta' }
    SKIP = @{ Label = '[SKIP]'; Color = 'DarkGray' }
}

function Write-UIBoxLine([string]$Text, [string]$TextColor, [string]$FrameColor, [int]$Inner) {
    $c = (Get-UIState).C
    $pad = ' ' * [Math]::Max(0, $Inner - 2 - $Text.Length)
    Write-UIText $c.V $FrameColor -NoNewline
    Write-UIText (' ' + $Text + $pad + ' ') $TextColor -NoNewline
    Write-UIText $c.V $FrameColor
}

# Libelle lisible du mode (Source / Target).
function Get-ModeLabel([string]$Mode) {
    switch ($Mode) {
        'Source' { 'Source (tenant a migrer)' }
        'Target' { 'Cible (tenant de destination)' }
        default  { $Mode }
    }
}

# Banniere. Les elements vides sont omis : elle peut etre affichee avant les questions (titre seul), puis reaffichee complete.
function Show-Banner([string]$Mode, [string]$TenantId, [string]$User, [string]$OutDir, [string]$ProjectId, [switch]$Simulation, [switch]$Discover, [string]$CloudiwayLogin) {
    $ui = Get-UIState; $c = $ui.C
    $inner = $ui.Width - 2
    $fc = 'Cyan'
    $name = Get-UIApp 'AppName' '3SR - Configuration du connecteur Cloudiway'
    $ver  = Get-UIApp 'AppVersion' '2.7'
    $date = Get-UIApp 'AppDate' '04/11/2026'
    $mail = Get-UIApp 'AppContact' 'votre contact 3SR'

    $modeTxt = ''
    if ($Discover) { $modeTxt = 'Decouverte (lecture seule du projet Cloudiway, aucune connexion au tenant)' }
    elseif ($Mode) { $modeTxt = Get-ModeLabel $Mode }
    if ($Simulation -and $modeTxt) { $modeTxt += ' - SIMULATION (-WhatIf) : aucune ecriture' }

    Write-UIText ''
    Write-UIText ($c.TL + ($c.H * $inner) + $c.TR) $fc
    Write-UIBoxLine '' '' $fc $inner
    $t = $name; $lp = [Math]::Max(0, [int](($inner - 2 - $t.Length) / 2))
    Write-UIBoxLine ((' ' * $lp) + $t) 'White' $fc $inner
    $sub = "version $ver - $date"
    Write-UIBoxLine ((' ' * [Math]::Max(0, [int](($inner - 2 - $sub.Length) / 2))) + $sub) 'Gray' $fc $inner
    $ct = "contact : $mail"
    Write-UIBoxLine ((' ' * [Math]::Max(0, [int](($inner - 2 - $ct.Length) / 2))) + $ct) 'Gray' $fc $inner
    Write-UIBoxLine '' '' $fc $inner

    # Liste explicite de paires : un pipeline qui ne laisse qu'une paire l'aplatirait en tableau de chaines (erreur sur .Trim() d'un caractere).
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($pair in @(@('Mode     ', $modeTxt), @('Tenant   ', $TenantId), @('Compte   ', $User), @('Cloudiway', $CloudiwayLogin), @('Projet   ', $ProjectId), @('Sortie   ', $OutDir))) {
        if ($pair[1]) { $items.Add(@($pair[0], [string]$pair[1])) }
    }
    $below = [System.Collections.Generic.List[string]]::new()
    if ($items.Count -gt 0) {
        Write-UIText ($c.ML + ($c.Line * $inner) + $c.MR) $fc
        $maxVal = $inner - 4 - 11
        foreach ($it in $items) {
            $val = [string]$it[1]
            # Un chemin trop long pour le cadre n'est jamais coupe au milieu : il est affiche en entier sous le cadre
            if ($it[0].Trim() -eq 'Sortie' -and $val.Length -gt $maxVal) { $below.Add("Sortie : $val"); $val = '(chemin complet sous le cadre)' }
            $lines = Split-UIText $val $maxVal
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $lab = if ($i -eq 0) { "$($it[0]): " } else { '           ' }
                $pad = ' ' * [Math]::Max(0, $inner - 2 - $lab.Length - $lines[$i].Length)
                Write-UIText $c.V $fc -NoNewline
                Write-UIText (' ' + $lab) 'DarkGray' -NoNewline
                Write-UIText ($lines[$i] + $pad + ' ') 'White' -NoNewline
                Write-UIText $c.V $fc
            }
        }
    }
    Write-UIText ($c.BL + ($c.H * $inner) + $c.BR) $fc
    foreach ($l in $below) { Write-UIText ('  ' + $l) 'White' }
    Write-UIText ''
}

function Write-Section([int]$Index, [int]$Total, [string]$Title) {
    $ui = Get-UIState; $c = $ui.C
    $head = "[$Index/$Total] $Title"
    Write-UIText ''
    Write-UIText $head 'Cyan'
    Write-UIText ($c.Line * [Math]::Min($ui.Width, [Math]::Max($head.Length, 40))) 'DarkCyan'
}

function Write-Status([string]$Level, [string]$Text, [string]$Detail = '') {
    $key = Get-UILevel $Level
    $lv = $script:UILevels[$key]
    Write-UIText '  ' '' -NoNewline
    Write-UIText $lv.Label $lv.Color -NoNewline
    Write-UIText (' ' + $Text) '' -NoNewline
    if ($Detail) { Write-UIText ('  ' + $Detail) 'DarkGray' -NoNewline }
    Write-UIText ''
}

# Tableau de controles { Name; Status OK|WARN|FAIL|SKIP|KO; Detail }
function Write-CheckTable($Rows) {
    $ui = Get-UIState
    $rows = @($Rows)
    if ($rows.Count -eq 0) { return }
    $maxName = [Math]::Floor($ui.Width * 0.4)
    $nameW = 8
    foreach ($r in $rows) { $nameW = [Math]::Max($nameW, ([string]$r.Name).Length) }
    $nameW = [Math]::Min($nameW, $maxName)
    $detailW = $ui.Width - 2 - 6 - 1 - $nameW - 2
    if ($detailW -lt 15) { $detailW = 15 }
    foreach ($r in $rows) {
        $lv = $script:UILevels[(Get-UILevel ([string]$r.Status))]
        $nameLines = Split-UIText ([string]$r.Name) $nameW
        $detLines = if ($r.Detail) { Split-UIText ([string]$r.Detail) $detailW } else { @('') }
        $n = [Math]::Max($nameLines.Count, $detLines.Count)
        for ($i = 0; $i -lt $n; $i++) {
            Write-UIText '  ' '' -NoNewline
            if ($i -eq 0) { Write-UIText $lv.Label $lv.Color -NoNewline } else { Write-UIText ('      ') '' -NoNewline }
            $nm = if ($i -lt $nameLines.Count) { $nameLines[$i] } else { '' }
            Write-UIText (' ' + $nm.PadRight($nameW) + '  ') '' -NoNewline
            $dt = if ($i -lt $detLines.Count) { $detLines[$i] } else { '' }
            Write-UIText $dt 'DarkGray'
        }
    }
}

function Write-Hint([string]$Text) {
    $ui = Get-UIState
    foreach ($l in (Split-UIText $Text ($ui.Width - 6))) {
        Write-UIText ('  ' + $ui.C.Bullet + ' ' + $l) 'DarkGray'
    }
}

# v2.5 : AVERTISSEMENT VISIBLE (bloc en couleur, hors tableau) : titre sur fond d'alerte + lignes de texte. Ne bloque rien.
function Write-Alert([string]$Title, [string[]]$Lines = @()) {
    $ui = Get-UIState
    Write-UIText ''
    Write-UIText ('  ' + $ui.C.Bullet + ' AVERTISSEMENT - ' + $Title) 'Yellow'
    foreach ($ln in @($Lines)) {
        foreach ($l in (Split-UIText $ln ($ui.Width - 8))) { Write-UIText ('    ' + $l) 'Yellow' }
    }
    Write-UIText ''
}

# Ligne de commande a copier : toujours sur UNE ligne, jamais coupee.
function Write-Command([string]$Text) {
    Write-UIText ('    ' + $Text) 'Cyan'
}

# --- Plan d'actions -------------------------------------------------------------------------------

function Get-ZoneLabel([string]$Area) {
    switch ($Area) {
        'Preflight'        { 'Prerequis' }
        'Rights'           { 'Droits' }
        'Application'      { 'Application' }
        'ServicePrincipal' { 'Princ. service' }
        'Permissions'      { 'Permissions' }
        'Consent'          { 'Consentement' }
        'Roles'            { 'Roles' }
        'Exchange'         { 'Exchange' }
        'Certificate'      { 'Certificat' }
        'ServiceAccount'   { 'Compte service' }
        'ServiceAccountPwd' { 'Mot de passe' }
        'Cloudiway'        { 'Cloudiway' }
        'Cleanup'          { 'Nettoyage' }
        default            { $Area }
    }
}

# Libelle et couleur d'une action de plan ou d'un resultat d'application.
function Get-ActionStyle([string]$Action) {
    switch (("$Action").Trim().ToUpperInvariant()) {
        'CREATE'   { @{ Label = 'CREER'; Color = 'Green' } }
        'UPDATE'   { @{ Label = 'METTRE A JOUR'; Color = 'Yellow' } }
        'OK'       { @{ Label = 'OK'; Color = 'Gray' } }
        'BLOCKED'  { @{ Label = 'BLOQUE'; Color = 'Red' } }
        'SKIP'     { @{ Label = 'IGNORE'; Color = 'DarkGray' } }
        'IGNORE'   { @{ Label = 'IGNORE'; Color = 'DarkGray' } }
        'APPLIQUE' { @{ Label = 'APPLIQUE'; Color = 'Green' } }
        'ECHEC'    { @{ Label = 'ECHEC'; Color = 'Red' } }
        'SIMULE'   { @{ Label = 'SIMULE'; Color = 'Cyan' } }
        default    { @{ Label = ("$Action").ToUpperInvariant(); Color = '' } }
    }
}

# Tableau de plan : Id, Zone, Element, Action (coloree), Raison. Mode empile si le terminal est etroit.
function Show-PlanTable($Plan, [string]$Title = '') {
    $ui = Get-UIState
    $items = @($Plan)
    if ($items.Count -eq 0) { Write-UIText '  (plan vide)' 'DarkGray'; return }
    if ($Title) { Write-UIText ("  $Title") 'White' }
    $idW = [Math]::Max(2, ([string]($items | ForEach-Object { [int]$_.Id } | Measure-Object -Maximum).Maximum).Length)
    $zoneW = 15; $actW = 13
    $rest = $ui.Width - (2 + $idW + 2 + $zoneW + 2 + $actW + 2 + 2)
    $stacked = ($rest -lt 40)
    $elW = [Math]::Max(14, [int][Math]::Floor($rest * 0.42))
    $rW = [Math]::Max(14, $rest - $elW)

    if (-not $stacked) {
        Write-UIText ('  ' + 'Id'.PadRight($idW) + '  ' + 'Zone'.PadRight($zoneW) + '  ' + 'Action'.PadRight($actW) + '  ' + 'Element'.PadRight($elW) + '  ' + 'Raison') 'DarkCyan'
        Write-UIText ('  ' + ($ui.C.Line * ($ui.Width - 2))) 'DarkCyan'
    }
    foreach ($it in $items) {
        $st = Get-ActionStyle ([string]$it.Action)
        $zone = Get-ZoneLabel ([string]$it.Area)
        $idTxt = ([string]$it.Id).PadLeft($idW)
        if ($stacked) {
            Write-UIText ('  ' + $idTxt + '  ' + $zone.PadRight($zoneW) + '  ') '' -NoNewline
            Write-UIText $st.Label $st.Color
            $txt = [string]$it.Name
            if ($it.Reason) { $txt += ' - ' + [string]$it.Reason }
            foreach ($l in (Split-UIText $txt ($ui.Width - 6))) { Write-UIText ('      ' + $l) 'Gray' }
            continue
        }
        $elLines = Split-UIText ([string]$it.Name) $elW
        $rLines = if ($it.Reason) { Split-UIText ([string]$it.Reason) $rW } else { @('') }
        $zLines = Split-UIText $zone $zoneW
        $aLines = Split-UIText $st.Label $actW
        $n = [Math]::Max([Math]::Max($elLines.Count, $rLines.Count), [Math]::Max($zLines.Count, $aLines.Count))
        for ($i = 0; $i -lt $n; $i++) {
            $idPart = if ($i -eq 0) { $idTxt } else { ' ' * $idW }
            $zPart = if ($i -lt $zLines.Count) { $zLines[$i] } else { '' }
            $aPart = if ($i -lt $aLines.Count) { $aLines[$i] } else { '' }
            $ePart = if ($i -lt $elLines.Count) { $elLines[$i] } else { '' }
            $rPart = if ($i -lt $rLines.Count) { $rLines[$i] } else { '' }
            Write-UIText ('  ' + $idPart + '  ' + $zPart.PadRight($zoneW) + '  ') '' -NoNewline
            Write-UIText $aPart.PadRight($actW) $st.Color -NoNewline
            Write-UIText ('  ' + $ePart.PadRight($elW) + '  ') '' -NoNewline
            Write-UIText $rPart 'DarkGray'
        }
    }
    # Totaux par action
    $counts = @{}
    foreach ($it in $items) { $k = (Get-ActionStyle ([string]$it.Action)).Label; $counts[$k] = 1 + [int]$counts[$k] }
    $sum = ($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0} : {1}" -f $_.Name, $_.Value }) -join '   '
    Write-UIText ''
    Write-UIText ("  Total : {0} action(s)   {1}" -f $items.Count, $sum) 'Gray'
}

# --- Questions interactives -----------------------------------------------------------------------

function Test-Interactive {
    try { return (-not [Console]::IsInputRedirected) } catch { return $false }
}

# Question a choix unique. $Options : liste de @{ Key; Label; Detail }. Retourne la Key choisie ($null si non interactif sans defaut).
function Read-Choice([string]$Title, $Options, [int]$DefaultIndex = 0) {
    $opts = @($Options)
    $def = $null
    if ($DefaultIndex -ge 1 -and $DefaultIndex -le $opts.Count) { $def = $opts[$DefaultIndex - 1].Key }
    if (-not (Test-Interactive)) { return $def }
    Write-UIText ''
    Write-UIText ("  " + $Title) 'White'
    for ($i = 0; $i -lt $opts.Count; $i++) {
        Write-UIText ("    {0}) " -f ($i + 1)) 'Cyan' -NoNewline
        Write-UIText ([string]$opts[$i].Label) '' -NoNewline
        if ($opts[$i].Detail) { Write-UIText ('  ' + [string]$opts[$i].Detail) 'DarkGray' -NoNewline }
        Write-UIText ''
    }
    $suffix = if ($DefaultIndex -ge 1) { " [$DefaultIndex]" } else { '' }
    while ($true) {
        $ans = ''
        try { $ans = ("" + (Read-Host ("  Votre choix (1-{0}){1}" -f $opts.Count, $suffix))).Trim() } catch { return $def }
        if (-not $ans -and $def) { return $def }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $opts.Count) { return $opts[$n - 1].Key }
        Write-Status WARN ("Saisie non valide : saisir un numero entre 1 et {0} (exemple : 1). Nouvelle question." -f $opts.Count)
    }
}

# Question a choix multiple. Saisie : "1,3", plage "1-3" ou "tout". Retourne un tableau de Key (dans l'ordre de la liste).
function Read-MultiChoice([string]$Title, $Options, [string[]]$DefaultKeys = @()) {
    $opts = @($Options)
    if (-not (Test-Interactive)) { return @($DefaultKeys) }
    Write-UIText ''
    Write-UIText ("  " + $Title) 'White'
    for ($i = 0; $i -lt $opts.Count; $i++) {
        Write-UIText ("    {0}) " -f ($i + 1)) 'Cyan' -NoNewline
        Write-UIText ([string]$opts[$i].Label) '' -NoNewline
        if ($opts[$i].Detail) { Write-UIText ('  ' + [string]$opts[$i].Detail) 'DarkGray' -NoNewline }
        Write-UIText ''
    }
    Write-UIText "  Saisir les numeros ou les noms separes par des virgules (ex. 1,2 ou Mail,OneDrive), une plage (ex. 1-3) ou 'tout'." 'DarkGray'
    $defTxt = if (@($DefaultKeys).Count -gt 0) { ' [Entree = ' + (@($DefaultKeys) -join ', ') + ']' } else { '' }
    while ($true) {
        $ans = ''
        try { $ans = ("" + (Read-Host ("  Votre choix{0}" -f $defTxt))).Trim().ToLowerInvariant() } catch { return @($DefaultKeys) }
        if (-not $ans -and @($DefaultKeys).Count -gt 0) { return @($DefaultKeys) }
        if (-not $ans) { Write-Status WARN 'Au moins un element est a choisir.'; continue }
        $picked = [System.Collections.Generic.SortedSet[int]]::new()
        $bad = $false
        if ($ans -in 'tout', 'tous', 'all', '*') {
            1..$opts.Count | ForEach-Object { [void]$picked.Add($_) }
        } else {
            foreach ($tok in ($ans -split '[,; ]+' | Where-Object { $_ })) {
                if ($tok -match '^(\d+)-(\d+)$') {
                    $a = [int]$Matches[1]; $b = [int]$Matches[2]
                    if ($a -gt $b) { $a, $b = $b, $a }
                    foreach ($k in $a..$b) { if ($k -ge 1 -and $k -le $opts.Count) { [void]$picked.Add($k) } else { $bad = $true } }
                } elseif ($tok -match '^\d+$' -and [int]$tok -ge 1 -and [int]$tok -le $opts.Count) {
                    [void]$picked.Add([int]$tok)
                } elseif ($tok -notmatch '^\d+$') {
                    # Nom de charge (Mail, OneDrive...) : cle ou libelle, sans tenir compte de la casse
                    $idx = -1
                    for ($j = 0; $j -lt $opts.Count; $j++) {
                        if ([string]$opts[$j].Key -ieq $tok -or [string]$opts[$j].Label -ieq $tok) { $idx = $j; break }
                    }
                    if ($idx -ge 0) { [void]$picked.Add($idx + 1) } else { $bad = $true; if (@($script:UnavailableWorkloadNames | Where-Object { $_ -ieq $tok }).Count -gt 0) { Write-Status WARN ("'{0}' : charge non disponible dans cette version (disponibles : {1})." -f $tok, (($opts | ForEach-Object { [string]$_.Label }) -join ', ')) } }
                } else { $bad = $true }
            }
        }
        if ($bad -or $picked.Count -eq 0) { Write-Status WARN ("Saisie non reconnue. Numeros valides : 1 a {0}." -f $opts.Count); continue }
        return @($picked | ForEach-Object { $opts[$_ - 1].Key })
    }
}

# Saisie de texte avec valeur par defaut, validation facultative ($Validate : scriptblock recevant la valeur) et message d'erreur.
function Read-Text([string]$Prompt, [string]$Default = '', [scriptblock]$Validate = $null, [string]$ErrorText = 'Valeur non valide.', [switch]$AllowEmpty) {
    if (-not (Test-Interactive)) { return $Default }
    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        $ans = ''
        try { $ans = ("" + (Read-Host ("  {0}{1}" -f $Prompt, $suffix))).Trim() } catch { return $Default }
        if (-not $ans) { $ans = $Default }
        if (-not $ans) {
            if ($AllowEmpty) { return '' }
            Write-Status WARN 'Une valeur est necessaire.'
            continue
        }
        if ($Validate) {
            $okv = $false
            try { $okv = [bool](& $Validate $ans) } catch { $okv = $false }
            if (-not $okv) { Write-Status WARN $ErrorText; continue }
        }
        return $ans
    }
}

# Saisie masquee (jeton, mot de passe). Retourne un [securestring] ou $null (non interactif, vide apres 3 essais).
function Read-SecretText([string]$Prompt) {
    if (-not (Test-Interactive)) { return $null }
    for ($try = 1; $try -le 3; $try++) {
        $s = $null
        try { $s = Read-Host ("  {0}" -f $Prompt) -AsSecureString } catch { return $null }
        if ($s -and $s.Length -gt 0) { return $s }
        Write-Status WARN 'Aucune valeur saisie.'
    }
    return $null
}

# Question O/N. Sans console interactive, la reponse est NON : rien n'est jamais accepte implicitement.
function Confirm-Action([string]$Question, [switch]$DefaultYes) {
    if (-not (Test-Interactive)) { return $false }
    $hint = if ($DefaultYes) { 'O/n' } else { 'o/N' }
    while ($true) {
        $ans = ''
        try { $ans = ("" + (Read-Host ("  {0} [{1}]" -f $Question, $hint))).Trim().ToLowerInvariant() } catch { return $false }
        if (-not $ans) { return [bool]$DefaultYes }
        if ($ans -in 'o', 'oui', 'y', 'yes') { return $true }
        if ($ans -in 'n', 'non', 'no') { return $false }
        Write-Status WARN 'Repondre par O (oui) ou N (non).'
    }
}

# Recapitulatif : liste de @(libelle, valeur).
function Show-Recap($Items, [string]$Title = 'Recapitulatif') {
    $ui = Get-UIState
    $its = @($Items | Where-Object { $_ })
    Write-UIText ''
    Write-UIText $Title 'Cyan'
    Write-UIText ($ui.C.Line * [Math]::Max($Title.Length, 20)) 'DarkCyan'
    $lw = 4
    foreach ($it in $its) { $lw = [Math]::Max($lw, ([string]$it[0]).Length) }
    $lw = [Math]::Min($lw, 28)
    $dw = [Math]::Max(20, $ui.Width - 4 - $lw - 2)
    foreach ($it in $its) {
        $lines = Split-UIText ([string]$it[1]) $dw
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $lab = if ($i -eq 0) { [string]$it[0] } else { '' }
            Write-UIText ('  ' + $lab.PadRight($lw) + '  ') 'DarkGray' -NoNewline
            Write-UIText $lines[$i] 'White'
        }
    }
    Write-UIText ''
}

# Validite en jours -> texte lisible ("180 jours, soit environ 6 mois").
function Format-Validity([int]$Days) {
    $months = [Math]::Round($Days / 30.0)
    if ($Days -ge 45 -and $months -ge 1) { return ("{0} jours, soit environ {1} mois" -f $Days, [int]$months) }
    return ("{0} jours" -f $Days)
}

# Noms codifies (application, compte de service, connecteur, certificat) et duree de validite des identifiants.
# $Names : { App; ServiceAccountLocal; ServiceAccountDisplay; Connector }. Aucun secret.
function Show-CodedNames($Names, [string]$Mode, [string]$ProjectId, [string]$Domain, [bool]$NeedServiceAccount, [int]$ValidityDays, [string]$AuthMethod = 'Both', [string]$Title = 'Noms utilises (codifies : ils servent a la relance)') {
    if (-not $Names) { return }
    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add(@('Application Entra', [string]$Names.App))
    if ($NeedServiceAccount) {
        $upn = [string]$Names.ServiceAccountLocal
        if ($Domain -and $upn -notmatch '@') { $upn = "$upn@$Domain" }
        $items.Add(@('Compte de service', ("{0} ({1})" -f $upn, [string]$Names.ServiceAccountDisplay)))
    } else {
        $items.Add(@('Compte de service', 'non necessaire pour ces charges'))
    }
    $items.Add(@('Connecteur Cloudiway', [string]$Names.Connector))
    $authTxt = switch ($AuthMethod) { 'Secret' { 'secret client' } 'Both' { 'certificat et secret client' } default { 'certificat' } }
    $certSubject = if ($Mode -and $ProjectId) { "CN=Cloudiway-$($Mode.ToUpperInvariant())-P$ProjectId" } else { '' }
    $items.Add(@('Authentification', ("{0}, valable {1}" -f $authTxt, (Format-Validity $ValidityDays))))
    if ($certSubject -and $AuthMethod -ne 'Secret') { $items.Add(@('Sujet du certificat', $certSubject)) }
    Show-Recap @($items) $Title
}

# Prochaines actions : $Steps = @{ Todo = liste de @{ Title; Text; Command }; Check = liste idem }.
# "A faire" (actions reelles) et "A verifier" (informations / controles non automatisables) : un groupe vide n'est pas affiche.
# Une liste simple (ancien format) est acceptee et affichee comme "A faire".
function Show-NextSteps($Steps) {
    $ui = Get-UIState
    $groups = [System.Collections.Generic.List[object]]::new()
    if ($Steps -is [System.Collections.IDictionary]) {
        $groups.Add(@{ Title = 'A faire'; Note = 'actions a realiser par vous : l''outil ne les a pas executees'; Items = @($Steps['Todo'] | Where-Object { $_ }) })
        $groups.Add(@{ Title = 'A verifier'; Note = 'informations et controles que l''outil ne peut pas automatiser ni deviner'; Items = @($Steps['Check'] | Where-Object { $_ }) })
    } else {
        $groups.Add(@{ Title = 'A faire'; Note = 'actions a realiser par vous : l''outil ne les a pas executees'; Items = @($Steps | Where-Object { $_ }) })
    }
    foreach ($g in $groups) {
        $st = @($g.Items)
        if ($st.Count -eq 0) { continue }
        Write-UIText $g.Title 'Cyan'
        Write-UIText ($ui.C.Line * 40) 'DarkCyan'
        Write-UIText ('  ' + $g.Note) 'DarkGray'
        $i = 0
        foreach ($s in $st) {
            $i++
            Write-UIText ("  {0}. {1}" -f $i, $s.Title) 'White'
            if ($s.Text) { foreach ($l in (Split-UIText ([string]$s.Text) ($ui.Width - 8))) { Write-UIText ('     ' + $l) 'Gray' } }
            foreach ($cmd in @($s.Command | Where-Object { $_ })) { Write-UIText ('     ' + $cmd) 'Cyan' }
        }
        Write-UIText ''
    }
}

# Bilan final. Verdict deduit des compteurs ; couleur du cadre : rouge (echec / non conforme), jaune (bloque), vert.
function Show-FinalReport([int]$Applied, [int]$Failed, [int]$Ignored, [int]$Blocked, [int]$Compliant, [int]$NonCompliant, $Duration, [string]$OutDir, [string]$ReportPath, [switch]$Simulation) {
    $ui = Get-UIState; $c = $ui.C
    $inner = $ui.Width - 2
    $fc = if ($Failed -gt 0 -or $NonCompliant -gt 0) { 'Red' } elseif ($Blocked -gt 0 -or $Ignored -gt 0) { 'Yellow' } else { 'Green' }
    $durTxt = if ($Duration -is [timespan]) { '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds } else { [string]$Duration }
    $verdict = if ($Simulation) { 'Simulation terminee : aucune ecriture n''a ete effectuee' }
    elseif ($Failed -gt 0 -or $NonCompliant -gt 0) { 'Termine avec des elements en echec ou non conformes' }
    elseif ($Blocked -gt 0 -or $Ignored -gt 0) { 'Termine : certains elements sont bloques ou ignores' }
    elseif ($Applied -eq 0) { 'Rien a faire : tout etait deja conforme' }
    else { 'Termine avec succes : tout est conforme' }
    if ($Simulation) { $fc = 'Cyan' }

    Write-UIText ''
    Write-UIText ($c.TL + ($c.H * $inner) + $c.TR) $fc
    foreach ($vl in (Split-UIText $verdict ($inner - 4))) { Write-UIBoxLine $vl $fc $fc $inner }
    Write-UIText ($c.ML + ($c.Line * $inner) + $c.MR) $fc
    $parts = @(@("Appliques : $Applied", 'Green'), @("En echec : $Failed", 'Red'), @("Ignores : $Ignored", 'DarkGray'), @("Bloques : $Blocked", 'Yellow'))
    $len = ($parts | ForEach-Object { $_[0].Length + 3 } | Measure-Object -Sum).Sum
    Write-UIText $c.V $fc -NoNewline
    Write-UIText ' ' '' -NoNewline
    foreach ($p in $parts) { Write-UIText $p[0] $p[1] -NoNewline; Write-UIText '   ' '' -NoNewline }
    Write-UIText (' ' * [Math]::Max(0, $inner - 1 - $len)) '' -NoNewline
    Write-UIText $c.V $fc
    if (-not $Simulation) {
        $tot = $Compliant + $NonCompliant
        $cc = if ($NonCompliant -gt 0) { 'Red' } else { 'Green' }
        Write-UIBoxLine ("Verification : {0} conforme(s) sur {1}" -f $Compliant, $tot) $cc $fc $inner
    }
    $items = @(@('Duree  ', $durTxt), @('Rapport', $ReportPath), @('Dossier', $OutDir))
    $maxVal = $inner - 4 - 10
    $below = [System.Collections.Generic.List[string]]::new()
    foreach ($it in $items) {
        if (-not $it[1]) { continue }
        $val = [string]$it[1]
        # Un chemin trop long pour le cadre est affiche en entier sous le cadre, jamais coupe
        if (($it[0].Trim() -in 'Rapport', 'Dossier') -and $val.Length -gt $maxVal) { $below.Add("$($it[0].Trim()) : $val"); $val = '(chemin complet sous le cadre)' }
        $lines = Split-UIText $val $maxVal
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $lab = if ($i -eq 0) { "$($it[0]) : " } else { '          ' }
            $pad = ' ' * [Math]::Max(0, $inner - 2 - $lab.Length - $lines[$i].Length)
            Write-UIText $c.V $fc -NoNewline
            Write-UIText (' ' + $lab) 'DarkGray' -NoNewline
            Write-UIText ($lines[$i] + $pad + ' ') 'White' -NoNewline
            Write-UIText $c.V $fc
        }
    }
    Write-UIText ($c.BL + ($c.H * $inner) + $c.BR) $fc
    foreach ($l in $below) { Write-UIText ('  ' + $l) 'White' }
    if (-not $Simulation) {
        Write-UIText '  Aucun secret n''a ete ecrit sur disque : les identifiants generes sont restes en memoire et ont ete transmis directement a Cloudiway.' 'DarkGray'
    }
    Write-UIText ''
}
