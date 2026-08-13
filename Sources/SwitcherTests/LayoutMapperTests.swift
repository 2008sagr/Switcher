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
    var tested = 0
    for layoutID in ["com.apple.keylayout.RussianWin", "com.apple.keylayout.Russian"] {
        guard let mapper = systemMapper(ruLayoutID: layoutID) else { continue }
        tested += 1
        let typed = try XCTUnwrap(mapper.transpose("любовь", from: .ru, to: .en),
                                  "\(layoutID): прямое преобразование должно работать")
        XCTAssertEqual(mapper.transpose(typed, from: .en, to: .ru), "любовь",
                       "\(layoutID): round-trip должен вернуть исходное слово")
    }
    // Без этой проверки тест проходит ВХОЛОСТУЮ на машине без русских
    // раскладок: цикл не выполняется, ни один ассерт не срабатывает, и
    // харнесс засчитывает тест как пройденный. Это центральная проверка
    // задачи — она обязана либо реально отработать, либо честно пропуститься.
    try XCTSkipUnless(tested > 0, "Ни одна русская раскладка не установлена")
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

/// Документирует известное ограничение: при коллизии обратного маппинга
/// (один символ доступен с двух разных физических клавиш исходной раскладки)
/// строковый и strokes-путь могут дать РАЗНЫЙ результат для одного и того же
/// реального нажатия. `KeyboardLayoutTable` детерминированно отдаёт обратный
/// поиск клавише с МЕНЬШИМ keyCode; если нажатие пришло с «проигравшей»
/// клавиши, строковый путь об этом не знает и подставит символ с клавиши-
/// «победителя», а strokes-путь — верный символ с клавиши самого нажатия.
func testStringPathCanDivergeFromStrokesPathOnReverseMappingCollision() throws {
    // 'a' достижима с двух клавиш исходной раскладки: keyCode 10 (выигрывает
    // обратный поиск как меньший) и keyCode 20 (проигрывает).
    let enMap: [UInt32: Character] = [UInt32(10) << 1: "a", UInt32(20) << 1: "a"]
    // На тех же физических клавишах в целевой раскладке — разные символы.
    let ruMap: [UInt32: Character] = [UInt32(10) << 1: "ф", UInt32(20) << 1: "ы"]
    let mapper = LayoutMapper(tables: [.en: KeyboardLayoutTable(map: enMap),
                                       .ru: KeyboardLayoutTable(map: ruMap)])

    // Строковый путь не знает, с какой физической клавиши пришла 'a':
    // обратный поиск всегда возвращает клавишу-«победителя» (keyCode 10).
    XCTAssertEqual(mapper.transpose("a", from: .en, to: .ru), "ф")

    // Но реальное нажатие пришло с «проигравшей» клавиши (keyCode 20) —
    // strokes-путь использует её keyCode напрямую и даёт верный символ.
    let strokeFromLosingKey = [KeyStroke(keyCode: 20, shift: false, char: "a")]
    XCTAssertEqual(mapper.transpose(strokes: strokeFromLosingKey, to: .ru), "ы")

    // Фиксируем расхождение явно: одно и то же нажатие 'a' даёт разные
    // символы в зависимости от того, каким путём его перенесли.
    XCTAssertNotEqual(mapper.transpose("a", from: .en, to: .ru),
                      mapper.transpose(strokes: strokeFromLosingKey, to: .ru))
}

let layoutMapperTests: [TestCase] = [
    TestCase("testTransposesLettersOnRussianPC", testTransposesLettersOnRussianPC),
    TestCase("testTransposesPunctuationPositionedLetters", testTransposesPunctuationPositionedLetters),
    TestCase("testPreservesCase", testPreservesCase),
    TestCase("testReturnsNilForUnmappableCharacter", testReturnsNilForUnmappableCharacter),
    TestCase("testDigitsAndHyphenPassThrough", testDigitsAndHyphenPassThrough),
    TestCase("testTransposesStrokes", testTransposesStrokes),
    TestCase("testStringPathCanDivergeFromStrokesPathOnReverseMappingCollision",
             testStringPathCanDivergeFromStrokesPathOnReverseMappingCollision)
]
