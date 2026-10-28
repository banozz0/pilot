import Foundation
import Testing
@testable import PilotCore

@Suite("Pilot block")
struct PilotBlockTests {
    static let sven = PilotBlock(
        rules: [.init(appId: "com.mitchellh.ghostty", workspace: "1"), .init(appId: "app.zen-browser.zen", workspace: "2")],
        floatApps: ["Vicinae", "Shottr", "Stats", "CodexBar", "Reminders MenuBar", "Bitwarden", "Tailscale", "FluidVoice",
                    "Fastpotify", "CuaDriver", "System Settings", "System Information", "Calculator", "Installer",
                    "Archive Utility", "Karabiner-Elements", "Karabiner-EventViewer", "Simulator"],
        floatTitles: ["Preferences", "Settings", "MiniPlayer"],
        gaps: .init(inner: 10, outer: 24))

    @Test("The user's gaps, two rules and float lists carry over from their file as it is today")
    func carryOverSven() throws {
        #expect(try PilotBlock.carryOver(from: SvenConfig.today) == Self.sven)
        #expect(try PilotBlock.carryOver(from: SvenConfig.migrated) == nil)
        // Migrated with the block Pilot wrote in place: the import reads the same settings back.
        #expect(try PilotBlock.carryOver(from: SvenConfig.migrated + "\n" + Self.sven.toml + "\n") == Self.sven)
        #expect(try PilotBlock.carryOver(from: "") == nil)
    }

    @Test("What Pilot wrote reads back as the same settings, so the import changes nothing under the user's fingers")
    func roundTrip() throws {
        #expect(try PilotBlock.carryOver(from: Self.sven.toml) == Self.sven)
        var other = PilotBlock(rules: [.init(appId: "com.apple.finder", workspace: "3")], floatApps: ["C++ Tool", "It's"],
                               gaps: .init(inner: 8, outer: 0))
        #expect(try PilotBlock.carryOver(from: other.toml) == other)
        other.floatTitles = ["Settings (beta)"]
        #expect(try PilotBlock.carryOver(from: other.toml) == other)
    }

    @Test("A callback Pilot cannot represent is refused with its line, so nothing is dropped on the way in")
    func carryOverRefusesUnknown() {
        let file = "a = 1\n\n[[on-window-detected]]\n    if.app-id = 'com.apple.finder'\n    run = ['layout floating', 'move-node-to-workspace 3']\n"
        #expect(throws: PilotBlockError.cannotCarryOver(line: 3)) { try PilotBlock.carryOver(from: file) }
        #expect(throws: PilotBlockError.cannotCarryOver(line: 1)) { try PilotBlock.carryOver(from: "gaps.inner.horizontal = 4\ngaps.inner.vertical = 8\n") }
        #expect(throws: PilotBlockError.cannotCarryOver(line: 1)) { try PilotBlock.carryOver(from: "gaps.outer.left = [{ monitor.main = 4 }, 8]\n") }
        // AeroSpace leaves an unset side at 0, so one side set is not a size for all of them.
        #expect(throws: PilotBlockError.cannotCarryOver(line: 1)) { try PilotBlock.carryOver(from: "gaps.inner.horizontal = 10\n") }
    }

    /// Card agent-bo-95423002 and the old tiler's reload: a failure with nothing on stderr carries stdout instead.
    @Test("A child that fails with nothing on stderr reports its stdout")
    func failureCarriesStdout() async {
        await #expect(throws: ChildProcess.Failure(tool: "sh", status: 3, message: "bad config")) {
            try await ChildProcess.run("/bin/sh", ["-c", "echo bad config; exit 3"])
        }
    }

    /// Card agent-bo-95423002: Clean shows Mole's section as it goes, so each line arrives while the child still runs.
    @Test("Each stdout line reaches the handler as it is printed, before the run returns, and stdout is still returned whole")
    func lines() async throws {
        let seen = Lines()
        // The second line waits for the first to be heard, so a handler that only ran at the end would stall to the timeout.
        let marker = FileManager.default.temporaryDirectory.appending(path: "pilot-lines-\(UUID().uuidString)").path
        seen.onLine = { if $0 == "one" { FileManager.default.createFile(atPath: marker, contents: nil) } }
        let out = try await ChildProcess.run("/bin/sh", ["-c", "echo one; while [ ! -e '\(marker)' ]; do sleep 0.05; done; printf two"],
                                             timeout: .seconds(5), lines: { seen.add($0) })
        try? FileManager.default.removeItem(atPath: marker)
        #expect(out == "one\ntwo")
        #expect(seen.all == ["one", "two"])
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var onLine: (String) -> Void = { _ in }
        var all: [String] { lock.withLock { lines } }
        func add(_ line: String) { lock.withLock { lines.append(line) }; onLine(line) }
    }
}

/// Card agent-bo-95422769: yabai floated Finder, and Sven kept that (2026-10-05); Pilot carries it into its always-float
/// list once, so a later removal on Settings › Workspaces sticks.
@Suite("yabai carry-over")
struct YabaiCarryTests {
    @Test("Finder joins the always-float apps once: not twice, and not after the carry-over ran")
    func finder() {
        var block = PilotBlock(floatAppIds: ["com.cleanshot.Shottr"])
        #expect(block.yabaiFloatsToCarry(alreadyCarried: true).isEmpty, "carried before: Sven may have removed it since")
        block.floatAppIds += block.yabaiFloatsToCarry(alreadyCarried: false)
        #expect(block.floatAppIds == ["com.cleanshot.Shottr", "com.apple.finder"])
        #expect(block.yabaiFloatsToCarry(alreadyCarried: false).isEmpty, "already there: nothing to write")
    }
}

/// C8: Always float takes apps by bundle id; a name from before moves to its app's id once, and a name no app answers to
/// stays, still matched by name, so no entry is lost.
@Suite("Float names by bundle id")
struct FloatNamesByBundleTests {
    @Test("Names an app answers to move to its bundle id, once and without a twin; the rest stay as names")
    func moves() throws {
        let ids = ["Finder": "com.apple.finder", "Code": "com.microsoft.VSCode", "Visual Studio Code": "com.microsoft.VSCode"]
        let block = PilotBlock(floatAppIds: ["com.apple.finder"], floatApps: ["Finder", "Code", "Gone App", "Visual Studio Code"])
        var moved = block
        let first = moved.moveFloatNames(to: ids), again = moved.moveFloatNames(to: ids)
        #expect(first && !again, "moved once, then nothing left to move")
        #expect(moved.floatAppIds == ["com.apple.finder", "com.microsoft.VSCode"])
        #expect(moved.floatApps == ["Gone App"])
        var gone = PilotBlock(floatApps: ["Gone App"])
        let none = gone.moveFloatNames(to: ids)
        #expect(!none && gone.floatApps == ["Gone App"])
    }

    @Test("Settings saved before C8 load with no float ids, their names kept")
    func oldSettingsLoad() throws {
        let old = #"{"rules":[],"floatApps":["Finder"],"floatTitles":[],"gaps":{"inner":10,"outer":24},"gapsOn":true}"#
        let block = try JSONDecoder().decode(PilotBlock.self, from: Data(old.utf8))
        #expect(block.floatAppIds.isEmpty && block.floatApps == ["Finder"])
        #expect(block.glide, "saved before Glide windows: it glides")
        let again = try JSONDecoder().decode(PilotBlock.self, from: JSONEncoder().encode(PilotBlock(floatAppIds: ["com.apple.finder"])))
        #expect(again.floatAppIds == ["com.apple.finder"])
    }
}
