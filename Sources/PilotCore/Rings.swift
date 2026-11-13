import Foundation

/// The Ring menu (P74, after Opie): Hyper+Space for the mouse. Holding a bound mouse button or key opens a ring of up to
/// eight of Pilot's actions around the pointer; flicking toward one and letting go runs it, a click on it too. A group
/// nests as the menu's branches do: entering it turns the ring into the group's own ring in the same place (Sven,
/// 2026-10-20), its name in the hub, and the hub or Esc goes back up one level; scrolling at the top steps to the next
/// ring; a switch shows on or off. Sven picked direction Halo (Q365, Q366): one disc cut into eight wedges, the answer in
/// the hub.
public struct Ring: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// A bundle id: the ring joins the wheel, first, while that app is in front (per-app rings, Q366); nil for every app.
    public var app: String?
    /// Its wedges are the Hyper+Space menu's top branches, read as it opens, each filled from its branch, so it follows the
    /// menu and is never edited by hand (the Pilot ring).
    public var menu: Bool
    /// Eight places, north first, clockwise; nil an empty one. None on a menu ring.
    public var slices: [RingSlice?]

    public init(id: String, name: String, app: String? = nil, menu: Bool = false, slices: [RingSlice?]) {
        self.id = id; self.name = name; self.app = app; self.menu = menu
        self.slices = Array((slices + Array(repeating: nil, count: Self.places)).prefix(Self.places))
    }

    /// A ring holds eight, as Opie's does: one per compass point, so a flick's direction is all it takes.
    public static let places = 8

    /// How many places hold something.
    public var count: Int { slices.count { $0 != nil } }

    /// The action id that opens it: `rings.open:<id>`, bindable as any other action, held.
    public var openID: String { Rings.openPrefix + id }

    /// The wedge at `path`: a place, then a place in the group there, and so on down. Set, only a path through groups
    /// written by hand reaches: a group filled from the menu is read-only.
    public subscript(path path: [Int]) -> RingSlice? {
        get {
            guard let first = path.first, slices.indices.contains(first) else { return nil }
            return path.dropFirst().reduce(slices[first]) { slice, p in slice?.slices.flatMap { $0.indices.contains(p) ? $0[p] : nil } }
        }
        set {
            guard let first = path.first, slices.indices.contains(first) else { return }
            slices[first] = RingSlice.setting(slices[first], Array(path.dropFirst()), newValue)
        }
    }
}

/// One wedge: an action, a switch (an action with an on or off state, shown on the wedge) or a group, whose own eight
/// it turns into when entered, as deep as wanted; a group may be filled from a menu branch as the ring opens.
public struct RingSlice: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case action, `switch`, group }

    public var kind: Kind
    /// The action it runs; nil for a group.
    public var action: String?
    /// Its name on the ring; the action's own when nil. A group's is its only name.
    public var label: String?
    /// A group's own eight, north first, clockwise; nil for any other kind, and for a group filled from the menu.
    public var slices: [RingSlice?]?
    /// A group filled from this Hyper+Space menu branch (`MenuBranch.rawValue`) each time it is entered.
    public var branch: String?

    public init(_ action: String, kind: Kind = .action, label: String? = nil) {
        self.kind = kind == .group ? .action : kind; self.action = action; self.label = label; slices = nil; branch = nil
    }

    /// A group of up to eight written by hand, groups among them.
    public static func group(_ label: String, _ slices: [RingSlice?]) -> RingSlice {
        var g = RingSlice("", label: label)
        g.kind = .group; g.action = nil
        g.slices = Array((slices + Array(repeating: nil, count: Ring.places)).prefix(Ring.places))
        return g
    }

    /// A group filled from the menu's `branch` as it is entered.
    public static func menu(_ label: String, branch: String) -> RingSlice {
        var g = RingSlice("", label: label)
        g.kind = .group; g.action = nil; g.branch = branch
        return g
    }

    public var isGroup: Bool { kind == .group }

    /// `slice` with the wedge at `path` inside it set to `value`; a missing or menu-filled group on the way changes nothing.
    static func setting(_ slice: RingSlice?, _ path: [Int], _ value: RingSlice?) -> RingSlice? {
        guard let p = path.first else { return value }
        guard var group = slice, group.isGroup, group.branch == nil, var inside = group.slices, inside.indices.contains(p) else { return slice }
        inside[p] = setting(inside[p], Array(path.dropFirst()), value)
        group.slices = inside
        return group
    }
}

