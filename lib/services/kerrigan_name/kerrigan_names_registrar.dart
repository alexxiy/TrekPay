import 'dart:async';
import 'dart:convert';

import '../../wallets/crypto_currency/crypto_currency.dart';
import 'kerrigan_name.dart';
import 'kerrigan_name_resolver.dart';
import 'kerrigan_names_protocol.dart';

/// The Kerrigan.name registrar: where names are registered and managed. It
/// takes the commands paid to its address, keeps the users' refund
/// balances and runs the marketplace.
class KerriganNamesService {
  const KerriganNamesService({
    required this.registrar,
    required this.network,
    required this.marker,
  });

  final Uri registrar;

  /// The network the registrar must report ("mainnet").
  final String network;

  /// Head of every command: tells networks apart, so a command signed for
  /// one can't be replayed on another.
  final String marker;

  /// The registrar for [coin], or null where names don't exist (see
  /// [KerriganNameService.forCoin]): Kerrigan has none yet.
  static KerriganNamesService? forCoin(CryptoCurrency coin) =>
      null;
}

class KerriganNamesException implements Exception {
  const KerriganNamesException(this.message, {this.fromServer = false});

  final String message;

  /// [message] is the registrar's own text (cleaned): it refused the
  /// request.
  final bool fromServer;

  @override
  String toString() => message;
}

/// Where payments for commands go.
typedef KerriganNamesPaymentInfo = ({
  String address,
  int paymentConfirmations,
  int refundConfirmations,
});

/// What a name lookup on the registrar found.
sealed class KerriganNamesAvailability {
  const KerriganNamesAvailability(this.name);

  final String name;
}

/// Free: [price] registers it.
final class KerriganNamesAvailable extends KerriganNamesAvailability {
  const KerriganNamesAvailable(super.name, this.price);

  final BigInt price;
}

/// Registered and not for sale.
final class KerriganNamesTaken extends KerriganNamesAvailability {
  const KerriganNamesTaken(super.name);
}

/// Listed on the marketplace for [price], by [owner] (public key).
final class KerriganNamesListed extends KerriganNamesAvailability {
  const KerriganNamesListed(super.name, this.price, this.owner);

  final BigInt price;
  final String? owner;
}

/// Where a paid command is in the registrar's queue.
enum KerriganNamesTxStatus {
  confirmingPayment(0),
  pendingProof(1),
  queuedProof(2),
  processingProof(3),
  submittingProof(4),
  done(5),
  orphaned(6),
  pendingRefund(7),
  refunded(8),
  rejected(9);

  const KerriganNamesTxStatus(this.code);

  final int code;

  static KerriganNamesTxStatus? fromCode(Object? code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }

  /// Nothing more will happen to it.
  bool get isFinal =>
      this == done || this == orphaned || this == refunded || this == rejected;

  bool get failed => this == orphaned || this == refunded || this == rejected;

  String get label => switch (this) {
    confirmingPayment => "Confirming payment",
    pendingProof => "Waiting for the proof",
    queuedProof => "Proof queued",
    processingProof => "Creating the proof",
    submittingProof => "Submitting the proof",
    done => "Done",
    orphaned => "Orphaned",
    pendingRefund => "Refund pending",
    refunded => "Refunded",
    rejected => "Rejected",
  };
}

/// What the registrar knows of a payment: nothing yet (all null), its
/// transaction ([txId], found by its memo), or its [status].
typedef KerriganNamesProgress = ({
  String? txId,
  KerriganNamesTxStatus? status,
  int? confirmations,

  /// Seconds until the next proof batch starts (queued commands).
  int? seconds,
});

/// A name in a list: the user's names or the marketplace.
typedef KerriganNamesDomain = ({
  String name,

  /// Listing price; zero when not for sale.
  BigInt price,

  /// Price of an update (destination, owner, listing).
  BigInt? updatePrice,

  /// Where it points (the user's own names).
  String? address,

  /// The owner's key (marketplace, when asked with a key).
  String? owner,
});

