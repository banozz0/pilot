import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Stats' Show, Layout and Range, measured without a screen (Sven, build 42: at a narrow window the names wrapped a
/// letter to a line, "Layo ut", "Ran ge"). Hosted offscreen at widths from a phone's to a wide page, the drawn size read
/// through a GeometryReader in an overlay: whole rows of controls are one, two or three rows' height; a name wrapped to a
/// second line makes it any other.
@MainActor
@Suite("Stats controls layout")
struct StatsControlsLayoutTests {
    static func drawn(_ views: StatsViewsStore, width: CGFloat) -> CGSize {
        let box = ExtensionDetailViewTests.Box()
        let controls = ExtensionDetailViewTests.measured(StatsControls(views: views, range: .constant(.twoMinutes)), box)
            .frame(width: width, alignment: .leading).pilotTheme(look: .shared)
        let (window, _) = ExtensionDetailViewTests.host(controls, CGSize(width: width, height: 400))
        defer { window.close() }
        _ = AliasesListTests.until { box.size != .zero }
        return box.size
    }

    @Test("Show, Layout and Range stay whole rows inside the width, from 300 to 1200 pt: no name wraps")
    func namesNeverWrap() {
        testApp()
        let views = StatsViewsStore(defaults: UserDefaults(suiteName: testSuite())!)
        let row = Self.drawn(views, width: 2000).height
        #expect(row > 0 && row < 40, "one row is \(row) tall")
        for width in [300, 420, 560, 640, 700, 760, 1200] as [CGFloat] {
            let size = Self.drawn(views, width: width)
            #expect(size.width <= width + 0.5, "at \(width): drawn \(size.width) wide")
            let rows = (1...3).map { CGFloat($0) * row + CGFloat($0 - 1) * 8 }
            #expect(rows.contains { abs($0 - size.height) < 1 }, "at \(width): \(size.height) tall, not 1 to 3 rows of \(row): a name wrapped")
        }
    }
}
