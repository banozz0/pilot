import Foundation
import Testing
@testable import PilotCore

/// Binds as a keyboard (design round 4, card agent-bo-95422894): the artifact's key rows, each key coloured by what its
/// bind does on the sublayer picked, free keys free, and Plain the last tab.
@Suite("Binds keyboard")
struct BindsKeyboardTests {
    static let defaults: [String: Key] = [
        "windows.close": Key("w"), "windows.toggleFloat": Key("t", .shift), "apps.terminal": Key("return"),
        "workspaces.go:2": Key("2"), "captures.area": Key("s"), "system.lock": Key("escape"), "apps.menu": Key("space"),
    ]

    @Test("The artifact's five rows, Caps Lock as the layer key, every legend a key Pilot knows")
    func rows() {
        let rows = BindsKeyboard.rows
        #expect(rows.count == 5)
        #expect(rows[0].map(\.legend) == ["Esc", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="])
        #expect(rows[2].first?.isLayerKey == true && rows[2].first?.legend == "Hyper" && rows[2].last?.legend == "Return")
        #expect(rows[4].map(\.legend) == ["Space"] && rows[4][0].width == 13.5)
        for cap in rows.joined() where !cap.isLayerKey && cap.legend != "Shift" {
            #expect(cap.code != nil, "\(cap.legend) has no key code")
        }
    }

    @Test("Six sublayer tabs, Plain last, each picking its keys")
    func layers() {
        #expect(BindsKeyboard.Layer.allCases.map(\.title) == ["Hyper", "+ Shift", "+ Ctrl", "+ Alt", "+ Shift Ctrl", "Plain"])
        #expect(BindsKeyboard.Layer.allCases.last == .plain)
    }

    @Test("A key's colour follows its action's module; a key with nothing on the layer is free")
    func colours() {
        let store = BindStore(defaults: Self.defaults)
        let hyper = BindsKeyboard.bound(store: store, layer: .hyper)
        #expect(hyper[KeyNames.code(for: "w")!] == ["windows.close"])
        #expect(hyper[KeyNames.code(for: "t")!] == nil, "T is bound only with Shift")
        #expect(BindsKeyboard.bound(store: store, layer: .shift)[KeyNames.code(for: "t")!] == ["windows.toggleFloat"])
        #expect(BindsKeyboard.module("apps") == 0 && BindsKeyboard.module("drive") == 0 && BindsKeyboard.module("windows") == 1)
        #expect(BindsKeyboard.module("workspaces") == 2 && BindsKeyboard.module("captures") == 3 && BindsKeyboard.module("system") == 4)
        #expect(BindsKeyboard.module("media") == 4 && BindsKeyboard.module("engine") == 5)
        #expect(BindsKeyboard.modules == ["Apps", "Windows", "Workspaces", "Captures", "System", "Pilot"])
    }

    @Test("Plain shows every key that holds a plain combo, whatever its modifiers")
    func plain() {
        var store = BindStore(defaults: Self.defaults)
        try! store.set("windows.minimise", to: Key(keyCode: KeyNames.code(for: "m")!, modifiers: .alt, hyper: false))
        let plain = BindsKeyboard.bound(store: store, layer: .plain)
        #expect(plain[KeyNames.code(for: "m")!] == ["windows.minimise"])
        #expect(plain[KeyNames.code(for: "w")!] == nil)
        #expect(BindsKeyboard.bound(store: store, layer: .hyper)[KeyNames.code(for: "m")!] == nil)
    }

    @Test("Toybox's Free keys: every free key in board order, a run of free F-keys as one range, named keys alone, no modifier; past the limit, a row's run of three or more typed keys as one range (card agent-bo-95423182)")
    func freeKeys() {
        let board = BindsKeyboard.Board(.ansi, compact: true)
        let code = { (name: String) in KeyNames.code(for: name)! }
        let free: Set<Int64> = Set(["F1", "F2", "F3", "F4", "F5", "F6", "5", "6", "Q", "U", "\\", ";", "'", "Home"].map(code))
        let bound = Dictionary(uniqueKeysWithValues: board.codes.filter { !free.contains($0) }.map { ($0, ["x"]) })
        let runs = BindsKeyboard.free(on: board, bound: bound)
        #expect(runs.map(\.label) == ["F1 – F6", "5", "6", "Home", "Q", "U", "\\", ";", "'"])
        #expect(runs.first?.codes == ["F1", "F2", "F3", "F4", "F5", "F6"].map(code), "the range picks its first key")
        #expect(runs.reduce(0) { $0 + $1.codes.count } == free.count, "every free key counted once")
        // A lone free F-key and a pair stay keys of their own.
        let pair = bound.filter { $0.key != code("F8") && $0.key != code("F10") && $0.key != code("F11") }
        #expect(BindsKeyboard.free(on: board, bound: pair).prefix(4).map(\.label) == ["F1 – F6", "F8", "F10", "F11"])
        // A layer with almost nothing bound: rows of typed keys fold into ranges, named keys stay alone.
        let empty = BindsKeyboard.free(on: board, bound: [code("W"): ["windows.close"]])
        #expect(empty.count <= BindsKeyboard.freeLimit)
        #expect(empty.map(\.label).contains("Q") && empty.map(\.label).contains("E – \\"), "W splits its row's run")
        #expect(empty.map(\.label).contains("` – ="), "the number row folds whole")
        #expect(empty.first?.label == "Esc" && empty.contains { $0.label == "F1 – F12" })
        #expect(!empty.contains { $0.label.contains("Shift") || $0.label.contains("Ctrl") || $0.label == "Caps" }, "no modifier is a free key")
        #expect(empty.reduce(0) { $0 + $1.codes.count } == board.codes.count - 1)
    }

    @Test("Toybox's Binds line under the title: how many binds the tab holds and how to press them, Plain's without Hyper (card agent-bo-95423182)")
    func summary() {
        #expect(BindsKeyboard.Layer.hyper.summary(count: 50, layerKeys: [.capsLock]) == "50 on Hyper · hold Caps Lock and press")
        #expect(BindsKeyboard.Layer.hyper.summary(count: 1, layerKeys: [.rightOption]) == "1 on Hyper · hold Right Option and press")
        #expect(BindsKeyboard.Layer.shift.summary(count: 12, layerKeys: [.capsLock]) == "12 on Hyper + Shift · hold Caps Lock and Shift, then press")
        #expect(BindsKeyboard.Layer.shiftCtrl.summary(count: 2, layerKeys: [.capsLock]) == "2 on Hyper + Shift Ctrl · hold Caps Lock, Shift and Ctrl, then press")
        #expect(BindsKeyboard.Layer.plain.summary(count: 3, layerKeys: [.capsLock]) == "3 plain combos · no Hyper, just the combo")
        #expect(BindsKeyboard.Layer.plain.summary(count: 1, layerKeys: [.capsLock]) == "1 plain combo · no Hyper, just the combo")
        #expect(BindsKeyboard.Layer.alt.summary(count: 0, layerKeys: [.capsLock]) == "Nothing on Hyper + Alt yet · hold Caps Lock and Alt, then press")
    }
}
