import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423031: messages sent Sven to Settings › Conflicts, Settings › General and Settings › Tiling, pages
/// renamed when the window was cut down to twelve. They now name the page and part from the titles the window shows.
@Suite("Page names in messages")
struct PageNamesTests {
    @Test("A part's path is its page and its own title, as the window shows them")
    func paths() {
        #expect(AppPlace(.conflicts).path == "Binds › Conflicts")
        #expect(AppPlace(.permissions).path == "Pilot › More › Permissions")
        #expect(AppPlace(.reports).path == "Update & Clean › Reports" && AppPlace(.stats).path == "Stats" && AppPlace(.tiling).path == "Tiling")
    }

    @Test("Onboarding's clash row sends the user to Binds › Conflicts")
    func onboardingConflicts() {
        var s = Onboarding.Status()
        s.clashes = 2
        #expect(Onboarding.Row.conflicts.detail(s).hasSuffix("any time in Binds › Conflicts."))
    }

    @Test("No string in Sources names a Settings › page: Pilot's window has no page called Settings")
    func noSettingsPage() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources").standardized
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100)
        // A string literal naming Settings › that is not macOS's own System Settings ›.
        func namesSettings(_ line: Substring) -> Bool {
            line.matches(of: /"[^"]*"/).contains { $0.output.replacing("System Settings ›", with: "").contains("Settings ›") }
        }
        let found = try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains("Settings ›") && namesSettings($0) }
                .map { "\(file.lastPathComponent): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        #expect(found.isEmpty, "\(found)")
    }
}