/// Every ring and how they behave, as `rings.json` beside the bind file holds them (schema `version`): the rings in the
/// order a scroll steps through them, then the three settings Settings › Rings and Binds › Mouse show.
public struct Rings: Equatable, Sendable {
    /// The file's schema version. A change of shape adds a case to `init(json:)`, never a second format. 2 (2026-10-20):
    /// groups in groups, a group filled from a menu branch, a ring of the menu's branches (the Pilot ring). 3 (2026-10-22):
    /// the This window ring, first. 4 (2026-11-13): This window gains Arrange and is first again, and Mouse 4's hold
    /// opens it (Q194; `upgrades`).
    public static let version = 4
    /// `rings.open:<ring id>`: the held action a key or a mouse hold binds.
    public static let openPrefix = "rings.open:"

    public var rings: [Ring]
    /// How long a mouse button bound to a ring must stay down before it opens, in milliseconds; a quicker press is its
    /// click (the mockup's 180).
    public var holdAfter: Int
    /// Letting go on a wedge runs it; off, the ring stays open until a click picks one.
    public var flickRuns: Bool
    /// The hub shows no action's name, only the lit wedge.
    public var hideNames: Bool

    public static let holdRange = 100...600

    public init(rings: [Ring], holdAfter: Int = 180, flickRuns: Bool = true, hideNames: Bool = false) {   // the mockup's 180
        self.rings = rings; self.holdAfter = holdAfter; self.flickRuns = flickRuns; self.hideNames = hideNames
    }

    /// The ring `rings.open:<id>` opens; nil for any other action id.
    public static func ringID(inAction id: String) -> String? {
        id.hasPrefix(openPrefix) ? String(id.dropFirst(openPrefix.count)) : nil
    }

    public func ring(id: String) -> Ring? { rings.first { $0.id == id } }

    /// `ring` in place of the one with its id, or added last.
    public mutating func put(_ ring: Ring) {
        if let i = rings.firstIndex(where: { $0.id == ring.id }) { rings[i] = ring } else { rings.append(ring) }
    }

    /// An action a wedge may not hold: one that asks for typing once it runs (the mockup's list: Ask AI, Translate, Snippets,
    /// Emoji search, the calculator, Quicklinks, Reminders, a note's text, Kill a process), or a ring's own opener.
    public static func needsTyping(_ id: String) -> Bool {
        id.hasPrefix(openPrefix) || typing.contains(id) || ["quicklinks.", "snippets.", "reminders.", "translate."].contains { id.hasPrefix($0) }
    }
    static let typing: Set<String> = ["ai.ask", "ai.chat", "ai.selection", "apps.emoji", "system.killProcess", "notes.toggle",
                                      "apps.bitwardenSearch", "system.translationLanguages", "apps.passwords", "captures.makeQR"]

    /// The rings a scroll steps through with `app` in front: that app's own first, then every app's, in their order. A ring
    /// with nothing on it is left out, unless it is the one `opening` (Q194: a New ring not filled yet stays in Launcher ›
    /// Rings, off the scroll).
    public func wheel(front app: String?, opening: String? = nil) -> [Ring] {
        let shown = rings.filter { $0.menu || $0.count > 0 || $0.id == opening }
        return shown.filter { $0.app != nil && $0.app == app } + shown.filter { $0.app == nil }
    }

    /// Whether `json` (nil: no file yet) is from before version 4, so this launch gives Mouse 4's hold to This window
    /// (BindStore.addRingHold). The file is written back at version 4 as it is read, so it happens once.
    public static func upgrades(_ json: Data?) -> Bool {
        guard let json else { return true }
        return ((try? JSONDecoder().decode(Version.self, from: json))?.version ?? 0) < 4
    }

    /// A ring id for `name` that no ring has: its words lowercased and joined, a number after it when taken.
    public func freeID(for name: String) -> String {
        let base = name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        let stem = base.isEmpty ? "ring" : base
        var id = stem, n = 2
        while ring(id: id) != nil { id = "\(stem)-\(n)"; n += 1 }
        return id
    }

    // MARK: the defaults

