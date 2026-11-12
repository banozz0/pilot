import Foundation

/// Where a drop on the top bar lands (card agent-bo-95423017; the Menu bar page's strip since Q185): each side is a
/// zone round its drawn slots (an empty side a zone of its own at its edge or the middle), the sides split halfway
/// between their zones in the order they are drawn, and the drop goes before the first slot of that side whose middle is right of it. Pure, so it is
/// tested without views; the bar hands it the slots as it drew them.
public struct BarDrop: Sendable {
    /// A slot as the bar drew it, its item as BarSlot.item; one with no width (an item drawing nothing, or one gone for
    /// room) still counts in its side's order.
    public struct Slot: Sendable {
        public let item: BarTrayItem
        public let minX: Double, maxX: Double

        public init(item: BarTrayItem, minX: Double, maxX: Double) {
            (self.item, self.minX, self.maxX) = (item, minX, maxX)
        }

        public init(kind: BarKind, minX: Double, maxX: Double) { self.init(item: .kind(kind), minX: minX, maxX: maxX) }

        /// Its kind as BarSlot.kind: an extension's item is of the Extensions kind.
        public var kind: BarKind { item.kind ?? .extensions }

        var drawn: Bool { maxX > minX }
        var midX: Double { (minX + maxX) / 2 }
    }

    /// Where the dragged item lands: before the slot at `index` of `side`'s slots without it, the caret at `caret`.
    public struct Target: Equatable, Sendable {
        public let side: TopBarSide
        public let index: Int
        public let caret: Double

        public init(side: TopBarSide, index: Int, caret: Double) { (self.side, self.index, self.caret) = (side, index, caret) }
    }

    /// Each side's slots in order, every one of them.
    public let sides: [TopBarSide: [Slot]]
    public let width: Double, height: Double
    /// An empty side's zone, and how far in from the bar's edge the left and right ones sit.
    static let emptyZone = 60.0, edge = 4.0
    /// A zone's reach past its first and last slot, and a drop's reach under the bar.
    static let pad = 3.0, below = 8.0
    /// The caret past a side's first or last slot: just outside its zone's edge, never on it.
    static let caretGap = 6.0
    /// How far in from the Group's edges a drop joins it rather than landing beside it.
    static let groupEdge = 8.0

    /// Whether a drop at `x`, `y` lands in the Group: on the bar, inside the Group's drawn slot.
    public func joinsGroup(x: Double, y: Double, dragging: BarTrayItem?) -> Bool {
        (0...height + Self.below).contains(y) && Self.joinsGroup(x: x, slots: TopBarSide.allCases.flatMap { sides[$0] ?? [] }, dragging: dragging)
    }

    /// Whether a drop at `x` lands in the Group (the strip's own slots as drawn): inside its drawn slot, a little in from
    /// its edges so a drop at either edge still goes beside it, for an item that can join.
    public static func joinsGroup(x: Double, slots: [Slot], dragging: BarTrayItem?) -> Bool {
        group(x: x, slots: slots, dragging: dragging) != nil
    }

    /// The group a drop at `x` joins, 1 the Group, 2 and on one more (Q182); nil for none.
    public static func group(x: Double, slots: [Slot], dragging: BarTrayItem?) -> Int? {
        guard dragging.map(BarSettings.groupable) == true else { return nil }
        let hit = slots.first { slot in
            guard slot.drawn, slot.item.drawnKind == .group else { return false }
            return (slot.minX + groupEdge...max(slot.minX + groupEdge, slot.maxX - groupEdge)).contains(x)
        }
        guard let hit else { return nil }
        if case .group(let number) = hit.item { return number }
        return 1
    }

    /// The same on the bar: a drop at `x`, `y` down from the bar's top edge.
    public func group(x: Double, y: Double, dragging: BarTrayItem?) -> Int? {
        guard (0...height + Self.below).contains(y) else { return nil }
        return Self.group(x: x, slots: TopBarSide.allCases.flatMap { sides[$0] ?? [] }, dragging: dragging)
    }

    public init(sides: [TopBarSide: [Slot]], width: Double, height: Double) {
        (self.sides, self.width, self.height) = (sides, width, height)
    }

