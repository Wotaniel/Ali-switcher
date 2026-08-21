import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Configuration

/// App version (read from VERSION file at build time, fallback "1.0.0").
let kAppVersion: String = {
    if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty {
        return v
    }
    return "1.0.0"
}()

/// Max pause between two Shift presses considered a "double-Shift" (sec).
let kDoubleShiftInterval: TimeInterval = 0.25
/// Typing buffer length limit (protection against unbounded growth).
let kMaxBufferLength = 500

let kLeftShiftKeyCode: CGKeyCode = 56   // kVK_Shift
let kRightShiftKeyCode: CGKeyCode = 60  // kVK_RightShift

// MARK: - Timing constants (centralized for easy tuning)

enum Timing {
    /// Delay between successive backspace key presses.
    static let backspaceDelay: TimeInterval = 0.008
    /// Delay between successive character typing.
    static let typeDelay: TimeInterval = 0.01
    /// Delay after switching layout before typing begins (let layout settle).
    static let layoutSwitchDelay: TimeInterval = 0.05
    /// Delay before backspace begins in auto-convert (after layout switch).
    static let autoConvertDelay: TimeInterval = 0.02
    /// Delay to allow clipboard copy to complete before reading.
    static let clipboardWait: TimeInterval = 0.15
    /// Delay before restoring clipboard after paste.
    static let clipboardRestore: TimeInterval = 0.4
}

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

final class Switcher: NSObject, NSWindowDelegate {

    private var lastShiftPress: CFTimeInterval = 0
    private var lastShiftRelease: CFTimeInterval = 0
    private var busy = false
    private var isReplacing = false
    private var tapActive = false
    /// After converting a selection — true. Another double-Shift (with no other
    /// actions in between) undoes the paste (Cmd+Z) — toggle back.
    private var lastWasSelectionConvert = false

    /// After auto-converting a word — stores info to undo the conversion.
    /// Double-Shift right after auto-convert reverts to the original text and
    /// layout (backspace the converted text, retype the original).
    /// Undoing also adds the trigger word to the exceptions list (self-learning,
    /// like Caramba: "delete + retype = skip this word next time").
    /// Any real (non-synthetic) keystroke cancels the undo window.
    private var lastAutoConvertInfo: (
        original: String,      // text to retype in the original layout
        backspaceCount: Int,   // chars to delete (converted text + boundary)
        undoToRussian: Bool,   // switch back to the opposite layout
        triggerWord: String    // the word that triggered conversion (for exceptions)
    )?;

    /// Remembers recent auto-converted word pairs (original → converted).
    /// Survives real keystrokes (unlike lastAutoConvertInfo) so that when the
    /// user manually converts the result back via clipboard, we can detect it
    /// and add the trigger word to exceptions.
    /// Stores multiple pairs because a later auto-convert shouldn't erase an
    /// earlier one that the user might still undo.
    private var recentAutoConvertedWords: [(original: String, converted: String)] = []
    private let maxRecentAutoWords = 20

    /// Characters typed during replacement (isReplacing) are buffered here
    /// and replayed after the replacement completes. Without this, fast
    /// typists' keystrokes land in wrong positions because our synthetic
    /// backspaces are happening concurrently.
    private var pendingCharacters: String = ""

    /// Auto-learn: if user undoes an auto-conversion, add the word pair to
    /// the learned list as an exception. Enabled by default — Caramba-style.
    private var autoLearnExceptions = true
    private var autoLearnItem: NSMenuItem?

    /// Auto mode (Punto Switcher style): automatically converts words at
    /// word boundaries using NSSpellChecker.
    private var autoModeEnabled = false
    private var autoModeItem: NSMenuItem?

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
        autoModeEnabled = UserDefaults.standard.bool(forKey: "autoModeEnabled")
        // Auto-learn defaults to true (enabled on first launch).
        autoLearnExceptions = UserDefaults.standard.object(forKey: "autoLearnExceptions") as? Bool ?? true
        // Load user word lists (two independent lists: EN and RU).
        loadLearnedWords()
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

