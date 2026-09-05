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

/// Ревью Task 12, находка 2: если strokes пуст, а заменять есть чем,
/// replaceViaKeycodeReplay обязан отказать ДО backspace'ов — иначе исходный
/// текст удаляется, а взамен не печатается ничего, и слово пропадает
/// бесследно. Проверяем это без живого приложения: раз отказ должен
/// происходить раньше любых системных вызовов (AX/CGEvent), для теста
/// достаточно убедиться, что вызов не запостил вообще ничего пользователю
/// в текстовое поле — тут это гарантируется тем, что метод возвращает
/// false, даже когда AX ничего не видит (пустой ax.focusedElement()) и
/// синхронный переключатель раскладки завершается мгновенно.
func testKeycodeReplayRefusesEmptyStrokes() throws {
    let injector = TextInjector(ax: AXTextClient(), onSwitchLayout: { _, done in done() })
    let req = ReplacementRequest(
        strokes: [], original: "привет", replacement: "ghbdtn",
        tail: "", targetLayout: .en, bundleID: "com.example.app"
    )
    XCTAssertEqual(injector.replaceViaKeycodeReplay(req), .notApplicable,
                   "Пустые strokes — сигнал отказать до удаления текста, а не после")
}

/// Находка 3 (финальное ревью): `replaceViaClipboard` (стратегия D) вставляла
/// через Cmd+V сразу после выделения, без единой сверки — в отличие от
/// стратегии C, которая сверяет `ax.selectedText(...)` перед печатью. Сверку
/// вынесли в общую чистую функцию `selectionMatchesExpectation`, используемую
/// теперь и C, и D. `AXUIElement` нельзя сконструировать в оффлайн-тесте
/// (непрозрачный тип из чужого процесса), поэтому проверяем саму логику
/// сравнения напрямую — то же самое разделение, что и у `planRange`.
func testSelectionMatchTrustsUnreadableSelection() throws {
    XCTAssertTrue(TextInjector.selectionMatchesExpectation(nil, expected: "ghbdtn "),
                  "Выделение недоступно для чтения — доверяем порядку доставки событий, как раньше")
    XCTAssertTrue(TextInjector.selectionMatchesExpectation("", expected: "ghbdtn "),
                  "Пустая строка — тоже нечем сверить, тот же исход")
}

func testSelectionMatchAcceptsExactSelection() throws {
    XCTAssertTrue(TextInjector.selectionMatchesExpectation("ghbdtn ", expected: "ghbdtn "))
}

func testSelectionMatchCatchesMismatch() throws {
    XCTAssertFalse(TextInjector.selectionMatchesExpectation("wrong", expected: "ghbdtn "),
                   "Выделили не то, что ожидалось, — сверка обязана поймать это до вставки")
}

/// Находка 4 (финальное ревью): файл словаря (~/.switcher/dictionary.json)
/// спроектирован для ручного редактирования, а SwitchDictionary.load()
/// декодирует его без валидации — гвард в addCorrection защищает только путь
/// через UI настроек. Пустая замена, вписанная вручную в файл, дошла бы до
/// TextInjector.replace() как replacement: "", и ни одна из четырёх стратегий
/// не отказала бы сама по себе (все сверяют исходный текст под кареткой, а
/// не непустоту замены) — слово тихо удалилось бы. Зовём именно публичный
/// replace(), а не отдельную стратегию: guard должен сработать ДО перебора
/// стратегий, поэтому тест безопасен — до живых AX/CGEvent вызовов дело не
/// доходит.
func testReplaceRefusesEmptyReplacement() throws {
    let injector = TextInjector(ax: AXTextClient(), onSwitchLayout: { _, done in done() })
    let req = ReplacementRequest(
        strokes: [KeyStroke(keyCode: 0, shift: false, char: "g")],
        original: "ghbdtn", replacement: "",
        tail: " ", targetLayout: .ru, bundleID: "com.example.app"
    )
    XCTAssertFalse(injector.replace(req),
                   "Пустая замена — отказ до вызова любой стратегии, а не тихое удаление слова")
}

// MARK: - Правило перебора (TextInjector.runTrial)
//
// Дефект, который чинят эти тесты: TextInjector.replace() перебирал
// стратегии как булевы — «не сработала, пробуем следующую» — не различая
// «ничего не тронула» и «уже поменяла текст, но подтвердить нечем». В
// терминале keycodeReplay меняла текст (backspace + переигранные нажатия),
// пост-проверка через AX не сходилась (AX терминала видит буфер терминала,
// а не текстовое поле) и возвращала false — перебор шёл дальше, к
// replaceViaSelection, которая вставляла ту же строку ЕЩЁ РАЗ: отсюда
// дублирование «test» → «testtest» и съеденный пробел перед словом.
//
// Правило проверяется здесь на чистой функции runTrial, без единого живого
// AX/CGEvent вызова: стратегии подменены замыканием, которое просто
// возвращает заготовленный исход и запоминает порядок вызовов.

