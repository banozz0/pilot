import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95423244: an extension row's actions, every type the design names, each with an optional title, and the
/// run message carrying a pushed or run command's context.
@Suite("Extension actions")
struct ExtensionActionTests {
    private func item(_ actions: String) throws -> Extension.Item {
        try JSONDecoder().decode(Extension.Item.self, from: Data(#"{"title": "row", "actions": [\#(actions)]}"#.utf8))
    }

    @Test("Each action type decodes with its field and its title; a missing field or unknown type is dropped")
    func decodes() throws {
        let row = try item("""
            {"type": "open", "url": "https://x.dev", "title": "Open site"}, {"type": "copy", "text": "a"}, {"type": "paste", "text": "b"},
            {"type": "push", "command": "detail", "context": {"repo": "pilot", "stars": 3, "tags": ["a"], "ok": true, "none": null}},
            {"type": "run", "command": "star"}, {"type": "hud", "text": "Hi"}, {"type": "pilot", "action": "windows.close"},
            {"type": "paste"}, {"type": "someday", "text": "x"}
            """)
        let context: JSONValue = .object(["repo": .string("pilot"), "stars": .number(3), "tags": .array([.string("a")]), "ok": .bool(true), "none": .null])
        #expect(row.actions.map(\.kind) == [.open("https://x.dev"), .copy("a"), .paste("b"), .push(command: "detail", context: context),
                                            .run(command: "star", context: nil), .hud("Hi"), .pilot("windows.close")])
        #expect(row.actions.map(\.label) == ["Open site", "Copy", "Paste", "Show", "Run", "Show message", "Run Pilot action"])
        #expect(row.dropped == 2, "the paste without text and the unknown type, counted for the log")
    }

    @Test("A Pilot action runs only a registered action; a shell, script, quicklink, app link or extension id is refused")
    func pilotAllowed() {
        let registered: Set = ["windows.close", "extensions.openFolder", "drive.shell:ls"]
        #expect(ExtensionList.allowsPilot("windows.close", isRegistered: registered.contains))
        #expect(!ExtensionList.allowsPilot("workspaces.go1", isRegistered: registered.contains), "not registered")
        for id in ["drive.shell:ls", "scripts.run:x.sh", "links.open:abc", "apps.open:com.apple.Terminal", "ext.demo.go"] {
            #expect(!ExtensionList.allowsPilot(id, isRegistered: registered.union([id]).contains), "\(id)")
        }
    }

