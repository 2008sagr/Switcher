import Foundation
@testable import SwitcherCore

func testEmptyHistoryGivesNoBonus() throws {
    let prior = LanguagePrior(capacity: 3, weight: 0.5)
    XCTAssertEqual(prior.bonus(forConverting: .ru), 0.0, accuracy: 0.001)
}

func testUniformHistoryGivesFullBonusTowardsIt() throws {
    let prior = LanguagePrior(capacity: 3, weight: 0.5)
    for _ in 0..<3 { prior.record(.ru) }
    XCTAssertEqual(prior.bonus(forConverting: .ru), 0.5, accuracy: 0.001)
    XCTAssertEqual(prior.bonus(forConverting: .en), -0.5, accuracy: 0.001,
                   "Против контекста порог должен ужесточаться симметрично")
}

func testMixedHistoryGivesPartialBonus() throws {
    let prior = LanguagePrior(capacity: 4, weight: 0.5)
    prior.record(.ru); prior.record(.ru); prior.record(.ru); prior.record(.en)
    // доли 0.75 / 0.25 → 0.5 * (0.75 - 0.25) = 0.25
    XCTAssertEqual(prior.bonus(forConverting: .ru), 0.25, accuracy: 0.001)
}

func testHistoryIsBoundedByCapacity() throws {
    let prior = LanguagePrior(capacity: 3, weight: 0.5)
    for _ in 0..<10 { prior.record(.en) }
    prior.record(.ru); prior.record(.ru); prior.record(.ru)
    XCTAssertEqual(prior.bonus(forConverting: .ru), 0.5, accuracy: 0.001,
                   "Старые слова должны вытесняться, иначе контекст залипает")
}

func testResetClearsHistory() throws {
    let prior = LanguagePrior(capacity: 3, weight: 0.5)
    for _ in 0..<3 { prior.record(.ru) }
    prior.reset()
    XCTAssertEqual(prior.bonus(forConverting: .ru), 0.0, accuracy: 0.001)
}

let languagePriorTests: [TestCase] = [
    TestCase("testEmptyHistoryGivesNoBonus", testEmptyHistoryGivesNoBonus),
    TestCase("testUniformHistoryGivesFullBonusTowardsIt", testUniformHistoryGivesFullBonusTowardsIt),
    TestCase("testMixedHistoryGivesPartialBonus", testMixedHistoryGivesPartialBonus),
    TestCase("testHistoryIsBoundedByCapacity", testHistoryIsBoundedByCapacity),
    TestCase("testResetClearsHistory", testResetClearsHistory)
]
