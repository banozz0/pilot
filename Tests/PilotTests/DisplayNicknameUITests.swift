import AppKit
import PilotCore
import SwiftUI
import Testing
import Observation
@testable import Pilot

@MainActor @Suite("Display nickname UI", .serialized)
struct DisplayNicknameUITests {
    static let first = DisplayNicknameTests.wideUUID
    static let second = DisplayNicknameTests.portraitUUID

    static func element(_ label: String, in root: AnyObject) -> AnyObject? {
        if (root.accessibilityLabel?() ?? nil) == label { return root }
        return (root.accessibilityChildren?() ?? []).lazy.compactMap { element(label, in: $0 as AnyObject) }.first
    }

    static func press(_ label: String, in root: AnyObject) throws {
        let button = try #require(element(label, in: root))
        #expect(button.accessibilityPerformPress?() == true)
        PanelTestSupport.pump()
    }

    static func identifier(_ id: String, in root: AnyObject) -> AnyObject? {
        if (root.accessibilityIdentifier?() ?? nil) == id { return root }
        return (root.accessibilityChildren?() ?? []).lazy.compactMap { identifier(id, in: $0 as AnyObject) }.first
    }

    static func type(_ value: String, into panel: NSPanel) throws {
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        let field = try #require(panel.contentView.flatMap { field(in: $0) })
        #expect(panel.makeFirstResponder(field))
        field.selectText(nil)
        PanelTestSupport.type(value, into: panel)
    }

    @Test("Rename is reachable from the real display popover without changing hardware", .pilotFocus)
    func renameReachable() async throws {
        let rig = DisplayNicknameTests.Rig(defaults: .pilot())
        await rig.displays.connections?.refresh()
        let panel = PanelTestSupport.open(DisplaysPopover(displays: rig.displays, brightness: nil).pilotTheme())
        defer { panel.close() }
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        PanelTestSupport.pump()
        let root = try #require(panel.contentView)
        #expect(SharedLook.BarPopoversTests.texts(in: root).contains("CU34G4Z"))
        let rename = try #require(Self.element("Rename CU34G4Z", in: root))
        #expect(rename.accessibilityPerformPress?() == true)
        PanelTestSupport.pump()
        #expect(Self.element("Name for CU34G4Z", in: root) != nil)
        try Self.type("Desk café 🖥️", into: panel)
        try Self.press("Save", in: root)
        #expect(rig.displays.nicknames.nickname(for: Self.first) == "Desk café 🖥️")
        #expect(Self.element("Rename Desk café 🖥️", in: root) != nil)
        #expect(SharedLook.BarPopoversTests.texts(in: root).contains("24G1WG4"))
        try Self.press("Rename Desk café 🖥️", in: root)
        try Self.type("Discard me", into: panel)
        try Self.press("Cancel", in: root)
        #expect(rig.displays.nicknames.nickname(for: Self.first) == "Desk café 🖥️")
        try Self.press("Rename Desk café 🖥️", in: root)
        try Self.press("Clear", in: root)
        try Self.press("Save", in: root)
        #expect(rig.displays.nicknames.nickname(for: Self.first) == nil)
        #expect(Self.element("Rename CU34G4Z", in: root) != nil)
        #expect(rig.hardware.calls.isEmpty && rig.screens.applied.isEmpty)
    }

    @Test("Missing and ambiguous physical identity disable Rename", .pilotFocus, arguments: [false, true])
    func unidentified(_ duplicate: Bool) async throws {
        let uuids: [String?] = duplicate ? [Self.first, Self.first] : [nil, Self.second]
        let rig = DisplayNicknameTests.Rig(defaults: .pilot(), uuids: uuids)
        await rig.displays.connections?.refresh()
        if duplicate { try rig.displays.nicknames.set("Unavailable identity", for: Self.first) }
        #expect(SharedLook.BarPopoversTests.enabled("Rename CU34G4Z", in: DisplaysPopover(displays: rig.displays, brightness: nil).pilotTheme()) == false)
        let shown = SharedLook.BarPopoversTests.labels(DisplaysPopover(displays: rig.displays, brightness: nil).pilotTheme())
        #expect(shown.contains("CU34G4Z") && !shown.contains("Unavailable identity"))
        #expect(rig.hardware.calls.isEmpty)
    }

