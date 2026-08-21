# AGENTS.md — AliSwitcher

## What is this project?

AliSwitcher — macOS layout switcher (RU↔EN only). Mini-analog of Punto/Caramba Switcher.

## Build / Test / Deploy

```bash
./build.sh                                    # Build → build/AliSwitcher.app
build/AliSwitcher.app/Contents/MacOS/AliSwitcher --test   # 232 self-tests
ditto build/AliSwitcher.app /Applications/AliSwitcher.app # Deploy
killall AliSwitcher; open /Applications/AliSwitcher.app   # Restart
./make-dmg.sh                                 # Build DMG installer → dist/AliSwitcher.dmg
```

## Versioning

- Version stored in `VERSION` file (e.g. `1.1.0`)
- `build.sh` reads it → writes to `CFBundleShortVersionString` + `CFBundleVersion` in Info.plist
- `kAppVersion` constant in `main.swift` reads from bundle at runtime
- About panel shows version via `kAppVersion`
- To bump version: edit `VERSION` file, rebuild

## Icon

- `make-icon.sh` generates `build/AliSwitcher.icns` from `build/icon-1024.png`
- `make-icon.sh` does NOT overwrite an existing `build/icon-1024.png` — custom icons are preserved
- To use a custom icon: replace `build/icon-1024.png`, delete `build/AliSwitcher.icns`, rebuild
- `build.sh` always calls `make-icon.sh` (it's safe — won't overwrite PNG)

**ALWAYS rebuild DMG after code changes** — `dist/AliSwitcher.dmg` goes stale.

## Tech stack

- Swift via `swiftc` (NOT SwiftPM), universal binary (arm64 + x86_64)
- `build.sh` uses `Sources/AliSwitcher/*.swift` glob — picks up all .swift files
- Builds in `/tmp` to avoid iCloud FileProvider corrupting signatures
- macOS 13+, uses swiftly toolchain if available

## Source files (12)

| File | Responsibility |
|---|---|
| `main.swift` | App lifecycle, CGEventTap, handle(), performSwitch, tryAutoConvert, undoAutoConvert, convertTypedText, Timing enum |
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
| `SelfTests.swift` | `--test` flag, 232 tests |

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

**Built-in word lists** (in code, ~100+ words each):
- `builtinEnWords` — common English words (the, is, a, I, he, it, was, for, …)
- `builtinRuWords` — common Russian words (что, она, юае, а, в, и, …)
- Checked via `isBuiltinWord(_:)` — dispatches by script
- In retroactive mode (user typed wrong layout), builtins are **skipped** — even common words should be converted

**`shouldConvert` priority order** (each step can return early):
1. Length/letters/uppercase/digits/underscores/URLs — structural filters
2. `Translit.convert` must succeed
3. **4a) Builtin words** → return nil (skip, unless retroactive)
4. **4b) Word list exception** → return nil (user undid this before)
5. **4c) Single-char retroactive** → only `.toCyrillic` (Latin→Russian), NOT `.toLatin`
6. **5–6) Spell-checker** (NSSpellChecker): orig must be misspelled + converted must be valid

### `findConversionRange` — unified conversion algorithm
- Shared between auto-convert (`isManual: false`) and manual double-Shift (`isManual: true`)
- **Last word**: ALWAYS converts (no checks for manual; `shouldConvert` for auto)
- **Retroactive walk**: previous words convert if same script + misspelled in own language
- **Auto-only checks** in retroactive: exceptions block, converted must be valid in target language, builtins SKIPPED (retroactive mode)
- **Manual-only**: no builtins, no exceptions, no convValid — user explicitly asked to convert
- **Single-char words**: convert in retroactive (size doesn't matter). In auto: single-char toLatin BLOCKED in trigger, but works in retroactive
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

## Business logic rules (CRITICAL — think before coding!)

**Two independent word lists — direction is implicit in the word's script:**

| Field | Type | Description |
|---|---|---|
| `AutoSwitcher.enWords` | `Set<String>` | Latin words user undid — blocks auto-convert (Latin→Russian) |
| `AutoSwitcher.ruWords` | `Set<String>` | Cyrillic words user undid — blocks auto-convert (Russian→Latin) |
| `builtinEnWords` / `builtinRuWords` | `Set<String>` | ~100+ common words per language, hardcoded in AutoSwitcher.swift |
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
→ Checked BEFORE learned words and spell-checker in `shouldConvert`.
→ Skipped in retroactive mode (user typed wrong layout → even common words need conversion).
→ Examples: English (the, is, a, I, he), Russian (что, она, юае, а, в).

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
- Thinking through ALL scenarios before writing code, not after_user覈complains
