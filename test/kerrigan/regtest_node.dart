// Kerrigan regtest node access for the regtest suites: JSON-RPC to the
// node (KERRIGAN_RPC, default http://rpc:rpc@127.0.0.1:19898; wallet
// calls go to KERRIGAN_WALLET, default "test") and block mining.
import 'dart:convert';
import 'dart:io';

final _rpcUrl = Uri.parse(
  Platform.environment["KERRIGAN_RPC"] ?? "http://rpc:rpc@127.0.0.1:19898",
);

final _defaultWallet = Platform.environment["KERRIGAN_WALLET"] ?? "test";

/// Node calls that need no wallet.
const _nodeCalls = {
  "createwallet",
  "unloadwallet",
  "getblockhash",
  "getblock",
  "getrawtransaction",
  "getrawmempool",
  "getblockcount",
  "validateaddress",
  "generatetoaddress",
  "mnsync",
};

/// JSON-RPC call [method] with [params], on [wallet] (default: the node's
/// test wallet) for wallet calls. Throws on an RPC error.
Future<dynamic> rpc(
  String method, [
  List<Object?> params = const [],
  String? wallet,
]) async {
  wallet ??= _nodeCalls.contains(method) ? null : _defaultWallet;
  final client = HttpClient();
  try {
    final url = wallet == null
        ? _rpcUrl.replace(userInfo: "")
        : _rpcUrl.replace(userInfo: "", path: "/wallet/$wallet");
    final request = await client.postUrl(url);
    request.headers.set(
      HttpHeaders.authorizationHeader,
      "Basic ${base64.encode(utf8.encode(_rpcUrl.userInfo))}",
    );
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        "jsonrpc": "1.0",
        "id": 1,
        "method": method,
        "params": params,
      }),
    );
    final response = await request.close();
    final body = jsonDecode(
      await response.transform(utf8.decoder).join(),
    ) as Map<String, dynamic>;
    if (body["error"] != null) {
      throw Exception("$method: ${body["error"]}");
    }
    return body["result"];
  } finally {
    client.close();
  }
}

String? _minerAddress;

/// Mine [count] blocks (rewards to a node wallet address).
Future<void> mine([int count = 1]) async {
  _minerAddress ??= await rpc("getnewaddress") as String;
  await rpc("generatetoaddress", [count, _minerAddress]);
}

/// Send [amount] KRGN to [address] from the node wallet in one output.
/// Mined coins are small (5 KRGN): a large amount is first gathered in
/// 2000 KRGN coins, as one send of it would have too many inputs.
Future<String> sendLarge(String address, num amount) async {
  const chunk = 2000;
  if (amount <= chunk) {
    return await rpc("sendtoaddress", [address, amount]) as String;
  }
  final gather = await rpc("getnewaddress") as String;
  for (var sent = 0; sent < amount + 1; sent += chunk) {
    await rpc("sendtoaddress", [gather, chunk]);
  }
  // Unconfirmed too: a block may not hold all the gathering txs.
  final coins = (await rpc("listunspent", [
    0,
    9999999,
    [gather],
  ]) as List).cast<Map<String, dynamic>>();
  final total = coins.fold<num>(0, (p, c) => p + (c["amount"] as num));
  const fee = 0.001;
  final raw = await rpc("createrawtransaction", [
    [
      for (final c in coins) {"txid": c["txid"], "vout": c["vout"]},
    ],
    {
      address: amount,
      gather: double.parse((total - amount - fee).toStringAsFixed(8)),
    },
  ]);
  final signed = await rpc("signrawtransactionwithwallet", [raw]) as Map;
  return await rpc("sendrawtransaction", [signed["hex"]]) as String;
}

/// Wait up to [seconds] for [check].
Future<void> waitFor(Future<bool> Function() check, {int seconds = 60}) async {
  for (int i = 0; i < seconds * 2; i++) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw Exception("timed out");
}
