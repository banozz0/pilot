import Darwin
import Foundation

/// A desktop widget (ADR 0016): a folder of its own in `Widgets/<id>/`, apart from extensions, read from its
/// `widget.json`. It draws Pilot's blocks or its own HTML, fed by a Pilot reading, a command run every 10 s or slower,
/// or nothing. Where it came from sets its trust: made here, or trusted, has full power; anything else is locked and
/// runs no command and loads no HTML (Q676, Q680). Everything here is pure or reads files only; the app runs and draws.
public struct Widget: Equatable, Sendable {
    public static let manifestName = "widget.json", entryName = "index.html"
    /// The shortest `every` a command may ask, in seconds, and how long one run may take (Q676).
    public static let fewestSeconds = 10
    public static let timeout: Duration = .seconds(5)
    /// The gallery's limits, held by import too (Q669): a file, a widget, its files; and what one run may print.
    public static let fileLimit = 2_000_000, widgetLimit = 10_000_000, mostFiles = 200, outputLimit = 1_000_000
    /// A command's words, so its Trust question and Allow prompts show it whole: a word a row, under Pilot's own lines,
    /// within the prompt's 20 line breaks and 1,200 characters.
    /// One budget for everything a question shows of a widget's own, counted as the question shows it (escaped), so the
    /// Place, Run, Install and Import questions fit the prompt (ControlGate.Ask.mostLines, .longest) with a margin for the
    /// program's resolved path (a bare name found on the PATH grows by up to 18 characters): a command of at most 12
    /// words and 320 shown characters, and sites of 100 characters in all, leaving room for the line naming what a widget inherits under its id. Test, Install and Import also name the folder
    /// they read, outside this budget: one with a path past about 100 characters is denied unasked, with that reason.
    public static let mostWords = 12, longestCommand = 320, longestHosts = 100

    public enum Draw: String, Sendable { case blocks, html }

    /// A reading Pilot already has.
    public enum Reading: String, CaseIterable, Sendable { case cpu, memory, disk, battery, network, clock, calendar }

    /// Where its data comes from: readings (one, or a few as This Mac and the clock and calendar show), a command (argv,
    /// never a shell string) with its seconds, one of its own settings drawn as text (the note), an installed extension's
    /// page, whose blocks it draws at the page's own pace (Q697), Pilot's notes as its `note` setting picks them (all by
    /// title, or one in full), drawn by Pilot alone, ~/code's repos with work not yet committed or pushed, drawn by Pilot
    /// alone (Q725), the market symbols its text setting names, priced by the Markets extension (Pilot's own Markets
    /// widget's alone, P83), or none.
    public enum Source: Equatable, Sendable {
        case reading([Reading]), command([String], every: Int), setting(String), extensionPage(String), notes(String), repos, markets(String), none
        /// A GitHub user's contribution calendar, read by gh, drawn by Pilot alone (P82).
        case github
        /// What the Mac plays, its cover and its controls, drawn by Pilot alone (Q726).
        case nowPlaying

        /// "reading cpu", "reading cpu, memory", "command every 60 s", "extension todo's page", "none".
        public var label: String {
            switch self {
            case .reading(let r): "reading \(r.map(\.rawValue).joined(separator: ", "))"
            case .command(_, let every): "command every \(every) s"
            case .setting(let name): "setting \(name)"
            case .extensionPage(let id): "extension \(id)'s page"
            case .notes: "your notes"
            case .repos: "your repos"
            case .github: "your GitHub contributions"
            case .nowPlaying: "what is playing"
            case .markets: "your market symbols"
            case .none: "none"
            }
        }
    }

    /// A button a JSON widget draws under its blocks (Q697): its title, and the Pilot action it runs, by id (`pilot
    /// actions` lists them; an extension's command is `ext.<extension>.<command>`). Live only in a ready, made-here or
    /// trusted widget; the Trust question lists each as title → action.
    public struct Button: Equatable, Sendable {
        public let title: String, action: String
        public init(title: String, action: String) { self.title = title; self.action = action }
        /// "Clean → apps.clean", as the Trust question and `pilot widget check` show it.
        public var line: String { "\(title) → \(action)" }
    }

    /// The starting size in points.
    public struct Size: Equatable, Sendable, Codable {
        public var width: Double, height: Double
        public init(width: Double, height: Double) { self.width = width; self.height = height }
        public static let standard = Size(width: 240, height: 160)
        public static let range = 80.0...2000.0
        /// A side held to the range.
        public static func clamp(_ side: Double) -> Double { side.clamped(range.lowerBound, range.upperBound) }
    }

