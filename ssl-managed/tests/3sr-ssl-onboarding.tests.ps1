<#
    Tests unitaires des fonctions PURES de 3sr-ssl-onboarding.ps1
    (celles qui ne touchent ni Azure ni le systeme de fichiers).

    Lancement (Pester 5) :  Invoke-Pester .\ssl-managed	ests

    Le script d'onboarding est un script executable, pas un module : on ne peut
    pas le dot-sourcer sans declencher tout son parcours interactif. On extrait
    donc ses definitions de fonctions par analyse syntaxique (AST) et on ne
    charge que celles-la.
#>

BeforeAll {
    $script:CheminScript = Join-Path (Split-Path -Parent $PSScriptRoot) "3sr-ssl-onboarding.ps1"
    if (-not (Test-Path $script:CheminScript)) { throw "Script introuvable : $($script:CheminScript)" }

    $erreurs = $null ; $jetons = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CheminScript, [ref]$jetons, [ref]$erreurs)
    if ($erreurs) { throw "Le script ne compile pas : $($erreurs[0].Message)" }

    $aExtraire = @("Test-NomStorage", "Test-NomKeyVault", "Test-NomResourceGroup", "Test-FichierSslList")
    $definitions = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $_.Name -in $aExtraire }

    if ($definitions.Count -ne $aExtraire.Count) {
        throw "Fonctions attendues non trouvées : $(($aExtraire | Where-Object { $_ -notin $definitions.Name }) -join ', ')"
    }
    foreach ($d in $definitions) { . ([scriptblock]::Create($d.Extent.Text)) }
}

Describe "Test-NomStorage" {
    It "accepte un nom valide" {
        Test-NomStorage "stsslmanaged123" | Should -BeNullOrEmpty
    }
    It "accepte la longueur minimale et maximale" {
        Test-NomStorage "abc"                      | Should -BeNullOrEmpty
        Test-NomStorage ("a" * 24)                 | Should -BeNullOrEmpty
    }
    It "refuse les majuscules" {
        Test-NomStorage "stSSLmanaged" | Should -Not -BeNullOrEmpty
    }
    It "refuse les tirets et les points" {
        Test-NomStorage "st-ssl-managed" | Should -Not -BeNullOrEmpty
        Test-NomStorage "st.sslmanaged"  | Should -Not -BeNullOrEmpty
    }
    It "refuse trop court et trop long" {
        Test-NomStorage "ab"        | Should -Not -BeNullOrEmpty
        Test-NomStorage ("a" * 25)  | Should -Not -BeNullOrEmpty
    }
    It "refuse la chaîne vide" {
        Test-NomStorage "" | Should -Not -BeNullOrEmpty
    }
}

Describe "Test-NomKeyVault" {
    It "accepte un nom valide" {
        Test-NomKeyVault "kv-sslmanaged-a1b2c" | Should -BeNullOrEmpty
    }
    It "refuse un nom commençant par un chiffre" {
        Test-NomKeyVault "1kv-ssl" | Should -Not -BeNullOrEmpty
    }
    It "refuse un nom finissant par un tiret" {
        Test-NomKeyVault "kv-ssl-" | Should -Not -BeNullOrEmpty
    }
    It "refuse deux tirets consécutifs" {
        Test-NomKeyVault "kv--ssl" | Should -Not -BeNullOrEmpty
    }
    It "refuse le souligné" {
        Test-NomKeyVault "kv_ssl" | Should -Not -BeNullOrEmpty
    }
    It "refuse trop court et trop long" {
        Test-NomKeyVault "kv"             | Should -Not -BeNullOrEmpty
        Test-NomKeyVault ("k" * 25)       | Should -Not -BeNullOrEmpty
    }
}

Describe "Test-NomResourceGroup" {
    It "accepte un nom valide" {
        Test-NomResourceGroup "RG-SSL-Managed" | Should -BeNullOrEmpty
    }
    It "accepte points, soulignés et parenthèses" {
        Test-NomResourceGroup "rg_ssl.managed(prod)" | Should -BeNullOrEmpty
    }
    It "refuse un nom finissant par un point" {
        Test-NomResourceGroup "RG-SSL." | Should -Not -BeNullOrEmpty
    }
    It "refuse les caractères interdits" {
        Test-NomResourceGroup "RG SSL"  | Should -Not -BeNullOrEmpty
        Test-NomResourceGroup "RG/SSL"  | Should -Not -BeNullOrEmpty
    }
    It "refuse au-delà de 90 caractères" {
        Test-NomResourceGroup ("r" * 91) | Should -Not -BeNullOrEmpty
    }
}

