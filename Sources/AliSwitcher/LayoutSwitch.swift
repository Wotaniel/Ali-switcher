import Carbon
import Darwin

/// Layout switching via Text Input Sources (Carbon TIS).
/// The same mechanism used by the macism utility.
enum LayoutSwitch {

    private static func sources() -> [TISInputSource] {
        guard let cfArray = TISCreateInputSourceList(
            [kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary,
            false
        )?.takeRetainedValue() else { return [] }

        // CFArray bridges freely to NSArray; elements are TISInputSourceRef.
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

    /// Switches the system layout to Russian or English.
    /// Returns false if no suitable layout is found (not installed in the system).
    @discardableResult
    static func select(toRussian: Bool) -> Bool {
        let sources = self.sources()

        // 1. Known exact IDs
        let exactTargets: [String] = toRussian
            ? ["com.apple.keylayout.Russian", "com.apple.keylayout.Russian-PC", "com.apple.keylayout.RussianWin"]
            : ["com.apple.keylayout.US", "com.apple.keylayout.ABC", "com.apple.keylayout.ABC-AZERTY"]
        for target in exactTargets {
            if let match = sources.first(where: { id($0)?.lowercased() == target }) {
                TISSelectInputSource(match)
                return true
            }
        }

        // 2. Heuristic by ID and name
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

    /// Toggles the layout to the opposite of the current one:
    /// if it is Russian now — English, otherwise — Russian.
    static func toggle() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let currentID = (id(current) ?? "").lowercased()
        let isRussian = currentID.contains("russian")
            || currentID.contains("belarusian")
            || currentID.contains("ukrainian")
        select(toRussian: !isRussian)
    }

    /// Is the current system layout Russian?
    static func currentIsRussian() -> Bool {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return id(current)?.lowercased().contains("russian") ?? false
    }

    /// Debug: prints the available layouts.
    static func debugPrint() {
        print("Available layouts (enabled):")
        for source in sources() {
            print("  \(id(source) ?? "?")  —  \(name(source) ?? "?")")
        }
    }
}
