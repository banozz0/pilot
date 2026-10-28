import Foundation
import NaturalLanguage

/// What turns text into another language: Apple's on-device translation in the app (AppleTranslator), a fake in tests.
public protocol Translator: Sendable {
    func translate(_ text: String, from: String, to: String) async throws(TranslateFailure) -> String
}

public enum TranslateFailure: Error, Equatable {
    /// The language pair is not downloaded on this Mac.
    case notInstalled
    case failed
}

/// Translate's two languages (card agent-bo-95423002), a setting: text in any language goes into `home`, and text
/// already in `home` goes into `other`. English and Spanish until changed.
public struct TranslatePair: Equatable, Sendable {
    public let home: String
    public let other: String

    public static let standard = TranslatePair(home: "en", other: "es")!
    static let homeKey = "translate.home", otherKey = "translate.other"
    /// The languages Apple's on-device translation offers, by code (Language & Region downloads them), in name order.
    public static let languages = ["ar", "zh-Hans", "zh-Hant", "nl", "en", "fr", "de", "hi", "id", "it", "ja", "ko", "pl", "pt", "ru",
                                   "es", "th", "tr", "uk", "vi"]

    /// Nil for a language paired with itself.
    public init?(home: String, other: String) {
        guard home != other else { return nil }
        self.home = home
        self.other = other
    }

    /// The saved pair, or the standard one when none is saved or it is broken.
    public init(defaults: UserDefaults) {
        self = defaults.string(forKey: Self.homeKey).flatMap { home in
            defaults.string(forKey: Self.otherKey).flatMap { TranslatePair(home: home, other: $0) }
        } ?? .standard
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(home, forKey: Self.homeKey)
        defaults.set(other, forKey: Self.otherKey)
    }

    /// The pair with a new language of his own, or a new second one; picking the other side's language swaps the two.
    public func with(home: String) -> TranslatePair { TranslatePair(home: home, other: home == other ? self.home : other)! }
    public func with(other: String) -> TranslatePair { TranslatePair(home: other == home ? self.other : home, other: other)! }

    /// Where text in `source` goes.
    public func target(for source: String) -> String { source == home ? other : home }

    // Translate's line (P40): its From and To show `source` (picked, or detected; nil before any text, with Auto) and where
    // that goes. Each pick saves the two languages shown as the pair, To as `home`, so Auto then sends text in either into
    // the other: the pair follows the last pick.

    /// What the To chip shows: where `source` goes, or `home` before there is one.
    public func shownTarget(source: String?) -> String { source.map(target(for:)) ?? home }

    /// To set to `to`; picking the source's own language swaps the two.
    public func picking(to: String, source: String?) -> TranslatePair {
        let from = source ?? other
        return TranslatePair(home: to, other: from == to ? shownTarget(source: source) : from) ?? self
    }

    /// From set to `from`; picking the target's own language swaps the two.
    public func picking(from: String, source: String?) -> TranslatePair {
        let shown = shownTarget(source: source)
        let to = shown != from ? shown : source.flatMap { $0 != from ? $0 : nil } ?? (home == from ? other : home)
        return TranslatePair(home: to, other: from) ?? self
    }

    /// The swap button: From and To change places.
    public func swapped(source: String?) -> TranslatePair {
        TranslatePair(home: source ?? other, other: shownTarget(source: source)) ?? self
    }
}

/// The From and To lists of Translate's line (P40): Auto first in From; the languages on this Mac, then the ones Language
/// & Region downloads, each by name with its code; the one shown checked.
public enum TranslateLanguages {
    public static let onMac = "On this Mac", download = "Download in Language & Region"

    /// `installed`: the languages a translation into or out of the other side already has on this Mac.
    public static func menu(from: Bool, shown: String?, installed: Set<String>) -> ChipMenu {
        let auto = from ? [ChipMenu.Row(value: "", title: "Auto-detect", checked: shown == nil, ruleAfter: true)] : []
        let rows = TranslatePair.languages.map { code in
            ChipMenu.Row(value: code, title: Translate.name(code), detail: code, section: installed.contains(code) ? onMac : download,
                         checked: code == shown)
        }
        return ChipMenu(from ? .translateFrom : .translateTo, rows: auto + rows.filter { $0.section == onMac } + rows.filter { $0.section == download },
                        filters: true)
    }
}

