#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Setup, Clipboard and Pilot on the kit (card agent-bo-95422898, design round 4 section 7): what the Menu bar page
/// picks, and every old Pilot part landing on General. The pages themselves are drawn in the gated renders.
@MainActor
@Suite("Settings pages")
struct SettingsPagesTests {
    static func setupDevices() -> SetupDevices {
        SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: SetupBluetoothTests.FakeBluetooth(), wifi: SetupWiFiTests.FakeWiFi(),
                     displays: SetupDisplays(system: SetupDisplaysTests.FakeDisplays()), look: Look(inputSources: SetupKeepAwakeTests.FakeSources()),
                     defaults: SetupBluetoothTests.defaults())
    }

    static func setup(open: SetupSection = .sound, onScreen: Bool = false) -> SetupPage {
        SetupPage(onScreen: onScreen, open: open, devices: setupDevices())
    }

    static func clipboard() -> ClipboardSettingsView {
        ClipboardSettingsView(history: ClipboardHistory(defaults: UserDefaults(suiteName: testSuite())!))
    }

    @Test("What the menu bar shows is picked on the Menu bar page, not on Stats (card agent-bo-95423024)")
    func readingsOnMenuBar() {
        #expect(!StatsPage.intro.lowercased().contains("menu bar"), "Stats still says the menu bar is picked there")
    }

    @Test("Pilot's parts are its front and its More (simplify-pages T7): every old Pilot part and link lands on the page, a place on More on that tab with its block asked for")
    func pilotParts() {
        #expect(AppPage.general.tabs.map(\.title) == ["Pilot", "More"])
        for name in ["pilot", "general", "permissions", "otherApps", "about"] {
            let model = AppWindowModel(defaults: UserDefaults(suiteName: testSuite())!)
            let place = AppPlace.linked(URL(string: "pilot://open?page=\(name)")!)
            #expect(place?.page == .general, "\(name)")
            guard let place else { continue }
            model.go(place)
            #expect(model.page == .general && model.section(of: .general) == (place.section?.onMore ?? place.section)
                    && model.blockFocus == (place.section?.onMore == nil ? nil : place.section), "\(name)")
        }
    }

    @Test("General's old Data and Helpers parts land on their new tabs: Binds › More › Export and import, Install › Helpers (page map, 2026-10-17)")
    func movedParts() {
        for (link, section) in [("page=exportImport", AppSection.exportImport), ("page=general&tab=exportImport", .exportImport),
                                ("page=helpers", .helpers), ("page=general&tab=helpers", .helpers)] {
            let place = AppPlace.linked(URL(string: "pilot://open?\(link)")!)
            #expect(place?.section == section && place?.page == section.page, "\(link)")
        }
        #expect(AppSection.exportImport.page == .binds && AppSection.helpers.page == .install)
    }
}

extension SharedLook {
/// Offscreen renders of the three pages for Moody beside the approved artifact 5sh21HWjCjsWYAwWKTibcE: in
/// Lagoon and Workshop, folded and with More open; Setup with Sound and Wi-Fi open; Pilot with the permission granted
/// and missing. Opt-in like the other renders, in a moved home (an Engine is built):
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter SettingsPagesRenders`
@MainActor
@Suite("Settings pages renders")
struct SettingsPagesRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Setup, Clipboard and Pilot render in two themes", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let engine = Engine()
        engine.observers.tiler.seed(focused: "1", occupied: [OccupiedWorkspace(name: "1", apps: ["Ghostty"])])
        let look = Look.shared

        // The main actor is let go before each picture, longer for Setup, so its own reads (Wi-Fi, Bluetooth) finish.
        func shot(_ name: String, _ page: some View, height: CGFloat, settle: Duration = .milliseconds(150)) async throws {
            let host = NSHostingView(rootView: page.environment(engine).frame(width: 1000, height: height).pilotTheme().background(Theme.background))
            host.frame.size = host.fittingSize
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = host
            defer { w.close() }
            try await Task.sleep(for: settle)
            host.layoutSubtreeIfNeeded()
            try #require(snapshot(host, scale: 2)?.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        }
        for theme in ["lagoon", "workshop"] {
            look.themeID = theme
            look.preview(spot: nil)
            let tall: CGFloat = 1000
            try await shot("setup-\(theme)", SettingsPagesTests.setup(onScreen: true), height: tall, settle: .milliseconds(700))
            try await shot("setup-wifi-\(theme)", SettingsPagesTests.setup(open: .wifi, onScreen: true), height: tall, settle: .milliseconds(700))
            try await shot("clipboard-\(theme)", SettingsPagesTests.clipboard(), height: tall)
            engine.gate.seed(trusted: true)
            try await shot("general-\(theme)", GeneralPage(), height: tall)
            try await shot("general-acknowledgements-open-\(theme)", GeneralPage(more: true, acknowledgementsOpen: true), height: tall)
            engine.gate.seed(trusted: false)
            try await shot("general-permission-missing-\(theme)", GeneralPage(), height: tall)
            // The page map's two new tabs (2026-10-17).
            try await shot("helpers-\(theme)", HelpersBlock(installed: ["homebrew", "mas"]), height: 600)
            try await shot("binds-export-import-\(theme)", KitPage { ExportImportRows() }, height: 600)
        }
        look.themeID = PilotTheme.defaultID
        look.preview(spot: nil)
    }
}
}
#endif
