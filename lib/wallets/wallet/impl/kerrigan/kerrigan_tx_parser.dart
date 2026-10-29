import 'dart:convert';
import 'dart:typed_data';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;

import '../../../../l10n/l10n.dart';
import '../../../../models/isar/models/blockchain_data/transaction_type.dart';
import '../../../../models/isar/models/blockchain_data/utxo.dart';
import '../../../../models/isar/models/blockchain_data/v2/input_v2.dart';
import '../../../../models/isar/models/blockchain_data/v2/output_v2.dart';
import '../../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../../utilities/amount/amount.dart';
import '../../../../utilities/extensions/extensions.dart';

/// How a Kerrigan transaction shows in the history: its direction, its Kerrigan
/// kind (see [KerriganTxKind]) and the amount worth showing.
typedef KerriganTxClass = ({TransactionType type, String? kind, BigInt amount});

/// [UTXO.otherData] key of an unconfirmed output locked by InstantSend:
/// final, so spendable like a confirmed one.
const kKerriganInstantLock = "instantLock";

bool isKerriganInstantLocked(UTXO utxo) =>
    utxo.otherData?.contains(kKerriganInstantLock) ?? false;

/// Classify a transaction from the wallet's point of view, like Kerrigan
/// Core's `TransactionRecord::decomposeTransaction`:
///
/// * coinbase outputs (mining or masternode payouts) show what they paid;
///   paying only [masternodePayouts], they are masternode rewards;
/// * coins we burnt in an OP_RETURN are a governance proposal fee;
/// * provider transactions ([txType] 1 to 4) register or update one of
///   our masternodes and show their fee;
/// * receiving shows what came in;
/// * sending shows what left the wallet (our inputs - fee - our outputs);
/// * sending to self shows what moved, without the change: shielding
///   (transparent -> own shield), unshielding (shield -> own transparent)
///   or a plain move.
///
/// The value balance decides "to self", not the output count: shield
/// bundles carry padding outputs nobody can decrypt.
///
/// Shield spends are inputs without an outpoint; shield notes are outputs
/// without a script. Outputs to one of [changeAddresses] are change.
KerriganTxClass? classifyKerriganTx({
  required List<InputV2> inputs,
  required List<OutputV2> outputs,
  Set<String> changeAddresses = const {},
  BigInt? fee,
  bool coinbase = false,
  int txType = 0,
  Set<String> masternodePayouts = const {},
}) {
  BigInt sum(Iterable<BigInt> v) => v.fold(BigInt.zero, (p, e) => p + e);
  bool isChange(OutputV2 o) =>
      o.walletOwns && o.addresses.any(changeAddresses.contains);

  final ownedInputs = inputs.where((e) => e.walletOwns).toList();
  final ownedOutputs = outputs.where((e) => e.walletOwns).toList();
  if (ownedInputs.isEmpty && ownedOutputs.isEmpty) return null;

  final ownedIn = sum(ownedInputs.map((e) => e.value));
  final ownedOut = sum(ownedOutputs.map((e) => e.value));

  if (coinbase && ownedOut > BigInt.zero) {
    final toMasternode =
        masternodePayouts.isNotEmpty &&
        ownedOutputs.every((o) => o.addresses.any(masternodePayouts.contains));
    return (
      type: TransactionType.incoming,
      kind: toMasternode
          ? KerriganTxKind.masternodeReward
          : KerriganTxKind.blockReward,
      amount: ownedOut,
    );
  }

  if (ownedIn == BigInt.zero) {
    return (type: TransactionType.incoming, kind: null, amount: ownedOut);
  }

  final burnt = sum(
    outputs
        .where((o) => o.scriptPubKeyHex.startsWith("6a"))
        .map((e) => e.value),
  );
  if (burnt > BigInt.zero) {
    return (
      type: TransactionType.outgoing,
      kind: KerriganTxKind.burn,
      amount: burnt,
    );
  }

  if (txType >= 1 && txType <= 4) {
    return (
      type: TransactionType.sentToSelf,
      kind: txType == 1
          ? KerriganTxKind.masternodeRegistration
          : KerriganTxKind.masternodeUpdate,
      amount: fee ?? BigInt.zero,
    );
  }

  // What left the wallet, fee excluded.
  final external = fee != null
      ? ownedIn - fee - ownedOut
      : sum(outputs.where((e) => !e.walletOwns).map((e) => e.value));
  final toSelf = external <= BigInt.zero;
  final type = toSelf ? TransactionType.sentToSelf : TransactionType.outgoing;

  if (!toSelf) {
    return (type: type, kind: null, amount: external);
  }

  /// Owned outputs that are not change, else all of them.
  BigInt moved(Iterable<OutputV2> outs) {
    final notChange = sum(outs.where((e) => !isChange(e)).map((e) => e.value));
    return notChange > BigInt.zero ? notChange : sum(outs.map((e) => e.value));
  }

  final shieldSpends = ownedInputs.where(
    (e) => e.outpoint == null && e.coinbase == null,
  );
  final notes = ownedOutputs.where((e) => e.scriptPubKeyHex.isEmpty);
  final transparent = ownedOutputs.where((e) => e.scriptPubKeyHex.isNotEmpty);

  if (shieldSpends.isEmpty && notes.isNotEmpty) {
    return (type: type, kind: KerriganTxKind.shield, amount: moved(notes));
  }
  if (shieldSpends.isNotEmpty && transparent.isNotEmpty) {
    return (
      type: type,
      kind: KerriganTxKind.unshield,
      amount: moved(transparent),
    );
  }
  return (type: type, kind: null, amount: moved(ownedOutputs));
}

