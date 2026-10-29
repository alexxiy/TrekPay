import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../services/kerrigan_name/kerrigan_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../widgets/desktop/secondary_button.dart';
import 'kerrigan_names_common.dart';
import 'kerrigan_names_status_view.dart';

/// The payments to Kerrigan NameSpace sent while the app runs that Kerrigan NameSpace hasn't
/// finished yet, one per wallet and name. The Names screens show those
/// names as in progress instead of offering to pay for them again, and
/// they are asked about every 30 seconds, status screen open or not, until
/// they're done.
abstract final class KerriganNamesInFlight {
  static final _entries =
      <
        String,
        ({KerriganNamesTracked tracked, KerriganNamesRegistrar registrar})
      >{};
  static Timer? _timer;

  static String _key(String walletId, String name) => "$walletId/$name";

  /// The payment in progress for [name], if any.
  static KerriganNamesTracked? of(String walletId, String name) =>
      _entries[_key(walletId, name)]?.tracked;

  static void add(
    KerriganNamesTracked tracked,
    KerriganNamesRegistrar registrar,
  ) {
    _entries[_key(tracked.walletId, tracked.name)] = (
      tracked: tracked,
      registrar: registrar,
    );
    _timer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_check()),
    );
    kerriganNamesChanged();
  }

  /// Kerrigan NameSpace is done with the payment [done] (an older payment for the
  /// same name leaves a newer one in progress).
  static void finished(KerriganNamesTracked done) {
    final key = _key(done.walletId, done.name);
    final t = _entries[key]?.tracked;
    if (t == null) return;
    final same =
        (done.memo != null && done.memo == t.memo) ||
        (done.txId != null && done.txId == t.txId);
    if (!same) return;
    _entries.remove(key);
    if (_entries.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
    kerriganNamesChanged();
  }

  static Future<void> _check() async {
    for (final e in [..._entries.values]) {
      var t = e.tracked;
      try {
        var txId = t.txId;
        final memo = t.memo;
        if (txId == null) {
          // The memo only finds the payment; its status goes by txid.
          if (memo == null) continue;
          txId = (await e.registrar.progressByMemo(t.name, memo)).txId;
          if (txId == null) continue;
          t = KerriganNamesTracked(
            walletId: t.walletId,
            name: t.name,
            op: t.op,
            memo: memo,
            txId: txId,
          );
          final key = _key(t.walletId, t.name);
          if (_entries[key]?.tracked.memo == memo) {
            _entries[key] = (tracked: t, registrar: e.registrar);
          }
        }
        final progress = await e.registrar.progressByTxId(t.name, txId);
        if (progress.status?.isFinal ?? false) finished(t);
      } catch (_) {
        // Asked again at the next check.
      }
    }
  }
}

/// What a name shows instead of its actions while a payment for it is in
/// progress: a way to follow it.
class KerriganNamesInFlightNote extends StatelessWidget {
  const KerriganNamesInFlightNote({super.key, required this.tracked});

  final KerriganNamesTracked tracked;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Row(
      children: [
        KerriganNamesIcon(
          KerriganNamesIcons.clock,
          size: 18,
          color: colors.accentColorBlue,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l10n.kerriganNamesInFlight,
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        ),
        const SizedBox(width: 8),
        IntrinsicWidth(
          child: SecondaryButton(
            label: l10n.kerriganNamesFollowIt,
            buttonHeight: Util.isDesktop ? ButtonHeight.s : null,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            onPressed: () => Navigator.of(
              context,
            ).pushNamed(KerriganNamesStatusView.routeName, arguments: tracked),
          ),
        ),
      ],
    );
  }
}
