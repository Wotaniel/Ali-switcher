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
        testAutoSwitcherEdgeCases()

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

    // MARK: - AutoSwitcher edge cases

    private static func testAutoSwitcherEdgeCases() {
        print("— AutoSwitcher: edge cases —")

        // isMixedCase — функция-утилита. Больше НЕ блокирует конвертацию
        // (spell-checker сам решает). Тесты проверяют корректность функции.
        check("mixed-case «iPhone» → isMixedCase true",
              AutoSwitcher.isMixedCase("iPhone"))
        check("mixed-case «macOS» → isMixedCase true",
              AutoSwitcher.isMixedCase("macOS"))
        check("mixed-case «JavaScript» → isMixedCase true",
              AutoSwitcher.isMixedCase("JavaScript"))
        check("не mixed-case «hello»",
              !AutoSwitcher.isMixedCase("hello"))
        check("не mixed-case «HELLO» (all upper)",
              !AutoSwitcher.isMixedCase("HELLO"))
        // mixed-case «Hello» → не mixed-case (sentence case ≠ mixed-case)
        check("не mixed-case «Hello» (sentence case)",
              !AutoSwitcher.isMixedCase("Hello"))

        // Digits in words
        check("digits «iPhone15» содержит цифры",
              AutoSwitcher.containsDigits("iPhone15"))
        check("digits «3D» содержит цифры",
              AutoSwitcher.containsDigits("3D"))
        check("нет digits «hello»",
              !AutoSwitcher.containsDigits("hello"))

        // URLs and emails
        check("URL «https://example.com» не конвертируется",
              AutoSwitcher.isNonConvertible("https://example.com"))
        check("URL «http://foo.bar» не конвертируется",
              AutoSwitcher.isNonConvertible("http://foo.bar"))
        check("URL «www.example.com» не конвертируется",
              AutoSwitcher.isNonConvertible("www.example.com"))
        check("email «foo@bar.com» не конвертируется",
              AutoSwitcher.isNonConvertible("foo@bar.com"))
        check("IP «127.0.0.1» не конвертируется",
              AutoSwitcher.isNonConvertible("127.0.0.1"))
        check("path «/usr/bin» не конвертируется",
              AutoSwitcher.isNonConvertible("/usr/bin"))
        check("path «~/Documents» не конвертируется",
              AutoSwitcher.isNonConvertible("~/Documents"))
        check("shell «$HOME» не конвертируется",
              AutoSwitcher.isNonConvertible("$HOME"))
        check("обычное слово «ghbdtn» конвертируется (не URL/email)",
              !AutoSwitcher.isNonConvertible("ghbdtn"))

        // CLI flags
        check("flag «-rf» не конвертируется",
              AutoSwitcher.isNonConvertible("-rf"))
        check("flag «--verbose» не конвертируется",
              AutoSwitcher.isNonConvertible("--verbose"))
        check("flag «-l» не конвертируется",
              AutoSwitcher.isNonConvertible("-l"))

        // snake_case identifiers
        check("underscore «my_var» содержит _",
              AutoSwitcher.containsUnderscore("my_var"))
        check("underscore «MAX_SIZE» содержит _",
              AutoSwitcher.containsUnderscore("MAX_SIZE"))
        check("нет underscore «hello»",
              !AutoSwitcher.containsUnderscore("hello"))
        check("snake_case «my_var_name» не конвертируется",
              AutoSwitcher.isNonConvertible("my_var_name"))
        check("обычное слово «привет» конвертируется (не URL/email)",
              !AutoSwitcher.isNonConvertible("привет"))

        // Domain detection: words that look like domains should match
        check("domain «adguard.com» опознаётся как домен",
              AutoSwitcher.matchesDomainPattern("adguard.com"))
        check("domain «example.org» опознаётся как домен",
              AutoSwitcher.matchesDomainPattern("example.org"))
        check("domain «foo.bar» НЕ опознаётся (.bar не TLD)",
              !AutoSwitcher.matchesDomainPattern("foo.bar"))
        check("обычное слово «hello» НЕ домен",
              !AutoSwitcher.matchesDomainPattern("hello"))
    }
}
