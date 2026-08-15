# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Switcher is a macOS utility that automatically corrects text typed in the wrong keyboard layout (EN ↔ RU) without hotkeys. It uses CGEventTap to intercept keyboard events at the system level, scores the typed word with a character-trigram language model, and replaces it in place using one of four platform-specific injection strategies.

## Build Commands

```bash
# Build and run (recommended for development)
make run           # Builds release bundle, signs ad-hoc, and launches

# Build without running
make bundle        # Creates Switcher.app in project root

# Debug build only (all three targets, including tests)
swift build        # Compiles without creating .app bundle

# Create DMG for distribution
make dmg           # Creates signed Switcher.dmg with drag-to-Applications layout

# Clean all build artifacts
make clean
```

`make build`/`make bundle`/`make run` compile only the `SwitcherApp` product (`swift build -c release --product SwitcherApp`), not the whole package: the `SwitcherTests` target uses `@testable import` and SwiftPM doesn't pass `-enable-testing` outside debug, so it fails to compile in a release configuration. Plain `swift build` (debug) builds all three targets fine — see [Testing](#testing).

**Requirements:** macOS 14 Sonoma or newer, Xcode Command Line Tools

**Permissions:** Accessibility permission required (System Settings → Privacy & Security → Accessibility). Without it, CGEventTap creation fails silently and the app does nothing.

## Architecture

### Thread separation

