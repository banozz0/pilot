import AppKit
import PilotCore
import SwiftUI

// Home's edit mode (spec home-edit, direction B "Workbench", Sven 2026-10-12; P91's grid, model A) and Home's extension
// blocks, drawn in every style through the Kit. Edit mode is on Home itself: the blocks wiggle under their corner brackets,
// edge grips, Layout chip and ✕, the cells show as dots, hidden blocks wait in the edit bar's tray, and Done keeps the edit
// while Escape and Cancel throw it away (HomeEditSession decides the layout).

/// Home in edit mode: the session every edit goes through, and the block the pointer carries or resizes (T5): a drag on a
/// block moves it, a drag on one of its handles resizes it; either snaps to whole cells, the others making room.
@Observable @MainActor
final class HomeEditMode {
    /// The sides a handle moves: a corner two, an edge grip one.
    typealias Edges = HomeCell.Edges

    /// A block the pointer holds: its cells and frame (page space) at pick-up, where the pointer took it (global) and
    /// where it holds it, and whether it is carried whole or resized by `edges`.
    struct Lift {
        let id: String
        /// Empty: carried whole; else the sides a handle resizes.
        let edges: Edges
        let start: HomeCell
        let frame: CGRect
        let from: CGPoint
        let grab: CGSize
        /// Dragged out of the tray: it floats as its chip.
        let fromTray: Bool
        /// One a pick-up, so each lift draws afresh.
        let serial: Int

        var resizing: Bool { !edges.isEmpty }
    }

    let session: HomeEditSession
    /// The block lifted, from pick-up until it has landed.
    private(set) var lift: Lift?
    /// The pointer while carrying, global: the floating block follows it 1:1.
    private(set) var pointer: CGPoint = .zero
    /// The pointer is on the edit bar: a drop there hides the block.
    private(set) var overTray = false
    /// Where the floating block flies as the pointer lets go, global; it fades there.
    private(set) var landing: CGRect?
    /// Auto-scroll's way, -1 up, 1 down, 0 still; its speed in pt/s is `scrollSpeed`.
    private(set) var scrolling = 0
    @ObservationIgnored private(set) var scrollSpeed: CGFloat = 0
    /// Where Home's page measures itself; the page hands it over as it draws in edit mode.
    @ObservationIgnored var frames: HomeFrames?
    @ObservationIgnored private var dwell: Timer?
    @ObservationIgnored private var landed: Timer?
    @ObservationIgnored private var pending: HomeCell?
    @ObservationIgnored private var gesture: CGPoint?
    @ObservationIgnored private var lifts = 0
    /// Reduce Motion is on (the page hands it over): no wiggle, lift scale or spring; changes fade 150 ms.
    @ObservationIgnored var reduceMotion = false
    /// The block the keyboard is on, and whether a key has been pressed since edit mode began: its ring shows only then,
    /// so a mouse never sees one.
    var focus: String?
    private(set) var keyed = false

    init(session: HomeEditSession) {
        self.session = session
    }

    /// The block held now: lifted and not yet dropped, put back or hidden.
    var carrying: Lift? { lift.flatMap { session.carried == $0.id ? $0 : nil } }

    // MARK: Carrying and resizing

    /// A drag on Home's page, global: its first move lifts the block under where it began; then the block follows. A drag
    /// whose block went back (Escape) moves nothing until the pointer lets go.
    func drag(from start: CGPoint, to point: CGPoint) {
        follow(from: start, to: point) { origin in
            if let id = frames?.block(at: start - origin) { pickUp(id, at: start - origin, from: start) }
        }
    }

    /// A drag on one of a block's handles, global: its first move takes the block by those sides.
    func resize(_ id: String, edges: Edges, from start: CGPoint, to point: CGPoint) {
        follow(from: start, to: point) { origin in
            guard let rect = frames?.frame(of: id) else { return }
            lift(id, edges: edges, frame: rect, from: start, grab: CGSize(width: start.x - origin.x - rect.minX, height: start.y - origin.y - rect.minY),
                 fromTray: false)
        }
    }

    /// A tray chip dragged, global: a hidden block lifted as its chip, shown where it is dropped.
    func dragHidden(_ id: String, from start: CGPoint, to point: CGPoint) {
        follow(from: start, to: point) { origin in
            lift(id, edges: [], frame: CGRect(origin: start - origin, size: .zero), from: start, grab: .zero, fromTray: true)
        }
    }

    /// A drag's move: its first (a new start) lifts with `begin`, given the page's origin; every one moves the held block.
    private func follow(from start: CGPoint, to point: CGPoint, begin: (CGPoint) -> Void) {
        if start != gesture {
            gesture = start
            if let origin = frames?.origin { begin(origin) }
        }
        move(to: point)
    }

    /// Lifts `id` where the page drew it, held at `point` in the page's space.
    func pickUp(_ id: String, at point: CGPoint, from start: CGPoint) {
        guard let rect = frames?.frame(of: id) else { return }
        lift(id, edges: [], frame: rect, from: start, grab: CGSize(width: point.x - rect.minX, height: point.y - rect.minY), fromTray: false)
    }

    private func lift(_ id: String, edges: Edges, frame: CGRect, from: CGPoint, grab: CGSize, fromTray: Bool) {
        guard let frames else { return }
        session.pickUp(id)
        guard session.carried == id else { return }
        dwell?.invalidate()
        landed?.invalidate()
        (dwell, landed, pending, landing, overTray) = (nil, nil, nil, nil, false)
        lifts += 1
        let draft = session.draft
        let start = frames.cells[id] ?? draft.cell(of: id) ?? HomeGrid.foot(HomeLayout.size(of: id), under: [])
        lift = Lift(id: id, edges: edges, start: start, frame: frame, from: from, grab: grab, fromTray: fromTray, serial: lifts)
        pointer = from
    }

    /// The held block under a new pointer, global.
    func move(to point: CGPoint) {
        guard let lift = carrying else { return }
        pointer = point
        overTray = !lift.resizing && frames?.bar?.contains(point) == true
        aimScroll()
        aim()
    }

    /// The cells the held block would take with the pointer where it is now: a carried block's frame snapped to the
    /// nearest cells at its own size (its width cut at the grid's right edge), a resized one's sides moved by whole cells.
    func cells(for lift: Lift) -> HomeCell? {
        guard !overTray, let frames, let origin = frames.origin, let inner = frames.inner else { return nil }
        if lift.resizing {
            let across = HomeGrid.cellWidth(inner) + HomeGrid.gap
            return lift.start.resized(lift.edges, dx: Int(((pointer.x - lift.from.x) / across).rounded()),
                                      dy: Int(((pointer.y - lift.from.y) / HomeGrid.pitch).rounded()))
        }
        let at = pointer - origin
        let frame = CGRect(x: at.x - lift.grab.width, y: at.y - lift.grab.height, width: 1, height: 1)
        guard let near = frames.cell(nearest: frame) else { return nil }
        return HomeCell(x: near.x, y: near.y, w: lift.start.w, h: lift.start.h).clamped
    }

