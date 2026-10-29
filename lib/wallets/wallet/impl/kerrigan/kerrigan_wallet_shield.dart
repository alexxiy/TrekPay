part of '../kerrigan_wallet.dart';

/// Blocks handed to the native scanner per call.
const _kShieldBatchBlocks = 200;

/// Marker in [TxData.otherData] for transactions built by the shield
/// library (anything touching a shield address or shield balance).
const _kOdShieldTx = "kerriganShieldTx";
const _kOdShieldNullifiers = "kerriganShieldNullifiers";
const _kOdShieldPendingIn = "kerriganShieldPendingIn";

/// Set in [TxData.otherData] by the UI to spend the shield balance.
const kKerriganFromShield = "kerriganFromShield";

/// Set in [TxData.otherData] by the UI: the recipient pays the fee
/// (receives the amount minus the fee).
const kKerriganSubtractFee = "kerriganSubtractFee";

/// Set in [TxData.otherData] by the UI: custom change address, a
/// transparent one for sends from the public balance, a shield one for
/// sends from the shield balance.
const kKerriganChangeAddress = "kerriganChangeAddress";

/// Set in [TxData.otherData]: more transparent outputs paid besides the
/// recipient, `[{"address": ..., "amount": sats}]` (sends from the shield
/// only). E.g. a little kept transparent for masternode fees.
const kKerriganExtraOutputs = "kerriganExtraOutputs";

/// Recipient "address" of a governance proposal fee: `OP_RETURN:<object
/// hash>`, an OP_RETURN output with the hash that burns its amount.
const kKerriganOpReturnPrefix = "OP_RETURN:";

bool isKerriganOpReturn(String address) =>
    address.startsWith(kKerriganOpReturnPrefix) &&
    RegExp(r"^[0-9a-f]{64}$")
        .hasMatch(address.substring(kKerriganOpReturnPrefix.length));

/// `OP_RETURN <hash>` for an [isKerriganOpReturn] recipient (the hash in
/// Kerrigan Core's internal byte order, as it looks for it).
Uint8List kerriganOpReturnScript(String address) => Uint8List.fromList([
  0x6a,
  0x20,
  ...address
      .substring(kKerriganOpReturnPrefix.length)
      .toUint8ListFromHex
      .reversed,
]);

/// Set in [TxData.otherData] by [KerriganWallet.prepareSend] when the change
/// goes to an address that is not this wallet's (a custom change address):
/// `{"address": ..., "sats": "..."}`. The confirm screen shows it, since
/// that change leaves the wallet like the payment does.
const kKerriganForeignChange = "kerriganForeignChange";

/// Change of [txData] that leaves the wallet (see [kKerriganForeignChange]).
({String address, BigInt sats})? kerriganForeignChange(TxData txData) {
  if (txData.otherData == null) return null;
  final v = (jsonDecode(txData.otherData!) as Map)[kKerriganForeignChange];
  if (v is! Map) return null;
  return (
    address: v["address"] as String,
    sats: BigInt.parse(v["sats"] as String),
  );
}

/// [otherData] (JSON) with [kKerriganForeignChange] set.
String _withForeignChange(String? otherData, String address, BigInt sats) =>
    jsonEncode({
      if (otherData != null) ...jsonDecode(otherData) as Map<String, dynamic>,
      kKerriganForeignChange: {"address": address, "sats": sats.toString()},
    });

/// The Sapling parameters download and load, shared by every wallet (the
/// prover is loaded once per process); progress goes to every caller.
Future<void>? _proverLoading;
final _proverProgress = <void Function(double)>{};

/// How the user pays a transaction: from the shield ([fromShield]) or
/// the transparent balance, with the coins picked in coin control (none:
/// chosen automatically) and where the change goes (null: automatic).
typedef KerriganFunding = ({
  bool fromShield,
  Set<UTXO> coins,
  String? changeAddress,
});

/// Automatic funding from the transparent balance.
const KerriganFunding kKerriganAutoFunding = (
  fromShield: false,
  coins: <UTXO>{},
  changeAddress: null,
);

/// [TxData.otherData] entries for [funding].
Map<String, dynamic> kerriganFundingOtherData(KerriganFunding funding) => {
  if (funding.fromShield) kKerriganFromShield: true,
  if (funding.changeAddress != null)
    kKerriganChangeAddress: funding.changeAddress,
};

/// [TxData.utxos] for [funding]: null lets the wallet choose.
Set<StandardInput>? kerriganFundingInputs(KerriganFunding funding) =>
    funding.coins.isEmpty
    ? null
    : {for (final u in funding.coins) StandardInput(u)};

bool _otherDataFlag(TxData txData, String key) =>
    txData.otherData != null &&
    (jsonDecode(txData.otherData!) as Map)[key] == true;

/// Unspent shield notes are mirrored as [UTXO] rows so coin control can
/// list, freeze and select them. Such rows carry this key (with the
/// note's nullifier) in [UTXO.otherData], use [_kShieldNoteVoutBase] +
/// the note's output index as vout (never a transparent vout) and are
/// kept out of the transparent balance and coin selection.
const kKerriganShieldNoteKey = "kerriganShieldNote";
const _kShieldNoteVoutBase = 1 << 20;

