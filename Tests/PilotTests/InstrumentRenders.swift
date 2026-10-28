#if DEBUG
import AppKit
@testable import Clipboard
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

    /// The mockup's eight copies, from the apps it names, then six older ones for a panel taller than eight rows.
    static let clips: [StoredClip] = [
        (ClipKind.text, "step-commit -m \"redesign A mockups\" --land", "com.mitchellh.ghostty", 20.0),
        (.link, "https://styles.refero.design/style/3b6a17f0-3bdf-418c", "app.zen-browser.zen", 125),
        (.image, "", "cc.ffitch.shottr", 540), (.colour, "#FF6B2C", "com.microsoft.VSCode", 840),
        (.text, "Pilot makes a Mac feel as close to Omarchy as macOS allows.", "md.obsidian", 1860),
        (.text, "Wait about 0.3 s between chained AeroSpace commands.", "com.anthropic.claudefordesktop", 3700),
        (.file, "/Users/ada/code/dotfiles/keymap/keymap.toml", "com.apple.finder", 7300),
        (.text, "swift test --filter BindStoreTests", "com.apple.dt.Xcode", 10_900),
        (.link, "https://nikitabobko.github.io/AeroSpace/commands", "app.zen-browser.zen", 14_400),
        (.text, "open -g \"pilot://open?page=look\"", "com.mitchellh.ghostty", 18_000),
        (.colour, "#EA5410", "com.microsoft.VSCode", 21_600), (.text, "Geist Mono for every changing number.", "md.obsidian", 25_200),
        (.file, "/Users/ada/code/pilot/SPEC.md", "com.apple.finder", 30_000), (.text, "bd ready --json", "com.mitchellh.ghostty", 36_000),
    ].enumerated().map { i, c in
        var clip = StoredClip(id: Int64(i + 1), kind: c.0, text: c.1, sourceApp: c.2, copiedAt: Date().addingTimeInterval(-c.3), pinned: false)
        if c.0 == .image { clip.customTitle = "Screenshot 09.12.41" }
        return clip
    }

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
        var sources = HomeSources()
        sources.lastCopied = { HomeCopy(text: "bd show agent-bo-95422987", at: Date().addingTimeInterval(-125), count: 48) }
        sources.pages = { [] }
        sources.recentCopies = { Self.clips }

        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map(name.contains) ?? true }

        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.instrument")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model)
            .environment(engine).environment(\.homeSources, sources)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "lagoon"
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
