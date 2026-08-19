#!/bin/bash
# Build the "drag to Applications" DMG with background and icon positions.
# Recipe: https://habr.com/ru/articles/152677/
#  1) RW image  2) copy background  3) AppleScript via Finder (tell disk, background
#     via file ".background:img", Applications alias, positions, close/open, update, delay)
#  4) chmod go-w, sync, detach  5) convert to UDZO zlib9.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f "$HOME/.swiftly/env.sh" ]; then
    . "$HOME/.swiftly/env.sh"
fi

./build.sh

APP_SRC="build/AliSwitcher.app"
[ -d "$APP_SRC" ] || APP_SRC="build/app/AliSwitcher.app"

VOL_NAME="AliSwitcher"
BG_IMG="background.png"
APP_BUNDLE_NAME="AliSwitcher.app"
# Window 700x440; icons 128pt, left and right, vertically centered (y=186)
WINDOW_LEFT=120; WINDOW_TOP=120; WINDOW_RIGHT=820; WINDOW_BOTTOM=560
BUNDLE_X=170; BUNDLE_Y=186
APPS_X=500; APPS_Y=186

WORK=$(mktemp -d /tmp/aliswitcher-dmg.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dmg/.background"

# --- image contents ---
cp -R "$APP_SRC" "$WORK/dmg/$APP_BUNDLE_NAME"
# Helper script: double-click → copies to Applications, removes quarantine,
# allows Gatekeeper, launches (for installs on other machines).
cp double-click-to-install.command "$WORK/dmg/double-click-to-install.command"
chmod +x "$WORK/dmg/double-click-to-install.command"
if [ -f "Sources/background/$BG_IMG" ]; then
    cp "Sources/background/$BG_IMG" "$WORK/dmg/.background/$BG_IMG"
else
    echo "⚠  No Sources/background/$BG_IMG — DMG will have no background"
fi

# --- RW image and mount (-noautoopen! the window is opened by AppleScript) ---
DMG_NAME_TMP="$WORK/$VOL_NAME-tmp.dmg"
hdiutil create -ov -srcfolder "$WORK/dmg" -format UDRW -volname "$VOL_NAME" "$DMG_NAME_TMP" >/dev/null
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_NAME_TMP" | egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 1

# --- customization via Finder ---
APPLESCRIPT=$(cat <<EOF
tell application "Finder"
	with timeout of 120 seconds
	tell disk "$VOL_NAME"
		open
		-- setting view options
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {$WINDOW_LEFT, $WINDOW_TOP, $WINDOW_RIGHT, $WINDOW_BOTTOM}
		set theViewOptions to the icon view options of container window
		set arrangement of theViewOptions to not arranged
		set icon size of theViewOptions to 128
		-- setting background picture
		set background picture of theViewOptions to file ".background:$BG_IMG"
		-- adding symlink to /Applications (skip if it already exists)
		if not (exists file "Applications" of container window) then
			make new alias file at container window to POSIX file "/Applications" with properties {name:"Applications"}
		end if
		-- reopening
		close
		open
		-- rearranging
		set the position of item "Applications" to {$APPS_X, $APPS_Y}
		set the position of item "$APP_BUNDLE_NAME" to {$BUNDLE_X, $BUNDLE_Y}
		-- updating and sleeping for 5 secs
		update without registering applications
		delay 5
	end tell
	end timeout
end tell
EOF
)
echo "$APPLESCRIPT" | osascript 2>&1 || echo "⚠  osascript failed (Finder?)"

# --- permissions, sync, detach ---
chmod -Rf go-w "/Volumes/$VOL_NAME" 2>/dev/null || true
sync
sync
hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "/Volumes/$VOL_NAME" >/dev/null 2>&1 || true

# --- final compressed UDZO ---
rm -f dist/AliSwitcher.dmg
hdiutil convert "$DMG_NAME_TMP" -format UDZO -imagekey zlib-level=9 -o dist/AliSwitcher.dmg >/dev/null

echo ""
echo "✓ DMG: dist/AliSwitcher.dmg"
echo "  Install: open dist/AliSwitcher.dmg → drag $APP_BUNDLE_NAME into Applications"
