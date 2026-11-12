import AppKit
import PilotCore
import SwiftUI

/// A personal name changes only after Save. The row owns its draft; changing physical UUID replaces the editor.
struct DisplayNicknameEditor: View {
    let systemName: String
    let displayUUID: String?
    let nicknames: DisplayNicknames
    var identityIsUnique = true
    @State private var editing = false
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var label: String { nicknames.label(systemName: systemName, displayUUID: identityIsUnique ? displayUUID : nil) }
    private var identified: Bool { identityIsUnique && displayUUID.flatMap(UUID.init(uuidString:)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editing {
                TextField("Name", text: $draft, prompt: Text(systemName))
                    .pilotField().accessibilityLabel("Name for \(label)")
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand { editing = false; problem = nil }
                Text("Only in Pilot. Leave blank to use the system name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Save", action: save).buttonStyle(.pilotPrimary).disabled(!identified)
                    Button("Cancel") { editing = false; problem = nil }.buttonStyle(.pilot)
                    Button("Clear") { draft = "" }.buttonStyle(.pilot)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            } else {
                Button("Rename") { draft = nicknames.nickname(for: displayUUID) ?? ""; problem = nil; editing = true }
                    .buttonStyle(.pilot).accessibilityLabel("Rename \(label)")
                    .accessibilityIdentifier("display-rename-\(displayUUID ?? systemName)")
                    .disabled(!identified)
                    .help(identified ? "Name this display only in Pilot" : "This display has no unique physical identity for a personal name")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: editing) { focused = editing }
    }

    private func save() {
        guard identified, let displayUUID else { problem = "This display no longer has a unique physical identity"; return }
        do { try nicknames.set(draft, for: displayUUID); editing = false; problem = nil }
        catch { problem = String(describing: error) }
    }
}

/// A bar item's parts in SwiftUI, for the top bar and the renders (card agent-bo-95422911); the macOS menu bar draws the
/// same parts as a template picture (StatusItemImage). Labels in the muted colour, values in mono, graphs as 1.2 pt lines.
struct BarPartsView: View {
    @Environment(\.style) private var style
    let items: [[BarPart]]
    var capsule = false
    /// The focused app's icon, for an app part.
    var appIcon: NSImage?
    /// Instrument's: the focused window's title beside the app's name, and the timer's title for its focus pill.
    var windowTitle: String?
    var focus: InstrumentBarFocus?

