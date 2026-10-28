import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// N5: Defaults › File search keeps Show hidden and the never-index list; a changed list restarts the index, and the
/// Files view opens with Show hidden as set. The chips and the block drawn offscreen and read back; PILOT_RENDER_DIR
/// keeps the PNGs.
@MainActor
@Suite("File search settings")
struct FileSearchSettingsTests {
    static func defaults() -> UserDefaults { UserDefaults(suiteName: testSuite())! }

    @Test("The list starts as shipped; add, remove and reset are kept and each restarts the index; a refused entry says why")
    func list() {
        let store = Self.defaults()
        let settings = FileSearchSettings(defaults: store, home: "/Users/ada")
        var restarts = 0
        settings.onExcludedChange = { restarts += 1 }
        #expect(settings.excluded == FileExclusions.defaults && !settings.showHidden)
        #expect(settings.add("/Users/ada/Movies") == nil)
        #expect(settings.add("~/Movies")?.contains("already") == true)
        #expect(settings.add("*.log") != nil)
        settings.remove("node_modules")
        settings.showHidden = true
        #expect(restarts == 2)
        let again = FileSearchSettings(defaults: store, home: "/Users/ada")
        #expect(again.excluded.contains("~/Movies") && !again.excluded.contains("node_modules") && again.showHidden)
        settings.reset()
        #expect(settings.excluded == FileExclusions.defaults && restarts == 3)
        settings.reset()
        #expect(restarts == 3)
    }

    /// Text in images on a test store, so neither Sven's reader nor his index is touched.
    static func imageText(_ store: UserDefaults = defaults(), changes: (() -> Void)? = nil) -> ImageTextSettings {
        let text = ImageTextSettings(defaults: store, home: "/Users/ada", excluded: { FileExclusions.defaults })
        text.onChange = changes ?? {}
        return text
    }

