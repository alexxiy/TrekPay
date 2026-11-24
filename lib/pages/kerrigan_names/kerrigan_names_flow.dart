import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/barcode_scanner_provider.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../services/kerrigan_name/kerrigan_name.dart';
import '../../services/kerrigan_name/kerrigan_names_protocol.dart';
import '../../services/kerrigan_name/kerrigan_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/amount/amount_unit.dart';
import '../../utilities/constants.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/desktop_page_column.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/icon_widgets/clipboard_icon.dart';
import '../../widgets/icon_widgets/qrcode_icon.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_text_field.dart';
import '../../widgets/toggle.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/kerrigan_funding_card.dart';
import 'kerrigan_names_common.dart';
import 'kerrigan_names_in_flight.dart';
import 'kerrigan_names_status_view.dart';

/// One command on a name, from choosing what it does to paying for it.
class KerriganNamesFlow {
  const KerriganNamesFlow({
    required this.walletId,
    required this.op,
    required this.name,
    required this.returnTo,
    required this.price,
    this.currentAddress,
    this.listedPrice,
  });

  final String walletId;
  final KerriganNamesOp op;
  final String name;

  /// The screen to come back to once paid (its route name).
  final String returnTo;

  /// What the command costs, as the registrar said: the price of a
  /// registration or a purchase, an update's for the others.
  final BigInt price;

  /// Where the name points now (a change of destination).
  final String? currentAddress;

  /// The name's price on the marketplace now (a new price).
  final BigInt? listedPrice;

  String get title => switch (op) {
    KerriganNamesOp.reg => l10n.kerriganNamesFlowRegister(
      kerriganNamesUnbroken(name),
    ),
    KerriganNamesOp.buy => l10n.kerriganNamesFlowBuy(
      kerriganNamesUnbroken(name),
    ),
    KerriganNamesOp.upd => l10n.kerriganNamesFlowChangeDestination,
    KerriganNamesOp.chg => l10n.kerriganNamesFlowChangeOwner,
    KerriganNamesOp.lst =>
      listedPrice == null
          ? l10n.kerriganNamesFlowList
          : l10n.kerriganNamesFlowChangePrice,
    KerriganNamesOp.ult => l10n.kerriganNamesFlowUnlist(
      kerriganNamesUnbroken(name),
    ),
  };
}

/// A signed command and where to pay it.
class KerriganNamesPayment {
  const KerriganNamesPayment({
    required this.flow,
    required this.address,
    required this.amount,
    required this.memo,
  });

  final KerriganNamesFlow flow;

  /// The registrar's shield address.
  final String address;

  /// In satoshis. Exact: the registrar refunds any other amount.
  final BigInt amount;

  /// The command and its signature.
  final String memo;
}

KerriganWallet _walletOf(WidgetRef ref, String walletId) =>
    ref.read(pWallets).getWallet(walletId) as KerriganWallet;

/// The route name of the screen [context] is on, to come back to.
String kerriganNamesRouteOf(BuildContext context) =>
    ModalRoute.of(context)?.settings.name ?? "/";

/// Starts [flow]: its target (address, owner or price) first, except an
/// unlisting, which has none and goes straight to payment.
Future<void> startKerriganNamesFlow(
  BuildContext context,
  WidgetRef ref,
  KerriganNamesFlow flow,
) async {
  if (flow.op != KerriganNamesOp.ult) {
    await Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) =>
            DesktopPageColumn(child: KerriganNamesTargetView(flow: flow)),
        settings: const RouteSettings(name: KerriganNamesTargetView.routeName),
      ),
    );
    return;
  }
  final wallet = _walletOf(ref, flow.walletId);
  final payment = await _sign(context, wallet, flow);
  if (payment == null || !context.mounted) return;
  await _openPayment(context, payment);
}

