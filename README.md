# TrekPay

TrekPay is a self-custodial mobile wallet for [Kerrigan](https://kerrigan.network) (KRGN). Your recovery phrase and keys never leave your device. The app talks to the Kerrigan network through a kerrigan-bridge server, and you can point it at your own.

## Features

- **Shielded (Sapling) transactions**: shield, unshield and send privately, with an optional encrypted memo. Shield change goes to your wallet's internal (change) key, as in Kerrigan Core.
- **Same keys as Kerrigan Core**: a recovery phrase restored in Kerrigan Core (`upgradetohd`) gives the same transparent addresses and the same shield keys.
- **InstantSend**: transactions locked by InstantSend show as confirmed and their coins can be spent at once.
- **Masternodes and governance**: register masternodes and BroodNodes from the wallet, follow their status and rewards, vote on proposals with all your masternodes and submit your own.
- **Kerrigan NameSpace**: pay to a KNS name like `alice.kerrigan` (the wallet checks the registry's proof before you send), and register, point, give away, list or buy names. KNS is run by [Kerrigan NameSpace](https://kerrigan-name.space), a service separate from TrekPay.
- **View-only wallets** from an xpub or a shield viewing key (`z_exportviewingkey`), with an optional birthday block.
- **History**: block and masternode rewards, proposal payments and shield transactions are labelled, and you can filter by each type. Rewards show how many confirmations are left until they mature.
- **Coin control**, an **address book** and **`kerrigan:` payment links**.
- **Backups**: encrypted backups of all wallets and settings, plus automatic backups.
- **Security**: PIN and fingerprint lock, and optional Tor for every connection.
- Open source (GPLv3), with no ads and no tracking.

Kerrigan logic follows [Kerrigan Core](https://github.com/kerrigan-network/kerrigan). The shield code (`crypto_plugins/flutter_libkerriganshield`) is a Rust library on `sapling-crypto` that reads and writes Kerrigan's Sapling transactions (special transaction type 10).

TrekPay started as a port of PIVXie, a PIVX wallet.

## Platforms

- **Android**: the main platform (targets Android 17, API 37).
- **iOS**: builds on a macOS host.
- **Linux**: builds and runs, shield included. Packaged as a tarball, Flatpak (`flatpak/`) or AppImage (`appimage/`).
- **Windows and macOS**: the build files are in place, shield included, but these builds are untested.

## Building

See the [build instructions](docs/building.md).

## Credits

TrekPay is built on [Stack Wallet](https://github.com/cypherstack/stack_wallet) by Cypher Stack, which is licensed under GPLv3. Source files keep their original copyright notices.

## License

[GPLv3](LICENSE)

Google Play and the Google Play logo are trademarks of Google LLC.
