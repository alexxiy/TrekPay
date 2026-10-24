import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../providers/global/secure_store_provider.dart';
import '../../providers/providers.dart';
import '../../utilities/logger.dart';
import '../../utilities/show_loading.dart';
import '../../wallets/isar/models/wallet_info.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../wallets/wallet/wallet.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/stack_dialog.dart';

// The accounts of a Kerrigan recovery phrase ([kKerriganAccountKey]), each
// a wallet of its own with its BIP44 account and ZIP 32 shield account.

/// The lowest account number from 1 on that none of [taken] uses: a
/// deleted account is the next one added again.
int kerriganNextAccount(Iterable<int> taken) {
  final used = taken.toSet();
  var n = 1;
  while (used.contains(n)) {
    n++;
  }
  return n;
}

/// Name of account [account] of the wallet named [base], e.g. "Savings
/// (account 2)", and not one of [taken].
String kerriganAccountWalletName(String base, int account, Set<String> taken) {
  // The suffix in English or the app's language (the base may have been
  // named in another one), e.g. "(account 2)".
  final suffix = {
    "(account 0)",
    l10n.accountsSuffix(0),
  }.map((s) => RegExp.escape(s).replaceFirst("0", r"\d+")).join("|");
  final root = base.replaceFirst(RegExp(" (?:$suffix)( \\d+)?\$"), "");
  final name = "$root ${l10n.accountsSuffix(account)}";
  if (!taken.contains(name)) return name;
  for (var i = 2; ; i++) {
    if (!taken.contains("$name $i")) return "$name $i";
  }
}

/// The wallets here with [wallet]'s recovery phrase, passphrase and
/// network, by account.
Future<Map<int, KerriganWallet>> kerriganPhraseAccounts(
  WidgetRef ref,
  KerriganWallet wallet,
) async {
  final mnemonic = await wallet.getMnemonic();
  final passphrase = await wallet.getMnemonicPassphrase();
  final accounts = <int, KerriganWallet>{};
  for (final w in ref.read(pWallets).wallets) {
    if (w is! KerriganWallet ||
        w.isViewOnly ||
        w.cryptoCurrency.identifier != wallet.cryptoCurrency.identifier) {
      continue;
    }
    if (await w.getMnemonic() == mnemonic &&
        await w.getMnemonicPassphrase() == passphrase) {
      accounts.putIfAbsent(w.account, () => w);
    }
  }
  return accounts;
}

/// Restores of added accounts, one at a time: each scans the shield
/// blocks from the restore height.
Future<void> _restores = Future.value();

/// Adds account [account] of [from]'s recovery phrase as a new wallet
/// named [name], then restores it in the background: its history, and
/// its shield notes from where [from] starts.
Future<KerriganWallet> kerriganAddAccountWallet(
  WidgetRef ref, {
  required KerriganWallet from,
  required int account,
  required String name,
}) async {
  final duress = ref.read(pDuress);
  final isar = ref.read(mainDBProvider).isar;
  final info = WalletInfo.createNew(
    coin: from.cryptoCurrency,
    name: name,
    // Never 0 (testnet without one): if the app closes before the restore
    // below runs, the first sync would start the shield scan at the tip.
    restoreHeight: max(from.shieldRestoreHeight, 1),
    otherDataJsonString: jsonEncode({
      kKerriganAccountKey: account,
      // Like a restore: one hidden right after adding would give duress
      // mode away.
      if (duress) WalletInfoKeys.duressMarkedVisibleWalletKey: true,
    }),
  );
  final wallet = await Wallet.create(
    walletInfo: info,
    mainDB: ref.read(mainDBProvider),
    secureStorageInterface: ref.read(secureStoreProvider),
    nodeService: ref.read(nodeServiceChangeNotifierProvider),
    prefs: ref.read(prefsChangeNotifierProvider),
    mnemonic: await from.getMnemonic(),
    mnemonicPassphrase: await from.getMnemonicPassphrase(),
  ) as KerriganWallet;
  await wallet.init();
  if (await from.info.isMnemonicVerified(isar)) {
    await wallet.info.setMnemonicVerified(isar: isar);
  }
  if (duress) {
    await wallet.info.updateDuressVisibilityStatus(
      isDuressVisible: true,
      isar: isar,
    );
  }
  ref.read(pWallets).addWallet(wallet);
  _restores = _restores.then((_) async {
    try {
      await wallet.recover(isRescan: false);
    } catch (e, s) {
      // The next sync picks it up again.
      Logging.instance.w(
        "Kerrigan: restoring account $account failed",
        error: e,
        stackTrace: s,
      );
    }
  });
  return wallet;
}

