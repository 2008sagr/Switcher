import Foundation
import ApplicationServices
import Carbon
import AppKit

// MARK: - C-compatible event tap callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passRetained(event) }
    let engine = Unmanaged<KeyboardEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handleCGEvent(proxy: proxy, type: type, event: event)
}

// MARK: - KeyboardEngine

final class KeyboardEngine {

    // MARK: - Configuration

    var autoSwitchEnabled:  Bool              = true
    var doubleShiftEnabled: Bool              = true
    var spellCheckEnabled:  Bool              = true
    var minWordLength:      Int               = 4
    var learningEnabled:    Bool              = true
    var exclusions:         Set<String>       = []
    var excludedApps:       Set<String>       = []
    var corrections:        [String: String]  = [:]  // lowercased "from" → "to"

    // MARK: - Callbacks

    var onSwitched: ((LastSwitchInfo) -> Void)?
    var onUndone:   ((LastSwitchInfo) -> Void)?

    // MARK: - Private state

    private var eventTap:          CFMachPort?
    private var runLoopSource:     CFRunLoopSource?
    private var appObserver:       NSObjectProtocol?

    private var wordBuffer:          String       = ""
    private var lastShiftDownTime:   TimeInterval = 0
    private let doubleShiftInterval: TimeInterval = 0.4
    private var currentAppBundleID:  String       = ""
    private var lastSwitch:          LastSwitchInfo?