    var body: some View {
        switch style.kind {
        case .toybox: ToyBarParts(items: items, appIcon: appIcon)
        case .instrument: InstrumentBarParts(items: items, appIcon: appIcon, windowTitle: windowTitle, focus: focus)
        }
    }
}

/// A mini line graph of points 0 to 1, oldest left, in the text colour.
struct Sparkline: View {
    let points: [Double]
    var body: some View {
        GeometryReader { geometry in
            let step = geometry.size.width / CGFloat(max(points.count - 1, 1))
            Path { path in
                for (i, point) in points.enumerated() {
                    let p = CGPoint(x: CGFloat(i) * step, y: geometry.size.height * (1 - CGFloat(min(max(point, 0), 1))))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }
            .stroke(.primary, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}

/// The timer's ring: the share of its time left, from the top, in the accent; Home draws its track in the theme's line.
struct TimerRing: View {
    let left: Double
    var lineWidth: CGFloat = 7
    var track: Color?
    /// The ring's colour; the theme's accent when nil.
    var tint: Color?
    var body: some View {
        ZStack {
            Circle().stroke(track ?? Theme.text.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(left, 0), 1)).stroke(tint ?? Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// One slot of a top bar side (card agent-bo-95422911): drawn in its style, a click opening its popover or running its
/// one action. Workspace numbers stay a button each (a click goes there); other apps keep their own view. In the top bar
/// each item is a module (card agent-bo-95422914), drawing nothing of its own at rest: its targets light on hover
/// (cards agent-bo-95423013 and 016).
struct TopBarSlotView: View {
    /// Drawn in the top bar, not the macOS menu bar's preview.
    @Environment(\.inTopBar) private var inBar
    @Environment(\.barPreview) private var preview
    @Environment(\.style) private var style
    let slot: BarSlot
    /// The tiler's monitor name for this bar's screen.
    let screen: String
    let sources: BarSources
    let store: BarItemsStore
    /// The slot's own view, so its popover hangs under it.
    @State private var anchor = ScreenAnchor.Box()

    /// What the slot shows: its own view (other apps, workspace numbers), its parts, or nothing (a battery not read).
    private enum Shows {
        case otherApps(oneButton: Bool), appMenus, workspaces(BarStyle), modes, parts([BarParts.KindTarget], tooltip: String), nothing
    }

    var body: some View {
        let entry = slot.entries.first
        let shows: Shows = switch (slot, entry?.kind, entry?.style) {
        // The Menu bar page's strip keeps the drawer's chevron with no app listed yet, so it is there to grab.
        case (.item, .otherApps, let style): !preview && sources.readings.menuApps.list.isEmpty && style != .oneButton ? .nothing : .otherApps(oneButton: style == .oneButton)
        case (.item, .appMenus, _): sources.readings.appMenus.list.isEmpty ? .nothing : .appMenus
        case (.item, .workspaces, let style?) where [.numbers, .withApp, .icons].contains(style): .workspaces(style)
        // Status lights: nothing at all while none is lit (Q205); the Menu bar page's strip keeps its unlit dots
        // (StatusDotsView), or it would leave nothing there to grab.
        case (.item, .modes, _): !preview && sources.readings.statusLights.lights.isEmpty ? .nothing : .modes
        default: parts()
        }
        if case .nothing = shows {
            EmptyView()
        } else if inBar, entry?.kind != .spacer, entry?.kind != .divider {
            item(shows).frame(maxHeight: .infinity).toyIsland(slot.kind)
        } else {
            item(shows)
        }
    }

    /// Every item takes a right-click (its menu), a hover (its tooltip) and, on Volume and Workspaces, a scroll (card
    /// agent-bo-95423010).
    @ViewBuilder private func item(_ shows: Shows) -> some View {
        let kind = slot.kind
        let view = content(shows)
            .background(ScreenAnchor(box: anchor, rightClick: { showMenu() },
                                     scroll: kind.scrolls ? { BarScroll.perform(kind, steps: $0, on: sources) } : nil))
        // The top bar's targets show their own tooltips, on BarHover's clock.
        if inBar { view } else { view.help(tooltip(shows)) }
    }

    @ViewBuilder private func content(_ shows: Shows) -> some View {
        switch shows {
        case .otherApps(let oneButton):
            TopBarMenuApps(apps: sources.readings.menuApps, oneButton: oneButton)
        case .appMenus: TopBarAppMenus(menus: sources.readings.appMenus)
        case .workspaces(let style): TopBarWorkspacesView(screen: screen, tiler: sources.observers.tiler, style: style)
        case .modes: TopBarStatusLights(lights: sources.readings.statusLights) { perform(slot.click) }
        case .parts(let targets, _):
            // The top bar's targets are apart by their insets.
            HStack(spacing: inBar ? 0 : 6) {
                ForEach(Array(targets.enumerated()), id: \.offset) { _, each in
                    let target = each.target
                    let kind = slot.entries.first?.kind, instrument = style.kind == .instrument
                    // Instrument's alone read the window's title and the timer's title, so no other style redraws for them.
                    let parts = BarPartsView(items: target.parts, capsule: slot.isGroup && !inBar,
                                             appIcon: kind == .focusedApp ? sources.observers.focusedApp?.icon : nil,
                                             windowTitle: instrument && kind == .focusedApp ? sources.observers.focusedWindowTitle : nil,
                                             focus: instrument && kind == .timer ? InstrumentBarFocus(sources.timer) : nil)
                    if inBar {
                        Button { perform(target.click, kinds: each.kinds) } label: { parts.barTarget(tooltip(shows)) }
                            .buttonStyle(.kitPress)
                    } else {
                        Button { perform(target.click, kinds: each.kinds) } label: { parts }.buttonStyle(.plain)
                    }
                }
            }
        case .nothing: EmptyView()
        }
    }

    /// Its targets and tooltip, from one read of its readings: an extension's own item is its own target, every other
    /// item one; in the Group the readings are one and each other item its own (BarParts.groupTargets).
    private func parts() -> Shows {
        let inputs = sources.inputs(for: slot.entries)
        let targets = slot.isGroup ? BarParts.groupTargets(slot.entries, inputs)
            : BarParts.parts(slot, inputs, settings: store.settings).map { BarParts.targets($0, click: slot.click).map { ($0, slot.kinds) } } ?? []
        return targets.isEmpty ? .nothing : .parts(targets, tooltip: BarTooltip.text(slot, inputs))
    }

    /// Workspace numbers read only the focused one, so a window opening redraws no tooltip.
    private func tooltip(_ shows: Shows) -> String {
        switch shows {
        case .parts(_, let tooltip): return tooltip
        case .workspaces:
            var i = BarInputs()
            i.focusedWorkspace = sources.observers.tiler.focused
            return BarTooltip.text(.workspaces, i)
        case .modes: return BarTooltip.text(slot, sources.inputs(for: slot.entries))
        case .otherApps, .appMenus, .nothing: return BarTooltip.text(slot.kind, BarInputs())
        }
    }

    /// A click on a target for `kinds`: the slot's items, or in the Group the one item (or run of readings) clicked.
    private func perform(_ click: BarClick, kinds: [BarKind]? = nil) {
        let kinds = kinds ?? slot.kinds, one = kinds.count == 1 ? kinds.first : nil
        // Option on the item's own click does its Option-click (Volume mutes); a part with a click of its own keeps it.
        if let one, click == one.click, NSEvent.modifierFlags.contains(.option), let option = one.optionClick {
            return sources.perform(option)
        }
        if case .extension(let id) = click {
            return BarPanel.shared.toggle(extension: id, under: anchor.view, AnyView(ExtensionItemPopover(id: id, bar: sources.extensionBar)))
        }
        if click == .menu { return showMenu(sources.clickMenu(one ?? slot.kind, store: store)) }
        // On the pill-first bar the clock is a reading of the Calendar page: its click opens the pill there.
        if inBar, one == .clock, click == .popover, store.pillFirst.on, let page = store.pillFirst.pages.firstIndex(where: { $0.kind == .calendar }) {
            return PillDrop.shared.toggle(page: page)
        }
        guard click == .popover else { return sources.perform(click) }
        BarPanel.shared.toggle(kinds, under: anchor.view, AnyView(BarPopover(kinds: kinds, sources: sources, store: store)))
    }

    /// The right-click menu, or `rows` in its place (Capture's click menu).
    private func showMenu(_ rows: [BarMenuRow]? = nil) {
        guard let view = anchor.view else { return }
        // Keyed by what the slot is, so an extension's own item moves and goes on its own (spec pilot-1.1 T50).
        let item = slot.item
        BarMenu.show(rows ?? sources.menu(item, in: .topBar, store: store), under: view) { [sources, store] action in
            sources.perform(action, on: item, store: store) { perform(.popover) }
        }
    }
}

extension EnvironmentValues {
    /// Whether the items draw in the top bar (TopBarStrip sets it); false outside it (the macOS menu bar's preview),
    /// where they draw as macOS shows them.
    @Entry var inTopBar = false
    /// Whether the items draw in the Menu bar page's strips, where an item with nothing to show must still be grabbed.
    @Entry var barPreview = false
    /// Item colours (Sven, Q251): the top bar's readings amber or red by how hard they run, other apps' coloured items and
    /// a provider's glyph in their own colours; off, one colour. TopBarStrip sets it from the bar's switch; off elsewhere.
    @Entry var barItemColours = false
    /// The wallpaper's ground under a Glass or Clear Instrument bar (BarTone.ground) and the side of its ink, which its
    /// amber, red and green are made to read on, moving toward the ink; nil elsewhere, where they are the theme's own.
    @Entry var barGround: (colour: UInt32, lighter: Bool)? = nil
}

/// The colours Item colours draws a reading in (MenuBarStats.Level), nil while it is off or the reading runs normal: the
/// theme's amber and red, in every style (Instrument's own roles have no status colours). On a bar over the wallpaper
/// (`ground`) each keeps its hue and moves in lightness until it reads (Contrast.legible).
@MainActor
enum BarLevelInk {
    static func colour(_ parts: [BarPart], on: Bool, ground: (colour: UInt32, lighter: Bool)? = nil) -> Color? {
        guard on else { return nil }
        return parts.lazy.compactMap { part -> Color? in
            guard case .level(let level) = part else { return nil }
            return switch level {
            case .normal: nil
            case .high: status(\.amber, on: ground)
            case .critical: status(\.problem, on: ground)
            }
        }.first
    }

    /// The theme's status colour at `role` (good, amber, problem): as it is with no `ground`, else readable on it.
    static func status(_ role: KeyPath<PilotTheme, UInt32>, on ground: (colour: UInt32, lighter: Bool)?) -> Color {
        let theme = Look.shared.theme
        guard let ground else { return Color(hex: theme[keyPath: role]) }
        return Color(hex: Contrast.legible(theme[keyPath: role], on: ground.colour, lighter: ground.lighter))
    }
}

extension Extension.Gauge.Icon {
    /// The provider's own colour for its glyph while Item colours is on; nil keeps the bar's ink (OpenAI's mark is black or white).
    var brand: Color? { self == .claude ? Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) : nil }
}

extension View {
    /// A bar item's popover: the kit's (card agent-bo-95422914) in the style, with its arrow's room at the item.
    func barPopover(width: CGFloat = 300) -> some View {
        KitPopover(width: width) { self }
    }
}

/// An item's popover (card agent-bo-95422911, round 3 sections 4 and 5): each leads with its reading, then its detail,
/// then a way into Pilot. The same view hangs from the macOS menu bar's item and the top bar's.
struct BarPopover: View {
    let kinds: [BarKind]
    let sources: BarSources
    let store: BarItemsStore

    var body: some View {
        switch kinds.count == 1 ? kinds[0] : .group {
        case .pilot: sources.dropdown()
        case .workspaces: WorkspacesPopover(tiler: sources.observers.tiler)
        case .focusedApp: FocusedAppPopover(observers: sources.observers)
        case .volume: SoundPopover(sound: sources.readings.sound)
        case .keyboardLayout:
            KeyboardPopover(look: sources.readings.look, close: sources.closePopover, lock: { sources.runAction(KeyboardLockController.actionID) })
        case .wifi: WiFiPopover(readings: sources.readings)
        case .displays: DisplaysPopover(displays: sources.displays(), brightness: sources.brightness())
        case .power: PowerPopover(runner: sources.power, close: sources.closePopover)
        case .clock: ClockPopover(store: store, readings: sources.readings) { sources.openApp("com.apple.iCal") }
        case .timer: TimerPopover(timer: sources.timer)
        case .extensions: ExtensionBarPopover(bar: sources.extensionBar)
        case .modes: StatusPopover(lights: sources.readings.statusLights, close: sources.closePopover)
        default:
            LiveStatPopover(stats: kinds.compactMap(\.stat)) { AppWindowController.shared.open(.home) }
        }
    }
}

/// The workspaces with their apps, the focused one marked; a click goes there.
struct WorkspacesPopover: View {
    @Environment(\.style) private var style
    let tiler: TilerService

    var body: some View {
        let ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("Workspaces").font(ink.title); Spacer() }
            if tiler.focused == nil { Text("\(tiler.tilerName) is not running: tiling and workspaces are off").foregroundStyle(ink.muted) }
            ForEach(tiler.occupied, id: \.name) { workspace in
                let current = workspace.name == tiler.focused
                Button { tiler.go(workspace.name, from: "bar") } label: {
                    HStack(spacing: 10) {
                        Text(workspace.name).font(ink.readout(12, weight: .semibold)).foregroundStyle(current ? ink.accent : ink.muted).frame(width: 16)
                        Text(workspace.apps.joined(separator: ", ")).lineLimit(1).truncationMode(.tail)
                        Spacer()
                    }
                    .padding(.horizontal, 6).frame(minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(current ? (ink.instrument ? style.color(\.raised) : ink.selected) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .barPopover()
    }
}

/// The app in front: its icon, name and workspace.
struct FocusedAppPopover: View {
    @Environment(\.style) private var style
    let observers: EngineObservers

    var body: some View {
        let ink = BarInk(style: style)
        HStack(spacing: 10) {
            if let icon = observers.focusedApp?.icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
            VStack(alignment: .leading, spacing: 2) {
                Text(observers.focusedApp?.localizedName ?? "No app in front").font(ink.title)
                if let workspace = observers.tiler.focused { Text("Workspace \(workspace)").foregroundStyle(ink.muted) }
            }
            Spacer()
        }
        .barPopover(width: 240)
    }
}

/// The output's level and mute and the outputs to pick (round 3's Sound popover); the keyboard layout is its own item's.
struct SoundPopover: View {
    @Environment(\.style) private var style
    let sound: SetupSound

    var body: some View {
        let output = sound.side(.output), ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sound").font(ink.title)
                Spacer()
                Text(TopBarText.volume(output.volume?.value, muted: output.muted)).font(ink.readout(12)).foregroundStyle(ink.muted)
            }
            if let level = output.volume, level.settable {
                HStack {
                    Slider(value: Binding(get: { Double(sound.shownLevel(.output)) }, set: { sound.setVolume(Float($0), .output) }), in: 0...1)
                    if let muted = output.muted {
                        Button { sound.toggleMute(.output) } label: { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                            .buttonStyle(.plain).accessibilityLabel(muted ? "Unmute" : "Mute")
                    }
                }
            }
            Text("Output").font(ink.words).foregroundStyle(ink.muted)
            HidingList(list: .soundOutput, items: output.devices, id: { $0.uid }, name: \.name, inUse: { $0.id == output.current }) { device, _ in
                BarChoiceRow(symbol: "speaker.wave.2", title: device.name, chosen: device.id == output.current) { sound.pick(device.id, .output) }
            }
        }
        .barPopover(width: 280)
    }
}

/// The Keyboard layout item's popover (Sven on build 36): the enabled layouts, the one in use checked, a click switching
/// to one, and Next; under a divider, Lock keyboard for cleaning (Sven 2026-10-26, Q512), which closes the popover and runs
/// the registered action, as its bind does.
struct KeyboardPopover: View {
    @Environment(\.style) private var style
    let look: Look
    var close: () -> Void = {}
    var lock: () -> Void = {}

    var body: some View {
        let ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Keyboard").font(ink.title)
                Spacer()
                Button("Next") { look.pickNextLayout() }.barButton().disabled(look.layouts.count < 2)
            }
            ForEach(look.layouts, id: \.id) { layout in
                BarChoiceRow(symbol: "keyboard", title: layout.name, chosen: layout.isCurrent) { look.pickLayout(layout.id) }
            }
            Divider()
            BarChoiceRow(symbol: "lock.rectangle", title: "Lock keyboard for cleaning", chosen: false) { close(); lock() }
        }
        .barPopover(width: 280)
        .onAppear { look.followLayouts() }
    }
}

/// One choice in a popover's list, Sound's outputs and Keyboard's layouts: its glyph, its name, the one in use checked.
private struct BarChoiceRow: View {
    @Environment(\.style) private var style
    let symbol: String
    let title: String
    let chosen: Bool
    let pick: () -> Void

    var body: some View {
        let ink = BarInk(style: style)
        Button(action: pick) {
            HStack {
                Image(systemName: symbol).foregroundStyle(chosen ? ink.accent : ink.muted)
                Text(title)
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(ink.accent) }
            }
            .frame(minHeight: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Displays item's popover (Sven 2026-10-12): each screen's name, its brightness where Pilot reaches it (Apple's call
/// or DDC; none, no slider), its resolution and refresh rate, from System's Displays card's models, so a mode picked here
/// goes back by itself after 15 s unless kept, as there.
struct DisplaysPopover: View {
    @Environment(\.style) private var style
    let displays: SetupDisplays
    let brightness: Brightness?

    var body: some View {
        let ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 10) {
            Text("Displays").font(ink.title)
            if let connections = displays.connections {
                // An off screen may hide (spec hide-rows); one that is on is in use.
                HidingList(list: .displays, items: connections.screens, id: \.displayUUID,
                           name: { displays.nicknames.label(systemName: $0.name, displayUUID: $0.displayUUID) }, inUse: { $0.state == .on }, slot: true) { connection, _ in
                    connectionScreen(connection, ink, connections)
                }
                Button("Restore All Displays") { Task { await connections.restoreAll() } }
                    .barButton().disabled(connections.busy)
                if let problem = connections.problem {
                    Text(problem).font(ink.words).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await connections.refresh() } }.barButton()
                }
            } else {
                ForEach(displays.displays, id: \.id) { display in screen(display, ink) }
            }
            if let problem = displays.problem { Text(problem).font(ink.words).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            Button("Displays in Pilot") { AppWindowController.shared.open(.system, setup: .displays) }.barButton()
        }
        .barPopover(width: 300)
        .onAppear {
            displays.start()
            if let connections = displays.connections { Task { await connections.refresh() } }
        }
    }

    @ViewBuilder private func connectionScreen(_ connection: ConnectionScreen, _ ink: BarInk, _ connections: DisplayConnections) -> some View {
        let unique = connections.screens.filter { $0.displayUUID == connection.displayUUID }.count == 1
        let label = displays.nicknames.label(systemName: connection.name, displayUUID: unique ? connection.displayUUID : nil)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "display").foregroundStyle(ink.muted).accessibilityHidden(true)
                Text(label).fontWeight(.semibold).lineLimit(1).help(label)
                if connection.main { Text("main").font(ink.words).foregroundStyle(ink.muted) }
                Spacer()
                Text(connection.state.rawValue.uppercased()).font(ink.words).foregroundStyle(ink.muted)
            }
            DisplayNicknameEditor(systemName: connection.name, displayUUID: connection.displayUUID, nicknames: displays.nicknames,
                                  identityIsUnique: unique)
                .id(connection.displayUUID)
            Toggle("\(label) connection", isOn: Binding(get: { connection.state == .on }, set: { on in
                Task { await connections.setConnected(on, id: connection.id, binding: connection.binding) }
            }))
            .toggleStyle(.pilotSwitch)
            .disabled(connections.busy || connection.asleep || !connection.supported || ![.on, .off].contains(connection.state) || (connection.state == .on && (!connections.canDisconnect(connection) || connections.validationNeeded(connection))))
            if connection.state == .on && connections.validationNeeded(connection) {
                Text("Test connection briefly disconnects, then reconnects this display.").font(ink.words).foregroundStyle(ink.muted)
                Button("Test connection") { Task { await connections.validateConnection(id: connection.id, binding: connection.binding) } }
                    .barButton().accessibilityLabel("Test connection \(label)").disabled(connections.busy || !connections.canDisconnect(connection))
            }
            if connection.state == .on, let display = displays.displays.first(where: { $0.id == connection.id }) {
                screenControls(display, ink)
            }
        }
    }

    private func screen(_ display: DisplayInfo, _ ink: BarInk) -> some View {
        let unique = displays.displays.filter { $0.displayUUID == display.displayUUID }.count == 1
        let label = displays.nicknames.label(systemName: display.name, displayUUID: unique ? display.displayUUID : nil)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "display").foregroundStyle(ink.muted).accessibilityHidden(true)
                Text(label).fontWeight(.semibold).lineLimit(1).help(label)
                if display.main { Text("main").font(ink.words).foregroundStyle(ink.muted) }
                Spacer()
            }
            DisplayNicknameEditor(systemName: display.name, displayUUID: display.displayUUID, nicknames: displays.nicknames,
                                  identityIsUnique: unique)
                .id(display.displayUUID)
            screenControls(display, ink)
        }
    }

    @ViewBuilder private func screenControls(_ display: DisplayInfo, _ ink: BarInk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let read = brightness?.screens[display.id], let level = read.level {
                HStack {
                    Image(systemName: "sun.max.fill").foregroundStyle(ink.muted).accessibilityHidden(true)
                    Slider(value: Binding(get: { level }, set: { brightness?.set(display.id, $0) }), in: 0...1)
                        .accessibilityLabel("\(displays.nicknames.label(systemName: display.name, displayUUID: displays.displays.filter { $0.displayUUID == display.displayUUID }.count == 1 ? display.displayUUID : nil)) brightness")
                    Text("\(Int((level * 100).rounded())) %").font(ink.readout(12)).foregroundStyle(ink.muted).frame(width: 40, alignment: .trailing)
                }
                if read.route == .ddc { Text("DDC brightness").font(ink.words).foregroundStyle(ink.muted) }
            }
            if displays.offersPicker(display.id) {
                let sizes = displays.sizes(for: display.id), rates = displays.rates(for: display.id)
                HStack(spacing: 6) {
                    choice("Resolution", sizes, current: displays.selectedSize(for: display.id) ?? display.mode, on: display.id) { $0.sizeLabel }
                    if rates.count > 1 {
                        choice("Refresh rate", rates, current: displays.selectedRate(for: display.id) ?? display.mode, on: display.id) { $0.rate ?? "?" }
                    }
                    Spacer()
                }
            }
            if displays.canRotate(display.id) { rotation(display) }
            if let pending = displays.pending, pending.display == display.id {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Keep \(pending.new.label)? Going back in \(pending.secondsLeft(at: context.date)) s").font(ink.words).foregroundStyle(ink.muted)
                }
                HStack(spacing: 6) {
                    Spacer()
                    Button("Go back") { displays.revert() }.barButton().fixedSize()
                    Button("Keep") { displays.keep() }.barButton(primary: true).fixedSize()
                }
            }
        }
    }

