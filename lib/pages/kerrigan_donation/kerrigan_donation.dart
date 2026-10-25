import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../../app_config.dart';
import '../../l10n/l10n.dart';
import '../../models/isar/models/isar_models.dart';
import '../../networking/http.dart';
import '../../services/kerrigan_name/kerrigan_name_resolver.dart';
import '../../services/tor_service.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/assets.dart';
import '../../utilities/logger.dart';
import '../../utilities/prefs.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/kerrigan_memo_field.dart';

// "Fuel Delta": donations to TrekPay's developer, straight from the wallet
// (ported from PIVXie's "Fuel PIVXie"). The tiers are in US dollars; the
// KRGN amount follows the price. Paid from the shielded balance, the
// dark, shielded Delta gets the power; from the transparent one, the
// light one.

/// Where donations go: a Kerrigan name of TrekPay's developer, looked up
/// and checked like any name typed on the send screen.
const kKerriganDonationName = "alexxiy.kerrigan";

/// Whether [coin]'s wallets can donate: where Kerrigan names resolve
/// (nowhere until the names service is in).
bool kerriganDonationAvailable(CryptoCurrency coin) =>
    KerriganNameService.forCoin(coin) != null;

/// The cheers message: what the 512-byte memo has room for after the
/// tag line (at most 63 bytes, see [kerriganDonationMemo]).
const kKerriganDonationMessageBytes = 448;

enum KerriganDonationTier {
  spark(1, "✨", "Tiny Spark", "Tiny Shield"),
  cell(5, "🔋", "Power Cell", "Shield Cell"),
  console(10, "💻", "Cyber Console", "Cyber Node"),
  hyperdrive(20, "🕶️", "Quantum Hyperdrive", "Zero-Knowledge Aegis"),
  surge(50, "⚡️", "Cosmic Surge", "Quantum Aegis"),
  flight(100, "🚀", "Astro Flight", "Stealth Flight"),
  custom(null, "🌌", "Limitless Nova", "Infinite Citadel");

  const KerriganDonationTier(
    this.usd,
    this.emoji,
    this._memoName,
    this._memoNameShielded,
  );

  /// The price in dollars; null for the custom amount.
  final int? usd;
  final String emoji;
  final String _memoName;
  final String _memoNameShielded;

  static const fixed = [spark, cell, console, hyperdrive, surge, flight];

  bool get isCustom => usd == null;

  /// The name in the memo, which the developer reads in English.
  String memoName({required bool shielded}) =>
      shielded ? _memoNameShielded : _memoName;

  String title({required bool shielded}) => shielded
      ? switch (this) {
          spark => l10n.donateTinyShield,
          cell => l10n.donateShieldCell,
          console => l10n.donateCyberNode,
          hyperdrive => l10n.donateZeroKnowledgeAegis,
          surge => l10n.donateQuantumAegis,
          flight => l10n.donateStealthFlight,
          custom => l10n.donateInfiniteCitadel,
        }
      : switch (this) {
          spark => l10n.donateTinySpark,
          cell => l10n.donatePowerCell,
          console => l10n.donateCyberConsole,
          hyperdrive => l10n.donateQuantumHyperdrive,
          surge => l10n.donateCosmicSurge,
          flight => l10n.donateAstroFlight,
          custom => l10n.donateLimitlessNova,
        };

  String description({required bool shielded}) => shielded
      ? switch (this) {
          spark => l10n.donateTinyShieldText,
          cell => l10n.donateShieldCellText,
          console => l10n.donateCyberNodeText,
          hyperdrive => l10n.donateZeroKnowledgeAegisText,
          surge => l10n.donateQuantumAegisText,
          flight => l10n.donateStealthFlightText,
          custom => l10n.donateInfiniteCitadelText,
        }
      : switch (this) {
          spark => l10n.donateTinySparkText,
          cell => l10n.donatePowerCellText,
          console => l10n.donateCyberConsoleText,
          hyperdrive => l10n.donateQuantumHyperdriveText,
          surge => l10n.donateCosmicSurgeText,
          flight => l10n.donateAstroFlightText,
          custom => l10n.donateLimitlessNovaText,
        };

  /// The mascot of [usd] dollars: the biggest tier it pays for.
  static KerriganDonationTier artFor(Decimal usd) => fixed.lastWhere(
    (t) => Decimal.fromInt(t.usd!) <= usd,
    orElse: () => spark,
  );

  /// The tier's picture: the dark, shielded Delta when paid from the
  /// shielded balance, the light one from the transparent one.
  String art({required bool shielded}) => isCustom
      ? Assets.donation.custom(shielded: shielded)
      : Assets.donation.tier(usd!, shielded: shielded);
}

/// Custom amounts with a surprise.
enum KerriganDonationEgg {
  /// Under a dollar.
  lowBattery,

  /// Exactly $4.04.
  fuelNotFound,

  /// $250 and up.
  overload;

  static KerriganDonationEgg? of(Decimal usd) {
    if (usd <= Decimal.zero) return null;
    if (usd < Decimal.one) return lowBattery;
    if ((usd * Decimal.fromInt(100)).round() == Decimal.fromInt(404)) {
      return fuelNotFound;
    }
    if (usd >= Decimal.fromInt(250)) return overload;
    return null;
  }