        // Auto Switch (Punto Switcher style: auto-detect wrong layout)
        let autoMode = NSMenuItem(title: "Auto Switch",
                                  action: #selector(toggleAutoMode),
                                  keyEquivalent: "")
        autoMode.target = self
        autoMode.state = autoModeEnabled ? .on : .off
        menu.addItem(autoMode)
        autoModeItem = autoMode

        // Auto-learn exceptions (undo → add word to exceptions)
        let autoLearn = NSMenuItem(title: "Auto-Learn Exceptions",
                                   action: #selector(toggleAutoLearn),
                                   keyEquivalent: "")
        autoLearn.target = self
        autoLearn.state = autoLearnExceptions ? .on : .off
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

    /// «Auto Switch» toggle (Punto Switcher style auto-detection).
    @objc private func toggleAutoMode() {
        autoModeEnabled = !autoModeEnabled
        UserDefaults.standard.set(autoModeEnabled, forKey: "autoModeEnabled")
        autoModeItem?.state = autoModeEnabled ? .on : .off
        log("auto mode: \(autoModeEnabled ? "ON" : "OFF")")
    }

    /// «Auto-Learn Exceptions» toggle: when ON, undoing an auto-conversion
    /// adds the word to the exceptions list automatically.
    @objc private func toggleAutoLearn() {
        autoLearnExceptions = !autoLearnExceptions
        UserDefaults.standard.set(autoLearnExceptions, forKey: "autoLearnExceptions")
        autoLearnItem?.state = autoLearnExceptions ? .on : .off
        log("auto-learn: \(autoLearnExceptions ? "ON" : "OFF")")
    }

    // MARK: - Word list editors (English & Russian)

    private var enWordsPanel: NSPanel?
    private var enWordsTextView: NSTextView?
    private var ruWordsPanel: NSPanel?
    private var ruWordsTextView: NSTextView?

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
            let word = line.trimmingCharacters(in: .whitespaces)
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

    // MARK: - Learned words (two independent lists: EN and RU)

    /// Loads two word lists from UserDefaults. Migrates old formats.
    private func loadLearnedWords() {
        // New format: two separate arrays.
        if let en = UserDefaults.standard.array(forKey: "enWords") as? [String] {
            AutoSwitcher.enWords = Set(en)
        }
        if let ru = UserDefaults.standard.array(forKey: "ruWords") as? [String] {
            AutoSwitcher.ruWords = Set(ru)
        }

        // Migrate old "learnedWords" format (formA\tformB\texc/dict).
        if let oldArr = UserDefaults.standard.array(forKey: "learnedWords") as? [String] {
            for line in oldArr {
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 1 else { continue }
                let word = parts[0]
                if !word.isEmpty {
                    AutoSwitcher.addException(word)
                }
            }
            UserDefaults.standard.removeObject(forKey: "learnedWords")
            saveLearnedWords()
            log("migrated old learnedWords → enWords(\(AutoSwitcher.enWords.count)) + ruWords(\(AutoSwitcher.ruWords.count))")
        }

        // Migrate very old formats.
        if let oldExc = UserDefaults.standard.array(forKey: "autoExceptions") as? [String] {
            for word in oldExc { AutoSwitcher.addException(word) }
            UserDefaults.standard.removeObject(forKey: "autoExceptions")
            saveLearnedWords()
        }
        if let oldDict = UserDefaults.standard.array(forKey: "customDictionary") as? [String] {
            // Old dictionary words → just add as exceptions (block auto-convert).
            for word in oldDict { AutoSwitcher.addException(word) }
            UserDefaults.standard.removeObject(forKey: "customDictionary")
            saveLearnedWords()
        }
    }

    /// Saves two word lists to UserDefaults.
    private func saveLearnedWords() {
        UserDefaults.standard.set(Array(AutoSwitcher.enWords), forKey: "enWords")
        UserDefaults.standard.set(Array(AutoSwitcher.ruWords), forKey: "ruWords")
    }

