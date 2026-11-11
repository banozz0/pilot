import AppKit
import PilotCore
import SwiftUI

/// Binds' keyboard in Toybox (card agent-bo-95423182, mockup B binds.html): the Mac's 75 % board in its coloured keyboard
/// case, each key a keycap with its legend top left, its bind's short name at its foot and its picture top right, filled
/// with its module's soft colour; a free key the free colour, the layer key the sun Hyper key with the Pilot mark, the
/// tab's held modifiers sun too, the picked key ringed in sun. A board too narrow for every name splits in two halves, one
/// over the other, as today's does.
struct ToyBindsBoard: View {
    @Environment(\.style) private var style
    let boards: KeyboardCaptions.Boards
    let binds: HomeBinds
    let layerKeys: [LayerKey]
    let layer: BindsKeyboard.Layer
    let picked: Int64?
    let pick: (Int64) -> Void
    /// A double-click on a key: its bind, or a new bind on it (`BindsKeyboardPage.Acts.open`); nothing on Home.
    var open: (Int64) -> Void = { _ in }
    /// The 75 % board kept whole, its names shrunk, where it would split (Home's board beside the column).
    var whole = false
    /// The case's whole width, which its paddings and so the keys' room follow from.
    @State private var width: CGFloat = 0

    var body: some View {
        let spacing = ToyBoardFit.Spacing(width: width)
        let inner = spacing.inner(width, outline: style.depth.board.outline)
        let fit = ToyBoardFit.best(names: binds.names, boards: boards, width: inner, spacing: spacing, whole: whole)
        let unit = ToyBoardFit.unit(fit.board, width: inner, spacing: spacing)
        let glyphs = binds.pictures(on: fit.board.codes)
        ZStack(alignment: .topLeading) {
            ForEach(Array(fit.board.spots.enumerated()), id: \.offset) { _, spot in
                let frame = ToyBoardFit.frame(spot, unit: unit, spacing: spacing)
                key(spot, frame: frame, unit: unit, fit: fit, spacing: spacing, glyphs: glyphs)
                    .frame(width: max(0, frame.width), height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .zIndex(spot.code != nil && spot.code == picked ? 1 : 0)
            }
        }
        .frame(width: max(0, inner), height: ToyBoardFit.height(fit.board, spacing: spacing), alignment: .topLeading)
        .padding(spacing.well)
        .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(style.color(\.sunken)) }
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(style.color(\.outline), lineWidth: style.depth.board.outline) }
        .padding(EdgeInsets(top: spacing.case, leading: spacing.case, bottom: spacing.case + 2, trailing: spacing.case))
        .styleSurface(\.board, fill: \.board, radius: \.board)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func key(_ spot: BindsKeyboard.Spot, frame: CGRect, unit: CGFloat, fit: ToyBoardFit, spacing: ToyBoardFit.Spacing,
                     glyphs: [Int64: BoardKey.Glyph]) -> some View {
        let action = spot.code.flatMap { binds.bound[$0]?.first }
        let info = action.flatMap { binds.infos[$0] }
        let hyper = BindsKeyboard.isLayerKey(spot, layerKeys: layerKeys, layer: layer)
        let held = !hyper && BindsKeyboard.isHeld(spot, layer: layer)
        let kind: ToyBoardKey.Kind = hyper ? .hyper : held ? .held : spot.code == nil ? .modifier
            : info.map { .bound(module: BindsKeyboard.module($0.module)) } ?? .free
        // A bind Pilot does not know draws free, as today's board does.
        let name = info == nil ? nil : spot.code.flatMap { binds.names[$0] }
        let legend = BindsKeyboard.printed(spot)
        let glyph = info == nil ? nil : spot.code.flatMap { glyphs[$0] }
        let notch = spot.isoReturn ? KeyShape.Notch(step: unit * 0.25, upper: ToyBoardFit.key) : nil
        // A name never breaks inside a word: drawn small enough that its longest word fits its key, or left to the key's
        // tip where none is (simplify-pages T14).
        let room = ToyBoardFit.room(spot, frame: frame, unit: unit, spacing: spacing)
        let nameSize = (hyper ? "Hyper" : name).flatMap { ToyBoardFit.wordSize($0, size: fit.size, room: room) }
        let shown = nameSize == nil ? nil : hyper ? "Hyper" : name
        let cap = ToyBoardKey(legend: legend, name: shown, kind: kind, picked: spot.code != nil && spot.code == picked,
                              size: fit.size, nameSize: nameSize, least: fit.shrinks ? ToyBoardFit.leastScale : 1, glyph: glyph,
                              mark: hyper && frame.width >= 100,
                              lines: spot.onFunctionRow ? 1 : 2, pad: spacing.pad, notch: notch)
        return Group {
            if let code = spot.code {
                Button { pick(code) } label: { cap }
                    .buttonStyle(.kitPress)
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

/// Where Toybox's board puts its keys and how big its names are: the 75 % board while every name fits its key whole, on one
/// or two lines (one on the function row), at one size for the board from 11.5 down to 10; else the board in two halves,
/// its keys twice as wide; where not even that holds a long one-word name, the name shrinks on its key, never under
/// `leastScale` of the size, rather than lose its end.
@MainActor
struct ToyBoardFit {
    let board: BindsKeyboard.Board
    let size: CGFloat
    var shrinks = false

    static let sizes: [CGFloat] = [11.5, 11, 10.5, 10]
    static let leastScale: CGFloat = 0.8
    /// A key's and the function row's height, and the room between a split board's halves.
    static let key: CGFloat = 64, function: CGFloat = 46, between: CGFloat = 16

    /// The case's padding round the well, the well's round the keys, the gap between keys and a key's own side padding:
    /// 14, 10, 7 and 6 on a wide page (the mockup's 18 and 12 less a little, so the page fits a 900 pt window); tighter
    /// on a narrow one, so its split keys hold their names.
    struct Spacing {
        let `case`: CGFloat, well: CGFloat, gap: CGFloat, pad: CGFloat
        init(width: CGFloat) {
            let wide = width >= 900
            `case` = wide ? 14 : 10
            well = wide ? 10 : 6
            gap = wide ? 7 : 5
            pad = wide ? 6 : 4
        }
        /// The keys' width in a case `width` wide: less the case's outline and padding, and the well's.
        func inner(_ width: CGFloat, outline: Double) -> CGFloat { width - 2 * (CGFloat(outline) + `case` + 2 + well) }
        /// A name's room is its key less the key's outline and side padding.
        var nameInset: CGFloat { 2 * 2 + 2 * pad }
    }
    static let legendSize: CGFloat = 13, glyphSize: CGFloat = 21

    /// The board and size for `names` on keys `width` wide; with no names, the 75 % board.
    /// `whole` keeps the 75 % board, its names at the least size, where it would split.
    static func best(names: [Int64: String], boards: KeyboardCaptions.Boards, width: CGFloat, spacing: Spacing, whole: Bool = false) -> ToyBoardFit {
        for board in whole ? [boards.compact] : [boards.compact, boards.split] {
            let rooms = rooms(names, on: board, width: width, spacing: spacing)
            if let size = sizes.first(where: { fits(rooms, size: $0) }) { return ToyBoardFit(board: board, size: size) }
        }
        return ToyBoardFit(board: whole ? boards.compact : boards.split, size: sizes[sizes.count - 1], shrinks: true)
    }

    /// The width one key unit takes on `board` drawn `width` wide: the key and the gap after it.
    static func unit(_ board: BindsKeyboard.Board, width: CGFloat, spacing: Spacing) -> CGFloat { max(0, width + spacing.gap) / board.width }

    static func frame(_ spot: BindsKeyboard.Spot, unit: CGFloat, spacing: Spacing) -> CGRect {
        let rows = BindsKeyboard.Board.rowsPerHalf, gap = spacing.gap
        let row = spot.row % rows, top = CGFloat(spot.row / rows) * (half(spacing) + between)
        let y = top + (row == 0 ? 0 : function + gap + CGFloat(row - 1) * (key + gap))
        let height = row == 0 ? function : spot.isoReturn ? 2 * key + gap : key
        return CGRect(x: spot.x * unit, y: y, width: spot.width * unit - gap, height: height)
    }

    /// One half's height: the function row and five rows.
    static func half(_ spacing: Spacing) -> CGFloat { function + 5 * (key + spacing.gap) }
    static func height(_ board: BindsKeyboard.Board, spacing: Spacing) -> CGFloat {
        CGFloat(board.halves) * half(spacing) + CGFloat(board.halves - 1) * between
    }

    /// Every named key on `board`, its name, the room its key gives it and how many lines it may take.
    static func rooms(_ names: [Int64: String], on board: BindsKeyboard.Board, width: CGFloat, spacing: Spacing) -> [(name: String, room: CGFloat, lines: Int)] {
        let unit = unit(board, width: width, spacing: spacing)
        return board.spots.compactMap { spot in
            spot.code.flatMap { names[$0] }.map {
                ($0, room(spot, frame: frame(spot, unit: unit, spacing: spacing), unit: unit, spacing: spacing), spot.onFunctionRow ? 1 : 2)
            }
        }
    }

    /// The room a key `frame` gives its name: its width less its outline, its padding and an ISO Return's notch.
    static func room(_ spot: BindsKeyboard.Spot, frame: CGRect, unit: CGFloat, spacing: Spacing) -> CGFloat {
        frame.width - spacing.nameInset - (spot.isoReturn ? unit * 0.25 : 0)
    }

    /// The step a name's size takes: a name's size is one of a few, so a window resize makes no new font (DisplayFaces
    /// keeps every size it makes) and no new measure.
    static let wordStep: CGFloat = 0.25

    /// The size, at most `size` and on `wordStep`'s grid, at which `name`'s longest word fits `room` whole, so the whole
    /// board shrinks a name rather than break a word (simplify-pages T14, Sven's Q36); nil where even half of `size` cannot
    /// hold it, and the key shows its legend and picture alone, its name in its tip.
    static func wordSize(_ name: String, size: CGFloat, room: CGFloat) -> CGFloat? {
        let words = name.split(separator: " ").map(String.init)
        let fits = { (s: CGFloat) in words.allSatisfy { width($0, size: s) + air <= room } }
        // The face's widths are not linear in its size: start from the linear guess, on the grid, and step down until it
        // measures whole; never under half the size, nor measured there.
        guard !fits(size), let widest = words.map({ width($0, size: size) }).max(), widest > 0, room > air else { return room > air ? size : nil }
        var s = (min(size, size * (room - air) / widest) / wordStep).rounded(.down) * wordStep
        while s >= size / 2 && !fits(s) { s -= wordStep }
        return s >= size / 2 ? s : nil
    }

    static func fits(_ rooms: [(name: String, room: CGFloat, lines: Int)], size: CGFloat) -> Bool {
        rooms.allSatisfy { (lines($0.name, size: size, room: $0.room) ?? .max) <= $0.lines }
    }

    /// The lines `text` wraps to at `size` in `room`, word by word; nil when one word alone is wider than the room.
    static func lines(_ text: String, size: CGFloat, room: CGFloat) -> Int? {
        var lines = 1, line: CGFloat = 0
        let space = width(" ", size: size)
        for word in text.split(separator: " ").map(String.init) {
            let w = width(word, size: size)
            guard w + air <= room else { return nil }
            if line > 0, line + space + w + air > room { lines += 1; line = w } else { line += (line > 0 ? space : 0) + w }
        }
        return lines
    }

    /// A name's air inside its room, so one that fits by a hair never meets the key's edge.
    static let air: CGFloat = 1

    /// `text`'s width in the names' face, Nunito 800, at `size`; measured once per text and size.
    static func width(_ text: String, size: CGFloat) -> CGFloat {
        let id = Measure(text: text, size: size)
        if let w = measured[id] { return w }
        let w = (text as NSString).size(withAttributes: [.font: DisplayFaces.font(StyleTokens.nunito(800), size: size)]).width
        measured[id] = w
        return w
    }
    private struct Measure: Hashable { let text: String, size: CGFloat }
    private static var measured: [Measure: CGFloat] = [:]
}

/// One Toybox key: a keycap with an ink outline and a solid bottom edge (StyleDepths.boardKey), its legend top left, its
/// name at its foot, its picture top right; the picked key ringed in sun and lifted.
struct ToyBoardKey: View {
    enum Kind: Equatable { case free, modifier, held, hyper, bound(module: Int) }
    @Environment(\.style) private var style
    let legend: String
    let name: String?
    let kind: Kind
    let picked: Bool
    let size: CGFloat
    /// The name's size where its longest word needs it smaller than `size` (ToyBoardFit.wordSize).
    var nameSize: CGFloat?
    var least: CGFloat = 1
    var glyph: BoardKey.Glyph?
    var mark = false
    var lines = 2
    var pad: CGFloat = 6
    var notch: KeyShape.Notch?
    @State private var hovered = false

    var body: some View {
        let d = style.depth.boardKey, r = style.radii.key
        let outer = KeyShape(radius: r, notch: notch)
        let inner = KeyShape(radius: max(r - d.outline, 0), notch: notch.map { .init(step: $0.step, upper: $0.upper - 2 * d.outline) })
        let border = EdgeInsets(top: d.outline, leading: d.outline, bottom: d.edge, trailing: d.outline)
        VStack(alignment: .leading, spacing: 0) {
            // The picture only where it fits beside the whole legend.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    legendText.fixedSize()
                    Spacer(minLength: 3)
                    if let glyph { picture(glyph) }
                }
                legendText.fixedSize()
            }
            Spacer(minLength: 0)
            if let name {
                Text(name)
                    .font(ToyBindsFace.ui(800, nameSize ?? size)).tracking(-0.05)
                    .foregroundStyle(sun ? style.color(\.onHyper) : style.color(\.text))
                    .lineLimit(lines).minimumScaleFactor(least)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, notch?.step ?? 0)
            }
        }
        .padding(.top, lines == 1 ? 4 : 5).padding(.horizontal, pad).padding(.bottom, lines == 1 ? 3 : 5)
        .padding(border)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .trailing) { if mark { PilotMark(size: 34).padding(.trailing, 10).padding(.bottom, d.edge - d.outline) } }
        .background {
            ZStack {
                outer.fill(style.color(\.outline))
                inner.fill(fill).padding(border)
                if hovered && !picked { inner.fill(style.color(\.text).opacity(0.07)).padding(border) }
            }
        }
        .overlay {
            if picked {
                KeyShape(radius: r + 5, notch: notch.map { .init(step: $0.step, upper: $0.upper + 5) })
                    .stroke(style.color(\.accent), lineWidth: 4).padding(-5)
            }
        }
        .offset(y: picked ? -2 : 0)
        .onHover { hovered = $0 }
    }

