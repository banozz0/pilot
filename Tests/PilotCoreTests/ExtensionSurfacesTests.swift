import Foundation
import Testing
@testable import PilotCore

/// Story 161 (ADR 0010 amended): a manifest's `surfaces` declare a page and a bar item, each a command and a pace held to
/// its floor; the command answers blocks (stats, meter, list, markdown, buttons) or a bar line, read leniently so a later
/// type never breaks an older Pilot. Fixtures are tiny shell programs in a temporary folder.
@Suite("Extension surfaces")
struct ExtensionSurfacesTests {
    /// An extension folder with `surfaces` and a `go` program printing `body`'s output.
    private func folder(surfaces: String, body: String = "true") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-surface-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"""
            {"id": "usage", "title": "Usage", "icon": "📊", "surfaces": \#(surfaces), "commands": [
              {"name": "summary", "title": "Usage summary", "mode": "no-view", "run": "go"},
              {"name": "page", "title": "Usage page", "mode": "no-view", "hidden": true, "run": "go"},
              {"name": "bar", "title": "Usage bar", "mode": "no-view", "hidden": true, "run": "go"}]}
            """#.utf8).write(to: dir.appending(path: Extension.manifestName))
        let program = dir.appending(path: "go")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return dir
    }

    @Test("A page and a bar item name their commands; the pace is the manifest's, held to 10 s for a page and 60 s for a bar item")
    func declared() throws {
        let dir = try folder(surfaces: #"{"page": {"command": "page", "every": 30}, "bar": {"command": "bar", "every": 5}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try Extension(folder: dir)
        #expect(ext.page?.command.name == "page" && ext.page?.every == 30 && ext.page?.kind == .page)
        #expect(ext.bar?.command.name == "bar" && ext.bar?.every == 60, "a bar item is never asked more than once a minute")
        #expect(Extension.Surface.pace(.page, asked: 2) == 10 && Extension.Surface.pace(.page, asked: nil) == 60)
        #expect(Extension.Surface.pace(.bar, asked: nil) == 120 && Extension.Surface.pace(.bar, asked: 99_999) == 3600)
    }

    @Test("No surfaces, or a shape Pilot does not know, declares nothing and still reads; a surface naming a missing command skips the folder")
    func lenient() throws {
        for surfaces in ["null", #""page""#, #"{"page": "page", "bar": {"every": 60}, "panel": {"command": "page"}}"#] {
            let dir = try folder(surfaces: surfaces)
            defer { try? FileManager.default.removeItem(at: dir) }
            let ext = try Extension(folder: dir)
            #expect(ext.page == nil && ext.bar == nil, "\(surfaces)")
        }
        let dir = try folder(surfaces: #"{"page": {"command": "board"}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: Extension.Problem.unknownSurfaceCommand(surface: "page", command: "board")) { try Extension(folder: dir) }
        #expect(Extension.Problem.unknownSurfaceCommand(surface: "page", command: "board").reason == #"surfaces.page: it has no command "board""#)
    }

    @Test("Blocks read every v1 type, tones and limits; unknown and broken blocks are skipped")
    func blocks() {
        let line = #"""
            {"type": "blocks", "blocks": [
              {"type": "stats", "items": [{"label": "Codex 5 h", "value": "52%", "tone": "warn"}, {"label": "PRs", "value": 3}, {"label": "no value"}]},
              {"type": "meter", "label": "Codex week", "percent": 118, "note": "resets Mon 09:00", "tone": "loud"},
              {"type": "list", "title": "Waiting on you", "items": [{"title": "Fix tiler", "subtitle": "pilot#12", "actions": [{"type": "open", "url": "https://github.com"}]}, {"subtitle": "no title"}]},
              {"type": "markdown", "text": "## Claude\nTokens **1.2M**"},
              {"type": "buttons", "actions": [{"type": "run", "command": "refresh", "title": "Refresh"}, {"type": "future"}]},
              {"type": "chart", "points": [1, 2]},
              {"type": "meter", "label": "no percent"}
            ]}
            """#
        // One JSON line, as a program prints it.
        guard case .blocks(let blocks, _) = ExtensionRun.surfaceAnswer(line.replacingOccurrences(of: "\n", with: " "), kind: .page) else { Issue.record("no blocks"); return }
        #expect(blocks == [
            .stats([.init(label: "Codex 5 h", value: "52%", tone: .warn), .init(label: "PRs", value: "3")]),
            .meter(.init(label: "Codex week", percent: 100, note: "resets Mon 09:00")),
            .list(title: "Waiting on you", items: [Extension.Item(title: "Fix tiler", subtitle: "pilot#12", actions: [.open("https://github.com")])]),
            .markdown("## Claude\nTokens **1.2M**"),
            .buttons([Extension.Item.Action(kind: .run(command: "refresh", context: nil), title: "Refresh")]),
        ])
        let many = #"{"type": "blocks", "blocks": ["# + Array(repeating: #"{"type": "markdown", "text": "x"}"#, count: 30).joined(separator: ",") + "]}"
        guard case .blocks(let capped, _) = ExtensionRun.surfaceAnswer(many, kind: .page) else { Issue.record("no blocks"); return }
        #expect(capped.count == Extension.Block.most)
    }

    @Test("omarchy-ideas T4: a hero and a strip decode, numbers as text, held to 3 stats and 7 columns; a broken one is skipped, the rest still read")
    func heroAndStrip() {
        let day = { (d: String) in #"{"label": "\#(d)", "glyph": "⛅️", "high": 25, "low": "18°"}"# }
        let line = #"{"type": "blocks", "blocks": ["# + [
            #"{"type": "hero", "glyph": "☀️", "value": 24, "unit": "°C", "place": "Valletta", "tone": "warn", "items": [{"label": "Feels", "value": "26°"}, {"label": "Wind", "value": "12 km/h"}, {"label": "Humidity", "value": 61, "tone": "fine"}, {"label": "UV", "value": 7}, {"label": "no value"}]}"#,
            #"{"type": "strip", "items": ["# + ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"].map(day).joined(separator: ",")
                + #", {"glyph": "☀️"}, {"label": "Bare"}]}"#,
            #"{"type": "hero", "glyph": "☀️", "place": "no value"}"#,
            #"{"type": "hero", "value": ["24"]}"#,
            #"{"type": "strip", "items": [{"label": "Thu"}, {"high": 25}]}"#,
            #"{"type": "strip", "items": "Thu"}"#,
            #"{"type": "hero", "value": "24°"}"#,
            #"{"type": "markdown", "text": "after"}"#,
        ].joined(separator: ",") + "]}"
        guard case .blocks(let blocks, _) = ExtensionRun.surfaceAnswer(line, kind: .popover) else { Issue.record("no blocks"); return }
        let column = { (d: String) in Extension.Block.Column(label: d, glyph: "⛅️", high: "25", low: "18°") }
        #expect(blocks == [
            .hero(.init(glyph: "☀️", value: "24", unit: "°C", place: "Valletta", tone: .warn,
                        stats: [.init(label: "Feels", value: "26°"), .init(label: "Wind", value: "12 km/h"), .init(label: "Humidity", value: "61", tone: .fine)])),
            .strip(["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"].map(column)),
            .hero(.init(value: "24°")),
            .markdown("after"),
        ])
        #expect(blocks.map(\.isWide) == [true, true, true, false])
        // A bar line's dropdown reads them too, and a meter's value stays a string: a number there still shows "N %".
        #expect(ExtensionRun.surfaceAnswer(#"{"type": "bar", "text": "☀️ 24°", "blocks": [{"type": "hero", "value": 24}, {"type": "meter", "label": "Rain", "percent": 30, "value": 30}]}"#, kind: .bar)
                == .bar(Extension.BarAnswer(text: "☀️ 24°", blocks: [.hero(.init(value: "24")), .meter(.init(label: "Rain", percent: 30))])))
    }

    @Test("A number reads as it did before T4: whole ones in full, 2e15 included; one past Int's range prints rather than traps")
    func numbers() {
        let line = #"{"type": "blocks", "blocks": [{"type": "stats", "items": [{"label": "a", "value": 2000000000000000}, {"label": "b", "value": 1e19}, {"label": "c", "value": 2.5}, {"label": "d", "value": -3}]}]}"#
        #expect(ExtensionRun.surfaceAnswer(line, kind: .page) == .blocks([.stats([.init(label: "a", value: "2000000000000000"), .init(label: "b", value: "1e+19"),
                                                                                 .init(label: "c", value: "2.5"), .init(label: "d", value: "-3")])]))
    }

    @Test("Pilot names every block type it draws (Q100), and each one named decodes; an unnamed one does not")
    func kinds() {
        let smallest: [String: String] = [
            "stats": #""items": [{"label": "a", "value": 1}]"#, "meter": #""label": "a", "percent": 1"#, "list": #""items": []"#,
            "markdown": #""text": "a""#, "buttons": #""actions": [{"type": "copy", "text": "a"}]"#, "section": #""title": "a""#,
            "chat": #""messages": []"#, "input": #""action": {"type": "run", "command": "a"}"#, "hero": #""value": 1"#,
            "strip": #""items": [{"label": "a", "high": 1}]"#, "note": #""text": "a""#,
            "links": #""items": [{"title": "a", "actions": [{"type": "copy", "text": "a"}]}]"#,
        ]
        #expect(Extension.Block.kinds.contains("hero") && Extension.Block.kinds.contains("strip"))
        #expect(Set(Extension.Block.kinds) == Set(smallest.keys) && Extension.Block.kinds.count == smallest.count)
        for kind in Extension.Block.kinds {
            let line = #"{"type": "blocks", "blocks": [{"type": "\#(kind)", "#  + (smallest[kind] ?? "") + "}]}"
            guard case .blocks(let blocks, _) = ExtensionRun.surfaceAnswer(line, kind: .page) else { Issue.record("\(kind): no blocks"); continue }
            #expect(blocks.count == 1, "\(kind) is named but does not decode")
        }
        #expect(ExtensionRun.surfaceAnswer(#"{"type": "blocks", "blocks": [{"type": "chart", "points": [1]}]}"#, kind: .page) == .blocks([]))
    }

    @Test("A bar line's text is one short line, its tone and dropdown blocks read; empty hides it; an error wins; a page answer is not a bar's")
    func bar() {
        let answer = ExtensionRun.surfaceAnswer(#"{"type": "bar", "text": "AI 52% and a lot more words than fit\nsecond", "tone": "alert", "blocks": [{"type": "markdown", "text": "hi"}]}"#,
                                                kind: .bar)
        #expect(answer == .bar(Extension.BarAnswer(text: "AI 52% and a lot more w…", tone: .alert, blocks: [.markdown("hi")])))
        guard case .bar(let read) = answer else { Issue.record("no bar"); return }
        #expect(read.text.count == Extension.BarAnswer.longest && read.text.hasSuffix("…") && read.shows)
        #expect(!Extension.BarAnswer(text: "  ").shows)
        #expect(ExtensionRun.surfaceAnswer(#"{"type": "error", "text": "gh is signed out"}"# + "\n" + #"{"type": "bar", "text": "x"}"#, kind: .bar)
                == .error("says: gh is signed out"))
        #expect(ExtensionRun.surfaceAnswer(#"{"type": "blocks", "blocks": []}"#, kind: .bar) == .error("sent no bar line"))
        #expect(ExtensionRun.surfaceAnswer("plain words", kind: .page) == .error(ExtensionRun.unreadable))
        #expect(ExtensionRun.surfaceAnswer("", kind: .page) == .error("sent no blocks"))
    }

    @Test("A surface runs its command with the surface named in the run message, and a slow one is stopped")
    func runs() async throws {
        let dir = try folder(surfaces: #"{"page": {"command": "page"}, "bar": {"command": "bar"}}"#,
                             body: #"read line; case "$line" in *'"surface":"bar"'*) echo '{"type":"bar","text":"ok"}';; *'"surface":"page"'*) echo '{"type":"blocks","blocks":[{"type":"markdown","text":"page"}]}';; *) sleep 5;; esac"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try Extension(folder: dir)
        #expect(await ExtensionRun.surface(try #require(ext.bar), inputs: .sample) == .bar(Extension.BarAnswer(text: "ok")))
        #expect(await ExtensionRun.surface(try #require(ext.page), inputs: .sample) == .blocks([.markdown("page")]))
        #expect(!String(decoding: ExtensionRun.message(ext.commands[0], inputs: .sample), as: UTF8.self).contains("surface"),
                "a command run from the menu is told no surface")
        let sleepy = try folder(surfaces: #"{"page": {"command": "page"}}"#, body: "sleep 5")
        defer { try? FileManager.default.removeItem(at: sleepy) }
        let started = Date()
        #expect(await ExtensionRun.surface(try #require(try Extension(folder: sleepy).page), inputs: .sample, timeout: .milliseconds(300))
                == .error("did not answer in 0.3 s"))
        #expect(Date().timeIntervalSince(started) < 3)
    }
}
