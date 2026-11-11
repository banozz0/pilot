#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pilot's text window (T49), opt-in like the other renders. First the files: fixtures in a temporary folder, never
/// Sven's, opened through the route a Finder open takes (TextWindows.load), edited and saved as Cmd+S saves, then read
/// back byte for byte: UTF-8 with a byte order mark and CRLF in a 0600 file, UTF-16 LE, a guessed Latin-1 with CR, mixed
/// line endings, a link to a Markdown file, an extended attribute; never saved over: read-only, locked, in the Trash;
/// refused: a binary, a file over 20 MB; a change on disk reloads a clean file and waits over an edited one. Then the window
/// in Instrument and Toybox under Tokyo Night (dark) and Porcelain (light): Markdown drawn, raw, plain text, the changed-on-disk
/// question.
/// `CFFIXED_USER_HOME=<fresh dir> PILOT_RENDER_DIR=<fresh dir> swift test --filter TextWindowRenders`
extension SharedLook {
@MainActor
@Suite("Text window renders")
struct TextWindowRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Text files open, save as they were and render in every style",
          .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to start on Sven's data")
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("text-window")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = FileManager.default.temporaryDirectory.appending(path: "pilot-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: files) }
        try await Self.roundTrips(files)
        try Self.renders(files, to: dir)
    }

