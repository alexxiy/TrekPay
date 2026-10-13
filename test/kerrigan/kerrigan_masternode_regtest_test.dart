// Masternodes (DIP3) and governance against regtest kerrigand +
// kerrigan-bridge, the way the wallet does them: DIP 9 keys from a seed,
// provider transactions from the native library, a proposal paid with an
// OP_RETURN fee and submitted through the bridge, and a vote signed with
// the masternode's voting key.
//
// The regtest suites share one regtest chain (they mine blocks), so run
// them with --concurrency=1. Needs the node's masternode sync finished
// (the test asks `mnsync next`, the node has no peers on regtest) and
// over 10,000 KRGN in the node's test wallet.
//
// Run on the build VM:
//   KERRIGAN_BRIDGE=http://127.0.0.1:3001 \
//   KERRIGAN_RPC=http://rpc:rpc@127.0.0.1:19898 \
//   KERRIGAN_SHIELD_LIB=/root/work/kshield/target/release/libkerrigan_shield_ffi.so \
//   flutter test --concurrency=1 test/kerrigan/kerrigan_masternode_regtest_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:decimal/decimal.dart';
import 'package:flutter_libkerriganshield/flutter_libkerriganshield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/amount/amount.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/api/kerrigan/kerrigan_bridge_client.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan_wallet.dart';

import 'regtest_node.dart';

// A fresh mnemonic per run keeps runs independent on a reused regtest chain.
final _mnemonic = bip39.generateMnemonic();

