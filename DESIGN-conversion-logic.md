# Design Document: AliSwitcher Conversion Logic

> **Status**: Design spec for Bug Fixes #1–#5  
> **Scope**: Auto-convert triggers, manual double-Shift, mixed-text handling, state management, error handling  
> **Date**: 2026-08-21

---

## Table of Contents

1. [Bug Inventory](#1-bug-inventory)
2. [Auto-convert Triggers](#2-auto-convert-triggers)
3. [Manual Double-Shift Logic](#3-manual-double-shift-logic)
4. [Mixed-text Handling](#4-mixed-text-handling)
5. [State Management](#5-state-management)
6. [Error Handling](#6-error-handling)
7. [Implementation Checklist](#7-implementation-checklist)

---

## 1. Bug Inventory

| # | Severity | Component | Summary |
|---|----------|-----------|---------|
| #1 | HIGH | `convertTypedText` | Leading boundary chars (space, period) eaten — `deleteCount = chunk.count` includes them but `fullText` doesn't |
| #2 | MED-HIGH | `KeyEvents.type` | Non-QWERTY chars (emoji, diacritics) silently dropped; mixed-script check only catches Cyrillic+Latin |
| #3 | MED | `undoAutoConvert` | `learnException` runs before `LayoutSwitch.select` — word added to exceptions even if layout switch fails undo never executes |
| #4 | MED | `SwitcherState` | Timeout force-reset doesn't invalidate in-flight `asyncAfter` completion callbacks — they fire later and corrupt state |
| #5 | MED | `SwitcherState` | `.reset` during `isReplacing` clears `pendingCharacters` but completion handler later sets `typedBuffer = text` — overrides the reset |

---

## 2. Auto-convert Triggers

### 2.1 When Exactly Should Auto-convert Fire?

**Definition**: Auto-convert = Punto-style silent correction. The user types in the wrong layout, hits a word boundary, and the app automatically backspaces and retypes the converted text — *without* the user doing anything extra.

**Trigger conditions (ALL must hold)**:

```
1. state.autoModeEnabled == true          ← user opted in
2. state.busy == false                    ← no conversion in progress
3. state.isReplacing == false             ← not mid-replacement
4. state.secureField == false             ← not a password field
5. event is NOT synthetic (not ours)     ← we don't auto-convert our own typing
6. KeyTracker decodes the key as .text(s) where s is exactly 1 char
7. AutoSwitcher.isBoundary(s) == true     ← it's a boundary (space, period, etc.)
8. evaluateAutoConvert(buffer, s) returns non-nil   ← conversion is needed
```

**Why each condition?** (causal reasoning):

- **(1)**: Auto-convert is opt-in. Some users find it disruptive. The menu toggle (`autoModeEnabled`) is the explicit user consent gate.
- **(2)**: If a conversion is already running (busy), we must not start another. Re-entrant conversions cause overlapping backspace/type chains that corrupt field text.
- **(3)**: `isReplacing` means synthetic backspace/type events are in-flight. Auto-convert during this window would backspace into the wrong position.
- **(4)**: Password fields must never be read or modified. `secureField` is detected at the start of a fragment and cached.
- **(5)**: Our own synthetic key events (posted via `CGEventSource(.privateState)`) must not trigger auto-convert checks. Otherwise the re-typed converted word would be re-evaluated, causing infinite loops.
- **(6)**: Only printable characters can be boundaries. Modifier key presses, function keys, etc. are not boundaries.
- **(7)**: Only "universal" punctuation can trigger (characters that are identical in both layouts). For example, `;` is `ж` in RU layout — it would break words like `db;e` apart incorrectly. But `.` is `.` in both layouts → safe boundary. See `AutoSwitcher.boundaries` for the exact set.
- **(8)**: `evaluateAutoConvert` is the pure decision function. It checks the last word's convertibility via `shouldConvert` (spell-checker + builtin lists + exception lists). Returns `nil` = no conversion needed → boundary char passes through normally.

### 2.2 The Blocking Mechanism

When auto-convert fires, the boundary character is **blocked** (`return nil` in the event handler). It is re-typed *after* the conversion completes (appended to `fullConvertedText`). This is critical:

**Why?** The boundary char has already been posted to the HID system by the time the event tap sees it. If we block it, the app never receives it. We re-type it as the last character of `fullConvertedText`. If we *didn't* block it, the boundary char would already be printed after the word — and our backspace count (which only counts the word, not the boundary) would erase characters before the boundary, not the word itself.

```
Without blocking:  field = "ghbdtn " ← space already typed
                   backspace 6 → "ghbdtn" → backspace removed wrong chars
                   WRONG: deletes 6 starting from AFTER the space

With blocking:     field = "ghbdtn" ← space blocked
                   backspace 6 → "" → type "привет "
                   CORRECT: deletes the word, types converted + space
```

### 2.3 Single-char Word Handling

**Decision**: `minWordLength = 2` for the trigger word. Single-char words **never** trigger auto-convert.

**Why?** A single character provides insufficient signal to determine wrong layout. The letter `f` could be a legitimate English letter or a mis-typed Russian `а`. Without more context (a multi-char word), the spell-checker can't distinguish: NSSpellChecker considers all single letters "valid" in English. Converting on a single char would create massive false positives.

**What goes wrong without this?** Every isolated letter followed by a space (`f `, `d `, `s `) would be checked and potentially converted. The user's normal typing would be constantly interrupted.

**Retroactive mode** (inside `evaluateAutoConvert`'s backwards walk):

When a multi-char word already proved the user is in the wrong layout, we **walk backwards** to convert previous words that are also in the wrong layout (same direction). In this retroactive walk, `minLength` drops to 1.

| Direction | Single-char allowed? | Why? |
|-----------|---------------------|------|
| `.toCyrillic` (Latin → Cyrillic) | ✅ YES | Unambiguous: there's only one Cyrillic letter per QWERTY key. `f` → `а` is the correct conversion. No cycles possible. |
| `.toLatin` (Cyrillic → Latin) | ❌ NO | Cycles and false positives. `о` → `j` is technically correct, but: (a) the Cyrillic letter `о` is also a valid Russian word, (b) it creates cycles: type `о` → auto-convert to `j` → if user is now in EN layout and types more, `j` might get retroactively converted back. The spell-checker can't reliably stop these because single-char valid words are inconsistent across spell-checker versions. |

**Current code**: 
- `evaluateAutoConvert` retroactive walk: **already blocks** single-char `.toLatin` ✅ (line with `if prevSeg.word.count == 1, prevResult.direction == .toLatin { break }`)
- `convertTypedText` retroactive walk (manual double-Shift): **does NOT block** single-char `.toLatin` ❌

**Design decision**: Block single-char `.toLatin` in the retroactive walk of `convertTypedText` too. This is a new requirement — see §3.4 below.

**Edge cases handled**:
- `я ghbdtn ` → "я" is a single-char Cyrillic that converts to `z` (.toLatin). Walk starts from "ghbdtn" (.toCyrillic). Different direction → walk stops immediately. No issue.
- `ghbdtnrjy ` → last word "rjy" → converts to "ком" (.toCyrillic). Retroactive walk sees "ghbdtn" → converts to "привет" (.toCyrillic). Same direction, both multi-char → converts. ✅
- `ghbdtn f ` → last word "f" (.toCyrillic). Retroactive walk: "ghbdtn" (.toCyrillic) → converts. Then "f" is the trigger (it would have to be ≥2 chars to trigger, so this wouldn't happen via auto-convert. Only via manual.)

### 2.4 Built-in Word Lists in Retroactive Mode

**Decision**: Built-in words (`builtinEnWords`, `builtinRuWords`) are **skipped** (not checked) in retroactive mode.

**Why?** The user was already typing in the wrong layout (proven by the trigger word). Even common words like "the" or "что" should be converted — the user typed them in the wrong layout. If we blocked builtins in retroactive, the user would get a partially-converted sentence: "ghbdtn что" → "привет что" (only "ghbdtn" converted, "что" blocked as builtin). That's worse than no conversion.

**What goes wrong without this?** Partial conversions. The user must double-Shift again to convert the remaining words, defeating the purpose of retroactive mode.

**Current code**: `isBuiltinWordRetrospective(word, retroactive:)` returns `false` when `retroactive == true`. ✅

### 2.5 Spell-checker in Retroactive

**Decision**: Retroactive multi-char words **must still pass** the "original is misspelled in its own language" check.

**Why?** A valid word in its own language means it was typed intentionally. Example: "by" is a valid English word. In retroactive mode after converting "ghbdtn" → "привет" (.toCyrillic), "by" → converts to "ин" (.toCyrillic). Same direction. BUT "by" is correctly spelled in English → `origMisspelled = false` → walk stops. This prevents converting intentional English words that happen to be convertible.

**What goes wrong without this?** "by ghbdtn" → "ин привет" — "by" was intentional but got converted. The user would have to undo every time they type a short English word before a wrong-layout word.

**Single-char exception**: Single-char retroactive words skip the spell-check (NSSpellChecker considers all single letters "valid", so the check is meaningless). They rely entirely on:
1. The direction check (must match the trigger word's direction)
2. For `.toLatin`: blocked entirely (see §2.3)

---

## 3. Manual Double-Shift Logic

### 3.1 Priority Order in `performSwitch`

When the user presses double-Shift, the switch follows this priority:

```
1. secureField                  → skip entirely (don't touch passwords)
2. lastAutoConvertInfo + no new → undoAutoConvert (revert last auto-convert)
3. AX selection (non-empty)    → convertSelectionViaClipboard (Cmd+C/V)
4. lastWasSelectionConvert +    → KeyEvents.undo() (Cmd+Z toggle)
   buffer empty
5. Buffer not empty             → convertTypedText (backspace + retype)
6. Fallback                      → convertSelectionViaClipboard (buffer empty, no selection → toggle)
```

**Step 2**: "No new text" means `typedBuffer` contains only boundary characters (spaces, punctuation). If the user typed new *letters* after the auto-convert, they want those converted, not the previous conversion undone. The `hasNewText` check:

```swift
let hasNewText = state.typedBuffer.contains { !AutoSwitcher.isBoundary($0) }
```

**Why?** After auto-convert, the undo window is open. The user has two choices: double-Shift to undo, or keep typing. If they keep typing letters, those letters are the new intent → undo is invalid → clear `lastAutoConvertInfo` and convert the new text. If they only typed spaces/punctuation (e.g., continuing the sentence), the undo is still valid.

### 3.2 `convertTypedText` — Sources of Text

`convertTypedText` uses one of two text sources for `ChunkFinder`:

1. **Real field text** (if Accessibility is available) — `realTextBeforeCaret()`
2. **Typing buffer** (fallback for Electron apps without AX) — `state.typedBuffer`

**Why prefer real text?** The buffer can drift (especially in apps that reorder input, like IME-based text entry). The real field text is ground truth. But many apps (VS Code, Electron-based) don't expose AX text → buffer is the only option.

**Why fall back to buffer?** Without AX, there's no way to know what text is before the caret. The buffer tracks every keystroke via `KeyTracker.action`. It's imperfect (doesn't track clipboard pastes, deletions via mouse selection) but it's the best available signal.

### 3.3 BUG #1 Fix: Leading Boundary Chars

**Problem**: `ChunkFinder.chunkStart` returns a chunk that may begin with boundary characters (space, period). `parseBufferSegments` skips leading boundaries — they don't appear in any segment. But `deleteCount = chunk.count` includes them. Result: leading boundaries are deleted but not re-typed → silently eaten.

**Traced example**:
```
Field:   "abc привет"
Care:    at end (index 10)
Chunk:   " привет"        ← ChunkFinder returns this (space is "transparent")
Parsed:  [("привет", "")] ← leading space is consumed by segment parser
ToType:  "ghbdtn"          ← prefix="" + convertedText="ghbdtn"
Delete:  chunk.count = 7   ← includes the leading space!
Result:  "abcghbdtn"       ← space eaten!
```

**Root cause**: `deleteCount = chunk.count` (full chunk size) ≠ `fullText.count` (segment words only, leading boundaries excluded). The mismatch comes from `parseBufferSegments` dropping leading boundary chars that `ChunkFinder` includes.

**Fix**: Calculate the count of leading boundary characters and subtract from `deleteCount`:

```swift
let leadingBoundaryCount = chunk.prefix(while: { AutoSwitcher.isBoundary($0) }).count
let deleteCount = chunk.count - leadingBoundaryCount
```

**Why subtract (not retype)?** If we subtract, the leading boundaries stay in the field untouched — they were never the user's "wrong layout" text, just spacing. Retyping them would work for simple spaces/periods, but would fail for non-QWERTY boundaries (em-dash `—`, ellipsis `…`) that `type()` can't handle (BUG #2). Subtracting is safer: **don't touch what doesn't need changing**.

**Trailing boundaries**: Already handled correctly — they're captured in the last segment's `gap` field and included in `convertedText`, so they're part of both `deleteCount` and `fullText`.

### 3.4 Single-char `.toLatin` in Manual Retroactive

**Current state**: `convertTypedText` does NOT block single-char `.toLatin` in its retroactive walk. It relies on spell-check to stop it (NSSpellChecker considers single letters "valid" → `origMisspelled = false` → break).

**Problem**: This is fragile:
1. NSSpellChecker behavior for single chars is not guaranteed across macOS versions.
2. Some Cyrillic chars like `щ` → `o` could be considered "misspelled" by certain spell-checker configurations.
3. Even if spell-check stops it, the design intent should be explicit — relying on a side effect of NSSpellChecker is an implicit invariant that's hard to reason about.

**Fix**: Add an explicit check in `convertTypedText`'s retroactive walk:

```swift
if prevSeg.word.count == 1, prevResult.direction == .toLatin {
    break  // Single-char toLatin blocked (cycles, false positives)
}
```

**Why?** Same reasoning as auto-convert (§2.3): single-char Cyrillic→Latin is ambiguous — the Cyrillic letter is likely intentional (it's a valid word like `о`, `а`, `я`), and converting it creates cycles.

**What about single-char `.toCyrillic`?** Allowed — `f` → `а` is the correct retroactive conversion. The Latin letter was almost certainly typed in the wrong layout (since the trigger word already proved wrong layout). No cycles possible (Latin → Cyrillic is one-directional in the retroactive context).

### 3.5 `hasNewText` Check — Why It's Correct

The `hasNewText` check is already correct:

```swift
let hasNewText = state.typedBuffer.contains { !AutoSwitcher.isBoundary($0) }
```

**Why?** After auto-convert:
- The converted text is typed by our synthetic events → tracked in `typedBuffer` (we call `trackTypedAction(.text(text))`).
- If the user presses double-Shift immediately: buffer = converted text (all letters) → `hasNewText = true`.

Wait — that's actually the PROBLEM! The converted text IS typed into the buffer by our own synthetic events. So `hasNewText` would be `true` even right after auto-convert, preventing undo.

**Actually**: Looking at the code more carefully, `tryAutoConvert` clears the buffer BEFORE the conversion:

```swift
state.typedBuffer = ""  // ← cleared before backspace/type chain
```

Then in the auto-convert completion handler, `typedBuffer` is NOT set (unlike `replaceByDeleting` which sets `typedBuffer = text`). Only `lastAutoConvertInfo` is set. So the buffer is empty after auto-convert.

If the user doesn't type anything after auto-convert: buffer is empty → `hasNewText = false` → undo path. ✅

If the user types letters after auto-convert: buffer has letters → `hasNewText = true` → convert path. ✅

If the user types only spaces after auto-convert: buffer = "  " → `hasNewText = false` → undo path. ✅ (spaces are boundaries)

**This is correct.** The `hasNewText` check works because:
1. Auto-convert clears the buffer before converting
2. Auto-convert doesn't set the buffer after converting (unlike manual conversion)
3. Only real user keystrokes repopulate the buffer
4. Only non-boundary characters count as "new text"

---

## 4. Mixed-text Handling

### 4.1 When to Use Clipboard Paste vs Key-by-Key Typing

**Two mechanisms**:

| Mechanism | Function | How it works | Constraints |
|-----------|----------|-------------|-------------|
| Key typing | `replaceByDeleting` | `KeyEvents.backspace(N)` + `KeyEvents.type(text)` | Only chars with QWERTY key positions. No emoji, no diacritics. |
| Clipboard | `replaceByClipboard` | `KeyEvents.backspace(N)` + `Clipboard.copy(text)` + `KeyEvents.paste()` | Any Unicode text. But: temporarily overwrites clipboard. |

**Current check** (BUG #2):

```swift
let hasCyrillic = fullText.contains { Translit.isCyrillic($0) }
let hasLatin = fullText.contains { $0.isLetter && !Translit.isCyrillic($0) }
if hasCyrillic && hasLatin {
    replaceByClipboard(...)
} else {
    replaceByDeleting(...)
}
```

This checks for mixed Cyrillic + Latin scripts. But it misses:

| Scenario | hasCyrillic | hasLatin | Current result | Actual problem |
|----------|-------------|----------|----------------|----------------|
| `"привет мир"` → `"ghbdtn vbh"` | No | Yes | `replaceByDeleting` | ✅ Correct (all Latin, typeable in EN layout) |
| `"привет vbh"` (mixed) | Yes | Yes | `replaceByClipboard` | ✅ Correct |
| `"ghbdtn 🎉"` | No | Yes | `replaceByDeleting` | ❌ Emoji dropped by `type()` |
| `"ghbdtn é"` | No | Yes | `replaceByDeleting` | ❌ `é` not in qwerty map → dropped |
| `"ghbdtn —"` | No | Yes | `replaceByDeleting` | ❌ `—` not in qwerty map → dropped |

### 4.2 Fix: Typeability Check

Replace the mixed-script check with a **universal typeability check**:

```swift
static func isFullyTypeable(_ text: String, toRussian: Bool) -> Bool {
    for ch in text {
        let source: Character = (toRussian ? Translit.enOnSameKey(ch) : nil) ?? ch
        if qwerty[source] == nil { return false }
    }
    return true
}
```

Usage in `convertTypedText`:

```swift
let toRussian = direction == .toCyrillic
if !KeyEvents.isFullyTypeable(fullText, toRussian: toRussian) {
    replaceByClipboard(fullText, deleteCount: deleteCount)
} else {
    replaceByDeleting(fullText, deleteCount: deleteCount, toRussian: toRussian)
}
```

**Why does this work?**

The `type()` function maps characters through the QWERTY map. For each character `ch`:

- **If `toRussian == true`** (typing in Russian layout):  
  `source = enOnSameKey(ch) ?? ch`  
  - Cyrillic `ch` → `enOnSameKey` returns the English key → found in `qwerty` ✓  
  - Latin `ch` → `enOnSameKey` returns nil → `source = ch` → found in `qwerty` ✓ (types as the Russian equivalent)  
  - Emoji `ch` → `enOnSameKey` returns nil → `source = ch` → NOT in `qwerty` ✗

- **If `toRussian == false`** (typing in English layout):  
  `source = ch` (no enOnSameKey)  
  - Latin `ch` → directly in `qwerty` ✓  
  - Cyrillic `ch` → NOT in `qwerty` ✗ (Cyrillic chars are not QWERTY keys)  
  - Emoji `ch` → NOT in `qwerty` ✗

So the typeability check handles ALL three cases:
1. **Mixed scripts** (Cyrillic + Latin in English layout): Cyrillic chars fail → clipboard ✅
2. **Emoji/diacritics**: Not in QWERTY → clipboard ✅
3. **Pure typeable text**: All chars pass → key typing ✅

**What goes wrong without `toRussian`-aware check?** If we just checked `qwerty[ch]` for every char:
- When typing Russian in the Russian layout: Cyrillic chars like `п` would be `qwerty["п"]` → nil → clipboard unnecessarily. This would use the clipboard for EVERY Russian word, even though key typing works perfectly fine (because `enOnSameKey("п") = "g"` → `qwerty["g"]` exists).

### 4.3 Clipboard Path: Trust, Don't Verify

When using clipboard paste (`replaceByClipboard`), we trust the paste to handle any Unicode. The clipboard path doesn't need layout switching (paste works in any layout). But we DO need to:
1. Snapshot the user's clipboard before modifying it
2. Restore it after the paste completes
3. Use a delay (`Timing.clipboardRestore = 0.4s`) to allow the paste to finish before restoring

**Why 0.4s?** Cmd+V paste is async — the app receives the event, reads the clipboard, processes it. If we restore the clipboard too quickly, the app might read the restored (old) content instead of our converted text. 0.4s is empirically determined to be safe for most apps (terminal, VS Code, Chrome, Safari).

---

## 5. State Management

### 5.1 The Fundamental Problem (BUG #4 + #5)

All conversion operations are **async chains** of `DispatchQueue.main.asyncAfter`:

```
asyncAfter(layoutSwitchDelay) {     // 50ms
    backspace(count: N) {           // N × 8ms
        type(text) {                // text.count × 10ms + 50ms
            // completion: sets isReplacing=false, busy=false, typedBuffer=text
        }
    }
}
```

For a 10-character word: 50 + (10 × 8) + 50 + (10 × 10) + closure overhead ≈ 250ms.

**The vulnerability**: if `isReplacing` is force-reset (timeout or `.reset`) while the chain is mid-flight, the pending closures still execute. They set `isReplacing = false`, `busy = false`, and crucially: `typedBuffer = text` — corrupting the state.

**Two trigger scenarios**:

1. **Timeout** (BUG #4): 3s timeout fires in `handle()`. Force-reset: `isReplacing = false`, `busy = false`, `pendingCharacters = ""`. But the backspace/type chain is still running. Its completion fires later → sets state again → race.

2. **`.reset` during isReplacing** (BUG #5): User presses Tab/Enter during replacement. The `.reset` case clears `pendingCharacters`. But the completion handler later sets `typedBuffer = text` — the reset is overridden. The buffer now contains stale converted text that doesn't match what's in the field.

### 5.2 Solution: Generation Token

Add an incrementing counter to `SwitcherState`:

```swift
/// Generation token for invalidating stale async completion callbacks.
/// Each conversion operation captures the current generation. Before setting
/// state in a callback, check that the generation hasn't changed — if it has,
/// the operation was superseded or timed out, and the callback should abort.
var generation: UInt64 = 0
```

**Rule**: Any code path that invalidates an in-flight operation increments `generation`:

```swift
state.generation += 1
```

Every async callback captures the generation at capture time and checks it before touching state:

```swift
KeyEvents.backspace(count: deleteCount) { [weak self, gen = state.generation] in
    guard let self, self.state.generation == gen else { return }  // ← abort if stale
    KeyEvents.type(text, toRussian: toRussian) { [weak self, gen = gen] in
        guard let self, self.state.generation == gen else { return }  // ← abort if stale
        self.state.isReplacing = false
        self.state.busy = false
        self.state.typedBuffer = text
        self.state.lastWasSelectionConvert = false
        self.replayPendingKeystrokes()
    }
}
```

**Where to increment generation** (invalidation points):

| Trigger | Code path | Sets state? |
|---------|-----------|-------------|
| Timeout force-reset | `handle()` isReplacing timeout check | ✅ Sets `isReplacing=false, busy=false, pendingCharacters=""` → also increment `generation` |
| `.reset` during isReplacing | `handle()` keyDown `.reset` case | Clears `pendingCharacters` → also increment `generation` |
| New conversion starts | `triggerSwitch()` → `performSwitch()` | Should NOT increment — the current generation's callback might still be running. Instead, `triggerSwitch` checks `guard !state.busy` and returns if busy. If not busy, it starts a new operation with a fresh generation. |

**Causal reasoning — why does this work?**

The generation token is a **monotonic version tag**. It doesn't prevent the async closures from firing — they're already scheduled on the dispatch queue. What it does is make them **no-ops**: if the generation changed since the operation started, the closure returns without touching any state.

```
Timeline:
  t=0ms:   conversion starts, generation = 1
           backspace chain begins
  t=50ms:  user presses Tab → .reset fires
           pendingCharacters = ""
           generation = 2  ← incremented
  t=80ms:  backspace chain completes
           completion closure captures gen=1
           self.state.generation == 2 ≠ 1 → abort ✅
           typedBuffer is NOT set ✅
```

**What about the type() calls that already fired?** The backspace/type key events were already posted to the HID system via `CGEvent.post`. If Tab moved focus, those key events landed in the wrong field. We can't un-post them. But the generation check prevents state corruption — `typedBuffer` won't contain stale data, and the next conversion will start with correct state.

This is an acceptable trade-off: the user pressed Tab/Enter (a deliberate focus change) during a conversion. The worst case: some extra key events typed into the wrong field. The critical fix is that `typedBuffer` is not corrupted, so subsequent operations (auto-convert, manual double-Shift) see the correct state.

### 5.3 `typedBuffer` Management

`typedBuffer` is the "what was typed" cache. It's the source of truth when AX isn't available.

| Operation | Sets `typedBuffer` to | Why? |
|-----------|-----------------------|------|
| `replaceByDeleting` completion | `text` (converted text) | So second double-Shift converts back (toggle) |
| `replaceByClipboard` completion | `text` (converted text) | Same — toggle works |
| `convertSelectionViaClipboard` completion | `""` (cleared) | Clipboard conversion uses Cmd+V; buffer doesn't track what was pasted. Can't know the real text. |
| `tryAutoConvert` start | `""` (cleared) | About to backspace+retype. Old buffer is stale. |
| `undoAutoConvert` start | `""` (cleared) | Reverting to original. Buffer will be rebuilt by undo's type() — but actually, we DON'T track undo's typed text. Is this a problem? |
| Mouse click | `""` (cleared) | Caret moved — old buffer is invalid |
| `.reset` keyDown (Enter, Tab) | `""` (cleared) | Text operation completed — new fragment starts |

**The `typedBuffer = text` in completion handlers** is the toggle mechanism. After manual conversion, the buffer contains the converted text. A second double-Shift sees this buffer, converts it back (Translit is symmetric), and types the original. This creates a double-Shift toggle: type in wrong layout → double-Shift → converted → double-Shift → converted back.

**Stale buffer danger** (AGENTS.md lesson): If `typedBuffer` isn't cleared after clipboard conversion, auto-convert fires on the converted text (from the buffer, not the field) → infinite loop or wrong conversion. This is why `convertSelectionViaClipboard` clears the buffer.

**With the generation fix**: The `typedBuffer = text` assignment only happens if the generation matches. If the operation was superseded (timeout, reset, new conversion), the buffer is not touched → no corruption.

### 5.4 `pendingCharacters` Replay

During `isReplacing`, real keystrokes are buffered in `pendingCharacters` and replayed after completion via `replayPendingKeystrokes()`.

**With generation token**: `replayPendingKeystrokes()` is called inside the completion handler, which already checks generation. If the operation was superseded, `pendingCharacters` was cleared (by timeout or `.reset`), so the replay would be a no-op even without the generation check. But the generation check provides defense-in-depth.

**Edge case**: If `.reset` fires during isReplacing, `pendingCharacters` is cleared immediately. The replay call in the completion handler (if it fires) would see empty `pendingCharacters` → returns early. But what if the `.reset` was Tab/Enter — the app has already moved focus? The pending characters were swallowed (not delivered to the app). This is acceptable: the user deliberately pressed Tab/Enter, which is a focus change. The pending characters are lost.

**Alternative considered**: Buffer Tab/Enter themselves and replay them. But this creates its own problems: if Tab moved focus to a submit button and we replay Tab after the conversion, it submits the form unexpectedly. Better to lose the keystrokes than replay them in the wrong context.

---

## 6. Error Handling

### 6.1 LayoutSwitch Failure (BUG #3)

**Problem**: `LayoutSwitch.select(toRussian:)` returns `false` if the target layout isn't installed. The current `undoAutoConvert` calls `learnException` BEFORE checking if the layout switch succeeds:

```swift
// CURRENT (BUGGY):
private func undoAutoConvert(_ info: ...) {
    if state.autoLearnExceptions {
        learnException(info.triggerWord)  // ← learned even if layout switch fails
    }
    guard LayoutSwitch.select(toRussian: info.undoToRussian) else {
        state.busy = false  // ← but exception was already added!
        return
    }
    // ... backspace + retype
}
```

**Fix**: Move `learnException` AFTER `LayoutSwitch.select`:

```swift
// FIXED:
private func undoAutoConvert(_ info: ...) {
    guard LayoutSwitch.select(toRussian: info.undoToRussian) else {
        log("undo: no target layout — skipping")
        state.busy = false
        return  // ← exception NOT learned
    }
    if state.autoLearnExceptions {
        learnException(info.triggerWord)  // ← learned only after layout switch succeeds
    }
    // ... backspace + retype
}
```

**Why?** `learnException` permanently adds the word to `enWords` or `ruWords`, blocking future auto-converts for that word. If the undo fails (no layout), the word shouldn't be blocked — the user's auto-convert still works (the converted text is in the field), and they can try undoing again (e.g., after installing the missing layout). Adding the exception prematurely means: (a) the word won't auto-convert anymore, (b) the user got no undo, (c) the field has wrong text.

**Same pattern in all conversion paths**: Every path that calls `LayoutSwitch.select` should check BEFORE modifying state:

| Path | Fix |
|------|-----|
| `tryAutoConvert` | ✅ Already correct — checks before setting `typedBuffer = ""` |
| `undoAutoConvert` | ❌ Move `learnException` after layout check |
| `replaceByDeleting` | ✅ Already correct — checks before setting `isReplacing` |
| `replaceByClipboard` | N/A — doesn't switch layout (paste works in any layout) |
| `convertSelectionViaClipboard` | ✅ Already calls `LayoutSwitch.select` before `Clipboard.copy` / `paste` |

### 6.2 `type()` Can't Type a Char (BUG #2)

**Problem**: `typeNext` calls `log("⚠  typeNext: cannot type ...")` and silently skips the character. The user sees missing characters with no indication of what happened.

**Fix**: Don't let the type() path be chosen for non-typeable text. The typeability check (§4.2) routes non-typeable text to clipboard paste BEFORE `type()` is called. This is a **pre-check**, not a fallback.

```
convertTypedText
  │
  ├─ isFullyTypeable(fullText, toRussian) == true
  │   → replaceByDeleting (key typing)
  │     If type() still encounters an unexpected miss → log + drop
  │     (shouldn't happen if pre-check is correct)
  │
  └─ isFullyTypeable(fullText, toRussian) == false
      → replaceByClipboard (clipboard paste)
        Any Unicode text handled
```

**Why pre-check instead of fallback?** The `type()` function processes characters one at a time with delays. If it encounters a non-typeable char at position 5 of 10, it's already typed 4 chars and deleted the original text. Falling back to clipboard mid-typing would mean: backspace the 4 typed chars, then clipboard-paste the full text. This is complex, error-prone, and doubles the operation time. A pre-check avoids the issue entirely.

**Defense-in-depth**: Even with the pre-check, `typeNext` should still handle the "shouldn't happen" case gracefully (log + skip the char). This is already the current behavior. The pre-check just makes it extremely unlikely to trigger.

### 6.3 Accessibility Returns nil

When `realTextBeforeCaret()` returns nil (AX not available for the app), `convertTypedText` falls back to the typing buffer. This is already handled:

```swift
if let real = realTextBeforeCaret(), !real.isEmpty {
    ns = real as NSString
} else {
    ns = state.typedBuffer as NSString
}
```

**Edge case**: Buffer is empty but AX has text → uses AX. ✅  
**Edge case**: Buffer has text but AX has nothing → uses buffer. ✅  
**Edge case**: Both empty → chunk is empty → `LayoutSwitch.toggle()` (no conversion). ✅

### 6.4 Event Tap Disabled by System

If the event tap is disabled by the system (timeout or user input), the re-enable logic handles it:

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    if let tap = currentTap { CGEvent.tapEnable(tap: tap, enable: true) }
    return nil
}
```

During this gap, `isReplacing` might be true (in-flight conversion). The completion handlers are on the main dispatch queue, not the event tap, so they still fire. But if no event tap is listening, new keystrokes bypass the buffer — `pendingCharacters` won't accumulate. This is acceptable: the tap gap is brief (milliseconds), and the conversion chain still completes via the dispatch queue.

---

## 7. Implementation Checklist

### BUG #1: Leading boundary chars eaten
- [x] Calculate `leadingBoundaryCount` in `convertTypedText`
- [ ] Pass `deleteCount = chunk.count - leadingBoundaryCount` to `replaceByDeleting` / `replaceByClipboard`
- [ ] Add test: "abc привет" → double-Shift → "abc ghbdtn" (space preserved)
- [ ] Add test: "abc. привет" → double-Shift → "abc. ghbdtn" (period preserved)

### BUG #2: Non-QWERTY chars silently dropped
- [ ] Add `isFullyTypeable(_ text: String, toRussian: Bool) -> Bool` to `KeyEvents`
- [ ] Replace mixed-script check with typeability check in `convertTypedText`
- [ ] Add test: "ghbdtn 🎉" → double-Shift → clipboard paste (emoji preserved)

### BUG #3: `learnException` before layout guard
- [ ] Move `learnException` after `LayoutSwitch.select` in `undoAutoConvert`
- [ ] Add test: simulate layout failure → exception not learned

### BUG #4: Timeout force-reset doesn't invalidate late completion
- [ ] Add `var generation: UInt64 = 0` to `SwitcherState`
- [ ] Increment `generation` in timeout force-reset path
- [ ] Capture generation in all async completion closures (`tryAutoConvert`, `undoAutoConvert`, `replaceByDeleting`, `replaceByClipboard`, `convertSelectionViaClipboard`)
- [ ] Add `guard self.state.generation == gen` check in each closure
- [ ] Add test: timeout during conversion → completion is no-op

### BUG #5: `.reset` during isReplacing + completion overrides typedBuffer
- [ ] Increment `generation` in `.reset` handler during isReplacing
- [ ] The generation check in `replaceByDeleting` completion already prevents `typedBuffer = text` ← covered by BUG #4 fix
- [ ] Add test: type Tab during conversion → typedBuffer not corrupted

### §3.4: Block single-char `.toLatin` in manual retroactive walk
- [ ] Add explicit check in `convertTypedText` retroactive loop
- [ ] Add test: single-char Cyrillic before converted word → not converted in manual mode

---

## Appendix A: State Transition Diagram

```
                    ┌─────────┐
                    │  IDLE   │ busy=false, isReplacing=false
                    │ (ready) │ typedBuffer tracks keystrokes
                    └────┬────┘
                         │
              ┌──────────┼──────────┐
              │          │          │
     double-Shift  boundary char  mouse click
              │ (auto on)  │          │
              ▼          ▼          ▼
     ┌────────────┐ ┌──────────┐ ┌─────────┐
     │ PERFORM    │ │ AUTO-    │ │ RESET   │
     │ SWITCH     │ │ CONVERT  │ │ buffer  │
     │ busy=true  │ │ busy=true│ │         │
     └─────┬──────┘ └────┬─────┘ └─────────┘
           │              │
     ┌─────┼─────┐        │
     │     │     │        │
   undo  select  typed   backspace
   auto  clip    text    + retype
   conv  board
     │     │     │        │
     ▼     ▼     ▼        ▼
   ┌──────────────────────────────┐
   │ REPLACING                    │ isReplacing=true
   │ busy=true, generation=N      │
   │ keystrokes buffered in       │
   │ pendingCharacters            │
   └──────────┬───────────────────┘
              │
     ┌────────┼────────┐
     │        │        │
   complete  timeout  .reset
     │        │        │
     ▼        ▼        ▼
   gen==N?  gen+=1   gen+=1
   YES→ok   NO→noop NO→noop
   (set     (stale)  (stale)
    state)
     │
     ▼
   ┌──────────┐
   │ REPLAY   │ type pending chars
   │ PENDING  │ track in buffer
   └────┬─────┘
        │
        ▼
   ┌─────────┐
   │  IDLE   │ busy=false, isReplacing=false
   │ (ready) │ typedBuffer updated
   └─────────┘
```

---

## Appendix B: Why `deleteCount` Must Match `fullText` Exactly

The conversion mechanism is:

1. Backspace N times (deletes N chars before the caret)
2. Type M characters (inserts M chars at the caret)

For the result to be correct, the net effect on text length must be `M - N = 0` (same length) or `M - N = delta` (if converted text is different length). This is guaranteed *only if*:
- N = number of characters in the field that should be deleted
- M = number of characters we type back (including unconverted prefix)

If N > M_actual: characters are eaten (Bug #1).  
If N < M_actual: characters are duplicated (the field grows).

**The invariant**: `deleteCount` must equal the number of characters in the chunk that correspond to what `fullText` replaces. Leading boundary chars that stay in the field must NOT be in `deleteCount`.
