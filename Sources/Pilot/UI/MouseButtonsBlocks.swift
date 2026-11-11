import PilotCore
import SwiftUI

/// Binds › Mouse (Q184, Q257; under System's Mouse card from Sven's Q68 until his round 3 notes on build 2300,
/// 2026-11-11, when it came back to Keys): a mouse's extra buttons bound to any Pilot action, in one flow. Click a button, on the
/// drawing or as its row's Sends field; press it on the mouse (the catch, 8 s); then the keyboard's bind sheet (BindEditor,
/// Sven after Build 82) picks what its click or its hold runs. A bound button opens the sheet at once.
/// The drawing labels every button with its action and holds the catch's box in one spot to its right (Sven, Q258); a row
/// per button under it lists the same binds. A button whose mouse app (NGenuity) set a media key or a key on it is bound as that
/// key from that mouse, tied to the button clicked. An unbound button keeps doing what it does now. Under the drawing,
/// With Hyper held gives each button a second action and the wheel two (P51), which run only while Hyper is down.
struct MouseButtonsBlocks: View {
    @Environment(Engine.self) var engine
    @Environment(\.ink) var ink
    /// The catch for a render, in place of the engine's.
    var shown: Shown?
    /// The connected mice for a render; nil reads the engine's.
    var mice: MouseButtons.Found?
    /// The drawn button picked for a render.
    var spot: Int?
    /// A press from a mouse other than the connected one, used anyway.
    @State var anyway = false
    /// Whether the box fits beside the drawing; under it otherwise.
    @State private var wide = true

    /// A render's catch: its state, the button it is for, its line, the seconds its countdown shows, and a quiet catch's
    /// vendor report.
    struct Shown {
        var learn: MouseButtons.Learn, target: Int?, note: String? = nil, askAccess = false, left = 6, hyper = false
        var vendorReport: String?
    }