    /// A picker as the bars' native menu at the pointer: a SwiftUI Picker's menu may not open in the popover's
    /// non-activating panel (ClockPopover's zone picker).
    private func choice(_ label: String, _ modes: [DisplayMode], current: DisplayMode, on display: CGDirectDisplayID,
                        title: @escaping (DisplayMode) -> String) -> some View {
        Button {
            BarMenu.pop(modes.map { mode in (title: title(mode), run: { displays.pick(mode, for: display) }) }, checked: title(current))
        } label: {
            HStack(spacing: 4) {
                Text(title(current))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .barButton().accessibilityLabel("\(label), \(title(current))")
    }

    /// Rotate › 0°, 90°, 180°, 270° with the one in use ticked (Sven 2026-10-22); a turn stays, and a tip offers Revert
    /// for 15 s (Sven 2026-10-24).
    private func rotation(_ display: DisplayInfo) -> some View {
        HStack(spacing: 6) {
            Button {
                BarMenu.pop(DisplayRotation.degrees.map { degrees in (title: "\(degrees)°", run: { displays.rotate(display.id, to: degrees) }) },
                            checked: "\(display.rotation)°")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rotate.right")
                    Text("Rotate \(display.rotation)°")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .barButton().accessibilityLabel("Rotate, \(display.rotation)°")
            Spacer()
        }
    }
}

/// The Power item's popover (Sven 2026-10-10): Lock screen, Sleep and Sleep displays run at once and close it; Restart,
/// Shut down and Log out ask first in place, the action's red word and Cancel, as an extension's ask does.
struct PowerPopover: View {
    @Environment(\.style) private var style
    let runner: any PowerRunning
    /// Takes the popover down once an action ran.
    var close: () -> Void = {}
    @State var ask = PowerAsk()

    var body: some View {
        let ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 2) {
            Text("Power").font(ink.title).padding(.horizontal, 6).padding(.bottom, 4)
            ForEach(PowerAction.allCases, id: \.self) { action in
                if action == .restart { ink.rule.frame(height: 1).padding(.vertical, 4) }
                if ask.asking == action { confirm(action, ink) } else { row(action, ink) }
            }
        }
        .barPopover(width: 260)
    }

    private func row(_ action: PowerAction, _ ink: BarInk) -> some View {
        Button {
            if ask.pick(action, on: runner) { close() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: action.symbol).foregroundStyle(ink.muted).frame(width: 18)
                Text(action.title)
                Spacer()
            }
            .padding(.horizontal, 6).frame(minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func confirm(_ action: PowerAction, _ ink: BarInk) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(action.confirmation?.question ?? action.title).font(ink.words).foregroundStyle(ink.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                Button("Cancel") { ask.cancel() }.buttonStyle(PilotButtonStyle()).fixedSize()
                Button(action.confirmation?.yes ?? action.title) { if ask.confirm(on: runner) { close() } }
                    .buttonStyle(PilotButtonStyle(primary: true, destructive: true)).fixedSize()
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(ink.selected))
    }
}

/// Wi-Fi's switch and link, never the network's name, which needs Location access Pilot never asks.
struct WiFiPopover: View {
    @Environment(\.style) private var style
    let readings: BarReadings

    var body: some View {
        let wifi = readings.wifi, ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Wi-Fi").font(ink.title)
                Spacer()
                // The radio's switch (T47), read back as soon as macOS has switched it.
                if let on = wifi?.on {
                    Toggle("Wi-Fi", isOn: Binding(get: { on }, set: { new in Task { await readings.setWiFi(new) } })).toggleStyle(.pilotSwitch)
                } else {
                    Text("No Wi-Fi").foregroundStyle(ink.muted)
                }
            }
            if let signal = wifi?.signal {
                LabeledContent("Signal", value: "\(signal) dBm · \(BarParts.wifiBars(signal)) of 4")
            }
            if let rate = wifi?.rate { LabeledContent("Rate", value: "\(Int(rate)) Mb/s") }
            Text("The network's name needs Location access, which Pilot never asks.").font(ink.words).foregroundStyle(ink.muted)
            Button("Wi-Fi in Pilot") { AppWindowController.shared.open(.system, setup: .wifi) }.barButton()
        }
        .barPopover(width: 260)
    }
}

/// The clock's popover (card agent-bo-95423011, SPEC story 168; Omarchy's look, omarchy-ideas T8), the date's and the
/// time's click: today's date big and centred (its click goes back to today) over the time, the week and the second zone,
/// a rail of the year gone, then a month by ISO weeks, Monday first, the weeks' numbers dim behind a hairline, today
/// outlined, a dot on each day with events (a holiday's day red and underlined), and the ‹ MONTH › stepper at its foot;
/// ‹ ›, ← → and ↑ ↓ change the month. A click on a day opens its card over the popover (Sven, 2026-10-23, on build 86):
/// that day's events as the list draws them, or Show events / the refused line; Escape or a click beside it closes it. Under it the next days' events, once Show events is on (which is when Calendar
/// access is asked; never before), each opening in Calendar, then a New event field; Open Calendar and the second zone's
/// picker at the foot.
struct ClockPopover: View {
    @Environment(\.style) private var style
    let store: BarItemsStore
    let readings: BarReadings
    /// Calendar itself, from the foot and for an event Calendar has no link to.
    let openCalendar: () -> Void
    /// Months from today's that the grid shows.
    @State private var offset = 0
    /// The day whose card shows, by its date in the grid.
    @State private var picked: Date?
    static let width: CGFloat = 380

