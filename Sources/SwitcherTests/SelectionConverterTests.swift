import Foundation
@testable import SwitcherCore

// MARK: - direction(for:)

func testDirectionPicksEnglishForMajorityCyrillic() throws {
    XCTAssertEqual(SelectionConverter.direction(for: "привет"), .en)
}

func testDirectionPicksRussianForMajorityLatin() throws {
    XCTAssertEqual(SelectionConverter.direction(for: "hello"), .ru)
}

func testDirectionPicksEnglishForMixedTextWithCyrillicMajority() throws {
    // 6 кириллических букв против 2 латинских — явное большинство.
    XCTAssertEqual(SelectionConverter.direction(for: "привет hi"), .en)
}

func testDirectionPicksRussianForMixedTextWithLatinMajority() throws {
    XCTAssertEqual(SelectionConverter.direction(for: "hello world при"), .ru)
}

/// Ровно половина кириллицы — это не "больше половины", поэтому решение
/// уходит в ветку "иначе" (en → ru), а не в отдельную "неопределённую" ветку.
func testDirectionPicksRussianOnExactHalfSplit() throws {
    XCTAssertEqual(SelectionConverter.direction(for: "ab яч"), .ru)
}

func testDirectionReturnsNilWhenNoLetters() throws {
    XCTAssertNil(SelectionConverter.direction(for: "123 456 !!! --- \n\t"))
}

func testDirectionIgnoresDigitsAndPunctuationInRatio() throws {
    // Буквы только кириллические — цифры и пунктуация в знаменатель не входят.
    XCTAssertEqual(SelectionConverter.direction(for: "при123, !!!"), .en)
}

// MARK: - plan(for:mapper:) — лимит длины и итоговая конвертация

private func trivialMapper() -> LayoutMapper {
    let enMap: [UInt32: Character] = [UInt32(1) << 1: "a"]
    let ruMap: [UInt32: Character] = [UInt32(1) << 1: "ф"]
    return LayoutMapper(tables: [.en: KeyboardLayoutTable(map: enMap),
                                 .ru: KeyboardLayoutTable(map: ruMap)])
}

func testPlanRejectsSelectionLongerThanLimit() throws {
    let tooLong = String(repeating: "a", count: SelectionConverter.maxLength + 1)
    XCTAssertNil(SelectionConverter.plan(for: tooLong, mapper: trivialMapper()))
}

func testPlanAcceptsSelectionAtExactLimit() throws {
    let atLimit = String(repeating: "a", count: SelectionConverter.maxLength)
    XCTAssertNotNil(SelectionConverter.plan(for: atLimit, mapper: trivialMapper()))
}

func testPlanReturnsConvertedTextAndTarget() throws {
    let plan = try XCTUnwrap(SelectionConverter.plan(for: "a", mapper: trivialMapper()))
    XCTAssertEqual(plan.target, .ru)
    XCTAssertEqual(plan.converted, "ф")
}

func testPlanReturnsNilWhenSelectionHasNoLetters() throws {
    XCTAssertNil(SelectionConverter.plan(for: "123 !!!", mapper: trivialMapper()))
}

let selectionConverterTests: [TestCase] = [
    TestCase("testDirectionPicksEnglishForMajorityCyrillic", testDirectionPicksEnglishForMajorityCyrillic),
    TestCase("testDirectionPicksRussianForMajorityLatin", testDirectionPicksRussianForMajorityLatin),
    TestCase("testDirectionPicksEnglishForMixedTextWithCyrillicMajority", testDirectionPicksEnglishForMixedTextWithCyrillicMajority),
    TestCase("testDirectionPicksRussianForMixedTextWithLatinMajority", testDirectionPicksRussianForMixedTextWithLatinMajority),
    TestCase("testDirectionPicksRussianOnExactHalfSplit", testDirectionPicksRussianOnExactHalfSplit),
    TestCase("testDirectionReturnsNilWhenNoLetters", testDirectionReturnsNilWhenNoLetters),
    TestCase("testDirectionIgnoresDigitsAndPunctuationInRatio", testDirectionIgnoresDigitsAndPunctuationInRatio),
    TestCase("testPlanRejectsSelectionLongerThanLimit", testPlanRejectsSelectionLongerThanLimit),
    TestCase("testPlanAcceptsSelectionAtExactLimit", testPlanAcceptsSelectionAtExactLimit),
    TestCase("testPlanReturnsConvertedTextAndTarget", testPlanReturnsConvertedTextAndTarget),
    TestCase("testPlanReturnsNilWhenSelectionHasNoLetters", testPlanReturnsNilWhenSelectionHasNoLetters)
]
