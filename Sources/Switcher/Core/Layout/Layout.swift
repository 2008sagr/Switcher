import CoreGraphics

/// Раскладка, с которой работает Switcher. Только EN и RU.
public enum Layout: String, Sendable {
    case en
    case ru

    public var opposite: Layout { self == .en ? .ru : .en }

    /// Разбор кода языка из TIS ("en-US", "ru", "ru-RU").
    public init?(languageCode: String) {
        switch languageCode.prefix(2).lowercased() {
        case "en": self = .en
        case "ru": self = .ru
        default:   return nil
        }
    }
}

/// Одно нажатие: физическая клавиша, состояние Shift и символ, который в итоге попал в текст.
/// Храним keycode, а не только символ — это позволяет переиграть нажатия в другой раскладке.
public struct KeyStroke: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let shift:   Bool
    public let char:    Character

    public init(keyCode: CGKeyCode, shift: Bool, char: Character) {
        self.keyCode = keyCode
        self.shift   = shift
        self.char    = char
    }
}