    /// The side's drop zone along the bar: its drawn slots' span, or an empty side's 60 points at its place.
    public func zone(_ side: TopBarSide) -> ClosedRange<Double> {
        let drawn = (sides[side] ?? []).filter(\.drawn), end = width - Self.edge
        if let first = drawn.first, let last = drawn.last { return first.minX - Self.pad...last.maxX + Self.pad }
        switch side {
        case .left: return Self.edge...Self.edge + Self.emptyZone
        case .centre: return (width - Self.emptyZone) / 2...(width + Self.emptyZone) / 2
        case .right: return end - Self.emptyZone...end
        }
    }

    /// The side a drop at `x` lands on: the zones in the order they sit along the bar (a long right side can reach past an
    /// empty centre's), each reaching halfway to the next.
    func side(at x: Double) -> TopBarSide {
        // An empty side keeps its whole zone even where a full neighbour reaches over it, as on a strip narrower than the
        // bar (P98); one so covered takes no share of the split below, or it would claim the far end.
        let zones = TopBarSide.allCases.map { (side: $0, span: zone($0), empty: !(sides[$0] ?? []).contains(where: \.drawn)) }
        if let hit = zones.first(where: { $0.empty && $0.span.contains(x) }) { return hit.side }
        let ordered = zones.filter { zone in zone.empty == false || !zones.contains { !$0.empty && $0.span.overlaps(zone.span) } }
            .map { ($0.side, $0.span) }.sorted { $0.1.lowerBound < $1.1.lowerBound }
        return zip(ordered, ordered.dropFirst()).first { x < ($0.1.upperBound + $1.1.lowerBound) / 2 }?.0.0 ?? ordered.last!.0
    }

    /// Where `dragging` lands for a drop at `x`, `y` down from the bar's top edge; nil off the bar (the caller decides
    /// what that means). Nil `dragging` is something not on the bar yet. The index counts the side's slots without the
    /// dragged one, a built-in item or an extension's, and never goes before Pilot's icon, which leads the left side.
    public func target(x: Double, y: Double, dragging: BarKind) -> Target? { target(x: x, y: y, dragging: .kind(dragging)) }

    public func target(x: Double, y: Double, dragging: BarTrayItem?) -> Target? {
        guard (0...height + Self.below).contains(y) else { return nil }
        let side = side(at: x)
        let others = (sides[side] ?? []).filter { $0.item != dragging }
        let lead = others.prefix { $0.kind.pinned }.count
        let next = others.indices.first { $0 >= lead && others[$0].drawn && others[$0].midX > x }
        let index = max(lead, next ?? others.lastIndex(where: \.drawn).map { $0 + 1 } ?? others.count)
        let before = others[..<index].last(where: \.drawn), after = others[index...].first(where: \.drawn)
        let caret = switch (before, after) {
        case let (b?, a?): (b.maxX + a.minX) / 2
        case let (b?, nil): b.maxX + Self.caretGap
        case let (nil, a?): a.minX - Self.caretGap
        case (nil, nil): (zone(side).lowerBound + zone(side).upperBound) / 2
        }
        return Target(side: side, index: index, caret: caret)
    }
}

extension BarSettings {
    /// A drop on the top bar: the item goes to `side`, before the slot now at `index` of that side's top bar slots without
    /// it, or last past the end. A reading joins the Group wherever it lands while the Group is shown (slots' rule). Pilot
    /// never moves: its icon leads the left side.
    public mutating func place(_ kind: BarKind, on side: TopBarSide, at index: Int) { place(.kind(kind), on: side, at: index) }

    /// The same for an extension's own item (spec pilot-1.1 T50), placed in the top bar's order like a built-in one;
    /// one with no place there yet changes nothing.
    public mutating func place(_ item: BarTrayItem, on side: TopBarSide, at index: Int) {
        guard item.kind?.pinned != true, self.index(of: item) != nil else { return }
        // Put at a place of its own, an item is out of the Group (Sven on build 2372: dragged out, it stays out).
        set(item, grouped: false)
        removeEmptyGroups()
        let others = slots(in: .topBar, topBarOn: true, side: side).filter { $0.item != item }
        // A link can name any index: below 0 is first.
        let index = max(index, 0)
        guard index < others.count else { return move(item, to: side) }
        set(item, side: side)
        // The slot's own item: the Group's is the Group, never its first member (which may be the item moved).
        let target = others[index].item
        move(item, to: entries.filter { $0.item != item }.firstIndex { $0.item == target }!)
    }

