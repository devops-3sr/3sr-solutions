# mocks.ps1 - cmdlets SIMULEES pour le banc de test hors ligne de CloudiwayCollector.
# A dot-sourcer APRES lib\*.ps1 (les stubs sont definis en portee globale et priment sur les vrais cmdlets).
# Aucun appel reseau, aucune connexion reelle. Chaque appel est enregistre dans $global:MockCalls.
#
$env:CLOUDIWAY_TESTS = '1'   # active le point d'injection 'pwsh' du script principal (tests uniquement)
# Etat global :
#   $global:MockCalls : List[object] {Seq; Kind; Cmd; Method; Uri; Detail}
#   $global:MockOpts  : options de scenario (voir Reset-MockState)

$global:MockTenantId = '11111111-2222-3333-4444-555555555555'
$global:MockUser = 'admin@contoso.com'
$global:MockInitial = 'contoso.onmicrosoft.com'

function global:Reset-MockState {
    $global:MockCalls = [System.Collections.Generic.List[object]]::new()
    $global:MockUnrouted = [System.Collections.Generic.List[string]]::new()
    $global:MockOpts = @{
        # Regex sur l'URI Graph complete : toute requete correspondante recoit un 403
        Forbid         = @(
            'signInActivity',
            '/reports/getTeamsUserActivityUserDetail',
            'windowsAutopilotDeviceIdentities',
            '/security/secureScores',
            'deviceManagementScripts',
            '/directoryRoles/22222222-[^/]*/members',
            '/groups/10000000-0000-0000-0000-000000000004/(members|owners)'
        )
        EmptyBody      = @()              # regex sur l'URI : 403 avec corps d'erreur VIDE (reduit a une accolade), comme observe en reel sur deviceManagementScripts
        ForbidAllGraph = $false           # tout Graph en 403 (sauf si ForbidAllExcept)
        ForbidAllExcept = @()
        ExtraGroups    = 0                # groupes de securite supplementaires (test de l'arret apres 10 echecs)
        TeamsChannelsForbid = $false      # /teams/*/channels en 403
        ConcealedNames = $false
        FailCmds       = @()              # noms de cmdlets (Exchange/SPO) qui levent une erreur
        ModuleMissing  = @()              # noms de modules dont Import-Module / Get-Module -ListAvailable echouent
        ExoWrongTenant = $false           # Get-AcceptedDomain sans le domaine initial
        ExoStatsFailIds = @('20000000-0000-0000-0000-000000000003')   # Get-MailboxStatistics en erreur pour ces ids
        DlMemberFailName = 'DL-Ventes'
        DnsAllFail     = $false
        MgContext      = @{ TenantId = $global:MockTenantId; Account = $global:MockUser }
        ConnectMgFails = $false
        OrgNoInitial   = $false
        IntuneMsg      = 'Application is not authorized to perform this operation.'
        InstallError   = ''               # message d'erreur de Install-Module (ex. droits administrateur requis)
        NetDown        = @()              # noms d'hotes HTTPS injoignables pour le preflight (login.microsoftonline.com...)
        MeRoles        = @('Global Administrator')   # roles d'annuaire du compte connecte (sonde d'acces Graph)
    }
}
Reset-MockState

function global:Add-MockCall([string]$Kind, [string]$Cmd, [string]$Method = '', [string]$Uri = '', [string]$Detail = '') {
    $global:MockCalls.Add([pscustomobject]@{ Seq = $global:MockCalls.Count + 1; Kind = $Kind; Cmd = $Cmd; Method = $Method; Uri = $Uri; Detail = $Detail })
}

