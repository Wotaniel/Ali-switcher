# Changelog

All notable changes to AliSwitcher are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/), dates in ISO 8601.

## [Unreleased]

### Added
- **Logger with levels and rotation** — new `Logger.swift` (`LogLevel` enum: `.debug`/`.info`/`.warn`/`.error`). Log path moved from `/tmp/AliSwitcher.log` to `~/Library/Logs/AliSwitcher.log` (survives reboot). Rotation at 1 MB, 3 files max. Level configurable via UserDefaults: `defaults write com.aliswitcher.AliSwitcher logLevel -int 0` (debug). Default: `.info`. Existing `log("msg")` calls work unchanged (default `.info`); verbose calls (findRange, convert details, replay, isReplacing START/END) moved to `.debug`; warnings (event tap fail, isReplacing stuck, no target layout, etc.) moved to `.warn`.
- **`Permissions.swift`** — centralized permission checks (`accessibilityGranted`, `inputMonitoringGranted`, `allGranted`) and "open System Settings" actions. Previously scattered across `Accessibility.swift`, `UIManager.swift`, and `main.swift`. UIManager's `@objc` methods are now thin wrappers. `Accessibility.swift` no longer has `isTrusted`/`requestPermissionIfNeeded`.

### Fixed
- **Backspace during conversion window** — when user pressed Backspace during `isReplacing` (0.1–0.8s conversion window) with empty `pendingCharacters` buffer, the key was silently discarded. Now: backspaces are queued in `pendingBackspaces` counter, replayed after conversion completes. User's backspace press is delayed ~0.3s but no longer lost.
- **Words with non-letter prefix not converted** — `isWordLatin` checked the first character of each word; if it was a quote or punctuation (e.g. `"nj`, `,tpdjpdhfnyjt`), the word was classified as "not Latin" and the retro walk stopped. Now: `isWordLatin` finds the first actual letter character, correctly classifying words with non-letter prefixes.
- **Comma/period splitting words that should be joined** — `,` (=`б` on ЙЦУКЕН) and `.` (=`ю`) were in the `boundaries` set, splitting words like `djj,ot` → `djj` + `,` + `ot` → `воо,ще` instead of `вообще`. Now: `parseBufferSegments` keeps `,`/`.` inside words when they're between letters or before letters at word start. Trailing `,`/`.` (followed by boundary/space) still treated as punctuation.
- **Force-reset on large conversions** — converting 17 words (96 backspaces + 90 chars ≈ 1.67s) exceeded the fixed 1.5s `isReplacingTimeout`, triggering force-reset and losing state. Now: timeout is adaptive — `max(1.5s, expectedDuration + 0.5s margin)` — scaling with delete count and text length.
- **Consecutive comma/period splitting words** — `k.,jv` (=`любом`) was split at `.` because the next char `,` was also a boundary. The fix only checked ONE character ahead; now `commaPeriodFollowedByLetter` looks through the entire sequence of consecutive `,`/`.` chars to find a letter at the end.
- **Log format string** — `RESULT` log line in `findConversionRange` had `\"` instead of `»` after `convertedText`, making the log output `conv=«orl"` instead of `conv=«orl»`.

## [1.2.0] — 2026-08-24

