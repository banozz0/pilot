import Foundation
import PilotCore
import Testing

/// The dropdown's blocks (card agent-bo-95422912, compact since spec pilot-1-1 T29): problems lead, Now only while something
/// runs, Option adds the developer rows, and every row the old dropdown offered has a place.
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

    @Test("The compact menu's blocks (spec pilot-1-1 T29): Option adds the developer rows before the footer; Now draws itself only while something runs")
    func blocks() {
        #expect(Dropdown.blocks(option: false) == [.status, .workspaces, .quickSwitches, .now, .rows, .footer])
        #expect(Dropdown.blocks(option: true) == [.status, .workspaces, .quickSwitches, .now, .rows, .developer, .footer])
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

    @Test("Hyper switched off says so, ahead of a problem, since fixing that would not bring it back (card agent-bo-95422986)")
    func hyperSwitchedOff() {
        #expect(Dropdown.hyperLine(hyperOn: false, trusted: true, secureInput: false, held: false, layerKey: "Caps Lock", problems: 0) == "Hyper is off")
        #expect(Dropdown.hyperLine(hyperOn: false, trusted: false, secureInput: true, held: false, layerKey: "Caps Lock", problems: 2) == "Hyper is off")
    }

    @Test("Every row of the old dropdown has a place in a block, Option's rows included, and Feedback and Support are on Settings' About")
    func nothingMissing() {
        let old = ["The workspaces with windows, a click going there", "The tiler is not running: tiling and workspaces are off",
                   "Rescue stranded windows", "Always rescue when the tiler quits", "Accessibility not granted", "Finish setup…",
                   "A password field has the keyboard", "Hyper held / Hyper is <key>", "Pilot's last error", "Last: <press>",
                   "Recent presses", "Pilot (the on/off switch)", "Also quit Karabiner-Elements", "Also quit Hammerspoon",
                   "The switch's problem", "Print observers", "Open Pilot… ⌘,", "Quit Pilot ⌘Q", "Send feedback", "Support Pilot"]
        #expect(Dropdown.carried.map(\.row) == old)
        let shown = Set(Dropdown.blocks(option: true))
        #expect(Dropdown.carried.allSatisfy { shown.contains($0.block) && !$0.now.isEmpty })
    }

    @Test("Row set A (Q683): Open, Capture and Pilot's groups, then Check for updates, Settings and Quit on one line; Check for updates only in a built bundle")
    func footerRows() {
        #expect(Dropdown.groups.map(\.title) == ["Open", "Capture", "Pilot"])
        #expect(Dropdown.groups.map { $0.rows.map(\.title) } == [
            ["Pilot menu", "Clipboard history", "AI chat", "Quick notes", "Dictate"], ["Capture area", "Screen recording"], ["Keys map", "Extensions"],
        ])
        #expect(Dropdown.footer(canUpdate: true).map(\.title) == ["Check for updates", "Settings", "Quit"])
        #expect(!Dropdown.footer(canUpdate: false).contains(.updates))
        // A row shows its registered action's bind, or its ⌘ key; never both.
        #expect(Dropdown.Row.allCases.compactMap(\.actionID) == ["apps.launcher", "apps.clipboard", "ai.chat", "notes.toggle", "dictation.toggle",
                                                                 "captures.area", "captures.screenRecording"])
        #expect(Dropdown.Row.allCases.filter { $0.command != nil } == [.settings, .quit])
        #expect(Dropdown.Row.allCases.allSatisfy { $0.actionID == nil || $0.command == nil })
        #expect(Dropdown.Row.developer.map(\.title) == ["Print observers", "Rescue stranded windows"])
        // Every row is drawn somewhere, once.
        let drawn = Dropdown.groups.flatMap(\.rows) + Dropdown.footer(canUpdate: true) + Dropdown.Row.developer
        #expect(Set(drawn) == Set(Dropdown.Row.allCases) && drawn.count == Dropdown.Row.allCases.count)
    }

    @Test("The Pilot on/off switch left the dropdown (Sven, 2026-10-07): the Hyper key switch leads Quick switches instead")
    func noPilotSwitch() throws {
        let pilot = try #require(Dropdown.carried.first { $0.row == "Pilot (the on/off switch)" })
        #expect(pilot.block == .quickSwitches && pilot.now == "gone; the Hyper key switch instead")
    }

    @Test("The Also quit ticks left the dropdowns with Other apps (C3, Sven 2026-10-10); their saved choice still applies")
    func noQuitTicks() {
        let ticks = Dropdown.carried.filter { $0.row.hasPrefix("Also quit") }
        #expect(ticks.count == 2 && ticks.allSatisfy { $0.now == "gone; the saved choice still applies" })
    }

    @Test("The six switches say what they do now; Hyper's names its layer key and wears that key's sign")
    func switches() {
        #expect(Dropdown.Switch.allCases.map(\.title) == ["Hyper key", "Tiling", "Top bar", "Keep awake", "Clipboard", "Dictation key"])
        #expect(Dropdown.Switch.allCases.map(\.short) == ["Hyper", "Tiling", "Top bar", "Awake", "Clipboard", "Dictation"])
        #expect(Dropdown.Switch.allCases.map { $0.state(true, layerKeys: [.capsLock], tiler: "Pilot's tiler") } == ["binds on", "Pilot's tiler on", "macOS bar hidden", "kept awake", "recording", "a tap dictates"])
        #expect(Dropdown.Switch.topBar.state(false, layerKeys: [.capsLock], tiler: "Pilot's tiler") == "macOS bar shown" && Dropdown.Switch.keepAwake.state(false, layerKeys: [.capsLock], tiler: "Pilot's tiler") == "sleeps as usual")
        #expect(LayerKey.allCases.map { Dropdown.Switch.hyper.state(false, layerKeys: [$0], tiler: "Pilot's tiler") }
                == ["Caps Lock left to macOS", "Left Control left to macOS", "Right Control left to macOS", "Left Option left to macOS",
                    "Right Option left to macOS", "Left Command left to macOS", "Right Command left to macOS"])
        #expect(LayerKey.allCases.map { Dropdown.Switch.hyper.symbol(layerKeys: [$0]) } == ["capslock", "control", "control", "option", "option", "command", "command"])
        #expect(Dropdown.Switch.tiling.symbol(layerKeys: [.rightOption]) == "rectangle.split.3x1")
        // Pilot's own tiler on (card agent-bo-95423025): Tiling names it.
        #expect([true, false].map { Dropdown.Switch.tiling.state($0, layerKeys: [.capsLock], tiler: "Pilot's tiler") } == ["Pilot's tiler on", "Pilot's tiler paused"])
    }
}
