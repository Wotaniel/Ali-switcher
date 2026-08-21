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

    /// Minimum word length to check (shorter → too many false positives).
    static let minWordLength = 2

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
    /// Includes single-char words ("I", "a") that replaced englishSingleCharWords.
    static let builtinEnWords: Set<String> = [
        // Single-char
        "I", "a", "i",
        // 2-char
        "am", "an", "as", "at", "be", "by", "do", "go", "he", "if", "in",
        "is", "it", "me", "my", "no", "of", "on", "or", "so", "to",
        "up", "us", "we",
        // 3-char
        "and", "are", "but", "can", "did", "for", "get", "got", "had",
        "has", "her", "him", "his", "how", "its", "let", "may", "new",
        "not", "now", "old", "one", "our", "out", "say", "see", "she",
        "the", "too", "two", "use", "was", "way", "who", "why", "yes",
        "yet", "you",
        // 4-char (common)
        "been", "came", "does", "each", "find", "from", "have", "here",
        "into", "just", "like", "made", "many", "more", "much", "must",
        "name", "only", "over", "some", "such", "than", "that", "them",
        "then", "there", "these", "they", "this", "upon", "want", "well",
        "were", "what", "when", "will", "with", "your",
        // Common abbreviations
        "ok", "ex", "ie", "eg", "vs", "etc", "jan", "feb", "mar", "apr",
        "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    /// Common Russian short words that should NEVER be auto-converted.
    /// Includes words that NSSpellChecker sometimes rejects (colloquial,
    /// short forms, particles).
    static let builtinRuWords: Set<String> = [
        // Single-char
        "а", "в", "и", "к", "о", "с", "у", "я",
        // 2-char
        "би", "бы", "вам", "вас", "вы", "да", "за", "ли", "на", "не", "ни", "но", "от", "по",
        "со", "то", "ту", "ты", "же", "бы",
        // 3-char
        "без", "для", "ещё", "ила", "или", "имя", "как", "мне",
        "моя", "наш", "него", "ней", "нет", "них", "она", "они", "оно",
        "под", "при", "про", "так", "теб", "там",
        "тво", "тем", "теё", "том", "тот", "тут", "хот", "что", "это", "эту",
        "эти", "их",
        // 4-char (common)
        "быть", "ведь", "весь", "вот", "всё", "всех",
        "где", "если", "есть", "еще", "зачем", "значит", "или",
        "когда", "кроме", "кто", "лишь", "между", "меня", "могу",
        "может", "моё", "мой", "над", "нам", "неё", "него", "ней",
        "нельзя", "нет", "ним", "них", "обед", "одно", "около",
        "она", "они", "оно",
        // Common colloquial / short forms that NSSpellChecker misses
        "юае", "юаё", "же", "ль", "теё", "чу",
    ]

    /// Characters that mark word boundaries (trigger a check).
    /// IMPORTANT: only "universal" punctuation — characters that are NOT
    /// letters in ANY layout. For example, ";" is "ж" in the Russian layout,
    /// so it must NOT be a boundary (otherwise "db;e" breaks into "db" + "e"
    /// instead of being checked as one word → "вижу"). But "." IS a boundary
    /// (it's "." in both layouts).
    static let boundaries: Set<Character> = [
        " ", ".", ",", "!", "?", "\n", "\t",
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
        if isWordLatin(word) { return builtinEnWords.contains(word) }
        return builtinRuWords.contains(word)
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

            // Find the word end (next boundary).
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

    /// Result of evaluating auto-convert: the decision to convert (or not).
    /// Pure data — no side effects. The caller (Switcher) performs the actual
    /// backspace/type/layout-switch.
    struct AutoConvertDecision {
        let convertedText: String       // text to type (without boundary char)
        let fullConvertedText: String  // text to type (with boundary char)
        let deleteCount: Int           // chars to backspace
        let direction: SwitchDirection
        let triggerWord: String        // word that triggered conversion
        let originalText: String       // pre-conversion text (for undo)
        let wordCount: Int             // number of words converted (retroactive)
    }

    /// Evaluates whether the buffer should be auto-converted on a word boundary.
    /// Pure function — returns a decision or nil (no conversion needed).
    /// This is the EXACT same logic as Switcher.tryAutoConvert, extracted so
    /// tests can call the real code path instead of reimplementing it.
    static func evaluateAutoConvert(
        buffer: String,
        boundaryChar: String
    ) -> AutoConvertDecision? {
        let segments = parseBufferSegments(buffer)

        // The last segment's word is what we check first.
        // Single-char words are allowed as triggers ONLY in the toCyrillic
        // direction (Latin → Russian). This lets "f" → "а" work (the user
        // typed Latin meaning Russian). In the reverse direction (Russian →
        // Latin), single chars like "а", "в", "и" are valid Russian words and
        // must NOT be auto-converted to English ("f", "d", "b").
        // NSSpellChecker considers all single letters "valid" in both
        // languages, so direction is the only way to distinguish intent.
        // Multi-char words always go through the full spell-checker.
        guard let lastSegment = segments.last,
              lastSegment.word.count >= minWordLength
                || (isSingleCharConvertible(lastSegment.word)
                    && Translit.convert(lastSegment.word)?.direction == .toCyrillic) else {
            return nil
        }

        // Skip words in the exceptions list (learned from previous undos).
        if isLearnedException(lastSegment.word) {
            return nil
        }

        // For single-char trigger words (Latin → Cyrillic direction only,
        // checked above), use minLength: 1 so shouldConvert doesn't reject
        // them at step 1. The spell-checker bypass in step 4b handles the
        // direction check (toCyrillic allowed, toLatin blocked).
        let minLen = lastSegment.word.count == 1 ? 1 : minWordLength
        guard let result = shouldConvert(lastSegment.word, minLength: minLen, isRetroactive: false) else { return nil }

        // Retroactive: walk backwards from the last word and convert all previous
        // words that are also in the wrong layout (same direction).
        var convertedText = result.converted
        var deleteCount = lastSegment.word.count

        var wordIndex = segments.count - 2
        while wordIndex >= 0 {
            let prevSeg = segments[wordIndex]
            let gap = segments[wordIndex].gap
            if let prevResult = shouldConvert(prevSeg.word, minLength: 1, isRetroactive: true),
               prevResult.direction == result.direction {
                convertedText = prevResult.converted + gap + convertedText
                deleteCount += prevSeg.word.count + gap.count
                wordIndex -= 1
            } else {
                break  // Stop — this word is not in the wrong layout.
            }
        }

        // Compute the original text (pre-conversion) for undo support.
        var originalText = ""
        for segIdx in (wordIndex + 1)..<segments.count {
            originalText += segments[segIdx].word + segments[segIdx].gap
        }
        let fullConvertedText = convertedText + boundaryChar

        return AutoConvertDecision(
            convertedText: convertedText,
            fullConvertedText: fullConvertedText,
            deleteCount: deleteCount,
            direction: result.direction,
            triggerWord: lastSegment.word,
            originalText: originalText,
            wordCount: segments.count - wordIndex - 1
        )
    }

    // MARK: - Learned words (two independent lists)

    /// Is the word Latin (English layout)? Direction is implicit:
    /// Latin word → toCyrillic; Cyrillic word → toLatin.
    static func isWordLatin(_ word: String) -> Bool {
        guard let first = word.first, first.isLetter else { return false }
        return !Translit.isCyrillic(first)
    }

    /// Is this word in the user's exception list (should NOT be auto-converted)?
    /// Checks the correct list based on the word's script.
    static func isLearnedException(_ word: String) -> Bool {
        if isWordLatin(word) { return enWords.contains(word) }
        return ruWords.contains(word)
    }

    /// Add a word to the appropriate exception list (auto-learn on undo).
    static func addException(_ word: String) {
        if isWordLatin(word) {
            enWords.insert(word)
        } else {
            ruWords.insert(word)
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
    /// 6. If minLength ≥ 2: original must be misspelled in its own language.
    ///    If minLength == 1 (retroactive): skip this check — NSSpellChecker
    ///    considers all single letters "valid" (e.g. "f" is not misspelled),
    ///    so we rely on the fact that the main word already proved wrong layout.
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

        // 4c) Single-char words in retroactive mode (minLength == 1):
        // If we already know the user was typing in the wrong layout
        // (retroactive walk triggered by a multi-char word), any single char
        // that converts to a letter of the other script is also wrong —
        // BUT ONLY in the toCyrillic direction (Latin → Russian).
        // In the toLatin direction (Russian → Latin), single chars like «а»,
        // «в», «и» are valid Russian words and must NOT be converted.
        if word.count == 1, minLength <= 1 {
            if result.direction == .toCyrillic {
                return result
            }
            return nil  // Don't convert single Russian letters to Latin
        }

        // 5–6) Spell-check both directions
        let checker = NSSpellChecker.shared

        let (origLang, convLang): (String, String) = result.direction == .toCyrillic
            ? ("en", "ru")    // Latin word → Cyrillic; check EN misspelled, RU valid
            : ("ru", "en")   // Cyrillic word → Latin;  check RU misspelled, EN valid

        // For retroactive checks (minLength == 1): skip origMisspelled check,
        // because NSSpellChecker considers single letters "valid" in EN.
        if minLength >= 2 {
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
