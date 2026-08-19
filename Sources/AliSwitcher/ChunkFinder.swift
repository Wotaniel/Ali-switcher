import Foundation

/// Finds the start of the "typed in the wrong layout" fragment.
///
/// Rule (like Punto): walk left from the caret, taking letters, digits, spaces
/// and punctuation. The fragment boundary is the first letter of the OTHER
/// alphabet (Cyrillic ↔ Latin) or a newline/tab. Spaces and punctuation inside
/// the fragment are "transparent", so the phrase "b yfgbcfk ytcrjkmrj ckjd …"
/// is selected whole, not word by word.
///
/// Important: we work with UTF-16 offsets (like the AX API and NSString),
/// not Swift Character indices, so positions never drift.
enum ChunkFinder {

    enum Script {
        case cyrillic, latin
    }

    /// Returns the UTF-16 index of the fragment start before `caret`.
    static func chunkStart(in text: NSString, before caret: Int) -> Int {
        guard caret > 0 else { return 0 }
        var script: Script? = nil
        var i = caret - 1
        while i >= 0 {
            let codeUnit = text.character(at: i)
            // Surrogate pair (emoji etc.) — not a letter, skip transparently.
            guard let scalar = UnicodeScalar(codeUnit) else {
                i -= 1
                continue
            }
            if CharacterSet.letters.contains(scalar) {
                let s: Script = isCyrillic(scalar) ? .cyrillic : .latin
                if let current = script {
                    if current != s { break } // alphabet changed — boundary
                } else {
                    script = s
                }
            } else if codeUnit == 0x000A || codeUnit == 0x000D || codeUnit == 0x0009 {
                break // newline / tab — hard boundary
            }
            // digits, spaces, punctuation — transparent, keep going
            i -= 1
        }
        return i + 1
    }

    private static func isCyrillic(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F)
    }
}
