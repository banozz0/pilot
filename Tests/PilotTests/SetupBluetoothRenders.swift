#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Offscreen renders of System's Wi-Fi and Bluetooth cards (Sven, 2026-11-26: "they open the actual Mac settings"): with
/// Bluetooth not asked yet, refused and allowed, at the window's default width, Tokyo Night and Folio. Each shot's page
/// holds its Wi-Fi Settings… and Bluetooth Settings… buttons, never pressed (they open System Settings). Opt-in like the
/// other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SetupBluetoothRenders`
@MainActor
@Suite("Setup Bluetooth renders")
struct SetupBluetoothRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Wi-Fi and Bluetooth cards render with Bluetooth not asked, refused and allowed", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's settings")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("setup-bluetooth")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let look = Look.shared
        // SwiftUI builds its accessibility tree only for an assistive client; this says one is here, so a button is found.
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer {
            NSApp.accessibilitySetValue(false, forAttribute: assistive)
            look.themeID = PilotTheme.defaultID; look.preview(spot: nil)
        }

        /// The page on fakes, Bluetooth answered `access`, at the width the window gives it (beside its 206 pt sidebar
        /// and hairline), its reads settled.
        func shot(_ name: String, access: PrivacyAccess) throws {
            let bt = SetupBluetoothTests.FakeBluetooth()
            bt.access = access
            let devices = SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: bt, wifi: SetupWiFiTests.FakeWiFi(),
                                       displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()),
                                       look: Look(inputSources: SetupKeepAwakeTests.FakeSources()))
            let host = NSHostingView(rootView: SetupPage(onScreen: true, devices: devices).frame(width: AppWindowController.size.width - 207, height: 1100)
                .pilotTheme().background(Theme.background))
            host.frame.size = host.fittingSize
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            defer { w.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            for button in ["Wi-Fi Settings…", "Bluetooth Settings…"] { #expect(Self.has(button, in: host), "no \(button) on \(name)") }
            #expect(bt.listed == 0 && bt.asked == 0, "the page listed or asked on \(name)")
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        for theme in ["tokyo-night", "folio"] {
            look.themeID = theme
            look.preview(spot: nil)
            for (state, access) in [("not-asked", PrivacyAccess.notAsked), ("refused", .denied), ("allowed", .allowed)] {
                try shot("\(state)-\(theme)", access: access)
            }
        }
    }

    /// Whether a button titled or labelled `name` is under `root`, as VoiceOver finds it. SwiftUI's nodes answer the
    /// accessibility selectors without declaring the protocol, so they are asked through Objective-C's dynamic lookup.
    private static func has(_ name: String, in root: AnyObject) -> Bool {
        if root.accessibilityRole?() == .button, root.accessibilityLabel?() == name || root.accessibilityTitle?() == name { return true }
        return (root.accessibilityChildren?() ?? []).contains { has(name, in: $0 as AnyObject) }
    }
}
}
#endif
