import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Configuration

/// Max pause between two Shift presses considered a "double-Shift" (sec).
let kDoubleShiftInterval: TimeInterval = 0.25
/// Typing buffer length limit (protection against unbounded growth).
let kMaxBufferLength = 500

let kLeftShiftKeyCode: CGKeyCode = 56   // kVK_Shift
let kRightShiftKeyCode: CGKeyCode = 60  // kVK_RightShift

// MARK: - Menu bar icon

enum StatusIcon {
    /// label — «RU» or «EN» (current layout); enabled=false — dimmed (no permissions).
    static func make(label: String, enabled: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let color = enabled ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.35)
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (18 - size.width) / 2, y: (18 - size.height) / 2))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

// MARK: - Main class

final class Switcher: NSObject {

    private var lastShiftPress: CFTimeInterval = 0
    private var lastShiftRelease: CFTimeInterval = 0
    private var busy = false
    private var isReplacing = false
    private var tapActive = false
    /// After converting a selection — true. Another double-Shift (with no other
    /// actions in between) undoes the paste (Cmd+Z) — toggle back.
    private var lastWasSelectionConvert = false

    /// A secure field (password) is focused: we neither listen nor convert it.
    private var secureField = false

    /// Typing buffer: we remember what the user typed (like Punto/Caramba).
    /// This lets us erase the text with Backspaces and retype the converted one
    /// in ANY app (VS Code, Slack included) — no Accessibility needed.
    private var typedBuffer = ""

    private var statusStateItem: NSMenuItem?
    private var autostartItem: NSMenuItem?
    private var a11yStatusItem: NSMenuItem?
    private var listenStatusItem: NSMenuItem?
    private var tapRetryTimer: Timer?

    func start() {
        let app = NSApplication.shared
        // Background app: no Dock icon; it appears only while the
        // permissions panel is open (see showPermissionsGuide).
        app.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        updateStatusIcon()
        updatePermissionStatus()
        // The icon follows the layout (also when the user switches it manually).
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatusIcon()
        }

        // 1. Silent permission check (no system dialogs — our own panel
        //    explains everything, see showPermissionsGuide).
        Accessibility.requestPermissionIfNeeded()

        // 2. Event tap with retries: the app stays alive and waits for permissions.
        startEventTap()

