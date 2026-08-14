# Switcher Core Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Переписать ядро Switcher так, чтобы детекция неверной раскладки опиралась на калиброванную триграммную модель, а замена текста выполнялась с проверкой состояния вместо угаданных задержек.

**Architecture:** Event tap живёт на выделенном потоке со своим run loop и в callback'е делает только работу с памятью; детекция — чистая функция на фоновой очереди; замена — четыре стратегии с pre-flight проверкой текста под кареткой, пост-проверкой и кэшем возможностей приложения.

**Tech Stack:** Swift 5.9, SwiftPM, macOS 14+, Carbon (`UCKeyTranslate`, TIS), ApplicationServices (AX), CoreGraphics (`CGEventTap`), XCTest, Python 3 (только для офлайн-генерации ресурса).

## Global Constraints

- Целевая платформа: `.macOS(.v14)`, swift-tools-version 5.9.
- Языки: только EN и RU. Никаких других раскладок в этом плане.
- Никаких сторонних зависимостей в `Package.swift`.
- В callback'е `CGEventTap` запрещены: AX-вызовы, `NSSpellChecker`, `Timer`, файловый и сетевой ввод-вывод, любые блокирующие примитивы.
- На пути замены запрещён `DispatchQueue.asyncAfter` с угаданной задержкой. Допустимы только: синхронные AX-вызовы с `AXUIElementSetMessagingTimeout(el, 0.25)`, ожидание системного уведомления, гарантированный порядок доставки внутри одного `CGEventSource`.
- Все AX-диапазоны считаются в UTF-16 (`String.utf16.count`), не в графемах.
- Синтетические события создаются из одного общего `CGEventSource(stateID: .privateState)` с `userData = 0x57495443`.
- Рабочая ветка: `core-rewrite`. Коммит после каждой задачи.
- Язык комментариев в коде и сообщений коммитов — русский, как в существующем коде.

**Спека:** `docs/superpowers/specs/2026-08-13-switcher-core-rewrite-design.md`

---

## File Structure

Создаются:

| Файл | Ответственность |
|---|---|
| `Sources/Switcher/Core/Layout/Layout.swift` | `enum Layout`, `struct KeyStroke` — общие типы |
| `Sources/Switcher/Core/Layout/KeyboardLayoutTable.swift` | таблица keyCode↔символ одной раскладки, загрузка через `UCKeyTranslate` |
| `Sources/Switcher/Core/Layout/LayoutMapper.swift` | транспонирование текста между EN и RU |
| `Sources/Switcher/Core/Detection/TrigramModel.swift` | загрузка бинарного ресурса, `meanLogProb` |
| `Sources/Switcher/Core/Detection/GuardRules.swift` | URL/email/пути, пароли, исключения слов и приложений |
| `Sources/Switcher/Core/Detection/LayoutDetector.swift` | вердикт: чистая функция |
| `Sources/Switcher/Core/Detection/LanguagePrior.swift` | язык последних слов, сдвиг порога |
| `Sources/Switcher/Core/Input/KeystrokeBuffer.swift` | буфер нажатий, границы слов |
| `Sources/Switcher/Core/Input/EventTapController.swift` | тап на выделенном потоке, метка synthetic |
| `Sources/Switcher/Core/Replacement/AXTextClient.swift` | обёртка над AX с таймаутом |
| `Sources/Switcher/Core/Replacement/ClipboardGuard.swift` | снимок и восстановление pasteboard |
| `Sources/Switcher/Core/Replacement/TextInjector.swift` | четыре стратегии, кэш возможностей |
| `Sources/Switcher/Core/SwitchCoordinator.swift` | оркестрация, undo, double Shift |
| `Tools/build_trigram_model.py` | офлайн-генератор ресурса модели |
| `Sources/Switcher/Resources/en.trigram`, `ru.trigram` | вшитые модели |

Удаляются: `Sources/Switcher/Core/KeyboardEngine.swift`, `Sources/Switcher/Core/LayoutConverter.swift`, `Sources/Switcher/Core/SpellCheckService.swift`, `Sources/Switcher/Core/TextReplacer.swift`.

Не трогаем: `AppState.swift`, `SwitchDictionary.swift`, `InputSourceManager.swift`, `Views/`.

---

## Task 1: Починить сборку и получить зелёный baseline

Проект сейчас не собирается: обе цели претендуют на `Sources/Switcher`.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SwitcherApp/main.swift`
- Modify: `Sources/Switcher/SwitcherApp.swift` → перенести в `Sources/SwitcherApp/`
- Modify: `Makefile:17,25`
- Delete: `Tests/SwitcherTests/SpellCheckServiceTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces: собирающийся пакет с целями `SwitcherCore` (библиотека) и `SwitcherApp` (исполняемая); `swift test` работает

- [ ] **Step 1: Убедиться, что сборка сейчас падает**

Run: `swift build 2>&1 | head -5`
Expected: `error: target 'Switcher' has overlapping sources`

- [ ] **Step 2: Развести цели по разным каталогам**

```bash
mkdir -p Sources/SwitcherApp
git mv Sources/Switcher/SwitcherApp.swift Sources/SwitcherApp/SwitcherApp.swift
git mv Sources/Switcher/AppDelegate.swift  Sources/SwitcherApp/AppDelegate.swift
git mv Sources/Switcher/Views             Sources/SwitcherApp/Views
```

`Package.swift` целиком:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Switcher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "SwitcherCore",
            path: "Sources/Switcher"
        ),
        .executableTarget(
            name: "SwitcherApp",
            dependencies: ["SwitcherCore"],
            path: "Sources/SwitcherApp"
        ),
        .testTarget(
            name: "SwitcherTests",
            dependencies: ["SwitcherCore"],
            path: "Tests/SwitcherTests"
        )
    ]
)
```

- [ ] **Step 3: Открыть типы ядра для исполняемой цели**

`Views/` и `AppDelegate` обращаются к `AppState`, `SwitchDictionary`, `CorrectionRule`, `LastSwitchInfo`, `KeyboardEngine`. После разделения целей им нужен `public`. Добавить `import SwitcherCore` в каждый файл `Sources/SwitcherApp/**/*.swift` и пометить `public` типы и члены, к которым обращается UI. Собирать итеративно: `swift build 2>&1 | grep -E "^.*error:" | head -20`, пока ошибок не останется.

- [ ] **Step 4: Удалить тест, зависящий от системных словарей**

`Tests/SwitcherTests/SpellCheckServiceTests.swift` проверяет `detectWrongLayout` через `NSSpellChecker` — результат зависит от того, установлен ли на машине русский словарь. Такой тест недетерминирован и будет заменён калибровочным в Task 6.

```bash
git rm Tests/SwitcherTests/SpellCheckServiceTests.swift
```

- [ ] **Step 5: Обновить Makefile под новое имя бинарника**

`Makefile:25` копирует `$(BUILD_DIR)/$(APP_NAME)`, то есть `.build/release/Switcher`. Теперь исполняемая цель называется `SwitcherApp`. Заменить строку 25 на:

```makefile
	@cp $(BUILD_DIR)/SwitcherApp $(CONTENTS)/MacOS/$(APP_NAME)
```

- [ ] **Step 6: Проверить, что всё собирается и тесты идут**

Run: `swift build && swift test 2>&1 | tail -20`
Expected: сборка без ошибок; тесты `LayoutConverterTests` и `KeyboardEngineDetectionTests` проходят.

- [ ] **Step 7: Коммит**

```bash
git add -A
git commit -m "fix: развести цели SwitcherCore и SwitcherApp по разным каталогам

Пакет не собирался: обе цели претендовали на Sources/Switcher.
Удалён SpellCheckServiceTests — зависел от наличия системного
русского словаря и был недетерминирован."
```

---

## Task 2: KeyboardLayoutTable — чтение реальной раскладки через UCKeyTranslate

**Files:**
- Create: `Sources/Switcher/Core/Layout/Layout.swift`
- Create: `Sources/Switcher/Core/Layout/KeyboardLayoutTable.swift`
- Test: `Tests/SwitcherTests/KeyboardLayoutTableTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `public enum Layout: String { case en, ru }`
  - `public struct KeyStroke: Equatable { public let keyCode: CGKeyCode; public let shift: Bool; public let char: Character }`
  - `public struct KeyboardLayoutTable { public init(map: [UInt32: Character]); public static func load(layoutData: Data, keyboardType: UInt32) -> KeyboardLayoutTable?; public func character(keyCode: CGKeyCode, shift: Bool) -> Character?; public func keyCode(for char: Character) -> (keyCode: CGKeyCode, shift: Bool)? }`
  - Ключ словаря `map`: `UInt32(keyCode) << 1 | (shift ? 1 : 0)`

- [ ] **Step 1: Написать падающий тест**

`Tests/SwitcherTests/KeyboardLayoutTableTests.swift`:

```swift
import XCTest
import Carbon
@testable import SwitcherCore

final class KeyboardLayoutTableTests: XCTestCase {

    /// Ключ: keyCode << 1 | shift
    private func key(_ code: CGKeyCode, _ shift: Bool) -> UInt32 {
        UInt32(code) << 1 | (shift ? 1 : 0)
    }

    func testLookupByKeyCode() {
        let table = KeyboardLayoutTable(map: [
            key(12, false): "q", key(12, true): "Q",
            key(13, false): "w", key(13, true): "W"
        ])
        XCTAssertEqual(table.character(keyCode: 12, shift: false), "q")
        XCTAssertEqual(table.character(keyCode: 12, shift: true),  "Q")
        XCTAssertNil(table.character(keyCode: 99, shift: false))
    }

    func testReverseLookupByCharacter() {
        let table = KeyboardLayoutTable(map: [
            key(12, false): "q", key(12, true): "Q"
        ])
        let hit = table.keyCode(for: "Q")
        XCTAssertEqual(hit?.keyCode, 12)
        XCTAssertEqual(hit?.shift, true)
        XCTAssertNil(table.keyCode(for: "z"))
    }

    /// Загрузка живой раскладки США. Установлена всегда, поэтому тест не пропускается.
    func testLoadsUSLayoutFromSystem() throws {
        let data = try XCTUnwrap(Self.systemLayoutData(matching: "com.apple.keylayout.US"),
                                 "Раскладка США должна присутствовать в системе")
        let table = try XCTUnwrap(KeyboardLayoutTable.load(
            layoutData: data,
            keyboardType: UInt32(LMGetKbdType())
        ))
        // Физические клавиши QWERTY: 12=q, 0=a, 6=z
        XCTAssertEqual(table.character(keyCode: 12, shift: false), "q")
        XCTAssertEqual(table.character(keyCode: 0,  shift: false), "a")
        XCTAssertEqual(table.character(keyCode: 6,  shift: false), "z")
        XCTAssertEqual(table.character(keyCode: 12, shift: true),  "Q")
    }

    static func systemLayoutData(matching id: String) -> Data? {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, true)?
            .takeRetainedValue() else { return nil }
        for i in 0..<CFArrayGetCount(list) {
            guard let ptr = CFArrayGetValueAtIndex(list, i) else { continue }
            let source = Unmanaged<TISInputSource>.fromOpaque(ptr).takeUnretainedValue()
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            guard sourceID == id else { continue }
            guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        }
        return nil
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter KeyboardLayoutTableTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'KeyboardLayoutTable' in scope`

- [ ] **Step 3: Реализовать типы**

`Sources/Switcher/Core/Layout/Layout.swift`:

```swift
import CoreGraphics

/// Раскладка, с которой работает Switcher. Только EN и RU.
public enum Layout: String, Sendable {
    case en
    case ru

    public var opposite: Layout { self == .en ? .ru : .en }

    /// Разбор кода языка из TIS ("en-US", "ru", "ru-RU").
    public init?(languageCode: String) {
        switch languageCode.prefix(2).lowercased() {
        case "en": self = .en
        case "ru": self = .ru
        default:   return nil
        }
    }
}

/// Одно нажатие: физическая клавиша, состояние Shift и символ, который в итоге попал в текст.
/// Храним keycode, а не только символ — это позволяет переиграть нажатия в другой раскладке.
public struct KeyStroke: Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let shift:   Bool
    public let char:    Character

    public init(keyCode: CGKeyCode, shift: Bool, char: Character) {
        self.keyCode = keyCode
        self.shift   = shift
        self.char    = char
    }
}
```

`Sources/Switcher/Core/Layout/KeyboardLayoutTable.swift`:

```swift
import Carbon
import CoreGraphics
import Foundation

/// Таблица соответствий «физическая клавиша ↔ символ» для одной раскладки.
///
/// Строится из данных `kTISPropertyUnicodeKeyLayoutData` реального источника ввода,
/// поэтому корректно описывает и «Русскую», и «Русскую — ПК», у которых знаки
/// препинания стоят на разных клавишах.
public struct KeyboardLayoutTable {

    /// Ключ: keyCode << 1 | shift
    private let forward: [UInt32: Character]
    private let reverse: [Character: (keyCode: CGKeyCode, shift: Bool)]

    public init(map: [UInt32: Character]) {
        forward = map
        var rev: [Character: (CGKeyCode, Bool)] = [:]
        // Меньший keyCode выигрывает: даёт стабильный результат независимо
        // от порядка обхода словаря.
        for (key, char) in map.sorted(by: { $0.key < $1.key }) where rev[char] == nil {
            rev[char] = (CGKeyCode(key >> 1), key & 1 == 1)
        }
        reverse = rev
    }

    public func character(keyCode: CGKeyCode, shift: Bool) -> Character? {
        forward[UInt32(keyCode) << 1 | (shift ? 1 : 0)]
    }

    public func keyCode(for char: Character) -> (keyCode: CGKeyCode, shift: Bool)? {
        reverse[char]
    }

    /// Прогоняет все клавиши основного блока через `UCKeyTranslate`.
    /// Возвращает nil, если данные раскладки непригодны (например, у источника
    /// ввода это IME, а не keyboard layout).
    public static func load(layoutData: Data, keyboardType: UInt32) -> KeyboardLayoutTable? {
        // Основной буквенно-цифровой блок. Модификаторы, функциональные клавиши
        // и цифровую панель не включаем — они не участвуют в наборе слов.
        let keyCodes: [CGKeyCode] = Array(0...50)
        var map: [UInt32: Character] = [:]

        let ok = layoutData.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            for code in keyCodes {
                for shift in [false, true] {
                    // Биты модификаторов в UCKeyTranslate — это старший байт
                    // EventRecord.modifiers, сдвинутый вправо на 8.
                    let modifierState: UInt32 = shift ? UInt32(shiftKey >> 8) : 0
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)

                    let status = UCKeyTranslate(
                        layout,
                        UInt16(code),
                        UInt16(kUCKeyActionDown),
                        modifierState,
                        keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                        &deadKeyState,
                        chars.count,
                        &length,
                        &chars
                    )
                    guard status == noErr, length == 1,
                          let scalar = Unicode.Scalar(chars[0]) else { continue }
                    let char = Character(scalar)
                    // Управляющие символы (Return, Tab, Escape) не нужны.
                    guard !char.isNewline, !char.unicodeScalars.contains(where: { $0.value < 0x20 })
                    else { continue }
                    map[UInt32(code) << 1 | (shift ? 1 : 0)] = char
                }
            }
            return true
        }

        guard ok, !map.isEmpty else { return nil }
        return KeyboardLayoutTable(map: map)
    }
}
```

- [ ] **Step 4: Проверить, что тест проходит**

Run: `swift test --filter KeyboardLayoutTableTests 2>&1 | tail -5`
Expected: PASS, 3 теста

- [ ] **Step 5: Коммит**

```bash
git add Sources/Switcher/Core/Layout Tests/SwitcherTests/KeyboardLayoutTableTests.swift
git commit -m "feat: KeyboardLayoutTable — чтение раскладки через UCKeyTranslate

Таблица строится из данных реального источника ввода, поэтому
одинаково корректна для «Русской» и «Русской — ПК»."
```

---

## Task 3: LayoutMapper — транспонирование текста между EN и RU

**Files:**
- Create: `Sources/Switcher/Core/Layout/LayoutMapper.swift`
- Test: `Tests/SwitcherTests/LayoutMapperTests.swift`
- Delete: `Sources/Switcher/Core/LayoutConverter.swift`, `Tests/SwitcherTests/LayoutConverterTests.swift`

**Interfaces:**
- Consumes: `Layout`, `KeyStroke`, `KeyboardLayoutTable` (Task 2)
- Produces:
  - `public final class LayoutMapper { public init(tables: [Layout: KeyboardLayoutTable]); public func transpose(_ text: String, from: Layout, to: Layout) -> String?; public func transpose(strokes: [KeyStroke], to: Layout) -> String? }`
  - `transpose` возвращает `nil`, если хотя бы один символ не удалось отобразить

