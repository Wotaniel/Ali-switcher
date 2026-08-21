# Changelog

All notable changes to AliSwitcher are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/), dates in ISO 8601.

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
