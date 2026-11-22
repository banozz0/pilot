import AppKit
import PilotCore
import SwiftUI

/// Cmd+K's actions on a note (Sven 2026-10-15) in the menu's Cmd+K look, searchable as an action panel
/// (direction B): what is typed over the actions, then those that match in groups split by rules, each with its key
/// (the formats', ⌘N, ⌘⌫), the Trash in the problem colour, ↵ on the highlighted one; typing, ↑↓ and Return from the
/// panel's keys (NotesKey), a click runs one. Over the note's corner, on the style's pop face.
struct NotesActionsView: View {
    @Environment(\.style) private var style
    @Bindable var model: NotesModel

    var body: some View {
        if let menu = model.actions {
            instrument(menu)
        }
    }

    private func rows<Rule: View, Row: View>(_ menu: NoteActions, @ViewBuilder rule: @escaping () -> Rule,
                                             @ViewBuilder row: @escaping (NoteAction, Bool) -> Row) -> some View {
        let shown = menu.visible
        return VStack(alignment: .leading, spacing: 0) {
            if shown.isEmpty {
                Text("No action called “\(menu.query)”").styleText(\.caption).foregroundStyle(style.color(\.text3))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, action in
                if index > 0, action.group != shown[index - 1].group { rule() }
                Button { model.runAction(at: index) } label: { row(action, index == menu.index).contentShape(.rect) }
                    .buttonStyle(.plain).focusable(false)
                    .accessibilityAddTraits(index == menu.index ? .isSelected : [])
            }
        }
    }

    /// The search line: what is typed after the glyph, its caret in the signal colour, or the prompt.
    private func search(_ menu: NoteActions, face: Font, caret: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(style.color(\.text3))
                .accessibilityHidden(true)
            HStack(spacing: 1) {
                if !menu.query.isEmpty { Text(menu.query).foregroundStyle(style.color(\.text)) }
                caret.frame(width: 1.5, height: 15)
                if menu.query.isEmpty { Text("Search actions…").foregroundStyle(style.color(\.text3)).padding(.leading, 1) }
            }
            .font(face).lineLimit(1)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Search actions on \(menu.title): \(menu.query)")
    }

    /// The actions whole when the panel has the room, else scrolling (the smallest panel).
    private func fitted(@ViewBuilder _ list: () -> some View) -> some View {
        let list = list()
        return ViewThatFits(in: .vertical) {
            list
            ScrollView { list }.scrollIndicators(.never)
        }
    }

    // MARK: Instrument

    private func instrument(_ menu: NoteActions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            search(menu, face: style.font(\.body), caret: style.color(\.accent))
                .padding(.horizontal, 12).frame(height: 38, alignment: .leading)
            InstrumentRule()
            fitted {
                rows(menu, rule: { InstrumentRule().padding(.horizontal, 6).padding(.vertical, 4) }) { action, on in
                    let ink: KeyPath<StyleColors, Paint> = action.danger ? \.problem : \.text
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol).font(style.font(\.icon)).frame(width: 18)
                            .foregroundStyle(style.color(on || action.danger ? ink : \.text3)).accessibilityHidden(true)
                        Text(action.title).styleText(\.body).foregroundStyle(style.color(ink))
                        Spacer(minLength: 8)
                        if on { InstrumentKey(text: "↵") } else if let key = action.key { NotesCaps(key: key) }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .instrumentRaised(on)
                }
                .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 6)
            }
        }
        .frame(width: 290)
        .styleSurface(\.pop, fill: \.panel, radius: \.card)
        .background(NotesPopoverWatch { model.perform(.closeActions) })
    }
}

/// Closes a pop-up drawn inside a window as a popover closes (Sven, 2026-11-20: Cmd+K's actions stayed open on a click
/// outside them and with another app in front): on a press outside its frame, in its window or another of Pilot's, on
/// its window losing the keyboard, and on another app coming in front (the panel never activates Pilot, so Pilot's own
/// resign is not enough). Escape stays the keys' (NotesKey). Laid behind the pop-up, so its frame is the pop-up's.
struct NotesPopoverWatch: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> Watch { Watch() }
    func updateNSView(_ view: Watch, context: Context) { view.close = close }

    /// True from a press that closed a pop-up to that press's release, so a button the press lands on (the head's
    /// Actions, the format bar's Aa) does not open it again.
    @MainActor private(set) static var closingPress = false
    @MainActor private static var release: Any?

    @MainActor final class Watch: NSView {
        var close: (() -> Void)?
        private var monitor: Any?
        private var observers: [(center: NotificationCenter, observer: NSObjectProtocol)] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.pressed(event) }
                return event
            }
            let center = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
            let resigned = center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
            let inactive = center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
            let other = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                MainActor.assumeIsolated { self?.dismiss() }
            }
            observers = [(center, resigned), (center, inactive), (workspace, other)]
        }

        /// A press Pilot is handed (its local monitor): outside the pop-up's frame, it closes the pop-up.
        func pressed(_ event: NSEvent) {
            guard let window, close != nil else { return }
            if event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) { return }
            NotesPopoverWatch.awaitRelease()
            dismiss()
        }

        private func dismiss() {
            guard window != nil, let close else { return }
            close()
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach { $0.center.removeObserver($0.observer) }
            observers = []
        }
    }

    /// Marks a closing press until its release has been handed on; the pop-up's own watch is gone by then.
    @MainActor private static func awaitRelease() {
        closingPress = true
        if let release { NSEvent.removeMonitor(release) }
        release = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { event in
            MainActor.assumeIsolated { released() }
            return event
        }
    }

    /// The closing press's release: once it has been handed on, a press is a press again.
    @MainActor static func released() {
        if let release { NSEvent.removeMonitor(release) }
        release = nil
        // On the run loop's next turn, which a render's wait turns too (a main-queue block would wait for it to end).
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { closingPress = false } }
    }
}

/// A note with no words in it (Sven 2026-10-15): one line under the caret says so, with Delete, which moves the file to
/// the Trash at once, no second question (⌘⌫ does the same). At the words' edge (NotesNote).
struct NotesEmptyNote: View {
    let model: NotesModel
    let markdown: MarkdownStyle

    var body: some View {
        HStack(spacing: 10) {
            Text("This note is empty.").font(Font(markdown.body)).foregroundStyle(Color(markdown.muted))
            Button("Delete") { model.trash(model.current) }
                .buttonStyle(PilotButtonStyle(destructive: true)).controlSize(.small).focusable(false)
                .help("Moves the note’s file to the Trash")
            NotesCaps(key: "⌘⌫")
        }
        .padding(.top, markdown.line + 12)
    }
}
