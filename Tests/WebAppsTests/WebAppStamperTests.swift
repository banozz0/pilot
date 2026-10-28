import AppKit
import Testing
@testable import WebApps

/// SPEC.md, Testing Decisions: stamp https://example.com into a temporary folder, check the bundle id in
/// Info.plist, codesign --verify, launch it, and read back a cookie after a relaunch. Needs the network.
@Suite("Web app stamper", .serialized)
struct WebAppStamperTests {
    /// The PilotWebApp binary SwiftPM built next to this test bundle.
    static let template = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "PilotWebApp")
    final class Marker {}

    /// Live only: it launches the stamped app, and one run left a macOS SecurityAgent password prompt over Sven's screen
    /// (2026-10-05, lane 1); PILOT_LIVE=1 swift test --filter WebAppStamper runs it.
    @Test("A stamped example.com is signed, launches, and keeps a cookie across a relaunch",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func stampLaunchRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-webapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let spec = try WebAppSpec(name: "Example", url: "https://example.com")
        let leftovers = Self.webKitFolders(for: spec.bundleID).filter { !FileManager.default.fileExists(atPath: $0.path) }
        defer {
            try? FileManager.default.removeItem(at: folder)
            leftovers.forEach { try? FileManager.default.removeItem(at: $0) }  // only what this test created
        }

        let app = try WebAppStamper.stamp(spec, template: Self.template, into: folder,
                                          icon: nil, signingIdentity: SigningIdentity.resolve())

        #expect(app.lastPathComponent == "Example.app")
        let plist = try #require(NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")))
        #expect(plist["CFBundleIdentifier"] as? String == "dev.banozz.pilot.webapp.example-com")
        #expect(try run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0)

        let binary = app.appending(path: "Contents/MacOS/PilotWebApp").path
        let set = try run(binary, [], env: [
            "PILOT_HEADLESS": "1",
            "PILOT_EVAL": "document.cookie = 'pilot_probe=42; max-age=86400'; document.cookie",
        ])
        #expect(set.output.contains("PILOT_EVAL result=Optional(pilot_probe=42)"), "first run: \(set.output)")
        // The site's own store, not WebKit's default one: the stamped data store id was read.
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/WebKit/\(spec.bundleID)/WebsiteDataStore/\(spec.dataStoreID.uuidString)")
        #expect(FileManager.default.fileExists(atPath: store.path), "no store at \(store.path)")
        let read = try run(binary, [], env: ["PILOT_HEADLESS": "1", "PILOT_EVAL": "document.cookie"])
        #expect(read.output.contains("pilot_probe=42"), "relaunch: \(read.output)")

        // example.com's one link goes to iana.org, another site, so it leaves for the browser.
        let click = try run(binary, [], env: ["PILOT_HEADLESS": "1",
                                                   "PILOT_EVAL": "document.querySelector('a').click(); 'clicked'"])
        #expect(click.output.contains("PILOT_EXTERNAL https://iana.org/"), "link: \(click.output)")
    }

    @Test("A stamp replaces an earlier web app of its name, and refuses and keeps any other app there")
    func stampKeepsOtherApps() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-webapp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let spec = try WebAppSpec(name: "Example", url: "https://example.com")
        // Any Mach-O as the template and an ad hoc signature: no Keychain, nothing launched.
        func stamp() throws -> URL { try WebAppStamper.stamp(spec, template: URL(filePath: "/usr/bin/true"), into: folder, icon: nil, signingIdentity: "-") }
        let app = try stamp()
        #expect(try stamp() == app && WebAppDirectory.read(app)?.bundleID == spec.bundleID, "an earlier web app is replaced")

        try FileManager.default.removeItem(at: app)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let other = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.desktop"], format: .xml, options: 0)
        try other.write(to: app.appending(path: "Contents/Info.plist"))
        #expect(throws: WebAppError.self) { try stamp() }
        #expect(try Data(contentsOf: app.appending(path: "Contents/Info.plist")) == other, "the other app is kept as it was")
    }

    @Test("Install fetches the site's own icon (live, x.com)",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func installFetchesIcon() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-webapp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try await WebAppStamper.install(try WebAppSpec(name: "X", url: "https://x.com"),
                                                  template: Self.template, into: folder)
        let icon = try #require(NSImage(contentsOf: app.appending(path: "Contents/Resources/AppIcon.icns")))
        #expect(icon.representations.contains { $0.pixelsWide == 1024 })
        #expect(try run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0)
    }

    static func webKitFolders(for bundleID: String) -> [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return ["WebKit/\(bundleID)", "HTTPStorages/\(bundleID)", "HTTPStorages/\(bundleID).binarycookies",
                "Caches/\(bundleID)"].map { library.appending(path: $0) }
    }
}
