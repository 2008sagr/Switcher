import Foundation

/// Временная заглушка вместо `KeyboardEngine`.
///
/// `KeyboardEngine` отключён через `#if false` в Task 3 (см. `KeyboardEngine.swift`):
/// он опирался на удалённый `LayoutConverter`, а на `LayoutMapper` пока не переведён.
/// Заглушка держит `AppState` и сборку зелёными до Task 11, где `KeyboardEngine`
/// переписывается на новое ядро и эта заглушка удаляется вместе с временным `#if false`.
public final class KeyboardEngineStub {

    public var autoSwitchEnabled:  Bool             = true
    public var doubleShiftEnabled: Bool             = true
    public var spellCheckEnabled:  Bool             = true
    public var minWordLength:      Int              = 4
    public var learningEnabled:    Bool             = true
    public var exclusions:         Set<String>      = []
    public var excludedApps:       Set<String>      = []
    public var corrections:        [String: String] = [:]

    public var onSwitched: ((LastSwitchInfo) -> Void)?
    public var onUndone:   ((LastSwitchInfo) -> Void)?

    public init() {}

    public func start() {}
    public func stop() {}

    public var isRunning: Bool { false }

    public func currentLanguage() -> String { "en" }

    public func performUndoFromUI() {}
}
