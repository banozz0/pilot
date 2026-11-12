import Foundation

/// The Menu bar page's edits (card agent-bo-95422913, design round 4 section 6): the page shows one placement at a time
/// (Menu bar, Top bar or Both) and + or a switch puts an item in that placement or takes it out, keeping the other.
extension BarSettings {
    /// Whether `kind` is in `placement` as the page shows it: both bars for Both, that bar (alone or with the other) for
    /// one bar. Pilot is in every one, as both bars draw it (card agent-bo-95423009).
    public func isOn(_ kind: BarKind, in placement: BarPlacement) -> Bool {
        let entry = entry(kind)
        guard entry.on else { return false }
        if kind.pinned { return true }
        switch placement {
        case .both: return entry.placement == .both
        case .menuBar: return entry.placement != .topBar
        case .topBar: return entry.placement != .menuBar
        }
    }

    /// + or the switch: in, the item joins `placement` and keeps the other bar it was in; out, it leaves `placement` and
    /// stays in the other, or goes off when that was its only place. Pilot is pinned in both, so it never moves; other
    /// apps never join the menu bar.
    public mutating func toggle(_ kind: BarKind, in placement: BarPlacement) {
        guard !kind.pinned else { return }
        let entry = entry(kind), joining = !isOn(kind, in: placement)
        let (menu, top): (Bool, Bool) = {
            let wasMenu = entry.on && entry.placement != .topBar, wasTop = entry.on && entry.placement != .menuBar
            switch placement {
            case .menuBar: return (joining, wasTop)
            case .topBar: return (wasMenu, joining)
            case .both: return (joining, joining)
            }
        }()
        set(kind, on: menu || top)
        if menu || top { set(kind, placement: menu && top ? .both : menu ? .menuBar : .topBar) }
    }

    /// Items on in the top bar only, which show nowhere while it is off (card agent-bo-95422993, G1): the page offers to
    /// put them in the menu bar too. Other apps are not among them: their items are the menu bar's own.
    public var onlyInTopBar: [BarKind] {
        entries.filter { $0.on && $0.placement == .topBar && !$0.kind.topBarOnly && $0.dividerID == nil }.map(\.kind)
    }

    /// Puts each item in the macOS menu bar as well, keeping the top bar it is in.
    public mutating func showInMenuBar(_ kinds: [BarKind]) {
        for kind in kinds { set(kind, in: .menuBar, on: true) }
    }

    /// Puts the item in `placement` or takes it out, as the page's switch does, only when it is not already so.
    public mutating func set(_ kind: BarKind, in placement: BarPlacement, on: Bool) {
        if on != isOn(kind, in: placement) { toggle(kind, in: placement) }
    }

    /// The page's line over `onlyInTopBar`: up to three named, then how many more. Nil while the top bar is on, or for none.
    public static func onlyInTopBarLine(_ kinds: [BarKind], topBarOn: Bool) -> String? {
        guard !topBarOn, !kinds.isEmpty else { return nil }
        let names = kinds.prefix(3).map(\.title) + (kinds.count > 3 ? ["\(kinds.count - 3) more"] : [])
        let list = spokenList(names)
        let one = kinds.count == 1
        return "\(list) \(one ? "is" : "are") in the top bar only, which is off, so \(one ? "it shows" : "they show") nowhere."
    }

    /// Clear all (Sven, Q411) for the placement the page shows: every item and the extensions' items in `ids` (one
    /// never placed is on) leave that bar and stay in the other; Both takes them off both. Pilot's own icon is pinned,
    /// so it stays.
    public mutating func clearAll(in placement: BarPlacement, extensions ids: [String]) {
        for kind in BarKind.allCases {
            if placement == .both { set(kind, on: false) } else { set(kind, in: placement, on: false) }
        }
        for id in ids {
            if placement == .both { set(extension: id, on: false, placement: extensionEntry(id).placement) }
            else if isOn(extension: id, in: placement) { toggle(extension: id, in: placement) }
        }
        if placement != .menuBar { removeMoreDividers() }
    }

    /// Whether Clear all in `placement` would change nothing.
    public func isClear(in placement: BarPlacement, extensions ids: [String]) -> Bool {
        var cleared = self
        cleared.clearAll(in: placement, extensions: ids)
        return cleared == self
    }

