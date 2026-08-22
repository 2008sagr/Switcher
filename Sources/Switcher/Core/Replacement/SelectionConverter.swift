import Foundation

/// Чистая логика конвертации ВЫДЕЛЕННОГО текста по двойному Shift.
///
/// Отдельный файл от `SwitchCoordinator` намеренно: всё, что здесь, не
/// трогает AX, буфер обмена или TIS — только строки и `LayoutMapper`,
/// поэтому тестируется офлайн, без системы. Координатор (чтение выделения,
/// Cmd+C/Cmd+V, запись обратно, смена раскладки) — отдельная зона
/// ответственности, живёт в `SwitchCoordinator`.
enum SelectionConverter {

    /// Выделение длиннее этого — не трогаем. Случайное «выделить всё» в
    /// большом документе не должно подвешивать конвертацию посимвольным
    /// проходом по всему файлу.
    static let maxLength = 10_000

    /// Определяет НАПРАВЛЕНИЕ конвертации — раскладку, В КОТОРУЮ нужно
    /// перевести текст (не текущую раскладку выделения).
    ///
    /// Правило: если кириллица составляет БОЛЬШЕ половины букв выделения —
    /// текст считается русским, набранным на английской раскладке, и цель —
    /// английский. Иначе (включая ровно половину и чисто латинский текст) —
    /// цель русский. В знаменателе — все буквы (Character.isLetter), не
    /// только кириллица и латиница: буква третьего алфавита учитывается как
    /// "не кириллица" и сдвигает решение в сторону "иначе".
    ///
    /// Посимвольное решение "каждый символ конвертировать по своему
    /// алфавиту" сознательно отвергнуто (см. отчёт): на смешанном тексте
    /// оно даёт непредсказуемый, рвущийся на куски результат — а тут нужно
    /// одно решение на всё выделение сразу.
    ///
    /// nil — в выделении нет ни одной буквы (только цифры/пунктуация/пробелы/
    /// эмодзи): конвертировать нечего, действие ничего не делает.
    static func direction(for text: String) -> Layout? {
        var letters = 0
        var cyrillic = 0
        for char in text where char.isLetter {
            letters += 1
            if isCyrillic(char) { cyrillic += 1 }
        }
        guard letters > 0 else { return nil }
        return cyrillic * 2 > letters ? .en : .ru
    }

    /// Собирает итоговое решение: направление + сама конвертация (мягкий
    /// режим `LayoutMapper.transposeSoft` — пробелы, цифры, переводы строк и
    /// прочее, что не отображается ни в одной раскладке, проходят насквозь).
    /// nil — либо в выделении нет букв (см. direction(for:)), либо оно
    /// длиннее maxLength.
    static func plan(for text: String, mapper: LayoutMapper) -> (target: Layout, converted: String)? {
        guard text.count <= maxLength else { return nil }
        guard let target = direction(for: text) else { return nil }
        let converted = mapper.transposeSoft(text, from: target.opposite, to: target)
        return (target, converted)
    }

    /// Кириллический блок Unicode (U+0400–U+04FF) — а-я/А-Я, ё/Ё и
    /// расширенные кириллические буквы. Символ — по первому unicode scalar:
    /// для букв, которые реально печатаются с клавиатуры, этого достаточно
    /// (составные графемы здесь не встречаются).
    private static let cyrillicRange: ClosedRange<UInt32> = 0x0400...0x04FF

    private static func isCyrillic(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return cyrillicRange.contains(scalar.value)
    }
}
