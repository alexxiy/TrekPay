//ON
import 'package:flutter_libkerriganshield/flutter_libkerriganshield.dart';

//END_ON
import '../interfaces/lib_kerrigan_shield_interface.dart';

LibKerriganShieldInterface get libKerriganShield => _getInterface();

//OFF
LibKerriganShieldInterface _getInterface() => const _Unavailable();

class _Unavailable extends LibKerriganShieldInterface {
  const _Unavailable();

  static Never _no() => throw Exception("Kerrigan shield not enabled!");

  @override
  bool get isAvailable => false;
  @override
  String extendedSpendingKey({
    required List<int> seed,
    required int coinType,
    int accountIndex = 0,
  }) => _no();
  @override
  String extendedFullViewingKey({required String extsk}) => _no();
  @override
  ({String address, List<int> diversifierIndex}) defaultAddress({
    required String extfvk,
    required String network,
  }) => _no();
  @override
  String changeAddress({required String extfvk, required String network}) =>
      _no();
  @override
  ({String address, List<int> diversifierIndex}) nextAddress({
    required String extfvk,
    required List<int> diversifierIndex,
    required String network,
  }) => _no();
  @override
  bool isValidAddress(String address, {required String network}) => false;
  @override
  ({int height, String tree}) closestCheckpoint({
    required int height,
    required String network,
  }) => _no();
  @override
  Future<Map<String, dynamic>> handleBlocks({
    required String tree,
    required List<List<String>> blocks,
    required String extfvk,
    required String network,
    required List<Map<String, dynamic>> notes,
  }) => _no();
  @override
  String saplingRoot(String tree) => _no();
  @override
  int saplingFee({required int spends, required int outputs}) => _no();
  @override
  Future<void> loadProver({
    required String outputParamsPath,
    required String spendParamsPath,
  }) => _no();
  @override
  bool proverIsLoaded() => false;
  @override
  Future<Map<String, dynamic>> createTransaction({
    List<Map<String, dynamic>>? notes,
    List<Map<String, dynamic>>? utxos,
    required String extsk,
    required String toAddress,
    required String changeAddress,
    required int amount,
    required String network,
    String memo = "",
    bool useAllInputs = false,
    bool subtractFee = false,
  }) => _no();
}

//END_OFF
//ON
LibKerriganShieldInterface _getInterface() => const _Impl();

class _Impl extends LibKerriganShieldInterface {
  const _Impl();

  @override
  bool get isAvailable => true;

  @override
  String extendedSpendingKey({
    required List<int> seed,
    required int coinType,
    int accountIndex = 0,
  }) => KerriganShield.extendedSpendingKey(
    seed: seed,
    coinType: coinType,
    accountIndex: accountIndex,
  );

  @override
  String extendedFullViewingKey({required String extsk}) =>
      KerriganShield.extendedFullViewingKey(extsk: extsk);

  @override
  ({String address, List<int> diversifierIndex}) defaultAddress({
    required String extfvk,
    required String network,
  }) => KerriganShield.defaultAddress(extfvk: extfvk, network: network);

  @override
  String changeAddress({required String extfvk, required String network}) =>
      KerriganShield.changeAddress(extfvk: extfvk, network: network);

  @override
  ({String address, List<int> diversifierIndex}) nextAddress({
    required String extfvk,
    required List<int> diversifierIndex,
    required String network,
  }) => KerriganShield.nextAddress(
    extfvk: extfvk,
    diversifierIndex: diversifierIndex,
    network: network,
  );

  @override
  bool isValidAddress(String address, {required String network}) =>
      KerriganShield.isValidAddress(address, network: network);

  @override
  ({int height, String tree}) closestCheckpoint({
    required int height,
    required String network,
  }) => KerriganShield.closestCheckpoint(height: height, network: network);

  @override
  Future<Map<String, dynamic>> handleBlocks({
    required String tree,
    required List<List<String>> blocks,
    required String extfvk,
    required String network,
    required List<Map<String, dynamic>> notes,
  }) => KerriganShield.handleBlocks(
    tree: tree,
    blocks: blocks,
    extfvk: extfvk,
    network: network,
    notes: notes,
  );

  @override
  String saplingRoot(String tree) => KerriganShield.saplingRoot(tree);

  @override
  int saplingFee({required int spends, required int outputs}) =>
      KerriganShield.saplingFee(spends: spends, outputs: outputs);

  @override
  Future<void> loadProver({
    required String outputParamsPath,
    required String spendParamsPath,
  }) => KerriganShield.loadProver(
    outputParamsPath: outputParamsPath,
    spendParamsPath: spendParamsPath,
  );

  @override
  bool proverIsLoaded() => KerriganShield.proverIsLoaded();

  @override
  Future<Map<String, dynamic>> createTransaction({
    List<Map<String, dynamic>>? notes,
    List<Map<String, dynamic>>? utxos,
    required String extsk,
    required String toAddress,
    required String changeAddress,
    required int amount,
    required String network,
    String memo = "",
    bool useAllInputs = false,
    bool subtractFee = false,
  }) => KerriganShield.createTransaction(
    notes: notes,
    utxos: utxos,
    extsk: extsk,
    toAddress: toAddress,
    changeAddress: changeAddress,
    amount: amount,
    network: network,
    memo: memo,
    useAllInputs: useAllInputs,
    subtractFee: subtractFee,
  );
}

//END_ON
