import AppKit
import Carbon.HIToolbox
import Clipboard
import Observation
import OSLog
import PilotCore
import Synchronization

private let snippetLog = Logger(subsystem: "dev.banozz.pilot", category: "snippets")

/// Pastes a snippet into the focused field (card agent-bo-95423044): the typed keyword erased, the filled text put on
/// the pasteboard marked transient (clipboard history skips it) and pasted with Cmd+V, the caret moved back to
/// {cursor}, then Sven's own copy put back. Pasting into the focused app is the feature (ADR 0001 allows a keystroke
/// into it); no key ever goes to another app's hotkey.
@MainActor
struct SnippetPaster {
    var pasteboard: NSPasteboard = .general
    /// Keys into the focused app, as Pilot's own so the tap lets them through; after the tap callback returns.
    var post: ([KeyEvent]) -> Void = { events in DispatchQueue.main.async { Post.events(events, own: true) } }
    var later: PasteBack.Later = PasteBack.onMain
    var now: () -> Date = { PlaceholderReads.now() }
    /// Typed instead when Pilot may not read the pasteboard (its access set to Always Deny): nothing to put back then.
    var type: (String) -> Void = { Post.text($0) }

    private static func keys(_ code: Int64, _ count: Int, _ modifiers: Modifiers = []) -> [KeyEvent] {
        (0..<count).flatMap { _ in KeyEvent.keystroke(code, modifiers: modifiers) }
    }

    /// Deletes `count` characters before the caret: a typed keyword.
    func erase(_ count: Int) { post(Self.keys(KeyCode.delete, count)) }

    /// `erasing`: the keyword's characters already in the field.
    func paste(_ snippet: Snippet, argument: String = "", erasing: Int = 0) {
        PlaceholderReads.read(for: snippet.text, argument: argument, pasteboard: pasteboard, now: now()) { values in
            let filled = snippet.expanded(values)
            paste(filled.text, caretBack: filled.caretBack, erasing: erasing)
            snippetLog.notice("snippet \(snippet.name, privacy: .public) pasted, \(filled.text.count) characters")
        }
    }

    /// Text as it is, over the selection or at the caret, the caret then moved `caretBack` to the left: a snippet's, or
    /// Quick AI's fixed text (card agent-bo-95423050), whose original is `thenCopy` (PasteBack.paste).
    func paste(_ text: String, caretBack: Int = 0, erasing: Int = 0, thenCopy: String? = nil) {
        guard pasteboard.accessBehavior != .alwaysDeny, !text.isEmpty else {
            erase(erasing)
            type(text)
            return post(Self.keys(KeyCode.leftArrow, caretBack))
        }
        PasteBack.paste(text, to: pasteboard, thenCopy: thenCopy, post: {
            post(Self.keys(KeyCode.delete, erasing) + Self.keys(KeyCode.v, 1, .cmd) + Self.keys(KeyCode.leftArrow, caretBack))
        }, later: later)
    }
}

/// Where the placeholders' live values come from as a snippet pastes or a quicklink opens (launcher-best T6): the clock,
/// the pasteboard, the clipboard history and the selection, each read only when the text holds its placeholder. The
/// selection is read through Accessibility alone, never the app's Copy: no key goes to another app for it (ADR 0001).
enum PlaceholderReads {
    /// The clock: the sandbox host's fixed time (PILOT_SANDBOX_NOW), else now. Set once, before any read.
    nonisolated(unsafe) static var now: () -> Date = Date.init
    /// The sandbox host's selection (PILOT_SANDBOX_SELECTION), read instead of the front app's. Set once, before any read.
    nonisolated(unsafe) static var selectionStandIn: String?

    /// The front app's selected text through Accessibility alone (SelectedText with no Copy), off the main thread; nil
    /// when it has none, only whitespace, or Pilot is in front.
    @MainActor static func selection() async -> String? {
        if let selectionStandIn { return selectionStandIn }
        return await SelectedText.focused(copy: { nil })?.text
    }

