# Regles de publication du depot public. Echoue (code 1) si une regle n'est pas respectee.
# Lancement local : pwsh -File .github/scripts/controle-depot.ps1   (depuis la racine du depot)

$ErrorActionPreference = 'Stop'
$echecs = New-Object System.Collections.Generic.List[string]
function Add-Echec([string]$Regle, [string]$Detail) { $script:echecs.Add("[$Regle] $Detail") }

$fichiers = @(git ls-files)
if ($fichiers.Count -eq 0) { throw 'Aucun fichier suivi par git.' }

# Les scripts de la CI (dossier .github) ne sont pas des livrables clients.
$livrablesPs1 = @($fichiers | Where-Object { $_ -match '\.ps1$' -and $_ -notlike '.github/*' })

# 1. Scripts livres : BOM UTF-8 obligatoire (Windows PowerShell 5.1 lit sinon les accents en ANSI)
foreach ($f in $livrablesPs1) {
    $o = [System.IO.File]::ReadAllBytes($f)
    if ($o.Length -lt 3 -or $o[0] -ne 0xEF -or $o[1] -ne 0xBB -or $o[2] -ne 0xBF) { Add-Echec 'bom' "$f n'a pas de BOM UTF-8" }
}

# 2. Noms de fichiers des scripts, lanceurs et guides : minuscules
foreach ($f in $fichiers | Where-Object { $_ -match '\.(ps1|cmd)$' -or $_ -match '-guide-(fr|en)\.md$' }) {
    $nom = Split-Path $f -Leaf
    if ($nom -cmatch '[A-Z]') { Add-Echec 'minuscules' "$f : le nom doit etre en minuscules" }
}

# 3. Chaque guide francais a son equivalent anglais, et inversement
foreach ($f in $fichiers | Where-Object { $_ -match '-guide-fr\.md$' }) {
    $en = $f -replace '-guide-fr\.md$', '-guide-en.md'
    if ($en -notin $fichiers) { Add-Echec 'guides' "$f n'a pas d'equivalent anglais ($en)" }
}
foreach ($f in $fichiers | Where-Object { $_ -match '-guide-en\.md$' }) {
    $fr = $f -replace '-guide-en\.md$', '-guide-fr.md'
    if ($fr -notin $fichiers) { Add-Echec 'guides' "$f n'a pas d'equivalent francais ($fr)" }
}

# 4. Identifiants GUID : uniquement ceux de la liste racine (.github/allowed-guids.txt) ou d'un
#    fichier allowed-guids.txt situe dans le dossier du fichier ou dans l'un de ses parents.
function Read-ListeGuid([string]$Chemin) {
    @(Get-Content $Chemin | ForEach-Object { ($_ -replace '#.*$', '').Trim().ToLowerInvariant() } | Where-Object { $_ })
}
$listes = @{}
foreach ($l in $fichiers | Where-Object { (Split-Path $_ -Leaf) -eq 'allowed-guids.txt' }) {
    $dossier = if ($l -eq '.github/allowed-guids.txt') { '' } else { (Split-Path $l -Parent).Replace('\', '/') }
    # Une liste placee dans un dossier tests/ vaut pour le dossier qui contient tests/.
    if ($dossier -eq 'tests') { $dossier = '' }
    elseif ($dossier -like '*/tests') { $dossier = $dossier.Substring(0, $dossier.Length - '/tests'.Length) }
    $listes[$dossier] = @($listes[$dossier]) + (Read-ListeGuid $l)
}
$motifGuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
foreach ($f in $fichiers | Where-Object { $_ -notmatch '\.(png|jpg|jpeg|gif|pdf|zip)$' -and (Split-Path $_ -Leaf) -ne 'allowed-guids.txt' }) {
    $autorises = @($listes[''])
    $parent = (Split-Path $f -Parent).Replace('\', '/')
    while ($parent) {
        if ($listes.ContainsKey($parent)) { $autorises += $listes[$parent] }
        $parent = (Split-Path $parent -Parent).Replace('\', '/')
    }
    $texte = Get-Content $f -Raw -Encoding UTF8
    if (-not $texte) { continue }
    foreach ($m in [regex]::Matches($texte, $motifGuid)) {
        if ($m.Value.ToLowerInvariant() -notin $autorises) { Add-Echec 'guid' "$f contient un identifiant non autorise : $($m.Value)" }
    }
}

# 5. Jetons SAS et signatures
foreach ($f in $fichiers | Where-Object { $_ -ne '.github/scripts/controle-depot.ps1' -and $_ -notmatch '\.(png|jpg|jpeg|gif|pdf|zip)$' }) {
    $texte = Get-Content $f -Raw -Encoding UTF8
    if ($texte -and $texte -match '[?&]sig=[A-Za-z0-9%+/=]{20,}') { Add-Echec 'sas' "$f contient une signature de jeton SAS" }
}

# 6. Fichiers qui ne doivent jamais etre suivis
foreach ($f in $fichiers | Where-Object { $_ -match '\.(pfx|p12|pem|key|jks|kdbx|tfstate)$' -or $_ -match '(^|/)local\.settings\.json$' -or $_ -match '(^|/)customers.*\.json$' -or $_ -match '(^|/)collecte-resultats/' -or $_ -match '(^|/)collecte-[^/]*\.zip$' }) {
    Add-Echec 'interdit' "$f ne doit pas etre publie"
}

if ($echecs.Count -gt 0) {
    $echecs | ForEach-Object { Write-Host "::error::$_" }
    Write-Host "$($echecs.Count) regle(s) non respectee(s)."
    exit 1
}
Write-Host "OK : $($fichiers.Count) fichiers verifies, toutes les regles sont respectees."
