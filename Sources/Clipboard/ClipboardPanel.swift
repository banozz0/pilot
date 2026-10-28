import AppKit
import Synchronization

/// What a key does in the clipboard panel (story 89, wireframe ol5Ak83dAho section 3). The digits act on rows only while
/// the search is empty; once something is typed they edit the search. Backspace only ever edits the search: Cmd or
/// Ctrl+Backspace deletes, typed or not (Sven, build 31: holding Backspace to clear a search went on deleting copies).
/// Shift+Up/Down and Cmd+A pick several rows, Cmd+Return one row at a time (Sven, 2026-10-08), which Return, Cmd+C,
/// Shift+Return, Cmd+Backspace and Cmd+P then act on together (card agent-bo-95422780). Plain arrows move the cursor
/// past the picks and keep them; Escape clears them first, then closes (Sven, 2026-10-21).
public enum PanelCommand: Equatable, Sendable {
    case paste(plain: Bool), copy, pasteRow(Int), move(Int), extend(Int), pickAll, togglePin, delete, cycleFilter(Int), close
    /// Cmd+T opens the tag field and Cmd+K the action list over the search (cards agent-bo-95422782 and 784); while
    /// one is open Return confirms, Escape or the same key leaves, the arrows choose, every other key types.
    case tag, actions, confirm, dismiss
    /// Cmd+S steps the sort, Cmd+Shift+S reverses it (card agent-bo-95422783).
    case cycleSort, reverseSort
    /// Option+Return pastes and deletes, with Shift as plain text (card agent-bo-95422784).
    case pasteAndDelete(plain: Bool)
    /// Cmd+Shift+Backspace deletes the open tag's tab, after asking (card agent-bo-95422986).
    case deleteTag
    /// Ctrl+Return pastes the picks one by one, each Cmd+V after giving the next (card agent-bo-95423071).
    case pasteInSequence
    /// Escape while rows are picked: the picks go, the panel stays (Sven, 2026-10-21).
    case clearPicks
    /// Cmd+/: every key in the panel's place, the foot holding only the most used (Sven, Q396); Cmd+/ or Escape shuts it.
    case keys
    /// Cmd+Return, or Cmd+click on a row: the row in or out of the picks, so rows apart can be picked (Sven, 2026-10-08).
    case togglePick
    /// Cmd+E on the Snippets tab: the Pilot window on Snippets (Sven, 2026-10-08).
    case editSnippets

    public enum Key: Equatable, Sendable { case up, down, left, right, `return`, escape, backspace, tab, character(Character) }

