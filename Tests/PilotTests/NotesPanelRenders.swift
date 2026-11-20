#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the Quick notes panel, direction B (P60): writing with the format bar over a selection, empty
/// Scratch's invitation, the drawer previewing another note, a search showing the matched lines, Cmd+K with its Format
/// group, and Cmd+Backspace's Trash question; Instrument on Tokyo Night in every state and on Porcelain writing,
/// drawn through HUD.makePanel as Pilot shows it. The notes are seeded in a temporary
/// folder, never Pilot's own. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter NotesPanelRenders`
extension SharedLook {
@MainActor
@Suite("Notes panel renders")
struct NotesPanelRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    static let hero = """
        # Ship the notes panel
        Round 1 for **Pilot**: keep it _Omarchy-calm_, the text is the hero.

        ## Today
        - [x] Read SuperCmd's quick notes
        - [x] Sketch Rice and Calm, dark and light
        - [ ] Wire `Hyper+Shift+W` to the panel
        - [ ] Trash confirm inside the panel

        ## Links
        - https://supercmd.sh
        - [AeroSpace](https://github.com/nikitabobko/AeroSpace) keeps it over every workspace and full-screen app
        """

    static let spanish = """
        # Spanish: ser vs estar
        **Ser** is what something _is_; **estar** is how or where it is.

        - [x] Soy de Malta
        - [ ] Estoy cansado, ¿y tú?
        - [ ] Lesson 7 in `~/code/espanol` on Friday
        """

    @Test("The notes panel renders direction B's states", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("notes-panel")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }

        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try Self.seed(folder)
        let hero = try #require(try store.load().first { $0.title == "Ship the notes panel" })

