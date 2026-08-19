import Cocoa
import Carbon

/// Определяет, что делает нажатая клавиша: вводит текст, удаляет, обрывает фрагмент.
/// Это «буфер набора», как в Punto/Caramba: мы запоминаем, что напечатал пользователь,
/// чтобы потом стереть это Backspace'ами и напечатать конвертированное.
enum KeyTracker {

    enum Action {
        case text(String)        // клавиша вставила этот текст (в текущей раскладке)
        case deleteBackward      // Backspace — удалили последний символ
        case reset               // курсор уехал / новая строка — фрагмент оборвался
        case ignore              // служебное (Cmd-сочетание, Escape и т.п.)
    }

    static func action(for event: CGEvent, currentLayout: TISInputSource) -> Action {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Служебные и навигационные клавиши
        switch keyCode {
        case 36, 76: return .reset        // Return / Enter
        case 48: return .reset            // Tab
        case 51: return .deleteBackward   // Backspace (Delete)
        case 53: return .ignore           // Escape
        case 115, 116, 119, 121: return .reset // Home / PageUp / End / PageDown
        case 117: return .ignore          // ForwardDelete
        case 123, 124, 125, 126: return .reset // стрелки
        default: break
        }

        // Сочетания с Command/Control — не текст (copy/paste/undo и т.п.)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .ignore }

        // Переводим keycode + модификаторы в символ(ы) текущей раскладки (UCKeyTranslate)
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
