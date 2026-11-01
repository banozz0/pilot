import AppKit
import PilotCore
import SwiftUI

// Home's edit mode (spec home-edit, direction B "Workbench", Sven 2026-10-12) and Home's extension blocks, drawn in every
// style through the Kit. Edit mode is on Home itself: the blocks wiggle under their size chips and ✕, hidden ones wait in
// the edit bar's tray, and Done keeps the edit while Escape and Cancel throw it away (HomeEditSession decides the layout).

/// Home in edit mode: the session every edit goes through, the size chip under the pointer, whose block's new frame the
/// page draws dashed (HomeEditPreview), and the block the pointer carries (T5).
@Observable @MainActor
final class HomeEditMode {
    typealias Place = HomeEditSession.Place

    struct Hover: Equatable {
        let id: String
        let size: HomeLayout.Size
    }

    /// A block the pointer carries: the slots and the page's shape taken at pick-up, kept until the drop so nothing moves
    /// under the pointer (HomeSlots), the frame it was lifted from (page space) and where the pointer holds it.
    struct Lift {
        let id: String
        let slots: HomeSlots
        let shape: HomeNow.Shape
        let frame: CGRect
        let grab: CGSize
        /// Dragged out of the tray: it floats as its chip.
        let fromTray: Bool
        /// One a pick-up, so each lift draws afresh.
        let serial: Int
    }

    let session: HomeEditSession
    var hover: Hover?
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
    @ObservationIgnored private var pending: Place?
    @ObservationIgnored private var gesture: CGPoint?
    @ObservationIgnored private var lifts = 0
    /// Reduce Motion is on (the page hands it over): no wiggle, lift scale or spring; changes fade 150 ms.
    @ObservationIgnored var reduceMotion = false
    /// The block the keyboard is on, and whether a key has been pressed since edit mode began: its ring shows only then,
    /// so a mouse never sees one.
    var focus: String?
    private(set) var keyed = false

    init(session: HomeEditSession, hover: Hover? = nil) {
        self.session = session
        self.hover = hover
    }

    /// The block carried now: lifted and not yet dropped, put back or hidden.
    var carrying: Lift? { lift.flatMap { session.carried == $0.id ? $0 : nil } }

    // MARK: Carrying

    /// A drag on Home's page, global: its first move lifts the block under where it began; then the block follows. A drag
    /// whose block went back (Escape) moves nothing until the pointer lets go.
    func drag(from start: CGPoint, to point: CGPoint) {
        if start != gesture {
            gesture = start
            if let origin = frames?.origin, let id = frames?.block(at: start - origin) { pickUp(id, at: start - origin) }
        }
        move(to: point)
    }

    /// A tray chip dragged, global: a hidden block lifted as its chip, shown where it is dropped.
    func dragHidden(_ id: String, from start: CGPoint, to point: CGPoint) {
        if start != gesture {
            gesture = start
            if let origin = frames?.origin {
                lift(id, frame: CGRect(origin: start - origin, size: .zero), grab: .zero, fromTray: true)
            }
        }
        move(to: point)
    }

    /// Lifts `id` where the page drew it, held at `point` in the page's space.
    func pickUp(_ id: String, at point: CGPoint) {
        guard let rect = frames?.rects[.block(id)] else { return }
        lift(id, frame: rect, grab: CGSize(width: point.x - rect.minX, height: point.y - rect.minY), fromTray: false)
    }

    private func lift(_ id: String, frame: CGRect, grab: CGSize, fromTray: Bool) {
        guard let frames, let drawn = frames.drawn else { return }
        session.pickUp(id)
        guard session.carried == id else { return }
        dwell?.invalidate()
        landed?.invalidate()
        (dwell, landed, pending, hover, landing, overTray) = (nil, nil, nil, nil, nil, false)
        lifts += 1
        lift = Lift(id: id, slots: HomeSlots(frames, carrying: id, size: session.draft.size(of:)), shape: drawn.shape, frame: frame,
                    grab: grab, fromTray: fromTray, serial: lifts)
        if let origin = frames.origin { pointer = CGPoint(x: frame.minX + grab.width + origin.x, y: frame.minY + grab.height + origin.y) }
    }

