import AppKit
import PilotCore
import SwiftUI

// Binds' Save map (Sven, 2026-10-19, Q328; Atlas picked in Q330): every layer of the active preset and the mouse as one
// PNG, drawn offscreen from the bind store at 2x (an A4 page at 300 dpi), to print or keep beside the keyboard.

/// What the map draws: the store's layers, each bound action's short name, full name, kind and picture, and the mouse's
/// bound buttons.
@MainActor
struct BindsMapModel {
    struct Bound {
        let action: String
        /// A word or two for a key ("Terminal", "¾ left"); `label` is the action's full name.
        let name: String
        let label: String
        let kind: BindsMap.Kind
        let glyph: BoardKey.Glyph
    }

    /// One bound mouse button or wheel direction: its plain press and its Hyper press.
    struct Mouse {
        let name: String
        /// The drawn button (3 the wheel click, 4 back, 5 forward); nil for the wheel's directions.
        let number: Int?
        var plain: Bound?
        var hyper: Bound?
    }

    let preset: String
    let layerKeys: [LayerKey]
    let date: Date
    let layers: [BindsMap.Layer]
    let bound: [String: Bound]
    let mouse: [Mouse]
    let board: BindsKeyboard.Board

    var layerKey: String { layerKeys.label }
    var keyCount: Int { layers.reduce(0) { $0 + $1.entries.count } }
    var mouseCount: Int { mouse.reduce(0) { $0 + ($1.plain == nil ? 0 : 1) + ($1.hyper == nil ? 0 : 1) } }

