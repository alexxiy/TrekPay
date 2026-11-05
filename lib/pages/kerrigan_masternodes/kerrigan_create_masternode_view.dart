import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import '../../db/isar/main_db.dart';
import '../../l10n/l10n.dart';
import '../../models/isar/models/isar_models.dart';
import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/desktop_page_column.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/middle_ellipsis_text.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/secret_screen.dart';
import '../../widgets/stack_text_field.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/kerrigan_funding_card.dart';
import 'kerrigan_masternodes_view.dart';

enum _Collateral { newAddress, ownAddress }

/// What "Add existing masternode" can add: a registration found on the
/// network for one of the wallet's coins, or an unused collateral output.
typedef _Existing = ({KerriganFoundMasternode? found, UTXO? output});

/// Create a masternode: its type, where the collateral goes and how it is
/// paid. Registering it on the network comes next, on its details page.
class KerriganCreateMasternodeView extends ConsumerStatefulWidget {
  const KerriganCreateMasternodeView({
    super.key,
    required this.walletId,
    this.existing = false,
  });

  static const routeName = "/kerriganCreateMasternode";

  final String walletId;

  /// Add a masternode whose collateral is already in the wallet (e.g.
  /// after restoring it): nothing is sent.
  final bool existing;

  @override
  ConsumerState<KerriganCreateMasternodeView> createState() =>
      _KerriganCreateMasternodeViewState();
}

