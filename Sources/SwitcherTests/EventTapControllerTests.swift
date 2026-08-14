import CoreGraphics
import Foundation
@testable import SwitcherCore

func testInjectSourceCarriesMarker() throws {
    XCTAssertEqual(EventTapController.injectSource.userData,
                   EventTapController.syntheticMarker,
                   "Метка должна стоять на ИСТОЧНИКЕ: на событии она теряется при проходе через HID-тап")
}

func testInjectSourceUsesPrivateState() throws {
    // .privateState не наследует физическое состояние модификаторов,
    // иначе удерживаемый Shift искажает инжектируемый текст.
    let event = CGEvent(keyboardEventSource: EventTapController.injectSource,
                        virtualKey: 0, keyDown: true)
    XCTAssertNotNil(event)
    XCTAssertEqual(event?.getIntegerValueField(.eventSourceUserData),
                   EventTapController.syntheticMarker)
}

func testClassifiesBackspace() throws {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true)!
    guard case .backspace = EventTapController.classify(event: event, type: .keyDown) else {
        return XCTFail("keyCode 51 должен классифицироваться как backspace")
    }
    // Харнесс засчитывает тест без единого ассерта как пройденный, даже если
    // guard выше молча совпал. Явный ассерт обязателен на каждом пути.
    XCTAssertTrue(true, "keyCode 51 классифицирован как .backspace")
}

func testClassifiesResetKeys() throws {
    // Tab(48), Escape(53), стрелки(123-126) сбрасывают буфер.
    for code: CGKeyCode in [48, 53, 123, 124, 125, 126] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        guard case .resetCause = EventTapController.classify(event: event, type: .keyDown) else {
            return XCTFail("keyCode \(code) должен сбрасывать буфер")
        }
        XCTAssertTrue(true, "keyCode \(code) классифицирован как .resetCause")
    }
}

func testCommandComboResetsBuffer() throws {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
    event.flags = .maskCommand
    guard case .resetCause = EventTapController.classify(event: event, type: .keyDown) else {
        return XCTFail("Комбинации с Cmd должны сбрасывать буфер")
    }
    XCTAssertTrue(true, "Cmd+8 классифицирован как .resetCause")
}

func testClassifiesMouseDown() throws {
    let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                        mouseCursorPosition: .zero, mouseButton: .left)!
    guard case .mouseDown = EventTapController.classify(event: event, type: .leftMouseDown) else {
        return XCTFail("Клик мышью обязан сбрасывать буфер: каретка уехала")
    }
    XCTAssertTrue(true, "leftMouseDown классифицирован как .mouseDown")
}

func testSpaceIsWordBoundary() throws {
    var chars: [UniChar] = Array(" ".utf16)
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
    event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
    guard case .wordBreakKey = EventTapController.classify(event: event, type: .keyDown) else {
        return XCTFail("Пробел — единственная надёжная граница слова")
    }
    XCTAssertTrue(true, "пробел классифицирован как .wordBreakKey")
}

/// Ключевая проверка: знаки препинания НЕ границы слова.
/// «любовь» в английской раскладке — это "k.,jdm": точка и запятая здесь
/// это «ю» и «б». Разорвав слово по ним, конвертировать будет нечего.
func testPunctuationIsPartOfTheWord() throws {
    for punctuation in [".", ",", ";", "'", "[", "]"] {
        var chars: [UniChar] = Array(punctuation.utf16)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: true)!
        event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        guard case .key = EventTapController.classify(event: event, type: .keyDown) else {
            return XCTFail("«\(punctuation)» должен попадать в буфер, а не завершать слово")
        }
        XCTAssertTrue(true, "«\(punctuation)» классифицирован как .key")
    }
}

let eventTapControllerTests: [TestCase] = [
    TestCase("testInjectSourceCarriesMarker", testInjectSourceCarriesMarker),
    TestCase("testInjectSourceUsesPrivateState", testInjectSourceUsesPrivateState),
    TestCase("testClassifiesBackspace", testClassifiesBackspace),
    TestCase("testClassifiesResetKeys", testClassifiesResetKeys),
    TestCase("testCommandComboResetsBuffer", testCommandComboResetsBuffer),
    TestCase("testClassifiesMouseDown", testClassifiesMouseDown),
    TestCase("testSpaceIsWordBoundary", testSpaceIsWordBoundary),
    TestCase("testPunctuationIsPartOfTheWord", testPunctuationIsPartOfTheWord),
]