    /// nil: the key is not the panel's, so the search field gets it. `returnCopies` is Settings › Clipboard's
    /// "Return in the panel: Copy only", which swaps Return and Cmd+C. `textSelected`: text is selected in the search
    /// field, whose Cmd+C copies it.
    /// `editing`: the Edit text editor is open, where Return and the arrows edit and Cmd+Return saves.
    /// Left and Right step the tabs while the search is empty, or the caret sits at that end of the typed text with
    /// nothing selected (`caretAtStart`, `caretAtEnd`); anywhere else they move the caret (card agent-bo-95422970).
    /// `snippets`: the Snippets tab, where Return pastes even with Copy only and a copy's keys (pin, tag, pick, copy,
    /// sort, delete) do nothing (Sven, 2026-10-08). `picked`: rows are picked, so Escape clears them before it closes.
    /// `keysShown`: Cmd+/'s list of keys is open, so Escape shuts it first.
    public init?(key: Key, command: Bool = false, option: Bool = false, shift: Bool = false, control: Bool = false, returnCopies: Bool = false,
                 textSelected: Bool = false, prompting: Bool = false, editing: Bool = false, caretAtStart: Bool = false, caretAtEnd: Bool = false,
                 searchEmpty: Bool, snippets: Bool = false, picked: Bool = false, keysShown: Bool = false) {
        let returnCopies = returnCopies && !snippets
        if editing {
            switch key {
            case .return where command: self = .confirm
            case .escape: self = .dismiss
            default: return nil
            }
            return
        }
        if prompting {
            switch key {
            case .return: self = .confirm
            case .escape: self = .dismiss
            case .character("t") where command, .character("k") where command: self = .dismiss
            case .up: self = .move(-1)
            case .down: self = .move(1)
            default: return nil
            }
            return
        }
        switch key {
        case .return where control && !command && !option: self = .pasteInSequence
        case .return where option && !command: self = .pasteAndDelete(plain: shift)
        case .return where shift && !command: self = .paste(plain: true)
        case .return where command: self = .togglePick
        case .return: self = returnCopies ? .copy : .paste(plain: false)
        case .character("c") where command && !textSelected: self = returnCopies ? .paste(plain: false) : .copy
        case .escape: self = keysShown ? .keys : picked ? .clearPicks : .close
        case .character("/") where command: self = .keys
        case .tab: self = .cycleFilter(shift ? -1 : 1)
        case .left where !command && !option && !shift && (searchEmpty || caretAtStart): self = .cycleFilter(-1)
        case .right where !command && !option && !shift && (searchEmpty || caretAtEnd): self = .cycleFilter(1)
        case .up: self = shift ? .extend(-1) : .move(-1)
        case .down: self = shift ? .extend(1) : .move(1)
        case .backspace where command || control: self = command && shift ? .deleteTag : .delete
        case .character("p") where command: self = .togglePin
        case .character("a") where command: self = .pickAll
        case .character("t") where command: self = .tag
        case .character("k") where command: self = .actions
        case .character("e") where command && snippets: self = .editSnippets
        case .character("s") where command: self = shift ? .reverseSort : .cycleSort
        case .character(let c) where searchEmpty && !command:
            guard let n = c.wholeNumberValue, (1...9).contains(n) else { return nil }
            self = .pasteRow(n - 1)
        default: return nil
        }
        if snippets, !worksOnSnippets { return nil }
    }

    /// What the Snippets tab takes: a snippet is pasted, never pinned, tagged, picked, copied, sorted or deleted.
    var worksOnSnippets: Bool {
        switch self {
        case .paste, .pasteRow, .move, .cycleFilter, .actions, .confirm, .dismiss, .editSnippets, .close: true
        default: false
        }
    }
}

extension PanelCommand {
    /// A click on a row does what Return does (card agent-bo-95422994).
    public static func click(returnCopies: Bool) -> PanelCommand {
        PanelCommand(key: .return, returnCopies: returnCopies, searchEmpty: true)!
    }
}

/// The panel's cursor and the rows picked with it, in the order they were picked (ClipBook numbers its picks the same
/// way). No picks: the cursor row alone is what a paste, pin or delete acts on.
public struct PanelSelection: Equatable, Sendable {
    public private(set) var cursor = 0
    /// Picked row ids, first pick first.
    public private(set) var picks: [Int64] = []

    public init() {}

    /// A plain arrow: the cursor moves on its own and the picks stay, so Shift+arrow or Cmd+Return can add more apart.
    public mutating func move(_ step: Int, in rows: [StoredClip]) {
        cursor = Self.clamp(cursor + step, rows)
    }

    /// Shift+arrow: the cursor row is picked first, then each row the cursor reaches; stepping back onto the
    /// previous pick drops the last one, as a text selection shrinks, and shrinking to the cursor row alone picks none.
    /// A run started off the picks (after a plain arrow) only adds, even onto an older pick.
    public mutating func extend(_ step: Int, in rows: [StoredClip]) {
        guard rows.indices.contains(cursor) else { return }
        let fresh = !picks.contains(rows[cursor].id)
        if fresh { picks.append(rows[cursor].id) }
        let next = Self.clamp(cursor + step, rows)
        guard next != cursor else { return }
        let id = rows[next].id
        if !fresh, picks.count > 1, picks[picks.count - 2] == id {
            picks.removeLast()
            if picks == [id] { picks = [] }
        } else if !picks.contains(id) {
            picks.append(id)
        }
        cursor = next
    }

    /// A click on a row (card agent-bo-95422994): the cursor on it and the picks gone, as a plain arrow leaves them.
    public mutating func place(_ index: Int, in rows: [StoredClip]) {
        guard rows.indices.contains(index) else { return }
        picks = []
        cursor = index
    }