class _KerriganCreateMasternodeViewState
    extends ConsumerState<KerriganCreateMasternodeView> {
  final _labelController = TextEditingController();
  final _labelFocus = FocusNode();
  final _addressLabelController = TextEditingController();
  final _addressLabelFocus = FocusNode();

  KerriganMasternodeType _type = KerriganMasternodeType.regular;
  _Collateral _collateral = _Collateral.newAddress;

  Address? _newAddress;
  List<Address> _ownAddresses = const [];
  Address? _ownAddress;
  KerriganFunding _funding = kKerriganAutoFunding;

  /// "Add existing": what was found, null while looking.
  List<_Existing>? _existing;
  _Existing? _picked;
  String? _findError;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  @override
  void initState() {
    _labelController.text = _wallet.nextMasternodeAlias();
    unawaited(widget.existing ? _find() : _load());
    super.initState();
  }

  Future<void> _load() async {
    final wallet = _wallet;
    var newAddress = await wallet.getCurrentReceivingAddress();
    // A collateral sent moments ago may not have moved the wallet to its
    // next address yet: never offer the same "new" address twice.
    if (newAddress != null &&
        wallet.masternodes.any((m) => m.address == newAddress!.value)) {
      await wallet.generateNewReceivingAddress();
      newAddress = await wallet.getCurrentReceivingAddress();
    }
    final own = await MainDB.instance
        .getAddresses(widget.walletId)
        .filter()
        .group(
          (q) => q
              .subTypeEqualTo(AddressSubType.receiving)
              .or()
              .subTypeEqualTo(AddressSubType.change),
        )
        .and()
        .typeEqualTo(AddressType.p2pkh)
        .sortBySubType()
        .thenByDerivationIndex()
        .findAll();
    if (!mounted) return;
    setState(() {
      _newAddress = newAddress;
      _ownAddresses = own;
      _ownAddress = own.isEmpty ? null : own.first;
    });
  }

  Future<void> _find() async {
    final wallet = _wallet;
    try {
      final found = await wallet.findExistingMasternodes();
      final usedByFound = {for (final f in found) "${f.txid}:${f.vout}"};
      final outputs = [
        for (final t in KerriganMasternodeType.values)
          ...await wallet.availableCollaterals(t),
      ].where((u) => !usedByFound.contains("${u.txid}:${u.vout}"));
      if (!mounted) return;
      setState(() {
        _existing = [
          for (final f in found) (found: f, output: null),
          for (final u in outputs) (found: null, output: u),
        ];
        _picked = _existing!.firstOrNull;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _existing = const [];
          _findError = e.toString().replaceFirst("Exception: ", "");
        });
      }
    }
  }

  @override
  void dispose() {
    _labelController.dispose();
    _labelFocus.dispose();
    _addressLabelController.dispose();
    _addressLabelFocus.dispose();
    super.dispose();
  }

  String _addressTitle(Address a) =>
      kerriganAddressTitle(widget.walletId, a.value);

  Future<void> _create() async {
    final wallet = _wallet;
    final label = _labelController.text.trim();
    final aliasError = wallet.masternodeAliasError(label);
    if (aliasError != null) {
      await showFloatingFlushBar(
        type: FlushBarType.warning,
        message: aliasError,
        context: context,
      );
      return;
    }

    if (widget.existing) {
      final picked = _picked;
      if (picked == null) return;
      if (picked.found != null) {
        await wallet.addFoundMasternode(picked.found!, label: label);
      } else {
        final u = picked.output!;
        await wallet.addMasternode(
          label: label,
          type:
              u.value ==
                  wallet
                      .masternodeCollateral(KerriganMasternodeType.broodNode)
                      .raw
                      .toInt()
              ? KerriganMasternodeType.broodNode
              : KerriganMasternodeType.regular,
          address: u.address ?? "",
          txid: u.txid,
          vout: u.vout,
        );
      }
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final address = _collateral == _Collateral.newAddress
        ? _newAddress?.value
        : _ownAddress?.value;
    if (address == null) return;
    final type = _type;

    final prepared = await showBuildingTransaction<(TxData, int)>(
      context: context,
      coin: wallet.cryptoCurrency,
      build: () async {
        final txData = await wallet.prepareMasternodeCollateral(
          address: address,
          type: type,
          funding: _funding,
          note: l10n.mnCreateNote(label),
        );
        return (txData, wallet.collateralVout(txData, address, type));
      },
    );
    if (!mounted || prepared == null) return;

    final (txData, vout) = prepared;
    final addressLabel = _collateral == _Collateral.newAddress
        ? _addressLabelController.text.trim()
        : null;
    Future<void>? saving;
    await Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => DesktopPageColumn(
          card: true,
          child: ConfirmTransactionView(
            txData: txData,
            walletId: widget.walletId,
            onSuccess: () {
              // Recorded (and its output frozen) once broadcast.
              saving = wallet.addMasternode(
                label: label,
                type: type,
                address: address,
                txid: txData.txid!,
                vout: vout,
                addressLabel: addressLabel,
              );
            },
            onSuccessInsteadOfRouteOnSuccess: () async {
              await saving;
              if (mounted) {
                Navigator.of(context).popUntil(
                  ModalRoute.withName(KerriganMasternodesView.routeName),
                );
              }
            },
          ),
        ),
        settings: const RouteSettings(name: ConfirmTransactionView.routeName),
      ),
    );
  }

  Widget _radioCard<T>({
    required T value,
    required T group,
    required ValueChanged<T> onChanged,
    required String title,
    String? subtitle,
    Widget? body,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final selected = value == group;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => onChanged(value),
        child: RoundedWhiteContainer(
          borderColor: selected ? colors.accentColorBlue : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Radio<T>(
                value: value,
                groupValue: group,
                activeColor: colors.radioButtonIconEnabled,
                onChanged: (v) => onChanged(v as T),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: STextStyles.titleBold12(context)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        _subtitle(subtitle),
                      ],
                      if (body != null && selected) ...[
                        const SizedBox(height: 8),
                        body,
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subtitle(String text) => Text(
    text,
    style: STextStyles.w500_12(context).copyWith(
      color: Theme.of(context).extension<StackColors>()!.textSubtitle1,
    ),
  );

  Widget _aliasField(String? error) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final border = error == null
        ? null
        : OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: colors.textError, width: 1.5),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: TextField(
            controller: _labelController,
            focusNode: _labelFocus,
            autocorrect: false,
            enableSuggestions: false,
            style: STextStyles.field(context),
            onChanged: (_) => setState(() {}),
            decoration: standardInputDecoration(
              l10n.mnAliasHint,
              _labelFocus,
              context,
            ).copyWith(enabledBorder: border, focusedBorder: border),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, top: 4),
            child: Text(
              error,
              style: STextStyles.label(context)
                  .copyWith(color: colors.textError),
            ),
          ),
      ],
    );
  }

  List<Widget> _existingOptions() {
    final wallet = _wallet;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final existing = _existing;
    if (existing == null) {
      return [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (existing.isEmpty) {
      return [
        RoundedWhiteContainer(
          child: Text(
            _findError != null
                ? l10n.mnLookupFailed(_findError!)
                : l10n.mnNoExistingFound(
                    fmt.format(
                      wallet.masternodeCollateral(
                        KerriganMasternodeType.regular,
                      ),
                    ),
                    fmt.format(
                      wallet.masternodeCollateral(
                        KerriganMasternodeType.broodNode,
                      ),
                    ),
                  ),
            style: STextStyles.itemSubtitle(context),
          ),
        ),
      ];
    }
    return [
      for (final e in existing)
        _radioCard<_Existing>(
          value: e,
          group: _picked ?? existing.first,
          onChanged: (v) => setState(() => _picked = v),
          title: e.found != null
              ? l10n.mnRegisteredType(e.found!.type.label) +
                    (e.found!.service == null ? "" : " · ${e.found!.service}")
              : l10n.mnUnusedCollateral(
                  fmt.format(
                    Amount(
                      rawValue: BigInt.from(e.output!.value),
                      fractionDigits: wallet.cryptoCurrency.fractionDigits,
                    ),
                  ),
                ),
          subtitle: e.found != null
              ? "${e.found!.txid.substring(0, 16)}…:${e.found!.vout}"
                    "${e.found!.keyIndex == null ? " · ${l10n.mnKeysNotInWallet}" : ""}"
              : "${e.output!.txid.substring(0, 16)}…:${e.output!.vout}",
        ),
    ];
  }

  @override
  Widget build(BuildContext context) =>
      SecretScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final collateral = fmt.format(wallet.masternodeCollateral(_type));
    final aliasError = wallet.masternodeAliasError(_labelController.text);

    return Background(
      child: AppScaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text(
            widget.existing ? l10n.mnAddExisting : l10n.mnCreate,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.existing) ...[
                Text(
                  l10n.mnAddExistingIntroKerrigan,
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 20),
              ],
              Text(l10n.mnAlias, style: STextStyles.smallMed12(context)),
              const SizedBox(height: 8),
              _aliasField(aliasError),
              const SizedBox(height: 20),
              if (widget.existing) ...[
                Text(
                  l10n.mnOrCollateral,
                  style: STextStyles.smallMed12(context),
                ),
                const SizedBox(height: 8),
                ..._existingOptions(),
              ] else ...[
                Text(l10n.mnType, style: STextStyles.smallMed12(context)),
                const SizedBox(height: 8),
                for (final t in KerriganMasternodeType.values)
                  _radioCard<KerriganMasternodeType>(
                    value: t,
                    group: _type,
                    onChanged: (v) => setState(() => _type = v),
                    title:
                        "${t.label} · ${fmt.format(wallet.masternodeCollateral(t))}",
                    subtitle: t == KerriganMasternodeType.regular
                        ? l10n.mnRegularText
                        : l10n.mnBroodNodeText,
                  ),
                const SizedBox(height: 12),
                Text(l10n.mnCollateral, style: STextStyles.smallMed12(context)),
                const SizedBox(height: 8),
                _radioCard<_Collateral>(
                  value: _Collateral.newAddress,
                  group: _collateral,
                  onChanged: (v) => setState(() => _collateral = v),
                  title: l10n.mnSendToNewAddress(collateral),
                  body: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _subtitle(_newAddress?.value ?? "…"),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: TextField(
                          controller: _addressLabelController,
                          focusNode: _addressLabelFocus,
                          style: STextStyles.field(context),
                          decoration: standardInputDecoration(
                            // The example doesn't fit a phone's field.
                            Util.isDesktop
                                ? l10n.mnAddressLabelExample(
                                    _labelController.text.trim().isEmpty
                                        ? "MN1"
                                        : _labelController.text.trim(),
                                  )
                                : l10n.mnAddressLabelOptional,
                            _addressLabelFocus,
                            context,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_ownAddresses.isNotEmpty)
                  _radioCard<_Collateral>(
                    value: _Collateral.ownAddress,
                    group: _collateral,
                    onChanged: (v) => setState(() => _collateral = v),
                    title: l10n.mnSendToMyAddress(collateral),
                    body: DropdownButton<Address>(
                      isExpanded: true,
                      itemHeight: null,
                      value: _ownAddress,
                      dropdownColor: colors.popupBG,
                      items: [
                        for (final a in _ownAddresses)
                          DropdownMenuItem(
                            value: a,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _addressTitle(a),
                                    style: STextStyles.w600_14(context),
                                  ),
                                  MiddleEllipsisText(
                                    a.value,
                                    style: STextStyles.w500_12(context)
                                        .copyWith(color: colors.textSubtitle1),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                      onChanged: (a) => setState(() => _ownAddress = a),
                    ),
                  ),
                const SizedBox(height: 4),
                KerriganFundingCard(
                  walletId: widget.walletId,
                  funding: _funding,
                  amount: wallet.masternodeCollateral(_type),
                  onChanged: (f) => setState(() => _funding = f),
                ),
                const SizedBox(height: 12),
                _subtitle(
                  l10n.mnCreateNextKerrigan(wallet.cryptoCurrency.ticker),
                ),
              ],
              const SizedBox(height: 24),
              PrimaryButton(
                label: widget.existing ? l10n.mnAdd : l10n.mnSendCollateral,
                enabled:
                    aliasError == null && (!widget.existing || _picked != null),
                onPressed: _create,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
