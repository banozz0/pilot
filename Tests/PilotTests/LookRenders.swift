#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the Look page (card agent-bo-95422896) for Moody beside the approved artifact 5sh21HWjCjsWYAwWKTibcE:
/// Lagoon, Workshop and Void, Glass off and on, and Glass at 100 % over white so the floor raises the
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

        var spot: [Double]?
        func shot(_ name: String, width: CGFloat = 1000, height: CGFloat = 860) throws {
            try Self.shot(look, spot: spot, to: dir.appendingPathComponent("\(name).png"), width: width, height: height)
        }
        for id in ["lagoon", "workshop", "void"] {
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
        for id in ["lagoon", "workshop"] {
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
        for id in ["lagoon", "workshop"] {
            look.themeID = id
            for style in PilotStyle.allCases {
                look.style = style
                try Self.shot(look, to: dir.appendingPathComponent("look-style-\(style.rawValue)-\(id).png"), width: 1000, height: 420)
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
        for id in ["lagoon", "porcelain"] {
            look.themeID = id
            for layout in MenuLayoutStyle.allCases {
                look.menuLayout = layout
                for window in [AppWindowController.size.width, AppWindowController.minSize.width] {
                    try Self.shot(look, to: dir.appendingPathComponent("look-menu-\(layout.rawValue)-\(id)-\(Int(window)).png"),
                                  width: Self.page(window), height: 640)
                }
            }
        }
        look.themeID = "lagoon"
        look.menuLayout = .rail
        look.style = .toybox
        try Self.shot(look, to: dir.appendingPathComponent("look-menu-toybox-lagoon.png"), width: Self.page(AppWindowController.size.width), height: 760)
        look.style = .instrument
        Self.resetShared()
    }

    /// The style picker at every width the page gets (Instrument's sidebar at 1000 and at 760; Toybox's rail at 760, 682),
    /// each style picked: Vision reads every card's name and both keys whole, none broken mid-word as a
    /// page 552 wide once broke Instrum/ent and Spac/e. With PILOT_RENDER_OCR=1 too, as Vision stalls on a loaded Mac.
    @Test("The Look page's style picker shows every word whole at every page width", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil && env["PILOT_RENDER_OCR"] != nil))
    func styleWords() throws {
        let (look, dir) = try Self.setUp()
        look.themeID = "lagoon"
        Self.mirror(look, spot: nil)
        for style in PilotStyle.allCases {
            look.style = style
            for width in [Self.page(AppWindowController.size.width), 682, Self.page(AppWindowController.minSize.width)] {
                let name = "look-style-words-\(style.rawValue)-\(Int(width))"
                let rep = try rendered(LookPage(look: look).styled(.page(.look), look: look).frame(width: width, height: 480, alignment: .top)
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
    static func shot(_ look: Look, spot: [Double]? = nil, to url: URL, width: CGFloat, height: CGFloat) throws {
        mirror(look, spot: spot)
        try writeRender(LookPage(look: look).styled(.page(.look), look: look).frame(width: width, height: height, alignment: .top)
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
