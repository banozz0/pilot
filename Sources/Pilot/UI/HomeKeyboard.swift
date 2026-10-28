import AppKit
import PilotCore
import SwiftUI

// What Home's and Binds' boards read (card agent-bo-95422992, mockup vg74ARspzoo direction B; Sven kept the short names on
// the keys): each bound key's kind, short name and picture, and how a board holds the names.

/// What Home shows of the Hyper binds (Binds of any tab's, card agent-bo-95423023): each board key's actions, and each
/// action's short name, kind and picture.
@MainActor
struct HomeBinds {
    let bound: [Int64: [String]]
    let infos: [String: BindsPage.ActionInfo]
    /// Each bound key's short name, the one its key shows, by key code.
    private(set) var names: [Int64: String] = [:]
    private let engine: Engine
    /// Each role's action and the app it opens today (Terminal is Ghostty here).
    private let roles: [String: String]

    /// `pictures` false skips the role apps, which only pictures need (a list of binds draws none).
    init(engine: Engine, layer: BindsKeyboard.Layer = .hyper, pictures: Bool = true) {
        self.engine = engine
        bound = BindsKeyboard.bound(store: engine.binds.store, layer: layer)
        infos = Dictionary(engine.bindActions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        roles = pictures ? AppsModule.roleApps() : [:]
        names = bound.compactMapValues { actions in actions.first.map { self.short($0) } }
    }

    /// How many of the board's keys are bound.
    var taken: Int { BindsKeyboard.codes.filter { bound[$0] != nil }.count }

    /// Which of the six kinds `action` is coloured as.
    func module(_ action: String) -> Int { BindsKeyboard.module(infos[action]?.module ?? "") }

    /// "Terminal", "¾ left", "Work": a word or two that fits a key; read through `names`.
    private func short(_ action: String) -> String {
        BindsKeyboard.short(action, label: infos[action]?.label ?? action) { engine.presets.contents.name(for: $0) }
    }

    /// The app's own icon for a bind that opens an app; else the action's symbol, else its kind's.
    func glyph(_ action: String) -> BoardKey.Glyph { picture(action).glyph }

    /// `glyph`, with what it pictures: the app's bundle or the symbol's name, so two keys showing one picture are found.
    func picture(_ action: String) -> (id: String, glyph: BoardKey.Glyph) {
        if let bundle = AppsModule.bundle(in: action) ?? roles[action], let icon = AppsModule.icon(bundle: bundle) { return (bundle, .image(icon)) }
        var symbol = Self.symbols[action] ?? Self.moduleSymbols[module(action) % Self.moduleSymbols.count]
        if action.hasPrefix("workspaces.go:"), let n = Int(action.dropFirst("workspaces.go:".count)), (0...50).contains(n) { symbol = "\(n).square" }
        return (symbol, .symbol(symbol))
    }

    /// The pictures of the binds on `codes`, by key code, leaving out any two keys share: a picture on two keys says
    /// nothing, so neither shows it (card agent-bo-95423023).
    func pictures(on codes: Set<Int64>) -> [Int64: BoardKey.Glyph] {
        Self.unique(bound.filter { codes.contains($0.key) }.compactMapValues { $0.first.map(picture) })
    }

    static func unique(_ pictures: [Int64: (id: String, glyph: BoardKey.Glyph)]) -> [Int64: BoardKey.Glyph] {
        let counts = Dictionary(pictures.values.map { ($0.id, 1) }, uniquingKeysWith: +)
        return pictures.compactMapValues { counts[$0.id] == 1 ? $0.glyph : nil }
    }

    /// Built-in actions' symbols, the mockup's Tabler icons in SF Symbols.
    static let symbols: [String: String] = [
        "system.lock": "lock", "system.lockKeyboard": "lock.rectangle", "apps.emoji": "face.smiling", "apps.clipboard": "list.clipboard", "apps.launcher": "command",
        "engine.sheet": "keyboard", "apps.terminal": "terminal", "apps.files": "folder",
        "apps.passwords": "key", "apps.editor": "chevron.left.forwardslash.chevron.right",
        "captures.area": "crop", "captures.fullscreen": "rectangle.dashed", "captures.ocr": "text.viewfinder",
        "captures.scrolling": "arrow.down.to.line.compact",
        "windows.close": "xmark", "windows.focusNext": "arrow.left.arrow.right", "windows.growWidth": "arrow.left.and.right",
        "windows.shrinkWidth": "arrow.right.and.line.vertical.and.arrow.left", "windows.firstThreeQuarters": "rectangle.lefthalf.inset.filled",
        "windows.lastQuarter": "rectangle.righthalf.inset.filled", "windows.flipSplit": "arrow.left.arrow.right.square",
        "windows.cycleColumnWidth": "arrow.left.and.right.square", "windows.cycleColumnWidthBack": "arrow.uturn.left.square",
        "windows.centreColumn": "align.horizontal.center", "windows.maximiseColumn": "arrow.up.left.and.arrow.down.right.square",
        "windows.leaveStack": "square.split.2x1",
        "windows.focusLeft": "arrow.left", "windows.focusRight": "arrow.right", "windows.focusUp": "arrow.up", "windows.focusDown": "arrow.down",
        "workspaces.former": "arrow.uturn.backward",
        "media.playPause": "playpause", "media.next": "forward", "media.previous": "backward", "media.mute": "speaker.slash",
        "media.volumeUp": "speaker.plus", "media.volumeDown": "speaker.minus",
    ]
    /// Apps, Windows, Workspaces, Captures, System, Pilot.
    static let moduleSymbols = ["app", "macwindow", "square.grid.2x2", "camera.viewfinder", "gearshape", "scope"]
}

/// How Home's board holds its names (Moody's AC1, card agent-bo-95422992): every short name whole and at one size for
/// the whole board, never shrunk key by key or cut short. The whole board at the largest size every name fits its key
/// at; when not even the smallest fits, the board splits into its two halves, one over the other, so each key is twice
/// as wide (at 760 pt); names give way to the colour alone only when neither holds them.
struct BoardFit: Equatable {
    enum Shape { case whole, split }
    var shape: Shape
    /// The names' one size; nil hides them, and each key says what it does by its colour, tooltip and inspector.
    var size: CGFloat?

