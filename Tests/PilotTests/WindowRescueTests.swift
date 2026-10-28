import CoreGraphics
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Card agent-bo-95422999, AC5: rescue brings back every window a tiler left off screen (a Pilot crash), with fake
/// windows and screens: nothing real moves.
@MainActor
@Suite("Window rescue on fake frames")
struct WindowRescueTests {
    /// Sven's wide main display and a portrait one to its right, in Accessibility coordinates.
    static let screens = [CGRect(x: 0, y: 0, width: 3440, height: 1440), CGRect(x: 3440, y: 0, width: 1440, height: 2560)]
    static let visible = CGRect(x: 0, y: 25, width: 3440, height: 1415)

    /// Each app's one window, moved in place.
    @MainActor final class FakeWindows {
        var frames: [String: CGRect]
        init(_ frames: [String: CGRect]) { self.frames = frames }
        func list() -> [RescueWindow] { frames.keys.sorted().map { app in RescueWindow(frame: frames[app]!) { self.frames[app] = $0 } } }
    }

    @Test("Every stranded window lands inside the main screen's visible frame; one on screen stays put")
    func bringsBackEveryStrandedWindow() {
        let fake = FakeWindows([
            // Parked in a free corner by the engine with a pixel showing, as the tiler hides a workspace's windows (the
            // main screen's bottom-right corner touches the portrait one, so its bottom-left is used).
            "Finder": CGRect(x: -1199, y: 1439, width: 1200, height: 800),
            "TextEdit": CGRect(x: 4879, y: 2559, width: 900, height: 700),
            // Left far off every screen.
            "Notes": CGRect(x: -9000, y: 9000, width: 800, height: 600),
            "Safari": CGRect(x: 100, y: 100, width: 1600, height: 1000),
        ])
        let before = fake.frames
        let tiler = TilerService(tip: { _ in })
        let rescue = WindowRescue(tiler: tiler, mac: WindowRescue.Mac(windows: { fake.list() }, screens: { Self.screens },
                                                                           landing: { Self.visible }))
        rescue.bringBackQuietly()
        for app in ["Finder", "TextEdit", "Notes"] {
            #expect(Self.visible.contains(fake.frames[app]!), "\(app) at \(fake.frames[app]!)")
            #expect(!Rescue.isStranded(fake.frames[app]!, screens: Self.screens))
        }
        #expect(fake.frames["Safari"] == before["Safari"])
        let landed = fake.frames
        rescue.bringBackQuietly()
        #expect(fake.frames == landed)
    }
}
