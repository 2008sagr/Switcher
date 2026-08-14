import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Связывает тап, детектор и замену.
///
/// Разделение потоков строгое, и это касается не только «куда не ходить»,
/// но и «кто владеет данными» (ревью Task 12, находка 1: одного лишь
/// «callback тапа не блокируется» недостаточно — общие поля тоже обязаны
/// иметь единственного владельца, иначе поток тапа и фоновая очередь могут
/// мутировать их одновременно):
///
///   tap thread   — НИЧЕГО не читает и не пишет напрямую. Единственное
///                  действие — `state.async`: отдать событие на очередь
///                  состояния и вернуться. Постановка в очередь не ждёт
///                  исполнения, поэтому это не блокирует тап.
///   state queue  — выделенная последовательная очередь, единственный
///                  владелец `buffer` и всех полей, которые мутируют и тап,
///                  и колбэки настроек с main, и разбор двойного Shift:
///                  buffer, pauseWorkItem, lastShiftTime, stateGuards,
///                  stateLastSwitch, stateCurrentBundleID и теневые копии
///                  публичных настроек (state*). Здесь же — дешёвые
///                  синхронные проверки перед тем, как уйти в работу
///                  тяжелее: ни AX, ни словаря, ни сети тут нет, так что
///                  очередь не подвисает.
///   work queue   — детекция (LayoutDetector → SystemWordValidator) и
///                  замена (TextInjector → AX). Получает от state только
///                  готовые снимки — value-типы (WordSnapshot, String,
///                  [String: String], LastSwitchInfo), которые безопасно
///                  переходят между очередями без общего мутабельного
///                  состояния.
///   main queue   — только колбэки в UI и системные уведомления
///                  (NSWorkspace, DistributedNotificationCenter).
///
/// `LanguagePrior`, `SystemWordValidator` и кэш стратегий в `TextInjector`
/// синхронизированы сами (свой `NSLock`), поэтому в это разделение не
/// включены — их можно звать с любой из очередей.
public final class SwitchCoordinator: EventTapDelegate {

    // MARK: - Настройки
    //
    // Публичный API сохранён таким, каким его использует AppState — прямое
    // присваивание `var` с main thread. Каждая запись синхронно (тем же
    // потоком, что и сама запись — единственный писатель, гонки нет) снимает
    // копию значения и передаёт её на `state`-очередь: именно теневая копия
    // (state*) — то, что фактически читают обработка тапа и детекция.
    // learningEnabled нигде в координаторе не читается (логику обучения
    // ведёт сам AppState по своей копии), поэтому теневой копии не заведено —
    // синхронизировать нечего.

    public var autoSwitchEnabled = true {
        didSet {
            let value = autoSwitchEnabled
            state.async { [weak self] in self?.stateAutoSwitchEnabled = value }
        }
    }
    public var doubleShiftEnabled = true {
        didSet {
            let value = doubleShiftEnabled
            state.async { [weak self] in self?.stateDoubleShiftEnabled = value }
        }
    }
    public var minWordLength = 4 {
        didSet {
            let value = minWordLength
            state.async { [weak self] in self?.stateMinWordLength = value }
        }
    }
    public var learningEnabled = true
    public var exclusions: Set<String> = [] {
        didSet {
            let excl = exclusions, apps = excludedApps
            state.async { [weak self] in self?.rebuildGuards(exclusions: excl, excludedApps: apps) }
        }
    }
    public var excludedApps: Set<String> = [] {
        didSet {
            let excl = exclusions, apps = excludedApps
            state.async { [weak self] in self?.rebuildGuards(exclusions: excl, excludedApps: apps) }
        }
    }
    public var corrections: [String: String] = [:] {
        didSet {
            let value = corrections
            state.async { [weak self] in self?.stateCorrections = value }
        }
    }

    public var onSwitched: ((LastSwitchInfo) -> Void)?
    public var onUndone:   ((LastSwitchInfo) -> Void)?
    /// Диагностика: замена или отмена не удалась ни одной из четырёх
    /// стратегий (ревью Task 12, находка 4). Слово при этом уже могло быть
    /// повреждено — вызывающая сторона решает, показывать ли это
    /// пользователю; сейчас AppState просто логирует в консоль.
    public var onReplacementFailed: ((String) -> Void)?

    // MARK: - Составные части

    private let tap = EventTapController()
    private let ax = AXTextClient()
    private let sources = InputSourceManager()
    /// Собственный NSLock внутри — вызывать можно с любой очереди.
    private let prior = LanguagePrior()

