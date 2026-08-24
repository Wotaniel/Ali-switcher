import Foundation

/// Where to switch the layout after converting text.
enum SwitchDirection {
    /// The text was typed in Cyrillic within the English layout → becomes Latin, switch to EN.
    case toLatin
    /// The text was typed in Latin within the Russian layout → becomes Cyrillic, switch to RU.
    case toCyrillic
}

/// Converts text between layouts (ЙЦУКЕН ↔ QWERTY).
enum Translit {

    // Key-to-key: Russian letter → Latin letter/symbol on the same key.
    private static let ruToEn: [Character: Character] = [
        // top row
        "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y",
        "г": "u", "ш": "i", "щ": "o", "з": "p", "х": "[", "ъ": "]",
        // middle row
        "ф": "a", "ы": "s", "в": "d", "а": "f", "п": "g", "р": "h",
        "о": "j", "л": "k", "д": "l", "ж": ";", "э": "'",
        // bottom row
        "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n",
        "ь": "m", "б": ",", "ю": ".",
        // ё and symbols (Shift variants)
        "ё": "`", "Ё": "~",
        "Й": "Q", "Ц": "W", "У": "E", "К": "R", "Е": "T", "Н": "Y",
        "Г": "U", "Ш": "I", "Щ": "O", "З": "P", "Х": "{", "Ъ": "}",
        "Ф": "A", "Ы": "S", "В": "D", "А": "F", "П": "G", "Р": "H",
        "О": "J", "Л": "K", "Д": "L", "Ж": ":", "Э": "\"",
        "Я": "Z", "Ч": "X", "С": "C", "М": "V", "И": "B", "Т": "N",
        "Ь": "M", "Б": "<", "Ю": ">",
        // dot in the Russian layout is "/" in the English one
        ".": "/",
        // punctuation: key-based mapping (Shift+6 RU = ":", EN gives "^", etc.)
        "№": "#", "\"": "@", ";": "$", ":": "^", "?": "&",
    ]

    private static let enToRu: [Character: Character] = {
        var dict = [Character: Character]()
        for (ru, en) in ruToEn { dict[en] = ru }
        return dict
    }()

    static func isCyrillic(_ ch: Character) -> Bool {
        (ch >= "а" && ch <= "я") || (ch >= "А" && ch <= "Я") || ch == "ё" || ch == "Ё"
    }

    /// The English character on the same physical key (for typing in the Russian layout).
    static func enOnSameKey(_ ru: Character) -> Character? {
        ruToEn[ru]
    }

    /// Determines the direction by the majority of letters and returns the converted text.
    static func convert(_ text: String) -> (converted: String, direction: SwitchDirection)? {
        // Normalize typographic quotes to ASCII (macOS Smart Quotes feature).
        // macOS replaces " with \u201C/\u201D and ' with \u2018/\u2019.
        // These aren't in the transliteration map, so without normalization
        // they pass through unchanged and break conversion.
        //   " (U+201C) → " (U+0022, Shift+э key in QWERTY → Э in RU)
        //   ' (U+2018) → ' (U+0027, э key in QWERTY → э in RU)
        let normalized: String
        if text.contains(where: { "\u{201C}\u{201D}\u{2018}\u{2019}".contains($0) }) {
            normalized = text
                .replacingOccurrences(of: "\u{201C}", with: "\"")
                .replacingOccurrences(of: "\u{201D}", with: "\"")
                .replacingOccurrences(of: "\u{2018}", with: "'")
                .replacingOccurrences(of: "\u{2019}", with: "'")
        } else {
            normalized = text
        }

        var cyrillic = 0
        var latin = 0
        for ch in normalized {
            if ch.isLetter {
                if isCyrillic(ch) { cyrillic += 1 } else { latin += 1 }
            }
        }
        guard cyrillic > 0 || latin > 0 else {
            // No letters — but characters like [, ], ', ; are on different keys
            // in RU vs EN layouts. Check if any character is in a translit map.
            for ch in normalized {
                if enToRu[ch] != nil {
                    // English-layout character (e.g. '[' → 'х')
                    let converted = String(normalized.map { enToRu[$0] ?? $0 })
                    return (converted, .toCyrillic)
                }
                if ruToEn[ch] != nil {
                    // Russian-layout character (e.g. '.' → '/')
                    let converted = String(normalized.map { ruToEn[$0] ?? $0 })
                    return (converted, .toLatin)
                }
            }
            return nil
        }

        let toLatin = cyrillic >= latin
        let map: [Character: Character] = toLatin ? ruToEn : enToRu
        let converted = String(normalized.map { map[$0] ?? $0 })
        let direction: SwitchDirection = toLatin ? .toLatin : .toCyrillic
        return (converted, direction)
    }
}
