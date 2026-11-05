import Foundation

/// The Allow gate (ADR 0013, inventory §5.6): what the pilot command may do only once Sven presses Allow on Pilot's own
/// prompt. Shell, scripts, keystrokes, URLs to any scheme, installs and applied imports wait on it. No argument or flag
/// skips it and a caller cannot approve ahead: every request asks, and an Allow runs that request once.
@MainActor
public final class ControlGate {
    /// One question, in words: what runs and the exact thing it runs.
    public struct Ask: Equatable, Sendable {
        /// "Run shell".
        public let title: String
        /// "rm -rf ~/tmp", as the request carries it.
        public let detail: String
        /// A plan's rows (ControlPlan), one line of `detail` each, for a surface that draws them as a card.
        public let rows: [ControlPlan.Change]
        /// The detail's lines when its line breaks are its own (a widget's or an extension's question, Pilot's lines then
        /// its words): a surface escapes each line and keeps the breaks between them, and a break typed inside one is only
        /// marked ⏎, so a title or a path can never start a line that reads as Pilot's (review 2).
        public let lines: [String]?
        /// The question in plain words for the prompt to lead with, when the whole of it is long: a headline ("Install
        /// Weather 1.3.0?") and at most two short lines naming every risk the whole shows (what runs as Sven, what goes
        /// to the Trash, where it comes from). The whole stays one click away, behind Show details; nil shows it at once.
        public private(set) var summary: Summary?

        public struct Summary: Equatable, Sendable {
            public let headline: String, points: [String]
        }

        public init(_ title: String, _ detail: String, rows: [ControlPlan.Change] = []) {
            self.title = title; self.detail = detail; self.rows = rows; lines = nil
        }

        public init(_ title: String, lines: [String]) {
            self.title = title; detail = lines.joined(separator: "\n"); rows = []; self.lines = lines
        }

        /// "Run shell: rm -rf ~/tmp".
        public var text: String { "\(title): \(detail)" }

        /// This question led by `headline` and `points`, at most two.
        public func summed(_ headline: String, _ points: [String]) -> Self {
            assert(points.count <= 2, "a summary has at most two lines")
            var ask = self
            ask.summary = Summary(headline: headline, points: points)
            return ask
        }
    }

    /// Shows the question and answers true for Allow. An answer after `wait` counts for nothing.
    public typealias Decider = @MainActor (Ask, ControlPeer?) async -> Bool

    /// How long the question stays; no answer by then denies.
    public static let wait: Duration = .seconds(60)

    /// Pilot's prompt; the chat swaps in its own inline question while it is open.
    public var decider: Decider
    private let wait: Duration

    public init(wait: Duration = ControlGate.wait, decider: @escaping Decider) { self.wait = wait; self.decider = decider }

    /// Runs `body` once, after an Allow when `ask` is a question; with no ask it runs at once. Deny, no answer in time,
    /// or a question too long to show whole throws denied and runs nothing. `ask` is read again after the Allow and
    /// must be the question shown, so what runs is what Sven saw: a quicklink or extension changed while it was up denies.
    /// A question a plan's Allow covers (ControlApproval) is not asked again while that plan applies.
    public func allow<T>(_ ask: @autoclosure @MainActor () -> Ask?, peer: ControlPeer?,
                         _ body: @MainActor () async throws(ControlError) -> T) async throws(ControlError) -> T {
        if let asked = ask(), !ControlApproval.covers(asked) {
            if let tooLong = asked.tooLong { throw ControlError(.denied, "not asked: \(tooLong)") }
            switch await decide(asked, peer) {
            case .allowed: break
            case .denied: throw ControlError(.denied, "not allowed: \(asked.text)")
            case .unanswered: throw ControlError(.denied, "no answer in \(wait.components.seconds) s, so not allowed: \(asked.text)")
            }
            guard ask() == asked else { throw ControlError(.denied, "changed while asking, so not run: \(asked.text)") }
        }
        return try await body()
    }

    private enum Answer { case allowed, denied, unanswered }

    /// The decider's answer, or unanswered once `wait` has passed; the loser is cancelled, which closes the prompt.
    private func decide(_ ask: Ask, _ peer: ControlPeer?) async -> Answer {
        let first = FirstAnswer()
        return await withCheckedContinuation { continuation in
            first.continuation = continuation
            first.racers = [
                Task { [decider] in first.give(await decider(ask, peer) ? .allowed : .denied) },
                Task { [wait] in try? await Task.sleep(for: wait); first.give(.unanswered) },
            ]
        }
    }