/// Translate (card agent-bo-95422773; Vicinae's Translate, rebuilt): the menu's Translate branch turns what Sven types
/// into his language, or text already in it into his second one (TranslatePair), on the Mac itself, and Return copies.
public enum Translate {
    /// The source is what NaturalLanguage detects, which reads words run together ("gutenmorgen" is German); the pair's
    /// own language when unsure.
    /// A From picked in Translate's line (P40) is the source whatever the text reads as.
    public static func direction(for text: String, pair: TranslatePair = .standard, from: String? = nil) -> (source: String, target: String) {
        let source = from ?? {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            return recognizer.dominantLanguage?.rawValue ?? pair.home
        }()
        return (source, pair.target(for: source))
    }

    /// The branch's answer for the text: the translation, a row that downloads a missing language, or a failure; none
    /// under two characters.
    public static func rows(for text: String, pair: TranslatePair = .standard, from: String? = nil, with translator: some Translator) async -> [MenuEntry] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= MenuNavigator.minimumQuery else { return [] }
        let (source, target) = direction(for: text, pair: pair, from: from)
        let pair = "\(name(source)) → \(name(target))"
        do {
            let translated = try await translator.translate(text, from: source, to: target)
            return [MenuEntry(title: translated, target: .copy(translated), home: .translate, detail: "\(pair) · Return copies",
                              isAnswer: true)]
        } catch .notInstalled {
            return [MenuEntry(title: "Download \(pair) for translation", target: .action("system.translationLanguages"),
                              home: .translate, detail: "opens Language & Region", isAnswer: true)]
        } catch {
            return [MenuEntry(title: "Could not translate this", target: .action("system.translationLanguages"), home: .translate,
                              detail: pair, isAnswer: true)]
        }
    }

    /// What to translate for a search in a branch: all of it inside Translate; at the root (card agent-bo-95422932) the
    /// text after "tr " or "translate ", two characters or more; nothing anywhere else.
    public static func query(for search: String, in branch: MenuBranch?) -> String? {
        switch branch {
        case .translate: search
        case nil: query(for: search)
        default: nil
        }
    }

    /// The root's rule: the text after "tr " or "translate ", two characters or more; nil for anything else, which stays a
    /// search.
    public static func query(for search: String) -> String? {
        text(after: search).flatMap { $0.count >= MenuNavigator.minimumQuery ? $0 : nil }
    }

    /// The text after "tr " or "translate ", trimmed and possibly empty; nil when the search starts with neither.
    public static func text(after search: String) -> String? {
        let search = search.drop(while: \.isWhitespace)
        guard let space = search.firstIndex(of: " "), ["tr", "translate"].contains(search[..<space].lowercased()) else { return nil }
        return search[space...].trimmingCharacters(in: .whitespaces)
    }

    /// "German", or "Chinese, Simplified" for zh-Hans.
    public static func name(_ code: String) -> String { english.localizedString(forIdentifier: code) ?? code }
    private static let english = Locale(identifier: "en")
}

/// The menu's translations, one at a time with the newest text winning (card agent-bo-95422979). Apple's engine runs
/// translations one after another and a cancelled one still runs to its end, so each text typed during a translation
/// queued behind it (measured: 1932 ms behind one, 736 ms alone); here a text replaced while it waits never runs.
public actor TranslateRunner {
    private let translator: any Translator
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Bumped by each text asked for; a text whose number is no longer the latest is dropped.
    private(set) var generation = 0

    public init(translator: some Translator) { self.translator = translator }

    /// The rows for the text, or nil when a newer text replaced it or its task was cancelled.
    public func rows(for text: String, pair: TranslatePair, from: String? = nil) async -> [MenuEntry]? {
        generation += 1
        let mine = generation
        await acquire()
        defer { release() }
        guard generation == mine, !Task.isCancelled else { return nil }
        let rows = await Translate.rows(for: text, pair: pair, from: from, with: translator)
        return generation == mine ? rows : nil
    }

    /// Loads the on-device model as Translate opens: the first translation in a process took 2937 ms and the next 178
    /// to 940, whichever direction. Nothing when a translation is already running.
    public func warm() async {
        guard !busy else { return }
        await acquire()
        defer { release() }
        _ = try? await translator.translate("hola", from: "es", to: "en")
    }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
    }

    /// Hands the turn to the next waiter, which keeps busy set.
    private func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
