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

/// Находка 5: `strokes.count` не проверяет ни keyCode, ни shift. Реализация,
/// хранящая только Character и синтезирующая фиктивные `KeyStroke(keyCode: 0, ...)`,
/// прошла бы старые тесты. Хранение keycode — смысл компонента: без него нельзя
/// переиграть слово в другой раскладке нажатиями тех же физических клавиш —
/// единственная стратегия замены, работающая в терминалах.
func testStrokesPreserveKeyCodeAndShift() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("AbC", into: buffer)
    let word = try XCTUnwrap(buffer.currentWord)
    let expected = [stroke("A", 0), stroke("b", 1), stroke("C", 2)]
    XCTAssertEqual(word.strokes, expected,
                   "keyCode и shift каждого нажатия должны сохраняться дословно")
}

/// Находка 6, часть 1: проверка `count >= maxLength` стоит ДО append. Ровно на
/// maxLength символах сброса ещё нет — буфер содержит их все.
func testAtMaxLengthBufferNotYetReset() throws {
    let buffer = KeystrokeBuffer(maxLength: 5)
    type("abcde", into: buffer) // ровно maxLength символов
    XCTAssertEqual(buffer.currentWord?.text, "abcde",
                   "На ровно maxLength символах сброса ещё не происходит")
}

/// Находка 6, часть 2: символ maxLength+1 переполняет буфер. Сброс происходит
/// ДО append, поэтому в буфере остаётся только этот один новый символ, а не
/// последние maxLength символов и не пустой буфер.
func testOneOverMaxLengthResetsToSingleChar() throws {
    let buffer = KeystrokeBuffer(maxLength: 5)
    type("abcdef", into: buffer) // maxLength + 1 символ
    XCTAssertEqual(buffer.currentWord?.text, "f",
                   "Шестой символ сначала вызывает полный сброс, потом добавляется сам — " +
                   "в буфере остаётся только он один")
}

/// Находка 7: строка из одних знаков препинания (без цифр и букв) тоже не
/// должна считаться словом — до сих пор проверялось только на цифрах.
func testPunctuationOnlyDoesNotFormWord() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("!?.,;", into: buffer)
    XCTAssertNil(buffer.currentWord, "Строка из одних знаков препинания не должна считаться словом")
}

/// Находка 8: `textUTF16Length` существует потому, что диапазоны Accessibility
/// считаются в UTF-16, а не в графемах. Эмодзи вне BMP — один Character
/// (одна графема), но два code unit'а UTF-16: без этого свойства замена
/// стёрла бы не тот диапазон текста.
func testTextUTF16LengthDiffersFromGraphemeCountForEmoji() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("hi👍", into: buffer)
    let word = try XCTUnwrap(buffer.currentWord)
    XCTAssertEqual(word.text.count, 3, "графемно — 3 символа (h, i, 👍)")
    XCTAssertEqual(word.textUTF16Length, 4,
                   "в UTF-16 эмодзи вне BMP занимает 2 code unit'а — итого 1+1+2")
}

/// Находка 8 (продолжение): та же проверка для `tailUTF16Length` — разделитель
/// тоже может оказаться символом вне BMP.
func testTailUTF16LengthDiffersFromGraphemeCountForEmoji() throws {
    let buffer = KeystrokeBuffer(maxLength: 50)
    type("hi", into: buffer)
    let snapshot = buffer.wordEndedBy(stroke("😀", 99))
    let word = try XCTUnwrap(snapshot)
    XCTAssertEqual(word.tail.count, 1, "графемно — один символ-разделитель")
    XCTAssertEqual(word.tailUTF16Length, 2,
                   "в UTF-16 — два code unit'а (суррогатная пара)")
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
    TestCase("testStrokesPreserveKeyCodeAndShift", testStrokesPreserveKeyCodeAndShift),
    TestCase("testAtMaxLengthBufferNotYetReset", testAtMaxLengthBufferNotYetReset),
    TestCase("testOneOverMaxLengthResetsToSingleChar", testOneOverMaxLengthResetsToSingleChar),
    TestCase("testPunctuationOnlyDoesNotFormWord", testPunctuationOnlyDoesNotFormWord),
    TestCase("testTextUTF16LengthDiffersFromGraphemeCountForEmoji", testTextUTF16LengthDiffersFromGraphemeCountForEmoji),
    TestCase("testTailUTF16LengthDiffersFromGraphemeCountForEmoji", testTailUTF16LengthDiffersFromGraphemeCountForEmoji),
]
