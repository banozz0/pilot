#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The settings window at its 780 pt minimum and its 1296 pt default (AppWindowController.minSize, .size), Instrument dark:
/// every page the sidebar lists at the window's own height, so the sidebar's names read whole off its left edge, and Desktop ›
/// Menu bar (Notifications on), Dock and Captures whole, so no row's label breaks mid-word beside its picker. Opt-in, in a
/// moved home: `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter SettingsFitRenders`
extension SharedLook {
@MainActor
@Suite("Settings fit renders")
struct SettingsFitRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let widths: [CGFloat] = [AppWindowController.minSize.width, AppWindowController.size.width]
    /// Pages whose rows pair a label with a segmented picker, drawn whole.
    static let pickerPages: [AppPage] = [.menuBar, .dock, .captures]

    /// Under the tab bar: the first point from the left where anything differs from the window's left edge (the sidebar's
    /// names start there, about 20 pt in), and whether the last 6 to 14 points at the right are one colour (nothing runs
    /// past the window's right edge).
    static func edges(_ rep: NSBitmapImageRep, top: CGFloat) -> (left: Int, right: Bool) {
        let scale = rep.pixelsWide / max(1, Int(rep.size.width)), width = Int(rep.size.width)
        let rows = Array(stride(from: Int(top) * scale, to: rep.pixelsHigh - 4 * scale, by: scale))
        let left = (0..<width).first { x in rows.contains { y in rep.colorAt(x: x * scale, y: y) != rep.colorAt(x: 0, y: y) } } ?? width
        let ground = rep.colorAt(x: (width - 10) * scale, y: Int(top) * scale)
        let right = rows.allSatisfy { y in stride(from: (width - 14) * scale, to: (width - 6) * scale, by: scale).allSatisfy { rep.colorAt(x: $0, y: y) == ground } }
        return (left, right)
    }

    @Test("Every listed page and the picker pages render at 780 and 1296", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
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

        func draw(_ page: AppPage, width: CGFloat, height: CGFloat, name: String) throws {
            guard only.map(name.contains) ?? true else { return }
            window.setContentSize(NSSize(width: width, height: height))
            model.go(AppPlace(page))
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
            let (left, right) = Self.edges(rep, top: PanelTabBar.height + 4)
            print("fit: \(name) content \(Int(rep.size.width))pt, first ink at x=\(left)pt, right gutter \(right ? "clear" : "INKED")")
        }
        for width in Self.widths {
            for area in AppArea.shownAll where !RailLayout.fullWidth(area) {
                for page in area.shown { try draw(page, width: width, height: AppWindowController.size.height, name: "list-\(page.rawValue)-\(Int(width))") }
            }
            for page in Self.pickerPages { try draw(page, width: width, height: 3600, name: "page-\(page.rawValue)-\(Int(width))") }
        }
    }
}
}
#endif
