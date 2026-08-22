import AppKit
import Foundation
@testable import SwitcherCore

/// Отдельный именованный pasteboard для тестов: системный буфер пользователя не трогаем.
private func makeTestPasteboard() -> NSPasteboard {
    NSPasteboard(name: .init("com.switcher.tests.\(UUID().uuidString)"))
}

func testClipboardGuardRestoresPreviousText() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("важное", forType: .string)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("привет"))
    XCTAssertEqual(pasteboard.string(forType: .string), "привет")

    guardian.restore()
    XCTAssertEqual(pasteboard.string(forType: .string), "важное")
}

func testClipboardGuardDoesNotClobberContentWrittenBySomeoneElse() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("старое", forType: .string)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("привет"))

    // Кто-то другой (пользователь нажал Cmd+C) пишет в буфер.
    pasteboard.clearContents()
    pasteboard.setString("пользователь скопировал", forType: .string)

    guardian.restore()
    XCTAssertEqual(pasteboard.string(forType: .string), "пользователь скопировал",
                   "Чужая запись важнее восстановления: перетирать её нельзя")
}

func testClipboardGuardPreservesNonStringTypes() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    let payload = Data([0x1, 0x2, 0x3])
    pasteboard.setData(payload, forType: .tiff)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("привет"))
    guardian.restore()

    XCTAssertEqual(pasteboard.data(forType: .tiff), payload,
                   "Нетекстовые типы обязаны переживать замену")
}

func testClipboardGuardRestoreWithoutWriteIsSafe() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("нетронуто", forType: .string)
    ClipboardGuard(pasteboard: pasteboard).restore()
    XCTAssertEqual(pasteboard.string(forType: .string), "нетронуто")
}

/// Ревью, находка 3 (Important): второй write() без промежуточного restore()
/// не должен пересохранять снимок — иначе он зафиксирует то, что записал
/// первый write(), и подлинный буфер пользователя будет потерян безвозвратно.
func testClipboardGuardSecondWriteWithoutRestorePreservesOriginal() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("старое", forType: .string)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("первая замена"))
    XCTAssertTrue(guardian.write("вторая замена"))

    guardian.restore()
    XCTAssertEqual(pasteboard.string(forType: .string), "старое",
                   "Повторный write() без restore() не должен терять исходный буфер")
}

/// Ревью: не было теста на повторный restore() ПОСЛЕ write() (был только
/// restore() без write() вовсе). Второй вызов подряд обязан быть no-op.
func testClipboardGuardRepeatedRestoreAfterWriteIsSafe() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("оригинал", forType: .string)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("замена"))

    guardian.restore()
    XCTAssertEqual(pasteboard.string(forType: .string), "оригинал")

    // Второй restore() подряд, без нового write() между ними — no-op.
    guardian.restore()
    XCTAssertEqual(pasteboard.string(forType: .string), "оригинал",
                   "Повторный restore() без write() не должен ничего менять")
}

/// Ревью: не было теста на элемент буфера с несколькими типами данных сразу.
func testClipboardGuardPreservesMultipleTypesOnSingleItem() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString("текст", forType: .string)
    let payload = Data([0xA, 0xB, 0xC])
    item.setData(payload, forType: .tiff)
    pasteboard.writeObjects([item])

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("привет"))
    guardian.restore()

    XCTAssertEqual(pasteboard.string(forType: .string), "текст",
                   "Строковый тип элемента с несколькими типами обязан восстановиться")
    XCTAssertEqual(pasteboard.data(forType: .tiff), payload,
                   "Второй тип того же элемента обязан восстановиться")
}

/// Ревью: не было теста на буфер с несколькими items сразу.
func testClipboardGuardPreservesMultipleItems() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    let first = NSPasteboardItem()
    first.setString("первый", forType: .string)
    let second = NSPasteboardItem()
    second.setString("второй", forType: .string)
    pasteboard.writeObjects([first, second])
    XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("привет"))
    guardian.restore()

    XCTAssertEqual(pasteboard.pasteboardItems?.count, 2,
                   "Число элементов буфера обязано восстановиться")
    XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "первый")
    XCTAssertEqual(pasteboard.pasteboardItems?.last?.string(forType: .string), "второй")
}

