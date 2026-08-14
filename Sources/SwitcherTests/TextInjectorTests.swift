import Foundation
@testable import SwitcherCore

private func request(original: String, replacement: String, tail: String) -> ReplacementRequest {
    ReplacementRequest(
        strokes: original.map { KeyStroke(keyCode: 0, shift: false, char: $0) },
        original: original,
        replacement: replacement,
        tail: tail,
        targetLayout: .ru,
        bundleID: "com.example.app"
    )
}

func testRangeCoversWordPlusTail() throws {
    let req = request(original: "ghbdtn", replacement: "привет", tail: " ")
    // Каретка после "ghbdtn " на позиции 30 → слово начинается в 30-6-1=23.
    let plan = TextInjector.planRange(caret: 30, request: req)
    XCTAssertEqual(plan?.start, 23)
    XCTAssertEqual(plan?.verifyLength, 7, "Слово плюс хвост")
    XCTAssertEqual(plan?.wordLength, 6, "Заменяется только слово, хвост остаётся")
}

func testRangeWithoutTail() throws {
    let req = request(original: "ghbdtn", replacement: "привет", tail: "")
    let plan = TextInjector.planRange(caret: 6, request: req)
    XCTAssertEqual(plan?.start, 0)
    XCTAssertEqual(plan?.verifyLength, 6)
    XCTAssertEqual(plan?.wordLength, 6)
}

func testRangeRejectsNegativeStart() throws {
    let req = request(original: "ghbdtn", replacement: "привет", tail: " ")
    XCTAssertNil(TextInjector.planRange(caret: 3, request: req),
                 "Слово не помещается перед кареткой — замену выполнять нельзя")
}

func testRangeUsesUTF16Length() throws {
    // "привет" — 6 графем и 6 UTF-16 единиц, а эмодзи — 1 графема и 2 единицы.
    let req = request(original: "ab", replacement: "👍", tail: "")
    let plan = TextInjector.planRange(caret: 2, request: req)
    XCTAssertEqual(plan?.wordLength, 2, "Длина оригинала считается в UTF-16")
}

func testStrategyOrderPrefersAXDirect() throws {
    XCTAssertEqual(InjectionStrategy.allCases.first, .axDirect)
    XCTAssertEqual(InjectionStrategy.allCases.last, .clipboard)
}

func testCacheStartsEmptyAndRecordsSuccess() throws {
    let injector = TextInjector(ax: AXTextClient(), onSwitchLayout: { _, done in done() })
    XCTAssertNil(injector.strategy(for: "com.example.app"))
    injector.recordSuccess(.keycodeReplay, for: "com.example.app")
    XCTAssertEqual(injector.strategy(for: "com.example.app"), .keycodeReplay)
}

func testFailureDemotesCachedStrategy() throws {
    let injector = TextInjector(ax: AXTextClient(), onSwitchLayout: { _, done in done() })
    injector.recordSuccess(.axDirect, for: "com.example.app")
    injector.recordFailure(.axDirect, for: "com.example.app")
    XCTAssertNil(injector.strategy(for: "com.example.app"),
                 "Отвалившаяся стратегия должна забываться, а не залипать навсегда")
}

let textInjectorTests: [TestCase] = [
    TestCase("testRangeCoversWordPlusTail", testRangeCoversWordPlusTail),
    TestCase("testRangeWithoutTail", testRangeWithoutTail),
    TestCase("testRangeRejectsNegativeStart", testRangeRejectsNegativeStart),
    TestCase("testRangeUsesUTF16Length", testRangeUsesUTF16Length),
    TestCase("testStrategyOrderPrefersAXDirect", testStrategyOrderPrefersAXDirect),
    TestCase("testCacheStartsEmptyAndRecordsSuccess", testCacheStartsEmptyAndRecordsSuccess),
    TestCase("testFailureDemotesCachedStrategy", testFailureDemotesCachedStrategy)
]
