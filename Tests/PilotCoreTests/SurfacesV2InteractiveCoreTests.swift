import Foundation
import Testing
@testable import PilotCore

/// Surfaces v2, P3 (SPEC story 165, ADR 0010 amended): the interactive additions decode leniently and within their
/// limits, a v1 answer reads as before, a run's ask comes to the right `input`, and the run message carries `input` and
/// Pilot's defaults only when there are some.
@Suite("Surfaces v2 interactive core")
struct SurfacesV2InteractiveCoreTests {
    /// The one block a popover answer of `block` (a JSON object) reads as; nil when it is skipped.
    static func block(_ block: String) -> Extension.Block? {
        guard case .blocks(let blocks, _) = ExtensionRun.surfaceAnswer(#"{"type":"blocks","blocks":["# + block.replacingOccurrences(of: "\n", with: " ") + #"]}"#, kind: .popover) else { return nil }
        return blocks.first
    }

    /// The first row of a list block holding `row`.
    static func row(_ row: String) -> Extension.Item? {
        guard case .list(_, let items, _)? = block(#"{"type":"list","items":["# + row + #"]}"#) else { return nil }
        return items.first
    }

    @Test("A chat keeps its last 20 messages, skips an unknown role or a broken one, reads times, and folds tool turns in a row")
    func chat() throws {
        let many = (0..<25).map { #"{"role":"user","text":"m\#($0)","at":1791622680}"# }.joined(separator: ",")
        guard case .chat(let long)? = Self.block(#"{"type":"chat","working":true,"messages":[\#(many)]}"#) else { Issue.record("no chat"); return }
        #expect(long.messages.count == 20 && long.messages.first?.text == "m5" && long.working)
        #expect(long.messages.first?.at == Date(timeIntervalSince1970: 1_791_622_680))
        let line = #"{"type":"chat","messages":[{"role":"user","text":"Is it green?"},{"role":"tool","text":"read 2 files"},{"role":"tool","text":"ran tests"},{"role":"system","text":"skip"},{"role":"assistant"},{"role":"assistant","text":"**Yes**"},{"role":"tool","text":"ran 3 tools"}]}"#
        guard case .chat(let chat)? = Self.block(line) else { Issue.record("no chat"); return }
        #expect(!chat.working && chat.messages.map(\.role) == [.user, .tool, .tool, .assistant, .tool])
        #expect(chat.shown.map(\.text) == ["Is it green?", "ran 2 tools", "**Yes**", "ran 3 tools"], "two in a row fold, one alone keeps its text")
        #expect(Self.block(#"{"type":"chat"}"#) == nil && Self.block(#"{"type":"chat","messages":[]}"#) == .chat(.init(messages: [])))
    }

    @Test("An input needs a run: an alt of another kind is dropped, an action of another kind drops the block; Return and Option+Return hand on the text")
    func input() throws {
        let line = #"{"type":"input","placeholder":"Reply…","action":{"type":"run","command":"send","context":{"ref":"s1"}},"alt":{"type":"run","command":"send","title":"Interrupt","context":{"ref":"s1","interrupt":true}}}"#
        guard case .input(let input)? = Self.block(line) else { Issue.record("no input"); return }
        #expect(input.placeholder == "Reply…" && input.action.kind == .run(command: "send", context: .object(["ref": .string("s1")])))
        #expect(input.submit("  hi there \n")?.input == "hi there" && input.submit("hi")?.kind == input.action.kind)
        #expect(input.submit("hi", alt: true)?.kind == .run(command: "send", context: .object(["ref": .string("s1"), "interrupt": .bool(true)])))
        #expect(input.submit("   ") == nil, "blank sends nothing")
        #expect(input.submit(String(repeating: "x", count: 5000))?.input?.count == Extension.Item.Action.longest)
        guard case .input(let noAlt)? = Self.block(#"{"type":"input","action":{"type":"run","command":"send"},"alt":{"type":"open","url":"https://x"}}"#) else {
            Issue.record("no input"); return
        }
        #expect(noAlt.alt == nil && noAlt.submit("hi", alt: true) == nil)
        #expect(Self.block(#"{"type":"input","action":{"type":"open","url":"https://x"}}"#) == nil && Self.block(#"{"type":"input"}"#) == nil)
    }

    @Test("A row's badges and inline buttons: three each at most, a broken one skipped never the row, long badges cut, unknown icons dropped")
    func badgesAndInline() throws {
        let row = try #require(Self.row(#"""
        {"title":"Pilot coordinator 2","badges":[{"text":"idle"},{"text":"review","tone":"fine"},{"text":""},{"tone":"warn"},{"text":"a very long badge text here","tone":"loud"},{"text":"fourth"}],
         "inline":[{"type":"push","command":"chat","icon":"bubble","title":"Reply"},{"type":"run","command":"sleep","icon":"🌙"},{"type":"warp"},{"type":"run","command":"x","icon":"rocket.fancy","title":"X"},{"type":"run","command":"y","icon":"moon"}],
         "actions":[{"type":"copy","text":"x"}]}
        """#))
        #expect(row.badges == [.init(text: "idle"), .init(text: "review", tone: .fine), .init(text: "a very long bad…")])
        #expect(row.inline.map(\.icon) == ["bubble", "🌙", nil] && row.inline.count == Extension.Item.mostInline)
        #expect(row.actions == [.copy("x")])
        #expect(Self.row(#"{"title":"t","badges":"nope","inline":{"type":"open"},"actions":[]}"#).map { $0.badges.isEmpty && $0.inline.isEmpty } == true)
    }

    @Test("Only a run asks: text, choices or confirm, the shape read leniently; destructive is read")
    func askDecode() throws {
        let row = try #require(Self.row(#"""
        {"title":"t","actions":[
          {"type":"run","command":"rename","title":"Rename…","ask":{"text":"Layout rework"}},
          {"type":"run","command":"tag","title":"Tag","ask":{"choices":[{"title":"review","value":"review"},{"title":"No tag"},{"value":"orphan"}]}},
          {"type":"run","command":"close","title":"Close…","destructive":true,"ask":{"confirm":"Close it? Its terminal ends."}},
          {"type":"run","command":"odd","ask":{"choices":[]}},
          {"type":"push","command":"chat","ask":{"text":"x"}}]}
        """#))
        #expect(row.actions.map(\.ask) == [.text("Layout rework"), .choices([.init(title: "review", value: "review"), .init(title: "No tag", value: "No tag")]),
                                           .confirm("Close it? Its terminal ends."), nil, nil])
        #expect(row.actions.map(\.destructive) == [false, false, true, false, false])
    }

    @Test("Asking: the text starts as given and runs trimmed, blank runs nothing; a choice runs with its value; a confirm runs with nothing extra")
    func asking() throws {
        let rename = Extension.Item.Action(kind: .run(command: "rename", context: nil), title: "Rename…", ask: .text("Layout rework"))
        var asking = try #require(Extension.Asking(rename))
        #expect(asking.text == "Layout rework" && asking.save()?.input == "Layout rework")
        asking.text = "  Layout rework build "
        let saved = try #require(asking.save())
        #expect(saved.input == "Layout rework build" && saved.ask == nil && saved.kind == rename.kind && saved.title == "Rename…")
        asking.text = "  "
        #expect(asking.save() == nil)
        let tag = Extension.Item.Action(kind: .run(command: "tag", context: nil), title: "Tag", ask: .choices([.init(title: "No tag", value: "none")]))
        let picking = try #require(Extension.Asking(tag))
        #expect(picking.save() == nil && picking.pick(.init(title: "No tag", value: "none")).input == "none")
        let close = Extension.Item.Action(kind: .run(command: "close", context: nil), title: "Close…", destructive: true, ask: .confirm("Close?"))
        let confirming = try #require(Extension.Asking(close))
        #expect(confirming.save()?.input == nil && confirming.save()?.ask == nil && confirming.yes == "Close")
        #expect(Extension.Asking(.copy("x")) == nil && Extension.Asking(Extension.Item.Action(kind: .run(command: "go", context: nil))) == nil)
    }

    @Test("A blocks answer's refresh is held to 2-60 s; missing or not a number is none and the line still reads")
    func refresh() {
        func every(_ value: String) -> Int?? {
            guard case .blocks(_, let every) = ExtensionRun.surfaceAnswer(#"{"type":"blocks","refresh":\#(value),"blocks":[{"type":"markdown","text":"x"}]}"#, kind: .page) else { return .none }
            return .some(every)
        }
        #expect(every("2") == .some(2) && every("0.4") == .some(2) && every("1") == .some(2) && every("30") == .some(30) && every("600") == .some(60))
        #expect(every(#""fast""#) == .some(nil) && every("null") == .some(nil) && every("-5") == .some(nil))
    }

    @Test("v1 answers read as before: a row without badges or inline, a page without refresh, an action without ask or icon")
    func v1Unchanged() throws {
        let row = try #require(Self.row(#"{"title":"pilot","subtitle":"main","icon":"🌿","actions":[{"type":"open","url":"https://github.com"},{"type":"run","command":"sync","title":"Sync"}]}"#))
        #expect(row == Extension.Item(title: "pilot", subtitle: "main", icon: "🌿",
                                      actions: [.open("https://github.com"), Extension.Item.Action(kind: .run(command: "sync", context: nil), title: "Sync")]))
        #expect(ExtensionRun.surfaceAnswer(#"{"type":"blocks","blocks":[{"type":"markdown","text":"hi"}]}"#, kind: .page) == .blocks([.markdown("hi")]))
        #expect(ExtensionRun.surfaceAnswer(#"{"type":"blocks","blocks":[{"type":"markdown","text":"hi"}]}"#, kind: .page) == .blocks([.markdown("hi")], refresh: nil))
    }

    /// A one-command extension in a temporary folder, for its run message.
    static func command() throws -> (Extension.Command, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id":"demo","title":"Demo","icon":"🧪","commands":[{"name":"send","title":"Send","mode":"no-view","run":"go"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        return (try Extension(folder: dir).commands[0], dir)
    }

    @Test("A run message carries the answer as input and Pilot's defaults as pilot; without them it is the v1 message, no key added")
    func runMessage() throws {
        let (command, dir) = try Self.command()
        defer { try? FileManager.default.removeItem(at: dir) }
        var inputs = ExtensionRun.Inputs.sample
        inputs.pilot = ["repos": "/Users/ada/code", "terminal": "com.mitchellh.ghostty"]
        let sent = try JSONDecoder().decode(JSONValue.self, from: ExtensionRun.message(command, context: .object(["ref": .string("s1")]), input: "hi", inputs: inputs))
        guard case .object(let fields) = sent else { Issue.record("not an object"); return }
        #expect(fields["input"] == .string("hi") && fields["context"] == .object(["ref": .string("s1")]))
        #expect(fields["pilot"] == .object(["repos": .string("/Users/ada/code"), "terminal": .string("com.mitchellh.ghostty")]))
        let v1 = try JSONDecoder().decode(JSONValue.self, from: ExtensionRun.message(command, inputs: ExtensionRun.Inputs.sample))
        guard case .object(let plain) = v1 else { Issue.record("not an object"); return }
        #expect(Set(plain.keys) == ["type", "extension", "command", "preferences", "paths"])
    }
}
