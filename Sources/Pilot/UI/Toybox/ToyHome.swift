import Clipboard
import PilotCore
import SwiftUI

/// Home in Toybox (card agent-bo-95423182, mockup B: home-dark.png, home-light.png, src/home.html), on Home's grid
/// (HomeNowPage; P91): the greeting with the Pilot mark where Capsy was, and the blocks, Large in Toybox's own forms: the
/// Pilot card (the one thing that needs you, else All clear with the menu's keys), the Hyper keyboard (Binds' Toybox
/// board), the workspaces with the one you are on in sun yellow, today's most pressed binds as bars in their module
/// colours, the newest copies and This Mac's four meters.
/// Quick actions are not in the mockup's Home, so Toybox leaves them to the menu.
struct ToyHome: View {
    let parts: HomeParts

    var body: some View {
        HomeNowPage(parts: parts, side: 26) {
            EmptyView()
        } own: { id, size in
            own(id, width: size.width)
        }
    }

    /// A block in Toybox's own form, at its cells' width (today's Large, and the Pilot card).
    @ViewBuilder private func own(_ id: String, width: CGFloat) -> some View {
        switch HomeLayout.Block(rawValue: id) {
        case .pilot: ToyPilotCard(parts: parts, row: width > 600)
        // Whole at every width, its names shrunk (split, its halves stacked would outgrow its cells); its keys keep their
        // height, so the board sits in the middle of its cells.
        case .keyboard: ToyHyperKeyboard(parts: parts, whole: true).frame(maxHeight: .infinity)
        case .workspaces: ToyWorkspaces(columns: width < 640 ? 2 : 4).frame(height: width < 640 ? 440 : 296)
        case .mostUsed: ToyMostPressed(parts: parts, spread: false)
        case .clipboard: ToyClipboard(parts: parts)
        case .thisMac: ToyThisMac(parts: parts)
        case .greeting, .quickActions, nil: EmptyView()
        }
    }

    // MARK: What Home works out

    /// The first `count` workspaces, the focused one always among them (in the last place when it is further on).
    static func shown(_ cells: [OccupiedWorkspace], focused: String?, count: Int = 4) -> [OccupiedWorkspace] {
        var shown = Array(cells.prefix(count))
        if let focused, !shown.contains(where: { $0.name == focused }), let cell = cells.first(where: { $0.name == focused }), !shown.isEmpty {
            shown[shown.count - 1] = cell
        }
        return shown
    }

    /// The slots Workspaces keeps while the tiler is stopped: the workspaces Hyper jumps to (numbers in order, then
    /// names), the first four, else 1 to 4.
    static func stoppedSlots(actions: [String]) -> [String] {
        let names = Set(actions.compactMap { $0.hasPrefix("workspaces.go:") ? String($0.dropFirst("workspaces.go:".count)) : nil })
        let ordered = names.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a < b
            }
        }
        return ordered.isEmpty ? ["1", "2", "3", "4"] : Array(ordered.prefix(4))
    }

    /// How many windows each column of a workspace's screen holds: one or two side by side, three as one beside two,
    /// four or more as two and two (the rest counted on the last).
    static func columns(_ windows: Int) -> [Int] {
        switch windows {
        case 0: []
        case 1: [1]
        case 2: [1, 1]
        case 3: [1, 2]
        default: [2, 2]
        }
    }

    /// The greeting's first word by the hour.
    static func greeting(_ hour: Int) -> String {
        switch hour {
        case 5..<12: "Morning"
        case 12..<18: "Afternoon"
        default: "Evening"
        }
    }

    /// A workspace's apps, longest first: every name, then the first two and how many more, then the first and the rest.
    static func appNames(_ apps: [String]) -> [String] {
        guard apps.count > 1 else { return apps }
        var names = [apps.joined(separator: ", ")]
        if apps.count > 2 { names.append(apps.prefix(2).joined(separator: ", ") + " +\(apps.count - 2)") }
        names.append(apps[0] + " +\(apps.count - 1)")
        return names
    }

    /// The words after the bind count in the hero's chip.
    static func bindsLine(binds: Int, clashes: Int) -> String {
        "\(binds == 1 ? "bind" : "binds"), \(clashes) \(clashes == 1 ? "clash" : "clashes")"
    }

    /// The line under a copy: the app it came from and when, a colour named as one; no app, its kind.
    static func clipLine(kind: ClipKind, app: String?, ago: String) -> String {
        ((kind == .colour || app == nil ? [kind.label] : []) + [app, ago].compactMap(\.self)).joined(separator: " · ")
    }

    /// A meter's bars: its last `count` readings as shares of `top`, an unread one 0.
    static func bars(_ values: [Double?], count: Int, top: Double) -> [Double] {
        values.suffix(count).map { (($0 ?? 0) / max(top, .ulpOfOne)).clamped01 }
    }
}

