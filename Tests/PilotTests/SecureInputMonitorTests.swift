import AppKit
import Testing
@testable import Pilot
import PilotCore

/// The menu-bar secure-input state while a menu is open (card agent-bo-95422742).
@MainActor
@Suite("Secure input monitor")
struct SecureInputMonitorTests {
    @Test("Secure input turning on while a menu is open (the run loop in event-tracking mode) shows within 2 s")
    func refreshesDuringMenuTracking() {
        testApp()   // as in Pilot.app, whose NSApplication puts event tracking in the common modes
        var secure = false
        let monitor = SecureInputMonitor(isEnabled: { secure })
        monitor.start()

        // Pilot's dropdown open: AppKit runs the main run loop in event-tracking mode until the menu closes.
        secure = true
        let closesAt = Date().addingTimeInterval(2.2)
        while Date() < closesAt { RunLoop.main.run(mode: .eventTracking, before: closesAt) }

        #expect(monitor.isActive)
    }

    @Test("The once-a-second poll may fire late, so macOS groups it with Pilot's other wake-ups (2026-10-10, idle CPU)")
    func pollCoalesces() {
        let monitor = SecureInputMonitor(isEnabled: { false })
        monitor.start()
        #expect(monitor.timer?.tolerance == SecureInputMonitor.tolerance)
        monitor.pause()
        #expect(monitor.timer == nil)
    }
}

/// Sven, 2026-10-08: Bitwarden's unlock field turned secure input on and Pilot seemed dead (Hyper, Hyper+V, the
/// app). Pilot says so in a tip naming the app that holds it, never works around it.
@MainActor
@Suite("Secure input tip")
struct SecureInputTipTests {
    @Test("Secure input coming on tips once, naming the app that holds it; again only an hour later")
    func tipsOncePerAppPerHour() {
        var secure = false, holder: String? = "Bitwarden", clock = Date(timeIntervalSince1970: 1_800_000_000)
        var tips: [String] = []
        let monitor = SecureInputMonitor(isEnabled: { secure }, owner: { (42, holder) }, isAlive: { _ in true }, now: { clock })
        monitor.onTip = { tips.append($0) }

        secure = true; monitor.refresh()
        monitor.refresh()   // still on: no second tip
        #expect(tips == ["A password field in Bitwarden has the keyboard, so Hyper waits"])

        secure = false; monitor.refresh()
        secure = true; clock += 600; monitor.refresh()   // Bitwarden again within the hour
        #expect(tips.count == 1)

        secure = false; monitor.refresh()
        holder = nil; secure = true; monitor.refresh()   // another holder, unknown
        #expect(tips.last == "A password field has the keyboard, so Hyper waits")
        #expect(monitor.holder == .unknown)

        secure = false; monitor.refresh()
        holder = "Bitwarden"; secure = true; clock += 3600; monitor.refresh()
        #expect(tips.count == 3)
    }

    @Test("Pilot's own password field and the login window never tip", arguments: [SecureInputMonitor.pilot, "loginwindow"])
    func quietHolders(_ app: String) {
        var secure = false
        var tips: [String] = []
        let monitor = SecureInputMonitor(isEnabled: { secure }, owner: { (42, app) }, isAlive: { _ in true })
        monitor.onTip = { tips.append($0) }
        secure = true; monitor.refresh()
        #expect(tips.isEmpty)
        #expect(monitor.isActive)
    }
}

/// 2026-10-21: after a reboot Vesktop turned secure input on, quit, and the lock stayed; macOS still named it, and after a
/// lock and unlock named the login window. Pilot names the app, says when it quit, and never blames the login window.
@MainActor
@Suite("Secure input holder")
struct SecureInputHolderTests {
    @Test("The holder is named while it runs; its quitting while secure input stays on shows on the next tick")
    func quitHolderIsStuck() {
        var secure = false, alive = true
        let monitor = SecureInputMonitor(isEnabled: { secure }, owner: { (695, "Vesktop") }, isAlive: { _ in alive })
        #expect(monitor.holder == nil)
        secure = true; monitor.refresh()
        #expect(monitor.holder == .app("Vesktop"))
        alive = false; monitor.refresh()
        #expect(monitor.holder == .quit("Vesktop"))
        secure = false; monitor.refresh()
        #expect(monitor.holder == nil)
    }

    @Test("The login window named while the screen is unlocked names nobody; an unlock reads the owner again")
    func loginWindowIsUnknown() {
        var owner: SecureInputMonitor.Owner = (695, "Vesktop")
        let monitor = SecureInputMonitor(isEnabled: { true }, owner: { owner }, isAlive: { _ in true })
        #expect(monitor.holder == .app("Vesktop"))
        monitor.start()
        monitor.pause()   // the screen locks
        owner = (177, "loginwindow")
        monitor.resume()
        #expect(monitor.holder == .unknown)
        monitor.pause()
    }

    @Test("Each holder's words: the app by name, a quit app with how to clear it, never the login window")
    func words() {
        #expect(SecureInputHolder.app("Vesktop").title == "Vesktop has the keyboard (a password field)")
        #expect(SecureInputHolder.quit("Vesktop").title == "Vesktop quit but left the keyboard locked")
        #expect(SecureInputHolder.quit(nil).title == "An app quit but left the keyboard locked")
        #expect(SecureInputHolder.quit("Vesktop").detail.contains("logging out always clears it"))
        #expect(!SecureInputHolder.unknown.title.contains("loginwindow"))
    }
}
