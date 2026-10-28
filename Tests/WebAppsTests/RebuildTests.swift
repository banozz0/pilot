import CryptoKit
import Foundation
import Testing
@testable import WebApps

/// Settings › Web apps → Rebuild (card agent-bo-95422813): a web app stamped earlier gets the newest template and keeps
/// everything that makes it itself, logins included. Signed ad hoc ("-"), so no keychain is touched and nothing launches.
@Suite("Web app rebuild", .serialized)
struct RebuildTests {
    /// The real template SwiftPM built, and a different Mach-O standing in for an older one.
    static let newTemplate = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appending(path: "PilotWebApp")
    static let oldTemplate = URL(fileURLWithPath: "/usr/bin/true")
    final class Marker {}

    let folder = FileManager.default.temporaryDirectory.appending(path: "pilot-rebuild-\(UUID().uuidString)")

    func digest(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    static func exampleSpec() throws -> WebAppSpec {
        var spec = try WebAppSpec(name: "Example", url: "https://example.com/start")
        spec.externalBrowser = "app.zen-browser.zen"
        spec.sameSiteHosts = ["example.org"]
        return spec
    }

    func stampOld(named fileName: String? = nil) throws -> InstalledWebApp {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var app = try WebAppStamper.stamp(try Self.exampleSpec(), template: Self.oldTemplate, into: folder, icon: Data("icon-bytes".utf8), signingIdentity: "-")
        if let fileName {
            let renamed = folder.appending(path: fileName)
            try FileManager.default.moveItem(at: app, to: renamed)
            app = renamed
        }
        return try #require(WebAppDirectory.read(app))
    }

    @Test("A rebuild keeps the bundle id, data store, Info.plist values, icon and file name, and holds the new template")
    func keepsItself() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try stampOld(named: "My Example.app")
        let before = try #require(NSDictionary(contentsOf: old.location.appending(path: "Contents/Info.plist")) as? [String: Any])
        #expect(old.spec.externalBrowser == "app.zen-browser.zen" && old.spec.sameSiteHosts == ["example.org"])

        let rebuilt = try WebAppStamper.rebuild(old, template: Self.newTemplate, signingIdentity: "-")

        #expect(rebuilt == old.location)
        let after = try #require(NSDictionary(contentsOf: rebuilt.appending(path: "Contents/Info.plist")) as? [String: Any])
        for key in ["CFBundleIdentifier", "CFBundleName", WebAppKey.url, WebAppKey.dataStoreID, WebAppKey.externalBrowser, "CFBundleIconFile"] {
            #expect(String(describing: after[key]) == String(describing: before[key]), "\(key)")
        }
        #expect(after[WebAppKey.sameSiteHosts] as? [String] == ["example.org"])
        #expect(try Data(contentsOf: rebuilt.appending(path: "Contents/Resources/AppIcon.icns")) == Data("icon-bytes".utf8))
        // Signing writes into the binary, so the rebuilt one is compared with a fresh stamp of the new template.
        let fresh = folder.appending(path: "fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let reference = try WebAppStamper.stamp(try Self.exampleSpec(), template: Self.newTemplate, into: fresh, icon: Data("icon-bytes".utf8), signingIdentity: "-")
        let binary = "Contents/MacOS/PilotWebApp"
        #expect(try digest(rebuilt.appending(path: binary)) == digest(reference.appending(path: binary)))
        #expect(try digest(rebuilt.appending(path: binary)) != digest(Self.oldTemplate))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".app") } == ["My Example.app"])
    }

    @Test("A rebuild never fetches an icon: an app at a site that cannot be reached keeps the icon it has")
    func noIconFetch() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let spec = try WebAppSpec(name: "Bare", url: "https://bare.invalid")
        let stamped = try WebAppStamper.stamp(spec, template: Self.oldTemplate, into: folder, icon: Data("kept-icon".utf8), signingIdentity: "-")
        let rebuilt = try WebAppStamper.rebuild(try #require(WebAppDirectory.read(stamped)), template: Self.newTemplate, signingIdentity: "-")
        #expect(try Data(contentsOf: rebuilt.appending(path: "Contents/Resources/AppIcon.icns")) == Data("kept-icon".utf8))
    }

    @Test("An app whose stored data store differs from its bundle id's is refused, so its logins are never left behind")
    func refusesOtherDataStore() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try stampOld()
        let plist = app.location.appending(path: "Contents/Info.plist")
        let dictionary = try #require(NSMutableDictionary(contentsOf: plist))
        dictionary[WebAppKey.dataStoreID] = UUID().uuidString
        try dictionary.write(to: plist)
        #expect(throws: WebAppError.self) {
            try WebAppStamper.rebuild(try #require(WebAppDirectory.read(app.location)), template: Self.newTemplate, signingIdentity: "-")
        }
        // An app with no stored id runs on WebKit's default store: refused too.
        dictionary.removeObject(forKey: WebAppKey.dataStoreID)
        try dictionary.write(to: plist)
        #expect(throws: WebAppError.self) {
            try WebAppStamper.rebuild(try #require(WebAppDirectory.read(app.location)), template: Self.newTemplate, signingIdentity: "-")
        }
    }

