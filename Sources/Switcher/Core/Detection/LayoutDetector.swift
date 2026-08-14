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
    ///   absoluteTarget -1.50 → FP 0.00%  FN 1.86%   ← 3765 положительных
    ///                  -1.60 → FP 0.07%  FN 0.50%      и 3001 отрицательный
    ///                  -1.70 → FP 0.23%  FN 0.21%
    ///                  -1.80 → FP 0.40%  FN 0.08%
    ///
    /// Замер сделан ПОСЛЕ обрезки границ слова в TrigramModel: до неё почти вся
    /// отрицательная популяция сидела в этой ветке, а после — ушла в delta, где
    /// обрабатывается надёжнее. Отрицательные здесь синтетические (знак препинания
    /// вставлен ВНУТРЬ английского слова: "l.ittle", "w.here") — так почти никто
    /// не печатает, поэтому фактический FP ещё ниже измеренного.
    ///
    /// Классы всё равно перекрываются, идеального порога не существует: часть
    /// английских слов в другой раскладке даёт настоящие русские. Это та же
    /// принципиальная неоднозначность, что и в delta-ветке; частично снимается
    /// контекстом соседних слов (Task 6b).
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
    private let prior: LanguagePrior?
    private let thresholds: DetectorThresholds

    public init(
        models: [Layout: TrigramModel],
        mapper: LayoutMapper,
        validator: WordValidating?,
        prior: LanguagePrior? = nil,
        thresholds: DetectorThresholds = .calibrated
    ) {
        self.models     = models
        self.mapper     = mapper
        self.validator  = validator
        self.prior      = prior
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

        // Контекст соседних слов сдвигает порог: там, где одно слово
        // неразрешимо, язык предыдущих слов — единственный сигнал.
        let effective = threshold - (prior?.bonus(forConverting: target) ?? 0)

        if let currentScore = models[currentLayout]?.meanLogProb(word, terminated: terminated) {
            guard targetScore - currentScore > effective else { return .keep }
        } else {
            // Модель текущего языка слово не оценивает — например, в нём есть
            // знаки препинания, стоящие в позициях букв другой раскладки.
            // Сравнивать не с чем, поэтому судим по абсолютной оценке цели.
            guard targetScore > thresholds.absoluteTarget - (prior?.bonus(forConverting: target) ?? 0)
            else { return .keep }
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
