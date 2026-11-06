#!/bin/zsh
# Builds Zide.app (release) next to this script. Usage: ./build.sh [--run]
set -e
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Zide"

# Assemble and sign outside the (iCloud-synced) Desktop, which adds Finder metadata that breaks codesign.
STAGE="$(mktemp -d)"
APP="$STAGE/Zide.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Zide"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sign_app() {
  # A stable identity keeps macOS privacy permissions across rebuilds (ad-hoc signatures change every build).
  local kc="$PWD/.signing/zide.keychain-db"
  [[ -f "$kc" ]] || ./.signing/make-identity.sh >/dev/null || return 1
  security unlock-keychain -p zide "$kc" || return 1
  local orig=(${(f)"$(security list-keychains -d user | tr -d ' "')"})
  security list-keychains -d user -s "${orig[@]}" "$kc"
  codesign --force --deep --sign "Zide Local Signing" "$APP"
  local rc=$?
  security list-keychains -d user -s "${orig[@]}"
  return $rc
}
sign_app || { echo "warning: stable signing failed, falling back to ad-hoc (permissions reset each build)"; codesign --force --deep --sign - "$APP"; }

rm -rf Zide.app
ditto "$APP" Zide.app
rm -rf "$STAGE"
echo "Built $(pwd)/Zide.app"

if [[ "$1" == "--run" ]]; then
  pkill -x Zide 2>/dev/null || true
  while pgrep -x Zide >/dev/null; do sleep 0.1; done
  open Zide.app
fi