bool isKerriganShieldNote(UTXO utxo) =>
    utxo.otherData?.contains(kKerriganShieldNoteKey) ?? false;

String? _noteNullifier(UTXO utxo) {
  if (!isKerriganShieldNote(utxo)) return null;
  return (jsonDecode(utxo.otherData!) as Map)[kKerriganShieldNoteKey]
      as String?;
}

extension _KerriganShield on KerriganWallet {
  /// Spending needs the recovery phrase; a shield view only wallet
  /// watches with its viewing key.
  bool get _shieldSupported =>
      libKerriganShield.isAvailable && (!isViewOnly || isShieldViewOnly);

  String get _network => cryptoCurrency.shieldNetwork;

  /// Restored wallets scan from Sapling activation: Kerrigan's shield
  /// pool is young, so that is quick.
  int get _defaultShieldRestoreHeight => 0;

  /// ZIP 32 spending key of this wallet's account, from the full BIP39
  /// seed like Kerrigan Core derives it from its HD seed
  /// (`m_Sapling/32'/coin_type'/account'`), so the same recovery phrase
  /// finds the same shield funds in both.
  Future<String> _extsk() async => _extskFromSeed(await _seed());

  String _extskFromSeed(Uint8List seed) =>
      libKerriganShield.extendedSpendingKey(
        seed: seed,
        coinType: cryptoCurrency.coinType,
        accountIndex: account,
      );

  /// Full viewing key: derived when the wallet's shield state loads and
  /// kept in memory only (it reveals every shield transaction, past and
  /// future, so it isn't written to the state file). A shield view only
  /// wallet keeps its key in secure storage, like an xpub.
  Future<String> _extfvk() async {
    if (isShieldViewOnly) {
      final data = await getViewOnlyWalletData();
      return (data as SaplingViewingKeyViewOnlyWalletData).viewingKey;
    }
    return libKerriganShield.extendedFullViewingKey(extsk: await _extsk());
  }

  /// Row of the first address of the wallet's viewing key.
  Future<Address> _defaultShieldAddressRow() async => _shieldAddressRow(
    libKerriganShield.defaultAddress(
      extfvk: await _extfvk(),
      network: _network,
    ),
  );

  Future<KerriganShieldState> _createShieldState(
    int fromHeight, {
    required String extfvk,
  }) async {
    final cp = libKerriganShield.closestCheckpoint(
      height: fromHeight,
      network: _network,
    );
    final address = libKerriganShield.defaultAddress(
      extfvk: extfvk,
      network: _network,
    );
    final state = KerriganShieldState(
      extfvk: extfvk,
      network: _network,
      startHeight: cp.height,
      lastProcessedBlock: cp.height,
      commitmentTree: cp.tree,
      diversifierIndex: address.diversifierIndex,
      currentAddress: address.address,
    );
    await state.save(walletId);
    Logging.instance.i(
      "Kerrigan shield: new state for $walletId from checkpoint ${cp.height}",
    );
    return state;
  }

  /// Loaded (or newly created) shield state. A wallet without state was
  /// created in-app, so scanning starts near the current tip; restores
  /// reset the state in [KerriganWallet.recover].
  Future<KerriganShieldState> _loadShield() async =>
      _shield ??
      await (_shieldLoading ??= _readShield().whenComplete(
        () => _shieldLoading = null,
      ));

  Future<KerriganShieldState> _readShield() async {
    final extfvk = await _extfvk();
    var state = await KerriganShieldState.load(walletId, extfvk: extfvk);
    if (state == null) {
      int from = info.restoreHeight;
      if (from <= 0) {
        from = await chainHeight;
        if (from <= 0) from = await bridge.getBlockCount();
      }
      state = await _createShieldState(from, extfvk: extfvk);
    }
    await _storeShieldAddresses(state);
    _shield = state;
    // Notes scanned before the library reported txid/output index can't
    // be shown in coin control; rescan them once.
    if (state.unspentNotes.any(
      (n) => state!.nullifierNotes[n["nullifier"]]?["txid"] == null,
    )) {
      Logging.instance.i("Kerrigan shield: rescanning to index existing notes");
      await _resetShield(fromHeight: state.startHeight);
    }
    return _shield!;
  }

  /// Shield addresses are also kept as Isar [Address] rows (type
  /// [AddressType.kerriganShield]) so the address list, labels and the
  /// receive screen treat them like other addresses. Rows are ordered
  /// by the diversifier index.
  Address _shieldAddressRow(({String address, List<int> diversifierIndex}) a) {
    int index = 0;
    for (int i = min(6, a.diversifierIndex.length) - 1; i >= 0; i--) {
      index = index * 256 + a.diversifierIndex[i];
    }
    return Address(
      walletId: walletId,
      value: a.address,
      publicKey: const [],
      derivationIndex: index,
      derivationPath: null,
      type: AddressType.kerriganShield,
      subType: AddressSubType.receiving,
    );
  }

