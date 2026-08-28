# AGENTS.md — AliSwitcher

## What is this project?

AliSwitcher — macOS layout switcher (RU↔EN only). Mini-analog of Punto/Caramba Switcher.

## Build / Test / Deploy

```bash
./build.sh                                    # Build → build/AliSwitcher.app
build/AliSwitcher.app/Contents/MacOS/AliSwitcher --test   # ~270 self-tests
ditto build/AliSwitcher.app /Applications/AliSwitcher.app # Deploy
killall AliSwitcher; open /Applications/AliSwitcher.app   # Restart
./make-dmg.sh                                 # Build DMG installer → dist/AliSwitcher-<version>.dmg
```

## Versioning

- Version stored in `VERSION` file (e.g. `1.2.0`)
- `build.sh` reads it → writes to `CFBundleShortVersionString` in Info.plist
- `CFBundleVersion` = git commit count (always increases, distinguishes builds within same version)
- `GitHash` custom plist key = git short commit hash (for identification)
- `kAppVersion`, `kBuildNumber`, `kGitHash` constants in `main.swift` read from bundle at runtime
- About panel shows: `Version 1.2.0 (build N, abc1234)`
- To bump version: edit `VERSION` file, rebuild
- DMG files are versioned: `dist/AliSwitcher-1.2.0.dmg` (make-dmg.sh reads VERSION)

## Icon

- `make-icon.sh` generates `build/AliSwitcher.icns` from `build/icon-1024.png`
- `make-icon.sh` does NOT overwrite an existing `build/icon-1024.png` — custom icons are preserved
- To use a custom icon: replace `build/icon-1024.png`, delete `build/AliSwitcher.icns`, rebuild
- `build.sh` always calls `make-icon.sh` (it's safe — won't overwrite PNG)

**ALWAYS rebuild DMG after code changes** — `dist/AliSwitcher-<version>.dmg` goes stale.
`make-dmg.sh` cleans old DMGs (`rm -f dist/AliSwitcher*.dmg`) before building.

## Tech stack

- Swift via `swiftc` (NOT SwiftPM), universal binary (arm64 + x86_64)
- `build.sh` uses `Sources/AliSwitcher/*.swift` glob — picks up all .swift files
- Builds in `/tmp` to avoid iCloud FileProvider corrupting signatures
- macOS 13+, uses swiftly toolchain if available

## Source files (14)

| File | Responsibility |
|---|---|
| `main.swift` | App lifecycle, CGEventTap, handle(), performSwitch, tryAutoConvert, undoAutoConvert, convertTypedText, Timing enum |
| `Logger.swift` | Logger with levels (.debug/.info/.warn/.error), file rotation (1MB, 3 files), path ~/Library/Logs/AliSwitcher.log, level via UserDefaults |
| `Permissions.swift` | Permission status checks (accessibilityGranted, inputMonitoringGranted, allGranted), open System Settings panes |
| `SwitcherState.swift` | Shared mutable state: busy, isReplacing, typedBuffer, generation (token), lastAutoConvertInfo, pendingCharacters |
| `UIManager.swift` | Menu bar, status icon, permissions panel, word list editors, autostart prompt |
| `AutoSwitcher.swift` | findConversionRange (unified), evaluateAutoConvert, shouldConvert, parseBufferSegments, builtin words (EN+RU), two word lists (enWords/ruWords), boundaries |
| `KeyEvents.swift` | Synthetic key posting: backspace, type, isFullyTypeable, canType, copySelection, paste, undo, replay |
| `KeyTracker.swift` | UCKeyTranslate, Action enum (.text/.deleteBackward/.reset/.ignore) |
| `Translit.swift` | ЙЦУКЕН↔QWERTY map, convert, isCyrillic, enOnSameKey |
| `ChunkFinder.swift` | UTF-16 script boundary detection (cyrillic↔latin) |
| `LayoutSwitch.swift` | TISSelectInputSource, currentIsRussian, toggle |
| `Accessibility.swift` | AXUIElement, focusedElement, secureField, selectedText, selectedRange |
| `Clipboard.swift` | ClipboardSnapshot, copy, restore |
| `SelfTests.swift` | `--test` flag, ~270 check() assertions |

## Builtin word lists (external files)

