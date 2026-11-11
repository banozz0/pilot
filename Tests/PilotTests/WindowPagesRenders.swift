#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// C3's page map (Sven, 2026-10-10): every page and tab in the whole window, Instrument in Nightwatch and Toybox in Lagoon
/// at 1000 and at the least width, 760, and the Hyper+Space menu's root in each, all one scale step bigger; and Home at the
/// window's first size, 1000 by 660. Seeded as InstrumentPagesRenders is (fakes; nothing reaches the tiler or the network). Opt-in, in
/// a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter WindowPagesRenders`
extension SharedLook {
@MainActor
@Suite("Window pages renders")
struct WindowPagesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Every page, and every tab past a page's first, by file name.
    static let places: [(String, AppPlace)] = AppPage.allCases.map { ($0.rawValue, AppPlace($0)) }
        + AppSection.allCases.filter(\.isTab).map { ("\($0.page.rawValue)-\($0.rawValue)", AppPlace($0)) }
        // A place on a More tab: the tab, its block scrolled to and marked in the index (simplify-pages T7).
        + AppSection.allCases.filter { $0.onMore != nil }.map { ("\($0.page.rawValue)-more-\($0.rawValue)", AppPlace($0)) }
        // A place on a front: the front scrolled to its block (Sven, 2026-11-11, after 2276).
        + AppSection.allCases.filter(\.onFront).map { ("\($0.page.rawValue)-front-\($0.rawValue)", AppPlace($0)) }

