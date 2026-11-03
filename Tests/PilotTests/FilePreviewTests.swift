import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Files view's preview pane (spec file-search-v2 T2): what it reads of a file, and the pane drawn beside the list.
@Suite("File preview")
struct FilePreviewTests {
    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pilot-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "Shots"), withIntermediateDirectories: true)
        return dir
    }

    @Test("A text file shows its first lines, tabs as spaces; an unknown extension is read to see")
    func text() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appending(path: "notes.md")
        try (["# Plan", "\tship it"] + (1...30).map { "line \($0)" }).joined(separator: "\n").write(to: notes, atomically: true, encoding: .utf8)
        let preview = try #require(FilePreview.read(notes.path))
        guard case .lines(let lines) = preview.look else { Issue.record("not lines: \(preview.look)"); return }
        #expect(lines.count == FilePreview.lineLimit)
        #expect(lines[0] == "# Plan" && lines[1] == "    ship it")
        #expect(preview.facts.map(\.label) == ["Kind", "Size", "Edited"])
        let rust = dir.appending(path: "main.rs")
        try "fn main() {}".write(to: rust, atomically: true, encoding: .utf8)
        #expect(FilePreview.read(rust.path)?.look == .lines(["fn main() {}"]))
    }

    @Test("A folder counts its visible items; binary shows its icon; a gone file shows nothing")
    func folderBinaryGone() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1, 0, 2, 0]).write(to: dir.appending(path: "blob.bin"))
        try Data().write(to: dir.appending(path: ".hidden"))
        let folder = try #require(FilePreview.read(dir.path))
        #expect(folder.look == .folder(2), "Shots and blob.bin, not the dot file")
        #expect(!folder.facts.map(\.label).contains("Size"), "a folder has no size line")
        #expect(FilePreview.read(dir.appending(path: "blob.bin").path)?.look == .icon)
        #expect(FilePreview.read(dir.appending(path: "gone.txt").path) == nil)
    }

    @Test("An image is a picture with its pixel size")
    @MainActor func image() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appending(path: "shot.png")
        try SharedLook.FileThumbnailRenders.png(shot, width: 64, height: 32)
        let preview = try #require(FilePreview.read(shot.path))
        #expect(preview.look == .picture)
        #expect(preview.facts.contains(.init(label: "Dimensions", value: "64 × 32")))
    }

    @Test("A gallery card: images, Markdown, folders and the rest; a Markdown card's title and first lines; the filter")
    func galleryCards() {
        func item(_ name: String, folder: Bool = false) -> FolderItem {
            FolderItem(url: URL(filePath: "/g/\(name)"), name: name, isFolder: folder, size: nil, modified: nil, kind: "", type: nil)
        }
        let items = [item("Dunes.HEIC"), item("plan.md"), item("Shots", folder: true), item("a.zip"), item("b.webp")]
        #expect(items.map(Gallery.kind) == [.image, .markdown, .folder, .other, .image])
        #expect(Gallery.filter(items, " dun ").map(\.name) == ["Dunes.HEIC"])
        #expect(Gallery.filter(items, "").count == 5)
        let card = Gallery.markdownCard("---\ntitle: x\n---\n\n# **Launch** plan\n\n- Ship `Pilot`\n1. Typo search\n> quoted\n---\n```\n", name: "plan")
        #expect(card == Gallery.MarkdownCard(title: "Launch plan", lines: ["Ship Pilot", "Typo search", "quoted"]))
        #expect(Gallery.markdownCard("just text", name: "notes").title == "notes", "no heading: the file name")
        #expect(Gallery.pixels(120) == 320 && Gallery.pixels(200) == 480 && Gallery.pixels(512) == 800)
        // The wallpaper folders: an image picked on its own brings its folder, each once.
        let folders = WallpaperSettings.containingFolders([URL(filePath: "/w/a"), URL(filePath: "/w/a/x.png"), URL(filePath: "/w/b/y.jpg"), URL(filePath: "/w/b")])
        #expect(folders.map(\.path) == ["/w/a", "/w/b"])
    }

    @Test("Edited reads today, yesterday or the date")
    func edited() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        #expect(FilePreview.edited(now.addingTimeInterval(-60), now: now).hasPrefix("today "))
        #expect(FilePreview.edited(now.addingTimeInterval(-86_400), now: now).hasPrefix("yesterday "))
        #expect(!FilePreview.edited(now.addingTimeInterval(-10 * 86_400), now: now).contains("day"))
    }
}

