#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Launcher › Your menu, every Files tab, Pilot and Menu bar in the whole window, Instrument in Tokyo Night (settings tidy,
/// Sven 2026-11-14): Your menu's two lists beside its preview at 1440, stacked at 1000; Files' pages; Notifications on
/// Menu bar. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter SettingsTidyRenders`
extension SharedLook {
@MainActor
@Suite("Settings tidy renders")
struct SettingsTidyRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Your menu, Files, Pilot and Menu bar in the window", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("settings-tidy")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = Engine()
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.settings-tidy")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let picked = Look.shared.style
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.style = picked }
        (Look.shared.style, Look.shared.themeID) = (.instrument, "tokyo-night")

        func shot(_ name: String, _ place: AppPlace, width: Int, height: Int) throws {
            model.go(place)
            window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 1))
            try Self.write(rep, from: Int(MenuBarRenders.pageLeft(.instrument, width: CGFloat(width))), to: dir.appendingPathComponent("\(name)-\(width).png"))
        }

        for width in [1440, 1000] { try shot("launcher", AppPlace(.menu), width: width, height: 2400) }
        // Every Files tab there is: its own content first, then each part.
        for tab in AppPage.files.tabs {
            try shot("files-\(tab.value?.rawValue ?? "front")", tab.value.map { AppPlace($0) } ?? AppPlace(.files), width: 1440, height: 2400)
        }
        try shot("pilot", AppPlace(.general), width: 1440, height: 2400)
        try shot("menubar", AppPlace(.menuBar), width: 1440, height: 4000)
    }

    /// RestyledRenders.writeTrimmed's cut 16 pt under the page's end, but a page taller than the render (a scroll that
    /// fills it) is written whole rather than failing: these renders compare layouts, not heights.
    static func write(_ rep: NSBitmapImageRep, from x: Int, to url: URL) throws {
        let scale = rep.pixelsWide / max(1, Int(rep.size.width))
        let data = try #require(rep.bitmapData), row = rep.bytesPerRow, start = x * scale * rep.bitsPerPixel / 8, bottom = rep.pixelsHigh - 1
        let last = stride(from: bottom, through: 0, by: -1).first { memcmp(data + $0 * row + start, data + bottom * row + start, row - start) != 0 } ?? bottom
        let height = min(rep.pixelsHigh, last + 16 * scale)
        let image = try #require(rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: height)))
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}
}
#endif
