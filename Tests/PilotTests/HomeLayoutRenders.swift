#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Story 167 on Home's grid (P91, model A): Home with extension blocks (HomeLayoutRenders.now, direction 2's lanes converted
/// to cells) in the whole window at 1440 and 1000 by 900 and at 760, in Instrument and Toybox, the rail and toolbar tabs
/// layouts; the default Home, and every block kept Strip, Square, Wide and Large at 1440; Sven's Home from 1.0.2 converted
/// and his goal (a big keyboard, This Mac, Weather and AI usage small on the right) at his 1640 × 1250 and at 1000 × 660;
/// then edit mode (spec home-edit, check 14): edit mode, a corner held mid-resize, the tray of hidden blocks, a block
/// carried over new cells (its outline and size readout where it lands), Reduce Motion and the keyboard's moves, at
/// 760×520, 1000×660, 1440×900 and 1720×1440, in Instrument dark and light and Toybox, and his goal in edit mode; each again
/// in the film's look (`film-`, P89; PILOT_RENDER_ONLY=film draws only those), with made-up clipboard rows and the film's
/// top bar time. Seeded as
/// HomeRenders seeds, with fake extension pages (lazygit, AI usage, Weather, Pomodoro, Now playing); nothing reaches the
/// tiler, the clipboard or an extension.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter HomeLayoutRenders`
extension SharedLook {
@MainActor
@Suite("Home layout renders")
struct HomeLayoutRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The two styles, and the film's look (Instrument in ExplainerFilmRenders.theme) for the 1.0.3 film's Home (P89).
    static let styles: [(String, PilotStyle, String)] = [("instrument", .instrument, "nightwatch"), ("toybox", .toybox, "toybox"),
                                                         ("film", .instrument, ExplainerFilmRenders.theme)]

    /// The extension blocks the sizes are drawn with, each with its emoji, its bar item's text and its page.
    static let fakes: [(id: String, title: String, icon: String, bar: String, blocks: [Extension.Block])] = [
        ("lazygit", "lazygit", "🌿", "4 ✎", [
            .stats([.init(label: "Changed", value: "4", tone: .warn), .init(label: "To push", value: "0"), .init(label: "To pull", value: "1"),
                    .init(label: "Clean", value: "24", tone: .fine)]),
            .list(title: "~/code · fetched just now", items: [
                Extension.Item(title: "pilot", subtitle: "main · 1 changed · last commit 2 h", icon: "✏️", actions: []),
                Extension.Item(title: "oss/Ghostex", subtitle: "main · 3 changed · 37 behind", icon: "✏️", actions: []),
                Extension.Item(title: "_references/zed", subtitle: "1a246ef (detached) · 1 changed", icon: "✏️", actions: []),
                Extension.Item(title: "_references/gpui-component", subtitle: "bc174a7 (detached) · 3 changed", icon: "✏️", actions: []),
                Extension.Item(title: "24 clean repos", icon: "🌿", actions: []),
            ]),
            .buttons([Extension.Item.Action(kind: .run(command: "fetch", context: nil), title: "Fetch all")]),
        ]),
        ("ai-usage", "AI usage", "📊", "52%", ExtensionSurfaceRenders.blocks),
        ("weather", "Weather", "⛅️", "17°", [
            .stats([.init(label: "Now", value: "17°"), .init(label: "Feels like", value: "15°"), .init(label: "Rain", value: "10%")]),
            .list(title: "Valletta, next days", items: ["Sat ☀️ 21° / 14°", "Sun ⛅️ 19° / 13°", "Mon 🌧 16° / 12°", "Tue ☀️ 22° / 15°"].map {
                Extension.Item(title: $0, actions: [])
            }),
            .markdown("Data from Open-Meteo, asked every 30 minutes."),
        ]),
        ("now-playing", "Now playing", "🎵", "5:07", [
            .stats([.init(label: "Playing", value: "5:07")]),
            .list(title: "Up next", items: ["The Cranberries — Zombie", "Portishead — Roads", "Massive Attack — Teardrop"].map {
                Extension.Item(title: $0, actions: [])
            }),
        ]),
        ("pomodoro", "Pomodoro", "🍅", "18:42", [
            .meter(.init(label: "Focus", percent: 25, note: "round 2 of 4, break at 15:20", value: "18:42 left")),
            .buttons([Extension.Item.Action(kind: .run(command: "pause", context: nil), title: "Pause"),
                      Extension.Item.Action(kind: .run(command: "skip", context: nil), title: "Skip")]),
        ]),
    ]