/// `force: true` нужен конвертации выделения по двойному Shift: там
/// "чужая" запись между write() и restore() — это наш же синтетический
/// Cmd+C (SwitchCoordinator читает выделение через буфер, когда AX не
/// отдаёт его напрямую), а не параллельное действие пользователя, которое
/// в обычном restore() нужно уважать и не перетирать.
func testClipboardGuardForceRestoreOverridesForeignWrite() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("исходное", forType: .string)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write(""))

    // Синтетический Cmd+C поверх нашей записи.
    pasteboard.clearContents()
    pasteboard.setString("скопированное выделение", forType: .string)

    guardian.restore(force: true)
    XCTAssertEqual(pasteboard.string(forType: .string), "исходное",
                   "force:true обязан восстановить буфер, даже если changeCount не совпал")
}

/// Дефект (два места — SwitchCoordinator.applySelectionConversion и
/// TextInjector.replaceViaClipboard): восстановление буфера обмена
/// синхронно сразу после постинга Cmd+V опережало обработку этого события
/// целевым приложением, и вставлялось исходное содержимое буфера, а не
/// конвертированный текст. Здесь проверяем сам примитив (scheduleRestore),
/// а не места его использования — CGEvent/AX/TIS тесты в этом проекте
/// запрещены.
func testClipboardGuardScheduleRestoreIsAsyncAndDelayed() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("исходное", forType: .string)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("вставленное"))

    guardian.scheduleRestore(after: 0.1)

    // Сразу после вызова буфер ещё не восстановлен: restore() ушёл в
    // отложенный блок на отдельной очереди, а не выполнился синхронно тут же.
    XCTAssertEqual(pasteboard.string(forType: .string), "вставленное",
                   "scheduleRestore обязан быть асинхронным — не восстанавливать раньше срока")

    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertEqual(pasteboard.string(forType: .string), "исходное",
                   "После истечения задержки буфер обязан восстановиться")
}

/// Отложенное восстановление обязано сверять changeCount точно так же, как
/// немедленное: если пользователь успел скопировать что-то своё за время
/// ожидания, восстановление не должно перетереть его запись.
func testClipboardGuardScheduleRestoreStillRespectsChangeCount() throws {
    let pasteboard = makeTestPasteboard()
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    pasteboard.setString("старое", forType: .string)

    let guardian = ClipboardGuard(pasteboard: pasteboard)
    XCTAssertTrue(guardian.write("вставленное"))

    guardian.scheduleRestore(after: 0.1)

    // Пользователь копирует что-то своё ДО того, как отложенное
    // восстановление успевает сработать.
    Thread.sleep(forTimeInterval: 0.02)
    pasteboard.clearContents()
    pasteboard.setString("пользователь скопировал", forType: .string)

    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertEqual(pasteboard.string(forType: .string), "пользователь скопировал",
                   "Отложенное восстановление обязано уважать чужую запись так же, как немедленное")
}

let clipboardGuardTests: [TestCase] = [
    TestCase("testClipboardGuardRestoresPreviousText", testClipboardGuardRestoresPreviousText),
    TestCase("testClipboardGuardDoesNotClobberContentWrittenBySomeoneElse", testClipboardGuardDoesNotClobberContentWrittenBySomeoneElse),
    TestCase("testClipboardGuardPreservesNonStringTypes", testClipboardGuardPreservesNonStringTypes),
    TestCase("testClipboardGuardRestoreWithoutWriteIsSafe", testClipboardGuardRestoreWithoutWriteIsSafe),
    TestCase("testClipboardGuardSecondWriteWithoutRestorePreservesOriginal", testClipboardGuardSecondWriteWithoutRestorePreservesOriginal),
    TestCase("testClipboardGuardRepeatedRestoreAfterWriteIsSafe", testClipboardGuardRepeatedRestoreAfterWriteIsSafe),
    TestCase("testClipboardGuardPreservesMultipleTypesOnSingleItem", testClipboardGuardPreservesMultipleTypesOnSingleItem),
    TestCase("testClipboardGuardPreservesMultipleItems", testClipboardGuardPreservesMultipleItems),
    TestCase("testClipboardGuardForceRestoreOverridesForeignWrite", testClipboardGuardForceRestoreOverridesForeignWrite),
    TestCase("testClipboardGuardScheduleRestoreIsAsyncAndDelayed", testClipboardGuardScheduleRestoreIsAsyncAndDelayed),
    TestCase("testClipboardGuardScheduleRestoreStillRespectsChangeCount", testClipboardGuardScheduleRestoreStillRespectsChangeCount)
]
