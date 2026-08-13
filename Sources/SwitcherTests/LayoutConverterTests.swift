@testable import SwitcherCore

func testRoundTripConversion() throws {
    let converter = LayoutConverter()
    let original = "hello"
    let ru = converter.convert(original, fromLanguage: "en", toLanguage: "ru")
    XCTAssertFalse(ru.isEmpty, "RU conversion should not be empty")
    let back = converter.convert(ru, fromLanguage: "ru", toLanguage: "en")
    XCTAssertEqual(back, original, "Round-trip conversion should return original word")
}

func testStrictModeUnmappable() throws {
    let converter = LayoutConverter()
    let resultStrict = converter.convert("@", fromLanguage: "en", toLanguage: "ru", strict: true)
    XCTAssertEqual(resultStrict, "", "Strict mode should return empty string for unmappable chars")
    let resultLenient = converter.convert("@", fromLanguage: "en", toLanguage: "ru", strict: false)
    XCTAssertEqual(resultLenient, "@", "Lenient mode should pass through unmappable chars")
}

let layoutConverterTests: [TestCase] = [
    TestCase("testRoundTripConversion", testRoundTripConversion),
    TestCase("testStrictModeUnmappable", testStrictModeUnmappable)
]
