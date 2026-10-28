import Foundation
import PilotCore
import Testing
import WebApps
@testable import Pilot

/// AI helper T9: packages, web apps, role picks and extensions as `pilot list|add|remove <collection>`, in a test home
/// of its own. Nothing installs: Install's visible terminal is a recorder, web apps stamp into a temp folder, signed ad
/// hoc, and the Trash is a temp folder. The gate's decider is the test's; no prompt shows.
@MainActor
@Suite("Collections: apps, web apps, packages")
final class CollectionsAppsTests {
    let home = URL(filePath: NSTemporaryDirectory()).appending(path: "pilot-apps-\(UUID().uuidString)", directoryHint: .isDirectory)
    let stores = AppCollectionStores()
    let verbs = ControlVerbs()
    /// What the gate was asked, the decider's answer, and what reached the visible terminal.
    var asked: [ControlGate.Ask] = []
    var peers: [ControlPeer?] = []
    var allow = false
    /// Runs while the question is up, before the answer: something changing on disk meanwhile.
    var whileAsking: () throws -> Void = {}
    /// Runs after Allow, before the stamp: an app put at the path while the live install fetches the site's icon.
    var beforeStamp: () throws -> Void = {}
    var ran: [(command: String, title: String, onSuccess: String)] = []
    var installed: Set<String> = []
    /// The pages a blank name was fetched from, and the web apps each rebuild was handed.
    var suggested: [URL] = []
    var rebuilt: [[String]] = []
    let defaultApps = FakeDefaultApps()
    var forgot: [AppRole] = []