    @Test("Unreadable settings show an error without closing the editor or overwriting names", .pilotFocus)
    func saveError() throws {
        let defaults = UserDefaults.pilot()
        defaults.set("preserve", forKey: "displays.nicknames")
        let names = DisplayNicknames(defaults: defaults)
        let panel = PanelTestSupport.open(DisplayNicknameEditor(systemName: "Monitor", displayUUID: Self.first, nicknames: names).frame(width: 300).pilotTheme())
        defer { panel.close() }
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        let root = try #require(panel.contentView)
        try Self.press("Rename Monitor", in: root)
        try Self.type("Desk", into: panel)
        try Self.press("Save", in: root)
        #expect(Self.element("Name for Monitor", in: root) != nil)
        #expect(SharedLook.BarPopoversTests.texts(in: root).contains { $0.contains("saved names were left unchanged") })
        #expect(defaults.string(forKey: "displays.nicknames") == "preserve")
    }

    @Test("The actual popover renames identical system names independently by UUID", .pilotFocus)
    func identicalPopover() async throws {
        let rig = DisplayNicknameTests.Rig(defaults: .pilot())
        rig.screens.screens = rig.screens.screens.map {
            DisplayInfo(id: $0.id, name: "Same", main: $0.main, frame: $0.frame, mode: $0.mode, rotation: $0.rotation, displayUUID: $0.displayUUID)
        }
        rig.hardware.screens = rig.hardware.screens.map {
            ConnectionScreen(id: $0.id, name: "Same", identity: $0.identity, state: $0.state, main: $0.main, builtIn: $0.builtIn, asleep: $0.asleep,
                             frame: $0.frame, mode: $0.mode, rotation: $0.rotation, location: $0.location, supported: $0.supported, displayUUID: $0.displayUUID)
        }
        let originals = rig.hardware.screens
        await rig.displays.connections?.refresh()
        let panel = PanelTestSupport.open(DisplaysPopover(displays: rig.displays, brightness: nil).pilotTheme())
        defer { panel.close() }
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        let root = try #require(panel.contentView)
        for (uuid, name) in [(Self.first, "Left"), (Self.second, "Right")] {
            let rename = try #require(Self.identifier("display-rename-\(uuid)", in: root))
            #expect(rename.accessibilityPerformPress?() == true)
            PanelTestSupport.pump()
            try Self.type(name, into: panel)
            try Self.press("Save", in: root)
            #expect(rig.displays.nicknames.nickname(for: uuid) == name)
        }
        #expect(Self.element("Rename Left", in: root) != nil && Self.element("Rename Right", in: root) != nil)
        #expect(rig.hardware.screens == originals && rig.hardware.calls.isEmpty && rig.screens.applied.isEmpty)
    }

