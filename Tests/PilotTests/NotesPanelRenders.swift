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
