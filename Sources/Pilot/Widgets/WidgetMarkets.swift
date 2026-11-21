import Foundation
import Observation
import OSLog
import PilotCore

private let marketsLog = Logger(subsystem: "dev.banozz.pilot", category: "widgets")

/// The Markets widget's data (`"data": {"markets": "symbols"}`, Sven Q726/Q729, spec P83): the symbols Edit widget picked
/// (TradingView listings, any coin, stock, fund, currency pair or index), priced by the installed Markets extension's
/// hidden `widget` command, free and keyless, which Pilot runs as the extension (ExtensionRun) and draws itself. Nothing
/// runs while no placement shows. While one does, one run every 60 s prices the symbols every shown placement wants,
/// with each range's change, high and low; a range's line is asked when the range changes and again after 10 minutes
/// (1D) or an hour (1W, 1M, 1Y). Everything is kept in memory only. A symbol with no free history (an index, a listing
/// outside the US) draws its day from the prices read here while it showed, its longer ranges without a line.
@MainActor
enum WidgetMarkets {
    nonisolated static let extensionID = "markets", command = "widget"
    /// Its settings: the symbols (a list of keys) and the range a chart opens on.
    static let symbolsName = "symbols", rangeName = "range"
    /// The most symbols a placement shows, as the extension asks at most.
    static let most = 12
    static let every: Duration = .seconds(60)
    /// A price younger than this is not asked again: a placement shown within the minute shows the last one.
    static let fresh: Duration = .seconds(55)

    /// A range key, and how long its line stays fresh.
    enum Range: String, CaseIterable, Sendable {
        case day = "1D", week = "1W", month = "1M", year = "1Y"
        var fresh: Duration { self == .day ? .seconds(600) : .seconds(3600) }
    }

    /// A symbol as the extension keys it: `kind:EXCHANGE:SYMBOL`, kind `stock` (a stock or a fund) or `pair` (the rest).
    struct Symbol: Hashable, Sendable {
        let key: String, kind: String, listing: String, symbol: String, exchange: String

        init?(_ key: String) {
            let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, ["stock", "pair"].contains(parts[0]), !parts[1].isEmpty, !parts[2].isEmpty, key.count <= 48,
                  key.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
            (self.key, kind, exchange, symbol, listing) = (key, parts[0], parts[1], parts[2], "\(parts[1]):\(parts[2])")
        }

        var context: JSONValue { .object(["kind": .string(kind), "symbol": .string(symbol), "listing": .string(listing)]) }

        /// Its TradingView page, `https://www.tradingview.com/symbols/BITSTAMP-BTCUSD/`: what a click on it opens.
        var page: URL? {
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~!"))
            guard let exchange = exchange.addingPercentEncoding(withAllowedCharacters: safe),
                  let symbol = symbol.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
            return URL(string: "https://www.tradingview.com/symbols/\(exchange)-\(symbol)/")
        }
    }

    /// One symbol's price as the extension read it: the day's, and each longer range's change, high and low.
    struct Quote: Equatable, Sendable {
        struct Span: Equatable, Sendable { var percent, high, low: Double? }
        var name: String, price: Double, change: Double?, percent: Double?, high: Double?, low: Double?
        var currency: String?, asset: String, type: String
        var spans: [Range: Span] = [:]

        /// The change over `range` in percent and in money, the high and the low: the day's own, else the span's, its
        /// money worked out from the percent.
        func moved(_ range: Range) -> (percent: Double?, change: Double?, high: Double?, low: Double?) {
            guard range != .day, let span = spans[range] else { return (percent, change, high, low) }
            let change = span.percent.map { price - price / (1 + $0 / 100) }
            return (span.percent, change, span.high, span.low)
        }

        /// The day's close before: the price less the day's change.
        var previous: Double? { change.map { price - $0 } }
    }

    // MARK: Kept in memory

