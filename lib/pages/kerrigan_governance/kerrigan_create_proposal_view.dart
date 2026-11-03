import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/desktop_page_column.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_text_field.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/kerrigan_funding_card.dart';
import 'kerrigan_governance_view.dart';

/// How long masternodes can vote on a new proposal.
List<(String, Duration)> get _durations => [
  (l10n.durationWeeks(1), const Duration(days: 7)),
  (l10n.durationWeeks(2), const Duration(days: 14)),
  (l10n.durationMonths(1), const Duration(days: 30)),
  (l10n.durationMonths(3), const Duration(days: 91)),
  (l10n.durationMonths(6), const Duration(days: 182)),
  (l10n.durationYears(1), const Duration(days: 365)),
];

/// Ask the masternodes to approve a payment: a proposal, or a release
/// from the growth fund escrow. Publishing costs a 1 KRGN fee (burnt);
/// once it has enough confirmations the wallet submits the proposal.
class KerriganCreateProposalView extends ConsumerStatefulWidget {
  const KerriganCreateProposalView({super.key, required this.walletId});

  static const routeName = "/kerriganCreateProposal";

  final String walletId;

  @override
  ConsumerState<KerriganCreateProposalView> createState() =>
      _KerriganCreateProposalViewState();
}

class _KerriganCreateProposalViewState
    extends ConsumerState<KerriganCreateProposalView> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  final _url = TextEditingController(text: "https://");
  final _urlFocus = FocusNode();
  final _amount = TextEditingController();
  final _amountFocus = FocusNode();
  final _otherPayee = TextEditingController();
  final _otherPayeeFocus = FocusNode();

  KerriganProposalType _type = KerriganProposalType.proposal;

  /// One of the wallet's addresses, unless [_payOther].
  String? _payee;
  bool _payOther = false;
  KerriganFunding _funding = kKerriganAutoFunding;
  Duration _duration = _durations[2].$2;

  /// Show errors only for fields the user touched (or after "Pay").
  final _touched = <TextEditingController>{};

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _url, _amount, _otherPayee]) {
      c.addListener(() {
        _touched.add(c);
        setState(() {});
      });
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    final receive = await _wallet.getCurrentReceivingAddress();
    if (!mounted) return;
    setState(() => _payee ??= receive?.value);
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _amount, _otherPayee]) {
      c.dispose();
    }
    for (final f in [_nameFocus, _urlFocus, _amountFocus, _otherPayeeFocus]) {
      f.dispose();
    }
    super.dispose();
  }

  Amount? get _amountValue {
    final d = Decimal.tryParse(_amount.text.trim().replaceAll(",", "."));
    if (d == null || d <= Decimal.zero) return null;
    return d.toAmount(fractionDigits: _wallet.cryptoCurrency.fractionDigits);
  }

  String get _payeeValue => _payOther ? _otherPayee.text.trim() : _payee ?? "";

  Map<TextEditingController, String?> get _errors {
    final wallet = _wallet;
    return {
      _name: wallet.proposalNameError(_name.text.trim()),
      _url: wallet.proposalUrlError(_url.text.trim()),
      _amount: wallet.proposalAmountError(_amountValue),
      if (_payOther) _otherPayee: wallet.proposalAddressError(_payeeValue),
    };
  }

  String? _error(TextEditingController c) =>
      _touched.contains(c) ? _errors[c] : null;

  Future<void> _pay() async {
    final errors = _errors;
    if (errors.values.any((e) => e != null) || _payeeValue.isEmpty) {
      setState(() => _touched.addAll(errors.keys));
      return;
    }
    final wallet = _wallet;
    final now = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
    final prepared =
        await showBuildingTransaction<(TxData, KerriganPendingProposal)>(
          context: context,
          coin: wallet.cryptoCurrency,
          build: () => wallet.prepareProposal(
            type: _type,
            name: _name.text.trim(),
            url: _url.text.trim(),
            paymentAddress: _payeeValue,
            amount: _amountValue!,
            startEpoch: now,
            endEpoch: now + _duration.inSeconds,
            funding: _funding,
          ),
        );
    if (!mounted || prepared == null) return;
    final (txData, proposal) = prepared;
    await Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => DesktopPageColumn(
          card: true,
          child: ConfirmTransactionView(
            txData: txData,
            walletId: widget.walletId,
            // Remembered before the fee goes out: were the app to stop
            // right after sending, the fee would be burnt with nothing
            // left to submit the proposal.
            beforeBroadcast: () =>
                wallet.addPendingProposal(proposal, txData.txid!),
            afterFailedBroadcast: () => wallet.forgetUnsentProposal(proposal),
            onSuccess: () {},
            onSuccessInsteadOfRouteOnSuccess: () {
              if (mounted) {
                Navigator.of(context).popUntil(
                  ModalRoute.withName(KerriganGovernanceView.routeName),
                );
              }
            },
          ),
        ),
        settings: const RouteSettings(name: ConfirmTransactionView.routeName),
      ),
    );
  }

  /// A text field outlined in red, with its error under it, while invalid.
  Widget _field({
    required TextEditingController controller,
    required FocusNode focus,
    required String hint,
    String? helper,
    int? maxLength,
    bool plain = false,
    TextInputType? keyboardType,
    List<TextInputFormatter>? formatters,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final error = _error(controller);
    final border = error == null
        ? null
        : OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: colors.textError, width: 1.5),
          );
    final note = error ?? helper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: TextField(
            controller: controller,
            focusNode: focus,
            autocorrect: !plain,
            enableSuggestions: !plain,
            keyboardType: keyboardType,
            inputFormatters: [
              if (maxLength != null)
                LengthLimitingTextInputFormatter(maxLength),
              ...?formatters,
            ],
            style: STextStyles.field(context),
            decoration: standardInputDecoration(
              hint,
              focus,
              context,
            ).copyWith(enabledBorder: border, focusedBorder: border),
          ),
        ),
        if (note != null || maxLength != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: 12,
              end: 4,
              top: 4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    note ?? "",
                    style: STextStyles.label(context).copyWith(
                      color: error != null
                          ? colors.textError
                          : colors.textSubtitle1,
                    ),
                  ),
                ),
                if (maxLength != null)
                  Text(
                    "${controller.text.length}/$maxLength",
                    style: STextStyles.label(context),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      selectedColor: colors.accentColorBlue.withValues(alpha: 0.18),
      backgroundColor: colors.popupBG,
      side: BorderSide(
        color: selected ? colors.accentColorBlue : colors.textFieldDefaultBG,
      ),
      labelStyle: STextStyles.w600_12(context)
          .copyWith(color: selected ? colors.accentColorBlue : colors.textDark),
      onSelected: (_) => onTap(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final coin = wallet.cryptoCurrency;
    final fmt = ref.watch(pAmountFormatter(coin));
    final label = STextStyles.smallMed12(context);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final fee = Amount(
      rawValue: BigInt.from(kKerriganProposalFeeSats),
      fractionDigits: coin.fractionDigits,
    );
    final balance = _funding.coins.isNotEmpty
        ? Amount(
            rawValue: _funding.coins.fold(
              BigInt.zero,
              (p, u) => p + BigInt.from(u.value),
            ),
            fractionDigits: coin.fractionDigits,
          )
        : _funding.fromShield
        ? wallet.info.cachedBalanceSecondary.spendable
        : wallet.info.cachedBalance.spendable;
    final enoughFunds = balance.raw > fee.raw;
    final escrow = _type == KerriganProposalType.escrowRelease;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text(
            l10n.govCreateProposal,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    RoundedWhiteContainer(
                      child: Text(
                        l10n.govCreateIntroKerrigan(fmt.format(fee)),
                        style: secondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.govKind, style: label),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in KerriganProposalType.values)
                          _chip(
                            t.label,
                            _type == t,
                            () => setState(() => _type = t),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      escrow ? l10n.govEscrowReleaseHint : l10n.govProposalHint,
                      style: secondary,
                    ),
                    const SizedBox(height: 16),
                    Text(l10n.govProposalName, style: label),
                    const SizedBox(height: 8),
                    _field(
                      controller: _name,
                      focus: _nameFocus,
                      hint: l10n.govNameHintKerrigan,
                      helper: l10n.govNameHelperKerrigan,
                      maxLength: kKerriganProposalNameMax,
                      plain: true,
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.govProposalLink, style: label),
                    const SizedBox(height: 8),
                    _field(
                      controller: _url,
                      focus: _urlFocus,
                      hint: "https://…",
                      plain: true,
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(l10n.govPaymentGoesTo, style: label),
                        ),
                        CustomTextButton(
                          text: _payOther
                              ? l10n.govUseMyAddress
                              : l10n.govPayAnotherAddress,
                          onTap: () => setState(() => _payOther = !_payOther),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_payOther)
                      _field(
                        controller: _otherPayee,
                        focus: _otherPayeeFocus,
                        hint: l10n.signTickerAddress(coin.ticker),
                        plain: true,
                      )
                    else
                      KerriganOwnAddressField(
                        walletId: widget.walletId,
                        value: _payee,
                        onChanged: (a) => setState(() => _payee = a),
                      ),
                    const SizedBox(height: 12),
                    Text(l10n.commonAmount, style: label),
                    const SizedBox(height: 8),
                    _field(
                      controller: _amount,
                      focus: _amountFocus,
                      hint: l10n.govAmountTicker(coin.ticker),
                      plain: true,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      formatters: [
                        FilteringTextInputFormatter.allow(RegExp(r"[0-9.,]")),
                      ],
                    ),
                    if (!escrow) ...[
                      const SizedBox(height: 16),
                      Text(l10n.govVotingRunsFor, style: label),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (text, d) in _durations)
                            _chip(
                              text,
                              _duration == d,
                              () => setState(() => _duration = d),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    KerriganFundingCard(
                      walletId: widget.walletId,
                      funding: _funding,
                      amount: fee,
                      onChanged: (f) => setState(() => _funding = f),
                    ),
                    const SizedBox(height: 16),
                    RoundedWhiteContainer(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _summary(l10n.govFeeBurnt, fmt.format(fee)),
                          _summary(
                            _funding.coins.isNotEmpty
                                ? l10n.govSelectedCoins
                                : _funding.fromShield
                                ? l10n.balanceShielded
                                : l10n.balanceTransparent,
                            fmt.format(balance),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            l10n.govAfterFeeKerrigan(
                              kKerriganProposalFeeConfirmations,
                              kKerriganProposalFeeConfirmations *
                                  coin.targetBlockTimeSeconds ~/
                                  60,
                            ),
                            style: secondary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  label: enoughFunds
                      ? l10n.govPayAndPublish(fmt.format(fee))
                      : l10n.govNotEnoughForFee(coin.ticker),
                  enabled: enoughFunds,
                  onPressed: _pay,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary(String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: STextStyles.w500_12(context).copyWith(
              color: Theme.of(context).extension<StackColors>()!.textSubtitle1,
            ),
          ),
        ),
        Text(value, style: STextStyles.w600_12(context)),
      ],
    ),
  );
}
