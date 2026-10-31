# test-preflight.ps1 - tests hors ligne de lib\preflight.ps1 (stubs, aucun reseau, aucun Connect-*).
# Usage : pwsh -NoProfile -File tests\test-preflight.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\preflight.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert([string]$Name, [bool]$Cond, [string]$Info = '') {
    if ($Cond) { $script:Pass++; Write-Host "PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "FAIL  $Name  $Info" -ForegroundColor Red }
}

$tmpOut = Join-Path ([System.IO.Path]::GetTempPath()) ("cwtest-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpOut | Out-Null
$script:Ctx = @{ TenantId = 'x'; User = 'u@x.fr'; Role = 'Source'; IsSource = $true; InitialDomain = 'x.onmicrosoft.com'; Out = $tmpOut; Capabilities = [System.Collections.Generic.List[object]]::new() }
# Silence les traces console de Write-Log pendant les tests
function Write-Log([string]$Msg, [string]$Color = 'Gray') { }

# ---------- Simulation ----------
$script:Sim = $null
function Reset-Sim {
    $script:Sim = @{
        Available = @{}; Loaded = @{}; InstallFail = $null; InstallVersion = '9.9.9'; Installed = @()
        Answer = $true; Answers = $null; Asked = @()
        Net = @{}; Repo = 'Trusted'; NuGet = '2.8.5.208'; TrustSet = 0; NuGetInstalled = 0
        Graph = @(); GraphCalls = @(); Ctx = $null
        Fail = @{}
    }
    $script:Sim.Available['Microsoft.Graph.Authentication'] = @([pscustomobject]@{ Name = 'Microsoft.Graph.Authentication'; Version = [version]'2.25.0' })
    $script:Sim.Available['ExchangeOnlineManagement'] = @([pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.9.2' })
    $script:Sim.Available['Microsoft.Online.SharePoint.PowerShell'] = @([pscustomobject]@{ Name = 'Microsoft.Online.SharePoint.PowerShell'; Version = [version]'16.0.26000' })
}

function Get-Module { param([string]$Name, [switch]$ListAvailable, $ErrorAction)
    if ($ListAvailable) { return $script:Sim.Available[$Name] }
    return $script:Sim.Loaded[$Name]
}
function Install-Module { param([string]$Name, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber, $WarningAction, $ErrorAction)
    if ($script:Sim.InstallFail) { throw $script:Sim.InstallFail }
    $script:Sim.Installed += $Name
    $script:Sim.Available[$Name] = @([pscustomobject]@{ Name = $Name; Version = [version]$script:Sim.InstallVersion })
}
function Get-PSRepository { param($Name, $ErrorAction) [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = $script:Sim.Repo } }
function Set-PSRepository { param($Name, $InstallationPolicy, $ErrorAction) $script:Sim.TrustSet++ }
function Get-PackageProvider { param($Name, [switch]$ListAvailable, $ErrorAction) if ($script:Sim.NuGet) { [pscustomobject]@{ Name = 'NuGet'; Version = [version]$script:Sim.NuGet } } }
function Install-PackageProvider { param($Name, $Scope, [switch]$Force, $WarningAction, $ErrorAction) $script:Sim.NuGetInstalled++ }
function Confirm-Preflight([string]$Question) {
    $script:Sim.Asked += $Question
    if ($null -ne $script:Sim.Answers -and @($script:Sim.Answers).Count -gt 0) { $a = $script:Sim.Answers[0]; $script:Sim.Answers = @($script:Sim.Answers | Select-Object -Skip 1); return $a }
    return $script:Sim.Answer
}
function Invoke-WebRequest { param([string]$Uri, $Method, $TimeoutSec, [switch]$UseBasicParsing, [switch]$SkipHttpErrorCheck, $ErrorAction)
    $h = ([uri]$Uri).Host
    $mode = if ($script:Sim.Net.ContainsKey($h)) { $script:Sim.Net[$h] } else { 'ok' }
    switch ($mode) {
        'ok' { return [pscustomobject]@{ StatusCode = 200 } }
        'http404' { return [pscustomobject]@{ StatusCode = 404 } }
        'proxy' { throw '407 Proxy Authentication Required' }
        'cert' { throw 'The SSL connection could not be established: the remote certificate is invalid' }
        default { throw 'No such host is known.' }
    }
}
function Get-MgContext { $script:Sim.Ctx }
function Get-ConnectionInformation { [pscustomobject]@{ UserPrincipalName = 'u@x.fr' } }
function Invoke-MgGraphRequest { param($Method, $Uri, $Headers, $OutputType, $OutputFilePath, $ErrorAction)
    if ($Method -ne 'GET') { throw "METHODE NON GET : $Method" }
    $script:Sim.GraphCalls += $Uri
    foreach ($rule in $script:Sim.Graph) {
        if ($Uri -match $rule.Match) {
            if ($rule.Throw) { throw $rule.Throw }
            if ($OutputFilePath) { Set-Content -LiteralPath $OutputFilePath -Value 'a;b'; return }
            return $rule.Result
        }
    }
    if ($OutputFilePath) { Set-Content -LiteralPath $OutputFilePath -Value 'a;b'; return }
    return [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }) }
}
# Les sondes d'acces emettent un avertissement comme les vrais cmdlets quand on borne le resultat (-Limit 1 / -ResultSize 1) : stubs avances
# (CmdletBinding) pour que -WarningAction SilentlyContinue ait un effet reel et que les tests prouvent la suppression.
function Get-OrganizationConfig { [CmdletBinding()] param() Write-Warning 'MOCK: configuration d organisation partiellement hydratee'; if ($script:Sim.Fail['org']) { throw 'Forbidden' }; [pscustomobject]@{ Name = 'x' } }
function Get-EXOMailbox { [CmdletBinding()] param($ResultSize) if ("$ResultSize" -eq '1') { Write-Warning 'MOCK: There are more results than ResultSize 1.' }; if ($script:Sim.Fail['mbx']) { throw 'The role assigned to user is not allowed to run Get-EXOMailbox' }; @([pscustomobject]@{ Id = 1 }) }
function Get-AcceptedDomain { [CmdletBinding()] param() Write-Warning 'MOCK: domaines acceptes'; if ($script:Sim.Fail['dom']) { throw 'denied' }; @([pscustomobject]@{ DomainName = 'x.onmicrosoft.com' }) }
function Get-SPOTenant { [CmdletBinding()] param() Write-Warning 'MOCK: tenant SPO'; if ($script:Sim.Fail['spot']) { throw 'Access denied' }; [pscustomobject]@{ A = 1 } }
function Get-SPOSite { [CmdletBinding()] param($Limit) if ("$Limit" -eq '1') { Write-Warning "More results were found but were not returned. Use '-Limit ALL' to return all possible results." }; if ($script:Sim.Fail['spos']) { throw 'Access denied' }; @([pscustomobject]@{ Url = 'u' }) }

function Row($res, [string]$like) { @($res.Rows | Where-Object { $_.Name -like $like })[0] }
$GraphOk = @{ TenantId = 't'; Account = 'u@x.fr'; Scopes = $script:GraphScopes }

# ---------- Invoke-LocalPreflight ----------
Reset-Sim
$r = Invoke-LocalPreflight -Parts @('Identity', 'Exchange', 'SharePoint') -OutBase (Join-Path $tmpOut 'sortie')
Assert 'Local nominal : Ok' $r.Ok (($r.Rows | Where-Object Status -eq 'FAIL' | ForEach-Object { $_.Name + ':' + $_.Detail }) -join ' | ')
Assert 'Local nominal : NeedsAdmin faux' (-not $r.NeedsAdmin)
Assert 'Local nominal : lignes au format { Name; Status; Detail; Impact }' ((@($r.Rows | Where-Object { $_.PSObject.Properties.Name -join ',' -ne 'Name,Status,Detail,Impact' }).Count) -eq 0)
Assert 'Local nominal : droits admin = SKIP' ((Row $r 'Droits administrateur').Status -eq 'SKIP')
Assert 'Local nominal : 3 modules OK' (@($r.Rows | Where-Object { $_.Name -like 'Module *' -and $_.Status -eq 'OK' }).Count -eq 3)
Assert 'Local nominal : aucun fichier residuel d''ecriture' (@(Get-ChildItem -LiteralPath $tmpOut -Filter '.cwtest-*' -Force).Count -eq 0)

# module absent + refus
Reset-Sim; $script:Sim.Available.Remove('ExchangeOnlineManagement'); $script:Sim.Answer = $false
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut
$m = Row $r 'Module ExchangeOnlineManagement'
Assert 'Module absent + refus -> FAIL' ($m.Status -eq 'FAIL' -and -not $r.Ok)
Assert 'Module absent + refus : commande CurrentUser fournie' ($m.Impact -match 'Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser')
Assert 'Module absent + refus : rien installe' ($script:Sim.Installed.Count -eq 0)
Assert 'Module absent + refus : question posee' ($script:Sim.Asked.Count -ge 1)

# module trop ancien + refus
Reset-Sim; $script:Sim.Available['ExchangeOnlineManagement'] = @([pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.4.0' }); $script:Sim.Answer = $false
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut
$m = Row $r 'Module ExchangeOnlineManagement'
Assert 'Module trop ancien (3.4.0 < 3.7.0) -> FAIL' ($m.Status -eq 'FAIL' -and $m.Detail -match '3\.4\.0')

# installation acceptee (accord interactif), depot approuve
Reset-Sim; $script:Sim.Available.Remove('ExchangeOnlineManagement'); $script:Sim.Answer = $true
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut
Assert 'Installation acceptee -> OK' ((Row $r 'Module ExchangeOnlineManagement').Status -eq 'OK' -and $r.Ok -and $script:Sim.Installed -contains 'ExchangeOnlineManagement')

# -InstallMissingModules : pas de question, mise a jour d'un module ancien
Reset-Sim; $script:Sim.Available['ExchangeOnlineManagement'] = @([pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.4.0' }); $script:Sim.Answer = $false
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut -InstallMissingModules
Assert '-InstallMissingModules : installe sans question' ((Row $r 'Module ExchangeOnlineManagement').Status -eq 'OK' -and $script:Sim.Asked.Count -eq 0)

# NuGet absent : tentative CurrentUser
Reset-Sim; $script:Sim.Available.Remove('ExchangeOnlineManagement'); $script:Sim.NuGet = $null
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut -InstallMissingModules
Assert 'NuGet absent : Install-PackageProvider appele' ($script:Sim.NuGetInstalled -eq 1)

# PSGallery non approuve : accord -> Set-PSRepository ; refus -> pas de Set-PSRepository, mention du Force
Reset-Sim; $script:Sim.Available.Remove('ExchangeOnlineManagement'); $script:Sim.Repo = 'Untrusted'; $script:Sim.Answers = @($true)
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut -InstallMissingModules
Assert 'PSGallery non approuve + accord -> Set-PSRepository' ($script:Sim.TrustSet -eq 1)
Reset-Sim; $script:Sim.Available.Remove('ExchangeOnlineManagement'); $script:Sim.Repo = 'Untrusted'; $script:Sim.Answers = @($false)
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut -InstallMissingModules
Assert 'PSGallery non approuve + refus -> config inchangee, installation forcee annoncee' ($script:Sim.TrustSet -eq 0 -and (Row $r 'Module ExchangeOnlineManagement').Detail -match 'forcee' -and $r.Ok)

# echec par manque de droits
Reset-Sim; $script:Sim.Available.Remove('ExchangeOnlineManagement'); $script:Sim.InstallFail = 'Administrator rights are required to install modules in AllUsers scope'
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut -InstallMissingModules
$m = Row $r 'Module ExchangeOnlineManagement'
Assert 'Echec droits -> NeedsAdmin' ($r.NeedsAdmin -and -not $r.Ok -and $m.Status -eq 'FAIL')
Assert 'Echec droits : commande AllUsers exacte' ($m.Impact -match 'Install-Module -Name ExchangeOnlineManagement -Scope AllUsers -Force -AllowClobber')
# echec autre (pas de droits) -> pas NeedsAdmin
Reset-Sim; $script:Sim.Available.Remove('ExchangeOnlineManagement'); $script:Sim.InstallFail = 'Unable to resolve package source'
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut -InstallMissingModules
Assert 'Echec non lie aux droits -> NeedsAdmin faux' (-not $r.NeedsAdmin -and -not $r.Ok)

# module deja charge en version incompatible
Reset-Sim; $script:Sim.Loaded['ExchangeOnlineManagement'] = [pscustomobject]@{ Name = 'ExchangeOnlineManagement'; Version = [version]'3.4.0' }
$r = Invoke-LocalPreflight -Parts @('Exchange') -OutBase $tmpOut
Assert 'Module charge en version incompatible -> FAIL signale' ((Row $r 'Module ExchangeOnlineManagement').Status -eq 'FAIL' -and (Row $r 'Module ExchangeOnlineManagement').Detail -match 'deja chargee')

# reseau KO / proxy / certificat / HTTP 404 = joignable
Reset-Sim; $script:Sim.Net['graph.microsoft.com'] = 'down'; $script:Sim.Net['login.microsoftonline.com'] = 'proxy'; $script:Sim.Net['outlook.office365.com'] = 'cert'; $script:Sim.Net['sharepoint.com'] = 'http404'
$r = Invoke-LocalPreflight -Parts @('Identity', 'Exchange', 'SharePoint') -OutBase $tmpOut
Assert 'Reseau KO -> FAIL, Ok faux' ((Row $r 'Reseau graph.microsoft.com').Status -eq 'FAIL' -and -not $r.Ok)
Assert 'Proxy 407 -> FAIL "proxy"' ((Row $r 'Reseau login.microsoftonline.com').Status -eq 'FAIL' -and (Row $r 'Reseau login.microsoftonline.com').Impact -match 'proxy')
Assert 'Erreur de certificat -> WARN (joignable)' ((Row $r 'Reseau outlook.office365.com').Status -eq 'WARN')
Assert 'HTTP 404 -> joignable (OK)' ((Row $r 'Reseau sharepoint.com').Status -eq 'OK')


# dossier de sortie impossible
Reset-Sim
$r = Invoke-LocalPreflight -Parts @('Identity') -OutBase 'Z:\inexistant-xyz\a\b'
Assert 'Dossier de sortie sans parent existant -> FAIL ou chemin gere' ((Row $r 'Dossier de sortie').Status -in 'FAIL', 'OK')

# ---------- Invoke-GraphAccessProbe ----------
Reset-Sim; $script:Sim.Ctx = [pscustomobject]$GraphOk
$script:Sim.Graph = @(@{ Match = 'directoryRole'; Result = [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Global Reader' }) } })
$p = Invoke-GraphAccessProbe
Assert 'Probe nominale : pas bloquant' (-not $p.Blocking -and (@($p.Rows | Where-Object Status -eq 'FAIL').Count -eq 0))
Assert 'Probe : roles retournes' ($p.Roles -contains 'Global Reader')
Assert 'Probe : uniquement des GET sur /me,/organization,... avec $top=1' (@($script:Sim.GraphCalls | Where-Object { $_ -match '/users\?\$top=1' }).Count -ge 1)
Assert 'Probe : points d acces attendus interroges' (@('/organization', '/domains', '/subscribedSkus', '/groups', '/servicePrincipals', '/devices', 'conditionalAccess/policies', 'authorizationPolicy', '/directoryRoles', 'reportSettings', 'userRegistrationDetails', 'secureScores', 'managedDevices', 'getOneDriveUsageAccountCounts' | Where-Object { $p2 = $_; -not @($script:Sim.GraphCalls | Where-Object { $_ -like "*$p2*" }).Count }).Count -eq 0)

# 403 sur point requis -> Blocking
Reset-Sim; $script:Sim.Ctx = [pscustomobject]$GraphOk
$script:Sim.Graph = @(@{ Match = '/users\?\$top=1&\$select=id$'; Throw = 'Response status code does not indicate success: 403 (Forbidden). Authorization_RequestDenied' })
$p = Invoke-GraphAccessProbe
$u = @($p.Rows | Where-Object { $_.Name -like 'Utilisateurs*' })[0]
Assert '403 sur point REQUIS -> Blocking + FAIL' ($p.Blocking -and $u.Status -eq 'FAIL' -and $u.Detail -match 'REQUIS')

# 403 sur point optionnel -> WARN seulement
Reset-Sim; $script:Sim.Ctx = [pscustomobject]$GraphOk
$script:Sim.Graph = @(@{ Match = 'secureScores'; Throw = '403 Forbidden Authorization_RequestDenied' })
$p = Invoke-GraphAccessProbe
$s = @($p.Rows | Where-Object { $_.Name -like 'Score*' })[0]
Assert '403 sur point OPTIONNEL -> WARN, pas Blocking' (-not $p.Blocking -and $s.Status -eq 'WARN' -and $s.Impact -match 'Lecteur de securite')

# licence absente (400/403 premium) -> WARN, impact licence
Reset-Sim; $script:Sim.Ctx = [pscustomobject]$GraphOk
$script:Sim.Graph = @(@{ Match = 'signInActivity'; Throw = '403 Forbidden: Authentication_RequestFromNonPremiumTenantOrB2CTenant premium license' }, @{ Match = 'managedDevices'; Throw = '400 BadRequest: tenant not licensed for Intune' })
$p = Invoke-GraphAccessProbe
$si = @($p.Rows | Where-Object { $_.Name -like 'Derniere connexion*' })[0]
$it = @($p.Rows | Where-Object { $_.Name -like 'Intune*' })[0]
Assert 'Licence P1 absente -> WARN non applicable avec impact clair' ($si.Status -eq 'WARN' -and $si.Detail -match 'non applicable' -and $si.Impact -match 'Entra ID P1' -and -not $p.Blocking)
Assert 'Intune absent (400) -> WARN non applicable' ($it.Status -eq 'WARN' -and $it.Detail -match 'non applicable')

# consentement partiel
Reset-Sim; $script:Sim.Ctx = [pscustomobject]@{ TenantId = 't'; Account = 'u@x.fr'; Scopes = @($script:GraphScopes | Select-Object -First 5) }
$p = Invoke-GraphAccessProbe
$c = @($p.Rows | Where-Object { $_.Name -like 'Consentement*' })[0]
Assert 'Consentement partiel signale (WARN, liste des manquants)' ($c.Status -eq 'WARN' -and $c.Detail -match 'Reports\.Read\.All' -and -not $p.Blocking)

# roles : indication Exchange / SharePoint quand aucun role utile
Reset-Sim; $script:Sim.Ctx = [pscustomobject]$GraphOk
$script:Sim.Graph = @(@{ Match = 'directoryRole'; Result = [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Helpdesk Administrator' }) } })
$p = Invoke-GraphAccessProbe
Assert 'Roles insuffisants -> indications Exchange et SharePoint' (@($p.Rows | Where-Object { $_.Name -eq 'Indication : Exchange' -and $_.Status -eq 'WARN' }).Count -eq 1 -and @($p.Rows | Where-Object { $_.Name -eq 'Indication : SharePoint' }).Count -eq 1)
$script:Sim.Graph = @(@{ Match = 'directoryRole'; Result = [pscustomobject]@{ value = @([pscustomobject]@{ displayName = 'Global Administrator' }) } })
$p = Invoke-GraphAccessProbe
Assert 'Administrateur general -> aucune indication negative' (@($p.Rows | Where-Object { $_.Name -like 'Indication*' }).Count -eq 0)

# pas de session Graph
Reset-Sim; $script:Sim.Ctx = $null
$p = Invoke-GraphAccessProbe
Assert 'Pas de session Graph -> Blocking' ($p.Blocking -and $p.Rows[0].Status -eq 'FAIL')

# ---------- Exchange / SharePoint ----------
Reset-Sim; $script:Ctx.Capabilities.Clear()
Assert 'Exchange nominal -> true' ((Test-ExchangeAccess) -eq $true -and @($script:Ctx.Capabilities | Where-Object { $_.Item -like 'Acces *' -and $_.Status -eq 'OK' }).Count -eq 3)
Reset-Sim; $script:Ctx.Capabilities.Clear(); $script:Sim.Fail['mbx'] = $true
$res = Test-ExchangeAccess
Assert 'Exchange Get-EXOMailbox refuse -> false + KO, sans exception' ($res -eq $false -and @($script:Ctx.Capabilities | Where-Object { $_.Item -eq 'Acces Get-EXOMailbox' -and $_.Status -eq 'KO' }).Count -eq 1)
Reset-Sim; $script:Ctx.Capabilities.Clear(); $script:Sim.Fail['org'] = $true
Assert 'Exchange Get-OrganizationConfig refuse -> PARTIEL, reste true' ((Test-ExchangeAccess) -eq $true -and @($script:Ctx.Capabilities | Where-Object { $_.Item -eq 'Acces Get-OrganizationConfig' -and $_.Status -eq 'PARTIEL' }).Count -eq 1)
Reset-Sim; $script:Ctx.Capabilities.Clear()
Assert 'SharePoint nominal -> true' ((Test-SharePointAccess) -eq $true -and @($script:Ctx.Capabilities | Where-Object { $_.Part -eq 'SharePoint' -and $_.Item -like 'Acces *' }).Count -eq 2)
Reset-Sim; $script:Ctx.Capabilities.Clear(); $script:Sim.Fail['spos'] = $true
Assert 'SharePoint Get-SPOSite refuse -> false' ((Test-SharePointAccess) -eq $false)

# ---------- Avertissements parasites : aucun WARNING des modules simules n'atteint l'ecran ----------
function Get-WarningsOf([scriptblock]$Block) { @(& $Block 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) }
Reset-Sim
$ctl = Get-WarningsOf { $null = Get-SPOSite -Limit 1 }
Assert 'temoin : le stub Get-SPOSite -Limit 1 emet bien l avertissement "More results were found"' ($ctl.Count -eq 1 -and $ctl[0].Message -like '*More results were found*')
$ctl = Get-WarningsOf { $null = Get-EXOMailbox -ResultSize 1 }
Assert 'temoin : le stub Get-EXOMailbox -ResultSize 1 emet bien un avertissement' ($ctl.Count -eq 1)
Reset-Sim; $script:Ctx.Capabilities.Clear()
$w = Get-WarningsOf { $null = Test-SharePointAccess }
Assert 'Test-SharePointAccess : aucun avertissement affiche (Get-SPOSite -Limit 1)' ($w.Count -eq 0) (($w | ForEach-Object { $_.Message }) -join ' | ')
Reset-Sim; $script:Ctx.Capabilities.Clear()
$w = Get-WarningsOf { $null = Test-ExchangeAccess }
Assert 'Test-ExchangeAccess : aucun avertissement affiche (Get-EXOMailbox -ResultSize 1)' ($w.Count -eq 0) (($w | ForEach-Object { $_.Message }) -join ' | ')
Assert 'sondes -Limit 1 / -ResultSize 1 : -WarningAction SilentlyContinue present dans preflight.ps1' ((Select-String -Path (Join-Path $root 'lib\preflight.ps1') -Pattern 'Get-SPOSite -Limit 1 -WarningAction SilentlyContinue' -Quiet) -and (Select-String -Path (Join-Path $root 'lib\preflight.ps1') -Pattern 'Get-EXOMailbox -ResultSize 1 -WarningAction SilentlyContinue' -Quiet))

Remove-Item -LiteralPath $tmpOut -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ("Resultat : {0} PASS, {1} FAIL" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
