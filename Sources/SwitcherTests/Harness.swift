import Foundation

/// Один тест: имя (по нему работает фильтр) и тело.
struct TestCase {
    let name: String
    let body: () throws -> Void

    init(_ name: String, _ body: @escaping () throws -> Void) {
        self.name = name
        self.body = body
    }
}

/// Бросается, чтобы пропустить тест: окружение не позволяет его выполнить.
/// Пропуск — не провал, но и не успех: он виден в итоговом отчёте.
struct XCTSkip: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

/// Состояние текущего теста. Однопоточный прогон, синхронизация не нужна.
enum Harness {
    static var failures: [String] = []
    static var assertions = 0

    static func fail(_ message: String, _ file: String, _ line: Int) {
        let shortFile = file.split(separator: "/").last.map(String.init) ?? file
        failures.append("\(message)  (\(shortFile):\(line))")
    }
}

// MARK: - Ассерты в стиле XCTest
//
// Имена намеренно совпадают с XCTest: тела тестов переносятся из плана дословно.

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: String = "",
                   file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    if try !expression() { Harness.fail(message.isEmpty ? "ожидалось true" : message, file, line) }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: String = "",
                    file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    if try expression() { Harness.fail(message.isEmpty ? "ожидалось false" : message, file, line) }
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                  _ message: String = "",
                                  file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    let left = try a(), right = try b()
    if left != right {
        Harness.fail("\(message.isEmpty ? "не равно" : message): получили \(left), ожидали \(right)", file, line)
    }
}

func XCTAssertEqual(_ a: @autoclosure () throws -> Double, _ b: @autoclosure () throws -> Double,
                    accuracy: Double, _ message: String = "",
                    file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    let left = try a(), right = try b()
    if abs(left - right) > accuracy {
        Harness.fail("\(message.isEmpty ? "не равно" : message): получили \(left), ожидали \(right) ± \(accuracy)", file, line)
    }
}

func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                     _ message: String = "",
                                     file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    if try a() == b() { Harness.fail(message.isEmpty ? "значения совпали" : message, file, line) }
}

func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "",
                     file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    if let value = try expression() {
        Harness.fail("\(message.isEmpty ? "ожидался nil" : message): получили \(value)", file, line)
    }
}

func XCTAssertNotNil<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "",
                        file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    if try expression() == nil { Harness.fail(message.isEmpty ? "получили nil" : message, file, line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         _ message: String = "",
                                         file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    let left = try a(), right = try b()
    if !(left > right) { Harness.fail("\(message.isEmpty ? "не больше" : message): \(left) не > \(right)", file, line) }
}

func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                      _ message: String = "",
                                      file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    let left = try a(), right = try b()
    if !(left < right) { Harness.fail("\(message.isEmpty ? "не меньше" : message): \(left) не < \(right)", file, line) }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             _ message: String = "",
                                             file: String = #fileID, line: Int = #line) rethrows {
    Harness.assertions += 1
    let left = try a(), right = try b()
    if !(left <= right) { Harness.fail("\(message.isEmpty ? "больше" : message): \(left) не <= \(right)", file, line) }
}

func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = "",
                         file: String = #fileID, line: Int = #line) {
    Harness.assertions += 1
    do { _ = try expression() }
    catch { Harness.fail("\(message.isEmpty ? "неожиданная ошибка" : message): \(error)", file, line) }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "",
                             file: String = #fileID, line: Int = #line) {
    Harness.assertions += 1
    do {
        _ = try expression()
        Harness.fail(message.isEmpty ? "ошибка не была брошена" : message, file, line)
    } catch {}
}

/// Разворачивает опционал или проваливает тест, прервав его выполнение.
func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "",
                  file: String = #fileID, line: Int = #line) throws -> T {
    Harness.assertions += 1
    guard let value = try expression() else {
        let text = message.isEmpty ? "получили nil при развёртывании" : message
        Harness.fail(text, file, line)
        throw UnwrapFailure(message: text)
    }
    return value
}

struct UnwrapFailure: Error { let message: String }

func XCTFail(_ message: String, file: String = #fileID, line: Int = #line) {
    Harness.assertions += 1
    Harness.fail(message, file, line)
}

func XCTSkipUnless(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
    if try !condition() { throw XCTSkip(reason) }
}

// MARK: - Прогон

/// Возвращает код возврата процесса: 0 — всё прошло, 1 — есть провалы.
func runSuites(_ suites: [(String, [TestCase])], filter: String?) -> Int32 {
    let patterns = filter.map { $0.split(separator: "|").map(String.init) } ?? []

    func matches(suite: String, test: String) -> Bool {
        guard !patterns.isEmpty else { return true }
        return patterns.contains { suite.contains($0) || test.contains($0) }
    }

    var passed = 0, failed = 0, skipped = 0
    var failureLines: [String] = []

    for (suiteName, cases) in suites {
        for testCase in cases where matches(suite: suiteName, test: testCase.name) {
            Harness.failures = []
            do {
                try testCase.body()
            } catch let skip as XCTSkip {
                skipped += 1
                print("⊘ \(suiteName).\(testCase.name) — пропущен: \(skip.reason)")
                continue
            } catch is UnwrapFailure {
                // Провал уже записан в Harness.failures.
            } catch {
                Harness.failures.append("неперехваченная ошибка: \(error)")
            }

            if Harness.failures.isEmpty {
                passed += 1
            } else {
                failed += 1
                failureLines.append("✘ \(suiteName).\(testCase.name)")
                failureLines.append(contentsOf: Harness.failures.map { "    \($0)" })
            }
        }
    }

    if !failureLines.isEmpty {
        print("")
        failureLines.forEach { print($0) }
    }
    print("")
    print("прошло \(passed), провалено \(failed), пропущено \(skipped), проверок \(Harness.assertions)")
    return failed == 0 ? 0 : 1
}
