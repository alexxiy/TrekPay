import 'dart:convert';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/kerrigan_governance/kerrigan_governance_widgets.dart';
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

  test(
    "votes sign Core's vote string: outpoint|object|signal|outcome|time",
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
    },
  );

  test(
    "the OP_RETURN of a proposal fee holds the hash in Core's byte order",
    () {
      final script = kerriganOpReturnScript(
        "$kKerriganOpReturnPrefix${"01" + "00" * 31}",
      );
      expect(script.toHex, "6a20${"00" * 31}01");
      expect(isKerriganOpReturn("${kKerriganOpReturnPrefix}xyz"), isFalse);
    },
  );

  group("the wallet's masternodes on a proposal", () {
    KerriganMasternode mn(String label, int vout, {String? service}) =>
        KerriganMasternode(
          label: label,
          type: KerriganMasternodeType.regular,
          address: "yRd4FhXfVGHXpsuZXPNkMrfD9GVj46pnjt",
          txid: "ab" * 32,
          vout: vout,
          createdAt: 0,
          payoutAddress: "yRd4FhXfVGHXpsuZXPNkMrfD9GVj46pnjt",
          service: service,
        );

    test("their votes are picked from all of the proposal's", () {
      final a = mn("A", 0);
      final b = mn("B", 1);
      String v(
        String outpoint,
        int time,
        String outcome, [
        String signal = "funding",
      ]) => "$outpoint:$time:$outcome:$signal:1";
      final votes = kerriganOwnVotes(
        [
          v("${"ab" * 32}-0", 100, "yes"),
          // A changed its vote: the latest counts.
          v("${"ab" * 32}-0", 200, "no"),
          // Not a funding vote.
          v("${"ab" * 32}-1", 300, "yes", "delete"),
          v("${"ab" * 32}-1", 150, "abstain"),
          // Someone else's masternode.
          v("${"cd" * 32}-0", 400, "yes"),
          "not a vote",
        ],
        [a, b],
      );
      expect(votes.keys, unorderedEquals([a.id, b.id]));
      expect(votes[a.id]!.vote, KerriganVote.no);
      expect(votes[a.id]!.time, 200);
      expect(votes[b.id]!.vote, KerriganVote.abstain);
    });

    test("are searched by alias or server address", () {
      final m = mn("MN-Frankfurt", 0, service: "[2a01:4f8::1]:7120");
      expect(kerriganMasternodeMatches(m, ""), isTrue);
      expect(kerriganMasternodeMatches(m, " frank "), isTrue);
      expect(kerriganMasternodeMatches(m, "2A01:4F8"), isTrue);
      expect(kerriganMasternodeMatches(m, "7120"), isTrue);
      expect(kerriganMasternodeMatches(m, "berlin"), isFalse);
      // Not registered yet: no server address.
      expect(kerriganMasternodeMatches(mn("MN2", 1), "127.0"), isFalse);
    });

    test("are listed latest vote first, then those without a vote", () {
      final a = mn("A", 0);
      final b = mn("B", 1);
      final c = mn("C", 2);
      final d = mn("D", 3);
      final votes = {
        b.id: KerriganMasternodeVote(vote: KerriganVote.yes, time: 100),
        c.id: KerriganMasternodeVote(vote: KerriganVote.no, time: 200),
        // Voted in the same second as B: the wallet's order.
        d.id: KerriganMasternodeVote(vote: KerriganVote.abstain, time: 100),
      };
      expect(
        [
          for (final m in kerriganByLatestVote([d, a, b, c], votes)) m.label,
        ],
        ["C", "D", "B", "A"],
      );
    });

    test("short lists show every vote, long ones two and Show all", () {
      expect(
        [for (var n = 0; n <= 5; n++) kerriganVotesShownOf(n)],
        [0, 1, 2, 3, 2, 2],
      );
      expect(kerriganVotesShownOf(1000), 2);
    });
  });
}