void main() {
  final bridgeUrl = Platform.environment["KERRIGAN_BRIDGE"];
  final skip =
      bridgeUrl == null || Platform.environment["KERRIGAN_SHIELD_LIB"] == null
      ? "KERRIGAN_BRIDGE / KERRIGAN_SHIELD_LIB not set"
      : null;

  final coin = Kerrigan(CryptoCurrencyNetwork.regtest);
  final params = coin.networkParams;
  late KerriganBridgeClient bridge;
  late coinlib.HDPrivateKey root;

  String p2pkh(coinlib.ECPublicKey key) => coinlib.P2PKHAddress.fromPublicKey(
    key,
    version: params.p2pkhPrefix,
  ).toString();

  // As KerriganMasternodes derives them: m/9'/coin'/3'/feature'/index.
  coinlib.HDPrivateKey dip9(int feature, int index) =>
      root.derivePath("m/9'/${coin.coinType}'/3'/$feature'/$index");
  coinlib.HDPrivateKey bip44(int chain, int index) =>
      root.derivePath("m/44'/${coin.coinType}'/0'/$chain/$index");

  /// A UTXO of [amount] KRGN on [key]'s address, as the library takes it.
  Future<Map<String, dynamic>> fund(
    coinlib.HDPrivateKey key,
    int amount,
  ) async {
    final address = p2pkh(key.publicKey);
    final txid = await sendLarge(address, amount);
    await mine();
    final tx = await rpc("getrawtransaction", [txid, true]) as Map;
    final out = (tx["vout"] as List).cast<Map<String, dynamic>>().firstWhere((
      o,
    ) {
      final spk = o["scriptPubKey"] as Map<String, dynamic>;
      return spk["address"] == address ||
          ((spk["addresses"] as List?)?.contains(address) ?? false);
    });
    return {
      "txid": txid,
      "vout": out["n"],
      "amount": ((out["value"] as num) * 1e8).round(),
      "private_key": key.privateKey.data.toHex,
      "script": (out["scriptPubKey"] as Map)["hex"],
    };
  }

  Future<String> send(Map<String, dynamic> options) async {
    final r = await KerriganShield.createProTx({
      ...options,
      "change_address": p2pkh(bip44(1, 0).publicKey),
      "network": "regtest",
    });
    final txid = await bridge.sendTx(r["txhex"] as String);
    expect(txid, r["txid"]);
    await mine();
    return txid;
  }

  final port = 30000 + Random().nextInt(20000);
  late Map<String, dynamic> collateral;
  late String proTxHash;
  late ({String secret, String public}) operator;

  setUpAll(() async {
    if (skip != null) return;
    await coinlib.loadCoinlib();
    bridge = KerriganBridgeClient(baseUri: Uri.parse(bridgeUrl!));
    root = coinlib.HDPrivateKey.fromSeed(bip39.mnemonicToSeed(_mnemonic));
    // The node has no peers on regtest: finish its masternode sync so it
    // takes governance objects.
    for (int i = 0; i < 4; i++) {
      await rpc("mnsync", ["next"]);
    }
  });

  tearDownAll(() async {
    if (skip != null) return;
    // Spend the collateral back to the node: the masternode leaves the
    // list, so runs leave no masternodes without a server on the chain.
    try {
      final wif = coinlib
          .WIF(
            privkey: bip44(0, 0).privateKey,
            version: coin.networkParams.wifPrefix,
          )
          .toString();
      final amount = collateral["amount"] as int;
      final raw = await rpc("createrawtransaction", [
        [
          {"txid": collateral["txid"], "vout": collateral["vout"]},
        ],
        {await rpc("getnewaddress"): (amount - 10000) / 1e8},
      ]);
      final signed = await rpc("signrawtransactionwithkey", [
        raw,
        [wif],
        [
          {
            "txid": collateral["txid"],
            "vout": collateral["vout"],
            "scriptPubKey": collateral["script"],
            "amount": amount / 1e8,
          },
        ],
      ]) as Map;
      await rpc("sendrawtransaction", [signed["hex"]]);
      await mine();
    } catch (e) {
      // ignore: avoid_print
      print("Leaving the test masternode registered: $e");
    }
  });

  test("registers a masternode with keys derived from the seed", () async {
    collateral = await fund(bip44(0, 0), 10000);
    final feeCoin = await fund(bip44(0, 1), 1);
    operator = KerriganShield.blsKeygen(ikm: dip9(3, 0).privateKey.data);
    final owner = p2pkh(dip9(2, 0).publicKey);
    final voting = p2pkh(dip9(1, 0).publicKey);
    final payout = p2pkh(bip44(0, 0).publicKey);

    proTxHash = await send({
      "kind": "register",
      "collateral_txid": collateral["txid"],
      "collateral_vout": collateral["vout"],
      "collateral_key": collateral["private_key"],
      "service": "127.0.0.1:$port",
      "owner_address": owner,
      "voting_address": voting,
      "operator_public_key": operator.public,
      "payout_address": payout,
      "utxos": [feeCoin],
    });

    final info = await bridge.protxInfo(proTxHash);
    final state = info["state"] as Map;
    expect(info["collateralHash"], collateral["txid"]);
    expect(info["type"], "Regular");
    expect(state["ownerAddress"], owner);
    expect(state["votingAddress"], voting);
    expect(state["payoutAddress"], payout);
    expect(state["pubKeyOperator"], operator.public);
    expect(state["service"], "127.0.0.1:$port");
    expect(state["PoSeBanHeight"], -1);
    expect(
      (await bridge.protxList()).any((e) => e["proTxHash"] == proTxHash),
      isTrue,
    );
  }, skip: skip);

  test("the operator key moves the masternode to another server", () async {
    await send({
      "kind": "update_service",
      "pro_tx_hash": proTxHash,
      "service": "127.0.0.1:${port + 1}",
      "operator_secret": operator.secret,
      "utxos": [await fund(bip44(0, 2), 1)],
    });
    final state = (await bridge.protxInfo(proTxHash))["state"] as Map;
    expect(state["service"], "127.0.0.1:${port + 1}");
  }, skip: skip);

  test("a proposal paid with an OP_RETURN fee is submitted with our hash, "
      "and the masternode votes on it", () async {
    final payee = p2pkh(bip44(0, 3).publicKey);
    final now = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    final name = "astronaut-test-${Random().nextInt(1 << 30)}";
    final dataHex = kerriganProposalDataHex(
      type: KerriganProposalType.proposal,
      name: name,
      url: "https://kerrigan.network/proposal",
      paymentAddress: payee,
      amount: Amount.fromDecimal(
        Decimal.parse("12.5"),
        fractionDigits: coin.fractionDigits,
      ),
      startEpoch: now,
      endEpoch: now + 30 * 24 * 3600,
    );
    final hash = kerriganProposalHash(dataHex: dataHex, time: now);

    // The fee: 1 KRGN burnt in OP_RETURN <hash>, change back, as the
    // wallet's transparent send builds it.
    final coin2 = await fund(bip44(0, 4), 2);
    var tx = coinlib.Transaction(version: 2, inputs: [], outputs: [])
        .addInput(
          coinlib.P2PKHInput(
            prevOut: coinlib.OutPoint(
              Uint8List.fromList(
                (coin2["txid"] as String).toUint8ListFromHex.reversed.toList(),
              ),
              coin2["vout"] as int,
            ),
            publicKey: bip44(0, 4).publicKey,
          ),
        )
        .addOutput(
          coinlib.Output.fromScriptBytes(
            BigInt.from(kKerriganProposalFeeSats),
            kerriganOpReturnScript("$kKerriganOpReturnPrefix$hash"),
          ),
        )
        .addOutput(
          coinlib.Output.fromAddress(
            BigInt.from(coin2["amount"] as int) -
                BigInt.from(kKerriganProposalFeeSats) -
                BigInt.from(1000),
            coinlib.Address.fromString(p2pkh(bip44(1, 0).publicKey), params),
          ),
        );
    tx = tx.signLegacy(inputN: 0, key: bip44(0, 4).privateKey);
    final feeTxid = await bridge.sendTx(tx.toHex());
    await mine(kKerriganProposalFeeConfirmations);

    final submitted = await bridge.submitGovernanceObject(
      revision: 1,
      time: now,
      dataHex: dataHex,
      feeTxid: feeTxid,
    );
    expect(submitted, hash);
    final objects = await bridge.governanceObjects();
    expect(objects.containsKey(hash), isTrue);
    expect(
      (jsonDecode(objects[hash]!["DataString"] as String) as Map)["name"],
      name,
    );

    // Vote Yes with the voting key (a signed message on regtest).
    final time = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    final signature = KerriganShield.signMessage(
      privateKey: dip9(1, 0).privateKey.data,
      message: kerriganVoteMessage(
        collateralTxid: collateral["txid"] as String,
        collateralVout: collateral["vout"] as int,
        objectHash: hash,
        vote: KerriganVote.yes,
        time: time,
      ),
    );
    final answer = await bridge.voteRaw(
      collateralTxid: collateral["txid"] as String,
      collateralVout: collateral["vout"] as int,
      objectHash: hash,
      signal: "funding",
      outcome: "yes",
      time: time,
      signatureBase64: signature,
    );
    expect(answer, contains("Voted successfully"));

    final votes = await bridge.currentVotes(
      hash,
      txid: collateral["txid"] as String,
      vout: collateral["vout"] as int,
    );
    expect(votes.values.single, contains(":yes:funding"));
    final after = (await bridge.governanceObjects())[hash]!;
    expect(after["YesCount"], 1);
  }, skip: skip);

  test("the owner key gives the masternode a new operator", () async {
    final next = KerriganShield.blsKeygen(ikm: dip9(3, 1).privateKey.data);
    await send({
      "kind": "update_registrar",
      "pro_tx_hash": proTxHash,
      "operator_public_key": next.public,
      "voting_address": p2pkh(dip9(1, 0).publicKey),
      "payout_address": p2pkh(bip44(0, 0).publicKey),
      "owner_key": dip9(2, 0).privateKey.data.toHex,
      "utxos": [await fund(bip44(0, 5), 1)],
    });
    var state = (await bridge.protxInfo(proTxHash))["state"] as Map;
    expect(state["pubKeyOperator"], next.public);
    // A new operator must set the server again.
    expect(state["PoSeBanHeight"], greaterThan(0));

    await send({
      "kind": "update_service",
      "pro_tx_hash": proTxHash,
      "service": "127.0.0.1:${port + 2}",
      "operator_secret": next.secret,
      "utxos": [await fund(bip44(0, 6), 1)],
    });
    state = (await bridge.protxInfo(proTxHash))["state"] as Map;
    expect(state["service"], "127.0.0.1:${port + 2}");
    expect(state["PoSeBanHeight"], -1);
  }, skip: skip);
}
