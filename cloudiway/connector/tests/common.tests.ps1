#Requires -Version 7.0
# Tests Pester 5 des fonctions pures de lib\common.ps1 et lib\permissions.ps1 (aucun reseau, aucune connexion).
# Lancement : tests\run-tests.ps1 (ou : Invoke-Pester -Path tests\common.tests.ps1)

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\permissions.ps1')
}

Describe 'Constantes' {
    It 'identifie l''outil sans adresse e-mail en dur' {
        $script:AppContact | Should -Be 'votre contact 3SR'
        $script:AppContact | Should -Not -Match '@'
    }
}

Describe 'ConvertTo-MaskedJson' {
    It 'masque toute cle sensible, y compris imbriquee' {
        $j = ConvertTo-MaskedJson ([ordered]@{ name = 'x'; password = 'P4ssw0rd-visible'; nested = @{ clientSecret = 'S3cret-visible'; keep = 'ok' } })
        $j | Should -Not -Match 'P4ssw0rd-visible'
        $j | Should -Not -Match 'S3cret-visible'
        $j | Should -Match '"keep": "ok"'
    }
    It 'conserve une cle explicitement declaree non secrete (-KeepKeys)' {
        $j = ConvertTo-MaskedJson ([ordered]@{ externalKey = 'CIW1|AA|20270101'; secretKey = 'S3CRET-VALUE' }) 5 -KeepKeys @('externalKey')
        $j | Should -Match 'CIW1\|AA\|20270101'
        $j | Should -Not -Match 'S3CRET-VALUE'
    }
}

Describe 'Mots de passe generes' {
    It 'New-StrongPassword : 24 caracteres, quatre classes' {
        $p = New-StrongPassword
        $p.Length | Should -Be 24
        $p | Should -Match '[A-Z]'
        $p | Should -Match '[a-z]'
        $p | Should -Match '[0-9]'
        $p | Should -Match '[!#$%&*+=?@_-]'
    }
    It 'New-AlnumPassword : uniquement des lettres et des chiffres' {
        $p = New-AlnumPassword 40
        $p.Length | Should -Be 40
        $p | Should -Match '^[A-Za-z0-9]+$'
    }
    It 'deux appels successifs donnent des valeurs differentes' {
        (New-StrongPassword) | Should -Not -Be (New-StrongPassword)
    }
}

Describe 'Get-ErrCode' {
    It 'lit le code HTTP dans le message de l''exception' {
        $e = try { throw 'Response status code does not indicate success: 403 (Forbidden).' } catch { $_ }
        Get-ErrCode $e | Should -Be 403
    }
    It 'retourne $null quand aucun code n''est lisible' {
        $e = try { throw 'erreur quelconque' } catch { $_ }
        Get-ErrCode $e | Should -BeNullOrEmpty
    }
}

Describe 'Get-ErrMsg' {
    It 'produit un message court, sur une ligne, prefixe par le code HTTP' {
        $e = try { throw 'Response status code does not indicate success: 403 (Forbidden).' } catch { $_ }
        $m = Get-ErrMsg $e
        $m | Should -Match '^HTTP 403'
        $m | Should -Not -Match "[`r`n]"
    }
    It 'tronque a 220 caracteres' {
        $e = try { throw ('x' * 600) } catch { $_ }
        (Get-ErrMsg $e).Length | Should -BeLessOrEqual 220
    }
}

Describe 'Get-AadstsHint' {
    It 'donne un conseil pour les codes courants' {
        foreach ($c in '65001', '90094', '53003', '50076') { (Get-AadstsHint "AADSTS${c}: message") | Should -Match "AADSTS$c" }
    }
    It 'ne donne rien pour un code inconnu' {
        Get-AadstsHint 'AADSTS99999: autre' | Should -Be ''
    }
}

Describe 'Matrice des permissions (mode Source, Mail et OneDrive)' {
    It 'ne demande aucune permission d''ecriture sur l''annuaire pour Mail et OneDrive' {
        $p = @(Get-PermissionSet -Mode Source -Workloads 'Mail', 'OneDrive')
        @($p | Where-Object { $_.Name -match '^(User|Group|Directory|Application)\.ReadWrite' }).Count | Should -Be 0
    }
    It 'Mail : roles Exchange Administrator et Exchange Recipient Administrator sur l''application' {
        $r = @(Get-RequiredEntraRoles -Mode Source -Workloads 'Mail')
        ($r | ForEach-Object Name) | Should -Contain 'Exchange Administrator'
        ($r | ForEach-Object Name) | Should -Contain 'Exchange Recipient Administrator'
        @($r | Where-Object { $_.Target -eq 'ServiceAccount' }).Count | Should -Be 0
    }
    It 'Mail et OneDrive en Source : aucun compte de service' {
        Test-NeedServiceAccount -Mode Source -Workloads 'Mail', 'OneDrive' | Should -BeFalse
    }
    It 'noms codifies' {
        $n = Get-CodedNames -Mode Source -ProjectId '12345' -TenantShort 'contoso'
        $n.App | Should -Be 'CLOUDIWAY-SOURCE-P12345'
        $n.Connector | Should -Be 'contoso-source'
        $n.CertificateSubject | Should -Be 'CN=Cloudiway-SOURCE-P12345'
    }
    It 'produits : Mail = 5, OneDrive = 6' {
        $p = Get-ProductIds -Workloads 'Mail', 'OneDrive'
        ($p.Ids -join ',') | Should -Be '5,6'
        $p.Unknown.Count | Should -Be 0
    }
}