    /// An item put on the top bar (a pilot://bar add link, pilot bar-items add): the item goes on, joins the top bar (one in the macOS menu bar alone is put in
    /// both) and lands as a drop does. Pilot is on and placed already.
    public mutating func add(_ kind: BarKind, on side: TopBarSide, at index: Int) {
        guard !kind.pinned else { return }
        // The Group draws nothing without a reading: one put back after it went with its readings brings round 4's three.
        if kind == .group, gathered.isEmpty { for reading in BarKind.groupStarters { join(reading); set(reading, grouped: true) } }
        join(kind)
        place(kind, on: side, at: index)
    }

    /// Whether `item` can sit in the Group: a groupable built-in item, or any extension's own item (Q182).
    public static func groupable(_ item: BarTrayItem) -> Bool {
        switch item {
        case .kind(let kind): kind.groupable
        case .extension: true
        case .divider, .group: false
        }
    }

    /// Puts a groupable item in the Group (a drop on its outline, `pilot bar group`): on, in every bar the Group is in.
    /// False for an item that cannot join, or while the Group is off.
    @discardableResult public mutating func group(_ kind: BarKind) -> Bool { group(.kind(kind)) }

    /// The same for any item into group `number` (1 the Group, while it is on): an extension's own item joins the top
    /// bar first, where its group gathers it. A group past the first not there yet is made where the item is, in the top
    /// bar (Q182: extensions in one pill, the readings in another), as one more divider is.
    @discardableResult public mutating func group(_ item: BarTrayItem, into number: Int = 1) -> Bool {
        guard Self.groupable(item), number >= 1 else { return false }
        if number == 1 {
            guard entry(.group).on else { return false }
        }
        switch item {
        case .kind(let kind):
            set(kind, on: true)
            if number == 1 { set(kind, placement: entry(.group).placement) }
            else if entry(kind).placement == .menuBar { set(kind, placement: .both) }
        case .extension(let id):
            if !isOn(extension: id, in: .topBar) { toggle(extension: id, in: .topBar) }
        case .divider, .group: return false
        }
        if number > 1, index(of: .group(number)) == nil, let at = index(of: item) {
            addGroup(number, side: entries[at].side)
            move(.group(number), to: at)
        }
        set(item, group: number)
        removeEmptyGroups()
        return true
    }

    /// The next free group number past the first: a new pill.
    public var nextGroup: Int { (moreGroups.max() ?? 1) + 1 }

    /// Takes one item out of the Group.
    public mutating func ungroup(_ kind: BarKind) { ungroup(.kind(kind)) }

    /// Takes one item out of its group, or every item of group `number` (Ungroup; nil every group): each comes out
    /// where its group is, in the order it drew, on its group's side. The Group, empty, draws nothing until an item joins
    /// it again; one more group, empty, goes.
    public mutating func ungroup(_ item: BarTrayItem? = nil, group number: Int? = nil) {
        let members = entries.filter { entry in
            guard let n = entry.groupNumber else { return false }
            return item.map { entry.item == $0 } ?? (number.map { n == $0 } ?? true)
        }
        for member in members {
            let group: BarTrayItem = member.groupNumber! > 1 ? .group(member.groupNumber!) : .kind(.group)
            set(member.item, group: nil)
            guard let at = index(of: group) else { continue }
            set(member.item, side: entries[at].side)
            move(member.item, to: entries.filter { $0.item != member.item }.firstIndex { $0.item == group }!)
        }
        removeEmptyGroups()
    }

    /// The item on, in the top bar: one in the macOS menu bar alone is put in both.
    private mutating func join(_ kind: BarKind) {
        set(kind, on: true)
        if entry(kind).placement == .menuBar { set(kind, placement: .both) }
    }

    /// The readings the top bar's Group gathers now; none while it is off.
    private var gathered: [BarKind] { slots(in: .topBar, topBarOn: true).first(where: \.isGroup)?.kinds ?? [] }

    /// Takes the slot `kind` draws off the bar (a remove link or the right-click menu's Remove; Sven on build 52 could not get rid of his
    /// readings): the item goes off; the Group goes off with the readings it gathers, so its slot goes rather than coming
    /// apart into one item per reading. Pilot never goes.
    public mutating func remove(slot kind: BarKind) {
        guard !kind.pinned else { return }
        if kind == .group { for reading in gathered { set(reading, on: false) } }
        set(kind, on: false)
    }

