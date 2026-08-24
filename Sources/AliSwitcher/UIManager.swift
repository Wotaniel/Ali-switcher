import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Status bar icon helper

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

// MARK: - UI Manager

/// Handles all user interface: menu bar, panels, word list editors,
/// permissions guide, about panel, uninstall dialog.
///
/// `Switcher` creates a `UIManager` and calls its methods during startup
/// and when permission/event-tap state changes. UI delegates (NSWindowDelegate)
/// are handled here, so panel close behavior (activation policy restoration)
/// lives in one place.
final class UIManager: NSObject, NSWindowDelegate {

    private let state: SwitcherState

    // MARK: - Menu bar

    private var statusItem: NSStatusItem?
    private var statusStateItem: NSMenuItem?
    private var autostartItem: NSMenuItem?
    private var a11yStatusItem: NSMenuItem?
    private var listenStatusItem: NSMenuItem?
    private var autoModeItem: NSMenuItem?
    private var autoLearnItem: NSMenuItem?

    // MARK: - Word list editors

    private var enWordsPanel: NSPanel?
    private var enWordsTextView: NSTextView?
    private var ruWordsPanel: NSPanel?
    private var ruWordsTextView: NSTextView?

    /// True if any word-list editor panel is currently visible.
    /// Checked by Switcher.handle() to suppress auto-convert while the user
    /// is typing in our own text fields (otherwise auto-convert would
    /// convert the words they're trying to add as exceptions).
    var anyEditorVisible: Bool {
        enWordsPanel?.isVisible ?? false || ruWordsPanel?.isVisible ?? false
    }

    // MARK: - Permissions panel

    private var permissionsPanel: NSPanel?

    init(state: SwitcherState) {
        self.state = state
    }

    // MARK: - App menu (in the menu bar when the app is active)