    /// The Pilot ring (Sven, 2026-10-20): the Hyper+Space menu's top branches, each entered as its own ring.
    public static let pilot = Ring(id: "pilot", name: "Pilot", menu: true, slices: [])

    /// This window (Sven's pick, Q415, direction A of the Home and Ring round; A again in the mouse ring round, Q194): one
    /// ring with one job, the window under the pointer, which each wedge focuses first (RingController). Each points where
    /// the keyboard already does: Maximise north as Hyper ↑, the snaps west and east as Hyper ← and →; the corners above
    /// send the window a workspace on or back, the ones below float it or close it. South is Arrange, the one group
    /// (Q194): the thirds where Hyper+Shift ← ↑ → put them, two thirds above them, Fullscreen, Centre and Minimise. Float is
    /// a plain wedge: Pilot reads no window's float state, so a switch there never showed on or off.
    public static let window = Ring(id: "window", name: "This window", slices: [
        RingSlice("windows.maximise"), RingSlice("windows.sendToNextWorkspace", label: "To next workspace"), RingSlice("windows.snapRight"),
        RingSlice("windows.toggleFloat", label: "Float or tile"),
        .group("Arrange", [RingSlice("windows.middleThird"), RingSlice("windows.lastTwoThirds"), RingSlice("windows.lastThird"),
                           RingSlice("windows.fullscreen", label: "Fullscreen"), RingSlice("windows.centre"), RingSlice("windows.minimise"),
                           RingSlice("windows.firstThird"), RingSlice("windows.firstTwoThirds")]),
        RingSlice("windows.close"), RingSlice("windows.snapLeft"), RingSlice("windows.sendToPreviousWorkspace", label: "To previous workspace"),
    ])

    /// This window as version 3 shipped it (Q415): a file still holding it, untouched, gets `window` in its place.
    static let windowV3 = Ring(id: "window", name: "This window", slices: [
        RingSlice("windows.maximise"), RingSlice("windows.sendToNextWorkspace"), RingSlice("windows.snapRight"),
        RingSlice("windows.toggleFloat", kind: .switch, label: "Float"), RingSlice("windows.minimise"), RingSlice("windows.close"),
        RingSlice("windows.snapLeft"), RingSlice("windows.sendToPreviousWorkspace"),
    ])

    /// This window first, the ring a mouse button's hold opens; then the Pilot ring and Sven's five from the mockup (Q366).
    /// Media's wedges are plain actions with no track or time in the hub: Pilot cannot read what is playing today
    /// (pilot-media only pauses and plays). Each slot points where the keyboard already does: Snap left sits west because
    /// it is Hyper ←.
    public static let standard = Rings(rings: [
        window,
        pilot,
        Ring(id: "windows", name: "Windows", slices: [
            RingSlice("windows.maximise"), RingSlice("windows.fullscreen"), RingSlice("windows.snapRight"),
            .group("Thirds and quarters", [RingSlice("windows.firstThird"), RingSlice("windows.middleThird"), RingSlice("windows.lastThird"),
                                           RingSlice("windows.firstTwoThirds"), RingSlice("windows.lastTwoThirds"),
                                           RingSlice("windows.firstThreeQuarters"), RingSlice("windows.lastQuarter"), RingSlice("windows.centreColumn")]),
            RingSlice("windows.centre"), RingSlice("windows.minimise"), RingSlice("windows.snapLeft"),
            RingSlice("windows.toggleFloat", kind: .switch, label: "Float window"),
        ]),
        Ring(id: "apps", name: "Apps", slices: [
            RingSlice("apps.launcher"), RingSlice("apps.browser"), RingSlice("workspaces.next"), RingSlice("apps.editor"),
            RingSlice("apps.clipboard"), RingSlice("apps.files"), RingSlice("workspaces.previous"), RingSlice("apps.terminal"),
        ]),
        Ring(id: "captures", name: "Captures", slices: [
            RingSlice("captures.area"), RingSlice("captures.activeWindow"), RingSlice("captures.fullscreen"),
            RingSlice("captures.screenRecording", kind: .switch, label: "Record screen"), RingSlice("captures.scrolling"), RingSlice("captures.ocr"),
            RingSlice("captures.editLast"), RingSlice("captures.pinLast"),
        ]),
        Ring(id: "system", name: "System", slices: [
            RingSlice("system.lock"), RingSlice("system.darkMode", kind: .switch, label: "Dark mode"),
            RingSlice("system.nightShift", kind: .switch, label: "Night Shift"), RingSlice("system.keepAwake", kind: .switch, label: "Keep awake"),
            RingSlice("system.sleep"), RingSlice("system.wifi", kind: .switch, label: "Wi-Fi"),
            RingSlice("system.idleLock", kind: .switch, label: "Lock when idle"), RingSlice("engine.topBar", kind: .switch, label: "Top bar"),
        ]),
        Ring(id: "media", name: "Media", slices: [
            RingSlice("media.playPause"), RingSlice("media.volumeUp"), RingSlice("media.next"), RingSlice("media.volumeDown"),
            RingSlice("media.mute", kind: .switch, label: "Mute"), RingSlice("system.soundSettings", label: "Sound output"), RingSlice("media.previous"),
            RingSlice("speech.readAloud"),
        ]),
    ])

