import Cocoa

/// Снимок буфера обмена: хранит ДАННЫЕ (тип → Data), а не ссылки на NSPasteboardItem.
/// Ссылки инвалидируются вызовом clearContents(), и запись их обратно
/// падает с исключением в -[NSPasteboard writeObjects:] (SIGABRT).
struct ClipboardSnapshot {
    /// Каждый элемент буфера — список «тип → данные».
    let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
}

enum Clipboard {

    static func snapshot() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return nil }

        var items: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
        for item in pasteboardItems {
            var entries: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append((type, data))
                }
            }
            if !entries.isEmpty { items.append(entries) }
        }
        return items.isEmpty ? nil : ClipboardSnapshot(items: items)
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func restore(_ snapshot: ClipboardSnapshot?) {
        guard let snapshot else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var items: [NSPasteboardItem] = []
        for entries in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: type)
            }
            items.append(item)
        }
        pasteboard.writeObjects(items)
    }
}
