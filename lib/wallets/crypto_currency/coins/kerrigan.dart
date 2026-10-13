import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;

import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../models/node_model.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/default_nodes.dart';
import '../../../utilities/enums/derive_path_type_enum.dart';
import '../../../wl_gen/interfaces/lib_kerrigan_shield_interface.dart';
import '../crypto_currency.dart';
import '../intermediate/bip39_hd_currency.dart';

/// Kerrigan (KRGN). Chain parameters follow Kerrigan Core
/// `src/chainparams.cpp` (v1.3.2); Kerrigan is Dash-based, with Sapling
/// shielded transactions (special transaction type 10).
///
/// Keys: BIP39 seeds, BIP44 `m/44'/99888'/account'` for transparent
/// addresses (coin type 1 on testnet and regtest) and ZIP 32
/// `m_Sapling/32'/99888'/account'` from the full seed for the shield, the
/// way Kerrigan Core derives them from its HD seed.
///
/// Network data comes from a kerrigan-bridge instance (shield stream + RPC
/// proxy + transparent address index), configured as this coin's node:
/// `host` is the full base URL, e.g. `https://bridge.example.org/mainnet`.
///
/// Unlike PIVX, Kerrigan regtest has its own address prefixes, so it is
/// a network of its own ([CryptoCurrencyNetwork.regtest]).
class Kerrigan extends Bip39HDCurrency {
  Kerrigan(super.network) {
    _idMain = "kerrigan";
    _uriScheme = "kerrigan";
    switch (network) {
      case CryptoCurrencyNetwork.main:
        _id = _idMain;
        _name = "Kerrigan";
        _ticker = "KRGN";
      case CryptoCurrencyNetwork.test:
        _id = "kerriganTestNet";
        _name = "tKerrigan";
        _ticker = "tKRGN";
      case CryptoCurrencyNetwork.regtest:
        _id = "kerriganRegTest";
        _name = "rKerrigan";
        _ticker = "rKRGN";
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  late final String _id;
  @override
  String get identifier => _id;

  late final String _idMain;
  @override
  String get mainNetId => _idMain;

  late final String _name;
  @override
  String get prettyName => _name;

  late final String _uriScheme;
  @override
  String get uriScheme => _uriScheme;

  late final String _ticker;
  @override
  String get ticker => _ticker;

  @override
  int get minConfirms => 1;

  /// Coinbase outputs mature after 100 blocks (`COINBASE_MATURITY`).
  @override
  int get minCoinbaseConfirms => 101;

  @override
  bool get torSupport => true;

  @override
  List<DerivePathType> get supportedDerivationPathTypes => [
    DerivePathType.bip44,
  ];

  /// Genesis hash of the network a node must serve.
  List<String> get acceptedGenesisHashes => [genesisHash];

  @override
  String get genesisHash {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return "00000444f8dbee14c599ac723b35cc8021b12d48d092c7ac67d45f6d8a0b9c32";
      case CryptoCurrencyNetwork.test:
        return "0013e791b16aa0491287b31d15c788d867a11d11031dac96842021d2213deb28";
      case CryptoCurrencyNetwork.regtest:
        return "3ba0907345a612be65d57a008ca271bc7f5f4d71559afde8e8f309587bc9b48a";
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  /// Kerrigan Core's dust threshold for P2PKH at its 3000 sat/kB dust
  /// relay fee: (34 + 148) bytes * 3 sat/byte.
  @override
  Amount get dustLimit =>
      Amount(rawValue: BigInt.from(546), fractionDigits: fractionDigits);

  /// Minimum relay fee (sat per byte, Kerrigan Core's 1000 sat/kB).
  /// Transparent transactions pay this; shield transactions pay
  /// Kerrigan's Sapling fee (see the shield library).
  int get minFeePerByte => 1;

  /// Name of the network for the shield library.
  String get shieldNetwork => switch (network) {
    CryptoCurrencyNetwork.main => "main",
    CryptoCurrencyNetwork.test => "test",
    CryptoCurrencyNetwork.regtest => "regtest",
    _ => throw Exception("Unsupported network: $network"),
  };

  /// ZIP 32 / BIP44 coin type.
  int get coinType => network == CryptoCurrencyNetwork.main ? 99888 : 1;

  /// Sapling shield address human-readable part (Bech32m).
  String get shieldHrp => switch (network) {
    CryptoCurrencyNetwork.main => "ks",
    CryptoCurrencyNetwork.test => "ktestsapling",
    CryptoCurrencyNetwork.regtest => "kregsapling",
    _ => throw Exception("Unsupported network: $network"),
  };

  @override
  coinlib.Network get networkParams {
    // Extended keys use the Bitcoin `xpub`/`tpub` serialisation, as
    // Kerrigan Core does.
    final (wif, p2pkh, p2sh, priv, pub) = switch (network) {
      CryptoCurrencyNetwork.main => (204, 45, 16, 0x0488ade4, 0x0488b21e),
      CryptoCurrencyNetwork.test => (239, 107, 19, 0x04358394, 0x043587cf),
      CryptoCurrencyNetwork.regtest => (239, 140, 19, 0x04358394, 0x043587cf),
      _ => throw Exception("Unsupported network: $network"),
    };
    return coinlib.Network(
      wifPrefix: wif,
      p2pkhPrefix: p2pkh,
      p2shPrefix: p2sh,
      privHDPrefix: priv,
      pubHDPrefix: pub,
      bech32Hrp: shieldHrp,
      messagePrefix: "\x19DarkCoin Signed Message:\n",
      minFee: BigInt.from(1000),
      minOutput: dustLimit.raw,
      feePerKb: BigInt.from(1000),
    );
  }

  @override
  String constructDerivePath({
    required DerivePathType derivePathType,
    int account = 0,
    required int chain,
    required int index,
  }) {
    switch (derivePathType) {
      case DerivePathType.bip44:
        return "m/44'/$coinType'/$account'/$chain/$index";
      default:
        throw Exception("DerivePathType $derivePathType not supported");
    }
  }

  @override
  ({coinlib.Address address, AddressType addressType}) getAddressForPublicKey({
    required coinlib.ECPublicKey publicKey,
    required DerivePathType derivePathType,
  }) {
    switch (derivePathType) {
      case DerivePathType.bip44:
        final addr = coinlib.P2PKHAddress.fromPublicKey(
          publicKey,
          version: networkParams.p2pkhPrefix,
        );
        return (address: addr, addressType: AddressType.p2pkh);
      default:
        throw Exception("DerivePathType $derivePathType not supported");
    }
  }

  @override
  bool validateAddress(String address) {
    return isTransparentAddress(address) || isShieldAddress(address);
  }

  /// Sapling address (`ks1…`). Needs the shield library; without it
  /// shield addresses are rejected.
  bool isShieldAddress(String address) {
    if (!address.startsWith("${shieldHrp}1")) return false;
    return libKerriganShield.isAvailable &&
        libKerriganShield.isValidAddress(address, network: shieldNetwork);
  }

  bool isTransparentAddress(String address) {
    try {
      final a = coinlib.Address.fromString(address, networkParams);
      return a is coinlib.P2PKHAddress || a is coinlib.P2SHAddress;
    } catch (_) {
      return false;
    }
  }

  @override
  AddressType? getAddressType(String address) {
    if (isShieldAddress(address)) return AddressType.kerriganShield;
    try {
      final a = coinlib.Address.fromString(address, networkParams);
      if (a is coinlib.P2PKHAddress) return AddressType.p2pkh;
      if (a is coinlib.P2SHAddress) return AddressType.p2sh;
    } catch (_) {}
    return null;
  }

  @override
  NodeModel defaultNode({required bool isPrimary}) {
    final String host;
    switch (network) {
      case CryptoCurrencyNetwork.main:
        // TODO: the public mainnet bridge, once one runs with ADDR_INDEX.
        host = "https://bridge.kerrigan.network";
      case CryptoCurrencyNetwork.test:
        // TODO: a public testnet bridge.
        host = "https://bridge.kerrigan.network/testnet";
      case CryptoCurrencyNetwork.regtest:
        // Development bridge (regtest node on the test VM).
        host = "http://192.168.1.27:3001";
      default:
        throw Exception("Unsupported network: $network");
    }
    final uri = Uri.parse(host);
    return NodeModel(
      host: host,
      port: uri.port,
      name: DefaultNodes.defaultName,
      id: DefaultNodes.buildId(this),
      useSSL: uri.scheme == "https",
      enabled: true,
      coinName: identifier,
      isFailover: true,
      isDown: false,
      torEnabled: true,
      clearnetEnabled: true,
      isPrimary: isPrimary,
    );
  }

  @override
  int get defaultSeedPhraseLength => 12;

  @override
  int get fractionDigits => 8;

  @override
  bool get hasBuySupport => false;

  @override
  bool get hasMnemonicPassphraseSupport => true;

  @override
  List<int> get possibleMnemonicLengths => [defaultSeedPhraseLength, 24];

  @override
  AddressType get defaultAddressType => defaultDerivePathType.getAddressType();

  @override
  BigInt get satsPerCoin => BigInt.from(100000000);

  @override
  int get targetBlockTimeSeconds => 120;

  @override
  DerivePathType get defaultDerivePathType => DerivePathType.bip44;

  @override
  Uri defaultBlockExplorer(String txid) {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return Uri.parse("https://explorer.kerrigan.network/#/tx/$txid");
      case CryptoCurrencyNetwork.test:
      case CryptoCurrencyNetwork.regtest:
        // No public explorer; the user can set one in the settings.
        return Uri.parse("https://explorer.kerrigan.network/#/tx/$txid");
      default:
        throw Exception(
          "Unsupported network for defaultBlockExplorer(): $network",
        );
    }
  }
}