    /// The cells under the pointer: a resize follows at once; a carried block's new cells count once the pointer has
    /// rested on them 80 ms, and the page makes room for it.
    func aim() {
        guard let lift = carrying else { return }
        let cell = cells(for: lift)
        guard cell != session.target else {
            dwell?.invalidate()
            dwell = nil
            return
        }
        if lift.resizing { return target(cell) }
        if dwell != nil, pending == cell { return }
        dwell?.invalidate()
        pending = cell
        dwell = Self.after(HomeMotion.rest) { [weak self] in self?.target(cell) }
    }

    private func target(_ cell: HomeCell?) {
        dwell = nil
        guard carrying != nil, session.target != cell else { return }
        withAnimation(settle) { session.hover(cell) }
        if cell != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// The pointer lets go: on the tray the block hides; else it takes the cells under the pointer, rested on or not;
    /// a resize that went nowhere changes nothing. The floating block flies to where it now lies.
    func release() {
        // The next drag lifts afresh, even from the same point.
        gesture = nil
        guard let lift = carrying else { return }
        dwell?.invalidate()
        dwell = nil
        scroll(0)
        if overTray {
            withAnimation(settle) { session.hide(lift.id) }
            withAnimation(HomeMotion.fade) { self.lift = nil; overTray = false }
            return
        }
        withAnimation(settle) {
            session.hover(cells(for: lift))
            session.drop()
        }
        land(lift)
    }

    /// The held block back where it was (Escape, ⌘Z while carrying), the draft unchanged.
    func putBack() {
        guard let lift = carrying else { return }
        dwell?.invalidate()
        dwell = nil
        scroll(0)
        withAnimation(settle) { session.putBack() }
        land(lift)
    }

    /// The floating block to the frame its block takes once the page has drawn the drop, fading as it lands; a block
    /// left hidden (a tray chip dropped off the grid), a resize, or any under Reduce Motion, just ends.
    private func land(_ lift: Lift) {
        landed?.invalidate()
        if reduceMotion || lift.resizing { return finish(lift) }
        landed = Self.after(.milliseconds(20)) { [weak self] in
            guard let self, self.lift?.serial == lift.serial else { return }
            let shown = session.draft.shown(extensions: session.extensions).contains(lift.id)
            guard shown, let rect = frames?.frame(of: lift.id), let origin = frames?.origin else { return finish(lift) }
            withAnimation(settle) { landing = rect.offsetBy(dx: origin.x, dy: origin.y) }
            landed = Self.after(.milliseconds(300)) { [weak self] in self?.finish(lift) }
        }
    }

    private func finish(_ lift: Lift) {
        landed = nil
        guard self.lift?.serial == lift.serial else { return }
        withAnimation(HomeMotion.fade) { self.lift = nil; landing = nil; overTray = false }
    }

    /// `body` once, `wait` from now, on the main run loop in every mode (a drag may hold it in event tracking).
    private static func after(_ wait: Duration, _ body: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: wait / .seconds(1), repeats: false) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// What VoiceOver says as edit mode begins.
    static let entered = "Editing Home. Each block's actions move, size and hide it; Return keeps the edit, Escape throws it away."

    /// A layout change's animation: the spring, or under Reduce Motion a 150 ms fade.
    var settle: Animation { HomeMotion.settle(reduce: reduceMotion) }

    /// Escape: a held block goes back first; else the edit is thrown away and edit mode ends (true).
    func escape() -> Bool {
        if carrying != nil { putBack(); return false }
        return session.escape()
    }

    /// ⌘Z: a held block goes back first; else one edit back.
    func undo() {
        if carrying != nil { putBack() } else { session.undo() }
    }

    // MARK: Auto-scroll

    /// Within 40 pt of the page's top or bottom edge as it shows, the page scrolls, faster nearer the edge, up to 900 pt/s;
    /// the edit bar's own height scrolls nothing.
    private func aimScroll() {
        guard let window = frames?.window, !overTray else { return scroll(0) }
        let top = window.minY, bottom = frames?.bar?.minY ?? window.maxY, edge = HomeMotion.scrollEdge, y = pointer.y
        if y < top + edge { scroll(-HomeMotion.scrollFastest * min(1, (top + edge - y) / edge)) }
        else if y > bottom - edge, y <= bottom { scroll(HomeMotion.scrollFastest * min(1, (y - bottom + edge) / edge)) }
        else { scroll(0) }
    }

    private func scroll(_ speed: CGFloat) {
        scrollSpeed = speed
        let way = speed < 0 ? -1 : speed > 0 ? 1 : 0
        if scrolling != way { scrolling = way }
    }

    // MARK: Keyboard and VoiceOver

    /// A key on the focused block in edit mode (spec home-edit, check 11; P91). Escape, Return and ⌘Z are the edit bar's.
    enum Key: Equatable {
        /// Tab and Shift-Tab: the next block or the one before; past either end the window's own Tab goes on (the bar).
        case tab, backTab
        /// The arrows move the block a cell, Shift and the arrows size it, 1 to 4 keep Strip, Square, Wide or Large (0
        /// Auto), ⌫ hides it.
        case edit(Edit)

        static func move(dx: Int, dy: Int) -> Key { .edit(.move(dx: dx, dy: dy)) }
        static func resize(dw: Int, dh: Int) -> Key { .edit(.resize(dw: dw, dh: dh)) }
        static func layout(_ layout: Widget.SizeClass?) -> Key { .edit(.layout(layout)) }
        static let hide = Key.edit(.hide)
    }

    /// An edit a key or VoiceOver makes on a block, as its mouse twin does: a drag, a handle, the Layout chip, the ✕.
    enum Edit: Equatable {
        case move(dx: Int, dy: Int)
        case resize(dw: Int, dh: Int)
        case layout(Widget.SizeClass?)
        case hide
    }

    /// The blocks focus walks, in reading order: by row, then column, as `blocks` (the ones Home draws) sit in the draft.
    func order(_ blocks: [String]) -> [String] { HomeLayout.reading(session.draft.cells(blocks)) }

    /// A key on the focused block, `blocks` the ones Home draws: true when edit mode takes it. While the pointer holds a
    /// block the keys wait.
    func press(_ key: Key, blocks: [String]) -> Bool {
        if carrying != nil { return true }
        keyed = true
        let order = order(blocks)
        guard let id = focus, let at = order.firstIndex(of: id) else {
            // Nothing focused yet: the first block takes the focus (the last, going back).
            switch key {
            case .tab, .edit(.move): focus = order.first
            case .backTab: focus = order.last
            case .edit: return false
            }
            return focus != nil
        }
        switch key {
        case .tab, .backTab:
            let next = at + (key == .tab ? 1 : -1)
            guard order.indices.contains(next) else { return false }
            focus = order[next]
        case .edit(.hide):
            let rest = order.filter { $0 != id }
            session.hide(id)
            focus = rest.isEmpty ? nil : rest[min(at, rest.count - 1)]
        case .edit(let edit): perform(edit, on: id)
        }
        return true
    }

    /// What VoiceOver offers on a block (check 12): the moves and sizes that change what Home draws, each Layout but its
    /// own, and Hide.
    func actions(for id: String) -> [(name: String, edit: Edit)] {
        // Each move is tried on the draft, so a block's list is worked out once a draft, not on every redraw.
        if offered?.draft != session.draft { offered = (session.draft, [:]) }
        if let known = offered?.actions[id] { return known }
        let out = offers(for: id)
        offered?.actions[id] = out
        return out
    }

    @ObservationIgnored private var offered: (draft: HomeLayout, actions: [String: [(name: String, edit: Edit)]])?

    private func offers(for id: String) -> [(name: String, edit: Edit)] {
        let moves: [(String, Int, Int)] = [("Move left", -1, 0), ("Move right", 1, 0), ("Move up", 0, -1), ("Move down", 0, 1)]
        let sizes: [(String, Int, Int)] = [("Wider", 1, 0), ("Narrower", -1, 0), ("Taller", 0, 1), ("Shorter", 0, -1)]
        var out: [(name: String, edit: Edit)] = moves.filter { session.moved(id, dx: $0.1, dy: $0.2) != nil }.map { ($0.0, .move(dx: $0.1, dy: $0.2)) }
        out += sizes.filter { session.resized(id, dw: $0.1, dh: $0.2) != nil }.map { ($0.0, .resize(dw: $0.1, dh: $0.2)) }
        let kept = session.draft.layout(of: id)
        out += ([nil] + Widget.SizeClass.allCases.map(Optional.some)).filter { $0 != kept }.map { ("Layout \($0?.title ?? "Auto")", .layout($0)) }
        out.append(("Hide", .hide))
        return out
    }

    /// An edit VoiceOver asked for, made as its mouse twin makes it.
    func perform(_ edit: Edit, on id: String) {
        guard carrying == nil else { return }
        switch edit {
        case .move(let dx, let dy): session.move(id, dx: dx, dy: dy)
        case .resize(let dw, let dh): session.resize(id, dw: dw, dh: dh)
        case .layout(let layout): session.layout(id, layout)
        case .hide: session.hide(id)
        }
        focus = id
    }

    /// A change from a block's right-click, staged in edit mode's draft: edit mode `mode`, else a new one on `layout`, so
    /// Done keeps it and ⌘Z, Escape or Cancel take it back (Moody on T4: at rest it saved at once).
    static func staging(_ edit: (HomeEditSession) -> Void, in mode: HomeEditMode?, make: () -> HomeEditSession) -> HomeEditMode {
        let mode = mode ?? HomeEditMode(session: make())
        edit(mode.session)
        return mode
    }
}

/// What a test watches of edit mode, handed down the window: edit mode while it is on, and where the edit bar last lay.
@MainActor
final class HomeEditWatch {
    var mode: HomeEditMode?
    var on: Bool { mode != nil }
    var bar: CGRect?
}

extension EnvironmentValues {
    @Entry var homeEditWatch: HomeEditWatch? = nil
}

/// Edit mode's motion and measures (spec home-edit notes, Motion).
enum HomeMotion {
    /// Entering: the blocks to 0.98 over 200 ms.
    static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
    static let enterScale: CGFloat = 0.98
    /// The chips and the edit bar fade in and out.
    static let fade = Animation.easeOut(duration: 0.15)
    /// A size change or a block hidden: the others close up on a spring with no bounce.
    static let settle = Animation.spring(duration: 0.3, bounce: 0)
    /// A wiggle's whole period, before each block's own ±8 %.
    static let period = 0.26
    /// A change's animation under Reduce Motion or not: the spring, or a 150 ms fade.
    static func settle(reduce: Bool) -> Animation { reduce ? fade : settle }
    /// A keyboard move (Kit.change, no spring), or a 150 ms fade under Reduce Motion.
    static func keyed(reduce: Bool) -> Animation { reduce ? fade : Kit.change }
    /// Edit mode's rest scale and the carried block's lift: none under Reduce Motion.
    static func enterScale(reduce: Bool) -> CGFloat { reduce ? 1 : enterScale }
    static func liftScale(reduce: Bool) -> CGFloat { reduce ? 1 : liftScale }

