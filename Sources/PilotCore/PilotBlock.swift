import Foundation

/// The Pilot block (stories 68 and 96): app rules, the always-float list, the gaps, the top bar's room and the scrolling
/// layout's settings, kept in Pilot's settings (PilotBlockStore) and handed to Pilot's tiler as its settings (TilerSettings).
/// Named for the block it once wrote into the old tiler's config; that file is now only read, once, as an import (`carryOver`, ADR 0011).
public struct PilotBlock: Codable, Equatable, Sendable {
    /// An app pinned to a workspace by bundle id.
    public struct AppRule: Codable, Equatable, Sendable {
        public var appId: String
        public var workspace: String
        public init(appId: String, workspace: String) { self.appId = appId; self.workspace = workspace }
    }

    /// One inner gap (both directions) and one outer gap (all four sides), as the Tiling settings show them.
    public struct Gaps: Codable, Equatable, Sendable {
        public var inner: Int
        public var outer: Int
        public init(inner: Int, outer: Int) { self.inner = inner; self.outer = outer }
    }

    /// A screen showing Pilot's top bar (card agent-bo-95422850): the tiler keeps the bar's height clear above the tiles
    /// on that monitor alone, matched by the monitor's name.
    public struct BarInset: Codable, Equatable, Sendable {
        public var monitor: String
        public var height: Int
        public init(monitor: String, height: Int) { self.monitor = monitor; self.height = height }
    }

    /// The scrolling layout's settings (spec scrolling-layout T4, Sven 2026-10-12): the widths a column steps through, a
    /// new column's width, how much of a column past an open screen edge stays on screen, how fast the strip scrolls, and
    /// when it centres the focused column (T9), and each app's own column width and focus (T11).
    public struct Scrolling: Codable, Equatable, Sendable {
        public var widths: [ColumnWidth]
        public var newWidth: ColumnWidth
        public var sliver: Int
        public var speed: ScrollSpeed
        public var centre: CentreMode
        public var apps: [ColumnRule]
        public init(widths: [ColumnWidth] = [.third, .half, .twoThirds, .full], newWidth: ColumnWidth = .third, sliver: Int = 5,
                    speed: ScrollSpeed = .smooth, centre: CentreMode = .never, apps: [ColumnRule] = []) {
            self.widths = widths; self.newWidth = newWidth; self.sliver = sliver; self.speed = speed; self.centre = centre; self.apps = apps
        }

