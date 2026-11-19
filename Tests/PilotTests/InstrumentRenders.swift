#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Home and the window frame in Instrument (mockup A, card agent-bo-95423181), opt-in like the other renders: the whole
/// window at 1440 by 900, 1000 by 900 and 760 by 900 (and 760 at the whole page's height), under Instrument dark and
/// Instrument light. Home's renders' seed in a moved home, with
/// Spotify's workspace 4 on a second display and eight recent copies (fakes; nothing reaches the tiler or the
/// clipboard).
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter InstrumentRenders`
extension SharedLook {
@MainActor
@Suite("Instrument renders")
struct InstrumentRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// Home's renders' windows, with workspace 4 on a second display.
    static let windows = HomeRenders.windows.replacingOccurrences(
        of: "\"workspace\": \"4\", \"monitor-id\": 1", with: "\"workspace\": \"4\", \"monitor-id\": 2")

    /// Where the page ends, in points: under the last row whose pixels right of `x` (the sidebar) differ from the bottom's.
    static func pageEnd(_ rep: NSBitmapImageRep, from x: Int) throws -> CGFloat {
        let scale = rep.pixelsWide / max(1, Int(rep.size.width))
        let data = try #require(rep.bitmapData), row = rep.bytesPerRow, start = x * scale * rep.bitsPerPixel / 8, bottom = rep.pixelsHigh - 1
        let last = stride(from: bottom, through: 0, by: -1).first { memcmp(data + $0 * row + start, data + bottom * row + start, row - start) != 0 } ?? bottom
        try #require(last < bottom - 16 * scale, "the page is taller than the render")
        return CGFloat(last + 1) / CGFloat(scale)
    }

    @Test("Home and the window frame render in Instrument dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("instrument")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }
        try HomeRenders.seedPresets()
        try #require(WorkspacePresetStore.standard.url.path.hasPrefix(home), "the presets would land outside the moved home")

        let engine = try HomeRenders.engine()
        // Home's renders' presses, moved to the three hours up to now, so none falls after the clock.
        var today = TodayPresses()
        let hour = Calendar.current.component(.hour, from: .now), midnight = Calendar.current.startOfDay(for: .now)
        for (n, action) in engine.today.top(20, now: .now).flatMap({ row in Array(repeating: row.action, count: row.count) }).enumerated() {
            let at = midnight.addingTimeInterval(Double(max(0, hour - [3, 2, 2, 1, 1, 1, 0, 0][n % 8])) * 3600 + Double(n % 40) * 60)
            today.count(action, at: min(at, .now))
        }
        engine.seedToday(today)
        let windows = try AeroWindow.parse(Self.windows)
        engine.observers.tiler.seed(focused: "1", occupied: OccupiedWorkspace.list(windows), windows: windows)
        SharedLook.StatsRenders.seed(SystemSampler.shared)
        SharedLook.StatsRenders.pickMockup(BarItemsStore.shared)
        let sources = HomeSources()

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }

        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.instrument")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.homeSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "tokyo-night"
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.style = .instrument }
        for (name, style, dark) in [("instrument-dark", PilotStyle.instrument, true), ("instrument-light", .instrument, false)] {
            Look.shared.style = style
            AppWindowController.applyLook(.shared, to: window)
            for (width, height) in [(1440, 900), (1000, 900), (760, 900), (1440, 1500), (760, 0)] {
                // Height 0: the whole page at its own height, measured on a window taller than it.
                let file = "\(name)-\(width)" + (height == 0 ? "-page" : "x\(height)")
                guard wanted(file) else { continue }
                func draw(_ height: CGFloat) throws -> NSBitmapImageRep {
                    window.setContentSize(NSSize(width: CGFloat(width), height: height))
                    model.go(AppPlace(.home))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                    frame.layoutSubtreeIfNeeded()
                    return try #require(snapshot(frame, scale: 2))
                }
                var rep = try draw(CGFloat(height == 0 ? 3200 : height))
                if height == 0 { rep = try draw(Self.pageEnd(rep, from: width >= 1000 ? 233 : 209) + 24) }
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
            }
        }
    }
}
}
#endif
