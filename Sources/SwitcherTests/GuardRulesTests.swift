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

let guardRulesTests: [TestCase] = [
    TestCase("testAllowsOrdinaryWord", testAllowsOrdinaryWord),
    TestCase("testBlocksExcludedWord", testBlocksExcludedWord),
    TestCase("testBlocksExcludedApp", testBlocksExcludedApp),
    TestCase("testDetectsURLsEmailsAndPaths", testDetectsURLsEmailsAndPaths),
    TestCase("testDetectsSecrets", testDetectsSecrets),
    TestCase("testOrdinaryWordsAreNotSecrets", testOrdinaryWordsAreNotSecrets),
    TestCase("testSecretsAndURLsAreBlockedByAllows", testSecretsAndURLsAreBlockedByAllows)
]
