import Foundation

extension Extension {
    /// Who narrows a list as Sven types (card agent-bo-95423243): Pilot, ranking the rows the program gave once as the
    /// view opened, or the program, asked again with each change of the search (`"filter": "self"`), its order kept.
    public enum Filter: String, Equatable, Sendable { case pilot, program = "self" }

    /// One row of a list command's answer.
    public struct Item: Equatable, Sendable, Decodable {
        /// What a row does, with the title Cmd+K lists it by; the first is Return's (card agent-bo-95423244).
        public struct Action: Equatable, Sendable {
            /// Open a URL or a path; copy or paste text; push another command's view or run a no-view one, handing on a
            /// context; show a HUD line, with an alert sound; run a registered Pilot action; start, hold or stop Pilot's one
            /// timer; show Pilot's alert, which stays until a button is pressed; ask Pilot's AI (ExtensionAI).
            public enum Kind: Equatable, Sendable {
                case open(String), copy(String), paste(String), push(command: String, context: JSONValue?)
                case run(command: String, context: JSONValue?), hud(String, sound: String? = nil), pilot(String)
                /// Its end and buttons are actions too, so the case is boxed.
                indirect case timer(TimerSpec), alert(AlertSpec)
                /// The AI page's provider on `text` under `task`, its answer handed to `then`, a run, as its `input`.
                indirect case ai(task: String, text: String, then: Action)
            }

            public let kind: Kind, title: String?
            /// Surfaces v2: an inline button's icon (one of `icons` or an emoji), whether it ends something (drawn red), and
            /// what a run asks first, in the row itself.
            public let icon: String?, destructive: Bool, ask: Ask?
            /// To-do B (2026-10-17): the key it runs on in Hyper+Space (Key), and whether Hyper+Space stays open as it runs, the
            /// list asked again once it ends (`stay`), its search emptied first (`clear`, which stays too).
            public let key: Key?, stay: Bool, clear: Bool
            /// The answer to its ask or the text typed in an input block, handed on as the run message's `"input"`; set by
            /// Pilot, never decoded.
            public internal(set) var input: String?

            public init(kind: Kind, title: String? = nil, icon: String? = nil, destructive: Bool = false, ask: Ask? = nil, key: Key? = nil,
                        stay: Bool = false, clear: Bool = false) {
                self.kind = kind; self.title = title; self.icon = icon; self.destructive = destructive; self.ask = ask
                self.key = key; self.stay = stay || clear; self.clear = clear
            }

            /// It answered: `input` handed on, nothing left to ask.
            public func answered(_ input: String?) -> Action {
                var done = Action(kind: kind, title: title, icon: icon, destructive: destructive, key: key, stay: stay, clear: clear)
                done.input = input
                return done
            }

            /// It answered with typed text: trimmed and cut to `longest`; nil when blank, so nothing runs.
            public func answering(_ typed: String) -> Action? {
                let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : answered(String(text.prefix(Self.longest)))
            }

            /// The longest text an answer hands on; past it a field takes no more.
            public static let longest = 4000

            /// The icons an inline button, a note or a link may name, and a hero or a strip may give as its glyph (Q475), as Pilot
            /// draws them (SF Symbols); any other name is dropped from a button, a note or a link, an emoji kept.
            public static let icons: [String: String] = [
                "bubble": "bubble.left", "moon": "moon", "sun": "sun.max", "pencil": "pencil", "tag": "tag", "xmark": "xmark",
                "arrow.up": "arrow.up", "arrow.down": "arrow.down", "terminal": "terminal", "refresh": "arrow.clockwise",
                "chart": "chart.bar.xaxis", "plus": "plus", "reset": "arrow.counterclockwise", "info": "info.circle",
                "circle": "circle", "checkmark.circle": "checkmark.circle.fill",
                // A hero's or a strip's weather glyphs, drawn as thin line icons (Q475).
                "cloud": "cloud", "cloud.sun": "cloud.sun", "cloud.moon": "cloud.moon", "cloud.rain": "cloud.rain",
                "cloud.drizzle": "cloud.drizzle", "cloud.bolt": "cloud.bolt.rain", "cloud.snow": "cloud.snow", "cloud.fog": "cloud.fog",
                "wind": "wind",
            ]

            /// What a run asks before it runs (Surfaces v2), in the row or the button row itself, never a modal: a text to
            /// edit (starting from its own), one of its choices, or a yes to its question. The text or the choice's value
            /// arrives as `"input"`; a confirm sends nothing extra.
            public enum Ask: Equatable, Sendable {
                case text(String), choices([Choice]), confirm(String)

