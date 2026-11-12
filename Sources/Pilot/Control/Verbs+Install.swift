import Foundation
import PilotCore

extension ControlVerbs {
    /// `install`: Install's search and its Get (CLI W16). Search asks every source the page asks, answers once each has;
    /// pick acts on a catalogue entry or a search row as Return there does, with Allow standing in for the confirm step;
    /// helper installs one of General's helpers as its Install button does.
    func registerInstallVerb(_ s: ControlInstall) {
        let subcommands = ["search <text>", "pick <key>", "helper <id>", "leftovers <app> [--trash]"]
        register(ControlVerb("install", help: "Install's search over every source (the catalogue, Homebrew, the App Store, GitHub, the package tools, the web), Get on a catalogue entry or a search row, and a helper's install.",
                             usage: "pilot install search <text> | install pick <key> | install helper <id> | install leftovers <app> [--trash]",
                             flags: [.init("trash", help: "install leftovers: move the ticked ones to the Trash, after Allow", takesValue: false)],
                             schema: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "search": "pilot install search <text>: the catalogue's matches (none while Recommend apps is off), then each source's results with its key, how it installs and the command it runs, or why the source has none; waits for every source (up to about 30 s)"
                                 case "pick": "pilot install pick <key>: a key from pilot list catalogue or a search. An installed entry says so; a vendor's https page opens in the browser; a package, a GitHub release file or an install script asks Allow with its exact command, then runs it in a terminal window; a page that is not https asks first"
                                 case "leftovers": "pilot install leftovers <app>: what Remove will offer once that .app is in the Trash, read from the app where it is now, so before pilot remove: its files at the top of ~/Library's \(AppLeftovers.placeNames.joined(separator: ", ")), each with its size and ticked, but for one another installed app may share. --trash asks Allow, then moves the ticked ones to the Trash"
                                 case "helper": "pilot install helper <id>: an id from pilot list helpers. An installed helper says so; Homebrew's installer asks Allow, then runs in a terminal window, which asks for your password; the others are Homebrew formulae, refused until Homebrew is installed"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            switch args.positional.first {
            case "search": return try await Self.search(args.positional.dropFirst().joined(separator: " "), s)
            case "pick": return try await Self.pick(try args.word(1, "key; pilot list catalogue or pilot install search lists them"), s, peer: call.peer)
            case "helper": return try await Self.helper(try args.word(1, "helper id; pilot list helpers lists them"), s, peer: call.peer)
            case "leftovers":
                return try await Self.leftovers(try args.word(1, "an app's path, such as /Applications/Name.app"), trash: args.has("trash"), s, peer: call.peer)
            case let other?: throw ControlError(.badValue, "no install \(other); there are search, pick, helper and leftovers")
            case nil: throw ControlError(.badRequest, "say search, pick, helper or leftovers")
            }
        })
    }

    /// Remove's leftovers for the app at `path` (Q181), as its panel lists them; with `trash`, the ticked ones to the
    /// Trash after Allow, as Move to Trash there moves them.
    private static func leftovers(_ path: String, trash: Bool, _ s: ControlInstall, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard path.hasSuffix(".app"), let app = AppLeftovers.App.read(URL(filePath: path)) else {
            throw ControlError(.badValue, "\(path) is not an app with a bundle id")
        }
        let items = await RemoveApp.leftovers(of: app, library: s.library)
        let rows: [JSONValue] = items.map { item in
            var row: [String: JSONValue] = ["path": .string(item.id), "place": .string(item.place), "ticked": .bool(item.tickedFirst)]
            row["size"] = item.bytes.map { .number(Double($0)) }
            row["sharedWith"] = item.sharedWith.map(JSONValue.string)
            if item.logins { row["logins"] = .bool(true) }
            return .object(row)
        }
        var answer: [String: JSONValue] = ["app": .string(app.name), "bundleID": .string(app.bundleID), "leftovers": .array(rows)]
        guard trash else { return .object(answer) }
        guard RemoveApp.copies(of: URL(filePath: path), running: s.running).isEmpty else {
            throw ControlError(.badValue, "\(app.name) is open: its files are in use, so quit it first")
        }
        let model = LeftoversModel(app: app.name, items: items, trash: s.leftoversTrash)
        guard !model.chosen.isEmpty else { throw ControlError(.badValue, "nothing of \(app.name)'s is ticked to go") }
        return try await s.gate.allow(ControlGate.Ask("Remove leftovers", lines: ["\(app.name)'s, to the Trash:"] + model.chosen.map(\.shown)), peer: peer) {
            () throws(ControlError) in
            answer["said"] = .string(await model.moveToTrash())
            return .object(answer)
        }
    }

