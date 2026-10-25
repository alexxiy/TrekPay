import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/kerrigan_donation/kerrigan_donation.dart';
import 'package:paymint/widgets/kerrigan_memo_field.dart';

Decimal _d(String s) => Decimal.parse(s);

void main() {
  group("kerriganDonationKrgn", () {
    final price = _d("0.306");

    test("three significant digits", () {
      expect(kerriganDonationKrgn(_d("1"), price), _d("3.27"));
      expect(kerriganDonationKrgn(_d("20"), price), _d("65.4"));
    });

    test("whole KRGN from 100 up", () {
      expect(kerriganDonationKrgn(_d("100"), price), _d("327"));
      expect(kerriganDonationKrgn(_d("1000"), price), _d("3268"));
    });

    test("below 1 KRGN, two digits after the first that isn't zero", () {
      expect(kerriganDonationKrgn(_d("0.01"), _d("0.327")), _d("0.0306"));
      expect(kerriganDonationKrgn(_d("0.1"), _d("0.2")), _d("0.5"));
    });

    test("nothing for nothing", () {
      expect(kerriganDonationKrgn(Decimal.zero, price), Decimal.zero);
      expect(kerriganDonationKrgn(_d("5"), Decimal.zero), Decimal.zero);
    });
  });

  test("the surprises", () {
    expect(KerriganDonationEgg.of(Decimal.zero), null);
    expect(KerriganDonationEgg.of(_d("0.5")), KerriganDonationEgg.lowBattery);
    expect(KerriganDonationEgg.of(_d("1")), null);
    expect(
      KerriganDonationEgg.of(_d("4.04")),
      KerriganDonationEgg.fuelNotFound,
    );
    expect(KerriganDonationEgg.of(_d("4.05")), null);
    expect(KerriganDonationEgg.of(_d("249.99")), null);
    expect(KerriganDonationEgg.of(_d("250")), KerriganDonationEgg.overload);
  });

  test("a custom amount gets the biggest tier it pays for", () {
    expect(KerriganDonationTier.artFor(_d("0.5")), KerriganDonationTier.spark);
    expect(KerriganDonationTier.artFor(_d("1")), KerriganDonationTier.spark);
    expect(KerriganDonationTier.artFor(_d("7")), KerriganDonationTier.cell);
    expect(
      KerriganDonationTier.artFor(_d("20")),
      KerriganDonationTier.hyperdrive,
    );
    expect(
      KerriganDonationTier.artFor(_d("99.99")),
      KerriganDonationTier.surge,
    );
    expect(
      KerriganDonationTier.artFor(_d("1000")),
      KerriganDonationTier.flight,
    );
  });

  test("the art follows the balance it's paid from", () {
    expect(
      KerriganDonationTier.cell.art(shielded: false),
      "assets/donation/public_t5.webp",
    );
    expect(
      KerriganDonationTier.flight.art(shielded: true),
      "assets/donation/private_t100.webp",
    );
    expect(
      KerriganDonationTier.custom.art(shielded: true),
      "assets/donation/private_custom.webp",
    );
  });

  test("dollars", () {
    expect(kerriganDonationUsdText(_d("20"), "en"), r"$20");
    expect(kerriganDonationUsdText(_d("12.5"), "en"), r"$12.50");
    expect(kerriganDonationUsdText(_d("1234"), "xx"), r"$1,234");
  });

  test("the address, cut", () {
    expect(kerriganDonationShortAddress("ks1short"), "ks1short");
    expect(
      kerriganDonationShortAddress("ks1qxyz0123456789abcdefk9fz3a"),
      "ks1qxyz0…k9fz3a",
    );
  });

  group("kerriganDonationMemo", () {
    test("a tag line for the developer, in the mode's names", () {
      expect(
        kerriganDonationMemo(
          tier: KerriganDonationTier.hyperdrive,
          shielded: false,
          usd: _d("20"),
        ),
        r"Fuel Delta: $20 · Quantum Hyperdrive",
      );
      expect(
        kerriganDonationMemo(
          tier: KerriganDonationTier.hyperdrive,
          shielded: true,
          usd: _d("20"),
        ),
        r"Fuel Delta: $20 · Zero-Knowledge Aegis",
      );
      expect(
        kerriganDonationMemo(
          tier: KerriganDonationTier.custom,
          shielded: false,
          usd: _d("12.5"),
        ),
        r"Fuel Delta: $12.50 · Limitless Nova",
      );
      expect(
        kerriganDonationMemo(tier: KerriganDonationTier.custom, shielded: true),
        "Fuel Delta: Infinite Citadel",
      );
    });

    test("then the cheers message, trimmed", () {
      expect(
        kerriganDonationMemo(
          tier: KerriganDonationTier.cell,
          shielded: false,
          usd: _d("5"),
          message: "  Great work! 🚀\n",
        ),
        "Fuel Delta: \$5 · Power Cell\nGreat work! 🚀",
      );
      expect(
        kerriganDonationMemo(
          tier: KerriganDonationTier.cell,
          shielded: false,
          usd: _d("5"),
          message: "   ",
        ),
        r"Fuel Delta: $5 · Power Cell",
      );
    });

    test("a full cheers message fits with the longest tag", () {
      final message = "😀" * (kKerriganDonationMessageBytes ~/ 4);
      final memo = kerriganDonationMemo(
        tier: KerriganDonationTier.custom,
        shielded: true,
        usd: _d("999999999999.99"),
        message: message,
      );
      expect(
        memo,
        "Fuel Delta: \$999999999999.99 · Infinite Citadel\n$message",
      );
      expect(utf8Length(memo), lessThanOrEqualTo(kKerriganMaxMemoBytes));
    });

    test("too long: the dollars go, then the message is cut", () {
      final ascii = kerriganDonationMemo(
        tier: KerriganDonationTier.cell,
        shielded: false,
        usd: _d("5"),
        message: "a" * 500,
      );
      expect(ascii, "Fuel Delta: Power Cell\n${"a" * 489}");
      expect(utf8Length(ascii), kKerriganMaxMemoBytes);

      final emoji = kerriganDonationMemo(
        tier: KerriganDonationTier.cell,
        shielded: false,
        usd: _d("5"),
        message: "😀" * 130,
      );
      // 23 bytes of tag leave 489: 122 whole emoji.
      expect(emoji, "Fuel Delta: Power Cell\n${"😀" * 122}");
      expect(utf8Length(emoji), lessThanOrEqualTo(kKerriganMaxMemoBytes));
    });
  });
}
