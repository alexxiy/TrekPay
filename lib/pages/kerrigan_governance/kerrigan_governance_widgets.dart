import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/constants.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/icon_widgets/x_icon.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/stack_text_field.dart';
import '../../widgets/textfield_icon_button.dart';
import '../kerrigan_masternodes/kerrigan_masternodes_view.dart';
import '../../widgets/adaptive_page.dart';

/// Readable on light themes too (deepens light accents such as yellow).
Color _readable(Color color, StackColors colors) {
  if (colors.brightness == Brightness.dark) return color;
  final hsl = HSLColor.fromColor(color);
  return hsl.lightness > 0.45 ? hsl.withLightness(0.42).toColor() : color;
}

Color kerriganProposalStatusColor(
  KerriganProposalStatus status,
  StackColors colors,
) => _readable(switch (status) {
  KerriganProposalStatus.passing => colors.accentColorGreen,
  KerriganProposalStatus.notPassing => colors.accentColorRed,
  KerriganProposalStatus.ended => colors.textSubtitle1,
  KerriganProposalStatus.invalid => colors.textSubtitle1,
}, colors);

Color kerriganVoteColor(KerriganVote vote, StackColors colors) =>
    _readable(switch (vote) {
      KerriganVote.yes => colors.accentColorGreen,
      KerriganVote.no => colors.accentColorRed,
      KerriganVote.abstain => colors.textSubtitle1,
    }, colors);

IconData kerriganVoteIcon(KerriganVote vote) => switch (vote) {
  KerriganVote.yes => Icons.thumb_up_alt_rounded,
  KerriganVote.no => Icons.thumb_down_alt_rounded,
  KerriganVote.abstain => Icons.remove_circle_outline_rounded,
};

/// A small tinted pill.
class KerriganPill extends StatelessWidget {
  const KerriganPill({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(100),
    ),
    child: Text(
      text,
      style: STextStyles.w600_12(context).copyWith(color: color),
    ),
  );
}

class KerriganProposalStatusPill extends StatelessWidget {
  const KerriganProposalStatusPill({super.key, required this.status});

  final KerriganProposalStatus status;

  @override
  Widget build(BuildContext context) => KerriganPill(
    text: status.label,
    color: kerriganProposalStatusColor(
      status,
      Theme.of(context).extension<StackColors>()!,
    ),
  );
}

/// Yes against No as one bar; under it the counts and the net Yes
/// votes against what passing takes ([threshold]).
class KerriganVotesBar extends StatelessWidget {
  const KerriganVotesBar({
    super.key,
    required this.yeas,
    required this.nays,
    this.netYes,
    this.threshold,
  });

  final int yeas;
  final int nays;

  /// Weighted net Yes (a BroodNode counts four times).
  final int? netYes;
  final int? threshold;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final yes = kerriganVoteColor(KerriganVote.yes, colors);
    final no = kerriganVoteColor(KerriganVote.no, colors);
    final total = yeas + nays;
    final label = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final net = netYes;
    final need = threshold;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 6,
            child: total == 0
                ? ColoredBox(color: colors.textFieldDefaultBG)
                : Row(
                    // Childless boxes take the row's height only stretched.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (yeas > 0)
                        Expanded(
                          flex: yeas,
                          child: ColoredBox(color: yes),
                        ),
                      if (yeas > 0 && nays > 0) const SizedBox(width: 2),
                      if (nays > 0)
                        Expanded(
                          flex: nays,
                          child: ColoredBox(color: no),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              l10n.govYesCount(yeas),
              style: STextStyles.w600_12(context).copyWith(color: yes),
            ),
            Text("  ·  ", style: label),
            Text(
              l10n.govNoCount(nays),
              style: STextStyles.w600_12(context).copyWith(color: no),
            ),
            const Spacer(),
            if (net != null && need != null)
              Text(
                l10n.govNetOfNeed(net, need),
                style: STextStyles.w600_12(context)
                    .copyWith(color: net >= need ? yes : colors.textSubtitle1),
              ),
          ],
        ),
      ],
    );
  }
}

/// "MN1 · Yes": how one of the wallet's masternodes voted.
class KerriganVoteChip extends StatelessWidget {
  const KerriganVoteChip({super.key, required this.label, required this.vote});

