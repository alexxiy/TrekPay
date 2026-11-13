// End-to-end checks of Kerrigan key derivation and transaction signing
// against a regtest kerrigand + kerrigan-bridge (with ADDR_INDEX enabled).
//
// The regtest suites share one regtest chain (they mine blocks), so run
// them with --concurrency=1.
//
// Run on the build VM:
//   KERRIGAN_BRIDGE=http://127.0.0.1:3001 \
//   KERRIGAN_RPC=http://rpc:rpc@127.0.0.1:19898 \
//   flutter test --concurrency=1 test/kerrigan/kerrigan_regtest_test.dart
//
// Skipped when KERRIGAN_BRIDGE is not set.
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/kerrigan/kerrigan_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan/kerrigan_tx_parser.dart';

import 'regtest_node.dart';

const _mnemonic =
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon about";

void main() {
  final bridgeUrl = Platform.environment["KERRIGAN_BRIDGE"];
  final skip = bridgeUrl == null ? "KERRIGAN_BRIDGE not set" : null;

  final coin = Kerrigan(CryptoCurrencyNetwork.regtest);
  late KerriganBridgeClient bridge;
  late coinlib.HDPrivateKey root;

  setUpAll(() async {
    if (skip != null) return;
    await coinlib.loadCoinlib();
    bridge = KerriganBridgeClient(baseUri: Uri.parse(bridgeUrl!));
    root = coinlib.HDPrivateKey.fromSeed(bip39.mnemonicToSeed(_mnemonic));
  });

  String addressAt(int chain, int index) {
    final path = coin.constructDerivePath(
      derivePathType: DerivePathType.bip44,
      chain: chain,
      index: index,
    );
    return coin
        .getAddressForPublicKey(
          publicKey: root.derivePath(path).publicKey,
          derivePathType: DerivePathType.bip44,
        )
        .address
        .toString();
  }

  String accountXpub() => root
      .derivePath("m/44'/1'/0'")
      .hdPublicKey
      .encode(coin.networkParams.pubHDPrefix);

  test("bridge verifies as a regtest bridge", () async {
    expect(await bridge.verifyFor(coin), isNull);
    // A mainnet wallet must not accept it.
    expect(
      await bridge.verifyFor(Kerrigan(CryptoCurrencyNetwork.main)),
      isNotNull,
    );
  }, skip: skip);

  test(
    "addresses match a Kerrigan Core wallet restored from the same mnemonic",
    () async {
      final name = "trekpay-interop-${DateTime.now().millisecondsSinceEpoch}";
      await rpc("createwallet", [name, false, true, "", false, false, false]);
      await rpc("upgradetohd", [_mnemonic, "", "", false], name);
      expect(await rpc("getnewaddress", [], name), addressAt(0, 0));
      expect(await rpc("getnewaddress", [], name), addressAt(0, 1));
      await rpc("unloadwallet", [name]);
    },
    skip: skip,
  );

  test("bridge derives the same addresses from the account xpub", () async {
    final xpub = accountXpub();
    final info = await bridge.xpub(xpub, details: "tokens", tokens: "derived");
    final tokens = (info["tokens"] as List).cast<Map<String, dynamic>>();
    String tokenAt(String suffix) =>
        tokens.firstWhere((t) => (t["path"] as String).endsWith(suffix))["name"]
            as String;
    expect(tokenAt("/0/0"), addressAt(0, 0));
    expect(tokenAt("/0/7"), addressAt(0, 7));
    expect(tokenAt("/1/3"), addressAt(1, 3));
    // The node agrees it is a valid address for this chain.
    final v = await rpc("validateaddress", [addressAt(0, 0)]) as Map;
    expect(v["isvalid"], isTrue);
  }, skip: skip);

  test(
    "funds, signs and broadcasts a transparent transaction",
    () async {
      final xpub = accountXpub();
      final receive = addressAt(0, 0);

      // Fund the wallet from the node and confirm it.
      final fundTxid = await rpc("sendtoaddress", [receive, 12.5]) as String;
      // Unconfirmed: in the bridge's mempool view, with its lock state
      // (no masternodes on this regtest chain, so never locked).
      await waitFor(() async {
        final utxos = await bridge.utxo(xpub);
        return utxos.any((u) => u["txid"] == fundTxid);
      });
      final pending = (await bridge.utxo(xpub))
          .firstWhere((u) => u["txid"] == fundTxid);
      expect(pending["confirmations"], 0);
      expect(pending["instantlock"], isFalse);
      expect((await bridge.tx(fundTxid))["instantlock"], isFalse);

      await mine();
      await waitFor(() async {
        final utxos = await bridge.utxo(xpub);
        return utxos.any(
          (u) => u["txid"] == fundTxid && (u["confirmations"] as int) > 0,
        );
      });
      final utxo = (await bridge.utxo(xpub))
          .firstWhere((u) => u["txid"] == fundTxid);
      final value = BigInt.parse(utxo["value"] as String);
      expect(utxo["address"], receive);
      expect(utxo["path"], "m/44'/1'/0'/0/0");

      // Spend it: one output to the node, change back to our change
      // chain. Same construction as KerriganWallet (version 2, P2PKH).
      final key = root.derivePath("m/44'/1'/0'/0/0");
      final nodeAddress = await rpc("getnewaddress") as String;
      final change = addressAt(1, 0);
      final fee = BigInt.from((10 + 149 + 2 * 34) * coin.minFeePerByte);
      final toNode = BigInt.from(300000000);

      var tx = coinlib.Transaction(version: 2, inputs: [], outputs: [])
          .addInput(
            coinlib.P2PKHInput(
              prevOut: coinlib.OutPoint(
                Uint8List.fromList(
                  fundTxid.toUint8ListFromHex.reversed.toList(),
                ),
                utxo["vout"] as int,
              ),
              publicKey: key.publicKey,
              sequence: 0xffffffff,
            ),
          )
          .addOutput(
            coinlib.Output.fromAddress(
              toNode,
              coinlib.Address.fromString(nodeAddress, coin.networkParams),
            ),
          )
          .addOutput(
            coinlib.Output.fromAddress(
              value - toNode - fee,
              coinlib.Address.fromString(change, coin.networkParams),
            ),
          );
      tx = tx.signLegacy(inputN: 0, key: key.privateKey);

      final txid = await bridge.sendTx(tx.toHex());
      expect(txid, tx.txid);

      // In the node's mempool, then visible through the bridge as unconfirmed.
      expect(await rpc("getrawmempool"), contains(txid));
      await waitFor(() async {
        final info = await bridge.xpub(xpub, details: "basic");
        return (info["unconfirmedTxs"] as int) > 0;
      });

      await mine();
      await waitFor(() async {
        final t = await bridge.tx(txid);
        return (t["confirmations"] as int) > 0;
      });
      final t = await bridge.tx(txid);
      expect(t["fees"], fee.toString());
      expect(t.containsKey("instantlock"), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    "raw transactions hash to their txid and give the real output values",
    () async {
      // Recent blocks: coinbase, transparent and (after the shield tests)
      // Sapling (type 10) transactions.
      var height = await bridge.getBlockCount();
      int checked = 0;
      int sapling = 0;
      while (height > 0 && (checked < 20 || sapling == 0) && checked < 400) {
        final hash = await rpc("getblockhash", [height]) as String;
        final block = await rpc("getblock", [hash, 1]) as Map;
        for (final txid in (block["tx"] as List).cast<String>()) {
          final raw = await bridge.rawTx(txid);
          final values = kerriganVerifiedOutputs(
            txid,
            raw,
          ).map((e) => e.value).toList();
          final node = await rpc("getrawtransaction", [txid, true]) as Map;
          expect(values, [
            for (final o in node["vout"] as List)
              BigInt.from((o as Map)["valueSat"] as int),
          ], reason: txid);
          if (node["type"] == 10) sapling++;
          checked++;
        }
        height--;
      }
      expect(checked, greaterThan(0));
      // A tampered transaction doesn't pass.
      final hash =
          await rpc("getblockhash", [await bridge.getBlockCount()]) as String;
      final txid =
          ((await rpc("getblock", [hash, 1]) as Map)["tx"] as List).first
              as String;
      final raw = await bridge.rawTx(txid);
      final tampered = "${raw.substring(0, raw.length - 2)}ff";
      expect(() => kerriganVerifiedOutputs(txid, tampered), throwsException);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    "watch long-poll wakes on our mempool tx and on blocks only",
    () async {
      final ours = addressAt(0, 5);
      late int height;
      late KerriganBridgeWatch r;
      late Object? paid;
      // A miner on the regtest node may wake the watch first: then the
      // round is tried again.
      for (var round = 1; ; round++) {
        height = await bridge.getBlockCount();
        // Establish the mempool sequence.
        final base = await bridge.watch(height: height, timeoutSeconds: 1);
        expect(base.changed, isFalse);

        // An unrelated tx does not wake us; a payment to our address does.
        final watched = bridge.watch(
          height: height,
          mempoolSeq: base.mempoolSeq,
          addresses: [ours],
          timeoutSeconds: 30,
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        await rpc("sendtoaddress", [await rpc("getnewaddress"), 1]);
        await Future<void>.delayed(const Duration(seconds: 3));
        paid = await rpc("sendtoaddress", [ours, 1]);
        r = await watched;
        if (!r.newBlock || round == 3) break;
      }
      expect(r.changed, isTrue);
      expect(r.newBlock, isFalse);
      expect(r.txids, [paid]);

      // A new block wakes us.
      final next = bridge.watch(
        height: height,
        mempoolSeq: r.mempoolSeq,
        addresses: [ours],
        timeoutSeconds: 30,
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      await mine();
      final b = await next;
      expect(b.newBlock, isTrue);
      expect(b.height, greaterThan(height));

      // A sequence the bridge never issued asks for a full resync.
      final reset = await bridge.watch(
        height: b.height,
        hash: b.hash,
        mempoolSeq: 1 << 40,
        timeoutSeconds: 5,
      );
      expect(reset.reset, isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