    func setupMainMenu() {
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

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.make(label: "RU", enabled: false)
        let menu = NSMenu()

        let stateItem = NSMenuItem(title: "AliSwitcher: waiting for permissions…", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
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

        // Auto Switch (Punto Switcher style: auto-detect wrong layout)
        let autoMode = NSMenuItem(title: "Auto Switch",
                                  action: #selector(toggleAutoMode),
                                  keyEquivalent: "")
        autoMode.target = self
        autoMode.state = state.autoModeEnabled ? .on : .off
        menu.addItem(autoMode)
        autoModeItem = autoMode

        // Auto-learn exceptions (undo → add word to exceptions)
        let autoLearn = NSMenuItem(title: "Auto-Learn Exceptions",
                                   action: #selector(toggleAutoLearn),
                                   keyEquivalent: "")
        autoLearn.target = self
        autoLearn.state = state.autoLearnExceptions ? .on : .off
        menu.addItem(autoLearn)
        autoLearnItem = autoLearn

        // Two separate word lists: English (Latin) and Russian (Cyrillic)
        let enWordsItem = NSMenuItem(title: "English Words…",
                                     action: #selector(showEnglishWordsEditor),
                                     keyEquivalent: "")
        enWordsItem.target = self
        menu.addItem(enWordsItem)

        let ruWordsItem = NSMenuItem(title: "Russian Words…",
                                     action: #selector(showRussianWordsEditor),
                                     keyEquivalent: "")
        ruWordsItem.target = self
        menu.addItem(ruWordsItem)
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

        let aboutItem = NSMenuItem(title: "About AliSwitcher",
                                   action: #selector(showAbout),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        statusStateItem = stateItem
    }

    /// Updates the permission status rows in the menu (red/green dot).
    func updatePermissionStatus() {
        let ax = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        a11yStatusItem?.title = "\(ax ? "🟢" : "🔴") Accessibility"
        listenStatusItem?.title = "\(listen ? "🟢" : "🔴") Input Monitoring"
        statusStateItem?.title = (ax && listen)
            ? "AliSwitcher — double-Shift works"
            : "AliSwitcher: waiting for permissions (AX=\(ax), Listen=\(listen))"
    }

    /// Menu bar icon: «RU»/«EN» for the current layout.
    func updateStatusIcon() {
        let label = LayoutSwitch.currentIsRussian() ? "RU" : "EN"
        let enabled: Bool = state.tapActive
        statusItem?.button?.image = StatusIcon.make(label: label, enabled: enabled)
    }

    /// Sets the status bar tooltip (called from event tap code).
    func setToolTip(_ text: String) {
        statusItem?.button?.toolTip = text
    }

    /// Sets the status state menu item title (called from event tap code).
    func setStatusStateTitle(_ text: String) {
        statusStateItem?.title = text
    }

    // MARK: - Permission settings

    @objc private func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    @objc private func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Launch at Login

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
    func showAutostartPromptIfNeeded() {
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

    // MARK: - Toggles

    /// «Auto Switch» toggle (Punto Switcher style auto-detection).
    @objc private func toggleAutoMode() {
        state.autoModeEnabled = !state.autoModeEnabled
        UserDefaults.standard.set(state.autoModeEnabled, forKey: "autoModeEnabled")
        autoModeItem?.state = state.autoModeEnabled ? .on : .off
        log("auto mode: \(state.autoModeEnabled ? "ON" : "OFF")")
    }

    /// «Auto-Learn Exceptions» toggle: when ON, undoing an auto-conversion
    /// adds the word to the exceptions list automatically.
    @objc private func toggleAutoLearn() {
        state.autoLearnExceptions = !state.autoLearnExceptions
        UserDefaults.standard.set(state.autoLearnExceptions, forKey: "autoLearnExceptions")
        autoLearnItem?.state = state.autoLearnExceptions ? .on : .off
        log("auto-learn: \(state.autoLearnExceptions ? "ON" : "OFF")")
    }

    // MARK: - Word list editors (English & Russian)

    @objc private func showEnglishWordsEditor() {
        showWordsEditor(
            lang: "English",
            description: "English words — one per line.\n"
                + "These block auto-conversion in Latin → Russian direction.",
            panel: &enWordsPanel,
            textView: &enWordsTextView,
            isLatin: true
        )
    }

    @objc private func showRussianWordsEditor() {
        showWordsEditor(
            lang: "Russian",
            description: "Russian words — one per line.\n"
                + "These block auto-conversion in Russian → Latin direction.",
            panel: &ruWordsPanel,
            textView: &ruWordsTextView,
            isLatin: false
        )
    }

    private func showWordsEditor(
        lang: String,
        description: String,
        panel: inout NSPanel?,
        textView: inout NSTextView?,
        isLatin: Bool
    ) {
        if let existingPanel = panel {
            NSApp.setActivationPolicy(.regular)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            existingPanel.makeKeyAndOrderFront(nil)
            return
        }

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "AliSwitcher: \(lang) Words"
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.level = .floating
        newPanel.isReleasedWhenClosed = false
        newPanel.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 400))

        let label = NSTextField(wrappingLabelWithString: description)
        label.frame = NSRect(x: 16, y: 348, width: 428, height: 48)
        label.font = NSFont.systemFont(ofSize: 11)
        content.addSubview(label)

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 50, width: 428, height: 290))
        let newTextView = NSTextView(frame: scrollView.bounds)
        newTextView.isEditable = true
        newTextView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        newTextView.autoresizingMask = [.width]
        scrollView.documentView = newTextView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        content.addSubview(scrollView)

        let saveButton = NSButton(title: "Save",
                                  target: self,
                                  action: #selector(saveWordsFromEditor))
        saveButton.frame = NSRect(x: 16, y: 14, width: 80, height: 28)
        saveButton.keyEquivalent = "\r"
        // tag identifies which language: 1 = English (Latin), 2 = Russian (Cyrillic)
        saveButton.tag = isLatin ? 1 : 2
        content.addSubview(saveButton)

        let countLabel = NSTextField(labelWithString: "")
        countLabel.frame = NSRect(x: 110, y: 18, width: 250, height: 20)
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.tag = 999
        content.addSubview(countLabel)

        newPanel.delegate = self
        newPanel.contentView = content
        panel = newPanel
        textView = newTextView

        populateWordsEditor(isLatin: isLatin, textView: newTextView, panel: newPanel)
        updateWordsCount(isLatin: isLatin, panel: newPanel)

        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        newPanel.makeKeyAndOrderFront(nil)
    }

