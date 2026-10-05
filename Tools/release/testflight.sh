#!/usr/bin/env bash
# Archive Vory and upload it to TestFlight, non-interactively.
#
# Needs an App Store Connect API key, so no Apple ID password or 2FA prompt is involved.
# Configure it once by exporting these (or putting them in Tools/release/.env, which is gitignored):
#
#   ASC_KEY_ID=ABCD123456                 # the API key's Key ID
#   ASC_ISSUER_ID=aaaaaaaa-bbbb-....      # the Issuer ID from the Keys page
#   ASC_KEY_PATH=$HOME/.appstoreconnect/private_keys/AuthKey_ABCD123456.p8
#   VORY_PUSH_RELAY_URL=https://vory-push-relay.example.workers.dev   # optional: the push relay you deployed
#
# One-time setup that must happen in a browser first, because Apple allows no other route:
#   1. Accept any pending agreements in App Store Connect.
#   2. Create the app record for the bundle id below, named "Vory: Hermes Agent UI".
# After that this script can run unattended for every subsequent build.
#
# The Mac app goes to TestFlight for Mac from the same script and the same app record:
#
#   PLATFORM=macos Tools/release/testflight.sh
#
# It archives the VoryMac scheme, exports a .pkg and uploads it with --type macos. Once, first:
# add the macOS platform to the app record, and have Mac App Store profiles with the names in
# ExportOptions-macOS.plist plus a Mac installer certificate in the keychain.
#
# DRY_RUN=1 (either platform) stops after the export and the push check: nothing is uploaded.

set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
[ -f Tools/release/.env ] && . Tools/release/.env

PROJECT="Vory.xcodeproj"
BUNDLE_ID="com.vorantx.vory"
PLATFORM="${PLATFORM:-ios}"
case "$PLATFORM" in
    ios)   SCHEME="Vory";    DESTINATION='generic/platform=iOS';   EXPORT_OPTIONS="Tools/release/ExportOptions.plist";       ARCHIVE_PREFIX="Vory" ;;
    macos) SCHEME="VoryMac"; DESTINATION='generic/platform=macOS'; EXPORT_OPTIONS="Tools/release/ExportOptions-macOS.plist"; ARCHIVE_PREFIX="Vory-mac" ;;
    *) printf 'PLATFORM must be ios or macos, not %s\n' "$PLATFORM" >&2; exit 1 ;;
esac
ARCHIVE_DIR="${ARCHIVE_DIR:-$ROOT/build/archives}"

fail() { printf '\n%s\n' "$1" >&2; exit 1; }

for var in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    [ -n "${!var:-}" ] || fail "$var is not set. See the header of this script."
done
[ -f "$ASC_KEY_PATH" ] || fail "API key not found at $ASC_KEY_PATH"

# Info.plist holds the $(MARKETING_VERSION) macro, so read the real value from the project.
MARKETING_VERSION="${MARKETING_VERSION:-$(grep -m1 'MARKETING_VERSION = ' "$PROJECT/project.pbxproj" | sed 's/.*= *//; s/;//')}"

# The build number is the iteration count: one more than the highest small build number App Store
# Connect already holds for this app (App Store Connect refuses a number it has already seen). The
# first ten builds used date-style numbers (up to 2609240140); those are ignored. The marketing
# version is 1.0.1 for the beta (1.0 was the date-numbered builds), then 1.2, 1.3, … and 2.0 for the
# App Store. Override with BUILD_NUMBER=.
next_build_number() {
    local token
    token="$(ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$ASC_KEY_PATH" swift Tools/release/asc-jwt.swift)" || return 1
    curl -sS --fail -H "Authorization: Bearer $token" \
        "https://api.appstoreconnect.apple.com/v1/builds?filter%5Bapp%5D=$ASC_APP_ID&limit=200&fields%5Bbuilds%5D=version" \
    | python3 -c '
import json, sys
versions = [b["attributes"]["version"] for b in json.load(sys.stdin)["data"]]
small = [int(v) for v in versions if v.isdigit() and int(v) < 100000]
print(max(small) + 1 if small else len(versions) + 1)'
}
ASC_APP_ID="${ASC_APP_ID:-6814980297}"
if [ -z "${BUILD_NUMBER:-}" ]; then
    BUILD_NUMBER="$(next_build_number)" || fail "Could not read the existing builds from App Store Connect to pick the next build number. Pass BUILD_NUMBER=<n> to override."
fi

ARCHIVE="$ARCHIVE_DIR/$ARCHIVE_PREFIX-$BUILD_NUMBER.xcarchive"
mkdir -p "$ARCHIVE_DIR"

