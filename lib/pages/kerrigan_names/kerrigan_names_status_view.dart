import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/wallets_provider.dart';
import '../../services/kerrigan_name/kerrigan_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import 'kerrigan_names_common.dart';
import 'kerrigan_names_in_flight.dart';

/// A paid command to follow: by its memo until the registrar finds its
/// transaction, then by [txId].
class KerriganNamesTracked {
  const KerriganNamesTracked({
    required this.walletId,
    required this.name,
    required this.op,
    required this.memo,
    required this.txId,
  });

  final String walletId;
  final String name;

  /// The operation's code ("REG").
  final String op;
  final String? memo;
  final String? txId;
}

/// Where a paid command is: found on the network, confirmed, proved, done
/// (or refunded). Asks the registrar every 30 seconds, as the web app
/// does, until nothing more will happen.
class KerriganNamesStatusView extends ConsumerStatefulWidget {
  const KerriganNamesStatusView({super.key, required this.tracked});

  static const routeName = "/kerriganNamesStatus";

  final KerriganNamesTracked tracked;

  @override
  ConsumerState<KerriganNamesStatusView> createState() =>
      _KerriganNamesStatusViewState();
}

class _KerriganNamesStatusViewState extends ConsumerState<KerriganNamesStatusView> {
  static const _interval = 30;

  late String? _txId = widget.tracked.txId;
  KerriganNamesProgress? _progress;
  int _paymentConfirmations = 40;
  int _refundConfirmations = 120;
  int _countdown = _interval;
  bool _polling = false;
  bool _offline = false;
  Timer? _timer;

  KerriganNamesTracked get _t => widget.tracked;

  KerriganNamesRegistrar get _registrar {
    final wallet = ref.read(pWallets).getWallet(_t.walletId) as KerriganWallet;
    return KerriganNamesRegistrar.forCoin(wallet.cryptoCurrency)!;
  }

