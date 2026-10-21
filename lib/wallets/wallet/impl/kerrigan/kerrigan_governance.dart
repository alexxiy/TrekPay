part of '../kerrigan_wallet.dart';

/// Burnt by a governance object's fee transaction
/// (`GOVERNANCE_PROPOSAL_FEE_TX`).
const kKerriganProposalFeeSats = 100000000;

/// Confirmations the fee needs before the object is accepted
/// (`GOVERNANCE_FEE_CONFIRMATIONS`).
const kKerriganProposalFeeConfirmations = 6;

/// A masternode may change its vote on an object once an hour
/// (`GOVERNANCE_UPDATE_MIN`).
const kKerriganVoteUpdateMinSeconds = 60 * 60;

/// Core's limits (`MAX_NAME_SIZE`, the longest proposal life).
const kKerriganProposalNameMax = 40;
const kKerriganProposalMaxSeconds = 365 * 24 * 60 * 60;

/// Characters Core takes in a name (it compares them lower-cased).
final _kProposalName = RegExp(r"^[-_a-zA-Z0-9]+$");

/// Governance object types (Kerrigan Core `GovernanceObject`).
enum KerriganProposalType {
  /// A proposal: masternodes vote on a payment or decision.
  proposal(1, "Proposal"),

  /// A growth fund release: passing it lets the escrowed growth fund pay
  /// its amount to its address.
  escrowRelease(3, "Growth fund release");

  const KerriganProposalType(this.code, this.label);

  final int code;
  final String label;

  static KerriganProposalType? of(int code) =>
      values.where((e) => e.code == code).firstOrNull;
}

/// A masternode's vote (`vote_outcome_enum_t`).
enum KerriganVote {
  yes(1, "Yes"),
  no(2, "No"),
  abstain(3, "Abstain");

  const KerriganVote(this.code, this.label);

  final int code;
  final String label;

  static KerriganVote? parse(String s) =>
      values.where((e) => e.name == s.trim().toLowerCase()).firstOrNull;
}

enum KerriganProposalStatus {
  /// Enough net Yes votes now.
  passing("Passing"),

  /// Too few net Yes votes.
  notPassing("Not passing"),

  /// Its time is over.
  ended("Ended"),

  /// The network rejects it (e.g. a bad fee or data).
  invalid("Invalid");

  const KerriganProposalStatus(this.label);

  final String label;
}

/// A governance object on the network (`gobject list`).
class KerriganProposal {
  KerriganProposal._({
    required this.hash,
    required this.feeHash,
    required this.type,
    required this.name,
    required this.url,
    required this.paymentAddress,
    required this.paymentAmount,
    required this.startEpoch,
    required this.endEpoch,
    required this.createdAt,
    required this.absoluteYes,
    required this.yeas,
    required this.nays,
    required this.abstains,
    required this.isValid,
    required this.invalidReason,
  });

  final String hash;
  final String feeHash;
  final KerriganProposalType type;
  final String name;
  final String url;
  final String paymentAddress;
  final Amount paymentAmount;

  /// Unix seconds; null for growth fund releases (no voting window).
  final int? startEpoch;
  final int? endEpoch;
  final int createdAt;

  /// Weighted Yes minus No (a BroodNode's vote counts four times).
  final int absoluteYes;
  final int yeas;
  final int nays;
  final int abstains;
  final bool isValid;
  final String? invalidReason;

  bool get isOver =>
      endEpoch != null &&
      endEpoch! < DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;

  KerriganProposalStatus statusFor(int threshold) => !isValid
      ? KerriganProposalStatus.invalid
      : isOver
      ? KerriganProposalStatus.ended
      // Core's fCachedFunding lags votes by minutes: count them here.
      : absoluteYes >= threshold
      ? KerriganProposalStatus.passing
      : KerriganProposalStatus.notPassing;