    @Test("A run message carries the context a push or run hands on")
    func context() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-ctx-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"id": "demo", "title": "Demo", "commands": [{"name": "detail", "title": "D", "mode": "list", "run": "go"}]}"#.utf8)
            .write(to: dir.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: dir.appending(path: "go"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appending(path: "go").path)
        let command = try Extension(folder: dir).commands[0]
        let line = ExtensionRun.message(command, query: "x", context: .object(["repo": .string("pilot")]), inputs: .sample)
        let sent = try JSONDecoder().decode([String: JSONValue].self, from: line)
        #expect(sent == ["type": .string("run"), "extension": .string("demo"), "command": .string("detail"), "query": .string("x"),
                         "context": .object(["repo": .string("pilot")]), "preferences": .object([:]),
                         "paths": .object(["data": .string("/tmp/pilot-ext-data"), "cache": .string("/tmp/pilot-ext-cache")])])
    }

    @Test("A no-view command's action message is what it does; an error still wins")
    func noViewAction() {
        #expect(ExtensionRun.outcome(of: #"{"type": "action", "action": {"type": "copy", "text": "v1.2"}}"#)
                == .actions([Extension.Item.Action(kind: .copy("v1.2"))]))
        #expect(ExtensionRun.outcome(of: #"{"type": "action", "action": {"type": "copy", "text": "x"}}"# + "\n" + #"{"type": "error", "text": "no"}"#)
                == .error("no"))
        #expect(ExtensionRun.outcome(of: #"{"type": "action", "action": {"type": "someday"}}"#) == .error("sent an action Pilot does not know"))
    }

    @Test("Several action messages all run, in printed order; an error anywhere still wins; past eight the rest are dropped and counted")
    func severalActions() {
        func action(_ text: String) -> String { #"{"type": "action", "action": {"type": "copy", "text": "\#(text)"}}"# }
        let two = [action("a"), #"{"type": "hud", "text": "ignored"}"#, action("b")].joined(separator: "\n")
        #expect(ExtensionRun.outcome(of: two) == .actions([.copy("a"), .copy("b")]), "every action, in order; the HUD line gives way")
        #expect(ExtensionRun.outcome(of: two + "\n" + #"{"type": "error", "text": "no"}"#) == .error("no"))
        let ten = (1...10).map { action("\($0)") }.joined(separator: "\n")
        #expect(ExtensionRun.outcome(of: ten) == .actions((1...8).map { .copy("\($0)") }, dropped: 2))
        #expect(ExtensionRun.mostActions == 8)
    }

    @Test("A HUD's sound is kept only when it is a macOS alert sound by name, in a hud action and a hud message alike")
    func hudSound() throws {
        let row = try item(#"{"type": "hud", "text": "Done", "sound": "Glass"}, {"type": "hud", "text": "Quiet", "sound": "Airhorn"}"#)
        #expect(row.actions.map(\.kind) == [.hud("Done", sound: "Glass"), .hud("Quiet")])
        #expect(ExtensionRun.outcome(of: #"{"type": "hud", "text": "Done", "sound": "Submarine"}"#) == .hud("Done", sound: "Submarine"))
        #expect(ExtensionRun.outcome(of: #"{"type": "hud", "text": "Done", "sound": "glass"}"#) == .hud("Done"), "names match exactly")
        #expect(Extension.sounds.count == 14 && ["Basso", "Tink", "Hero", "Ping"].allSatisfy(Extension.sounds.contains))
    }

    @Test("A timer action decodes its title, seconds, pause, end and buttons, the end and buttons as actions themselves")
    func timer() throws {
        let row = try item(#"""
            {"type": "timer", "title": "Focus", "seconds": 1500, "paused": false,
             "end": {"type": "run", "command": "ended", "context": {"block": 2}},
             "actions": [{"type": "run", "command": "pause", "title": "Pause"}, {"type": "someday"},
                         {"type": "timer", "title": "Break", "seconds": 300, "actions": [{"type": "hud", "text": "x"}]},
                         {"type": "copy", "text": "c"}, {"type": "paste", "text": "p"}, {"type": "hud", "text": "fifth"}]}
            """#)
        guard case .timer(let timer) = try #require(row.actions.first).kind else { Issue.record("not a timer"); return }
        #expect(timer.title == "Focus" && timer.seconds == 1500 && !timer.paused && !timer.stops)
        #expect(timer.end == Extension.Item.Action(kind: .run(command: "ended", context: .object(["block": .number(2)]))))
        #expect(timer.actions.count == Extension.TimerSpec.most, "the unknown one dropped, the fifth past four too")
        #expect(timer.actions.map(\.label) == ["Pause", "Break", "Copy", "Paste"])
        #expect(timer.actions[1].kind == .timer(Extension.TimerSpec(title: "Break", seconds: 300, actions: [Extension.Item.Action(kind: .hud("x"))])))
        #expect(row.actions[0].label == "Focus", "its title names it on Cmd+K")
    }

    @Test("A timer's seconds run 1 to a day, whole; 0 stops; outside that, or missing, the action is dropped; no title says Timer")
    func timerSeconds() throws {
        func spec(_ fields: String) throws -> Extension.TimerSpec? {
            guard case .timer(let t)? = try item(#"{"type": "timer", \#(fields)}"#).actions.first?.kind else { return nil }
            return t
        }
        #expect(try spec(#""seconds": 1"#)?.seconds == 1)
        #expect(try spec(#""seconds": 86400"#)?.seconds == 86_400)
        #expect(try spec(#""seconds": 1500.0"#)?.seconds == 1500, "a whole number written with a point still counts")
        #expect(try spec(#""seconds": 0"#)?.stops == true)
        #expect(try spec(#""seconds": 0"#).map { Extension.Item.Action(kind: .timer($0)).label } == "Stop timer")
        #expect(try spec(#""seconds": 86401"#) == nil)
        #expect(try spec(#""seconds": -1"#) == nil)
        #expect(try spec(#""seconds": 2.5"#) == nil)
        #expect(try spec(#""title": "Focus""#) == nil, "no seconds")
        #expect(try spec(#""seconds": 60, "paused": true"#) == Extension.TimerSpec(title: "Timer", seconds: 60, paused: true))
        #expect(Extension.TimerSpec.countdown(1500) == "25:00" && Extension.TimerSpec.countdown(59) == "00:59")
        #expect(Extension.TimerSpec.countdown(3723) == "1:02:03" && Extension.TimerSpec.countdown(86_400) == "24:00:00")
    }

    @Test("An alert decodes its text, note, sound and up to three buttons; no text drops it")
    func alert() throws {
        let row = try item(#"""
            {"type": "alert", "text": "Focus done", "note": "4th block today. Take 15.", "sound": "Glass",
             "actions": [{"type": "run", "command": "rest", "title": "Start break"}, {"type": "run", "command": "stop", "title": "Stop"},
                         {"type": "someday"}, {"type": "hud", "text": "three"}, {"type": "hud", "text": "four"}]},
            {"type": "alert", "note": "no heading"}, {"type": "alert", "text": "Plain", "sound": "Nope"}
            """#)
        #expect(row.actions.count == 2 && row.dropped == 1, "the alert without text dropped")
        guard case .alert(let alert) = row.actions[0].kind, case .alert(let plain) = row.actions[1].kind else { Issue.record("not alerts"); return }
        #expect(alert.text == "Focus done" && alert.note == "4th block today. Take 15." && alert.sound == "Glass")
        #expect(alert.actions.map(\.label) == ["Start break", "Stop", "Show message"], "three at most, the unknown one skipped")
        #expect(plain == Extension.AlertSpec(text: "Plain"), "an unknown sound plays nothing")
        #expect(row.actions[1].label == "Show alert")
    }
}

/// Card agent-bo-95423244: Cmd+K on an extension row lists its own actions by title; only a live picker's rows are ever
/// replaced wholesale.
@Suite("Extension row actions in the menu")
struct ExtensionRowActionTests {
    private func row(_ title: String, actions: [String]?) -> MenuEntry {
        var row = MenuEntry(title: title, target: .action("ext.demo.rows#\(title)"), isAnswer: true)
        row.ownActions = actions
        return row
    }

    @Test("Cmd+K lists a live row's own actions by title; Return on one names it by index")
    func commandK() {
        var nav = MenuNavigator(list: [], title: "Rows", live: true)
        nav.replaceList([row("pilot", actions: ["Open site", "Copy", "Paste"])])
        _ = nav.handle(.commandK)
        #expect(nav.actions?.visible == [.own(0, "Open site"), .own(1, "Copy"), .own(2, "Paste")])
        _ = nav.handle(.down)
        #expect(nav.handle(.return) == .own(1, row("pilot", actions: ["Open site", "Copy", "Paste"])))
        #expect(nav.handle(.return) == .run(row("pilot", actions: ["Open site", "Copy", "Paste"])), "Return on the row is its first, run by the panel")
    }

    @Test("A static picker offers no actions and is never replaced; the menu neither")
    func guarded() {
        var picker = MenuNavigator(list: [row("login", actions: ["Copy"])], title: "Bitwarden")
        _ = picker.handle(.commandK)
        #expect(picker.actions == nil)
        picker.replaceList([row("other", actions: nil)])
        #expect(picker.rows.map(\.title) == ["login"])
        var menu = MenuNavigator(entries: [MenuEntry(title: "Close window", target: .action("windows.close"))])
        menu.query = "close"
        menu.replaceList([])
        #expect(menu.rows.map(\.title).contains("Close window"))
    }
}
