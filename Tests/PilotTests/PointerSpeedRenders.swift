#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Offscreen renders of System › Mouse's pointer speed (Sven, Q440 to Q442) and the tip its cycle key raises, on a fake
/// pointer, so nothing reads or moves the Mac's. Instrument on Nightwatch (a tip's surface is its HUD panel, which Toybox draws apart). Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter PointerSpeedRenders`
@MainActor
@Suite("Pointer speed renders")
struct PointerSpeedRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// A Mac at Normal 1.5 with one HyperX mouse; a write only changes the fake.
    final class FakePointer: PointerSystem, @unchecked Sendable {
        var speed: Double? = 1.5
        var writes: [Double] = []
        func read() -> Double? { speed }
        func write(_ speed: Double) { writes.append(speed); self.speed = speed }
        func mice() -> [String] { ["HyperX Pulsefire Core"] }
        func followPlugIns() {}
    }

    @Test("System › Mouse and the cycle tip", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's settings")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("pointer-speed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        look.style = .instrument
        look.themeID = "nightwatch"
        let fake = FakePointer()
        // A fresh suite: a render run keeps the app's defaults in the moved home, so a last run's pick would show.
        let pointer = PointerSpeed(system: fake, defaults: UserDefaults(suiteName: "pointer-render-\(UUID().uuidString)")!)
        pointer.refresh()
        let devices = SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: SetupBluetoothTests.FakeBluetooth(), wifi: SetupWiFiTests.FakeWiFi(),
                                   displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()),
                                   look: Look(inputSources: SetupKeepAwakeTests.FakeSources()), pointer: pointer)
        try writeRender(SetupPage(onScreen: true, devices: devices).frame(width: 1000, height: 1500).pilotTheme().background(Theme.background),
                        to: dir.appendingPathComponent("page.png"))
        pointer.pick(2)
        try writeRender(TipView(text: pointer.tip).padding(20).pilotTheme().background(Theme.background), to: dir.appendingPathComponent("tip.png"))
        try #require(fake.writes == [2.4], "only the fake moved")
    }
}
}
#endif
