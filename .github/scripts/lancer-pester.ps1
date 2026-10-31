# Lance les tests Pester 5 du depot. Utilise sur PowerShell 7 et sur Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
Install-Module Pester -RequiredVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Import-Module Pester -RequiredVersion 5.5.0
$config = New-PesterConfiguration
$config.Run.Path = 'ssl-managed/tests'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