// MARK: - Pilot card

/// Pilot's own card beside the greeting: while something needs you, the one nudge
/// (`.nudge`) with the first thing, how many there are, what it costs and its fix, which holds Return as today's first
/// problem button does (one nudge, never a stack); else All clear, or Hyper is off, with the menu's keys.
private struct ToyPilotCard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let parts: HomeParts
    /// A row across the page (narrower windows): the words beside the tile, the button at the right while it fits.
    var row = false

    var body: some View {
        let header = HStack(alignment: .top, spacing: 14) { tile; words }
        Group {
            if row {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 14) { tile; words.fixedSize(); Spacer(minLength: 16); action }
                    VStack(alignment: .leading, spacing: 14) { header; action }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) { header; Spacer(minLength: 0); action }
            }
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .styleSurface(\.card)
        .accessibilityElement(children: .contain)
    }

    private var tile: some View {
        let problem = parts.problems.first, on = engine.hyperSwitch.isOn
        return ToySymbolCap(symbol: problem.map { Self.symbol($0.kind) } ?? (on ? "checkmark" : "power"),
                            fill: problem != nil ? \.problem : on ? \.good : \.sunken)
    }

    private var words: some View {
        let problems = parts.problems, problem = problems.first, on = engine.hyperSwitch.isOn
        return VStack(alignment: .leading, spacing: 0) {
            ToyEyebrow(text: problems.isEmpty ? "Pilot" : problems.count == 1 ? "One thing left" : "One of \(problems.count) things left")
            Text(problem?.title ?? PilotTile.headline(hyperOn: on, problems: 0))
                .font(style.toyFredoka(19)).foregroundStyle(style.color(\.text))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text(PilotTile.note(hyperOn: on, problems: problem.map { [$0] } ?? [], layerKey: engine.settings.layerKeys.label))
                .font(style.toyNunito(700, 13.5)).lineSpacing(2)
                .foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
        }
        .help(problem.map { $0.detail ?? $0.title } ?? "")
    }

    /// The first problem's fix, holding Return; with nothing to fix, the menu and its keys.
    @ViewBuilder private var action: some View {
        if let problem = parts.problems.first {
            if let fix = parts.fix(problem) {
                ReturnButton(title: fix.title, holdsReturn: parts.holdsReturn(0), style: PilotButtonStyle(primary: true), action: fix.run).fixedSize()
            }
        } else {
            HStack(spacing: 10) {
                Button { engine.action(AppsModule.menuID)?.run() } label: { Label("Pilot menu", systemImage: "command") }
                    .buttonStyle(.pilot).fixedSize()
                if let key = engine.binds.store.trigger(for: AppsModule.menuID) { ToyBind(key: key) }
            }
        }
    }

    static func symbol(_ kind: HomeProblems.Problem.Kind) -> String {
        switch kind {
        case .accessibility: "hand.raised.fill"
        case .tiler: "rectangle.split.3x1.fill"
        case .secureInput: "lock.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - Hyper keyboard

/// The Hyper keyboard: Binds' Toybox board in its case under a title line, each bound key with its bind's short name; a
/// click is `HomeParts.openKey`. Hyper off: the board rests, dimmed, with Turn on.
private struct ToyHyperKeyboard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let parts: HomeParts
    /// The board whole, its names shrunk, rather than split.
    var whole = false

    var body: some View {
        let binds = parts.binds, boards = KeyboardCaptions.current
        let off = !engine.hyperSwitch.isOn
        // No card around it: the board's own case is its surface, and a card's padding would split it into halves at 1440.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Hyper keyboard").styleText(\.title).foregroundStyle(style.color(\.text)).lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if off { Button("Turn on Hyper") { engine.hyperSwitch.set(true) }.buttonStyle(PilotButtonStyle(primary: true)).fixedSize() }
                ToyLink(title: "All binds") { parts.go(AppPlace(.binds)) }
            }
            .padding(.horizontal, 4)
            ToyBindsBoard(boards: boards, binds: binds, layerKeys: engine.settings.layerKeys, layer: .hyper, picked: nil, pick: parts.openKey, whole: whole)
            .opacity(off ? 0.38 : 1)
            .allowsHitTesting(!off)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Workspaces

/// The workspaces (`.ws`): each a screen of its windows' app icons laid out in columns, its number and apps under it; the
/// one you are on sun yellow with "You are here" over it. A click goes there, or sets an empty one up; right-click edits
/// it. The tiler stopped, the card says so.
private struct ToyWorkspaces: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    @Environment(\.editWorkspace) private var editWorkspace
    /// Tiles across: four, or two rows of two in one column.
    let columns: Int

    var body: some View {
        let tiler = engine.observers.tiler
        let focused = tiler.focused
        let shown = ToyHome.shown(tiler.homeCells, focused: focused)
        ToyCard(title: "Workspaces") {
            if focused == nil {
                // The nudge card above says why and holds the fix; this card only waits.
                Text("Waiting for \(tiler.tilerName)").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text3)).fixedSize()
            } else {
                hint(shown)
            }
        } content: {
            if focused == nil {
                stopped(ToyHome.stoppedSlots(actions: Array(engine.binds.store.binds.values)))
            } else {
                let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
                VStack(spacing: 26) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 14) {
                            ForEach(row, id: \.name) { workspace in
                                tile(workspace, here: workspace.name == focused, windows: tiler.windows.filter { $0.workspace == workspace.name })
                            }
                            ForEach(row.count..<columns, id: \.self) { _ in Color.clear }
                        }
                    }
                }
                .padding(.top, 6)
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// "Hyper 1 to 4 jumps there", from the first and last shown workspace's binds; nothing when either has none.
    @ViewBuilder private func hint(_ shown: [OccupiedWorkspace]) -> some View {
        let go = { (workspace: OccupiedWorkspace?) in workspace.flatMap { engine.binds.store.trigger(for: "workspaces.go:\($0.name)") } }
        if shown.count > 1, let first = go(shown.first), let last = go(shown.last) {
            HStack(spacing: 8) {
                ToyBind(key: first)
                Text("to")
                ToyKeycap(label: KeyNames.name(for: last.keyCode))
                Text("jumps there")
            }
            .font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2))
            .fixedSize()
        }
    }

    private func tile(_ workspace: OccupiedWorkspace, here: Bool, windows: [AeroWindow]) -> some View {
        let empty = workspace.apps.isEmpty
        let preset = engine.presets.contents.name(for: workspace.name)
        let apps = ToyHome.appNames(workspace.apps)
        let names = empty ? ["click to set it up"] : preset.map { preset in apps.map { "\(preset) · \($0)" } + apps } ?? apps
        return Button {
            if empty, let editWorkspace { editWorkspace(workspace.name) } else { engine.observers.tiler.go(workspace.name, from: "home") }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ToyScreen(windows: windows.filter { !$0.isFloating } + windows.filter(\.isFloating), here: here)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(workspace.name).font(style.toyFredoka(28)).fixedSize()
                        .foregroundStyle(here ? style.color(\.onAccent) : style.color(\.text))
                    ViewThatFits(in: .horizontal) {
                        ForEach(names, id: \.self) { Text($0).fixedSize() }
                        Text("")
                    }
                    .font(style.toyNunito(700, 13))
                    .foregroundStyle(here ? style.color(\.onAccent) : empty ? style.color(\.text3) : style.color(\.text2))
                }
                .lineLimit(1).padding(.horizontal, 2)
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 17, trailing: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Toy.block(style, fill: here ? style.color(\.accent) : style.color(\.sunken), radius: 18, edge: 5))
            .overlay(alignment: .top) {
                if here {
                    Text("You are here").font(style.toyNunito(900, 11)).tracking(0.88).textCase(.uppercase)
                        .foregroundStyle(style.color(\.accent)).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(style.color(\.outline), in: .capsule)
                        .offset(y: -13)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .editsWorkspace(workspace.name)
        .help(empty ? "Set workspace \(workspace.name) up" : "Go to workspace \(workspace.name)")
        .accessibilityLabel(empty ? "Workspace \(workspace.name), empty: set it up"
                            : "Workspace \(workspace.name)\(preset.map { " “\($0)”" } ?? ""): \(workspace.apps.joined(separator: ", "))")
        .accessibilityAddTraits(here ? .isSelected : [])
    }

    /// The tiler stopped: its workspaces' slots, empty and flat (nothing to go to), each numbered, in the same grid.
    private func stopped(_ names: [String]) -> some View {
        let rows = stride(from: 0, to: names.count, by: columns).map { Array(names[$0..<min($0 + columns, names.count)]) }
        return VStack(spacing: 26) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(row, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 10) {
                            ToyScreen(windows: [], here: false)
                            Text(name).font(style.toyFredoka(28)).foregroundStyle(style.color(\.text3)).lineLimit(1).padding(.horizontal, 2)
                        }
                        .padding(EdgeInsets(top: 12, leading: 12, bottom: 17, trailing: 12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Toy.block(style, fill: style.color(\.sunken), radius: 18, edge: 2))
                        .opacity(0.7)
                    }
                    ForEach(row.count..<columns, id: \.self) { _ in Color.clear }
                }
            }
        }
        .padding(.top, 6)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspaces \(names.joined(separator: ", ")), waiting for the tiler")
    }
}

