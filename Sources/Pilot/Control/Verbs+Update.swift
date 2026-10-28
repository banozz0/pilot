import Foundation
import PilotCore

extension ControlVerbs {
    /// `update`: Hyper+Space › Update. The list reads what is outdated; Update all, one row and Unpin each ask Allow with
    /// the exact command, which stands in for the menu's confirm, then run in the visible terminal.
    func registerUpdate(_ jobs: ControlJobs) {
        let subcommands = ["list", "all", "<key>", "unpin <key>"]
        register(ControlVerb("update", help: "What is outdated (apps, command-line tools, macOS), and Update all, one row or Unpin after Allow, as the menu's Update does (Mac › Update & Clean opens it too).",
                             usage: "pilot update [list] | update all | update <key> | update unpin <key>", flags: [],
                             schema: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             index: { .object(["subcommands": .array(subcommands.map(JSONValue.string))]) },
                             detail: { word in
                                 switch word {
                                 case "list": "pilot update list: every outdated row the menu shows, each with its key, from → to and whether Update all takes it; reads brew, uv, softwareupdate, mas, npm, bun and cargo (up to 2 min)"
                                 case "all": "pilot update all: asks Allow with the command, then upgrades every row Update all takes in a terminal window; answers the run's report"
                                 case "unpin": "pilot update unpin <key>: asks Allow with brew unpin, then runs it in a terminal window; the next list offers the formula to update"
                                 default: nil
                                 }
                             }) { call throws(ControlError) in
            let args = call.arguments()
            switch args.positional.first ?? "list" {
            case "list":
                let rows = try await Self.readUpdates(jobs)
                return Self.updateList(rows, includeSelfUpdating: jobs.includeSelfUpdating())
            case "all": return try await Self.updateAll(jobs, peer: call.peer)
            case "unpin": return try await Self.unpin(try args.word(1, "row key; pilot update list lists them"), jobs, peer: call.peer)
            case let key: return try await Self.updateOne(key, jobs, peer: call.peer)
            }
        })
    }

    /// Reads Update's rows through the menu's check (joined while it runs, kept while fresh) and keeps them for the picks that follow.
    private static func readUpdates(_ jobs: ControlJobs) async throws(ControlError) -> [UpdateRow] {
        guard let rows = await jobs.readUpdates() else { throw ControlError(.notReady, "Homebrew's outdated list could not be read; ask again to retry") }
        jobs.updates = (rows, .now)
        return rows
    }

    /// The rows the last list read while fresh, as the menu's picks act on the rows it shows; else read now.
    private static func shownUpdates(_ jobs: ControlJobs) async throws(ControlError) -> [UpdateRow] {
        let rows: [UpdateRow]
        if let kept = jobs.updates, Date.now.timeIntervalSince(kept.at) < ControlJobs.keepUpdates { rows = kept.rows } else { rows = try await readUpdates(jobs) }
        return UpdateList.visible(rows, includeSelfUpdating: jobs.includeSelfUpdating())
    }

    private static func updateList(_ rows: [UpdateRow], includeSelfUpdating: Bool) -> JSONValue {
        let shown = UpdateList.visible(rows, includeSelfUpdating: includeSelfUpdating)
        let going = UpdateList.allRows(shown, includeSelfUpdating: includeSelfUpdating), all = Set(going.map(\.item.key))
        return .object([
            "rows": .array(shown.map { r in
                let restarts = if case .macOS(_, _, true) = r.item { true } else { false }
                return .object(["key": .string(r.item.key), "name": .string(r.item.name), "category": .string(r.category.rawValue),
                                "kind": .string(r.item.kindLabel(home: NSHomeDirectory())), "from": .string(r.from), "to": .string(r.to),
                                "pinned": .bool(r.pinned), "selfUpdating": .bool(r.selfUpdating), "restartsMac": .bool(restarts),
                                "inUpdateAll": .bool(all.contains(r.item.key))])
            }),
            "updateAll": UpdateList.command(going, includeSelfUpdating: includeSelfUpdating).map(JSONValue.string) ?? .null,
            "summary": UpdateList.summary(shown, includeSelfUpdating: includeSelfUpdating).map(JSONValue.string) ?? .null,
            "includeSelfUpdating": .bool(includeSelfUpdating),
            "leftOut": .number(Double(rows.count - shown.count)),
        ])
    }

    private static func updateAll(_ jobs: ControlJobs, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let shown = try await shownUpdates(jobs), include = jobs.includeSelfUpdating()
        let going = UpdateList.allRows(shown, includeSelfUpdating: include)
        guard let command = UpdateList.command(going, includeSelfUpdating: include) else {
            return .object(["ran": .null, "report": .null,
                            "note": .string(shown.isEmpty ? "Everything is up to date" : "Only macOS updates or pinned formulae left; pick each one")])
        }
        return try await runUpdate("Update all", command, going, jobs, peer: peer)
    }

    /// Asks with the exact command, then runs it in the terminal with its report; the rows it updates leave the kept list.
    private static func runUpdate(_ title: String, _ command: String, _ rows: [UpdateRow], _ jobs: ControlJobs,
                                  peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let report = RunReport.update(title, command: command, rows: rows)
        return try await jobs.gate.allow(ControlGate.Ask(title, command), peer: peer) { () throws(ControlError) in
            let going = Set(rows.map(\.item.key))
            jobs.updates?.rows.removeAll { going.contains($0.item.key) }
            jobs.dropUpdates()
            jobs.terminal(command, "Update", "true", report)
            return Self.started(command, report: report.id, in: jobs.store)
        }
    }

    private static func updateOne(_ key: String, _ jobs: ControlJobs, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let row = try await updateRow(key, jobs)
        guard UpdateList.unpin(row) == nil, let command = UpdateList.command([row], includeSelfUpdating: true) else {
            throw ControlError(.badValue, "\(row.item.name) is pinned, so it is not updated; pilot update unpin \(key) asks to unpin it")
        }
        return try await runUpdate("Update \(row.item.name)", command, [row], jobs, peer: peer)
    }

    private static func unpin(_ key: String, _ jobs: ControlJobs, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let row = try await updateRow(key, jobs)
        guard let command = UpdateList.unpin(row) else { throw ControlError(.badValue, "\(row.item.name) is not a pinned formula; pilot update \(key) updates it") }
        return try await jobs.gate.allow(ControlGate.Ask("Unpin \(row.item.name)", command), peer: peer) { () throws(ControlError) in
            // Unpinned, the row is one to update: the next list reads it so.
            jobs.updates = nil
            jobs.dropUpdates()
            jobs.terminal(command, "Unpin", "true", nil)
            return .object(["ran": .string(command), "note": .string("runs in a terminal window; the next pilot update list offers \(row.item.name) to update")])
        }
    }

    /// The shown row `key` names, or bad-value naming the list.
    private static func updateRow(_ key: String, _ jobs: ControlJobs) async throws(ControlError) -> UpdateRow {
        guard let row = try await shownUpdates(jobs).first(where: { $0.item.key == key }) else {
            throw ControlError(.badValue, "nothing outdated has the key \(key); pilot update list lists them")
        }
        return row
    }
}
