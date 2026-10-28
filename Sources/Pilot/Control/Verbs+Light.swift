import PilotCore

extension ControlVerbs {
    /// `light`: a shell hook's or script's push to the Status lights item, its jobs' slots (builds, long commands) or an
    /// agent's. Pilot never runs or polls anything for it: the light stays as pushed until the next push, a done one goes
    /// out once seen or after ten minutes, a failed one once seen.
    func registerLight(_ lights: @escaping @MainActor () -> StatusLights = { .shared }) {
        let states = StatusLight.State.words.keys.sorted()
        register(ControlVerb("light", help: "Lights a job (a build, a long command) or an agent in the Status lights item, or clears it.",
                             usage: "pilot light <id> working|waiting|done|error|clear [--title <words>] [--detail <words>] [--agent] [--session <ghostex ref>]",
                             flags: [.init("title", help: "who it is, as its row names it; the id when left out"),
                                     .init("detail", help: "its context: what it does, an exit code"),
                                     .init("agent", help: "an agent's light, not a job's", takesValue: false),
                                     .init("session", help: "the Ghostex session its row opens ($GHOSTEX_GLOBAL_SESSION_REF)")]) { call throws(ControlError) in
            let args = call.arguments()
            let id = try args.word(0, "id")
            let word = try args.word(1, "state: \(states.joined(separator: ", "))")
            guard let state = StatusLight.State.words[word] else {
                throw ControlError(.badValue, "no state \(word); states: \(states.joined(separator: ", "))")
            }
            lights().push(id: id, state: state, title: args.value("title") ?? id, family: args.has("agent") ? .agent : .job,
                          detail: args.value("detail"), session: args.value("session"))
            return .object(["id": .string(id), "state": .string(word)])
        })
    }
}
