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

    /// Is this word mixed-case? (iPhone, macOS, JavaScript — but NOT "Hello")
    /// Only INTERNAL caps count: an uppercase letter AFTER the first position.
    /// "Hello" (sentence case — first letter capital, rest lowercase) is normal
    /// and should still be converted. "iPhone" (cap after first) → skip.
    static func isMixedCase(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        guard letters.count > 1 else { return false }
        let letterArray = Array(letters)
        // All-uppercase words (HELLO, JSON) are not mixed-case — they're
        // conventionally uppercased and should still be converted if needed.
        let hasLower = letterArray.contains { $0.isLowercase }
        guard hasLower else { return false }
        return letterArray.dropFirst().contains { $0.isUppercase }
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
    static func shouldConvert(_ word: String, minLength: Int = minWordLength) -> (converted: String, direction: SwitchDirection)? {
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
