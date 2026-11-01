import Foundation
import PilotCore

/// `pilot ext show|broken|run|page|open` (CLI W15): an extension's Extensions detail read back, the folders the page lists as
/// not read, a command's or a page's answer, and the page or card opened. A run and a page ask Allow (they run the
/// extension's program as Sven) and read nothing back while a password preference is set, since the program is handed it.
extension ControlVerbs {
    /// `ext show <id>`: what the card shows, preference values left to list ext-prefs.
    static func showExtension(_ args: ControlArguments, _ tools: ExtensionTools) async throws(ControlError) -> JSONValue {
        let ext = try await tools.require(try args.word(1, "id"))
        let shown = await tools.shown(ext)
        var o: [String: JSONValue] = [
            "id": .string(ext.id), "title": .string(ext.title), "folder": .string(ext.folder.path),
            "description": .string(ext.description), "examples": .array(ext.examples.map(JSONValue.string)),
            "touches": .array(ExtensionsPage.permissions(ext.permissions, label: tools.label).map { .string($0.text) }),
            "touchesNote": .string(ExtensionsPage.notEnforced),
            "commands": .array(ext.listed.map { c in
                var row: [String: JSONValue] = ["action": .string(c.actionID), "name": .string(c.name), "title": .string(c.title),
                                                "mode": .string(c.mode.rawValue), "does": .string(c.mode.help)]
                row["keyword"] = c.keyword.map(JSONValue.string)
                return .object(row)
            }),
            "preferences": .array(ext.preferences.map { .string($0.name) }),
            "needs": .array(ext.preferences.filter { ExtensionTools.PrefRow($0, of: ext, shown).missing }.map { .string($0.name) }),
            "page": .bool(ext.page != nil), "barItem": .bool(ext.bar != nil),
            "next": .string("pilot list ext-prefs for its preference values; pilot ext open \(ext.id)"),
        ]
        o["icon"] = ext.icon.map(JSONValue.string)
        o["version"] = ext.version.map(JSONValue.string)
        return .object(o)
    }

    /// `ext broken`: the folders in Extensions that do not read as extensions, each with why (the page's Folders not read).
    static func brokenExtensions(_ tools: ExtensionTools) async -> JSONValue {
        .array(await tools.found().broken.map { .object(["folder": .string($0.folder), "why": .string($0.problem.reason)]) })
    }

    /// `ext open <id> [--card]`: its own page when it declares one, else (or with --card) the Extensions page on its card.
    static func openExtension(_ args: ControlArguments, _ tools: ExtensionTools) async throws(ControlError) -> JSONValue {
        let ext = try await tools.require(try args.word(1, "id"))
        let page = ext.page != nil && !args.has("card")
        tools.open(ext.id, page)
        return .object(["opened": .string(ext.id), "on": .string(page ? "page" : "card")])
    }

    /// `ext run <action> [--query <text>] [--input <text>]`: runs the command once after Allow, as Hyper+Space would, and
    /// answers what Pilot would show: a no-view command's line or actions (none performed: pilot run performs them), a
    /// list's items or a detail.
    static func runExtension(_ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let action = try args.word(1, "action, e.g. ext.<id>.<command>")
        guard let (ext, command) = Extension.command(inAction: action, in: await tools.found().extensions) else {
            throw ControlError(.unknownAction, "no extension command \(action); pilot ext show <id> lists its commands")
        }
        let (query, input) = (args.value("query"), args.value("input") ?? Extension.input(inAction: action))
        let extra = [query.map { "search \(ControlGate.Ask.visible($0))" }, input.map { "input \(ControlGate.Ask.visible($0))" }].compactMap { $0 }
        return try await tools.readBack(ext, command, extra, peer: peer) { () throws(ControlError) in
            let inputs = try await tools.inputs(ext)
            var answer: [String: JSONValue] = ["ran": .string(command.actionID), "mode": .string(command.mode.rawValue)]
            if command.mode == .noView {
                switch await Task.detached(operation: { await ExtensionRun.noView(command, input: input, inputs: inputs) }).value {
                case .hud(let line, _): answer["shows"] = .string(line ?? "\(command.title) ran")
                case .error(let message): throw ControlError(.badValue, "\(ext.title) says: \(message)")
                case .actions(let actions, let dropped):
                    answer["actions"] = .array(actions.map(Self.action))
                    answer["note"] = .string("not performed\(dropped > 0 ? "; \(dropped) past \(ExtensionRun.mostActions) dropped" : ""): pilot run \(command.actionID) performs them")
                case .timedOut: throw ControlError(.timeout, "\(command.actionID) \(Self.late(ExtensionRun.noViewTimeout))")
                case .failed(let why): throw tools.failed(command, why)
                }
            } else {
                switch await ExtensionRun.list(command, query: query ?? "", inputs: inputs) {
                case .items(let items): answer["items"] = .array(items.map(Self.item))
                case .detail(let detail): answer["detail"] = Self.detail(detail)
                case .error(let why): throw tools.failed(command, why, in: ext)
                }
            }
            return .object(answer)
        }
    }