  bool get _final => _progress?.status?.isFinal ?? false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTargets());
    unawaited(_poll());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_final) return;
      setState(() => _countdown--);
      if (_countdown <= 0) unawaited(_poll());
    });
  }

  Future<void> _loadTargets() async {
    try {
      final info = await _registrar.paymentInfo();
      if (mounted) {
        setState(() {
          _paymentConfirmations = info.paymentConfirmations;
          _refundConfirmations = info.refundConfirmations;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    kerriganNamesChanged();
    super.dispose();
  }

  /// A final status: no more checks, and the Names screens underneath
  /// reload.
  void _finished() {
    _timer?.cancel();
    KerriganNamesInFlight.finished(_t);
    kerriganNamesChanged();
  }

  Future<void> _poll() async {
    if (_polling || _final) return;
    _polling = true;
    setState(() => _countdown = _interval);
    try {
      final registrar = _registrar;
      final txId = _txId;
      final memo = _t.memo;
      if (txId == null && memo != null) {
        final found = await registrar.progressByMemo(_t.name, memo);
        if (!mounted) return;
        setState(() => _offline = false);
        if (found.txId == null) return;
        setState(() {
          _txId = found.txId;
          _progress = found;
        });
        if (_final) {
          _finished();
          return;
        }
        // Found: its status right away, not in 30 seconds.
        _polling = false;
        await _poll();
        return;
      }
      if (txId == null) return;
      final progress = await registrar.progressByTxId(_t.name, txId);
      if (!mounted) return;
      setState(() {
        _offline = false;
        // An empty answer (not seen yet) keeps what is known.
        if (progress.status != null) _progress = progress;
      });
      if (_final) _finished();
    } catch (_) {
      // Tried again at the next check, as the web app does.
      if (mounted) setState(() => _offline = true);
    } finally {
      _polling = false;
    }
  }

  String get _success => switch (_t.op) {
    "BUY" => "You've bought ${_t.name}!",
    "UPD" => "${_t.name} now points to its new address!",
    "CHG" => "${_t.name} now belongs to its new owner!",
    "LST" => "${_t.name} is listed on the marketplace!",
    "ULT" => "${_t.name} is off the marketplace!",
    _ => "You've registered ${_t.name}!",
  };

  /// "3 minutes 20 seconds", "3 minutes" or "20 seconds".
  static String _time(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return [
      if (m > 0) "$m ${m == 1 ? "minute" : "minutes"}",
      if (s > 0 || m == 0) "$s ${s == 1 ? "second" : "seconds"}",
    ].join(" ");
  }

  (String, String) get _text {
    final p = _progress;
    final status = p?.status;
    final confirmations = p?.confirmations ?? 0;
    final seconds = p?.seconds;
    return switch (status) {
      null when _txId == null => (
        "Looking for your payment…",
        "Waiting for your payment to reach the network.",
      ),
      null => (
        "Waiting for confirmation",
        "Your transaction is on the network.",
      ),
      KerriganNamesTxStatus.confirmingPayment => (
        "Confirmed $confirmations/$_paymentConfirmations",
        "Waiting for the payment's confirmations.",
      ),
      KerriganNamesTxStatus.pendingRefund => (
        "Confirmed $confirmations/$_refundConfirmations",
        "Waiting for the refund's confirmations.",
      ),
      KerriganNamesTxStatus.pendingProof || KerriganNamesTxStatus.queuedProof => (
        "Waiting for the ZK proof…",
        seconds != null && seconds > 0
            ? "It starts in about ${_time(seconds)}."
            : "It's about to start.",
      ),
      KerriganNamesTxStatus.processingProof => (
        "Creating the ZK proof…",
        "Checking the cryptographic proofs.",
      ),
      KerriganNamesTxStatus.submittingProof => (
        "Submitting the ZK proof…",
        "Almost done.",
      ),
      KerriganNamesTxStatus.done => ("Congrats!", _success),
      KerriganNamesTxStatus.refunded => (
        "Payment refunded",
        "Something in the payment was wrong, or someone else got the name "
            "first. The amount is back in your Kerrigan.name balance (My "
            "Balance).",
      ),
      KerriganNamesTxStatus.orphaned => (
        "Payment unsuccessful",
        "The transaction seems to be orphaned because of Kerrigan network "
            "issues.",
      ),
      KerriganNamesTxStatus.rejected => (
        "Transaction not accepted",
        "Kerrigan.name rejected the transaction because it doesn't follow the "
            "protocol rules.",
      ),
    };
  }

  Widget _icon(StackColors colors) {
    final status = _progress?.status;
    if (status == null || !status.isFinal) {
      return SizedBox(
        width: 72,
        height: 72,
        child: CircularProgressIndicator(
          strokeWidth: 6,
          color: colors.accentColorBlue,
          backgroundColor: colors.accentColorBlue.withValues(alpha: 0.15),
        ),
      );
    }
    final color = kerriganNamesReadable(
      status.failed ? colors.accentColorRed : colors.accentColorGreen,
      colors,
    );
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Center(
        child: KerriganNamesIcon(
          status.failed ? KerriganNamesIcons.cross : KerriganNamesIcons.check,
          size: 38,
          color: color,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final (heading, description) = _text;
    final status = _progress?.status;
    final txId = _txId;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: kerriganNamesFlowAppBar(context, _t.name),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    KerriganNamesSteps(
                      step: status == KerriganNamesTxStatus.done
                          ? KerriganNamesStep.done
                          : KerriganNamesStep.pay,
                    ),
                    const SizedBox(height: 36),
                    Center(
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: Center(child: _icon(colors)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      heading,
                      textAlign: TextAlign.center,
                      style: STextStyles.pageTitleH1(context),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: STextStyles.itemSubtitle(context),
                    ),
                    const SizedBox(height: 20),
                    if (!_final)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: colors.textFieldDefaultBG,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              KerriganNamesIcon(
                                KerriganNamesIcons.clock,
                                size: 18,
                                color: colors.accentColorBlue,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _polling
                                    ? "Checking…"
                                    : "Next check in ${_countdown}s",
                                style: STextStyles.w600_14(context),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_offline && !_final) ...[
                      const SizedBox(height: 8),
                      Text(
                        "Couldn't reach Kerrigan.name. Trying again at the next "
                        "check.",
                        textAlign: TextAlign.center,
                        style: STextStyles.w500_12(context)
                            .copyWith(color: colors.textSubtitle1),
                      ),
                    ],
                    if (!_final) ...[
                      const SizedBox(height: 24),
                      RoundedWhiteContainer(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: colors.accentColorBlue,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                "You can close this screen: nothing stops. "
                                "Follow the payment in My Transactions and "
                                "tap it there to come back here.",
                                style: STextStyles.w500_12(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (txId != null) ...[
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton.icon(
                          onPressed: () =>
                              kerriganNamesCopy(context, txId, "Transaction ID"),
                          icon: Icon(
                            Icons.copy_rounded,
                            size: 14,
                            color: colors.textSubtitle1,
                          ),
                          label: Text(
                            "Transaction ${kerriganNamesShortId(txId)}",
                            style: STextStyles.w500_12(context)
                                .copyWith(color: colors.textSubtitle1),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: "My Transactions",
                        onPressed: () => Navigator.of(context)
                            .pushReplacementNamed(
                              KerriganNamesSection.transactions.routeName,
                              arguments: _t.walletId,
                            ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PrimaryButton(
                        label: _final ? "Done" : "Close",
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