  final String label;
  final KerriganVote vote;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = kerriganVoteColor(vote, colors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kerriganVoteIcon(vote), size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            "$label · ${vote.label}",
            style: STextStyles.w600_12(context).copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Votes of the wallet's masternodes listed on a proposal before "Show
/// all".
const kKerriganVotesShown = 2;

/// More masternodes than this: their sheets take the whole screen and
/// can be searched.
const kKerriganManyMasternodes = 6;

/// How many of [count] votes a proposal lists: all of them, or
/// [kKerriganVotesShown] and "Show all" (which never hides just one).
int kerriganVotesShownOf(int count) =>
    count <= kKerriganVotesShown + 1 ? count : kKerriganVotesShown;

/// Whether masternode [m] matches the search [query]: by its alias or
/// its server's address.
bool kerriganMasternodeMatches(KerriganMasternode m, String query) {
  final q = query.trim().toLowerCase();
  return q.isEmpty ||
      m.label.toLowerCase().contains(q) ||
      (m.service?.toLowerCase().contains(q) ?? false);
}

/// [masternodes] as their [votes] are listed: the latest vote first, then
/// those that haven't voted, in the wallet's order.
List<KerriganMasternode> kerriganByLatestVote(
  List<KerriganMasternode> masternodes,
  Map<String, KerriganMasternodeVote> votes,
) {
  final order = {for (final (i, m) in masternodes.indexed) m.id: i};
  final voted =
      [
        for (final m in masternodes)
          if (votes[m.id] != null) m,
      ]..sort((a, b) {
        final c = votes[b.id]!.time.compareTo(votes[a.id]!.time);
        return c != 0 ? c : order[a.id]!.compareTo(order[b.id]!);
      });
  return [
    ...voted,
    for (final m in masternodes)
      if (votes[m.id] == null) m,
  ];
}

/// "Show all 1000", after the votes a proposal lists: opens all of the
/// wallet's masternodes and their votes.
class KerriganShowAllChip extends StatelessWidget {
  const KerriganShowAllChip({
    super.key,
    required this.count,
    required this.onTap,
  });

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).extension<StackColors>()!.accentColorBlue;
    return Material(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(100),
      child: InkWell(
        borderRadius: BorderRadius.circular(100),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.unfold_more_rounded, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                l10n.govShowAll(count),
                style: STextStyles.w600_12(context).copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "3 Yes · 1 No · 1 Abstain · 2 not voted": the wallet's masternodes on
/// a proposal (Abstain only when one did).
class KerriganVoteCounts extends StatelessWidget {
  const KerriganVoteCounts({
    super.key,
    required this.masternodes,
    required this.votes,
  });

  final List<KerriganMasternode> masternodes;
  final Map<String, KerriganMasternodeVote> votes;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final counts = {for (final v in KerriganVote.values) v: 0};
    for (final m in masternodes) {
      final v = votes[m.id]?.vote;
      if (v != null) counts[v] = counts[v]! + 1;
    }
    final voted = counts.values.fold(0, (a, b) => a + b);
    final label = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    TextSpan count(KerriganVote vote) => TextSpan(
      text: switch (vote) {
        KerriganVote.yes => l10n.govYesCount(counts[vote]!),
        KerriganVote.no => l10n.govNoCount(counts[vote]!),
        KerriganVote.abstain => l10n.govAbstained(counts[vote]!),
      },
      style: STextStyles.w600_12(context)
          .copyWith(color: kerriganVoteColor(vote, colors)),
    );
    return Text.rich(
      TextSpan(
        children: [
          count(KerriganVote.yes),
          TextSpan(text: "  ·  ", style: label),
          count(KerriganVote.no),
          if (counts[KerriganVote.abstain]! > 0) ...[
            TextSpan(text: "  ·  ", style: label),
            count(KerriganVote.abstain),
          ],
          TextSpan(
            text: "  ·  ${l10n.govNotVotedCount(masternodes.length - voted)}",
            style: label,
          ),
        ],
      ),
    );
  }
}

/// One of the wallet's masternodes and its vote on a proposal.
class KerriganMasternodeVoteRow extends StatelessWidget {
  const KerriganMasternodeVoteRow({
    super.key,
    required this.wallet,
    required this.masternode,
    required this.vote,
    this.loading = false,
    this.inList = false,
  });

  final KerriganWallet wallet;
  final KerriganMasternode masternode;
  final KerriganMasternodeVote? vote;
  final bool loading;

  /// In a sheet listing them all: shows the server's address (searched
  /// by), but not the network status (a request per row).
  final bool inList;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final v = vote;
    final problem = wallet.votingProblem(masternode);
    final status = problem != null && v == null
        ? problem
        : loading
        ? l10n.kerriganNamesChecking
        : v == null
        ? l10n.govNotVoted
        : v.canChange
        ? l10n.govVotedAgo(_since(v.time))
        : l10n.govVotedAgoCanChange(
            _since(v.time),
            kerriganDuration(
              v.changeableAt.difference(DateTime.now()).inSeconds,
            ),
          );
    final service = masternode.service;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(masternode.label, style: STextStyles.w600_14(context)),
                const SizedBox(height: 2),
                Text(
                  inList && service != null ? "$service · $status" : status,
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
          if (v != null)
            KerriganPill(
              text: v.vote.label,
              color: kerriganVoteColor(v.vote, colors),
            )
          else if (!inList)
            KerriganMasternodeStatusTag(wallet: wallet, masternode: masternode),
        ],
      ),
    );
  }
}

