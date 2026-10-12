#!/usr/bin/env bash
# Builds Twanotch in Release, replaces /Applications/TwaNotch.app and relaunches it.
# Usage: scripts/install.sh
set -euo pipefail

APP_NAME="TwaNotch"  # bundle file and process name; the display name is Twanotch
BUNDLE_ID="com.twan.twanotch"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$REPO_ROOT/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
SIGN_IDENTITY="TwaNotch Self-Signed"
SIGN_KEYCHAIN="$HOME/Library/Keychains/twanotch-signing.keychain-db"

echo "==> Building $APP_NAME (Release)"
xcodebuild \
  -project "$REPO_ROOT/boringNotch.xcodeproj" \
  -scheme boringNotch \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: $BUILT_APP was not produced" >&2
  exit 1
fi

# Release builds are signed with this self-signed identity; signing local builds with it too
# keeps the same app identity, so macOS keeps Accessibility permission between installs.
# The identity lives in its own keychain (see scripts/setup-signing-keychain.sh).
if [[ -f "$SIGN_KEYCHAIN" ]] \
  && keychain_password="$(security find-generic-password -s twanotch-signing-keychain -a "$USER" -w 2>/dev/null)"; then
  echo "==> Signing with \"$SIGN_IDENTITY\""
  security unlock-keychain -p "$keychain_password" "$SIGN_KEYCHAIN"
  "$REPO_ROOT/scripts/sign-app.sh" "$BUILT_APP" "$SIGN_IDENTITY" "$SIGN_KEYCHAIN"
  security lock-keychain "$SIGN_KEYCHAIN"
else
  echo "warning: signing keychain not set up; installing the ad-hoc signed build" >&2
fi

if pgrep -x "$APP_NAME" >/dev/null; then
  echo "==> Quitting the running $APP_NAME"
  osascript -e "quit app id \"$BUNDLE_ID\"" || true
  for _ in {1..20}; do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.5
  done
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "error: $APP_NAME is still running; quit it and run the script again" >&2
    exit 1
  fi
fi

echo "==> Installing to $INSTALLED_APP"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "==> Launching $APP_NAME"
open "$INSTALLED_APP"

version="$(defaults read "$INSTALLED_APP/Contents/Info.plist" CFBundleShortVersionString)"
build_number="$(defaults read "$INSTALLED_APP/Contents/Info.plist" CFBundleVersion)"
echo "Installed $APP_NAME $version ($build_number)"
codesign -dv "$INSTALLED_APP" 2>&1 | grep -q "Signature=adhoc" \
  && echo "Ad-hoc signed: grant Accessibility again in System Settings if the HUD replacement stops working."
exit 0
