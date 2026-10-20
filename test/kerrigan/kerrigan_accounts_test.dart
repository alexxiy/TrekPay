// The account helpers: BIP44 accounts of a recovery phrase, each a wallet
// of its own. Account 0 against Kerrigan Core itself is in
// kerrigan_regtest_test.dart.
import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/kerrigan_accounts/kerrigan_accounts.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan_wallet.dart';

const _mnemonic =
    "high fruit sick panther hospital place robust seminar maze benefit shoe bleak";

/// BIP39 seeds and roots of a phrase, with and without a passphrase.
const _bip39Seeds = [
  (
    mnemonic: "display item diagram flip slogan firm illness measure staff shrimp absent abandon",
    passphrase: "",
    seed:
        "2e92a1b65e77b6f1e5a77b9a5bab3be47e47cc8286a04f863d9d7829300b4f94"
        "4037b9472c9b8d578dc966c30f3d7ac81021b6cbb783f1453612d8ebccd6c4ed",
    xprv: "xprv9s21ZrQH143K35E747GySrQzeXGAS1rsfCyfMjEyFAczB4Xwy6phKaE5ps9FxcswDAaFqamX3BEAR6CePBKZqHGK5mtjUtMJ3EzevA773h6",
  ),
  (
    mnemonic: "display item diagram flip slogan firm illness measure staff shrimp absent abandon",
    passphrase: "123456",
    seed:
        "9e867a891a3420fbf2e2ee5c760cea1b27f5d920a009b6ae7582466f2b614953"
        "7be6e7f87489f11bd929e284c49e4ca98c592a8c84147f203e75ce71a0be80df",
    xprv: "xprv9s21ZrQH143K2LMsnBWQyzuwJWqeTagZ8i3hDwRNhYPVauTTmw3gmqDYDaZSthdLJ6HhvKrp6qAP4xEC3SvzofZmV4XSUPo3B7WE1JWEt8Y",
  ),
];

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  final mainnet = Kerrigan(CryptoCurrencyNetwork.main);

  // As KerriganWallet._deriveAddress: public derivation from the account xpub.
  String receiving(Kerrigan coin, String accountXpub, int index) => coin
      .getAddressForPublicKey(
        publicKey: coinlib.HDPublicKey.decode(
          accountXpub,
          coin.networkParams.pubHDPrefix,
        ).derivePath("0/$index").publicKey,
        derivePathType: DerivePathType.bip44,
      )
      .address
      .toString();

  test("a phrase and passphrase give the BIP39 seed", () {
    // As KerriganWallet._seed and getRootHDNode.
    for (final v in _bip39Seeds) {
      final seed = bip39.mnemonicToSeed(v.mnemonic, passphrase: v.passphrase);
      expect(seed.toHex, v.seed);
      expect(
        coinlib.HDPrivateKey.fromSeed(seed)
            .encode(mainnet.networkParams.privHDPrefix),
        v.xprv,
      );
    }
  });

  for (final network in CryptoCurrencyNetwork.values) {
    test("an account's xpub gives its addresses on ${network.name}", () {
      final coin = Kerrigan(network);
      final root = coinlib.HDPrivateKey.fromSeed(
        bip39.mnemonicToSeed(_mnemonic),
      );
      final seen = <String>{};
      for (final account in [0, 1, 2]) {
        final xpub = kerriganAccountXpub(root, coin, account);
        for (int i = 0; i < 5; i++) {
          // The full path from the root, as signing derives the key.
          final key = root.derivePath(
            coin.constructDerivePath(
              derivePathType: DerivePathType.bip44,
              account: account,
              chain: 0,
              index: i,
            ),
          );
          final expected = coin
              .getAddressForPublicKey(
                publicKey: key.publicKey,
                derivePathType: DerivePathType.bip44,
              )
              .address
              .toString();
          expect(receiving(coin, xpub, i), expected, reason: "$account/0/$i");
          expect(coin.validateAddress(expected), isTrue);
          seen.add(expected);
        }
      }
      expect(seen, hasLength(15), reason: "accounts share no address");
    });
  }

  test("account paths", () {
    expect(kerriganAccountPath(mainnet, 0), "m/44'/99888'/0'");
    expect(kerriganAccountPath(mainnet, 2), "m/44'/99888'/2'");
    expect(
      kerriganAccountPath(Kerrigan(CryptoCurrencyNetwork.test), 1),
      "m/44'/1'/1'",
    );
    expect(
      kerriganAccountPath(Kerrigan(CryptoCurrencyNetwork.regtest), 1),
      "m/44'/1'/1'",
    );
  });

  group("finding used accounts", () {
    Future<List<int>> find(Set<int> used) =>
        kerriganFindAccounts(from: 1, isUsed: (n) async => used.contains(n));

    test("looks past two unused accounts, not three", () async {
      expect(await find({}), isEmpty);
      expect(await find({1, 2}), [1, 2]);
      expect(await find({2, 5}), [2, 5]);
      expect(await find({3}), [3]);
      expect(await find({4}), isEmpty);
    });

    test("stops after 20 accounts", () async {
      final all = await kerriganFindAccounts(from: 1, isUsed: (_) async => true);
      expect(all, [for (int n = 1; n <= 20; n++) n]);
    });

    test("reads the bridge's answer", () {
      expect(kerriganXpubIsUsed({}), isFalse);
      expect(kerriganXpubIsUsed({"usedTokens": 0, "txs": 0}), isFalse);
      expect(kerriganXpubIsUsed({"usedTokens": 2}), isTrue);
      expect(kerriganXpubIsUsed({"txs": 1}), isTrue);
      expect(kerriganXpubIsUsed({"unconfirmedTxs": 1}), isTrue);
    });
  });

  group("account wallets", () {
    test("the next account is the lowest one not here", () {
      expect(kerriganNextAccount([]), 1);
      expect(kerriganNextAccount([0]), 1);
      expect(kerriganNextAccount([0, 1, 2]), 3);
      expect(kerriganNextAccount([0, 2]), 1);
      expect(kerriganNextAccount([1, 0, 3]), 2);
    });

    test("names", () {
      expect(kerriganAccountWalletName("Savings", 1, {}), "Savings (account 1)");
      expect(
        kerriganAccountWalletName("Savings (account 1)", 2, {}),
        "Savings (account 2)",
      );
      expect(
        kerriganAccountWalletName("Savings", 2, {"Savings (account 2)"}),
        "Savings (account 2) 2",
      );
      expect(
        kerriganAccountWalletName("Savings (account 2) 2", 3, {}),
        "Savings (account 3)",
      );
    });
  });
}
