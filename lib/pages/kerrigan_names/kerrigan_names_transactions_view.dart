import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/kerrigan_name/kerrigan_name.dart';
import '../../services/kerrigan_name/kerrigan_names_protocol.dart';
import '../../services/kerrigan_name/kerrigan_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/middle_ellipsis_text.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_dialog.dart';
import 'kerrigan_names_common.dart';
import 'kerrigan_names_status_view.dart';

/// The user's payments to Kerrigan NameSpace (and where each stands) and their
/// withdrawals. A payment in progress opens its status screen.
class KerriganNamesTransactionsView extends ConsumerStatefulWidget {
  const KerriganNamesTransactionsView({super.key, required this.walletId});

  static const routeName = kKerriganNamesTransactionsRoute;

  final String walletId;

  @override
  ConsumerState<KerriganNamesTransactionsView> createState() =>
      _KerriganNamesTransactionsViewState();
}

class _KerriganNamesTransactionsViewState
    extends ConsumerState<KerriganNamesTransactionsView> {
  bool _refunds = false;
  int _page = 1;
  bool _loading = true;
  String? _error;
  int _request = 0;
  int _paymentConfirmations = kKerriganNamesPaymentConfirmations;
  int _refundConfirmations = kKerriganNamesRefundConfirmations;

  KerriganNamesPage<KerriganNamesIncoming>? _incoming;
  KerriganNamesPage<KerriganNamesRefund>? _refundList;

  /// Sent from this wallet and not listed by Kerrigan NameSpace yet.
  List<KerriganNamesSent> _sent = const [];

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  KerriganNamesRegistrar get _registrar =>
      KerriganNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;

  @override
  void initState() {
    super.initState();
    kerriganNamesChanges.addListener(_changed);
    _sent = _wallet.namesSent;
    unawaited(_load());
    unawaited(
      _registrar.paymentInfo().then((info) {
        if (!mounted) return;
        setState(() {
          _paymentConfirmations = info.paymentConfirmations;
          _refundConfirmations = info.refundConfirmations;
        });
      }, onError: (_) {}),
    );
  }

  @override
  void dispose() {
    kerriganNamesChanges.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_load());

  Future<void> _load() async {
    final request = ++_request;
    final refunds = _refunds;
    final page = _page;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final wallet = _wallet;
      final identity = await wallet.namesIdentity();
      final nonce = kerriganNamesNonce();
      final signature = await identity.sign(
        kerriganNamesHistoryMessage(
          marker: _registrar.service.marker,
          type: refunds ? "ref" : "in",
          pubkey: identity.publicKey,
          page: page,
          count: kKerriganNamesHistoryPageSize,
          nonce: nonce,
        ),
      );
      if (refunds) {
        final list = await _registrar.refunds(
          pubkey: identity.publicKey,
          page: page,
          nonce: nonce,
          signature: signature,
        );
        if (!mounted || request != _request) return;
        setState(() => _refundList = list);
      } else {
        final list = await _registrar.incoming(
          pubkey: identity.publicKey,
          page: page,
          nonce: nonce,
          signature: signature,
        );
        if (!mounted || request != _request) return;
        // Listed now: no need to keep them.
        final listed = {for (final t in list.items) t.txId};
        final seen = [
          for (final s in wallet.namesSent)
            if (listed.contains(s.txid)) s.txid,
        ];
        if (seen.isNotEmpty) await wallet.forgetNamesSent(seen);
        if (!mounted || request != _request) return;
        setState(() {
          _incoming = list;
          _sent = wallet.namesSent;
        });
      }
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(
        () => _error = l10n.kerriganNamesLoadTransactionsFailed(
          kerriganNamesError(e),
        ),
      );
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _switch(bool refunds) {
    if (refunds == _refunds) return;
    setState(() {
      _refunds = refunds;
      _page = 1;
    });
    unawaited(_load());
  }

  Future<void> _open(KerriganNamesTracked tracked) async {
    await Navigator.of(context)
        .pushNamed(KerriganNamesStatusView.routeName, arguments: tracked);
    if (mounted) unawaited(_load());
  }

  Future<void> _showMemo(String memo) => showDialog<void>(
    context: context,
    builder: (context) {
      final colors = Theme.of(context).extension<StackColors>()!;
      return StackDialog(
        title: l10n.kerriganNamesTransactionMemo,
        message: memo,
        leftButton: TextButton(
          style: colors.getSecondaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            l10n.commonClose,
            style: STextStyles.button(context)
                .copyWith(color: colors.accentColorDark),
          ),
        ),
        rightButton: TextButton(
          style: colors.getPrimaryEnabledButtonStyle(context),
          onPressed: () async {
            await kerriganNamesCopy(context, memo, l10n.commonMemo);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Text(l10n.commonCopy, style: STextStyles.button(context)),
        ),
      );
    },
  );

  Widget _tabs() {
    final colors = Theme.of(context).extension<StackColors>()!;
    Widget tab(String label, String icon, bool refunds) {
      final selected = _refunds == refunds;
      return Expanded(
        child: Material(
          color: selected ? colors.accentColorBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _switch(refunds),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  KerriganNamesIcon(
                    icon,
                    size: 16,
                    color: selected
                        ? colors.buttonTextPrimary
                        : colors.textSubtitle1,
                  ),
                  const SizedBox(width: 6),
                  // A label a little too long ("Geri qaytarmalar") shrinks
                  // a little rather than overflowing.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        style: STextStyles.w600_14(context).copyWith(
                          color: selected
                              ? colors.buttonTextPrimary
                              : colors.textSubtitle1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          tab(l10n.kerriganNamesIncoming, KerriganNamesIcons.incoming, false),
          const SizedBox(width: 4),
          tab(l10n.kerriganNamesRefunds, KerriganNamesIcons.refunds, true),
        ],
      ),
    );
  }

  Widget _txIdRow(String txId) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => kerriganNamesCopy(context, txId, l10n.commonTransactionId),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              kerriganNamesShortId(txId),
              style: STextStyles.w500_12(
                context,
              ).copyWith(fontFamily: "monospace", color: colors.textSubtitle1),
            ),
            const SizedBox(width: 4),
            Icon(Icons.copy_rounded, size: 12, color: colors.textSubtitle1),
          ],
        ),
      ),
    );
  }

  /// "2026-11-03 UTC".
  static String _day(DateTime d) =>
      "${d.year}-${d.month.toString().padLeft(2, "0")}-"
      "${d.day.toString().padLeft(2, "0")} UTC";

  Widget _card({
    required String name,
    required String op,
    required Widget status,
    String? confirmations,
    String? details,
    String? txId,
    String? memo,
    String? note,
    VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RoundedWhiteContainer(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: KerriganNamesNameText(
                        name,
                        style: STextStyles.w600_14(context),
                      ),
                    ),
                    KerriganNamesPill(text: op, color: colors.accentColorBlue),
                    if (onTap != null) ...[
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: colors.textSubtitle1,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    status,
                    if (confirmations != null) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          l10n.kerriganNamesConfirmations(confirmations),
                          style: secondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                if (details != null && details.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(details, style: secondary),
                ],
                if (note != null) ...[
                  const SizedBox(height: 6),
                  Text(note, style: secondary),
                ],
                if (txId != null || memo != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (txId != null && txId.isNotEmpty) _txIdRow(txId),
                      const Spacer(),
                      if (memo != null && memo.isNotEmpty)
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => _showMemo(memo),
                          child: Text(
                            l10n.kerriganNamesShowMemo,
                            style: STextStyles.w600_12(context)
                                .copyWith(color: colors.accentColorBlue),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _incomingList() {
    final wallet = _wallet;
    final list = _incoming;
    final items = list?.items ?? const <KerriganNamesIncoming>[];
    final listed = {for (final t in items) t.txId};
    final sent = _page == 1
        ? [
            for (final s in _sent)
              if (!listed.contains(s.txid)) s,
          ]
        : const <KerriganNamesSent>[];
    return [
      for (final s in sent)
        _card(
          name: s.name,
          op: s.op,
          status: const KerriganNamesStatusPill(status: null),
          note: l10n.kerriganNamesSentWaiting,
          txId: s.txid,
          memo: s.memo,
          onTap: () => _open(
            KerriganNamesTracked(
              walletId: widget.walletId,
              name: s.name,
              op: s.op,
              memo: s.memo,
              txId: s.txid,
            ),
          ),
        ),
      for (final t in items)
        _card(
          name: t.name,
          op: t.op,
          status: KerriganNamesStatusPill(status: t.status, raw: t.rawStatus),
          confirmations: switch (t.status) {
            KerriganNamesTxStatus.confirmingPayment =>
              "${t.confirmations}/$_paymentConfirmations",
            KerriganNamesTxStatus.pendingRefund =>
              "${t.confirmations}/$_refundConfirmations",
            _ => null,
          },
          details: [
            if (t.time != null) _day(t.time!),
            if (t.amount > BigInt.zero)
              kerriganNamesAmount(t.amount, ref, wallet),
            // What a listing asked for the name.
            if (t.price > BigInt.zero)
              l10n.kerriganNamesListedForShort(
                kerriganNamesAmount(t.price, ref, wallet),
              ),
          ].join("  ·  "),
          txId: t.txId,
          memo: t.memo,
          onTap:
              t.status == null ||
                  t.status!.isFinal ||
                  t.txId.isEmpty ||
                  !isValidKerriganName(t.name)
              ? null
              : () => _open(
                  KerriganNamesTracked(
                    walletId: widget.walletId,
                    name: t.name,
                    op: t.op,
                    memo: t.memo.isEmpty ? null : t.memo,
                    txId: t.txId,
                  ),
                ),
        ),
    ];
  }

  List<Widget> _refundsList() {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return [
      for (final r in _refundList?.items ?? const <KerriganNamesRefund>[])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: RoundedWhiteContainer(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        kerriganNamesAmount(r.amount, ref, wallet),
                        style: STextStyles.w600_16(context),
                      ),
                    ),
                    KerriganNamesPill(
                      text:
                          r.status?.label ??
                          l10n.kerriganNamesStatusCode("${r.rawStatus ?? "?"}"),
                      color: kerriganNamesReadable(switch (r.status) {
                        KerriganNamesRefundStatus.paid =>
                          colors.accentColorGreen,
                        KerriganNamesRefundStatus.error =>
                          colors.accentColorRed,
                        _ => colors.accentColorBlue,
                      }, colors),
                      icon: r.status == KerriganNamesRefundStatus.error
                          ? KerriganNamesIcons.warning
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (r.date != null) _day(r.date!),
                    if (r.fee.isNotEmpty) l10n.kerriganNamesFeePercent(r.fee),
                  ].join("  ·  "),
                  style: secondary,
                ),
                if (r.address.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => kerriganNamesCopy(
                      context,
                      r.address,
                      l10n.commonAddress,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Text(
                            l10n.kerriganNamesRefundSentTo,
                            style: secondary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: MiddleEllipsisText(
                              r.address,
                              style: STextStyles.w500_12(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (r.txId.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: _txIdRow(r.txId),
                  ),
                ],
              ],
            ),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final rows = _refunds ? _refundsList() : _incomingList();
    final count = _refunds ? _refundList?.count : _incoming?.count;
    final shown = _refunds ? _refundList : _incoming;
    return Background(
      child: AppScaffold(
        backgroundColor: colors.background,
        appBar: KerriganNamesAppBar(
          walletId: widget.walletId,
          title: l10n.kerriganNamesMyTransactions,
          section: KerriganNamesSection.transactions,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Row(
                  children: [
                    Expanded(child: _tabs()),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: l10n.commonRefresh,
                      onPressed: _loading ? null : _load,
                      icon: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.refresh_rounded,
                              color: colors.accentColorBlue,
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _refunds
                      ? l10n.kerriganNamesRefundsIntro
                      : l10n.kerriganNamesIncomingIntro,
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 12),
                if (_error != null) ...[
                  KerriganNamesListState(error: _error, onRetry: _load),
                  // What this wallet sent still shows.
                  if (!_refunds) ...rows,
                ] else if (shown == null && _loading)
                  const KerriganNamesListState(loading: true)
                else if (rows.isEmpty)
                  KerriganNamesListState(
                    empty: _refunds
                        ? l10n.kerriganNamesNoWithdrawals
                        : l10n.kerriganNamesNoPayments,
                  )
                else ...[
                  ...rows,
                  KerriganNamesPager(
                    page: _page,
                    count: count ?? 0,
                    pageSize: kKerriganNamesHistoryPageSize,
                    onPage: (p) {
                      setState(() => _page = p);
                      unawaited(_load());
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
