import Foundation
import PilotCore
import Synchronization

/// `pilot ext act <id> <action>` (P30): one of an extension page's block actions, pressed as on its page: a button, a
/// row's click or its inline and ⋯ actions, a link, a move of a row (⌥↑ ⌥↓), an input box's Return (--input, --alt for
/// Option+Return), with the answer to what it asks (--answer). It asks the page once, as `ext page` does, then performs
/// the action and asks the page again; the answer is what it did and the blocks after. Its command runs as the page's
/// do, the HUD left out (its line comes back instead); an open, copy, paste, Pilot action, timer or alert is answered,
/// never performed, as `ext run` answers them. A Raycast-format extension (ADR 0017) has no page: `ext act` presses a
/// callback of one of its view's rows instead (actView, T2), and fills and submits a Form (fill, T10).
extension ControlVerbs {
    /// One action a page offers: its name as `ext act` takes it ("Refresh", "Milk/Remove"), the action, and the input box
    /// it belongs to (nil for any other block), with whether it is that box's Option+Return, and whether it is a row's or a
    /// link's name alone, pressing its first action.
    struct PageTarget {
        let path: String, action: Extension.Item.Action, box: Extension.Block.Input?, alt: Bool
        var bare = false
    }

    /// Every action in `blocks`, in the order `ext page` lists them: a row's or a link's name alone is its first action.
    static func targets(_ blocks: [Extension.Block]) -> [PageTarget] {
        blocks.flatMap { block -> [PageTarget] in
            switch block {
            case .buttons(let actions): return actions.map { PageTarget(path: $0.label, action: $0, box: nil, alt: false) }
            case .list(_, let items, let reorder):
                return items.enumerated().flatMap { index, item -> [PageTarget] in
                    var rows = item.actions.first.map { [PageTarget(path: item.title, action: $0, box: nil, alt: false, bare: true)] } ?? []
                    rows += item.actions.map { PageTarget(path: "\(item.title)/\($0.label)", action: $0, box: nil, alt: false) }
                    if let reorder, let id = item.id {
                        if index > 0 { rows.append(PageTarget(path: "\(item.title)/Move up", action: reorder.action(key: id, to: index - 1), box: nil, alt: false)) }
                        if index < items.count - 1 {
                            rows.append(PageTarget(path: "\(item.title)/Move down", action: reorder.action(key: id, to: index + 1), box: nil, alt: false))
                        }
                    }
                    return rows
                }
            case .links(let links):
                return links.flatMap { link -> [PageTarget] in
                    let name = link.title ?? link.icon ?? "link"
                    return [PageTarget(path: name, action: link.actions[0], box: nil, alt: false, bare: true)]
                        + link.actions.map { PageTarget(path: "\(name)/\($0.label)", action: $0, box: nil, alt: false) }
                }
            case .input(let box):
                return ([box.action] + box.actions).map { PageTarget(path: $0.label, action: $0, box: box, alt: false) }
                    + (box.alt.map { [PageTarget(path: $0.label, action: $0, box: box, alt: true)] } ?? [])
            case .section(_, _, _, _, let inner, _, _): return targets(inner)
            case .stats, .meter, .markdown, .chat, .hero, .note, .strip: return []
            }
        }
    }

    /// The target `word` names: its whole name, else its action's title alone, only when one target has it; bad-value lists
    /// the names otherwise. Never a number: the Allow question shows the word, which must say what is pressed.
    static func target(_ word: String, in targets: [PageTarget], page id: String) throws(ControlError) -> PageTarget {
        let lower = word.lowercased()
        var hits = targets.filter { $0.path.lowercased() == lower }
        if hits.isEmpty { hits = targets.filter { $0.action.label.lowercased() == lower } }
        // A row's name alone and its first action are the same press: the whole name ("Milk/Edit") is kept.
        hits = hits.filter { hit in !hits.contains { $0.path.count > hit.path.count && $0.action == hit.action && $0.alt == hit.alt } }
        let names = targets.map(\.path)
        let listed = names.prefix(30).joined(separator: "\n") + (names.count > 30 ? "\n…" : "")
        switch hits.count {
        case 1: return hits[0]
        case 0: throw ControlError(.badValue, targets.isEmpty ? "\(id)'s page offers no action" : "no action \(word) on \(id)'s page; it offers:\n\(listed)")
        default: throw ControlError(.badValue, "\(word) names \(hits.count) actions on \(id)'s page; say one by its whole name:\n"
                                    + hits.map(\.path).joined(separator: "\n"))
        }
    }

