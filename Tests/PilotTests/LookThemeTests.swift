import AppKit
import CoreText
import Foundation
import Observation
import PilotCore
import Testing
@testable import Pilot

/// Design round 4's foundation on the app side (card agent-bo-95422890): the Look settings are stored, saved at once and
/// observed; the material carries over as Glass; a pick restyles Ghostty; the display faces load from the bundle's Fonts;
/// the window takes its material. Throwaway defaults only: nothing of Sven's is read or written, no window is shown.
@MainActor
@Suite("Look themes")
struct LookThemeTests {
    @MainActor
    struct Bench {
        let look: Look
        let ghostty = LookTests.FakeGhostty()
        let defaults: UserDefaults

        init(defaults: UserDefaults? = nil) {
            self.defaults = defaults ?? LookTests.defaults()
            look = Look(themes: LookTests.themes, ghostty: ghostty, defaults: self.defaults)
        }

        func again() -> Look { Look(themes: LookTests.themes, ghostty: LookTests.FakeGhostty(), defaults: defaults) }
    }

    @Test("A fresh install is Instrument, Lagoon, Glass off with Transparency at 33 %, the window and panels solid")
    func defaults() {
        let look = Bench().look
        #expect(look.style == .instrument && look.themeID == "lagoon" && look.theme.id == "lagoon")
        #expect(!look.glass && look.transparency == 33)
        let l = look.layers
        #expect([l.ground, l.sidebar, l.card, l.well, l.raised, l.keyFree] == Array(repeating: 1, count: 6))
        #expect(look.effectiveMaterial == .solid)
    }

    @Test("Every setting is saved as it changes and read back by the next start")
    func persisted() {
        let bench = Bench()
        let look = bench.look
        look.style = .toybox
        look.themeID = "orchid"
        look.glass = true
        look.transparency = 55
        let next = bench.again()
        #expect(next.style == .toybox && next.themeID == "orchid" && next.theme.id == "orchid")
        #expect(next.glass && next.transparency == 55 && next.effectiveMaterial == .glass)
        // Transparency stays between 0 and 100.
        look.transparency = -12
        #expect(look.transparency == 0 && bench.again().transparency == 0)
        look.transparency = 140
        #expect(look.transparency == 100)
    }

    @Test("A saved Strength carries over as the Transparency whose ground draws what it drew, saved under its own key")
    func strengthCarriesOver() {
        let defaults = LookTests.defaults()
        defaults.set(80, forKey: "look.strength")
        defaults.set("glass", forKey: "look.material")
        let bench = Bench(defaults: defaults)
        // Glass at Strength 80 drew its ground at 44 %; Transparency 97 draws it at 43.7 %.
        #expect(bench.look.transparency == 97 && defaults.integer(forKey: "look.transparency") == 97)
        #expect(Layers.strength(transparency: bench.look.transparency) == 80)
        // Once carried over, the old key is never read again.
        defaults.set(40, forKey: "look.strength")
        #expect(bench.again().transparency == 97)
    }

    @Test("The saved material carries over once as Glass: Tinted and Glass on, Solid and Transparency 0 % off; the user's Glass at 100 % stays")
    func materialCarriesOver() {
        for (material, transparency, glass, slider) in [("tinted", 40, true, 40), ("glass", 100, true, 100), ("solid", 60, false, 60),
                                                        ("glass", 0, false, 33)] {
            let defaults = LookTests.defaults()
            defaults.set(material, forKey: "look.material")
            defaults.set(transparency, forKey: "look.transparency")
            defaults.set(false, forKey: "look.panelsGlass")
            let look = Bench(defaults: defaults).look
            #expect(look.glass == glass && look.transparency == slider, "\(material) \(transparency)")
            #expect(defaults.object(forKey: "look.glass") as? Bool == glass && defaults.integer(forKey: "look.transparency") == slider)
            // The old keys stay, for an older Pilot; the new one wins from now on.
            #expect(defaults.string(forKey: "look.material") == material)
            look.glass.toggle()
            #expect(Bench(defaults: defaults).look.glass == !glass)
        }
        // Nothing saved: off, and nothing written until it changes.
        let fresh = Bench()
        #expect(!fresh.look.glass && fresh.defaults.object(forKey: "look.glass") == nil)
    }

