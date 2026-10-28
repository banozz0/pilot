#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds in Toybox (card agent-bo-95423182, mockup B binds-dark.png and binds-light.png), opt-in like the other renders:
/// the page column alone at the mockup's 1364 pt (its 1440 window less the 76 pt rail), Toybox dark and light and Instrument,
/// then at 924 and 684 (the 1000 and 760 windows), the Plain tab, and the list Find opens. Seeded as HomeRenders seeds
/// Home, in a moved home: My binds with the mockup's apps on T, B, G, I, Z and M, today's presses. An Engine reads and
/// writes binds.json, so the pixel check runs here too, never on Sven's own home.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ToyboxBindsRenders`
extension SharedLook {
@MainActor
@Suite("Toybox Binds renders")
struct ToyboxBindsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The engine HomeRenders seeds, in the moved home only.
    func engine() throws -> Engine {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        try SharedLook.HomeRenders.seedPresets()
        return try SharedLook.HomeRenders.engine()
    }

    /// Binds' page as the window hosts it: the page surface, `width` by `height`, on the shared Look.
    func page(_ engine: Engine, width: CGFloat, height: CGFloat = 900, plain: Bool = false, search: String = "") -> some View {
        BindsKeyboardPage(search: search, startOnPlain: plain) { _ in }
            .styled(.page(.binds))
            .environment(engine)
            .frame(width: width, height: height)
            .pilotTheme(look: .shared)
            .background(Theme.background)
    }

    /// Toybox takes dark or light from its theme, not the Dark switch (since 96d94dc), so its dark is Toybox Night.
    func pick(_ style: PilotStyle, dark: Bool = true) {
        Look.shared.style = style
        if style == .toybox { Look.shared.themeID = dark ? "toybox-night" : "toybox" }
    }

    @Test("Binds renders as mockup B in Toybox dark and light, beside Instrument, at 1364, 924 and 684", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let engine = try engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("binds")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Look.shared.themeID = "lagoon"
        defer { Look.shared.themeID = PilotTheme.defaultID; pick(.instrument) }
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }
        func write(_ name: String, _ view: some View, trimmed: Bool = false) throws {
            guard wanted(name) else { return }
            let rep = try rendered(view, wait: 0.9)
            let url = dir.appendingPathComponent("\(name).png")
            if trimmed { try RestyledRenders.writeTrimmed(rep, from: 0, to: url) }
            else { try #require(rep.representation(using: .png, properties: [:])).write(to: url) }
        }

        for dark in [true, false] {
            pick(.toybox, dark: dark)
            let tone = dark ? "dark" : "light"
            try write("toybox-\(tone)-1364", page(engine, width: 1364))
            for width in [CGFloat(924), 684] { try write("toybox-\(tone)-\(Int(width))", page(engine, width: width, height: 2400), trimmed: true) }
            try write("toybox-\(tone)-1364-plain", page(engine, width: 1364, plain: true))
            try write("toybox-\(tone)-1364-find", page(engine, width: 1364, search: "Open"))
        }
        pick(.instrument)
        try write("instrument-1364", page(engine, width: 1364))
    }

    @Test("Binds hosted under Toybox draws other pixels than Instrument, and Toybox dark other than Toybox light", .enabled(if: env["CFFIXED_USER_HOME"] != nil))
    func drawn() throws {
        let engine = try engine()
        defer { Look.shared.themeID = PilotTheme.defaultID; pick(.instrument) }
        func pixels() throws -> Data {
            let rep = try rendered(page(engine, width: 1364), wait: 0.5)
            return Data(bytes: try #require(rep.bitmapData), count: rep.bytesPerRow * rep.pixelsHigh)
        }
        pick(.instrument)
        let instrument = try pixels()
        pick(.toybox, dark: true)
        let dark = try pixels()
        pick(.toybox, dark: false)
        let light = try pixels()
        #expect(Set(instrument).count > 16 && Set(dark).count > 16, "a blank page")
        #expect(dark != instrument && light != instrument, "Toybox drew Instrument's Binds")
        #expect(dark != light, "Toybox light drew dark")
    }
}
}
#endif