    /// The action as it runs: an input box's with the typed text, Option+Return's with --alt, the answer to what it asks.
    static func pressed(_ target: PageTarget, _ args: ControlArguments) throws(ControlError) -> Extension.Item.Action {
        let typed = args.value("input"), answer = args.value("answer")
        if let box = target.box {
            guard answer == nil else { throw ControlError(.badRequest, "\(target.path) is an input box's: its text goes in --input") }
            guard let typed else { throw ControlError(.badRequest, "\(target.path) runs with the box's text: say --input <text>") }
            let alt = args.has("alt") || target.alt, submits = target.alt || target.action == box.action
            if alt, box.alt == nil { throw ControlError(.badValue, "this box has no Option+Return action") }
            if alt, !submits { throw ControlError(.badRequest, "--alt is the box's Option+Return; \(target.path) is an action of its own") }
            let action = submits ? box.submit(typed, alt: alt) : target.action.answering(typed)
            guard let action else { throw ControlError(.badValue, "--input is blank, so nothing runs") }
            return action
        }
        guard typed == nil, !args.has("alt") else {
            throw ControlError(.badRequest, "--input and --alt are an input box's; \(target.path) is not one\(target.action.ask == nil ? "" : ", and asks: answer with --answer")")
        }
        switch target.action.ask {
        case nil:
            guard answer == nil else { throw ControlError(.badRequest, "\(target.path) asks nothing, so it takes no --answer") }
            return target.action
        case .text(let start)?:
            guard let answer else { throw ControlError(.badRequest, "\(target.path) asks for text (it starts as \(start)): say --answer <text>") }
            guard let done = target.action.answering(answer) else { throw ControlError(.badValue, "--answer is blank, so nothing runs") }
            return done
        case .choices(let choices)?:
            let listed = choices.map(\.title).joined(separator: ", ")
            guard let answer else { throw ControlError(.badRequest, "\(target.path) asks for one of: \(listed); say --answer <choice>") }
            guard let choice = choices.first(where: { $0.title.lowercased() == answer.lowercased() || $0.value == answer }) else {
                throw ControlError(.badValue, "no choice \(answer); it offers \(listed)")
            }
            return target.action.answered(choice.value)
        case .confirm(let question)?:
            guard ["yes", "y"].contains(answer?.lowercased()) else { throw ControlError(.badRequest, "\(target.path) asks: \(question); --answer yes runs it") }
            return target.action.answered(nil)
        }
    }

    /// `ext act <id> <action> [--input <text>] [--answer <text>] [--alt]`.
    static func actExtension(_ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let ext = try await tools.require(try args.word(1, "id"))
        if ext.page == nil, ext.commands.contains(where: { $0.runtime == .raycast }) { return try await actView(ext, args, tools, peer: peer) }
        guard let page = ext.page else { throw ControlError(.badValue, "\(ext.id) declares no page; pilot ext show \(ext.id) says what it has") }
        let word = try args.word(2, "action, by its name as pilot ext page \(ext.id) shows it (a button, a row, row/action)")
        // The first Allow reads the page; the press asks its own, built from what the page answered, naming what runs.
        let reading = ["to find \(ControlGate.Ask.visible(word)) on it; the press asks again"]
        return try await tools.readBack(ext, page.command, reading, peer: peer) { () throws(ControlError) in
            let inputs = try await tools.inputs(ext)
            let before = try await Self.blocks(of: page, ext, tools, inputs)
            let target = try Self.target(word, in: Self.targets(before), page: ext.id)
            let action = try Self.pressed(target, args)
            return try await tools.gate.allow(Self.press(target, action, ext, alt: target.alt || args.has("alt")), peer: peer) { () throws(ControlError) in
                var answer: [String: JSONValue] = ["page": .string(ext.id), "pressed": .string(target.path), "action": Self.action(action)]
                answer.merge(try await Self.perform(action, ext, tools, inputs)) { $1 }
                log.notice("ext act: \(ext.id, privacy: .public) pressed an action, from the pilot command")
                answer["blocks"] = .array(try await Self.blocks(of: page, ext, tools, inputs).map(Self.block))
                return .object(answer)
            }
        }
    }

