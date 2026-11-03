# preflight.ps1 - prerequis du poste et controle des acces.
# Ne fait que RETOURNER des donnees (lignes { Name; Status; Detail; Impact }) : l'affichage est assure par l'appelant.
# Lecture seule sur les tenants. Seules ecritures : Install-Module / Install-PackageProvider / Set-PSRepository sur le poste,
# et uniquement apres accord de l'utilisateur (ou -InstallMissingModules pour les modules).
# Statut d'une ligne : OK | WARN | FAIL | SKIP.

function New-CheckRow([string]$Name, [string]$Status, [string]$Detail = '', [string]$Impact = '') {
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Impact = $Impact }
}

# Question O/N. Sans console interactive (entree redirigee), la reponse est NON : rien n'est jamais accepte par defaut.
function Confirm-Preflight([string]$Question) {
    try {
        if ([Console]::IsInputRedirected) { return $false }
        $rep = Read-Host $Question
        return [bool]("$rep" -match '^(o|oui|y|yes)$')
    } catch { return $false }
}

# Version la plus haute installee + version eventuellement deja chargee dans la session.
function Get-PreflightModuleState([string]$Name) {
    $inst = $null; $loaded = $null
    try {
        $m = @(Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue | Sort-Object { [version]"$($_.Version)" } -Descending | Select-Object -First 1)
        if ($m.Count -gt 0 -and $m[0]) { $inst = [version]"$($m[0].Version)" }
    } catch { }
    try {
        $l = @(Get-Module -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($l.Count -gt 0 -and $l[0]) { $loaded = [version]"$($l[0].Version)" }
    } catch { }
    [pscustomobject]@{ Installed = $inst; Loaded = $loaded }
}

# Teste une URL HTTPS (HEAD, delai 5 s). State : Ok | Proxy | Cert | Down. Ne leve jamais ; ne lit ni n'ecrit aucun jeton.
function Get-HttpsReach([string]$Url, [int]$TimeoutSec = 5) {
    $via = ''
    try {
        $u = [uri]$Url
        $px = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($u)
        if ($px -and $px.Host -ne $u.Host) { $via = " (via proxy $($px.Host))" }
    } catch { }
    try {
        $r = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop
        if ($r -and [int]$r.StatusCode -eq 407) {
            return [pscustomobject]@{ State = 'Proxy'; Detail = "le proxy exige une authentification (HTTP 407)$via" }
        }
        return [pscustomobject]@{ State = 'Ok'; Detail = "joignable$via" }
    } catch {
        $e = $_
        $msg = "$($e.Exception.Message)"
        $code = $null
        try { if ($e.Exception.Response -and $e.Exception.Response.StatusCode) { $code = [int]$e.Exception.Response.StatusCode } } catch { }
        if ($null -eq $code -and $msg -match '\b(\d{3})\b' -and $msg -match 'Proxy Authentication|\b407\b') { $code = 407 }
        if ($code -eq 407) { return [pscustomobject]@{ State = 'Proxy'; Detail = "le proxy exige une authentification (HTTP 407)$via" } }
        if ($null -ne $code) { return [pscustomobject]@{ State = 'Ok'; Detail = "joignable (reponse HTTP $code)$via" } }
        if ($msg -match 'certificate|certificat|SSL|TLS|trust|revocation|Authentication failed') {
            return [pscustomobject]@{ State = 'Cert'; Detail = "joignable mais certificat non reconnu (inspection TLS du reseau ou date du poste incorrecte ?)$via" }
        }
        if ($msg -match 'timed out|timeout|delai|canceled|annul') { return [pscustomobject]@{ State = 'Down'; Detail = "aucune reponse en $TimeoutSec s$via" } }
        if ($msg -match 'No such host|nodename|resolve|DNS|introuvable|name or service') { return [pscustomobject]@{ State = 'Down'; Detail = "nom de serveur introuvable (DNS)$via" } }
        $short = ($msg -replace '\s+', ' ')
        return [pscustomobject]@{ State = 'Down'; Detail = ("echec de connexion : " + $short.Substring(0, [Math]::Min(120, $short.Length)) + $via) }
    }
}

function Invoke-LocalPreflight {
    [CmdletBinding()]
    param(
        [string[]]$Parts,
        [string]$OutBase,
        [switch]$InstallMissingModules,
        [switch]$NoGraph   # reprise sans partie Graph : le module Graph n'est alors pas exige
    )
    $WarningPreference = 'SilentlyContinue'   # aucun avertissement brut (Install-Module, NuGet...) : nos propres messages seulement
    $rows = [System.Collections.Generic.List[object]]::new()
    $needsAdmin = $false
    if (-not $Parts -or @($Parts).Count -eq 0) { $Parts = @('Identity', 'Devices', 'Security', 'Dns', 'Exchange', 'SharePoint') }
    $collect = @($Parts)
    $needGraph = ((-not $NoGraph) -and $collect.Count -gt 0)
    $needExo = ('Exchange' -in $Parts)
    $needSpo = ('SharePoint' -in $Parts)

    # --- 1. PowerShell ---
    try {
        $v = $PSVersionTable.PSVersion
        if ($v -lt [version]'7.0') {
            $rows.Add((New-CheckRow 'PowerShell' 'FAIL' "version $v : PowerShell 7 minimum" 'L''outil ne peut pas s''executer. Installer PowerShell 7 (winget install --id Microsoft.PowerShell -e) puis relancer avec pwsh.'))
        } elseif ($v -lt [version]'7.4') {
            $rows.Add((New-CheckRow 'PowerShell' 'WARN' "version $v (7.4 recommandee)" 'Fonctionne, mais une mise a jour de PowerShell 7 est conseillee.'))
        } else {
            $rows.Add((New-CheckRow 'PowerShell' 'OK' "version $v"))
        }
    } catch { $rows.Add((New-CheckRow 'PowerShell' 'WARN' 'version non determinable')) }

    # --- 2. Systeme ---
    try {
        $isWin = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { [bool]$IsWindows } else { $true }
        if ($isWin) {
            $rows.Add((New-CheckRow 'Systeme' 'OK' ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)))
        } else {
            $rows.Add((New-CheckRow 'Systeme' 'WARN' ([System.Runtime.InteropServices.RuntimeInformation]::OSDescription) 'Outil valide sous Windows uniquement : les fenetres de connexion peuvent se comporter differemment.'))
        }
    } catch { $rows.Add((New-CheckRow 'Systeme' 'WARN' 'systeme non determinable')) }

    # --- 3. Politique d'execution (information) ---
    try {
        $ep = "$(Get-ExecutionPolicy)"
        if ($ep -in 'Restricted', 'AllSigned') {
            $rows.Add((New-CheckRow 'Politique d''execution' 'WARN' $ep 'Les scripts non signes peuvent etre bloques. Le lanceur fourni (cloudiway-collector.cmd) contourne ce blocage pour cette seule execution.'))
        } else {
            $rows.Add((New-CheckRow 'Politique d''execution' 'OK' "$ep (information)"))
        }
    } catch { $rows.Add((New-CheckRow 'Politique d''execution' 'SKIP' 'non lisible')) }

    # --- 4. Droits administrateur : non requis ---
    $rows.Add((New-CheckRow 'Droits administrateur' 'SKIP' 'non requis (installation dans le profil de l''utilisateur)'))

    # --- 5. Dossier de sortie : ecriture + espace ---
    if ($OutBase) {
        try {
            $full = [System.IO.Path]::GetFullPath($OutBase, (Get-Location).ProviderPath)
            $probe = $full
            while ($probe -and -not (Test-Path -LiteralPath $probe -PathType Container)) {
                $parent = Split-Path -Parent $probe
                if (-not $parent -or $parent -eq $probe) { $probe = $null; break }
                $probe = $parent
            }
            if (-not $probe) {
                $rows.Add((New-CheckRow 'Dossier de sortie' 'FAIL' "aucun dossier parent existant pour '$full'" 'Aucun resultat ne pourra etre ecrit. Choisir un autre emplacement avec -OutDir.'))
            } else {
                $tmp = Join-Path $probe (".cwtest-{0}.tmp" -f [guid]::NewGuid().ToString('N'))
                try {
                    Set-Content -LiteralPath $tmp -Value 'x' -ErrorAction Stop
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                    $rows.Add((New-CheckRow 'Dossier de sortie' 'OK' "ecriture possible ($full)"))
                } catch {
                    $rows.Add((New-CheckRow 'Dossier de sortie' 'FAIL' "ecriture impossible dans '$probe'" 'Aucun resultat ne pourra etre enregistre. Choisir un dossier accessible en ecriture avec -OutDir (ex. le Bureau).'))
                }
                # espace disque
                $root = [System.IO.Path]::GetPathRoot($full)
                if (-not $root -or $root.StartsWith('\\')) {
                    $rows.Add((New-CheckRow 'Espace disque' 'SKIP' 'chemin reseau : espace non verifiable'))
                } else {
                    try {
                        $freeMB = [math]::Floor(([System.IO.DriveInfo]::new($root)).AvailableFreeSpace / 1MB)
                        if ($freeMB -lt 200) {
                            $rows.Add((New-CheckRow 'Espace disque' 'FAIL' "$freeMB Mo libres sur $root (200 Mo requis)" 'La collecte risque d''echouer en cours de route. Liberer de l''espace ou choisir un autre disque (-OutDir).'))
                        } else {
                            $rows.Add((New-CheckRow 'Espace disque' 'OK' "$freeMB Mo libres sur $root"))
                        }
                    } catch { $rows.Add((New-CheckRow 'Espace disque' 'SKIP' 'non verifiable')) }
                }
            }
        } catch {
            $rows.Add((New-CheckRow 'Dossier de sortie' 'FAIL' "chemin invalide : $($_.Exception.Message)" 'Indiquer un chemin valide avec -OutDir.'))
        }
    } else {
        $rows.Add((New-CheckRow 'Dossier de sortie' 'SKIP' 'non precise'))
        $rows.Add((New-CheckRow 'Espace disque' 'SKIP' 'non precise'))
    }

    # --- 6. Reseau HTTPS ---
    $hosts = @(
        @{ Host = 'login.microsoftonline.com'; Need = ($collect.Count -gt 0); Impact = 'Aucune connexion Microsoft 365 possible : la collecte est impossible depuis ce poste.' }
        @{ Host = 'graph.microsoft.com'; Need = $needGraph; Impact = 'Les parties Identite, Appareils, Securite et DNS (Microsoft Graph) ne pourront pas etre collectees.' }
        @{ Host = 'outlook.office365.com'; Need = $needExo; Impact = 'La partie Exchange Online ne pourra pas etre collectee.' }
        @{ Host = 'sharepoint.com'; Need = $needSpo; Impact = 'La partie SharePoint / OneDrive ne pourra pas etre collectee.' }
    )
    foreach ($h in $hosts) {
        $nm = "Reseau $($h.Host)"
        if (-not $h.Need) { $rows.Add((New-CheckRow $nm 'SKIP' 'non necessaire pour les parties demandees')); continue }
        $r = Get-HttpsReach ("https://{0}/" -f $h.Host)
        switch ($r.State) {
            'Ok' { $rows.Add((New-CheckRow $nm 'OK' $r.Detail)) }
            'Cert' { $rows.Add((New-CheckRow $nm 'WARN' $r.Detail 'La connexion peut etre refusee si le reseau intercepte le trafic chiffre. Tester depuis un autre reseau ou demander a l''equipe reseau d''autoriser ce domaine.')) }
            'Proxy' { $rows.Add((New-CheckRow $nm 'FAIL' $r.Detail ("Un proxy est a configurer ou a authentifier. " + $h.Impact))) }
            default { $rows.Add((New-CheckRow $nm 'FAIL' $r.Detail ("Verifier la connexion Internet, le pare-feu et le proxy (HTTPS 443 vers $($h.Host)). " + $h.Impact))) }
        }
    }

    # --- 7. Modules ---
    $reqs = [System.Collections.Generic.List[object]]::new()
    if ($needGraph) { $reqs.Add(@{ Name = 'Microsoft.Graph.Authentication'; Min = [version]'2.0.0'; For = 'les parties Identite, Appareils, Securite et DNS' }) }
    if ($needExo) { $reqs.Add(@{ Name = 'ExchangeOnlineManagement'; Min = [version]'3.7.0'; For = 'la partie Exchange' }) }
    if ($needSpo) { $reqs.Add(@{ Name = 'Microsoft.Online.SharePoint.PowerShell'; Min = $null; For = 'la partie SharePoint / OneDrive' }) }

    if ($reqs.Count -eq 0) {
        $rows.Add((New-CheckRow 'Modules PowerShell' 'SKIP' 'aucun module requis pour les parties demandees'))
    } else {
        $modRows = @{}
        $todo = [System.Collections.Generic.List[object]]::new()
        foreach ($rq in $reqs) {
            $st = Get-PreflightModuleState $rq.Name
            $bad = (-not $st.Installed) -or ($rq.Min -and $st.Installed -lt $rq.Min)
            if ($bad) { $todo.Add($rq) }
            $rq['State'] = $st
        }

        if ($todo.Count -gt 0) {
            $names = @($todo | ForEach-Object { $_.Name })
            $cmdUser = "Install-Module -Name $($names -join ',') -Scope CurrentUser -Force -AllowClobber"
            $cmdAdmin = "Install-Module -Name $($names -join ',') -Scope AllUsers -Force -AllowClobber"
            $fail = {
                param($rq, $detail, $impactSuffix)
                $modRows[$rq.Name] = New-CheckRow "Module $($rq.Name)" 'FAIL' $detail ("Sans ce module, $($rq.For) ne pourra pas etre collectee. $impactSuffix")
            }

            # PSGallery : enregistree, joignable, approuvee ?
            $galleryOk = $true
            $repo = $null
            try { $repo = Get-PSRepository -Name PSGallery -ErrorAction Stop } catch { $repo = $null }
            if (-not $repo) {
                $rows.Add((New-CheckRow 'PSGallery' 'FAIL' 'depot PSGallery non enregistre' 'Les modules manquants ne peuvent pas etre installes. Commande : Register-PSRepository -Default'))
                $galleryOk = $false
            } else {
                $g = Get-HttpsReach 'https://www.powershellgallery.com/api/v2'
                if ($g.State -in 'Ok', 'Cert') {
                    $rows.Add((New-CheckRow 'PSGallery' 'OK' $g.Detail))
                } else {
                    $rows.Add((New-CheckRow 'PSGallery' 'FAIL' $g.Detail 'Impossible de telecharger les modules manquants depuis ce poste. Installer les modules depuis un autre reseau, ou les copier manuellement.'))
                    $galleryOk = $false
                }
            }

            if (-not $galleryOk) {
                foreach ($rq in $todo) { & $fail $rq 'module absent ou trop ancien, telechargement impossible' ("Commande a lancer depuis un reseau autorise : $cmdUser") }
            } else {
                $detailTodo = ($todo | ForEach-Object {
                        $s = $_.State.Installed
                        if ($s) { "$($_.Name) (version $s, minimum $($_.Min))" } else { "$($_.Name) (absent)" }
                    }) -join ' ; '
                $go = [bool]$InstallMissingModules
                if (-not $go) {
                    Write-Host ''
                    Write-Host "Modules PowerShell a installer ou mettre a jour : $detailTodo" -ForegroundColor Yellow
                    $go = Confirm-Preflight 'Les installer maintenant dans votre profil utilisateur (sans droits administrateur) ? [O/N]'
                }
                if (-not $go) {
                    foreach ($rq in $todo) { & $fail $rq "module absent ou trop ancien ($detailTodo) ; installation refusee" "Pour l'installer vous-meme : $cmdUser" }
                } else {
                    # Fournisseur NuGet (CurrentUser)
                    $nuget = $null
                    try { $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1 } catch { }
                    if ($nuget -and [version]"$($nuget.Version)" -ge [version]'2.8.5.201') {
                        $rows.Add((New-CheckRow 'Fournisseur NuGet' 'OK' "version $($nuget.Version)"))
                    } else {
                        try {
                            Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                            $rows.Add((New-CheckRow 'Fournisseur NuGet' 'OK' 'installe dans le profil utilisateur'))
                        } catch {
                            $rows.Add((New-CheckRow 'Fournisseur NuGet' 'WARN' ("installation impossible : " + $_.Exception.Message) 'L''installation des modules va tout de meme etre tentee ; si elle echoue, utiliser la commande proposee pour une console administrateur.'))
                        }
                    }

                    # PSGallery non approuve : accord explicite requis pour changer la configuration
                    $forceNote = ''
                    if ("$($repo.InstallationPolicy)" -ne 'Trusted') {
                        $trusted = $false
                        if (Confirm-Preflight 'PSGallery n''est pas un depot approuve. L''approuver sur ce poste (Set-PSRepository -Name PSGallery -InstallationPolicy Trusted) ? [O/N]') {
                            try {
                                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
                                $trusted = $true
                                $rows.Add((New-CheckRow 'PSGallery approuve' 'OK' 'depot marque comme approuve sur ce poste'))
                            } catch {
                                $rows.Add((New-CheckRow 'PSGallery approuve' 'WARN' ("changement impossible : " + $_.Exception.Message) 'L''installation sera forcee sans modifier la configuration.'))
                            }
                        }
                        if (-not $trusted) {
                            $forceNote = ' (depot non approuve : installation forcee, sans modifier votre configuration)'
                            $rows.Add((New-CheckRow 'PSGallery approuve' 'WARN' 'depot non approuve, configuration inchangee' 'Les modules sont installes avec -Force, ce qui supprime l''invite de confirmation. Rien d''autre n''est modifie.'))
                        }
                    }

                    # Installation module par module
                    foreach ($rq in $todo) {
                        try {
                            Write-Host "Installation de $($rq.Name) (peut prendre une a deux minutes) ..." -ForegroundColor Cyan
                            Install-Module -Name $rq.Name -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
                        } catch {
                            $m = "$($_.Exception.Message)"
                            if ($m -match 'administrator|administrateur|UnauthorizedAccess|Access to the path|Acces au chemin|denied|refus|elevat|privilege') {
                                $needsAdmin = $true
                                & $fail $rq "installation refusee faute de droits : $($m.Substring(0, [Math]::Min(120, $m.Length)))" "A lancer dans une console PowerShell ouverte en tant qu'administrateur : Install-Module -Name $($rq.Name) -Scope AllUsers -Force -AllowClobber (puis relancer la collecte)."
                            } else {
                                & $fail $rq ("installation echouee : " + $m.Substring(0, [Math]::Min(160, $m.Length))) "Essayer manuellement : Install-Module -Name $($rq.Name) -Scope CurrentUser -Force -AllowClobber"
                            }
                            continue
                        }
                        $st2 = Get-PreflightModuleState $rq.Name
                        $rq['State'] = $st2
                        if ((-not $st2.Installed) -or ($rq.Min -and $st2.Installed -lt $rq.Min)) {
                            & $fail $rq "installation terminee mais version $(if ($st2.Installed) { $st2.Installed } else { 'introuvable' }) detectee (minimum $($rq.Min))" "Fermer cette console, ouvrir une nouvelle fenetre pwsh et relancer."
                        } else {
                            $modRows[$rq.Name] = New-CheckRow "Module $($rq.Name)" 'OK' ("installe ou mis a jour : version $($st2.Installed)" + $forceNote)
                        }
                    }
                }
            }
        }

        # Modules OK (ou installes) : version minimale et module deja charge avec une version incompatible
        foreach ($rq in $reqs) {
            if ($modRows.ContainsKey($rq.Name) -and $modRows[$rq.Name].Status -eq 'FAIL') { continue }
            $st = $rq.State
            $detail = if ($modRows.ContainsKey($rq.Name)) { $modRows[$rq.Name].Detail } else { "version $($st.Installed)" }
            if ($st.Loaded -and $rq.Min -and $st.Loaded -lt $rq.Min) {
                $modRows[$rq.Name] = New-CheckRow "Module $($rq.Name)" 'FAIL' "version $($st.Loaded) deja chargee dans cette session (minimum $($rq.Min))" "Fermer cette console, ouvrir une nouvelle fenetre pwsh et relancer : sinon $($rq.For) ne pourra pas etre collectee."
            } elseif (-not $modRows.ContainsKey($rq.Name)) {
                $modRows[$rq.Name] = New-CheckRow "Module $($rq.Name)" 'OK' $detail
            }
        }
        foreach ($rq in $reqs) { $rows.Add($modRows[$rq.Name]) }
    }

    $ok = (@($rows | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0)
    [pscustomobject]@{ Ok = $ok; Rows = @($rows); NeedsAdmin = $needsAdmin }
}

# Classe une erreur Graph : Droit (401/403) | NonApplicable (400/404 ou licence/service absent) | Autre
function Get-ProbeErrorClass($Err) {
    $txt = ''
    try { $txt = "$($Err.Exception.Message) $($Err.ErrorDetails.Message)" } catch { }
    $code = $null
    try { if ($Err.Exception.Response -and $Err.Exception.Response.StatusCode) { $code = [int]$Err.Exception.Response.StatusCode } } catch { }
    if ($null -eq $code -and $txt -match '\b(400|401|403|404)\b') { $code = [int]$Matches[1] }
    if ($null -eq $code) {
        if ($txt -match 'Forbidden|Authorization_RequestDenied|Insufficient privileges|AccessDenied') { $code = 403 }
        elseif ($txt -match 'Unauthorized|InvalidAuthenticationToken') { $code = 401 }
        elseif ($txt -match 'BadRequest') { $code = 400 }
        elseif ($txt -match 'NotFound|ResourceNotFound') { $code = 404 }
    }
    $class = 'Autre'
    if ($txt -match 'premium|license|licence|NonPremium|not licensed|not enabled|no Intune|service not|MdmNotConfigured') { $class = 'NonApplicable' }
    elseif ($code -in 401, 403) { $class = 'Droit' }
    elseif ($code -in 400, 404) { $class = 'NonApplicable' }
    [pscustomobject]@{ Code = $code; Class = $class }
}

function Invoke-GraphAccessProbe {
    [CmdletBinding()]
    param()
    $WarningPreference = 'SilentlyContinue'

    # Table des points d'acces (lisible et modifiable). Required = $true : un echec bloque la collecte.
    # Role / Licence : cause probable en cas de refus ; Impact : ce qui ne sera pas collecte.
    $Points = @(
        @{ Name = 'Organisation (/organization)'; Path = '/organization'; Required = $true; Role = 'Lecteur general, Lecteur de repertoire ou Administrateur general'; Licence = ''; Impact = 'Le tenant ne peut pas etre identifie.' }
        @{ Name = 'Domaines (/domains)'; Path = '/domains'; Required = $true; Role = 'Lecteur general, Lecteur de repertoire ou Administrateur general'; Licence = ''; Impact = 'Les domaines du tenant ne peuvent pas etre lus.' }
        @{ Name = 'Utilisateurs (/users)'; Path = '/users?$top=1&$select=id'; Required = $true; Role = 'Lecteur general, Lecteur de repertoire ou Administrateur general'; Licence = ''; Impact = 'Le nombre et la liste des comptes ne peuvent pas etre collectes.' }
        @{ Name = 'Groupes (/groups)'; Path = '/groups?$top=1&$select=id'; Required = $true; Role = 'Lecteur general, Lecteur de repertoire ou Administrateur general'; Licence = ''; Impact = 'Les groupes, Teams et sites de groupe ne peuvent pas etre collectes.' }
        @{ Name = 'Licences (/subscribedSkus)'; Path = '/subscribedSkus'; Required = $false; Role = 'Lecteur general, Lecteur de repertoire ou Administrateur de licences'; Licence = ''; Impact = 'L''inventaire des licences ne sera pas collecte.' }
        @{ Name = 'Applications (/servicePrincipals)'; Path = '/servicePrincipals?$top=1&$select=id'; Required = $false; Role = 'Lecteur general ou Lecteur de repertoire'; Licence = ''; Impact = 'L''inventaire des applications d''entreprise ne sera pas collecte.' }
        @{ Name = 'Appareils Entra (/devices)'; Path = '/devices?$top=1&$select=id'; Required = $false; Role = 'Lecteur general ou Lecteur de repertoire'; Licence = ''; Impact = 'L''inventaire des appareils Entra ne sera pas collecte.' }
        @{ Name = 'Derniere connexion (signInActivity)'; Path = '/users?$top=1&$select=id,signInActivity'; Required = $false; Role = 'Lecteur de rapports, Lecteur de securite ou Lecteur general'; Licence = 'Entra ID P1 ou P2'; Impact = 'les dernieres connexions des comptes ne seront pas collectees.' }
        @{ Name = 'Acces conditionnel'; Path = '/identity/conditionalAccess/policies?$top=1'; Required = $false; Role = 'Lecteur de securite, Administrateur d''acces conditionnel ou Lecteur general'; Licence = 'Entra ID P1 ou P2'; Impact = 'les strategies d''acces conditionnel ne seront pas inventoriees.' }
        @{ Name = 'Strategie d''autorisation'; Path = '/policies/authorizationPolicy'; Required = $false; Role = 'Lecteur general ou Lecteur de securite'; Licence = ''; Impact = 'les parametres d''invitation et de consentement ne seront pas collectes.' }
        @{ Name = 'Roles d''annuaire actifs (/directoryRoles)'; Path = '/directoryRoles'; Required = $false; Role = 'Lecteur general ou Lecteur de repertoire'; Licence = ''; Impact = 'la liste des administrateurs ne sera pas collectee.' }
        @{ Name = 'Parametres de rapports'; Path = '/admin/reportSettings'; Required = $false; Role = 'Lecteur de rapports, Administrateur general ou Lecteur general'; Licence = ''; Impact = 'on ne saura pas si les noms sont masques dans les rapports d''usage.' }
        @{ Name = 'Rapport d''usage'; Path = '/reports/getOneDriveUsageAccountCounts(period=''D7'')'; Kind = 'Report'; Required = $false; Role = 'Lecteur de rapports, Administrateur general ou Lecteur general'; Licence = ''; Impact = 'les rapports d''usage (OneDrive, SharePoint, boites, Teams) ne seront pas collectes : volumetries manquantes.' }
        @{ Name = 'Methodes d''authentification (MFA)'; Path = '/reports/authenticationMethods/userRegistrationDetails?$top=1'; Required = $false; Role = 'Lecteur de rapports, Lecteur de securite ou Lecteur general'; Licence = 'Entra ID P1 ou P2'; Impact = 'l''etat d''enregistrement MFA des comptes ne sera pas collecte.' }
        @{ Name = 'Score de securite'; Path = '/security/secureScores?$top=1'; Required = $false; Role = 'Lecteur de securite ou Lecteur general'; Licence = ''; Impact = 'le score de securite ne sera pas collecte.' }
        @{ Name = 'Intune (/deviceManagement/managedDevices)'; Path = '/deviceManagement/managedDevices?$top=1&$select=id'; Required = $false; Role = 'Administrateur Intune, Lecteur general ou Administrateur general'; Licence = 'Microsoft Intune'; Impact = 'les appareils geres et profils Intune ne seront pas inventories (normal si Intune n''est pas utilise).' }
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $blocking = $false
    $roleNames = @()

    $mc = $null
    try { $mc = Get-MgContext } catch { $mc = $null }
    if (-not $mc) {
        $rows.Add((New-CheckRow 'Session Microsoft Graph' 'FAIL' 'aucune session Graph active' 'La collecte ne peut pas demarrer : la connexion Graph doit reussir avant les controles.'))
        return [pscustomobject]@{ Blocking = $true; Rows = @($rows); Roles = @() }
    }

    # --- Consentement : scopes accordes vs demandes ---
    try {
        $granted = @($mc.Scopes | Where-Object { $_ } | ForEach-Object { "$_".ToLowerInvariant() })
        if ($granted.Count -eq 0) {
            $rows.Add((New-CheckRow 'Consentement (permissions)' 'SKIP' 'la session n''expose pas la liste des permissions accordees'))
        } else {
            $missing = @($script:GraphScopes | Where-Object { $_.ToLowerInvariant() -notin $granted })
            if ($missing.Count -eq 0) {
                $rows.Add((New-CheckRow 'Consentement (permissions)' 'OK' ("{0} permissions accordees sur {0}" -f @($script:GraphScopes).Count)))
            } else {
                $rows.Add((New-CheckRow 'Consentement (permissions)' 'WARN' ("{0} permission(s) non accordee(s) sur {1} : {2}" -f $missing.Count, @($script:GraphScopes).Count, ($missing -join ', ')) 'Consentement partiel : les collectes qui s''appuient sur ces permissions echoueront. Un Administrateur general doit accorder le consentement, ou le compte utilise doit en avoir le droit.'))
            }
        }
    } catch { $rows.Add((New-CheckRow 'Consentement (permissions)' 'SKIP' 'non verifiable')) }

    # --- Roles d'annuaire de l'utilisateur ---
    $rolesKnown = $false
    try {
        $r = @(Invoke-G '/me/transitiveMemberOf/microsoft.graph.directoryRole?$select=displayName' -All)
        $roleNames = @($r | ForEach-Object { "$($_.displayName)" } | Where-Object { $_ } | Sort-Object -Unique)
        $rolesKnown = $true
        if ($roleNames.Count -gt 0) {
            $rows.Add((New-CheckRow 'Roles d''annuaire du compte' 'OK' ($roleNames -join ', ')))
        } else {
            $rows.Add((New-CheckRow 'Roles d''annuaire du compte' 'WARN' 'aucun role d''annuaire actif' 'Le compte n''a aucun role administrateur actif (un role eligible PIM non active n''apparait pas). Beaucoup de lectures risquent d''etre refusees.'))
        }
    } catch {
        $rows.Add((New-CheckRow 'Roles d''annuaire du compte' 'WARN' ("non lisibles : " + (Get-ErrMsg $_)) 'Indication sur les droits indisponible ; les controles ci-dessous restent valables.'))
    }

    if ($rolesKnown) {
        $has = { param([string[]]$names) @($roleNames | Where-Object { $_ -in $names }).Count -gt 0 }
        $isGA = & $has @('Global Administrator')
        $isGR = & $has @('Global Reader')
        if (-not ($isGA -or (& $has @('Exchange Administrator')) -or $isGR)) {
            $rows.Add((New-CheckRow 'Indication : Exchange' 'WARN' 'ni Administrateur Exchange, ni Administrateur general, ni Lecteur general' 'La partie Exchange peut etre refusee (indication seulement : des groupes de roles Exchange accordes directement peuvent suffire).'))
        }
        if (-not ($isGA -or (& $has @('SharePoint Administrator')))) {
            $rows.Add((New-CheckRow 'Indication : SharePoint' 'WARN' 'ni Administrateur SharePoint, ni Administrateur general' 'La connexion au centre d''administration SharePoint peut etre refusee (indication seulement).'))
        }
        if (-not ($isGA -or $isGR -or (& $has @('Intune Administrator')))) {
            $rows.Add((New-CheckRow 'Indication : Intune' 'WARN' 'ni Administrateur Intune, ni Administrateur general, ni Lecteur general' 'L''inventaire Intune peut etre refuse (indication seulement).'))
        }
        if (-not ($isGA -or $isGR -or (& $has @('Security Reader', 'Security Administrator', 'Reports Reader', 'Directory Readers')))) {
            $rows.Add((New-CheckRow 'Indication : securite et rapports' 'WARN' 'aucun role de lecture (securite, rapports, repertoire) detecte' 'Les rapports d''usage, la securite et l''acces conditionnel peuvent etre refuses (indication seulement).'))
        }
    }

    # --- Une lecture minimale par point ---
    foreach ($p in $Points) {
        $tmp = $null
        try {
            if ($p.Kind -eq 'Report') {
                $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cwprobe-{0}.csv" -f [guid]::NewGuid().ToString('N'))
                Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0" + $p.Path) -OutputFilePath $tmp -ErrorAction Stop
            } else {
                $null = Invoke-G $p.Path
            }
            $rows.Add((New-CheckRow $p.Name 'OK' $(if ($p.Required) { 'lecture possible (requis)' } else { 'lecture possible' })))
        } catch {
            $c = Get-ProbeErrorClass $_
            $codeTxt = if ($c.Code) { "HTTP $($c.Code)" } else { 'erreur' }
            $why = switch ($c.Class) {
                'Droit' { "refuse ($codeTxt) : droit ou consentement manquant, role probable : $($p.Role)" }
                'NonApplicable' { "non applicable ($codeTxt) : licence ou service absent" + $(if ($p.Licence) { ", probablement $($p.Licence)" } else { '' }) }
                default { "echec ($codeTxt) : " + (Get-ErrMsg $_) }
            }
            if ($p.Required) {
                $blocking = $true
                $rows.Add((New-CheckRow $p.Name 'FAIL' ("REQUIS - " + $why) ("La collecte ne peut pas continuer : " + $p.Impact + " Utiliser un compte Administrateur general ou Lecteur general, et verifier le consentement.")))
            } else {
                $imp = switch ($c.Class) {
                    'Droit' { "Sans ce droit (" + $p.Role + "), " + $p.Impact }
                    'NonApplicable' { $(if ($p.Licence) { "Sans " + $p.Licence + ", " } else { "Sans ce service, " }) + $p.Impact }
                    default { "Si l'erreur persiste, " + $p.Impact }
                }
                $rows.Add((New-CheckRow $p.Name 'WARN' $why $imp))
            }
        } finally {
            if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    [pscustomobject]@{ Blocking = $blocking; Rows = @($rows); Roles = @($roleNames) }
}

# Lecture minimale Exchange. Essentiels : Get-EXOMailbox et Get-AcceptedDomain (echec -> $false).
# Get-OrganizationConfig (EWS, organisation) : echec -> PARTIEL, n'invalide pas l'acces.
function Test-ExchangeAccess {
    [CmdletBinding()]
    param()
    $WarningPreference = 'SilentlyContinue'   # jamais d'avertissement brut des modules Microsoft (les vrais problemes passent par Add-Cap)
    $ok = $true
    try {
        try { $null = Get-OrganizationConfig -WarningAction SilentlyContinue -ErrorAction Stop; Add-Cap 'Exchange' 'Acces Get-OrganizationConfig' 'OK' }
        catch { Add-Cap 'Exchange' 'Acces Get-OrganizationConfig' 'PARTIEL' ("lecture refusee ou indisponible, la configuration EWS ne sera pas collectee : " + (Get-ErrMsg $_)) }

        try { $null = @(Get-EXOMailbox -ResultSize 1 -WarningAction SilentlyContinue -ErrorAction Stop); Add-Cap 'Exchange' 'Acces Get-EXOMailbox' 'OK' }
        catch { $ok = $false; Add-Cap 'Exchange' 'Acces Get-EXOMailbox' 'KO' ("lecture des boites refusee (role Exchange probablement manquant : Administrateur Exchange, Lecteur general ou Administrateur general) : " + (Get-ErrMsg $_)) }

        try { $null = @(Get-AcceptedDomain -WarningAction SilentlyContinue -ErrorAction Stop); Add-Cap 'Exchange' 'Acces Get-AcceptedDomain' 'OK' }
        catch { $ok = $false; Add-Cap 'Exchange' 'Acces Get-AcceptedDomain' 'KO' ("lecture des domaines acceptes refusee : " + (Get-ErrMsg $_)) }
    } catch { $ok = $false }
    return $ok
}

# Lecture minimale SharePoint. Essentiel : Get-SPOSite (echec -> $false). Get-SPOTenant : echec -> PARTIEL.
function Test-SharePointAccess {
    [CmdletBinding()]
    param()
    $WarningPreference = 'SilentlyContinue'   # jamais d'avertissement brut des modules Microsoft (les vrais problemes passent par Add-Cap)
    $ok = $true
    try {
        try { $null = Get-SPOTenant -WarningAction SilentlyContinue -ErrorAction Stop; Add-Cap 'SharePoint' 'Acces Get-SPOTenant' 'OK' }
        catch { Add-Cap 'SharePoint' 'Acces Get-SPOTenant' 'PARTIEL' ("parametres du tenant non lisibles : " + (Get-ErrMsg $_)) }

        try { $null = @(Get-SPOSite -Limit 1 -WarningAction SilentlyContinue -ErrorAction Stop); Add-Cap 'SharePoint' 'Acces Get-SPOSite' 'OK' }
        catch { $ok = $false; Add-Cap 'SharePoint' 'Acces Get-SPOSite' 'KO' ("lecture des sites refusee (role Administrateur SharePoint ou Administrateur general probablement manquant) : " + (Get-ErrMsg $_)) }
    } catch { $ok = $false }
    return $ok
}
