#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The top bar's right side with the mockup's readings (card agent-bo-95423010): Storage at 97 percent used draws amber,
/// CPU at 9 does not. The right-click menu and tooltips are drawn by macOS on screen only, so they are
/// lane 1's live check. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-3010 PILOT_RENDER_DIR=/tmp/pilot-renders-3010 swift test --filter BarActionsRenders`
@MainActor
@Suite("Bar actions renders")
struct BarActionsRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The top bar's readings, Storage at 97 percent", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to draw on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("bar-actions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let sampler = SystemSamplerTests.sampler(SystemSamplerTests.Counter())
        SharedLook.StatsRenders.seed(sampler)
        let readings = BarReadings(sound: SetupSound(audio: SetupSoundTests.FakeAudio()), look: Look(inputSources: SetupKeepAwakeTests.FakeSources()),
                                   readBattery: { nil }, readWiFi: { nil }, watchStats: { _ in Task {} })
        let sources = BarSources(readings: readings, observers: EngineObservers(), sampler: sampler,
                                 keepAwake: KeepAwake(power: SetupKeepAwakeTests.FakePower()),
                                 timer: ExtensionTimer(), pilotTitle: { "2" })
        let defaults = try #require(UserDefaults(suiteName: "pilot.renders.bar-actions"))
        defaults.removePersistentDomain(forName: "pilot.renders.bar-actions")
        let bar = BarItemsStore(defaults: defaults) { [:] }
        // The mockup's right side: CPU, Memory, Storage and Heat as text, each its own item, then the layout and Volume.
        bar.settings.set(.group, on: false)
        for kind in [BarKind.cpu, .memory, .storage, .heat, .keyboardLayout, .volume] { bar.settings.set(kind, on: true) }
        bar.settings.set(.network, on: false)
        bar.settings.set(.otherApps, on: false)
        for kind in [BarKind.volume, .keyboardLayout] { readings.hold(kind) }
        defer { for kind in [BarKind.volume, .keyboardLayout] { readings.release(kind) } }
        let view = TopBarView(screen: "CU34G4Z", sources: sources, store: bar).frame(width: 1100, height: 30)
        let host = NSHostingView(rootView: view)
        host.frame.size = NSSize(width: 1100, height: 30)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("top-bar.png"))
    }
}
}
#endif