    /// A block's top a hold enters edit mode on: its title bar (Instrument's is 44 pt, Toybox's about 48).
    static let titleBar: CGFloat = 48

    /// Pick-up: the carried block lifts to 1.03 under a deeper shadow over 120 ms.
    static let lift = Animation.easeOut(duration: 0.12)
    static let liftScale: CGFloat = 1.03
    /// A new slot counts once the pointer rests in it this long.
    static let rest = Duration.milliseconds(80)
    /// Auto-scroll: within this of the page's shown edge, at most this fast (pt/s).
    static let scrollEdge: CGFloat = 40, scrollFastest: CGFloat = 900

    /// The wiggle's angle in degrees for a block `width` wide: each corner sways 1 pt, at most 1.5°; none under Reduce
    /// Motion.
    static func wiggle(width: CGFloat, reduce: Bool = false) -> Double {
        guard width > 0, !reduce else { return 0 }
        return min(1.5, Double(2 / width) * 180 / .pi)
    }

    /// A block's own period (within ±8 %) and phase, the same for its id every time, so a render draws alike.
    static func rhythm(_ id: String) -> (period: Double, phase: Double) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let spread = Double(hash % 1000) / 999, share = Double((hash / 1000) % 1000) / 999
        let period = Self.period * (0.92 + 0.16 * spread)
        return (period, period * share)
    }
}

extension HomeParts {
    /// Home's edit mode while it is on.
    var editMode: HomeEditMode? { editing.wrappedValue }

    /// An edit session on the saved layout, packing the blocks this style draws.
    func newSession() -> HomeEditSession { HomeEditSession(layout: sources.layout().layout, extensions: beyond, style: style) }