    /// Where `item`'s slot is in the top bar with the bar on: its side and its place there from 0; nil while it is not
    /// there. A reading the Group gathers is at the Group's place.
    public func topBarPlace(_ item: BarTrayItem) -> (side: TopBarSide, index: Int)? {
        let sides = preview(.topBar).top ?? [:]
        return TopBarSide.allCases.lazy.compactMap { side in
            sides[side]?.firstIndex { $0.item == item || $0.isGroup && $0.entries.contains { $0.item == item } }.map { (side, $0) }
        }.first
    }

    /// Moves `kind`'s slot one place along the top bar, `step` -1 left or 1 right: within its side, and past a side's end
    /// into the next side's near end. Nothing goes before Pilot's icon; a reading the Group gathers has no slot to move.
    public mutating func nudge(_ kind: BarKind, by step: Int) { nudge(.kind(kind), by: step) }

    /// The same for an extension's own item, or any item by what a drag moves.
    public mutating func nudge(_ item: BarTrayItem, by step: Int) {
        guard item.kind?.pinned != true, let index = index(of: item) else { return }
        let side = entries[index].side, all = slots(in: .topBar, topBarOn: true, side: side)
        guard let at = all.firstIndex(where: { $0.item == item }) else { return }
        // `place` counts the side's slots without the moved one, so one place either way is `at + step` in both.
        let to = at + step, lead = all.prefix { $0.kind.pinned }.count
        if to >= lead, to < all.count { return place(item, on: side, at: to) }
        let sides = TopBarSide.allCases, next = sides.firstIndex(of: side)! + step
        guard sides.indices.contains(next) else { return }
        place(item, on: sides[next], at: step < 0 ? .max : 0)
    }
}

/// The spacer at a width of Sven's own (Sven on build 21: free spacing; the Menu bar page's Width since Q185): one spacer
/// at any width, saved with the bar, rather than several spacers (dividers are the one item the top bar holds more of).
public enum BarSpacer {
    public static let widths: ClosedRange<Double> = 4...600

    /// Its width as drawn: stretched, else its style's.
    public static func width(_ entry: BarEntry) -> Double { entry.width ?? (entry.style == .flexible ? 40 : 14) }

    static func clamp(_ width: Double) -> Double { min(max(width.rounded(), widths.lowerBound), widths.upperBound) }
}

/// A pilot://bar link (card agent-bo-95423017): `move=<kind>`, `add=<kind>` (each with `side=left|centre|right` and
/// `index=<n>`, else the item's own side and last there) or `remove=<kind>` does what a drag does; `edit=1` opens the
/// Menu bar page, where the bar is dragged; `spacer=<points>` sets the spacer's width as the page's Width does (`spacer=reset` gives it back its style's). A link
/// naming an item or side this Pilot lacks is nil, and the app logs it.
public enum BarRoute: Equatable, Sendable {
    case edit
    case spacer(Double?)
    case move(BarKind, side: TopBarSide?, index: Int?)
    case add(BarKind, side: TopBarSide?, index: Int?)
    case remove(BarKind)

    public init?(_ url: URL) {
        var to: TopBarSide?
        if let side = url.queryValue("side") {
            guard let known = TopBarSide(rawValue: side) else { return nil }
            to = known
        }
        let index = url.queryValue("index").flatMap { Int($0) }
        let kind = { (name: String) in url.queryValue(name).flatMap(BarKind.init(rawValue:)) }
        if let kind = kind("move") { self = .move(kind, side: to, index: index) }
        else if let kind = kind("add") { self = .add(kind, side: to, index: index) }
        else if let kind = kind("remove") { self = .remove(kind) }
        else if url.queryValue("edit") == "1" { self = .edit }
        else if let spacer = url.queryValue("spacer") {
            guard spacer == "reset" || Double(spacer) != nil else { return nil }
            self = .spacer(Double(spacer))
        }
        else { return nil }
    }

    /// Its change to the bar; opening the Menu bar page changes nothing here.
    public func apply(to s: inout BarSettings) {
        switch self {
        case .edit: break
        case .move(let kind, let side, let index): s.place(kind, on: side ?? s.entry(kind).side, at: index ?? .max)
        case .add(let kind, let side, let index): s.add(kind, on: side ?? s.entry(kind).side, at: index ?? .max)
        case .remove(let kind): s.remove(slot: kind)
        case .spacer(let width): s.setSpacer(width: width)
        }
    }
}
