import AppKit
import Testing
@testable import Pilot

/// Pilot keeps running when its last window goes (lane 1's P1 after card agent-bo-95422912): without SwiftUI's
/// MenuBarExtra, SwiftUI answers AppKit's "terminate after the last window closed?" with yes, so the first panel Pilot
/// hid at launch quit it, and Cmd+W on the app window would too (story 40: Cmd+W closes the window, Pilot keeps running).
@MainActor
@Suite("Stay running")
struct StayRunningTests {
    @Test("The app delegate answers no to terminating after the last window closes, rather than leaving it to SwiftUI")
    func lastWindowKeepsPilot() {
        let delegate: NSApplicationDelegate = AppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApplication.shared) == false)
    }
}
