#!/usr/bin/env bash
# Build, sign, notarise and verify Hangar-<version>.dmg for download outside the App Store, and optionally attach it to
# the GitHub release for the tag. One-off setup and the per-release steps are in docs/releasing.md.
#
#   scripts/release.sh                       build, sign, notarise, staple and verify build/release/Hangar-<v>.dmg
#   scripts/release.sh --publish [--draft]   then attach the DMG and its checksums to the GitHub release for tag v<v>
#   scripts/release.sh --skip-notarise       check signing and packaging locally; the DMG is NOT for distribution
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0; DRAFT=0; NOTARISE=1
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --draft) DRAFT=1 ;;
    --skip-notarise|--skip-notarize) NOTARISE=0 ;;
    *) echo "usage: scripts/release.sh [--publish [--draft]] [--skip-notarise]" >&2; exit 2 ;;
  esac
done
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
[ "$DRAFT" = 1 ] && [ "$PUBLISH" = 0 ] && fail "--draft only makes sense with --publish"
[ "$PUBLISH" = 1 ] && [ "$NOTARISE" = 0 ] && fail "--publish needs a notarised DMG; drop --skip-notarise"

WORK=$(mktemp -d)
MNT="$WORK/mnt"
cleanup() { hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# 1. Prerequisites ------------------------------------------------------------------------------------------------
TEAM="${HANGAR_TEAM:-}"
if [ -z "$TEAM" ] && [ -f Local.xcconfig ]; then
  TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Local.xcconfig | head -1)
fi
[ -n "$TEAM" ] || fail "no signing team: set HANGAR_TEAM or DEVELOPMENT_TEAM in Local.xcconfig"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*('"$TEAM"')\)".*/\1/p' | head -1)
[ -n "$IDENTITY" ] || fail "no 'Developer ID Application' identity for team $TEAM in the keychain (docs/releasing.md, step 1)"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\).*/\1/p' project.yml | head -1)
BUNDLE_ID=$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *\([A-Za-z0-9.-]*\).*/\1/p' project.yml | head -1)
[ -n "$VERSION" ] && [ -n "$BUNDLE_ID" ] || fail "could not read MARKETING_VERSION and PRODUCT_BUNDLE_IDENTIFIER from project.yml"

# The notarisation login belongs to the Apple ID and team, not the app, so a login made for another app works too.
NOTARY_PROFILE=""
if [ "$NOTARISE" = 1 ]; then
  for p in "${HANGAR_NOTARY_PROFILE:-}" hangar-notary nightwatch-notary; do
    [ -n "$p" ] || continue
    if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then NOTARY_PROFILE="$p"; break; fi
  done
  [ -n "$NOTARY_PROFILE" ] || fail "no working notarytool login (tried hangar-notary, nightwatch-notary). Create one: docs/releasing.md, step 3"
fi

if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null || fail "--publish needs the GitHub CLI (gh)"
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "tag v$VERSION does not exist: tag the release first (docs/releasing.md)"
  # A published download must be built from exactly the tagged commit, with nothing uncommitted.
  [ "$(git rev-parse "v$VERSION^{commit}")" = "$(git rev-parse HEAD)" ] || fail "check out v$VERSION before publishing"
  [ -z "$(git status --porcelain)" ] || fail "uncommitted changes: commit or stash them before publishing"
  # The notes come from this version's section of docs/CHANGELOG.md: no section, no release.
  # The release title is "Hangar <v>", plus the tag annotation's first line when it is a name (e.g. "Don't Panic").
  NAME=$(git tag -l --format='%(contents:subject)' "v$VERSION")
  case "$NAME" in ""|Hangar*) TITLE="Hangar $VERSION" ;; *) TITLE="Hangar $VERSION: $NAME" ;; esac
  scripts/release-notes.sh "$VERSION" > "$WORK/notes.md" || fail "add a '## $VERSION' section to docs/CHANGELOG.md first"
fi

OUT="build/release"
APP="$OUT/Build/Products/Release/Hangar.app"
DMG="$OUT/Hangar-$VERSION.dmg"
LATEST="$OUT/Hangar.dmg"      # same file without the version, for releases/latest/download/Hangar.dmg

