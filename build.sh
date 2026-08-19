#!/bin/bash
# Сборка AliSwitcher: swiftc → .app бандл (без Xcode и без SwiftPM).
set -euo pipefail
cd "$(dirname "$0")"

# Тулчейн: предпочитаем swiftly, если он установлен (системная CLT на этой машине рассинхронизирована).
if [ -f "$HOME/.swiftly/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.swiftly/env.sh"
fi
swiftc --version >/dev/null 2>&1 || { echo "✗ Нет рабочего swiftc. Установите тулчейн: brew install swiftly && swiftly init -y"; exit 1; }

APP="build/AliSwitcher.app"
# Полный сброс: старые файлы могут нести защищённые xattr (com.apple.macl),
# которые codesign не переваривает и которые не снимаются xattr -cr.
rm -rf "$APP" build/AliSwitcher build/AliSwitcher.icns build/makeicon build/icon-1024.png
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Иконка (генерируется из простой картинки)
./make-icon.sh

echo "▸ Сборка универсального бинаря (arm64 + x86_64)..."
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
    Sources/AliSwitcher/*.swift -o build/AliSwitcher-arm64
swiftc -O -swift-version 5 -target x86_64-apple-macosx13.0 \
    Sources/AliSwitcher/*.swift -o build/AliSwitcher-x86_64
lipo -create -output build/AliSwitcher build/AliSwitcher-arm64 build/AliSwitcher-x86_64
rm -f build/AliSwitcher-arm64 build/AliSwitcher-x86_64

cp build/AliSwitcher "$APP/Contents/MacOS/AliSwitcher"
cp build/AliSwitcher.icns "$APP/Contents/Resources/AliSwitcher.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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

# Подпись: стабильным самоподписанным сертификатом (если есть), иначе ad-hoc.
# Стабильная подпись = TCC-права (Accessibility/Input Monitoring) НЕ слетают
# при пересборках. Создать сертификат: ./setup-cert.sh
xattr -cr "$APP" 2>/dev/null || true
CERT_NAME="AliSwitcher Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    codesign --force --sign "$CERT_NAME" "$APP"
else
    echo "⚠  Сертификат не найден — подписываю ad-hoc (права будут слетать при пересборках)."
    echo "   Создайте сертификат один раз: ./setup-cert.sh"
    codesign --force --sign - "$APP"
fi

echo ""
echo "✓ Готово: $APP (universal: arm64 + x86_64)"
echo "  Запуск:   open \"$APP\""
echo "  Инсталлер: ./make-installer.sh → build/AliSwitcher-Installer.pkg"
