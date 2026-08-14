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

/// Ранний порог строже: на границе слова он не должен ловить меньше, чем ранний.
func testEarlyTriggerIsStricterThanWordBoundary() throws {
    _ = try makeFixture()
    XCTAssertGreaterThan(DetectorThresholds.calibrated.early,
                         DetectorThresholds.calibrated.wordBoundary)
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

/// Отдельная проверка самой ветки absoluteTarget: слово, где символы вне
/// алфавита стоят ВНУТРИ, обрезкой границ не спасается и оценке английской
/// моделью не поддаётся — значит решение принимается по абсолютной оценке цели.
func testInternalPunctuationKeepsWordUnscorableInSourceLanguage() throws {
    let (_, mapper) = try makeFixture()
    let en = try TrigramModel.bundled(.en)
    for word in ["любовь", "объезд", "съезд", "подъезд"] {
        let typed = try XCTUnwrap(mapper.transpose(word, from: .ru, to: .en))
        XCTAssertNil(en.meanLogProb(typed, terminated: true),
                     "\(typed): внутренняя пунктуация делает слово неоцениваемым")
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

func testEarlyTriggerRejectsShortPrefixes() throws {
    let (detector, mapper) = try makeFixture()
    guard let typed = mapper.transpose("привет", from: .ru, to: .en) else {
        return XCTFail("Транспонирование должно работать")
    }
    let shortPrefix = String(typed.prefix(4))
    XCTAssertEqual(detector.evaluate(word: shortPrefix, currentLayout: .en, trigger: .early), .keep,
                   "Префикс короче earlyMinLength оценивать нельзя")
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

let layoutDetectorCalibrationTests: [TestCase] = [
    TestCase("testNoFalsePositivesOnCorrectlyTypedWords", testNoFalsePositivesOnCorrectlyTypedWords),
    TestCase("testCatchesWrongLayoutWords", testCatchesWrongLayoutWords),
    TestCase("testEarlyTriggerIsStricterThanWordBoundary", testEarlyTriggerIsStricterThanWordBoundary),
    TestCase("testCatchesWordsWithPunctuationPositionedLetters", testCatchesWordsWithPunctuationPositionedLetters),
    TestCase("testInternalPunctuationKeepsWordUnscorableInSourceLanguage", testInternalPunctuationKeepsWordUnscorableInSourceLanguage),
    TestCase("testDoesNotTouchEnglishWordsWithTrailingPunctuation", testDoesNotTouchEnglishWordsWithTrailingPunctuation),
    TestCase("testEarlyTriggerRejectsShortPrefixes", testEarlyTriggerRejectsShortPrefixes),
    TestCase("testWordValidInCurrentLanguageIsNeverConverted", testWordValidInCurrentLanguageIsNeverConverted),
    TestCase("testPrintThresholdSweep", testPrintThresholdSweep)
]
