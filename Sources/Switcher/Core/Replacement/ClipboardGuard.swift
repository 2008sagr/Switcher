import AppKit
import Foundation

/// Сохраняет и восстанавливает содержимое буфера обмена вокруг вставки.
///
/// Отличия от прежней реализации: снимаются ВСЕ типы данных, а не только
/// строка, и восстановление происходит только если после нашей записи в
/// буфер никто больше не писал.
///
/// Не потокобезопасен: `snapshot` и `changeCountAfterWrite` — изменяемое
/// состояние без синхронизации. Экземпляр создаётся и используется из одной
/// конкретной очереди (в проекте — очередь фоновой замены текста); вызывать
/// его методы параллельно из разных очередей запрещено.
public final class ClipboardGuard {

    private let pasteboard: NSPasteboard

    /// nil — снимок ещё не снят или уже восстановлен. Отличие от пустого
    /// массива важно: пустой снимок — легитимное состояние («буфер был
    /// пуст»), а nil — сигнал «write() ещё не вызывался с прошлого restore()»,
    /// который используется, чтобы повторный write() не затёр исходный снимок.
    private var snapshot: [[NSPasteboard.PasteboardType: Data]]?
    private var changeCountAfterWrite: Int?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Записывает `text` в буфер, предварительно сохранив его содержимое.
    ///
    /// Повторный вызов write() без промежуточного restore() НЕ пересохраняет
    /// снимок: иначе второй снимок зафиксировал бы уже то, что записал первый
    /// write(), а не подлинное содержимое пользователя, и restore() вернул бы
    /// буфер не к исходному состоянию, а к состоянию «после первой записи» —
    /// данные пользователя потерялись бы безвозвратно и молча.
    @discardableResult
    public func write(_ text: String) -> Bool {
        if snapshot == nil {
            snapshot = (pasteboard.pasteboardItems ?? []).map { item in
                var copy: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { copy[type] = data }
                }
                return copy
            }
        }

        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        changeCountAfterWrite = pasteboard.changeCount
        return ok
    }

    public func restore() {
        guard let expected = changeCountAfterWrite else { return }
        changeCountAfterWrite = nil
        let saved = snapshot ?? []
        snapshot = nil

        // Между нашей записью и восстановлением кто-то ещё писал в буфер —
        // его данные важнее нашего восстановления.
        guard pasteboard.changeCount == expected else { return }

        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
