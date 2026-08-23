import Foundation

/// Что заставило детектор проснуться.
///
/// Единственный повод — `wordBoundary`. Раньше были ещё `early` (оценка на
/// каждый символ) и `pause` (оценка после паузы в наборе) — оба убраны
/// намеренно, а не по недосмотру, и обратно их включать нельзя не подумав.
///
/// Причина: префикс русского слова статистически неотличим от целого
/// русского слова — это не вопрос калибровки порога, а свойство самой
/// триграммной модели. Замер (детектор на реальном коде, не гипотеза):
///
///   ghjdthrf → «проверка»
///        ghjd    (4 симв.) pause  → «пров»
///        ghjdt   (5 симв.) early  → «прове»   ← уверенно конвертируется
///        ghjdth  (6 симв.) early  → «провер»
///   ghbdtn → «привет»
///        ghbd    (4 симв.) pause  → «прив»
///        ghbdt   (5 симв.) early  → «приве»   ← уверенно конвертируется
///   dctulf → «всегда»
///        dctul   (5 симв.) early  → «всегд»   ← уверенно конвертируется
///
/// «прове» выглядит для модели ровно так же правдоподобно, как «слово» —
/// оба целые с точки зрения триграмм. Пользователь печатает `ghjdt` (ещё не
/// дописал «проверка»), ранний триггер конвертирует префикс в «прове» и
/// переключает раскладку, а остаток «hrf» падает уже в русскую — каша.
/// Короткие слова (например «rfr», 3 символа) этой беды избегали случайно:
/// они короче minWordLength (4) и до раннего/паузного триггера просто не
/// добирались — отсюда симптом «понимает rfr, но не понимает ghjdthrf».
///
/// Калибровка порогов (`DetectorThresholds.calibrated`) делалась на ЦЕЛЫХ
/// словах и была слепа к этому сценарию: подобрать порог, отличающий
/// недописанный префикс от целого слова, нельзя в принципе — статистика
/// префикса и статистика слова с этой длиной неразличимы. Единственная
/// рабочая защита — не оценивать префиксы вообще, то есть конвертировать
/// только на границе слова.
public enum Trigger: Sendable {
    /// Пользователь нажал пробел, Enter или иной завершающий слово символ —
    /// слово дописано. Единственный повод для оценки, см. комментарий выше.
    case wordBoundary
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
    /// Порог для случая, когда слово вообще не оценивается моделью текущего
    /// языка. Так бывает, когда в слове есть знаки препинания: "k.,jdm" — это
    /// «любовь», и точка с запятой здесь буквы. Английская модель такое слово
    /// оценить не может, поэтому разницу считать не с чем и решение
    /// принимается по абсолютной оценке целевого языка.
    ///
    /// Это не краевой случай: через этот путь проходят все русские слова
    /// с б, ю, ж, э, х, ъ — по замерам 15% корпуса.
    ///
    /// С переходом на посегментную оценку (`meanLogProbBySegments`, см.
    /// подробный комментарий у `calibrated` ниже) эта ветка СУЗИЛАСЬ: раньше
    /// в неё попадало любое слово с внутренней пунктуацией, раз целиком его
    /// было нечем оценить. Теперь оцениваются и сегменты от двух символов —
    /// ветка достижима, только если НИ ОДИН сегмент typed-строки не набрал
    /// двух символов (например «a.b»: сегменты «a» и «b» по одному символу).
    /// Слово вроде «заём» (typed "pf§v", сегмент "pf" длиной 2) раньше шло
    /// этой веткой, а после фикса оценивается веткой delta — это не потеря,
    /// а расширение детекции: раньше такое слово требовало языкового
    /// контекста, чтобы вообще заметиться, теперь распознаётся само по себе.
    public var absoluteTarget: Double

    public init(wordBoundary: Double, absoluteTarget: Double) {
        self.wordBoundary   = wordBoundary
        self.absoluteTarget = absoluteTarget
    }