                public struct Choice: Equatable, Sendable {
                    public let title: String, value: String
                    public init(title: String, value: String) { self.title = title; self.value = value }
                }

                /// The most choices one ask lists.
                public static let mostChoices = 8

                /// An ask line: `{"text": …}`, `{"choices": [{"title", "value"}]}` or `{"confirm": …}`; nil for any other
                /// shape, or choices with none readable.
                init?(_ value: JSONValue?) {
                    guard case .object(let o)? = value else { return nil }
                    if case .string(let question)? = o["confirm"] { self = .confirm(question); return }
                    if case .array(let raw)? = o["choices"] {
                        let choices = raw.compactMap { item -> Choice? in
                            guard case .object(let c) = item, case .string(let title)? = c["title"] else { return nil }
                            let value: String = if case .string(let v)? = c["value"] { v } else { title }
                            return Choice(title: title, value: value)
                        }
                        guard !choices.isEmpty else { return nil }
                        self = .choices(Array(choices.prefix(Self.mostChoices)))
                        return
                    }
                    if case .string(let text)? = o["text"] { self = .text(text); return }
                    return nil
                }
            }
            public static func open(_ target: String) -> Action { Action(kind: .open(target)) }
            public static func copy(_ text: String) -> Action { Action(kind: .copy(text)) }

            /// Its own title, else its type's.
            public var label: String {
                if let title { return title }
                return switch kind {
                case .open: "Open"
                case .copy: "Copy"
                case .paste: "Paste"
                case .push: "Show"
                case .run: "Run"
                case .hud: "Show message"
                case .pilot: "Run Pilot action"
                case .timer(let timer): timer.stops ? "Stop timer" : "Start timer"
                case .alert: "Show alert"
                case .ai: "Ask AI"
                }
            }

            /// One action line; nil for an unknown type or one missing its field (a timer's seconds outside 0 to a day, or not
            /// whole), so a newer program still lists. A timer's or alert's own actions decode the same way, the unknown ones
            /// dropped, the ones past its limit too.
            init?(_ line: Line) {
                let kind: Kind? = switch line.type {
                case "open": line.url.map(Kind.open)
                case "copy": line.text.map(Kind.copy)
                case "paste": line.text.map(Kind.paste)
                case "push": line.command.map { Kind.push(command: $0, context: line.context) }
                case "run": line.command.map { Kind.run(command: $0, context: line.context) }
                case "hud": line.text.map { Kind.hud($0, sound: Extension.sound(line.sound)) }
                case "pilot": line.action.map(Kind.pilot)
                case "timer": TimerSpec(line).map(Kind.timer)
                case "alert": line.text.map { text in
                    Kind.alert(AlertSpec(text: text, note: line.note, sound: Extension.sound(line.sound),
                                         actions: Array((line.actions ?? []).compactMap(Action.init).prefix(AlertSpec.most))))
                }
                case "ai": ExtensionAI.kind(task: line.prompt, text: line.text, then: line.then.flatMap(Action.init))
                default: nil
                }
                guard let kind else { return nil }
                let icon = line.icon.flatMap { Self.icons[$0] != nil || ScriptCommand.isEmoji($0) ? $0 : nil }
                // Only a run asks: an answer has nowhere else to go.
                let ask: Ask? = if case .run = kind { Ask(line.ask) } else { nil }
                // Only a run stays: anything else ends in another app or view.
                let run: Bool = if case .run = kind { true } else { false }
                self.init(kind: kind, title: line.title, icon: icon, destructive: line.destructive ?? false, ask: ask, key: line.key.flatMap(Key.init),
                          stay: run && line.stay == true, clear: run && line.clear == true)
            }

            /// The actions under `key`, and how many were dropped as unknown or missing their field.
            static func decode<Key: CodingKey>(_ c: KeyedDecodingContainer<Key>, _ key: Key) throws -> ([Action], Int) {
                let lines = try c.decodeIfPresent([Line].self, forKey: key) ?? []
                let actions = lines.compactMap(Action.init)
                return (actions, lines.count - actions.count)
            }

            /// What an action says, every type's fields together; a class, since a timer's `end` is an action line in it.
            final class Line: Decodable {
                let type: String, url: String?, text: String?, command: String?, context: JSONValue?, action: String?, title: String?
                let sound: String?, note: String?, seconds: Double?, paused: Bool?, end: Line?, actions: [Line]?
                /// Surfaces v2.
                let icon: String?, destructive: Bool?, ask: JSONValue?
                /// To-do B.
                let key: String?, stay: Bool?, clear: Bool?
                /// An `ai` action's task and the run its answer goes to.
                let prompt: String?, then: Line?
            }
        }

