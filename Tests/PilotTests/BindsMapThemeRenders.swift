#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds' Save map in the active theme (Q646, spec pilot-1-1 T5): BindsMapRenders' fixture drawn with MapInk in Void (Sven's),
/// Porcelain (light) and Tokyo Night (today's fixed look), each in its own colour scheme, so the builder sees the map follow the
/// theme and its kinds' colours in a grey theme. Opt-in like the other renders; it measures each page and prints its size,
/// and BindsMapRenders keeps the A4 check (2480 by 3508 px).
/// `CFFIXED_USER_HOME=/tmp/<fresh> PILOT_RENDER_DIR=/tmp/<fresh> swift test --filter BindsMapThemeRenders`
@MainActor
@Suite("Binds map theme renders")
struct BindsMapThemeRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Save map draws in Void, Porcelain and Tokyo Night", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's binds")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("binds-map")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        DisplayFaces.register()
        let engine = Engine()
        try FileManager.default.createDirectory(at: engine.binds.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: BindsMapRenders.fixture).write(to: engine.binds.fileURL)
        engine.binds.load()
        let model = BindsMapModel(engine: engine, board: BindsKeyboard.Board(.ansi, compact: true), date: Date(timeIntervalSince1970: 1_792_368_000))
        for id in ["void", "porcelain", "tokyo-night"] {
            let theme = try #require(PilotTheme.named(id))
            let renderer = ImageRenderer(content: BindsMapSheet(model: model, ink: MapInk(theme)).environment(\.colorScheme, theme.dark ? .dark : .light))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            #expect(rep.pixelsWide == 2480)
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("binds-map-\(id).png"))
            print("binds-map-\(id).png: \(rep.pixelsWide) by \(rep.pixelsHigh) px, A4 is 2480 by 3508")
        }
    }
}
#endif