    /// Direction 2's lanes with extension blocks in every one, converted to cells as a 1.0.2 layout is: Pomodoro a Strip,
    /// lazygit a card down the left under the default's lists, AI usage and Weather side by side between the keyboard and
    /// This Mac.
    static var now: HomeLayout {
        let order: [(String, HomeLayout.Size)] = [("workspaces", .small), ("ext:pomodoro", .icon), ("keyboard", .large), ("clipboard", .small),
                                                  ("mostUsed", .small), ("ext:lazygit", .small), ("ext:ai-usage", .medium), ("ext:weather", .medium),
                                                  ("thisMac", .large)]
        return HomeLayout(lanes: HomeLayout(rows: order.map { HomeLayout.Row(id: $0.0, shown: true, size: $0.1) }, grid: nil))
    }

    /// `now` with every block's Layout kept at `layout`.
    static func kept(_ layout: Widget.SizeClass) -> HomeLayout {
        var home = now
        for row in home.rows where row.shown { home.set(row.id, layout: layout) }
        return home
    }

    /// `layout` as the film shows it (P89): the greeting hidden, since it says this Mac's user's first name, which a public
    /// video must not.
    static func filmed(_ layout: HomeLayout) -> HomeLayout {
        var layout = layout
        layout.set("greeting", shown: false)
        return layout
    }

    /// Whether the renders draw the film's Home (P89): its clipboard rows are `filmClips` and its page bar reads the film's
    /// top bar time (ClockRenders.now), so Home and the bar beside it agree.
    static var filming = false

    /// AI usage as the film's Home shows it: ExtensionSurfaceRenders' blocks with their times read off the film's top bar
    /// (Wed 7 Oct, 21:04), so the 5 h window resets 2 h 18 min after the bar's clock says.
    static let filmAIUsage: [Extension.Block] = ExtensionSurfaceRenders.blocks.map { block in
        switch block {
        case .meter(let m) where m.note?.hasPrefix("resets today") == true:
            .meter(.init(label: m.label, percent: m.percent, note: "resets today 23:22 (in 2 h 18 min)", tone: m.tone))
        case .list(let title, let items, let reorder):
            .list(title: title, items: items.map { item in
                guard item.subtitle?.contains("resets") == true else { return item }
                return Extension.Item(title: item.title, subtitle: "1.2M tokens since 18:22 · resets 23:22", icon: item.icon, actions: item.actions)
            }, reorder: reorder)
        default: block
        }
    }

    /// The film's clipboard rows: made-up copies from the film's own story, nothing of this Mac's or Pilot's work.
    static let filmClips: [StoredClip] = [
        (ClipKind.text, "Lunch at the market at 1?", "com.apple.MobileSMS", 20.0),
        (.link, "https://en.wikipedia.org/wiki/Tiling_window_manager", "com.apple.Safari", 125),
        (.image, "", "com.apple.screencaptureui", 540), (.colour, "#2BC4F0", "com.apple.Notes", 840),
        (.text, "Book the 9:40 train to Sintra.", "com.apple.Notes", 1860),
        (.text, "12 Rua das Flores, 1200-195 Lisbon", "com.apple.mail", 3700),
        (.file, "/Users/ana/Documents/Lisbon weekend/plan.md", "com.apple.finder", 7300),
        (.text, "Ask Ana if she wants to come.", "com.apple.Notes", 10_900),
    ].enumerated().map { i, c in
        var clip = StoredClip(id: Int64(i + 1), kind: c.0, text: c.1, sourceApp: c.2, copiedAt: Date().addingTimeInterval(-c.3), pinned: false)
        if c.0 == .image { clip.customTitle = "Screenshot 21.02.11" }
        return clip
    }

