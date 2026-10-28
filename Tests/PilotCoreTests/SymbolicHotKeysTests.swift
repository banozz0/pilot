import Foundation
import Testing
@testable import PilotCore

/// Shortcut conflicts on a recorded table (stories 34, 35 and 101, card agent-bo-95422087): never the real domain.
@Suite("Symbolic hotkeys")
struct SymbolicHotKeysTests {
    /// Rows of this Mac's com.apple.symbolichotkeys, `defaults export` on 2026-10-05 (read only): Mission Control on,
    /// its Shift variant on, Ctrl+Down cleared, the input-source and Spotlight keys off, Desktop 1 on, and row 164's
    /// odd two-number value.
    static let recorded = """
    {"32": {"enabled": true, "value": {"parameters": [65535, 126, 8650752], "type": "standard"}},
     "33": {"enabled": false, "value": {"parameters": [65535, 65535, 0], "type": "standard"}},
     "34": {"enabled": true, "value": {"parameters": [65535, 126, 8781824], "type": "standard"}},
     "60": {"enabled": false, "value": {"parameters": [32, 49, 262144], "type": "standard"}},
     "64": {"enabled": false, "value": {"parameters": [32, 49, 1048576], "type": "standard"}},
     "118": {"enabled": true, "value": {"parameters": [65535, 18, 262144], "type": "standard"}},
     "164": {"enabled": false, "value": {"parameters": [262144, 9223372036854775807], "type": "modifier"}}}
    """

    static func table(_ json: String = recorded) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

    /// A bind set as the tap holds it, trigger → action: Ctrl+Up as a plain combo, and Hyper keys, which never clash.
    static let binds: [Key: String] = [Key("up", .ctrl, hyper: false): "system.missionControl", Key("w"): "windows.close",
                                       Key("up", .ctrl): "windows.maximise", Key("1"): "workspaces.go:1"]

    @Test("A row reads as its key and whether it is on; a cleared or odd row has no key")
    func parse() {
        let keys = SymbolicHotKeys.hotKeys(in: Self.table())
        let mc = keys.first { $0.id == 32 }
        #expect(mc == .init(id: 32, enabled: true, key: Key("up", .ctrl, hyper: false), name: "Mission Control"))
        #expect(keys.first { $0.id == 34 }?.key == Key("up", [.ctrl, .shift], hyper: false))
        #expect(keys.first { $0.id == 33 }?.key == nil)
        #expect(keys.first { $0.id == 164 }?.key == nil)
    }

    @Test("For that bind set only Mission Control clashes, with Pilot's own Ctrl+Up plain combo")
    func clashes() {
        #expect(SymbolicHotKeys.clashes(in: Self.table(), binds: Self.binds).map(\.hotkey.id) == [32])
        #expect(SymbolicHotKeys.clashes(in: Self.table(), binds: Self.binds).first?.action == "system.missionControl")
        // A Hyper bind never reaches macOS: the tap swallows it.
        #expect(SymbolicHotKeys.clashes(in: Self.table(), binds: [Key("1", .ctrl): "workspaces.go1"]).isEmpty)
        // A one-sided plain combo still lands on macOS's shortcut, which ignores sides.
        #expect(SymbolicHotKeys.clashes(in: Self.table(), binds: [Key("1", .leftCtrl, hyper: false): "x"]).map(\.hotkey.id) == [118])
    }

    @Test("Switching off writes enabled false and nothing else; restore gives back the exact table")
    func switchOffAndRestore() {
        let original = Self.table()
        let (off, backup) = SymbolicHotKeys.switchOff([32], in: original, backup: [:])
        #expect(SymbolicHotKeys.hotKeys(in: off).first { $0.id == 32 }?.enabled == false)
        #expect(SymbolicHotKeys.clashes(in: off, binds: Self.binds).isEmpty)
        var others = off; others["32"] = original["32"]
        #expect(Self.same(others, original))
        #expect(Self.same(SymbolicHotKeys.restore(backup, in: off), original))
    }

    @Test("A row macOS leaves out is on by default: it clashes, switching off adds it, restore takes it out again")
    func absentRow() {
        var original = Self.table(); original["32"] = nil
        #expect(SymbolicHotKeys.clashes(in: original, binds: Self.binds).map(\.hotkey.id) == [32])
        let (off, backup) = SymbolicHotKeys.switchOff([32], in: original, backup: [:])
        #expect(SymbolicHotKeys.hotKeys(in: off).first { $0.id == 32 }?.enabled == false)
        #expect(backup["absent"] as? [String] == ["32"])
        #expect(Self.same(SymbolicHotKeys.restore(backup, in: off), original))
    }

    @Test("Switching off twice keeps the first backup, so restore still gives back the table before either")
    func twice() {
        let original = Self.table()
        let first = SymbolicHotKeys.switchOff([32], in: original, backup: [:])
        let second = SymbolicHotKeys.switchOff([32, 118], in: first.table, backup: first.backup)
        #expect(Self.same(SymbolicHotKeys.restore(second.backup, in: second.table), original))
    }

    @Test("Every macOS shortcut the Binds screen warns about has a row here: Cmd+` (row 27) is on when the table leaves it out")
    func everyWarnedRow() {
        let cmdBacktick = Key(keyCode: 50, modifiers: .cmd, hyper: false)
        #expect(PlainComboShadow.warning(for: cmdBacktick) != nil)
        #expect(SymbolicHotKeys.clashes(in: Self.table(), binds: [cmdBacktick: "x"]).map(\.hotkey.id) == [27])
        // Each warned combo that macOS keeps in this table clashes once its row is left out (the App switcher is not in it).
        for (key, _) in PlainComboShadow.macOS where key.keyCode != 48 {
            #expect(SymbolicHotKeys.clashes(in: [:], binds: [key: "x"]).count == 1, "\(key.label)")
        }
    }
}