function global:New-MockError([int]$Status = 403, [string]$Code = 'Forbidden', [string]$Msg = 'Insufficient privileges to complete the operation.', [switch]$EmptyBody) {
    $ex = [System.Net.Http.HttpRequestException]::new("Response status code does not indicate success: $Status ($Code).")
    $er = [System.Management.Automation.ErrorRecord]::new($ex, "MockGraph$Status", [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
    $er.ErrorDetails = if ($EmptyBody) { [System.Management.Automation.ErrorDetails]::new("{`r`n") } else { [System.Management.Automation.ErrorDetails]::new((@{ error = @{ code = $Code; message = $Msg } } | ConvertTo-Json -Compress)) }
    $er
}

# Echec de cmdlet Exchange / SPO simule via $global:MockOpts.FailCmds
function global:Test-MockFail([string]$Cmd) {
    if ($global:MockOpts.FailCmds -contains $Cmd) {
        throw [System.InvalidOperationException]::new("MOCK: $Cmd refuse (The user is not assigned to any management roles).")
    }
}

# ======================================================================================================
# Donnees Graph
# ======================================================================================================
function global:Get-MockUsers {
    $lic1 = [pscustomobject]@{ skuId = '00000000-0000-0000-0000-0000000000a1'; disabledPlans = @() }
    $lic2 = [pscustomobject]@{ skuId = '00000000-0000-0000-0000-0000000000a2'; disabledPlans = @() }
    $mk = {
        param($n, $upn, $name, $type, $enabled, $licenses, $mail)
        [pscustomobject]@{
            id = "20000000-0000-0000-0000-00000000000$n"; userPrincipalName = $upn; displayName = $name; givenName = $name; surname = 'X'
            mail = $mail; mailNickname = ($upn -split '@')[0]
            proxyAddresses = @("SMTP:$mail", "smtp:$(($upn -split '@')[0])@contoso.onmicrosoft.com")
            userType = $type; accountEnabled = $enabled; assignedLicenses = @($licenses)
            createdDateTime = [datetime]'2024-10-24T10:49:05Z'; usageLocation = 'FR'; onPremisesSyncEnabled = $null
            onPremisesSamAccountName = $null; onPremisesDomainName = $null; onPremisesLastSyncDateTime = $null
            department = $null; jobTitle = $null
        }
    }
    @(
        (& $mk 1 'alice@contoso.com' 'Alice' 'Member' $true @($lic1, $lic2) 'alice@contoso.com')
        (& $mk 2 'bob@contoso.com' 'Bob' 'Member' $true @($lic1) 'bob@contoso.com')
        (& $mk 3 'carol@contoso.com' 'Carol' 'Member' $false @($lic1) 'carol@contoso.com')
        (& $mk 4 'dave@contoso.com' 'Dave' 'Member' $true @() 'dave@contoso.com')
        (& $mk 5 'eve_ext.com#EXT#@contoso.onmicrosoft.com' 'Eve' 'Guest' $true @() 'eve@ext.com')
    )
}

function global:Get-MockGroups {
    $g = {
        param($n, $name, $types, $mailEnabled, $secEnabled, $rpo)
        [pscustomobject]@{
            id = "10000000-0000-0000-0000-00000000000$n"; displayName = $name; mail = if ($mailEnabled) { "$name@contoso.com" } else { $null }
            mailNickname = $name; proxyAddresses = if ($mailEnabled) { @("SMTP:$name@contoso.com") } else { @() }
            groupTypes = @($types); mailEnabled = $mailEnabled; securityEnabled = $secEnabled
            resourceProvisioningOptions = @($rpo); visibility = 'Private'; onPremisesSyncEnabled = $null
            createdDateTime = [datetime]'2025-02-27T09:10:11Z'
        }
    }
    $list = @(
        (& $g 1 'Equipe-Projet' @('Unified') $true $false @('Team'))
        (& $g 2 'Groupe-Sans-Equipe' @('Unified') $true $false @())
        (& $g 3 'DL-Ventes' @() $true $false @())
        (& $g 4 'Securite-Admins' @() $false $true @())
    )
    for ($i = 1; $i -le [int]$global:MockOpts.ExtraGroups; $i++) {
        $list += [pscustomobject]@{
            id = ('10000000-0000-0000-0001-{0:D12}' -f $i); displayName = "Extra-$i"; mail = $null; mailNickname = "extra$i"; proxyAddresses = @()
            groupTypes = @(); mailEnabled = $false; securityEnabled = $true; resourceProvisioningOptions = @(); visibility = $null
            onPremisesSyncEnabled = $null; createdDateTime = [datetime]'2025-03-01T00:00:00Z'
        }
    }
    $list
}

function global:New-MockPage($Items, [string]$Next) {
    $p = [ordered]@{ '@odata.context' = 'https://graph.microsoft.com/v1.0/$metadata#mock'; value = @($Items) }
    if ($Next) { $p['@odata.nextLink'] = $Next }
    [pscustomobject]$p
}

function global:Write-MockReport([string]$Report, [string]$File) {
    $csv = switch -Regex ($Report) {
        'getOneDriveUsageAccountDetail' {
            '"Report Refresh Date","Site Id","Site URL","Owner Display Name","Is Deleted","Last Activity Date","File Count","Active File Count","Storage Used (Byte)","Storage Allocated (Byte)","Owner Principal Name","Report Period"' + "`r`n" +
            '"2026-10-22","00000000-0000-0000-0000-000000000000","","7D56F0D79FA5FAA0249B729835EEC004","False","2026-10-21","216","36","633339843","1099511627776","9D7152D4F029FE50264731978279D32D","180"'
        }
        'getSharePointSiteUsageDetail' {
            '"Report Refresh Date","Site Id","Site URL","Owner Display Name","Is Deleted","Last Activity Date","File Count","Active File Count","Page View Count","Visited Page Count","Storage Used (Byte)","Storage Allocated (Byte)","Root Web Template","Owner Principal Name","Report Period"' + "`r`n" +
            '"2026-10-22","00000000-0000-0000-0000-000000000000","","CBB1A8AD256C603CBD9B6CBC59E31E20","False","2026-10-20","393","28","47","8","26975179616","27487790694400","Group","83CFB0497429E7CD4C33B8A61A8C4067","180"'
        }
        'getMailboxUsageDetail' {
            '"Report Refresh Date","User Principal Name","Display Name","Is Deleted","Deleted Date","Created Date","Last Activity Date","Item Count","Storage Used (Byte)","Has Archive","Report Period"' + "`r`n" +
            '"2026-10-22","326800F879E417424EF7958CB8FE8C70","46676377A6E3AE8AD024D4675CEB238D","False","","2018-09-10","2026-10-22","464648","19031437151","False","180"'
        }
        'getOffice365ActiveUserDetail' {
            '"Report Refresh Date","User Principal Name","Display Name","Is Deleted","Has Exchange License","Report Period"' + "`r`n" +
            '"2026-10-20","61849C0799756A2EA27B0DE6D87F0AFC","7B0A0278216468FCC6180D3A61847FD4","False","True","180"'
        }
        default { '"a","b"' + "`r`n" + '"1","2"' }
    }
    # Graph renvoie un CSV UTF-8 avec BOM
    [System.IO.File]::WriteAllText($File, $csv + "`r`n", [System.Text.UTF8Encoding]::new($true))
}

# ======================================================================================================
# Invoke-MgGraphRequest (route par URI). GET seulement : toute autre methode est enregistree (le test echoue)
# ======================================================================================================
function global:Invoke-MgGraphRequest {
    [CmdletBinding()]
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [System.Collections.IDictionary]$Headers,
        [object]$Body,
        [ValidateSet('HashTable', 'Json', 'PSObject', 'HttpResponseMessage')][string]$OutputType,
        [string]$OutputFilePath,
        [string]$InputFilePath,
        [string]$ContentType,
        [string]$Token,
        [switch]$SkipHttpErrorCheck
    )
    $m = "$Method".ToUpperInvariant()
    Add-MockCall 'Graph' 'Invoke-MgGraphRequest' $m $Uri $(if ($OutputFilePath) { 'OutputFilePath' } else { '' })
    if ($m -ne 'GET') { return $null }
    if ($Uri -notmatch '^https://graph\.microsoft\.com/(v1\.0|beta)(/[^?]*)(\?(.*))?$') { throw "MOCK: URI inattendue : $Uri" }
    $ver = $Matches[1]; $path = $Matches[2]; $q = $Matches[4]

    if ($global:MockOpts.ForbidAllGraph) {
        $exempt = $false
        foreach ($rx in @($global:MockOpts.ForbidAllExcept)) { if ($Uri -match $rx) { $exempt = $true } }
        if (-not $exempt) { $PSCmdlet.ThrowTerminatingError((New-MockError 403)) }
    }
    foreach ($rx in @($global:MockOpts.EmptyBody)) { if ($rx -and $Uri -match $rx) { $PSCmdlet.ThrowTerminatingError((New-MockError 403 'Forbidden' '' -EmptyBody)) } }
    foreach ($rx in @($global:MockOpts.Forbid)) {
        if ($Uri -match $rx) { $mm = if ($path -match '^/device(Management|AppManagement)') { $global:MockOpts.IntuneMsg } else { 'Insufficient privileges to complete the operation.' }; $PSCmdlet.ThrowTerminatingError((New-MockError 403 'Forbidden' $mm)) }
    }

    switch -Regex ($path) {
        '^/organization$' {
            $vd = @(
                [pscustomobject]@{ name = 'contoso.onmicrosoft.com'; isInitial = $true; isDefault = $false; type = 'Managed' }
                [pscustomobject]@{ name = 'contoso.com'; isInitial = $false; isDefault = $true; type = 'Managed' }
            )
            if ($global:MockOpts.OrgNoInitial) { $vd = @([pscustomobject]@{ name = 'contoso.com'; isInitial = $false; isDefault = $true }) }
            return (New-MockPage @([pscustomobject]@{
                        id = $global:MockTenantId; displayName = 'Contoso SAS'; verifiedDomains = $vd; countryLetterCode = 'FR'; preferredLanguage = 'fr'
                        onPremisesSyncEnabled = $null; onPremisesLastSyncDateTime = $null; createdDateTime = [datetime]'2018-05-18T10:00:00Z'
                    }))
        }
        '^/subscribedSkus$' {
            return (New-MockPage @(
                    [pscustomobject]@{ skuId = '00000000-0000-0000-0000-0000000000a1'; skuPartNumber = 'O365_BUSINESS_PREMIUM'; capabilityStatus = 'Enabled'; consumedUnits = 3; prepaidUnits = [pscustomobject]@{ enabled = 25; suspended = 0; warning = 0 } }
                    [pscustomobject]@{ skuId = '00000000-0000-0000-0000-0000000000a2'; skuPartNumber = 'O365_BUSINESS'; capabilityStatus = 'Enabled'; consumedUnits = 1; prepaidUnits = [pscustomobject]@{ enabled = 5 } }
                ))
        }
        '^/users$' {
            $u = Get-MockUsers
            if ($q -match 'signInActivity') {
                return (New-MockPage ($u | ForEach-Object { [pscustomobject]@{ id = $_.id; signInActivity = [pscustomobject]@{ lastSignInDateTime = [datetime]'2026-10-23T08:14:44Z'; lastNonInteractiveSignInDateTime = [datetime]'2026-10-23T11:50:30Z' } } }))
            }
            if ($q -match 'skiptoken=P2') { return (New-MockPage $u[3..4]) }
            return (New-MockPage $u[0..2] 'https://graph.microsoft.com/v1.0/users?$select=id&$top=999&$skiptoken=P2')
        }
        '^/groups$' {
            $g = @(Get-MockGroups)
            if ($q -match 'skiptoken=P2') { return (New-MockPage $g[2..($g.Count - 1)]) }
            return (New-MockPage $g[0..1] 'https://graph.microsoft.com/v1.0/groups?$select=id&$top=999&$skiptoken=P2')
        }
        '^/groups/[^/]+/(members|owners)/\$count$' { return 7 }
        '^/domains$' {
            return (New-MockPage @(
                    [pscustomobject]@{ id = 'contoso.onmicrosoft.com'; isVerified = $true; isDefault = $false; isInitial = $true; authenticationType = 'Managed'; supportedServices = @('Email', 'OfficeCommunicationsOnline') }
                    [pscustomobject]@{ id = 'contoso.com'; isVerified = $true; isDefault = $true; isInitial = $false; authenticationType = 'Managed'; supportedServices = @('Email') }
                    [pscustomobject]@{ id = 'fr.contoso.com'; isVerified = $true; isDefault = $false; isInitial = $false; authenticationType = 'Managed'; supportedServices = @() }
                    [pscustomobject]@{ id = 'err.contoso.com'; isVerified = $true; isDefault = $false; isInitial = $false; authenticationType = 'Managed'; supportedServices = @() }
                    [pscustomobject]@{ id = 'pending.contoso.com'; isVerified = $false; isDefault = $false; isInitial = $false; authenticationType = 'Managed'; supportedServices = @() }
                ))
        }
        '^/teams/([^/]+)/channels$' {
            if ($global:MockOpts.TeamsChannelsForbid) { $PSCmdlet.ThrowTerminatingError((New-MockError 403)) }
            return (New-MockPage @(
                    [pscustomobject]@{ id = '19:a@thread.tacv2'; displayName = 'General'; membershipType = 'standard' }
                    [pscustomobject]@{ id = '19:b@thread.tacv2'; displayName = 'Direction'; membershipType = 'private' }
                    [pscustomobject]@{ id = '19:c@thread.tacv2'; displayName = 'Partenaires'; membershipType = 'shared' }
                ))
        }
        '^/admin/reportSettings$' {
            return [pscustomobject]@{ '@odata.context' = 'https://graph.microsoft.com/v1.0/$metadata#admin/reportSettings/$entity'; displayConcealedNames = [bool]$global:MockOpts.ConcealedNames }
        }
        '^/reports/(\w+)\(period=''D180''\)$' {
            if (-not $OutputFilePath) { throw 'MOCK: rapport sans -OutputFilePath' }
            Write-MockReport $Matches[1] $OutputFilePath
            return $null
        }
        '^/reports/getOneDriveUsageAccountCounts\(period=''D7''\)$' {
            if (-not $OutputFilePath) { throw 'MOCK: rapport sans -OutputFilePath' }
            Write-MockReport 'getOneDriveUsageAccountCounts' $OutputFilePath
            return $null
        }
        '^/me/transitiveMemberOf/microsoft\.graph\.directoryRole$' {
            return (New-MockPage @($global:MockOpts.MeRoles | ForEach-Object { [pscustomobject]@{ '@odata.type' = '#microsoft.graph.directoryRole'; displayName = $_ } }))
        }
        '^/reports/authenticationMethods/userRegistrationDetails$' {
            return (New-MockPage @(
                    [pscustomobject]@{ id = '20000000-0000-0000-0000-000000000001'; userPrincipalName = 'alice@contoso.com'; isAdmin = $true; isMfaRegistered = $false; isMfaCapable = $false; isSsprRegistered = $false; isPasswordlessCapable = $false; defaultMfaMethod = $null; methodsRegistered = @() }
                    [pscustomobject]@{ id = '20000000-0000-0000-0000-000000000002'; userPrincipalName = 'bob@contoso.com'; isAdmin = $false; isMfaRegistered = $true; isMfaCapable = $true; isSsprRegistered = $true; isPasswordlessCapable = $false; defaultMfaMethod = 'mobilePhone'; methodsRegistered = @('mobilePhone', 'softwareOneTimePasscode') }
                ))
        }
        '^/servicePrincipals$' {
            return (New-MockPage @(
                    [pscustomobject]@{ id = 's1'; displayName = 'Microsoft Graph'; appId = '00000003-0000-0000-c000-000000000000'; servicePrincipalType = 'Application'; preferredSingleSignOnMode = $null; accountEnabled = $true; appOwnerOrganizationId = 'f8cdef31-a31e-4b4a-93e4-5f571e91255a'; tags = @() }
                    [pscustomobject]@{ id = 's2'; displayName = 'Contoso Reporting App'; appId = 'aaaaaaaa-0000-0000-0000-000000000001'; servicePrincipalType = 'Application'; preferredSingleSignOnMode = 'saml'; accountEnabled = $true; appOwnerOrganizationId = 'aaaaaaaa-0000-0000-0000-000000000002'; tags = @('WindowsAzureActiveDirectoryIntegratedApp') }
                    [pscustomobject]@{ id = 's3'; displayName = 'Managed id'; appId = 'x'; servicePrincipalType = 'ManagedIdentity'; preferredSingleSignOnMode = $null; accountEnabled = $true; appOwnerOrganizationId = $null; tags = @() }
                ))
        }
        '^/devices$' {
            return (New-MockPage @(
                    [pscustomobject]@{ id = 'd1'; displayName = 'PC-001'; operatingSystem = 'Windows'; operatingSystemVersion = '10.0.26200'; trustType = 'AzureAd'; isManaged = $true; isCompliant = $true; approximateLastSignInDateTime = [datetime]'2026-10-19T08:34:21Z'; registrationDateTime = [datetime]'2024-09-19T12:56:48Z'; onPremisesSyncEnabled = $null; profileType = 'RegisteredDevice'; manufacturer = 'LENOVO'; model = '20TA' }
                    [pscustomobject]@{ id = 'd2'; displayName = 'PC-002'; operatingSystem = 'iOS'; operatingSystemVersion = '18'; trustType = 'Workplace'; isManaged = $false; isCompliant = $null; approximateLastSignInDateTime = $null; registrationDateTime = $null; onPremisesSyncEnabled = $null; profileType = 'RegisteredDevice'; manufacturer = 'Apple'; model = 'iPhone' }
                ))
        }
        '^/deviceManagement/managedDevices$' {
            return (New-MockPage @([pscustomobject]@{ id = 'm1'; deviceName = 'PC-001'; operatingSystem = 'Windows'; osVersion = '10.0.26200'; managedDeviceOwnerType = 'company'; complianceState = 'compliant'; enrolledDateTime = [datetime]'2025-01-01T00:00:00Z'; lastSyncDateTime = [datetime]'2026-10-20T00:00:00Z'; model = 'X'; manufacturer = 'LENOVO'; deviceEnrollmentType = 'windowsAzureADJoin'; managementAgent = 'mdm'; userPrincipalName = 'alice@contoso.com'; azureADDeviceId = 'd1'; isEncrypted = $true; autopilotEnrolled = $false }))
        }
        '^/deviceManagement/windowsAutopilotDeviceIdentities$' {
            return (New-MockPage @([pscustomobject]@{ id = 'a1'; serialNumber = 'SN1'; manufacturer = 'LENOVO'; model = 'X'; groupTag = 'G'; enrollmentState = 'enrolled'; lastContactedDateTime = [datetime]'2026-10-20T00:00:00Z'; deploymentProfileAssignmentStatus = 'assignedUnkownSyncState' }))
        }
        '^/deviceManagement/deviceCompliancePolicies$' { return (New-MockPage @([pscustomobject]@{ id = 'c1'; displayName = 'Secure Boot'; '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; createdDateTime = [datetime]'2025-01-27T16:30:46Z' }, [pscustomobject]@{ id = 'c2'; displayName = 'iOS'; '@odata.type' = '#microsoft.graph.iosCompliancePolicy'; createdDateTime = [datetime]'2025-02-01T00:00:00Z' })) }
        '^/deviceManagement/deviceConfigurations$' { return (New-MockPage @([pscustomobject]@{ id = 'p1'; displayName = 'Wifi'; '@odata.type' = '#microsoft.graph.windowsWifiConfiguration'; createdDateTime = [datetime]'2025-03-01T00:00:00Z' })) }
        '^/deviceManagement/configurationPolicies$' {
            if ($ver -ne 'beta') { throw 'MOCK: configurationPolicies attend beta' }
            return (New-MockPage @([pscustomobject]@{ id = 'sc1'; name = 'Baseline'; createdDateTime = [datetime]'2025-04-01T00:00:00Z' }))
        }
        '^/deviceAppManagement/mobileApps$' { return (New-MockPage @()) }
        '^/deviceAppManagement/managedAppPolicies$' { return (New-MockPage @([pscustomobject]@{ id = 'mp1'; displayName = 'MAM'; '@odata.type' = '#microsoft.graph.iosManagedAppProtection'; createdDateTime = [datetime]'2025-05-01T00:00:00Z' })) }
        '^/deviceManagement/deviceManagementScripts$' { return (New-MockPage @([pscustomobject]@{ id = 'sc'; displayName = 'Script'; createdDateTime = [datetime]'2025-05-01T00:00:00Z' })) }
        '^/deviceManagement/windowsAutopilotDeploymentProfiles$' {
            if ($ver -ne 'beta') { throw 'MOCK: autopilot profiles attend beta' }
            return (New-MockPage @([pscustomobject]@{ id = 'ap1'; displayName = 'AP'; '@odata.type' = '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile'; createdDateTime = [datetime]'2025-06-01T00:00:00Z' }))
        }
        '^/deviceManagement/deviceEnrollmentConfigurations$' { return (New-MockPage @([pscustomobject]@{ id = 'e1'; displayName = 'ESP'; '@odata.type' = '#microsoft.graph.windows10EnrollmentCompletionPageConfiguration'; createdDateTime = [datetime]'2025-06-01T00:00:00Z' }, [pscustomobject]@{ id = 'e2'; displayName = 'Limit'; '@odata.type' = '#microsoft.graph.deviceEnrollmentLimitConfiguration'; createdDateTime = $null })) }
        '^/identity/conditionalAccess/policies$' { return (New-MockPage @()) }   # liste vide volontaire
        '^/policies/identitySecurityDefaultsEnforcementPolicy$' { return [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000005'; displayName = 'Security Defaults'; isEnabled = $false } }
        '^/policies/authorizationPolicy$' {
            return (New-MockPage @([pscustomobject]@{ id = 'authorizationPolicy'; allowInvitesFrom = 'everyone'; allowedToSignUpEmailBasedSubscriptions = $true; allowEmailVerifiedUsersToJoinOrganization = $false; guestUserRoleId = '10dae51f-b6af-4016-8d66-8c2a99b929b3'
                        defaultUserRolePermissions = [pscustomobject]@{ allowedToCreateApps = $true; allowedToCreateSecurityGroups = $true; allowedToCreateTenants = $true; permissionGrantPoliciesAssigned = @('ManagePermissionGrantsForSelf.microsoft-user-default-low', 'ManagePermissionGrantsForOwnedResource.x') } }))
        }
        '^/policies/crossTenantAccessPolicy/default$' {
            return [pscustomobject]@{ b2bCollaborationInbound = [pscustomobject]@{ usersAndGroups = [pscustomobject]@{ accessType = 'allowed'; targets = @([pscustomobject]@{ target = 'AllUsers'; targetType = 'user' }) } }
                b2bCollaborationOutbound = $null; inboundTrust = [pscustomobject]@{ isMfaAccepted = $false }; tenantRestrictions = $null
            }
        }
        '^/directoryRoles$' {
            return (New-MockPage @([pscustomobject]@{ id = '11111111-0000-0000-0000-000000000001'; displayName = 'Global Administrator' }, [pscustomobject]@{ id = '22222222-0000-0000-0000-000000000002'; displayName = 'Directory Writers' }))
        }
        '^/directoryRoles/([^/]+)/members$' {
            return (New-MockPage @([pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; id = '20000000-0000-0000-0000-000000000001'; displayName = 'Alice'; userPrincipalName = 'alice@contoso.com' }, [pscustomobject]@{ '@odata.type' = '#microsoft.graph.servicePrincipal'; id = 's2'; displayName = 'AppSP' }))
        }
        '^/security/secureScores$' {
            return (New-MockPage @([pscustomobject]@{ id = 'ss1'; createdDateTime = [datetime]'2026-10-24T00:00:00Z'; currentScore = 107.34; maxScore = 272; activeUserCount = 35; licensedUserCount = 0 }))
        }
        '^/policies/authenticationMethodsPolicy$' {
            return [pscustomobject]@{ id = 'authenticationMethodsPolicy'; authenticationMethodConfigurations = @([pscustomobject]@{ id = 'Fido2'; state = 'enabled' }, [pscustomobject]@{ id = 'Sms'; state = 'disabled' }) }
        }
        default {
            $global:MockUnrouted.Add("$ver$path")
            $PSCmdlet.ThrowTerminatingError((New-MockError 404 'NotFound' "MOCK: route inconnue $ver$path"))
        }
    }
}

# --- Graph : connexion (jamais reelle) ------------------------------------------------------------
function global:Connect-MgGraph {
    [CmdletBinding()]
    param([string]$TenantId, [string[]]$Scopes, [string]$ContextScope, [switch]$NoWelcome, [string]$ClientId, [switch]$UseDeviceAuthentication)
    Add-MockCall 'Graph' 'Connect-MgGraph' '' '' ("Scopes=" + ($Scopes -join ',') + ";ContextScope=$ContextScope")
    if ($global:MockOpts.ConnectMgFails) { throw 'MOCK: authentification annulee' }
}
function global:Get-MgContext { [CmdletBinding()] param() Add-MockCall 'Graph' 'Get-MgContext'; if ($global:MockOpts.MgContext) { [pscustomobject]$global:MockOpts.MgContext } }
function global:Disconnect-MgGraph { [CmdletBinding()] param() Add-MockCall 'Graph' 'Disconnect-MgGraph' }

# --- Garde-fous : aucune interaction, aucune installation ----------------------------------------
# Decompte avant les fenetres de connexion : jamais d'attente reelle (chaque appel est enregistre, le banc reste rapide)
function global:Start-Sleep { [CmdletBinding()] param([Parameter(Position = 0)][double]$Seconds, [int]$Milliseconds) Add-MockCall 'Sleep' 'Start-Sleep' '' '' "$Seconds" }
function global:Read-Host { [CmdletBinding()] param([Parameter(Position = 0)][string]$Prompt) Add-MockCall 'Interactive' 'Read-Host' '' '' $Prompt; 'N' }
function global:Install-Module { [CmdletBinding()] param([Parameter(Position = 0)][string[]]$Name, [string]$Repository, [string]$Scope, [switch]$Force, [switch]$AllowClobber) Add-MockCall 'Install' 'Install-Module' '' '' "$Name"; throw $(if ($global:MockOpts.InstallError) { $global:MockOpts.InstallError } else { 'MOCK: Install-Module interdit en test' }) }

# --- Preflight du poste : aucun reseau, aucune galerie, aucune installation de fournisseur ------------
function global:Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, [string]$Method, [int]$TimeoutSec, [switch]$UseBasicParsing, [switch]$SkipHttpErrorCheck)
    $h = ([uri]$Uri).Host
    Add-MockCall 'Net' 'Invoke-WebRequest' '' $Uri $h
    if ($global:MockOpts.NetDown -contains $h) { throw 'No such host is known.' }
    [pscustomobject]@{ StatusCode = 200 }
}
function global:Get-PSRepository { [CmdletBinding()] param([string]$Name) Add-MockCall 'Gallery' 'Get-PSRepository'; [pscustomobject]@{ Name = 'PSGallery'; InstallationPolicy = 'Trusted' } }
function global:Set-PSRepository { [CmdletBinding()] param([string]$Name, [string]$InstallationPolicy) Add-MockCall 'Install' 'Set-PSRepository'; throw 'MOCK: Set-PSRepository interdit en test' }
function global:Get-PackageProvider { [CmdletBinding()] param([string]$Name, [switch]$ListAvailable) Add-MockCall 'Gallery' 'Get-PackageProvider'; [pscustomobject]@{ Name = 'NuGet'; Version = [version]'2.8.5.208' } }
function global:Install-PackageProvider { [CmdletBinding()] param([string]$Name, [string]$Scope, [switch]$Force) Add-MockCall 'Install' 'Install-PackageProvider'; throw 'MOCK: Install-PackageProvider interdit en test' }

# --- Modules : aucun vrai chargement -------------------------------------------------------------
$global:MockKnownModules = @('Microsoft.Graph.Authentication', 'ExchangeOnlineManagement', 'Microsoft.Online.SharePoint.PowerShell')
function global:Import-Module {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Name, [switch]$DisableNameChecking, [switch]$Force, [switch]$Global, [switch]$PassThru)
    Add-MockCall 'Module' 'Import-Module' '' '' "$Name"
    if ($Name -and $Name[0] -in $global:MockKnownModules) {
        if ($global:MockOpts.ModuleMissing -contains $Name[0]) { throw "The specified module '$($Name[0])' was not loaded because no valid module file was found in any module directory." }
        return
    }
    throw "MOCK: Import-Module non simule pour '$Name'"
}
function global:Get-Module {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string[]]$Name, [switch]$ListAvailable, [switch]$All)
    Add-MockCall 'Module' 'Get-Module' '' '' "$Name"
    foreach ($n in $Name) {
        if ($n -in $global:MockKnownModules -and $global:MockOpts.ModuleMissing -notcontains $n) { [pscustomobject]@{ Name = $n; Version = [version]'9.9.9' } }
    }
}

# Remplace le processus enfant `pwsh -NoProfile -File <script> -Worker X -ContextFile Y` par un appel en processus
function global:pwsh {
    $a = @($args)
    Add-MockCall 'Process' 'pwsh' '' '' ($a -join ' ')
    $fi = [array]::IndexOf($a, '-File'); $wi = [array]::IndexOf($a, '-Worker'); $ci = [array]::IndexOf($a, '-ContextFile')
    if ($fi -lt 0 -or $wi -lt 0 -or $ci -lt 0) { throw "MOCK: pwsh appele avec des arguments inattendus : $($a -join ' ')" }
    & $a[$fi + 1] -Worker $a[$wi + 1] -ContextFile $a[$ci + 1]
}

# ======================================================================================================
# Exchange Online
# ======================================================================================================
function global:Connect-ExchangeOnline {
    [CmdletBinding()]
    param([string]$UserPrincipalName, [switch]$DisableWAM, [switch]$ShowBanner, [string]$Organization, [switch]$UseRPSSession)
    Add-MockCall 'EXO' 'Connect-ExchangeOnline' '' '' "UPN=$UserPrincipalName;DisableWAM=$DisableWAM;ShowBanner=$ShowBanner"
    Test-MockFail 'Connect-ExchangeOnline'
}
function global:Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess)] param() Add-MockCall 'EXO' 'Disconnect-ExchangeOnline' }

