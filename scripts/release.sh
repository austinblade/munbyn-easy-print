#!/bin/zsh
# Builds a Developer ID–signed, notarized "Munbyn Easy Print.app", zips it,
# and publishes it as a GitHub release tagged v<CFBundleShortVersionString>.
#
# One-time setup (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials munbyn-notary \
#     --apple-id you@example.com --team-id <TEAMID>
#
# Usage: ./scripts/release.sh [--draft]
# Env:   NOTARY_PROFILE (default munbyn-notary)
#        SIGN_IDENTITY  (default: first "Developer ID Application" identity)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-munbyn-notary}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate found" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
APP="build/Munbyn Easy Print.app"
ZIP="build/MunbynEasyPrint-$VERSION.zip"

[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists; bump CFBundleShortVersionString in Resources/Info.plist" >&2
  exit 1
fi

swift test
SIGN_IDENTITY="$IDENTITY" ./scripts/build-app.sh

# Notarization needs the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Re-zip so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

NOTES="$(cat <<EOF
## Install

1. Download **$(basename "$ZIP")** below and unzip it.
2. Drag **Munbyn Easy Print** into your **Applications** folder.
3. Open it and follow the [setup steps](https://github.com/austinblade/munbyn-easy-print#setup).

Requires macOS 14 Sonoma or later. Signed with a Developer ID and notarized by Apple.

SHA-256: \`$SHA\`
EOF
)"

git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Munbyn Easy Print $VERSION" --notes "$NOTES" ${1:+"$1"}
echo "Published $TAG"
