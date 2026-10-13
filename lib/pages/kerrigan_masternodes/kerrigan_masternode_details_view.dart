import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../notifications/show_flush_bar.dart';
import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/wallet/impl/kerrigan_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/icon_buttons.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_dialog.dart';
import '../../widgets/stack_text_field.dart';
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
      final keys = (
        owner: index == null ? "" : await wallet.masternodeOwnerAddress(index),
        voting: index == null
            ? ""
            : await wallet.masternodeVotingAddress(index),
        operator: operatorIndex == null
            ? null
            : await wallet.masternodeOperatorKey(operatorIndex),
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
      await _warn(error ?? "Couldn't build the transaction");
      return;
    }
    final fee = ref.read(pAmountFormatter(wallet.cryptoCurrency)).format(
      tx.fee,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: title,
        message: "$message\n\nNetwork fee: $fee",
        leftButton: SecondaryButton(
          label: "Cancel",
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: "Send",
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    // The fee spends coins: authorise like any send.
    if (!await authorizeSpend(
      context,
      coin: wallet.cryptoCurrency,
      reason: "Authenticate to send the masternode transaction",
    )) {
      if (mounted) await _warn("Not authorised");
      return;
    }
    if (!mounted) return;
    final sent = await showLoading<KerriganMasternode>(
      whileFuture: wallet.sendProviderTx(tx),
      context: context,
      message: "Sending",
      onException: (e) => error = e,
    );
    if (!mounted) return;
    if (sent == null) {
      await _warn(error ?? "Couldn't send the transaction");
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
      await _warn("Paste a valid operator public key (96 hex characters)");
      return;
    }
    _serviceFocus.unfocus();
    await _providerTx(
      building: "Preparing the registration",
      build: () => _wallet.prepareMasternodeRegistration(
        mn,
        service: service,
        hostOperatorKey: host,
      ),
      title: "Register ${mn.label}?",
      message: service.isEmpty
          ? "The masternode goes on the network without a server; it "
                "earns nothing until its server is set."
          : "The masternode goes on the network with server $service.",
      done:
          "Registration sent. The masternode is listed once the "
          "transaction is in a block.",
    );
  }

  Future<void> _updateService(KerriganMasternode mn) async {
    final service = _service();
    if (service == null || service.isEmpty) {
      if (service != null) await _warn("Enter the server's IP address");
      return;
    }
    _serviceFocus.unfocus();
    await _providerTx(
      building: "Preparing the update",
      build: () =>
          _wallet.prepareMasternodeServiceUpdate(mn, service: service),
      title: "Set the server",
      message: "${mn.label} will be served by $service.",
      done: "Update sent. It takes effect once in a block.",
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
      building: "Preparing the change",
      build: () => _wallet.prepareMasternodeOperatorChange(
        mn,
        hostOperatorKey: hostKey.isEmpty ? null : hostKey,
      ),
      title: "Change the operator key",
      message:
          "The masternode stops until its server is set again with the new "
          "key${hostKey.isEmpty ? " (do it here once this change is in a block)" : " (your host does that)"}.",
      done: "Change sent. Set the server once it is in a block.",
    );
  }

  Future<void> _copy(String text, [String what = "Copied to clipboard"]) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.info,
          message: what,
          context: context,
        ),
      );
    }
  }

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
                    secret && !_showSecret ? "••••••••••••••••••••" : value,
                    style: STextStyles.w600_14(context),
                  ),
                ],
              ),
            ),
            if (secret)
              CustomTextButton(
                text: _showSecret ? "Hide" : "Show",
                onTap: () => setState(() => _showSecret = !_showSecret),
              ),
            const SizedBox(width: 8),
            IconCopyButton(data: value),
          ],
        ),
      ),
    );
  }

  Widget _codeBlock(String code) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              code,
              style: STextStyles.w500_12(context)
                  .copyWith(fontFamily: "monospace", color: colors.textDark),
            ),
          ),
          const SizedBox(width: 8),
          IconCopyButton(data: code),
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
        : "Not an operator public key (96 hex characters)";
  }

  Future<void> _showHostingDetails(KerriganMasternode mn) async {
    final colors = Theme.of(context).extension<StackColors>()!;
    final secret = _keys?.operator?.secret;
    final all = [
      "Collateral transaction: ${mn.txid}",
      "Output index: ${mn.vout}",
      if (secret != null) "Masternode key (operator secret): $secret",
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                "Host on masternode.space",
                style: STextStyles.pageTitleH2(context),
              ),
              const SizedBox(height: 8),
              Text(
                secret != null
                    ? "Give masternode.space these values when you add the "
                          "masternode there. Your collateral never leaves "
                          "this wallet. They tell you the server's IP "
                          "address: enter it on this page to register the "
                          "masternode (or to update its server)."
                    : "Give masternode.space the collateral transaction "
                          "and output index. Ask them for the server's IP "
                          "address and its operator public key, then "
                          "register the masternode on this page with "
                          "\"My host gave me an operator key\".",
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 16),
              _row("Collateral transaction", mn.txid),
              _row("Output index", "${mn.vout}"),
              if (secret != null)
                _row("Masternode key (operator secret)", secret, secret: true),
              const SizedBox(height: 8),
              SecondaryButton(
                label: "Copy all",
                onPressed: () => _copy(all, "Hosting details copied"),
              ),
              const SizedBox(height: 8),
              PrimaryButton(
                label: "Open masternode.space",
                onPressed: () => launchUrl(
                  Uri.parse(_kMasternodeSpaceUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _remove(KerriganMasternode mn) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: "Remove masternode?",
        message:
            "Astronaut forgets this masternode and unfreezes its collateral, "
            "so it can be spent. Spending the collateral ends the masternode "
            "on the network.",
        leftButton: SecondaryButton(
          label: "Cancel",
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: "Remove",
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
        "Register on the network",
        subtitle:
            "Registering puts the masternode on the network with its "
            "server's address and the operator key the server runs with. "
            "Get the server ready first (see below); you may also register "
            "now without a server and set it later.",
        [
          _field(
            controller: _serviceController,
            focus: _serviceFocus,
            hint: "Server IP, e.g. 203.0.113.5",
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
                        ? "Operator key from my host"
                        : "Operator key made by this wallet",
                    style: STextStyles.smallMed12(context),
                  ),
                ),
                CustomTextButton(
                  text: _useHostKey
                      ? "Make one here"
                      : "My host gave me an operator key",
                  onTap: () => setState(() => _useHostKey = !_useHostKey),
                ),
              ],
            )
          else
            Text(
              "A BroodNode registers with its server's identity key: run "
              "\"kerrigan-cli gethmpidentity\" on the server and paste the "
              "identity here.",
              style: STextStyles.itemSubtitle(context),
            ),
          const SizedBox(height: 8),
          if (_useHostKey)
            _field(
              controller: _hostKeyController,
              focus: _hostKeyFocus,
              hint: "Operator public key (96 hex characters)",
              error: _hostKeyError,
            )
          else
            Text(
              "The server runs with this wallet's operator secret key "
              "(shown below). Restoring this wallet brings it back.",
              style: STextStyles.itemSubtitle(context),
            ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: "Register masternode",
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
        "Server",
        subtitle: mn.walletOperates
            ? needsServer
                  ? "Enter the server's address to ${state?.status == KerriganMasternodeStatus.banned ? "revive the masternode" : "start the masternode"}. "
                        "The server must run Kerrigan Core with this "
                        "masternode's operator secret key."
                  : "Moved to another server? Enter its address."
            : "Your host holds this masternode's operator key and sets its "
                  "server.",
        [
          if (mn.walletOperates) ...[
            _field(
              controller: _serviceController,
              focus: _serviceFocus,
              hint: "Server IP, e.g. 203.0.113.5",
              error: _serviceError,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 10),
            PrimaryButton(
              label: needsServer ? "Set server" : "Update server",
              enabled:
                  !wallet.isViewOnly &&
                  _serviceController.text.trim().isNotEmpty &&
                  _serviceError == null,
              onPressed: () => _updateService(mn),
            ),
          ] else
            Text(
              state?.service ?? "Not set",
              style: STextStyles.w600_14(context),
            ),
        ],
      ),
      if (mn.keyIndex != null)
        _section(
          "Operator",
          subtitle:
              "Moving to another host, or a key that leaked? Give the "
              "masternode a new operator key.",
          [
            SecondaryButton(
              label: "Change operator key",
              enabled: !wallet.isViewOnly,
              onPressed: () => _changeOperator(mn),
            ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final mn = _masternode;
    final height = ref.watch(pWalletChainHeight(widget.walletId));
    final blockSeconds = wallet.cryptoCurrency.targetBlockTimeSeconds;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            mn == null || mn.label.isEmpty ? "Masternode" : mn.label,
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
                                    text: "Refresh",
                                    onTap: _refresh,
                                  ),
                                ],
                              ),
                              if (state != null &&
                                  state.registeredHeight > 0) ...[
                                const SizedBox(height: 8),
                                Text(
                                  "Registered at block "
                                  "${state.registeredHeight} · last paid "
                                  "${state.lastPaidHeight > 0 ? kerriganBlocksAgo(height, state.lastPaidHeight, blockSeconds) : "not yet"}"
                                  "${state.posePenalty > 0 ? " · PoSe penalty ${state.posePenalty}" : ""}",
                                  style: STextStyles.itemSubtitle(context),
                                ),
                              ],
                              if (state?.status ==
                                  KerriganMasternodeStatus.revoked) ...[
                                const SizedBox(height: 8),
                                Text(
                                  "Its operator stopped serving it. Give it "
                                  "a new operator key below.",
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
                          "Easiest: host it on masternode.space",
                          style: STextStyles.w600_14(context),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "masternode.space runs the server for you: no "
                          "server to rent, set up or keep online. Your "
                          "collateral stays in this wallet.",
                          style: STextStyles.itemSubtitle(context),
                        ),
                        const SizedBox(height: 12),
                        PrimaryButton(
                          label: "Show what masternode.space needs",
                          onPressed: () => _showHostingDetails(mn),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          "Or run it on your own server",
                          style: STextStyles.w600_14(context),
                        ),
                        const SizedBox(height: 8),
                        if (mn.type == KerriganMasternodeType.broodNode)
                          Text(
                            "Install Kerrigan Core on the server and open "
                            "port ${wallet.masternodePortOf(mn.service ?? state?.service)}. "
                            "Register with "
                            "the identity \"kerrigan-cli gethmpidentity\" "
                            "prints there, following Kerrigan's BroodNode "
                            "guide for the server's settings.",
                            style: STextStyles.itemSubtitle(context),
                          )
                        else if (operatorSecret != null) ...[
                          Text(
                            "Install Kerrigan Core on the server, put these "
                            "lines in its kerrigan.conf"
                            "${(mn.service ?? state?.service) == null ? " (replace YOUR_SERVER_IP with its public IP)" : ""}, "
                            "open port ${wallet.masternodePortOf(mn.service ?? state?.service)} "
                            "and restart "
                            "kerrigand. Then register the masternode (or "
                            "set its server) above.",
                            style: STextStyles.itemSubtitle(context),
                          ),
                          const SizedBox(height: 8),
                          _codeBlock(
                            wallet.masternodeKerriganConf(
                              mn.copyWith(service: mn.service ?? state?.service),
                              operatorSecret,
                            ),
                          ),
                        ] else
                          Text(
                            "This masternode's operator key comes from its "
                            "host. To run it yourself, give it a new "
                            "operator key made by this wallet (\"Change "
                            "operator key\").",
                            style: STextStyles.itemSubtitle(context),
                          ),
                        const SizedBox(height: 24),
                        _row("Collateral address", mn.address),
                        _row("Collateral transaction", mn.txid),
                        _row("Output index", "${mn.vout}"),
                        _row(
                          "Payout address",
                          state?.payoutAddress ?? mn.payoutAddress,
                        ),
                        if (mn.proTxHash != null)
                          _row("Registration transaction", mn.proTxHash!),
                        if ((state?.ownerAddress ?? _keys?.owner ?? "")
                            .isNotEmpty)
                          _row(
                            "Owner address",
                            state?.ownerAddress ?? _keys!.owner,
                          ),
                        if ((state?.votingAddress ?? _keys?.voting ?? "")
                            .isNotEmpty)
                          _row(
                            "Voting address",
                            state?.votingAddress ?? _keys!.voting,
                          ),
                        if ((state?.operatorPublicKey ?? operatorPublic) !=
                            null)
                          _row(
                            "Operator public key",
                            state?.operatorPublicKey ?? operatorPublic!,
                          ),
                        if (operatorSecret != null)
                          _row(
                            "Operator secret key",
                            operatorSecret,
                            secret: true,
                          ),
                        const SizedBox(height: 16),
                        SecondaryButton(
                          label: "Remove masternode",
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
          Text("New operator key", style: STextStyles.pageTitleH2(context)),
          const SizedBox(height: 12),
          if (!brood) ...[
            RadioListTile<bool>(
              value: false,
              groupValue: _host,
              activeColor: colors.radioButtonIconEnabled,
              contentPadding: EdgeInsets.zero,
              title: Text(
                "Make a new one in this wallet",
                style: STextStyles.w600_14(context),
              ),
              subtitle: Text(
                "For your own server: put its secret in kerrigan.conf.",
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
                "Use my host's key",
                style: STextStyles.w600_14(context),
              ),
              onChanged: (v) => setState(() => _host = v!),
            ),
          ] else
            Text(
              "Paste the identity \"kerrigan-cli gethmpidentity\" prints on "
              "the BroodNode's server.",
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
                  "Operator public key (96 hex characters)",
                  _focus,
                  context,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          PrimaryButton(
            label: "Continue",
            enabled: !_host || valid,
            onPressed: () =>
                Navigator.of(context).pop(_host ? key.toLowerCase() : ""),
          ),
        ],
      ),
    );
  }
}