        let all = ["1-writing", "2-scratch", "3-drawer", "4-search", "5-actions", "6-trash", "7-pinned"]
        let passes: [(PilotStyle, String, [String])] = [(.instrument, "tokyo-night", all), (.instrument, "porcelain", ["1-writing"])]
        for (style, theme, states) in passes {
            look.style = style
            look.themeID = theme
            for state in states {
                let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
                model.reload()
                model.open(state == "2-scratch" ? NoteStore.scratch : hero.id)
                switch state {
                case "3-drawer":
                    model.focusList()
                    while model.selectedNote?.title != "Spanish: ser vs estar", model.rows.last?.id != model.selection { model.stepList(1) }
                    try #require(model.selectedNote?.title == "Spanish: ser vs estar")
                case "4-search":
                    model.focusList()
                    model.queryField = "oat"
                    try #require(model.rows.map(\.title).contains("Groceries"))
                case "5-actions": model.openActions()
                case "6-trash": model.askTrash()
                // The head's pin filled: the panel pinned on screen.
                case "7-pinned": model.pinnedOnScreen = true
                default: break
                }
                let panel = HUD.makePanel(NotesPanelView(model: model).frame(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height),
                                          surface: .notes)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if state == "1-writing", let editor = NotesMarkdownRenders.editors(in: content).first(where: \.isEditable) {
                    // A selection, so the format bar rises over it.
                    panel.makeFirstResponder(editor)
                    editor.setSelectedRange((editor.string as NSString).range(of: "the text is the hero"))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                }
                content.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(content, scale: 2))
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-\(state).png"))
                if state == "5-actions", theme == "tokyo-night" { try Self.actionsClose(model, panel: panel, content: content) }
            }
        }
    }

    /// Cmd+K's actions close as a popover does (Sven, 2026-11-20): a press on them keeps them; a press elsewhere in the
    /// note, its window losing the keyboard, Pilot giving way and another app in front each close them; Escape still
    /// does. The press is handed to the watch as Pilot's local monitor hands it, never posted to the screen.
    static func actionsClose(_ model: NotesModel, panel: NSWindow, content: NSView) throws {
        func watches(_ view: NSView) -> [NotesPopoverWatch.Watch] {
            (view as? NotesPopoverWatch.Watch).map { [$0] } ?? view.subviews.flatMap(watches)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        func watch() throws -> NotesPopoverWatch.Watch { try #require(watches(content).first, "no watch behind Cmd+K's actions") }
        func press(_ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func reopen() throws {
            model.perform(.actions)
            settle()
            try #require(model.actions != nil, "Cmd+K did not open the actions")
        }
        try #require(model.actions != nil)
        let w = try watch()
        w.pressed(press(w.convert(NSPoint(x: w.bounds.midX, y: w.bounds.midY), to: nil)))
        try #require(model.actions != nil, "a press on the actions closed them")
        w.pressed(press(NSPoint(x: 40, y: 40)))
        try #require(model.actions == nil, "a press outside the actions left them open")
        // Its release handed on, the head's Actions (or Cmd+K) opens them again.
        NotesPopoverWatch.released()
        settle()
        try reopen()
        let posts: [(NotificationCenter, Notification.Name, Any?)] = [
            (.default, NSWindow.didResignKeyNotification, panel),
            (.default, NSApplication.didResignActiveNotification, NSApp),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification, nil),
        ]
        for (center, name, object) in posts {
            _ = try watch()
            let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            center.post(name: name, object: object, userInfo: name == NSWorkspace.didActivateApplicationNotification ? [NSWorkspace.applicationUserInfoKey: finder as Any] : nil)
            try #require(model.actions == nil, "\(name.rawValue) left the actions open")
            try reopen()
        }
        let escape = try #require(NotesKey.pressed(53, [], "\u{1b}", model: model, responder: nil))
        try #require(escape == .closeActions)
        model.perform(escape)
        try #require(model.actions == nil, "Escape left the actions open")
    }

    /// The note round 2 drew notes in (shots 6c-*): a ticked checklist under Pack, a heading with nothing under it yet.
    static let trip = """
        # Trip plan
        Leave **Friday 07:30**, train to the airport.

        ## Pack
        - [x] Passport
        - [ ] Charger and the _small_ adapter
        - [ ] Rain jacket

        ## Route

        """

    /// UI redesign T26 (shots 6c-insert and round 1's 6a): the format bar over a selection, the head's Insert menu with
    /// Sketch under the pointer, and the note's ticked checklist, in Instrument on Tokyo Night and Porcelain, written as
    /// `T26-<theme>-<state>.png`.
    @Test("The notes panel renders the format bar and the Insert menu", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderInsert() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("notes-panel")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }

        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(folder: folder)
        _ = try store.load()
        try Data(Self.trip.utf8).write(to: folder.appending(path: "trip-plan-100010.md"))
        let trip = try #require(try store.load().first { $0.title == "Trip plan" })

        look.style = .instrument
        for theme in ["tokyo-night", "porcelain"] {
            look.themeID = theme
            for state in ["select", "insert", "checklist"] {
                let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
                model.reload()
                model.open(trip.id)
                let view = NotesPanelView(model: model, inserting: state == "insert", insertHovered: state == "insert" ? .sketch : nil)
                let panel = HUD.makePanel(view.frame(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height), surface: .notes)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                if state == "select", let editor = NotesMarkdownRenders.editors(in: content).first(where: \.isEditable) {
                    panel.makeFirstResponder(editor)
                    editor.setSelectedRange((editor.string as NSString).range(of: "train to the airport"))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                }
                content.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(content, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("T26-\(theme)-\(state).png"))
            }
        }
    }

    /// Round 2's route (shots 6c-draw and 6c-done) in a 560 × 220 sketch: a house, a dotted way to a train, on to a plane,
    /// in the note's own ink, and the train's track in the amber marker.
    static let route: [Sketch.Stroke] = {
        func pen(_ points: [(Double, Double)], width: Double = Sketch.penWidth + 0.5) -> Sketch.Stroke {
            Sketch.Stroke(width: width, points: points.map { Sketch.Point($0.0, $0.1) })
        }
        func dots(from: Double, to: Double, y: (Double) -> Double) -> [Sketch.Stroke] {
            stride(from: from, through: to, by: 13).map { x in pen([(x, y(x))], width: 3.5) }
        }
        let house = [pen([(44, 172), (44, 112), (80, 80), (116, 112), (116, 172), (44, 172)]), pen([(68, 172), (68, 146), (90, 146), (90, 172)])]
        let way = dots(from: 132, to: 326, y: { 140 - 26 * sin(($0 - 132) / 34) })
        let train = [pen([(352, 104), (420, 104), (430, 114), (430, 150), (420, 160), (352, 160), (342, 150), (342, 114), (352, 104)]),
                     pen([(354, 122), (418, 122)]), pen([(358, 166), (346, 182)]), pen([(414, 166), (426, 182)])]
        let track = Sketch.Stroke(tool: .marker, ink: SketchBoard.inks[0], width: Sketch.markerWidth, points: [Sketch.Point(334, 196), Sketch.Point(438, 194)])
        let onward = dots(from: 444, to: 486, y: { 130 - ($0 - 444) * 1.1 })
        let plane = [pen([(482, 64), (536, 40), (516, 92), (506, 72), (482, 64)]), pen([(506, 72), (536, 40)])]
        return house + way + [track] + train + onward + plane
    }()

    /// UI redesign T29 (shots 6c-draw and 6c-done): the canvas opened from Insert › Sketch on the empty line under Route,
    /// the route drawn, the pen picked; then a note with a saved sketch drawn inline in the theme's ink, Edit sketch over
    /// it, and the round checklist boxes with `_small_` slanted. Tokyo Night then Porcelain, the same SVG in both, so a
    /// sketch's ink follows the theme rather than the first look's. Written as `T29-<theme>-<state>.png`.
    @Test("The notes panel renders the sketch canvas", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderSketch() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("notes-panel")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        let board = SketchBoard.shared
        defer { board.done(); (look.style, look.themeID, look.glass) = saved }

        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(folder: folder)
        _ = try store.load()
        let link = try Sketch(width: 560, height: 220, strokes: Self.route).save(in: folder, now: .now)
        let head = "# Trip plan\nLeave **Friday 07:30**, train to the airport.\n\n## Route\n"
        // A note to draw in per theme, so the first pass's saved link never reaches the second's.
        for n in 0..<2 { try Data(head.utf8).write(to: folder.appending(path: "trip-plan-10001\(n).md")) }
        try Data((head + link + "\n\n## Pack\n- [x] Passport\n- [ ] Charger and the _small_ adapter\n").utf8)
            .write(to: folder.appending(path: "trip-plan-done-100011.md"))
        let notes = try store.load()
        let done = try #require(notes.first { $0.id == "trip-plan-done-100011.md" })

        look.style = .instrument
        for (n, theme) in ["tokyo-night", "porcelain"].enumerated() {
            look.themeID = theme
            let drawn = try #require(notes.first { $0.id == "trip-plan-10001\(n).md" })
            for state in ["draw", "done"] {
                let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
                model.reload()
                model.open(state == "draw" ? drawn.id : done.id)
                let view = NotesPanelView(model: model, sketchHover: state == "done")
                let panel = HUD.makePanel(view.frame(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height), surface: .notes)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                // The editor given the keyboard, its caret at the note's end (the draw note's: the empty line under Route).
                let editor = try #require(NotesMarkdownRenders.editors(in: content).first { $0.isEditable })
                panel.makeFirstResponder(editor)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                if state == "draw" {
                    NotesInsert.sketch.perform(model.editor)
                    try #require(board.isOpen, "Insert › Sketch did not open the canvas")
                    board.sketch.strokes = Self.route
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                } else {
                    // Scrolled to the checklist under the sketch: the panel is shorter than round 2's frame.
                    editor.scrollRangeToVisible(NSRange(location: (editor.string as NSString).length, length: 0))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                }
                content.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(content, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("T29-\(theme)-\(state).png"))
                if state == "draw" {
                    // Escape is Done (T30): the Notes page's key read on the first pass, the panel's on the second; each
                    // saves the sketch and holds the key, the list left alone, with the window holding the keyboard as
                    // the canvas leaves it; the sketch saved in attachments/, linked on the line under Route, and read
                    // back stroke for stroke.
                    let escape = n == 0 ? NotesPageKeys.key(53, [], "\u{1b}", model: model, responder: panel.firstResponder)
                        : NotesKey.pressed(53, [], "\u{1b}", model: model, responder: panel.firstResponder)
                    try #require(escape == .held, "Escape while sketching was not held (\(n == 0 ? "page" : "panel"))")
                    try #require(!board.isOpen && !model.listFocused, "Escape while sketching left the canvas or opened the list")
                    let saved = try #require(model.text.components(separatedBy: "\n").first { $0.hasPrefix("![Sketch](attachments/sketch-") })
                    try #require(model.text.hasPrefix(head + saved + "\n"), "the link is not on the line under Route")
                    let path = String(saved.dropFirst("![Sketch](".count).dropLast())
                    try #require(try Sketch.load(from: folder.appending(path: path)).strokes.count == Self.route.count)
                } else if theme == "porcelain" {
                    // Edit sketch, the last pass: the sketch reopened, a stroke taken out, Done writes over the same file,
                    // and the editor draws it anew rather than the cached picture.
                    let path = String(link.dropFirst("![Sketch](".count).dropLast())
                    let before = try #require(editor.pictureRects().first?.image)
                    board.open(on: editor, link: path)
                    try #require(board.isOpen, "Edit sketch did not reopen the sketch")
                    board.sketch.strokes.removeLast()
                    board.done()
                    try #require(try Sketch.load(from: folder.appending(path: path)).strokes.count == Self.route.count - 1)
                    try #require(model.text.contains(link), "the link moved")
                    try #require(editor.pictureRects().first?.image !== before, "the sketch was drawn from the cache")
                    // The window closing mid-sketch keeps it (T30): its willClose is Done while the editor is still there.
                    let links = Sketch.count(in: model.text)
                    board.open(on: editor)
                    board.sketch.strokes = Self.route
                    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: panel)
                    try #require(!board.isOpen, "the window closing left the canvas open")
                    try #require(Sketch.count(in: model.text) == links + 1, "the window closing lost the sketch")
                    let kept = try #require(model.text.components(separatedBy: "\n").last { $0.hasPrefix("![Sketch](attachments/sketch-") && $0 != link })
                    let keptPath = String(kept.dropFirst("![Sketch](".count).dropLast())
                    try #require(try Sketch.load(from: folder.appending(path: keptPath)).strokes.count == Self.route.count)
                    // Another note opened mid-sketch (spec-end review 1, blocker 1): the sketch ends in the note it was
                    // drawn in and is saved in that note's file; the note opened after gets none of it.
                    let other = "packing-list-100012.md"
                    try Data("# Packing list\nSocks.\n".utf8).write(to: folder.appending(path: other))
                    model.reload()
                    let first = model.current
                    board.open(on: editor)
                    board.sketch.strokes = Self.route
                    model.open(other)
                    try #require(!board.isOpen && model.current == other, "opening another note left the canvas open")
                    func drawn(_ text: String) -> [String] {
                        text.components(separatedBy: "\n").filter { $0.hasPrefix("![Sketch](attachments/sketch-") && $0 != link && $0 != kept }
                    }
                    let onDisk = try store.load()
                    try #require(onDisk.filter { !drawn($0.text).isEmpty }.map(\.id) == [first], "the sketch is not in the note it was drawn in alone")
                    try #require(Sketch.count(in: model.text) == 0, "the sketch reached the note opened after")
                    // The quick notes panel hiding while a sketch is open in another window (the Notes page's; here this
                    // render's, which is not the panel): that sketch stays open (spec-end review 2). One in the panel
                    // itself ends there, before the panel's save (hide's Done, for the panel's window only).
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    try #require(editor.string == model.text, "the editor does not show the note opened")
                    board.open(on: editor)
                    board.sketch.strokes = Self.route
                    NotesPanel.shared.hide()
                    try #require(board.isOpen, "hiding the panel ended a sketch drawn outside it")
                    board.done()
                    model.flush()
                    let hidden = try String(contentsOf: folder.appending(path: model.current), encoding: .utf8)
                    try #require(drawn(hidden).count == 1, "the sketch was lost")
                    // The notes folder changed mid-sketch, as the Notes page's folder line and `pilot set notes.folder` do
                    // (spec-end review 2), through the panel's own shared model and an Engine that never launches, which
                    // holds the setting: the sketch ends in its note in the old folder, and the new folder gets none of it.
                    // Then the model swapped for the new folder mid-sketch (the next show, the page's reload): the old
                    // model's sketch ends in its own note first.
                    let engine = Engine()
                    let old = folder.appending(path: "old", directoryHint: .isDirectory), moved = folder.appending(path: "new", directoryHint: .isDirectory)
                    for dir in [old, moved] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
                    engine.settings.notesFolder = old.path
                    defer { engine.settings.notesFolder = nil }
                    let noteA = "folder-note-100030.md"
                    try Data("# Folder note\nDrawn before the folder changes.\n".utf8).write(to: old.appending(path: noteA))
                    let shared = NotesPanel.shared.currentModel()
                    try #require(shared.store.folder.path == NotesFolder.folder(old.path).path, "the panel's model is not on the old folder")
                    shared.reload()
                    shared.open(noteA)
                    let sharedPanel = HUD.makePanel(NotesPanelView(model: shared).frame(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height),
                                                    surface: .notes)
                    defer { sharedPanel.close() }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    let sharedContent = try #require(sharedPanel.contentView)
                    let sharedEditor = try #require(NotesMarkdownRenders.editors(in: sharedContent).first { $0.isEditable })
                    sharedPanel.makeFirstResponder(sharedEditor)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    let inOld = { Sketch.count(in: try String(contentsOf: old.appending(path: noteA), encoding: .utf8)) }
                    let inNew = { try NoteStore(folder: moved).load().map { Sketch.count(in: $0.text) }.reduce(0, +) }
                    board.open(on: sharedEditor)
                    try #require(board.isOpen, "the canvas did not open on the panel's model")
                    board.sketch.strokes = Self.route
                    try NotesPanel.shared.changeFolder(to: moved, move: false)
                    try #require(!board.isOpen, "changing the folder left the canvas open")
                    try #require(try inOld() == 1 && inNew() == 0, "the sketch is not in its note in the old folder alone")
                    board.open(on: sharedEditor)
                    board.sketch.strokes = Self.route
                    let next = NotesPanel.shared.currentModel()
                    try #require(next !== shared && !board.isOpen, "the model swapped with the canvas still open")
                    try #require(try inOld() == 2 && inNew() == 0, "the swap lost the sketch or moved it to the new folder")
                }
            }
        }
    }

    /// Nine notes over Scratch, Pinned, Today, Yesterday and two older days (Earlier), each file dated as it was last edited.
    static func seed(_ folder: URL) throws -> NoteStore {
        let store = NoteStore(folder: folder)
        _ = try store.load()
        let calendar = Calendar.current, today = calendar.startOfDay(for: .now)
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: DateComponents(day: -daysAgo, hour: hour, minute: minute), to: today)!
        }
        let notes: [(id: String, text: String, edited: Date)] = [
            ("Scratch.md", "# Scratch\n\nbuy oat milk\n", at(0, 14, 32)),
            ("pilot-v1-punch-list-100001.md", "# Pilot v1 punch list\n- [ ] Licence screen\n", at(1, 10, 2)),
            ("ship-the-notes-panel-100002.md", hero, at(0, 14, 20)),
            ("shippers-club-call-100003.md", "# Shippers Club call\nDemo the notes panel.\n", at(0, 9, 10)),
            ("spanish-ser-vs-estar-100004.md", spanish, at(1, 21, 40)),
            ("groceries-100005.md", "# Groceries\n- [ ] oat milk\n- [ ] limes\n", at(1, 18, 5)),
            ("aerospace-binds-to-try-100006.md", "# AeroSpace binds to try\n", at(2, 16, 22)),
            ("disk-cleanup-list-100007.md", "# Disk cleanup list\n", at(2, 11, 3)),
            ("reading-list-100008.md", "# Reading list\n", at(3, 20, 15)),
        ]
        for note in notes {
            let url = folder.appending(path: note.id)
            try Data(note.text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: note.edited], ofItemAtPath: url.path)
        }
        try store.setPinned("pilot-v1-punch-list-100001.md", true)
        return store
    }
}
}
#endif
