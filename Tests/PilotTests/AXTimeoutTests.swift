import AppKit
import Foundation
import Testing
@testable import Pilot

/// Card agent-bo-95423031: binds run inside the key tap, so an Accessibility ask to a hung app held every key for
/// macOS's default timeout. HungAppFixture stands in for the hung app: windowless, its own process, nobody's windows.
@MainActor
@Suite("Accessibility timeout")
struct AXTimeoutTests {
    final class Marker {}
    static let fixture = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "HungAppFixture")

    @Test("A window ask to a hung app gives up within a second")
    func hungAppAnswersFast() throws {
        let hung = Process(), out = Pipe()
        hung.executableURL = Self.fixture
        hung.arguments = ["10"]
        hung.standardOutput = out
        try hung.run()
        defer { hung.terminate() }
        _ = out.fileHandleForReading.availableData   // "hung": its main thread has stopped answering

        AXTimeout.applyEverywhere()
        let start = ContinuousClock.now
        #expect(AXWindow.windows(of: hung.processIdentifier).isEmpty)
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
