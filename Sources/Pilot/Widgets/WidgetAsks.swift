import Foundation
import PilotCore

/// What a widget asks for, in the one wording every surface shows (ADR 0016): the Trust to run card on the desktop, the
/// Widgets page's Trust this widget, and the Allow questions of `pilot widget check` and `pilot add widgets`. Its
/// command names the program the runner will start, resolved as the runner resolves it, marked when it lies outside the
/// widget's folder.
///
/// Widget text can never pass for Pilot's: Pilot's own lines come first, and the command's words last, under a header
/// that counts them, each a row marked №n. An argv word is printable ASCII (widget.json refuses anything else), so it can
/// hold no № and no line break: a row starts only where Pilot marks one, however a long word wraps, and the count
/// shows any doubt. Titles and the rest are text escaping leaves unchanged. Each surface still escapes as it draws
/// (ControlGate.Ask.visible: the card and the sheet per row, the Allow prompt per line of the Ask's own `lines`).
enum WidgetAsks {
    /// Every argv word, the program first as the runner resolves it (its path in the widget's folder, "./feed.sh", or in
    /// full); `outside` when the program is none of the widget's files; `missing` when it is not there to run. Nil with
    /// no command.
    static func command(_ widget: Widget) -> (words: [String], outside: Bool, missing: Bool)? {
        guard case .command(let argv, _) = widget.data else { return nil }
        let search = Widget.environment(id: widget.id, folder: widget.folder, from: [:])["PATH"] ?? ""
        guard let program = Widget.program(argv[0], folder: widget.folder, path: search) else { return (argv, false, true) }
        let folder = widget.folder.standardizedFileURL.path + "/", path = program.standardizedFileURL.path
        let inside = path.hasPrefix(folder)
        return ([inside ? "./" + path.dropFirst(folder.count) : path] + argv.dropFirst(), !inside, false)
    }

    /// What Trust this widget gives power to: Pilot's lines (the page it loads, its sites, its readings), then the
    /// command's header and its words.
    struct Asking: Equatable {
        var lines: [String] = []
        var header: String?
        var words: [String] = []

        /// As text lines, for the Allow prompt: each word a row marked №1, №2 …, a mark no argv word can hold (printable
        /// ASCII only), so a word that wraps never starts what reads as a row.
        var text: [String] { lines + (header.map { [$0] } ?? []) + rows }

        /// The words, each a row marked №n: the one row form every question uses.
        var rows: [String] { words.enumerated().map { "    №\($0.offset + 1)  \($0.element)" } }
    }

    /// `picks`: the buttons a placement will start with (`pilot add widgets --values`), named instead of the default.
    static func asking(_ widget: Widget, picks: [String]? = nil) -> Asking {
        var asking = Asking()
        if widget.draw == .html { asking.lines.append("Loads its page (\(Widget.entryName)), which may reach any website") }
        // The sites it says it uses are shown, not enforced (Q680); hosts are checked to be plain addresses.
        asking.lines.append(widget.hosts.isEmpty ? "Sites it lists: none" : "Sites it lists: \(widget.hosts.joined(separator: ", "))")
        if case .reading(let readings) = widget.data { asking.lines.append("Readings: \(readings.map(\.rawValue).joined(separator: ", "))") }
        if case .extensionPage(let id) = widget.data {
            asking.lines.append("Shows extension \(id)'s page; its buttons do what they do on that page")
        }
        if case .notes = widget.data { asking.lines.append("Shows your notes, as Pilot draws them; a click opens one in the notes panel") }
        if widget.data == .repos { asking.lines.append("Shows your repos in ~/code with work not committed or pushed, as Pilot reads them; a click opens one") }
        if widget.data == .nowPlaying { asking.lines.append("Shows what is playing with its cover; its buttons play or pause, skip and go back") }
        if !widget.buttons.isEmpty { asking.lines.append(Widget.buttonsLine(widget.buttons)) }
        // Its list or its actions setting, never both (Widget.init), so the question has one buttons line either way.
        if let field = widget.actionsField { asking.lines.append(Widget.picksLine(picks ?? Widget.picks(field.initial))) }
        if let command = command(widget) {
            let every = if case .command(_, let every) = widget.data { Widget.every(every) } else { Widget.fewestSeconds }
            let program = command.missing ? "; its program is not an executable file in the widget's folder or on its PATH"
                : command.outside ? "; its program is outside the widget's folder" : ""
            asking.header = "Runs, as you, every \(every) s while it shows\(program), these \(command.words.count) words, each a row from №:"
            asking.words = command.words
        }
        return asking
    }

    /// Every line of it as text, the words last and numbered.
    static func lines(_ widget: Widget, picks: [String]? = nil) -> [String] { asking(widget, picks: picks).text }

    /// A line or a name from the widget's own files as a surface draws it, escaped once.
    static func shown(_ text: String) -> String { ControlGate.Ask.visible(text) }

    /// Whether pressing it can run anything, once it may: its own buttons or the ones picked in Edit widget, the
    /// Launcher's tiles, an extension page's (Q697), a note's row or a repo's.
    static func acts(_ widget: Widget) -> Bool {
        switch widget.data {
        case .extensionPage, .notes, .repos, .nowPlaying, .markets: return true
        default: return !widget.buttons.isEmpty || widget.actionsField != nil || widget.menuField != nil
        }
    }

    /// Whether placing it runs anything of its own: a command or a page, once it may.
    static func runsOnShow(_ widget: Widget) -> Bool {
        if case .command = widget.data { return true }
        return widget.draw == .html
    }
}