/// Прогоняет `runTrial` с заготовленными исходами по порядку `InjectionStrategy.allCases`
/// и возвращает список фактически опрошенных стратегий вместе с итогом.
private func trial(_ outcomes: [InjectionStrategy: StrategyOutcome])
    -> (called: [InjectionStrategy], result: TextInjector.TrialOutcome) {
    var called: [InjectionStrategy] = []
    let result = TextInjector.runTrial(order: InjectionStrategy.allCases) { strategy in
        called.append(strategy)
        return outcomes[strategy] ?? .notApplicable
    }
    return (called, result)
}

/// .notApplicable — гарантированно ничего не тронуто, перебор обязан идти
/// дальше по списку и в итоге дойти до стратегии, которая сработала.
func testTrialContinuesPastNotApplicable() throws {
    let (called, result) = trial([
        .axDirect: .notApplicable,
        .keycodeReplay: .notApplicable,
        .selectAndInject: .notApplicable,
        .clipboard: .succeeded
    ])
    XCTAssertEqual(called, InjectionStrategy.allCases,
                   "Каждая нотApplicable-стратегия обязана уступать место следующей")
    XCTAssertEqual(result, .succeeded(.clipboard))
}

/// .mutatedUnverified — текст уже изменён этой стратегией. Перебор обязан
/// ОСТАНОВИТЬСЯ на ней: следующая стратегия по счёту не должна быть даже
/// опрошена, иначе она применит замену повторно поверх уже применённой —
/// ровно баг из симптома пользователя (дублирование текста в терминале).
func testTrialStopsAtMutatedUnverified() throws {
    let (called, result) = trial([
        .axDirect: .notApplicable,
        .keycodeReplay: .mutatedUnverified
        // selectAndInject и clipboard намеренно не заданы: если перебор
        // дойдёт до них, outcomes[...] вернёт .notApplicable по умолчанию,
        // и тест это не поймает через result — поэтому решает именно `called`.
    ])
    XCTAssertEqual(called, [.axDirect, .keycodeReplay],
                   "После mutatedUnverified ни одна следующая стратегия не должна быть опрошена")
    XCTAssertEqual(result, .mutatedUnverified(.keycodeReplay))
}

/// .succeeded останавливает перебор немедленно, даже первой стратегией.
func testTrialStopsImmediatelyOnSucceeded() throws {
    let (called, result) = trial([.axDirect: .succeeded])
    XCTAssertEqual(called, [.axDirect],
                   "Успех первой же стратегии — остальные опрашивать незачем")
    XCTAssertEqual(result, .succeeded(.axDirect))
}

/// Если все стратегии гарантированно ничего не тронули — итог exhausted,
/// а не мутация: replace() обязан вернуть false, не соврав об успехе.
func testTrialExhaustedWhenAllNotApplicable() throws {
    let (called, result) = trial([:])
    XCTAssertEqual(called, InjectionStrategy.allCases)
    XCTAssertEqual(result, .exhausted)
}

let textInjectorTests: [TestCase] = [
    TestCase("testRangeCoversWordPlusTail", testRangeCoversWordPlusTail),
    TestCase("testRangeWithoutTail", testRangeWithoutTail),
    TestCase("testRangeRejectsNegativeStart", testRangeRejectsNegativeStart),
    TestCase("testRangeUsesUTF16Length", testRangeUsesUTF16Length),
    TestCase("testStrategyOrderPrefersAXDirect", testStrategyOrderPrefersAXDirect),
    TestCase("testCacheStartsEmptyAndRecordsSuccess", testCacheStartsEmptyAndRecordsSuccess),
    TestCase("testFailureDemotesCachedStrategy", testFailureDemotesCachedStrategy),
    TestCase("testKeycodeReplayRefusesEmptyStrokes", testKeycodeReplayRefusesEmptyStrokes),
    TestCase("testSelectionMatchTrustsUnreadableSelection", testSelectionMatchTrustsUnreadableSelection),
    TestCase("testSelectionMatchAcceptsExactSelection", testSelectionMatchAcceptsExactSelection),
    TestCase("testSelectionMatchCatchesMismatch", testSelectionMatchCatchesMismatch),
    TestCase("testReplaceRefusesEmptyReplacement", testReplaceRefusesEmptyReplacement),
    TestCase("testTrialContinuesPastNotApplicable", testTrialContinuesPastNotApplicable),
    TestCase("testTrialStopsAtMutatedUnverified", testTrialStopsAtMutatedUnverified),
    TestCase("testTrialStopsImmediatelyOnSucceeded", testTrialStopsImmediatelyOnSucceeded),
    TestCase("testTrialExhaustedWhenAllNotApplicable", testTrialExhaustedWhenAllNotApplicable)
]
