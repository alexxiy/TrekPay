part of '../kerrigan_wallet.dart';

/// Masternode types (Kerrigan Core `MnType`).
enum KerriganMasternodeType {
  regular("Masternode", 10000),
  broodNode("BroodNode", 40000);

  const KerriganMasternodeType(this.label, this.collateralCoins);

  final String label;

  /// The exact collateral, in whole coins.
  final int collateralCoins;
}

/// A deterministic masternode (Dash DIP3) of this wallet: a collateral
/// output frozen in the wallet, registered on chain by a provider
/// transaction (ProRegTx).
///
/// Its owner and voting keys, and its operator key unless the host gave
/// one, derive from the wallet seed on DIP 9 paths, so a restored wallet
/// has them again (see [KerriganMasternodes.findExistingMasternodes]).
class KerriganMasternode {
  const KerriganMasternode({
    required this.label,
    required this.type,
    required this.address,
    required this.txid,
    required this.vout,
    required this.createdAt,
    required this.payoutAddress,
    this.keyIndex,
    this.operatorIndex,
    this.hostOperatorKey,
    this.proTxHash,
    this.service,
  });

  final String label;
  final KerriganMasternodeType type;

  /// Wallet address holding the collateral.
  final String address;

  /// Collateral output.
  final String txid;
  final int vout;

  /// Unix seconds.
  final int createdAt;

  /// Where the masternode's rewards go (the collateral address unless it
  /// was registered elsewhere).
  final String payoutAddress;

  /// DIP 9 index of the owner and voting keys. Null for a masternode
  /// registered elsewhere with keys this wallet doesn't hold.
  final int? keyIndex;

  /// DIP 9 index of the operator key the wallet made, or null.
  final int? operatorIndex;

  /// Operator public key (BLS, hex) the host gave, when the wallet
  /// didn't make the operator key.
  final String? hostOperatorKey;

  /// The registration transaction, once sent.
  final String? proTxHash;

  /// The server, `ip:port`, once known.
  final String? service;

  String get id => "$txid:$vout";

  bool get isRegistered => proTxHash != null;

  /// The wallet can sign for the operator: update the server.
  bool get walletOperates => operatorIndex != null;

  static const _keep = Object();

  KerriganMasternode copyWith({
    Object? keyIndex = _keep,
    Object? operatorIndex = _keep,
    Object? hostOperatorKey = _keep,
    Object? proTxHash = _keep,
    Object? service = _keep,
    String? payoutAddress,
  }) => KerriganMasternode(
    label: label,
    type: type,
    address: address,
    txid: txid,
    vout: vout,
    createdAt: createdAt,
    payoutAddress: payoutAddress ?? this.payoutAddress,
    keyIndex: keyIndex == _keep ? this.keyIndex : keyIndex as int?,
    operatorIndex: operatorIndex == _keep
        ? this.operatorIndex
        : operatorIndex as int?,
    hostOperatorKey: hostOperatorKey == _keep
        ? this.hostOperatorKey
        : hostOperatorKey as String?,
    proTxHash: proTxHash == _keep ? this.proTxHash : proTxHash as String?,
    service: service == _keep ? this.service : service as String?,
  );

  Map<String, dynamic> toJson() => {
    "label": label,
    "type": type.name,
    "address": address,
    "txid": txid,
    "vout": vout,
    "createdAt": createdAt,
    "payoutAddress": payoutAddress,
    if (keyIndex != null) "keyIndex": keyIndex,
    if (operatorIndex != null) "operatorIndex": operatorIndex,
    if (hostOperatorKey != null) "hostOperatorKey": hostOperatorKey,
    if (proTxHash != null) "proTxHash": proTxHash,
    if (service != null) "service": service,
  };

  factory KerriganMasternode.fromJson(Map<String, dynamic> json) =>
      KerriganMasternode(
        label: json["label"] as String,
        type: KerriganMasternodeType.values.byName(json["type"] as String),
        address: json["address"] as String,
        txid: json["txid"] as String,
        vout: json["vout"] as int,
        createdAt: json["createdAt"] as int,
        payoutAddress: json["payoutAddress"] as String,
        keyIndex: json["keyIndex"] as int?,
        operatorIndex: json["operatorIndex"] as int?,
        hostOperatorKey: json["hostOperatorKey"] as String?,
        proTxHash: json["proTxHash"] as String?,
        service: json["service"] as String?,
      );
}

/// Where a masternode stands on the network.
enum KerriganMasternodeStatus {
  /// No registration on chain.
  unregistered("Not registered"),

  /// Registration sent, not mined yet.
  pending("Registering"),

  /// Registered without a server: banned until its server is set.
  needsServer("Needs a server"),

  /// Registered and serving.
  enabled("Enabled"),

  /// Banned for not serving (proof of service); setting its server again
  /// revives it.
  banned("PoSe banned"),