    /// Live only (launches the stamped app headless, needs the network): PILOT_LIVE=1 swift test --filter RebuildTests.
    @Test("A cookie set before a rebuild is there after it (live, example.com)",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func keepsLogins() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let spec = try WebAppSpec(name: "Example", url: "https://example.com")
        let leftovers = WebAppStamperTests.webKitFolders(for: spec.bundleID).filter { !FileManager.default.fileExists(atPath: $0.path) }
        defer {
            try? FileManager.default.removeItem(at: folder)
            leftovers.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let stamped = try WebAppStamper.stamp(spec, template: Self.newTemplate, into: folder, icon: nil, signingIdentity: "-")
        let set = try run(stamped.appending(path: "Contents/MacOS/PilotWebApp").path, [], env: [
            "PILOT_HEADLESS": "1", "PILOT_EVAL": "document.cookie = 'pilot_rebuild=7; max-age=86400'; document.cookie"])
        #expect(set.output.contains("pilot_rebuild=7"), "before: \(set.output)")
        let rebuilt = try WebAppStamper.rebuild(try #require(WebAppDirectory.read(stamped)), template: Self.newTemplate, signingIdentity: "-")
        let read = try run(rebuilt.appending(path: "Contents/MacOS/PilotWebApp").path, [], env: ["PILOT_HEADLESS": "1", "PILOT_EVAL": "document.cookie"])
        #expect(read.output.contains("pilot_rebuild=7"), "after: \(read.output)")
    }

    @Test("An app whose site would give another bundle id is refused, so its logins are never left behind")
    func refusesNewIdentity() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try stampOld()
        let moved = InstalledWebApp(spec: try WebAppSpec(name: app.name, url: "https://other.example"), bundleID: app.bundleID,
                                    location: app.location)
        #expect(throws: WebAppError.self) { try WebAppStamper.rebuild(moved, template: Self.newTemplate, signingIdentity: "-") }
    }

    final class FakeApps: RunningWebApps, @unchecked Sendable {
        var running: Set<String>
        var quitAsked: [String] = []
        let quits: Bool
        init(running: Set<String>, quits: Bool) { self.running = running; self.quits = quits }
        func isRunning(_ bundleID: String) -> Bool { running.contains(bundleID) }
        func quit(_ bundleID: String) {
            quitAsked.append(bundleID)
            if quits { running.remove(bundleID) }
        }
    }

    @Test("A running app is asked to quit first; one that will not quit blocks its rebuild with a message")
    func running() async throws {
        let apps = FakeApps(running: ["a"], quits: true)
        var built = 0
        try await WebAppRebuild.whenQuit("a", name: "A", apps: apps, wait: .milliseconds(50)) { built += 1 }
        #expect(apps.quitAsked == ["a"] && built == 1)

        let stuck = FakeApps(running: ["b"], quits: false)
        await #expect(throws: WebAppRebuild.StillRunning.self) {
            try await WebAppRebuild.whenQuit("b", name: "B", apps: stuck, wait: .milliseconds(50)) { built += 1 }
        }
        #expect(built == 1)
        #expect(WebAppRebuild.StillRunning(name: "B").message == "B is still running; quit it and press Rebuild again.")
    }

    @Test("Rebuild all asks every running app to quit up front, rebuilds each that went, and names the one that stayed")
    func all() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try stampOld(named: "First.app")
        try FileManager.default.createDirectory(at: folder.appending(path: "b"), withIntermediateDirectories: true)
        let other = try #require(WebAppDirectory.read(try WebAppStamper.stamp(try WebAppSpec(name: "Other", url: "https://other.example"),
                                                                              template: Self.oldTemplate, into: folder.appending(path: "b"),
                                                                              icon: nil, signingIdentity: "-")))
        let apps = FakeApps(running: [first.bundleID, other.bundleID], quits: false)
        apps.running.remove(first.bundleID)  // First quits at once; Other never does
        let outcomes = await WebAppRebuild.all([first, other], running: apps, template: Self.newTemplate, identity: { "-" },
                                               wait: .milliseconds(50))
        #expect(Set(apps.quitAsked) == [other.bundleID])  // only the one running; asked again while it is waited for
        #expect(outcomes == [.init(name: "Example", failure: nil),
                             .init(name: "Other", failure: "Other is still running; quit it and press Rebuild again.")])
    }
}