  String get text => switch (this) {
    lowBattery => l10n.donateEggLowBattery,
    fuelNotFound => l10n.donateEggFuelNotFound,
    overload => l10n.donateEggOverload,
  };
}

/// [usd] dollars in KRGN at [price] dollars a KRGN, rounded to three
/// significant digits (whole KRGN from 100 up): 65.4 rather than 65.3594.
Decimal kerriganDonationKrgn(Decimal usd, Decimal price) {
  if (usd <= Decimal.zero || price <= Decimal.zero) return Decimal.zero;
  final exact = (usd / price).toDecimal(scaleOnInfinitePrecision: 12);
  var scale = 3 - exact.toBigInt().toString().length;
  if (exact < Decimal.one) {
    // Two more digits after the first one that isn't zero.
    var v = exact;
    scale = 2;
    while (v < Decimal.one && scale < 8) {
      v = v * Decimal.ten;
      scale++;
    }
  }
  return exact.round(scale: scale.clamp(0, 8));
}

/// [usd] for people: "$20", "$12.34" (in the locale's way).
String kerriganDonationUsdText(Decimal usd, String locale) =>
    NumberFormat.simpleCurrency(
      locale: _intlLocale(locale),
      name: "USD",
      decimalDigits: usd.isInteger ? 0 : 2,
    ).format(usd.toDouble());

/// [krgn] for people, as many decimals as it has: "65.4 KRGN".
String kerriganDonationKrgnText(Decimal krgn, String ticker, String locale) {
  final number = NumberFormat("#,##0.########", _intlLocale(locale));
  return "${number.format(krgn.toDouble())} $ticker";
}

String _intlLocale(String locale) =>
    NumberFormat.localeExists(locale) ? locale : "en_US";

/// The donation's shielded memo: a tag line in English for the developer
/// ("Fuel Delta: $20 · Quantum Hyperdrive"), then the cheers message.
/// Always within [kKerriganMaxMemoBytes]: an absurd custom amount loses
/// its dollars from the tag, and only then is the message cut.
String kerriganDonationMemo({
  required KerriganDonationTier tier,
  required bool shielded,
  Decimal? usd,
  String message = "",
}) {
  String tag(bool withUsd) {
    final dollars = withUsd && usd != null
        ? "\$${usd.isInteger ? usd : usd.toStringAsFixed(2)} · "
        : "";
    return "Fuel Delta: $dollars${tier.memoName(shielded: shielded)}";
  }

  final text = message.trim();
  if (text.isEmpty) return tag(true);
  var memo = "${tag(true)}\n$text";
  if (utf8Length(memo) > kKerriganMaxMemoBytes) memo = "${tag(false)}\n$text";
  return truncateUtf8(memo, kKerriganMaxMemoBytes);
}

/// The donation: [amount] to [address] (a shield address) with [memo],
/// paid as [funding] says. The fee comes on top.
Future<TxData> prepareKerriganDonation(
  KerriganWallet wallet, {
  required String address,
  required Amount amount,
  required String memo,
  required String note,
  required KerriganFunding funding,
}) => wallet.prepareSend(
  txData: TxData(
    note: note,
    noteOnChain: "",
    memo: memo,
    recipients: [
      TxRecipient(
        address: address,
        amount: amount,
        isChange: false,
        addressType: AddressType.kerriganShield,
      ),
    ],
    utxos: kerriganFundingInputs(funding),
    otherData: jsonEncode(kerriganFundingOtherData(funding)),
  ),
);

({Decimal value, DateTime at})? _usdPrice;

/// Kerrigan's price in US dollars from CoinGecko, under the rules of the
/// app's prices (only with external calls on; through Tor when Tor is
/// on). Null when it isn't known. Asked at most once a minute.
Future<Decimal?> kerriganUsdPrice({HTTP client = const HTTP()}) async {
  final last = _usdPrice;
  if (last != null &&
      DateTime.now().difference(last.at) < const Duration(minutes: 1)) {
    return last.value;
  }
  if (!Prefs.instance.externalCalls ||
      !(await Prefs.instance.isExternalCallsSet())) {
    return null;
  }
  try {
    final response = await client.get(
      url: Uri.parse(
        "https://api.coingecko.com/api/v3/simple/price"
        "?ids=kerrigan&vs_currencies=usd",
      ),
      headers: {'Content-Type': 'application/json'},
      proxyInfo: !AppConfig.hasFeature(AppFeature.tor)
          ? null
          : Prefs.instance.useTor
          ? TorService.sharedInstance.getProxyInfo()
          : null,
    );
    final json = jsonDecode(response.body) as Map;
    final value = Decimal.parse("${(json["kerrigan"] as Map)["usd"]}");
    if (value <= Decimal.zero) return last?.value;
    _usdPrice = (value: value, at: DateTime.now());
    return value;
  } catch (e, s) {
    Logging.instance.w("Kerrigan price in USD", error: e, stackTrace: s);
    return last?.value;
  }
}
