import Foundation
import Testing
@testable import WebApps

@Suite("Web app spec")
struct WebAppSpecTests {
    @Test("The bundle id is dev.banozz.pilot.webapp plus the host slug, www dropped")
    func bundleID() throws {
        #expect(try WebAppSpec(name: "Example", url: "https://example.com").bundleID == "dev.banozz.pilot.webapp.example-com")
        #expect(try WebAppSpec(name: "X", url: "https://x.com/home").bundleID == "dev.banozz.pilot.webapp.x-com")
        #expect(try WebAppSpec(name: "Gmail", url: "https://mail.google.com/mail/u/0/").bundleID == "dev.banozz.pilot.webapp.mail-google-com")
        #expect(try WebAppSpec(name: "Ex", url: "https://WWW.Example.com").bundleID == "dev.banozz.pilot.webapp.example-com")
    }

    @Test("A URL without a web host is refused")
    func refusesNonWebURL() {
        #expect(throws: WebAppError.self) { try WebAppSpec(name: "A", url: "notaurl") }
        #expect(throws: WebAppError.self) { try WebAppSpec(name: "A", url: "file:///etc/hosts") }
        #expect(throws: WebAppError.self) { try WebAppSpec(name: "", url: "https://example.com") }
    }

    @Test("The data store id is stable across re-stamps and differs per site, so logins survive a re-stamp")
    func dataStoreID() throws {
        let a = try WebAppSpec(name: "Example", url: "https://example.com")
        let again = try WebAppSpec(name: "Renamed", url: "https://example.com/other")
        let b = try WebAppSpec(name: "X", url: "https://x.com")
        #expect(a.dataStoreID == again.dataStoreID)
        #expect(a.dataStoreID != b.dataStoreID)
    }

    @Test("Info.plist carries the identity, the site and the template executable")
    func infoPlist() throws {
        var spec = try WebAppSpec(name: "X", url: "https://x.com")
        spec.externalBrowser = "app.zen-browser.zen"
        spec.sameSiteHosts = ["twitter.com"]
        let plist = spec.infoPlist(hasIcon: true)
        #expect(plist["CFBundleIdentifier"] as? String == "dev.banozz.pilot.webapp.x-com")
        #expect(plist["CFBundleName"] as? String == "X")
        #expect(plist["CFBundleExecutable"] as? String == "PilotWebApp")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["PilotURL"] as? String == "https://x.com")
        #expect(plist["PilotDataStoreID"] as? String == spec.dataStoreID.uuidString)
        #expect(plist["PilotExternalBrowser"] as? String == "app.zen-browser.zen")
        #expect(plist["PilotSameSiteHosts"] as? [String] == ["twitter.com"])
        #expect(spec.infoPlist(hasIcon: false)["CFBundleIconFile"] == nil)
    }

    @Test("The app file is named after the web app, with path characters replaced")
    func appFileName() throws {
        #expect(try WebAppSpec(name: "X", url: "https://x.com").appFileName == "X.app")
        #expect(try WebAppSpec(name: "Mail/Work: Gmail", url: "https://mail.google.com").appFileName == "Mail-Work- Gmail.app")
    }

    @Test("Same site is the site's host, its subdomains and the extra hosts, whatever the case or www")
    func sameSite() {
        let site = SameSite(siteURL: URL(string: "https://www.X.com")!, extraHosts: ["Twitter.com"])
        #expect(site.contains(URL(string: "https://x.com/home")!))
        #expect(site.contains(URL(string: "https://API.x.com")!))
        #expect(site.contains(URL(string: "https://mobile.twitter.com")!))
        #expect(site.contains(URL(string: "about:blank")!))
        #expect(!site.contains(URL(string: "https://notx.com")!))
        #expect(!site.contains(URL(string: "https://iana.org/help")!))
    }
}
