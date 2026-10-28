import AppKit
import PilotCore

extension ControlVerbs {
    /// `pilot bug` (P48, Sven Q296): /troubleshoot's Report it. Pilot's own bug form on GitHub (Feedback, story 136), its
    /// title, what happened and the steps filled in with this Mac's facts; Sven reads it there and presses Submit himself.
    /// Opening it asks Allow, as any link the AI opens does; `--link` only answers the link, so it opens and asks nothing.
    func registerBugReport(_ app: ControlActions) {
        register(ControlVerb("bug", help: "Opens Pilot's bug form on GitHub filled in, for the person to read and submit; --link only prints it.",
                             usage: "pilot bug <title> --what <what happened> [--steps <steps>] [--link]",
                             flags: [.init("what", help: "what happened, and what was expected"), .init("steps", help: "the steps to see it again"),
                                     .init("link", help: "print the link, open nothing", takesValue: false)]) { call throws(ControlError) in
            let args = call.arguments()
            let title = args.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw ControlError(.badRequest, "missing title") }
            let report = Feedback.Report(title: title, what: try args.required("what"), steps: args.value("steps") ?? "")
            let url = Feedback.url(.bug, facts: SendFeedback.facts(layerKeys: app.engine()?.settings.layerKeys ?? []), report: report)
            guard !args.has("link") else { return .string(url.absoluteString) }
            let crash = await app.newestCrash()
            return try await app.gate.allow(ControlGate.Ask("Open a bug report on GitHub", title), peer: call.peer) { () throws(ControlError) in
                app.openURL(url)
                let attach = crash.map { "; the person may attach the crash report \($0.name) there (pilot crash --reveal shows it)" } ?? ""
                return .string("opened Pilot's bug form on GitHub: \(title); it is sent only when Submit is pressed there" + attach)
            }
        })
    }

    /// `pilot crash` (SH12, Sven Q315): the newest of Pilot's and its helpers' crash reports from the last 7 days, by name
    /// and date, for /troubleshoot to name; `--reveal` shows it in Finder, for the person to attach to a bug report. Only
    /// the file name is read, never the report, and nothing is sent.
    func registerCrashReport(_ app: ControlActions) {
        register(ControlVerb("crash", help: "Names the newest Pilot crash report from the last 7 days; --reveal shows it in Finder. Never reads or sends it.",
                             usage: "pilot crash [--reveal]",
                             flags: [.init("reveal", help: "show the report in Finder, selected", takesValue: false)]) { call throws(ControlError) in
            let args = call.arguments()
            guard args.positional.isEmpty else { throw ControlError(.badRequest, "pilot crash takes no words; --reveal shows the report") }
            guard let crash = await app.newestCrash() else {
                return .object(["report": .null, "folder": .string(CrashReports.shownFolder),
                                "note": .string("no Pilot crash report from the last 7 days")])
            }
            let read: JSONValue = .object([
                "report": .string(crash.name), "process": .string(crash.process),
                "date": .string(crash.date.formatted(date: .long, time: .shortened)),
                "path": .string("\(CrashReports.shownFolder)/\(crash.name)"),
                "note": .string("it may hold paths from this Mac; attaching it to a bug report is the person's choice"),
            ])
            guard args.has("reveal") else { return read }
            return try await app.gate.allow(ControlGate.Ask("Show a crash report in Finder", crash.name), peer: call.peer) { () throws(ControlError) in
                app.reveal(crash.url)
                return read
            }
        })
    }
}