    /// A setting Sven fills; a password's value lives in the Keychain, the rest in `settings.json` and each placement's
    /// own values (Edit widget). A `note` is one of Pilot's notes by id, or "" for all of them; `actions` is a list of
    /// Pilot actions' ids, the widget's buttons as Sven picks them, each of a button's shape (isActionID); `menu` is a list
    /// of Hyper+Space rows by their keys (menuPicks), the Launcher's tiles, a setting only Pilot's own widgets may have.
    public struct Field: Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable { case text, number, choice, checkbox, colour, password, note, actions, menu }
        public let name: String, label: String, kind: Kind, choices: [String], initial: JSONValue?
    }

    public let folder: URL
    public let id: String, title: String, version: String?, description: String?, icon: String
    public let draw: Draw, data: Source, hosts: [String], size: Size, settings: [Field], buttons: [Button]
    /// The one workspace a new placement shows on (Q691); nil for every workspace, the default.
    public let workspace: String?

    /// Why a folder is not a widget, each reason one line.
    public struct Problems: Error, Equatable, CustomStringConvertible {
        public let reasons: [String]
        public init(reasons: [String]) { self.reasons = reasons }
        public var description: String { reasons.joined(separator: "; ") }
    }

    /// Reads `folder/widget.json`; throws every problem found, never the first alone.
    public init(folder: URL) throws(Problems) {
        let file = folder.appending(path: Self.manifestName)
        guard let data = try? Self.readFile(file, limit: Self.fileLimit) else { throw Problems(reasons: ["it has no readable \(Self.manifestName)"]) }
        try self.init(manifest: data, folder: folder)
    }

    /// A widget from its manifest's bytes: a folder's, or one of Pilot's ready widgets, which live in code.
    public init(manifest data: Data, folder: URL) throws(Problems) {
        guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Problems(reasons: ["\(Self.manifestName) is not a JSON object"])
        }
        var problems: [String] = []
        // The icon is held to one emoji instead (isEmoji), whose joiners and variation selectors escaping would write out.
        func text(_ key: String, required: Bool, longest: Int, plain: Bool = true) -> String? {
            switch o[key] {
            // Counted in scalars, the unit the prompt's limit counts (a letter with a run of accents is one character).
            case .string(let s)? where !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (plain ? s.unicodeScalars.count : s.count) <= longest && (!plain || Self.isPlain(s)): return s
            case nil where !required, .null? where !required: return nil
            default: problems.append("\(key) must be text of 1 to \(longest) characters, with no control or invisible characters"); return nil
            }
        }
        let id = text("id", required: true, longest: 64) ?? ""
        if !id.isEmpty, !Self.isID(id) { problems.append("id must be lowercase letters, digits and single hyphens") }
        let title = text("title", required: true, longest: 60) ?? ""
        if !title.isEmpty, !Self.isTitle(title) { problems.append("title may not hold №, the mark Pilot gives a command's words") }
        let version = text("version", required: false, longest: 20), description = text("description", required: false, longest: 300)
        let icon = text("icon", required: false, longest: 8, plain: false)
        if let icon, !ScriptCommand.isEmoji(icon) { problems.append("icon must be one emoji") }
        let draw = o["draw"] == nil ? .blocks : o["draw"]?.string.flatMap(Draw.init(rawValue:)) ?? .blocks
        if o["draw"] != nil, o["draw"]?.string.flatMap(Draw.init(rawValue:)) == nil { problems.append("draw must be blocks or html") }
        if draw == .html, !Self.isRegularFile(folder.appending(path: Self.entryName)) { problems.append("an html widget needs \(Self.entryName) beside \(Self.manifestName)") }
        let source = Self.source(o["data"], problems: &problems)
        var hosts: [String] = []
        switch o["hosts"] {
        case nil, .null?: break
        case .array(let list)? where list.count <= 20:
            for host in list {
                if case .string(let h) = host, Self.isHost(h) { hosts.append(h) } else { problems.append("hosts must be web addresses, like api.example.com") ; break }
            }
            if hosts.joined(separator: ", ").count > Self.longestHosts { problems.append("hosts may be \(Self.longestHosts) characters in all, as the Trust question lists them") }
        default: problems.append("hosts must be a list of at most 20 web addresses")
        }
        var size = Size.standard
        switch o["size"] {
        case nil, .null?: break
        case .object(let s)?:
            if case .number(let w)? = s["width"], case .number(let h)? = s["height"], Size.range.contains(w), Size.range.contains(h) {
                size = Size(width: w, height: h)
            } else { problems.append("size needs a width and a height, each 80 to 2000 points") }
        default: problems.append("size must be an object with a width and a height")
        }
        let settings = Self.fields(o["settings"], problems: &problems)
        var workspace: String?
        switch o["workspace"] {
        case nil, .null?: break
        case .string(let w)? where Workspaces.all.contains(w): workspace = w
        default: problems.append("workspace must be one of \(Workspaces.all.first!) to \(Workspaces.all.last!), as text, or left out for every workspace")
        }
        if case .setting(let name) = source, !settings.contains(where: { $0.name == name && $0.kind == .text }) {
            problems.append("data.setting must name one of its text settings")
        }
        if case .extensionPage = source, draw != .blocks { problems.append("data.extension draws Pilot's blocks: draw must be blocks") }
        if source == .repos, draw != .blocks { problems.append("data.repos draws Pilot's blocks: draw must be blocks") }
        if source == .github, draw != .blocks { problems.append("data.github draws Pilot's blocks: draw must be blocks") }
        if source == .nowPlaying, draw != .blocks { problems.append("data.nowPlaying draws Pilot's own tile: draw must be blocks") }
        // It runs the Markets extension unasked: Pilot's own Markets widget's (a reserved id), never a folder's.
        if case .markets(let name) = source, !Self.isReserved(id) || draw != .blocks || !settings.contains(where: { $0.name == name && $0.kind == .text }) {
            problems.append("data.markets is Pilot's own Markets widget's: a blocks widget naming one of its text settings")
        }
        if case .notes(let name) = source {
            if draw != .blocks { problems.append("data.notes draws Pilot's blocks: draw must be blocks") }
            if !settings.contains(where: { $0.name == name && $0.kind == .note }) { problems.append("data.notes must name one of its note settings") }
        }
        let picked = settings.filter { $0.kind == .actions }
        if picked.count > 1 { problems.append("a widget has at most one actions setting") }
        if !picked.isEmpty, draw != .blocks { problems.append("an actions setting's buttons are a JSON widget's (draw blocks)") }
        // A menu setting runs any row Hyper+Space lists, past what a button may run: Pilot's own widgets' alone (a reserved
        // id; the Launcher's), never a folder's.
        let rows = settings.filter { $0.kind == .menu }
        if !rows.isEmpty, !Self.isReserved(id) || rows.count > 1 || draw != .blocks || !picked.isEmpty {
            problems.append("a menu setting is Pilot's own Launcher's: one, on a blocks widget with no actions setting")
        }
        var buttons: [Button] = []
        switch o["buttons"] {
        case nil, .null?: break
        case .array(let list)? where list.count <= Self.mostButtons:
            for item in list {
                guard case .object(let b) = item, case .string(let label)? = b["title"], case .string(let action)? = b["action"],
                      label.unicodeScalars.count <= 24, Self.isTitle(label),
                      Self.isActionID(action) else {
                    problems.append("buttons must each be {\"title\": plain text of 1 to 24 characters, \"action\": a Pilot action's id, as pilot actions lists it, "
                        + "of the form module.name, or ext.extension.command, that runs with no question and acts on nothing outside its id}")
                    break
                }
                buttons.append(Button(title: label, action: action))
            }
        default: problems.append("buttons must be a list of at most \(Self.mostButtons)")
        }
        if !buttons.isEmpty, draw != .blocks { problems.append("buttons are a JSON widget's (draw blocks): a page draws its own") }
        if !buttons.isEmpty, !picked.isEmpty { problems.append("its buttons are its list or its actions setting, not both") }
        // The Trust question shows its command's words, its sites and its buttons whole: together they fit the room the
        // prompt has for them, the buttons' line counted as shown.
        let reach = Self.shownSource(source) + hosts.joined(separator: ", ").unicodeScalars.count
            + (buttons.isEmpty ? 0 : Self.buttonsLine(buttons).unicodeScalars.count)
            + (picked.isEmpty ? 0 : Self.picksLine(Self.picks(picked[0].initial)).unicodeScalars.count)
        if reach > Self.longestCommand + Self.longestHosts {
            problems.append("its command, sites and buttons may be \(Self.longestCommand + Self.longestHosts) characters in all, as the Trust question shows them")
        }
        guard problems.isEmpty else { throw Problems(reasons: problems) }
        self.folder = folder; self.id = id; self.title = title; self.version = version; self.description = description
        self.icon = icon ?? "🧩"; self.draw = draw; self.data = source; self.hosts = hosts; self.size = size; self.settings = settings
        self.workspace = workspace; self.buttons = buttons
    }

    /// A JSON widget's buttons, at most six (an extension page's row holds six); and the most an actions setting holds,
    /// drawn as a grid.
    public static let mostButtons = 6, mostPicks = 12

    /// A placement's own values as they are kept (Edit widget, `pilot add widgets --values`): its settings only, never a
    /// password (the Keychain's, the widget's), an actions setting's picks only as a button may run them, and Pilot's
    /// Layout when it keeps a class (Auto is kept as nothing); nil when none are left.
    public func own(_ values: [String: JSONValue]) -> [String: JSONValue]? {
        var own: [String: JSONValue] = [:]
        if offersLayout, let kept = values[Self.layoutName]?.string.flatMap(SizeClass.init(rawValue:)) { own[Self.layoutName] = .string(kept.rawValue) }
        for field in settings where field.kind != .password {
            guard let value = values[field.name] else { continue }
            own[field.name] = switch field.kind {
            case .actions: .array(Self.picks(value).map(JSONValue.string))
            case .menu: .array(Self.menuPicks(value).map(JSONValue.string))
            default: value
            }
        }
        return own.isEmpty ? nil : own
    }

    /// Whether its questions still fit the prompt with `picks` as its actions setting's buttons (a placement's own, from
    /// `pilot add widgets --values`), counted as Widget.init counts its default: the command's words, the sites and the
    /// buttons line share one room.
    public func fits(picks: [String]) -> Bool {
        let reach = Self.shownSource(data) + hosts.joined(separator: ", ").unicodeScalars.count
            + (buttons.isEmpty ? 0 : Self.buttonsLine(buttons).unicodeScalars.count)
            + (actionsField == nil ? 0 : Self.picksLine(picks).unicodeScalars.count)
        return reach <= Self.longestCommand + Self.longestHosts
    }

    /// Its actions setting, the one a widget may have: the buttons Sven picks in Edit widget.
    public var actionsField: Field? { settings.first { $0.kind == .actions } }

    /// Its menu setting, Pilot's Launcher's: the Hyper+Space rows Sven picks in Edit widget, drawn as tiles.
    public var menuField: Field? { settings.first { $0.kind == .menu } }

    /// The row keys a menu setting's value holds (MenuEntry.Target.key: `app:`, `action:`, `branch:`), in order, once
    /// each, at most `mostMenuPicks`; a bare action id, as the Launcher kept its buttons before 1.0.2, reads as its row.
    public static func menuPicks(_ value: JSONValue?) -> [String] {
        guard case .array(let list)? = value else { return [] }
        var seen: Set<String> = []
        return Array(list.compactMap(\.string).compactMap { isActionID($0) ? "action:\($0)" : isMenuKey($0) ? $0 : nil }
            .filter { seen.insert($0).inserted }.prefix(mostMenuPicks))
    }

    /// A Hyper+Space row's key a Launcher tile may keep: an app, an action or a branch, plain printable text.
    public static func isMenuKey(_ s: String) -> Bool {
        guard (1...200).contains(s.count), s.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }),
              let colon = s.firstIndex(of: ":") else { return false }
        return ["app", "action", "branch"].contains(s[..<colon]) && s.index(after: colon) < s.endIndex
    }

    /// The most tiles a menu setting holds.
    public static let mostMenuPicks = 24

    /// The action ids an actions setting's value holds that a button may run, in order, once each, at most `mostPicks`.
    public static func picks(_ value: JSONValue?) -> [String] {
        guard case .array(let list)? = value else { return [] }
        var seen: Set<String> = []
        return Array(list.compactMap(\.string).filter { isActionID($0) && seen.insert($0).inserted }.prefix(mostPicks))
    }

    /// A Pilot action's id a button may run, by its shape, never a list of what it may not (round 3 review): a plain
    /// action, `<module>.<name>`, one dot and nothing after it (no `:` or `/`, so no app, site, page, workspace, script,
    /// menu, key or shell id carrying what it acts on), that Pilot runs with no question of its own and that is safe to
    /// run from a click elsewhere (Abilities.canTry: not the windows', not shut down, sleep, lock, Wi-Fi, Hyper or tiling
    /// off); or a real extension command, `ext.<extension>.<command>`, with nothing after it, as its own page's buttons
    /// run it. Whether Pilot has the action is asked when it runs, and `pilot widget check` says so.
    public static func isActionID(_ s: String) -> Bool {
        guard (1...80).contains(s.count), s.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }), !s.contains("/") else { return false }
        if s.hasPrefix(Extension.prefix) { return Extension.command(inAction: s) != nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return false }
        return ControlGate.Ask.run(s) == nil && Abilities.canTry(s) && !notOnClick.contains(s)
    }

    /// Plain actions a click on the desktop should never start, though the app window may try them: recording the screen,
    /// and tiling switched back on, which moves every window.
    static let notOnClick: Set<String> = ["captures.screenRecording", "engine.tilingOn"]

    /// The Trust question's line for an actions setting's buttons, which Sven picks, with the ones it starts with (its
    /// default, live once trusted until Edit widget changes them): counted in the question's room as the buttons line is.
    public static func picksLine(_ defaults: [String]) -> String {
        "Buttons you pick in Edit widget, each a Pilot action of a button's shape"
            + (defaults.isEmpty ? "" : "; it starts with: " + defaults.joined(separator: ", "))
    }

    /// The Trust question's line for buttons, each title → action.
    public static func buttonsLine(_ buttons: [Button]) -> String {
        "Buttons, each its title → the Pilot action it runs: " + buttons.map(\.line).joined(separator: ", ")
    }

    /// What the Trust question shows of its source past Pilot's own words: a command's words, an extension and command.
    static func shownSource(_ source: Source) -> Int {
        switch source {
        case .command(let words, _): words.reduce(0) { $0 + ControlGate.Ask.visible($1).unicodeScalars.count }
        case .extensionPage(let id): id.unicodeScalars.count
        default: 0
        }
    }

    /// Text a question or the page shows as it is (a title, a description, a setting's label or choice): exactly what
    /// ControlGate.Ask.visible leaves unchanged, so it shows as typed and as long as typed, and nothing in it (a control,
    /// bidi or zero-width character, an odd space, a backslash or ⏎) could make it read as something else (Q680).
    public static func isPlain(_ s: String) -> Bool { ControlGate.Ask.visible(s) == s }

    /// An argv word: printable ASCII with single spaces inside, never at an end, so every word shows as typed and no
    /// word can draw a row mark (№), a blank-looking symbol or a line of its own; text in any script is a setting's
    /// (handed on stdin), not an argument.
    public static func isArgvWord(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
            && !s.hasPrefix(" ") && !s.hasSuffix(" ") && !s.contains("  ")
    }

    /// A title as every question shows it, above a command's rows: 1 to 60 characters (scalars) of text shown as typed,
    /// not blank, and no №, the mark Pilot gives a command's words. widget.json, `pilot widget new` and the builder hold
    /// a title to this one rule.
    public static func isTitle(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespaces).isEmpty && s.unicodeScalars.count <= 60 && isPlain(s) && !s.contains("№")
    }

    /// Ids that start `pilot-` are Pilot's ready widgets': a folder in Widgets with one is not read.
    public static let reservedPrefix = "pilot-"
    public static func isReserved(_ id: String) -> Bool { id.hasPrefix(reservedPrefix) }

    /// Lowercase letters and digits in runs joined by single hyphens.
    public static func isID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.split(separator: "-", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
    }

    /// A host or an https address naming one: shown on the Trust to run card, never enforced (Q680).
    /// A host in ASCII host syntax (a non-ASCII name in its punycode form), written bare or as `https://host/`, nothing
    /// else: no path, port or query, read character by character rather than by a URL parser that would accept and
    /// re-encode more. So a site shows exactly as typed and as long as typed.
    public static func isHost(_ s: String) -> Bool {
        var host = Substring(s)
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) { host = host.dropFirst(scheme.count) }
        if host.hasSuffix("/") { host = host.dropLast() }
        return !host.isEmpty && host.count <= 253 && host.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "*"
        }
    }

    private static func source(_ value: JSONValue?, problems: inout [String]) -> Source {
        switch value {
        case nil, .null?: return .none
        case .object(let d)?:
            if case .string(let name)? = d["setting"], d["reading"] == nil, d["command"] == nil { return .setting(name) }
            // Pilot's notes, as its note setting picks them: drawn by Pilot alone, never handed to a page or a program.
            if let named = d["notes"] {
                guard case .string(let name) = named, d.count == 1 else {
                    problems.append("data.notes must name its note setting, alone: the widget shows your notes as that setting picks them")
                    return .none
                }
                return .notes(name)
            }
            // ~/code's own repos with work not committed or pushed: drawn by Pilot alone, like the notes.
            if let named = d["repos"] {
                guard named == .bool(true), d.count == 1 else {
                    problems.append("data.repos must be true, alone: the widget shows your repos with work not committed or pushed")
                    return .none
                }
                return .repos
            }
            // What the Mac plays, drawn by Pilot alone with its cover and controls (Q726).
            if let named = d["nowPlaying"] {
                guard named == .bool(true), d.count == 1 else {
                    problems.append("data.nowPlaying must be true, alone: the widget shows what is playing")
                    return .none
                }
                return .nowPlaying
            }
            // Market symbols, its text setting's, priced through the Markets extension: Pilot's own Markets widget's.
            if let named = d["markets"] {
                guard case .string(let name) = named, d.count == 1 else {
                    problems.append("data.markets must name its symbols setting, alone: the widget shows those symbols' prices")
                    return .none
                }
                return .markets(name)
            }
            // An installed extension's page, by the extension's id: the blocks its page shows, which Pilot asks for as the
            // page does, at the page's pace, with nothing of the widget's (Q697).
            if let named = d["extension"] {
                guard case .string(let id) = named, isID(id), d.count == 1 else {
                    problems.append("data.extension must be an installed extension's id, alone: the widget shows that extension's page")
                    return .none
                }
                return .extensionPage(id)
            }
            // A GitHub user's contributions, read by gh (P82): the user is its setting, drawn by Pilot alone.
            if let named = d["github"] {
                guard named == .bool(true), d.count == 1 else { problems.append("data.github must be true, alone: the widget shows GitHub contributions"); return .none }
                return .github
            }
            switch (d["reading"], d["command"]) {
            case (let named?, nil):
                // A reading by name, or a list of up to six (This Mac's, the clock and calendar's).
                let names: [JSONValue] = if case .array(let list) = named { list } else { [named] }
                let readings = names.compactMap { $0.string.flatMap(Reading.init(rawValue:)) }
                guard !readings.isEmpty, readings.count == names.count, readings.count <= 6, Set(readings).count == readings.count else {
                    problems.append("data.reading must be one, or a list of up to six, of \(Reading.allCases.map(\.rawValue).joined(separator: ", "))")
                    return .none
                }
                return .reading(readings)
            case (nil, .array(let argv)?):
                // Every word is shown whole, as itself, in the Trust question and every Allow: plain text only, and few
                // and short enough that the question always fits the prompt (ControlGate.Ask.mostLines, .longest).
                let words = argv.compactMap { if case .string(let s) = $0, isArgvWord(s) { s } else { nil } }
                let shown = words.reduce(0) { $0 + ControlGate.Ask.visible($1).count }
                guard !words.isEmpty, words.count == argv.count, words.count <= mostWords, shown <= longestCommand else {
                    problems.append("data.command must be 1 to \(mostWords) words of printable ASCII (single spaces inside, none at the ends), "
                        + "\(longestCommand) characters in all as shown: the program, then its arguments; other text belongs in a setting, a longer script in a file in the widget's folder")
                    return .none
                }
                var every = 60
                switch d["every"] {
                case nil: break
                case .number(let n)? where n.isFinite && n >= Double(fewestSeconds) && n <= 86_400: every = Int(n.rounded(.up))
                default: problems.append("data.every must be \(fewestSeconds) to 86400 seconds")
                }
                return .command(words, every: every)
            default:
                problems.append("data must name its readings, one command, one setting, an extension or its note setting")
                return .none
            }
        default:
            problems.append("data must be an object")
            return .none
        }
    }

    private static func fields(_ value: JSONValue?, problems: inout [String]) -> [Field] {
        guard let value, value != .null else { return [] }
        guard case .array(let list) = value, list.count <= 30 else { problems.append("settings must be a list of at most 30 fields"); return [] }
        var fields: [Field] = []
        for item in list {
            guard case .object(let f) = item, case .string(let name)? = f["name"], isFieldName(name),
                  case .string(let type)? = f["type"], let kind = Field.Kind(rawValue: type) else {
                problems.append("each setting needs a name (letters, digits, _) and a type: \(Field.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
                continue
            }
            guard !fields.contains(where: { $0.name == name }) else { problems.append("setting \(name) is listed twice"); continue }
            let choices: [String] = if case .array(let c)? = f["choices"] { c.compactMap(\.string) } else { [] }
            if kind == .choice, choices.isEmpty { problems.append("setting \(name) is a choice with no choices") }
            let label: String = if case .string(let l)? = f["label"], !l.isEmpty { l } else { name }
            if !isPlain(label) || label.unicodeScalars.count > 40 || !choices.allSatisfy({ isPlain($0) && $0.unicodeScalars.count <= 60 }) || choices.count > 30 {
                problems.append("setting \(name)'s label (40 characters) and choices (at most 30, 60 characters each) must be text shown as typed")
            }
            switch (kind, f["default"]) {
            case (.actions, let given?) where given != .null:
                guard case .array(let ids) = given, ids.count <= mostPicks, ids.allSatisfy({ $0.string.map(isActionID) == true }) else {
                    problems.append("setting \(name)'s default must be a list of at most \(mostPicks) Pilot actions' ids, each of a button's shape")
                    continue
                }
            case (.menu, let given?) where given != .null:
                guard case .array(let keys) = given, keys.count <= mostMenuPicks, keys.allSatisfy({ $0.string.map(isMenuKey) == true }) else {
                    problems.append("setting \(name)'s default must be a list of at most \(mostMenuPicks) Hyper+Space rows' keys")
                    continue
                }
            case (.note, let given?) where given != .null && given.string == nil:
                problems.append("setting \(name)'s default must be a note's file name, or \"\" for all notes")
            default: break
            }
            // A password's default would sit in a file anyone can read.
            fields.append(Field(name: name, label: label, kind: kind, choices: choices, initial: kind == .password ? nil : f["default"]))
        }
        return fields
    }

    private static func isFieldName(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter, s.count <= 40 else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// `url`'s bytes, opened without following a link and only as a regular file, at most `limit`.
    public static func readFile(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}

// MARK: - Trust

extension Widget {
    /// Made here (`pilot widget new`, the builder, `/widget`, Duplicate to edit) or trusted (Trust this widget): full
    /// power. Locked: no command and no HTML, readings only (Q676, Q680). Pilot alone writes it.
    public enum Trust: String, Codable, Sendable {
        case madeHere = "made-here", trusted, locked

        /// Whether its command runs and its HTML loads.
        public var runs: Bool { self != .locked }
    }

    /// `WidgetData/<id>/trust.json`. The level holds only for the folder it was given to, by its device and inode: a
    /// folder replaced, re-imported or copied in by Finder under an id that once had trust (uninstall keeps WidgetData)
    /// is another inode and reads locked, while Sven's edits inside it keep it.
    public struct TrustRecord: Codable, Equatable, Sendable {
        public var level: Trust
        public var device: Int64, inode: UInt64
        public var at: Date
        public init(level: Trust, device: Int64, inode: UInt64, at: Date = .now) { self.level = level; self.device = device; self.inode = inode; self.at = at }
    }

    /// A folder's device and inode, nil unless it is a real folder (a link to one is not).
    public static func identity(of folder: URL) -> (device: Int64, inode: UInt64)? {
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return (Int64(info.st_dev), UInt64(info.st_ino))
    }

    /// The trust `record` gives the folder now: locked with no record, a record for another folder, or no folder.
    public static func trust(_ record: TrustRecord?, folder: (device: Int64, inode: UInt64)?) -> Trust {
        guard let record, let folder, record.device == folder.device, record.inode == folder.inode else { return .locked }
        return record.level
    }

    /// The record in `file`, nil when missing or unreadable (both read as locked).
    public static func readTrust(_ file: URL) -> TrustRecord? {
        guard let data = try? readFile(file, limit: 4096) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TrustRecord.self, from: data)
    }

    public static func encode(_ record: TrustRecord) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(record)) ?? Data()
    }
}

