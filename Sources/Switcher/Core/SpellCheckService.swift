import AppKit
import NaturalLanguage

/// Validates words and detects likely wrong-layout input.
final class SpellCheckService {

    private let checker = NSSpellChecker.shared

    // MARK: - Cache for spell checking results (LRU)
    private struct CacheEntry {
        let isValid: Bool
        var lastAccess: Date
    }
    private var spellCheckCache: [String: CacheEntry] = [:]
    private let maxCacheSize = 200  // Limit cache to prevent memory bloat

    // MARK: - Spell checking

    /// Returns true if `word` appears to be a valid word in `language` (e.g. "en", "ru").
    func isValidWord(_ word: String, language: String) -> Bool {
        guard word.count >= 2 else { return true }

        // Check cache first
        let cacheKey = "\(word)|\(language)"
        if var cached = spellCheckCache[cacheKey] {
            // Cache hit — update access time and return
            cached.lastAccess = Date()
            spellCheckCache[cacheKey] = cached
            return cached.isValid
        }

        // Cache miss — perform actual spell check
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let isValid = range.location == NSNotFound

        // Store in cache (evict LRU entry if full)
        if spellCheckCache.count >= maxCacheSize {
            evictLeastRecentlyUsed()
        }
        spellCheckCache[cacheKey] = CacheEntry(isValid: isValid, lastAccess: Date())

        return isValid
    }

    /// Evicts the least recently used entry from the cache.
    private func evictLeastRecentlyUsed() {
        guard let oldestKey = spellCheckCache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else {
            return
        }
        spellCheckCache.removeValue(forKey: oldestKey)
    }

    // MARK: - Wrong layout detection

    /// Returns true if the word was almost certainly typed in the wrong layout.
    ///
    /// Strategy:
    /// 1. (Primary)   Spell checker — only works when language dictionary is installed.
    /// 2. (Fallback)  N-gram frequency — does the word contain bigrams common in the language?
    ///               Much more reliable than script-only check. "xnjnj" has zero English bigrams;
    ///               "привет" contains the very common Russian bigram "пр".
    ///
    /// Crucially, we do NOT use a pure script (character-set) fallback — that is what caused
    /// "чтото" → "xnjnj" false-positives: "xnjnj" is all-Latin but not English.
    func detectWrongLayout(
        word: String,
        currentLanguage: String,
        converted: String,
        targetLanguage: String,
        useSpellCheck: Bool
    ) -> Bool {
        // Safety: if the word itself already contains characters from the target script,
        // something is off — skip to avoid weird double-conversions.
        if containsScriptOf(targetLanguage, in: word) { return false }

        if useSpellCheck {
            // Spell check path — most accurate, requires dictionaries.
            // Current word must be invalid AND converted must be valid.
            if isValidWord(word, language: currentLanguage) { return false }
            if isValidWord(converted, language: targetLanguage) { return true }

            // Spell checker may not have the target language dictionary installed.
            // Fall through to n-gram check for the converted word only.
            return hasLanguageNgrams(converted, language: targetLanguage)
        } else {
            // No spell check: pure n-gram heuristic.
            // Current word should NOT have common n-grams of current language.
            if hasLanguageNgrams(word, language: currentLanguage) { return false }
            // Converted word MUST have common n-grams of target language.
            return hasLanguageNgrams(converted, language: targetLanguage)
        }
    }

    // MARK: - N-gram frequency analysis

    /// Checks whether `word` contains at least one bigram that is very common
    /// in `language`. Calibrated to avoid false positives:
    /// - "xnjnj" has none of the English bigrams → returns false (correct: not English)
    /// - "привет" contains "пр" → returns true (correct: Russian)
    /// - "чтото" contains "то" → returns true (correct: do NOT switch away from Russian)
    func hasLanguageNgrams(_ word: String, language: String) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 2 else { return false }

        switch language.prefix(2).lowercased() {
        case "en":
            // Top ~30 English bigrams by corpus frequency.
            // "gh" intentionally excluded — it looks common but rarely starts words.
            let bigrams = ["th","he","in","er","an","re","on","en","at","es",
                           "ed","ha","le","to","st","or","is","ar","ou","nt",
                           "it","al","as","ng","nd","se","di","ca","te","ll",
                           "we","ri","ro","li","io","ay","ti","de","me","ea"]
            return bigrams.contains { lower.contains($0) }

        case "ru":
            // Top ~30 Russian bigrams.
            let bigrams = ["то","на","не","ст","ен","ть","но","ра","та","ни",
                           "ел","пр","ко","от","ов","во","по","го","за","ло",
                           "ле","ри","ил","ер","ет","ал","ан","ро","ки","де",
                           "ли","ча","ес","со","ем","ва","ла","ит","ве","ив"]
            return bigrams.contains { lower.contains($0) }

        default:
            return false
        }
    }

    // MARK: - Script helpers

    /// Returns true if `text` contains ANY letter-character from `language`'s script.
    private func containsScriptOf(_ language: String, in text: String) -> Bool {
        return text.contains { isCharInScript($0, forLanguage: language) }
    }

    private func isCharInScript(_ char: Character, forLanguage lang: String) -> Bool {
        guard let v = char.unicodeScalars.first?.value else { return false }
        switch lang.prefix(2).lowercased() {
        case "ru": return v >= 0x0400 && v <= 0x04FF   // Cyrillic block
        case "en": return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) // Basic Latin A-Za-z
        default:   return false
        }
    }
}
