# ui.ps1 - presentation console (affichage uniquement, via Write-Host ; aucune sortie dans le pipeline).
# Ne se connecte a rien. Aucune fonction ne leve d'exception d'affichage.
# Depend de $script:AppName / AppVersion / AppDate / AppContact (lib\common.ps1), avec valeurs de repli.

$script:UI = $null

function Initialize-UI {
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }

    $unicode = $false
    if (-not $redirected) {
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
        default                              { 'INFO' }
    }
}

$script:UILevels = @{
    OK   = @{ Label = '[ OK ]'; Color = 'Green' }
    WARN = @{ Label = '[WARN]'; Color = 'Yellow' }
    FAIL = @{ Label = '[FAIL]'; Color = 'Red' }
    INFO = @{ Label = '[INFO]'; Color = 'Cyan' }
    WAIT = @{ Label = '[WAIT]'; Color = 'Magenta' }
}

function Write-UIBoxLine([string]$Text, [string]$TextColor, [string]$FrameColor, [int]$Inner) {
    $c = (Get-UIState).C
    $pad = ' ' * [Math]::Max(0, $Inner - 2 - $Text.Length)
    Write-UIText $c.V $FrameColor -NoNewline
    Write-UIText (' ' + $Text + $pad + ' ') $TextColor -NoNewline
    Write-UIText $c.V $FrameColor
}

function Show-Banner([string]$Role, [string]$TenantId, [string]$User, [string]$OutDir, [switch]$RoleExplicit) {
    $ui = Get-UIState; $c = $ui.C
    $inner = $ui.Width - 2
    $fc = 'Cyan'
    $name = Get-UIApp 'AppName' '3SR - Collecte de donnees'
    $ver  = Get-UIApp 'AppVersion' '1.2'
    $date = Get-UIApp 'AppDate' '31/10/2026'
    $mail = Get-UIApp 'AppContact' 'votre contact 3SR'
    # La ligne de role dit quel argument la determine (et si c'est la valeur par defaut)
    $roleTxt = switch ($Role) {
        'Source' { 'Source   (option -Role Source' + $(if ($RoleExplicit) { '' } else { ', valeur par defaut' }) + ') - tenant a migrer : volumetries completes' }
        'Target' { 'Cible    (option -Role Target) - tenant de destination : conflits et securite' }
        default  { $Role }
    }

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
    Write-UIText ($c.ML + ($c.Line * $inner) + $c.MR) $fc
    $items = @(
        @('Role   ', $roleTxt), @('Tenant ', $TenantId), @('Compte ', $User), @('Sortie ', $OutDir)
    )
    $maxVal = $inner - 4 - 9
    $below = [System.Collections.Generic.List[string]]::new()
    foreach ($it in $items) {
        if (-not $it[1]) { continue }
        $val = [string]$it[1]
        # Un chemin trop long pour le cadre n'est jamais coupe au milieu : il est affiche en entier sous le cadre
        if ($it[0].Trim() -eq 'Sortie' -and $val.Length -gt $maxVal) { $below.Add("Sortie : $val"); $val = '(chemin complet sous le cadre)' }
        $lines = Split-UIText $val $maxVal
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $lab = if ($i -eq 0) { "$($it[0]): " } else { '         ' }
            $pad = ' ' * [Math]::Max(0, $inner - 2 - $lab.Length - $lines[$i].Length)
            Write-UIText $c.V $fc -NoNewline
            Write-UIText (' ' + $lab) 'DarkGray' -NoNewline
            Write-UIText ($lines[$i] + $pad + ' ') 'White' -NoNewline
            Write-UIText $c.V $fc
        }
    }
    Write-UIText ($c.BL + ($c.H * $inner) + $c.BR) $fc
    foreach ($l in $below) { Write-UIText ('  ' + $l) 'White' }
    Write-UIText ''
}

