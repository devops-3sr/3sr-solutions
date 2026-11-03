<#
.SYNOPSIS
    Point d'entree unique des tests de cloudiway-collector. Hors ligne : ni Azure, ni Microsoft 365, ni reseau.
.DESCRIPTION
    Usage : pwsh -NoProfile -File tests\run-tests.ps1 [-SkipPester]
    Etapes :
      1. syntaxe (ParseFile), BOM UTF-8 et fins de ligne CRLF de chaque .ps1 ;
      2. noms de fichiers et dossiers en minuscules ;
      3. GUID : tout GUID present dans un fichier texte doit figurer dans tests\allowed-guids.txt ;
      4. lanceur : essai a blanc (-SelfTest) sous Windows PowerShell 5.1 quand il est disponible ;
      5. banc maison test-preflight.ps1 puis test-collectors.ps1 (cmdlets simulees, aucune connexion) ;
      6. tests Pester 5 (tests\common.tests.ps1) quand Pester 5 est installe ; sans Pester, cette etape est ignoree.
    Ecrit uniquement dans le dossier temporaire. Code de sortie : 0 si tout est vert, 1 sinon.
#>
#Requires -Version 7.0
[CmdletBinding()]
param([switch]$SkipPester)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pwshExe = (Get-Process -Id $PID).Path
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Step, [string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Step = $Step; Status = $Status; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'SKIP' { 'Yellow' } default { 'Red' } }
    Write-Host ("[{0}] {1}{2}" -f $Status, $Step, $(if ($Detail) { " - $Detail" } else { '' })) -ForegroundColor $color
}

$allFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File)
$rel = { param($f) $f.FullName.Substring($root.Length + 1) -replace '\\', '/' }

# 1. syntaxe, BOM, CRLF
$bad = @()
foreach ($f in @($allFiles | Where-Object Extension -eq '.ps1')) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { $bad += "$(& $rel $f) : syntaxe ($($errs[0].Message))" }
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) { $bad += "$(& $rel $f) : BOM UTF-8 absent" }
    $txt = [IO.File]::ReadAllText($f.FullName)
    if (($txt -replace "`r`n", '') -match "[`r`n]") { $bad += "$(& $rel $f) : fins de ligne non CRLF" }
}
if ($bad.Count -eq 0) { Add-Result 'Syntaxe, BOM UTF-8 et CRLF des .ps1' 'PASS' } else { Add-Result 'Syntaxe, BOM UTF-8 et CRLF des .ps1' 'FAIL' ($bad -join ' | ') }

# 2. noms en minuscules
$upper = @($allFiles | Where-Object { (& $rel $_) -cmatch '[A-Z]' } | ForEach-Object { & $rel $_ })
if ($upper.Count -eq 0) { Add-Result 'Noms de fichiers en minuscules' 'PASS' } else { Add-Result 'Noms de fichiers en minuscules' 'FAIL' ($upper -join ', ') }

# 3. GUID autorises
$allowedFile = Join-Path $PSScriptRoot 'allowed-guids.txt'
$allowed = @{}
foreach ($l in (Get-Content -LiteralPath $allowedFile -Encoding utf8)) { if ($l.Trim()) { $allowed[$l.Trim().ToLowerInvariant()] = $true } }
$guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$unknown = @()
foreach ($f in @($allFiles | Where-Object { $_.Extension -in '.ps1', '.md', '.cmd', '.txt' -and $_.FullName -ne $allowedFile })) {
    $txt = [IO.File]::ReadAllText($f.FullName)
    foreach ($m in [regex]::Matches($txt, $guidRx)) { if (-not $allowed.ContainsKey($m.Value.ToLowerInvariant())) { $unknown += "$(& $rel $f) : $($m.Value)" } }
}
if ($unknown.Count -eq 0) { Add-Result "GUID : tous dans allowed-guids.txt ($($allowed.Count) valeurs)" 'PASS' } else { Add-Result 'GUID : tous dans allowed-guids.txt' 'FAIL' (($unknown | Select-Object -Unique) -join ' | ') }

