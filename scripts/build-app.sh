#!/bin/zsh
# Builds "build/Munbyn Easy Print.app". Pass --install to copy it to
# /Applications and launch it (launch-at-login needs a stable location).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Munbyn Easy Print.app"
swift build -c release

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MunbynEasyPrint" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# A real identity keeps the code signature stable across rebuilds, so macOS
# remembers the Bluetooth permission. Override with SIGN_IDENTITY=-.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$APP"
echo "Signed with ${IDENTITY:-ad-hoc identity}"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Munbyn Easy Print"' 2>/dev/null || true
  pkill -x MunbynEasyPrint 2>/dev/null || true
  rm -rf "/Applications/Munbyn Easy Print.app"
  cp -R "$APP" /Applications/
  open "/Applications/Munbyn Easy Print.app"
  echo "Installed to /Applications and launched"
fi
