# collect-security.ps1 - parametres de securite du tenant (acces conditionnel, MFA, roles, etc.).
# Suppose une session Graph ouverte et lib\common.ps1 charge. Lecture seule (GET). Ne leve jamais d'exception.

function Invoke-SecurityCollection {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $WarningPreference = 'SilentlyContinue'   # aucun avertissement brut des modules Microsoft a l'ecran (les vrais problemes passent par Add-Cap)
    Set-StrictMode -Off
    $part = 'Security'
    try {
        Write-Log '=== Securite du tenant ===' 'Cyan'

        try {
            $ca = Invoke-G '/identity/conditionalAccess/policies' -All
            Save-Csv ($ca | Select-Object displayName, state, createdDateTime, modifiedDateTime,
                @{n = 'users_include'; e = { ($_.conditions.users.includeUsers + $_.conditions.users.includeGroups + $_.conditions.users.includeRoles) -join '|' } },
                @{n = 'users_exclude'; e = { ($_.conditions.users.excludeUsers + $_.conditions.users.excludeGroups + $_.conditions.users.excludeRoles) -join '|' } },
                @{n = 'apps'; e = { $_.conditions.applications.includeApplications -join '|' } },
                @{n = 'platforms'; e = { $_.conditions.platforms.includePlatforms -join '|' } },
                @{n = 'locations_include'; e = { $_.conditions.locations.includeLocations -join '|' } },
                @{n = 'grant'; e = { ($_.grantControls.builtInControls -join '|') + ' (' + $_.grantControls.operator + ')' } },
                @{n = 'session'; e = { ($_.sessionControls.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object Name) -join '|' } }) 'conditional-access.csv'
            Add-Cap $part 'Conditional Access' 'OK' "$(@($ca).Count) politiques"
        } catch { Add-Cap $part 'Conditional Access' 'KO' (Get-ErrMsg $_) }

        try {
            $sd = Invoke-G '/policies/identitySecurityDefaultsEnforcementPolicy'
            Save-Csv ([pscustomobject]@{ SecurityDefaultsEnabled = $sd.isEnabled }) 'security-defaults.csv'
            Add-Cap $part 'Security defaults' 'OK'
        } catch { Add-Cap $part 'Security defaults' 'KO' (Get-ErrMsg $_) }

        try {
            $ap = Invoke-G '/policies/authorizationPolicy'
            Save-Csv ([pscustomobject]@{
                    allowInvitesFrom = $ap.allowInvitesFrom; allowedToSignUpEmailBasedSubscriptions = $ap.allowedToSignUpEmailBasedSubscriptions
                    allowEmailVerifiedUsersToJoinOrganization = $ap.allowEmailVerifiedUsersToJoinOrganization; guestUserRoleId = $ap.guestUserRoleId
                    usersCanCreateApps = $ap.defaultUserRolePermissions.allowedToCreateApps; usersCanCreateSecurityGroups = $ap.defaultUserRolePermissions.allowedToCreateSecurityGroups
                    usersCanCreateTenants = $ap.defaultUserRolePermissions.allowedToCreateTenants
                    userConsentPolicies = ($ap.defaultUserRolePermissions.permissionGrantPoliciesAssigned -join '|')
                }) 'authorization-policy.csv'
            Add-Cap $part 'Authorization policy' 'OK'
        } catch { Add-Cap $part 'Authorization policy' 'KO' (Get-ErrMsg $_) }

        try {
            $xt = Invoke-G '/policies/crossTenantAccessPolicy/default'
            Save-Csv ([pscustomobject]@{
                    b2bCollabInbound = ($xt.b2bCollaborationInbound | ConvertTo-Json -Compress -Depth 5); b2bCollabOutbound = ($xt.b2bCollaborationOutbound | ConvertTo-Json -Compress -Depth 5)
                    inboundTrust = ($xt.inboundTrust | ConvertTo-Json -Compress -Depth 5); tenantRestrictions = ($xt.tenantRestrictions | ConvertTo-Json -Compress -Depth 5)
                }) 'cross-tenant-access.csv'
            Add-Cap $part 'Cross-tenant access (defaut)' 'OK'
        } catch { Add-Cap $part 'Cross-tenant access (defaut)' 'KO' (Get-ErrMsg $_) }

        try {
            $roles = Invoke-G '/directoryRoles' -All
            $total = @($roles).Count; $k = 0; $rKo = 0
            $rrows = foreach ($r in $roles) {
                $k++
                Write-Progress -Activity 'Roles annuaire' -Status "$k / $total" -PercentComplete ([int](100 * $k / [Math]::Max(1, $total)))
                $mem = @()
                try { $mem = @(Invoke-G "/directoryRoles/$($r.id)/members?`$select=id,displayName,userPrincipalName" -All) } catch { $rKo++ }
                [pscustomobject]@{ Role = $r.displayName; Members = $mem.Count; MemberList = (($mem | ForEach-Object { $_.userPrincipalName ?? $_.displayName }) -join '|') }
            }
            Write-Progress -Activity 'Roles annuaire' -Completed
            Save-Csv $rrows 'directory-roles.csv'
            if ($rKo -gt 0) { Add-Cap $part 'Roles annuaire' 'PARTIEL' "$rKo role(s) dont les membres n'ont pas pu etre lus" } else { Add-Cap $part 'Roles annuaire' 'OK' "$total roles actifs" }
        } catch {
            Write-Progress -Activity 'Roles annuaire' -Completed
            Add-Cap $part 'Roles annuaire' 'KO' (Get-ErrMsg $_)
        }

        try {
            $ur = Invoke-G '/reports/authenticationMethods/userRegistrationDetails' -All
            Save-Csv ($ur | Select-Object userPrincipalName, isAdmin, isMfaRegistered, isMfaCapable, isSsprRegistered, isPasswordlessCapable, defaultMfaMethod, @{n = 'methodsRegistered'; e = { $_.methodsRegistered -join '|' } }) 'mfa-registration.csv'
            Add-Cap $part 'Inscription MFA' 'OK' "$(@($ur).Count) comptes"
        } catch { Add-Cap $part 'Inscription MFA' 'KO' (Get-ErrMsg $_) }

        try {
            $ss = Invoke-G '/security/secureScores?$top=1'
            Save-Csv ($ss | Select-Object createdDateTime, currentScore, maxScore, activeUserCount, licensedUserCount) 'secure-score.csv'
            Add-Cap $part 'Secure Score' 'OK'
        } catch { Add-Cap $part 'Secure Score' 'KO' (Get-ErrMsg $_) }

        try {
            $am = Invoke-G '/policies/authenticationMethodsPolicy'
            Save-Csv ($am.authenticationMethodConfigurations | Select-Object id, state) 'auth-methods-policy.csv'
            Add-Cap $part 'Methodes d''authentification' 'OK'
        } catch { Add-Cap $part 'Methodes d''authentification' 'KO' (Get-ErrMsg $_) }
    } catch {
        Write-Progress -Activity 'Roles annuaire' -Completed
        try { Add-Cap $part 'Collecte (erreur inattendue)' 'KO' (Get-ErrMsg $_) } catch { }
    }
}
