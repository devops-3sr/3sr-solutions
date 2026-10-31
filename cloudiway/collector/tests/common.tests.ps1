#Requires -Version 7.0
# Tests Pester 5 des fonctions pures de lib\common.ps1 (aucun reseau, aucune connexion).
# Lancement : tests\run-tests.ps1 (ou : Invoke-Pester -Path tests\common.tests.ps1)

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1')
}

Describe 'Constantes' {
    It 'demande exactement 18 permissions Graph, toutes en lecture seule' {
        $script:GraphScopes.Count | Should -Be 18
        @($script:GraphScopes | Where-Object { $_ -notmatch '\.Read(Basic)?(\.All|\.Directory)$' }).Count | Should -Be 0
    }
    It 'ne definit aucun verrou sur un tenant particulier' {
        Get-Variable -Scope Script -Name Tenant3SR -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-GB' {
    It 'convertit des octets en Go au format francais' {
        ConvertTo-GB 1073741824 | Should -Be '1,00'
        ConvertTo-GB 1610612736 | Should -Be '1,50'
    }
    It 'retourne $null pour une valeur vide' {
        ConvertTo-GB $null | Should -BeNullOrEmpty
        ConvertTo-GB '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-BytesFromSize' {
    It 'extrait les octets du format SharePoint / Exchange' {
        Get-BytesFromSize '11.05 GB (11,864,090,092 bytes)' | Should -Be 11864090092
    }
    It 'retourne $null pour un format inconnu' {
        Get-BytesFromSize 'inconnu' | Should -BeNullOrEmpty
        Get-BytesFromSize $null | Should -BeNullOrEmpty
    }
}

Describe 'Format-Date' {
    It 'formate une date en ISO sans fuseau' {
        Format-Date ([datetime]'2026-10-12T06:59:10') | Should -Be '2026-10-12T06:59:10'
    }
    It 'laisse inchangee toute valeur qui n''est pas une date' {
        Format-Date 'texte' | Should -Be 'texte'
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
        $m.Length | Should -BeLessOrEqual 220
    }
    It 'tronque a 220 caracteres' {
        $e = try { throw ('x' * 600) } catch { $_ }
        (Get-ErrMsg $e).Length | Should -BeLessOrEqual 220
    }
}
