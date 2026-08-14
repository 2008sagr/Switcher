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

let clipboardGuardTests: [TestCase] = [
    TestCase("testClipboardGuardRestoresPreviousText", testClipboardGuardRestoresPreviousText),
    TestCase("testClipboardGuardDoesNotClobberContentWrittenBySomeoneElse", testClipboardGuardDoesNotClobberContentWrittenBySomeoneElse),
    TestCase("testClipboardGuardPreservesNonStringTypes", testClipboardGuardPreservesNonStringTypes),
    TestCase("testClipboardGuardRestoreWithoutWriteIsSafe", testClipboardGuardRestoreWithoutWriteIsSafe)
]
