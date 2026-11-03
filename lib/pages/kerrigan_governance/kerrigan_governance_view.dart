import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import '../../services/event_bus/global_event_bus.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/logger.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../kerrigan_masternodes/kerrigan_masternodes_view.dart';
import 'kerrigan_create_proposal_view.dart';
import 'kerrigan_governance_widgets.dart';
import 'kerrigan_proposal_view.dart';

enum _Tab {
  active,
  ended;

  String get label => switch (this) {
    active => l10n.govTabActive,
    ended => l10n.govTabEnded,
  };
}

enum _Filter {
  all,
  passing,
  notPassing,
  growthFund;

  String get label => switch (this) {
    all => l10n.govFilterAll,
    passing => l10n.govFilterPassing,
    notPassing => l10n.govFilterNotPassing,
    growthFund => l10n.govFilterGrowthFund,
  };

  /// "No passing proposals." and so on.
  String get none => switch (this) {
    all => l10n.govNoneNow,
    passing => l10n.govNonePassing,
    notPassing => l10n.govNoneNotPassing,
    growthFund => l10n.govNoneGrowthFund,
  };

  bool shows(KerriganProposal p, KerriganProposalStatus s) => switch (this) {
    _Filter.all => true,
    _Filter.passing => s == KerriganProposalStatus.passing,
    _Filter.notPassing => s == KerriganProposalStatus.notPassing,
    _Filter.growthFund => p.type == KerriganProposalType.escrowRelease,
  };
}

/// The network's governance: proposals and growth fund releases, voted on
/// by masternodes. Vote with the wallet's masternodes and create
/// proposals. From the wallet's menu, next to Masternodes.
class KerriganGovernanceView extends ConsumerStatefulWidget {
  const KerriganGovernanceView({super.key, required this.walletId});

  static const routeName = "/kerriganGovernance";

  final String walletId;

  @override
  ConsumerState<KerriganGovernanceView> createState() =>
      _KerriganGovernanceViewState();
}

