import Foundation
@testable import SwitcherCore

func testLoadsBundledModels() throws {
    XCTAssertNoThrow(try TrigramModel.bundled(.en))
    XCTAssertNoThrow(try TrigramModel.bundled(.ru))
}

func testRealWordScoresHigherThanGibberish() throws {
    let ru = try TrigramModel.bundled(.ru)
    let real = try XCTUnwrap(ru.meanLogProb("привет", terminated: true))
    let junk = try XCTUnwrap(ru.meanLogProb("ывапрол", terminated: true))
    XCTAssertGreaterThan(real, junk)

    let en = try TrigramModel.bundled(.en)
    let realEn = try XCTUnwrap(en.meanLogProb("hello", terminated: true))
    let junkEn = try XCTUnwrap(en.meanLogProb("ghbdtn", terminated: true))
    XCTAssertGreaterThan(realEn, junkEn)
}

func testWrongLayoutTextScoresLowInSourceLanguage() throws {
    let en = try TrigramModel.bundled(.en)
    let ru = try TrigramModel.bundled(.ru)
    // "ghbdtn" — это «привет», набранное в английской раскладке.
    let asEnglish = try XCTUnwrap(en.meanLogProb("ghbdtn", terminated: true))
    let asRussian = try XCTUnwrap(ru.meanLogProb("привет", terminated: true))
    XCTAssertGreaterThan(asRussian - asEnglish, 1.0,
                         "Разрыв должен быть уверенным, а не пограничным")
}

func testReturnsNilForForeignCharacters() throws {
    let en = try TrigramModel.bundled(.en)
    XCTAssertNil(en.meanLogProb("привет", terminated: true))
    XCTAssertNil(en.meanLogProb("he11o", terminated: true))
}

func testReturnsNilForTooShortWord() throws {
    let en = try TrigramModel.bundled(.en)
    XCTAssertNil(en.meanLogProb("a", terminated: true))
}

func testPrefixScoringIgnoresWordEnd() throws {
    let ru = try TrigramModel.bundled(.ru)
    let prefix = try XCTUnwrap(ru.meanLogProb("прив", terminated: false))
    let whole  = try XCTUnwrap(ru.meanLogProb("прив", terminated: true))
    // "прив^" — неестественный конец слова, поэтому целиком оценивается хуже.
    XCTAssertGreaterThan(prefix, whole)
}

func testIsCaseInsensitive() throws {
    let ru = try TrigramModel.bundled(.ru)
    XCTAssertEqual(ru.meanLogProb("Привет", terminated: true),
                   ru.meanLogProb("привет", terminated: true))
}

func testRejectsBadMagic() throws {
    XCTAssertThrowsError(try TrigramModel(data: Data("XXXX".utf8)))
}

/// Заголовок с огромным размером алфавита обязан дать ошибку, а не уронить
/// процесс: size*size*size переполняет Int раньше проверки на усечённость.
func testRejectsOversizedAlphabetWithoutCrashing() throws {
    var data = Data("STG2".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(0xC000_0000).littleEndian) { Array($0) })
    data.append(Data(repeating: 0, count: 64))
    XCTAssertThrowsError(try TrigramModel(data: data))
}

/// Верная магия и правдоподобный алфавит, но данных после заголовка не хватает.
func testRejectsTruncatedData() throws {
    var data = Data("STG2".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(28).littleEndian) { Array($0) })
    data.append(Data(repeating: 0, count: 28 * 4))   // алфавит есть, таблицы нет
    XCTAssertThrowsError(try TrigramModel(data: data))
}

/// Знак препинания на конце не должен мешать оценке: без обрезки границ
/// английские слова со знаком препинания не оценивались вовсе.
func testTrimsBoundaryPunctuation() throws {
    let en = try TrigramModel.bundled(.en)
    let plain = try XCTUnwrap(en.meanLogProb("hello", terminated: true))
    let dotted = try XCTUnwrap(en.meanLogProb("hello.", terminated: true))
    XCTAssertEqual(plain, dotted, accuracy: 0.0001)
    // Внутренние символы вне алфавита по-прежнему делают слово неоцениваемым:
    // на этом держится ветка absoluteTarget.
    XCTAssertNil(en.meanLogProb("k.,jdm", terminated: true))
}

/// Внутренняя пунктуация — это то, что делает ветку absoluteTarget у
/// LayoutDetector достижимой: пока слово с такими символами нельзя оценить
/// моделью исходного языка, сравнивать не с чем, и решение принимается по
/// абсолютной оценке цели (см. LayoutDetector.swift). В отличие от
/// testTrimsBoundaryPunctuation, здесь символ вне алфавита стоит ВНУТРИ
/// слова, а не на границе — обрезка его не убирает.
///
/// Перенесено из LayoutDetectorCalibrationTests: там тест сидел в наборе
/// детектора, но не вызывал detector.evaluate() вообще — утверждал
/// поведение TrigramModel, а не детектора. Это характеризация модели, ей
/// место здесь. Формы — реальное транспонирование ru→en раскладкой
/// «Русская — ПК» (получены прогоном LayoutMapper, см. task-6-report.md).
func testInternalPunctuationKeepsWordUnscorable() throws {
    let en = try TrigramModel.bundled(.en)
    let cases: [(typed: String, original: String)] = [
        ("k.,jdm", "любовь"), ("j,]tpl", "объезд"), ("c]tpl", "съезд"), ("gjl]tpl", "подъезд")
    ]
    for (typed, original) in cases {
        XCTAssertNil(en.meanLogProb(typed, terminated: true),
                     "\(typed) («\(original)»): внутренняя пунктуация делает слово неоцениваемым")
    }
}

let trigramModelTests: [TestCase] = [
    TestCase("testLoadsBundledModels", testLoadsBundledModels),
    TestCase("testRealWordScoresHigherThanGibberish", testRealWordScoresHigherThanGibberish),
    TestCase("testWrongLayoutTextScoresLowInSourceLanguage", testWrongLayoutTextScoresLowInSourceLanguage),
    TestCase("testReturnsNilForForeignCharacters", testReturnsNilForForeignCharacters),
    TestCase("testReturnsNilForTooShortWord", testReturnsNilForTooShortWord),
    TestCase("testPrefixScoringIgnoresWordEnd", testPrefixScoringIgnoresWordEnd),
    TestCase("testIsCaseInsensitive", testIsCaseInsensitive),
    TestCase("testRejectsBadMagic", testRejectsBadMagic),
    TestCase("testRejectsOversizedAlphabetWithoutCrashing", testRejectsOversizedAlphabetWithoutCrashing),
    TestCase("testRejectsTruncatedData", testRejectsTruncatedData),
    TestCase("testTrimsBoundaryPunctuation", testTrimsBoundaryPunctuation),
    TestCase("testInternalPunctuationKeepsWordUnscorable", testInternalPunctuationKeepsWordUnscorable)
]