    init(engine: Engine, board: BindsKeyboard.Board, date: Date = .now) {
        let store = engine.binds.store
        let infos = Dictionary(engine.allBindActions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let home = HomeBinds(engine: engine)
        var bound: [String: Bound] = [:]
        func make(_ id: String) -> Bound {
            if let b = bound[id] { return b }
            let action = infos[id] == nil ? engine.action(id) : nil
            let label = infos[id]?.label ?? action?.label ?? id
            let module = infos[id]?.module ?? action?.module.rawValue ?? ""
            var name = Self.names[id] ?? BindsKeyboard.short(id, label: label) { engine.presets.contents.name(for: $0) }
            // A picker's name is its title's ("Code folder"): its first word holds a key.
            if id.hasPrefix("drive.pick:"), let first = name.split(separator: " ").first { name = String(first) }
            // A site whose name is one letter ("X") reads as an unlabelled key: its host says it ("x.com").
            if name.count == 1, let host = Self.site(id).flatMap({ URL(string: $0)?.host() }) { name = host.replacing(/^www\./, with: "") }
            let b = Bound(action: id, name: name, label: label, kind: BindsMap.Kind(module: module), glyph: Self.glyph(id, home: home))
            bound[id] = b
            return b
        }
        layers = BindsMap.layers(store.binds)
        for layer in layers { for entry in layer.entries { _ = make(entry.action) } }

        var rows: [String: Mouse] = [:]
        for (trigger, bind) in store.mouseBinds {
            let id: String, row: Mouse
            if MouseKeys.isScroll(trigger.keyCode) {
                let up = trigger.keyCode == MouseKeys.scrollUp.keyCode
                id = up ? "w1" : "w2"
                row = rows[id] ?? Mouse(name: up ? "Wheel up" : "Wheel down", number: nil)
            } else if let n = MouseKeys.number(trigger) ?? bind.button {
                id = String(format: "b%02d", n)
                row = rows[id] ?? Mouse(name: MouseKeys.buttonName(n), number: n)
            } else {
                id = "s" + MouseKeys.sends(trigger)
                row = rows[id] ?? Mouse(name: MouseKeys.sends(trigger), number: nil)
            }
            var next = row
            if trigger.hyper { next.hyper = make(bind.action) } else { next.plain = make(bind.action) }
            rows[id] = next
        }
        mouse = rows.sorted { $0.key < $1.key }.map(\.value)
        self.bound = bound
        preset = store.preset.title
        layerKeys = engine.settings.layerKeys
        self.date = date
        self.board = board
    }

    /// A run's words: its first action's name without the number, "Go to workspace".
    func runLabel(_ run: BindsMap.Run, in layer: BindsMap.Layer) -> String {
        guard let code = run.codes.first, let action = layer.byKey[code]?.action, let label = bound[action]?.label else { return run.family }
        // The run's number out of the name, at its end or inside it ("Move window to workspace 1 and follow").
        return label.replacing(/\s+\d+(?=\s|$)/, with: "")
    }

    /// A bind's picture: an app's own icon; else Binds' keyboard symbol, the menu's for the action, then the map's
    /// below, so no two different tools share a gear (judge, round 1); a site a globe.
    static func glyph(_ id: String, home: HomeBinds) -> BoardKey.Glyph {
        let picture = home.glyph(id)
        if case .image = picture { return picture }
        // A site in a named browser wears that browser's icon, so two sites in two browsers differ; any other site a globe.
        if id.hasPrefix("apps.url:"), let browser = id.dropFirst("apps.url:".count).split(separator: ":").first,
           let icon = AppsModule.icon(bundle: String(browser)) { return .image(icon) }
        if site(id) != nil { return .symbol("globe") }
        if HomeBinds.symbols[id] != nil { return picture }
        if let symbol = MenuEntry.actionSymbol(id) ?? symbol(id) { return .symbol(symbol) }
        return picture
    }

    /// The address a site bind opens; nil for any other action.
    static func site(_ id: String) -> String? {
        if id.hasPrefix("apps.url:") { return id.split(separator: ":", maxSplits: 2).last.map(String.init) }
        for prefix in ["apps.web:", "drive.url:"] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return nil
    }

    /// The map's symbols for actions neither the menu nor Binds' keyboard draws one for.
    static func symbol(_ id: String) -> String? {
        if id.hasPrefix("workspaces.moveFollow:"), let n = Int(id.dropFirst("workspaces.moveFollow:".count)), (0...50).contains(n) { return "\(n).circle.fill" }
        if id.hasPrefix("apps.private:") { return "eye.slash" }
        if id.hasPrefix("drive.pick:") { return "list.bullet.rectangle" }
        for (prefix, symbol) in [("windows.join", "arrow.%@.square"), ("windows.sendToDisplay", "arrowshape.%@")] where id.hasPrefix(prefix) {
            let side = id.dropFirst(prefix.count).lowercased()
            if ["left", "right", "up", "down"].contains(side) { return String(format: symbol, side) }
        }
        return symbols[id]
    }

    static let symbols: [String: String] = [
        "terminal.drop": "rectangle.bottomthird.inset.filled", "notes.toggle": "note.text", "speech.readAloud": "speaker.wave.2.bubble",
        "apps.pastePlain": "doc.plaintext", "drive.copy": "doc.on.doc", "bar.peekMenuBar": "menubar.rectangle",
        "system.brightnessDown": "sun.min", "system.brightnessUp": "sun.max", "system.brightnessDownAll": "sun.min.fill",
        "system.brightnessUpAll": "sun.max.fill", "system.infoHUD": "info.circle", "system.menu": "switch.2",
        "system.nextWallpaper": "photo", "system.previousWallpaper": "photo.on.rectangle", "windows.defocus": "circle.dotted",
        "windows.popOut": "rectangle.portrait.and.arrow.forward", "windows.grow": "plus.rectangle", "windows.shrink": "minus.rectangle",
    ]

    /// Short names for keys where Binds' short name runs past a key cap on one line at the map's one name size.
    static let names: [String: String] = [
        "system.brightnessDown": "Dim", "system.brightnessUp": "Bright", "system.brightnessDownAll": "Dim all",
        "system.brightnessUpAll": "Bright all", "windows.fullscreen": "Full", "windows.grow": "Grow", "windows.shrink": "Shrink",
        "windows.cycleColumnWidthBack": "Width ←", "captures.pickColour": "Colour", "apps.passwords": "Vault", "notes.toggle": "Notes",
    ]
}

// MARK: Ink and type

/// The map's colours, from Lagoon, Pilot's default theme: its ground, surfaces, lines and text, and four kind colours
/// that never repeat (Lagoon's Windows and Captures share a teal on the Binds page; a map coloured by kind cannot).
struct MapInk {
    let theme: PilotTheme
    let ground, surface, raised, line, line2, text, text2, text3, accent, onAccent: Color
    let kinds: [Color]

