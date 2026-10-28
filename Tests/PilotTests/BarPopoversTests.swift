#if DEBUG
import AppKit
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// The top bar's Sound, Keyboard and Displays popovers (Sven on build 36): Sound lists sound alone, Keyboard its layouts
/// with a click switching, Displays each screen with its brightness only where a route reaches it. Every one on fakes:
/// no test changes the Mac's volume, layout, brightness or display mode. Read through the accessibility tree, as
/// FillPagesTests reads a panel; the renders are opt-in in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter BarPopoversTests`
@MainActor
@Suite("Bar popovers")
struct BarPopoversTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    /// The wide screen at 60 Hz, so its size offers two rates.
    static let wide60 = DisplayMode(id: 3, width: 3440, height: 1440, pixelWidth: 3440, refresh: 60)

    /// The fake screens (SetupDisplaysTests: a wide one with two sizes and, here, two rates, a portrait one with one mode)
    /// and their brightness: screen 1 answers Apple's call at 50 %, screen 2 no route.
    static func displays() async -> (SetupDisplaysTests.FakeDisplays, SetupDisplays, Brightness) {
        let fake = SetupDisplaysTests.FakeDisplays()
        fake.modesByDisplay[1]?.append(wide60)
        let displays = SetupDisplays(system: fake, after: SetupKeepAwakeTests.FakeTime().after)
        let brightness = Brightness(hardware: ControlSystemVerbTests.FakeHardware())
        await brightness.refresh([.init(id: 1, appleAllowed: true), .init(id: 2, appleAllowed: true)])
        return (fake, displays, brightness)
    }

    static func connectionScreen(_ id: UInt32, _ name: String, _ identity: String, state: ConnectionState = .on, main: Bool = false,
                                 supported: Bool = true) -> ConnectionScreen {
        ConnectionScreen(id: id, name: name, identity: identity, state: state, main: main, builtIn: false, asleep: false,
                         frame: .init(x: 0, y: 0, width: 1920, height: 1080), mode: SetupDisplaysTests.wide, rotation: 0,
                         supported: supported)
    }

    final class ConnectionStore: DisplayConnectionsStore {
        var value: DisplayConnectionsCheckpoint
        init(_ value: DisplayConnectionsCheckpoint = .init()) { self.value = value }
        func load() throws -> DisplayConnectionsCheckpoint { value }
        func save(_ checkpoint: DisplayConnectionsCheckpoint) throws { value = checkpoint }
    }

    final class ConnectionHardware: DisplayConnectionsBackend, @unchecked Sendable {
        var screens: [ConnectionScreen]
        var failure: Error?
        init(_ screens: [ConnectionScreen]) { self.screens = screens }
        func read(remembered: [ConnectionScreen]) async throws -> [ConnectionScreen] {
            if let failure { throw failure }
            return screens
        }
        func setEnabled(_ enabled: Bool, screen: ConnectionScreen) async throws {}
        func restoreLayout(_ screens: [ConnectionScreen]) async throws {}
    }

    static func connectionDisplays(_ screens: [ConnectionScreen], store: ConnectionStore = .init()) -> (SetupDisplays, DisplayConnections) {
        let connections = DisplayConnections(backend: ConnectionHardware(screens), store: store)
        return (SetupDisplays(system: SetupDisplaysTests.FakeDisplays(), after: SetupKeepAwakeTests.FakeTime().after, connections: connections), connections)
    }

    /// The labels `view` shows in a hidden panel; `press` presses the first element labelled so first.
    static func labels(_ view: some View, press: String? = nil) -> [String] {
        let panel = PanelTestSupport.open(view)
        defer { panel.close() }
        // SwiftUI builds its accessibility tree only for an assistive client; this says one is here.
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        PanelTestSupport.pump()
        guard let root = panel.contentView else { return [] }
        if let press, let element = element(press, in: root) {
            _ = element.accessibilityPerformPress?()
            PanelTestSupport.pump()
        }
        return texts(in: root)
    }

    /// Every label, and every static text's words (SwiftUI gives a Text its words as its value), under `root`.
    static func texts(in root: AnyObject) -> [String] {
        let value: (() -> Any?)? = root.accessibilityValue
        let own = [root.accessibilityLabel?() ?? nil, root.accessibilityRole?() == .staticText ? value?() as? String : nil]
        return own.compactMap { $0 }.filter { !$0.isEmpty } + (root.accessibilityChildren?() ?? []).flatMap { texts(in: $0 as AnyObject) }
    }

    private static func element(_ label: String, in root: AnyObject) -> AnyObject? {
        if (root.accessibilityLabel?() ?? nil) == label { return root }
        return (root.accessibilityChildren?() ?? []).lazy.compactMap { element(label, in: $0 as AnyObject) }.first
    }

    static func enabled(_ label: String, in view: some View) -> Bool? {
        let panel = PanelTestSupport.open(view)
        defer { panel.close() }
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        PanelTestSupport.pump()
        guard let root = panel.contentView, let element = element(label, in: root) else { return nil }
        return element.isAccessibilityEnabled?()
    }

    @Test("Sound lists the level and the outputs, and no keyboard layout (Sven on build 36: British – PC and Next sat under the outputs)", .pilotFocus)
    func soundIsSoundOnly() {
        let sound = SetupSound(audio: SetupSoundTests.FakeAudio())
        sound.start()
        defer { sound.stop() }
        let shown = Self.labels(SoundPopover(sound: sound).pilotTheme())
        for name in ["Sound", "Output", "MacBook Speakers", "LG HDR 4K", "TV"] { #expect(shown.contains(name), "\(name) in \(shown)") }
        for gone in ["Keyboard", "Next", "British – PC"] { #expect(!shown.contains(gone), "\(gone) in \(shown)") }
    }

    @Test("Keyboard lists every enabled layout and Next; a click on one switches to it", .pilotFocus)
    func keyboardLists() {
        let layouts = BarReadingsTests.Sources(), look = Look(inputSources: layouts)
        look.followLayouts()
        #expect(look.currentLayout?.name == "British – PC")
        let shown = Self.labels(KeyboardPopover(look: look).pilotTheme(), press: "Spanish – ISO")
        for name in ["Keyboard", "Next", "ABC", "British – PC", "Spanish – ISO"] { #expect(shown.contains(name), "\(name) in \(shown)") }
        #expect(layouts.selected == ["spanish"] && look.currentLayout?.name == "Spanish – ISO")
    }

    @Test("Displays lists each screen; a slider only where a route reaches it, the size and rate pickers only where it has a choice", .pilotFocus)
    func displaysLists() async {
        let (fake, displays, brightness) = await Self.displays()
        let shown = Self.labels(DisplaysPopover(displays: displays, brightness: brightness).pilotTheme())
        for name in ["Displays", "CU34G4Z", "24G1WG4", "main", "CU34G4Z brightness", "Resolution, 3440 × 1440", "Refresh rate, 100 Hz", "Displays in Pilot"] {
            #expect(shown.contains(name), "\(name) in \(shown)")
        }
        #expect(!shown.contains("24G1WG4 brightness"), "screen 2 has no route: \(shown)")
        #expect(!shown.contains { $0.hasPrefix("Resolution, 1440") }, "screen 2 has one mode: \(shown)")
        #expect(fake.applied.isEmpty, "showing it changes no mode")
    }

    @Test("Connection rows retain an OFF display and suppress its controls; validated displays omit the attended test", .pilotFocus)
    func connectionRows() async {
        let store = ConnectionStore(.init(verifiedIdentities: ["wide": ProcessInfo.processInfo.operatingSystemVersionString]))
        let (displays, connections) = Self.connectionDisplays([
            Self.connectionScreen(1, "CU34G4Z", "wide", main: true),
            Self.connectionScreen(2, "24G1WG4", "portrait", state: .off),
        ], store: store)
        await connections.refresh()
        let brightness = Brightness(hardware: ControlSystemVerbTests.FakeHardware())
        await brightness.refresh([.init(id: 1, appleAllowed: true), .init(id: 2, appleAllowed: true)])
        let shown = Self.labels(DisplaysPopover(displays: displays, brightness: brightness).pilotTheme())
        for label in ["CU34G4Z", "24G1WG4", "OFF", "Restore All Displays", "CU34G4Z brightness"] {
            #expect(shown.contains(label), "\(label) in \(shown)")
        }
        #expect(!shown.contains("24G1WG4 brightness"), "OFF keeps no brightness control: \(shown)")
        #expect(!shown.contains("Test connection"), "validated display suppresses the attended test: \(shown)")
    }

    @Test("Metadata-less display rows reconcile independently when one disappears and returns", .pilotFocus)
    func metadataLessRowsStayDistinct() async throws {
        let first = Self.connectionScreen(1, "Display 1", "-:-:-:-:-", supported: false)
        let second = Self.connectionScreen(2, "Display 2", "-:-:-:-:-", supported: false)
        #expect(Self.connectionScreen(1, "Known", "serial").rowID == Self.connectionScreen(7, "Known", "serial").rowID)
        let hardware = ConnectionHardware([first, second])
        let connections = DisplayConnections(backend: hardware, store: ConnectionStore())
        let displays = SetupDisplays(system: SetupDisplaysTests.FakeDisplays(), connections: connections)
        await connections.refresh()
        let panel = PanelTestSupport.open(DisplaysPopover(displays: displays, brightness: nil).pilotTheme())
        defer { panel.close() }
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        PanelTestSupport.pump()
        let root = try #require(panel.contentView)
        #expect(Self.texts(in: root).contains(first.name) && Self.texts(in: root).contains(second.name))
        for inventory in [[second], [second, first], [first]] {
            hardware.screens = inventory
            await connections.refresh()
            PanelTestSupport.pump()
            let shown = Self.texts(in: root)
            for screen in [first, second] {
                #expect(shown.contains(screen.name) == inventory.contains(screen), "\(screen.name): \(shown)")
            }
        }
    }

    @Test("The last usable display cannot be toggled, and Restore All remains reachable after an unknown read", .pilotFocus)
    func connectionSafetyAndRecovery() async {
        let (single, connections) = Self.connectionDisplays([Self.connectionScreen(1, "Only", "only", main: true)])
        await connections.refresh()
        let view = DisplaysPopover(displays: single, brightness: nil).pilotTheme()
        #expect(Self.enabled("Only connection", in: view) == false)

        let (unknown, failed) = Self.connectionDisplays([Self.connectionScreen(9, "Remembered", "remembered", state: .unknown, supported: false)])
        await failed.refresh()
        let shown = Self.labels(DisplaysPopover(displays: unknown, brightness: nil).pilotTheme())
        #expect(shown.contains("Remembered") && shown.contains("Restore All Displays"), "\(shown)")
    }

    @Test("A size picked in Displays waits for Keep, as on System's card", .pilotFocus)
    func displaysPending() async {
        let (fake, displays, brightness) = await Self.displays()
        displays.start()
        displays.pick(SetupDisplaysTests.wideLow, for: 1)
        let shown = Self.labels(DisplaysPopover(displays: displays, brightness: brightness).pilotTheme())
        #expect(shown.contains("Keep") && shown.contains("Go back"), "\(shown)")
        #expect(fake.applied.map(\.permanently) == [false])
    }

    @Test("The Sound, Keyboard and Displays popovers render in Instrument and Toybox",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try ClockRenders.dir("bar-popovers")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let sound = SetupSound(audio: SetupSoundTests.FakeAudio()), layouts = Look(inputSources: BarReadingsTests.Sources())
        sound.start()
        defer { sound.stop() }
        let (_, displays, brightness) = await Self.displays()
        let (_, waiting, _) = await Self.displays()
        waiting.start()
        waiting.pick(SetupDisplaysTests.wideLow, for: 1)
        for (style, theme) in [(PilotStyle.instrument, "nightwatch"), (.toybox, "toybox")] {
            look.style = style
            look.themeID = theme
            let tokens = StyleTokens.of(style, theme: look.theme)
            let popovers: [(String, AnyView)] = [("sound", AnyView(SoundPopover(sound: sound))), ("keyboard", AnyView(KeyboardPopover(look: layouts))),
                                                 ("displays", AnyView(DisplaysPopover(displays: displays, brightness: brightness))),
                                                 ("displays-waiting", AnyView(DisplaysPopover(displays: waiting, brightness: brightness)))]
            for (name, popover) in popovers {
                try writeRender(popover.styled(.barPopovers, look: look).pilotTheme(look: look).padding(24).background(Color(tokens.colors.canvas)),
                                to: dir.appendingPathComponent("\(style.rawValue)-\(name).png"), wait: 0.5)
            }
        }
    }
}
}
#endif
