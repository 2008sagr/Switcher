import Foundation

/// Последняя раскладка, о которой сообщила система, — снимок для очередей,
/// которым нельзя звать TIS напрямую.
///
/// Существует ровно по одной причине: `InputSourceManager` можно вызывать
/// только с main (см. его заголовок), а `SwitchCoordinator.evaluate()` на
/// каждое слово читает текущую раскладку с очереди `work`. Раньше это
/// читалось прямым вызовом `TISCopyCurrentKeyboardInputSource` — со
/// вторичной очереди это падение (`dispatch_assert_queue_fail` внутри
/// HIToolbox). Здесь вместо похода в TIS читается кэш: значение обновляется
/// на main (при старте и по системному уведомлению
/// `TISNotifySelectedKeyboardInputSourceChanged`, включая наши собственные
/// переключения — `TISSelectInputSource` рассылает то же уведомление), а
/// читается с любой очереди.
///
/// Свой `NSLock`, симметрично `LanguagePrior` и кэшу стратегий в
/// `TextInjector` — по той же причине эти три типа не входят в разделение
/// очередей `SwitchCoordinator`, вызывать их можно откуда угодно.
final class CurrentLayoutCache {

    private var value: String
    private let lock = NSLock()

    init(initial: String = "en") {
        self.value = initial
    }

    /// Кладёт новое значение. Вызывается с main — по факту, но лок делает
    /// вызов безопасным и с любой другой очереди тоже.
    func update(_ language: String) {
        lock.lock(); defer { lock.unlock() }
        value = language
    }

    /// Читает последнее известное значение. Безопасно с любой очереди —
    /// именно ради этого класс и заведён.
    func read() -> String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
