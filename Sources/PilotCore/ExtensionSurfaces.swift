import Foundation

/// An extension's surfaces (story 161, ADR 0010 amended; design https://claude.ai/artifact/9vfiVdLcrd6unBF9sJCBqx): beside
/// its Hyper+Space branch, which every extension has, its manifest may declare a page in the app window and a top-bar
/// item. Each names one of its commands, which answers with blocks Pilot lays out in its own style (a bar command with a
/// short text and a tone first), and how often Pilot asks again:
///
///     "surfaces": { "page": { "command": "usage", "every": 60 }, "bar": { "command": "bar", "every": 120 } }
extension Extension {
    /// One declared surface: the command Pilot runs for it and its pace in seconds, held to the surface's floor.
    public struct Surface: Equatable, Sendable {
        /// A popover is the bar item's own, asked on a click with its bar command (Surfaces v2); never declared.
        public enum Kind: String, Sendable { case page, bar, popover }

        public let kind: Kind, command: Command, every: Int

        public init(kind: Kind, command: Command, every: Int) { self.kind = kind; self.command = command; self.every = every }

        /// A page is asked again every 10 s at most often, 60 s when the manifest says nothing; a bar item every 60 s at
        /// most often, 120 s by default, so three of them stay cheap (lean budgets, story 142). An hour at the longest.
        public static func pace(_ kind: Kind, asked: Double?) -> Int {
            let (floor, standard) = kind == .bar ? (60, 120) : (10, 60)
            guard let asked, asked.isFinite else { return standard }
            return min(max(Int(asked.rounded()), floor), 3600)
        }
    }

    /// The manifest's `surfaces`: a page and a bar item, each an object with `command` and an optional `every`; any other
    /// shape declares nothing, so a later Pilot's surface never skips the folder. A surface naming a command the extension
    /// lacks does: its author's mistake, said on the Extensions page.
    static func surfaces(_ value: JSONValue?, commands: [Command]) throws -> (page: Surface?, bar: Surface?) {
        guard case .object(let declared)? = value else { return (nil, nil) }
        func surface(_ kind: Surface.Kind) throws -> Surface? {
            guard case .object(let fields)? = declared[kind.rawValue], case .string(let name)? = fields["command"] else { return nil }
            guard let command = commands.first(where: { $0.name == name }) else {
                throw Problem.unknownSurfaceCommand(surface: kind.rawValue, command: name)
            }
            let every: Double? = if case .number(let n)? = fields["every"] { n } else { nil }
            return Surface(kind: kind, command: command, every: Surface.pace(kind, asked: every))
        }
        return (try surface(.page), try surface(.bar))
    }

    /// How a stat, a meter or a bar item reads: fine, warn or alert; none is plain.
    public enum Tone: String, Equatable, Sendable {
        case fine, warn, alert

        var rank: Int { switch self { case .fine: 0; case .warn: 1; case .alert: 2 } }
    }

