// End-to-end shield (Sapling) checks against regtest kerrigand +
// kerrigan-bridge, using the native library, the wallet's stream parser,
// bridge client and history parser.
//
// The regtest suites share one regtest chain (they mine blocks), so run
// them with --concurrency=1.
//
// Run on the DevBox:
//   KERRIGAN_BRIDGE=http://127.0.0.1:3001 \
//   KERRIGAN_RPC=http://rpc:rpc@127.0.0.1:19898 \
//   KERRIGAN_SHIELD_LIB=.../libkerrigan_shield_ffi.so \
//   KERRIGAN_PARAMS_DIR=~/.sapling-params \
//   flutter test --concurrency=1 test/kerrigan/kerrigan_shield_regtest_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_libkerriganshield/flutter_libkerriganshield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/blockchain_data/transaction_type.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/kerrigan/kerrigan_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan/kerrigan_shield_stream.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan/kerrigan_tx_parser.dart';

import 'regtest_node.dart';

// A fresh mnemonic per run keeps runs independent on a reused regtest chain.
final _mnemonic = bip39.generateMnemonic();
const _network = "regtest";

String _hex(String text) =>
    text.codeUnits.map((c) => c.toRadixString(16).padLeft(2, "0")).join();

/// Minimal port of the wallet's scanning loop (see
/// kerrigan_wallet_shield.dart), keeping what history parsing needs.
class _Scanner {
  _Scanner(this.bridge, this.extfvk, this.height, this.tree);

  final KerriganBridgeClient bridge;
  final String extfvk;
  int height;
  String tree;
  List<Map<String, dynamic>> notes = [];
  final walletTxs = <Map<String, dynamic>>[];
  final nullifierNotes = <String, Map<String, dynamic>>{};
  final txInfo = <String, Map<String, dynamic>>{};

  Future<void> sync() async {
    final blocks = await parseKerriganShieldStream(
      bridge.shieldData(height + 1),
    ).toList();
    if (blocks.isEmpty) return;
    final r = await KerriganShield.handleBlocks(
      tree: tree,
      blocks: [for (final b in blocks) b.txs],
      extfvk: extfvk,
      network: _network,
      notes: notes,
    );
    for (final n in r["decrypted_new_notes"] as List) {
      nullifierNotes[(n as Map)["nullifier"] as String] = {
        "value": n["value"],
        "address": n["address"],
      };
    }
    final spent = Set<String>.from(r["nullifiers"] as List);
    notes = [
      for (final n in [
        ...r["decrypted_notes"] as List,
        ...r["decrypted_new_notes"] as List,
      ])
        if (!spent.contains((n as Map)["nullifier"]))
          Map<String, dynamic>.from(n),
    ];
    for (final w in r["wallet_transactions"] as List) {
      final wtx = Map<String, dynamic>.from(w as Map);
      walletTxs.add(wtx);
      // Same shape as KerriganShieldState.txInfo.
      txInfo[wtx["txid"] as String] = {
        "received": wtx["received"],
        "spentNullifiers": [
          for (final nf in wtx["nullifiers"] as List)
            if (nullifierNotes.containsKey(nf)) nf,
        ],
        "sent": wtx["sent"],
      };
    }
    tree = r["commitment_tree"] as String;
    height = blocks.last.height;
  }

  int get balance => notes.fold(0, (p, n) => p + (n["value"] as num).toInt());
}

