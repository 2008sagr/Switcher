import Foundation
@testable import SwitcherCore

// Крашфикс (com.switcher.work падал в TIS): CurrentLayoutCache — тот снимок,
// который evaluate() читает вместо прямого похода в TIS с фоновой очереди.
// Тестируется только сама логика хранения значения — никаких TIS-вызовов,
// AX и CGEvent здесь нет и быть не может (см. ограничения задачи).

func testCurrentLayoutCacheReturnsInitialValue() throws {
    let cache = CurrentLayoutCache(initial: "en")
    XCTAssertEqual(cache.read(), "en")
}

func testCurrentLayoutCacheReflectsUpdate() throws {
    let cache = CurrentLayoutCache(initial: "en")
    cache.update("ru")
    XCTAssertEqual(cache.read(), "ru",
                    "После update() read() обязан немедленно видеть новое значение — " +
                    "это и есть контракт, на который полагается currentLayout()")
}

func testCurrentLayoutCacheLastUpdateWins() throws {
    let cache = CurrentLayoutCache(initial: "en")
    cache.update("ru")
    cache.update("en")
    cache.update("ru")
    XCTAssertEqual(cache.read(), "ru",
                    "Симметрично тому, как приходят уведомления системы: " +
                    "каждое новое значение полностью замещает предыдущее")
}

let currentLayoutCacheTests: [TestCase] = [
    TestCase("testCurrentLayoutCacheReturnsInitialValue", testCurrentLayoutCacheReturnsInitialValue),
    TestCase("testCurrentLayoutCacheReflectsUpdate", testCurrentLayoutCacheReflectsUpdate),
    TestCase("testCurrentLayoutCacheLastUpdateWins", testCurrentLayoutCacheLastUpdateWins)
]
