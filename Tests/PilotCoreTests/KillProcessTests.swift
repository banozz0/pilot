import Darwin
import Foundation
import Testing
@testable import PilotCore

/// Kill a process (card agent-bo-95422771): which signal a pick sends (its rows are Activity's, ActivityTests). The only
/// process ever signalled here is one this test started.
@Suite("Kill process")
struct KillProcessTests {
    @Test("A pick sends SIGTERM; the same pid again within 30 s sends SIGKILL, later SIGTERM again")
    func signals() {
        var kills = KillProcess.Kills()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(kills.signal(for: 7, now: t) == SIGTERM)
        #expect(kills.signal(for: 8, now: t) == SIGTERM)
        #expect(kills.signal(for: 7, now: t + 10) == SIGKILL)
        #expect(kills.signal(for: 8, now: t + 31) == SIGTERM)
    }

    @Test("Kill a process sits in System › Fix it and typing kill finds it first")
    func inTheMenu() {
        #expect(MenuLayout.rows[MenuLayout.system("Fix it")]?.contains(.action("system.killProcess")) == true)
        let rows = [MenuEntry(title: "Kill a process", target: .action("system.killProcess"), home: .system),
                    MenuEntry(title: "Skills", target: .app("app.skills"), home: .apps)]
        var nav = MenuNavigator(entries: rows)
        nav.query = "kill"
        #expect(nav.rows.first?.title == "Kill a process")
    }

    @Test("Sending the signal quits a process this test started")
    func killsItsOwnChild() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        #expect(KillProcess.send(SIGTERM, to: child.processIdentifier))
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    }
}