  static KerriganProposal? _fromJson(
    Map<String, dynamic> json, {
    required int fractionDigits,
  }) {
    final type = KerriganProposalType.of(
      (json["ObjectType"] as num?)?.toInt() ?? 0,
    );
    if (type == null) return null;
    Map<String, dynamic> data;
    try {
      data = Map<String, dynamic>.from(
        jsonDecode(json["DataString"] as String) as Map,
      );
    } catch (_) {
      return null;
    }
    final amount = Decimal.tryParse("${data["payment_amount"] ?? 0}");
    int? epoch(String key) => (data[key] as num?)?.toInt();
    final reason = (json["IsValidReason"] as String?)?.trim() ?? "";
    return KerriganProposal._(
      hash: json["Hash"] as String,
      feeHash: json["CollateralHash"] as String? ?? "",
      type: type,
      name: "${data["name"] ?? ""}",
      url: "${data["url"] ?? ""}",
      paymentAddress: "${data["payment_address"] ?? ""}",
      paymentAmount: (amount ?? Decimal.zero).toAmount(
        fractionDigits: fractionDigits,
      ),
      startEpoch: epoch("start_epoch"),
      endEpoch: epoch("end_epoch"),
      createdAt: (json["CreationTime"] as num?)?.toInt() ?? 0,
      absoluteYes: (json["AbsoluteYesCount"] as num?)?.toInt() ?? 0,
      yeas: (json["YesCount"] as num?)?.toInt() ?? 0,
      nays: (json["NoCount"] as num?)?.toInt() ?? 0,
      abstains: (json["AbstainCount"] as num?)?.toInt() ?? 0,
      isValid: json["fBlockchainValidity"] != false,
      invalidReason: reason.isEmpty ? null : reason,
    );
  }
}

/// The network's governance as seen now.
class KerriganGovernance {
  KerriganGovernance({
    required this.proposals,
    required this.pending,
    required this.threshold,
    required this.enabledMasternodes,
  });

  /// Newest first.
  final List<KerriganProposal> proposals;

  /// This wallet's proposals not on the network yet (fee confirming).
  final List<KerriganPendingProposal> pending;

  /// Net (weighted) Yes votes an object needs to pass: a tenth of the
  /// masternodes' voting weight, at least the minimum quorum.
  final int threshold;

  final int enabledMasternodes;

  KerriganProposalStatus statusOf(KerriganProposal p) => p.statusFor(threshold);
}

/// A proposal this wallet paid the fee for, submitted once the fee has
/// [kKerriganProposalFeeConfirmations] confirmations.
class KerriganPendingProposal {
  KerriganPendingProposal({
    required this.type,
    required this.name,
    required this.dataHex,
    required this.time,
    required this.hash,
    required this.feeTxid,
    this.error,
  });

  final KerriganProposalType type;
  final String name;

  /// The object's data (its JSON, hex) and creation time: with the fee
  /// they make the object submitted.
  final String dataHex;
  final int time;
  final String hash;
  final String feeTxid;

  /// Why submitting failed for good (the fee is lost), if it did.
  final String? error;

  Map<String, dynamic> get data => Map<String, dynamic>.from(
    jsonDecode(utf8.decode(dataHex.toUint8ListFromHex)) as Map,
  );

  KerriganPendingProposal copyWith({String? feeTxid, String? error}) =>
      KerriganPendingProposal(
        type: type,
        name: name,
        dataHex: dataHex,
        time: time,
        hash: hash,
        feeTxid: feeTxid ?? this.feeTxid,
        error: error ?? this.error,
      );

  Map<String, dynamic> toJson() => {
    "type": type.code,
    "name": name,
    "dataHex": dataHex,
    "time": time,
    "hash": hash,
    "feeTxid": feeTxid,
    if (error != null) "error": error,
  };

  factory KerriganPendingProposal.fromJson(Map<String, dynamic> json) =>
      KerriganPendingProposal(
        type: KerriganProposalType.of(json["type"] as int)!,
        name: json["name"] as String,
        dataHex: json["dataHex"] as String,
        time: json["time"] as int,
        hash: json["hash"] as String,
        feeTxid: json["feeTxid"] as String,
        error: json["error"] as String?,
      );
}

