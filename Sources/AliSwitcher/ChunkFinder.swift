import Foundation

/// Поиск границы «фрагмента, набранного не в той раскладке».
///
/// Правило (как в Punto): от позиции курсора идём влево, захватывая
/// буквы, цифры, пробелы и знаки препинания. Граница фрагмента — это
/// первая буква ДРУГОГО алфавита (кириллица ↔ латиница) либо перевод
/// строки/таб. Пробелы и знаки внутри фрагмента «прозрачны», поэтому
/// фраза «b yfgbcfk ytcrjkmrj ckjd …» выделяется целиком, а не по словам.
///
/// Важно: работаем с UTF-16 смещениями (как AX API и NSString), а не
/// с Character-индексами Swift, чтобы не разъезжались позиции.
enum ChunkFinder {

    enum Script {
        case cyrillic, latin
    }

    /// Возвращает UTF-16 индекс начала фрагмента перед позицией `caret`.
    static func chunkStart(in text: NSString, before caret: Int) -> Int {
        guard caret > 0 else { return 0 }
        var script: Script? = nil
        var i = caret - 1
        while i >= 0 {
            let codeUnit = text.character(at: i)
            // Суррогатная пара (эмодзи и т.п.) — не буква, пропускаем прозрачно.
            guard let scalar = UnicodeScalar(codeUnit) else {
                i -= 1
                continue
            }
            if CharacterSet.letters.contains(scalar) {
                let s: Script = isCyrillic(scalar) ? .cyrillic : .latin
                if let current = script {
                    if current != s { break } // алфавит сменился — граница
                } else {
                    script = s
                }
            } else if codeUnit == 0x000A || codeUnit == 0x000D || codeUnit == 0x0009 {
                break // перевод строки / таб — жёсткая граница
            }
            // цифры, пробелы, знаки препинания — прозрачны, идём дальше
            i -= 1
        }
        return i + 1
    }

    private static func isCyrillic(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F)
    }
}
