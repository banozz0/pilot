import Carbon
import PilotCore
import SwiftUI

/// Binds as a keyboard (design round 4, card agent-bo-95422894): the sublayer tabs with Plain last, the keyboard with
/// each key coloured by what its bind does, the clicked key's inspector (rebind, clear, or bind a free key); Show as list
/// opens the full list (search, filters, Reset per bind). Toybox and Instrument draw their own page and list on this
/// page's state, keys and dialogs (ADR 0008; `Acts`).
struct BindsKeyboardPage: View {
    @Environment(Engine.self) private var engine
    @Environment(\.style) private var style
    /// The window's search: a search lists, the keyboard waits.
    let search: String
    /// Plain combos asked for by a link or the window's search.
    let startOnPlain: Bool
    /// An action whose bind editor opens at once (the menu's Set Hyper bind), cleared as it opens.
    let editBind: Binding<String?>
    let go: (AppPlace) -> Void

    /// The layer the keyboard and its lists show, the one asked for from the first frame, so the tabs open on it rather
    /// than slide to it.
    @State private var layer: BindsKeyboard.Layer

    init(search: String, startOnPlain: Bool = false, editBind: Binding<String?> = .constant(nil), go: @escaping (AppPlace) -> Void) {
        self.search = search
        self.startOnPlain = startOnPlain
        self.editBind = editBind
        self.go = go
        _layer = State(initialValue: startOnPlain ? .plain : .hyper)
    }
    /// The key picked on a tab; another tab shows its own first pick.
    @State private var picked: (layer: BindsKeyboard.Layer, code: Int64)?
    @FocusState private var boardFocused: Bool
    @State private var asList = false
    @State private var editing: BindEditing?
    @State private var switchingTo: BindStore.Preset?
    @State private var confirmingResetAll = false
    @State private var refusal: String?
    /// The Mac's keyboard as Binds draws it, read again when the keyboard layout changes.
    @State private var board = KeyboardCaptions.current

    var body: some View {
        // The tab's binds once a pass: each key's actions, names and pictures (card agent-bo-95423023).
        let toybox = style.kind == .toybox
        let listed = asList || !search.trimmingCharacters(in: .whitespaces).isEmpty
        let binds = HomeBinds(engine: engine, layer: layer, pictures: !listed)
        let bound = binds.bound
        let key = (picked?.layer == layer ? picked?.code : nil) ?? Self.firstPick(bound, board: board.full)
        let only: BindsPage.Tab? = layer == .plain && asList ? .plain : nil, back = search.isEmpty ? { asList = false } : nil
        Group {
            if listed && toybox {
                ToyBindsList(only: only, seed: search, back: back)
            } else if listed {
                InstrumentBindsList(only: only, seed: search, back: back)
            } else {
                boardKeys(Group {
                    if toybox { toy(binds, key: key) } else { instrument(binds, key: key) }
                }, bound: bound, key: key)
            }
        }
        .onChange(of: startOnPlain) { if startOnPlain { layer = .plain } }
        .onChange(of: editBind.wrappedValue, initial: true) {
            guard let action = editBind.wrappedValue else { return }
            editing = .init(action: action)
            editBind.wrappedValue = nil
        }
        // A Hyper press picks its key while the board shows in the window in front (card agent-bo-95422993, G5).
        .modifier(PicksKeys(when: !listed && editing == nil, engine: engine, pick: pick))
        .onReceive(DistributedNotificationCenter.default().publisher(for: Self.inputSourceChanged)) { _ in board = KeyboardCaptions.reload() }
        .bindsDialogs(editing: $editing, switchingTo: $switchingTo, confirmingResetAll: $confirmingResetAll, refusal: $refusal)
        .presetDialogs()
    }

    /// A plain combo's macOS-shadow warning (section 7: it stays on the row); nil for a Hyper bind.
    static func warning(for action: String, store: BindStore) -> String? {
        store.trigger(for: action).flatMap(PlainComboShadow.warning)
    }

    /// A bind's keys after Hyper's, as Toybox's and Instrument's big caps show them: the tab's modifiers and the key as `board`
    /// prints it; a plain combo's own modifiers and the key.
    static func capParts(_ key: Int64, action: String?, layer: BindsKeyboard.Layer, store: BindStore, board: BindsKeyboard.Board) -> [String] {
        let name = board.caption(key)
        guard layer != .plain else {
            return (action.flatMap { store.trigger(for: $0) }.map { Array($0.label.split(separator: "+").map(String.init).dropLast()) } ?? []) + [name]
        }
        return (layer.sublayer.map { $0.title.split(separator: "+").dropFirst().map(String.init) } ?? []) + [name]
    }

    /// macOS's word that the keyboard layout changed.
    static let inputSourceChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    /// The key picked first: B when it is bound, as the artifact shows, else the first bound key on the board, row by row.
    static func firstPick(_ bound: [Int64: [String]], board: BindsKeyboard.Board = .init(.ansi)) -> Int64? {
        if let b = KeyNames.code(for: "B"), bound[b] != nil { return b }
        return board.spots.compactMap(\.code).first { bound[$0] != nil } ?? KeyNames.code(for: "B")
    }