    init(_ t: PilotTheme = PilotTheme.named("lagoon") ?? .standard) {
        theme = t
        let c = { Color(hex: $0) }
        ground = c(t.ground); surface = c(t.surface); raised = c(t.raised); line = c(t.line); line2 = c(t.line2)
        text = c(t.text); text2 = c(t.text2); text3 = c(t.text3); accent = c(t.accent); onAccent = c(t.onAccent)
        // App the accent, as Binds colours it (Q252); Window the amber; Capture the second colour (the third where it repeats
        // the good one); Tool the second text, Instrument's neutral, which no theme's accent sits near (judge, round 2).
        let capture = t.second == t.good ? t.third : t.second
        kinds = [t.accent, t.amber, capture, t.text2].map(c)
    }

    func kind(_ k: BindsMap.Kind) -> Color { kinds[k.rawValue] }
    /// A kind's tint as a key's face.
    func tint(_ k: BindsMap.Kind) -> Color { kind(k).opacity(theme.dark ? 0.16 : 0.11) }
}

@MainActor
enum MapType {
    static func sans(_ size: CGFloat, _ weight: Int = 400) -> Font { Font(DisplayFaces.font(StyleTokens.geist(weight), size: size)) }
    static func mono(_ size: CGFloat, _ weight: Int = 400) -> Font { Font(DisplayFaces.font(StyleTokens.geistMono(weight), size: size)) }
}

// MARK: Board geometry

/// Where each key of the compact board sits at a size: one unit a key's width, the function row shorter and set apart.
struct MapBoard {
    let board: BindsKeyboard.Board
    let unit: CGFloat
    let rowHeight: CGFloat
    let gap: CGFloat
    /// The function row's height and the room under it.
    var fRow: CGFloat { (rowHeight * 0.8).rounded() }
    var fGap: CGFloat { (rowHeight * 0.2).rounded() }

    func frame(_ spot: BindsKeyboard.Spot) -> CGRect {
        let y = spot.row == 0 ? 0 : fRow + fGap + CGFloat(spot.row - 1) * rowHeight
        return CGRect(x: spot.x * unit, y: y, width: spot.width * unit - gap, height: (spot.row == 0 ? fRow : rowHeight) - gap)
    }

    var size: CGSize {
        let rows = (board.spots.map(\.row).max() ?? 5)
        return CGSize(width: board.width * unit - gap, height: fRow + fGap + CGFloat(rows) * rowHeight - gap)
    }

    /// Whether `spot` is drawn held on `layer`: a layer key on a Hyper layer, or one of the layer's modifiers.
    static func held(_ spot: BindsKeyboard.Spot, layer: BindsMap.Layer, layerKeys: [LayerKey]) -> (layerKey: Bool, modifier: Bool) {
        guard layer.hyper else { return (false, false) }
        let isLayerKey = BindsKeyboard.isLayerKey(spot, layerKeys: layerKeys, layer: .hyper)
        let isHeld = !isLayerKey && spot.modifier.map { !layer.modifiers.isDisjoint(with: $0.both) } == true
        return (isLayerKey, isHeld)
    }
}

/// The picture of a bind: an app's icon, else its symbol in its kind's colour.
struct MapGlyph: View {
    let bound: BindsMapModel.Bound
    let size: CGFloat
    let colour: Color

    var body: some View {
        switch bound.glyph {
        case .image(let image): Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.74, weight: .medium)).foregroundStyle(colour)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - The sheet

/// The map: a card per layer, each of the busiest layers a whole keyboard with every bound key named and pictured in its
/// kind's colour, the others as a list of their keys, two cards a row; the smallest layers stacked beside the mouse,
/// drawn with its buttons numbered. Lagoon, as Pilot draws Binds; an A4 page (1240 by 1754 pt) while the binds fit it,
/// longer when they do not.
struct BindsMapSheet: View {
    let model: BindsMapModel
    var ink = MapInk()

    static let width: CGFloat = 1240, a4: CGFloat = 1754, margin: CGFloat = 40, pad: CGFloat = 20, gap: CGFloat = 12
    /// A layer with this many binds or more is drawn as a keyboard; Hyper always is.
    static let boardFrom = 25
    /// A layer with this many binds or fewer stacks beside the mouse.
    static let smallUpTo = 4