/// A vote one of this wallet's masternodes cast.
class KerriganMasternodeVote {
  KerriganMasternodeVote({required this.vote, required this.time});

  final KerriganVote vote;

  /// Unix seconds.
  final int time;

  /// When the vote may be changed (Core rejects earlier updates).
  DateTime get changeableAt => DateTime.fromMillisecondsSinceEpoch(
    (time + kKerriganVoteUpdateMinSeconds) * 1000,
  );

  bool get canChange => DateTime.now().isAfter(changeableAt);
}

/// Most masternodes whose votes on a proposal are asked for one by one
/// (a node call each); more get every masternode's votes in one call.
const kKerriganVotesOneByOneMax = 10;

/// The latest funding vote of each of [masternodes] among [votes]
/// (`gobject getcurrentvotes` values, "txid-vout:time:outcome:signal:
/// weight"), by masternode id.
Map<String, KerriganMasternodeVote> kerriganOwnVotes(
  Iterable<String> votes,
  Iterable<KerriganMasternode> masternodes,
) {
  final ids = {for (final m in masternodes) "${m.txid}-${m.vout}": m.id};
  final result = <String, KerriganMasternodeVote>{};
  for (final v in votes) {
    final parts = v.split(":");
    if (parts.length < 4 || parts[3] != "funding") continue;
    final id = ids[parts[0]];
    final vote = KerriganVote.parse(parts[2]);
    final time = int.tryParse(parts[1]);
    if (id == null || vote == null || time == null) continue;
    final current = result[id];
    if (current == null || current.time < time) {
      result[id] = KerriganMasternodeVote(vote: vote, time: time);
    }
  }
  return result;
}

/// A governance object's data: its JSON, hex encoded (`data-hex`).
String kerriganProposalDataHex({
  required KerriganProposalType type,
  required String name,
  required String url,
  required String paymentAddress,
  required Amount amount,
  int? startEpoch,
  int? endEpoch,
}) {
  final data = <String, Object>{
    "end_epoch": ?endEpoch,
    "name": name,
    "payment_address": paymentAddress,
    "payment_amount": num.parse(amount.decimal.toString()),
    "start_epoch": ?startEpoch,
    "type": type.code,
    "url": url,
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(data))).toHex;
}

/// A governance object's hash (display hex), as Kerrigan Core's
/// `Governance::Object::GetHash`: sha256d of the parent hash (none), the
/// revision, the time, the data hex as a string, an empty masternode
/// outpoint (serialized like an input) and an empty signature.
String kerriganProposalHash({
  required String dataHex,
  required int time,
  int revision = 1,
}) {
  final w = BytesBuilder()
    ..add(Uint8List(32)) // hashParent
    ..add(_le(revision, 4))
    ..add(_le(time, 8));
  final hex = utf8.encode(dataHex);
  w
    ..add(_compactSize(hex.length))
    ..add(hex)
    // masternodeOutpoint: null hash, index -1; then the old CTxIn tail.
    ..add(Uint8List(32))
    ..add(_le(0xffffffff, 4))
    ..addByte(0)
    ..add(_le(0xffffffff, 4))
    ..addByte(0); // vchSig
  return Uint8List.fromList(
    coinlib.sha256DoubleHash(w.toBytes()).reversed.toList(),
  ).toHex;
}

/// The message a voting key signs (`CGovernanceVote::GetSignatureString`).
String kerriganVoteMessage({
  required String collateralTxid,
  required int collateralVout,
  required String objectHash,
  required KerriganVote vote,
  required int time,
}) => "$collateralTxid-$collateralVout|$objectHash|1|${vote.code}|$time";

