import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Что тап увидел. Разбор события — чистая функция, поэтому тестируется офлайн.
public enum TapEvent {
    case key(KeyStroke)
    case backspace
    /// Пробел или знак препинания: слово закончилось.
    case wordBreakKey(KeyStroke)
    /// Буфер надо сбросить; строка — причина, для отладки.
    case resetCause(String)
    /// Нажат только модификатор (для двойного Shift).
    case modifierOnly(CGKeyCode)
    case mouseDown
}

/// Получатель разобранных событий тапа.
///
/// КОНТРАКТ (нарушение замораживает клавиатуру во всей системе):
/// `didObserve` вызывается СИНХРОННО прямо внутри callback'а CGEventTap, на
/// выделенном потоке тапа. Перенос тапа на свой поток решает только проблему
/// «main thread занят посторонним» — он НЕ решает «сам callback выполняется
/// дольше таймаута macOS». Если реализация `didObserve` заблокируется —
/// обращение к Accessibility API, проверка орфографии, чтение файла, сеть,
/// таймер, любой блокирующий примитив (lock, semaphore.wait, DispatchQueue.sync
/// на занятую очередь) — то воспроизведётся ровно тот же
/// kCGEventTapDisabledByTimeout, только на выделенном потоке вместо main.
/// Реализация ОБЯЗАНА вернуться немедленно: разобрать событие в памяти,
/// поставить в очередь/буфер и отдать управление. Вся потенциально
/// блокирующая работа переносится на другую очередь/поток самим делегатом.
public protocol EventTapDelegate: AnyObject {
    func tap(_ tap: EventTapController, didObserve event: TapEvent)
}

private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
    controller.handle(type: type, event: event)
    // Событие пропускается ВСЕГДА. Подавление клавиш — источник гонок
    // и потерянного ввода; замена выполняется поверх уже набранного текста.
    return Unmanaged.passUnretained(event)
}

/// Владеет CGEventTap. Живёт на выделенном потоке со своим run loop, чтобы
/// подвисание main thread не приводило к kCGEventTapDisabledByTimeout и
/// заморозке клавиатуры во всей системе.
public final class EventTapController {

    /// Метка «это наше событие». Ставится на ИСТОЧНИК: поле
    /// .eventSourceUserData производно от источника, и при постинге
    /// через HID-тап система перезаписывает его значением из источника.
    public static let syntheticMarker: Int64 = 0x57495443

    /// Единственный источник для всех синтетических событий.
    /// .privateState — независимое состояние модификаторов: с .hidSystemState
    /// удерживаемый пользователем Shift попадал бы в инжектируемый текст.
    public static let injectSource: CGEventSource = {
        guard let source = CGEventSource(stateID: .privateState) else {
            // CGEventSource(stateID:) документированно может вернуть nil.
            // Источник инжекта — единственный на весь процесс и нужен для
            // любой замены текста; без него функциональность приложения
            // теряет смысл целиком. Внятный fatalError лучше, чем слепой
            // форс-анврап: тот же крэш, но с диагностикой в консоли, а не
            // безымянный "Fatal error: Unexpectedly found nil" в рантайме.
            fatalError("[Switcher] Не удалось создать CGEventSource(.privateState) — инжект текста невозможен")
        }
        source.userData = syntheticMarker
        return source
    }()

    public weak var delegate: EventTapDelegate?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    public init() {}

    deinit {
        // Обязателен: указатель на self передан в тап через passUnretained,
        // а run loop source и выделенный поток живут независимо от ARC —
        // CFRunLoopRun() не вернётся, пока его не остановят. Без этого
        // освобождение контроллера без вызова stop() оставляет системный
        // хук с указателем на освобождённую память.
        stop()
    }

    public var isRunning: Bool { tap != nil }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard AXIsProcessTrusted() else {
            print("[Switcher] Нет разрешения Accessibility — тап не создаётся")
            return false
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: pointer
        ) else {
            print("[Switcher] Не удалось создать event tap")
            return false
        }

        tap = created
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)

        // Выделенный поток: занятость main thread не должна приводить
        // к таймауту тапа и заморозке ввода в системе.
        let ready = DispatchSemaphore(value: 0)
        // Узкое окно гонки (ревью, находка 5): если единственный внешний
        // владелец контроллера освободит его между worker.start() и первой
        // строкой замыкания, weak self внутри замыкания станет nil, guard
        // провалится и тап реально не включится — но поток к этому моменту
        // уже создан. didEnable фиксирует, что произошло НА САМОМ ДЕЛЕ,
        // и start() возвращает честный результат, а не "true" по умолчанию.
        var didEnable = false
        let worker = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else { ready.signal(); return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            didEnable = true
            ready.signal()
            CFRunLoopRun()
        }
        worker.name = "com.switcher.eventtap"
        worker.qualityOfService = .userInteractive
        worker.start()
        thread = worker
        ready.wait()

        guard didEnable else {
            print("[Switcher] Контроллер освобождён во время старта — тап не включён")
            return false
        }

        print("[Switcher] Event tap запущен на выделенном потоке")
        return true
    }

    /// Идемпотентен: безопасно звать, если тап не запускался или уже
    /// остановлен — это важно, потому что теперь stop() вызывается ещё и
    /// из deinit, и там повторный/лишний вызов не должен падать.
    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource, let loop = threadRunLoop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopStop(loop)
        }
        self.tap = nil
        runLoopSource = nil
        threadRunLoop = nil
        thread = nil
    }

    /// Вызывается из callback'а. Только разбор и передача делегату:
    /// ни AX, ни словарей, ни таймеров, ни ввода-вывода.
    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Наши собственные события мимо буфера: иначе инжектированный текст
        // попадёт в буфер и вызовет каскад повторных конверсий.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return }
        delegate?.tap(self, didObserve: Self.classify(event: event, type: type))
    }

    /// Чистая классификация события. `static` ради офлайн-тестов.
    static func classify(event: CGEvent, type: CGEventType) -> TapEvent {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            // Каретка уехала — всё, что накоплено, больше не соответствует тексту.
            return .mouseDown

        case .flagsChanged:
            return .modifierOnly(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
                return .resetCause("модификатор")
            }
            switch keyCode {
            case CGKeyCode(kVK_Delete):    return .backspace
            case CGKeyCode(kVK_Tab):       return .resetCause("tab")
            case CGKeyCode(kVK_Escape):    return .resetCause("escape")
            case CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow),
                 CGKeyCode(kVK_DownArrow), CGKeyCode(kVK_UpArrow):
                return .resetCause("стрелка")
            default:  break
            }

            guard let char = unicodeChar(from: event) else { return .resetCause("нет символа") }
            let stroke = KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift), char: char)

            // Границей слова считается ТОЛЬКО пробельный символ.
            //
            // Знаки препинания границей не являются: на русской раскладке они
            // стоят в позициях букв. «любовь», набранное в английской раскладке,
            // выглядит как "k.,jdm" — точка и запятая здесь это «ю» и «б», и они
            // обязаны попасть в буфер. Если рвать слово по ним, конвертировать
            // будет нечего.
            if char.isWhitespace || char.isNewline {
                return .wordBreakKey(stroke)
            }
            return .key(stroke)

        default:
            return .resetCause("прочее")
        }
    }

    private static func unicodeChar(from event: CGEvent) -> Character? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0, let scalar = Unicode.Scalar(chars[0]) else { return nil }
        return Character(scalar)
    }
}