// MARK: - Running a command

extension Widget {
    /// The system's folders, after the widget's own and Homebrew's on its PATH.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The child's whole environment, never Pilot's own: HOME, USER and TMPDIR from Pilot's, a PATH of the widget's folder,
    /// Homebrew's and the system's, LANG and the widget's id.
    public static func environment(id: String, folder: URL, from pilot: [String: String]) -> [String: String] {
        pilot.filter { ["HOME", "USER", "TMPDIR"].contains($0.key) }.merging([
            "PATH": [folder.path, "/opt/homebrew/bin", "/usr/local/bin", systemPath].joined(separator: ":"),
            "LANG": "en_US.UTF-8", "PILOT_WIDGET_ID": id,
        ]) { _, new in new }
    }

    /// The program argv's first word names: a path with a slash against the widget's folder (or absolute), a bare name
    /// looked up on `path` as a shell would; nil unless it is an executable file. Process searches nothing itself.
    public static func program(_ word: String, folder: URL, path: String) -> URL? {
        let fm = FileManager.default
        func runnable(_ url: URL) -> URL? {
            var isFolder: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue && fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        if word.contains("/") {
            return runnable(word.hasPrefix("/") ? URL(filePath: word) : folder.appending(path: word).standardizedFileURL)
        }
        return path.split(separator: ":").lazy.compactMap { runnable(URL(filePath: String($0)).appending(path: word)) }.first
    }

    /// What Pilot writes on the command's stdin, then closes it: the settings (passwords included, never in argv or the
    /// environment) and the size it draws at.
    public static func message(settings: [String: JSONValue], size: Size) -> Data {
        let fields: JSONValue = .object(["type": .string("widget"), "settings": .object(settings),
                                         "size": .object(["width": .number(size.width), "height": .number(size.height)])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(fields)) ?? Data()) + Data("\n".utf8)
    }

    /// What one run answered: blocks to draw, data for the page, or why there is nothing. An error's `reason` is Pilot's
    /// own fixed words; `said` is what the program printed with it (its error message, its stderr), which only its tile and
    /// a private log line show: it may carry a password the run was handed, so no `pilot` answer ever reads it back.
    public enum Answer: Equatable, Sendable {
        case blocks([Extension.Block]), data(JSONValue), error(String, said: String? = nil)

        public var kind: String {
            switch self { case .blocks: "blocks"; case .data: "data"; case .error: "error" }
        }
    }

    private struct Printed: Decodable { let type: String, blocks: [Extension.Block.Line]?, data: JSONValue?, text: String? }

    /// The one JSON object the command printed: `{"type":"blocks","blocks":[…]}` or `{"type":"data","data":{…}}`, or an
    /// error message. The whole output is read as one object; failing that its last line, so a stray log line before is
    /// forgiven.
    public static func answer(_ output: String) -> Answer {
        guard output.utf8.count <= outputLimit else { return .error("printed more than \(outputLimit / 1_000_000) MB") }
        let decoder = JSONDecoder()
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed.split(whereSeparator: \.isNewline).last.map(String.init)
        guard let printed = [trimmed, last].compactMap({ $0 }).lazy.compactMap({ try? decoder.decode(Printed.self, from: Data($0.utf8)) }).first else {
            return .error(trimmed.isEmpty ? "printed nothing" : "printed no widget answer, one JSON object")
        }
        switch printed.type {
        case "blocks": return .blocks(Extension.Block.blocks(printed.blocks))
        case "data":
            guard let data = printed.data, case .object = data else { return .error("its data must be a JSON object") }
            return .data(data)
        case "error": return .error("printed an error message", said: printed.text.map { String($0.prefix(200)) })
        default: return .error("printed an answer of a type widgets do not print; they print blocks or data")
        }
    }

    /// The seconds between two runs of a command: what it asks, never under 10.
    public static func every(_ asked: Int) -> Int { max(asked, fewestSeconds) }
}

// MARK: - Import

extension Widget {
    /// One file of a folder walked for import.
    public struct Walked: Equatable, Sendable {
        public let path: String, size: Int, executable: Bool, device: Int64, inode: UInt64
    }