    /// The carried block under a new pointer, global.
    func move(to point: CGPoint) {
        guard carrying != nil else { return }
        pointer = point
        overTray = frames?.bar?.contains(point) == true
        aimScroll()
        aim()
    }

    /// The slot under the pointer, in the page as it lies now (it may have scrolled): a new one counts once the pointer
    /// has rested in it 80 ms, and the page makes room for it.
    func aim() {
        guard let lift = carrying, let origin = frames?.origin else { return }
        let place = overTray ? nil : lift.slots.slot(at: pointer - origin)?.place
        guard place != session.target else {
            dwell?.invalidate()
            dwell = nil
            return
        }
        if dwell != nil, pending == place { return }
        dwell?.invalidate()
        pending = place
        dwell = Self.after(HomeMotion.rest) { [weak self] in self?.target(place) }
    }

    private func target(_ place: Place?) {
        dwell = nil
        guard carrying != nil, session.target != place else { return }
        withAnimation(settle) { session.hover(place) }
        if place != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    /// The pointer lets go: on the tray the block hides; on a slot it drops there, at the slot's size, rested in or not;
    /// off every slot it goes back. The floating block flies to where it now lies.
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
        let place = frames?.origin.flatMap { lift.slots.slot(at: pointer - $0)?.place }
        withAnimation(settle) {
            session.hover(place)
            session.drop()
        }
        land(lift)
    }

    /// The carried block back where it was (Escape, ⌘Z while carrying), the draft unchanged.
    func putBack() {
        guard let lift = carrying else { return }
        dwell?.invalidate()
        dwell = nil
        scroll(0)
        withAnimation(settle) { session.putBack() }
        land(lift)
    }