    /// Edit mode on, on the saved layout; a hold says so with a tap under the finger.
    func beginEdit(byHold: Bool = false) {
        guard editing.wrappedValue == nil else { return }
        if byHold { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        let session = newSession()
        withAnimation(HomeMotion.enter) { editing.wrappedValue = HomeEditMode(session: session) }
        AccessibilityNotification.Announcement(HomeEditMode.entered).post()
    }

    /// Done keeps the draft (the default saves as nothing); otherwise the edit is thrown away.
    func endEdit(save: Bool) {
        guard let mode = editing.wrappedValue else { return }
        if save { mode.session.done(sources.layout()) } else { mode.session.cancel() }
        withAnimation(Kit.change) { editing.wrappedValue = nil }
    }

    /// Escape and Cancel: a carried block goes back first, else the edit is thrown away and edit mode ends.
    func escapeEdit() {
        guard let mode = editing.wrappedValue, mode.escape() else { return }
        withAnimation(Kit.change) { editing.wrappedValue = nil }
    }

    /// A Layout or a hide from a block's right-click: a change to edit mode's draft, edit mode turned on first at rest;
    /// nothing is saved until Done.
    func change(_ edit: (HomeEditSession) -> Void) {
        let mode = editing.wrappedValue
        withAnimation(mode?.settle ?? HomeMotion.enter) {
            editing.wrappedValue = HomeEditMode.staging(edit, in: mode, make: newSession)
        }
    }

    /// A block's name: Pilot's own, else its extension page's title, else its Home widget's.
    func title(_ id: String) -> String {
        let ext = HomeLayout.extensionID(id)
        return HomeLayout.Block(rawValue: id)?.title ?? pages.first { $0.id == ext }?.title
            ?? widget(id)?.title ?? ext ?? id
    }
}

/// Home's foot at rest: Edit Home (⌘E), which puts Home in edit mode.
struct HomeEditFoot: View {
    let parts: HomeParts

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button { parts.beginEdit() } label: {
                Label("Edit Home", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.pilot)
            .keyboardShortcut("e", modifiers: .command)
            .help("Move, size, hide and add Home's blocks (⌘E, or hold a block's title bar)")
        }
    }
}

/// Edit mode's bar, pinned to the window's foot at every size: the tray of hidden blocks (a click shows one where it was),
/// then Reset, Cancel (Escape) and Done (Return). Liquid Glass under a see-through tint, so a render without glass still
/// shows the bar.
struct HomeEditBar: View {
    @Environment(\.ink) private var ink
    @Environment(\.style) private var style
    @Environment(\.homeEditWatch) private var watch
    let parts: HomeParts
    let mode: HomeEditMode

    static let height: CGFloat = 48, margin: CGFloat = 12
    /// The height the bar takes from the page.
    static var room: CGFloat { height + 2 * margin }

    /// A block carried from Home is over the bar.
    private var dropping: Bool { mode.overTray && mode.carrying?.fromTray == false }

    var body: some View {
        let session = mode.session
        let hidden = session.draft.resolved(extensions: session.extensions)
            .filter { !$0.shown && HomeLayout.draws($0.id, in: style.kind) }
        let shape = RoundedRectangle(cornerRadius: ink.radius(14), style: .continuous)
        HStack(spacing: 8) {
            Text("Hidden").font(ink.ui(11.5, .semibold)).foregroundStyle(ink.muted).fixedSize()
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if let lift = mode.carrying, mode.overTray, !lift.fromTray {
                        // A block carried onto the tray: let go and it hides here.
                        Text("Let go to hide \(parts.title(lift.id))").font(ink.ui(12, .medium)).foregroundStyle(ink.accentInk).lineLimit(1)
                    } else if hidden.isEmpty {
                        Text("Hide a block with its ✕, or drag it here.").font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                    }
                    ForEach(hidden) { row in
                        let name = parts.title(row.id)
                        // A click shows it where it was; a drag carries it onto Home, where it shows as it is dropped.
                        Chip(text: name, symbol: "plus")
                            .opacity(mode.carrying?.id == row.id ? 0.4 : 1)
                            .contentShape(.capsule)
                            .onTapGesture { withAnimation(mode.settle) { session.show(row.id) } }
                            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                                .onChanged { mode.dragHidden(row.id, from: $0.startLocation, to: $0.location) }
                                .onEnded { _ in mode.release() })
                            .help("Show \(name) where it was, or drag it onto Home's cells")
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Show \(name)")
                            .accessibilityAction { withAnimation(mode.settle) { session.show(row.id) } }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            // A sideways ScrollView takes only sideways deltas: a mouse wheel or an up-down swipe over it turns sideways.
            .background(SidewaysWheel())
            .accessibilityLabel("Hidden blocks")
            Button("Reset") { withAnimation(mode.settle) { session.reset() } }
                .buttonStyle(.pilot)
                .disabled(session.draft.isStandard(extensions: session.extensions))
                .help("Put back the default Home; Done keeps it")
            Button("Cancel") { parts.escapeEdit() }
                .buttonStyle(.pilot).keyboardShortcut(.cancelAction)
                .help("Throw this edit away (Escape)")
            // Return finds a page while the window's search holds words.
            Button("Done") { parts.endEdit(save: true) }
                .buttonStyle(.pilotPrimary).keyboardShortcut(parts.searching ? nil : .defaultAction)
                .help("Keep this Home (Return)")
        }
        // ⌘Z: one edit back, to the layout at entry at most.
        .background {
            Button("Undo") { withAnimation(mode.settle) { mode.undo() } }
                .keyboardShortcut("z", modifiers: .command).disabled(!session.canUndo && session.carried == nil)
                .opacity(0).accessibilityHidden(true)
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: Self.height)
        .background(ink.raised.opacity(0.82), in: shape)
        // A carried block over the bar: the bar takes it, outlined in the accent.
        .overlay { shape.strokeBorder(dropping ? ink.accent : ink.line2, lineWidth: dropping ? 1.5 : 1) }
        .animation(Kit.change, value: dropping)
        .glassEffect(.regular, in: shape)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { watch?.bar = $0 }
        .padding(Self.margin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit Home")
    }
}

/// Over its frame, a scroll that is more up-down than sideways (a mouse wheel, an up-down swipe) goes on as the same
/// scroll sideways, momentum and all, so the edit bar's Hidden tray scrolls with either (Sven on 1.0.2 build 6: "i cant
/// scroll horizontally for 'hidden'"). Clicks and drags pass through.
struct SidewaysWheel: NSViewRepresentable {
    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) {}
    static func dismantleNSView(_ view: Catcher, coordinator: ()) { view.stop() }