    /// The order the page drags into: `kind` lands where `target` is.
    public mutating func move(_ kind: BarKind, onto target: BarKind) {
        guard kind != target, let index = index(of: .kind(target)) else { return }
        set(kind, side: entry(target).side)
        move(kind, to: index)
    }

    /// What the page's preview draws for `placement`: the top bar's three sides and the macOS menu bar, each nil when
    /// that bar is not shown; with Both, the menu bar keeps only what stays there while the top bar is on. The same
    /// slots the bars draw.
    public func preview(_ placement: BarPlacement) -> (top: [TopBarSide: [BarSlot]]?, menu: [BarSlot]?) {
        let top = placement == .menuBar ? nil
            : Dictionary(uniqueKeysWithValues: TopBarSide.allCases.map { ($0, slots(in: .topBar, topBarOn: true, side: $0)) })
        return (top, placement == .topBar ? nil : slots(in: .menuBar, topBarOn: placement == .both))
    }
}

/// The Stats page's menu-bar chooser (card agent-bo-95422992; Sven, 2026-10-07: the Readings block moves to Stats): a
/// chip per reading that flips the same setting the Menu bar page's switch flips, and the readings' look, Text, Graph or
/// One item.
extension BarSettings {
    /// Every item that shows one of This Mac's readings, in BarKind's order.
    public static let readingKinds = BarKind.allCases.filter { $0.stat != nil }

    public enum ReadingsLook: String, CaseIterable, Sendable {
        case text, graph, oneItem
    }

    /// The readings, the ones in the menu bar first in the bar's order and numbered from 1, then the rest in BarKind's.
    public var readingChips: [(kind: BarKind, order: Int?)] {
        let on = entries.map(\.kind).filter { Self.readingKinds.contains($0) && isOn($0, in: .menuBar) }
        return on.enumerated().map { ($1, Optional($0 + 1)) } + Self.readingKinds.filter { !on.contains($0) }.map { ($0, nil) }
    }

    /// A chip's click: the reading joins the menu bar or leaves it, as the Menu bar page's switch does.
    public mutating func toggleReading(_ kind: BarKind) { toggle(kind, in: .menuBar) }

    /// One item while the Group is in the menu bar; else Graph when a reading there draws a graph, else Text.
    public var readingsLook: ReadingsLook {
        if isOn(.group, in: .menuBar) { return .oneItem }
        return Self.readingKinds.contains { isOn($0, in: .menuBar) && entry($0).style == .graph } ? .graph : .text
    }

    /// Text and Graph take the Group out of the menu bar and give every reading that style where it has it, its first
    /// style where not; One item puts the Group in.
    public mutating func setReadingsLook(_ look: ReadingsLook) {
        if (look == .oneItem) != isOn(.group, in: .menuBar) { toggle(.group, in: .menuBar) }
        guard look != .oneItem else { return }
        let style: BarStyle = look == .graph ? .graph : .text
        for kind in Self.readingKinds { set(kind, style: kind.styles.contains(style) ? style : kind.styles[0]) }
    }
}

/// What the Menu bar page drags (Sven, Q185, 2026-10-16): a built-in item or an extension's own item, between the bar
/// tray and the strip of the bar the page shows. Carried by a drag as its `rawValue`.
public enum BarTrayItem: Hashable, Sendable {
    case kind(BarKind)
    case `extension`(String)
    /// One more divider past the first, by its number (BarEntry.dividerID): the top bar's alone.
    case divider(Int)

