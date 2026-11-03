# cloudiway-collector-launcher.ps1 - Lanceur de CloudiwayCollector (compatible Windows PowerShell 5.1 ET PowerShell 7)
#
# Role : verifier / installer PowerShell 7, puis relancer cloudiway-collector.ps1 sous pwsh
#        avec tous les arguments recus. Ne contient volontairement AUCUNE syntaxe PowerShell 7
#        (pas de ??, ?., ternaire, &&, ||). Fichier ASCII uniquement.
#
# Ecritures : Unblock-File sur le package, et l'installation de PowerShell 7 SI l'utilisateur accepte.
# Aucun secret lu ni ecrit. Aucun acces reseau hors installation winget demandee.

param(
    [switch]$SelfTest,                                  # parametre cache : affiche ce qui serait fait, sans rien lancer
    [Parameter(ValueFromRemainingArguments = $true)]
    $PassThru
)

$ErrorActionPreference = 'Continue'

$AppName    = '3SR - Collecte de donnees'
$AppVersion = '1.2'
$AppDate    = '31/10/2026'
$AppContact = 'votre contact 3SR'
$MainScript = Join-Path $PSScriptRoot 'cloudiway-collector.ps1'

# ------------------------------------------------------------------ (a) banniere
function Show-LauncherBanner {
    $line = '+' + ('-' * 58) + '+'
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host ('|  {0,-56}|' -f $AppName) -ForegroundColor Cyan
    Write-Host ('|  {0,-56}|' -f ('Version ' + $AppVersion + '  -  ' + $AppDate)) -ForegroundColor Cyan
    Write-Host ('|  {0,-56}|' -f ('Contact : ' + $AppContact)) -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ''
}

# ------------------------------------------------------------------ (b) deblocage
function Unblock-Package {
    try {
        Get-ChildItem -Path $PSScriptRoot -Recurse -File -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    } catch {
        # silencieux : le deblocage est un confort, pas une obligation
    }
}

# ------------------------------------------------------------------ (c) recherche de pwsh
function Get-PwshVersion {
    param([string]$Path)
    # Retourne un [version] ou $null si le fichier ne s'execute pas (ex. alias WindowsApps casse).
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
        $out = & $Path -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
        $txt = ($out | Select-Object -First 1)
        if (-not $txt) { return $null }
        $txt = ([string]$txt).Trim()
        # retire un eventuel suffixe de pre-version (7.5.0-preview.1)
        $m = [regex]::Match($txt, '^\d+(\.\d+){1,3}')
        if (-not $m.Success) { return $null }
        return [version]$m.Value
    } catch {
        return $null
    }
}

function Find-Pwsh {
    # Retourne @{ Path; Version } du premier pwsh >= 7.0 trouve, sinon $null.
    $candidates = New-Object System.Collections.ArrayList

    try {
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { [void]$candidates.Add($cmd.Source) }
    } catch { }

    if ($env:ProgramFiles) {
        [void]$candidates.Add((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'))
    }
    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'))
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\pwsh.exe'))
    }

    try {
        $reg = 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
        if (Test-Path $reg) {
            foreach ($k in (Get-ChildItem $reg -ErrorAction SilentlyContinue)) {
                $loc = (Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue).InstallLocation
                if ($loc) { [void]$candidates.Add((Join-Path $loc 'pwsh.exe')) }
            }
        }
    } catch { }

    $seen = @{}
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $key = $c.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $v = Get-PwshVersion -Path $c
        if ($v -and $v.Major -ge 7) {
            return @{ Path = $c; Version = $v }
        }
    }
    return $null
}

# ------------------------------------------------------------------ (d) installation
function Read-YesNo {
    param([string]$Question)
    while ($true) {
        try { $a = Read-Host ($Question + ' (O/N)') } catch { return $false }
        if ($null -eq $a) { return $false }
        $a = $a.Trim().ToUpperInvariant()
        if ($a -eq 'O' -or $a -eq 'OUI' -or $a -eq 'Y' -or $a -eq 'YES') { return $true }
        if ($a -eq 'N' -or $a -eq 'NON' -or $a -eq 'NO') { return $false }
        Write-Host 'Repondez par O (oui) ou N (non).'
    }
}

