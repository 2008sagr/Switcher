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
        let source = CGEventSource(stateID: .privateState)!
        source.userData = syntheticMarker
        return source
    }()

    public weak var delegate: EventTapDelegate?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    public init() {}

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
        let worker = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else { ready.signal(); return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        worker.name = "com.switcher.eventtap"
        worker.qualityOfService = .userInteractive
        worker.start()
        thread = worker
        ready.wait()

        print("[Switcher] Event tap запущен на выделенном потоке")
        return true
    }

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
            case 51:  return .backspace                       // Delete
            case 48:  return .resetCause("tab")
            case 53:  return .resetCause("escape")
            case 123, 124, 125, 126: return .resetCause("стрелка")
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
