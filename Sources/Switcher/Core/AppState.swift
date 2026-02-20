import Foundation
import Combine
import ApplicationServices
import ServiceManagement

class AppState: ObservableObject {

    // MARK: - Persisted settings

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            isEnabled ? engine.start() : engine.stop()
        }
    }

    @Published var autoSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: "autoSwitchEnabled")
            engine.autoSwitchEnabled = autoSwitchEnabled
        }
    }

    @Published var doubleShiftEnabled: Bool {
        didSet {
            UserDefaults.standard.set(doubleShiftEnabled, forKey: "doubleShiftEnabled")
            engine.doubleShiftEnabled = doubleShiftEnabled
        }
    }

    @Published var spellCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(spellCheckEnabled, forKey: "spellCheckEnabled")
            engine.spellCheckEnabled = spellCheckEnabled
        }
    }

    @Published var minWordLength: Int {
        didSet {
            UserDefaults.standard.set(minWordLength, forKey: "minWordLength")
            engine.minWordLength = minWordLength
        }
    }

    @Published var learningEnabled: Bool {
        didSet {
            UserDefaults.standard.set(learningEnabled, forKey: "learningEnabled")
            engine.learningEnabled = learningEnabled
        }
    }

    private var applyingLaunchAtLogin = false

    @Published var launchAtLoginEnabled: Bool {
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

    @Published var dictionary: SwitchDictionary {
        didSet {
            dictionary.save()
            engine.exclusions   = dictionary.exceptionsSet
            engine.excludedApps = dictionary.excludedAppsSet
            engine.corrections  = dictionary.correctionsMap
        }
    }

    func addException(_ word: String) {
        dictionary.addException(word)
    }

    func removeException(_ word: String) {
        dictionary.removeException(word)
    }

    func importDictionary(_ imported: SwitchDictionary, merging: Bool) {
        if merging {
            dictionary.merge(with: imported)
        } else {
            dictionary = imported
        }
    }

    var exclusions: Set<String> { dictionary.exceptionsSet }

    // MARK: - Per-app exclusions

    var excludedApps: [String] { dictionary.excludedApps }

    func addExcludedApp(_ bundleID: String) {
        dictionary.addExcludedApp(bundleID)
    }

    func removeExcludedApp(_ bundleID: String) {
        dictionary.removeExcludedApp(bundleID)
    }

    // MARK: - Corrections

    var correctionRules: [CorrectionRule] { dictionary.corrections }

    func addCorrection(from: String, to: String) {
        dictionary.addCorrection(from: from, to: to)
    }

    func removeCorrection(from: String) {
        dictionary.removeCorrection(from: from)
    }

    // MARK: - Runtime state

    @Published var switchCount:      Int    = 0
    @Published var lastSwitchedWord: String = ""
    @Published var hasAccessibility: Bool   = false
    @Published var engineRunning:    Bool   = false
    @Published var lastSwitch:       LastSwitchInfo?
    @Published var currentLayout:    String = "EN"

    var canUndo: Bool { lastSwitch?.isUndoable == true }

    // MARK: - Engine

    let engine: KeyboardEngine
    private var layoutObserver: NSObjectProtocol?

    init() {
        let savedDict        = SwitchDictionary.load()
        isEnabled            = UserDefaults.standard.object(forKey: "isEnabled")           as? Bool ?? true
        autoSwitchEnabled    = UserDefaults.standard.object(forKey: "autoSwitchEnabled")   as? Bool ?? true
        doubleShiftEnabled   = UserDefaults.standard.object(forKey: "doubleShiftEnabled")  as? Bool ?? true
        spellCheckEnabled    = UserDefaults.standard.object(forKey: "spellCheckEnabled")   as? Bool ?? true
        minWordLength        = UserDefaults.standard.object(forKey: "minWordLength")       as? Int  ?? 4
        learningEnabled      = UserDefaults.standard.object(forKey: "learningEnabled")     as? Bool ?? true
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        dictionary           = savedDict

        engine = KeyboardEngine()
        engine.autoSwitchEnabled  = autoSwitchEnabled
        engine.doubleShiftEnabled = doubleShiftEnabled
        engine.spellCheckEnabled  = spellCheckEnabled
        engine.minWordLength      = minWordLength
        engine.learningEnabled    = learningEnabled
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

                // Learn from double-shift: split selection into words, add each as correction rule
                if info.isDoubleShift && self.learningEnabled {
                    let origWords = info.originalWord
                        .components(separatedBy: .whitespacesAndNewlines)
                        .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                        .filter { !$0.isEmpty }
                    let convWords = info.replacedWith
                        .components(separatedBy: .whitespacesAndNewlines)
                        .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                        .filter { !$0.isEmpty }
                    if origWords.count == convWords.count {
                        for (orig, conv) in zip(origWords, convWords) {
                            self.addCorrection(from: orig, to: conv)
                        }
                    }
                }
            }
        }

        engine.onUndone = { [weak self] info in
            DispatchQueue.main.async {
                self?.lastSwitch = nil
                if self?.learningEnabled == true, !info.isCorrection {
                    self?.addException(info.originalWord)
                }
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