- [ ] **Step 1: Написать падающий тест**

`Tests/SwitcherTests/LayoutMapperTests.swift`:

```swift
import XCTest
import Carbon
@testable import SwitcherCore

final class LayoutMapperTests: XCTestCase {

    /// Собирает маппер из живых системных раскладок.
    /// Возвращает nil, если русская раскладка не установлена.
    private func systemMapper(ruLayoutID: String) -> LayoutMapper? {
        guard let enData = KeyboardLayoutTableTests.systemLayoutData(matching: "com.apple.keylayout.US"),
              let ruData = KeyboardLayoutTableTests.systemLayoutData(matching: ruLayoutID),
              let en = KeyboardLayoutTable.load(layoutData: enData, keyboardType: UInt32(LMGetKbdType())),
              let ru = KeyboardLayoutTable.load(layoutData: ruData, keyboardType: UInt32(LMGetKbdType()))
        else { return nil }
        return LayoutMapper(tables: [.en: en, .ru: ru])
    }

    func testTransposesLettersOnRussianPC() throws {
        guard let mapper = systemMapper(ruLayoutID: "com.apple.keylayout.RussianWin") else {
            throw XCTSkip("Раскладка «Русская — ПК» не установлена")
        }
        XCTAssertEqual(mapper.transpose("ghbdtn", from: .en, to: .ru), "привет")
        XCTAssertEqual(mapper.transpose("привет", from: .ru, to: .en), "ghbdtn")
    }

    /// Ключевая проверка: слова со знаками препинания в позиции букв.
    /// «любовь» на ПК-раскладке набирается как "k.,jdm", а на «Русской» — иначе.
    /// Обе должны отработать без хардкода таблицы.
    func testTransposesPunctuationPositionedLetters() throws {
        var tested = 0
        for layoutID in ["com.apple.keylayout.RussianWin", "com.apple.keylayout.Russian"] {
            guard let mapper = systemMapper(ruLayoutID: layoutID) else { continue }
            tested += 1
            let typed = try XCTUnwrap(mapper.transpose("любовь", from: .ru, to: .en),
                                      "\(layoutID): прямое преобразование должно работать")
            XCTAssertEqual(mapper.transpose(typed, from: .en, to: .ru), "любовь",
                           "\(layoutID): round-trip должен вернуть исходное слово")
        }
        // Без этой проверки тест проходит ВХОЛОСТУЮ на машине без русских
        // раскладок: цикл не выполняется, ни один ассерт не срабатывает, и
        // харнесс засчитывает тест как пройденный. Это центральная проверка
        // задачи — она обязана либо реально отработать, либо честно пропуститься.
        try XCTSkipUnless(tested > 0, "Ни одна русская раскладка не установлена")
    }

    func testPreservesCase() throws {
        guard let mapper = systemMapper(ruLayoutID: "com.apple.keylayout.RussianWin") else {
            throw XCTSkip("Раскладка «Русская — ПК» не установлена")
        }
        XCTAssertEqual(mapper.transpose("Ghbdtn", from: .en, to: .ru), "Привет")
    }

    func testReturnsNilForUnmappableCharacter() {
        // Пустые таблицы: отобразить нечего.
        let mapper = LayoutMapper(tables: [.en: KeyboardLayoutTable(map: [:]),
                                           .ru: KeyboardLayoutTable(map: [:])])
        XCTAssertNil(mapper.transpose("abc", from: .en, to: .ru))
    }

    func testDigitsAndHyphenPassThrough() {
        let enMap: [UInt32: Character] = [UInt32(12) << 1: "q"]
        let ruMap: [UInt32: Character] = [UInt32(12) << 1: "й"]
        let mapper = LayoutMapper(tables: [.en: KeyboardLayoutTable(map: enMap),
                                           .ru: KeyboardLayoutTable(map: ruMap)])
        XCTAssertEqual(mapper.transpose("q1-q", from: .en, to: .ru), "й1-й")
    }

    func testTransposesStrokes() {
        let ruMap: [UInt32: Character] = [UInt32(12) << 1: "й", UInt32(13) << 1: "ц"]
        let mapper = LayoutMapper(tables: [.en: KeyboardLayoutTable(map: [:]),
                                           .ru: KeyboardLayoutTable(map: ruMap)])
        let strokes = [KeyStroke(keyCode: 12, shift: false, char: "q"),
                       KeyStroke(keyCode: 13, shift: false, char: "w")]
        XCTAssertEqual(mapper.transpose(strokes: strokes, to: .ru), "йц")
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter LayoutMapperTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'LayoutMapper' in scope`

- [ ] **Step 3: Реализовать LayoutMapper**

```swift
import CoreGraphics
import Foundation

/// Переносит текст между раскладками через физические клавиши.
///
/// Символ ищется в исходной таблице, из неё берётся клавиша, и по той же клавише
/// берётся символ целевой таблицы. Никаких зашитых таблиц соответствий: всё
/// выводится из данных реально установленных раскладок.
public final class LayoutMapper {

    private let tables: [Layout: KeyboardLayoutTable]

    /// Символы, не зависящие от раскладки: проходят насквозь.
    private static let layoutIndependent = CharacterSet(charactersIn: "0123456789-_ ")

    public init(tables: [Layout: KeyboardLayoutTable]) {
        self.tables = tables
    }

    /// Возвращает nil, если хотя бы один символ отобразить не удалось —
    /// частичная конверсия хуже, чем отсутствие конверсии.
    public func transpose(_ text: String, from: Layout, to: Layout) -> String? {
        guard let source = tables[from], let target = tables[to] else { return nil }

        var result = ""
        result.reserveCapacity(text.count)

        for char in text {
            if char.unicodeScalars.allSatisfy({ Self.layoutIndependent.contains($0) }) {
                result.append(char)
                continue
            }
            guard let stroke = source.keyCode(for: char),
                  let mapped = target.character(keyCode: stroke.keyCode, shift: stroke.shift)
            else { return nil }
            result.append(mapped)
        }
        return result
    }

    /// Отрисовывает записанные нажатия в целевой раскладке.
    /// Точнее строкового пути: keycode известен напрямую, обратный поиск не нужен.
    public func transpose(strokes: [KeyStroke], to: Layout) -> String? {
        guard let target = tables[to] else { return nil }

        var result = ""
        result.reserveCapacity(strokes.count)

        for stroke in strokes {
            if let mapped = target.character(keyCode: stroke.keyCode, shift: stroke.shift) {
                result.append(mapped)
            } else if stroke.char.unicodeScalars.allSatisfy({ Self.layoutIndependent.contains($0) }) {
                result.append(stroke.char)
            } else {
                return nil
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Проверить, что тест проходит**

Run: `swift test --filter LayoutMapperTests 2>&1 | tail -5`
Expected: PASS. Тесты с русской раскладкой пропускаются (`XCTSkip`), если она не установлена — это ожидаемо.

- [ ] **Step 5: Удалить старый конвертер**

```bash
git rm Sources/Switcher/Core/LayoutConverter.swift Tests/SwitcherTests/LayoutConverterTests.swift
```

`KeyboardEngine.swift` ссылается на `LayoutConverter` и перестанет собираться. Это ожидаемо и чинится в Task 11, когда `KeyboardEngine` удаляется целиком. Чтобы держать сборку зелёной до тех пор, временно закомментировать тело `KeyboardEngine.swift` целиком, обернув файл в `#if false ... #endif`, и убрать его создание из `AppState.swift`, заменив на заглушку:

```swift
// AppState.swift — временно, до Task 11
let engine = KeyboardEngineStub()
```

Создать `Sources/Switcher/Core/KeyboardEngineStub.swift` с пустыми свойствами и методами, которые дёргает `AppState`: `autoSwitchEnabled`, `doubleShiftEnabled`, `spellCheckEnabled`, `minWordLength`, `learningEnabled`, `exclusions`, `excludedApps`, `corrections`, `onSwitched`, `onUndone`, `start()`, `stop()`, `isRunning`, `currentLanguage()`, `performUndoFromUI()`.

- [ ] **Step 6: Проверить сборку и все тесты**

Run: `swift build && swift test 2>&1 | tail -10`
Expected: сборка чистая, все тесты проходят

- [ ] **Step 7: Коммит**

```bash
git add -A
git commit -m "feat: LayoutMapper на основе реальных раскладок

Заменяет захардкоженную таблицу на 70 пар. Соответствия выводятся
из данных установленных источников ввода, поэтому знаки препинания
корректны на обеих русских раскладках.

KeyboardEngine временно отключён через #if false — удаляется в Task 11."
```

---

## Task 4: Генератор триграммной модели и бинарный ресурс

**Files:**
- Create: `Tools/build_trigram_model.py`
- Create: `Sources/Switcher/Resources/en.trigram`, `Sources/Switcher/Resources/ru.trigram` (генерируются)
- Modify: `Package.swift`
- Modify: `Makefile`

**Interfaces:**
- Consumes: ничего
- Produces: два бинарных файла формата STG2 (описан ниже) и SwiftPM-ресурс в цели `SwitcherCore`

**Формат STG2** (little-endian, плотный массив — прямая индексация без поиска):

```
смещение   размер     содержимое
0          4          магия "STG2" (ASCII)
4          4          A — размер алфавита, UInt32
8          A*4        алфавит, скаляры Unicode, UInt32 каждый; индекс 0 — граница слова
8+A*4      A³*4       log10 условных вероятностей, Float32, индекс = i0*A² + i1*A + i2
```

Алфавиты (индекс 0 — маркер границы `^`):
- en: `^abcdefghijklmnopqrstuvwxyz'` → A = 28, A³ = 21952, файл ≈ 88 КБ
- ru: `^абвгдеёжзийклмнопрстуфхцчшщъыьэюя` → A = 34, A³ = 39304, файл ≈ 157 КБ

Значение — `log10 P(c₂ | c₀c₁)` со сглаживанием add-k, k = 0.5:
`P = (count(c₀c₁c₂) + k) / (count(c₀c₁) + k·A)`

- [ ] **Step 1: Написать генератор**

`Tools/build_trigram_model.py`:

