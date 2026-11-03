import Foundation
import Observation
import PilotCore

/// Home's edit mode as a model (spec home-edit, seam 1; P91's grid): the layout at entry, the draft every edit changes, one
/// undo step per edit back to the entry, and the block carried or resized with the cells it would take. Done saves the
/// draft; Escape and Cancel give the entry back (Sven, 2026-10-12: only Done saves). The views draw it and the tests drive
/// it with none.
@Observable @MainActor
final class HomeEditSession {
    /// The layout as edit mode began; Escape and Cancel give it back.
    let entry: HomeLayout
    private(set) var draft: HomeLayout
    /// The block picked up (shown, or from the tray) or held by a handle, and the cells it would take, if any.
    private(set) var carried: String?
    private(set) var target: HomeCell?
    private var steps: [HomeLayout] = []
    /// The installed extensions with a page, whose rows the draft lists.
    let extensions: [String]
    /// The style Home draws in: only the blocks it draws are packed (Instrument's notices are its Pilot block); nil packs
    /// every shown block.
    let style: PilotStyle?

    init(layout: HomeLayout, extensions: [String], style: PilotStyle? = nil) {
        entry = layout
        draft = layout
        self.extensions = extensions
        self.style = style
    }

    var canUndo: Bool { !steps.isEmpty }

    /// The blocks a layout has Home draw, in its order.
    func drawn(_ layout: HomeLayout) -> [String] { layout.drawn(style, extensions: extensions) }

    /// The cells Home draws a layout at.
    func cells(_ layout: HomeLayout) -> [String: HomeCell] { layout.cells(drawn(layout)) }

    /// The draft as it would be if the carried block took the cells it hovers: what the page draws while it makes room.
    var preview: HomeLayout {
        guard let carried, let target else { return draft }
        var layout = draft
        layout.put(carried, on: target, style: style, extensions: extensions, from: cells(draft)[carried])
        return layout
    }

    // MARK: Carrying

    /// Picks a block up (a drag or a handle): a shown one, or a hidden one dragged from the tray.
    func pickUp(_ id: String) {
        guard listed.contains(id) else { return }
        carried = id
        target = nil
    }

    /// The cells under the carried block, nil off the grid (it goes back where it was).
    func hover(_ cell: HomeCell?) {
        guard carried != nil, target != cell else { return }
        target = cell
    }

    /// Drops the carried block on the cells it hovers, shown. Off the grid it goes back unchanged.
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

    /// Moves a block `dx` columns and `dy` rows (an arrow key, VoiceOver's moves). Up or down goes as far as it takes to
    /// pass the block it meets, so each press changes something while there is room.
    func move(_ id: String, dx: Int, dy: Int) {
        if let next = moved(id, dx: dx, dy: dy) { edit { $0 = next } }
    }

    /// The draft with `id` moved, nil when the move changes nothing Home draws (VoiceOver offers only the moves that do).
    func moved(_ id: String, dx: Int, dy: Int) -> HomeLayout? {
        let cells = cells(draft)
        guard let cell = cells[id] else { return nil }
        if dy == 0 { return changed(put(id, HomeCell(x: min(max(0, cell.x + dx), HomeGrid.columns - cell.w), y: cell.y, w: cell.w, h: cell.h), in: draft)) }
        let lowest = cells.values.map(\.maxY).max() ?? 0
        var y = cell.y + dy
        while y >= 0 && y <= lowest {
            var next = draft
            next.put(id, on: HomeCell(x: cell.x, y: y, w: cell.w, h: cell.h), style: style, extensions: extensions, from: cell)
            if next.cell(of: id)?.y != cell.y { return changed(next) }
            y += dy
        }
        return nil
    }

    /// Grows or shrinks a block by whole cells (Shift-arrows, VoiceOver's Wider, Narrower, Taller and Shorter), from its
    /// top left, within the columns and never under one cell.
    func resize(_ id: String, dw: Int, dh: Int) {
        if let next = resized(id, dw: dw, dh: dh) { edit { $0 = next } }
    }

    /// The draft with `id` resized, nil when the size cannot change (the columns' edge, one cell, HomeCell.tallest rows).
    func resized(_ id: String, dw: Int, dh: Int) -> HomeLayout? {
        guard let cell = cells(draft)[id] else { return nil }
        let resized = cell.resized([.right, .bottom], dx: dw, dy: dh)
        return resized == cell ? nil : changed(put(id, resized, in: draft))
    }

    /// A block onto `cell`, the others making room.
    func put(_ id: String, _ cell: HomeCell) { edit { $0 = put(id, cell, in: $0) } }

    private func put(_ id: String, _ cell: HomeCell, in layout: HomeLayout) -> HomeLayout {
        var next = layout
        next.put(id, on: cell, style: style, extensions: extensions, from: cells(layout)[id])
        return next
    }

    /// `next`, unless Home would draw it as the draft.
    private func changed(_ next: HomeLayout) -> HomeLayout? { cells(next) == cells(draft) ? nil : next }

    /// The Layout chip: a class kept, or Auto with nil.
    func layout(_ id: String, _ layout: Widget.SizeClass?) { edit { $0.set(id, layout: layout) } }

    /// ✕, or a drop on the tray: hidden, its cells and Layout kept; the blocks under it float up.
    func hide(_ id: String) {
        if carried == id { putBack() }
        edit { $0.hide(id, style: style, extensions: extensions) }
    }

    /// A tray chip clicked: shown on its saved cells (the blocks there move down), else at the grid's foot.
    func show(_ id: String) { edit { $0.put(id, style: style, extensions: extensions) } }

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

    /// One undo step, when the edit changes the rows Home lists.
    private func edit(_ change: (inout HomeLayout) -> Void) {
        var next = draft
        change(&next)
        guard next.resolved(extensions: extensions) != draft.resolved(extensions: extensions) else { return }
        steps.append(draft)
        draft = next
    }
}