function global:Get-AcceptedDomain {
    [CmdletBinding()] param([string]$Identity)
    Add-MockCall 'EXO' 'Get-AcceptedDomain'; Test-MockFail 'Get-AcceptedDomain'
    if ($global:MockOpts.ExoWrongTenant) { return [pscustomobject]@{ DomainName = 'autre.onmicrosoft.com'; DomainType = 'Authoritative'; Default = $true } }
    [pscustomobject]@{ DomainName = 'contoso.onmicrosoft.com'; DomainType = 'Authoritative'; Default = $false }
    [pscustomobject]@{ DomainName = 'contoso.com'; DomainType = 'Authoritative'; Default = $true }
}

function global:Get-OrganizationConfig {
    [CmdletBinding()] param([string]$Identity)
    Add-MockCall 'EXO' 'Get-OrganizationConfig'; Test-MockFail 'Get-OrganizationConfig'
    [pscustomobject]@{
        Name = 'contoso.onmicrosoft.com'; AuditDisabled = $false; PublicFoldersEnabled = 'None'; OAuth2ClientProfileEnabled = $true
        DefaultAuthenticationPolicy = ''; SmtpClientAuthenticationDisabled = $true; ConnectorsEnabled = $true; MailTipsAllTipsEnabled = $true; CustomerLockboxEnabled = $false
        EwsEnabled = $null; EwsAllowList = $null; EwsBlockList = $null; EwsAllowMacOutlook = $null; EwsAllowOutlook = $null; EwsAllowEntourage = $null
        EwsApplicationAccessPolicy = $null; EwsOperationAccessPolicyEnabled = $null; EwsOperationAccessPolicyAllowList = $null; EwsOperationAccessPolicyPopulated = $false; EwsAllowedAppIDs = @('ac1e5a45-2177-412c-ac06-09ba04df530a', 'abcdef00-0000-0000-0000-000000000000')
    }
}

