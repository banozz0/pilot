#if DEBUG
import AppKit
@testable import Clipboard
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The panels in Toybox (card agent-bo-95423182, batch 5) beside Instrument, through HUD.makePanel as Pilot shows them: the
/// tips, the rescue prompt and an extension's alert; the hold overlay's pages; the notes panel's
/// states; the clipboard panel's; then the top bar's popovers, the Pilot dropdown and the bind editor. Toybox follows the
/// theme, so each runs per theme. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter ToyboxPanelsRenders`
/// `PILOT_RENDER_STYLES=instrument,toybox` and `PILOT_RENDER_THEME=toybox,toybox-night,lagoon` (the defaults) narrow it;
/// `PILOT_RENDER_ONLY=<part>[,<part>]` keeps the parts named (hud, overlay, notes, clipboard, topbar, bind-editor).
extension SharedLook {
@MainActor
@Suite("Toybox panels renders")
struct ToyboxPanelsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static func list(_ key: String, _ fallback: String) -> [String] {
        (env[key] ?? fallback).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func wants(_ part: String) -> Bool {
        guard let only = env["PILOT_RENDER_ONLY"] else { return true }
        return only.split(separator: ",").contains { part.contains($0) }
    }

    /// One style in one theme: `dir(part)` makes that pass's folder for a part.
    struct Pass: Sendable {
        let out: URL, tag: String
        func dir(_ part: String) throws -> URL {
            let dir = out.appendingPathComponent("\(part)-\(tag)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    /// Each picked style in each picked theme, Look.shared set to it.
    static func passes(_ body: @MainActor (Pass) async throws -> Void) async throws {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        // Solid panels: the glass would show whatever sits behind the test window.
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"]))
        for style in list("PILOT_RENDER_STYLES", "instrument,toybox") {
            look.style = try #require(PilotStyle(rawValue: style))
            for theme in list("PILOT_RENDER_THEME", "toybox,toybox-night,lagoon") {
                look.themeID = theme
                try await body(Pass(out: out, tag: "\(style)-\(theme)"))
            }
        }
    }

    @Test("The HUDs, overlay, Quick AI, notes and clipboard panels render in Instrument and Toybox, every state",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func panels() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try NotesPanelRenders.seed(folder)
        let hero = try #require(try store.load().first { $0.title == "Ship the notes panel" })
        let clipStore = try InstrumentPanelsTests.clipStore()
        func render(_ view: some View, _ surface: StyleSurface, _ name: String, _ dir: URL) throws {
            try InstrumentPanelsRenders.render(view, surface, name, in: dir)
        }

        try await Self.passes { pass in
            if Self.wants("hud") {
                let hud = try pass.dir("hud")
                try render(TipView(text: "Workspace 2 saved: 3 windows"), .hud, "1-tip", hud)
                try render(TipView(text: "Converting 2 of 5 to JPG…", action: HUD.TipAction(title: "Cancel") {}), .hud, "2-tip-progress", hud)
                try render(TipView(text: "3 files converted to JPG", action: HUD.TipAction(title: "Reveal") {}), .hud, "3-tip-done", hud)
                try render(ExtensionAlertView(alert: ExtensionTimerTests.alert), .hud, "6-alert", hud)
                try render(ExtensionAlertView(alert: ExtensionTimerTests.plainAlert), .hud, "7-alert-ok", hud)
            }

            if Self.wants("overlay") {
                let overlay = try pass.dir("overlay")
                let rows = InstrumentPanelsTests.overlayRows
                try render(OverlayView(title: "Hyper", rows: rows), .overlay, "1-hyper", overlay)
                let shift = [("windows", "H", "Move left"), ("windows", "L", "Move right"), ("workspaces", "1", "Move to workspace 1"),
                             ("workspaces", "2", "Move to workspace 2")].map { BindsPage.Row(id: $0.2, key: $0.1, label: $0.2, module: $0.0, custom: false) }
                try render(OverlayView(title: "Hyper+Shift", rows: shift), .overlay, "2-shift", overlay)
                let many = (0..<20).map { BindsPage.Row(id: "\($0)", key: String(UnicodeScalar(UInt8(65 + $0))), label: "Action \($0 + 1)",
                                                       module: ["apps", "windows", "system", "media"][$0 / 5], custom: false) }
                try render(OverlayView(title: "Hyper+Ctrl", rows: many), .overlay, "3-three-columns", overlay)
                try render(OverlayView(title: "Hyper+Alt", rows: []), .overlay, "4-empty", overlay)
                try render(OverlayView(title: "Hyper", rows: [rows[5], rows[0], rows[3]]), .overlay, "5-most-used", overlay)
            }

            if Self.wants("notes") {
                let notes = try pass.dir("notes")
                for state in ["1-editing", "2-scratch", "3-list", "4-list-none", "5-trash", "6-smallest"] {
                    let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
                    model.reload()
                    model.open(state == "2-scratch" ? NoteStore.scratch : hero.id)
                    switch state {
                    case "3-list":
                        model.focusList()
                        model.queryField = "pan"
                        model.stepList(1)
                    case "4-list-none": model.focusList(); model.queryField = "zzq"
                    case "5-trash": model.askTrash()
                    default: break
                    }
                    let size = state == "6-smallest" ? NotesPanel.minSize : NotesPanel.defaultSize
                    try render(NotesPanelView(model: model).frame(width: size.width, height: size.height), .notes, state, notes)
                }
            }

            if Self.wants("clipboard") {
                let clips = try pass.dir("clipboard")
                @MainActor func clipboard(_ name: String, snippets: [Snippet] = [], _ change: (PanelModel) throws -> Void = { _ in }) throws {
                    let model = PanelModel(store: clipStore, snippets: { snippets })
                    try change(model)
                    try render(ClipboardPanelView(model: model, returnCopies: false), .clipboard, name, clips)
                }
                try clipboard("1-list")
                try clipboard("2-link") { $0.move(1) }
                try clipboard("3-colour") { $0.move(-9) }
                try clipboard("4-picks") { $0.move(1); $0.extend(1); $0.extend(1) }
                try clipboard("5-search") { $0.query = "pilot" }
                try clipboard("6-tag") { $0.move(2); $0.open(.tag); $0.type("o") }
                try clipboard("7-actions") { $0.move(1); $0.open(.actions) }
                try clipboard("8-edit") { $0.move(2); $0.open(.edit) }
                try clipboard("9-rename") { $0.move(2); $0.open(.rename) }
                try clipboard("10-delete-tag") { model in
                    model.tab = try #require(model.tabs.first { if case .tag = $0 { true } else { false } })
                    model.askDeleteTag()
                }
                try clipboard("11-empty-images") { $0.tab = .kind(.image) }
                try clipboard("12-empty-search") { $0.query = "zzq" }
                for (name, list, change) in Snippet.renderStates {
                    try clipboard(name, snippets: list) { $0.tab = .kind(.snippet); change($0) }
                }
            }
        }
    }

    @Test("The top bar's readings popover and Pilot dropdown, and Binds' bind editor, render in Instrument and Toybox",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func barAndEditor() async throws {
        // InstrumentPanelsRenders.topBar's fakes: the mockup's workspaces, Stats' readings, a focus block at 18:42.
        StatsRenders.seed(SystemSampler.shared)
        let clock = HomeRenders.Clock(), start = clock.now
        let timer = ExtensionTimer(now: { clock.now })
        timer.startFocus()
        clock.now = start.addingTimeInterval(25 * 60 - (18 * 60 + 42))
        timer.tick()
        defer { timer.stop() }
        let engine = Engine()
        let windows = try AeroWindow.parse(HomeRenders.windows)
        engine.observers.tiler.seed(focused: "2", occupied: OccupiedWorkspace.list(windows), windows: windows, perMonitor: [])
        typealias On = DropdownQuickSwitchesTests.Fake
        let switches = QuickSwitches(hyper: On(true), tiling: On(true), topBar: On(false), keepAwake: On(true), clipboard: On(true))
        let rows = [SystemStats.Row(name: "User", value: "9 %", explanation: "", topic: .cpu), SystemStats.Row(name: "System", value: "4 %", explanation: "", topic: .cpu),
                    SystemStats.Row(name: "Used", value: "11.2 GB", explanation: "", topic: .ram)]
        let sampler = SystemSampler.shared
        // The bind editor's binds: Toybox Binds' seeded engine, a free Hyper key and Terminal's, taken.
        let editorEngine = try ToyboxBindsRenders().engine()
        let store = editorEngine.binds.store
        let free = try #require("tujkbnmyhgiopqwerasdfzxcvl".map { Key(String($0)) }.first { store.action(for: $0) == nil })
        let taken = try #require(store.trigger(for: "apps.terminal"))
        let ghostty = "apps.open:com.mitchellh.ghostty"
        let apps = AppsModule.installedApps()

        try await Self.passes { pass in
            let look = Look.shared
            let canvas = Color(StyleTokens.of(look.style, theme: look.theme).colors.canvas)
            if Self.wants("topbar") {
                let bar = try pass.dir("topbar")
                let views: [(String, AnyView)] = [
                    ("1-readings", AnyView(StatPopover(stats: [.cpu, .ram], rows: rows, busiest: [:], values: sampler.latestValues, latest: sampler.latest,
                                                       history: sampler.history) {})),
                    ("2-dropdown", AnyView(PilotDropdown(switches: switches, option: false).environment(engine))),
                    ("3-dropdown-option", AnyView(PilotDropdown(switches: switches, option: true).environment(engine))),
                ]
                for (name, view) in views {
                    try writeRender(view.styled(.topBar, look: look).pilotTheme(look: look).padding(24).background(canvas),
                                    to: bar.appendingPathComponent("\(name).png"), wait: 0.5)
                }
                // Onboarding's Extras downloading (Q543): the dropdown's card, and Pilot's menu-bar item with its meter on a
                // light and a dark menu bar.
                typealias Download = ExtrasDownloads.Download
                ExtrasDownloads.shared.seeded = [Download(title: "Whisper large-v3 turbo", megabytes: 632, state: .downloading(0.42)),
                                             Download(title: "Read aloud voices", megabytes: 133, state: .ready),
                                             Download(title: "Upscaler, Max quality", megabytes: 67, state: .downloading(0))]
                defer { ExtrasDownloads.shared.seeded = nil }
                try writeRender(PilotDropdown(switches: switches, option: false).environment(engine).styled(.topBar, look: look)
                    .pilotTheme(look: look).padding(24).background(canvas), to: bar.appendingPathComponent("4-dropdown-downloads.png"), wait: 0.5)
                let entry = try #require(BarSettings.defaults.entries.first { $0.kind == .pilot })
                var inputs = BarInputs()
                inputs.pilotTitle = "2"
                inputs.pilotDownload = ExtrasDownloads.shared.share
                let parts = try #require(BarParts.parts(entry, inputs))
                let image = try #require(StatusItemImage.image([parts]))
                let item = { (dark: Bool) in
                    Image(nsImage: image).renderingMode(.template).foregroundStyle(dark ? Color.white : .black)
                        .padding(.horizontal, 12).frame(height: 24).background(Color(white: dark ? 0.16 : 0.92))
                }
                try writeRender(HStack(spacing: 0) { item(false); item(true) }.padding(8), to: bar.appendingPathComponent("5-menu-bar-item.png"))
            }
            if Self.wants("bind-editor") {
                // Editor A (spec bind-editor T6), as BindEditorRenders draws Instrument's: the kinds on a free key, Ghostty
                // picked, and Ghostty over a taken key (Replace); Suggest with AI asking, its card and no bind (ai-binds T3).
                let binds = try pass.dir("bind-editor")
                let actions = editorEngine.bindActions
                @MainActor func finder(_ query: String = "", picked: String? = nil, ai: BindFinder.AI? = nil) -> BindFinder {
                    let finder = BindFinder(query: query, picked: picked, ai: ai)
                    finder.load(apps: apps, actions: actions)
                    return finder
                }
                let asking = finder("go to youtube in chrome", ai: BindEditorTests.slow)
                asking.ask("go to youtube in chrome") { _ in }
                let card = finder(picked: BindEditorTests.youtube)
                card.suggested = true
                let noBind = finder("make coffee", ai: BindEditorTests.ai(#"{"id": null, "reason": "A key cannot make coffee"}"#))
                noBind.ask("make coffee") { _ in }
                await BindEditorTests.settle { noBind.asking?.running == false }
                for (name, editor) in [("a1-kinds", BindEditor(action: nil, actions: actions, startKey: free, finder: finder())),
                                       ("a3-picked", BindEditor(action: nil, actions: actions, startKey: free, finder: finder(picked: ghostty))),
                                       ("a5-replace", BindEditor(action: nil, actions: actions, startKey: taken, finder: finder(picked: ghostty))),
                                       ("a12-ai-asking", BindEditor(action: nil, actions: actions, startKey: free, finder: asking)),
                                       ("a13-ai-card", BindEditor(action: nil, actions: actions, startKey: free, finder: card)),
                                       ("a14-ai-nobind", BindEditor(action: nil, actions: actions, startKey: free, finder: noBind))] {
                    let rep = try BindEditorRenders.drawn(editor.environment(editorEngine).styled(.page(.binds), look: look).pilotTheme(look: look))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: binds.appendingPathComponent("\(name).png"))
                    let points = CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
                    #expect(points.width <= 560 && points.height <= 600, "\(name) is \(Int(points.width))×\(Int(points.height))")
                }
            }
        }
    }
}
}
#endif
