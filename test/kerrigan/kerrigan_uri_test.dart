import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/utilities/address_utils.dart';

void main() {
  const address =
      "kregsapling1j9s20dpe62kr0jhfvnqua3j8wv873ccy7u3l3fuwgvc8l4yy0dqpnaknkp3g0uaj0jynjpyc6ul";

  test("shield memo survives a payment URI round trip", () {
    const memo = "Invoice #42: 100% paid & thanks";
    final uri = AddressUtils.buildUriString("kerrigan", address, {
      "amount": "1.5",
      "memo": memo,
    });
    final parsed = AddressUtils.parsePaymentUri(uri)!;
    expect(parsed.address, address);
    expect(parsed.amount, "1.5");
    expect(parsed.additionalParams["memo"], memo);
  });

  test("memos are ZIP 321 base64url, as Kerrigan Core writes them", () {
    final uri = AddressUtils.buildUriString("kerrigan", address, {
      "memo": "coffee money",
    });
    expect(uri, "kerrigan:$address?memo=Y29mZmVlIG1vbmV5");
    // Kerrigan Core's Send page omits the padding; padded works too.
    for (final m in ["Y29mZmVlIG1vbmV5", "VGhhbmtzIQ", "VGhhbmtzIQ=="]) {
      final parsed = AddressUtils.parsePaymentUri("kerrigan:$address?memo=$m");
      expect(parsed, isNotNull, reason: m);
    }
    expect(
      AddressUtils.parsePaymentUri(
        "kerrigan:$address?memo=VGhhbmtzIQ",
      )!.additionalParams["memo"],
      "Thanks!",
    );
    // Non-ASCII text and characters base64url has instead of + and /.
    const text = "Café ☕ <>?";
    expect(AddressUtils.decodeMemo(AddressUtils.encodeMemo(text)), text);
    expect(AddressUtils.encodeMemo("<<???>>"), isNot(contains("/")));
  });

  test("a URI with an unreadable memo is refused, like Kerrigan Core does",
      () {
    for (final m in ["not base64!", "_w", "a+b/", "AABB" * 200]) {
      expect(
        AddressUtils.parsePaymentUri("kerrigan:$address?memo=$m"),
        isNull,
        reason: m,
      );
    }
    // Trailing zero padding is dropped.
    expect(AddressUtils.decodeMemo("aGkAAA"), "hi");
  });
}
