import Foundation
import PilotCore
import Testing

/// The Pilot menu's words (card agent-bo-95422912; one fixed menu since 2026-11-20): the headline and Hyper's line, the
/// footer's rows and Option's developer rows, and the switches.
@Suite("Dropdown")
struct DropdownTests {
    @Test("Key labels sign the real layer key and the bind's own keys, never a fixed Caps Lock (card agent-bo-95422993, G3)", arguments: LayerKey.allCases)
    func keyLabels(layerKey: LayerKey) {
        let sign = layerKey.symbol
        #expect(Dropdown.keyLabel(Key("space"), layerKeys: [layerKey]) == "\(sign) Space")
        #expect(Dropdown.keyLabel(Key("space", .shift), layerKeys: [layerKey]) == "\(sign)⇧ Space")
        #expect(Dropdown.keyLabel(Key("m", .alt, hyper: false), layerKeys: [layerKey]) == "Alt+M")
        #expect(Dropdown.keyLabel(nil, layerKeys: [layerKey]) == nil)
        #expect(Dropdown.workspaceKeys(layerKeys: [layerKey], count: 3) == "\(sign) 1–4")
        #expect(Dropdown.workspaceKeys(layerKeys: [layerKey], count: 6) == "\(sign) 1–6")
    }

    @Test("The headline says Pilot is on, or how many things need fixing; the line under it what Hyper is")
    func headline() {
        #expect(Dropdown.headline(isOn: true, problems: 0) == "Pilot is on")
        #expect(Dropdown.headline(isOn: false, problems: 0) == "Pilot is off")
        #expect(Dropdown.headline(isOn: true, problems: 2) == "Pilot needs 2 things")
        #expect(Dropdown.headline(isOn: true, problems: 1) == "Pilot needs 1 thing")
        #expect(Dropdown.hyperLine(hyperOn: true, trusted: true, secureInput: false, held: false, layerKey: "⇪ Caps Lock", problems: 0) == "Hyper is ⇪ Caps Lock")
        #expect(Dropdown.hyperLine(hyperOn: true, trusted: true, secureInput: false, held: true, layerKey: "⇪ Caps Lock", problems: 0) == "Hyper held")
        #expect(Dropdown.hyperLine(hyperOn: true, trusted: false, secureInput: false, held: false, layerKey: "⇪ Caps Lock", problems: 2) == "Hyper is off until they are fixed")
    }

    @Test("Key binds and the launcher both off say Hyper is off, ahead of a problem (card agent-bo-95422986); Key binds off alone keeps Hyper+Space (T20)")
    func hyperSwitchedOff() {
        #expect(Dropdown.hyperLine(hyperOn: false, launcherOn: false, trusted: true, secureInput: false, held: false, layerKey: "Caps Lock", problems: 0) == "Hyper is off")
        #expect(Dropdown.hyperLine(hyperOn: false, launcherOn: false, trusted: false, secureInput: true, held: false, layerKey: "Caps Lock", problems: 2) == "Hyper is off")
        #expect(Dropdown.hyperLine(hyperOn: false, trusted: true, secureInput: false, held: false, layerKey: "Caps Lock", problems: 0) == "Key binds are off: only Hyper+Space works")
        #expect(Dropdown.hyperLine(hyperOn: false, trusted: false, secureInput: true, held: false, layerKey: "Caps Lock", problems: 2) == "Hyper is off until they are fixed")
    }

    @Test("The footer: Check for updates, Settings and Quit on one line, Check for updates only in a built bundle; Option's developer rows (the command rows went 2026-11-20)")
    func footerRows() {
        #expect(Dropdown.footer(canUpdate: true).map(\.title) == ["Check for updates", "Settings", "Quit"])
        #expect(!Dropdown.footer(canUpdate: false).contains(.updates))
        #expect(Dropdown.Row.allCases.filter { $0.command != nil } == [.settings, .quit])
        #expect(Dropdown.Row.developer.map(\.title) == ["Print observers", "Rescue stranded windows"])
        // Every row is drawn somewhere, once.
        let drawn = Dropdown.footer(canUpdate: true) + Dropdown.Row.developer
        #expect(Set(drawn) == Set(Dropdown.Row.allCases) && drawn.count == Dropdown.Row.allCases.count)
    }

    @Test("The switches say what they do now; the four are Home's and the Pilot menu's, each by its setting")
    func switches() {
        #expect(Dropdown.Switch.allCases.map(\.title) == ["Launcher", "Key binds", "Tiling", "Top bar", "Keep awake", "Clipboard", "Dictation key"])
        #expect(Dropdown.Switch.allCases.map(\.short) == ["Launcher", "Binds", "Tiling", "Top bar", "Awake", "Clipboard", "Dictation"])
        #expect(Dropdown.Switch.allCases.map { $0.state(true, layerKeys: [.capsLock], tiler: "Pilot's tiler") } == ["opens on its key", "binds on", "Pilot's tiler on", "macOS bar hidden", "kept awake", "keeps what you copy", "a tap dictates"])
        #expect(Dropdown.Switch.topBar.state(false, layerKeys: [.capsLock], tiler: "Pilot's tiler") == "macOS bar shown" && Dropdown.Switch.keepAwake.state(false, layerKeys: [.capsLock], tiler: "Pilot's tiler") == "sleeps as usual")
        #expect(Dropdown.Switch.hyper.state(false, layerKeys: [.capsLock], tiler: "Pilot's tiler") == "only the launcher's key")
        #expect(Dropdown.Switch.four.compactMap(\.settingKey) == ["launcher.on", "switch.on", "tiling.on", "clipboard.recording"])
        #expect(LayerKey.allCases.map { Dropdown.Switch.hyper.symbol(layerKeys: [$0]) } == ["capslock", "control", "control", "option", "option", "command", "command"])
        #expect(Dropdown.Switch.tiling.symbol(layerKeys: [.rightOption]) == "rectangle.split.3x1")
        // Pilot's own tiler on (card agent-bo-95423025): Tiling names it.
        #expect([true, false].map { Dropdown.Switch.tiling.state($0, layerKeys: [.capsLock], tiler: "Pilot's tiler") } == ["Pilot's tiler on", "Pilot's tiler paused"])
    }
}