# 2. Build and sign the app ---------------------------------------------------------------------------------------
step "Clean Release build, signed with Developer ID and hardened runtime"
rm -rf "$OUT/Build" "$DMG" "$DMG.sha256" "$LATEST" "$LATEST.sha256"
mkdir -p "$OUT"
xcodegen generate -q
xcodebuild -project Hangar.xcodeproj -scheme Hangar -configuration Release -derivedDataPath "$OUT" -jobs 4 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build >/dev/null     # NO: Xcode otherwise adds get-task-allow, which Apple rejects

check_app() {   # $1 = path to an app; prints nothing, fails with a reason
  codesign --verify --deep --strict "$1" || fail "signature check failed for $1"
  local info; info=$(codesign -d --verbose=4 "$1" 2>&1)    # captured first: grep -q on a pipe would trip pipefail
  case "$info" in *"(runtime)"*) ;; *) fail "hardened runtime is not enabled" ;; esac
  case "$info" in *"Authority=Developer ID Application"*) ;; *) fail "not signed with a Developer ID" ;; esac
  local ent; ent=$(codesign -d --entitlements - "$1" 2>&1)
  case "$ent" in *get-task-allow*) fail "the app carries the debugging entitlement get-task-allow, which Apple rejects" ;; esac
}
step "Verify the app signature and identity"
check_app "$APP"
BUILT_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[ "$BUILT_ID" = "$BUNDLE_ID" ] || fail "the built app's bundle ID is '$BUILT_ID' but project.yml says '$BUNDLE_ID' (check Local.xcconfig)"

# 3. The disk image: the app beside an Applications shortcut, signed too ---------------------------------------------
step "Package $DMG"
STAGE="$WORK/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Hangar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Hangar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "$NOTARISE" = 0 ]; then
  step "Skipped notarisation (--skip-notarise)"
  echo "Built $DMG, signed as a Developer ID but NOT notarised: for checking locally only, not for distribution."
  exit 0
fi

# 4. Notarise the DMG (Apple usually answers in a few minutes), staple, and check it as Gatekeeper will --------------
step "Submit for notarisation with the '$NOTARY_PROFILE' login (waits for Apple)"
# A rejection still exits 0, so read the status from the JSON; a network failure is caught by the same check.
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$WORK/notary.json" || true
STATUS=$(plutil -extract status raw "$WORK/notary.json" 2>/dev/null || true)
if [ "$STATUS" != "Accepted" ]; then
  ID=$(plutil -extract id raw "$WORK/notary.json" 2>/dev/null || true)
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" || true
  fail "notarisation was not accepted (status: ${STATUS:-unknown}); Apple's log is above"
fi
xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

step "Open the DMG read-only and check the app inside"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -noverify -mountpoint "$MNT" "$DMG"
check_app "$MNT/Hangar.app"
# The ticket is stapled to the DMG, not to the app inside it; Gatekeeper finds the app's ticket from the same notarisation
# (online, or from the DMG when it is copied out), so this checks acceptance, not a stapled ticket on the app.
spctl --assess --type execute --verbose=2 "$MNT/Hangar.app"
hdiutil detach -quiet "$MNT"

cp "$DMG" "$LATEST"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" && shasum -a 256 "$(basename "$LATEST")" > "$(basename "$LATEST").sha256")
step "Ready: $DMG (notarised and stapled)"
echo "SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"

# 5. Optional: attach to the GitHub release for the tag --------------------------------------------------------------
if [ "$PUBLISH" = 1 ]; then
  step "Attach to the GitHub release for v$VERSION"
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release edit "v$VERSION" --notes-file "$WORK/notes.md" >/dev/null
  else
    gh release create "v$VERSION" --verify-tag --title "$TITLE" --notes-file "$WORK/notes.md" $([ "$DRAFT" = 1 ] && echo --draft) >/dev/null
  fi
  gh release upload "v$VERSION" "$DMG" "$DMG.sha256" "$LATEST" "$LATEST.sha256" --clobber
  echo "Attached to the v$VERSION release$([ "$DRAFT" = 1 ] && echo ' (draft: review and publish it on GitHub)')."
fi