    private static var quotes: [String: Quote] = [:]
    private static var errors: [String: String] = [:]
    private static var pricedAt: [String: ContinuousClock.Instant] = [:]
    /// Each symbol's line by range, and when it was read.
    private static var lines: [String: (at: ContinuousClock.Instant, points: [Double])] = [:]
    /// Each symbol's prices read here today, one a run: the day's line for a symbol with no free history.
    private static var samples: [String: [(at: Date, price: Double)]] = [:]
    /// Why nothing reads: no Markets extension, an older one, a failed run.
    private static var problem: String?
    /// The symbols each shown placement wants: one run prices them all.
    private static var wanted: [String: [Symbol]] = [:]
    private static var pricing: Task<Void, Never>?
    /// The extension found, read again after 5 minutes (an install or update on the Extensions page).
    private static var found: (at: ContinuousClock.Instant, ext: Extension?)?

    static func key(_ key: String, _ range: Range) -> String { "\(key) \(range.rawValue)" }

    /// The symbols a setting keeps, in order, once each, at most `most`: a list of keys, or keys in one text.
    static func symbols(_ value: JSONValue?) -> [Symbol] {
        let keys: [String] = switch value {
        case .array(let list)?: list.compactMap(\.string)
        case .string(let text)?: text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        default: []
        }
        var seen: Set<String> = []
        return Array(keys.compactMap(Symbol.init).filter { seen.insert($0.key).inserted }.prefix(most))
    }

    // MARK: The feed

    /// A placement's feed while it shows: its board on the tile, priced now (or from the last run if under a minute old)
    /// and every 60 s, its range's lines when they are due; a range key pressed asks that range's lines at once.
    static func feed(_ model: WidgetTileModel, values: [String: JSONValue], symbols name: String, placement id: String,
                     answered: (String?) -> Void) async {
        let board = MarketsBoard(symbols: symbols(values[name]), range: values[rangeName]?.string.flatMap(Range.init) ?? .day)
        board.picked = { board in Task { await draw(board) } }
        model.markets = board
        wanted[id] = board.symbols
        defer { wanted[id] = nil }
        while !Task.isCancelled {
            await draw(board)
            answered(board.message)
            try? await Task.sleep(for: wait(board.symbols))
        }
    }

    /// Prices the board's symbols (shared with every placement), then asks its range's lines that are due, and fills it.
    static func draw(_ board: MarketsBoard) async {
        guard !board.symbols.isEmpty else { return fill(board) }
        let range = board.range
        let due = board.symbols.filter { lines[key($0.key, range)].map { ContinuousClock.now - $0.at >= range.fresh } ?? true }
        if !due.isEmpty {
            await ask(board.symbols, range: range, lines: due)
        } else if board.symbols.contains(where: { pricedAt[$0.key].map { ContinuousClock.now - $0 >= fresh } ?? true }) {
            await price()
        }
        fill(board)
    }

    /// How long a feed sleeps: until its oldest price is a minute old.
    static func wait(_ symbols: [Symbol]) -> Duration {
        let oldest = symbols.compactMap { pricedAt[$0.key] }.min()
        guard let oldest else { return every }
        return max(every - (ContinuousClock.now - oldest), .seconds(1))
    }

    /// One run for every symbol any shown placement wants, shared with a run under way.
    private static func price() async {
        if let pricing { return await pricing.value }
        var seen: Set<String> = []
        let all = wanted.values.flatMap { $0 }.filter { seen.insert($0.key).inserted }
        let task = Task { await ask(all, range: .day, lines: []) }
        pricing = task
        await task.value
        pricing = nil
    }