    final class Catcher: NSView {
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.turn(event) ? nil : event
            }
        }

        /// Hands an up-down scroll over this frame sideways to the view under it; false leaves the event as it is.
        func turn(_ event: NSEvent) -> Bool {
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), bounds.contains(convert(event.locationInWindow, from: nil)),
                  let under = window?.contentView?.hitTest(event.locationInWindow) else { return false }
            under.scrollWheel(with: Self.sideways(event))
            return true
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The event with its up-down deltas moved to the sideways axis; down scrolls on to the right.
        static func sideways(_ event: NSEvent) -> NSEvent {
            guard let copy = event.cgEvent?.copy() else { return event }
            let pairs: [(CGEventField, CGEventField)] = [(.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
                                                         (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)]
            for (down, side) in pairs {
                copy.setIntegerValueField(side, value: copy.getIntegerValueField(down))
                copy.setIntegerValueField(down, value: 0)
            }
            copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            return NSEvent(cgEvent: copy) ?? event
        }
    }
}

/// A block's Layout chip and its ✕, on its top edge in edit mode: Auto, or one of the four classes kept (the desktop's
/// Edit widget offers the same), and the ✕ that hides it.
struct HomeLayoutChip: View {
    @Environment(\.ink) private var ink
    let id: String
    let parts: HomeParts
    let mode: HomeEditMode
    /// The class the block draws now.
    let drawn: Widget.SizeClass

    var body: some View {
        let kept = mode.session.draft.layout(of: id), name = parts.title(id)
        HStack(spacing: 4) {
            Menu {
                HomeLayoutPicker(selection: Binding(get: { kept }, set: { layout in withAnimation(mode.settle) { mode.session.layout(id, layout) } }))
            } label: {
                HStack(spacing: 5) {
                    Text("Layout").font(ink.ui(11.5, .medium)).foregroundStyle(ink.text2)
                    Text("\(kept == nil ? "Auto · " : "")\(drawn.title)").font(ink.ui(11.5, .semibold)).foregroundStyle(ink.accentInk)
                }
                .padding(.horizontal, 9).frame(height: 24)
                .background(ink.raised, in: .capsule)
                .overlay { Capsule().strokeBorder(ink.line2) }
                .contentShape(.capsule)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Layout: Auto picks it by size; a class keeps it")
            .accessibilityLabel("\(name) layout: \(kept?.title ?? "Auto, \(drawn.title)")")
            HomeHideButton(id: id, parts: parts, mode: mode)
        }
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .fixedSize()
    }
}

/// A block's Layout as a menu's choices: Auto, or one of the four classes, as Edit widget offers them on the desktop.
private struct HomeLayoutPicker: View {
    let selection: Binding<Widget.SizeClass?>

    var body: some View {
        Picker("Layout", selection: selection) {
            Text("Auto: by its size").tag(Widget.SizeClass?.none)
            ForEach(Widget.SizeClass.allCases, id: \.self) { Text($0.title).tag(Widget.SizeClass?.some($0)) }
        }
        .pickerStyle(.inline).labelsHidden()
    }
}

/// A block's ✕ in edit mode: hidden, it waits in the tray.
private struct HomeHideButton: View {
    let id: String
    let parts: HomeParts
    let mode: HomeEditMode

    var body: some View {
        let name = parts.title(id)
        Button { withAnimation(mode.settle) { mode.session.hide(id) } } label: { HomeHideBadge() }
            .buttonStyle(.kitPress)
            .help("Hide \(name); it waits in the tray")
            .accessibilityLabel("Hide \(name)")
    }
}

/// A block's corner brackets and its left, right and bottom edge grips in edit mode: a drag on one resizes the block by
/// whole cells from that side, the others making room.
private struct HomeHandles: View {
    @Environment(\.ink) private var ink
    let id: String
    let mode: HomeEditMode
    /// The block is being resized: its handles in the accent.
    let on: Bool

    private static let corners: [(HomeEditMode.Edges, Alignment, FrameResizePosition)] = [
        ([.top, .left], .topLeading, .topLeading), ([.top, .right], .topTrailing, .topTrailing),
        ([.bottom, .left], .bottomLeading, .bottomLeading), ([.bottom, .right], .bottomTrailing, .bottomTrailing),
    ]
    private static let edges: [(HomeEditMode.Edges, Alignment, FrameResizePosition)] = [
        (.left, .leading, .leading), (.right, .trailing, .trailing), (.bottom, .bottom, .bottom),
    ]