    @Test("Views reading the theme, the material and the style redraw when one changes, without a relaunch")
    func observed() {
        let bench = Bench()
        let look = bench.look
        final class Flag: @unchecked Sendable { var raised = false }
        let theme = Flag(), material = Flag(), style = Flag()
        withObservationTracking { _ = look.theme } onChange: { theme.raised = true }
        withObservationTracking { _ = look.layers } onChange: { material.raised = true }
        withObservationTracking { _ = look.style } onChange: { style.raised = true }
        look.themeID = "workshop"
        look.transparency = 60
        look.style = .toybox
        #expect(theme.raised && material.raised && style.raised)
        #expect(look.colors.ground == ThemeColors(PilotTheme.named("workshop")!).ground && !look.theme.dark)
    }

    @Test("Picking a theme writes Ghostty once from its Omarchy palette, and nothing else")
    func pickRestylesGhostty() throws {
        let bench = Bench()
        bench.look.pick("dusk")
        #expect(bench.ghostty.written == [GhosttyLook(theme: LookTests.themes.named("last-horizon"))])
    }

    @Test("A theme retired in round 15 starts as the new theme closest to it, saved, and Ghostty follows through the pick's path; an unknown id is the default")
    func retired() async throws {
        // The whole map is PilotThemeTests.migration's; here the app's start with a retired id and an unknown one.
        for (old, new) in [("paper", "workshop"), ("nope", "lagoon")] {
            let defaults = LookTests.defaults()
            defaults.set(old, forKey: "look.theme")
            let bench = Bench(defaults: defaults)
            #expect(bench.look.themeID == new && bench.look.theme.id == new, "\(old)")
            #expect(defaults.string(forKey: "look.theme") == new && bench.again().themeID == new, "\(old) saved")
            try await SetupSoundTests.until { !bench.ghostty.written.isEmpty }
            #expect(bench.ghostty.written.map { $0.theme?.id } == [PilotTheme.named(new)?.source], "\(old): Ghostty takes \(new)'s palette once")
        }
        // A designed id, or none saved, writes nothing.
        let defaults = LookTests.defaults()
        defaults.set("void", forKey: "look.theme")
        let bench = Bench(defaults: defaults), fresh = Bench()
        try await Task.sleep(for: .milliseconds(50))
        #expect(bench.look.themeID == "void" && bench.ghostty.written.isEmpty && fresh.ghostty.written.isEmpty)
        #expect(fresh.look.themeID == "lagoon" && fresh.defaults.string(forKey: "look.theme") == nil)
        // Pilot's look taken out of Ghostty stays out: the id moves on, Ghostty is left alone.
        let out = LookTests.defaults()
        out.set("hearth", forKey: "look.theme")
        let ghostty = LookTests.FakeGhostty()
        ghostty.isApplied = false
        #expect(Look(themes: LookTests.themes, ghostty: ghostty, defaults: out).themeID == "dusk")
        try await Task.sleep(for: .milliseconds(50))
        #expect(ghostty.written.isEmpty && out.string(forKey: "look.theme") == "dusk")
    }

    @Test("The wallpaper's brightness is read only from a file that is there: a renamed one leaves the theme's own spot")
    func currentWallpaper() throws {
        let look = Bench().look
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-look-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gone = dir.appending(path: "Wallpapers/anime-nun-with-the-lantern - 3440x1440.png")
        look.desktopPicture = { gone }
        #expect(look.currentWallpaper == nil)
        let there = dir.appending(path: "wall.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0]).write(to: there)
        look.desktopPicture = { there }
        #expect(look.currentWallpaper == there)
    }

    @Test("Reduce transparency makes the window and panels solid; Increase contrast makes every surface solid")
    func accessibility() {
        let bench = Bench()
        let look = bench.look
        look.glass = true
        #expect(look.effectiveMaterial == .glass && look.layers.card < 1)
        look.setAccessibility(reduceTransparency: true, increaseContrast: false)
        #expect(look.effectiveMaterial == .solid && look.layers.ground == 1)
        look.setAccessibility(reduceTransparency: false, increaseContrast: true)
        #expect(look.effectiveMaterial == .glass && look.layers.card == 1 && look.layers.raised == 1 && look.layers.ground < 1)
        // Glass stays on, so turning the setting off brings it back.
        #expect(look.glass)
    }

    static let fonts = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/Fonts").standardizedFileURL

    @Test("Every theme's display face loads from the bundled fonts at its weight and axes, its OFL licence beside it")
    func faces() throws {
        DisplayFaces.directory = Self.fonts
        #expect(DisplayFaces.register() == PilotTheme.designed.count)
        for theme in PilotTheme.designed {
            let face = theme.face
            let font = DisplayFaces.font(face, size: 24)
            #expect(font.familyName == face.family, "\(theme.id): \(font.familyName ?? "none")")
            let axes = (CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber]) ?? [:]
            if !axes.isEmpty, let wght = axes[NSNumber(value: DisplayFaces.tag("wght"))] {
                #expect(abs(wght.doubleValue - Double(face.weight)) < 1, "\(theme.id) weight \(wght)")
            }
            for (tag, value) in face.axes {
                #expect(axes[NSNumber(value: DisplayFaces.tag(tag))]?.doubleValue == value, "\(theme.id) \(tag)")
            }
            let licence = try String(contentsOf: Self.fonts.appending(path: "\(face.file)/OFL.txt"), encoding: .utf8)
            #expect(licence.contains("SIL OPEN FONT LICENSE"), "\(theme.id) licence")
        }
        // The system face is the system's.
        #expect(DisplayFaces.font(.system, size: 20).familyName == NSFont.systemFont(ofSize: 20).familyName)
    }

