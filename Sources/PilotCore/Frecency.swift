import Foundation

/// The menu's frecency (story 75; SPEC.md, Frecency): the last 20 picks per entry id, each weighed by its age.
/// Kept on the Mac, never sent anywhere.
public struct Frecency: Equatable, Sendable {
    public static let kept = 20

    /// Pick times by entry id (MenuEntry.Target.key), oldest first.
    public private(set) var picks: [String: [Date]]

    public init(picks: [String: [Date]] = [:]) { self.picks = picks }

    public mutating func record(_ id: String, at date: Date) {
        picks[id] = Array((picks[id, default: []] + [date]).suffix(Self.kept))
    }

    /// Reset ranking (Cmd+K, card agent-bo-95422968): the entry ranks as if never picked.
    public mutating func forget(_ id: String) { picks[id] = nil }

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

/// The picks on disk: one JSON object of entry id to pick times.
public struct FrecencyStore: Sendable {
    /// ~/Library/Application Support/Pilot/frecency.json
    public static let standard = FrecencyStore(url: PilotFolder.support.appending(path: "frecency.json"))

    public let url: URL

    public init(url: URL) { self.url = url }

    /// No picks when nothing was picked yet. A file that does not decode throws, so no save wipes it. A retired action's
    /// picks count for the action that replaced it.
    public func load() throws -> Frecency {
        let saved: [String: [Date]] = try JSONFile(url: url).load(or: [:])
        let picks = Dictionary(saved.map { (RetiredActions.current(key: $0.key), $0.value) }) { ($0 + $1).sorted() }
        return Frecency(picks: picks.mapValues { Array($0.suffix(Frecency.kept)) })
    }

    public func save(_ frecency: Frecency) throws { try JSONFile(url: url).save(frecency.picks) }
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