    init(store: BarItemsStore, readings: BarReadings, picked: Date? = nil, openCalendar: @escaping () -> Void) {
        self.store = store
        self.readings = readings
        self.openCalendar = openCalendar
        _picked = State(initialValue: picked)
    }
    /// The second zones offered, by city; the one set stays offered whatever it is.
    static let zones = ["UTC", "Europe/London", "Europe/Madrid", "Europe/Malta", "America/New_York", "America/Bogota",
                        "America/Los_Angeles", "Asia/Dubai", "Asia/Singapore", "Asia/Tokyo", "Australia/Sydney"]

    var body: some View {
        let now = readings.now, here = TimeZone.autoupdatingCurrent
        let on = store.settings.clockEvents
        let events = on ? readings.calendar.events : nil
        let shown = ClockMonth.month(offset, from: now, timeZone: here)
        let month = ClockMonth(showing: shown, now: now, timeZone: here, locale: .autoupdatingCurrent, events: events ?? [])
        let ink = BarInk(style: style)
        VStack(alignment: .leading, spacing: 12) {
            hero(now, week: month.week, here: here, ink: ink)
            yearRail(now, here: here, ink: ink)
            grid(month, ink: ink)
            rule(ink)
            if !on {
                showEvents(ink)
            } else if let events {
                upcoming(ClockMonth.upcoming(events, now: now, timeZone: here), now: now, here: here, ink: ink)
                rule(ink)
                NewEvent(calendar: readings.calendar, hours: hours)
            } else if readings.calendar.refused {
                refused(ink)
            }
            rule(ink)
            footer(now, ink: ink)
        }
        .overlayPreferenceValue(DayAnchor.self) { anchor in
            if let day = month.weeks.joined().first(where: { $0.date == picked }), let anchor {
                GeometryReader { box in dayCard(day, at: box[anchor], in: box.size, on: on, loaded: events != nil, ink: ink) }
            }
        }
        .barPopover(width: Self.width)
        .background(MonthKeys(step: { offset += $0 }, escape: picked == nil ? nil : { picked = nil }))
        .onChange(of: offset) { picked = nil }
        .task(id: on ? offset : nil) {
            guard on else { return }
            await readings.calendar.load(showing: shown, now: now, timeZone: here)
        }
    }

