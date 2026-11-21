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
            let inputs = try await tools.inputs(ext, command)
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
                // A Raycast command's input is its first argument (T11).
                let ran = if command.runtime == .raycast, let input { await ExtensionRun.list(command, query: query ?? "", input: input, inputs: inputs) }
                    else { await ExtensionRun.list(command, query: query ?? "", inputs: inputs) }
                switch ran {
                case .items(let items): answer["items"] = .array(items.map(Self.item))
                case .empty(let empty): (answer["items"], answer["empty"]) = (.array([]), Self.empty(empty))
                case .detail(let detail): answer["detail"] = Self.detail(detail)
                case .form(let form): answer["form"] = Self.form(form)
                case .error(let why): throw tools.failed(command, why, in: ext)
                }
            }
            return .object(answer)
        }
    }

    /// `ext page <id>`: asks the extension's page command once after Allow, as its page does, and answers
    /// the blocks the page would show.
    static func pageExtension(_ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let ext = try await tools.require(try args.word(1, "id"))
        if ext.page == nil, ext.isRaycast { return try await livePage(ext, args, tools, peer: peer) }
        guard let page = ext.page else { throw ControlError(.badValue, "\(ext.id) declares no page; pilot ext show \(ext.id) says what it has") }
        return try await tools.readBack(ext, page.command, ["for its page"], peer: peer) { () throws(ControlError) in
            switch await ExtensionRun.surface(page, inputs: try await tools.inputs(ext, page.command)) {
            case .blocks(let blocks, let refresh):
                var answer: [String: JSONValue] = ["page": .string(ext.id), "command": .string(page.command.actionID), "blocks": .array(blocks.map(Self.block))]
                answer["refresh"] = refresh.map { .number(Double($0)) }
                return .object(answer)
            case .error(let why): throw tools.failed(page.command, why, in: ext)
            case .bar: throw ControlError(.badValue, "\(ext.title) \(ExtensionRun.unreadable)")
            }
        }
    }

    /// `ext page <raycast id> [--command <name>] [--query <text>] [--press <row> [--action <label>] [--then <row>]] [--reopen]` (T30): the
    /// Raycast extension's page as it runs live, through the page's own model (ExtensionLivePageModel): its rows once
    /// they settle; `--query` typed into its search; `--press` selects that row and presses Return, or with `--action`
    /// opens Cmd+K and presses that action, after its own Allow; `--reopen` leaves the page and shows it again (its host
    /// stopped and started afresh). The page then goes away, its host with it.
    @MainActor static func livePage(_ ext: Extension, _ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        guard let model = ExtensionLivePageModel(ext, storage: tools.storage) else {
            let others = ExtensionLivePageModel.elsewhere(of: ext).map(\.actionID)
            return .object(["page": .string(ext.id), "live": .bool(false), "offers": .string("Open in Hyper+Space"),
                            "commands": .array(others.map(JSONValue.string))])
        }
        if let name = args.value("command") {
            guard let picked = ExtensionLivePageModel.commands(of: ext).first(where: { $0.name == name }) else {
                throw ControlError(.badValue, "\(ext.title) has no view \(name) a page runs; pilot ext show \(ext.id) lists its commands")
            }
            await model.choose(picked)
        }
        let press = args.value("press"), action = args.value("action")
        let reading = press.map { ["to press \(ControlGate.Ask.visible($0)) on it; the press asks again"] } ?? []
        return try await tools.readBack(ext, model.command, reading, peer: peer) { () throws(ControlError) in
            defer { model.stop() }
            await model.start()
            if let problem = model.problem { throw ControlError(.badValue, problem) }
            var answer: [String: JSONValue] = ["page": .string(ext.id), "live": .bool(true), "command": .string(model.command.actionID),
                                               "shown": await Self.settledPage(model)]
            if let query = args.value("query") {
                model.query = query
                answer["typed"] = await Self.settledPage(model, after: true)
            }
            if let press {
                guard let index = model.nav.rows.firstIndex(where: { $0.title == press }) else {
                    throw ControlError(.badValue, "no row \(press) on \(ext.title)'s page; its rows are under shown")
                }
                // The action a press would run: Return's, or the Cmd+K one named. Raycast's typed ones (open, copy,
                // paste) are Pilot's to perform on a press on screen, so they are answered, never performed, as ext act's.
                let row = model.nav.rows[index]
                let at = action.map { label in row.ownActions?.firstIndex(of: label) } ?? 0
                guard let at, let pressed = model.action(at, for: row) else {
                    throw ControlError(.badValue, "\(press) offers no action \(action ?? "for Return"); it offers: \(row.ownActions?.joined(separator: ", ") ?? "none")")
                }
                guard pressed.handler != nil else {
                    answer["pressed"] = .object(["row": .string(press), "action": Self.action(pressed),
                                                 "note": .string("answered, not performed: Pilot performs it on a press on screen")])
                    return .object(answer)
                }
                let then = args.value("then")
                let ask = ControlGate.Ask("Press on \(ControlGate.Ask.visible(ext.title))",
                                          "presses \(ControlGate.Ask.visible(press))\(action.map { " › \(ControlGate.Ask.visible($0))" } ?? "")\(then.map { ", then \(ControlGate.Ask.visible($0))" } ?? "") on its page, running its callbacks in pilot-ext-host")
                try await tools.gate.allow(ask, peer: peer) { () throws(ControlError) in
                    model.nav.point(at: index)
                    if action != nil {
                        // Through Cmd+K's list, as a press on screen goes.
                        _ = model.handle(.commandK)
                        guard let shown = model.nav.actions?.visible.firstIndex(where: { $0.title == action }) else {
                            throw ControlError(.badValue, "Cmd+K on \(press) lists no \(action ?? "")")
                        }
                        model.clickAction(shown)
                    } else {
                        _ = model.handle(.return)
                    }
                    log.notice("ext page: \(ext.id, privacy: .public) pressed on its live page, from the pilot command")
                    answer["pressed"] = await Self.settledPage(model, after: true)
                    // A second Return in the view the first left (an alert's Confirm), under the same Allow; a callback only.
                    guard let then else { return }
                    guard let next = model.nav.rows.firstIndex(where: { $0.title == then }) else {
                        throw ControlError(.badValue, "no row \(then) after the press; its rows are under pressed")
                    }
                    guard model.action(0, for: model.nav.rows[next])?.handler != nil else {
                        throw ControlError(.badRequest, "--then presses a callback; \(then)'s Return is one Pilot performs on screen")
                    }
                    model.nav.point(at: next)
                    _ = model.handle(.return)
                    answer["then"] = await Self.settledPage(model, after: true)
                }
            }
            if args.has("reopen") {
                model.stop()
                await model.start()
                answer["reopened"] = await Self.settledPage(model)
            }
            return .object(answer)
        }
    }

    /// The live page once it settles: its host's newest view drawn and nothing new for 400 ms (`after`: a change was just
    /// made, so it waits for one more draw first), up to 8 s.
    @MainActor private static func settledPage(_ model: ExtensionLivePageModel, after: Bool = false) async -> JSONValue {
        func loading() -> Bool { model.nav.rows.first?.title.hasSuffix(" is loading…") == true }
        let until = ContinuousClock.now + .seconds(8)
        var last = model.nav.rows, quiet = ContinuousClock.now, changed = !after
        while ContinuousClock.now < until {
            try? await Task.sleep(for: .milliseconds(50))
            if model.nav.rows != last || model.nav.emptyView != nil && last.isEmpty { last = model.nav.rows; quiet = .now; changed = true }
            if changed, !loading(), !last.isEmpty || model.nav.emptyView != nil, ContinuousClock.now - quiet >= .milliseconds(400) { break }
        }
        var o: [String: JSONValue] = ["query": .string(model.nav.query), "depth": .number(Double(model.depth)),
                                      "rows": .array(model.nav.rows.map { row in
                                          var r: [String: JSONValue] = ["title": .string(row.title)]
                                          r["subtitle"] = row.subtitle.map(JSONValue.string)
                                          r["section"] = row.section.map(JSONValue.string)
                                          r["sectionSubtitle"] = row.sectionSubtitle.map(JSONValue.string)
                                          r["actions"] = row.ownActions.map { .array($0.map(JSONValue.string)) }
                                          r["accessories"] = row.accessories.map { .array($0.map(Self.accessory)) }
                                          r["sideDetail"] = row.sideDetail.map(Self.pageDetail)
                                          return .object(r)
                                      })]
        if let title = model.nav.title { o["title"] = .string(title) }
        if let empty = model.nav.emptyView { o["empty"] = Self.empty(empty) }
        if let detail = model.nav.shownDetail { o["detail"] = Self.pageDetail(detail) }
        // What Raycast draws around the view (T31), as the page and Hyper+Space draw it.
        if let chrome = model.nav.chrome {
            var c: [String: JSONValue] = ["placeholder": .string(MenuModel.placeholder(model.nav)),
                                          "foot": .string(chrome.title ?? model.nav.title ?? model.command.title)]
            if chrome.showsDetail { c["showsDetail"] = .bool(true) }
            o["chrome"] = .object(c)
        }
        return .object(o)
    }

    /// A Raycast accessory in words (T31): its text or tag, its colour and what its icon is.
    static func accessory(_ one: Extension.Item.Accessory) -> JSONValue {
        var o: [String: JSONValue] = [:]
        o["text"] = one.text.map(JSONValue.string)
        if one.tag { o["tag"] = .bool(true) }
        o["color"] = one.color.map(JSONValue.string)
        o["icon"] = picture(one.picture)
        return .object(o)
    }

    /// A Raycast icon as words: its symbol and tint, "picture" for bytes, its emoji, or "file <path>".
    static func picture(_ p: Extension.Picture) -> JSONValue? {
        if let symbol = p.symbol { return .string(symbol + (p.tint.map { " (\($0))" } ?? "")) }
        if let image = p.image { return .string("picture \(image.count) B") }
        if let emoji = p.emoji { return .string(emoji) }
        return p.file.map { .string("file " + $0) }
    }

    /// A detail as the page draws it (T31): its markdown's first 200 characters, an image named by its alt, and its
    /// metadata parts in order.
    static func pageDetail(_ detail: Extension.Detail) -> JSONValue {
        var o: [String: JSONValue] = ["markdown": .string(String(detail.markdown.prefix(200)))]
        let images = DetailBlock.split(detail.markdown).compactMap { if case .image(let alt, let source) = $0 { "\(alt) (\(source.prefix(22))…)" } else { nil } }
        if !images.isEmpty { o["images"] = .array(images.map(JSONValue.string)) }
        o["parts"] = detail.parts.isEmpty ? nil : .array(detail.parts.map { part in
            var p: [String: JSONValue] = ["kind": .string(part.kind.rawValue)]
            if !part.title.isEmpty { p["title"] = .string(part.title) }
            p["text"] = part.text.map(JSONValue.string)
            p["icon"] = picture(part.picture)
            if !part.tags.isEmpty { p["tags"] = .array(part.tags.map { .string(($0.text ?? "") + ($0.color.map { " (\($0))" } ?? "")) }) }
            p["target"] = part.target.map(JSONValue.string)
            return .object(p)
        })
        return .object(o)
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
        case .invoke(let handler): o["handler"] = .string(handler)
        }
        return .object(o)
    }

    /// A Raycast list's empty view (T26), as `ext run` and `ext act` show it beside no rows.
    static func empty(_ empty: Extension.Empty) -> JSONValue {
        var out: [String: JSONValue] = ["title": .string(empty.title)]
        out["description"] = empty.description.map(JSONValue.string)
        out["symbol"] = empty.symbol.map(JSONValue.string)
        out["icon"] = empty.icon.map(JSONValue.string)
        if !empty.actions.isEmpty { out["actions"] = .array(empty.actions.map(Self.action)) }
        return .object(out)
    }

    static func item(_ item: Extension.Item) -> JSONValue {
        var o: [String: JSONValue] = ["title": .string(item.title), "actions": .array(item.actions.map(action))]
        o["id"] = item.id.map(JSONValue.string)
        o["subtitle"] = item.subtitle.map(JSONValue.string)
        o["icon"] = item.icon.map(JSONValue.string)
        // T5 (coordinator's yes, 2026-11-19): the row's SF Symbol, and its picture as its size and hash, never its bytes.
        o["symbol"] = item.symbol.map(JSONValue.string)
        o["image"] = item.image.map { .string("\($0.count) B, sha256 \(ExtensionCatalogue.sha256($0).prefix(12))") }
        if !item.badges.isEmpty { o["badges"] = .array(item.badges.map { .string($0.text) }) }
        o["section"] = item.section.map(JSONValue.string)
        o["accessory"] = item.accessory.map { .string($0.text) }
        return .object(o)
    }

    static func detail(_ detail: Extension.Detail) -> JSONValue {
        .object(["markdown": .string(detail.markdown), "actions": .array(detail.actions.map(action)),
                 "metadata": .array(detail.metadata.map { .object(["label": .string($0.label), "text": .string($0.text)]) })])
    }

    /// A Raycast Form (T10): each field as Pilot draws it, its value and error, and the form's actions.
    static func form(_ form: Extension.Form) -> JSONValue {
        func field(_ f: Extension.Form.Field) -> JSONValue {
            var o: [String: JSONValue] = ["kind": .string(f.kind.rawValue)]
            for (key, word) in [("id", f.id), ("title", f.title), ("placeholder", f.placeholder), ("error", f.error), ("info", f.info),
                                ("label", f.label), ("text", f.text), ("change", f.change), ("blur", f.blur)] { o[key] = word.map(JSONValue.string) }
            if f.kind != .description, f.kind != .separator { o["value"] = f.value ?? .null }
            // "Levels/High = high": its section, title and value.
            if let options = f.options { o["options"] = .array(options.map { .string(($0.section.map { "\($0)/" } ?? "") + "\($0.title) = \($0.value)") }) }
            if f.kind == .date { o["time"] = .bool(f.time ?? true) }
            return .object(o)
        }
        return .object(["fields": .array(form.fields.map(field)), "actions": .array(form.actions.map(action))])
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
            guard !readsBackPasswords else { return }
            let set = await shown(ext).passwordsSet
            guard set.isEmpty else {
                throw ControlError(.denied, "\(ext.id) has a password preference set (\(set.sorted().joined(separator: ", "))), so what it prints is not read back: it may hold the password. pilot run <action> runs it; its page shows on screen (pilot ext open \(ext.id))")
            }
        }
        try await noPassword()
        let base = Self.run(command, of: ext)
        let answer = try await gate.allow(ControlGate.Ask(base.title, ([base.detail] + extra).joined(separator: ", ")), peer: peer) { () throws(ControlError) in
            try await noPassword()
            return try await body()
        }
        log.notice("ext: \(command.actionID, privacy: .public) read back, from the pilot command")
        return answer
    }

    /// The question running `command` of `ext` asks: the run's own (with a keyword's input), else, for a command no
    /// action id names (a page's, a hidden one), its title and program.
    static func run(_ command: Extension.Command, of ext: Extension) -> ControlGate.Ask {
        if Extension.command(inAction: command.actionID, in: [ext]) != nil, let ask = ControlGate.Ask.run(command.actionID, extensions: [ext]) { return ask }
        return ControlGate.Ask("Run extension command \(ControlGate.Ask.visible(ext.title)) › \(ControlGate.Ask.visible(command.title))",
                               command.program.path(percentEncoded: false))
    }

    /// A run that failed: the extension's own error message as it said it, but a failed exit (whose reason is the program's
    /// stderr, which can hold anything) as a fixed line, the reason in the log only, as Hyper+Space does.
    func failed(_ command: Extension.Command, _ why: String, in ext: Extension? = nil) -> ControlError {
        if let ext, why.hasPrefix("says:") || why == ExtensionRun.unreadable || why.hasPrefix("sent no") || why.hasPrefix("did not answer")
            || why.hasPrefix("used more than") {
            return ControlError(why.hasPrefix("did not answer") ? .timeout : .badValue, "\(ext.title) \(why)")
        }
        log.error("ext: \(command.actionID, privacy: .public) failed: \(why, privacy: .private)")
        return ControlError(.badValue, "\(command.actionID) stopped with an error; Pilot's log says why")
    }

    /// What a run of `command` is handed, as Hyper+Space hands it, or bad-value saying the preference to set first.
    func inputs(_ ext: Extension, _ command: Extension.Command) async throws(ControlError) -> ExtensionRun.Inputs {
        var why: String?
        guard let inputs = await ExtensionsModule.inputs(for: ext, command: command, storage: storage, hud: { why = $0 }) else {
            throw ControlError(.badValue, (why ?? "\(ext.title) did not start") + " pilot list ext-prefs shows what is missing.")
        }
        return inputs
    }
}
