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

  test("memo from a hand-written URI", () {
    final parsed = AddressUtils.parsePaymentUri(
      "kerrigan:$address?memo=coffee%20money",
    )!;
    expect(parsed.additionalParams["memo"], "coffee money");
  });
}
