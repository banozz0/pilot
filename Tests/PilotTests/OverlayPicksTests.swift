import Foundation
@testable import PilotCore
import Testing
@testable import Pilot

/// Binds › Overlay (story 56, Sven 2026-10-10): a switch per bind for what holding Hyper shows, reached from Binds' tabs,
/// a link, the window's search and the overlay's own Edit what shows; the overlay lays out however many are picked.
@MainActor
@Suite("Overlay picks")
struct OverlayPicksTests {
    @Test("Binds has an Overlay tab, which a link and the window's search reach; Instrument and Toybox give it the frame's bar")
    func place() {
        #expect(AppPage.binds.tabs.map(\.title) == ["Keyboard", "Overlay", "Mouse", "Swap keys", "Export and import"],
                "Abilities went to Menu (C3); export and import came from General (page map, 2026-10-17)")
        #expect(AppPlace.linked(URL(string: "pilot://open?page=binds&tab=overlay")!) == AppPlace(.overlay))
        #expect(AppPlace.search("overlay").first == AppPlace(.overlay))
        #expect(AppPlace.search("cheat sheet").first == AppPlace(.overlay))
        // Named in full: inside #expect's expansion a bare `.overlay` is not read as AppSection's.
        #expect(!InstrumentFrame.pageOwnsBar(.binds, section: AppSection.overlay))
        #expect(!ToyLayout.ownsTitleRow(.binds, section: AppSection.overlay))
        #expect(OverlayPicksPage.intro(delay: HoldOverlay.delay).hasPrefix("Hold Hyper 0.4 s"), "the page says how to open the overlay")
    }

    static let item = LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {}))

    @Test("The pick is stored, observed and read back at the next launch")
    func stored() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let item = Self.item
        let settings = PilotSettings(defaults: defaults, loginItem: item)
        nonisolated(unsafe) var fired = 0
        withObservationTracking { _ = settings.overlayPicks } onChange: { fired += 1 }
        settings.overlayPicks = ["windows.close"]
        #expect(fired == 1, "Binds › Overlay's switches follow a change")
        #expect(PilotSettings(defaults: defaults, loginItem: item).overlayPicks == ["windows.close"])
    }

    @Test("Nothing changes until a switch: the default shows every bind; a switch off from it keeps every other and turns to My own pick")
    func switching() throws {
        let engine = Engine()
        let store = BindStore(defaults: engine.registry.defaults), actions = engine.bindActions
        let settings = PilotSettings(defaults: try #require(UserDefaults(suiteName: testSuite())), loginItem: Self.item)
        func shown() -> Set<String> {
            OverlayPage.shown(store: store, actions: actions, mode: settings.overlayMode, presses: [:], picks: settings.overlayPicks)
        }
        func hyper() -> Set<String> {
            Set(OverlayPage.rows(store: store, actions: actions, sublayer: .hyper, mode: settings.overlayMode, presses: [:],
                                 picks: settings.overlayPicks).map(\.id))
        }
        #expect(settings.overlayMode == .every)
        let every = shown(), all = hyper()
        #expect(all.contains("windows.close") && all.isSubset(of: every) && every.count > all.count)
        settings.showInOverlay("windows.close", false, shown: shown())
        #expect(settings.overlayMode == .pick)
        #expect(shown() == every.subtracting(["windows.close"]) && hyper() == all.subtracting(["windows.close"]))
        settings.showInOverlay("windows.close", true, shown: shown())
        #expect(shown() == every)
    }

    static func rows(_ count: Int, modules: Int) -> [BindsPage.Row] {
        (0..<count).map { BindsPage.Row(id: "a\($0)", key: "K", label: "Bind \($0)", module: "m\($0 * modules / count)", custom: false) }
    }

    @Test("The overlay grows to five columns of at most 18 lines, then cuts the rest and counts them")
    func manyFit() {
        for (count, columns) in [(6, 1), (16, 2), (30, 3), (48, 4), (60, 5)] {
            let fit = InstrumentOverlay.fit(Self.rows(count, modules: 6))
            #expect(fit.more == 0 && InstrumentOverlay.columns(fit.rows).count == columns, "\(count) binds")
            #expect(InstrumentOverlay.columns(fit.rows).allSatisfy { $0.count <= InstrumentOverlay.maxLines })
        }
        let many = Self.rows(140, modules: 12)
        let fit = InstrumentOverlay.fit(many)
        #expect(fit.more > 0 && fit.rows.count + fit.more == 140 && fit.rows == Array(many.prefix(fit.rows.count)))
        let laid = InstrumentOverlay.columns(fit.rows)
        #expect(laid.count <= InstrumentOverlay.maxColumns && laid.allSatisfy { $0.count <= InstrumentOverlay.maxLines })
        #expect(InstrumentOverlay.fit(Array(many.prefix(fit.rows.count + 1))).more == 1, "the cut is the most that fits")
    }
}