        /// A row's badge (Surfaces v2): a short word in a tone, after its title; at most three.
        public struct Badge: Equatable, Sendable, Decodable {
            public static let most = 3, longest = 16
            public let text: String, tone: Tone?

            public init(text: String, tone: Tone? = nil) {
                self.text = text.count > Self.longest ? String(text.prefix(Self.longest - 1)) + "…" : text
                self.tone = tone
            }

            private enum CodingKeys: String, CodingKey { case text, tone }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let text = try c.decode(String.self, forKey: .text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "empty badge") }
                self.init(text: text, tone: (try? c.decode(String.self, forKey: .tone)).flatMap(Tone.init(rawValue:)))
            }
        }

        /// The most inline buttons a row shows.
        public static let mostInline = 3

        public let id: String?, title: String, subtitle: String?, icon: String?, keywords: String?
        /// A small picture in its emoji's place (Now playing's artwork, 2026-10-16): a PNG or JPEG sent as base64, kept only
        /// up to `largestImage` bytes; a popover row draws it, Hyper+Space shows the emoji.
        public let image: Data?
        public static let largestImage = 64 * 1024
        public let actions: [Action]
        /// Surfaces v2: its badges and its inline buttons (actions drawn as small icon buttons on the row), three each at most.
        public let badges: [Badge], inline: [Action]
        /// To-do B (2026-10-17): the heading Hyper+Space draws over it and the rows after it that share it (`section`), and a
        /// short word at its right, such as a due day (`accessory`, a string or a badge's `text` and `tone`).
        public let section: String?, accessory: Badge?
        /// How many of its actions were of a type Pilot does not know, or missing their field, and so dropped.
        public let dropped: Int

        public init(id: String? = nil, title: String, subtitle: String? = nil, icon: String? = nil, keywords: String? = nil,
                    actions: [Action], badges: [Badge] = [], inline: [Action] = [], image: Data? = nil, section: String? = nil,
                    accessory: Badge? = nil) {
            self.id = id; self.title = title; self.subtitle = subtitle; self.icon = icon; self.keywords = keywords; self.actions = actions
            self.image = image; self.section = section; self.accessory = accessory
            self.badges = Array(badges.prefix(Badge.most)); self.inline = Array(inline.prefix(Self.mostInline))
            dropped = 0
        }

        private enum CodingKeys: String, CodingKey { case id, title, subtitle, icon, keywords, actions, badges, inline, image, section, accessory }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            icon = try c.decodeIfPresent(String.self, forKey: .icon).flatMap { ScriptCommand.isEmoji($0) ? $0 : nil }
            keywords = try c.decodeIfPresent(String.self, forKey: .keywords)
            // Read leniently: a picture that is not base64, or too large, is no picture.
            image = (try? c.decode(String.self, forKey: .image)).flatMap { Data(base64Encoded: $0) }.flatMap { $0.count <= Self.largestImage ? $0 : nil }
            (actions, dropped) = try Action.decode(c, .actions)
            // Read leniently: a broken badge or button is skipped, never the row.
            badges = Array(((try? c.decode([Lenient<Badge>].self, forKey: .badges)) ?? []).compactMap(\.value).prefix(Badge.most))
            inline = Array(((try? c.decode([Lenient<Action.Line>].self, forKey: .inline)) ?? []).compactMap { $0.value.flatMap(Action.init) }
                .prefix(Self.mostInline))
            section = (try? c.decode(String.self, forKey: .section)).flatMap { $0.isEmpty ? nil : $0 }
            // A word alone, or a badge's text and tone.
            accessory = (try? c.decode(String.self, forKey: .accessory)).flatMap { $0.isEmpty ? nil : Badge(text: $0) }
                ?? (try? c.decode(Badge.self, forKey: .accessory))
        }
    }
}

extension Extension {
    /// A detail command's answer (card agent-bo-95423245): markdown Pilot renders, facts shown beside it, and actions
    /// under Cmd+K, the first Return's.
    public struct Detail: Equatable, Sendable, Decodable {
        public struct Fact: Equatable, Sendable, Decodable {
            public let label: String, text: String
            public init(label: String, text: String) { self.label = label; self.text = text }
        }

        public let markdown: String, metadata: [Fact], actions: [Item.Action]
        /// How many of its actions were of a type Pilot does not know, or missing their field, and so dropped.
        public let dropped: Int

        public init(markdown: String, metadata: [Fact], actions: [Item.Action]) {
            self.markdown = markdown; self.metadata = metadata; self.actions = actions
            dropped = 0
        }

