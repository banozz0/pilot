import Foundation
import PilotCore
import Translation

/// The menu's translator (card agent-bo-95422773): Apple's Translation framework on the Mac itself, with languages
/// already downloaded, so no text leaves the Mac and no account or key is used. A session per translation: the
/// system keeps the model warm, so only the first one after a while takes about two seconds.
struct AppleTranslator: Translator {
    /// Always the high-fidelity engine. Pilot's binary records SDK 26.0 (Package.swift's macOS 26), and for such a binary
    /// Translation's default is the low-latency Traditional engine, whose languages are separate downloads; the ones
    /// Language & Region installs are high fidelity, so the default threw notInstalled for every phrase while a probe
    /// linked against SDK 27 translated (card agent-bo-95422773, 2026-10-05). Not provable under swift test: the test
    /// runner records SDK 27, so the default is high fidelity there already. macOS 26.0 to 26.3 have no strategy to ask
    /// for and keep the default.
    private static func session(from: String, to: String) -> TranslationSession {
        let source = Locale.Language(identifier: from), target = Locale.Language(identifier: to)
        guard #available(macOS 26.4, *) else { return TranslationSession(installedSource: source, target: target) }
        return TranslationSession(installedSource: source, target: target, preferredStrategy: .highFidelity)
    }

    func translate(_ text: String, from: String, to: String) async throws(TranslateFailure) -> String {
        let session = Self.session(from: from, to: to)
        do { return try await session.translate(text).targetText }
        catch TranslationError.notInstalled { throw .notInstalled }
        catch { throw .failed }
    }
}

extension AppleTranslator {
    /// Which of `languages` already translate on this Mac with `other` (P40's lists): into `other` when they are From's,
    /// out of it when they are To's. LanguageAvailability asks the system, nothing is downloaded.
    static func installed(_ languages: [String], with other: String, from: Bool) async -> Set<String> {
        let side = Locale.Language(identifier: other)
        return await withTaskGroup(of: String?.self) { group in
            for code in languages where code != other {
                group.addTask {
                    let language = Locale.Language(identifier: code)
                    return await LanguageAvailability().status(from: from ? language : side, to: from ? side : language) == .installed ? code : nil
                }
            }
            // The other side itself is on this Mac whenever anything is: picking it swaps the two.
            return await group.reduce(into: [other]) { found, code in if let code { found.insert(code) } }
        }
    }
}
