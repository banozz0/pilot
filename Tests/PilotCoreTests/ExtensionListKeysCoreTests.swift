import Foundation
import Testing
@testable import PilotCore

/// To-do B (ADR 0010 amended 2026-10-17): a list item's `section` and `accessory`, an action's `key`, `stay` and `clear`
/// decode leniently, the keys a search field or Pilot owns are refused, and a live picker heads its rows by section.
@Suite("Extension list sections and keys core")
struct ExtensionListKeysCoreTests {
    /// The items of a list answer holding `items` (JSON objects).
    static func items(_ items: String) -> [Extension.Item] {
        let line = #"{"type":"list","items":[\#(items)]}"#.replacingOccurrences(of: "\n", with: " ")
        guard case .items(let found) = ExtensionRun.answer(line) else { return [] }
        return found
    }

    @Test("A key reads as modifiers then one key, and only one the field and Pilot leave free")
    func keys() {
        typealias Key = Extension.Item.Action.Key
        let e = Key("cmd+e")
        #expect(e?.code == 14 && e?.command == true && e?.symbol == "⌘E")
        #expect(Key("opt+up")?.symbol == "⌥↑" && Key("cmd+delete")?.symbol == "⌘⌫" && Key("Cmd+Shift+C")?.symbol == "⇧⌘C")
        #expect(Key("ctrl+opt+return")?.symbol == "⌃⌥↵" && Key("cmd+z") != nil && Key("cmd+0") != nil)
        for refused in ["e", "shift+e", "cmd+a", "cmd+c", "cmd+v", "cmd+x", "cmd+k", "cmd+q", "cmd+w", "cmd+1", "cmd+9", "opt+e", "opt+3",
                        "cmd+left", "cmd+tab", "hyper+e", "cmd+", "", "cmd+ee"] {
            #expect(Key(refused) == nil, "\(refused)")
        }
        #expect(Key("cmd+shift+a") != nil, "shifted, it is no editing key")
        #expect(e?.matches(code: 14, command: true, option: false, control: false, shift: false) == true)
        #expect(e?.matches(code: 14, command: true, option: false, control: false, shift: true) == false)
    }

    @Test("Section, accessory, key, stay and clear decode; a bad one is dropped, never the row; only a run stays")
    func decode() throws {
        let rows = Self.items(#"""
        {"title":"Buy milk","section":"Today","accessory":"Fri","actions":[
          {"type":"run","command":"done","title":"Mark done","stay":true},
          {"type":"run","command":"edit","key":"cmd+e","stay":true,"ask":{"text":"Buy milk"}},
          {"type":"copy","text":"Buy milk","key":"cmd+c","stay":true},
          {"type":"run","command":"add","clear":true}]},
        {"title":"Call mum","section":"","accessory":{"text":"Mon 12","tone":"alert"}},
        {"title":"Plain","accessory":7}
        """#)
        #expect(rows.map(\.title) == ["Buy milk", "Call mum", "Plain"])
        let milk = rows[0]
        #expect(milk.section == "Today" && milk.accessory == .init(text: "Fri"))
        #expect(milk.actions.map(\.stay) == [true, true, false, true], "a copy never stays; clear stays")
        #expect(milk.actions.map { $0.key?.symbol } == [nil, "⌘E", nil, nil], "⌘C is the field's")
        #expect(milk.actions[3].clear && !milk.actions[0].clear)
        #expect(rows[1].section == nil && rows[1].accessory == .init(text: "Mon 12", tone: .alert))
        #expect(rows[2].accessory == nil)
        // Answered, an action keeps its key and its stay.
        let answered = try #require(milk.actions[1].answering(" Buy oat milk "))
        #expect(answered.input == "Buy oat milk" && answered.key?.symbol == "⌘E" && answered.stay && answered.ask == nil)
    }

    @Test("A live picker's rows carry their section, accessory and keys, gathered and headed by section")
    func sections() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-ext-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"id":"todo","title":"To-do","commands":[{"name":"todo","title":"To-do","mode":"list","run":"go","filter":"self"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        let command = try Extension(folder: dir).commands[0]
        let rows = ExtensionList.entries(Self.items(#"""
        {"title":"Add “x”"},
        {"title":"late","section":"Overdue","accessory":"Fri 16","actions":[{"type":"run","command":"done"},{"type":"run","command":"edit","key":"cmd+e"}]},
        {"title":"now","section":"Today"},
        {"title":"also late","section":"Overdue"},
        {"title":"did","section":"Done","actions":[{"type":"run","command":"undone"}]}
        """#), of: command)
        #expect(rows[1].detail == "Fri 16" && rows[1].ownKeys?.map { $0?.symbol } == [nil, "⌘E"] && rows[4].ownKeys == nil)
        var nav = MenuNavigator(list: [], title: "To-do", live: true)
        nav.replaceList(rows)
        #expect(nav.rows.map(\.title) == ["Add “x”", "late", "also late", "now", "did"], "a section never heads twice")
        #expect(MenuGroups.sections(nav.rows) == [1: .section("Overdue"), 3: .section("Today"), 4: .section("Done")])
        #expect(MenuGroups.bySection(rows.filter { $0.section == nil }).map(\.title) == ["Add “x”"])
        #expect(MenuGroups.sections([MenuEntry(title: "a", target: .action("a"))]).isEmpty, "a tidy list has no heading")
    }
}
