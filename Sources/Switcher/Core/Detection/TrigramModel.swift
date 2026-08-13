import Foundation

public enum TrigramModelError: Error {
    case badMagic
    case truncated
    case resourceMissing(Layout)
}

/// Символьная триграммная модель языка.
///
/// Хранит плотную таблицу log10 P(c₂ | c₀c₁), поэтому оценка слова — это
/// арифметика по прямым индексам, без поиска и без аллокаций.
/// Формат ресурса описан в плане (STG2).
public final class TrigramModel {

    private let alphabetSize: Int
    private let indexOf: [Character: Int]
    private let probs: [Float]

    /// Индекс маркера границы слова — всегда 0.
    private static let boundaryIndex = 0

    public init(data: Data) throws {
        guard data.count >= 8, data[data.startIndex..<data.startIndex + 4] == Data("STG2".utf8) else {
            throw TrigramModelError.badMagic
        }

        let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        let alphabetBytes = size * 4
        let probsCount    = size * size * size
        guard data.count == 8 + alphabetBytes + probsCount * 4 else {
            throw TrigramModelError.truncated
        }

        var table: [Character: Int] = [:]
        var values = [Float](repeating: 0, count: probsCount)

        data.withUnsafeBytes { raw in
            for i in 0..<size {
                let scalarValue = raw.loadUnaligned(fromByteOffset: 8 + i * 4, as: UInt32.self)
                if let scalar = Unicode.Scalar(scalarValue) {
                    table[Character(scalar)] = i
                }
            }
            let base = 8 + alphabetBytes
            for i in 0..<probsCount {
                values[i] = raw.loadUnaligned(fromByteOffset: base + i * 4, as: Float.self)
            }
        }

        alphabetSize = size
        indexOf      = table
        probs        = values
    }

    public static func bundled(_ layout: Layout) throws -> TrigramModel {
        guard let url = Bundle.module.url(forResource: layout.rawValue, withExtension: "trigram") else {
            throw TrigramModelError.resourceMissing(layout)
        }
        return try TrigramModel(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Средний log10 условной вероятности по триграммам слова.
    ///
    /// Нормировка на количество триграмм убирает перекос в пользу коротких слов:
    /// без неё длинное слово всегда проигрывало бы короткому.
    ///
    /// - Parameter terminated: `true` — слово дописано (`^^слово^`),
    ///   `false` — оценивается префикс (`^^сло`), концевой маркер не добавляется.
    /// - Returns: `nil`, если слово короче двух символов или содержит символы
    ///   вне алфавита модели — такое слово этой модели не принадлежит.
    public func meanLogProb(_ word: String, terminated: Bool) -> Double? {
        let lower = word.lowercased()
        guard lower.count >= 2 else { return nil }

        var ids = [Self.boundaryIndex, Self.boundaryIndex]
        ids.reserveCapacity(lower.count + 3)
        for char in lower {
            guard let index = indexOf[char], index != Self.boundaryIndex else { return nil }
            ids.append(index)
        }
        if terminated { ids.append(Self.boundaryIndex) }

        var total = 0.0
        let count = ids.count - 2
        for i in 0..<count {
            let offset = ids[i] * alphabetSize * alphabetSize
                       + ids[i + 1] * alphabetSize
                       + ids[i + 2]
            total += Double(probs[offset])
        }
        return total / Double(count)
    }
}
