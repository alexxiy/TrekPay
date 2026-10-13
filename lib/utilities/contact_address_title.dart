import '../models/isar/models/contact_entry.dart';
import '../wallets/crypto_currency/coins/kerrigan.dart';

extension ContactAddressTitle on ContactAddressEntry {
  /// What the address is, worked out from the address itself. Contact
  /// addresses have no hand-typed label any more.
  String get kind {
    final c = coin;
    if (c is Kerrigan) {
      if (c.isShieldAddress(address)) return "Shielded";
    }
    return "Transparent";
  }

  /// "Shielded (KRGN)".
  String get title => "$kind (${coin.ticker})";
}