    /// One block of a page or a bar item's popover (v1: stats, meter, list, markdown, buttons; v2: section, chat, input;
    /// omarchy-ideas T4: hero, strip; no charts yet). Unknown types are skipped, so a later block never breaks an older
    /// Pilot; the run message's `pilot.blocks` names the ones this Pilot draws (`kinds`), so an extension can send the
    /// older ones to an older Pilot.
    public indirect enum Block: Equatable, Sendable {
        /// Numbers side by side, at most six.
        case stats([Stat])
        /// A share filled, 0 to 100, with its label and a note ("resets 14:20").
        case meter(Meter)
        /// Rows as a list command's items, each with its actions (Return's first), under an optional title; at most 50.
        /// 2026-10-17: on a page, a `reorder` lets Sven drag its rows (or move one with ⌥↑ ⌥↓), each move run as its command.
        case list(title: String?, items: [Item], reorder: Reorder? = nil)
        /// Text Pilot renders as the detail view does.
        case markdown(String)
        /// A row of buttons, each an action as today; at most six, the first primary.
        case buttons([Item.Action])
        /// A card of blocks under a title and a subtitle (Surfaces v2: AI usage's provider), each with an aside at its right
        /// (the account, the plan); one level deep, a section in a section skipped. Q138: a provider `icon` before its title,
        /// its `help` on hover over its head; in a popover the aside note is a chip by the title, and a section with no
        /// blocks is one quiet line (an account not asked).
        case section(title: String?, subtitle: String?, aside: String? = nil, asideNote: String? = nil, blocks: [Block],
                     icon: Gauge.Icon? = nil, help: String? = nil)
        /// A conversation (Surfaces v2: a Ghostex session), its last 20 messages, tool turns folded to one grey line.
        case chat(Chat)
        /// A reply box (Surfaces v2): Return runs its action, Option+Return its alt, the typed text handed on as `"input"`.
        case input(Input)
        /// A big now (Weather): a glyph, a value and its unit, a place, and at most three small stats under it.
        case hero(Hero)
        /// Columns side by side (Weather's days): each a label, a glyph, a high and a low; at most seven.
        case strip([Column])
        /// Q138: one small quiet line (AI usage's reset credits): an icon, its text, an aside at its right, the rest on hover.
        case note(Note)
        /// Q138: a row of small links (AI usage's status pages, dashboards, Add account), each a word, an icon or a toned
        /// dot; a click runs its action, or lists them when it has several. Last in a popover, it sits beside Open page.
        case links([Link])

        /// The block types this Pilot draws, by the name a block line's `type` gives.
        enum Kind: String, CaseIterable { case stats, meter, list, markdown, buttons, section, chat, input, hero, strip, note, links }

        /// Every block type this Pilot draws, as the run message's `pilot.blocks` names them.
        public static let kinds = Kind.allCases.map(\.rawValue)

        /// A chat block: a popover showing one is wider, and scrolls from its newest message.
        public var isChat: Bool { if case .chat = self { true } else { false } }

        /// A hero or a strip, or a section holding one: a popover showing one is as wide as the calendar's, so a week fits.
        public var isWide: Bool {
            switch self {
            case .hero, .strip: true
            case .section(_, _, _, _, let blocks, _, _): blocks.contains(where: \.isWide)
            default: false
            }
        }

        public struct Chat: Equatable, Sendable {
            public struct Message: Equatable, Sendable {
                public enum Role: String, Sendable { case user, assistant, tool }
                public let role: Role, text: String, at: Date?
                public init(role: Role, text: String, at: Date? = nil) { self.role = role; self.text = text; self.at = at }
            }

            /// The most messages a chat shows, the last ones.
            public static let most = 20

            public let messages: [Message], working: Bool

            public init(messages: [Message], working: Bool = false) {
                self.messages = Array(messages.suffix(Self.most)); self.working = working
            }

            /// The messages as drawn: tool turns in a row fold to one line, its own text when alone, "ran 3 tools" when not.
            public var shown: [Message] {
                var out: [Message] = [], tools: [Message] = []
                func fold() {
                    guard let last = tools.last else { return }
                    out.append(tools.count == 1 ? last : Message(role: .tool, text: "ran \(tools.count) tools", at: last.at))
                    tools = []
                }
                for message in messages {
                    if message.role == .tool { tools.append(message); continue }
                    fold()
                    out.append(message)
                }
                fold()
                return out
            }
        }

        public struct Input: Equatable, Sendable {
            public let placeholder: String?, action: Item.Action, alt: Item.Action?
            /// 2026-10-17: a live box (`"live": true`) runs its action as Sven types, once typing pauses this long
            /// (`"debounce"` in ms, held to `pauses`); nil runs it on Return only.
            public let live: Duration?

            public init(placeholder: String? = nil, action: Item.Action, alt: Item.Action? = nil, live: Duration? = nil) {
                self.placeholder = placeholder; self.action = action; self.alt = alt; self.live = live
            }

            /// A live box's pause by default, and the shortest and longest it may ask, in ms.
            public static let pause = 250, pauses = 50...2000

            /// The pause a block line asks: none unless `live`, else its `debounce` held to `pauses`, or the default.
            static func live(_ live: Bool?, debounce: Double?) -> Duration? {
                guard live == true else { return nil }
                let ms = debounce.flatMap { $0.isFinite ? min(max(Int($0.rounded()), pauses.lowerBound), pauses.upperBound) : nil } ?? pause
                return .milliseconds(ms)
            }

            /// What Return (`alt`: Option+Return) runs with `text`; nil for blank text, or Option+Return without an alt.
            public func submit(_ text: String, alt useAlt: Bool = false) -> Item.Action? {
                (useAlt ? alt : action)?.answering(text)
            }

            /// What a live box runs as `text` changes: its action with the text trimmed and cut to `longest`, blank too, so
            /// an emptied box can clear what it searched.
            public func typed(_ text: String) -> Item.Action {
                action.answered(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Item.Action.longest)))
            }
        }

        /// A list's reorder (2026-10-17, Markets' watchlist): the no-view command a move runs, handed the row's `id` as `key`
        /// and its place after the move, from 0, as `to`. A row without an id does not move.
        public struct Reorder: Equatable, Sendable {
            public let command: String
            public init(command: String) { self.command = command }

            /// A `{"command": …}` line; nil for any other shape.
            init?(_ value: JSONValue?) {
                guard case .object(let o)? = value, case .string(let command)? = o["command"], !command.isEmpty else { return nil }
                self.command = command
            }

            /// The run a move is: `{"key": key, "to": to}` as its context.
            public func action(key: String, to: Int) -> Item.Action {
                Item.Action(kind: .run(command: command, context: .object(["key": .string(key), "to": .number(Double(to))])), title: "Move")
            }

            /// `items` with the row `key` moved to `to`; nil when no row has that id, `to` is outside the list, or the row
            /// is there already.
            public static func moving(_ items: [Item], key: String, to: Int) -> [Item]? {
                guard let from = items.firstIndex(where: { $0.id == key }), items.indices.contains(to), from != to else { return nil }
                var moved = items
                moved.insert(moved.remove(at: from), at: to)
                return moved
            }
        }

        public struct Stat: Equatable, Sendable {
            public let label: String, value: String, tone: Tone?
            public init(label: String, value: String, tone: Tone? = nil) { self.label = label; self.value = value; self.tone = tone }
        }

        public struct Hero: Equatable, Sendable {
            public let glyph: String?, value: String, unit: String?, place: String?, tone: Tone?, stats: [Stat]
            public init(glyph: String? = nil, value: String, unit: String? = nil, place: String? = nil, tone: Tone? = nil, stats: [Stat] = []) {
                self.glyph = glyph; self.value = value; self.unit = unit; self.place = place; self.tone = tone
                self.stats = Array(stats.prefix(Block.mostHeroStats))
            }
        }

        /// One column of a strip: its label ("Thu") and at least one of a glyph, a high and a low.
        public struct Column: Equatable, Sendable {
            public let label: String, glyph: String?, high: String?, low: String?
            public init(label: String, glyph: String? = nil, high: String? = nil, low: String? = nil) {
                self.label = label; self.glyph = glyph; self.high = high; self.low = low
            }
        }

        public struct Note: Equatable, Sendable {
            /// `icon` one of the inline buttons' (Item.Action.icons); any other name is dropped.
            public let text: String, aside: String?, help: String?, icon: String?
            public init(text: String, aside: String? = nil, help: String? = nil, icon: String? = nil) {
                self.text = text; self.aside = aside; self.help = help; self.icon = icon.flatMap { Item.Action.icons[$0] == nil ? nil : $0 }
            }
        }

        /// One link of a links row: at least a title or an icon, and at least one action.
        public struct Link: Equatable, Sendable {
            /// `icon` one of Item.Action.icons; `tone` a dot before the title; `word` after it in the text colour ("minor").
            public let title: String?, icon: String?, tone: Tone?, word: String?, help: String?, actions: [Item.Action]
            public init?(title: String? = nil, icon: String? = nil, tone: Tone? = nil, word: String? = nil, help: String? = nil,
                         actions: [Item.Action]) {
                let icon = icon.flatMap { Item.Action.icons[$0] == nil ? nil : $0 }
                guard title != nil || icon != nil, !actions.isEmpty else { return nil }
                self.title = title; self.icon = icon; self.tone = tone; self.word = word; self.help = help
                self.actions = Array(actions.prefix(Block.mostButtons))
            }

            /// Its tooltip and spoken name: its help, else its title, else its first action's.
            public var label: String { help ?? title ?? actions[0].label }
        }

        public struct Meter: Equatable, Sendable {
            public let label: String, percent: Double, note: String?, tone: Tone?
            /// Q138: words shown on hover (a popover's pace, once its note is left out).
            public let help: String?
            /// When its window resets (Surfaces v2): Pilot ticks the countdown itself, so the extension need not run.
            public let resetsAt: Date?
            /// A tick on the track, 0 to 100 (AI usage: where the share left should be by now), its tone (fine in reserve,
            /// alert in deficit; none the text's colour), and the figure shown in place of "N %" ("94% left").
            public let mark: Double?, markTone: Tone?, value: String?
            public init(label: String, percent: Double, note: String? = nil, tone: Tone? = nil, resetsAt: Date? = nil,
                        mark: Double? = nil, value: String? = nil, markTone: Tone? = nil, help: String? = nil) {
                self.label = label; self.percent = min(max(percent, 0), 100); self.note = note; self.tone = tone; self.resetsAt = resetsAt
                self.help = help
                self.mark = mark.flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }; self.value = value; self.markTone = markTone
            }

            /// A popover's "Resets 11:49", on a 24-hour clock: "Resets tomorrow 09:00", "Resets Thu 20:00" within six days,
            /// "Resets 15 Oct 20:00" past them.
            public static func resets(at resetsAt: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                      locale: Locale = .autoupdatingCurrent) -> String {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: resetsAt)).day ?? 0
                func say(_ format: Date.FormatString) -> String {
                    resetsAt.formatted(Date.VerbatimFormatStyle(format: format, locale: locale, timeZone: calendar.timeZone, calendar: calendar))
                }
                let day = switch days {
                case 0: ""
                case 1: "tomorrow "
                case 2...6: say("\(weekday: .abbreviated) ")
                default: say("\(day: .defaultDigits) \(month: .abbreviated) ")
                }
                return "Resets " + day + say("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)")
            }

            /// "resets 12:40 · in 1 h 22 min", "resets tomorrow 09:00 · in 13 h 5 min", "resets Thu 20:00 · in 2 d 4 h";
            /// once past, "reset at 12:40". Its time in `locale`'s own clock.
            public static func countdown(to resetsAt: Date, now: Date, calendar: Calendar = .autoupdatingCurrent,
                                         locale: Locale = .autoupdatingCurrent) -> String {
                var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
                time.timeZone = calendar.timeZone
                let clock = resetsAt.formatted(time)
                guard resetsAt > now else { return "reset at \(clock)" }
                var weekday = Date.FormatStyle(locale: locale).weekday(.abbreviated)
                weekday.timeZone = calendar.timeZone
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).map { calendar.isDate(resetsAt, inSameDayAs: $0) } ?? false
                let day = calendar.isDate(resetsAt, inSameDayAs: now) ? "" : tomorrow ? "tomorrow " : resetsAt.formatted(weekday) + " "
                let minutes = Int((resetsAt.timeIntervalSince(now) / 60).rounded(.up)), d = minutes / 1440, h = minutes / 60 % 24, m = minutes % 60
                let left = d > 0 ? "\(d) d \(h) h" : h > 0 ? "\(h) h \(m) min" : minutes <= 1 ? "under a minute" : "\(m) min"
                return "resets \(day)\(clock) · in \(left)"
            }
        }

        /// The most blocks one answer shows, and the most of each block's parts; the rest are dropped.
        public static let most = 24, mostStats = 6, mostItems = 50, mostButtons = 6, mostHeroStats = 3, mostColumns = 7, mostLinks = 6
    }

    /// A bar command's answer: the item's short text (at most 24 characters), its gauges (Surfaces v2), its tone, and the
    /// blocks its popover shows until the popover's own answer comes. Neither text nor gauges hides the item.
    public struct BarAnswer: Equatable, Sendable {
        public static let longest = 24

        public let text: String, tone: Tone?, blocks: [Block], gauges: [Gauge]

        public init(text: String, tone: Tone? = nil, blocks: [Block] = [], gauges: [Gauge] = []) {
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            self.text = line.count > Self.longest ? String(line.prefix(Self.longest - 1)) + "…" : line
            self.tone = tone; self.blocks = blocks; self.gauges = Array(gauges.prefix(Gauge.most))
        }

        /// Whether the item draws: a text or a gauge to show.
        public var shows: Bool { !text.isEmpty || !gauges.isEmpty }

        /// The strongest tone it carries, its own or a gauge's: alert over warn over fine.
        public var loudest: Tone? {
            ([tone] + gauges.map(\.tone)).compactMap { $0 }.max { $0.rank < $1.rank }
        }
    }

    /// One gauge of a bar item's icon (Surfaces v2, CodexBar's style): a provider's glyph, a label of at most five
    /// characters (a ticker: Markets' SPY), one or two thin meters stacked, each 0 to 100 (AI usage: the session over the
    /// week), and a short text ("66%"), the meters and text in its tone. At most three per item.
    public struct Gauge: Equatable, Sendable {
        public static let most = 3, mostMeters = 2, longestLabel = 5, longestText = 6

        /// Pilot's own provider glyphs, drawn by Pilot (no logo files).
        public enum Icon: String, Sendable {
            case claude, openai

            public var title: String { switch self { case .claude: "Claude"; case .openai: "OpenAI" } }
        }

        public let label: String, meters: [Double], tone: Tone?, icon: Icon?, text: String

        public init(label: String = "", meters: [Double] = [], tone: Tone? = nil, icon: Icon? = nil, text: String = "") {
            self.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.longestLabel))
            self.meters = Array(meters.filter(\.isFinite).prefix(Self.mostMeters)).map { min(max($0, 0), 100) }
            self.tone = tone; self.icon = icon
            self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.longestText))
        }

        /// Whether it draws: a meter, a glyph or a text.
        public var shows: Bool { !meters.isEmpty || icon != nil || !text.isEmpty }

        /// A gauge line: nil without a meter, a known glyph or a text to draw.
        init?(_ value: JSONValue) {
            guard case .object(let o) = value else { return nil }
            let raw: [JSONValue] = if case .array(let a)? = o["meters"] { a } else { [] }
            let meters = raw.compactMap { if case .number(let n) = $0, n.isFinite { n } else { nil } }
            let string = { (key: String) -> String? in if case .string(let s)? = o[key] { s } else { nil } }
            self.init(label: string("label") ?? "", meters: meters, tone: string("tone").flatMap(Tone.init(rawValue:)),
                      icon: string("icon").flatMap(Icon.init(rawValue:)), text: string("text") ?? "")
            guard shows else { return nil }
        }

        /// The gauges in a bar line's `gauges`, the broken ones skipped, the first three.
        static func gauges(_ value: JSONValue?) -> [Gauge] {
            guard case .array(let raw)? = value else { return [] }
            return Array(raw.compactMap(Gauge.init).prefix(most))
        }
    }
}

