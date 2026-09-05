import CoreGraphics
import Foundation

/// Снимок слова: сами нажатия, их текстовое представление и завершающий разделитель.
public struct WordSnapshot: Equatable {
    public let strokes: [KeyStroke]
    public let text:    String
    /// Разделитель, завершивший слово (" ", ","), либо "" если слово не дописано.
    public let tail:    String

    /// Длина в UTF-16 — именно так считаются диапазоны Accessibility.
    public var textUTF16Length: Int { text.utf16.count }
    public var tailUTF16Length: Int { tail.utf16.count }
}

/// Копит нажатия текущего слова.
///
/// Хранит `KeyStroke`, а не символы: keycode нужен, чтобы переиграть нажатия
/// в другой раскладке (стратегия замены B). Никакой логики детекции здесь нет,
/// никаких таймеров — только память.
public final class KeystrokeBuffer {

    private var strokes: [KeyStroke] = []
    private let maxLength: Int

    public init(maxLength: Int = 50) {
        self.maxLength = maxLength
    }

    public func append(_ stroke: KeyStroke) {
        // Переполнение — признак кода, JSON или бессмысленно длинного ввода.
        // Начинаем слово заново, а не растим буфер.
        if strokes.count >= maxLength { strokes.removeAll(keepingCapacity: true) }
        strokes.append(stroke)
    }

    public func backspace() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
    }

    public func reset() {
        strokes.removeAll(keepingCapacity: true)
    }

    public var currentWord: WordSnapshot? {
        snapshot(tail: "")
    }

    /// Завершает слово разделителем и очищает буфер.
    /// Возвращает nil, если копить было нечего.
    public func wordEndedBy(_ stroke: KeyStroke) -> WordSnapshot? {
        defer { reset() }
        return snapshot(tail: String(stroke.char))
    }

    private func snapshot(tail: String) -> WordSnapshot? {
        guard !strokes.isEmpty else { return nil }
        let text = String(strokes.map(\.char))
        // Последовательность без букв (числа, знаки) словом не считаем.
        guard text.contains(where: { $0.isLetter }) else { return nil }
        return WordSnapshot(strokes: strokes, text: text, tail: tail)
    }
}