class _KerriganGovernanceViewState
    extends ConsumerState<KerriganGovernanceView> {
  late Future<KerriganGovernance> _governance;

  /// This wallet's masternode votes, by proposal hash (filled in as they
  /// arrive).
  final _votes = <String, Map<String, KerriganMasternodeVote>>{};
  int _generation = 0;

  /// Our proposals waiting for their fee to confirm: the list follows
  /// new blocks (their confirmations, then the submission).
  bool _hasPending = false;

  _Tab _tab = _Tab.active;
  _Filter _filter = _Filter.all;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  /// The wallet submits a waiting proposal in its refresh after the
  /// block that confirmed the fee: show it once that refresh is done.
  late final StreamSubscription<WalletSyncStatusChangedEvent> _synced;

  @override
  void initState() {
    super.initState();
    _load();
    _synced = GlobalEventBus.instance.on<WalletSyncStatusChangedEvent>().listen(
      (e) {
        if (e.walletId == widget.walletId &&
            e.newStatus == WalletSyncStatus.synced &&
            _hasPending &&
            mounted) {
          setState(_load);
        }
      },
    );
  }

  @override
  void dispose() {
    _synced.cancel();
    super.dispose();
  }

  void _load() {
    final generation = ++_generation;
    final wallet = _wallet;
    _governance = () async {
      // Submit proposals whose fee confirmed meanwhile, then show them.
      if (wallet.pendingProposals.isNotEmpty) {
        try {
          await wallet.submitPendingProposals();
        } catch (e) {
          Logging.instance.w("Kerrigan: proposals: $e");
        }
      }
      return wallet.loadGovernance();
    }();
    _governance.then((g) {
      _hasPending = g.pending.isNotEmpty;
      _loadVotes(g, generation);
    }, onError: (_) {});
  }

  /// One proposal at a time (see [KerriganGovernanceWallet.masternodeVotes]).
  Future<void> _loadVotes(KerriganGovernance g, int generation) async {
    final wallet = _wallet;
    if (!wallet.masternodes.any((m) => m.isRegistered)) return;
    for (final p in g.proposals.where((p) => !p.isOver)) {
      if (!mounted || generation != _generation) return;
      try {
        final votes = await wallet.masternodeVotes(p);
        if (mounted && generation == _generation) {
          setState(() => _votes[p.hash] = votes);
        }
      } catch (e) {
        Logging.instance.w("Kerrigan: votes of ${p.name}: $e");
      }
    }
  }

  Future<void> _refresh() async {
    setState(_load);
    try {
      await _governance;
    } catch (_) {
      // Shown by the FutureBuilder.
    }
  }

  Future<void> _open(
    KerriganProposal proposal,
    KerriganGovernance governance,
  ) async {
    final changed = await Navigator.of(context).pushNamed(
      KerriganProposalView.routeName,
      arguments: (
        walletId: widget.walletId,
        proposal: proposal,
        governance: governance,
      ),
    );
    if (changed == true && mounted) setState(_load);
  }

  Future<void> _create() async {
    await Navigator.of(context).pushNamed(
      KerriganCreateProposalView.routeName,
      arguments: widget.walletId,
    );
    if (mounted) setState(_load);
  }

  Future<void> _removePending(KerriganPendingProposal p) async {
    await _wallet.removePendingProposal(p.hash);
    if (mounted) setState(_load);
  }

  @override
  Widget build(BuildContext context) {
    // A new block: follow our waiting proposals without a pull.
    ref.listen(pWalletChainHeight(widget.walletId), (previous, next) {
      if (_hasPending && previous != next) setState(_load);
    });
    final colors = Theme.of(context).extension<StackColors>()!;
    final canCreate = !_wallet.isViewOnly;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text(l10n.govTitle, style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: _Tabs(
                  selected: _tab,
                  onSelected: (t) => setState(() => _tab = t),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: _proposalList(),
                ),
              ),
              if (canCreate)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: PrimaryButton(
                    label: l10n.govCreateProposal,
                    onPressed: _create,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _proposalList() => FutureBuilder<KerriganGovernance>(
    future: _governance,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _LoadError(
          error: snapshot.error!,
          onRetry: () => setState(_load),
        );
      }
      final g = snapshot.data;
      if (g == null) {
        return const Center(child: CircularProgressIndicator());
      }
      final ended = _tab == _Tab.ended;
      final all = [
        for (final p in g.proposals)
          if (p.isOver == ended) p,
      ];
      final shown = [
        for (final p in all)
          if (ended || _filter.shows(p, g.statusOf(p))) p,
      ];
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (!ended) ...[
            _SummaryCard(wallet: _wallet, governance: g),
            const SizedBox(height: 14),
            _filterChips(g, all),
            for (final p in g.pending) ...[
              const SizedBox(height: 10),
              _PendingCard(
                wallet: _wallet,
                proposal: p,
                onRemove: () => _removePending(p),
              ),
            ],
          ],
          if (shown.isEmpty && (ended || g.pending.isEmpty))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text(
                ended
                    ? l10n.govNoneEnded
                    : all.isEmpty
                    ? l10n.govNoneNow
                    : _filter.none,
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle(context),
              ),
            ),
          for (final p in shown) ...[
            const SizedBox(height: 10),
            _ProposalCard(
              wallet: _wallet,
              proposal: p,
              governance: g,
              votes: _votes[p.hash],
              onTap: () => _open(p, g),
            ),
          ],
        ],
      );
    },
  );

  Widget _filterChips(KerriganGovernance g, List<KerriganProposal> all) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final f in _Filter.values)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                label: Text(
                  "${f.label} "
                  "${all.where((p) => f.shows(p, g.statusOf(p))).length}",
                ),
                selected: _filter == f,
                showCheckmark: false,
                selectedColor: colors.accentColorBlue.withValues(alpha: 0.18),
                backgroundColor: colors.popupBG,
                side: BorderSide(
                  color: _filter == f
                      ? colors.accentColorBlue
                      : colors.textFieldDefaultBG,
                ),
                labelStyle: STextStyles.w600_12(context).copyWith(
                  color: _filter == f
                      ? colors.accentColorBlue
                      : colors.textDark,
                ),
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.selected, required this.onSelected});

  final _Tab selected;
  final ValueChanged<_Tab> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final t in _Tab.values)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelected(t),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: t == selected ? colors.popupBG : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    t.label,
                    textAlign: TextAlign.center,
                    style: STextStyles.w600_14(context).copyWith(
                      color: t == selected
                          ? colors.textDark
                          : colors.textSubtitle1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What passing takes, and how many masternodes vote.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.wallet, required this.governance});

  final KerriganWallet wallet;
  final KerriganGovernance governance;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final g = governance;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colors.textSubtitle1),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: secondary)),
        ],
      ),
    );
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.govIntroKerrigan, style: secondary),
          line(Icons.how_to_vote_rounded, l10n.govToPassKerrigan(g.threshold)),
          line(
            Icons.dns_rounded,
            l10n.govMasternodesEnabled(g.enabledMasternodes),
          ),
        ],
      ),
    );
  }
}

