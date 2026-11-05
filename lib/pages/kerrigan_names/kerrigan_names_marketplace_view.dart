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
import '../../utilities/util.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import 'kerrigan_names_common.dart';
import 'kerrigan_names_flow.dart';
import 'kerrigan_names_in_flight.dart';

/// Names for sale: buy one, or change the price of (or unlist) the
/// user's own listings.
class KerriganNamesMarketplaceView extends ConsumerStatefulWidget {
  const KerriganNamesMarketplaceView({super.key, required this.walletId});

  static const routeName = kKerriganNamesMarketplaceRoute;

  final String walletId;

  @override
  ConsumerState<KerriganNamesMarketplaceView> createState() =>
      _KerriganNamesMarketplaceViewState();
}

class _KerriganNamesMarketplaceViewState
    extends ConsumerState<KerriganNamesMarketplaceView> {
  String? _key;
  String _search = "";
  List<String> _zones = kKerriganNameZones;

  /// The pages shown so far, and where the next one starts (null: no more).
  List<KerriganNamesDomain>? _names;
  String? _next;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _moreError;
  int _request = 0;

  // Filters live with the screen: leaving it resets them.
  KerriganNamesFilter _filter = kKerriganNamesNoFilter;
  bool _filtersOpen = false;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  KerriganNamesRegistrar get _registrar =>
      KerriganNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;

  @override
  void initState() {
    super.initState();
    kerriganNamesChanges.addListener(_changed);
    unawaited(_loadKey());
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

  /// The user's key, to tell their own listings apart (the list has each
  /// owner's).
  Future<void> _loadKey() async {
    try {
      final key = await kerriganNamesPublicKey(_wallet);
      if (mounted) setState(() => _key = key);
    } catch (_) {}
  }

  /// The first page again.
  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _moreError = null;
    });
    try {
      final page = await _registrar.marketplace(
        search: _search,
        filter: _filter,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _names = page.items;
        _next = page.next;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(
        () => _error = l10n.kerriganNamesLoadNamesFailed(kerriganNamesError(e)),
      );
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  /// The page after those shown.
  Future<void> _more() async {
    final after = _next;
    if (after == null || _loading || _loadingMore) return;
    final request = _request;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await _registrar.marketplace(
        after: after,
        search: _search,
        filter: _filter,
      );
      if (!mounted || request != _request) return;
      setState(() {
        // A name whose listing changed meanwhile may come again.
        final shown = {for (final d in _names ?? const []) d.name};
        _names = [
          ...?_names,
          for (final d in page.items)
            if (!shown.contains(d.name)) d,
        ];
        _next = page.next;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(
        () => _moreError = l10n.kerriganNamesLoadNamesFailed(
          kerriganNamesError(e),
        ),
      );
    } finally {
      if (mounted && request == _request) setState(() => _loadingMore = false);
    }
  }

  void _setFilter(KerriganNamesFilter filter) {
    setState(() => _filter = filter);
    unawaited(_load());
  }

  KerriganNamesFlow _flow(KerriganNamesDomain d, KerriganNamesOp op) =>
      KerriganNamesFlow(
        walletId: widget.walletId,
        op: op,
        name: d.name,
        price: op == KerriganNamesOp.buy ? d.price : d.updatePrice,
        listedPrice: op == KerriganNamesOp.lst ? d.price : null,
        returnTo: KerriganNamesMarketplaceView.routeName,
      );

  Future<void> _buy(KerriganNamesDomain d) async {
    final ok = await kerriganNamesConfirm(
      context,
      title: l10n.kerriganNamesBuyName,
      message: l10n.kerriganNamesBuyConfirm(
        kerriganNamesUnbroken(d.name),
        kerriganNamesAmount(d.price, ref, _wallet),
      ),
      action: l10n.kerriganNamesBuy,
    );
    if (ok && mounted) {
      await startKerriganNamesFlow(context, ref, _flow(d, KerriganNamesOp.buy));
    }
  }

  Future<void> _unlist(KerriganNamesDomain d) async {
    final ok = await kerriganNamesConfirm(
      context,
      title: l10n.kerriganNamesUnlistTitle,
      message: l10n.kerriganNamesUnlistConfirm(kerriganNamesUnbroken(d.name)),
      action: l10n.kerriganNamesUnlist,
    );
    if (ok && mounted) {
      await startKerriganNamesFlow(context, ref, _flow(d, KerriganNamesOp.ult));
    }
  }

  Widget _card(KerriganNamesDomain d) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final own = _key != null && d.owner == _key;
    final inFlight = KerriganNamesInFlight.of(widget.walletId, d.name);
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
                if (own)
                  KerriganNamesPill(
                    text: l10n.kerriganNamesYours,
                    color: colors.accentColorBlue,
                  )
                else
                  KerriganNamesZoneBadge(name: d.name),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              kerriganNamesAmount(d.price, ref, _wallet),
              style: STextStyles.w600_18(context)
                  .copyWith(color: colors.accentColorBlue),
            ),
            const SizedBox(height: 10),
            if (inFlight != null)
              KerriganNamesInFlightNote(tracked: inFlight)
            else if (own)
              Row(
                children: [
                  Expanded(
                    child: SecondaryButton(
                      label: l10n.kerriganNamesChangePrice,
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      onPressed: () => startKerriganNamesFlow(
                        context,
                        ref,
                        _flow(d, KerriganNamesOp.lst),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SecondaryButton(
                      label: l10n.kerriganNamesUnlist,
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      onPressed: () => _unlist(d),
                    ),
                  ),
                ],
              )
            else
              PrimaryButton(
                label: l10n.kerriganNamesBuyName,
                buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                onPressed: () => _buy(d),
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
          title: l10n.kerriganNamesMarketplace,
          section: KerriganNamesSection.marketplace,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  l10n.kerriganNamesMarketplaceIntro,
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 12),
                KerriganNamesSearchBar(
                  search: KerriganNamesSearchField(
                    hint: l10n.kerriganNamesSearchOnSale,
                    onSearch: (term) {
                      _search = term;
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
                    onChanged: _setFilter,
                  ),
                const SizedBox(height: 12),
                if (_loading && names == null)
                  const KerriganNamesListState(loading: true)
                else if (_error != null)
                  KerriganNamesListState(error: _error, onRetry: _load)
                else if (names == null || names.isEmpty)
                  KerriganNamesListState(
                    empty: filtered
                        ? l10n.kerriganNamesNoFilterMatch
                        : _search.isNotEmpty
                        ? l10n.kerriganNamesNoMatch
                        : l10n.kerriganNamesNoneOnSale,
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
                        : SecondaryButton(
                            label: l10n.kerriganNamesSellMyNames,
                            width: 200,
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.m
                                : null,
                            onPressed: () => Navigator.of(context)
                                .pushReplacementNamed(
                                  KerriganNamesSection.myNames.routeName,
                                  arguments: widget.walletId,
                                ),
                          ),
                  )
                else ...[
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  CardGrid(children: [for (final d in names) _card(d)]),
                  if (_moreError != null)
                    KerriganNamesListState(error: _moreError, onRetry: _more)
                  else if (_next != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Center(
                        child: SecondaryButton(
                          label: l10n.kerriganNamesShowMore,
                          width: 200,
                          enabled: !_loadingMore && !_loading,
                          buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                          onPressed: _more,
                        ),
                      ),
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
