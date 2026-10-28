import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// C8: Tiling's Always float apps are a switch per app, by bundle id; names from before move to their app's id once, and a
/// name no app answers to stays as a row of its own.
@MainActor
@Suite("Tiling float apps")
struct TilingFloatAppsTests {
    static let apps = [(name: "Finder", bundle: "com.apple.finder"), (name: "Ghostty", bundle: "com.mitchellh.ghostty"),
                       (name: "Zen", bundle: "app.zen-browser.zen")]
    static let block = PilotBlock(floatAppIds: ["app.zen-browser.zen", "com.example.gone"], floatApps: ["Old Name"])

    @Test("Floated apps first, then by name: an id this Mac lacks and a name from before C8 are rows too")
    func rows() {
        let rows = FloatApps.rows(apps: Self.apps, block: Self.block, query: "", first: FloatApps.floated(Self.block))
        #expect(rows.map(\.name) == ["Gone", "Old Name", "Zen", "Finder", "Ghostty"])
        #expect(rows.map(\.floats) == [true, true, true, false, false])
        #expect(rows[1].bundle == nil && rows[0].bundle == "com.example.gone")
    }

    @Test("Search matches the name or the bundle id, case ignored")
    func search() {
        let first = FloatApps.floated(Self.block)
        #expect(FloatApps.rows(apps: Self.apps, block: Self.block, query: "GH", first: first).map(\.name) == ["Ghostty"])
        #expect(FloatApps.rows(apps: Self.apps, block: Self.block, query: "zen-browser", first: first).map(\.name) == ["Zen"])
        #expect(FloatApps.rows(apps: Self.apps, block: Self.block, query: "nothing like it", first: first).isEmpty)
    }

    @Test("A switch writes the app's bundle id, or for a name from before C8 drops that name")
    func set() {
        var block = Self.block
        let rows = FloatApps.rows(apps: Self.apps, block: block, query: "", first: [])
        let row = { (name: String) in rows.first { $0.name == name }! }
        FloatApps.set(row("Ghostty"), on: true, in: &block)
        FloatApps.set(row("Zen"), on: false, in: &block)
        FloatApps.set(row("Old Name"), on: false, in: &block)
        #expect(block.floatAppIds == ["com.example.gone", "com.mitchellh.ghostty"])
        #expect(block.floatApps.isEmpty)
        // The order holds while switches change: only a new list or search puts the floated first again.
        #expect(FloatApps.rows(apps: Self.apps, block: block, query: "", first: []).map(\.name) == ["Finder", "Ghostty", "Gone", "Zen"])
    }

    @Test("Saved float names move to bundle ids at the first launch and are saved; a name no app answers to is kept, never looked up again")
    func migratesAtLaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        defaults.set(try JSONEncoder().encode(PilotBlock(floatApps: ["Finder", "Code", "Gone App"])), forKey: "pilotBlock")
        let store = PilotBlockStore(tiler: EngineObservers().tiler, defaults: defaults) { names in
            ["Finder": "com.apple.finder", "Code": "com.microsoft.VSCode"].filter { names.contains($0.key) }
        }
        #expect(store.block.floatAppIds == ["com.apple.finder", "com.microsoft.VSCode"])
        #expect(store.block.floatApps == ["Gone App"])
        let saved = try JSONDecoder().decode(PilotBlock.self, from: try #require(defaults.data(forKey: "pilotBlock")))
        #expect(saved == store.block)
        _ = PilotBlockStore(tiler: EngineObservers().tiler, defaults: defaults) { names in
            Issue.record("looked up \(names) again"); return [:]
        }
    }
}

#if DEBUG
/// The Tiling page in Instrument and Toybox (C8), opt-in like the other renders, on fixed apps so the list is the same on any Mac:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter TilingFloatAppsRenders`
extension SharedLook {
@MainActor
@Suite("Tiling float apps renders")
struct TilingFloatAppsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Tiling renders in each style with the float switches, floated first",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's files")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("tiling-float-apps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        var seeded = PilotBlock(floatAppIds: ["com.apple.finder", "com.apple.systempreferences"], floatApps: ["Old Helper"],
                                floatTitles: ["Preferences", "Settings"], gaps: .init(inner: 10, outer: 14))
        seeded.rules = []
        defaults.set(try JSONEncoder().encode(seeded), forKey: "pilotBlock")
        let tiler = EngineObservers().tiler
        let block = PilotBlockStore(tiler: tiler, defaults: defaults) { _ in [:] }
        let settings = PilotSettings(defaults: defaults, loginItem: SwipeWorkspacesTests.item)
        let apps = [(name: "Finder", bundle: "com.apple.finder"), (name: "System Settings", bundle: "com.apple.systempreferences"),
                    (name: "Calculator", bundle: "com.apple.calculator"), (name: "Notes", bundle: "com.apple.Notes"),
                    (name: "Safari", bundle: "com.apple.Safari"), (name: "Terminal", bundle: "com.apple.Terminal")]

        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "lagoon"
        for style in PilotStyle.allCases {
            look.style = style
            let page = MonitorsGround { TilingBody(block: block, settings: settings, apps: apps) }
                .styled(.page(.workspaces)).frame(width: 1000, height: 2500).pilotTheme(look: look)
            try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("tiling-\(style.rawValue).png"))
        }
    }
}
}
#endif
