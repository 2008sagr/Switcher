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
