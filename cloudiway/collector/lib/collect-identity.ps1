# collect-identity.ps1 - identites, licences, groupes, domaines, Teams, rapports d'usage, applications d'entreprise.
# Suppose une session Graph ouverte et lib\common.ps1 charge. Lecture seule (GET). Ne leve jamais d'exception.

function Invoke-IdentityCollection {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $WarningPreference = 'SilentlyContinue'   # aucun avertissement brut des modules Microsoft a l'ecran (les vrais problemes passent par Add-Cap)
    Set-StrictMode -Off
    $part = 'Identity'
    # Ecriture CSV isolee : un fichier verrouille (Excel) ne doit pas abandonner le reste de la collecte.
    function Save-CsvSafe($Data, [string]$Name) {
        try { Save-Csv $Data $Name } catch { try { Add-Cap 'Identity' "ecriture $Name" 'KO' (Get-ErrMsg $_) } catch { } }
    }
    try {
        $isSource = [bool]$script:Ctx.IsSource
        Write-Log '=== Identites (Graph) ===' 'Cyan'

        # --- Licences ---
        $skuMap = @{}
        try {
            $skus = Invoke-G '/subscribedSkus'
            $skus | ForEach-Object { $skuMap[$_.skuId] = $_.skuPartNumber }
            Save-CsvSafe ($skus | Select-Object skuPartNumber, skuId, capabilityStatus, @{n = 'Purchased'; e = { $_.prepaidUnits.enabled } }, @{n = 'Consumed'; e = { $_.consumedUnits } }) 'skus.csv'
            Add-Cap $part 'subscribedSkus' 'OK' "$(@($skus).Count) abonnements"
        } catch { Add-Cap $part 'subscribedSkus' 'KO' (Get-ErrMsg $_) }

        # --- Utilisateurs ---
        $users = $null
        try {
            $sel = 'id,userPrincipalName,displayName,givenName,surname,mail,mailNickname,proxyAddresses,userType,accountEnabled,assignedLicenses,createdDateTime,usageLocation,onPremisesSyncEnabled,onPremisesSamAccountName,onPremisesDomainName,onPremisesLastSyncDateTime,department,jobTitle'
            $users = Invoke-G "/users?`$select=$sel&`$top=999" -All
            Add-Cap $part 'users' 'OK' "$(@($users).Count) objets"
        } catch { Add-Cap $part 'users' 'KO' (Get-ErrMsg $_) }

        # signInActivity : tentative (Entra ID P1 requis, KO attendu sinon)
        $signIn = @{}
        try {
            Invoke-G "/users?`$select=id,signInActivity&`$top=999" -All | ForEach-Object { $signIn[$_.id] = $_.signInActivity }
            Add-Cap $part 'signInActivity' 'OK'
        } catch { Add-Cap $part 'signInActivity' 'KO' ("Non disponible (Entra ID P1 requis) : " + (Get-ErrMsg $_)) }

        if ($users) {
            $rows = foreach ($u in $users) {
                $s = $signIn[$u.id]
                [pscustomobject]@{
                    id = $u.id; userPrincipalName = $u.userPrincipalName; displayName = $u.displayName; givenName = $u.givenName; surname = $u.surname
                    mail = $u.mail; mailNickname = $u.mailNickname; proxyAddresses = ($u.proxyAddresses -join '|'); userType = $u.userType
                    accountEnabled = $u.accountEnabled; licenses = (($u.assignedLicenses | ForEach-Object { $skuMap[$_.skuId] ?? $_.skuId }) -join '|')
                    licensed = (@($u.assignedLicenses).Count -gt 0); createdDateTime = $u.createdDateTime; usageLocation = $u.usageLocation
                    department = $u.department; jobTitle = $u.jobTitle
                    onPremisesSyncEnabled = $u.onPremisesSyncEnabled; onPremisesSamAccountName = $u.onPremisesSamAccountName; onPremisesDomainName = $u.onPremisesDomainName
                    onPremisesLastSyncDateTime = $u.onPremisesLastSyncDateTime
                    lastSignIn = $s.lastSignInDateTime; lastNonInteractiveSignIn = $s.lastNonInteractiveSignInDateTime
                }
            }
            Save-CsvSafe $rows 'users.csv'
            if ($isSource) { Save-CsvSafe ($rows | Where-Object userType -eq 'Guest' | Select-Object userPrincipalName, mail, createdDateTime) 'guests.csv' }
        }

        # --- Groupes ---
        $groups = $null
        try {
            $gsel = 'id,displayName,mail,mailNickname,proxyAddresses,groupTypes,mailEnabled,securityEnabled,resourceProvisioningOptions,visibility,onPremisesSyncEnabled,createdDateTime'
            $groups = Invoke-G "/groups?`$select=$gsel&`$top=999" -All
            $gTotal = @($groups).Count
            Add-Cap $part 'groups' 'OK' "$gTotal objets"

            # Comptes de membres / proprietaires : source uniquement, sequentiel (robustesse), groupes de distribution simples exclus
            # (leurs membres sont comptes cote Exchange, distribution-lists.csv). Arret apres 10 echecs consecutifs.
            $i = 0; $consecKo = 0; $stopped = $false; $skipped = 0; $koCount = 0
            $grows = foreach ($g in $groups) {
                $i++
                $kind = if ($g.groupTypes -contains 'Unified') { 'M365' } elseif ($g.mailEnabled -and $g.securityEnabled) { 'MailSecurity' } elseif ($g.mailEnabled) { 'Distribution' } else { 'Security' }
                $mc = $null; $oc = $null
                if ($isSource) {
                    if (($i % 5) -eq 1 -or $i -eq $gTotal) { Write-Progress -Activity 'Groupes : comptes de membres et proprietaires' -Status "$i / $gTotal" -PercentComplete ([int](100 * $i / [Math]::Max(1, $gTotal))) }
                    if ($kind -eq 'Distribution') { $skipped++ }
                    elseif ($stopped) { $mc = 'KO'; $oc = 'KO' }
                    else {
                        try { $mc = Get-GCount "/groups/$($g.id)/members/`$count"; $okM = $true } catch { $mc = 'KO'; $okM = $false }
                        try { $oc = Get-GCount "/groups/$($g.id)/owners/`$count"; $okO = $true } catch { $oc = 'KO'; $okO = $false }
                        if ($okM -or $okO) { $consecKo = 0 } else { $consecKo++; $koCount++ }
                        if ($consecKo -ge 10) { $stopped = $true }
                    }
                }
                [pscustomobject]@{
                    id = $g.id; displayName = $g.displayName; mail = $g.mail; mailNickname = $g.mailNickname; proxyAddresses = ($g.proxyAddresses -join '|')
                    kind = $kind; groupTypes = ($g.groupTypes -join '|'); mailEnabled = $g.mailEnabled; securityEnabled = $g.securityEnabled
                    isTeam = ($g.resourceProvisioningOptions -contains 'Team'); visibility = $g.visibility; onPremisesSyncEnabled = $g.onPremisesSyncEnabled
                    members = $mc; owners = $oc; createdDateTime = $g.createdDateTime
                }
            }
            Write-Progress -Activity 'Groupes : comptes de membres et proprietaires' -Completed
            Save-CsvSafe $grows 'groups.csv'
            if ($isSource) {
                if ($stopped) { Add-Cap $part 'groups membres/proprietaires' 'PARTIEL' 'Arret apres 10 echecs consecutifs (droits insuffisants ?) ; valeurs KO pour les groupes restants' }
                elseif ($koCount -gt 0) { Add-Cap $part 'groups membres/proprietaires' 'PARTIEL' "$koCount groupe(s) sans comptes (KO) ; $skipped groupes de distribution non comptes (voir Exchange)" }
                else { Add-Cap $part 'groups membres/proprietaires' 'OK' "$skipped groupes de distribution non comptes (voir Exchange)" }
            }
        } catch {
            Write-Progress -Activity 'Groupes : comptes de membres et proprietaires' -Completed
            Add-Cap $part 'groups' 'KO' (Get-ErrMsg $_)
        }

        # --- Domaines ---
        try {
            $dom = Invoke-G '/domains'
            Save-CsvSafe ($dom | Select-Object id, isVerified, isDefault, isInitial, authenticationType, @{n = 'supportedServices'; e = { $_.supportedServices -join '|' } }) 'domains.csv'
            Add-Cap $part 'domains' 'OK' "$(@($dom).Count) domaines"
        } catch { Add-Cap $part 'domains' 'KO' (Get-ErrMsg $_) }

        if ($isSource) {
            # --- Canaux des equipes Teams : standard / prive / partage (prives et partages ont leur propre site) ---
            if ($groups) {
                try {
                    $teams = @($groups | Where-Object { $_.resourceProvisioningOptions -contains 'Team' })
                    $crow = [System.Collections.Generic.List[object]]::new()
                    $tKo = 0; $tKoMsg = ''; $j = 0
                    foreach ($tm in $teams) {
                        $j++
                        Write-Progress -Activity 'Equipes Teams : canaux' -Status "$j / $($teams.Count)" -PercentComplete ([int](100 * $j / [Math]::Max(1, $teams.Count)))
                        try {
                            $ch = Invoke-G "/teams/$($tm.id)/channels?`$select=id,displayName,membershipType" -All
                            $crow.Add([pscustomobject]@{
                                    TeamId = $tm.id; Team = $tm.displayName; Channels = @($ch).Count
                                    Standard = @($ch | Where-Object membershipType -eq 'standard').Count
                                    Private = @($ch | Where-Object membershipType -eq 'private').Count
                                    Shared = @($ch | Where-Object membershipType -eq 'shared').Count
                                })
                        } catch { $tKo++; if (-not $tKoMsg) { $tKoMsg = Get-ErrMsg $_ } }
                    }
                    Write-Progress -Activity 'Equipes Teams : canaux' -Completed
                    Save-CsvSafe $crow 'teams-channels.csv'
                    if ($tKo -gt 0) { Add-Cap $part 'teams channels' 'PARTIEL' "$($crow.Count) / $($teams.Count) equipes lues ; $tKo en erreur (ex. $tKoMsg)" }
                    else { Add-Cap $part 'teams channels' 'OK' "$($teams.Count) equipes" }
                } catch {
                    Write-Progress -Activity 'Equipes Teams : canaux' -Completed
                    Add-Cap $part 'teams channels' 'KO' (Get-ErrMsg $_)
                }
            } else {
                Add-Cap $part 'teams channels' 'KO' 'Liste des groupes indisponible'
            }

            # --- Rapports d'usage : capacite explicite sur l'anonymisation ---
            try {
                $rs = Invoke-G '/admin/reportSettings'
                $conc = $rs.displayConcealedNames
                if ($conc -eq $true) { Add-Cap $part 'reportSettings' 'PARTIEL' 'displayConcealedNames=True : les rapports d''usage sont anonymises (identites non exploitables)' }
                else { Add-Cap $part 'reportSettings' 'OK' "displayConcealedNames=$conc (rapports nominatifs)" }
            } catch { Add-Cap $part 'reportSettings' 'KO' (Get-ErrMsg $_) }
            Save-Report 'getOneDriveUsageAccountDetail' 'report-onedrive-usage.csv'
            Save-Report 'getSharePointSiteUsageDetail' 'report-sharepoint-usage.csv'
            Save-Report 'getMailboxUsageDetail' 'report-mailbox-usage.csv'
            Save-Report 'getTeamsUserActivityUserDetail' 'report-teams-activity.csv'
            Save-Report 'getOffice365ActiveUserDetail' 'report-active-users.csv'
        }

        # --- Applications d'entreprise (inventaire SSO ; SAML / OIDC a refaire cote editeur, hors Cloudiway) ---
        try {
            $sp = Invoke-G "/servicePrincipals?`$select=id,displayName,appId,servicePrincipalType,preferredSingleSignOnMode,accountEnabled,appOwnerOrganizationId,tags&`$top=999" -All
            $own = @($sp | Where-Object { $_.appOwnerOrganizationId -ne $script:MicrosoftTenantId -and $_.servicePrincipalType -eq 'Application' })
            Save-CsvSafe ($own | Select-Object displayName, appId, preferredSingleSignOnMode, accountEnabled, appOwnerOrganizationId, @{n = 'tags'; e = { $_.tags -join '|' } }) 'enterprise-apps.csv'
            Add-Cap $part 'servicePrincipals' 'OK' "$($own.Count) apps (hors Microsoft)"
        } catch { Add-Cap $part 'servicePrincipals' 'KO' (Get-ErrMsg $_) }
    } catch {
        Write-Progress -Activity 'Groupes : comptes de membres et proprietaires' -Completed
        try { Add-Cap $part 'Collecte (erreur inattendue)' 'KO' (Get-ErrMsg $_) } catch { }
    }
}
