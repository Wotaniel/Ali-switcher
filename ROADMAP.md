# AliSwitcher — План развития

> Текущая версия: **1.1.0** (август 2026)
> Принцип: **layout switcher, не текстовый процессор**. Только конвертация раскладки.

---

## 📋 Резюме: что уже есть

| Область | Статус |
|---|---|
| Двойной Shift → конвертация набранного | ✅ Готово |
| Двойной Shift → конвертация выделения (через clipboard) | ✅ Готово |
| Авто-конвертация (detect + switch) | ✅ Готово |
| Auto-learn исключений (undo → блок) | ✅ Готово |
| Два независимых списка слов (enWords / ruWords) | ✅ Готово |
| Built-in словари (~100+ слов на язык) | ✅ Готово |
| NSSpellChecker (проверка орфографии) | ✅ Готово |
| Ретроактивная конвертация (многословный фрагмент) | ✅ Готово |
| Защита полей паролей (secureField) | ✅ Готово |
| Undo (двойной Shift повторно → отмена) | ✅ Готово |
| Menu bar app (RU индикатор) | ✅ Готово |
|Панель прав (Accessibility + Input Monitoring) | ✅ Готово |
| Автозапуск при входе | ✅ Готово |
| DMG-инсталлер | ✅ Готово |
| Self-signed cert (права переживают пересборки) | ✅ Готово |
| 232 self-tests (findConversionRange, типiability, boundary math) | ✅ Готово |
| Рефакторинг: UIManager + SwitcherState извлечены из main.swift | ✅ Готово |
| Generation token (защита async callbacks от race conditions) | ✅ Готово |
| isFullyTypeable (проверка типаемости перед конвертацией) | ✅ Готово |
| typedBufferIsFromConversion (защита от загрязнения буфера) | ✅ Готово |

---

## 🎯 Приоритеты (по убыванию)

### Фаза 1 — Качество и стабильность (ближайшие 2–4 недели)

Самое важное: то, что уже работает, должно работать **без сюрпризов**.

#### 1.1. Рефакторинг `main.swift` — частично выполнено
**Что сделано:**
- [x] UI (menus, panels, windows) → `UIManager.swift`
- [x] Состояние → `SwitcherState.swift` (busy, typedBuffer, generation, isReplacing)
- [x] `AutoSwitcher.findConversionRange` — единый алгоритм для авто + ручной конвертации

**Что осталось:**
- [ ] Вынести permissions logic → `Permissions.swift` (вместе с `Accessibility.swift`)
- [ ] `Switcher` → разбить на: `EventTapManager` (tap + callbacks), `TextConverter` (performSwitch + convert flow)
- [ ] `main.swift` сейчас ~850 строк (было ~1350) — целевое значение ~300

#### 1.2. Автоматические UI-тесты
**Проблема:** 232 unit-теста покрывают логику, но не UI-флоу (панели прав, редакторы слов, меню).
**План:**
- [ ] Базовые smoke-тесты: открытие/закрытие панелей без крашей
- [ ] Тесты lifecycle: `activationPolicy` корректно переключается на `.accessory` при закрытии каждой панели
- [ ] Тесты влияния на `busy` флаг: открытие/закрытие окон не должно ломать event tap

#### 1.3. Лог-система ✅
**Проблема:** `log()` и `print()` вперемешку, нет уровней, нет ротации, вывод только в консоль.
**План:**
- [x] Единый Logger с уровнями `.debug / .info / .warn / .error`
- [x] Запись в `~/Library/Logs/AliSwitcher.log` с ротацией (1 МБ, 3 файла)
- [ ] Меню: "Export Debug Log…" → собирает лог + версию + ОС в файл (для баг-репортов)
- [x] Уровень логирования настраивается в UserDefaults (`logLevel`)

