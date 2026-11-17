// Two real KerriganWallets on regtest (Isar, the shield library, the bridge
// behind a proxy that can fail requests) send to each other in every
// direction: transparent or shield, to a transparent or a shield address.
// Both sides must end up confirmed at the tx's block:
// - live: both wallets sync while the tx waits and after it is mined;
// - closed: the wallets don't sync until long after the tx was mined;
// - cutScan: the first sync after the tx was mined fails inside the shield
//   scan (the bridge refuses the tx). Before the fix, the wallet's notes
//   moved on without the tree, and the next shield send failed with
//   "Failed to add sapling spend";
// - cutHistory: that sync fails after the shield scan saved its blocks and
//   before the history was stored, as when the app closes mid-sync. Before
//   the fix, a shield-to-shield send stayed "Sending (0/1)" for good.
// Later blocks carry newer txs for both wallets, so a wallet that missed
// the tx's block can't pick it up again by chance.
//
// Needs KERRIGAN_BRIDGE, KERRIGAN_RPC, KERRIGAN_SHIELD_LIB,
// KERRIGAN_PARAMS_DIR (as the other regtest suites; see
// ~/work/kerrigan_regtest_tests.sh) and libisar.so (ISAR_LIB, default: the
// Linux release bundle's).
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:decimal/decimal.dart';
import 'package:flutter_libkerriganshield/flutter_libkerriganshield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:paymint/db/isar/main_db.dart';
import 'package:paymint/models/isar/models/block_explorer.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/models/isar/models/contact_entry.dart';
import 'package:paymint/models/isar/models/isar_models.dart';
import 'package:paymint/models/isar/stack_theme.dart';
import 'package:paymint/models/node_model.dart';
import 'package:paymint/services/node_service.dart';
import 'package:paymint/utilities/amount/amount.dart';
import 'package:paymint/utilities/flutter_secure_storage_interface.dart';
import 'package:paymint/utilities/prefs.dart';
import 'package:paymint/utilities/stack_file_system.dart';
import 'package:paymint/wallets/api/kerrigan/kerrigan_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/isar/models/wallet_info.dart';
import 'package:paymint/wallets/isar/models/wallet_info_meta.dart';
import 'package:paymint/wallets/models/tx_data.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan_wallet.dart';
import 'package:paymint/wallets/wallet/wallet.dart';

import 'regtest_node.dart' as node;

final _env = Platform.environment;

class _Prefs extends Fake implements Prefs {
  @override
  bool get useTor => false;
}

class _Nodes extends Fake implements NodeService {
  _Nodes(this.node);
  final NodeModel node;

  @override
  NodeModel? getPrimaryNodeFor({required CryptoCurrency currency}) => node;
}

/// Passes requests on to the bridge, but answers 503 for `/tx/<txid>`
/// while the txid is in [failTx], once its count of requests still let
/// through is used up.
class _Proxy {
  _Proxy(this.target);
  final Uri target;
  final failTx = <String, int>{};
  var refused = 0;
  final _client = HttpClient()..autoUncompress = false;
  late HttpServer _server;

  int get port => _server.port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() async {
    await _server.close(force: true);
    _client.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final s = req.uri.pathSegments;
    if (s.length == 2 && s[0] == "tx" && failTx.containsKey(s[1])) {
      final left = failTx[s[1]]!;
      if (left > 0) {
        failTx[s[1]] = left - 1;
      } else {
        refused++;
        req.response.statusCode = 503;
        await req.response.close();
        return;
      }
    }
    try {
      final out = await _client.openUrl(
        req.method,
        target.replace(path: req.uri.path, query: req.uri.query),
      );
      req.headers.forEach((k, v) {
        if (k != HttpHeaders.hostHeader) {
          for (final x in v) {
            out.headers.add(k, x);
          }
        }
      });
      await out.addStream(req);
      final resp = await out.close();
      req.response.statusCode = resp.statusCode;
      for (final h in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentEncodingHeader,
      ]) {
        final v = resp.headers.value(h);
        if (v != null) req.response.headers.set(h, v);
      }
      await req.response.addStream(resp);
      await req.response.close();
    } catch (_) {
      req.response.statusCode = 502;
      await req.response.close();
    }
  }
}

enum _Mode { live, closed, cutScan, cutHistory }