String _since(int time) {
  final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000 - time;
  return kerriganDuration(seconds < 0 ? 0 : seconds);
}

/// Search the wallet's masternodes by alias or server address.
class KerriganMasternodeSearchField extends StatefulWidget {
  const KerriganMasternodeSearchField({super.key, required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  State<KerriganMasternodeSearchField> createState() =>
      _KerriganMasternodeSearchFieldState();
}

class _KerriganMasternodeSearchFieldState
    extends State<KerriganMasternodeSearchField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The fill colour follows the focus.
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
    child: TextField(
      controller: _controller,
      focusNode: _focus,
      autocorrect: false,
      enableSuggestions: false,
      style: STextStyles.field(context),
      onChanged: (value) {
        setState(() {});
        widget.onChanged(value);
      },
      decoration:
          standardInputDecoration(
            l10n.govSearchMasternodes,
            _focus,
            context,
          ).copyWith(
            prefixIcon: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
              child: SvgPicture.asset(Assets.svg.search, width: 16, height: 16),
            ),
            suffixIcon: _controller.text.isEmpty
                ? null
                : UnconstrainedBox(
                    child: TextFieldIconButton(
                      child: const XIcon(),
                      onTap: () {
                        _controller.clear();
                        setState(() {});
                        widget.onChanged("");
                      },
                    ),
                  ),
          ),
    ),
  );
}

/// A bottom sheet about the wallet's masternodes, laid out with
/// [KerriganSheetLayout].
Future<T?> showKerriganSheet<T>(BuildContext context, WidgetBuilder builder) =>
    showAppSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: builder,
    );

/// A sheet's handle, [header], scrolling [list] and [footer]. With
/// [fullHeight] (a long list) it fills the screen, else it is as tall as
/// its content.
class KerriganSheetLayout extends StatelessWidget {
  const KerriganSheetLayout({
    super.key,
    required this.fullHeight,
    required this.header,
    required this.list,
    this.footer = const [],
  });

  final bool fullHeight;
  final List<Widget> header;

  /// Shrink-wrapped unless [fullHeight].
  final Widget list;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return SafeArea(
      child: Padding(
        // Above the keyboard while searching.
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: fullHeight ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 60,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ...header,
            if (fullHeight) Expanded(child: list) else Flexible(child: list),
            ...footer,
          ],
        ),
      ),
    );
  }
}

/// "No masternode matches …", for a search that finds none.
Widget kerriganNoMasternodeMatches(BuildContext context, String query) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        l10n.govNoMasternodeMatch(query.trim()),
        textAlign: TextAlign.center,
        style: STextStyles.itemSubtitle(context),
      ),
    );

/// All of the wallet's masternodes and their [votes] on the proposal
/// [proposalName], latest vote first.
Future<void> showKerriganMasternodeVotesSheet(
  BuildContext context, {
  required KerriganWallet wallet,
  required String proposalName,
  required Map<String, KerriganMasternodeVote> votes,
}) => showKerriganSheet<void>(
  context,
  (_) => _MasternodeVotesSheet(
    wallet: wallet,
    proposalName: proposalName,
    votes: votes,
  ),
);

