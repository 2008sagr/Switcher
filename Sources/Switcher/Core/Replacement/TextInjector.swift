import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum InjectionStrategy: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
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

/// Исход одной стратегии замены. Раньше был Bool — этого недостаточно:
/// стратегии B/C/D сперва меняют текст синтетическими событиями и только
/// потом проверяют результат, а Bool не различает «ничего не трогали,
/// провалились на входе» от «уже поменяли текст, но проверить нечем».
/// Смешение этих исходов в перебор TextInjector.replace() приводило к
/// повторному применению следующей стратегией поверх уже применённой первой
/// (дублирование текста в терминале) и к порче хвоста слова (Shift+←
/// в терминале двигает каретку, а не выделяет — следующая стратегия решала,
/// что предыдущая ничего не сделала, и сама съедала пробел перед словом).
enum StrategyOutcome: Equatable {
    /// Текст заменён и подтверждён последующим чтением через AX.
    case succeeded
    /// Текст уже изменён синтетическими событиями, но подтвердить нечем
    /// (типично для терминалов: AX там видит буфер терминала, а не текстовое
    /// поле, и пост-проверка никогда не сойдётся). Перебор обязан
    /// остановиться здесь — попытка следующей стратегии ударила бы по уже
    /// применённой замене.
    case mutatedUnverified
    /// Текст гарантированно не тронут — можно безопасно пробовать следующую
    /// стратегию.
    case notApplicable
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

    // MARK: - Правило перебора

    /// Итог прогона списка стратегий по порядку.
    enum TrialOutcome: Equatable {
        /// Сработала и подтвердилась — вот эта.
        case succeeded(InjectionStrategy)
        /// Эта стратегия уже поменяла текст, но подтвердить нечем — перебор
        /// остановлен на ней, дальше не идём.
        case mutatedUnverified(InjectionStrategy)
        /// Все стратегии отказали, ничего не тронуто.
        case exhausted
    }

    /// Чистая функция ради тестируемости: сама не делает системных вызовов,
    /// только применяет правило перебора к уже готовым исходам, которые ей
    /// поставляет `perform`. Правило:
    ///   .succeeded         → вернуть эту стратегию, остановиться.
    ///   .mutatedUnverified → остановиться НА НЕЙ ЖЕ, следующую не пробовать:
    ///                        текст уже изменён, повторное применение его
    ///                        испортит (дублирование, съеденный пробел).
    ///   .notApplicable     → перейти к следующей стратегии по порядку.
    static func runTrial(order: [InjectionStrategy],
                          perform: (InjectionStrategy) -> StrategyOutcome) -> TrialOutcome {
        for strategy in order {
            switch perform(strategy) {
            case .succeeded:          return .succeeded(strategy)
            case .mutatedUnverified:  return .mutatedUnverified(strategy)
            case .notApplicable:      continue
            }
        }
        return .exhausted
    }

    // MARK: - Точка входа

    /// Синхронный. Вызывать только с фоновой очереди: внутри AX-вызовы.
    @discardableResult
    public func replace(_ request: ReplacementRequest) -> Bool {
        // Находка 4 (финальное ревью): SwitchDictionary.addCorrection
        // отбрасывает пустую замену при добавлении через интерфейс
        // настроек, но файл ~/.switcher/dictionary.json спроектирован для
        // ручного редактирования, а SwitchDictionary.load() декодирует его
        // без валидации. Пустая замена, вписанная вручную, дошла бы сюда
        // как replacement: "" — и ни одна из четырёх стратегий не откажет
        // сама по себе (все они сверяют ИСХОДНЫЙ текст под кареткой, а не
        // непустоту замены), так что слово было бы тихо удалено. Guard —
        // последняя линия защиты, до перебора стратегий и любых системных
        // вызовов.
        guard !request.replacement.isEmpty else { return false }

        let order: [InjectionStrategy]
        if let cached = strategy(for: request.bundleID) {
            order = [cached] + InjectionStrategy.allCases.filter { $0 != cached }
        } else {
            order = InjectionStrategy.allCases
        }

        switch Self.runTrial(order: order, perform: { candidate in
            let outcome = perform(candidate, request)
            // Понижаем стратегию ТОЛЬКО когда она гарантированно ничего не
            // тронула — иначе кэш забыл бы стратегию, которая скорее всего
            // работает, просто в этом приложении подтвердить нечем (терминал),
            // и каждая следующая замена заново перебирала бы варианты.
            if outcome == .notApplicable { recordFailure(candidate, for: request.bundleID) }
            return outcome
        }) {
        case .succeeded(let strategy):
            recordSuccess(strategy, for: request.bundleID)
            return true
        case .mutatedUnverified:
            return true
        case .exhausted:
            return false
        }
    }

