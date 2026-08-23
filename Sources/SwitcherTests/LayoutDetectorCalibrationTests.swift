import Carbon
import Foundation
@testable import SwitcherCore

/// Калибровка: измеряем ложные срабатывания и пропуски на корпусе из
/// настоящих слов и их транспонированных версий.

/// Собирает детектор и маппер из живых системных раскладок.
/// Пропускает набор, если нужных раскладок нет — вместо падения процесса.
private func makeFixture() throws -> (detector: LayoutDetector, mapper: LayoutMapper) {
    guard let enData = systemLayoutData(matching: "com.apple.keylayout.US"),
          let ruData = systemLayoutData(matching: "com.apple.keylayout.RussianWin"),
          let en = KeyboardLayoutTable.load(layoutData: enData, keyboardType: UInt32(LMGetKbdType())),
          let ru = KeyboardLayoutTable.load(layoutData: ruData, keyboardType: UInt32(LMGetKbdType()))
    else { throw XCTSkip("Нужны раскладки США и «Русская — ПК»") }

    let mapper = LayoutMapper(tables: [.en: en, .ru: ru])
    let detector = LayoutDetector(
        models: [.en: try TrigramModel.bundled(.en), .ru: try TrigramModel.bundled(.ru)],
        mapper: mapper,
        validator: nil   // калибруем чистую статистику, без словаря
    )
    return (detector, mapper)
}

/// Корпус: частотные слова обоих языков.
///
/// Русская часть намеренно насыщена буквами б, ю, ж, э, х, ъ — они стоят
/// на клавишах знаков препинания, и такие слова идут по ветке
/// absoluteTarget, а не delta. По замерам это 15% реального потока.
///
/// Английская часть содержит слова с завершающим знаком препинания: это
/// единственная популяция, способная дать ложное срабатывание на ветке
/// absoluteTarget, поэтому без них порог не откалибровать.
///
/// «эхо» намеренно исключено: три буквы короче minWordLength (по умолчанию
/// 4), детектор такое слово в реальной работе никогда не увидит.
let layoutDetectorCorpus: [(String, Layout)] = {
    let en = ["hello", "world", "please", "keyboard", "switch", "layout", "message",
              "computer", "language", "problem", "morning", "already", "between",
              "because", "different", "important", "something", "together", "without",
              "government", "development", "information", "experience", "understand",
              "test", "code", "file", "name", "time", "work", "make", "know", "think",
              "hello.", "world,", "please.", "message,", "computer.", "already,",
              "because.", "something,", "together.", "without,", "don't", "it's"]
    let ru = ["привет", "спасибо", "пожалуйста", "клавиатура", "раскладка", "сообщение",
              "компьютер", "проблема", "сегодня", "который", "человек", "работа",
              "например", "поэтому", "всегда", "любовь", "объявление", "подъезд",
              "съёмка", "жёлтый", "ёлка", "юность", "яблоко", "здравствуйте",
              "хорошо", "время", "место", "слово", "может", "будет", "очень",
              "объезд", "жизнь", "съезд", "хожу", "бюджет", "художник",
              "изъян", "объём", "жюри", "энергия", "хобби", "юбилей"]
    return en.map { ($0, Layout.en) } + ru.map { ($0, Layout.ru) }
}()

/// Настоящие слова, набранные правильно, трогать нельзя.
func testNoFalsePositivesOnCorrectlyTypedWords() throws {
    let (detector, _) = try makeFixture()
    var falsePositives: [String] = []
    for (word, layout) in layoutDetectorCorpus {
        if case .convert = detector.evaluate(word: word, currentLayout: layout, trigger: .wordBoundary) {
            falsePositives.append("\(word) [\(layout.rawValue)]")
        }
    }
    let rate = Double(falsePositives.count) / Double(layoutDetectorCorpus.count)
    XCTAssertLessThan(rate, 0.02,
                      "Ложных срабатываний \(falsePositives.count)/\(layoutDetectorCorpus.count): \(falsePositives.prefix(15))")
}

