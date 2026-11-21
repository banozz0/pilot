import Foundation

/// The menu's frecency (story 75; SPEC.md, Frecency): the last 20 picks per entry id, each weighed by its age, and the
/// short queries each was picked from (learned abbreviations, spec launcher-best T7). Kept on the Mac, never sent anywhere.
public struct Frecency: Equatable, Sendable {
    public static let kept = 20

    /// A pick made with a short query typed: what was typed, folded (`Typed.folded`), and when.
    public struct Typed: Codable, Equatable, Sendable {
        public var query: String, at: Date

        public init(query: String, at: Date) { self.query = query; self.at = at }

        /// The longest query learned: what LaunchBar and Alfred train is an abbreviation, not a phrase.
        public static let letters = 4

        /// The query as learned and looked up: trimmed, case and accents ignored; nil when it is empty, holds a space or
        /// runs past four characters.
        public static func folded(_ query: String) -> String? {
            let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return q.isEmpty || q.count > letters || q.contains(" ") ? nil : q
        }
    }

    /// The picks a query must earn before it lists its row first.
    public static let learnedAfter = 2

    /// Pick times by entry id (MenuEntry.Target.key), oldest first.
    public private(set) var picks: [String: [Date]]
    /// The short queries each entry id was picked from, oldest first, the last 20 per id as with `picks`.
    public private(set) var typed: [String: [Typed]]

    public init(picks: [String: [Date]] = [:], typed: [String: [Typed]] = [:]) { self.picks = picks; self.typed = typed }

    /// A pick of `id` at `date`; with `query`, the query too when it is short enough to learn (`Typed.folded`).
    public mutating func record(_ id: String, at date: Date, query: String? = nil) {
        picks[id] = Array((picks[id, default: []] + [date]).suffix(Self.kept))
        guard let q = query.flatMap(Typed.folded) else { return }
        typed[id] = Array((typed[id, default: []] + [Typed(query: q, at: date)]).suffix(Self.kept))
    }

    /// Reset ranking (Cmd+K, card agent-bo-95422968): the entry ranks as if never picked, its learned queries gone too.
    public mutating func forget(_ id: String) {
        picks[id] = nil
        typed[id] = nil
    }

    /// The entry id `query` lists first once learned (T7): of the ids picked from that exact query at least twice, the
    /// one whose second-last such pick is the latest, so a row reassigns the query only after two picks of its own, not
    /// on one stray pick (LaunchBar's training); nil when none was. A hand alias outranks it (MenuNavigator.aliasFirst).
    public func learned(_ query: String) -> String? {
        guard let q = Typed.folded(query) else { return nil }
        return typed.compactMap { id, picks -> (id: String, earned: Date, last: Date)? in
            let times = picks.filter { $0.query == q }.map(\.at)
            guard times.count >= Self.learnedAfter else { return nil }
            return (id, times[times.count - Self.learnedAfter], times[times.count - 1])
        }.max { ($0.earned, $0.last, $1.id) < ($1.earned, $1.last, $0.id) }?.id
    }

    /// A pick's weight by age in days, oldest band last; older than 90 days weighs 10.
    private static let weights: [(days: Double, weight: Int)] = [(4, 100), (14, 70), (31, 50), (90, 30)]

    /// The sum of each pick's weight: 100 at 4 days old or less, 70 at 14, 50 at 31, 30 at 90, 10 when older.
    public func score(_ id: String, now: Date) -> Int {
        (picks[id] ?? []).reduce(0) { sum, date in
            let days = now.timeIntervalSince(date) / 86_400
            return sum + (Self.weights.first { days <= $0.days }?.weight ?? 10)
        }
    }

    /// Each id's score over the best one's, 0 to 1; empty when none of them was picked.
    public func boosts(for ids: [String], now: Date) -> [String: Double] {
        let scores = ids.map { ($0, score($0, now: now)) }
        guard let best = scores.map(\.1).max(), best > 0 else { return [:] }
        return Dictionary(scores.map { ($0, Double($1) / Double(best)) }, uniquingKeysWith: max)
    }
}

/// The picks on disk: one JSON object of entry id to pick times, and beside it `frecency.typed.json`, entry id to the
/// short queries picked from (T7), so a Pilot from before reads its own file as it always did.
public struct FrecencyStore: Sendable {
    /// ~/Library/Application Support/Pilot/frecency.json
    public static let standard = FrecencyStore(url: PilotFolder.support.appending(path: "frecency.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// The learned queries' file, beside the picks'.
    public var typedURL: URL { url.deletingPathExtension().appendingPathExtension("typed.json") }

    /// No picks when nothing was picked yet. A file that does not decode throws, so no save wipes it. A retired action's
    /// picks count for the action that replaced it.
    public func load() throws -> Frecency {
        func current<T>(_ saved: [String: [T]], by date: (T) -> Date) -> [String: [T]] {
            Dictionary(saved.map { (RetiredActions.current(key: $0.key), $0.value) }) { ($0 + $1).sorted { date($0) < date($1) } }
                .mapValues { Array($0.suffix(Frecency.kept)) }
        }
        let picks: [String: [Date]] = try JSONFile(url: url).load(or: [:])
        let typed: [String: [Frecency.Typed]] = try JSONFile(url: typedURL).load(or: [:])
        return Frecency(picks: current(picks) { $0 }, typed: current(typed, by: \.at))
    }

    public func save(_ frecency: Frecency) throws {
        try JSONFile(url: url).save(frecency.picks)
        try JSONFile(url: typedURL).save(frecency.typed.filter { !$0.value.isEmpty })
    }
}

/// The menu's favourites on disk (Cmd+K, card agent-bo-95422968): a JSON list of entry ids, kept on the Mac.
public struct FavouritesStore: Sendable {
    /// ~/Library/Application Support/Pilot/favourites.json
    public static let standard = FavouritesStore(url: PilotFolder.support.appending(path: "favourites.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// None before the first favourite. A file that does not decode throws, so no save wipes it.
    public func load() throws -> Set<String> { Set(try JSONFile(url: url).load(or: [String]()).map { RetiredActions.current(key: $0) }) }

    public func save(_ favourites: Set<String>) throws { try JSONFile(url: url).save(favourites.sorted()) }
}
