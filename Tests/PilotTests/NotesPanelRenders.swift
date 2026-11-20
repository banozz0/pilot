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
    /// Picture… under the pointer, and the note's ticked checklist, in Instrument on Tokyo Night and Porcelain, written as
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
                let view = NotesPanelView(model: model, inserting: state == "insert", insertHovered: state == "insert" ? .picture : nil)
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

    /// A sketch a note already holds, as T29 saved it (a house, a dotted way, the amber marker under it): the sketch
    /// canvas is gone (Sven, 2026-11-20), but the SVG still shows as the note's picture, in the theme's ink. Tokyo Night
    /// then Porcelain, written as `sketch-kept-<theme>.png`.
    static let keptSVG = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="560" height="220" viewBox="0 0 560 220" data-pilot-sketch="1">
        <path class="pilot-pen" d="M44 172 L44 112 L80 80 L116 112 L116 172 L44 172" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        <path class="pilot-pen" d="M68 172 L68 146 L90 146 L90 172" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        <path class="pilot-marker" d="M150 196 L438 194" fill="none" stroke="#e0af68" stroke-opacity="0.35" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>
        <path class="pilot-pen" d="M150 140 L150 140" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/>
        <path class="pilot-pen" d="M180 128 L180 128" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/>
        <path class="pilot-pen" d="M352 104 L420 104 L430 114 L430 150 L420 160 L352 160 L342 150 L342 114 L352 104" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>

        """

    @Test("A note's saved sketch still shows as its picture", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func renderKeptSketch() throws {
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
        let attachments = folder.appending(path: NoteAttachments.folder)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data(Self.keptSVG.utf8).write(to: attachments.appending(path: "sketch-20261120-101500.svg"))
        let text = "# Trip plan\nLeave **Friday 07:30**, train to the airport.\n\n## Route\n![Sketch](attachments/sketch-20261120-101500.svg)\n\n## Pack\n- [x] Passport\n"
        try Data(text.utf8).write(to: folder.appending(path: "trip-plan-100011.md"))

        look.style = .instrument
        for theme in ["tokyo-night", "porcelain"] {
            look.themeID = theme
            let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
            model.reload()
            model.open("trip-plan-100011.md")
            let panel = HUD.makePanel(NotesPanelView(model: model).frame(width: NotesPanel.defaultSize.width, height: NotesPanel.defaultSize.height),
                                      surface: .notes)
            defer { panel.close() }
            let content = try #require(panel.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let editor = try #require(NotesMarkdownRenders.editors(in: content).first { $0.isEditable })
            try #require(editor.pictureRects().count == 1, "the saved sketch does not show")
            try #require(model.text == text, "showing the sketch changed the note")
            content.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(content, scale: 2))
            try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("sketch-kept-\(theme).png"))
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
