import Foundation
import Testing
@testable import WebApps

/// Settings › Web apps and URL binds (stories 87 and 19): the web apps Pilot stamped, which one a URL opens in,
/// and Remove.
@Suite("Web app directory")
struct WebAppDirectoryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-webapps-\(UUID().uuidString)")

    /// A bundle with only the Info.plist a stamp writes; enough for the directory, which never launches it.
    @discardableResult
    func fake(_ name: String, _ url: String, bundleID: String? = nil) throws -> URL {
        let spec = try WebAppSpec(name: name, url: url)
        var plist = spec.infoPlist(hasIcon: false)
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        let app = folder.appending(path: spec.appFileName)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    @Test("Lists the web apps Pilot stamped, by name, and skips every other app")
    func list() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try fake("X", "https://x.com")
        try fake("Gmail", "https://mail.google.com/mail/u/0/")
        try fake("Safari thing", "https://example.org", bundleID: "com.apple.Safari.WebApp.1234")
        let apps = WebAppDirectory.list(in: folder)
        #expect(apps.map(\.name) == ["Gmail", "X"])
        #expect(apps.map(\.bundleID) == ["dev.banozz.pilot.webapp.mail-google-com", "dev.banozz.pilot.webapp.x-com"])
        #expect(apps.first?.url.absoluteString == "https://mail.google.com/mail/u/0/")
        #expect(apps.first?.location.lastPathComponent == "Gmail.app")
    }

    @Test("An empty or missing folder lists nothing")
    func missingFolder() {
        #expect(WebAppDirectory.list(in: folder).isEmpty)
    }

    @Test("A URL opens in the web app for its site, www and path ignored; another site has none")
    func match() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try fake("Example", "https://example.com")
        try fake("Gmail", "https://mail.google.com/mail/u/0/")
        #expect(WebAppDirectory.app(for: URL(string: "https://example.com")!, in: folder)?.name == "Example")
        #expect(WebAppDirectory.app(for: URL(string: "https://www.Example.com/a/b?c=d")!, in: folder)?.name == "Example")
        #expect(WebAppDirectory.app(for: URL(string: "https://mail.google.com/")!, in: folder)?.name == "Gmail")
        #expect(WebAppDirectory.app(for: URL(string: "https://google.com")!, in: folder) == nil)
        #expect(WebAppDirectory.app(for: URL(string: "https://iana.org")!, in: folder) == nil)
    }

    @Test("When a site and its subdomain both have a web app, the subdomain's wins")
    func mostSpecific() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try fake("Google", "https://google.com")
        try fake("Gmail", "https://mail.google.com")
        #expect(WebAppDirectory.app(for: URL(string: "https://mail.google.com/x")!, in: folder)?.name == "Gmail")
        #expect(WebAppDirectory.app(for: URL(string: "https://docs.google.com")!, in: folder)?.name == "Google")
    }

    @Test("Remove moves the app to the Trash, so it leaves the list and can be put back")
    func remove() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try fake("Example", "https://example.com")
        let app = try #require(WebAppDirectory.list(in: folder).first)
        let trashed = try WebAppDirectory.trash(app.location)
        defer { try? FileManager.default.removeItem(at: trashed) }
        #expect(WebAppDirectory.list(in: folder).isEmpty)
        #expect(FileManager.default.fileExists(atPath: trashed.appending(path: "Contents/Info.plist").path))
    }

    @Test("The suggested name is the site's own short name, then its title, then its host")
    func suggestedName() {
        let page = URL(string: "https://x.com/home")!
        #expect(WebAppSpec.suggestedName(html: #"<meta name="application-name" content="Gmail"><title>Inbox (3) - me</title>"#, page: page) == "Gmail")
        #expect(WebAppSpec.suggestedName(html: #"<meta property='og:site_name' content='YouTube'>"#, page: page) == "YouTube")
        #expect(WebAppSpec.suggestedName(html: "<html><head><title>\n  Example Domain </title>", page: page) == "Example Domain")
        #expect(WebAppSpec.suggestedName(html: "<title>Tom &amp; Jerry</title>", page: page) == "Tom & Jerry")
        #expect(WebAppSpec.suggestedName(html: "", page: URL(string: "https://www.claude.ai/new")!) == "Claude")
        #expect(WebAppSpec.suggestedName(html: "<title></title>", page: page) == "X")
    }
}