  /// Make sure every shield address handed out so far (default up to
  /// the current one) has a row; they are re-derived, as wallets made
  /// before rows existed only remember the current one.
  Future<void> _storeShieldAddresses(KerriganShieldState state) async {
    final stored =
        (await mainDB
                .getAddresses(walletId)
                .filter()
                .typeEqualTo(AddressType.kerriganShield)
                .valueProperty()
                .findAll())
            .toSet();
    if (stored.contains(state.currentAddress)) return;
    var a = libKerriganShield.defaultAddress(
      extfvk: state.extfvk,
      network: state.network,
    );
    final rows = [_shieldAddressRow(a)];
    for (int i = 0; i < 10000 && a.address != state.currentAddress; i++) {
      a = libKerriganShield.nextAddress(
        extfvk: state.extfvk,
        diversifierIndex: a.diversifierIndex,
        network: state.network,
      );
      rows.add(_shieldAddressRow(a));
    }
    await mainDB.updateOrPutAddresses(
      rows.where((e) => !stored.contains(e.value)).toList(),
    );
  }

  Future<void> _resetShield({required int fromHeight}) async {
    final extfvk = _shield?.extfvk ?? await _extfvk();
    await KerriganShieldState.delete(walletId);
    // The old state stays in use until the new one is ready.
    final state = await _createShieldState(fromHeight, extfvk: extfvk);
    _shield = state;
    await _storeShieldAddresses(state);
  }

  /// Where automatic shield change goes: the internal (change) key's
  /// address, as Kerrigan Core does. The scan tells change notes by their
  /// key, and a wallet restored in Kerrigan Core finds them too.
  String _shieldChangeAddress(KerriganShieldState state) => libKerriganShield
      .changeAddress(extfvk: state.extfvk, network: state.network);

  // ===========================================================================
  // Sync

  Future<void> _syncShield() async {
    if (!_shieldSupported) return;
    final state = await _loadShield();
    final walletTxids = <String>{};
    final scannedFrom = state.lastProcessedBlock;

    // Nothing to fetch until a new block is known (the chain height is
    // updated first on every refresh).
    final tip = await chainHeight;
    if (tip > state.lastProcessedBlock) {
      // Progress by height (the stream only has blocks with shield
      // data): 10 % to 95 % of the history step.
      final span = tip - scannedFrom;
      void progress(int height) =>
          _syncProgress(0.1 + 0.85 * (height - scannedFrom) / span);

      // A dropped connection resumes after the last saved batch.
      await retryShieldStream(
        position: () => state.lastProcessedBlock,
        onRetry: (e) => Logging.instance.w(
          "Kerrigan ${info.name}: shield stream failed after block "
          "${state.lastProcessedBlock}, resuming: $e",
        ),
        attempt: () async {
          // A cancel during a stalled stream lands here after the timeout.
          if (_recovering && _recoverCancelled) {
            throw Exception(l10n.restoreCancelled);
          }
          // The next batch downloads while the previous one is scanned (in
          // a background isolate); batches are still scanned one after
          // another.
          var batch = <KerriganShieldBlock>[];
          Future<void>? scanning;
          try {
            await for (final block in parseKerriganShieldStream(
              bridge.shieldData(
                state.lastProcessedBlock + 1,
                compact: !_shieldFullStream,
              ),
            )) {
              if (_recovering && _recoverCancelled) {
                throw Exception(l10n.restoreCancelled);
              }
              progress(block.height);
              batch.add(block);
              if (batch.length >= _kShieldBatchBlocks) {
                await scanning;
                scanning = _processShieldBlocks(state, batch, walletTxids)
                  // Errors surface at the next await, not as uncaught.
                  ..ignore();
                batch = [];
              }
            }
          } finally {
            // Never leave a scan running past this point, even on errors.
            await scanning;
          }
          if (batch.isNotEmpty) {
            await _processShieldBlocks(state, batch, walletTxids);
          }
        },
      );
      progress(tip);
    }

    // After a parser change, every shield tx is read again.
    if (_reparseHistory) walletTxids.addAll(state.txInfo.keys);
    if (walletTxids.isNotEmpty) {
      await _storeShieldHistory(walletTxids);
    }
    await _writeShieldNoteRows(state);

    // With shield funds, fetch the proving parameters ahead of the first
    // spend so sending doesn't wait on a ~50 MB download. A view only
    // wallet never spends.
    if (!isViewOnly &&
        state.unspentNotes.isNotEmpty &&
        !libKerriganShield.proverIsLoaded()) {
      unawaited(
        _ensureProver().catchError(
          (Object e) =>
              Logging.instance.w("Kerrigan: prover preload failed: $e"),
        ),
      );
    }
  }

