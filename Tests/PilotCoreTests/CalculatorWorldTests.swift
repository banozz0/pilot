import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423047: currency, time zones and dates answered at the menu's root; stub rates, a fixed clock and
/// zone, never the network.
@Suite("Calculator: money, zones, dates")
struct CalculatorWorldTests {
    static let malta = TimeZone(identifier: "Europe/Malta")!
    /// Thursday 8 October 2026, 12:00 in Malta.
    static let now = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!
    static let rates = Rates(date: "2026-10-07", base: "eur", rates: ["eur": 1, "usd": 1.1, "cop": 4500, "gbp": 0.85])

    static func row(_ text: String, rates: RateState? = RateState(rates: Self.rates, fetched: now, offline: false), now: Date = now) -> MenuEntry? {
        RootAnswers.entries(for: text, now: now, zone: malta, rates: rates).first
    }

    @Test("Money: a code, a symbol or a name on either side, any amount the calculator reads")
    func money() {
        #expect(Self.row("40 eur in usd")?.title == "44 USD")
        #expect(Self.row("€40 in usd")?.title == "44 USD")
        #expect(Self.row("40 € to usd")?.title == "44 USD")
        #expect(Self.row("40eur in dollars")?.title == "44 USD")
        #expect(Self.row("$11 in eur")?.title == "10 EUR")
        #expect(Self.row("100 usd to cop")?.title == "409090.9091 COP")
        #expect(Self.row("2*20 EUR in GBP")?.title == "34 GBP")
        let row = Self.row("40 eur in usd")
        #expect(row?.target == .copy("44 USD") && row?.isAnswer == true)
        #expect(row?.detail?.contains("rates from 2026-10-07") == true)
        #expect(row?.detail?.contains("offline") == false)
    }

    @Test("Offline means the last fetch failed or is over a day old, never the rates' own date; no rates, no unknown code, no row")
    func offline() {
        // The source runs a day behind: rates dated 2026-10-07, fetched now, read fresh a day later.
        #expect(Self.row("40 eur in usd", now: Self.now.addingTimeInterval(86_399))?.detail?.contains("offline") == false)
        let late = RateState(rates: Self.rates, fetched: Self.now.addingTimeInterval(-25 * 3600), offline: false)
        #expect(Self.row("40 eur in usd", rates: late)?.detail?.contains("offline, rates from 2026-10-07") == true)
        #expect(Self.row("40 eur in usd", rates: RateState(rates: Self.rates, fetched: Self.now, offline: true))?.detail?
            .contains("offline, rates from 2026-10-07") == true)
        #expect(Self.row("40 eur in usd", rates: nil) == nil)
        #expect(Self.row("40 eur in xyz") == nil)
        #expect(Self.row("40 abc in usd") == nil)
    }

    @Test("Time zones: a time in one place in another, a time here in another, the time in a place now")
    func zones() {
        let london = Self.row("5pm london in malta")
        #expect(london?.title == "18:00")
        #expect(london?.detail?.contains("London") == true && london?.detail?.contains("Malta") == true)
        let bogota = Self.row("17:30 bogotá in malta")
        #expect(bogota?.title == "00:30")
        #expect(bogota?.detail?.contains("next day") == true)
        #expect(Self.row("17:30 bogota in malta")?.title == "00:30")
        #expect(Self.row("time in tokyo")?.title == "19:00")
        #expect(Self.row("noon in new york")?.title == "06:00")
        #expect(Self.row("9am to london")?.title == "08:00")
        #expect(Self.row("5pm narnia in malta") == nil)
        #expect(Self.row("time in narnia") == nil)
    }

    @Test("Dates: a day plus or minus days, weeks, months or years; days until or since a day")
    func dates() {
        #expect(Self.row("today + 30 days")?.title == "Sat 7 Nov 2026")
        #expect(Self.row("today - 2 weeks")?.title == "Thu 24 Sep 2026")
        #expect(Self.row("in 10 days")?.title == "Sun 18 Oct 2026")
        #expect(Self.row("3 weeks ago")?.title == "Thu 17 Sep 2026")
        #expect(Self.row("tomorrow + 1 month")?.title == "Mon 9 Nov 2026")
        #expect(Self.row("2026-12-25 - 1 year")?.title == "Thu 25 Dec 2025")
        #expect(Self.row("days until 2026-12-25")?.title == "78 days")
        #expect(Self.row("days since 2026-01-01")?.title == "280 days")
        #expect(Self.row("days until 2026-10-09")?.title == "1 day")
        #expect(Self.row("today + 30 lemons") == nil)
        #expect(Self.row("days until soon") == nil)
    }

    @Test("What the calculator answered before still answers; a bare date, a word or a reminder gives no extra row")
    func before() {
        #expect(Self.row("12*49")?.title == "588")
        #expect(Self.row("5 km in mi")?.title == "3.106855961 mi")
        for text in ["2024-10-06", "firefox", "in", "time", "days", "5 in usd", "17 london in malta"] { #expect(Self.row(text) == nil, "\(text)") }
        #expect(Self.row("20m stretch")?.target == .reminder(.set(seconds: 1200, text: "stretch")))
    }
}

/// The rates cache: read from disk, refreshed only when stale, old rates kept when a fetch fails.
@Suite("Currency rates store")
struct RatesStoreTests {
    static let json = Data(#"{"date":"2026-10-07","eur":{"eur":1,"usd":1.1,"cop":4500}}"#.utf8)

    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("The source's JSON reads as rates; anything else does not")
    func parse() {
        #expect(Rates.parse(Self.json) == Rates(date: "2026-10-07", base: "eur", rates: ["eur": 1, "usd": 1.1, "cop": 4500]))
        #expect(Rates.parse(Data("nope".utf8)) == nil)
        #expect(Rates.parse(Data(#"{"date":"2026-10-07"}"#.utf8)) == nil)
    }

    @Test("A fetch fills the cache; a second within 12 hours fetches nothing; a failed one keeps the rates and says offline")
    func refresh() async throws {
        let file = try Self.folder().appendingPathComponent("rates.json")
        let t0 = Date(timeIntervalSince1970: 1_791_417_600)
        let fetches = Counter()
        let store = RatesStore(file: file) { _ in
            if await fetches.add() { throw URLError(.notConnectedToInternet) }
            return Self.json
        }
        #expect(await store.state == nil)
        await store.refresh(now: t0)
        #expect(await store.state == RateState(rates: Rates.parse(Self.json)!, fetched: t0, offline: false))
        await store.refresh(now: t0.addingTimeInterval(3600))
        #expect(await fetches.count == 1)
        await fetches.fail()
        await store.refresh(now: t0.addingTimeInterval(13 * 3600))
        #expect(await fetches.count == 3, "the source and its fallback")
        #expect(await store.state == RateState(rates: Rates.parse(Self.json)!, fetched: t0, offline: true))
        // A new store reads what the first one saved, without fetching.
        let again = RatesStore(file: file) { _ in throw URLError(.badURL) }
        #expect(await again.state?.rates.date == "2026-10-07")
    }

    actor Counter {
        private(set) var count = 0
        private var failing = false
        /// Counts a fetch; whether it fails.
        func add() -> Bool { count += 1; return failing }
        func fail() { failing = true }
    }
}
