import AppKit
import PilotCore
import SwiftUI

/// Binds' keyboard in Instrument (mockup A's binds.html, card agent-bo-95423181, ADR 0008): the Mac's 75 % board, hairline
/// keys with the legend in mono at the top left. A bound key is raised, with its one line glyph at the top right (none
/// where another key would show the same, HomeBinds.pictures) and its short name at its foot; an app's key shows the
/// app's own icon, centred and unlabelled. The layer key is filled in the signal colour, the tab's held modifiers wear its
/// soft fill, the picked key is ringed in it, and a key outside the module picked under the board is dimmed. On Binds a
/// bound key is filled in its module's colour (`tinted`, Q252). Every name is whole: the board splits in two halves, one
/// over the other, where the 75 % board cannot hold them.
struct InstrumentBindsBoard: View {
    @Environment(\.style) private var style
    let boards: KeyboardCaptions.Boards
    let binds: HomeBinds
    let layerKeys: [LayerKey]
    let layer: BindsKeyboard.Layer
    let picked: Int64?
    /// What each key says (the page works it out once a pass).
    let marks: InstrumentBoardFit.Marks
    /// The module the board shows lit; nil for all six.
    let module: Int?
    let pick: (Int64) -> Void
    /// A double-click on a key: its bind, or a new bind on it (`BindsKeyboardPage.Acts.open`); nothing on Home.
    var open: (Int64) -> Void = { _ in }
    /// The 75 % board kept whole, its names shrunk, where it would split (Home's board beside the column).
    var whole = false
    /// Each bound key filled in its module's colour (StyleColors.groups), as Binds draws it; Home keeps them plain.
    var tinted = false
    @State private var width: CGFloat = 0