#### 1.4. Edge-case проверка: терминальные приложения
**Проблема:** Terminal.app и iTerm2 обрабатывают synthetic keystrokes по-другому (могут не ловить `Cmd+V` через CGEvent).
**План:**
- [ ] Тестировать конвертацию выделения в Terminal/iTerm2/Termius
- [ ] Fallback: если `Cmd+V` не сработал → попытка через `CGEventPostToPid` к конкретному окну
- [ ] Документация: какие приложения могут быть проблемными

---

### Фаза 2 — UX и полировка (короткими итерациями)

#### 2.1. Окно настроек (Settings)
**Проблема:** все настройки scattered в меню bar. Нет единого окна, скриншотить неудобно, new users не понимают что есть.
**План:**
- [ ] Простое `NSWindow` с вкладками: General / Auto-Convert / Words / About
- [ ] General: автозапуск, логирование
- [ ] Auto-Convert: on/off, delay, auto-learn, задержка undo
- [ ] Words: редакторы enWords/ruWords — прямо во вкладке
- [ ] About: версия, лицензия, ссылка на репорт баги
- [ ] Меню бар: "Settings…" → открывает окно
- [ ] Помнить: НЕ добавлять лишних настроек — только то что уже есть

#### 2.2. Нормальный onboarding
**Проблема:** первый запуск — панель прав выглядит пугающе, непонятно "что дальше".
**План:**
- [ ] Короткий приветственный флоу: 3 шага (Input Monitoring → Accessibility → Try it!)
- [ ] На каждом шаге: что разрешить → зачем → как проверить → "Continue"
- [ ] После выдачи прав — мини-анимация/подсказка: "Наберите 'ghbdtn' и нажмите двойной Shift"

#### 2.3. Иконка приложения
**Проблема:** текущая иконка может выглядеть непрофессионально в Dock (хотя app accessory, About panel её показывает).
**План:**
- [ ] Дизайн: минималистичная иконка (клавиатура ↔ флаг RU/EN)
- [ ] Dark/light варианты (template icon)
- [ ] Проверить что `make-icon.sh` корректно собирает из 1024 PNG

#### 2.4. Уведомления об undo
**Проблема:** после авто-конверта пользователь не понимает, что двойной Shift повторно — это undo.
**План:**
- [ ] После авто-конверта — краткая подсказка (toast/notification): "Двойной Shift снова = отмена"
- [ ] Показывать только первые N раз (не раздражать опытных)
- [ ] Счётчик в UserDefaults (`undoHintsShown`)

---

### Фаза 3 — Дистрибуция (когда стабильно)

#### 3.1. Notarization (Apple)
**Проблема:** self-signed cert — Gatekeeper ругается при первом запуске, `xattr -d` нужен.
**План:**
- [ ] Зарегистрировать Apple Developer ID ($99/year)
- [ ] `build.sh` → add `codesign` + `notarytool` (CI скрипт)
- [ ] `xcrun stapler staple` после нотаризации
- [ ] Запись в memory: `notarize.sh` (отдельный скрипт, не в `build.sh`)

#### 3.2. Homebrew Cask
**Проблема:** установка только через DMG вручную, оригинальный способ для мака — `brew install --cask`.
**План:**
- [ ] Создать cask формулу в `homebrew-cask` репозитории (после нотаризации)
- [ ] Автоматизация: GitHub Action → push DMG → update cask
- [ ] `brew install --cask aliswitcher` — единая команда

#### 3.3. GitHub Release automation
**Проблема:** релизы собираются вручную (`./build.sh && ./make-dmg.sh`).
**План:**
- [ ] GitHub Action: при `git tag v*` → build universal → notarize → upload DMG → create release
- [ ] Release notes генерируются из commit messages
- [ ].sha256 checksum для Homebrew cask

