import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/kerrigan_name/kerrigan_names_protocol.dart';
import '../../services/kerrigan_name/kerrigan_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
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
  int _page = 1;
  String _search = "";
  KerriganNamesPage<KerriganNamesDomain>? _names;
  bool _loading = true;
  String? _error;
  int _request = 0;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  @override
  void initState() {
    super.initState();
    kerriganNamesChanges.addListener(_changed);
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
      // With the key, the user's own listings come marked.
      String? key = _key;
      if (key == null) {
        try {
          key = await kerriganNamesPublicKey(_wallet);
          if (mounted) setState(() => _key = key);
        } catch (_) {}
      }
      final names = await KerriganNamesRegistrar.forCoin(_wallet.cryptoCurrency)!
          .marketplace(pubkey: key, page: _page, search: _search);
      if (!mounted || request != _request) return;
      setState(() => _names = names);
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = l10n.kerriganNamesLoadNamesFailed(kerriganNamesError(e)));
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  KerriganNamesFlow _flow(KerriganNamesDomain d, KerriganNamesOp op) => KerriganNamesFlow(
    walletId: widget.walletId,
    op: op,
    name: d.name,
    price: op == KerriganNamesOp.buy ? d.price : null,
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
    return Background(
      child: Scaffold(
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
                KerriganNamesSearchField(
                  hint: l10n.kerriganNamesSearchOnSale,
                  onSearch: (term) {
                    _search = term;
                    _page = 1;
                    unawaited(_load());
                  },
                ),
                const SizedBox(height: 12),
                if (_loading && names == null)
                  const KerriganNamesListState(loading: true)
                else if (_error != null)
                  KerriganNamesListState(error: _error, onRetry: _load)
                else if (names == null || names.items.isEmpty)
                  KerriganNamesListState(
                    empty: _search.isNotEmpty
                        ? l10n.kerriganNamesNoMatch
                        : l10n.kerriganNamesNoneOnSale,
                    action: _search.isNotEmpty
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
                  for (final d in names.items) _card(d),
                  KerriganNamesPager(
                    page: _page,
                    count: names.count,
                    pageSize: kKerriganNamesListPageSize,
                    onPage: (p) {
                      _page = p;
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
