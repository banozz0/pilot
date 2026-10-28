import Foundation
import Testing
@testable import Pilot
import PilotCore

/// Update's reads (story 118, card agent-bo-95422882) through a fake reader: nothing here runs brew, npm, softwareupdate
/// or any upgrade. Needs Homebrew's brew to exist, as Update itself does.
@Suite("Update reads", .enabled(if: Homebrew.cli("brew") != nil))
struct UpdateReadTests {
    static let brew = #"{"formulae": [{"name": "atuin", "installed_versions": ["18.22.0"], "current_version": "18.23.0", "pinned": false}], "casks": []}"#
    static let npm = #"{"agent-browser": {"current": "0.28.0", "latest": "0.38.2", "location": "/opt/homebrew/lib/node_modules/agent-browser"}}"#

    static func fake(npm: String?) -> InstallModule.UpdateReader {
        { cli, arguments, success in
            switch URL(filePath: cli ?? "").lastPathComponent {
            case "brew": brew
            case "npm": success.contains(1) ? npm : nil
            default: nil
            }
        }
    }

    @Test("Homebrew's rows come without waiting on the other lists; failed npm, softwareupdate, mas, bun and cargo reads add nothing")
    func failedReads() async {
        #expect(await InstallModule.updateRows(read: Self.fake(npm: nil))?.map(\.item.key) == ["formula:atuin"])
        #expect(await InstallModule.moreUpdateRows(read: Self.fake(npm: nil)).isEmpty)
    }

    @Test("npm's list is read even though npm exits 1 when it lists anything, once per tree",
          .enabled(if: !CatalogueEntry.Check.copies(of: "npm").isEmpty))
    func npmRead() async {
        let rows = await InstallModule.moreUpdateRows(read: Self.fake(npm: Self.npm))
        #expect(rows.map(\.item) == [.npm("agent-browser", prefix: "/opt/homebrew")])
    }
}
