import Foundation
import AppKit

/// Automatic layout switching (Punto Switcher style).
///
/// When the user types a word in the wrong layout and hits a boundary
/// (space, period, comma, etc.), we check the word with NSSpellChecker:
///
///   - If the original word is **misspelled** in its own language
///   - AND the converted word is **valid** in the other language
///
/// → we auto-convert it (backspace + retype in the correct layout).
///
/// This mirrors what Punto Switcher does: it waits for a word boundary,
/// then checks the last word and silently corrects it.
enum AutoSwitcher {

    /// Minimum word length to check. Single-char words CAN trigger
    /// auto-convert — but builtin word lists protect common single-char
    /// words (а, в, и, I, a) from false-positive conversion.
    static let minWordLength = 1

    // MARK: - Built-in common word lists
    //
    // These are high-frequency short words in each language that
    // NSSpellChecker sometimes doesn't recognize (especially Russian
    // colloquial forms, abbreviations, or words missing from the system
    // dictionary). Without this list, false-positive auto-conversions happen.
    //
    // Direction is implicit: Latin words → never convert to Russian;
    // Cyrillic words → never convert to English.
    // Built-in lists are ALWAYS checked (can't be removed by user).

    /// Common English short words that should NEVER be auto-converted.
    /// Loaded from builtin_words_en.txt (Contents/Resources/).
    /// Only 1-3 char words: longer words are handled by NSSpellChecker.
    /// Falls back to empty set if file is missing (e.g. running from CLI).
    static let builtinEnWords: Set<String> = loadBuiltinWords("builtin_words_en")

    /// Common Russian short words that should NEVER be auto-converted.
    /// Loaded from builtin_words_ru.txt (Contents/Resources/).
    /// Only 1-3 char words: longer words are handled by NSSpellChecker.
    /// Falls back to empty set if file is missing (e.g. running from CLI).
    static let builtinRuWords: Set<String> = loadBuiltinWords("builtin_words_ru")

    /// Loads builtin word list from a .txt file in the app bundle.
    /// One word per line; lines starting with # are comments.
    private static func loadBuiltinWords(_ name: String) -> Set<String> {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            log(.warn, "builtin: \(name).txt not found — using empty set")
            return []
        }
        let words = Set(content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
        log("builtin: \(name).txt → \(words.count) words")
        return words
    }

    /// Characters that mark word boundaries (trigger a check).
    /// Only TRULY universal characters — same character in BOTH layouts:
    ///   space, newline, tab, ! (Shift+1), ? (Shift+/), —, –, …
    /// Characters like ".", ";" are NOT boundaries because on macOS ЙЦУКЕН:
    ///   "." → "ю" (letter), "," → "б" (letter), ";" → "ж" (letter)
    /// They can be part of a word (e.g. "htdm." = "ревью" — period is "ю").
    /// The spell-checker validates whether a segment including these chars
    /// is a real word.
    static let boundaries: Set<Character> = [
        " ", "!", "?", "\n", "\t",
        "—", "–", "…",
    ]

    /// Words matching this regex are NEVER converted (URLs, emails, code, flags).
    /// Examples: "https://...", "foo@bar.com", "/usr/bin", "127.0.0.1",
    /// "-rf", "--verbose", "my_var_name"
    private static let nonConvertRegex: NSRegularExpression = {
        let patterns = [
            #"https?://"#,                      // URLs with http/https
            #"^www\."#,                         // www.something
            #"^[\w.+-]+@[\w.-]+\.\w+$"#,       // email addresses
            #"^\d{1,3}(\.\d{1,3}){3}$"#,        // IP addresses
            #"^[/~]"#,                           // file paths (/usr, ~/...)
            #"^\$"#,                             // shell variables ($HOME)
            #"^-"#,                              // CLI flags (-rf, --verbose)
            #"^[a-zA-Z]+(_[a-zA-Z]+)+$"#,      // snake_case identifiers (my_var, MAX_SIZE)
        ]
        let combined = patterns.joined(separator: "|")
        return try! NSRegularExpression(pattern: combined, options: [])
    }()