    var body: some View {
        let colour = on ? ink.accent : ink.text2.opacity(0.8)
        ZStack {
            ForEach(Self.corners, id: \.0.rawValue) { edges, alignment, position in
                Bracket(edges: edges).stroke(colour, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 14, height: 14).padding(3)
                    .contentShape(.rect)
                    .grip(id, edges, mode, position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .offset(x: edges.contains(.left) ? -5 : 5, y: edges.contains(.top) ? -5 : 5)
            }
            ForEach(Self.edges, id: \.0.rawValue) { edges, alignment, position in
                let across = edges == .bottom
                Capsule().fill(colour)
                    .frame(width: across ? 26 : 4, height: across ? 4 : 26)
                    .padding(across ? .vertical : .horizontal, 6)
                    .contentShape(.rect)
                    .grip(id, edges, mode, position)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .offset(x: edges == .left ? -8 : edges == .right ? 8 : 0, y: across ? 8 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    /// A corner's L, drawn along the sides it moves.
    private struct Bracket: Shape {
        let edges: HomeEditMode.Edges

        func path(in rect: CGRect) -> Path {
            let x = edges.contains(.left) ? rect.minX : rect.maxX, y = edges.contains(.top) ? rect.minY : rect.maxY
            var path = Path()
            path.move(to: CGPoint(x: edges.contains(.left) ? rect.maxX : rect.minX, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: edges.contains(.top) ? rect.maxY : rect.minY))
            return path
        }
    }
}

private extension View {
    /// A handle's drag: the block resized by `edges`, under the resize pointer.
    func grip(_ id: String, _ edges: HomeEditMode.Edges, _ mode: HomeEditMode, _ position: FrameResizePosition) -> some View {
        pointerStyle(.frameResize(position: position))
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { mode.resize(id, edges: edges, from: $0.startLocation, to: $0.location) }
                .onEnded { _ in mode.release() })
    }
}

extension View {
    /// A block on Home, as edit mode draws it (HomeEditBlock), drawing `drawn` on `cell`.
    func homeEditable(_ id: String, _ parts: HomeParts, drawn: Widget.SizeClass, wide: Bool) -> some View {
        modifier(HomeEditBlock(id: id, parts: parts, drawn: drawn, wide: wide))
    }
}

/// A block on Home. At rest a 0.5 s hold on its title bar (or on empty page, HomeNowPage's) enters edit mode, a hold on
/// its content stays a press, and its right-click offers Edit Home, Layout and Hide. In edit mode it rests a little
/// smaller and wiggles under its corner brackets, edge grips, Layout chip and ✕; its content takes no press, row or hover
/// while its readings go on. The keyboard reaches it (Tab, the arrows move it a cell, Shift and the arrows size it, 1 to 4
/// and 0 its Layout, ⌫ hides it) and VoiceOver offers the same; under Reduce Motion it stays still, outlined dashed.
struct HomeEditBlock: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    let parts: HomeParts
    /// The class it draws now, which its Layout chip says.
    let drawn: Widget.SizeClass
    /// Wide enough for its Layout chip (over 170 pt); narrower, just its ✕ at its corner.
    let wide: Bool
    @State private var pointer = HomePointer()
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let mode = parts.editMode
        // Carried whole, it leaves its cells empty (the page outlines where it lands) while the pointer carries a copy of it
        // (HomeCarryLayer); resized, it draws at its new cells as it goes.
        let held = mode?.carrying?.id == id ? mode?.carrying : nil
        let floated = held.map { !$0.resizing } ?? false
        content
            .allowsHitTesting(mode == nil)
            // In edit mode VoiceOver finds the block, its cells and its actions, not its inert content.
            .accessibilityHidden(mode != nil)
            .opacity(floated ? 0 : 1)
            .animation(HomeMotion.fade, value: floated)
            // In edit mode the block itself is what the pointer finds: a drag on it, from the page (HomeNowPage), carries it.
            .overlay { if mode != nil { Color.clear.contentShape(.rect) } }
            .modifier(HomeWiggle(id: id, on: mode != nil && held == nil && parts.onScreen && !reduceMotion))
            .scaleEffect(mode == nil || held != nil ? 1 : HomeMotion.enterScale(reduce: reduceMotion))
            // Reduce Motion's dashed outline, and the keyboard's ring once a key is pressed.
            .overlay {
                let ring = mode.map { $0.keyed && $0.focus == id } ?? false
                if mode != nil, !floated, reduceMotion || ring { HomeEditOutline(focused: ring).transition(.opacity) }
            }
            .overlay { if let mode, !floated { HomeHandles(id: id, mode: mode, on: held != nil).transition(.opacity) } }
            .overlay(alignment: wide ? .top : .topTrailing) {
                if let mode, !floated {
                    Group {
                        if wide { HomeLayoutChip(id: id, parts: parts, mode: mode, drawn: drawn).offset(y: -12) }
                        else { HomeHideButton(id: id, parts: parts, mode: mode).offset(x: 7, y: -7) }
                    }
                    .transition(.opacity)
                }
            }
            .onContinuousHover { phase in
                if case .active(let at) = phase { pointer.y = at.y } else { pointer.y = nil }
            }
            .gesture(LongPressGesture(minimumDuration: 0.5, maximumDistance: 4).onEnded { _ in
                if let y = pointer.y, y < HomeMotion.titleBar { parts.beginEdit(byHold: true) }
            }, including: mode == nil ? .all : .subviews)
            .contextMenu { menu(mode) }
            // The keyboard in edit mode (check 11): the focus follows edit mode's, and the keys go to the mode.
            .focusable(mode != nil)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press($0) }
            .onChange(of: mode?.focus == id, initial: true) { _, on in if on != focused { focused = on } }
            .onChange(of: focused) { _, on in if on, let mode, mode.focus != id { mode.focus = id } }
            // VoiceOver (check 12): the block, its cells and class, and its moves, sizes, Layouts and Hide.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(parts.title(id))
            .accessibilityValue(mode == nil ? "" : words(id))
            .accessibilityActions {
                // For VoiceOver, Voice Control and Switch Control; worked out once a draft (HomeEditMode.actions(for:)).
                if let mode {
                    ForEach(Array(mode.actions(for: id).enumerated()), id: \.offset) { _, action in
                        Button(action.name) {
                            withAnimation(mode.settle) { mode.perform(action.edit, on: id) }
                            announce(mode)
                        }
                    }
                }
            }
    }

    /// A key press as edit mode reads it: Tab and Shift-Tab, the arrows (with Shift, a resize), ⌫, 1 to 4 and 0 with no
    /// modifier (⌘1 to ⌘4 stay the window's); nil for the rest.
    static func key(_ press: KeyPress) -> HomeEditMode.Key? {
        let mods = press.modifiers.subtracting([.numericPad, .function, .capsLock])
        if press.key == .tab, mods.isSubset(of: .shift) { return mods.contains(.shift) ? .backTab : .tab }
        let arrows: [KeyEquivalent: (Int, Int)] = [.leftArrow: (-1, 0), .rightArrow: (1, 0), .upArrow: (0, -1), .downArrow: (0, 1)]
        if let (dx, dy) = arrows[press.key], mods.isSubset(of: .shift) {
            return mods.contains(.shift) ? .resize(dw: dx, dh: dy) : .move(dx: dx, dy: dy)
        }
        guard mods.isEmpty else { return nil }
        switch press.key {
        case .delete, .deleteForward: return .hide
        default:
            guard press.characters.count == 1, let n = press.characters.first?.wholeNumberValue, (0...4).contains(n) else { return nil }
            return .layout(n == 0 ? nil : Widget.SizeClass.allCases[n - 1])
        }
    }

    /// A key on this block in edit mode, handed to the mode, and said aloud for VoiceOver when it changes a block. Escape
    /// and Return do what the edit bar's Cancel and Done do: a focused block takes the key before the bar does.
    private func press(_ press: KeyPress) -> KeyPress.Result {
        guard parts.editMode != nil else { return .ignored }
        let plain = press.modifiers.subtracting([.numericPad, .function, .capsLock]).isEmpty
        if press.key == .escape, plain { parts.escapeEdit(); return .handled }
        if press.key == .return, plain, !parts.searching { parts.endEdit(save: true); return .handled }
        guard let key = HomeEditBlock.key(press), let mode = parts.editMode else { return .ignored }
        var taken = false
        withAnimation(HomeMotion.keyed(reduce: reduceMotion)) { taken = mode.press(key, blocks: parts.blocks) }
        guard taken else { return .ignored }
        switch key {
        case .edit(.hide): post("\(parts.title(id)) hidden")
        case .edit: announce(mode)
        case .tab, .backTab: break
        }
        return .handled
    }

    /// Where a block is and its Layout, as VoiceOver says it: "column 6, row 1, 14 by 9 cells, Auto"; from the cells the
    /// page drew, so a redraw packs nothing.
    private func words(_ id: String) -> String {
        guard let cell = parts.cells[id] else { return "" }
        return "column \(cell.x + 1), row \(cell.y + 1), \(cell.w) by \(cell.h) cells, \(parts.pin(id)?.title ?? "Auto")"
    }

    /// Said after a key or VoiceOver edit, from the draft just made (the page has not drawn it yet).
    private func announce(_ mode: HomeEditMode) {
        let draft = mode.session.draft
        guard let cell = mode.session.cells(draft)[id] else { return post("\(parts.title(id)) hidden") }
        post("\(parts.title(id)): column \(cell.x + 1), row \(cell.y + 1), \(cell.w) by \(cell.h) cells, \(draft.layout(of: id)?.title ?? "Auto")")
    }

    private func post(_ words: String) { AccessibilityNotification.Announcement(words).post() }

    @ViewBuilder private func menu(_ mode: HomeEditMode?) -> some View {
        let name = parts.title(id)
        // A widget on Home: its own settings, as its right-click on the desktop offers.
        if mode == nil, let placement = HomeLayout.widgetID(id) {
            Button("Edit widget…") { WidgetDesk.shared.editPlacement(placement) }
            Button("Remove from Home") { WidgetDesk.shared.removePlacement(placement) }
            Divider()
        }
        if mode == nil { Button("Edit Home") { parts.beginEdit() } }
        Menu("Layout") {
            HomeLayoutPicker(selection: Binding(get: { parts.pin(id) }, set: { layout in parts.change { $0.layout(id, layout) } })).menuRows()
        }
        Button("Hide \(name)") { parts.change { $0.hide(id) } }
    }
}

/// Where the pointer last rested on a block, kept without drawing again.
private final class HomePointer {
    var y: CGFloat?
}

/// A ✕ badge: a narrow block's, at its corner.
private struct HomeHideBadge: View {
    @Environment(\.ink) private var ink