    var body: some View {
        let mouse = engine.mouseButtons
        let learn = shown?.learn ?? mouse.learn
        let target = shown.map(\.target) ?? mouse.target
        let hyper = shown?.hyper ?? mouse.hyper
        let binds = engine.binds.store.mouseBinds
        let actions = engine.bindActions(including: binds.map(\.bind.action))
        // A hold's row names its ring.
        let labels = Dictionary(actions.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
            .merging(engine.rings.store.rings.rings.map { ($0.openID, $0.name) }, uniquingKeysWith: { _, ring in ring })
        let found = mice ?? mouse.found
        let rows = Self.rows(binds, found: found, labels: labels)
        let hyperRows = Self.hyperRows(binds, plain: rows, labels: labels)
        let selected = spot
        VStack(alignment: .leading, spacing: 0) {
            KitBlock(title: found.names.isEmpty ? "Your mouse" : found.names.joined(separator: ", "), symbol: "computermouse", note: Self.intro) {
                InfoMark(text: "Each button's label and row say what it runs. A button with no bind keeps its own job.")
            } content: {
                BlockRow(first: true) {
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 24)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                    layout {
                        MouseDrawing(labels: Self.labels(rows), waiting: learn == .listening ? target : nil,
                                     lit: Self.lit(learn, target: target, selected: selected)) { click($0, rows: rows) }
                        box(learn, target: target, hyper: hyper, found: found)
                            .frame(width: wide ? Self.boxWidth : nil).frame(maxWidth: 420, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)   // the row's width, never the content's
                    .onGeometryChange(for: Bool.self) { $0.size.width >= MouseDrawing.canvas.width + 24 + Self.boxWidth } action: { wide = $0 }
                }
                table(rows, learn: learn, target: target, hyper: hyper)
            }
            KitBlock(title: "With Hyper held", symbol: "command") {
                InfoMark(text: "Hold Hyper and press a button or roll the wheel: its Hyper action runs instead. Without Hyper, every click and scroll is untouched.")
            } content: {
                hyperTable(hyperRows, learn: learn, target: target, hyper: hyper, dragsWithHyper: engine.settings.dragModifier == .hyper)
            }
            KitBlock(title: "A key for rings", symbol: "keyboard") {
                InfoMark(text: "Hold the key, flick toward a wedge, let go. Set or change it in Keyboard, as any other bind.")
            } content: {
                ringKeys
            }
        }
        .onAppear { if mice == nil { mouse.findMice() } }
        .onDisappear { if shown == nil, mouse.learn != .idle { mouse.cancel() } }
        .onChange(of: mouse.learn) { anyway = false }
        .sheet(item: editing(found)) { button in
            // The window behind the sheet stays main while the sheet is key: its height caps the sheet's.
            BindEditor(action: nil, actions: actions, windowHeight: NSApp.mainWindow?.contentLayoutRect.height ?? 660, mouse: button)
                .floating()
        }
    }

    /// The catch's press, once it is from the connected mouse or used anyway: the sheet's button. Its Cancel and Save
    /// end the catch. Never in a render.
    private func editing(_ found: MouseButtons.Found) -> Binding<MouseTrigger?> {
        let mouse = engine.mouseButtons
        return Binding(get: { shown == nil ? Self.trigger(mouse.learn, target: mouse.target, hyper: mouse.hyper, found: found, anyway: anyway) : nil },
                       set: { if $0 == nil, mouse.learn != .idle { mouse.cancel() } })
    }

    /// The sheet's button for a caught press: on the button it was caught for, with Other button…'s note when it sent a
    /// drawn button's number (Q309); nil while waiting, or for a press from another mouse not used yet.
    static func trigger(_ learn: MouseButtons.Learn, target: Int?, hyper: Bool, found: MouseButtons.Found, anyway: Bool) -> MouseTrigger? {
        guard case .got(let key, let device) = learn, anyway || !isOtherMouse(device, found: found) else { return nil }
        let shared = target == nil ? MouseKeys.number(key).flatMap { n in MouseDrawing.chips.contains { $0.button == n } ? n : nil } : nil
        return MouseTrigger(sends: key, device: device, button: button(of: key, target: target), hyper: hyper,
                            note: shared.map { MouseKeys.Catch.shared(MouseKeys.buttonName($0), sends: MouseKeys.sends(key), device: found.names.first) })
    }

    // MARK: Flow

    /// A drawn button clicked: a bound one (a click or a hold) opens the sheet on its bind, an unbound one starts the catch.
    func click(_ n: Int, rows: [Row]) {
        if let row = rows.first(where: { $0.button == n }), row.isBound { change(row) } else { press(n) }
    }

    /// The catch for button `n`, nil for one the drawing lacks; `hyper` for its Hyper action.
    func press(_ n: Int?, hyper: Bool = false) {
        engine.mouseButtons.startLearning(for: n, hyper: hyper)
    }

    /// Change: straight to the sheet, as Pilot knows what the button sends (its click's or its hold's bind, a Hyper row's
    /// own, or the wheel); the catch otherwise.
    func change(_ row: Row) {
        guard let trigger = row.plain ?? row.sends else { return press(row.button, hyper: row.hyper) }
        engine.mouseButtons.pick(trigger, device: row.device, button: row.button, hyper: row.hyper)
    }

    func remove(_ row: Row) {
        guard let trigger = row.trigger else { return }
        engine.binds.setMouse(trigger, to: nil)
    }

    func cancel() { engine.mouseButtons.cancel() }

    // MARK: Rows

    /// One button as the page lists it: a drawn button, a further one the mouse has, or a bind no button holds (a media
    /// key caught with Other button…, a button of a mouse not connected now).
    struct Row: Equatable {
        /// Its number, 3 the wheel click; nil for a key the mouse sends on no button.
        var button: Int?
        var trigger: Key?
        var device: MouseKeys.Device?
        /// The action's label.
        var label: String?
        /// A With Hyper held row (P51): `trigger` is its Hyper bind, `sends` what the button sends as far as Pilot knows
        /// (its own bind's trigger, or the wheel's direction), nil until a catch says.
        var hyper = false
        var sends: Key?
        /// Its hold's trigger (P74) and the ring it opens; nil when holding it does nothing more than a press.
        var hold: Key?
        var holdLabel: String?

        var name: String { button.map(MouseKeys.buttonName) ?? (trigger ?? sends).map(MouseKeys.sends) ?? "" }
        /// What the button runs, as the table and the box say it: its hold's ring, then its click.
        var runs: String? {
            guard let holdLabel else { return label }
            return "Hold: ring \(holdLabel) · click: \(label ?? quickPress)"
        }
        /// A hold-bound button's quick press with no Click bind: a media key goes on to Now Playing; a button's or a
        /// keystroke's does nothing (Sven, Q370).
        var quickPress: String { plain.map { MouseKeys.isMedia($0.keyCode) } == true ? "its own job" : "nothing" }
        /// Its click or its hold is bound.
        var isBound: Bool { trigger != nil || hold != nil }
        /// What the button sends, from its click's bind or its hold's.
        var plain: Key? { trigger ?? hold.map(MouseKeys.plain) }
        var isWheel: Bool { sends.map { MouseKeys.isScroll($0.keyCode) } ?? false }
    }

    /// The rows, by button: 3 to 5 always, the mouse's further buttons, and each bound one; a plain button's bind on its
    /// own number, a key the mouse sends on the button it was caught for. Every bind shows once; one no button holds comes last.
    /// A hold's bind (P74) joins the row of the button it is held on, or of the trigger it holds.
    static func rows(_ all: [(trigger: Key, bind: BindStore.MouseBind)], found: MouseButtons.Found, labels: [String: String]) -> [Row] {
        var left = all.filter { !$0.trigger.hyper && !MouseKeys.isHold($0.trigger.keyCode) }
        var holds = all.filter { MouseKeys.isHold($0.trigger.keyCode) }
        let numbers = Set(3...5).union(found.buttons.compactMap(MouseKeys.number))
            .union(all.compactMap { MouseKeys.number(MouseKeys.plain($0.trigger)) ?? $0.bind.button })
        func row(_ b: (trigger: Key, bind: BindStore.MouseBind), on button: Int?) -> Row {
            Row(button: button, trigger: b.trigger, device: b.bind.device, label: labels[b.bind.action] ?? b.bind.action)
        }
        func withHold(_ r: Row) -> Row {
            guard let i = holds.firstIndex(where: { h in
                let plain = MouseKeys.plain(h.trigger)
                return plain == r.trigger || r.button != nil && (MouseKeys.number(plain) == r.button || h.bind.button == r.button)
            }) else { return r }
            let h = holds.remove(at: i)
            var r = r
            r.hold = h.trigger
            r.holdLabel = labels[h.bind.action] ?? h.bind.action
            if r.device == nil { r.device = h.bind.device }
            return r
        }
        let listed = numbers.filter { $0 >= 3 }.sorted().map { n in
            let own = left.firstIndex { MouseKeys.number($0.trigger) == n }
            guard let i = own ?? left.firstIndex(where: { MouseKeys.isSent($0.trigger.keyCode) && $0.bind.button == n }) else { return withHold(Row(button: n)) }
            return withHold(row(left.remove(at: i), on: n))
        }
        let rest = left.map { withHold(row($0, on: nil)) }
        return listed + rest + holds.map { h in
            Row(button: nil, device: h.bind.device, sends: MouseKeys.plain(h.trigger), hold: h.trigger, holdLabel: labels[h.bind.action] ?? h.bind.action)
        }
    }

    /// With Hyper held's rows (P51): one per button row (its Hyper bind on the plain trigger's button), Hyper + scroll up
    /// and down, then each Hyper bind no button holds. A button that sends a key (NGenuity's Esc) has one too: under Hyper
    /// the mouse's key runs its Hyper bind, else its plain one, never the keyboard's Hyper + that key.
    static func hyperRows(_ all: [(trigger: Key, bind: BindStore.MouseBind)], plain: [Row], labels: [String: String]) -> [Row] {
        var left = all.filter { $0.trigger.hyper }
        func take(_ match: (Key, BindStore.MouseBind) -> Bool) -> (trigger: Key, bind: BindStore.MouseBind)? {
            left.firstIndex { match($0.trigger, $0.bind) }.map { left.remove(at: $0) }
        }
        func row(_ b: (trigger: Key, bind: BindStore.MouseBind)?, button: Int?, sends: Key?, device: MouseKeys.Device?) -> Row {
            Row(button: button, trigger: b?.trigger, device: b?.bind.device ?? device, label: b.map { labels[$0.bind.action] ?? $0.bind.action },
                hyper: true, sends: sends)
        }
        let buttons = plain.compactMap { p -> Row? in
            guard let n = p.button else { return nil }
            let b = take { t, b in MouseKeys.number(t) == n || MouseKeys.isSent(t.keyCode) && b.button == n }
            return row(b, button: n, sends: b?.trigger ?? p.trigger, device: p.device)
        }
        let wheel = [MouseKeys.scrollUp, MouseKeys.scrollDown].map { key in row(take { t, _ in t == key }, button: nil, sends: key, device: nil) }
        return buttons + wheel + left.map { row($0, button: nil, sends: $0.trigger, device: nil) }
    }

    /// The drawing's labels, from the rows of buttons 3 to 5.
    static func labels(_ rows: [Row]) -> [Int: MouseDrawing.Label] {
        Dictionary(uniqueKeysWithValues: rows.compactMap { r in
            guard let n = r.button, (3...5).contains(n) else { return nil }
            return (n, MouseDrawing.Label(action: r.runs, sends: r.plain.flatMap { MouseKeys.isSent($0.keyCode) ? MouseKeys.sends($0) : nil }))
        })
    }

    /// The drawn button lit: the one the catch is about, else the one picked.
    static func lit(_ learn: MouseButtons.Learn, target: Int?, selected: Int?) -> Int? {
        if case .got(let key, _) = learn { return button(of: key, target: target) }
        return learn == .idle ? selected : target
    }

    /// The button a caught trigger is bound on: a plain button its own number, a key the mouse sends the button it was caught for.
    static func button(of key: Key, target: Int?) -> Int? { MouseKeys.number(key) ?? target }

    /// Whether a media key came from a mouse other than the connected ones.
    static func isOtherMouse(_ device: MouseKeys.Device?, found: MouseButtons.Found) -> Bool {
        guard let device, !found.mice.isEmpty else { return false }
        return !found.mice.contains { $0.isSame(as: device) }
    }

    static let boxWidth: CGFloat = 272

    static let intro = "Click a button on the drawing or its Sends field, press it on your mouse, pick what it runs."

    /// The actions to pick from: media first, then the rest by module, those matching `search` only.
    static func choices(_ actions: [BindsPage.ActionInfo], search: String) -> [BindsPage.ActionInfo] {
        let words = search.lowercased().split(separator: " ")
        let matching = words.isEmpty ? actions : actions.filter { a in
            let text = "\(a.label) \(a.module) \(a.keywords ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return matching.filter { $0.module == "media" } + matching.filter { $0.module != "media" }
    }
}
