#!/usr/bin/env bash

set -x -e

# Configure files for TrekPay.
APP_BUILD_PLATFORM=$1

export NEW_NAME="TrekPay"
export NEW_APP_ID="alexxiy.kerrigan"
export NEW_APP_ID_CAMEL="alexxiy.kerrigan"
export NEW_APP_ID_SNAKE="alexxiy.kerrigan"
# Linux: Flatpak IDs need three parts, and on Wayland a window finds its
# icon through a .desktop file named after its ID, so every Linux package
# (tarball, AppImage, Flatpak) uses this one.
export NEW_LINUX_APP_ID="alexxiy.kerrigan.TrekPay"
export NEW_BASIC_NAME="trekpay"

NEW_PUBSPEC_NAME="paymint" # package name used across lib/ imports
PUBSPEC_FILE="${APP_PROJECT_ROOT_DIR}/pubspec.yaml"

# String replacements.
if [[ "$(uname)" == 'Darwin' ]]; then
  # macos specific sed
  sed -i '' "s/name: PLACEHOLDER/name: ${NEW_PUBSPEC_NAME}/g" "${PUBSPEC_FILE}"
  sed -i '' "s/description: PLACEHOLDER/description: ${NEW_NAME}/g" "${PUBSPEC_FILE}"
else
  sed -i "s/name: PLACEHOLDER/name: ${NEW_PUBSPEC_NAME}/g" "${PUBSPEC_FILE}"
  sed -i "s/description: PLACEHOLDER/description: ${NEW_NAME}/g" "${PUBSPEC_FILE}"
fi

dart "${APP_PROJECT_ROOT_DIR}/tool/process_pubspec_deps.dart" \
      "${PUBSPEC_FILE}" \
      TOR \
      KERRIGAN

dart "${APP_PROJECT_ROOT_DIR}/tool/gen_interfaces.dart" \
      "${APP_PROJECT_ROOT_DIR}/tool/wl_templates" \
      "${APP_PROJECT_ROOT_DIR}/lib/wl_gen/generated" \
      TOR \
      KERRIGAN

pushd "${APP_PROJECT_ROOT_DIR}"
BUILT_COMMIT_HASH=$(git log -1 --pretty=format:"%H")
popd

APP_CONFIG_DART_FILE="${APP_PROJECT_ROOT_DIR}/lib/app_config.g.dart"
rm -f "$APP_CONFIG_DART_FILE"
cat << EOF > "$APP_CONFIG_DART_FILE"
// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_config.dart';

const _prefix = "TrekPay";
const _separator = "";
const _suffix = "";
const _emptyWalletsMessage =
    "Create your first Kerrigan wallet";
const _appDataDirName = "trekpay";
const _shortDescriptionText = "Your privacy. Your keys. Your KRGN.";
const _commitHash = "$BUILT_COMMIT_HASH";

// Project links. Empty ones are not shown in the app.
const _websiteUrl = "https://trekpay.space";
const _termsUrl = "https://trekpay.space/terms-of-service.html";
const _privacyUrl = "https://trekpay.space/privacy-policy.html";

// Support. The developer: questions about the app and bug reports.
const List<SupportLink> _developerLinks = [
  (
    channel: SupportChannel.telegram,
    text: "@alexxiy_lounge",
    url: "https://t.me/alexxiy_lounge",
  ),
  (
    channel: SupportChannel.email,
    text: "support@trekpay.space",
    url: "mailto:support@trekpay.space",
  ),
];

// The official Kerrigan community (see kerrigan.network).
const List<SupportLink> _communityLinks = [
  (
    channel: SupportChannel.discord,
    text: "Kerrigan Discord",
    url: "https://discord.gg/V9P3UDjkFu",
  ),
  (
    channel: SupportChannel.x,
    text: "@kerrigannetwork",
    url: "https://x.com/kerrigannetwork",
  ),
];

const Set<AppFeature> _features = {
  AppFeature.tor,
  AppFeature.darkTheme,
};

const ({String light, String dark})? _appIconAsset = (
  light: "assets/in_app_logo_icons/trekpay-icon_light.svg",
  dark: "assets/in_app_logo_icons/trekpay-icon_dark.svg",
);

// Release builds are single-coin (mainnet). Debug builds, and test
// builds made with --dart-define=KERRIGAN_TESTNET=true, add Kerrigan
// testnet and regtest.
const _kerriganTestnet = bool.fromEnvironment("KERRIGAN_TESTNET");

final List<CryptoCurrency> _supportedCoins = List.unmodifiable([
  Kerrigan(CryptoCurrencyNetwork.main),
  if (kDebugMode || _kerriganTestnet) Kerrigan(CryptoCurrencyNetwork.test),
  if (kDebugMode || _kerriganTestnet) Kerrigan(CryptoCurrencyNetwork.regtest),
]);

EOF