/// Слова, набранные не в той раскладке, должны исправляться.
func testCatchesWrongLayoutWords() throws {
    let (detector, mapper) = try makeFixture()
    var misses: [String] = []
    var total = 0
    for (word, layout) in layoutDetectorCorpus {
        // Имитируем набор слова при активной противоположной раскладке.
        guard let typed = mapper.transpose(word, from: layout, to: layout.opposite) else { continue }
        total += 1
        guard case .convert(let to, let text) = detector.evaluate(
            word: typed, currentLayout: layout.opposite, trigger: .wordBoundary
        ), to == layout, text == word else {
            misses.append("\(typed) → ожидали \(word)")
            continue
        }
    }
    let rate = Double(misses.count) / Double(total)
    XCTAssertLessThan(rate, 0.10,
                      "Пропусков \(misses.count)/\(total): \(misses.prefix(15))")
}

/// Русские слова, где буквы стоят на клавишах знаков препинания.
/// «любовь» в английской раскладке содержит "." и ",", поэтому английская
/// модель его не оценивает — решение принимается по абсолютной оценке цели.
///
/// Только слова от 4 букв: короче до детектора не доходит — их отсекает
/// guard по minWordLength (по умолчанию 4). Ставить порог под трёхбуквенное
/// «эхо» (-1.66) значило бы подгонять модель под случай, которого в работе
/// не бывает.
func testCatchesWordsWithPunctuationPositionedLetters() throws {
    let (detector, mapper) = try makeFixture()
    for word in ["любовь", "объезд", "жизнь", "съезд", "подъезд"] {
        let typed = try XCTUnwrap(mapper.transpose(word, from: .ru, to: .en),
                                  "\(word): транспонирование должно работать")
        // Проверяем ПОВЕДЕНИЕ, а не то, какой веткой детектор к нему пришёл.
        // У «жизнь» → ";bpym" буква на клавише препинания стоит на границе
        // слова, обрезка её убирает, и решение принимается по delta, а не по
        // absoluteTarget. Ответ от этого не меняется, и привязываться к
        // механизму здесь нельзя.
        XCTAssertEqual(detector.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                       .convert(to: .ru, text: word),
                       "\(typed) должно исправляться в «\(word)»")
    }
}

/// Настоящие английские слова с точкой на конце трогать нельзя.
func testDoesNotTouchEnglishWordsWithTrailingPunctuation() throws {
    let (detector, _) = try makeFixture()
    for word in ["hello.", "world,", "please.", "message,"] {
        XCTAssertEqual(detector.evaluate(word: word, currentLayout: .en, trigger: .wordBoundary),
                       .keep, "\(word) — обычное английское слово со знаком препинания")
    }
}

func testWordValidInCurrentLanguageIsNeverConverted() throws {
    let (_, mapper) = try makeFixture()
    final class AlwaysValid: WordValidating {
        func isValid(_ word: String, in layout: Layout) -> Bool { true }
    }
    let strict = LayoutDetector(
        models: [.en: try TrigramModel.bundled(.en), .ru: try TrigramModel.bundled(.ru)],
        mapper: mapper,
        validator: AlwaysValid()
    )
    XCTAssertEqual(strict.evaluate(word: "ghbdtn", currentLayout: .en, trigger: .wordBoundary), .keep)
}