/// A workspace's screen (`.screen`): its windows as little windows in columns, each its app's icon; the first column the
/// wider, as a main window is; an empty one dashed.
private struct ToyScreen: View {
    @Environment(\.style) private var style
    let windows: [AeroWindow]
    let here: Bool

    var body: some View {
        let columns = ToyHome.columns(windows.count)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        GeometryReader { g in
            let inner = g.size.width - 12 - 5 * CGFloat(max(0, columns.count - 1))
            HStack(spacing: 5) {
                ForEach(Array(columns.enumerated()), id: \.offset) { c, count in
                    let start = columns.prefix(c).reduce(0, +)
                    VStack(spacing: 5) {
                        ForEach(0..<count, id: \.self) { r in
                            let i = start + r
                            let more = i == 3 && windows.count > 4 ? windows.count - 3 : 0
                            window(windows[i], more: more, small: count > 1)
                        }
                    }
                    .frame(width: columns.count == 2 && windows.count < 4 ? inner * (c == 0 ? 0.58 : 0.42) : inner / CGFloat(columns.count))
                }
            }
            .padding(6)
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity)
        .background(here ? style.color(\.accent).mix(with: .white, by: 0.3) : style.color(\.canvas), in: shape)
        .overlay {
            if windows.isEmpty {
                shape.strokeBorder(style.color(\.text3), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                Text("empty").font(style.toyNunito(700, 12.5)).foregroundStyle(style.color(\.text3))
            } else {
                shape.strokeBorder(style.color(\.outline), lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }

    /// One window (`.win`): the dots of its title bar and its app's icon; the fourth counts the ones not drawn.
    private func window(_ window: AeroWindow, more: Int, small: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack {
            if more > 0 {
                Text("+\(more)").font(style.toyFredoka(16)).foregroundStyle(style.color(\.text2))
            } else {
                ToyAppIcon(bundle: window.bundleId, name: window.appName, size: small ? 26 : 34).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.color(\.panel), in: shape)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } }
                .foregroundStyle(style.color(\.outline).opacity(0.5)).padding(.top, 5).padding(.leading, 6)
        }
        .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
    }
}

// MARK: - Most pressed

/// Today's busiest binds (`.press`): each one's keycaps, its app's icon, name and count over a bar in its module's soft
/// colour as long as its share of the busiest. `spread`, the rows fill the card's height.
private struct ToyMostPressed: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let parts: HomeParts
    let spread: Bool

    private struct Row {
        let action: String
        let key: Key?
        let name: String
        let count: Int
        let module: Int
    }

    var body: some View {
        let rows = engine.today.top(5, now: .now).map { row in
            let action = engine.action(row.action)
            return Row(action: row.action, key: engine.binds.store.trigger(for: row.action), name: action?.label ?? row.action, count: row.count,
                       module: BindsKeyboard.module(action?.module.rawValue ?? ""))
        }
        let top = max(1, rows.first?.count ?? 1)
        ToyCard(title: "Most pressed today") {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing pressed yet today").font(style.toyFredoka(19)).foregroundStyle(style.color(\.text))
                    Text("Hold \(engine.settings.layerKeys.label) and press a key; it counts here.")
                        .font(style.toyNunito(700, 13.5)).foregroundStyle(style.color(\.text2))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: spread ? 0 : 12) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if spread && i > 0 { Spacer(minLength: 12) }
                        line(row, share: Double(row.count) / Double(top))
                    }
                }
                .frame(maxHeight: spread ? .infinity : nil, alignment: .top)
            }
        }
    }

    private func line(_ row: Row, share: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return HStack(spacing: 10) {
            Group { if let key = row.key { ToyBind(key: key, small: true) } }.frame(minWidth: 84, alignment: .leading)
            if case .image(let image) = parts.binds.glyph(row.action) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: 24, height: 24).accessibilityHidden(true)
            }
            Text(row.name).font(style.toyNunito(700, 14)).foregroundStyle(style.color(\.text))
                .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
            Spacer(minLength: 6)
            Text("\(row.count)×").font(style.toyNunito(800, 13)).monospacedDigit()
                .foregroundStyle(style.color(\.text2)).fixedSize()
        }
        .padding(.leading, 6).padding(.trailing, 12)
        .frame(height: 38)
        .background {
            GeometryReader { g in
                Toy.moduleSoft(row.module, style).frame(width: g.size.width * share.clamped01).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(style.color(\.sunken))
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(style.color(\.outline), lineWidth: 2) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.count) presses today")
    }
}

