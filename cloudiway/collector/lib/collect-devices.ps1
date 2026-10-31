# collect-devices.ps1 - postes Entra, Intune, Autopilot, inventaire de configuration Intune.
# Suppose une session Graph ouverte et lib\common.ps1 charge. Lecture seule (GET). Ne leve jamais d'exception.
# Tenant sans Intune : les KO sont attendus ; un seul message court par element.

# Message court pour les erreurs Intune/Entra (licence absente, droits) : evite 10 lignes de bruit identiques.
# -Inventory : element d'INVENTAIRE Intune optionnel. Un refus 401/403 (ou une erreur de licence / role) produit alors un message
# clair, repris au bilan final comme "non disponible" (voir Get-CapAdvice dans ui.ps1).
function Get-DevicesShortErr($e, [switch]$Inventory) {
    $m = Get-ErrMsg $e
    if ($Inventory) {
        $code = Get-ErrCode $e
        if (($code -in 401, 403) -or $m -match 'HTTP (401|403)|Forbidden|not authorized|Authorization|licen|MdmAuthority|not enrolled|not applicable') {
            $c = if ($code -in 401, 403) { $code } else { 403 }
            return "Refus HTTP ${c} : role Intune ou licence manquant (inventaire optionnel)"
        }
    }
    if ($m -match 'licen|Intune|Forbidden|not authorized|Authorization|MdmAuthority|not enrolled|tenant.*not|not applicable') {
        return ('Non disponible (licence Intune absente ou droit insuffisant) : ' + $m.Substring(0, [Math]::Min(100, $m.Length)))
    }
    return $m.Substring(0, [Math]::Min(150, $m.Length))
}

function Invoke-DevicesCollection {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $WarningPreference = 'SilentlyContinue'   # aucun avertissement brut des modules Microsoft a l'ecran (les vrais problemes passent par Add-Cap)
    Set-StrictMode -Off
    $part = 'Devices'
    $noIntune = $false
    try {
        Write-Log '=== Postes / Intune ===' 'Cyan'

        try {
            $dev = Invoke-G "/devices?`$select=id,displayName,operatingSystem,operatingSystemVersion,trustType,isManaged,isCompliant,approximateLastSignInDateTime,registrationDateTime,onPremisesSyncEnabled,profileType,manufacturer,model&`$top=999" -All
            Save-Csv $dev 'entra-devices.csv'
            Add-Cap $part 'Entra devices' 'OK' "$(@($dev).Count) objets (trustType: AzureAd = Entra joined, ServerAd = hybride, Workplace = registered)"
        } catch { Add-Cap $part 'Entra devices' 'KO' (Get-ErrMsg $_) }

        # Pas de propriete joinType (inexistante en v1.0 : provoque un 400)
        try {
            $md = Invoke-G "/deviceManagement/managedDevices?`$select=id,deviceName,operatingSystem,osVersion,managedDeviceOwnerType,complianceState,enrolledDateTime,lastSyncDateTime,model,manufacturer,deviceEnrollmentType,managementAgent,userPrincipalName,azureADDeviceId,isEncrypted&`$top=999" -All
            Save-Csv $md 'intune-managed-devices.csv'
            Add-Cap $part 'Intune managedDevices' 'OK' "$(@($md).Count) objets"
        } catch {
            # Tenant sans Intune (licence absente / non applicable / acces refuse) : une seule ligne, tous les appels Intune suivants sont ignores
            $rawMd = Get-ErrMsg $_
            if ($rawMd -match 'not applicable|tenant.*not|licen[sc]e|Forbidden|403|no Intune') {
                $noIntune = $true
                Add-Cap $part 'Intune' 'KO' 'Intune absent ou non accessible (licence ou droit) : appels Intune ignores'
            } else { Add-Cap $part 'Intune managedDevices' 'KO' (Get-DevicesShortErr $_) }
        }

        if (-not $noIntune) { try {
            $ap = Invoke-G '/deviceManagement/windowsAutopilotDeviceIdentities?$top=999' -All
            Save-Csv ($ap | Select-Object id, serialNumber, manufacturer, model, groupTag, enrollmentState, lastContactedDateTime, deploymentProfileAssignmentStatus) 'autopilot-devices.csv'
            Add-Cap $part 'Autopilot' 'OK' "$(@($ap).Count) objets"
        } catch { Add-Cap $part 'Autopilot' 'KO' (Get-DevicesShortErr $_) } }

        # Inventaire de la configuration (noms et types seulement) : base de la reconstruction
        $inv = [System.Collections.Generic.List[object]]::new()
        $items = @(
            @{ K = 'Compliance'; P = '/deviceManagement/deviceCompliancePolicies'; V = 'v1.0' },
            @{ K = 'ConfigProfile'; P = '/deviceManagement/deviceConfigurations'; V = 'v1.0' },
            @{ K = 'SettingsCatalog'; P = '/deviceManagement/configurationPolicies'; V = 'beta' },
            @{ K = 'App'; P = '/deviceAppManagement/mobileApps'; V = 'v1.0' },
            @{ K = 'AppProtection'; P = '/deviceAppManagement/managedAppPolicies'; V = 'v1.0' },
            @{ K = 'Script'; P = '/deviceManagement/deviceManagementScripts'; V = 'beta' },
            @{ K = 'AutopilotProfile'; P = '/deviceManagement/windowsAutopilotDeploymentProfiles'; V = 'beta' },
            @{ K = 'EnrollmentConfig'; P = '/deviceManagement/deviceEnrollmentConfigurations'; V = 'v1.0' }
        )
        $n = 0
        foreach ($e in $items) {
            if ($noIntune) { break }
            $n++
            Write-Progress -Activity 'Inventaire de configuration Intune' -Status "$n / $($items.Count) : $($e.K)" -PercentComplete ([int](100 * $n / $items.Count))
            try {
                $list = Invoke-G $e.P -All -Version $e.V
                foreach ($x in $list) { $inv.Add([pscustomobject]@{ Category = $e.K; Name = ($x.displayName ?? $x.name); ODataType = $x.'@odata.type'; CreatedDateTime = $x.createdDateTime }) }
                Add-Cap $part "inventaire $($e.K)" 'OK' "$(@($list).Count) elements"
            } catch { Add-Cap $part "inventaire $($e.K)" 'KO' (Get-DevicesShortErr $_ -Inventory) }
        }
        Write-Progress -Activity 'Inventaire de configuration Intune' -Completed
        Save-Csv $inv 'intune-config-inventory.csv'
    } catch {
        Write-Progress -Activity 'Inventaire de configuration Intune' -Completed
        try { Add-Cap $part 'Collecte (erreur inattendue)' 'KO' (Get-ErrMsg $_) } catch { }
    }
}