/// Печатает таблицу FP/FN по сетке порогов. Не ассертит — это инструмент
/// для выбора DetectorThresholds.calibrated при изменении модели.
func testPrintThresholdSweep() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["SWITCHER_SWEEP"] == "1",
                      "Запуск: SWITCHER_SWEEP=1 swift run SwitcherTests testPrintThresholdSweep")
    let (detector, mapper) = try makeFixture()

    // Сетка порога разницы: слова, оцениваемые обеими моделями.
    print("=== delta ===")
    print("порог\tFP%\tFN%")
    for step in stride(from: 0.0, through: 2.0, by: 0.1) {
        var fp = 0, fn = 0, total = 0
        for (word, layout) in layoutDetectorCorpus {
            guard let correct = detector.delta(word: word, currentLayout: layout, terminated: true)
            else { continue }
            total += 1
            if correct > step { fp += 1 }
            if let typed = mapper.transpose(word, from: layout, to: layout.opposite),
               let wrong = detector.delta(word: typed, currentLayout: layout.opposite, terminated: true),
               wrong <= step {
                fn += 1
            }
        }
        guard total > 0 else { continue }
        print(String(format: "%.1f\t%.2f\t%.2f", step,
                     100.0 * Double(fp) / Double(total),
                     100.0 * Double(fn) / Double(total)))
    }

    // Сетка абсолютного порога: слова, которые модель текущего языка
    // оценить не может (знаки препинания в позициях букв).
    print("=== absoluteTarget ===")
    print("порог\tFP%\tFN%")
    for step in stride(from: -3.0, through: -0.5, by: 0.1) {
        var fp = 0, fn = 0, total = 0
        for (word, layout) in layoutDetectorCorpus {
            guard detector.delta(word: word, currentLayout: layout, terminated: true) == nil,
                  let correct = detector.targetScore(word: word, currentLayout: layout, terminated: true)
            else { continue }
            total += 1
            if correct > step { fp += 1 }
            if let typed = mapper.transpose(word, from: layout, to: layout.opposite),
               let wrong = detector.targetScore(word: typed, currentLayout: layout.opposite, terminated: true),
               wrong <= step {
                fn += 1
            }
        }
        guard total > 0 else { continue }
        print(String(format: "%.1f\t%.2f\t%.2f", step,
                     100.0 * Double(fp) / Double(total),
                     100.0 * Double(fn) / Double(total)))
    }
}

/// Контекст решает там, где одно слово нерешаемо.
/// «руки» набранное в английской раскладке даёт "herb": delta ≈ +0.25,
/// ниже порога 0.5 — без контекста слово останется английским.
/// После трёх русских слов эффективный порог падает до 0.0 и слово
/// исправляется.
func testContextResolvesAmbiguousWord() throws {
    let models: [Layout: TrigramModel] = [.en: try TrigramModel.bundled(.en),
                                          .ru: try TrigramModel.bundled(.ru)]
    let (_, mapper) = try makeFixture()
    let typed = try XCTUnwrap(mapper.transpose("руки", from: .ru, to: .en))

    let without = LayoutDetector(models: models, mapper: mapper, validator: nil)
    XCTAssertEqual(without.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                   .keep, "Без контекста слово на грани оставляем как есть")

    let prior = LanguagePrior(capacity: 3, weight: 0.5)
    for _ in 0..<3 { prior.record(.ru) }
    let with = LayoutDetector(models: models, mapper: mapper, validator: nil, prior: prior)
    XCTAssertEqual(with.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                   .convert(to: .ru, text: "руки"),
                   "Русский контекст должен склонять решение в пользу русского")
}

/// Контекст не должен ломать смешанный текст: частотное английское слово
/// остаётся английским даже посреди русского.
///
/// «if» добавлено отдельно от остальных: его delta ≈ −0.41 (замерено sweep'ом
/// по корпусу задачи) — ближе к сдвинутому порогу 0.0, чем у любого другого
/// слова набора («here» ≈ −0.44, у остальных четырёх от −1.19 до −2.01). Без
/// него тест не заметил бы, например, ошибочно завышенный вес приоритета:
/// слова с запасом в единицы log10-правдоподобия останутся «keep» почти при
/// любом разумном сдвиге порога, а «if» — нет.
func testContextDoesNotBreakCommonEnglishWordInRussianText() throws {
    let models: [Layout: TrigramModel] = [.en: try TrigramModel.bundled(.en),
                                          .ru: try TrigramModel.bundled(.ru)]
    let (_, mapper) = try makeFixture()
    let prior = LanguagePrior(capacity: 3, weight: 0.5)
    for _ in 0..<3 { prior.record(.ru) }
    let detector = LayoutDetector(models: models, mapper: mapper, validator: nil, prior: prior)
    for word in ["here", "the", "code", "file", "test", "if"] {
        XCTAssertEqual(detector.evaluate(word: word, currentLayout: .en, trigger: .wordBoundary),
                       .keep, "«\(word)» — частотное английское слово, контекст его не перебивает")
    }
}