# Options du script et difference Source / Cible (affiche juste apres la banniere). Affichage seulement ; ne decrit que ce que le code fait
# (voir les tests IsSource dans lib\collect-*.ps1).
function Show-Usage {
    $ui = Get-UIState; $c = $ui.C
    $lw = 24
    $dw = [Math]::Max(20, $ui.Width - 4 - $lw - 1)
    Write-UIText 'Options du script' 'Cyan'
    Write-UIText ($c.Line * 17) 'DarkCyan'
    $opts = @(
        @('-TenantId <GUID>', 'OBLIGATOIRE. Identifiant (GUID) du tenant a collecter.'),
        @('-User <UPN>', 'OBLIGATOIRE. Compte administrateur qui se connecte ; tout autre compte est refuse.'),
        @('-Role Source|Target', 'Role du tenant (defaut : Source). Voir le tableau ci-dessous.'),
        @('-Parts <liste>', 'Parties a collecter (defaut : toutes) : Identity, Devices, Security, Dns, Exchange, SharePoint.'),
        @('-OutDir <dossier>', 'Dossier de sortie (defaut : collecte-resultats a cote du script).'),
        @('-InstallMissingModules', 'Installe sans question les modules PowerShell manquants (profil utilisateur).')
    )
    foreach ($o in $opts) {
        $dl = Split-UIText $o[1] $dw
        for ($i = 0; $i -lt $dl.Count; $i++) {
            $lab = if ($i -eq 0) { $o[0] } else { '' }
            Write-UIText ('  ' + $lab.PadRight($lw) + ' ') 'White' -NoNewline
            Write-UIText $dl[$i] 'Gray'
        }
    }
    Write-UIText ''
    Write-UIText 'Source versus Cible' 'Cyan'
    Write-UIText ($c.Line * 19) 'DarkCyan'
    $lw2 = 8
    $dw2 = [Math]::Max(20, $ui.Width - 4 - $lw2 - 1)
    $roles = @(
        @('Source', 'statistiques de boites et archives, permissions, listes de distribution avec membres, contacts, invites, nombre de membres des groupes, canaux Teams, rapports d''usage, OneDrive et sites avec tailles.'),
        @('Cible', 'liste legere des boites, tous les destinataires (recipients.csv), URL et titres de sites sans tailles ni OneDrive.'),
        @('Commun', 'identites, licences, groupes, domaines, postes, securite, DNS, flux de messagerie, EWS.')
    )
    foreach ($r in $roles) {
        $dl = Split-UIText $r[1] $dw2
        for ($i = 0; $i -lt $dl.Count; $i++) {
            $lab = if ($i -eq 0) { $r[0] } else { '' }
            Write-UIText ('  ' + $lab.PadRight($lw2) + ' ') 'White' -NoNewline
            Write-UIText $dl[$i] 'Gray'
        }
    }
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

function Show-OverallProgress([int]$Done, [int]$Total, [string]$Label = '') {
    try {
        $pct = if ($Total -gt 0) { [Math]::Min(100, [Math]::Max(0, [int](100 * $Done / $Total))) } else { 0 }
        Write-Progress -Id 5 -Activity (Get-UIApp 'AppName' 'Collecte') -Status ("{0}/{1} - {2}" -f $Done, $Total, $Label) -PercentComplete $pct
    } catch { }
}

function Complete-OverallProgress {
    try { Write-Progress -Id 5 -Activity (Get-UIApp 'AppName' 'Collecte') -Completed } catch { }
}

function Write-Hint([string]$Text) {
    $ui = Get-UIState
    foreach ($l in (Split-UIText $Text ($ui.Width - 6))) {
        Write-UIText ('  ' + $ui.C.Bullet + ' ' + $l) 'DarkGray'
    }
}

# Conseil en clair pour un element de capabilities (Part, Item, Status, Detail). Retourne { Unavailable [bool]; Advice [string] }.
# Unavailable = element OPTIONNEL refuse pour une raison de licence ou de role : reste un KO dans le journal, mais le bilan le presente
# comme "non disponible" (et non comme une erreur du script). Seuls des KO peuvent etre "non disponibles".
function Get-CapAdvice($Cap) {
    $p = "$($Cap.Part)"; $i = "$($Cap.Item)"; $d = "$($Cap.Detail)"; $st = "$($Cap.Status)"
    $res = @{ Unavailable = $false; Advice = '' }
    $ko = ($st -eq 'KO')
    $denied = ($d -match 'HTTP (400|401|403|404)|Refus|Forbidden|not authorized|Authorization|Insufficient|denied|licen|not applicable|Non disponible|premium')
    if ($p -eq 'Devices' -and $i -match '^(Intune|Autopilot|inventaire )') {
        $res.Advice = 'Intune non licencie ou role Intune manquant (Administrateur Intune ou Lecteur general) : inventaire optionnel, le reste de la collecte n''est pas affecte.'
        $res.Unavailable = ($ko -and $denied)
    }
    elseif ($i -match 'signInActivity') {
        $res.Advice = 'Licence Entra ID P1 ou P2 absente : les dernieres connexions des comptes ne sont pas disponibles.'
        $res.Unavailable = ($ko -and $denied)
    }
    elseif ($i -match 'Conditional Access|Inscription MFA|Methodes d|Authorization policy|Cross-tenant') {
        $res.Advice = 'Licence Entra ID P1 ou P2 absente, ou role Lecteur de securite / Lecteur general manquant.'
        $res.Unavailable = ($ko -and $denied)
    }
    elseif ($i -match 'Secure Score') {
        $res.Advice = 'Role Lecteur de securite manquant, ou score de securite non disponible sur ce tenant.'
        $res.Unavailable = ($ko -and $denied)
    }
    elseif ($p -eq 'Identity' -and $i -match '^report ') {
        $res.Advice = 'Rapport d''usage non disponible : role Lecteur de rapports manquant, ou rapports non actives sur ce tenant.'
        $res.Unavailable = ($ko -and $denied)
    }
    elseif ($i -match 'reportSettings') {
        $res.Advice = 'Rapports d''usage anonymises par un reglage du tenant (Centre d''administration Microsoft 365 > Parametres > Parametres de l''organisation > Services > Rapports) : les noms sont masques, les volumes par personne ne sont pas exploitables.'
        $res.Unavailable = ($ko -and $denied)
    }
    elseif ($i -match 'directoryRoles|Roles annuaire') {
        $res.Advice = 'Certains roles d''annuaire ne sont pas lisibles avec ce compte (role Lecteur general conseille).'
        $res.Unavailable = ($ko -and $denied)
    }
    elseif ($i -match 'groups membres|teams channels') {
        $res.Advice = 'Droit de lecture insuffisant sur certains groupes ou equipes (role Lecteur general conseille) : comptes de membres ou canaux incomplets.'
    }
    elseif ($p -eq 'Exchange' -and $i -match '^(Acces|Connexion|Module|Compte)') {
        $res.Advice = 'Relancer avec un compte Administrateur Exchange, Lecteur general ou Administrateur general (voir le guide, Droits necessaires).'
    }
    elseif ($p -eq 'SharePoint' -and $i -match '^(Acces|Connect|Module)') {
        $res.Advice = 'Relancer avec un compte Administrateur SharePoint ou Administrateur general ; la fenetre de connexion expire au bout de 2 minutes.'
    }
    elseif ($i -match 'Statistiques des boites') {
        $res.Advice = 'Certaines boites n''ont pas pu etre mesurees (boites systeme ou inaccessibles) ; elles sont signalees dans mailboxes.csv (StatsRead = False).'
    }
    elseif ($i -match 'CodeSortieWorker') {
        $res.Advice = 'Un processus de collecte s''est termine avec un code different de 0 : voir run.log.'
    }
    elseif ($p -eq 'Dns') {
        $res.Advice = 'Le resolveur DNS du poste n''a pas repondu pour certains domaines : relancer la partie Dns depuis un autre reseau si besoin.'
    }
    [pscustomobject]$res
}

# Liste des elements en KO puis PARTIEL (une ligne chacun : "Partie / Item : detail"), avec conseil en clair pour les causes connues.
# Les KO d'elements optionnels (licence ou role) sont presentes comme "non disponibles" : ce n'est pas une erreur du script.
function Show-IssueList($Caps) {
    $ui = Get-UIState
    $caps = @($Caps | Where-Object { $_.Status -in 'KO', 'PARTIEL' })
    if ($caps.Count -eq 0) { return }
    $recs = foreach ($cp in $caps) {
        $a = Get-CapAdvice $cp
        [pscustomobject]@{ Cap = $cp; Advice = $a.Advice; Kind = $(if ($cp.Status -eq 'PARTIEL') { 'PARTIEL' } elseif ($a.Unavailable) { 'NA' } else { 'KO' }) }
    }
    $sections = @(
        @{ Kind = 'KO'; Label = '[KO]'; Color = 'Red'; Title = 'Elements en erreur' },
        @{ Kind = 'PARTIEL'; Label = '[PARTIEL]'; Color = 'Yellow'; Title = 'Elements partiels' },
        @{ Kind = 'NA'; Label = '[NON DISPO]'; Color = 'Cyan'; Title = 'Elements non disponibles sur ce tenant (licence ou role manquant : ce n''est pas une erreur du script)' }
    )
    $left = 40
    foreach ($sec in $sections) {
        $grp = @($recs | Where-Object Kind -eq $sec.Kind)
        if ($grp.Count -eq 0) { continue }
        Write-UIText ''
        foreach ($l in (Split-UIText ("{0} ({1})" -f $sec.Title, $grp.Count) ($ui.Width - 2))) { Write-UIText ('  ' + $l) $sec.Color }
        foreach ($r in $grp) {
            if ($left -le 0) { break }
            $left--
            $txt = ("{0} / {1}" -f $r.Cap.Part, $r.Cap.Item)
            if ($r.Cap.Detail) { $d = [string]$r.Cap.Detail; $txt += ' : ' + $d.Substring(0, [Math]::Min(200, $d.Length)) }
            $w = $ui.Width - 4 - 13
            $lines = Split-UIText $txt $w
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($i -eq 0) { Write-UIText ('  ' + $sec.Label.PadRight(12) + ' ') $sec.Color -NoNewline } else { Write-UIText (' ' * 15) '' -NoNewline }
                Write-UIText $lines[$i] ''
            }
            if ($r.Advice) {
                foreach ($l in (Split-UIText $r.Advice $w)) { Write-UIText ((' ' * 15) + $l) 'DarkGray' }
            }
        }
    }
    if ($left -le 0) { Write-UIText ''; Write-UIText '  (liste tronquee : voir capabilities.csv pour le detail complet)' 'DarkGray' }
    Write-UIText ''
}

