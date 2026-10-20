import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/barcode_scanner_provider.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
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
    this.price,
    this.currentAddress,
    this.listedPrice,
  });

  final String walletId;
  final KerriganNamesOp op;
  final String name;

  /// The screen to come back to once paid (its route name).
  final String returnTo;

  /// What a registration or a purchase costs. Other commands cost an
  /// update, looked up when needed.
  final BigInt? price;

  /// Where the name points now (a change of destination).
  final String? currentAddress;

  /// The name's price on the marketplace now (a new price).
  final BigInt? listedPrice;

  String get title => switch (op) {
    KerriganNamesOp.reg => "Register $name",
    KerriganNamesOp.buy => "Buy $name",
    KerriganNamesOp.upd => "Change destination",
    KerriganNamesOp.chg => "Change owner",
    KerriganNamesOp.lst =>
      listedPrice == null ? "List on the marketplace" : "Change sell price",
    KerriganNamesOp.ult => "Unlist $name",
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
    message: "Signing",
    onException: (e) => error = e,
    whileFutureAlt: () async {
      final registrar = KerriganNamesRegistrar.forCoin(wallet.cryptoCurrency)!;
      final info = await registrar.paymentInfo();
      final amount = flow.price ?? await registrar.updatePriceFor(flow.name);
      final identity = await wallet.namesIdentity();
      final command = kerriganNamesCommand(
        marker: registrar.service.marker,
        op: flow.op,
        name: flow.name,
        nonce: kerriganNamesNonce(),
        pubkey: identity.publicKey,
        target: target,
        newOwner: newOwner,
        priceSats: priceSats,
      );
      if (!kerriganNamesCommandFits(command)) {
        throw const KerriganNamesException(
          "This doesn't fit in a payment memo. Choose a shorter name.",
        );
      }
      return KerriganNamesPayment(
        flow: flow,
        address: info.address,
        amount: amount,
        memo: "$command:${await identity.sign(command)}",
      );
    },
  );
  if (payment == null && context.mounted) {
    await showKerriganNamesError(context, error ?? "Signing failed");
  }
  return payment;
}

Future<void> _openPayment(BuildContext context, KerriganNamesPayment payment) =>
    Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) =>
            DesktopPageColumn(child: KerriganNamesPaymentView(payment: payment)),
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