/// A bind as Toybox's keycaps: Hyper's sun cap for a Hyper bind, a cap per modifier, the key's own name; `small`, the
/// press rows' 24 pt caps (`.press .kc`).
struct ToyBind: View {
    let key: Key
    var small = false
    /// The bind editor's heading caps.
    var large = false

    var body: some View {
        let signs = [(Modifiers.shift, "⇧"), (.ctrl, "⌃"), (.alt, "⌥"), (.cmd, "⌘")].filter { !key.modifiers.isDisjoint(with: $0.0) }.map(\.1)
        ToyKeys(keys: signs + [KeyNames.name(for: key.keyCode)], hyper: key.hyper, large: large, small: small)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel((key.hyper ? "Hyper " : "") + key.label)
    }
}

/// A glyph on a coloured keycap (`.bigtile`): what needs you, All clear, the tiler stopped.
struct ToySymbolCap: View {
    @Environment(\.style) private var style
    let symbol: String
    let fill: KeyPath<StyleColors, Paint>

    var body: some View {
        Image(systemName: symbol).font(.system(size: 22, weight: .heavy)).foregroundStyle(style.color(\.outline))
            .frame(width: 44, height: 42)
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
            .background(Toy.block(style, fill: style.color(fill), radius: 14, edge: 4))
            .accessibilityHidden(true)
    }
}

