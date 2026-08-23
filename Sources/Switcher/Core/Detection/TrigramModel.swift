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
        // Верхняя граница обязательна: size приходит из файла без проверок, а
        // size*size*size переполняет Int раньше, чем сработает guard ниже, и
        // процесс падает по trap вместо честной ошибки. Реальные алфавиты — 28 и 34.
        guard size >= 2, size <= 256 else { throw TrigramModelError.truncated }
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
    /// Ведущие и хвостовые символы вне алфавита обрезаются перед оценкой.
    /// Это нужно для реального сценария: слово, набранное не в той раскладке,
    /// после обратной конверсии может получить знак препинания на границе —
    /// например, «hello.», где точка получилась из конвертированной «ю».
    /// Без обрезки такое слово вообще не оценивалось бы (см. guard по
    /// алфавиту ниже), и детектор пропускал бы весь класс слов со знаками
    /// препинания на конце. ВНУТРЕННИЕ символы вне алфавита не трогаем —
    /// именно они отличают "k.,jdm" («любовь», буквы на клавишах знаков
    /// препинания) от обычного слова и уводят решение детектора в отдельную
    /// ветку (абсолютная оценка цели вместо разницы моделей).
    ///
    /// - Parameter terminated: `true` — слово дописано (`^^слово^`),
    ///   `false` — оценивается префикс (`^^сло`), концевой маркер не добавляется.
    /// - Returns: `nil`, если слово короче двух символов (после обрезки границ)
    ///   или содержит внутри символы вне алфавита модели — такое слово этой
    ///   модели не принадлежит.
    public func meanLogProb(_ word: String, terminated: Bool) -> Double? {
        var lower = Substring(word.lowercased())
        while let first = lower.first, indexOf[first] == nil { lower = lower.dropFirst() }
        while let last = lower.last, indexOf[last] == nil { lower = lower.dropLast() }
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

    /// Посегментная оценка слова: то же самое `meanLogProb`, но применённое
    /// по частям, если внутри слова есть символы вне алфавита.
    ///
    /// `meanLogProb` выше специально возвращает `nil` при ЛЮБОМ внутреннем
    /// символе вне алфавита — это часть его контракта (см. doc-комментарий
    /// там), на нём держится ветка `absoluteTarget` у `LayoutDetector`, и его
    /// менять нельзя. Но этот же guard делает неоцениваемым целый класс
    /// реальных слов: адрес сайта («yandex.ru», «google.com») или обычное
    /// предложение со знаком препинания ВНУТРИ слова — не только на границе,
    /// для которой уже есть отдельная обрезка.
    ///
    /// Здесь слово режется по символам вне алфавита на сегменты, каждый
    /// сегмент от двух символов оценивается отдельно тем же `meanLogProb`, и
    /// результаты усредняются с весом по длине сегмента — иначе короткий
    /// хвост после точки (например «ru» у «yandex.ru») получил бы тот же вес,
    /// что и длинная содержательная часть перед ней. Завершающий маркер
    /// (`terminated`) применяется только к ПОСЛЕДНЕМУ сегменту: только он
    /// граничит с настоящим концом слова, а не со знаком препинания внутри.
    ///
    /// Замер (3938 положительных, 8000 отрицательных, половина отрицательных
    /// с доменными окончаниями .ru/.com/.org) — см. doc-комментарий
    /// `DetectorThresholds.calibrated`.
    ///
    /// - Returns: `nil`, если НИ ОДИН сегмент не набрал двух символов
    ///   (например «a.b» — оба куска короче двух букв) — такое слово нечем
    ///   оценить даже посегментно.
    public func meanLogProbBySegments(_ word: String, terminated: Bool) -> Double? {
        let lower = word.lowercased()
        let segments = lower.split(whereSeparator: { indexOf[$0] == nil })
        guard !segments.isEmpty else { return nil }

        var weightedTotal = 0.0
        var totalWeight = 0.0
        let lastIndex = segments.count - 1
        for (i, segment) in segments.enumerated() {
            guard segment.count >= 2 else { continue }
            let segmentTerminated = terminated && i == lastIndex
            guard let score = meanLogProb(String(segment), terminated: segmentTerminated) else { continue }
            let weight = Double(segment.count)
            weightedTotal += score * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        return weightedTotal / totalWeight
    }
}
