import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import 'kerrigan_create_masternode_view.dart';
import 'kerrigan_masternode_details_view.dart';

/// The wallet's masternodes (Dash-style deterministic masternodes), from
/// the wallet's menu.
class KerriganMasternodesView extends ConsumerStatefulWidget {
  const KerriganMasternodesView({super.key, required this.walletId});

  static const routeName = "/kerriganMasternodes";

  final String walletId;

  @override
  ConsumerState<KerriganMasternodesView> createState() =>
      _KerriganMasternodesViewState();
}

/// What a card shows besides the stored masternode.
typedef KerriganMasternodeCardData = ({
  KerriganMasternodeState state,
  Amount earned,
});

class _KerriganMasternodesViewState
    extends ConsumerState<KerriganMasternodesView> {
  /// Network data per masternode id, refetched on pull to refresh.
  Map<String, Future<KerriganMasternodeCardData>> _data = {};

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  @override
  void initState() {
    _reload();
    super.initState();
  }

  void _reload() {
    final wallet = _wallet;
    _data = {
      for (final mn in wallet.masternodes)
        mn.id: () async {
          final results = await Future.wait([
            wallet.masternodeState(mn),
            wallet.masternodeEarned(mn),
          ]);
          return (
            state: results[0] as KerriganMasternodeState,
            earned: results[1] as Amount,
          );
        }(),
    };
  }

  Future<void> _refresh() async {
    setState(_reload);
    await Future.wait(_data.values);
  }

  Future<void> _open(String route, Object arguments) async {
    await Navigator.of(context).pushNamed(route, arguments: arguments);
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final masternodes = _wallet.masternodes;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text("Masternodes", style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: masternodes.isEmpty
                      ? _Empty(wallet: _wallet)
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              KerriganMasternodesSummary(
                                wallet: _wallet,
                                masternodes: masternodes,
                                data: _data,
                              ),
                              for (final mn in masternodes) ...[
                                const SizedBox(height: 12),
                                KerriganMasternodeCard(
                                  wallet: _wallet,
                                  masternode: mn,
                                  data: _data[mn.id],
                                  onTap: () => _open(
                                    KerriganMasternodeDetailsView.routeName,
                                    (walletId: widget.walletId, id: mn.id),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: "Create masternode",
                  onPressed: () => _open(
                    KerriganCreateMasternodeView.routeName,
                    widget.walletId,
                  ),
                ),
                const SizedBox(height: 8),
                SecondaryButton(
                  label: "Add existing masternode",
                  onPressed: () =>
                      _open(KerriganCreateMasternodeView.routeName, (
                        walletId: widget.walletId,
                        existing: true,
                      )),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends ConsumerWidget {
  const _Empty({required this.wallet});

  final KerriganWallet wallet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    return ListView(
      children: [
        const SizedBox(height: 40),
        Center(child: _MasternodeIcon(color: colors.textSubtitle1, size: 56)),
        const SizedBox(height: 24),
        Text(
          "No masternodes yet",
          textAlign: TextAlign.center,
          style: STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 8),
        Text(
          "A masternode locks a collateral of "
          "${fmt.format(wallet.masternodeCollateral(KerriganMasternodeType.regular))} "
          "in this wallet and earns rewards while a server runs it. The "
          "collateral stays yours and is frozen so it can't be spent by "
          "accident. A BroodNode locks "
          "${fmt.format(wallet.masternodeCollateral(KerriganMasternodeType.broodNode))} "
          "and votes with four times the weight.",
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle(context),
        ),
      ],
    );
  }
}

/// Count, enabled ones and rewards earned by all masternodes.
class KerriganMasternodesSummary extends ConsumerWidget {
  const KerriganMasternodesSummary({
    super.key,
    required this.wallet,
    required this.masternodes,
    required this.data,
  });

  final KerriganWallet wallet;
  final List<KerriganMasternode> masternodes;
  final Map<String, Future<KerriganMasternodeCardData>> data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    return FutureBuilder<List<KerriganMasternodeCardData>>(
      future: Future.wait([for (final mn in masternodes) data[mn.id]!]),
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        final enabled = loaded
            ?.where((e) => e.state.status == KerriganMasternodeStatus.enabled)
            .length;
        // Masternodes sharing a payout address share its rewards.
        final earned = loaded == null
            ? null
            : {
                for (int i = 0; i < masternodes.length; i++)
                  masternodes[i].payoutAddress: loaded[i].earned,
              }.values.fold(
                Amount.zeroWith(
                  fractionDigits: wallet.cryptoCurrency.fractionDigits,
                ),
                (p, e) => p + e,
              );

        Widget stat(String label, String value) => Expanded(
          child: Column(
            children: [
              Text(
                value,
                textAlign: TextAlign.center,
                style: STextStyles.w600_16(context),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: STextStyles.w500_12(
                  context,
                ).copyWith(color: colors.textSubtitle1),
              ),
            ],
          ),
        );

        return RoundedWhiteContainer(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Row(
            children: [
              stat("Masternodes", "${masternodes.length}"),
              stat("Enabled", enabled == null ? "…" : "$enabled"),
              stat("Earned", earned == null ? "…" : fmt.format(earned)),
            ],
          ),
        );
      },
    );
  }
}

class KerriganMasternodeCard extends ConsumerWidget {
  const KerriganMasternodeCard({
    super.key,
    required this.wallet,
    required this.masternode,
    required this.data,
    required this.onTap,
  });

  final KerriganWallet wallet;
  final KerriganMasternode masternode;
  final Future<KerriganMasternodeCardData>? data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final height = ref.watch(pWalletChainHeight(wallet.walletId));
    final mn = masternode;

    return FutureBuilder<KerriganMasternodeCardData>(
      future: data,
      builder: (context, snapshot) {
        final d = snapshot.data;
        final state = d?.state;
        final status = state?.status ?? KerriganMasternodeStatus.checking;

        Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Text(
                label,
                style: STextStyles.w500_12(
                  context,
                ).copyWith(color: colors.textSubtitle1),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.w500_12(
                    context,
                  ).copyWith(color: colors.textDark),
                ),
              ),
            ],
          ),
        );

        final registered = state != null && state.registeredHeight > 0;
        return GestureDetector(
          onTap: onTap,
          child: RoundedWhiteContainer(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mn.label.isEmpty ? mn.type.label : mn.label,
                            style: STextStyles.w600_16(context),
                          ),
                          const SizedBox(height: 6),
                          KerriganMasternodeStatusPill(status: status),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _MasternodeIcon(
                      color: kerriganMasternodeStatusColor(status, colors),
                      size: 28,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Divider(height: 16, color: colors.backgroundAppBar),
                row("Server", state?.service ?? mn.service ?? "Not set"),
                row(
                  "Collateral",
                  "${fmt.format(wallet.masternodeCollateral(mn.type))} · "
                      "${mn.txid.substring(0, 8)}…:${mn.vout}",
                ),
                if (mn.type == KerriganMasternodeType.broodNode)
                  row("Type", "BroodNode"),
                if (registered)
                  row(
                    "Last paid",
                    state.lastPaidHeight > 0
                        ? "${kerriganBlocksAgo(height, state.lastPaidHeight, wallet.cryptoCurrency.targetBlockTimeSeconds)} "
                              "(block ${state.lastPaidHeight})"
                        : "Not yet",
                  ),
                if (d != null) row("Earned", fmt.format(d.earned)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The masternode (server) icon on a tinted round tile.
class _MasternodeIcon extends StatelessWidget {
  const _MasternodeIcon({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(size * 0.36),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      shape: BoxShape.circle,
    ),
    child: Icon(Icons.dns_rounded, size: size, color: color),
  );
}

/// "3 d 4 h", "2 h 15 min", "12 min", "40 s".
String kerriganDuration(int seconds) {
  if (seconds < 60) return "${seconds.clamp(0, 59)} s";
  final m = seconds ~/ 60, h = m ~/ 60, d = h ~/ 24;
  if (d > 0) return h % 24 > 0 ? "$d d ${h % 24} h" : "$d d";
  if (h > 0) return m % 60 > 0 ? "$h h ${m % 60} min" : "$h h";
  return "$m min";
}

/// "~2 h ago" for block [height] seen from [chainHeight].
String kerriganBlocksAgo(int chainHeight, int height, int blockSeconds) {
  final blocks = chainHeight - height;
  if (blocks <= 0) return "Just now";
  return "~${kerriganDuration(blocks * blockSeconds)} ago";
}

Color kerriganMasternodeStatusColor(
  KerriganMasternodeStatus status,
  StackColors colors,
) {
  final color = switch (status) {
    KerriganMasternodeStatus.enabled => colors.accentColorGreen,
    KerriganMasternodeStatus.pending => colors.accentColorYellow,
    KerriganMasternodeStatus.checking ||
    KerriganMasternodeStatus.unknown => colors.textSubtitle1,
    KerriganMasternodeStatus.unregistered ||
    KerriganMasternodeStatus.needsServer => colors.accentColorOrange,
    _ => colors.accentColorRed,
  };
  if (colors.brightness == Brightness.dark) return color;
  // Light themes: deepen light accents (yellow) so text stays readable.
  final hsl = HSLColor.fromColor(color);
  return hsl.lightness > 0.45 ? hsl.withLightness(0.42).toColor() : color;
}

/// Masternode status as a coloured pill.
class KerriganMasternodeStatusPill extends StatelessWidget {
  const KerriganMasternodeStatusPill({super.key, required this.status});

  final KerriganMasternodeStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = kerriganMasternodeStatusColor(status, colors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        status.label,
        style: STextStyles.w600_12(context).copyWith(color: color),
      ),
    );
  }
}

/// Masternode status from the network, as a [KerriganMasternodeStatusPill].
class KerriganMasternodeStatusTag extends StatelessWidget {
  const KerriganMasternodeStatusTag({
    super.key,
    required this.wallet,
    required this.masternode,
  });

  final KerriganWallet wallet;
  final KerriganMasternode masternode;

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<KerriganMasternodeState>(
        future: wallet.masternodeState(masternode),
        builder: (context, snapshot) => KerriganMasternodeStatusPill(
          status: snapshot.data?.status ?? KerriganMasternodeStatus.checking,
        ),
      );
}