    @Test("Packaging/Fonts holds only faces a theme or style draws, so a retired theme's face leaves the bundle (story 142)")
    func onlyUsedFaces() throws {
        let folders = try FileManager.default.contentsOfDirectory(at: Self.fonts, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .map(\.lastPathComponent)
        let used = (PilotTheme.designed.map(\.face) + StyleTokens.faces).filter { !$0.isSystem }.map(\.file)
        #expect(Set(folders) == Set(used))
    }

    @Test("The window takes its material: none behind Solid, Liquid Glass behind Glass")
    func windowMaterial() throws {
        let bench = Bench()
        let look = bench.look
        let window = AppWindowController.makeWindow(content: NSView())
        defer { window.close() }
        let host = try #require(window.contentView as? MaterialBackdrop)
        AppWindowController.applyLook(look, to: window)
        #expect(window.isOpaque && host.effect == nil && window.backgroundColor == NSColor(look.colors.ground))
        look.glass = true
        AppWindowController.applyLook(look, to: window)
        let glass = try #require(host.effect as? NSGlassEffectView)
        #expect(glass.tintColor?.alphaComponent ?? 0 > 0.3)
        // Instrument takes the material and Transparency too (round 15); Toybox's window stays opaque whatever they are.
        look.transparency = 100
        look.style = .instrument
        AppWindowController.applyLook(look, to: window)
        #expect(!window.isOpaque && host.effect is NSGlassEffectView && look.layers.card < 1)
        #expect(abs(((host.effect as? NSGlassEffectView)?.tintColor?.alphaComponent ?? 0) - look.layers.ground) < 0.01)
        look.style = .toybox
        AppWindowController.applyLook(look, to: window)
        #expect(window.isOpaque && host.effect == nil && look.layers.card == 1)
        look.style = .instrument
        // Transparency 0 % is solid.
        look.transparency = 0
        AppWindowController.applyLook(look, to: window)
        #expect(window.isOpaque && host.effect == nil)
        look.transparency = 33
        look.setAccessibility(reduceTransparency: true, increaseContrast: false)
        AppWindowController.applyLook(look, to: window)
        #expect(window.isOpaque && host.effect == nil)
        // A light theme gives the window light controls.
        look.themeID = "porcelain"
        AppWindowController.applyLook(look, to: window)
        #expect(window.appearance?.name == .aqua)
    }

    @Test("The window's glass stays live when the window is not key (Sven, 2026-10-17: it went solid)")
    func glassWhenNotKey() throws {
        let bench = Bench()
        let look = bench.look
        look.glass = true
        look.transparency = 100
        let window = AppWindowController.makeWindow(content: NSView())
        defer { window.close() }
        let host = try #require(window.contentView as? MaterialBackdrop)
        AppWindowController.applyLook(look, to: window)
        for note in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.post(name: note, object: window)
            #expect(!window.isKeyWindow && !window.isOpaque)
            #expect(host.effect is NSGlassEffectView && host.effect?.isHidden == false, "\(note.rawValue): glass shown")
            #expect(host.layer?.backgroundColor == nil, "\(note.rawValue): no still colour over the desktop")
        }
    }
}
