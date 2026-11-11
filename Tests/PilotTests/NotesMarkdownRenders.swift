#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Offscreen renders of the notes panel's Markdown round (Q114 to Q116, Sven 2026-10-15) on SuperCmd's reference note:
/// the note as it reads, the caret on a line showing its marks, and the list with the keyboard previewing it, in
/// Instrument and Toybox, dark and light, through HUD.makePanel as Pilot shows it. Seeded in a temporary folder, never
/// Pilot's own. Opt-in like the other renders, in a moved home:
/// `CFFIXED_USER_HOME=/tmp/pilot-render-home PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter NotesMarkdownRenders`
extension SharedLook {
@MainActor
@Suite("Notes Markdown renders")
struct NotesMarkdownRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The reference note renders as it reads, with the caret's line raw, and previewed from the list, in both styles dark and light",
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

        let passes: [(PilotStyle, String, String)] = [(.instrument, "tokyo-night", "dark"), (.instrument, "folio", "light"),
                                                      (.toybox, "toybox-night", "dark"), (.toybox, "toybox", "light")]
        for (style, theme, side) in passes {
            look.style = style
            look.themeID = theme
            let dir = out.appendingPathComponent("notes-markdown-\(style.rawValue)-\(side)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for state in ["1-reference", "2-caret-line", "3-list-preview", "4-trash", "5-actions", "6-empty-note", "7-scratch"] {
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
                    if state == "2-caret-line" {
                        // The caret on the Attendees line: its `**` show, every other line stays drawn.
                        panel.makeFirstResponder(editor)
                        editor.setSelectedRange(NSRange(location: (editor.string as NSString).range(of: "Attendees").location + 4, length: 0))
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