    /// The history's text copies before the latest, newest first: `depth` of them, none for 0.
    @MainActor static func earlierClips(_ depth: Int) -> [String] {
        guard depth > 0 else { return [] }
        return Array(ClipboardHistory.shared.recent().filter { $0.kind == .text }.dropFirst().prefix(depth).map(\.text))
    }

    /// `then` with the values `text` needs: at once, or after the selection is read when it holds {selection}.
    /// {clipboard} reads `pasteboard` unless Pilot's access to it is Always Deny.
    @MainActor static func read(for text: String, argument: String = "", pasteboard: NSPasteboard = .general, now: Date? = nil,
                                then: @escaping @MainActor (Placeholders.Values) -> Void) {
        let needs = Placeholders.summary(of: text)
        let readable = needs.kinds.contains(.clipboard) && pasteboard.accessBehavior != .alwaysDeny
        let values = Placeholders.Values(now: now ?? Self.now(), clipboard: readable ? pasteboard.string(forType: .string) : nil,
                                         earlierClips: earlierClips(needs.clipboardDepth), argument: argument)
        guard needs.kinds.contains(.selection) else { return then(values) }
        Task { @MainActor in
            var values = values
            values.selection = await selection()
            then(values)
        }
    }

    /// What the Snippets page's preview and `pilot list` fill with: the clock, and samples for the clipboard, the
    /// argument and the selection (the sandbox's selection when it has one), never the pasteboard or another app's text.
    @MainActor static func samples() -> Placeholders.Values {
        Placeholders.Values(now: now(), clipboard: SnippetsEditor.sampleClipboard,
                            earlierClips: Array(repeating: SnippetsEditor.sampleEarlierClip, count: 9),
                            selection: selectionStandIn ?? SnippetsEditor.sampleSelection, argument: SnippetsEditor.sampleArgument)
    }
}

/// Watches what the focused app is typed for a snippet's keyword (the tap hands it every key it lets through). On a
/// match the keyword's last key is kept from the app and the snippet replaces the rest; never while secure input is on.
/// The keyboard tap asks `typed` on its own thread and the main thread sets and resets it, so its state is behind a lock.
final class SnippetKeywords: @unchecked Sendable {
    private var typing = SnippetTyping(keywords: [])
    private var byKeyword: [String: Snippet] = [:]
    private let isBlocked: () -> Bool
    private let expand: (Snippet, _ erasing: Int) -> Void
    private let lock = NSRecursiveLock()
    /// Whether one of Pilot's own windows is key, as the main thread last read NSApp.keyWindow (SnippetLibrary.start):
    /// the tap's thread never asks AppKit.
    static let pilotWindowIsKey = Atomic(false)

    /// `isBlocked`: secure input is on, or one of Pilot's own windows takes the keys (the snippet editor, Hyper+Space's
    /// search), where a keyword is being typed, not used.
    init(isBlocked: @escaping () -> Bool = { IsSecureEventInputEnabled() || SnippetKeywords.pilotWindowIsKey.load(ordering: .relaxed) },
         expand: @escaping (Snippet, _ erasing: Int) -> Void) {
        self.isBlocked = isBlocked; self.expand = expand
    }

    /// Every change: the copies the tap pastes follow each name and text edit. What was typed so far is kept unless
    /// the keywords themselves changed.
    func set(_ snippets: [Snippet]) {
        lock.lock(); defer { lock.unlock() }
        let old = Set(byKeyword.keys)
        byKeyword = Dictionary(snippets.filter { !$0.keyword.isEmpty }.map { ($0.keyword, $0) }) { first, _ in first }
        if Set(byKeyword.keys) != old { typing = SnippetTyping(keywords: Array(byKeyword.keys)) }
    }

    /// The snippet typing `keyword` pastes now: the tap's own copy, which the snippets row reads back as typedText.
    func snippet(for keyword: String) -> Snippet? { lock.withLock { byKeyword[keyword] } }

    /// A click or another app in front: the caret moved, so what came before no longer counts.
    func reset() { lock.withLock { typing.reset() } }

