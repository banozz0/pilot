import Foundation

/// A day's exchange rates against one base currency, codes in lower case (card agent-bo-95423047).
public struct Rates: Codable, Equatable, Sendable {
    /// The day the rates are for, yyyy-MM-dd as the source writes it.
    public var date: String
    public var base: String
    public var rates: [String: Double]

    public init(date: String, base: String, rates: [String: Double]) {
        self.date = date; self.base = base; self.rates = rates
    }

    /// fawazahmed0's currency-api (CC0 data, no key): {"date": "2026-10-07", "eur": {"usd": 1.1, …}}.
    public static func parse(_ data: Data, base: String = "eur") -> Rates? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let date = json["date"] as? String,
              let table = json[base] as? [String: Any] else { return nil }
        let rates = table.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return rates.isEmpty ? nil : Rates(date: date, base: base, rates: rates)
    }
}

/// The rates the calculator answers with, when Pilot fetched them, and whether the last fetch failed.
public struct RateState: Equatable, Sendable {
    public var rates: Rates
    public var fetched: Date
    public var offline: Bool
    public init(rates: Rates, fetched: Date, offline: Bool) { self.rates = rates; self.fetched = fetched; self.offline = offline }
}

/// The rates cache, `~/Library/Application Support/Pilot/rates.json`: read once, fetched again when the menu opens and
/// the last fetch is 12 hours old, from the source then its fallback, one fetch at a time; a failed fetch keeps the old
/// rates and marks them offline.
public actor RatesStore {
    public static let sources = [
        URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/eur.min.json")!,
        URL(string: "https://latest.currency-api.pages.dev/v1/currencies/eur.min.json")!,
    ]
    public static let standard = RatesStore(file: PilotFolder.support.appending(path: "rates.json")) { url in
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await URLSession.shared.data(for: request).0
    }

    private struct Cache: Codable {
        var fetched: Date
        var rates: Rates
    }

    private let file: URL
    private let fetch: @Sendable (URL) async throws -> Data
    private var cache: Cache?
    private var offline = false
    private var fetching = false

    public init(file: URL, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.file = file
        self.fetch = fetch
        cache = try? JSONFile(url: file).load(or: nil)
    }

    public var state: RateState? { cache.map { RateState(rates: $0.rates, fetched: $0.fetched, offline: offline) } }

    /// Fetches when there are no rates or the last fetch is 12 hours old; nothing while a fetch runs. The rates after it.
    @discardableResult
    public func refresh(now: Date = .now) async -> RateState? {
        guard !fetching, cache.map({ now.timeIntervalSince($0.fetched) >= 12 * 3600 }) ?? true else { return state }
        fetching = true
        defer { fetching = false }
        for source in Self.sources {
            guard let data = try? await fetch(source), let rates = Rates.parse(data) else { continue }
            let fresh = Cache(fetched: now, rates: rates)
            cache = fresh
            offline = false
            try? JSONFile(url: file).save(fresh)
            return state
        }
        offline = true
        return state
    }
}
