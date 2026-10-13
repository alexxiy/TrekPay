import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tuple/tuple.dart';

import '../../../models/isar/models/isar_models.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/middle_ellipsis_text.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../coin_control/coin_control_view.dart';
import 'kerrigan_change_address_sheet.dart';

/// How a Kerrigan transaction is paid ([KerriganFunding]): from the public or the
/// private balance, with which coins, and where the change goes.
class KerriganFundingCard extends ConsumerWidget {
  const KerriganFundingCard({
    super.key,
    required this.walletId,
    required this.funding,
    required this.onChanged,
    this.amount,
    this.subtractFee = false,
    this.allowShield = true,
  });

  final String walletId;
  final KerriganFunding funding;
  final ValueChanged<KerriganFunding> onChanged;

  /// What is being paid, for the coin control summary.
  final Amount? amount;
  final bool subtractFee;

  /// Whether the private balance can pay this transaction.
  final bool allowShield;

  Future<void> _chooseCoins(BuildContext context) async {
    final result = await Navigator.of(context).pushNamed(
      CoinControlView.routeName,
      arguments: Tuple5(
        walletId,
        CoinControlViewType.use,
        amount,
        funding.coins,
        (
          shieldNotes: funding.fromShield,
          sendAmount: amount,
          toShield: false,
          subtractFee: subtractFee,
        ),
      ),
    );
    if (result is Set<UTXO>) {
      onChanged((
        fromShield: funding.fromShield,
        coins: result,
        changeAddress: funding.changeAddress,
      ));
    }
  }

  Future<void> _chooseChange(BuildContext context, Kerrigan coin) async {
    final picked = await showModalBottomSheet<String>(
      backgroundColor: Colors.transparent,
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => KerriganChangeAddressSheet(
        walletId: walletId,
        coin: coin,
        current: funding.changeAddress,
        shield: funding.fromShield,
      ),
    );
    if (picked != null) {
      onChanged((
        fromShield: funding.fromShield,
        coins: funding.coins,
        changeAddress: picked.isEmpty ? null : picked,
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = ref.watch(pWallets).getWallet(walletId) as KerriganWallet;
    final coin = wallet.cryptoCurrency;
    final fmt = ref.watch(pAmountFormatter(coin));
    final public = ref.watch(pWalletBalance(walletId)).spendable;
    final private = ref.watch(pWalletBalanceSecondary(walletId)).spendable;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final coinsTotal = Amount(
      rawValue: funding.coins.fold(
        BigInt.zero,
        (p, u) => p + BigInt.from(u.value),
      ),
      fractionDigits: coin.fractionDigits,
    );
    final change = funding.changeAddress;

    Widget source(String label, bool shield, Amount balance) {
      final selected = funding.fromShield == shield;
      return Expanded(
        child: GestureDetector(
          onTap: selected
              ? null
              : () => onChanged((
                  fromShield: shield,
                  coins: const {},
                  changeAddress: null,
                )),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: selected
                  ? colors.accentColorBlue.withValues(alpha: 0.12)
                  : colors.textFieldDefaultBG,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? colors.accentColorBlue : Colors.transparent,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: STextStyles.w600_14(context).copyWith(
                    color: selected ? colors.accentColorBlue : colors.textDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(fmt.format(balance), style: secondary),
              ],
            ),
          ),
        ),
      );
    }

    Widget row(String title, String value, List<Widget> actions) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: STextStyles.w600_14(context)),
                const SizedBox(height: 2),
                MiddleEllipsisText(value, style: secondary),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );

    final shieldPossible = allowShield && wallet.supportsShield;
    return RoundedWhiteContainer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text("Pay from", style: STextStyles.smallMed12(context)),
          const SizedBox(height: 8),
          Row(
            children: [
              source("Transparent balance", false, public),
              if (shieldPossible) ...[
                const SizedBox(width: 8),
                source("Shielded balance", true, private),
              ],
            ],
          ),
          row(
            funding.fromShield ? "Notes to spend" : "Coins to spend",
            funding.coins.isEmpty
                ? "Chosen automatically"
                : "${funding.coins.length} selected · ${fmt.format(coinsTotal)}",
            [
              if (funding.coins.isNotEmpty)
                CustomTextButton(
                  text: "Reset",
                  onTap: () => onChanged((
                    fromShield: funding.fromShield,
                    coins: const {},
                    changeAddress: funding.changeAddress,
                  )),
                ),
              const SizedBox(width: 12),
              CustomTextButton(
                text: "Choose",
                onTap: () => _chooseCoins(context),
              ),
            ],
          ),
          row(
            "Change address",
            change == null
                ? funding.fromShield
                      ? "Automatic (your private change address)"
                      : "Automatic (a new change address)"
                : change,
            [
              CustomTextButton(
                text: "Choose",
                onTap: () => _chooseChange(context, coin),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
