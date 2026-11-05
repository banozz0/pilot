import Foundation
import PilotCore

/// `pilot ext act <id> <action>` (P30): one of an extension page's block actions, pressed as on its page: a button, a
/// row's click or its inline and ⋯ actions, a link, a move of a row (⌥↑ ⌥↓), an input box's Return (--input, --alt for
/// Option+Return), with the answer to what it asks (--answer). It asks the page once, as `ext page` does, then performs
/// the action and asks the page again; the answer is what it did and the blocks after. Its command runs as the page's
/// do, the HUD left out (its line comes back instead); an open, copy, paste, Pilot action, timer or alert is answered,
/// never performed, as `ext run` answers them.
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
            parts.append("sends \(min(text.count, ExtensionAI.longest)) characters of its page to \(ControlVerbs.destination(AISettings.shared))")
            if case .run(let name, _) = then.kind { parts.append("then \(runs(name, view: false)) with the answer") }
        case .open, .copy, .paste, .hud, .pilot, .timer, .alert: return nil
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
            let next = await ExtensionAI.ask(task, text, then: then, runner: AISettings.shared.runner())
            var out = try await perform(next, ext, tools, inputs)
            out["askedAI"] = .bool(true)
            return out
        case .push(let name, let context):
            guard let command = ext.view(name) else {
                return ["note": .string("not performed: it opens a page of its own (\(name)); pilot ext open \(ext.id) shows the page")]
            }
            var out: [String: JSONValue] = ["showed": .string(command.actionID)]
            switch await ExtensionRun.list(command, query: "", context: context, inputs: inputs) {
            case .items(let items): out["items"] = .array(items.map(Self.item))
            case .detail(let detail): out["detail"] = Self.detail(detail)
            case .error(let why): throw tools.failed(command, why, in: ext)
            }
            return out
        case .open, .copy, .paste, .hud, .pilot, .timer, .alert:
            return ["note": .string("not performed: it opens, copies, pastes or shows something, or runs a Pilot action, outside the extension; its page performs it")]
        }
    }
}
