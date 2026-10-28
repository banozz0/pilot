#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pages not yet restyled inside Instrument's frame (card agent-bo-95423181), opt-in like the other renders: Look,
/// Workspaces, Setup, Stats, Install and Clipboard in the whole window at 1440, 1000 and 760 by 900, Instrument dark and
/// light. Seeded as Home's renders are, in a moved home.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter InstrumentFrameRenders`
extension SharedLook {
@MainActor
@Suite("Instrument frame renders")
struct InstrumentFrameRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let pages: [AppPage] = [.look, .workspaces, .system, .activity, .install, .clipboard]

    @Test("Unrestyled pages render in Instrument's frame dark and light", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let engine = try ToyboxBindsRenders().engine()
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("frame")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppWindowModel(defaults: UserDefaults(suiteName: "pilot.renders.instrument.frame")!)
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        Look.shared.themeID = "nightwatch"
        defer { Look.shared.themeID = PilotTheme.defaultID; Look.shared.style = .instrument }
        let only = Self.env["PILOT_RENDER_ONLY"]
        for (name, style, dark) in [("instrument-dark", PilotStyle.instrument, true), ("instrument-light", .instrument, false)] {
            Look.shared.style = style
            AppWindowController.applyLook(.shared, to: window)
            for page in Self.pages { for width in [1440, 1000, 760] {
                let file = "\(name)-\(page.rawValue)-\(width)"
                guard only.map(file.contains) ?? true else { continue }
                window.setContentSize(NSSize(width: CGFloat(width), height: 900))
                model.go(AppPlace(page))
                RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                frame.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(frame, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
            } }
        }
    }
}
}
#endif