extension Extension {
    /// A run asking before it runs (Surfaces v2), in its row or its button row: what is typed so far, then the action to
    /// run with the answer as `"input"`, or nothing yet.
    public struct Asking: Equatable, Sendable {
        public let action: Item.Action, ask: Item.Action.Ask
        public var text: String

        /// Nil when `action` asks nothing, so it runs at once.
        public init?(_ action: Item.Action) {
            guard let ask = action.ask else { return nil }
            self.action = action; self.ask = ask
            text = if case .text(let start) = ask { start } else { "" }
        }

        /// Return or Save: a text ask runs with the text, trimmed, when there is some; a confirm runs with nothing extra; a
        /// choices ask waits for its pick.
        public func save() -> Item.Action? {
            switch ask {
            case .text: action.answering(text)
            case .confirm: action.answered(nil)
            case .choices: nil
            }
        }

        /// A choice picked: runs with its value.
        public func pick(_ choice: Item.Action.Ask.Choice) -> Item.Action { action.answered(choice.value) }

        /// The confirm button's word: the action's title without its "…", else OK.
        public var yes: String {
            let title = action.title.map { $0.hasSuffix("…") ? String($0.dropLast()) : $0 } ?? ""
            return title.isEmpty ? "OK" : title
        }
    }
}

extension Extension.Block {
    /// What a block line says, every type's fields together.
    struct Line: Decodable {
        let type: String
        let title: String?, label: String?, text: String?, note: String?, tone: String?, percent: Double?
        /// Surfaces v2: a section's subtitle, asides and blocks, a meter's reset time in seconds since 1970, mark, its tone and
        /// value; a chat's messages and whether it works; an input's placeholder, action and alt.
        let subtitle: String?, aside: String?, asideNote: String?, blocks: [Line]?, resetsAt: Double?, mark: Double?, markTone: String?
        let messages: [Lenient<MessageLine>]?, working: Bool?, placeholder: String?, action: Extension.Item.Action.Line?, alt: Extension.Item.Action.Line?
        /// 2026-10-17: a list's reorder, an input's live and its debounce in ms.
        let reorder: JSONValue?, live: Bool?, debounce: Double?
        let actions: [Extension.Item.Action.Line]?
        /// A meter's value and a hero's (omarchy-ideas T4), as written: a meter reads only a string, a hero a number too.
        let value: JSONValue?
        /// omarchy-ideas T4: a hero's glyph, unit and place, its small stats in `items`; a strip's columns are its `items`.
        let glyph: String?, unit: String?, place: String?
        /// Q138: a meter's, a section's, a note's or a link's words on hover; a section's provider icon, a note's or link's
        /// icon (both read from `icon`); a link's word.
        let help: String?, icon: String?, word: String?
        /// `items` read both ways from the one key: a stats block's as any JSON, a list's as items, each broken one skipped.
        let items: JSONValue?, rows: [Lenient<Extension.Item>]?
        /// Q138: a links block's `items`, each broken one skipped.
        let links: [Lenient<LinkLine>]?