Describe "Test-FichierSslList" {
    It "accepte un fichier conforme" {
        $json = '{"ssl_list":[{"cn":"www.exemple.fr","type":"mono","auto-renew":"true"}]}'
        $r = Test-FichierSslList -Contenu $json
        $r.Valide        | Should -BeTrue
        $r.NbCertificats | Should -Be 1
    }
    It "accepte plusieurs entrées et les compte" {
        $json = '{"ssl_list":[{"cn":"a.fr","type":"mono"},{"cn":"b.fr","type":"wildcard"},{"cn":"c.fr"}]}'
        (Test-FichierSslList -Contenu $json).NbCertificats | Should -Be 3
    }
    It "refuse un contenu vide" {
        (Test-FichierSslList -Contenu "").Valide    | Should -BeFalse
        (Test-FichierSslList -Contenu "   ").Valide | Should -BeFalse
    }
    It "refuse un JSON malformé" {
        (Test-FichierSslList -Contenu '{"ssl_list":[').Valide | Should -BeFalse
    }
    It "refuse l'absence de ssl_list" {
        (Test-FichierSslList -Contenu '{"autre":[]}').Valide | Should -BeFalse
    }
    It "refuse une ssl_list vide" {
        (Test-FichierSslList -Contenu '{"ssl_list":[]}').Valide | Should -BeFalse
    }
    It "refuse une entrée sans cn" {
        (Test-FichierSslList -Contenu '{"ssl_list":[{"type":"mono"}]}').Valide | Should -BeFalse
    }
    It "refuse un cn vide" {
        (Test-FichierSslList -Contenu '{"ssl_list":[{"cn":"  "}]}').Valide | Should -BeFalse
    }
    It "refuse un type inconnu" {
        $r = Test-FichierSslList -Contenu '{"ssl_list":[{"cn":"a.fr","type":"sansan"}]}'
        $r.Valide  | Should -BeFalse
        $r.Message | Should -Match "inconnu"
    }
    It "accepte une date create-after valide et la compte" {
        $json = '{"ssl_list":[{"cn":"a.fr","type":"mono","create-after":"2026-10-01"},{"cn":"b.fr","type":"mono"}]}'
        $r = Test-FichierSslList -Contenu $json
        $r.Valide        | Should -BeTrue
        $r.NbCertificats | Should -Be 2
        $r.Message       | Should -Match "1 à émission programmée"
    }
    It "refuse une date create-after au format francais" {
        $r = Test-FichierSslList -Contenu '{"ssl_list":[{"cn":"a.fr","create-after":"01/10/2026"}]}'
        $r.Valide  | Should -BeFalse
        $r.Message | Should -Match "AAAA-MM-JJ"
    }
    It "refuse une date create-after inexistante" {
        (Test-FichierSslList -Contenu '{"ssl_list":[{"cn":"a.fr","create-after":"2026-13-45"}]}').Valide | Should -BeFalse
    }
    It "tolere create-after absent ou vide" {
        (Test-FichierSslList -Contenu '{"ssl_list":[{"cn":"a.fr","create-after":null}]}').Valide | Should -BeTrue
        (Test-FichierSslList -Contenu '{"ssl_list":[{"cn":"a.fr","create-after":""}]}').Valide   | Should -BeTrue
    }
    It "désigne l'entrée fautive par son rang" {
        $json = '{"ssl_list":[{"cn":"a.fr"},{"cn":"b.fr"},{"type":"mono"}]}'
        (Test-FichierSslList -Contenu $json).Message | Should -Match "n.3"
    }
}

Describe "Encodage des scripts livrés au client" {
    # Windows PowerShell 5.1 lit un .ps1 sans BOM en ANSI : tout le texte accentué
    # devient illisible chez le client. Défaut réel constaté sur l'offboarding.
    It "<_> commence par un BOM UTF-8" -ForEach @("3sr-ssl-onboarding.ps1", "3sr-ssl-offboarding.ps1") {
        $chemin = Join-Path (Split-Path -Parent $PSScriptRoot) $_
        Test-Path $chemin | Should -BeTrue
        $octets = [System.IO.File]::ReadAllBytes($chemin)[0..2]
        ($octets -join ',') | Should -Be '239,187,191' -Because "sans BOM, PowerShell 5.1 affiche des caractères accentués corrompus"
    }
}

Describe "Intégrité du script" {
    It "ne contient aucun secret évident" {
        $contenu = Get-Content $script:CheminScript -Raw
        $contenu | Should -Not -Match '(?i)(password|mot de passe)\s*=\s*["''][^"'']{6,}'
        $contenu | Should -Not -Match '(?i)(SharedAccessSignature|sig=|AccountKey=)'
    }
    It "n'accorde jamais Owner ou Contributor à 3SR" {
        $contenu = Get-Content $script:CheminScript -Raw
        $contenu | Should -Not -Match '\$RoleKeyVault\s*=\s*"(Owner|Contributor)"'
        $contenu | Should -Not -Match '"Key Vault Administrator"'
    }
    It "impose bien la région France Centre" {
        $contenu = Get-Content $script:CheminScript -Raw
        $contenu | Should -Match '\$Region\s*=\s*"francecentral"'
    }
    It "ne contient aucune commande de suppression de ressource" {
        $contenu = Get-Content $script:CheminScript -Raw
        $contenu | Should -Not -Match 'az.*\b(group|storage account|keyvault)\b.*\bdelete\b'
    }
}
