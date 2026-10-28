#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Story 167 on direction 2 "Now beside the board" (Sven's pick, 2026-10-12): Home with extension blocks in every lane
/// (HomeLayoutRenders.now) in the whole window at 1440 and 1000 by 900 and at 760 (stacked, drawn whole), in Instrument and
/// Toybox, the rail and toolbar tabs layouts; the default Home, every block small and every block medium at 1440; then edit
/// mode (spec home-edit, check 14): edit mode, a size chip under the pointer, the tray of hidden blocks and a block carried
/// over a slot (its well and size label where it lands), at 760×520, 1000×660, 1440×900 and 1720×1440, in Instrument dark
/// and light and Toybox. Seeded as HomeRenders seeds, with
/// fake extension pages (lazygit, AI usage, Weather, Pomodoro); nothing reaches the tiler, the clipboard or an extension.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter HomeLayoutRenders`
extension SharedLook {
@MainActor
@Suite("Home layout renders")
struct HomeLayoutRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let styles: [(String, PilotStyle, String)] = [("instrument", .instrument, "nightwatch"), ("toybox", .toybox, "toybox")]

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
        ("pomodoro", "Pomodoro", "🍅", "18:42", [
            .meter(.init(label: "Focus", percent: 25, note: "round 2 of 4, break at 15:20", value: "18:42 left")),
            .buttons([Extension.Item.Action(kind: .run(command: "pause", context: nil), title: "Pause"),
                      Extension.Item.Action(kind: .run(command: "skip", context: nil), title: "Skip")]),
        ]),
    ]

    /// Direction 2 with extension blocks in every lane: Pomodoro an icon, lazygit a small card in the column under the
    /// default's lists, AI usage and Weather medium side by side on the board between the keyboard and This Mac.
    static var now: HomeLayout {
        var layout = HomeLayout(rows: [])
        let order: [(String, HomeLayout.Size)] = [("workspaces", .small), ("ext:pomodoro", .icon), ("keyboard", .large), ("clipboard", .small),
                                                  ("mostUsed", .small), ("ext:lazygit", .small), ("ext:ai-usage", .medium), ("ext:weather", .medium),
                                                  ("thisMac", .large)]
        for (id, size) in order {
            layout.set(id, shown: true)
            layout.set(id, size: size)
        }
        return layout
    }

    /// A Home of the fakes and Pilot's blocks, every one `size`, or the mix (lazygit and Weather icons, Pomodoro and the
    /// clipboard small, AI usage and This Mac medium, Workspaces and the keyboard large) when nil.
    static func sized(_ size: HomeLayout.Size?) -> HomeLayout {
        var layout = HomeLayout(rows: [])
        let mix: [String: HomeLayout.Size] = ["ext:lazygit": .icon, "ext:weather": .icon, "ext:pomodoro": .small, "clipboard": .small,
                                              "ext:ai-usage": .medium, "thisMac": .medium, "workspaces": .large, "keyboard": .large]
        let order = size == nil ? ["ext:lazygit", "ext:weather", "ext:pomodoro", "clipboard", "workspaces", "keyboard", "ext:ai-usage", "thisMac"]
            : ["workspaces", "ext:lazygit", "ext:ai-usage", "ext:weather", "ext:pomodoro", "keyboard", "thisMac", "clipboard"]
        for id in order {
            layout.set(id, shown: true)
            layout.set(id, size: size ?? mix[id] ?? .standard(id))
        }
        return layout
    }

    /// Where Home starts as the window shows it: edit mode, a size chip hovered.
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
            models[fake.id] = ExtensionPageModel(id: fake.id, folder: exts, storage: ExtensionSurfaceTests.storage(dir), run: { _, _ in .blocks(blocks) })
            await models[fake.id]?.refresh()
        }

        let store = HomeLayoutStore(defaults: try #require(UserDefaults(suiteName: testSuite())))
        var sources = HomeSources()
        sources.lastCopied = { HomeCopy(text: "bd show agent-bo-95422987", at: Date().addingTimeInterval(-125), count: 48) }
        sources.recentCopies = { InstrumentRenders.clips }
        sources.pages = { Self.fakes.map { ExtensionPages.Link(id: $0.id, title: $0.title, icon: $0.icon) } }
        let pages = models
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

        // Direction 2 (Sven's pick, 2026-10-12) at 900 pt tall, the height it fits whole at 1440, in both window layouts; 760
        // stacks, so it is drawn tall enough to show all of it. Then the default alone and every block small, then medium.
        let saved2 = look.windowShape
        defer { look.windowShape = saved2 }
        var states: [(name: String, layout: HomeLayout, shape: WindowShape, width: CGFloat, height: CGFloat)] = []
        for shape in WindowShape.allCases {
            for width: CGFloat in [1440, 1000, 760] { states.append(("now-\(shape.rawValue)-\(Int(width))", Self.now, shape, width, width == 760 ? 1900 : 900)) }
        }
        states += [("default-rail-1440", .standard, .rail, 1440, 900),
                   ("size-small-rail-1440", Self.sized(.small), .rail, 1440, 900), ("size-medium-rail-1440", Self.sized(.medium), .rail, 1440, 900)]
        for state in states {
            if state.layout == .standard { store.reset() } else { store.save(state.layout) }
            look.windowShape = state.shape
            for (name, style, theme) in Self.styles where wanted("\(name)-\(state.name)") {
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
        // hidden but Pilot's own; a size chip under the pointer, its new frame dashed, on a block in view (stacked, at 760 and
        // 1000, the board is below the fold: Clipboard's Icon; side by side, the keyboard's Medium); the default Home, whose
        // tray holds the four extension pages.
        let themes: [(String, PilotStyle, String)] = [("instrument-dark", .instrument, "lagoon"), ("instrument-light", .instrument, "porcelain"),
                                                      ("toybox", .toybox, "toybox")]
        // Carrying: stacked, lazygit's card held over the icon row (an icon well); side by side, Most used held between the
        // keyboard and the medium pair (a medium well on the board), the pointer near the slot's top.
        typealias Carry = (id: String, place: HomeEditSession.Place)
        let edits: [(name: String, layout: HomeLayout, hover: (Int) -> HomeEditMode.Hover?, carry: (Int) -> Carry?)] = [
            ("edit", Self.now, { _ in nil }, { _ in nil }),
            ("hover", Self.now, { $0 < 1440 ? .init(id: "clipboard", size: .icon) : .init(id: "keyboard", size: .medium) }, { _ in nil }),
            ("tray", .standard, { _ in nil }, { _ in nil }),
            ("carry", Self.now, { _ in nil }, { $0 < 1440 ? ("ext:lazygit", .icons(before: nil)) : ("mostUsed", .board(before: "ext:ai-usage")) }),
            // T6: Reduce Motion (still, dashed outlines), the keyboard's ring on Clipboard, and Clipboard carried by the
            // keyboard two slots on (to the column's end), drawn under its well.
            ("reduce", Self.now, { _ in nil }, { _ in nil }),
            ("keys", Self.now, { _ in nil }, { _ in nil }),
            ("keycarry", Self.now, { _ in nil }, { _ in nil }),
        ]
        look.windowShape = .rail
        for edit in edits {
            if edit.layout == .standard { store.reset() } else { store.save(edit.layout) }
            for (name, style, theme) in themes {
                for (width, height) in [(760, 520), (1000, 660), (1440, 900), (1720, 1440)] where wanted("edit-\(name)-\(edit.name)-\(width)") {
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
                    // The chip under the pointer, once the page has measured itself.
                    if let hover = edit.hover(width) {
                        try #require(watch.mode, "not in edit mode").hover = hover
                        PanelTestSupport.pump(0.3)
                    }
                    // Picked up at its middle and held over the slot, rested in, as the page's drag hands it (global).
                    if let carry = edit.carry(width) {
                        let mode = try #require(watch.mode, "not in edit mode"), frames = try #require(mode.frames)
                        let origin = try #require(frames.origin), rect = try #require(frames.rects[.block(carry.id)])
                        let start = CGPoint(x: rect.midX + origin.x, y: rect.midY + origin.y)
                        mode.drag(from: start, to: CGPoint(x: start.x + 6, y: start.y))
                        let area = try #require(mode.carrying?.slots.slots.first { $0.place == carry.place }?.area.first, "no slot \(carry.place)")
                        mode.drag(from: start, to: CGPoint(x: area.minX + area.width * 0.7 + origin.x, y: area.minY + min(24, area.height / 2) + origin.y))
                        // The slot counts after an 80 ms rest, then the page makes room on a 0.3 s spring.
                        let rested = Date.now + 1
                        while mode.session.target != carry.place, Date.now < rested { PanelTestSupport.pump(0.05) }
                        let settled = Date.now + 0.6
                        while Date.now < settled { PanelTestSupport.pump(0.05) }
                        #expect(mode.session.target == carry.place, "\(name) \(width): carried \(carry.id) over \(String(describing: mode.session.target))")
                    }
                    // The keyboard: Tab to the first block, the arrow on to Clipboard; Space and two arrows carry it.
                    if edit.name == "keys" || edit.name == "keycarry" {
                        let mode = try #require(watch.mode, "not in edit mode")
                        let blocks = mode.session.draft.shown(extensions: mode.session.extensions), across = mode.frames?.drawn?.shape.across ?? 2
                        mode.focus = nil
                        let keys: [HomeEditMode.Key] = edit.name == "keys" ? [.tab, .later, .later] : [.tab, .later, .later, .space, .later, .later]
                        for key in keys { _ = mode.press(key, blocks: blocks, across: across) }
                        #expect(mode.focus == "clipboard", "\(name) \(width): the keyboard is on \(String(describing: mode.focus))")
                        PanelTestSupport.pump(0.9)
                        if edit.name == "keycarry" {
                            // Carried to the column's end, the page draws it there, after lazygit: under it, or beside it stacked.
                            let rects = try #require(mode.frames).rects
                            #expect(watch.mode === mode && mode.keyCarried == "clipboard" && mode.session.target == .column(before: nil),
                                    "\(name) \(width): carrying \(String(describing: mode.keyCarried)) to \(String(describing: mode.session.target))")
                            let clip = try #require(rects[.block("clipboard")]), git = try #require(rects[.block("ext:lazygit")])
                            #expect(clip.minY > git.maxY || (abs(clip.minY - git.minY) < 2 && clip.minX > git.maxX),
                                    "\(name) \(width): Clipboard at \(String(describing: rects[.block("clipboard")])), lazygit at \(String(describing: rects[.block("ext:lazygit")]))")
                        }
                    }
                    if edit.name == "reduce" { #expect(watch.mode?.reduceMotion == true, "\(name) \(width): Reduce Motion did not reach edit mode") }
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("edit-\(name)-\(edit.name)-\(width).png"))
                    // Let go, so the next state starts with nothing carried.
                    watch.mode?.putBack()
                    watch.mode?.session.putBack()
                }
            }
        }
    }
}
}
#endif
