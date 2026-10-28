#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Settings › General › Uninstall… (Q423) as the approved mockup lists it: the defaults ticked, and the once-only ask
/// with Pilot itself ticked, in Instrument dark and light. Rows handed in, nothing read from disk or trashed.
/// `PILOT_RENDER_DIR=<fresh dir> swift test --filter UninstallRenders`
extension SharedLook {
@MainActor
@Suite("Uninstall renders")
struct UninstallRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let items: [UninstallItem] = {
        let mb: Int64 = 1_000_000, none = [URL]()
        return [
            UninstallItem(kind: .dictation(.whisperTurbo), title: "Dictation model", detail: "Whisper large-v3 turbo", urls: none, bytes: 1_100 * mb),
            UninstallItem(kind: .voice, title: "Voice model", detail: "Kokoro", urls: none, bytes: 90 * mb),
            UninstallItem(kind: .giphy, title: "GIF cache", detail: "GIFs picked from GIPHY", urls: none, bytes: 3_600_000),
            UninstallItem(kind: .caches, title: "Caches", detail: nil, urls: none, bytes: 12 * mb),
            UninstallItem(kind: .clipboard, title: "Clipboard history", detail: "Items and image text", urls: none, bytes: 124 * mb),
            UninstallItem(kind: .fileIndex, title: "File index", detail: "Built again at the next file search", urls: none, bytes: 20 * mb),
            UninstallItem(kind: .extensions, title: "Extensions and their data", detail: nil, urls: none, bytes: 36 * mb),
            UninstallItem(kind: .webApps, title: "Web apps", detail: "3 apps in ~/Applications", urls: none, bytes: 2 * mb),
            UninstallItem(kind: .rest, title: "Binds, settings and reports", detail: "Everything else in Pilot's folder, and its preferences", urls: none, bytes: mb),
            UninstallItem(kind: .pilot, title: "Pilot.app, login item and the pilot command", detail: "Quits Pilot when done", urls: none, bytes: 67 * mb),
        ]
    }()

    @Test("The panel with the defaults ticked, and its ask", .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func render() throws {
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("uninstall")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.style = .instrument
        for theme in ["lagoon", "porcelain"] {
            look.themeID = theme
            let ask = UninstallModel(items: Self.items, phase: .confirming)
            ask.ticked.insert("pilot")
            for (name, model) in [("defaults", UninstallModel(items: Self.items)), ("ask", ask)] {
                try writeRender(UninstallSheet(model: model).pilotSheet().floating(), to: dir.appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }
}
}
#endif
