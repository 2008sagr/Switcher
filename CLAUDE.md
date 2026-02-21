# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Switcher is a macOS utility that automatically corrects text typed in the wrong keyboard layout (EN ↔ RU) without hotkeys. It uses CGEventTap to intercept keyboard events at the system level and performs intelligent layout detection and conversion.

## Build Commands

```bash
# Build and run (recommended for development)
make run           # Builds release bundle, signs ad-hoc, and launches

# Build without running
make bundle        # Creates Switcher.app in project root

# Debug build only
swift build        # Compiles without creating .app bundle

# Create DMG for distribution
make dmg           # Creates signed Switcher.dmg with drag-to-Applications layout

# Clean all build artifacts
make clean
```

**Requirements:** macOS 14 Sonoma or newer, Xcode Command Line Tools

**Permissions:** Accessibility permission required (System Settings → Privacy & Security → Accessibility). Without it, CGEventTap creation fails silently and the app does nothing.

## Architecture

### Event Processing Flow

The core architecture is built around a **CGEventTap** registered at session level (`.cgSessionEventTap`, `.headInsertEventTap`) that intercepts all keyboard events before they reach applications:

```
User types → CGEventTap → eventTapCallback (C function)
                              ↓
                         KeyboardEngine.handleCGEvent()
                              ↓
                    ┌─────────┴─────────┐
                    ↓                   ↓
            handleKeyDown()      handleFlagsChanged()
                    ↓                   ↓
            (auto-switch logic)    (double Shift detection)
```

**Critical implementation detail:** The tap callback MUST be a C-compatible free function (`eventTapCallback`), which uses `Unmanaged<KeyboardEngine>` to bridge to Swift instance methods. The engine instance is retained when the tap is created and released when stopped.

### Core Components

**[KeyboardEngine.swift](Sources/Switcher/Core/KeyboardEngine.swift)** — Central event processing
- Manages CGEventTap lifecycle
- Buffers typed characters (including punctuation) in `wordBuffer` with max limit of 50 chars (prevents memory issues)
- Triggers auto-switch ONLY on Space and Enter (punctuation is NOT a trigger to avoid breaking words with layout-mapped symbols)
- Handles double Shift detection (< 0.4s between presses)
- **Replacement guard:** Sets `isReplacing = true` during text replacement to prevent synthetic events (backspace, Cmd+V) from being processed recursively
- **Buffer overflow protection:** Resets buffer when exceeding `maxWordBufferLength` (50 chars) to handle code/JSON input

**[TextReplacer.swift](Sources/Switcher/Core/TextReplacer.swift)** — Two replacement strategies
- **AX API path:** Uses `kAXSelectedTextRangeAttribute` + `kAXSelectedTextAttribute` (instant, no clipboard side effects)
- **Backspace + Paste fallback:** Synthetic backspace events + `NSPasteboard` with clipboard preservation (used for auto-switch and apps without AX support)

**[SpellCheckService.swift](Sources/Switcher/Core/SpellCheckService.swift)** — Layout validation
- Primary: `NSSpellChecker` (word must be invalid in current layout, valid after conversion)
- **Performance optimization:** LRU (Least Recently Used) cache for spell-check results
  - Max 200 entries with timestamp tracking
  - Frequently used words stay in cache indefinitely
  - When full, evicts only the least recently accessed entry
- Fallback: N-gram analysis using top-40 bigrams for EN/RU (when target language dictionary not installed)
- **Design choice:** Pure Unicode block detection intentionally avoided to prevent false positives on ambiguous Latin text

**[LayoutConverter.swift](Sources/Switcher/Core/LayoutConverter.swift)** — Character mapping
- Static table of 70 pairs (QWERTY ↔ ЙЦУКЕН, upper + lower case)
- `strict: true` mode: unmappable chars → empty string (used for auto-switch)
- `strict: false` mode: unmappable chars → passthrough (used for double Shift on arbitrary selection)