    // MARK: the file

    public enum LoadError: Error, Equatable { case newerVersion(Int), unreadable(String) }

    /// Reads a file of any version up to this one; an empty or missing ring list keeps the defaults' rings. Version 1 is
    /// version 2 with groups one level deep and no Pilot ring, which it gains, first. Version 2 is version 3 without the
    /// This window ring, which it gains, first (Sven's pick, Q415). Version 3 is version 4 with This window anywhere and
    /// Q415's eight on it: it moves first, and those eight, if untouched, become today's (Q194).
    public init(json: Data) throws(LoadError) {
        let file: File
        do {
            let version = try JSONDecoder().decode(Version.self, from: json).version ?? 0
            guard version <= Self.version else { throw LoadError.newerVersion(version) }
            file = try JSONDecoder().decode(File.self, from: json)
        } catch let error as LoadError {
            throw error
        } catch {
            throw .unreadable(String(describing: error))
        }
        var seen = Set<String>()
        var rings = (file.rings ?? []).compactMap { r -> Ring? in
            guard !r.id.isEmpty, seen.insert(r.id).inserted else { return nil }   // a hand-edited second ring on one id: the first stays
            return Ring(id: r.id, name: r.name, app: r.app, menu: r.menu == true, slices: r.menu == true ? [] : (r.slices ?? []).map { $0?.slice })
        }
        if file.version < 2, file.rings != nil, !seen.contains(Self.pilot.id) { rings.insert(Self.pilot, at: 0) }
        if file.version < 3, file.rings != nil, !seen.contains(Self.window.id) { rings.insert(Self.window, at: 0) }
        // Version 4 (Q194): This window first, as Mouse 4's hold opens it; Q415's eight, untouched, become Arrange's ring.
        if file.version < 4, let i = rings.firstIndex(where: { $0.id == Self.window.id }) {
            var window = rings.remove(at: i)
            if window.slices == Self.windowV3.slices, window.app == nil, !window.menu { window.slices = Self.window.slices }
            rings.insert(window, at: 0)
        }
        let standard = Self.standard
        self.init(rings: file.rings == nil ? standard.rings : rings,
                  holdAfter: min(max(file.holdAfter ?? standard.holdAfter, Self.holdRange.lowerBound), Self.holdRange.upperBound),
                  flickRuns: file.flickRuns ?? standard.flickRuns, hideNames: file.hideNames ?? standard.hideNames)
    }

    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = File(version: Self.version, rings: rings.map { r in
            RingRow(id: r.id, name: r.name, app: r.app, menu: r.menu ? true : nil, slices: r.menu ? nil : r.slices.map { $0.map(SliceRow.init) })
        }, holdAfter: holdAfter, flickRuns: flickRuns, hideNames: hideNames)
        return try! encoder.encode(file)
    }

    private struct Version: Decodable { var version: Int? }

    /// `{"version": 3, "holdAfter": 180, "flickRuns": true, "hideNames": false, "rings": [{"id": "pilot", "name": "Pilot",
    /// "menu": true}, {"id": "windows", "name": "Windows", "slices": [{"action": "windows.maximise"}, null, {"kind": "group",
    /// "label": "Thirds", "slices": [...]}, {"kind": "group", "label": "Power", "branch": "category:Power"}, …]}]}`.
    private struct File: Codable {
        var version: Int
        var rings: [RingRow]?
        var holdAfter: Int?, flickRuns: Bool?, hideNames: Bool?
    }

    private struct RingRow: Codable {
        var id: String, name: String, app: String?
        var menu: Bool?
        var slices: [SliceRow?]?
    }

    private struct SliceRow: Codable {
        var kind: String?, action: String?, label: String?, branch: String?
        var slices: [SliceRow?]?

        init(_ s: RingSlice) {
            kind = s.kind == .action ? nil : s.kind.rawValue
            action = s.action; label = s.label; branch = s.branch
            slices = s.slices.map { $0.map { $0.map(SliceRow.init) } }
        }

        /// A row with no action is no wedge, an unknown kind an action; a group keeps its groups, as deep as written.
        var slice: RingSlice? {
            if kind == RingSlice.Kind.group.rawValue {
                if let branch { return .menu(label ?? "Group", branch: branch) }
                return .group(label ?? "Group", (slices ?? []).map { $0?.slice })
            }
            guard let action, !action.isEmpty else { return nil }
            return RingSlice(RetiredActions.current(action), kind: kind == RingSlice.Kind.switch.rawValue ? .switch : .action, label: label)
        }
    }
}

