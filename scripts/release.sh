#!/usr/bin/env bash
# Build, sign, notarise and verify a Hangar release DMG. Nothing is published.
#
#   scripts/release.sh                 full run (needs the notarytool profile, see README "Releasing")
#   scripts/release.sh --skip-notarise build, sign and package only, then check the signature
#
# The signing team comes from HANGAR_TEAM or, failing that, DEVELOPMENT_TEAM in the git-ignored Local.xcconfig.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${HANGAR_NOTARY_PROFILE:-hangar-notary}"
SKIP_NOTARISE=0
[ "${1:-}" = "--skip-notarise" ] && SKIP_NOTARISE=1

step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

TEAM="${HANGAR_TEAM:-}"
if [ -z "$TEAM" ] && [ -f Local.xcconfig ]; then
  TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Local.xcconfig | head -1)
fi
[ -n "$TEAM" ] || die "no signing team: set HANGAR_TEAM or DEVELOPMENT_TEAM in Local.xcconfig"

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*('"$TEAM"')\)".*/\1/p' | head -1)
[ -n "$IDENTITY" ] || die "no 'Developer ID Application' identity for team $TEAM in the keychain"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\).*/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from project.yml"

if [ "$SKIP_NOTARISE" = 0 ]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile '$PROFILE' not found. Create it once with: xcrun notarytool store-credentials $PROFILE (see README)"
fi

OUT="build/release"
APP="$OUT/Build/Products/Release/Hangar.app"
DMG="build/Hangar-$VERSION.dmg"

step "Clean Release build, signed with Developer ID and hardened runtime"
rm -rf "$OUT" "$DMG"
xcodegen generate -q
xcodebuild -project Hangar.xcodeproj -scheme Hangar -configuration Release -derivedDataPath "$OUT" -jobs 4 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build >/dev/null

step "Verify the app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
INFO=$(codesign -d --verbose=4 "$APP" 2>&1)         # captured first: grep -q on a pipe would trip pipefail
case "$INFO" in *"(runtime)"*) ;; *) die "hardened runtime is not enabled" ;; esac
case "$INFO" in *"Authority=Developer ID Application"*) ;; *) die "not signed with a Developer ID" ;; esac

step "Package $DMG"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Hangar" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARISE" = 1 ]; then
  step "Skipped notarisation (--skip-notarise). The DMG is signed but NOT notarised: Gatekeeper will warn on other Macs."
else
  step "Submit for notarisation (waits for Apple)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  step "Staple and verify"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

step "Done"
shasum -a 256 "$DMG"
