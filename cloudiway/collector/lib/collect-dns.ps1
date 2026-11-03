# collect-dns.ps1 - resolution DNS publique (MX, SPF, DMARC, Autodiscover) des domaines verifies du tenant.
# Lit domains.csv (repli : Graph /domains). Resolve-DnsName indisponible = capacite KO, jamais d'exception.

# Resolution d'un type d'enregistrement. Status : OK | ABSENT (le nom ou le type n'existe pas) | ERREUR (resolveur, delai).
function Get-DnsRecordSafe([string]$Name, [string]$Type) {
    $res = [pscustomobject]@{ Records = @(); Status = 'OK'; Err = '' }
    foreach ($attempt in 1..2) {
        try {
            $r = Resolve-DnsName -Name $Name -Type $Type -DnsOnly -WarningAction SilentlyContinue -ErrorAction Stop
            $res.Records = @($r | Where-Object { $_.Type -eq $Type })
            $res.Status = if ($res.Records.Count -gt 0) { 'OK' } else { 'ABSENT' }
            return $res
        } catch {
            $m = "$($_.Exception.Message)"
            $code = $null
            if ($_.Exception.PSObject.Properties['NativeErrorCode']) { $code = $_.Exception.NativeErrorCode }
            if (($code -in 9003, 9501) -or ($m -match 'does not exist|n.existe pas|RCODE_NAME_ERROR|Name Error|no records|aucun enregistrement')) {
                $res.Status = 'ABSENT'; return $res
            }
            $res.Status = 'ERREUR'; $res.Err = $m
        }
    }
    return $res
}

# Fournisseurs de filtrage/messagerie deduits des hotes MX (liste de motifs).
function Get-MxProviders([string[]]$MxHosts) {
    $patterns = [ordered]@{
        'Microsoft EOP'   = 'mail\.protection\.outlook\.com|\.mail\.protection\.outlook\.'
        'Mimecast'        = 'mimecast'
        'Proofpoint'      = 'pphosted|ppe-hosted|proofpoint'
        'Barracuda'       = 'barracuda|cudamail'
        'Google'          = 'google\.com|googlemail\.com|aspmx'
        'CodeTwo'         = 'codetwo'
        'Vade'            = 'vadesecure|vade-secure|vade\.secure'
        'Hornetsecurity'  = 'hornetsecurity|hornetdrive'
        'Trend Micro'     = 'trendmicro|tmes\.'
    }
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($h in $MxHosts) {
        $matched = $false
        foreach ($k in $patterns.Keys) {
            if ($h -match $patterns[$k]) { if (-not $found.Contains($k)) { $found.Add($k) }; $matched = $true; break }
        }
        if (-not $matched -and -not $found.Contains('Autre (a identifier)')) { $found.Add('Autre (a identifier)') }
    }
    return ($found -join ' + ')
}

function Invoke-DnsCollection {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $WarningPreference = 'SilentlyContinue'   # aucun avertissement brut des modules Microsoft a l'ecran (les vrais problemes passent par Add-Cap)
    Set-StrictMode -Off
    $part = 'Dns'
    try {
        Write-Log '=== DNS public ===' 'Cyan'

        if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) {
            Save-Csv @() 'dns.csv'
            Add-Cap $part 'Resolution publique' 'KO' 'Resolve-DnsName indisponible sur ce poste (module DnsClient absent)'
            return
        }

        # Liste des domaines verifies : domains.csv en priorite, sinon Graph
        $domList = @()
        $csv = Import-CollectedCsv 'domains.csv'
        if (@($csv).Count -gt 0) {
            $domList = @($csv | Where-Object { "$($_.isVerified)" -eq 'True' } | ForEach-Object { $_.id })
        } else {
            try { $domList = @((Invoke-G '/domains') | Where-Object { $_.isVerified -eq $true } | ForEach-Object { $_.id }) }
            catch { Add-Cap $part 'Liste domaines' 'KO' (Get-ErrMsg $_); Save-Csv @() 'dns.csv'; return }
        }
        $domList = @($domList | Where-Object { $_ -and $_ -notlike '*.onmicrosoft.com' } | Sort-Object -Unique)

        $total = $domList.Count; $i = 0; $errCount = 0
        $drows = foreach ($d in $domList) {
            $i++
            Write-Progress -Activity 'Resolution DNS' -Status "$i / $total : $d" -PercentComplete ([int](100 * $i / [Math]::Max(1, $total)))
            $rowErr = $false

            $mxr = Get-DnsRecordSafe $d 'MX'
            $mxHosts = @($mxr.Records | Sort-Object Preference | ForEach-Object { "$($_.NameExchange)".TrimEnd('.') })
            $mx = switch ($mxr.Status) {
                'OK' { (($mxr.Records | Sort-Object Preference | ForEach-Object { "$($_.Preference) $($_.NameExchange)" }) -join '|') }
                'ABSENT' { 'ABSENT' }
                default { $rowErr = $true; 'ERREUR' }
            }

            $txr = Get-DnsRecordSafe $d 'TXT'
            $spf = switch ($txr.Status) {
                'ERREUR' { $rowErr = $true; 'ERREUR' }
                default {
                    $s = @($txr.Records | ForEach-Object { $_.Strings -join '' } | Where-Object { $_ -like 'v=spf1*' })
                    if ($s.Count -gt 0) { $s -join ' || ' } else { 'ABSENT' }
                }
            }

            $dmr = Get-DnsRecordSafe "_dmarc.$d" 'TXT'
            $dmarc = switch ($dmr.Status) {
                'OK' {
                    $v = @($dmr.Records | ForEach-Object { $_.Strings -join '' } | Where-Object { $_ -like 'v=DMARC1*' })
                    if ($v.Count -gt 0) { $v -join ' || ' } else { 'ABSENT' }
                }
                'ABSENT' { 'ABSENT' }
                default { $rowErr = $true; 'ERREUR' }
            }

            $adr = Get-DnsRecordSafe "autodiscover.$d" 'CNAME'
            $ad = switch ($adr.Status) {
                'OK' { (($adr.Records | ForEach-Object { $_.NameHost }) -join '|') }
                'ABSENT' { 'ABSENT' }
                default { $rowErr = $true; 'ERREUR' }
            }

            $prov = if ($mxr.Status -eq 'ERREUR') { 'Indetermine (erreur DNS)' }
            elseif ($mxr.Status -eq 'ABSENT') { 'Pas de MX' }
            else { Get-MxProviders $mxHosts }

            if ($rowErr) { $errCount++ }
            [pscustomobject]@{ Domain = $d; MX = $mx; FiltrageDeduit = $prov; SPF = $spf; DMARC = $dmarc; Autodiscover = $ad }
        }
        Write-Progress -Activity 'Resolution DNS' -Completed
        Save-Csv $drows 'dns.csv'

        if ($total -eq 0) { Add-Cap $part 'Resolution publique' 'OK' '0 domaine personnalise verifie' }
        elseif ($errCount -ge $total) { Add-Cap $part 'Resolution publique' 'KO' "Aucune resolution aboutie sur $total domaines (reseau ou resolveur DNS ?)" }
        elseif ($errCount -gt 0) { Add-Cap $part 'Resolution publique' 'PARTIEL' "$total domaines ; $errCount avec au moins une erreur de resolution (valeur ERREUR)" }
        else { Add-Cap $part 'Resolution publique' 'OK' "$total domaines" }
    } catch {
        Write-Progress -Activity 'Resolution DNS' -Completed
        try { Add-Cap $part 'Collecte (erreur inattendue)' 'KO' (Get-ErrMsg $_) } catch { }
    }
}
