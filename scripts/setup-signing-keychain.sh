#!/usr/bin/env bash
# One-time setup: puts the Twanotch signing identity in its own keychain so codesign can use it
# without keychain prompts. The keychain password is random and kept in the login keychain,
# where scripts/install.sh reads it.
# Usage: scripts/setup-signing-keychain.sh <identity.p12>
#        (reads the .p12 password from TWANOTCH_P12_PASSWORD, or asks for it)
set -euo pipefail

P12="${1:?usage: setup-signing-keychain.sh <identity.p12>}"
KEYCHAIN="$HOME/Library/Keychains/twanotch-signing.keychain-db"
PASSWORD_SERVICE="twanotch-signing-keychain"

if [[ -e "$KEYCHAIN" ]]; then
  echo "error: $KEYCHAIN already exists; delete it first to recreate it" >&2
  exit 1
fi

p12_password="${TWANOTCH_P12_PASSWORD:-}"
if [[ -z "$p12_password" ]]; then
  read -r -s -p "Password for $P12: " p12_password
  echo
fi

keychain_password="$(openssl rand -hex 24)"
security add-generic-password -U -s "$PASSWORD_SERVICE" -a "$USER" -w "$keychain_password" \
  -T /usr/bin/security "$HOME/Library/Keychains/login.keychain-db"

security create-keychain -p "$keychain_password" "$KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$p12_password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$KEYCHAIN" >/dev/null
security lock-keychain "$KEYCHAIN"

echo "Created $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN" | grep '"' || true