    public var rawValue: String {
        switch self {
        case .kind(let kind): "kind:" + kind.rawValue
        case .extension(let id): "extension:" + id
        case .divider(let id): "divider:\(id)"
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix("kind:"), let kind = BarKind(rawValue: String(rawValue.dropFirst(5))) { self = .kind(kind) }
        else if rawValue.hasPrefix("extension:"), rawValue.count > 10 { self = .extension(String(rawValue.dropFirst(10))) }
        else if rawValue.hasPrefix("divider:"), let id = Int(rawValue.dropFirst(8)), id > 0 { self = .divider(id) }
        else { return nil }
    }

    /// The built-in item it is, nil for an extension's or one more divider.
    public var kind: BarKind? { if case .kind(let kind) = self { kind } else { nil } }

    /// The built-in item it draws as: one more divider is a divider; nil for an extension's.
    public var drawnKind: BarKind? { if case .divider = self { .divider } else { kind } }

    /// Whether it lives in the top bar alone, so the macOS menu bar's strip takes no drop of it.
    public var topBarOnly: Bool {
        switch self {
        case .kind(let kind): kind.topBarOnly
        case .extension: false
        case .divider: true
        }
    }
}

/// Where a drop on the page's strip lands: a side of the top bar and the place on it, as BarDrop.Target, or the place
/// in the macOS menu bar's row of Pilot's items.
public enum BarStripDrop: Equatable, Sendable {
    case top(TopBarSide, index: Int)
    case menu(index: Int)
}

/// The Menu bar page's strip and tray (Sven, Q185, 2026-10-16): the strip is the bar the page shows (Menu bar, Top bar,
/// or Both's top bar and what stays in the menu bar), the tray every item not on it by group. A drop on the strip puts
/// the item there at the drop's place, a drag along it reorders, a drop on the tray takes it off. Each is one call
/// here, so the drag and the tests make the same change.
extension BarSettings {
    /// Whether `kind` is drawn in the strip for `placement`: in one of its slots, the Group only while it gathers a
    /// reading (it draws nothing without one).
    public func onStrip(_ kind: BarKind, placement: BarPlacement) -> Bool {
        stripSlots(placement).contains { kind == .group ? $0.isGroup : $0.kinds.contains(kind) }
    }

    /// Whether an extension's item is drawn for `placement`: its own item in the menu bar or its own slot in the top bar.
    public func onStrip(extension id: String, placement: BarPlacement) -> Bool {
        switch placement {
        case .menuBar: shows(extension: id, in: .menuBar, topBarOn: false)
        case .topBar: shows(extension: id, in: .topBar, topBarOn: true)
        case .both: shows(extension: id, in: .topBar, topBarOn: true) || shows(extension: id, in: .menuBar, topBarOn: true)
        }
    }

    /// Whether a piece is drawn in the strip for `placement`, a built-in item or an extension's.
    public func onStrip(_ item: BarTrayItem, placement: BarPlacement) -> Bool {
        switch item {
        case .kind(let kind): onStrip(kind, placement: placement)
        case .extension(let id): onStrip(extension: id, placement: placement)
        case .divider: placement != .menuBar && index(of: item) != nil
        }
    }