- `Sources/AliSwitcher/builtin_words_en.txt` — common English 1-3 char words (109 words)
- `Sources/AliSwitcher/builtin_words_ru.txt` — common Russian 1-3 char words (80 words)
- One word per line; lines starting with `#` are comments
- Loaded at startup via `Bundle.main` → `builtinEnWords` / `builtinRuWords` (Set<String>)
- `build.sh` copies both to `Contents/Resources/`
- Fallback to empty set if file missing (e.g. running from CLI without bundle)
- All words lowercase; `isBuiltinWord` lowercases before lookup (case-insensitive)
- NOT hardcoded in Swift — edit txt files freely, rebuild to apply

## Critical patterns

### `busy` flag management
- `busy = true` in `triggerSwitch()`, `busy = false` in EVERY completion/cancel path
- NEVER use `defer { busy = false }` — async paths outlive the function scope
- After ANY change to performSwitch flow, check ALL return paths for busy reset
- **Lesson recorded**: `/memories/repo/ali-switcher-huge-fuckup-toggle.md`

### `typedBuffer` state (stale buffer = broken spaces)
- After `replaceByDeleting`: `typedBuffer = text`, `typedBufferIsFromConversion = true` (replaced with converted text → toggle works)
- After `convertSelectionViaClipboard`: `typedBuffer = ""` (cleared)
- New typing clears buffer if `typedBufferIsFromConversion` is true — prevents stale converted text polluting the next fragment
- Stale buffer → auto-convert fires on wrong data → blocks space key permanently

### `performSwitch` priority order
1. `secureField` → skip
2. `lastAutoConvertInfo` (if set) + `!hasNewText` → `undoAutoConvert` (backspace + retype original). If `hasNewText` → clear info, fall through to convert
3. AX selection (non-empty) → `convertSelectionViaClipboard` (ALWAYS clipboard, even if buffer not empty)
4. `lastWasSelectionConvert` + buffer empty → `KeyEvents.undo()` (Cmd+Z toggle)
5. Buffer not empty → `convertTypedText` (backspace + retype)
6. Fallback → `convertSelectionViaClipboard`

### Generation token (BUG #4/#5 fix)
- `state.generation: UInt64` — incremented on timeout force-reset and `.reset` during isReplacing
- Every async callback captures `gen` at start, checks `state.generation == gen` before modifying state
- Stale callbacks become no-ops — prevents race conditions when timeout fires mid-conversion

### Two independent word lists

Direction is **implicit in the word's script** (alphabet). Two simple `Set<String>` — no struct, no pairs, no flags, no dictionary concept.

**2 word lists** (directly persisted to UserDefaults):

| Set | Script | Purpose |
|---|---|---|
| `enWords` | Latin | Latin words user undid — block auto-convert (Latin→Russian) |
| `ruWords` | Cyrillic | Cyrillic words user undid — block auto-convert (Russian→Latin) |

**`addException(_ word:)`** routes by script: Latin → `enWords`, Cyrillic → `ruWords`.

**Built-in word lists** (external txt files, ~80-109 words each):
- `builtinEnWords` — common English 1-3 char words (the, is, a, I, he, it, …)
- `builtinRuWords` — common Russian 1-3 char words (что, она, а, в, и, …)
- Loaded from `builtin_words_en.txt` / `builtin_words_ru.txt` in app bundle
- Checked via `isBuiltinWord(_:)` — dispatches by script (case-insensitive)
- In retroactive mode (user typed wrong layout), builtins are **skipped** — even common words should be converted

**`shouldConvert` priority order** (each step can return early):
1. Length/letters/uppercase/digits/underscores/URLs — structural filters
2. `Translit.convert` must succeed
3. **4a) Builtin words** → return nil (skip, unless retroactive)
4. **4b) Word list exception** → return nil (user undid this before)
5. **4c) Single-char words** → convert ONLY if result is in builtin list (both directions: `d→в ✓`, `f→а ✓`, `g→п ✗`, `Ш→I ✓`, `ъ→] ✗`)
6. **4d) Mixed-script words** → `hasMixedScript` detects Cyrillic+Latin mix → convert directly (skip spell-checker)
7. **5–6) Spell-checker** (NSSpellChecker): orig must be misspelled + converted must be valid