/// Signs the command of [flow] with [target], [newOwner] or [priceSats],
/// behind a loading screen. Null (after telling the user) on failure.
Future<KerriganNamesPayment?> _sign(
  BuildContext context,
  KerriganWallet wallet,
  KerriganNamesFlow flow, {
  String? target,
  String? newOwner,
  BigInt? priceSats,
}) async {
  Object? error;
  final payment = await showLoading<KerriganNamesPayment>(
    context: context,
    message: l10n.kerriganNamesSigning,
    onException: (e) => error = e,
    whileFutureAlt: () async {
      final registrar = KerriganNamesRegistrar.forCoin(wallet.cryptoCurrency)!;
      final info = await registrar.paymentInfo();
      final identity = await wallet.namesIdentity();
      final command = kerriganNamesCommand(
        marker: registrar.service.marker,
        op: flow.op,
        name: flow.name,
        nonce: await registrar.commandNonce(flow.name),
        pubkey: identity.publicKey,
        target: target,
        newOwner: newOwner,
        priceSats: priceSats,
      );
      if (!kerriganNamesCommandFits(command)) {
        throw KerriganNamesException(l10n.kerriganNamesMemoTooLong);
      }
      return KerriganNamesPayment(
        flow: flow,
        address: info.address,
        amount: flow.price,
        memo: "$command:${await identity.sign(command)}",
      );
    },
  );
  if (payment == null && context.mounted) {
    await showKerriganNamesError(
      context,
      error ?? l10n.kerriganNamesSigningFailed,
    );
  }
  return payment;
}

Future<void> _openPayment(BuildContext context, KerriganNamesPayment payment) =>
    Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => DesktopPageColumn(
          child: KerriganNamesPaymentView(payment: payment),
        ),
        settings: const RouteSettings(name: KerriganNamesPaymentView.routeName),
      ),
    );

// =============================================================================
// Target

/// What a command needs: the address a name points to (register, buy,
/// change destination), the new owner's key (change owner) or the price
/// (list).
class KerriganNamesTargetView extends ConsumerStatefulWidget {
  const KerriganNamesTargetView({super.key, required this.flow});

  static const routeName = "/kerriganNamesTarget";

  final KerriganNamesFlow flow;

  @override
  ConsumerState<KerriganNamesTargetView> createState() =>
      _KerriganNamesTargetViewState();
}

/// What the target screen's text field takes.
enum _Input { key, price, address }