        /// Settings saved before T9 have no `centre` (never), before T11 no `apps`.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(widths: try c.decode([ColumnWidth].self, forKey: .widths), newWidth: try c.decode(ColumnWidth.self, forKey: .newWidth),
                      sliver: try c.decode(Int.self, forKey: .sliver), speed: try c.decode(ScrollSpeed.self, forKey: .speed),
                      centre: try c.decodeIfPresent(CentreMode.self, forKey: .centre) ?? .never,
                      apps: try c.decodeIfPresent([ColumnRule].self, forKey: .apps) ?? [])
        }

        /// The sliver Settings and `pilot set` allow, in points.
        public static let sliverRange = 1...20
    }

    /// A column's width as a share of the monitor's usable width, by the word Settings and `pilot set` show.
    public enum ColumnWidth: String, Codable, CaseIterable, Sendable {
        case quarter = "1/4", third = "1/3", half = "1/2", twoThirds = "2/3", threeQuarters = "3/4", full
        public var title: String { self == .full ? "Full" : rawValue }
        public var fraction: Double {
            switch self {
            case .quarter: 1.0 / 4
            case .third: 1.0 / 3
            case .half: 1.0 / 2
            case .twoThirds: 2.0 / 3
            case .threeQuarters: 3.0 / 4
            case .full: 1
            }
        }
    }

    /// An app's own column on a scrolling strip (spec scrolling-layout T11, Paneru's `width` and `dont_focus` rules): its
    /// windows' column width, nil for the automatic one, and whether a window it opens takes focus.
    public struct ColumnRule: Codable, Equatable, Sendable {
        public var appId: String
        public var width: ColumnWidth?
        public var focus: Bool
        public init(appId: String, width: ColumnWidth? = nil, focus: Bool = true) { self.appId = appId; self.width = width; self.focus = focus }
    }

    /// When the strip centres the focused column (spec scrolling-layout T9, niri's center-focused-column): never, scrolling
    /// the least that shows it whole (the default, Sven's Q20); on overflow, centring it only when it was not whole in view;
    /// always.
    public enum CentreMode: String, Codable, CaseIterable, Sendable {
        case never, overflow, always
        public var title: String { self == .overflow ? "On overflow" : rawValue.capitalized }
    }

    /// How long a strip scroll glides: smooth 350 ms (the default), fast 150 ms, instant jumps.
    public enum ScrollSpeed: String, Codable, CaseIterable, Sendable {
        case smooth, fast, instant
        public var title: String { rawValue.capitalized }
        public var glide: Duration? {
            switch self {
            case .smooth: .milliseconds(350)
            case .fast: .milliseconds(150)
            case .instant: nil
            }
        }
    }

    public var rules: [AppRule]
    /// Apps whose windows never tile, by bundle id (C8): Tiling's Float switches.
    public var floatAppIds: [String]
    /// App names whose windows never tile, as macOS shows the running app's name: those from before C8 and the import's
    /// that no app on this Mac answered to when they moved (`moveFloatNames` moved the rest to `floatAppIds`).
    public var floatApps: [String]
    /// Window titles that never tile, whatever the app: a title containing one of them, case ignored (Google Accounts).
    public var floatTitles: [String]
    public var gaps: Gaps
    /// Off writes zero gaps and keeps the sizes for the next toggle (Hyper+Shift+Backspace).
    public var gapsOn: Bool
    /// The screens with the top bar on, empty while it is off; kept whether gaps are on or off.
    public var topBar: [BarInset]
    /// The screens showing Pilot's dock (spec pilot-dock), its room at their foot; empty while it is off. A block saved
    /// before the dock has none.
    public var dock: [BarInset] = []
    public var scrolling: Scrolling
    /// Tiled windows glide to a new place instead of jumping (Sven's Q147); Reduce Motion and Low Power Mode jump anyway.
    public var glide: Bool

    public init(rules: [AppRule] = [], floatAppIds: [String] = [], floatApps: [String] = [], floatTitles: [String] = [],
                gaps: Gaps = Gaps(inner: 0, outer: 0), gapsOn: Bool = true, topBar: [BarInset] = [], scrolling: Scrolling = Scrolling(),
                glide: Bool = true) {
        self.rules = rules; self.floatAppIds = floatAppIds; self.floatApps = floatApps; self.floatTitles = floatTitles; self.gaps = gaps; self.gapsOn = gapsOn
        self.topBar = topBar; self.scrolling = scrolling; self.glide = glide
    }

    /// Settings saved before the top bar existed have no `topBar`, before C8 no `floatAppIds`, before the scrolling layout
    /// no `scrolling`, before Glide windows no `glide` (on).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rules: try c.decode([AppRule].self, forKey: .rules),
                  floatAppIds: try c.decodeIfPresent([String].self, forKey: .floatAppIds) ?? [], floatApps: try c.decode([String].self, forKey: .floatApps),
                  floatTitles: try c.decode([String].self, forKey: .floatTitles), gaps: try c.decode(Gaps.self, forKey: .gaps),
                  gapsOn: try c.decode(Bool.self, forKey: .gapsOn), topBar: try c.decodeIfPresent([BarInset].self, forKey: .topBar) ?? [],
                  scrolling: try c.decodeIfPresent(Scrolling.self, forKey: .scrolling) ?? Scrolling(),
                  glide: try c.decodeIfPresent(Bool.self, forKey: .glide) ?? true)
        dock = try c.decodeIfPresent([BarInset].self, forKey: .dock) ?? []
    }

    /// The Window shelf's room at the left edge of a monitor showing a Stage workspace, in points (ADR 0015: Q660's 172,
    /// grown for Sven's bigger cards, about Stage Manager's strip on a 1440 pt tall screen): the tiler keeps it free and
    /// the shelf panel fills it.
    public static let shelfWidth = 232

    /// What yabai floated that Pilot keeps (card agent-bo-95422769, Sven's call 2026-10-05): Finder, by bundle id (C8).
    public static let yabaiFloats = ["com.apple.finder"]

    /// yabai's floats this block still lacks, none once the carry-over ran (Sven may have removed one since).
    public func yabaiFloatsToCarry(alreadyCarried: Bool) -> [String] {
        alreadyCarried ? [] : Self.yabaiFloats.filter { !floatAppIds.contains($0) }
    }

    /// Each float name in `ids` moved to `floatAppIds` as that app's bundle id (C8); a name no app answers to stays and is
    /// still matched by name, so no entry is lost. False when none moved.
    public mutating func moveFloatNames(to ids: [String: String]) -> Bool {
        let before = floatApps.count
        floatApps.removeAll { name in
            guard let id = ids[name] else { return false }
            if !floatAppIds.contains(id) { floatAppIds.append(id) }
            return true
        }
        return floatApps.count < before
    }

    /// Names as one anchored regex, the form the tiler matches float lists and bar screens by.
    public static func namePattern(_ names: [String]) -> String { NameList.pattern(names) }

    /// Float titles as one unanchored regex, `(A|B)`: a window floats when its title contains one of them, case ignored, so
    /// Google Accounts floats "Sign in - Google Accounts — Zen Browser" (Sven, 2026-10-10).
    public static func titlePattern(_ titles: [String]) -> String { NameList.parts(titles) }

    private static let innerKeys = ["inner.horizontal", "inner.vertical"]
    private static let outerKeys = ["outer.left", "outer.bottom", "outer.top", "outer.right"]
    private static let toWorkspace = "move-node-to-workspace "
    private static let float = "layout floating"
    /// Each float list with the callback condition that matches it in an imported config.
    private static let floatLists: [(condition: String, list: any WritableKeyPath<PilotBlock, [String]> & Sendable)] =
        [("app-name-regex-substring", \.floatApps), ("window-title-regex-substring", \.floatTitles)]

    /// The one-time import (ADR 0011): Sven's gaps, rules and float lists read from an AeroSpace config, so Pilot's
    /// settings start from what the file did (coordinator note 1). Reads the whole file, the block Pilot once wrote
    /// included; never writes it. Nil when it sets none of them; a gap or callback Pilot cannot hold is refused with its
    /// line, never dropped.
    public static func carryOver(from file: String) throws(PilotBlockError) -> PilotBlock? {
        var gaps: [String: Int] = [:], firstGap: Int?, bars: [BarInset] = []
        var callbacks: [(line: Int, keys: [String: TOMLValue])] = []
        for line in TOMLLine.walk(file) {
            guard let key = line.key, let raw = line.value else {
                if line.isArrayHeader && line.table == "on-window-detected" { callbacks.append((line.number, [:])) }
                continue
            }
            let value = TOMLValue(raw)
            if key.hasPrefix("gaps.") || key == "gaps" {
                let name = String(key.dropFirst(5))
                if name == "outer.top", let (perMonitor, outer) = BarInset.parse(raw) {
                    bars = perMonitor.map { BarInset(monitor: $0.monitor, height: $0.height - outer) }
                    gaps[name] = outer
                } else {
                    guard case .int(let n) = value, (innerKeys + outerKeys).contains(name) else { throw .cannotCarryOver(line: line.number) }
                    gaps[name] = n
                }
                firstGap = firstGap ?? line.number
            } else if line.table == "on-window-detected" {
                guard let last = callbacks.indices.last else { throw .cannotCarryOver(line: line.number) }
                callbacks[last].keys[String(key.dropFirst(line.table.count + 1))] = value
            } else if key == "on-window-detected" {
                throw .cannotCarryOver(line: line.number)
            }
        }
        guard firstGap != nil || !callbacks.isEmpty else { return nil }
        var block = PilotBlock()
        if let firstGap {
            func uniform(_ keys: [String]) throws(PilotBlockError) -> Int {
                // AeroSpace leaves an unset side at 0, so a group is one size only when every side agrees.
                let values = Set(keys.map { gaps[$0] ?? 0 })
                guard values.count <= 1 else { throw .cannotCarryOver(line: firstGap) }
                return values.first ?? 0
            }
            block.gaps = Gaps(inner: try uniform(innerKeys), outer: try uniform(outerKeys))
            block.topBar = bars
        }
        for callback in callbacks {
            guard callback.keys.count == 2, case .string(let run)? = callback.keys["run"],
                  let (key, value) = callback.keys.first(where: { $0.key != "run" }), key.hasPrefix("if."),
                  case .string(let match) = value
            else { throw .cannotCarryOver(line: callback.line) }
            let condition = key.dropFirst(3), workspace = run.dropFirst(toWorkspace.count)
            if condition == "app-id", run.hasPrefix(toWorkspace), !workspace.isEmpty, !workspace.contains(" ") {
                block.rules.append(AppRule(appId: match, workspace: String(workspace)))
            } else if run == float, let list = floatLists.first(where: { $0.condition == condition })?.list,
                      let names = NameList.names(match) {
                block[keyPath: list] += names
            } else {
                throw .cannotCarryOver(line: callback.line)
            }
        }
        return block
    }
}