    /// The first of the decider and the clock to answer; it cancels the other.
    @MainActor private final class FirstAnswer {
        var continuation: CheckedContinuation<Answer, Never>?
        var racers: [Task<Void, Never>] = []

        func give(_ answer: Answer) {
            guard let continuation else { return }
            self.continuation = nil
            racers.forEach { $0.cancel() }
            racers = []
            continuation.resume(returning: answer)
        }
    }
}

extension ControlGate.Ask {
    /// The longest question, in Unicode scalars, and the most line breaks the prompt shows whole on a laptop screen; a
    /// longer one is denied unasked, never cut.
    public static let longest = 1200, mostLines = 20

    /// Why the question cannot be shown whole; nil when it can. Its details open under its summary's headline, so that
    /// counts too.
    var tooLong: String? {
        let shown = text + (summary.map { "\n" + $0.headline } ?? "")
        let length = shown.unicodeScalars.count, lines = shown.unicodeScalars.count { $0 == "\n" }
        if length > Self.longest { return "the question is \(length) characters, past the \(Self.longest) Pilot shows whole" }
        if lines > Self.mostLines { return "the question has \(lines) line breaks, past the \(Self.mostLines) Pilot shows whole" }
        return nil
    }

    /// The setting keys whose pages already confirm a change: the layer key, Pilot's switch, and the Window shelf's
    /// pictures (Stills and Live ask Screen Recording; Live warns first).
    private static let confirmedSettings: Set<String> = ["layerKey", "switch.on", "shelf.pictures"]

    /// Prefixes whose ids run a command, a keystroke or a URL of any scheme: they ask by prefix, whatever follows parses
    /// or not, the rest shown as the request carries it.
    private static let asking: [(prefix: String, title: String)] = [
        ("drive.shell:", "Run shell"), ("drive.pick:", "Run shell picker"), ("drive.url:", "Open URL"),
        ("drive.shortcut:", "Run shortcut"), ("drive.key:", "Send keystroke"), (ScriptCommand.prefix, "Run script"),
    ]

    /// The actions that cut the network, a radio, the power or the session, or take the keyboard (T52, Sven Q837): from
    /// the socket they ask Allow, a pilot:// link needs the token (LinkToken.allows), and an extension row never runs them
    /// (ExtensionList.allowsPilot). The tap, Pilot's own buttons and the menu run them as ever. Keep awake, lock when idle
    /// and eject all stay off it: none of them cuts the network, a radio, the power or the session.
    public static let cutting: [String: String] = [
        "system.wifi": "Turn Wi-Fi on or off", "system.bluetooth": "Turn Bluetooth on or off",
        "system.shutDown": "Shut down the Mac", "system.restart": "Restart the Mac", "system.sleep": "Put the Mac to sleep",
        "system.logOut": "Log out", "system.lock": "Lock the screen", "system.lockKeyboard": "Lock the keyboard",
    ]

    /// Registered actions that act outside Pilot without a page's confirm: typing into the front app, and `cutting`.
    private static let askingActions = cutting.merging(["apps.pastePlain": "Type the clipboard into the front app"]) { a, _ in a }

    /// The question running action `id` asks, nil when it runs without one. A quicklink asks with its URL and an
    /// extension command with its extension, title and program, looked up in `quicklinks` and `extensions`; one not found
    /// still asks. Every other `drive.` id but a menu press asks, as does a link that is not http or https, and anything
    /// an import switches off (BindStore.arrivesOff).
    public static func run(_ id: String, quicklinks: [Quicklink] = [], extensions: [Extension] = []) -> Self? {
        if let title = askingActions[id] { return Self(title, id) }
        if let (prefix, title) = asking.first(where: { id.hasPrefix($0.prefix) }) { return Self(title, String(id.dropFirst(prefix.count))) }
        if id.hasPrefix(Quicklink.prefix) { return quicklink(id, in: quicklinks) }
        if id.hasPrefix(Extension.prefix) { return extensionCommand(id, in: extensions) }
        switch AppLink(id: id) {
        case .web(let url)?, .url(_, let url)?:
            if ["http", "https"].contains(URL(string: url)?.scheme?.lowercased() ?? "") { return nil }
            return Self("Open link", url)
        case .open?, .privateWindow?: return nil
        case nil: break
        }
        let unparsedLink = ["apps.web:", "apps.url:"].contains { id.hasPrefix($0) }
        let otherDrive = id.hasPrefix("drive.") && !id.hasPrefix("drive.menu:")
        return unparsedLink || otherDrive || BindStore.arrivesOff(id) ? Self("Run", id) : nil
    }

