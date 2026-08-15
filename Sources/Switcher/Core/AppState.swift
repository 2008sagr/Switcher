import Foundation
import Combine
import ApplicationServices
import ServiceManagement

public class AppState: ObservableObject {

    // MARK: - Persisted settings

    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            // Тернарный оператор здесь больше не подходит: start() теперь
            // возвращает Bool (честный результат запуска тапа), а stop() — Void.
            if isEnabled {
                engine.start()
            } else {
                engine.stop()
            }
        }
    }

    @Published public var autoSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: "autoSwitchEnabled")
            engine.autoSwitchEnabled = autoSwitchEnabled
        }
    }

    @Published public var doubleShiftEnabled: Bool {
        didSet {
            UserDefaults.standard.set(doubleShiftEnabled, forKey: "doubleShiftEnabled")
            engine.doubleShiftEnabled = doubleShiftEnabled
        }
    }

    @Published public var minWordLength: Int {
        didSet {
            UserDefaults.standard.set(minWordLength, forKey: "minWordLength")
            engine.minWordLength = minWordLength
        }
    }

    private var applyingLaunchAtLogin = false

    @Published public var launchAtLoginEnabled: Bool {
        didSet {
            guard !applyingLaunchAtLogin else { return }
            do {
                if launchAtLoginEnabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[Switcher] Launch at login error: \(error)")
                applyingLaunchAtLogin = true
                launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
                applyingLaunchAtLogin = false
            }
        }
    }

    // MARK: - Dictionary

    @Published public var dictionary: SwitchDictionary {
        didSet {
            dictionary.save()
            engine.exclusions   = dictionary.exceptionsSet
            engine.excludedApps = dictionary.excludedAppsSet
            engine.corrections  = dictionary.correctionsMap
        }
    }

    public func addException(_ word: String) {
        dictionary.addException(word)
    }

    public func removeException(_ word: String) {
        dictionary.removeException(word)
    }

    public func importDictionary(_ imported: SwitchDictionary, merging: Bool) {
        if merging {
            dictionary.merge(with: imported)
        } else {
            dictionary = imported
        }
    }

    public var exclusions: Set<String> { dictionary.exceptionsSet }

    // MARK: - Per-app exclusions

    public var excludedApps: [String] { dictionary.excludedApps }

    public func addExcludedApp(_ bundleID: String) {
        dictionary.addExcludedApp(bundleID)
    }

    public func removeExcludedApp(_ bundleID: String) {
        dictionary.removeExcludedApp(bundleID)
    }

    // MARK: - Corrections

    public var correctionRules: [CorrectionRule] { dictionary.corrections }

    public func addCorrection(from: String, to: String) {
        dictionary.addCorrection(from: from, to: to)
    }

    public func removeCorrection(from: String) {
        dictionary.removeCorrection(from: from)
    }

    // MARK: - Runtime state

    @Published public var switchCount:      Int    = 0
    @Published public var lastSwitchedWord: String = ""
    @Published public var hasAccessibility: Bool   = false
    @Published public var engineRunning:    Bool   = false
    @Published public var lastSwitch:       LastSwitchInfo?
    @Published public var currentLayout:    String = "EN"

    public var canUndo: Bool { lastSwitch?.isUndoable == true }

    // MARK: - Engine

    public let engine: SwitchCoordinator
    private var layoutObserver: NSObjectProtocol?

    public init() {
        let savedDict        = SwitchDictionary.load()
        isEnabled            = UserDefaults.standard.object(forKey: "isEnabled")           as? Bool ?? true
        autoSwitchEnabled    = UserDefaults.standard.object(forKey: "autoSwitchEnabled")   as? Bool ?? true
        doubleShiftEnabled   = UserDefaults.standard.object(forKey: "doubleShiftEnabled")  as? Bool ?? true
        minWordLength        = UserDefaults.standard.object(forKey: "minWordLength")       as? Int  ?? 4
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        dictionary           = savedDict

        engine = SwitchCoordinator()
        engine.autoSwitchEnabled  = autoSwitchEnabled
        engine.doubleShiftEnabled = doubleShiftEnabled
        engine.minWordLength      = minWordLength
        engine.exclusions         = savedDict.exceptionsSet
        engine.excludedApps       = savedDict.excludedAppsSet
        engine.corrections        = savedDict.correctionsMap

        // Engine → AppState callbacks
        engine.onSwitched = { [weak self] info in
            DispatchQueue.main.async {
                guard let self else { return }
                self.switchCount      += 1
                self.lastSwitchedWord = info.originalWord
                self.lastSwitch       = info
            }
        }

        // Диагностика неудачной замены/отмены (ревью Task 12, находка 4):
        // отдельного UI для ошибок пока нет, но лог — минимум, который не
        // даёт пропаже текста пройти незамеченной.
        engine.onReplacementFailed = { word in
            print("[Switcher] Замена не удалась: «\(word)»")
        }

        // Отмена больше не заносит слово в исключения автоматически: одна
        // случайная отмена раньше означала вечную блокировку слова без
        // всякой обратной связи для пользователя (см. коммит). Отмена
        // только возвращает текст — исключения теперь только вручную,
        // через настройки (addException/removeException).
        engine.onUndone = { [weak self] _ in
            DispatchQueue.main.async {
                self?.lastSwitch = nil
            }
        }

        hasAccessibility = AXIsProcessTrusted()
        if isEnabled { engine.start() }
        engineRunning = engine.isRunning

        // Periodically re-check accessibility; auto-restart engine when granted.
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            DispatchQueue.main.async {
                let justGranted = !self.hasAccessibility && trusted
                self.hasAccessibility = trusted
                self.engineRunning    = self.engine.isRunning
                if justGranted && self.isEnabled {
                    self.engine.start()
                    self.engineRunning = self.engine.isRunning
                }
            }
        }

        // Track keyboard layout changes
        currentLayout = engine.currentLanguage().hasPrefix("ru") ? "RU" : "EN"
        let notifName = NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: notifName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.currentLayout = self.engine.currentLanguage().hasPrefix("ru") ? "RU" : "EN"
        }
    }

    deinit {
        if let obs = layoutObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }
}
