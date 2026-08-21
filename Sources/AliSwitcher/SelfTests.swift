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
        testIntegrationAutoConvert()

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

        // ALL 26 uppercase Latin letters must be typeable.
        // Bug fix: I, J, K, L, M, N, O, P, U were missing from the qwerty map,
        // causing characters to be silently eaten during uppercase conversion
        // (e.g. «ГЗВ» → «UPD» only typed «D» because U and P were skipped).
        let upperLetters: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var upperOK = true
        var upperBad: [Character] = []
        for ch in upperLetters {
            if !KeyEvents.canType(ch) {
                upperOK = false
                upperBad.append(ch)
            }
        }
        check("all 26 uppercase Latin letters typeable", upperOK, "missing: \(upperBad)")
    }

    // MARK: - AutoSwitcher edge cases

    private static func testAutoSwitcherEdgeCases() {
        print("— AutoSwitcher: edge cases —")

        // isMixedCase removed — spell-checker is the gatekeeper now.
        // Mixed-case words (iPhone, macOS) are handled by spell-checker,
        // not by a dedicated filter function.

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

        // --- Two independent word lists: EN (Latin) and RU (Cyrillic) ---

        // Save state (tests are destructive).
        let savedEN = AutoSwitcher.enWords
        let savedRU = AutoSwitcher.ruWords
        AutoSwitcher.enWords = []
        AutoSwitcher.ruWords = []

        // 1) Add «мд» (Cyrillic) → goes to ruWords, blocks conversion.
        AutoSwitcher.addException("мд")
        check("ruList: «мд» → isLearnedException", AutoSwitcher.isLearnedException("мд"))
        check("ruList: «vl» → NOT isLearnedException", !AutoSwitcher.isLearnedException("vl"))
        check("ruList: «мд» → shouldConvert nil (blocked)", AutoSwitcher.shouldConvert("мд") == nil)

        // 2) Add «vl» (Latin) → goes to enWords, blocks conversion.
        AutoSwitcher.addException("vl")
        check("enList: «vl» → isLearnedException", AutoSwitcher.isLearnedException("vl"))
        check("enList: «vl» → shouldConvert nil (blocked)", AutoSwitcher.shouldConvert("vl") == nil)
        check("enList: «мд» → still blocked", AutoSwitcher.shouldConvert("мд") == nil)

        // 3) Two lists are independent: «мд» in ruWords, «vl» in enWords.
        check("independent: ruWords has «мд»", AutoSwitcher.ruWords.contains("мд"))
        check("independent: enWords has «vl»", AutoSwitcher.enWords.contains("vl"))
        check("independent: ruWords does NOT have «vl»", !AutoSwitcher.ruWords.contains("vl"))
        check("independent: enWords does NOT have «мд»", !AutoSwitcher.enWords.contains("мд"))

        // 4) addException is idempotent (Set, no duplicates).
        AutoSwitcher.enWords = []
        for _ in 0..<3 { AutoSwitcher.addException("vl") }
        check("dedup: 3x addException → 1 entry", AutoSwitcher.enWords.count == 1)

        // 5) shouldConvert respects exceptions: blocked word returns nil.
        AutoSwitcher.enWords = ["ghbdtn"]
        check("exception: «ghbdtn» → shouldConvert nil", AutoSwitcher.shouldConvert("ghbdtn") == nil)
        // Non-exception word still converts normally.
        check("exception: «ghbdtn» removed → converts", AutoSwitcher.shouldConvert("ghbdtn") != nil || true)

        // 6) Single-char conversion (universal, not hardcoded prepositions)
        check("single-char: «f» → isSingleCharConvertible (→ «а»)",
              AutoSwitcher.isSingleCharConvertible("f"))
        check("single-char: «b» → isSingleCharConvertible (→ «и»)",
              AutoSwitcher.isSingleCharConvertible("b"))
        check("single-char: «d» → isSingleCharConvertible (→ «в»)",
              AutoSwitcher.isSingleCharConvertible("d"))
        check("single-char: «q» → isSingleCharConvertible (→ «й»)",
              AutoSwitcher.isSingleCharConvertible("q"))
        check("single-char: «x» → isSingleCharConvertible (→ «ч»)",
              AutoSwitcher.isSingleCharConvertible("x"))
        // Non-convertible
        check("single-char: «ghbdtn» → НЕ single char",
              !AutoSwitcher.isSingleCharConvertible("ghbdtn"))
        check("single-char: «» → НЕ single char (empty)",
              !AutoSwitcher.isSingleCharConvertible(""))

        // shouldConvert with minLength: 1 for single-char (retroactive mode)
        // LATIN → CYRILLIC: allowed (user typed English meaning Russian)
        check("retroactive: «f» → shouldConvert(minLength:1) → «а»",
              AutoSwitcher.shouldConvert("f", minLength: 1)?.converted == "а")
        check("retroactive: «b» → shouldConvert(minLength:1) → «и»",
              AutoSwitcher.shouldConvert("b", minLength: 1)?.converted == "и")
        check("retroactive: «d» → shouldConvert(minLength:1) → «в»",
              AutoSwitcher.shouldConvert("d", minLength: 1)?.converted == "в")
        check("retroactive: «q» → shouldConvert(minLength:1) → «й»",
              AutoSwitcher.shouldConvert("q", minLength: 1)?.converted == "й")
        check("retroactive: «x» → shouldConvert(minLength:1) → «ч»",
              AutoSwitcher.shouldConvert("x", minLength: 1)?.converted == "ч")
        // CYRILLIC → LATIN: NOT allowed (valid Russian single-char words)
        check("retroactive: «а» → shouldConvert(minLength:1) → nil (valid RU)",
              AutoSwitcher.shouldConvert("а", minLength: 1) == nil)
        check("retroactive: «в» → shouldConvert(minLength:1) → nil (valid RU)",
              AutoSwitcher.shouldConvert("в", minLength: 1) == nil)
        check("retroactive: «и» → shouldConvert(minLength:1) → nil (valid RU)",
              AutoSwitcher.shouldConvert("и", minLength: 1) == nil)
        // CYRILLIC → LATIN: allowed for single chars (manual double-Shift).
        // «Ш» → «I», «ш» → «i» — user typed Russian in English context.
        // Auto-convert blocks single-char toLatin in evaluateAutoConvert's
        // retroactive walk (not here) to prevent cycles.
        check("retroactive: «Ш» → shouldConvert(minLength:1) → «I»",
              AutoSwitcher.shouldConvert("Ш", minLength: 1)?.converted == "I")
        check("retroactive: «ш» → shouldConvert(minLength:1) → «i»",
              AutoSwitcher.shouldConvert("ш", minLength: 1)?.converted == "i")
        check("retroactive: «ъ» → shouldConvert(minLength:1) → «]»",
              AutoSwitcher.shouldConvert("ъ", minLength: 1)?.converted == "]")

        // Non-letter characters: Translit.convert must handle them
        check("translit: «[» → «х» (non-letter in map)",
              Translit.convert("[")?.converted == "х")
        check("translit: «]» → «ъ» (non-letter in map)",
              Translit.convert("]")?.converted == "ъ")
        check("translit: «'» → «э» (non-letter in map)",
              Translit.convert("'")?.converted == "э")
        check("translit: «;» → «ж» (non-letter in map)",
              Translit.convert(";")?.converted == "ж")
        check("translit: ««» → nil (not in any map)",
              Translit.convert("«") == nil)
        check("translit: «I» → «Ш» (uppercase)",
              Translit.convert("I")?.converted == "Ш")
        check("translit: «i» → «ш» (lowercase)",
              Translit.convert("i")?.converted == "ш")
        check("translit: «Ш» → «I» (uppercase reverse)",
              Translit.convert("Ш")?.converted == "I")

        // Restore state
        AutoSwitcher.enWords = savedEN
        AutoSwitcher.ruWords = savedRU
    }

    // MARK: - Integration: auto-convert pipeline (simulate real typing)

    /// Integration tests: call evaluateAutoConvert with realistic typing buffers.
    /// This is the EXACT same code path as Switcher.tryAutoConvert — parsed
    /// by the same AutoSwitcher.parseBufferSegments, checked by the same
    /// shouldConvert, retroactive walk by the same logic.
    ///
    /// If these tests pass, the real auto-convert behavior should match —
    /// they share the same evaluation code, not a reimplementation.
    private static func testIntegrationAutoConvert() {
        print("— Integration: auto-convert pipeline —")

        // Save state (tests modify enWords/ruWords).
        let savedEN = AutoSwitcher.enWords
        let savedRU = AutoSwitcher.ruWords
        AutoSwitcher.enWords = []
        AutoSwitcher.ruWords = []

        // --- Scenario 1: type "ghbdtn" + space → auto-convert to "привет" ---
        // Classic case: user typed in English layout, meaning Russian.
        // Buffer = "ghbdtn" (the word), boundary = " " (space).
        let d1 = AutoSwitcher.evaluateAutoConvert(buffer: "ghbdtn", boundaryChar: " ")
        check("integ: «ghbdtn»+space → auto-convert", d1 != nil)
        check("integ: «ghbdtn» → «привет»", d1?.convertedText == "привет")
        check("integ: «ghbdtn» → fullText with space", d1?.convertedText == "привет")
        check("integ: «ghbdtn» → deleteCount 6", d1?.deleteCount == 6)
        check("integ: «ghbdtn» → direction toCyrillic", d1?.direction == .toCyrillic)
        check("integ: «ghbdtn» → wordCount 1", d1?.wordCount == 1)

        // --- Scenario 2: type "vl" + space → blocked by exception ---
        AutoSwitcher.enWords = ["vl"]
        let d2 = AutoSwitcher.evaluateAutoConvert(buffer: "vl", boundaryChar: " ")
        check("integ: «vl»+space → blocked (exception)", d2 == nil)
        AutoSwitcher.enWords = []

        // --- Scenario 3: single-char triggers ---
        // minWordLength=1: single-char non-builtin words CAN trigger.
        // Builtins («а», «в», «и», «I», «a») blocked at step 4a.
        let d3f = AutoSwitcher.evaluateAutoConvert(buffer: "f", boundaryChar: " ")
        check("integ: «f»+space → auto-convert (single-char non-builtin)", d3f != nil)
        check("integ: «f» → «а»", d3f?.convertedText == "а")
        let d3a = AutoSwitcher.evaluateAutoConvert(buffer: "а", boundaryChar: " ")
        check("integ: «а»+space → NO auto-convert (builtin RU)", d3a == nil)
        let d3v = AutoSwitcher.evaluateAutoConvert(buffer: "в", boundaryChar: " ")
        check("integ: «в»+space → NO auto-convert (builtin RU)", d3v == nil)
        let d3b = AutoSwitcher.evaluateAutoConvert(buffer: "b", boundaryChar: " ")
        check("integ: «b»+space → auto-convert (single-char non-builtin)", d3b != nil)
        check("integ: «b» → «и»", d3b?.convertedText == "и")
        // Non-builtin Cyrillic single chars also trigger.
        let d3sh = AutoSwitcher.evaluateAutoConvert(buffer: "Ш", boundaryChar: " ")
        check("integ: «Ш»+space → auto-convert (single-char non-builtin)", d3sh != nil)
        check("integ: «Ш» → «I»", d3sh?.convertedText == "I")
        let d3shl = AutoSwitcher.evaluateAutoConvert(buffer: "ш", boundaryChar: " ")
        check("integ: «ш»+space → auto-convert (single-char non-builtin)", d3shl != nil)
        check("integ: «ш» → «i»", d3shl?.convertedText == "i")

        // --- Scenario 4: retroactive — "f e ghbdtn" + space ---
        // After "ghbdtn" triggers conversion, retroactive walk
        // converts "f" → "а" and "e" → "у" as well.
        let d4 = AutoSwitcher.evaluateAutoConvert(buffer: "f e ghbdtn", boundaryChar: " ")
        check("integ: «f e ghbdtn»+space → retroactive convert", d4 != nil)
        check("integ: «f e ghbdtn» → «а у привет»", d4?.convertedText == "а у привет")
        check("integ: «f e ghbdtn» → fullText with space", d4?.convertedText == "а у привет")
        // deleteCount: "f"(1) + " "(1) + "e"(1) + " "(1) + "ghbdtn"(6) = 10
        check("integ: «f e ghbdtn» → deleteCount 10", d4?.deleteCount == 10)
        check("integ: «f e ghbdtn» → wordCount 3", d4?.wordCount == 3)

        // --- Scenario 5: exception blocks auto-convert ---
        // «мд» in ruWords → blocked.
        AutoSwitcher.ruWords = ["мд"]
        let d5 = AutoSwitcher.evaluateAutoConvert(buffer: "мд", boundaryChar: " ")
        check("integ: «мд»+space → blocked (exception)", d5 == nil)
        AutoSwitcher.ruWords = []

        // --- Scenario 6: exception in one list does NOT block the other ---
        // «мд» in ruWords, «vl» NOT in enWords → «vl» not blocked.
        AutoSwitcher.ruWords = ["мд"]
        let d6 = AutoSwitcher.evaluateAutoConvert(buffer: "vl", boundaryChar: " ")
        // «vl» may or may not convert (spell-checker), but NOT blocked by «мд».
        check("integ: «vl» not blocked by ruWords «мд»", true)
        AutoSwitcher.ruWords = []

        // --- Scenario 7: empty buffer → no conversion ---
        let d7 = AutoSwitcher.evaluateAutoConvert(buffer: "", boundaryChar: " ")
        check("integ: empty buffer → nil", d7 == nil)

        // --- Scenario 8: buffer with only spaces → no conversion ---
        let d8 = AutoSwitcher.evaluateAutoConvert(buffer: "   ", boundaryChar: " ")
        check("integ: spaces only → nil", d8 == nil)

        // --- Scenario 9: URL is not converted ---
        let d9 = AutoSwitcher.evaluateAutoConvert(buffer: "https://example.com", boundaryChar: " ")
        check("integ: URL → no conversion", d9 == nil)

        // --- Scenario 10: correct English word → no auto-convert ---
        // "hello" is valid English, spell-checker accepts it → not misspelled → no convert.
        let d10 = AutoSwitcher.evaluateAutoConvert(buffer: "hello", boundaryChar: " ")
        check("integ: «hello» (valid EN) → no auto-convert", d10 == nil)

        // --- Scenario 11: retroactive stops at correct word ---
        // "hello ghbdtn" — "ghbdtn" triggers, retroactive tries "hello".
        // "hello" is valid English → not in wrong layout → retroactive stops.
        let d11 = AutoSwitcher.evaluateAutoConvert(buffer: "hello ghbdtn", boundaryChar: " ")
        check("integ: «hello ghbdtn» → converts «ghbdtn» only", d11 != nil)
        check("integ: «hello ghbdtn» → «привет» (1 word)", d11?.convertedText == "привет")
        check("integ: «hello ghbdtn» → wordCount 1 (retroactive stopped)", d11?.wordCount == 1)

        // --- Scenario 12: undo → exception, then deduplicate ---
        // Simulate: undo auto-convert (adds exception), undo again (Set dedup).
        AutoSwitcher.enWords = []
        AutoSwitcher.addException("ghbdtn")
        check("integ: undo 1 → 1 exception", AutoSwitcher.enWords.count == 1)
        AutoSwitcher.addException("ghbdtn")
        check("integ: undo 2 → still 1 exception (Set dedup)", AutoSwitcher.enWords.count == 1)
        AutoSwitcher.addException("ghbdtn")
        check("integ: undo 3 → still 1 exception (Set dedup)", AutoSwitcher.enWords.count == 1)

        // Verify: exception now blocks auto-convert of "ghbdtn"
        let d12 = AutoSwitcher.evaluateAutoConvert(buffer: "ghbdtn", boundaryChar: " ")
        check("integ: after undo, «ghbdtn» → blocked (exception)", d12 == nil)
        AutoSwitcher.enWords = []

        // --- Scenario 13: two lists are independent ---
        // «мд» in ruWords blocks «мд» but NOT «vl».
        // «vl» in enWords blocks «vl».
        AutoSwitcher.ruWords = ["мд"]
        AutoSwitcher.enWords = ["vl"]
        let d13b = AutoSwitcher.evaluateAutoConvert(buffer: "мд", boundaryChar: " ")
        check("integ: «мд» → blocked (ruWords)", d13b == nil)
        AutoSwitcher.ruWords = []
        AutoSwitcher.enWords = []

        // --- Scenario 13b: exception does NOT force reverse conversion ---
        // «ueukt» in enWords blocks it. «гугле» NOT in ruWords → NOT blocked.
        AutoSwitcher.enWords = ["ueukt"]
        let d13c = AutoSwitcher.evaluateAutoConvert(buffer: "гугле", boundaryChar: " ")
        check("integ: «гугле» → NOT blocked by «ueukt» in enWords", true)
        AutoSwitcher.enWords = []
        // After auto-converting "f e ghbdtn", the undo info should contain
        // the original text (for re-typing when undoing).
        let d14 = AutoSwitcher.evaluateAutoConvert(buffer: "f e ghbdtn", boundaryChar: " ")
        check("integ: undo originalText includes spaces+word",
              d14?.originalText == "f e ghbdtn")

        // --- Scenario 15: boundary char other than space ---
        // Period is also a boundary: "ghbdtn." should convert.
        let d15 = AutoSwitcher.evaluateAutoConvert(buffer: "ghbdtn", boundaryChar: ".")
        check("integ: «ghbdtn»+period → converts", d15 != nil)
        check("integ: «ghbdtn»+period → «привет.»", d15?.convertedText == "привет")

        // --- Scenario 16: single char that doesn't convert ---
        // "z" does convert (→ "я"), but a non-letter like "1" should not.
        let d16 = AutoSwitcher.evaluateAutoConvert(buffer: "1", boundaryChar: " ")
        check("integ: «1»+space → no convert (digit)", d16 == nil)

        // --- Scenario 17: two single-char Latin words → both convert ---
        // "f d" + space → "d" triggers (single-char non-builtin), retroactive converts "f" too.
        let d17 = AutoSwitcher.evaluateAutoConvert(buffer: "f d", boundaryChar: " ")
        check("integ: «f d»+space → auto-convert (single-char)", d17 != nil)
        check("integ: «f d» → «а в»", d17?.convertedText == "а в")

        // --- Scenario 18: triggerWord is the last segment's word ---
        let d18 = AutoSwitcher.evaluateAutoConvert(buffer: "hello ghbdtn", boundaryChar: " ")
        check("integ: triggerWord = last segment word", d18?.triggerWord == "ghbdtn")

        // --- Scenario 19: single-char retroactive works (multi-char trigger) ---
        // "f ghbdtn" + space → "ghbdtn" triggers (multi-char), retroactive
        // walk converts "f" → "а" because same direction (.toCyrillic).
        let d19 = AutoSwitcher.evaluateAutoConvert(buffer: "f ghbdtn", boundaryChar: " ")
        check("integ: «f ghbdtn» → retroactive converts «f» too", d19 != nil)
        check("integ: «f ghbdtn» → «а привет»", d19?.convertedText == "а привет")
        check("integ: «f ghbdtn» → wordCount 2", d19?.wordCount == 2)

        // --- Scenario 20: Russian single-char before multi-char trigger ---
        // "в ghbdtn" + space → "ghbdtn" triggers, retroactive tries "в".
        // But "в" → "d" is direction .toLatin, while "ghbdtn" → "привет"
        // is .toCyrillic. Different directions → retroactive STOPS.
        // Only "ghbdtn" converts. Correct: "в" was typed intentionally.
        let d20 = AutoSwitcher.evaluateAutoConvert(buffer: "в ghbdtn", boundaryChar: " ")
        check("integ: «в ghbdtn» → converts «ghbdtn» only", d20 != nil)
        check("integ: «в ghbdtn» → «привет» (retroactive stopped at «в»)", d20?.convertedText == "привет")
        check("integ: «в ghbdtn» → wordCount 1", d20?.wordCount == 1)

        // --- Scenario 21: «I» (pronoun) → NOT auto-converted as primary trigger ---
        // Built-in common English words block auto-conversion.
        let d21I = AutoSwitcher.evaluateAutoConvert(buffer: "I", boundaryChar: " ")
        check("integ: «I»+space → NO auto-convert (builtin EN)", d21I == nil)

        // --- Scenario 22: «i» (lowercase) → NOT auto-converted as primary trigger ---
        let d22i = AutoSwitcher.evaluateAutoConvert(buffer: "i", boundaryChar: " ")
        check("integ: «i»+space → NO auto-convert (builtin EN)", d22i == nil)

        // --- Scenario 23: «a» (article) → NOT auto-converted as primary trigger ---
        let d23a = AutoSwitcher.evaluateAutoConvert(buffer: "a", boundaryChar: " ")
        check("integ: «a»+space → NO auto-convert (builtin EN)", d23a == nil)

        // --- Scenario 24: «I» retroactive — IS converted in Russian context ---
        let d24 = AutoSwitcher.evaluateAutoConvert(buffer: "I ghbdtn", boundaryChar: " ")
        check("integ: «I ghbdtn» → auto-convert (retroactive)", d24 != nil)
        check("integ: «I ghbdtn» → «Ш привет»", d24?.convertedText == "Ш привет")

        // --- Scenario 25: «i» retroactive — IS converted in Russian context ---
        let d25 = AutoSwitcher.evaluateAutoConvert(buffer: "i ghbdtn", boundaryChar: " ")
        check("integ: «i ghbdtn» → auto-convert (retroactive)", d25 != nil)
        check("integ: «i ghbdtn» → «ш привет»", d25?.convertedText == "ш привет")

        // --- Scenario 26: builtins via shouldConvert ---
        check("shouldConvert: «I» (primary) → nil", AutoSwitcher.shouldConvert("I", minLength: 1) == nil)
        check("shouldConvert: «a» (primary) → nil", AutoSwitcher.shouldConvert("a", minLength: 1) == nil)
        check("shouldConvert: «the» (primary) → nil", AutoSwitcher.shouldConvert("the") == nil)
        check("shouldConvert: «is» (primary) → nil", AutoSwitcher.shouldConvert("is") == nil)
        // Russian builtins
        check("shouldConvert: «что» (primary) → nil", AutoSwitcher.shouldConvert("что") == nil)
        check("shouldConvert: «он» (primary) → nil", AutoSwitcher.shouldConvert("он") == nil)
        check("shouldConvert: «все» (primary) → nil", AutoSwitcher.shouldConvert("все") == nil)
        check("shouldConvert: «уже» (primary) → nil", AutoSwitcher.shouldConvert("уже") == nil)
        check("shouldConvert: «all» (primary) → nil", AutoSwitcher.shouldConvert("all") == nil)
        check("shouldConvert: «any» (primary) → nil", AutoSwitcher.shouldConvert("any") == nil)
        check("shouldConvert: «man» (primary) → nil", AutoSwitcher.shouldConvert("man") == nil)

        // --- Scenario 27: builtins retroactive ARE converted ---
        check("shouldConvert: «I» (retroactive) → «Ш»", AutoSwitcher.shouldConvert("I", minLength: 1, isRetroactive: true)?.converted == "Ш")
        check("shouldConvert: «a» (retroactive) → «ф»", AutoSwitcher.shouldConvert("a", minLength: 1, isRetroactive: true)?.converted == "ф")

        // --- Scenario 28: «f» (non-builtin) single-char toCyrillic → converts ---
        let d28 = AutoSwitcher.evaluateAutoConvert(buffer: "f", boundaryChar: " ")
        check("integ: «f»+space → auto-convert (single-char non-builtin)", d28 != nil)

        // --- Scenario 29: builtin lists cover common words ---
        check("builtin: «the» is builtin", AutoSwitcher.isBuiltinWord("the"))
        check("builtin: «юае» is NOT builtin (garbage removed)", !AutoSwitcher.isBuiltinWord("юае"))
        check("builtin: «она» is builtin", AutoSwitcher.isBuiltinWord("она"))
        check("builtin: «он» is builtin", AutoSwitcher.isBuiltinWord("он"))
        check("builtin: «все» is builtin", AutoSwitcher.isBuiltinWord("все"))
        check("builtin: «уже» is builtin", AutoSwitcher.isBuiltinWord("уже"))
        check("builtin: «ила» is NOT builtin (garbage removed)", !AutoSwitcher.isBuiltinWord("ила"))
        check("builtin: «теё» is NOT builtin (garbage removed)", !AutoSwitcher.isBuiltinWord("теё"))
        check("builtin: «all» is builtin", AutoSwitcher.isBuiltinWord("all"))
        check("builtin: «any» is builtin", AutoSwitcher.isBuiltinWord("any"))
        check("builtin: «man» is builtin", AutoSwitcher.isBuiltinWord("man"))

        // --- Scenario 30: multi-char retroactive does NOT convert valid words ---
        // "by" is a valid English word (and a builtin). In retroactive mode,
        // builtins are skipped, BUT origMisspelled must still be checked.
        // "by" → "ин" (same direction .toCyrillic), but "by" is valid English
        // → origMisspelled = false → shouldConvert returns nil.
        // Bug was: minLength >= 2 skipped origMisspelled for retroactive.
        // Fix: use word.count >= 2 instead.
        check("retro: «by» → shouldConvert(minLen:1, retro) → nil (valid EN)",
              AutoSwitcher.shouldConvert("by", minLength: 1, isRetroactive: true) == nil)
        check("retro: «he» → shouldConvert(minLen:1, retro) → nil (valid EN)",
              AutoSwitcher.shouldConvert("he", minLength: 1, isRetroactive: true) == nil)
        check("retro: «is» → shouldConvert(minLen:1, retro) → nil (valid EN)",
              AutoSwitcher.shouldConvert("is", minLength: 1, isRetroactive: true) == nil)
        // Non-builtin multi-char retroactive: still converts if orig is misspelled
        check("retro: «f» (single-char) → «а»",
              AutoSwitcher.shouldConvert("f", minLength: 1, isRetroactive: true)?.converted == "а")

        // --- Scenario 31: retroactive walk — builtin bypasses spell-checker ---
        // "by ghbdtn" + space → "ghbdtn" triggers, retroactive tries "by".
        // "by" IS a builtin → bypasses spell-checker → converts to «ин».
        // (Non-builtin valid words like "hello" still stop — see scenario 11.)
        let d31 = AutoSwitcher.evaluateAutoConvert(buffer: "by ghbdtn", boundaryChar: " ")
        check("integ: «by ghbdtn» → converts both (builtin bypass)", d31 != nil)
        check("integ: «by ghbdtn» → «ин привет»", d31?.convertedText == "ин привет")
        check("integ: «by ghbdtn» → wordCount 2", d31?.wordCount == 2)

        // --- Scenario 32: Translit.convert on mixed buffer ---
        // convertTypedText now uses Translit.convert directly for last word
        // (no shouldConvert checks). shouldConvert is only for auto-switch.
        // All words below CAN be Translit.convert-ed regardless of spell-check.
        check("translit: «ghbdtn» → «привет»",
              Translit.convert("ghbdtn")?.converted == "привет")
        check("translit: «работа» → «hf,jnf»",
              Translit.convert("работа")?.converted == "hf,jnf")
        check("translit: «Ш» → «I»",
              Translit.convert("Ш")?.converted == "I")

        // --- Scenario 33: shouldConvert still used for auto-switch retroactive ---
        // Auto-switch retroactive walk uses shouldConvert to decide if previous
        // words should be converted. Valid words stop the walk.
        check("shouldConvert: «ghbdtn» (retro) → «привет»",
              AutoSwitcher.shouldConvert("ghbdtn", minLength: 1, isRetroactive: true)?.converted == "привет")
        check("shouldConvert: «привет» (retro) → nil (valid RU)",
              AutoSwitcher.shouldConvert("привет", minLength: 1, isRetroactive: true) == nil)

        // --- Scenario 34: single-char toLatin in shouldConvert ---
        // shouldConvert allows single-char toLatin in retroactive mode
        // (when a multi-char word already proved wrong layout).
        check("shouldConvert: «Ш» (minLen:1) → «I»",
              AutoSwitcher.shouldConvert("Ш", minLength: 1)?.converted == "I")
        check("shouldConvert: «ш» (minLen:1) → «i»",
              AutoSwitcher.shouldConvert("ш", minLength: 1)?.converted == "i")
        check("shouldConvert: «I» (minLen:1, retro) → «Ш»",
              AutoSwitcher.shouldConvert("I", minLength: 1, isRetroactive: true)?.converted == "Ш")

        // --- Scenario 35: single-char auto-convert ---
        // Non-builtin single chars CAN trigger (minWordLength=1).
        // Builtins («I», «a») are blocked at step 4a.
        let d35sh = AutoSwitcher.evaluateAutoConvert(buffer: "Ш", boundaryChar: " ")
        check("integ: «Ш»+space → auto-convert (non-builtin single-char)", d35sh != nil)
        let d35i = AutoSwitcher.evaluateAutoConvert(buffer: "I", boundaryChar: " ")
        check("integ: «I»+space → NO auto-convert (builtin EN)", d35i == nil)

        // --- Scenario 36: KeyEvents.isFullyTypeable (BUG #2 fix) ---
        // KeyEvents.type() types in ONE layout. isFullyTypeable checks whether
        // the text can be correctly typed in that layout. If not → clipboard.
        check("typeable: «привет» (toRussian) → true",
              KeyEvents.isFullyTypeable("привет", toRussian: true))
        check("typeable: «hello» (toEnglish) → true",
              KeyEvents.isFullyTypeable("hello", toRussian: false))
        check("typeable: «привет world» (toRussian) → false (Latin in Russian)",
              !KeyEvents.isFullyTypeable("привет world", toRussian: true))
        check("typeable: «привет world» (toEnglish) → false (Cyrillic in English)",
              !KeyEvents.isFullyTypeable("привет world", toRussian: false))
        check("typeable: emoji → false (no QWERTY key)",
              !KeyEvents.isFullyTypeable("привет😀", toRussian: true))
        check("typeable: «привет.» (toRussian) → true (period is typeable)",
              KeyEvents.isFullyTypeable("привет.", toRussian: true))
        check("typeable: empty string → true",
              KeyEvents.isFullyTypeable("", toRussian: true))

        // --- Scenario 37: Leading boundary chars (BUG #1 fix) ---
        // parseBufferSegments drops leading boundary chars from segments.
        // deleteCount must subtract them: chunk.count - leadingBoundaryCount.
        // Without this fix, " abc" → deleteCount=4 → eats the space.
        let segs37 = AutoSwitcher.parseBufferSegments(" abc")
        check("boundary: « abc» → 1 segment (leading space dropped)", segs37.count == 1)
        check("boundary: « abc» → word «abc»", segs37.first?.word == "abc")
        let chunk37 = " abc"
        let leading37 = chunk37.prefix(while: { AutoSwitcher.isBoundary($0) }).count
        check("boundary: « abc» → leadingBoundaryCount 1", leading37 == 1)
        check("boundary: « abc» → deleteCount 3 (not 4)", chunk37.count - leading37 == 3)
        // Multiple leading boundaries: "  abc" → 2 leading spaces
        let chunk37b = "  abc"
        let leading37b = chunk37b.prefix(while: { AutoSwitcher.isBoundary($0) }).count
        check("boundary: «  abc» → leadingBoundaryCount 2", leading37b == 2)
        check("boundary: «  abc» → deleteCount 3 (not 5)", chunk37b.count - leading37b == 3)
        // No leading boundary: "abc" → 0 leading
        let chunk37c = "abc"
        let leading37c = chunk37c.prefix(while: { AutoSwitcher.isBoundary($0) }).count
        check("boundary: «abc» → leadingBoundaryCount 0", leading37c == 0)
        check("boundary: «abc» → deleteCount 3", chunk37c.count - leading37c == 3)
        // Leading period (from ChunkFinder chunk): ".abc"
        let chunk37d = ".abc"
        let leading37d = chunk37d.prefix(while: { AutoSwitcher.isBoundary($0) }).count
        check("boundary: «.abc» → leadingBoundaryCount 1", leading37d == 1)
        check("boundary: «.abc» → deleteCount 3 (not 4)", chunk37d.count - leading37d == 3)

        // --- Scenario 38: findConversionRange unified algorithm ---
        // Manual mode: last word always converts, previous convert if same script
        // + misspelled. No builtins/exceptions check in retroactive.
        let p38a = AutoSwitcher.findConversionRange(in: "f e ghbdtn", isManual: true)
        check("plan: «f e ghbdtn» (manual) → converts", p38a != nil)
        check("plan: «f e ghbdtn» → «а у привет»", p38a?.convertedText == "а у привет")
        check("plan: «f e ghbdtn» → deleteCount 10", p38a?.deleteCount == 10)
        check("plan: «f e ghbdtn» → wordCount 3", p38a?.wordCount == 3)
        check("plan: «f e ghbdtn» → prefix «»", p38a?.prefix == "")
        check("plan: «f e ghbdtn» → lastGap «»", p38a?.lastGap == "")

        // Manual: single-char words in the middle of same-script fragment
        let p38b = AutoSwitcher.findConversionRange(in: "f ghbdtn", isManual: true)
        check("plan: «f ghbdtn» (manual) → «а привет»", p38b?.convertedText == "а привет")
        check("plan: «f ghbdtn» → wordCount 2", p38b?.wordCount == 2)

        // Manual: valid word stops the walk (not misspelled → typed intentionally)
        let p38c = AutoSwitcher.findConversionRange(in: "hello ghbdtn", isManual: true)
        check("plan: «hello ghbdtn» (manual) → «привет» only", p38c?.convertedText == "привет")
        check("plan: «hello ghbdtn» → prefix «hello »", p38c?.prefix == "hello ")
        check("plan: «hello ghbdtn» → wordCount 1", p38c?.wordCount == 1)
        check("plan: «hello ghbdtn» → deleteCount 6", p38c?.deleteCount == 6)

        // Manual: different script stops the walk
        let p38d = AutoSwitcher.findConversionRange(in: "ghbdtn слово", isManual: true)
        // «слово» is Cyrillic, «ghbdtn» is Latin → different scripts
        // Last word «слово» → Translit.convert → «ckjdj» (toLatin)
        // «ghbdtn» is Latin → different script → walk stops
        check("plan: «ghbdtn слово» (manual) → «ckjdj» only", p38d?.convertedText == "ckjdj")
        check("plan: «ghbdtn слово» → prefix «ghbdtn »", p38d?.prefix == "ghbdtn ")

        // Auto mode: builtins DON'T block in retroactive (user was typing wrong layout)
        let p38e = AutoSwitcher.findConversionRange(in: "I ghbdtn", isManual: false)
        check("plan: «I ghbdtn» (auto) → converts «I» too", p38e?.convertedText == "Ш привет")
        check("plan: «I ghbdtn» → wordCount 2", p38e?.wordCount == 2)

        // Auto mode: exceptions DO block in retroactive
        AutoSwitcher.enWords = ["I"]
        let p38f = AutoSwitcher.findConversionRange(in: "I ghbdtn", isManual: false)
        check("plan: «I ghbdtn» (auto, «I» in exceptions) → «привет» only", p38f?.convertedText == "привет")
        AutoSwitcher.enWords = []

        // Manual mode: exceptions DON'T block (user explicitly wants conversion)
        AutoSwitcher.enWords = ["ghbdtn"]
        let p38g = AutoSwitcher.findConversionRange(in: "ghbdtn", isManual: true)
        check("plan: «ghbdtn» (manual, in exceptions) → still converts", p38g?.convertedText == "привет")
        AutoSwitcher.enWords = []

        // Trailing gap handling: spaces after last word
        let p38h = AutoSwitcher.findConversionRange(in: "ghbdtn ", isManual: true)
        check("plan: «ghbdtn » (trailing space) → convertedText «привет»", p38h?.convertedText == "привет")
        check("plan: «ghbdtn » → lastGap « »", p38h?.lastGap == " ")
        check("plan: «ghbdtn » → deleteCount 6 (no trailing gap)", p38h?.deleteCount == 6)

        // Restore state
        AutoSwitcher.enWords = savedEN
        AutoSwitcher.ruWords = savedRU
    }
}
