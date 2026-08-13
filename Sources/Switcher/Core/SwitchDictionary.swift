import Foundation

// MARK: - Last switch info (for undo)

public struct LastSwitchInfo {
    let originalWord:  String   // what user actually typed ("ghbdtn")
    public let replacedWith:  String   // what we replaced it with ("привет")
    let fromLanguage:  String   // layout that was active when user typed
    let toLanguage:    String   // layout we switched to
    let timestamp:     Date
    let isCorrection:  Bool     // true = typo correction, false = layout switch
    let isDoubleShift: Bool     // true = triggered by double-shift on selected text

    /// Undo is only available for a short window after the switch.
    var isUndoable: Bool {
        Date().timeIntervalSince(timestamp) < 5.0
    }
}

// MARK: - Correction rule (typo → correct spelling)

public struct CorrectionRule: Codable {
    public var from: String   // word as typed (stored lowercased)
    public var to:   String   // corrected replacement
}

// MARK: - Switch dictionary

/// Persistent user dictionary for Switcher.
/// Stores exceptions (words that must never be auto-switched) and correction rules.
/// Saved as JSON to ~/.switcher/dictionary.json (user home directory, survives app updates).
public struct SwitchDictionary: Codable {

    var schemaVersion: Int            = 1
    public var exceptions:    [String]       = []    // sorted, stable JSON diff
    var excludedApps:  [String]       = []    // bundle IDs of apps where auto-switch is disabled
    var corrections:   [CorrectionRule] = []  // typo → correct spelling rules
    var lastModified:  Date           = Date()

    // MARK: - Computed helpers

    var exceptionsSet: Set<String> {
        Set(exceptions)
    }

    /// O(1) lookup map for correction rules, keyed by lowercased "from" word.
    var correctionsMap: [String: String] {
        Dictionary(uniqueKeysWithValues: corrections.map { ($0.from, $0.to) })
    }

    // MARK: - Persistence

    public static var fileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".switcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("dictionary.json")
    }()

    /// Legacy location (for migration)
    private static var legacyFileURL: URL? = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Switcher", isDirectory: true)
        return dir.appendingPathComponent("dictionary.json")
    }()

    static func load() -> SwitchDictionary {
        // Try new location first
        if let data = try? Data(contentsOf: fileURL),
           let dict = try? decoder.decode(SwitchDictionary.self, from: data) {
            return dict
        }

        // Try legacy location (~/Library/Application Support/Switcher/)
        if let legacyURL = legacyFileURL,
           let data = try? Data(contentsOf: legacyURL),
           let dict = try? decoder.decode(SwitchDictionary.self, from: data) {
            print("[Switcher] Migrating dictionary from legacy location to ~/.switcher/")
            dict.save()  // Save to new location
            try? FileManager.default.removeItem(at: legacyURL)  // Clean up old file
            return dict
        }

        // Migrate from UserDefaults (oldest legacy storage)
        let legacy = UserDefaults.standard.stringArray(forKey: "exclusions") ?? []
        var dict = SwitchDictionary()
        dict.exceptions = legacy.map { $0.lowercased() }.sorted()
        if !legacy.isEmpty { dict.save() }
        return dict
    }

    func save() {
        var copy = self
        copy.lastModified = Date()
        copy.exceptions   = exceptions.sorted()
        guard let data = try? Self.encoder.encode(copy) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Exception mutations

    mutating func addException(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !exceptionsSet.contains(w) else { return }
        exceptions.append(w)
        exceptions.sort()
    }

    mutating func removeException(_ word: String) {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        exceptions.removeAll { $0 == w }
    }

    // MARK: - Per-app exclusions

    var excludedAppsSet: Set<String> { Set(excludedApps) }

    mutating func addExcludedApp(_ bundleID: String) {
        guard !bundleID.isEmpty, !excludedAppsSet.contains(bundleID) else { return }
        excludedApps.append(bundleID)
        excludedApps.sort()
    }

    mutating func removeExcludedApp(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
    }

    // MARK: - Correction mutations

    mutating func addCorrection(from: String, to: String) {
        let f = from.lowercased().trimmingCharacters(in: .whitespaces)
        let t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty, f != t.lowercased() else { return }
        corrections.removeAll { $0.from == f }
        corrections.append(CorrectionRule(from: f, to: t))
        corrections.sort { $0.from < $1.from }
    }

    mutating func removeCorrection(from: String) {
        corrections.removeAll { $0.from == from }
    }

    // MARK: - Merge

    mutating func merge(with other: SwitchDictionary) {
        let combined = Set(exceptions).union(Set(other.exceptions))
        exceptions = combined.sorted()
        let combinedApps = Set(excludedApps).union(Set(other.excludedApps))
        excludedApps = combinedApps.sorted()
        var mergedCorrections = correctionsMap
        for rule in other.corrections { mergedCorrections[rule.from] = rule.to }
        corrections = mergedCorrections.map { CorrectionRule(from: $0.key, to: $0.value) }
            .sorted { $0.from < $1.from }
    }

    // MARK: - Export

    public func exportJSON() -> Data? {
        try? Self.encoder.encode(self)
    }

    /// Plain text: one word per line (easy to hand-edit in TextEdit).
    func exportText() -> String {
        exceptions.joined(separator: "\n")
    }

    // MARK: - Import

    public static func fromJSON(_ data: Data) throws -> SwitchDictionary {
        try decoder.decode(SwitchDictionary.self, from: data)
    }

    public static func fromText(_ text: String) -> SwitchDictionary {
        var dict = SwitchDictionary()
        let words = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        dict.exceptions = Array(Set(words)).sorted()
        return dict
    }

    // MARK: - Codecs

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting    = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
