import Foundation

/// Куда переключаем раскладку после конвертации текста.
enum SwitchDirection {
    /// Текст был набран кириллицей в английской раскладке → станет латиницей, включаем EN.
    case toLatin
    /// Текст был набран латиницей в русской раскладке → станет кириллицей, включаем RU.
    case toCyrillic
}

/// Перевод текста из одной раскладки в другую (ЙЦУКЕН ↔ QWERTY).
enum Translit {

    // Клавиша-в-клавишу: русская буква → латинская буква/символ на той же клавише.
    private static let ruToEn: [Character: Character] = [
        // верхний ряд
        "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y",
        "г": "u", "ш": "i", "щ": "o", "з": "p", "х": "[", "ъ": "]",
        // средний ряд
        "ф": "a", "ы": "s", "в": "d", "а": "f", "п": "g", "р": "h",
        "о": "j", "л": "k", "д": "l", "ж": ";", "э": "'",
        // нижний ряд
        "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n",
        "ь": "m", "б": ",", "ю": ".",
        // ё и знаки (Shift-варианты)
        "ё": "`", "Ё": "~",
        "Й": "Q", "Ц": "W", "У": "E", "К": "R", "Е": "T", "Н": "Y",
        "Г": "U", "Ш": "I", "Щ": "O", "З": "P", "Х": "{", "Ъ": "}",
        "Ф": "A", "Ы": "S", "В": "D", "А": "F", "П": "G", "Р": "H",
        "О": "J", "Л": "K", "Д": "L", "Ж": ":", "Э": "\"",
        "Я": "Z", "Ч": "X", "С": "C", "М": "V", "И": "B", "Т": "N",
        "Ь": "M", "Б": "<", "Ю": ">",
        // точка в русской раскладке — это "/" в английской
        ".": "/",
        // знаки препинания: пересчёт по клавише (Shift+6 RU = ":", в EN даёт "^", и т.п.)
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

    /// Английский символ на той же физической клавише (для печати в русской раскладке).
    static func enOnSameKey(_ ru: Character) -> Character? {
        ruToEn[ru]
    }

    /// Определяет направление по большинству букв и возвращает сконвертированный текст.
    static func convert(_ text: String) -> (converted: String, direction: SwitchDirection)? {
        var cyrillic = 0
        var latin = 0
        for ch in text {
            if ch.isLetter {
                if isCyrillic(ch) { cyrillic += 1 } else { latin += 1 }
            }
        }
        guard cyrillic > 0 || latin > 0 else { return nil }

        let toLatin = cyrillic >= latin
        let map: [Character: Character] = toLatin ? ruToEn : enToRu
        let converted = String(text.map { map[$0] ?? $0 })
        let direction: SwitchDirection = toLatin ? .toLatin : .toCyrillic
        return (converted, direction)
    }
}
