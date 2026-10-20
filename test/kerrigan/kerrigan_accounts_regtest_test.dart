// A phrase's other accounts on the regtest node + kerrigan-bridge: finding
// the used ones as a restore does (KerriganWallet.findUsedAccounts), and
// each account's own shield key.
//
// The regtest suites share one chain, so run them with --concurrency=1.
//
// Run on the DevBox (see kerrigan_regtest_test.dart):
//   KERRIGAN_BRIDGE=http://127.0.0.1:3001 \
//   KERRIGAN_RPC=http://rpc:rpc@127.0.0.1:19898 \
//   KERRIGAN_SHIELD_LIB=.../libkerrigan_shield_ffi.so \
//   flutter test --concurrency=1 test/kerrigan/kerrigan_accounts_regtest_test.dart
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_libkerriganshield/flutter_libkerriganshield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/wallets/api/kerrigan/kerrigan_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan_wallet.dart';

import 'regtest_node.dart';

// A fresh phrase per run keeps runs independent on a reused regtest chain.
final _mnemonic = bip39.generateMnemonic();

void main() {
  final bridgeUrl = Platform.environment["KERRIGAN_BRIDGE"];
  final skip = bridgeUrl == null ? "KERRIGAN_BRIDGE not set" : null;
  final skipShield = Platform.environment["KERRIGAN_SHIELD_LIB"] == null
      ? "KERRIGAN_SHIELD_LIB not set"
      : null;

  final coin = Kerrigan(CryptoCurrencyNetwork.regtest);
  final seed = bip39.mnemonicToSeed(_mnemonic);
  late KerriganBridgeClient bridge;
  late coinlib.HDPrivateKey root;

  setUpAll(() async {
    await coinlib.loadCoinlib();
    root = coinlib.HDPrivateKey.fromSeed(seed);
    if (bridgeUrl != null) {
      bridge = KerriganBridgeClient(baseUri: Uri.parse(bridgeUrl));
    }
  });

  String address(int account, {int chain = 0, int index = 0}) => coin
      .getAddressForPublicKey(
        publicKey: coinlib.HDPublicKey.decode(
          kerriganAccountXpub(root, coin, account),
          coin.networkParams.pubHDPrefix,
        ).derivePath("$chain/$index").publicKey,
        derivePathType: DerivePathType.bip44,
      )
      .address
      .toString();

  // As KerriganWallet.findUsedAccounts.
  Future<bool> used(int account) async => kerriganXpubIsUsed(
    await bridge.xpub(
      kerriganAccountXpub(root, coin, account),
      details: "basic",
      gap: 20,
    ),
  );

  test("finds the used accounts after the first", () async {
    expect(await kerriganFindAccounts(from: 1, isUsed: used), isEmpty);

    // Account 2 at a later receiving address, account 5 on its change
    // chain only; 1, 3 and 4 stay unused.
    await rpc("sendtoaddress", [address(2, index: 3), 1]);
    await rpc("sendtoaddress", [address(5, chain: 1), 1]);
    await mine();
    await waitFor(() async => await used(2) && await used(5), seconds: 90);

    expect(await used(1), isFalse);
    expect(await kerriganFindAccounts(from: 1, isUsed: used), [2, 5]);
    expect(await kerriganFindAccounts(from: 3, isUsed: used), [5]);
    expect(await kerriganFindAccounts(from: 6, isUsed: used), isEmpty);
  }, skip: skip);

  test("each account has its own shield key", () {
    String extsk(int account) => KerriganShield.extendedSpendingKey(
      seed: seed,
      coinType: coin.coinType,
      accountIndex: account,
    );
    expect(
      KerriganShield.extendedSpendingKey(seed: seed, coinType: coin.coinType),
      extsk(0),
    );
    expect({extsk(0), extsk(1), extsk(2)}, hasLength(3));
    String shieldAddress(int account) => KerriganShield.defaultAddress(
      extfvk: KerriganShield.extendedFullViewingKey(extsk: extsk(account)),
      network: coin.shieldNetwork,
    ).address;
    expect(shieldAddress(1), isNot(shieldAddress(0)));
    expect(coin.isShieldAddress(shieldAddress(1)), isTrue);
  }, skip: skipShield);
}
