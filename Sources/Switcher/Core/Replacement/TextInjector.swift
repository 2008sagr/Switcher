import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum InjectionStrategy: String, CaseIterable, Codable, Sendable {
    /// Прямая правка диапазона через AX. Ноль синтетических событий.
    case axDirect
    /// Смена раскладки и переигрывание тех же клавиш. Для терминалов и игр,
    /// которые читают keycode, а не unicode-строку события.
    case keycodeReplay
    /// Shift+← по количеству символов и одна вставка целой строкой.
    case selectAndInject
    /// Вставка через буфер обмена. Последний резерв.
    case clipboard
}

public struct ReplacementRequest {
    public let strokes:      [KeyStroke]
    public let original:     String
    public let replacement:  String
    /// Разделитель после слова: " ", "," либо "" для незавершённого слова.
    public let tail:         String
    public let targetLayout: Layout
    public let bundleID:     String

    public init(strokes: [KeyStroke], original: String, replacement: String,
                tail: String, targetLayout: Layout, bundleID: String) {
        self.strokes      = strokes
        self.original     = original
        self.replacement  = replacement
        self.tail         = tail
        self.targetLayout = targetLayout
        self.bundleID     = bundleID
    }
}

/// Выполняет замену уже набранного слова.
///
/// Главный принцип: перед мутацией состояние проверяется, после мутации —
/// подтверждается. Если текст под кареткой не тот, что ожидался, замена не
/// выполняется вовсе: лучше не сработать, чем испортить чужой текст.
public final class TextInjector {

    /// Диапазоны замены, все длины в UTF-16.
    struct RangePlan: Equatable {
        let start: Int
        /// Слово плюс хвост — что проверяем.
        let verifyLength: Int
        /// Только слово — что заменяем.
        let wordLength: Int
    }

    private let ax: AXTextClient
    private let onSwitchLayout: (Layout, @escaping () -> Void) -> Void
    private var cache: [String: InjectionStrategy] = [:]
    private let cacheLock = NSLock()

    public init(ax: AXTextClient,
                onSwitchLayout: @escaping (Layout, @escaping () -> Void) -> Void) {
        self.ax = ax
        self.onSwitchLayout = onSwitchLayout
    }

    // MARK: - Кэш стратегий