    var body: some View {
        let measure = InstrumentBoardFit.measure(style.type.keyName)
        let fit = InstrumentBoardFit.best(marks, boards: boards, width: width, measure: measure, whole: whole)
        let spacing = InstrumentBoardFit.Spacing(width: width)
        let unit = InstrumentBoardFit.unit(fit.board, width: width)
        ZStack(alignment: .topLeading) {
            ForEach(Array(fit.board.spots.enumerated()), id: \.offset) { _, spot in
                let frame = InstrumentBoardFit.frame(spot, unit: unit, gap: spacing.gap)
                key(spot, marks: marks, unit: unit, spacing: spacing, scale: fit.scale)
                    .frame(width: max(0, frame.width), height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .zIndex(spot.code != nil && spot.code == picked ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: InstrumentBoardFit.height(fit.board, gap: spacing.gap),
               maxHeight: InstrumentBoardFit.height(fit.board, gap: spacing.gap), alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func key(_ spot: BindsKeyboard.Spot, marks: InstrumentBoardFit.Marks, unit: CGFloat, spacing: InstrumentBoardFit.Spacing,
                     scale: CGFloat) -> some View {
        let action = spot.code.flatMap { binds.bound[$0]?.first }
        let info = action.flatMap { binds.infos[$0] }
        let hyper = BindsKeyboard.isLayerKey(spot, layerKeys: layerKeys, layer: layer)
        let held = !hyper && BindsKeyboard.isHeld(spot, layer: layer)
        // A bind Pilot does not know draws free, as today's board does.
        let kind: InstrumentBoardKey.Kind = hyper ? .hyper : held ? .held : spot.code == nil ? .modifier : info == nil ? .free : .bound
        let shows = marks.shows(spot)
        let cap = InstrumentBoardKey(
            legend: BindsKeyboard.printed(spot), name: hyper ? "Hyper" : shows.name, glyph: shows.glyph, centred: shows.centred, kind: kind,
            picked: spot.code != nil && spot.code == picked,
            group: tinted && kind == .bound ? action.map(binds.module) : nil,
            dimmed: module != nil && kind == .bound && action.map(binds.module) != module,
            least: scale, function: spot.onFunctionRow, spacing: spacing,
            notch: spot.isoReturn ? KeyShape.Notch(step: unit * 0.25, upper: InstrumentBoardFit.key) : nil)
        return Group {
            if let code = spot.code {
                Button { pick(code) } label: { cap }
                    .buttonStyle(.plain)
                    .opensOnDoubleClick { open(code) }
                    .help(info?.label ?? "")
                    .accessibilityLabel(info.map { "\(spot.legend): \($0.label)" } ?? "\(spot.legend): free")
                    .accessibilityAddTraits(code == picked ? .isSelected : [])
            } else {
                cap.accessibilityLabel(hyper ? "Hyper: \(layerKeys.label)" : spot.legend)
            }
        }
    }
}

extension View {
    /// A double-click runs `open` (Bind editor T3): a count-2 tap simultaneous with the button under it, so the first
    /// click still picks at once, with no wait to see whether a second follows.
    func opensOnDoubleClick(_ open: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture(count: 2).onEnded(open))
    }
}

/// Where Instrument's board puts its keys (the mockup's 52 pt keys, 30 pt function row and 5 pt gaps, tighter on a
/// narrow board) and whether its names fit: the 75 % board while every name fits its key whole, on two lines at most (one
/// on the function row), at the key name's size or with a name too long for its key a little smaller (`gentle`); else the
/// board in two halves, its keys twice as wide; where not even that holds a long one-word name (the least window's board),
/// that name shrinks on its key, never under `leastScale`, rather than lose its end. Only the names that need it shrink.
@MainActor
struct InstrumentBoardFit {
    let board: BindsKeyboard.Board
    /// The least a name on this board is drawn at, of its size.
    var scale: CGFloat = 1

    static let key: CGFloat = 52, function: CGFloat = 30, between: CGFloat = 16
    static let gentle: CGFloat = 0.9, leastScale: CGFloat = 0.7

    /// The gap between keys and a key's sides inside its hairline: the mockup's 5, 6 and 5 (`.k`); 4, 4 and 3 on a board
    /// under 600 pt, so its split keys hold their names.
    struct Spacing: Equatable {
        let gap: CGFloat, leading: CGFloat, trailing: CGFloat
        init(width: CGFloat) {
            let wide = width >= 600
            gap = wide ? 5 : 4
            leading = wide ? 6 : 4
            trailing = wide ? 5 : 3
        }
    }
    /// A name's air inside its room, so one that fits by a hair never meets the key's edge.
    static let air: CGFloat = 1

    /// What each key says beyond its legend, the same on the whole board and its halves: an app's icon alone (centred)
    /// on a key a key and a half wide or less, else the glyph at the top right and the name at the foot; on the function
    /// row the glyph, or the name where the key has none.
    struct Marks {
        let names: [Int64: String]
        let glyphs: [Int64: BoardKey.Glyph]
        /// Each key's width on the 75 % board, which says whether it holds an app's icon beside a name.
        let widths: [Int64: Double]

        /// The tab's: each bound key's short name and its picture where no other key shows the same; a key whose bind
        /// Pilot does not know says nothing, drawn free.
        @MainActor init(_ binds: HomeBinds, boards: KeyboardCaptions.Boards) {
            self.init(names: binds.names.filter { binds.infos[binds.bound[$0.key]?.first ?? ""] != nil },
                      glyphs: binds.pictures(on: boards.compact.codes), compact: boards.compact)
        }

        init(names: [Int64: String], glyphs: [Int64: BoardKey.Glyph], compact: BindsKeyboard.Board) {
            self.names = names
            self.glyphs = glyphs.filter { names[$0.key] != nil }
            widths = Dictionary(compact.spots.compactMap { s in s.code.map { ($0, s.width) } }, uniquingKeysWith: { a, _ in a })
        }

        func shows(_ spot: BindsKeyboard.Spot) -> (name: String?, glyph: BoardKey.Glyph?, centred: Bool) {
            guard let code = spot.code, let name = names[code] else { return (nil, nil, false) }
            let glyph = glyphs[code]
            if case .image? = glyph, (widths[code] ?? 1) <= 1.5 { return (nil, glyph, true) }
            if spot.onFunctionRow, glyph != nil { return (nil, glyph, false) }
            return (name, glyph, false)
        }
    }

    /// The board and whether its names shrink, for keys `width` wide in all.
    /// `whole` keeps the 75 % board, its names at the least scale, where it would split.
    static func best(_ marks: Marks, boards: KeyboardCaptions.Boards, width: CGFloat, measure: (String) -> CGFloat, whole: Bool = false) -> InstrumentBoardFit {
        for board in whole ? [boards.compact] : [boards.compact, boards.split] {
            let rooms = rooms(marks, on: board, width: width)
            if let scale = [1, gentle].first(where: { fits(rooms, measure: measure, scale: $0) }) { return InstrumentBoardFit(board: board, scale: scale) }
        }
        return InstrumentBoardFit(board: whole ? boards.compact : boards.split, scale: leastScale)
    }

    static func fits(_ rooms: [(name: String, room: CGFloat, lines: Int)], measure: (String) -> CGFloat, scale: CGFloat = 1) -> Bool {
        rooms.allSatisfy { (lines($0.name, room: $0.room / scale, measure: measure) ?? .max) <= $0.lines }
    }

    /// Every named key on `board`: its name, the room its key gives it and how many lines it may take.
    static func rooms(_ marks: Marks, on board: BindsKeyboard.Board, width: CGFloat) -> [(name: String, room: CGFloat, lines: Int)] {
        let unit = unit(board, width: width), spacing = Spacing(width: width)
        return board.spots.compactMap { spot in
            marks.shows(spot).name.map {
                ($0, frame(spot, unit: unit, gap: spacing.gap).width - spacing.leading - spacing.trailing - (spot.isoReturn ? unit * 0.25 : 0),
                 spot.onFunctionRow ? 1 : 2)
            }
        }
    }

    /// The lines `text` wraps to in `room`, word by word; nil when one word alone is wider than the room.
    static func lines(_ text: String, room: CGFloat, measure: (String) -> CGFloat) -> Int? {
        var lines = 1, line: CGFloat = 0
        let space = measure(" ")
        for word in text.split(separator: " ").map(String.init) {
            let w = measure(word)
            guard w + air <= room else { return nil }
            if line > 0, line + space + w + air > room { lines += 1; line = w } else { line += (line > 0 ? space : 0) + w }
        }
        return lines
    }

    /// A text's width in `role`'s face at its size with its tracking; measured once per text and role.
    static func measure(_ role: TypeRole) -> (String) -> CGFloat {
        let font = StyleTokens.nsFont(role)
        return { text in
            let id = Measured(text: text, size: role.size, tracking: role.tracking, face: String(describing: role.face))
            if let w = measured[id] { return w }
            let w = (text as NSString).size(withAttributes: [.font: font]).width + CGFloat(role.size * role.tracking) * CGFloat(text.count)
            measured[id] = w
            return w
        }
    }
    private struct Measured: Hashable { let text: String, size: Double, tracking: Double, face: String }
    private static var measured: [Measured: CGFloat] = [:]

    /// The width one key unit takes on `board` drawn `width` wide: the key and the gap after it.
    static func unit(_ board: BindsKeyboard.Board, width: CGFloat) -> CGFloat { max(0, width + Spacing(width: width).gap) / board.width }

    static func frame(_ spot: BindsKeyboard.Spot, unit: CGFloat, gap: CGFloat) -> CGRect {
        let rows = BindsKeyboard.Board.rowsPerHalf
        let row = spot.row % rows, top = CGFloat(spot.row / rows) * (half(gap) + between)
        let y = top + (row == 0 ? 0 : function + gap + CGFloat(row - 1) * (key + gap))
        let height = row == 0 ? function : spot.isoReturn ? 2 * key + gap : key
        return CGRect(x: spot.x * unit, y: y, width: spot.width * unit - gap, height: height)
    }

    /// One half's height: the function row and five rows.
    static func half(_ gap: CGFloat) -> CGFloat { function + 5 * (key + gap) }
    static func height(_ board: BindsKeyboard.Board, gap: CGFloat) -> CGFloat { CGFloat(board.halves) * half(gap) + CGFloat(board.halves - 1) * between }
}

/// One Instrument key: a hairline cap, raised while bound; its legend top left, its glyph top right, its name at its foot
/// (an app's icon centred instead), filled in its module's colour with that colour's ink where `group` is set; the picked
/// key ringed in the signal colour with its soft halo.
struct InstrumentBoardKey: View {
    enum Kind: Equatable { case free, modifier, held, hyper, bound }
    @Environment(\.style) private var style
    let legend: String
    let name: String?
    let glyph: BoardKey.Glyph?
    var centred = false
    let kind: Kind
    let picked: Bool
    /// The bound key's module, whose colour fills it (StyleColors.groups); nil draws it plain.
    var group: Int?
    var dimmed = false
    var least: CGFloat = 1
    var function = false
    var spacing = InstrumentBoardFit.Spacing(width: 600)
    var notch: KeyShape.Notch?
    @State private var hovered = false

    var body: some View {
        let shape = KeyShape(radius: style.radii.key, notch: notch)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    if kind == .bound {
                        // --key-shadow: the key's edge under it.
                        ForEach(Array(style.depth.boardKey.shadows.enumerated()), id: \.offset) { _, s in
                            shape.fill(Color(s.color)).offset(y: s.y)
                        }
                    }
                    shape.fill(fill)
                    if hovered && !picked && kind != .hyper { shape.fill(style.color(\.line)) }
                }
            }
            .overlay { if let ring { shape.strokeBorder(ring) } }
            .overlay {
                if picked {
                    shape.strokeBorder(style.color(\.accent), lineWidth: 1.5)
                    KeyShape(radius: style.radii.key + 3, notch: notch.map { .init(step: $0.step, upper: $0.upper + 3) })
                        .stroke(style.color(\.accentSoft), lineWidth: 3).padding(-1.5)
                }
            }
            .opacity(dimmed ? 0.38 : 1)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }

    @ViewBuilder private var content: some View {
        if function {
            HStack(spacing: 4) {
                legendText
                Spacer(minLength: 2)
                if let glyph { picture(glyph, side: InstrumentBoardKey.small) } else if let name { nameText(lines: 1) }
            }
            .padding(.horizontal, 7)
            .frame(maxHeight: .infinity)
        } else if centred, let glyph {
            ZStack(alignment: .topLeading) {
                legendText.padding(.top, 6).padding(.leading, spacing.leading)
                picture(glyph, side: InstrumentBoardKey.large).frame(maxWidth: .infinity, maxHeight: .infinity).padding(.top, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 3) {
                    legendText
                    Spacer(minLength: 0)
                    if let glyph { picture(glyph, side: InstrumentBoardKey.small).padding(.top, -1) }
                }
                Spacer(minLength: 0)
                if let name { nameText(lines: 2).padding(.leading, notch?.step ?? 0) }
            }
            .padding(.top, 6).padding(.bottom, 6)
            .padding(.leading, spacing.leading).padding(.trailing, spacing.trailing)
        }
    }

    /// An app icon's side at the top right, and centred on a key it has alone.
    static let small: CGFloat = 17, large: CGFloat = 26

    private var legendText: some View {
        InstrumentLegend(text: legend).foregroundStyle(style.color(ink(kind == .bound ? \.text2 : \.text3))).lineLimit(1).fixedSize()
    }

    private func nameText(lines: Int) -> some View {
        Text(name ?? "").styleText(\.keyName).foregroundStyle(style.color(ink(\.text)))
            .lineLimit(lines).minimumScaleFactor(least).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func picture(_ glyph: BoardKey.Glyph, side: CGFloat) -> some View {
        switch glyph {
        case .image(let image): Image(nsImage: image).resizable().interpolation(.high).frame(width: side, height: side).accessibilityHidden(true)
        case .symbol(let symbol): Image(systemName: symbol).font(style.font(\.icon)).foregroundStyle(style.color(ink(\.text2))).accessibilityHidden(true)
        }
    }

    /// `role`, or the ink on the layer key's fill, on a held modifier's and on a module's colour.
    private func ink(_ role: KeyPath<StyleColors, Paint>) -> KeyPath<StyleColors, Paint> {
        switch kind {
        case .hyper: \.onAccent
        case .held: \.onHyper
        case .bound where group != nil: role == \.text ? \.onGroup : \.onGroup2
        default: role
        }
    }

    private var fill: Color {
        switch kind {
        case .bound: group.map { Color(style.colors.groups[$0 % style.colors.groups.count]) } ?? style.color(\.key)
        case .hyper: style.color(\.accent)
        case .held: style.color(\.hyper)
        case .free, .modifier: style.color(\.keyFree)
        }
    }

    /// A bound key's ring is its depth's; a free one's the faint hairline; the layer key has none.
    private var ring: Color? {
        switch kind {
        case .bound: style.depth.boardKey.ring.map(Color.init)
        case .hyper: nil
        case .held: style.color(\.accentLine)
        case .free, .modifier: style.color(\.keyRing)
        }
    }
}

/// A key's legend in the key face; a sign the mono face lacks (⌦, the arrows) as its line icon at the face's size.
struct InstrumentLegend: View {
    @Environment(\.style) private var style
    let text: String

    var body: some View {
        if let symbol = InstrumentKey.symbols[text] {
            Image(systemName: symbol).font(.system(size: style.type.key.size, weight: .medium)).accessibilityLabel(text)
        } else {
            Text(text).styleText(\.key)
        }
    }
}