    /// Populates the editor with words for the given language.
    /// One word per line, sorted alphabetically.
    private func populateWordsEditor(isLatin: Bool, textView: NSTextView, panel: NSPanel) {
        let words = isLatin
            ? AutoSwitcher.enWords.sorted()
            : AutoSwitcher.ruWords.sorted()
        textView.string = words.isEmpty ? "" : words.joined(separator: "\n")
    }

    private func updateWordsCount(isLatin: Bool, panel: NSPanel) {
        let count = isLatin ? AutoSwitcher.enWords.count : AutoSwitcher.ruWords.count
        let view = panel.contentView?.viewWithTag(999) as? NSTextField
        view?.stringValue = count == 0 ? "No words" : "\(count) word\(count == 1 ? "" : "s")"
    }

    @objc private func saveWordsFromEditor(_ sender: NSButton) {
        let isLatin = sender.tag == 1
        let textView = isLatin ? enWordsTextView : ruWordsTextView
        let panel = isLatin ? enWordsPanel : ruWordsPanel
        let text = textView?.string ?? ""

        // Parse: one word per line.
        var words: Set<String> = []
        for line in text.components(separatedBy: .newlines) {
            let word = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard !word.isEmpty else { continue }
            words.insert(word)
        }

        if isLatin {
            AutoSwitcher.enWords = words
        } else {
            AutoSwitcher.ruWords = words
        }
        saveLearnedWords()
        log("words: saved \(words.count) \(isLatin ? "EN" : "RU") words")

        // Refresh both editors if they're open
        if let p = enWordsPanel, let tv = enWordsTextView {
            populateWordsEditor(isLatin: true, textView: tv, panel: p)
            updateWordsCount(isLatin: true, panel: p)
        }
        if let p = ruWordsPanel, let tv = ruWordsTextView {
            populateWordsEditor(isLatin: false, textView: tv, panel: p)
            updateWordsCount(isLatin: false, panel: p)
        }

        panel?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Permissions guide

    /// Permissions guide window: does not close on button presses until
    /// «Done» (both settings sections can be opened).
    @objc func showPermissionsGuide() {
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

        panel.delegate = self
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

    // MARK: - About panel

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AliSwitcher"
        alert.informativeText = """
            Version \(kAppVersion) (build \(kBuildNumber), \(kGitHash))

            macOS layout switcher (RU↔EN).
            Mini-analog of Punto/Caramba Switcher.

            Double-Shift — convert selection or typed text.
            Auto Switch — detects wrong layout on word boundaries.
            Auto-Learn — undoing adds words to exceptions.

            https://github.com/alishch/AliSwitcher
            """
        alert.alertStyle = .informational
        alert.icon = NSImage(named: "AliSwitcher")
        alert.addButton(withTitle: "OK")
        showModal(alert)
    }

    // MARK: - Uninstall

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

    // MARK: - Modal helper

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

    // MARK: - NSWindowDelegate

    /// Called when ANY panel is closed — including via the red close button.
    /// Without this, closing a panel via the close button (not "Save") would
    /// leave the app in .regular activation policy and show a Dock icon.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Only restore accessory if no other panels are visible.
        let enWordsVisible = enWordsPanel?.isVisible ?? false
        let ruWordsVisible = ruWordsPanel?.isVisible ?? false
        let permissionsVisible = permissionsPanel?.isVisible ?? false
        // windowWillClose fires BEFORE isVisible becomes false, so exclude
        // the window that's currently closing.
        let othersVisible: Bool
        if window === enWordsPanel {
            othersVisible = ruWordsVisible || permissionsVisible
        } else if window === ruWordsPanel {
            othersVisible = enWordsVisible || permissionsVisible
        } else if window === permissionsPanel {
            othersVisible = enWordsVisible || ruWordsVisible
        } else {
            othersVisible = enWordsVisible || ruWordsVisible || permissionsVisible
        }
        if !othersVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
