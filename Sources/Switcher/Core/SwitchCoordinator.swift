import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Связывает тап, детектор и замену.
///
/// Разделение потоков строгое:
///   tap thread   — только буфер (через EventTapDelegate)
///   work queue   — детекция и замена, тут разрешены AX и NSSpellChecker
///   main queue   — только колбэки в UI
public final class SwitchCoordinator: EventTapDelegate {

    // MARK: - Настройки

    public var autoSwitchEnabled  = true
    public var doubleShiftEnabled = true
    public var minWordLength      = 4
    public var learningEnabled    = true
    public var exclusions: Set<String>      = [] { didSet { rebuildGuards() } }
    public var excludedApps: Set<String>    = [] { didSet { rebuildGuards() } }
    public var corrections: [String: String] = [:]

    public var onSwitched: ((LastSwitchInfo) -> Void)?
    public var onUndone:   ((LastSwitchInfo) -> Void)?

    // MARK: - Составные части

    private let tap = EventTapController()
    private let buffer = KeystrokeBuffer()
    private let ax = AXTextClient()
    private let sources = InputSourceManager()
    private let prior = LanguagePrior()
    private let work = DispatchQueue(label: "com.switcher.work", qos: .userInitiated)

    private var mapper: LayoutMapper?
    private var detector: LayoutDetector?
    private var injector: TextInjector!
    private var guards = GuardRules()

    private var currentBundleID = ""
    private var lastSwitch: LastSwitchInfo?
    private var lastShiftTime: TimeInterval = 0
    private var pauseWorkItem: DispatchWorkItem?
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
        currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.currentBundleID = app?.bundleIdentifier ?? ""
            self?.buffer.reset()   // Новое приложение — старый буфер невалиден.
            self?.prior.reset()    // И контекст предыдущих слов тоже не относится к делу.
        }
        return tap.start()
    }

    public func stop() {
        tap.stop()
        pauseWorkItem?.cancel()
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

    private func rebuildGuards() {
        guards = GuardRules(wordExclusions: exclusions, excludedApps: excludedApps)
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
        detector = LayoutDetector(models: [.en: en, .ru: ru],
                                  mapper: mapper,
                                  validator: SystemWordValidator(),
                                  prior: prior)
    }

    // MARK: - EventTapDelegate (вызывается на потоке тапа)

    public func tap(_ tap: EventTapController, didObserve event: TapEvent) {
        switch event {
        case .key(let stroke):
            buffer.append(stroke)
            schedulePauseCheck()
            if let word = buffer.currentWord { evaluate(word, trigger: .early) }

        case .backspace:
            buffer.backspace()
            lastSwitch = nil

        case .wordBreakKey(let stroke):
            pauseWorkItem?.cancel()
            if let word = buffer.wordEndedBy(stroke) { evaluate(word, trigger: .wordBoundary) }

        case .resetCause, .mouseDown:
            pauseWorkItem?.cancel()
            buffer.reset()
            // Контекст предыдущих слов больше не относится к делу:
            // каретка уехала или пользователь ушёл в другое место.
            prior.reset()
            lastSwitch = nil

        case .modifierOnly(let keyCode):
            handleModifier(keyCode)
        }
    }

    private func schedulePauseCheck() {
        pauseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let word = self.buffer.currentWord else { return }
            self.evaluate(word, trigger: .pause)
        }
        pauseWorkItem = item
        work.asyncAfter(deadline: .now() + pauseInterval, execute: item)
    }

    // MARK: - Детекция и замена (фоновая очередь)

    private func evaluate(_ word: WordSnapshot, trigger: Trigger) {
        guard autoSwitchEnabled, let detector else { return }
        guard word.text.count >= minWordLength else { return }
        let bundleID = currentBundleID
        guard guards.allows(word: word.text, bundleID: bundleID) else { return }

        work.async { [weak self] in
            guard let self else { return }
            let layout = self.currentLayout()

            // Пользовательские правила исправления опечаток имеют приоритет.
            if let corrected = self.corrections[word.text.lowercased()] {
                self.apply(word: word, replacement: corrected, target: layout,
                           bundleID: bundleID, isCorrection: true)
                return
            }

            guard case .convert(let target, let text) = detector.evaluate(
                word: word.text, currentLayout: layout, trigger: trigger
            ) else {
                // Слово оставлено как есть — оно тоже контекст.
                // Запоминаем только на границе слова: на паузе и ранней
                // конверсии слово ещё может быть дописано.
                if trigger == .wordBoundary { self.prior.record(layout) }
                return
            }

            self.apply(word: word, replacement: text, target: target,
                       bundleID: bundleID, isCorrection: false)
        }
    }

    private func apply(word: WordSnapshot, replacement: String, target: Layout,
                       bundleID: String, isCorrection: Bool) {
        let request = ReplacementRequest(
            strokes: word.strokes, original: word.text, replacement: replacement,
            tail: word.tail, targetLayout: target, bundleID: bundleID
        )
        guard injector.replace(request) else { return }

        if !isCorrection { switchLayout(to: target, completion: {}) }
        buffer.reset()
        prior.record(target)   // подтверждённое слово — контекст для следующих

        let info = LastSwitchInfo(
            originalWord: word.text, replacedWith: replacement,
            fromLanguage: target.opposite.rawValue, toLanguage: target.rawValue,
            timestamp: Date(), isCorrection: isCorrection, isDoubleShift: false
        )
        lastSwitch = info
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

    private func handleModifier(_ keyCode: CGKeyCode) {
        guard doubleShiftEnabled, keyCode == 56 || keyCode == 60 else { return }
        let now = Date().timeIntervalSince1970
        if now - lastShiftTime < doubleShiftInterval {
            lastShiftTime = 0
            work.async { [weak self] in self?.performUndo() }
        } else {
            lastShiftTime = now
        }
    }

    public func performUndoFromUI() {
        work.async { [weak self] in self?.performUndo() }
    }

    private func performUndo() {
        guard let info = lastSwitch, info.isUndoable else { return }
        lastSwitch = nil

        let request = ReplacementRequest(
            strokes: [], original: info.replacedWith, replacement: info.originalWord,
            tail: "", targetLayout: Layout(languageCode: info.fromLanguage) ?? .en,
            bundleID: currentBundleID
        )
        guard injector.replace(request) else { return }

        if !info.isCorrection, let from = Layout(languageCode: info.fromLanguage) {
            switchLayout(to: from, completion: {})
        }
        buffer.reset()
        DispatchQueue.main.async { self.onUndone?(info) }
    }
}