/// The pane drawn in Classic's Files view, one render each for a png, a text file and a folder (PILOT_RENDER_DIR keeps
/// them). A fake QuickLook reads the png with ImageIO.
extension SharedLook {
@MainActor
@Suite("File preview renders")
struct FilePreviewRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("The pane previews the selected file beside the list", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        look.style = .instrument
        look.themeID = "lagoon"
        let dir = try FilePreviewTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appending(path: "pilot shot.png")
        try SharedLook.FileThumbnailRenders.png(shot, width: 320, height: 200)
        let notes = dir.appending(path: "pilot launch.md")
        try "# Launch\n\n- Ship Pilot to the Shippers Club\n- Typo search: 7 ms\n- Preview pane beside the list\n".write(to: notes, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appending(path: "pilot shots"), withIntermediateDirectories: true)
        try SharedLook.FileThumbnailRenders.png(dir.appending(path: "pilot shots/1.png"))
        let rows = [shot, notes, dir.appending(path: "pilot shots")].map {
            MenuEntry(title: $0.lastPathComponent, target: .file($0.path), detail: "today", subtitle: "~/Desktop")
        }
        var nav = MenuNavigator(entries: [])
        nav.query = "pilot"
        while nav.only != .file { _ = nav.handle(.tab) }
        nav.provide(.file, rows)
        let model = MenuModel(nav: nav)
        let thumbnails = FileThumbnails.shared
        thumbnails.make = FileThumbnailRenders.fake
        defer { thumbnails.make = FileThumbnails.quickLook }
        var green = 0
        // The folder sorts first as the best match, then the png and the notes.
        for (index, name) in ["folder", "image", "text"].enumerated() {
            if index > 0 { _ = model.nav.handle(.down) }
            let panel = HUD.makePanel(MenuView(model: model), surface: .menu)
            defer { panel.close() }
            let content = try #require(panel.contentView)
            // The pane reads the file and makes its picture in tasks: time for them, then a layout pass.
            try await Task.sleep(for: .milliseconds(1500))
            content.layoutSubtreeIfNeeded()
            let rep = try #require(snapshot(content, scale: 2))
            // The pane is the right third; the list's own thumbnail is left of it.
            if index == 1 { green = FileThumbnailRenders.green(rep, from: rep.pixelsWide * 2 / 3) }
            if let out = Self.env["PILOT_RENDER_DIR"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: out).appending(path: "file-preview-\(name).png"))
            }
        }
        #expect(green > 1000, "the png's picture fills the pane")
    }

    /// The gallery window's face (P90) on a folder of two pngs, a Markdown file and a subfolder: the pngs as their
    /// pictures (the fake QuickLook's green), the Markdown as its title and lines. PILOT_RENDER_DIR keeps gallery.png.
    @Test("The gallery draws a folder as cards", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func gallery() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let dir = try FilePreviewTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try SharedLook.FileThumbnailRenders.png(dir.appending(path: "dunes.png"), width: 320, height: 200)
        try SharedLook.FileThumbnailRenders.png(dir.appending(path: "lagoon.png"), width: 200, height: 320)
        try "# Launch\n\n- Ship Pilot to the Shippers Club\n- Typo search: 7 ms\n".write(to: dir.appending(path: "launch.md"), atomically: true, encoding: .utf8)
        try "zip".write(to: dir.appending(path: "notes.zip"), atomically: true, encoding: .utf8)
        let model = GalleryModel(folder: dir)
        model.make = FileThumbnailRenders.fake
        model.show(dir, wallpaper: true, display: nil, sources: [dir])
        defer { model.close() }
        let host = NSHostingView(rootView: GalleryView(model: model).styled(.window).pilotTheme().background(Theme.background))
        host.frame = CGRect(origin: .zero, size: GalleryWindow.size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        defer { w.close() }
        w.contentView = host
        let deadline = Date().addingTimeInterval(4)
        while model.items.count < 5, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.items.map(\.name) == ["Shots", "dunes.png", "lagoon.png", "launch.md", "notes.zip"], "folders first, then by name")
        try await Task.sleep(for: .milliseconds(1500))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(host, scale: 2))
        if let out = Self.env["PILOT_RENDER_DIR"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: out).appending(path: "gallery.png"))
        }
        #expect(FileThumbnailRenders.green(rep) > 4000, "both pngs draw as their pictures")
        model.query = "lag"
        #expect(model.shown.map(\.name) == ["lagoon.png"])
    }
}
}
