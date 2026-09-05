import Foundation
@testable import SwitcherCore

private let rules = GuardRules(
    wordExclusions: ["ghbdtn"],
    excludedApps: ["com.apple.Terminal"]
)

func testAllowsOrdinaryWord() throws {
    XCTAssertTrue(rules.allows(word: "hello", bundleID: "com.apple.Notes"))
}

func testBlocksExcludedWord() throws {
    XCTAssertFalse(rules.allows(word: "ghbdtn", bundleID: "com.apple.Notes"))
    XCTAssertFalse(rules.allows(word: "GHBDTN", bundleID: "com.apple.Notes"),
                   "Исключения сравниваются без учёта регистра")
}

func testBlocksExcludedApp() throws {
    XCTAssertFalse(rules.allows(word: "hello", bundleID: "com.apple.Terminal"))
}

func testDetectsURLsEmailsAndPaths() throws {
    for sample in ["http://example.com", "https://a.b", "www.example.com",
                   "user@example.com", "/usr/local/bin", "~/Documents",
                   "example.co.uk", "ftp://host"] {
        XCTAssertTrue(GuardRules.looksLikeURLOrPath(sample), "не распознан: \(sample)")
    }
    for sample in ["hello", "привет", "don't", "co-op", "end."] {
        XCTAssertFalse(GuardRules.looksLikeURLOrPath(sample), "ложное срабатывание: \(sample)")
    }
}

func testDetectsSecrets() throws {
    // Длиннее 6 и одновременно строчные, заглавные и цифры/знаки.
    XCTAssertTrue(GuardRules.looksLikeSecret("Passw0rd"))
    XCTAssertTrue(GuardRules.looksLikeSecret("aB3xY9zQ"))
    XCTAssertTrue(GuardRules.looksLikeSecret("Tr0ub4dor"))
}

func testOrdinaryWordsAreNotSecrets() throws {
    for sample in ["password", "PASSWORD", "Password", "hello", "Привет",
                   "abcdef", "Ab1", "договор"] {
        XCTAssertFalse(GuardRules.looksLikeSecret(sample), "ложное срабатывание: \(sample)")
    }
}

func testSecretsAndURLsAreBlockedByAllows() throws {
    XCTAssertFalse(rules.allows(word: "Passw0rd", bundleID: "com.apple.Notes"))
    XCTAssertFalse(rules.allows(word: "user@example.com", bundleID: "com.apple.Notes"))
}

/// Находка 1: пароль, набранный со случайно включённым Caps Lock, состоит из
/// заглавных букв и цифр/знаков, но не содержит строчных. Старое правило
/// (обязательно строчные + заглавные + цифры/знаки) такой пароль пропускало —
/// худший сценарий: sudo в терминале, где ввод не отображается на экране,
/// и порчу нечем заметить.
func testDetectsCapsLockPassword() throws {
    XCTAssertTrue(GuardRules.looksLikeSecret("PASSW0RD"),
                  "пароль с Caps Lock (только заглавные + цифра) должен считаться секретом")
    XCTAssertTrue(GuardRules.looksLikeSecret("TR0UBADOR#"),
                  "пароль с Caps Lock и знаком должен считаться секретом")
}

/// Находка 2: граница `count > 6` не была протестирована. Проверено рантаймом:
/// ровно 6 символов — false, ровно 7 — true (седьмой символ не влияет на
/// состав hasUpper/hasOther, оба набора уже содержат заглавную и знак/цифру).
func testSecretLengthBoundary() throws {
    XCTAssertFalse(GuardRules.looksLikeSecret("Ab3#kZ"),
                    "6 символов — граница не пройдена, даже с заглавной и знаком")
    XCTAssertTrue(GuardRules.looksLikeSecret("Ab3#kZx"),
                  "7 символов — граница пройдена")
}

/// Находка 3: правило `hasUpper && hasOther` намеренно блокирует автозамену
/// для обычных слов с заглавной буквой и цифрой — это осознанный компромисс
/// в пользу безопасности (см. комментарий над `looksLikeSecret`), а не дефект.
/// Тест фиксирует цену этого решения, а не проверяет «желаемое» поведение.
func testOrdinaryWordsResemblingSecretsAreBlocked() throws {
    for sample in ["Windows10", "iPhone15", "JohnDoe23"] {
        XCTAssertTrue(GuardRules.looksLikeSecret(sample),
                      "\(sample): осознанно блокируется как похожее на секрет — " +
                      "асимметрия цены ошибки важнее редкого неудобства")
    }
}

/// Находка 4: упрощённая `looksLikeURLOrPath` расходится со старой версией на
/// русских сокращениях, оборванных многоточием («т.е..», «и.о..», «два.три..»).
/// Направление расхождения безопасное — упрощённая версия блокирует замену
/// там, где старая её разрешала, — поэтому это не баг, откатывать не нужно.
/// Тест фиксирует расхождение как намеренное.
func testURLDetectionBlocksAbbreviationsWithEllipsis() throws {
    for sample in ["т.е..", "и.о..", "два.три.."] {
        XCTAssertTrue(GuardRules.looksLikeURLOrPath(sample),
                      "\(sample): блокировка намеренная (см. отчёт ревью, находка 4)")
    }
}

let guardRulesTests: [TestCase] = [
    TestCase("testAllowsOrdinaryWord", testAllowsOrdinaryWord),
    TestCase("testBlocksExcludedWord", testBlocksExcludedWord),
    TestCase("testBlocksExcludedApp", testBlocksExcludedApp),
    TestCase("testDetectsURLsEmailsAndPaths", testDetectsURLsEmailsAndPaths),
    TestCase("testDetectsSecrets", testDetectsSecrets),
    TestCase("testOrdinaryWordsAreNotSecrets", testOrdinaryWordsAreNotSecrets),
    TestCase("testSecretsAndURLsAreBlockedByAllows", testSecretsAndURLsAreBlockedByAllows),
    TestCase("testDetectsCapsLockPassword", testDetectsCapsLockPassword),
    TestCase("testSecretLengthBoundary", testSecretLengthBoundary),
    TestCase("testOrdinaryWordsResemblingSecretsAreBlocked", testOrdinaryWordsResemblingSecretsAreBlocked),
    TestCase("testURLDetectionBlocksAbbreviationsWithEllipsis", testURLDetectionBlocksAbbreviationsWithEllipsis)
]
