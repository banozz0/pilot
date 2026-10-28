import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Card agent-bo-95422973: swipe between workspaces is off by default and saved, its gesture tap runs only while it is on,
/// and the tap's touches reach the swipe. A fake tap only: no test creates an event tap or posts an event.
@MainActor
@Suite("Swipe workspaces")
struct SwipeWorkspacesTests {
    final class FakeTap: GestureTap {
        var starts = 0, stops = 0
        var installs = true
        var frame: (([Double]) -> Void)?
        func start(_ frame: @escaping ([Double]) -> Void) -> Bool {
            starts += 1
            if installs { self.frame = frame }
            return installs
        }
        func stop() { stops += 1; frame = nil }
    }

    static let item = LoginItem(service: .init(status: { .enabled }, register: {}, unregister: {}))
    func settings() throws -> (PilotSettings, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: testSuite()))
        return (PilotSettings(defaults: defaults, loginItem: Self.item), defaults)
    }

    @Test("Off by default; a change reaches the engine's hook and is read back at the next launch")
    func stored() throws {
        let (settings, defaults) = try settings()
        #expect(!settings.swipeWorkspaces)
        var applied = 0
        settings.onSwipeWorkspacesChange = { applied += 1 }
        settings.swipeWorkspaces = true
        #expect(applied == 1)
        #expect(defaults.bool(forKey: "windows.swipeWorkspaces"))
        #expect(PilotSettings(defaults: defaults, loginItem: Self.item).swipeWorkspaces)
    }

    @Test("The tap starts only while the swipe is on, once, and stops when it goes off")
    func armed() {
        let tap = FakeTap()
        let swipe = SwipeWorkspaces(tap: tap)
        swipe.update(on: false)
        #expect(tap.starts == 0 && !swipe.isRunning)
        swipe.update(on: true)
        swipe.update(on: true)
        #expect(tap.starts == 1 && swipe.isRunning)
        swipe.update(on: false)
        #expect(tap.stops == 1 && !swipe.isRunning)
    }

    /// Drawn offscreen and pressed where the words are, as LookPageTests does; PILOT_RENDER_DIR also saves the picture. A
    /// Vision read, so it runs only with PILOT_LIVE=1 (card agent-bo-95422962 keeps default runs free of them).
    @Test("Workspaces' Swipe block shows the swipe switch off, and a press on it turns the swipe on",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func row() throws {
        let (settings, _) = try settings()
        // The Swipe block lives on the Workspaces page (Sven's Q207 page map), drawn as wide as the host.
        let page = WorkspaceSwipeBlock(settings: settings)
            .padding(20).frame(width: 1000).background(Theme.background)
        if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
            try writeRender(page, to: URL(fileURLWithPath: dir).appendingPathComponent("tiling-mouse.png"), wait: 0.3)
        }
        try LookPageTests().hosted(page) { (host: NSView) throws in
            #expect(try LookPageTests.click(MouseDragSection.swipeLabel, in: host), "no swipe row in the Swipe block")
            #expect(settings.swipeWorkspaces)
        }
    }

    /// Opt-in like the other renders: `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SwipeWorkspacesTests`
    @Test("The Swipe block renders at the window's least width",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] != nil && ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil))
    func narrow() throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (settings, _) = try settings()
        let page = WorkspaceSwipeBlock(settings: settings)
            .frame(width: AppWindowController.minSize.width).background(Theme.background)
        try writeRender(page, to: dir.appendingPathComponent("tiling-760.png"), wait: 0.3)
    }

    @Test("A tap that cannot be made leaves the swipe off, and the next update tries again")
    func notInstalled() {
        let tap = FakeTap()
        tap.installs = false
        let swipe = SwipeWorkspaces(tap: tap)
        swipe.update(on: true)
        #expect(!swipe.isRunning)
        tap.installs = true
        swipe.update(on: true)
        #expect(tap.starts == 2 && swipe.isRunning)
    }

    @Test("The tap's touches reach the swipe: three moving left fire next once, moving right fire previous")
    func fires() throws {
        let tap = FakeTap()
        let swipe = SwipeWorkspaces(tap: tap)
        var fired: [WorkspaceSwipe.Fire] = []
        swipe.onSwipe = { fired.append($0) }
        swipe.update(on: true)
        let frame = try #require(tap.frame)
        for xs in [[0.5, 0.6, 0.7], [0.4, 0.5, 0.6], [0.3, 0.4, 0.5], [0.2, 0.3, 0.4], []] { frame(xs) }
        #expect(fired == [.next])
        for xs in [[0.2, 0.3, 0.4], [0.3, 0.4, 0.5], [0.4, 0.5, 0.6], [0.4, 0.5]] { frame(xs) }
        #expect(fired == [.next, .previous])
    }
}