    private func perform(_ strategy: InjectionStrategy, _ request: ReplacementRequest) -> StrategyOutcome {
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

    private func replaceViaAX(_ request: ReplacementRequest) -> StrategyOutcome {
        // Pre-flight — до любых мутаций, только чтение (verifiedPlan сама
        // ничего не пишет: focusedElement/isSecure/caretLocation/string).
        guard let (element, plan) = verifiedPlan(request) else { return .notApplicable }

        // ax.select — это перемещение выделения, не правка текста, поэтому
        // отказ здесь всё ещё «ничего не тронуто».
        guard ax.select(element, location: plan.start, length: plan.wordLength) else {
            return .notApplicable
        }

        // ax.replaceSelection — единственный собственно мутирующий вызов
        // здесь, и в отличие от CGEvent-стратегий B/C/D это синхронный
        // блокирующий IPC-вызов к AX сервера приложения с определённым
        // ответом: false означает, что приложение ОТКЛОНИЛО запись целиком,
        // а не «применило частично». Поэтому здесь ещё можно безопасно
        // уступить следующей стратегии.
        guard ax.replaceSelection(element, with: request.replacement) else {
            // Вернуть каретку туда, где она была.
            _ = ax.select(element, location: plan.start + plan.wordLength + request.tail.utf16.count, length: 0)
            return .notApplicable
        }

        let newWordLength = request.replacement.utf16.count
        _ = ax.select(element, location: plan.start + newWordLength + request.tail.utf16.count, length: 0)

        // Пост-проверка. AX уже подтвердил применение правки (replaceSelection
        // вернул true) — точка невозврата пройдена ДО этой строки. Несовпадение
        // здесь означает «не смогли перечитать» (например, приложение сразу
        // после правки что-то ещё поменяло), а не «не применили», поэтому
        // дальше — mutatedUnverified, а не notApplicable.
        let expected = request.replacement + request.tail
        if ax.string(element, location: plan.start, length: expected.utf16.count) == expected {
            return .succeeded
        }
        return .mutatedUnverified
    }

    // MARK: - Стратегия B: переигрывание keycode'ов

    func replaceViaKeycodeReplay(_ request: ReplacementRequest) -> StrategyOutcome {
        // Без нажатий переигрывать нечем. Ниже сначала идёт sendBackspaces —
        // без этой проверки исходный текст удалился бы, а взамен не
        // напечаталось бы ничего: слово пропадает у пользователя без следа
        // и без сообщения об ошибке (см. ревью Task 12, находка 2). Отказ
        // здесь — страховка на уровне самого инжектора, а не только на
        // уровне вызывающего кода, который обязан передавать strokes.
        guard !request.strokes.isEmpty else { return .notApplicable }

        // Вторая линия защиты (финальное ревью, находка 1). Без AX сверить
        // состояние нечем вообще: раньше это место молча пропускало
        // проверку и шло прямиком к sendBackspaces(deleteCount) — то есть
        // било вслепую по количеству символов, посчитанному из снимка
        // буфера. Это ровно те приложения (терминалы), ради которых
        // стратегия существует, и именно они получали удар первыми, если
        // снимок оказывался устаревшим.
        //
        // Выбор — отказаться и уступить следующей стратегии, а не пытаться
        // подтвердить состояние как-то иначе (например, эвристикой
        // «буфер свежий» из спеки: не было мыши/смены фокуса, последнее
        // нажатие недавно). Причины:
        //   1. Принцип во всём файле один и тот же — «лучше не сработать,
        //      чем испортить текст» (см. заголовок класса); отказ уже
        //      закрывает опасность полностью, а не частично.
        //   2. Альтернативная эвристика подтверждала бы состояние ДО
        //      начала replaceViaKeycodeReplay, но не защищает от событий,
        //      случившихся уже ВНУТРИ него, — включая до секунды ожидания
        //      подтверждения смены раскладки чуть ниже. Ложное чувство
        //      безопасности хуже честного отказа.
        //   3. Отказ здесь не глушит замену совсем: strategy selectAndInject
        //      и strategy clipboard идут следующими в порядке перебора
        //      (TextInjector.replace()) и могут сработать в том же самом
        //      приложении — пользователь в худшем случае не получает
        //      исправления в этот раз, а не порченный текст.
        guard let element = ax.focusedElement() else { return .notApplicable }
        guard !ax.isSecure(element) else { return .notApplicable }
        if let caret = ax.caretLocation(element),
           let plan = Self.planRange(caret: caret, request: request),
           let actual = ax.string(element, location: plan.start, length: plan.verifyLength),
           actual != request.original + request.tail {
            return .notApplicable
        }

        // Раскладка меняется ПЕРЕД переигрыванием и подтверждается уведомлением,
        // а не задержкой: иначе клавиши отрисуются в старой раскладке. Отказ
        // здесь — ещё до backspace'ов, текст не тронут.
        let switched = DispatchSemaphore(value: 0)
        onSwitchLayout(request.targetLayout) { switched.signal() }
        guard switched.wait(timeout: .now() + 1.0) == .success else { return .notApplicable }

        // Точка невозврата: синтетические события летят в очередь, назад их
        // не забрать — отсюда и ниже только .succeeded или .mutatedUnverified.
        let deleteCount = request.original.utf16.count + request.tail.utf16.count
        sendBackspaces(deleteCount)
        for stroke in request.strokes {
            postKey(stroke.keyCode, shift: stroke.shift)
        }
        for char in request.tail {
            postUnicode(String(char))
        }

        // Приложение обрабатывает события асинхронно, поэтому пост-проверку
        // делаем через AX там, где он есть; иначе доверяем порядку доставки —
        // ЭТО и есть терминальный случай: AX терминала видит буфер терминала,
        // а не текстовое поле, сверить нечем в принципе, и так будет всегда.
        // Раньше здесь стояло `return true`, что при провале следующей
        // сверки ниже вырождалось в `return false` — то есть считалось, что
        // ничего не изменилось, хотя события уже отправлены. Отсюда и
        // дублирование текста в терминале: перебор шёл дальше, к
        // replaceViaSelection, которая вставляла строку ещё раз.
        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return .mutatedUnverified }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return .mutatedUnverified }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
            ? .succeeded : .mutatedUnverified
    }

    // MARK: - Стратегия C: выделение и одна вставка

    /// Совпадает ли реально выделенное с ожидаемым «слово + хвост». Вынесено
    /// в чистую функцию ради тестируемости (симметрично `planRange`):
    /// `AXUIElement` — непрозрачный тип из чужого процесса, сконструировать
    /// его в оффлайн-тесте нельзя, поэтому вся логика сравнения, которая
    /// решает «доверять или нет» выделению, живёт отдельно от самого
    /// AX-вызова, который её кормит. Используется и стратегией C, и
    /// стратегией D (находка 3, финальное ревью) — раньше D не сверяла
    /// вообще ничего.
    ///
    /// `nil` или пустая строка — значит выделение прочитать не удалось
    /// (доступно на запись, но не на чтение, либо атрибут не отвечает):
    /// раз сверить нечем, доверяем порядку доставки событий, как и раньше.
    static func selectionMatchesExpectation(_ selected: String?, expected: String) -> Bool {
        guard let selected, !selected.isEmpty else { return true }
        return selected == expected
    }

    private func replaceViaSelection(_ request: ReplacementRequest) -> StrategyOutcome {
        if let element = ax.focusedElement(), ax.isSecure(element) { return .notApplicable }

        let count = request.original.utf16.count + request.tail.utf16.count
        for _ in 0..<count {
            postKey(123, shift: true)   // kVK_LeftArrow с Shift
        }

        // До этой точки посланы только стрелки (Shift+←) — они двигают
        // каретку или расширяют выделение, но сами по себе НИКОГДА не
        // вставляют и не удаляют символы ни в одном текстовом поле. Это
        // верно и в терминалах, где Shift+← часто вообще не создаёт
        // выделения, а просто двигает курсор (см. пост-проверку выше по
        // стеку — replaceViaKeycodeReplay): для нас разница неважна, в обоих
        // случаях текст гарантированно не тронут. Поэтому отказ здесь —
        // ещё .notApplicable, а не .mutatedUnverified.
        if let element = ax.focusedElement(),
           !Self.selectionMatchesExpectation(ax.selectedText(element),
                                              expected: request.original + request.tail) {
            // Выделили не то (или закаретили не туда) — снять выделение и уйти.
            postKey(124, shift: false)  // kVK_RightArrow
            return .notApplicable
        }

        // Точка невозврата: одно событие со всей строкой. Приложение
        // получает один insertText, это один шаг undo и между символами
        // нечему разъехаться — но дальше текст уже изменён, откатить нельзя.
        postUnicode(request.replacement + request.tail)

        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return .mutatedUnverified }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return .mutatedUnverified }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
            ? .succeeded : .mutatedUnverified
    }

    // MARK: - Стратегия D: буфер обмена

    private func replaceViaClipboard(_ request: ReplacementRequest) -> StrategyOutcome {
        if let element = ax.focusedElement(), ax.isSecure(element) { return .notApplicable }

        let guardian = ClipboardGuard()
        // Запись в СВОЙ буфер обмена не трогает текст целевого приложения —
        // отказ здесь по-прежнему .notApplicable. defer здесь намеренно НЕ
        // используется (в отличие от прежней версии) — восстановление до и
        // после Cmd+V должно вести себя по-разному, см. ниже по функции.
        guard guardian.write(request.replacement + request.tail) else { return .notApplicable }

        let count = request.original.utf16.count + request.tail.utf16.count
        for _ in 0..<count { postKey(123, shift: true) }   // kVK_LeftArrow с Shift

        // Сверка симметрично стратегии C: до Cmd+V посланы только стрелки —
        // движение каретки/выделения, не правка текста, поэтому отказ здесь
        // всё ещё .notApplicable (находка 3, финальное ревью: раньше D не
        // сверяла вообще ничего перед вставкой).
        if let element = ax.focusedElement(),
           !Self.selectionMatchesExpectation(ax.selectedText(element),
                                              expected: request.original + request.tail) {
            // Выделили не то — снять выделение и уйти. Cmd+V ещё не
            // отправлен, приложению нечего было прочитать из буфера —
            // восстановить можно немедленно, синхронно, задержка тут не
            // нужна (см. doc-комментарий у ClipboardGuard.scheduleRestore
            // про то, от чего вообще зависит задержка).
            postKey(124, shift: false)  // kVK_RightArrow
            guardian.restore()
            return .notApplicable
        }

        // Точка невозврата: Cmd+V вставляет буфер обмена в приложение.
        postCommandKey(9)   // kVK_ANSI_V

        // Cmd+V — синтетическое событие: оно встаёт в очередь событий и
        // обрабатывается целевым приложением АСИНХРОННО, позже этой строки.
        // Немедленное restore() (как было раньше, через defer) в среднем
        // успевало сработать раньше, чем приложение читало буфер — то есть
        // раньше, чем Cmd+V фактически что-либо вставлял, и в приложение
        // попадало исходное содержимое буфера, а не конвертированный текст.
        // Это ровно те приложения (терминалы без Accessibility), ради
        // которых стратегия D вообще существует. scheduleRestore()
        // откладывает restore() на отдельную очередь и не блокирует эту —
        // пост-проверка ниже выполняется сразу же, не дожидаясь его.
        guardian.scheduleRestore()

        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return .mutatedUnverified }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return .mutatedUnverified }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
            ? .succeeded : .mutatedUnverified
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
