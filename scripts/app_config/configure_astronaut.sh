#!/usr/bin/env bash

set -x -e

# Configure files for Astronaut.
APP_BUILD_PLATFORM=$1

export NEW_NAME="Astronaut"
export NEW_APP_ID="org.kerrigan.astronaut"
export NEW_APP_ID_CAMEL="org.kerrigan.astronaut"
export NEW_APP_ID_SNAKE="org.kerrigan.astronaut"
# Linux: Flatpak IDs need three parts, and on Wayland a window finds its
# icon through a .desktop file named after its ID, so every Linux package
# (tarball, AppImage, Flatpak) uses this one.
export NEW_LINUX_APP_ID="org.kerrigan.astronaut"
export NEW_BASIC_NAME="astronaut"

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

const _prefix = "Astronaut";
const _separator = "";
const _suffix = "";
const _emptyWalletsMessage =
    "Create your first Kerrigan wallet";
const _appDataDirName = "astronaut";
const _shortDescriptionText = "Your privacy. Your keys. Your KRGN.";
const _commitHash = "$BUILT_COMMIT_HASH";

// Project links. Empty ones are not shown in the app.
const _websiteUrl = "https://kerrigan.network";
const _termsUrl = "";
const _privacyUrl = "";

// Support: the official Kerrigan community channels (see kerrigan.network).
const List<SupportLink> _supportLinks = [
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
  light: "assets/in_app_logo_icons/pivxie-icon_light.svg",
  dark: "assets/in_app_logo_icons/pivxie-icon_dark.svg",
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