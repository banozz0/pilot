#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the Quick notes panel, direction B (P60): writing with the format bar over a selection, empty
/// Scratch's invitation, the drawer previewing another note, a search showing the matched lines, Cmd+K with its Format
/// group, and Cmd+Backspace's Trash question; Instrument on Tokyo Night in every state, on Porcelain writing, and Toybox
/// writing and with the drawer, drawn through HUD.makePanel as Pilot shows it. The notes are seeded in a temporary
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
        let passes: [(PilotStyle, String, [String])] = [(.instrument, "tokyo-night", all), (.instrument, "porcelain", ["1-writing"]),
                                                        (.toybox, "toybox-night", ["1-writing", "3-drawer"])]
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
            }
        }
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
                    // Escape is Done (T30): the panel's key monitor saves the sketch and holds the key, the list left alone;
                    // the sketch saved in attachments/, linked on the line under Route, and read back stroke for stroke.
                    try #require(NotesKey.pressed(53, [], "\u{1b}", model: model, responder: panel.firstResponder) == .held,
                                 "Escape while sketching was not held")
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
