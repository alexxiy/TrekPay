import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/clipboard_interface.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/icon_buttons.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/secret_screen.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/stack_text_field.dart';
import '../pinpad_views/authenticate_user.dart';
import '../send_view/sub_widgets/authorize_spend.dart';
import 'kerrigan_masternodes_view.dart';

const _kMasternodeSpaceUrl = "https://masternode.space";

/// One masternode: where it stands, registering it on the network,
/// moving it to another server or operator, and how to get its server
/// running (hosted on masternode.space or on your own server).
class KerriganMasternodeDetailsView extends ConsumerStatefulWidget {
  const KerriganMasternodeDetailsView({
    super.key,
    required this.walletId,
    required this.masternodeId,
  });

  static const routeName = "/kerriganMasternodeDetails";

  final String walletId;
  final String masternodeId;

  @override
  ConsumerState<KerriganMasternodeDetailsView> createState() =>
      _KerriganMasternodeDetailsViewState();
}

class _KerriganMasternodeDetailsViewState
    extends ConsumerState<KerriganMasternodeDetailsView> {
  late Future<KerriganMasternodeState> _state;

  /// The wallet's keys for this masternode, once derived.
  ({String owner, String voting, ({String secret, String public})? operator})?
  _keys;
  bool _showSecret = false;

  final _serviceController = TextEditingController();
  final _serviceFocus = FocusNode();
  final _hostKeyController = TextEditingController();
  final _hostKeyFocus = FocusNode();

  /// Registering: the operator key comes from the host.
  bool _useHostKey = false;

  KerriganWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as KerriganWallet;

  KerriganMasternode? get _masternode =>
      _wallet.masternodes.where((e) => e.id == widget.masternodeId).firstOrNull;

  @override
  void initState() {
    super.initState();
    final mn = _masternode;
    _serviceController.text = mn?.service ?? "";
    _useHostKey =
        mn?.type == KerriganMasternodeType.broodNode ||
        mn?.hostOperatorKey != null;
    _hostKeyController.text = mn?.hostOperatorKey ?? "";
    _reload();
    unawaited(_loadKeys());
  }

  void _reload() {
    final mn = _masternode;
    if (mn != null) _state = _wallet.masternodeState(mn);
  }

  Future<void> _loadKeys() async {
    final wallet = _wallet;
    final saved = _masternode;
    if (saved == null || wallet.isViewOnly) return;
    var mn = saved;
    try {
      mn = await wallet.ensureMasternodeKeys(mn);
    } catch (_) {
      // Offline: registering picks the keys.
    }
    // Before registering, show the keys registering would use.
    final index = mn.keyIndex;
    final operatorIndex = mn.operatorIndex ?? (mn.isRegistered ? null : index);
    try {
      final keys = await wallet.masternodeKeys(
        index: index,
        operatorIndex: operatorIndex,
      );
      if (mounted) setState(() => _keys = keys);
    } catch (_) {
      // Keys are shown when available.
    }
  }

  @override
  void dispose() {
    _serviceController.dispose();
    _serviceFocus.dispose();
    _hostKeyController.dispose();
    _hostKeyFocus.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {
    _reload();
    unawaited(_loadKeys());
  });

  Future<void> _warn(Object e) => showFloatingFlushBar(
    type: FlushBarType.warning,
    message: e.toString().replaceFirst("Exception: ", ""),
    context: context,
    duration: const Duration(seconds: 5),
  );

  /// Build a provider transaction, confirm its fee, send it.
  Future<void> _providerTx({
    required String building,
    required Future<KerriganProviderTx> Function() build,
    required String title,
    required String message,
    required String done,
  }) async {
    final wallet = _wallet;
    Exception? error;
    final tx = await showLoading<KerriganProviderTx>(
      whileFuture: build(),
      context: context,
      message: building,
      onException: (e) => error = e,
    );
    if (!mounted) return;
    if (tx == null) {
      await _warn(error ?? l10n.mnBuildFailed);
      return;
    }
    final fee = ref.read(pAmountFormatter(wallet.cryptoCurrency)).format(
      tx.fee,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: title,
        message: "$message\n\n${l10n.mnNetworkFee(fee)}",
        leftButton: SecondaryButton(
          label: l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: l10n.commonSend,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    // The fee spends coins: authorise like any send.
    if (!await authorizeSpend(
      context,
      coin: wallet.cryptoCurrency,
      reason: l10n.mnAuthReason,
    )) {
      if (mounted) await _warn(l10n.mnNotAuthorised);
      return;
    }
    if (!mounted) return;
    final sent = await showLoading<KerriganMasternode>(
      whileFuture: wallet.sendProviderTx(tx),
      context: context,
      message: l10n.txSending,
      onException: (e) => error = e,
    );
    if (!mounted) return;
    if (sent == null) {
      await _warn(error ?? l10n.mnSendFailed);
      return;
    }
    _serviceController.text = sent.service ?? "";
    _refresh();
    await showFloatingFlushBar(
      type: FlushBarType.success,
      message: done,
      context: context,
      duration: const Duration(seconds: 5),
    );
  }

  String? _service() {
    final text = _serviceController.text.trim();
    if (text.isEmpty) return "";
    try {
      return _wallet.normalizeMasternodeService(text);
    } catch (e) {
      unawaited(_warn(e is FormatException ? e.message : e));
      return null;
    }
  }

  Future<void> _register(KerriganMasternode mn) async {
    final service = _service();
    if (service == null) return;
    final host = _useHostKey ? _hostKeyController.text.trim() : null;
    if (_useHostKey && !_wallet.isValidOperatorPublicKey(host ?? "")) {
      await _warn(l10n.mnPasteOperatorKey);
      return;
    }
    _serviceFocus.unfocus();
    await _providerTx(
      building: l10n.mnPreparingRegistration,
      build: () => _wallet.prepareMasternodeRegistration(
        mn,
        service: service,
        hostOperatorKey: host,
      ),
      title: l10n.mnRegisterTitle(mn.label),
      message: service.isEmpty
          ? l10n.mnRegisterNoServer
          : l10n.mnRegisterWithServer(service),
      done: l10n.mnRegistrationSent,
    );
  }

  Future<void> _updateService(KerriganMasternode mn) async {
    final service = _service();
    if (service == null || service.isEmpty) {
      if (service != null) await _warn(l10n.mnEnterIp);
      return;
    }
    _serviceFocus.unfocus();
    await _providerTx(
      building: l10n.mnPreparingUpdate,
      build: () =>
          _wallet.prepareMasternodeServiceUpdate(mn, service: service),
      title: l10n.mnSetServerTitle,
      message: l10n.mnServedBy(mn.label, service),
      done: l10n.mnUpdateSent,
    );
  }

  Future<void> _changeOperator(KerriganMasternode mn) async {
    final hostKey = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OperatorSheet(wallet: _wallet, masternode: mn),
    );
    if (hostKey == null || !mounted) return;
    await _providerTx(
      building: l10n.mnPreparingChange,
      build: () => _wallet.prepareMasternodeOperatorChange(
        mn,
        hostOperatorKey: hostKey.isEmpty ? null : hostKey,
      ),
      title: l10n.mnChangeOperatorTitle,
      message: hostKey.isEmpty
          ? l10n.mnChangeOperatorOwn
          : l10n.mnChangeOperatorHost,
      done: l10n.mnChangeSent,
    );
  }

  /// Copies [text], which holds the operator secret key.
  Future<void> _copy(String text, [String? what]) async {
    await const ClipboardWrapper().setSecret(text);
    if (mounted) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.info,
          message: what ?? l10n.commonCopiedToClipboard,
          context: context,
        ),
      );
    }
  }

  /// Shows the operator secret key once the user proved it's them (PIN
  /// or password): it runs the masternode, anywhere.
  Future<bool> _revealSecret() async {
    if (_showSecret) return true;
    final ok = await authenticateUser(
      context,
      coin: _wallet.cryptoCurrency,
      title: l10n.mnShowOperatorKey,
      reason: l10n.mnShowOperatorKeyReason,
    );
    if (ok && mounted) setState(() => _showSecret = true);
    return ok;
  }

  static const _hiddenSecret = "••••••••••••••••••••";

  /// Shorter in config lines, which then fit a phone's width.
  static const _hiddenSecretInCode = "••••••••••••";

  Widget _row(String label, String value, {bool secret = false}) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RoundedWhiteContainer(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    secret && !_showSecret ? _hiddenSecret : value,
                    style: STextStyles.w600_14(context),
                  ),
                ],
              ),
            ),
            if (secret)
              CustomTextButton(
                text: _showSecret ? l10n.commonHide : l10n.commonShow,
                onTap: _showSecret
                    ? () => setState(() => _showSecret = false)
                    : _revealSecret,
              ),
            if (!secret || _showSecret) ...[
              const SizedBox(width: 8),
              IconCopyButton(data: value, secret: secret),
            ],
          ],
        ),
      ),
    );
  }

  /// [code] holds the operator secret key: hidden, and not copied, until
  /// [_revealSecret].
  Widget _codeBlock(String Function(String secret) code, String secret) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              code(_showSecret ? secret : _hiddenSecretInCode),
              style: STextStyles.w500_12(context)
                  .copyWith(fontFamily: "monospace", color: colors.textDark),
            ),
          ),
          const SizedBox(width: 8),
          if (_showSecret)
            IconCopyButton(data: code(secret), secret: true)
          else
            CustomTextButton(text: l10n.commonShow, onTap: _revealSecret),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required FocusNode focus,
    required String hint,
    String? error,
    TextInputType? keyboardType,
  }) {
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
            controller: controller,
            focusNode: focus,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: keyboardType,
            style: STextStyles.field(context),
            onChanged: (_) => setState(() {}),
            decoration: standardInputDecoration(
              hint,
              focus,
              context,
            ).copyWith(enabledBorder: border, focusedBorder: border),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Text(
              error,
              style: STextStyles.label(context)
                  .copyWith(color: colors.textError),
            ),
          ),
      ],
    );
  }

  String? get _serviceError => _serviceController.text.trim().isEmpty
      ? null
      : _wallet.masternodeServiceError(_serviceController.text);

  String? get _hostKeyError {
    final key = _hostKeyController.text.trim();
    return key.isEmpty || _wallet.isValidOperatorPublicKey(key)
        ? null
        : l10n.mnNotOperatorKey;
  }

  Future<void> _showHostingDetails(KerriganMasternode mn) async {
    final colors = Theme.of(context).extension<StackColors>()!;
    final secret = _keys?.operator?.secret;
    final all = [
      "${l10n.mnCollateralTx}: ${mn.txid}",
      "${l10n.mnOutputIndex}: ${mn.vout}",
      if (secret != null) "${l10n.mnOperatorSecretForHost}: $secret",
    ].join("\n");
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: colors.popupBG,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.mnHostTitle,
                style: STextStyles.pageTitleH2(context),
              ),
              const SizedBox(height: 8),
              Text(
                secret != null
                    ? l10n.mnHostTextKerrigan
                    : l10n.mnHostTextHostKey(l10n.mnHostGaveKey),
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 16),
              _row(l10n.mnCollateralTx, mn.txid),
              _row(l10n.mnOutputIndex, "${mn.vout}"),
              if (secret != null)
                _row(l10n.mnOperatorSecretForHost, secret, secret: true),
              const SizedBox(height: 8),
              SecondaryButton(
                label: l10n.mnCopyAll,
                onPressed: () => _copy(all, l10n.mnHostingCopied),
              ),
              const SizedBox(height: 8),
              PrimaryButton(
                label: l10n.mnOpenMasternodeSpace,
                onPressed: () => launchUrl(
                  Uri.parse(_kMasternodeSpaceUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Future<void> _remove(KerriganMasternode mn) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: l10n.mnRemoveTitle,
        message: l10n.mnRemoveTextKerrigan,
        leftButton: SecondaryButton(
          label: l10n.commonCancel,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: l10n.commonRemove,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (confirmed != true) return;
    await _wallet.removeMasternode(mn);
    if (mounted) Navigator.of(context).pop();
  }

  Widget _section(String title, List<Widget> children, {String? subtitle}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: RoundedWhiteContainer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: STextStyles.w600_14(context)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle, style: STextStyles.itemSubtitle(context)),
              ],
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  List<Widget> _registerSection(KerriganMasternode mn) {
    final wallet = _wallet;
    final brood = mn.type == KerriganMasternodeType.broodNode;
    return [
      _section(
        l10n.mnRegisterSection,
        subtitle: l10n.mnRegisterSectionText,
        [
          _field(
            controller: _serviceController,
            focus: _serviceFocus,
            hint: l10n.mnServerIpExample,
            error: _serviceError,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          if (!brood)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _useHostKey
                        ? l10n.mnOperatorFromHost
                        : l10n.mnOperatorFromWallet,
                    style: STextStyles.smallMed12(context),
                  ),
                ),
                CustomTextButton(
                  text: _useHostKey ? l10n.mnMakeOneHere : l10n.mnHostGaveKey,
                  onTap: () => setState(() => _useHostKey = !_useHostKey),
                ),
              ],
            )
          else
            Text(
              l10n.mnBroodNodeRegisterText,
              style: STextStyles.itemSubtitle(context),
            ),
          const SizedBox(height: 8),
          if (_useHostKey)
            _field(
              controller: _hostKeyController,
              focus: _hostKeyFocus,
              hint: l10n.mnOperatorKeyHint,
              error: _hostKeyError,
            )
          else
            Text(
              l10n.mnOperatorWalletText,
              style: STextStyles.itemSubtitle(context),
            ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: l10n.mnRegister,
            enabled:
                !wallet.isViewOnly &&
                _serviceError == null &&
                (!_useHostKey ||
                    (_hostKeyController.text.trim().isNotEmpty &&
                        _hostKeyError == null)),
            onPressed: () => _register(mn),
          ),
        ],
      ),
    ];
  }

  List<Widget> _registeredSections(
    KerriganMasternode mn,
    KerriganMasternodeState? state,
  ) {
    final wallet = _wallet;
    final needsServer =
        state?.status == KerriganMasternodeStatus.needsServer ||
        state?.status == KerriganMasternodeStatus.banned;
    return [
      _section(
        l10n.mnServer,
        subtitle: mn.walletOperates
            ? needsServer
                  ? state?.status == KerriganMasternodeStatus.banned
                        ? l10n.mnServerRevive
                        : l10n.mnServerStart
                  : l10n.mnServerMoved
            : l10n.mnHostSetsServerNote,
        [
          if (mn.walletOperates) ...[
            _field(
              controller: _serviceController,
              focus: _serviceFocus,
              hint: l10n.mnServerIpExample,
              error: _serviceError,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 10),
            PrimaryButton(
              label: needsServer ? l10n.mnSetServer : l10n.mnUpdateServer,
              enabled:
                  !wallet.isViewOnly &&
                  _serviceController.text.trim().isNotEmpty &&
                  _serviceError == null,
              onPressed: () => _updateService(mn),
            ),
          ] else
            Text(
              state?.service ?? l10n.mnNotSet,
              style: STextStyles.w600_14(context),
            ),
        ],
      ),
      if (mn.keyIndex != null)
        _section(
          l10n.mnOperator,
          subtitle: l10n.mnOperatorText,
          [
            SecondaryButton(
              label: l10n.mnChangeOperator,
              enabled: !wallet.isViewOnly,
              onPressed: () => _changeOperator(mn),
            ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) =>
      SecretScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final mn = _masternode;
    final height = ref.watch(pWalletChainHeight(widget.walletId));
    final blockSeconds = wallet.cryptoCurrency.targetBlockTimeSeconds;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text(
            mn == null || mn.label.isEmpty ? l10n.mnMasternode : mn.label,
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: mn == null
            ? const SizedBox.shrink()
            : SafeArea(
                child: FutureBuilder<KerriganMasternodeState>(
                  future: _state,
                  builder: (context, snapshot) {
                    final state = snapshot.data;
                    final registered =
                        mn.isRegistered ||
                        (state != null &&
                            state.status !=
                                KerriganMasternodeStatus.unregistered &&
                            state.status != KerriganMasternodeStatus.unknown);
                    final operatorPublic =
                        mn.hostOperatorKey ?? _keys?.operator?.public;
                    final operatorSecret = mn.walletOperates || !registered
                        ? _keys?.operator?.secret
                        : null;
                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        RoundedWhiteContainer(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    mn.type.label,
                                    style: STextStyles.w600_14(context),
                                  ),
                                  const Spacer(),
                                  KerriganMasternodeStatusPill(
                                    status:
                                        state?.status ??
                                        KerriganMasternodeStatus.checking,
                                  ),
                                  const SizedBox(width: 8),
                                  CustomTextButton(
                                    text: l10n.commonRefresh,
                                    onTap: _refresh,
                                  ),
                                ],
                              ),
                              if (state != null &&
                                  state.registeredHeight > 0) ...[
                                const SizedBox(height: 8),
                                Text(
                                  [
                                    l10n.mnRegisteredLastPaid(
                                      state.registeredHeight,
                                      state.lastPaidHeight > 0
                                          ? kerriganBlocksAgo(
                                              height,
                                              state.lastPaidHeight,
                                              blockSeconds,
                                            )
                                          : l10n.mnNotYet,
                                    ),
                                    if (state.posePenalty > 0)
                                      l10n.mnPosePenalty(state.posePenalty),
                                  ].join(" · "),
                                  style: STextStyles.itemSubtitle(context),
                                ),
                              ],
                              if (state?.status ==
                                  KerriganMasternodeStatus.revoked) ...[
                                const SizedBox(height: 8),
                                Text(
                                  l10n.mnRevokedText,
                                  style: STextStyles.itemSubtitle(context),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (!registered)
                          ..._registerSection(mn)
                        else
                          ..._registeredSections(mn, state),
                        const SizedBox(height: 16),
                        Text(
                          l10n.mnEasiest,
                          style: STextStyles.w600_14(context),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.mnEasiestTextKerrigan,
                          style: STextStyles.itemSubtitle(context),
                        ),
                        const SizedBox(height: 12),
                        PrimaryButton(
                          label: l10n.mnShowWhatNeeded,
                          onPressed: () async {
                            if ((_keys?.operator?.secret == null ||
                                    await _revealSecret()) &&
                                mounted) {
                              await _showHostingDetails(mn);
                            }
                          },
                        ),
                        const SizedBox(height: 24),
                        Text(
                          l10n.mnOwnServer,
                          style: STextStyles.w600_14(context),
                        ),
                        const SizedBox(height: 8),
                        if (mn.type == KerriganMasternodeType.broodNode)
                          Text(
                            l10n.mnOwnServerBroodNode(
                              wallet.masternodePortOf(
                                mn.service ?? state?.service,
                              ),
                            ),
                            style: STextStyles.itemSubtitle(context),
                          )
                        else if (operatorSecret != null) ...[
                          Text(
                            (mn.service ?? state?.service) == null
                                ? l10n.mnOwnServerTextReplaceIp(
                                    wallet.masternodePortOf(null),
                                  )
                                : l10n.mnOwnServerText(
                                    wallet.masternodePortOf(
                                      mn.service ?? state?.service,
                                    ),
                                  ),
                            style: STextStyles.itemSubtitle(context),
                          ),
                          const SizedBox(height: 8),
                          _codeBlock(
                            (secret) => wallet.masternodeKerriganConf(
                              mn.copyWith(service: mn.service ?? state?.service),
                              secret,
                            ),
                            operatorSecret,
                          ),
                        ] else
                          Text(
                            l10n.mnOperatorFromHostText(l10n.mnChangeOperator),
                            style: STextStyles.itemSubtitle(context),
                          ),
                        const SizedBox(height: 24),
                        _row(l10n.mnCollateralAddress, mn.address),
                        _row(l10n.mnCollateralTx, mn.txid),
                        _row(l10n.mnOutputIndex, "${mn.vout}"),
                        _row(
                          l10n.mnPayoutAddress,
                          state?.payoutAddress ?? mn.payoutAddress,
                        ),
                        if (mn.proTxHash != null)
                          _row(l10n.mnRegistrationTx, mn.proTxHash!),
                        if ((state?.ownerAddress ?? _keys?.owner ?? "")
                            .isNotEmpty)
                          _row(
                            l10n.mnOwnerAddress,
                            state?.ownerAddress ?? _keys!.owner,
                          ),
                        if ((state?.votingAddress ?? _keys?.voting ?? "")
                            .isNotEmpty)
                          _row(
                            l10n.mnVotingAddress,
                            state?.votingAddress ?? _keys!.voting,
                          ),
                        if ((state?.operatorPublicKey ?? operatorPublic) !=
                            null)
                          _row(
                            l10n.mnOperatorPublicKey,
                            state?.operatorPublicKey ?? operatorPublic!,
                          ),
                        if (operatorSecret != null)
                          _row(
                            l10n.mnOperatorSecretKey,
                            operatorSecret,
                            secret: true,
                          ),
                        const SizedBox(height: 16),
                        SecondaryButton(
                          label: l10n.mnRemove,
                          onPressed: () => _remove(mn),
                        ),
                      ],
                    );
                  },
                ),
              ),
      ),
    );
  }
}

