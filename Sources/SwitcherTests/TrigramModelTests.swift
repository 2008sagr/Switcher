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

let trigramModelTests: [TestCase] = [
    TestCase("testLoadsBundledModels", testLoadsBundledModels),
    TestCase("testRealWordScoresHigherThanGibberish", testRealWordScoresHigherThanGibberish),
    TestCase("testWrongLayoutTextScoresLowInSourceLanguage", testWrongLayoutTextScoresLowInSourceLanguage),
    TestCase("testReturnsNilForForeignCharacters", testReturnsNilForForeignCharacters),
    TestCase("testReturnsNilForTooShortWord", testReturnsNilForTooShortWord),
    TestCase("testPrefixScoringIgnoresWordEnd", testPrefixScoringIgnoresWordEnd),
    TestCase("testIsCaseInsensitive", testIsCaseInsensitive),
    TestCase("testRejectsBadMagic", testRejectsBadMagic)
]
