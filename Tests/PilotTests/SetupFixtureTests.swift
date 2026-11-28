import Foundation
@testable import Pilot
import PilotCore
import Testing

/// Six setup bugs Sven found by hand, each rebuilt from `Tests/Fixtures/setup/recorded.json`: the shape of a real Mac's
/// setup, every name made up, written by `Scripts/record-setup` (build-test.md rule 7). Each case builds that shape in a
/// throwaway folder and fails with its bug put back. A re-recording that loses a shape fails its case's #require: record
/// again on a Mac that has it, or drop the case. Serialized: two cases point the browser reader at their own folder.
@Suite("setup fixture", .serialized)
struct SetupFixtureTests {
    struct Recording: Decodable {
        struct Temp: Decodable { let spelled: String, resolves: String }
        struct Entry: Decodable { let kind: String, to: String?, lands: String? }
        struct Browser: Decodable {
            /// A Chromium profile's bookmarks files by name, each its page count (nil: it did not parse).
            struct Profile: Decodable {
                let name: String, bookmarks: [String: Int?]?
                func pages(_ file: String) -> Int { (bookmarks?[file] ?? nil) ?? 0 }
            }
            let family: String, folder: String, bundles: [String], installed: Bool, profiles: [Profile]
        }
        let tempFolder: Temp, homeApps: [String], configs: [String: Entry], supportFolders: [String: String?], browsers: [Browser]
    }