/// Приоритет обязан применяться и в ветке absoluteTarget, а не только в
/// ветке delta — через absoluteTarget идут все русские слова с буквами
/// б, ю, ж, э, х, ъ, ё (по замерам — 15% реального потока), и regression,
/// убирающий вычитание bonus именно в этой строке, testContextResolvesAmbiguousWord
/// не поймает: там слово «руки» вообще не задевает эту ветку.
///
/// «заём» набранное в английской раскладке даёт "pf§v": «ё» стоит внутри
/// слова, поэтому английская модель его не оценивает (delta == nil), и
/// решение принимается по абсолютной оценке цели — targetScore ≈ −1.96.
/// Без контекста порог −1.6, −1.96 его не превышает → keep. Полный русский
/// контекст сдвигает порог до −1.6 − 0.5 = −2.1, а −1.96 > −2.1 → convert.
/// Найдено sweep'ом по расширенному списку слов с внутренними
/// б/ю/ж/э/х/ъ/ё (подробности подбора — в task-6b-report.md,
/// «Фикс-раунд 1»).
/// Слово для этого теста подобрано заново после перехода на посегментную
/// оценку. Раньше здесь стояло «заём» (typed "pf§v"): под старым meanLogProb
/// currentScore был nil (внутри "ё" вне алфавита), решение шло веткой
/// absoluteTarget. С посегментной оценкой у "pf§v" сегмент "pf" — уже 2
/// символа и оценивается, currentScore стал НЕ nil, и слово переехало в
/// ветку delta (там оно конвертируется уже БЕЗ контекста — сам по себе
/// признак того, что фикс расширил, а не сузил, детекцию). Год для этого
/// теста слово нужно другое: такое, где currentScore посегментно
/// по-прежнему nil (ни один сегмент typed-строки не набирает двух символов).
///
/// «тюл» (ткань) ↔ typed "n.k": оба сегмента ("n", "k") длиной 1, currentScore
/// nil, targetScore ≈ -1.67 — между -1.6 (порог без контекста, keep) и -2.1
/// (порог с полным русским контекстом, convert). Подобрано перебором по
/// всем typed-строкам вида «буква,пунктуация,буква» с проверкой этого
/// диапазона (см. отчёт).
func testContextAppliesToAbsoluteTargetBranch() throws {
    let models: [Layout: TrigramModel] = [.en: try TrigramModel.bundled(.en),
                                          .ru: try TrigramModel.bundled(.ru)]
    let (_, mapper) = try makeFixture()
    let typed = try XCTUnwrap(mapper.transpose("тюл", from: .ru, to: .en))

    let without = LayoutDetector(models: models, mapper: mapper, validator: nil)
    XCTAssertEqual(without.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                   .keep, "Без контекста слово в ветке absoluteTarget остаётся как есть")

    let prior = LanguagePrior(capacity: 3, weight: 0.5)
    for _ in 0..<3 { prior.record(.ru) }
    let with = LayoutDetector(models: models, mapper: mapper, validator: nil, prior: prior)
    XCTAssertEqual(with.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                   .convert(to: .ru, text: "тюл"),
                   "Русский контекст должен сдвигать и абсолютный порог тоже")
}

