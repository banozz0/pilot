import Foundation
import Observation

/// Home's edit mode as a model (spec home-edit, seam 1): the layout at entry, the draft every edit changes, one undo step
/// per edit back to the entry, and the block carried with the slot it hovers. Done saves the draft; Escape and Cancel give
/// the entry back (Sven, 2026-10-12: only Done saves). The views draw it and the tests drive it with none.
@Observable @MainActor
final class HomeEditSession {
    /// Where a carried block can land, in Home's lanes as drawn. `before` is the drawn block it goes in front of (a board
    /// row's first block), nil for the lane's end.
    enum Place: Hashable, Sendable {
        /// In the column's row of icon tabs.
        case icons(before: String?)
        /// Among the column's small cards.
        case column(before: String?)
        /// A board row of its own, between rows. A medium's row pairs it with the medium after it, as `HomeLayout.lanes`
        /// pairs (forward): before a lone medium, or after one, it pairs with that one.
        case board(before: String?)
        /// The empty half beside a lone medium, its left or its right (`trailing`): it pairs with it.
        case beside(String, trailing: Bool)

        /// The size a block of size `carried` takes here: the lane sets it. The column's icon row gives icon, its cards
        /// small; beside a medium gives medium; between board rows a board block keeps its size and any other turns medium.
        func size(carrying carried: HomeLayout.Size) -> HomeLayout.Size {
            switch self {
            case .icons: .icon
            case .column: .small
            case .beside: .medium
            case .board: carried.lane == .board ? carried : .medium
            }
        }
    }

    /// The layout as edit mode began; Escape and Cancel give it back.
    let entry: HomeLayout
    private(set) var draft: HomeLayout
    /// The block picked up, shown or from the tray, and the place it hovers, if any.
    private(set) var carried: String?
    private(set) var target: Place?
    private var steps: [HomeLayout] = []
    /// The installed extensions with a page, whose rows the draft lists.
    let extensions: [String]

    init(layout: HomeLayout, extensions: [String]) {
        entry = layout
        draft = layout
        self.extensions = extensions
    }

    var canUndo: Bool { !steps.isEmpty }

    /// The draft as it would be if the carried block dropped where it hovers: what the page draws while it makes room.
    var preview: HomeLayout {
        guard let carried, let target else { return draft }
        var layout = draft
        layout.put(carried, at: target, listed: listed)
        return layout
    }

    // MARK: Carrying

    /// Picks a block up: a shown one, or a hidden one dragged from the tray.
    func pickUp(_ id: String) {
        guard listed.contains(id) else { return }
        carried = id
        target = nil
    }

    /// The place under the carried block, nil off every slot (it drops back where it was).
    func hover(_ place: Place?) {
        guard carried != nil, target != place else { return }
        target = place
    }

    /// Drops the carried block where it hovers: shown, at the place's size. Off every slot it goes back unchanged.
    func drop() {
        guard carried != nil else { return }
        if target != nil { edit { $0 = preview } }
        putBack()
    }

    /// The carried block back where it was, the draft unchanged (the first Escape while carrying).
    func putBack() {
        carried = nil
        target = nil
    }

    // MARK: Edits

    /// A size chip: the size picks the lane, so a size in the other lane moves the block there.
    func size(_ id: String, _ size: HomeLayout.Size) { edit { $0.set(id, size: size) } }

    /// ✕, or a drop on the tray: hidden, its place and size kept.
    func hide(_ id: String) {
        if carried == id { putBack() }
        edit { $0.set(id, shown: false) }
    }

    /// A tray chip clicked: shown at its saved place and size.
    func show(_ id: String) { edit { $0.set(id, shown: true) } }

    func reset() { edit { $0 = .standard } }

    /// One edit back, to the entry at most. While a block is carried it only puts it back.
    func undo() {
        if carried != nil { putBack(); return }
        if let last = steps.popLast() { draft = last }
    }

    // MARK: Leaving

    /// Escape: puts a carried block back first; with none it throws the edit away and answers true (edit mode ends).
    func escape() -> Bool {
        if carried != nil { putBack(); return false }
        cancel()
        return true
    }

    /// Cancel: the entry layout back, every edit thrown away.
    func cancel() {
        putBack()
        draft = entry
        steps = []
    }

    /// Done: saves the draft; one Home draws as the default saves as nothing (`home.blocks` removed), so a later default
    /// is the one read.
    func done(_ store: HomeLayoutStore) {
        putBack()
        if draft.isStandard(extensions: extensions) { store.reset() } else { store.save(draft) }
    }

    // MARK: -

    private var listed: [String] { draft.resolved(extensions: extensions).map(\.id) }

    /// One undo step, when the edit changes the rows Home lists (not only the hidden ones a move takes in).
    private func edit(_ change: (inout HomeLayout) -> Void) {
        var next = draft
        change(&next)
        guard next.resolved(extensions: extensions) != draft.resolved(extensions: extensions) else { return }
        steps.append(draft)
        draft = next
    }
}

extension HomeLayout {
    /// Puts `id` at a place, shown, at the size the place gives.
    mutating func put(_ id: String, at place: HomeEditSession.Place, listed: [String]) {
        set(id, size: place.size(carrying: size(of: id)))
        set(id, shown: true)
        switch place {
        case .icons(let before), .column(let before), .board(let before): move(id, before: before, listed: listed)
        case .beside(let other, false): move(id, before: other, listed: listed)
        case .beside(let other, true): move(id, after: other, listed: listed)
        }
    }
}