    /// Opens, edits and saves each fixture, then reads its bytes back.
    static func roundTrips(_ files: URL) async throws {
        let fm = FileManager.default
        // UTF-8 with a mark and CRLF, readable by its owner alone.
        let bomCRLF = files.appending(path: "windows.txt")
        try Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\n".utf8)).write(to: bomCRLF)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bomCRLF.path)
        let doc = try #require(TextWindows.load(bomCRLF, alert: false))
        #expect(doc.model.text == "one\ntwo\n")
        #expect(doc.model.format == TextFileFormat(encoding: .utf8, bom: true, lineEnding: .crlf))
        #expect(!doc.model.markdown && !doc.isDocumentEdited)
        // The document keeps no undo manager: its window's takes the text view's undo.
        doc.makeWindowControllers()
        #expect(doc.undoManager == nil && doc.windowControllers.first?.window?.undoManager != nil)
        // Typing back to the file's text is clean again.
        doc.model.text += "x"
        #expect(doc.isDocumentEdited && doc.model.edited)
        doc.model.text.removeLast()
        #expect(!doc.isDocumentEdited)
        doc.model.text += "three"
        try save(doc)
        #expect(try Data(contentsOf: bomCRLF) == Data([0xEF, 0xBB, 0xBF] + Array("one\r\ntwo\r\nthree".utf8)))
        #expect((try fm.attributesOfItem(atPath: bomCRLF.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!doc.isDocumentEdited)
        // The same file again is the same document.
        #expect(TextWindows.load(bomCRLF, alert: false) === doc)
        doc.close()

        // UTF-16 LE with its mark.
        let utf16 = files.appending(path: "wide.txt")
        try Data([0xFF, 0xFE] + "café\n".data(using: .utf16LittleEndian)!).write(to: utf16)
        let wide = try #require(TextWindows.load(utf16, alert: false))
        #expect(wide.model.text == "café\n" && wide.model.format.encoding == .utf16LittleEndian && wide.model.format.bom)
        wide.model.text += "ünï"
        try save(wide)
        #expect(try Data(contentsOf: utf16) == Data([0xFF, 0xFE] + "café\nünï".data(using: .utf16LittleEndian)!))
        wide.close()

        // Latin-1 with CR: every byte reads; text Latin-1 cannot hold is never written lossy.
        let latin = files.appending(path: "old.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x78]).write(to: latin)
        let old = try #require(TextWindows.load(latin, alert: false))
        #expect(old.model.text == "café\nx" && old.model.format.encoding == .isoLatin1 && old.model.format.lineEnding == .cr)
        #expect(old.model.format.guessed && old.model.format.name == "Latin-1?")
        old.model.text += "y"
        try save(old)
        #expect(try Data(contentsOf: latin) == Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x78, 0x79]))
        old.model.text += "€"
        #expect(!old.model.format.canEncode(old.model.text))
        #expect(throws: TextFileFormat.Problem.self) { try old.data(ofType: TextWindows.plainText) }
        old.close()
        #expect(try Data(contentsOf: latin) == Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x78, 0x79]))

        // Mixed line endings: each line keeps its own, byte for byte; a new line is LF.
        let mixedURL = files.appending(path: "mixed.txt")
        let mixedBytes = Array("a\r\nb\nc\rd\r\n".utf8)
        try Data(mixedBytes).write(to: mixedURL)
        let mixed = try #require(TextWindows.load(mixedURL, alert: false))
        #expect(mixed.model.format.mixed && mixed.model.format.lineName == "Mixed")
        mixed.model.text += "e\nf"
        try save(mixed)
        #expect(try Data(contentsOf: mixedURL) == Data(mixedBytes + Array("e\nf".utf8)))
        mixed.close()

        // Never saved over (Q105): read-only (0444), locked (Finder's Locked, uchg), moved to the Trash. The bytes and the
        // edits stay, and the error says why.
        for (name, lock) in [("readonly.txt", "chmod 444"), ("locked.txt", "chflags uchg")] {
            let url = files.appending(path: name)
            try Data("keep\n".utf8).write(to: url)
            let doc = try #require(TextWindows.load(url, alert: false))
            try shell("\(lock) '\(url.path)'")
            defer { try? shell("chflags nouchg '\(url.path)'; chmod 644 '\(url.path)'") }
            doc.model.text += "edit"
            #expect(refusal(doc)?.contains("is read-only or locked, so Pilot didn’t save it") == true, "\(name)")
            #expect(try Data(contentsOf: url) == Data("keep\n".utf8) && doc.isDocumentEdited && doc.model.text == "keep\nedit")
            doc.close()
        }
        let trash = files.appending(path: ".Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let doomed = files.appending(path: "doomed.txt"), trashed = trash.appending(path: "doomed.txt")
        try Data("old\n".utf8).write(to: doomed)
        let moved = try #require(TextWindows.load(doomed, alert: false))
        try fm.moveItem(at: doomed, to: trashed)
        // What NSDocument's presentedItemDidMove does when Finder moves the file to the Trash.
        moved.fileURL = trashed.resolvingSymlinksInPath()
        moved.model.text += "new"
        #expect(refusal(moved)?.contains("is in the Trash, so Pilot didn’t save it") == true)
        #expect(try Data(contentsOf: trashed) == Data("old\n".utf8))
        moved.close()

        // An extended attribute (a tag, a quarantine) stays through a save.
        let tagged = files.appending(path: "tagged.txt")
        try Data("t\n".utf8).write(to: tagged)
        try shell("xattr -w dev.banozz.pilot.test kept '\(tagged.path)'")
        let tag = try #require(TextWindows.load(tagged, alert: false))
        tag.model.text += "x"
        try save(tag)
        tag.close()
        try shell("test \"$(xattr -p dev.banozz.pilot.test '\(tagged.path)')\" = kept")

        // A link opens its target: a save writes the target and the link stays a link.
        let target = files.appending(path: "target.md")
        try "# Title\n".write(to: target, atomically: true, encoding: .utf8)
        let link = files.appending(path: "link.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = try #require(TextWindows.load(link, alert: false))
        #expect(linked.model.markdown && linked.fileURL?.lastPathComponent == "target.md")
        linked.model.text += "body\n"
        try save(linked)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: link, encoding: .utf8) == "# Title\nbody\n")
        linked.close()

        // A file emptied on disk while its window shows it untouched: the plain editor shows the empty text, never the
        // old one (a later keystroke and Cmd+S would write that back).
        testApp()
        let emptied = files.appending(path: "emptied.txt")
        try Data("abc\n".utf8).write(to: emptied)
        let shown = try #require(TextWindows.load(emptied, alert: false))
        let host = NSHostingView(rootView: TextWindowView(model: shown.model).styled(.page(.notes)).frame(width: 600, height: 400))
        let frame = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        frame.contentView = host
        defer { frame.close() }
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))
        let editor = try #require(plainView(in: host))
        #expect(editor.string == "abc\n")
        try changeOnDisk(emptied, to: "", after: 2)
        shown.reload()
        #expect(await pump(2) { editor.string == shown.model.text })
        #expect(shown.model.text == "" && editor.string == "", "the editor kept \(editor.string.debugDescription)")
        shown.close()