    private var zone: TimeZone? { store.settings.clockZone.flatMap(TimeZone.init(identifier:)) }
    private var hours: TopBarClockFormat { store.settings.clock.hoursAndMinutes }

    private func rule(_ ink: BarInk) -> some View {
        ink.rule.frame(height: ink.toybox ? 2 : 1).padding(.horizontal, -PopoverMetrics.inset)
    }

    /// Today's month and day large and centred, a click back to today; under it the time, the week and the second zone.
    private func hero(_ now: Date, week: Int, here: TimeZone, ink: BarInk) -> some View {
        let full = ClockMonth.fullDate(now, timeZone: here, locale: .autoupdatingCurrent)
        return VStack(spacing: 4) {
            Button { offset = 0 } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 22, weight: .semibold)).foregroundStyle(ink.accent)
                    Text(ClockMonth.heroDate(now, timeZone: here, locale: .autoupdatingCurrent))
                        .font(ink.toybox ? ToyFace.fredoka(34) : ink.readout(32, weight: .bold)).foregroundStyle(ink.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("\(full), back to today").accessibilityLabel("\(full), back to today")
            HStack(spacing: 6) {
                Text(hours.text(now)).font(ink.readout(12, weight: .medium)).monospacedDigit().foregroundStyle(ink.text2)
                Text("· Week \(week)").foregroundStyle(ink.muted)
                if let zone {
                    Text("· \(BarParts.city(zone)) \(hours.text(now, timeZone: zone))").monospacedDigit().foregroundStyle(ink.muted)
                }
            }
            .font(ink.words)
        }
        .frame(maxWidth: .infinity)
    }

