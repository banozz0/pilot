import Testing
@testable import PilotCore

/// Device-dependent flag bits (IOLLEvent.h NX_DEVICE*KEYMASK): which physical side of a modifier is held.
private let leftAlt: UInt64 = 0x20, rightAlt: UInt64 = 0x40, leftShift: UInt64 = 0x2, rightShift: UInt64 = 0x4
private let h = Key("h").keyCode

@Suite("Plain combos")
struct PlainComboTests {
    private func run(_ bind: Key, flags: UInt64, keyCode: Int64 = h) -> LayerDecision {
        var layer = HyperLayer(layerKey: .capsLock)
        return layer.handle(.init(kind: .keyDown, keyCode: keyCode, flags: flags), isBound: { $0 == bind })
    }

    @Test("Left Alt+H runs a left Alt+H bind and its keyUp is swallowed; right Alt+H passes, so right Alt still types")
    func leftAltNotRight() {
        let bind = Key(keyCode: h, modifiers: .leftAlt, hyper: false)
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h, flags: KeyEvent.altMask | leftAlt), isBound: { $0 == bind }) == .run(bind, autorepeat: false))
        #expect(layer.handle(.init(kind: .keyUp, keyCode: h, flags: KeyEvent.altMask | leftAlt), isBound: { $0 == bind }) == .swallow)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h, flags: KeyEvent.altMask | rightAlt), isBound: { $0 == bind }) == .pass)
        #expect(layer.handle(.init(kind: .keyUp, keyCode: h, flags: KeyEvent.altMask | rightAlt), isBound: { $0 == bind }) == .pass)
    }

    @Test("An Alt+H bind with no side runs from either Alt")
    func eitherSide() {
        let bind = Key(keyCode: h, modifiers: .alt, hyper: false)
        #expect(run(bind, flags: KeyEvent.altMask | leftAlt) == .run(bind, autorepeat: false))
        #expect(run(bind, flags: KeyEvent.altMask | rightAlt) == .run(bind, autorepeat: false))
    }

    @Test("A left Alt+Shift+H bind runs with either Shift")
    func sideWithEitherShift() {
        let bind = Key(keyCode: h, modifiers: [.leftAlt, .shift], hyper: false)
        #expect(run(bind, flags: KeyEvent.altMask | leftAlt | KeyEvent.shiftMask | leftShift) == .run(bind, autorepeat: false))
        #expect(run(bind, flags: KeyEvent.altMask | leftAlt | KeyEvent.shiftMask | rightShift) == .run(bind, autorepeat: false))
        #expect(run(bind, flags: KeyEvent.altMask | rightAlt | KeyEvent.shiftMask | leftShift) == .pass)
    }

    @Test("With three modifiers on one side, the bind naming more sides wins")
    func mostSidesFirst() {
        let leftShift: UInt64 = 0x2, leftCtrl: UInt64 = 0x1
        let flags = KeyEvent.shiftMask | leftShift | KeyEvent.ctrlMask | leftCtrl | KeyEvent.altMask | leftAlt
        let twoSides = Key(keyCode: h, modifiers: [.leftShift, .leftCtrl, .alt], hyper: false)
        let oneSide = Key(keyCode: h, modifiers: [.shift, .ctrl, .leftAlt], hyper: false)
        var layer = HyperLayer(layerKey: .capsLock)
        #expect(layer.handle(.init(kind: .keyDown, keyCode: h, flags: flags), isBound: { $0 == twoSides || $0 == oneSide }) == .run(twoSides, autorepeat: false))
    }

    @Test("A posted Ctrl+Up with no side bits matches a Ctrl+Up bind")
    func noDeviceBits() {
        let bind = Key(keyCode: Key("up").keyCode, modifiers: .ctrl, hyper: false)
        #expect(run(bind, flags: KeyEvent.ctrlMask, keyCode: bind.keyCode) == .run(bind, autorepeat: false))
    }

    @Test("Shift alone or no modifier is no plain combo")
    func needsCmdCtrlOrAlt() {
        let bind = Key(keyCode: h, modifiers: .shift, hyper: false)
        #expect(run(bind, flags: KeyEvent.shiftMask | leftShift) == .pass)
        #expect(run(Key(keyCode: h, modifiers: [], hyper: false), flags: 0) == .pass)
    }

    @Test("Flags posted for left Alt+Shift read back as left Alt with either Shift first, and both sides as either side")
    func postedFlags() {
        let event = KeyEvent(kind: .keyDown, keyCode: h, flags: KeyEvent.flags(for: [.leftAlt, .shift]))
        #expect(event.plainCombos.first == Key(keyCode: h, modifiers: [.leftAlt, .shift], hyper: false))
        #expect(KeyEvent.flags(for: .alt) == KeyEvent.altMask)
        #expect(KeyEvent.flags(for: .rightAlt) == KeyEvent.altMask | rightAlt)
    }

    // MARK: the Binds screen

    @Test("The Plain combos tab lists every bind without Hyper, with its whole trigger and what it shadows")
    func plainTab() {
        let actions: [BindsPage.ActionInfo] = [
            .init(id: "windows.close", label: "Close window", module: "windows"),
            .init(id: "windows.focusLeft", label: "Focus left", module: "windows"),
            .init(id: "system.missionControl", label: "Mission Control", module: "system"),
        ]
        let store = BindStore(defaults: [
            "windows.close": Key("w"),
            "windows.focusLeft": Key(keyCode: h, modifiers: .leftAlt, hyper: false),
            "system.missionControl": Key(keyCode: Key("up").keyCode, modifiers: .ctrl, hyper: false),
        ])
        let rows = BindsPage.rows(store: store, actions: actions, tab: .plain)
        #expect(rows.map(\.id) == ["system.missionControl", "windows.focusLeft"])
        #expect(rows.map(\.key) == ["Ctrl+↑", "Left Alt+H"])
        #expect(rows.map(\.warning) == ["Shadows macOS's Mission Control.", "Left Alt+H no longer types a character; Right Alt+H still does."])
        #expect(BindsPage.rows(store: store, actions: actions, tab: .layer(.hyper)).map(\.warning) == [nil])
    }

    @Test("The clash table: macOS shortcuts on either side, Alt typing and its accents, Cmd menu shortcuts, and free combos")
    func shadows() {
        func plain(_ name: String, _ m: Modifiers) -> Key { Key(keyCode: Key(name).keyCode, modifiers: m, hyper: false) }
        #expect(PlainComboShadow.warning(for: plain("up", .leftCtrl)) == "Shadows macOS's Mission Control.")
        #expect(PlainComboShadow.warning(for: plain("space", .cmd)) == "Shadows macOS's Spotlight.")
        #expect(PlainComboShadow.warning(for: plain("e", .alt)) == "Alt+E types the ´ accent; this takes it from both Alt keys.")
        #expect(PlainComboShadow.warning(for: plain("e", .rightAlt)) == "Right Alt+E no longer types the ´ accent.")
        #expect(PlainComboShadow.warning(for: plain("e", [.leftAlt, .shift])) == "Shift+Left Alt+E no longer types the ´ accent; Shift+Right Alt+E still does.")
        #expect(PlainComboShadow.warning(for: plain("w", .cmd)) == "Cmd+W is a menu shortcut in most apps; this takes it everywhere.")
        #expect(PlainComboShadow.warning(for: plain("x", [.cmd, .ctrl])) == nil)
        #expect(PlainComboShadow.warning(for: Key("w")) == nil)
    }
}
