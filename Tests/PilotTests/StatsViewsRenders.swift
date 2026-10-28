#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Stats' views (Sven's yes, 2026-10-10): the store keeps each card's view and the layout across a relaunch, every run;
/// and, opt-in like the other renders, the Overview at 1440 by 900, 1000 by 900 and whole, then Compact with every card as each
/// view, in Instrument and Toybox, seeded as StatsRenders does:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter StatsViewsRenders`
extension SharedLook {
@MainActor
@Suite("Stats views renders")
struct StatsViewsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("A card's view and the page's layout are read back by a new store on the same defaults")
    func persists() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        let store = StatsViewsStore(defaults: defaults)
        #expect(store.views == StatsViews())
        store.set(.bars, for: .cpu)
        store.setLayout(.compact)
        store.set(.line, for: .network)
        let relaunched = StatsViewsStore(defaults: defaults)
        #expect(relaunched.views == store.views)
        #expect(relaunched.views.layout == .compact && relaunched.views.view(.network) == .line && relaunched.views.view(.cpu) == .ring)
        relaunched.setLayout(.comfortable)
        #expect(StatsViewsStore(defaults: defaults).views.view(.cpu) == .bars)
        defaults.set(Data("not json".utf8), forKey: StatsViewsStore.key)
        #expect(StatsViewsStore(defaults: defaults).views == StatsViews(), "a file that no longer reads falls back to the defaults")
        let all = StatsViewsStore(defaults: defaults)
        all.setAll(.number)
        #expect(StatsViewsStore(defaults: defaults).views.shared == .number, "Show's pick is saved like a card's")
    }

    @Test("Stats renders every view and both layouts in both styles", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("stats-views")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        SharedLook.StatsRenders.pickMockup(BarItemsStore.shared)
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains { name.contains($0) } } ?? true }

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared, views = StatsViewsStore.shared
        look.themeID = Self.env["PILOT_RENDER_THEME"] ?? "lagoon"
        defer {
            look.themeID = PilotTheme.defaultID; look.style = .instrument
            views.reset()
        }

        /// Every card as `view` (nil: the layout's defaults), CPU as Bars when `mixed`, then each of `picks`, the window at
        /// `width` by `height`; `header` keeps the page's top 230 pt, where Show, Layout and Range sit.
        func shot(_ name: String, style: PilotStyle, density: StatsDensity, view: StatsView?, mixed: Bool = false,
                  picks: [StatsCard: StatsView] = [:], header: Bool = false, width: CGFloat = 1440, height: CGFloat = 900) throws {
            guard wanted(name) else { return }
            look.style = style
            views.reset()
            views.setLayout(density)
            if let view { views.setAll(view) }
            if mixed { views.set(.bars, for: .cpu) }
            for (card, view) in picks { views.set(view, for: card) }
            window.setContentSize(NSSize(width: width, height: height))
            model.go(AppPlace(.stats))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            var rep = try #require(snapshot(frame, scale: 2))
            if header { rep = NSBitmapImageRep(cgImage: try #require(rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: 460)))) }
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        for style in PilotStyle.allCases {
            let name = style.rawValue
            // The Overview (Sven's card layout, 2026-10-12): one look, at 1440 and at 1000 wide.
            try shot("\(name)-overview-1440", style: style, density: .comfortable, view: nil)
            try shot("\(name)-overview-1000", style: style, density: .comfortable, view: nil, width: 1000)
            // The whole page, Worth a look and Right now under the fold at 900.
            try shot("\(name)-overview-full", style: style, density: .comfortable, view: nil, height: 1500)
            for view in StatsView.allCases { try shot("\(name)-compact-\(view.rawValue)", style: style, density: .compact, view: view) }
            // A MacBook's seven (Battery beside Temperature), CPU as a Line, Memory a Ring, Graphics Bars, the rest Number
            // (Sven, 2026-10-12, forms Q23 and Q24).
            if wanted("\(name)-overview-battery-picks") {
                SharedLook.StatsRenders.seed(SystemSampler.shared, battery: true)
                try shot("\(name)-overview-battery-picks", style: style, density: .comfortable, view: nil,
                         picks: [.cpu: .line, .memory: .ring, .graphics: .bars])
                SharedLook.StatsRenders.seed(SystemSampler.shared)
            }
            try shot("\(name)-compact", style: style, density: .compact, view: nil)
        }
        // Show over every card (Sven, 2026-10-11), in Compact, where the cards take a view: one view picked, then none
        // while CPU differs.
        for (name, style) in [("instrument", PilotStyle.instrument), ("toybox", .toybox)] {
            try shot("header-\(name)-ring", style: style, density: .compact, view: .ring, header: true)
            try shot("header-\(name)-mixed", style: style, density: .compact, view: .ring, mixed: true, header: true)
        }
    }
}
}
#endif