        private enum CodingKeys: String, CodingKey {
            case type, title, label, text, note, tone, percent, actions, items, subtitle, aside, asideNote, blocks, resetsAt, mark, markTone, value, messages,
                 working, placeholder, action, alt, glyph, unit, place, help, icon, word, reorder, live, debounce
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            (title, label, text, note, tone) = (try? c.decode(String.self, forKey: .title), try? c.decode(String.self, forKey: .label),
                                                try? c.decode(String.self, forKey: .text), try? c.decode(String.self, forKey: .note),
                                                try? c.decode(String.self, forKey: .tone))
            percent = try? c.decode(Double.self, forKey: .percent)
            actions = try? c.decode([Extension.Item.Action.Line].self, forKey: .actions)
            items = try? c.decode(JSONValue.self, forKey: .items)
            rows = try? c.decode([Lenient<Extension.Item>].self, forKey: .items)
            links = try? c.decode([Lenient<LinkLine>].self, forKey: .items)
            subtitle = try? c.decode(String.self, forKey: .subtitle)
            (aside, asideNote) = (try? c.decode(String.self, forKey: .aside), try? c.decode(String.self, forKey: .asideNote))
            blocks = (try? c.decode([Lenient<Line>].self, forKey: .blocks))?.compactMap(\.value)
            resetsAt = (try? c.decode(Double.self, forKey: .resetsAt)).flatMap { $0.isFinite ? $0 : nil }
            mark = try? c.decode(Double.self, forKey: .mark)
            markTone = try? c.decode(String.self, forKey: .markTone)
            value = try? c.decode(JSONValue.self, forKey: .value)
            messages = try? c.decode([Lenient<MessageLine>].self, forKey: .messages)
            working = try? c.decode(Bool.self, forKey: .working)
            placeholder = try? c.decode(String.self, forKey: .placeholder)
            action = try? c.decode(Extension.Item.Action.Line.self, forKey: .action)
            alt = try? c.decode(Extension.Item.Action.Line.self, forKey: .alt)
            (glyph, unit, place) = (try? c.decode(String.self, forKey: .glyph), try? c.decode(String.self, forKey: .unit),
                                    try? c.decode(String.self, forKey: .place))
            (help, icon, word) = (try? c.decode(String.self, forKey: .help), try? c.decode(String.self, forKey: .icon),
                                  try? c.decode(String.self, forKey: .word))
            reorder = try? c.decode(JSONValue.self, forKey: .reorder)
            (live, debounce) = (try? c.decode(Bool.self, forKey: .live), try? c.decode(Double.self, forKey: .debounce))
        }
    }

