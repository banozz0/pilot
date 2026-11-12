import PilotCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Menu bar (card agent-bo-95422913, design round 4 section 6 and pick 6's page cut): one page for the macOS
/// menu bar and Pilot's top bar. The top bar's switch and screens, a live strip of the bar the page shows (Menu bar, Top
/// bar or Both) and under it the bar tray (Sven, Q185): drag from the tray onto the strip to add, along the strip to
/// reorder, back to the tray to take off. Then every group of items with its switches and styles (the readings among
/// them, Sven 2026-10-16), and the clock's pattern. It replaces the Top bar page and This Mac's In the menu bar list. Drawn as
/// design round 4's mbPage (card agent-bo-95422914): cards with a switch per item.
struct MenuBarPage: View {
    @Environment(\.ink) private var ink
    @Environment(Engine.self) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The window shows: the preview reads live only then (a closed window is kept, and keeps its pages).
    let onScreen: Bool
    /// Which placement the page shows and + edits: the one picked last (BarItemsStore.pagePlacement) unless given.
    @State private var placement: BarPlacement
    /// The clock pattern being typed, applied on Return so the bars never draw a half-typed one.
    @State private var pattern: String?
    /// The readers the preview holds while the page shows.
    @State private var held: Set<BarKind> = []
    /// The item being dragged from the strip or the tray, set as its drag starts.
    @State private var dragged: BarTrayItem?
    /// Where the top bar strip drew each slot (BarFrames.space), its size, and the pointer over it mid-drag.
    @State private var topFrames: [TopBarSide: [Int: CGRect]] = [:]
    @State private var topSize: CGSize = .zero
    @State private var overTop: CGPoint?
    /// Where the menu bar strip drew each of Pilot's slots and its row (menuSpace), and the pointer's x over it mid-drag.
    @State private var menuFrames: [Int: CGRect] = [:]
    @State private var menuRow: CGRect = .zero
    @State private var overMenu: CGFloat?
    /// Clear all or Restore defaults, asked before it goes through.
    @State private var asking: BarReset?
    var nicknames: DisplayNicknames = .shared
    /// The extensions' bar items the page lists and places: the app's, or a render's.
    var extensionBar: ExtensionBar = .shared

    init(onScreen: Bool, placement: BarPlacement? = nil, nicknames: DisplayNicknames = .shared, extensionBar: ExtensionBar = .shared) {
        self.onScreen = onScreen
        self.nicknames = nicknames
        self.extensionBar = extensionBar
        _placement = State(initialValue: placement ?? BarItemsStore.shared.pagePlacement)
    }

    var body: some View {
        let store = BarItemsStore.shared, topBar = engine.topBar
        PageBody {
            if let problem = store.loadError { FinePrint(text: problem, color: ink.red) }
            // The switch, its problem and the hidden items' notice are one group, closer together than the blocks.
            VStack(alignment: .leading, spacing: 8) {
                SwitchCard(symbol: "menubar.rectangle", name: "Top bar", isOn: topBar.isOn, busy: topBar.busy,
                           detail: "Pilot's own bar in place of the macOS menu bar. On hides the menu bar (it still slides down when you point at the top edge); items in both bars move to it. Off gives the menu bar back as it was.") {
                    topBar.set(!topBar.isOn)
                }
                if let problem = topBar.problem { FinePrint(text: problem, color: ink.red) }
                onlyInTopBar(store, topBarOn: topBar.isOn)
            }
            HStack(alignment: .bottom) {
                Text("Drag from the tray onto the bar to add, along it to reorder, back to the tray to take off. Drop an item on the Group's dotted outline to group it; drag it out, or right-click Ungroup, to take it out.")
                    .font(ink.ui(13)).foregroundStyle(ink.text2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                resets(store)
                placements
            }
            Tile {
                VStack(alignment: .leading, spacing: 14) {
                    preview(store)
                    BarTray(store: store, placement: placement, extensions: extensionBar.items, dragged: $dragged)
                }
            }
            // The page reads top to bottom as the bar does (Sven, 2026-11-12, Q182: "too crowded and im getting confused"):
            // the switch, the bar's items, how the bar looks, each item's style, the clock and the pill, then the screens.
            // Pilot's own menu has its own page beside this one (PilotMenuPage).
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow(alignment: .top) {
                    BarPresetControls(store: store)
                    barColour(store)
                }
            }
            // Rows of two cards, each row's blocks one height; the readings are a group like any other (Sven, 2026-10-16).
            let columns = 2, groups = BarGroup.allCases
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: groups.count, by: columns)), id: \.self) { start in
                    GridRow(alignment: .top) {
                        ForEach(groups[start..<min(start + columns, groups.count)], id: \.self) { group in groupTile(group, store: store) }
                    }
                }
            }
            clock(store)
            PillEditor(extensionBar: extensionBar)
            screenChoices(topBar)
        }
        .disabled(store.loadError != nil)
        .onAppear { hold(previewed(store)) }
        .onChange(of: previewed(store)) { hold(previewed(store)) }
        .onChange(of: onScreen) { hold(previewed(store)) }
        .onChange(of: placement) { store.pagePlacement = placement }
        // The top bar switched on or off moved it (BarItemsStore.topBarSwitched).
        .onChange(of: store.pagePlacement) { placement = store.pagePlacement }
        .onDisappear { hold([]) }
    }

    /// Same system-name bindings, with row identity kept separate from the visible nickname.
    func screenChoices(_ topBar: TopBarController) -> some View {
        Tile(title: "Screens", symbol: "display") {
            FinePrint(text: "The top bar shows on each screen switched on here.").padding(.bottom, 4)
            ForEach(Self.screenRows(topBar.connected), id: \.id) { row in
                let screen = row.screen
                let label = nicknames.label(systemName: screen.name, displayUUID: row.displayUUID)
                Toggle(isOn: Binding(get: { !topBar.leftOut.contains(screen.name) },
                                     set: { on in if on { topBar.leftOut.remove(screen.name) } else { topBar.leftOut.insert(screen.name) } })) {
                    TitledText(title: label,
                               detail: "\(TopBarGeometry.inset(screen.strip)) pt high, the menu bar's own height").lineLimit(1)
                        .help(label)
                }
                .toggleStyle(.pilotSwitchRow)
                .padding(.vertical, 6)
            }
        }
    }

    static func screenRows(_ screens: [TopBarGeometry.Screen]) -> [(id: String, screen: TopBarGeometry.Screen, displayUUID: String?)] {
        let uuids = screens.map { $0.displayUUID.flatMap(UUID.init(uuidString:))?.uuidString }
        return screens.enumerated().map { index, screen in
            let uuid = uuids[index].flatMap { value in uuids.filter { $0 == value }.count == 1 ? value : nil }
            return (id: uuid ?? "unidentified-\(index)", screen: screen, displayUUID: uuid)
        }
    }

    /// The top bar's own Background and Colour (Sven, 2026-10-10): Solid in the theme's bar colour until picked, whatever
    /// Look's Glass says.
    private func barColour(_ store: BarItemsStore) -> some View {
        @Bindable var store = store
        // The label and its ⓘ in one column, so both controls still start level.
        let label = { (title: String, info: String) in
            HStack(spacing: 6) { Text(title).font(ink.ui(12)).foregroundStyle(ink.muted); InfoMark(text: info) }
                .frame(width: 104, alignment: .leading)
        }
        return Tile(title: "Bar background", symbol: "paintbrush") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    label("Background", "Solid paints the bar in its colour; Glass lets the desktop show through, whatever Look's own Glass is.")
                    Segments(selection: $store.background, options: TopBarBackground.allCases.map { ($0, $0.title) }, label: "Background")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    label("Colour", "The theme's bar colour until you pick one of your own.")
                    ColourChoicePicker(choice: $store.colour, theme: TopBarColour.ground(.theme, style: TopBarWindows.tokens(.shared)),
                                       label: "Bar colour")
                    Spacer(minLength: 0)
                }
                // Each item in its own colour (Sven, Q251), on by default.
                HStack(spacing: 10) {
                    label("Item colours", "CPU, GPU and memory turn amber at 70 % and red at 90 %, the disk at 85 and 95 %, the temperature at 80 and 95 °C, the battery at 20 and 10 % left. Other apps' items keep their own colours, Claude's glyph its orange; Pilot's own items stay in the theme's colour. Off, the bar is one colour.")
                    Toggle("Item colours", isOn: $store.itemColours).toggleStyle(.pilotSwitch)
                    Spacer(minLength: 0)
                }
                FinePrint(text: "Glass tints the glass with the colour, at Look's Transparency. Clear shows the wallpaper with no tint, as the macOS menu bar does, the text in the theme's own colour. On a colour the theme's text would not read on, the bar's text turns white or dark.")
            }
        }
    }

    /// Which placement the page shows and + edits.
    private var placements: some View {
        HStack(spacing: 8) {
            InfoMark(text: "Which bar the strip and the item switches below are for.")
            Segments(selection: $placement, options: BarPlacement.allCases.map { ($0, $0.title) }, label: "Shows")
        }
    }

    /// The items the preview shows.
    private func previewed(_ store: BarItemsStore) -> Set<BarKind> {
        let preview = store.settings.preview(placement)
        return Set(((preview.top?.values.joined()).map(Array.init) ?? []).flatMap(\.kinds) + (preview.menu ?? []).flatMap(\.kinds))
    }

    /// The preview's items read live, as the bars do, only while the window shows.
    private func hold(_ kinds: Set<BarKind>) {
        engine.barSources.readings.hold(onScreen ? kinds : [], replacing: &held)
    }

    // MARK: Top bar only

    /// Items on in the top bar only show nowhere while it is off (card agent-bo-95422993, G1): one line naming them and the
    /// button that puts them in the menu bar too. The dropdown's problem row (the amber triangle, the words, the fix) at the
    /// switch card's corner, so the two sit square.
    @ViewBuilder private func onlyInTopBar(_ store: BarItemsStore, topBarOn: Bool) -> some View {
        let kinds = store.settings.onlyInTopBar
        if let line = BarSettings.onlyInTopBarLine(kinds, topBarOn: topBarOn) {
            if ink.style.kind == .instrument {
                // Instrument's notice row (Home's): the eyebrow in the signal's text colour, the line, its fix.
                HStack(spacing: 14) {
                    InstrumentEyebrow(text: "Top bar", role: \.accentText)
                    Text(line).styleText(\.body).foregroundStyle(ink.text).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Show in the menu bar") {
                        withAnimation(reduceMotion ? nil : Kit.change) { store.settings.showInMenuBar(kinds) }
                    }
                    .buttonStyle(InstrumentButtonStyle())
                }
                .instrumentNotice()
                .transition(.opacity)
            } else {
                toyboxNotice(line, kinds: kinds, store: store)
            }
        }
    }

    /// Toybox's: the dropdown's problem row (the amber triangle, the words, the fix) on the amber.
    private func toyboxNotice(_ line: String, kinds: [BarKind], store: BarItemsStore) -> some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius)
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(ink.warnText).accessibilityHidden(true)
            Text(line).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Show in the menu bar") {
                withAnimation(reduceMotion ? nil : Kit.change) { store.settings.showInMenuBar(kinds) }
            }
            .buttonStyle(.pilotPrimary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(ink.yellow.opacity(0.1), in: shape)
        .transition(.opacity)
    }

    // MARK: Strip

    /// The menu bar strip's coordinate space, its whole row.
    static let menuSpace = "pilot.page.menu"
    /// The desk above each strip, where its pieces' − sit (StripPiece): inside the strip's hit area, so they take clicks,
    /// and wholly inside the desk (Sven on build 2372: they were cut at the bar's top edge). The top bar has as much
    /// each side, so the last item's − is inside too.
    static let room: CGFloat = 18

    /// The bars over a strip of desk, as design round 4's preview: Pilot's top bar as it draws (in its style, the Strip
    /// or the Menu), the macOS menu bar with Pilot's items on the right. Each takes the tray's and its own items' drops
    /// (Q185): the top bar's sides as BarDrop zones, the menu bar's row before the slot under the pointer.
    ///
    /// The top bar shows every item, whatever the window's width (Sven on build 2363: other apps' items and the extensions
    /// were missing unless Pilot was full screen): it lays out at least as wide as it needs with nothing going for room
    /// (StripRoom), and a page narrower than that scrolls it sideways. Scrolled, not scaled: a bar twice the page's width
    /// would draw its words at half size, too small to read or grab; wrapped, it would not be the bar. The macOS menu
    /// bar keeps the page's width and crowds as macOS does (menuStrip).
    @ViewBuilder private func preview(_ store: BarItemsStore) -> some View {
        let preview = store.settings.preview(placement)
        let radius = ink.corner(10, \.control)
        VStack(spacing: 0) {
            if let top = preview.top {
                ScrollView(.horizontal) {
                    // The drop, its marks and the strip's frames all sit inside the scrolled bar, so they share its places.
                    StripRoom {
                        // The page's width, the least the bar takes.
                        Color.clear.frame(height: 0).containerRelativeFrame(.horizontal)
                        topStrip(top, store: store)
                    }
                }
                .scrollIndicators(.visible)
                // A wheel or a trackpad's up and down over the bar moves it sideways (Sven on build 2372); elsewhere they
                // scroll the page.
                .background(SidewaysWheel())
            }
            if let menu = preview.menu { menuStrip(menu, store: store) }
            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity)
        // A strip of the theme's desk under the bars; Instrument's sunk well.
        .background(Desk(ink: ink))
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(ink.line) }
    }

    /// Pilot's top bar as it draws, a drop on it landing as BarDrop says: the zones, the side's name and the caret show
    /// while a drag is over it.
    private func topStrip(_ top: [TopBarSide: [BarSlot]], store: BarItemsStore) -> some View {
        let drop = topDrop(top), background = store.background.shown(transparency: Look.shared.transparency)
        let joining = overTop.map { drop.joinsGroup(x: $0.x, y: $0.y, dragging: dragged) } ?? false
        return TopBarStrip(sides: top, configuration: store.settings.preset, background: background, colour: store.colour, glassPreview: true, itemColours: store.itemColours,
                           report: { side, index, rect in if topFrames[side]?[index] != rect { topFrames[side, default: [:]][index] = rect } }, preview: true) {
            stripSlot($0, store, inTopBar: true, joining: joining)
        }
        .frame(height: store.settings.preset?.height ?? 30)
        .background { if background == .glass, store.settings.preset?.preset.islands != true { BarGlassGround(colour: store.colour) } }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { topSize = $0 }
        // Over the Group the outline lights in place of the caret: the drop joins it.
        .overlay { if let overTop, !joining { BarDropMarks(drop: drop, target: drop.target(x: overTop.x, y: overTop.y, dragging: dragged)) } }
        .padding(.top, Self.room)
        // The whole strip takes the drop, its clear gaps too (a Glass bar draws no ground of its own).
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], delegate: Self.topDrop(drop, store: store, placement: placement, dragged: dragged, room: Self.room,
                                                         animation: reduceMotion ? nil : Kit.change,
                                                         over: { overTop = $0.map { CGPoint(x: $0.x, y: $0.y - Self.room) } }, finish: { dragged = nil }))
        .padding(.horizontal, Self.room)
    }

    /// The top bar strip's drop: where BarDrop says, as BarSettings.drop places it; `room` is the desk above the bar.
    static func topDrop(_ drop: BarDrop, store: BarItemsStore, placement: BarPlacement, dragged: BarTrayItem?, room: CGFloat = 0,
                        animation: Animation?, over: @escaping (CGPoint?) -> Void, finish: @escaping () -> Void) -> TrayItemDrop<BarStripDrop> {
        TrayItemDrop(dragged: dragged, animation: animation, over: over, finish: finish) { item, at in
            if drop.joinsGroup(x: at.x, y: at.y - room, dragging: item) { return .group }
            return drop.target(x: at.x, y: at.y - room, dragging: item).map { BarStripDrop.top($0.side, index: $0.index) }
        } apply: { [store, placement] item, target in store.settings.drop(item, on: target, placement: placement) }
    }

    /// The menu bar strip's drop: before the slot under the pointer; never an item of the top bar alone.
    static func menuDrop(_ slots: [BarDrop.Slot], store: BarItemsStore, placement: BarPlacement, dragged: BarTrayItem?, animation: Animation?,
                         over: @escaping (CGPoint?) -> Void, finish: @escaping () -> Void) -> TrayItemDrop<BarStripDrop> {
        TrayItemDrop(dragged: dragged, animation: animation, over: over, finish: finish) { item, at in
            if item.topBarOnly { return nil }
            if BarDrop.joinsGroup(x: at.x, slots: slots, dragging: item) { return .group }
            return .menu(index: BarDrop.menuTarget(x: at.x, slots: slots, dragging: item).index)
        } apply: { [store, placement] item, target in store.settings.drop(item, on: target, placement: placement) }
    }

    /// The top bar's slots as the strip drew them, as BarDrop takes them.
    private func topDrop(_ top: [TopBarSide: [BarSlot]]) -> BarDrop {
        let sides = TopBarSide.allCases.map { side in
            (side, (top[side] ?? []).enumerated().map { i, slot in
                let rect = topFrames[side]?[i].flatMap { $0.width > 0 && $0.maxX > 0 ? $0 : nil } ?? .zero
                return BarDrop.Slot(item: slot.item, minX: rect.minX, maxX: rect.maxX)
            })
        }
        return BarDrop(sides: Dictionary(uniqueKeysWithValues: sides), width: topSize.width, height: topSize.height)
    }

    /// The macOS menu bar: Pilot's items on the right, beside the system's own; with Both, only what stays there. Short of
    /// room (at 760), Finder goes first (the items are what this page drags), then the leftmost items whole, as on Stats'
    /// strip and a crowded menu bar; the strip is never wider than the page. Extensions' own items sit before Pilot's.
    private func menuStrip(_ menu: [BarSlot], store: BarItemsStore) -> some View {
        let extensions = extensionBar.items.filter { store.settings.shows(extension: $0.id, in: .menuBar, topBarOn: placement == .both) }
        let slots = menuSlots(menu)
        let joining = overMenu.map { BarDrop.joinsGroup(x: $0, slots: slots, dragging: dragged) } ?? false
        return HStack(spacing: 13) {
            Image(systemName: "apple.logo")
            ViewThatFits(in: .horizontal) { Text("Finder").fontWeight(.bold).fixedSize(); Color.clear.frame(width: 0) }
                .layoutPriority(-1)
            Spacer(minLength: 12).layoutPriority(-2)
            TrailingRow(spacing: 13) {
                ForEach(extensions) { item in extensionPiece(item, store: store, inTopBar: false) }
                ForEach(Array(menu.enumerated()), id: \.offset) { i, slot in
                    stripSlot(slot, store, inTopBar: false, joining: joining)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.menuSpace)) } action: { menuFrames[i] = $0 }
                }
            }
            .font(ink.ui(12, .medium))
            // The ones that go sit past the row's leading edge: drawn and dragged nowhere. The cut reaches up over the
            // pieces' − (StripPiece) and past the last one's, so only the leading side cuts.
            .padding(.top, 16).padding(.trailing, 14).clipped().contentShape(Rectangle()).padding(.top, -16).padding(.trailing, -14)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.menuSpace)) } action: { menuRow = $0 }
            Image(systemName: "wifi").opacity(0.85)
            // macOS's clock, unless Pilot's clock item is in the bar: one clock, as on Stats.
            if Self.showsMacClock(menu) { Text(Date.now.formatted(.dateTime.weekday().day().month().hour().minute())).fixedSize() }
        }
        .font(ink.ui(13))
        .padding(.horizontal, 14).frame(height: 28)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        // The bar's shade follows the style's dark; Instrument's raised fill.
        .background(ink.style.kind == .instrument ? ink.selected : ink.style.dark ? Color.black.opacity(0.42) : Color.white.opacity(0.45))
        .coordinateSpace(.named(Self.menuSpace))
        .overlay {
            if let overMenu, !joining {
                GeometryReader { BarCaret(x: BarDrop.menuTarget(x: overMenu, slots: slots, dragging: dragged).caret, height: $0.size.height) }
            }
        }
        .padding(.top, Self.room)
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], delegate: Self.menuDrop(slots, store: store, placement: placement, dragged: dragged,
                                                          animation: reduceMotion ? nil : Kit.change, over: { overMenu = $0?.x }, finish: { dragged = nil }))
    }

    /// The menu bar's slots as the strip drew them; one gone for room (left of the row) has no width.
    private func menuSlots(_ menu: [BarSlot]) -> [BarDrop.Slot] {
        menu.enumerated().map { i, slot in
            let rect = menuFrames[i].flatMap { $0.width > 0 && $0.minX >= menuRow.minX - 1 ? $0 : nil } ?? .zero
            return BarDrop.Slot(item: slot.item, minX: rect.minX, maxX: rect.maxX)
        }
    }

    /// Whether the strip draws macOS's clock: only while Pilot's own clock item is not among `slots`, so it shows once.
    static func showsMacClock(_ slots: [BarSlot]) -> Bool { !slots.contains { $0.kinds.contains(.clock) } }

    /// One slot of a strip, piece by piece (Sven on build 54: one by one, not by sections): an item is one piece; the
    /// Group's readings are a piece each inside its outline, the outline itself dragging the whole Group; an extension's
    /// item placed in the top bar is a slot and a piece of its own (spec pilot-1.1 T50), drawn while it is installed.
    @ViewBuilder private func stripSlot(_ slot: BarSlot, _ store: BarItemsStore, inTopBar: Bool, joining: Bool) -> some View {
        if slot.isGroup {
            groupSlot(slot, store, inTopBar: inTopBar, joining: joining)
        } else if case .extension(let id) = slot.item {
            if let item = extensionBar.items.first(where: { $0.id == id }) { extensionPiece(item, store: store, inTopBar: true) }
        } else {
            piece(.item(slot.entries[0]), store, inTopBar: inTopBar)
        }
    }

    /// An item as the bar draws it, one piece, dragged and taken off as its own item: each divider is its own. In the
    /// Group it has no place of its own to step to: its menu takes it out of the Group, or splits the Group.
    private func piece(_ slot: BarSlot, _ store: BarItemsStore, inTopBar: Bool, inGroup: Bool = false) -> some View {
        let kind = slot.kind, item = slot.item, screen = engine.topBar.connected.first?.name ?? ""
        let grouped = inGroup ? [StripAction(title: "Take out of the Group", run: ungroup(item, store)), StripAction(title: "Ungroup", run: ungroup(nil, store))] : []
        return StripPiece(item: item, title: kind.title, pinned: kind.pinned, dragged: $dragged,
                          remove: takeOff(item, store), step: inGroup ? nil : step(item, store, inTopBar: inTopBar), actions: grouped) {
            BarDragChip(kind: kind, slot: slot, screen: screen, sources: engine.barSources, store: store)
        } content: {
            TopBarSlotView(slot: slot, screen: screen, sources: engine.barSources, store: store).environment(\.barPreview, true)
        }
        .onPage(ink.style)
    }

    /// The Group: its items a piece each, inside a hairline outline whose gaps and edge drag the whole Group; the outline
    /// lights while a drop would join it (`joining`).
    private func groupSlot(_ slot: BarSlot, _ store: BarItemsStore, inTopBar: Bool, joining: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: ink.corner(ink.radius(6), \.chip), style: .continuous)
        let group = BarTrayItem.kind(.group)
        return HStack(spacing: 10) {
            // By item: several extensions' items share one kind.
            ForEach(slot.entries, id: \.item) { entry in piece(.item(entry), store, inTopBar: inTopBar, inGroup: true) }
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background {
            shape.fill(joining ? ink.accent.opacity(0.14) : .clear)
                .overlay { shape.strokeBorder(joining ? ink.accent : ink.line2, style: StrokeStyle(lineWidth: joining ? 1.5 : 1, dash: [3, 2])) }
                .contentShape(shape)
                .help("The Group: drag its edge to move it whole, drop an item on it to group it, or drag one out")
                .onDrag {
                    dragged = group
                    return NSItemProvider(object: group.rawValue as NSString)
                } preview: {
                    BarDragChip(kind: .group, slot: slot, screen: engine.topBar.connected.first?.name ?? "", sources: engine.barSources, store: store)
                }
                .contextMenu {
                    Button("Ungroup", action: ungroup(nil, store))
                    Button("Take the Group off the bar", action: takeOff(group, store))
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Group")
        .accessibilityAction(named: "Ungroup", ungroup(nil, store))
        .accessibilityAction(named: "Take the Group off the bar", takeOff(group, store))
    }

    /// Takes `kind` out of the Group, or every item (Ungroup).
    private func ungroup(_ item: BarTrayItem?, _ store: BarItemsStore) -> () -> Void {
        { [reduceMotion] in withAnimation(reduceMotion ? nil : Kit.change) { store.settings.ungroup(item) } }
    }

    /// An extension's own item, its emoji and its answer, a piece of its own in either strip.
    private func extensionPiece(_ item: ExtensionBar.Item, store: BarItemsStore, inTopBar: Bool) -> some View {
        let tray = BarTrayItem.extension(item.id)
        // Move left and right along the top bar, as a built-in item's; the macOS menu bar orders its own items.
        return StripPiece(item: tray, title: item.title, pinned: false, dragged: $dragged, remove: takeOff(tray, store),
                          step: inTopBar ? step(tray, store, inTopBar: true) : nil) {
            BarDragChip(kind: .extensions, slot: nil, screen: "", sources: engine.barSources, store: store, extensionItem: (item.icon ?? "🧩", item.title))
        } content: {
            ExtensionStripFace(item: item).fixedSize().padding(.horizontal, inTopBar ? 4 : 0)
        }
        .onPage(ink.style)
    }

    private func takeOff(_ item: BarTrayItem, _ store: BarItemsStore) -> () -> Void {
        { [placement, reduceMotion] in withAnimation(reduceMotion ? nil : Kit.change) { _ = store.settings.takeOff(item, placement: placement) } }
    }

    private func step(_ item: BarTrayItem, _ store: BarItemsStore, inTopBar: Bool) -> (Int) -> Void {
        { [placement, reduceMotion] by in
            withAnimation(reduceMotion ? nil : Kit.change) { store.settings.step(item, by: by, inTopBar: inTopBar, topBarOn: placement == .both) }
        }
    }

    // MARK: Items

    private func groupTile(_ group: BarGroup, store: BarItemsStore) -> some View {
        let kinds = BarKind.allCases.filter { $0.group == group }
        return Tile(title: group.title) {
            Text("\(kinds.count)").font(ink.mono(11)).foregroundStyle(ink.muted)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(kinds.enumerated()), id: \.element) { i, kind in
                    if i > 0 { ink.line.opacity(0.7).frame(height: 1) }
                    itemRow(kind, store: store)
                    if kind == .otherApps { exactItemsRow(store) }
                    if kind == .bluetoothBatteries { lowBatteryRow }
                    // Each extension's own item under the Extensions item (Surfaces v2), placed as any item is.
                    if kind == .extensions {
                        ForEach(extensionBar.items) { item in
                            ink.line.opacity(0.7).frame(height: 1)
                            extensionRow(item, store: store)
                        }
                    }
                }
            }
            // Fills the row's height, so the tiles beside it end level.
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// An item, design round 4's row: its symbol on a squircle, name and styles, and its switch.
    private func itemRow(_ kind: BarKind, store: BarItemsStore) -> some View {
        let entry = store.settings.entry(kind), on = store.settings.isOn(kind, in: placement)
        let locked = kind.pinned || (kind.topBarOnly && placement != .topBar)
        return HStack(spacing: 10) {
            // Each group's tiles in its own module colour.
            Squircle(symbol: kind.symbol, colour: ink.module(BarGroup.allCases.firstIndex(of: kind.group) ?? 0), big: false)
            VStack(alignment: .leading, spacing: 3) {
                itemName(kind)
                if kind.styles.count > 1 {
                    Flow(spacing: 3, lineSpacing: 3) {
                        ForEach(kind.styles, id: \.self) { style in
                            StyleChip(title: style.title, on: on && entry.style == style) { store.settings.set(kind, style: style) }
                        }
                    }
                    .padding(.leading, -5)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(kind.title) style")
                }
                if kind == .spacer, on { spacerWidth(entry, store: store) }
            }
            Spacer(minLength: 6)
            Toggle(kind.title, isOn: Binding(get: { on }, set: { _ in store.settings.toggle(kind, in: placement) }))
                .toggleStyle(.pilotSwitch)
                .disabled(locked)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }

    /// The spacer's own width (Sven on build 21: free spacing), what dragging its edge on the bar did before Q185: saved
    /// once, when the slider is let go; Reset gives back its style's.
    private func spacerWidth(_ entry: BarEntry, store: BarItemsStore) -> some View {
        HStack(spacing: 8) {
            Text("Width").font(ink.ui(10.5)).foregroundStyle(ink.muted)
            Slider(value: Binding(get: { BarSpacer.width(store.settings.entry(.spacer)) }, set: { store.settings.setSpacer(width: $0) }),
                   in: BarSpacer.widths) { editing in if editing { store.hold() } else { store.release() } }
                .controlSize(.mini).frame(maxWidth: 160)
                .accessibilityLabel("Spacer width")
                .accessibilityValue("\(Int(BarSpacer.width(entry))) points")
            Text("\(Int(BarSpacer.width(entry))) pt").font(ink.mono(10.5)).foregroundStyle(ink.muted).monospacedDigit().fixedSize()
            if entry.width != nil {
                Button("Reset") { store.settings.setSpacer(width: nil) }.buttonStyle(.link).font(ink.ui(10.5))
            }
        }
    }

    /// Other apps' Show exact menu bar items (ADR 0012): off by default; turning it on asks Screen Recording, which
    /// nothing else in Pilot asks. While it lacks the grant the drawer keeps its glyphs and the row says where to allow it.
    private func exactItemsRow(_ store: BarItemsStore) -> some View {
        let pictures = engine.barSources.readings.menuApps.pictures
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Show exact menu bar items", isOn: Binding(get: { store.settings.exactMenuItems }, set: { on in
                store.settings.exactMenuItems = on
                pictures.toggled()
            }))
            .toggleStyle(.pilotSwitchRow(info: "Off, the drawer shows a plain glyph for each app's item."))
            .font(ink.ui(12, .medium))
            FinePrint(text: "The drawer shows each app's items as macOS draws them. Needs Screen Recording, for this alone.")
            if engine.barSources.readings.menuApps.opensInPlace {
                FinePrint(text: "On macOS 27.2 an app's menu opens at its own spot in the menu bar, not under the drawer.")
            }
            if store.settings.exactMenuItems, pictures.lacksPermission {
                Button("Allow Screen Recording…") { PermissionDragPanel.openScreenRecording() }
                    .buttonStyle(.link).font(ink.ui(12))
            }
        }
        .padding(.leading, 38)
        .padding(.bottom, 6)
    }

    /// Low-battery alerts (Q394), on by default, whether or not the item shows.
    private var lowBatteryRow: some View {
        @Bindable var alerts = LowBatteryAlerts.shared
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Low-battery alerts", isOn: $alerts.isOn)
                .toggleStyle(.pilotSwitchRow(info: "Earbuds and headphones alert only while this item or Stats shows them: macOS reads their batteries slowly."))
                .font(ink.ui(12, .medium))
            FinePrint(text: "A keyboard, mouse or trackpad at 20 % and again at 10 % shows a tip and a notification, once each.")
        }
        .padding(.leading, 38)
        .padding(.bottom, 6)
    }

    /// An extension's bar item: its emoji and title, in the macOS menu bar by default; + or the switch places it as a
    /// built-in item's does, and asks it at once.
    private func extensionRow(_ item: ExtensionBar.Item, store: BarItemsStore) -> some View {
        let on = store.settings.isOn(extension: item.id, in: placement)
        let toggle = {
            store.settings.toggle(extension: item.id, in: placement)
            extensionBar.nudge()
        }
        return HStack(spacing: 10) {
            Text(item.icon ?? "🧩").font(ink.ui(13)).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(ink.ui(12.5, .medium)).fixedSize(horizontal: false, vertical: true)
                Text(item.problem ?? item.answer.map { $0.text.isEmpty ? "extension" : $0.text } ?? "extension")
                    .font(ink.ui(10.5)).foregroundStyle(ink.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            Toggle(item.title, isOn: Binding(get: { on }, set: { _ in toggle() })).toggleStyle(.pilotSwitch)
        }
        .padding(.leading, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }

    /// An item's name, whole: "top bar only" beside it while the row has room for both, on its own line under it when not;
    /// a name too long for its row wraps, never cut.
    @ViewBuilder private func itemName(_ kind: BarKind) -> some View {
        let name = Text(kind.title).font(ink.ui(12.5, .medium)).fixedSize(horizontal: false, vertical: true)
        if kind.topBarOnly {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { name; Text("· top bar only").font(ink.ui(10.5)).foregroundStyle(ink.muted) }
                VStack(alignment: .leading, spacing: 1) { name; Text("top bar only").font(ink.ui(10.5)).foregroundStyle(ink.muted) }
            }
        } else {
            name
        }
    }

    // MARK: Clear all

    /// Clear all and Restore defaults (Sven, Q411), each asked first in the Binds page's Reset all style, for the bar
    /// the page shows (Menu bar, Top bar or Both): Clear all takes every item off it, the extensions' too; Restore
    /// defaults is its way back.
    private func resets(_ store: BarItemsStore) -> some View {
        let ids = extensionBar.items.map(\.id)
        // Beside the bar switch, where Sven looks for it (2026-10-22), its ⓘ saying what each does.
        // The ⓘ leads, as the placement switch's does, so the two never sit side by side.
        return HStack(spacing: 8) {
            InfoMark(text: BarReset.info(placement))
            Button("Restore defaults…") { asking = .restore }.buttonStyle(.pilot)
            Button("Clear all…") { asking = .clear }.buttonStyle(.pilotDestructive).disabled(store.settings.isClear(in: placement, extensions: ids))
        }
        .padding(.trailing, 8)
        .confirmationDialog(asking?.question(placement) ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            presenting: asking) { reset in
            Button(reset.button, role: .destructive) {
                withAnimation(reduceMotion ? nil : Kit.change) {
                    switch reset {
                    case .clear: store.settings.clearAll(in: placement, extensions: ids)
                    case .restore: store.settings.restoreDefaultItems(in: placement)
                    }
                }
                extensionBar.nudge()
            }
        } message: { Text($0.message(placement)) }
    }

    // MARK: Clock

    private func clock(_ store: BarItemsStore) -> some View {
        @Bindable var store = store
        let typed = pattern ?? store.settings.clock.rawValue
        // The page's settings grid (Wallpaper, Clipboard): label and ⓘ on the left, the control on the right.
        return Tile(title: "Clock", symbol: "clock") {
            BlockRow(first: true) {
                label("Style", "What the clock item shows: the time, the date before it, or the time here and in a second zone.")
                // The clock item's style, as `pilot bar style clock` and `bar.clockStyle` set it (P45).
                Picker("Style", selection: Binding(get: { store.settings.entry(.clock).style }, set: { store.settings.set(.clock, style: $0) })) {
                    ForEach(BarKind.clock.styles, id: \.self) { Text($0.menuTitle).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            BlockRow {
                label("Time", "How the clock item writes the time; a pattern typed below shows here as Your own.")
                Picker("Time", selection: $store.settings.clock) {
                    ForEach(TopBarClockFormat.presets, id: \.format) { Text($0.title).tag($0.format) }
                    if !TopBarClockFormat.presets.contains(where: { $0.format == store.settings.clock }) {
                        Text("Your own").tag(store.settings.clock)
                    }
                }
                .labelsHidden().fixedSize()
            }
            // The pattern is the time alone: the style adds the date or the second zone around it, so the row says so
            // and the line under it shows the whole clock (Sven on build 74: Date + time beside "HH:mm").
            BlockRow {
                label("Time pattern", "A date pattern, as macOS takes it, applied on Return: HH hours, mm minutes, ss seconds, h:mm a for 12 h. The style adds the date or the second zone around it.")
                TextField("Time pattern", text: Binding(get: { typed }, set: { pattern = $0 }))
                    .labelsHidden().font(ink.mono(12)).pilotField().frame(width: 160)
                    .onSubmit {
                        if let pattern, !pattern.isEmpty { store.settings.clock = TopBarClockFormat(rawValue: pattern) }
                        pattern = nil
                    }
            }
            BlockRow {
                Text("The bar shows").frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.clockPreview(store.settings, pattern: TopBarClockFormat(rawValue: typed), now: .now))
                    .foregroundStyle(ink.text2).monospacedDigit().lineLimit(1)
            }
        }
    }

    /// A setting's name and its ⓘ, taking the row's room so the control sits at its right end.
    private func label(_ title: String, _ info: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            InfoMark(text: info)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The clock item's text as the bars draw it in its style, with `pattern` for the time: "Sun 18 Oct  13:27".
    static func clockPreview(_ settings: BarSettings, pattern: TopBarClockFormat, now: Date) -> String {
        var inputs = BarInputs()
        inputs.now = now
        return BarParts.text(BarParts.parts(settings.entry(.clock), inputs, clock: pattern, zone: settings.clockZone) ?? [])
    }
}

/// A Glass top bar's ground on the page, as the bar's window paints it (TopBarWindows.applyLook): glass in its ink's
/// light or dark, tinted with the bar's colour at Look's Transparency. The strip itself draws no ground on Glass, so
/// without this a colour's ink (dark, on Sven's near-white) sat faint on the page's dark desk (Sven on build 58).
struct BarGlassGround: View {
    @Environment(\.style) private var style
    let colour: ColourChoice

    var body: some View {
        Rectangle().fill(.bar)
            .overlay(Color(nsColor: TopBarColour.tint(colour, style: style, look: .shared)))
            .environment(\.colorScheme, TopBarColour.tokens(colour, style: style).dark ? .dark : .light)
    }
}

/// An extension's own item on the page's strip, as the bar draws it (Sven on build 55: Ghostex and To-do showed twice):
/// its face alone, since an extension's answer leads with its own emoji ("👻 5"); its emoji alone while it has nothing
/// to show, so it can still be dragged.
struct ExtensionStripFace: View {
    enum Shows: Equatable { case face(ExtensionBarFace), icon(String) }

    let item: ExtensionBar.Item

    static func shows(_ item: ExtensionBar.Item) -> Shows { item.face.map(Shows.face) ?? .icon(item.icon ?? "🧩") }

    var body: some View {
        switch Self.shows(item) {
        case .face(let face): BarPartsView(items: [[.extensionItem(face)]])
        case .icon(let icon): Text(icon)
        }
    }
}

/// One of an item's styles, design round 4's: small words, the picked one raised with a hairline while the item is on.
private struct StyleChip: View {
    @Environment(\.ink) private var ink
    let title: String
    let on: Bool
    let pick: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.corner(ink.radius(3), \.chip))
        Button(action: pick) {
            Text(title).font(ink.ui(10.5)).lineLimit(1)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .foregroundStyle(on ? ink.text : ink.muted)
                .background(on ? ink.selected : .clear, in: shape)
                .overlay { if on { shape.strokeBorder(ink.line2) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension BarPlacement {
    var title: String {
        switch self {
        case .menuBar: "Menu bar"
        case .topBar: "Top bar"
        case .both: "Both"
        }
    }
}

extension BarKind {
    /// The item's symbol on the page.
    var symbol: String {
        switch self {
        case .pilot: PilotMarkShape.symbol
        case .workspaces: "square.grid.2x2"
        case .focusedApp: "macwindow"
        case .otherApps: "ellipsis.circle"
        case .appMenus: "filemenu.and.selection"
        case .cpu: "cpu"
        case .memory: "square.stack.3d.up"
        case .network: "network"
        case .graphics: "display"
        case .storage: "cylinder"
        case .heat: "thermometer.medium"
        case .battery: "battery.75"
        case .bluetoothBatteries: "headphones"
        case .keepAwake: "cup.and.saucer"
        case .power: "power"
        case .volume: "speaker.wave.2"
        case .keyboardLayout: "keyboard"
        case .wifi: "wifi"
        case .displays: "display"
        case .terminal, .askAI, .pill: BarParts.dropSymbol(self)
        case .capture: BarParts.captureSymbol
        case .modes: BarParts.statusSymbol
        case .clock: "clock"
        case .timer: "timer"
        case .extensions: "puzzlepiece.extension"
        case .spacer: "arrow.left.and.right"
        case .divider: "line.diagonal"
        case .group: "rectangle.3.group"
        }
    }
}

/// The top bar's preview at the width the page gives it, or wider when the bar needs more with nothing going for room (Sven
/// on build 2363): a ScrollView proposes no width, so this takes the page's width from its first view (sized to the
/// scroll view) and the bar's own from the second (TopBarRow's natural width), and lays the bar out at the wider of the two.
private struct StripRoom: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let bars = subviews[1].sizeThatFits(ProposedViewSize(width: nil, height: proposal.height))
        return CGSize(width: max(subviews[0].sizeThatFits(.unspecified).width, bars.width), height: bars.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: 0))
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// A strip of the theme's desk, under the preview's bars and the style thumbnails' bars; Instrument's sunk well, since its
/// colours are the theme's roles and its one signal is not decoration.
private struct Desk: View {
    let ink: Ink

    var body: some View {
        if ink.style.kind == .instrument {
            ink.style.color(\.sunken)
        } else {
            LinearGradient(colors: [ink.accent.opacity(0.22), ink.tag(1).opacity(0.12), ink.background],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// The Menu bar page's two resets, each asked first.
private enum BarReset {
    case clear, restore

    /// The bar `placement` names in a sentence.
    static func bars(_ placement: BarPlacement) -> String {
        switch placement {
        case .menuBar: "the macOS menu bar"
        case .topBar: "Pilot's top bar"
        case .both: "Pilot's top bar and the macOS menu bar"
        }
    }

    /// The ⓘ beside the two buttons: what each does to the bar the page shows.
    static func info(_ placement: BarPlacement) -> String {
        "For the bar picked beside: Clear all takes every item off \(bars(placement)), the extensions' too; Pilot's own icon stays. Restore defaults brings back the default items there."
    }

    func question(_ placement: BarPlacement) -> String {
        let bar = placement == .both ? "both bars" : placement == .menuBar ? "the menu bar" : "the top bar"
        return self == .clear ? "Clear every item from \(bar)?" : "Restore the default items in \(bar)?"
    }
    var button: String { self == .clear ? "Clear all" : "Restore defaults" }
    func message(_ placement: BarPlacement) -> String {
        let other = placement == .both ? "" : placement == .menuBar ? " Items also in the top bar stay there." : " Items also in the menu bar stay there."
        return self == .clear
            ? "Every item leaves \(Self.bars(placement)), the extensions' too.\(other) Pilot's own icon stays: it is how you reach Pilot. Restore defaults brings the default items back."
            : placement == .both
                ? "The items, their order and their places go back to Pilot's defaults. The clock's pattern and the bar's colour stay."
                : "Pilot's default items come back to \(Self.bars(placement)).\(other) The clock's pattern and the bar's colour stay."
    }
}

/// Geometry uses the same setter as pilot bar, never replaces personal items.
struct BarPresetControls: View {
    let store: BarItemsStore
    @State private var problem = ""
    var body: some View {
        Tile(title: "Bar layout", symbol: "menubar.rectangle") {
            Picker("Preset", selection: Binding(get: { store.settings.preset?.preset.rawValue ?? "legacy" }, set: { value in
                do { try store.choosePreset(value); problem = "" } catch { problem = String(describing: error) }
            })) {
                Text("Full bar").tag("legacy")
                ForEach(BarPreset.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            if let config = store.settings.preset {
                // The sizes behind one fold, closed until opened (Sven, 2026-11-12): the preset's defaults are the bar.
                KitFold(title: "Adjust sizes") {
                    // Each row reads the preset again, never with `!`: picking Full bar clears it, and a row can redraw
                    // before this branch goes (build 2276 trapped there).
                    ForEach(BarItemsStore.geometryFields, id: \.0) { field in
                        Stepper(field.1 + " · " + String(format: field.0 == "border" ? "%.1f pt" : "%.0f pt", (store.settings.preset ?? config)[keyPath: field.2]), value: Binding(get: {
                            store.settings.preset?[keyPath: field.2] ?? 0
                        }, set: { value in
                            do { try store.setGeometry(field.0, value: value); problem = "" } catch { problem = String(describing: error) }
                        }), in: BarPresetConfiguration.ranges[field.0]!, step: field.0 == "border" ? 0.5 : 1)
                    }
                    Button("Reset sizes") {
                        do { try store.choosePreset(config.preset.rawValue); problem = "" } catch { problem = String(describing: error) }
                    }.buttonStyle(.pilot)
                }
            }
            Text("Items and their order stay personal. Pack defaults and Restore are reviewed in Look.")
            if !problem.isEmpty { Text(problem).foregroundStyle(.red) }
        }
        .disabled(Look.shared.themePressing)  // A theme owns the layout: it waits while Look's Apply or Restore runs.
    }
}