        private enum CodingKeys: String, CodingKey { case markdown, metadata, actions }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
            metadata = try c.decodeIfPresent([Fact].self, forKey: .metadata) ?? []
            (actions, dropped) = try Item.Action.decode(c, .actions)
        }
    }
}

extension Extension {
    /// A `timer` action (Pomodoro as an extension, 2026-10-10): Pilot's one countdown, shown with `title` in the Timer bar
    /// item, the dropdown's Now block and Home's Timer block. `seconds` from 1 to a day; 0 stops the timer if it is this
    /// extension's. Paused, it shows the time held and neither counts nor ends. At zero Pilot runs `end` as the extension's
    /// action (none: a HUD says the title is done); `actions`, at most four, are its buttons.
    public struct TimerSpec: Equatable, Sendable {
        /// The longest timer, a day, and the most buttons it shows.
        public static let longest = 86_400, most = 4

        public let title: String, seconds: Int, paused: Bool, end: Item.Action?, actions: [Item.Action]

        public init(title: String, seconds: Int, paused: Bool = false, end: Item.Action? = nil, actions: [Item.Action] = []) {
            self.title = title; self.seconds = seconds; self.paused = paused; self.end = end; self.actions = actions
        }

        /// `"seconds": 0`: stop the timer, if it is this extension's.
        public var stops: Bool { seconds == 0 }

        /// What a timer line says; nil when its seconds are missing, not whole, or outside 0 to a day. The title is
        /// "Timer" when it has none.
        init?(_ line: Item.Action.Line) {
            guard let given = line.seconds, given.rounded() == given, (0...Double(Self.longest)).contains(given) else { return nil }
            self.init(title: line.title ?? "Timer", seconds: Int(given), paused: line.paused ?? false, end: line.end.flatMap(Item.Action.init),
                      actions: Array((line.actions ?? []).compactMap(Item.Action.init).prefix(Self.most)))
        }

        /// "24:59", or "1:02:03" from an hour up: the time left, `seconds` whole.
        public static func countdown(_ seconds: Int) -> String {
            let s = max(seconds, 0)
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
        }
    }

    /// An `alert` action: Pilot's own HUD panel that stays until a button is pressed, `text` its heading and `note` its
    /// second line, a button per action (at most three, the first primary) or OK when there are none; `sound` plays as it
    /// shows. Any button closes it, then runs its action as the extension's.
    public struct AlertSpec: Equatable, Sendable {
        /// The most buttons an alert shows.
        public static let most = 3

        public let text: String, note: String?, sound: String?, actions: [Item.Action]

        public init(text: String, note: String? = nil, sound: String? = nil, actions: [Item.Action] = []) {
            self.text = text; self.note = note; self.sound = sound; self.actions = actions
        }
    }

    /// The macOS alert sounds a `hud` or `alert` may name, by their names in /System/Library/Sounds.
    public static let sounds: Set<String> = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
                                             "Sosumi", "Submarine", "Tink"]

    /// `name` when it is one of those sounds; nil for any other, which plays nothing.
    static func sound(_ name: String?) -> String? { name.flatMap { sounds.contains($0) ? $0 : nil } }
}

/// A list or detail command's answer: its items, its detail, or why there is nothing (cards agent-bo-95423243, 245).
public enum ListOutcome: Equatable, Sendable { case items([Extension.Item]), detail(Extension.Detail), error(String) }

extension ExtensionRun {
    /// A list's program must answer within this, or the error row shows and it is stopped.
    public static let listTimeout: Duration = .seconds(2)

    /// Runs a list or detail command with `query` in its run message and reads its answer: the last list or detail message; an error
    /// message, a line that is not the protocol, a failed exit or silence is the reason the error row gives. Concurrent,
    /// so a large answer is decoded off the main actor that runs the key tap.
    @concurrent public static func list(_ command: Extension.Command, query: String, context: JSONValue? = nil, inputs: Inputs,
                            environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                            timeout: Duration = listTimeout) async -> ListOutcome {
        let output: String
        do { output = try await self.output(command, query: query, context: context, inputs: inputs, environment: pilot, timeout: timeout) }
        catch { return .error(reason(error, timeout: timeout)) }
        return answer(output)
    }

    /// Why a view's or a surface's program gave no answer: too slow, a failed exit, or the error itself.
    static func reason(_ error: any Error, timeout: Duration) -> String {
        switch error {
        case is ChildProcess.TimedOut: late(timeout)
        case let failure as ChildProcess.Failure: "stopped with an error: \(failure.message.prefix(120))"
        default: error.localizedDescription
        }
    }