    /// One link of a links block as written.
    struct LinkLine: Decodable {
        let title: String?, icon: String?, tone: String?, word: String?, help: String?
        let actions: [Lenient<Extension.Item.Action.Line>]?
    }

    /// One chat message line: its role (user, assistant or tool; any other skipped), its text, when in seconds since 1970.
    struct MessageLine: Decodable {
        let role: String, text: String, at: Double?

        var message: Chat.Message? {
            guard let role = Chat.Message.Role(rawValue: role) else { return nil }
            return Chat.Message(role: role, text: text, at: at.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
        }
    }

    /// One block; nil for an unknown type or one missing what it needs (a meter's percent, a markdown's text), or a
    /// section inside a section (`nested`).
    init?(_ line: Line, nested: Bool = false) {
        let tone = { (raw: String?) in raw.flatMap(Extension.Tone.init(rawValue:)) }
        switch Kind(rawValue: line.type) {
        case .stats?:
            let stats = Self.stats(line.items)
            guard !stats.isEmpty else { return nil }
            self = .stats(Array(stats.prefix(Self.mostStats)))
        case .meter?:
            guard let label = line.label, let percent = line.percent, percent.isFinite else { return nil }
            let value: String? = if case .string(let s)? = line.value { s } else { nil }
            self = .meter(Meter(label: label, percent: percent, note: line.note, tone: tone(line.tone),
                                resetsAt: line.resetsAt.map { Date(timeIntervalSince1970: $0) }, mark: line.mark, value: value,
                                markTone: tone(line.markTone), help: line.help))
        case .list?:
            guard let rows = line.rows else { return nil }
            self = .list(title: line.title, items: Array(rows.compactMap(\.value).prefix(Self.mostItems)), reorder: Reorder(line.reorder))
        case .markdown?:
            guard let text = line.text else { return nil }
            self = .markdown(text)
        case .buttons?:
            let actions = (line.actions ?? []).compactMap(Extension.Item.Action.init)
            guard !actions.isEmpty else { return nil }
            self = .buttons(Array(actions.prefix(Self.mostButtons)))
        case .section?:
            let blocks = (line.blocks ?? []).compactMap { Self($0, nested: true) }
            guard !nested, line.title != nil || !blocks.isEmpty else { return nil }
            self = .section(title: line.title, subtitle: line.subtitle, aside: line.aside, asideNote: line.asideNote,
                            blocks: Array(blocks.prefix(Self.most)), icon: line.icon.flatMap(Extension.Gauge.Icon.init(rawValue:)), help: line.help)
        case .chat?:
            guard let lines = line.messages else { return nil }
            self = .chat(Chat(messages: lines.compactMap { $0.value?.message }, working: line.working ?? false))
        case .input?:
            // Only a run takes typed text; an alt of another kind is dropped, an action of another kind drops the block.
            let run = { (line: Extension.Item.Action.Line?) -> Extension.Item.Action? in
                guard let action = line.flatMap(Extension.Item.Action.init), case .run = action.kind else { return nil }
                return action
            }
            guard let action = run(line.action) else { return nil }
            self = .input(Input(placeholder: line.placeholder, action: action, alt: run(line.alt), live: Input.live(line.live, debounce: line.debounce)))
        case .hero?:
            guard let value = Self.text(line.value) else { return nil }
            self = .hero(Hero(glyph: line.glyph, value: value, unit: line.unit, place: line.place, tone: tone(line.tone), stats: Self.stats(line.items)))
        case .strip?:
            guard case .array(let raw)? = line.items else { return nil }
            let columns = raw.compactMap { item -> Column? in
                guard case .object(let o) = item, case .string(let label)? = o["label"] else { return nil }
                let (glyph, high, low) = (Self.text(o["glyph"]), Self.text(o["high"]), Self.text(o["low"]))
                guard glyph != nil || high != nil || low != nil else { return nil }
                return Column(label: label, glyph: glyph, high: high, low: low)
            }
            guard !columns.isEmpty else { return nil }
            self = .strip(Array(columns.prefix(Self.mostColumns)))
        case .note?:
            guard let text = line.text, !text.isEmpty else { return nil }
            self = .note(Note(text: text, aside: line.aside, help: line.help, icon: line.icon))
        case .links?:
            let links = (line.links ?? []).compactMap(\.value).compactMap { link in
                Link(title: link.title, icon: link.icon, tone: link.tone.flatMap(Extension.Tone.init(rawValue:)), word: link.word, help: link.help,
                     actions: (link.actions ?? []).compactMap { $0.value.flatMap(Extension.Item.Action.init) })
            }
            guard !links.isEmpty else { return nil }
            self = .links(Array(links.prefix(Self.mostLinks)))
        case nil: return nil
        }
    }

