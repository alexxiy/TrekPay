import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:paymint/db/hive/db.dart';
import 'package:paymint/networking/http.dart';
import 'package:paymint/services/price.dart';
import 'package:paymint/utilities/format.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';

import 'hive/hive_ce_test_utils.dart';
import 'price_test.mocks.dart';

// The answers trimmed from vote.kerrigan.network/api/price and CoinGecko's
// exchange_rates.
const _priceJson =
    '{"last":0.01589521774318484,"targetVolume":1006.18,'
    '"exchanges":["Nestex","SafeTrade","NonKYC","NonKYC (SOL)"],'
    '"perExchange":[{"exchange":"Nestex","last":0.01694691,"volume":233.3,'
    '"bid":0.01684986,"ask":0.01736305}],"fetchedAt":1793295705077}';
const _ratesJson =
    '{"rates":{"btc":{"name":"Bitcoin","unit":"BTC","value":1,"type":'
    '"crypto"},"usd":{"name":"US Dollar","unit":"\$","value":80000.0,'
    '"type":"fiat"},"eur":{"name":"Euro","unit":"€","value":72000.0,'
    '"type":"fiat"}}}';

const _headers = {'Content-Type': 'application/json'};

@GenerateMocks([HTTP])
void main() {
  setUp(() async {
    await setUpHiveCeTest();
    await DB.instance.hive.openBox<dynamic>(DB.boxNamePriceCache);
    await DB.instance.hive.openBox<dynamic>(DB.boxNamePrefs);
    await DB.instance.put<dynamic>(
      boxName: DB.boxNamePrefs,
      key: "externalCalls",
      value: true,
    );
  });

  tearDown(() async {
    await tearDownHiveCeTest();
  });

  void answer(MockHTTP client, Uri url, String body, {int code = 200}) {
    when(client.get(url: url, headers: _headers, proxyInfo: null))
        .thenAnswer((_) async => Response(utf8.encode(body), code));
  }

  void verifyCalled(MockHTTP client, Uri url, int times) {
    verify(client.get(url: url, headers: _headers, proxyInfo: null))
        .called(times);
  }

  Future<Map<CryptoCurrency, CoinPrice>> fetch(
    MockHTTP client,
    String currency,
  ) {
    final api = PriceAPI(client);
    api.resetLastCalledToForceNextCallToUpdateCache();
    return api.getPricesAnd24hChange(baseCurrency: currency);
  }

  void expectKrgnPrice(Map<CryptoCurrency, CoinPrice> prices, String value) {
    // Only mainnet Kerrigan has a price; testnet and regtest coins have none.
    expect(prices.length, 1);
    final entry = prices.entries.single;
    expect(entry.key, isA<Kerrigan>());
    expect(entry.key.network, CryptoCurrencyNetwork.main);
    expect(entry.value.value, Decimal.parse(value));
    // The price source has no 24 hour change.
    expect(entry.value.change24h, isNull);
  }

  test("the price in US dollars is vote.kerrigan.network's last", () async {
    final client = MockHTTP();
    answer(client, PriceAPI.kerriganPriceUrl, _priceJson);

    expectKrgnPrice(await fetch(client, "USD"), "0.01589521774318484");

    verifyCalled(client, PriceAPI.kerriganPriceUrl, 1);
    verifyNoMoreInteractions(client);
  });

  test("other currencies go through CoinGecko's rates", () async {
    final client = MockHTTP();
    answer(client, PriceAPI.kerriganPriceUrl, _priceJson);
    answer(client, PriceAPI.exchangeRatesUrl, _ratesJson);

    // 0.01589521774318484 * 72000 / 80000, cut to 12 decimals
    expectKrgnPrice(await fetch(client, "EUR"), "0.014305695968");
    // A crypto base works the same way: 0.01589521774318484 / 80000
    expectKrgnPrice(await fetch(client, "btc"), "0.000000198690");

    verifyCalled(client, PriceAPI.kerriganPriceUrl, 2);
    verifyCalled(client, PriceAPI.exchangeRatesUrl, 2);
    verifyNoMoreInteractions(client);
  });

  test("a second call within a minute comes from the cache", () async {
    final client = MockHTTP();
    answer(client, PriceAPI.kerriganPriceUrl, _priceJson);

    final api = PriceAPI(client);
    api.resetLastCalledToForceNextCallToUpdateCache();
    await api.getPricesAnd24hChange(baseCurrency: "USD");
    final cached = await api.getPricesAnd24hChange(baseCurrency: "USD");

    expectKrgnPrice(cached, "0.01589521774318484");
    verifyCalled(client, PriceAPI.kerriganPriceUrl, 1);
    verifyNoMoreInteractions(client);
  });

  test("a failed fetch keeps the price in the same currency", () async {
    final client = MockHTTP();
    answer(client, PriceAPI.kerriganPriceUrl, _priceJson);
    await fetch(client, "USD");

    answer(client, PriceAPI.kerriganPriceUrl, "Bad Gateway", code: 502);
    expectKrgnPrice(await fetch(client, "USD"), "0.01589521774318484");
  });

  test("a cached price in another currency isn't shown", () async {
    final client = MockHTTP();
    answer(client, PriceAPI.kerriganPriceUrl, _priceJson);
    await fetch(client, "USD");

    when(
      client.get(
        url: PriceAPI.exchangeRatesUrl,
        headers: _headers,
        proxyInfo: null,
      ),
    ).thenThrow(const SocketException("Failed host lookup"));
    expect(await fetch(client, "EUR"), isEmpty);
  });

  test("a currency CoinGecko has no rate for gets no price", () async {
    final client = MockHTTP();
    answer(client, PriceAPI.kerriganPriceUrl, _priceJson);
    answer(client, PriceAPI.exchangeRatesUrl, _ratesJson);

    expect(await fetch(client, "gbp"), isEmpty);
  });

  test("answers without a usable price give none", () async {
    for (final body in [
      '{"error":"busy"}',
      '{"last":0}',
      '{"last":-1.5}',
      '{"last":"0.0159"}',
      '[]',
      'not json',
    ]) {
      final client = MockHTTP();
      answer(client, PriceAPI.kerriganPriceUrl, body);
      expect(await fetch(client, "USD"), isEmpty, reason: body);
    }
  });

  test("no internet available", () async {
    final client = MockHTTP();
    when(
      client.get(
        url: PriceAPI.kerriganPriceUrl,
        headers: _headers,
        proxyInfo: null,
      ),
    ).thenThrow(
      const SocketException(
        "Failed host lookup: 'vote.kerrigan.network' (OS Error: Temporary "
        "failure in name resolution, errno = -3)",
      ),
    );

    expect(await fetch(client, "USD"), isEmpty);
  });

  test("unit prices show three significant digits below 1", () {
    int decimals(String price) => Format.priceDecimals(Decimal.parse(price));
    expect(decimals("15.2"), 2);
    expect(decimals("1"), 2);
    expect(decimals("0.159"), 3);
    expect(decimals("0.0159"), 4);
    expect(decimals("0.00000019869"), 9);
    expect(decimals("0"), 2);
  });
}
