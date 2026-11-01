import AppKit
import CoreServices
import PilotCore

/// The Mac's own dictionary for Define (Q596): the entry's record from the first active dictionary that has the word
/// (DictionaryServices' record calls: syllables, pronunciation, every example, origin, the dictionary's name), or the
/// run-on text `DCSCopyTextDefinition` answers when no record reads; offline, off the main thread: "serendipity" 49 ms,
/// "casa" 1 ms on Sven's Mac (2026-10-30). Both answer nil under the `swift` interpreter and in `swift test`, so only
/// Pilot.app calls them.
enum MacDictionary {
    /// The word's entry, cut into senses (DictionaryEntry); nil for a word no dictionary on this Mac has.
    static func entry(_ word: String) async -> DictionaryEntry? {
        await Task.detached(priority: .userInitiated) { lookUp(word) }.value
    }

    /// A word's entry, from its record; an inflection ("serendipities") has no record of its own, so the text's headword
    /// is tried next, and the text itself last.
    private nonisolated static func lookUp(_ word: String) -> DictionaryEntry? {
        if let entry = record(word) { return entry }
        guard let fromText = text(word).flatMap(DictionaryEntry.init(definition:)) else { return nil }
        return fromText.word.lowercased() == word.lowercased() ? fromText : record(fromText.word) ?? fromText
    }

    private nonisolated static func text(_ word: String) -> String? {
        let text = word as NSString
        return DCSCopyTextDefinition(nil, text, CFRange(location: 0, length: text.length))?.takeRetainedValue() as String?
    }

    /// DictionaryServices' record calls, which the SDK does not declare; nil when this macOS lacks one.
    private struct Records: @unchecked Sendable {
        typealias Active = @convention(c) () -> Unmanaged<CFArray>?
        typealias Search = @convention(c) (CFTypeRef, CFString, CFTypeRef?, CFTypeRef?) -> Unmanaged<CFArray>?
        typealias Data = @convention(c) (CFTypeRef, Int) -> Unmanaged<CFString>?
        typealias Name = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
        let active: Active, search: Search, data: Data, name: Name

        static let shared: Records? = {
            guard let library = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices", RTLD_NOW),
                  let active = dlsym(library, "DCSGetActiveDictionaries"), let search = dlsym(library, "DCSCopyRecordsForSearchString"),
                  let data = dlsym(library, "DCSRecordCopyData"), let name = dlsym(library, "DCSDictionaryGetName") else { return nil }
            return Records(active: unsafeBitCast(active, to: Active.self), search: unsafeBitCast(search, to: Search.self),
                           data: unsafeBitCast(data, to: Data.self), name: unsafeBitCast(name, to: Name.self))
        }()
    }

    /// The word's entry in the first active dictionary whose records read as one; a thesaurus is passed over.
    private nonisolated static func record(_ word: String) -> DictionaryEntry? {
        guard let calls = Records.shared, let dictionaries = calls.active()?.takeUnretainedValue() as? [AnyObject] else { return nil }
        for dictionary in dictionaries {
            let name = calls.name(dictionary)?.takeUnretainedValue() as String?
            if name?.localizedCaseInsensitiveContains("thesaurus") == true { continue }
            // The exact search: the other methods are undocumented and crash or answer junk (2026-10-31).
            let records = calls.search(dictionary, word as CFString, nil, nil)?.takeRetainedValue() as? [AnyObject] ?? []
            let bodies = records.compactMap { calls.data($0, 0)?.takeRetainedValue() as String? }
            if let entry = DictionaryEntry(records: bodies, dictionary: name, search: word) { return entry }
        }
        return nil
    }

    /// What a misspelt or half-typed English word may be, best first, each a word this Mac's dictionary defines, with its
    /// entry: the spell checker's guesses, correction and completions, then the nearest words in the Mac's word list.
    @MainActor
    static func suggestions(_ word: String, count: Int) async -> [(word: String, entry: DictionaryEntry)] {
        let checker = NSSpellChecker.shared, range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = checker.guesses(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        let corrected = checker.correction(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0)
        let completions = checker.completions(forPartialWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        let checked = guesses + [corrected].compactMap(\.self) + completions
        let pass = Task.detached(priority: .userInitiated) {
            var found: [(word: String, entry: DictionaryEntry)] = [], tried: Set<String> = [word.lowercased()], listed: Set<String> = []
            func take(_ candidates: [String]) {
                // An entry is listed once: "serendipities" and "serendipity's" are serendipity. A newer keystroke stops it.
                for candidate in candidates where found.count < count && !Task.isCancelled {
                    guard tried.insert(candidate.lowercased()).inserted, let entry = lookUp(candidate),
                          listed.insert(entry.word.lowercased()).inserted else { continue }
                    found.append((entry.word, entry))
                }
            }
            take(checked)
            if found.count < count, !Task.isCancelled, let list = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
                take(Define.nearest(word, in: list.split(separator: "\n"), limit: count * 4))
            }
            return found
        }
        return await withTaskCancellationHandler { await pass.value } onCancel: { pass.cancel() }
    }
}
