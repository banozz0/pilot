#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Binds' Save map (Q328, Atlas Q330), opt-in like the other renders: the PNG Save map writes, drawn from a fixture binds.json (Sven's
/// own preset: seven layers, plain combos and six mouse binds) on the US board, so the test Mac's keyboard layout changes
/// nothing. App icons come from the apps this Mac has; a missing app draws its kind's symbol.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter BindsMapRenders`
@MainActor
@Suite("Binds map renders")
struct BindsMapRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/binds-map/binds.json")

    @Test("Save map draws every layer and the mouse from a binds file", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's binds")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("binds-map")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        // A test run's store reads a file of its own (Binds.fileURL): the fixture goes there, then it loads again.
        let engine = Engine()
        try FileManager.default.createDirectory(at: engine.binds.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: Self.fixture).write(to: engine.binds.fileURL)
        engine.binds.load()
        let model = BindsMapModel(engine: engine, board: BindsKeyboard.Board(.ansi, compact: true),
                                  date: Date(timeIntervalSince1970: 1_792_368_000))
        #expect(model.layers.map(\.title) == ["Hyper", "Hyper + Shift", "Hyper + Ctrl", "Hyper + Alt", "Hyper + Shift + Ctrl",
                                              "Hyper + Ctrl + Alt", "Without Hyper"])
        #expect(model.keyCount == 135)
        #expect(model.mouse.count == 5)
        let png = try #require(BindsMapSheet.png(model))
        try png.write(to: dir.appendingPathComponent("binds-map.png"))
        // Sven's seven layers and the mouse fit one A4 page: 2480 by 3508 px.
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 2480)
        #expect(rep.pixelsHigh == 3508)
    }
}
#endif