/// otherData of a classified Kerrigan transaction.
Map<String, dynamic> kerriganTxOtherData({
  required KerriganTxClass c,
  required int fractionDigits,
  required Set<String> changeAddresses,
  BigInt? fee,
  String? memo,
  bool ownSend = false,
  bool instantLocked = false,
  String? rawTx,
}) => {
  if (memo != null && memo.isNotEmpty) TxV2OdKeys.onChainNote: memo,
  if (c.kind != null) TxV2OdKeys.kerriganKind: c.kind,
  if (instantLocked) TxV2OdKeys.instantLock: true,
  TxV2OdKeys.kerriganAmount: Amount(
    rawValue: c.amount,
    fractionDigits: fractionDigits,
  ).toJsonString(),
  if (changeAddresses.isNotEmpty)
    TxV2OdKeys.kerriganChange: changeAddresses.toList(),
  if (ownSend) TxV2OdKeys.kerriganOwnSend: true,
  TxV2OdKeys.kerriganRawTx: ?rawTx,
  // Rewards create coins: no fee. Always set otherwise, as the inputs
  // may not show the fee (shield spends, unknown inputs).
  TxV2OdKeys.overrideFee: Amount(
    rawValue: KerriganTxKind.rewards.contains(c.kind)
        ? BigInt.zero
        : (fee ?? BigInt.zero),
    fractionDigits: fractionDigits,
  ).toJsonString(),
};

