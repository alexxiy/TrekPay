import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/models/isar/models/blockchain_data/transaction_type.dart';
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
  int? type,
}) => {
  "txid": "aa" * 32,
  "type": ?type,
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
  Set<String> masternodePayouts = const {},
}) => parseKerriganTx(
  json,
  walletId: "test",
  fractionDigits: 8,
  receiving: {_ours},
  change: const {},
  shieldAddresses: {_shield},
  shield: shield,
  nullifierNotes: nullifierNotes,
  masternodePayouts: masternodePayouts,
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

  test("an InstantSend-locked mempool tx shows as pending until mined", () {
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
    expect(locked.isInstantLockedBeforeBlock, isTrue);
    // The coins are spendable at once, but the tx waits for its block.
    expect(locked.isConfirmed(500, 1, 101), isFalse);
    expect(
      locked.statusLabel(
        currentChainHeight: 500,
        minConfirms: 1,
        minCoinbaseConfirms: 101,
      ),
      "Receiving (0/1)",
    );
    final unlocked = _parse(pending(false));
    expect(unlocked.isInstantLocked, isFalse);
    expect(unlocked.isInstantLockedBeforeBlock, isFalse);
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
        "sent": <dynamic>[],
      },
      nullifierNotes: {
        nf: {"value": 7 * _coin, "address": _shield},
      },
    );
    expect(tx.type, TransactionType.outgoing);
    expect(tx.kerriganChangeAddresses, contains(_change));
    expect(
      tx.getAmountSentFromThisWallet(fractionDigits: 8, subtractFee: true).raw,
      BigInt.from(2 * _coin),
    );
    expect(tx.getFee(fractionDigits: 8).raw, BigInt.from(25000));
  });

  test("a coinbase paying one of our masternodes is a masternode reward", () {
    final json = _tx(
      coinbase: true,
      vin: [
        {"coinbase": "03aabbcc"},
      ],
      vout: [
        {
          "value": "${5 * _coin}",
          "addresses": [_someone],
          "hex": _p2pkh,
        },
        {
          "value": "${5 * _coin}",
          "addresses": [_ours],
          "hex": _p2pkh,
        },
      ],
    );
    final tx = _parse(json, masternodePayouts: {_ours});
    expect(tx.kerriganKind, KerriganTxKind.masternodeReward);
    expect(KerriganTxCategory.of(tx), KerriganTxCategory.masternodeReward);
    expect(tx.isCoinbase(), isTrue);
    // Without our masternode it's a plain block reward.
    expect(_parse(json).kerriganKind, KerriganTxKind.blockReward);
  });

  test("a proposal fee burns coins in an OP_RETURN", () {
    final tx = _parse(
      _tx(
        fees: "1000",
        vin: [
          {
            "txid": "bb" * 32,
            "vout": 0,
            "value": "${2 * _coin}",
            "addresses": [_ours],
          },
        ],
        vout: [
          {
            "value": "$_coin",
            "addresses": <String>[],
            "hex": "6a20${"cd" * 32}",
          },
          {
            "value": "${_coin - 1000}",
            "addresses": [_ours],
            "hex": _p2pkh,
          },
        ],
      ),
    );
    expect(tx.kerriganKind, KerriganTxKind.burn);
    expect(tx.type, TransactionType.outgoing);
    expect(KerriganTxCategory.of(tx), KerriganTxCategory.masternode);
  });

  test("provider transactions register or update our masternodes", () {
    Map<String, dynamic> provider(int type) => _tx(
      type: type,
      fees: "450",
      vin: [
        {
          "txid": "bb" * 32,
          "vout": 0,
          "value": "100000",
          "addresses": [_ours],
        },
      ],
      vout: [
        {
          "value": "99550",
          "addresses": [_ours],
          "hex": _p2pkh,
        },
      ],
    );
    final reg = _parse(provider(1));
    expect(reg.kerriganKind, KerriganTxKind.masternodeRegistration);
    expect(reg.type, TransactionType.sentToSelf);
    for (final type in [2, 3, 4]) {
      expect(
        _parse(provider(type)).kerriganKind,
        KerriganTxKind.masternodeUpdate,
      );
    }
  });
}
