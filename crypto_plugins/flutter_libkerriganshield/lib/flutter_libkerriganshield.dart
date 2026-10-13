/// Kerrigan Sapling (shield) wallet core via dart:ffi.
///
/// The native library exposes one JSON entry point; this file wraps it
/// in typed helpers. Heavy calls (block scanning, proving) should go
/// through the `*Async` variants, which run on a background isolate.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class KerriganShieldException implements Exception {
  KerriganShieldException(this.method, this.message);

  final String method;
  final String message;

  @override
  String toString() => "KerriganShieldException($method): $message";
}

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

/// Override to load the library from a custom path (e.g. host tests).
String? kerriganShieldLibraryPathOverride;

DynamicLibrary _open() {
  final override = kerriganShieldLibraryPathOverride ??
      Platform.environment["KERRIGAN_SHIELD_LIB"];
  if (override != null) return DynamicLibrary.open(override);
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open("libkerrigan_shield_ffi.so");
  }
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  if (Platform.isWindows) return DynamicLibrary.open("kerrigan_shield_ffi.dll");
  throw UnsupportedError("Unsupported platform");
}

DynamicLibrary? _lib;
_CallNative? _call;
_FreeDart? _free;

void _ensureLoaded() {
  if (_call != null) return;
  _lib = _open();
  _call = _lib!.lookupFunction<_CallNative, _CallNative>(
    "kerrigan_shield_call",
  );
  _free = _lib!.lookupFunction<_FreeNative, _FreeDart>("kerrigan_shield_free");
}

/// Synchronous call into the native library. Returns the decoded `ok`
/// value or throws [KerriganShieldException].
dynamic kerriganShieldCall(String method, Map<String, dynamic> args) {
  _ensureLoaded();
  final m = method.toNativeUtf8();
  final a = jsonEncode(args).toNativeUtf8();
  try {
    final r = _call!(m, a);
    final text = r.toDartString();
    _free!(r);
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (json.containsKey("err")) {
      throw KerriganShieldException(method, json["err"].toString());
    }
    return json["ok"];
  } finally {
    malloc.free(m);
    malloc.free(a);
  }
}

/// [kerriganShieldCall] on a background isolate.
Future<dynamic> kerriganShieldCallAsync(
  String method,
  Map<String, dynamic> args,
) {
  final libOverride = kerriganShieldLibraryPathOverride;
  return Isolate.run(() {
    kerriganShieldLibraryPathOverride = libOverride;
    return kerriganShieldCall(method, args);
  });
}

/// Typed helpers. [network] is "main", "test" or "regtest". Notes are
/// opaque JSON maps produced by the library; each carries `value` (sat),
/// `address`, `nullifier`, `memo` and `scope`.
abstract final class KerriganShield {
  static String version() => kerriganShieldCall("version", {}) as String;

  /// ZIP 32 account spending key for a BIP39 [seed] (the full seed, as
  /// Kerrigan Core uses its HD seed). Hex of the 169-byte key, the same
  /// as Kerrigan Core's `z_exportkey`.
  static String extendedSpendingKey({
    required List<int> seed,
    required int coinType,
    int accountIndex = 0,
  }) =>
      kerriganShieldCall("generate_extsk", {
        "seed_hex": _hex(seed),
        "coin_type": coinType,
        "account_index": accountIndex,
      }) as String;

  /// Viewing key of [extsk]: hex of the 128-byte key, the same as Kerrigan
  /// Core's `z_exportviewingkey`.
  static String extendedFullViewingKey({required String extsk}) =>
      kerriganShieldCall("generate_extfvk", {"key": extsk}) as String;

  static ({String address, List<int> diversifierIndex}) defaultAddress({
    required String extfvk,
    required String network,
  }) =>
      _address(
        kerriganShieldCall(
            "default_address", {"key": extfvk, "network": network}),
      );

  /// The change address: the internal key's default address (Kerrigan
  /// Core sends change there too).
  static String changeAddress({
    required String extfvk,
    required String network,
  }) =>
      kerriganShieldCall("change_address", {"key": extfvk, "network": network})
          as String;

  static ({String address, List<int> diversifierIndex}) nextAddress({
    required String extfvk,
    required List<int> diversifierIndex,
    required String network,
  }) =>
      _address(
        kerriganShieldCall("next_address", {
          "extfvk": extfvk,
          "diversifier_index": diversifierIndex,
          "network": network,
        }),
      );

  static bool isValidAddress(String address, {required String network}) =>
      kerriganShieldCall("validate_address", {
        "address": address,
        "network": network,
      }) as bool;

  static ({int height, String tree}) closestCheckpoint({
    required int height,
    required String network,
  }) {
    final r = kerriganShieldCall("closest_checkpoint", {
      "height": height,
      "network": network,
    }) as Map;
    return (height: r["height"] as int, tree: r["tree"] as String);
  }

  /// Scan [blocks] (lists of raw tx hex) on a background isolate.
  /// Returns `decrypted_notes` (still-tracked notes, witnesses updated),
  /// `decrypted_new_notes`, `nullifiers` (all spent in these blocks),
  /// `commitment_tree` and `wallet_transactions`.
  static Future<Map<String, dynamic>> handleBlocks({
    required String tree,
    required List<List<String>> blocks,
    required String extfvk,
    required String network,
    required List<Map<String, dynamic>> notes,
  }) async {
    final r = await kerriganShieldCallAsync("handle_blocks", {
      "tree": tree,
      "blocks": [
        for (final b in blocks) {"txs": b},
      ],
      "extfvk": extfvk,
      "network": network,
      "notes": notes,
    });
    return Map<String, dynamic>.from(r as Map);
  }

  /// Display-order hex of the tree root.
  static String saplingRoot(String tree) {
    final raw = kerriganShieldCall("sapling_root", {"tree": tree}) as String;
    final bytes = <String>[];
    for (int i = 0; i < raw.length; i += 2) {
      bytes.add(raw.substring(i, i + 2));
    }
    return bytes.reversed.join();
  }

  static int saplingFee({required int spends, required int outputs}) =>
      kerriganShieldCall("sapling_fee", {"spends": spends, "outputs": outputs})
          as int;

  static Future<void> loadProver({
    required String outputParamsPath,
    required String spendParamsPath,
  }) async {
    await kerriganShieldCallAsync("load_prover", {
      "output_path": outputParamsPath,
      "spend_path": spendParamsPath,
    });
  }

  static bool proverIsLoaded() =>
      kerriganShieldCall("prover_is_loaded", {}) as bool;

  /// Build and prove a transaction on a background isolate. Exactly one
  /// of [notes] or [utxos] is given. Each utxo: `txid`, `vout`, `amount`,
  /// `private_key` (hex), `script` (hex, P2PKH). An empty
  /// [changeAddress] sends shield change to the wallet's internal
  /// address. Returns `txid`, `txhex`, `nullifiers`, `fee`, `amount`.
  static Future<Map<String, dynamic>> createTransaction({
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
  }) async {
    final r = await kerriganShieldCallAsync("create_transaction", {
      "notes": notes,
      "utxos": utxos,
      "extsk": extsk,
      "to_address": toAddress,
      "change_address": changeAddress,
      "amount": amount,
      "network": network,
      "memo": memo,
      "use_all_inputs": useAllInputs,
      "subtract_fee": subtractFee,
    });
    return Map<String, dynamic>.from(r as Map);
  }

  static ({String address, List<int> diversifierIndex}) _address(dynamic r) {
    final m = r as Map;
    return (
      address: m["address"] as String,
      diversifierIndex: List<int>.from(m["diversifier_index"] as List),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join();
}