    /// Every file under `folder`, by lstat, never following a link: a link anywhere (even one pointing inside), anything
    /// that is not a regular file or a folder, a path that is not safe inside the folder, and the gallery's limits are
    /// each a problem. Import refuses a folder with any (Q680).
    public static func walk(_ folder: URL) -> (files: [Walked], problems: [String]) {
        var files: [Walked] = [], problems: [String] = [], total = 0
        var root = stat()
        guard lstat(folder.path, &root) == 0 else { return ([], ["\(folder.path) does not exist"]) }
        guard root.st_mode & S_IFMT == S_IFDIR else {
            return ([], [root.st_mode & S_IFMT == S_IFLNK ? "the folder is a symlink" : "it is not a folder"])
        }
        func visit(_ url: URL, _ relative: String, depth: Int) {
            guard depth < 16 else { return problems.append("\(relative) is nested too deep") }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return problems.append("\(relative.isEmpty ? "the folder" : relative) does not read") }
            for name in names.sorted() {
                let path = relative.isEmpty ? name : relative + "/" + name
                guard isSafeEntry(path) else { problems.append("\(path) leaves the folder"); continue }
                let child = url.appending(path: name)
                var info = stat()
                guard lstat(child.path, &info) == 0 else { problems.append("\(path) does not read"); continue }
                switch info.st_mode & S_IFMT {
                case S_IFLNK: problems.append("\(path) is a symlink")
                case S_IFDIR: visit(child, path, depth: depth + 1)
                case S_IFREG:
                    let size = Int(info.st_size)
                    if size > fileLimit { problems.append("\(path) is larger than the \(fileLimit / 1_000_000) MB a file may be") }
                    total += size
                    files.append(Walked(path: path, size: size, executable: info.st_mode & S_IXUSR != 0, device: Int64(info.st_dev), inode: UInt64(info.st_ino)))
                default: problems.append("\(path) is not a regular file")
                }
            }
        }
        visit(folder, "", depth: 0)
        if files.count > mostFiles { problems.append("it has \(files.count) files, more than the \(mostFiles) a widget may have") }
        if total > widgetLimit { problems.append("it is larger than the \(widgetLimit / 1_000_000) MB a widget may be") }
        if !files.contains(where: { $0.path == manifestName }) { problems.append("it has no \(manifestName)") }
        return (files, problems)
    }

