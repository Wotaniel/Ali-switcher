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

/// Build number (git commit count — always increases with each commit).
let kBuildNumber: String = {
    if let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !b.isEmpty {
        return b
    }
    return "?"
}()

/// Git short hash of the commit this build was made from (for identification).
let kGitHash: String = {
    if let h = Bundle.main.object(forInfoDictionaryKey: "GitHash") as? String, !h.isEmpty {
        return h
    }
    return "dev"
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

/// Computes an adaptive isReplacing timeout based on the conversion size.
/// Small conversions use the 1.5s minimum. Large conversions (many
/// backspaces + long text) get proportional headroom.
/// Formula: max(1.5s, expectedDuration + 0.5s margin)
/// where expectedDuration = backspaces * backspaceDelay + chars * typeDelay + layoutSwitchDelay
func computeIsReplacingTimeout(deleteCount: Int, textLength: Int) -> CFTimeInterval {
    let expected = Double(deleteCount) * Timing.backspaceDelay
                 + Double(textLength) * Timing.typeDelay
                 + Timing.layoutSwitchDelay
    return max(SwitcherState.minIsReplacingTimeout, expected + 0.5)
}

// MARK: - Global state

var currentTap: CFMachPort?

// MARK: - Global helpers (used by Switcher and UIManager)

/// Shortens text in the log (privacy: do not write full content).
func redact(_ s: String, limit: Int = 24) -> String {
    guard s.count > limit else { return s }
    return s.prefix(limit) + "…"
}

// MARK: - Word list persistence

/// Loads two word lists from UserDefaults. Migrates old formats.
func loadLearnedWords() {
    // New format: two separate arrays.
    if let en = UserDefaults.standard.array(forKey: "enWords") as? [String] {
        AutoSwitcher.enWords = Set(en.map { $0.lowercased() })
    }
    if let ru = UserDefaults.standard.array(forKey: "ruWords") as? [String] {
        AutoSwitcher.ruWords = Set(ru.map { $0.lowercased() })
    }

    // Migrate old "learnedWords" format (formA\tformB\texc/dict).
    if let oldArr = UserDefaults.standard.array(forKey: "learnedWords") as? [String]
        ?? UserDefaults.standard.array(forKey: "learnedPairs") as? [String] {
        for line in oldArr {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 1 else { continue }
            let word = parts[0]
            if !word.isEmpty {
                AutoSwitcher.addException(word)
            }
        }
        UserDefaults.standard.removeObject(forKey: "learnedWords")
        UserDefaults.standard.removeObject(forKey: "learnedPairs")
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
func saveLearnedWords() {
    UserDefaults.standard.set(Array(AutoSwitcher.enWords), forKey: "enWords")
    UserDefaults.standard.set(Array(AutoSwitcher.ruWords), forKey: "ruWords")
}

/// Adds a word to the appropriate exception list (auto-learn on undo).
func learnException(_ word: String) {
    AutoSwitcher.addException(word)
    saveLearnedWords()
    log("exception: «\(redact(word))» (EN: \(AutoSwitcher.enWords.count), RU: \(AutoSwitcher.ruWords.count))")
}

// MARK: - Main class

/// Coordinates the event tap, double-Shift detection, and all conversion
/// flows (manual switch, auto-convert, undo). UI is delegated to `UIManager`,
/// shared mutable state lives in `SwitcherState`.
final class Switcher {

    private let state = SwitcherState()
    private lazy var ui = UIManager(state: state)

    func start() {
        let app = NSApplication.shared
        // Background app: no Dock icon; it appears only while the
        // permissions panel is open (see UIManager.showPermissionsGuide).
        app.setActivationPolicy(.accessory)
        state.autoModeEnabled = UserDefaults.standard.bool(forKey: "autoModeEnabled")
        // Auto-learn defaults to true (enabled on first launch).
        state.autoLearnExceptions = UserDefaults.standard.object(forKey: "autoLearnExceptions") as? Bool ?? true
        // Load user word lists (two independent lists: EN and RU).
        loadLearnedWords()
        ui.setupMainMenu()
        ui.setupStatusItem()
        ui.updateStatusIcon()
        ui.updatePermissionStatus()
        // The icon follows the layout (also when the user switches it manually).
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.ui.updateStatusIcon()
        }

        // 1. Silent permission check (no system dialogs — our own panel
        //    explains everything, see UIManager.showPermissionsGuide).
        Permissions.requestIfNeeded()

        // 2. Event tap with retries: the app stays alive and waits for permissions.
        startEventTap()

        // 3. If permissions are missing — show the guide window.
        if !Permissions.allGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.ui.showPermissionsGuide()
            }
        }

        // 4. On first launch — ask about Launch at Login.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.ui.showAutostartPromptIfNeeded()
        }

        print("▶  AliSwitcher is running. Double-Shift = convert text + switch layout.")
        print("   Menu bar icon: «RU» → click → Quit.")
        app.run()
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
            let ax = Permissions.accessibilityGranted
            let listen = Permissions.inputMonitoringGranted
            log(.warn, "Event tap not created: Accessibility=\(ax), InputMonitoring=\(listen)")
            state.tapActive = false
            ui.updatePermissionStatus()
            ui.setToolTip("AliSwitcher: waiting for permissions (AX=\(ax), Listen=\(listen))")
            ui.updateStatusIcon()
            ui.setStatusStateTitle("AliSwitcher: waiting for permissions (AX=\(ax), Listen=\(listen)) — System Settings → Privacy & Security")
            state.tapRetryTimer?.invalidate()
            state.tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.startEventTap()
            }
            return
        }

        state.tapRetryTimer?.invalidate()
        state.tapRetryTimer = nil
        currentTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("✔  Event tap active — permissions granted, waiting for double-Shift")
        state.tapActive = true
        ui.updatePermissionStatus()
        ui.setToolTip("AliSwitcher: working (double-Shift)")
        ui.updateStatusIcon()
        ui.setStatusStateTitle("AliSwitcher — double-Shift works")
        print("✔  Event tap active.")
    }

    // MARK: - Event handling

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        // Safety: force-reset isReplacing if stuck for too long.
        // This prevents the keyboard from being permanently blocked.
        if state.isReplacing {
            let now = CFAbsoluteTimeGetCurrent()
            if now - state.isReplacingSince > state.isReplacingTimeout {
                log(.warn, "isReplacing stuck for \(Int(now - state.isReplacingSince))s — force reset")
                state.isReplacing = false
                state.busy = false
                state.pendingCharacters = ""
                state.pendingBackspaces = 0
                state.generation &+= 1  // BUG #4 fix: invalidate in-flight callbacks
            }
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = currentTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        switch type {
        case .keyDown:
            // Any key press resets the double-Shift counter
            state.lastShiftPress = 0
            // During replacement (backspace + retype), swallow real keystrokes
            // and buffer them — they'd land in wrong positions during backspacing.
            // Replayed after replacement completes.
            if state.isReplacing, !isSynthetic(event) {
                if let layout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
                    let action = KeyTracker.action(for: event, currentLayout: layout)
                    switch action {
                    case .text(let s):
                        state.pendingCharacters.append(s)
                        return nil  // swallow printable chars — replayed after
                    case .deleteBackward:
                        if !state.pendingCharacters.isEmpty {
                            state.pendingCharacters.removeLast()
                        } else {
                            // Queue the backspace instead of losing it.
                            // It will be replayed after the conversion completes.
                            state.pendingBackspaces += 1
                            log(.warn, "backspace queued during isReplacing (total: " + String(state.pendingBackspaces) + ")")
                        }
                        return nil  // swallow backspace — replayed after
                    case .reset:
                        // Enter, Tab, arrows, Home/End — let them through.
                        // Blocking navigation keys makes the keyboard feel dead.
                        state.pendingCharacters = ""
                        state.pendingBackspaces = 0
                        state.generation &+= 1  // BUG #5 fix: invalidate stale completion
                    case .ignore:
                        // Escape, function keys, Cmd combos — let them through.
                        // These don't affect the text buffer position.
                        break
                    }
                }
                // .reset and .ignore pass through to the app.
            }
            // Selection toggle reset — only on real user keystrokes.
            // Our own synthetic Cmd+C/Cmd+V/Cmd+Z (privateState) don't count.
            if state.lastWasSelectionConvert, !isSynthetic(event) {
                state.lastWasSelectionConvert = false
            }
            // Real keystrokes cancel the auto-convert undo window.
            if state.lastAutoConvertInfo != nil, !isSynthetic(event) {
                state.lastAutoConvertInfo = nil
            }
            // Auto mode: on word-boundary characters (space, period, etc.)
            // check the preceding word and auto-convert if needed.
            // IMPORTANT: we block the original boundary character (return nil)
            // and re-type it after conversion — otherwise backspace erases
            // the wrong characters (space is already printed after the word).
            // Cache KeyTracker.action to avoid calling it twice per keystroke.
            if state.autoModeEnabled, !state.busy, !state.isReplacing, !state.secureField, !isSynthetic(event), !ui.anyEditorVisible {
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
            state.typedBuffer = ""
            state.secureField = false
            state.lastWasSelectionConvert = false
            state.lastAutoConvertInfo = nil
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
            if state.lastShiftPress != 0,
               now - state.lastShiftPress < kDoubleShiftInterval,
               state.lastShiftRelease > state.lastShiftPress {
                // Double-Shift — eat the second press and trigger conversion.
                state.lastShiftPress = 0
                triggerSwitch()
                return nil
            }
            state.lastShiftPress = now
        } else {
            state.lastShiftRelease = now
        }
        return Unmanaged.passUnretained(event)
    }

    /// Is the event synthetic (ours)? Synthetic events created by us
    /// via CGEventSource have eventSourceUnixProcessID == our PID.
    private func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }

    /// Replays characters and backspaces that were queued during replacement
    /// (isReplacing). Text is typed first (pendingCharacters), then backspaces
    /// are sent (pendingBackspaces). Without this, pressing backspace during a
    /// conversion (~0.3s window) felt like the key was dead — swallowed and lost.
    private func replayPendingKeystrokes() {
        let text = state.pendingCharacters
        state.pendingCharacters = ""
        let backspaces = state.pendingBackspaces
        state.pendingBackspaces = 0

        guard !text.isEmpty || backspaces > 0 else { return }

        if !text.isEmpty {
            log(.debug, "replay: " + redact(text) + " (" + String(text.count) + " chars), " + String(backspaces) + " backspace(s)")
            let toRussian = Translit.isCyrillic(text.first!)
            KeyEvents.replay(text, toRussian: toRussian) { [weak self] in
                // Track in buffer so future auto-convert / manual switch sees them
                self?.trackTypedAction(.text(text))
                if backspaces > 0 {
                    KeyEvents.backspace(count: backspaces) { }
                }
            }
        } else {
            log(.debug, "replay: " + String(backspaces) + " backspace(s)")
            KeyEvents.backspace(count: backspaces) { }
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
            if state.typedBuffer.isEmpty, !state.secureField {
                state.secureField = isFocusedFieldSecure()
            }
            guard !state.secureField else { return }
            // Buffer pollution fix: if typedBuffer has converted text from a
            // previous conversion (for toggle-back), clear it before appending
            // new text — the user is typing a NEW fragment, not continuing
            // the converted one.
            if state.typedBufferIsFromConversion {
                state.typedBuffer = ""
                state.typedBufferIsFromConversion = false
            }
            state.typedBuffer.append(s)
            if state.typedBuffer.count > kMaxBufferLength {
                state.typedBuffer.removeFirst(state.typedBuffer.count - kMaxBufferLength)
            }
        case .deleteBackward:
            if state.secureField { return }
            // Buffer pollution fix: if buffer is from conversion, backspace
            // modifies the real field — buffer is now stale. Clear it.
            if state.typedBufferIsFromConversion {
                state.typedBuffer = ""
                state.typedBufferIsFromConversion = false
            } else if !state.typedBuffer.isEmpty {
                state.typedBuffer.removeLast()
            }
        case .reset:
            state.typedBuffer = ""
            state.typedBufferIsFromConversion = false
            state.secureField = false
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
        guard !state.busy, !state.isReplacing else { return false }

        // Delegate to the pure function (shared with tests).
        // This ensures the real code path and test code path are identical.
        guard let decision = AutoSwitcher.evaluateAutoConvert(
            buffer: state.typedBuffer, boundaryChar: boundaryChar
        ) else {
            return false
        }

        let toRussian = decision.direction == .toCyrillic
        let fullConvertedText = decision.convertedText + boundaryChar
        log("auto: buffer=«\(redact(state.typedBuffer))» → «\(redact(decision.convertedText))»+\(boundaryChar) (dir=\(toRussian ? "EN→RU" : "RU→EN"), \(decision.wordCount) words, del \(decision.deleteCount))")

        state.busy = true
        state.isReplacingTimeout = computeIsReplacingTimeout(
            deleteCount: decision.deleteCount, textLength: fullConvertedText.count)
        state.isReplacing = true; state.isReplacingSince = CFAbsoluteTimeGetCurrent()
        let gen = state.generation  // BUG #4/#5: capture for async callback validation
        guard LayoutSwitch.select(toRussian: toRussian) else {
            log(.warn, "auto: no target layout — skipping")
            state.busy = false
            state.isReplacing = false
            return false
        }
        state.typedBuffer = ""

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.autoConvertDelay) { [weak self] in
            guard let self else { return }
            KeyEvents.backspace(count: decision.deleteCount) { [weak self] in
                guard let self else { return }
                KeyEvents.type(fullConvertedText, toRussian: toRussian) { [weak self] in
                    guard let self else { return }
                    self.state.isReplacing = false
                    self.state.busy = false
                    guard self.state.generation == gen else { return }  // stale — skip state write
                    self.replayPendingKeystrokes()
                    // Store undo info: double-Shift reverts this conversion.
                    self.state.lastAutoConvertInfo = (
                        original: decision.originalText + boundaryChar,
                        backspaceCount: fullConvertedText.count,
                        undoToRussian: !toRussian,
                        triggerWord: decision.triggerWord
                    )
                    // Also remember the word pair for delayed exception learning
                    // (survives real keystrokes, used by clipboard undo).
                    // Keep a list — a later auto-convert shouldn't erase an
                    // earlier pair the user might still undo.
                    self.state.recentAutoConvertedWords.append((original: decision.triggerWord, converted: decision.convertedText))
                    if self.state.recentAutoConvertedWords.count > self.state.maxRecentAutoWords {
                        self.state.recentAutoConvertedWords.removeFirst()
                    }
                }
            }
        }
        return true
    }

    /// Reverts the last auto-conversion: switches back to the original layout,
    /// backspaces the converted text, and retypes the original.
    private func undoAutoConvert(_ info: (original: String, backspaceCount: Int, undoToRussian: Bool, triggerWord: String)) {
        guard LayoutSwitch.select(toRussian: info.undoToRussian) else {
            log(.warn, "undo: no target layout — skipping")
            state.busy = false
            return
        }
        // Self-learning: add the trigger word to exceptions so it
        // won't be auto-converted again (Caramba-style: undo = exception).
        // BUG #3 fix: AFTER LayoutSwitch guard — if the layout switch fails,
        // the undo didn't happen, so we must NOT learn the exception
        // (would block future auto-converts for a word that wasn't actually undone).
        if state.autoLearnExceptions {
            learnException(info.triggerWord)
        }
        state.isReplacingTimeout = computeIsReplacingTimeout(
            deleteCount: info.backspaceCount, textLength: info.original.count)
        state.isReplacing = true; state.isReplacingSince = CFAbsoluteTimeGetCurrent()
        let gen = state.generation  // BUG #4/#5: capture for async callback validation
        state.typedBuffer = ""

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.layoutSwitchDelay) { [weak self] in
            guard let self else { return }
            KeyEvents.backspace(count: info.backspaceCount) { [weak self] in
                guard let self else { return }
                KeyEvents.type(info.original, toRussian: info.undoToRussian) { [weak self] in
                    guard let self else { return }
                    self.state.isReplacing = false
                    self.state.busy = false
                    guard self.state.generation == gen else { return }  // stale — skip state write
                    self.replayPendingKeystrokes()
                }
            }
        }
    }

    /// Parses the typing buffer into a list of (word, gap) segments.
    /// Delegates to AutoSwitcher for the pure logic (also used by tests).
    private func parseBufferSegments() -> [(word: String, gap: String)] {
        AutoSwitcher.parseBufferSegments(state.typedBuffer)
    }

    // MARK: - Conversion

    private func triggerSwitch() {
        guard !state.busy else { return }
        state.busy = true
        DispatchQueue.main.async { [weak self] in
            self?.performSwitch()
        }
    }

    private func performSwitch() {
        log("switch: buffer «\(redact(state.typedBuffer))»")

        // Password field — do not touch at all.
        if state.secureField {
            log(.debug, "switch: secure field — skipping")
            state.busy = false
            return
        }

        // Undo auto-convert: double-Shift right after auto-convert reverts
        // to the original text and layout. BUT if the user has already typed
        // new text after the auto-convert, they want to convert that text,
        // not undo the previous conversion.
        if let info = state.lastAutoConvertInfo {
            let hasNewText = state.typedBuffer.contains { !AutoSwitcher.isBoundary($0) }
            if hasNewText {
                log(.debug, "switch: new text after auto-convert → convert (skip undo)")
                state.lastAutoConvertInfo = nil
                // Fall through to conversion below.
            } else {
                log(.debug, "undo: reverting auto-convert")
                state.lastAutoConvertInfo = nil
                undoAutoConvert(info)
                return
            }
        }

        // 1) Selection → always use clipboard (Cmd+C/V), even if buffer is not empty.
        //    User explicitly selected text — clipboard conversion is preferred.
        if let selected = Accessibility.selectedText(), !selected.isEmpty {
            convertSelectionViaClipboard()
            return
        }

        // 2) Toggle: undo last clipboard conversion (Cmd+Z).
        //    Only when there's no selection and no new typing.
        if state.lastWasSelectionConvert, state.typedBuffer.isEmpty {
            log(.debug, "toggle: undoing the last conversion (Cmd+Z)")
            state.lastWasSelectionConvert = false
            KeyEvents.undo()
            state.busy = false
            return
        }

        // 3) Buffer has text → retype conversion (backspace + type).
        if !state.typedBuffer.isEmpty {
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
        guard !state.isReplacing else { state.busy = false; return }
        state.isReplacingTimeout = SwitcherState.minIsReplacingTimeout  // clipboard: unknown size
        state.isReplacing = true; state.isReplacingSince = CFAbsoluteTimeGetCurrent()
        let gen = state.generation  // BUG #4/#5: capture for async callback validation

        let pasteboard = NSPasteboard.general
        let beforeChange = pasteboard.changeCount
        let saved = Clipboard.snapshot()

        KeyEvents.copySelection()

        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.clipboardWait) { [weak self] in
            guard let self else { return }
            guard self.state.generation == gen else {  // stale — abort + cleanup
                self.state.isReplacing = false
                self.state.busy = false
                return
            }
            guard pasteboard.changeCount != beforeChange,
                  let text = pasteboard.string(forType: .string),
                  !text.isEmpty,
                  let result = Translit.convert(text),
                  result.converted != text else {
                // No selection or nothing to convert — just toggle the layout.
                log(.debug, "selection(copy): nothing to copy/convert → toggle")
                self.state.typedBuffer = ""  // Clear stale buffer before toggle
                Clipboard.restore(saved)
                self.state.isReplacing = false
                self.state.busy = false
                LayoutSwitch.toggle()
                self.replayPendingKeystrokes()
                return
            }
            log(.debug, "selection(copy): «\(redact(text))» → «\(redact(result.converted))»")

            // Self-learning: if this selection conversion reverses any recent
            // auto-convert (user selected the auto-converted text and double-Shifts
            // it back), add the trigger word to exceptions — same as undoAutoConvert.
            if self.state.autoLearnExceptions, !self.state.recentAutoConvertedWords.isEmpty {
                let selText = text.trimmingCharacters(in: .whitespaces)
                let convText = result.converted.trimmingCharacters(in: .whitespaces)
                // Search all recent auto-converted pairs — a later auto-convert
                // shouldn't prevent learning from an earlier one.
                var learned: [(original: String, converted: String)] = []
                self.state.recentAutoConvertedWords.removeAll { autoWord in
                    let matched = selText == autoWord.converted || selText == autoWord.original
                        || convText == autoWord.original || convText == autoWord.converted
                    if matched { learned.append(autoWord) }
                    return matched
                }
                for word in learned {
                    learnException(word.original)
                }
            }

            self.state.lastWasSelectionConvert = true
            LayoutSwitch.select(toRussian: result.direction == .toCyrillic)
            Clipboard.copy(result.converted)
            KeyEvents.paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.clipboardRestore) { [weak self] in
                guard let self else { return }
                Clipboard.restore(saved)
                self.state.isReplacing = false
                self.state.busy = false
                guard self.state.generation == gen else { return }  // stale — skip state write
                self.state.typedBuffer = ""  // Clear stale buffer after clipboard conversion
                self.replayPendingKeystrokes()
            }
        }
    }

    /// Main path: find the "typed in the wrong layout" fragment
    /// (from real field text if Accessibility is available, otherwise from the buffer),
    /// erase it with Backspaces and retype the converted text.
    ///
    /// Uses the unified findConversionRange algorithm (shared with auto-convert):
    /// 1. Last word: ALWAYS convert (no dictionary checks).
    /// 2. Previous words: convert if same script AND not a valid word
    ///    in own language (spell-checker). Stop at valid word or script change.
    /// 3. Word size doesn't matter — single chars convert too.
    private func convertTypedText() {
        let ns: NSString
        if let real = realTextBeforeCaret(), !real.isEmpty {
            ns = real as NSString
            log(.debug, "convert: using real field text (\(ns.length) chars)")
        } else {
            ns = state.typedBuffer as NSString
            log(.debug, "convert: using typing buffer (\(ns.length) chars)")
        }

        let caret = ns.length
        let start = ChunkFinder.chunkStart(in: ns, before: caret)
        guard start < caret else {
            log(.debug, "convert: empty fragment → toggle")
            LayoutSwitch.toggle()
            state.busy = false
            return
        }
        let chunk = ns.substring(with: NSRange(location: start, length: caret - start))
        guard !chunk.isEmpty else {
            log(.debug, "convert: empty chunk → toggle")
            LayoutSwitch.toggle()
            state.busy = false
            return
        }

        // Unified algorithm: determine what to convert (shared with auto-convert).
        guard let plan = AutoSwitcher.findConversionRange(in: chunk, isManual: true) else {
            log(.debug, "convert: «\(redact(chunk))» last word cannot be converted → toggle")
            LayoutSwitch.toggle()
            state.busy = false
            return
        }

        // Type ONLY the converted portion (+ trailing gap). The prefix stays
        // in the field (it was not erased). This avoids duplicating the prefix.
        let toRussian = plan.direction == .toCyrillic
        let fullText = plan.convertedText + plan.lastGap
        let deleteCount = plan.deleteCount + plan.lastGap.count
        log(.debug, "convert: chunk=«\(redact(chunk))» prefix=«\(redact(plan.prefix))» orig=«\(redact(plan.originalText))» → conv=«\(redact(plan.convertedText))»+gap full=«\(redact(fullText))» (dir=\(toRussian ? "EN→RU" : "RU→EN"), \(plan.wordCount) words, del \(deleteCount))")

        // BUG #2 fix: universal typeability pre-check.
        if KeyEvents.isFullyTypeable(fullText, toRussian: toRussian) {
            replaceByDeleting(fullText,
                              deleteCount: deleteCount,
                              toRussian: toRussian)
        } else {
            log(.debug, "convert: non-typeable chars → clipboard paste")
            replaceByClipboard(fullText, deleteCount: deleteCount)
        }
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
        guard !state.isReplacing else { state.busy = false; return }
        guard LayoutSwitch.select(toRussian: toRussian) else {
            log(.warn, "replaceByDeleting: no target layout — leaving text as is")
            state.busy = false
            return
        }
        state.isReplacingTimeout = computeIsReplacingTimeout(
            deleteCount: deleteCount, textLength: text.count)
        state.isReplacing = true; state.isReplacingSince = CFAbsoluteTimeGetCurrent()
        let gen = state.generation  // BUG #4/#5: capture for async callback validation
        KeyEvents.backspace(count: deleteCount) { [weak self] in
            guard let self else { return }
            log("deleted \(deleteCount), typing «\(text)»")
            KeyEvents.type(text, toRussian: toRussian) { [weak self] in
                guard let self else { return }
                self.state.isReplacing = false
                self.state.busy = false
                guard self.state.generation == gen else { return }  // stale — skip state write
                // Replace buffer with converted text → second double-Shift
                // converts back (toggle) instead of repeating the same conversion.
                self.state.typedBuffer = text
                self.state.typedBufferIsFromConversion = true
                self.state.lastWasSelectionConvert = false
                self.replayPendingKeystrokes()
            }
        }
    }

    /// Erases deleteCount chars via Backspace, then pastes text via clipboard.
    /// Used when the converted text has mixed scripts (Cyrillic + Latin)
    /// and can't be typed in a single layout.
    private func replaceByClipboard(_ text: String, deleteCount: Int) {
        guard !state.isReplacing else { state.busy = false; return }
        state.isReplacingTimeout = computeIsReplacingTimeout(
            deleteCount: deleteCount, textLength: text.count)
        state.isReplacing = true; state.isReplacingSince = CFAbsoluteTimeGetCurrent()
        let gen = state.generation  // BUG #4/#5: capture for async callback validation
        let saved = Clipboard.snapshot()
        KeyEvents.backspace(count: deleteCount) { [weak self] in
            guard let self else { return }
            log("deleted \(deleteCount), pasting «\(text)» via clipboard")
            Clipboard.copy(text)
            KeyEvents.paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + Timing.clipboardRestore) { [weak self] in
                guard let self else { return }
                Clipboard.restore(saved)
                self.state.isReplacing = false
                self.state.busy = false
                guard self.state.generation == gen else { return }  // stale — skip state write
                self.state.typedBuffer = text
                self.state.typedBufferIsFromConversion = true
                self.state.lastWasSelectionConvert = false
                self.replayPendingKeystrokes()
            }
        }
    }

}

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