    private var legendText: some View {
        return Text(legend)
            .font(ToyBindsFace.ui(800, kind == .modifier || kind == .held ? 12 : ToyBoardFit.legendSize))
            .foregroundStyle(sun ? style.color(\.onHyper) : kind == .free || kind == .modifier ? style.color(\.text3) : style.color(\.text))
            .opacity(kind == .free ? 0.8 : 1)
    }

    /// The layer key and the tab's held modifiers: sun caps.
    private var sun: Bool { kind == .hyper || kind == .held }

    private var fill: Color {
        switch kind {
        case .free: style.color(\.keyFree)
        case .modifier: style.color(\.panel)
        case .held, .hyper: style.color(\.hyper)
        case .bound(let module): Toy.moduleSoft(module, style)
        }
    }

    /// The app's own icon, else the action's symbol in the ink.
    @ViewBuilder private func picture(_ glyph: BoardKey.Glyph) -> some View {
        Group {
            switch glyph {
            case .image(let image): Image(nsImage: image).resizable().interpolation(.high).frame(width: ToyBoardFit.glyphSize, height: ToyBoardFit.glyphSize)
            case .symbol(let symbol):
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(style.dark ? style.color(\.text) : style.color(\.outline))
                    .frame(width: ToyBoardFit.glyphSize, height: ToyBoardFit.glyphSize)
            }
        }
        .padding(.top, -1)
        .accessibilityHidden(true)
    }
}

/// Toybox Binds' faces, made from the bundled files at a weight and size the tokens' roles do not name (the mockup's
/// 13.5 pt rows, its 11.5 pt counts).
@MainActor
enum ToyBindsFace {
    static func ui(_ weight: Int, _ size: CGFloat) -> Font { Font(DisplayFaces.font(StyleTokens.nunito(weight), size: size)) }
}
