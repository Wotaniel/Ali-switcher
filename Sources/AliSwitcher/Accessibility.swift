import Cocoa
import ApplicationServices

/// Работа с Accessibility API: чтение выделенного текста в приложении на переднем плане.
enum Accessibility {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Показывает системный запрос на «Специальные возможности», если права ещё нет.
    @discardableResult
    static func requestPermissionIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Элемент, в котором сейчас находится курсор (в приложении на переднем плане).
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        // 1) Системно-широкий фокус
        if let el = attribute(of: systemWide, kAXFocusedUIElementAttribute as CFString) {
            return el
        }

        // 2) Фолбэк для приложений со слабой AX (Electron и т.п.):
        //    сфокусированное приложение → сфокусированное окно → элемент
        if let app = attribute(of: systemWide, kAXFocusedApplicationAttribute as CFString) {
            if let window = attribute(of: app, kAXFocusedWindowAttribute as CFString),
               let el = attribute(of: window, kAXFocusedUIElementAttribute as CFString) {
                return el
            }
            if let el = attribute(of: app, kAXFocusedUIElementAttribute as CFString) {
                return el
            }
            return app
        }
        return nil
    }

    private static func attribute(of element: AXUIElement, _ attr: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    /// Поле является защищённым (пароль): такие поля не слушаем и не конвертируем.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        return role == "AXSecureTextField"
    }

    /// Текст, выделенный в данный момент в фокусе.
    static func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        return selectedText(of: element)
    }

    static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard err == .success, let value else { return nil }
        if let str = value as? String { return str }
        return String(value as! CFString)
    }

    /// Весь текст поля/области, где находится курсор (UTF-16 длина = NSString.length).
    static func value(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        if let str = value as? String { return str }
        return String(value as! CFString)
    }

    /// Текущий диапазон выделения (или позиция курсора, если длина 0).
    /// Смещения — UTF-16, как у NSString.
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        let axValue = (value as! AXValue)

        // Одни приложения хранят диапазон как CFRange, другие — как пару Int32
        // в CGPoint-структуре. Пробуем оба варианта.
        var range = CFRange(location: 0, length: 0)
        if AXValueGetValue(axValue, .cfRange, &range) {
            return range
        }
        var point = CGPoint.zero
        if AXValueGetValue(axValue, .cgPoint, &point) {
            let loc = Int(point.x)
            let len = Int(point.y)
            if loc >= 0, len >= 0 {
                return CFRange(location: loc, length: len)
            }
        }
        return nil
    }

    /// Устанавливает выделенный диапазон (UTF-16 смещения).
    @discardableResult
    static func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let axValue = AXValueCreate(.cfRange, &r) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
        return err == .success
    }
}
