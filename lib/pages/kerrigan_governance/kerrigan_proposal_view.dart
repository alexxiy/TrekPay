import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/block_explorers.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/block_explorer_link.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../kerrigan_masternodes/kerrigan_masternodes_view.dart';
import 'kerrigan_governance_view.dart';
import 'kerrigan_governance_widgets.dart';

/// One proposal or growth fund release: what it asks for, how the
/// network votes, and this wallet's masternodes' votes. Pops `true` after
/// a vote.
class KerriganProposalView extends ConsumerStatefulWidget {
  const KerriganProposalView({
    super.key,
    required this.walletId,
    required this.proposal,
    required this.governance,
  });

  static const routeName = "/kerriganProposal";

  final String walletId;
  final KerriganProposal proposal;
  final KerriganGovernance governance;

  @override
  ConsumerState<KerriganProposalView> createState() =>
      _KerriganProposalViewState();
}

class _KerriganProposalViewState extends ConsumerState<KerriganProposalView> {
  late Future<Map<String, KerriganMasternodeVote>> _votes;
  late KerriganProposal _proposal = widget.proposal;
  late KerriganGovernance _governance = widget.governance;
  bool _voted = false;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  @override
  void initState() {
    super.initState();
    _votes = _wallet.masternodeVotes(widget.proposal);
  }

  Future<void> _vote(KerriganVote vote) async {
    Map<String, KerriganMasternodeVote> current;
    try {
      current = await _votes;
    } catch (_) {
      current = const {};
    }
    if (!mounted) return;
    final done = await showKerriganSheet<bool>(
      context,
      (_) => _VoteSheet(
        wallet: _wallet,
        proposal: _proposal,
        vote: vote,
        current: current,
      ),
    );
    if (done == true && mounted) {
      _voted = true;
      setState(() => _votes = _wallet.masternodeVotes(_proposal));
      await _reloadTally();
    }
  }

  /// The vote counts as the network has them now.
  Future<void> _reloadTally() async {
    try {
      final governance = await _wallet.loadGovernance();
      final proposal = governance.proposals
          .where((p) => p.hash == _proposal.hash)
          .firstOrNull;
      if (proposal == null || !mounted) return;
      setState(() {
        _governance = governance;
        _proposal = proposal;
      });
    } catch (_) {
      // The list refreshes when this page closes.
    }
  }

  String _date(int epoch) {
    final d = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    String two(int v) => v.toString().padLeft(2, "0");
    return "${d.year}-${two(d.month)}-${two(d.day)}";
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final p = _proposal;
    final g = _governance;
    final status = g.statusOf(p);
    final masternodes = wallet.masternodes;
    final canVote =
        !p.isOver && masternodes.any((m) => wallet.votingProblem(m) == null);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);

