import AppKit
import Observation
import PilotCore
import SwiftUI

/// Drag to rearrange on the top bar itself (spec drag-reorder; Sven, 2026-11-14: "is it possible also for menubar?"): a
/// slot to another place on its side or another side (an island, on the island presets), a group's member along its
/// group, into another group or out to a side. It lands as a drop on the Menu bar page's strip does (BarDrop's target,
/// BarSettings.place), so the page and the bar keep one order. One model for every bar window: each island draws the
/// whole row cropped, so the gap and the dragged piece show in whichever window they cross.
@Observable @MainActor
final class BarDrag {
    static let shared = BarDrag()

    /// What is dragged: a slot of `side` at `slot`, or the member at `member` of group `group` (a run of readings is
    /// one member and moves as one), drawn at `frame` as the drag began.
    struct Piece: Equatable {
        let screen: String
        let items: [BarTrayItem]
        let side: TopBarSide
        let slot: Int
        let group: Int?
        let member: Int?
        let frame: CGRect
        /// Its width and the gap after it: how far the others slide.
        let room: CGFloat
    }

    /// Where it lands: before the slot now at `index` of a side's others, or the member at `index` of a group's others.
    enum Target: Equatable {
        case side(TopBarSide, Int)
        case group(Int, Int)
    }

    /// A member of a group as a bar drew it, keyed by its group and its place among the group's members.
    struct MemberKey: Hashable {
        let screen: String
        let group: Int
        let index: Int
    }

    /// Each group's members as drawn at rest, in BarFrames' space, and what each moves.
    @ObservationIgnored private(set) var members: [MemberKey: (items: [BarTrayItem], frame: CGRect)] = [:]
    @ObservationIgnored var frames = BarFrames.shared
    @ObservationIgnored var store: BarItemsStore?

    private(set) var piece: Piece?
    private(set) var dx: CGFloat = 0
    private(set) var target: Target?
    /// The bar's slots and the drop's zones as the drag began.
    @ObservationIgnored private var sides: [TopBarSide: [BarSlot]] = [:]
    @ObservationIgnored private var drop: BarDrop?
    @ObservationIgnored private var press: (piece: Piece, x: CGFloat, size: CGSize)?

    init() {}

    /// A render's mid-drag state (DragRenders).
    init(rendering piece: Piece, dx: CGFloat, target: Target?) {
        (self.piece, self.dx, self.target) = (piece, dx, target)
    }

    var dragging: Bool { piece != nil }

    /// A group's member drew at `frame` (TopBarSlotView); unchanged frames and reports during a drag write nothing.
    func report(_ frame: CGRect, items: [BarTrayItem], group: Int, index: Int, on screen: String) {
        guard piece == nil else { return }
        let key = MemberKey(screen: screen, group: group, index: index)
        if members[key]?.frame != frame || members[key]?.items != items { members[key] = (items, frame) }
    }

    // MARK: A bar window's press (BarPanelDrag)