    /// The year and a thin bar of its share gone, the percentage on the right.
    private func yearRail(_ now: Date, here: TimeZone, ink: BarInk) -> some View {
        let done = ClockMonth.yearDone(now, timeZone: here)
        let year = Calendar(identifier: .iso8601).dateComponents(in: here, from: now).year ?? 0
        return HStack(spacing: 10) {
            Text(String(year)).font(ink.readout(11, weight: .medium)).foregroundStyle(ink.text2)
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.selected)
                    Capsule().fill(ink.toybox ? ink.accentFill : ink.text2).frame(width: box.size.width * done)
                }
            }
            .frame(height: 6)
            Text("\(Int(done * 100))%").font(ink.readout(11, weight: .medium)).monospacedDigit().foregroundStyle(ink.muted)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(year), \(Int(done * 100)) percent gone")
    }

    /// The weekdays and a row a week, its ISO number dim behind a hairline; the ‹ MONTH YEAR › stepper at the foot,
    /// its title fixed in width so the arrows never move, accent when another month shows.
    private func grid(_ month: ClockMonth, ink: BarInk) -> some View {
        let small = ink.instrument ? ink.readout(10, weight: .medium) : .system(size: 10, weight: .semibold)
        let hairline = ink.rule.frame(width: 1)
        return VStack(spacing: 8) {
            Grid(horizontalSpacing: 0, verticalSpacing: 4) {
                GridRow {
                    Text("W").font(small).foregroundStyle(ink.muted.opacity(0.6)).frame(width: 30).overlay(alignment: .trailing) { hairline }
                    ForEach(Array(month.weekdays.enumerated()), id: \.offset) { Text($1).font(small).foregroundStyle(ink.muted).frame(maxWidth: .infinity) }
                }
                ForEach(Array(month.weeks.enumerated()), id: \.offset) { i, week in
                    GridRow {
                        Text("\(month.weekNumbers[i])").font(ink.readout(10)).foregroundStyle(ink.muted.opacity(0.6))
                            .frame(width: 30, height: 30).overlay(alignment: .trailing) { hairline }
                        ForEach(week, id: \.date) { day in DayCell(day: day, picked: day.date == picked) { picked = day.date } }
                    }
                }
            }
            HStack(spacing: 6) {
                MonthArrow(symbol: "chevron.left", label: "Previous month") { offset -= 1 }
                Button { offset = 0 } label: {
                    Text(month.title.uppercased()).font(ink.readout(12, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(month.isCurrent ? ink.text : ink.accent).frame(width: 170).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Back to today").accessibilityLabel("\(month.title), back to today")
                MonthArrow(symbol: "chevron.right", label: "Next month") { offset += 1 }
            }
        }
    }

    /// A picked day's card under its cell, or over it when there is more room above, kept inside the popover; a click
    /// beside it closes it. Its events as the list draws them, at most five and the rest in Calendar; with events off or
    /// refused, what the list shows instead. Only what the month read is shown: a click never asks Calendar access.
    private func dayCard(_ day: ClockMonth.Day, at cell: CGRect, in box: CGSize, on: Bool, loaded: Bool, ink: BarInk) -> some View {
        let width: CGFloat = 270, gap: CGFloat = 4, above = cell.minY > box.height - cell.maxY
        let card = KitPopover(width: width, arrow: false) {
            if on, loaded, day.events.isEmpty {
                Text("Nothing on \(day.title)").font(ink.words).foregroundStyle(ink.muted)
            } else {
                eyebrow(day.title, ink).padding(.bottom, 8)
                if !on {
                    HStack {
                        Text("Events are off").font(ink.words).foregroundStyle(ink.muted)
                        Spacer()
                        Button("Show events") { store.settings.clockEvents = true }.barButton()
                    }
                } else if loaded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(day.events.prefix(5).enumerated()), id: \.offset) { _, event in EventRow(event: event, hours: hours, open: open) }
                    }
                    if day.events.count > 5 {
                        Button("\(day.events.count - 5) more in Calendar", action: openCalendar).buttonStyle(.plain).font(ink.words).foregroundStyle(ink.muted)
                    }
                } else if readings.calendar.refused {
                    refused(ink)
                }
            }
        }
        .shadow(color: .black.opacity(ink.toybox ? 0 : 0.25), radius: 10, y: 4)
        .contentShape(Rectangle()).onTapGesture {}
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { picked = nil }
            card.frame(height: above ? cell.minY - gap : box.height - cell.maxY - gap, alignment: above ? .bottom : .top)
                .offset(x: min(max(cell.midX - width / 2, 0), box.width - width), y: above ? 0 : cell.maxY + gap)
        }
        .frame(width: box.width, height: box.height, alignment: .topLeading)
    }

    /// Events off: one button turns them on, which asks Calendar access the first time.
    private func showEvents(_ ink: BarInk) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar").foregroundStyle(ink.muted)
            Text("Calendar events").font(ink.words).foregroundStyle(ink.muted)
            Spacer()
            Button("Show events") { store.settings.clockEvents = true }.barButton()
        }
    }

    /// Asked and refused: where to give it, and a way to turn events off again.
    private func refused(_ ink: BarInk) -> some View {
        HStack(spacing: 10) {
            Text("No Calendar access").font(ink.words).foregroundStyle(ink.muted).fixedSize()
            Spacer()
            Button("Allow") { readings.calendar.open(ClockCalendar.privacy) }.barButton().help("Privacy & Security › Calendars")
            hideEvents
        }
    }

    private var hideEvents: some View {
        IconButton(symbol: "eye.slash", label: "Hide events", size: 20, glyph: 11) { store.settings.clockEvents = false }
    }

    /// Today and the next days with events, each with its time, its calendar's colour and its title.
    private func upcoming(_ days: [ClockMonth.Listed], now: Date, here: TimeZone, ink: BarInk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(days, id: \.date) { day in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        eyebrow(ClockMonth.dayName(day.date, now: now, timeZone: here, locale: .autoupdatingCurrent), ink)
                        Spacer()
                        if day.date == days.first?.date { hideEvents }
                    }
                    if day.events.isEmpty { Text("Nothing else today").foregroundStyle(ink.muted) }
                    ForEach(Array(day.events.enumerated()), id: \.offset) { _, event in EventRow(event: event, hours: hours, open: open) }
                }
            }
        }
    }

    /// A day's name over its events.
    @ViewBuilder private func eyebrow(_ name: String, _ ink: BarInk) -> some View {
        if ink.instrument { InstrumentEyebrow(text: name) } else {
            Text(name.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(ink.muted)
        }
    }

    private func open(_ event: ClockEvent) {
        if let url = event.url { readings.calendar.open(url) } else { openCalendar() }
    }

    /// Open Calendar on the left, the second zone's picker on the right.
    private func footer(_ now: Date, ink: BarInk) -> some View {
        HStack {
            if ink.toybox || ink.instrument { Button("Open Calendar", action: openCalendar).barButton() } else { AccentLink(title: "Open Calendar", action: openCalendar) }
            Spacer()
            // The bars' native menu at the pointer: a SwiftUI Menu in the popover's non-activating panel may not open,
            // as the extension row's ⋯ did not (Sven on build 20).
            Button {
                let current = store.settings.clockZone, choices = Self.zoneChoices(current)
                BarMenu.pop(choices.map { choice in (choice.title, { store.settings.clockZone = choice.id }) },
                            checked: choices.first { $0.id == current }?.title)
            } label: {
                Label(zone == nil ? "Second zone" : "Change zone", systemImage: "globe").font(ink.words).contentShape(.rect)
            }
            .buttonStyle(.plain).fixedSize()
            .foregroundStyle(ink.muted)
        }
    }

    /// The second-zone menu: None, then each zone offered and the one set, by city name.
    static func zoneChoices(_ current: String?) -> [(id: String?, title: String)] {
        [(nil, "None")] + Set(zones + [current].compactMap { $0 }).sorted().map { id in (id, TimeZone(identifier: id).map(BarParts.city) ?? id) }
    }

    /// ‹ or ›.
    private struct MonthArrow: View {
        @Environment(\.style) private var style
        let symbol: String
        let label: String
        let action: () -> Void

        var body: some View {
            let ink = BarInk(style: style)
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(ink.text2)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
                    .background {
                        if ink.toybox { Toy.block(style, fill: style.color(\.sunken), radius: 7, edge: 2) }
                        else { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink.selected) }
                    }
            }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
        }
    }

    /// A new event in plain words (Sven, 2026-10-23, Q420), what Pilot read shown under it as it is typed; Return or Add
    /// saves it to the default calendar, where the list reads it back.
    private struct NewEvent: View {
        @Environment(\.style) private var style
        let calendar: ClockCalendar
        let hours: TopBarClockFormat
        @State private var text = ""
        /// What the text reads as, parsed as it changes.
        @State private var event: QuickEvent?
        /// What the last add did, until the next word is typed.
        @State private var said: String?

        var body: some View {
            let ink = BarInk(style: style)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("New event", text: $text, prompt: Text("+ New event: lunch tomorrow 1pm"))
                        .pilotField().onSubmit(add).accessibilityLabel("New event")
                    Button("Add", action: add).barButton(primary: true).disabled(event == nil)
                }
                Group {
                    if let event {
                        let to = calendar.newEventsCalendar.map { " · \($0)" } ?? ""
                        Text("→ \(Text(event.title).foregroundStyle(ink.text).fontWeight(.semibold)) · \(event.when(time: { hours.text($0) }))\(to)")
                    } else if !text.isEmpty {
                        Text("Add a day or a time: tomorrow 1pm, fri 9:30, 3 nov")
                    } else if let said {
                        Text(said)
                    }
                }
                .font(ink.words).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.tail)
            }
            .onChange(of: text) {
                event = QuickEvent.parse(text)
                if !text.isEmpty { said = nil }
            }
        }

        private func add() {
            guard let event else { return }
            text = ""
            Task { said = await calendar.add(event) }
        }
    }

    /// An event: its start (All day) in mono, its calendar's colour, its title; a click opens it in Calendar. A holiday's
    /// title is a red chip (Sven, 2026-10-23, Q418).
    private struct EventRow: View {
        @Environment(\.style) private var style
        let event: ClockEvent
        let hours: TopBarClockFormat
        let open: (ClockEvent) -> Void

        var body: some View {
            let ink = BarInk(style: style)
            Button { open(event) } label: {
                HStack(spacing: 9) {
                    Text(event.allDay ? "All day" : hours.text(event.start)).font(ink.readout(11)).foregroundStyle(ink.text2)
                        .frame(width: 52, alignment: .leading)
                    if event.holiday {
                        Text(event.title).font(ink.words).fontWeight(.semibold).foregroundStyle(ink.holiday).lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(ink.holiday.opacity(0.15), in: .rect(cornerRadius: ink.toybox ? 7 : 5, style: .continuous))
                    } else {
                        Capsule().fill(colour(ink)).frame(width: ink.instrument ? 2 : 3, height: 16)
                        Text(event.title).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(event.allDay ? event.title : "\(event.title), \(hours.text(event.start)) – \(hours.text(event.end))")
        }

        private func colour(_ ink: BarInk) -> Color {
            guard let c = event.colour else { return ink.toybox ? ink.accentFill : ink.instrument ? style.color(\.line3) : Theme.yellow }
            return Color(c)
        }
    }

    /// A day: its number in mono, dim outside the month, today outlined in the accent (never filled, Toybox too), a dot
    /// under a day with events; a holiday's number red over a short red line instead. A click picks it (its card); the
    /// pointer over it, or its card open, fills it.
    private struct DayCell: View {
        @Environment(\.style) private var style
        let day: ClockMonth.Day
        let picked: Bool
        let pick: () -> Void
        @State private var hovered = false

        var body: some View {
            let ink = BarInk(style: style)
            Button(action: pick) { number(ink) }
                .buttonStyle(.plain).onHover { hovered = $0 }.pointerStyle(.link)
                .anchorPreference(key: DayAnchor.self, value: .bounds) { picked ? $0 : nil }
                .accessibilityLabel(day.title)
                .accessibilityValue(day.events.isEmpty ? "" : "\(day.events.count) events")
        }

        private func number(_ ink: BarInk) -> some View {
            let cell = RoundedRectangle(cornerRadius: ink.toybox ? 8 : 5, style: .continuous)
            return Text("\(day.number)").font(ink.readout(13, weight: day.isToday ? .bold : .medium))
                .foregroundStyle(day.isToday ? ink.accent : !day.inMonth ? ink.muted.opacity(0.5) : day.isHoliday ? ink.holiday : ink.text)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background {
                    if hovered || picked {
                        cell.fill(ink.selected).padding(.horizontal, 4)
                    }
                }
                .contentShape(Rectangle())
                .overlay {
                    if day.isToday {
                        cell.strokeBorder(ink.accentFill, lineWidth: ink.toybox ? 2 : 1.5).padding(.horizontal, 4)
                    }
                }
                .overlay(alignment: .bottom) {
                    if day.isHoliday {
                        Capsule().fill(ink.holiday.opacity(day.inMonth ? 1 : 0.5)).frame(width: 14, height: 2).padding(.bottom, 2)
                    } else if day.hasEvents {
                        Circle().fill(ink.toybox ? Toy.module(3, style) : ink.instrument ? (day.isToday ? ink.accent : ink.muted) : Theme.yellow)
                            .frame(width: 4, height: 4).padding(.bottom, 2)
                    }
                }
        }
    }

    /// The picked day cell's bounds: where its card hangs.
    private struct DayAnchor: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
    }
}

/// The arrow keys in the panel this view is in, while it is key: each hands `step` the month it moves by
/// (ClockMonth.step), unless a field is being typed in (New event). Escape is BarPanel's, which closes the popover,
/// unless `escape` is set (a day's card open): then the panel hands it that instead (KeyPanel.escape).
private struct MonthKeys: NSViewRepresentable {
    let step: (Int) -> Void
    let escape: (() -> Void)?

    func makeNSView(context: Context) -> Watch { Watch() }
    func updateNSView(_ view: Watch, context: Context) {
        view.step = step
        view.escape = escape
    }

    final class Watch: NSView {
        var step: (Int) -> Void = { _ in }
        var escape: (() -> Void)? { didSet { (window as? KeyPanel)?.escape = escape } }
        private var monitor: Any?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            (window as? KeyPanel)?.escape = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? KeyPanel)?.escape = escape
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // An arrow is used up; any other key passes on.
                let used: Bool = MainActor.assumeIsolated {
                    guard let self, event.window === self.window, !(self.window?.firstResponder is NSText),
                          event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
                          let by = ClockMonth.step(keyCode: Int64(event.keyCode)) else { return false }
                    self.step(by)
                    return true
                }
                return used ? nil : event
            }
        }
    }
}