function global:Get-MockMailboxes {
    $mk = {
        param($n, $upn, $name, $type, $arch, $lit, $fwd)
        [pscustomobject]@{
            RecipientTypeDetails = $type; PrimarySmtpAddress = $upn; EmailAddresses = @("SMTP:$upn", "smtp:$(($upn -split '@')[0])@contoso.onmicrosoft.com"); Alias = ($upn -split '@')[0]
            DisplayName = $name; UserPrincipalName = $upn; ExternalDirectoryObjectId = "20000000-0000-0000-0000-00000000000$n"
            ArchiveStatus = $arch; ArchiveGuid = [guid]::Empty; LitigationHoldEnabled = $lit; RetentionHoldEnabled = $false
            ForwardingSmtpAddress = $fwd; ForwardingAddress = $null; DeliverToMailboxAndForward = $false; HiddenFromAddressListsEnabled = $false
        }
    }
    @(
        (& $mk 1 'alice@contoso.com' 'Alice' 'UserMailbox' 'Active' $true $null)
        (& $mk 2 'bob@contoso.com' 'Bob' 'UserMailbox' 'None' $false 'smtp:bob@ext.com')
        (& $mk 3 'carol@contoso.com' 'Carol' 'UserMailbox' 'None' $false $null)
        (& $mk 4 'dave@contoso.com' 'Dave' 'UserMailbox' 'None' $false $null)
        (& $mk 5 'support@contoso.com' 'Support' 'SharedMailbox' 'None' $false $null)
        (& $mk 6 'salle1@contoso.com' 'Salle 1' 'RoomMailbox' 'None' $false $null)
        (& $mk 7 'ghost@contoso.com' 'Ghost' 'UserMailbox' 'None' $false $null)
    )
}