extension MenuBranch {
    /// The branch `rawValue` names: a fixed one by its case name, `category:<name>` in Install, `<branch>:<name>` in the
    /// branch it browses (System's, Remove's, Update's, an extension's).
    public init?(id: String) {
        if let fixed = MenuBranch.allCases.first(where: { $0.rawValue == id }) { self = fixed; return }
        guard let colon = id.firstIndex(of: ":") else { return nil }
        let browse = String(id[..<colon]), name = String(id[id.index(after: colon)...])
        if browse == "category" { self = .category(name, in: .install); return }
        guard let parent = MenuBranch.allCases.first(where: { $0.rawValue == browse }) else { return nil }
        self = .category(name, in: parent)
    }
}

/// Halo's measures in points, and where the pointer aims: the hub under the pointer and the disc of eight wedges around
/// it. Every level of a ring is the same disc.
public enum RingGeometry {
    /// The hub's radius: inside it nothing is aimed.
    public static let hub: Double = 54
    /// The disc's radius, its outer rim.
    public static let disc: Double = 138
    /// The panel's side: the disc and a margin.
    public static let side: Double = 2 * (disc + 8)

    /// A wedge's centre, degrees clockwise from north.
    public static func angle(of place: Int) -> Double { Double(place) * 360 / Double(Ring.places) }

    /// The bearing of `(dx, dy)` (y up), degrees clockwise from north, 0 to 360.
    public static func bearing(dx: Double, dy: Double) -> Double {
        let a = atan2(dx, dy) * 180 / .pi
        return a < 0 ? a + 360 : a
    }

    /// The wedge a bearing falls in.
    public static func place(bearing: Double) -> Int {
        Int((bearing + 180 / Double(Ring.places)) / (360 / Double(Ring.places))) % Ring.places
    }
}

/// One ring open: which ring of the wheel shows, the levels entered (the ring, then each group in turn), what the pointer
/// aims at on the level showing, and which page of it. Pure, so the controller hands it the pointer from the ring's centre
/// (points, y up), the time, and how to fill a group from the menu, and reads what to draw or run.
public struct RingSession: Equatable, Sendable {
    /// A level showing: its name in the hub, its wedges, and the page of them when they are more than eight.
    public struct Level: Equatable, Sendable {
        public var name: String
        public var items: [RingSlice?]
        public var page = 0
        public init(name: String, items: [RingSlice?]) { self.name = name; self.items = items }
    }

    /// One of the eight places: a wedge, or More, the last place of a level with more than eight.
    public enum Place: Equatable, Sendable { case slice(RingSlice), more }

    public enum Outcome: Equatable, Sendable {
        /// Run this action id; the ring closes first.
        case run(String)
        /// Close, running nothing.
        case cancel
        /// Stay open for a click (a quick tap of the trigger, a group or More let go on, or flick-and-let-go switched off).
        case stay
    }

    /// Fills a group from a menu branch (its `rawValue`), or the Pilot ring with the menu's top branches for nil.
    public typealias Expand = (String?) -> [RingSlice?]