    init() throws {
        let fm = FileManager.default
        for folder in ["Applications", "Trash", "Extensions"] { try fm.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true) }
        let defaults = UserDefaults(suiteName: testSuite())!
        stores.gate = ControlGate(wait: .seconds(5)) { [unowned self] ask, peer in
            asked.append(ask); peers.append(peer)
            try? whileAsking()
            return allow
        }
        stores.installed = InstalledStore(url: home.appending(path: "installed.json"))
        stores.packageInstalled = { [unowned self] in installed.contains($0.key) }
        stores.run = { [unowned self] in ran.append(($0, $1, $2)) }
        stores.webApps = home.appending(path: "Applications")
        // The real stamper, with any Mach-O as its template and an ad hoc signature: no Keychain, no icon fetch. Off the
        // main actor, as the live install runs, so its codesign never stalls the suites timing work there.
        stores.stamp = { [unowned self] spec, folder in
            try beforeStamp()
            return try await Task.detached {
                try WebAppStamper.stamp(spec, template: URL(filePath: "/usr/bin/true"), into: folder, icon: nil, signingIdentity: "-")
            }.value
        }
        stores.trash = { [home] url in
            let to = home.appending(path: "Trash/\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: to)
            return to
        }
        let apps: Set<String> = ["com.mitchellh.ghostty", "com.microsoft.VSCode"]
        stores.picks = AppRolePicks(defaults: defaults, installed: { apps.contains($0) }, found: { $0 == "codex" })
        stores.editor = EditorChoice(defaults: defaults, installed: { apps.contains($0) }, handler: { _ in nil })
        stores.extensions = home.appending(path: "Extensions")
        stores.suggest = { [unowned self] in suggested.append($0); return "Linear – Plan and build" }
        // The real rebuild, on the test's template, ad hoc signed, with nothing running.
        stores.rebuild = { [unowned self] apps in
            rebuilt.append(apps.map(\.name))
            return await WebAppRebuild.all(apps, running: NothingRunning(), template: URL(filePath: "/usr/bin/true"), identity: { "-" })
        }
        stores.editorChoices = { [("Visual Studio Code", "com.microsoft.VSCode"), ("TextEdit", "com.apple.TextEdit")] }
        stores.automatic = { $0 == .terminal ? "com.mitchellh.ghostty" : "com.apple.\($0.rawValue)" }
        stores.appName = { ["com.mitchellh.ghostty": "Ghostty"][$0] }
        stores.defaultApps = defaultApps
        stores.forget = { [unowned self] in forgot.append($0) }
        verbs.registerAppCollections(stores)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func answer(_ verb: String, _ args: [String], peer: ControlPeer? = nil) async -> ControlAnswer {
        await verbs.answer(ControlRequest(id: .number(1), verb: verb, args: args), peer: peer)
    }

    func rows(_ collection: String) async -> [[String: JSONValue]] {
        guard case .array(let rows) = await answer("list", [collection]).result else { Issue.record("list \(collection) gave no rows"); return [] }
        return rows.compactMap { if case .object(let row) = $0 { row } else { nil } }
    }

    @Test("list packages reads installed.json, Pilot's record of what it installed")
    func listPackages() async throws {
        #expect(await rows("packages").isEmpty)
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try stores.installed.record(Package(.cask, "obsidian")!, at: day)
        try stores.installed.record(Package(.formula, "hello")!, at: day)
        let listed = await rows("packages")
        #expect(listed.map { $0["package"] } == [.string("cask:obsidian"), .string("formula:hello")])
        #expect(listed.first?["via"] == .string("Homebrew app") && listed.first?["installed"] == .string(day.ISO8601Format()))
    }

    @Test("add package asks first: Deny runs nothing; Allow hands Install's flow the key with no confirm click")
    func installPackage() async throws {
        let denied = await answer("add", ["packages", "--package", "formula:hello"])
        #expect(denied.error?.code == .denied && denied.error?.message == "not allowed: Install package: brew install hello")
        #expect(asked == [ControlGate.Ask("Install package", "brew install hello")] && ran.isEmpty)

        allow = true
        let allowed = await answer("add", ["packages", "--package", "formula:hello"])
        #expect(allowed.ok, "\(allowed.error?.message ?? "")")
        #expect(ran.map(\.command) == ["brew install hello"] && ran.first?.title == "Install hello")
        #expect(ran.first?.onSuccess == "open -g 'pilot://installed?package=formula:hello'", "the terminal's success records it, as a click's run does")
        #expect(try stores.installed.load().isEmpty, "nothing is recorded before the command ends")
        #expect(asked.count == 2)
    }

    @Test("add package: an installed one answers without asking; a bad key or none is bad-value")
    func installRefusals() async {
        installed = ["cask:obsidian"]
        let already = await answer("add", ["packages", "--package", "cask:obsidian"])
        #expect(already.result == .object(["package": .string("cask:obsidian"), "installed": .bool(true), "ran": .null]))
        #expect(await answer("add", ["packages", "--package", "brew install x; rm -rf ~"]).error?.message.hasPrefix("--package: ") == true)
        #expect(await answer("add", ["packages", "--package", "page:https://example.com"]).error?.code == .badValue)
        #expect(await answer("add", ["packages"]).error?.message.hasPrefix("packages needs --package") == true)
        #expect(asked.isEmpty && ran.isEmpty)
    }

    @Test("remove package asks with its exact command; Deny runs nothing, Allow runs it in the terminal")
    func removePackage() async {
        #expect(await answer("remove", ["packages", "cask:zed"]).error?.code == .denied && ran.isEmpty)
        allow = true
        #expect(await answer("remove", ["packages", "cask:zed"]).ok)
        #expect(asked.map(\.text) == ["Remove package: brew uninstall --cask zed", "Remove package: brew uninstall --cask zed"])
        #expect(ran.map(\.command) == ["brew uninstall --cask zed"] && ran.first?.onSuccess == "open -g 'pilot://removed?package=cask:zed'")
        #expect(await answer("remove", ["packages", "zed"]).error?.code == .badValue)
    }

    @Test("add webapp is gated and stamps into the folder; list reads it back; remove is gated and trashes it")
    func webApps() async throws {
        let add = ["webapps", "--name", "Linear", "--url", "https://linear.app"]
        #expect(await answer("add", add).error?.code == .denied)
        #expect(asked.last == ControlGate.Ask("Install web app", "Linear, https://linear.app"))
        #expect(await rows("webapps").isEmpty)

        allow = true
        let built = await answer("add", add)
        #expect(built.ok, "\(built.error?.message ?? "")")
        let listed = await rows("webapps")
        #expect(listed.map { $0["bundle"] } == [.string("dev.banozz.pilot.webapp.linear-app")] && listed.first?["name"] == .string("Linear"))
        #expect(listed.first?["action"] == AppsModule.webID("https://linear.app").map { .string($0) })
        let app = stores.webApps.appending(path: "Linear.app").path
        let verified = try await Task.detached {
            let verify = try Process.run(URL(filePath: "/usr/bin/codesign"), arguments: ["--verify", app])
            verify.waitUntilExit()
            return verify.terminationStatus
        }.value
        #expect(verified == 0, "stamped and signed")

        // Building it again says it replaces the one there.
        _ = await answer("add", add)
        #expect(asked.last?.detail == "Linear, https://linear.app, replacing the web app Linear (https://linear.app) there")

        allow = false
        #expect(await answer("remove", ["webapps", "Linear"]).error?.code == .denied)
        #expect(await rows("webapps").count == 1)
        allow = true
        #expect(await answer("remove", ["webapps", "dev.banozz.pilot.webapp.linear-app"]).ok)
        #expect(asked.last == ControlGate.Ask("Remove web app", "Linear: move Linear.app to the Trash"))
        #expect(await rows("webapps").isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "Trash/Linear.app").path))
        #expect(await answer("remove", ["webapps", "Linear"]).error == ControlError(.badValue, "no web app Linear; there are none"))
    }

    @Test("Each gated add and remove hands the gate who asked, so the Allow prompt names the program")
    func gateNamesTheAsker() async throws {
        allow = true
        let me = ControlPeer(pid: getpid(), uid: getuid())
        _ = await answer("add", ["packages", "--package", "formula:hello"], peer: me)
        _ = await answer("remove", ["packages", "formula:hello"], peer: me)
        _ = await answer("add", ["webapps", "--name", "Linear", "--url", "https://linear.app"], peer: me)
        _ = await answer("remove", ["webapps", "Linear"], peer: me)
        #expect(asked.count == 4 && peers == Array(repeating: me, count: 4))
        #expect(AllowPrompt.program(me) != "a program", "the prompt's program line reads this process, not the no-peer fallback")
    }

    /// A plain app bundle at `name`.app in the web apps folder: not one Pilot stamped.
    func plainApp(_ name: String) throws -> URL {
        let app = stores.webApps.appending(path: "\(name).app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.linear.desktop", "CFBundleName": name], format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        return app
    }

    @Test("add webapp refuses a name whose app there Pilot did not stamp: it is kept, nothing asked")
    func webAppKeepsOtherApps() async throws {
        allow = true
        let app = try plainApp("Linear")
        let refused = await answer("add", ["webapps", "--name", "Linear", "--url", "https://linear.app"])
        #expect(refused.error?.code == .badValue && refused.error?.message.hasPrefix("--name: ") == true, "\(String(describing: refused.error))")
        #expect(asked.isEmpty && WebAppDirectory.read(app) == nil)
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents/Info.plist").path), "the other app is untouched")
    }

    @Test("add webapp reads its question again after Allow: an app put at the path while asking denies and is kept")
    func webAppChangedWhileAsking() async throws {
        allow = true
        whileAsking = { [unowned self] in _ = try plainApp("Linear") }
        let denied = await answer("add", ["webapps", "--name", "Linear", "--url", "https://linear.app"])
        #expect(denied.error?.code == .denied && denied.error?.message.hasPrefix("changed while asking") == true, "\(String(describing: denied.error))")
        #expect(asked == [ControlGate.Ask("Install web app", "Linear, https://linear.app")])
        #expect(WebAppDirectory.read(stores.webApps.appending(path: "Linear.app")) == nil, "the other app is not replaced")
    }

    @Test("add webapp: an app put at the path after Allow, while the icon is fetched, is kept and the build refused")
    func webAppAppearsWhileStamping() async throws {
        allow = true
        beforeStamp = { [unowned self] in _ = try plainApp("Linear") }
        let refused = await answer("add", ["webapps", "--name", "Linear", "--url", "https://linear.app"])
        #expect(refused.error?.code == .badValue && refused.error?.message.contains("is not a Pilot web app") == true, "\(String(describing: refused.error))")
        #expect(FileManager.default.fileExists(atPath: stores.webApps.appending(path: "Linear.app/Contents/Info.plist").path))
        #expect(WebAppDirectory.read(stores.webApps.appending(path: "Linear.app")) == nil, "the other app is not replaced")
    }

    @Test("add webapp: a bad site or an empty name is bad-value naming its field, asked nothing")
    func webAppRefusals() async {
        #expect(await answer("add", ["webapps", "--name", "X", "--url", "file:///etc"]).error?.message.hasPrefix("--url:") == true)
        #expect(await answer("add", ["webapps", "--name", " ", "--url", "https://x.com"]).error?.message.hasPrefix("--name:") == true)
        #expect(await answer("add", ["webapps", "--url", "file:///etc"]).error?.message.hasPrefix("--url:") == true, "checked before any fetch")
        #expect(await answer("add", ["webapps", "--name", "X"]).error?.message.hasPrefix("webapps needs --url") == true)
        #expect(asked.isEmpty && suggested.isEmpty)
    }

    @Test("add webapp with no name takes the site's own, as Create app fills a blank one, and asks with it")
    func webAppSuggestedName() async {
        #expect(await answer("add", ["webapps", "--url", "https://linear.app"]).error?.code == .denied)
        #expect(suggested == [URL(string: "https://linear.app")!])
        #expect(asked == [ControlGate.Ask("Install web app", "Linear – Plan and build, https://linear.app")])
        _ = await answer("add", ["webapps", "--name", "", "--url", "https://linear.app"])
        #expect(suggested.count == 2, "an empty --name is blank too")
    }

    @Test("webapp ideas lists the recommended sites with whether one is made; rebuild asks, then rebuilds and reads back")
    func ideasAndRebuild() async throws {
        let ideas = await answer("webapp", ["ideas"])
        guard case .array(let rows) = ideas.result else { Issue.record("ideas gave no rows"); return }
        #expect(rows.count == WebAppIdea.all.count)
        #expect(rows.first == .object(["id": .string("gmail"), "name": .string("Gmail"), "link": .string("https://mail.google.com"),
                                       "host": .string("mail.google.com"), "made": .bool(false)]))

        allow = true
        #expect(await answer("add", ["webapps", "--name", "Linear", "--url", "https://linear.app"]).ok)
        #expect(await answer("add", ["webapps", "--name", "Gmail", "--url", "https://mail.google.com"]).ok)
        guard case .array(let after) = await answer("webapp", ["ideas"]).result else { return }
        #expect(after.filter { if case .object(let r) = $0 { r["made"] == .bool(true) } else { false } }.count == 2)

        asked = []; allow = false
        #expect(await answer("webapp", ["rebuild", "Linear"]).error?.code == .denied && rebuilt.isEmpty)
        #expect(asked == [ControlGate.Ask("Rebuild web app", "Linear: quits each one running, then rebuilds it with Pilot's newest web app")])
        allow = true
        let one = await answer("webapp", ["rebuild", "dev.banozz.pilot.webapp.linear-app"])
        #expect(one.ok, "\(one.error?.message ?? "")")
        guard case .object(let answered) = one.result else { return }
        #expect(answered["rebuilt"] == .array([.object(["name": .string("Linear"), "rebuilt": .bool(true)])]))
        guard case .array(let listed) = answered["webapps"] else { Issue.record("no web apps read back"); return }
        #expect(listed.count == 2)
        #expect(await answer("webapp", ["rebuild", "all"]).ok)
        #expect(rebuilt == [["Linear"], ["Gmail", "Linear"]])
        #expect(asked.last?.detail.hasPrefix("Gmail, Linear: ") == true)

        #expect(await answer("webapp", ["rebuild", "Nope"]).error?.message == "no web app Nope; there are Gmail, Linear")
        #expect(await answer("webapp", ["rebuild"]).error?.code == .badRequest)
        #expect(await answer("webapp", ["build"]).error?.code == .badValue)
        #expect(await answer("webapp", ["ideas", "--all"]).error?.code == .unknownFlag)
    }

    @Test("Role picks set and read back from the objects Settings binds to; remove goes back to Automatic")
    func roles() async {
        let terminal = await answer("add", ["roles", "--role", "terminal", "--app", "com.mitchellh.ghostty"])
        #expect(terminal.result == .object(["role": .string("terminal"), "pick": .string("com.mitchellh.ghostty"), "app": .string("com.mitchellh.ghostty"),
                                            "automatic": .string("com.mitchellh.ghostty"),
                                            "choices": .array([.object(["bundle": .string("com.mitchellh.ghostty"), "name": .string("Ghostty")])])]))
        #expect(stores.picks.app(.terminal) == "com.mitchellh.ghostty")
        #expect(await answer("add", ["roles", "--role", "editor", "--app", "com.microsoft.VSCode"]).ok && stores.editor.pick == "com.microsoft.VSCode")
        #expect(await answer("add", ["roles", "--role", "notes", "--app", AppRolePicks.pilot]).ok, "Pilot's own notes need no install")
        let listed = await rows("roles")
        #expect(listed.map { $0["role"] } == ["terminal", "agent", "browser", "messages", "ai", "mail", "notes", "music", "passwords", "editor"]
            .map { .string($0) })
        #expect(listed.last?["pick"] == .string("com.microsoft.VSCode") && listed[2]["pick"] == .string("automatic"))
        #expect(await answer("add", ["roles", "--role", "ai", "--app", "https://chatgpt.com"]).ok, "a website needs no install (Q463)")
        #expect(await answer("add", ["roles", "--role", "agent", "--app", "codex"]).ok && stores.picks.app(.agent) == "codex")
        #expect(await answer("add", ["roles", "--role", "agent", "--app", "claude"]).error?.message.hasPrefix("--app: no command") == true)

        #expect(await answer("remove", ["roles", "terminal"]).ok && stores.picks.picks[.terminal] == nil)
        #expect(await answer("remove", ["roles", "editor"]).ok && stores.editor.pick == nil)
        #expect(await answer("add", ["roles", "--role", "terminal", "--app", "com.nope.App"]).error?.message.hasPrefix("--app:") == true)
        #expect(await answer("add", ["roles", "--role", "files", "--app", "com.mitchellh.ghostty"]).error?.message.hasPrefix("--role:") == true)
        #expect(stores.picks.picks[.terminal] == nil && asked.isEmpty)
    }

    @Test("list roles says what Automatic gives and the picker's apps; the editor takes only one of its choices")
    func roleChoices() async {
        let listed = await rows("roles")
        #expect(listed[0]["pick"] == .string("automatic") && listed[0]["automatic"] == .string("com.mitchellh.ghostty") && listed[0]["app"] == nil)
        #expect(listed[6]["choices"] == .array([.object(["bundle": .string(AppRolePicks.pilot), "name": .string("Pilot quick notes")])]),
                "Notes offers Pilot's quick notes; no known notes app is installed")
        #expect(listed[9]["choices"] == .array([.object(["bundle": .string("com.microsoft.VSCode"), "name": .string("Visual Studio Code")]),
                                                .object(["bundle": .string("com.apple.TextEdit"), "name": .string("TextEdit")])]))
        let refused = await answer("add", ["roles", "--role", "editor", "--app", "com.mitchellh.ghostty"])
        #expect(refused.error?.message == "--app: com.mitchellh.ghostty is not an editor choice; there are com.microsoft.VSCode, com.apple.TextEdit")
        #expect(stores.editor.pick == nil)
        #expect(await answer("add", ["roles", "--role", "music", "--app", "com.mitchellh.ghostty"]).ok, "a key takes any installed app, as Other app… does")
    }

    @Test("list default-apps reads each kind, main cards first; add asks with old → new, sets it and reads it back")
    func defaultApps() async throws {
        let listed = await rows("default-apps")
        #expect(listed.prefix(3).map { $0["kind"] } == ["web", "public.plain-text", "net.daringfireball.markdown"].map { .string($0) })
        #expect(listed.count == FileKinds.groups.flatMap(\.kinds).count && listed.filter { $0["main"] == .bool(true) }.count == 3)
        let text = listed[1]
        #expect(text["current"] == .string("com.microsoft.VSCode") && text["currentName"] == .string("Visual Studio Code"))
        #expect(text["name"] == .string("Plain text") && text["covers"] == .string(".txt") && text["group"] == .string("Text"))
        #expect(listed[0]["current"] == .string("com.google.Chrome") && listed[0]["currentName"] == .string("Name of com.google.Chrome"),
                "a default macOS left out of the choices is named and listed first")
        #expect(defaultApps.sets.isEmpty, "a list changes nothing")

        let add = ["default-apps", "--kind", "web", "--app", "app.zen-browser.zen"]
        #expect(await answer("add", add).error?.code == .denied && defaultApps.sets.isEmpty)
        #expect(asked == [ControlGate.Ask("Set default app", "Web links: Name of com.google.Chrome → Zen. macOS asks you to confirm a new web browser.")])
        allow = true
        let set = await answer("add", add)
        #expect(set.ok, "\(set.error?.message ?? "")")
        guard case .object(let row) = set.result else { return }
        #expect(row["current"] == .string("app.zen-browser.zen") && row["message"] == nil)
        #expect(defaultApps.current(FakeDefaultApps.http) == "app.zen-browser.zen" && forgot == [.browser])

        asked = []
        #expect(await answer("add", add).ok && asked.isEmpty, "already the default: nothing asked, nothing set")
        defaultApps.refuse = "No"
        let refused = await answer("add", ["default-apps", "--kind", "public.plain-text", "--app", "com.apple.TextEdit"])
        guard case .object(let failed) = refused.result else { Issue.record("no row"); return }
        #expect(failed["current"] == .string("com.microsoft.VSCode") && failed["message"] == .string("Not changed: No"))

        #expect(await answer("add", ["default-apps", "--kind", "nope", "--app", "x"]).error?.message.hasPrefix("--kind: no kind nope") == true)
        #expect(await answer("add", ["default-apps", "--kind", "web", "--app", "com.apple.Terminal"]).error?.message.hasPrefix("--app:") == true)
        #expect(await answer("remove", ["default-apps", "web"]).error?.code == .badValue)
    }

    @Test("list extensions lists the installed ones with their commands; the list is read-only here")
    func extensions() async throws {
        let folder = stores.extensions.appending(path: "ports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"id": "ports", "title": "Ports", "version": "1.0.0", "commands": [{"name": "list", "title": "Open ports", "mode": "list", "run": "run"}, {"name": "tick", "title": "Tick", "mode": "no-view", "run": "run", "hidden": true}]}"#.utf8)
            .write(to: folder.appending(path: Extension.manifestName))
        try Data("#!/bin/sh\n".utf8).write(to: folder.appending(path: "run"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appending(path: "run").path)

        let listed = await rows("extensions")
        #expect(listed.count == 1 && listed.first?["id"] == .string("ports") && listed.first?["version"] == .string("1.0.0"))
        #expect(listed.first?["commands"] == .array([.object(["name": .string("list"), "title": .string("Open ports"), "mode": .string("list"),
                                                             "action": .string("ext.ports.list")])]), "a hidden command is no row")
        #expect(await answer("add", ["extensions", "--id", "x"]).error == ControlError(.badValue, "extensions is read-only"))
    }
}

/// No web app runs: a rebuild never waits on a quit.
private struct NothingRunning: RunningWebApps {
    func isRunning(_ bundleID: String) -> Bool { false }
    func quit(_ bundleID: String) {}
}