    /// Cmd+Return on the cursor row, or Cmd+click on a row: the cursor there, the row in or out of the picks.
    public mutating func toggle(_ index: Int, in rows: [StoredClip]) {
        guard rows.indices.contains(index) else { return }
        cursor = index
        let id = rows[index].id
        if let at = picks.firstIndex(of: id) { picks.remove(at: at) } else { picks.append(id) }
    }

    public mutating func pickAll(_ rows: [StoredClip]) {
        picks = rows.map(\.id)
    }

    public mutating func clearPicks() { picks = [] }

    /// Rows an action just made (split, merge): the cursor on the first, all of them picked when there are several.
    public mutating func select(_ ids: [Int64], in rows: [StoredClip]) {
        guard let first = ids.first, let index = rows.firstIndex(where: { $0.id == first }) else { return }
        cursor = index
        picks = ids.count > 1 ? ids : []
    }

    /// After the rows change: picks that are gone drop out, the cursor follows its row or stays in range.
    public mutating func refit(_ rows: [StoredClip], cursorOn id: Int64?) {
        let ids = Set(rows.map(\.id))
        picks.removeAll { !ids.contains($0) }
        cursor = id.flatMap { id in rows.firstIndex { $0.id == id } } ?? Self.clamp(cursor, rows)
    }

    /// What a paste, pin or delete acts on: the picks in pick order, else the cursor row.
    public func targets(in rows: [StoredClip]) -> [StoredClip] {
        guard !picks.isEmpty else { return rows.indices.contains(cursor) ? [rows[cursor]] : [] }
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return picks.compactMap { byID[$0] }
    }

    /// The row's place in the pick order, from 1; nil when it is not picked.
    public func pickNumber(of id: Int64) -> Int? {
        picks.firstIndex(of: id).map { $0 + 1 }
    }

    private static func clamp(_ index: Int, _ rows: [StoredClip]) -> Int {
        min(max(index, 0), max(rows.count - 1, 0))
    }
}

/// One row of the tag field's list: make a tag of what was typed, or an existing tag.
public enum TagChoice: Equatable, Sendable {
    case create(String), existing(ClipTag)

    /// "Create" first when the typed name (as ClipTag.name stores it) is no tag yet, then every tag containing it.
    public static func list(typed: String, tags: [ClipTag]) -> [TagChoice] {
        let name = ClipTag.name(typed)
        let matching = name.isEmpty ? tags : tags.filter { $0.name.localizedCaseInsensitiveContains(name) }
        let exists = tags.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return (name.isEmpty || exists ? [] : [.create(name)]) + matching.map(TagChoice.existing)
    }
}

/// Text pasted through the pasteboard with Sven's copy put back once the app has read it: snippets and plain paste
/// (card agent-bo-95423072).
@MainActor
public enum PasteBack {
    /// How long the app gets to read the pasteboard before Sven's copy goes back on it.
    public static let after: TimeInterval = 0.5

