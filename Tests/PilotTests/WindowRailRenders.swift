#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The window's built layouts (window directions, Sven 2026-10-11, design 6D3E1T482hjVZaUkgMvvDb), opt-in like the other
/// renders, each in its own folder: Home, Keys › Binds and Desktop › Menu bar in the whole window at 1440 by 900,
/// Instrument (Lagoon, Porcelain) and Toybox (Toybox Night, Toybox), dark and light; then Menu bar at 760 dark (the rail's
/// list folds into the header, the tabs drop their names), and the rail's Binds at 1600 dark, full width as every one-page area.
/// `PILOT_RENDER_SHAPE=tabs` (or rail) renders one layout. Seeded as Home's renders are, in a moved home.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter WindowRailRenders`
extension SharedLook {
@MainActor
@Suite("Window rail renders")
struct WindowRailRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let pages: [AppPage] = [.home, .binds, .menuBar]
    static let looks: [(name: String, style: PilotStyle, theme: String)] = [
        ("instrument-dark", .instrument, "lagoon"), ("instrument-light", .instrument, "porcelain"),
        ("toybox-dark", .toybox, "toybox-night"), ("toybox-light", .toybox, "toybox"),
    ]

    @Test("Each built window layout renders in Instrument and Toybox, dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let engine = try ToyboxBindsRenders().engine()
        let root = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.window.rail")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        defer { look.themeID = PilotTheme.defaultID; look.style = .instrument; look.windowShape = .rail }
        let only = Self.env["PILOT_RENDER_ONLY"]
        var dir = root
        func shot(_ file: String, _ page: AppPage, width: Int) throws {
            guard only.map(file.contains) ?? true else { return }
            window.setContentSize(NSSize(width: CGFloat(width), height: 900))
            model.go(AppPlace(page))
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            frame.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(frame, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
        }
        for shape in WindowShape.allCases where (Self.env["PILOT_RENDER_SHAPE"].map { $0 == shape.rawValue } ?? true) {
            look.windowShape = shape
            dir = root.appendingPathComponent(shape.rawValue)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, style, theme) in Self.looks {
                look.style = style
                look.themeID = theme
                AppWindowController.applyLook(look, to: window)
                for page in Self.pages { try shot("\(name)-\(page.rawValue)-1440", page, width: 1440) }
                if name.hasSuffix("dark") { try shot("\(name)-menuBar-760", .menuBar, width: 760) }
                if name.hasSuffix("dark") && shape == .rail { try shot("\(name)-binds-1600", .binds, width: 1600) }
            }
        }
    }
}
}
#endif