#### 3.4. Sparkle обновления (опционально)
**Проблема:** обновления требуют ручной переустановки.
**План:**
- [ ] Интегрировать Sparkle framework (https://sparkle-project.org)
- [ ] Appcast XML с версиями + UR
- [ ] Бекенда: GitHub Pages для appcast.xml
- [ ] Контекст: приложение background — нужен ||
      UI для "доступно обновление" (диалог или menu badge)
- ⚠️ Только после нотаризации

---

### Фаза 4 — Возможные расширения (далёкая перспектива)

#### 4.1. Не только RU↔EN
**Проблема:** много языков сложно, но быть может есть спрос на UK↔EN, BE↔EN и т.д.
**План:**
- [ ] Абстракция: `LayoutPair` с таблицей транслитерации вместо хардкода ЙЦУКЕН
- [ ] Каждая пара — отдельный файл (`TranslitRu.swift`, `TranslitUk.swift` ...)
- [ ] Настройка: выбор пары раскладок
- [ ] Built-in words → per-layout

#### 4.2. Статистика использования (опционально, privacy-first)
**Проблема:** любопытно как используется, но privacy.
**План:**
- [ ] Локальная статистика: сколько конвертаций в день, какие слова (без текста, только агрегаты)
- [ ] График в About panel
- [ ] Никакой телеметрии на сервер (никогда)
- [ ] Меню: "Usage Stats…" → окно с цифрами
- [ ] Reset: "Clear Stats"

#### 4.3. Глобальный hotkey (опционально)
**Проблема:** двойной Shift не всех устраивает — некоторые используют для caps lock.
**План:**
- [ ] Настраиваемый hotkey: `⌃⌥Space` или `⌘⇧\\` или что угодно
- [ ] Настройка в Settings → General
- [ ] Двойной Shift остаётся дефолтом

#### 4.4. Игнор приложений (только список)
**Проблема:** AGENTS.md написано "don't add app exclusion lists — edge-case detection handles code context". Но код-проверка структурная (underscores, digits, domains) — иногда фейлит на языках программирования с `camelCase`.
**План:**
- [ ] ЧЕРЕЗ настройки → только список приложений (bundle ID), auto-convert OFF
- [ ] Двойной Shift продолжает работать во всех приложениях (только auto-convert off)
- [ ] По умолчанию список пуст — не ломать текущий UX
- [ ] Документировать принципиально: auto-convert off ≠ app disabled, только авто

---

### Фаза 5 — Инфраструктура (continuous)

#### 5.1. Тесты в CI
- [ ] GitHub Actions: `swiftc` build + `--test` на каждом push
- [ ] Matrix: macOS 13 / 14 / 15
- [ ] Lint: `swift-format` или `swiftlint`

#### 5.2. Версионирование
- [ ] SemVer строго: MAJOR только при breaking, MINOR для feature, PATCH для багфикс
- [ ] CHANGELOG.md (авто-генерация из commit messages)
- [ ] VERSION файл → единственный source of truth (уже сделано)

#### 5.3. Документация
- [ ] README.md: дополнить скриншотами
- [ ] CONTRIBUTING.md: как собрать, как добавить builtin word, как добавить тест
- [ ] ARCHITECTURE.md: диаграмма классов, flow performSwitch, state diagram busy/typedBuffer

---

## ❌ Чего НЕ делать (явные ограничения)

| Идея | Почему нет |
|---|---|
| Е→ё, em-dashes, smart quotes | Это layout switcher, НЕ текстовый процессор |
| Переводчик (意义上) | Это не translater, это translit converter |
| Облачная синхронизация списков слов | Privacy + усложнение, нет смысла для layout switcher |
| Перетаскивание слов между списками (drag-and-drop) | Списки independent по скрипту, нельзя перетаскивать |
| Профили (work/home) | Нет запроса на это, переусложнение |
| Плагины / Extension API | Принцип: маленький и фокусированный |
| App Store distribution | Санбокс убивает event tap и input monitoring |

---

## 📅 Приоритет на ближайший месяц (август–сентябрь 2026)

| # | Что | Оценка | Важно? |
|---|---|---|---|
| 1 | Доработка рефакторинга `main.swift` (Permissions, EventTap, TextConverter) | 1–2 дня | ⭐⭐⭐ |
| 2 | Лог-система с уровнями и файлом | 1–2 дня | ⭐⭐⭐ |
| 3 | Edge-case: Terminal/iTerm2 выделение | 1 день | ⭐⭐ |
| 4 | Окно настроек (вкладки) | 2–3 дня | ⭐⭐ |
| 5 | Нормальный onboarding (права) | 1–2 дня | ⭐⭐ |
| 6 | Уведомление об undo | 0.5 дня | ⭐ |
| 7 | Notarization (после developer ID) | 1 день | ⭐⭐ |
| 8 | GitHub Release Action | 0.5 дня | ⭐ |

**Не делать в этом месяце:** другие раскладки (Фаза 4.1), статистика (4.2), Sparkle.

---

## 📝 Заметки для реализации

### Рефакторинг main.swift — приоритет #1

Текущий god-class `Switcher` делает всё. План разделения:

```
main.swift                    (entry point, app lifecycle)              ~50 строк
├── EventTapManager.swift     (CGEventTap, double-Shift detection)     ~150 строк
├── TextConverter.swift       (performSwitch, undo, convert flows)     ~250 строк
├── AutoConvertController.swift (tryAutoConvert, undoAutoConvert)       ~100 строк
├── UIManager.swift           (menu bar, panels, editors, permissions UI) ~300 строк ✅
├── SwitcherState.swift       (shared mutable state: busy, typedBuffer, generation) ✅
└── Existing:
    ├── AutoSwitcher.swift    (findConversionRange, shouldConvert, word lists)
    ├── KeyEvents.swift       (isFullyTypeable, type, backspace, paste, undo)
    ├── KeyTracker.swift     (already separate, good)
    ├── Translit.swift       (already separate, good)
    ├── ChunkFinder.swift    (already separate, good)
    ├── LayoutSwitch.swift   (already separate, good)
    ├── Accessibility.swift  (already separate, good)
    └── Clipboard.swift      (already separate, good)
```

Проблема: `Switcher` класс держит **состояние** (busy, typedBuffer, lastAutoConvertInfo). Это состояние вынесено в `SwitcherState.swift` (✅ выполнено), но `main.swift` всё ещё содержит `performSwitch`, `tryAutoConvert`, `undoAutoConvert`, `convertTypedText` — это следующий шаг рефакторинга.

### Notarization — важное замечание

Хотя сам `build.sh` хорошо собирает self-signed app, для **публичной дистрибуции** через Homebrew/Direct-download не обойтись без Apple Developer ID:
- Notarization требует Apple Developer Program ($99/year)
- Нужен App-specific password для `notarytool` (генерируется в Apple ID account)
- `xcrun notarytool submit AliSwitcher.app.zip --apple-id ... --password ... --team-id ...`
- Ожидание: 5–30 минут
- Sparkle/Updates: тоже требует нотаризации — нельзя поставить на старое

### Homebrew Cask — flow

```ruby
cask "aliswitcher" do
  version "1.1.0"
  sha256 "..."

  url "https://github.com/.../releases/download/v#{version}/AliSwitcher-#{version}.dmg"
  name "AliSwitcher"
  desc "RU/EN layout switcher for macOS"
  homepage "https://github.com/.../aliswitcher"

  app "AliSwitcher.app"
end
```

Cask должен быть в `homebrew-cask` репозитории (PR). После мержа:
`brew install --cask aliswitcher`

---

## 🔄 История ревизий плана

| Дата | Изменение |
|---|---|
| 2026-08-21 | Создан план развития |
| 2026-08-22 | Обновлено: 232 теста, рефакторинг частично выполнен (UIManager + SwitcherState), findConversionRange, generation token, isFullyTypeable |

---

> **Принцип:** маленький и фокусированный, а не feature-rich. Каждое предложение новой фичи должно проходить проверку: "Это укладывается в концепцию layout switcher?". Если нет — отбросить.