    /// `ext act <id> <row> [--command <name>]` or `ext act <id> --handler <id>` (T2): a Raycast-format view's row callback,
    /// or on a Form `ext act <id> [<action>] --type <field>=<text> --submit [<json values>]` (T10, fill below),
    /// pressed in a host started for it and kept open until the answer after the press, then closed. The first Allow
    /// reads the view; the press asks its own. Its answer: the rows before the press and after it. `--then <row>` (T8)
    /// presses again in the same host, in the view the first press left (a pushed one), `escape` going back a view; the
    /// one Allow names both presses, and the answer adds the rows between them.
    static func actView(_ ext: Extension, _ args: ControlArguments, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        let named = args.value("command")
        guard let command = (named.map(ext.view) ?? ext.commands.first { $0.mode != .noView }), command.runtime == .raycast else {
            throw ControlError(.badValue, "\(ext.title) has no view \(named ?? "") to press in; pilot ext show \(ext.id) lists its commands")
        }
        let handler = args.value("handler"), filling = args.has("submit") || args.value("type") != nil
        // A fill names an action only to press one other than its form's SubmitForm.
        let word: String? = if let handler { handler } else if filling { args.positional.count > 2 ? args.positional[2] : nil }
            else { try args.word(2, "row, by its title as pilot ext run \(command.actionID) shows it (or row/action), or --handler <id>") }
        let reading = ["to find \(word.map(ControlGate.Ask.visible) ?? "its form") in it; the press asks again"]
        return try await tools.readBack(ext, command, reading, peer: peer) { () throws(ControlError) in
            let inputs = try await tools.inputs(ext)
            let session = ExtensionSession(command, context: nil, inputs: inputs, folder: ext.folder)
            let answer: Result<JSONValue, ControlError>
            do throws(ControlError) { answer = .success(try await Self.press(word, handler: handler, then: args.value("then"), fill: filling ? args : nil, in: session, command, ext, tools, peer: peer)) }
            catch { answer = .failure(error) }
            session.close()
            await session.ended()
            return try answer.get()
        }
    }