/// The hash a voting key signs on testnet
/// (`CGovernanceVote::GetSignatureHash`), internal byte order.
Uint8List kerriganVoteHash({
  required String collateralTxid,
  required int collateralVout,
  required String objectHash,
  required KerriganVote vote,
  required int time,
}) {
  final w = BytesBuilder()
    ..add(collateralTxid.toUint8ListFromHex.reversed.toList())
    ..add(_le(collateralVout, 4))
    ..add(objectHash.toUint8ListFromHex.reversed.toList())
    ..add(_le(vote.code, 4))
    ..add(_le(1, 4)) // VOTE_SIGNAL_FUNDING
    ..add(_le(time, 8));
  return coinlib.sha256DoubleHash(w.toBytes());
}

Uint8List _le(int value, int bytes) {
  final out = Uint8List(bytes);
  var v = value;
  for (int i = 0; i < bytes; i++) {
    out[i] = v & 0xff;
    v >>= 8;
  }
  return out;
}

Uint8List _compactSize(int n) => n < 0xfd
    ? Uint8List.fromList([n])
    : n <= 0xffff
    ? Uint8List.fromList([0xfd, ..._le(n, 2)])
    : Uint8List.fromList([0xfe, ..._le(n, 4)]);

const _kPendingProposals = "kerriganPendingProposals";

/// Per wallet: the [KerriganGovernanceWallet.submitPendingProposals]
/// running, which a sync finishing meanwhile joins instead of submitting
/// again.
final _submittingProposals = <String, Future<void>>{};

extension KerriganGovernanceWallet on KerriganWallet {
  /// Transparent addresses of this wallet (receiving first), e.g. to
  /// receive a proposal's payment.
  Future<List<Address>> ownTransparentAddresses() => mainDB
      .getAddresses(walletId)
      .filter()
      .group(
        (q) => q
            .subTypeEqualTo(AddressSubType.receiving)
            .or()
            .subTypeEqualTo(AddressSubType.change),
      )
      .and()
      .typeEqualTo(AddressType.p2pkh)
      .sortBySubType()
      .thenByDerivationIndex()
      .findAll();

  /// A receiving address never handed out before.
  Future<String> newReceivingAddress() async {
    await generateNewReceivingAddress();
    return (await getCurrentReceivingAddress())!.value;
  }

  // ---------------------------------------------------------------------------
  // Reading

  List<KerriganPendingProposal> get pendingProposals =>
      _pendingIn(info.otherData);

  List<KerriganPendingProposal> _pendingIn(Map<String, dynamic> otherData) => [
    for (final e in (otherData[_kPendingProposals] as List?) ?? const [])
      KerriganPendingProposal.fromJson(Map<String, dynamic>.from(e as Map)),
  ];

  /// Rewrite the stored list, not this wallet's possibly older copy of it.
  Future<void> _updatePending(
    List<KerriganPendingProposal> Function(List<KerriganPendingProposal> stored)
    change,
  ) => info.updateOtherDataWith(
    isar: mainDB.isar,
    change: (stored) => {
      _kPendingProposals: [
        for (final p in change(_pendingIn(stored))) p.toJson(),
      ],
    },
  );

