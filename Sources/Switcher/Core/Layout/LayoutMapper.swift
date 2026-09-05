import CoreGraphics
import Foundation

/// Переносит текст между раскладками через физические клавиши.
///
/// Символ ищется в исходной таблице, из неё берётся клавиша, и по той же клавише
/// берётся символ целевой таблицы. Никаких зашитых таблиц соответствий: всё
/// выводится из данных реально установленных раскладок.
public final class LayoutMapper {

    private let tables: [Layout: KeyboardLayoutTable]

    /// Символы, не зависящие от раскладки: проходят насквозь.
    private static let layoutIndependent = CharacterSet(charactersIn: "0123456789-_ ")

    public init(tables: [Layout: KeyboardLayoutTable]) {
        self.tables = tables
    }

    /// Возвращает nil, если хотя бы один символ отобразить не удалось —
    /// частичная конверсия хуже, чем отсутствие конверсии.
    ///
    /// Обратный поиск клавиши по символу неоднозначен при коллизии (один
    /// символ доступен с двух физических клавиш): `KeyboardLayoutTable`
    /// детерминированно берёт клавишу с меньшим keyCode. Если реальное
    /// нажатие пришло с другой клавиши, результат может отличаться от
    /// `transpose(strokes:to:)` — тот путь надёжнее, так как использует
    /// keyCode нажатия напрямую, без обратного поиска.
    public func transpose(_ text: String, from: Layout, to: Layout) -> String? {
        guard let source = tables[from], let target = tables[to] else { return nil }

        var result = ""
        result.reserveCapacity(text.count)

        for char in text {
            if char.unicodeScalars.allSatisfy({ Self.layoutIndependent.contains($0) }) {
                result.append(char)
                continue
            }
            guard let stroke = source.keyCode(for: char),
                  let mapped = target.character(keyCode: stroke.keyCode, shift: stroke.shift)
            else { return nil }
            result.append(mapped)
        }
        return result
    }

    /// Мягкий режим — для конвертации ВЫДЕЛЕНИЯ, а не автозамены.
    ///
    /// Отличие от строгого `transpose(_:from:to:)` выше: там неотображаемый
    /// символ отменяет всю конверсию (nil) — это правильно для автозамены,
    /// где лучше не сработать, чем испортить слово. Для выделения это не
    /// годится: пользователь мог выделить что угодно — пробелы, цифры,
    /// пунктуацию, переводы строк, эмодзи, буквы третьего языка — и всё это
    /// обязано остаться на месте, а не отменять конверсию остального текста.
    /// Поэтому здесь неотображаемое просто проходит насквозь, а не сбоит.
    public func transposeSoft(_ text: String, from: Layout, to: Layout) -> String {
        guard let source = tables[from], let target = tables[to] else { return text }

        var result = ""
        result.reserveCapacity(text.count)

        for char in text {
            if let stroke = source.keyCode(for: char),
               let mapped = target.character(keyCode: stroke.keyCode, shift: stroke.shift) {
                result.append(mapped)
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// Отрисовывает записанные нажатия в целевой раскладке.
    /// Точнее строкового пути: keycode известен напрямую, обратный поиск не нужен —
    /// поэтому при коллизии обратного маппинга (см. `transpose(_:from:to:)`) этот
    /// метод даёт корректный результат, а строковый путь может ошибиться.
    public func transpose(strokes: [KeyStroke], to: Layout) -> String? {
        guard let target = tables[to] else { return nil }

        var result = ""
        result.reserveCapacity(strokes.count)

        for stroke in strokes {
            if let mapped = target.character(keyCode: stroke.keyCode, shift: stroke.shift) {
                result.append(mapped)
            } else if stroke.char.unicodeScalars.allSatisfy({ Self.layoutIndependent.contains($0) }) {
                result.append(stroke.char)
            } else {
                return nil
            }
        }
        return result
    }
}