    var body: some View {
        Image(systemName: "xmark").font(ink.system(8.5, weight: .bold)).foregroundStyle(ink.text2)
            .frame(width: 20, height: 20)
            .background(ink.raised, in: .circle)
            .overlay { Circle().strokeBorder(ink.line2) }
            .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
            .contentShape(.circle)
    }
}

/// A block's outline in edit mode: dashed under Reduce Motion, in place of the wiggle; the accent ring while the keyboard
/// is on it.
private struct HomeEditOutline: View {
    @Environment(\.ink) private var ink
    let focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(12) + 3, style: .continuous)
        shape.strokeBorder(focused ? ink.accent : ink.text2.opacity(0.55),
                           style: focused ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .padding(-3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Edit mode's wiggle: the block turns so its corners sway 1 pt, on its own period and phase, only while `on` (edit mode,
/// the window showing); off, it is still and costs nothing.
struct HomeWiggle: ViewModifier {
    let id: String
    let on: Bool
    @State private var width: CGFloat = 0
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
            .rotationEffect(.degrees(angle))
            .task(id: on ? width : -1) {
                guard on, width > 0 else {
                    if angle != 0 { withAnimation(Kit.change) { angle = 0 } }
                    return
                }
                let rhythm = HomeMotion.rhythm(id), most = HomeMotion.wiggle(width: width), half = rhythm.period / 2
                guard (try? await Task.sleep(for: .seconds(rhythm.phase))) != nil else { return }
                var side = -1.0
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: half)) { angle = side * most }
                    side = -side
                    guard (try? await Task.sleep(for: .seconds(half))) != nil else { return }
                }
            }
    }
}

/// The carried block, over Home's page and its edit bar (HomeNowPage's overlay, in the window's space): lifted to 1.03
/// under a deeper shadow, it follows the pointer 1:1, held where it was picked up; let go, it flies to where it landed
/// and fades as the block shows there.
struct HomeCarryLayer<Block: View>: View {
    let mode: HomeEditMode
    let frames: HomeFrames
    @ViewBuilder let block: (HomeEditMode.Lift) -> Block

    var body: some View {
        if let lift = mode.lift, let window = frames.window {
            HomeLifted(lift: lift, landing: mode.landing.map { $0.offsetBy(dx: -window.minX, dy: -window.minY) },
                       at: mode.pointer - window.origin) { block(lift) }
                .id(lift.serial)
        }
    }
}

private struct HomeLifted<Block: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lift: HomeEditMode.Lift
    /// Where it lands, in the layer's space, once let go.
    let landing: CGRect?
    /// The pointer, in the layer's space.
    let at: CGPoint
    @ViewBuilder let block: Block
    @State private var up = false

    var body: some View {
        let landed = landing != nil
        let frame = landing ?? CGRect(x: at.x - lift.grab.width, y: at.y - lift.grab.height, width: lift.frame.width, height: lift.frame.height)
        Group {
            if lift.fromTray { block.fixedSize() } else { block.frame(width: frame.width, height: frame.height) }
        }
        .scaleEffect(landed ? 1 : up ? HomeMotion.liftScale(reduce: reduceMotion) : HomeMotion.enterScale(reduce: reduceMotion))
        .shadow(color: .black.opacity(up && !landed ? 0.35 : 0.12), radius: up && !landed ? 16 : 6, y: up && !landed ? 16 : 3)
        .opacity(landed ? 0 : 1)
        .animation(HomeMotion.fade, value: landed)
        .position(lift.fromTray ? CGPoint(x: landing?.midX ?? at.x, y: landing?.midY ?? at.y) : CGPoint(x: frame.midX, y: frame.midY))
        .allowsHitTesting(false)
        .environment(\.homeBlockAsks, false)
        .accessibilityHidden(true)
        .onAppear { withAnimation(HomeMotion.lift) { up = true } }
    }
}

/// Where a held block lands, over Home's grid: its cells outlined in the accent (dashed while it is carried whole), with
/// the size readout, "14 × 9 · 908 × 568 · Large".
struct HomeSnapLayer: View {
    @Environment(\.ink) private var ink
    let mode: HomeEditMode
    let parts: HomeParts
    /// The grid's width.
    let inner: CGFloat