/// One meaningful line of a TOML file: a table header, or a key with its full dotted path and raw value (the carry-over).
struct TOMLLine {
    let number: Int
    let table: String
    let isArrayHeader: Bool
    /// The full dotted key, table included; nil on a header.
    let key: String?
    let value: Substring?

    static func walk(_ file: String) -> [TOMLLine] {
        var table = "", out: [TOMLLine] = []
        for (index, raw) in file.components(separatedBy: "\n").enumerated() {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if text.hasPrefix("[") {
                let array = text.hasPrefix("[[")
                table = dotted(text.dropFirst(array ? 2 : 1).prefix { $0 != "]" })
                out.append(TOMLLine(number: index + 1, table: table, isArrayHeader: array, key: nil, value: nil))
            } else if let eq = text.firstIndex(of: "=") {
                let key = [table, dotted(text[..<eq])].filter { !$0.isEmpty }.joined(separator: ".")
                out.append(TOMLLine(number: index + 1, table: table, isArrayHeader: false, key: key, value: text[text.index(after: eq)...]))
            }
        }
        return out
    }

    /// `a . b` and `a.b` are the same key.
    private static func dotted(_ s: Substring) -> String {
        s.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ".")
    }
}

public enum PilotBlockError: Error, Equatable, CustomStringConvertible {
    case cannotCarryOver(line: Int)

