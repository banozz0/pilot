#if DEBUG
import AppKit
@testable import Clipboard
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The HUDs (tip, window rescue, an extension's alert) and the notes panel in Instrument (card
/// agent-bo-95423181, ADR 0008): each draws Instrument, not Toybox's pixels, dark and light; through HUD.makePanel each is
/// opaque on the style's pop face, its own shadow in margins round it. The tip refits and the notes panel keeps its size and place round the face, not the window.
extension SharedLook {
@MainActor
@Suite("Instrument panels")
struct InstrumentPanelsTests {
    /// One surface's view, built fresh for each draw, and the surface it is.
    struct Case: CustomTestStringConvertible, @unchecked Sendable {
        let name: String
        let surface: StyleSurface
        let view: @MainActor () -> AnyView
        var testDescription: String { name }
    }

    /// A notes folder of the render suite's nine notes, and the model open on "Ship the notes panel".
    static func notes() -> NotesModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-instrument-notes-\(UUID().uuidString)")
        let store = try! NotesPanelRenders.seed(folder)
        let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
        model.reload()
        if let hero = model.notes.first(where: { $0.title == "Ship the notes panel" }) { model.open(hero.id) }
        return model
    }

    /// A clipboard history of four copies from three apps, the colour pinned, two tagged; in a fresh temporary file.
    static func clipStore() throws -> ClipboardStore {
        let db = FileManager.default.temporaryDirectory.appending(path: "pilot-instrument-clips-\(UUID().uuidString).sqlite")
        let store = try ClipboardStore(path: db)
        let now = Date()
        let samples: [(String, String?)] = [("open -g \"pilot://run?action=windows.close&app=Finder\"", "com.mitchellh.ghostty"),
                                            ("https://github.com/nikitabobko/AeroSpace", "com.apple.Safari"),
                                            ("Pilot makes a Mac feel as close to Omarchy as macOS allows.\nOne native app with its own tiler.", "com.apple.TextEdit"),
                                            ("#FF6B2C", nil)]
        for (i, (text, app)) in samples.enumerated() {
            let item = ClipItem(kind: text.hasPrefix("#") ? .colour : text.hasPrefix("http") ? .link : .text, text: text,
                                contents: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]], sourceApp: app)
            let id = try store.add(item, at: now.addingTimeInterval(Double(-60 * (i * i + 1))))
            if i == 3 { try store.setPinned(id, true) }
        }
        let recent = try store.recent()
        _ = try store.tag([try #require(recent.last?.id)], with: "omarchy")
        _ = try store.tag([try #require(recent.first?.id)], with: "pilot")
        return store
    }

    /// The Hyper page's binds as the overlay lists them: by module, then label.
    static let overlayRows: [BindsPage.Row] = [
        ("apps", "Return", "Open terminal"), ("apps", "B", "Open browser"), ("apps", "E", "Open editor"),
        ("engine", "Space", "Pilot menu"), ("engine", "C", "Keybindings"),
        ("windows", "W", "Close window"), ("windows", "H", "Focus left"), ("windows", "L", "Focus right"), ("windows", "F", "Full width"),
        ("workspaces", "1", "Go to workspace 1"), ("workspaces", "2", "Go to workspace 2"), ("workspaces", "3", "Go to workspace 3"),
    ].map { BindsPage.Row(id: $0.2, key: $0.1, label: $0.2, module: $0.0, custom: false) }

    nonisolated static let cases: [Case] = [
        Case(name: "tip", surface: .hud) { AnyView(TipView(text: "Converting 2 of 5 to JPG…", action: HUD.TipAction(title: "Cancel") {})) },
        Case(name: "alert", surface: .hud) { AnyView(ExtensionAlertView(alert: ExtensionTimerTests.alert)) },
        Case(name: "notes", surface: .notes) { AnyView(NotesPanelView(model: notes())) },
        Case(name: "clipboard", surface: .clipboard) { AnyView(ClipboardPanelView(model: PanelModel(store: try! clipStore()), returnCopies: false)) },
        Case(name: "overlay", surface: .overlay) { AnyView(OverlayView(title: "Hyper", rows: overlayRows)) },
    ]

    @Test("Onboarding draws Instrument, not Toybox's pixels, dark and light",
          arguments: [OnboardingModel.Step.welcome, .tryIt])
    func onboarding(_ step: OnboardingModel.Step) throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        let engine = Engine()
        func draw() throws -> Data {
            let model = OnboardingModel()
            model.step = step
            return try StyleTests().pixels(OnboardingView(model: model, look: look).environment(engine), look: look)
        }
        look.style = .toybox
        let toybox = try draw()
        look.style = .instrument
        let dark = try draw()
        #expect(dark != toybox, "\(step): Instrument drew Toybox's")
        // Instrument is dark or light as its theme is: Paper's draws light.
        look.themeID = "porcelain"
        #expect(try draw() != dark, "\(step): Instrument light drew dark")
    }

    @Test("The overlay's binds go in even columns, each module's eyebrow over its first bind, never alone at a column's foot; a ranked page has none")
    func overlayColumns() {
        let columns = InstrumentOverlay.columns(Self.overlayRows)
        #expect(columns.count == 2)
        let binds = columns.flatMap { $0 }.compactMap { if case .bind(let row) = $0 { row } else { nil } }
        #expect(binds == Self.overlayRows, "every bind once, in order")
        for column in columns {
            if case .group? = column.last { Issue.record("an eyebrow alone at a column's foot") }
            if case .bind? = column.first { Issue.record("a column starts without its module's eyebrow") }
        }
        #expect(abs(columns[0].count - columns[1].count) <= 2)
        let ranked = [Self.overlayRows[5], Self.overlayRows[0], Self.overlayRows[6]]
        #expect(InstrumentOverlay.columns(ranked).flatMap { $0 }.allSatisfy { if case .bind = $0 { true } else { false } })
        #expect(InstrumentOverlay.columns(Array(Self.overlayRows.prefix(4))).count == 1)
    }

    /// The top bar's parts: its readings, glyphs and clock in the bar, its tooltip, a reading's popover, Pilot's dropdown
    /// and the drag chip.
    nonisolated static let barCases: [Case] = [
        Case(name: "bar parts", surface: .topBar) {
            AnyView(BarPartsView(items: [[.reading(.cpu), .value("14%", widest: "100%")], [.symbol("wifi")], [.bar(0.6), .value("82%")],
                                         [.date("Thu 8 Oct"), .time("09:41")]]).environment(\.inTopBar, true))
        },
        Case(name: "tooltip", surface: .topBar) { AnyView(BarTooltipView(text: "Workspace 2: Telegram, Zen")) },
        Case(name: "readings", surface: .barPopovers) {
            AnyView(StatPopover(stats: [.cpu], rows: [SystemStats.Row(name: "User", value: "9 %", explanation: "", topic: .cpu)], busiest: [:]) {})
        },
        Case(name: "dropdown", surface: .barPopovers) {
            typealias On = DropdownQuickSwitchesTests.Fake
            return AnyView(PilotDropdown(switches: QuickSwitches(hyper: On(true), tiling: On(true), topBar: On(false), keepAwake: On(false), clipboard: On(true), dictation: On(true)),
                                         option: false).environment(Engine()))
        },
        // Binds' sheet draws in the Binds page's style (the page itself is another designer's).
        Case(name: "bind editor", surface: .page(.binds)) {
            let engine = Engine()
            return AnyView(BindEditor(action: "apps.terminal", actions: engine.bindActions).environment(engine))
        },
    ]

    @Test("Each panel draws Instrument, not Toybox's pixels, dark and light", arguments: cases)
    func drawn(_ c: Case) throws { try check(c) }

    @Test("The top bar's parts, tooltip, popovers and dropdown, and Binds' bind editor, draw Instrument, not Toybox's pixels, dark and light",
          arguments: barCases)
    func bar(_ c: Case) throws { try check(c) }

    /// `c` drawn Instrument dark (not Toybox's) and light (not dark).
    func check(_ c: Case) throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        let style = StyleTests()
        func draw() throws -> Data { try style.pixels(c.view().styled(c.surface, look: look), look: look) }
        look.style = .toybox
        let toybox = try draw()
        look.style = .instrument
        let dark = try draw()
        #expect(dark != toybox, "\(c.name): Instrument drew Toybox's")
        // Instrument is dark or light as its theme is: Paper's draws light.
        look.themeID = "porcelain"
        #expect(try draw() != dark, "\(c.name): Instrument light drew dark")
    }

    @Test("A workspace chip lights only the live one: filled while it has the focus, raised while another screen has it, bare otherwise")
    func barWorkspaces() throws {
        let (look, _) = LookPageTests().look()
        DisplayFaces.directory = LookThemeTests.fonts
        look.style = .instrument
        let style = StyleTests()
        func chip(current: Bool, focused: Bool) throws -> Data {
            try style.pixels(InstrumentWorkspaceChip(label: "2", current: current, focused: focused, occupied: true).styled(.topBar, look: look),
                             look: look)
        }
        let live = try chip(current: true, focused: true), elsewhere = try chip(current: true, focused: false), rest = try chip(current: false, focused: false)
        #expect(live != elsewhere && elsewhere != rest && live != rest)
        // The bar's numbers: 4, which the portrait display shows, gets a hairline before it; on one display, none.
        let tiler = TilerService()
        let occupied = ["1", "2", "3", "4"].map { OccupiedWorkspace(name: $0, apps: ["Zen"]) }
        func numbers(_ monitors: String) throws -> Data {
            tiler.seed(focused: "2", occupied: occupied, perMonitor: try JSONDecoder().decode([AeroMonitorWorkspace].self, from: Data(monitors.utf8)))
            return try style.pixels(TopBarWorkspacesView(screen: "Studio", tiler: tiler).environment(\.inTopBar, true)
                .styled(.topBar, look: look), look: look)
        }
        let one = try numbers(#"[{"monitor-id": 1, "monitor-name": "Studio", "workspace": "2"}]"#)
        let two = try numbers(#"[{"monitor-id": 1, "monitor-name": "Studio", "workspace": "2"}, {"monitor-id": 2, "monitor-name": "Portrait", "workspace": "4"}]"#)
        #expect(one != two, "no hairline before the workspace the portrait display shows")
        // Where the hairline goes (InstrumentBar.displays): before the first of the run another display holds, which goes
        // after this screen's, so never before the first.
        let split = { (names: [String], away: [String: Int]) in InstrumentBar.displays(InstrumentBarTests.items(names), here: 1, shown: [], monitors: away) }
        #expect(split(["1", "2", "3", "4"], ["4": 2]).elsewhere == 3)
        #expect(split(["1", "2", "3", "4"], ["3": 2, "4": 2]).elsewhere == 2, "one hairline before a run")
        let first = split(["1", "2"], ["1": 2])
        #expect(first.items.map(\.name) == ["2", "1"] && first.elsewhere == 1, "none before the first")
    }

    @Test("Through HUD.makePanel each panel in Instrument is opaque on the pop face, its shadow in margins round it, the window server's off",
          arguments: cases)
    func panel(_ c: Case) throws {
        let (look, _) = LookPageTests().look()
        testApp()
        let theme = look.themeID
        defer { look.themeID = theme }
        for dark in [true, false] {
            look.style = .instrument
            // Instrument is dark or light as its theme is: Paper's is light.
            look.themeID = dark ? theme : "porcelain"
            let panel = try #require(HUD.makePanel(c.view(), surface: c.surface, look: look) as? KeyPanel)
            defer { panel.close() }
            let tokens = StyleTokens.of(.instrument, theme: look.theme)
            #expect(tokens.depth.pop.shadows.isEmpty && NSEdgeInsetsEqual(panel.margins, NSEdgeInsetsZero),
                    "no pop-up casts a shadow, so the window is the face (Sven on build 29)")
            #expect(!panel.hasShadow)
            #expect((panel.contentView as? MaterialBackdrop)?.effect == nil, "Instrument's panels are opaque whatever the Panels material")
            #expect(panel.appearance?.name == (dark ? .darkAqua : .aqua))
        }
    }

    @Test("A tip in Instrument refits to its new words, about the centre it opened on")
    func tipRefit() throws {
        testApp()
        let look = Look.shared
        let style = look.style
        look.style = .instrument
        defer { HUD.dismissTip(); look.style = style }
        let panel = PanelTestSupport.hide(HUD.prepareTip("Converting 2 of 5 to JPG…", seconds: .infinity, action: HUD.TipAction(title: "Cancel") {}))
        panel.orderFrontRegardless()
        PanelTestSupport.pump()
        #expect((panel.contentView as? MaterialBackdrop)?.effect == nil, "the tip did not draw Instrument")
        let shown = try #require(HUD.tipModel)
        let opened = panel.frame
        HUD.updateTip("Converting 10 of 12 to WebP…", on: shown)
        PanelTestSupport.pump(0.1)
        let host = try #require((panel.contentView as? MaterialBackdrop)?.content)
        let fit = host.fittingSize
        #expect(panel.frame.width > opened.width, "the tip did not grow")
        #expect(abs(panel.frame.width - fit.width) < 1 && abs(panel.frame.height - fit.height) < 1,
                "the window \(panel.frame.size) is not the face \(fit)")
        #expect(abs(panel.frame.midX - opened.midX) <= 0.5 && abs(panel.frame.midY - opened.midY) <= 0.5)
    }

    // MARK: Notes panel's frame

    /// The room Instrument's pop shadow took round the face until build 29: a frame kept with it still opens at its face.
    static let instrument = NSEdgeInsets(top: 10, left: 40, bottom: 70, right: 40)
    static let screen = CGRect(x: 0, y: 0, width: 1800, height: 1100)

    @Test("The notes panel opens at its default face centred on the screen, with the margins round it when restyled")
    func notesDefaultFrame() {
        let plain = NotesPanel.frame(saved: nil, savedMargins: NSEdgeInsetsZero, margins: NSEdgeInsetsZero, screen: Self.screen)
        #expect(plain == CGRect(x: 520, y: 310, width: 760, height: 480), "the frame with no margins moved")
        let m = Self.instrument
        let styled = NotesPanel.frame(saved: nil, savedMargins: NSEdgeInsetsZero, margins: m, screen: Self.screen)
        #expect(styled == CGRect(x: 520 - m.left, y: 310 - m.bottom, width: 760 + m.left + m.right, height: 480 + m.top + m.bottom))
    }

    @Test("The kept frame is the face's: one kept without margins opens with them at the same face, and back; a face under the smallest size grows down from its top")
    func notesSavedFrame() {
        let m = Self.instrument
        let face = CGRect(x: 200, y: 150, width: 900, height: 600)
        let styled = NotesPanel.frame(saved: face, savedMargins: NSEdgeInsetsZero, margins: m, screen: Self.screen)
        #expect(styled == CGRect(x: 200 - m.left, y: 150 - m.bottom, width: 900 + m.left + m.right, height: 600 + m.top + m.bottom))
        #expect(NotesPanel.frame(saved: styled, savedMargins: m, margins: NSEdgeInsetsZero, screen: Self.screen) == face)
        #expect(NotesPanel.frame(saved: styled, savedMargins: m, margins: m, screen: Self.screen) == styled)
        #expect(NotesPanel.frame(saved: face, savedMargins: NSEdgeInsetsZero, margins: NSEdgeInsetsZero, screen: Self.screen) == face,
                "the kept frame with no margins moved")
        let small = NotesPanel.frame(saved: CGRect(x: 100, y: 100, width: 300, height: 200), savedMargins: NSEdgeInsetsZero, margins: m,
                                     screen: Self.screen)
        #expect(small.width - m.left - m.right == NotesPanel.minSize.width && small.height - m.top - m.bottom == NotesPanel.minSize.height)
        #expect(small.maxY - m.top == 300, "the face's top edge moved")
    }

    @Test("The margins the frame was kept with are saved beside it; none before styles")
    func notesSavedMargins() {
        let defaults = UserDefaults(suiteName: testSuite())!
        #expect(NSEdgeInsetsEqual(NotesPanel.savedMargins(defaults), NSEdgeInsetsZero))
        NotesPanel.saveMargins(Self.instrument, defaults)
        #expect(NSEdgeInsetsEqual(NotesPanel.savedMargins(defaults), Self.instrument))
    }

    @Test("A restyled panel resizes from its face's edges and corners, the opposite edges staying put, never under its smallest size")
    func faceEdges() {
        let m = Self.instrument
        let size = CGSize(width: 840, height: 560)
        let face = CGRect(x: m.left, y: m.bottom, width: size.width - m.left - m.right, height: size.height - m.top - m.bottom)
        #expect(FaceEdges.at(CGPoint(x: face.maxX + 2, y: face.midY), window: size, margins: m) == .right)
        #expect(FaceEdges.at(CGPoint(x: face.minX - 3, y: face.midY), window: size, margins: m) == .left)
        #expect(FaceEdges.at(CGPoint(x: face.midX, y: face.maxY - 4), window: size, margins: m) == .top)
        #expect(FaceEdges.at(CGPoint(x: face.minX + 1, y: face.minY + 1), window: size, margins: m) == [.left, .bottom])
        #expect(FaceEdges.at(CGPoint(x: face.midX, y: face.midY), window: size, margins: m) == nil, "inside the face")
        #expect(FaceEdges.at(CGPoint(x: 4, y: face.midY), window: size, margins: m) == nil, "out in the shadow's room")
        let frame = CGRect(x: 100, y: 100, width: 840, height: 560), min = CGSize(width: 600, height: 400)
        #expect(FaceEdges.right.resized(frame, by: CGVector(dx: 50, dy: 9), min: min) == CGRect(x: 100, y: 100, width: 890, height: 560))
        #expect(FaceEdges([.left, .top]).resized(frame, by: CGVector(dx: -20, dy: 30), min: min) == CGRect(x: 80, y: 100, width: 860, height: 590))
        #expect(FaceEdges([.left, .bottom]).resized(frame, by: CGVector(dx: 500, dy: 500), min: min) == CGRect(x: 340, y: 260, width: 600, height: 400))
    }
}
}
#endif