# 4. lanceur sous Windows PowerShell 5.1
$ps51 = Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ps51) {
    $launcher = Join-Path $root 'cloudiway-collector-launcher.ps1'
    $o = & $ps51.Source -NoProfile -ExecutionPolicy Bypass -File $launcher -SelfTest -TenantId 00000000-0000-0000-0000-000000000000 -User admin@contoso.com 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $txt = $o -join "`n"
    if ($code -eq 0 -and $txt -match '\[SelfTest\] version' -and $txt -match 'nb arguments transmis : 4' -and $txt -match 'cloudiway-collector\.ps1') { Add-Result 'Lanceur (Windows PowerShell 5.1, -SelfTest)' 'PASS' }
    else { Add-Result 'Lanceur (Windows PowerShell 5.1, -SelfTest)' 'FAIL' "code $code ; $($txt.Substring(0, [Math]::Min(300, $txt.Length)))" }
} else { Add-Result 'Lanceur (Windows PowerShell 5.1, -SelfTest)' 'SKIP' 'powershell.exe indisponible' }

# 5. bancs maison (processus separes)
foreach ($bench in 'test-preflight.ps1', 'test-collectors.ps1') {
    $log = Join-Path ([IO.Path]::GetTempPath()) ("cwbench-{0}-{1}.log" -f $bench, [guid]::NewGuid().ToString('N').Substring(0, 6))
    & $pwshExe -NoProfile -File (Join-Path $PSScriptRoot $bench) *> $log
    $code = $LASTEXITCODE
    $lines = @(Get-Content -LiteralPath $log -Encoding utf8)
    $total = @($lines | Where-Object { $_ -match '^(TOTAL :|Resultat :)' } | Select-Object -Last 1)
    $failLines = @($lines | Where-Object { $_ -match '^\s*FAIL ' } | Select-Object -First 15)
    if ($code -eq 0 -and $total.Count -eq 1 -and $failLines.Count -eq 0) { Add-Result "Banc $bench" 'PASS' $total[0] }
    else {
        Add-Result "Banc $bench" 'FAIL' ("code $code ; " + $(if ($total.Count) { $total[0] } else { 'aucun total affiche' }))
        $failLines | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        Write-Host "      journal complet : $log" -ForegroundColor Yellow
        continue
    }
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
}

# 6. Pester 5 (facultatif)
if ($SkipPester) { Add-Result 'Pester (common.tests.ps1)' 'SKIP' 'option -SkipPester' }
else {
    $pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -ge 5 } | Sort-Object Version -Descending | Select-Object -First 1
    if ($pester) {
        try {
            Import-Module $pester.Path -Force
            $r = Invoke-Pester -Path (Join-Path $PSScriptRoot 'common.tests.ps1') -PassThru -Output None
            if ($r.FailedCount -eq 0 -and $r.PassedCount -gt 0) { Add-Result 'Pester (common.tests.ps1)' 'PASS' "$($r.PassedCount) tests, Pester $($pester.Version)" }
            else { Add-Result 'Pester (common.tests.ps1)' 'FAIL' "$($r.FailedCount) echec(s), $($r.PassedCount) reussite(s)" }
        } catch { Add-Result 'Pester (common.tests.ps1)' 'FAIL' $_.Exception.Message }
    } else { Add-Result 'Pester (common.tests.ps1)' 'SKIP' 'Pester 5 non installe (facultatif)' }
}

$nFail = @($results | Where-Object Status -eq 'FAIL').Count
Write-Host ''
Write-Host ("RESULTAT : {0} etape(s), {1} PASS, {2} FAIL, {3} SKIP" -f $results.Count, @($results | Where-Object Status -eq 'PASS').Count, $nFail, @($results | Where-Object Status -eq 'SKIP').Count) -ForegroundColor $(if ($nFail) { 'Red' } else { 'Green' })
exit $(if ($nFail) { 1 } else { 0 })
