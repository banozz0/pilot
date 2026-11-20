#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The settings window at its 780 pt minimum and its 1296 pt default (AppWindowController.minSize, .size), Instrument dark:
/// every page of every area, each of its tabs, 3600 pt tall, Notifications on, so no row's label breaks mid-word beside its
/// picker and nothing pushes the window's content past its left edge (the first ink under the tab bar, printed). Opt-in,
/// in a moved home: `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter SettingsFitRenders/render`
extension SharedLook {
@MainActor
@Suite("Settings fit renders")
struct SettingsFitRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let widths: [CGFloat] = [AppWindowController.minSize.width, AppWindowController.size.width]

    /// Under the tab bar, the first point from the left where anything differs from the window's left edge: the sidebar's
    /// highlight starts 10 pt in; less is the content pushed past the edge.
    static func firstInk(_ rep: NSBitmapImageRep, top: CGFloat) -> Int {
        let scale = rep.pixelsWide / max(1, Int(rep.size.width)), width = Int(rep.size.width)
        let rows = Array(stride(from: Int(top) * scale, to: rep.pixelsHigh - 4 * scale, by: scale))
        return (0..<width).first { x in rows.contains { y in rep.colorAt(x: x * scale, y: y) != rep.colorAt(x: 0, y: y) } } ?? width
    }

    @Test("Every page and tab renders at 780 and 1296", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath(), "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("settings-fit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        // Notifications on shows its Show in and Layer rows; with no live source started nothing reads or draws on screen.
        NotificationSettings.shared.enabled = true
        defer { NotificationSettings.shared.enabled = false }
        let engine = Engine()
        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        (look.themeID, look.style) = ("nightwatch", .instrument)
        AppWindowController.applyLook(look, to: window)
        let only = Self.env["PILOT_RENDER_ONLY"]

        for width in Self.widths {
            window.setContentSize(NSSize(width: width, height: 3600))
            for area in AppArea.shownAll { for page in area.shown {
                for tab in page.tabs.isEmpty ? [(value: nil, title: "")] : page.tabs {
                    let name = "\(page.rawValue)-\(tab.value?.rawValue ?? "front")-\(Int(width))"
                    guard only.map(name.contains) ?? true else { continue }
                    model.go(AppPlace(page, tab.value))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
                    print("fit: \(name) first ink at x=\(Self.firstInk(rep, top: PanelTabBar.height + 4))pt")
                }
            } }
        }
    }

    /// Menu bar › Notifications with Dock saved (Sven, 2026-11-20, Q284), at 1296: Pilot's dock off with the top bar on
    /// (Show in offers Floating and Top bar, Top bar marked), both off (the same two and the fine print), the dock on (Dock
    /// offered and marked). Stand-ins for the dock and the top bar, so nothing switches on the Mac.
    /// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter "SettingsFitRenders/dockStates"`
    @Test("Notifications' Show in with Dock saved, Pilot's dock off and on", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func dockStates() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == URL(fileURLWithPath: home).resolvingSymlinksInPath(), "the home directory did not move")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("settings-fit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let settings = NotificationSettings.shared
        let saved = (settings.enabled, settings.showIn, settings.topBarOn, settings.dockOn)
        defer { (settings.enabled, settings.showIn, settings.topBarOn, settings.dockOn) = saved }
        settings.enabled = true
        settings.showIn = .dock
        let look = Look.shared
        let was = (look.themeID, look.style)
        defer { (look.themeID, look.style) = was }
        (look.themeID, look.style) = ("nightwatch", .instrument)
        let engine = Engine()
        for (name, dock, top) in [("dock-off-topbar-on", false, true), ("dock-off-topbar-off", false, false), ("dock-on", true, false)] {
            (settings.dockOn, settings.topBarOn) = ({ dock }, { top })
            // A window each: the stand-ins aren't observed, as the engine's dock and top bar are in Pilot.
            let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
            let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
            defer { window.close() }
            let frame = try #require(window.contentView?.superview)
            AppWindowController.applyLook(look, to: window)
            model.go(AppPlace(.menuBar))
            window.setContentSize(NSSize(width: AppWindowController.size.width, height: 3600))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("notifications-\(name).png"))
            print("q284: \(name): saved \(settings.showIn.rawValue), placement \(settings.placement.rawValue), choices \(settings.choices.map(\.rawValue)), marked \(settings.shownChoice.rawValue)")
        }
        // A Dock saved before Q284 never put the bar's bell item on: the first launch after does, once.
        let bar = BarItemsStore.shared, old = try #require(UserDefaults(suiteName: testSuite()))
        let bell = bar.settings.entry(.notifications).on
        defer { bar.settings.set(.notifications, on: bell) }
        old.set(NotificationSettings.ShowIn.dock.rawValue, forKey: NotificationSettings.showInKey)
        bar.settings.set(.notifications, on: false)
        _ = NotificationSettings(defaults: old)
        let first = bar.settings.entry(.notifications).on
        bar.settings.set(.notifications, on: false)
        _ = NotificationSettings(defaults: old)
        print("q284: Dock saved before: bell item on at the first launch \(first), off again at the next \(!bar.settings.entry(.notifications).on)")
    }
}
}
#endif