    /// The sheet as a PNG at `scale`, 2 by default (a 1240 pt sheet is 2480 px, A4's width at 300 dpi), its size in
    /// points kept so it reads as a 144 dpi picture.
    static func png(_ model: BindsMapModel, scale: CGFloat = 2) -> Data? {
        let renderer = ImageRenderer(content: BindsMapSheet(model: model).environment(\.colorScheme, .dark))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    private var boards: [BindsMap.Layer] {
        model.layers.enumerated().filter { $0.offset == 0 || $0.element.entries.count >= Self.boardFrom }.map(\.element)
    }
    private var lists: [BindsMap.Layer] {
        model.layers.enumerated().filter { $0.offset > 0 && (Self.smallUpTo + 1..<Self.boardFrom).contains($0.element.entries.count) }.map(\.element)
    }
    private var small: [BindsMap.Layer] { model.layers.dropFirst().filter { $0.entries.count <= Self.smallUpTo } }

    /// A card under the keyboards: a layer's list, the smallest layers together, or the mouse.
    private enum Block { case list(BindsMap.Layer), small([BindsMap.Layer]), mouse }

    /// The cards under the keyboards in two columns, each card to the shorter column, by its lines' count, so neither
    /// column stretches a card over empty room (judge, round 3).
    private var columns: [[Block]] {
        var blocks = lists.map(Block.list)
        if !small.isEmpty { blocks.append(.small(small)) }
        if !model.mouse.isEmpty { blocks.append(.mouse) }
        func height(_ b: Block) -> Int {
            switch b {
            case .list(let layer): 3 + (lines(layer).count + 1) / 2
            case .small(let layers): layers.reduce(0) { $0 + 3 + lines($1).count }
            case .mouse: 4 + model.mouse.count
            }
        }
        var out: [[Block]] = [[], []], filled = [0, 0]
        for b in blocks {
            let i = filled[0] <= filled[1] ? 0 : 1
            out[i].append(b)
            filled[i] += height(b)
        }
        return out
    }

    var body: some View {
        let columns = columns
        VStack(alignment: .leading, spacing: Self.gap) {
            header.padding(.bottom, 1)
            ForEach(Array(boards.enumerated()), id: \.offset) { _, layer in card(layer) { board(layer) } }
            if !columns.joined().isEmpty {
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(0..<2, id: \.self) { c in
                        VStack(spacing: Self.gap) {
                            ForEach(Array(columns[c].enumerated()), id: \.offset) { i, block in
                                // The column's last card takes what is left, so the two columns end together.
                                self.block(block, fill: i == columns[c].count - 1)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(provenance).font(MapType.mono(11.5)).foregroundStyle(ink.text3)
        }
        .padding(Self.margin)
        .frame(width: Self.width, alignment: .topLeading)
        .frame(minHeight: Self.a4, alignment: .top)
        .background(ink.ground)
    }

    @ViewBuilder private func block(_ block: Block, fill: Bool) -> some View {
        switch block {
        case .list(let layer): card(layer, fill: fill) { list(layer, columns: 2) }
        case .small(let layers): smallCard(layers, fill: fill)
        case .mouse: mouse(fill: fill)
        }
    }

    private var provenance: String {
        "Saved from Pilot on \(model.date.formatted(.dateTime.day().month(.wide).year())), preset \(model.preset)"
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 5) {
                Text("KEYBOARD MAP").font(MapType.mono(12.5, 500)).tracking(1.4).foregroundStyle(ink.accent)
                Text(model.preset).font(MapType.sans(34, 600)).tracking(-0.9).foregroundStyle(ink.text)
                Text("Hold \(model.layerKey) for Hyper. \(model.keyCount) keys on \(model.layers.count) layers, \(model.mouseCount) on the mouse.")
                    .font(MapType.sans(15)).foregroundStyle(ink.text2)
            }
            Spacer()
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                ForEach([0, 2], id: \.self) { i in
                    GridRow {
                        ForEach(BindsMap.Kind.allCases[i..<i + 2], id: \.self) { kind in
                            HStack(spacing: 9) {
                                RoundedRectangle(cornerRadius: 3).fill(ink.kind(kind)).frame(width: 12, height: 12)
                                Text(kind.title).font(MapType.sans(13.5, 500)).foregroundStyle(ink.text2)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Cards

    private func card(_ layer: BindsMap.Layer, fill: Bool = false, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            title(layer)
            content()
        }
        .padding(Self.pad)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ink.line, lineWidth: 1))
    }

    /// A layer's title row: its keys as caps (the layer key, then the held modifiers), its name, how to press, its count.
    private func title(_ layer: BindsMap.Layer) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 4) {
                if layer.hyper { cap("Hyper", strong: true) } else { quietCap("no Hyper") }
                ForEach(Array(layer.signs.map(String.init).enumerated()), id: \.offset) { cap($0.element, strong: false) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.title).font(MapType.sans(19, 600)).tracking(-0.3).foregroundStyle(ink.text)
                Text(layer.how(layerKey: model.layerKey)).font(MapType.sans(12.5)).foregroundStyle(ink.text2)
            }
            Spacer(minLength: 8)
            Text("\(layer.entries.count)").font(MapType.mono(14, 500)).foregroundStyle(ink.text3)
        }
    }

    private func cap(_ text: String, strong: Bool) -> some View {
        Text(text).font(MapType.mono(12, 600)).foregroundStyle(strong ? ink.onAccent : ink.accent)
            .padding(.horizontal, 8).frame(minWidth: 26, minHeight: 25)
            .background(RoundedRectangle(cornerRadius: 6).fill(strong ? ink.accent : ink.accent.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.accent.opacity(strong ? 0 : 0.5), lineWidth: 1))
    }

    /// The smallest layers in one card, a section each, so a layer of one bind does not spend a card's frame.
    private func smallCard(_ layers: [BindsMap.Layer], fill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(layers.enumerated()), id: \.offset) { i, layer in
                if i > 0 { Rectangle().fill(ink.line).frame(height: 1) }
                VStack(alignment: .leading, spacing: 8) {
                    title(layer)
                    list(layer, columns: 1)
                }
            }
        }
        .padding(Self.pad)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ink.line, lineWidth: 1))
    }