function Show-FinalReport([int]$Ok, [int]$Partial, [int]$Ko, $Duration, [string]$ZipPath, [string]$OutDir, [int]$Unavailable = 0) {
    $ui = Get-UIState; $c = $ui.C
    $inner = $ui.Width - 2
    $realKo = [Math]::Max(0, $Ko - $Unavailable)
    $fc = if ($realKo -gt 0) { 'Red' } elseif ($Ko -gt 0 -or $Partial -gt 0) { 'Yellow' } else { 'Green' }
    $durTxt = if ($Duration -is [timespan]) { '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds } else { [string]$Duration }
    $verdict = if ($realKo -gt 0) { 'Collecte terminee avec des elements en erreur' }
    elseif ($Ko -gt 0) { 'Collecte terminee : certains elements non disponibles sur ce tenant' }
    elseif ($Partial -gt 0) { 'Collecte terminee avec des elements partiels' }
    else { 'Collecte terminee avec succes' }

    Write-UIText ''
    Write-UIText ($c.TL + ($c.H * $inner) + $c.TR) $fc
    foreach ($vl in (Split-UIText $verdict ($inner - 4))) { Write-UIBoxLine $vl $fc $fc $inner }
    Write-UIText ($c.ML + ($c.Line * $inner) + $c.MR) $fc
    # compteurs colores sur une ligne
    $parts = @(@("OK : $Ok", 'Green'), @("Partiels : $Partial", 'Yellow'), @("KO : $Ko", 'Red'))
    $len = ($parts | ForEach-Object { $_[0].Length + 4 } | Measure-Object -Sum).Sum
    Write-UIText $c.V $fc -NoNewline
    Write-UIText ' ' '' -NoNewline
    foreach ($p in $parts) { Write-UIText $p[0] $p[1] -NoNewline; Write-UIText '    ' '' -NoNewline }
    Write-UIText (' ' * [Math]::Max(0, $inner - 1 - $len)) '' -NoNewline
    Write-UIText $c.V $fc
    if ($Unavailable -gt 0) { Write-UIBoxLine ("dont $Unavailable non disponible(s) : licence ou role manquant sur ce tenant") 'Gray' $fc $inner }
    $items = @(@('Duree  ', $durTxt), @('Archive', $ZipPath), @('Dossier', $OutDir))
    $maxVal = $inner - 4 - 10
    $below = [System.Collections.Generic.List[string]]::new()
    foreach ($it in $items) {
        if (-not $it[1]) { continue }
        $val = [string]$it[1]
        # Un chemin trop long pour le cadre n'est jamais coupe au milieu d'un mot : il est affiche en entier sous le cadre
        if (($it[0].Trim() -in 'Archive', 'Dossier') -and $val.Length -gt $maxVal) { $below.Add("$($it[0].Trim()) : $val"); $val = '(chemin complet sous le cadre)' }
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
    Write-UIText ''
}