/// New operator key: one this wallet makes (pops "") or one from a host
/// (pops the key).
class _OperatorSheet extends StatefulWidget {
  const _OperatorSheet({required this.wallet, required this.masternode});

  final KerriganWallet wallet;
  final KerriganMasternode masternode;

  @override
  State<_OperatorSheet> createState() => _OperatorSheetState();
}

class _OperatorSheetState extends State<_OperatorSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late bool _host =
      widget.masternode.type == KerriganMasternodeType.broodNode;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final key = _controller.text.trim();
    final valid = widget.wallet.isValidOperatorPublicKey(key);
    final brood = widget.masternode.type == KerriganMasternodeType.broodNode;
    return Container(
      decoration: BoxDecoration(
        color: colors.popupBG,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        24,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.mnNewOperatorKey, style: STextStyles.pageTitleH2(context)),
          const SizedBox(height: 12),
          if (!brood) ...[
            RadioListTile<bool>(
              value: false,
              groupValue: _host,
              activeColor: colors.radioButtonIconEnabled,
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.mnMakeNewOperator,
                style: STextStyles.w600_14(context),
              ),
              subtitle: Text(
                l10n.mnMakeNewOperatorText,
                style: STextStyles.itemSubtitle(context),
              ),
              onChanged: (v) => setState(() => _host = v!),
            ),
            RadioListTile<bool>(
              value: true,
              groupValue: _host,
              activeColor: colors.radioButtonIconEnabled,
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.mnUseHostKey,
                style: STextStyles.w600_14(context),
              ),
              onChanged: (v) => setState(() => _host = v!),
            ),
          ] else
            Text(
              l10n.mnPasteIdentity,
              style: STextStyles.itemSubtitle(context),
            ),
          if (_host) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autocorrect: false,
                enableSuggestions: false,
                style: STextStyles.field(context),
                onChanged: (_) => setState(() {}),
                decoration: standardInputDecoration(
                  l10n.mnOperatorKeyHint,
                  _focus,
                  context,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          PrimaryButton(
            label: l10n.commonContinue,
            enabled: !_host || valid,
            onPressed: () =>
                Navigator.of(context).pop(_host ? key.toLowerCase() : ""),
          ),
        ],
      ),
    );
  }
}