    /// A field as text: a string as it is, a number as "3" or "2.5", one past Int's range as Swift prints it ("1e+19");
    /// nil for anything else.
    static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: s
        case .number(let n)?: Int(exactly: n).map(String.init) ?? String(n)
        default: nil
        }
    }

    /// The stats in `items`: each a label and a value, its tone if known; one without either is skipped.
    static func stats(_ items: JSONValue?) -> [Stat] {
        guard case .array(let raw)? = items else { return [] }
        return raw.compactMap { item -> Stat? in
            guard case .object(let o) = item, case .string(let label)? = o["label"], let value = text(o["value"]) else { return nil }
            let tone: String? = if case .string(let t)? = o["tone"] { t } else { nil }
            return Stat(label: label, value: value, tone: tone.flatMap(Extension.Tone.init(rawValue:)))
        }
    }

    /// The blocks in `lines`, the unknown and broken ones skipped, at most `most`.
    static func blocks(_ lines: [Line]?) -> [Extension.Block] { Array((lines ?? []).compactMap { Self($0) }.prefix(most)) }
}

/// One element that may fail to decode, kept as nil so the rest still read.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// What a surface's command came to: its blocks (a page), its bar answer, or why there is nothing.
/// Blocks may ask to be asked again every `refresh` seconds while their view shows (Surfaces v2).
public enum SurfaceOutcome: Equatable, Sendable {
    case blocks([Extension.Block], refresh: Int? = nil), bar(Extension.BarAnswer), error(String)
}