    /// A press at `point` on `screen`'s bar `size` big: a group's member under it, else a slot; never Pilot's icon.
    func pressed(at point: CGPoint, on screen: String, size: CGSize) -> Bool {
        press = nil
        guard let store else { return false }
        let sides = store.settings.preview(.topBar).top ?? [:]
        func room(_ frame: CGRect, among others: [CGRect]) -> CGFloat {
            let next = others.filter { $0.minX >= frame.maxX }.map(\.minX).min(), before = others.filter { $0.maxX <= frame.minX }.map(\.maxX).max()
            return frame.width + (next.map { $0 - frame.maxX } ?? before.map { frame.minX - $0 } ?? 8)
        }
        // A member's report outlives a move out of its group (the ones left never report again): one counts only while
        // its items are still in that group and it lies inside the group's slot as drawn now; the rest go.
        func place(_ group: Int) -> (side: TopBarSide, index: Int)? { store.settings.topBarPlace(group > 1 ? .group(group) : .kind(.group)) }
        func current(_ key: MemberKey, _ member: (items: [BarTrayItem], frame: CGRect)) -> Bool {
            guard member.items.allSatisfy({ store.settings.entry(for: $0)?.groupNumber == key.group }), let spot = place(key.group),
                  let slot = frames.frames[.init(screen: key.screen, side: spot.side, index: spot.index)] else { return false }
            return slot.minX <= member.frame.midX && member.frame.midX <= slot.maxX
        }
        members = members.filter { current($0.key, $0.value) }
        if let hit = members.first(where: { $0.key.screen == screen && $0.value.frame.width > 0 && $0.value.frame.contains(point) }),
           let spot = place(hit.key.group) {
            let mates = members.filter { $0.key.screen == screen && $0.key.group == hit.key.group && $0.key != hit.key }.map(\.value.frame)
            press = (Piece(screen: screen, items: hit.value.items, side: spot.side, slot: spot.index, group: hit.key.group, member: hit.key.index,
                           frame: hit.value.frame, room: room(hit.value.frame, among: mates)), point.x, size)
        } else if let hit = slot(at: point, on: screen, in: sides), let found = sides[hit.side]?[hit.index], !found.kind.pinned {
            let mates = (sides[hit.side] ?? []).indices.compactMap { $0 == hit.index ? nil : frames.frames[.init(screen: screen, side: hit.side, index: $0)] }
            press = (Piece(screen: screen, items: [found.item], side: hit.side, slot: hit.index, group: nil, member: nil, frame: hit.frame,
                           room: room(hit.frame, among: mates)), point.x, size)
        }
        if press != nil { self.sides = sides }
        return press != nil
    }

    func moved(to point: CGPoint) {
        guard let press else { return }
        if piece == nil {
            let screen = press.piece.screen
            drop = BarDrop(sides, size: press.size) { [frames] in frames.frames[.init(screen: screen, side: $0, index: $1)] }
            piece = press.piece
            BarPanel.shared.close()
        }
        dx = point.x - press.x
        let next = landing(x: press.piece.frame.midX + dx, y: point.y)
        if next != target { target = next }
    }

    /// The drop, then the gap closing in one animation. Off the bar it lands nowhere and the piece goes back.
    func released(at point: CGPoint) {
        if let piece, let target, let store {
            var s = store.settings
            var members: [[BarTrayItem]] = []
            if case .group(let number, _) = target { members = memberFrames(number, on: piece.screen).map(\.items) }
            Self.apply(piece, target, to: &s, members: members)
            if s != store.settings { withAnimation(DockDrag.settle) { store.settings = s } }
        }
        withAnimation(DockDrag.settle) { (piece, dx, target) = (nil, 0, nil) }
        (press, drop) = (nil, nil)
    }

    /// What a drop makes of the settings: to a side through `place`, as `pilot bar move` does; into a group through
    /// `place(_:inGroup:at:)`, as `pilot bar group --index` does, the place counted in the group's entries.
    static func apply(_ piece: Piece, _ target: Target, to s: inout BarSettings, members: [[BarTrayItem]]) {
        switch target {
        case .side(let side, let index):
            // Pilot's icon never takes a place of its own: out of its group it goes back to the left's lead.
            for (k, item) in piece.items.enumerated() {
                if item.kind?.pinned == true { s.ungroup(item) } else { s.place(item, on: side, at: index + k) }
            }
        case .group(let number, let index):
            // The group's entries without the dragged ones, so the member at `index` of the others is found by its first.
            let others = members.filter { $0.first.map { !piece.items.contains($0) } ?? false }
            let entries = (s.slots(in: .topBar, topBarOn: true).first { $0.groupNumber == number }?.entries ?? []).map(\.item).filter { !piece.items.contains($0) }
            let at = others.indices.contains(index) ? entries.firstIndex(of: others[index][0]) ?? entries.count : entries.count
            for (k, item) in piece.items.enumerated() { s.place(item, inGroup: number, at: at + k) }
        }
    }

