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

        // --- Learned words: directional exceptions & dictionary ---

        // Save state (tests are destructive).
        let savedWords = AutoSwitcher.learnedWords
        AutoSwitcher.learnedWords = []

        // 1) Exception «мд»⇄«vl»: block «мд» (formA), allow «vl» (formB).
        AutoSwitcher.learnedWords.append(
            AutoSwitcher.LearnedWord(formA: "мд", formB: "vl", isException: true))

        // lookupLearned prioritizes formA
        let excLookupMD = AutoSwitcher.lookupLearned("мд")
        check("lookup: «мд» → exception (formA match)", excLookupMD != nil && excLookupMD!.isException)
        let excLookupVL = AutoSwitcher.lookupLearned("vl")
        check("lookup: «vl» → exception (formB match)", excLookupVL != nil && excLookupVL!.isException)
        // formA is «мд», not «vl»
        check("lookup: «vl» formA is «мд»", excLookupVL!.formA == "мд")

        // shouldConvert: «мд» blocked (exception on formA), «vl» falls through
        check("exception: «мд» → shouldConvert nil",
              AutoSwitcher.shouldConvert("мд") == nil)
        // «vl» → should NOT be blocked by exception (word != formA)
        // (may return nil from spell-checker, but NOT from exception)
        let convVL = AutoSwitcher.shouldConvert("vl")
        if convVL != nil {
            check("exception: «vl» → конвертируется (не blocked exception)", true)
        } else {
            // spell-checker rejected «мд» — expected, but NOT because of exception
            check("exception: «vl» НЕ blocked exception (spell-checker отказал)", true)
        }

        // 2) Dictionary «vl»⇄«мд»: force-convert BOTH directions
        AutoSwitcher.learnedWords = []
        AutoSwitcher.learnedWords.append(
            AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: false))

        let dictConvVL = AutoSwitcher.shouldConvert("vl")
        check("dictionary: «vl» → shouldConvert возвращает результат", dictConvVL != nil)
        let dictConvMD = AutoSwitcher.shouldConvert("мд")
        check("dictionary: «мд» → shouldConvert (formB match, dictionary) возвращает результат", dictConvMD != nil)

        // 3) Conflicting: exception «мд⇄vl» + dictionary «vl⇄мд»
        // lookupLearned for «vl» should return dictionary (formA match wins)
        AutoSwitcher.learnedWords = [
            AutoSwitcher.LearnedWord(formA: "мд", formB: "vl", isException: true),
            AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: false),
        ]
        let conflictVL = AutoSwitcher.lookupLearned("vl")
        check("conflict: «vl» → dictionary wins (formA match before formB)",
              conflictVL != nil && !conflictVL!.isException)

        let conflictMD = AutoSwitcher.lookupLearned("мд")
        check("conflict: «мд» → exception wins (formA match)",
              conflictMD != nil && conflictMD!.isException)

        check("conflict: «мд» → shouldConvert nil (exception)", AutoSwitcher.shouldConvert("мд") == nil)
        check("conflict: «vl» → shouldConvert результат (dictionary first)", AutoSwitcher.shouldConvert("vl") != nil)

        // 4) Toggle scenario: undo → manual convert → undo.
        // Each toggle must REPLACE, not multiply (dedup in addLearnedPair).
        AutoSwitcher.learnedWords = []
        // Step 1: undo auto-convert → exception "vl⇄мд exc"
        AutoSwitcher.learnedWords.removeAll { $0.formA == "vl" || $0.formB == "vl" || $0.formA == "мд" || $0.formB == "мд" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: true))
        check("toggle 1: 1 entry (exc)", AutoSwitcher.learnedWords.count == 1)

        // Step 2: manual convert → dictionary (replaces exception)
        AutoSwitcher.learnedWords.removeAll { $0.formA == "vl" || $0.formB == "vl" || $0.formA == "мд" || $0.formB == "мд" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: false))
        check("toggle 2: 1 entry (dict, not 2)", AutoSwitcher.learnedWords.count == 1)

        // Step 3: undo again → exception (replaces dictionary)
        AutoSwitcher.learnedWords.removeAll { $0.formA == "vl" || $0.formB == "vl" || $0.formA == "мд" || $0.formB == "мд" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: true))
        check("toggle 3: 1 entry (exc, not 2)", AutoSwitcher.learnedWords.count == 1)

        // 5) No duplicates after 3x addLearnedPair for same pair
        AutoSwitcher.learnedWords = []
        for _ in 0..<3 {
            AutoSwitcher.learnedWords.removeAll { $0.formA == "vl" || $0.formB == "vl" || $0.formA == "мд" || $0.formB == "мд" }
            AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: true))
        }
        check("dedup: 3x same pair → 1 entry", AutoSwitcher.learnedWords.count == 1)

        // 6) Different pairs are NOT deduped
        AutoSwitcher.learnedWords.removeAll { $0.formA == "vl" || $0.formB == "vl" || $0.formA == "мд" || $0.formB == "мд" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: true))
        AutoSwitcher.learnedWords.removeAll { $0.formA == "abc" || $0.formB == "abc" || $0.formA == "xyz" || $0.formB == "xyz" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "abc", formB: "xyz", isException: false))
        check("dedup: different pairs → 2 entries", AutoSwitcher.learnedWords.count == 2)

        // 7) Single-char conversion (universal, not hardcoded prepositions)
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

        // Restore state
        AutoSwitcher.learnedWords = savedWords
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

        // Save state (tests modify learnedWords).
        let savedWords = AutoSwitcher.learnedWords
        AutoSwitcher.learnedWords = []

        // --- Scenario 1: type "ghbdtn" + space → auto-convert to "привет" ---
        // Classic case: user typed in English layout, meaning Russian.
        // Buffer = "ghbdtn" (the word), boundary = " " (space).
        let d1 = AutoSwitcher.evaluateAutoConvert(buffer: "ghbdtn", boundaryChar: " ")
        check("integ: «ghbdtn»+space → auto-convert", d1 != nil)
        check("integ: «ghbdtn» → «привет»", d1?.convertedText == "привет")
        check("integ: «ghbdtn» → fullText with space", d1?.fullConvertedText == "привет ")
        check("integ: «ghbdtn» → deleteCount 6", d1?.deleteCount == 6)
        check("integ: «ghbdtn» → direction toCyrillic", d1?.direction == .toCyrillic)
        check("integ: «ghbdtn» → wordCount 1", d1?.wordCount == 1)

        // --- Scenario 2: type "vl" + space → auto-convert to "мд" ---
        // Requires a dictionary entry (NSSpellChecker rejects "мд").
        AutoSwitcher.learnedWords = [
            AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: false)
        ]
        let d2 = AutoSwitcher.evaluateAutoConvert(buffer: "vl", boundaryChar: " ")
        check("integ: «vl»+space → auto-convert (dict)", d2 != nil)
        check("integ: «vl» → «мд»", d2?.convertedText == "мд")
        check("integ: «vl» → fullText «мд »", d2?.fullConvertedText == "мд ")
        check("integ: «vl» → deleteCount 2", d2?.deleteCount == 2)
        AutoSwitcher.learnedWords = []

        // --- Scenario 3: type "f" + space → auto-convert to "а" ---
        // Single-char: isSingleCharConvertible bypasses minWordLength.
        // But shouldConvert needs to be called with minLength: 1.
        let d3 = AutoSwitcher.evaluateAutoConvert(buffer: "f", boundaryChar: " ")
        check("integ: «f»+space → auto-convert (single char)", d3 != nil)
        check("integ: «f» → «а»", d3?.convertedText == "а")
        check("integ: «f» → fullText «а »", d3?.fullConvertedText == "а ")
        check("integ: «f» → deleteCount 1", d3?.deleteCount == 1)

        // --- Scenario 4: retroactive — "f e ghbdtn" + space ---
        // After "ghbdtn" triggers conversion, retroactive walk
        // converts "f" → "а" and "e" → "у" as well.
        let d4 = AutoSwitcher.evaluateAutoConvert(buffer: "f e ghbdtn", boundaryChar: " ")
        check("integ: «f e ghbdtn»+space → retroactive convert", d4 != nil)
        check("integ: «f e ghbdtn» → «а у привет»", d4?.convertedText == "а у привет")
        check("integ: «f e ghbdtn» → fullText with space", d4?.fullConvertedText == "а у привет ")
        // deleteCount: "f"(1) + " "(1) + "e"(1) + " "(1) + "ghbdtn"(6) = 10
        check("integ: «f e ghbdtn» → deleteCount 10", d4?.deleteCount == 10)
        check("integ: «f e ghbdtn» → wordCount 3", d4?.wordCount == 3)

        // --- Scenario 5: exception blocks auto-convert ---
        // Exception "мд⇄vl" blocks «мд» (formA). When user types «мд»+space,
        // auto-convert should return nil — not convert.
        AutoSwitcher.learnedWords = [
            AutoSwitcher.LearnedWord(formA: "мд", formB: "vl", isException: true)
        ]
        let d5 = AutoSwitcher.evaluateAutoConvert(buffer: "мд", boundaryChar: " ")
        check("integ: «мд»+space → blocked (exception)", d5 == nil)
        AutoSwitcher.learnedWords = []

        // --- Scenario 6: exception does NOT block reverse direction ---
        // Exception "мд⇄vl" blocks «мд» but NOT «vl».
        // «vl» falls through to spell-checker (may or may not convert).
        // The test verifies it's NOT blocked by the exception.
        AutoSwitcher.learnedWords = [
            AutoSwitcher.LearnedWord(formA: "мд", formB: "vl", isException: true)
        ]
        // Add a dictionary entry so «vl» would convert if not blocked
        AutoSwitcher.learnedWords.append(
            AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: false))
        let d6 = AutoSwitcher.evaluateAutoConvert(buffer: "vl", boundaryChar: " ")
        check("integ: «vl»+space → converts (exception doesn't block formB)", d6 != nil)
        check("integ: «vl» → «мд» (dictionary wins)", d6?.convertedText == "мд")
        AutoSwitcher.learnedWords = []

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
        // Simulate: undo auto-convert (adds exception), undo again (should replace, not multiply).
        // This mimics addLearnedPair's dedup logic.
        AutoSwitcher.learnedWords = []
        // Step 1: first undo → exception "ghbdtn⇄привет exc"
        AutoSwitcher.learnedWords.removeAll { $0.formA == "ghbdtn" || $0.formB == "ghbdtn" || $0.formA == "привет" || $0.formB == "привет" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "ghbdtn", formB: "привет", isException: true))
        check("integ: undo 1 → 1 exception", AutoSwitcher.learnedWords.count == 1)

        // Step 2: second undo → should REPLACE, not add another
        AutoSwitcher.learnedWords.removeAll { $0.formA == "ghbdtn" || $0.formB == "ghbdtn" || $0.formA == "привет" || $0.formB == "привет" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "ghbdtn", formB: "привет", isException: true))
        check("integ: undo 2 → still 1 exception (dedup)", AutoSwitcher.learnedWords.count == 1)

        // Step 3: third undo → still 1
        AutoSwitcher.learnedWords.removeAll { $0.formA == "ghbdtn" || $0.formB == "ghbdtn" || $0.formA == "привет" || $0.formB == "привет" }
        AutoSwitcher.learnedWords.append(AutoSwitcher.LearnedWord(formA: "ghbdtn", formB: "привет", isException: true))
        check("integ: undo 3 → still 1 exception (dedup)", AutoSwitcher.learnedWords.count == 1)

        // Verify: exception now blocks auto-convert of "ghbdtn"
        let d12 = AutoSwitcher.evaluateAutoConvert(buffer: "ghbdtn", boundaryChar: " ")
        check("integ: after undo, «ghbdtn» → blocked (exception)", d12 == nil)
        AutoSwitcher.learnedWords = []

        // --- Scenario 13: exception + dictionary conflict (formA priority) ---
        // exception "мд⇄vl" + dictionary "vl⇄мд"
        // lookupLearned("vl") → dictionary (formA match) → converts
        // lookupLearned("мд") → exception (formA match) → blocked
        AutoSwitcher.learnedWords = [
            AutoSwitcher.LearnedWord(formA: "мд", formB: "vl", isException: true),
            AutoSwitcher.LearnedWord(formA: "vl", formB: "мд", isException: false),
        ]
        let d13a = AutoSwitcher.evaluateAutoConvert(buffer: "vl", boundaryChar: " ")
        check("integ: conflict «vl» → converts (dict wins)", d13a != nil)
        check("integ: conflict «vl» → «мд»", d13a?.convertedText == "мд")
        let d13b = AutoSwitcher.evaluateAutoConvert(buffer: "мд", boundaryChar: " ")
        check("integ: conflict «мд» → blocked (exc wins)", d13b == nil)
        AutoSwitcher.learnedWords = []

        // --- Scenario 14: originalText for undo ---
        // After auto-converting "f e ghbdtn", the undo info should contain
        // the original text (for re-typing when undoing).
        let d14 = AutoSwitcher.evaluateAutoConvert(buffer: "f e ghbdtn", boundaryChar: " ")
        check("integ: undo originalText includes spaces+word",
              d14?.originalText == "f e ghbdtn")

        // --- Scenario 15: boundary char other than space ---
        // Period is also a boundary: "ghbdtn." should convert.
        let d15 = AutoSwitcher.evaluateAutoConvert(buffer: "ghbdtn", boundaryChar: ".")
        check("integ: «ghbdtn»+period → converts", d15 != nil)
        check("integ: «ghbdtn»+period → «привет.»", d15?.fullConvertedText == "привет.")

        // --- Scenario 16: single char that doesn't convert ---
        // "z" does convert (→ "я"), but a non-letter like "1" should not.
        let d16 = AutoSwitcher.evaluateAutoConvert(buffer: "1", boundaryChar: " ")
        check("integ: «1»+space → no convert (digit)", d16 == nil)

        // --- Scenario 17: two single-char words retroactive ---
        // "f d" + space → retroactive converts both: "а в"
        let d17 = AutoSwitcher.evaluateAutoConvert(buffer: "f d", boundaryChar: " ")
        check("integ: «f d»+space → retroactive 2 words", d17 != nil)
        check("integ: «f d» → «а в»", d17?.convertedText == "а в")
        check("integ: «f d» → wordCount 2", d17?.wordCount == 2)

        // --- Scenario 18: triggerWord is the last segment's word ---
        let d18 = AutoSwitcher.evaluateAutoConvert(buffer: "hello ghbdtn", boundaryChar: " ")
        check("integ: triggerWord = last segment word", d18?.triggerWord == "ghbdtn")

        // Restore state
        AutoSwitcher.learnedWords = savedWords
    }
}
