import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/kerrigan_name/kerrigan_name.dart';
import '../../services/kerrigan_name/kerrigan_names_protocol.dart';
import '../../services/kerrigan_name/kerrigan_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_text_field.dart';
import 'kerrigan_names_common.dart';
import 'kerrigan_names_flow.dart';
import 'kerrigan_names_in_flight.dart';

/// Kerrigan Name (Kerrigan NameSpace): look a name up and register it, or buy it when
/// it's for sale. The menu leads to the user's names, balance and
/// transactions, and to the marketplace.
class KerriganNamesView extends ConsumerStatefulWidget {
  const KerriganNamesView({super.key, required this.walletId});

  static const routeName = "/kerriganNames";

  final String walletId;

  @override
  ConsumerState<KerriganNamesView> createState() => _KerriganNamesViewState();
}

class _KerriganNamesViewState extends ConsumerState<KerriganNamesView> {
  final _label = TextEditingController();
  final _focus = FocusNode();
  String _zone = ".${kKerriganNameZones.first}";

  bool _checking = false;
  KerriganNamesAvailability? _result;
  String? _error;
  String? _ownKey;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  KerriganNamesRegistrar get _registrar =>
      KerriganNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;

  String get _name => "${_label.text}$_zone";

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    kerriganNamesChanges.addListener(_changed);
    unawaited(_loadKey());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showKerriganNamesInfoOnce(context));
    });
  }

  Future<void> _loadKey() async {
    try {
      final key = await kerriganNamesPublicKey(_wallet);
      if (mounted) setState(() => _ownKey = key);
    } catch (_) {}
  }

  @override
  void dispose() {
    kerriganNamesChanges.removeListener(_changed);
    _label.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// A payment went through: what the check said may have changed.
  void _changed() {
    if (_result != null) unawaited(_check());
  }

  void _edited() => setState(() {
    _result = null;
    _error = null;
  });

  Future<void> _check() async {
    final label = _label.text;
    if (label.isEmpty || _checking) return;
    FocusScope.of(context).unfocus();
    if (!isValidKerriganNamesLabel(label) ||
        _name.length > kKerriganNameMaxLength) {
      setState(() {
        _result = null;
        _error = l10n.kerriganNamesInvalidName(kKerriganNameMaxLength);
      });
      return;
    }
    setState(() {
      _checking = true;
      _result = null;
      _error = null;
    });
    try {
      final result = await _registrar.check(_name);
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is KerriganNamesException && e.fromServer
              ? e.message
              : l10n.kerriganNamesUnreachable,
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _register(KerriganNamesAvailable a) => startKerriganNamesFlow(
    context,
    ref,
    KerriganNamesFlow(
      walletId: widget.walletId,
      op: KerriganNamesOp.reg,
      name: a.name,
      price: a.price,
      returnTo: KerriganNamesView.routeName,
    ),
  );

  Future<void> _buy(KerriganNamesListed l) async {
    final ok = await kerriganNamesConfirm(
      context,
      title: l10n.kerriganNamesBuyName,
      message: l10n.kerriganNamesBuyConfirm(
        kerriganNamesUnbroken(l.name),
        kerriganNamesAmount(l.price, ref, _wallet),
      ),
      action: l10n.kerriganNamesBuy,
    );
    if (!ok || !mounted) return;
    await startKerriganNamesFlow(
      context,
      ref,
      KerriganNamesFlow(
        walletId: widget.walletId,
        op: KerriganNamesOp.buy,
        name: l.name,
        price: l.price,
        returnTo: KerriganNamesView.routeName,
      ),
    );
  }

  Future<void> _unlist(KerriganNamesListed l) async {
    final ok = await kerriganNamesConfirm(
      context,
      title: l10n.kerriganNamesUnlistTitle,
      message: l10n.kerriganNamesUnlistConfirm(kerriganNamesUnbroken(l.name)),
      action: l10n.kerriganNamesUnlist,
    );
    if (!ok || !mounted) return;
    await startKerriganNamesFlow(
      context,
      ref,
      KerriganNamesFlow(
        walletId: widget.walletId,
        op: KerriganNamesOp.ult,
        name: l.name,
        returnTo: KerriganNamesView.routeName,
      ),
    );
  }

  Future<void> _pickZone() async {
    final colors = Theme.of(context).extension<StackColors>()!;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: colors.popupBG,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.kerriganNamesZone,
                style: STextStyles.pageTitleH2(context),
              ),
              const SizedBox(height: 8),
              for (final z in kKerriganNameZones)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: KerriganNamesNameText(
                    "${_label.text.isEmpty ? l10n.kerriganNamesZoneSample : _label.text}.$z",
                  ),
                  trailing: ".$z" == _zone
                      ? Icon(Icons.check_rounded, color: colors.accentColorBlue)
                      : null,
                  onTap: () => Navigator.of(context).pop(".$z"),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != _zone) {
      setState(() => _zone = picked);
      _edited();
    }
  }

  Widget _resultBox() {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: colors.textError,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                error,
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textError),
              ),
            ),
          ],
        ),
      );
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    final green = kerriganNamesReadable(colors.accentColorGreen, colors);
    final purple = colors.accentColorBlue;
    final inFlight = KerriganNamesInFlight.of(widget.walletId, result.name);
    Widget box({
      required Color color,
      required String text,
      required String action,
      required VoidCallback onTap,
    }) => Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KerriganNamesNameText(result.name),
          const SizedBox(height: 2),
          Text(
            text,
            style: STextStyles.w600_14(context).copyWith(color: color),
          ),
          const SizedBox(height: 10),
          if (inFlight != null)
            KerriganNamesInFlightNote(tracked: inFlight)
          else
            PrimaryButton(
              label: action,
              // On phones as high as Check above it.
              buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
              onPressed: onTap,
            ),
        ],
      ),
    );
    return switch (result) {
      KerriganNamesAvailable() => box(
        color: green,
        text: l10n.kerriganNamesAvailableFor(
          kerriganNamesAmount(result.price, ref, wallet),
        ),
        action: l10n.kerriganNamesGetItNow,
        onTap: () => _register(result),
      ),
      KerriganNamesListed() => box(
        color: purple,
        text: l10n.kerriganNamesListedFor(
          kerriganNamesAmount(result.price, ref, wallet),
        ),
        action: result.owner != null && result.owner == _ownKey
            ? l10n.kerriganNamesUnlistItNow
            : l10n.kerriganNamesBuyItNow,
        onTap: () => result.owner != null && result.owner == _ownKey
            ? _unlist(result)
            : _buy(result),
      ),
      KerriganNamesTaken() => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(
          children: [
            Icon(Icons.block_rounded, size: 18, color: colors.textError),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.kerriganNamesTaken(kerriganNamesUnbroken(result.name)),
                style: STextStyles.w600_14(context)
                    .copyWith(color: colors.textError),
              ),
            ),
          ],
        ),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: KerriganNamesAppBar(walletId: widget.walletId),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: colors.accentColorBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: colors.accentColorBlue.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Center(
                    child: KerriganNamesIcon(
                      KerriganNamesIcons.code,
                      size: 32,
                      strokeWidth: 1.5,
                      color: colors.accentColorBlue,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text.rich(
                TextSpan(
                  children: [
                    ...l10nSpans(
                      l10n.kerriganNamesGetYourName,
                      style: const TextStyle(),
                      bold: TextStyle(color: colors.accentColorBlue),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                style: STextStyles.pageTitleH1(context),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.kerriganNamesIntro,
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 10),
              Center(
                child: CustomTextButton(
                  text: l10n.kerriganNamesHowDoesItWork,
                  onTap: () => showKerriganNamesInfo(context),
                ),
              ),
              const SizedBox(height: 20),
              RoundedWhiteContainer(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.kerriganNamesRegisterYourName,
                      style: STextStyles.w600_16(context),
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: TextField(
                        controller: _label,
                        focusNode: _focus,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _check(),
                        onChanged: (_) => _edited(),
                        inputFormatters: [
                          TextInputFormatter.withFunction((old, value) {
                            final text = sanitizeKerriganNamesLabel(value.text);
                            return text == value.text
                                ? value
                                : TextEditingValue(
                                    text: text,
                                    selection: TextSelection.collapsed(
                                      offset: text.length,
                                    ),
                                  );
                          }),
                          LengthLimitingTextInputFormatter(
                            kKerriganNameMaxLength - 1,
                          ),
                        ],
                        style: STextStyles.field(context),
                        decoration:
                            standardInputDecoration(
                              l10n.kerriganNamesEnterName,
                              _focus,
                              context,
                            ).copyWith(
                              suffixIcon: Padding(
                                padding: const EdgeInsets.all(6),
                                child: Material(
                                  color: colors.background,
                                  borderRadius: BorderRadius.circular(8),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: _pickZone,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _zone,
                                            style: STextStyles.w600_14(context)
                                                .copyWith(
                                                  color: colors.accentColorBlue,
                                                ),
                                          ),
                                          Icon(
                                            Icons.expand_more_rounded,
                                            size: 18,
                                            color: colors.accentColorBlue,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _checking
                        ? SecondaryButton(
                            label: l10n.kerriganNamesChecking,
                            enabled: false,
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.l
                                : null,
                          )
                        : PrimaryButton(
                            label: l10n.kerriganNamesCheck,
                            enabled: _label.text.isNotEmpty,
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.l
                                : null,
                            onPressed: _check,
                          ),
                    _resultBox(),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const KerriganNamesSteps(step: KerriganNamesStep.check),
            ],
          ),
        ),
      ),
    );
  }
}
