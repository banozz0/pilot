#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The This window ring (Q415, Arrange added in Q194) as the ring's panel draws it: its eight wedges with the engine's names,
/// To next workspace aimed, then inside Arrange with Middle third aimed, in Instrument on Tokyo Night, solid. Opt-in like
/// the other renders, in a moved home, whose rings.json the run reads and upgrades as Pilot would:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter RingRenders`
extension SharedLook {
@MainActor
@Suite("Ring renders")
struct RingRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("This window renders with its eight wedges, the next-workspace one aimed, and inside Arrange",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func thisWindow() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.style = .instrument
        look.themeID = "tokyo-night"
        // Solid: the glass would show whatever sits behind the test window.
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }

        let engine = Engine()
        let ring = try #require(engine.rings.store.rings.rings.first)
        #expect(ring.id == Rings.window.id, "This window is the first ring")
        let controller = RingController(store: engine.rings.store)
        controller.label = { engine.action($0)?.label }
        var session = RingSession(wheel: [ring])
        controller.keys = { engine.binds.store.trigger(for: $0)?.label }
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("ring")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, path, place) in [("this-window", [Int](), 1), ("this-window-arrange", [4], 0)] {
            session.pick(path: path, place: place)
            let model = controller.model(session, states: [:], roles: [:])
            let view = RingView(model: model).styled(.menu, look: look).pilotTheme(look: look)
                .padding(28).background(Color(red: 0.03, green: 0.06, blue: 0.1))
            try writeRender(view, to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
}
#endif
