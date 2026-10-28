import AppKit
import Carbon.HIToolbox
import Clipboard
import Observation
import OSLog
import PilotCore

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
    var now: () -> Date = Date.init
    /// Typed instead when Pilot may not read the pasteboard (its access set to Always Deny): nothing to put back then.
    var type: (String) -> Void = { Post.text($0) }

    private static func keys(_ code: Int64, _ count: Int, _ modifiers: Modifiers = []) -> [KeyEvent] {
        (0..<count).flatMap { _ in KeyEvent.keystroke(code, modifiers: modifiers) }
    }

    /// Deletes `count` characters before the caret: a typed keyword.
    func erase(_ count: Int) { post(Self.keys(KeyCode.delete, count)) }

    /// `erasing`: the keyword's characters already in the field.
    func paste(_ snippet: Snippet, argument: String = "", erasing: Int = 0) {
        let readable = pasteboard.accessBehavior != .alwaysDeny
        let filled = snippet.expanded(now: now(), clipboard: readable ? pasteboard.string(forType: .string) : nil, argument: argument)
        paste(filled.text, caretBack: filled.caretBack, erasing: erasing)
        snippetLog.notice("snippet \(snippet.name, privacy: .public) pasted, \(filled.text.count) characters")
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

/// Watches what the focused app is typed for a snippet's keyword (the tap hands it every key it lets through). On a
/// match the keyword's last key is kept from the app and the snippet replaces the rest; never while secure input is on.
@MainActor
final class SnippetKeywords {
    private var typing = SnippetTyping(keywords: [])
    private var byKeyword: [String: Snippet] = [:]
    private let isBlocked: () -> Bool
    private let expand: (Snippet, _ erasing: Int) -> Void

    /// `isBlocked`: secure input is on, or one of Pilot's own windows takes the keys (the snippet editor, Hyper+Space's
    /// search), where a keyword is being typed, not used.
    init(isBlocked: @escaping () -> Bool = { IsSecureEventInputEnabled() || NSApp.keyWindow != nil },
         expand: @escaping (Snippet, _ erasing: Int) -> Void) {
        self.isBlocked = isBlocked; self.expand = expand
    }

    func set(_ snippets: [Snippet]) {
        byKeyword = Dictionary(snippets.filter { !$0.keyword.isEmpty }.map { ($0.keyword, $0) }) { first, _ in first }
        typing = SnippetTyping(keywords: Array(byKeyword.keys))
    }

    /// A click or another app in front: the caret moved, so what came before no longer counts.
    func reset() { typing.reset() }

    /// A key down the focused app gets, with the characters it types, read only while a keyword is watched; true keeps it
    /// from the app.
    func typed(_ e: KeyEvent, _ characters: @autoclosure () -> String) -> Bool {
        guard e.kind == .keyDown, !byKeyword.isEmpty else { return false }
        if e.keyCode == KeyCode.delete, e.flags & KeyEvent.chordMask == 0 { typing.backspace(); return false }
        let characters = characters()
        // A shortcut, or a key that types no character (an arrow, Return, Tab, Escape): the caret may be anywhere now.
        guard e.flags & (KeyEvent.cmdMask | KeyEvent.ctrlMask) == 0, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || (0xF700...0xF8FF).contains($0.value) })
        else { typing.reset(); return false }
        guard let keyword = typing.type(characters), let snippet = byKeyword[keyword], !isBlocked() else { return false }
        expand(snippet, keyword.count - characters.count)
        return true
    }
}

/// Sven's snippets: snippets.json read at launch, saved on every edit, and the keywords the tap watches for.
@Observable @MainActor
final class SnippetLibrary {
    static let shared = SnippetLibrary()

    /// Every change is saved at once and the tap watches the new keywords.
    var snippets: [Snippet] {
        didSet {
            // A name or text typed in the editor leaves the keywords as they were.
            if snippets.map(\.keyword) != oldValue.map(\.keyword) { keywords.set(snippets) }
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
    @ObservationIgnored private(set) lazy var keywords = SnippetKeywords { [weak self] snippet, erasing in
        self?.typed(snippet, erasing: erasing)
    }
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
    }
}