    /// Sven's Home from 1.0.2, converted, and his goal.
    static var svens: HomeLayout { HomeLayout(lanes: try! JSONDecoder().decode(HomeLayout.self, from: Data(HomeLayoutTests.svensLanes.utf8))) }

    /// Where Home starts as the window shows it: edit mode or not.
    @Observable @MainActor
    final class Starting {
        var start: HomePage.Start?
        /// Reduce Motion on, as System Settings › Accessibility › Display sets it.
        var reduce = false
    }

    struct Host: View {
        let model: AppWindowModel
        let starting: Starting
        let watch: HomeEditWatch

        var body: some View {
            AppWindowView(model: model).environment(\.homeStart, starting.start).environment(\.homeEditWatch, watch)
                .transformEnvironment(\._accessibilityReduceMotion) { if starting.reduce { $0 = true } }
        }
    }

    @Test("Direction 2 in every style, layout and width, the size classes, and edit mode at the four window sizes", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("home-layout")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        try HomeRenders.seedPresets()
        let engine = try HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)

        // The extensions' pages, each answered by a fake.
        let dir = try ExtensionSurfaceTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exts = dir.appending(path: "Extensions")
        var models: [String: ExtensionPageModel] = [:]
        for fake in Self.fakes {
            try ExtensionSurfaceTests.write(fake.id, title: fake.title, in: exts)
            let blocks = fake.blocks
            models[fake.id] = ExtensionPageModel(id: fake.id, folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { _, _ in
                let film = fake.id == "ai-usage" ? await MainActor.run { Self.filming ? Self.filmAIUsage : nil } : nil
                return .blocks(film ?? blocks)
            })
            await models[fake.id]?.refresh()
        }

