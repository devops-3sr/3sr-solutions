@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # Scripts interactifs : l'affichage en console est voulu.
        'PSAvoidUsingWriteHost',
        # Appels de commandes externes (az) avec arguments positionnels.
        'PSAvoidUsingPositionalParameters',
        # Fonctions internes : les scripts proposent un mode simulation et une confirmation explicite.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
