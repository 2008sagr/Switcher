import Carbon
import CoreGraphics
import Foundation

/// Таблица соответствий «физическая клавиша ↔ символ» для одной раскладки.
///
/// Строится из данных `kTISPropertyUnicodeKeyLayoutData` реального источника ввода,
/// поэтому корректно описывает и «Русскую», и «Русскую — ПК», у которых знаки
/// препинания стоят на разных клавишах.
public struct KeyboardLayoutTable {

    /// Ключ: keyCode << 1 | shift
    private let forward: [UInt32: Character]
    private let reverse: [Character: (keyCode: CGKeyCode, shift: Bool)]

    public init(map: [UInt32: Character]) {
        forward = map
        var rev: [Character: (CGKeyCode, Bool)] = [:]
        // Меньший keyCode выигрывает: даёт стабильный результат независимо
        // от порядка обхода словаря.
        for (key, char) in map.sorted(by: { $0.key < $1.key }) where rev[char] == nil {
            rev[char] = (CGKeyCode(key >> 1), key & 1 == 1)
        }
        reverse = rev
    }

    public func character(keyCode: CGKeyCode, shift: Bool) -> Character? {
        forward[UInt32(keyCode) << 1 | (shift ? 1 : 0)]
    }

    public func keyCode(for char: Character) -> (keyCode: CGKeyCode, shift: Bool)? {
        reverse[char]
    }

    /// Прогоняет все клавиши основного блока через `UCKeyTranslate`.
    /// Возвращает nil, если данные раскладки непригодны (например, у источника
    /// ввода это IME, а не keyboard layout).
    public static func load(layoutData: Data, keyboardType: UInt32) -> KeyboardLayoutTable? {
        // Основной буквенно-цифровой блок. Модификаторы, функциональные клавиши
        // и цифровую панель не включаем — они не участвуют в наборе слов.
        let keyCodes: [CGKeyCode] = Array(0...50)
        var map: [UInt32: Character] = [:]

        let ok = layoutData.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            for code in keyCodes {
                for shift in [false, true] {
                    // Биты модификаторов в UCKeyTranslate — это старший байт
                    // EventRecord.modifiers, сдвинутый вправо на 8.
                    let modifierState: UInt32 = shift ? UInt32(shiftKey >> 8) : 0
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)

                    let status = UCKeyTranslate(
                        layout,
                        UInt16(code),
                        UInt16(kUCKeyActionDown),
                        modifierState,
                        keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        chars.count,
                        &length,
                        &chars
                    )
                    guard status == noErr, length == 1,
                          let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let char = Character(scalar)
                    // Управляющие символы (Return, Tab, Escape) не нужны.
                    guard !char.isNewline, !char.unicodeScalars.contains(where: { $0.value < 0x20 })
                    else { continue }
                    map[UInt32(code) << 1 | (shift ? 1 : 0)] = char
                }
            }
            return true
        }

        guard ok, !map.isEmpty else { return nil }
        return KeyboardLayoutTable(map: map)
    }
}