    /// A key on the board: Binds' cap, at its width in key units on this board.
    struct Key {
        let cap: BindsKeyboard.Cap
        let width: Double
    }

    /// The room between a split board's halves, beyond the keys' gap.
    static let between: CGFloat = 8
    /// The widest a split board's one-wide key grows, so on a wide block its keys keep a key's proportions.
    static let widestUnit: CGFloat = 76

    /// Binds' five rows.
    static let wholeRows = BindsKeyboard.rows.map { $0.map { Key(cap: $0, width: $0.width) } }
    /// The halves, split as a Kinesis is: Esc to 5, Tab to T, Hyper to G and Shift to B on the left, Esc, Tab, Hyper and
    /// Shift two wide; 6 to =, Y to ], H to Return and N to Shift on the right, Return and Shift two wide; Space across.
    /// Seven units a row, so both halves are one width.
    static let splitRows: [[Key]] = {
        let rows = BindsKeyboard.rows.dropLast()
        let left = rows.map { $0.prefix(6).enumerated().map { i, cap in Key(cap: cap, width: i == 0 ? 2 : 1) } }
        let right = rows.map { $0.dropFirst(6).map { Key(cap: $0, width: $0.width > 1 ? 2 : 1) } }
        return left + right + [(BindsKeyboard.rows.last ?? []).map { Key(cap: $0, width: 7) }]
    }()

    static func rows(_ shape: Shape) -> [[Key]] { shape == .whole ? wholeRows : splitRows }

    /// Each row's one-wide key, so every row fills the board as Binds' do; a split board no wider than `widestUnit` keys.
    static func units(_ shape: Shape, width: CGFloat, gap: CGFloat) -> [CGFloat] {
        let rows = rows(shape)
        let span = rows.map { $0.reduce(0) { $0 + CGFloat($1.width) } }.max() ?? 1
        let most = CGFloat(rows.map(\.count).max() ?? 1)
        let board = shape == .whole ? width : min(width, widestUnit * span + gap * (most - 1))
        return rows.map { row in max(0, (board - gap * CGFloat(row.count - 1)) / row.reduce(0) { $0 + CGFloat($1.width) }) }
    }

    /// The board's height: its rows of keys `key` tall, and the room between a split board's halves.
    func height(key: CGFloat, gap: CGFloat) -> CGFloat {
        let rows = CGFloat(Self.rows(shape).count)
        return rows * (key + gap) - gap + (shape == .split ? Self.between : 0)
    }
}
