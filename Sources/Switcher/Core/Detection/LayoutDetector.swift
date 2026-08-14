import Foundation

/// Что заставило детектор проснуться.
public enum Trigger: Sendable {
    /// Пользователь нажал пробел или знак препинания — слово дописано.
    case wordBoundary
    /// Пауза в наборе: слово, скорее всего, дописано, но подтверждения нет.
    case pause
    /// Каждый символ: оценивается недописанный префикс.
    case early
}

public enum Verdict: Equatable, Sendable {
    case keep
    case convert(to: Layout, text: String)
}

/// Источник словарной проверки. Отделён протоколом, чтобы детектор
/// оставался чистой функцией и тестировался без системных словарей.
public protocol WordValidating: AnyObject {
    func isValid(_ word: String, in layout: Layout) -> Bool
}

/// Пороги разницы log10-правдоподобия на триграмму.
///
/// Значения получены прогоном `testPrintThresholdSweep` по корпусу
/// `layoutDetectorCorpus`. Менять их вручную не нужно:
/// пересобрал модель — перезапусти sweep и подставь новую точку.
public struct DetectorThresholds: Sendable {
    public var wordBoundary: Double
    public var pause: Double
    public var early: Double
    public var earlyMinLength: Int
    /// Порог для случая, когда слово вообще не оценивается моделью текущего
    /// языка. Так бывает, когда в слове есть знаки препинания: "k.,jdm" — это
    /// «любовь», и точка с запятой здесь буквы. Английская модель такое слово
    /// оценить не может, поэтому разницу считать не с чем и решение
    /// принимается по абсолютной оценке целевого языка.
    ///
    /// Это не краевой случай: через этот путь проходят все русские слова
    /// с б, ю, ж, э, х, ъ — по замерам 15% корпуса.
    public var absoluteTarget: Double

    public init(wordBoundary: Double, pause: Double, early: Double,
                earlyMinLength: Int, absoluteTarget: Double) {
        self.wordBoundary   = wordBoundary
        self.pause          = pause
        self.early          = early
        self.earlyMinLength = earlyMinLength
        self.absoluteTarget = absoluteTarget
    }

    /// Замерено прогоном `testPrintThresholdSweep` по корпусу из ~90 слов
    /// (см. task-6-report.md за полными таблицами):
    ///
    ///   delta          +0.3 → FP 0.00%  FN 0.00%
    ///                  +0.5 → FP 0.00%  FN 2.00%   ← wordBoundary, pause
    ///                  +1.2 → FP 0.00%  FN 10.00%  ← early (строже намеренно)
    ///
    /// Для absoluteTarget маленький корпус задачи не даёт достаточно
    /// отрицательных примеров (английских слов со знаком препинания на
    /// конце), поэтому порог перемерен отдельно на популяциях 794
    /// положительных (русские слова, чья английская форма содержит знаки
    /// препинания) и 6000 отрицательных примеров:
    ///
    ///   порог    FP%    FN%
    ///   -1.80    1.40   0.00
    ///   -1.70    1.02   0.00
    ///   -1.60    0.70   0.00   ← оптимум при FN=0
    ///   -1.50    0.47   0.38
    ///   -1.40    0.23   1.01
    ///
    /// Классы перекрываются, идеального порога не существует: худшие
    /// отрицательные примеры — реальные английские слова, чья форма в
    /// другой раскладке тоже оказывается реальным русским словом ("bye."
    /// → "иную" даёт -1.04, "here." → "рукую" даёт -1.06). Это тот же
    /// принципиальный конфликт, что и на ветке delta, только для случая,
    /// когда сравнивать не с чем. -1.6 выбран как точка нулевого FN с
    /// минимальным FP среди таких точек.
    public static let calibrated = DetectorThresholds(
        wordBoundary: 0.5,
        pause: 0.5,
        early: 1.2,
        earlyMinLength: 5,
        absoluteTarget: -1.6
    )
}

/// Решает, набрано ли слово в неверной раскладке.
///
/// Чистая функция от слова, текущей раскладки и повода: никакого состояния,
/// никакого ввода-вывода, никаких обращений к AX. Благодаря этому вся логика
/// детекции покрывается офлайн-тестами.
public final class LayoutDetector {

    private let models: [Layout: TrigramModel]
    private let mapper: LayoutMapper
    private let validator: WordValidating?
    private let thresholds: DetectorThresholds

    public init(
        models: [Layout: TrigramModel],
        mapper: LayoutMapper,
        validator: WordValidating?,
        thresholds: DetectorThresholds = .calibrated
    ) {
        self.models     = models
        self.mapper     = mapper
        self.validator  = validator
        self.thresholds = thresholds
    }

    public func evaluate(word: String, currentLayout: Layout, trigger: Trigger) -> Verdict {
        let target = currentLayout.opposite

        if trigger == .early, word.count < thresholds.earlyMinLength { return .keep }

        // Слово, признанное словарём текущего языка, не трогаем никогда.
        // Статистика может ошибиться на редком слове, словарь — нет.
        if let validator, validator.isValid(word, in: currentLayout) { return .keep }

        let terminated = trigger != .early
        guard let converted = mapper.transpose(word, from: currentLayout, to: target),
              let targetModel = models[target],
              let targetScore = targetModel.meanLogProb(converted, terminated: terminated)
        else { return .keep }

        let threshold: Double
        switch trigger {
        case .wordBoundary: threshold = thresholds.wordBoundary
        case .pause:        threshold = thresholds.pause
        case .early:        threshold = thresholds.early
        }

        if let currentScore = models[currentLayout]?.meanLogProb(word, terminated: terminated) {
            guard targetScore - currentScore > threshold else { return .keep }
        } else {
            // Модель текущего языка слово не оценивает — например, в нём есть
            // знаки препинания, стоящие в позициях букв другой раскладки.
            // Сравнивать не с чем, поэтому судим по абсолютной оценке цели.
            guard targetScore > thresholds.absoluteTarget else { return .keep }
        }
        return .convert(to: target, text: converted)
    }

    /// Насколько правдоподобнее слово выглядит в противоположной раскладке.
    /// Положительное значение — в пользу конверсии. `nil`, если хотя бы одна
    /// сторона не оценивается. `internal` ради калибровочного теста.
    func delta(word: String, currentLayout: Layout, terminated: Bool) -> Double? {
        let target = currentLayout.opposite
        guard let currentModel = models[currentLayout],
              let targetModel  = models[target],
              let converted    = mapper.transpose(word, from: currentLayout, to: target),
              let currentScore = currentModel.meanLogProb(word, terminated: terminated),
              let targetScore  = targetModel.meanLogProb(converted, terminated: terminated)
        else { return nil }
        return targetScore - currentScore
    }

    /// Абсолютная оценка слова в целевом языке после транспонирования.
    /// `internal` ради калибровочного теста.
    func targetScore(word: String, currentLayout: Layout, terminated: Bool) -> Double? {
        let target = currentLayout.opposite
        guard let targetModel = models[target],
              let converted = mapper.transpose(word, from: currentLayout, to: target)
        else { return nil }
        return targetModel.meanLogProb(converted, terminated: terminated)
    }
}
