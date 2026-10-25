import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/locale_provider.dart';
import '../../providers/global/prefs_provider.dart';
import '../../providers/global/price_provider.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/assets.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/desktop_page_column.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/kerrigan_memo_field.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_text_field.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/kerrigan_funding_card.dart';
import 'kerrigan_donation.dart';
import 'kerrigan_donation_controls.dart';
import 'kerrigan_donation_stage.dart';

/// "Fuel Delta": pick a donation size on a slider and watch Delta power
/// up, pick the balance (the Shielded switch: the dark, shielded Delta or
/// the light, transparent one) and the coins, add a cheers message, slide
/// to send. Paid to [kerriganDonationAddress].
class KerriganDonationView extends ConsumerStatefulWidget {
  const KerriganDonationView({super.key, required this.walletId});

  static const routeName = "/kerriganDonation";

  final String walletId;

  @override
  ConsumerState<KerriganDonationView> createState() =>
      _KerriganDonationViewState();
}

/// What the stage shows.
typedef _Look = ({
  String art,
  KerriganDonationTier mood,
  KerriganDonationEgg? egg,
});

class _KerriganDonationViewState extends ConsumerState<KerriganDonationView> {
  /// In [KerriganDonationTier.values]: the fixed tiers, then the custom
  /// amount.
  int _index = KerriganDonationTier.cell.index;
  late KerriganFunding _funding;

  /// Whether the balance or the coins were picked: the default no longer
  /// follows the price.
  bool _fundingChosen = false;

  /// KRGN in US dollars; null while [_priceLoading] or when unknown.
  Decimal? _price;
  bool _priceLoading = true;

  final _custom = TextEditingController();
  final _customFocus = FocusNode();
  bool _customInKrgn = false;

  final _message = TextEditingController();
  final _messageFocus = FocusNode();

  bool _sending = false;

  /// After a donation: the stage that thanks for it.
  _Look? _thanks;

  KerriganDonationTier get _tier => KerriganDonationTier.values[_index];

