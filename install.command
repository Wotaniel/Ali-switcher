#!/bin/bash
# Установщик AliSwitcher (для DMG): двойной клик — всё сделает сам.
# Копирует приложение в /Applications, снимает quarantine,
# разрешает Gatekeeper, запускает.
cd "$(dirname "$0")"

APP="AliSwitcher.app"
DEST="/Applications/$APP"

echo "AliSwitcher — установка"
echo "======================="

# 1. Копируем в /Applications
if [ ! -d "$DEST" ]; then
    echo "▸ Копирую $APP в /Applications..."
    cp -R "$APP" "$DEST"
else
    echo "▸ Обновляю $APP в /Applications..."
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
fi

# 2. Снимаем quarantine (Gatekeeper)
echo "▸ Снимаю quarantine..."
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# 3. Разрешаем Gatekeeper (спросит пароль)
echo "▸ Разрешаю Gatekeeper (нужен пароль)..."
osascript -e "do shell script \"spctl --add --label AliSwitcher '$DEST'\" with administrator privileges" 2>/dev/null \
    && echo "  ✓ Gatekeeper разрешён" \
    || echo "  ⚠  не смог разрешить Gatekeeper (можно запустить правым кликом → Открыть)"

# 4. Запускаем
echo "▸ Запускаю..."
open "$DEST"

echo ""
echo "✓ Готово. Приложение в $DEST"
echo "  Иконка «RU» появится в строке меню."
echo "  Права при первом запуске: Специальные возможности + Наблюдение за вводом."
echo ""
read -n 1 -s -r -p "Нажмите любую клавишу, чтобы закрыть…"
echo ""