class _MasternodeVotesSheet extends StatefulWidget {
  const _MasternodeVotesSheet({
    required this.wallet,
    required this.proposalName,
    required this.votes,
  });

  final KerriganWallet wallet;
  final String proposalName;
  final Map<String, KerriganMasternodeVote> votes;

  @override
  State<_MasternodeVotesSheet> createState() => _MasternodeVotesSheetState();
}

class _MasternodeVotesSheetState extends State<_MasternodeVotesSheet> {
  late final _masternodes = kerriganByLatestVote(
    widget.wallet.masternodes,
    widget.votes,
  );
  String _query = "";

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final many = _masternodes.length > kKerriganManyMasternodes;
    final shown = [
      for (final m in _masternodes)
        if (kerriganMasternodeMatches(m, _query)) m,
    ];
    return KerriganSheetLayout(
      fullHeight: many,
      header: [
        Text(l10n.govYourMasternodes, style: STextStyles.pageTitleH2(context)),
        const SizedBox(height: 4),
        Text(
          widget.proposalName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: STextStyles.w500_12(context)
              .copyWith(color: colors.textSubtitle1),
        ),
        const SizedBox(height: 10),
        KerriganVoteCounts(masternodes: _masternodes, votes: widget.votes),
        if (many) ...[
          const SizedBox(height: 12),
          KerriganMasternodeSearchField(
            onChanged: (q) => setState(() => _query = q),
          ),
        ],
        const SizedBox(height: 8),
      ],
      list: shown.isEmpty
          ? kerriganNoMasternodeMatches(context, _query)
          : ListView.builder(
              shrinkWrap: !many,
              itemCount: shown.length,
              itemBuilder: (_, i) => KerriganMasternodeVoteRow(
                wallet: widget.wallet,
                masternode: shown[i],
                vote: widget.votes[shown[i].id],
                inList: true,
              ),
            ),
    );
  }
}

/// A titled value that copies itself when tapped.
class KerriganCopyRow extends StatelessWidget {
  const KerriganCopyRow({
    super.key,
    required this.title,
    required this.value,
    this.onOpen,
    this.openTooltip,
    this.footer,
  });

  final String title;
  final String value;

  /// Shown under the value.
  final Widget? footer;

  /// Shows a link button (e.g. to the block explorer).
  final VoidCallback? onOpen;
  final String? openTooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) {
          await showFloatingFlushBar(
            type: FlushBarType.info,
            message: l10n.commonCopiedWhat(title),
            iconAsset: Assets.svg.copy,
            context: context,
          );
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(value, style: STextStyles.w500_14(context)),
                  if (footer != null) ...[const SizedBox(height: 2), footer!],
                ],
              ),
            ),
            if (onOpen != null)
              IconButton(
                tooltip: openTooltip,
                visualDensity: VisualDensity.compact,
                onPressed: onOpen,
                icon: Icon(
                  Icons.open_in_new_rounded,
                  size: 18,
                  color: colors.accentColorBlue,
                ),
              )
            else
              const SizedBox(width: 8),
            Icon(Icons.copy_rounded, size: 16, color: colors.textSubtitle1),
          ],
        ),
      ),
    );
  }
}

/// Open a proposal's link after showing where it goes (links come from
/// whoever submitted the proposal).
Future<void> openKerriganProposalUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.scheme == "https" || uri.scheme == "http")) {
    await showFloatingFlushBar(
      type: FlushBarType.warning,
      message: l10n.govNotWebLink(url),
      context: context,
    );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StackDialog(
      title: l10n.govOpenLink,
      message: "$url\n\n${l10n.govOpenLinkText}",
      leftButton: TextButton(
        style: Theme.of(context)
            .extension<StackColors>()!
            .getSecondaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          l10n.commonCancel,
          style: STextStyles.button(context).copyWith(
            color: Theme.of(context).extension<StackColors>()!.accentColorDark,
          ),
        ),
      ),
      rightButton: TextButton(
        style: Theme.of(context)
            .extension<StackColors>()!
            .getPrimaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(true),
        child: Text(l10n.commonOpen, style: STextStyles.button(context)),
      ),
    ),
  );
  if (ok == true) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