  Future<void> _processShieldBlocks(
    KerriganShieldState state,
    List<KerriganShieldBlock> blocks,
    Set<String> walletTxids,
  ) async {
    final relevant = blocks
        .where((b) => b.height > state.lastProcessedBlock)
        .toList();
    if (relevant.isEmpty) return;

    final r = await UiStallWatch.run(
      "Kerrigan ${info.name}: shield blocks "
      "${relevant.first.height}-${relevant.last.height}",
      () => libKerriganShield.handleBlocks(
        tree: state.commitmentTree,
        blocks: [for (final b in relevant) b.txs],
        extfvk: state.extfvk,
        network: state.network,
        notes: state.unspentNotes,
      ),
    );

    final kept = [
      for (final n in r["decrypted_notes"] as List)
        Map<String, dynamic>.from(n as Map),
    ];
    final added = [
      for (final n in r["decrypted_new_notes"] as List)
        Map<String, dynamic>.from(n as Map),
    ];
    for (final n in added) {
      state.nullifierNotes[n["nullifier"] as String] = {
        "value": n["value"],
        "address": n["address"],
      };
    }
    final spent = Set<String>.from(r["nullifiers"] as List);
    state.unspentNotes = [
      ...kept,
      ...added,
    ].where((n) => !spent.contains(n["nullifier"])).toList();
    state.pendingSpent.removeWhere((_, nfs) => nfs.any(spent.contains));

    final walletTxs = [
      for (final w in r["wallet_transactions"] as List)
        Map<String, dynamic>.from(w as Map),
    ];
    await _findCompactTxids(walletTxs, relevant);
    for (final wtx in walletTxs) {
      final txid = wtx["txid"] as String;
      // Its notes are in [unspentNotes] now.
      state.pendingIncoming.remove(txid);
      for (final n in wtx["received"] as List) {
        final note = state.nullifierNotes[(n as Map)["nullifier"]];
        if (note != null) {
          note["txid"] = txid;
          note["index"] = n["index"];
        }
      }
      state.txInfo[txid] = {
        "received": [
          for (final n in wtx["received"] as List)
            {
              "value": (n as Map)["value"],
              "address": n["address"],
              "memo": n["memo"],
              "nullifier": n["nullifier"],
              "index": n["index"],
              "change": n["change"] == true,
            },
        ],
        "spentNullifiers": [
          for (final nf in wtx["nullifiers"] as List)
            if (state.nullifierNotes.containsKey(nf)) nf,
        ],
        // Shield outputs we sent to others (recovered with our ovk).
        "sent": [
          for (final n in wtx["sent"] as List? ?? const [])
            {
              "value": (n as Map)["value"],
              "address": n["address"],
              "memo": n["memo"],
            },
        ],
      };
      walletTxids.add(txid);
    }

    state.commitmentTree = r["commitment_tree"] as String;
    state.lastProcessedBlock = relevant.last.height;
    await state.save(walletId);
  }

  /// Compact stream packets carry no txid (the library leaves it empty):
  /// find each such wallet tx among its block's transactions by the
  /// nullifiers and note commitments it revealed. Without a match the
  /// stream and the chain disagree: the scan goes on from full
  /// transactions (see [retryShieldStream]).
  Future<void> _findCompactTxids(
    List<Map<String, dynamic>> walletTxs,
    List<KerriganShieldBlock> blocks,
  ) async {
    final blockParts = <int, Map<String, KerriganShieldParts>>{};
    for (final wtx in walletTxs) {
      if ((wtx["txid"] as String).isNotEmpty) continue;
      final height = blocks[(wtx["block"] as num).toInt()].height;
      final parts = blockParts[height] ??= await _blockShieldParts(height);
      final nullifiers = List<String>.from(wtx["nullifiers"] as List);
      final commitments = List<String>.from(wtx["commitments"] as List);
      final txid = parts.entries
          .where(
            (e) =>
                listEquals(e.value.nullifiers, nullifiers) &&
                listEquals(e.value.commitments, commitments),
          )
          .firstOrNull
          ?.key;
      if (txid == null) {
        _shieldFullStream = true;
        throw KerriganCompactStreamMismatch(
          "Kerrigan shield: no transaction of block $height matches the stream",
        );
      }
      wtx["txid"] = txid;
    }
  }

  /// [KerriganShieldParts] of every transaction in the block at [height],
  /// from raw transactions checked against their txids.
  Future<Map<String, KerriganShieldParts>> _blockShieldParts(int height) async {
    final txids = await bridge.blockTxids(height);
    final parts = <String, KerriganShieldParts>{};
    for (var i = 0; i < txids.length; i += KerriganWallet._kParallelRequests) {
      final ids = txids
          .skip(i)
          .take(KerriganWallet._kParallelRequests)
          .toList();
      final raws = await Future.wait(ids.map(bridge.rawTx));
      for (final (j, txid) in ids.indexed) {
        parts[txid] = kerriganVerifiedShieldParts(txid, raws[j]);
      }
    }
    return parts;
  }

