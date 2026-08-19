import Cocoa
import Carbon.HIToolbox

// MARK: - Конфигурация

/// Максимальная пауза между двумя нажатиями Shift, которая считается «двойным шифтом» (сек).
let kDoubleShiftInterval: TimeInterval = 0.25
/// Предел длины буфера набора (защита от неограниченного роста).
let kMaxBufferLength = 500

let kLeftShiftKeyCode: CGKeyCode = 56   // kVK_Shift
let kRightShiftKeyCode: CGKeyCode = 60  // kVK_RightShift

// MARK: - Иконка в строке меню

enum StatusIcon {
    /// enabled=false — приглушённая версия (права не выданы).
    static func make(enabled: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        let color = enabled ? NSColor.labelColor : NSColor.labelColor.withAlphaComponent(0.35)
        let text = NSAttributedString(string: "RU", attributes: [
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

    /// Защищённое поле (пароль) в фокусе: не слушаем и не конвертируем.
    private var secureField = false

    /// Буфер набора: запоминаем, что пользователь напечатал (как Punto/Caramba).
    /// Это позволяет стереть текст Backspace'ами и напечатать конвертированный
    /// в ЛЮБОМ приложении (включая VS Code, Slack) — без Accessibility.
    private var typedBuffer = ""

    private var statusStateItem: NSMenuItem?
    private var tapRetryTimer: Timer?

    func start() {
        let app = NSApplication.shared
        // Фоновое приложение: Dock-иконки нет; она появляется только пока
        // открыт диалог прав (см. showPermissionsGuide).
        app.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()

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
        item.button?.image = StatusIcon.make(enabled: false)
        let menu = NSMenu()

        let state = NSMenuItem(title: "AliSwitcher: жду права…", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
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

    @objc private func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    /// Окно-инструкция: какие права нужны и где их выдать.
    /// Пока диалог открыт — приложение видно в Dock (можно вернуть ему фокус).
    @objc private func showPermissionsGuide() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }

        let alert = NSAlert()
        alert.messageText = "AliSwitcher: нужны разрешения"
        alert.informativeText = """
        Разрешения выдаются в Системных настройках → Конфиденциальность и безопасность.

        ОБЯЗАТЕЛЬНО:
        • «Наблюдение за вводом» (Input Monitoring)
          — слежение за нажатиями клавиш: двойной Shift и запоминание набранного.
          Без него приложение не работает.

        ЖЕЛАТЕЛЬНО (для дополнительных возможностей):
        • «Специальные возможности» (Accessibility)
          — конвертация выделенного текста, защита полей паролей, точный фрагмент по тексту поля.

        Кнопки ниже откроют нужные разделы.
        """
        alert.addButton(withTitle: "Наблюдение за вводом…")
        alert.addButton(withTitle: "Специальные возможности…")
        alert.addButton(withTitle: "Позже")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            openPrivacyPane("Privacy_ListenEvent")
        case .alertSecondButtonReturn:
            openPrivacyPane("Privacy_Accessibility")
        default:
            break
        }
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
            statusItem?.button?.toolTip = "AliSwitcher: жду права (AX=\(ax), Listen=\(listen))"
            statusItem?.button?.image = StatusIcon.make(enabled: false)
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
        statusItem?.button?.toolTip = "AliSwitcher: работает (двойной Shift)"
        statusItem?.button?.image = StatusIcon.make(enabled: true)
        statusStateItem?.title = "AliSwitcher — двойной Shift работает"
        print("✔  Event tap активен.")
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

// MARK: - Запуск

if CommandLine.arguments.contains("--test") {
    runSelfTests()
    exit(0)
}

if CommandLine.arguments.contains("--layouts") {
    LayoutSwitch.debugPrint()
    exit(0)
}

print("AliSwitcher — переключатель раскладки по двойному Shift (RU ↔ EN)")
print("================================================================")
Switcher().start()

// MARK: - Самопроверка (--test)

func runSelfTests() {
    func chunk(of text: String, caret: Int) -> String {
        let ns = text as NSString
        let start = ChunkFinder.chunkStart(in: ns, before: caret)
        return ns.substring(with: NSRange(location: start, length: caret - start))
    }

    print("— Проверка выделения фрагмента —")

    let example = "я начал писать что-то, случайно переключил раскладку b yfgbcfk ytcrjkmrj ckjd yf lheujq hfcrkflrt^ ye;yj xnj,s dsltkbkjcm dct yfgbcfyyjt b"
    let exChunk = chunk(of: example, caret: (example as NSString).length)
    print("1. Фрагмент:      «\(exChunk)»")
    if let r = Translit.convert(exChunk) {
        print("   Конвертация:  «\(r.converted)»")
        print("   Раскладка:    \(r.direction == .toCyrillic ? "RU" : "EN")")
    } else {
        print("   Конвертация:  нет букв → no-op")
    }

    let single = "привет ghbdtn"
    let sChunk = chunk(of: single, caret: (single as NSString).length)
    print("2. «привет ghbdtn» → фрагмент «\(sChunk)» → «\(Translit.convert(sChunk)?.converted ?? "nil")»")

    let whole = "Привет мир"
    let wChunk = chunk(of: whole, caret: (whole as NSString).length)
    print("3. «Привет мир»   → фрагмент «\(wChunk)» → «\(Translit.convert(wChunk)?.converted ?? "nil")»")

    print("")
    print("— Проверка печати клавишами (карта QWERTY) —")
    let ru = "и написал несколько слов"
    var ruOK = true
    for ch in ru where ch.isLetter {
        if let en = Translit.enOnSameKey(ch), KeyEvents.canType(en) {
            // ok
        } else {
            ruOK = false
            print("   нет клавиши для «\(ch)»")
        }
    }
    print("   Русский текст «\(ru)»: \(ruOK ? "все буквы печатаемы" : "есть проблемы")")

    print("")
    print("— Проверка AXValue (диапазон выделения) —")
    var r1 = CFRange(location: 5, length: 3)
    if let v = AXValueCreate(.cfRange, &r1) {
        var back = CFRange()
        let ok = AXValueGetValue(v, .cfRange, &back)
        print("   cfRange roundtrip: \(ok ? "OK" : "FAIL") → (\(back.location), \(back.length))")
    } else {
        print("   cfRange create: FAIL")
    }
}
