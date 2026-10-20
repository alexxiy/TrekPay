import 'dart:convert';
import 'dart:math';

import 'package:isar_community/isar.dart';

import '../../../../../utilities/amount/amount.dart';
import '../transaction_type.dart';
import 'input_v2.dart';
import 'output_v2.dart';

part 'transaction_v2.g.dart';

@Collection()
class TransactionV2 {
  Id id = Isar.autoIncrement;

  @Index()
  // History lists page through a wallet's txs newest first.
  @Index(name: "walletId_timestamp", composite: [CompositeIndex("timestamp")])
  final String walletId;

  @Index(unique: true, composite: [CompositeIndex("walletId")])
  final String txid;

  final String hash;

  @Index()
  late final int timestamp;

  final int? height;
  final String? blockHash;
  final int version;

  final List<InputV2> inputs;
  final List<OutputV2> outputs;

  @enumerated
  final TransactionType type;

  @enumerated
  final TransactionSubType subType;

  final String? otherData;

  TransactionV2({
    required this.walletId,
    required this.blockHash,
    required this.hash,
    required this.txid,
    required this.timestamp,
    required this.height,
    required this.inputs,
    required this.outputs,
    required this.version,
    required this.type,
    required this.subType,
    required this.otherData,
  });

  TransactionV2 copyWith({
    String? walletId,
    String? txid,
    String? hash,
    int? timestamp,
    int? height,
    String? blockHash,
    int? version,
    List<InputV2>? inputs,
    List<OutputV2>? outputs,
    TransactionType? type,
    TransactionSubType? subType,
    String? otherData,
  }) {
    return TransactionV2(
      walletId: walletId ?? this.walletId,
      txid: txid ?? this.txid,
      hash: hash ?? this.hash,
      timestamp: timestamp ?? this.timestamp,
      height: height ?? this.height,
      blockHash: blockHash ?? this.blockHash,
      version: version ?? this.version,
      inputs: inputs ?? this.inputs,
      outputs: outputs ?? this.outputs,
      type: type ?? this.type,
      subType: subType ?? this.subType,
      otherData: otherData ?? this.otherData,
    );
  }

  @ignore
  String? get memo => _getFromOtherData(key: TxV2OdKeys.memo) as String?;

  @ignore
  int? get size => _getFromOtherData(key: TxV2OdKeys.size) as int?;

  @ignore
  int? get vSize => _getFromOtherData(key: TxV2OdKeys.vSize) as int?;

  @ignore
  String? get onChainNote =>
      _getFromOtherData(key: TxV2OdKeys.onChainNote) as String?;

  int getConfirmations(int currentChainHeight) {
    if (height == null || height! <= 0) return 0;
    return max(0, currentChainHeight - (height! - 1));
  }

  bool isConfirmed(
    int currentChainHeight,
    int minimumConfirms,
    int minimumCoinbaseConfirms,
  ) {
    // Kerrigan: an InstantSend lock makes an unconfirmed tx final.
    if (isInstantLocked && (height == null || height! <= 0)) return true;
    final confirmations = getConfirmations(currentChainHeight);
    return confirmations >=
        (isCoinbase() ? minimumCoinbaseConfirms : minimumConfirms);
  }

  Amount getFee({required int fractionDigits}) {
    // check for override fee
    final fee = _getOverrideFee();
    if (fee != null) {
      return fee;
    }

    if (isCoinbase()) {
      return Amount.zeroWith(fractionDigits: fractionDigits);
    }

    final inSum = inputs
        .map((e) => e.value)
        .reduce((value, element) => value += element);
    final outSum = outputs
        .map((e) => e.value)
        .reduce((value, element) => value += element);

    return Amount(rawValue: inSum - outSum, fractionDigits: fractionDigits);
  }

  Amount getAmountReceivedInThisWallet({required int fractionDigits}) {
    final kerriganAmount = _getKerriganAmount();
    if (kerriganAmount != null) return kerriganAmount;

    final outSum = outputs
        .where((e) => e.walletOwns)
        .fold(BigInt.zero, (p, e) => p + e.value);

    return Amount(rawValue: outSum, fractionDigits: fractionDigits);
  }

