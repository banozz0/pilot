import Foundation
import Testing
@testable import PilotCore

/// The drive catalogue (card agent-bo-95422445, story 46): the shipped JSON of known apps and their plain-English
/// actions, each checked against the vendor's docs; an app with none is "not supported".
@Suite("Drive catalogue")
struct DriveCatalogueTests {
    /// The file build-app.sh copies into Pilot.app's Resources.
    static let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Packaging/drive-catalogue.json")

    @Test("The shipped catalogue reads, and starts with the apps the binds drive: Ghostty and Zen")
    func shippedFile() throws {
        let catalogue = try DriveCatalogue(json: Data(contentsOf: Self.shipped))
        #expect(Set(catalogue.apps.map(\.bundle)).isSuperset(of: ["com.mitchellh.ghostty", "app.zen-browser.zen"]))
        #expect(catalogue.actions(for: "com.mitchellh.ghostty")?.contains { $0.route == "drive.menu:com.mitchellh.ghostty:View > Quick Terminal" } == true)
        #expect(catalogue.actions(for: "app.zen-browser.zen")?.contains { $0.route == "apps.private:app.zen-browser.zen" } == true)
    }

    @Test("An app the catalogue does not hold is not supported")
    func notSupported() throws {
        let catalogue = try DriveCatalogue(json: Data(contentsOf: Self.shipped))
        #expect(catalogue.actions(for: "com.apple.TextEdit") == nil)
    }

    @Test("A bound route is named by its app and action, never by its link")
    func label() throws {
        let catalogue = try DriveCatalogue(json: Data(contentsOf: Self.shipped))
        #expect(catalogue.label(for: "drive.menu:com.mitchellh.ghostty:View > Quick Terminal") == "Ghostty: Quick terminal")
        #expect(catalogue.label(for: "drive.shell:true") == nil)
    }

    static let good = """
    {"apps": [{"name": "Shottr", "bundle": "cc.ffitch.shottr", "doc": "https://shottr.cc/kb/urlschemes", "checked": "2026-10-05",
               "actions": [{"label": "Capture area", "route": "drive.url:shottr://grab/area"}]}]}
    """

    @Test("A fixture with a route, a doc URL and a date reads")
    func goodFixture() throws {
        #expect(try DriveCatalogue(json: Data(Self.good.utf8)).apps.count == 1)
    }

    @Test("An entry missing its route, its doc URL or its date, or with a route Pilot cannot run, is refused",
          arguments: [
            ("no route", Self.good.replacingOccurrences(of: #", "route": "drive.url:shottr://grab/area""#, with: "")),
            ("empty route", Self.good.replacingOccurrences(of: "drive.url:shottr://grab/area", with: "")),
            ("unknown route", Self.good.replacingOccurrences(of: "drive.url:shottr://grab/area", with: "shottr://grab/area")),
            ("no doc", Self.good.replacingOccurrences(of: #""doc": "https://shottr.cc/kb/urlschemes", "#, with: "")),
            ("doc not a web page", Self.good.replacingOccurrences(of: "https://shottr.cc/kb/urlschemes", with: "shottr docs")),
            ("no date", Self.good.replacingOccurrences(of: #""checked": "2026-10-05","#, with: "")),
            ("date not a date", Self.good.replacingOccurrences(of: "2026-10-05", with: "today")),
          ])
    func brokenFixture(_ broken: (String, String)) {
        #expect(throws: DriveCatalogue.Problem.self, "\(broken.0)") { try DriveCatalogue(json: Data(broken.1.utf8)) }
    }
}