    /// A path inside a widget's folder, as a folder walk or a .zip entry names it: relative, no `..` or `.`, no empty
    /// part, backslash or NUL.
    public static func isSafeEntry(_ path: String) -> Bool { ExtensionCatalogue.isSafe(path) }

    /// A folder copied into a temporary one for import, each file read without following a link and checked to be the
    /// file the walk saw; `widget` is the copy as Pilot reads it.
    public struct Staged: Sendable {
        public let copy: URL, widget: Widget
        public func remove() { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    }

    /// Walks `folder`, copies it into `staging` file by file and reads the copy as a widget; throws Problems with every
    /// reason, leaving nothing behind.
    @concurrent public static func stage(_ folder: URL, into staging: URL) async throws(Problems) -> Staged {
        let (files, problems) = walk(folder)
        guard problems.isEmpty else { throw Problems(reasons: problems) }
        let fm = FileManager.default
        let copy = staging.appending(path: "import-\(UUID().uuidString)").appending(path: folder.lastPathComponent)
        do {
            for file in files {
                let source = folder.appending(path: file.path)
                let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Problems(reasons: ["\(file.path) changed while it was read"]) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_dev) == file.device, UInt64(info.st_ino) == file.inode else {
                    throw Problems(reasons: ["\(file.path) changed while it was read"])
                }
                let data = try handle.read(upToCount: fileLimit + 1) ?? Data()
                guard data.count <= fileLimit else { throw Problems(reasons: ["\(file.path) is larger than the \(fileLimit / 1_000_000) MB a file may be"]) }
                let url = copy.appending(path: file.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                try fm.setAttributes([.posixPermissions: file.executable ? 0o755 : 0o644], ofItemAtPath: url.path)
            }
            return Staged(copy: copy, widget: try Widget(folder: copy))
        } catch {
            try? fm.removeItem(at: copy.deletingLastPathComponent())
            if let problems = error as? Problems { throw problems }
            throw Problems(reasons: ["it did not copy: \(error.localizedDescription)"])
        }
    }
}

// MARK: - Placement and when it shows

extension Widget {
    /// One widget on the desktop (the `widgets` collection): a widget may be placed more than once. Its top-left corner is
    /// a fraction of its screen's frame, so it keeps its place when the resolution changes; `screen` is the display's
    /// UUID, nil for the main one. `workspace` is the one workspace it shows on, nil for every one (Q691): a new placement
    /// starts with its widget.json's, and the Widgets page changes it.
    public struct Placement: Codable, Equatable, Sendable {
        public var id: String, widget: String, screen: String?
        public var x: Double, y: Double, width: Double, height: Double
        public var workspace: String?
        /// Sven resized it (Hyper+right-drag, Q695): its size is his, never fitted to its content.
        public var sized: Bool?
        /// On Pilot's Home page instead of the desktop: Home draws it among its blocks, and it runs only while Home draws it;
        /// its screen, place and workspace are not read.
        public var home: Bool?
        /// Its own settings (Edit widget), over the widget's: each placement keeps its own, as macOS widgets do; never a
        /// password, which stays the widget's, in the Keychain.
        public var values: [String: JSONValue]?
        public init(id: String = Placement.newID(), widget: String, screen: String?, x: Double, y: Double, width: Double, height: Double,
                    workspace: String? = nil, home: Bool = false) {
            self.id = id; self.widget = widget; self.screen = screen; self.x = x; self.y = y; self.width = width; self.height = height
            self.workspace = workspace; self.home = home ? true : nil
        }