    /// The board's figures from what is kept: each symbol's quote, its line over the board's range (the prices read
    /// today for a day with none), and why nothing reads.
    static func fill(_ board: MarketsBoard) {
        var drawn: [String: [Double]] = [:]
        board.loaded = Set(board.symbols.map(\.key).filter { lines[key($0, board.range)] != nil })
        for symbol in board.symbols {
            if let line = lines[key(symbol.key, board.range)]?.points, line.count > 1 { drawn[symbol.key] = line }
            else if board.range == .day, let read = samples[symbol.key], read.count > 1 { drawn[symbol.key] = read.map(\.price) }
        }
        board.quotes = board.symbols.reduce(into: [:]) { $0[$1.key] = quotes[$1.key] }
        board.errors = board.symbols.reduce(into: [:]) { $0[$1.key] = errors[$1.key] }
        board.lines = drawn
        board.message = board.symbols.isEmpty ? "No symbols yet: right-click it › Edit widget to add some."
            : board.quotes.isEmpty ? problem ?? board.symbols.compactMap({ errors[$0.key] }).first : nil
    }

    // MARK: The extension

    /// The Markets extension installed, looked up again after 5 minutes.
    private static func markets() async -> Extension? {
        if let found, ContinuousClock.now - found.at < .seconds(300) { return found.ext }
        let ext = await Task.detached(priority: .utility) { Extension.find().extensions.first { $0.id == extensionID } }.value
        found = (.now, ext)
        return ext
    }

    /// Runs the extension's `widget` command with `context` and reads its one data line; nil with `problem` set when it
    /// is missing, too old, or its run failed.
    private static func run(_ context: JSONValue) async -> [String: JSONValue]? {
        guard let ext = await markets() else {
            problem = "Install Markets on the Extensions page: this widget reads its prices."
            return nil
        }
        guard let command = ext.commands.first(where: { $0.name == command }) else {
            problem = "Update Markets on the Extensions page: this widget needs Markets 1.4."
            return nil
        }
        var said: String?
        guard let inputs = await ExtensionsModule.inputs(for: ext, storage: ExtensionStorage(), hud: { said = $0 }) else {
            problem = said ?? "Markets did not start"
            return nil
        }
        do {
            let output = try await ExtensionRun.output(command, context: context, inputs: inputs, timeout: .seconds(25))
            for line in output.split(separator: "\n") {
                guard case .object(let message)? = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                if message["type"] == .string("error") { problem = "Markets: \(message["text"]?.string ?? "it failed")"; return nil }
                if message["type"] == .string("data"), case .object(let data)? = message["data"] { problem = nil; return data }
            }
            problem = "Markets sent no prices"
        } catch is CancellationError {
            return nil
        } catch {
            problem = "Markets did not answer in time"
            marketsLog.error("markets widget: run failed: \(String(describing: error), privacy: .private)")
        }
        return nil
    }

    /// One run: `symbols`' prices, and their lines over `range` for `lines`; kept with when they were read.
    private static func ask(_ symbols: [Symbol], range: Range, lines asked: [Symbol]) async {
        guard !symbols.isEmpty else { return }
        let context: JSONValue = .object(["symbols": .array(symbols.map(\.context)), "range": .string(range.rawValue),
                                          "lines": .array(asked.map { .string($0.key) })])
        guard let data = await run(context) else { return }
        let now = ContinuousClock.now, today = Date()
        let read: [String: JSONValue] = if case .object(let q)? = data["quotes"] { q } else { [:] }
        for (key, value) in read {
            guard let quote = Self.quote(value) else { continue }
            (quotes[key], pricedAt[key], errors[key]) = (quote, now, nil)
            // One price a run, today's only.
            var kept = (samples[key] ?? []).filter { Calendar.current.isDate($0.at, inSameDayAs: today) }
            if kept.last.map({ today.timeIntervalSince($0.at) >= 50 }) ?? true { kept.append((today, quote.price)) }
            samples[key] = Array(kept.suffix(1440))
        }
        // Why a symbol has no price; a priced one's missing line is no error of its price.
        if case .object(let failed)? = data["errors"] {
            for (key, why) in failed where read[key] == nil { errors[key] = why.string }
        }
        let drawn: [String: JSONValue] = if case .object(let l)? = data["lines"] { l } else { [:] }
        for symbol in asked {
            // A symbol with no free history is not asked again until its line is due.
            let points: [Double] = if case .array(let list)? = drawn[symbol.key] {
                list.compactMap { if case .array(let p) = $0, p.count == 2, case .number(let v) = p[1] { v } else { nil } }
            } else { [] }
            lines[key(symbol.key, range)] = (now, points)
        }
    }

