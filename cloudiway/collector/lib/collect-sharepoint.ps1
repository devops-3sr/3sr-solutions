# collect-sharepoint.ps1 - collecte SharePoint / OneDrive (lecture seule, connexion interactive).
# Tourne dans un processus worker dedie (module SPO et module Exchange ne cohabitent pas : conflit Microsoft.Identity.Client).
# Ne leve jamais d'exception.

function Invoke-SharePointCollection {
    $WarningPreference = 'SilentlyContinue'   # collecte longue : jamais d'avertissement brut des modules Microsoft (ex. Get-SPOSite : "More results were found")
    $part = 'SharePoint'
    $spoOk = $false
    try {
        # --- Domaine d'administration SharePoint ------------------------------------------------------
        $initial = [string]$script:Ctx.InitialDomain
        $name = $initial -replace '\.onmicrosoft\.com$', ''
        if (-not $name -or $name -match '[^A-Za-z0-9\-]') {
            Add-Cap $part 'Connect-SPOService' 'KO' "Domaine initial inexploitable ('$initial') : impossible de construire l'URL d'administration SharePoint"
            return
        }
        $adminUrl = "https://$name-admin.sharepoint.com"

        # --- Module ----------------------------------------------------------------------------------
        try {
            Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop
        } catch {
            Add-Cap $part 'Module SharePoint' 'KO' ("Module Microsoft.Online.SharePoint.PowerShell indisponible : " + (Get-ErrMsg $_))
            return
        }

        # --- Connexion interactive -------------------------------------------------------------------
        Write-Log '=== SharePoint / OneDrive : une fenetre de connexion Microsoft va s''ouvrir ===' 'Yellow'
        # LIMITE CONNUE : le compte reellement connecte a SharePoint n'est pas verifiable (Connect-SPOService n'expose pas
        # l'identite de la session ; pas de verification via Get-SPOUser, volontairement). Seul le tenant est controle
        # indirectement par l'URL d'administration. Le compte attendu est donc seulement rappele a l'operateur.
        Write-Log ("Information : compte SharePoint attendu = {0} (non verifiable automatiquement, a controler dans la fenetre de connexion)" -f $script:Ctx.User)
        Write-Host ("  >>> Connectez-vous avec le compte : {0}" -f $script:Ctx.User) -ForegroundColor Yellow
        Write-Host '  >>> La fenetre expire au bout d''environ 2 minutes : ne la laissez pas ouverte sans y repondre.' -ForegroundColor Yellow
        Write-Host '  >>> Si la fenetre est passee derriere d''autres applications, cherchez-la dans la barre des taches.' -ForegroundColor Yellow
        try {
            Connect-SPOService -Url $adminUrl -WarningAction SilentlyContinue -InformationAction SilentlyContinue -ErrorAction Stop
            $spoOk = $true
            Add-Cap $part 'Connect-SPOService' 'OK' 'Connexion a l''administration SharePoint du tenant'
        } catch {
            Add-Cap $part 'Connect-SPOService' 'KO' ((Get-ErrMsg $_) + ' (relancer la partie SharePoint : -Parts SharePoint)')
            return
        }

        # Test des acces essentiels AVANT la collecte (resultat deja enregistre par la sonde sous 'Acces ...')
        if (Get-Command Test-SharePointAccess -CommandType Function -ErrorAction SilentlyContinue) {
            if (-not (Test-SharePointAccess)) {
                Write-Log 'SharePoint : acces essentiel refuse pour ce compte, la collecte SharePoint est ignoree (voir les lignes Acces ci-dessus).' 'Yellow'
                return
            }
        }

        # --- Sites et comptes OneDrive ---------------------------------------------------------------
        $sites = $null
        try {
            $sites = @(if ($script:Ctx.IsSource) { Get-SPOSite -Limit All -IncludePersonalSite $true -WarningAction SilentlyContinue -ErrorAction Stop } else { Get-SPOSite -Limit All -WarningAction SilentlyContinue -ErrorAction Stop })
            Add-Cap $part 'Get-SPOSite' 'OK' ("{0} sites" -f $sites.Count)
        } catch {
            Add-Cap $part 'Get-SPOSite' 'KO' (Get-ErrMsg $_)
        }

        if ($null -ne $sites) {
            # $sites est toujours un tableau (eventuellement vide) : les CSV sont ecrits meme pour 0 site
            try {
                $srows = foreach ($s in $sites) {
                    $mb = [int64]$s.StorageUsageCurrent
                    $personal = $s.Template -like 'SPSPERS*'
                    [pscustomobject]@{
                        Url = $s.Url; Title = $s.Title; Template = $s.Template; Owner = $s.Owner
                        StorageBytes = $mb * 1MB; StorageGB = ConvertTo-GB ($mb * 1MB)
                        LastContentModifiedDate = Format-Date $s.LastContentModifiedDate; GroupId = $s.GroupId; RelatedGroupId = $s.RelatedGroupId
                        IsTeamsConnected = $s.IsTeamsConnected; IsTeamsChannelConnected = $s.IsTeamsChannelConnected; TeamsChannelType = $s.TeamsChannelType
                        SharingCapability = $s.SharingCapability; LockState = $s.LockState; HubSiteId = $s.HubSiteId
                        Category = if ($personal) { 'OneDrive' } elseif ($s.Template -in $script:SystemSiteTemplates) { 'Systeme' } else { 'SharePoint' }
                    }
                }
                $srows = @($srows)
                if ($script:Ctx.IsSource) {
                    Save-Csv $srows 'sites.csv'
                    Save-Csv @($srows | Where-Object Category -eq 'OneDrive') 'onedrive.csv'
                    Save-Csv @($srows | Where-Object Category -eq 'SharePoint') 'sharepoint.csv'
                    Save-Csv @($srows | Where-Object Category -eq 'Systeme') 'sharepoint-system.csv'
                } else {
                    # Cible : liste allegee (pas de OneDrive, pas de volumes), utile pour detecter les conflits de noms
                    Save-Csv @($srows | Where-Object Category -ne 'OneDrive' | Select-Object Url, Title, Template, Category) 'sites.csv'
                }
                $nOd = @($srows | Where-Object Category -eq 'OneDrive').Count
                $nSp = @($srows | Where-Object Category -eq 'SharePoint').Count
                $nSy = @($srows | Where-Object Category -eq 'Systeme').Count
                Add-Cap $part 'Categorisation des sites' 'OK' ("{0} OneDrive, {1} sites SharePoint, {2} sites systeme (sites systeme comptes a part)" -f $nOd, $nSp, $nSy)
            } catch {
                Add-Cap $part 'Ecriture sites / OneDrive' 'KO' (Get-ErrMsg $_)
            }
        }

        # --- Proprietes de partage du tenant ---------------------------------------------------------
        try {
            $t = Get-SPOTenant -WarningAction SilentlyContinue -ErrorAction Stop
            $keep = 'SharingCapability', 'OneDriveSharingCapability', 'DefaultSharingLinkType', 'DefaultLinkPermission', 'RequireAnonymousLinksExpireInDays', 'SharingDomainRestrictionMode', 'SharingAllowedDomainList', 'SharingBlockedDomainList', 'ExternalUserExpirationRequired', 'ExternalUserExpireInDays', 'StorageQuota', 'StorageQuotaAllocated', 'OneDriveStorageQuota', 'ResourceQuota', 'ConditionalAccessPolicy', 'LegacyAuthProtocolsEnabled'
            $present = @($keep | Where-Object { $t.PSObject.Properties.Name -contains $_ })
            Save-Csv ($t | Select-Object $present) 'spo-tenant.csv'
            $absent = @($keep | Where-Object { $_ -notin $present })
            Add-Cap $part 'Get-SPOTenant' 'OK' $(if ($absent.Count) { "Proprietes absentes de cette version du module : " + ($absent -join ', ') } else { '' })
        } catch {
            Add-Cap $part 'Get-SPOTenant' 'KO' (Get-ErrMsg $_)
        }

        # --- Limite connue : inactivite non mesurable ------------------------------------------------
        Add-Cap $part 'LastContentModifiedDate' 'OK' 'Note : non fiable pour l''inactivite. Date non fiable pour mesurer l''inactivite : Microsoft modifie la quasi-totalite des sites de nuit. Ne pas l''utiliser pour exclure des sites ; seuls les rapports d''usage Graph (ou un export du centre d''administration) donnent l''activite reelle.'
    } catch {
        try { Add-Cap $part 'Collecte SharePoint' 'KO' ("Erreur inattendue : " + (Get-ErrMsg $_)) } catch { }
    } finally {
        if ($spoOk) { try { Disconnect-SPOService -WarningAction SilentlyContinue -ErrorAction SilentlyContinue } catch { } }
    }
}