```python
#!/usr/bin/env python3
"""Строит триграммную модель символов для Switcher.

Скачивает открытые частотные списки слов (OpenSubtitles, CC-BY-SA) и
записывает плотную таблицу log10 условных вероятностей в формате STG2.

Запускается вручную при необходимости пересобрать модель; результат
коммитится в репозиторий, поэтому в рантайме сеть не нужна.

    python3 Tools/build_trigram_model.py
"""
import struct
import sys
import urllib.request
from pathlib import Path

BOUNDARY = "^"
ALPHABETS = {
    "en": BOUNDARY + "abcdefghijklmnopqrstuvwxyz'",
    "ru": BOUNDARY + "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
}
SOURCES = {
    "en": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt",
    "ru": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt",
}
SMOOTHING_K = 0.5
OUT_DIR = Path(__file__).resolve().parent.parent / "Sources" / "Switcher" / "Resources"


def load_words(lang):
    """Возвращает список (слово, частота) из частотного списка."""
    print(f"  скачиваю {SOURCES[lang]}")
    with urllib.request.urlopen(SOURCES[lang]) as response:
        text = response.read().decode("utf-8")

    alphabet = set(ALPHABETS[lang][1:])
    words = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        word, count = parts[0].lower(), int(parts[1])
        # Слова с посторонними символами (цифры, латиница в русском списке)
        # искажают статистику — отбрасываем.
        if word and all(ch in alphabet for ch in word):
            words.append((word, count))
    print(f"  принято слов: {len(words)}")
    return words


def build(lang):
    alphabet = ALPHABETS[lang]
    A = len(alphabet)
    index = {ch: i for i, ch in enumerate(alphabet)}

    trigram = [0.0] * (A * A * A)
    bigram = [0.0] * (A * A)

    for word, count in load_words(lang):
        # Паддинг границами: ^^слово^
        padded = BOUNDARY * 2 + word + BOUNDARY
        ids = [index[ch] for ch in padded]
        for i in range(len(ids) - 2):
            a, b, c = ids[i], ids[i + 1], ids[i + 2]
            trigram[a * A * A + b * A + c] += count
            bigram[a * A + b] += count

    import math
    probs = []
    for a in range(A):
        for b in range(A):
            context = bigram[a * A + b]
            denominator = context + SMOOTHING_K * A
            for c in range(A):
                numerator = trigram[a * A * A + b * A + c] + SMOOTHING_K
                probs.append(math.log10(numerator / denominator))

    out = bytearray(b"STG2")
    out += struct.pack("<I", A)
    for ch in alphabet:
        out += struct.pack("<I", ord(ch))
    for p in probs:
        out += struct.pack("<f", p)

    path = OUT_DIR / f"{lang}.trigram"
    path.write_bytes(out)
    print(f"  записано {path} ({len(out)} байт, A={A})")


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for lang in ("en", "ru"):
        print(f"[{lang}]")
        build(lang)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Сгенерировать ресурсы и проверить размеры**

Run:
```bash
python3 Tools/build_trigram_model.py
ls -l Sources/Switcher/Resources/*.trigram
```
Expected: `en.trigram` ≈ 87 928 байт, `ru.trigram` ≈ 157 360 байт

Sanity-проверка содержимого — «привет» должно быть вероятнее «ghbdtn» по русской модели:

```bash
python3 - <<'PY'
import struct, math
data = open("Sources/Switcher/Resources/ru.trigram","rb").read()
assert data[:4] == b"STG2"
A = struct.unpack_from("<I", data, 4)[0]
alphabet = "".join(chr(struct.unpack_from("<I", data, 8+i*4)[0]) for i in range(A))
base = 8 + A*4
idx = {ch:i for i,ch in enumerate(alphabet)}
def score(w):
    p = "^^" + w + "^"
    ids = [idx[c] for c in p]
    vals = [struct.unpack_from("<f", data, base + 4*(ids[i]*A*A + ids[i+1]*A + ids[i+2]))[0]
            for i in range(len(ids)-2)]
    return sum(vals)/len(vals)
print("A =", A, "алфавит:", alphabet)
print("привет:", round(score("привет"), 3))
print("ывапрол:", round(score("ывапрол"), 3))
assert score("привет") > score("ывапрол")
print("OK")
PY
```
Expected: `привет` заметно выше, чем `ывапрол`; печатается `OK`

- [ ] **Step 3: Подключить ресурсы к цели SwitcherCore**

В `Package.swift` цель `SwitcherCore`:

```swift
        .target(
            name: "SwitcherCore",
            path: "Sources/Switcher",
            resources: [.copy("Resources/en.trigram"), .copy("Resources/ru.trigram")]
        ),
```

- [ ] **Step 4: Убедиться, что SwiftPM собирает бандл ресурсов**

Run:
```bash
swift build -c release && ls -d .build/release/*.bundle && ls .build/release/*.bundle/Contents/Resources/
```
Expected: каталог `Switcher_SwitcherCore.bundle`, внутри `en.trigram` и `ru.trigram`.

Записать фактическое имя бандла — оно понадобится в следующем шаге.

- [ ] **Step 5: Копировать бандл ресурсов в .app**

`Makefile:20-28` копирует в бандл только `Info.plist` и иконку, поэтому в собранном приложении модели не будет и загрузка упадёт. Добавить в цель `bundle` после строки с `AppIcon.icns`:

```makefile
	@cp -R $(BUILD_DIR)/Switcher_SwitcherCore.bundle $(CONTENTS)/Resources/
```

- [ ] **Step 6: Проверить, что ресурс попал в .app**

Run: `make bundle && ls Switcher.app/Contents/Resources/Switcher_SwitcherCore.bundle/Contents/Resources/`
Expected: `en.trigram`, `ru.trigram`

- [ ] **Step 7: Коммит**

```bash
git add Tools/build_trigram_model.py Sources/Switcher/Resources/*.trigram Package.swift Makefile
git commit -m "feat: генератор триграммной модели и вшитые ресурсы

Плотная таблица log10 P(c2|c0c1) со сглаживанием add-k по частотным
спискам OpenSubtitles. Формат STG2 индексируется напрямую, без поиска.
В рантайме сеть не нужна: ресурс коммитится."
```

---

## Task 5: TrigramModel — загрузка и оценка

**Files:**
- Create: `Sources/Switcher/Core/Detection/TrigramModel.swift`
- Test: `Tests/SwitcherTests/TrigramModelTests.swift`

**Interfaces:**
- Consumes: `Layout` (Task 2), ресурсы `*.trigram` (Task 4)
- Produces:
  - `public final class TrigramModel { public static func bundled(_ layout: Layout) throws -> TrigramModel; public init(data: Data) throws; public func meanLogProb(_ word: String, terminated: Bool) -> Double? }`
  - `public enum TrigramModelError: Error { case badMagic, truncated, resourceMissing }`
  - `meanLogProb` возвращает `nil`, если слово содержит символы вне алфавита или короче двух символов
  - `terminated: true` — слово целиком (`^^слово^`), `false` — префикс (`^^сло`)

- [ ] **Step 1: Написать падающий тест**

`Tests/SwitcherTests/TrigramModelTests.swift`:

```swift
import XCTest
@testable import SwitcherCore

final class TrigramModelTests: XCTestCase {

    func testLoadsBundledModels() throws {
        XCTAssertNoThrow(try TrigramModel.bundled(.en))
        XCTAssertNoThrow(try TrigramModel.bundled(.ru))
    }

    func testRealWordScoresHigherThanGibberish() throws {
        let ru = try TrigramModel.bundled(.ru)
        let real = try XCTUnwrap(ru.meanLogProb("привет", terminated: true))
        let junk = try XCTUnwrap(ru.meanLogProb("ывапрол", terminated: true))
        XCTAssertGreaterThan(real, junk)

        let en = try TrigramModel.bundled(.en)
        let realEn = try XCTUnwrap(en.meanLogProb("hello", terminated: true))
        let junkEn = try XCTUnwrap(en.meanLogProb("ghbdtn", terminated: true))
        XCTAssertGreaterThan(realEn, junkEn)
    }

    func testWrongLayoutTextScoresLowInSourceLanguage() throws {
        let en = try TrigramModel.bundled(.en)
        let ru = try TrigramModel.bundled(.ru)
        // "ghbdtn" — это «привет», набранное в английской раскладке.
        let asEnglish = try XCTUnwrap(en.meanLogProb("ghbdtn", terminated: true))
        let asRussian = try XCTUnwrap(ru.meanLogProb("привет", terminated: true))
        XCTAssertGreaterThan(asRussian - asEnglish, 1.0,
                             "Разрыв должен быть уверенным, а не пограничным")
    }

    func testReturnsNilForForeignCharacters() throws {
        let en = try TrigramModel.bundled(.en)
        XCTAssertNil(en.meanLogProb("привет", terminated: true))
        XCTAssertNil(en.meanLogProb("he11o", terminated: true))
    }

    func testReturnsNilForTooShortWord() throws {
        let en = try TrigramModel.bundled(.en)
        XCTAssertNil(en.meanLogProb("a", terminated: true))
    }

    func testPrefixScoringIgnoresWordEnd() throws {
        let ru = try TrigramModel.bundled(.ru)
        let prefix = try XCTUnwrap(ru.meanLogProb("прив", terminated: false))
        let whole  = try XCTUnwrap(ru.meanLogProb("прив", terminated: true))
        // "прив^" — неестественный конец слова, поэтому целиком оценивается хуже.
        XCTAssertGreaterThan(prefix, whole)
    }

    func testIsCaseInsensitive() throws {
        let ru = try TrigramModel.bundled(.ru)
        XCTAssertEqual(ru.meanLogProb("Привет", terminated: true),
                       ru.meanLogProb("привет", terminated: true))
    }

    func testRejectsBadMagic() {
        XCTAssertThrowsError(try TrigramModel(data: Data("XXXX".utf8)))
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter TrigramModelTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'TrigramModel' in scope`

- [ ] **Step 3: Реализовать TrigramModel**

```swift
import Foundation

public enum TrigramModelError: Error {
    case badMagic
    case truncated
    case resourceMissing(Layout)
}

/// Символьная триграммная модель языка.
///
/// Хранит плотную таблицу log10 P(c₂ | c₀c₁), поэтому оценка слова — это
/// арифметика по прямым индексам, без поиска и без аллокаций.
/// Формат ресурса описан в плане (STG2).
public final class TrigramModel {

    private let alphabetSize: Int
    private let indexOf: [Character: Int]
    private let probs: [Float]

    /// Индекс маркера границы слова — всегда 0.
    private static let boundaryIndex = 0

    public init(data: Data) throws {
        guard data.count >= 8, data[data.startIndex..<data.startIndex + 4] == Data("STG2".utf8) else {
            throw TrigramModelError.badMagic
        }

        let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        let alphabetBytes = size * 4
        let probsCount    = size * size * size
        guard data.count == 8 + alphabetBytes + probsCount * 4 else {
            throw TrigramModelError.truncated
        }

        var table: [Character: Int] = [:]
        var values = [Float](repeating: 0, count: probsCount)

        data.withUnsafeBytes { raw in
            for i in 0..<size {
                let scalarValue = raw.loadUnaligned(fromByteOffset: 8 + i * 4, as: UInt32.self)
                if let scalar = Unicode.Scalar(scalarValue) {
                    table[Character(scalar)] = i
                }
            }
            let base = 8 + alphabetBytes
            for i in 0..<probsCount {
                values[i] = raw.loadUnaligned(fromByteOffset: base + i * 4, as: Float.self)
            }
        }

        alphabetSize = size
        indexOf      = table
        probs        = values
    }

    public static func bundled(_ layout: Layout) throws -> TrigramModel {
        guard let url = Bundle.module.url(forResource: layout.rawValue, withExtension: "trigram") else {
            throw TrigramModelError.resourceMissing(layout)
        }
        return try TrigramModel(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// Средний log10 условной вероятности по триграммам слова.
    ///
    /// Нормировка на количество триграмм убирает перекос в пользу коротких слов:
    /// без неё длинное слово всегда проигрывало бы короткому.
    ///
    /// - Parameter terminated: `true` — слово дописано (`^^слово^`),
    ///   `false` — оценивается префикс (`^^сло`), концевой маркер не добавляется.
    /// - Returns: `nil`, если слово короче двух символов или содержит символы
    ///   вне алфавита модели — такое слово этой модели не принадлежит.
    public func meanLogProb(_ word: String, terminated: Bool) -> Double? {
        let lower = word.lowercased()
        guard lower.count >= 2 else { return nil }

        var ids = [Self.boundaryIndex, Self.boundaryIndex]
        ids.reserveCapacity(lower.count + 3)
        for char in lower {
            guard let index = indexOf[char], index != Self.boundaryIndex else { return nil }
            ids.append(index)
        }
        if terminated { ids.append(Self.boundaryIndex) }

        var total = 0.0
        let count = ids.count - 2
        for i in 0..<count {
            let offset = ids[i] * alphabetSize * alphabetSize
                       + ids[i + 1] * alphabetSize
                       + ids[i + 2]
            total += Double(probs[offset])
        }
        return total / Double(count)
    }
}
```

- [ ] **Step 4: Проверить, что тест проходит**

Run: `swift test --filter TrigramModelTests 2>&1 | tail -5`
Expected: PASS, 8 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/Switcher/Core/Detection/TrigramModel.swift Tests/SwitcherTests/TrigramModelTests.swift
git commit -m "feat: TrigramModel — оценка слова по вшитой модели языка

Средний log10 P(c2|c0c1) с нормировкой на длину. Режим префикса
позволяет оценивать недописанное слово для ранней конверсии."
```

---

## Task 6: LayoutDetector и калибровка порогов

Самая важная задача плана: пороги должны выводиться из измерений, а не назначаться.

**Files:**
- Create: `Sources/Switcher/Core/Detection/LayoutDetector.swift`
- Test: `Tests/SwitcherTests/LayoutDetectorCalibrationTests.swift`

**Interfaces:**
- Consumes: `Layout`, `LayoutMapper` (Task 3), `TrigramModel` (Task 5)
- Produces:
  - `public enum Trigger { case wordBoundary, pause, early }`
  - `public enum Verdict: Equatable { case keep; case convert(to: Layout, text: String) }`
  - `public protocol WordValidating: AnyObject { func isValid(_ word: String, in layout: Layout) -> Bool }`
  - `public final class LayoutDetector { public init(models: [Layout: TrigramModel], mapper: LayoutMapper, validator: WordValidating?); public func evaluate(word: String, currentLayout: Layout, trigger: Trigger) -> Verdict }`
  - `public struct DetectorThresholds { public var wordBoundary: Double; public var pause: Double; public var early: Double; public var earlyMinLength: Int; public static let calibrated: DetectorThresholds }`

- [ ] **Step 1: Написать калибровочный тест**

`Tests/SwitcherTests/LayoutDetectorCalibrationTests.swift`:

```swift
import XCTest
import Carbon
@testable import SwitcherCore

/// Калибровка: измеряем ложные срабатывания и пропуски на корпусе из
/// настоящих слов и их транспонированных версий.
final class LayoutDetectorCalibrationTests: XCTestCase {

    private var detector: LayoutDetector!
    private var mapper: LayoutMapper!

    override func setUpWithError() throws {
        guard let enData = KeyboardLayoutTableTests.systemLayoutData(matching: "com.apple.keylayout.US"),
              let ruData = KeyboardLayoutTableTests.systemLayoutData(matching: "com.apple.keylayout.RussianWin"),
              let en = KeyboardLayoutTable.load(layoutData: enData, keyboardType: UInt32(LMGetKbdType())),
              let ru = KeyboardLayoutTable.load(layoutData: ruData, keyboardType: UInt32(LMGetKbdType()))
        else { throw XCTSkip("Нужны раскладки США и «Русская — ПК»") }

        mapper = LayoutMapper(tables: [.en: en, .ru: ru])
        detector = LayoutDetector(
            models: [.en: try TrigramModel.bundled(.en), .ru: try TrigramModel.bundled(.ru)],
            mapper: mapper,
            validator: nil   // калибруем чистую статистику, без словаря
        )
    }

    /// Настоящие слова, набранные правильно, трогать нельзя.
    func testNoFalsePositivesOnCorrectlyTypedWords() {
        var falsePositives: [String] = []
        for (word, layout) in Self.corpus {
            if case .convert = detector.evaluate(word: word, currentLayout: layout, trigger: .wordBoundary) {
                falsePositives.append("\(word) [\(layout.rawValue)]")
            }
        }
        let rate = Double(falsePositives.count) / Double(Self.corpus.count)
        XCTAssertLessThan(rate, 0.02,
                          "Ложных срабатываний \(falsePositives.count)/\(Self.corpus.count): \(falsePositives.prefix(15))")
    }

    /// Слова, набранные не в той раскладке, должны исправляться.
    func testCatchesWrongLayoutWords() {
        var misses: [String] = []
        var total = 0
        for (word, layout) in Self.corpus {
            // Имитируем набор слова при активной противоположной раскладке.
            guard let typed = mapper.transpose(word, from: layout, to: layout.opposite) else { continue }
            total += 1
            guard case .convert(let to, let text) = detector.evaluate(
                word: typed, currentLayout: layout.opposite, trigger: .wordBoundary
            ), to == layout, text == word else {
                misses.append("\(typed) → ожидали \(word)")
                continue
            }
        }
        let rate = Double(misses.count) / Double(total)
        XCTAssertLessThan(rate, 0.10,
                          "Пропусков \(misses.count)/\(total): \(misses.prefix(15))")
    }

    /// Ранний порог строже: на границе слова он не должен ловить меньше, чем ранний.
    func testEarlyTriggerIsStricterThanWordBoundary() {
        XCTAssertGreaterThan(DetectorThresholds.calibrated.early,
                             DetectorThresholds.calibrated.wordBoundary)
    }

    /// Русские слова, где буквы стоят на клавишах знаков препинания.
    /// «любовь» в английской раскладке содержит "." и ",", поэтому английская
    /// модель его не оценивает — решение принимается по абсолютной оценке цели.
    func testCatchesWordsWithPunctuationPositionedLetters() throws {
        // Только слова от 4 букв: короче до детектора не доходит — их отсекает
        // guard по minWordLength (по умолчанию 4). Ставить порог под трёхбуквенное
        // «эхо» (-1.66) значило бы подгонять модель под случай, которого в работе
        // не бывает.
        for word in ["любовь", "объезд", "жизнь", "съезд", "подъезд"] {
            let typed = try XCTUnwrap(mapper.transpose(word, from: .ru, to: .en),
                                      "\(word): транспонирование должно работать")
            XCTAssertNil(try TrigramModel.bundled(.en).meanLogProb(typed, terminated: true),
                         "\(typed): английская модель такое слово оценить не может")
            XCTAssertEqual(detector.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                           .convert(to: .ru, text: word),
                           "\(typed) должно исправляться в «\(word)»")
        }
    }

    /// Настоящие английские слова с точкой на конце трогать нельзя.
    func testDoesNotTouchEnglishWordsWithTrailingPunctuation() {
        for word in ["hello.", "world,", "please.", "message,"] {
            XCTAssertEqual(detector.evaluate(word: word, currentLayout: .en, trigger: .wordBoundary),
                           .keep, "\(word) — обычное английское слово со знаком препинания")
        }
    }

    func testEarlyTriggerRejectsShortPrefixes() {
        guard let typed = mapper.transpose("привет", from: .ru, to: .en) else {
            return XCTFail("Транспонирование должно работать")
        }
        let shortPrefix = String(typed.prefix(4))
        XCTAssertEqual(detector.evaluate(word: shortPrefix, currentLayout: .en, trigger: .early), .keep,
                       "Префикс короче earlyMinLength оценивать нельзя")
    }

    func testWordValidInCurrentLanguageIsNeverConverted() throws {
        final class AlwaysValid: WordValidating {
            func isValid(_ word: String, in layout: Layout) -> Bool { true }
        }
        let strict = LayoutDetector(
            models: [.en: try TrigramModel.bundled(.en), .ru: try TrigramModel.bundled(.ru)],
            mapper: mapper,
            validator: AlwaysValid()
        )
        XCTAssertEqual(strict.evaluate(word: "ghbdtn", currentLayout: .en, trigger: .wordBoundary), .keep)
    }

    /// Печатает таблицу FP/FN по сетке порогов. Не ассертит — это инструмент
    /// для выбора DetectorThresholds.calibrated при изменении модели.
    func testPrintThresholdSweep() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWITCHER_SWEEP"] == "1",
                          "Запуск: SWITCHER_SWEEP=1 swift test --filter testPrintThresholdSweep")
        // Сетка порога разницы: слова, оцениваемые обеими моделями.
        print("=== delta ===")
        print("порог\tFP%\tFN%")
        for step in stride(from: 0.0, through: 2.0, by: 0.1) {
            var fp = 0, fn = 0, total = 0
            for (word, layout) in Self.corpus {
                guard let correct = detector.delta(word: word, currentLayout: layout, terminated: true)
                else { continue }
                total += 1
                if correct > step { fp += 1 }
                if let typed = mapper.transpose(word, from: layout, to: layout.opposite),
                   let wrong = detector.delta(word: typed, currentLayout: layout.opposite, terminated: true),
                   wrong <= step {
                    fn += 1
                }
            }
            guard total > 0 else { continue }
            print(String(format: "%.1f\t%.2f\t%.2f", step,
                         100.0 * Double(fp) / Double(total),
                         100.0 * Double(fn) / Double(total)))
        }

        // Сетка абсолютного порога: слова, которые модель текущего языка
        // оценить не может (знаки препинания в позициях букв).
        print("=== absoluteTarget ===")
        print("порог\tFP%\tFN%")
        for step in stride(from: -3.0, through: -0.5, by: 0.1) {
            var fp = 0, fn = 0, total = 0
            for (word, layout) in Self.corpus {
                guard detector.delta(word: word, currentLayout: layout, terminated: true) == nil,
                      let correct = detector.targetScore(word: word, currentLayout: layout, terminated: true)
                else { continue }
                total += 1
                if correct > step { fp += 1 }
                if let typed = mapper.transpose(word, from: layout, to: layout.opposite),
                   let wrong = detector.targetScore(word: typed, currentLayout: layout.opposite, terminated: true),
                   wrong <= step {
                    fn += 1
                }
            }
            guard total > 0 else { continue }
            print(String(format: "%.1f\t%.2f\t%.2f", step,
                         100.0 * Double(fp) / Double(total),
                         100.0 * Double(fn) / Double(total)))
        }
    }

    /// Корпус: частотные слова обоих языков.
    ///
    /// Русская часть намеренно насыщена буквами б, ю, ж, э, х, ъ — они стоят
    /// на клавишах знаков препинания, и такие слова идут по ветке
    /// absoluteTarget, а не delta. По замерам это 15% реального потока.
    ///
    /// Английская часть содержит слова с завершающим знаком препинания: это
    /// единственная популяция, способная дать ложное срабатывание на ветке
    /// absoluteTarget, поэтому без них порог не откалибровать.
    static let corpus: [(String, Layout)] = {
        let en = ["hello", "world", "please", "keyboard", "switch", "layout", "message",
                  "computer", "language", "problem", "morning", "already", "between",
                  "because", "different", "important", "something", "together", "without",
                  "government", "development", "information", "experience", "understand",
                  "test", "code", "file", "name", "time", "work", "make", "know", "think",
                  "hello.", "world,", "please.", "message,", "computer.", "already,",
                  "because.", "something,", "together.", "without,", "don't", "it's"]
        let ru = ["привет", "спасибо", "пожалуйста", "клавиатура", "раскладка", "сообщение",
                  "компьютер", "проблема", "сегодня", "который", "человек", "работа",
                  "например", "поэтому", "всегда", "любовь", "объявление", "подъезд",
                  "съёмка", "жёлтый", "ёлка", "юность", "яблоко", "здравствуйте",
                  "хорошо", "время", "место", "слово", "может", "будет", "очень",
                  "объезд", "жизнь", "съезд", "хожу", "бюджет", "художник",
                  "изъян", "объём", "жюри", "энергия", "хобби", "юбилей"]
        return en.map { ($0, Layout.en) } + ru.map { ($0, Layout.ru) }
    }()
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter LayoutDetectorCalibrationTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'LayoutDetector' in scope`

- [ ] **Step 3: Реализовать LayoutDetector**

```swift
import Foundation

/// Что заставило детектор проснуться.
public enum Trigger: Sendable {
    /// Пользователь нажал пробел или знак препинания — слово дописано.
    case wordBoundary
    /// Пауза в наборе: слово, скорее всего, дописано, но подтверждения нет.
    case pause
    /// Каждый символ: оценивается недописанный префикс.
    case early
}

public enum Verdict: Equatable, Sendable {
    case keep
    case convert(to: Layout, text: String)
}

/// Источник словарной проверки. Отделён протоколом, чтобы детектор
/// оставался чистой функцией и тестировался без системных словарей.
public protocol WordValidating: AnyObject {
    func isValid(_ word: String, in layout: Layout) -> Bool
}

/// Пороги разницы log10-правдоподобия на триграмму.
///
/// Значения получены прогоном `testPrintThresholdSweep` по корпусу
/// `LayoutDetectorCalibrationTests.corpus`. Менять их вручную не нужно:
/// пересобрал модель — перезапусти sweep и подставь новую точку.
public struct DetectorThresholds: Sendable {
    public var wordBoundary: Double
    public var pause: Double
    public var early: Double
    public var earlyMinLength: Int
    /// Порог для случая, когда слово вообще не оценивается моделью текущего
    /// языка. Так бывает, когда в слове есть знаки препинания: "k.,jdm" — это
    /// «любовь», и точка с запятой здесь буквы. Английская модель такое слово
    /// оценить не может, поэтому разницу считать не с чем и решение
    /// принимается по абсолютной оценке целевого языка.
    ///
    /// Это не краевой случай: через этот путь проходят все русские слова
    /// с б, ю, ж, э, х, ъ — по замерам 15% корпуса.
    public var absoluteTarget: Double

    public init(wordBoundary: Double, pause: Double, early: Double,
                earlyMinLength: Int, absoluteTarget: Double) {
        self.wordBoundary   = wordBoundary
        self.pause          = pause
        self.early          = early
        self.earlyMinLength = earlyMinLength
        self.absoluteTarget = absoluteTarget
    }

    /// Замерено прототипом на 4000 частотных слов (по 2000 на язык):
    ///
    ///   delta          +0.3 → FP 0.03%  FN 0.49%
    ///                  +0.5 → FP 0.00%  FN 1.01%   ← wordBoundary, pause
    ///                  +1.2 → FP 0.00%  FN 6.99%   ← early (строже намеренно)
    ///   absoluteTarget -1.6 → FP 0.70%  FN 0.00%   ← 794 положительных
    ///                  -1.7 → FP 1.02%  FN 0.00%      и 6000 отрицательных
    ///
    /// Классы здесь ПЕРЕКРЫВАЮТСЯ, идеального порога не существует: худшие
    /// отрицательные — "bye." → «иную» (-1.04) и "here." → «рукую» (-1.06),
    /// то есть настоящие английские слова, дающие в другой раскладке настоящие
    /// русские. Это та же принципиальная неоднозначность, что и в delta-ветке;
    /// частично снимается контекстом соседних слов (Task 6b).
    public static let calibrated = DetectorThresholds(
        wordBoundary: 0.5,
        pause: 0.5,
        early: 1.2,
        earlyMinLength: 5,
        absoluteTarget: -1.6
    )
}

/// Решает, набрано ли слово в неверной раскладке.
///
/// Чистая функция от слова, текущей раскладки и повода: никакого состояния,
/// никакого ввода-вывода, никаких обращений к AX. Благодаря этому вся логика
/// детекции покрывается офлайн-тестами.
public final class LayoutDetector {

    private let models: [Layout: TrigramModel]
    private let mapper: LayoutMapper
    private let validator: WordValidating?
    private let thresholds: DetectorThresholds

    public init(
        models: [Layout: TrigramModel],
        mapper: LayoutMapper,
        validator: WordValidating?,
        thresholds: DetectorThresholds = .calibrated
    ) {
        self.models     = models
        self.mapper     = mapper
        self.validator  = validator
        self.thresholds = thresholds
    }

    public func evaluate(word: String, currentLayout: Layout, trigger: Trigger) -> Verdict {
        let target = currentLayout.opposite

        if trigger == .early, word.count < thresholds.earlyMinLength { return .keep }

        // Слово, признанное словарём текущего языка, не трогаем никогда.
        // Статистика может ошибиться на редком слове, словарь — нет.
        if let validator, validator.isValid(word, in: currentLayout) { return .keep }

        let terminated = trigger != .early
        guard let converted = mapper.transpose(word, from: currentLayout, to: target),
              let targetModel = models[target],
              let targetScore = targetModel.meanLogProb(converted, terminated: terminated)
        else { return .keep }

        let threshold: Double
        switch trigger {
        case .wordBoundary: threshold = thresholds.wordBoundary
        case .pause:        threshold = thresholds.pause
        case .early:        threshold = thresholds.early
        }

        if let currentScore = models[currentLayout]?.meanLogProb(word, terminated: terminated) {
            guard targetScore - currentScore > threshold else { return .keep }
        } else {
            // Модель текущего языка слово не оценивает — например, в нём есть
            // знаки препинания, стоящие в позициях букв другой раскладки.
            // Сравнивать не с чем, поэтому судим по абсолютной оценке цели.
            guard targetScore > thresholds.absoluteTarget else { return .keep }
        }
        return .convert(to: target, text: converted)
    }

    /// Насколько правдоподобнее слово выглядит в противоположной раскладке.
    /// Положительное значение — в пользу конверсии. `nil`, если хотя бы одна
    /// сторона не оценивается. `internal` ради калибровочного теста.
    func delta(word: String, currentLayout: Layout, terminated: Bool) -> Double? {
        let target = currentLayout.opposite
        guard let currentModel = models[currentLayout],
              let targetModel  = models[target],
              let converted    = mapper.transpose(word, from: currentLayout, to: target),
              let currentScore = currentModel.meanLogProb(word, terminated: terminated),
              let targetScore  = targetModel.meanLogProb(converted, terminated: terminated)
        else { return nil }
        return targetScore - currentScore
    }

    /// Абсолютная оценка слова в целевом языке после транспонирования.
    /// `internal` ради калибровочного теста.
    func targetScore(word: String, currentLayout: Layout, terminated: Bool) -> Double? {
        let target = currentLayout.opposite
        guard let targetModel = models[target],
              let converted = mapper.transpose(word, from: currentLayout, to: target)
        else { return nil }
        return targetModel.meanLogProb(converted, terminated: terminated)
    }
}
```

- [ ] **Step 4: Прогнать sweep и подставить измеренные пороги**

Run: `SWITCHER_SWEEP=1 swift test --filter testPrintThresholdSweep 2>&1 | grep -A25 "==="`

Печатаются две таблицы.

Из таблицы `delta` выбрать точку, где FP < 2% и FN минимально → это `wordBoundary` и `pause`. Для `early` взять точку той же таблицы, где FP < 0.5%.

Из таблицы `absoluteTarget` выбрать точку, где FP < 2% и FN минимально → это `absoluteTarget`. Она отвечает за слова со знаками препинания в позициях букв («любовь» → `k.,jdm`), которые модель текущего языка оценить не может.

Ожидаемые значения (прототип на 4000 частотных слов дал именно их):

| параметр | порог | FP | FN |
|---|---|---|---|
| `wordBoundary`, `pause` | +0.5 | 0.00% | 1.01% |
| `early` | +1.2 | 0.00% | 6.99% |
| `absoluteTarget` | −1.6 | 0.70% | 0.00% |

Если измеренные значения отличаются — обновить константы в `DetectorThresholds.calibrated`, а не ослаблять ассерты в тестах.

Для ветки `absoluteTarget` популяции перекрываются, поэтому FP не обнуляется ни при
каком пороге: часть английских слов со знаком препинания даёт в другой раскладке
настоящие русские слова («bye.» → «иную», «here.» → «рукую»). Выбирается точка
с FN = 0 при минимальном FP.

- [ ] **Step 5: Проверить, что все тесты проходят**

Run: `swift test --filter LayoutDetectorCalibrationTests 2>&1 | tail -10`
Expected: PASS. Если `testNoFalsePositivesOnCorrectlyTypedWords` или `testCatchesWrongLayoutWords` падают — поднять/опустить порог по таблице из шага 4, а не ослаблять ассерт.

- [ ] **Step 6: Коммит**

```bash
git add Sources/Switcher/Core/Detection/LayoutDetector.swift Tests/SwitcherTests/LayoutDetectorCalibrationTests.swift
git commit -m "feat: LayoutDetector с калиброванными порогами

Решение принимается по разнице log10-правдоподобия на триграмму
между текущей и противоположной раскладкой. Пороги получены прогоном
по корпусу, а не назначены. Словарь текущего языка имеет приоритет
над статистикой."
```

---

## Task 6b: LanguagePrior — контекст последних слов

Единственный резерв точности, недостижимый для модели одного слова.

Замеры: 0.68% словаря принципиально неоднозначны — транспонированная форма
слова является настоящим словом другого языка («руку» ←→ «here», «еще» ←→ «tot»,
«душа» ←→ «leif»). Модель, смотрящая на одно слово, такие случаи не решает
никогда: это одни и те же нажатия клавиш. Их `delta` кучкуется вокруг нуля
(медиана −0.04, 79% в полосе от −0.5 до +1.0), то есть решение принимается
на грани. Язык соседних слов — единственный доступный дополнительный сигнал.

**Files:**
- Create: `Sources/Switcher/Core/Detection/LanguagePrior.swift`
- Modify: `Sources/Switcher/Core/Detection/LayoutDetector.swift`
- Test: `Tests/SwitcherTests/LanguagePriorTests.swift`

**Interfaces:**
- Consumes: `Layout` (Task 2), `LayoutDetector`, `DetectorThresholds` (Task 6)
- Produces:
  - `public final class LanguagePrior { public init(capacity: Int, weight: Double); public func record(_ layout: Layout); public func reset(); public func bonus(forConverting to: Layout) -> Double }`
  - `LayoutDetector.init` получает дополнительный параметр `prior: LanguagePrior?` (по умолчанию `nil`)
  - `bonus` лежит в диапазоне `[-weight, +weight]`; эффективный порог = `threshold - bonus`

- [ ] **Step 1: Написать падающий тест**

`Tests/SwitcherTests/LanguagePriorTests.swift`:

```swift
import XCTest
@testable import SwitcherCore

final class LanguagePriorTests: XCTestCase {

    func testEmptyHistoryGivesNoBonus() {
        let prior = LanguagePrior(capacity: 3, weight: 0.5)
        XCTAssertEqual(prior.bonus(forConverting: .ru), 0.0, accuracy: 0.001)
    }

    func testUniformHistoryGivesFullBonusTowardsIt() {
        let prior = LanguagePrior(capacity: 3, weight: 0.5)
        for _ in 0..<3 { prior.record(.ru) }
        XCTAssertEqual(prior.bonus(forConverting: .ru), 0.5, accuracy: 0.001)
        XCTAssertEqual(prior.bonus(forConverting: .en), -0.5, accuracy: 0.001,
                       "Против контекста порог должен ужесточаться симметрично")
    }

    func testMixedHistoryGivesPartialBonus() {
        let prior = LanguagePrior(capacity: 4, weight: 0.5)
        prior.record(.ru); prior.record(.ru); prior.record(.ru); prior.record(.en)
        // доли 0.75 / 0.25 → 0.5 * (0.75 - 0.25) = 0.25
        XCTAssertEqual(prior.bonus(forConverting: .ru), 0.25, accuracy: 0.001)
    }

    func testHistoryIsBoundedByCapacity() {
        let prior = LanguagePrior(capacity: 3, weight: 0.5)
        for _ in 0..<10 { prior.record(.en) }
        prior.record(.ru); prior.record(.ru); prior.record(.ru)
        XCTAssertEqual(prior.bonus(forConverting: .ru), 0.5, accuracy: 0.001,
                       "Старые слова должны вытесняться, иначе контекст залипает")
    }

    func testResetClearsHistory() {
        let prior = LanguagePrior(capacity: 3, weight: 0.5)
        for _ in 0..<3 { prior.record(.ru) }
        prior.reset()
        XCTAssertEqual(prior.bonus(forConverting: .ru), 0.0, accuracy: 0.001)
    }
}
```

Дополнить `Tests/SwitcherTests/LayoutDetectorCalibrationTests.swift`:

```swift
    /// Контекст решает там, где одно слово нерешаемо.
    /// «руки» набранное в английской раскладке даёт "hera": delta ≈ +0.25,
    /// ниже порога 0.5 — без контекста слово останется английским.
    /// После трёх русских слов эффективный порог падает до 0.0 и слово
    /// исправляется.
    func testContextResolvesAmbiguousWord() throws {
        let models: [Layout: TrigramModel] = [.en: try TrigramModel.bundled(.en),
                                              .ru: try TrigramModel.bundled(.ru)]
        let typed = try XCTUnwrap(mapper.transpose("руки", from: .ru, to: .en))

        let without = LayoutDetector(models: models, mapper: mapper, validator: nil)
        XCTAssertEqual(without.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                       .keep, "Без контекста слово на грани оставляем как есть")

        let prior = LanguagePrior(capacity: 3, weight: 0.5)
        for _ in 0..<3 { prior.record(.ru) }
        let with = LayoutDetector(models: models, mapper: mapper, validator: nil, prior: prior)
        XCTAssertEqual(with.evaluate(word: typed, currentLayout: .en, trigger: .wordBoundary),
                       .convert(to: .ru, text: "руки"),
                       "Русский контекст должен склонять решение в пользу русского")
    }

    /// Контекст не должен ломать смешанный текст: частотное английское слово
    /// остаётся английским даже посреди русского.
    func testContextDoesNotBreakCommonEnglishWordInRussianText() throws {
        let models: [Layout: TrigramModel] = [.en: try TrigramModel.bundled(.en),
                                              .ru: try TrigramModel.bundled(.ru)]
        let prior = LanguagePrior(capacity: 3, weight: 0.5)
        for _ in 0..<3 { prior.record(.ru) }
        let detector = LayoutDetector(models: models, mapper: mapper, validator: nil, prior: prior)
        for word in ["here", "the", "code", "file", "test"] {
            XCTAssertEqual(detector.evaluate(word: word, currentLayout: .en, trigger: .wordBoundary),
                           .keep, "«\(word)» — частотное английское слово, контекст его не перебивает")
        }
    }
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter LanguagePriorTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'LanguagePrior' in scope`

- [ ] **Step 3: Реализовать LanguagePrior**

```swift
import Foundation

/// Язык последних подтверждённых слов.
///
/// Нужен для случаев, принципиально неразрешимых по одному слову: 0.68%
/// словаря составляют пары вида «руку» ←→ «here», где обе интерпретации —
/// настоящие слова, и нажатия клавиш физически одинаковы. Никакая модель
/// одного слова их не различает; язык соседей — единственный сигнал.
///
/// Вес намеренно умеренный: при полностью однородном контексте порог
/// сдвигается на 0.5, что переворачивает пограничные слова («руки», «еще»,
/// «душ»), но не трогает частотные слова другого языка («here», delta −0.44).
/// Более агрессивный вес ломал бы смешанный текст.
public final class LanguagePrior {

    private var history: [Layout] = []
    private let capacity: Int
    private let weight: Double
    private let lock = NSLock()

    public init(capacity: Int = 3, weight: Double = 0.5) {
        self.capacity = max(1, capacity)
        self.weight = weight
    }

    /// Запоминает язык подтверждённого слова. Вызывается только на границе
    /// слова: на паузе и ранней конверсии слово ещё может измениться.
    public func record(_ layout: Layout) {
        lock.lock(); defer { lock.unlock() }
        history.append(layout)
        if history.count > capacity { history.removeFirst(history.count - capacity) }
    }

    /// Сбрасывается вместе с буфером: смена приложения, клик мышью, смена
    /// фокуса означают, что предыдущий контекст больше не относится к делу.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        history.removeAll(keepingCapacity: true)
    }

    /// Сдвиг порога для конверсии в `to`. Положительное значение облегчает
    /// конверсию, отрицательное — ужесточает. Диапазон [-weight, +weight].
    public func bonus(forConverting to: Layout) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard !history.isEmpty else { return 0 }
        let matching = history.filter { $0 == to }.count
        let share = Double(matching) / Double(history.count)
        return weight * (share - (1.0 - share))
    }
}
```

- [ ] **Step 4: Подключить приоритет к детектору**

В `LayoutDetector` добавить хранимое свойство и параметр инициализатора:

```swift
    private let prior: LanguagePrior?

    public init(
        models: [Layout: TrigramModel],
        mapper: LayoutMapper,
        validator: WordValidating?,
        prior: LanguagePrior? = nil,
        thresholds: DetectorThresholds = .calibrated
    ) {
        self.models     = models
        self.mapper     = mapper
        self.validator  = validator
        self.prior      = prior
        self.thresholds = thresholds
    }
```

В `evaluate`, после выбора `threshold` по триггеру и перед сравнением,
применить сдвиг:

```swift
        // Контекст соседних слов сдвигает порог: там, где одно слово
        // неразрешимо, язык предыдущих слов — единственный сигнал.
        let effective = threshold - (prior?.bonus(forConverting: target) ?? 0)

        if let currentScore = models[currentLayout]?.meanLogProb(word, terminated: terminated) {
            guard targetScore - currentScore > effective else { return .keep }
        } else {
            guard targetScore > thresholds.absoluteTarget - (prior?.bonus(forConverting: target) ?? 0)
            else { return .keep }
        }
        return .convert(to: target, text: converted)
```

- [ ] **Step 5: Проверить тесты**

Run: `swift test --filter "LanguagePriorTests|LayoutDetectorCalibrationTests" 2>&1 | tail -10`
Expected: PASS. Если `testContextResolvesAmbiguousWord` падает — сверить фактическую `delta` для этого слова прогоном sweep и при необходимости подобрать другое пограничное слово из выданной таблицы, а не менять вес.

- [ ] **Step 6: Коммит**

```bash
git add Sources/Switcher/Core/Detection/LanguagePrior.swift \
        Sources/Switcher/Core/Detection/LayoutDetector.swift \
        Tests/SwitcherTests/LanguagePriorTests.swift \
        Tests/SwitcherTests/LayoutDetectorCalibrationTests.swift
git commit -m "feat: LanguagePrior — контекст последних слов

0.68% словаря принципиально неоднозначны («руку» ←→ «here»): по одному
слову они неразрешимы в принципе, их delta лежит вокруг нуля. Язык
соседних слов сдвигает порог на 0.5 при однородном контексте —
достаточно, чтобы перевернуть пограничные случаи, и недостаточно,
чтобы сломать смешанный текст."
```

---

## Task 7: GuardRules — фильтры, при которых не вмешиваемся

**Files:**
- Create: `Sources/Switcher/Core/Detection/GuardRules.swift`
- Test: `Tests/SwitcherTests/GuardRulesTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `public struct GuardRules { public var wordExclusions: Set<String>; public var excludedApps: Set<String>; public init(wordExclusions: Set<String>, excludedApps: Set<String>); public func allows(word: String, bundleID: String) -> Bool; public static func looksLikeURLOrPath(_ word: String) -> Bool; public static func looksLikeSecret(_ word: String) -> Bool }`

- [ ] **Step 1: Написать падающий тест**

`Tests/SwitcherTests/GuardRulesTests.swift`:

```swift
import XCTest
@testable import SwitcherCore

final class GuardRulesTests: XCTestCase {

    private let rules = GuardRules(
        wordExclusions: ["ghbdtn"],
        excludedApps: ["com.apple.Terminal"]
    )

    func testAllowsOrdinaryWord() {
        XCTAssertTrue(rules.allows(word: "hello", bundleID: "com.apple.Notes"))
    }

    func testBlocksExcludedWord() {
        XCTAssertFalse(rules.allows(word: "ghbdtn", bundleID: "com.apple.Notes"))
        XCTAssertFalse(rules.allows(word: "GHBDTN", bundleID: "com.apple.Notes"),
                       "Исключения сравниваются без учёта регистра")
    }

    func testBlocksExcludedApp() {
        XCTAssertFalse(rules.allows(word: "hello", bundleID: "com.apple.Terminal"))
    }

    func testDetectsURLsEmailsAndPaths() {
        for sample in ["http://example.com", "https://a.b", "www.example.com",
                       "user@example.com", "/usr/local/bin", "~/Documents",
                       "example.co.uk", "ftp://host"] {
            XCTAssertTrue(GuardRules.looksLikeURLOrPath(sample), "не распознан: \(sample)")
        }
        for sample in ["hello", "привет", "don't", "co-op", "end."] {
            XCTAssertFalse(GuardRules.looksLikeURLOrPath(sample), "ложное срабатывание: \(sample)")
        }
    }

    func testDetectsSecrets() {
        // Длиннее 6 и одновременно строчные, заглавные и цифры/знаки.
        XCTAssertTrue(GuardRules.looksLikeSecret("Passw0rd"))
        XCTAssertTrue(GuardRules.looksLikeSecret("aB3xY9zQ"))
        XCTAssertTrue(GuardRules.looksLikeSecret("Tr0ub4dor"))
    }

    func testOrdinaryWordsAreNotSecrets() {
        for sample in ["password", "PASSWORD", "Password", "hello", "Привет",
                       "abcdef", "Ab1", "договор"] {
            XCTAssertFalse(GuardRules.looksLikeSecret(sample), "ложное срабатывание: \(sample)")
        }
    }

    func testSecretsAndURLsAreBlockedByAllows() {
        XCTAssertFalse(rules.allows(word: "Passw0rd", bundleID: "com.apple.Notes"))
        XCTAssertFalse(rules.allows(word: "user@example.com", bundleID: "com.apple.Notes"))
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter GuardRulesTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'GuardRules' in scope`

- [ ] **Step 3: Реализовать GuardRules**

```swift
import Foundation

/// Условия, при которых Switcher не вмешивается в набор.
///
/// Все проверки — чистые функции от слова и bundle ID: никаких обращений
/// к Accessibility. Проверка секретного поля через AX живёт отдельно,
/// в `SwitchCoordinator`, потому что требует ввода-вывода.
public struct GuardRules {

    public var wordExclusions: Set<String>
    public var excludedApps:   Set<String>

    public init(wordExclusions: Set<String> = [], excludedApps: Set<String> = []) {
        self.wordExclusions = wordExclusions
        self.excludedApps   = excludedApps
    }

    public func allows(word: String, bundleID: String) -> Bool {
        guard !excludedApps.contains(bundleID) else { return false }
        guard !wordExclusions.contains(word.lowercased()) else { return false }
        guard !Self.looksLikeURLOrPath(word) else { return false }
        guard !Self.looksLikeSecret(word) else { return false }
        return true
    }

    public static func looksLikeURLOrPath(_ word: String) -> Bool {
        let lower = word.lowercased()
        if lower.contains("@") { return true }
        if lower.hasPrefix("http") || lower.hasPrefix("www.") || lower.hasPrefix("ftp") { return true }
        if lower.hasPrefix("/") || lower.hasPrefix("~/") || lower.hasPrefix("./") { return true }
        // Домен вида example.co.uk: точка внутри слова, а не в конце.
        let inner = lower.dropLast(lower.hasSuffix(".") ? 1 : 0)
        if inner.filter({ $0 == "." }).count >= 1 && !inner.hasSuffix(".") && inner.contains(".") {
            let parts = inner.split(separator: ".")
            if parts.count >= 2 && parts.allSatisfy({ !$0.isEmpty }) { return true }
        }
        return false
    }

    /// Грубая оценка «это пароль или капча, а не слово».
    ///
    /// Правило Caramba: длиннее шести знаков и одновременно содержит строчные,
    /// заглавные и цифры или знаки. Закрывает случаи, где `AXSecureTextField`
    /// не срабатывает: sudo в терминале, поля Electron, капчи.
    public static func looksLikeSecret(_ word: String) -> Bool {
        guard word.count > 6 else { return false }
        var hasLower = false, hasUpper = false, hasOther = false
        for char in word {
            if char.isLowercase { hasLower = true }
            else if char.isUppercase { hasUpper = true }
            else if char.isNumber || char.isSymbol || char.isPunctuation { hasOther = true }
        }
        return hasLower && hasUpper && hasOther
    }
}
```

- [ ] **Step 4: Проверить, что тест проходит**

Run: `swift test --filter GuardRulesTests 2>&1 | tail -5`
Expected: PASS, 7 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/Switcher/Core/Detection/GuardRules.swift Tests/SwitcherTests/GuardRulesTests.swift
git commit -m "feat: GuardRules — фильтры URL, путей, паролей и исключений

Эвристика пароля закрывает случаи, где AXSecureTextField не срабатывает:
sudo в терминале, поля Electron, капчи."
```

---

## Task 8: KeystrokeBuffer — буфер нажатий и границы слов

**Files:**
- Create: `Sources/Switcher/Core/Input/KeystrokeBuffer.swift`
- Test: `Tests/SwitcherTests/KeystrokeBufferTests.swift`

**Interfaces:**
- Consumes: `KeyStroke` (Task 2)
- Produces:
  - `public struct WordSnapshot: Equatable { public let strokes: [KeyStroke]; public let text: String; public let tail: String }`
  - `public final class KeystrokeBuffer { public init(maxLength: Int); public func append(_ stroke: KeyStroke); public func backspace(); public func reset(); public var currentWord: WordSnapshot? { get }; public func wordEndedBy(_ stroke: KeyStroke) -> WordSnapshot? }`
  - `tail` — символ-разделитель, завершивший слово (`" "`, `","`), либо `""` для незавершённого

- [ ] **Step 1: Написать падающий тест**

`Tests/SwitcherTests/KeystrokeBufferTests.swift`:

```swift
import XCTest
@testable import SwitcherCore

final class KeystrokeBufferTests: XCTestCase {

    private func stroke(_ char: Character, _ code: CGKeyCode = 0) -> KeyStroke {
        KeyStroke(keyCode: code, shift: char.isUppercase, char: char)
    }

    private func type(_ text: String, into buffer: KeystrokeBuffer) {
        for (offset, char) in text.enumerated() {
            buffer.append(stroke(char, CGKeyCode(offset)))
        }
    }

    func testAccumulatesWord() {
        let buffer = KeystrokeBuffer(maxLength: 50)
        type("hello", into: buffer)
        XCTAssertEqual(buffer.currentWord?.text, "hello")
        XCTAssertEqual(buffer.currentWord?.tail, "")
        XCTAssertEqual(buffer.currentWord?.strokes.count, 5)
    }

    func testBackspaceRemovesLastStroke() {
        let buffer = KeystrokeBuffer(maxLength: 50)
        type("hello", into: buffer)
        buffer.backspace()
        XCTAssertEqual(buffer.currentWord?.text, "hell")
    }

    func testBackspaceOnEmptyBufferIsSafe() {
        let buffer = KeystrokeBuffer(maxLength: 50)
        buffer.backspace()
        XCTAssertNil(buffer.currentWord)
    }

    func testResetClearsBuffer() {
        let buffer = KeystrokeBuffer(maxLength: 50)
        type("hello", into: buffer)
        buffer.reset()
        XCTAssertNil(buffer.currentWord)
    }

    func testSpaceEndsWordAndCarriesTail() {
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
    func testPunctuationAccumulatesInsideWord() {
        let buffer = KeystrokeBuffer(maxLength: 50)
        type("k.,jdm", into: buffer)
        XCTAssertEqual(buffer.currentWord?.text, "k.,jdm",
                       "«любовь» в английской раскладке — слово целиком, а не три обрывка")
        XCTAssertEqual(buffer.wordEndedBy(stroke(" ", 49))?.text, "k.,jdm")
    }

    func testWordEndOnEmptyBufferReturnsNil() {
        let buffer = KeystrokeBuffer(maxLength: 50)
        XCTAssertNil(buffer.wordEndedBy(stroke(" ", 49)))
    }

    func testOverflowResetsBuffer() {
        let buffer = KeystrokeBuffer(maxLength: 5)
        type("abcdefgh", into: buffer)
        XCTAssertLessThanOrEqual(buffer.currentWord?.text.count ?? 0, 5,
                                 "Длинный ввод (код, JSON) не должен копиться бесконечно")
    }

    func testDigitsDoNotFormWord() {
        let buffer = KeystrokeBuffer(maxLength: 50)
        type("1234", into: buffer)
        XCTAssertNil(buffer.currentWord, "Слово должно содержать хотя бы одну букву")
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter KeystrokeBufferTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'KeystrokeBuffer' in scope`

- [ ] **Step 3: Реализовать KeystrokeBuffer**

```swift
import CoreGraphics
import Foundation

/// Снимок слова: сами нажатия, их текстовое представление и завершающий разделитель.
public struct WordSnapshot: Equatable {
    public let strokes: [KeyStroke]
    public let text:    String
    /// Разделитель, завершивший слово (" ", ","), либо "" если слово не дописано.
    public let tail:    String

    /// Длина в UTF-16 — именно так считаются диапазоны Accessibility.
    public var textUTF16Length: Int { text.utf16.count }
    public var tailUTF16Length: Int { tail.utf16.count }
}

/// Копит нажатия текущего слова.
///
/// Хранит `KeyStroke`, а не символы: keycode нужен, чтобы переиграть нажатия
/// в другой раскладке (стратегия замены B). Никакой логики детекции здесь нет,
/// никаких таймеров — только память.
public final class KeystrokeBuffer {

    private var strokes: [KeyStroke] = []
    private let maxLength: Int

    public init(maxLength: Int = 50) {
        self.maxLength = maxLength
    }

    public func append(_ stroke: KeyStroke) {
        // Переполнение — признак кода, JSON или бессмысленно длинного ввода.
        // Начинаем слово заново, а не растим буфер.
        if strokes.count >= maxLength { strokes.removeAll(keepingCapacity: true) }
        strokes.append(stroke)
    }

    public func backspace() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
    }

    public func reset() {
        strokes.removeAll(keepingCapacity: true)
    }

    public var currentWord: WordSnapshot? {
        snapshot(tail: "")
    }

    /// Завершает слово разделителем и очищает буфер.
    /// Возвращает nil, если копить было нечего.
    public func wordEndedBy(_ stroke: KeyStroke) -> WordSnapshot? {
        defer { reset() }
        return snapshot(tail: String(stroke.char))
    }

    private func snapshot(tail: String) -> WordSnapshot? {
        guard !strokes.isEmpty else { return nil }
        let text = String(strokes.map(\.char))
        // Последовательность без букв (числа, знаки) словом не считаем.
        guard text.contains(where: { $0.isLetter }) else { return nil }
        return WordSnapshot(strokes: strokes, text: text, tail: tail)
    }
}
```

- [ ] **Step 4: Проверить, что тест проходит**

Run: `swift test --filter KeystrokeBufferTests 2>&1 | tail -5`
Expected: PASS, 9 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/Switcher/Core/Input/KeystrokeBuffer.swift Tests/SwitcherTests/KeystrokeBufferTests.swift
git commit -m "feat: KeystrokeBuffer — накопление нажатий с сохранением keycode

Хранение keycode вместо символов позволяет переиграть слово в другой
раскладке вместо инжекта юникода."
```

---

## Task 9: EventTapController — тап на выделенном потоке

**Files:**
- Create: `Sources/Switcher/Core/Input/EventTapController.swift`
- Test: `Tests/SwitcherTests/EventTapControllerTests.swift`

**Interfaces:**
- Consumes: `KeyStroke` (Task 2)
- Produces:
  - `public enum TapEvent { case key(KeyStroke), backspace, wordBreakKey(KeyStroke), resetCause(String), modifierOnly(CGKeyCode), mouseDown }`
  - `public protocol EventTapDelegate: AnyObject { func tap(_ tap: EventTapController, didObserve event: TapEvent) }`
  - `public final class EventTapController { public static let syntheticMarker: Int64 = 0x57495443; public static let injectSource: CGEventSource; public weak var delegate: EventTapDelegate?; public init(); public func start() -> Bool; public func stop(); public var isRunning: Bool }`

**Ключевые требования:** callback не делает ничего, кроме разбора события и вызова делегата; события всегда пропускаются (`Unmanaged.passUnretained(event)`); тап живёт на выделенном потоке.

- [ ] **Step 1: Написать падающий тест**

Полный тап требует Accessibility, поэтому тестируем то, что тестируется офлайн: классификацию событий и настройку источника инжекта.

`Tests/SwitcherTests/EventTapControllerTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import SwitcherCore

final class EventTapControllerTests: XCTestCase {

    func testInjectSourceCarriesMarker() {
        XCTAssertEqual(EventTapController.injectSource.userData,
                       EventTapController.syntheticMarker,
                       "Метка должна стоять на ИСТОЧНИКЕ: на событии она теряется при проходе через HID-тап")
    }

    func testInjectSourceUsesPrivateState() {
        // .privateState не наследует физическое состояние модификаторов,
        // иначе удерживаемый Shift искажает инжектируемый текст.
        let event = CGEvent(keyboardEventSource: EventTapController.injectSource,
                            virtualKey: 0, keyDown: true)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.getIntegerValueField(.eventSourceUserData),
                       EventTapController.syntheticMarker)
    }

    func testClassifiesBackspace() {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true)!
        guard case .backspace = EventTapController.classify(event: event, type: .keyDown) else {
            return XCTFail("keyCode 51 должен классифицироваться как backspace")
        }
    }

    func testClassifiesResetKeys() {
        // Tab(48), Escape(53), стрелки(123-126) сбрасывают буфер.
        for code: CGKeyCode in [48, 53, 123, 124, 125, 126] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            guard case .resetCause = EventTapController.classify(event: event, type: .keyDown) else {
                return XCTFail("keyCode \(code) должен сбрасывать буфер")
            }
        }
    }

    func testCommandComboResetsBuffer() {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true)!
        event.flags = .maskCommand
        guard case .resetCause = EventTapController.classify(event: event, type: .keyDown) else {
            return XCTFail("Комбинации с Cmd должны сбрасывать буфер")
        }
    }

    func testClassifiesMouseDown() {
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                            mouseCursorPosition: .zero, mouseButton: .left)!
        guard case .mouseDown = EventTapController.classify(event: event, type: .leftMouseDown) else {
            return XCTFail("Клик мышью обязан сбрасывать буфер: каретка уехала")
        }
    }

    func testSpaceIsWordBoundary() {
        var chars: [UniChar] = Array(" ".utf16)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)!
        event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        guard case .wordBreakKey = EventTapController.classify(event: event, type: .keyDown) else {
            return XCTFail("Пробел — единственная надёжная граница слова")
        }
    }

    /// Ключевая проверка: знаки препинания НЕ границы слова.
    /// «любовь» в английской раскладке — это "k.,jdm": точка и запятая здесь
    /// это «ю» и «б». Разорвав слово по ним, конвертировать будет нечего.
    func testPunctuationIsPartOfTheWord() {
        for punctuation in [".", ",", ";", "'", "[", "]"] {
            var chars: [UniChar] = Array(punctuation.utf16)
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 47, keyDown: true)!
            event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            guard case .key = EventTapController.classify(event: event, type: .keyDown) else {
                return XCTFail("«\(punctuation)» должен попадать в буфер, а не завершать слово")
            }
        }
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter EventTapControllerTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'EventTapController' in scope`

- [ ] **Step 3: Реализовать EventTapController**

```swift
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Что тап увидел. Разбор события — чистая функция, поэтому тестируется офлайн.
public enum TapEvent {
    case key(KeyStroke)
    case backspace
    /// Пробел или знак препинания: слово закончилось.
    case wordBreakKey(KeyStroke)
    /// Буфер надо сбросить; строка — причина, для отладки.
    case resetCause(String)
    /// Нажат только модификатор (для двойного Shift).
    case modifierOnly(CGKeyCode)
    case mouseDown
}

public protocol EventTapDelegate: AnyObject {
    func tap(_ tap: EventTapController, didObserve event: TapEvent)
}

private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
    controller.handle(type: type, event: event)
    // Событие пропускается ВСЕГДА. Подавление клавиш — источник гонок
    // и потерянного ввода; замена выполняется поверх уже набранного текста.
    return Unmanaged.passUnretained(event)
}

/// Владеет CGEventTap. Живёт на выделенном потоке со своим run loop, чтобы
/// подвисание main thread не приводило к kCGEventTapDisabledByTimeout и
/// заморозке клавиатуры во всей системе.
public final class EventTapController {

    /// Метка «это наше событие». Ставится на ИСТОЧНИК: поле
    /// .eventSourceUserData производно от источника, и при постинге
    /// через HID-тап система перезаписывает его значением из источника.
    public static let syntheticMarker: Int64 = 0x57495443

    /// Единственный источник для всех синтетических событий.
    /// .privateState — независимое состояние модификаторов: с .hidSystemState
    /// удерживаемый пользователем Shift попадал бы в инжектируемый текст.
    public static let injectSource: CGEventSource = {
        let source = CGEventSource(stateID: .privateState)!
        source.userData = syntheticMarker
        return source
    }()

    public weak var delegate: EventTapDelegate?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    public init() {}

    public var isRunning: Bool { tap != nil }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard AXIsProcessTrusted() else {
            print("[Switcher] Нет разрешения Accessibility — тап не создаётся")
            return false
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: pointer
        ) else {
            print("[Switcher] Не удалось создать event tap")
            return false
        }

        tap = created
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)

        // Выделенный поток: занятость main thread не должна приводить
        // к таймауту тапа и заморозке ввода в системе.
        let ready = DispatchSemaphore(value: 0)
        let worker = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else { ready.signal(); return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        worker.name = "com.switcher.eventtap"
        worker.qualityOfService = .userInteractive
        worker.start()
        thread = worker
        ready.wait()

        print("[Switcher] Event tap запущен на выделенном потоке")
        return true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource, let loop = threadRunLoop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopStop(loop)
        }
        self.tap = nil
        runLoopSource = nil
        threadRunLoop = nil
        thread = nil
    }

    /// Вызывается из callback'а. Только разбор и передача делегату:
    /// ни AX, ни словарей, ни таймеров, ни ввода-вывода.
    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Наши собственные события мимо буфера: иначе инжектированный текст
        // попадёт в буфер и вызовет каскад повторных конверсий.
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker else { return }
        delegate?.tap(self, didObserve: Self.classify(event: event, type: type))
    }

    /// Чистая классификация события. `static` ради офлайн-тестов.
    static func classify(event: CGEvent, type: CGEventType) -> TapEvent {
        switch type {
        case .leftMouseDown, .rightMouseDown:
            // Каретка уехала — всё, что накоплено, больше не соответствует тексту.
            return .mouseDown

        case .flagsChanged:
            return .modifierOnly(CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags

            if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
                return .resetCause("модификатор")
            }
            switch keyCode {
            case 51:  return .backspace                       // Delete
            case 48:  return .resetCause("tab")
            case 53:  return .resetCause("escape")
            case 123, 124, 125, 126: return .resetCause("стрелка")
            default:  break
            }

            guard let char = unicodeChar(from: event) else { return .resetCause("нет символа") }
            let stroke = KeyStroke(keyCode: keyCode, shift: flags.contains(.maskShift), char: char)

            // Границей слова считается ТОЛЬКО пробельный символ.
            //
            // Знаки препинания границей не являются: на русской раскладке они
            // стоят в позициях букв. «любовь», набранное в английской раскладке,
            // выглядит как "k.,jdm" — точка и запятая здесь это «ю» и «б», и они
            // обязаны попасть в буфер. Если рвать слово по ним, конвертировать
            // будет нечего.
            if char.isWhitespace || char.isNewline {
                return .wordBreakKey(stroke)
            }
            return .key(stroke)

        default:
            return .resetCause("прочее")
        }
    }

    private static func unicodeChar(from event: CGEvent) -> Character? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0, let scalar = Unicode.Scalar(chars[0]) else { return nil }
        return Character(scalar)
    }
}
```

- [ ] **Step 4: Проверить, что тест проходит**

Run: `swift test --filter EventTapControllerTests 2>&1 | tail -5`
Expected: PASS, 6 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/Switcher/Core/Input/EventTapController.swift Tests/SwitcherTests/EventTapControllerTests.swift
git commit -m "feat: EventTapController на выделенном потоке

Callback только разбирает событие и передаёт делегату — никаких AX,
словарей и таймеров. События никогда не подавляются. Метка synthetic
ставится на источник, а не на событие: на событии она теряется.
Тап слушает mouseDown — клик мышью обязан сбрасывать буфер."
```

---

## Task 10: AXTextClient и ClipboardGuard

**Files:**
- Create: `Sources/Switcher/Core/Replacement/AXTextClient.swift`
- Create: `Sources/Switcher/Core/Replacement/ClipboardGuard.swift`
- Test: `Tests/SwitcherTests/ClipboardGuardTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `public final class AXTextClient { public init(timeout: Float); public func focusedElement() -> AXUIElement?; public func isSecure(_ element: AXUIElement) -> Bool; public func caretLocation(_ element: AXUIElement) -> Int?; public func string(_ element: AXUIElement, location: Int, length: Int) -> String?; public func select(_ element: AXUIElement, location: Int, length: Int) -> Bool; public func replaceSelection(_ element: AXUIElement, with text: String) -> Bool; public func selectedText(_ element: AXUIElement) -> String? }`
  - `public final class ClipboardGuard { public init(pasteboard: NSPasteboard); public func write(_ text: String) -> Bool; public func restore() }`
  - `caretLocation` возвращает `nil`, если есть выделение (длина ≠ 0) — замена в этом случае не выполняется

- [ ] **Step 1: Написать падающий тест для ClipboardGuard**

`Tests/SwitcherTests/ClipboardGuardTests.swift`:

```swift
import XCTest
import AppKit
@testable import SwitcherCore

final class ClipboardGuardTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        // Отдельный pasteboard: системный буфер пользователя не трогаем.
        pasteboard = NSPasteboard(name: .init("com.switcher.tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    func testRestoresPreviousText() {
        pasteboard.clearContents()
        pasteboard.setString("важное", forType: .string)

        let guardian = ClipboardGuard(pasteboard: pasteboard)
        XCTAssertTrue(guardian.write("привет"))
        XCTAssertEqual(pasteboard.string(forType: .string), "привет")

        guardian.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "важное")
    }

    func testDoesNotClobberContentWrittenBysomeoneElse() {
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

    func testPreservesNonStringTypes() {
        pasteboard.clearContents()
        let payload = Data([0x1, 0x2, 0x3])
        pasteboard.setData(payload, forType: .tiff)

        let guardian = ClipboardGuard(pasteboard: pasteboard)
        XCTAssertTrue(guardian.write("привет"))
        guardian.restore()

        XCTAssertEqual(pasteboard.data(forType: .tiff), payload,
                       "Нетекстовые типы обязаны переживать замену")
    }

    func testRestoreWithoutWriteIsSafe() {
        pasteboard.clearContents()
        pasteboard.setString("нетронуто", forType: .string)
        ClipboardGuard(pasteboard: pasteboard).restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "нетронуто")
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter ClipboardGuardTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'ClipboardGuard' in scope`

- [ ] **Step 3: Реализовать ClipboardGuard**

```swift
import AppKit
import Foundation

/// Сохраняет и восстанавливает содержимое буфера обмена вокруг вставки.
///
/// Отличия от прежней реализации: снимаются ВСЕ типы данных, а не только
/// строка, и восстановление происходит только если после нашей записи в
/// буфер никто больше не писал.
public final class ClipboardGuard {

    private let pasteboard: NSPasteboard
    private var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
    private var changeCountAfterWrite: Int?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    public func write(_ text: String) -> Bool {
        snapshot = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }

        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        changeCountAfterWrite = pasteboard.changeCount
        return ok
    }

    public func restore() {
        guard let expected = changeCountAfterWrite else { return }
        changeCountAfterWrite = nil

        // Между нашей записью и восстановлением кто-то ещё писал в буфер —
        // его данные важнее нашего восстановления.
        guard pasteboard.changeCount == expected else {
            snapshot = []
            return
        }

        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        snapshot = []
    }
}
```

- [ ] **Step 4: Проверить ClipboardGuard**

Run: `swift test --filter ClipboardGuardTests 2>&1 | tail -5`
Expected: PASS, 4 теста

- [ ] **Step 5: Реализовать AXTextClient**

Автотестов нет: любой вызов требует живого приложения с Accessibility. Проверяется вручную в Task 13.

```swift
import ApplicationServices
import Foundation

/// Тонкая обёртка над Accessibility с обязательным таймаутом.
///
/// Без таймаута дефолт составляет 6 секунд: одно подвисшее приложение
/// заблокировало бы поток. Все вызовы синхронные, поэтому вызывать этот
/// класс из callback'а event tap запрещено.
public final class AXTextClient {

    private let system = AXUIElementCreateSystemWide()

    public init(timeout: Float = 0.25) {
        AXUIElementSetMessagingTimeout(system, timeout)
    }

    public func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let element = value else { return nil }
        let axElement = element as! AXUIElement
        AXUIElementSetMessagingTimeout(axElement, 0.25)
        return axElement
    }

    public func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return false }
        return role == "AXSecureTextField"
    }

    /// Позиция каретки в UTF-16. Возвращает nil, если есть выделение:
    /// заменять что-либо при активном выделении нельзя.
    public func caretLocation(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let raw = value else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.length == 0 else { return nil }
        return range.location
    }

    /// Читает текст диапазона НЕ трогая выделение — параметризованный атрибут.
    /// Прежняя реализация двигала выделение ради проверки и оставляла его
    /// сдвинутым при неудаче.
    public func string(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard location >= 0, length > 0 else { return nil }
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    public func select(_ element: AXUIElement, location: Int, length: Int) -> Bool {
        guard location >= 0, length >= 0 else { return false }
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    public func replaceSelection(_ element: AXUIElement, with text: String) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    public func selectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
```

- [ ] **Step 6: Проверить сборку и все тесты**

Run: `swift build && swift test 2>&1 | tail -10`
Expected: сборка чистая, все тесты проходят

- [ ] **Step 7: Коммит**

```bash
git add Sources/Switcher/Core/Replacement Tests/SwitcherTests/ClipboardGuardTests.swift
git commit -m "feat: AXTextClient с таймаутом и ClipboardGuard со всеми типами

AXTextClient читает диапазон через AXStringForRange, не трогая
выделение, и всегда ставит таймаут 0.25 с вместо дефолтных 6.
ClipboardGuard сохраняет все типы данных и не перетирает то,
что пользователь скопировал во время замены."
```

---

## Task 11: TextInjector — четыре стратегии с проверкой состояния

**Files:**
- Create: `Sources/Switcher/Core/Replacement/TextInjector.swift`
- Test: `Tests/SwitcherTests/TextInjectorTests.swift`

**Interfaces:**
- Consumes: `KeyStroke`, `Layout` (Task 2), `LayoutMapper` (Task 3), `AXTextClient`, `ClipboardGuard` (Task 10), `EventTapController.injectSource` (Task 9)
- Produces:
  - `public enum InjectionStrategy: String, CaseIterable, Codable { case axDirect, keycodeReplay, selectAndInject, clipboard }`
  - `public struct ReplacementRequest { public let strokes: [KeyStroke]; public let original: String; public let replacement: String; public let tail: String; public let targetLayout: Layout; public let bundleID: String }`
  - `public final class TextInjector { public init(ax: AXTextClient, onSwitchLayout: @escaping (Layout, @escaping () -> Void) -> Void); public func replace(_ request: ReplacementRequest) -> Bool; public func strategy(for bundleID: String) -> InjectionStrategy? }`
  - `replace` синхронный, вызывается с фоновой очереди, возвращает `true` при подтверждённом успехе

- [ ] **Step 1: Написать падающий тест**

Инжект в живое приложение автотестом не проверить. Тестируем то, что тестируется: расчёт диапазонов, порядок стратегий и поведение кэша.

`Tests/SwitcherTests/TextInjectorTests.swift`:

```swift
import XCTest
@testable import SwitcherCore

final class TextInjectorTests: XCTestCase {

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

    func testRangeCoversWordPlusTail() {
        let req = request(original: "ghbdtn", replacement: "привет", tail: " ")
        // Каретка после "ghbdtn " на позиции 30 → слово начинается в 30-6-1=23.
        let plan = TextInjector.planRange(caret: 30, request: req)
        XCTAssertEqual(plan?.start, 23)
        XCTAssertEqual(plan?.verifyLength, 7, "Слово плюс хвост")
        XCTAssertEqual(plan?.wordLength, 6, "Заменяется только слово, хвост остаётся")
    }

    func testRangeWithoutTail() {
        let req = request(original: "ghbdtn", replacement: "привет", tail: "")
        let plan = TextInjector.planRange(caret: 6, request: req)
        XCTAssertEqual(plan?.start, 0)
        XCTAssertEqual(plan?.verifyLength, 6)
        XCTAssertEqual(plan?.wordLength, 6)
    }

    func testRangeRejectsNegativeStart() {
        let req = request(original: "ghbdtn", replacement: "привет", tail: " ")
        XCTAssertNil(TextInjector.planRange(caret: 3, request: req),
                     "Слово не помещается перед кареткой — замену выполнять нельзя")
    }

    func testRangeUsesUTF16Length() {
        // "привет" — 6 графем и 6 UTF-16 единиц, а эмодзи — 1 графема и 2 единицы.
        let req = request(original: "ab", replacement: "👍", tail: "")
        let plan = TextInjector.planRange(caret: 2, request: req)
        XCTAssertEqual(plan?.wordLength, 2, "Длина оригинала считается в UTF-16")
    }

    func testStrategyOrderPrefersAXDirect() {
        XCTAssertEqual(InjectionStrategy.allCases.first, .axDirect)
        XCTAssertEqual(InjectionStrategy.allCases.last, .clipboard)
    }

    func testCacheStartsEmptyAndRecordsSuccess() {
        let injector = TextInjector(ax: AXTextClient(), onSwitchLayout: { _, done in done() })
        XCTAssertNil(injector.strategy(for: "com.example.app"))
        injector.recordSuccess(.keycodeReplay, for: "com.example.app")
        XCTAssertEqual(injector.strategy(for: "com.example.app"), .keycodeReplay)
    }

    func testFailureDemotesCachedStrategy() {
        let injector = TextInjector(ax: AXTextClient(), onSwitchLayout: { _, done in done() })
        injector.recordSuccess(.axDirect, for: "com.example.app")
        injector.recordFailure(.axDirect, for: "com.example.app")
        XCTAssertNil(injector.strategy(for: "com.example.app"),
                     "Отвалившаяся стратегия должна забываться, а не залипать навсегда")
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter TextInjectorTests 2>&1 | tail -5`
Expected: FAIL — `cannot find 'TextInjector' in scope`

- [ ] **Step 3: Реализовать TextInjector**

```swift
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum InjectionStrategy: String, CaseIterable, Codable, Sendable {
    /// Прямая правка диапазона через AX. Ноль синтетических событий.
    case axDirect
    /// Смена раскладки и переигрывание тех же клавиш. Для терминалов и игр,
    /// которые читают keycode, а не unicode-строку события.
    case keycodeReplay
    /// Shift+← по количеству символов и одна вставка целой строкой.
    case selectAndInject
    /// Вставка через буфер обмена. Последний резерв.
    case clipboard
}

public struct ReplacementRequest {
    public let strokes:      [KeyStroke]
    public let original:     String
    public let replacement:  String
    /// Разделитель после слова: " ", "," либо "" для незавершённого слова.
    public let tail:         String
    public let targetLayout: Layout
    public let bundleID:     String

    public init(strokes: [KeyStroke], original: String, replacement: String,
                tail: String, targetLayout: Layout, bundleID: String) {
        self.strokes      = strokes
        self.original     = original
        self.replacement  = replacement
        self.tail         = tail
        self.targetLayout = targetLayout
        self.bundleID     = bundleID
    }
}

/// Выполняет замену уже набранного слова.
///
/// Главный принцип: перед мутацией состояние проверяется, после мутации —
/// подтверждается. Если текст под кареткой не тот, что ожидался, замена не
/// выполняется вовсе: лучше не сработать, чем испортить чужой текст.
public final class TextInjector {

    /// Диапазоны замены, все длины в UTF-16.
    struct RangePlan: Equatable {
        let start: Int
        /// Слово плюс хвост — что проверяем.
        let verifyLength: Int
        /// Только слово — что заменяем.
        let wordLength: Int
    }

    private let ax: AXTextClient
    private let onSwitchLayout: (Layout, @escaping () -> Void) -> Void
    private var cache: [String: InjectionStrategy] = [:]
    private let cacheLock = NSLock()

    public init(ax: AXTextClient,
                onSwitchLayout: @escaping (Layout, @escaping () -> Void) -> Void) {
        self.ax = ax
        self.onSwitchLayout = onSwitchLayout
    }

    // MARK: - Кэш стратегий

    public func strategy(for bundleID: String) -> InjectionStrategy? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[bundleID]
    }

    func recordSuccess(_ strategy: InjectionStrategy, for bundleID: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[bundleID] = strategy
    }

    /// Стратегия перестала работать (например, приложение обновилось) —
    /// забываем её, чтобы следующий раз снова перебрать варианты.
    func recordFailure(_ strategy: InjectionStrategy, for bundleID: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[bundleID] == strategy { cache.removeValue(forKey: bundleID) }
    }

    // MARK: - Расчёт диапазонов

    /// Чистая функция ради тестируемости. Все длины — UTF-16.
    static func planRange(caret: Int, request: ReplacementRequest) -> RangePlan? {
        let wordLength = request.original.utf16.count
        let tailLength = request.tail.utf16.count
        let start = caret - wordLength - tailLength
        guard start >= 0, wordLength > 0 else { return nil }
        return RangePlan(start: start,
                         verifyLength: wordLength + tailLength,
                         wordLength: wordLength)
    }

    // MARK: - Точка входа

    /// Синхронный. Вызывать только с фоновой очереди: внутри AX-вызовы.
    @discardableResult
    public func replace(_ request: ReplacementRequest) -> Bool {
        let order: [InjectionStrategy]
        if let cached = strategy(for: request.bundleID) {
            order = [cached] + InjectionStrategy.allCases.filter { $0 != cached }
        } else {
            order = InjectionStrategy.allCases
        }

        for strategy in order {
            if perform(strategy, request) {
                recordSuccess(strategy, for: request.bundleID)
                return true
            }
            recordFailure(strategy, for: request.bundleID)
        }
        return false
    }

    private func perform(_ strategy: InjectionStrategy, _ request: ReplacementRequest) -> Bool {
        switch strategy {
        case .axDirect:        return replaceViaAX(request)
        case .keycodeReplay:   return replaceViaKeycodeReplay(request)
        case .selectAndInject: return replaceViaSelection(request)
        case .clipboard:       return replaceViaClipboard(request)
        }
    }

    // MARK: - Pre-flight

    /// Убеждается, что перед кареткой действительно лежит то слово, которое мы
    /// собрались заменить. Закрывает клик мышью, автодополнение приложения,
    /// допечатывание пользователем и протухший буфер после смены фокуса.
    private func verifiedPlan(_ request: ReplacementRequest)
        -> (element: AXUIElement, plan: RangePlan)? {
        guard let element = ax.focusedElement(),
              !ax.isSecure(element),
              let caret = ax.caretLocation(element),
              let plan = Self.planRange(caret: caret, request: request),
              let actual = ax.string(element, location: plan.start, length: plan.verifyLength),
              actual == request.original + request.tail
        else { return nil }
        return (element, plan)
    }

    // MARK: - Стратегия A: прямая правка через AX

    private func replaceViaAX(_ request: ReplacementRequest) -> Bool {
        guard let (element, plan) = verifiedPlan(request) else { return false }

        guard ax.select(element, location: plan.start, length: plan.wordLength),
              ax.replaceSelection(element, with: request.replacement)
        else {
            // Вернуть каретку туда, где она была.
            _ = ax.select(element, location: plan.start + plan.wordLength + request.tail.utf16.count, length: 0)
            return false
        }

        let newWordLength = request.replacement.utf16.count
        _ = ax.select(element, location: plan.start + newWordLength + request.tail.utf16.count, length: 0)

        // Пост-проверка: убедиться, что приложение действительно применило правку.
        let expected = request.replacement + request.tail
        return ax.string(element, location: plan.start, length: expected.utf16.count) == expected
    }

    // MARK: - Стратегия B: переигрывание keycode'ов

    private func replaceViaKeycodeReplay(_ request: ReplacementRequest) -> Bool {
        // Проверяем состояние, если AX доступен хотя бы на чтение.
        if let element = ax.focusedElement() {
            guard !ax.isSecure(element) else { return false }
            if let caret = ax.caretLocation(element),
               let plan = Self.planRange(caret: caret, request: request),
               let actual = ax.string(element, location: plan.start, length: plan.verifyLength),
               actual != request.original + request.tail {
                return false
            }
        }

        // Раскладка меняется ПЕРЕД переигрыванием и подтверждается уведомлением,
        // а не задержкой: иначе клавиши отрисуются в старой раскладке.
        let switched = DispatchSemaphore(value: 0)
        onSwitchLayout(request.targetLayout) { switched.signal() }
        guard switched.wait(timeout: .now() + 1.0) == .success else { return false }

        let deleteCount = request.original.utf16.count + request.tail.utf16.count
        sendBackspaces(deleteCount)
        for stroke in request.strokes {
            postKey(stroke.keyCode, shift: stroke.shift)
        }
        for char in request.tail {
            postUnicode(String(char))
        }

        // Приложение обрабатывает события асинхронно, поэтому пост-проверку
        // делаем через AX там, где он есть; иначе доверяем порядку доставки.
        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return true }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return true }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
    }

    // MARK: - Стратегия C: выделение и одна вставка

    private func replaceViaSelection(_ request: ReplacementRequest) -> Bool {
        if let element = ax.focusedElement(), ax.isSecure(element) { return false }

        let count = request.original.utf16.count + request.tail.utf16.count
        for _ in 0..<count {
            postKey(123, shift: true)   // kVK_LeftArrow с Shift
        }

        // Читать выделение часто можно даже там, где писать в него нельзя.
        if let element = ax.focusedElement(),
           let selected = ax.selectedText(element),
           !selected.isEmpty,
           selected != request.original + request.tail {
            // Выделили не то — снять выделение и уйти.
            postKey(124, shift: false)  // kVK_RightArrow
            return false
        }

        // Одно событие со всей строкой: приложение получает один insertText,
        // это один шаг undo и между символами нечему разъехаться.
        postUnicode(request.replacement + request.tail)

        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return true }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return true }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
    }

    // MARK: - Стратегия D: буфер обмена

    private func replaceViaClipboard(_ request: ReplacementRequest) -> Bool {
        if let element = ax.focusedElement(), ax.isSecure(element) { return false }

        let guardian = ClipboardGuard()
        guard guardian.write(request.replacement + request.tail) else { return false }
        defer { guardian.restore() }

        let count = request.original.utf16.count + request.tail.utf16.count
        for _ in 0..<count { postKey(123, shift: true) }
        postCommandKey(9)   // kVK_ANSI_V

        guard let element = ax.focusedElement(),
              let caret = ax.caretLocation(element) else { return true }
        let expected = request.replacement + request.tail
        let start = caret - expected.utf16.count
        guard start >= 0 else { return true }
        return ax.string(element, location: start, length: expected.utf16.count) == expected
    }

    // MARK: - Постинг событий

    /// Все события идут из одного источника: очередь событий macOS
    /// гарантирует порядок доставки, поэтому задержки между ними не нужны.
    private var source: CGEventSource { EventTapController.injectSource }

    private func postKey(_ keyCode: CGKeyCode, shift: Bool) {
        let flags: CGEventFlags = shift ? .maskShift : []
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func postCommandKey(_ keyCode: CGKeyCode) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func sendBackspaces(_ count: Int) {
        for _ in 0..<count { postKey(51, shift: false) }
    }

    /// Вставляет строку ЦЕЛИКОМ одним событием.
    private func postUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        var chars = Array(text.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.flags = []
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cgAnnotatedSessionEventTap)
        }
        // keyUp без unicode-строки: с ней часть приложений вставляет текст дважды.
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.flags = []
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
```

- [ ] **Step 4: Проверить, что тест проходит**

Run: `swift test --filter TextInjectorTests 2>&1 | tail -5`
Expected: PASS, 7 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/Switcher/Core/Replacement/TextInjector.swift Tests/SwitcherTests/TextInjectorTests.swift
git commit -m "feat: TextInjector — четыре стратегии с проверкой состояния

Перед заменой проверяется текст под кареткой, после — результат.
Ни одной угаданной задержки: порядок гарантируется одним источником
событий, смена раскладки подтверждается уведомлением. Строка
вставляется одним событием вместо цикла по символам. Кэш стратегий
на bundle ID самовосстанавливается при отказе."
```

---

## Task 12: SwitchCoordinator — сборка движка

**Files:**
- Create: `Sources/Switcher/Core/SwitchCoordinator.swift`
- Create: `Sources/Switcher/Core/SystemWordValidator.swift`
- Modify: `Sources/Switcher/Core/AppState.swift`
- Delete: `Sources/Switcher/Core/KeyboardEngine.swift`, `Sources/Switcher/Core/KeyboardEngineStub.swift`, `Sources/Switcher/Core/SpellCheckService.swift`, `Sources/Switcher/Core/TextReplacer.swift`
- Delete: `Tests/SwitcherTests/KeyboardEngineDetectionTests.swift`

**Interfaces:**
- Consumes: всё из задач 2–11
- Produces:
  - `public final class SystemWordValidator: WordValidating` — `NSSpellChecker` с LRU-кэшем и TTL, вызывается только с фоновой очереди
  - `public final class SwitchCoordinator: EventTapDelegate` со свойствами, которые дёргает `AppState`: `autoSwitchEnabled`, `doubleShiftEnabled`, `minWordLength`, `learningEnabled`, `exclusions`, `excludedApps`, `corrections`, `onSwitched`, `onUndone`, `start()`, `stop()`, `isRunning`, `currentLanguage()`, `performUndoFromUI()`

- [ ] **Step 1: Реализовать SystemWordValidator**

```swift
import AppKit
import Foundation

/// Словарная проверка через NSSpellChecker.
///
/// Вызывать только с фоновой очереди: NSSpellChecker медленный, а из
/// callback'а event tap блокирующие вызовы запрещены. Кэш с TTL, чтобы
/// установка нового языкового словаря подхватывалась без перезапуска.
public final class SystemWordValidator: WordValidating {

    private struct Entry {
        let isValid: Bool
        let storedAt: Date
    }

    private let checker = NSSpellChecker.shared
    private var cache: [String: Entry] = [:]
    private var order: [String] = []
    private let maxEntries: Int
    private let ttl: TimeInterval
    private let lock = NSLock()

    public init(maxEntries: Int = 500, ttl: TimeInterval = 3600) {
        self.maxEntries = maxEntries
        self.ttl = ttl
    }

    public func isValid(_ word: String, in layout: Layout) -> Bool {
        let cleaned = word.lowercased().filter { $0.isLetter }
        guard cleaned.count >= 2 else { return false }
        let key = "\(cleaned)|\(layout.rawValue)"

        lock.lock()
        if let entry = cache[key], Date().timeIntervalSince(entry.storedAt) < ttl {
            lock.unlock()
            return entry.isValid
        }
        lock.unlock()

        let range = checker.checkSpelling(
            of: cleaned, startingAt: 0, language: layout.rawValue,
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        )
        let isValid = range.location == NSNotFound

        lock.lock()
        if cache[key] == nil {
            order.append(key)
            if order.count > maxEntries { cache.removeValue(forKey: order.removeFirst()) }
        }
        cache[key] = Entry(isValid: isValid, storedAt: Date())
        lock.unlock()

        return isValid
    }
}
```

- [ ] **Step 2: Реализовать SwitchCoordinator**

```swift
import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Связывает тап, детектор и замену.
///
/// Разделение потоков строгое:
///   tap thread   — только буфер (через EventTapDelegate)
///   work queue   — детекция и замена, тут разрешены AX и NSSpellChecker
///   main queue   — только колбэки в UI
public final class SwitchCoordinator: EventTapDelegate {

    // MARK: - Настройки

    public var autoSwitchEnabled  = true
    public var doubleShiftEnabled = true
    public var minWordLength      = 4
    public var learningEnabled    = true
    public var exclusions: Set<String>      = [] { didSet { rebuildGuards() } }
    public var excludedApps: Set<String>    = [] { didSet { rebuildGuards() } }
    public var corrections: [String: String] = [:]

    public var onSwitched: ((LastSwitchInfo) -> Void)?
    public var onUndone:   ((LastSwitchInfo) -> Void)?

    // MARK: - Составные части

    private let tap = EventTapController()
    private let buffer = KeystrokeBuffer()
    private let ax = AXTextClient()
    private let sources = InputSourceManager()
    private let prior = LanguagePrior()
    private let work = DispatchQueue(label: "com.switcher.work", qos: .userInitiated)

    private var mapper: LayoutMapper?
    private var detector: LayoutDetector?
    private var injector: TextInjector!
    private var guards = GuardRules()

    private var currentBundleID = ""
    private var lastSwitch: LastSwitchInfo?
    private var lastShiftTime: TimeInterval = 0
    private var pauseWorkItem: DispatchWorkItem?
    private var appObserver: NSObjectProtocol?

    private let doubleShiftInterval: TimeInterval = 0.4
    private let pauseInterval: TimeInterval = 0.5

    public init() {
        injector = TextInjector(ax: ax) { [weak self] layout, done in
            self?.switchLayout(to: layout, completion: done)
        }
        tap.delegate = self
        rebuildLayoutTables()
    }

    // MARK: - Жизненный цикл

    @discardableResult
    public func start() -> Bool {
        currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.currentBundleID = app?.bundleIdentifier ?? ""
            self?.buffer.reset()   // Новое приложение — старый буфер невалиден.
        }
        return tap.start()
    }

    public func stop() {
        tap.stop()
        pauseWorkItem?.cancel()
        if let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appObserver = nil
        }
    }

    public var isRunning: Bool { tap.isRunning }

    public func currentLanguage() -> String { sources.currentLanguage() }

    private func currentLayout() -> Layout {
        Layout(languageCode: sources.currentLanguage()) ?? .en
    }

    private func rebuildGuards() {
        guards = GuardRules(wordExclusions: exclusions, excludedApps: excludedApps)
    }

    private func rebuildLayoutTables() {
        var tables: [Layout: KeyboardLayoutTable] = [:]
        for source in sources.selectableSources() {
            guard let code = sources.language(for: source),
                  let layout = Layout(languageCode: code),
                  tables[layout] == nil,
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            tables[layout] = KeyboardLayoutTable.load(layoutData: data,
                                                      keyboardType: UInt32(LMGetKbdType()))
        }
        guard tables[.en] != nil, tables[.ru] != nil else {
            print("[Switcher] Нужны обе раскладки: английская и русская")
            return
        }
        let mapper = LayoutMapper(tables: tables)
        self.mapper = mapper
        guard let en = try? TrigramModel.bundled(.en),
              let ru = try? TrigramModel.bundled(.ru) else {
            print("[Switcher] Не удалось загрузить модели языка")
            return
        }
        detector = LayoutDetector(models: [.en: en, .ru: ru],
                                  mapper: mapper,
                                  validator: SystemWordValidator(),
                                  prior: prior)
    }

    // MARK: - EventTapDelegate (вызывается на потоке тапа)

    public func tap(_ tap: EventTapController, didObserve event: TapEvent) {
        switch event {
        case .key(let stroke):
            buffer.append(stroke)
            schedulePauseCheck()
            if let word = buffer.currentWord { evaluate(word, trigger: .early) }

        case .backspace:
            buffer.backspace()
            lastSwitch = nil

        case .wordBreakKey(let stroke):
            pauseWorkItem?.cancel()
            if let word = buffer.wordEndedBy(stroke) { evaluate(word, trigger: .wordBoundary) }

        case .resetCause, .mouseDown:
            pauseWorkItem?.cancel()
            buffer.reset()
            // Контекст предыдущих слов больше не относится к делу:
            // каретка уехала или пользователь ушёл в другое место.
            prior.reset()
            lastSwitch = nil

        case .modifierOnly(let keyCode):
            handleModifier(keyCode)
        }
    }

    private func schedulePauseCheck() {
        pauseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let word = self.buffer.currentWord else { return }
            self.evaluate(word, trigger: .pause)
        }
        pauseWorkItem = item
        work.asyncAfter(deadline: .now() + pauseInterval, execute: item)
    }

    // MARK: - Детекция и замена (фоновая очередь)

    private func evaluate(_ word: WordSnapshot, trigger: Trigger) {
        guard autoSwitchEnabled, let detector else { return }
        guard word.text.count >= minWordLength else { return }
        let bundleID = currentBundleID
        guard guards.allows(word: word.text, bundleID: bundleID) else { return }

        work.async { [weak self] in
            guard let self else { return }
            let layout = self.currentLayout()

            // Пользовательские правила исправления опечаток имеют приоритет.
            if let corrected = self.corrections[word.text.lowercased()] {
                self.apply(word: word, replacement: corrected, target: layout,
                           bundleID: bundleID, isCorrection: true)
                return
            }

            guard case .convert(let target, let text) = detector.evaluate(
                word: word.text, currentLayout: layout, trigger: trigger
            ) else {
                // Слово оставлено как есть — оно тоже контекст.
                // Запоминаем только на границе слова: на паузе и ранней
                // конверсии слово ещё может быть дописано.
                if trigger == .wordBoundary { self.prior.record(layout) }
                return
            }

            self.apply(word: word, replacement: text, target: target,
                       bundleID: bundleID, isCorrection: false)
        }
    }

    private func apply(word: WordSnapshot, replacement: String, target: Layout,
                       bundleID: String, isCorrection: Bool) {
        let request = ReplacementRequest(
            strokes: word.strokes, original: word.text, replacement: replacement,
            tail: word.tail, targetLayout: target, bundleID: bundleID
        )
        guard injector.replace(request) else { return }

        if !isCorrection { switchLayout(to: target, completion: {}) }
        buffer.reset()
        prior.record(target)   // подтверждённое слово — контекст для следующих

        let info = LastSwitchInfo(
            originalWord: word.text, replacedWith: replacement,
            fromLanguage: target.opposite.rawValue, toLanguage: target.rawValue,
            timestamp: Date(), isCorrection: isCorrection, isDoubleShift: false
        )
        lastSwitch = info
        DispatchQueue.main.async { self.onSwitched?(info) }
    }

    /// Меняет раскладку и дожидается подтверждения системным уведомлением,
    /// а не фиксированной задержкой.
    private func switchLayout(to layout: Layout, completion: @escaping () -> Void) {
        let name = NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged")
        var observer: NSObjectProtocol?
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
            completion()
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: name, object: nil, queue: .main
        ) { _ in finish() }

        sources.switchToLanguage(layout.rawValue)

        // Страховка на случай, если уведомление не придёт (раскладка уже активна).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
    }

    // MARK: - Двойной Shift: отмена

    private func handleModifier(_ keyCode: CGKeyCode) {
        guard doubleShiftEnabled, keyCode == 56 || keyCode == 60 else { return }
        let now = Date().timeIntervalSince1970
        if now - lastShiftTime < doubleShiftInterval {
            lastShiftTime = 0
            work.async { [weak self] in self?.performUndo() }
        } else {
            lastShiftTime = now
        }
    }

    public func performUndoFromUI() {
        work.async { [weak self] in self?.performUndo() }
    }

    private func performUndo() {
        guard let info = lastSwitch, info.isUndoable else { return }
        lastSwitch = nil

        let request = ReplacementRequest(
            strokes: [], original: info.replacedWith, replacement: info.originalWord,
            tail: "", targetLayout: Layout(languageCode: info.fromLanguage) ?? .en,
            bundleID: currentBundleID
        )
        guard injector.replace(request) else { return }

        if !info.isCorrection, let from = Layout(languageCode: info.fromLanguage) {
            switchLayout(to: from, completion: {})
        }
        buffer.reset()
        DispatchQueue.main.async { self.onUndone?(info) }
    }
}
```

- [ ] **Step 3: Переключить AppState на SwitchCoordinator**

В `AppState.swift` заменить `let engine: KeyboardEngine` на `let engine: SwitchCoordinator` и `KeyboardEngine()` на `SwitchCoordinator()`. Удалить присваивание `engine.spellCheckEnabled` — в новом движке словарная проверка не отключается: она всегда идёт как приоритет над статистикой. Соответствующий переключатель в `SettingsView` убрать, `AppState.spellCheckEnabled` оставить как persisted-свойство без эффекта не нужно — удалить и его.

- [ ] **Step 4: Удалить старое ядро**

```bash
git rm Sources/Switcher/Core/KeyboardEngine.swift \
       Sources/Switcher/Core/KeyboardEngineStub.swift \
       Sources/Switcher/Core/SpellCheckService.swift \
       Sources/Switcher/Core/TextReplacer.swift \
       Tests/SwitcherTests/KeyboardEngineDetectionTests.swift
```

- [ ] **Step 5: Собрать и прогнать все тесты**

Run: `swift build 2>&1 | grep -E "error|warning: unused" | head -20; swift test 2>&1 | tail -15`
Expected: сборка без ошибок; все тесты проходят

- [ ] **Step 6: Коммит**

```bash
git add -A
git commit -m "feat: SwitchCoordinator вместо KeyboardEngine

Собирает тап, детектор и замену с жёстким разделением потоков:
на потоке тапа только буфер, детекция и замена на фоновой очереди,
UI-колбэки на main. Старое ядро удалено: KeyboardEngine,
SpellCheckService, TextReplacer, LayoutConverter."
```

---

## Task 13: Ручная проверка и README

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: всё
- Produces: обновлённая документация, подтверждённая работоспособность

- [ ] **Step 1: Собрать и запустить приложение**

Run: `make run`
Дать разрешение Accessibility, если система запросит.

- [ ] **Step 2: Проверить каждый класс приложений**

Набрать `ghbdtn ` (это «привет» в английской раскладке) и убедиться, что слово исправляется и раскладка переключается:

| Приложение | Ожидаемая стратегия | Отметка |
|---|---|---|
| TextEdit | axDirect | [ ] |
| Safari, поле поиска | axDirect | [ ] |
| Terminal.app | keycodeReplay | [ ] |
| VS Code | keycodeReplay или selectAndInject | [ ] |
| Slack или Telegram | selectAndInject | [ ] |

- [ ] **Step 3: Проверить защиты**

- [ ] Поле пароля в Системных настройках — исправления нет
- [ ] `sudo` в терминале — исправления нет
- [ ] Приложение из списка исключений — исправления нет
- [ ] Набор `Passw0rdX` — исправления нет
- [ ] Набор `user@example.com` — исправления нет

- [ ] **Step 4: Проверить сохранность данных**

- [ ] Скопировать картинку, вызвать замену в приложении со стратегией clipboard, вставить — картинка на месте
- [ ] Набрать слово, кликнуть мышью в другое место, дождаться паузы — соседний текст не пострадал
- [ ] Двойной Shift после исправления — текст возвращается, раскладка возвращается

- [ ] **Step 5: Проверить, что клавиатура не залипает**

Печатать быстро и непрерывно 30 секунд в TextEdit, чередуя языки. Ни одного пропущенного символа, ни одной паузы.

- [ ] **Step 6: Обновить документацию**

В `CLAUDE.md` заменить раздел «Architecture» на описание новой структуры (таблица из раздела File Structure этого плана), раздел «Key Algorithms» — на описание триграммной модели и четырёх стратегий замены, раздел «Testing Notes» — на список автотестов. В `README.md` обновить описание алгоритма.

- [ ] **Step 7: Коммит**

```bash
git add README.md CLAUDE.md
git commit -m "docs: описание нового ядра

Триграммная модель вместо доли биграмм, четыре стратегии замены
с проверкой состояния, разделение потоков."
```

---

## Self-Review

**Покрытие спеки:**

| Требование спеки | Задача |
|---|---|
| Починить `Package.swift` | 1 |
| Тап на выделенном потоке, без блокирующего IPC в callback | 9 |
| Callback никогда не подавляет клавишу | 9 |
| Тап слушает `mouseDown` | 9 |
| Метка synthetic на источнике, `.privateState` | 9 |
| Единый путь детекции, три повода | 12 |
| Триграммная модель, генератор, вшитый ресурс | 4, 5 |
| Калибровка порогов тестом | 6 |
| Контекст соседних слов (добавлено после спеки) | 6b |
| Словарный override, `NSSpellChecker` в фоне с TTL | 6, 12 |
| Ранняя конверсия по префиксу, минимум 5 символов | 5, 6 |
| GuardRules: URL, пути, пароли, исключения | 7 |
| Секретное поле через AX с кэшем | 10, 11 |
| `UCKeyTranslate` для обеих русских раскладок | 2, 3 |
| Буфер keycode'ов | 8 |
| Pre-flight проверка текста под кареткой | 11 |
| Хвостовой символ, `tail` 0 или 1 | 8, 11 |
| Четыре стратегии, кэш возможностей, пост-проверка | 11 |
| `ClipboardGuard` со всеми типами и `changeCount` | 10 |
| `AXUIElementSetMessagingTimeout` 0.25 | 10 |
| Смена раскладки по уведомлению | 12 |
| Автотесты по списку из спеки | 2, 3, 5, 6, 7, 8, 9, 10, 11 |
| Ручная проверка | 13 |

Пробелов не найдено.

**Проверено прототипом до написания плана:**

- `CGEventSource.userData` — сеттабельное свойство Swift; `kAXStringForRangeParameterizedAttribute` существует; `AXUIElementSetMessagingTimeout` возвращает `.success`; данные раскладки читаются.
- `keyboardSetUnicodeString` кладёт строку «привет» целиком в одно событие (round-trip вернул 6 символов) — стратегия C реализуема как задумано.
- Триграммная модель на 4000 частотных слов разделяет классы с FP 0.00% и FN 1.01% при пороге +0.5. Пороги в плане — измеренные, не назначенные.
- Знаки препинания НЕ являются границей слова: «любовь» набирается как `k.,jdm`. Из-за этого 15% русских слов не оцениваются английской моделью, и для них введена отдельная ветка `absoluteTarget`. Эта ветка появилась в результате self-review плана, в исходной спеке её не было.
- Потолок точности для модели одного слова измерен: 0.68% словаря принципиально неоднозначны («руку» ←→ «here»). Триграммная модель даёт FN 1.01%, то есть до теоретического предела остаётся 0.33 п.п. Это и был ответ на вопрос «не взять ли нейросеть»: резерв не в классе модели, а в контексте — отсюда Task 6b. Вес приоритета 0.5 подобран по замеренному распределению `delta` неоднозначных пар (медиана −0.04, 79% в полосе от −0.5 до +1.0).

**Известные компромиссы, зафиксированные осознанно:**

- `switchLayout` содержит `asyncAfter(0.3)` как страховку на случай, если уведомление о смене раскладки не придёт (например, целевая раскладка уже активна). Это не угаданная задержка на пути замены, а таймаут ожидания события — глобальное ограничение не нарушается.
- Стратегии B, C и D возвращают `true` без пост-проверки, если AX недоступен для чтения. Проверить результат в таком приложении нечем; альтернатива — считать замену неудачной и перебирать оставшиеся стратегии, что привело бы к многократной вставке.
- Двойной Shift в этом плане выполняет только отмену. Конверсия выделенного текста по двойному Shift, которая была в старом коде, не переносится: пользователь подтвердил, что нужна именно отмена. Если понадобится — отдельная задача.

**Проверка согласованности имён:** `Layout`, `KeyStroke`, `KeyboardLayoutTable`, `LayoutMapper`, `TrigramModel`, `Trigger`, `Verdict`, `WordValidating`, `DetectorThresholds`, `LayoutDetector`, `GuardRules`, `WordSnapshot`, `KeystrokeBuffer`, `TapEvent`, `EventTapDelegate`, `EventTapController`, `AXTextClient`, `ClipboardGuard`, `InjectionStrategy`, `ReplacementRequest`, `RangePlan`, `TextInjector`, `SystemWordValidator`, `SwitchCoordinator` — каждое имя определено ровно в одной задаче и используется в последующих с теми же сигнатурами.