        let store = HomeLayoutStore(defaults: try #require(UserDefaults(suiteName: testSuite())))
        var sources = HomeSources()
        sources.lastCopied = {
            Self.filming ? HomeCopy(text: "Lunch at the market at 1?", at: Date().addingTimeInterval(-20), count: 48)
                         : HomeCopy(text: "bd show agent-bo-95422987", at: Date().addingTimeInterval(-125), count: 48)
        }
        sources.recentCopies = { Self.filming ? Self.filmClips : InstrumentRenders.clips }
        sources.now = { Self.filming ? ClockRenders.now : $0 }
        defer { Self.filming = false }
        sources.pages = { Self.fakes.map { ExtensionPages.Link(id: $0.id, title: $0.title, icon: $0.icon) } }
        let pages = models
        /// The film's Home on or off; AI usage asks its fake again so its blocks follow.
        func film(_ on: Bool) async {
            guard Self.filming != on else { return }
            Self.filming = on
            await pages["ai-usage"]?.refresh()
        }
        sources.page = { pages[$0] ?? ExtensionPageModel(id: $0) }
        sources.barText = { id in Self.fakes.first { $0.id == id }?.bar }
        sources.layout = { store }

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let starting = Starting(), watch = HomeEditWatch()
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: Host(model: model, starting: starting, watch: watch)
            .environment(engine).environment(\.homeSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        // The converted lanes at 900 pt tall, in both window layouts, at 760 drawn tall enough to show all of it. Then the
        // default alone, every block kept in each class, and Sven's Home before and after at his window and the default one.
        let saved2 = look.windowShape
        defer { look.windowShape = saved2 }
        var states: [(name: String, layout: HomeLayout, shape: WindowShape, width: CGFloat, height: CGFloat)] = []
        for shape in WindowShape.allCases {
            for width: CGFloat in [1440, 1000, 760] { states.append(("now-\(shape.rawValue)-\(Int(width))", Self.now, shape, width, width == 760 ? 1400 : 900)) }
        }
        states.append(("default-rail-1440", .standard, .rail, 1440, 900))
        for layout in Widget.SizeClass.allCases { states.append(("layout-\(layout.rawValue)-rail-1440", Self.kept(layout), .rail, 1440, 1100)) }
        for (width, height) in [(1640, 1250), (1000, 660)] {
            states.append(("svens-before-rail-\(width)", Self.svens, .rail, CGFloat(width), CGFloat(height)))
            states.append(("svens-goal-rail-\(width)", HomeLayoutTests.svensGoal, .rail, CGFloat(width), CGFloat(height)))
        }
        for state in states {
            if state.layout == .standard { store.reset() } else { store.save(state.layout) }
            look.windowShape = state.shape
            for (name, style, theme) in Self.styles where wanted("\(name)-\(state.name)") {
                await film(name == "film")
                if Self.filming { store.save(Self.filmed(state.layout)) }
                (look.themeID, look.style) = (theme, style)
                AppWindowController.applyLook(look, to: window)
                window.setContentSize(NSSize(width: state.width, height: state.height))
                model.go(AppPlace(.home))
                PanelTestSupport.pump(0.9)
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name)-\(state.name).png"))
            }
        }

        // Edit mode at the four window sizes (Sven, Q57) in Instrument dark and light and Toybox: Home as above with nothing
        // hidden but Pilot's own; the keyboard's corner held mid-resize, four columns in and three rows down; the default
        // Home, whose tray holds the extension pages; Most used carried to the right of the board; Reduce Motion; the
        // keyboard's ring on Clipboard, and Clipboard moved a row up by its arrow. Then Sven's goal in edit mode at his window
        // and the default one, each block's class checked against P91's frames 4 and 5.
        let themes: [(String, PilotStyle, String)] = [("instrument-dark", .instrument, "tokyo-night"), ("instrument-light", .instrument, "porcelain"),
                                                      ("toybox", .toybox, "toybox"), ("film", .instrument, ExplainerFilmRenders.theme)]
        let fourSizes = [(760, 520), (1000, 660), (1440, 900), (1720, 1440)], svensSizes = [(1000, 660), (1640, 1250)]
        let edits: [(name: String, layout: HomeLayout, sizes: [(Int, Int)])] = [
            ("edit", Self.now, fourSizes), ("resize", Self.now, fourSizes), ("tray", .standard, fourSizes), ("carry", Self.now, fourSizes),
            ("reduce", Self.now, fourSizes), ("keys", Self.now, fourSizes), ("keymove", Self.now, fourSizes),
            ("svens-goal", HomeLayoutTests.svensGoal, svensSizes),
        ]
        look.windowShape = .rail
        for edit in edits {
            if edit.layout == .standard { store.reset() } else { store.save(edit.layout) }
            for (name, style, theme) in themes {
                for (width, height) in edit.sizes where wanted("edit-\(name)-\(edit.name)-\(width)") {
                    await film(name == "film")
                    if Self.filming { store.save(Self.filmed(edit.layout)) }
                    (look.themeID, look.style) = (theme, style)
                    AppWindowController.applyLook(look, to: window)
                    window.setContentSize(NSSize(width: width, height: height))
                    starting.reduce = edit.name == "reduce"
                    // Home again, so it starts in edit mode.
                    starting.start = nil
                    model.go(AppPlace(.binds))
                    PanelTestSupport.pump(0.2)
                    starting.start = .init(editing: true)
                    model.go(AppPlace(.home))
                    PanelTestSupport.pump(0.9)
                    let mode = try #require(watch.mode, "not in edit mode"), frames = try #require(mode.frames)
                    let origin = try #require(frames.origin), grid = try #require(frames.rects[.grid])
                    let step = CGSize(width: HomeGrid.cellWidth(grid.width) + HomeGrid.gap, height: HomeGrid.pitch)
                    func global(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + origin.x, y: point.y + origin.y) }
                    switch edit.name {
                    case "resize":
                        // The keyboard's bottom right corner, held: it draws 14 × 9, the blocks under it moved down.
                        let rect = try #require(frames.frame(of: "keyboard")), corner = global(CGPoint(x: rect.maxX - 4, y: rect.maxY - 4))
                        mode.resize("keyboard", edges: [.bottom, .right], from: corner, to: CGPoint(x: corner.x - 4 * step.width, y: corner.y + 3 * step.height))
                        PanelTestSupport.pump(0.6)
                        #expect(mode.session.target.map { ($0.w, $0.h) } ?? (0, 0) == (14, 9), "\(name) \(width): \(String(describing: mode.session.target))")
                    case "carry":
                        // Most used, picked up at its middle and held over the board's right, rested on.
                        let rect = try #require(frames.frame(of: "mostUsed")), start = global(CGPoint(x: rect.midX, y: rect.midY))
                        mode.drag(from: start, to: CGPoint(x: start.x + 6, y: start.y))
                        let to = HomeGrid.rect(HomeCell(x: 18, y: 2, w: 1, h: 1), inner: grid.width)
                        mode.drag(from: start, to: global(CGPoint(x: grid.minX + to.minX + rect.width / 2, y: grid.minY + to.minY + rect.height / 2)))
                        let rested = Date.now + 1
                        while mode.session.target == nil, Date.now < rested { PanelTestSupport.pump(0.05) }
                        PanelTestSupport.pump(0.6)
                        #expect(mode.session.target != nil, "\(name) \(width): nothing under the carried block")
                    case "keys", "keymove":
                        // The keyboard: Tab to the first block, Tab on to Clipboard; an arrow takes it a row up.
                        let blocks = mode.session.drawn(mode.session.draft)
                        mode.focus = nil
                        _ = mode.press(.tab, blocks: blocks)
                        while mode.focus != "clipboard", mode.press(.tab, blocks: blocks) {}
                        #expect(mode.focus == "clipboard", "\(name) \(width): the keyboard is on \(String(describing: mode.focus))")
                        if edit.name == "keymove" {
                            let before = try #require(mode.session.cells(mode.session.draft)["clipboard"])
                            _ = mode.press(.move(dx: 0, dy: -1), blocks: blocks)
                            #expect((mode.session.cells(mode.session.draft)["clipboard"]?.y ?? .max) < before.y, "\(name) \(width): Clipboard did not move up")
                        }
                        PanelTestSupport.pump(0.9)
                    case "svens-goal":
                        // P91 frame 4 at his window: This Mac and Weather Wide, AI usage and the keyboard Large; frame 5 at the
                        // default window: all four Square but the keyboard.
                        let classes = Dictionary(uniqueKeysWithValues: frames.cells.map { ($0.key, HomeGrid.sizeClass($0.value, inner: grid.width, pin: nil)) })
                        let want: [String: Widget.SizeClass] = width >= 1640
                            ? ["keyboard": .large, "thisMac": .wide, "ext:weather": .wide, "ext:ai-usage": .large, "workspaces": .wide]
                            : ["keyboard": .large, "thisMac": .square, "ext:weather": .square, "ext:ai-usage": .square, "workspaces": .square]
                        for (id, kind) in want { #expect(classes[id] == kind, "\(name) \(width): \(id) draws \(String(describing: classes[id])), grid \(grid.width) pt") }
                        print("svens-goal \(name) \(width)×\(height): grid \(Int(grid.width)) pt, cells \(String(format: "%.1f", HomeGrid.cellWidth(grid.width))) pt, "
                              + want.keys.sorted().map { "\($0) \(frames.cells[$0]!) \(classes[$0]!.title)" }.joined(separator: ", "))
                    default: break
                    }
                    if edit.name == "reduce" { #expect(watch.mode?.reduceMotion == true, "\(name) \(width): Reduce Motion did not reach edit mode") }
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("edit-\(name)-\(edit.name)-\(width).png"))
                    // Let go, so the next state starts with nothing held.
                    watch.mode?.putBack()
                    watch.mode?.session.putBack()
                }
            }
        }
    }
}
}
#endif