    /// Opens the view in `session`, finds the callback (a row's first, row/action, or the handler named), asks Allow for
    /// the press and presses it; with `fill`'s arguments, fills its form (fill).
    private static func press(_ word: String?, handler: String?, then: String?, fill: ControlArguments?, in session: ExtensionSession,
                              _ command: Extension.Command, _ ext: Extension, _ tools: ExtensionTools, peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        func shown(_ outcome: ListOutcome) throws(ControlError) -> (items: [Extension.Item], json: [String: JSONValue]) {
            let json = try Self.outcome(outcome, command, ext, tools)
            switch outcome {
            case .items(let items): return (items, json)
            case .detail(let detail): return (ExtensionList.items(detail, of: command), json)
            case .form(let form): return ([Extension.Item(title: command.title, actions: form.actions)], json)
            case .error: return ([], json)
            }
        }
        /// A press by its handler id, or the callback a row's name finds in `items`.
        func pressing(_ id: String, path: String) -> PageTarget {
            PageTarget(path: path, action: Extension.Item.Action(kind: .invoke(handler: id)), box: nil, alt: false)
        }
        func find(_ word: String, in items: [Extension.Item]) throws(ControlError) -> PageTarget {
            try Self.target(word, in: Self.targets([.list(title: nil, items: items)]).filter { $0.action.handler != nil }, page: command.actionID)
        }
        _ = try shown(await session.ask(""))
        let first = await session.settled()?.outcome ?? .error("sent no list")
        let before = try shown(first)
        if let fill {
            guard let form = first.form else { throw ControlError(.badValue, "--type and --submit fill a form; \(command.actionID) shows none") }
            let named = try word.map { name throws(ControlError) in try find(name, in: before.items).action }
            return try await Self.fill(form, pressing: named, fill, before: before.json, in: session, command, ext, tools, peer: peer)
        }
        let target = if let handler { pressing(handler, path: "handler \(handler)") } else { try find(word ?? "", in: before.items) }
        let id = target.action.handler ?? word ?? ""
        let label = target.bare ? " (\(ControlGate.Ask.visible(target.action.label)))" : ""
        let escape = then?.lowercased() == "escape"
        let second = then.map { ", then \(escape ? "Escape (back a view)" : ControlGate.Ask.visible($0)), runs their callbacks" } ?? ", runs its callback"
        let ask = ControlGate.Ask("Press on \(ControlGate.Ask.visible(ext.title))",
                                  "presses \(ControlGate.Ask.visible(target.path))\(label)\(second) in pilot-ext-host")
        return try await tools.gate.allow(ask, peer: peer) { () throws(ControlError) in
            var after = try shown(await session.invoke(id))
            var answer: [String: JSONValue] = ["command": .string(command.actionID), "pressed": .string(target.path), "action": Self.action(target.action),
                                               "before": .object(before.json)]
            if let then {
                // The second press is found in the view the first left; escape is the host's own back (T8).
                let next = escape ? pressing(ExtensionListSession.pop, path: "Escape") : try find(then, in: after.items)
                answer["between"] = .object(after.json)
                answer["then"] = .string(next.path)
                after = try shown(await session.invoke(next.action.handler ?? ExtensionListSession.pop))
            }
            log.notice("ext act: \(ext.id, privacy: .public) pressed a callback, from the pilot command")
            answer.merge(after.json) { $1 }
            if session.newest?.loading == true { answer["loading"] = .bool(true) }
            return .object(answer)
        }
    }

    /// How long a fill waits after its last edit for echoes still coming (a controlled field's that comes later).
    static let echoQuiet: Duration = .milliseconds(300)

