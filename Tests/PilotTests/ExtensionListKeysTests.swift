import AppKit
import Foundation
@testable import PilotCore
import Testing
@testable import Pilot

/// To-do B (ADR 0010 amended 2026-10-17) in Hyper+Space: a key runs the selected row's action, a run that stays keeps the
/// panel open, an ask is asked in the panel, and the foot names Return's action, a keyed second and Cmd+K.
@MainActor
@Suite("Extension list sections and keys")
struct ExtensionListKeysTests {
    static let rows = #"""
    {"type":"list","items":[
     {"id":"a","title":"Buy milk","section":"Today","accessory":"Today","actions":[
       {"type":"run","command":"done","title":"Mark done","stay":true},
       {"type":"run","command":"undo","title":"Undo delete","key":"cmd+z","stay":true},
       {"type":"run","command":"edit","title":"Edit","key":"cmd+e","stay":true,"ask":{"text":"Buy milk"}},
       {"type":"run","command":"due","title":"Set due date","key":"cmd+d","stay":true,"ask":{"choices":[{"title":"Today","value":"2026-10-17"},{"title":"No date","value":""}]}},
       {"type":"run","command":"move","title":"Move up","key":"opt+up","stay":true,"context":{"id":"a","by":-1}},
       {"type":"run","command":"delete","title":"Delete","key":"cmd+delete","stay":true,"ask":{"confirm":"Delete it?"}},
       {"type":"run","command":"add","title":"Add","clear":true},
       {"type":"run","command":"done","title":"Close after"}]}]}
    """#

    static func items() throws -> [Extension.Item] {
        guard case .items(let items) = ExtensionRun.answer(rows.replacingOccurrences(of: "\n", with: " ")) else { throw CancellationError() }
        return items
    }

    private func session() throws -> (ExtensionListSession, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-ext-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id":"todo","title":"To-do","commands":[{"name":"todo","title":"To-do","mode":"list","run":"go","filter":"pilot"},{"name":"done","title":"Done","mode":"no-view","hidden":true,"run":"go"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        let ext = try Extension(folder: dir)
        let items = try Self.items()
        let session = ExtensionListSession(ext, ext.commands[0], inputs: .sample, run: { _, _ in .items(items) })
        return (session, dir)
    }

    @Test("A row carries its actions' keys; a refresh asks again even under Pilot's filter")
    func keys() async throws {
        let (session, dir) = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        var shown: [[MenuEntry]] = []
        session.show = { shown.append($0) }
        session.search("")
        await session.settled()
        session.search("milk")  // Pilot's filter: never asked again by a search
        let kept = await session.refresh(keeping: shown.first?.first)
        #expect(shown.count == 2, "the refresh asked again")
        #expect(kept == shown.last?.first?.id, "its item is still there, in its section")
        #expect(await session.refresh(keeping: MenuEntry(title: "gone", target: .action("ext.todo.todo#9"))) == nil)
        let row = try #require(shown.last?.first)
        #expect(row.ownKeys?.map { $0?.symbol } == [nil, "⌘Z", "⌘E", "⌘D", "⌥↑", "⌘⌫", nil, nil] && row.detail == "Today" && row.section == "Today")
    }

    @Test("A run that stays keeps the panel open, clear empties the search; an ask is asked in the panel; the rest close")
    func picks() async throws {
        let (session, dir) = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        var shown: [[MenuEntry]] = []
        session.show = { shown.append($0) }
        session.search("")
        await session.settled()
        let row = try #require(shown.first?.first)
        guard case .keep(false, false, _) = session.pick(row, action: 0) else { Issue.record("Mark done closed the panel"); return }
        guard case .keep(true, false, _) = session.pick(row, action: 6) else { Issue.record("Add kept its search"); return }
        guard case .close = session.pick(row, action: 7) else { Issue.record("a run without stay stayed"); return }
        guard case .push("Edit", let edit) = session.pick(row, action: 2), let ask = edit as? ExtensionAskSource else {
            Issue.record("Edit did not ask"); return
        }
        #expect(ask.opening == "Buy milk")
        var asked: [[MenuEntry]] = []
        ask.show = { asked.append($0) }
        ask.search("  ")
        #expect(asked.last?.map(\.title) == ["Type the new text"])
        guard case .stay = ask.pick(try #require(asked.last?.first), action: 0) else { Issue.record("a blank edit ran"); return }
        ask.search("Buy oat milk")
        #expect(asked.last?.map(\.title) == ["Buy oat milk"] && asked.last?.first?.ownActions == ["Edit"])
        guard case .keep(false, true, _) = ask.pick(try #require(asked.last?.first), action: 0) else { Issue.record("the edit did not stay"); return }
    }

    @Test("Choices list as rows Pilot filters; a confirm lists its question and Cancel, which runs nothing")
    func asks() throws {
        let rows = ExtensionAskSource.rows(.choices([.init(title: "Today", value: "d"), .init(title: "No date", value: "")]), label: "Set due date", typed: "")
        #expect(rows.map(\.title) == ["Today", "No date"] && rows.allSatisfy { !$0.isAnswer })
        let confirm = ExtensionAskSource.rows(.confirm("Delete it?"), label: "Delete", typed: "")
        #expect(confirm.map(\.title) == ["Delete it?", "Cancel"] && confirm.map { $0.ownActions ?? [] } == [["Delete"], ["Cancel"]])
        let ext = try ExtensionAskSourceFixture.ext()
        let action = try #require(Self.items().first?.actions[5])
        let source = ExtensionAskSource(.confirm("Delete it?"), action: action, in: ext, inputs: .sample)
        guard case .keep(false, true, let run) = source.pick(confirm[1], action: 0) else { Issue.record("Cancel did not go back"); return }
        #expect(run() == nil, "Cancel runs nothing")
        guard case .keep(false, true, _) = source.pick(confirm[0], action: 0) else { Issue.record("yes did not run and stay"); return }
    }

    @Test("The foot names Return's action, the second when it has a key, then Cmd+K; Escape closes")
    func foot() throws {
        func words(_ hints: [KeyHint]) -> [String] { hints.map { "\($0.key) \($0.label)" } }
        let command = try ExtensionAskSourceFixture.ext().commands[0]
        var nav = MenuNavigator(list: [], title: "To-do", live: true)
        nav.replaceList(ExtensionList.entries(try Self.items(), of: command))
        let model = MenuModel(nav: nav)
        #expect(words(model.footer) == ["Esc close"])
        #expect(words(model.footerCommands) == ["↵ Mark done", "⌘Z Undo delete", "⌘K Actions"])
        #expect(model.headings == [0: .section("Today")])
    }
}

/// A To-do folder for the ask and foot tests, made once.
@MainActor
enum ExtensionAskSourceFixture {
    static func ext() throws -> Extension {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-ext-ask-fixture")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id":"todo","title":"To-do","commands":[{"name":"todo","title":"To-do","mode":"list","run":"go","filter":"self"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        return try Extension(folder: dir)
    }
}