/// The extension timer: its ring and countdown, its title, when it ends (or Paused) and its buttons; with none running,
/// that it is not and Get Pomodoro, which opens the Extensions page's catalogue at it.
struct TimerPopover: View {
    @Environment(\.style) private var style
    let timer: ExtensionTimer

    var body: some View {
        let ink = BarInk(style: style)
        VStack(spacing: 8) {
            ZStack {
                TimerRing(left: timer.left ?? 0, lineWidth: ink.toybox ? 9 : ink.instrument ? 4 : 7,
                          track: ink.toybox ? style.color(\.sunken) : ink.instrument ? style.color(\.line2) : nil,
                          tint: ink.toybox ? Toy.module(3, style) : ink.instrument ? style.color(\.accent) : nil).frame(width: 96, height: 96)
                if ink.instrument {
                    Text(timer.countdown ?? "–").font(ink.readout(20, weight: .medium)).monospacedDigit()
                } else {
                    Text(timer.countdown ?? "–").font(ink.toybox ? ToyFace.fredoka(24) : Theme.mono(20, weight: .semibold))
                }
            }
            .padding(.top, 4)
            if let title = timer.title {
                Text(title).font(ink.title)
                if let when = TimerWords.when(timer) { Text(when).foregroundStyle(ink.muted) }
                TimerButtons(timer: timer) { title, primary, run in Button(title, action: run).barButton(primary: primary) }
            } else {
                Text("No timer running.").font(ink.title)
                Button("Get Pomodoro") { AppWindowController.shared.open(AppPlace(.extensionCatalogue), extension: "pomodoro") }.barButton(primary: true)
            }
        }
        .frame(maxWidth: .infinity)
        .barPopover(width: 240)
    }
}