    @Test("Every page renders in Instrument and Toybox at 1000 and 760", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("window-pages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()

        let engine = try SharedLook.HomeRenders.engine()
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        // PILOT_RENDER_ONLY narrows to the file names holding one of its comma-separated words.
        let only = Self.env["PILOT_RENDER_ONLY"]?.split(separator: ",").map(String.init)
        let looks: [(name: String, style: PilotStyle, theme: String, widths: [Int])] = [
            ("instrument", .instrument, "nightwatch", [1000, 760]), ("toybox", .toybox, "lagoon", [1000, 760]),
        ]
        for (name, style, theme, widths) in looks {
            look.style = style
            look.themeID = theme
            AppWindowController.applyLook(look, to: window)
            for width in widths {
                for (page, place) in Self.places {
                    let file = "\(name)-\(width)-\(page)"
                    guard only.map({ $0.contains { file.contains($0) } }) ?? true else { continue }
                    window.setContentSize(NSSize(width: CGFloat(width), height: width == 760 ? 620 : 760))
                    model.go(place)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
                }
            }
            // The window's first size: Instrument's and Toybox's sidebars keep their mockups' rows and footer and scroll
            // there; the renders show by how much.
            window.setContentSize(AppWindowController.size)
            model.go(AppPlace(.home))
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            frame.layoutSubtreeIfNeeded()
            try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(name)-660-sidebar.png"))
            // Fronts at the window's first size: Pilot's, Open with's and Captures' fit without a scroll with their previews
            // (simplify-pages T8, T26, T27); Tiling's, System's, Workspaces' and Voice's fronts and the More tabs show how
            // much does (Sven, 2026-11-11, after 2276), Workspaces' also with four workspaces, as Sven keeps them.
            func wanted(_ file: String) -> Bool { only.map { $0.contains { file.contains($0) } } ?? true }
            func front(_ place: AppPlace, _ file: String) throws {
                guard wanted(file) else { return }
                model.go(place)
                RunLoop.main.run(until: Date().addingTimeInterval(0.7))
                frame.layoutSubtreeIfNeeded()
                try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
            }
            let fronts = [AppPage.general, .menu, .openWith, .tiling, .captures, .system, .binds, .workspaces, .voice].map { ($0.rawValue, AppPlace($0)) }
                + [("voice-more", AppPlace(.voiceMore)), ("tiling-more", AppPlace(.tilingMore)), ("workspaces-more", AppPlace(.workspacesMore)),
                   ("binds-more", AppPlace(.bindsMore)), ("binds-mouse", AppPlace(.mouse))]
            for (page, place) in fronts { try front(place, "\(name)-660-\(page)") }
            if wanted("\(name)-660-workspaces-4") {
                let list = engine.workspaceList, kept = list.count
                while list.count > 4 { list.remove() }
                try front(AppPlace(.workspaces), "\(name)-660-workspaces-4")
                while list.count < kept { list.add() }
            }
            // The previews follow their controls (T26, T27): Launcher's with its second row hidden and its last moved first,
            // Open with's with another editor picked, Pilot's with right Command as Hyper, Tiling's with wide gaps, a thick
            // border and Defocus, Captures' opening the editor, Voice's at Words in both places in the theme's colour;
            // each put back after.
            do {
                let root = MenuRootSettings.shared, editor = EditorChoice.shared, settings = engine.settings
                let (savedRoot, savedPick, savedKeys) = (root.root, editor.pick, settings.layerKeys)
                defer { (root.root, editor.pick) = (savedRoot, savedPick); settings.setLayerKeys(savedKeys, from: .settings) }
                let captures = CaptureSettingsStore.shared, dictation = PilotDictation.shared
                let savedCapture = captures.settings
                let savedLook = (look.windowBorder, look.windowBorderWidth, look.defocusStrength, look.defocusDim)
                let savedDictation = (dictation.showIn, dictation.whileSpeaking, dictation.waveColour)
                defer {
                    captures.settings = savedCapture
                    (look.windowBorder, look.windowBorderWidth, look.defocusStrength, look.defocusDim) = savedLook
                    (dictation.showIn, dictation.whileSpeaking, dictation.waveColour) = savedDictation
                }
                root.root.show(MenuBranch.top[1], false)
                root.root.move(try #require(MenuBranch.top.last), to: 0)
                editor.pick = "com.apple.TextEdit"
                settings.setLayerKeys([.rightCommand], from: .settings)
                (look.windowBorder, look.windowBorderWidth, look.defocusStrength, look.defocusDim) = (true, 6, 2, 40)
                captures.settings.afterCapture = .editor
                (dictation.showIn, dictation.whileSpeaking, dictation.waveColour) = (.both, .words, .theme)
                for (page, place) in fronts where page != "tiling" { try front(place, "\(name)-660-\(page)-set") }
                // Voice's bar slot needs the top bar on, which this window leaves off: the preview alone, as it draws then.
                for side in [TopBarSide.left, .right] where wanted("\(name)-660-voice-bar") {
                    let setup = DictationOverlay.Setup(showIn: .both, barSide: side, colour: .theme, topBarShows: true)
                    try writeRender(DictationPreview(setup: setup, words: true).frame(width: 600).padding(20).pilotTheme(look: look).background(Theme.background),
                                    to: dir.appendingPathComponent("\(name)-660-voice-bar-\(side.rawValue).png"))
                }
                // Tiling's gaps on a store of its own: the engine's hands each change to the tiler.
                let file = "\(name)-660-tiling-set"
                if wanted(file) {
                    let defaults = try #require(UserDefaults(suiteName: testSuite()))
                    defaults.set(try JSONEncoder().encode(PilotBlock(gaps: .init(inner: 24, outer: 24))), forKey: "pilotBlock")
                    let block = PilotBlockStore(tiler: EngineObservers().tiler, defaults: defaults)
                    let page = MonitorsGround { TilingBody(block: block, settings: engine.settings, apps: []) }
                        .frame(width: 716, height: 560).pilotTheme(look: look)
                    try writeRender(page, to: dir.appendingPathComponent("\(file).png"))
                }
            }
            // The menu's root and a search, as the panel draws them.
            for (state, nav) in [("root", AliasesRenders.root()), ("search", AliasesRenders.search())] {
                let file = "\(name)-menu-\(state)"
                guard only.map({ $0.contains { file.contains($0) } }) ?? true else { continue }
                let panel = HUD.makePanel(MenuView(model: MenuModel(nav: nav)).environment(engine), surface: .menu)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                content.layoutSubtreeIfNeeded()
                try #require(snapshot(content, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
            }
        }
    }
}
}
#endif
