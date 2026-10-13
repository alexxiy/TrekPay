import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/show_flush_bar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/stack_dialog.dart';

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
              "$yeas Yes",
              style: STextStyles.w600_12(context).copyWith(color: yes),
            ),
            Text("  ·  ", style: label),
            Text(
              "$nays No",
              style: STextStyles.w600_12(context).copyWith(color: no),
            ),
            const Spacer(),
            if (net != null && need != null)
              Text(
                "$net of $need net Yes",
                style: STextStyles.w600_12(context).copyWith(
                  color: net >= need ? yes : colors.textSubtitle1,
                ),
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
            message: "$title copied",
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
      message: "Not a web link: $url",
      context: context,
    );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StackDialog(
      title: "Open link?",
      message:
          "$url\n\nThe proposal's author set this link. Check it before "
          "you trust what it shows.",
      leftButton: TextButton(
        style: Theme.of(context)
            .extension<StackColors>()!
            .getSecondaryEnabledButtonStyle(context),
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          "Cancel",
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
        child: Text("Open", style: STextStyles.button(context)),
      ),
    ),
  );
  if (ok == true) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