    /// Checks if a 1-character word converts to a letter of the other script.
    /// Used in retroactive mode: if we already know the user was typing in
    /// the wrong layout, a single char that converts is also wrong.
    /// Universal — no hardcoded word list, works for any letter.
    static func isSingleCharConvertible(_ word: String) -> Bool {
        guard word.count == 1 else { return false }
        guard let result = Translit.convert(word), result.converted != word else { return false }
        return result.converted.count == 1 && result.converted.first!.isLetter
    }

    /// Is this character a word boundary?
    static func isBoundary(_ ch: Character) -> Bool {
        boundaries.contains(ch) || ch.isWhitespace
    }

    /// Does the word contain BOTH Cyrillic AND Latin letters?
    /// A real word is always single-script — mixed script means the user
    /// changed layout mid-word (or had a leftover char from previous typing).
    /// NSSpellChecker can't reliably reason about mixed-script words, so
    /// callers (e.g. shouldConvert) treat this as an unambiguous wrong-layout
    /// signal and skip the spell-checker.
    static func hasMixedScript(_ word: String) -> Bool {
        var hasCyrillic = false
        var hasLatin = false
        for ch in word where ch.isLetter {
            if Translit.isCyrillic(ch) { hasCyrillic = true } else { hasLatin = true }
        }
        return hasCyrillic && hasLatin
    }

    /// Should this word be skipped entirely (URL, email, path, code)?
    static func isNonConvertible(_ word: String) -> Bool {
        let range = NSRange(word.startIndex..<word.endIndex, in: word)
        return nonConvertRegex.firstMatch(in: word, options: [], range: range) != nil
    }

    /// Does this word contain digits? (iPhone15, 3D, etc.)
    static func containsDigits(_ word: String) -> Bool {
        word.contains(where: { $0.isNumber })
    }

    /// Does this word contain underscores? (my_var, MAX_SIZE — code identifiers)
    static func containsUnderscore(_ word: String) -> Bool {
        word.contains("_")
    }