    @Test("Identically named monitors use UUID metadata; pin values and bar routing retain system names")
    func duplicateSystemNames() throws {
        let names = DisplayNicknames(defaults: .pilot())
        try names.set("Left", for: Self.first)
        try names.set("Right", for: Self.second)
        let displays = [ConnectedDisplay(name: "Same", id: Self.first), ConnectedDisplay(name: "Same", id: Self.second)]
        let original = WorkspaceMonitors.choices(pinned: displays[1].pin, displays: displays)
        let pick = WorkspaceMonitorsBlock.monitorChoices(pinned: displays[1].pin, displays: displays, nicknames: names)
        #expect(pick.choices.map(\.title) == ["Any", "Main", "Left", "Right"])
        #expect(pick.choices.map(\.value) == original.choices.map(\.value) && pick.picked == original.picked)
        var selected: MonitorPin?
        let menu = try #require(try OpenedMenu.of(width: 220) {
            DropdownField(label: "Workspace 1's monitor", options: pick.choices, picked: pick.picked) { selected = $0 }.frame(width: 220)
        })
        try OpenedMenu.choose("Left", in: menu)
        #expect(selected == displays[0].pin)
        let offline = WorkspaceMonitorsBlock.monitorChoices(pinned: displays[1].pin, displays: [displays[0]], nicknames: names)
        #expect(offline.choices.last?.title == "Right (unplugged)")
        let legacy: MonitorPin = .display(name: "Same", id: nil)
        #expect(WorkspaceMonitorsBlock.monitorChoices(pinned: legacy, displays: [], nicknames: names).choices.last?.title == "Same (unplugged)")
        let ambiguous = WorkspaceMonitorsBlock.monitorChoices(pinned: nil, displays: [displays[0], displays[0]], nicknames: names)
        #expect(ambiguous.choices.suffix(2).map(\.title) == ["Same", "Same"])
        let bars = [TopBarGeometry.Screen(name: "Same", strip: 30, displayUUID: Self.first), .init(name: "Same", strip: 22, displayUUID: Self.second)]
        #expect(TopBarGeometry.bars(bars).map(\.monitor) == ["Same", "Same"])
        #expect(TopBarGeometry.bars(bars).map(\.height) == [30, 22])

        let old = try AeroMonitorWorkspace.parse("""
        [{"monitor-id":1,"monitor-name":"Same","workspace":"1"}]
        """)
        #expect(old.first?.displayUUID == nil)
        let rows = try AeroMonitorWorkspace.parse("""
        [{"monitor-id":1,"monitor-name":"Same","workspace":"1","display-uuid":"\(Self.first)"},
         {"monitor-id":2,"monitor-name":"Same","workspace":"2","display-uuid":"\(Self.second)"}]
        """)
        let occupied = [OccupiedWorkspace(name: "1", apps: []), .init(name: "2", apps: [])]
        func labels(_ metadata: [AeroMonitorWorkspace]) -> [String] {
            InstrumentWorkspaces.displays(occupied: occupied, windows: [], focused: "1", monitors: metadata, nicknames: names).map(\.name)
        }
        #expect(labels(rows) == ["Left", "Right"])
        #expect(labels(old) == ["Same"])
        var duplicate = rows
        duplicate[1].displayUUID = Self.first
        #expect(labels(duplicate) == ["Same", "Same"])
        try names.set("", for: Self.first)
        #expect(labels(rows) == ["Same", "Right"])
    }

    @Test("HUD and wallpaper labels observe rename and reset without replacing routing data")
    func observationAndWallpaper() async throws {
        let names = DisplayNicknames(defaults: .pilot())
        let hud = LevelModel(screen: "Same", reading: .level(0.5), displayUUID: Self.first, nicknames: names)
        var changed = false
        withObservationTracking { _ = hud.screen } onChange: { MainActor.assumeIsolated { changed = true } }
        try names.set("Desk", for: Self.first)
        #expect(changed && hud.screen == "Desk" && LevelFace.label(hud) == "Desk brightness 50 %")
        let settings = WallpaperSettings(defaults: .pilot())
        settings.remove(WallpaperCycle.standardFolder.path)
        let screens: [WallpaperControl.Screen] = [
            .init(id: 73, name: "Same", shape: .landscape, current: nil, displayUUID: Self.first),
            .init(id: 12, name: "Same", shape: .landscape, current: nil, displayUUID: Self.second),
            .init(id: 89, name: "Same", shape: .landscape, current: nil),
        ]
        let app = WallpaperControl(settings: settings, nicknames: names, screens: { screens })
        let verbs = ControlVerbs()
        verbs.registerWallpaper(app)
        let socket = ControlSocket(path: ControlSocketTests.tempPath(), verbs: verbs)
        #expect(socket.start())
        defer { socket.stop() }
        let run = try await PilotCLITests.pilot(["list", "wallpaper-screens"], socket: socket.path.path)
        #expect(run.status == 0 && run.err.isEmpty)
        let result = try JSONDecoder().decode([JSONValue].self, from: Data(run.out.utf8))
        #expect(DisplayConnectionVerbTests.path(result[0], "label") == .string("Desk"))
        #expect(DisplayConnectionVerbTests.path(result[0], "screen") == .string("Same"))
        #expect(DisplayConnectionVerbTests.path(result[0], "id") == .number(73))
        #expect(DisplayConnectionVerbTests.path(result[1], "label") == .string("Same"))
        #expect(DisplayConnectionVerbTests.path(result[2], "displayUUID") == nil)
        try names.set("", for: Self.first)
        #expect(hud.screen == "Same")
        #expect(DisplayConnectionVerbTests.path((await app.screenRows())[0], "label") == .string("Same"))
    }

    @Test("System, wallpaper and HUD labels observe long names and reset in both styles", .pilotFocus, arguments: ["instrument", "toybox"])
    func nativeSurfaces(_ style: String) throws {
        let rig = DisplayNicknameTests.Rig(defaults: .pilot())
        rig.displays.start()
        let names = rig.displays.nicknames
        let look = Look(inputSources: SetupKeepAwakeTests.FakeSources(), defaults: .pilot())
        look.style = try #require(PilotStyle(rawValue: style))
        let devices = SetupDevices(audio: SetupSoundTests.FakeAudio(), bluetooth: SetupBluetoothTests.FakeBluetooth(), wifi: SetupWiFiTests.FakeWiFi(),
                                   displays: rig.displays, look: look, defaults: .pilot())
        let wallpaper = WallpaperBlock(settings: WallpaperSettings(defaults: .pilot()), screens: [
            WallpaperScreen(id: 1, name: "CU34G4Z", portrait: false, detail: "No wallpaper file", thumb: nil, next: nil, nextName: nil, displayUUID: Self.first)
        ], count: 0, nicknames: names)
        let hud = LevelModel(screen: "CU34G4Z", reading: .level(0.5), displayUUID: Self.first, nicknames: names)
        var effectiveStyle: StyleTokens?
        let panel = PanelTestSupport.open(VStack {
            SetupPage(onScreen: false, devices: devices).frame(width: 1000, height: 620)
            wallpaper.frame(width: 600)
            LevelView(model: hud)
        }.transformEnvironment(\.style) { effectiveStyle = $0 }.styled(.hud, look: look).pilotTheme(look: look))
        defer { panel.close() }
        #expect(try #require(effectiveStyle) == StyleTokens.of(look.style, theme: look.theme))
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        let root = try #require(panel.contentView)
        #expect(Self.element("Rename CU34G4Z", in: root) != nil)
        let long = String(repeating: "Desk café 🖥️ ", count: 80)
        try names.set(long, for: Self.first)
        PanelTestSupport.pump()
        #expect(Self.element("Rename \(long)", in: root) != nil)
        #expect(Self.element("Next wallpaper on \(long)", in: root) != nil)
        #expect(Self.element("\(long) brightness 50 %", in: root) != nil)
        #expect(panel.frame.width <= 1001 && panel.alphaValue == 0)
        try Self.press("Rename \(long)", in: root)
        #expect(Self.element("Name for \(long)", in: root) != nil)
        try Self.press("Clear", in: root)
        try Self.press("Save", in: root)
        #expect(Self.element("Rename CU34G4Z", in: root) != nil)
        #expect(Self.element("Next wallpaper on CU34G4Z", in: root) != nil)
        #expect(Self.element("CU34G4Z brightness 50 %", in: root) != nil)
        #expect(rig.hardware.calls.isEmpty && rig.screens.applied.isEmpty)
    }

    @Test("Ambiguous UUID readbacks retain system labels and hide the unusable nickname")
    func ambiguousReadbacks() async throws {
        let rig = DisplayNicknameTests.Rig(defaults: .pilot(), uuids: [Self.first, Self.first])
        try rig.displays.nicknames.set("Old personal name", for: Self.first)
        let socket = ControlSocket(path: ControlSocketTests.tempPath(), verbs: rig.verbs)
        #expect(socket.start())
        defer { socket.stop() }
        let run = try await PilotCLITests.pilot(["system", "displays"], socket: socket.path.path)
        #expect(run.status == 0 && run.err.isEmpty)
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(run.out.utf8))
        for collection in ["screens", "connections"] {
            for (index, original) in ["CU34G4Z", "24G1WG4"].enumerated() {
                #expect(DisplayConnectionVerbTests.path(result, collection, String(index), "label") == .string(original))
                #expect(DisplayConnectionVerbTests.path(result, collection, String(index), "nickname") == nil)
            }
        }
        #expect(rig.displays.nicknames.nickname(for: Self.first) == "Old personal name")
        #expect(rig.hardware.calls.isEmpty && rig.screens.applied.isEmpty)
    }

    @Test("The actual Home title stays inside a narrow workspace column with a long nickname", .pilotFocus)
    func homeTitleBounds() throws {
        let long = String(repeating: "Desk café ", count: 80)
        let view = InstrumentWorkspaces(width: 150).column(.init(id: 1, name: long, workspaces: []), perRow: 1, each: 150, focused: nil)
        let panel = PanelTestSupport.open(view.frame(width: 150).pilotTheme())
        defer { panel.close() }
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        let root = try #require(panel.contentView)
        let title = try #require(Self.element(long, in: root) ?? Self.element(long.uppercased(), in: root))
        let frame = try #require(title.accessibilityFrame?())
        #expect(frame.width > 0 && frame.width <= 150, "Actual Home title width: \(frame.width)")
    }

    @Test("Menu bar rows have independent UUID view identities and follow rename/reset without changing routing", .pilotFocus)
    func menuBarRows() throws {
        let names = DisplayNicknames(defaults: .pilot())
        try names.set("Left", for: Self.first)
        try names.set("Right", for: Self.second)
        let screens = [TopBarGeometry.Screen(name: "Same", strip: 30, displayUUID: Self.first), .init(name: "Same", strip: 22, displayUUID: Self.second)]
        let rows = MenuBarPage.screenRows(screens)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.map(\.screen) == screens)
        let missing = MenuBarPage.screenRows([.init(name: "Same", strip: 30), .init(name: "Same", strip: 30)])
        #expect(Set(missing.map(\.id)).count == 2)
        let ambiguous = MenuBarPage.screenRows([screens[0], screens[0]])
        #expect(Set(ambiguous.map(\.id)).count == 2)
        let panels = TopBarControllerTests.FakePanels()
        let autohide = TopBarControllerTests.FakeAutohide()
        let bars = TopBarControllerTests.Bars()
        let controller = TopBarController(defaults: .pilot(), autohide: autohide, writeBars: { bars.written.append($0) }, screens: { screens }, panels: panels)
        let panel = PanelTestSupport.open(MenuBarPage(onScreen: false, nicknames: names).screenChoices(controller).frame(width: 420).pilotTheme())
        defer { panel.close() }
        let assistive = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        NSApp.accessibilitySetValue(true, forAttribute: assistive)
        defer { NSApp.accessibilitySetValue(false, forAttribute: assistive) }
        let root = try #require(panel.contentView)
        func has(_ text: String) -> Bool { SharedLook.BarPopoversTests.texts(in: root).contains { $0.contains(text) } }
        #expect(has("Left") && has("Right"))
        try names.set("Desk", for: Self.first)
        PanelTestSupport.pump()
        #expect(has("Desk") && has("Right") && !has("Left"))
        try names.set("", for: Self.first)
        PanelTestSupport.pump()
        #expect(has("Same") && has("Right") && !has("Desk"))
        #expect(controller.connected == screens && controller.leftOut.isEmpty)
        #expect(bars.written.isEmpty && panels.shown.isEmpty && !autohide.hidden)

        let hud = LevelModel(screen: "Same", reading: .level(0.5), displayUUID: Self.second, nicknames: names, identityIsUnique: false)
        #expect(LevelFace.label(hud) == "Same brightness 50 %")
        hud.identityIsUnique = true
        #expect(LevelFace.label(hud) == "Right brightness 50 %")
    }
}