  Future<void> _storeShieldHistory(Set<String> txids) async {
    final sets = await _addressSets();
    final ids = txids.toList();
    final fetched = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += KerriganWallet._kParallelRequests) {
      fetched.addAll(
        await Future.wait(
          ids.skip(i).take(KerriganWallet._kParallelRequests).map(bridge.tx),
        ),
      );
    }
    await _storeTxs([for (final json in fetched) ?_parseTx(json, sets: sets)]);
  }

  /// [UTXO] rows for the unspent notes (see [kKerriganShieldNoteKey]).
  /// Block data comes from the stored tx. Notes in a pending spend get
  /// no row ([MainDB.updateUTXOs] would keep a stale `used` flag).
  Future<List<UTXO>> _shieldNoteRows(KerriganShieldState state) async {
    final rows = <UTXO>[];
    final txs = await _storedTxs([
      for (final n in state.spendableNotes)
        if (state.nullifierNotes[n["nullifier"]]?["txid"] case final String t)
          t,
    ]);
    for (final n in state.spendableNotes) {
      final nf = n["nullifier"] as String;
      final meta = state.nullifierNotes[nf];
      final txid = meta?["txid"] as String?;
      if (txid == null) continue;
      final tx = txs[txid];
      final memo = n["memo"] as String?;
      rows.add(
        UTXO(
          walletId: walletId,
          txid: txid,
          vout: _kShieldNoteVoutBase + ((meta!["index"] as num?)?.toInt() ?? 0),
          value: (n["value"] as num).toInt(),
          name: "",
          isBlocked: false,
          blockedReason: null,
          isCoinbase: false,
          blockHash: tx?.blockHash,
          blockHeight: tx?.height,
          blockTime: tx?.timestamp,
          address: n["address"] as String?,
          otherData: jsonEncode({
            kKerriganShieldNoteKey: nf,
            if (memo != null && memo.isNotEmpty) "memo": memo,
          }),
        ),
      );
    }
    return rows;
  }

  Future<void> _writeShieldNoteRows(KerriganShieldState state) async {
    await _putUtxoRows(notes: await _shieldNoteRows(state));
  }

  /// Nullifiers of notes the user froze in coin control.
  Future<Set<String>> _frozenNullifiers() async => {
    for (final u
        in await mainDB
            .getUTXOs(walletId)
            .filter()
            .isBlockedEqualTo(true)
            .findAll())
      ?_noteNullifier(u),
  };

  /// Notes a shield spend may use: the coin-control selection if any,
  /// else every confirmed note not frozen or already being spent.
  Future<List<Map<String, dynamic>>> _notesToSpend(
    KerriganShieldState state,
    TxData txData,
  ) async {
    final notes = state.spendableNotes;
    final selected = (txData.utxos ?? const {})
        .whereType<StandardInput>()
        .map((e) => _noteNullifier(e.utxo))
        .nonNulls
        .toSet();
    if (selected.isNotEmpty) {
      final chosen = notes.where((n) => selected.contains(n["nullifier"]));
      if (chosen.length != selected.length) {
        throw Exception("Attempted to use an unavailable shield note");
      }
      return chosen.toList();
    }
    final frozen = await _frozenNullifiers();
    return notes.where((n) => !frozen.contains(n["nullifier"])).toList();
  }

  Future<void> _updateShieldBalance() async {
    if (!_shieldSupported) return;
    final state = await _loadShield();
    final frozen = await _frozenNullifiers();
    int total = 0;
    int blocked = 0;
    for (final n in state.spendableNotes) {
      final v = (n["value"] as num).toInt();
      total += v;
      if (frozen.contains(n["nullifier"])) blocked += v;
    }
    // Change (or a send to self) of sends still unconfirmed: without it
    // the balance dropped by the whole spent note until the next block.
    // Only while the send is unconfirmed in the history: a dropped send is
    // forgotten, a confirmed one is in the notes above.
    var pending = 0;
    if (state.pendingIncoming.isNotEmpty) {
      final unconfirmed = await mainDB.isar.transactionV2s
          .where()
          .walletIdEqualTo(walletId)
          .filter()
          .heightIsNull()
          .txidProperty()
          .findAll();
      for (final e in state.pendingIncoming.entries) {
        if (unconfirmed.contains(e.key)) pending += e.value;
      }
    }
    Amount amount(int v) => Amount(
      rawValue: BigInt.from(v),
      fractionDigits: cryptoCurrency.fractionDigits,
    );
    await info.updateBalanceSecondary(
      newBalance: Balance(
        total: amount(total + pending),
        spendable: amount(total - blocked),
        blockedTotal: amount(blocked),
        pendingSpendable: amount(pending),
      ),
      isar: mainDB.isar,
    );
  }

  // ===========================================================================
  // Sapling params

  Future<void> _ensureProver({
    void Function(double progress)? onProgress,
  }) async {
    if (libKerriganShield.proverIsLoaded()) return;
    // One download at a time: two would write the same files.
    if (onProgress != null) _proverProgress.add(onProgress);
    try {
      await (_proverLoading ??= _loadProver().whenComplete(
        () => _proverLoading = null,
      ));
    } finally {
      if (onProgress != null) _proverProgress.remove(onProgress);
    }
  }

  Future<void> _loadProver() async {
    void onProgress(double p) {
      for (final listener in [..._proverProgress]) {
        listener(p);
      }
    }

    final root = await StackFileSystem.applicationRootDirectory();
    final dir = Directory("${root.path}/sapling-params");
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final output = File("${dir.path}/sapling-output.params");
    final spend = File("${dir.path}/sapling-spend.params");

    // From the wallet's node (the fastest bridge, unless the user chose a
    // node); a file it can't give comes from the app's other bridges, then
    // from Zcash's download server (Kerrigan uses the Zcash Sapling
    // parameters).
    final sources = {
      bridge.baseUri.toString(),
      for (final node in cryptoCurrency.defaultNodes)
        KerriganBridgeClient.fromParts(
          host: node.host,
          port: node.port,
          useSSL: node.useSSL,
          useTor: false,
        ).baseUri.toString(),
      "https://download.z.cash/downloads",
    };
    // Sizes of the files whose hashes the prover checks.
    for (final (file, name, size, weight, base) in [
      (output, "sapling-output.params", 3592860, 0.07, 0.0),
      (spend, "sapling-spend.params", 47958396, 0.93, 0.07),
    ]) {
      if (file.existsSync()) continue;
      Object? lastError;
      for (final src in sources) {
        try {
          await KerriganBridgeClient.downloadToFile(
            Uri.parse("$src/$name"),
            file,
            maxBytes: size,
            // Per file: Tor may have been turned on meanwhile.
            proxy: bridge.useTor
                ? TorService.sharedInstance.getProxyInfo()
                : null,
            onProgress: (r, _) => onProgress(base + weight * r / size),
          );
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
        }
      }
      if (lastError != null)
        throw Exception(l10n.shieldDownloadFailed(name, "$lastError"));
    }
    try {
      await libKerriganShield.loadProver(
        outputParamsPath: output.path,
        spendParamsPath: spend.path,
      );
    } catch (_) {
      // Corrupt download: remove so the next attempt starts fresh.
      if (output.existsSync()) await output.delete();
      if (spend.existsSync()) await spend.delete();
      rethrow;
    }
  }

  // ===========================================================================
  // Send

  Future<TxData> _prepareShieldSend({
    required TxData txData,
    required bool fromShield,
  }) async {
    try {
      return await _buildShieldSend(txData: txData, fromShield: fromShield);
    } catch (e) {
      if (e.toString().contains("Not enough balance")) {
        throw Exception(l10n.sendInsufficientForFee);
      }
      if (e.toString().contains("below the dust limit")) {
        throw Exception(l10n.shieldTooSmallAfterFee);
      }
      rethrow;
    }
  }

  Future<TxData> _buildShieldSend({
    required TxData txData,
    required bool fromShield,
  }) async {
    final recipients = txData.recipients!;
    if (recipients.length != 1) {
      throw Exception(l10n.shieldSingleRecipient);
    }
    if (utf8.encode(txData.memo ?? "").length > 512) {
      throw Exception(l10n.shieldMemoTooLong);
    }
    final recipient = recipients.first;
    final state = await _loadShield();
    await _ensureProver();
    final own = (await mainDB.getAddresses(walletId).findAll())
        .map((e) => e.value)
        .toSet();

    final Map<String, dynamic> result;
    List<StandardInput> usedInputs = const [];
    final String changeAddress;
    // The automatic shield change address, which has no address row.
    String? ownChange;

    // The native library takes raw scripts as `script:<hex>`.
    String libAddress(String address) => isKerriganOpReturn(address)
        ? "script:${kerriganOpReturnScript(address).toHex}"
        : address;
    final extra = [
      for (final e
          in (txData.otherData == null
                  ? null
                  : (jsonDecode(txData.otherData!)
                            as Map)[kKerriganExtraOutputs]
                        as List?) ??
              const [])
        (
          address: (e as Map)["address"] as String,
          amount: (e["amount"] as num).toInt(),
        ),
    ];
    for (final e in extra) {
      if (!cryptoCurrency.isTransparentAddress(e.address)) {
        throw Exception("Extra outputs go to transparent addresses");
      }
    }

    if (fromShield) {
      final custom = txData.otherData == null
          ? null
          : (jsonDecode(txData.otherData!) as Map)[kKerriganChangeAddress]
                as String?;
      if (custom != null && custom.isNotEmpty) {
        if (!isShieldAddress(custom)) {
          throw Exception(l10n.shieldChangeMustBeShield);
        }
        changeAddress = custom;
      } else {
        changeAddress = _shieldChangeAddress(state);
        ownChange = changeAddress;
      }
      final notes = await _notesToSpend(state, txData);
      final available = notes.fold<int>(
        0,
        (p, n) => p + (n["value"] as num).toInt(),
      );
      if (available < recipient.amount.raw.toInt()) {
        throw Exception(l10n.shieldInsufficient);
      }
      result = await libKerriganShield.createTransaction(
        notes: notes,
        extsk: await _extsk(),
        toAddress: libAddress(recipient.address),
        extraOutputs: extra,
        changeAddress: changeAddress,
        amount: recipient.amount.raw.toInt(),
        network: state.network,
        memo: txData.memo ?? "",
        subtractFee: _otherDataFlag(txData, kKerriganSubtractFee),
        useAllInputs: txData.utxos?.isNotEmpty ?? false,
      );
    } else {
      changeAddress = await _transparentChangeAddress(txData);
      final selected = (txData.utxos ?? const {})
          .whereType<StandardInput>()
          .map((e) => e.utxo)
          .toList();
      final candidates = _spendable(
        selected.isNotEmpty
            ? selected
            : await mainDB.getUTXOs(walletId).findAll(),
        await chainHeight,
        collateral: selected.isNotEmpty,
      );
      if (selected.isNotEmpty && candidates.length != selected.length) {
        throw Exception("Attempted to use an unavailable utxo");
      }
      if (extra.isNotEmpty || isKerriganOpReturn(recipient.address)) {
        throw Exception(l10n.sendShieldOnly);
      }
      // Keys only for the coins the library will spend (all of a
      // coin-control selection).
      final needed = selected.isNotEmpty
          ? candidates
          : kerriganShieldingInputs(
              candidates,
              amount: recipient.amount.raw.toInt(),
              subtractFee: _otherDataFlag(txData, kKerriganSubtractFee),
            );
      final seed = await _seed();
      // Transparent inputs are signed with legacy signatures, which don't
      // commit to the value spent: _withKeys checks each value against
      // its previous transaction.
      final inputs = await _withKeys(
        needed,
        root: coinlib.HDPrivateKey.fromSeed(seed),
      );
      result = await libKerriganShield.createTransaction(
        utxos: [
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
        ],
        extsk: _extskFromSeed(seed),
        toAddress: recipient.address,
        changeAddress: changeAddress,
        amount: recipient.amount.raw.toInt(),
        network: state.network,
        memo: txData.memo ?? "",
        subtractFee: _otherDataFlag(txData, kKerriganSubtractFee),
        useAllInputs: selected.isNotEmpty,
      );
      final used = Set<String>.from(result["nullifiers"] as List);
      usedInputs = inputs
          .where((i) => used.contains("${i.utxo.txid},${i.utxo.vout}"))
          .toList();
    }

    final fee = BigInt.from(result["fee"] as int);
    final amount = BigInt.from(result["amount"] as int);
    final nullifiers = List<String>.from(result["nullifiers"] as List);
    final txid = result["txid"] as String;
    final digits = cryptoCurrency.fractionDigits;

    // Temporary history entry until the tx is seen on chain.
    final inputsTotal = fromShield
        ? nullifiers.fold(
            BigInt.zero,
            (p, nf) =>
                p +
                BigInt.from((state.nullifierNotes[nf]?["value"] as num?) ?? 0),
          )
        : usedInputs.fold(BigInt.zero, (p, i) => p + BigInt.from(i.utxo.value));
    final extraTotal = extra.fold(
      BigInt.zero,
      (p, e) => p + BigInt.from(e.amount),
    );
    final changeValue = inputsTotal - amount - fee - extraTotal;
    final tempInputs = [
      if (fromShield)
        for (final nf in nullifiers)
          InputV2.isarCantDoRequiredInDefaultConstructor(
            scriptSigHex: null,
            scriptSigAsm: null,
            sequence: null,
            outpoint: null,
            addresses: [state.nullifierNotes[nf]?["address"] as String? ?? ""],
            valueStringSats: "${state.nullifierNotes[nf]?["value"] ?? 0}",
            witness: null,
            innerRedeemScriptAsm: null,
            coinbase: null,
            walletOwns: true,
          )
      else
        for (final i in usedInputs)
          InputV2.isarCantDoRequiredInDefaultConstructor(
            scriptSigHex: null,
            scriptSigAsm: null,
            sequence: null,
            outpoint: OutpointV2.isarCantDoRequiredInDefaultConstructor(
              txid: i.utxo.txid,
              vout: i.utxo.vout,
            ),
            addresses: [i.utxo.address!],
            valueStringSats: "${i.utxo.value}",
            witness: null,
            innerRedeemScriptAsm: null,
            coinbase: null,
            walletOwns: true,
          ),
    ];
    final recipientIsOurs =
        own.contains(recipient.address) ||
        recipient.address == state.currentAddress;
    final changeIsOurs =
        changeAddress == ownChange || own.contains(changeAddress);
    // Shield notes have no script; transparent outputs keep theirs.
    String script(String address) => isShieldAddress(address)
        ? ""
        : isKerriganOpReturn(address)
        ? kerriganOpReturnScript(address).toHex
        : coinlib.Output.fromAddress(
            BigInt.zero,
            _parseAddress(address),
          ).scriptPubKey.toHex;
    final tempOutputs = [
      OutputV2.isarCantDoRequiredInDefaultConstructor(
        scriptPubKeyHex: script(recipient.address),
        valueStringSats: amount.toString(),
        addresses: isKerriganOpReturn(recipient.address)
            ? const []
            : [recipient.address],
        walletOwns: recipientIsOurs,
      ),
      for (final e in extra)
        OutputV2.isarCantDoRequiredInDefaultConstructor(
          scriptPubKeyHex: script(e.address),
          valueStringSats: "${e.amount}",
          addresses: [e.address],
          walletOwns: own.contains(e.address),
        ),
      if (changeValue > BigInt.zero)
        OutputV2.isarCantDoRequiredInDefaultConstructor(
          scriptPubKeyHex: script(changeAddress),
          valueStringSats: changeValue.toString(),
          addresses: [changeAddress],
          walletOwns: changeIsOurs,
        ),
    ];
    final tempClass = classifyKerriganTx(
      inputs: tempInputs,
      outputs: tempOutputs,
      changeAddresses: {changeAddress},
      fee: fee,
    )!;

    // What comes back to this wallet's shield addresses.
    var shieldIn = BigInt.zero;
    if (changeIsOurs && isShieldAddress(changeAddress)) {
      shieldIn += changeValue;
    }
    if (recipientIsOurs && isShieldAddress(recipient.address)) {
      shieldIn += amount;
    }

    final otherData = <String, dynamic>{
      if (txData.otherData != null)
        ...jsonDecode(txData.otherData!) as Map<String, dynamic>,
      _kOdShieldTx: true,
      _kOdShieldNullifiers: fromShield ? nullifiers : <String>[],
      if (shieldIn > BigInt.zero) _kOdShieldPendingIn: shieldIn.toInt(),
      if (!changeIsOurs && changeValue > BigInt.zero)
        kKerriganForeignChange: {
          "address": changeAddress,
          "sats": changeValue.toString(),
        },
    };

    return txData.copyWith(
      raw: result["txhex"] as String,
      txid: txid,
      fee: Amount(rawValue: fee, fractionDigits: digits),
      vSize: (result["txhex"] as String).length ~/ 2,
      recipients: [
        recipient.copyWith(
          amount: Amount(rawValue: amount, fractionDigits: digits),
        ),
      ],
      usedUTXOs: usedInputs,
      otherData: jsonEncode(otherData),
      tempTx: TransactionV2(
        walletId: walletId,
        blockHash: null,
        hash: txid,
        txid: txid,
        height: null,
        timestamp: DateTime.timestamp().millisecondsSinceEpoch ~/ 1000,
        inputs: List.unmodifiable(tempInputs),
        outputs: List.unmodifiable(tempOutputs),
        version: 3,
        type: tempClass.type,
        subType: TransactionSubType.none,
        otherData: jsonEncode(
          kerriganTxOtherData(
            c: tempClass,
            fractionDigits: digits,
            changeAddresses: {changeAddress},
            fee: fee,
            memo: isShieldAddress(recipient.address)
                ? txData.memo?.trim()
                : null,
            ownSend: true,
            rawTx: result["txhex"] as String,
          ),
        ),
      ),
    );
  }

  Future<TxData> _confirmShieldSend(TxData txData) async {
    final od = jsonDecode(txData.otherData!) as Map<String, dynamic>;
    final nullifiers = List<String>.from(
      od[_kOdShieldNullifiers] as List? ?? const [],
    );
    final pendingIn = (od[_kOdShieldPendingIn] as num?)?.toInt() ?? 0;
    final state = nullifiers.isEmpty && pendingIn == 0
        ? null
        : await _loadShield();
    final txid = await bridge.sendTx(txData.raw!);
    // Sent: its notes are spent from now on, even if saving that fails
    // (the state in memory is what the next send picks notes from).
    if (nullifiers.isNotEmpty) state?.pendingSpent[txid] = nullifiers;
    if (pendingIn > 0) state?.pendingIncoming[txid] = pendingIn;
    final sent = txData.copyWith(txid: txid, txHash: txid);
    // What follows only records the send. An error here must not read as
    // a failed send, or the user would pay again.
    try {
      if (state != null) {
        await state.save(walletId);
        await _writeShieldNoteRows(state);
      }
      final used = (txData.usedUTXOs ?? const [])
          .whereType<StandardInput>()
          .map((e) => e.utxo.copyWith(used: true))
          .toList();
      if (used.isNotEmpty) {
        await _utxoLock.protect(() => mainDB.putUTXOs(used));
      }
      final result = await updateSentCachedTxData(txData: sent);
      await updateBalance();
      return result;
    } catch (e, s) {
      Logging.instance.e(
        "Kerrigan: $txid sent, but recording it failed",
        error: e,
        stackTrace: s,
      );
      return sent;
    }
  }
}

/// The transparent coins the shield library spends to pay [amount] from
/// [candidates]: largest first, until they cover the amount and the fee
/// (with transparent change and two shield outputs), as its coin
/// selection does; all of them when they never do.
List<UTXO> kerriganShieldingInputs(
  List<UTXO> candidates, {
  required int amount,
  bool subtractFee = false,
}) {
  final sorted = [...candidates]..sort((a, b) => b.value.compareTo(a.value));
  var total = 0;
  for (var i = 0; i < sorted.length; i++) {
    total += sorted[i].value;
    final fee = KerriganWallet._shieldFee(tIn: i + 1, tOut: 1, spends: 0);
    if (total >= amount + (subtractFee ? 0 : fee)) {
      return sorted.sublist(0, i + 1);
    }
  }
  return sorted;
}