    static let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../..").standardizedFileURL
    static let recorded: Recording = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(Recording.self, from: Data(contentsOf: repo.appending(path: "Tests/Fixtures/setup/recorded.json")))
    }()

    /// A throwaway folder in Foundation's spelling (/var/folders/…, links resolved as ThemeFiles reads roots).
    static func sandbox() throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "setup-fixture-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A recorded path (`~/…`) inside the sandbox home.
    static func place(_ recorded: String, _ home: String) -> String { home + (recorded.hasPrefix("~") ? String(recorded.dropFirst()) : recorded) }

    /// A file with `contents` (its folders made), or a folder.
    static func make(_ path: String, _ contents: Data? = nil) throws {
        let manager = FileManager.default
        guard let contents else { return try manager.createDirectory(atPath: path, withIntermediateDirectories: true) }
        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try contents.write(to: URL(filePath: path))
    }

    /// Pilot's browser for a recorded one, by the bundle ids both take from WebSearch's tables.
    static func browser(_ recorded: Recording.Browser) -> BrowserBookmarks.Browser? {
        BrowserBookmarks.browsers.first { $0.bundles.contains(recorded.bundles[0]) }
    }

    /// A Chromium bookmarks file with `count` made-up pages in its bar.
    static func chromiumBookmarks(_ count: Int, _ tag: String) throws -> Data {
        let pages = (0..<count).map { ["type": "url", "name": "Page \($0)", "url": "https://example.com/\(tag)/\($0)"] }
        return try JSONSerialization.data(withJSONObject: ["roots": ["bookmark_bar": ["type": "folder", "children": pages]]])
    }

    /// The browser reader's home for the length of `body`: its sandbox stand-in, apps under `Applications/<bundle id>`.
    static func readingBrowsers<T>(from home: String, _ body: () async throws -> T) async rethrows -> T {
        setenv("PILOT_SANDBOX_BROWSERS", home, 1)
        defer { unsetenv("PILOT_SANDBOX_BROWSERS") }
        return try await body()
    }

    /// Bug 3 (2026-10-24): an app kept in a home folder outside the application folders was no app to Pilot.
    @Test("An app kept in home outside the application folders is listed")
    func homeApp() throws {
        let app = try #require(Self.recorded.homeApps.first, "the recording has no app kept in home")
        let home = try Self.sandbox()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let bundle = Self.place(app, home)
        try Self.make(bundle + "/Contents")
        // The walk lists the folder as /private/var; compared in Foundation's spelling, as the sandbox is.
        let found = AppsModule.homeApps(home: home, fullDiskAccess: true).apps
            .map { URL(filePath: $0.dir + "/" + $0.entry).resolvingSymlinksInPath().path }
        #expect(found.contains(bundle), "home walk found \(found)")
    }

    /// Bug 11 (2026-11-09): Obsidian's support folder is lowercase on disk; detection read `Obsidian` and found no vaults.
    @Test("Obsidian's vaults are found under its support folder as the disk spells it")
    func obsidianFolderCase() throws {
        let spelled = try #require(Self.recorded.supportFolders["obsidian"] ?? nil, "the recording has no Obsidian folder")
        let home = try Self.sandbox()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let vault = home + "/Notes"
        try Self.make(vault + "/.obsidian")
        let listed = try JSONSerialization.data(withJSONObject: ["vaults": ["a1b2c3": ["path": vault, "ts": 1]]])
        try Self.make(home + "/Library/Application Support/\(spelled)/obsidian.json", listed)
        let found = ThemeCoordinator.detectApps(home: home, within: home)
        #expect(found.vaults.map(\.root) == [vault])
    }

    /// Bug 11 (2026-11-09): Ghostty's config is a link into a dotfiles repo; Apply refused it, "target escapes bound root".
    @Test("Ghostty's config linked to a file elsewhere in home reads through the link")
    func ghosttyLinkedConfig() throws {
        let entry = try #require(Self.recorded.configs[".config/ghostty/config"], "the recording has no Ghostty config")
        try #require(entry.kind == "link" && entry.lands == "file", "Ghostty's config is no link to a file in the recording")
        let home = try Self.sandbox()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let target = Self.place(try #require(entry.to), home), bytes = Data("font-size = 13\n".utf8)
        try Self.make(target, bytes)
        let folder = home + "/.config/ghostty"
        try Self.make(folder)
        try FileManager.default.createSymbolicLink(atPath: folder + "/config", withDestinationPath: target)
        let read = try ThemeFiles.read(root: folder, path: "config", linkedLeaf: true)
        #expect(read.bytes == bytes)
    }

    /// Bug 18 (2026-11-16): a pack library spelled through a link (/var for /private/var) loaded no wallpapers.
    @Test("A pack under a root spelled through the temp folder's link loads its wallpapers")
    func packUnderLinkedRoot() throws {
        let temp = Self.recorded.tempFolder
        try #require(temp.spelled != temp.resolves, "the recording's temp folder is spelled without a link")
        let root = try Self.sandbox()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try #require(root.hasPrefix(temp.spelled + "/"), "this run's temp folder \(root) is not spelled as the recording's \(temp.spelled)")
        let packs = root + "/packs"
        try Self.make(packs)
        try FileManager.default.copyItem(at: Self.repo.appending(path: "catalogue/themes/beacon"), to: URL(filePath: packs + "/beacon"))
        let loaded = try ThemePackStore(root: packs, writableRoot: packs).load("beacon")
        #expect(!loaded.images.isEmpty)
    }

    /// Bug 27 (2026-11-22): a removed browser's folder stays behind (Zen's), and its bookmarks were listed.
    @Test("A browser whose folder stayed after its app went counts as not installed")
    func leftoverBrowser() async throws {
        let gone = try #require(Self.recorded.browsers.first { !$0.installed && !$0.profiles.isEmpty }, "the recording has no leftover browser folder")
        let kept = Self.recorded.browsers.first { $0.installed && !$0.profiles.isEmpty }
        let home = try Self.sandbox()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let support = home + "/Library/Application Support/"
        for browser in [gone, kept].compactMap({ $0 }) {
            for profile in browser.profiles {
                if browser.family == "firefox" { try Self.make(support + browser.folder + "/Profiles/" + profile.name + "/places.sqlite", Data()) }
                else { try Self.make(support + browser.folder + "/" + profile.name + "/Bookmarks", try Self.chromiumBookmarks(1, profile.name)) }
            }
        }
        if let kept { try Self.make(home + "/Applications/" + kept.bundles[0]) }
        let leftover = try #require(Self.browser(gone))
        #expect(!BrowserBookmarks.profiles(leftover, home: URL(filePath: home)).isEmpty, "the leftover's profile is not on disk")
        let installed = await Self.readingBrowsers(from: home) { BrowserReader.installed().map(\.name) }
        #expect(!installed.contains(leftover.name), "installed: \(installed)")
        if let kept, let browser = Self.browser(kept) { #expect(installed.contains(browser.name), "installed: \(installed)") }
    }

    /// Chrome on build 3114 (2026-11-22): a signed-in account's bookmarks live in AccountBookmarks; Bookmarks held none.
    @Test("A Chromium profile's signed-in account bookmarks reach the menu beside its own")
    func accountBookmarks() async throws {
        let signedIn = Self.recorded.browsers.filter { $0.family == "chromium" }.compactMap { browser in
            browser.profiles.first { $0.pages("AccountBookmarks") > 0 }.map { (browser, $0) }
        }.first
        let (browser, profile) = try #require(signedIn, "the recording has no profile with account bookmarks")
        let own = profile.pages("Bookmarks"), account = profile.pages("AccountBookmarks")
        try #require(await MainActor.run { BrowserSettings.shared.bookmarks }, "the bookmarks switch is off in this run")
        let home = try Self.sandbox()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = home + "/Library/Application Support/" + browser.folder + "/" + profile.name
        try Self.make(folder + "/Bookmarks", try Self.chromiumBookmarks(own, "own"))
        try Self.make(folder + "/AccountBookmarks", try Self.chromiumBookmarks(account, "account"))
        try Self.make(home + "/Applications/" + browser.bundles[0])
        let rows = await Self.readingBrowsers(from: home) { await BrowserReader().bookmarks().rows }
        #expect(rows.count == own + account)
    }
}