        // A binary file is not text.
        let binary = files.appending(path: "blob.txt")
        try Data([0x50, 0x00, 0x4B]).write(to: binary)
        #expect(TextWindows.load(binary, alert: false) == nil)
        // Over 20 MB is refused from its size, before a byte is read (a sparse file).
        let huge = files.appending(path: "huge.txt")
        fm.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(TextWindows.largest + 1))
        try handle.close()
        #expect(TextWindows.load(huge, alert: false) == nil)
        #expect(TextWindows.type(of: files.appending(path: "a.md")) == TextWindows.markdown)
        #expect(TextWindows.type(of: files.appending(path: "a.txt")) == TextWindows.plainText)
        #expect(TextWindows.type(of: files.appending(path: "a.png")) == nil)

        // A change on disk: a clean file reads it; an edited one keeps the edits and asks.
        let notes = files.appending(path: "notes.md")
        try "first\n".write(to: notes, atomically: true, encoding: .utf8)
        let watched = try #require(TextWindows.load(notes, alert: false))
        try changeOnDisk(notes, to: "second\n", after: 2)
        watched.diskChanged()
        #expect(watched.model.text == "second\n" && !watched.isDocumentEdited)
        watched.model.text += "mine"
        try changeOnDisk(notes, to: "third\n", after: 4)
        watched.diskChanged()
        #expect(watched.model.text == "second\nmine" && watched.model.changedOnDisk != nil)
        watched.reload()
        #expect(watched.model.text == "third\n" && watched.model.changedOnDisk == nil && !watched.isDocumentEdited)
        // Another process's writes, uncoordinated as vim's or git's: in place, then an editor's atomic rename. Heard
        // without a nudge.
        try shell("sleep 1.1; printf 'fourth\\n' > '\(notes.path)'")
        #expect(await pump { watched.model.text == "fourth\n" }, "an in-place write was not heard: \(watched.model.text)")
        try shell("sleep 1.1; printf 'fifth\\n' > '\(notes.path).tmp' && mv '\(notes.path).tmp' '\(notes.path)'")
        #expect(await pump { watched.model.text == "fifth\n" }, "a rename over the file was not heard: \(watched.model.text)")
        watched.model.text += "mine"
        try shell("sleep 1.1; printf 'sixth\\n' > '\(notes.path)'")
        #expect(await pump { watched.model.changedOnDisk != nil }, "a write under edits did not ask")
        #expect(watched.model.text == "fifth\nmine")
        // Keep mine, then Pilot's own save: its replace of the file is heard and asks nothing.
        watched.keepMine()
        try save(watched)
        #expect(await !pump(1.5) { watched.model.changedOnDisk != nil || watched.model.text != "fifth\nmine" })
        #expect(try String(contentsOf: notes, encoding: .utf8) == "fifth\nmine" && !watched.isDocumentEdited)
        watched.close()
    }

    /// Runs `script` in a child shell and waits for it.
    static func shell(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(script) failed")
    }

    /// Waits until `done` holds, at most `seconds`, off the main queue meanwhile: the watch's events arrive on it, and a
    /// run loop turned inside this test's own main-queue job never drains it.
    static func pump(_ seconds: TimeInterval = 4, until done: () -> Bool) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while !done() && Date() < until { try? await Task.sleep(for: .milliseconds(50)) }
        return done()
    }

    /// The plain editor's text view under `view`.
    static func plainView(in view: NSView) -> PlainTextView? {
        (view as? PlainTextView) ?? view.subviews.lazy.compactMap { plainView(in: $0) }.first
    }

    /// The save's error, which NSDocument shows over the window; nil when it saved.
    static func refusal(_ doc: TextDocument) -> String? {
        do { try save(doc); return nil } catch { return error.localizedDescription }
    }

    /// Cmd+S's save, waited on.
    static func save(_ doc: TextDocument) throws {
        var done = false, failure: Error?
        doc.save(to: try #require(doc.fileURL), ofType: try #require(doc.fileType), for: .saveOperation) { error in
            failure = error
            done = true
        }
        let until = Date().addingTimeInterval(5)
        while !done && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try #require(done, "the save never finished")
        if let failure { throw failure }
    }

    /// Another app's write, its date `after` seconds on so the change is seen whatever the clock's grain.
    static func changeOnDisk(_ url: URL, to text: String, after: TimeInterval) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(after)], ofItemAtPath: url.path)
    }

    static let sample = """
        # Launch checklist

        The **plan** for _Friday_, with `pilot status` and a [link](https://example.com).

        - [x] Ship the build
        - [ ] Write the notes
        - Tell the club

        > Done is better than perfect.

        ```
        swift build --product Pilot
        ```
        """

    /// The window in each style and theme, at 900 by 640.
    static func renders(_ files: URL, to dir: URL) throws {
        testApp()
        DisplayFaces.directory = LookThemeTests.fonts
        DisplayFaces.register()
        let md = files.appending(path: "Launch.md"), txt = files.appending(path: "todo.txt")
        try sample.write(to: md, atomically: true, encoding: .utf8)
        try "Groceries\r\n- oats\r\n- coffee\r\n\r\nCall the landlord about the boiler.\r\n".write(to: txt, atomically: true, encoding: .utf8)
        let markdown = try #require(TextWindows.load(md, alert: false)), plain = try #require(TextWindows.load(txt, alert: false))
        defer { markdown.close(); plain.close() }
        let look = Look.shared
        let saved = (look.themeID, look.style)
        defer { (look.themeID, look.style) = saved }
        let only = env["PILOT_RENDER_ONLY"]
        func wanted(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains { name.contains($0) } } ?? true }

        for theme in ["tokyo-night", "porcelain"] {
            look.themeID = theme
            for style in PilotStyle.allCases {
                look.style = style
                let states: [(name: String, doc: TextDocument, raw: Bool, changed: Bool)] = [
                    ("md", markdown, false, false), ("md-raw", markdown, true, false), ("txt", plain, false, false),
                    ("changed", markdown, false, true),
                ]
                for state in states where (theme == "tokyo-night" || state.name == "md") && wanted("\(style.rawValue)-\(theme)-\(state.name)") {
                    state.doc.model.raw = state.raw
                    state.doc.model.changedOnDisk = state.changed ? Date(timeIntervalSince1970: 1_793_000_000) : nil
                    if state.changed { state.doc.model.text = sample + "\n\nAn edit not saved yet." }
                    defer { if state.changed { state.doc.model.text = sample } }
                    let view = TextWindowView(model: state.doc.model).styled(.page(.notes)).frame(width: 900, height: 640).pilotTheme(look: look)
                    let rep = try rendered(view, wait: 0.8)
                    try #require(rep.representation(using: .png, properties: [:]))
                        .write(to: dir.appendingPathComponent("\(style.rawValue)-\(theme)-\(state.name).png"))
                    let words = try recognisedText(in: rep).map(\.text).joined(separator: " ")
                    // The head names the file and how it sits on disk; drawn Markdown hides its marks, raw shows them.
                    // (Vision reads the head's small caption face's "Launch" as "Laanch" now and then.)
                    #expect(words.contains(state.doc === plain ? "todo.txt" : "ch.md"), "\(state.name): \(words)")
                    #expect(words.contains(state.doc === plain ? "CRLF" : "LF"), "\(state.name): \(words)")
                    if state.name == "md" { #expect(words.contains("Launch checklist") && !words.contains("# Launch"), "\(words)") }
                    if state.name == "md-raw" { #expect(words.contains("# Launch checklist"), "\(words)") }
                    if state.name == "changed" { #expect(words.contains("Reload") && words.contains("Keep mine"), "\(words)") }
                }
            }
        }
    }
}
}
#endif