/// "Voting ends in ~12 d", "Ended ~2 d ago", or the growth fund note.
String kerriganProposalTiming(KerriganProposal p) {
  final now = DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;
  final start = p.startEpoch, end = p.endEpoch;
  if (end == null) return l10n.govGrowthFundRelease;
  if (start != null && start > now) {
    return l10n.govStartsIn(kerriganDuration(start - now));
  }
  return end > now
      ? l10n.govVotingEndsIn(kerriganDuration(end - now))
      : l10n.govEndedAgo(kerriganDuration(now - end));
}

class _ProposalCard extends ConsumerWidget {
  const _ProposalCard({
    required this.wallet,
    required this.proposal,
    required this.governance,
    required this.votes,
    required this.onTap,
  });

  final KerriganWallet wallet;
  final KerriganProposal proposal;
  final KerriganGovernance governance;
  final Map<String, KerriganMasternodeVote>? votes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = proposal;
    final masternodes = wallet.masternodes;
    final myVotes = votes ?? const <String, KerriganMasternodeVote>{};
    // Latest first: a few of them, the rest behind "Show all".
    final voted = [
      for (final m in kerriganByLatestVote(masternodes, myVotes))
        if (myVotes[m.id] != null) m,
    ];
    final votesShown = kerriganVotesShownOf(voted.length);

    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(14),
      onPressed: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.w600_14(context),
                ),
              ),
              const SizedBox(width: 8),
              KerriganProposalStatusPill(status: governance.statusOf(p)),
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: fmt.format(p.paymentAmount),
                  style: STextStyles.w600_12(context),
                ),
                TextSpan(
                  text: " · ${kerriganProposalTiming(p)}",
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          KerriganVotesBar(
            yeas: p.yeas,
            nays: p.nays,
            netYes: p.absoluteYes,
            threshold: governance.threshold,
          ),
          if (voted.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in voted.take(votesShown))
                  KerriganVoteChip(label: m.label, vote: myVotes[m.id]!.vote),
                if (votesShown < voted.length)
                  KerriganShowAllChip(
                    count: masternodes.length,
                    onTap: () => showKerriganMasternodeVotesSheet(
                      context,
                      wallet: wallet,
                      proposalName: p.name,
                      votes: myVotes,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One of this wallet's proposals before the network knows it.
class _PendingCard extends ConsumerWidget {
  const _PendingCard({
    required this.wallet,
    required this.proposal,
    required this.onRemove,
  });

  final KerriganWallet wallet;
  final KerriganPendingProposal proposal;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final p = proposal;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final failed = p.error != null;

    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(14),
      borderColor: failed ? colors.textError : colors.accentColorBlue,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(p.name, style: STextStyles.w600_14(context)),
              ),
              KerriganPill(
                text: failed
                    ? l10n.govFailed
                    : switch (p.type) {
                        KerriganProposalType.proposal => l10n.govYourProposal,
                        KerriganProposalType.escrowRelease =>
                          l10n.govYourGrowthFundRelease,
                      },
                color: failed ? colors.textError : colors.accentColorBlue,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (failed) ...[
            Text(p.error!, style: secondary.copyWith(color: colors.textError)),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: CustomTextButton(text: l10n.commonRemove, onTap: onRemove),
            ),
          ] else
            FutureBuilder<int?>(
              future: wallet.feeConfirmationsOf(p),
              builder: (context, snapshot) {
                final confs = snapshot.data;
                const need = kKerriganProposalFeeConfirmations;
                final text = confs == null
                    ? l10n.govFeeSent
                    : confs < need
                    ? l10n.govFeeConfirming(confs, need)
                    : l10n.govSubmitting;
                return Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: confs == null ? null : confs / need,
                        color: colors.accentColorBlue,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(text, style: secondary)),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final text = error.toString().replaceFirst("Exception: ", "");
    final forbidden = text.contains("not allowed");
    // Scrollable, so pull to refresh works here too.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Icon(Icons.cloud_off_rounded, size: 48, color: colors.textSubtitle2),
        const SizedBox(height: 16),
        Text(
          l10n.govLoadFailed,
          textAlign: TextAlign.center,
          style: STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 8),
        Text(
          forbidden ? l10n.govNodeNoData : text,
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle(context),
        ),
        const SizedBox(height: 24),
        SecondaryButton(label: l10n.commonTryAgain, onPressed: onRetry),
      ],
    );
  }
}
