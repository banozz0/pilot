import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Binds as a keyboard on the app side (card agent-bo-95422894): the key picked first, and Plain combos as the
/// keyboard's last tab rather than a page tab, still reached by its old link.
@MainActor
@Suite("Binds keyboard page")
struct BindsKeyboardPageTests {
    @Test("While the Binds board picks, a Hyper press picks its key with its sublayer; a bound one runs too, so binds work with Pilot in front (T48), a free one only picks; plain combos still run (card agent-bo-95422993, G5)")
    func hyperPressPicks() {
        let tap = HyperTap(layer: HyperLayer(layerKey: .capsLock))
        let b = KeyNames.code(for: "B")!
        tap.isBound = { $0 == Key("k") || $0 == Key("w", .cmd, hyper: false) }
        var ran: [Key] = [], unbound: [Key] = [], picked: [Key] = []
        tap.onRun = { key, _ in ran.append(key) }
        tap.onUnbound = { key, _ in unbound.append(key) }
        func press(_ code: Int64, flags: UInt64 = 0, hyper: Bool = true) {
            if hyper { #expect(tap.route(.init(kind: .keyDown, keyCode: KeyCode.f18))) }
            #expect(tap.route(.init(kind: .keyDown, keyCode: code, flags: flags)) == true)
            #expect(tap.route(.init(kind: .keyUp, keyCode: code, flags: flags)))
            if hyper { #expect(tap.route(.init(kind: .keyUp, keyCode: KeyCode.f18))) }
        }
        tap.picking = { picked.append($0) }
        press(KeyCode.k)
        press(b, flags: KeyEvent.shiftMask)
        press(KeyNames.code(for: "W")!, flags: KeyEvent.cmdMask, hyper: false)
        #expect(picked == [Key("k"), Key("b", .shift)])
        // T48: the bound Hyper+K ran as well as picking; the free Hyper+Shift+B only picked.
        #expect(ran == [Key("k"), Key("w", .cmd, hyper: false)] && unbound.isEmpty)
        tap.picking = nil
        press(KeyCode.k)
        #expect(ran.last == Key("k") && ran.count == 3 && picked.count == 2)
    }

    @Test("Return and Delete act on the picked key's row: Return rebinds its bind or binds the free key, Delete clears the picked bind and leaves a free key alone (card agent-bo-95422993, G4)")
    func returnAndDelete() {
        let w = KeyNames.code(for: "W")!, b = KeyNames.code(for: "B")!, q = KeyNames.code(for: "Q")!
        let bound = [w: ["windows.close"], b: ["apps.browser"]]
        #expect(BindsKeyboard.Command(returnKey: true, picked: w, bound: bound) == .rebind("windows.close"))
        #expect(BindsKeyboard.Command(returnKey: false, picked: w, bound: bound) == .clear("windows.close"))
        #expect(BindsKeyboard.Command(returnKey: true, picked: b, bound: bound) == .rebind("apps.browser"))
        #expect(BindsKeyboard.Command(returnKey: false, picked: b, bound: bound) == .clear("apps.browser"))
        #expect(BindsKeyboard.Command(returnKey: true, picked: q, bound: bound) == .bind(q))
        #expect(BindsKeyboard.Command(returnKey: false, picked: q, bound: bound) == nil)
        #expect(BindsKeyboard.Command(returnKey: true, picked: nil, bound: bound) == nil)
    }

    @Test("B is picked first when it is bound, else the first bound key on the board")
    func firstPick() {
        let b = KeyNames.code(for: "B")!, w = KeyNames.code(for: "W")!, esc = KeyNames.code(for: "Esc")!
        #expect(BindsKeyboardPage.firstPick([b: ["apps.browser"], w: ["windows.close"]]) == b)
        #expect(BindsKeyboardPage.firstPick([w: ["windows.close"], esc: ["system.menu"]]) == esc)
        #expect(BindsKeyboardPage.firstPick([:]) == b)
    }

    @Test("Binds has no page tabs (Abilities moved to Menu in C3): Plain combos is the keyboard's last tab, and its old link opens Binds on it")
    func plainIsASublayer() {
        // Overlay, Swap keys and Export and import are places on More (simplify-pages T14).
        #expect(AppPage.binds.tabs.map(\.value) == [nil, .mouse, .bindsMore] && !AppSection.plainCombos.isTab)
        let model = AppWindowModel(defaults: UserDefaults(suiteName: testSuite())!)
        model.go(AppPlace.linked(URL(string: "pilot://open?page=plainCombos")!)!)
        #expect(model.page == .binds && model.section(of: .binds) == .plainCombos)
        model.go(AppPlace(.binds))
        #expect(model.section(of: .binds) == nil)
    }

    @Test("The conflicts count on Binds is ShortcutConflicts' clash count for the binds, on a fake domain")
    func conflictCount() {
        let fake = ShortcutConflictsTests.FakeDomain(ShortcutConflictsTests.original)
        let url = FileManager.default.temporaryDirectory.appending(path: "pilot-conflicts-\(UUID().uuidString).plist")
        let conflicts = ShortcutConflicts(domain: fake.domain, backupURL: url)
        let model = AppWindowModel(defaults: UserDefaults(suiteName: testSuite())!)
        model.refreshConflicts(binds: ShortcutConflictsTests.binds, conflicts: conflicts)
        #expect(model.conflictCount == conflicts.clashes(binds: ShortcutConflictsTests.binds).count && model.conflictCount == 1)
        model.refreshConflicts(binds: [:], conflicts: conflicts)
        #expect(model.conflictCount == 0)
    }

    @Test("A plain combo that shadows macOS says so on the Plain tab; a Hyper bind never does")
    func plainWarning() {
        var store = BindStore(defaults: [:])
        try! store.set("system.missionControl", to: Key("up", .ctrl, hyper: false))
        try! store.set("clipboard.history", to: Key("v", .leftAlt, hyper: false))
        try! store.set("windows.close", to: Key("w"))
        #expect(BindsKeyboardPage.warning(for: "system.missionControl", store: store)?.contains("Mission Control") == true)
        #expect(BindsKeyboardPage.warning(for: "clipboard.history", store: store) != nil)
        #expect(BindsKeyboardPage.warning(for: "windows.close", store: store) == nil)
    }

    /// Home's names on the main block, the longest Pilot draws among them, and names on the function row, the nav keys
    /// and the arrows, as Binds' board puts every key in a bind's reach.
    static let names: [Int64: String] = HomePageTests.names.merging([
        "F7": "Back", "F8": "Play", "F9": "Next", "F10": "Mute", "F11": "Vol −", "F12": "Vol +", "Escape": "Lock", "`": "Former",
        "Home": "Scrolling", "End": "Previous", "PageDown": "Obsidian", "ForwardDelete": "Close",
        "Delete": "Passwords", "\\": "WhatsApp", "'": "Messages", ";": "Telegram",
        "Left": "Left", "Right": "Right", "Up": "Up", "Down": "Down",
    ].map { (KeyNames.code(for: $0.key)!, $0.value) }) { _, new in new }

}
