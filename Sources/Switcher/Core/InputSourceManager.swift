import Carbon
import Foundation

/// Manages macOS TIS input sources (keyboard layouts).
final class InputSourceManager {

    // MARK: - Current layout

    func currentLanguage() -> String {
        guard let source = currentSource() else { return "en" }
        return language(for: source) ?? "en"
    }

    func currentSource() -> TISInputSource? {
        return TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    }

    // MARK: - Switching

    func switchToLanguage(_ lang: String) {
        guard let source = selectableSource(for: lang) else {
            print("[Switcher] No selectable input source found for language: \(lang)")
            return
        }
        TISSelectInputSource(source)
    }

    // MARK: - Available sources

    func availableLanguages() -> [String] {
        return selectableSources().compactMap { language(for: $0) }.removingDuplicates()
    }

    func selectableSources() -> [TISInputSource] {
        let filter: [String: Any] = [
            kTISPropertyInputSourceIsEnabled as String:         true,
            kTISPropertyInputSourceIsSelectCapable as String:   true
        ]

        guard let listRef = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() else {
            return []
        }
        let count = CFArrayGetCount(listRef)
        return (0..<count).compactMap { i -> TISInputSource? in
            guard let ptr = CFArrayGetValueAtIndex(listRef, i) else { return nil }
            return Unmanaged<TISInputSource>.fromOpaque(ptr).takeUnretainedValue()
        }
    }

    // MARK: - Helpers

    func language(for source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as NSArray
        return langs.firstObject as? String
    }

    func localizedName(for source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func selectableSource(for lang: String) -> TISInputSource? {
        return selectableSources().first { source in
            guard let srcLang = language(for: source) else { return false }
            return srcLang.lowercased().hasPrefix(lang.prefix(2).lowercased())
        }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