/// What every timer surface says beside the countdown.
enum TimerWords {
    /// "Paused", or "Ends at 10:25"; nil with no timer.
    @MainActor static func when(_ timer: ExtensionTimer) -> String? {
        if timer.isPaused { return "Paused" }
        return timer.ends.map { "Ends at \($0.formatted(date: .omitted, time: .shortened))" }
    }
}

/// The timer's buttons, its extension's actions, in rows of two, each drawn by `button` with its title, whether it is the
/// first (primary) and what pressing it does; Stop when the extension gave none, so a timer never sits there unstoppable.
struct TimerButtons<Drawn: View>: View {
    let timer: ExtensionTimer
    @ViewBuilder let button: (String, Bool, @escaping () -> Void) -> Drawn

    var body: some View {
        let actions = timer.buttons
        VStack(spacing: 6) {
            if actions.isEmpty {
                button("Stop", false) { timer.stop() }
            } else {
                ForEach(Array(stride(from: 0, to: actions.count, by: 2)), id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row..<min(row + 2, actions.count), id: \.self) { i in button(actions[i].label, i == 0) { timer.press(i) } }
                    }
                }
            }
        }
    }
}

/// The AppKit view behind a SwiftUI one, for hanging a panel or menu under it; with `rightClick` it takes the right
/// mouse button there (the item's menu, card agent-bo-95423010), with `scroll` the scroll wheel, as steps up positive,
/// both handed to it by the bar's window (TopBarPanel), and leaves every other event to the SwiftUI view. One that
/// `optionPasses` (another app's item, whose right-click is that app's menu) leaves an Option+right-click to the anchor
/// under it: Pilot's own item menu.
struct ScreenAnchor: NSViewRepresentable {
    /// Holds the AppKit view; a class, so a click reads where the view is at that moment.
    final class Box {
        weak var view: NSView?
    }
    let box: Box
    var rightClick: (() -> Void)?
    var scroll: ((Int) -> Void)?
    var optionPasses = false

    final class AnchorView: NSView {
        var rightClick: (() -> Void)?
        var scroll: ((Int) -> Void)?
        var optionPasses = false
        private var steps = BarScroll.Steps()

        /// The anchor under `event` with a use for it (a right button or wheel event; nil for any other), the frontmost
        /// first.
        static func taking(_ event: NSEvent, in view: NSView?) -> AnchorView? {
            let wants: (AnchorView) -> Bool
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                let option = event.modifierFlags.contains(.option)
                wants = { $0.rightClick != nil && !(option && $0.optionPasses) }
            case .scrollWheel: wants = { $0.scroll != nil }
            default: return nil
            }
            func under(_ view: NSView?) -> AnchorView? {
                for sub in view?.subviews.reversed() ?? [] where !sub.isHidden {
                    if let anchor = sub as? AnchorView, wants(anchor), anchor.convert(anchor.bounds, to: nil).contains(event.locationInWindow) {
                        return anchor
                    }
                    if let found = under(sub) { return found }
                }
                return nil
            }
            return under(view)
        }

        /// What the bar's window hands it: the menu on the right button's up (its down is used up), the steps of a scroll.
        func take(_ event: NSEvent) {
            switch event.type {
            case .rightMouseUp: rightClick?()
            case .scrollWheel:
                // Up means louder and the previous workspace whichever way the Mac's natural scrolling turns the wheel.
                let delta = Double(event.scrollingDeltaY) * (event.isDirectionInvertedFromDevice ? -1 : 1)
                let count = steps.add(delta, precise: event.hasPreciseScrollingDeltas)
                if count != 0 { scroll?(count) }
            default: break
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        box.view = view
        view.rightClick = rightClick
        view.scroll = scroll
        view.optionPasses = optionPasses
    }
}
