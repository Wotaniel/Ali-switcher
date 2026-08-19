#!/bin/bash
# Собирает установщик build/AliSwitcher-Installer.pkg:
#  - AliSwitcher.app в /Applications
#  - LaunchAgent (автозапуск после входа)
#  - приветственное окно инсталлера с инструкцией по правам
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION="1.0.0"
BUNDLE_ID="local.alishch.aliswitcher"
STAGE="build/installer-root"
SCRIPTS="build/installer-scripts"
PKG_INNER="build/AliSwitcher-inner.pkg"
PKG_FINAL="build/AliSwitcher-Installer.pkg"

rm -rf "$STAGE" "$SCRIPTS" "$PKG_INNER" "$PKG_FINAL"
mkdir -p "$STAGE/Applications" "$STAGE/Library/LaunchAgents" "$SCRIPTS"

# --- .app ---
cp -R build/AliSwitcher.app "$STAGE/Applications/"

# --- LaunchAgent: автозапуск после входа в систему ---
cat > "$STAGE/Library/LaunchAgents/$BUNDLE_ID.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.alishch.aliswitcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/AliSwitcher.app/Contents/MacOS/AliSwitcher</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

# --- postinstall: регистрируем автозапуск и запускаем приложение для текущего пользователя ---
cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo 501)
PLIST="/Library/LaunchAgents/local.alishch.aliswitcher.plist"

launchctl bootout "gui/$CONSOLE_UID/local.alishch.aliswitcher" 2>/dev/null || true
launchctl bootstrap "gui/$CONSOLE_UID" "$PLIST" 2>/dev/null || true

if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    launchctl asuser "$CONSOLE_UID" open "/Applications/AliSwitcher.app" 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$SCRIPTS/postinstall"

# --- сборка пакета ---
pkgbuild --root "$STAGE" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --scripts "$SCRIPTS" \
    --install-location / \
    "$PKG_INNER" >/dev/null

# --- приветственное окно с инструкцией по правам ---
mkdir -p build/distribution
cat > build/distribution/welcome.html <<'HTML'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>AliSwitcher</title></head>
<body style="font-family: -apple-system, 'Helvetica Neue', sans-serif; color: #222; padding: 8px 20px; font-size: 13px;">
<h2 style="margin-bottom: 4px;">AliSwitcher</h2>
<p style="margin-top: 0; color: #666;">Переключатель раскладки по двойному Shift (русский ↔ английский)</p>
<p><b>Как работает:</b> напечатали текст не в той раскладке → дважды нажали Shift → текст переведён в правильную раскладку, раскладка переключена.</p>
<p><b>После установки включите AliSwitcher в двух списках</b> (Системные настройки → Конфиденциальность и безопасность):</p>
<ol>
<li><b>Специальные возможности</b> — чтение выделенного текста и его замена клавишами.</li>
<li><b>Наблюдение за вводом</b> — слежение за двойным нажатием Shift.</li>
</ol>
<p>При первом запуске приложение покажет подсказку с кнопками, открывающими нужные разделы настроек.</p>
<p style="color: #666;">Приложение запускается автоматически после входа (иконка «RU» в строке меню). Выйти — через меню иконки.</p>
</body>
</html>
HTML

cat > build/distribution/distribution.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>AliSwitcher</title>
    <welcome file="welcome.html"/>
    <options customize="never" require-scripts="false"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default">
        <pkg-ref id="local.alishch.aliswitcher"/>
    </choice>
    <pkg-ref id="local.alishch.aliswitcher" version="1.0.0" onConclusion="none">AliSwitcher-inner.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild --distribution build/distribution/distribution.xml \
    --package-path build \
    "$PKG_FINAL" >/dev/null

echo ""
echo "✓ Инсталлер: $PKG_FINAL"
echo "  Установка: двойной клик → Мастер установки."
echo "  Если macOS скажет «неизвестный разработчик» — правый клик → «Открыть» (нужна Developer ID для полной тишины)."
