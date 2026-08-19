import Cocoa
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Конфигурация

/// Максимальная пауза между двумя нажатиями Shift, которая считается «двойным шифтом» (сек).
let kDoubleShiftInterval: TimeInterval = 0.25
/// Предел длины буфера набора (защита от неограниченного роста).
let kMaxBufferLength = 500

let kLeftShiftKeyCode: CGKeyCode = 56   // kVK_Shift
let kRightShiftKeyCode: CGKeyCode = 60  // kVK_RightShift

// MARK: - Иконка в строке меню

enum StatusIcon {
    /// label — «RU» или «EN» (текущая раскладка); enabled=false — приглушённая версия (прав нет).
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

// MARK: - Главный класс

final class Switcher: NSObject {

    private var lastShiftPress: CFTimeInterval = 0
    private var lastShiftRelease: CFTimeInterval = 0
    private var busy = false
    private var isReplacing = false
    private var tapActive = false

    /// Защищённое поле (пароль) в фокусе: не слушаем и не конвертируем.
    private var secureField = false

    /// Буфер набора: запоминаем, что пользователь напечатал (как Punto/Caramba).
    /// Это позволяет стереть текст Backspace'ами и напечатать конвертированный
    /// в ЛЮБОМ приложении (включая VS Code, Slack) — без Accessibility.
    private var typedBuffer = ""

    private var statusStateItem: NSMenuItem?
    private var autostartItem: NSMenuItem?
    private var tapRetryTimer: Timer?

    func start() {
        let app = NSApplication.shared
        // Фоновое приложение: Dock-иконки нет; она появляется только пока
        // открыт диалог прав (см. showPermissionsGuide).
        app.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        updateStatusIcon()
        // Иконка следует за раскладкой (в т.ч. когда пользователь меняет её вручную).
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStatusIcon()
        }

        // 1. Запрашиваем права (система покажет диалоги)
        Accessibility.requestPermissionIfNeeded()
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }

        // 2. Event tap с ретраями: приложение живёт и само ждёт, пока права выдадут.
        startEventTap()