extension Extension.Block {
    /// The fastest and slowest `refresh` a blocks answer may ask, in seconds.
    public static let refreshRange = 2...60

    /// A blocks answer's `refresh`, held to 2 to 60 s; nil when it asks none (or not a number).
    static func refresh(_ asked: JSONValue?) -> Int? {
        guard case .number(let asked)? = asked, asked.isFinite, asked > 0 else { return nil }
        return min(max(Int(asked.rounded()), refreshRange.lowerBound), refreshRange.upperBound)
    }
}

extension ExtensionRun {
    /// A page's or a popover's command may take this long, a bar item's this (design: 5 s and 2 s), then it is stopped
    /// and says so.
    public static let pageTimeout: Duration = .seconds(5), barTimeout: Duration = .seconds(2)

    /// Runs `surface`'s command with `"surface": "page"` or `"bar"` in its run message and reads its answer; concurrent,
    /// so a large answer is decoded off the main actor that runs the key tap.
    @concurrent public static func surface(_ surface: Extension.Surface, inputs: Inputs,
                                           environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                                           timeout: Duration? = nil) async -> SurfaceOutcome {
        await blocks(surface.command, surface: surface.kind, inputs: inputs, environment: pilot, timeout: timeout)
    }

    /// Runs `command` for `surface`, handing on `context` (a push's in a popover or page, Surfaces v2), and reads its
    /// answer as that surface's.
    @concurrent public static func blocks(_ command: Extension.Command, surface: Extension.Surface.Kind, context: JSONValue? = nil,
                                          inputs: Inputs, environment pilot: [String: String] = ProcessInfo.processInfo.environment,
                                          timeout: Duration? = nil) async -> SurfaceOutcome {
        let timeout = timeout ?? (surface == .bar ? barTimeout : pageTimeout)
        do {
            let printed = try await output(command, context: context, surface: surface, inputs: inputs, environment: pilot, timeout: timeout)
            return surfaceAnswer(printed, kind: surface)
        } catch { return .error(reason(error, timeout: timeout)) }
    }

