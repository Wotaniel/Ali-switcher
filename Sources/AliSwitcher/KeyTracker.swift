import Cocoa
import Carbon

/// Figures out what a pressed key does: types text, deletes, or breaks the fragment.
/// This is the "typing buffer", like in Punto/Caramba: we remember what the user
/// typed so we can erase it with Backspaces and retype the converted text.
enum KeyTracker {

    enum Action {
        case text(String)        // the key inserted this text (in the current layout)
        case deleteBackward      // Backspace — removed the last character
        case reset               // caret moved / new line — fragment broken
        case ignore              // special (Cmd combo, Escape, etc.)
    }

    static func action(for event: CGEvent, currentLayout: TISInputSource) -> Action {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Special and navigation keys
        switch keyCode {
        case 36, 76: return .reset        // Return / Enter
        case 48: return .reset            // Tab
        case 51: return .deleteBackward   // Backspace (Delete)
        case 53: return .ignore           // Escape
        case 115, 116, 119, 121: return .reset // Home / PageUp / End / PageDown
        case 117: return .ignore          // ForwardDelete
        case 123, 124, 125, 126: return .reset // arrows
        default: break
        }

        // Command/Control combos — not text (copy/paste/undo etc.)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .ignore }

        // Translate keycode + modifiers into character(s) of the current layout (UCKeyTranslate)
        guard let layoutData = TISGetInputSourceProperty(currentLayout, kTISPropertyUnicodeKeyLayoutData) else {
            return .ignore
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        guard let layoutPtr = data.withUnsafeBytes({ bytes -> UnsafePointer<UCKeyboardLayout>? in
            bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
        }) else { return .ignore }

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        var modifierState: UInt32 = 0
        if flags.contains(.maskShift) { modifierState |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { modifierState |= UInt32(optionKey) }

        let status = UCKeyTranslate(layoutPtr,
                                    UInt16(keyCode),
                                    UInt16(kUCKeyActionDisplay),
                                    modifierState,
                                    UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadKeyState,
                                    chars.count,
                                    &length,
                                    &chars)
        guard status == noErr, length > 0 else { return .ignore }
        return .text(String(utf16CodeUnits: chars, count: length))
    }
}