class _KerriganNamesTargetViewState
    extends ConsumerState<KerriganNamesTargetView> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  /// The address picked from the wallet's own.
  String? _target;

  /// The name points to an address typed in (in [_text]) instead of one of
  /// the wallet's.
  bool _custom = false;
  String? _ownKey;
  bool _touched = false;

  KerriganNamesFlow get _flow => widget.flow;
  KerriganWallet get _wallet => _walletOf(ref, _flow.walletId);

  // The price is typed in the wallet's unit (mPIV and so on): its decimal
  // places below KRGN, and its name.
  AmountUnit get _unit => ref.read(pAmountUnit(_wallet.cryptoCurrency));
  int get _shift =>
      math.min(_unit.shift, _wallet.cryptoCurrency.fractionDigits);

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() => _touched = true));
    _focus.addListener(() => setState(() {}));
    final listed = _flow.listedPrice;
    if (listed != null) _text.text = kerriganNamesCoins(listed, shift: _shift);
    _touched = false;
    unawaited(_load());
  }

  Future<void> _load() async {
    final wallet = _wallet;
    if (_flow.op.hasTarget) {
      final current = await wallet.getCurrentShieldAddress();
      if (mounted && _target == null && current != _flow.currentAddress) {
        setState(() => _target = current);
      }
    }
    if (_flow.op == KerriganNamesOp.chg) {
      try {
        final key = await kerriganNamesPublicKey(wallet);
        if (mounted) setState(() => _ownKey = key);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _newOwner => _text.text.trim().toLowerCase();

  /// The bare address in [raw]: a scanned or pasted "kerrigan:<address>?..."
  /// link gives its address. Lowercase, as the registry keeps it (QR codes
  /// often spell bech32 in capitals).
  static String _addressIn(String raw) {
    var text = raw.trim().split("\n").first;
    if (text.contains(":")) text = text.substring(text.indexOf(":") + 1);
    return text.split("?").first.trim().toLowerCase();
  }

  /// Where the name will point: the picked or the typed address.
  String? get _destination => _custom ? _addressIn(_text.text) : _target;

  /// Why the input can't be used yet (null: it can).
  String? get _error {
    switch (_flow.op) {
      case KerriganNamesOp.reg:
      case KerriganNamesOp.upd:
      case KerriganNamesOp.buy:
        final target = _destination;
        if (target == null) return l10n.kerriganNamesChooseAddress;
        if (target.isEmpty) return "";
        if (target == _flow.currentAddress) {
          return l10n.kerriganNamesAlreadyPointsHere(_flow.name);
        }
        if (!isValidKerriganNamesTarget(target)) {
          return target.startsWith(kKerriganNameTargetPrefix)
              ? l10n.kerriganNamesInvalidShieldAddress
              : l10n.kerriganNamesShieldOnly;
        }
        return null;
      case KerriganNamesOp.chg:
        final key = _newOwner;
        if (key.isEmpty) return "";
        if (key == _ownKey) return l10n.kerriganNamesOwnKey;
        if (!isValidKerriganNamesPublicKey(key)) {
          return l10n.kerriganNamesInvalidPublicKey;
        }
        return null;
      case KerriganNamesOp.lst:
        if (_text.text.trim().isEmpty) return "";
        if (parseKerriganNamesPrice(_text.text, shift: _shift) == null) {
          final coin = _wallet.cryptoCurrency;
          final max = kerriganNamesAmount(
            BigInt.from(kKerriganNamesMaxListingPrice) *
                BigInt.from(10).pow(coin.fractionDigits),
            ref,
            _wallet,
          );
          final decimals = coin.fractionDigits - _shift;
          return decimals > 0
              ? l10n.kerriganNamesInvalidPrice(max, decimals)
              : l10n.kerriganNamesInvalidPriceWhole(max);
        }
        return null;
      case KerriganNamesOp.ult:
        return null;
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _text.text = _custom ? _addressIn(text) : text;
  }

  Future<void> _scan() async {
    if (FocusScope.of(context).hasFocus) {
      FocusScope.of(context).unfocus();
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    if (!mounted) return;
    final result = await ref.read(pBarcodeScanner).scan(context: context);
    final raw = result.rawContent?.trim();
    if (raw != null && raw.isNotEmpty) _text.text = _addressIn(raw);
  }

  Future<void> _next() async {
    final payment = await _sign(
      context,
      _wallet,
      _flow,
      target: _flow.op.hasTarget ? _destination : null,
      newOwner: _flow.op == KerriganNamesOp.chg ? _newOwner : null,
      priceSats: _flow.op == KerriganNamesOp.lst
          ? parseKerriganNamesPrice(_text.text, shift: _shift)
          : null,
    );
    if (payment == null || !mounted) return;
    await _openPayment(context, payment);
  }

  Widget _field({
    required String hint,
    Widget? suffix,
    _Input input = _Input.key,
  }) {
    final price = input == _Input.price;
    final colors = Theme.of(context).extension<StackColors>()!;
    final error = _touched ? _error : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The red outline is drawn over the field: as the field's own
        // border, it would pull the label up into it.
        DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: error == null || error.isEmpty
                ? null
                : Border.all(color: colors.textError, width: 1.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TextField(
              controller: _text,
              textDirection: TextDirection.ltr,
              focusNode: _focus,
              autocorrect: false,
              enableSuggestions: false,
              minLines: price ? 1 : 2,
              maxLines: price ? 1 : 3,
              keyboardType: price
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              inputFormatters: switch (input) {
                _Input.price => [
                  FilteringTextInputFormatter.allow(RegExp(r"[0-9.]")),
                ],
                _Input.key => [
                  FilteringTextInputFormatter.allow(RegExp(r"[0-9a-fA-F]")),
                ],
                // Pasted links are cut to their address when used.
                _Input.address => null,
              },
              style: STextStyles.field(context),
              decoration: standardInputDecoration(
                hint,
                _focus,
                context,
              ).copyWith(suffixIcon: suffix),
            ),
          ),
        ),
        if (error != null && error.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: 12,
              end: 4,
              top: 4,
            ),
            child: Text(
              error,
              style: STextStyles.label(context)
                  .copyWith(color: colors.textError),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final secondary = STextStyles.itemSubtitle(context);
    final op = _flow.op;
    final cost = _flow.price;
    final error = _error;
    final listedPrice = _flow.listedPrice;
    final listed = listedPrice == null
        ? null
        : kerriganNamesAmount(listedPrice, ref, wallet, exact: true);
    final targetError = op.hasTarget ? error : null;

    final name = kerriganNamesUnbroken(_flow.name);
    final (String heading, String text) = switch (op) {
      KerriganNamesOp.reg || KerriganNamesOp.buy => (
        l10n.kerriganNamesWherePoint(name),
        l10n.kerriganNamesWherePointText(name),
      ),
      KerriganNamesOp.upd => (
        l10n.kerriganNamesNewDestination,
        l10n.kerriganNamesNewDestinationText(name),
      ),
      KerriganNamesOp.chg => (
        l10n.kerriganNamesWhoOwns(name),
        l10n.kerriganNamesWhoOwnsText,
      ),
      KerriganNamesOp.lst => (
        _flow.listedPrice == null
            ? l10n.kerriganNamesSetPrice(name)
            : l10n.kerriganNamesSetNewPrice(name),
        l10n.kerriganNamesSetPriceText,
      ),
      KerriganNamesOp.ult => ("", ""),
    };

    final costLine = switch (op) {
      KerriganNamesOp.reg => l10n.kerriganNamesCostRegistration(
        kerriganNamesAmount(cost, ref, wallet),
      ),
      KerriganNamesOp.buy => l10n.kerriganNamesCostPrice(
        kerriganNamesAmount(cost, ref, wallet),
      ),
      _ => l10n.kerriganNamesCostChange(kerriganNamesAmount(cost, ref, wallet)),
    };

    return Background(
      child: AppScaffold(
        backgroundColor: colors.background,
        appBar: kerriganNamesFlowAppBar(context, _flow.title),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    const KerriganNamesSteps(step: KerriganNamesStep.check),
                    const SizedBox(height: 20),
                    KerriganNamesNameText(_flow.name),
                    const SizedBox(height: 12),
                    Text(heading, style: STextStyles.pageTitleH2(context)),
                    const SizedBox(height: 6),
                    Text(text, style: secondary),
                    const SizedBox(height: 16),
                    if (op.hasTarget) ...[
                      SizedBox(
                        height: 48,
                        child: Toggle(
                          onColor: Util.isDesktop
                              ? colors.rateTypeToggleDesktopColorOn
                              : colors.popupBG,
                          onText: l10n.kerriganNamesMyAddresses,
                          offColor: Util.isDesktop
                              ? colors.rateTypeToggleDesktopColorOff
                              : colors.textFieldDefaultBG,
                          offText: l10n.kerriganNamesAnotherAddress,
                          isOn: _custom,
                          onValueChanged: (custom) => setState(() {
                            _custom = custom;
                            _touched = false;
                          }),
                          decoration: BoxDecoration(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(
                              Constants.size.circularBorderRadius,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (op.hasTarget && _custom)
                      _field(
                        hint: l10n.kerriganNamesShieldAddress,
                        input: _Input.address,
                        suffix: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: l10n.commonPaste,
                              onPressed: _paste,
                              icon: const ClipboardIcon(),
                            ),
                            IconButton(
                              tooltip: l10n.qrScanTitle,
                              onPressed: _scan,
                              icon: const QrCodeIcon(),
                            ),
                          ],
                        ),
                      )
                    else if (op.hasTarget) ...[
                      KerriganOwnAddressField(
                        walletId: _flow.walletId,
                        value: _target,
                        shield: true,
                        placeholder: l10n.kerriganNamesChooseAddress,
                        tags: {
                          if (_flow.currentAddress != null)
                            _flow.currentAddress!:
                                l10n.kerriganNamesCurrentDestination,
                        },
                        onChanged: (a) => setState(() {
                          _target = a;
                          _touched = true;
                        }),
                      ),
                      if (_touched && targetError != null)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: 12,
                            top: 4,
                          ),
                          child: Text(
                            targetError,
                            style: STextStyles.label(context)
                                .copyWith(color: colors.textError),
                          ),
                        ),
                    ],
                    if (op == KerriganNamesOp.chg) ...[
                      _field(
                        hint: l10n.kerriganNamesNewOwnerKey,
                        suffix: IconButton(
                          tooltip: l10n.commonPaste,
                          onPressed: _paste,
                          icon: const ClipboardIcon(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        borderColor: colors.accentColorOrange,
                        child: Text(
                          l10n.kerriganNamesNewOwnerWarning(name),
                          style: STextStyles.w500_12(context),
                        ),
                      ),
                    ],
                    if (op == KerriganNamesOp.lst) ...[
                      _field(
                        hint: l10n.kerriganNamesPrice,
                        input: _Input.price,
                        suffix: Padding(
                          padding: const EdgeInsetsDirectional.only(
                            end: 14,
                            top: 14,
                          ),
                          child: Text(
                            _unit.unitForCoin(wallet.cryptoCurrency),
                            style: STextStyles.w600_14(context)
                                .copyWith(color: colors.textSubtitle1),
                          ),
                        ),
                      ),
                      if (listed != null)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(
                            start: 12,
                            top: 4,
                          ),
                          child: Text(
                            l10n.kerriganNamesListedNow(listed),
                            style: STextStyles.label(context)
                                .copyWith(color: colors.textSubtitle1),
                          ),
                        ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      costLine,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  width: double.infinity,
                  label: l10n.commonNext,
                  enabled: error == null,
                  onPressed: _next,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Payment

/// The payment of a signed command: where it goes, the amount and the
/// memo (as the web app shows them), how the wallet pays it, then the
/// transaction.
class KerriganNamesPaymentView extends ConsumerStatefulWidget {
  const KerriganNamesPaymentView({super.key, required this.payment});

  static const routeName = "/kerriganNamesPayment";

  final KerriganNamesPayment payment;

  @override
  ConsumerState<KerriganNamesPaymentView> createState() =>
      _KerriganNamesPaymentViewState();
}

class _KerriganNamesPaymentViewState
    extends ConsumerState<KerriganNamesPaymentView> {
  KerriganFunding _funding = kKerriganAutoFunding;

  KerriganNamesPayment get _payment => widget.payment;
  KerriganNamesFlow get _flow => _payment.flow;

  Amount _amount(KerriganWallet wallet) => Amount(
    rawValue: _payment.amount,
    fractionDigits: wallet.cryptoCurrency.fractionDigits,
  );

  String get _note => switch (_flow.op) {
    KerriganNamesOp.reg => l10n.kerriganNamesNoteRegister(_flow.name),
    KerriganNamesOp.buy => l10n.kerriganNamesNoteBuy(_flow.name),
    KerriganNamesOp.upd => l10n.kerriganNamesNoteDestination(_flow.name),
    KerriganNamesOp.chg => l10n.kerriganNamesNoteOwner(_flow.name),
    KerriganNamesOp.lst => l10n.kerriganNamesNoteList(_flow.name),
    KerriganNamesOp.ult => l10n.kerriganNamesNoteUnlist(_flow.name),
  };

  Future<void> _create() async {
    final wallet = _walletOf(ref, _flow.walletId);
    final txData = await showBuildingTransaction<TxData>(
      context: context,
      coin: wallet.cryptoCurrency,
      build: () => wallet.prepareNamesPayment(
        address: _payment.address,
        amount: _amount(wallet),
        memo: _payment.memo,
        note: _note,
        funding: _funding,
      ),
    );
    if (!mounted || txData == null) return;
    final txid = txData.txid;
    final navigator = Navigator.of(context);
    final tracked = KerriganNamesTracked(
      walletId: _flow.walletId,
      name: _flow.name,
      op: _flow.op.code,
      memo: _payment.memo,
      txId: null,
    );
    await navigator.push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => DesktopPageColumn(
          card: true,
          child: ConfirmTransactionView(
            txData: txData,
            walletId: _flow.walletId,
            onSuccess: () {},
            beforeBroadcast: txid == null
                ? null
                : () => wallet.rememberNamesSent((
                    txid: txid,
                    name: _flow.name,
                    op: _flow.op.code,
                    memo: _payment.memo,
                    sent: DateTime.now(),
                  )),
            afterFailedBroadcast: txid == null
                ? null
                : () => wallet.forgetNamesSent([txid]),
            onSuccessInsteadOfRouteOnSuccess: () {
              KerriganNamesInFlight.add(
                tracked,
                KerriganNamesRegistrar.forCoin(wallet.cryptoCurrency)!,
              );
              navigator.popUntil(ModalRoute.withName(_flow.returnTo));
              unawaited(
                navigator.pushNamed(
                  KerriganNamesStatusView.routeName,
                  arguments: tracked,
                ),
              );
            },
          ),
        ),
        settings: const RouteSettings(name: ConfirmTransactionView.routeName),
      ),
    );
  }

  Widget _row({
    required String title,
    required String value,
    required String what,
    bool mono = false,
    Widget? badge,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => kerriganNamesCopy(context, value, what),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: STextStyles.w500_12(context)
                              .copyWith(color: colors.textSubtitle1),
                        ),
                        if (badge != null) ...[const SizedBox(width: 8), badge],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: mono
                          ? STextStyles.w500_12(context).copyWith(
                              fontFamily: "monospace",
                              color: colors.textDark,
                            )
                          : STextStyles.w600_14(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.copy_rounded, size: 16, color: colors.textSubtitle1),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet =
        ref.watch(pWallets).getWallet(_flow.walletId) as KerriganWallet;
    final amount = _amount(wallet);
    return Background(
      child: AppScaffold(
        backgroundColor: colors.background,
        appBar: kerriganNamesFlowAppBar(context, _flow.title),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    const KerriganNamesSteps(step: KerriganNamesStep.pay),
                    const SizedBox(height: 20),
                    Text(
                      _flow.op == KerriganNamesOp.reg
                          ? l10n.kerriganNamesPayToRegister(
                              kerriganNamesUnbroken(_flow.name),
                            )
                          : l10n.kerriganNamesPayForChange,
                      style: STextStyles.pageTitleH2(context),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10n.kerriganNamesPaymentExplained,
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 16),
                    _row(
                      title: l10n.kerriganNamesToKerriganName,
                      value: _payment.address,
                      what: l10n.commonAddress,
                      mono: true,
                    ),
                    const SizedBox(height: 8),
                    _row(
                      title: l10n.commonAmount,
                      value: kerriganNamesAmount(
                        _payment.amount,
                        ref,
                        wallet,
                        exact: true,
                      ),
                      what: l10n.commonAmount,
                    ),
                    const SizedBox(height: 8),
                    _row(
                      title: l10n.kerriganNamesShieldedMemo,
                      value: _payment.memo,
                      what: l10n.commonMemo,
                      mono: true,
                      badge: KerriganNamesPill(
                        text: l10n.kerriganNamesAddedForYou,
                        color: kerriganNamesReadable(
                          colors.accentColorGreen,
                          colors,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    KerriganFundingCard(
                      walletId: _flow.walletId,
                      funding: _funding,
                      amount: amount,
                      onChanged: (f) => setState(() => _funding = f),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.kerriganNamesFeeOnTop,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  width: double.infinity,
                  label: l10n.kerriganNamesCreateTransaction,
                  onPressed: _create,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