/// A command paid to the registrar, from the user's history.
typedef KerriganNamesIncoming = ({
  String name,
  String op,
  int confirmations,
  KerriganNamesTxStatus? status,
  int? rawStatus,
  String txId,
  String memo,
});

/// Where a withdrawal is (TX_REFUND_* of the registrar).
enum KerriganNamesRefundStatus {
  waiting(0, "Waiting"),
  queued(1, "Queued"),

  /// Being sent: still on its way, so it reads as queued, as on the web.
  sending(2, "Queued"),
  paid(3, "Paid"),

  /// The amount went back to the balance.
  error(4, "Error"),

  /// Retried on its own after a payout batch the node refused: still on
  /// its way.
  solo(5, "Queued");

  const KerriganNamesRefundStatus(this.code, this.label);

  final int code;
  final String label;

  static KerriganNamesRefundStatus? fromCode(Object? code) {
    for (final s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// A withdrawal of the refund balance.
typedef KerriganNamesRefund = ({
  DateTime? date,
  BigInt amount,

  /// Service fee, in percent.
  String fee,
  String txId,
  KerriganNamesRefundStatus? status,
  int? rawStatus,
});

typedef KerriganNamesPage<T> = ({int count, List<T> items});

/// Refunded payments the user can withdraw, the service fee a withdrawal
/// pays (percent), and the least balance a withdrawal may ask for, fee
/// included (zero: no minimum).
typedef KerriganNamesBalance = ({
  BigInt balance,
  double feePercent,
  BigInt minWithdrawal,
});

const kKerriganNamesDefaultRefundFee = 5.0;

/// Page sizes, as the web app uses them.
const kKerriganNamesListPageSize = 20;
const kKerriganNamesHistoryPageSize = 10;

/// Talks to the registrar's API (`/v1.0/...`).
///
/// The answers aren't proofs: unlike name lookups for payments (checked
/// against BNB Smart Chain), what the registrar says here is taken as it
/// says it, like the web app does. Nothing it says can move funds by
/// itself: every payment is built, shown and confirmed in the wallet.
class KerriganNamesRegistrar {
  KerriganNamesRegistrar(this.service, {KerriganNameTransport? transport})
    : _transport = transport ?? kerriganNameHttpTransport;

  /// The registrar for [coin], with the app's network settings (Tor), or
  /// null when [coin] has no names.
  static KerriganNamesRegistrar? forCoin(CryptoCurrency coin) {
    final service = KerriganNamesService.forCoin(coin);
    if (service == null) return null;
    return _shared[service.registrar] ??= KerriganNamesRegistrar(service);
  }

  static final _shared = <Uri, KerriganNamesRegistrar>{};

  final KerriganNamesService service;
  final KerriganNameTransport _transport;

  Future<KerriganNamesPaymentInfo>? _paymentInfo;
  Future<Map<int, BigInt>>? _updatePrices;
  DateTime? _updatePricesAt;

  static const _pricesMaxAge = Duration(minutes: 5);

  Future<Object?> _call(String path, [Map<String, dynamic>? body]) async {
    final url = service.registrar.replace(path: "/v1.0/$path");
    final KerriganNameResponse response;
    try {
      response = await _transport(
        body == null ? "GET" : "POST",
        url,
        body: body == null ? null : jsonEncode(body),
      );
    } catch (e) {
      throw KerriganNamesException("Couldn't reach Kerrigan.name ($e)");
    }
    Object? json;
    try {
      json = jsonDecode(response.body);
    } catch (_) {
      json = null;
    }
    if (json is Map) {
      final error = json["error"];
      if (error != null) {
        final text = cleanKerriganNameServerText(
          error is Map ? error["error_message"] : error,
        );
        throw KerriganNamesException(
          text ?? "Kerrigan.name refused the request",
          fromServer: true,
        );
      }
      if (json.containsKey("response")) return json["response"];
    }
    throw KerriganNamesException(
      "Kerrigan.name sent an answer the app doesn't understand "
      "(HTTP ${response.status})",
    );
  }

  static Never _malformed() => throw const KerriganNamesException(
    "Kerrigan.name sent an answer the app doesn't understand",
  );

  /// [_call] for the signed requests the registrar takes within a minute
  /// of their nonce: its "Request timeout" means this device's clock is
  /// off.
  Future<Object?> _timed(String path, Map<String, dynamic> body) async {
    try {
      return await _call(path, body);
    } on KerriganNamesException catch (e) {
      if (e.fromServer && e.message == "Request timeout") {
        throw const KerriganNamesException(
          "Kerrigan.name turned the request down because this device's clock "
          "is off. Set the right time and try again.",
          fromServer: true,
        );
      }
      rethrow;
    }
  }

  /// The registrar's payment address, checked against [service] (network,
  /// address rule). Asked once; a failure is asked again next time.
  Future<KerriganNamesPaymentInfo> paymentInfo() async {
    final pending = _paymentInfo ??= _fetchPaymentInfo();
    try {
      return await pending;
    } catch (_) {
      if (identical(_paymentInfo, pending)) _paymentInfo = null;
      rethrow;
    }
  }

  Future<KerriganNamesPaymentInfo> _fetchPaymentInfo() async {
    final r = await _call("getPaymentAddress");
    if (r is! Map) _malformed();
    final address = r["address"];
    if (r["network"] != null && r["network"] != service.network) {
      throw KerriganNamesException(
        "Kerrigan.name answered for ${r["network"]}, not ${service.network}",
      );
    }
    if (address is! String || !isValidKerriganNamesTarget(address)) _malformed();
    int confirmations(Object? v, int fallback) =>
        v is int && v > 0 && v < 10000 ? v : fallback;
    return (
      address: address,
      paymentConfirmations: confirmations(
        r["payment_confirmations"],
        kKerriganNamesPaymentConfirmations,
      ),
      refundConfirmations: confirmations(
        r["refund_confirmations"],
        kKerriganNamesRefundConfirmations,
      ),
    );
  }

  /// The lookup path of [name]. Names from the registrar's own lists go
  /// there too, so one that isn't a name never reaches a URL.
  static String _checkPath(String name) {
    if (!isValidKerriganName(name)) {
      throw KerriganNamesException("$name isn't a valid Kerrigan name");
    }
    return "check/$name";
  }

  /// Whether [name] is free, taken or for sale.
  Future<KerriganNamesAvailability> check(String name) async {
    final r = await _call(_checkPath(name), {"with_pubkey": true});
    if (r is! Map || r["exists"] is! bool) _malformed();
    final price = _sats(r["price"]);
    if (r["exists"] == false) {
      if (price == null || price <= BigInt.zero) _malformed();
      return KerriganNamesAvailable(name, price);
    }
    if (price != null && price > BigInt.zero) {
      final owner = r["pubkey"];
      return KerriganNamesListed(name, price, owner is String ? owner : null);
    }
    return KerriganNamesTaken(name);
  }

  /// The payment carrying [memo] for [name], once the registrar has seen
  /// it.
  Future<KerriganNamesProgress> progressByMemo(String name, String memo) async {
    final r = await _call(_checkPath(name), {
      "reg_id": base64.encode(utf8.encode(memo)),
    });
    return _progress(r);
  }

  /// Where the payment [txId] for [name] is.
  Future<KerriganNamesProgress> progressByTxId(String name, String txId) async {
    final r = await _call(_checkPath(name), {"tx_id": txId});
    return _progress(r);
  }

  static KerriganNamesProgress _progress(Object? r) {
    // Nothing known yet comes back as an empty list.
    if (r is! Map) {
      if (r is List && r.isEmpty) {
        return (txId: null, status: null, confirmations: null, seconds: null);
      }
      _malformed();
    }
    final txId = r["tx_id"];
    return (
      txId: txId is String && txId.isNotEmpty ? txId : null,
      status: KerriganNamesTxStatus.fromCode(_int(r["status"])),
      confirmations: _int(r["confirmations"]),
      seconds: _int(r["seconds"]),
    );
  }

  /// Price of an update by label length (the longest key covers longer
  /// labels), for 5 minutes.
  Future<Map<int, BigInt>> updatePrices() async {
    final at = _updatePricesAt;
    if (_updatePrices == null ||
        at == null ||
        DateTime.now().difference(at) > _pricesMaxAge) {
      _updatePricesAt = DateTime.now();
      _updatePrices = _fetchUpdatePrices();
    }
    final pending = _updatePrices!;
    try {
      return await pending;
    } catch (_) {
      if (identical(_updatePrices, pending)) _updatePrices = null;
      rethrow;
    }
  }

  Future<Map<int, BigInt>> _fetchUpdatePrices() async {
    final r = await _call("prices", {"type": "upd"});
    if (r is! Map || r.isEmpty) _malformed();
    final prices = <int, BigInt>{};
    for (final e in r.entries) {
      final length = int.tryParse("${e.key}");
      final price = _sats(e.value);
      if (length == null || price == null || price <= BigInt.zero) {
        _malformed();
      }
      prices[length] = price;
    }
    return prices;
  }

  /// What an update of [name] costs.
  Future<BigInt> updatePriceFor(String name) async {
    final prices = await updatePrices();
    final length = splitKerriganName(name).label.length;
    final longest = prices.keys.reduce((a, b) => a > b ? a : b);
    final price = prices[length >= longest ? longest : length];
    if (price == null) _malformed();
    return price;
  }

  /// The names [pubkey] owns, those matching [search] when given.
  Future<KerriganNamesPage<KerriganNamesDomain>> myNames({
    required String pubkey,
    int page = 1,
    String search = "",
  }) => _domains({
    "type": "my",
    "page": page,
    "count": kKerriganNamesListPageSize,
    "pubkey": pubkey,
    if (search.isNotEmpty) "search": search,
  });

  /// Names for sale. With [pubkey], each comes with its owner's key, so the
  /// user's own listings can be told apart.
  Future<KerriganNamesPage<KerriganNamesDomain>> marketplace({
    String? pubkey,
    int page = 1,
    String search = "",
  }) => _domains({
    "type": "marketplace",
    "page": page,
    "count": kKerriganNamesListPageSize,
    "pubkey": ?pubkey,
    if (search.isNotEmpty) "search": search,
  });

  Future<KerriganNamesPage<KerriganNamesDomain>> _domains(
    Map<String, dynamic> body,
  ) async {
    final r = await _call("domains", body);
    if (r is! Map) _malformed();
    final list = r["domains"];
    if (list is! List) _malformed();
    final items = <KerriganNamesDomain>[];
    for (final d in list) {
      if (d is! Map) _malformed();
      final name = d["domain"];
      if (name is! String || !isValidKerriganName(name)) continue;
      final address = d["address"];
      final owner = d["pubkey"];
      items.add((
        name: name,
        price: _sats(d["price"]) ?? BigInt.zero,
        updatePrice: _sats(d["tx_price"]),
        address: address is String ? address : null,
        owner: owner is String ? owner : null,
      ));
    }
    return (count: _int(r["count"]) ?? items.length, items: items);
  }

  /// Refunds waiting for [pubkey], and the withdrawal fee.
  Future<KerriganNamesBalance> balance(String pubkey) async {
    final r = await _call("balance", {"action": "get", "pubkey": pubkey});
    if (r is! Map) _malformed();
    final balance = _sats(r["balance"]);
    if (balance == null) _malformed();
    final fee = double.tryParse("${r["fee"]}");
    // Payouts cost the registrar a network fee each, so it refuses small
    // ones. An older registrar doesn't say: no minimum, as on the web.
    final minimum = _sats(r["min_withdrawal"]);
    return (
      balance: balance,
      feePercent: fee != null && fee >= 0 && fee < 100
          ? fee
          : kKerriganNamesDefaultRefundFee,
      minWithdrawal: minimum != null && minimum > BigInt.zero
          ? minimum
          : BigInt.zero,
    );
  }

  /// Asks for [amount] of the balance to be paid to [address]. [signature]
  /// signs [kerriganNamesWithdrawMessage].
  Future<void> withdraw({
    required String pubkey,
    required String address,
    required BigInt amount,
    required int nonce,
    required String signature,
  }) async {
    final r = await _timed("balance", {
      "action": "withdraw",
      "pubkey": pubkey,
      "address": address,
      "amount": "$amount",
      "nonce": nonce,
      "signature": signature,
    });
    if (r != 1) {
      throw const KerriganNamesException(
        "The withdrawal failed: Kerrigan.name sent an unexpected answer",
      );
    }
  }

  /// The commands [pubkey] paid for, newest first. [signature] signs
  /// [kerriganNamesHistoryMessage] with type "in" and [nonce].
  Future<KerriganNamesPage<KerriganNamesIncoming>> incoming({
    required String pubkey,
    required int page,
    required int nonce,
    required String signature,
  }) async {
    final r = await _history("in", pubkey, page, nonce, signature);
    final items = <KerriganNamesIncoming>[];
    for (final t in r.items) {
      final status = _int(t["status"]);
      items.add((
        name: _text(t["domain_name"]),
        op: _text(t["op"]),
        confirmations: _int(t["confirmations"]) ?? 0,
        status: KerriganNamesTxStatus.fromCode(status),
        rawStatus: status,
        txId: _txId(t["tx_id"]),
        memo: _text(t["memo"]),
      ));
    }
    return (count: r.count, items: items);
  }

  /// The withdrawals [pubkey] asked for, newest first. [signature] signs
  /// [kerriganNamesHistoryMessage] with type "ref" and [nonce].
  Future<KerriganNamesPage<KerriganNamesRefund>> refunds({
    required String pubkey,
    required int page,
    required int nonce,
    required String signature,
  }) async {
    final r = await _history("ref", pubkey, page, nonce, signature);
    final items = <KerriganNamesRefund>[];
    for (final t in r.items) {
      final date = _int(t["date"]);
      final status = _int(t["status"]);
      items.add((
        date: date == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(date * 1000, isUtc: true),
        amount: _sats(t["amount"]) ?? BigInt.zero,
        fee: _text(t["fee"]).replaceAll("%", ""),
        txId: _txId(t["tx_id"]),
        status: KerriganNamesRefundStatus.fromCode(status),
        rawStatus: status,
      ));
    }
    return (count: r.count, items: items);
  }

  Future<KerriganNamesPage<Map<Object?, Object?>>> _history(
    String type,
    String pubkey,
    int page,
    int nonce,
    String signature,
  ) async {
    final r = await _timed("transactions", {
      "type": type,
      "pubkey": pubkey,
      "page": page,
      "count": kKerriganNamesHistoryPageSize,
      "nonce": nonce,
      "signature": signature,
    });
    if (r is! Map) _malformed();
    final list = r["tx"];
    if (list is! List) _malformed();
    return (
      count: _int(r["count"]) ?? list.length,
      items: [
        for (final t in list)
          if (t is Map) t,
      ],
    );
  }
}

int? _int(Object? v) => v is int ? v : int.tryParse("${v ?? ""}");

/// Server text of a history entry, safe to show (no control or direction
/// characters). A memo is up to 512 bytes, so nothing is cut.
String _text(Object? v) => v == null
    ? ""
    : "$v"
          .replaceAll(
            RegExp(
              r"[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e"
              r"\u2066-\u2069]",
            ),
            " ",
          )
          .trim();

/// A transaction id, or "" for anything that isn't one.
String _txId(Object? v) {
  final s = "${v ?? ""}".toLowerCase();
  return RegExp(r"^[0-9a-f]{64}$").hasMatch(s) ? s : "";
}

/// An amount in satoshis: an integer, or a decimal string the registrar's
/// database may write with a fraction (".00000000").
BigInt? _sats(Object? v) {
  if (v is int) return BigInt.from(v);
  if (v is! String) return null;
  final s = v.trim();
  final whole = RegExp(r"^(\d+)(\.0*)?$").firstMatch(s);
  return whole == null ? null : BigInt.parse(whole.group(1)!);
}