    /// `ext page <id>`: asks the extension's page command once after Allow, as its page and its Home block do, and answers
    /// the blocks the page would show.
    static func pageExtension(_ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let ext = try await tools.require(try args.word(1, "id"))
        guard let page = ext.page else { throw ControlError(.badValue, "\(ext.id) declares no page; pilot ext show \(ext.id) says what it has") }
        return try await tools.readBack(ext, page.command, ["for its page"], peer: peer) { () throws(ControlError) in
            switch await ExtensionRun.surface(page, inputs: try await tools.inputs(ext)) {
            case .blocks(let blocks, let refresh):
                var answer: [String: JSONValue] = ["page": .string(ext.id), "command": .string(page.command.actionID), "blocks": .array(blocks.map(Self.block))]
                answer["refresh"] = refresh.map { .number(Double($0)) }
                return .object(answer)
            case .error(let why): throw tools.failed(page.command, why, in: ext)
            case .bar: throw ControlError(.badValue, "\(ext.title) \(ExtensionRun.unreadable)")
            }
        }
    }

    static func late(_ timeout: Duration) -> String { "did not answer in \(String(format: "%g", timeout.inSeconds)) s" }

    // MARK: What an extension answered, as JSON

    /// An action in words: what it does and to what.
    static func action(_ action: Extension.Item.Action) -> JSONValue {
        var o: [String: JSONValue] = ["does": .string(action.label)]
        o["title"] = action.title.map(JSONValue.string)
        o["key"] = action.key.map { .string($0.symbol) }
        if action.stay { o["stays"] = .bool(true) }
        switch action.kind {
        case .open(let target): o["target"] = .string(target)
        case .copy(let text), .paste(let text), .hud(let text, _): o["text"] = .string(text)
        case .push(let command, _), .run(let command, _): o["command"] = .string(command)
        case .pilot(let id): o["action"] = .string(id)
        case .timer(let timer): o["text"] = .string(timer.title)
        case .alert(let alert): o["text"] = .string(alert.text)
        case .ai(let task, _, _): o["text"] = .string(task)
        }
        return .object(o)
    }

    static func item(_ item: Extension.Item) -> JSONValue {
        var o: [String: JSONValue] = ["title": .string(item.title), "actions": .array(item.actions.map(action))]
        o["id"] = item.id.map(JSONValue.string)
        o["subtitle"] = item.subtitle.map(JSONValue.string)
        o["icon"] = item.icon.map(JSONValue.string)
        if !item.badges.isEmpty { o["badges"] = .array(item.badges.map { .string($0.text) }) }
        o["section"] = item.section.map(JSONValue.string)
        o["accessory"] = item.accessory.map { .string($0.text) }
        return .object(o)
    }

    static func detail(_ detail: Extension.Detail) -> JSONValue {
        .object(["markdown": .string(detail.markdown), "actions": .array(detail.actions.map(action)),
                 "metadata": .array(detail.metadata.map { .object(["label": .string($0.label), "text": .string($0.text)]) })])
    }

    static func stat(_ stat: Extension.Block.Stat) -> JSONValue {
        .object(["label": .string(stat.label), "value": .string(stat.value), "tone": stat.tone.map { .string($0.rawValue) }].compactMapValues { $0 })
    }