    /// A key held with no Hyper: the line ring, not the signal colour, which means Hyper alone.
    private func quietCap(_ text: String) -> some View {
        Text(text).font(MapType.mono(12, 600)).foregroundStyle(ink.text2)
            .padding(.horizontal, 8).frame(minHeight: 25)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ink.line2, lineWidth: 1))
    }

    /// Each bound key's name on `layer`: keys sharing a name that differ by direction say it ("Swap ←", judge, round 3). Two
    /// sites of one name keep it whole and differ by picture: the browser's icon, or the globe.
    private func names(_ layer: BindsMap.Layer) -> [Int64: String] {
        let place = Dictionary(model.board.spots.enumerated().compactMap { i, s in s.code.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        let entries = layer.entries.sorted { (place[$0.code] ?? 999) < (place[$1.code] ?? 999) }
        var counts: [String: Int] = [:]
        for e in entries { if let n = model.bound[e.action]?.name { counts[n, default: 0] += 1 } }
        var out: [Int64: String] = [:]
        for e in entries {
            guard let name = model.bound[e.action]?.name else { continue }
            guard counts[name, default: 0] > 1 else { out[e.code] = name; continue }
            let id = e.action.lowercased()
            if let arrow = [("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓")].first(where: { id.hasSuffix($0.0) })?.1 {
                out[e.code] = "\(name) \(arrow)"
            } else {
                out[e.code] = name
            }
        }
        return out
    }

    // MARK: Board

    private func board(_ layer: BindsMap.Layer) -> some View {
        let unit = (Self.width - 2 * Self.margin - 2 * Self.pad) / model.board.width
        let geo = MapBoard(board: model.board, unit: unit, rowHeight: (unit * 0.72).rounded(), gap: 5)
        let byKey = layer.byKey, runs = BindsMap.runs(layer), names = names(layer)
        let inRun = Set(runs.flatMap(\.codes))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(model.board.spots.enumerated()), id: \.offset) { _, spot in
                let f = geo.frame(spot)
                key(spot, entry: spot.code.flatMap { byKey[$0] }, name: spot.code.flatMap { names[$0] }, layer: layer,
                    run: spot.code.map(inRun.contains) ?? false, size: f.size)
                    .offset(x: f.minX, y: f.minY)
            }
            // A numbered run's words once across its keys.
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                let frames = model.board.spots.filter { $0.code.map(run.codes.contains) ?? false }.map(geo.frame)
                if let a = frames.first, let b = frames.last, let kind = run.codes.first.flatMap({ byKey[$0] }).flatMap({ model.bound[$0.action]?.kind }) {
                    Text("\(model.runLabel(run, in: layer))  \(run.first)–\(run.last)")
                        .font(MapType.sans(12, 600)).foregroundStyle(ink.kind(kind)).lineLimit(1)
                        .frame(width: b.maxX - a.minX - 16, height: 17)
                        .background(Capsule().fill(ink.surface))
                        .overlay(Capsule().strokeBorder(ink.kind(kind).opacity(0.55), lineWidth: 1))
                        .offset(x: a.minX + 8, y: a.maxY - 21)
                }
            }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func key(_ spot: BindsKeyboard.Spot, entry: BindsMap.Entry?, name: String?, layer: BindsMap.Layer, run: Bool, size: CGSize) -> some View {
        let held = MapBoard.held(spot, layer: layer, layerKeys: model.layerKeys)
        let legend = BindsKeyboard.printed(spot)
        let shape = RoundedRectangle(cornerRadius: 7)
        let fRow = spot.row == 0
        if let entry, let b = model.bound[entry.action] {
            let colour = ink.kind(b.kind)
            ZStack(alignment: .topLeading) {
                shape.fill(ink.raised)
                shape.fill(ink.tint(b.kind))
                shape.strokeBorder(colour.opacity(0.65), lineWidth: 1.5)
                HStack(alignment: .top, spacing: 2) {
                    Text(BindsMap.Layer.signs(entry.modifiers) + legend).font(MapType.mono(run ? 13 : fRow ? 10.5 : 12, 600)).foregroundStyle(colour)
                    Spacer(minLength: 0)
                    if !run { MapGlyph(bound: b, size: fRow ? 13 : 17, colour: colour) }
                }
                .padding(.horizontal, 6).padding(.top, fRow ? 3 : 5)
                if !run {
                    // One line at one size: a name a key cannot hold has a shorter one in BindsMapModel.names.
                    Text(name ?? b.name).font(MapType.sans(fRow ? 11.5 : 12.5, 500)).foregroundStyle(ink.text)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .frame(width: size.width - 11, height: size.height - (fRow ? 4 : 6), alignment: .bottomLeading)
                        .padding(.leading, 6)
                }
            }
            .frame(width: size.width, height: size.height)
        } else {
            // A free key keeps quiet so the bound ones read (judge, round 1); the held keys show how to press the layer.
            let on = held.layerKey || held.modifier
            ZStack(alignment: .topLeading) {
                shape.fill(held.layerKey ? ink.accent : held.modifier ? ink.accent.opacity(0.16) : .clear)
                shape.strokeBorder(on ? ink.accent.opacity(0.7) : ink.line, lineWidth: 1)
                Text(held.layerKey ? "hyper" : legend).font(MapType.mono(11, held.layerKey ? 600 : 400))
                    .foregroundStyle(held.layerKey ? ink.onAccent : held.modifier ? ink.accent : ink.text3.opacity(0.6))
                    .padding(.horizontal, 6).padding(.top, fRow ? 4 : 5)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    // MARK: List

    /// One line of a list card: a bind, or a run of numbered binds as one.
    private struct Line { let keys: String; let bound: BindsMapModel.Bound; let words: String }

    private func lines(_ layer: BindsMap.Layer) -> [Line] {
        let runs = BindsMap.runs(layer), inRun = Set(runs.flatMap(\.codes)), byKey = layer.byKey
        var out: [Line] = []
        for run in runs {
            guard let code = run.codes.first, let b = byKey[code].flatMap({ model.bound[$0.action] }) else { continue }
            // The run's own picture, not its first key's number.
            let shown = BindsMapModel.Bound(action: b.action, name: b.name, label: b.label, kind: b.kind, glyph: .symbol("number.square"))
            out.append(Line(keys: "\(run.first)–\(run.last)", bound: shown, words: model.runLabel(run, in: layer)))
        }
        // The rest in board order.
        let place = Dictionary(model.board.spots.enumerated().compactMap { i, s in s.code.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        for entry in layer.entries.sorted(by: { (place[$0.code] ?? 999) < (place[$1.code] ?? 999) }) where !inRun.contains(entry.code) {
            guard let b = model.bound[entry.action] else { continue }
            out.append(Line(keys: BindsMap.Layer.signs(entry.modifiers) + model.board.caption(entry.code), bound: b, words: b.label))
        }
        return out
    }

    private func list(_ layer: BindsMap.Layer, columns: Int) -> some View {
        let lines = lines(layer)
        let per = max(1, Int((Double(lines.count) / Double(columns)).rounded(.up)))
        // One chip column a list, as wide as its widest chip, so every picture and name starts on one line (judge, round 3).
        let chip = max(36, (lines.map { CGFloat($0.keys.count) }.max() ?? 1) * 7.3 + 14)
        return HStack(alignment: .top, spacing: 14) {
            ForEach(0..<columns, id: \.self) { c in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.dropFirst(c * per).prefix(per).enumerated()), id: \.offset) { _, line in row(line, chip: chip) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func row(_ line: Line, chip: CGFloat) -> some View {
        let colour = ink.kind(line.bound.kind)
        return HStack(spacing: 8) {
            Text(line.keys).font(MapType.mono(12, 600)).foregroundStyle(colour).lineLimit(1).fixedSize()
                .padding(.horizontal, 6).frame(minWidth: 36, minHeight: 23)
                .background(RoundedRectangle(cornerRadius: 6).fill(ink.tint(line.bound.kind)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(colour.opacity(0.6), lineWidth: 1.25))
                .frame(width: chip, alignment: .leading)
            MapGlyph(bound: line.bound, size: 16, colour: colour)
            Text(line.words).font(MapType.sans(13.5, 500)).foregroundStyle(ink.text).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Mouse

    /// The mouse: drawn from the top and the side, each bound button numbered, then each button alone and with Hyper.
    private func mouse(fill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "computermouse").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink.accent)
                    .frame(width: 26, height: 25).background(RoundedRectangle(cornerRadius: 6).fill(ink.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mouse").font(MapType.sans(19, 600)).tracking(-0.3).foregroundStyle(ink.text)
                    Text("Each button alone, and with \(model.layerKey) held").font(MapType.sans(12.5)).foregroundStyle(ink.text2)
                }
                Spacer(minLength: 8)
                Text("\(model.mouseCount)").font(MapType.mono(14, 500)).foregroundStyle(ink.text3)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text("")
                    Text("ALONE").font(MapType.mono(11, 500)).tracking(1).foregroundStyle(ink.text3)
                    Text("WITH HYPER").font(MapType.mono(11, 500)).tracking(1).foregroundStyle(ink.text3)
                }
                .padding(.bottom, 8)
                ForEach(Array(model.mouse.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(ink.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        HStack(spacing: 8) {
                            MouseBadge(number: row.number, wheel: row.name, ink: ink)
                            Text(row.name).font(MapType.sans(13.5, 500)).foregroundStyle(ink.text2).fixedSize()
                        }
                        cell(row.plain)
                        cell(row.hyper)
                    }
                    .frame(minHeight: 30)
                }
            }
        }
        .padding(Self.pad)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(ink.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ink.line, lineWidth: 1))
    }

    @ViewBuilder private func cell(_ b: BindsMapModel.Bound?) -> some View {
        if let b {
            HStack(spacing: 7) {
                MapGlyph(bound: b, size: 17, colour: ink.kind(b.kind))
                Text(b.label).font(MapType.sans(13.5, 500)).foregroundStyle(ink.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("—").font(MapType.sans(13.5)).foregroundStyle(ink.text3.opacity(0.6))
        }
    }
}

/// A drawn button's number in a round badge, the wheel's direction as an arrow.
struct MouseBadge: View {
    let number: Int?
    let wheel: String
    let ink: MapInk
    var body: some View {
        Text(number.map(String.init) ?? (wheel.hasSuffix("up") ? "↑" : wheel.hasSuffix("down") ? "↓" : "•"))
            .font(MapType.mono(11.5, 600)).foregroundStyle(ink.accent)
            .frame(width: 22, height: 22)
            .background(Circle().fill(ink.accent.opacity(0.14)))
            .overlay(Circle().strokeBorder(ink.accent.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - Save

/// Save map…: asks where first, then draws the active preset's map and writes it; `failed` says why a write did not
/// happen. The panel begins rather than runs modal, so the tap keeps going while it is open.
@MainActor
enum BindsMapSave {
    static func run(engine: Engine, failed: @escaping (String) -> Void = { _ in }) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pilot keyboard map.png"
        panel.allowedContentTypes = [.png]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let model = BindsMapModel(engine: engine, board: KeyboardCaptions.current.compact)
            guard let data = BindsMapSheet.png(model) else { return failed("The map could not be drawn.") }
            do { try data.write(to: url, options: .atomic); log.notice("binds: map saved to \(url.path, privacy: .public)") }
            catch { failed("\(url.lastPathComponent) not written: \(error.localizedDescription)") }
        }
    }
}
