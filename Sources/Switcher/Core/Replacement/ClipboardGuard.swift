import AppKit
import Foundation

/// Сохраняет и восстанавливает содержимое буфера обмена вокруг вставки.
///
/// Отличия от прежней реализации: снимаются ВСЕ типы данных, а не только
/// строка, и восстановление происходит только если после нашей записи в
/// буфер никто больше не писал.
public final class ClipboardGuard {

    private let pasteboard: NSPasteboard
    private var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
    private var changeCountAfterWrite: Int?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    public func write(_ text: String) -> Bool {
        snapshot = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        changeCountAfterWrite = pasteboard.changeCount
        return ok
    }

    public func restore() {
        guard let expected = changeCountAfterWrite else { return }
        changeCountAfterWrite = nil

        // Между нашей записью и восстановлением кто-то ещё писал в буфер —
        // его данные важнее нашего восстановления.
        guard pasteboard.changeCount == expected else {
            snapshot = []
            return
        }

        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        snapshot = []
    }
}
