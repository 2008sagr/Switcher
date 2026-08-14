import CoreGraphics
import Foundation
@testable import SwitcherCore

private func stroke(_ char: Character, _ code: CGKeyCode = 0) -> KeyStroke {
    KeyStroke(keyCode: code, shift: char.isUppercase, char: char)
}

private func type(_ text: String, into buffer: KeystrokeBuffer) {
    for (offset, char) in text.enumerated() {
        buffer.append(stroke(char, CGKeyCode(offset)))
    }
}

func testAccumulatesWord() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("hello", into: buffer)
    XCTAssertEqual(buffer.currentWord?.text, "hello")
    XCTAssertEqual(buffer.currentWord?.tail, "")
    XCTAssertEqual(buffer.currentWord?.strokes.count, 5)
}

func testBackspaceRemovesLastStroke() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("hello", into: buffer)
    buffer.backspace()
    XCTAssertEqual(buffer.currentWord?.text, "hell")
}

func testBackspaceOnEmptyBufferIsSafe() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    buffer.backspace()
    XCTAssertNil(buffer.currentWord)
}

func testResetClearsBuffer() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("hello", into: buffer)
    buffer.reset()
    XCTAssertNil(buffer.currentWord)
}

func testSpaceEndsWordAndCarriesTail() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("hello", into: buffer)
    let snapshot = buffer.wordEndedBy(stroke(" ", 49))
    XCTAssertEqual(snapshot?.text, "hello")
    XCTAssertEqual(snapshot?.tail, " ")
    XCTAssertNil(buffer.currentWord, "После границы слова буфер очищается")
}

/// Буфер не решает, что считать границей — он принимает любой разделитель
/// и кладёт его в tail. Политику задаёт EventTapController, и по ней
/// границей является только пробельный символ: знаки препинания стоят
/// в позициях букв другой раскладки и обязаны попадать внутрь слова.
func testPunctuationAccumulatesInsideWord() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("k.,jdm", into: buffer)
    XCTAssertEqual(buffer.currentWord?.text, "k.,jdm",
                   "«любовь» в английской раскладке — слово целиком, а не три обрывка")
    XCTAssertEqual(buffer.wordEndedBy(stroke(" ", 49))?.text, "k.,jdm")
}

func testWordEndOnEmptyBufferReturnsNil() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    XCTAssertNil(buffer.wordEndedBy(stroke(" ", 49)))
}

func testOverflowResetsBuffer() throws {
    let buffer = KeystrokeBuffer(maxLength: 5)
    type("abcdefgh", into: buffer)
    XCTAssertLessThanOrEqual(buffer.currentWord?.text.count ?? 0, 5,
                             "Длинный ввод (код, JSON) не должен копиться бесконечно")
}

func testDigitsDoNotFormWord() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("1234", into: buffer)
    XCTAssertNil(buffer.currentWord, "Слово должно содержать хотя бы одну букву")
}

let keystrokeBufferTests: [TestCase] = [
    TestCase("testAccumulatesWord", testAccumulatesWord),
    TestCase("testBackspaceRemovesLastStroke", testBackspaceRemovesLastStroke),
    TestCase("testBackspaceOnEmptyBufferIsSafe", testBackspaceOnEmptyBufferIsSafe),
    TestCase("testResetClearsBuffer", testResetClearsBuffer),
    TestCase("testSpaceEndsWordAndCarriesTail", testSpaceEndsWordAndCarriesTail),
    TestCase("testPunctuationAccumulatesInsideWord", testPunctuationAccumulatesInsideWord),
    TestCase("testWordEndOnEmptyBufferReturnsNil", testWordEndOnEmptyBufferReturnsNil),
    TestCase("testOverflowResetsBuffer", testOverflowResetsBuffer),
    TestCase("testDigitsDoNotFormWord", testDigitsDoNotFormWord),
]