function global:Get-EXOCASMailbox {
    [CmdletBinding()] param([string]$Identity, [string]$ResultSize, [string[]]$PropertySets, [string[]]$Properties)
    Add-MockCall 'EXO' 'Get-EXOCASMailbox'; Test-MockFail 'Get-EXOCASMailbox'
    $i = 0
    foreach ($m in (Get-MockMailboxes)) { $i++; [pscustomobject]@{ ExternalDirectoryObjectId = $m.ExternalDirectoryObjectId; PrimarySmtpAddress = $m.PrimarySmtpAddress; EwsEnabled = $(if ($i -eq 2) { $false } elseif ($i -eq 3) { $true } else { $null }) } }
}

function global:Get-EXOMailbox {
    [CmdletBinding()]
    param([string]$Identity, [string]$ResultSize, [string[]]$Properties, [string[]]$PropertySets, [string[]]$RecipientTypeDetails, [switch]$PublicFolder, [switch]$Archive, [string]$Filter)
    Add-MockCall 'EXO' 'Get-EXOMailbox' '' '' "PublicFolder=$PublicFolder;Properties=$($Properties -join ',')"
    # Comme le vrai cmdlet : avertissement parasite quand le resultat est borne (doit etre supprime par -WarningAction SilentlyContinue)
    if ("$ResultSize" -eq '1') { Write-Warning 'MOCK-WARN: There are more results than ResultSize 1 (Get-EXOMailbox).' }
    Test-MockFail 'Get-EXOMailbox'
    if ($PublicFolder) { return }
    if ($Properties -contains 'WhenCreated') { throw 'MOCK: WhenCreated ne doit pas etre demande a Get-EXOMailbox ' }
    Get-MockMailboxes
}

