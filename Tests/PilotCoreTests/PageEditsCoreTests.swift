import Foundation
import Testing
@testable import PilotCore

/// A page's edits (2026-10-17, Markets' watchlist and search): a list's `reorder` and an input's `live` decode leniently and
/// within their limits, a move is its command run with `{key, to}`, and a live box hands on what is typed, blank too.
@Suite("Page edits core")
struct PageEditsCoreTests {
    static func block(_ line: String) -> Extension.Block? { SurfacesV2InteractiveCoreTests.block(line) }

    static let rows = #"[{"id":"SPY","title":"SPY"},{"id":"BTC","title":"BTC"},{"title":"no id"},{"id":"ETH","title":"ETH"}]"#

    @Test("A list's reorder names its command; any other shape, or none, is no reorder, and the rows read as before")
    func reorder() throws {
        guard case .list(_, let items, let reorder)? = Self.block(#"{"type":"list","reorder":{"command":"move"},"items":\#(Self.rows)}"#) else {
            Issue.record("no list"); return
        }
        #expect(reorder == .init(command: "move") && items.map(\.id) == ["SPY", "BTC", nil, "ETH"])
        for odd in [#""move""#, #"{}"#, #"{"command":""}"#, #"{"command":3}"#, "true"] {
            guard case .list(_, let kept, let none)? = Self.block(#"{"type":"list","reorder":\#(odd),"items":\#(Self.rows)}"#) else {
                Issue.record("no list for \(odd)"); continue
            }
            #expect(none == nil && kept.count == 4, "\(odd) declares no reorder")
        }
        guard case .list(_, _, let plain)? = Self.block(#"{"type":"list","items":\#(Self.rows)}"#) else { Issue.record("no list"); return }
        #expect(plain == nil)
    }

    @Test("A move is a run of the reorder's command with the row's id as key and its place after the move as to, in the run message's context")
    func movePayload() throws {
        let move = Extension.Block.Reorder(command: "move").action(key: "BTC", to: 0)
        #expect(move.kind == .run(command: "move", context: .object(["key": .string("BTC"), "to": .number(0)])) && move.ask == nil)
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-page-edits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"id":"markets","title":"Markets","commands":[{"name":"move","title":"Move","mode":"no-view","hidden":true,"run":"go"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        let ext = try Extension(folder: dir)
        guard case .run(let name, let context) = move.kind, let command = ext.noView(name) else { Issue.record("no move command"); return }
        let sent = String(decoding: ExtensionRun.message(command, context: context, inputs: .init(preferences: [:], data: URL(filePath: "/d"), cache: URL(filePath: "/c"))), as: UTF8.self)
        #expect(sent.contains(#""command":"move""#) && sent.contains(#""context":{"key":"BTC","to":0}"#), "\(sent)")
    }

    @Test("Moving a row: dropped on a later row it lands at that row's place, on an earlier one at its; no such id, past either end, or there already moves nothing")
    func moving() throws {
        guard case .list(_, let items, _)? = Self.block(#"{"type":"list","items":\#(Self.rows)}"#) else { Issue.record("no list"); return }
        func ids(_ key: String, _ to: Int) -> [String?]? { Extension.Block.Reorder.moving(items, key: key, to: to)?.map(\.id) }
        #expect(ids("SPY", 2) == ["BTC", nil, "SPY", "ETH"], "row 0 onto row 2 is to 2, not 3")
        #expect(ids("ETH", 0) == ["ETH", "SPY", "BTC", nil])
        #expect(ids("BTC", 1) == nil && ids("GOLD", 0) == nil && ids("SPY", 4) == nil && ids("SPY", -1) == nil)
    }

    @Test("An input is live only with live true: its pause is 250 ms, or its debounce held to 50 to 2000 ms; a live box hands on the text trimmed, blank too")
    func live() throws {
        func pause(_ fields: String) -> Duration?? {
            guard case .input(let input)? = Self.block(#"{"type":"input","action":{"type":"run","command":"find"}\#(fields)}"#) else { return .none }
            return .some(input.live)
        }
        #expect(pause(#","live":true"#) == .some(.milliseconds(250)) && pause(#","live":true,"debounce":400"#) == .some(.milliseconds(400)))
        #expect(pause(#","live":true,"debounce":10"#) == .some(.milliseconds(50)) && pause(#","live":true,"debounce":9000"#) == .some(.milliseconds(2000)))
        #expect(pause(#","live":true,"debounce":"fast""#) == .some(.milliseconds(250)), "a debounce that is no number is the default")
        #expect(pause("") == .some(nil) && pause(#","live":false"#) == .some(nil) && pause(#","debounce":300"#) == .some(nil) && pause(#","live":"yes""#) == .some(nil))
        let input = Extension.Block.Input(action: .init(kind: .run(command: "find", context: nil)), live: .milliseconds(250))
        #expect(input.typed("  btc \n").input == "btc" && input.typed("   ").input == "" && input.submit("   ") == nil)
        #expect(input.typed(String(repeating: "a", count: 5000)).input?.count == Extension.Item.Action.longest)
    }
}