    /// A key down the focused app gets, with the characters it types, read only while a keyword is watched; true keeps it
    /// from the app.
    func typed(_ e: KeyEvent, _ characters: @autoclosure () -> String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard e.kind == .keyDown, !byKeyword.isEmpty else { return false }
        if e.keyCode == KeyCode.delete, e.flags & KeyEvent.chordMask == 0 { typing.backspace(); return false }
        let characters = characters()
        // A shortcut, or a key that types no character (an arrow, Return, Tab, Escape): the caret may be anywhere now.
        guard e.flags & (KeyEvent.cmdMask | KeyEvent.ctrlMask) == 0, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || (0xF700...0xF8FF).contains($0.value) })
        else { typing.reset(); return false }
        guard let keyword = typing.type(characters), let snippet = snippet(for: keyword), !isBlocked() else { return false }
        expand(snippet, keyword.count - characters.count)
        return true
    }
}

/// Sven's snippets: snippets.json read at launch, saved on every edit, and the keywords the tap watches for.
@Observable @MainActor
final class SnippetLibrary {
    static let shared = SnippetLibrary()

    /// Every change is saved at once and the tap pastes it from then on.
    var snippets: [Snippet] {
        didSet {
            keywords.set(snippets)
            do { try store.save(snippets); failed = nil } catch {
                failed = "Snippets not saved: \(error.localizedDescription)"
                snippetLog.error("snippets not saved: \(String(describing: error), privacy: .public)")
            }
        }
    }
    /// Why the file did not read or save; the editor shows it. A file that does not read is never overwritten.
    private(set) var failed: String?
    @ObservationIgnored private let store: SnippetStore
    @ObservationIgnored private let paster: SnippetPaster
    /// Asked by the keyboard tap on its own thread: a match hands its paste to the main queue.
    @ObservationIgnored private(set) lazy var keywords = SnippetKeywords(expand: hopping { [weak self] snippet, erasing in
        self?.typed(snippet, erasing: erasing)
    })
    @ObservationIgnored private var monitors: [Any] = []

    init(store: SnippetStore = .standard, paster: SnippetPaster = SnippetPaster()) {
        self.store = store
        self.paster = paster
        do { snippets = try store.load() } catch {
            snippets = []
            failed = "snippets.json did not read, so it is left as it is: \(error.localizedDescription)"
            snippetLog.error("snippets not read: \(String(describing: error), privacy: .public)")
        }
        keywords.set(snippets)
    }

    /// The snippet a menu row names, pasted into the app in front.
    func paste(_ pick: SnippetPick) {
        guard let snippet = snippet(pick.id) else { return }
        paster.paste(snippet, argument: pick.argument ?? "")
    }

    func snippet(_ id: UUID) -> Snippet? { snippets.first { $0.id == id } }

    /// A typed keyword: pasted, or, when it takes an argument, erased and asked for in Hyper+Space. After the tap
    /// callback returns: reading the pasteboard can take a while, and the tap must answer at once.
    private func typed(_ snippet: Snippet, erasing: Int) {
        DispatchQueue.main.async { [self] in
            guard snippet.needsArgument else { return paster.paste(snippet, erasing: erasing) }
            paster.erase(erasing)
            PilotMenu.shared.askArgument(for: snippet)
        }
    }

    /// Clicks and app switches move the caret, so a keyword is only one typed in a row.
    func start() {
        guard monitors.isEmpty else { return }
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.keywords.reset() }
        }) { monitors.append(click) }
        monitors.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keywords.reset() }
        })
        // Pilot's own key window, read here on the main thread for the tap's `isBlocked`: after each change settles, as a
        // window resigning key comes before the next one becomes key.
        let follow: @Sendable (Notification) -> Void = { _ in
            DispatchQueue.main.async { SnippetKeywords.pilotWindowIsKey.store(NSApp.keyWindow != nil, ordering: .relaxed) }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            monitors.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: follow))
        }
    }
}
