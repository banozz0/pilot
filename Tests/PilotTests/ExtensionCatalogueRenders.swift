#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Extensions › Catalogue (2026-10-10) drawn offscreen on the fixture catalogue: Claude Sessions not installed (its
/// install failed, so its card says why), Pomodoro installed at 0.9.0 (an update), Ports installed at its version. In
/// Instrument and Toybox, plus the page while the catalogue is read and when it could not be.
/// Temporary folders and a fixture source only; opt-in like the other renders:
/// `PILOT_RENDER_DIR=<fresh dir> swift test --filter ExtensionCatalogueRenders`
extension SharedLook {
@MainActor
@Suite("Extension catalogue renders")
struct ExtensionCatalogueRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The Catalogue tab renders loaded, reading and out of reach, in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil))
    func render() async throws {
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("extension-catalogue")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        let (loaded, dir) = try ExtensionCatalogueModelTests.model()
        defer { try? FileManager.default.removeItem(at: dir) }
        await loaded.open()
        await loaded.install(try #require(loaded.index?.entry("ports")))
        try ExtensionCatalogueModelTests.write(#"""
            {"id": "pomodoro", "title": "Pomodoro", "version": "0.9.0", "commands": [{"name": "focus", "title": "Focus", "mode": "no-view", "run": "run"}]}
            """#, as: "pomodoro", in: loaded.installer.extensions)
        // The fixture holds only Ports' files, so this install fails and its card says why.
        await loaded.install(try #require(loaded.index?.entry("claude-sessions")))
        await loaded.readInstalled()
        #expect(loaded.failures["claude-sessions"] != nil)

        let (failed, failedDir) = try ExtensionCatalogueModelTests.model(.init(down: true))
        defer { try? FileManager.default.removeItem(at: failedDir) }
        await failed.open()
        let (reading, readingDir) = try ExtensionCatalogueModelTests.model(.init(slow: true))
        defer { try? FileManager.default.removeItem(at: readingDir) }
        let read = Task { await reading.open() }
        defer { read.cancel() }
        try await Task.sleep(for: .milliseconds(50))

        func shot(_ name: String, _ model: ExtensionCatalogueModel, style: PilotStyle, theme: String,
                  size: CGSize = CGSize(width: 1000, height: 900)) throws {
            look.themeID = theme
            look.style = style
            let page = Ground { ExtensionCataloguePage(onScreen: false, model: model).frame(width: size.width, height: size.height) }
                .styled(.page(.extensions), look: look).pilotTheme(look: look)
            try writeRender(page, to: out.appendingPathComponent("\(name).png"), wait: 0.6)
        }
        try shot("instrument-loaded", loaded, style: .instrument, theme: "nightwatch")
        try shot("toybox-loaded", loaded, style: .toybox, theme: "toybox")
        try shot("instrument-failed", failed, style: .instrument, theme: "nightwatch", size: CGSize(width: 1000, height: 420))
        try shot("toybox-reading", reading, style: .toybox, theme: "toybox", size: CGSize(width: 1000, height: 300))
    }
}

/// The page on its style's ground, as the window lays it.
private struct Ground<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}
#endif