  Amount getAmountSentFromThisWallet({
    required int fractionDigits,
    required bool subtractFee,
  }) {
    final kerriganAmount = _getKerriganAmount();
    if (kerriganAmount != null) return kerriganAmount;

    final inSum = inputs
        .where((e) => e.walletOwns)
        .fold(BigInt.zero, (p, e) => p + e.value);

    Amount amount =
        Amount(rawValue: inSum, fractionDigits: fractionDigits) -
        getAmountReceivedInThisWallet(fractionDigits: fractionDigits);

    if (subtractFee) {
      amount = amount - getFee(fractionDigits: fractionDigits);
    }

    // negative amounts are likely an error or can happen with coins such as eth
    // that don't use the btc style inputs/outputs
    if (amount.raw < BigInt.zero) {
      return Amount.zeroWith(fractionDigits: fractionDigits);
    }

    return amount;
  }

  Set<String> associatedAddresses() => {
    ...inputs.map((e) => e.addresses).expand((e) => e),
    ...outputs.map((e) => e.addresses).expand((e) => e),
  };

  @ignore
  String? get kerriganKind =>
      _getFromOtherData(key: TxV2OdKeys.kerriganKind) as String?;

  /// Kerrigan: unconfirmed, but locked by InstantSend (final).
  @ignore
  bool get isInstantLocked =>
      _getFromOtherData(key: TxV2OdKeys.instantLock) == true;

  /// Kerrigan change addresses among the outputs.
  @ignore
  Set<String> get kerriganChangeAddresses => {
    ...((_getFromOtherData(key: TxV2OdKeys.kerriganChange) as List?) ??
            const [])
        .cast<String>(),
  };

  @ignore
  bool get isKerriganOwnSend =>
      _getFromOtherData(key: TxV2OdKeys.kerriganOwnSend) == true;

  /// Raw hex of an unconfirmed transaction this wallet sent.
  @ignore
  String? get kerriganRawTx =>
      _getFromOtherData(key: TxV2OdKeys.kerriganRawTx) as String?;

  Amount? _getKerriganAmount() {
    try {
      return Amount.fromSerializedJsonString(
        _getFromOtherData(key: TxV2OdKeys.kerriganAmount) as String,
      );
    } catch (_) {
      return null;
    }
  }

  Amount? _getOverrideFee() {
    try {
      return Amount.fromSerializedJsonString(
        _getFromOtherData(key: TxV2OdKeys.overrideFee) as String,
      );
    } catch (_) {
      return null;
    }
  }

  String statusLabel({
    required int currentChainHeight,
    required int minConfirms,
    required int minCoinbaseConfirms,
  }) {
    String prettyConfirms() =>
        "("
        "${getConfirmations(currentChainHeight)}"
        "/"
        "${(isCoinbase() ? minCoinbaseConfirms : minConfirms)}"
        ")";

    final kerriganLabel = _kerriganStatusLabel(
      confirmed: isConfirmed(
        currentChainHeight,
        minConfirms,
        minCoinbaseConfirms,
      ),
      confirms: prettyConfirms(),
    );
    if (kerriganLabel != null) return kerriganLabel;

    if (type == TransactionType.incoming) {
      if (isConfirmed(currentChainHeight, minConfirms, minCoinbaseConfirms)) {
        return "Received";
      } else {
        return "Receiving ${prettyConfirms()}";
      }
    } else if (type == TransactionType.outgoing) {
      if (isConfirmed(currentChainHeight, minConfirms, minCoinbaseConfirms)) {
        return "Sent";
      } else {
        return "Sending ${prettyConfirms()}";
      }
    } else if (type == TransactionType.sentToSelf) {
      if (isConfirmed(currentChainHeight, minConfirms, minCoinbaseConfirms)) {
        return "Sent to self";
      } else {
        return "Sent to self ${prettyConfirms()}";
      }
    } else {
      return type.name;
    }
  }

