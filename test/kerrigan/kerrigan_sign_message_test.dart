import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/settings_views/wallet_settings_view/sign_message_view.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  final coin = Kerrigan(CryptoCurrencyNetwork.regtest);

  // From a Kerrigan Core regtest node: dumpprivkey, then
  // signmessagewithprivkey (verifymessage accepts it).
  const wif = "cQvkLEFiQFc3d8B6WJJKQn1vuz54PZw8R2DsH46RiEdf5kUCy8Xj";
  const address = "yh18gwPqi6yMwJYG37TZS44aiHajqPr9D8";
  const message = "Sign me: Astronaut ✓\nline two";
  const signature =
      "II5E4rMuPrv7hUrs7mV00EVe2ONOoEDwYbIfFlEnapkXdVTCQ3oGN6VRYckodAKjQERkobdpHD9RssDT6Cwwy/w=";

  test("Kerrigan signs messages with Core's prefix", () {
    expect(signedMessageMagic(coin), "DarkCoin Signed Message:\n");
  });

  test("a signature matches Kerrigan Core's", () {
    final key = coinlib.WIF.fromString(wif).privkey;
    final signed = coinlib.MessageSignature.sign(
      key: key,
      message: message,
      prefix: signedMessageMagic(coin),
    );
    expect(signed.toString(), signature);
  });

  test("Kerrigan Core's signature verifies, a changed message doesn't", () {
    final a = coinlib.Address.fromString(address, coin.networkParams);
    final s = coinlib.MessageSignature.fromBase64(signature);
    final prefix = signedMessageMagic(coin);
    expect(s.verifyAddress(address: a, message: message, prefix: prefix), true);
    expect(
      s.verifyAddress(address: a, message: "$message ", prefix: prefix),
      false,
    );
  });
}