/// РЕГРЕССИЯ на причину, по которой ранний и паузный триггеры убраны
/// совсем (см. doc-комментарий у `Trigger`), а не перекалиброваны с более
/// строгим порогом.
///
/// Это не гипотеза — воспроизводит замер, которым баг был найден. Слова
/// ниже — недописанные префиксы реальных русских слов, набранные при
/// активной английской раскладке (то есть то, что реально лежит в буфере
/// в момент, когда старый ранний триггер срабатывал бы на каждый символ):
///
///   ghjdthrf → «проверка»: префиксы ghjd (4 симв.), ghjdt (5), ghjdth (6)
///   ghbdtn   → «привет»:   префикс  ghbdt (5)
///   dctulf   → «всегда»:   префикс  dctul (5)
///
/// Тест проверяет `delta(..., terminated: false)` — ровно тот режим оценки
/// префикса, которым пользовался бывший early-триггер, — и требует, чтобы
/// значение уверенно превышало `wordBoundary` (0.5, порог для ДОПИСАННЫХ
/// слов). Замеренные значения (см. отчёт): ghjd 3.07, ghjdt 2.97,
/// ghjdth 2.53, ghbdt 2.46, dctul 1.66 — все в разы выше 0.5. Порог здесь
/// не занижен и не завышен: он вообще не пропускной — модель искренне
/// считает недописанный префикс дописанным правдоподобным словом, потому
/// что статистика триграмм префикса неотличима от статистики целого слова
/// такой же длины. Значит калибровкой порога (сколь угодно строгого) эту
/// проблему не решить в принципе — защититься можно только не оценивая
/// префиксы вообще, то есть конвертируя исключительно на границе слова.
func testUnterminatedPrefixesScoreAsConfidentlyAsWholeWords() throws {
    let (detector, _) = try makeFixture()
    // (набранный префикс, сколько букв от целого слова)
    let prefixes: [(typed: String, of: String)] = [
        ("ghjd",   "проверка"),  // «пров»
        ("ghjdt",  "проверка"),  // «прове»
        ("ghjdth", "проверка"),  // «провер»
        ("ghbdt",  "привет"),    // «приве»
        ("dctul",  "всегда"),    // «всегд»
    ]
    for (typed, whole) in prefixes {
        let delta = try XCTUnwrap(
            detector.delta(word: typed, currentLayout: .en, terminated: false),
            "\(typed): модель должна оценивать префикс — иначе тест не о том"
        )
        XCTAssertGreaterThan(delta, DetectorThresholds.calibrated.wordBoundary,
            "\(typed) (префикс «\(whole)») набирает delta \(delta), что выше порога для " +
            "ЦЕЛЫХ слов (\(DetectorThresholds.calibrated.wordBoundary)) — префикс неотличим " +
            "от дописанного слова, поэтому единственная защита — не оценивать префиксы")
    }
}

/// Адреса сайтов, набранные не в той раскладке. Раньше слово вообще не
/// доходило до сравнения раскладок: targetModel.meanLogProb(converted, ...)
/// возвращал nil на точке ВНУТРИ слова ("yandex.ru", "google.com"), и первый
/// же guard в evaluate() уводил решение в .keep. Посегментная оценка режет
/// слово по неалфавитным символам и оценивает куски "yandex"/"ru",
/// "google"/"com" по отдельности.
func testConvertsWebsiteAddressesWithInternalPunctuation() throws {
    let (detector, mapper) = try makeFixture()
    let cases: [(domain: String, typed: String)] = [
        ("yandex.ru", "нфтвучюкг"),
        ("google.com", "пщщпдуюсщь"),
    ]
    for (domain, expectedTyped) in cases {
        let typed = try XCTUnwrap(mapper.transpose(domain, from: .en, to: .ru),
                                  "\(domain): транспонирование должно работать")
        XCTAssertEqual(typed, expectedTyped,
                       "\(domain): ожидали конкретную транспонированную форму из замера")
        XCTAssertEqual(detector.evaluate(word: typed, currentLayout: .ru, trigger: .wordBoundary),
                       .convert(to: .en, text: domain),
                       "\(typed) должно исправляться в «\(domain)»")
    }
}

/// Регрессия на переход evaluate() на посегментную оценку: слова с
/// пунктуацией, набранные ВЕРНО (не в чужой раскладке), по-прежнему нельзя
/// трогать. "don't" уже не задевает сегментацию — апостроф входит в
/// английский алфавит модели, — но включён явно, чтобы фиксировать это.
func testDoesNotTouchCorrectlyTypedWordsWithPunctuationAfterSegmentedScoringFix() throws {
    let (detector, _) = try makeFixture()
    XCTAssertEqual(detector.evaluate(word: "hello.", currentLayout: .en, trigger: .wordBoundary),
                   .keep, "«hello.» — верно набранное английское слово")
    XCTAssertEqual(detector.evaluate(word: "world,", currentLayout: .en, trigger: .wordBoundary),
                   .keep, "«world,» — верно набранное английское слово")
    XCTAssertEqual(detector.evaluate(word: "don't", currentLayout: .en, trigger: .wordBoundary),
                   .keep, "«don't» — апостроф входит в алфавит, сегментация тут ни при чём")
    XCTAssertEqual(detector.evaluate(word: "привет.", currentLayout: .ru, trigger: .wordBoundary),
                   .keep, "«привет.» — верно набранное русское слово")
}