    var body: some View {
        if let held = mode.carrying, let cell = parts.cells[held.id] {
            let rect = HomeGrid.rect(cell, inner: inner)
            let drawn = HomeGrid.sizeClass(cell, inner: inner, pin: parts.pin(held.id))
            let shape = RoundedRectangle(cornerRadius: ink.radius(12), style: .continuous)
            shape.fill(ink.accent.opacity(held.resizing ? 0 : 0.06))
                .overlay { shape.strokeBorder(ink.accent, style: held.resizing ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1.5, dash: [6, 4])) }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(cell.w) × \(cell.h) · \(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) · \(drawn.title)")
                        .font(ink.mono(11, weight: .semibold)).foregroundStyle(ink.onAccent).fixedSize()
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(ink.accent, in: .capsule)
                        .offset(y: 28)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// The cells, as faint dots, while Home is in edit mode: one in the middle of each, `rows` deep.
struct HomeCellDots: View {
    @Environment(\.ink) private var ink
    let inner: CGFloat
    let rows: Int

    var body: some View {
        Canvas { context, _ in
            var dots = Path()
            for row in 0..<rows {
                for column in 0..<HomeGrid.columns {
                    let middle = HomeGrid.rect(HomeCell(x: column, y: row, w: 1, h: 1), inner: inner)
                    dots.addEllipse(in: CGRect(x: middle.midX - 1.5, y: middle.midY - 1.5, width: 3, height: 3))
                }
            }
            context.fill(dots, with: .color(ink.text.opacity(0.14)))
        }
        .frame(width: inner, height: CGFloat(rows) * HomeGrid.pitch)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An installed extension's page as a Home block: its blocks, asked as its page asks (on its pace, only while the window
/// shows), on a tile in the style; Open goes to its page, as a push to one of its views does. Its model is Home's, kept
/// by extension id, so the block keeps its last answer when it moves. Wide: its first figure, then its first list folded
/// to the block, "N more" opening its page, or with no list its first figures and three rows (HomeVariant.medium); Large:
/// the whole page, or on a block narrower than the page's own width its Wide form. A page of usage cards (AI usage) shows
/// just their meters at both, the cards side by side (T34). Never more than its block holds: its blocks from the first,
/// then the first one's own parts.
struct HomeExtensionBlock: View {
    @Environment(\.ink) private var ink
    let id: String
    let parts: HomeParts
    /// Wide or Large: the class it draws.
    var drawn: Widget.SizeClass = .large
    /// Its block's width: the whole page needs `wholePage`.
    var width: CGFloat = .infinity
    var rows: Int? = nil
    /// Takes the height its cells give it.
    var fill = true

    var body: some View {
        let link = parts.pages.first { $0.id == id }
        let model = parts.pageModel(id)
        // Its emoji leads its title.
        Tile(title: link?.label ?? id, fill: fill) {
            AccentLink(title: "Open") { parts.openExtension(id) }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = model.problem { FinePrint(text: problem, color: ink.warnText) }
                if let page = model.blocks {
                    let whole = drawn == .large && width >= Self.wholePage
                    let cards = HomeVariant.usage(page)
                    if !cards.isEmpty {
                        usage(cards)
                    } else if !whole, let list = HomeVariant.list(page) {
                        small(page, list: list, title: link?.title ?? id)
                    } else {
                        let blocks = whole ? page : HomeVariant.medium(page)
                        if blocks.isEmpty { FinePrint(text: "Nothing to show.") }
                        ViewThatFits(in: .vertical) {
                            ForEach(Array(Self.fitting(blocks).enumerated()), id: \.offset) { _, part in
                                ExtensionBlocksView(blocks: part) { action in
                                    model.run(action, act: { ExtensionActions.run($0, in: $1, inputs: $2) }) { _, _ in parts.openExtension(id) }
                                }
                            }
                        }
                    }
                } else if model.problem == nil {
                    FinePrint(text: "Asking \(link?.title ?? id)…")
                }
            }
        }
        // Asked only while the window shows (ADR 0010); its last answer stays while it is hidden.
        .asksPage(model, onScreen: parts.onScreen)
    }

    /// The least width a whole page draws in: its figures three across.
    static let wholePage: CGFloat = 420

    /// What a block can show of `blocks`, most first: all of them, one fewer down to the first, then the first's own
    /// parts (a section's meters) one fewer down to one.
    static func fitting(_ blocks: [Extension.Block]) -> [[Extension.Block]] {
        let firsts = (1..<max(1, blocks.count)).reversed().map { Array(blocks.prefix($0)) }
        let parts = HomeVariant.flattened(Array(blocks.prefix(1)))
        return [blocks] + firsts + (parts.count > 1 ? (1..<parts.count).reversed().map { Array(parts.prefix($0)) } : [])
    }

    /// A page of usage cards (AI usage) at any size: the cards side by side, as many across as the block is wide, each
    /// shrunk before a provider is left out (HomeVariant.usageFits).
    @ViewBuilder private func usage(_ cards: [Extension.Block]) -> some View {
        ViewThatFits(in: .vertical) {
            ForEach(Array(HomeVariant.usageFits(cards).enumerated()), id: \.offset) { _, fit in
                let across = HomeVariant.across(fit.cards.count, width: width, compact: fit.compact)
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: fit.cards.count, by: across)), id: \.self) { start in
                        GridRow {
                            ForEach(start..<min(start + across, fit.cards.count), id: \.self) { i in
                                ExtensionBlocksView(blocks: [fit.cards[i]], compact: fit.compact) { _ in }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The first figure on a line, then the list's rows folded; a row opens the page.
    @ViewBuilder private func small(_ page: [Extension.Block], list: [Extension.Item], title: String) -> some View {
        if let figure = HomeVariant.figure(page) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(figure.value).font(ink.mono(15, weight: .medium)).monospacedDigit().foregroundStyle(ink.tone(figure.tone, else: ink.text))
                Text(figure.label).font(ink.ui(11.5)).foregroundStyle(ink.muted)
            }
            .lineLimit(1)
        }
        HomeFoldList(total: list.count, rows: rows, more: HomeMore(title: "Open \(title)") { parts.openExtension(id) }) { i in
            let item = list[i]
            Button { parts.openExtension(id) } label: {
                HStack(spacing: 9) {
                    Text(item.icon ?? "•").font(ink.ui(11)).frame(width: 16)
                    HStack(spacing: 6) {
                        Text(item.title).font(ink.ui(12.5)).foregroundStyle(ink.text).layoutPriority(1)
                        if let subtitle = item.subtitle { Text(subtitle).font(ink.ui(11.5)).foregroundStyle(ink.muted) }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.kitPress)
            .help(item.subtitle.map { "\(item.title): \($0)" } ?? item.title)
        }
    }
}

/// Home's extension blocks' models, by extension id, made once each through HomeSources.page.
@MainActor
final class HomePageModels {
    private var models: [String: ExtensionPageModel] = [:]

    func model(_ id: String, make: (String) -> ExtensionPageModel) -> ExtensionPageModel {
        if let model = models[id] { return model }
        let model = make(id)
        models[id] = model
        return model
    }
}

extension CGPoint {
    /// From one space to another: a global point less a space's global origin.
    static func - (point: CGPoint, origin: CGPoint) -> CGPoint { CGPoint(x: point.x - origin.x, y: point.y - origin.y) }
}
