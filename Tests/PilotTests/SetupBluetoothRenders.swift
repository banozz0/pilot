#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Offscreen renders of Setup › Bluetooth after macOS refused Pilot (card agent-bo-95422970): the Ask again and Open
/// Settings row, at the window's default and least widths, Lagoon and Workshop; then Ask again pressed
/// through the page's own button on a fake whose reset fails, so the sentence that sends you to Open Settings shows. Open
/// Settings is never pressed (it opens System Settings). Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SetupBluetoothRenders`
@MainActor
@Suite("Setup Bluetooth renders")
struct SetupBluetoothRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Bluetooth refused renders before and after a failed Ask again", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's settings")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("setup-bluetooth")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        let look = Look.shared
        // SwiftUI builds its accessibility tree only for an assistive client; this says one is here, so a press can land.
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer {
            NSApp.accessibilitySetValue(false, forAttribute: assistive)
            look.themeID = PilotTheme.defaultID; look.preview(spot: nil)
        }

        /// The page on fakes, Bluetooth open, Show pressed before, macOS's answer a refusal that Pilot cannot clear.
        func refused() -> (SetupPage, SetupBluetoothTests.FakeBluetooth) {
            let bt = SetupBluetoothTests.FakeBluetooth()
            bt.access = .denied
            bt.resetWorks = false
            let devices = SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: bt, wifi: SetupWiFiTests.FakeWiFi(),
                                       displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()),
                                       look: Look(inputSources: SetupKeepAwakeTests.FakeSources()), defaults: SetupBluetoothTests.defaults(shown: true))
            return (SetupPage(onScreen: true, open: .bluetooth, devices: devices), bt)
        }

        /// The page at the width the window gives it (beside its 206 pt sidebar and hairline), its reads settled; `press` is
        /// a button the page's own accessibility tree presses before the picture.
        func shot(_ name: String, window: CGFloat, press: String? = nil) async throws {
            let (page, bt) = refused()
            let host = NSHostingView(rootView: page.frame(width: window - 207, height: 620)
                .pilotTheme().background(Theme.background))
            host.frame.size = host.fittingSize
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            defer { w.close() }
            try await settle()
            if let press {
                try #require(Self.press(press, in: host), "no \(press) button on the page")
                try await settle()
                #expect(bt.resets == 1, "Ask again did not reach the reset")
            }
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }

        for theme in ["lagoon", "workshop"] {
            look.themeID = theme
            look.preview(spot: nil)
            for window in [AppWindowController.size.width, AppWindowController.minSize.width] {
                try await shot("refused-\(theme)-\(Int(window))", window: window)
            }
            try await shot("ask-again-failed-\(theme)-\(Int(AppWindowController.minSize.width))",
                           window: AppWindowController.minSize.width, press: "Ask again")
        }
    }

    /// Lets the page's own tasks (its Bluetooth read, a press's Task) finish.
    private func settle() async throws {
        Self.spin(0.3)
        try await Task.sleep(for: .milliseconds(300))
        Self.spin(0.3)
    }

    private static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Presses the first button titled or labelled `name` under `root`, as VoiceOver would; false when there is none.
    /// SwiftUI's nodes answer the accessibility selectors without declaring the protocol, so they are asked through
    /// Objective-C's dynamic lookup.
    private static func press(_ name: String, in root: AnyObject) -> Bool {
        if root.accessibilityRole?() == .button, root.accessibilityLabel?() == name || root.accessibilityTitle?() == name {
            return root.accessibilityPerformPress?() ?? false
        }
        for child in root.accessibilityChildren?() ?? [] where press(name, in: child as AnyObject) { return true }
        return false
    }
}
}
#endif