    public var description: String {
        switch self {
        case .cannotCarryOver(let line): "~/.aerospace.toml line \(line) is a gap or rule Pilot's settings cannot hold; nothing carried over"
        }
    }
}

/// A list of literal names as one anchored regex, `^(A|B)$`, the shape AeroSpace's regex conditions take.
enum NameList {
    private static let special = Set("\\^$.|?*+()[]{}")

    static func pattern(_ names: [String]) -> String { "^" + parts(names) + "$" }

    /// The names escaped and joined, `(A|B)`, unanchored: a match anywhere in the text.
    static func parts(_ names: [String]) -> String {
        "(" + names.map { String($0.flatMap { special.contains($0) ? ["\\", $0] : [$0] }) }.joined(separator: "|") + ")"
    }

    /// The names back, or nil when the regex is anything but a list of escaped literals.
    static func names(_ pattern: String) -> [String]? {
        guard pattern.hasPrefix("^("), pattern.hasSuffix(")$") else { return nil }
        var names = [""], escaped = false
        for c in pattern.dropFirst(2).dropLast(2) {
            if escaped { names[names.count - 1].append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "|" { names.append("") }
            else if special.contains(c) { return nil }
            else { names[names.count - 1].append(c) }
        }
        return escaped || names.contains("") ? nil : names
    }
}

/// The few TOML values the block holds: integers and single-line strings. Anything else is `.other`.
enum TOMLValue: Equatable {
    case int(Int), string(String), other

    init(_ text: Substring) {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let quote = text.first, quote == "'" || quote == "\"", let s = TOMLString.unquote(text) { self = .string(s); return }
        let token = text.prefix { $0 != "#" && $0 != " " }
        self = Int(token).map(TOMLValue.int) ?? .other
    }
}

enum TOMLString {
    /// A literal ('…') or basic ("…") string at the start of `text`, trailing comment allowed; nil otherwise.
    static func unquote(_ text: String) -> String? {
        guard let quote = text.first else { return nil }
        var out = "", escaped = false, rest = text.dropFirst()
        while let c = rest.first {
            rest = rest.dropFirst()
            if escaped {
                guard c == "\\" || c == "\"" else { return nil }
                out.append(c); escaped = false
            } else if quote == "\"" && c == "\\" { escaped = true }
            else if c == quote {
                let tail = rest.trimmingCharacters(in: .whitespaces)
                return tail.isEmpty || tail.hasPrefix("#") ? out : nil
            } else { out.append(c) }
        }
        return nil
    }
}

extension PilotBlock.BarInset {
    /// `outer.top`'s per-monitor values and the default, as Pilot's block wrote them; nil for any other value.
    static func parse(_ raw: Substring) -> (bars: [Self], outer: Int)? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
        let rule = #/\{ monitor\.("(?:[^"\\]|\\.)*") = (\d+) \}, /#
        var rest = Substring(text.dropFirst().dropLast()), bars: [Self] = []
        while let match = rest.prefixMatch(of: rule) {
            guard let pattern = TOMLString.unquote(String(match.1)), let names = NameList.names(pattern), names.count == 1,
                  let value = Int(match.2) else { return nil }
            bars.append(Self(monitor: names[0], height: value))
            rest = rest[match.range.upperBound...]
        }
        guard !bars.isEmpty, let outer = Int(rest) else { return nil }
        return (bars, outer)
    }
}
