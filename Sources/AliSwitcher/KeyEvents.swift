import Cocoa
import Carbon.HIToolbox

/// Posting synthetic keyboard events to the active application.
enum KeyEvents {

    /// Sends a key press (down + up) with the given modifiers.
    /// privateState marks the event as synthetic so our own handler can
    /// distinguish it from real user keystrokes.
    static func post(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Cmd+C — copy the selection to the clipboard.
    static func copySelection() {
        post(keyCode: CGKeyCode(kVK_ANSI_C), flags: [.maskCommand])
    }

    /// Cmd+V — paste from the clipboard (replaces the selection).
    static func paste() {
        post(keyCode: CGKeyCode(kVK_ANSI_V), flags: [.maskCommand])
    }

    /// Cmd+Z — undo the last action (reverse selection conversion).
    static func undo() {
        post(keyCode: CGKeyCode(kVK_ANSI_Z), flags: [.maskCommand])
    }

    /// Sends count Backspace presses (removes characters or the selection).
    static func backspace(count: Int, completion: @escaping () -> Void) {
        guard count > 0 else {
            completion()
            return
        }
        backspaceNext(remaining: count, completion: completion)
    }

    private static func backspaceNext(remaining: Int, completion: @escaping () -> Void) {
        guard remaining > 0 else {
            completion()
            return
        }
        post(keyCode: CGKeyCode(kVK_Delete), flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.backspaceDelay) {
            backspaceNext(remaining: remaining - 1, completion: completion)
        }
    }

    // MARK: - Typing text via keys

    /// Map "character at QWERTY position → (virtual keycode, needs Shift?)".
    private static let qwerty: [Character: (CGKeyCode, Bool)] = [
        "a": (0, false), "s": (1, false), "d": (2, false), "f": (3, false),
        "h": (4, false), "g": (5, false), "z": (6, false), "x": (7, false),
        "c": (8, false), "v": (9, false), "b": (11, false), "q": (12, false),
        "w": (13, false), "e": (14, false), "r": (15, false), "y": (16, false),
        "t": (17, false), "1": (18, false), "2": (19, false), "3": (20, false),
        "4": (21, false), "6": (22, false), "5": (23, false), "=": (24, false),
        "9": (25, false), "7": (26, false), "-": (27, false), "8": (28, false),
        "0": (29, false), "]": (30, false), "o": (31, false), "u": (32, false),
        "[": (33, false), "i": (34, false), "p": (35, false), "l": (37, false),
        "j": (38, false), "'": (39, false), "k": (40, false), ";": (41, false),
        "\\": (42, false), ",": (43, false), "/": (44, false), "n": (45, false),
        "m": (46, false), ".": (47, false), "`": (50, false), " ": (49, false),
        "A": (0, true), "S": (1, true), "D": (2, true), "F": (3, true),
        "H": (4, true), "G": (5, true), "Z": (6, true), "X": (7, true),
        "C": (8, true), "V": (9, true), "B": (11, true), "Q": (12, true),
        "W": (13, true), "E": (14, true), "R": (15, true), "Y": (16, true),
        "T": (17, true), "O": (31, true), "U": (32, true), "I": (34, true),
        "P": (35, true), "L": (37, true), "J": (38, true), "K": (40, true),
        "N": (45, true), "M": (46, true),
        "!": (18, true), "@": (19, true), "#": (20, true),
        "$": (21, true), "^": (22, true), "%": (23, true), "+": (24, true),
        "(": (25, true), "&": (26, true), "_": (27, true), "*": (28, true),
        ")": (29, true), "}": (30, true), "{": (33, true), "|": (42, true),
        "\"": (39, true), ":": (41, true), "<": (43, true), "?": (44, true),
        ">": (47, true), "~": (50, true),
    ]

    /// Can this character be typed (does it have a QWERTY key)?
    static func canType(_ qwertyChar: Character) -> Bool {
        qwerty[qwertyChar] != nil
    }

    /// Can every character in text be typed CORRECTLY via the QWERTY map?
    ///
    /// Two conditions:
    /// 1. Every char must have a QWERTY key (emoji, non-standard punctuation → false)
    /// 2. Script consistency: when typing in Russian layout, all letters must
    ///    be Cyrillic (enOnSameKey maps them to QWERTY keys). A Latin letter
    ///    in Russian text would be mistyped (pressing 'h' in RU → 'р', not 'h').
    ///    Same in reverse: a Cyrillic letter in English text has no QWERTY key.
    ///
    /// BUG #2 fix: universal typeability pre-check. If false → clipboard paste.
    static func isFullyTypeable(_ text: String, toRussian: Bool) -> Bool {
        for ch in text {
            if ch.isLetter {
                if toRussian {
                    // Letter must be Cyrillic — enOnSameKey finds its QWERTY key.
                    guard let source = Translit.enOnSameKey(ch), qwerty[source] != nil else {
                        return false  // Latin letter in Russian text → can't type correctly
                    }
                } else {
                    // Letter must be Latin — it IS the QWERTY key.
                    if qwerty[ch] == nil {
                        return false  // Cyrillic letter in English text → can't type
                    }
                }
            } else {
                // Non-letter (space, punctuation, digit): must have a QWERTY key.
                if qwerty[ch] == nil {
                    return false  // Emoji, non-standard punctuation → can't type
                }
            }
        }
        return true
    }

    /// Types the text with keys in the CURRENT (already switched) layout.
    /// Typing over the selection replaces it — no clipboard needed.
    static func type(_ text: String, toRussian: Bool, completion: (() -> Void)? = nil) {
        let chars = Array(text)
        guard !chars.isEmpty else {
            completion?()
            return
        }
        // Pause before the first key: the app needs time to apply the new layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.layoutSwitchDelay) {
            typeNext(chars, index: 0, toRussian: toRussian, completion: completion)
        }
    }

    private static func typeNext(_ chars: [Character], index: Int, toRussian: Bool, completion: (() -> Void)?) {
        guard index < chars.count else {
            completion?()
            return
        }
        let ch = chars[index]
        // Which physical key (at QWERTY position) produces this character in the target layout?
        let source: Character = (toRussian ? Translit.enOnSameKey(ch) : nil) ?? ch
        if let (keyCode, shift) = qwerty[source] {
            post(keyCode: keyCode, flags: shift ? [.maskShift] : [])
        } else {
            log("⚠  typeNext: cannot type «\(ch)» (source «\(source)» not in qwerty map)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.typeDelay) {
            typeNext(chars, index: index + 1, toRussian: toRussian, completion: completion)
        }
    }

    /// Replays buffered characters after replacement. Same as type() but
    /// without the initial layoutSwitchDelay — the layout is already set.
    static func replay(_ text: String, toRussian: Bool, completion: (() -> Void)? = nil) {
        let chars = Array(text)
        guard !chars.isEmpty else {
            completion?()
            return
        }
        typeNext(chars, index: 0, toRussian: toRussian, completion: completion)
    }
}
