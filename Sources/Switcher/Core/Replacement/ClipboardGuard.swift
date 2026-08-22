import AppKit
import Foundation

/// Сохраняет и восстанавливает содержимое буфера обмена вокруг вставки.
///
/// Отличия от прежней реализации: снимаются ВСЕ типы данных, а не только
/// строка, и восстановление происходит только если после нашей записи в
/// буфер никто больше не писал.
///
/// Не потокобезопасен: `snapshot` и `changeCountAfterWrite` — изменяемое
/// состояние без синхронизации. Гарантия, которая реально нужна — не «все
/// вызовы на одной очереди», а «вызовы никогда не идут параллельно друг
/// другу»: write() всегда синхронный и на `work`, а вот restore() может
/// прийти как синхронно оттуда же, так и позже и с другой очереди — через
/// scheduleRestore() (см. ниже), чтобы не блокировать `work` на время
/// ожидания. Это безопасно, потому что на один экземпляр за всё время его
/// жизни приходится ровно одна пара write()/restore(): пока не случился
/// restore(), новый write() тем же экземпляром не запускается (см. apply()
/// в SwitchCoordinator и replaceViaClipboard в TextInjector — оба создают
/// новый ClipboardGuard на каждую замену). Вызывать методы одного и того же
/// экземпляра параллельно из разных очередей всё равно запрещено.
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

    /// Задержка по умолчанию для `scheduleRestore(after:on:)`.
    ///
    /// Это НЕ задержка на пути замены текста (в проекте действует правило
    /// «никаких задержек, подобранных на глаз, на пути замены» — см. историю
    /// коммитов и TextInjector) — восстановление буфера обмена вообще не
    /// часть замены, а уборка ПОСЛЕ неё. К моменту, когда вызывается
    /// scheduleRestore(), Cmd+V уже отправлен в очередь системных событий:
    /// то, что окажется в тексте целевого приложения, уже полностью
    /// определено содержимым буфера на тот момент и от этой задержки не
    /// зависит. Единственный вопрос, который она решает — успеет ли
    /// приложение ПРОЧИТАТЬ буфер до того, как мы вернём в него исходное
    /// содержимое пользователя. Дождаться этого события напрямую нельзя:
    /// NSPasteboard не сообщает о чтении, а опрашивать changeCount
    /// бесполезно — чтение его не меняет (в отличие от Cmd+C, где мы можем
    /// и явно ждём смены changeCount, см. readSelectionViaClipboard в
    /// SwitchCoordinator). Значение — эмпирическое, порядка времени,
    /// которое требуется системе на доставку и обработку синтетического
    /// Cmd+V даже в тяжёлых приложениях; 0.5с даёт большой запас.
    public static let pasteSettleDelay: TimeInterval = 0.5

    /// Восстанавливает буфер асинхронно, спустя `delay`, не блокируя
    /// вызывающую очередь (по умолчанию — на отдельной, не на `work`, чтобы
    /// отложенное восстановление не откладывало обработку следующих слов).
    ///
    /// Замыкание удерживает `self` сильной ссылкой — экземпляр обязан
    /// дожить до момента восстановления, ARC это гарантирует сам, отдельно
    /// хранить `guardian` вызывающей стороне не нужно.
    ///
    /// changeCount по-прежнему сверяется внутри restore() как обычно — если
    /// за время ожидания пользователь сам скопировал что-то новое, отложенное
    /// восстановление его не перетрёт, ровно как и немедленное.
    public func scheduleRestore(after delay: TimeInterval = ClipboardGuard.pasteSettleDelay,
                                 on queue: DispatchQueue = .global(qos: .utility)) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            restore()
        }
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
        if ok {
            changeCountAfterWrite = pasteboard.changeCount
            return true
        }

        // setString() не удалась, а clearContents() выше уже стёр буфер —
        // если ничего не сделать, снимок пользователя (тот, что снят прямо
        // сейчас, либо более ранним write() в этой же паре) теряется
        // безвозвратно: вызывающий код при false просто выходит, не трогая
        // guardian (см. apply() в SwitchCoordinator и replaceViaClipboard в
        // TextInjector). Восстанавливаем снимок немедленно и возвращаем
        // объект в чистое состояние — как будто write() не вызывался вовсе:
        // snapshot и changeCountAfterWrite сбрасываются в nil так же, как
        // после обычного restore(), значит последующий restore() будет
        // no-op, а следующий write() снимет снимок заново. Сбрасывать
        // changeCountAfterWrite обязательно и тогда, когда он остался от
        // более раннего УСПЕШНОГО write() этой же пары (см. тест
        // testClipboardGuardSecondWriteFailureLeavesCleanState) — иначе
        // restore() посчитал бы, что есть что восстанавливать, хотя мы уже
        // сделали это здесь.
        writeBack(snapshot ?? [])
        snapshot = nil
        changeCountAfterWrite = nil
        return false
    }

    /// Записывает сохранённые данные обратно в pasteboard. Общий хвост для
    /// restore() и отката неудачной записи в write().
    private func writeBack(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// `force: true` восстанавливает буфер безусловно, не сверяя changeCount.
    ///
    /// Обычная защита ниже («чужая запись важнее нашего восстановления»)
    /// рассчитана на параллельное действие ПОЛЬЗОВАТЕЛЯ между write() и
    /// restore(). Она неприменима, когда ожидаемое изменение между ними —
    /// наш же собственный синтетический Cmd+C (SwitchCoordinator читает
    /// выделение через буфер обмена, когда AX не отдаёт его напрямую): это
    /// не чужая запись, которую нужно уважать, а наше же действие, которое
    /// нужно убрать, вернув буфер к состоянию ДО него.
    public func restore(force: Bool = false) {
        guard let expected = changeCountAfterWrite else { return }
        changeCountAfterWrite = nil
        let saved = snapshot ?? []
        snapshot = nil

        // Между нашей записью и восстановлением кто-то ещё писал в буфер —
        // его данные важнее нашего восстановления. force: true пропускает
        // эту проверку (см. комментарий выше).
        guard force || pasteboard.changeCount == expected else { return }

        writeBack(saved)
    }
}
