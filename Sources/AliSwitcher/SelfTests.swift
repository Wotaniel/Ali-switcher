import Foundation

/// Self-tests of the pure AliSwitcher logic (no GUI, no system permissions).
/// Run: AliSwitcher --test  (exit 0 = all passed, 1 = failures)
enum SelfTests {

    private static var passed = 0
    private static var failed = 0
    private static var failures: [String] = []

    static func run() -> Bool {
        testTranslit()
        testChunkFinder()
        testTypingMap()

        print("")
        print("— Result —")
        print("✅ passed: \(passed), ❌ failed: \(failed)")
        if !failures.isEmpty {
            print("Failed checks:")
            for f in failures { print("  ✗ \(f)") }
        }
        return failed == 0
    }

    // MARK: - Helpers

    private static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
        } else {
            failed += 1
            failures.append("\(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    private static func conv(_ text: String) -> String? {
        Translit.convert(text)?.converted
    }

    private static func chunk(of text: String, caret: Int) -> String {
        let ns = text as NSString
        let start = ChunkFinder.chunkStart(in: ns, before: caret)
        return ns.substring(with: NSRange(location: start, length: caret - start))
    }

    // MARK: - Translit

    private static func testTranslit() {
        print("— Translit (ЙЦУКЕН ↔ QWERTY) —")

        // RU → EN
        check("RU→EN «привет»", conv("привет") == "ghbdtn")
        check("RU→EN «Привет Мир»", conv("Привет Мир") == "Ghbdtn Vbh")
        check("RU→EN «раскладке:» (знаки)", conv("раскладке:") == "hfcrkflrt^")
        check("RU→EN «нужно чтобы»", conv("нужно чтобы") == "ye;yj xnj,s")
        check("RU→EN «б»→«,»", conv("б") == ",")
        check("RU→EN «Б»→«<»", conv("Б") == "<")
        check("RU→EN «ё»→«`», «Ё»→«~»", conv("ёЁ") == "`~")
        check("RU→EN «х»→«[», «ъ»→«]»", conv("хъ") == "[]")
        check("RU→EN «ж»→«;», «э»→«'»", conv("жэ") == ";'")
        check("RU→EN «ю»→«.», «я»→«z»", conv("юя") == ".z")
        // Signs inside a word (a lone sign is skipped by convert(): no letters)
        check("RU→EN «привет.» точка→«/»", conv("привет.") == "ghbdtn/")
        check("RU→EN «день №»→«ltym #»", conv("день №") == "ltym #")

        // EN → RU
        check("EN→RU «ghbdtn»", conv("ghbdtn") == "привет")
        check("EN→RU «ghbdtn vbh»", conv("ghbdtn vbh") == "привет мир")
        check("EN→RU «,»→«б»", conv("ghbdtn,") == "приветб")
        check("EN→RU «.»→«ю»", conv("ghbdtn.") == "приветю")
        check("EN→RU «[»→«х», «{»→«Х»", conv("ghbdtn[{") == "приветхХ")
        check("EN→RU «^»→«:», «&»→«?»", conv("ghbdtn^&") == "привет:?")
        check("EN→RU «@»→«\"»", conv("ghbdtn@") == "привет\"")
        check("EN→RU «;»→«ж»", conv("ghbdtn;") == "приветж")

        // Direction
        check("направление: кириллица → toLatin",
              Translit.convert("привет")?.direction == .toLatin)
        check("направление: латиница → toCyrillic",
              Translit.convert("hello")?.direction == .toCyrillic)

        // No letters — no-op
        check("нет букв «123 !!!» → nil", conv("123 !!!") == nil)
        check("пусто → nil", conv("") == nil)

        // User example: it is the FRAGMENT that gets converted (as in the real scenario)
        let chunk = " b yfgbcfk ytcrjkmrj ckjd yf lheujq hfcrkflrt^ ye;yj xnj,s dsltkbkjcm dct yfgbcfyyjt b"
        check("пример пользователя: конвертация фрагмента",
              conv(chunk) == " и написал несколько слов на другой раскладке: нужно чтобы выделилось все написанное и",
              "получили: «\(conv(chunk) ?? "nil")»")
    }

    // MARK: - ChunkFinder

    private static func testChunkFinder() {
        print("— ChunkFinder (граница фрагмента) —")

        check("«привет ghbdtn» → фрагмент « ghbdtn»",
              chunk(of: "привет ghbdtn", caret: 13) == " ghbdtn")
        check("«ghbdtn» (только не та раскладка) → весь",
              chunk(of: "ghbdtn", caret: 6) == "ghbdtn")
        check("«Привет мир» (весь правильный) → весь (toggle)",
              chunk(of: "Привет мир", caret: 10) == "Привет мир")
        check("«ab cd» (один алфавит) → весь",
              chunk(of: "ab cd", caret: 5) == "ab cd")
        check("«аб cd» → только латинский хвост",
              chunk(of: "аб cd", caret: 5) == " cd")
        check("перевод строки — граница",
              chunk(of: "abc\ndef", caret: 7) == "def")
        check("таб — граница",
              chunk(of: "abc\tdef", caret: 7) == "def")
        check("пустой текст → 0",
              chunk(of: "", caret: 0) == "")

        let example = "я начал писать что-то, случайно переключил раскладку b yfgbcfk ytcrjkmrj ckjd yf lheujq hfcrkflrt^ ye;yj xnj,s dsltkbkjcm dct yfgbcfyyjt b"
        let exChunk = chunk(of: example, caret: (example as NSString).length)
        check("пример пользователя: фрагмент = вся «не та» фраза",
              exChunk == " b yfgbcfk ytcrjkmrj ckjd yf lheujq hfcrkflrt^ ye;yj xnj,s dsltkbkjcm dct yfgbcfyyjt b",
              "получили: «\(exChunk)»")
    }

    // MARK: - Typing map (QWERTY)

    private static func testTypingMap() {
        print("— KeyEvents: карта QWERTY —")

        // Same logic as in KeyEvents.type(): char → QWERTY neighbour (or itself)
        func typeable(_ ch: Character) -> Bool {
            let source: Character = Translit.enOnSameKey(ch) ?? ch
            return KeyEvents.canType(source)
        }

        // Every letter of Russian text must be typeable
        let ru = "и написал несколько слов на другой раскладке чтобы выделилось всё"
        var allTypeable = true
        var bad: [Character] = []
        for ch in ru where ch.isLetter {
            if !typeable(ch) {
                allTypeable = false
                bad.append(ch)
            }
        }
        check("все буквы «\(ru.prefix(20))…» печатаемы", allTypeable, "проблемные: \(bad)")

        // Punctuation must be typeable (in the Russian layout)
        let symbols = "№;:,?.{}"
        var symbolsOK = true
        bad = []
        for ch in symbols {
            if !typeable(ch) {
                symbolsOK = false
                bad.append(ch)
            }
        }
        check("знаки «\(symbols)» печатаемы", symbolsOK, "проблемные: \(bad)")
    }
}