    /// The floating block to the frame its block takes once the page has drawn the drop, fading as it lands; a block
    /// left hidden (a tray chip dropped off every slot), or any under Reduce Motion, just fades.
    private func land(_ lift: Lift) {
        landed?.invalidate()
        if reduceMotion { return finish(lift) }
        landed = Self.after(.milliseconds(20)) { [weak self] in
            guard let self, self.lift?.serial == lift.serial else { return }
            let shown = session.draft.shown(extensions: session.extensions).contains(lift.id)
            guard shown, let rect = frames?.rects[.block(lift.id)], let origin = frames?.origin else { return finish(lift) }
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

    /// Escape: a carried block goes back first (by pointer or by keyboard); else the edit is thrown away and edit mode
    /// ends (true).
    func escape() -> Bool {
        if carrying != nil { putBack(); return false }
        return session.escape()
    }

    /// ⌘Z: a carried block goes back first; else one edit back.
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

    /// A key on the focused block in edit mode (spec home-edit, check 11). Escape, Return and ⌘Z are the edit bar's.
    enum Key: Equatable {
        /// Tab and Shift-Tab: the next block or the one before; past either end the window's own Tab goes on (the bar).
        case tab, backTab
        /// The arrows, up and left earlier, down and right later: the focus, or the carried block slot by slot.
        case earlier, later
        /// Space: picks the focused block up, or drops the carried one.
        case space
        /// 1 to 4: Icon, Small, Medium, Large.
        case size(HomeLayout.Size)
        /// ⌫: hides the focused block.
        case hide
    }

    /// An edit VoiceOver offers on a block, as its mouse twin makes it: a drag to a slot, a size chip, the ✕.
    enum Edit: Equatable {
        case move(Place)
        case size(HomeLayout.Size)
        case hide
    }

    /// The block the keyboard (or VoiceOver) carries: picked up with no pointer.
    var keyCarried: String? { carrying == nil ? session.carried : nil }

    /// A key on the focused block, `blocks` the ones Home draws and `across` the board's columns: true when edit mode takes
    /// it. While the pointer carries a block the keys wait.
    func press(_ key: Key, blocks: [String], across: Int) -> Bool {
        if carrying != nil { return true }
        keyed = true
        let order = Self.order(drawn(session.draft, blocks), size: session.draft.size(of:), across: across)
        if let id = keyCarried {
            switch key {
            case .space: keyDrop(id, blocks: blocks, across: across)
            case .earlier, .later: step(id, by: key == .earlier ? -1 : 1, blocks: blocks, across: across)
            case .hide: hide(id, order: order)
            case .tab, .backTab, .size: break
            }
            return true
        }
        guard let id = focus, let at = order.firstIndex(of: id) else {
            // Nothing focused yet: the first block takes the focus (the last, going back).
            switch key {
            case .tab, .earlier, .later: focus = order.first
            case .backTab: focus = order.last
            case .space, .size, .hide: return false
            }
            return focus != nil
        }
        switch key {
        case .tab, .backTab:
            let next = at + (key == .tab ? 1 : -1)
            guard order.indices.contains(next) else { return false }
            focus = order[next]
        case .earlier, .later: focus = order[min(order.count - 1, max(0, at + (key == .earlier ? -1 : 1)))]
        case .space: session.pickUp(id)
        case .size(let size): session.size(id, size)
        case .hide: hide(id, order: order)
        }
        return true
    }

    /// What VoiceOver offers on a block (check 12): Move earlier and later (the nearest slot at its size, as the arrows
    /// find them), Move to the column or the board (the lane's end), every other size, and Hide. A move that would leave
    /// it where it is is not offered.
    func actions(for id: String, blocks: [String], across: Int) -> [(name: String, edit: Edit)] {
        let size = session.draft.size(of: id), slots = slots(carrying: id, blocks: blocks, across: across)
        var out: [(name: String, edit: Edit)] = []
        if let home = slots.home {
            let same = { (k: Int) in slots.places[k].size(carrying: size) == size }
            if let k = (0..<home).last(where: same) { out.append(("Move earlier", .move(slots.places[k]))) }
            if let k = (home + 1..<slots.places.count).first(where: same) { out.append(("Move later", .move(slots.places[k]))) }
        }
        if size != .small { out.append(("Move to the column", .move(.column(before: nil)))) }
        if size.lane != .board { out.append(("Move to the board", .move(.board(before: nil)))) }
        out += HomeLayout.Size.allCases.filter { $0 != size }.map { ("Size \($0.title)", .size($0)) }
        out.append(("Hide", .hide))
        return out
    }

    /// An edit VoiceOver asked for, made as its mouse twin makes it.
    func perform(_ edit: Edit, on id: String) {
        guard carrying == nil else { return }
        switch edit {
        case .move(let place):
            session.pickUp(id)
            session.hover(place)
            session.drop()
        case .size(let size): session.size(id, size)
        case .hide: session.hide(id)
        }
        focus = id
    }

    /// Where the keyboard can take `id`, in reading order (the icon row, the column, then the board, a lone medium's empty
    /// half after its row), each kept once by what Home would draw; and the one that leaves it where it is.
    func slots(carrying id: String, blocks: [String], across: Int) -> (places: [Place], home: Int?) {
        let draft = session.draft, listed = draft.resolved(extensions: session.extensions).map(\.id)
        let lanes = HomeLayout.lanes(drawn(draft, blocks), size: draft.size(of:), across: across)
        var places: [Place] = lanes.icons.filter { $0 != id }.map { .icons(before: $0) } + [.icons(before: nil)]
        places += lanes.column.filter { $0 != id }.map { .column(before: $0) } + [.column(before: nil)]
        for row in lanes.board {
            let ids = row.filter { $0 != id }
            guard let first = ids.first else { continue }
            places.append(.board(before: first))
            // Its empty half is the left one only when its pair there is the block carried (HomeSlots).
            if across == 2, ids.count == 1, draft.size(of: first) == .medium { places.append(.beside(first, trailing: row.first != id)) }
        }
        places.append(.board(before: nil))
        // What Home draws of a layout: its lanes and the carried block's size.
        func look(_ layout: HomeLayout) -> (HomeLayout.Lanes, HomeLayout.Size) {
            (HomeLayout.lanes(drawn(layout, blocks), size: layout.size(of:), across: across), layout.size(of: id))
        }
        var seen: [(HomeLayout.Lanes, HomeLayout.Size)] = [], kept: [Place] = []
        for place in places {
            var layout = draft
            layout.put(id, at: place, listed: listed)
            let drawn = look(layout)
            if !seen.contains(where: { $0 == drawn }) { seen.append(drawn); kept.append(place) }
        }
        let here = look(draft)
        return (kept, seen.firstIndex { $0 == here })
    }

    /// The blocks focus walks, in reading order: the icon row, the column, the board.
    static func order(_ blocks: [String], size: (String) -> HomeLayout.Size, across: Int) -> [String] {
        let lanes = HomeLayout.lanes(blocks, size: size, across: across)
        return lanes.icons + lanes.column + lanes.board.flatMap { $0 }
    }

    /// `layout`'s shown blocks that Home draws, in its order.
    private func drawn(_ layout: HomeLayout, _ blocks: [String]) -> [String] {
        let drawn = Set(blocks)
        return layout.shown(extensions: session.extensions).filter(drawn.contains)
    }

    /// The carried block to the next slot or the one before, from where it hovers (else where it is).
    private func step(_ id: String, by way: Int, blocks: [String], across: Int) {
        let slots = slots(carrying: id, blocks: blocks, across: across)
        guard !slots.places.isEmpty else { return }
        let at = session.target.flatMap(slots.places.firstIndex(of:)) ?? slots.home ?? (way > 0 ? -1 : slots.places.count)
        session.hover(slots.places[min(slots.places.count - 1, max(0, at + way))])
    }

    /// Space on a carried block: dropped where it hovers; back where it was if that is where it is, so no undo step.
    private func keyDrop(_ id: String, blocks: [String], across: Int) {
        let slots = slots(carrying: id, blocks: blocks, across: across)
        if let target = session.target, slots.places.firstIndex(of: target) != slots.home { session.drop() } else { session.putBack() }
        focus = id
    }

    /// ⌫: hidden, the focus to the block after it (the one before, at the end).
    private func hide(_ id: String, order: [String]) {
        let rest = order.filter { $0 != id }, at = order.firstIndex(of: id) ?? 0
        session.hide(id)
        focus = rest.isEmpty ? nil : rest[min(at, rest.count - 1)]
    }

    /// A change from a block's right-click, staged in edit mode's draft: edit mode `mode`, else a new one on `layout`, so
    /// Done keeps it and ⌘Z, Escape or Cancel take it back (Moody on T4: at rest it saved at once).
    static func staging(_ edit: (HomeEditSession) -> Void, in mode: HomeEditMode?, layout: HomeLayout, extensions: [String]) -> HomeEditMode {
        let mode = mode ?? HomeEditMode(session: HomeEditSession(layout: layout, extensions: extensions))
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

    /// Edit mode on, on the saved layout; a hold says so with a tap under the finger.
    func beginEdit(byHold: Bool = false) {
        guard editing.wrappedValue == nil else { return }
        if byHold { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
        let session = HomeEditSession(layout: sources.layout().layout, extensions: beyond)
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

    /// A size or a hide from a block's right-click: a change to edit mode's draft, edit mode turned on first at rest;
    /// nothing is saved until Done.
    func change(_ edit: (HomeEditSession) -> Void) {
        let mode = editing.wrappedValue
        withAnimation(mode?.settle ?? HomeMotion.enter) {
            editing.wrappedValue = HomeEditMode.staging(edit, in: mode, layout: sources.layout().layout, extensions: beyond)
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
            .help("Size, hide and add Home's blocks (⌘E, or hold a block's title bar)")
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
            .filter { !$0.shown && (HomeLayout.Block(rawValue: $0.id)?.drawn(in: style.kind) ?? true) }
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
                            .help("Show \(name) where it was, or drag it onto Home")
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

/// A block's size chips and its ✕, on its top edge in edit mode: a size in the other lane moves the block there; the chip
/// under the pointer has the page draw the block's new frame dashed.
struct HomeSizeChips: View {
    @Environment(\.ink) private var ink
    let id: String
    let parts: HomeParts
    let mode: HomeEditMode

    var body: some View {
        let current = parts.size(id), name = parts.title(id)
        HStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(HomeLayout.Size.allCases, id: \.self) { size in
                    HomeSizeChip(size: size, on: size == current, name: name) { over in
                        let hover = HomeEditMode.Hover(id: id, size: size)
                        withAnimation(Kit.change) {
                            if over, size != current { mode.hover = hover } else if mode.hover == hover { mode.hover = nil }
                        }
                    } pick: {
                        mode.hover = nil
                        withAnimation(mode.settle) { mode.session.size(id, size) }
                    }
                }
            }
            .padding(2)
            .background(ink.raised, in: .capsule)
            .overlay { Capsule().strokeBorder(ink.line2) }
            Button {
                mode.hover = nil
                withAnimation(mode.settle) { mode.session.hide(id) }
            } label: {
                Image(systemName: "xmark").font(ink.system(9.5, weight: .bold)).foregroundStyle(ink.text2)
                    .frame(width: 24, height: 24)
                    .background(ink.raised, in: .circle)
                    .overlay { Circle().strokeBorder(ink.line2) }
                    .contentShape(.circle)
            }
            .buttonStyle(.kitPress)
            .help("Hide \(name); it waits in the tray")
            .accessibilityLabel("Hide \(name)")
        }
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .fixedSize()
    }
}

/// One size chip: lit when it is the block's size.
private struct HomeSizeChip: View {
    @Environment(\.ink) private var ink
    let size: HomeLayout.Size
    let on: Bool
    let name: String
    let hover: (Bool) -> Void
    let pick: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: pick) {
            Text(size.title).font(ink.ui(11.5, on ? .semibold : .medium))
                .foregroundStyle(on ? ink.accentInk : over ? ink.text : ink.text2)
                .padding(.horizontal, 8).frame(height: 20)
                .background(on ? ink.selection : ink.text.opacity(over ? 0.07 : 0), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.kitPress)
        .onHover { over = $0; hover($0) }
        .animation(Kit.change, value: over)
        .help("\(size.title): \(size.place)")
        .accessibilityLabel("\(name): \(size.title)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension View {
    /// A block on Home, as edit mode draws it (HomeEditBlock).
    func homeEditable(_ id: String, _ parts: HomeParts, tab: Bool = false) -> some View {
        modifier(HomeEditBlock(id: id, parts: parts, tab: tab))
    }
}

/// A block on Home. At rest a 0.5 s hold on its title bar (or on empty page, HomeNowPage's) enters edit mode, a hold on
/// its content stays a press, and its right-click offers Edit Home, Size and Hide. In edit mode it rests a little smaller
/// and wiggles under its size chips; its content takes no press, row or hover card while its readings go on. The
/// keyboard reaches it (Tab and the arrows, Space, 1 to 4, ⌫) and VoiceOver offers its moves, sizes and Hide; under
/// Reduce Motion it stays still, outlined dashed.
struct HomeEditBlock: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String
    let parts: HomeParts
    /// An icon tab: its ✕ at its corner, its size chips while the pointer is on it.
    var tab = false
    @State private var pointer = HomePointer()
    @FocusState private var focused: Bool
    /// The pointer on the tab, on its chips, and the chips showing: they close a beat after it leaves both.
    @State private var over = false
    @State private var overChips = false
    @State private var chips = false

    func body(content: Content) -> some View {
        let mode = parts.editMode
        // Carried, it is a dashed well at the size it lands at, where it lands (the page draws the drop's preview), while
        // the pointer carries a copy of it (HomeCarryLayer); carried by the keyboard it shows under the well.
        let carried = mode?.session.carried == id, floated = carried && mode?.carrying != nil
        content
            .allowsHitTesting(mode == nil)
            // In edit mode VoiceOver finds the block, its size and its actions, not its inert content.
            .accessibilityHidden(mode != nil)
            .opacity(floated ? 0 : 1)
            .overlay { if carried { HomeSizeGhost(size: parts.size(id)).transition(.opacity) } }
            .animation(HomeMotion.fade, value: carried)
            // In edit mode the block itself is what the pointer finds: a drag on it, from the page (HomeNowPage), carries it.
            .overlay { if mode != nil { Color.clear.contentShape(.rect) } }
            .modifier(HomeWiggle(id: id, on: mode != nil && !carried && parts.onScreen && !reduceMotion))
            .scaleEffect(mode == nil ? 1 : HomeMotion.enterScale(reduce: reduceMotion))
            // Reduce Motion's dashed outline, and the keyboard's ring once a key is pressed.
            .overlay {
                let ring = mode.map { $0.keyed && $0.focus == id } ?? false
                if mode != nil, !carried, reduceMotion || ring { HomeEditOutline(focused: ring).transition(.opacity) }
            }
            .overlay(alignment: tab ? .topLeading : .top) {
                if let mode, !carried {
                    Group {
                        if tab { tabChrome(mode) } else { HomeSizeChips(id: id, parts: parts, mode: mode).offset(y: -12) }
                    }
                    .transition(.opacity)
                }
            }
            .onHover { over = $0 }
            .task(id: over || overChips) {
                let want = over || overChips
                guard want != chips else { return }
                if !want, (try? await Task.sleep(for: .milliseconds(150))) == nil { return }
                withAnimation(HomeMotion.fade) { chips = want }
            }
            .zIndex(chips ? 1 : 0)
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
            .onKeyPress(phases: .down) { press($0) }
            .onChange(of: mode?.focus == id, initial: true) { _, on in if on != focused { focused = on } }
            .onChange(of: focused) { _, on in if on, let mode, mode.focus != id { mode.focus = id } }
            // VoiceOver (check 12): the block, its size, and its moves, sizes and Hide.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(parts.title(id))
            .accessibilityValue(mode == nil ? "" : parts.size(id).title)
            .accessibilityActions {
                if let mode {
                    let across = mode.frames?.drawn?.shape.across ?? 2
                    ForEach(Array(mode.actions(for: id, blocks: parts.blocks, across: across).enumerated()), id: \.offset) { _, action in
                        Button(action.name) {
                            withAnimation(mode.settle) { mode.perform(action.edit, on: id) }
                            announce(after: action.edit, mode)
                        }
                    }
                }
            }
            // No transition of its own: a copy leaving one lane for another would go on measuring where it was (HomeSlots).
    }

    /// A key press as edit mode reads it: Tab and Shift-Tab, the arrows, Space, ⌫ and 1 to 4 with no modifier (⌘1 to ⌘4
    /// stay the window's); nil for the rest.
    static func key(_ press: KeyPress) -> HomeEditMode.Key? {
        let mods = press.modifiers.subtracting([.numericPad, .function, .capsLock])
        if press.key == .tab, mods.isSubset(of: .shift) { return mods.contains(.shift) ? .backTab : .tab }
        guard mods.isEmpty else { return nil }
        switch press.key {
        case .upArrow, .leftArrow: return .earlier
        case .downArrow, .rightArrow: return .later
        case .space: return .space
        case .delete, .deleteForward: return .hide
        default:
            guard press.characters.count == 1, let n = press.characters.first?.wholeNumberValue, (1...4).contains(n) else { return nil }
            return .size(HomeLayout.Size.allCases[n - 1])
        }
    }

    /// A key on this block in edit mode, handed to the mode, and said aloud for VoiceOver when it moves or changes a block.
    /// Escape and Return do what the edit bar's Cancel and Done do: a focused block takes the key before the bar does.
    private func press(_ press: KeyPress) -> KeyPress.Result {
        guard parts.editMode != nil else { return .ignored }
        let plain = press.modifiers.subtracting([.numericPad, .function, .capsLock]).isEmpty
        if press.key == .escape, plain { parts.escapeEdit(); return .handled }
        if press.key == .return, plain, !parts.searching { parts.endEdit(save: true); return .handled }
        guard let key = HomeEditBlock.key(press), let mode = parts.editMode else { return .ignored }
        let carried = mode.keyCarried
        var taken = false
        withAnimation(HomeMotion.keyed(reduce: reduceMotion)) {
            taken = mode.press(key, blocks: parts.blocks, across: mode.frames?.drawn?.shape.across ?? 2)
        }
        guard taken else { return .ignored }
        let name = parts.title(carried ?? id)
        switch key {
        case .space where carried == nil && mode.keyCarried != nil:
            post("Picked up \(name). Arrows move it, Space drops it, Escape puts it back.")
        case .space: post("\(name): \(mode.session.draft.size(of: carried ?? id).title)")
        case .earlier where carried != nil, .later where carried != nil: mode.session.target.map { post(words($0, size: mode.session.preview.size(of: carried ?? id))) }
        case .size(let size): post("\(name): \(size.title)")
        case .hide: post("\(name) hidden")
        default: break
        }
        return .handled
    }

    /// Where a carried block would land, as VoiceOver says it.
    private func words(_ place: HomeEditSession.Place, size: HomeLayout.Size) -> String {
        let at: String = switch place {
        case .icons(let before): before.map { "in the icon row, before \(parts.title($0))" } ?? "at the icon row's end"
        case .column(let before): before.map { "in the column, before \(parts.title($0))" } ?? "at the column's end"
        case .board(let before): before.map { "on the board, before \(parts.title($0))" } ?? "at the board's end"
        case .beside(let other, _): "beside \(parts.title(other))"
        }
        return "\(size.title), \(at)"
    }

    private func announce(after edit: HomeEditMode.Edit, _ mode: HomeEditMode) {
        let name = parts.title(id)
        switch edit {
        case .hide: post("\(name) hidden")
        case .move, .size: post("\(name): \(mode.session.draft.size(of: id).title)")
        }
    }

    private func post(_ words: String) { AccessibilityNotification.Announcement(words).post() }

    /// An icon tab's ✕ at its corner, and its size chips over it while the pointer is on it.
    @ViewBuilder private func tabChrome(_ mode: HomeEditMode) -> some View {
        let name = parts.title(id)
        ZStack(alignment: .topLeading) {
            Button {
                withAnimation(mode.settle) { mode.session.hide(id) }
            } label: {
                HomeHideBadge()
            }
            .buttonStyle(.kitPress)
            .help("Hide \(name); it waits in the tray")
            .accessibilityLabel("Hide \(name)")
            .offset(x: -7, y: -7)
            if chips {
                HomeSizeChips(id: id, parts: parts, mode: mode).onHover { overChips = $0 }.offset(y: -32).transition(.opacity)
            }
        }
    }

    @ViewBuilder private func menu(_ mode: HomeEditMode?) -> some View {
        let name = parts.title(id)
        // A widget on Home: its own settings, as its right-click on the desktop offers.
        if mode == nil, let placement = HomeLayout.widgetID(id) {
            Button("Edit widget…") { WidgetDesk.shared.editPlacement(placement) }
            Button("Remove from Home") { WidgetDesk.shared.removePlacement(placement) }
            Divider()
        }
        if mode == nil { Button("Edit Home") { parts.beginEdit() } }
        Menu("Size") {
            Picker("Size", selection: Binding(get: { parts.size(id) }, set: { size in parts.change { $0.size(id, size) } })) {
                ForEach(HomeLayout.Size.allCases, id: \.self) { Text("\($0.title) · \($0.place)").tag($0) }
            }
            .pickerStyle(.inline).labelsHidden().menuRows()
        }
        Button("Hide \(name)") { parts.change { $0.hide(id) } }
    }
}

/// Where the pointer last rested on a block, kept without drawing again.
private final class HomePointer {
    var y: CGFloat?
}

/// An icon tab's ✕ badge.
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

/// Where a block would draw at another size (the size chip under the pointer), from the lanes Home drew and the frames it
/// measured: in its new lane where the block it now goes in front of is (on the board, where its new row is now), at the
/// new size's width; its own height in the same lane, else a well's. A guide drawn dashed; the size change's spring settles the true frame.
enum HomeEditPreview {
    static func frame(of id: String, at size: HomeLayout.Size, blocks: [String], sizes: (String) -> HomeLayout.Size,
                      drawn: HomeFrames.Drawn, rects: [HomeFrames.Key: CGRect]) -> CGRect? {
        let shape = drawn.shape, gap = shape.gap
        let lanes = HomeLayout.lanes(blocks, size: { $0 == id ? size : sizes($0) }, across: shape.across)
        func rect(_ id: String) -> CGRect? { rects[.block(id)] }
        let height = sizes(id).lane == size.lane ? rect(id)?.height ?? HomeNow.well : HomeNow.well
        if let k = lanes.icons.firstIndex(of: id) {
            let side = HomeLayout.Size.tab, others = drawn.lanes.icons.filter { $0 != id }
            if k < others.count, let at = rect(others[k]) { return CGRect(x: at.minX, y: at.minY, width: side, height: side) }
            if let last = others.last.flatMap(rect) { return CGRect(x: last.maxX + 10, y: last.minY, width: side, height: side) }
            return rects[.well(.icons)].map { CGRect(x: $0.minX, y: $0.minY, width: side, height: side) }
        }
        if let k = lanes.column.firstIndex(of: id) {
            let others = drawn.lanes.column.filter { $0 != id }
            if k < others.count, let at = rect(others[k]) { return CGRect(x: at.minX, y: at.minY, width: at.width, height: height) }
            if let last = others.last.flatMap(rect) {
                return CGRect(x: rects[.lane(.column)]?.minX ?? last.minX, y: last.maxY + gap, width: last.width, height: height)
            }
            return rects[.well(.column)]
        }
        guard let r = lanes.board.firstIndex(where: { $0.contains(id) }), let board = rects[.lane(.board)] else { return nil }
        // Two to a row, or in edit mode a lone medium, take half the board.
        let row = lanes.board[r]
        let half = row.count > 1 || (shape.across == 2 && (row[0] == id ? size : sizes(row[0])) == .medium)
        let each = half ? (board.width - gap) / 2 : board.width
        // The board's rows as drawn: the new size's row r lies where row r is now, or past the last.
        let rows = drawn.lanes.board.compactMap { ids -> CGRect? in
            let frames = ids.compactMap(rect)
            return frames.first.map { frames.dropFirst().reduce($0) { $0.union($1) } }
        }
        let y = r < rows.count ? rows[r].minY : rows.last.map { $0.maxY + gap } ?? rects[.well(.board)]?.minY ?? board.minY
        return CGRect(x: row.first == id ? board.minX : board.maxX - each, y: y, width: each, height: height)
    }
}

/// The block whose size chip is under the pointer, dashed at the frame the new size gives it, over Home's page.
struct HomeSizeGhostLayer: View {
    let mode: HomeEditMode
    let frames: HomeFrames
    let parts: HomeParts

    var body: some View {
        if let hover = mode.hover, let drawn = frames.drawn,
           let rect = HomeEditPreview.frame(of: hover.id, at: hover.size, blocks: parts.blocks, sizes: parts.size, drawn: drawn, rects: frames.rects) {
            HomeSizeGhost(size: hover.size).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                .transition(.opacity)
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

/// The dashed frame a size chip under the pointer previews, with the size it gives.
struct HomeSizeGhost: View {
    @Environment(\.ink) private var ink
    let size: HomeLayout.Size

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(12), style: .continuous)
        shape.fill(ink.accent.opacity(0.06))
            .overlay { shape.strokeBorder(ink.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])) }
            .overlay(alignment: .topLeading) {
                // Whole even on a tab's 52 pt.
                Text(size.title).font(ink.ui(11, .semibold)).foregroundStyle(ink.onAccent).fixedSize()
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(ink.accent, in: .capsule)
                    .padding(size == .icon ? 5 : 8)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An installed extension's page as a Home block: its blocks, asked as its page asks (on its pace, only while the window
/// shows), on a tile in the style; Open goes to its page, as a push to one of its views does. Its model is Home's, kept
/// by extension id, so the block keeps its last answer when it moves to another row. Small, in the column: its first
/// figure, then its first list folded to the card (`rows` fixed, else fitted), "N more" opening its page; a page with no
/// list keeps its medium blocks.
struct HomeExtensionBlock: View {
    @Environment(\.ink) private var ink
    let id: String
    let parts: HomeParts
    var rows: Int? = nil
    /// Takes the height its row or column gives it.
    var fill = true

    var body: some View {
        let link = parts.pages.first { $0.id == id }
        let size = parts.size(HomeLayout.extensionRow(id))
        let model = parts.pageModel(id)
        // Its emoji leads its title.
        Tile(title: link?.label ?? id, fill: fill) {
            AccentLink(title: "Open") { parts.openExtension(id) }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = model.problem { FinePrint(text: problem, color: ink.warnText) }
                if let page = model.blocks {
                    if size.lane == .column, let list = HomeVariant.list(page) {
                        small(page, list: list, title: link?.title ?? id)
                    } else {
                        // Medium keeps its first figures and three rows (HomeVariant.medium); large is the whole page.
                        let blocks = size == .large ? page : HomeVariant.medium(page)
                        if blocks.isEmpty { FinePrint(text: "Nothing to show.") }
                        ExtensionBlocksView(blocks: blocks) { action in
                            model.run(action, act: { ExtensionActions.run($0, in: $1, inputs: $2) }) { _, _ in parts.openExtension(id) }
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