    /// The error row's reason when a view's program is too slow.
    static func late(_ timeout: Duration) -> String {
        "did not answer in \(String(format: "%g", timeout.inSeconds)) s"
    }

    private struct Answer: Decodable { let type: String, text: String?, items: [Extension.Item]? }

    /// The list, the detail or the reason in what a view's program printed: the first error, else the last answer.
    static func answer(_ output: String) -> ListOutcome {
        var last: ListOutcome?
        for line in output.split(whereSeparator: \.isNewline) {
            switch reply(line) {
            case .answer(.error(let reason)): return .error(reason)
            case .answer(let answer): last = answer
            case .plain: return .error(unreadable)
            case .skip: continue
            }
        }
        return last ?? .error("sent no list")
    }

    public static let unreadable = "sent a line Pilot can't read"

    /// What one printed line is: an answer (a list, a detail or an error message), a plain line outside the message
    /// format, or nothing to act on (a blank line or a message of a type Pilot does not know).
    enum Reply: Equatable { case answer(ListOutcome), plain, skip }

    static func reply(_ line: some StringProtocol) -> Reply {
        guard !line.allSatisfy(\.isWhitespace) else { return .skip }
        let data = Data(line.utf8), decoder = JSONDecoder()
        guard let answer = try? decoder.decode(Answer.self, from: data) else { return .plain }
        switch answer.type {
        case "error": return .answer(.error("says: \(answer.text ?? "it failed")"))
        case "list": return .answer(.items(answer.items ?? []))
        case "detail": return .answer((try? decoder.decode(Extension.Detail.self, from: data)).map(ListOutcome.detail) ?? .error(unreadable))
        default: return .skip
        }
    }
}

/// An extension's list in the menu (card agent-bo-95423243): its items as picker rows, each found by the index in its
/// id, and the one error row.
public enum ExtensionList {
    /// The items as rows: the program's order kept as answers when it filters, rows Pilot ranks when Pilot does.
    public static func entries(_ items: [Extension.Item], of command: Extension.Command) -> [MenuEntry] {
        let ownOrder = command.filter == .program
        return items.enumerated().map { index, item in
            var row = MenuEntry(title: item.title, target: .action("\(command.actionID)#\(index)"), detail: item.accessory?.text,
                                keywords: item.keywords, isAnswer: ownOrder, subtitle: item.subtitle, icon: .command(emoji: item.icon ?? command.icon))
            row.ownActions = item.actions.map(\.label)
            if item.actions.contains(where: { $0.key != nil }) { row.ownKeys = item.actions.map(\.key) }
            row.section = item.section
            return row
        }
    }

    /// A detail as the view's one row, never ranked: the panel draws its detail in place of the list, and Return and
    /// Cmd+K act on its actions as on an item's (card agent-bo-95423245).
    public static func detail(_ detail: Extension.Detail, of command: Extension.Command) -> MenuEntry {
        var row = MenuEntry(title: command.title, target: .action("\(command.actionID)#0"), isAnswer: true, icon: .command(emoji: command.icon))
        row.ownActions = detail.actions.map(\.label)
        row.extensionDetail = detail
        return row
    }

    /// The row that says why there are no items, under the extension's title.
    public static func error(_ reason: String, of command: Extension.Command, in title: String) -> MenuEntry {
        MenuEntry(title: "\(title) \(reason)", target: .action("\(command.actionID)#error"), isAnswer: true, icon: .command(emoji: command.icon))
    }

    /// Whether a Pilot action may run `id`: only a registered action, never a shell or other drive route, a script, a
    /// quicklink, an app link or another extension's command, which carry more power than an extension row should.
    public static func allowsPilot(_ id: String, isRegistered: (String) -> Bool) -> Bool {
        isRegistered(id) && !["drive.", "scripts.run:", "links.open:", "apps.", Extension.prefix].contains { id.hasPrefix($0) }
    }

    /// What an open action opens: a URL with a scheme, or a path from / or ~; nil for anything else.
    public static func url(_ target: String) -> URL? {
        if target.hasPrefix("/") || target.hasPrefix("~") { return URL(filePath: NSString(string: target).expandingTildeInPath) }
        guard let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url
    }

    /// The item a row stands for; nil for the error row.
    public static func item(at row: MenuEntry, in items: [Extension.Item]) -> Extension.Item? {
        guard case .action(let id) = row.target, let hash = id.lastIndex(of: "#"), let index = Int(id[id.index(after: hash)...]),
              items.indices.contains(index) else { return nil }
        return items[index]
    }
}