        // 3. If permissions are missing — show the guide window.
        if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPermissionsGuide()
            }
        }

        // 4. On first launch — ask about Launch at Login.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showAutostartPromptIfNeeded()
        }

        print("▶  AliSwitcher is running. Double-Shift = convert text + switch layout.")
        print("   Menu bar icon: «RU» → click → Quit.")
        app.run()
    }

    // MARK: - App menu (in the menu bar when the app is active)

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let guide = NSMenuItem(title: "Permissions…",
                               action: #selector(showPermissionsGuide),
                               keyEquivalent: "")
        guide.target = self
        appMenu.addItem(guide)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.make(label: "RU", enabled: false)
        let menu = NSMenu()

        let state = NSMenuItem(title: "AliSwitcher: waiting for permissions…", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        // Permission status: red dot = missing, green = granted
        let a11yStatus = NSMenuItem(title: "Accessibility", action: nil, keyEquivalent: "")
        a11yStatus.isEnabled = false
        menu.addItem(a11yStatus)
        a11yStatusItem = a11yStatus

        let listenStatus = NSMenuItem(title: "Input Monitoring", action: nil, keyEquivalent: "")
        listenStatus.isEnabled = false
        menu.addItem(listenStatus)
        listenStatusItem = listenStatus
        menu.addItem(.separator())

        // Launch at Login (SMAppService)
        let autostart = NSMenuItem(title: "Launch at Login",
                                   action: #selector(toggleAutostart),
                                   keyEquivalent: "")
        autostart.target = self
        autostart.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(autostart)
        autostartItem = autostart
        menu.addItem(.separator())

        // IMPORTANT: a background app has no first responder, so every menu item
        // with an action needs an explicit target — otherwise it turns grey.
        let a11yItem = NSMenuItem(title: "Permissions: Accessibility…",
                                  action: #selector(openAccessibilitySettings),
                                  keyEquivalent: "")
        a11yItem.target = self
        menu.addItem(a11yItem)

        let listenItem = NSMenuItem(title: "Permissions: Input Monitoring…",
                                    action: #selector(openInputMonitoringSettings),
                                    keyEquivalent: "")
        listenItem.target = self
        menu.addItem(listenItem)

        let guideItem = NSMenuItem(title: "How to set permissions…",
                                   action: #selector(showPermissionsGuide),
                                   keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        let uninstallItem = NSMenuItem(title: "Uninstall AliSwitcher…",
                                       action: #selector(uninstallApp),
                                       keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        statusStateItem = state
    }

    /// Updates the permission status rows in the menu (red/green dot) and the icon.
    private func updatePermissionStatus() {
        let ax = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        a11yStatusItem?.title = "\(ax ? "🟢" : "🔴") Accessibility"
        listenStatusItem?.title = "\(listen ? "🟢" : "🔴") Input Monitoring"
        statusStateItem?.title = (ax && listen)
            ? "AliSwitcher — double-Shift works"
            : "AliSwitcher: waiting for permissions (AX=\(ax), Listen=\(listen))"
    }

    @objc private func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// «Launch at Login» toggle (SMAppService, macOS 13+).
    @objc private func toggleAutostart() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            do {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    let alert = NSAlert()
                    alert.messageText = "Login Item needs approval"
                    alert.informativeText = "Enable AliSwitcher in System Settings → General → Login Items."
                    alert.addButton(withTitle: "OK")
                    showModal(alert)
                }
            } catch {
                log("autostart register error: \(error)")
            }
        }
        autostartItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    /// On first launch asks whether to add the app to Launch at Login.
    private func showAutostartPromptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "didAskAutostart") else { return }
        UserDefaults.standard.set(true, forKey: "didAskAutostart")

        let alert = NSAlert()
        alert.messageText = "Launch AliSwitcher at login?"
        alert.informativeText = "Add AliSwitcher to login items so the switcher is always ready?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        let response = showModal(alert)
        if response == .alertFirstButtonReturn {
            try? SMAppService.mainApp.register()
        }
        autostartItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    /// Shows a modal window ABOVE everything, including full-screen apps:
    /// the window becomes auxiliary (floating) and visible on all Spaces.
    private func showModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let window = alert.window
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.level = .floating
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return alert.runModal()
    }

    /// Permissions guide window: does not close on button presses until
    /// «Done» (both settings sections can be opened).
    private var permissionsPanel: NSPanel?

    @objc private func showPermissionsGuide() {
        if let panel = permissionsPanel {
            NSApp.setActivationPolicy(.regular)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "AliSwitcher: permissions needed"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))

        let label = NSTextField(wrappingLabelWithString: """
        Permissions are granted in System Settings → Privacy & Security.

        REQUIRED:
        • Input Monitoring — tracking keystrokes (double-Shift).
        RECOMMENDED:
        • Accessibility — selected text conversion and password-field protection.

        The buttons below open the settings — the window stays open.
        """)
        label.frame = NSRect(x: 20, y: 130, width: 420, height: 150)
        label.font = NSFont.systemFont(ofSize: 13)
        content.addSubview(label)

        let listenButton = NSButton(title: "Input Monitoring…",
                                    target: self,
                                    action: #selector(openInputMonitoringSettings))
        listenButton.frame = NSRect(x: 20, y: 90, width: 280, height: 28)
        content.addSubview(listenButton)

        let a11yButton = NSButton(title: "Accessibility…",
                                  target: self,
                                  action: #selector(openAccessibilitySettings))
        a11yButton.frame = NSRect(x: 20, y: 56, width: 280, height: 28)
        content.addSubview(a11yButton)

        let doneButton = NSButton(title: "Done",
                                  target: self,
                                  action: #selector(closePermissionsPanel))
        doneButton.frame = NSRect(x: 20, y: 14, width: 100, height: 28)
        content.addSubview(doneButton)

        panel.contentView = content
        permissionsPanel = panel
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func closePermissionsPanel() {
        permissionsPanel?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    /// Full uninstall: warning → uninstall.sh with administrator rights.
    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Uninstall AliSwitcher?"
        alert.informativeText = """
        This will remove:
        • the app from /Applications;
        • Launch at Login item;
        • installation record, logs and temp files.

        This cannot be undone. Continue?
        """
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        let response = showModal(alert)
        guard response == .alertFirstButtonReturn else { return }

        // Run uninstall.sh with administrator rights (macOS asks for the password).
        // Path is taken from our own bundle — the app can run from anywhere.
        let script = Bundle.main.bundlePath + "/Contents/Resources/uninstall.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            let err = NSAlert()
            err.messageText = "Uninstall script not found"
            err.informativeText = script
            err.addButton(withTitle: "OK")
            showModal(err)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
        try? process.run()
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Event tap

    private func startEventTap() {
        let eventMask = CGEventMask(1 << Int(CGEventType.flagsChanged.rawValue))
            | CGEventMask(1 << Int(CGEventType.keyDown.rawValue))
            | CGEventMask(1 << Int(CGEventType.leftMouseDown.rawValue))
            | CGEventMask(1 << Int(CGEventType.rightMouseDown.rawValue))
            | CGEventMask(1 << Int(CGEventType.otherMouseDown.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return nil }
                let switcher = Unmanaged<Switcher>.fromOpaque(refcon).takeUnretainedValue()
                return switcher.handle(event: event, type: type)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            let ax = AXIsProcessTrusted()
            let listen = CGPreflightListenEventAccess()
            log("⚠  Event tap not created: Accessibility=\(ax), InputMonitoring=\(listen)")
            tapActive = false
            updatePermissionStatus()
            statusItem?.button?.toolTip = "AliSwitcher: waiting for permissions (AX=\(ax), Listen=\(listen))"
            updateStatusIcon()
            statusStateItem?.title = "AliSwitcher: waiting for permissions (AX=\(ax), Listen=\(listen)) — System Settings → Privacy & Security"
            tapRetryTimer?.invalidate()
            tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.startEventTap()
            }
            return
        }

        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        currentTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("✔  Event tap active — permissions granted, waiting for double-Shift")
        tapActive = true
        updatePermissionStatus()
        statusItem?.button?.toolTip = "AliSwitcher: working (double-Shift)"
        updateStatusIcon()
        statusStateItem?.title = "AliSwitcher — double-Shift works"
        print("✔  Event tap active.")
    }

    /// Menu bar icon: «RU»/«EN» for the current layout.
    private func updateStatusIcon() {
        let label = LayoutSwitch.currentIsRussian() ? "RU" : "EN"
        statusItem?.button?.image = StatusIcon.make(label: label, enabled: tapActive)
    }

    // MARK: - Event handling

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = currentTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        switch type {
        case .keyDown:
            // Any key press resets the double-Shift counter
            lastShiftPress = 0
            // Selection toggle reset — only on real user keystrokes.
            // Our own synthetic Cmd+C/Cmd+V/Cmd+Z (privateState) don't count.
            if lastWasSelectionConvert, !isSynthetic(event) {
                lastWasSelectionConvert = false
            }
            // Remember what was typed (Punto mechanism)
            trackTyping(event)
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Mouse click — the typed fragment is "lost" (caret may have moved)
            typedBuffer = ""
            secureField = false
            lastWasSelectionConvert = false
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            break

        default:
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kLeftShiftKeyCode) || keyCode == Int64(kRightShiftKeyCode) else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = event.flags.contains(.maskShift)
        let now = CFAbsoluteTimeGetCurrent()

        if isDown {
            if lastShiftPress != 0,
               now - lastShiftPress < kDoubleShiftInterval,
               lastShiftRelease > lastShiftPress {
                // Double-Shift — eat the second press and trigger conversion.
                lastShiftPress = 0
                triggerSwitch()
                return nil
            }
            lastShiftPress = now
        } else {
            lastShiftRelease = now
        }
        return Unmanaged.passUnretained(event)
    }

    /// Is the event synthetic (ours)? Synthetic events created by us
    /// via CGEventSource have eventSourceUnixProcessID == our PID.
    private func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }

    /// Updates the typing buffer from a key event.
    private func trackTyping(_ event: CGEvent) {
        guard let layout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        switch KeyTracker.action(for: event, currentLayout: layout) {
        case .text(let s):
            // At the start of a new fragment check whether this is a password field.
            if typedBuffer.isEmpty, !secureField {
                secureField = isFocusedFieldSecure()
            }
            guard !secureField else { return }
            typedBuffer.append(s)
            if typedBuffer.count > kMaxBufferLength {
                typedBuffer.removeFirst(typedBuffer.count - kMaxBufferLength)
            }
        case .deleteBackward:
            if secureField { return }
            if !typedBuffer.isEmpty { typedBuffer.removeLast() }
        case .reset:
            typedBuffer = ""
            secureField = false
        case .ignore:
            break
        }
    }

    private func isFocusedFieldSecure() -> Bool {
        guard let element = Accessibility.focusedElement() else { return false }
        return Accessibility.isSecureField(element)
    }

    // MARK: - Conversion

    private func triggerSwitch() {
        guard !busy else { return }
        busy = true
        DispatchQueue.main.async { [weak self] in
            self?.performSwitch()
        }
    }

    private func performSwitch() {
        defer { busy = false }
        log("switch: buffer «\(redact(typedBuffer))»")

        // Password field — do not touch at all.
        if secureField {
            log("switch: secure field — skipping")
            return
        }

        // 1) If the buffer is empty, the user may have selected text.
        if typedBuffer.isEmpty {
            // 1a) Right after a selection conversion (and with no other actions)
            //     another double-Shift undoes the paste (Cmd+Z) — toggle back.
            if lastWasSelectionConvert {
                log("toggle: undoing the last conversion (Cmd+Z)")
                lastWasSelectionConvert = false
                KeyEvents.undo()
                return
            }
            // 1b) Try to convert the selection via the clipboard.
            //     If there is no selection — a layout toggle happens inside.
            convertSelectionViaClipboard()
            return
        }

        // 2) Main path: fragment from real text (if AX is available) or from the buffer.
        convertTypedText()
    }

    /// Converts the selected text via the clipboard:
    /// Cmd+C → read the buffer → convert → Cmd+V (replaces the selection).
    /// If there is no selection or nothing to convert — toggles the layout.
    private func convertSelectionViaClipboard() {
        guard !isReplacing else { return }
        isReplacing = true

        let pasteboard = NSPasteboard.general
        let beforeChange = pasteboard.changeCount
        let saved = Clipboard.snapshot()

        KeyEvents.copySelection()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard pasteboard.changeCount != beforeChange,
                  let text = pasteboard.string(forType: .string),
                  !text.isEmpty,
                  let result = Translit.convert(text),
                  result.converted != text else {
                // No selection or nothing to convert — just toggle the layout.
                self.log("selection(copy): nothing to copy/convert → toggle")
                Clipboard.restore(saved)
                self.isReplacing = false
                LayoutSwitch.toggle()
                return
            }
            self.log("selection(copy): «\(self.redact(text))» → «\(self.redact(result.converted))»")
            self.lastWasSelectionConvert = true
            LayoutSwitch.select(toRussian: result.direction == .toCyrillic)
            Clipboard.copy(result.converted)
            KeyEvents.paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Clipboard.restore(saved)
                self.isReplacing = false
            }
        }
    }

    /// Main path: find the "typed in the wrong layout" fragment
    /// (from real field text if Accessibility is available, otherwise from the buffer),
    /// erase it with Backspaces and retype the converted text.
    private func convertTypedText() {
        let ns: NSString
        if let real = realTextBeforeCaret(), !real.isEmpty {
            ns = real as NSString
            log("convert: using real field text (\(ns.length) chars)")
        } else {
            ns = typedBuffer as NSString
            log("convert: using typing buffer (\(ns.length) chars)")
        }

        let caret = ns.length
        let start = ChunkFinder.chunkStart(in: ns, before: caret)
        guard start < caret else {
            log("convert: empty fragment → toggle")
            LayoutSwitch.toggle()
            return
        }
        let chunk = ns.substring(with: NSRange(location: start, length: caret - start))
        guard !chunk.isEmpty,
              let result = Translit.convert(chunk),
              result.converted != chunk else {
            log("convert: «\(chunk)» cannot be converted → toggle")
            LayoutSwitch.toggle()
            return
        }
        log("convert: «\(redact(chunk))» → «\(redact(result.converted))»")
        replaceByDeleting(result.converted,
                          deleteCount: chunk.count,
                          toRussian: result.direction == .toCyrillic)
    }

    /// The field text before the caret (if Accessibility is available).
    private func realTextBeforeCaret() -> String? {
        guard let element = Accessibility.focusedElement(),
              let whole = Accessibility.value(element),
              let range = Accessibility.selectedRange(element) else { return nil }
        let ns = whole as NSString
        let caret = Int(range.location) + Int(range.length)
        guard caret > 0, caret <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: 0, length: caret))
    }

    /// Switches the layout, erases deleteCount characters, types the text.
    private func replaceByDeleting(_ text: String, deleteCount: Int, toRussian: Bool) {
        guard !isReplacing else { return }
        guard LayoutSwitch.select(toRussian: toRussian) else {
            log("replaceByDeleting: no target layout — leaving text as is")
            return
        }
        isReplacing = true
        KeyEvents.backspace(count: deleteCount) { [weak self] in
            guard let self else { return }
            self.log("deleted \(deleteCount), typing «\(text)»")
            KeyEvents.type(text, toRussian: toRussian) {
                self.isReplacing = false
            }
        }
    }

    // MARK: - Log

    /// Shortens text in the log (privacy: do not write full content).
    private func redact(_ s: String, limit: Int = 24) -> String {
        guard s.count > limit else { return s }
        return s.prefix(limit) + "…"
    }

    private func log(_ message: String) {
        let line = "[\(String(format: "%.3f", Date().timeIntervalSince1970))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/AliSwitcher.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Global state

var currentTap: CFMachPort?
var statusItem: NSStatusItem?

// MARK: - Singleton: only one app instance

var singletonLockFD: Int32 = -1

/// Acquires an exclusive lock (flock). If another instance is already running
/// (LaunchAgent + manual launch, autostart + open), the second one cannot
/// acquire the lock and exits — no duplicates, no double event taps.
func acquireSingletonLock() -> Bool {
    let lockPath = "/tmp/local.alishch.aliswitcher.lock"
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    singletonLockFD = fd // keep it open for the process lifetime
    return true
}

// MARK: - Launch

if CommandLine.arguments.contains("--test") {
    exit(SelfTests.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--layouts") {
    LayoutSwitch.debugPrint()
    exit(0)
}

if !acquireSingletonLock() {
    print("AliSwitcher already running — second instance exits.")
    exit(0)
}

print("AliSwitcher — RU/EN layout switcher via double-Shift")
print("====================================================")
Switcher().start()