    private static func search(_ text: String, _ s: ControlInstall) async throws(ControlError) -> JSONValue {
        guard InstallSearch.Query(text) != nil else {
            throw ControlError(.badValue, "search needs \(MenuNavigator.minimumQuery) to 100 characters, not starting with -")
        }
        guard let (query, groups) = await s.search(text) else { throw ControlError(.notReady, "the search was cut short; ask again") }
        let found = CataloguePage.sections(s.entries(), query: query.text, category: nil, recommend: s.recommend()).flatMap(\.entries)
        return .object([
            "query": .string(query.text),
            "catalogue": .array(found.map { .object(row($0, installed: s.isInstalled($0))) }),
            "groups": .array(groups.map { g in
                var group: [String: JSONValue] = ["source": .string(g.source.rawValue), "title": .string(g.source.title),
                                                  "results": .array(g.results.map { r in
                    var result: [String: JSONValue] = ["key": .string(r.key), "title": .string(r.title), "via": .string(r.via),
                                                       "detail": .string(r.detail), "installed": .bool(r.installed)]
                    result["command"] = r.method.command.map(JSONValue.string)
                    return .object(result)
                })]
                group["trouble"] = g.trouble.map { .string($0.line(g.source)) }
                return .object(group)
            }),
        ])
    }

    /// Get on a catalogue entry (by key or id), else on a search row's key: what InstallModule.pick does, each step
    /// that runs a command behind Allow.
    private static func pick(_ key: String, _ s: ControlInstall, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        if let entry = s.entries().first(where: { $0.key == key || $0.id == key }) {
            if s.isInstalled(entry) { return .object(["key": .string(entry.key), "name": .string(entry.name), "installed": .bool(true)]) }
            switch entry.method {
            case .download(let page):
                guard let url = URL(string: page) else { throw ControlError(.badValue, "\(entry.name)'s page \(page) does not read") }
                return try await openPage(url, entry.key, s, peer: peer)
            case .script: return try await runAfterAllow("Install \(entry.name)", entry.method.scriptCommand!, entry.key, s, peer: peer)
            case .package(let p): return try await installPackage(p, title: "Install \(entry.name)", s, peer: peer)
            }
        }
        guard let method = InstallSearch.Method(key: key) else {
            throw ControlError(.badValue, "no catalogue entry or search result has the key \(key); pilot list catalogue or pilot install search lists them")
        }
        let title = InstallSearch.title(key)
        switch method {
        case .page(let url): return try await openPage(url, key, s, peer: peer)
        case .download(let url):
            guard let command = InstallSearch.downloadCommand(url) else { throw ControlError(.badValue, "\(url.lastPathComponent) is not a file name Install downloads") }
            return try await runAfterAllow("Install \(title ?? url.lastPathComponent)", command, key, s, peer: peer)
        case .package(let p): return try await installPackage(p, title: "Install \(title ?? p.name)", s, peer: peer)
        }
    }

    /// General's Install on a helper (InstallModule.install): Homebrew's installer after Allow, waiting for Return so its
    /// next steps are read; a formula as a package, once Homebrew is there.
    private static func helper(_ id: String, _ s: ControlInstall, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard let helper = Helper.named(id) else { throw ControlError(.badValue, "no helper \(id); pilot list helpers lists them") }
        switch helper.step(installed: s.helpers()) {
        case .installed: return .object(["id": .string(helper.id), "name": .string(helper.name), "installed": .bool(true)])
        case .needsHomebrew: throw ControlError(.notReady, "\(helper.name) installs through Homebrew; pilot install helper homebrew first")
        case .installer(let command): return try await runAfterAllow("Install \(helper.name)", command, helper.key, s, peer: peer)
        case .formula(let p): return try await installPackage(p, title: "Install \(helper.name)", s, peer: peer)
        }
    }

    /// A page opens with nothing asked when it is https, as a web link runs; any other scheme (the App Store's) asks.
    private static func openPage(_ url: URL, _ key: String, _ s: ControlInstall, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let ask = url.scheme?.lowercased() == "https" ? nil : ControlGate.Ask("Open link", url.absoluteString)
        return try await s.gate.allow(ask, peer: peer) { () throws(ControlError) in
            s.open(url)
            return .object(["key": .string(key), "opened": .string(url.absoluteString)])
        }
    }

    /// A release file or an install script: asks with the command, then runs it in the terminal, which waits for Return.
    private static func runAfterAllow(_ title: String, _ command: String, _ key: String, _ s: ControlInstall,
                                      peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        try await s.gate.allow(ControlGate.Ask(title, command), peer: peer) { () throws(ControlError) in
            s.run(command, title, VisibleRun.waitForReturn)
            return .object(["key": .string(key), "ran": .string(command), "note": .string("runs in a terminal window")])
        }
    }

    /// A package: asks as `add packages` does, then runs through Install's own step, whose success records it.
    private static func installPackage(_ p: Package, title: String, _ s: ControlInstall, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        try await s.gate.allow(.install(.package, p.install), peer: peer) { () throws(ControlError) in
            InstallModule.confirmRun(title, p.install, hook: "installed", key: p.key, confirm: ControlInstall.confirmed, run: s.run)
            return .object(["key": .string(p.key), "ran": .string(p.install),
                            "note": .string("runs in a terminal window; installed.json records it once the command ends with exit 0")])
        }
    }
}