    /// Fills the open Form and submits it (T10): `--type <field>=<text>` types the text one change per character, sent
    /// without waiting between them as keystrokes come, then leaves the field; `--submit [<json>]` sets each field the
    /// object names (text, true or false, a date as yyyy-mm-dd or ISO 8601, a list of paths), leaving each, then presses
    /// the SubmitForm (or the action named). One Allow names all of it. The answer: the form before, what each line the
    /// host sent while typing showed and any stale echo it ignored, the form filled, and the view after the submit, which
    /// is still the form with `submitted: false` while a field shows an error (Raycast does not submit then).
    private static func fill(_ form: Extension.Form, pressing named: Extension.Item.Action?, _ args: ControlArguments, before: [String: JSONValue],
                             in session: ExtensionSession, _ command: Extension.Command, _ ext: Extension, _ tools: ExtensionTools,
                             peer: ControlPeer?) async throws(ControlError) -> JSONValue {
        func editable(_ id: String) throws(ControlError) -> Extension.Form.Field {
            guard let field = form.field(id), field.change != nil else {
                let ids = form.fields.compactMap(\.id).joined(separator: ", ")
                throw ControlError(.badValue, "\(ControlGate.Ask.visible(ext.title))'s form has no field \(ControlGate.Ask.visible(id)); it has \(ids.isEmpty ? "none" : ControlGate.Ask.visible(ids))")
            }
            return field
        }
        // --type <field>=<text>: a text field's, text area's or password's.
        var typing: (field: Extension.Form.Field, text: String)?
        if let typed = args.value("type") {
            guard let equals = typed.firstIndex(of: "=") else { throw ControlError(.badRequest, "--type is <field>=<text>") }
            let field = try editable(String(typed[..<equals]))
            guard [.text, .password, .textarea].contains(field.kind) else { throw ControlError(.badValue, "--type types into a text field; \(field.id ?? "") is a \(field.kind.rawValue)") }
            typing = (field, String(typed[typed.index(after: equals)...]))
        }
        // --submit's values, each held to its field's kind.
        var sets: [(field: Extension.Form.Field, value: JSONValue)] = []
        if let given = args.value("submit"), !given.isEmpty {
            guard case .object(let values)? = try? JSONDecoder().decode(JSONValue.self, from: Data(given.utf8)) else {
                throw ControlError(.badRequest, "--submit takes the fields' values as a JSON object, {\"<id>\": <value>, …}")
            }
            for (id, value) in values.sorted(by: { $0.key < $1.key }) {
                let field = try editable(id)
                sets.append((field, try Self.formValue(value, for: field)))
            }
        }
        let submits = args.has("submit")
        let action = submits ? named ?? form.submit : nil
        if submits, action?.handler == nil { throw ControlError(.badValue, "\(ControlGate.Ask.visible(ext.title))'s form has no action to submit it") }
        let name = { (field: Extension.Form.Field) in ControlGate.Ask.visible(field.title ?? field.id ?? "a field") }
        var parts: [String] = []
        if let typing { parts.append("types \(typing.text.count) characters into \(name(typing.field))") }
        if !sets.isEmpty { parts.append("sets \(sets.map { name($0.field) }.joined(separator: ", "))") }
        if let action { parts.append("presses \(ControlGate.Ask.visible(action.label))") }
        let ask = ControlGate.Ask("Fill the form on \(ControlGate.Ask.visible(ext.title))", parts.joined(separator: ", then ") + ", runs their callbacks in pilot-ext-host")
        return try await tools.gate.allow(ask, peer: peer) { () throws(ControlError) in
            var answer: [String: JSONValue] = ["command": .string(command.actionID), "before": .object(before)]
            if let typing, let id = typing.field.id, let handler = typing.field.change {
                // Every line the host sends while typing, as the field shows it and as the host said it when that was stale.
                let seen = Mutex<[JSONValue]>([])
                session.watch {
                    guard let view = session.newest, case .form(let now) = view.outcome else { return }
                    var line: [String: JSONValue] = ["shows": now.field(id)?.value ?? .null]
                    if let said = view.stale[id] { line["ignored"] = said }
                    seen.withLock { $0.append(.object(line)) }
                }
                let keys = typing.text.indices.map { JSONValue.string(String(typing.text[...$0])) }
                _ = await session.edit(id, handler: handler, values: keys)
                if let blur = typing.field.blur { _ = await session.invoke(blur) }
                try? await Task.sleep(for: Self.echoQuiet)
                session.watch { }
                answer["typed"] = .object(["field": .string(id), "sent": .number(Double(keys.count)), "lines": .array(seen.withLock { $0 }),
                                           "shows": session.newest?.outcome.form?.field(id)?.value ?? .null])
            }
            for (field, value) in sets {
                guard let id = field.id, let handler = field.change else { continue }
                _ = await session.edit(id, handler: handler, values: [value])
                if let blur = field.blur { _ = await session.invoke(blur) }
            }
            if !sets.isEmpty { try? await Task.sleep(for: Self.echoQuiet) }
            guard let filled = session.newest?.outcome else { throw ControlError(.badValue, "\(command.actionID) stopped while filling") }
            answer["filled"] = .object(try Self.outcome(filled, command, ext, tools))
            if let action, let handler = action.handler {
                let after = await session.invoke(handler)
                answer["pressed"] = .string(action.label)
                answer["after"] = .object(try Self.outcome(after, command, ext, tools))
                if case .form(let still) = after, let shown = still.fields.first(where: { $0.error != nil }) {
                    answer["submitted"] = .bool(false)
                    answer["blocked"] = .string("\(shown.title ?? shown.id ?? "a field") shows an error: \(shown.error ?? "")")
                } else {
                    answer["submitted"] = .bool(true)
                }
            }
            log.notice("ext act: \(ext.id, privacy: .public) filled a form, from the pilot command")
            return .object(answer)
        }
    }

