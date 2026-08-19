import Cocoa
import Carbon.HIToolbox

/// Постинг синтетических клавиатурных событий в активное приложение.
enum KeyEvents {

    /// Отправляет нажатие клавиши (down + up) с заданными модификаторами.
    static func post(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    /// Cmd+C — копирование выделения в буфер обмена.
    static func copySelection() {
        post(keyCode: CGKeyCode(kVK_ANSI_C), flags: [.maskCommand])
    }

    /// Cmd+V — вставка из буфера обмена (заменяет выделение).
    static func paste() {
        post(keyCode: CGKeyCode(kVK_ANSI_V), flags: [.maskCommand])
    }

    /// Отправляет count нажатий Backspace (удаление символов или выделения).
    static func backspace(count: Int, completion: @escaping () -> Void) {        guard count > 0 else {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
            backspaceNext(remaining: remaining - 1, completion: completion)
        }
    }

    // MARK: - Печать текста клавишами

    /// Карта «символ на QWERTY-позиции → (virtual keycode, нужен ли Shift)».
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
        "T": (17, true), "!": (18, true), "@": (19, true), "#": (20, true),
        "$": (21, true), "^": (22, true), "%": (23, true), "+": (24, true),
        "(": (25, true), "&": (26, true), "_": (27, true), "*": (28, true),
        ")": (29, true), "}": (30, true), "{": (33, true), "|": (42, true),
        "\"": (39, true), ":": (41, true), "<": (43, true), "?": (44, true),
        ">": (47, true), "~": (50, true),
    ]

    /// Можно ли напечатать этот символ (есть ли клавиша в QWERTY-позиции).
    static func canType(_ qwertyChar: Character) -> Bool {
        qwerty[qwertyChar] != nil
    }

    /// Печатает текст клавишами в ТЕКУЩЕЙ (уже переключённой) раскладке.
    /// Печать поверх выделения заменяет его — работает без буфера обмена.
    static func type(_ text: String, toRussian: Bool, completion: (() -> Void)? = nil) {
        let chars = Array(text)
        guard !chars.isEmpty else {
            completion?()
            return
        }
        // Пауза перед первой клавишей: приложение должно успеть применить новую раскладку.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            typeNext(chars, index: 0, toRussian: toRussian, completion: completion)
        }
    }

    private static func typeNext(_ chars: [Character], index: Int, toRussian: Bool, completion: (() -> Void)?) {
        guard index < chars.count else {
            completion?()
            return
        }
        let ch = chars[index]
        // Какая физическая клавиша (в QWERTY-позиции) даёт этот символ в целевой раскладке?
        let source: Character = (toRussian ? Translit.enOnSameKey(ch) : nil) ?? ch
        if let (keyCode, shift) = qwerty[source] {
            post(keyCode: keyCode, flags: shift ? [.maskShift] : [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            typeNext(chars, index: index + 1, toRussian: toRussian, completion: completion)
        }
    }
}
