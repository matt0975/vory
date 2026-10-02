#!/bin/bash
# Makes the demo copy of the iPhone app from a Debug simulator build and installs it on a booted
# simulator: the same binary under its own bundle id, ad-hoc signed, with no extensions. Like the
# Mac's demo copy (make-demo-app.sh) it keeps its own settings, holds credentials in memory and
# uses a dictionary for iCloud (see Vory/App/DemoMode.swift), so it can be pointed at the mock
# gateway and recorded. It has no Live Activity or widgets: those are the extensions.
#
#   Tools/dev/make-demo-app-sim.sh <path to Debug-iphonesimulator Vory.app> <simulator udid>
#
# Then, with the mock running (Tools/mock-gateway/mock_gateway.py --port 9119 --token mock-token):
#   xcrun simctl launch <udid> com.vorantx.vory.demo -vory-demo-gateway http://127.0.0.1:9119 mock-token Workshop
# or, to start from the first screen with an iCloud backup to restore:
#   xcrun simctl launch <udid> com.vorantx.vory.demo -vory-demo-cloud http://127.0.0.1:9119 mock-token Workshop
# Add -companionPromptShown YES to keep the Companion prompt out of a recording. Running this
# again starts the copy over (it is uninstalled first).
set -euo pipefail
SRC="${1:?path to the Debug simulator Vory.app}"
SIM="${2:?simulator udid}"
DEMO_ID="com.vorantx.vory.demo"

[ -d "$SRC" ] || { echo "no app at $SRC" >&2; exit 1; }
if ! LC_ALL=C grep -q -a -- "-vory-demo-gateway" "$SRC/Vory"; then
  echo "that build has no demo mode in it (it must be a Debug build)" >&2; exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$SRC" "$WORK/Vory.app"
APP="$WORK/Vory.app"
# No extensions and no watch app: they belong to the real bundle id.
rm -rf "$APP/PlugIns" "$APP/Watch" "$APP/_CodeSignature"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_ID" "$APP/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
xcrun simctl terminate "$SIM" "$DEMO_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM" "$DEMO_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$APP"
echo "$DEMO_ID installed on $SIM"