  /// Its operator stopped serving it; it needs a new operator key.
  revoked("Revoked"),

  /// The network couldn't be asked.
  unknown("Unknown"),

  /// Not loaded yet.
  checking("Checking…");

  const KerriganMasternodeStatus(this.label);

  final String label;
}

/// A masternode as the network sees it (`protx info`).
typedef KerriganMasternodeState = ({
  KerriganMasternodeStatus status,
  String? proTxHash,
  String? service,
  int registeredHeight,
  int lastPaidHeight,
  int posePenalty,
  String? operatorPublicKey,
  String? ownerAddress,
  String? votingAddress,
  String? payoutAddress,
});

/// A provider transaction ready to send; [masternode] is how the wallet
/// records the masternode once it is sent.
typedef KerriganProviderTx = ({
  String txid,
  String hex,
  Amount fee,
  List<UTXO> spent,
  KerriganMasternode masternode,
});

/// A registered masternode whose collateral is in this wallet but which
/// the wallet doesn't list (after a restore, or registered elsewhere).
typedef KerriganFoundMasternode = ({
  String proTxHash,
  KerriganMasternodeType type,
  String txid,
  int vout,
  String address,
  String payoutAddress,
  String? service,
  int? keyIndex,
  int? operatorIndex,
  String operatorPublicKey,
});

const _kMasternodesKey = "kerriganMasternodes";
const _kMasternodeFrozenReason = "Masternode collateral";

/// Default P2P ports (`nDefaultPort`).
const kKerriganMasternodePortMain = 7120;
const kKerriganMasternodePortTest = 17120;
const kKerriganMasternodePortRegtest = 27120;

/// Kept transparent when a collateral is paid from the shield: provider
/// transactions (registration, updates) pay their fee from transparent
/// coins.
const _kProviderFeeReserveSats = 100000;

/// DIP 9 masternode key features: m/9'/coin'/3'/feature'/index.
const _kDip9Voting = 1;
const _kDip9Owner = 2;
const _kDip9Operator = 3;

/// How far key discovery looks for a restored wallet's masternode keys.
const _kMasternodeKeySearch = 20;

/// Ids (`txid:vout`) of the masternodes in a wallet's otherData.
List<String> kerriganMasternodeIds(Map<String, dynamic> otherData) => [
  for (final e in (otherData[_kMasternodesKey] as List?) ?? const [])
    KerriganMasternode.fromJson(Map<String, dynamic>.from(e as Map)).id,
];

extension KerriganMasternodes on KerriganWallet {
  List<KerriganMasternode> get masternodes => [
    for (final e in (info.otherData[_kMasternodesKey] as List?) ?? const [])
      KerriganMasternode.fromJson(Map<String, dynamic>.from(e as Map)),
  ];

  Set<String> get _masternodePayouts => {
    for (final m in masternodes) m.payoutAddress,
  };

  bool _isMasternodeCollateral(String txid, int vout) =>
      masternodes.any((m) => m.txid == txid && m.vout == vout);

  Amount masternodeCollateral(KerriganMasternodeType type) => Amount(
    rawValue: BigInt.from(type.collateralCoins) * cryptoCurrency.satsPerCoin,
    fractionDigits: cryptoCurrency.fractionDigits,
  );

  int get masternodePort => switch (cryptoCurrency.network) {
    CryptoCurrencyNetwork.main => kKerriganMasternodePortMain,
    CryptoCurrencyNetwork.regtest => kKerriganMasternodePortRegtest,
    _ => kKerriganMasternodePortTest,
  };

  bool get _mainnet => cryptoCurrency.network == CryptoCurrencyNetwork.main;

  // ---------------------------------------------------------------------------
  // Aliases and servers

  /// The first free alias "MN1", "MN2", ...
  String nextMasternodeAlias() {
    final used = {for (final m in masternodes) m.label.trim().toLowerCase()};
    for (int i = 1; ; i++) {
      if (!used.contains("mn$i")) return "MN$i";
    }
  }

  bool isMasternodeAliasTaken(String alias) {
    final a = alias.trim().toLowerCase();
    return masternodes.any((m) => m.label.trim().toLowerCase() == a);
  }

  static final _aliasPattern = RegExp(r"^[A-Za-z0-9_.-]{1,32}$");

  /// Why [alias] can't name a new masternode, or null when it can.
  String? masternodeAliasError(String alias) {
    final a = alias.trim();
    if (a.isEmpty) return "Enter a masternode alias";
    if (!_aliasPattern.hasMatch(a)) {
      return a.length > 32
          ? "At most 32 characters"
          : "Only letters, digits, \"_\", \"-\" and \".\"";
    }
    if (isMasternodeAliasTaken(a)) {
      return "Another masternode is already called \"$a\"";
    }
    return null;
  }

