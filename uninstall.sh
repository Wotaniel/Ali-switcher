#!/bin/bash
# Полное удаление AliSwitcher. Запускать с sudo (или через меню приложения).
set -euo pipefail

CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null || echo 501)

kill_all() {
    pkill -9 -x AliSwitcher 2>/dev/null || true
    sleep 1
}

echo "▸ Останавливаю приложение..."
kill_all

echo "▸ Сбрасываю права (TCC: Специальные возможности / Наблюдение за вводом)..."
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    sudo -u "$CONSOLE_USER" tccutil reset Accessibility local.alishch.aliswitcher 2>/dev/null || true
    sudo -u "$CONSOLE_USER" tccutil reset ListenEvent local.alishch.aliswitcher 2>/dev/null || true
fi

echo "▸ Отключаю автозапуск (LaunchAgent)..."
launchctl bootout "gui/$CONSOLE_UID/local.alishch.aliswitcher" 2>/dev/null || true
rm -f /Library/LaunchAgents/local.alishch.aliswitcher.plist

echo "▸ Удаляю приложение из /Applications..."
rm -rf /Applications/AliSwitcher.app

echo "▸ Ищу и удаляю остальные копии приложения..."
ps -xo command 2>/dev/null | grep '/AliSwitcher.app/Contents/MacOS/AliSwitcher' | grep -v grep | awk '{print $1}' | sed 's#/Contents/MacOS/AliSwitcher$##' | sort -u | while read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && rm -rf "$p" && echo "  удалено: $p"
done
# На случай если процесс ещё жив после удаления файлов — убиваем снова
kill_all

echo "▸ Забываю запись об установке..."
pkgutil --forget local.alishch.aliswitcher 2>/dev/null || true

echo "▸ Чищу временные файлы и логи..."
rm -f /tmp/AliSwitcher.log /tmp/local.alishch.aliswitcher.lock
rm -f "$HOME/Library/Logs/DiagnosticReports/AliSwitcher-"*.ips 2>/dev/null || true

echo ""
echo "✓ AliSwitcher полностью удалён."
