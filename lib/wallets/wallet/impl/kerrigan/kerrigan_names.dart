part of '../kerrigan_wallet.dart';

// Kerrigan NameSpace (ported from PIVX.name): registering and managing names. A
// command is a payment to the registrar's shield address whose memo is
// the command, signed with the wallet's names key.

/// Wallet otherData: the Kerrigan NameSpace payments sent from this wallet, kept
/// until the registrar lists them, so that they show in My Transactions
/// right away.
const _kOdNamesSent = "kerriganNamesSent";

/// How long a sent payment is shown without the registrar listing it.
const _kNamesSentMaxAge = Duration(days: 3);

/// A Kerrigan NameSpace payment sent from this wallet.
typedef KerriganNamesSent = ({
  String txid,
  String name,
  String op,
  String memo,
  DateTime sent,
});

extension KerriganNamesWallet on KerriganWallet {
  /// The key of this wallet's names: the same key Kerrigan NameSpace makes from
  /// this wallet's recovery phrase.
  Future<KerriganNamesIdentity> namesIdentity() async =>
      KerriganNamesIdentity.fromMnemonic(await getMnemonic());

  /// The payment of a Kerrigan NameSpace command: [amount] to the registrar's
  /// [address], with the command as the shielded memo, paid as [funding]
  /// says. The fee comes on top (the registrar wants the exact price).
  Future<TxData> prepareNamesPayment({
    required String address,
    required Amount amount,
    required String memo,
    required String note,
    KerriganFunding funding = kKerriganAutoFunding,
  }) {
    if (!isShieldAddress(address)) {
      throw Exception(l10n.namesNotShieldAddress);
    }
    return prepareSend(
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
  }

  /// This wallet's shield addresses, newest first.
  Future<List<Address>> ownShieldAddresses() => mainDB
      .getAddresses(walletId)
      .filter()
      .typeEqualTo(AddressType.kerriganShield)
      .sortByDerivationIndexDesc()
      .findAll();

  /// The Kerrigan NameSpace payments sent from this wallet that may not be listed
  /// by the registrar yet, newest first.
  List<KerriganNamesSent> get namesSent {
    final stored = info.otherData[_kOdNamesSent];
    if (stored is! List) return const [];
    final now = DateTime.now();
    final out = <KerriganNamesSent>[];
    for (final e in stored) {
      if (e is! Map) continue;
      final sent = DateTime.fromMillisecondsSinceEpoch(
        ((e["sent"] as num?) ?? 0).toInt() * 1000,
      );
      if (now.difference(sent) > _kNamesSentMaxAge) continue;
      out.add((
        txid: "${e["txid"]}",
        name: "${e["name"]}",
        op: "${e["op"]}",
        memo: "${e["memo"]}",
        sent: sent,
      ));
    }
    out.sort((a, b) => b.sent.compareTo(a.sent));
    return out;
  }

  /// Remembers [sent] (right before it is broadcast).
  Future<void> rememberNamesSent(KerriganNamesSent sent) =>
      info.updateOtherDataWith(
        isar: mainDB.isar,
        change: (stored) => {
          _kOdNamesSent: [
            for (final e in (stored[_kOdNamesSent] as List?) ?? const [])
              if (e is Map && e["txid"] != sent.txid) e,
            {
              "txid": sent.txid,
              "name": sent.name,
              "op": sent.op,
              "memo": sent.memo,
              "sent": sent.sent.millisecondsSinceEpoch ~/ 1000,
            },
          ],
        },
      );

  /// Forgets the payments [txids] (listed by the registrar now, or never
  /// sent), and the ones too old to show.
  Future<void> forgetNamesSent(Iterable<String> txids) {
    final drop = txids.toSet();
    final keep = namesSent.map((e) => e.txid).toSet().difference(drop);
    return info.updateOtherDataWith(
      isar: mainDB.isar,
      change: (stored) => {
        _kOdNamesSent: [
          for (final e in (stored[_kOdNamesSent] as List?) ?? const [])
            if (e is Map && keep.contains(e["txid"])) e,
        ],
      },
    );
  }
}
