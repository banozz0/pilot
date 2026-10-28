import Foundation
import Testing
@testable import PilotCore

/// Stats' views (Sven's yes, 2026-10-10): Line, Bars, Ring or Number per card, saved per card, and the page Comfortable
/// or Compact, each layout keeping its own picks.
@Suite("Stats views")
struct StatsViewsTests {
    @Test("Nothing picked: the Overview draws every card as a number; Compact a ring for a share, a number for a rate")
    func defaults() {
        var views = StatsViews()
        #expect(views.layout == .comfortable)
        #expect(StatsCard.allCases.allSatisfy { views.view($0) == .number })
        views.layout = .compact
        #expect(views.view(.cpu) == .ring && views.view(.memory) == .ring && views.view(.temperature) == .ring && views.view(.fan) == .ring)
        #expect(views.view(.network) == .number && views.view(.storage) == .number)
    }

    @Test("A pick is saved for its card alone, and only in the layout it was made in")
    func perCard() {
        var views = StatsViews()
        views.set(.bars, for: .cpu)
        #expect(views.view(.cpu) == .bars)
        #expect(views.view(.memory) == .number, "another card keeps its own view")
        views.layout = .compact
        #expect(views.view(.cpu) == .ring, "Compact keeps its own default until a pick there")
        views.set(.number, for: .cpu)
        views.layout = .comfortable
        #expect(views.view(.cpu) == .bars, "Compact's pick left Comfortable's alone")
        views.layout = .compact
        #expect(views.view(.cpu) == .number)
    }

    @Test("Show sets every card in the page's layout; one card changed reads as none picked")
    func setAll() {
        var views = StatsViews()
        #expect(views.shared == .number, "the Overview's defaults all agree")
        views.layout = .compact
        #expect(views.shared == nil, "Compact's defaults mix rings and numbers")
        views.setAll(.bars)
        #expect(views.shared == .bars && StatsCard.allCases.allSatisfy { views.view($0) == .bars })
        views.set(.ring, for: .fan)
        #expect(views.shared == nil, "a card picked on its own makes the page mixed")
        #expect(views.view(.fan) == .ring && views.view(.cpu) == .bars, "the card's own pick still holds")
        views.layout = .comfortable
        #expect(views.shared == .number, "Show in Compact left the Overview alone")
    }

    @Test("The picks and the layout survive a save and a read back")
    func codable() throws {
        var views = StatsViews()
        views.set(.ring, for: .fan)
        views.layout = .compact
        views.set(.line, for: .network)
        let back = try JSONDecoder().decode(StatsViews.self, from: JSONEncoder().encode(views))
        #expect(back == views)
        #expect(back.layout == .compact && back.view(.network) == .line)
        var comfortable = back
        comfortable.layout = .comfortable
        #expect(comfortable.view(.fan) == .ring)
    }

    @Test("A save from before the Overview drops Comfortable's picks and keeps Compact's; a new save keeps both")
    func migrate() throws {
        // An old save: picks in both layouts, no version.
        var before = StatsViews()
        before.set(.ring, for: .cpu)
        before.layout = .compact
        before.set(.bars, for: .cpu)
        before.layout = .comfortable
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        #expect(json.removeValue(forKey: "version") != nil)
        var views = try JSONDecoder().decode(StatsViews.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(views.layout == .comfortable && views.view(.cpu) == .number, "the Overview starts at its own look")
        views.layout = .compact
        #expect(views.view(.cpu) == .bars)
        views.layout = .comfortable
        views.set(.line, for: .cpu)
        let again = try JSONDecoder().decode(StatsViews.self, from: JSONEncoder().encode(views))
        #expect(again.view(.cpu) == .line, "a pick made in the Overview survives the next launch")
    }

    @Test("Bars average the samples falling in each bar, nil where none did, each drawn at its middle")
    func bars() {
        // Six samples across the range, the last at now (x = 1); a gap at the second.
        let xs = [1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6, 1]
        let values: [Double?] = [0.1, nil, 0.3, 0.5, 0.2, 0.4]
        let bars = StatsViews.bars(xs: xs, values: values, count: 3)
        #expect(bars.xs == [1.0 / 6, 0.5, 5.0 / 6])
        #expect(bars.values[0] == 0.1, "the gap stays out of the average")
        #expect(abs((bars.values[1] ?? 0) - 0.4) < 1e-9)
        #expect(abs((bars.values[2] ?? 0) - 0.3) < 1e-9)
        #expect(StatsViews.bars(xs: [0.9, 1], values: [1, 2], count: 4).values == [nil, nil, nil, 1.5], "a short history fills only the right")
        #expect(StatsViews.barCount(.twoMinutes) == 30 && StatsViews.barCount(.hour) == 60 && StatsViews.barCount(.today) == 24)
    }

    @Test("A ring's lowest, average and highest leave unread samples out; none read, none shown")
    func spread() throws {
        let s = try #require(StatsViews.spread([0.2, nil, 0.6, 0.4]))
        #expect(s.low == 0.2 && s.high == 0.6 && abs(s.average - 0.4) < 1e-9)
        #expect(StatsViews.spread([nil, nil]) == nil)
    }
}
