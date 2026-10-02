#!/bin/bash
# Makes the demo copy of the Mac app from a Debug build: the same binary under its own bundle
# id, ad-hoc signed, with no extensions. It keeps its own settings, holds credentials in memory
# and uses a dictionary for iCloud (see Vory/App/DemoMode.swift), so it can be pointed at the
# mock gateway and recorded without the real app's gateways or chats ever being in it.
#
#   Tools/dev/make-demo-app.sh <path to Debug Vory.app> <output folder>
#
# Then, with the mock running (Tools/mock-gateway/mock_gateway.py --port 9119 --token mock-token):
#   <output folder>/Vory.app/Contents/MacOS/Vory -vory-demo-gateway http://127.0.0.1:9119 mock-token Workshop
# or, to start from the first screen with an iCloud backup to restore:
#   <output folder>/Vory.app/Contents/MacOS/Vory -vory-demo-cloud http://127.0.0.1:9119 mock-token Workshop
# Its settings are in the defaults domain com.vorantx.vory.demo (defaults delete … starts over).
set -euo pipefail
SRC="${1:?path to the Debug Vory.app}"
OUT="${2:?output folder}"
DEMO_ID="com.vorantx.vory.demo"

[ -d "$SRC" ] || { echo "no app at $SRC" >&2; exit 1; }
if ! LC_ALL=C grep -q -r -a -- "-vory-demo-gateway" "$SRC/Contents/MacOS"; then
  echo "that build has no demo mode in it (it must be a Debug build)" >&2; exit 1
fi
mkdir -p "$OUT"
rm -rf "$OUT/Vory.app"
cp -R "$SRC" "$OUT/Vory.app"
APP="$OUT/Vory.app"
# No extensions (they belong to the real bundle id) and no provisioning profile.
rm -rf "$APP/Contents/PlugIns" "$APP/Contents/embedded.provisionprofile" "$APP/Contents/_CodeSignature"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_ID" "$APP/Contents/Info.plist"
# Ad hoc, with no entitlements: no sandbox, no Keychain group, no iCloud, no push.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --deep "$APP"
echo "$APP ($DEMO_ID)"