/// An app's own icon, by its bundle or its running app's name; else its initial on a sky tile.
private struct ToyAppIcon: View {
    @Environment(\.style) private var style
    let bundle: String
    let name: String
    let size: CGFloat

    var body: some View {
        if let icon = AppsModule.icon(bundle: bundle) ?? AppsModule.icon(named: name) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Text(name.prefix(1).uppercased()).font(style.toyFredoka(size * 0.5))
                .foregroundStyle(style.color(\.outline))
                .frame(width: size * 0.82, height: size * 0.82)
                .toyWell(\.modules[0], radius: size * 0.24)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Clipboard

/// A copy as Home shows it: its kind, words, the app it came from and when.
struct HomeClip: Sendable {
    let kind: ClipKind
    let title: String
    /// The app's bundle id, and its name.
    let source: String?
    let app: String?
    let at: Date

    /// A kept copy as Home shows it.
    @MainActor init(_ clip: StoredClip) {
        self.init(kind: clip.kind, title: clip.title, source: clip.sourceApp, app: clip.sourceApp.flatMap(AppsModule.appName), at: clip.copiedAt)
    }

    init(kind: ClipKind, title: String, source: String?, app: String?, at: Date) {
        self.kind = kind; self.title = title; self.source = source; self.app = app; self.at = at
    }
}

/// The newest copies (`.clip`): what each is, a swatch for a colour, the line under it and its app's icon; under them the
/// keys that open the whole history.
private struct ToyClipboard: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    let parts: HomeParts
    @State private var clips: [HomeClip] = []

    var body: some View {
        ToyCard(title: "Clipboard") {
            if let copy = parts.copy {
                Text("\(copy.count) kept").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)).fixedSize()
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if clips.isEmpty {
                    Text("Nothing copied yet").font(style.toyFredoka(19)).foregroundStyle(style.color(\.text))
                    Text("What you copy shows here, newest first, with the app it came from.")
                        .font(style.toyNunito(700, 13.5)).foregroundStyle(style.color(\.text2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                TimelineView(.everyMinute) { context in
                    VStack(spacing: 10) { ForEach(Array(clips.enumerated()), id: \.offset) { row($1, now: context.date) } }
                }
                Spacer(minLength: 2)
                Button { engine.action("apps.clipboard")?.run() } label: {
                    HStack(spacing: 8) {
                        if let key = engine.binds.store.trigger(for: "apps.clipboard") { ToyBind(key: key) }
                        Text("opens the whole history").font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.kitPress)
                .help("Open the clipboard")
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .task(id: parts.copy) { clips = parts.sources.recentCopies().prefix(3).map(HomeClip.init) }
    }

    private func row(_ clip: HomeClip, now: Date) -> some View {
        let colour = clip.kind == .colour ? ClipboardCapture.colourValue(clip.title) : nil
        let mono = [.link, .colour, .email].contains(clip.kind)
        return HStack(spacing: 12) {
            Group {
                if let colour { Color(Paint(colour)) } else {
                    Toy.moduleSoft(Toy.module(of: clip.kind), style)
                        .overlay { Image(systemName: clip.kind.symbol).font(.system(size: 17, weight: .bold)).foregroundStyle(style.color(\.text)) }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: 2) }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title.trimmingCharacters(in: .whitespacesAndNewlines).replacing("\n", with: " "))
                    .font(mono ? style.toyMono(12.5) : style.toyNunito(700, 13.5))
                    .foregroundStyle(style.color(\.text)).truncationMode(.tail)
                Text(ToyHome.clipLine(kind: clip.kind, app: clip.app, ago: StatsFormat.ago(now.timeIntervalSince(clip.at))))
                    .font(style.toyNunito(700, 12)).foregroundStyle(style.color(\.text3))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let source = clip.source, AppsModule.icon(bundle: source) != nil {
                AppGlyph(bundles: [source], symbol: "app", size: 22)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .toyWell(radius: 14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - This Mac

/// This Mac now (`.mac`): CPU, memory and the CPU's temperature as bar sparklines of their last readings, the startup
/// disk as a meter with what is free, each in its module colour; Stats has the history.
private struct ToyThisMac: View {
    @Environment(\.style) private var style
    let parts: HomeParts

    var body: some View {
        let system = SystemSampler.shared
        let values = system.latestValues, raw = system.latest, history = system.history
        let cpu = history.map(\.cpu), ram = history.map { Optional($0.ram) }, heat = history.map(\.heat)
        let disk = raw?.slow.disk
        ToyCard(title: "This Mac") {
            ToyLink(title: "Stats") { parts.go(AppPlace(.stats)) }
        } content: {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    gauge("CPU", values?.cpu.map(StatsFormat.percent), "%") {
                        ToySpark(bars: ToyHome.bars(cpu, count: 14, top: StatsFormat.ceiling(cpu, steps: StatsFormat.shareSteps)), colour: Toy.module(0, style))
                    }
                    gauge("RAM", values.map { StatsFormat.percent($0.ram) }, "%") {
                        ToySpark(bars: ToyHome.bars(ram, count: 14, top: 1), colour: Toy.module(1, style))
                    }
                }
                GridRow {
                    gauge("SSD", raw?.diskUsed.map(StatsFormat.percent), "%") {
                        VStack(alignment: .leading, spacing: 6) {
                            Spacer(minLength: 0)
                            ToyChunkyMeter(share: raw?.diskUsed ?? 0, colour: Toy.module(2, style))
                            if let disk {
                                Text(StatsFormat.bytes(Double(disk.available)) + " free").font(style.toyNunito(700, 12))
                                    .foregroundStyle(disk.available < 20_000_000_000 ? style.color(\.problem) : style.color(\.text2)).lineLimit(1)
                            }
                        }
                    }
                    gauge("Temp", values?.heat.map(StatsFormat.whole), "°C") {
                        ToySpark(bars: ToyHome.bars(heat, count: 14, top: StatsFormat.ceiling(heat, steps: StatsFormat.heatSteps, headroom: 1.25)),
                                 colour: Toy.module(4, style))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func gauge(_ label: String, _ value: String?, _ unit: String, @ViewBuilder chart: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(style.toyNunito(800, 12)).tracking(0.72).textCase(.uppercase)
                    .foregroundStyle(style.color(\.text2))
                Spacer(minLength: 4)
                Text("\(Text(value ?? "–").font(style.toyFredoka(24)).foregroundStyle(style.color(\.text)))\(Text(unit).font(style.toyNunito(700, 13)).foregroundStyle(style.color(\.text2)))")
                    .monospacedDigit().fixedSize()
            }
            .lineLimit(1)
            chart().frame(minHeight: 30, maxHeight: .infinity)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toyWell(radius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value.map { "\($0) \(unit)" } ?? "not read yet")
    }
}

/// Bars standing on the gauge's foot (`.spark`), each outlined in the ink, a reading at least a sliver.
struct ToySpark: View {
    @Environment(\.style) private var style
    let bars: [Double]
    let colour: Color

    var body: some View {
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(bars.indices, id: \.self) { i in
                    let share = bars[i]
                    let shape = UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous)
                    shape.fill(colour).overlay { shape.stroke(style.color(\.outline), lineWidth: 1.5) }
                        .frame(height: max(4, g.size.height * share))
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
        }
    }
}

// MARK: - Small parts

private extension Double {
    /// Kept within 0 to 1, as a share is drawn.
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}

/// A card's trailing link: its words, the text colour while hovered.
private struct ToyLink: View {
    @Environment(\.style) private var style
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(style.toyNunito(700, 13))
                .foregroundStyle(hovering ? style.color(\.text) : style.color(\.text2)).fixedSize().contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .onHover { hovering = $0 }
    }
}
