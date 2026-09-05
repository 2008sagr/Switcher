import Carbon
import Foundation

/// Manages macOS TIS input sources (keyboard layouts).
///
/// ВСЕ методы этого класса обязаны вызываться ТОЛЬКО с главного потока.
/// Внутри HIToolbox у TIS-функций (`TISCopyCurrentKeyboardInputSource`,
/// `TISSelectInputSource`, `TISGetInputSourceProperty`,
/// `TISCreateInputSourceList`...) стоит `dispatch_assert_queue` на главную
/// очередь — вызов с любой другой валит процесс через
/// `EXC_BREAKPOINT`/`SIGTRAP` (`_dispatch_assert_queue_fail`), а не
/// возвращает ошибку, которую можно было бы поймать. Это доказано четырьмя
/// идентичными крашами: `SwitchCoordinator.evaluate()` и `switchLayout()`
/// когда-то звали методы этого класса с фоновой очереди `work`.
///
/// `dispatchPrecondition` ниже — не попытка починить неправильный вызов на
/// лету (починить нечем, HIToolbox уже требует main), а страховка на
/// повторение: если когда-нибудь появится новый путь вызова с фоновой
/// очереди, он упадёт здесь же, с понятным местом в трейсе — вместо того,
/// чтобы падать тремя кадрами глубже внутри HIToolbox, как в исходных
/// крашлогах.
final class InputSourceManager {

    // MARK: - Current layout

    func currentLanguage() -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = currentSource() else { return "en" }
        return language(for: source) ?? "en"
    }

    func currentSource() -> TISInputSource? {
        dispatchPrecondition(condition: .onQueue(.main))
        return TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    }

    // MARK: - Switching

    func switchToLanguage(_ lang: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = selectableSource(for: lang) else {
            print("[Switcher] No selectable input source found for language: \(lang)")
            return
        }
        TISSelectInputSource(source)
    }

    // MARK: - Available sources

    func availableLanguages() -> [String] {
        dispatchPrecondition(condition: .onQueue(.main))
        return selectableSources().compactMap { language(for: $0) }.removingDuplicates()
    }

    func selectableSources() -> [TISInputSource] {
        dispatchPrecondition(condition: .onQueue(.main))
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
        dispatchPrecondition(condition: .onQueue(.main))
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as NSArray
        return langs.firstObject as? String
    }

    func localizedName(for source: TISInputSource) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func selectableSource(for lang: String) -> TISInputSource? {
        dispatchPrecondition(condition: .onQueue(.main))
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
