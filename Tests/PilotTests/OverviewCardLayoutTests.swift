import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Overview's cards, measured without a screen (Sven, build 42: Temperature overlapped Network in every view). The
/// grid hands each card its column's width and places the next one a spacing further on, so a card drawn wider than its
/// column runs under its neighbour. Each card is hosted offscreen at a column's width, its drawn size read through a
/// GeometryReader in an overlay.
@MainActor
@Suite("Overview card layout")
struct OverviewCardLayoutTests {
    /// The narrowest column the grid gives (its `minimum`), the 760 pt window's, then wider ones.
    static let columns: [CGFloat] = [230, 246, 300, 420]

    /// Network at its widest: four figures, the addresses whole, the upload beside a three-digit rate.
    static func network(_ store: BarItemsStore) -> OverviewCard {
        let values: [Double?] = (0..<60).map { Double($0 % 7) * 1000 }
        let line = ChartLine(name: "↓ Down", values: values, colour: .blue)
        let trace = OverviewCard.Trace(xs: values.indices.map(Double.init), lines: [line, ChartLine(name: "↑ Up", values: values, colour: .blue, dashed: true)],
                                       spark: line, sparkTop: 8000, top: 8000, topLabel: "8 KB/s", axis: ["2 min", "1 min", "now"], span: 120,
                                       bars: 30, label: "Download and upload", share: 0.4, of: "Down", format: { "\(Int($0)) B/s" })
        return OverviewCard(kind: .network, card: .network, colour: .third, store: store, caption: "Downloading · Wi-Fi", value: "937",
                            unit: "KB/s", aside: "↑ 1.1 MB/s",
                            figures: [StatsFact("Today", "188.3 GB"), StatsFact("Signal", "−67 dBm"), StatsFact("Address", "192.168.100.240"),
                                      StatsFact("Public IP", "213.217.238.100")],
                            trace: trace)
    }

    /// Memory at its widest: a four-digit value beside its pressure badge, three figures.
    static func memory(_ store: BarItemsStore) -> OverviewCard {
        let card = network(store)
        return OverviewCard(kind: .memory, card: .memory, colour: .second, store: store, caption: "In use of 128.0 GB", value: "127.9", unit: "GB",
                            badge: .init(text: "Critical · 100 %", tone: .problem),
                            figures: [StatsFact("App", "100.8 GB"), StatsFact("Wired", "12.5 GB"), StatsFact("Compressed", "13.0 GB")], trace: card.trace)
    }

    @Test("Every view draws a card no wider than its column, from the narrowest to a wide one")
    func cardsStayInTheirColumn() throws {
        testApp()
        let store = BarItemsStore(defaults: UserDefaults(suiteName: testSuite())!) { [:] }
        let views = StatsViewsStore(defaults: UserDefaults(suiteName: testSuite())!)
        for view in StatsView.allCases {
            views.setAll(view)
            for column in Self.columns {
              for make in [Self.network, Self.memory] {
                let box = ExtensionDetailViewTests.Box()
                let card = ExtensionDetailViewTests.measured(make(store), box)
                    .frame(width: column).environment(\.statsViews, views).pilotTheme(look: .shared)
                let (window, _) = ExtensionDetailViewTests.host(card, CGSize(width: 900, height: 500))
                defer { window.close() }
                _ = AliasesListTests.until { box.size != .zero }
                #expect(box.size.width > 0, "\(view) at \(column): drew nothing")
                #expect(box.size.width <= column + 0.5, "\(view) at \(column): drawn \(box.size.width) wide, past its column")
              }
            }
        }
    }
}