    // MARK: Where it lands, and the gap

    /// Over a group's outline the piece joins it, before the first of its others whose middle is right of `x`; anywhere
    /// else on the bar BarDrop's side and place; below the bar nowhere.
    private func landing(x: CGFloat, y: CGFloat) -> Target? {
        guard let piece, let drop, let first = piece.items.first else { return nil }
        if let number = drop.group(x: Double(x), y: Double(y), dragging: first) {
            let others = memberFrames(number, on: piece.screen).filter { $0.items != piece.items }
            return .group(number, others.filter { $0.frame.midX < x }.count)
        }
        return drop.target(x: Double(x), y: Double(y), dragging: piece.group == nil ? first : nil).map { .side($0.side, $0.index) }
    }

    /// The offset of the slot at `index` of `side` on `screen`'s bar; each side keeps its anchor.
    func offset(side: TopBarSide, index: Int, on screen: String) -> CGFloat {
        let slot = piece?.group == nil && piece?.side == side ? piece?.slot : nil
        var entering: Int?
        if case .side(let to, let at)? = target, to == side { entering = at }
        return offset(side, index, dragged: slot, entering: entering, on: screen)
    }

    /// The offset of the member at `index` of group `group`: the group holds its left end, as the left side does.
    func offset(member index: Int, group: Int, on screen: String) -> CGFloat {
        var entering: Int?
        if case .group(let number, let at)? = target, number == group { entering = at }
        return offset(.left, index, dragged: piece?.group == group ? piece?.member : nil, entering: entering, on: screen)
    }

    /// The piece at `index` of a row anchored at `anchor` on `screen`: the dragged one (at `dragged`) follows the
    /// pointer, the rest open the gap at `entering`.
    private func offset(_ anchor: TopBarSide, _ index: Int, dragged: Int?, entering: Int?, on screen: String) -> CGFloat {
        guard let piece, piece.screen == screen else { return 0 }
        if dragged == index { return dx }
        return CGFloat(DragGap.shift(anchor, j: index, leaving: dragged, entering: entering, width: Double(piece.room)))
    }

    /// Whether the slot at `index` of `side` is dragged or holds the dragged member, drawn over the rest.
    func lifts(side: TopBarSide, index: Int, on screen: String) -> Bool {
        piece.map { $0.screen == screen && $0.side == side && $0.slot == index } ?? false
    }

    // MARK: Reading the bar

    private func slot(at point: CGPoint, on screen: String, in sides: [TopBarSide: [BarSlot]]) -> (side: TopBarSide, index: Int, frame: CGRect)? {
        for side in TopBarSide.allCases {
            for index in (sides[side] ?? []).indices {
                if let rect = frames.frames[.init(screen: screen, side: side, index: index)], rect.width > 0, rect.contains(point) { return (side, index, rect) }
            }
        }
        return nil
    }

    private func memberFrames(_ group: Int, on screen: String) -> [(items: [BarTrayItem], frame: CGRect)] {
        members.filter { $0.key.screen == screen && $0.key.group == group && $0.value.frame.width > 0 }.sorted { $0.key.index < $1.key.index }.map(\.value)
    }
}

/// One bar window's part of the drag: its screen and its row's view, whose space is BarFrames'.
@MainActor
final class BarPanelDrag: PanelDrag {
    let screen: String
    weak var host: NSView?
    let drag = BarDrag.shared

    init(screen: String, host: NSView) { (self.screen, self.host) = (screen, host) }

    func pressed(at point: CGPoint) -> Bool { drag.pressed(at: point, on: screen, size: host?.bounds.size ?? .zero) }
    func moved(to point: CGPoint) { drag.moved(to: point) }
    func released(at point: CGPoint) { drag.released(at: point) }
}
