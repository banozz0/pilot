#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Notes page (task N1; direction B, P60), opt-in like the other renders: the whole window on the page in Instrument
/// and Toybox under Lagoon (dark) and Porcelain (light) at 1440 by 900, Instrument at 760 too; then the page alone in
/// each style on Lagoon: the docked list searched, asking before the Trash, a note showing a picture pasted in (notes
/// round 2), empty Scratch's invitation, Cmd+K, and the folder line asking whether to move the notes to a picked folder.
/// The notes are the panel renders' nine, seeded in a temporary folder, never Pilot's own.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter NotesPageRenders`
extension SharedLook {
@MainActor
@Suite("Notes page renders")
struct NotesPageRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The Notes page renders in every style, dark and light, with its states",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start an engine on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("notes-page")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let toml = (home as NSString).appendingPathComponent(".aerospace.toml")
        if !FileManager.default.fileExists(atPath: toml) { FileManager.default.createFile(atPath: toml, contents: Data()) }

        let engine = try SharedLook.HomeRenders.engine()
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-render-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try NotesPanelRenders.seed(folder)
        let hero = try #require(try store.load().first { $0.title == "Ship the notes panel" })
        let pictured = try Self.pictureNote(store)
        // The window's page reads the panel's model, which reads the folder setting.
        engine.settings.notesFolder = folder.path
        defer { engine.settings.notesFolder = nil }
        NotesPanel.shared.currentModel().open(hero.id)
        let only = Self.env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains { name.contains($0) } } ?? true }

        let model = AppWindowModel(defaults: try #require(UserDefaults(suiteName: testSuite())))
        let window = AppWindowController.makeWindow(content: NSHostingView(rootView: AppWindowView(model: model).environment(engine)))
        defer { window.close() }
        let frame = try #require(window.contentView?.superview)
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }

        let states: [(name: String, start: NotesPage.Start, open: String)] = [
            ("search", .init(query: "oat"), hero.id), ("trash", .init(trashing: hero.id), hero.id), ("picture", .init(), pictured),
            ("scratch", .init(), NoteStore.scratch), ("actions", .init(actions: true), hero.id),
            ("move", .init(picked: URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Vault/Inbox")), hero.id),
        ]
        for theme in ["lagoon", "porcelain"] {
            look.themeID = theme
            for style in PilotStyle.allCases {
                let name = style.rawValue
                look.style = style
                AppWindowController.applyLook(look, to: window)
                let widths = theme == "lagoon" && style == .instrument ? [1440, 760] : [1440]
                for width in widths where wanted("window-\(name)-\(theme)-\(width)") {
                    window.setContentSize(NSSize(width: CGFloat(width), height: 900))
                    model.go(AppPlace(.notes))
                    RunLoop.main.run(until: Date().addingTimeInterval(0.9))
                    frame.layoutSubtreeIfNeeded()
                    let rep = try #require(snapshot(frame, scale: 2))
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("window-\(name)-\(theme)-\(width).png"))
                    // The folder's line shows under the list without a scroll (direction B: one line, 2026-10-18).
                    if width == 1440 {
                        let words = try recognisedText(in: rep).map(\.text).joined(separator: " ")
                        #expect(words.contains("Change"), "\(name) \(theme): \(words)")
                    }
                }
                for state in states where theme == "lagoon" && wanted("page-\(name)-\(state.name)") {
                    let notes = NotesModel(store: store, defaults: try #require(UserDefaults(suiteName: testSuite())))
                    notes.reload()
                    notes.open(state.open)
                    let page = NotesGround { NotesPage(onScreen: false, model: notes, start: state.start) }
                        .styled(.page(.notes)).environment(engine).frame(width: 1000, height: 640).pilotTheme(look: look)
                    try writeRender(page, to: dir.appendingPathComponent("page-\(name)-\(state.name).png"))
                }
            }
        }
    }
}

/// The page on its style's ground, as the window's frame lays it.
private struct NotesGround<Content: View>: View {
    @Environment(\.ink) private var ink
    @ViewBuilder var content: Content
    var body: some View { content.styleLayout().background(ink.background) }
}
}

@MainActor
extension SharedLook.NotesPageRenders {
    /// A note with a picture saved in attachments/ as a paste saves one: a 1200 by 700 px gradient with a caption.
    static func pictureNote(_ store: NoteStore) throws -> String {
        let size = NSSize(width: 1200, height: 700)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 30)
            let caption = NSAttributedString(string: "Moodboard", attributes: [.font: NSFont.systemFont(ofSize: 96, weight: .bold), .foregroundColor: NSColor.white])
            caption.draw(at: NSPoint(x: 80, y: 80))
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let link = try NoteAttachments.save(png, named: nil, ext: "png", in: store.folder, now: .now)
        let note = try store.create(text: "# Moodboard\nThe colours for the site.\n\(link)\nAnd one more line under it.\n")
        return note.id
    }
}
#endif
