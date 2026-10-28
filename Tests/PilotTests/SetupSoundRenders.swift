#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Offscreen renders of System › Sound with a monitor's speakers hidden (spec hide-rows): Sven's outputs on a fake, one
/// folded under Hidden (1), then Hidden pressed open through the page's own button so it shows dimmed with Show.
/// Instrument on Nightwatch, dark. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SetupSoundRenders`
@MainActor
@Suite("Setup Sound renders")
struct SetupSoundRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Sound with a hidden output, folded and open", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's settings")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("setup-sound")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let look = Look.shared
        let saved = (look.themeID, look.style)
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer {
            NSApp.accessibilitySetValue(false, forAttribute: assistive)
            (look.themeID, look.style) = saved
        }
        look.style = .instrument
        look.themeID = "nightwatch"

        let audio = SetupSoundTests.FakeAudio()
        audio.devices[.output] = [AudioDevice(id: 10, name: "24G1WG4", uid: "monitor-a"), AudioDevice(id: 11, name: "CU34G4Z", uid: "monitor-b"),
                                  AudioDevice(id: 12, name: "AB13X USB Audio", uid: "usb"), AudioDevice(id: 13, name: "Mac mini Speakers", uid: "speakers")]
        audio.defaults[.output] = 13
        audio.volumes[13] = 0.5
        audio.mutes[13] = false
        // The shared store, which a render run keeps in the moved home; the hide goes again after.
        HiddenRows.shared.set("monitor-a", hidden: true, in: .soundOutput)
        defer { HiddenRows.shared.set("monitor-a", hidden: false, in: .soundOutput) }
        let devices = SetupDevices(audio: audio, bluetooth: SetupBluetoothTests.FakeBluetooth(), wifi: SetupWiFiTests.FakeWiFi(),
                                   displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()),
                                   look: Look(inputSources: SetupKeepAwakeTests.FakeSources()), defaults: SetupBluetoothTests.defaults(shown: false))
        let host = NSHostingView(rootView: SetupPage(onScreen: true, devices: devices).frame(width: AppWindowController.minSize.width - 207, height: 900)
            .pilotTheme().background(Theme.background))
        host.frame.size = host.fittingSize
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        defer { w.close() }

        func shot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        PanelTestSupport.pump(0.6)
        try shot("hidden-folded")
        try DisplayNicknameUITests.press("Hidden, 1", in: host)
        // The fold animates; a quiet run loop comes before it ends.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        try shot("hidden-open")
    }
}
}
#endif
