import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/isar/main_db.dart';
import '../../l10n/l10n.dart';
import '../../models/isar/models/isar_models.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/kerrigan_name/kerrigan_name.dart';
import '../../services/kerrigan_name/kerrigan_names_protocol.dart';
import '../../services/kerrigan_name/kerrigan_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/middle_ellipsis_text.dart';
import '../../widgets/rounded_white_container.dart';
import '../send_view/sub_widgets/kerrigan_funding_card.dart';
import 'kerrigan_names_common.dart';
import 'kerrigan_names_flow.dart';
import 'kerrigan_names_in_flight.dart';

/// The names this wallet's key owns: where they point, and changing the
/// destination, the owner or the listing.
class KerriganNamesMyNamesView extends ConsumerStatefulWidget {
  const KerriganNamesMyNamesView({super.key, required this.walletId});

  static const routeName = kKerriganNamesMyNamesRoute;

  final String walletId;

  @override
  ConsumerState<KerriganNamesMyNamesView> createState() =>
      _KerriganNamesMyNamesViewState();
}

class _KerriganNamesMyNamesViewState
    extends ConsumerState<KerriganNamesMyNamesView> {
  String? _key;
  String? _keyError;

  int _page = 1;
  String _search = "";
  KerriganNamesPage<KerriganNamesDomain>? _names;
  bool _loading = true;
  String? _error;
  int _request = 0;

  // Filters live with the screen: leaving it resets them.
  KerriganNamesFilter _filter = kKerriganNamesNoFilter;
  bool _filtersOpen = false;
  List<String> _zones = kKerriganNameZones;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  @override
  void initState() {
    super.initState();
    kerriganNamesChanges.addListener(_changed);
    unawaited(
      kerriganNamesZones(_wallet).then((zones) {
        if (mounted) setState(() => _zones = zones);
      }),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    kerriganNamesChanges.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_load());

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final key = _key ?? await kerriganNamesPublicKey(_wallet);
      if (!mounted || request != _request) return;
      setState(() => _key = key);
      final registrar = KerriganNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;
      var names = await registrar.myNames(
        pubkey: key,
        page: _page,
        search: _search,
        filter: _filter,
      );
      // Past the end (a name sold or moved meanwhile): the last page.
      final last = (names.count / kKerriganNamesListPageSize).ceil();
      if (names.items.isEmpty && _page > 1) {
        if (!mounted || request != _request) return;
        _page = last < 1 ? 1 : last;
        if (last >= 1) {
          names = await registrar.myNames(
            pubkey: key,
            page: last,
            search: _search,
            filter: _filter,
          );
        }
      }
      if (!mounted || request != _request) return;
      setState(() => _names = names);
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        if (_key == null) _keyError = kerriganNamesError(e);
        _error = l10n.kerriganNamesLoadMyNamesFailed(kerriganNamesError(e));
      });
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _setFilter(KerriganNamesFilter filter) {
    setState(() {
      _filter = filter;
      _page = 1;
    });
    unawaited(_load());
  }

  void _setPage(int page) {
    setState(() => _page = page);
    unawaited(_load());
  }

  Future<void> _start(KerriganNamesFlow flow) =>
      startKerriganNamesFlow(context, ref, flow);

  KerriganNamesFlow _flow(
    KerriganNamesDomain d,
    KerriganNamesOp op, {
    BigInt? listedPrice,
  }) => KerriganNamesFlow(
    walletId: widget.walletId,
    op: op,
    name: d.name,
    returnTo: KerriganNamesMyNamesView.routeName,
    price: d.updatePrice,
    currentAddress: d.address,
    listedPrice: listedPrice,
  );

  Future<void> _unlist(KerriganNamesDomain d) async {
    final ok = await kerriganNamesConfirm(
      context,
      title: l10n.kerriganNamesUnlistTitle,
      message: l10n.kerriganNamesUnlistConfirm(kerriganNamesUnbroken(d.name)),
      action: l10n.kerriganNamesUnlist,
    );
    if (ok && mounted) await _start(_flow(d, KerriganNamesOp.ult));
  }

  /// What can be done with [d], in a sheet: the price or unlisting while
  /// it's on sale, else its destination, owner or listing.
  Future<void> _manage(KerriganNamesDomain d) async {
    final colors = Theme.of(context).extension<StackColors>()!;
    final listed = d.price > BigInt.zero;
    final actions = <_Action>[
      if (listed) ...[
        (
          icon: KerriganNamesIcons.price,
          label: l10n.kerriganNamesFlowChangePrice,
          note: l10n.kerriganNamesListedForShort(
            kerriganNamesAmount(d.price, ref, _wallet),
          ),
          run: () =>
              _start(_flow(d, KerriganNamesOp.lst, listedPrice: d.price)),
        ),
        (
          icon: KerriganNamesIcons.unlist,
          label: l10n.kerriganNamesUnlist,
          note: l10n.kerriganNamesActionUnlistNote,
          run: () => _unlist(d),
        ),
      ] else ...[
        (
          icon: KerriganNamesIcons.destination,
          label: l10n.kerriganNamesFlowChangeDestination,
          note: l10n.kerriganNamesActionDestinationNote,
          run: () => _start(_flow(d, KerriganNamesOp.upd)),
        ),
        (
          icon: KerriganNamesIcons.owner,
          label: l10n.kerriganNamesFlowChangeOwner,
          note: l10n.kerriganNamesActionOwnerNote,
          run: () => _start(_flow(d, KerriganNamesOp.chg)),
        ),
        (
          icon: KerriganNamesIcons.list,
          label: l10n.kerriganNamesActionList,
          note: l10n.kerriganNamesActionListNote,
          run: () => _start(_flow(d, KerriganNamesOp.lst)),
        ),
      ],
    ];
    final picked = await showAppSheet<_Action>(
      scrollable: true,
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
              KerriganNamesNameText(
                d.name,
                style: STextStyles.pageTitleH2(context),
              ),
              const SizedBox(height: 12),
              for (final a in actions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _actionTile(a),
                ),
            ],
          ),
        ),
      ),
    );
    // Once the sheet is gone, so that the flow opens over this page.
    if (picked != null && mounted) await picked.run();
  }

  Widget _actionTile(_Action a) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = a.icon == KerriganNamesIcons.unlist
        ? colors.textError
        : colors.accentColorBlue;
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).pop(a),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: KerriganNamesIcon(a.icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.label, style: STextStyles.w600_14(context)),
                    const SizedBox(height: 2),
                    Text(
                      a.note,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: colors.textSubtitle1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyCard() {
    final colors = Theme.of(context).extension<StackColors>()!;
    final key = _key;
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: key == null
            ? null
            : () => kerriganNamesCopy(context, key, l10n.commonPublicKey),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.kerriganNamesYourPublicKey,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ),
                  if (key != null)
                    Icon(
                      Icons.copy_rounded,
                      size: 16,
                      color: colors.textSubtitle1,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                key ?? _keyError ?? "…",
                style: STextStyles.w500_12(context).copyWith(
                  fontFamily: "monospace",
                  color: key == null && _keyError != null
                      ? colors.textError
                      : colors.textDark,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.kerriganNamesPublicKeyExplained,
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(KerriganNamesDomain d) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final listed = d.price > BigInt.zero;
    final address = d.address;
    final own =
        address != null &&
        MainDB.instance.isar.addresses.getByValueWalletIdSync(
              address,
              widget.walletId,
            ) !=
            null;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final walletId = widget.walletId;
    final inFlight = KerriganNamesInFlight.of(walletId, d.name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RoundedWhiteContainer(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: KerriganNamesNameText(d.name)),
                const SizedBox(width: 8),
                listed
                    ? KerriganNamesPill(
                        text: l10n.kerriganNamesOnSale(
                          kerriganNamesAmount(d.price, ref, wallet),
                        ),
                        color: colors.accentColorBlue,
                      )
                    : KerriganNamesPill(
                        text: l10n.kerriganNamesActive,
                        color: kerriganNamesReadable(
                          colors.accentColorGreen,
                          colors,
                        ),
                      ),
              ],
            ),
            if (address != null) ...[
              const SizedBox(height: 10),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () =>
                    kerriganNamesCopy(context, address, l10n.commonAddress),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              own
                                  ? l10n.kerriganNamesPointsTo(
                                      kerriganAddressTitle(walletId, address),
                                    )
                                  // Possibly one of this phrase's that the
                                  // wallet hasn't made yet (after a
                                  // restore): not "outside the wallet".
                                  : l10n.kerriganNamesPointsElsewhere,
                              style: secondary,
                            ),
                            const SizedBox(height: 2),
                            MiddleEllipsisText(
                              address,
                              style: STextStyles.w500_14(context),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: colors.textSubtitle1,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (inFlight != null)
              KerriganNamesInFlightNote(tracked: inFlight)
            else
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 160),
                  child: IntrinsicWidth(
                    child: SecondaryButton(
                      label: l10n.kerriganNamesManage,
                      icon: KerriganNamesIcon(
                        KerriganNamesIcons.manage,
                        size: 18,
                        color: colors.buttonTextSecondary,
                      ),
                      iconSpacing: 8,
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      onPressed: () => _manage(d),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final names = _names;
    final filtered = _filter != kKerriganNamesNoFilter;
    return Background(
      child: AppScaffold(
        maxBodyWidth: ScreenFit.panesOrColumn(context),
        backgroundColor: colors.background,
        appBar: KerriganNamesAppBar(
          walletId: widget.walletId,
          title: l10n.kerriganNamesMyNames,
          section: KerriganNamesSection.myNames,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  l10n.kerriganNamesMyNamesIntro,
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 12),
                _keyCard(),
                const SizedBox(height: 12),
                KerriganNamesSearchBar(
                  search: KerriganNamesSearchField(
                    hint: l10n.kerriganNamesSearchMine,
                    onSearch: (term) {
                      _search = term;
                      _page = 1;
                      unawaited(_load());
                    },
                  ),
                  filter: _filter,
                  open: _filtersOpen,
                  onToggle: () => setState(() => _filtersOpen = !_filtersOpen),
                ),
                if (_filtersOpen)
                  KerriganNamesFilterPanel(
                    filter: _filter,
                    zones: _zones,
                    withStatus: true,
                    onChanged: _setFilter,
                  ),
                const SizedBox(height: 12),
                if (_loading && names == null)
                  const KerriganNamesListState(loading: true)
                else if (_error != null)
                  KerriganNamesListState(error: _error, onRetry: _load)
                else if (names == null || names.items.isEmpty)
                  KerriganNamesListState(
                    empty: filtered
                        ? l10n.kerriganNamesNoFilterMatch
                        : _search.isNotEmpty
                        ? l10n.kerriganNamesNoMatch
                        : l10n.kerriganNamesNoneYet,
                    action: filtered
                        ? SecondaryButton(
                            label: l10n.kerriganNamesResetFilters,
                            width: 200,
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.m
                                : null,
                            onPressed: () => _setFilter(kKerriganNamesNoFilter),
                          )
                        : _search.isNotEmpty
                        ? null
                        : PrimaryButton(
                            label: l10n.kerriganNamesRegisterFirst,
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.m
                                : null,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                  )
                else ...[
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  CardGrid(children: [for (final d in names.items) _card(d)]),
                  KerriganNamesPager(
                    page: _page,
                    count: names.count,
                    pageSize: kKerriganNamesListPageSize,
                    onPage: _setPage,
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

typedef _Action = ({
  String icon,
  String label,
  String note,
  FutureOr<void> Function() run,
});
