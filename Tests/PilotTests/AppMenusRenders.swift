#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The top bar with App menus off (as on main) and on, over a fake TextEdit menu bar (card agent-bo-95423015); Calm's
/// strip draws see-through offscreen, so its PNGs want a dark ground behind them. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-3015 PILOT_RENDER_DIR=/tmp/pilot-renders-3015 swift test --filter AppMenusRenders`
@MainActor
@Suite("App menus renders")
struct AppMenusRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The top bar before and after App menus, TextEdit in front", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to draw on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("app-menus")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let sampler = SystemSamplerTests.sampler(SystemSamplerTests.Counter())
        SharedLook.StatsRenders.seed(sampler)
        let menus = AppMenus(reader: AppMenusTests.fake(), front: { AppMenusTests.textEdit }, center: NotificationCenter())
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: SetupKeepAwakeTests.FakeSources()),
                                   appMenus: menus, readBattery: { nil }, readWiFi: { nil }, watchStats: { _ in Task {} })
        let sources = BarSources(readings: readings, observers: EngineObservers(), sampler: sampler,
                                 keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: ExtensionTimer(), pilotTitle: { "2" })
        let defaults = try #require(UserDefaults(suiteName: "pilot.renders.app-menus"))
        defaults.removePersistentDomain(forName: "pilot.renders.app-menus")
        let bar = BarItemsStore(defaults: defaults) { [:] }
        bar.settings.set(.otherApps, on: false)
        readings.hold(.appMenus)
        defer { readings.release(.appMenus) }
        await menus.reading?.value
        for on in [false, true] {
            bar.settings.set(.appMenus, on: on)
            let host = NSHostingView(rootView: TopBarView(screen: "CU34G4Z", sources: sources, store: bar).frame(width: 1100, height: 30))
            host.frame.size = NSSize(width: 1100, height: 30)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = host
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
                .write(to: dir.appendingPathComponent("\(on ? "after" : "before").png"))
            window.close()
        }
    }
}
}
#endif
