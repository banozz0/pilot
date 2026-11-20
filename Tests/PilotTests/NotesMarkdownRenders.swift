#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the notes panel's Markdown round (Q114 to Q116, Sven 2026-10-15) on SuperCmd's reference note:
/// the note as it reads, the caret on a line showing its marks, and the list with the keyboard previewing it, in
/// Instrument, dark and light, through HUD.makePanel as Pilot shows it. Seeded in a temporary folder, never
/// Pilot's own. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter NotesMarkdownRenders`
extension SharedLook {
@MainActor
@Suite("Notes Markdown renders")
struct NotesMarkdownRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The reference note renders as it reads, with no marks on the caret's line (in a bold word, a link, a list line), and previewed from the list, in Instrument dark and light",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let saved = (look.style, look.themeID, look.glass)
        look.glass = false
        defer { (look.style, look.themeID, look.glass) = saved }
        let out = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-notes-md-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try NotesPanelRenders.seed(folder)
        let reference = try store.create(text: NotesMarkdownTests.reference)

        let passes: [(PilotStyle, String, String)] = [(.instrument, "tokyo-night", "dark"), (.instrument, "folio", "light")]
        for (style, theme, side) in passes {
            look.style = style
            look.themeID = theme
            let dir = out.appendingPathComponent("notes-markdown-\(style.rawValue)-\(side)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // The caret's line, dark only: in a bold word, in a link's words and in a list line (Sven, 2026-11-20, Q285).
            let carets = side == "dark" ? ["2-caret-bold", "2-caret-link", "2-caret-list"] : []
            for state in ["1-reference"] + carets + ["3-list-preview", "4-trash", "5-actions", "6-empty-note", "7-scratch"] {
                let model = NotesModel(store: store, defaults: UserDefaults(suiteName: testSuite())!)
                model.reload()
                model.open(state == "3-list-preview" || state == "7-scratch" ? NoteStore.scratch : reference.id)
                switch state {
                case "3-list-preview":
                    model.focusList()
                    while model.selectedNote?.id != reference.id, model.rows.last?.id != model.selection { model.stepList(1) }
                    try #require(model.selectedNote?.id == reference.id)
                case "4-trash": model.askTrash()
                case "5-actions": model.openActions(); model.stepActions(3)
                case "6-empty-note":
                    model.new()
                    model.text = "\n"
                default: break
                }
                let tall = state.hasPrefix("1") || state.hasPrefix("2")
                let size = CGSize(width: NotesPanel.defaultSize.width, height: tall ? 1120 : NotesPanel.defaultSize.height)
                let panel = HUD.makePanel(NotesPanelView(model: model).frame(width: size.width, height: size.height), surface: .notes)
                defer { panel.close() }
                let content = try #require(panel.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                if let editor = Self.editors(in: content).first(where: \.isEditable) {
                    if state.hasPrefix("2-caret") {
                        // The caret inside a bold word, a link or a list line, the editor holding the keyboard: no mark shows.
                        panel.makeFirstResponder(editor)
                        try #require(panel.firstResponder === editor, "the editor does not have the keyboard")
                        let s = editor.string as NSString
                        let at = ["2-caret-bold": "Attendees", "2-caret-link": "search ranking", "2-caret-list": "Ship the notes"][state]!
                        editor.setSelectedRange(NSRange(location: s.range(of: at).location + 4, length: 0))
                        editor.restyle()
                        for mark in ["**Attendees", "[search ranking", "](https://example.com", "- Ship", "**Tip"] {
                            let i = s.range(of: mark).location
                            let gone = editor.textStorage?.attribute(.notesHidden, at: i, effectiveRange: nil) != nil
                                || editor.textStorage?.attribute(.notesBullet, at: i, effectiveRange: nil) != nil
                            try #require(gone, "\(state): \(mark) shows")
                        }
                    } else {
                        // The caret on the empty last line, so no line shows its marks.
                        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                    }
                    editor.restyle()
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                content.layoutSubtreeIfNeeded()
                let rep = try #require(snapshot(content, scale: 2))
                try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(state).png"))
            }
        }
    }

    static func editors(in view: NSView) -> [NotesTextView] {
        (view as? NotesTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }
}
}
#endif
