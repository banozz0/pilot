#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the Look page (card agent-bo-95422896) for Moody beside the approved artifact 5sh21HWjCjsWYAwWKTibcE:
/// Tokyo Night, Folio and Void, Glass off and on, and Glass at 100 % over white so the floor raises the
/// surface (the amber badge). The page runs on a Look of its own (a fake Ghostty, its own defaults); only the shared
/// look's theme is previewed, in a moved home. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter LookRenders`
extension SharedLook {
@MainActor
@Suite("Look renders")
struct LookRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The Look page renders in three themes", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderLook() throws {
        let (look, dir) = try Self.setUp()
        if let proof = Self.env["PILOT_THEME_REVIEW_RENDER"] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: proof))
            let value = try JSONDecoder().decode(JSONValue.self, from: bytes)
            guard case .object(let fields) = value, case .array(let inputs) = fields["inputs"],
                  let plan = inputs.first, let result = inputs.last else { throw ThemeFailure("missing review render fixture") }
            look.style = .instrument; look.themeID = "tokyo-night"; Self.mirror(look, spot: nil)
            try writeRender(ThemePreviewSummary(plan: plan) { ThemePlanReview(plan: plan) }
                .padding(20).frame(width: 760, height: 420, alignment: .topLeading)
                .styled(.page(.look), look: look).pilotTheme(look: look).background(Theme.background),
                to: dir.appendingPathComponent("theme-review.png"), wait: 0.8)
            try writeRender(Text(themeOutcomeText(result)).textSelection(.enabled)
                .padding(20).frame(width: 760, height: 140, alignment: .topLeading)
                .styled(.page(.look), look: look).pilotTheme(look: look).background(Theme.background),
                to: dir.appendingPathComponent("theme-outcomes.png"), wait: 0.8)
            Self.resetShared(); return
        }
        if Self.env["PILOT_THEME_SECTION_RENDER"] == "1" {
            // Apply theme and Restore default on the heading's line (Q69); Apply's result one line, each change behind
            // Details (build 2276).
            let result: JSONValue = .object(["status": .string("applied"),
                "changed": .array(["Pilot", "wallpaper", "Ghostty", "Zed", "Obsidian vault notes", "VS Code"].map(JSONValue.string)),
                "changes": .array(["Pilot: colours, cursor colours", "Wallpaper collection: 2 images", "Ghostty", "Zed", "Obsidian vault notes", "VS Code"].map(JSONValue.string)),
                "next": .array([.string("Reload Obsidian to see it.")])])
            for id in ["tokyo-night", "porcelain"] {
                look.style = .instrument; look.themeID = id; Self.mirror(look, spot: nil)
                let themes = PilotTheme.designed.filter { ThemeNativePalette.stock($0.id).compatible(with: look.style.rawValue) }
                try writeRender(ThemeSection(themes: themes, picked: "tokyo-night", columns: 4, applied: true, canApply: true, running: false,
                                             pick: { _ in }, apply: {}, restore: {}) {
                        Text(themeOutcomeText(result))
                        DisclosureGroup("Details") { Text(themeOutcomeDetails(result)).font(.caption) }
                    } more: { EmptyView() }
                    .padding(20).frame(width: 980, height: 1260, alignment: .topLeading)
                    .styled(.page(.look), look: look).pilotTheme(look: look).background(Theme.background),
                    to: dir.appendingPathComponent("theme-section-\(id).png"), wait: 0.8)
            }
            Self.resetShared(); return
        }
        if Self.env["PILOT_THEME_EDITOR_RENDER"] == "1" {
            let base = try #require(LookTests.themes.first)
            var pack = ThemePack(id: "lagoon-copy", title: "Lagoon copy", dark: base.dark, palette: base.colors,
                                 adapters: ["ghostty": .object([:]), "zed": .object([:]), "obsidian": .object([:])])
            pack.material = .init(glass: true, transparency: 35, blur: "full")
            let wide = try Data(contentsOf: try Self.shippedPicture("tokyo-night"))
            let tall = try Data(contentsOf: try Self.shippedPicture("tokyo-night", tall: true))
            for style in PilotStyle.allCases {
                for id in ["tokyo-night", "porcelain"] {
                    look.style = style; look.themeID = id; Self.mirror(look, spot: nil)
                    var draft = ThemePackStore.Draft(pack: pack)
                    if id == "tokyo-night" {
                        draft.pack.wallpapers = ["wallpapers/Tide.png", "wallpapers/Dusk.png"]
                        draft.files = ["wallpapers/Tide.heic": wide, "wallpapers/Dusk.png": tall]
                    }
                    try writeRender(HStack(alignment: .top, spacing: 18) {
                        ThemePackEditor(draft: .constant(draft), save: {}, review: {}, cancel: {})
                    }.padding(20).frame(width: 1100, height: 920, alignment: .top)
                        .styled(.page(.look), look: look).pilotTheme(look: look).background(Theme.background),
                        to: dir.appendingPathComponent("editor-\(style.rawValue)-\(id).png"), wait: 0.8)
                }
            }
            Self.resetShared(); return
        }

        var spot: [Double]?
        func shot(_ name: String, width: CGFloat = 1000, height: CGFloat = 860) throws {
            try Self.shot(look, spot: spot, to: dir.appendingPathComponent("\(name).png"), width: width, height: height)
        }
        for id in ["tokyo-night", "folio", "void"] {
            look.themeID = id
            try shot("look-\(id)", height: 1000)
        }
        look.themeID = PilotTheme.defaultID
        // Over a white wallpaper, the first theme whose floor lifts its card at Transparency 100 %, so the badge turns amber;
        // More open.
        let white: [Double] = [255, 255, 255]
        let raised = PilotTheme.designed.first { Layers(transparency: 100, text: $0.text2, card: $0.surface, ground: $0.ground, spot: white).lifted }
        let theme = try #require(raised, "no theme lifts its floor at 100 % over white")
        look.themeID = theme.id
        look.glass = true
        look.transparency = 100
        spot = white
        try shot("look-raised-more-\(theme.id)-glass", height: 1200)
        try #require(look.layers.lifted, "the floor did not rise")
        look.glass = false
        look.transparency = 33
        spot = nil
        look.themeID = PilotTheme.defaultID
        // Reduce transparency on: the window is solid (the badge and Defocus's line saying so are Tiling's now, below).
        Look.shared.setAccessibility(reduceTransparency: true, increaseContrast: false)
        look.setAccessibility(reduceTransparency: true, increaseContrast: false)
        look.glass = true
        try shot("look-reduce-transparency", height: 1600)
        Look.shared.setAccessibility(reduceTransparency: false, increaseContrast: false)
        look.setAccessibility(reduceTransparency: false, increaseContrast: false)
        // At the window's least width, Glass off and on: the Transparency row shows only while it is on.
        for glass in [false, true] {
            look.glass = glass
            try shot("look-glass-\(glass ? "on" : "off")-760", width: AppWindowController.minSize.width, height: 1300)
        }
        Self.resetShared()
    }

    /// Defocus's Blur and Dim rows (Sven, 2026-10-16), on Tiling's Focused window block since the page map (Sven
    /// 2026-10-17): as they come, dim only, and both off, where the hint says there is nothing to do; then Reduce
    /// transparency on, where the badge and Defocus each say so on a line of their own; at the window's least width, in
    /// each style.
    @Test("Tiling's Focused window block renders its Defocus rows and badge", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderDefocus() throws {
        let (look, dir) = try Self.setUp()
        func shot(_ name: String) throws {
            Self.mirror(look, spot: nil)
            try writeRender(FocusedWindowBlock(look: look).styled(.page(.tiling), look: look).padding(.horizontal, 24)
                                .frame(width: Self.page(AppWindowController.minSize.width), height: 820, alignment: .top)
                                .pilotTheme(look: look).background(Theme.background),
                            to: dir.appendingPathComponent("focused-window-\(name).png"), wait: 0.8)
        }
        for (name, strength, dim) in [("default", Defocus.defaultStrength, Defocus.defaultDim), ("dim-only", 0, 45), ("both-off", 0, 0)] {
            look.defocusStrength = strength
            look.defocusDim = dim
            try shot("defocus-\(name)")
        }
        look.defocusStrength = Defocus.defaultStrength
        look.defocusDim = Defocus.defaultDim
        look.setAccessibility(reduceTransparency: true, increaseContrast: false)
        try shot("reduce-transparency")
        look.setAccessibility(reduceTransparency: false, increaseContrast: false)
        look.style = .toybox
        try shot("toybox")
        look.style = .instrument
        Self.resetShared()
    }

    /// The page at the window's default and least widths (card agent-bo-95422970): every theme card's line whole, in a dark
    /// theme and a light one, so a fix at one width or in one theme opens no clip at the other.
    @Test("The Look page shows every line whole at both window widths", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderWidths() throws {
        let (look, dir) = try Self.setUp()
        for id in ["tokyo-night", "folio"] {
            look.themeID = id
            for window in [AppWindowController.size.width, AppWindowController.minSize.width] {
                try Self.shot(look, to: dir.appendingPathComponent("look-widths-\(id)-\(Int(window)).png"), width: Self.page(window), height: 1400)
            }
        }
        Self.resetShared()
    }

    /// The style picker (story 137, card agent-bo-95423180) at the top of the page: each style picked, in a dark theme and a
    /// light one (dark or light is the theme's).
    @Test("The Look page's style picker renders in every style", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderStyles() throws {
        let (look, dir) = try Self.setUp()
        for id in ["tokyo-night", "folio"] {
            look.themeID = id
            for style in PilotStyle.allCases {
                look.style = style
                try Self.shot(look, more: true, to: dir.appendingPathComponent("look-style-\(style.rawValue)-\(id).png"), width: 1000, height: 420)
            }
        }
        look.style = .instrument
        Self.resetShared()
    }

    /// Menu Rail and Classic T9: the Hyper+Space menu tiles under the style picker, each layout picked, in a dark theme
    /// and a light one at the window's default and least widths; then under Toybox, which says it keeps its own menu.
    @Test("The Look page's Hyper+Space menu picker renders", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderMenuLayout() throws {
        let (look, dir) = try Self.setUp()
        for id in ["tokyo-night", "porcelain"] {
            look.themeID = id
            for layout in MenuLayoutStyle.allCases {
                look.menuLayout = layout
                for window in [AppWindowController.size.width, AppWindowController.minSize.width] {
                    try Self.shot(look, more: true, to: dir.appendingPathComponent("look-menu-\(layout.rawValue)-\(id)-\(Int(window)).png"),
                                  width: Self.page(window), height: 640)
                }
            }
        }
        look.themeID = "tokyo-night"
        look.menuLayout = .rail
        look.style = .toybox
        try Self.shot(look, more: true, to: dir.appendingPathComponent("look-menu-toybox-lagoon.png"), width: Self.page(AppWindowController.size.width), height: 760)
        look.style = .instrument
        Self.resetShared()
    }

    /// The style picker at every width the page gets (Instrument's sidebar at 1000 and at 760; Toybox's rail at 760, 682),
    /// each style picked: Vision reads every card's name and both keys whole, none broken mid-word as a
    /// page 552 wide once broke Instrum/ent and Spac/e. With PILOT_RENDER_OCR=1 too, as Vision stalls on a loaded Mac.
    @Test("The Look page's style picker shows every word whole at every page width", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RENDER_OCR"] != nil))
    func styleWords() throws {
        let (look, dir) = try Self.setUp()
        look.themeID = "tokyo-night"
        Self.mirror(look, spot: nil)
        for style in PilotStyle.allCases {
            look.style = style
            for width in [Self.page(AppWindowController.size.width), 682, Self.page(AppWindowController.minSize.width)] {
                let name = "look-style-words-\(style.rawValue)-\(Int(width))"
                let rep = try rendered(LookPage(look: look, more: true).styled(.page(.look), look: look).frame(width: width, height: 480, alignment: .top)
                                        .pilotTheme(look: look).background(Theme.background), wait: 0.8)
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
                let read = try recognisedText(in: rep).map(\.text).joined(separator: " ").lowercased()
                let tokens = read.split { !$0.isLetter }.map(String.init)
                let words = PilotStyle.allCases.map { $0.title.lowercased() } + ["hyper", "space"]
                // A word broken over two lines reads as its stub ("instrum", "spac"); a missing one, not at all.
                let stubs = tokens.filter { token in token.count >= 3 && words.contains { $0.count > token.count && $0.hasPrefix(token) } }
                let missing = words.filter { !tokens.contains($0) }
                #expect(stubs.isEmpty && missing.isEmpty, "\(name): broken \(stubs), missing \(missing) in \(read)")
            }
        }
        look.style = .instrument
        Self.resetShared()
    }

    /// Look in the whole window at its first size, 1000 by 660 (simplify-pages T20, T28): the front, Glass off and on over
    /// Tokyo Night's wallpaper, and More, in Instrument and Toybox, a dark theme and a light one. The shared look in a moved home,
    /// so Theme draws its packs' section; nothing reaches Ghostty or the apps.
    @Test("Look's front and More at 1000 by 660", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderWindow() throws {
        let (_, dir) = try Self.setUp()
        let engine = try SharedLook.HomeRenders.engine()
        let still = WallpaperScreen.thumbnail(try Self.shippedPicture("tokyo-night"), size: 640)
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)
            .environment(\.lookPreviewStill, still)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved; Self.resetShared() }
        let screens = [WallpaperScreen(id: 1, name: "Built-in Retina Display", portrait: false, detail: "tokyo-night-wide.png · 1 of 2",
                                       thumb: still, next: still, nextName: nil)]
        func shot(_ place: AppPlace, _ name: String) throws {
            model.go(place)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        for (style, themes) in [(PilotStyle.instrument, ["tokyo-night", "porcelain"]), (.toybox, ["toybox-night", "toybox"])] {
            for theme in themes {
                look.style = style; look.themeID = theme
                AppWindowController.applyLook(look, to: window)
                window.setContentSize(AppWindowController.size)
                let name = "window-660-\(style.rawValue)-\(theme)"
                look.glass = false
                try shot(AppPlace(.look), "\(name)-front")
                try shot(AppPlace(.lookMore), "\(name)-more")
                // The whole front, past the window's foot: the preview follows Glass (T28).
                for glass in [false, true] {
                    look.glass = glass
                    try writeRender(LookPage(look: look, screens: screens).environment(\.lookPreviewStill, still).styled(.page(.look), look: look).frame(width: Self.page(1000), height: 1500, alignment: .top)
                                        .pilotTheme(look: look).background(Theme.background),
                                    to: dir.appendingPathComponent("page-front-\(style.rawValue)-\(theme)-glass-\(glass ? "on" : "off").png"), wait: 0.8)
                }
                look.glass = false
            }
        }
    }

    /// Look's preview, the desk in the theme (round 3 note 3, Sven's pick A of the look-preview-design round and its
    /// tweak): the whole window at 1000 by 660 in Tokyo Night and in Toybox's night, then the preview alone at the size that
    /// window gives it (354 by 257, measured in the round) in four of the line-up of 18's new packs, and once at 978 by 344
    /// (Sven's wider window on build 2300). Each pack's own manifest and wide wallpaper.
    /// `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter "LookRenders/renderPreview"`
    @Test("Look's preview as a desk in four packs", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderPreview() throws {
        let (look, base) = try Self.setUp()
        let dir = base.appendingPathComponent("preview")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packs = root.appending(path: "Packaging/ThemePacks")
        func pack(_ id: String) throws -> ThemePack { try ThemePack.decode(Data(contentsOf: packs.appending(path: "\(id)/manifest.json"))) }
        func still(_ id: String) throws -> NSImage { try #require(WallpaperScreen.thumbnail(try Self.shippedPicture(id), size: 640)) }
        func wear(_ look: Look, _ id: String, dark: Bool) throws {
            look.style = .instrument; look.themeID = id; look.packChanged(try pack(id))
            try #require(look.theme.id == id && look.theme.dark == dark, "\(id) did not resolve from its pack")
        }
        let shared = Look.shared
        let saved = (shared.themeID, shared.style, shared.glass)
        defer { (shared.themeID, shared.style, shared.glass) = saved; shared.packChanged(nil); look.packChanged(nil); Self.resetShared() }

        // In place: the whole window, the shared look.
        let tokyo = try still("tokyo-night")
        let engine = try SharedLook.HomeRenders.engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)
            .environment(\.lookPreviewStill, tokyo)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        for (style, id) in [(PilotStyle.instrument, "tokyo-night"), (.toybox, "toybox-night")] {
            if style == .instrument { try wear(shared, id, dark: true) } else { shared.packChanged(nil); shared.style = style; shared.themeID = id }
            shared.glass = false
            AppWindowController.applyLook(shared, to: window)
            window.setContentSize(AppWindowController.size)
            model.go(AppPlace(.look))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            try #require(snapshot(frame, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("window-\(id).png"))
        }

        // Alone, in each pack.
        func shot(_ name: String, _ picture: NSImage, width: CGFloat = 354, height: CGFloat = 257) throws {
            try writeRender(LookPreview(look: look).environment(\.lookPreviewStill, picture).frame(width: width, height: height)
                                .styled(.page(.look), look: look).pilotTheme(look: look).background(Theme.background),
                            to: dir.appendingPathComponent("\(name).png"), wait: 0.5)
        }
        for (id, dark) in [("tokyo-night", true), ("catppuccin", true), ("gruvbox", true), ("dracula", true)] {
            try wear(look, id, dark: dark); try wear(shared, id, dark: dark)
            let picture = try still(id)
            try shot(id, picture)
            if id == "tokyo-night" { try shot("wide-tokyo-night", picture, width: 978, height: 344) }
        }
    }

    /// The first wide (or the tall) wallpaper of Pilot's own pack `id`, from the repo's catalogue copy: the app ships it
    /// palette-only and downloads the pictures on Apply.
    static func shippedPicture(_ id: String, tall: Bool = false) throws -> URL {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "catalogue/themes/\(id)/wallpapers")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        return folder.appending(path: try #require(names.first { $0.hasPrefix("\(id)-tall.") == tall }, "\(id) has no \(tall ? "tall" : "wide") wallpaper"))
    }

    /// A Look of its own (a fake Ghostty, its own defaults), and the directory the renders go to; refuses unless the home
    /// directory moved.
    static func setUp() throws -> (Look, URL) {
        let home = try #require(env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's settings")
        let dir = URL(fileURLWithPath: try #require(env["PILOT_RENDER_DIR"])).appendingPathComponent("look")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        return (Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: LookTests.defaults()), dir)
    }

    /// The page for `look`, `width` wide, written to `url`.
    static func shot(_ look: Look, spot: [Double]? = nil, more: Bool = false, to url: URL, width: CGFloat, height: CGFloat) throws {
        mirror(look, spot: spot)
        try writeRender(LookPage(look: look, more: more).styled(.page(.look), look: look).frame(width: width, height: height, alignment: .top)
                            .pilotTheme(look: look).background(Theme.background),
                        to: url, wait: 0.8)
    }

    /// The page's width in a window `window` wide: it sits beside Instrument's sidebar (232 pt from 1000 wide, else 208)
    /// and a hairline.
    static func page(_ window: CGFloat) -> CGFloat { window - (window >= 1000 ? 232 : 208) - 1 }

    /// Theme draws from the shared look, so each shot copies the page's look onto it (in the moved home only; Ghostty is
    /// never touched).
    static func mirror(_ look: Look, spot: [Double]?) {
        look.preview(spot: spot)
        let shared = Look.shared
        shared.themeID = look.theme.id
        shared.glass = look.glass
        shared.transparency = look.transparency
        shared.preview(spot: spot)
    }

    static func resetShared() {
        Look.shared.themeID = PilotTheme.defaultID
        Look.shared.glass = false
        Look.shared.transparency = 33
        Look.shared.preview(spot: nil)
    }
}
}
#endif
