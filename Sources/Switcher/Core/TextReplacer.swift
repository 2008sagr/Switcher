import Cocoa
import ApplicationServices

/// Handles all text replacement operations:
/// 1. Replace last typed word (auto-switch)
/// 2. Replace selected text (double-shift)
final class TextReplacer {

    /// Set to true while a replacement is in progress to prevent re-triggering.
    var isReplacing: Bool = false

    // MARK: - Replace last typed word (auto-switch case)

    /// Deletes `original` (via backspaces) and types `replacement` (via clipboard paste).
    func replaceLastTyped(original: String, replacement: String, completion: (() -> Void)? = nil) {
        isReplacing = true

        let deleteCount = original.count
        sendBackspaces(deleteCount)

        // Wait for backspaces to be processed, then paste
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(deleteCount) * 0.008 + 0.04) {
            self.pasteText(replacement) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.isReplacing = false
                    completion?()
                }
            }
        }
    }

    // MARK: - Replace selected text (double-shift case)

    /// Tries Accessibility API first, then clipboard paste fallback.
    func replaceSelectedText(with replacement: String, completion: (() -> Void)? = nil) {
        isReplacing = true

        if setSelectedTextViaAccessibility(replacement) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.isReplacing = false
                completion?()
            }
            return
        }

        // Fallback: paste over selection
        pasteText(replacement) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.isReplacing = false
                completion?()
            }
        }
    }

    // MARK: - Undo replacement (AX-first to avoid clipboard freeze)

    /// Selects the last `original.count` characters via AX and replaces them directly.
    /// Falls back to backspace + paste if the app doesn't support AX text mutation.
    func undoReplacement(original: String, replacement: String, completion: (() -> Void)? = nil) {
        isReplacing = true
        if replaceViaAXRange(original: original, replacement: replacement) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.isReplacing = false
                completion?()
            }
            return
        }
        // Fallback: backspace + paste (slower path)
        let deleteCount = original.count
        sendBackspaces(deleteCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(deleteCount) * 0.008 + 0.04) {
            self.pasteText(replacement) {
                self.isReplacing = false
                completion?()
            }
        }
    }

    /// Moves cursor selection back by `original.count`, verifies the text, then replaces it.
    /// Returns false if AX is not supported or the selected text doesn't match.
    private func replaceViaAXRange(original: String, replacement: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        let axElement = element as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rawValue = rangeRef else { return false }
        let axValue = rawValue as! AXValue

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.length == 0,
              range.location >= original.count else { return false }

        var newRange = CFRange(location: range.location - original.count, length: original.count)
        guard let newRangeValue = AXValueCreate(.cfRange, &newRange) else { return false }
        guard AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, newRangeValue) == .success else { return false }

        // Verify selection matches expected text before overwriting
        var selRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextAttribute as CFString, &selRef) == .success,
              let selected = selRef as? String, selected == original else {
            // Restore cursor to original position and bail
            if let restore = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, restore)
            }
            return false
        }

        return AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, replacement as CFTypeRef) == .success
    }

    // MARK: - Get selected text

    func getSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }

        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selection) == .success else {
            return nil
        }
        return selection as? String
    }

    // MARK: - Private helpers

    private func setSelectedTextViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }

        let result = AXUIElementSetAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    private func pasteText(_ text: String, completion: (() -> Void)? = nil) {
        let pb = NSPasteboard.general
        let previousContents = pb.string(forType: .string)
        let previousTypes = pb.types ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Small delay to ensure the pasteboard write is visible to the target app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.sendCmdV()

            // Restore original clipboard content
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                pb.clearContents()
                if let prev = previousContents, previousTypes.contains(.string) {
                    pb.setString(prev, forType: .string)
                }
                completion?()
            }
        }
    }

    func sendCmdC() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)   // kVK_ANSI_C = 8
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func sendReturn() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        down?.flags = []
        up?.flags   = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)

        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)   // kVK_Delete = 51
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
            down?.flags = []   // explicitly clear modifiers — prevents Ctrl+Backspace when called during Ctrl+Z undo
            up?.flags   = []
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func sendCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // kVK_ANSI_V = 9
        let vUp   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
