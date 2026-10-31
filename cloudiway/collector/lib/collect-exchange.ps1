# collect-exchange.ps1 - collecte Exchange Online en LECTURE SEULE (Get-* uniquement).
# Fonction publique : Invoke-ExchangeCollection (sans parametre). Tourne dans le processus worker Exchange
# (culture en-US deja forcee, $script:Ctx reconstruit, fonctions de common.ps1 deja chargees).
# Ne leve jamais d'exception.

function Invoke-ExchangeCollection {
    $WarningPreference = 'SilentlyContinue'   # collecte longue : jamais d'avertissement brut des modules Microsoft (les vrais problemes passent par Add-Cap)
    $part = 'Exchange'
    $isSource = [bool]$script:Ctx.IsSource
    $connected = $false

    # Culture en-US forcee pour le thread si necessaire (formats de dates et de nombres des cmdlets EXO)
    try {
        if ([System.Threading.Thread]::CurrentThread.CurrentCulture.Name -ne 'en-US') {
            $enUS = [cultureinfo]'en-US'
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $enUS
            [System.Threading.Thread]::CurrentThread.CurrentUICulture = $enUS
        }
    } catch { }

    try {
        # ------------------------------------------------------------------------------------------
        # Connexion + verification du tenant (jamais de collecte sur un mauvais tenant)
        # ------------------------------------------------------------------------------------------
        Write-Log '=== Exchange Online ===' 'Cyan'
        try {
            Import-Module ExchangeOnlineManagement -WarningAction SilentlyContinue -ErrorAction Stop
        } catch {
            Add-Cap $part 'Module ExchangeOnlineManagement' 'KO' (Get-ErrMsg $_)
            return
        }

        try {
            $exoArgs = @{
                UserPrincipalName = $script:Ctx.User
                ShowBanner        = $false
                ErrorAction       = 'Stop'
            }
            $exoParams = (Get-Command Connect-ExchangeOnline -ErrorAction Stop).Parameters
            $exoArgs['WarningAction'] = 'SilentlyContinue'
            $exoArgs['InformationAction'] = 'SilentlyContinue'
            if ($exoParams.ContainsKey('ShowProgress')) { $exoArgs['ShowProgress'] = $false }   # pas de barre de progression ni d'import verbeux du module
            if ($exoParams.ContainsKey('DisableWAM')) {
                $exoArgs['DisableWAM'] = $true
            } else {
                Add-Cap $part 'Module ExchangeOnlineManagement' 'PARTIEL' 'module ancien : mise a jour recommandee (parametre -DisableWAM absent, connexion sans)'
            }
            Connect-ExchangeOnline @exoArgs
            $connected = $true
        } catch {
            Add-Cap $part 'Connexion' 'KO' (Get-ErrMsg $_)
            return
        }

        # Verification du compte connecte (le compte impose doit etre celui de la session)
        $connUpn = $null
        try {
            $ci = Get-ConnectionInformation -WarningAction SilentlyContinue -ErrorAction Stop | Select-Object -Last 1
            if ($null -ne $ci) { $connUpn = "$($ci.UserPrincipalName)" }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($connUpn)) {
            Add-Cap $part 'Compte connecte' 'PARTIEL' 'compte non verifiable (Get-ConnectionInformation indisponible ou sans UPN)'
        } elseif ($connUpn -ine "$($script:Ctx.User)") {
            Add-Cap $part 'Compte connecte' 'KO' 'Compte connecte different du compte impose. Collecte arretee.'
            return
        }

        $acc = $null
        try {
            $acc = @(Get-AcceptedDomain -WarningAction SilentlyContinue -ErrorAction Stop)
        } catch {
            Add-Cap $part 'Connexion' 'KO' ("Verification du tenant impossible (Get-AcceptedDomain) : " + (Get-ErrMsg $_))
            return
        }
        if ($script:Ctx.InitialDomain -notin @($acc | ForEach-Object { "$($_.DomainName)" })) {
            Add-Cap $part 'Connexion' 'KO' ("Connecte a un autre tenant : le domaine $($script:Ctx.InitialDomain) est absent des domaines acceptes. Collecte arretee.")
            return
        }
        Add-Cap $part 'Connexion' 'OK' "Tenant verifie ($($script:Ctx.InitialDomain))"

        # Test des acces essentiels AVANT la collecte (resultat deja enregistre par la sonde sous 'Acces ...')
        if (Get-Command Test-ExchangeAccess -CommandType Function -ErrorAction SilentlyContinue) {
            if (-not (Test-ExchangeAccess)) {
                Write-Log 'Exchange : acces essentiel refuse pour ce compte, la collecte Exchange est ignoree (voir les lignes Acces ci-dessus).' 'Yellow'
                return
            }
        }

        # ------------------------------------------------------------------------------------------
        # EWS + configuration d'organisation
        # ------------------------------------------------------------------------------------------
        try {
            $oc = Get-OrganizationConfig -WarningAction SilentlyContinue -ErrorAction Stop
            $ewsProps = @($oc.PSObject.Properties | Where-Object { $_.Name -like 'Ews*' })
            $allText = ($ewsProps | ForEach-Object { "$($_.Value)" }) -join ' '
            $row = [ordered]@{ Tenant = $script:Ctx.TenantId }
            foreach ($p in $ewsProps) { $row[$p.Name] = (@($p.Value) -join '|') }
            foreach ($k in $script:CloudiwayAppIds.Keys) {
                $row["AppId_$($script:CloudiwayAppIds[$k])_present"] = ($allText -match [regex]::Escape($k))
            }
            $casOk = $true
            try {
                $cas = @(Get-EXOCASMailbox -ResultSize Unlimited -PropertySets Minimum, Ews -WarningAction SilentlyContinue -ErrorAction Stop)
                $row['Mailboxes_Total'] = $cas.Count
                $row['Mailboxes_EwsEnabled_False'] = @($cas | Where-Object { $_.EwsEnabled -eq $false }).Count
                $row['Mailboxes_EwsEnabled_Null'] = @($cas | Where-Object { $null -eq $_.EwsEnabled }).Count
            } catch {
                $casOk = $false
                Add-Cap $part 'EWS par boite (Get-EXOCASMailbox)' 'KO' (Get-ErrMsg $_)
            }
            Save-Csv ([pscustomobject]$row) 'ews.csv'
            $ewsDetail = if ($ewsProps.Count) { 'proprietes : ' + (($ewsProps.Name) -join ',') } else { 'aucune propriete Ews* exposee' }
            Add-Cap $part 'EWS OrganizationConfig' ($(if ($casOk) { 'OK' } else { 'PARTIEL' })) $ewsDetail

            try {
                $keep = 'Name', 'AuditDisabled', 'PublicFoldersEnabled', 'OAuth2ClientProfileEnabled', 'DefaultAuthenticationPolicy', 'SmtpClientAuthenticationDisabled', 'ConnectorsEnabled', 'MailTipsAllTipsEnabled', 'CustomerLockboxEnabled'
                $present = @($keep | Where-Object { $oc.PSObject.Properties.Name -contains $_ })
                Save-Csv ($oc | Select-Object $present) 'exo-organization.csv'
                Add-Cap $part 'Configuration organisation' 'OK'
            } catch { Add-Cap $part 'Configuration organisation' 'KO' (Get-ErrMsg $_) }
        } catch { Add-Cap $part 'EWS OrganizationConfig' 'KO' (Get-ErrMsg $_) }

        # ------------------------------------------------------------------------------------------
        # Boites aux lettres
        # ------------------------------------------------------------------------------------------
        $mbx = $null
        try {
            $props = 'RecipientTypeDetails,PrimarySmtpAddress,EmailAddresses,Alias,DisplayName,UserPrincipalName,ExternalDirectoryObjectId,ArchiveStatus,ArchiveGuid,LitigationHoldEnabled,RetentionHoldEnabled,ForwardingSmtpAddress,ForwardingAddress,DeliverToMailboxAndForward,HiddenFromAddressListsEnabled' -split ','
            $mbx = @(Get-EXOMailbox -ResultSize Unlimited -Properties $props -WarningAction SilentlyContinue -ErrorAction Stop)
            Add-Cap $part 'Liste des boites (Get-EXOMailbox)' 'OK' "$($mbx.Count) boites"
        } catch { Add-Cap $part 'Liste des boites (Get-EXOMailbox)' 'KO' (Get-ErrMsg $_) }

        if ($null -ne $mbx) {
            if ($isSource) {
                # Dates relues via Get-Mailbox (WhenCreatedUTC) : les Get-EXO* perdent les dates jour > 12
                $created = @{}
                try {
                    Get-Mailbox -ResultSize Unlimited -WarningAction SilentlyContinue -ErrorAction Stop |
                        ForEach-Object { $created["$($_.ExternalDirectoryObjectId)"] = $_.WhenCreatedUTC }
                    Add-Cap $part 'Dates de creation (Get-Mailbox)' 'OK' "$($created.Count) boites"
                } catch { Add-Cap $part 'Dates de creation (Get-Mailbox)' 'KO' (Get-ErrMsg $_) }

                try {
                    $total = [Math]::Max(1, $mbx.Count)
                    $mrows = [System.Collections.Generic.List[object]]::new()
                    $i = 0
                    $t0 = Get-Date
                    foreach ($m in $mbx) {
                        $i++
                        try {
                            if (($i % 10) -eq 0 -or $i -eq 1 -or $i -eq $total) {
                                $elapsed = ((Get-Date) - $t0).TotalSeconds
                                $eta = if ($i -gt 1) { [int]($elapsed / ($i - 1) * ($total - $i + 1)) } else { 0 }
                                Write-Progress -Activity 'Statistiques des boites aux lettres (long)' -Status ("{0} / {1} - reste environ {2} s" -f $i, $total, $eta) -PercentComplete ([int](100 * $i / $total))
                            }
                            if (($i % 50) -eq 0) { Write-Log ("Statistiques boites : {0} / {1}" -f $i, $total) }

                            $st = $null; $ast = $null
                            $id = "$($m.ExternalDirectoryObjectId)"
                            try { $st = Get-MailboxStatistics -Identity $id -WarningAction SilentlyContinue -ErrorAction Stop } catch { }
                            if ("$($m.ArchiveStatus)" -eq 'Active') {
                                try { $ast = Get-MailboxStatistics -Identity $id -Archive -WarningAction SilentlyContinue -ErrorAction Stop } catch { }
                            }
                            $b = Get-BytesFromSize $st.TotalItemSize
                            $db = Get-BytesFromSize $st.TotalDeletedItemSize
                            $ab = Get-BytesFromSize $ast.TotalItemSize
                            $mrows.Add([pscustomobject]@{
                                RecipientTypeDetails          = $m.RecipientTypeDetails
                                DisplayName                   = $m.DisplayName
                                UserPrincipalName             = $m.UserPrincipalName
                                PrimarySmtpAddress            = $m.PrimarySmtpAddress
                                Alias                         = $m.Alias
                                EmailAddresses                = ($m.EmailAddresses -join '|')
                                ExternalDirectoryObjectId     = $m.ExternalDirectoryObjectId
                                ArchiveStatus                 = $m.ArchiveStatus
                                LitigationHoldEnabled         = $m.LitigationHoldEnabled
                                RetentionHoldEnabled          = $m.RetentionHoldEnabled
                                ForwardingSmtpAddress         = $m.ForwardingSmtpAddress
                                ForwardingAddress             = $m.ForwardingAddress
                                DeliverToMailboxAndForward    = $m.DeliverToMailboxAndForward
                                HiddenFromAddressListsEnabled = $m.HiddenFromAddressListsEnabled
                                WhenCreatedUTC                = Format-Date $created[$id]
                                TotalItemSizeBytes            = $b
                                TotalItemSizeGB               = ConvertTo-GB $b
                                ItemCount                     = $st.ItemCount
                                TotalDeletedItemSizeBytes     = $db
                                TotalDeletedItemSizeGB        = ConvertTo-GB $db
                                LastUserActionTime            = Format-Date $st.LastUserActionTime
                                LastLogonTime                 = Format-Date $st.LastLogonTime
                                StatsRead                     = ($null -ne $st)
                                ArchiveSizeBytes              = $ab
                                ArchiveSizeGB                 = ConvertTo-GB $ab
                                ArchiveItemCount              = $ast.ItemCount
                                IsLitigationOrRetention       = ([bool]$m.LitigationHoldEnabled -or [bool]$m.RetentionHoldEnabled)
                            })
                        } catch {
                            # Une boite en erreur ne doit pas interrompre les autres : ligne sans statistiques
                            $mrows.Add([pscustomobject]@{
                                RecipientTypeDetails = $m.RecipientTypeDetails; DisplayName = $m.DisplayName; UserPrincipalName = $m.UserPrincipalName
                                PrimarySmtpAddress = $m.PrimarySmtpAddress; Alias = $m.Alias; EmailAddresses = ($m.EmailAddresses -join '|')
                                ExternalDirectoryObjectId = $m.ExternalDirectoryObjectId; ArchiveStatus = $m.ArchiveStatus
                                LitigationHoldEnabled = $m.LitigationHoldEnabled; RetentionHoldEnabled = $m.RetentionHoldEnabled
                                ForwardingSmtpAddress = $m.ForwardingSmtpAddress; ForwardingAddress = $m.ForwardingAddress
                                DeliverToMailboxAndForward = $m.DeliverToMailboxAndForward; HiddenFromAddressListsEnabled = $m.HiddenFromAddressListsEnabled
                                WhenCreatedUTC = $null; TotalItemSizeBytes = $null; TotalItemSizeGB = $null; ItemCount = $null
                                TotalDeletedItemSizeBytes = $null; TotalDeletedItemSizeGB = $null; LastUserActionTime = $null; LastLogonTime = $null
                                StatsRead = $false; ArchiveSizeBytes = $null; ArchiveSizeGB = $null; ArchiveItemCount = $null
                                IsLitigationOrRetention = ([bool]$m.LitigationHoldEnabled -or [bool]$m.RetentionHoldEnabled)
                            })
                        }
                    }
                    Write-Progress -Activity 'Statistiques des boites aux lettres (long)' -Completed
                    try { Save-Csv $mrows 'mailboxes.csv' } catch { Add-Cap $part 'Ecriture mailboxes.csv' 'KO' ('fichier verrouille ou disque : ' + (Get-ErrMsg $_)) }
                    # Boites systeme (decouverte, supervision...) : sans statistiques lisibles et non migrees, ignorees ici.
                    $sysTypes = 'DiscoveryMailbox', 'MonitoringMailbox', 'ArbitrationMailbox', 'AuditLogMailbox'
                    $sysCount = @($mrows | Where-Object { $_.RecipientTypeDetails -in $sysTypes }).Count
                    $miss = @($mrows | Where-Object { -not $_.StatsRead -and $_.RecipientTypeDetails -notin $sysTypes }).Count
                    $detail = "$miss boite(s) sans statistiques sur $($mrows.Count)"
                    if ($sysCount) { $detail += " ($sysCount boite(s) systeme ignoree(s), non migrees)" }
                    Add-Cap $part 'Statistiques des boites' ($(if ($miss) { 'PARTIEL' } else { 'OK' })) $detail
                } catch {
                    Write-Progress -Activity 'Statistiques des boites aux lettres (long)' -Completed
                    Add-Cap $part 'Statistiques des boites' 'KO' (Get-ErrMsg $_)
                }

                # Permissions : boites partagees, salles, equipements
                try {
                    $prow = [System.Collections.Generic.List[object]]::new()
                    $permErr = 0
                    $shared = @($mbx | Where-Object { $_.RecipientTypeDetails -in 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox' })
                    foreach ($m in $shared) {
                        $id = "$($m.ExternalDirectoryObjectId)"
                        try {
                            Get-EXOMailboxPermission -Identity $id -WarningAction SilentlyContinue -ErrorAction Stop |
                                Where-Object { -not $_.IsInherited -and $_.User -notlike 'NT AUTHORITY*' -and $_.User -notlike 'S-1-5-*' } |
                                ForEach-Object { $prow.Add([pscustomobject]@{ Mailbox = $m.PrimarySmtpAddress; Type = $m.RecipientTypeDetails; Right = ($_.AccessRights -join '|'); Trustee = $_.User }) }
                        } catch { $permErr++ }
                        try {
                            Get-EXORecipientPermission -Identity $id -AccessRights SendAs -WarningAction SilentlyContinue -ErrorAction Stop |
                                Where-Object { $_.Trustee -notlike 'NT AUTHORITY*' } |
                                ForEach-Object { $prow.Add([pscustomobject]@{ Mailbox = $m.PrimarySmtpAddress; Type = $m.RecipientTypeDetails; Right = 'SendAs'; Trustee = $_.Trustee }) }
                        } catch { $permErr++ }
                    }
                    Save-Csv $prow 'mailbox-permissions.csv'
                    Add-Cap $part 'Permissions boites partagees' ($(if ($permErr) { 'PARTIEL' } else { 'OK' })) "$($shared.Count) boites, $($prow.Count) droits, $permErr lecture(s) en erreur"
                } catch { Add-Cap $part 'Permissions boites partagees' 'KO' (Get-ErrMsg $_) }

                # Listes de distribution
                try {
                    $dl = @(Get-EXORecipient -ResultSize Unlimited -RecipientTypeDetails MailUniversalDistributionGroup, MailUniversalSecurityGroup, DynamicDistributionGroup -WarningAction SilentlyContinue -ErrorAction Stop)
                    $dlrows = [System.Collections.Generic.List[object]]::new()
                    $dlErr = 0
                    foreach ($d in $dl) {
                        $n = if ($d.RecipientTypeDetails -eq 'DynamicDistributionGroup') { 'dynamique' }
                        else { try { @(Get-DistributionGroupMember -Identity "$($d.ExternalDirectoryObjectId)" -ResultSize Unlimited -WarningAction SilentlyContinue -ErrorAction Stop).Count } catch { $dlErr++; 'KO' } }
                        $dlrows.Add([pscustomobject]@{ DisplayName = $d.DisplayName; PrimarySmtpAddress = $d.PrimarySmtpAddress; Alias = $d.Alias; Type = $d.RecipientTypeDetails; Members = $n; EmailAddresses = ($d.EmailAddresses -join '|') })
                    }
                    Save-Csv $dlrows 'distribution-lists.csv'
                    Add-Cap $part 'Listes de distribution' ($(if ($dlErr) { 'PARTIEL' } else { 'OK' })) "$($dl.Count) listes, $dlErr comptage(s) de membres en erreur"
                } catch { Add-Cap $part 'Listes de distribution' 'KO' (Get-ErrMsg $_) }

                # Contacts et utilisateurs de messagerie
                try {
                    $mc = @(Get-EXORecipient -ResultSize Unlimited -RecipientTypeDetails MailContact, MailUser -WarningAction SilentlyContinue -ErrorAction Stop)
                    Save-Csv ($mc | Select-Object DisplayName, PrimarySmtpAddress, Alias, RecipientTypeDetails, ExternalEmailAddress, @{n = 'EmailAddresses'; e = { $_.EmailAddresses -join '|' } }) 'mail-contacts.csv'
                    Add-Cap $part 'Contacts et MailUsers' 'OK' "$($mc.Count) objets"
                } catch { Add-Cap $part 'Contacts et MailUsers' 'KO' (Get-ErrMsg $_) }
            }
            else {
                # Cible : export allege pour la detection de conflits
                try {
                    Save-Csv ($mbx | Select-Object RecipientTypeDetails, DisplayName, UserPrincipalName, PrimarySmtpAddress, Alias, @{n = 'EmailAddresses'; e = { $_.EmailAddresses -join '|' } }, @{n = 'IsLitigationOrRetention'; e = { ([bool]$_.LitigationHoldEnabled -or [bool]$_.RetentionHoldEnabled) } }) 'mailboxes.csv'
                    Add-Cap $part 'Boites (cible, allege)' 'OK' "$($mbx.Count) boites"
                } catch { Add-Cap $part 'Boites (cible, allege)' 'KO' (Get-ErrMsg $_) }
                try {
                    $rcp = @(Get-EXORecipient -ResultSize Unlimited -WarningAction SilentlyContinue -ErrorAction Stop)
                    Save-Csv ($rcp | Select-Object Alias, DisplayName, PrimarySmtpAddress, RecipientTypeDetails, @{n = 'EmailAddresses'; e = { $_.EmailAddresses -join '|' } }) 'recipients.csv'
                    Add-Cap $part 'Destinataires (Get-EXORecipient)' 'OK' "$($rcp.Count) destinataires"
                } catch { Add-Cap $part 'Destinataires (Get-EXORecipient)' 'KO' (Get-ErrMsg $_) }
            }
        }

        # ------------------------------------------------------------------------------------------
        # Dossiers publics : comptage seulement (non migres par Cloudiway)
        # ------------------------------------------------------------------------------------------
        try {
            $pf = @(Get-Mailbox -PublicFolder -ResultSize Unlimited -WarningAction SilentlyContinue -ErrorAction Stop)
            Add-Cap $part 'Boites de dossiers publics' 'OK' "$($pf.Count) (non migrees par Cloudiway)"
        } catch { Add-Cap $part 'Boites de dossiers publics' 'KO' (Get-ErrMsg $_) }

        # ------------------------------------------------------------------------------------------
        # Flux de messagerie
        # ------------------------------------------------------------------------------------------
        try {
            Save-Csv ($acc | Select-Object DomainName, DomainType, Default) 'accepted-domains.csv'
            Add-Cap $part 'Domaines acceptes' 'OK' "$($acc.Count) domaines"
        } catch { Add-Cap $part 'Domaines acceptes' 'KO' (Get-ErrMsg $_) }

        try {
            $cn = [System.Collections.Generic.List[object]]::new()
            Get-InboundConnector -WarningAction SilentlyContinue -ErrorAction Stop | Select-Object @{n = 'Direction'; e = { 'Inbound' } }, Name, Enabled, ConnectorType, @{n = 'SmartHosts'; e = { '' } }, @{n = 'RecipientDomains'; e = { '' } }, @{n = 'SenderDomains'; e = { $_.SenderDomains -join '|' } }, @{n = 'SenderIPAddresses'; e = { $_.SenderIPAddresses -join '|' } }, @{n = 'TlsSenderCertificateName'; e = { $_.TlsSenderCertificateName } }, Comment |
                ForEach-Object { $cn.Add($_) }
            Get-OutboundConnector -WarningAction SilentlyContinue -ErrorAction Stop | Select-Object @{n = 'Direction'; e = { 'Outbound' } }, Name, Enabled, ConnectorType, @{n = 'SmartHosts'; e = { $_.SmartHosts -join '|' } }, @{n = 'RecipientDomains'; e = { $_.RecipientDomains -join '|' } }, @{n = 'SenderDomains'; e = { '' } }, @{n = 'SenderIPAddresses'; e = { '' } }, @{n = 'TlsSenderCertificateName'; e = { $_.TlsDomain } }, Comment |
                ForEach-Object { $cn.Add($_) }
            Save-Csv $cn 'connectors.csv'
            Add-Cap $part 'Connecteurs' 'OK' "$($cn.Count) connecteurs"
        } catch { Add-Cap $part 'Connecteurs' 'KO' (Get-ErrMsg $_) }

        try {
            $tr = @(Get-TransportRule -ResultSize Unlimited -WarningAction SilentlyContinue -ErrorAction Stop)
            Save-Csv ($tr | Select-Object Name, State, Priority, Mode, @{n = 'Description'; e = { ($_.Description -replace '\s+', ' ').Trim() } }) 'transport-rules.csv'
            Add-Cap $part 'Regles de transport' 'OK' "$($tr.Count) regles"
        } catch { Add-Cap $part 'Regles de transport' 'KO' (Get-ErrMsg $_) }

        try {
            $dk = @(Get-DkimSigningConfig -WarningAction SilentlyContinue -ErrorAction Stop)
            Save-Csv ($dk | Select-Object Domain, Enabled, Status) 'dkim.csv'
            Add-Cap $part 'DKIM' 'OK' "$($dk.Count) domaines"
        } catch { Add-Cap $part 'DKIM' 'KO' (Get-ErrMsg $_) }
    }
    catch {
        # Filet de securite : aucune exception ne doit remonter au worker
        try { Add-Cap $part 'Collecte Exchange' 'KO' (Get-ErrMsg $_) } catch { }
    }
    finally {
        if ($connected) {
            try { Disconnect-ExchangeOnline -Confirm:$false -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }
}
