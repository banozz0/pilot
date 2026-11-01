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

    @Test("Same site is the site's host, its subdomains and the extra hosts, whatever the case or www; sign-in stays in the web app")
    func sameSite() {
        let site = SameSite(siteURL: URL(string: "https://www.X.com")!, extraHosts: ["Twitter.com"])
        #expect(site.contains(URL(string: "https://x.com/home")!))
        #expect(site.contains(URL(string: "https://API.x.com")!))
        #expect(site.contains(URL(string: "https://mobile.twitter.com")!))
        #expect(site.contains(URL(string: "about:blank")!))
        #expect(!site.contains(URL(string: "https://notx.com")!))
        #expect(!site.contains(URL(string: "https://iana.org/help")!))

        // Sign-in stays (bug 2026-11-01): Messenger's Facebook verify and back, sign-in pages anywhere, a popup closes once home.
        func url(_ s: String) -> URL { URL(string: s)! }
        let messenger = SameSite.forWebApp(siteURL: url("https://www.messenger.com"), extraHosts: [])
        // Sven's bug: the verify page's Continue to facebook.com, Facebook's own steps, then back to Messenger's auth token.
        for (step, link) in ["https://www.facebook.com/checkpoint/1501092823525282/?next=https%3A%2F%2Fwww.messenger.com%2F",
                             "https://m.facebook.com/login/?next=https%3A%2F%2Fwww.messenger.com", "https://www.facebook.com/settings",
                             "https://www.messenger.com/login/auth_token/?userid=1", "https://static.xx.fbcdn.net/a.png"].enumerated() {
            #expect(messenger.route(url(link), click: true) == .here, "step \(step)")
        }
        #expect(messenger.route(url("https://www.instagram.com/p/x"), click: true) == .browser)
        // The pair is the web app's own: a facebook.com URL bind does not open the Messenger app.
        #expect(!SameSite(siteURL: url("https://messenger.com"), extraHosts: []).contains(url("https://facebook.com")))
        #expect(SameSite.forWebApp(siteURL: url("https://x.com"), extraHosts: []).contains(url("https://mobile.twitter.com/a")))

        // Another site: sign-in pages stay, every other page of their hosts still goes to the browser.
        let slack = SameSite.forWebApp(siteURL: url("https://app.slack.com"), extraHosts: [])
        for page in ["https://accounts.google.com/o/oauth2/v2/auth?client_id=1", "https://appleid.apple.com/auth/authorize",
                     "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", "https://login.live.com/oauth20_authorize.srf",
                     "https://id.atlassian.com/login", "https://acme.okta.com/app/x/sso", "https://acme.us.auth0.com/authorize",
                     "https://github.com/login/oauth/authorize?client_id=1", "https://github.com/sessions/two-factor",
                     "https://www.facebook.com/v19.0/dialog/oauth?client_id=1", "https://www.instagram.com/accounts/login/"] {
            #expect(slack.route(url(page), click: true) == .here, "\(page)")
        }
        for page in ["https://github.com/example/project", "https://www.facebook.com/someone", "https://mail.google.com",
                     "https://iana.org", "https://github.com/loginx"] {
            #expect(slack.route(url(page), click: true) == .browser, "\(page)")
        }
        // Redirects and form posts stay wherever they go, as before.
        #expect(slack.route(url("https://iana.org"), click: false) == .here)

        // New windows: a target=_blank link or a script's window.open to the site loads here, elsewhere leaves; a script's
        // window to a sign-in page or a blank page is a popup; a sized one always was.
        #expect(slack.route(url("https://app.slack.com/x"), click: false, newWindow: true) == .here)
        #expect(slack.route(url("https://app.slack.com/x"), click: true, newWindow: true) == .here)
        #expect(slack.route(url("https://accounts.google.com/x"), click: true, newWindow: true) == .here)
        #expect(slack.route(url("https://iana.org"), click: true, newWindow: true) == .browser)
        #expect(slack.route(url("https://accounts.google.com/o/oauth2"), click: false, newWindow: true) == .popup)
        #expect(slack.route(url("about:blank"), click: false, newWindow: true) == .popup)
        #expect(slack.route(url("https://slack.com/oauth/v2/authorize"), click: false, newWindow: true) == .popup)
        #expect(slack.route(url("https://iana.org"), click: false, newWindow: true) == .browser)
        #expect(slack.route(url("https://iana.org"), click: true, newWindow: true, sized: true) == .popup)

        // The popup's trip: blank, the site's own start, Google, back on the site: over. One that never left stays open.
        var trip = SignInTrip(site: slack)
        for step in ["about:blank", "https://app.slack.com/auth/start"] { trip.visit(url(step)) }
        #expect(!trip.isOver(at: url("https://app.slack.com/auth/start")))
        trip.visit(url("https://accounts.google.com/o/oauth2"))
        #expect(!trip.isOver(at: url("https://accounts.google.com/o/oauth2")))
        #expect(trip.isOver(at: url("https://app.slack.com/client/T1/done")))
        var compose = SignInTrip(site: slack)
        compose.visit(url("https://app.slack.com/compose"))
        #expect(!compose.isOver(at: url("https://app.slack.com/compose")))
    }
}
