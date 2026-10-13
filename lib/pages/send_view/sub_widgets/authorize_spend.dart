import 'package:flutter/material.dart';

import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import '../../../route_generator.dart';
import '../../../utilities/util.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../pinpad_views/lock_screen_view.dart';

/// Ask for the wallet password (desktop) or PIN / biometrics (mobile)
/// before signing a transaction that spends coins, as the send
/// confirmation does. True when the user is authorised.
Future<bool> authorizeSpend(
  BuildContext context, {
  required CryptoCurrency coin,
  String reason = "Authenticate to send transaction",
}) async {
  if (Util.isDesktop) {
    final unlocked = await showDialog<bool?>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [DesktopDialogCloseButton()],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 32, bottom: 32),
              child: DesktopAuthSend(coin: coin),
            ),
          ],
        ),
      ),
    );
    return unlocked == true;
  }
  final unlocked = await Navigator.push<bool>(
    context,
    RouteGenerator.getRoute<bool>(
      shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
      builder: (_) => LockscreenView(
        showBackButton: true,
        popOnSuccess: true,
        routeOnSuccessArguments: true,
        routeOnSuccess: "",
        biometricsCancelButtonString: "CANCEL",
        biometricsLocalizedReason: reason,
        biometricsAuthenticationTitle: "Confirm Transaction",
      ),
      settings: const RouteSettings(name: "/authorizespendlockscreen"),
    ),
  );
  return unlocked == true;
}