### Added
- **Auto build number + git hash** — `CFBundleVersion` now tracks git commit count (always increases); new `GitHash` plist key stores short commit hash. About panel shows `Version 1.2.0 (build N, abc1234)`. Makes every build identifiable even within the same version.
- **Builtin word lists in external `.txt` files** — `builtin_words_en.txt` (109 words) and `builtin_words_ru.txt` (80 words), one word per line with `#` comments. Loaded at startup via `Bundle.main` with fallback to empty set. `build.sh` copies both to `Contents/Resources/`. No more hardcoded word arrays in `AutoSwitcher.swift`.
- **`hasMixedScript` helper** — detects words containing BOTH Cyrillic AND Latin letters (never occurs in legitimate text). Mixed-script words skip spell-checker entirely (NSSpellChecker can't reason about them — treated «nj» in «Э"nj» as valid English abbreviation NJ = New Jersey → blocked conversion). Mixed script → unambiguous wrong-layout → convert directly.
- **Typographic quote normalization** — `Translit.convert()` normalizes smart quotes (`U+201C`/`U+201D` → `"`, `U+2018`/`U+2019` → `'`) before map lookup. macOS Smart Quotes feature was replacing ASCII quotes, which aren't in the ЙЦУКЕН↔QWERTY map → quotes passed through unchanged.
- **`anyEditorVisible` property** in `UIManager` — auto-convert suppressed while word-list editor windows are open. Prevents auto-convert from interfering with typing in editor panels.
- **`isReplacing` didSet observer** — auto-logs START/END with duration for every conversion. Diagnostic for user-reported "backspace disabled" (shows exactly when/how long isReplacing was active).
- **Backspace loss diagnostic log** — logs when backspace is swallowed during `isReplacing` with empty `pendingCharacters` buffer (key lost).
- **Versioned DMG names** — `make-dmg.sh` reads `VERSION` → `dist/AliSwitcher-1.2.0.dmg`. Old DMGs cleaned before build (no more `AliSwitcher 2.dmg` copies).
- ~38 new tests (232 → 270 assertions): `hasMixedScript`, typographic quotes, single-char builtin-only rules (both directions), manual retro walk regression, all-caps conversion.

### Fixed
- **Single-char over-conversion** (#12): single-char words converted one direction (Latin→Cyrillic) but not the other. Now: a single-char converts ONLY if its result is in the builtin list — works both directions. `d→в ✓`, `f→а ✓`, `g→п ✗`, `q→й ✗`, `Ш→I ✓`, `ъ→] ✗`.
- **Mixed-script words blocked** (#11): `shouldConvert` now checks `hasMixedScript` BEFORE spell-checker (step 4d). Mixed → return conversion directly, no spell-checker.
- **Manual mode over-correction** (#14 → #16): PR #14 disabled ALL spell-checker in manual retro walk — valid words like «есть», «термин» had no guard → «есть термин АГВ» converted all 3 words. Fix: split into `origMisspelled` (runs in BOTH modes — stops on valid words) and `convValid` (auto-only per AGENTS.md). All-caps bypass for acronyms (ЕРФТЛ→THANK works).
- **Case-insensitive exception lists** (#8): words starting with uppercase (The, Мы, It) now match lowercase variants in exception lists. All operations (`isLearnedException`, `addException`, `saveWordsFromEditor`, `loadLearnedWords`) lowercase before insert/lookup.
- **«б» missing from RU builtins** (#9): Russian particle «б» was not in builtin list → single-char `б` passed shouldConvert → auto-convert fired on «ну ток я б» → «z ,».
- **Auto-convert in editor panels** (#12): auto-convert was firing while typing in word-list editor windows. Now suppressed via `anyEditorVisible` check.

### Changed
- `isReplacingTimeout`: 3.0s → 1.5s (conversions take ~0.4s, 4x safety margin). Reduces keyboard-dead window if conversion ever stalls.
- Builtins: English 906→109 words, Russian 612→80 words (removed Scrabble junk like `aa`, `bae`, `qi`, `xu`, `ви`, `нё` — kept only real common 1-3 char words).
- Removed «vs» from EN builtins (#7): `vs` on QWERTY = `мы` on ЙЦУКЕН — both were builtins, redundant. Kept only Russian variant.
- Added ё/е variants for Russian builtins (всё/все, ещё/еще, etc.).
- `minWordLength`: 2 → 1 (single-char words can trigger auto-convert, protected by builtin lists).
- `findConversionRange` retro walk: identical rules for manual and auto (was: `!isManual` guards on spell-checker). Exception: selection convert is still separate (no checks at all).
- `isBuiltinWord` now case-insensitive (lowercase lookup) — uppercase «I» no longer bypasses builtin check.
- `README.md` rewritten to cover all functionality.

### Removed
- Hardcoded builtin word arrays in `AutoSwitcher.swift` (replaced by txt files).
- Stale DMG files: `AliSwitcher 2.dmg`, `AliSwitcher 3.dmg`, `AliSwitcher 4.dmg`, `AliSwitcher 5.dmg`, `AliSwitcher.dmg` (replaced by single versioned `AliSwitcher-1.2.0.dmg`).

## [1.1.0] — 2026-08-22

### Added
- **Unified `findConversionRange`** — single algorithm shared between auto-convert and manual double-Shift. Last word always converts; previous words convert if same script + misspelled. Auto adds builtins/exceptions/convValid checks; manual skips all dictionary checks.
- **Generation token** (`state.generation`) — async callbacks capture generation at start, check before modifying state. Prevents race conditions when timeout fires mid-conversion (BUG #4/#5 fix).
- **`isFullyTypeable`** — universal typeability pre-check with script consistency. If any char can't be typed via QWERTY map → clipboard paste instead (BUG #2 fix).
- **`typedBufferIsFromConversion`** flag — buffer pollution prevention. After conversion, `typedBuffer = text` for toggle-back; new typing clears it. Fixes stale converted text leaking into next fragment.
- **`SwitcherState.swift`** — shared mutable state extracted from `main.swift` (busy, isReplacing, typedBuffer, generation, lastAutoConvertInfo, pendingCharacters).
- **`UIManager.swift`** — all UI (menu bar, status icon, permissions panel, word list editors, autostart prompt) extracted from `main.swift`.
- **Safety timeout** (3s) on `isReplacing` — force-reset if stuck, prevents keyboard blocking.
- **`isReplacingSince`** timestamp — tracks how long replacement has been running.
- **`lastGap`** in `ConversionPlan` — trailing boundary chars exposed separately. Auto-convert adds boundary char; manual adds the trailing gap back.
- 38 new tests (194 → 232): `findConversionRange` scenarios, `isFullyTypeable` cross-script, leading boundary math, trailing gap handling, exception/builtin retroactive behavior.

### Fixed
- **BUG #1 (HIGH)**: `convertTypedText` ate leading boundary chars (space, period). `parseBufferSegments` dropped them, but `deleteCount = chunk.count` included them → chars silently eaten. Fix: subtract leading boundary count.
- **BUG #2 (MEDIUM-HIGH)**: `type()` silently dropped non-QWERTY chars (emoji, diacritics). Old `hasCyrillic && hasLatin` check missed them. Fix: universal `isFullyTypeable` pre-check.
- **BUG #3 (MEDIUM)**: `undoAutoConvert` called `learnException` BEFORE `LayoutSwitch.select` guard. If layout switch failed, word added to exceptions but undo didn't happen. Fix: moved after guard.
- **BUG #4 (MEDIUM)**: Timeout force-reset didn't invalidate in-flight completion. Stale callback set `typedBuffer = text` after user already typed new text. Fix: generation token.
- **BUG #5 (MEDIUM)**: `.reset` (Tab/Enter) during `isReplacing` cleared `pendingCharacters`, but completion handler later overwrote `typedBuffer`. Fix: generation token incremented on `.reset`.
- **Buffer pollution**: after manual conversion, `typedBuffer = text` (for toggle-back). New typing appended to stale converted text → "если" leaked into "еслиляськи масяськи". Fix: `typedBufferIsFromConversion` flag.
- **Single-char toLatin in retroactive**: blocked in manual retroactive walk (was only in auto). Prevents cycles like О→J→О→J… and false positives (й→q).
- **Prefix duplication**: `convertTypedText` was retyping the prefix (text before conversion range that stays in field). Now types only `convertedText + lastGap`.

### Changed
- `AutoConvertDecision` replaced by `ConversionPlan` (no `fullConvertedText` field — callers construct it from `convertedText` + boundary char).
- `evaluateAutoConvert` delegates to `findConversionRange(isManual: false)`.
- `convertTypedText` delegates to `findConversionRange(isManual: true)` instead of inline retroactive walk.
- Builtins SKIPPED in retroactive mode (both auto and manual) — matches old `isRetroactive=true` behavior.
- `convValid` check added for auto multi-char retroactive words.
- `learnException` moved after `LayoutSwitch.select` guard in `undoAutoConvert`.
- DMG path: `build/AliSwitcher.dmg` → `dist/AliSwitcher.dmg`.
- `.gitignore`: `dist/` folder unignored (DMG installers tracked in git).
- Source files: 10 → 12 (SwitcherState.swift + UIManager.swift added).

### Removed
- Inline retroactive walk in `convertTypedText` (replaced by `findConversionRange`).
- Inline retroactive walk in `evaluateAutoConvert` (replaced by `findConversionRange`).
- `AutoConvertDecision` struct (replaced by `ConversionPlan`).
- `fullConvertedText` field (callers construct from parts).
- Old `hasCyrillic && hasLatin` mixed-script check (replaced by `isFullyTypeable`).
- Single-char toLatin block in auto retroactive (now handled in `findConversionRange`).

## [1.0.0] — 2026-08-21

### Initial release
- Double-Shift conversion (typed text + selected text)
- Auto-convert (Punto Switcher style) with NSSpellChecker
- Undo (double-Shift after auto-convert)
- Auto-learn exceptions (undo → block)
- Two independent word lists (enWords / ruWords)
- Built-in word lists (~100+ words per language)
- Retroactive conversion (multi-word fragments)
- Password field protection
- DMG installer
- Self-signed certificate (permissions survive rebuilds)
- 194 self-tests