function global:Get-Mailbox {
    [CmdletBinding()] param([string]$Identity, [string]$ResultSize, [switch]$PublicFolder)
    Add-MockCall 'EXO' 'Get-Mailbox'; Test-MockFail 'Get-Mailbox'
    if ($PublicFolder) { return }
    foreach ($m in (Get-MockMailboxes)) { [pscustomobject]@{ ExternalDirectoryObjectId = $m.ExternalDirectoryObjectId; WhenCreatedUTC = [datetime]'2024-10-24T10:49:05' } }
}

function global:Get-MailboxStatistics {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Identity, [switch]$Archive)
    Add-MockCall 'EXO' 'Get-MailboxStatistics' '' '' "Id=$Identity;Archive=$Archive"
    Write-Warning 'MOCK-WARN: Get-MailboxStatistics avertissement simule.'
    Test-MockFail 'Get-MailboxStatistics'
    if ($global:MockOpts.ExoStatsFailIds -contains $Identity) { throw [System.InvalidOperationException]::new("MOCK: statistiques indisponibles pour $Identity") }
    if ($Archive) { return [pscustomobject]@{ TotalItemSize = '60 GB (64,424,509,440 bytes)'; TotalDeletedItemSize = '0 B (0 bytes)'; ItemCount = 500; LastUserActionTime = $null; LastLogonTime = $null } }
    if ($Identity -eq '20000000-0000-0000-0000-000000000001') {
        return [pscustomobject]@{ TotalItemSize = '120 GB (128,849,018,880 bytes)'; TotalDeletedItemSize = '1.5 GB (1,610,612,736 bytes)'; ItemCount = 90000; LastUserActionTime = [datetime]'2026-10-12T08:55:45'; LastLogonTime = [datetime]'2026-10-12T18:14:11' }
    }
    [pscustomobject]@{ TotalItemSize = '11.05 GB (11,864,090,092 bytes)'; TotalDeletedItemSize = '4.22 MB (4,428,419 bytes)'; ItemCount = 12167; LastUserActionTime = [datetime]'2026-10-12T08:55:45'; LastLogonTime = [datetime]'2026-10-12T18:14:11' }
}

function global:Get-EXOMailboxPermission {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Identity, [string]$User)
    Add-MockCall 'EXO' 'Get-EXOMailboxPermission'; Test-MockFail 'Get-EXOMailboxPermission'
    [pscustomobject]@{ Identity = $Identity; User = 'alice@contoso.com'; AccessRights = @('FullAccess'); IsInherited = $false; Deny = $false }
    [pscustomobject]@{ Identity = $Identity; User = 'NT AUTHORITY\SELF'; AccessRights = @('FullAccess', 'ReadPermission'); IsInherited = $false; Deny = $false }
    [pscustomobject]@{ Identity = $Identity; User = 'S-1-5-21-1-2-3-500'; AccessRights = @('FullAccess'); IsInherited = $false; Deny = $false }
    [pscustomobject]@{ Identity = $Identity; User = 'EURPR01\Admins'; AccessRights = @('FullAccess'); IsInherited = $true; Deny = $false }
}