        public var onHome: Bool { home == true }

        /// Whether it shows on a screen in `state`, and why: the screen's own rule (an empty workspace or Show desktop,
        /// Q692 keeps widgets behind windows), narrowed to its one workspace when it has one.
        public func why(on state: ScreenState) -> (shows: Bool, reason: String) {
            guard let workspace, state.why.shows, state.workspace != workspace else { return state.why }
            return (false, "it shows on workspace \(workspace) only")
        }

        public static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

        /// A new placement of `widget` at its own size and on its own workspace (its widget.json's), a step down and right
        /// from the `count` placed before it, so two never land on each other; what is given overrides. On Home it has no
        /// screen or workspace.
        public static func new(_ widget: Widget, after count: Int, screen: String? = nil, x: Double? = nil, y: Double? = nil,
                               workspace: String? = nil, home: Bool = false) -> Placement {
            let step = 0.05 + 0.03 * Double(count % 10)
            return Placement(widget: widget.id, screen: home ? nil : screen, x: x ?? step, y: y ?? step, width: widget.size.width,
                             height: widget.size.height, workspace: home ? nil : workspace ?? widget.workspace, home: home)
        }

        /// Its frame on a screen whose frame is `screen`, top-left origin, kept on the screen.
        public func frame(on screen: CGRect) -> CGRect {
            let w = min(width, screen.width), h = min(height, screen.height)
            let left = screen.minX + (screen.width * x).clamped(0, screen.width - w)
            let top = screen.minY + (screen.height * y).clamped(0, screen.height - h)
            return CGRect(x: left, y: top, width: w, height: h)
        }

