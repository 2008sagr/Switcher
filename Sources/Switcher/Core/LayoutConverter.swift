import Foundation

/// Converts text between keyboard layouts (EN QWERTY ↔ RU ЙЦУКЕН).
///
/// The core idea: when a user types on a QWERTY keyboard with the wrong layout
/// active, each physical key produces a different character than intended.
/// This converter maps characters to what they would be on the same physical
/// key in the other layout.
struct LayoutConverter {

    // MARK: - EN (QWERTY) → RU (ЙЦУКЕН)
    // Maps what you got (EN char) → what you wanted (RU char at same physical key)

    static let enToRu: [Character: Character] = [
        // Top row
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е",
        "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з",
        "[": "х", "]": "ъ",
        // Middle row
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п",
        "h": "р", "j": "о", "k": "л", "l": "д",
        ";": "ж", "'": "э",
        // Bottom row
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и",
        "n": "т", "m": "ь", ",": "б", ".": "ю",
        // Uppercase
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е",
        "Y": "Н", "U": "Г", "I": "Ш", "O": "Щ", "P": "З",
        "{": "Х", "}": "Ъ",
        "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П",
        "H": "Р", "J": "О", "K": "Л", "L": "Д",
        ":": "Ж", "\"": "Э",
        "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И",
        "N": "Т", "M": "Ь", "<": "Б", ">": "Ю"
    ]

    // MARK: - RU (ЙЦУКЕН) → EN (QWERTY) — auto-derived

    static let ruToEn: [Character: Character] = {
        Dictionary(uniqueKeysWithValues: enToRu.map { ($0.value, $0.key) })
    }()

    // MARK: - Public API

    /// Convert text typed in one layout to what it would be in another layout.
    ///
    /// - strict: true  → return "" if ANY character can't be mapped (used for auto-switch word check)
    ///           false → pass unmapped characters through unchanged (used for double-shift on arbitrary selections)
    func convert(_ text: String, fromLanguage: String, toLanguage: String, strict: Bool = true) -> String {
        let mapping: [Character: Character]

        let from = fromLanguage.prefix(2).lowercased()
        let to   = toLanguage.prefix(2).lowercased()

        switch (from, to) {
        case ("en", "ru"): mapping = Self.enToRu
        case ("ru", "en"): mapping = Self.ruToEn
        default: return ""
        }

        return applyMapping(mapping, to: text, strict: strict)
    }

    // MARK: - Private

    private func applyMapping(_ mapping: [Character: Character], to text: String, strict: Bool) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for char in text {
            if let mapped = mapping[char] {
                result.append(mapped)
            } else if char.isNumber || char.isWhitespace || char == "-" || char == "'" {
                // Digits, whitespace, hyphens, apostrophes — layout-independent, always pass through
                result.append(char)
            } else if strict {
                // Strict mode: any unmappable character means the whole conversion is invalid
                return ""
            } else {
                // Lenient mode (double-shift): pass unknown characters through unchanged
                result.append(char)
            }
        }
        return result
    }

    /// Check how many characters in the text can be mapped to the target layout.
    /// Returns a value from 0.0 to 1.0.
    func mappingConfidence(_ text: String, fromLanguage: String, toLanguage: String) -> Double {
        let mapping: [Character: Character]

        let from = fromLanguage.prefix(2).lowercased()
        let to   = toLanguage.prefix(2).lowercased()

        switch (from, to) {
        case ("en", "ru"): mapping = Self.enToRu
        case ("ru", "en"): mapping = Self.ruToEn
        default: return 0.0
        }

        let mappable = text.filter { mapping[$0] != nil || $0.isNumber || $0 == " " || $0 == "-" }.count
        return Double(mappable) / Double(max(1, text.count))
    }
}
