import AppKit
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Other apps' menu bar items on the top bar (card agent-bo-95422853), on a fake Accessibility tree: nothing is read
/// from or pressed in a real app.
@MainActor
@Suite("Menu bar apps")
struct MenuAppsTests {
    final class FakeExtras: MenuExtrasReading, @unchecked Sendable {
        var apps: [MenuExtrasApp] = [
            MenuExtrasApp(pid: 10, name: "Shottr", bundleId: "cc.ffitch.shottr"),
            MenuExtrasApp(pid: 11, name: "Finder", bundleId: "com.apple.finder"),
            MenuExtrasApp(pid: 12, name: "Control Centre", bundleId: "com.apple.controlcenter"),
            MenuExtrasApp(pid: 13, name: "Pilot", bundleId: "dev.banozz.pilot"),
        ]
        /// Read from the scan's threads while a test edits it, so behind a lock.
        private let lock = NSLock()
        private var _trees: [pid_t: [MenuExtrasRaw]] = [
            10: [MenuExtrasRaw(title: nil, description: "Shottr", help: nil, handle: MenuItemHandle("shottr" as NSString))],
            12: [MenuExtrasRaw(title: "Mon 5 Oct 21:00", description: "Clock", help: nil, handle: MenuItemHandle("clock" as NSString)),
                 MenuExtrasRaw(title: nil, description: nil, help: nil, handle: MenuItemHandle("cc" as NSString))],
            13: [MenuExtrasRaw(title: "2", description: nil, help: nil, handle: MenuItemHandle("pilot" as NSString))],
        ]
        var trees: [pid_t: [MenuExtrasRaw]] {
            get { lock.withLock { _trees } }
            set { lock.withLock { _trees = newValue } }
        }
        var timesOut: Set<pid_t> = []
        /// How long each app's read takes, so a test can ask again mid-scan.
        var delay: TimeInterval = 0
        var pressed: [MenuItemHandle] = []

        /// Whether the last running() ran on the main thread: NSWorkspace updates its list there (card agent-bo-95423303).
        var runningOnMain: Bool?

        /// How many scans asked for the running apps.
        var scans = 0

        func running() -> [MenuExtrasApp] { runningOnMain = Thread.isMainThread; scans += 1; return apps }
        func items(of pid: pid_t) throws -> [MenuExtrasRaw]? {
            let tree = trees[pid]
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if timesOut.contains(pid) { throw MenuExtrasTimeout() }
            return tree
        }
        func press(_ handle: MenuItemHandle) -> Bool { pressed.append(handle); return true }
        /// The items MenuBarAgent hosts by owning pid, as macOS 27.2 draws them.
        var agentItems: [pid_t: [MenuExtrasRaw]] = [:]
        func hosted(by agent: pid_t) throws -> [pid_t: [MenuExtrasRaw]] { agentItems }
    }

    static func make(_ fake: FakeExtras) -> MenuApps { MenuApps(reader: fake, ownPid: 13) }

    @Test("Apps with menu bar items are listed by name, items in order; an app with none and Pilot itself are left out")
    func lists() async {
        let fake = FakeExtras()
        let apps = Self.make(fake)
        await apps.refresh()
        #expect(apps.list.map(\.app.name) == ["Shottr", "Control Centre"])
        #expect(apps.list[1].items.map(\.label) == ["Clock", "Control Centre"])
        #expect(apps.list[0].items.map(\.label) == ["Shottr"])
        #expect(!apps.opensInPlace)
        // macOS 27.2: an app with no bar of its own lists MenuBarAgent's items for it, which open where they sit.
        fake.apps += [MenuExtrasApp(pid: 14, name: "MenuBarAgent", bundleId: MenuApps.menuBarAgent),
                      MenuExtrasApp(pid: 15, name: "Tailscale", bundleId: "io.tailscale.ipn.macsys")]
        fake.agentItems = [15: [MenuExtrasRaw(title: nil, description: "Tailscale", help: nil, handle: MenuItemHandle("tailscale" as NSString))]]
        await apps.refresh()
        #expect(apps.list.first { $0.app.pid == 15 }?.items.map(\.hosted) == [true])
        #expect(apps.list.first { $0.app.pid == 10 }?.items.map(\.hosted) == [false])
        #expect(apps.opensInPlace)
    }

    @Test("Control Centre's own button and its clock are left out, its other items kept; an app left with none is not listed (Sven on build 60)")
    func menuBarOnlyLeftOut() async {
        let fake = FakeExtras()
        fake.trees[12] = [
            MenuExtrasRaw(title: "Mon 5 Oct 21:00", description: "Clock", help: nil, handle: MenuItemHandle("clock" as NSString), identifier: "com.apple.menuextra.clock"),
            MenuExtrasRaw(title: nil, description: "Control Centre", help: nil, handle: MenuItemHandle("cc" as NSString), identifier: "com.apple.menuextra.controlcenter"),
            MenuExtrasRaw(title: nil, description: "Wi-Fi", help: nil, handle: MenuItemHandle("wifi" as NSString), identifier: "com.apple.menuextra.wifi"),
        ]
        let apps = Self.make(fake)
        await apps.refresh()
        #expect(apps.list.first { $0.app.pid == 12 }?.items.map(\.label) == ["Wi-Fi"])
        fake.trees[12]?.removeLast()
        await apps.refresh()
        #expect(apps.list.map(\.app.name) == ["Shottr"])
        // macOS 27: MenuBarAgent owns the button and the clock, unnamed; a named item of its stays.
        fake.apps.append(MenuExtrasApp(pid: 14, name: "MenuBarAgent", bundleId: MenuApps.menuBarAgent))
        fake.trees[14] = [MenuExtrasRaw(title: nil, description: nil, help: nil, handle: MenuItemHandle("agent cc" as NSString)),
                          MenuExtrasRaw(title: "", description: "", help: nil, handle: MenuItemHandle("agent clock" as NSString))]
        await apps.refresh()
        #expect(apps.list.map(\.app.name) == ["Shottr"])
        fake.trees[14]?.append(MenuExtrasRaw(title: nil, description: "Siri", help: nil, handle: MenuItemHandle("siri" as NSString)))
        await apps.refresh()
        #expect(apps.list.first { $0.app.pid == 14 }?.items.map(\.label) == ["Siri"])
    }

