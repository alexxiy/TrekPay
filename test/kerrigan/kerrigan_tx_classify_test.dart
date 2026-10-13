import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/blockchain_data/transaction.dart';
import 'package:paymint/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:paymint/models/transaction_filter.dart';
import 'package:paymint/wallets/wallet/impl/kerrigan/kerrigan_tx_parser.dart';

const _coin = 100000000;

const _ours = "yRd4FhXfVGHXpsuZXPNkMrfD9GVj46pnjt";
const _someone = "yeiahYKSYceWZji4SMJ6sQSTYsyELJxf1T";
const _shield =
    "kregsapling1j9s20dpe62kr0jhfvnqua3j8wv873ccy7u3l3fuwgvc8l4yy0dqpnaknkp3g0uaj0jynjpyc6ul";
const _change =
    "kregsapling12pl8nuy7rr2ja6adwmtf423pktlzs9wlxtl0klqnnmj9d342zqp2k2n4vwrqst6z7snlz30snj6";

final _p2pkh = "76a914${"33" * 20}88ac";

Map<String, dynamic> _tx({
  List<Map<String, dynamic>> vin = const [],
  required List<Map<String, dynamic>> vout,
  int height = 300,
  bool coinbase = false,
  String fees = "0",
  bool? instantlock,
}) => {
  "txid": "aa" * 32,
  "blockHeight": height,
  "blockTime": 1791871312,
  "coinbase": coinbase,
  "fees": fees,
  "vin": vin,
  "vout": vout,
  "instantlock": ?instantlock,
};

TransactionV2 _parse(
  Map<String, dynamic> json, {
  Map<String, dynamic>? shield,
  Map<String, Map<String, dynamic>> nullifierNotes = const {},
}) => parseKerriganTx(
  json,
  walletId: "test",
  fractionDigits: 8,
  receiving: {_ours},
  change: const {},
  shieldAddresses: {_shield},
  shield: shield,
  nullifierNotes: nullifierNotes,
)!;

void main() {
  test("a coinbase payout is a block reward, immature until maturity", () {
    final tx = _parse(
      _tx(
        coinbase: true,
        vin: [
          {"coinbase": "03aabbcc"},
        ],
        vout: [
          {
            "value": "${10 * _coin}",
            "addresses": [_someone],
            "hex": _p2pkh,
          },
          {
            "value": "${3 * _coin}",
            "addresses": [_ours],
            "hex": _p2pkh,
          },
        ],
      ),
    );
    expect(tx.kerriganKind, KerriganTxKind.blockReward);
    expect(tx.type, TransactionType.incoming);
    expect(
      tx.getAmountReceivedInThisWallet(fractionDigits: 8).raw,
      BigInt.from(3 * _coin),
    );
    expect(KerriganTxCategory.of(tx), KerriganTxCategory.blockReward);
    expect(tx.isConfirmed(400, 1, 101), isTrue);
    expect(tx.isConfirmed(350, 1, 101), isFalse);
  });

  test("an InstantSend-locked mempool tx counts as confirmed", () {
    Map<String, dynamic> pending(bool locked) => _tx(
      height: -1,
      instantlock: locked,
      vin: [
        {
          "txid": "bb" * 32,
          "vout": 0,
          "addresses": [_someone],
          "value": "${2 * _coin}",
        },
      ],
      vout: [
        {
          "value": "${_coin}",
          "addresses": [_ours],
          "hex": _p2pkh,
        },
      ],
    );
    final locked = _parse(pending(true));
    expect(locked.isInstantLocked, isTrue);
    expect(locked.isConfirmed(500, 1, 101), isTrue);
    expect(
      locked.statusLabel(
        currentChainHeight: 500,
        minConfirms: 1,
        minCoinbaseConfirms: 101,
      ),
      "Received",
    );
    final unlocked = _parse(pending(false));
    expect(unlocked.isInstantLocked, isFalse);
    expect(unlocked.isConfirmed(500, 1, 101), isFalse);
  });

  test("shield change (the internal key) is not counted as sent", () {
    // Spend a 7 KRGN note: 2 KRGN to someone's transparent address, the
    // rest back to the internal key, 0.00025 fee.
    const nf = "11";
    final tx = _parse(
      _tx(
        fees: "25000",
        vout: [
          {
            "value": "${2 * _coin}",
            "addresses": [_someone],
            "hex": _p2pkh,
          },
        ],
      ),
      shield: {
        "received": [
          {
            "value": 7 * _coin - 2 * _coin - 25000,
            "address": _change,
            "memo": null,
            "nullifier": "22",
            "index": 0,
            "change": true,
          },
        ],
        "spentNullifiers": [nf],
        "sent": [],
      },
      nullifierNotes: {
        nf: {"value": 7 * _coin, "address": _shield},
      },
    );
    expect(tx.type, TransactionType.outgoing);
    expect(tx.kerriganChangeAddresses, contains(_change));
    expect(
      tx
          .getAmountSentFromThisWallet(fractionDigits: 8, subtractFee: true)
          .raw,
      BigInt.from(2 * _coin),
    );
    expect(tx.getFee(fractionDigits: 8).raw, BigInt.from(25000));
  });
}
