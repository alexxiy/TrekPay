export '../generated/lib_kerrigan_shield_interface_impl.dart';

/// Kerrigan Sapling (shield) wallet core. Implemented by the
/// `flutter_libkerriganshield` plugin when the app is configured with the
/// KERRIGAN marker; otherwise every call throws.
///
/// [network] is "main", "test" or "regtest". Notes are opaque JSON maps
/// produced by the native library; each carries `value` (sat), `address`,
/// `nullifier`, `memo` and `scope` ("external", or "internal" for change).
abstract class LibKerriganShieldInterface {
  const LibKerriganShieldInterface();

  bool get isAvailable;

  /// ZIP 32 account spending key (hex) for a BIP39 [seed].
  String extendedSpendingKey({
    required List<int> seed,
    required int coinType,
    int accountIndex = 0,
  });

  /// Viewing key (hex) of a spending key.
  String extendedFullViewingKey({required String extsk});

  ({String address, List<int> diversifierIndex}) defaultAddress({
    required String extfvk,
    required String network,
  });

  /// Where shield change goes: the internal key's default address.
  String changeAddress({required String extfvk, required String network});

  ({String address, List<int> diversifierIndex}) nextAddress({
    required String extfvk,
    required List<int> diversifierIndex,
    required String network,
  });

  bool isValidAddress(String address, {required String network});

  ({int height, String tree}) closestCheckpoint({
    required int height,
    required String network,
  });

  Future<Map<String, dynamic>> handleBlocks({
    required String tree,
    required List<List<String>> blocks,
    required String extfvk,
    required String network,
    required List<Map<String, dynamic>> notes,
  });

  /// Display-order hex of the commitment tree's root.
  String saplingRoot(String tree);

  /// Kerrigan's Sapling fee for [spends] spends and [outputs] shield
  /// outputs (at least two: bundles are padded).
  int saplingFee({required int spends, required int outputs});

  Future<void> loadProver({
    required String outputParamsPath,
    required String spendParamsPath,
  });

  bool proverIsLoaded();

  Future<Map<String, dynamic>> createTransaction({
    List<Map<String, dynamic>>? notes,
    List<Map<String, dynamic>>? utxos,
    required String extsk,
    required String toAddress,
    // Empty: the wallet's internal shield address (spending notes).
    required String changeAddress,
    required int amount,
    required String network,
    String memo = "",
    // Spend every given note/UTXO (coin control selection).
    bool useAllInputs = false,
    // The recipient pays the fee (receives amount - fee).
    bool subtractFee = false,
    // More transparent outputs (shield notes only). An address may be
    // `script:<hex>` for a raw output script (e.g. OP_RETURN).
    List<({String address, int amount})> extraOutputs = const [],
  });

  // ---------------------------------------------------------------------------
  // Masternodes (DIP3) and governance

  /// BLS operator key pair from 32+ bytes of key material (IETF KeyGen):
  /// secret (32 bytes big-endian) and public key (48 bytes), hex.
  ({String secret, String public}) blsKeygen({required List<int> ikm});

  /// Public key (hex) of a BLS operator secret key (hex).
  String blsPublicKey(String secret);

  bool isValidBlsPublicKey(String key);

  /// Base64 compact signature of [message] with Kerrigan's message magic
  /// (`signmessage`).
  String signMessage({required List<int> privateKey, required String message});

  /// Base64 compact signature of a 32-byte hash (internal byte order).
  String signHash({required List<int> privateKey, required List<int> hash});

  /// Build and sign a provider transaction (ProRegTx, ProUpServTx,
  /// ProUpRegTx, ProUpRevTx); see the native `create_pro_tx`. Returns
  /// `txid`, `txhex`, `fee` and the spent UTXOs (`nullifiers`).
  Future<Map<String, dynamic>> createProTx(Map<String, dynamic> options);
}