/// The other accounts of [wallet]'s recovery phrase that have been used
/// (see [KerriganWallet.findUsedAccounts]); none when looking fails.
Future<List<int>> kerriganFindUsedAccounts(KerriganWallet wallet) async {
  try {
    return await wallet.findUsedAccounts();
  } catch (e, s) {
    Logging.instance.w(
      "Kerrigan: looking for other accounts failed",
      error: e,
      stackTrace: s,
    );
    return const [];
  }
}

/// Adds [accounts] of [wallet]'s recovery phrase that aren't here yet
/// (after a restore) and returns their names.
Future<List<String>> kerriganAddAccounts(
  WidgetRef ref,
  KerriganWallet wallet,
  List<int> accounts,
) async {
  if (accounts.isEmpty) return const [];
  final here = await kerriganPhraseAccounts(ref, wallet);
  final names = {for (final w in ref.read(pWallets).wallets) w.info.name};
  final added = <String>[];
  for (final account in accounts) {
    if (here.containsKey(account)) continue;
    final name = kerriganAccountWalletName(wallet.info.name, account, names);
    names.add(name);
    await kerriganAddAccountWallet(ref, from: wallet, account: account, name: name);
    added.add(name);
  }
  return added;
}

/// What the restore succeeded dialog says about [added] accounts.
String? kerriganAddedAccountsMessage(List<String> added) {
  if (added.isEmpty) return null;
  final names = added.map((n) => "“$n”").join(", ");
  return added.length == 1
      ? l10n.accountsAddedOne(names)
      : l10n.accountsAddedMany(names);
}

/// "Add account" of a Kerrigan wallet's menu: asks, then adds the phrase's
/// next account as a new wallet.
Future<void> showKerriganAddAccountDialog(
  BuildContext context,
  WidgetRef ref,
  String walletId,
) async {
  final wallet = ref.read(pWallets).getWallet(walletId) as KerriganWallet;
  final here = await kerriganPhraseAccounts(ref, wallet);
  final account = kerriganNextAccount(here.keys);
  final name = kerriganAccountWalletName((here[0] ?? wallet).info.name, account, {
    for (final w in ref.read(pWallets).wallets) w.info.name,
  });
  if (!context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => StackDialog(
      title: l10n.accountsAddTitle(account),
      message: l10n.accountsAddText(account, name),
      leftButton: SecondaryButton(
        label: l10n.commonCancel,
        onPressed: () => Navigator.of(context).pop(false),
      ),
      rightButton: PrimaryButton(
        label: l10n.accountsAdd,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return;

  Exception? error;
  final added = await showLoading<KerriganWallet>(
    whileFuture: kerriganAddAccountWallet(
      ref,
      from: wallet,
      account: account,
      name: name,
    ),
    context: context,
    message: l10n.accountsAdding(account),
    onException: (e) => error = e,
  );
  if (!context.mounted) return;
  unawaited(
    showFloatingFlushBar(
      type: added == null ? FlushBarType.warning : FlushBarType.success,
      message: added == null
          ? l10n.accountsAddFailed(
              error.toString().replaceFirst("Exception: ", ""),
            )
          : l10n.accountsAdded(name),
      context: context,
    ),
  );
}
