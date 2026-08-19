#!/bin/bash
# Сборка AliSwitcher: swiftc → .app бандл.
# Сборка/подпись идут в /tmp (ВНЕ iCloud): FileProvider из iCloud Drive
# подмешивает в build/ мусор (xattr/._/macl) прямо во время codesign,
# из-за чего подпись периодически «падала». Готовый .app копируется в build/.
set -euo pipefail
cd "$(dirname "$0")"

# Тулчейн: предпочитаем swiftly (системная CLT на этой машине рассинхронизирована).
if [ -f "$HOME/.swiftly/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.swiftly/env.sh"
fi
swiftc --version >/dev/null 2>&1 || { echo "✗ Нет рабочего swiftc. Установите тулчейн: brew install swiftly && swiftly init -y"; exit 1; }

mkdir -p build

# Иконка (в build/ — она не участвует в подписи)
./make-icon.sh

# Временная папка сборки вне iCloud
STAGE=$(mktemp -d /tmp/aliswitcher-build.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/app/Contents/MacOS" "$STAGE/app/Contents/Resources"

echo "▸ Сборка универсального бинаря (arm64 + x86_64)..."
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
    Sources/AliSwitcher/*.swift -o "$STAGE/AliSwitcher-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macosx13.0 \
    Sources/AliSwitcher/*.swift -o "$STAGE/AliSwitcher-x86_64"
lipo -create -output "$STAGE/AliSwitcher" "$STAGE/AliSwitcher-arm64" "$STAGE/AliSwitcher-x86_64"

cp "$STAGE/AliSwitcher" "$STAGE/app/Contents/MacOS/AliSwitcher"
cp build/AliSwitcher.icns "$STAGE/app/Contents/Resources/AliSwitcher.icns"
cp uninstall.sh "$STAGE/app/Contents/Resources/uninstall.sh"

cat > "$STAGE/app/Contents/Info.plist" <<'PLIST'
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
        <string>1.0.0</string>
    <key>CFBundleVersion</key>
        <string>1</string>
    <key>CFBundleIconFile</key>
        <string>AliSwitcher</string>
    <key>LSMinimumSystemVersion</key>
        <string>13.0</string>
    <key>LSUIElement</key>
        <true/>
</dict>
</plist>
PLIST

# Подпись стабильным сертификатом (в /tmp — без вмешательства iCloud)
CERT_NAME="AliSwitcher Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force --sign "$CERT_NAME" "$STAGE/app"
else
    echo "⚠  Сертификат не найден — подписываю ad-hoc (права будут слетать при пересборках)."
    echo "   Создайте сертификат один раз: ./setup-cert.sh"
    codesign --force --sign - "$STAGE/app"
fi

# Готовый подписанный .app — в build/
# Если старый build/AliSwitcher.app занят iCloud/root (не удаляется) —
# кладём в build/app/AliSwitcher.app.
OUT_APP="build/AliSwitcher.app"
if ! rm -rf "$OUT_APP" 2>/dev/null; then
    echo "⚠  build/AliSwitcher.app не удаляется (root/iCloud) — собираю в $OUT_APP/.. app/"
    OUT_APP="build/app/AliSwitcher.app"
    mkdir -p build/app
    rm -rf "$OUT_APP"
fi
ditto "$STAGE/app" "$OUT_APP"

codesign --verify "$OUT_APP" || { echo "✗ Проверка подписи не прошла"; exit 1; }

echo ""
echo "✓ Готово: $OUT_APP (universal: arm64 + x86_64)"
echo "  Запуск:   open \"$OUT_APP\""
echo "  Инсталлер: ./make-dmg.sh → dist/AliSwitcher.dmg"
