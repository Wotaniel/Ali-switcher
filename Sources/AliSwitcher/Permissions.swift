import Cocoa
import ApplicationServices

/// Centralized permission checks and settings access.
///
/// All permission status checks (`AXIsProcessTrusted`, `CGPreflightListenEventAccess`)
/// and "open System Settings" actions live here. Previously these were scattered
/// across `Accessibility.swift`, `UIManager.swift`, and `main.swift`.
///
/// UI elements (panels, menu items) stay in `UIManager` — they need `@objc`
/// and `NSObject` target-action, which a pure enum can't provide.
/// UIManager's `@objc` methods are thin wrappers around these calls.
enum Permissions {

    // MARK: - Status checks

    /// Is Accessibility (AX) permission granted?
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Is Input Monitoring permission granted?
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    /// Are ALL required permissions granted?
    static var allGranted: Bool { accessibilityGranted && inputMonitoringGranted }

    /// Silent permission check (no system dialog — our own panel explains everything).
    /// Call at startup; returns current status without prompting.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Open System Settings

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// Opens System Settings → Privacy & Security → Input Monitoring.
    static func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
