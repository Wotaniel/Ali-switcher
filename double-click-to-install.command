#!/bin/bash
# AliSwitcher installer (for the DMG): double-click and everything is done.
# Copies the app to /Applications, removes quarantine,
# allows Gatekeeper, launches.
cd "$(dirname "$0")"

APP="AliSwitcher.app"
DEST="/Applications/$APP"

echo "AliSwitcher — installation"
echo "=========================="

# 1. Copy to /Applications
if [ ! -d "$DEST" ]; then
    echo "▸ Copying $APP to /Applications..."
    cp -R "$APP" "$DEST"
else
    echo "▸ Updating $APP in /Applications..."
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
fi

# 2. Remove quarantine (Gatekeeper)
echo "▸ Removing quarantine..."
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# 3. Allow Gatekeeper (asks for the password)
echo "▸ Allowing Gatekeeper (password required)..."
osascript -e "do shell script \"spctl --add --label AliSwitcher '$DEST'\" with administrator privileges" 2>/dev/null \
    && echo "  ✓ Gatekeeper allowed" \
    || echo "  ⚠  could not allow Gatekeeper (right-click → Open still works)"

# 4. Launch
echo "▸ Launching..."
open "$DEST"

echo ""
echo "✓ Done. The app is in $DEST"
echo "  The «RU» icon will appear in the menu bar."
echo "  Permissions on first launch: Accessibility + Input Monitoring."
echo ""
read -n 1 -s -r -p "Press any key to close…"
echo ""