    /// A Raycast view as `ext act` shows it: its rows, its detail or its form; its error is thrown.
    private static func outcome(_ outcome: ListOutcome, _ command: Extension.Command, _ ext: Extension, _ tools: ExtensionTools) throws(ControlError) -> [String: JSONValue] {
        switch outcome {
        case .items(let items): return ["items": .array(items.map(Self.item))]
        case .detail(let detail): return ["detail": Self.detail(detail)]
        case .form(let form): return ["form": Self.form(form)]
        case .error(let why): throw tools.failed(command, why, in: ext)
        }
    }

    /// `value` as `field` takes it on the wire: text, true or false, a dropdown's option by its value, a date at local
    /// midnight (yyyy-mm-dd) or as ISO 8601 (null clears it), a file pick's paths.
    static func formValue(_ value: JSONValue, for field: Extension.Form.Field) throws(ControlError) -> JSONValue {
        let name = ControlGate.Ask.visible(field.id ?? "")
        switch (field.kind, value) {
        case (.text, .string), (.password, .string), (.textarea, .string), (.checkbox, .bool): return value
        case (.dropdown, .string(let pick)):
            guard field.options?.contains(where: { $0.value == pick }) == true else {
                throw ControlError(.badValue, "\(name) has no option \(ControlGate.Ask.visible(pick)); it offers \(ControlGate.Ask.visible((field.options ?? []).map(\.value).joined(separator: ", ")))")
            }
            return value
        case (.date, .null): return value
        case (.date, .string(let text)):
            guard let date = Extension.Form.date(text) else {
                throw ControlError(.badValue, "\(name) takes a date as yyyy-mm-dd or ISO 8601, not \(ControlGate.Ask.visible(text))")
            }
            return .string(Extension.Form.wireDate(date))
        case (.file, .array(let paths)) where paths.allSatisfy({ $0.string != nil }): return value
        default: throw ControlError(.badValue, "\(name) is a \(field.kind.rawValue) field: \(Self.expected(field.kind))")
        }
    }

    private static func expected(_ kind: Extension.Form.Field.Kind) -> String {
        switch kind {
        case .checkbox: "true or false"
        case .date: "a date as yyyy-mm-dd or ISO 8601, or null"
        case .file: "a list of paths"
        default: "text"
        }
    }

    /// The press's question: the extension and the action's whole name, and everything that runs or leaves: the command
    /// with its program, the text it is handed, the question it asked and its answer, and for an AI ask how much of the
    /// page goes to which provider before its command runs. Nil for a press that is answered, not performed.
    static func press(_ target: PageTarget, _ action: Extension.Item.Action, _ ext: Extension, alt: Bool) -> ControlGate.Ask? {
        func runs(_ name: String, view: Bool) -> String {
            guard let command = view ? ext.view(name) : ext.noView(name) else {
                return "runs \(ControlGate.Ask.visible(name)), which \(ControlGate.Ask.visible(ext.title)) does not have"
            }
            return "runs \(ControlGate.Ask.visible(command.title)) (\(command.program.path(percentEncoded: false)))"
        }
        // A row's or a link's name alone presses its first action: the action is named too.
        let label = target.bare ? " (\(ControlGate.Ask.visible(target.action.label)))" : ""
        var parts = ["presses \(ControlGate.Ask.visible(target.path))\(label)\(alt ? " as Option+Return" : "")"]
        switch action.kind {
        case .run(let name, _): parts.append(runs(name, view: false))
        case .push(let name, _): parts.append(runs(name, view: true))
        case .ai(_, let text, let then):
            parts.append("sends \(min(text.count, ExtensionAI.longest)) characters of its page to \(ControlVerbs.destinations(AISettings.shared))")
            if case .run(let name, _) = then.kind { parts.append("then \(runs(name, view: false)) with the answer") }
        case .open, .copy, .paste, .hud, .pilot, .timer, .alert, .invoke: return nil
        }
        if let input = action.input { parts.append("with the text \(ControlGate.Ask.visible(input))") }
        switch target.action.ask {
        case .confirm(let question)?: parts.append("answering yes to \(ControlGate.Ask.visible(question))")
        case .text?, .choices?, nil: break
        }
        return ControlGate.Ask("Press on \(ControlGate.Ask.visible(ext.title))'s page", parts.joined(separator: ", "))
    }