  /// Proposals and growth fund releases with their votes, from the
  /// bridge's node.
  Future<KerriganGovernance> loadGovernance() async {
    final results = await Future.wait([
      bridge.governanceObjects(),
      bridge.governanceInfo(),
      bridge.masternodeCount(),
    ]);
    final objects = results[0] as Map<String, Map<String, dynamic>>;
    final govInfo = results[1];
    final count = results[2];
    final proposals = [
      for (final o in objects.values)
        ?KerriganProposal._fromJson(
          o,
          fractionDigits: cryptoCurrency.fractionDigits,
        ),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return KerriganGovernance(
      proposals: proposals,
      pending: [
        for (final p in pendingProposals)
          if (!objects.containsKey(p.hash)) p,
      ],
      threshold: (govInfo["fundingthreshold"] as num?)?.toInt() ?? 1,
      enabledMasternodes: (count["enabled"] as num?)?.toInt() ?? 0,
    );
  }

  /// The current votes of this wallet's masternodes on [proposal], by
  /// masternode id ([KerriganMasternode.id]).
  ///
  /// A few masternodes are asked about one by one; past
  /// [kKerriganVotesOneByOneMax], one request brings every masternode's
  /// votes on [proposal] (one or two each) and ours are picked.
  Future<Map<String, KerriganMasternodeVote>> masternodeVotes(
    KerriganProposal proposal,
  ) async {
    final mine = masternodes.where((m) => m.isRegistered).toList();
    if (mine.isEmpty) return const {};
    final votes = <String>[
      if (mine.length > kKerriganVotesOneByOneMax)
        ...(await bridge.currentVotes(proposal.hash)).values
      else
        for (final m in mine)
          ...(await bridge.currentVotes(
            proposal.hash,
            txid: m.txid,
            vout: m.vout,
          )).values,
    ];
    return kerriganOwnVotes(votes, mine);
  }

  /// Why [mn] can't vote, or null when it can.
  String? votingProblem(KerriganMasternode mn) {
    if (!mn.isRegistered) return "Not registered";
    if (mn.keyIndex == null) return "Its voting key isn't in this wallet";
    return null;
  }

  /// Vote [vote] on [proposal] with [mn]: its voting key signs, the
  /// bridge relays. Throws with the node's reason when the vote is not
  /// taken (e.g. the masternode isn't valid, or it voted less than an
  /// hour ago).
  Future<void> voteOnProposal({
    required KerriganProposal proposal,
    required KerriganMasternode mn,
    required KerriganVote vote,
    coinlib.HDPrivateKey? root,
  }) async {
    final problem = votingProblem(mn);
    if (problem != null) throw Exception(problem);
    final key = (await _dip9Key(
      _kDip9Voting,
      mn.keyIndex!,
      root: root,
    )).privateKey.data;
    final time = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    // Kerrigan Core checks vote signatures as signed messages, except on
    // testnet, where it checks a signature of the vote's hash.
    final signature = cryptoCurrency.network == CryptoCurrencyNetwork.test
        ? libKerriganShield.signHash(
            privateKey: key,
            hash: kerriganVoteHash(
              collateralTxid: mn.txid,
              collateralVout: mn.vout,
              objectHash: proposal.hash,
              vote: vote,
              time: time,
            ),
          )
        : libKerriganShield.signMessage(
            privateKey: key,
            message: kerriganVoteMessage(
              collateralTxid: mn.txid,
              collateralVout: mn.vout,
              objectHash: proposal.hash,
              vote: vote,
              time: time,
            ),
          );
    try {
      final answer = await bridge.voteRaw(
        collateralTxid: mn.txid,
        collateralVout: mn.vout,
        objectHash: proposal.hash,
        signal: "funding",
        outcome: vote.name,
        time: time,
        signatureBase64: signature,
      );
      if (!answer.toLowerCase().contains("voted successfully")) {
        throw Exception(answer);
      }
    } catch (e) {
      throw Exception(_voteError(e.toString()));
    }
  }

  /// [voteOnProposal] with each of [masternodes] in turn, reading the
  /// recovery phrase once for all of them: yields each one's error, or
  /// null when its vote was taken. Stops when the listener cancels.
  Stream<({KerriganMasternode mn, Object? error})> voteOnProposalWith({
    required KerriganProposal proposal,
    required List<KerriganMasternode> masternodes,
    required KerriganVote vote,
  }) async* {
    coinlib.HDPrivateKey? root;
    for (final mn in masternodes) {
      Object? error;
      try {
        if (votingProblem(mn) == null) root ??= await getRootHDNode();
        await voteOnProposal(
          proposal: proposal,
          mn: mn,
          vote: vote,
          root: root,
        );
      } catch (e) {
        error = e;
      }
      yield (mn: mn, error: error);
    }
  }

  static String _voteError(String error) {
    final e = error
        .replaceFirst("Exception: ", "")
        .replaceFirst(RegExp(r"^KerriganBridgeException\(\d*\):\s*"), "")
        .replaceFirst(RegExp(r"^Error voting\s*:\s*"), "")
        .trim();
    if (e.contains("Failure to find masternode")) {
      return "The network doesn't count this masternode as valid (set its "
          "server first)";
    }
    if (e.contains("voting too often")) {
      return "This masternode voted less than an hour ago";
    }
    return e.isEmpty ? "The vote was not accepted" : e;
  }

  // ---------------------------------------------------------------------------
  // Creating

  String? proposalNameError(String name) {
    if (name.isEmpty) return "Enter a name";
    if (name.length > kKerriganProposalNameMax) {
      return "At most $kKerriganProposalNameMax characters";
    }
    if (!_kProposalName.hasMatch(name)) {
      return "Letters, digits, \"-\" and \"_\" only";
    }
    return null;
  }

  String? proposalUrlError(String url) {
    if (url.isEmpty) return "Enter the link to the proposal's description";
    final uri = Uri.tryParse(url);
    if (url.length < 4 ||
        url.contains(RegExp(r"\s")) ||
        uri == null ||
        !(uri.scheme == "https" || uri.scheme == "http") ||
        uri.host.isEmpty) {
      return "Not a valid web link (https://…)";
    }
    return null;
  }

  String? proposalAmountError(Amount? amount) {
    if (amount == null || amount.raw <= BigInt.zero) return "Enter an amount";
    return null;
  }

  String? proposalAddressError(String address) {
    if (address.isEmpty) return "Enter the address to pay";
    try {
      if (coinlib.Address.fromString(address, cryptoCurrency.networkParams)
          is coinlib.P2PKHAddress) {
        return null;
      }
    } catch (_) {}
    return "A regular transparent ${cryptoCurrency.ticker} address";
  }

  /// The fee transaction of a new governance object: 1 KRGN burnt in an
  /// `OP_RETURN` with the object's hash, paid as [funding] says. Confirm
  /// with [confirmSend], then [addPendingProposal] with its txid.
  Future<(TxData, KerriganPendingProposal)> prepareProposal({
    required KerriganProposalType type,
    required String name,
    required String url,
    required String paymentAddress,
    required Amount amount,
    int? startEpoch,
    int? endEpoch,
    KerriganFunding funding = kKerriganAutoFunding,
  }) async {
    final error =
        proposalNameError(name) ??
        proposalUrlError(url) ??
        proposalAmountError(amount) ??
        proposalAddressError(paymentAddress);
    if (error != null) throw Exception(error);
    if (type == KerriganProposalType.proposal) {
      if (startEpoch == null || endEpoch == null || endEpoch <= startEpoch) {
        throw Exception("Choose how long the vote runs");
      }
      if (endEpoch - startEpoch > kKerriganProposalMaxSeconds) {
        throw Exception("A proposal runs for at most a year");
      }
    }
    final dataHex = kerriganProposalDataHex(
      type: type,
      name: name,
      url: url,
      paymentAddress: paymentAddress,
      amount: amount,
      startEpoch: type == KerriganProposalType.proposal ? startEpoch : null,
      endEpoch: type == KerriganProposalType.proposal ? endEpoch : null,
    );
    final time = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    final hash = kerriganProposalHash(dataHex: dataHex, time: time);
    final txData = await prepareSend(
      txData: TxData(
        note: "${type.label} fee: $name",
        noteOnChain: "",
        utxos: kerriganFundingInputs(funding),
        otherData: jsonEncode(kerriganFundingOtherData(funding)),
        recipients: [
          TxRecipient(
            address: "$kKerriganOpReturnPrefix$hash",
            amount: Amount(
              rawValue: BigInt.from(kKerriganProposalFeeSats),
              fractionDigits: cryptoCurrency.fractionDigits,
            ),
            isChange: false,
            addressType: AddressType.nonWallet,
          ),
        ],
      ),
    );
    return (
      txData,
      KerriganPendingProposal(
        type: type,
        name: name,
        dataHex: dataHex,
        time: time,
        hash: hash,
        feeTxid: "",
      ),
    );
  }

  /// Remember [proposal] whose fee went out in [feeTxid]; it is submitted
  /// once the fee is confirmed (see [submitPendingProposals]).
  Future<void> addPendingProposal(
    KerriganPendingProposal proposal,
    String feeTxid,
  ) => _updatePending(
    (stored) => [
      ...stored.where((p) => p.hash != proposal.hash),
      proposal.copyWith(feeTxid: feeTxid),
    ],
  );

  /// Forget a pending proposal (after it failed).
  Future<void> removePendingProposal(String hash) =>
      _updatePending((stored) => [...stored.where((p) => p.hash != hash)]);

  /// After sending [proposal]'s fee failed: forget the proposal when the
  /// network doesn't have its fee transaction. Kept when it may have it
  /// (it is then submitted once the fee confirms).
  Future<void> forgetUnsentProposal(KerriganPendingProposal proposal) async {
    final saved = pendingProposals
        .where((p) => p.hash == proposal.hash)
        .firstOrNull;
    if (saved == null) return;
    if (await _stillOnNetwork(saved.feeTxid) == false) {
      await removePendingProposal(proposal.hash);
    }
  }

  /// Confirmations of a pending proposal's fee, null while unconfirmed.
  Future<int?> feeConfirmationsOf(KerriganPendingProposal p) async {
    final tx = await mainDB.isar.transactionV2s
        .where()
        .txidWalletIdEqualTo(p.feeTxid, walletId)
        .findFirst();
    final height = tx?.height;
    if (height == null || height <= 0) return null;
    return await chainHeight - height + 1;
  }

  /// Submit the pending proposals whose fee is confirmed enough; called
  /// after syncing. A proposal the network already knows is done.
  Future<void> submitPendingProposals() =>
      _submittingProposals[walletId] ??= _submitPendingProposals().whenComplete(
        // Not `=> remove(...)`: that returns this very future, which
        // whenComplete would then wait for, forever.
        () {
          _submittingProposals.remove(walletId);
        },
      );

  Future<void> _submitPendingProposals() async {
    final pending = pendingProposals;
    if (pending.isEmpty) return;
    final known = (await bridge.governanceObjects()).keys.toSet();
    // By hash: submitted (or already known) ones, and lasting errors.
    final done = <String>{};
    final errors = <String, String>{};
    for (final p in pending) {
      if (known.contains(p.hash)) {
        done.add(p.hash);
        continue;
      }
      if (p.error != null) continue;
      final confs = await feeConfirmationsOf(p);
      if (confs == null || confs < kKerriganProposalFeeConfirmations) {
        continue;
      }
      try {
        final hash = await bridge.submitGovernanceObject(
          revision: 1,
          time: p.time,
          dataHex: p.dataHex,
          feeTxid: p.feeTxid,
        );
        if (hash != p.hash) {
          Logging.instance.w(
            "Kerrigan: proposal ${p.name} submitted as $hash, expected "
            "${p.hash}",
          );
        }
        done.add(p.hash);
      } catch (e) {
        Logging.instance.w("Kerrigan: submitting proposal ${p.name}: $e");
        final message = e
            .toString()
            .replaceFirst("Exception: ", "")
            .replaceFirst(RegExp(r"^KerriganBridgeException\(\d*\):\s*"), "");
        // Not synced yet, or too few confirmations: try again later.
        final temporary =
            message.contains("Must wait for client to sync") ||
            message.contains("confirmations");
        if (!temporary) errors[p.hash] = message;
      }
    }
    if (done.isEmpty && errors.isEmpty) return;
    // Proposals added meanwhile stay.
    await _updatePending(
      (stored) => [
        for (final p in stored)
          if (!done.contains(p.hash))
            errors.containsKey(p.hash) ? p.copyWith(error: errors[p.hash]) : p,
      ],
    );
  }
}