    @Test("pilot get and set read and flip Text in images; off is kept and tells the reader, which clears the index")
    func imageTextSwitch() async throws {
        let store = Self.defaults()
        var changes = 0
        let text = Self.imageText(store) { changes += 1 }
        let schema = SettingsSchema()
        schema.registerImageText(text)
        let verbs = ControlVerbs()
        verbs.registerSettings(schema)
        func ask(_ verb: String, _ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil) }
        #expect(await ask("get", "files.imageText").result == .bool(true))
        let off = await ask("set", "files.imageText", "off")
        #expect(off.ok, "\(off.error?.message ?? "")")
        #expect(!text.enabled && changes == 1)
        #expect(await ask("get", "files.imageText").result == .bool(false))
        #expect(!Self.imageText(store).enabled)
        _ = await ask("set", "files.imageText", "on")
        #expect(text.enabled && changes == 2)
        #expect(await ask("set", "files.imageText", "maybe").error?.code == .badValue)
    }

    @Test("pilot list, add and remove image-text-folders change the folders read; --reset puts back the four; pilot files counts them")
    func imageTextFolders() async throws {
        let store = Self.defaults()
        var changes = 0
        let files = ControlFiles()
        files.home = "/Users/ada"
        files.imageText = Self.imageText(store) { changes += 1 }
        files.imageTextCounts = { (412, 3) }
        files.fullDiskAccess = { false }
        files.running = { false }
        let verbs = ControlVerbs()
        verbs.registerFiles(files, convert: ControlConvert())
        func ask(_ verb: String, _ args: String...) async -> ControlAnswer { await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil) }
        func listed() async -> [String] {
            guard case .array(let rows) = await ask("list", "image-text-folders").result else { return [] }
            return rows.compactMap { if case .object(let row) = $0, case .string(let folder) = row["folder"] { folder } else { nil } }
        }
        #expect(await listed() == ImageTextSettings.standardFolders)
        let added = await ask("add", "image-text-folders", "--folder", "/Users/ada/Movies")
        #expect(added.ok, "\(added.error?.message ?? "")")
        #expect(await listed().last == "~/Movies" && ImageTextSettings(defaults: store, home: "/Users/ada").folders.last == "~/Movies")
        #expect(await ask("add", "image-text-folders", "--folder", "~/Library/Caches").error?.message.hasPrefix("--folder:") == true)
        #expect(await ask("add", "image-text-folders", "--folder", "/etc").error?.message.hasPrefix("--folder:") == true)
        #expect(await ask("remove", "image-text-folders", "/Users/ada/Desktop").ok)
        #expect(await ask("remove", "image-text-folders", "~/Nowhere").error?.message.contains("~/Downloads") == true)
        #expect(await listed() == ["~/Downloads", "~/Documents", "~/Pictures", "~/Movies"])
        #expect(await ask("remove", "image-text-folders", "--reset").ok)
        #expect(await listed() == ImageTextSettings.standardFolders && changes == 3)
        guard case .object(let state) = await ask("files").result, case .object(let counts) = state["imageText"] else {
            Issue.record("pilot files gave no imageText")
            return
        }
        #expect(counts == ["on": .bool(true), "read": .number(412), "waiting": .number(3)])
    }

    @Test("The count line says what was read and what waits")
    func countLine() {
        #expect(ImageTextCount.text((0, 0)) == "0 images read")
        #expect(ImageTextCount.text((1, 0)) == "1 image read")
        #expect(ImageTextCount.text((412, 3)) == "412 images read, 3 waiting")
    }

    @Test("The helper starts with the never-index list as --ignore lines")
    func passesTheList() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "FileSearchSettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let helper = folder.appending(path: "pilot-files"), args = folder.appending(path: "args")
        try "#!/bin/sh\nprintf '%s|' \"$@\" > '\(args.path)'\ncat > /dev/null\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let index = FileIndex(helper: helper, fullDiskAccess: { true }, ignore: { ["/Library/*", "node_modules/"] })
        index.start()
        defer { index.restart() }
        let wait = Date().addingTimeInterval(5)
        while (try? String(contentsOf: args, encoding: .utf8)) == nil, Date() < wait { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        #expect(try String(contentsOf: args, encoding: .utf8) == "--ignore|/Library/*\nnode_modules/|")
    }

    @Test("The Files view shows Kind, Where, When and Hidden files as chips with the filters in force; the block lists the folders")
    func renders() throws {
        let look = try LookPageTests().look().0
        var nav = MenuNavigator(entries: [])
        nav.query = "budget kind:pdf"
        nav.show(.file)
        nav.fileFilters.place = .downloads
        nav.provide(.file, MenuEntries.files([(NSHomeDirectory() + "/Downloads/budget.pdf", nil)], home: NSHomeDirectory()))
        let model = MenuModel(nav: nav)
        let settings = FileSearchSettings(defaults: Self.defaults(), home: "/Users/ada")
        settings.onExcludedChange = {}
        let view = VStack(spacing: 20) {
            MenuView(model: model).frame(width: 760, height: 360)
            FileSearchBlock(settings: settings, text: Self.imageText(), counts: { (412, 3) }, clear: {}).frame(width: 760)
        }
        var text = ""
        try LookPageTests().hosted(view.frame(width: 1000, height: 1500).background(Theme.background).pilotTheme(look: look), height: 1500) { host in
            let rep = try #require(snapshot(host, scale: 2))
            if let dir = ProcessInfo.processInfo.environment["PILOT_RENDER_DIR"] {
                try rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: dir).appending(path: "file-filters.png"))
            }
            text = try recognisedText(in: rep).map(\.text).joined(separator: "\n")
        }
        for line in ["PDF", "Downloads", "Any time", "Hidden files", "budget.pdf", "File search", "Show hidden and system files",
                     "node_modules", "~/Library", "Never search in",
                     // Vision reads the folders' "~/" as "¿", "-/" or "~/" on a loaded Mac: the folder name is what is drawn.
                     "Text in images", "Find images by the words in them", "Read in", "Pictures", "Downloads", "Add",
                     "412 images read, 3 waiting", "Clear text index"] {
            #expect(text.contains(line), "\(line) missing, read: \(text)")
        }
    }
}
