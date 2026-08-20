# AGENTS.md — AliSwitcher

## What is this project?

AliSwitcher — macOS layout switcher (RU↔EN only). Mini-analog of Punto/Caramba Switcher.

## Build / Test / Deploy

```bash
./build.sh                                    # Build → build/AliSwitcher.app
build/AliSwitcher.app/Contents/MacOS/AliSwitcher --test   # 66 self-tests
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

## Source files (10)

| File | Responsibility |
|---|---|
| `main.swift` | App, CGEventTap, performSwitch, tryAutoConvert, undoAutoConvert, Timing enum, menu, exceptions editor |
| `AutoSwitcher.swift` | shouldConvert, isNonConvertible, matchesDomainPattern, isMixedCase, boundaries |
| `KeyEvents.swift` | Synthetic key posting: backspace, type, copySelection, paste, undo |
| `KeyTracker.swift` | UCKeyTranslate, Action enum (.text/.deleteBackward/.reset/.ignore) |
| `Translit.swift` | ЙЦУКЕН↔QWERTY map, convert, isCyrillic, enOnSameKey |
| `ChunkFinder.swift` | UTF-16 script boundary detection (cyrillic↔latin) |
| `LayoutSwitch.swift` | TISSelectInputSource, currentIsRussian, toggle |
| `Accessibility.swift` | AXUIElement, focusedElement, secureField, selectedText, selectedRange |
| `Clipboard.swift` | ClipboardSnapshot, copy, restore |
| `SelfTests.swift` | `--test` flag, 66 tests |

## Critical patterns

### `busy` flag management
- `busy = true` in `triggerSwitch()`, `busy = false` in EVERY completion/cancel path
- NEVER use `defer { busy = false }` — async paths outlive the function scope
- After ANY change to performSwitch flow, check ALL return paths for busy reset
- **Lesson recorded**: `/memories/repo/ali-switcher-huge-fuckup-toggle.md`

### `typedBuffer` state (stale buffer = broken spaces)
- After `replaceByDeleting`: `typedBuffer = text` (replaced with converted text → toggle works)
- After `convertSelectionViaClipboard`: `typedBuffer = ""` (cleared)
- Stale buffer → auto-convert fires on wrong data → blocks space key permanently

### `performSwitch` priority order
1. `secureField` → skip
2. `lastAutoConvertInfo` → `undoAutoConvert` (backspace + retype original)
3. AX selection (non-empty) → `convertSelectionViaClipboard` (ALWAYS clipboard, even if buffer not empty)
4. `lastWasSelectionConvert` + buffer empty → `KeyEvents.undo()` (Cmd+Z toggle)
5. Buffer not empty → `convertTypedText` (backspace + retype)
6. Fallback → `convertSelectionViaClipboard`

### Auto-learn exceptions
- `autoLearnExceptions` (default ON): undoing auto-convert adds word pair to learnedWords as exception
- Works for both `undoAutoConvert` (double-Shift undo) and `convertSelectionViaClipboard` (selection undo)
- Learned words persisted in `UserDefaults["learnedWords"]` as `[String]` (`"formA\tformB\texc"` or `"formA\tformB\tdict"`)
- Menu: "Auto-Learn Exceptions" toggle + "Words…" editor (format: `! word1 word2` = exception, `word1 word2` = dictionary)

## What NOT to do

- Don't add text polishing (е→ё, em-dashes, smart quotes) — this is a **layout** switcher
- Don't add app exclusion lists — edge-case detection handles code context instead
- Don't touch `isMixedCase` to block conversions — spell-checker is the gatekeeper
- Don't forget to rebuild DMG after code changes
- Don't use `defer { busy = false }` in async methods

## Business logic rules (CRITICAL — think before coding!)

**Unified learned words list — exceptions and dictionary in ONE list:**

| Field | Type | Description |
|---|---|---|
| `AutoSwitcher.learnedWords` | `[LearnedWord]` | Unified list. Each entry has `formA`, `formB`, `isException` |
| `LearnedWord.isException` | `Bool` | `true` = exception (don't auto-convert), `false` = dictionary (force-convert) |
| `AutoSwitcher.lookupLearned(_:)` | `LearnedWord?` | Directional: prioritizes `formA` match over `formB` (exceptions only block original direction) |
| `learnedWords` (UserDefaults) | `[String]` | Stored as `"formA\tformB\texc"` or `"formA\tformB\tdict"` |

**Exception** = user undoes an auto-convert → word pair stored with `isException: true`
→ `shouldConvert` returns nil for that word **only when `word == formA`** (directional).
→ `formB` (reverse direction) is NOT blocked — `lookupLearned` prioritizes formA matches.

**Dictionary** = user manually converts text (genuine, not undo) → stored with `isException: false`
→ `shouldConvert` skips spell-checker for that word (works both directions via formA or formB match).

**NEVER call `learnCustomDictionary` when the conversion is an undo of an auto-convert.**
If the user auto-converts «мд»→«vl», then selects «vl» and double-Shifts it back — that's
an **exception** (don't convert «мд» next time), NOT a dictionary word.
The `wasExceptionUndo` flag in `convertSelectionViaClipboard` guards this.

**Deduplication — no entry multiplication:**
- `addLearnedPair` ALWAYS removes matching entries before adding (dedup by any form match)
- Toggle cycle (undo → manual convert → undo) replaces entries, never multiplies
- `loadLearnedWords` deduplicates on load: same type in both directions = keep one
- Different types for same pair (exc + dict in different directions) = keep BOTH (serves different directions via formA priority)
- Log shows "replaced N old entries" when dedup occurs

**Senior developer checklist before any change:**
1. What is the business meaning of this data path? (undo vs genuine conversion)
2. What happens if this code runs in EVERY possible scenario? (exception undo, manual convert, toggle, fallback)
3. Are there two opposing concepts that could get crossed? (exceptions vs dictionary)
4. What state survives across keystrokes vs what's cleared? (recentAutoConvertedWords vs lastAutoConvertInfo)
5. Does every panel/window close path restore `activationPolicy` to `.accessory`?

**The developer of this codebase is a senior engineer who prioritizes:**
- Business logic correctness over clever shortcuts
- Structural clarity — every data path should be traceable
- Reliability — every async path, every close button, every edge case must be handled
- Thinking through ALL scenarios before writing code, not after_user覈complains