void main() {
  final bridgeUrl = _env["KERRIGAN_BRIDGE"];
  final skip =
      bridgeUrl == null ||
          _env["KERRIGAN_SHIELD_LIB"] == null ||
          _env["KERRIGAN_PARAMS_DIR"] == null
      ? "KERRIGAN_BRIDGE / KERRIGAN_SHIELD_LIB / KERRIGAN_PARAMS_DIR not set"
      : null;

  final coin = Kerrigan(CryptoCurrencyNetwork.regtest);
  late Directory dir;
  late Isar isar;
  late _Proxy proxy;
  late KerriganBridgeClient bridge;
  late KerriganWallet a;
  late KerriganWallet b;

  Future<KerriganWallet> newWallet(String name, NodeService nodes) async {
    final w = await Wallet.create(
      walletInfo: WalletInfo.createNew(coin: coin, name: name),
      mainDB: MainDB.instance,
      secureStorageInterface: FakeSecureStorage(),
      nodeService: nodes,
      prefs: _Prefs(),
      mnemonic: bip39.generateMnemonic(strength: 256),
      mnemonicPassphrase: "",
    );
    await w.init();
    return w as KerriganWallet;
  }

  Future<void> sync(KerriganWallet w) async {
    await w.updateChainHeight();
    await w.updateUTXOs();
    await w.updateTransactions();
    await w.updateBalance();
  }

  Future<void> syncBoth() async {
    await sync(a);
    await sync(b);
  }

  Future<TransactionV2?> row(KerriganWallet w, String txid) =>
      MainDB.instance.isar.transactionV2s.getByTxidWalletId(txid, w.walletId);

  /// Mines [n] blocks and waits until the bridge has indexed them and,
  /// for each of [txids], every transparent address the tx touches.
  Future<void> mine(int n, [List<String> txids = const []]) async {
    // The regtest miner timer may be mining at the same moment.
    for (var i = 0; ; i++) {
      try {
        await node.mine(n);
        break;
      } catch (_) {
        if (i == 10) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    final tip = await node.rpc("getblockcount") as int;
    for (var i = 0; i < 120 && await bridge.getBlockCount() < tip; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    for (final txid in txids) {
      for (var i = 0; ; i++) {
        final json = await bridge.tx(txid);
        var ok = (json["blockHeight"] as int? ?? -1) > 0;
        final addresses = {
          for (final io in [
            ...?json["vin"] as List?,
            ...?json["vout"] as List?,
          ])
            ...?((io as Map)["addresses"] as List?)?.cast<String>(),
        };
        for (final address in addresses) {
          if (!ok) break;
          try {
            ok = (await bridge.addressTxs(
              address,
              pageSize: 50,
            )).any((t) => t["txid"] == txid);
          } catch (_) {}
        }
        if (ok) break;
        if (i == 120) throw Exception("the bridge never indexed $txid");
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  /// Shield payments in one tx, from a node address funded for it (the
  /// node's other sends would spend a standing one's coins).
  Future<String> zSend(Map<KerriganWallet, num> amounts) async {
    final from = await node.rpc("getnewaddress") as String;
    final total = amounts.values.fold<num>(0, (t, v) => t + v);
    await node.sendLarge(from, double.parse((total + 0.01).toStringAsFixed(8)));
    final opid = await node.rpc("z_sendmany", [
      from,
      [
        for (final e in amounts.entries)
          {"address": await e.key.getCurrentShieldAddress(), "amount": e.value},
      ],
      0,
    ]) as String;
    if (!opid.startsWith("opid-")) return opid;
    // An async operation: wait for its txid.
    for (var i = 0; ; i++) {
      final ops = await node.rpc("z_getoperationresult", [
        [opid],
      ]) as List;
      if (ops.isNotEmpty) {
        final op = ops.first as Map;
        if (op["status"] != "success") throw Exception("z_sendmany: $op");
        return (op["result"] as Map)["txid"] as String;
      }
      if (i == 120) throw Exception("z_sendmany: $opid never finished");
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Newer txs for both wallets, transparent and shield, in one block.
  Future<void> newerTxs() async {
    final txids = <String>[];
    for (final w in [a, b]) {
      txids.add(
        await node.rpc("sendtoaddress", [
          (await w.getCurrentReceivingAddress())!.value,
          0.1,
        ]) as String,
      );
    }
    txids.add(await zSend({a: 0.1, b: 0.1}));
    await mine(1, txids);
  }

  setUpAll(() async {
    if (skip != null) return;
    await coinlib.loadCoinlib();
    await Isar.initializeIsarCore(
      libraries: {
        Abi.linuxX64: File(
          _env["ISAR_LIB"] ?? "build/linux/x64/release/bundle/lib/libisar.so",
        ).absolute.path,
      },
    );
    dir = await Directory.systemTemp.createTemp("kerrigan_wallet_sync_test");
    StackFileSystem.setDesktopOverrideDir(dir.path);
    isar = await Isar.open([
      TransactionNoteSchema,
      UTXOSchema,
      AddressSchema,
      AddressLabelSchema,
      TransactionBlockExplorerSchema,
      StackThemeSchema,
      ContactEntrySchema,
      WalletInfoSchema,
      TransactionV2Schema,
      WalletInfoMetaSchema,
    ], directory: dir.path);
    await MainDB.instance.initMainDB(mock: isar);
    final p = _env["KERRIGAN_PARAMS_DIR"]!;
    await KerriganShield.loadProver(
      outputParamsPath: "$p/sapling-output.params",
      spendParamsPath: "$p/sapling-spend.params",
    );

    bridge = KerriganBridgeClient(baseUri: Uri.parse(bridgeUrl!));
    proxy = _Proxy(Uri.parse(bridgeUrl));
    await proxy.start();
    final nodes = _Nodes(
      coin
          .defaultNode(isPrimary: true)
          .copyWith(
            host: "127.0.0.1",
            port: proxy.port,
            useSSL: false,
            clearnetEnabled: true,
          ),
    );
    a = await newWallet("A", nodes);
    b = await newWallet("B", nodes);
    await syncBoth();

    // A: 40 KRGN transparent and 40 KRGN in the shield.
    final funding = [
      await node.sendLarge((await a.getCurrentReceivingAddress())!.value, 40),
      await zSend({a: 40}),
    ];
    await mine(2, funding);
    await syncBoth();
    final txs = await MainDB.instance.isar.transactionV2s
        .where()
        .walletIdEqualTo(a.walletId)
        .count();
    final utxos = await MainDB.instance.isar.utxos
        .where()
        .walletIdEqualTo(a.walletId)
        .count();
    final bal = a.info.cachedBalance;
    // ignore: avoid_print
    print(
      "A funded: txs $txs utxos $utxos total ${bal.total.raw} "
      "spendable ${bal.spendable.raw} pending ${bal.pendingSpendable.raw} "
      "shield ${a.info.otherData}",
    );
    expect(bal.total.raw, greaterThan(BigInt.zero));
  });

  tearDownAll(() async {
    if (skip != null) return;
    await proxy.close();
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  for (final mode in _Mode.values) {
    for (final fromShield in [false, true]) {
      for (final toShield in [false, true]) {
        final name =
            "${fromShield ? "shield" : "transparent"} to "
            "${toShield ? "shield" : "transparent"}, ${mode.name}";
        test(
          name,
          () async {
            final to = toShield
                ? (await b.getCurrentShieldAddress())!
                : (await b.getCurrentReceivingAddress())!.value;
            final prepared = await a.prepareSend(
              txData: TxData(
                note: "",
                noteOnChain: "",
                memo: toShield ? "sync test" : null,
                recipients: [
                  TxRecipient(
                    address: to,
                    amount: Amount.fromDecimal(
                      Decimal.parse("1.25"),
                      fractionDigits: coin.fractionDigits,
                    ),
                    isChange: false,
                    addressType: toShield
                        ? AddressType.kerriganShield
                        : AddressType.p2pkh,
                  ),
                ],
                otherData: jsonEncode(
                  kerriganFundingOtherData((
                    fromShield: fromShield,
                    coins: <UTXO>{},
                    changeAddress: null,
                  )),
                ),
              ),
            );
            final sent = await a.updateSentCachedTxData(
              txData: await a.confirmSend(txData: prepared),
            );
            final txid = sent.txid!;
            expect((await row(a, txid))?.height, isNull, reason: "pending");

            if (mode == _Mode.live) await syncBoth();
            await mine(1, [txid]);
            final height = (await bridge.tx(txid))["blockHeight"] as int;
            expect(height, greaterThan(0));

            if (mode == _Mode.cutScan || mode == _Mode.cutHistory) {
              proxy.refused = 0;
              for (final w in [a, b]) {
                // cutHistory: the scan's own request for the block's txs
                // goes through.
                proxy.failTx[txid] = mode == _Mode.cutHistory ? 1 : 0;
                try {
                  await sync(w);
                } catch (_) {
                  // The cut.
                }
              }
              proxy.failTx.remove(txid);
              // ignore: avoid_print
              print("$name: ${proxy.refused} requests refused");
            } else if (mode == _Mode.live) {
              await syncBoth();
            }

            // Past the history window, with newer txs on both sides.
            await mine(11);
            await newerTxs();
            await syncBoth();
            await syncBoth();

            final mine_ = await row(a, txid);
            final theirs = await row(b, txid);
            expect(mine_, isNotNull, reason: "sender's history");
            expect(mine_!.height, height, reason: "sender confirmed");
            expect(mine_.type, TransactionType.outgoing);
            expect(theirs, isNotNull, reason: "receiver's history");
            expect(theirs!.height, height, reason: "receiver confirmed");
            expect(theirs.type, TransactionType.incoming);
          },
          skip: skip,
          timeout: const Timeout(Duration(minutes: 6)),
        );
      }
    }
  }

  test(
    "both wallets still spend from the shield after the cuts",
    () async {
      final txids = <String>[];
      for (final (from, to) in [(a, b), (b, a)]) {
        final prepared = await from.prepareSend(
          txData: TxData(
            note: "",
            noteOnChain: "",
            memo: "after the cuts",
            recipients: [
              TxRecipient(
                address: (await to.getCurrentShieldAddress())!,
                amount: Amount.fromDecimal(
                  Decimal.parse("0.05"),
                  fractionDigits: coin.fractionDigits,
                ),
                isChange: false,
                addressType: AddressType.kerriganShield,
              ),
            ],
            otherData: jsonEncode(
              kerriganFundingOtherData((
                fromShield: true,
                coins: <UTXO>{},
                changeAddress: null,
              )),
            ),
          ),
        );
        txids.add(
          (await from.updateSentCachedTxData(
            txData: await from.confirmSend(txData: prepared),
          )).txid!,
        );
      }
      await mine(1, txids);
      await syncBoth();
      for (final txid in txids) {
        final height = (await bridge.tx(txid))["blockHeight"] as int;
        expect((await row(a, txid))?.height, height);
        expect((await row(b, txid))?.height, height);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