    Widget fact(String title, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: secondary),
          const SizedBox(height: 2),
          Text(value, style: STextStyles.w600_14(context)),
        ],
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_voted);
      },
      child: Background(
        child: Scaffold(
          backgroundColor: colors.background,
          appBar: PageAppBar(
            onBack: () => Navigator.of(context).pop(_voted),
            title: Text(p.type.label, style: STextStyles.navBarTitle(context)),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    p.name,
                                    style: STextStyles.pageTitleH2(context),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                KerriganProposalStatusPill(status: status),
                              ],
                            ),
                            if (p.url.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () =>
                                    openKerriganProposalUrl(context, p.url),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.open_in_new_rounded,
                                        size: 16,
                                        color: colors.accentColorBlue,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          p.url,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: STextStyles.w500_12(context)
                                              .copyWith(
                                                color: colors.accentColorBlue,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            if (!p.isValid) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.govInvalid(p.invalidReason ?? l10n.govUnknownReason),
                                style: STextStyles.w500_12(context)
                                    .copyWith(color: colors.textError),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                fact(
                                  p.type == KerriganProposalType.escrowRelease
                                      ? l10n.govRelease
                                      : l10n.commonAmount,
                                  fmt.format(p.paymentAmount),
                                ),
                                fact(
                                  l10n.govVotingPeriod,
                                  p.endEpoch == null
                                      ? l10n.govVotingOpen
                                      : "${_date(p.startEpoch ?? p.createdAt)} – ${_date(p.endEpoch!)}",
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(kerriganProposalTiming(p), style: secondary),
                            if (p.type ==
                                KerriganProposalType.escrowRelease) ...[
                              const SizedBox(height: 8),
                              Text(
                                l10n.govEscrowReleaseText,
                                style: secondary,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(l10n.govVotes, style: STextStyles.w600_14(context)),
                            const SizedBox(height: 10),
                            KerriganVotesBar(
                              yeas: p.yeas,
                              nays: p.nays,
                              netYes: p.absoluteYes,
                              threshold: g.threshold,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.govPassesWithKerrigan(g.threshold),
                              style: secondary,
                            ),
                            if (p.abstains > 0) ...[
                              const SizedBox(height: 4),
                              Text(l10n.govAbstained(p.abstains), style: secondary),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              l10n.govYourMasternodes,
                              style: STextStyles.w600_14(context),
                            ),
                            const SizedBox(height: 8),
                            if (masternodes.isEmpty)
                              Text(
                                l10n.govVotingNeedsMasternode,
                                style: secondary,
                              )
                            else
                              FutureBuilder<
                                Map<String, KerriganMasternodeVote>
                              >(
                                future: _votes,
                                builder: (context, snapshot) {
                                  if (snapshot.hasError) {
                                    return Text(
                                      l10n.govVotesLoadFailed,
                                      style: secondary,
                                    );
                                  }
                                  final votes = snapshot.data;
                                  final ordered = votes == null
                                      ? masternodes
                                      : kerriganByLatestVote(
                                          masternodes,
                                          votes,
                                        );
                                  final shown = kerriganVotesShownOf(
                                    ordered.length,
                                  );
                                  final more =
                                      votes != null && shown < ordered.length;
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (more) ...[
                                        KerriganVoteCounts(
                                          masternodes: masternodes,
                                          votes: votes,
                                        ),
                                        const SizedBox(height: 4),
                                      ],
                                      for (final mn in ordered.take(shown))
                                        KerriganMasternodeVoteRow(
                                          wallet: wallet,
                                          masternode: mn,
                                          vote: votes?[mn.id],
                                          loading: votes == null,
                                        ),
                                      if (more)
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              top: 6,
                                            ),
                                            child: KerriganShowAllChip(
                                              count: ordered.length,
                                              onTap: () =>
                                                  showKerriganMasternodeVotesSheet(
                                                    context,
                                                    wallet: wallet,
                                                    proposalName: p.name,
                                                    votes: votes,
                                                  ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RoundedWhiteContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            KerriganCopyRow(
                              title: l10n.govPaymentAddress,
                              value: p.paymentAddress,
                              openTooltip: l10n.govOpenInExplorer,
                              onOpen: () => openInBlockExplorer(
                                context,
                                ref,
                                getBlockExplorerAddressUrlFor(
                                  coin: wallet.cryptoCurrency,
                                  address: p.paymentAddress,
                                ),
                                address: true,
                              ),
                            ),
                            KerriganCopyRow(
                              title: l10n.govProposalHash,
                              value: p.hash,
                            ),
                            if (p.feeHash.isNotEmpty)
                              KerriganCopyRow(
                                title: l10n.govFeeTransaction,
                                value: p.feeHash,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (canVote)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: SecondaryButton(
                            label: l10n.govAbstain,
                            onPressed: () => _vote(KerriganVote.abstain),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SecondaryButton(
                            label: l10n.govVoteNo,
                            onPressed: () => _vote(KerriganVote.no),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: PrimaryButton(
                            label: l10n.govVoteYes,
                            onPressed: () => _vote(KerriganVote.yes),
                          ),
                        ),
                      ],
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

enum _Result { pending, running, done, failed }

/// Pick the masternodes that vote [vote], then sign and relay one vote
/// each. Pops `true` when at least one vote went through.
class _VoteSheet extends StatefulWidget {
  const _VoteSheet({
    required this.wallet,
    required this.proposal,
    required this.vote,
    required this.current,
  });

  final KerriganWallet wallet;
  final KerriganProposal proposal;
  final KerriganVote vote;
  final Map<String, KerriganMasternodeVote> current;

  @override
  State<_VoteSheet> createState() => _VoteSheetState();
}

class _VoteSheetState extends State<_VoteSheet> {
  late final List<KerriganMasternode> _masternodes = widget.wallet.masternodes;
  late final Set<String> _selected = {
    for (final m in _masternodes)
      if (_blockedReason(m) == null) m.id,
  };
  final _results = <String, (_Result, String?)>{};
  bool _running = false;
  String _query = "";

  bool get _finished =>
      _results.isNotEmpty &&
      _results.values.every(
        (r) => r.$1 == _Result.done || r.$1 == _Result.failed,
      );

  int _count(_Result result) =>
      _results.values.where((r) => r.$1 == result).length;

  /// Why [m] can't cast this vote now, or null.
  String? _blockedReason(KerriganMasternode m) {
    final problem = widget.wallet.votingProblem(m);
    if (problem != null) return problem;
    final v = widget.current[m.id];
    if (v == null) return null;
    if (v.vote == widget.vote) {
      return switch (widget.vote) {
        KerriganVote.yes => l10n.govAlreadyVotedYes,
        KerriganVote.no => l10n.govAlreadyVotedNo,
        KerriganVote.abstain => l10n.govAlreadyAbstained,
      };
    }
    if (!v.canChange) {
      final wait = v.changeableAt.difference(DateTime.now()).inSeconds;
      return l10n.govCanChangeIn(kerriganDuration(wait));
    }
    return null;
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      for (final id in _selected) {
        _results[id] = (_Result.pending, null);
      }
    });
    final picked = [
      for (final m in _masternodes)
        if (_selected.contains(m.id)) m,
    ];
    var next = 0;
    void markNextRunning() {
      if (next < picked.length) {
        _results[picked[next].id] = (_Result.running, null);
      }
    }

    setState(markNextRunning);
    await for (final r in widget.wallet.voteOnProposalWith(
      proposal: widget.proposal,
      masternodes: picked,
      vote: widget.vote,
    )) {
      // Leaving the stream stops the remaining votes.
      if (!mounted) return;
      setState(() {
        _results[r.mn.id] = r.error == null
            ? (_Result.done, null)
            : (
                _Result.failed,
                r.error.toString().replaceFirst("Exception: ", ""),
              );
        next++;
        markNextRunning();
      });
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final vote = widget.vote;
    final voteColor = kerriganVoteColor(vote, colors);
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final done = _count(_Result.done);
    final failed = _count(_Result.failed);
    final verb = switch (vote) {
      KerriganVote.yes => l10n.govVoteYes,
      KerriganVote.no => l10n.govVoteNo,
      KerriganVote.abstain => l10n.govAbstain,
    };
    final many = _masternodes.length > kKerriganManyMasternodes;
    final shown = [
      for (final m in _masternodes)
        if (kerriganMasternodeMatches(m, _query)) m,
    ];
    // What "Select all" picks: the listed ones that can cast this vote.
    final selectable = [
      for (final m in shown)
        if (_blockedReason(m) == null) m.id,
    ];
    final allSelected = selectable.every(_selected.contains);

    return KerriganSheetLayout(
      fullHeight: many,
      header: [
        Row(
          children: [
            Icon(kerriganVoteIcon(vote), color: voteColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(verb, style: STextStyles.pageTitleH2(context)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.proposal.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: secondary,
        ),
        if (many) ...[
          const SizedBox(height: 12),
          KerriganMasternodeSearchField(
            onChanged: (q) => setState(() => _query = q),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.govSelectedOf(_selected.length, _masternodes.length),
                  style: secondary,
                ),
              ),
              if (_results.isEmpty && selectable.isNotEmpty)
                CustomTextButton(
                  text: allSelected ? l10n.commonSelectNone : l10n.commonSelectAll,
                  onTap: () => setState(
                    () => allSelected
                        ? _selected.removeAll(selectable)
                        : _selected.addAll(selectable),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
      ],
      list: shown.isEmpty
          ? kerriganNoMasternodeMatches(context, _query)
          : ListView.builder(
              shrinkWrap: !many,
              itemCount: shown.length,
              itemBuilder: (context, i) => _row(context, shown[i], many),
            ),
      footer: [
        const SizedBox(height: 8),
        if (many && _results.isNotEmpty) ...[
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: l10n.govAcceptedOf(done, _results.length)),
                if (failed > 0)
                  TextSpan(
                    text: " · ${l10n.govFailedCount(failed)}",
                    style: TextStyle(color: colors.textError),
                  ),
              ],
            ),
            style: STextStyles.w600_12(context),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          l10n.govVoteExplainedKerrigan,
          style: secondary,
        ),
        const SizedBox(height: 16),
        if (_finished)
          PrimaryButton(
            label: l10n.commonDone,
            onPressed: () => Navigator.of(context).pop(done > 0),
          )
        else
          PrimaryButton(
            label: _running
                ? l10n.govVoting(done + failed, _results.length)
                : _selected.isEmpty
                ? l10n.govSelectMasternode
                : switch (vote) {
                    KerriganVote.yes => l10n.govVoteYesWith(_selected.length),
                    KerriganVote.no => l10n.govVoteNoWith(_selected.length),
                    KerriganVote.abstain => l10n.govAbstainWith(
                      _selected.length,
                    ),
                  },
            enabled: !_running && _selected.isNotEmpty,
            onPressed: _run,
          ),
      ],
    );
  }

  /// [showService]: the server's address too (a long list, searched by it).
  Widget _row(BuildContext context, KerriganMasternode m, bool showService) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final blocked = _blockedReason(m);
    final result = _results[m.id];
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);

    final Widget trailing;
    String? subtitle = blocked;
    Color? subtitleColor;
    switch (result?.$1) {
      case null:
        trailing = Checkbox(
          value: _selected.contains(m.id),
          activeColor: colors.checkboxBGChecked,
          checkColor: colors.checkboxIconChecked,
          onChanged: blocked != null || _running
              ? null
              : (on) => setState(
                  () =>
                      on == true ? _selected.add(m.id) : _selected.remove(m.id),
                ),
        );
      case _Result.pending:
        trailing = Icon(Icons.more_horiz_rounded, color: colors.textSubtitle2);
        subtitle = l10n.govFilterWaiting;
      case _Result.running:
        trailing = const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        subtitle = l10n.govSigningSending;
      case _Result.done:
        trailing = Icon(
          Icons.check_circle_rounded,
          color: kerriganVoteColor(KerriganVote.yes, colors),
        );
        subtitle = l10n.govVoteAccepted;
      case _Result.failed:
        trailing = Icon(Icons.error_rounded, color: colors.textError);
        subtitle = result!.$2;
        subtitleColor = colors.textError;
    }
    if (showService && m.service != null) {
      subtitle = subtitle == null ? m.service : "${m.service} · $subtitle";
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.label, style: STextStyles.w600_14(context)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: subtitleColor == null
                        ? secondary
                        : secondary.copyWith(color: subtitleColor),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 40, child: Center(child: trailing)),
        ],
      ),
    );
  }
}
