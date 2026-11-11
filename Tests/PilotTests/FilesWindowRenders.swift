#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// Pilot Files (spec pilot-1.1 T10, T5's pick B) as its window draws it, in Tokyo Night: a fixture Downloads in the list
/// with a picture picked, and a fixture Pictures in the grid. Devices, favourites, Hidden apps and thumbnails are fixed,
/// so nothing of this Mac's is read. Opt-in, offscreen:
/// `CFFIXED_USER_HOME=/tmp/pilot-rh PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter FilesWindowRenders`
extension SharedLook {
@MainActor
@Suite("Pilot Files renders")
struct FilesWindowRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment

    @Test("Pilot Files draws pick B in list and grid", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        look.themeID = "tokyo-night"
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("pilot-files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let downloads = try Self.fixture(home + "/Downloads", [
            ("Cursors 1.1", nil, 2), ("pilot-1.0.3.dmg", 21_400_000, 5), ("Screenshot 2026-11-03 at 14.22.png", -1, 1),
            ("film-v4-final.mp4", 1_480_000, 20), ("invoice-oct-2026.pdf", 182_000, 30), ("omarchy-themes.zip", 960_000, 50),
            ("colors.toml", 1_200, 70), ("README.md", 4_800, 72), ("spanish-notes.txt", 3_000, 140)])
        let pictures = try Self.fixture(home + "/Pictures", [
            ("wallpaper-lagoon.png", -1, 90), ("dunes-dawn.png", -1, 100), ("fjord.png", -1, 110), ("night-city.png", -1, 120),
            ("forest-fog.png", -1, 130), ("salt-flats.png", -1, 140)])