    /// The tray for `placement`: each group with its items not on the strip, groups with none left out, one item a chip
    /// (Sven on build 54: one by one, not by sections). Pilot is never there (it is pinned); items of the top bar alone
    /// are not offered for the menu bar. The old Extensions item is not either: `extensions` (their ids) offer each
    /// extension's own item, one by one. The divider is always there for the top bar: once one is on it, the chip is
    /// one more (Sven on build 2363: any number of dividers).
    public func tray(_ placement: BarPlacement, extensions: [String] = []) -> [(group: BarGroup, items: [BarTrayItem])] {
        BarGroup.allCases.compactMap { group in
            let kinds = BarKind.allCases.filter {
                $0.group == group && !$0.pinned && $0 != .extensions && !(placement == .menuBar && $0.topBarOnly)
                    && (!onStrip($0, placement: placement) || $0 == .divider && placement != .menuBar)
            }
            let items = kinds.map { $0 == .divider ? dividerToAdd(placement) : .kind($0) }
                + (group == .extensions ? extensions.filter { !onStrip(extension: $0, placement: placement) }.map(BarTrayItem.extension) : [])
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// The divider the tray and `pilot add bar-items` add for `placement`: the divider item until it is on the strip,
    /// then one more on the top bar, a number no divider has.
    public func dividerToAdd(_ placement: BarPlacement) -> BarTrayItem {
        guard placement != .menuBar, onStrip(.divider, placement: placement) else { return .kind(.divider) }
        return .divider((entries.compactMap(\.dividerID).max() ?? 0) + 1)
    }

    /// A drop of `item` on the strip for `placement` at `drop`; false where it cannot land (Pilot, which never moves; an
    /// item of the top bar alone on the menu bar). On Top bar the item joins the top bar and keeps the menu bar; on Menu
    /// bar the reverse; on Both the top bar's strip puts it in both bars and the menu bar's in the menu bar alone. One
    /// already there moves: the same call reorders.
    @discardableResult public mutating func drop(_ item: BarTrayItem, on drop: BarStripDrop, placement: BarPlacement) -> Bool {
        guard case .kind(let kind) = item else {
            if case .extension(let id) = item { return self.drop(extension: id, on: drop, placement: placement) }
            if case .divider(let id) = item { return self.drop(divider: id, on: drop, placement: placement) }
            return false
        }
        guard !kind.pinned else { return false }
        switch (drop, placement) {
        case (.top(let side, let index), .topBar):
            set(kind, in: .topBar, on: true)
            fillGroup(kind, in: .topBar)
            place(kind, on: side, at: index)
        case (.top(let side, let index), .both):
            set(kind, on: true)
            set(kind, placement: .both)
            fillGroup(kind, in: .topBar)
            place(kind, on: side, at: index)
        case (.menu(let index), .menuBar), (.menu(let index), .both):
            guard !kind.topBarOnly else { return false }
            if placement == .both {
                set(kind, on: true)
                set(kind, placement: .menuBar)
            } else {
                set(kind, in: .menuBar, on: true)
            }
            fillGroup(kind, in: .menuBar)
            placeInMenuBar(kind, at: index, topBarOn: placement == .both)
        case (.top, .menuBar), (.menu, .topBar): return false
        }
        return true
    }

    /// An extension's item dropped on the strip: it joins that bar as the page's switch does, and in the top bar lands
    /// where it drops, its own slot in the order as a built-in item's is (spec pilot-1.1 T50). In the macOS menu bar it
    /// is its own item, beside Pilot's, where macOS puts it.
    private mutating func drop(extension id: String, on drop: BarStripDrop, placement: BarPlacement) -> Bool {
        switch (drop, placement) {
        case (.top, .topBar): if !shows(extension: id, in: .topBar, topBarOn: true) { set(extension: id, on: true, placement: isOn(extension: id, in: .menuBar) ? .both : .topBar) }
        case (.top, .both): set(extension: id, on: true, placement: .both)
        case (.menu, .menuBar): if !isOn(extension: id, in: .menuBar) { toggle(extension: id, in: .menuBar) }
        case (.menu, .both): set(extension: id, on: true, placement: .menuBar)
        case (.top, .menuBar), (.menu, .topBar): return false
        }
        if case .top(let side, let index) = drop { place(.extension(id), on: side, at: index) }
        return true
    }

    /// One more divider dropped on the top bar's strip: new from the tray, it is made there; one already there moves. The
    /// macOS menu bar holds only the first.
    private mutating func drop(divider id: Int, on drop: BarStripDrop, placement: BarPlacement) -> Bool {
        guard case .top(let side, let index) = drop, placement != .menuBar else { return false }
        if self.index(of: .divider(id)) == nil { addDivider(id, side: side) }
        place(.divider(id), on: side, at: index)
        return true
    }

    /// A drop on the tray: the item leaves the strip for `placement`. On Menu bar or Top bar it leaves that bar and stays
    /// in the other; on Both it goes off. The Group takes the readings it gathers with it, so its slot goes whole. Pilot
    /// never goes.
    @discardableResult public mutating func takeOff(_ item: BarTrayItem, placement: BarPlacement) -> Bool {
        switch item {
        case .kind(let kind):
            guard !kind.pinned, onStrip(kind, placement: placement) else { return false }
            let gathered = kind == .group ? groupSlotKinds(placement) : []
            for each in [kind] + gathered {
                if placement == .both { set(each, on: false) } else { set(each, in: placement, on: false) }
            }
        case .extension(let id):
            guard onStrip(extension: id, placement: placement) else { return false }
            if placement == .both { set(extension: id, on: false, placement: extensionEntry(id).placement) }
            else if isOn(extension: id, in: placement) { toggle(extension: id, in: placement) }
        case .divider:
            guard onStrip(item, placement: placement) else { return false }
            removeDivider(item)
        }
        return true
    }

    /// One place along its bar's row for the page's Move left and Move right (the drag's keyboard way): in the top bar
    /// as nudge does, into the next side past a side's end; in the menu bar one slot over.
    public mutating func step(_ kind: BarKind, by step: Int, inTopBar: Bool, topBarOn: Bool) {
        guard !kind.pinned else { return }
        if inTopBar { return nudge(.kind(kind), by: step) }
        let slots = slots(in: .menuBar, topBarOn: topBarOn)
        guard let at = slots.firstIndex(where: { $0.item == .kind(kind) }) else { return }
        let to = at + step
        guard slots.indices.contains(to) else { return }
        placeInMenuBar(kind, at: to, topBarOn: topBarOn)
    }

    /// The same for an extension's own item: along the top bar as a built-in item's; in the macOS menu bar it has no
    /// place in Pilot's order to step.
    public mutating func step(_ item: BarTrayItem, by step: Int, inTopBar: Bool, topBarOn: Bool) {
        switch item {
        case .kind(let kind): self.step(kind, by: step, inTopBar: inTopBar, topBarOn: topBarOn)
        case .extension, .divider: if inTopBar { nudge(item, by: step) }
        }
    }

    /// The menu bar's order: `kind` goes before the slot now at `index` of the menu bar's slots without it, or after the
    /// last past the end.
    public mutating func placeInMenuBar(_ kind: BarKind, at index: Int, topBarOn: Bool) {
        // By item, not kind: the top bar's more dividers are dividers too.
        let others = slots(in: .menuBar, topBarOn: topBarOn).filter { $0.item != .kind(kind) }
        guard let last = others.last else { return }
        let rest = entries.filter { $0.item != .kind(kind) }
        if index >= 0, index < others.count {
            move(kind, to: rest.firstIndex { $0.item == others[index].item }!)
        } else if index < 0, let first = others.first {
            move(kind, to: rest.firstIndex { $0.item == first.item }!)
        } else {
            move(kind, to: rest.firstIndex { $0.item == last.item }! + 1)
        }
    }

    /// The Group put on with no reading to gather draws nothing: it brings round 4's three into the same bar.
    private mutating func fillGroup(_ kind: BarKind, in place: BarPlace) {
        guard kind == .group, !slots(in: place, topBarOn: place == .topBar).contains(where: \.isGroup) else { return }
        for reading in [BarKind.cpu, .memory, .network] {
            if place == .topBar { set(reading, in: .topBar, on: true) } else { set(reading, in: .menuBar, on: true) }
        }
    }

    /// The readings the Group's slot gathers in the strip for `placement`.
    private func groupSlotKinds(_ placement: BarPlacement) -> [BarKind] {
        stripSlots(placement).filter(\.isGroup).flatMap(\.kinds)
    }

    /// Every slot the strip for `placement` draws: the top bar's sides in order, then the menu bar's.
    private func stripSlots(_ placement: BarPlacement) -> [BarSlot] {
        let preview = preview(placement)
        let top = preview.top.map { sides in TopBarSide.allCases.flatMap { sides[$0] ?? [] } } ?? []
        return top + (preview.menu ?? [])
    }
}

extension BarDrop {
    /// Where a drop at `x` lands in the macOS menu bar's row of Pilot's items (`slots` as drawn, hidden ones with no
    /// width): before the first drawn slot whose middle is right of it, the caret between the two; past them all, last.
    public static func menuTarget(x: Double, slots: [Slot], dragging: BarKind) -> (index: Int, caret: Double) {
        menuTarget(x: x, slots: slots, dragging: .kind(dragging))
    }

    public static func menuTarget(x: Double, slots: [Slot], dragging: BarTrayItem?) -> (index: Int, caret: Double) {
        let others = slots.filter { $0.item != dragging }
        let index = others.indices.first { others[$0].drawn && others[$0].midX > x } ?? others.count
        let before = others[..<index].last(where: \.drawn), after = others[index...].first(where: \.drawn)
        let caret = switch (before, after) {
        case let (b?, a?): (b.maxX + a.minX) / 2
        case let (b?, nil): b.maxX + caretGap
        case let (nil, a?): a.minX - caretGap
        case (nil, nil): x
        }
        return (index, caret)
    }
}
