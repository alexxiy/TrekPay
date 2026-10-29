import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan/kerrigan_tx_parser.dart';

/// Little-endian bytes of [v] over [n] bytes.
List<int> le(int v, int n) => [
  for (int i = 0; i < n; i++) (v >> (8 * i)) & 0xff,
];

Uint8List tx({
  required List<int> version,
  required List<int> values,
  List<int> tail = const [],
}) {
  final script = List.filled(25, 0x76); // P2PKH-sized dummy script
  return Uint8List.fromList([
    ...version,
    2, // two inputs
    for (int i = 0; i < 2; i++) ...[
      ...List.filled(32, i + 1), // prev txid
      ...le(i, 4), // prev vout
      107, ...List.filled(107, 0xaa), // scriptSig
      ...le(0xffffffff, 4),
    ],
    values.length,
    for (final v in values) ...[...le(v, 8), script.length, ...script],
    ...le(0, 4), // nLockTime
    ...tail,
  ]);
}

void main() {
  test("output values of a legacy transaction", () {
    final raw = tx(version: le(1, 4), values: [1000000000000, 12345]);
    expect(kerriganTxOutputs(raw).map((e) => e.value), [
      BigInt.from(1000000000000),
      BigInt.from(12345),
    ]);
  });

  test(
    "output values of a Sapling (type 10) transaction ignore the payload",
    () {
      final raw = tx(
        version: [3, 0, 10, 0], // nVersion 3, nType 10
        values: [5000],
        tail: [200, ...List.filled(200, 0x42)], // vExtraPayload
      );
      expect(kerriganTxOutputs(raw).map((e) => e.value), [BigInt.from(5000)]);
    },
  );

  test("a truncated transaction is rejected", () {
    final raw = tx(version: le(1, 4), values: [1, 2, 3]);
    expect(
      () => kerriganTxOutputs(Uint8List.sublistView(raw, 0, raw.length - 40)),
      throwsA(anything),
    );
  });

  group("shield parts", () {
    String hex(List<int> b) =>
        b.map((e) => e.toRadixString(16).padLeft(2, "0")).join();

    // Spend: cv, anchor, nullifier, rk (32 each), proof 192, signature 64.
    List<int> spend(int nf) => [
      ...List.filled(64, 0x11),
      ...List.filled(32, nf),
      ...List.filled(32 + 192 + 64, 0x22),
    ];
    // Output: cv, cmu, epk (32 each), enc 580, out 80, proof 192.
    List<int> output(int cmu) => [
      ...List.filled(32, 0x33),
      ...List.filled(32, cmu),
      ...List.filled(32 + 580 + 80 + 192, 0x44),
    ];

    /// The Sapling payload (vExtraPayload of a type 10 transaction) with
    /// its CompactSize length in front.
    List<int> payload(
      List<int> spends,
      List<int> outputs, {
      int cut = 0,
      List<int> extra = const [],
    }) {
      final body = [
        ...le(1, 2), // payload version
        spends.length ~/ 384, ...spends,
        outputs.length ~/ 948, ...outputs,
        ...le(-7000, 8), // valueBalance
        ...List.filled(64, 0x55), // bindingSig
        ...extra,
      ];
      final n = body.length - cut;
      return [
        ...(n < 0xfd ? [n] : [0xfd, ...le(n, 2)]),
        ...body.take(n),
      ];
    }

    test("nullifiers and commitments of a Sapling transaction", () {
      final raw = tx(
        version: [3, 0, 10, 0], // nVersion 3, nType 10
        values: [5000],
        tail: payload([...spend(0xa1), ...spend(0xa2)], output(0xc1)),
      );
      final parts = kerriganTxShieldParts(raw);
      expect(parts.nullifiers, [
        hex(List.filled(32, 0xa1)),
        hex(List.filled(32, 0xa2)),
      ]);
      expect(parts.commitments, [hex(List.filled(32, 0xc1))]);
    });

    test("transactions without shield data have none", () {
      for (final raw in [
        tx(version: le(1, 4), values: [1]),
        tx(version: [3, 0, 0, 0], values: [1]),
        // Another special transaction type: its payload isn't Sapling.
        tx(version: [3, 0, 1, 0], values: [1], tail: [3, 1, 2, 3]),
      ]) {
        final parts = kerriganTxShieldParts(raw);
        expect(parts.nullifiers, isEmpty);
        expect(parts.commitments, isEmpty);
      }
    });

    test("a Sapling payload of the wrong length is rejected", () {
      final short = tx(
        version: [3, 0, 10, 0],
        values: [1],
        tail: payload([], output(1), cut: 1),
      );
      expect(() => kerriganTxShieldParts(short), throwsA(anything));
      final long = tx(
        version: [3, 0, 10, 0],
        values: [1],
        tail: payload([], output(1), extra: [0]),
      );
      expect(() => kerriganTxShieldParts(long), throwsFormatException);
    });
  });
}