        // Hidden apps never show: an app whose bundle id Hidden apps holds, in the listing and as a search hit.
        let hiddenApp = downloads.appending(path: "Hidden.app")
        try FileManager.default.createDirectory(at: hiddenApp.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": Self.hiddenID], format: .xml, options: 0)
            .write(to: hiddenApp.appending(path: "Contents/Info.plist"))
        try FileManager.default.createDirectory(atPath: home + "/code", withIntermediateDirectories: true)

        let list = Self.model(downloads, home: home)
        try await Self.settle(list)
        #expect(!list.items.contains { $0.name == "Hidden.app" })
        #expect(FilesModel.item(hiddenApp, hidden: [Self.hiddenID]) == nil)
        #expect(FilesModel.item(hiddenApp, hidden: []) != nil)
        #expect(list.favourites.map(\.title) == ["code"])

        // T51: real icons, a folder's custom one included, made off the main thread (NSWorkspace's, not a glyph).
        let dressed = downloads.appending(path: "Cursors 1.1")
        #expect(NSWorkspace.shared.setIcon(NSImage(cgImage: try #require(Self.picture(256)), size: NSSize(width: 128, height: 128)),
                                           forFile: dressed.path, options: []))
        let plain = try #require(await list.picture(downloads.appending(path: "README.md"), pixels: 36, icon: true))
        let custom = try #require(await list.picture(dressed, pixels: 36, icon: true))
        #expect(Self.pixels(plain) != Self.pixels(custom), "the folder's custom icon draws, not the generic one")
        // The sidebar's device and the toolbar's figure are one read: the shown folder's volume carries the listing's.
        #expect(list.devices.first?.free == list.free)
        // Cmd+Shift+.: hidden files list too, Hidden apps' apps never.
        try Data("x".utf8).write(to: downloads.appending(path: ".hidden-note"))
        list.reload()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!list.items.contains { $0.name == ".hidden-note" })
        list.showHidden = true
        for _ in 0..<40 where !list.items.contains(where: { $0.name == ".hidden-note" }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(list.items.contains { $0.name == ".hidden-note" })
        #expect(!list.items.contains { $0.name == "Hidden.app" })
        list.showHidden = false
        for _ in 0..<40 where list.items.contains(where: { $0.name == ".hidden-note" }) { try await Task.sleep(for: .milliseconds(50)) }

        // A file completed or edited after its first thumbnail refreshes both cached misses and pictures.
        let shot = downloads.appending(path: "Screenshot 2026-11-03 at 14.22.png")
        let original = try Data(contentsOf: shot), date = Date(timeIntervalSince1970: 1_800_000_000)
        let before = try #require(await list.picture(shot, pixels: 36, modified: date))
        try Data().write(to: shot)
        #expect(await list.picture(shot, pixels: 36, modified: date.addingTimeInterval(1)) == nil)
        try FileThumbnailRenders.png(shot)
        let after = try #require(await list.picture(shot, pixels: 36, modified: date.addingTimeInterval(2)))
        #expect(Self.pixels(before) != Self.pixels(after))
        try original.write(to: shot)
        list.reload()
        try await Task.sleep(for: .milliseconds(150))
        look.style = .instrument
        list.select(try #require(list.items.first { $0.name == "README.md" }))
        list.select(try #require(list.items.first { $0.name.hasPrefix("Screenshot") }), modifiers: .command)
        try await Self.render(list, "1-list", in: dir)

        let grid = Self.model(pictures, home: home)
        grid.mode = .grid
        try await Self.settle(grid)
        look.style = .toybox
        look.themeID = "porcelain"
        grid.select(try #require(grid.items.first))
        grid.select(grid.items[2], modifiers: .shift)
        try await Self.render(grid, "2-grid", in: dir)

        // C keeps the current folder visible at the window's minimum width, even with many ancestors.
        let deep = try Self.fixture(home + "/Projects/Website/Assets/Images/Exports/November", [("picture.png", -1, 1)])
        let narrow = Self.model(deep, home: home)
        try await Self.settle(narrow)
        look.style = .instrument
        try await Self.render(narrow, "3-narrow-path", in: dir, size: NSSize(width: 820, height: 440))
    }

    /// T55: New file from the built-in and Sven's templates, Copy path's three forms, the typed path bar and its
    /// completion, folder sizes (protected ones never read), and Cmd+X then Cmd+V as a move; every write through FileOps
    /// with a throwaway Trash in the fixture home and a clipboard of the test's own, each undone again.
    @Test("Pilot Files: new file, paths, folder sizes, cut", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func powerFeatures() async throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        look.themeID = "tokyo-night"
        let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"])).appendingPathComponent("pilot-files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = FileManager.default

        let projects = try Self.fixture(home + "/Projects", [("alpha", nil, 3), ("beta", nil, 8), ("notes.txt", 300, 1), ("it's here", nil, 2)])
        let alpha = projects.appending(path: "alpha"), beta = projects.appending(path: "beta")
        try Data(count: 1_000).write(to: alpha.appending(path: "a.bin"))
        try files.createDirectory(at: alpha.appending(path: "deep"), withIntermediateDirectories: true)
        try Data(count: 2_500).write(to: alpha.appending(path: "deep/b.bin"))
        try Data(count: 10_000).write(to: beta.appending(path: "c.bin"))

        // Protected folders are never read from outside them: Desktop itself, and Home, which holds it.
        try files.createDirectory(atPath: home + "/Desktop/inner", withIntermediateDirectories: true)
        let roots = FolderListing.protectedRoots(home: home, fullDiskAccess: false), apps = FolderListing.appData(home: home)
        func fence(_ inside: String) throws -> FolderListing.Fence {
            try #require(FolderListing.Fence(inside: inside, protected: roots, appData: apps))
        }
        #expect(FolderListing.folderSize(URL(filePath: home + "/Desktop"), fence: try fence(home)) == nil)
        #expect(FolderListing.folderSize(URL(filePath: home), fence: try fence("/Users")) == nil)
        #expect(FolderListing.folderSize(URL(filePath: home + "/Desktop/inner"), fence: try fence(home + "/Desktop")) == 0)
        #expect(FolderListing.folderSize(alpha, fence: try fence(projects.path)) == 3_500)
        #expect(FolderListing.folderSize(alpha, fence: try fence(projects.path), cap: 2) == nil, "past the cap it shows —")
        // By identity, not spelling: Desktop reached through a link to the home folder is still Desktop.
        let alias = URL(filePath: home + "/alias")
        if !files.fileExists(atPath: alias.path) { try files.createSymbolicLink(atPath: alias.path, withDestinationPath: home) }
        #expect(FolderListing.folderSize(alias.appending(path: "Desktop"), fence: try fence(home)) == nil)
        // Another app's data: its folder in Containers is read only from inside it.
        let app = URL(filePath: home + "/Library/Containers/com.example.app", directoryHint: .isDirectory)
        try files.createDirectory(at: app.appending(path: "Data"), withIntermediateDirectories: true)
        try Data(count: 700).write(to: app.appending(path: "Data/x.bin"))
        #expect(FolderListing.folderSize(app, fence: try fence(home + "/Library/Containers")) == nil)
        #expect(FolderListing.folderSize(app.appending(path: "Data"), fence: try fence(app.path)) == 700)
        // Another volume is never walked: /dev is devfs, refused on its lstat alone.
        #expect(FolderListing.folderSize(URL(filePath: "/dev"), fence: try fence(home)) == nil)

        // A throwaway Trash in the fixture home and a clipboard of the test's own: nothing of Sven's is touched.
        let bin = URL(filePath: home + "/.t55-trash", directoryHint: .isDirectory)
        let ops = FileOps(trash: { url in
            let into = bin.appending(path: String(UUID().uuidString.prefix(8)), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            let went = into.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: went)
            return went
        }, trashFolder: { _ in bin.appending(path: "XXXXXXXX", directoryHint: .isDirectory) })
        let cut = FilesCut.shared
        let board = NSPasteboard(name: .init("dev.banozz.pilot.test.T55.\(UUID().uuidString)"))
        cut.board = board
        defer { cut.clear(); cut.board = .general; board.releaseGlobally() }

        let model = Self.model(projects, home: home)
        model.ops = ops
        let templates = model.templateFolder
        try #require(templates.path.hasPrefix(home + "/"), "the templates folder is outside the fixture home")
        try await Self.settle(model)
        try await Self.until { !model.sizingFolders && model.folderSizes.count == 3 }
        #expect(model.folderSizes[alpha.path]?.bytes == 3_500)
        #expect(model.folderSizes[beta.path]?.bytes == 10_000)
        #expect(model.sizeLabel(model.items.first { $0.name == "beta" }!) == FolderListing.size(10_000))
        model.sort = .size
        #expect(model.items.map(\.name) == ["beta", "alpha", "notes.txt", "it's here"])

        // New file: empty Text twice (the second numbered), then Sven's template, each name open for editing.
        let snapshot = try Self.tree(projects)
        // Existing fixture E2E now carries a group through the same public model actions the window uses.
        let rows = model.shown
        let folders = Array(rows.filter(\.isFolder).prefix(2))
        var opened: [URL] = []
        model.newWindow = { opened.append($0) }
        model.open(folders)
        try #require(opened == folders.map(\.url), "a grouped Open creates a window for every folder")
        #expect(model.folder == projects)
        model.select(rows[0])
        model.select(rows[2], modifiers: .shift)
        #expect(model.selectedIDs == Set(rows.prefix(3).map(\.id)))
        model.select(rows[1], modifiers: .command)
        #expect(model.selectedIDs == [rows[0].id, rows[2].id])
        model.select(rows[0], modifiers: .command)
        model.select(rows[2], modifiers: .command)
        #expect(model.selectedIDs.isEmpty && model.selection == nil)
        model.selectAll()
        #expect(model.selections.count == rows.count)
        model.select(rows[2])
        model.select(rows[3], modifiers: .command)
        let group = model.selections.map(\.url)
        model.copy()
        #expect(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] == group)
        model.cut()
        #expect(cut.urls == group)
        let payload = model.drag(model.selections.map(\.id))
        #expect(!model.canSpring(into: group[0]))
        model.open([try #require(rows.first { $0.id == alpha.path })])
        try await Self.until { model.loaded && model.folder.path == alpha.path }
        #expect(opened == folders.map(\.url), "a single folder still opens in this window")
        #expect(model.selectedIDs.isEmpty && payload == group)
        #expect(model.drop(payload, on: alpha))
        try await Self.idle(model)
        #expect(group.allSatisfy { files.fileExists(atPath: alpha.appending(path: $0.lastPathComponent).path) })
        model.endDrag()
        model.undo()
        try await Self.idle(model)
        #expect(try Self.tree(projects) == snapshot)
        model.go(projects)
        try await Self.until { model.loaded && model.items.count == rows.count }
        model.select(try #require(model.items.first { $0.url == group[0] }))
        model.select(try #require(model.items.first { $0.url == group[1] }), modifiers: .command)
        model.trash()
        try await Self.idle(model)
        #expect(group.allSatisfy { !files.fileExists(atPath: $0.path) })
        model.undo()
        try await Self.idle(model)
        #expect(try Self.tree(projects) == snapshot)
        model.newFile(FileTemplate.builtIn[0])
        try await Self.idle(model)
        #expect(files.fileExists(atPath: projects.appending(path: "untitled.txt").path))
        #expect(model.renaming == projects.appending(path: "untitled.txt").path)
        model.renaming = nil
        model.newFile(FileTemplate.builtIn[0])
        try await Self.idle(model)
        #expect(files.fileExists(atPath: projects.appending(path: "untitled 2.txt").path))
        try files.createDirectory(at: templates, withIntermediateDirectories: true)
        try Data("# Invoice\n".utf8).write(to: templates.appending(path: "Invoice.md"))
        // A downloaded template: its quarantine flag goes with each copy.
        let quarantine = "0081;00000000;T55 test;"
        #expect(setxattr(templates.appending(path: "Invoice.md").path, "com.apple.quarantine", quarantine, quarantine.utf8.count, 0, 0) == 0)
        model.readSidebar()
        try await Self.until { model.templates.contains { $0.name == "Invoice.md" } }
        model.newFile(try #require(model.templates.first { $0.name == "Invoice.md" }))
        try await Self.idle(model)
        #expect(try String(contentsOf: projects.appending(path: "Invoice.md"), encoding: .utf8) == "# Invoice\n")
        #expect(try files.attributesOfItem(atPath: projects.appending(path: "Invoice.md").path)[.type] as? FileAttributeType == .typeRegular)
        var flag = [UInt8](repeating: 0, count: 64)
        let flagged = getxattr(projects.appending(path: "Invoice.md").path, "com.apple.quarantine", &flag, flag.count, 0, 0)
        #expect(flagged > 0 && String(decoding: flag.prefix(max(0, flagged)), as: UTF8.self) == quarantine)
        // Only plain files are templates: a link (it would make a link to its target) and a folder are left out and refused.
        let link = templates.appending(path: "Link.md")
        if (try? files.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try files.createSymbolicLink(atPath: link.path, withDestinationPath: projects.appending(path: "notes.txt").path)
        }
        try files.createDirectory(at: templates.appending(path: "Folder"), withIntermediateDirectories: true)
        model.readSidebar()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.templates.map(\.name) == ["untitled.txt", "untitled.md", "Invoice.md"])
        await #expect(throws: FileOps.Failure.self) { try await ops.plan(.newFile(in: projects, named: "x.md", template: link)) }
        await #expect(throws: FileOps.Failure.self) { try await ops.plan(.newFile(in: projects, named: "x", template: templates.appending(path: "Folder"))) }
        #expect(model.notice?.problem == false, "\(model.notice?.text ?? "")")
        for _ in 0..<3 { model.undo(); try await Self.idle(model) }
        #expect(try Self.tree(projects) == snapshot, "Cmd+Z three times sends the three new files to the Trash")

        // Copy path's three forms, a name with a space and a quote.
        let quoted = projects.appending(path: "it's here")
        model.copyPath(quoted, as: .plain)
        #expect(board.string(forType: .string) == quoted.path)
        model.copyPath(quoted, as: .shell)
        #expect(board.string(forType: .string) == "'\(quoted.path.replacingOccurrences(of: "'", with: "'\\''"))'")
        model.copyPath(quoted, as: .home)
        #expect(board.string(forType: .string) == "~/Projects/it's here")
        #expect(FolderListing.resolve("'\(quoted.path.replacingOccurrences(of: "'", with: "'\\''"))'", from: alpha).path == quoted.path)
        #expect(FolderListing.resolve(home + "/Projects/it\\'s\\ here", from: alpha).path == quoted.path)

        // Cut: Cmd+X marks, Cmd+V in another folder moves (Cmd+Z puts it back); a clipboard changed since drops the mark.
        model.selected = projects.appending(path: "notes.txt").path
        model.cut()
        #expect(cut.paths == [projects.appending(path: "notes.txt").path])
        try await Self.render(model, "3-sizes-cut", in: dir)
        model.go(beta)
        try await Self.until { model.loaded && model.folder.path == beta.path }
        model.paste(moving: false)
        try await Self.idle(model)
        #expect(files.fileExists(atPath: beta.appending(path: "notes.txt").path))
        #expect(!files.fileExists(atPath: projects.appending(path: "notes.txt").path))
        #expect(cut.urls.isEmpty, "the mark goes once its items moved")
        model.undo()
        try await Self.idle(model)
        #expect(try Self.tree(projects) == snapshot, "Cmd+Z puts the cut file back")
        model.cut(model.items.first)
        board.clearContents()
        board.setString("something else", forType: .string)
        model.paste(moving: false)
        #expect(cut.urls.isEmpty)
        #expect(model.notice?.problem == true, "a stale mark pastes as a copy would: here nothing, the clipboard holds no file")
        model.dismissNotice()
        #expect(try Self.tree(projects) == snapshot)

        // A cut file renamed and another put at its name: Cmd+V refuses and moves nothing, and no later paste copies the
        // stranger; a move whose plan names other items than the cut's runs neither.
        let notes = projects.appending(path: "notes.txt"), old = projects.appending(path: "notes-old.txt")
        model.go(projects)
        try await Self.until { model.loaded && model.folder.path == projects.path && model.items.contains { $0.name == "notes.txt" } }
        model.cut(model.items.first { $0.name == "notes.txt" })
        try files.moveItem(at: notes, to: old)
        try Data("stranger".utf8).write(to: notes)
        model.go(beta)
        try await Self.until { model.loaded && model.folder.path == beta.path }
        model.paste(moving: false)
        try await Self.idle(model)
        #expect(model.notice?.text == "notes.txt changed since Cmd+X (renamed or replaced); nothing was moved. Cut it again.")
        #expect(cut.urls.isEmpty && !files.fileExists(atPath: beta.appending(path: "notes.txt").path))
        model.dismissNotice()
        model.paste(moving: false)
        try await Self.idle(model)
        #expect(!files.fileExists(atPath: beta.appending(path: "notes.txt").path), "the clipboard no longer names it")
        model.dismissNotice()
        model.run(.move([notes], into: beta, .ask), expect: [try #require(FileOps.identity(of: old))])
        try await Self.idle(model)
        #expect(model.notice?.text.hasPrefix("notes.txt changed since Cmd+X") == true)
        #expect(!files.fileExists(atPath: beta.appending(path: "notes.txt").path))
        model.dismissNotice()
        // The fixture as it was (the stranger is the test's own file in the fixture home).
        try files.removeItem(at: notes)
        try files.moveItem(at: old, to: notes)
        #expect(try Self.tree(projects) == snapshot)

        // A cut onto a name already there: Replace moves the very item cut, the one there going to the Trash; Cmd+Z puts
        // both back.
        let there = beta.appending(path: "notes.txt")
        try Data("already here".utf8).write(to: there)
        let betaBefore = try Self.tree(beta)
        model.go(projects)
        try await Self.until { model.loaded && model.folder.path == projects.path && model.items.contains { $0.name == "notes.txt" } }
        model.cut(model.items.first { $0.name == "notes.txt" })
        model.go(beta)
        try await Self.until { model.loaded && model.folder.path == beta.path }
        model.paste(moving: false)
        try await Self.idle(model)
        #expect(model.notice?.clash != nil, "\(model.notice?.text ?? "")")
        model.answer(.replace)
        try await Self.idle(model)
        #expect(model.notice?.problem == false, "\(model.notice?.text ?? "")")
        #expect(try Data(contentsOf: there).count == 300 && !files.fileExists(atPath: notes.path))
        model.undo()
        try await Self.idle(model)
        #expect(try Self.tree(beta) == betaBefore, "the replaced one is back from the Trash")

        // A refusal already showing when the cut's Cmd+V meets the clash: the question joins it and keeps the cut's
        // identities, so a file put at the cut one's name before Replace is answered is refused, and nothing moves.
        model.go(projects)
        try await Self.until { model.loaded && model.folder.path == projects.path && model.items.contains { $0.name == "notes.txt" } }
        model.cut(model.items.first { $0.name == "notes.txt" })
        model.go(beta)
        try await Self.until { model.loaded && model.folder.path == beta.path }
        model.goTo("~/nowhere")
        model.editingPath = false
        #expect(model.notice?.problem == true)
        model.paste(moving: false)
        try await Self.idle(model)
        #expect(model.notice?.clash != nil && model.notice?.text.hasPrefix("Nothing at") == true, "\(model.notice?.text ?? "")")
        try files.moveItem(at: notes, to: old)
        try Data("stranger".utf8).write(to: notes)
        model.answer(.replace)
        try await Self.idle(model)
        #expect(model.notice?.text == "notes.txt changed since Cmd+X (renamed or replaced); nothing was moved. Cut it again.")
        #expect(try Data(contentsOf: there) == Data("already here".utf8) && files.fileExists(atPath: notes.path), "nothing moved")
        model.dismissNotice()
        try files.removeItem(at: notes)
        try files.moveItem(at: old, to: notes)
        try files.removeItem(at: there)
        #expect(try Self.tree(projects) == snapshot, "the cut one is back where it was")

        // The path bar: completion from ~ and from the shown folder, Return goes, a file's folder opens with it picked.
        #expect(FolderListing.completions("~/Pro", from: beta, home: home) == ["~/Projects/"])
        #expect(FolderListing.completions("../a", from: beta, home: home) == ["../alpha/"])
        #expect(FolderListing.completions("~/Projects/", from: beta, home: home) == ["~/Projects/alpha/", "~/Projects/beta/", "~/Projects/it's here/"])
        model.editingPath = true
        model.goTo("~/Projects/alpha")
        #expect(model.folder.path == alpha.path && !model.editingPath)
        model.goTo("../notes.txt")
        #expect(model.folder.path == projects.path && model.selected == projects.appending(path: "notes.txt").path)
        model.editingPath = true
        model.goTo("~/nowhere")
        #expect(model.editingPath && model.notice?.problem == true)
        model.dismissNotice()
        try await Self.until { model.loaded && !model.sizingFolders }
        try await Self.render(model, "4-path-bar", in: dir)
    }

    /// The tree under `folder`: each item's path from it and its size, so a write undone leaves it as it was.
    static func tree(_ folder: URL) throws -> [String] {
        let walk = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]))
        return walk.compactMap { ($0 as? URL).map { url in "\(url.path.dropFirst(folder.path.count)) \((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)" } }.sorted()
    }

    /// Waits for `done`, at most 3 seconds.
    static func until(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<60 where !done() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(done())
    }

    /// Waits for every file action to end.
    static func idle(_ model: FilesModel) async throws {
        try await Task.sleep(for: .milliseconds(50))
        try await until { model.working == 0 }
    }

    static let hiddenID = "dev.banozz.test.hidden"

    /// A model on `folder` whose sidebar, Hidden apps, search and thumbnails are fixed.
    static func model(_ folder: URL, home: String) -> FilesModel {
        let tb: Int64 = 1_000_000_000_000
        let devices = [FilesModel.Device(name: "Macintosh HD", symbol: "internaldrive", url: URL(filePath: "/"), free: 1_400 * tb / 1000, total: 2 * tb),
                       FilesModel.Device(name: "T7 Shield", symbol: "externaldrive", url: URL(filePath: "/Volumes/T7 Shield"), free: 612 * tb / 1000, total: 2 * tb),
                       FilesModel.Device(name: "nas.local", symbol: "server.rack", url: URL(filePath: "/Volumes/nas"), free: 3_100 * tb / 1000, total: 4 * tb)]
        let sources = FilesModel.Sources(
            hidden: { [hiddenID] }, favourites: { ["file:" + home + "/code", "action:apps.terminal"] }, devices: { devices }, search: { _, reply in reply([]) },
            make: FileThumbnailRenders.fake)
        let model = FilesModel(folder: folder, home: home, sources: sources)
        model.start()
        return model
    }

    /// A folder of fixture items: a nil size makes a folder, -1 a picture, else a file that many bytes long; each
    /// modified that many hours ago.
    static func fixture(_ path: String, _ items: [(String, Int?, Double)]) throws -> URL {
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = try #require(picture(64))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        for (name, size, ago) in items {
            let url = folder.appending(path: name)
            switch size {
            case nil: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            case let bytes? where bytes < 0: try png.write(to: url)
            case let bytes?: try Data(count: bytes).write(to: url)
            }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago * 3600)], ofItemAtPath: url.path)
        }
        return folder
    }

    /// A lagoon at dusk: the thumbnail every picture gets, `side` pixels wide.
    nonisolated static func picture(_ side: Int) -> CGImage? {
        let (w, h) = (side, side * 2 / 3)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [CGColor(red: 0.05, green: 0.25, blue: 0.4, alpha: 1), CGColor(red: 0.1, green: 0.45, blue: 0.6, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        ctx.setFillColor(CGColor(red: 0.2, green: 0.75, blue: 0.9, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: Double(w) * 0.62, y: Double(h) * 0.55, width: Double(w) * 0.16, height: Double(w) * 0.16))
        ctx.setFillColor(CGColor(red: 0.04, green: 0.2, blue: 0.33, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 2 / 5))
        return ctx.makeImage()
    }

    /// An image's pixels, to tell two icons apart.
    static func pixels(_ image: NSImage) -> Data? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data as Data?
    }

    /// Waits for the folder's first read and the sidebar's.
    static func settle(_ model: FilesModel) async throws {
        for _ in 0..<60 where !(model.loaded && !model.devices.isEmpty) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.loaded)
        #expect(model.problem == nil)
        #expect(!model.items.isEmpty)
    }

    /// The window's content at its own size, in a borderless window parked off screen, at Retina scale.
    static func render(_ model: FilesModel, _ name: String, in dir: URL, size: NSSize = FilesWindows.size) async throws {
        let host = NSHostingView(rootView: FilesView(model: model).styled(.window).pilotTheme())
        host.frame.size = size
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close(); model.close() }
        // The inspector's read and the thumbnails come in after the first pass.
        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(snapshot(host, scale: 2))
        try #require(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
    }
}
}
#endif