    public private(set) var wheel: [Ring]
    public private(set) var index: Int
    /// The ring's own level first, then each group entered.
    public private(set) var levels: [Level] = []
    /// The place aimed on the level showing.
    public private(set) var aim: Int?
    /// When the pointer came to rest on a group or More, for the pause that enters it.
    private var rested: Rest?
    /// Where and since when the pointer has rested in the hub on a level below the ring's, for the pause that goes back
    /// up; a pointer still moving starts it again, so crossing the hub to the far side never goes up (Build 76).
    private var inHub: HubRest?
    private struct HubRest: Equatable, Sendable { var since: TimeInterval, x: Double, y: Double }
    /// The place the pointer was on as the level changed: it enters nothing until the pointer moves to another, so
    /// resting where a group was never falls straight through the next level too.
    private var settled: Int?
    /// The pointer has been inside the disc since the level changed: only then does a flick past the rim enter a group.
    private var withinDisc = false
    /// The pointer has left the hub since the level changed: only then does coming back into it go up.
    private var leftHub = false
    private struct Rest: Equatable, Sendable { var place: Int, since: TimeInterval }

    /// A pause on a group or More this long enters it, as keeping on outward past the rim does.
    public static let groupPause: TimeInterval = 0.25
    /// A rest in the hub this long goes back up a level: the pointer still within `hubStill` points of where it came to
    /// rest. Crossing the hub, at any speed, is never a rest (Sven on Build 76: moving from one wedge to another quit the
    /// ring: a 0.2 s pause was the time an ordinary move spends crossing the 108 pt hub, so it went up a level and the
    /// let-go landed on the ring above).
    public static let hubPause: TimeInterval = 0.3
    public static let hubStill: Double = 4
    /// A trigger let go this soon after the ring opened, nothing aimed, leaves it open for a click: a tap, not a hold.
    public static let tap: TimeInterval = 0.3
    /// A level's page when it holds more than eight: seven, and More last.
    public static let pageSize = Ring.places - 1

    public init(wheel: [Ring], index: Int = 0, expand: Expand = { _ in [] }) {
        self.wheel = wheel
        self.index = wheel.isEmpty ? 0 : min(max(index, 0), wheel.count - 1)
        showRing(expand)
    }

    public var ring: Ring? { wheel.indices.contains(index) ? wheel[index] : nil }
    public var level: Level? { levels.last }
    /// How many groups deep: 0 on the ring itself.
    public var depth: Int { max(levels.count - 1, 0) }
    /// The names down to the level showing, the ring's first.
    public var crumbs: [String] { levels.map(\.name) }

    /// The level's pages: one up to eight wedges, else seven a page.
    public var pages: Int {
        guard let n = level?.items.count, n > Ring.places else { return 1 }
        return (n + Self.pageSize - 1) / Self.pageSize
    }

    /// The eight places showing, north first: the level's own when they are eight or fewer, else its page and More.
    public var places: [Place?] {
        guard let level else { return Array(repeating: nil, count: Ring.places) }
        if level.items.count <= Ring.places {
            return (level.items + Array(repeating: nil, count: Ring.places - level.items.count)).map { $0.map(Place.slice) }
        }
        let start = level.page * Self.pageSize
        let shown = level.items[start..<min(start + Self.pageSize, level.items.count)].map { $0.map(Place.slice) }
        return Array(shown) + Array(repeating: nil, count: Self.pageSize - shown.count) + [.more]
    }

    /// What the aim lands on: a wedge, More, or nothing.
    public var aimed: Place? { aim.flatMap { places[$0] } }

    /// The pointer at `(dx, dy)` from the centre at `now`: true when what is aimed, the level or its page changed.
    @discardableResult
    public mutating func point(dx: Double, dy: Double, at now: TimeInterval, expand: Expand = { _ in [] }) -> Bool {
        let before = (aim, levels)
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < RingGeometry.hub {
            aim = nil; rested = nil; settled = nil
            if depth > 0, leftHub {
                if let rest = inHub, (dx - rest.x) * (dx - rest.x) + (dy - rest.y) * (dy - rest.y) <= Self.hubStill * Self.hubStill {
                    if now - rest.since >= Self.hubPause { up() }
                } else {
                    inHub = HubRest(since: now, x: dx, y: dy)
                }
            }
            return before != (aim, levels)
        }
        inHub = nil
        leftHub = true
        if distance <= RingGeometry.disc { withinDisc = true }
        let place = RingGeometry.place(bearing: RingGeometry.bearing(dx: dx, dy: dy))
        if settled != place { settled = nil }
        // Where a group was entered nothing is aimed until the pointer moves to another wedge: a flick past the rim
        // onto a group, let go, runs nothing of the group's ring.
        aim = places[place] == nil || settled == place ? nil : place
        let enters: Bool = switch places[place] {
        case .more?: true
        case .slice(let s)?: s.isGroup
        case nil: false
        }
        if enters, settled == nil {
            if rested?.place != place { rested = Rest(place: place, since: now) }
            // Keeping on outward past the rim, or a pause on it, enters it.
            if (distance > RingGeometry.disc && withinDisc) || now - (rested?.since ?? now) >= Self.groupPause { enter(place, expand) }
        } else {
            rested = nil
        }
        return before != (aim, levels)
    }

