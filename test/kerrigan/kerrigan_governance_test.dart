import 'dart:convert';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/amount/amount.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan_wallet.dart';

void main() {
  setUpAll(coinlib.loadCoinlib);

  test("proposal data is the JSON Kerrigan Core validates", () {
    final hex = kerriganProposalDataHex(
      type: KerriganProposalType.proposal,
      name: "exchange-listing",
      url: "https://kerrigan.network/p/1",
      paymentAddress: "yRd4FhXfVGHXpsuZXPNkMrfD9GVj46pnjt",
      amount: Amount.fromDecimal(Decimal.parse("2500.5"), fractionDigits: 8),
      startEpoch: 1791800000,
      endEpoch: 1794392000,
    );
    final data = jsonDecode(utf8.decode(hex.toUint8ListFromHex)) as Map;
    expect(data, {
      "end_epoch": 1794392000,
      "name": "exchange-listing",
      "payment_address": "yRd4FhXfVGHXpsuZXPNkMrfD9GVj46pnjt",
      "payment_amount": 2500.5,
      "start_epoch": 1791800000,
      "type": 1,
      "url": "https://kerrigan.network/p/1",
    });

    // Growth fund releases have no voting window.
    final release = jsonDecode(
      utf8.decode(
        kerriganProposalDataHex(
          type: KerriganProposalType.escrowRelease,
          name: "listing",
          url: "https://kerrigan.network/p/2",
          paymentAddress: "yRd4FhXfVGHXpsuZXPNkMrfD9GVj46pnjt",
          amount: Amount.fromDecimal(Decimal.fromInt(50000), fractionDigits: 8),
        ).toUint8ListFromHex,
      ),
    ) as Map;
    expect(release["type"], 3);
    expect(release.containsKey("end_epoch"), isFalse);
  });

  test("the object hash covers the data and time", () {
    final a = kerriganProposalHash(dataHex: "7b7d", time: 1);
    expect(a, hasLength(64));
    expect(kerriganProposalHash(dataHex: "7b7d", time: 2), isNot(a));
    expect(kerriganProposalHash(dataHex: "7b7e", time: 1), isNot(a));
  });

  test("votes sign Core's vote string: outpoint|object|signal|outcome|time",
      () {
    expect(
      kerriganVoteMessage(
        collateralTxid: "ab" * 32,
        collateralVout: 1,
        objectHash: "cd" * 32,
        vote: KerriganVote.no,
        time: 1791800000,
      ),
      "${"ab" * 32}-1|${"cd" * 32}|1|2|1791800000",
    );
    expect(KerriganVote.parse("ABSTAIN"), KerriganVote.abstain);
  });

  test("the OP_RETURN of a proposal fee holds the hash in Core's byte order",
      () {
    final script = kerriganOpReturnScript(
      "$kKerriganOpReturnPrefix${"01" + "00" * 31}",
    );
    expect(script.toHex, "6a20${"00" * 31}01");
    expect(isKerriganOpReturn("${kKerriganOpReturnPrefix}xyz"), isFalse);
  });
}
