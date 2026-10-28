import AppKit
import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// Launcher › Rings (P74, Halo's Settings › Rings; Binds' until Sven on Build 76): the rings on the wheel and those for one app on the left, the ring itself
/// in the middle, drawn by the ring's own view, where a click picks a wedge, a second click on a group enters its own ring
/// and a click on the hub goes back up, and the picked wedge on the right: its action, kind and name, its key, then how
/// every ring opens and runs. The Pilot ring and a group filled from the menu are shown as the menu fills them, never
/// edited here.
struct RingsPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink
    /// A render's pick, in place of the page's own.
    var shown: Pick?
    /// Opens another place of the window (Binds › Mouse, to catch a button).
    var go: (AppPlace) -> Void = { _ in }
    /// Recording a key for this ring, and a key another action already holds, to replace or leave.
    @State private var recording: String?
    @State private var taken: (ring: String, key: Key, by: String)?
    /// A button whose hold opens something else, asked about before its hold moves to this ring.
    @State private var moving: (ring: String, hold: Hold, from: String)?

    /// A mouse button a ring's hold can go on: its number, what it sends, its mouse, and what its hold opens now.
    struct Hold { var n: Int, sends: Key, device: MouseKeys.Device?, opens: String? }

    /// The ring picked, the groups entered on it (each a place), and the wedge picked on that level.
    struct Pick: Equatable {
        var ring: String?, path: [Int] = [], place: Int?
        var full: [Int]? { place.map { path + [$0] } }
    }

    @State private var pick = Pick()
    /// The ring Delete ring asks about, as `pilot remove rings` asks Allow.
    @State private var deleting: Ring?
    @State private var picking = false
    @State private var query = ""
    /// The switches' states and the role apps, read as the page shows, never on each redraw.
    @State private var states: [String: Bool] = [:]
    @State private var roles: [String: String] = [:]
    /// The actions a wedge may hold, read as the picker opens.
    @State private var choices: [BindsPage.ActionInfo] = []
    /// The menu read as the Pilot ring and menu groups fill, while the page shows.
    @State private var menu: RingMenuSource?
    @FocusState private var searching: Bool

    private var store: RingStore { engine.rings.store }
    private var current: Pick { shown ?? pick }

    var body: some View {
        let rings = store.rings
        let ring = current.ring.flatMap(rings.ring(id:)) ?? rings.rings.first
        KitPage(intro: Self.intro) {
            HStack(alignment: .top, spacing: 12) {
                list(rings, picked: ring?.id).frame(width: 204)
                if let ring {
                    preview(ring).frame(minWidth: 380, maxWidth: .infinity)
                    inspector(ring, rings).frame(width: 268)
                } else {
                    Text("No ring yet. Make one with New ring.").font(ink.ui(13)).foregroundStyle(ink.muted)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.top, 4)
        }
        .onAppear {
            states = engine.rings.states()
            roles = engine.rings.roleApps()
            menu = RingMenuSource(engine: engine)
            engine.mouseButtons.findMice()
        }
        .onDisappear { if recording != nil { stopRecording() } }
        .confirmationDialog("Delete ring \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { ring in
            Button("Delete", role: .destructive) { delete(ring) }
            Button("Cancel", role: .cancel) {}
        } message: { ring in
            Text(Self.deleteNote(ring, engine.binds.store))
        }
    }

    static let intro = "Hold a mouse button or a key and a ring of Pilot's actions opens at the pointer: flick toward one and let go. "
        + "Scroll while it is open for the next ring."

    // MARK: the list

    private func list(_ rings: Rings, picked: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading("On the wheel")
            ForEach(rings.rings.filter { $0.app == nil }) { ring in row(ring, picked: picked) }
            let apps = rings.rings.filter { $0.app != nil }
            if !apps.isEmpty {
                heading("For apps").padding(.top, 12)
                ForEach(apps) { ring in row(ring, picked: picked) }
            }
            Button { newRing() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus").frame(width: 18).foregroundStyle(ink.muted)
                    Text("New ring").foregroundStyle(ink.text2)
                    Spacer(minLength: 0)
                }
                .font(ink.ui(13)).padding(.horizontal, 10).frame(height: 32).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.line2, lineWidth: 1))
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(ink.mono(10.5, weight: .medium)).tracking(1.2).textCase(.uppercase).foregroundStyle(ink.muted)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
    }

    private func row(_ ring: Ring, picked: String?) -> some View {
        let on = ring.id == picked
        return Button { pick = Pick(ring: ring.id) } label: {
            HStack(spacing: 9) {
                if let app = ring.app, let icon = AppsModule.icon(bundle: app) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: ring.app == nil ? RingLook.symbol(ring.id + ".") : "circle.dashed").frame(width: 18)
                        .foregroundStyle(on ? ink.text : ink.text2)
                }
                Text(ring.name).foregroundStyle(ink.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(ring.menu ? "menu" : "\(ring.count)").font(ink.mono(11.5)).foregroundStyle(ink.muted)
            }
            .font(ink.ui(13)).padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? ink.selection : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ring.name), \(ring.count) actions")
    }

    // MARK: the ring

    private func preview(_ ring: Ring) -> some View {
        let scale = 0.86
        let side = RingGeometry.side * scale
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.dashed").foregroundStyle(ink.text2)
                TextField("Name", text: Binding(get: { ring.name }, set: { name in edit(ring) { $0.name = name } }))
                    .textFieldStyle(.plain).font(ink.ui(14.5, .semibold)).foregroundStyle(ink.text)
                    .disabled(ring.menu)   // the Pilot ring follows the menu, its name too
                Spacer(minLength: 8)
                Text(current.path.isEmpty ? "Click a wedge to change it, a group again to open it" : "Click the hub to go back up")
                    .font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                if !ring.menu { more(ring) }
            }
            .padding(.horizontal, 14).frame(height: 46)
            Rectangle().fill(ink.line).frame(height: 1)
            RingView(model: model(ring))
                .scaleEffect(scale)
                .frame(width: side, height: side)
                .contentShape(.rect)
                .gesture(SpatialTapGesture().onEnded { tap in
                    pickWedge(ring, dx: tap.location.x / scale - RingGeometry.side / 2, dy: RingGeometry.side / 2 - tap.location.y / scale)
                })
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            Rectangle().fill(ink.line).frame(height: 1)
            opens(ring).padding(.horizontal, 14).frame(height: 46)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.raised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.line2, lineWidth: 1))
    }

    /// The ring as the menu draws it, on the level entered, the picked wedge lit.
    private func model(_ ring: Ring) -> RingModel {
        let expand: RingSession.Expand = { [menu] in menu?.wedges($0) ?? [] }
        var session = RingSession(wheel: [ring], expand: expand)
        session.pick(path: current.path, place: current.place, expand: expand)
        return engine.rings.model(session, states: states, roles: roles)
    }

    /// A click on the drawn ring: the hub goes back up a level; a wedge is picked, and a group already picked is entered.
    private func pickWedge(_ ring: Ring, dx: Double, dy: Double) {
        let d = (dx * dx + dy * dy).squareRoot()
        guard d >= RingGeometry.hub else { return pick = Pick(ring: ring.id, path: current.path.dropLast()) }
        guard d <= RingGeometry.disc else { return pick = Pick(ring: ring.id, path: current.path) }
        let p = RingGeometry.place(bearing: RingGeometry.bearing(dx: dx, dy: dy))
        var shown = RingSession(wheel: [ring], expand: { [menu] in menu?.wedges($0) ?? [] })
        shown.pick(path: current.path, place: nil, expand: { [menu] in menu?.wedges($0) ?? [] })
        if current.place == p, case .slice(let s)? = shown.places[p], s.isGroup {
            pick = Pick(ring: ring.id, path: current.path + [p])
        } else {
            pick = Pick(ring: ring.id, path: current.path, place: p)
        }
    }

    /// Whether the level picked is written by hand: not the Pilot ring, and no group on the way filled from the menu.
    private func editable(_ ring: Ring) -> Bool {
        !ring.menu && current.path.indices.allSatisfy { ring[path: Array(current.path.prefix($0 + 1))]?.branch == nil }
    }

    /// What opens this ring, set right here (Sven on Build 76): its key, recorded as Binds' editor records one, and each
    /// mouse button whose hold opens it, picked from the buttons Binds › Mouse knows, each with what it sends.
    @ViewBuilder private func opens(_ ring: Ring) -> some View {
        let store = engine.binds.store
        let key = store.trigger(for: ring.openID)
        let held = store.mouseBinds.filter { $0.bind.action == ring.openID }
        HStack(spacing: 7) {
            Text("Opens with").foregroundStyle(ink.muted)
            if recording == ring.id {
                Text("Press a Hyper key…").foregroundStyle(ink.accentText)
                Button("Cancel") { stopRecording() }.buttonStyle(.pilot)
            } else if let moving, moving.ring == ring.id {
                Text("\(MouseKeys.buttonName(moving.hold.n)) held opens \(moving.from)").foregroundStyle(ink.text).lineLimit(1)
                Button("Use it here") { setHold(ring, moving.hold); self.moving = nil }.buttonStyle(.pilotPrimary)
                Button("Cancel") { self.moving = nil }.buttonStyle(.pilot)
            } else if let taken, taken.ring == ring.id {
                Text("\(taken.key.label) is \(engine.action(taken.by)?.label ?? taken.by)").foregroundStyle(ink.text).lineLimit(1)
                Button("Use it") { engine.binds.replace(ring.openID, with: taken.key); self.taken = nil }.buttonStyle(.pilotPrimary)
                Button("Cancel") { self.taken = nil }.buttonStyle(.pilot)
            } else {
                if let key {
                    Kbd(text: key.label, small: true)
                    Button { try? engine.binds.set(ring.openID, to: nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(ink.muted).accessibilityLabel("Remove \(key.label)")
                } else {
                    Button("Record key") { record(ring) }.buttonStyle(.pilot)
                }
                ForEach(held, id: \.trigger) { b in
                    Kbd(text: MouseKeys.plain(b.trigger).label, small: true)
                    Text("held").foregroundStyle(ink.muted)
                    Button { engine.binds.setMouse(b.trigger, to: nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(ink.muted).accessibilityLabel("Remove \(b.trigger.label)")
                }
                holdMenu(ring)
            }
            Spacer(minLength: 0)
        }
        .font(ink.ui(12.5))
    }

    /// Hold a mouse button: each button Binds › Mouse lists, by what it sends (a button, or the key its mouse's own app set
    /// on it), and Catch one… for a button Pilot has not heard yet. A button holds one hold, so picking one moves its hold here.
    private func holdMenu(_ ring: Ring) -> some View {
        let binds = engine.binds.store.mouseBinds
        let rows = MouseButtonsPage.rows(binds, found: engine.mouseButtons.found, labels: [:])
        let hyper = MouseButtonsPage.hyperRows(binds, plain: rows, labels: [:])
        let buttons: [Hold] = rows.compactMap { row in
            guard let n = row.button else { return nil }
            // What it sends: its own bind's, else its Hyper bind's, else its button number.
            let sends = row.plain ?? hyper.first { $0.button == n }?.trigger.map { Key(keyCode: $0.keyCode, modifiers: $0.modifiers, hyper: false) }
            let opens = binds.first { $0.trigger == row.hold }.map { b in Rings.ringID(inAction: b.bind.action).flatMap { store.rings.ring(id: $0)?.name }
                ?? engine.action(b.bind.action)?.label ?? b.bind.action }
            return Hold(n: n, sends: sends ?? MouseKeys.button(Int64(n - 1)), device: row.device ?? hyper.first { $0.button == n }?.device, opens: opens)
        }
        return Menu {
            ForEach(buttons, id: \.n) { b in
                // Its hold's own ring named, so a pick that moves it is never a surprise.
                Button("\(MouseKeys.buttonName(b.n)) held (sends \(MouseKeys.sends(b.sends)))" + (b.opens.map { " · opens \($0)" } ?? "")) {
                    if let from = b.opens, from != ring.name { moving = (ring.id, b, from) } else { setHold(ring, b) }
                }
            }
            Divider()
            Button("Catch another button in Binds › Mouse…") { go(AppPlace(.mouse)) }
        } label: {
            Label("Hold a mouse button", systemImage: "computermouse")
        }
        .menuStyle(.button).buttonStyle(.pilot).fixedSize()
    }

    /// The button's hold opens this ring; a button holds one hold, so one it opened before is let go.
    private func setHold(_ ring: Ring, _ b: Hold) {
        engine.binds.setMouse(MouseKeys.hold(b.sends), to: ring.openID, device: b.device, button: b.n)
    }

    /// Record key: the next Hyper key binds this ring, as Binds' editor's Record does; a key another action holds asks.
    private func record(_ ring: Ring) {
        recording = ring.id
        taken = nil
        let id = ring.openID, ringID = ring.id, binds = engine.binds
        engine.recordKey(onlyHyper: true) { key in
            // After the tap callback returned.
            Task { @MainActor in
                recording = nil
                engine.recordKey(nil)
                do throws(BindStore.BindError) { try binds.set(id, to: key) } catch {
                    if case .triggerTaken(let k, let by) = error { taken = (ringID, k, by) }
                }
            }
        }
    }

    private func stopRecording() {
        recording = nil
        engine.recordKey(nil)
    }

    private func more(_ ring: Ring) -> some View {
        Menu {
            if ring.app == nil {
                Button("Only for one app…") { chooseApp(ring) }
            } else {
                Button("For every app") { edit(ring) { $0.app = nil } }
            }
            Divider()
            Button("Delete ring…", role: .destructive) { deleting = ring }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(ink.muted).frame(width: 26, height: 26).contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More for \(ring.name)")
    }

    // MARK: the wedge

    private func inspector(_ ring: Ring, _ rings: Rings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !editable(ring) {
                Text(ring.menu ? "Pilot ring" : "From the menu").font(ink.ui(14, .semibold)).foregroundStyle(ink.text).padding(.horizontal, 14).frame(height: 46)
                Rectangle().fill(ink.line).frame(height: 1)
                Text("This follows the Hyper+Space menu: each branch is a group whose ring is filled from that branch as it opens, "
                     + "minus anything that asks for typing. Hide or reorder branches in Launcher › Your menu. Click a group again to look inside.")
                    .font(ink.ui(12.5)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true).padding(14)
            } else if let full = current.full {
                let p = full[full.count - 1]
                let slice = ring[path: full]
                HStack(spacing: 8) {
                    Text("\(Self.arrows[p]) \(Self.compass[p])").font(ink.mono(11.5, weight: .medium)).tracking(1).foregroundStyle(ink.accentText)
                    Text(current.path.isEmpty ? (slice?.isGroup == true ? "Group" : "Wedge")
                         : "In \(ring[path: current.path]?.label ?? "the group")")
                        .font(ink.ui(14, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                }
                .padding(.horizontal, 14).frame(height: 46)
                Rectangle().fill(ink.line).frame(height: 1)
                wedge(ring, full, slice).padding(14)
            } else {
                Text("Wedge").font(ink.ui(14, .semibold)).foregroundStyle(ink.text).padding(.horizontal, 14).frame(height: 46)
                Rectangle().fill(ink.line).frame(height: 1)
                Text("Click a wedge on the ring to pick what it runs.").font(ink.ui(12.5)).foregroundStyle(ink.muted).padding(14)
            }
            Rectangle().fill(ink.line).frame(height: 1)
            behaviour(rings).padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ink.line2, lineWidth: 1))
    }

    static let compass = ["NORTH", "NORTH-EAST", "EAST", "SOUTH-EAST", "SOUTH", "SOUTH-WEST", "WEST", "NORTH-WEST"]
    static let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]

    @ViewBuilder private func wedge(_ ring: Ring, _ path: [Int], _ slice: RingSlice?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if slice?.isGroup != true {
                field("Action") {
                    Button { query = ""; choices = engine.bindActions.filter { !Rings.needsTyping($0.id) }; picking = true } label: {
                        HStack(spacing: 8) {
                            if let id = slice?.action { Image(systemName: RingLook.symbol(id)).foregroundStyle(ink.text2).frame(width: 16) }
                            Text(slice?.action.flatMap { engine.action($0)?.label } ?? slice?.action ?? "Pick an action")
                                .foregroundStyle(slice == nil ? ink.muted : ink.text).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(ink.muted)
                        }
                        .font(ink.ui(13)).padding(.horizontal, 10).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.well))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ink.line2, lineWidth: 1))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $picking, arrowEdge: .leading) { actionPicker(ring, path) }
                }
            }
            if slice != nil {
                field("Kind") {
                    Picker("Kind", selection: Binding(get: { slice?.kind ?? .action }, set: { setKind($0, ring, path) })) {
                        Text("Action").tag(RingSlice.Kind.action)
                        Text("Switch").tag(RingSlice.Kind.switch)
                        Text("Group").tag(RingSlice.Kind.group)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                field(slice?.isGroup == true ? "Name" : "Label on the ring") {
                    TextField(slice?.action.flatMap { engine.action($0)?.label } ?? "Group", text: Binding(
                        get: { slice?.label ?? "" },
                        set: { label in change(ring, path) { $0?.label = label.isEmpty ? nil : label } }))
                        .textFieldStyle(.roundedBorder).font(ink.ui(13))
                }
                if let id = slice?.action {
                    HStack {
                        Text("Also on the keyboard").font(ink.ui(12.5)).foregroundStyle(ink.text2)
                        Spacer(minLength: 8)
                        if let key = engine.binds.store.trigger(for: id) { Kbd(text: key.label, small: true) }
                        else { Text("No key").font(ink.ui(12)).foregroundStyle(ink.muted) }
                    }
                }
                if let branch = slice?.branch {
                    Text("Filled from the menu's \(MenuBranch(id: branch)?.title ?? branch) branch as it opens.").font(ink.ui(12)).foregroundStyle(ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if slice?.isGroup == true {
                    Text("Click it again on the ring to open its own ring and set what it holds, groups too.").font(ink.ui(12)).foregroundStyle(ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Empty this wedge") { change(ring, path) { $0 = nil } }.buttonStyle(.pilot)
            }
        }
    }

    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(ink.ui(12)).foregroundStyle(ink.text2)
            content()
        }
    }

    /// Every action a wedge may hold (none that asks for typing), searched as the bind editor's list is.
    private func actionPicker(_ ring: Ring, _ path: [Int]) -> some View {
        let actions = MouseButtonsPage.choices(choices, search: query)
        return VStack(alignment: .leading, spacing: 8) {
            SearchBox(prompt: "Search actions", text: $query, focused: $searching)
                .onAppear { searching = true }
                .onSubmit { if let first = actions.first { setAction(first.id, ring, path) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                        if i == 0 || actions[i - 1].module != a.module { PartHeading(text: Abilities.title(a.module)).padding(.horizontal, 8) }
                        Button { setAction(a.id, ring, path) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: RingLook.symbol(a.id)).foregroundStyle(ink.text2).frame(width: 16)
                                Text(a.label).foregroundStyle(ink.text).lineLimit(1)
                                Spacer(minLength: 8)
                            }
                            .font(ink.ui(12.5)).padding(.horizontal, 8).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(i == 0 ? ink.selection : .clear))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if actions.isEmpty { Text("No action matches.").font(ink.ui(12)).foregroundStyle(ink.muted).padding(8) }
                }
            }
            .frame(height: 300)
        }
        .padding(12).frame(width: 300)
    }

    // MARK: how rings behave

    private func behaviour(_ rings: Rings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Hide names on the ring", isOn: Binding(get: { rings.hideNames }, set: { on in store.change { $0.hideNames = on } }))
                .toggleStyle(.pilotSwitchRow)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Flick and let go runs it", isOn: Binding(get: { rings.flickRuns }, set: { on in store.change { $0.flickRuns = on } }))
                    .toggleStyle(.pilotSwitchRow)
                Text("Off: point, then click. A wedge also runs on click while the ring is open.").font(ink.ui(12)).foregroundStyle(ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HoldAfterRow()
        }
        .font(ink.ui(12.5))
    }

    // MARK: edits

    private func edit(_ ring: Ring, _ change: (inout Ring) -> Void) {
        var next = ring
        change(&next)
        store.change { $0.put(next) }
    }

    /// The wedge at `path` changed in place.
    private func change(_ ring: Ring, _ path: [Int], _ change: (inout RingSlice?) -> Void) {
        edit(ring) { r in change(&r[path: path]) }
    }

    private func setAction(_ id: String, _ ring: Ring, _ path: [Int]) {
        picking = false
        change(ring, path) { slice in
            let kind: RingSlice.Kind = slice?.kind == .switch ? .switch : .action
            slice = RingSlice(id, kind: kind, label: slice?.isGroup == true ? nil : slice?.label)
        }
    }

    private func setKind(_ kind: RingSlice.Kind, _ ring: Ring, _ path: [Int]) {
        change(ring, path) { slice in
            switch kind {
            case .group: slice = .group(slice?.label ?? "Group", [])
            case .action, .switch:
                if let action = slice?.action { slice = RingSlice(action, kind: kind, label: slice?.label) } else { slice = nil }
            }
        }
    }

    private func newRing() {
        var id = ""
        store.change { rings in
            id = rings.freeID(for: "New ring")
            rings.rings.append(Ring(id: id, name: "New ring", slices: []))
        }
        pick = Pick(ring: id)
    }

    /// What Delete ring's question says goes with it: the wedges, and the key and button holds that open it.
    static func deleteNote(_ ring: Ring, _ store: BindStore) -> String {
        let opens = (store.trigger(for: ring.openID).map { [$0.label] } ?? []) + store.mouseBinds.filter { $0.bind.action == ring.openID }.map(\.trigger.label)
        return opens.isEmpty ? "Its wedges go with it." : "Its wedges and what opens it go with it: \(opens.joined(separator: ", "))."
    }

    /// Its key and each button's hold that opened it go with it (Engine.deleteRing).
    private func delete(_ ring: Ring) {
        engine.deleteRing(ring.id)
        pick = Pick()
    }

    /// Only for one app: picked from the Applications folder, the ring opens first while that app is in front.
    private func chooseApp(_ ring: Ring) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use this app"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return }
        edit(ring) { $0.app = bundle }
    }
}

/// Hold after (P74): how long a mouse button bound to a ring stays down before the ring opens, shared by Launcher › Rings
/// and Binds › Mouse.
struct HoldAfterRow: View {
    @Environment(Engine.self) private var engine
    @Environment(\.ink) private var ink

    var body: some View {
        let store = engine.rings.store
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold after").font(ink.ui(12.5)).foregroundStyle(ink.text)
                Text("A quicker press is the button's click").font(ink.ui(11.5)).foregroundStyle(ink.muted)
            }
            Spacer(minLength: 8)
            Text("\(store.rings.holdAfter) ms").font(ink.mono(12)).foregroundStyle(ink.text).monospacedDigit()
            Stepper("Hold after", value: Binding(get: { store.rings.holdAfter }, set: { ms in store.change { $0.holdAfter = ms } }),
                    in: Rings.holdRange, step: 20)
                .labelsHidden()
        }
    }
}