    private let inputSourceManager = InputSourceManager()
    private let layoutConverter    = LayoutConverter()
    private let spellChecker       = SpellCheckService()
    private let textReplacer       = TextReplacer()

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            print("[Switcher] Not trusted — waiting for Accessibility permission")
            return
        }

        // Track frontmost app for per-app exclusions
        currentAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.currentAppBundleID = app?.bundleIdentifier ?? ""
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .headInsertEventTap,
            options:          .defaultTap,
            eventsOfInterest: mask,
            callback:         eventTapCallback,
            userInfo:         selfPtr
        ) else {
            Unmanaged<KeyboardEngine>.fromOpaque(selfPtr).release()
            print("[Switcher] Failed to create event tap — check Accessibility permission")
            return
        }

        eventTap      = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[Switcher] Event tap started")
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let obs = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appObserver = nil
        }
        eventTap      = nil
        runLoopSource = nil
        print("[Switcher] Event tap stopped")
    }

    var isRunning: Bool { eventTap != nil }

    func currentLanguage() -> String { inputSourceManager.currentLanguage() }

    // MARK: - Event dispatch

    func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout, let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return nil
        }

        if textReplacer.isReplacing { return Unmanaged.passRetained(event) }

        switch type {
        case .keyDown:
            let pass = handleKeyDown(event: event)
            return pass ? Unmanaged.passRetained(event) : nil
        case .flagsChanged:
            handleFlagsChanged(event: event)
            return Unmanaged.passRetained(event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - Key down
    // Returns true → pass through.  false → suppress.

    private func handleKeyDown(event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags   = event.flags

        // Other modifier combos: reset buffer, pass through
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            wordBuffer = ""
            lastSwitch = nil
            return true
        }

        switch keyCode {
        case 51:         // Backspace
            if !wordBuffer.isEmpty { wordBuffer.removeLast() }
            return true

        case 49:         // Space
            if applyCorrection(appendingChar: " ") { wordBuffer = ""; return false }
            let switched = triggerCheck(appendingChar: " ")
            wordBuffer = ""
            return !switched

        case 36, 76:     // Return / numpad Enter
            if applyCorrection(appendingChar: "\n") { wordBuffer = ""; return false }
            let switched = triggerCheck(appendingChar: "\n")
            wordBuffer = ""
            return !switched

        case 48:         // Tab
            wordBuffer = ""
            return true

        case 53:         // Escape — close undo window
            lastSwitch = nil
            return true

        case 123, 124, 125, 126:   // Arrow keys
            wordBuffer = ""
            return true

        default:
            guard let char = unicodeChar(from: event) else { return true }

            if isPunctuation(char) {
                if applyCorrection(appendingChar: char) { wordBuffer = ""; return false }
                let switched = triggerCheck(appendingChar: char)
                wordBuffer = ""
                return !switched
            } else {
                if lastSwitch != nil { lastSwitch = nil }
                wordBuffer.append(char)
                return true
            }
        }
    }

    // MARK: - Flags changed (double-Shift)

    private func handleFlagsChanged(event: CGEvent) {
        guard doubleShiftEnabled else { return }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags   = event.flags
        guard keyCode == 56 || keyCode == 60 else { return }
        guard flags.contains(.maskShift) else { return }

        let now = Date().timeIntervalSince1970
        if now - lastShiftDownTime < doubleShiftInterval {
            lastShiftDownTime = 0
            handleDoubleShift()
        } else {
            lastShiftDownTime = now
        }
    }

    // MARK: - Typo correction

    /// Returns true if a correction was applied (caller should suppress trigger char).
    @discardableResult
    private func applyCorrection(appendingChar: Character?) -> Bool {
        guard !corrections.isEmpty else { return false }
        guard !wordBuffer.isEmpty else { return false }
        guard !excludedApps.contains(currentAppBundleID) else { return false }
        guard !isFocusedElementSecure() else { return false }

        let word = wordBuffer
        guard let corrected = corrections[word.lowercased()] else { return false }

        let finalReplacement = corrected + (appendingChar.map { $0 != "\n" ? String($0) : "" } ?? "")
        let capturedWord = word
        wordBuffer = ""

        let info = LastSwitchInfo(originalWord: capturedWord, replacedWith: finalReplacement,
                                  fromLanguage: "", toLanguage: "", timestamp: Date(),
                                  isCorrection: true, isDoubleShift: false)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastSwitch = info
            self.textReplacer.replaceLastTyped(original: capturedWord, replacement: finalReplacement) {
                if appendingChar == "\n" { self.textReplacer.sendReturn() }
                self.onSwitched?(info)
            }
        }
        return true
    }

    // MARK: - Auto-switch

    @discardableResult
    private func triggerCheck(appendingChar: Character? = nil) -> Bool {
        guard autoSwitchEnabled else { return false }
        guard wordBuffer.count >= minWordLength else { return false }

        // Skip excluded apps
        guard !excludedApps.contains(currentAppBundleID) else { return false }

        // Skip password / secure text fields
        guard !isFocusedElementSecure() else { return false }

        let word = wordBuffer

        // Skip exceptions list
        guard !exclusions.contains(word.lowercased()) else { return false }

        // Skip URLs, emails, file paths
        guard !looksLikeURLOrEmail(word) else { return false }

        let currentLang = inputSourceManager.currentLanguage()
        let targetLang  = oppositeLanguage(currentLang)

        let converted = layoutConverter.convert(word, fromLanguage: currentLang, toLanguage: targetLang)
        guard !converted.isEmpty else { return false }

        guard spellChecker.detectWrongLayout(
            word: word, currentLanguage: currentLang,
            converted: converted, targetLanguage: targetLang,
            useSpellCheck: spellCheckEnabled
        ) else { return false }

        let finalReplacement = converted + (appendingChar.map { $0 != "\n" ? String($0) : "" } ?? "")
        let capturedWord     = word
        wordBuffer = ""

        let info = LastSwitchInfo(originalWord: capturedWord, replacedWith: finalReplacement,
                                  fromLanguage: currentLang, toLanguage: targetLang, timestamp: Date(),
                                  isCorrection: false, isDoubleShift: false)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastSwitch = info
            self.textReplacer.replaceLastTyped(original: capturedWord, replacement: finalReplacement) {
                self.inputSourceManager.switchToLanguage(targetLang)
                if appendingChar == "\n" { self.textReplacer.sendReturn() }
                self.onSwitched?(info)
            }
        }
        return true
    }

    // MARK: - Undo

    func performUndoFromUI() {
        guard let info = lastSwitch, info.isUndoable else { return }
        performUndo(info)
    }

    private func performUndo(_ info: LastSwitchInfo) {
        lastSwitch = nil
        wordBuffer = ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textReplacer.undoReplacement(original: info.replacedWith, replacement: info.originalWord) {
                if !info.isCorrection {
                    self.inputSourceManager.switchToLanguage(info.fromLanguage)
                }
                self.onUndone?(info)
            }
        }
    }

    // MARK: - Double-shift on selected text

    private func handleDoubleShift() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if let selected = self.textReplacer.getSelectedText(), !selected.isEmpty {
                self.performDoubleShiftConversion(selected: selected)
                return
            }
            if let info = self.lastSwitch, info.isUndoable {
                self.performUndo(info)
            }
        }
    }

    private func performDoubleShiftConversion(selected: String) {
        let fromLang: String
        let toLang:   String

        if scriptRatio(of: selected, lo: 0x41, hi: 0x7A) > 0.5 {
            fromLang = "en"; toLang = "ru"
        } else if scriptRatio(of: selected, lo: 0x0400, hi: 0x04FF) > 0.5 {
            fromLang = "ru"; toLang = "en"
        } else {
            fromLang = inputSourceManager.currentLanguage()
            toLang   = oppositeLanguage(fromLang)
        }

        let converted = layoutConverter.convert(selected, fromLanguage: fromLang, toLanguage: toLang, strict: false)
        guard !converted.isEmpty, converted != selected else { return }

        wordBuffer = ""
        textReplacer.replaceSelectedText(with: converted) { [weak self] in
            guard let self else { return }
            self.inputSourceManager.switchToLanguage(toLang)
            let info = LastSwitchInfo(originalWord: selected, replacedWith: converted,
                                      fromLanguage: fromLang, toLanguage: toLang, timestamp: Date(),
                                      isCorrection: false, isDoubleShift: true)
            self.lastSwitch = info
            self.onSwitched?(info)
        }
    }

    private func getSelectionViaClipboard(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let prevCount = pb.changeCount
        textReplacer.sendCmdC()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            completion(pb.changeCount != prevCount ? pb.string(forType: .string) : nil)
        }
    }

    // MARK: - Security check

    /// Returns true if the focused element is a password / secure text field.
    /// Auto-switch is disabled in such fields.
    private func isFocusedElementSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return false }

        return role == "AXSecureTextField"
    }

    // MARK: - URL / email guard

    private func looksLikeURLOrEmail(_ word: String) -> Bool {
        let lower = word.lowercased()
        // Email
        if lower.contains("@") { return true }
        // URL schemes
        if lower.hasPrefix("http") || lower.hasPrefix("www") || lower.hasPrefix("ftp") { return true }
        // File paths
        if lower.hasPrefix("/") || lower.hasPrefix("~/") { return true }
        // Multiple dots → domain-like
        if lower.filter({ $0 == "." }).count >= 2 { return true }
        return false
    }

    // MARK: - Helpers

    private func unicodeChar(from event: CGEvent) -> Character? {
        var length = 0
        var chars  = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0, let scalar = Unicode.Scalar(chars[0]) else { return nil }
        return Character(scalar)
    }

    private func isPunctuation(_ char: Character) -> Bool { ".,!?;:".contains(char) }

    private func oppositeLanguage(_ lang: String) -> String { lang.hasPrefix("ru") ? "en" : "ru" }

    private func scriptRatio(of text: String, lo: UInt32, hi: UInt32) -> Double {
        let letters = text.filter { $0.isLetter }
        guard !letters.isEmpty else { return 0 }
        let matching = letters.filter { ($0.unicodeScalars.first?.value).map { lo <= $0 && $0 <= hi } == true }
        return Double(matching.count) / Double(letters.count)
    }
}