class _KerriganNamesTargetViewState extends ConsumerState<KerriganNamesTargetView> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  /// The address picked from the wallet's own.
  String? _target;

  /// The name points to an address typed in (in [_text]) instead of one of
  /// the wallet's.
  bool _custom = false;
  String? _ownKey;
  BigInt? _cost;
  String? _costError;
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
    await _loadCost();
  }

  Future<void> _loadCost() async {
    final price = _flow.price;
    if (price != null) {
      setState(() => _cost = price);
      return;
    }
    setState(() => _costError = null);
    try {
      final registrar = KerriganNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;
      final cost = await registrar.updatePriceFor(_flow.name);
      if (mounted) setState(() => _cost = cost);
    } catch (e) {
      if (mounted) setState(() => _costError = kerriganNamesError(e));
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
        if (target == null) return "Choose an address";
        if (target.isEmpty) return "";
        if (target == _flow.currentAddress) {
          return "${_flow.name} already points to this address.";
        }
        if (!isValidKerriganNamesTarget(target)) {
          return target.startsWith("ps1")
              ? "That isn't a valid shield address. Check it for typos."
              : "A name can only point to a shield address. It starts with "
                    "\"ps1\".";
        }
        return null;
      case KerriganNamesOp.chg:
        final key = _newOwner;
        if (key.isEmpty) return "";
        if (key == _ownKey) return "That's your own key: the name is yours.";
        if (!isValidKerriganNamesPublicKey(key)) {
          return "That isn't a valid public key. It's 64 characters, 0-9 "
              "and a-f.";
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
          final places = decimals > 0
              ? "with up to $decimals decimals"
              : "without decimals";
          return "Enter a price above 0 and up to $max, $places.";
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
            padding: const EdgeInsets.only(left: 12, right: 4, top: 4),
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
    final cost = _cost;
    final error = _error;
    final listedPrice = _flow.listedPrice;
    final listed = listedPrice == null
        ? null
        : kerriganNamesAmount(listedPrice, ref, wallet, exact: true);
    final targetError = op.hasTarget ? error : null;

    final (String heading, String text) = switch (op) {
      KerriganNamesOp.reg || KerriganNamesOp.buy => (
        "Where should ${_flow.name} point?",
        "Choose one of your shield addresses, or enter another one. Anyone "
            "who pays ${_flow.name} pays this address, and you can change it "
            "later.",
      ),
      KerriganNamesOp.upd => (
        "Choose the new destination",
        "Payments to ${_flow.name} will go to this address. People keep "
            "paying the name and never need to know.",
      ),
      KerriganNamesOp.chg => (
        "Who will own ${_flow.name}?",
        "Paste the public key of the new owner. They find it in My Names, "
            "in Astronaut or on Kerrigan.name.",
      ),
      KerriganNamesOp.lst => (
        _flow.listedPrice == null
            ? "Set the price for ${_flow.name}"
            : "Set a new price for ${_flow.name}",
        "Anyone can buy the name for this price on the marketplace. The "
            "price then goes to your Kerrigan.name balance (My Balance), to "
            "withdraw to your wallet.",
      ),
      KerriganNamesOp.ult => ("", ""),
    };

    final costLine = switch (op) {
      _ when cost == null => null,
      KerriganNamesOp.reg => "Registration: ${kerriganNamesAmount(cost, ref, wallet)}",
      KerriganNamesOp.buy => "Price: ${kerriganNamesAmount(cost, ref, wallet)}",
      _ => "This change costs ${kerriganNamesAmount(cost, ref, wallet)}",
    };

    return Background(
      child: Scaffold(
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
                          onText: "My addresses",
                          offColor: Util.isDesktop
                              ? colors.rateTypeToggleDesktopColorOff
                              : colors.textFieldDefaultBG,
                          offText: "Another address",
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
                        hint: "Shield address",
                        input: _Input.address,
                        suffix: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: "Paste",
                              onPressed: _paste,
                              icon: const ClipboardIcon(),
                            ),
                            IconButton(
                              tooltip: "Scan QR code",
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
                        placeholder: "Choose an address",
                        tags: {
                          if (_flow.currentAddress != null)
                            _flow.currentAddress!: "current destination",
                        },
                        onChanged: (a) => setState(() {
                          _target = a;
                          _touched = true;
                        }),
                      ),
                      if (_touched && targetError != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 4),
                          child: Text(
                            targetError,
                            style: STextStyles.label(context)
                                .copyWith(color: colors.textError),
                          ),
                        ),
                    ],
                    if (op == KerriganNamesOp.chg) ...[
                      _field(
                        hint: "New owner's public key",
                        suffix: IconButton(
                          tooltip: "Paste",
                          onPressed: _paste,
                          icon: const ClipboardIcon(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        borderColor: colors.accentColorOrange,
                        child: Text(
                          "The new owner gets ${_flow.name} and full control "
                          "of it. Only they can give it back.",
                          style: STextStyles.w500_12(context),
                        ),
                      ),
                    ],
                    if (op == KerriganNamesOp.lst) ...[
                      _field(
                        hint: "Price",
                        input: _Input.price,
                        suffix: Padding(
                          padding: const EdgeInsets.only(right: 14, top: 14),
                          child: Text(
                            _unit.unitForCoin(wallet.cryptoCurrency),
                            style: STextStyles.w600_14(context)
                                .copyWith(color: colors.textSubtitle1),
                          ),
                        ),
                      ),
                      if (listed != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 4),
                          child: Text(
                            "Listed for $listed now",
                            style: STextStyles.label(context)
                                .copyWith(color: colors.textSubtitle1),
                          ),
                        ),
                    ],
                    const SizedBox(height: 16),
                    if (costLine != null)
                      Text(
                        "$costLine, plus the network fee.",
                        style: STextStyles.w500_12(context)
                            .copyWith(color: colors.textSubtitle1),
                      )
                    else if (_costError != null)
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _costError!,
                              style: STextStyles.w500_12(context)
                                  .copyWith(color: colors.textError),
                            ),
                          ),
                          TextButton(
                            onPressed: _loadCost,
                            child: const Text("Try again"),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  label: "Next",
                  enabled: error == null && cost != null,
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

class _KerriganNamesPaymentViewState extends ConsumerState<KerriganNamesPaymentView> {
  KerriganFunding _funding = kKerriganAutoFunding;

  KerriganNamesPayment get _payment => widget.payment;
  KerriganNamesFlow get _flow => _payment.flow;

  Amount _amount(KerriganWallet wallet) => Amount(
    rawValue: _payment.amount,
    fractionDigits: wallet.cryptoCurrency.fractionDigits,
  );

  String get _note => switch (_flow.op) {
    KerriganNamesOp.reg => "Kerrigan.name: register ${_flow.name}",
    KerriganNamesOp.buy => "Kerrigan.name: buy ${_flow.name}",
    KerriganNamesOp.upd => "Kerrigan.name: new destination for ${_flow.name}",
    KerriganNamesOp.chg => "Kerrigan.name: new owner for ${_flow.name}",
    KerriganNamesOp.lst => "Kerrigan.name: list ${_flow.name}",
    KerriganNamesOp.ult => "Kerrigan.name: unlist ${_flow.name}",
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
    final wallet = ref.watch(pWallets).getWallet(_flow.walletId) as KerriganWallet;
    final amount = _amount(wallet);
    return Background(
      child: Scaffold(
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
                          ? "Pay to register ${_flow.name}"
                          : "Pay to process the change",
                      style: STextStyles.pageTitleH2(context),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "Your wallet makes this payment to Kerrigan.name with the "
                      "memo inside. The memo is the command, and Kerrigan.name "
                      "acts on it once the payment is confirmed. Kerrigan.name "
                      "publishes its viewing key, so anyone can read the "
                      "memo, but there's nothing secret in it.",
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 16),
                    _row(
                      title: "To Kerrigan.name",
                      value: _payment.address,
                      what: "Address",
                      mono: true,
                    ),
                    const SizedBox(height: 8),
                    _row(
                      title: "Amount",
                      value: kerriganNamesAmount(
                        _payment.amount,
                        ref,
                        wallet,
                        exact: true,
                      ),
                      what: "Amount",
                    ),
                    const SizedBox(height: 8),
                    _row(
                      title: "Shielded memo",
                      value: _payment.memo,
                      what: "Memo",
                      mono: true,
                      badge: KerriganNamesPill(
                        text: "Added for you",
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
                      "The network fee comes on top: Kerrigan.name needs the "
                      "exact amount, and refunds a payment that differs.",
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: PrimaryButton(
                  label: "Create transaction",
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