        /// The fractions a frame (top-left origin) gives on `screen`.
        public mutating func move(to frame: CGRect, on screen: CGRect) {
            guard screen.width > 0, screen.height > 0 else { return }
            x = ((frame.minX - screen.minX) / screen.width).clamped(0, 1)
            y = ((frame.minY - screen.minY) / screen.height).clamped(0, 1)
        }
    }

    /// What decides whether a screen's widgets show (Q592): its shown workspace has no window, or Show desktop holds the
    /// windows out; and the screen is in use. A tiler that is not answering shows nothing, since emptiness is unknown.
    public struct ScreenState: Equatable, Sendable {
        public var inUse: Bool, tilerAnswering: Bool, workspace: String?, windows: Int, showingDesktop: Bool
        public init(inUse: Bool, tilerAnswering: Bool, workspace: String?, windows: Int, showingDesktop: Bool) {
            self.inUse = inUse; self.tilerAnswering = tilerAnswering; self.workspace = workspace; self.windows = windows; self.showingDesktop = showingDesktop
        }

        public var shows: Bool { why.shows }

        /// Whether it shows, and why, in words `pilot status --part widgets` gives.
        public var why: (shows: Bool, reason: String) {
            guard inUse else { return (false, "the screen is locked or asleep") }
            guard tilerAnswering, let workspace else { return (false, "the tiler is not answering") }
            if showingDesktop { return (true, "Show desktop holds workspace \(workspace)'s windows out") }
            if windows == 0 { return (true, "workspace \(workspace) is empty") }
            return (false, "workspace \(workspace) has \(windows) window\(windows == 1 ? "" : "s")")
        }
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), Swift.max(low, high)) }
}