    public func strategy(for bundleID: String) -> InjectionStrategy? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[bundleID]
    }

    func recordSuccess(_ strategy: InjectionStrategy, for bundleID: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[bundleID] = strategy
    }

    /// Стратегия перестала работать (например, приложение обновилось) —
    /// забываем её, чтобы следующий раз снова перебрать варианты.
    func recordFailure(_ strategy: InjectionStrategy, for bundleID: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[bundleID] == strategy { cache.removeValue(forKey: bundleID) }
    }

    // MARK: - Расчёт диапазонов

    /// Чистая функция ради тестируемости. Все длины — UTF-16.
    static func planRange(caret: Int, request: ReplacementRequest) -> RangePlan? {
        let wordLength = request.original.utf16.count
        let tailLength = request.tail.utf16.count
        let start = caret - wordLength - tailLength
        guard start >= 0, wordLength > 0 else { return nil }
        return RangePlan(start: start,
                         verifyLength: wordLength + tailLength,
                         wordLength: wordLength)
    }

    // MARK: - Точка входа

    /// Синхронный. Вызывать только с фоновой очереди: внутри AX-вызовы.
    @discardableResult
    public func replace(_ request: ReplacementRequest) -> Bool {
        let order: [InjectionStrategy]
        if let cached = strategy(for: request.bundleID) {
            order = [cached] + InjectionStrategy.allCases.filter { $0 != cached }
        } else {
            order = InjectionStrategy.allCases
        }

        for strategy in order {
            if perform(strategy, request) {
                recordSuccess(strategy, for: request.bundleID)
                return true
            }
            recordFailure(strategy, for: request.bundleID)
        }
        return false
    }

    private func perform(_ strategy: InjectionStrategy, _ request: ReplacementRequest) -> Bool {
        switch strategy {
        case .axDirect:        return replaceViaAX(request)
        case .keycodeReplay:   return replaceViaKeycodeReplay(request)
        case .selectAndInject: return replaceViaSelection(request)
        case .clipboard:       return replaceViaClipboard(request)
        }
    }

    // MARK: - Pre-flight

    /// Убеждается, что перед кареткой действительно лежит то слово, которое мы
    /// собрались заменить. Закрывает клик мышью, автодополнение приложения,
    /// допечатывание пользователем и протухший буфер после смены фокуса.
    private func verifiedPlan(_ request: ReplacementRequest)
        -> (element: AXUIElement, plan: RangePlan)? {
        guard let element = ax.focusedElement(),
              !ax.isSecure(element),
              let caret = ax.caretLocation(element),
              let plan = Self.planRange(caret: caret, request: request),
              let actual = ax.string(element, location: plan.start, length: plan.verifyLength),
              actual == request.original + request.tail
        else { return nil }
        return (element, plan)
    }

    // MARK: - Стратегия A: прямая правка через AX

    private func replaceViaAX(_ request: ReplacementRequest) -> Bool {
        guard let (element, plan) = verifiedPlan(request) else { return false }

        guard ax.select(element, location: plan.start, length: plan.wordLength),
              ax.replaceSelection(element, with: request.replacement)
        else {
            // Вернуть каретку туда, где она была.
            _ = ax.select(element, location: plan.start + plan.wordLength + request.tail.utf16.count, length: 0)
            return false
        }

        let newWordLength = request.replacement.utf16.count
        _ = ax.select(element, location: plan.start + newWordLength + request.tail.utf16.count, length: 0)

        // Пост-проверка: убедиться, что приложение действительно применило правку.
        let expected = request.replacement + request.tail
        return ax.string(element, location: plan.start, length: expected.utf16.count) == expected
    }

    // MARK: - Стратегия B: переигрывание keycode'ов

    func replaceViaKeycodeReplay(_ request: ReplacementRequest) -> Bool {
        // Без нажатий переигрывать нечем. Ниже сначала идёт sendBackspaces —
        // без этой проверки исходный текст удалился бы, а взамен не
        // напечаталось бы ничего: слово пропадает у пользователя без следа
        // и без сообщения об ошибке (см. ревью Task 12, находка 2). Отказ
        // здесь — страховка на уровне самого инжектора, а не только на
        // уровне вызывающего кода, который обязан передавать strokes.
        guard !request.strokes.isEmpty else { return false }

        // Проверяем состояние, если AX доступен хотя бы на чтение.
        if let element = ax.focusedElement() {
            guard !ax.isSecure(element) else { return false }
            if let caret = ax.caretLocation(element),
               let plan = Self.planRange(caret: caret, request: request),
               let actual = ax.string(element, location: plan.start, length: plan.verifyLength),
               actual != request.original + request.tail {
                return false
            }
        }

        // Раскладка меняется ПЕРЕД переигрыванием и подтверждается уведомлением,
        // а не задержкой: иначе клавиши отрисуются в старой раскладке.
        let switched = DispatchSemaphore(value: 0)
        onSwitchLayout(request.targetLayout) { switched.signal() }
        guard switched.wait(timeout: .now() + 1.0) == .success else { return false }

        let deleteCount = request.original.utf16.count + request.tail.utf16.count
        sendBackspaces(deleteCount)
        for stroke in request.strokes {
            postKey(stroke.keyCode, shift: stroke.shift)
        }
        for char in request.tail {
            postUnicode(String(char))
        }

        // Приложение обрабатывает события асинхронно, поэтому пост-проверку
        // делаем через AX там, где он есть; иначе доверяем порядку доставки.
        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return true }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return true }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
    }

    // MARK: - Стратегия C: выделение и одна вставка

    private func replaceViaSelection(_ request: ReplacementRequest) -> Bool {
        if let element = ax.focusedElement(), ax.isSecure(element) { return false }

        let count = request.original.utf16.count + request.tail.utf16.count
        for _ in 0..<count {
            postKey(123, shift: true)   // kVK_LeftArrow с Shift
        }

        // Читать выделение часто можно даже там, где писать в него нельзя.
        if let element = ax.focusedElement(),
           let selected = ax.selectedText(element),
           !selected.isEmpty,
           selected != request.original + request.tail {
            // Выделили не то — снять выделение и уйти.
            postKey(124, shift: false)  // kVK_RightArrow
            return false
        }

        // Одно событие со всей строкой: приложение получает один insertText,
        // это один шаг undo и между символами нечему разъехаться.
        postUnicode(request.replacement + request.tail)

        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return true }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return true }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
    }

    // MARK: - Стратегия D: буфер обмена

    private func replaceViaClipboard(_ request: ReplacementRequest) -> Bool {
        if let element = ax.focusedElement(), ax.isSecure(element) { return false }

        let guardian = ClipboardGuard()
        guard guardian.write(request.replacement + request.tail) else { return false }
        defer { guardian.restore() }

        let count = request.original.utf16.count + request.tail.utf16.count
        for _ in 0..<count { postKey(123, shift: true) }
        postCommandKey(9)   // kVK_ANSI_V

        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return true }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return true }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
    }

    // MARK: - Постинг событий

    /// Все события идут из одного источника: очередь событий macOS
    /// гарантирует порядок доставки, поэтому задержки между ними не нужны.
    private var source: CGEventSource { EventTapController.injectSource }

    private func postKey(_ keyCode: CGKeyCode, shift: Bool) {
        let flags: CGEventFlags = shift ? .maskShift : []
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func postCommandKey(_ keyCode: CGKeyCode) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func sendBackspaces(_ count: Int) {
        for _ in 0..<count { postKey(51, shift: false) }
    }

    /// Вставляет строку ЦЕЛИКОМ одним событием.
    private func postUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        var chars = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.flags = []
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        // keyUp без unicode-строки: с ней часть приложений вставляет текст дважды.
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.flags = []
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
