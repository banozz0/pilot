import Foundation
import PilotCore
import WebApps

extension ControlVerbs {
    /// `webapp`: the rest of Install › Web apps (CLI W16) beside the webapps collection. Ideas lists the recommended
    /// sites with whether one is made; rebuild gives one or every web app Pilot's newest build, as Rebuild and Rebuild
    /// all do, after Allow, since it quits a running one and replaces its binary.
    func registerWebApps(_ s: AppCollectionStores) {
        let subcommands = ["ideas", "rebuild <name|bundle>", "rebuild all"]
        register(ControlVerb("webapp", help: "Install › Web apps: the recommended sites and whether each is made, and Rebuild or Rebuild all after Allow.",
                             usage: "pilot webapp ideas | webapp rebuild <name|bundle|all>", flags: [],
                             schema: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "ideas": "pilot webapp ideas: the sites the page recommends, each with its link and whether a web app Pilot built opens it; pilot add webapps --url <link> makes one"
                                 case "rebuild": "pilot webapp rebuild <name|bundle|all>: asks Allow, quits each one that is running, then rebuilds it with Pilot's newest web app; answers each outcome and the web apps read back"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            switch args.positional.first {
            case "ideas":
                let hosts = Set(WebAppDirectory.list(in: s.webApps).compactMap { $0.url.host() })
                return .array(WebAppIdea.all.map { idea in
                    .object(["id": .string(idea.id), "name": .string(idea.name), "link": .string(idea.link), "host": .string(idea.host),
                             "made": .bool(idea.isMade(hosts: hosts))])
                })
            case "rebuild": return try await Self.rebuild(try args.word(1, "web app's name or bundle id, or all"), s, peer: call.peer)
            case let other?: throw ControlError(.badValue, "no webapp \(other); there are ideas and rebuild")
            case nil: throw ControlError(.badRequest, "say ideas or rebuild")
            }
        })
    }

    private static func rebuild(_ word: String, _ s: AppCollectionStores, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        func targets() -> [InstalledWebApp] {
            let apps = WebAppDirectory.list(in: s.webApps)
            return word == "all" ? apps : apps.filter { $0.name == word || $0.bundleID == word }
        }
        let going = targets()
        guard !going.isEmpty else {
            let apps = WebAppDirectory.list(in: s.webApps)
            throw ControlError(.badValue, "no web app \(word); there are \(apps.isEmpty ? "none" : apps.map(\.name).joined(separator: ", "))")
        }
        // Read again once Allow is pressed: a web app added or gone meanwhile denies.
        return try await s.gate.allow(rebuildAsk(targets()), peer: peer) { () throws(ControlError) in
            let outcomes = await s.rebuild(going)
            return .object(["rebuilt": .array(outcomes.map { o in
                var row: [String: JSONValue] = ["name": .string(o.name), "rebuilt": .bool(o.failure == nil)]
                row["failure"] = o.failure.map(JSONValue.string)
                return .object(row)
            }), "webapps": .array(WebAppDirectory.list(in: s.webApps).map { .object(row($0)) })])
        }
    }

    /// Every name while the question fits; else how many.
    private static func rebuildAsk(_ apps: [InstalledWebApp]) -> ControlGate.Ask {
        let what = "quits each one running, then rebuilds it with Pilot's newest web app"
        let named = ControlGate.Ask("Rebuild web app", "\(apps.map(\.name).joined(separator: ", ")): \(what)")
        return named.text.count <= ControlGate.Ask.longest ? named : ControlGate.Ask("Rebuild web app", "all \(apps.count) web apps: \(what)")
    }
}