    /// Замерено прогоном `testPrintThresholdSweep` по корпусу из ~90 слов
    /// (см. task-6-report.md за полными таблицами):
    ///
    ///   delta          +0.3 → FP 0.00%  FN 0.00%
    ///                  +0.5 → FP 0.00%  FN 1.47%   ← wordBoundary
    ///
    /// (популяция ветки delta — 68 слов корпуса после обрезки границ в
    /// TrigramModel: было ~50 до фикса f78d89b, часть слов с пунктуацией на
    /// границе — например "hello." — стала оцениваемой и перешла в эту ветку)
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
    ///
    /// --- Посегментная оценка (фикс: слова с пунктуацией ВНУТРИ не
    /// исправлялись вовсе) ---
    ///
    /// Баг: targetModel.meanLogProb() возвращает nil, если внутри слова есть
    /// символ вне алфавита — это часть его контракта (см. doc-комментарий
    /// там). Обрезка снимает только ВЕДУЩИЕ и ХВОСТОВЫЕ символы, поэтому
    /// «yandex.ru» (точка ВНУТРИ, не на границе) вообще не оценивался, и
    /// evaluate() выходил на первый guard с .keep, даже не дойдя до сравнения
    /// раскладок. Пользовательский симптом — адреса сайтов, набранные не в
    /// той раскладке, не исправлялись никогда.
    ///
    /// Фикс — `TrigramModel.meanLogProbBySegments`: слово режется по
    /// символам вне алфавита на сегменты, каждый сегмент от двух символов
    /// оценивается отдельно, результаты усредняются с весом по длине
    /// сегмента. `evaluate()` переведён на него на ОБЕИХ сторонах — текущей
    /// и целевой. Старый `meanLogProb` не тронут: у него отдельный контракт
    /// (nil при любой внутренней пунктуации) и отдельные тесты, на нём
    /// по-прежнему держится сам факт существования ветки absoluteTarget —
    /// см. её комментарий ниже про то, как она теперь сузилась.
    ///
    /// Замер (3938 положительных — русские слова, набранные в английской
    /// раскладке; 8000 отрицательных — правильно набранные английские слова,
    /// половина с доменными окончаниями .ru/.com/.org, чтобы отдельно
    /// проверить именно этот класс ложных срабатываний):
    ///
    ///   порог   FP%    FN%
    ///   +0.4    0.00   1.22
    ///   +0.5    0.00   1.52   ← wordBoundary, не менялся
    ///   +0.6    0.00   1.90
    ///
    /// Разделение классов: минимум среди положительных 1% = +0.34, максимум
    /// среди отрицательных = +0.37, медианы +2.49 (положительные) и −2.02
    /// (отрицательные) — классы разделены с запасом, порог 0.5 остаётся
    /// корректным для посегментной оценки без изменений, FP нулевой.
    ///
    /// `pause` (0.5) и `early` (1.2, earlyMinLength 5) были здесь до фикса
    /// преждевременной конверсии (см. doc-комментарий у `Trigger`) — убраны
    /// вместе с самими триггерами, а не просто занулены, чтобы неиспользуемое
    /// поле не намекало, что триггеры можно вернуть настройкой значения.
    public static let calibrated = DetectorThresholds(
        wordBoundary: 0.5,
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

    // `trigger` в сигнатуре — на будущее (контракт с вызывающей стороной,
    // покрыт её тестами) и для симметрии с `Trigger`, у которого сейчас
    // ровно один случай, `wordBoundary`; сама оценка от него больше не
    // ветвится — режим префикса (terminated: false) убран вместе с early/
    // pause, см. doc-комментарий у `Trigger`.
    public func evaluate(word: String, currentLayout: Layout, trigger: Trigger) -> Verdict {
        let target = currentLayout.opposite

        // Слово, признанное словарём текущего языка, не трогаем никогда.
        // Статистика может ошибиться на редком слове, словарь — нет.
        if let validator, validator.isValid(word, in: currentLayout) { return .keep }

        guard let converted = mapper.transpose(word, from: currentLayout, to: target),
              let targetModel = models[target],
              let targetScore = targetModel.meanLogProbBySegments(converted, terminated: true)
        else { return .keep }

        // Контекст соседних слов сдвигает порог: там, где одно слово
        // неразрешимо, язык предыдущих слов — единственный сигнал.
        let effective = thresholds.wordBoundary - (prior?.bonus(forConverting: target) ?? 0)

        if let currentScore = models[currentLayout]?.meanLogProbBySegments(word, terminated: true) {
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
