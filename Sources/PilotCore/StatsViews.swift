import Foundation

/// How Stats shows its readings (Sven's yes, 2026-10-10): each card with a chart as a Line, Bars, a Ring or a Number,
/// picked in the card's header and saved per card, and the page as the Overview or Compact. Each layout keeps its own
/// picks, so a pick in one never changes the other: the Overview's cards start as a Number (Sven's card layout,
/// 2026-10-12: the value, its figures and a sparkline), Compact's as a Ring or a Number.
public enum StatsCard: String, CaseIterable, Codable, Sendable {
    case cpu, memory, storage, network, temperature, fan, graphics
}

public enum StatsView: String, CaseIterable, Codable, Sendable {
    case line, bars, ring, number

    public var title: String {
        switch self {
        case .line: "Line"
        case .bars: "Bars"
        case .ring: "Ring"
        case .number: "Number"
        }
    }

    public var symbol: String {
        switch self {
        case .line: "chart.xyaxis.line"
        case .bars: "chart.bar.fill"
        case .ring: "circle.circle"
        case .number: "textformat.123"
        }
    }
}

public enum StatsDensity: String, CaseIterable, Codable, Sendable {
    /// The Overview (Sven's card layout, 2026-10-12): six cards with a sparkline each, Worth a look and Right now. It
    /// took Comfortable's place and keeps its saved word, so a saved `comfortable` and `pilot set stats.layout
    /// comfortable` both mean it.
    case comfortable
    /// Smaller cards, every one on one 1440 by 900 screen.
    case compact

    public var title: String { self == .comfortable ? "Overview" : "Compact" }
}

public struct StatsViews: Codable, Equatable, Sendable {
    public var layout = StatsDensity.comfortable
    /// Each layout's picks; a card with none shows its layout's default.
    private var picks: [StatsDensity: [StatsCard: StatsView]] = [:]
    /// 2 since the Overview took Comfortable's place (2026-10-12); a save without it is older.
    private var version = 2

    public init() {}

    private enum CodingKeys: String, CodingKey { case layout, picks, version }

    /// A save from before the Overview drops Comfortable's picks, which share its word: the Overview starts at its own
    /// look, not at the picks made for the big charts it replaced.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = try c.decode(StatsDensity.self, forKey: .layout)
        picks = try c.decode([StatsDensity: [StatsCard: StatsView]].self, forKey: .picks)
        if (try c.decodeIfPresent(Int.self, forKey: .version) ?? 1) < 2 { picks[.comfortable] = nil }
    }

    /// What `card` shows in the page's layout.
    public func view(_ card: StatsCard) -> StatsView { picks[layout]?[card] ?? Self.default(card, in: layout) }

    public mutating func set(_ view: StatsView, for card: StatsCard) { picks[layout, default: [:]][card] = view }

    /// The view every card shows in the page's layout; nil when they differ (the page's All cards shows none picked).
    public var shared: StatsView? {
        let first = view(StatsCard.allCases[0])
        return StatsCard.allCases.allSatisfy { view($0) == first } ? first : nil
    }

    /// Every card to `view` in the page's layout (Sven, 2026-10-11); each card draws all four, so none falls back.
    public mutating func setAll(_ view: StatsView) { for card in StatsCard.allCases { set(view, for: card) } }

    /// The Overview draws a number with its figures and sparkline; Compact a ring for a share of a known top, a number for
    /// a rate.
    public static func `default`(_ card: StatsCard, in layout: StatsDensity) -> StatsView {
        switch layout {
        case .comfortable: .number
        case .compact: [.storage, .network].contains(card) ? .number : .ring
        }
    }

    /// How many bars a range draws: 4 s each over 2 minutes, a minute each over the hour, an hour each today.
    public static func barCount(_ range: StatsRange) -> Int {
        switch range {
        case .twoMinutes: 30
        case .hour: 60
        case .today: 24
        }
    }

    /// Bars' samples: at most `count` bars across the range, each the average of the values whose x falls in it, nil
    /// where none did; each bar drawn at its middle.
    public static func bars(xs: [Double], values: [Double?], count: Int) -> (xs: [Double], values: [Double?]) {
        guard count > 0 else { return ([], []) }
        var sums = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        for (x, value) in zip(xs, values) {
            guard let value else { continue }
            let i = min(count - 1, max(0, Int(x * Double(count) - 1e-9)))
            sums[i] += value
            counts[i] += 1
        }
        return ((0..<count).map { (Double($0) + 0.5) / Double(count) }, (0..<count).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : nil })
    }

    /// A ring's line under it: the lowest, the average and the highest value across the range; nil when none was read.
    public static func spread(_ values: [Double?]) -> (low: Double, average: Double, high: Double)? {
        let read = values.compactMap(\.self)
        guard let low = read.min(), let high = read.max() else { return nil }
        return (low, read.reduce(0, +) / Double(read.count), high)
    }
}