    private struct SurfaceLine: Decodable {
        let type: String, text: String?, tone: String?, blocks: [Extension.Block.Line]?, gauges: JSONValue?, refresh: JSONValue?
    }

    /// The answer in what a surface's command printed: the first error message wins, else the last blocks message (a
    /// page) or bar message (a bar item, which may carry blocks for its dropdown). A plain line is unreadable; silence says
    /// it sent nothing.
    static func surfaceAnswer(_ output: String, kind: Extension.Surface.Kind) -> SurfaceOutcome {
        var last: SurfaceOutcome?
        let decoder = JSONDecoder()
        for line in output.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let message = try? decoder.decode(SurfaceLine.self, from: Data(line.utf8)) else { return .error(unreadable) }
            switch (message.type, kind) {
            case ("error", _): return .error("says: \(message.text ?? "it failed")")
            case ("blocks", .page), ("blocks", .popover):
                last = .blocks(Extension.Block.blocks(message.blocks), refresh: Extension.Block.refresh(message.refresh))
            case ("bar", .bar):
                last = .bar(Extension.BarAnswer(text: message.text ?? "", tone: message.tone.flatMap(Extension.Tone.init(rawValue:)),
                                                blocks: Extension.Block.blocks(message.blocks), gauges: Extension.Gauge.gauges(message.gauges)))
            default: continue
            }
        }
        return last ?? .error(kind == .bar ? "sent no bar line" : "sent no blocks")
    }
}
