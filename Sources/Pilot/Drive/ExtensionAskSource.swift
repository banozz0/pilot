import AppKit
import PilotCore

/// A run's ask in Hyper+Space (To-do B, ADR 0010 amended 2026-10-17): a view pushed over the list, as a row's or button
/// row's ask is asked in its place on a page. A text ask puts its text in the search to edit and lists one row, Return
/// saving what is typed; choices list as rows the search filters; a confirm lists its question and Cancel. Escape goes
/// back to the list with nothing run. The answer runs as the action would: with the panel open and the list asked again
/// when it stays, else once the panel closes.
@MainActor
final class ExtensionAskSource: MenuSource {
    var show: ([MenuEntry]) -> Void = { _ in }
    let ask: Extension.Item.Action.Ask, action: Extension.Item.Action, ext: Extension, inputs: ExtensionRun.Inputs
    private var typed = ""

    init(_ ask: Extension.Item.Action.Ask, action: Extension.Item.Action, in ext: Extension, inputs: ExtensionRun.Inputs) {
        self.ask = ask; self.action = action; self.ext = ext; self.inputs = inputs
    }

    var opening: String { if case .text(let text) = ask { text } else { "" } }

    /// The rows for what is typed: a text ask's one row follows it; choices and a confirm are listed once, Pilot filtering.
    func search(_ query: String) {
        typed = query
        show(Self.rows(ask, label: action.label, typed: query))
    }

    /// Each row names what Return does to it, so the foot says it.
    static func rows(_ ask: Extension.Item.Action.Ask, label: String, typed: String) -> [MenuEntry] {
        func row(_ title: String, _ id: String, answer: Bool = true, subtitle: String? = nil, does: String = label) -> MenuEntry {
            var row = MenuEntry(title: title, target: .action("ask#\(id)"), isAnswer: answer, subtitle: subtitle)
            row.ownActions = [does]
            return row
        }
        switch ask {
        case .text:
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return [row(text.isEmpty ? "Type the new text" : text, "text", subtitle: text.isEmpty ? nil : "Return: \(label)")]
        case .choices(let choices):
            return choices.indices.map { row(choices[$0].title, "\($0)", answer: false) }
        case .confirm(let question):
            return [row(question, "yes", subtitle: label), row("Cancel", "no", does: "Cancel")]
        }
    }

    func pick(_ row: MenuEntry, action index: Int) -> MenuPick {
        guard case .action(let id) = row.target, let answer = id.split(separator: "#").last else { return .stay }
        let picked: Extension.Item.Action?
        switch ask {
        case .text: picked = action.answering(typed)
        case .choices(let choices): picked = Int(answer).flatMap { choices.indices.contains($0) ? action.answered(choices[$0].value) : nil }
        case .confirm: picked = answer == "yes" ? action.answered(nil) : nil
        }
        // Cancel, or a blank text: back to the list, nothing run.
        guard let picked else { return answer == "no" ? .keep(clear: false, back: true) { nil } : .stay }
        return ExtensionActions.answered(picked, in: ext, inputs: inputs, back: true)
    }

    func close() {}
}