function global:Get-EXORecipientPermission {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Identity, [string[]]$AccessRights, [string]$Trustee)
    Add-MockCall 'EXO' 'Get-EXORecipientPermission'; Test-MockFail 'Get-EXORecipientPermission'
    [pscustomobject]@{ Identity = $Identity; Trustee = 'bob@contoso.com'; AccessRights = @('SendAs'); IsInherited = $false }
    [pscustomobject]@{ Identity = $Identity; Trustee = 'NT AUTHORITY\SELF'; AccessRights = @('SendAs'); IsInherited = $false }
}

function global:Get-EXORecipient {
    [CmdletBinding()] param([string]$Identity, [string]$ResultSize, [string[]]$RecipientTypeDetails, [string[]]$Properties)
    Add-MockCall 'EXO' 'Get-EXORecipient' '' '' "Types=$($RecipientTypeDetails -join ',')"
    Test-MockFail 'Get-EXORecipient'
    $dl = {
        param($n, $name, $type)
        [pscustomobject]@{ DisplayName = $name; PrimarySmtpAddress = "$name@contoso.com"; Alias = $name; RecipientTypeDetails = $type; ExternalDirectoryObjectId = "30000000-0000-0000-0000-00000000000$n"; EmailAddresses = @("SMTP:$name@contoso.com"); ExternalEmailAddress = $null }
    }
    $dls = @((& $dl 1 'DL-Ventes' 'MailUniversalDistributionGroup'), (& $dl 2 'DL-Tous' 'MailUniversalDistributionGroup'), (& $dl 3 'DDL-Paris' 'DynamicDistributionGroup'), (& $dl 4 'Sec-Mail' 'MailUniversalSecurityGroup'))
    $contacts = @(
        [pscustomobject]@{ DisplayName = 'Contact1'; PrimarySmtpAddress = 'c1@ext.com'; Alias = 'c1'; RecipientTypeDetails = 'MailContact'; ExternalEmailAddress = 'SMTP:c1@ext.com'; EmailAddresses = @('SMTP:c1@ext.com') }
        [pscustomobject]@{ DisplayName = 'MailUser1'; PrimarySmtpAddress = 'mu1@ext.com'; Alias = 'mu1'; RecipientTypeDetails = 'MailUser'; ExternalEmailAddress = 'SMTP:mu1@ext.com'; EmailAddresses = @('SMTP:mu1@ext.com') }
    )
    if ($RecipientTypeDetails -contains 'MailContact') { return $contacts }
    if ($RecipientTypeDetails -contains 'MailUniversalDistributionGroup') { return $dls }
    $all = @()
    foreach ($m in (Get-MockMailboxes)) { $all += [pscustomobject]@{ Alias = $m.Alias; DisplayName = $m.DisplayName; PrimarySmtpAddress = $m.PrimarySmtpAddress; RecipientTypeDetails = $m.RecipientTypeDetails; EmailAddresses = $m.EmailAddresses } }
    $all + $dls + $contacts
}

function global:Get-DistributionGroupMember {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$Identity, [string]$ResultSize)
    Add-MockCall 'EXO' 'Get-DistributionGroupMember' '' '' "Id=$Identity"
    Test-MockFail 'Get-DistributionGroupMember'
    if ($Identity -eq '30000000-0000-0000-0000-000000000002') { throw [System.InvalidOperationException]::new('MOCK: liste introuvable') }
    1..3 | ForEach-Object { [pscustomobject]@{ Name = "member$_" } }
}

function global:Get-InboundConnector {
    [CmdletBinding()] param([string]$Identity)
    Add-MockCall 'EXO' 'Get-InboundConnector'; Test-MockFail 'Get-InboundConnector'
    [pscustomobject]@{ Name = 'From Mimecast'; Enabled = $true; ConnectorType = 'Partner'; SenderDomains = @('smtp:*;1'); SenderIPAddresses = @('1.2.3.4', '5.6.7.8'); TlsSenderCertificateName = 'mimecast.com'; Comment = 'c' }
}
function global:Get-OutboundConnector {
    [CmdletBinding()] param([string]$Identity, [switch]$IncludeTestModeConnectors)
    Add-MockCall 'EXO' 'Get-OutboundConnector'; Test-MockFail 'Get-OutboundConnector'
    [pscustomobject]@{ Name = 'To Mimecast'; Enabled = $true; ConnectorType = 'Partner'; SmartHosts = @('smtp.mimecast.com'); RecipientDomains = @('*'); TlsDomain = 'mimecast.com'; Comment = $null }
}
function global:Get-TransportRule {
    [CmdletBinding()] param([string]$Identity, [string]$ResultSize)
    Add-MockCall 'EXO' 'Get-TransportRule'; Test-MockFail 'Get-TransportRule'
    [pscustomobject]@{ Name = 'Disclaimer'; State = 'Enabled'; Priority = 0; Mode = 'Enforce'; Description = "Si le message`r`n   est externe`r`n   alors ajouter un avertissement" }
    [pscustomobject]@{ Name = 'Sans description'; State = 'Disabled'; Priority = 1; Mode = 'Audit'; Description = $null }
}
function global:Get-DkimSigningConfig {
    [CmdletBinding()] param([string]$Identity)
    Add-MockCall 'EXO' 'Get-DkimSigningConfig'; Test-MockFail 'Get-DkimSigningConfig'
    [pscustomobject]@{ Domain = 'contoso.com'; Enabled = $true; Status = 'Valid' }
    [pscustomobject]@{ Domain = 'contoso.onmicrosoft.com'; Enabled = $true; Status = 'Valid' }
}

# ======================================================================================================
# SharePoint Online
# ======================================================================================================
function global:Connect-SPOService {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Url, [object]$Credential, [switch]$ModernAuth)
    Add-MockCall 'SPO' 'Connect-SPOService' '' $Url
    Test-MockFail 'Connect-SPOService'
}
function global:Disconnect-SPOService { [CmdletBinding()] param() Add-MockCall 'SPO' 'Disconnect-SPOService' }

