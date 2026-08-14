import Foundation

/// Условия, при которых Switcher не вмешивается в набор.
///
/// Все проверки — чистые функции от слова и bundle ID: никаких обращений
/// к Accessibility. Проверка секретного поля через AX живёт отдельно,
/// в `SwitchCoordinator`, потому что требует ввода-вывода.
public struct GuardRules {

    public var wordExclusions: Set<String>
    public var excludedApps:   Set<String>

    public init(wordExclusions: Set<String> = [], excludedApps: Set<String> = []) {
        self.wordExclusions = wordExclusions
        self.excludedApps   = excludedApps
    }

    public func allows(word: String, bundleID: String) -> Bool {
        guard !excludedApps.contains(bundleID) else { return false }
        guard !wordExclusions.contains(word.lowercased()) else { return false }
        guard !Self.looksLikeURLOrPath(word) else { return false }
        guard !Self.looksLikeSecret(word) else { return false }
        return true
    }

    public static func looksLikeURLOrPath(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.contains("@") { return true }
        if lower.hasPrefix("http") || lower.hasPrefix("www.") || lower.hasPrefix("ftp") { return true }
        if lower.hasPrefix("/") || lower.hasPrefix("~/") || lower.hasPrefix("./") { return true }
        // Домен вида example.co.uk: минимум две непустые части, разделённые
        // точкой. Один конечный "." (конец предложения) не считается —
        // отбрасываем его перед разбиением. split(separator:) сам исключает
        // пустые части, так что дополнительная проверка на пустоту не нужна.
        let inner = lower.hasSuffix(".") ? String(lower.dropLast()) : lower
        return inner.split(separator: ".").count >= 2
    }

    /// Грубая оценка «это пароль или капча, а не слово».
    ///
    /// Правило Caramba: длиннее шести знаков и одновременно содержит строчные,
    /// заглавные и цифры или знаки. Закрывает случаи, где `AXSecureTextField`
    /// не срабатывает: sudo в терминале, поля Electron, капчи.
    public static func looksLikeSecret(_ word: String) -> Bool {
        guard word.count > 6 else { return false }
        var hasLower = false, hasUpper = false, hasOther = false
        for char in word {
            if char.isLowercase { hasLower = true }
            else if char.isUppercase { hasUpper = true }
            else if char.isNumber || char.isSymbol || char.isPunctuation { hasOther = true }
        }
        return hasLower && hasUpper && hasOther
    }
}