This is the load-bearing architectural decision of the rewrite. The previous version made blocking Accessibility calls directly inside the `CGEventTap` callback, which occasionally froze keyboard input system-wide (the tap has a hard timeout; if the callback doesn't return in time, macOS disables it). The current design enforces a strict split:

```
tap thread (EventTapController, own run loop)
    → parses the raw CGEvent, appends to KeystrokeBuffer, returns immediately
    → NEVER touches AX, NSSpellChecker, disk, or any blocking primitive
        ↓ (EventTapDelegate callback, still on tap thread — kept trivial)
work queue (DispatchQueue, .userInitiated, owned by SwitchCoordinator)
    → LayoutDetector.evaluate(), SystemWordValidator, TextInjector — all AX I/O happens here
        ↓
main queue
    → UI callbacks only (onSwitched / onUndone → AppState)
```

`EventTapDelegate.tap(_:didObserve:)` is called synchronously inside the tap callback; its contract (documented at the protocol) forbids anything blocking. The event itself is **never suppressed** — `tapCallback` always returns the original event unmodified; correction happens after the fact, on top of what was already typed. This avoids the input races and dropped keystrokes that suppressing events invites.

### File structure

| File | Responsibility |
|---|---|
| `Core/Layout/Layout.swift` | `enum Layout` (en/ru), `struct KeyStroke` (keyCode + shift + char) |
| `Core/Layout/KeyboardLayoutTable.swift` | keyCode ↔ character table for one layout, built from real layout data via `UCKeyTranslate` |
| `Core/Layout/LayoutMapper.swift` | transposes text between layouts by physical key, using two `KeyboardLayoutTable`s |
| `Core/Detection/TrigramModel.swift` | loads the bundled binary trigram resource, `meanLogProb(_:terminated:)` |
| `Core/Detection/LayoutDetector.swift` | pure-function verdict: `keep` or `convert(to:text:)` |
| `Core/Detection/LanguagePrior.swift` | language of the last confirmed words, shifts the decision threshold |
| `Core/Detection/GuardRules.swift` | word/app exclusions, URL/path/secret heuristics — pure functions |
| `Core/Input/KeystrokeBuffer.swift` | buffers `KeyStroke`s (not characters) for the current word |
| `Core/Input/EventTapController.swift` | owns the `CGEventTap`, runs it on a dedicated thread |
| `Core/Replacement/AXTextClient.swift` | thin wrapper over Accessibility, sets a messaging timeout |
| `Core/Replacement/ClipboardGuard.swift` | snapshots and restores the pasteboard across all types, guarded by `changeCount` |
| `Core/Replacement/TextInjector.swift` | four replacement strategies, per-bundle-ID strategy cache |
| `Core/SwitchCoordinator.swift` | wires tap → detector → injector; owns the three-queue split; double-Shift undo |
| `Core/SystemWordValidator.swift` | `NSSpellChecker` wrapped as `WordValidating`, LRU cache with TTL |
| `Core/AppState.swift` | `ObservableObject` managing settings, unchanged from before the rewrite |
| `Core/SwitchDictionary.swift` | learning and exclusions, unchanged from before the rewrite |
| `Core/InputSourceManager.swift` | TIS layout switching, unchanged from before the rewrite |
| `Tools/build_trigram_model.py` | offline generator for `Resources/en.trigram` / `ru.trigram` (not run at build time) |

Removed in the rewrite: `KeyboardEngine.swift`, `TextReplacer.swift`, `SpellCheckService.swift`, `LayoutConverter.swift` — superseded by the files above.

## Key Algorithms

### Detection: character-trigram language model

`TrigramModel` holds a dense table of `log10 P(c₂ | c₀c₁)` per language, built offline by `Tools/build_trigram_model.py` from open word-frequency lists and bundled as a binary resource (`Resources/en.trigram`, `ru.trigram`) — no dictionaries or network calls at runtime. `LayoutDetector.evaluate(word:currentLayout:trigger:)` is a pure function (no I/O, fully unit-testable) with two decision branches:

- **Delta branch** — the normal case. Both the current-layout model and the target-layout model score the word (`meanLogProb`); the decision is `targetScore − currentScore > threshold`.
- **Absolute branch** — used when the current-layout model returns `nil`, i.e. the word contains characters outside its alphabet. This is not an edge case: it's how *every* Russian word containing б, ю, ж, э, х, ъ arrives, because on the EN layout those letters land on punctuation keys («любовь» is typed as `k.,jdm`). ~15% of the corpus goes through this branch. Here the decision is `targetScore > absoluteTarget threshold` — there's nothing to subtract from.

Thresholds (`DetectorThresholds.calibrated`) are **measured**, not chosen: a calibration sweep (`LayoutDetectorCalibrationTests`) against a labeled corpus picked the operating point. See the doc comment on `DetectorThresholds.calibrated` in [LayoutDetector.swift](Sources/Switcher/Core/Detection/LayoutDetector.swift) for the full sweep tables and reasoning — don't duplicate the numbers elsewhere; they're tied to the exact model build and will drift if repeated by hand.

`LanguagePrior` tracks the layout of the last few confirmed words and shifts the effective threshold for the ~0.68% of the dictionary that's genuinely ambiguous by keystrokes alone (e.g. «руку» ↔ «here»), where a single-word model has a hard ceiling.

**Word boundary is whitespace only.** Punctuation is deliberately *not* a boundary and stays inside the buffered word — same reason as the absolute branch above: on the wrong layout, punctuation keys are letters.

**Evaluation happens only at the word boundary — there is exactly one `Trigger` case, `wordBoundary`.** Earlier versions also scored the word on every keystroke (`early`) and after a typing pause (`pause`), trying to react before the user finished typing. Both were removed, not just recalibrated, because the failure mode isn't a threshold problem: a truncated prefix of a long Russian word is statistically indistinguishable from a complete Russian word of that length (e.g. typing `ghjdt` — a prefix of `ghjdthrf` → «проверка» — scored as a confident, complete word and got converted mid-word, corrupting the rest of the word as it kept coming in the wrong layout). Short words never showed the bug because they're already below `minWordLength` and never reached the early/pause triggers. See the doc comment on `Trigger` in [LayoutDetector.swift](Sources/Switcher/Core/Detection/LayoutDetector.swift) for the full measurement and `testUnterminatedPrefixesScoreAsConfidentlyAsWholeWords` in `LayoutDetectorCalibrationTests.swift` for the regression test — don't reintroduce a per-keystroke or pause-based trigger without addressing this first.

### Replacement: four strategies with pre/post verification

`TextInjector` tries strategies in this order, caching whichever one succeeds per bundle ID (`strategy(for bundleID:)`) so subsequent replacements in the same app skip straight to it, and self-healing if a cached strategy stops working (`recordFailure` evicts it, next call falls back to full order):

1. **`axDirect`** — direct AX range edit (`kAXSelectedTextRangeAttribute` + `kAXSelectedTextAttribute`). Zero synthetic events.
2. **`keycodeReplay`** — switches the input source, then replays the buffered `KeyStroke`s' keycodes. For terminals and other apps that read raw keycodes rather than the Unicode string on the event.
3. **`selectAndInject`** — Shift+← by character count to select, then a single `insertText`-style event with the whole replacement string (one undo step, nothing to race between characters).
4. **`clipboard`** — last resort: `ClipboardGuard` snapshot/write/paste/restore across all pasteboard types, tracked by `changeCount`.

Every strategy verifies the text under the caret **before** mutating (`verifiedPlan`/inline pre-flight — catches a stale buffer after a mouse click, app autocomplete, or the user typing ahead) and **after** (post-check via AX where AX is readable at all). If the pre-flight check fails, nothing is touched — silently doing nothing beats corrupting text that isn't what was expected. Strategies B/C/D return `true` without a post-check when AX isn't readable for that element at all; there's nothing to verify against, and treating that as failure would retry into a double-insert.

### Double Shift: undo only

`SwitchCoordinator` detects two Shift presses within 0.4s and, if a switch happened within the last 5s (`LastSwitchInfo.isUndoable`), replaces the corrected word back with what the user originally typed and switches the layout back. This is a deliberate scope cut from the previous version: double-Shift no longer converts an arbitrary text selection. If that's needed again, it's new work, not a regression to fix.

## Package layout

SwiftPM has three targets: `SwitcherCore` (library, `Sources/Switcher/`, the code above), `SwitcherApp` (executable, `Sources/SwitcherApp/` — entry point, `AppDelegate`, `Views/`), `SwitcherTests` (executable, `Sources/SwitcherTests/` — see [Testing](#testing)).

## Data Storage

- **Settings:** `UserDefaults.standard` (com.switcher.app domain)
- **Dictionary:** `~/.switcher/dictionary.json` (easy to access, backup, and version control)
- **Bundle Resources:** `Resources/Info.plist`, `Resources/AppIcon.icns`

**Dictionary Migration:** On first launch after update, automatically migrates from `~/Library/Application Support/Switcher/dictionary.json` to `~/.switcher/dictionary.json`

## SwiftUI Structure

- **Entry:** [SwitcherApp.swift](Sources/SwitcherApp/SwitcherApp.swift) — `MenuBarExtra` + `Settings` scenes
- **Views:** [MenuBarContentView.swift](Sources/SwitcherApp/Views/MenuBarContentView.swift), [SettingsView.swift](Sources/SwitcherApp/Views/SettingsView.swift) (5 tabs)
- **Delegation:** [AppDelegate.swift](Sources/SwitcherApp/AppDelegate.swift) — Requests accessibility permission on launch

## Adding New Layouts

`Layout` is a closed `en`/`ru` enum by design (see [Layout.swift](Sources/Switcher/Core/Layout/Layout.swift)) — adding a third layout means extending the enum itself, not just a table. From there:

1. Add the case to `enum Layout` and its `opposite`/`init?(languageCode:)` handling
2. Build a trigram model for the new language with `Tools/build_trigram_model.py` and bundle the resource (update `Package.swift` resources and `SwitchCoordinator.rebuildLayoutTables()`)
3. `KeyboardLayoutTable`/`LayoutMapper` need no per-language code — they read real layout data via `UCKeyTranslate`, so a new TIS input source is picked up automatically once its `Layout` case exists

Current support: 🇬🇧 English QWERTY ↔ 🇷🇺 Русский ЙЦУКЕН

## Code Signing

The app uses **ad-hoc signing** (`codesign --sign -`) via Makefile. No Apple Developer account required for local use. For distribution, update `Makefile` with actual signing identity.

## Testing

98 automated tests (plus 1 calibration test, skipped by default) live in the `SwitcherTests` **executable** target (`Sources/SwitcherTests/`), not a `Tests/` XCTest target — XCTest is not available in this environment. `main.swift` is a small hand-rolled runner (`runSuites`); run it with `swift run`, not `swift test`:

```bash
swift run SwitcherTests                          # full suite
swift run SwitcherTests GuardRulesTests          # one suite by name
SWITCHER_SWEEP=1 swift run SwitcherTests testPrintThresholdSweep  # calibration sweep (skipped by default)
```

`swift test` finds nothing (`error: no tests found; create a target in the 'Tests' directory`) — there is no `Tests` target in this package. That's expected, not broken; don't "fix" it by adding one without addressing why XCTest isn't usable here first.

Covered by automated tests: `KeyboardLayoutTable`/`LayoutMapper` (both layouts, driven by real `UCKeyTranslate` data), `TrigramModel`, detector threshold calibration, `LanguagePrior`, `GuardRules`, `KeystrokeBuffer`, `EventTapController` (event classification — a pure function, no real tap involved), `ClipboardGuard`, `TextInjector` (range planning and strategy selection).

This doesn't remove the need for manual testing, still required for:
1. Real `CGEventTap` behavior in live apps (TextEdit, browsers, terminals, Electron)
2. Accessibility permission handling, including granting it while the app is running
3. Exclusions (password fields, apps on the exclusion list)
4. Clipboard integrity and surrounding text safety during a real replacement

## Подпись кода и разрешение Accessibility

Приложение подписывается локальной идентичностью `Switcher Dev Signing`, а не
ad-hoc. Это не косметика: macOS привязывает выданное разрешение Accessibility к
«требованию к коду». При ad-hoc-подписи требование — это отпечаток самого
бинарника:

    designated => cdhash H"0e16d501..."

то есть КАЖДАЯ пересборка выглядит для системы новым приложением, разрешение
перестаёт действовать, и приложение молча перестаёт ловить клавиатуру. Со стороны
это неотличимо от сломанного кода — на отладку такого симптома легко потерять час.

С сертификатом требование не содержит отпечатка бинарника:

    designated => identifier "com.switcher.app" and certificate leaf = H"e20730..."

и переживает пересборки. Проверено: изменение бинарника меняет cdhash, но не
требование.

Создать идентичность на новой машине — один раз:

    make cert

Доверять сертификату не нужно: доверие требуется для ПРОВЕРКИ подписи, а не для
подписания, и `codesign` работает с недоверенным сертификатом. Если идентичности
нет, `make sign` откатывается на ad-hoc и печатает предупреждение.

Если разрешение всё же слетело (например, после смены идентичности), в Системных
настройках нужно УДАЛИТЬ приложение из списка Универсального доступа и добавить
заново — простое переключение галочки оставит устаревшую запись.
