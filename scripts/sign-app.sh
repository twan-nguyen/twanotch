#!/usr/bin/env bash
# Re-signs a built TwaNotch.app with a code signing identity, inside out, keeping each item's
# entitlements. A stable identity keeps the app's designated requirement unchanged between
# builds, so macOS keeps privacy permissions such as Accessibility across updates.
# Usage: scripts/sign-app.sh <path/to/TwaNotch.app> <identity name> [unlocked keychain]
set -euo pipefail

APP="${1:?usage: sign-app.sh <app> <identity> [keychain]}"
IDENTITY="${2:?usage: sign-app.sh <app> <identity> [keychain]}"
KEYCHAIN="${3:-}"

if [[ -n "$KEYCHAIN" ]]; then
  # codesign only finds identities in keychains on the search list, so add this one for the
  # duration of the script and put the original list back afterwards.
  original_keychains="$(security list-keychains -d user | tr -d '"')"
  restore_keychains() {
    # shellcheck disable=SC2086
    security list-keychains -d user -s $original_keychains
  }
  trap restore_keychains EXIT
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $original_keychains
fi

sign() {
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --preserve-metadata=entitlements "$1"
}

is_macho() {
  [[ "$(file -b "$1")" == Mach-O* ]]
}

# Loose Mach-O files first (helper tools such as Sparkle's Autoupdate), deepest path first.
while IFS= read -r file; do
  is_macho "$file" && sign "$file"
done < <(find "$APP/Contents" -type f -perm +111 | awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-)

# Then nested bundles; -depth lists children before their parents.
while IFS= read -r bundle; do
  sign "$bundle"
done < <(find "$APP/Contents" -depth -type d \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.appex" \))

sign "$APP"

codesign --verify --deep --strict "$APP"

# Every Mach-O inside must now carry the identity, not an ad-hoc signature.
while IFS= read -r file; do
  if is_macho "$file" && codesign -dv "$file" 2>&1 | grep -q "Signature=adhoc"; then
    echo "error: $file is still ad-hoc signed" >&2
    exit 1
  fi
done < <(find "$APP/Contents" -type f -perm +111)

codesign -d -r- "$APP" 2>&1 | grep designated
