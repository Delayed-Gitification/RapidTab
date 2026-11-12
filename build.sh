#!/bin/bash
# Builds build/RapidTab.app and installs it to ~/Applications.
#
# Signing: uses the "RapidTab Local Signing" identity if present (create it once with
# scripts/make-signing-cert.sh) so macOS permissions survive rebuilds. Override with SIGN_ID.
# Falls back to ad-hoc signing, which means re-granting permissions after every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/RapidTab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -target arm64-apple-macos14.0 \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/RapidTab" \
  -framework AppKit -framework ScreenCaptureKit -framework ServiceManagement

DEFAULT_ID="RapidTab Local Signing"
if [ -z "${SIGN_ID:-}" ]; then
  if security find-identity -p codesigning | grep -q "\"$DEFAULT_ID\""; then
    SIGN_ID="$DEFAULT_ID"
  else
    SIGN_ID="-"
    echo "warning: no \"$DEFAULT_ID\" identity; ad-hoc signing (run scripts/make-signing-cert.sh)"
  fi
fi
codesign --force --sign "$SIGN_ID" --identifier local.rapidtab "$APP"
echo "Built $APP (signed with: $SIGN_ID)"

if [ "${NO_INSTALL:-}" != "1" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x RapidTab 2>/dev/null || true
  rm -rf "$HOME/Applications/RapidTab.app"
  cp -R "$APP" "$HOME/Applications/RapidTab.app"
  echo "Installed to ~/Applications/RapidTab.app"
fi