AUTH=(-authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "==> Archiving $BUNDLE_ID $MARKETING_VERSION ($BUILD_NUMBER) for $PLATFORM"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "$DESTINATION" \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    "${AUTH[@]}" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    VORY_PUSH_RELAY_URL="${VORY_PUSH_RELAY_URL:-}" \
    2>&1 | tee "$ARCHIVE_DIR/archive-$ARCHIVE_PREFIX-$BUILD_NUMBER.log" | grep -E 'error:|warning: .*(signing|provision)|ARCHIVE' || true

[ -d "$ARCHIVE" ] || fail "Archive was not produced. Re-run without the grep filter to see why."

# A delegate method that only "nearly matches" its protocol's requirement is never called (a
# card's links once loaded their page inside the chat for exactly that): no build ships with one.
if grep -q "nearly matches optional requirement" "$ARCHIVE_DIR/archive-$ARCHIVE_PREFIX-$BUILD_NUMBER.log"; then
    grep "nearly matches optional requirement" "$ARCHIVE_DIR/archive-$ARCHIVE_PREFIX-$BUILD_NUMBER.log" | sort -u >&2
    fail "A delegate method does not match its protocol (above), so the system never calls it. Fix it before shipping."
fi

echo "==> Exporting with manual distribution signing"
EXPORT_DIR="$ARCHIVE_DIR/export-$ARCHIVE_PREFIX-$BUILD_NUMBER"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_DIR" \
    "${AUTH[@]}"

# Guard the one thing that silently breaks background push: a build signed for the sandbox
# APNs environment will never receive notifications sent to the production host.
# PlistBuddy cannot read a pipe ("Error Reading File: /dev/stdin"), so go through real files.
GUARD_TMP="$(mktemp -d)"
if [ "$PLATFORM" = macos ]; then
    PRODUCT="$(ls "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1)"
    [ -n "$PRODUCT" ] || fail "No .pkg was produced in $EXPORT_DIR"
    # The profile sits beside Info.plist inside the app in the installer's payload.
    pkgutil --expand-full "$PRODUCT" "$GUARD_TMP/pkg" >/dev/null 2>&1 || true
    PROFILE="$(find "$GUARD_TMP/pkg" -path '*Vory.app/Contents/embedded.provisionprofile' 2>/dev/null | head -1)"
    [ -n "$PROFILE" ] && cp "$PROFILE" "$GUARD_TMP/prov.cms"
    APS_KEY='com.apple.developer.aps-environment'
    UPLOAD_TYPE=macos
else
    PRODUCT="$(ls "$EXPORT_DIR"/*.ipa 2>/dev/null | head -1)"
    [ -n "$PRODUCT" ] || fail "No .ipa was produced in $EXPORT_DIR"
    unzip -p "$PRODUCT" 'Payload/*.app/embedded.mobileprovision' > "$GUARD_TMP/prov.cms" 2>/dev/null || true
    APS_KEY='aps-environment'
    UPLOAD_TYPE=ios
fi
security cms -D -i "$GUARD_TMP/prov.cms" -o "$GUARD_TMP/prov.plist" 2>/dev/null || true
APS="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$APS_KEY" "$GUARD_TMP/prov.plist" 2>/dev/null || true)"
rm -rf "$GUARD_TMP"
[ "$APS" = "production" ] || fail "Expected $APS_KEY=production in the signed build, got '${APS:-absent}'."
echo "    signed with $APS_KEY=production"

if [ -n "${DRY_RUN:-}" ]; then
    printf '\nDry run: %s is built, signed for production push, and NOT uploaded.\n' "$PRODUCT"
    exit 0
fi

echo "==> Uploading to TestFlight"
xcrun altool --upload-app --type "$UPLOAD_TYPE" --file "$PRODUCT" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

# Keep the App Store listing in step: attach this build to the version (created if needed) and
# refresh its screenshots from Tools/release/screenshots. Skipped with SKIP_LISTING=1.
# The listing script knows the iOS version only; the Mac version's listing is kept by hand for now.
if [ -z "${SKIP_LISTING:-}" ] && [ "$PLATFORM" = ios ]; then
    echo "==> Updating the App Store listing (build + screenshots)"
    python3 Tools/release/asc-listing.py attach "$MARKETING_VERSION" "$BUILD_NUMBER" \
        && python3 Tools/release/asc-listing.py screenshots \
        || echo "(listing update failed; run Tools/release/asc-listing.py by hand)"
fi

cat <<EOS

Uploaded build $BUILD_NUMBER of version $MARKETING_VERSION.

Apple now processes it, which usually takes a few minutes. Internal testers get it automatically
once processing finishes; no review is involved. Export compliance is already answered in
Info.plist, so nothing should be waiting on you.
EOS
