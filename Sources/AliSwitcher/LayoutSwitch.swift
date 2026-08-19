import Carbon
import Darwin

/// Переключение раскладки через Text Input Sources (Carbon TIS).
/// Тот же механизм, что использует утилита macism.
enum LayoutSwitch {

    private static func sources() -> [TISInputSource] {
        guard let cfArray = TISCreateInputSourceList(
            [kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary,
            false
        )?.takeRetainedValue() else { return [] }

        // CFArray свободно мостится в NSArray; элементы — TISInputSourceRef.
        return (cfArray as NSArray).map { $0 as! TISInputSource }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        let cf = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cf as String
    }

    private static func id(_ source: TISInputSource) -> String? {
        property(source, kTISPropertyInputSourceID)
    }

    private static func name(_ source: TISInputSource) -> String? {
        property(source, kTISPropertyLocalizedName)
    }

    /// Переключает системную раскладку на русскую или английскую.
    /// Возвращает false, если подходящая раскладка не найдена (не установлена в системе).
    @discardableResult
    static func select(toRussian: Bool) -> Bool {
        let sources = self.sources()

        // 1. Точные известные ID
        let exactTargets: [String] = toRussian
            ? ["com.apple.keylayout.Russian", "com.apple.keylayout.Russian-PC", "com.apple.keylayout.RussianWin"]
            : ["com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.ABC-AZERTY"]
        for target in exactTargets {
            if let match = sources.first(where: { id($0)?.lowercased() == target }) {
                TISSelectInputSource(match)
                return true
            }
        }

        // 2. Эвристика по ID и имени
        if toRussian {
            if let match = sources.first(where: { (id($0) ?? "").lowercased().contains("russian") }) {
                TISSelectInputSource(match)
                return true
            }
        } else {
            if let match = sources.first(where: { source in
                let id = (id(source) ?? "").lowercased()
                let name = (name(source) ?? "").lowercased()
                return id.contains(".us") || id.contains("abc") || name.contains("english")
            }) {
                TISSelectInputSource(match)
                return true
            }
        }
        return false
    }

    /// Переключает раскладку на противоположную текущей:
    /// если сейчас русская — станет английская, иначе — русская.
    static func toggle() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let currentID = (id(current) ?? "").lowercased()
        let isRussian = currentID.contains("russian")
            || currentID.contains("belarusian")
            || currentID.contains("ukrainian")
        select(toRussian: !isRussian)
    }

    /// Отладка: печатает доступные раскладки.
    static func debugPrint() {
        print("Доступные раскладки (включённые):")
        for source in sources() {
            print("  \(id(source) ?? "?")  —  \(name(source) ?? "?")")
        }
    }
}
