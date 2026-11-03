import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/kerrigan_name/kerrigan_name.dart';

import 'kerrigan_name_fixtures.dart';

String _hex(String s) =>
    utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, "0")).join();

String? _verify(Map<String, dynamic> record, [String name = "alice.krgn"]) =>
    verifyKerriganNameRecord(record, name, liveRoot);

void main() {
  group("names", () {
    final cases = {
      "alex.krgn": true,
      "richard.secure": true,
      "hello-world.safe": true,
      "krgn-123.private": true,
      "a.krgn": true,
      "${"a" * 59}.krgn": true,
      "${"a" * 60}.krgn": false,
      "al-ex.krgn": true,
      "ALEX.krgn": false, // the registry's spelling is lowercase
      "alex.krgn2": false,
      "alex.krgn.name": false,
      "alex": false,
      "": false,
      ".krgn": false,
      "-alex.krgn": false,
      "alex-.krgn": false,
      "al--ex.krgn": false,
      "al_ex.krgn": false,
      "alex!.krgn": false,
      "alex space.krgn": false,
      "alice.krgnfoo.safe": false,
      "alice..krgn": false,
      "ålex.krgn": false,
    };
    cases.forEach((name, valid) {
      test("isValidKerriganName($name) is $valid", () {
        expect(isValidKerriganName(name), valid);
      });
    });

    test("input is trimmed and lowercased once", () {
      expect(normalizeKerriganName("  Alice.KRGN "), "alice.krgn");
      expect(normalizeKerriganName("bad--name.krgn"), isNull);
      expect(looksLikeKerriganName("bad--name.Krgn"), isTrue);
      expect(looksLikeKerriganName(liveTarget), isFalse);
    });

    // Extend any valid name by any byte and the zone stops being a zone.
    // Without that, the name's place in a record's hash could slide even with
    // every other length fixed, so it is checked rather than assumed.
    test("no valid name is the start of another", () {
      const chars = ["a", "b", "z", "0", "-", "."];
      for (final zone in kKerriganNameZones) {
        for (final label in ["a", "ab", "a-b", "z0", "alice"]) {
          final name = "$label.$zone";
          var ext = [""];
          for (var depth = 0; depth < 3; depth++) {
            ext = [
              for (final e in ext)
                for (final c in chars) e + c,
            ];
            for (final e in ext) {
              expect(isValidKerriganName(name + e), isFalse, reason: name + e);
            }
          }
        }
      }
    });
  });

  group("target addresses", () {
    test("one mainnet Sapling address, exactly as the registry spells it", () {
      expect(isStrictKerriganNameTarget(liveTarget), isTrue);
      for (final bad in [
        liveTarget.substring(0, liveTarget.length - 1),
        "${liveTarget}a",
        liveTarget.toUpperCase(),
        "ks1${"q" * 75}",
        // the same payload with a bech32 (not bech32m) checksum
        "ks1l0c2g00waxlkde9l2s2jt86u7su0e0krndeh9deq42pwkz2hyqu0fm2t50lqv8q8sjv3xc5rw7v",
        // a padding bit set
        "ks1l0c2g00waxlkde9l2s2jt86u7su0e0krndeh9deq42pwkz2hyqu0fm2t50lqv8q8sjv38s78hxu",
        // testnet
        "ktestsapling1${liveTarget.substring(3)}",
      ]) {
        expect(isStrictKerriganNameTarget(bad), isFalse, reason: bad);
      }
    });

    test("the prefix the app tells people is the one targets really have", () {
      expect(liveTarget, startsWith(kKerriganNameTargetPrefix));
      final arbs = Directory("lib/l10n")
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith(".arb"));
      expect(arbs, hasLength(14));
      for (final arb in arbs) {
        final texts = jsonDecode(arb.readAsStringSync()) as Map;
        expect(
          texts["kerriganNamesShieldOnly"],
          contains(kKerriganNameTargetPrefix),
          reason: arb.path,
        );
      }
    });
  });

  group("records", () {
    test("the live records verify against the chain's root", () {
      expect(_verify(liveRecord()), liveTarget);
      // listed for sale: a price that takes all 8 bytes' worth of care
      expect(
        verifyKerriganNameRecord(donateRecord(), "donate.krgn", liveRoot),
        otherShieldAddress,
      );
      expect(
        verifyKerriganNameRecord(
          liveRecord(),
          "alice.krgn",
          "0x${liveRoot.toUpperCase()}",
        ),
        liveTarget,
      );
    });

    test("any changed field breaks it", () {
      final changes = <String, Object?>{
        "target_address": "ks1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
        "owner_pubkey":
            "a3a5f261984931e0df5c7434b16d468efb1953098d3cad4fa1506b9e052e7fc7",
        "price": 1,
        "nonce": 1786604914,
        "merkle_proof": [
          "8a82192137794bb5517a6555960e44c24297bc1b93db5190153539f8d724f8e2",
          "b425d835191c6b4f8335ad173b5c53ba24baca23e7efc5068ba91cd344ad4781",
          "65373c2edab2cca928c5d9df7bed8753ca4464c5b663b76859ad176cdfeac181",
        ],
        "domain_name": "alice.safe",
      };
      changes.forEach((field, value) {
        expect(_verify(liveRecord({field: value})), isNull, reason: field);
      });
      // A real address of the right shape that isn't the one committed to.
      expect(
        _verify(liveRecord({"target_address": otherShieldAddress})),
        isNull,
      );
      expect(_verify(liveRecord(), "alice.safe"), isNull);
    });

    test("a record folded for another name is refused", () {
      expect(
        verifyKerriganNameRecord(
          liveRecord({"domain_name": "donate.krgn"}),
          "donate.krgn",
          liveRoot,
        ),
        isNull,
      );
    });

    test("the depth must match the proof, and stay within 128", () {
      expect(_verify(liveRecord({"proof_depth": 2})), isNull);
      expect(_verify(liveRecord({"proof_depth": 4})), isNull);
      expect(_verify(liveRecord({"proof_depth": "3"})), isNull);
      final deep = List.filled(129, "00" * 32);
      expect(
        _verify(liveRecord({"merkle_proof": deep, "proof_depth": 129})),
        isNull,
      );
    });

    test("only an inclusion proof resolves a name", () {
      for (final terminal in <Object?>[
        "Vacant",
        "occupied",
        null,
        <String, Object>{"Blocked": <String, Object>{}},
      ]) {
        expect(
          _verify(liveRecord({"proof_terminal": terminal})),
          isNull,
          reason: "$terminal",
        );
      }
    });

    test("incomplete or malformed records are refused", () {
      for (final field in [
        "target_address",
        "owner_pubkey",
        "price",
        "nonce",
        "smt_root",
        "merkle_proof",
        "proof_depth",
        "proof_terminal",
        "domain_name",
      ]) {
        final record = liveRecord()..remove(field);
        expect(_verify(record), isNull, reason: field);
      }
      expect(verifyKerriganNameRecord(null, "alice.krgn", liveRoot), isNull);
      expect(verifyKerriganNameRecord("x", "alice.krgn", liveRoot), isNull);
      expect(
        _verify(
          liveRecord({
            "merkle_proof": ["zz" * 32, "00" * 32, "00" * 32],
          }),
        ),
        isNull,
      );
      expect(
        _verify(
          liveRecord({
            "merkle_proof": ["00" * 31, "00" * 32, "00" * 32],
          }),
        ),
        isNull,
      );
    });

    test("price and nonce must be exact u64 values", () {
      for (final bad in [
        -1,
        1.5,
        1786604913.0,
        "0x10",
        "1e3",
        " 1",
        "18446744073709551616",
        true,
        <String, dynamic>{},
      ]) {
        expect(_verify(liveRecord({"nonce": bad})), isNull, reason: "$bad");
      }
      // The decimal-string spelling of the same value is the same value.
      expect(_verify(liveRecord({"nonce": "1786604913"})), liveTarget);
    });
  });

  // The record's hash has no length prefixes, so these all hash to the same
  // bytes as the real record. Only the fixed field shapes stop them.
  group("field boundaries", () {
    test("undecodable characters after the owner key", () {
      expect(
        _verify(liveRecord({"owner_pubkey": "${liveOwnerKey}ZZZZ"})),
        isNull,
      );
    });

    test("an owner key that swallowed the start of the address", () {
      for (final k in [1, 5, 20, 40]) {
        final record = liveRecord({
          "owner_pubkey": liveOwnerKey + _hex(liveTarget.substring(0, k)),
          "target_address": liveTarget.substring(k),
        });
        expect(_verify(record), isNull, reason: "k=$k");
      }
    });

    test("an owner key shorter than 32 bytes", () {
      expect(
        _verify(liveRecord({"owner_pubkey": liveOwnerKey.substring(0, 60)})),
        isNull,
      );
    });

    test("a name that slides into the owner key", () {
      // hash_leaf("alice.krgnfoo.safe", P, ...) has the same bytes as
      // hash_leaf("alice.krgn", hex("foo.safe") + P, ...).
      expect(
        _verify(liveRecord({"owner_pubkey": _hex("foo.safe") + liveOwnerKey})),
        isNull,
      );
      expect(
        verifyKerriganNameRecord(
          liveRecord({"domain_name": "alice.krgnfoo.safe"}),
          "alice.krgnfoo.safe",
          liveRoot,
        ),
        isNull,
      );
    });
  });

  group("the root comes from the chain", () {
    test("never from the record", () {
      for (final root in ["", "not-a-root", "11" * 32, "00" * 32]) {
        expect(
          verifyKerriganNameRecord(liveRecord(), "alice.krgn", root),
          isNull,
          reason: root,
        );
      }
    });

    // A depth 0 proof whose root is its own leaf agrees with itself, and is
    // worth nothing against the chain's root. 5d0fba7d… is the record's
    // leaf hash.
    test("a self-rooted depth 0 proof", () {
      const leaf =
          "5d0fba7d07c708008261085bf9728d11c9a6fffa919982c1649b0781ccb41eae";
      final selfRooted = liveRecord({
        "merkle_proof": <String>[],
        "proof_depth": 0,
        "smt_root": leaf,
      });
      expect(
        verifyKerriganNameRecord(selfRooted, "alice.krgn", leaf),
        liveTarget,
      );
      expect(_verify(selfRooted), isNull);
    });

    // The name rule holds on its own, whatever root the caller trusts: a
    // record for a name the registry can't hold is refused even when it is
    // consistent with its root.
    test("never for a name the registry can't hold", () {
      const name = "alice.krgnfoo.safe";
      // its leaf, with the live record's other fields
      const leaf =
          "afaab737941a6435e378aca37897caa18751c61abd5b664e238c30346370219b";
      final selfRooted = liveRecord({
        "domain_name": name,
        "merkle_proof": <String>[],
        "proof_depth": 0,
        "smt_root": leaf,
      });
      expect(verifyKerriganNameRecord(selfRooted, name, leaf), isNull);
    });

    test("the record's own root must be the chain's", () {
      expect(_verify(liveRecord({"smt_root": "11" * 32})), isNull);
      expect(_verify(liveRecord({"smt_root": null})), isNull);
    });
  });

  test("roots are 32 bytes of hex", () {
    expect(parseKerriganNameRoot("0x${"AB" * 32}"), "ab" * 32);
    expect(parseKerriganNameRoot("ab" * 31), isNull);
    expect(parseKerriganNameRoot("${"ab" * 32}0"), isNull);
    expect(parseKerriganNameRoot("zz" * 32), isNull);
    expect(parseKerriganNameRoot(42), isNull);
  });
}