function Install-Pwsh7 {
    # Retourne $true si une installation a ete tentee et s'est terminee sans erreur.
    Write-Host ''
    Write-Host 'PowerShell 7 est necessaire.' -ForegroundColor Yellow
    Write-Host 'Pourquoi : cet outil utilise des fonctions modernes qui n''existent pas dans le'
    Write-Host 'PowerShell fourni avec Windows (version 5). PowerShell 7 s''installe a cote, sans'
    Write-Host 'rien remplacer ni modifier du systeme existant.'
    Write-Host ''

    $winget = $null
    try { $winget = Get-Command winget -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }

    if (-not $winget) {
        Write-Host 'L''outil d''installation automatique (winget) n''est pas disponible sur ce poste.' -ForegroundColor Yellow
        Write-Host 'Telechargez PowerShell 7 ici :'
        Write-Host '    https://aka.ms/powershell-release?tag=stable'
        Write-Host ''
        Write-Host 'Installez PowerShell 7 puis relancez cloudiway-collector.cmd.'
        return $false
    }

    Write-Host 'Installation proposee (winget) :'
    Write-Host '    winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements'
    Write-Host 'Attention : Windows peut afficher une fenetre de controle de compte utilisateur (UAC)'
    Write-Host 'demandant des droits administrateur. Il faut alors l''accepter.' -ForegroundColor Yellow
    Write-Host ''
    if (-not (Read-YesNo 'Installer PowerShell 7 maintenant ?')) {
        Write-Host ''
        Write-Host 'Installation refusee. Vous pouvez aussi telecharger PowerShell 7 ici :'
        Write-Host '    https://aka.ms/powershell-release?tag=stable'
        Write-Host 'puis relancer cloudiway-collector.cmd.'
        return $false
    }

    try {
        & winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements
        $code = $LASTEXITCODE
    } catch {
        Write-Host ('Echec du lancement de winget : ' + $_.Exception.Message) -ForegroundColor Red
        return $false
    }
    # 0 = installe ; -1978335189 (0x8A15002B) = deja installe / aucune mise a jour : on re-teste de toute facon
    if ($code -ne 0 -and $code -ne -1978335189) {
        Write-Host ('winget a retourne le code ' + $code + '.') -ForegroundColor Red
        return $false
    }
    return $true
}

# ------------------------------------------------------------------ (e) construction de la ligne de commande
function ConvertTo-QuotedArg {
    # Quoting conforme a CommandLineToArgvW : valeurs avec espaces / guillemets preservees.
    param([string]$Arg)
    if ($null -eq $Arg) { $Arg = '' }
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') {
            $bs++
        } elseif ($ch -eq '"') {
            [void]$sb.Append('\', ($bs * 2 + 1))
            [void]$sb.Append('"')
            $bs = 0
        } else {
            if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append('\', ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-ChildArguments {
    param([string]$Pwsh, $Forwarded)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('-NoProfile')
    [void]$parts.Add('-ExecutionPolicy')
    [void]$parts.Add('Bypass')
    [void]$parts.Add('-File')
    [void]$parts.Add($MainScript)
    foreach ($a in @($Forwarded)) {
        if ($null -ne $a) { [void]$parts.Add([string]$a) }
    }
    $quoted = @()
    foreach ($p in $parts) { $quoted += (ConvertTo-QuotedArg $p) }
    return ($quoted -join ' ')
}

# ================================================================== programme
Show-LauncherBanner
Unblock-Package

$pwsh = Find-Pwsh

if (-not $pwsh) {
    if ($SelfTest) {
        Write-Host '[SelfTest] PowerShell 7 introuvable : le lanceur proposerait l''installation (rien n''est installe en mode SelfTest).'
        exit 0
    }
    $installed = Install-Pwsh7
    if (-not $installed) { exit 2 }
    # le PATH du processus courant n'est pas rafraichi : on reteste les chemins connus
    $pwsh = Find-Pwsh
    if (-not $pwsh) {
        Write-Host ''
        Write-Host 'PowerShell 7 a ete installe mais reste introuvable depuis cette fenetre.' -ForegroundColor Yellow
        Write-Host 'Fermez cette fenetre puis relancez cloudiway-collector.cmd.'
        exit 3
    }
}

Write-Host ('PowerShell 7 detecte : ' + $pwsh.Path + '  (version ' + $pwsh.Version + ')') -ForegroundColor Green

if (-not (Test-Path -LiteralPath $MainScript -PathType Leaf)) {
    Write-Host ('Script principal introuvable : ' + $MainScript) -ForegroundColor Red
    exit 4
}

$childArgs = Get-ChildArguments -Pwsh $pwsh.Path -Forwarded $PassThru

if ($SelfTest) {
    Write-Host ''
    Write-Host ('[SelfTest] Version de PowerShell du lanceur : ' + $PSVersionTable.PSVersion)
    Write-Host ('[SelfTest] pwsh        : ' + $pwsh.Path)
    Write-Host ('[SelfTest] version     : ' + $pwsh.Version)
    Write-Host ('[SelfTest] nb arguments transmis : ' + @($PassThru).Count)
    $i = 0
    foreach ($a in @($PassThru)) { Write-Host ('[SelfTest]   arg[' + $i + '] = <' + $a + '>'); $i++ }
    Write-Host '[SelfTest] commande qui serait lancee :'
    Write-Host ('  "' + $pwsh.Path + '" ' + $childArgs)
    exit 0
}

Write-Host 'Lancement de la collecte...'
Write-Host ''

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $pwsh.Path
    $psi.Arguments = $childArgs
    $psi.UseShellExecute = $false          # herite de la console courante
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    $exit = $proc.ExitCode
} catch {
    Write-Host ('Impossible de lancer la collecte : ' + $_.Exception.Message) -ForegroundColor Red
    exit 5
}
exit $exit