    /// Into the group at `place`, or the next page for More; the pointer stays where it is.
    private mutating func enter(_ place: Int, _ expand: Expand) {
        switch places[place] {
        case .more?:
            levels[levels.count - 1].page = (levels[levels.count - 1].page + 1) % pages
        case .slice(let s)? where s.isGroup:
            levels.append(Level(name: s.label ?? "Group", items: s.branch.map { expand($0) } ?? s.slices ?? []))
        default:
            return
        }
        changed(at: place)
    }

    /// Back up one level, to the group's own ring; false on the ring itself.
    @discardableResult
    public mutating func up() -> Bool {
        guard depth > 0 else { return false }
        levels.removeLast()
        changed(at: nil)
        leftHub = false
        return true
    }

    private mutating func changed(at place: Int?) {
        aim = nil; rested = nil; inHub = nil
        settled = place
        withinDisc = false
    }

    private mutating func showRing(_ expand: Expand) {
        guard let ring else { return levels = [] }
        levels = [Level(name: ring.name, items: ring.menu ? expand(nil) : ring.slices)]
        changed(at: nil)
    }

    /// A scroll step: on the ring itself the next ring (+1) or the one before, round the wheel; inside a group its next
    /// page or the one before.
    public mutating func scroll(_ step: Int, expand: Expand = { _ in [] }) {
        if depth > 0 || wheel.count < 2 {
            guard pages > 1 else { return }
            levels[levels.count - 1].page = ((levels[levels.count - 1].page + step) % pages + pages) % pages
            changed(at: nil)
            return
        }
        index = ((index + step) % wheel.count + wheel.count) % wheel.count
        showRing(expand)
    }

    /// The trigger let go `held` seconds after the ring opened.
    public func release(held: TimeInterval, flickRuns: Bool) -> Outcome {
        switch aimed {
        // Let go just after a group was entered, before the pointer moved on, or on nothing inside a group: its ring
        // stays for a pick (Esc or a click outside closes it); only the ring's own hub, or nothing on it, closes.
        case nil: return held < Self.tap || settled != nil || depth > 0 ? .stay : .cancel
        case .more?: return .stay
        case .slice(let s)?:
            if s.isGroup { return .stay }
            guard flickRuns, let action = s.action else { return .stay }
            return .run(action)
        }
    }

    /// A click at `(dx, dy)` while the ring is open: a wedge runs, a group or More enters, the hub goes back up a level
    /// (or closes on the ring itself), outside the disc closes.
    public mutating func click(dx: Double, dy: Double, at now: TimeInterval, expand: Expand = { _ in [] }) -> Outcome {
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < RingGeometry.hub { return up() ? .stay : .cancel }
        guard distance <= RingGeometry.disc else { return .cancel }
        let place = RingGeometry.place(bearing: RingGeometry.bearing(dx: dx, dy: dy))
        switch places[place] {
        case nil: return .cancel
        case .more?:
            enter(place, expand)
            return .stay
        case .slice(let s)?:
            if s.isGroup { enter(place, expand); return .stay }
            return s.action.map(Outcome.run) ?? .cancel
        }
    }

    /// Settings › Rings' pick: the groups at `path` entered, from the ring's places, and `place` on that level aimed.
    public mutating func pick(path: [Int], place: Int?, expand: Expand = { _ in [] }) {
        showRing(expand)
        for p in path { guard case .slice(let s)? = places[p], s.isGroup else { break }; enter(p, expand) }
        aim = place.flatMap { places[$0] == nil ? nil : $0 }
    }
}