/// Ветка absoluteTarget не исчезла с переходом на посегментную оценку —
/// сузилась. Раньше в неё попадало любое слово с внутренней пунктуацией,
/// раз modели текущего языка целиком было нечем оценивать. Теперь
/// meanLogProbBySegments оценивает и сегменты ≥2 символов тоже, так что
/// ветка достижима только когда НИ ОДИН сегмент не набирает двух символов —
/// например "a.b" (сегменты "a" и "b" по одному символу).
///
/// Тест проверяет это на живом мэппере: "a.b", набранное при английской
/// раскладке, — не настоящее русское слово ни в каком смысле, но
/// демонстрирует механизм — currentScore (en) не оценивается вообще,
/// targetScore (ru, транспонированная гиббериш-строка без внутренней
/// пунктуации) оценивается и оказывается ниже порога, поэтому решение —
/// .keep, принятое именно веткой absoluteTarget, а не первым guard'ом.
func testAbsoluteTargetBranchReachableOnlyWhenNoSegmentReachesMinimumLength() throws {
    let (detector, mapper) = try makeFixture()
    let en = try TrigramModel.bundled(.en)
    let ru = try TrigramModel.bundled(.ru)

    XCTAssertNil(en.meanLogProbBySegments("a.b", terminated: true),
                "currentScore обязан быть nil — иначе решение приняла бы ветка delta, а не absoluteTarget")

    let converted = try XCTUnwrap(mapper.transpose("a.b", from: .en, to: .ru),
                                  "транспонирование не должно падать на коротких сегментах")
    XCTAssertNotNil(ru.meanLogProbBySegments(converted, terminated: true),
                    "targetScore обязан быть НЕ nil — иначе evaluate() вышел бы на самом первом guard'е, а не на absoluteTarget")

    XCTAssertEqual(detector.evaluate(word: "a.b", currentLayout: .en, trigger: .wordBoundary), .keep,
                   "«a.b» — не русское слово, absoluteTarget должен оставить его как есть")
}

let layoutDetectorCalibrationTests: [TestCase] = [
    TestCase("testNoFalsePositivesOnCorrectlyTypedWords", testNoFalsePositivesOnCorrectlyTypedWords),
    TestCase("testCatchesWrongLayoutWords", testCatchesWrongLayoutWords),
    TestCase("testCatchesWordsWithPunctuationPositionedLetters", testCatchesWordsWithPunctuationPositionedLetters),
    TestCase("testDoesNotTouchEnglishWordsWithTrailingPunctuation", testDoesNotTouchEnglishWordsWithTrailingPunctuation),
    TestCase("testWordValidInCurrentLanguageIsNeverConverted", testWordValidInCurrentLanguageIsNeverConverted),
    TestCase("testPrintThresholdSweep", testPrintThresholdSweep),
    TestCase("testContextResolvesAmbiguousWord", testContextResolvesAmbiguousWord),
    TestCase("testContextDoesNotBreakCommonEnglishWordInRussianText", testContextDoesNotBreakCommonEnglishWordInRussianText),
    TestCase("testContextAppliesToAbsoluteTargetBranch", testContextAppliesToAbsoluteTargetBranch),
    TestCase("testUnterminatedPrefixesScoreAsConfidentlyAsWholeWords", testUnterminatedPrefixesScoreAsConfidentlyAsWholeWords),
    TestCase("testConvertsWebsiteAddressesWithInternalPunctuation", testConvertsWebsiteAddressesWithInternalPunctuation),
    TestCase("testDoesNotTouchCorrectlyTypedWordsWithPunctuationAfterSegmentedScoringFix", testDoesNotTouchCorrectlyTypedWordsWithPunctuationAfterSegmentedScoringFix),
    TestCase("testAbsoluteTargetBranchReachableOnlyWhenNoSegmentReachesMinimumLength", testAbsoluteTargetBranchReachableOnlyWhenNoSegmentReachesMinimumLength)
]