    /// Is this word a built-in common word that should NEVER be converted?
    /// Checked BEFORE learned words and spell-checker — builtins always win.
    /// In retroactive mode, builtins are SKIPPED — if the user was already
    /// typing in the wrong layout, even common words should be converted.
    static func isBuiltinWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        if isWordLatin(word) { return builtinEnWords.contains(lower) }
        return builtinRuWords.contains(lower)
    }

    /// Regex for domain names (adguard.com, example.org, sub.domain.io).
    /// Used to accept conversions that NSSpellChecker rejects — "adguard.com"
    /// isn't a dictionary word but is clearly a domain the user intended.
    private static let domainRegex: NSRegularExpression = {
        let tlds = ["com", "org", "net", "io", "ru", "su", "gov", "edu", "dev", "app",
                    "co", "me", "info", "biz", "tv", "cc", "uk", "us", "de", "fr",
                    "it", "es", "ai", "tech", "cloud", "store", "online", "site"]
        let tldPattern = tlds.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "^[\\w-]+(\\.[\\w-]+)*\\.(\(tldPattern))$",
            options: [.caseInsensitive]
        )
    }()

    /// Does the text look like a domain name? (adguard.com, example.org)
    static func matchesDomainPattern(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return domainRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Two independent word lists: English (Latin) and Russian (Cyrillic).
    /// Words in these lists are NEVER auto-converted.
    /// Direction is implicit in the word's script: Latin → enWords,
    /// Cyrillic → ruWords.
    /// Loaded/saved from UserDefaults as two separate arrays.
    static var enWords: Set<String> = []
    static var ruWords: Set<String> = []

    /// Parses a typing buffer into (word, gap) segments.
    /// Example: "f e ghbdtn" → [("f", " "), ("e", " "), ("ghbdtn", "")]
    /// The gap is the boundary character(s) following each word.
    /// Pure function — no instance state, safe to call from tests.
    ///
    /// Boundaries are ONLY truly universal chars (space, !, ?, newline, tab).
    /// Characters like ".", ",", ";" are NOT boundaries — on macOS ЙЦУКЕН
    /// they map to letters (ю, б, ж). They stay inside words and the
    /// spell-checker validates whether the whole segment is a real word.
    /// Example: "htdm." → one segment "htdm." → Translit.convert → "ревью"
    /// (where "." → "ю"). Spell-checker confirms "ревью" is valid → convert.
    static func parseBufferSegments(_ buffer: String) -> [(word: String, gap: String)] {
        guard !buffer.isEmpty else { return [] }

        var segments: [(word: String, gap: String)] = []
        var i = buffer.startIndex

        while i < buffer.endIndex {
            // Skip leading boundary chars.
            var wordStart = i
            while wordStart < buffer.endIndex, isBoundary(buffer[wordStart]) {
                wordStart = buffer.index(after: wordStart)
            }
            guard wordStart < buffer.endIndex else { break }

            // Find the word end (next boundary char).
            var wordEnd = wordStart
            while wordEnd < buffer.endIndex, !isBoundary(buffer[wordEnd]) {
                wordEnd = buffer.index(after: wordEnd)
            }
            let word = String(buffer[wordStart..<wordEnd])

            // Find the gap (boundary chars after the word).
            var gapEnd = wordEnd
            while gapEnd < buffer.endIndex, isBoundary(buffer[gapEnd]) {
                gapEnd = buffer.index(after: gapEnd)
            }
            let gap = String(buffer[wordEnd..<gapEnd])

            segments.append((word: word, gap: gap))
            i = gapEnd
        }

        return segments
    }

    /// Result of finding what to convert in a text fragment.
    /// Shared between auto-convert and manual double-Shift.
    struct ConversionPlan {
        /// Text before the conversion range (stays in field, not retyped).
        let prefix: String
        /// Original text being converted (converted words + gaps between them,
        /// WITHOUT the trailing gap after the last word).
        let originalText: String
        /// Converted text to type (converted words + gaps between them,
        /// WITHOUT the trailing gap after the last word).
        let convertedText: String
        /// Trailing boundary chars after the last word (spaces, punctuation).
        /// For manual: these stay in the field, so caller adds them to
        /// both the typed text and delete count.
        /// For auto: these were NOT typed yet (boundary was blocked),
        /// so the caller adds the boundary char instead.
        let lastGap: String
        /// Chars to backspace (= originalText.count, without trailing gap).
        let deleteCount: Int
        /// Conversion direction (toCyrillic or toLatin).
        let direction: SwitchDirection
        /// Last word — determined the direction.
        let triggerWord: String
        /// Number of words converted (including retroactive).
        let wordCount: Int
    }

    /// Determines what text to convert in a fragment.
    /// Unified algorithm for auto-convert and manual double-Shift.
    ///
    /// Rules:
    /// 1. Last word ALWAYS converts. For auto (isManual=false): trigger word
    ///    must pass shouldConvert. For manual: just Translit.convert (user
    ///    explicitly double-Shifted).
    /// 2. Walk backwards: convert previous words if:
    ///    a. Same script (Latin/Cyrillic) as the last word
    ///    b. Builtin words («не», «the», «как») → convert unconditionally
    ///       (trigger already proved wrong layout)
    ///    c. Non-builtin ≥2 chars → spell-checker: orig must be misspelled +
    ///       converted must be valid in target
    ///    d. Single-char → skip spell-checker (useless for 1-letter words)
    ///    e. Learned exceptions block (user undid this word before)
    ///    IDENTICAL rules for manual and auto.
    /// 3. Stop at: different script, valid word, exception, or unconvertible.
    ///
    /// Note: conversion of SELECTED TEXT (convertSelectionViaClipboard) is
    /// a separate path — it converts the selection directly via Translit
    /// without any checks (no shouldConvert, no spell-checker, no builtins).
    static func findConversionRange(
        in text: String,
        isManual: Bool
    ) -> ConversionPlan? {
        let segments = parseBufferSegments(text)
        guard let lastSeg = segments.last, !lastSeg.word.isEmpty,
              let lastResult = Translit.convert(lastSeg.word),
              lastResult.converted != lastSeg.word else { return nil }

        let mode = isManual ? "manual" : "auto"
        let direction = lastResult.direction
        let lastIsLatin = isWordLatin(lastSeg.word)

        log(.debug, "findRange[\(mode)]: buffer=«\(redact(text))» segments=\(segments.map { "\($0.word)" })")
        log(.debug, "findRange[\(mode)]: last=«\(lastSeg.word)»→«\(lastResult.converted)» dir=\(direction == .toCyrillic ? "EN→RU" : "RU→EN") latin=\(lastIsLatin)")

        // For auto-convert: trigger word must pass shouldConvert checks.
        // (builtins, exceptions, spell-checker, structural filters).
        // For manual: last word always converts — no dictionary checks.
        if !isManual {
            guard shouldConvert(lastSeg.word, isRetroactive: false) != nil else {
                log(.debug, "findRange[\(mode)]: last word «\(lastSeg.word)» failed shouldConvert → nil")
                return nil
            }
        }

        let convLang = direction == .toCyrillic ? "ru" : "en"

        // Build converted text. Last word is always converted (no checks).
        // DON'T include lastSeg.gap — it's trailing boundary chars (spaces,
        // punctuation) handled separately by callers.
        var convertedText = lastResult.converted
        var wordIndex = segments.count - 2
        let checker = NSSpellChecker.shared
        let origLang = direction == .toCyrillic ? "en" : "ru"

        while wordIndex >= 0 {
            let prevSeg = segments[wordIndex]
            let gap = prevSeg.gap
            if prevSeg.word.isEmpty { wordIndex -= 1; continue }

            // Same script as last word? If different → stop (can't convert
            // words from a different "wrong layout" in one pass).
            let prevIsLatin = isWordLatin(prevSeg.word)
            if prevIsLatin != lastIsLatin {
                log(.debug, "findRange[\(mode)]: retro «\(prevSeg.word)» → stop (different script, latin=\(prevIsLatin))")
                break
            }

            // Can convert via Translit?
            guard let prevResult = Translit.convert(prevSeg.word),
                  prevResult.direction == direction,
                  prevResult.converted != prevSeg.word else {
                log(.debug, "findRange[\(mode)]: retro «\(prevSeg.word)» → stop (Translit fail / same direction / no change)")
                break
            }

            // Spell-checker (≥2 chars, not mixed-script, not all-caps).
            //
            // Builtin words: in AUTO mode, spell-checker RUNS — if the word is
            // valid in its own language (origMisspelled=false), the walk stops.
            // Previously builtins bypassed spell-checker entirely, which caused
            // valid words like «это»/«из» to be converted alongside the trigger
            // word (BUG: «это из сдд» → «'nj bp cll» instead of just «сдд»→«cll»).
            // In MANUAL mode, builtins still bypass (user explicitly asked).
            //
            // Mixed-script words: skip spell-checker (NSSpellChecker can't
            // reason about them) — they're always wrong-layout typos.
            // All-caps words: skip spell-checker (NSSpellChecker treats them as
            // valid acronyms like HTML/JSON), but in manual mode user may have
            // typed them in wrong layout (ЕРФТЛ → THANK).
            //
            // origMisspelled (word is gibberish in own language) runs in BOTH
            // modes — otherwise valid words like «есть»/«термин» get converted
            // when user only wanted the last word (BUG: «есть термин АГВ» case).
            // convValid (converted is valid in target language) is auto-only
            // per AGENTS.md: "no convValid in manual".
            let prevLetters = prevSeg.word.filter { $0.isLetter }
            let prevAllCaps = prevLetters.count > 1 && prevLetters.allSatisfy({ $0.isUppercase })
            if !prevAllCaps, !(isBuiltinWord(prevSeg.word) && isManual), prevSeg.word.count >= 2,
               !hasMixedScript(prevSeg.word) {
                let origMisspelled = checker.checkSpelling(
                    of: prevSeg.word, startingAt: 0,
                    language: origLang, wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil
                ).location != NSNotFound
                if !origMisspelled {
                    log(.debug, "findRange[\(mode)]: retro «\(prevSeg.word)» → stop (valid in \(origLang))")
                    break
                }

                // convValid check (converted must be valid in target language)
                // is auto-only — manual mode: user explicitly asked.
                if !isManual {
                    let convValid = checker.checkSpelling(
                        of: prevResult.converted, startingAt: 0,
                        language: convLang, wrap: false,
                        inSpellDocumentWithTag: 0, wordCount: nil
                    ).location == NSNotFound
                    if !convValid, !matchesDomainPattern(prevResult.converted) {
                        log(.debug, "findRange[\(mode)]: retro «\(prevSeg.word)» → stop (converted «\(prevResult.converted)» invalid in \(convLang))")
                        break
                    }
                }
            }

            // Exceptions block (user undid this word before).
            // Manual mode: user explicitly wants conversion — ignore exceptions.
            if !isManual, isLearnedException(prevSeg.word) {
                log(.debug, "findRange[\(mode)]: retro «\(prevSeg.word)» → stop (learned exception)")
                break
            }

            log(.debug, "findRange[\(mode)]: retro «\(prevSeg.word)» → «\(prevResult.converted)» ✓")
            convertedText = prevResult.converted + gap + convertedText
            wordIndex -= 1
        }

        // Build prefix (unchanged text before conversion range — stays in field).
        var prefix = ""
        if wordIndex >= 0 {
            for i in 0...wordIndex {
                prefix += segments[i].word + segments[i].gap
            }
        }

        // Build originalText for undo = converted words + gaps between them
        // (WITHOUT the trailing gap after the last word).
        var originalText = ""
        for i in (wordIndex + 1)..<segments.count {
            originalText += segments[i].word
            // Add gap for all segments except the last one (trailing gap is separate)
            if i < segments.count - 1 {
                originalText += segments[i].gap
            }
        }

        let lastGap = lastSeg.gap
        let wordCount = segments.count - wordIndex - 1

        log(.debug, "findRange[\(mode)]: RESULT prefix=«\(redact(prefix))» orig=«\(redact(originalText))» conv=«\(redact(convertedText))» gap=«\(redact(lastGap))» words=\(wordCount)")

        return ConversionPlan(
            prefix: prefix,
            originalText: originalText,
            convertedText: convertedText,
            lastGap: lastGap,
            deleteCount: originalText.count,
            direction: direction,
            triggerWord: lastSeg.word,
            wordCount: wordCount
        )
    }

    /// Evaluates whether the buffer should be auto-converted on a word boundary.
    /// Pure function — returns a decision or nil (no conversion needed).
    /// This is the EXACT same logic as Switcher.tryAutoConvert, extracted so
    /// tests can call the real code path instead of reimplementing it.
    static func evaluateAutoConvert(
        buffer: String,
        boundaryChar: String
    ) -> ConversionPlan? {
        let segments = parseBufferSegments(buffer)

        // Auto-convert: single-char words CAN trigger. Builtin word lists
        // protect common single-char words (а, в, и, I, a) from false
        // positives. Uncommon single chars (ф→a, й→q) will convert —
        // they're almost certainly typed in the wrong layout.
        guard let lastSegment = segments.last,
              lastSegment.word.count >= minWordLength else {
            return nil
        }

        // Delegate to unified function (isManual=false → auto-convert checks).
        guard let plan = findConversionRange(in: buffer, isManual: false) else { return nil }

        return plan
    }

    // MARK: - Learned words (two independent lists)

    /// Is the word Latin (English layout)? Direction is implicit:
    /// Latin word → toCyrillic; Cyrillic word → toLatin.
    /// Skips non-letter prefix chars (e.g. quotes, punctuation) to find
    /// the actual script of the word. Without this, `"nj` would return
    /// false ("`"` is not a letter) and break the retro walk.
    static func isWordLatin(_ word: String) -> Bool {
        guard let first = word.first(where: { $0.isLetter }) else { return false }
        return !Translit.isCyrillic(first)
    }

    /// Is this word in the user's exception list (should NOT be auto-converted)?
    /// Checks the correct list based on the word's script.
    static func isLearnedException(_ word: String) -> Bool {
        let lower = word.lowercased()
        if isWordLatin(word) { return enWords.contains(lower) }
        return ruWords.contains(lower)
    }

    /// Add a word to the appropriate exception list (auto-learn on undo).
    /// Always lowercases — exceptions are case-insensitive.
    static func addException(_ word: String) {
        let lower = word.lowercased()
        if isWordLatin(word) {
            enWords.insert(lower)
        } else {
            ruWords.insert(lower)
        }
    }

    // Removed: enDictionary, ruDictionary, rebuildLearnedSets, isLearnedDictionary.

    /// Is this word in the built-in common words list (NEVER convert)?
    /// In retroactive mode, builtins are skipped — the user was already
    /// typing in the wrong layout, so even common words should convert.
    static func isBuiltinWordRetrospective(_ word: String, retroactive: Bool) -> Bool {
        guard !retroactive else { return false }
        return isBuiltinWord(word)
    }

    /// Determines whether a word was typed in the wrong layout.
    /// Returns the converted text + direction if auto-conversion is needed.
    ///
    /// Criteria (all must hold):
    /// 1. Word length ≥ minLength (default 2; lowered to 1 for retroactive checks —
    ///    when we already know the user was typing in the wrong layout from
    ///    the previous word, single characters like "f" → "а" are valid).
    /// 2. Contains at least one letter.
    /// 3. Is not all-uppercase (like "HTML", "API" — likely abbreviations).
    /// 3b. Does not contain digits (like "iPhone15", "3D" — code or codenames).
    /// 3c. Does not look like URL, email, IP, file path — don't touch those.
    /// 4. Translit.convert produces a different string.
    /// 5. Converted is correctly spelled in the target language.
    ///    If NSSpellChecker doesn't recognize the converted text (e.g. "adguard.com"
    ///    is not a dictionary word) but it matches a domain pattern → accept anyway.
    /// 6. Original must be misspelled in its own language (for words with
    ///    count ≥ 2). Single-char words skip this check — NSSpellChecker
    ///    considers all single letters "valid", so we rely on the fact that
    ///    the main word already proved wrong layout.
    static func shouldConvert(_ word: String, minLength: Int = minWordLength, isRetroactive: Bool = false) -> (converted: String, direction: SwitchDirection)? {
        // 1) Too short
        guard word.count >= minLength else { return nil }

        // 2) Must contain letters
        guard word.contains(where: { $0.isLetter }) else { return nil }

        // 3) All uppercase → likely an abbreviation (HTML, JSON, etc.)
        let letters = word.filter { $0.isLetter }
        if letters.count > 1 && letters.allSatisfy({ $0.isUppercase }) {
            return nil
        }

        // Note: mixed-case words (iPhone, macOS) are NOT filtered here.
        // If they're in the wrong layout ("шЗрщту" = "iPhone" typed in RU layout),
        // the spell-checker validates the conversion — no need to block them.

        // 3b) Words with digits (iPhone15, 3D, C4H8) — don't convert
        if containsDigits(word) { return nil }

        // 3c) Words with underscores (snake_case identifiers: my_var) — don't convert
        if containsUnderscore(word) { return nil }

        // 3d) URLs, emails, file paths, CLI flags — don't convert
        if isNonConvertible(word) { return nil }

        // 4) Must be convertible
        guard let result = Translit.convert(word) else { return nil }
        guard result.converted != word else { return nil }

        // 4a) Built-in common words — NEVER convert (unless retroactive).
        // These are high-frequency words that NSSpellChecker may miss.
        // In retroactive mode, skip this check — the user was already typing
        // in the wrong layout, so even common words should be converted.
        if isBuiltinWordRetrospective(word, retroactive: isRetroactive) {
            return nil
        }

        // 4b) User exception list — word the user undid before.
        // Two independent lists: direction is implicit in the word's script.
        if isLearnedException(word) {
            return nil  // user undid this conversion before — don't repeat
        }

        // 4c) Single-char words: convert ONLY if the result is a builtin word.
        // Real single-char words are rare: «а», «в», «и» (RU), «I», «a» (EN).
        // If the converted char is in the builtin list → it's a real word,
        // the user typed it in the wrong layout → convert.
        // If NOT in builtin → don't touch it (almost certainly intentional).
        // Examples:
        //   «d» → «в» ✓ (в is builtin RU)    «f» → «а» ✓ (а is builtin RU)
        //   «Ш» → «I» ✓ (I is builtin EN)   «ш» → «i» ✓ (i is builtin EN)
        //   «g» → «п» ✗ (п NOT builtin)     «q» → «й» ✗ (й NOT builtin)
        //   «п» → «g» ✗ (g NOT builtin)     «ъ» → «]» ✗ (] not even a letter)
        if word.count == 1, minLength <= 1 {
            if isBuiltinWord(result.converted) {
                return result
            }
            return nil
        }

        // 4d) Mixed-script word: contains BOTH Cyrillic AND Latin letters.
        // A real word is always single-script — mixed script means the user
        // changed layout mid-word. NSSpellChecker can't reason about mixed
        // scripts (splits on punctuation, considers single-letter fragments
        // "valid"), so we skip spell-checker entirely and convert directly.
        // Example: «Э"nj» (Cyrillic Э leftover + ASCII " (Shift+э) + Latin nj)
        // → «ЭЭто» — spell-checker thought «nj» was a valid English abbreviation
        // and rejected conversion. With mixed-script detection: convert freely.
        if hasMixedScript(word) {
            return result
        }

        // 5–6) Spell-check both directions
        let checker = NSSpellChecker.shared

        let (origLang, convLang): (String, String) = result.direction == .toCyrillic
            ? ("en", "ru")    // Latin word → Cyrillic; check EN misspelled, RU valid
            : ("ru", "en")   // Cyrillic word → Latin;  check RU misspelled, EN valid

        // origMisspelled check: is the word misspelled in its own language?
        // If it IS valid in its own language → it was typed intentionally → don't convert.
        // Skip ONLY for single-char words (NSSpellChecker considers all single
        // letters "valid" in EN, so the check is meaningless for them).
        // Multi-char retroactive words MUST be checked — otherwise valid English
        // words like "by" (→ "ин") get incorrectly converted retroactively.
        if word.count >= 2 {
            let origMisspelled = checker.checkSpelling(
                of: word, startingAt: 0,
                language: origLang, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location != NSNotFound

            guard origMisspelled else { return nil }
        }

        let convValid = checker.checkSpelling(
            of: result.converted, startingAt: 0,
            language: convLang, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound

        // If NSSpellChecker doesn't recognize the converted word BUT it looks
        // like a domain name (e.g. "adguard.com"), accept — the user likely
        // typed a URL in the wrong layout.
        if !convValid, matchesDomainPattern(result.converted) {
            return result
        }

        guard convValid else { return nil }

        return result
    }
}