**[AppState.swift](Sources/Switcher/Core/AppState.swift)** — `ObservableObject` managing settings
- All settings persisted to `UserDefaults`
- Propagates changes to `KeyboardEngine` properties
- Handles `SMAppService` for launch-at-login

**[SwitchDictionary.swift](Sources/Switcher/Core/SwitchDictionary.swift)** — Learning and exclusions
- Stored at: `~/.switcher/dictionary.json` (user home directory, survives app updates)
- Auto-migrates from legacy location: `~/Library/Application Support/Switcher/`
- Contains: `exceptions` (never switch), `excludedApps` (bundle IDs), `corrections` (typo rules)
- Pretty-printed JSON for stable git diffs
- **Learning mode:** Double Shift undo → add to exceptions; Double Shift on selection → add conversion pair to corrections

### Key Algorithms

**Auto-switch triggers:** Only **Space** and **Enter/Return** trigger word processing
- Punctuation marks (`.`, `,`, `;`, etc.) are NOT triggers because they map to letters in other layouts
- Example: Russian "любовь" typed in EN → "k.jdjm" — the `.` is actually `ю` and must be part of the word buffer

**Auto-switch trigger conditions** (all must pass after Space/Enter):
1. Word length >= `minWordLength` (default: 4)
2. Current app NOT in `excludedApps`
3. Active field NOT `AXSecureTextField` (password field)
4. Word NOT resembles URL/email/file path
5. Word NOT in `exceptions` set
6. `SpellCheckService.detectWrongLayout()` returns true

**Double Shift behavior:**
- **With text selection:** Detect language by cyrillics/Latin ratio → convert using `LayoutConverter` (strict: false) → replace via AX API
- **Without selection:** If `lastSwitch` exists and < 5s old → undo conversion via AX API

**Replacement safety:**
1. Set `textReplacer.isReplacing = true`
2. Perform replacement (AX or backspace+paste)
3. Set `textReplacer.isReplacing = false`
4. While `isReplacing == true`, `handleCGEvent` returns events unmodified to prevent recursion

## Data Storage

- **Settings:** `UserDefaults.standard` (com.switcher.app domain)
- **Dictionary:** `~/.switcher/dictionary.json` (easy to access, backup, and version control)
- **Bundle Resources:** `Resources/Info.plist`, `Resources/AppIcon.icns`

**Dictionary Migration:** On first launch after update, automatically migrates from `~/Library/Application Support/Switcher/dictionary.json` to `~/.switcher/dictionary.json`

## SwiftUI Structure

- **Entry:** [SwitcherApp.swift](Sources/Switcher/SwitcherApp.swift) — `MenuBarExtra` + `Settings` scenes
- **Views:** [MenuBarContentView.swift](Sources/Switcher/Views/MenuBarContentView.swift), [SettingsView.swift](Sources/Switcher/Views/SettingsView.swift) (5 tabs)
- **Delegation:** [AppDelegate.swift](Sources/Switcher/AppDelegate.swift) — Requests accessibility permission on launch

## Adding New Layouts

To support additional layout pairs beyond EN↔RU:

1. Add character mapping table in [LayoutConverter.swift](Sources/Switcher/Core/LayoutConverter.swift)
2. Extend `convert()` method with new case
3. Update `SpellCheckService` n-gram tables if using fallback detection for new language

Current support: 🇬🇧 English QWERTY ↔ 🇷🇺 Русский ЙЦУКЕН

## Code Signing

The app uses **ad-hoc signing** (`codesign --sign -`) via Makefile. No Apple Developer account required for local use. For distribution, update `Makefile` with actual signing identity.

## Testing Notes

This project currently has **no automated tests**. Testing requires:
1. Manual testing with Accessibility permission granted
2. Verifying CGEventTap behavior in real apps (TextEdit, browsers, terminals)
3. Testing exclusions (e.g., password fields, excluded apps like IDEs)
4. Validating dictionary persistence across restarts