    /// Единственный владелец буфера и всех полей, разделяемых между тапом,
    /// колбэками настроек (main) и обработкой двойного Shift. Строгая
    /// последовательность очереди — это и есть синхронизация, без единого
    /// явного NSLock в координаторе.
    private let state = DispatchQueue(label: "com.switcher.state", qos: .userInteractive)
    /// Детекция и замена: AX, NSSpellChecker, системные вызовы смены раскладки.
    private let work = DispatchQueue(label: "com.switcher.work", qos: .userInitiated)

    private var mapper: LayoutMapper?
    private var detector: LayoutDetector?
    private var injector: TextInjector!

    // Поля ниже принадлежат ИСКЛЮЧИТЕЛЬНО `state`-очереди: читать и писать
    // их можно только изнутри блоков, отправленных туда через state.async
    // (или синхронно из методов, которые сама `state` вызывает, например
    // handle(_:), вызванного из tap(_:didObserve:)).
    private let buffer = KeystrokeBuffer()
    private var stateGuards = GuardRules()
    private var stateAutoSwitchEnabled = true
    private var stateDoubleShiftEnabled = true
    private var stateMinWordLength = 4
    private var stateCorrections: [String: String] = [:]
    private var stateCurrentBundleID = ""
    private var stateLastSwitch: LastSwitchInfo?
    private var lastShiftTime: TimeInterval = 0
    private var pauseWorkItem: DispatchWorkItem?

    /// Мутируется только из start()/stop(), которые в этом кодбейзе всегда
    /// зовутся с main (AppState, кнопка «Перезапустить» в UI) — отдельной
    /// защиты не заводил, но это допущение, а не гарантия типов.
    private var appObserver: NSObjectProtocol?

    private let doubleShiftInterval: TimeInterval = 0.4
    private let pauseInterval: TimeInterval = 0.5

    public init() {
        injector = TextInjector(ax: ax) { [weak self] layout, done in
            self?.switchLayout(to: layout, completion: done)
        }
        tap.delegate = self
        rebuildLayoutTables()
    }

    // MARK: - Жизненный цикл