  String? _kerriganStatusLabel({
    required bool confirmed,
    required String confirms,
  }) {
    String label(String done, String pending) =>
        confirmed ? done : "$pending $confirms";
    switch (kerriganKind) {
      case KerriganTxKind.blockReward:
        return label("Block reward", "Block reward");
      case KerriganTxKind.masternodeReward:
        return label("Masternode reward", "Masternode reward");
      case KerriganTxKind.burn:
        return label("Proposal fee", "Proposal fee");
      case KerriganTxKind.masternodeRegistration:
        return label("Masternode registered", "Registering masternode");
      case KerriganTxKind.masternodeUpdate:
        return label("Masternode updated", "Updating masternode");
      case KerriganTxKind.shield:
        return label("Shielded", "Shielding");
      case KerriganTxKind.unshield:
        return label("Unshielded", "Unshielding");
      default:
        return null;
    }
  }

  /// [otherData] decoded once: list cards read several keys per build.
  @ignore
  late final Map<dynamic, dynamic>? _otherDataMap = otherData == null
      ? null
      : jsonDecode(otherData!) as Map<dynamic, dynamic>?;

  dynamic _getFromOtherData({required dynamic key}) => _otherDataMap?[key];

  bool isCoinbase() =>
      (type == TransactionType.incoming &&
          inputs.any((e) => e.coinbase != null)) ||
      KerriganTxKind.rewards.contains(kerriganKind);

  @override
  String toString() {
    return 'TransactionV2(\n'
        '  walletId: $walletId,\n'
        '  hash: $hash,\n'
        '  txid: $txid,\n'
        '  type: $type,\n'
        '  subType: $subType,\n'
        '  timestamp: $timestamp,\n'
        '  height: $height,\n'
        '  blockHash: $blockHash,\n'
        '  version: $version,\n'
        '  inputs: $inputs,\n'
        '  outputs: $outputs,\n'
        '  otherData: $otherData,\n'
        ')';
  }
}

abstract final class TxV2OdKeys {
  static const size = "size";
  static const vSize = "vSize";
  static const onChainNote = "onChainNote";
  static const overrideFee = "overrideFee";
  static const memo = "onChainMemo";

  /// Kerrigan transaction kind, see [KerriganTxKind].
  static const kerriganKind = "kerriganKind";

  /// Kerrigan: amount to show instead of one derived from the outputs
  /// (the value shielded or unshielded, without the change).
  static const kerriganAmount = "kerriganAmount";

  /// Kerrigan: change addresses among the outputs (list of strings).
  static const kerriganChange = "kerriganChange";

  /// Kerrigan: built and sent by this wallet; its amount and change are
  /// exact, unlike what a rescan can infer.
  static const kerriganOwnSend = "kerriganOwnSend";

  /// Kerrigan: unconfirmed but locked by InstantSend, so final.
  static const instantLock = "instantLock";

  /// Kerrigan: raw hex of a transaction this wallet sent, kept while it
  /// is unconfirmed to send it again if the network loses it.
  static const kerriganRawTx = "kerriganRawTx";
}

/// Kinds of Kerrigan transactions shown with their own label.
abstract final class KerriganTxKind {
  /// A coinbase output: a mining payout.
  static const blockReward = "blockReward";

  /// A coinbase output paying one of the wallet's masternodes.
  static const masternodeReward = "masternodeReward";

  /// Coins burnt in an OP_RETURN output: a governance proposal fee.
  static const burn = "burn";

  /// Provider transactions: a masternode registration (ProRegTx), or an
  /// update of its server, keys or payout (ProUpServTx, ProUpRegTx,
  /// ProUpRevTx).
  static const masternodeRegistration = "masternodeRegistration";
  static const masternodeUpdate = "masternodeUpdate";

  static const shield = "shield";
  static const unshield = "unshield";

  /// Bundled history icon of [kind], or null for a plain send/receive.
  static String? iconAsset(String? kind, {required bool pending}) {
    final name = switch (kind) {
      blockReward => "stake-reward",
      masternodeReward => "masternode-reward",
      burn => "burn",
      shield => "shield",
      unshield => "unshield",
      _ => null,
    };
    if (name == null) return null;
    return "assets/svg/tx-icon-pivx-$name${pending ? "-pending" : ""}.svg";
  }

  /// Kinds that mint new coins: immature until coinbase maturity.
  static const rewards = {blockReward, masternodeReward};
}