    @Test("The running apps are read on the main thread, where NSWorkspace updates them")
    func runningOnMain() async {
        let fake = FakeExtras()
        await Self.make(fake).refresh()
        #expect(fake.runningOnMain == true)
    }

    @Test("A click on an item presses that item, nothing else")
    func press() async {
        let fake = FakeExtras()
        let apps = Self.make(fake)
        await apps.refresh()
        #expect(await apps.press(apps.list[1].items[0]).value)
        #expect(fake.pressed == [MenuItemHandle("clock" as NSString)])
    }

    @Test("A read that times out leaves that app as it was; the others refresh")
    func timeout() async {
        let fake = FakeExtras()
        let apps = Self.make(fake)
        await apps.refresh()
        fake.timesOut = [10]
        fake.trees[12] = [MenuExtrasRaw(title: nil, description: "Wi-Fi", help: nil, handle: MenuItemHandle("wifi" as NSString))]
        await apps.refresh()
        #expect(apps.list.map(\.app.name) == ["Shottr", "Control Centre"])
        #expect(apps.list[0].items.map(\.label) == ["Shottr"])
        #expect(apps.list[1].items.map(\.label) == ["Wi-Fi"])
    }

    @Test("A refresh asked for during a scan runs once that scan ends, so a launch or a hover is never missed")
    func askedMidScan() async {
        let fake = FakeExtras()
        fake.delay = 0.05
        let apps = Self.make(fake)
        let first = Task { await apps.refresh() }
        try? await Task.sleep(for: .milliseconds(20))
        fake.trees[11] = [MenuExtrasRaw(title: nil, description: "Finder", help: nil, handle: MenuItemHandle("finder" as NSString))]
        await apps.refresh()
        await first.value
        for _ in 0..<200 where !apps.list.map(\.app.name).contains("Finder") { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(apps.list.map(\.app.name) == ["Shottr", "Finder", "Control Centre"])
    }

    @Test("No poll: while followed, the pointer coming over the apps lists them afresh, at most once per hoverGap (2026-10-10, idle CPU)")
    func hoverRefreshes() async throws {
        let fake = FakeExtras()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        // No real launch or quit scans in the middle of it.
        let apps = MenuApps(reader: fake, ownPid: 13, now: { clock }, watchLaunches: { _ in NSObject() })
        apps.start()
        #expect(try await SystemSamplerTests.wait { apps.list.map(\.app.name) == ["Shottr", "Control Centre"] })
        let scans = fake.scans
        fake.trees[11] = [MenuExtrasRaw(title: nil, description: "Finder", help: nil, handle: MenuItemHandle("finder" as NSString))]
        // Right after a scan, a hover asks nothing.
        apps.hovered()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.scans == scans)
        clock += MenuApps.hoverGap
        apps.hovered()
        #expect(try await SystemSamplerTests.wait { apps.list.map(\.app.name) == ["Shottr", "Finder", "Control Centre"] })
        apps.stop()
        #expect(!apps.isFollowing)
    }

    @Test("An item's label is its description, else its title, else its help, else its app's name")
    func labels() {
        #expect(MenuApps.label(MenuExtrasRaw(title: "T", description: "D", help: "H", handle: MenuItemHandle("x" as NSString)), app: "A") == "D")
        #expect(MenuApps.label(MenuExtrasRaw(title: "T", description: "", help: "H", handle: MenuItemHandle("x" as NSString)), app: "A") == "T")
        #expect(MenuApps.label(MenuExtrasRaw(title: nil, description: nil, help: "H", handle: MenuItemHandle("x" as NSString)), app: "A") == "H")
        #expect(MenuApps.label(MenuExtrasRaw(title: nil, description: nil, help: nil, handle: MenuItemHandle("x" as NSString)), app: "A") == "A")
    }

    @Test("An app's activation policy is asked once, not at every scan; again once its app is gone or the answers are old (2026-10-10, idle CPU)")
    func policiesKept() {
        var clock = Date(timeIntervalSince1970: 1_800_000_000), asks = 0
        var policies: [pid_t: NSApplication.ActivationPolicy] = [10: .accessory, 11: .prohibited]
        let cache = PolicyCache(now: { clock })
        func scan(_ pids: [pid_t]) -> [pid_t] {
            cache.allowed(pids, pid: { $0 }) { asks += 1; return policies[$0] ?? .regular }
        }
        #expect(scan([10, 11]) == [10])
        #expect(asks == 2)
        // The scans that follow ask nothing, even of an app that changed.
        clock += 30
        policies[11] = .accessory
        #expect(scan([10, 11]) == [10])
        #expect(asks == 2)
        // An app gone: its pid, reused, is asked afresh.
        #expect(scan([11]) == [])
        policies[10] = .prohibited
        #expect(scan([10, 11]) == [])
        #expect(asks == 3)
        // Past `life` every answer is asked again, so a changed policy is followed.
        clock += PolicyCache.life
        #expect(scan([10, 11]) == [11])
        #expect(asks == 5)
    }
}