function global:Get-SPOSite {
    [CmdletBinding()] param([string]$Limit, [bool]$IncludePersonalSite, [string]$Filter, [string]$Identity)
    Add-MockCall 'SPO' 'Get-SPOSite' '' '' "Limit=$Limit;IncludePersonalSite=$IncludePersonalSite"
    # Texte reel du module SPO quand -Limit borne le resultat (constate lors d'un premier test reel)
    if ("$Limit" -eq '1') { Write-Warning "MOCK-WARN: More results were found but were not returned. Use '-Limit ALL' to return all possible results." }
    Test-MockFail 'Get-SPOSite'
    $z = '00000000-0000-0000-0000-000000000000'
    $s = {
        param($url, $title, $tpl, $owner, $mb, $gid, $team, $chan, $chanType)
        [pscustomobject]@{
            Url = $url; Title = $title; Template = $tpl; Owner = $owner; StorageUsageCurrent = [uint64]$mb
            LastContentModifiedDate = [datetime]'2026-10-12T06:59:10'; GroupId = [guid]$gid; RelatedGroupId = [guid]$z
            IsTeamsConnected = $team; IsTeamsChannelConnected = $chan; TeamsChannelType = $chanType
            SharingCapability = 'ExternalUserAndGuestSharing'; LockState = 'Unlock'; HubSiteId = [guid]$z
        }
    }
    $r = @(
        (& $s 'https://contoso-my.sharepoint.com/personal/alice_contoso_com' 'Alice' 'SPSPERS#10' 'alice@contoso.com' 30720 $z $false $false 'None')
        (& $s 'https://contoso-my.sharepoint.com/personal/bob_contoso_com' 'Bob' 'SPSPERS#10' 'bob@contoso.com' 100 $z $false $false 'None')
        (& $s 'https://contoso-my.sharepoint.com/personal/carol_contoso_com' 'Carol' 'SPSPERS#10' 'carol@contoso.com' 2048 $z $false $false 'None')
        (& $s 'https://contoso-my.sharepoint.com/personal/orphan_contoso_com' 'Orphan' 'SPSPERS#10' 'orphan@contoso.com' 5 $z $false $false 'None')
        (& $s 'https://contoso.sharepoint.com/sites/equipe-projet' 'Equipe-Projet' 'GROUP#0' 'c:0o.c|federateddirectoryclaimprovider|10000000-0000-0000-0000-000000000001_o' 40000 '10000000-0000-0000-0000-000000000001' $true $false 'None')
        (& $s 'https://contoso.sharepoint.com/sites/groupe-sans-equipe' 'Groupe-Sans-Equipe' 'GROUP#0' 'x' 500 '10000000-0000-0000-0000-000000000002' $false $false 'None')
        (& $s 'https://contoso.sharepoint.com/sites/equipe-projet-Direction' 'Direction' 'TEAMCHANNEL#1' 'x' 300 $z $false $true 'PrivateChannel')
        (& $s 'https://contoso.sharepoint.com/sites/equipe-projet-Partenaires' 'Partenaires' 'TEAMCHANNEL#1' 'x' 300 $z $false $true 'SharedChannel')
        (& $s 'https://contoso.sharepoint.com/sites/vide' 'Vide' 'STS#3' 'x' 0 $z $false $false 'None')
        (& $s 'https://contoso.sharepoint.com/sites/intranet' 'Intranet' 'SITEPAGEPUBLISHING#0' 'x' 2000 $z $false $false 'None')
        (& $s 'https://contoso.sharepoint.com/' 'Racine' 'SITEPAGEPUBLISHING#0' 'x' 1 $z $false $false 'None')
        (& $s 'https://contoso.sharepoint.com/sites/appcatalog' 'AppCatalog' 'APPCATALOG#0' 'x' 1 $z $false $false 'None')
        (& $s 'https://contoso.sharepoint.com/search' 'Search' 'SRCHCEN#0' 'x' 1 $z $false $false 'None')
    )
    if (-not $IncludePersonalSite) { $r = @($r | Where-Object { $_.Template -notlike 'SPSPERS*' }) }
    $r
}

function global:Get-SPOTenant {
    [CmdletBinding()] param()
    Add-MockCall 'SPO' 'Get-SPOTenant'; Test-MockFail 'Get-SPOTenant'
    # Version "ancienne" du module : pas de LegacyAuthProtocolsEnabled ni ConditionalAccessPolicy
    [pscustomobject]@{
        SharingCapability = 'ExternalUserAndGuestSharing'; OneDriveSharingCapability = 'ExternalUserAndGuestSharing'; DefaultSharingLinkType = 'AnonymousAccess'
        DefaultLinkPermission = 'None'; RequireAnonymousLinksExpireInDays = -1; SharingDomainRestrictionMode = 'None'; SharingAllowedDomainList = ''; SharingBlockedDomainList = ''
        ExternalUserExpirationRequired = $false; ExternalUserExpireInDays = 60; StorageQuota = 1295360; StorageQuotaAllocated = 0; OneDriveStorageQuota = 1048576; ResourceQuota = 0
    }
}

# ======================================================================================================
# DNS public (jamais de reseau)
# ======================================================================================================
function global:Resolve-DnsName {
    [CmdletBinding()] param([Parameter(Position = 0, Mandatory)][string]$Name, [string]$Type = 'A', [switch]$DnsOnly)
    Add-MockCall 'DNS' 'Resolve-DnsName' '' '' "$Name/$Type"
    $nx = { throw ([System.ComponentModel.Win32Exception]::new(9003, "$Name : DNS name does not exist")) }
    $timeout = { throw ([System.ComponentModel.Win32Exception]::new(1460, "$Name : This operation returned because the timeout period expired")) }
    if ($global:MockOpts.DnsAllFail) { & $timeout }
    $soa = [pscustomobject]@{ Name = $Name; Type = 'SOA'; Strings = $null }
    switch -Regex ($Name) {
        '^err\.contoso\.com$|^_dmarc\.err\.contoso\.com$|^autodiscover\.err\.contoso\.com$' { & $timeout }
        '^pending\.' { & $nx }
    }
    $fr = ($Name -match 'fr\.contoso\.com$')
    switch ($Type) {
        'MX' {
            if ($Name -eq 'contoso.com') { return [pscustomobject]@{ Name = $Name; Type = 'MX'; Preference = 0; NameExchange = 'contoso-com.mail.protection.outlook.com' } }
            if ($fr) { return @([pscustomobject]@{ Name = $Name; Type = 'MX'; Preference = 10; NameExchange = 'eu-smtp-inbound-1.mimecast.com' }, [pscustomobject]@{ Name = $Name; Type = 'MX'; Preference = 20; NameExchange = 'eu-smtp-inbound-2.mimecast.com' }) }
            & $nx
        }
        'TXT' {
            if ($Name -eq '_dmarc.contoso.com') { return [pscustomobject]@{ Name = $Name; Type = 'TXT'; Strings = @('v=DMARC1; p=none; rua=mailto:r@contoso.com') } }
            if ($Name -like '_dmarc.*') { & $nx }
            if ($Name -eq 'contoso.com') { return @([pscustomobject]@{ Name = $Name; Type = 'TXT'; Strings = @('MS=ms12345678') }, [pscustomobject]@{ Name = $Name; Type = 'TXT'; Strings = @('v=spf1 include:spf.protection.outlook.com ', '-all') }) }
            # fr.contoso.com : pas de SPF, seulement un enregistrement TXT quelconque + SOA d'autorite (comme le vrai cmdlet)
            return @([pscustomobject]@{ Name = $Name; Type = 'TXT'; Strings = @('google-site-verification=abc') }, $soa)
        }
        'CNAME' {
            if ($Name -eq 'autodiscover.contoso.com') { return [pscustomobject]@{ Name = $Name; Type = 'CNAME'; NameHost = 'autodiscover.outlook.com' } }
            # reponse sans CNAME : le vrai cmdlet renvoie le SOA d'autorite
            return $soa
        }
        default { & $nx }
    }
}