    /// What Toybox's and Instrument's pages' buttons do: this page's state and dialogs, so picking, binding, clearing,
    /// presets and the list behave alike in both.
    struct Acts {
        let pick: (Int64) -> Void
        /// Shows a tab with a key picked on it.
        let show: (BindsKeyboard.Layer, Int64) -> Void
        let edit: (BindEditing) -> Void
        let clear: (String) -> Void
        let reset: (String) -> Void
        let switchTo: (BindStore.Preset) -> Void
        let resetAll: () -> Void
        let showList: () -> Void
        let go: (AppPlace) -> Void
    }

    private var acts: Acts {
        Acts(pick: { picked = (layer, $0); boardFocused = true }, show: { layer = $0; picked = ($0, $1); boardFocused = true },
             edit: { editing = $0 }, clear: clear, reset: reset, switchTo: { switchingTo = $0 }, resetAll: { confirmingResetAll = true },
             showList: { asList = true }, go: go)
    }

    /// Toybox (card agent-bo-95423182): its own page on this page's state, dialogs and keys.
    private func toy(_ binds: HomeBinds, key: Int64?) -> some View {
        ToyBindsPage(binds: binds, key: key, layer: $layer, boards: board, refusal: refusal, acts: acts)
    }

    /// Instrument (card agent-bo-95423181): its own page on this page's state, dialogs and keys.
    private func instrument(_ binds: HomeBinds, key: Int64?) -> some View {
        InstrumentBindsPage(binds: binds, key: key, layer: $layer, boards: board, refusal: refusal, acts: acts)
    }

    /// A free key's bind starts from it on this tab's sublayer; nil on Plain.
    private func startKey(_ code: Int64) -> Key? { layer.sublayer.map { Key(keyCode: code, modifiers: $0.modifiers) } }

    /// A Hyper press: its tab and its key.
    private func pick(_ key: Key) {
        let layer = BindsKeyboard.Layer(hyper: key) ?? layer
        self.layer = layer
        picked = (layer, key.keyCode)
        boardFocused = true
    }

    /// Return and Delete act on the picked key, as the inspector's ↵ and ⌫ say (card agent-bo-95422993, G4), while the
    /// board has the focus: a click on a key or a Hyper press gives it.
    private func boardKeys(_ board: some View, bound: [Int64: [String]], key: Int64?) -> some View {
        board
            .focusable()
            .focused($boardFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.return, .delete, .deleteForward]) { press in
                guard let command = BindsKeyboard.Command(returnKey: press.key == .return, picked: key, bound: bound) else { return .ignored }
                switch command {
                case .rebind(let action): editing = .init(action: action)
                case .bind(let code): editing = .init(action: nil, startKey: startKey(code))
                case .clear(let action): clear(action)
                }
                return .handled
            }
    }

    private func clear(_ action: String) {
        do { try engine.binds.set(action, to: nil); refusal = nil } catch { refusal = BindsPage.refusal(error, actions: engine.bindActions) }
    }

    private func reset(_ action: String) {
        do { try engine.binds.reset(action); refusal = nil } catch { refusal = BindsPage.refusal(error, actions: engine.bindActions) }
    }
}

/// The board picks Hyper presses while it shows in the window in front, a bound one still running (T48); its own
/// modifier, so the window's focus changing redraws only this, never the board.
private struct PicksKeys: ViewModifier {
    @Environment(\.controlActiveState) private var active
    let when: Bool
    let engine: Engine
    let pick: (Key) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: when && active == .key, initial: true) { _, picks in engine.pickKeys(picks ? pick : nil) }
            .onDisappear { engine.pickKeys(nil) }
    }
}

/// Keys' More (simplify-pages T14; Overlay, Swap keys and Export and import were Binds' tabs): Swap keys, Export and
/// import, Cleaning, and what the overlay shows, longest last, each a place a link or the search lands on. Cleaning's Set
/// key opens the bind editor on the keyboard, as Launcher's Set key does, More having no editor of its own.
struct BindsMorePage: View {
    /// The window's search, which the overlay's list filters by.
    var search = ""
    /// Binds' editor on that action, on the keyboard.
    var editBind: (String) -> Void = { _ in }

    /// More's index. A row added to or moved off a block changes its count here; the overlay's list is one.
    static let entries = [
        MoreEntry(id: .keySwaps, symbol: "arrow.left.arrow.right", controls: 3),
        MoreEntry(id: .exportImport, symbol: "arrow.up.arrow.down", controls: 3),
        MoreEntry(id: .cleaning, symbol: "lock", controls: 2),
        MoreEntry(id: .overlay, symbol: "rectangle.grid.2x2", controls: 4),
    ]

    var body: some View {
        KitMore(entries: Self.entries) {
            KeySwapsBlock().moreBlock(.keySwaps)
            ExportImportRows().moreBlock(.exportImport)
            KeyboardLockCard { editing in editing.action.map(editBind) }.moreBlock(.cleaning)
            OverlayPicksBlocks(search: search)
        }
    }
}