    /// Runs a step after a delay; tests hold it instead.
    public typealias Later = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    public static let onMain: Later = { delay, step in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() } }
    /// Each pasteboard's paste still waiting to put the copy back: the change it made and the copy it saved.
    private static let waiting = Mutex<[NSPasteboard.Name: (change: Int, saved: [[String: Data]])]>([:])

    /// Puts `text` on as plain text, transient, has `post` paste it, and after `after` puts Sven's copy back, transient
    /// (it is in the history from when it was copied), unless something was copied meanwhile: that is his newest copy.
    /// `thenCopy` goes on instead of his copy, as an ordinary copy the history keeps (Quick AI's original text). A paste
    /// inside an earlier one's wait saves that one's copy, not its plain text (two presses within the half second left
    /// the plain text on, card agent-bo-95423072).
    public static func paste(_ text: String, to pasteboard: NSPasteboard, thenCopy: String? = nil, post: () -> Void, later: Later) {
        let name = pasteboard.name, saved = copy(on: pasteboard)
        PanelRows.write([.init(contents: [], text: text)], plain: true, to: pasteboard)
        let ours = pasteboard.changeCount
        waiting.withLock { $0[name] = (ours, saved) }
        post()
        later(after) { [pasteboard] in
            // Its wait ends either way; a later paste that took it over keeps its own.
            waiting.withLock { if $0[name]?.change == ours { $0[name] = nil } }
            guard pasteboard.changeCount == ours else { return }
            if let thenCopy {
                pasteboard.clearContents()
                pasteboard.setString(thenCopy, forType: .string)
            } else {
                putBack(saved, on: pasteboard)
            }
        }
    }

    /// `paste`, through a press that takes its time (the app's Paste menu item pressed through Accessibility, the
    /// selection box): Sven's copy goes back `after` once `press` returns, not once it starts, pressed or not. False when
    /// it found no Paste.
    public static func paste(_ text: String, to pasteboard: NSPasteboard, press: () async -> Bool, later: Later = onMain) async -> Bool {
        var putBack: (@MainActor () -> Void)?
        paste(text, to: pasteboard, post: {}, later: { _, step in putBack = step })
        let pressed = await press()
        if let putBack { later(after, putBack) }
        return pressed
    }

    /// The focused app's selected text through its own Copy, for an app whose Accessibility has none (Quick AI's fix in
    /// Ghostex's GPUI, Electron apps, Chrome without its accessibility tree): `post` presses Cmd+C, the pasteboard is
    /// looked at every 20 ms for up to half a second for the app's copy, then Sven's copy goes back, transient. Nil when
    /// no text came (nothing selected) or Pilot may not read the pasteboard.
    public static func copySelection(from pasteboard: NSPasteboard, post: () -> Void,
                                     sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> String? {
        await copySelection(from: pasteboard, press: { post(); return true }, sleep: sleep)
    }

    /// The same through a press that takes its time, such as the app's Copy menu item pressed through Accessibility
    /// (the selection box, ADR 0001): the half second starts once `press` returns; nothing when it found no Copy.
    public static func copySelection(from pasteboard: NSPasteboard, press: () async -> Bool,
                                     sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async -> String? {
        guard pasteboard.accessBehavior != .alwaysDeny else { return nil }
        let saved = items(on: pasteboard), before = pasteboard.changeCount, poll = Duration.milliseconds(20)
        guard await press() else { return nil }
        for _ in 0..<25 where pasteboard.changeCount == before { await sleep(poll) }
        guard pasteboard.changeCount != before else { return nil }
        // An app may clear the pasteboard and write its text a moment later.
        if pasteboard.string(forType: .string) == nil { await sleep(poll) }
        let text = pasteboard.string(forType: .string)
        putBack(saved, on: pasteboard)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    /// Sven's copy, to put back after a paste: what is on the pasteboard, or the copy a paste still waiting saved, never
    /// that paste's own text.
    static func copy(on pasteboard: NSPasteboard) -> [[String: Data]] {
        waiting.withLock { $0[pasteboard.name].flatMap { $0.change == pasteboard.changeCount ? $0.saved : nil } } ?? items(on: pasteboard)
    }

    /// Every item on the pasteboard, each type's data, to put back later.
    private static func items(on pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } }) { a, _ in a }
        }
    }

    /// Sven's copy back, transient (it is in the history from when it was copied); nothing when there was none.
    static func putBack(_ saved: [[String: Data]], on pasteboard: NSPasteboard) {
        if saved.isEmpty { pasteboard.clearContents() } else {
            PanelRows.write([.init(contents: saved, text: "")], plain: false, forget: true, to: pasteboard)
        }
    }
}

public enum PanelRows {
    /// One stored copy on its way back to the pasteboard.
    public struct Paste: Sendable {
        public var contents: [[String: Data]]
        public var text: String

        public init(contents: [[String: Data]], text: String) {
            self.contents = contents; self.text = text
        }
    }

    /// Pins on top, then everything else; each group keeps the store's newest-first order.
    public static func ordered(_ clips: [StoredClip]) -> [StoredClip] {
        clips.filter(\.pinned) + clips.filter { !$0.pinned }
    }