        // 3. Если прав нет — показываем окно-инструкцию.
        if !AXIsProcessTrusted() || !CGPreflightListenEventAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPermissionsGuide()
            }
        }

        // 4. При первом запуске — спрашиваем про автозапуск.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showAutostartPromptIfNeeded()
        }

        print("▶  AliSwitcher работает. Двойной Shift = конвертация фрагмента + смена раскладки.")
        print("   Индикатор в строке меню: «RU» → клик → «Выйти».")
        app.run()
    }

    // MARK: - Меню приложения (в строке меню, когда приложение активно)

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let guide = NSMenuItem(title: "Настроить права…",
                               action: #selector(showPermissionsGuide),
                               keyEquivalent: "")
        guide.target = self
        appMenu.addItem(guide)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Статус-бар

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.make(label: "RU", enabled: false)
        let menu = NSMenu()

        let state = NSMenuItem(title: "AliSwitcher: жду права…", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())

        // Автозапуск при входе (SMAppService)
        let autostart = NSMenuItem(title: "Автозапуск при входе",
                                   action: #selector(toggleAutostart),
                                   keyEquivalent: "")
        autostart.target = self
        autostart.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(autostart)
        autostartItem = autostart
        menu.addItem(.separator())

        // ВАЖНО: у фонового приложения нет first responder, поэтому у каждого
        // пункта с действием должен быть явный target — иначе он будет серым.
        let a11yItem = NSMenuItem(title: "Права: Специальные возможности…",
                                  action: #selector(openAccessibilitySettings),
                                  keyEquivalent: "")
        a11yItem.target = self
        menu.addItem(a11yItem)

        let listenItem = NSMenuItem(title: "Права: Наблюдение за вводом…",
                                    action: #selector(openInputMonitoringSettings),
                                    keyEquivalent: "")
        listenItem.target = self
        menu.addItem(listenItem)

        let guideItem = NSMenuItem(title: "Как настроить права…",
                                   action: #selector(showPermissionsGuide),
                                   keyEquivalent: "")
        guideItem.target = self
        menu.addItem(guideItem)

        let uninstallItem = NSMenuItem(title: "Удалить AliSwitcher…",
                                       action: #selector(uninstallApp),
                                       keyEquivalent: "")
        uninstallItem.target = self
        menu.addItem(uninstallItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Выйти",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
        statusStateItem = state
    }

    @objc private func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// Переключатель «Автозапуск при входе» (SMAppService, macOS 13+).
    @objc private func toggleAutostart() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            do {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    let alert = NSAlert()
                    alert.messageText = "Нужно подтверждение автозапуска"
                    alert.informativeText = "Включите AliSwitcher в Системных настройках → Основные → Элементы входа."
                    alert.addButton(withTitle: "OK")
                    showModal(alert)
                }
            } catch {
                log("autostart register error: \(error)")
            }
        }
        autostartItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    /// При первом запуске спрашиваем, добавить ли приложение в автозапуск.
    private func showAutostartPromptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "didAskAutostart") else { return }
        UserDefaults.standard.set(true, forKey: "didAskAutostart")

        let alert = NSAlert()
        alert.messageText = "Запускать AliSwitcher при входе?"
        alert.informativeText = "Добавить AliSwitcher в автозапуск, чтобы переключатель всегда был готов к работе?"
        alert.addButton(withTitle: "Да")
        alert.addButton(withTitle: "Нет")
        let response = showModal(alert)
        if response == .alertFirstButtonReturn {
            try? SMAppService.mainApp.register()
        }
        autostartItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    /// Показывает модальное окно ПОВЕРХ всего, включая полноэкранные приложения:
    /// окно становится вспомогательным (floating) и видимым на всех Space.
    private func showModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let window = alert.window
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.level = .floating
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return alert.runModal()
    }

    /// Окно-инструкция по правам: не закрывается при нажатии кнопок,
    /// пока пользователь не нажмёт «Готово» (можно открыть оба раздела настроек).
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
        panel.title = "AliSwitcher: нужны разрешения"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))

        let label = NSTextField(wrappingLabelWithString: """
        Разрешения выдаются в Системных настройках → Конфиденциальность и безопасность.

        ОБЯЗАТЕЛЬНО:
        • «Наблюдение за вводом» — слежение за нажатиями (двойной Shift).
        ЖЕЛАТЕЛЬНО:
        • «Специальные возможности» — выделенный текст и защита полей паролей.

        Кнопки ниже открывают нужные разделы — окно при этом останется.
        """)
        label.frame = NSRect(x: 20, y: 130, width: 420, height: 150)
        label.font = NSFont.systemFont(ofSize: 13)
        content.addSubview(label)

        let listenButton = NSButton(title: "Наблюдение за вводом…",
                                    target: self,
                                    action: #selector(openInputMonitoringSettings))
        listenButton.frame = NSRect(x: 20, y: 90, width: 280, height: 28)
        content.addSubview(listenButton)

        let a11yButton = NSButton(title: "Специальные возможности…",
                                  target: self,
                                  action: #selector(openAccessibilitySettings))
        a11yButton.frame = NSRect(x: 20, y: 56, width: 280, height: 28)
        content.addSubview(a11yButton)

        let doneButton = NSButton(title: "Готово",
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

    /// Полное удаление: предупреждение → скрипт uninstall.sh с правами администратора.
    @objc private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "Удалить AliSwitcher?"
        alert.informativeText = """
        Будут удалены:
        • приложение из /Applications;
        • автозапуск (LaunchAgent);
        • запись об установке, логи и временные файлы.

        Действие нельзя отменить. Продолжить?
        """
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        let response = showModal(alert)
        guard response == .alertFirstButtonReturn else { return }

        // Запускаем uninstall.sh с правами администратора (macOS запросит пароль).
        // Путь берём из собственного бандла — приложение может работать откуда угодно.
        let script = Bundle.main.bundlePath + "/Contents/Resources/uninstall.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            let err = NSAlert()
            err.messageText = "Не найден скрипт удаления"
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
            log("⚠  Event tap не создан: Accessibility=\(ax), InputMonitoring=\(listen)")
            tapActive = false
            statusItem?.button?.toolTip = "AliSwitcher: жду права (AX=\(ax), Listen=\(listen))"
            updateStatusIcon()
            statusStateItem?.title = "AliSwitcher: жду права (AX=\(ax), Listen=\(listen)) — Системные настройки → Конфиденциальность"
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
        log("✔  Event tap активен — права есть, жду двойной Shift")
        tapActive = true
        statusItem?.button?.toolTip = "AliSwitcher: работает (двойной Shift)"
        updateStatusIcon()
        statusStateItem?.title = "AliSwitcher — двойной Shift работает"
        print("✔  Event tap активен.")
    }

    /// Иконка в строке меню: «RU»/«EN» по текущей раскладке.
    private func updateStatusIcon() {
        let label = LayoutSwitch.currentIsRussian() ? "RU" : "EN"
        statusItem?.button?.image = StatusIcon.make(label: label, enabled: tapActive)
    }

    // MARK: - Обработка событий

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = currentTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        }

        switch type {
        case .keyDown:
            // Любая клавиша сбрасывает счётчик «двойного шифта»
            lastShiftPress = 0
            // Запоминаем, что напечатано (для Punto-механизма)
            trackTyping(event)
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Клик мышью — набранный фрагмент «потерян» (курсор мог уехать)
            typedBuffer = ""
            secureField = false
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
                // Двойной Shift — съедаем второе нажатие и запускаем конвертацию.
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

    /// Обновляет буфер набора по событию клавиши.
    private func trackTyping(_ event: CGEvent) {
        guard let layout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        switch KeyTracker.action(for: event, currentLayout: layout) {
        case .text(let s):
            // В начале нового фрагмента проверяем, не пароль ли это поле.
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

    // MARK: - Конвертация

    private func triggerSwitch() {
        guard !busy else { return }
        busy = true
        DispatchQueue.main.async { [weak self] in
            self?.performSwitch()
        }
    }

    private func performSwitch() {
        defer { busy = false }
        log("switch: буфер «\(redact(typedBuffer))»")

        // Парольное поле — не трогаем вообще.
        if secureField {
            log("switch: защищённое поле — пропускаю")
            return
        }

        // 1) Если буфер пуст — возможно, пользователь выделил текст:
        //    конвертируем выделение через буфер обмена (Cmd+C → конвертация → Cmd+V).
        //    Работает в любых приложениях, включая VS Code/Slack, без Accessibility.
        if typedBuffer.isEmpty {
            convertSelectionViaClipboard()
            return
        }

        // 2) Основной путь: фрагмент из реального текста (если AX доступен) или из буфера.
        convertTypedText()
    }

    /// Конвертация выделенного текста через буфер обмена:
    /// Cmd+C → читаем буфер → конвертируем → Cmd+V (заменяет выделение).
    /// Если выделения нет — просто переключает раскладку.
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
                // Выделения нет или конвертировать нечего — просто переключаем раскладку.
                self.log("selection(copy): нечего копировать/конвертировать → toggle")
                Clipboard.restore(saved)
                self.isReplacing = false
                LayoutSwitch.toggle()
                return
            }
            self.log("selection(copy): «\(self.redact(text))» → «\(self.redact(result.converted))»")
            LayoutSwitch.select(toRussian: result.direction == .toCyrillic)
            Clipboard.copy(result.converted)
            KeyEvents.paste()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Clipboard.restore(saved)
                self.isReplacing = false
            }
        }
    }

    /// Основной путь: находим фрагмент «набранного не в той раскладке»
    /// (по реальному тексту поля, если Accessibility доступен, иначе по буферу),
    /// стираем его Backspace'ами и печатаем конвертированный текст.
    private func convertTypedText() {
        let ns: NSString
        if let real = realTextBeforeCaret(), !real.isEmpty {
            ns = real as NSString
            log("convert: использую реальный текст поля (\(ns.length) симв.)")
        } else {
            ns = typedBuffer as NSString
            log("convert: использую буфер набора (\(ns.length) симв.)")
        }

        let caret = ns.length
        let start = ChunkFinder.chunkStart(in: ns, before: caret)
        guard start < caret else {
            log("convert: фрагмент пуст → toggle")
            LayoutSwitch.toggle()
            return
        }
        let chunk = ns.substring(with: NSRange(location: start, length: caret - start))
        guard !chunk.isEmpty,
              let result = Translit.convert(chunk),
              result.converted != chunk else {
            log("convert: «\(chunk)» не конвертируется → toggle")
            LayoutSwitch.toggle()
            return
        }
        log("convert: «\(redact(chunk))» → «\(redact(result.converted))»")
        replaceByDeleting(result.converted,
                          deleteCount: chunk.count,
                          toRussian: result.direction == .toCyrillic)
    }

    /// Текст поля до позиции курсора (если Accessibility доступен).
    private func realTextBeforeCaret() -> String? {
        guard let element = Accessibility.focusedElement(),
              let whole = Accessibility.value(element),
              let range = Accessibility.selectedRange(element) else { return nil }
        let ns = whole as NSString
        let caret = Int(range.location) + Int(range.length)
        guard caret > 0, caret <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: 0, length: caret))
    }

    /// Переключаем раскладку, стираем deleteCount символов, печатаем текст.
    private func replaceByDeleting(_ text: String, deleteCount: Int, toRussian: Bool) {
        guard !isReplacing else { return }
        guard LayoutSwitch.select(toRussian: toRussian) else {
            log("replaceByDeleting: нет нужной раскладки — текст не трогаю")
            return
        }
        isReplacing = true
        KeyEvents.backspace(count: deleteCount) { [weak self] in
            guard let self else { return }
            self.log("удалено \(deleteCount), печатаю «\(text)»")
            KeyEvents.type(text, toRussian: toRussian) {
                self.isReplacing = false
            }
        }
    }

    // MARK: - Лог

    /// Укорачивает текст в логе (приватность: не пишем содержимое целиком).
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

// MARK: - Глобальное состояние

var currentTap: CFMachPort?
var statusItem: NSStatusItem?

// MARK: - Синглтон: только один экземпляр приложения

var singletonLockFD: Int32 = -1

/// Захватывает эксклюзивную блокировку (flock). Если другой экземпляр уже
/// запущен (LaunchAgent + ручной запуск, автозапуск + open), второй не сможет
/// получить блокировку и завершится — никаких дубликатов и двойных event tap.
func acquireSingletonLock() -> Bool {
    let lockPath = "/tmp/local.alishch.aliswitcher.lock"
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    singletonLockFD = fd // держим открытым всё время жизни процесса
    return true
}

// MARK: - Запуск

if CommandLine.arguments.contains("--test") {
    exit(SelfTests.run() ? 0 : 1)
}

if CommandLine.arguments.contains("--layouts") {
    LayoutSwitch.debugPrint()
    exit(0)
}

if !acquireSingletonLock() {
    print("AliSwitcher уже запущен — второй экземпляр выходит.")
    exit(0)
}

print("AliSwitcher — переключатель раскладки по двойному Shift (RU ↔ EN)")
print("================================================================")
Switcher().start()