    /// Adds a word to the appropriate exception list (auto-learn on undo).
    private func learnException(_ word: String) {
        AutoSwitcher.addException(word)
        saveLearnedWords()
        log("exception: «\(redact(word))» (EN: \(AutoSwitcher.enWords.count), RU: \(AutoSwitcher.ruWords.count))")
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
            Version \(kAppVersion)

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
            // During replacement (backspace + retype), swallow real keystrokes
            // and buffer them — they'd land in wrong positions during backspacing.
            // Replayed after replacement completes.
            if isReplacing, !isSynthetic(event) {
                if let layout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
                    let action = KeyTracker.action(for: event, currentLayout: layout)
                    switch action {
                    case .text(let s):
                        pendingCharacters.append(s)
                    case .deleteBackward:
                        if !pendingCharacters.isEmpty { pendingCharacters.removeLast() }
                    case .reset:
                        pendingCharacters = ""
                    case .ignore:
                        break
                    }
                }
                return nil  // swallow — replayed after replacement
            }
            // Selection toggle reset — only on real user keystrokes.
            // Our own synthetic Cmd+C/Cmd+V/Cmd+Z (privateState) don't count.
            if lastWasSelectionConvert, !isSynthetic(event) {
                lastWasSelectionConvert = false
            }
            // Real keystrokes cancel the auto-convert undo window.
            if lastAutoConvertInfo != nil, !isSynthetic(event) {
                lastAutoConvertInfo = nil
            }
            // Auto mode: on word-boundary characters (space, period, etc.)
            // check the preceding word and auto-convert if needed.
            // IMPORTANT: we block the original boundary character (return nil)
            // and re-type it after conversion — otherwise backspace erases
            // the wrong characters (space is already printed after the word).
            // Cache KeyTracker.action to avoid calling it twice per keystroke.
            if autoModeEnabled, !busy, !isReplacing, !secureField, !isSynthetic(event) {
                if let layout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
                    let action = KeyTracker.action(for: event, currentLayout: layout)
                    if case .text(let s) = action, s.count == 1, AutoSwitcher.isBoundary(s[s.startIndex]) {
                        if tryAutoConvert(boundaryChar: s) {
                            return nil  // block boundary char — re-typed after conversion
                        }
                    }
                    // Reuse the cached action (don't call KeyTracker again)
                    trackTypedAction(action)
                }
            } else if !isSynthetic(event) {
                // Don't track our own synthetic events — they'd pollute the buffer
                trackTyping(event)
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Mouse click — the typed fragment is "lost" (caret may have moved)
            typedBuffer = ""
            secureField = false
            lastWasSelectionConvert = false
            lastAutoConvertInfo = nil
            // NOTE: do NOT clear recentAutoConvertedWords here!
            // The user needs to CLICK to select text for selection undo —
            // clearing would destroy the exception learning data.
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

    /// Replays characters that were typed during replacement (isReplacing).
    /// They were buffered to prevent cursor displacement during backspace+retype.
    private func replayPendingKeystrokes() {
        guard !pendingCharacters.isEmpty else { return }
        let text = pendingCharacters
        pendingCharacters = ""
        log("replay: «\(redact(text))» (\(text.count) chars)")
        let toRussian = Translit.isCyrillic(text.first!)
        KeyEvents.replay(text, toRussian: toRussian) { [weak self] in
            // Track in buffer so future auto-convert / manual switch sees them
            self?.trackTypedAction(.text(text))
        }
    }

    /// Updates the typing buffer from a key event.
    private func trackTyping(_ event: CGEvent) {
        guard let layout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let action = KeyTracker.action(for: event, currentLayout: layout)
        trackTypedAction(action)
    }

    /// Updates the typing buffer from a pre-computed KeyTracker.Action.
    /// Allows caching the action result to avoid calling KeyTracker twice.
    private func trackTypedAction(_ action: KeyTracker.Action) {
        switch action {
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

    // MARK: - Auto Switch (Punto Switcher style)

    /// Extracts the last word from the typing buffer (everything after the
    /// last boundary character) and attempts auto-conversion via NSSpellChecker.
    /// Returns true if auto-conversion was triggered (boundary char blocked),
    /// false if no conversion needed (boundary char should pass through).
    private func tryAutoConvert(boundaryChar: String) -> Bool {
        guard !busy, !isReplacing else { return false }

        // Delegate to the pure function (shared with tests).
        // This ensures the real code path and test code path are identical.
        guard let decision = AutoSwitcher.evaluateAutoConvert(
            buffer: typedBuffer, boundaryChar: boundaryChar
        ) else {
            return false
        }

        let toRussian = decision.direction == .toCyrillic
        log("auto: «\(redact(decision.triggerWord))» → «\(redact(decision.convertedText))» (retroactive \(decision.wordCount) words, deleting \(decision.deleteCount))")

        let fullConvertedText = decision.fullConvertedText

        busy = true
        isReplacing = true
        guard LayoutSwitch.select(toRussian: toRussian) else {
            log("auto: no target layout — skipping")
            busy = false
            isReplacing = false
            return false
        }
        typedBuffer = ""

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.autoConvertDelay) { [weak self] in
            guard let self else { return }
            KeyEvents.backspace(count: decision.deleteCount) { [weak self] in
                guard let self else { return }
                KeyEvents.type(fullConvertedText, toRussian: toRussian) { [weak self] in
                    guard let self else { return }
                    self.isReplacing = false
                    self.busy = false
                    self.replayPendingKeystrokes()
                    // Store undo info: double-Shift reverts this conversion.
                    self.lastAutoConvertInfo = (
                        original: decision.originalText + boundaryChar,
                        backspaceCount: fullConvertedText.count,
                        undoToRussian: !toRussian,
                        triggerWord: decision.triggerWord
                    )
                    // Also remember the word pair for delayed exception learning
                    // (survives real keystrokes, used by clipboard undo).
                    // Keep a list — a later auto-convert shouldn't erase an
                    // earlier pair the user might still undo.
                    self.recentAutoConvertedWords.append((original: decision.triggerWord, converted: decision.convertedText))
                    if self.recentAutoConvertedWords.count > self.maxRecentAutoWords {
                        self.recentAutoConvertedWords.removeFirst()
                    }
                }
            }
        }
        return true
    }

    /// Reverts the last auto-conversion: switches back to the original layout,
    /// backspaces the converted text, and retypes the original.
    private func undoAutoConvert(_ info: (original: String, backspaceCount: Int, undoToRussian: Bool, triggerWord: String)) {
        // Self-learning: add the trigger word to exceptions so it
        // won't be auto-converted again (Caramba-style: undo = exception).
        if autoLearnExceptions {
            learnException(info.triggerWord)
        }

        guard LayoutSwitch.select(toRussian: info.undoToRussian) else {
            log("undo: no target layout — skipping")
            busy = false
            return
        }
        isReplacing = true
        typedBuffer = ""

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.layoutSwitchDelay) { [weak self] in
            guard let self else { return }
            KeyEvents.backspace(count: info.backspaceCount) { [weak self] in
                guard let self else { return }
                KeyEvents.type(info.original, toRussian: info.undoToRussian) { [weak self] in
                    guard let self else { return }
                    self.isReplacing = false
                    self.busy = false
                    self.replayPendingKeystrokes()
                }
            }
        }
    }

    /// Parses the typing buffer into a list of (word, gap) segments.
    /// Delegates to AutoSwitcher for the pure logic (also used by tests).
    private func parseBufferSegments() -> [(word: String, gap: String)] {
        AutoSwitcher.parseBufferSegments(typedBuffer)
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
        log("switch: buffer «\(redact(typedBuffer))»")

        // Password field — do not touch at all.
        if secureField {
            log("switch: secure field — skipping")
            busy = false
            return
        }

        // Undo auto-convert: highest priority — double-Shift right after
        // auto-convert reverts to the original text and layout.
        if let info = lastAutoConvertInfo {
            log("undo: reverting auto-convert")
            lastAutoConvertInfo = nil
            undoAutoConvert(info)
            return
        }

        // 1) Selection → always use clipboard (Cmd+C/V), even if buffer is not empty.
        //    User explicitly selected text — clipboard conversion is preferred.
        if let selected = Accessibility.selectedText(), !selected.isEmpty {
            convertSelectionViaClipboard()
            return
        }

        // 2) Toggle: undo last clipboard conversion (Cmd+Z).
        //    Only when there's no selection and no new typing.
        if lastWasSelectionConvert, typedBuffer.isEmpty {
            log("toggle: undoing the last conversion (Cmd+Z)")
            lastWasSelectionConvert = false
            KeyEvents.undo()
            busy = false
            return
        }

        // 3) Buffer has text → retype conversion (backspace + type).
        if !typedBuffer.isEmpty {
            convertTypedText()
            return
        }

        // 4) No selection, no buffer → try clipboard (might find selection via Cmd+C).
        //    If nothing to convert — toggles the layout.
        convertSelectionViaClipboard()
    }

    /// Converts the selected text via the clipboard:
    /// Cmd+C → read the buffer → convert → Cmd+V (replaces the selection).
    /// If there is no selection or nothing to convert — toggles the layout.
    private func convertSelectionViaClipboard() {
        guard !isReplacing else { busy = false; return }
        isReplacing = true

        let pasteboard = NSPasteboard.general
        let beforeChange = pasteboard.changeCount
        let saved = Clipboard.snapshot()

        KeyEvents.copySelection()

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.clipboardWait) { [weak self] in
            guard let self else { return }
            guard pasteboard.changeCount != beforeChange,
                  let text = pasteboard.string(forType: .string),
                  !text.isEmpty,
                  let result = Translit.convert(text),
                  result.converted != text else {
                // No selection or nothing to convert — just toggle the layout.
                self.log("selection(copy): nothing to copy/convert → toggle")
                self.typedBuffer = ""  // Clear stale buffer before toggle
                Clipboard.restore(saved)
                self.isReplacing = false
                self.busy = false
                LayoutSwitch.toggle()
                self.replayPendingKeystrokes()
                return
            }
            self.log("selection(copy): «\(self.redact(text))» → «\(self.redact(result.converted))»")

            // Self-learning: if this selection conversion reverses any recent
            // auto-convert (user selected the auto-converted text and double-Shifts
            // it back), add the trigger word to exceptions — same as undoAutoConvert.
            if self.autoLearnExceptions, !self.recentAutoConvertedWords.isEmpty {
                let selText = text.trimmingCharacters(in: .whitespaces)
                let convText = result.converted.trimmingCharacters(in: .whitespaces)
                // Search all recent auto-converted pairs — a later auto-convert
                // shouldn't prevent learning from an earlier one.
                var learned: [(original: String, converted: String)] = []
                self.recentAutoConvertedWords.removeAll { autoWord in
                    let matched = selText == autoWord.converted || selText == autoWord.original
                        || convText == autoWord.original || convText == autoWord.converted
                    if matched { learned.append(autoWord) }
                    return matched
                }
                for word in learned {
                    self.learnException(word.original)
                }
            }

            self.lastWasSelectionConvert = true
            LayoutSwitch.select(toRussian: result.direction == .toCyrillic)
            Clipboard.copy(result.converted)
            KeyEvents.paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.clipboardRestore) {
                Clipboard.restore(saved)
                self.typedBuffer = ""  // Clear stale buffer after clipboard conversion
                self.isReplacing = false
                self.busy = false
                self.replayPendingKeystrokes()
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
            busy = false
            return
        }
        let chunk = ns.substring(with: NSRange(location: start, length: caret - start))
        guard !chunk.isEmpty,
              let result = Translit.convert(chunk),
              result.converted != chunk else {
            log("convert: «\(chunk)» cannot be converted → toggle")
            LayoutSwitch.toggle()
            busy = false
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
        guard !isReplacing else { busy = false; return }
        guard LayoutSwitch.select(toRussian: toRussian) else {
            log("replaceByDeleting: no target layout — leaving text as is")
            busy = false
            return
        }
        isReplacing = true
        KeyEvents.backspace(count: deleteCount) { [weak self] in
            guard let self else { return }
            self.log("deleted \(deleteCount), typing «\(text)»")
            KeyEvents.type(text, toRussian: toRussian) { [weak self] in
                guard let self else { return }
                self.isReplacing = false
                self.busy = false
                // Replace buffer with converted text → second double-Shift
                // converts back (toggle) instead of repeating the same conversion.
                self.typedBuffer = text
                self.lastWasSelectionConvert = false
                self.replayPendingKeystrokes()
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