    /// Puts the picked copies on the pasteboard as one paste, in pick order. One copy goes back exactly as it was
    /// copied, every item with every type. A plain paste, or several copies that all have text, is their texts joined
    /// by new lines (files by their paths); several files go back as every file, so Finder pastes them all; anything
    /// else (an image among them) goes back as every pasteboard item in order; a paste of those goes in by `steps`, as an
    /// app reads one item. Whatever is not one copy as it was
    /// copied is marked transient, so the history does not keep it as a new item. A plain paste of an image with no
    /// text pastes it whole.
    /// `forget`: marked transient even as one copy, for a paste whose row is deleted next (paste and delete).
    public static func write(_ pastes: [Paste], plain: Bool, forget: Bool = false, to pasteboard: NSPasteboard) {
        let string = NSPasteboard.PasteboardType.string.rawValue
        let joinable = !pastes.isEmpty && pastes.allSatisfy { !$0.text.isEmpty } && (plain || (pastes.count > 1 && !allFiles(pastes)))
        if joinable {
            put([[string: Data(pastes.map(\.text).joined(separator: "\n").utf8)]], transient: true, to: pasteboard)
        } else {
            put(pastes.flatMap(\.contents), transient: forget || pastes.count > 1, to: pasteboard)
        }
    }

    /// History rows back on the pasteboard, from their stored contents; see the several-copies write. A plain paste
    /// takes an image's text, read from it, as its text (card agent-bo-95423070); any other paste keeps the image, so
    /// several images never paste as their texts. `paste`: rows that cannot go on as one are not written; their
    /// `steps` come back, for PasteSteps.
    @discardableResult
    public static func write(_ clips: [StoredClip], from store: ClipboardStore, plain: Bool, forget: Bool = false, paste: Bool = false,
                             to pasteboard: NSPasteboard) throws -> [Paste]? {
        let pastes = try pastes(clips, from: store, plain: plain)
        if paste, let steps = steps(pastes) { return steps }
        write(pastes, plain: plain, forget: forget, to: pasteboard)
        return nil
    }

    /// A paste of several copies that cannot go on as one, an image among them: each run of texts joined by new lines,
    /// as one paste joins them, and each other copy on its own, in pick order, for PasteSteps to paste one after another.
    /// An app reads one item of a pasteboard with several, so one Cmd+V landed only the image or only the text (Sven,
    /// build 36). Nil when the write above lands whole: one copy, texts, files. Nothing goes between a text and an image:
    /// a new line there would run a terminal's command line.
    public static func steps(_ pastes: [Paste]) -> [Paste]? {
        guard pastes.count > 1, pastes.contains(where: \.text.isEmpty), !allFiles(pastes) else { return nil }
        var steps: [Paste] = [], texts: [String] = []
        func endTexts() {
            guard !texts.isEmpty else { return }
            let text = texts.joined(separator: "\n")
            steps.append(Paste(contents: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]], text: text))
            texts = []
        }
        for paste in pastes {
            if paste.text.isEmpty { endTexts(); steps.append(paste) } else { texts.append(paste.text) }
        }
        endTexts()
        return steps
    }

    /// Every copy is files: they go back as every file, so Finder pastes them all.
    private static func allFiles(_ pastes: [Paste]) -> Bool {
        pastes.allSatisfy { $0.contents.allSatisfy { $0[NSPasteboard.PasteboardType.fileURL.rawValue] != nil } }
    }

    /// The clips' stored contents on their way back, with the text a paste or a plain paste writes.
    static func pastes(_ clips: [StoredClip], from store: ClipboardStore, plain: Bool) throws -> [Paste] {
        try clips.map { Paste(contents: try store.contents(of: $0.id), text: plain ? $0.plainText : $0.text) }
    }

    /// One stored copy back on the pasteboard; see the several-copies write.
    public static func write(_ contents: [[String: Data]], text: String, plain: Bool, to pasteboard: NSPasteboard) {
        write([Paste(contents: contents, text: text)], plain: plain, to: pasteboard)
    }

    private static func put(_ contents: [[String: Data]], transient: Bool, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(contents.enumerated().map { index, representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: .init(type)) }
            if transient && index == 0 { item.setData(Data(), forType: ClipboardCapture.transient) }
            return item
        })
    }
}
