#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Capture looks and output (T27; editors round 2, C1, C2, C8, C9, C11) in the real capture editor with its backdrop
/// panel: a look applied and set for every capture, auto balance, a backdrop sized for Instagram, the whole panel tall
/// with Add a capture's recent captures, and each of Pilot's looks, a place size and a before-and-after as exported;
/// Instrument (Lagoon, Workshop) and Toybox (toybox-night, toybox). Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter CaptureLooksRenders`
extension SharedLook {
@MainActor
@Suite("Capture looks renders")
struct CaptureLooksRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Looks, balance, sizes by place and Add a capture render in Instrument and Toybox, dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("capture-looks")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let capture = try #require(CaptureFixture.image())
        // Two earlier captures for Add a capture's row, and the wallpapers the panel lists.
        let walls = try BackdropPanelRenders.wallpapers(in: out.appendingPathComponent("wallpapers"))
        let earlier = try (1...2).map { n -> URL in
            let url = out.appendingPathComponent("wallpapers/Capture \(n).png")
            try BackdropPanelRenders.write(try #require(BackdropPanelRenders.crop(capture, to: CGSize(width: 420 + n * 140, height: 300))), to: url)
            return url
        }
        let library = BackdropLibrary.shared
        library.setWallpapersNow(walls, recent: earlier)
        let settings = CaptureSettingsStore.shared
        let every = settings.settings.everyCaptureLook
        defer { settings.settings.everyCaptureLook = every }
        let sunset = try #require(BackdropPreset.looks.first { $0.name == "Sunset" })
        let balanced = try #require(BackdropPreset.looks.first { $0.backdrop.balance })

        for pass in CaptureEditorRenders.passes {
            look.style = pass.style
            look.themeID = pass.theme
            let tokens = StyleTokens.of(look.style, theme: look.theme)
            func model(_ b: Backdrop?) -> EditorModel {
                let m = EditorModel(image: capture, scale: 2, accent: tokens.colors.accent.rgb, dark: tokens.dark, ground: tokens.colors.canvas.rgb)
                m.panelOpen = true
                m.setBackdrop(b?.resolved(for: capture))
                m.loadPictureNow()
                return m
            }
            library.setEveryCapture(sunset)
            let states: [(String, EditorModel)] = [
                ("1-look-sunset-every-capture", model(sunset.backdrop)),
                ("2-auto-balance", model(balanced.backdrop)),
                ("3-size-for-instagram", model(Backdrop(fill: .gradient([0x5B8DEF, 0x1E2A78]), pad: 48, place: .instagram))),
            ]
            for (name, m) in states {
                let size = EditorLayout.window(m.size, fit: 1, tokens: tokens, panel: true)
                let view = CaptureEditorView(model: m, add: { _, _ in })
                let rep = try CaptureEditorRenders.draw(view, tokens: tokens, size: size, scale: 2)
                try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("E\(name)-\(pass.tag).png"))
            }
            // The whole panel, tall, so every group shows: Looks to Add a capture.
            let m = states[2].1
            let panel = BackdropPanel(backdrop: m.backdrop, set: { _ in }, subject: capture, capture: true, add: { _, _ in })
                .background(tokens.color(\.panel))
            let rep = try CaptureEditorRenders.draw(panel, tokens: tokens, size: CGSize(width: BackdropPanel.width, height: 1180), scale: 2)
            try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("P-panel-whole-\(pass.tag).png"))
        }

        // The exports: each of Pilot's looks, Instagram's size, and a before and after in Ocean.
        for l in BackdropPreset.looks {
            let flat = try #require(MarkupRenderer.framed(capture, l.backdrop, scale: 2))
            try BackdropPanelRenders.write(flat, to: out.appendingPathComponent("X-look-\(l.name.lowercased()).png"))
        }
        let insta = try #require(MarkupRenderer.framed(capture, Backdrop(fill: .gradient([0x5B8DEF, 0x1E2A78]), pad: 48, place: .instagram), scale: 2))
        #expect((insta.width, insta.height) == (1080, 1350))
        try BackdropPanelRenders.write(insta, to: out.appendingPathComponent("X-size-instagram-1080x1350.png"))
        let after = try #require(Pins.load(earlier[1])?.0)
        let joined = try #require(CombineLayout.draw([capture, after], direction: .sideBySide, gap: 0))
        let ocean = try #require(BackdropPreset.looks.first { $0.name == "Ocean" })
        try BackdropPanelRenders.write(try #require(MarkupRenderer.framed(joined, ocean.backdrop, scale: 2)),
                                       to: out.appendingPathComponent("X-add-a-capture-before-after.png"))
    }
}
}
#endif