  @override
  void initState() {
    super.initState();
    final price = _appUsdPrice();
    _funding = _defaultFunding(
      price == null
          ? null
          : kerriganDonationKrgn(Decimal.fromInt(_tier.usd!), price),
    );
    unawaited(_loadPrice());
    // Opened once: the More menu stops pointing here.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(prefsChangeNotifierProvider).donationSeen = true,
    );
  }

  @override
  void dispose() {
    _custom.dispose();
    _customFocus.dispose();
    _message.dispose();
    _messageFocus.dispose();
    super.dispose();
  }

  /// The shielded balance when it pays [krgn], else the transparent one
  /// when that does; else (or with [krgn] unknown) whichever has coins,
  /// shielded first.
  KerriganFunding _defaultFunding(Decimal? krgn) {
    final wallet =
        ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;
    final shield = ref.read(pWalletBalanceSecondary(widget.walletId)).spendable;
    final transparent = ref.read(pWalletBalance(widget.walletId)).spendable;
    final want = krgn == null
        ? null
        : Amount.fromDecimal(
            krgn,
            fractionDigits: wallet.cryptoCurrency.fractionDigits,
          );
    bool pays(Amount balance) =>
        want == null ? balance > Amount.zero : balance >= want;
    final fromShield =
        wallet.supportsShield &&
        (pays(shield) || (!pays(transparent) && shield > Amount.zero));
    return (fromShield: fromShield, coins: const {}, changeAddress: null);
  }

  /// The price the app already has, when its currency is the dollar.
  Decimal? _appUsdPrice() {
    if (ref.read(prefsChangeNotifierProvider).currency != "USD") return null;
    final price = ref
        .read(priceAnd24hChangeNotifierProvider)
        .getPrice(ref.read(pWalletCoin(widget.walletId)))
        ?.value;
    return price == null || price <= Decimal.zero ? null : price;
  }

  Future<void> _loadPrice() async {
    final price = _appUsdPrice() ?? await kerriganUsdPrice();
    if (!mounted) return;
    setState(() {
      _price = price;
      _priceLoading = false;
      if (price == null) _customInKrgn = true;
      // The price may say the default balance can't pay.
      if (!_fundingChosen) _funding = _defaultFunding(_value.krgn);
    });
  }

  /// The custom amount as typed, when it is one.
  Decimal? get _typed {
    final value = Decimal.tryParse(_custom.text.trim().replaceAll(",", "."));
    return value == null || value <= Decimal.zero ? null : value;
  }

  /// The donation in dollars and in KRGN, each null where unknown.
  ({Decimal? usd, Decimal? krgn}) get _value {
    final price = _price;
    final tier = _tier;
    if (!tier.isCustom) {
      final usd = Decimal.fromInt(tier.usd!);
      return (
        usd: usd,
        krgn: price == null ? null : kerriganDonationKrgn(usd, price),
      );
    }
    final typed = _typed;
    if (typed == null) return (usd: null, krgn: null);
    if (_customInKrgn) {
      return (usd: price == null ? null : typed * price, krgn: typed);
    }
    return (
      usd: typed,
      krgn: price == null ? null : kerriganDonationKrgn(typed, price),
    );
  }

  _Look _look(({Decimal? usd, Decimal? krgn}) value) {
    final tier = _tier;
    final usd = value.usd;
    final egg = tier.isCustom && usd != null
        ? KerriganDonationEgg.of(usd)
        : null;
    final mood = !tier.isCustom
        ? tier
        : egg == KerriganDonationEgg.overload
        // Holding its own power cell, next to the giant one.
        ? KerriganDonationTier.cell
        // Up to $100, the tier the amount pays for; past it (or until there
        // is an amount) the custom art.
        : usd != null && usd < Decimal.fromInt(100)
        ? KerriganDonationTier.artFor(usd)
        : KerriganDonationTier.custom;
    return (art: mood.art(shielded: _funding.fromShield), mood: mood, egg: egg);
  }

  void _setShield(bool shield) {
    if (shield == _funding.fromShield) return;
    HapticFeedback.selectionClick();
    setState(() {
      _fundingChosen = true;
      _funding = (fromShield: shield, coins: const {}, changeAddress: null);
    });
  }

  /// Switches the custom amount between dollars and KRGN, converting what
  /// is typed.
  void _toggleCustomUnit() {
    final value = _value;
    setState(() {
      _customInKrgn = !_customInKrgn;
      final converted = _customInKrgn ? value.krgn : value.usd;
      final text = converted == null
          ? ""
          : _customInKrgn
          ? converted.toString()
          : converted.round(scale: 2).toString();
      _custom.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  Future<void> _chooseFunding(Amount? amount) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _FundingSheet(
      walletId: widget.walletId,
      initial: _funding,
      amount: amount,
      onChanged: (funding) => setState(() {
        _fundingChosen = true;
        _funding = funding;
      }),
    ),
  );

  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    try {
      FocusScope.of(context).unfocus();
      final wallet =
          ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;
      final coin = wallet.cryptoCurrency;
      final tier = _tier;
      final value = _value;
      final krgn = value.krgn;
      final address = kerriganDonationAddress(coin);
      if (krgn == null || address == null) return;
      final look = _look(value);
      final funding = _funding;
      final memo = kerriganDonationMemo(
        tier: tier,
        shielded: funding.fromShield,
        usd: value.usd,
        message: _message.text,
      );

      final txData = await showBuildingTransaction<TxData>(
        context: context,
        coin: coin,
        build: () => prepareKerriganDonation(
          wallet,
          address: address,
          amount: Amount.fromDecimal(krgn, fractionDigits: coin.fractionDigits),
          memo: memo,
          note: l10n.donateNote(tier.title(shielded: funding.fromShield)),
          funding: funding,
        ),
      );
      if (!mounted || txData == null) return;

      final navigator = Navigator.of(context);
      await navigator.push(
        RouteGenerator.getRoute<void>(
          shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
          builder: (_) => DesktopPageColumn(
            card: true,
            child: ConfirmTransactionView(
              txData: txData,
              walletId: widget.walletId,
              onSuccess: () {},
              onSuccessInsteadOfRouteOnSuccess: () {
                navigator.popUntil(
                  ModalRoute.withName(KerriganDonationView.routeName),
                );
                if (mounted) {
                  setState(() {
                    _thanks = look;
                    _message.clear();
                  });
                }
              },
            ),
          ),
          settings: const RouteSettings(name: ConfirmTransactionView.routeName),
        ),
      );
    } finally {
      _sending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet =
        ref.watch(pWallets).getWallet(widget.walletId) as KerriganWallet;
    final palette = KerriganDonationPalette.of(shielded: _funding.fromShield);
    final thanks = _thanks;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text(
            l10n.donateTitle,
            style: Util.isDesktop
                ? STextStyles.desktopH3(context)
                : STextStyles.navBarTitle(context),
          ),
          actions: [
            if (wallet.supportsShield && thanks == null)
              _ShieldSwitch(
                value: _funding.fromShield,
                onChanged: _setShield,
                palette: palette,
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: thanks == null
                  ? _form(context, wallet, palette)
                  : _thanked(context, thanks),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(
    BuildContext context,
    KerriganWallet wallet,
    KerriganDonationPalette palette,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final coin = wallet.cryptoCurrency;
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((value) => value.locale),
    );
    final fmt = ref.watch(pAmountFormatter(coin));
    final tier = _tier;
    final value = _value;
    final look = _look(value);
    final amount = value.krgn == null
        ? null
        : Amount.fromDecimal(value.krgn!, fractionDigits: coin.fractionDigits);

    final fromShield = _funding.fromShield;
    final shield = ref
        .watch(pWalletBalanceSecondary(widget.walletId))
        .spendable;
    final transparent = ref.watch(pWalletBalance(widget.walletId)).spendable;
    final balance = fromShield ? shield : transparent;
    final other = fromShield ? transparent : shield;
    final short = amount != null && amount > balance;
    final otherPays =
        amount != null &&
        short &&
        amount <= other &&
        (fromShield || wallet.supportsShield);

    final usd = value.usd;
    final title = [
      if (usd != null && (!tier.isCustom || !_customInKrgn))
        kerriganDonationUsdText(usd, locale),
      "${tier.title(shielded: fromShield)} ${tier.emoji}",
    ].join(" • ");
    final krgnLine = value.krgn == null
        ? null
        : tier.isCustom && _customInKrgn
        ? [
            kerriganDonationKrgnText(value.krgn!, coin.ticker, locale),
            if (usd != null)
              "≈ ${kerriganDonationUsdText(usd.round(scale: 2), locale)}",
          ].join(" ")
        : "≈ ${kerriganDonationKrgnText(value.krgn!, coin.ticker, locale)}";
    final description =
        look.egg?.text ?? tier.description(shielded: fromShield);
    final address = kerriganDonationAddress(coin) ?? "";

    String? priceNote;
    if (!tier.isCustom && _price == null) {
      priceNote = _priceLoading ? l10n.donatePriceLoading : l10n.donateNoPrice;
    }

    final subtle = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              KerriganDonationStage(
                art: look.art,
                mood: look.mood,
                shielded: fromShield,
                egg: look.egg,
              ),
              const SizedBox(height: 14),
              Text(
                (fromShield
                        ? l10n.donateDeltaShielded
                        : l10n.donateDeltaTransparent)
                    .toUpperCase(),
                textAlign: TextAlign.center,
                style: subtle.copyWith(letterSpacing: 1.2),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                textAlign: TextAlign.center,
                style: STextStyles.pageTitleH2(context),
              ),
              if (krgnLine != null) ...[
                const SizedBox(height: 2),
                Text(
                  krgnLine,
                  textAlign: TextAlign.center,
                  style: STextStyles.w500_14(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
              const SizedBox(height: 8),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    description,
                    key: ValueKey(description),
                    textAlign: TextAlign.center,
                    style: STextStyles.itemSubtitle(context),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              KerriganDonationTierSlider(
                labels: [
                  for (final t in KerriganDonationTier.fixed)
                    kerriganDonationUsdText(Decimal.fromInt(t.usd!), locale),
                  l10n.donateCustom,
                ],
                index: _index,
                palette: palette,
                semanticLabel: l10n.donateSize,
                onChanged: (i) => setState(() => _index = i),
              ),
              if (priceNote != null) ...[
                const SizedBox(height: 12),
                Text(priceNote, textAlign: TextAlign.center, style: subtle),
              ],
              if (tier.isCustom) ...[
                const SizedBox(height: 16),
                _customField(context, coin.ticker),
              ],
              const SizedBox(height: 20),
              Text(l10n.sendPayFrom, style: STextStyles.smallMed12(context)),
              const SizedBox(height: 8),
              _payFrom(context, fmt, balance, amount, palette),
              if (short) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        fromShield
                            ? l10n.donateNotEnoughShielded
                            : l10n.donateNotEnoughTransparent,
                        style: STextStyles.errorSmall(context),
                      ),
                    ),
                    if (otherPays)
                      CustomTextButton(
                        text: fromShield
                            ? l10n.donateUseTransparent
                            : l10n.donateUseShielded,
                        onTap: () => _setShield(!fromShield),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Text(l10n.donateCheers, style: STextStyles.smallMed12(context)),
              const SizedBox(height: 8),
              KerriganMemoField(
                key: const ValueKey("donation-cheers"),
                controller: _message,
                focusNode: _messageFocus,
                maxBytes: kKerriganDonationMessageBytes,
                hint: l10n.donateCheersHint,
              ),
              const SizedBox(height: 6),
              Text(l10n.donateCheersNote, style: subtle),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            children: [
              KerriganSlideToConfirm(
                label: l10n.donateSlide,
                palette: palette,
                enabled: amount != null && !short,
                onConfirmed: _send,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.donateTo(kerriganDonationShortAddress(address)),
                textAlign: TextAlign.center,
                style: subtle,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _customField(BuildContext context, String ticker) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final canSwitch = _price != null;
    final unit = _customInKrgn ? ticker : "USD";
    return TextField(
      // Kept by key: the lines above it come and go as the amount is typed,
      // and a rebuilt field would lose the focus.
      key: const ValueKey("donation-amount"),
      controller: _custom,
      focusNode: _customFocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_AmountFormatter(decimals: _customInKrgn ? 8 : 2)],
      style: STextStyles.field(context),
      onChanged: (_) => setState(() {}),
      decoration:
          standardInputDecoration(
            l10n.commonAmount,
            _customFocus,
            context,
          ).copyWith(
            prefixText: _customInKrgn ? null : "\$ ",
            suffixIcon: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: canSwitch
                  ? TextButton.icon(
                      onPressed: _toggleCustomUnit,
                      icon: Icon(
                        Icons.swap_horiz_rounded,
                        size: 18,
                        color: colors.accentColorBlue,
                      ),
                      label: Text(
                        unit,
                        style: STextStyles.w600_14(context)
                            .copyWith(color: colors.accentColorBlue),
                      ),
                    )
                  : Center(
                      widthFactor: 1,
                      child: Text(unit, style: STextStyles.w600_14(context)),
                    ),
            ),
          ),
    );
  }

  Widget _payFrom(
    BuildContext context,
    AmountFormatter fmt,
    Amount balance,
    Amount? amount,
    KerriganDonationPalette palette,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final coins = _funding.coins;
    final coinsTotal = Amount(
      rawValue: coins.fold(BigInt.zero, (p, u) => p + BigInt.from(u.value)),
      fractionDigits: balance.fractionDigits,
    );
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _chooseFunding(amount),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.glow.withValues(alpha: 0.15),
                ),
                child: Icon(
                  _funding.fromShield
                      ? Icons.shield_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                  color: colors.accentColorBlue,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _funding.fromShield
                          ? l10n.balanceShielded
                          : l10n.balanceTransparent,
                      style: STextStyles.w600_14(context),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.donateAvailable(fmt.format(balance)),
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                    if (coins.isNotEmpty)
                      Text(
                        l10n.sendCoinsSelected(
                          coins.length,
                          fmt.format(coinsTotal),
                        ),
                        style: STextStyles.w500_12(context)
                            .copyWith(color: colors.textSubtitle1),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              CustomTextButton(
                text: l10n.commonChange,
                onTap: () => _chooseFunding(amount),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thanked(BuildContext context, _Look look) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              KerriganDonationStage(
                art: Assets.donation.thanks(shielded: _funding.fromShield),
                mood: look.mood,
                shielded: _funding.fromShield,
                celebrating: true,
              ),
              const SizedBox(height: 20),
              Text(
                _funding.fromShield
                    ? l10n.donateThanksTitleShielded
                    : l10n.donateThanksTitle,
                textAlign: TextAlign.center,
                style: STextStyles.pageTitleH1(context),
              ),
              const SizedBox(height: 8),
              Text(
                _funding.fromShield
                    ? l10n.donateThanksTextShielded
                    : l10n.donateThanksText,
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.donateOnItsWay,
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle(context),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: SecondaryButton(
                  label: l10n.donateAgain,
                  onPressed: () => setState(() => _thanks = null),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PrimaryButton(
                  label: l10n.commonDone,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The app bar's Shielded switch: pays from the shielded balance (and
/// shows the dark, shielded Delta) or from the transparent one.
class _ShieldSwitch extends StatelessWidget {
  const _ShieldSwitch({
    required this.value,
    required this.onChanged,
    required this.palette,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final KerriganDonationPalette palette;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: MergeSemantics(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  value ? Icons.shield_rounded : Icons.shield_outlined,
                  size: 16,
                  color: value ? colors.accentColorBlue : colors.textSubtitle1,
                ),
                const SizedBox(width: 4),
                Text(
                  l10n.donateShielded,
                  style: STextStyles.w500_12(context).copyWith(
                    color: value ? colors.textDark : colors.textSubtitle1,
                  ),
                ),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: value,
                    onChanged: onChanged,
                    activeTrackColor: palette.glow,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Up to twelve whole digits and [decimals] decimals, with "." or ",".
class _AmountFormatter extends TextInputFormatter {
  _AmountFormatter({required int decimals})
    : _pattern = RegExp("^\\d{0,12}([.,]\\d{0,$decimals})?\$");

  final RegExp _pattern;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => _pattern.hasMatch(newValue.text) ? newValue : oldValue;
}

/// "Change" on the Pay from row: the balance, the coins (or notes) to
/// spend and the change address, as on the other Kerrigan payment screens.
class _FundingSheet extends ConsumerStatefulWidget {
  const _FundingSheet({
    required this.walletId,
    required this.initial,
    required this.amount,
    required this.onChanged,
  });

  final String walletId;
  final KerriganFunding initial;
  final Amount? amount;
  final ValueChanged<KerriganFunding> onChanged;

  @override
  ConsumerState<_FundingSheet> createState() => _FundingSheetState();
}

class _FundingSheetState extends ConsumerState<_FundingSheet> {
  late KerriganFunding _funding = widget.initial;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Container(
          decoration: BoxDecoration(
            color: colors.popupBG,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KerriganFundingCard(
                  walletId: widget.walletId,
                  funding: _funding,
                  amount: widget.amount,
                  toShield: true,
                  onChanged: (funding) {
                    setState(() => _funding = funding);
                    widget.onChanged(funding);
                  },
                ),
                const SizedBox(height: 16),
                PrimaryButton(
                  label: l10n.commonDone,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