### `findConversionRange` — unified conversion algorithm
- Shared between auto-convert (`isManual: false`) and manual double-Shift (`isManual: true`)
- **Last word**: ALWAYS converts (no checks for manual; `shouldConvert` for auto)
- **Retroactive walk**: previous words convert if same script + misspelled in own language
- **Spell-checker in retro walk**: `origMisspelled` runs in BOTH modes. `convValid` (converted must be valid in target) runs in BOTH modes when `origMisspelled=false` (word valid in source). All-caps words bypass spell-checker (NSSpellChecker treats them as valid acronyms → ЕРФТЛ→THANK works)
- **Direction priority** (both modes): if word is valid in source AND converted is valid in target → word exists in both dictionaries → CONVERT (direction decides: EN→RU → Russian wins, RU→EN → English wins). If valid in source but NOT in target → STOP. Example: «vs»→«мы» both valid → convert; «by»→«ин» «ин» invalid in RU → stop
- **Auto-only checks** in retroactive: exceptions block, `convValid` for gibberish words (origMisspelled=true); builtins SKIPPED (retroactive mode)
- **Manual-only**: no exceptions, no `convValid` for gibberish words — user explicitly asked to convert
- **Single-char words**: convert in retroactive (size doesn't matter). In auto trigger: single-char converts only if result is builtin
- Returns `ConversionPlan` with: prefix, originalText, convertedText, lastGap, deleteCount, direction

### Auto-learn exceptions
- `autoLearnExceptions` (default ON): undoing auto-convert adds word to `enWords` or `ruWords` via `learnException(_:)`
- `learnException` called AFTER `LayoutSwitch.select` guard — if layout switch fails, word NOT added (BUG #3 fix)
- Works for both `undoAutoConvert` (double-Shift undo) and `convertSelectionViaClipboard` (selection undo)
- Word lists persisted in `UserDefaults["enWords"]` and `UserDefaults["ruWords"]` as `[String]` (one word per element)
- Menu: "Auto-Learn Exceptions" toggle + "English Words…" + "Russian Words…" editors
- Two separate windows: English (Latin words, one per line) and Russian (Cyrillic words, one per line)
- `saveWordsFromEditor` parses one word per line into `Set<String>`, replaces entire list
- No dictionary concept — manual convert does NOT learn anything

## What NOT to do

- Don't add text polishing (е→ё, em-dashes, smart quotes) — this is a **layout** switcher
- Don't add app exclusion lists — edge-case detection handles code context instead
- Don't forget to rebuild DMG after code changes
- Don't use `defer { busy = false }` in async methods
- Don't forget to normalize typographic quotes — macOS Smart Quotes replaces `"` with `\u201C`/`\u201D`, which aren't in the transliteration map. `Translit.convert()` already handles this.
- Don't add new hardcoded builtin words in Swift — use the txt files
- `isReplacingTimeout` is 1.5s (not 3s) — conversions take ~0.4s, 4x margin

## Business logic rules (CRITICAL — think before coding!)

**Two independent word lists — direction is implicit in the word's script:**

| Field | Type | Description |
|---|---|---|
| `AutoSwitcher.enWords` | `Set<String>` | Latin words user undid — blocks auto-convert (Latin→Russian) |
| `AutoSwitcher.ruWords` | `Set<String>` | Cyrillic words user undid — blocks auto-convert (Russian→Latin) |
| `builtinEnWords` / `builtinRuWords` | `Set<String>` | 80-109 common 1-3 char words, loaded from txt files in app bundle |
| `enWords` (UserDefaults) | `[String]` | One word per element, loaded/saved directly |
| `ruWords` (UserDefaults) | `[String]` | One word per element, loaded/saved directly |

**Direction is determined by script (alphabet), NOT by a field:**
- Latin word in `enWords` → blocks auto-convert in **Latin→Russian** direction only
- Cyrillic word in `ruWords` → blocks auto-convert in **Russian→Latin** direction only
- Lists are fully independent — no pairs, no reverse blocking

**Exception** = user undoes an auto-convert → word added to `enWords` or `ruWords` via `learnException(_:)`
→ `shouldConvert` returns nil — the word is in the exception list for its script.
→ Reverse direction is NOT blocked (different script → different list).

**No dictionary concept.** Manual convert (double-Shift on selection) does NOT learn anything.
There is no force-convert mechanism. Only undo (exception) learns.

**Built-in words** = safety net for common words NSSpellChecker may miss.
→ Checked BEFORE learned words and spell-checker in `shouldConvert` (trigger word only).
→ In retroactive walk: **auto mode** — builtins go through spell-checker (`origMisspelled` stops at valid words like «это», «из», «by»). **Manual mode** — builtins bypass spell-checker (user explicitly asked to convert).

**Deduplication — automatic via Set:**
- `enWords` and `ruWords` are `Set<String>` — duplicates impossible by construction
- `addException` simply inserts; Set handles dedup
- `saveWordsFromEditor` parses one word per line, creates new Set — old list fully replaced

**Senior developer checklist before any change:**
1. Which script (Latin/Cyrillic) does this word belong to? → `enWords` or `ruWords`?
2. Does this undo path call `learnException`? (it should)
3. What state survives across keystrokes vs what's cleared? (`recentAutoConvertedWords` vs `lastAutoConvertInfo`)
4. Does every panel/window close path restore `activationPolicy` to `.accessory`?
5. Is this a builtin word? → builtins block conversion (except in retroactive mode)
6. Manual convert should NOT learn anything — only undo learns

**The developer of this codebase is a senior engineer who prioritizes:**
- Business logic correctness over clever shortcuts
- Structural clarity — every data path should be traceable
- Reliability — every async path, every close button, every edge case must be handled
- Thinking through ALL scenarios before writing code, not after the user complains

## AI assistant anti-degradation checklist

Before making ANY change, read this section:

1. **Read AGENTS.md + relevant source files FIRST.** Don't guess from memory — read the actual code. Memory notes are for context, not for copying code patterns blindly.
2. **Run `--test` before AND after changes.** If tests fail before your change → fix the pre-existing failure first or report it.
3. **Manual vs auto:** manual = user double-Shifted = NO spell-checker, NO exceptions, NO builtins on the LAST word. BUT `origMisspelled` DOES run in manual retro walk — it stops on valid words like «есть». **Direction priority**: if word is valid in BOTH source and target → convert (direction's target wins). «vs»→«мы» both valid → convert. «by»→«ин» only «by» valid → stop.
4. **Single-char conversion rule:** a single-char converts ONLY if its result is in the builtin list. This works BOTH directions. Don't revert to the old one-directional rule.
5. **Mixed-script words:** `hasMixedScript` → skip spell-checker, convert directly. A word with both Cyrillic AND Latin = always wrong layout.
6. **Two independent word lists:** `enWords` (Latin) and `ruWords` (Cyrillic). Direction is implicit in script. No pairs, no dictionary, no force-convert. Don't re-introduce paired/structured exceptions.
7. **Builtin words are in txt files** (`builtin_words_en.txt` / `builtin_words_ru.txt`), NOT hardcoded in Swift. Add new words there.
8. **Case-insensitive** everything: `isLearnedException`, `addException`, `saveWordsFromEditor`, `loadLearnedWords`, `isBuiltinWord` — all lowercase before lookup/insert.
9. **Generation token** (`state.generation`): every async callback must capture `gen` at start and check `state.generation == gen` before modifying state.
10. **`typedBufferIsFromConversion`**: after conversion, buffer = converted text (for toggle-back). New typing clears it. Backspace during converted buffer also clears it.
11. **`anyEditorVisible`**: auto-convert is suppressed when word-list editor windows are open.
12. **Typographic quotes**: `Translit.convert()` normalizes `\u201C`/`\u201D` → `"` and `\u2018`/`\u2019` → `'` before map lookup.
13. **After ANY code change**: `./build.sh && ./make-dmg.sh` — rebuild both. The DMG goes stale.
14. **Communicate in Russian** if the user writes in Russian. English if English.
15. **`isWordLatin`** must find the first LETTER character (skip quotes/punctuation), not just check `word.first`. Otherwise `"nj` or `,tpdjpdhfnyjt` won't convert.
16. **`,` and `.`** map to `б` and `ю` on ЙЦУКЕН. They're in `boundaries` set, but `parseBufferSegments` must keep them INSIDE words when between/before letters (e.g. `djj,ot` = `вообще`). Trailing comma/period still = boundary. **Consecutive** `.,` (= `юб`) must also stay inside — `commaPeriodFollowedByLetter` looks through the WHOLE sequence, not just one char ahead.
17. **`isReplacingTimeout` is adaptive** (not fixed 1.5s). `computeIsReplacingTimeout(deleteCount:textLength:)` scales with conversion size. Large conversions (96 backspaces + 90 chars) need ~2.2s, small ones stay at 1.5s.