    private static func quicklink(_ id: String, in links: [Quicklink]) -> Self {
        guard let (linkID, query) = Quicklink.parse(id), let link = links.first(where: { $0.id == linkID }) else {
            return Self("Open quicklink", "\(id.dropFirst(Quicklink.prefix.count)), not found")
        }
        return Self("Open quicklink \(link.name)", link.url(query: query ?? "")?.absoluteString ?? link.url)
    }

    private static func extensionCommand(_ id: String, in extensions: [Extension]) -> Self {
        guard let (ext, command) = Extension.command(inAction: id, in: extensions) else {
            return Self("Run extension command", "\(id.dropFirst(Extension.prefix.count)), not found")
        }
        let input = Extension.input(inAction: id).map { " with input \($0)" } ?? ""
        return Self("Run extension command \(ext.title) › \(command.title)", "\(command.program.path(percentEncoded: false))\(input)")
    }

    /// The question setting `key` to `value` asks, nil for a setting that changes without one.
    public static func set(_ key: String, to value: String) -> Self? {
        confirmedSettings.contains(key) ? Self("Set \(key)", value) : nil
    }

    /// A key combination pressed into `app` through the tap.
    public static func press(_ keys: String, app: String) -> Self { Self("Press \(keys) in", app) }

    /// Software Pilot installs or removes outside its own lists, by the collection `pilot add`/`remove` names.
    public enum Software: String, CaseIterable, Sendable {
        case package, webApp = "web app", `extension`

        /// The collection that holds it.
        public var collection: String {
            switch self {
            case .package: "packages"
            case .webApp: "webapps"
            case .extension: "extensions"
            }
        }
    }

    public static func install(_ kind: Software, _ id: String) -> Self { Self("Install \(kind.rawValue)", id) }
    public static func remove(_ kind: Software, _ id: String) -> Self { Self("Remove \(kind.rawValue)", id) }
    public static func install(_ kind: Software, lines: [String]) -> Self { Self("Install \(kind.rawValue)", lines: lines) }
    public static func remove(_ kind: Software, lines: [String]) -> Self { Self("Remove \(kind.rawValue)", lines: lines) }

    /// The question `pilot add <collection>` asks: an install for packages, web apps and extensions; nil for Pilot's
    /// own lists (aliases, quicklinks, snippets, …), where adding runs nothing.
    public static func add(to collection: String, _ row: String) -> Self? {
        Software.allCases.first { $0.collection == collection }.map { install($0, row) }
    }

    public static func remove(from collection: String, _ row: String) -> Self? {
        Software.allCases.first { $0.collection == collection }.map { remove($0, row) }
    }

    /// `import --apply`: what the import changes, in a line.
    public static func applyImport(_ summary: String) -> Self { Self("Apply import", summary) }

    /// A change to macOS's own shortcuts (com.apple.symbolichotkeys), as the Binds page's conflict fix makes.
    public static func macShortcut(_ change: String) -> Self { Self("Change macOS shortcut", change) }

    /// `text` with every scalar that would show as something else, or as nothing, written out, so it reads one way only
    /// without colour: a line break as ⏎ before a real new line, a tab as `\t`, a bidi override or a zero-width space as
    /// `\u{202E}`, a typed backslash doubled and a typed ⏎ written out, so each mark reads one way only. A plain space stays.
    public static func visible(_ text: String) -> String {
        text.unicodeScalars.reduce(into: "") { $0 += escaped($1) ?? String($1) }
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case " ": return nil
        case "\\": return "\\\\"
        case "\n": return "⏎\n"
        case "⏎": return "\\u{23CE}"
        case "\t": return "\\t"
        case "\r": return "\\r"
        default: break
        }
        let p = scalar.properties
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator, .spaceSeparator,
                                                   .privateUse, .surrogate, .unassigned]
        guard hidden.contains(p.generalCategory) || p.isDefaultIgnorableCodePoint || p.isWhitespace else { return nil }
        return "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
    }
}
