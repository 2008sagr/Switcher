import Carbon
import Foundation
@testable import SwitcherCore

/// Ключ: keyCode << 1 | shift
private func key(_ code: CGKeyCode, _ shift: Bool) -> UInt32 {
    UInt32(code) << 1 | (shift ? 1 : 0)
}

func testLookupByKeyCode() throws {
    let table = KeyboardLayoutTable(map: [
        key(12, false): "q", key(12, true): "Q",
        key(13, false): "w", key(13, true): "W"
    ])
    XCTAssertEqual(table.character(keyCode: 12, shift: false), "q")
    XCTAssertEqual(table.character(keyCode: 12, shift: true),  "Q")
    XCTAssertNil(table.character(keyCode: 99, shift: false))
}

func testReverseLookupByCharacter() throws {
    let table = KeyboardLayoutTable(map: [
        key(12, false): "q", key(12, true): "Q"
    ])
    let hit = table.keyCode(for: "Q")
    XCTAssertEqual(hit?.keyCode, 12)
    XCTAssertEqual(hit?.shift, true)
    XCTAssertNil(table.keyCode(for: "z"))
}

/// Загрузка живой раскладки США. Установлена всегда, поэтому тест не пропускается.
func testLoadsUSLayoutFromSystem() throws {
    let data = try XCTUnwrap(systemLayoutData(matching: "com.apple.keylayout.US"),
                             "Раскладка США должна присутствовать в системе")
    let table = try XCTUnwrap(KeyboardLayoutTable.load(
        layoutData: data,
        keyboardType: UInt32(LMGetKbdType())
    ))
    // Физические клавиши QWERTY: 12=q, 0=a, 6=z
    XCTAssertEqual(table.character(keyCode: 12, shift: false), "q")
    XCTAssertEqual(table.character(keyCode: 0,  shift: false), "a")
    XCTAssertEqual(table.character(keyCode: 6,  shift: false), "z")
    XCTAssertEqual(table.character(keyCode: 12, shift: true),  "Q")
}

/// Коллизия в обратном индексе: один символ доступен с двух разных клавиш.
/// Контракт `init(map:)` — побеждает меньший keyCode. На этот контракт
/// напрямую опирается LayoutMapper из следующей задачи.
func testReverseLookupPrefersSmallerKeyCode() throws {
    let table = KeyboardLayoutTable(map: [
        key(20, false): "q",
        key(5,  false): "q"
    ])
    let hit = try XCTUnwrap(table.keyCode(for: "q"))
    XCTAssertEqual(hit.keyCode, 5)
}

/// Русская раскладка должна грузиться не хуже американской: на клавише,
/// где у US стоит знак препинания, у RU — буква. Именно это ломала
/// захардкоженная таблица на 70 пар.
func testLoadsRussianLayoutFromSystem() throws {
    try XCTSkipUnless(systemLayoutData(matching: "com.apple.keylayout.RussianWin") != nil,
                      "Раскладка RussianWin отсутствует в системе")
    let usData = try XCTUnwrap(systemLayoutData(matching: "com.apple.keylayout.US"))
    let ruData = try XCTUnwrap(systemLayoutData(matching: "com.apple.keylayout.RussianWin"))
    let kbdType = UInt32(LMGetKbdType())
    let us = try XCTUnwrap(KeyboardLayoutTable.load(layoutData: usData, keyboardType: kbdType))
    let ru = try XCTUnwrap(KeyboardLayoutTable.load(layoutData: ruData, keyboardType: kbdType))

    // Клавиша точки с запятой (keyCode 41): на US — ";", на RU — буква "ж".
    let usChar = try XCTUnwrap(us.character(keyCode: 41, shift: false))
    let ruChar = try XCTUnwrap(ru.character(keyCode: 41, shift: false))
    XCTAssertEqual(usChar, ";")
    XCTAssertTrue(ruChar.isLetter, "На клавише ';' в RU должна быть буква, получили \(ruChar)")
    XCTAssertNotEqual(usChar, ruChar)
}

/// Усечённые данные раскладки не должны приводить к чтению за границей буфера —
/// `load` обязан безопасно вернуть nil. Регрессия на guard в `load()`.
func testLoadTruncatedDataReturnsNilSafely() throws {
    let truncated = Data(repeating: 0, count: 4)
    XCTAssertNil(KeyboardLayoutTable.load(layoutData: truncated, keyboardType: 0))

    let empty = Data()
    XCTAssertNil(KeyboardLayoutTable.load(layoutData: empty, keyboardType: 0))
}

func systemLayoutData(matching id: String) -> Data? {
    let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String]
    guard let list = TISCreateInputSourceList(filter as CFDictionary, true)?
        .takeRetainedValue() else { return nil }
    for i in 0..<CFArrayGetCount(list) {
        guard let ptr = CFArrayGetValueAtIndex(list, i) else { continue }
        let source = Unmanaged<TISInputSource>.fromOpaque(ptr).takeUnretainedValue()
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        guard sourceID == id else { continue }
        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
        return Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
    }
    return nil
}

let keyboardLayoutTableTests: [TestCase] = [
    TestCase("testLookupByKeyCode", testLookupByKeyCode),
    TestCase("testReverseLookupByCharacter", testReverseLookupByCharacter),
    TestCase("testLoadsUSLayoutFromSystem", testLoadsUSLayoutFromSystem),
    TestCase("testReverseLookupPrefersSmallerKeyCode", testReverseLookupPrefersSmallerKeyCode),
    TestCase("testLoadsRussianLayoutFromSystem", testLoadsRussianLayoutFromSystem),
    TestCase("testLoadTruncatedDataReturnsNilSafely", testLoadTruncatedDataReturnsNilSafely)
]