void main() {
  final bridgeUrl = Platform.environment["KERRIGAN_BRIDGE"];
  final skip =
      bridgeUrl == null || Platform.environment["KERRIGAN_SHIELD_LIB"] == null
      ? "KERRIGAN_BRIDGE / KERRIGAN_SHIELD_LIB not set"
      : null;

  final coin = Kerrigan(CryptoCurrencyNetwork.regtest);
  late KerriganBridgeClient bridge;
  late Uint8List seed;
  late String extsk;
  late String extfvk;
  late String shieldAddress;
  late _Scanner scanner;
  late coinlib.HDPrivateKey tKey;
  late String tAddress;

  setUpAll(() async {
    if (skip != null) return;
    await coinlib.loadCoinlib();
    bridge = KerriganBridgeClient(baseUri: Uri.parse(bridgeUrl!));
    seed = bip39.mnemonicToSeed(_mnemonic);
    extsk = KerriganShield.extendedSpendingKey(
      seed: seed,
      coinType: coin.coinType,
    );
    extfvk = KerriganShield.extendedFullViewingKey(extsk: extsk);
    shieldAddress = KerriganShield.defaultAddress(
      extfvk: extfvk,
      network: _network,
    ).address;
    // No checkpoints: scan from Sapling activation, like the wallet.
    final cp = KerriganShield.closestCheckpoint(
      height: await bridge.getBlockCount(),
      network: _network,
    );
    scanner = _Scanner(bridge, extfvk, cp.height, cp.tree);
    final dir = Platform.environment["KERRIGAN_PARAMS_DIR"]!;
    await KerriganShield.loadProver(
      outputParamsPath: "$dir/sapling-output.params",
      spendParamsPath: "$dir/sapling-spend.params",
    );
    final path = coin.constructDerivePath(
      derivePathType: DerivePathType.bip44,
      chain: 0,
      index: 0,
    );
    tKey = coinlib.HDPrivateKey.fromSeed(seed).derivePath(path);
    tAddress = coin
        .getAddressForPublicKey(
          publicKey: tKey.publicKey,
          derivePathType: DerivePathType.bip44,
        )
        .address
        .toString();
  });

  /// The wallet's history entry of [txid], parsed like the wallet does.
  Future<TransactionV2> parsed(String txid) async {
    final json = await bridge.tx(txid);
    return parseKerriganTx(
      json,
      walletId: "w",
      fractionDigits: 8,
      receiving: {tAddress},
      change: const {},
      shieldAddresses: {shieldAddress},
      shield: scanner.txInfo[txid],
      nullifierNotes: scanner.nullifierNotes,
    )!;
  }

  BigInt shown(TransactionV2 tx) => tx.type == TransactionType.incoming
      ? tx.getAmountReceivedInThisWallet(fractionDigits: 8).raw
      : tx
            .getAmountSentFromThisWallet(fractionDigits: 8, subtractFee: true)
            .raw;

  test(
    "receives a shield note with a memo from Kerrigan Core",
    () async {
      expect(coin.isShieldAddress(shieldAddress), isTrue);
      final from = await rpc("getnewaddress") as String;
      await rpc("sendtoaddress", [from, 20]);
      await mine();
      final txid =
          await rpc("z_sendmany", [
                from,
                [
                  {
                    "address": shieldAddress,
                    "amount": 7,
                    "memo": _hex("hello trekpay"),
                  },
                ],
              ])
              as String;
      await mine();
      await waitFor(() async {
        await scanner.sync();
        return scanner.balance == 700000000;
      });
      expect(scanner.notes.single["address"], shieldAddress);
      expect(scanner.notes.single["scope"], "external");
      final w = scanner.walletTxs.last;
      expect(w["txid"], txid);
      expect(w["received"][0]["value"], 700000000);
      expect(w["received"][0]["memo"], "hello trekpay");
      expect(w["received"][0]["change"], isFalse);
      // Coin control identifies notes by txid + output index.
      expect(w["received"][0]["nullifier"], scanner.notes.single["nullifier"]);
      expect(w["received"][0]["index"], isA<int>());

      final tx = await parsed(txid);
      expect(tx.type, TransactionType.incoming);
      expect(shown(tx), BigInt.from(700000000));
      expect(tx.otherData, contains("hello trekpay"));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    "unshields to Kerrigan Core; change comes back to the internal key",
    () async {
      final dest = await rpc("getnewaddress") as String;
      final change = KerriganShield.changeAddress(
        extfvk: extfvk,
        network: _network,
      );
      final r = await KerriganShield.createTransaction(
        notes: scanner.notes,
        extsk: extsk,
        toAddress: dest,
        changeAddress: "",
        amount: 200000000,
        network: _network,
      );
      final fee = r["fee"] as int;
      // Kerrigan's Sapling fee: 1 spend, 2 outputs.
      expect(fee, 25000);
      final txid = await bridge.sendTx(r["txhex"] as String);
      expect(txid, r["txid"]);
      expect(await rpc("getrawmempool"), contains(txid));
      await mine();
      await waitFor(() async {
        await scanner.sync();
        return scanner.balance == 700000000 - 200000000 - fee;
      });
      expect(scanner.notes.single["address"], change);
      expect(scanner.notes.single["scope"], "internal");
      // The bridge's fee for the tx matches the library's.
      expect((await bridge.tx(txid))["fees"], "$fee");
      // Kerrigan Core received it.
      expect(await rpc("getreceivedbyaddress", [dest, 0]), 2);

      final tx = await parsed(txid);
      expect(tx.type, TransactionType.outgoing);
      expect(shown(tx), BigInt.from(200000000));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    "shields transparent coins (utxos -> own shield address)",
    () async {
      final fundTxid = await rpc("sendtoaddress", [tAddress, 5]) as String;
      await mine();
      late Map<String, dynamic> utxo;
      await waitFor(() async {
        final list = await bridge.utxo(tAddress);
        final found = list.where(
          (u) => u["txid"] == fundTxid && (u["confirmations"] as int) > 0,
        );
        if (found.isEmpty) return false;
        utxo = found.first;
        return true;
      });

      final before = scanner.balance;
      final r = await KerriganShield.createTransaction(
        utxos: [
          {
            "txid": fundTxid,
            "vout": utxo["vout"],
            "amount": int.parse(utxo["value"] as String),
            "private_key": tKey.privateKey.data.toHex,
            "script": coinlib.Address.fromString(
              tAddress,
              coin.networkParams,
            ).program.script.compiled.toHex,
          },
        ],
        extsk: extsk,
        toAddress: shieldAddress,
        changeAddress: tAddress,
        amount: 300000000,
        network: _network,
      );
      expect(r["nullifiers"], ["$fundTxid,${utxo["vout"]}"]);
      expect(r["fee"], 20000);
      final txid = await bridge.sendTx(r["txhex"] as String);
      await mine();
      await waitFor(() async {
        await scanner.sync();
        return scanner.balance == before + 300000000;
      });
      // Transparent change came back to us.
      final t = await bridge.tx(txid);
      expect(
        (t["vout"] as List).any(
          (o) => (o["addresses"] as List).contains(tAddress),
        ),
        isTrue,
      );

      final tx = await parsed(txid);
      expect(tx.type, TransactionType.sentToSelf);
      expect(tx.kerriganKind, KerriganTxKind.shield);
      expect(shown(tx), BigInt.from(300000000));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    "coin control: useAllInputs spends every selected note",
    () async {
      expect(scanner.notes.length, greaterThanOrEqualTo(2));
      final dest = await rpc("getnewaddress") as String;
      Future<Map<String, dynamic>> build(bool all) =>
          KerriganShield.createTransaction(
            notes: scanner.notes,
            extsk: extsk,
            toAddress: dest,
            changeAddress: "",
            amount: 10000000,
            network: _network,
            useAllInputs: all,
          );
      // A small amount needs one note; with coin control every note goes in.
      expect((await build(false))["nullifiers"], hasLength(1));
      final r = await build(true);
      expect(r["nullifiers"], hasLength(scanner.notes.length));
      expect(r["fee"], 10000 + 5000 * scanner.notes.length + 10000);
      final before = scanner.balance;
      await bridge.sendTx(r["txhex"] as String);
      await mine();
      await waitFor(() async {
        await scanner.sync();
        return scanner.notes.length == 1;
      });
      expect(scanner.balance, before - 10000000 - (r["fee"] as int));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    "subtractFee: the recipient pays the fee",
    () async {
      final dest = await rpc("getnewaddress") as String;
      final before = scanner.balance;
      // Sending everything without subtractFee must fail, not quietly
      // take the fee out of the amount.
      await expectLater(
        KerriganShield.createTransaction(
          notes: scanner.notes,
          extsk: extsk,
          toAddress: dest,
          changeAddress: "",
          amount: before,
          network: _network,
        ),
        throwsA(predicate((e) => e.toString().contains("Not enough balance"))),
      );
      final r = await KerriganShield.createTransaction(
        notes: scanner.notes,
        extsk: extsk,
        toAddress: dest,
        changeAddress: "",
        amount: 50000000,
        network: _network,
        subtractFee: true,
      );
      final fee = r["fee"] as int;
      final txid = await bridge.sendTx(r["txhex"] as String);
      await mine();
      await waitFor(() async {
        await scanner.sync();
        return scanner.balance == before - 50000000;
      });
      final t = await bridge.tx(txid);
      final paid = (t["vout"] as List).firstWhere(
        (o) => (o["addresses"] as List).contains(dest),
      );
      expect(paid["value"], "${50000000 - fee}");
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    "shield -> Kerrigan Core's shield address: Core gets it, we see what we sent",
    () async {
      final dest = await rpc("z_getnewaddress") as String;
      final before = scanner.balance;
      const memo = "outgoing memo test";
      final r = await KerriganShield.createTransaction(
        notes: scanner.notes,
        extsk: extsk,
        toAddress: dest,
        changeAddress: "",
        amount: 20000000,
        network: _network,
        memo: memo,
      );
      final txid = await bridge.sendTx(r["txhex"] as String);
      await mine();
      await waitFor(() async {
        await scanner.sync();
        return scanner.walletTxs.any((w) => w["txid"] == txid);
      });
      // Only our change is ours; the recipient's note is not.
      expect(scanner.balance, before - 20000000 - (r["fee"] as int));
      for (final n in scanner.notes) {
        expect(n["address"], isNot(dest));
      }
      // The sender sees where it went (outgoing viewing key).
      final w = scanner.walletTxs.lastWhere((w) => w["txid"] == txid);
      final sent = (w["sent"] as List).single as Map;
      expect(sent["address"], dest);
      expect(sent["value"], 20000000);
      expect(sent["memo"], memo);
      // Kerrigan Core decrypts the note and its memo.
      final notes = (await rpc("z_listunspent", [0]) as List).cast<Map>();
      final note = notes.firstWhere((n) => n["address"] == dest);
      expect(note["amount"], 0.2);
      expect(note["memo"] as String, startsWith(_hex(memo)));

      final tx = await parsed(txid);
      expect(tx.type, TransactionType.outgoing);
      expect(shown(tx), BigInt.from(20000000));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
