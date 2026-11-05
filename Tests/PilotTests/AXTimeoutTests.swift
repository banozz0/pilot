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

    /// T59 (build 6): a hit test on the system-wide element landed on Pilot's own capture overlay, so AppKit answered
    /// in-process on a background thread, holding Accessibility's lock while it waited for SwiftUI's, which the main
    /// thread held as it asked Accessibility: Pilot and its key tap froze. The system-wide element is for the timeout
    /// alone; every ask goes to a named app that is never Pilot (AXFront, the Dock, Finder, the hovered app).
    @Test("No Accessibility ask goes through the system-wide element or to Pilot's own pid")
    func systemWideOnlySetsTheTimeout() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 100)
        var asks: [String] = []
        for file in files {
            for (i, line) in try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where (line.contains("AXUIElementCreateSystemWide()") && !line.contains("AXUIElementSetMessagingTimeout(")
                   || line.contains("AXUIElementCreateApplication(getpid())")
                   || line.contains("AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)"))
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                asks.append("\(file.lastPathComponent):\(i + 1)")
            }
        }
        #expect(asks.isEmpty, "system-wide or own-pid asks: \(asks)")
    }
}