    static func block(_ block: Extension.Block) -> JSONValue {
        func some(_ fields: [String: JSONValue?]) -> JSONValue { .object(fields.compactMapValues { $0 }) }
        func text(_ s: String?) -> JSONValue? { s.map(JSONValue.string) }
        switch block {
        case .stats(let stats):
            return some(["type": .string("stats"), "stats": .array(stats.map(stat))])
        case .meter(let m):
            return some(["type": .string("meter"), "label": .string(m.label), "percent": .number(m.percent), "note": text(m.note), "value": text(m.value),
                         "tone": text(m.tone?.rawValue), "resetsAt": text(m.resetsAt?.ISO8601Format()), "help": text(m.help)])
        case .list(let title, let items, let reorder):
            return some(["type": .string("list"), "title": text(title), "items": .array(items.map(item)), "reorder": reorder.map { .object(["command": .string($0.command)]) }])
        case .markdown(let markdown): return .object(["type": .string("markdown"), "text": .string(markdown)])
        case .buttons(let actions): return .object(["type": .string("buttons"), "actions": .array(actions.map(action))])
        case .section(let title, let subtitle, let aside, let asideNote, let blocks, let icon, let help):
            return some(["type": .string("section"), "title": text(title), "subtitle": text(subtitle), "aside": text(aside), "asideNote": text(asideNote),
                         "icon": text(icon?.rawValue), "help": text(help), "blocks": .array(blocks.map(Self.block))])
        case .chat(let chat):
            return .object(["type": .string("chat"), "working": .bool(chat.working),
                            "messages": .array(chat.shown.map { .object(["role": .string($0.role.rawValue), "text": .string($0.text)]) })])
        case .input(let input):
            return some(["type": .string("input"), "placeholder": text(input.placeholder), "action": action(input.action),
                         "live": input.live.map { .number(($0 / .milliseconds(1)).rounded()) },
                         "actions": input.actions.isEmpty ? nil : .array(input.actions.map(action)),
                         "files": input.files.map { .array($0.map(JSONValue.string)) }])
        case .hero(let hero):
            return some(["type": .string("hero"), "glyph": text(hero.glyph), "value": .string(hero.value), "unit": text(hero.unit), "place": text(hero.place),
                         "tone": text(hero.tone?.rawValue),
                         "stats": .array(hero.stats.map(stat))])
        case .note(let note):
            return some(["type": .string("note"), "text": .string(note.text), "aside": text(note.aside), "help": text(note.help), "icon": text(note.icon)])
        case .links(let links):
            return .object(["type": .string("links"), "items": .array(links.map {
                some(["title": text($0.title), "icon": text($0.icon), "tone": text($0.tone?.rawValue), "word": text($0.word), "help": text($0.help),
                      "actions": .array($0.actions.map(action))])
            })])
        case .strip(let columns):
            return .object(["type": .string("strip"), "columns": .array(columns.map {
                some(["label": .string($0.label), "glyph": text($0.glyph), "high": text($0.high), "low": text($0.low)])
            })])
        }
    }
}

extension ExtensionTools {
    /// Runs `body` after Allow on running `command` of `ext` (the run's question, `extra` added), unless one of `ext`'s
    /// password preferences is set: its program is handed the password, so what it prints may hold it, and nothing is
    /// read back or asked (as pilot run withholds an extension's tips, RunReadback.withheld).
    func readBack(_ ext: Extension, _ command: Extension.Command, _ extra: [String], peer: ControlPeer?,
                  _ body: @MainActor () async throws(ControlError) -> JSONValue) async throws(ControlError) -> JSONValue {
        // Asked before the question and again after Allow, so a password set while it was up still withholds.
        func noPassword() async throws(ControlError) {
            let set = await shown(ext).passwordsSet
            guard set.isEmpty else {
                throw ControlError(.denied, "\(ext.id) has a password preference set (\(set.sorted().joined(separator: ", "))), so what it prints is not read back: it may hold the password. pilot run <action> runs it; its page shows on screen (pilot ext open \(ext.id))")
            }
        }
        try await noPassword()
        let base = ControlGate.Ask.run(command.actionID, extensions: [ext]) ?? ControlGate.Ask("Run extension command", command.actionID)
        let answer = try await gate.allow(ControlGate.Ask(base.title, ([base.detail] + extra).joined(separator: ", ")), peer: peer) { () throws(ControlError) in
            try await noPassword()
            return try await body()
        }
        log.notice("ext: \(command.actionID, privacy: .public) read back, from the pilot command")
        return answer
    }

    /// A run that failed: the extension's own error message as it said it, but a failed exit (whose reason is the program's
    /// stderr, which can hold anything) as a fixed line, the reason in the log only, as Hyper+Space does.
    func failed(_ command: Extension.Command, _ why: String, in ext: Extension? = nil) -> ControlError {
        if let ext, why.hasPrefix("says:") || why == ExtensionRun.unreadable || why.hasPrefix("sent no") || why.hasPrefix("did not answer") {
            return ControlError(why.hasPrefix("did not answer") ? .timeout : .badValue, "\(ext.title) \(why)")
        }
        log.error("ext: \(command.actionID, privacy: .public) failed: \(why, privacy: .private)")
        return ControlError(.badValue, "\(command.actionID) stopped with an error; Pilot's log says why")
    }

    /// What a run of `ext` is handed, as Hyper+Space hands it, or bad-value saying the preference to set first.
    func inputs(_ ext: Extension) async throws(ControlError) -> ExtensionRun.Inputs {
        var why: String?
        guard let inputs = await ExtensionsModule.inputs(for: ext, storage: storage, hud: { why = $0 }) else {
            throw ControlError(.badValue, (why ?? "\(ext.title) did not start") + " pilot list ext-prefs shows what is missing.")
        }
        return inputs
    }
}
