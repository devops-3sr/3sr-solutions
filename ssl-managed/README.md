# SSL Managed

Scripts and guides for customers of the **3SR SSL Managed** service. 3SR issues and renews your SSL/TLS certificates; the certificates are delivered into **your own** Azure Key Vault, and your private keys never leave your environment.

*Scripts et guides pour les clients du service **3SR SSL Managed**. 3SR émet et renouvelle vos certificats SSL/TLS ; ils sont déposés dans **votre** coffre Azure Key Vault, et vos clés privées ne quittent jamais votre environnement.*

## Files

| File | Purpose |
|---|---|
| [`3sr-ssl-onboarding.ps1`](3sr-ssl-onboarding.ps1) | Creates, in your subscription, the resource group, storage account and Key Vault, and grants 3SR two limited roles |
| [`3sr-ssl-offboarding.ps1`](3sr-ssl-offboarding.ps1) | Removes the roles granted to 3SR. Deletes no resource |
| [`3sr-ssl-onboarding-guide-en.md`](3sr-ssl-onboarding-guide-en.md) | Step-by-step guide (English) |
| [`3sr-ssl-onboarding-guide-fr.md`](3sr-ssl-onboarding-guide-fr.md) | Guide pas à pas (français) |

The scripts display their messages in French.

## What you need

- You are a 3SR SSL Managed customer: 3SR provides you with a certificate list file named `<your-code>-ssl.json`. **Without it, the scripts are of no use on their own.**
- Azure CLI and PowerShell 5.1 or later, and the Owner role on the target subscription.

## Read before you run

1. Read the guide and the script.
2. Run the simulation: `.\3sr-ssl-onboarding.ps1 -Simulation` (nothing is created or modified).
3. Check the SHA-256 of the script against the one published in the release notes:
   ```powershell
   Get-FileHash .\3sr-ssl-onboarding.ps1 -Algorithm SHA256
   ```
4. Run it for real.

## Versions

See [`CHANGELOG.md`](CHANGELOG.md) and the GitHub releases (tags `ssl-managed-vX.Y.Z`).

## License

[MIT](../LICENSE).
