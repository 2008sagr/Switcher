import Carbon
@testable import SwitcherCore

/// Собирает маппер из живых системных раскладок.
/// Возвращает nil, если русская раскладка не установлена.
private func systemMapper(ruLayoutID: String) -> LayoutMapper? {
    guard let enData = systemLayoutData(matching: "com.apple.keylayout.US"),
          let ruData = systemLayoutData(matching: ruLayoutID),
          let en = KeyboardLayoutTable.load(layoutData: enData, keyboardType: UInt32(LMGetKbdType())),
          let ru = KeyboardLayoutTable.load(layoutData: ruData, keyboardType: UInt32(LMGetKbdType()))
    else { return nil }
    return LayoutMapper(tables: [.en: en, .ru: ru])
}

func testTransposesLettersOnRussianPC() throws {
    guard let mapper = systemMapper(ruLayoutID: "com.apple.keylayout.RussianWin") else {
        throw XCTSkip("Раскладка «Русская — ПК» не установлена")
    }
    XCTAssertEqual(mapper.transpose("ghbdtn", from: .en, to: .ru), "привет")
    XCTAssertEqual(mapper.transpose("привет", from: .ru, to: .en), "ghbdtn")
}

/// Ключевая проверка: слова со знаками препинания в позиции букв.
/// «любовь» на ПК-раскладке набирается как "k.,jdm", а на «Русской» — иначе.
/// Обе должны отработать без хардкода таблицы.
func testTransposesPunctuationPositionedLetters() throws {
    for layoutID in ["com.apple.keylayout.RussianWin", "com.apple.keylayout.Russian"] {
        guard let mapper = systemMapper(ruLayoutID: layoutID) else { continue }
        let typed = try XCTUnwrap(mapper.transpose("любовь", from: .ru, to: .en),
                                  "\(layoutID): прямое преобразование должно работать")
        XCTAssertEqual(mapper.transpose(typed, from: .en, to: .ru), "любовь",
                       "\(layoutID): round-trip должен вернуть исходное слово")
    }
}

func testPreservesCase() throws {
    guard let mapper = systemMapper(ruLayoutID: "com.apple.keylayout.RussianWin") else {
        throw XCTSkip("Раскладка «Русская — ПК» не установлена")
    }
    XCTAssertEqual(mapper.transpose("Ghbdtn", from: .en, to: .ru), "Привет")
}

func testReturnsNilForUnmappableCharacter() throws {
    // Пустые таблицы: отобразить нечего.
    let mapper = LayoutMapper(tables: [.en: KeyboardLayoutTable(map: [:]),
                                       .ru: KeyboardLayoutTable(map: [:])])
    XCTAssertNil(mapper.transpose("abc", from: .en, to: .ru))
}

func testDigitsAndHyphenPassThrough() throws {
    let enMap: [UInt32: Character] = [UInt32(12) << 1: "q"]
    let ruMap: [UInt32: Character] = [UInt32(12) << 1: "й"]
    let mapper = LayoutMapper(tables: [.en: KeyboardLayoutTable(map: enMap),
                                       .ru: KeyboardLayoutTable(map: ruMap)])
    XCTAssertEqual(mapper.transpose("q1-q", from: .en, to: .ru), "й1-й")
}

func testTransposesStrokes() throws {
    let ruMap: [UInt32: Character] = [UInt32(12) << 1: "й", UInt32(13) << 1: "ц"]
    let mapper = LayoutMapper(tables: [.en: KeyboardLayoutTable(map: [:]),
                                       .ru: KeyboardLayoutTable(map: ruMap)])
    let strokes = [KeyStroke(keyCode: 12, shift: false, char: "q"),
                   KeyStroke(keyCode: 13, shift: false, char: "w")]
    XCTAssertEqual(mapper.transpose(strokes: strokes, to: .ru), "йц")
}

let layoutMapperTests: [TestCase] = [
    TestCase("testTransposesLettersOnRussianPC", testTransposesLettersOnRussianPC),
    TestCase("testTransposesPunctuationPositionedLetters", testTransposesPunctuationPositionedLetters),
    TestCase("testPreservesCase", testPreservesCase),
    TestCase("testReturnsNilForUnmappableCharacter", testReturnsNilForUnmappableCharacter),
    TestCase("testDigitsAndHyphenPassThrough", testDigitsAndHyphenPassThrough),
    TestCase("testTransposesStrokes", testTransposesStrokes)
]