/// The wallet's view of a bridge (Blockbook) transaction, with what the
/// shield scan knows about it ([shield]: `received` notes, our
/// `spentNullifiers`, `sent` notes recovered with our outgoing key).
///
/// Notes to the wallet's internal (change) key, or to a shield address
/// of ours never handed out ([shieldAddresses] are the handed-out ones),
/// are change. An unconfirmed transaction with `instantlock` is final.
/// Returns null for a transaction that doesn't touch the wallet.
TransactionV2? parseKerriganTx(
  Map<String, dynamic> json, {
  required String walletId,
  required int fractionDigits,
  required Set<String> receiving,
  required Set<String> change,
  required Set<String> shieldAddresses,
  Map<String, dynamic>? shield,
  Map<String, Map<String, dynamic>> nullifierNotes = const {},
  Set<String> masternodePayouts = const {},
}) {
  final all = {...receiving, ...change};
  final changeAddresses = <String>{};

  final inputs = <InputV2>[];
  for (final v in (json["vin"] as List? ?? const [])) {
    final vin = Map<String, dynamic>.from(v as Map);
    final addrs = List<String>.from(vin["addresses"] as List? ?? const []);
    final coinbase = vin["coinbase"] as String?;
    inputs.add(
      InputV2.isarCantDoRequiredInDefaultConstructor(
        scriptSigHex: null,
        scriptSigAsm: null,
        sequence: vin["sequence"] as int?,
        outpoint: coinbase != null
            ? null
            : OutpointV2.isarCantDoRequiredInDefaultConstructor(
                txid: vin["txid"] as String,
                vout: vin["vout"] as int,
              ),
        addresses: addrs,
        valueStringSats: vin["value"] as String? ?? "0",
        witness: null,
        innerRedeemScriptAsm: null,
        coinbase: coinbase,
        walletOwns: addrs.any(all.contains),
      ),
    );
  }

  // Shield notes this wallet spent (values from its nullifier map).
  for (final nf in (shield?["spentNullifiers"] as List?) ?? const []) {
    final note = nullifierNotes[nf];
    inputs.add(
      InputV2.isarCantDoRequiredInDefaultConstructor(
        scriptSigHex: null,
        scriptSigAsm: null,
        sequence: null,
        outpoint: null,
        addresses: [note?["address"] as String? ?? ""],
        valueStringSats: "${note?["value"] ?? 0}",
        witness: null,
        innerRedeemScriptAsm: null,
        coinbase: null,
        walletOwns: true,
      ),
    );
  }

  final outputs = <OutputV2>[];
  for (final v in (json["vout"] as List? ?? const [])) {
    final vout = Map<String, dynamic>.from(v as Map);
    final addrs = List<String>.from(vout["addresses"] as List? ?? const []);
    final owns = addrs.any(all.contains);
    if (owns) changeAddresses.addAll(addrs.where(change.contains));
    outputs.add(
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: vout["hex"] as String? ?? "",
        valueStringSats: BigInt.parse(vout["value"] as String? ?? "0")
            .toString(),
        addresses: addrs,
        walletOwns: owns,
      ),
    );
  }

  // Shield notes this wallet received.
  final receivedNotes = (shield?["received"] as List?) ?? const [];
  for (final n in receivedNotes) {
    final address = (n as Map)["address"] as String;
    if (n["change"] == true || !shieldAddresses.contains(address)) {
      changeAddresses.add(address);
    }
    outputs.add(
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: "",
        valueStringSats: "${(n["value"] as num).toInt()}",
        addresses: [address],
        walletOwns: true,
      ),
    );
  }

  // Shield outputs this wallet sent to someone else.
  final sentNotes = (shield?["sent"] as List?) ?? const [];
  for (final n in sentNotes) {
    outputs.add(
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: "",
        valueStringSats: "${((n as Map)["value"] as num).toInt()}",
        addresses: [n["address"] as String],
        walletOwns: false,
      ),
    );
  }

  final fee = json["fees"] == null
      ? null
      : BigInt.parse(json["fees"] as String);
  final height = json["blockHeight"] as int? ?? -1;
  final c = classifyKerriganTx(
    inputs: inputs,
    outputs: outputs,
    changeAddresses: changeAddresses,
    fee: fee,
    coinbase: json["coinbase"] == true,
    txType: json["type"] as int? ?? 0,
    masternodePayouts: masternodePayouts,
  );
  if (c == null) return null;

  // Text memos of the shield notes received or sent (the shielded memo).
  final memo = [
    for (final n in [...sentNotes, ...receivedNotes])
      if (((n as Map)["memo"] as String?)?.trim().isNotEmpty ?? false)
        (n["memo"] as String).trim(),
  ].join("\n");

  final txid = json["txid"] as String;
  return TransactionV2(
    walletId: walletId,
    blockHash: json["blockHash"] as String?,
    hash: txid,
    txid: txid,
    height: height > 0 ? height : null,
    version: json["version"] as int? ?? 1,
    timestamp:
        (json["blockTime"] as int?) ??
        DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
    inputs: List.unmodifiable(inputs),
    outputs: List.unmodifiable(outputs),
    type: c.type,
    subType: TransactionSubType.none,
    otherData: jsonEncode(
      kerriganTxOtherData(
        c: c,
        fractionDigits: fractionDigits,
        changeAddresses: changeAddresses,
        fee: fee,
        memo: memo,
        instantLocked: height <= 0 && json["instantlock"] == true,
      ),
    ),
  );
}

/// One output of a raw transaction: its value and script.
typedef KerriganRawOutput = ({BigInt value, Uint8List script});

/// Reads a raw Kerrigan transaction from the start: nVersion and nType
/// (16 bits each), inputs, outputs, nLockTime, then for a special
/// transaction (nVersion 3 and up, nType not 0) its extra payload, which
/// for a Sapling transaction (nType 10) is the Sapling bundle.
class _KerriganRawTxReader {
  _KerriganRawTxReader(this.raw) : view = ByteData.sublistView(raw);