    static func quote(_ value: JSONValue) -> Quote? {
        guard case .object(let q) = value, let price = q["price"]?.number else { return nil }
        var made = Quote(name: q["name"]?.string ?? "", price: price, change: q["change"]?.number, percent: q["percent"]?.number,
                         high: q["high"]?.number, low: q["low"]?.number, currency: q["currency"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                         asset: q["asset"]?.string ?? "other", type: q["type"]?.string ?? "")
        if case .object(let spans)? = q["ranges"] {
            for range in Range.allCases {
                guard case .object(let s)? = spans[range.rawValue] else { continue }
                made.spans[range] = .init(percent: s["percent"]?.number, high: s["high"]?.number, low: s["low"]?.number)
            }
        }
        return made
    }

    // MARK: Search and preview

    /// A listing TradingView's search found, as Edit widget lists it.
    struct Found: Hashable, Sendable { let key: String, symbol: String, name: String, group: String }

    /// TradingView's listings for `text` through the extension (`crypto sol`, `fx eur` narrow it); or why not.
    static func search(_ text: String) async -> Result<[Found], SearchProblem> {
        guard let data = await run(.object(["search": .string(text)])) else { return .failure(SearchProblem(text: problem ?? "Markets did not answer")) }
        guard case .array(let list)? = data["found"] else { return .success([]) }
        return .success(list.compactMap { value in
            guard case .object(let f) = value, let key = f["key"]?.string, let symbol = Symbol(key) else { return nil }
            let kind = Self.kinds[f["type"]?.string ?? ""] ?? (symbol.kind == "stock" ? "Stock" : "Pair")
            return Found(key: key, symbol: symbol.symbol, name: f["name"]?.string ?? "", group: [kind, f["where"]?.string ?? symbol.exchange].joined(separator: " · "))
        })
    }

    struct SearchProblem: Error { let text: String }

    /// TradingView's types in words.
    nonisolated static let kinds = ["stock": "Stock", "dr": "Stock", "fund": "Fund", "spot": "Crypto", "crypto": "Crypto", "forex": "FX",
                        "index": "Index", "futures": "Futures", "bond": "Bond", "economic": "Economy"]

    /// The Widgets page's look at it: the default symbols with what is kept from a placement shown before, never a run.
    static func preview(_ model: WidgetTileModel, values: [String: JSONValue]) {
        let board = MarketsBoard(symbols: symbols(values[symbolsName]), range: values[rangeName]?.string.flatMap(Range.init) ?? .day)
        fill(board)
        board.message = nil
        model.markets = board
    }
}

/// One placement's Markets: its symbols, the range its chart shows (a key's press changes it for as long as it shows),
/// and the figures WidgetMarkets.fill gives it.
@Observable @MainActor
final class MarketsBoard {
    let symbols: [WidgetMarkets.Symbol]
    var range: WidgetMarkets.Range
    var quotes: [String: WidgetMarkets.Quote] = [:]
    var errors: [String: String] = [:]
    var lines: [String: [Double]] = [:]
    /// The symbols whose line over the range was asked: one asked with none has no free history; one not yet is loading.
    var loaded: Set<String> = []
    var message: String?
    /// A range key pressed: the feed asks its lines.
    @ObservationIgnored var picked: (MarketsBoard) -> Void = { _ in }

    init(symbols: [WidgetMarkets.Symbol], range: WidgetMarkets.Range) { self.symbols = symbols; self.range = range }

    func pick(_ range: WidgetMarkets.Range) {
        guard range != self.range else { return }
        self.range = range
        WidgetMarkets.fill(self)
        picked(self)
    }
}

private extension JSONValue {
    var number: Double? { if case .number(let n) = self { n } else { nil } }
}