    private static func blocks(of page: Extension.Surface, _ ext: Extension, _ tools: ExtensionTools,
                               _ inputs: ExtensionRun.Inputs) async throws(ControlError) -> [Extension.Block] {
        switch await ExtensionRun.surface(page, inputs: inputs) {
        case .blocks(let blocks, _): return blocks
        case .error(let why): throw tools.failed(page.command, why, in: ext)
        case .bar: throw ControlError(.badValue, "\(ext.title) \(ExtensionRun.unreadable)")
        }
    }

    /// The press itself: a run of one of its no-view commands, an AI ask handed to its run, or a push to a list or detail
    /// read back; anything else is answered, not performed.
    private static func perform(_ action: Extension.Item.Action, _ ext: Extension, _ tools: ExtensionTools,
                                _ inputs: ExtensionRun.Inputs) async throws(ControlError) -> [String: JSONValue] {
        switch action.kind {
        case .run(let name, let context):
            guard let command = ext.noView(name) else { throw ControlError(.badValue, "\(ext.title) has no command \(name) to run") }
            let input = action.input
            var out: [String: JSONValue] = ["ran": .string(command.actionID)]
            switch await Task.detached(operation: { await ExtensionRun.noView(command, context: context, input: input, inputs: inputs) }).value {
            case .hud(let line, _): out["shows"] = .string(line ?? "\(command.title) ran")
            case .error(let message): out["error"] = .string("\(ext.title) says: \(message)")
            case .actions(let actions, _):
                out["actions"] = .array(actions.map(Self.action))
                out["note"] = .string("its actions are not performed: its page or pilot run \(command.actionID) performs them")
            case .timedOut: throw ControlError(.timeout, "\(command.actionID) \(Self.late(ExtensionRun.noViewTimeout))")
            case .failed(let why): throw tools.failed(command, why)
            }
            return out
        case .ai(let task, let text, let then):
            // The provider is the AI page's; only the size is logged, never the text.
            log.notice("ext act: \(ext.id, privacy: .public) asks AI about \(text.utf8.count) bytes")
            let heard = AIFallback.Heard()
            let next = await ExtensionAI.ask(task, text, then: then, runner: AISettings.shared.runner(told: heard.tell), heard: heard)
            var out = try await perform(next, ext, tools, inputs)
            out["askedAI"] = .bool(true)
            if let notice = heard.notice { out["notice"] = .string(notice.line) }
            return out
        case .push(let name, let context):
            guard let command = ext.view(name) else {
                return ["note": .string("not performed: it opens a page of its own (\(name)); pilot ext open \(ext.id) shows the page")]
            }
            var out: [String: JSONValue] = ["showed": .string(command.actionID)]
            switch await ExtensionRun.list(command, query: "", context: context, inputs: inputs) {
            case .items(let items): out["items"] = .array(items.map(Self.item))
            case .detail(let detail): out["detail"] = Self.detail(detail)
            case .form(let form): out["form"] = Self.form(form)
            case .error(let why): throw tools.failed(command, why, in: ext)
            }
            return out
        case .invoke:
            return ["note": .string("not performed: a callback is pressed in its open view (pilot ext act \(ext.id) <row>)")]
        case .open, .copy, .paste, .hud, .pilot, .timer, .alert:
            return ["note": .string("not performed: it opens, copies, pastes or shows something, or runs a Pilot action, outside the extension; its page performs it")]
        }
    }
}
