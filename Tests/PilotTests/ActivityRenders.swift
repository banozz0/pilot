#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Activity (task N3), opt-in like the other renders: the whole window on the page in Instrument and Toybox, under Lagoon
/// (dark) and Porcelain (light) at 1440 by 900 and Instrument at 760; then
/// the page alone in each style with an app opened, a row hovered and a force quit waiting to be confirmed, and searched
/// and sorted by memory, and narrow. Seeded rows on real bundles of this Mac for the icons; nothing is read or quit.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter ActivityRenders`
extension SharedLook {
@MainActor
@Suite("Activity renders")
struct ActivityRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// A working day on Sven's Mac: a cargo build in Ghostex hogging the CPU, Zen with its tabs, macOS in the background.
    static let ps = """
            1     0     0   0.2  20416 /sbin/launchd
          130     1     0   6.4  95856 /System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores
          160     1    88  11.2 604000 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
          420     1   502   0.0  20480 /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow
          600     1   502   3.1  90000 /usr/libexec/photoanalysisd
          610     1   502   0.4  40000 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
          700     1   502   1.2 160000 /opt/homebrew/bin/node
          710     1   502   0.0  12000 /usr/libexec/trustd
        34511     1   502   4.1 735664 /Applications/Zen.app/Contents/MacOS/zen
         2204 34511   502  22.0 616320 /Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container
         9546 34511   502   0.8 416912 /Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container
         9547 34511   502   0.3 216912 /Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container
         7811     1   502  13.8 418704 /Applications/Ghostex.app/Contents/MacOS/Ghostex
         7812  7811   502   0.0   3000 -zsh
         7813  7812   502 342.0 5200000 /Users/ada/.cargo/bin/cargo
         7814  7812   502   0.9 220000 /opt/homebrew/bin/claude
        69659     1   502   1.8  68768 /Applications/Ghostty.app/Contents/MacOS/ghostty
         5100     1   502   0.6 380000 /Applications/Obsidian.app/Contents/MacOS/Obsidian
         5101  5100   502   0.2 180000 /Applications/Obsidian.app/Contents/Frameworks/Obsidian Helper (Renderer).app/Contents/MacOS/Obsidian Helper (Renderer)
         5300     1   502   0.1  98000 /System/Applications/Music.app/Contents/MacOS/Music
         1398     1   502   0.2 150288 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
        47642     1   502   1.1 115680 /Applications/Pilot.app/Contents/MacOS/Pilot
        47650 47642   502   0.1 167024 /Applications/Pilot.app/Contents/Helpers/pilot-files
        """

    static let apps = [("Zen", 34511, "/Applications/Zen.app"), ("Ghostex", 7811, "/Applications/Ghostex.app"),
                       ("Ghostty", 69659, "/Applications/Ghostty.app"), ("Obsidian", 5100, "/Applications/Obsidian.app"),
                       ("Music", 5300, "/System/Applications/Music.app"), ("Finder", 1398, "/System/Library/CoreServices/Finder.app"),
                       ("Pilot", 47642, "/Applications/Pilot.app")].map { Activity.App(pid: $0.1, name: $0.0, bundlePath: $0.2) }

    static var seeded: Activity.Snapshot { Activity.snapshot(Activity.parse(ps), apps: apps, me: 502, pilot: 47642) }

    /// Ghostex opened, Zen hovered, cargo's force quit waiting for its confirm.
    static let states = ActivityPage.Start(expanded: ["app.7811"], hovered: "app.34511", confirming: .init(id: "pid.7813", force: true))
    static let searched = ActivityPage.Start(sort: .memory, query: "plugin", hovered: "pid.2204", confirming: .init(id: "pid.9546", force: false))

    @Test("Activity renders in every style and layout, dark and light, with its states",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("activity")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        ActivityMonitor.shared.seed(Self.seeded, quitting: ["pid.700"])
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains { name.contains($0) } } ?? true }

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        for theme in ["lagoon", "porcelain"] {
            look.themeID = theme
            for style in PilotStyle.allCases {
                let name = style.rawValue
                look.style = style
                AppWindowController.applyLook(look, to: window)
                let widths = theme == "lagoon" && style == .instrument ? [1440, 760] : [1440]
                for width in widths where wanted("window-\(name)-\(theme)-\(width)") {
                    window.setContentSize(NSSize(width: CGFloat(width), height: 900))
                    model.go(AppPlace(.activity))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("window-\(name)-\(theme)-\(width).png"))
                }
                // The page alone at the window's page width: its states, then a search sorted by memory.
                // And narrow, where the actions go under the hovered row.
                for (state, start, width) in [("states", Self.states, 1000), ("search", Self.searched, 1000), ("narrow", Self.states, 520)]
                where theme == "lagoon" && wanted("page-\(name)-\(state)") {
                    let page = ActivityGround { ActivityPage(onScreen: false, start: start) }.styled(.page(.activity))
                        .environment(engine).frame(width: CGFloat(width), height: 1600).pilotTheme(look: look)
                    try RestyledRenders.writeTrimmed(rendered(page), from: 0, to: dir.appendingPathComponent("page-\(name)-\(state).png"))
                }
            }
        }
    }
}

/// The page on its style's ground, as the window's frame lays it.
private struct ActivityGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
