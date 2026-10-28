import Foundation
import PilotCore

extension ControlVerbs {
    /// The verbs about the socket itself: `ping`, `version`, `help` and `schema`.
    func registerCore() {
        register(ControlVerb("ping", help: "Answers pong while Pilot runs.", flags: []) { _ in .string("pong") })
        register(ControlVerb("version", help: "Pilot's version and build.", flags: []) { _ in
            .object(["version": .string(GeneralPage.shortVersion),
                     "build": .string(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev")])
        })
        register(ControlVerb("help", help: "Lists every verb, or says how to use one; list, add and remove take a collection too.",
                             usage: "pilot help [<verb> [<collection>]]", flags: []) { [unowned self] call throws(ControlError) in
            guard let name = call.words.first else {
                return .string((ControlVerb.columns(sorted.map { ($0.name, $0.help) })
                                + ["pilot [--json] <verb> …: --json, before the verb, prints the answer as one JSON line"]).joined(separator: "\n"))
            }
            let verb = try verb(name)
            if let word = call.words.dropFirst().first, let detail = try verb.detail?(word) { return .string(detail) }
            return .string(([verb.usage, verb.help] + ControlVerb.columns((verb.flags ?? []).map { ($0.name, $0.help) }, prefix: "  --"))
                .joined(separator: "\n"))
        })
        register(ControlVerb("schema", help: "Every verb, with its flags, keys, collections and pages, as JSON; --index, --verb or --collection reads less.",
                             usage: "pilot schema [--index | --verb <verb> | --collection <name>]",
                             flags: [.init("index", help: "each verb's name, help, usage and flags, with a short summary of its part", takesValue: false),
                                     .init("verb", help: "one verb's entry, flags and part included"),
                                     .init("collection", help: "one collection's fields, row key and the edits that ask Allow")]) { [unowned self] call throws(ControlError) in
            let args = call.arguments()
            guard args.flags.count <= 1 else { throw ControlError(.badRequest, "pilot schema takes one of --index, --verb, --collection") }
            if args.has("index") { return schemaIndex }
            if args.has("verb") { return try schema(verb: try args.required("verb")) }
            if args.has("collection") { return try schema(collection: try args.required("collection")) }
            return schema
        })
    }
}
