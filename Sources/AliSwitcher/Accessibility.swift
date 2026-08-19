import Cocoa
import ApplicationServices

/// Accessibility API: reading selected text in the frontmost app.
enum Accessibility {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Silent permission check (no system dialog — our own panel explains everything).
    @discardableResult
    static func requestPermissionIfNeeded() -> Bool {
        AXIsProcessTrusted()
    }

    /// The element that currently holds the caret (in the frontmost app).
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        // 1) System-wide focus
        if let el = attribute(of: systemWide, kAXFocusedUIElementAttribute as CFString) {
            return el
        }

        // 2) Fallback for apps with weak AX (Electron etc.):
        //    focused app → focused window → element
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

    /// Is the field secure (password)? We neither listen to nor convert such fields.
    static func isSecureField(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }
        return role == "AXSecureTextField"
    }

    /// Text currently selected in the focused element.
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

    /// The whole text of the field/area (UTF-16 length = NSString.length).
    static func value(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        if let str = value as? String { return str }
        return String(value as! CFString)
    }

    /// Current selection range (or caret position when length is 0).
    /// Offsets are UTF-16, like NSString.
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard err == .success, let value else { return nil }
        let axValue = (value as! AXValue)

        // Some apps store the range as CFRange, others as a pair of Int32s
        // in a CGPoint struct. Try both.
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

    /// Sets the selected range (UTF-16 offsets).
    @discardableResult
    static func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var r = range
        guard let axValue = AXValueCreate(.cfRange, &r) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
        return err == .success
    }
}
