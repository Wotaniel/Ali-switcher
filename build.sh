#!/bin/bash
# Build AliSwitcher: swiftc → .app bundle.
# Build/sign happen in /tmp (OUTSIDE iCloud): the iCloud FileProvider mixes junk
# (xattr/._/macl) into build/ during codesign, which broke signatures randomly.
# The finished .app is copied to build/.
set -euo pipefail
cd "$(dirname "$0")"

# Prefer the swiftly toolchain (system CLT on this machine is out of sync).
if [ -f "$HOME/.swiftly/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.swiftly/env.sh"
fi
swiftc --version >/dev/null 2>&1 || { echo "✗ No working swiftc. Install a toolchain: brew install swiftly && swiftly init -y"; exit 1; }

mkdir -p build

# Read version from VERSION file (default: 1.0.0)
VERSION=$(cat VERSION 2>/dev/null | tr -d '[:space:]')
: "${VERSION:=1.0.0}"

# Build number: git commit count (always increases with each commit).
# Falls back to epoch timestamp if not in a git repo.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo "$(date +%s)")

# Git short hash for display in About panel (falls back to "dev").
GITHASH=$(git rev-parse --short HEAD 2>/dev/null || echo "dev")

echo "▸ Version: $VERSION (build $BUILD, $GITHASH)"

# Icon (in build/ — not part of the signature)
# make-icon.sh won't overwrite existing PNG (preserves custom icons).
./make-icon.sh

# Build dir outside iCloud
STAGE=$(mktemp -d /tmp/aliswitcher-build.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/app/Contents/MacOS" "$STAGE/app/Contents/Resources"

echo "▸ Building universal binary (arm64 + x86_64)..."
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
    Sources/AliSwitcher/*.swift -o "$STAGE/AliSwitcher-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macosx13.0 \
    Sources/AliSwitcher/*.swift -o "$STAGE/AliSwitcher-x86_64"
lipo -create -output "$STAGE/AliSwitcher" "$STAGE/AliSwitcher-arm64" "$STAGE/AliSwitcher-x86_64"

cp "$STAGE/AliSwitcher" "$STAGE/app/Contents/MacOS/AliSwitcher"
cp build/AliSwitcher.icns "$STAGE/app/Contents/Resources/AliSwitcher.icns"
cp Sources/AliSwitcher/builtin_words_en.txt "$STAGE/app/Contents/Resources/builtin_words_en.txt"
cp Sources/AliSwitcher/builtin_words_ru.txt "$STAGE/app/Contents/Resources/builtin_words_ru.txt"
cp uninstall.sh "$STAGE/app/Contents/Resources/uninstall.sh"

cat > "$STAGE/app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
        <string>AliSwitcher</string>
    <key>CFBundleIdentifier</key>
        <string>local.alishch.aliswitcher</string>
    <key>CFBundleName</key>
        <string>AliSwitcher</string>
    <key>CFBundleDisplayName</key>
        <string>AliSwitcher</string>
    <key>CFBundlePackageType</key>
        <string>APPL</string>
    <key>CFBundleShortVersionString</key>
        <string>$VERSION</string>
    <key>CFBundleVersion</key>
        <string>$BUILD</string>
    <key>GitHash</key>
        <string>$GITHASH</string>
    <key>CFBundleIconFile</key>
        <string>AliSwitcher</string>
    <key>LSMinimumSystemVersion</key>
        <string>13.0</string>
    <key>LSUIElement</key>
        <true/>
</dict>
</plist>
PLIST

# Sign with the stable certificate (in /tmp — no iCloud interference)
CERT_NAME="AliSwitcher Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force --sign "$CERT_NAME" "$STAGE/app"
else
    echo "⚠  Certificate not found — signing ad-hoc (permissions will be lost on rebuilds)."
    echo "   Create the certificate once: ./setup-cert.sh"
    codesign --force --sign - "$STAGE/app"
fi

# Copy the signed .app to build/
# If the old build/AliSwitcher.app is locked by iCloud/root (cannot be removed) —
# put it into build/app/AliSwitcher.app instead.
OUT_APP="build/AliSwitcher.app"
if ! rm -rf "$OUT_APP" 2>/dev/null; then
    echo "⚠  build/AliSwitcher.app cannot be removed (root/iCloud) — building into build/app/"
    OUT_APP="build/app/AliSwitcher.app"
    mkdir -p build/app
    rm -rf "$OUT_APP"
fi
ditto "$STAGE/app" "$OUT_APP"

codesign --verify "$OUT_APP" || { echo "✗ Signature verification failed"; exit 1; }

echo ""
echo "✓ Done: $OUT_APP (universal: arm64 + x86_64)"
echo "  Run:     open \"$OUT_APP\""
echo "  DMG:     ./make-dmg.sh → dist/AliSwitcher-\$(cat VERSION).dmg"