    @discardableResult
    public func start() -> Bool {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        state.async { [weak self] in self?.stateCurrentBundleID = bundleID }

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let newBundleID = app?.bundleIdentifier ?? ""
            self?.state.async {
                self?.stateCurrentBundleID = newBundleID
                self?.pauseWorkItem?.cancel()
                self?.buffer.reset()   // Новое приложение — старый буфер невалиден.
                self?.stateLastSwitch = nil
            }
            // LanguagePrior сам себя синхронизирует — можно звать прямо с main.
            self?.prior.reset()    // И контекст предыдущих слов тоже не относится к делу.
        }
        return tap.start()
    }

    public func stop() {
        tap.stop()
        state.async { [weak self] in self?.pauseWorkItem?.cancel() }
        if let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appObserver = nil
        }
    }

    public var isRunning: Bool { tap.isRunning }

    public func currentLanguage() -> String { sources.currentLanguage() }

    private func currentLayout() -> Layout {
        Layout(languageCode: sources.currentLanguage()) ?? .en
    }

    /// Выполняется на `state`.
    private func rebuildGuards(exclusions: Set<String>, excludedApps: Set<String>) {
        stateGuards = GuardRules(wordExclusions: exclusions, excludedApps: excludedApps)
    }

    private func rebuildLayoutTables() {
        var tables: [Layout: KeyboardLayoutTable] = [:]
        for source in sources.selectableSources() {
            guard let code = sources.language(for: source),
                  let layout = Layout(languageCode: code),
                  tables[layout] == nil,
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            tables[layout] = KeyboardLayoutTable.load(layoutData: data,
                                                      keyboardType: UInt32(LMGetKbdType()))
        }
        guard tables[.en] != nil, tables[.ru] != nil else {
            print("[Switcher] Нужны обе раскладки: английская и русская")
            return
        }
        let mapper = LayoutMapper(tables: tables)
        self.mapper = mapper
        guard let en = try? TrigramModel.bundled(.en),
              let ru = try? TrigramModel.bundled(.ru) else {
            print("[Switcher] Не удалось загрузить модели языка")
            return
        }
        // models/mapper/validator/prior у LayoutDetector — все let, сам он
        // не мутирует ничего снаружи: с любой очереди безопасен на чтение.
        detector = LayoutDetector(models: [.en: en, .ru: ru],
                                  mapper: mapper,
                                  validator: SystemWordValidator(),
                                  prior: prior)
    }

    // MARK: - EventTapDelegate (вызывается на потоке тапа)

    /// Контракт: вернуться немедленно. `state.async` этому не противоречит —
    /// постановка в очередь не тождественна исполнению. Вся логика, которая
    /// раньше выполнялась прямо здесь на потоке тапа (буфер, guards,
    /// lastSwitch), переехала в handle(_:) на `state`, единственный
    /// владелец этих данных.
    public func tap(_ tap: EventTapController, didObserve event: TapEvent) {
        state.async { [weak self] in self?.handle(event) }
    }

    /// Выполняется исключительно на `state`.
    private func handle(_ event: TapEvent) {
        switch event {
        case .key(let stroke):
            buffer.append(stroke)
            schedulePauseCheck()
            if let word = buffer.currentWord { kickOffEvaluation(word, trigger: .early) }

        case .backspace:
            buffer.backspace()
            stateLastSwitch = nil

        case .wordBreakKey(let stroke):
            pauseWorkItem?.cancel()
            if let word = buffer.wordEndedBy(stroke) { kickOffEvaluation(word, trigger: .wordBoundary) }

        case .resetCause, .mouseDown:
            pauseWorkItem?.cancel()
            buffer.reset()
            // Контекст предыдущих слов больше не относится к делу:
            // каретка уехала или пользователь ушёл в другое место.
            prior.reset()
            stateLastSwitch = nil

        case .modifierOnly(let keyCode):
            handleModifier(keyCode)
        }
    }

    /// Выполняется на `state`: и планирование, и (при срабатывании) чтение
    /// buffer.currentWord происходят на очереди-владельце буфера.
    private func schedulePauseCheck() {
        pauseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let word = self.buffer.currentWord else { return }
            self.kickOffEvaluation(word, trigger: .pause)
        }
        pauseWorkItem = item
        state.asyncAfter(deadline: .now() + pauseInterval, execute: item)
    }

    // MARK: - Детекция (граница state → work)
    //
    // Дешёвая часть (autoSwitchEnabled/minWordLength/guards) выполняется
    // прямо на `state` — синхронно, но без AX/словаря/сети, так что очередь
    // не подвисает. В work уходит уже готовый снимок: WordSnapshot
    // (value-тип), bundleID (String), corrections (Dictionary) — копии,
    // независимые от дальнейших изменений на state.

    /// Выполняется на `state`.
    private func kickOffEvaluation(_ word: WordSnapshot, trigger: Trigger) {
        guard stateAutoSwitchEnabled, let detector else { return }
        guard word.text.count >= stateMinWordLength else { return }
        let bundleID = stateCurrentBundleID
        guard stateGuards.allows(word: word.text, bundleID: bundleID) else { return }
        let corrections = stateCorrections

        work.async { [weak self] in
            self?.evaluate(word, trigger: trigger, bundleID: bundleID,
                           corrections: corrections, detector: detector)
        }
    }

    // MARK: - Детекция и замена (work queue)

    /// Выполняется на `work`.
    private func evaluate(_ word: WordSnapshot, trigger: Trigger, bundleID: String,
                          corrections: [String: String], detector: LayoutDetector) {
        let layout = currentLayout()

        // Пользовательские правила исправления опечаток имеют приоритет.
        if let corrected = corrections[word.text.lowercased()] {
            apply(word: word, replacement: corrected, target: layout,
                  bundleID: bundleID, isCorrection: true)
            return
        }

        guard case .convert(let target, let text) = detector.evaluate(
            word: word.text, currentLayout: layout, trigger: trigger
        ) else {
            // Слово оставлено как есть — оно тоже контекст.
            // Запоминаем только на границе слова: на паузе и ранней
            // конверсии слово ещё может быть дописано.
            if trigger == .wordBoundary { prior.record(layout) }
            return
        }

        apply(word: word, replacement: text, target: target,
              bundleID: bundleID, isCorrection: false)
    }

    /// Выполняется на `work`.
    private func apply(word: WordSnapshot, replacement: String, target: Layout,
                       bundleID: String, isCorrection: Bool) {
        let request = ReplacementRequest(
            strokes: word.strokes, original: word.text, replacement: replacement,
            tail: word.tail, targetLayout: target, bundleID: bundleID
        )
        guard injector.replace(request) else {
            // Не проглатываем отказ молча (ревью, находка 4): слово могло
            // остаться в промежуточном состоянии, и это стоит хотя бы видеть
            // в логе, а по возможности — сообщать наверх.
            print("[Switcher] Не удалось заменить слово «\(word.text)» — все стратегии отказали")
            onReplacementFailed?(word.text)
            return
        }

        // .keycodeReplay уже переключила раскладку сама и дождалась
        // подтверждения (см. replaceViaKeycodeReplay) — звать switchLayout
        // второй раз незачем: это лишний наблюдатель
        // DistributedNotificationCenter на каждую такую замену (ревью,
        // находка 5).
        if !isCorrection, injector.strategy(for: bundleID) != .keycodeReplay {
            switchLayout(to: target, completion: {})
        }

        prior.record(target)   // подтверждённое слово — контекст для следующих

        let info = LastSwitchInfo(
            originalWord: word.text, replacedWith: replacement, strokes: word.strokes,
            fromLanguage: target.opposite.rawValue, toLanguage: target.rawValue,
            timestamp: Date(), isCorrection: isCorrection, isDoubleShift: false
        )
        // buffer и stateLastSwitch принадлежат state — мутируем их только там.
        state.async { [weak self] in
            self?.buffer.reset()
            self?.stateLastSwitch = info
        }
        DispatchQueue.main.async { self.onSwitched?(info) }
    }

    /// Меняет раскладку и дожидается подтверждения системным уведомлением,
    /// а не фиксированной задержкой.
    private func switchLayout(to layout: Layout, completion: @escaping () -> Void) {
        let name = NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")
        var observer: NSObjectProtocol?
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
            completion()
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in finish() }

        sources.switchToLanguage(layout.rawValue)

        // Страховка на случай, если уведомление не придёт (раскладка уже активна).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
    }

    // MARK: - Двойной Shift: отмена

    /// Выполняется на `state` (вызывается из handle(_:)) — читать и писать
    /// lastShiftTime/stateLastSwitch здесь безопасно без доп. синхронизации.
    private func handleModifier(_ keyCode: CGKeyCode) {
        guard stateDoubleShiftEnabled, keyCode == 56 || keyCode == 60 else { return }
        let now = Date().timeIntervalSince1970
        if now - lastShiftTime < doubleShiftInterval {
            lastShiftTime = 0
            beginUndo()
        } else {
            lastShiftTime = now
        }
    }

    /// UI (кнопка «Отменить») тоже идёт через `state`: снимок stateLastSwitch
    /// и его обнуление обязаны происходить на очереди-владельце.
    public func performUndoFromUI() {
        state.async { [weak self] in self?.beginUndo() }
    }

    /// Выполняется на `state`: проверяет и потребляет stateLastSwitch,
    /// дальше передаёт снимок (value-тип, копировать безопасно) на work —
    /// там уже сама замена через AX.
    private func beginUndo() {
        guard let info = stateLastSwitch, info.isUndoable else { return }
        stateLastSwitch = nil
        let bundleID = stateCurrentBundleID
        work.async { [weak self] in self?.finishUndo(info, bundleID: bundleID) }
    }

    /// Выполняется на `work`.
    private func finishUndo(_ info: LastSwitchInfo, bundleID: String) {
        // Отмена возвращает ИСХОДНОЕ слово: раскладка переключается в
        // исходную (fromLanguage), а переигрываются исходные нажатия
        // (info.strokes) — не пустой массив (ревью, находка 2а).
        let request = ReplacementRequest(
            strokes: info.strokes, original: info.replacedWith, replacement: info.originalWord,
            tail: "", targetLayout: Layout(languageCode: info.fromLanguage) ?? .en,
            bundleID: bundleID
        )
        guard injector.replace(request) else {
            print("[Switcher] Не удалось отменить замену «\(info.replacedWith)» — все стратегии отказали")
            onReplacementFailed?(info.replacedWith)
            return
        }

        if !info.isCorrection, let from = Layout(languageCode: info.fromLanguage),
           injector.strategy(for: bundleID) != .keycodeReplay {
            switchLayout(to: from, completion: {})
        }

        // Симметрично apply(): отменённая конверсия не должна больше давить
        // на контекст соседних слов — иначе ещё до трёх следующих
        // неоднозначных слов получат необоснованный сдвиг порога в пользу
        // языка, который пользователь только что признал неверным (ревью,
        // находка 3).
        if let target = Layout(languageCode: info.toLanguage) {
            prior.forget(target)
        }

        state.async { [weak self] in self?.buffer.reset() }
        DispatchQueue.main.async { self.onUndone?(info) }
    }
}