  /// Why [text] is not a usable server address, or null when it is.
  String? masternodeServiceError(String text) {
    try {
      normalizeMasternodeService(text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  /// Parse a server address, `1.2.3.4:7120`, `[2001:db8::1]:7120` or a
  /// bare IP (default port). Returns `ip:port`, or throws.
  String normalizeMasternodeService(String text) {
    final s = text.trim();
    String host;
    int port = masternodePort;
    if (s.startsWith("[")) {
      final end = s.indexOf("]");
      if (end < 0) throw const FormatException("Invalid IPv6 address");
      host = s.substring(1, end);
      final rest = s.substring(end + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(":")) throw const FormatException("Invalid port");
        port = _parsePort(rest.substring(1));
      }
    } else if (":".allMatches(s).length == 1) {
      final i = s.indexOf(":");
      host = s.substring(0, i);
      port = _parsePort(s.substring(i + 1));
    } else {
      host = s;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip == null) {
      throw const FormatException("Enter the server's IP address");
    }
    if (port <= 0 || port > 65535) throw const FormatException("Invalid port");
    // As Kerrigan Core checks it: mainnet masternodes run on 7120 and
    // other networks never do.
    if (_mainnet && port != kKerriganMasternodePortMain) {
      throw const FormatException(
        "Masternodes must use port $kKerriganMasternodePortMain",
      );
    }
    if (!_mainnet && port == kKerriganMasternodePortMain) {
      throw const FormatException(
        "Port $kKerriganMasternodePortMain is for mainnet masternodes only",
      );
    }
    return ip.type == InternetAddressType.IPv6
        ? "[${ip.address}]:$port"
        : "${ip.address}:$port";
  }

  static int _parsePort(String text) {
    final port = int.tryParse(text.trim());
    if (port == null) throw const FormatException("Invalid port");
    return port;
  }

  // ---------------------------------------------------------------------------
  // Keys (DIP 9: m/9'/coin'/3'/feature'/index)

  Future<coinlib.HDPrivateKey> _dip9Key(int feature, int index) async {
    if (isViewOnly) throw Exception("View only wallets have no keys");
    return (await getRootHDNode()).derivePath(
      "m/9'/${cryptoCurrency.coinType}'/3'/$feature'/$index",
    );
  }

  String _p2pkh(coinlib.ECPublicKey key) => coinlib.P2PKHAddress.fromPublicKey(
    key,
    version: cryptoCurrency.networkParams.p2pkhPrefix,
  ).toString();

  /// Owner address of key [index]: controls the registration.
  Future<String> masternodeOwnerAddress(int index) async =>
      _p2pkh((await _dip9Key(_kDip9Owner, index)).publicKey);

  /// Voting address of key [index]: votes on proposals.
  Future<String> masternodeVotingAddress(int index) async =>
      _p2pkh((await _dip9Key(_kDip9Voting, index)).publicKey);

  /// Operator key pair (BLS) of key [index]: the server runs with its
  /// secret.
  Future<({String secret, String public})> masternodeOperatorKey(
    int index,
  ) async => libKerriganShield.blsKeygen(
    ikm: (await _dip9Key(_kDip9Operator, index)).privateKey.data,
  );

  /// The operator public key [mn] is (or will be) registered with.
  Future<String?> operatorPublicKeyOf(KerriganMasternode mn) async =>
      mn.hostOperatorKey ??
      (mn.operatorIndex == null
          ? null
          : (await masternodeOperatorKey(mn.operatorIndex!)).public);

  /// The operator secret key, when the wallet made the operator key.
  Future<String?> operatorSecretOf(KerriganMasternode mn) async =>
      mn.operatorIndex == null
      ? null
      : (await masternodeOperatorKey(mn.operatorIndex!)).secret;

  bool isValidOperatorPublicKey(String key) =>
      RegExp(r"^[0-9a-fA-F]{96}$").hasMatch(key.trim()) &&
      libKerriganShield.isValidBlsPublicKey(key.trim().toLowerCase());

  /// A DIP 9 index not used by this wallet's masternodes nor, as owner
  /// key, by a registration on the network (a restored wallet may have
  /// used it before).
  Future<int> _freeKeyIndex(List<Map<String, dynamic>> registered) async {
    final usedOwners = {
      for (final e in registered)
        (e["state"] as Map?)?["ownerAddress"] as String?,
    };
    final usedOperators = {
      for (final e in registered)
        (e["state"] as Map?)?["pubKeyOperator"] as String?,
    };
    var index = 0;
    for (final m in masternodes) {
      for (final i in [m.keyIndex, m.operatorIndex]) {
        if (i != null && i >= index) index = i + 1;
      }
    }
    while (usedOwners.contains(await masternodeOwnerAddress(index)) ||
        usedOperators.contains((await masternodeOperatorKey(index)).public)) {
      index++;
    }
    return index;
  }

  /// Give an unregistered [mn] its DIP 9 key index now, so the operator
  /// key a server is set up with is the one registering uses. Returns
  /// the masternode as stored.
  Future<KerriganMasternode> ensureMasternodeKeys(KerriganMasternode mn) async {
    if (mn.keyIndex != null || mn.isRegistered || isViewOnly) return mn;
    final index = await _freeKeyIndex(await bridge.protxList());
    final updated = mn.copyWith(
      keyIndex: index,
      operatorIndex: mn.hostOperatorKey == null ? index : null,
    );
    await _saveMasternode(updated);
    return updated;
  }

  // ---------------------------------------------------------------------------
  // Collateral

  /// Unspent outputs of exactly the collateral of [type] not used by a
  /// masternode yet (e.g. a collateral sent before, or after a restore).
  Future<List<UTXO>> availableCollaterals(KerriganMasternodeType type) async {
    final raw = masternodeCollateral(type).raw.toInt();
    return (await mainDB.getUTXOs(walletId).findAll())
        .where(
          (u) =>
              !isKerriganShieldNote(u) &&
              u.value == raw &&
              u.used != true &&
              !_isMasternodeCollateral(u.txid, u.vout),
        )
        .toList();
  }

  /// Remember a masternode and freeze its collateral.
  Future<KerriganMasternode> addMasternode({
    required String label,
    required KerriganMasternodeType type,
    required String address,
    required String txid,
    required int vout,
    String? addressLabel,
    String? payoutAddress,
    int? keyIndex,
    int? operatorIndex,
    String? hostOperatorKey,
    String? proTxHash,
    String? service,
  }) async {
    if (label.trim().isEmpty) throw Exception("Masternode alias is required");
    final mn = KerriganMasternode(
      label: label.trim(),
      type: type,
      address: address,
      txid: txid,
      vout: vout,
      createdAt: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
      payoutAddress: payoutAddress ?? address,
      keyIndex: keyIndex,
      operatorIndex: operatorIndex,
      hostOperatorKey: hostOperatorKey,
      proTxHash: proTxHash,
      service: service,
    );
    await info.updateOtherData(
      newEntries: {
        _kMasternodesKey: [
          for (final m in masternodes)
            if (m.id != mn.id) m.toJson(),
          mn.toJson(),
        ],
      },
      isar: mainDB.isar,
    );
    final newLabel = addressLabel?.trim() ?? "";
    if (newLabel.isNotEmpty) {
      final existing = mainDB.getAddressLabelSync(walletId, address);
      await mainDB.updateAddressLabel(
        existing?.copyWith(label: newLabel) ??
            AddressLabel(
              walletId: walletId,
              addressString: address,
              value: newLabel,
              tags: null,
            ),
      );
    }
    await _freezeCollateral(mn, frozen: true);
    return mn;
  }

  /// Forget a masternode; its collateral becomes spendable again.
  /// Spending it ends the masternode on the network.
  Future<void> removeMasternode(KerriganMasternode mn) async {
    await info.updateOtherData(
      newEntries: {
        _kMasternodesKey: [
          for (final m in masternodes)
            if (m.id != mn.id) m.toJson(),
        ],
      },
      isar: mainDB.isar,
    );
    await _freezeCollateral(mn, frozen: false);
  }

  Future<void> _saveMasternode(KerriganMasternode mn) => info.updateOtherData(
    newEntries: {
      _kMasternodesKey: [
        for (final m in masternodes) m.id == mn.id ? mn.toJson() : m.toJson(),
      ],
    },
    isar: mainDB.isar,
  );

  Future<void> _freezeCollateral(
    KerriganMasternode mn, {
    required bool frozen,
  }) async {
    final utxo = await mainDB.isar.utxos
        .where()
        .txidWalletIdVoutEqualTo(mn.txid, walletId, mn.vout)
        .findFirst();
    if (utxo == null) return; // frozen by updateUTXOs once it is seen
    await mainDB.putUTXO(
      utxo.copyWith(
        isBlocked: frozen,
        blockedReason: frozen ? _kMasternodeFrozenReason : null,
      ),
    );
    await updateBalance();
  }

  /// Transparent coins available for provider transaction fees.
  Future<Amount> providerFeeBalance() async {
    final coins = _spendable(
      await mainDB.getUTXOs(walletId).findAll(),
      await chainHeight,
    );
    return Amount(
      rawValue: coins.fold(BigInt.zero, (p, u) => p + BigInt.from(u.value)),
      fractionDigits: cryptoCurrency.fractionDigits,
    );
  }

  /// Build the collateral payment: exactly the collateral of [type] to
  /// [address] (a wallet address), paid as [funding] says. Paid from the
  /// shield, it also keeps a little transparent for the registration fee
  /// when the wallet has none. Confirm with [confirmSend], then call
  /// [addMasternode] with [collateralVout].
  Future<TxData> prepareMasternodeCollateral({
    required String address,
    required KerriganMasternodeType type,
    KerriganFunding funding = kKerriganAutoFunding,
    String note = "Create masternode",
  }) async {
    final other = kerriganFundingOtherData(funding);
    if (funding.fromShield &&
        (await providerFeeBalance()).raw <
            BigInt.from(_kProviderFeeReserveSats)) {
      other[kKerriganExtraOutputs] = [
        {
          "address": (await getCurrentChangeAddress() ??
                  await _deriveAddress(chain: 1, index: 0))
              .value,
          "amount": _kProviderFeeReserveSats,
        },
      ];
    }
    return prepareSend(
      txData: TxData(
        // The confirm screen expects both notes set, like the send screen.
        note: note,
        noteOnChain: "",
        recipients: [
          TxRecipient(
            address: address,
            amount: masternodeCollateral(type),
            isChange: false,
            addressType: AddressType.p2pkh,
          ),
        ],
        utxos: kerriganFundingInputs(funding),
        otherData: jsonEncode(other),
      ),
    );
  }

  /// Output index of the collateral in a prepared collateral payment.
  int collateralVout(
    TxData txData,
    String address,
    KerriganMasternodeType type,
  ) {
    final raw = txData.raw;
    if (raw != null) {
      final outputs = kerriganTxOutputs(raw.toUint8ListFromHex);
      final value = masternodeCollateral(type).raw;
      final script = coinlib.Output.fromAddress(
        BigInt.zero,
        _parseAddress(address),
      ).scriptPubKey;
      for (int i = 0; i < outputs.length; i++) {
        if (outputs[i].value == value &&
            outputs[i].script.toHex == script.toHex) {
          return i;
        }
      }
    }
    throw Exception("Collateral output not found");
  }

  // ---------------------------------------------------------------------------
  // The network's view

  static bool _noService(String? s) =>
      s == null || s.isEmpty || s == "[::]:0" || s.startsWith("0.0.0.0:");

  KerriganMasternodeState _stateOf(Map<String, dynamic> entry) {
    final state = Map<String, dynamic>.from(entry["state"] as Map? ?? {});
    final service = state["service"] as String?;
    final banned = ((state["PoSeBanHeight"] as num?)?.toInt() ?? -1) > 0;
    final revoked = ((state["revocationReason"] as num?)?.toInt() ?? 0) > 0;
    return (
      status: !banned
          ? KerriganMasternodeStatus.enabled
          : revoked
          ? KerriganMasternodeStatus.revoked
          : _noService(service)
          ? KerriganMasternodeStatus.needsServer
          : KerriganMasternodeStatus.banned,
      proTxHash: entry["proTxHash"] as String?,
      service: _noService(service) ? null : service,
      registeredHeight: (state["registeredHeight"] as num?)?.toInt() ?? 0,
      lastPaidHeight: (state["lastPaidHeight"] as num?)?.toInt() ?? 0,
      posePenalty: (state["PoSePenalty"] as num?)?.toInt() ?? 0,
      operatorPublicKey: state["pubKeyOperator"] as String?,
      ownerAddress: state["ownerAddress"] as String?,
      votingAddress: state["votingAddress"] as String?,
      payoutAddress: state["payoutAddress"] as String?,
    );
  }

  static const KerriganMasternodeState _noState = (
    status: KerriganMasternodeStatus.unregistered,
    proTxHash: null,
    service: null,
    registeredHeight: 0,
    lastPaidHeight: 0,
    posePenalty: 0,
    operatorPublicKey: null,
    ownerAddress: null,
    votingAddress: null,
    payoutAddress: null,
  );

  /// [mn] as the network sees it.
  Future<KerriganMasternodeState> masternodeState(
    KerriganMasternode mn,
  ) async {
    try {
      Map<String, dynamic>? entry;
      if (mn.proTxHash != null) {
        try {
          entry = await bridge.protxInfo(mn.proTxHash!);
        } on KerriganBridgeException catch (e) {
          if (e.statusCode == 403) rethrow;
          // Not registered (yet): look at the registration below.
        }
      }
      entry ??= (await bridge.protxList())
          .where(
            (e) =>
                e["collateralHash"] == mn.txid &&
                e["collateralIndex"] == mn.vout,
          )
          .firstOrNull;
      if (entry != null) {
        // The collateral was spent: the masternode is gone.
        if (entry["collateralHash"] != mn.txid ||
            entry["collateralIndex"] != mn.vout) {
          return _noState;
        }
        return _stateOf(entry);
      }
      if (mn.proTxHash != null) {
        final tx = await mainDB.isar.transactionV2s
            .where()
            .txidWalletIdEqualTo(mn.proTxHash!, walletId)
            .findFirst();
        // Not in the wallet yet: it was only just sent.
        if (tx == null || tx.height == null || tx.height! <= 0) {
          return (
            status: KerriganMasternodeStatus.pending,
            proTxHash: mn.proTxHash,
            service: mn.service,
            registeredHeight: 0,
            lastPaidHeight: 0,
            posePenalty: 0,
            operatorPublicKey: null,
            ownerAddress: null,
            votingAddress: null,
            payoutAddress: null,
          );
        }
      }
      return _noState;
    } catch (e) {
      Logging.instance.w("Kerrigan: masternode state failed: $e");
      return (
        status: KerriganMasternodeStatus.unknown,
        proTxHash: mn.proTxHash,
        service: mn.service,
        registeredHeight: 0,
        lastPaidHeight: 0,
        posePenalty: 0,
        operatorPublicKey: null,
        ownerAddress: null,
        votingAddress: null,
        payoutAddress: null,
      );
    }
  }

  /// Masternode rewards paid to [mn]'s payout address so far.
  Future<Amount> masternodeEarned(KerriganMasternode mn) async {
    final txs = await mainDB.isar.transactionV2s
        .where()
        .walletIdEqualTo(walletId)
        .findAll();
    var total = BigInt.zero;
    for (final tx in txs) {
      if (tx.kerriganKind != KerriganTxKind.masternodeReward) continue;
      for (final o in tx.outputs) {
        if (o.walletOwns && o.addresses.contains(mn.payoutAddress)) {
          total += o.value;
        }
      }
    }
    return Amount(
      rawValue: total,
      fractionDigits: cryptoCurrency.fractionDigits,
    );
  }

  /// Registered masternodes whose collateral is one of this wallet's
  /// coins but which the wallet doesn't list yet (e.g. after a restore),
  /// with the DIP 9 key indexes of the keys this wallet holds.
  Future<List<KerriganFoundMasternode>> findExistingMasternodes() async {
    final coins = {
      for (final u in await mainDB.getUTXOs(walletId).findAll())
        if (!isKerriganShieldNote(u) && u.used != true) "${u.txid}:${u.vout}": u,
    };
    final listed = {for (final m in masternodes) m.id};
    final found = <KerriganFoundMasternode>[];
    final registered = await bridge.protxList();
    final candidates = [
      for (final e in registered)
        if (coins.containsKey("${e["collateralHash"]}:${e["collateralIndex"]}") &&
            !listed.contains("${e["collateralHash"]}:${e["collateralIndex"]}"))
          e,
    ];
    if (candidates.isEmpty) return found;

    final owners = <String, int>{};
    final operators = <String, int>{};
    for (int i = 0; i < _kMasternodeKeySearch; i++) {
      owners[await masternodeOwnerAddress(i)] = i;
      operators[(await masternodeOperatorKey(i)).public] = i;
    }
    for (final e in candidates) {
      final state = _stateOf(e);
      final utxo = coins["${e["collateralHash"]}:${e["collateralIndex"]}"]!;
      found.add((
        proTxHash: e["proTxHash"] as String,
        type: e["type"] == "Regular"
            ? KerriganMasternodeType.regular
            : KerriganMasternodeType.broodNode,
        txid: utxo.txid,
        vout: utxo.vout,
        address: utxo.address ?? "",
        payoutAddress: state.payoutAddress ?? utxo.address ?? "",
        service: state.service,
        keyIndex: owners[state.ownerAddress],
        operatorIndex: operators[state.operatorPublicKey],
        operatorPublicKey: state.operatorPublicKey ?? "",
      ));
    }
    return found;
  }

  /// List a masternode found by [findExistingMasternodes].
  Future<KerriganMasternode> addFoundMasternode(
    KerriganFoundMasternode f, {
    required String label,
  }) => addMasternode(
    label: label,
    type: f.type,
    address: f.address,
    txid: f.txid,
    vout: f.vout,
    payoutAddress: f.payoutAddress,
    keyIndex: f.keyIndex,
    operatorIndex: f.operatorIndex,
    hostOperatorKey: f.operatorIndex == null ? f.operatorPublicKey : null,
    proTxHash: f.proTxHash,
    service: f.service,
  );

  // ---------------------------------------------------------------------------
  // Provider transactions

  /// Transparent coins to pay a provider transaction's fee, with keys.
  Future<List<Map<String, dynamic>>> _providerFeeUtxos() async {
    final coins = _spendable(
      await mainDB.getUTXOs(walletId).findAll(),
      await chainHeight,
    )..sort((a, b) => b.value.compareTo(a.value));
    // A few coins are plenty for a fee of a few thousand sats.
    final picked = <UTXO>[];
    var sum = 0;
    for (final u in coins) {
      picked.add(u);
      sum += u.value;
      if (sum >= _kProviderFeeReserveSats || picked.length >= 5) break;
    }
    if (picked.isEmpty) {
      throw Exception(
        "Masternode transactions pay a small fee from your transparent "
        "balance, which is empty. Move a little ${cryptoCurrency.ticker} "
        "(0.001 is plenty) to a transparent address of this wallet.",
      );
    }
    final inputs = await _withKeys(picked);
    return [
      for (final i in inputs)
        {
          "txid": i.utxo.txid,
          "vout": i.utxo.vout,
          "amount": i.utxo.value,
          "private_key": i.key!.privateKey!.data.toHex,
          "script": coinlib.Address.fromString(
            i.utxo.address!,
            cryptoCurrency.networkParams,
          ).program.script.compiled.toHex,
        },
    ];
  }

  Future<KerriganProviderTx> _buildProviderTx(
    Map<String, dynamic> kind,
    KerriganMasternode updated,
  ) async {
    final utxos = await _providerFeeUtxos();
    final change =
        (await getCurrentChangeAddress() ??
                await _deriveAddress(chain: 1, index: 0))
            .value;
    final result = await libKerriganShield.createProTx({
      ...kind,
      "utxos": utxos,
      "change_address": change,
      "network": cryptoCurrency.shieldNetwork,
    });
    final spent = Set<String>.from(result["nullifiers"] as List);
    final all = await mainDB.getUTXOs(walletId).findAll();
    return (
      txid: result["txid"] as String,
      hex: result["txhex"] as String,
      fee: Amount(
        rawValue: BigInt.from(result["fee"] as int),
        fractionDigits: cryptoCurrency.fractionDigits,
      ),
      spent: [
        for (final u in all)
          if (spent.contains("${u.txid},${u.vout}")) u,
      ],
      masternode: updated,
    );
  }

  /// The collateral's confirmations, or throws when it's gone.
  Future<int> _collateralConfirmations(KerriganMasternode mn) async {
    final utxo = await mainDB.isar.utxos
        .where()
        .txidWalletIdVoutEqualTo(mn.txid, walletId, mn.vout)
        .findFirst();
    if (utxo == null || utxo.used == true) {
      throw Exception("The collateral output is not in this wallet anymore");
    }
    final height = utxo.blockHeight;
    if (height == null || height <= 0) return 0;
    return await chainHeight - height + 1;
  }

  /// Register [mn] (ProRegTx): its collateral, owner and voting keys,
  /// operator key and payout address go on chain. [service] may be empty
  /// when the server isn't known yet; the masternode then waits, banned,
  /// until its server is set. [hostOperatorKey] is the operator public
  /// key a host gave; without it the wallet makes the operator key.
  Future<KerriganProviderTx> prepareMasternodeRegistration(
    KerriganMasternode mn, {
    required String service,
    String? hostOperatorKey,
  }) async {
    if (isViewOnly) throw Exception("View only wallets cannot sign");
    if (await _collateralConfirmations(mn) < 1) {
      throw Exception("Wait for the collateral to be confirmed");
    }
    final normalized = service.trim().isEmpty
        ? ""
        : normalizeMasternodeService(service);
    final host = hostOperatorKey?.trim().toLowerCase();
    if (host != null && host.isNotEmpty && !isValidOperatorPublicKey(host)) {
      throw Exception("That is not a valid operator public key");
    }
    if (mn.type == KerriganMasternodeType.broodNode &&
        (host == null || host.isEmpty)) {
      throw Exception(
        "A BroodNode registers with its server's identity key "
        "(kerrigan-cli gethmpidentity)",
      );
    }
    final registered = await bridge.protxList();
    final index = mn.keyIndex ?? await _freeKeyIndex(registered);
    final useHost = host != null && host.isNotEmpty;
    final operatorIndex = useHost ? null : (mn.operatorIndex ?? index);
    final operatorKey = useHost
        ? host
        : (await masternodeOperatorKey(operatorIndex!)).public;

    final address = await mainDB.getAddress(walletId, mn.address);
    if (address?.derivationPath == null) {
      throw Exception("The collateral address is not a wallet address");
    }
    final collateralKey = (await getRootHDNode())
        .derivePath(address!.derivationPath!.value)
        .privateKey;

    return _buildProviderTx(
      {
        "kind": "register",
        "evo": mn.type == KerriganMasternodeType.broodNode,
        "collateral_txid": mn.txid,
        "collateral_vout": mn.vout,
        "collateral_key": collateralKey.data.toHex,
        "service": normalized,
        "owner_address": await masternodeOwnerAddress(index),
        "voting_address": await masternodeVotingAddress(index),
        "operator_public_key": operatorKey,
        "payout_address": mn.payoutAddress,
        "operator_reward": 0,
      },
      mn.copyWith(
        keyIndex: index,
        operatorIndex: operatorIndex,
        hostOperatorKey: useHost ? host : null,
        service: normalized.isEmpty ? null : normalized,
      ),
    ).then(
      (tx) => (
        txid: tx.txid,
        hex: tx.hex,
        fee: tx.fee,
        spent: tx.spent,
        masternode: tx.masternode.copyWith(proTxHash: tx.txid),
      ),
    );
  }

  /// Set [mn]'s server (ProUpServTx, signed with the operator key the
  /// wallet made). Also revives a banned masternode.
  Future<KerriganProviderTx> prepareMasternodeServiceUpdate(
    KerriganMasternode mn, {
    required String service,
  }) async {
    if (!mn.isRegistered) throw Exception("Register the masternode first");
    final secret = await operatorSecretOf(mn);
    if (secret == null) {
      throw Exception(
        "Your host holds this masternode's operator key; they set its "
        "server",
      );
    }
    final normalized = normalizeMasternodeService(service);
    return _buildProviderTx({
      "kind": "update_service",
      "evo": mn.type == KerriganMasternodeType.broodNode,
      "pro_tx_hash": mn.proTxHash,
      "service": normalized,
      "operator_secret": secret,
    }, mn.copyWith(service: normalized));
  }

  /// Give [mn] a new operator key (ProUpRegTx, signed by the owner key):
  /// [hostOperatorKey] from a new host, or a new one the wallet makes.
  /// The network then waits for the new operator to set the server.
  Future<KerriganProviderTx> prepareMasternodeOperatorChange(
    KerriganMasternode mn, {
    String? hostOperatorKey,
  }) async {
    if (!mn.isRegistered) throw Exception("Register the masternode first");
    final keyIndex = mn.keyIndex;
    if (keyIndex == null) {
      throw Exception("This wallet doesn't hold the masternode's owner key");
    }
    final host = hostOperatorKey?.trim().toLowerCase();
    final useHost = host != null && host.isNotEmpty;
    if (useHost && !isValidOperatorPublicKey(host)) {
      throw Exception("That is not a valid operator public key");
    }
    int? operatorIndex;
    String operatorKey;
    if (useHost) {
      operatorKey = host;
    } else {
      operatorIndex = await _freeKeyIndex(await bridge.protxList());
      operatorKey = (await masternodeOperatorKey(operatorIndex)).public;
    }
    final state = await masternodeState(mn);
    return _buildProviderTx(
      {
        "kind": "update_registrar",
        "pro_tx_hash": mn.proTxHash,
        "operator_public_key": operatorKey,
        "voting_address":
            state.votingAddress ?? await masternodeVotingAddress(keyIndex),
        "payout_address": state.payoutAddress ?? mn.payoutAddress,
        "owner_key": (await _dip9Key(
          _kDip9Owner,
          keyIndex,
        )).privateKey.data.toHex,
      },
      mn.copyWith(
        operatorIndex: operatorIndex,
        hostOperatorKey: useHost ? host : null,
        service: null,
      ),
    );
  }

  /// Send a provider transaction and record the masternode as it now is.
  Future<KerriganMasternode> sendProviderTx(KerriganProviderTx tx) async {
    final txid = await bridge.sendTx(tx.hex);
    if (txid != tx.txid) {
      Logging.instance.w("Kerrigan: provider tx sent as $txid, built ${tx.txid}");
    }
    await mainDB.putUTXOs([for (final u in tx.spent) u.copyWith(used: true)]);
    await _saveMasternode(tx.masternode);
    unawaited(refresh());
    return tx.masternode;
  }

  // ---------------------------------------------------------------------------
  // Hosting

  /// `kerrigan.conf` for [mn]'s server, run with the operator secret.
  /// The port of a "host:port" [service], else the network's default.
  int masternodePortOf(String? service) {
    if (service == null) return masternodePort;
    return int.tryParse(service.substring(service.lastIndexOf(":") + 1)) ??
        masternodePort;
  }

  String masternodeKerriganConf(KerriganMasternode mn, String operatorSecret) {
    final service = mn.service ?? "YOUR_SERVER_IP:$masternodePort";
    final i = service.lastIndexOf(":");
    var ip = service.substring(0, i);
    if (ip.startsWith("[")) ip = ip.substring(1, ip.length - 1);
    final port = masternodePortOf(service);
    final lines = [
      "server=1",
      "listen=1",
      "daemon=1",
      "externalip=$ip",
      if (port != masternodePort) "port=$port",
      "masternodeblsprivkey=$operatorSecret",
    ];
    return switch (cryptoCurrency.network) {
      CryptoCurrencyNetwork.main =>
        "# Kerrigan masternode: ${mn.label}\n${lines.join("\n")}\n",
      CryptoCurrencyNetwork.regtest =>
        "# Kerrigan masternode: ${mn.label}\nregtest=1\n[regtest]\n"
            "${lines.join("\n")}\n",
      _ =>
        "# Kerrigan masternode: ${mn.label}\ntestnet=1\n[test]\n"
            "${lines.join("\n")}\n",
    };
  }
}