  final Uint8List raw;
  final ByteData view;
  int pos = 0;

  Uint8List take(int length) {
    if (length < 0 || pos + length > raw.length) {
      throw const FormatException("Truncated transaction");
    }
    return Uint8List.sublistView(raw, pos, pos += length);
  }

  int varint() {
    final first = take(1)[0];
    if (first < 0xfd) return first;
    final bytes = ByteData.sublistView(
      take(first == 0xfd ? 2 : (first == 0xfe ? 4 : 8)),
    );
    return switch (first) {
      0xfd => bytes.getUint16(0, Endian.little),
      0xfe => bytes.getUint32(0, Endian.little),
      _ => bytes.getUint64(0, Endian.little),
    };
  }

  /// Reads up to and including the outputs.
  List<KerriganRawOutput> outputs() {
    pos = 4; // nVersion + nType
    final inputs = varint();
    for (int i = 0; i < inputs; i++) {
      take(36); // prevout
      take(varint()); // scriptSig
      take(4); // nSequence
    }
    final count = varint();
    return [
      for (int i = 0; i < count; i++)
        (
          value: BigInt.from(
            ByteData.sublistView(take(8)).getInt64(0, Endian.little),
          ),
          script: Uint8List.fromList(take(varint())),
        ),
    ];
  }
}

/// Outputs of a raw Kerrigan transaction (any version: outputs come before
/// the extra payload).
List<KerriganRawOutput> kerriganTxOutputs(Uint8List raw) =>
    _KerriganRawTxReader(raw).outputs();

/// The Sapling parts of a transaction a shield scan sees: the nullifiers
/// its spends reveal and the note commitments (cmu) of its outputs, both
/// as hex of the wire bytes, in order.
typedef KerriganShieldParts = ({
  List<String> nullifiers,
  List<String> commitments,
});

/// [KerriganShieldParts] of a raw Kerrigan transaction; empty lists when
/// it isn't a Sapling transaction.
KerriganShieldParts kerriganTxShieldParts(Uint8List raw) {
  const none = (nullifiers: <String>[], commitments: <String>[]);
  final tx = _KerriganRawTxReader(raw);
  final version = tx.view.getInt16(0, Endian.little);
  final type = tx.view.getUint16(2, Endian.little);
  if (version < 3 || type != 10) return none;
  tx.outputs();
  tx.take(4); // nLockTime
  final payloadLength = tx.varint();
  final payloadEnd = tx.pos + payloadLength;
  tx.take(2); // Sapling payload version
  // Spend: cv, anchor, nullifier, rk (32 each), proof 192, signature 64.
  final spends = tx.varint();
  final nullifiers = [
    for (int i = 0; i < spends; i++)
      Uint8List.sublistView(tx.take(384), 64, 96).toHex,
  ];
  // Output: cv, cmu, epk (32 each), enc 580, out 80, proof 192.
  final outputs = tx.varint();
  final commitments = [
    for (int i = 0; i < outputs; i++)
      Uint8List.sublistView(tx.take(948), 32, 64).toHex,
  ];
  tx.take(8 + 64); // valueBalance, bindingSig
  if (tx.pos != payloadEnd) {
    throw const FormatException("Malformed Sapling payload");
  }
  return (nullifiers: nullifiers, commitments: commitments);
}

/// Parse [rawHex] after checking that it hashes to [txid]. Throws when it
/// does not.
T _kerriganVerified<T>(
  String txid,
  String rawHex,
  T Function(Uint8List) parse,
) {
  final raw = rawHex.toUint8ListFromHex;
  final id = Uint8List.fromList(coinlib.sha256DoubleHash(raw).reversed.toList())
      .toHex;
  if (id != txid) {
    throw Exception(l10n.txWrongFromServer(txid));
  }
  return parse(raw);
}

/// Outputs of the raw transaction [rawHex], after checking that it
/// hashes to [txid]. Throws when it does not.
List<KerriganRawOutput> kerriganVerifiedOutputs(String txid, String rawHex) =>
    _kerriganVerified(txid, rawHex, kerriganTxOutputs);

/// [KerriganShieldParts] of the raw transaction [rawHex], after checking
/// that it hashes to [txid]. Throws when it does not.
KerriganShieldParts kerriganVerifiedShieldParts(String txid, String rawHex) =>
    _kerriganVerified(txid, rawHex, kerriganTxShieldParts);
