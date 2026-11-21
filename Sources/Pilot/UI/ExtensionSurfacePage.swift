import AppKit
import Observation
import PilotCore
import SwiftUI

/// An extension's page in the app window (story 161): its command asked as the page shows and again on its pace (10 s at
/// the most often) while the window is on screen, never while hidden; Refresh asks now. The blocks of the last answer
/// stay while a later one fails, the failure said over them.
@Observable @MainActor
final class ExtensionPageModel {
    let id: String
    private(set) var ext: Extension?
    private(set) var blocks: [Extension.Block]?
    /// Why the last ask has nothing: a required setting unset, an error, too slow; nil when it answered.
    private(set) var problem: String?
    /// A required setting is unset: the page offers the extension's settings.
    private(set) var needsSettings = false
    /// The extension is gone, or has neither a page nor a bar item to show.
    private(set) var gone = false
    private(set) var updated: Date?
    /// When its command was last asked, answered or not.
    private(set) var tried: Date?
    private(set) var asking = false
    /// Its last answer's own pace (Surfaces v2), over the manifest's while it lasts.
    private(set) var refresh: Int?
    /// A push to one of its no-view commands (Surfaces v2): that command's view, beside the blocks on a wide page, over
    /// them on a narrow one, with its own back stack.
    var pane: ExtensionPopoverModel?
    @ObservationIgnored private(set) var inputs: ExtensionRun.Inputs?
    /// When the extension and its settings were last read from its folder.
    @ObservationIgnored private var read: Date?
    /// Its folder and settings, which its page's Settings reads too.
    @ObservationIgnored let folder: URL
    @ObservationIgnored let storage: ExtensionStorage
    @ObservationIgnored private let run: @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome
    @ObservationIgnored private let now: () -> Date
    /// The ask in flight, and whether another was asked for while it ran: a change's ask is never dropped, it runs next.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var again = false
    /// Counted at the start and the end of each change made on the page (a row moved, a live search): an answer asked
    /// before the count moved may be from before the change, so it is dropped and the ask after the change shows instead.
    @ObservationIgnored private var changes = 0
    /// The last change asked for, which the next one waits out.
    @ObservationIgnored private var changing: Task<Void, Never>?
    /// A live input's run (2026-10-17): its pause, its quiet run and the ask after it; a newer text cancels it.
    @ObservationIgnored private var live: Task<Void, Never>?
    /// A live input's run, and its pause; a test's fakes.
    @ObservationIgnored var quiet: @Sendable (Extension.Command, JSONValue?, String?, ExtensionRun.Inputs) async -> ExtensionRun.Outcome = {
        await ExtensionRun.noView($0, context: $1, input: $2, inputs: $3)
    }
    @ObservationIgnored var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: $0 / 10) }

    init(id: String, folder: URL = Extension.folder, storage: ExtensionStorage = ExtensionStorage(), now: @escaping () -> Date = Date.init,
         run: @escaping @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome = { await ExtensionRun.surface($0, inputs: $1) }) {
        self.id = id; self.folder = folder; self.storage = storage; self.now = now; self.run = run
    }

    /// The page's pace in seconds: its last answer's `refresh`, else its manifest's.
    var every: Int { refresh ?? ext?.shownSurface?.every ?? Extension.Surface.pace(.page, asked: nil) }

    /// When it asks again after a failed ask (the header's "trying again 18:55"); nil while the last ask answered.
    var nextTry: Date? { problem == nil ? nil : tried.map { $0.addingTimeInterval(Double(every)) } }

    /// Opens `command`'s view in the pane, asked as the page is, with the push's `context`.
    func open(_ command: String, title: String?, context: JSONValue?,
              act: @escaping ExtensionActions.Act = { ExtensionActions.run($0, in: $1, inputs: $2) },
              run: @escaping @Sendable (Extension.Command, JSONValue?, ExtensionRun.Inputs) async -> SurfaceOutcome = ExtensionPopoverModel.runner(.page)) async {
        guard let ext, let inputs else { return }
        let pane = ExtensionPopoverModel(id: id, folder: folder, storage: storage, now: now, run: run)
        pane.act = act
        self.pane = pane
        await pane.start(ext, inputs: inputs, command: command, title: title, context: context)
    }

    /// Asks its page's command, off the main thread. The extension and its settings are read again from its folder first
    /// when `reread`, when they are missing, or once its manifest's pace has passed since they were read: a faster
    /// `refresh` (Surfaces v2) asks only the command. Asked while an ask runs, it asks once more after that one, and
    /// returns when the page shows the later answer.
    func refresh(reread: Bool = false) async {
        if let inFlight {
            again = true
            return await inFlight.value
        }
        asking = true
        let task = Task {
            await ask(reread: reread)
            while again {
                again = false
                await ask(reread: false)
            }
            (inFlight, asking) = (nil, false)
        }
        inFlight = task
        await task.value
    }

    private func ask(reread: Bool) async {
        let pace = Double(ext?.shownSurface?.every ?? Extension.Surface.pace(.page, asked: nil))
        if reread || inputs == nil || read.map({ now().timeIntervalSince($0) >= pace }) ?? true {
            let (folder, id) = (folder, id)
            let found = await Task.detached { Extension.find(in: folder).extensions.first { $0.id == id } }.value
            ext = found
            guard let ext = found, ext.shownSurface != nil else { gone = true; return }
            gone = false
            var why: String?, unset = false
            inputs = await ExtensionsModule.inputs(for: ext, storage: storage, hud: { why = $0 }, unset: { _ in unset = true })
            needsSettings = unset
            read = now()
            if inputs == nil { problem = why }
        }
        if let ext, let page = ext.shownSurface, let inputs {
            let asked = changes
            let outcome = await run(page, inputs)
            guard asked == changes else { return }
            tried = now()
            switch outcome {
            case .blocks(let answer, let every): (blocks, problem, updated, refresh) = (answer, nil, now(), every)
            case .error(let why): problem = "\(ext.title) \(why)"
            case .bar: problem = "\(ext.title) \(ExtensionRun.unreadable)"
            }
        }
        if let problem { dlog.error("extension page: \(self.id, privacy: .public) \(problem, privacy: .private)") }
    }

    /// Asks on its pace until cancelled, while what shows it is on screen; an answer younger than its pace (a window shown
    /// again) waits out the rest of it first.
    func keepFresh() async {
        while !Task.isCancelled {
            let wait = updated.map { Double(every) - now().timeIntervalSince($0) } ?? 0
            if wait > 0 { guard (try? await sleep(.seconds(wait))) != nil else { return } }
            await refresh()
            guard (try? await sleep(.seconds(every))) != nil else { return }
        }
    }

    /// Runs `action`, a change Sven made on the page (a row moved, 2026-10-17), as the extension's, then asks again;
    /// returns once the page shows the extension's answer to it. Changes run one after another, so two quick moves never
    /// race in the extension's own files.
    func change(_ action: Extension.Item.Action, act: @escaping ExtensionActions.Act) async {
        let before = changing
        let task = Task {
            await before?.value
            guard let ext, let inputs else { return }
            changes += 1
            await act(action, ext, inputs)?.value
            changes += 1
            await refresh()
        }
        changing = task
        await task.value
    }

    /// A live input's text changed (2026-10-17): its run waits out `pause` (nil, its Return: none), then runs quietly and
    /// the page asks again. A newer text cancels the run waiting or running, its process tree stopped, so only the newest
    /// text's answer is drawn; nothing waits while no one types.
    func typed(_ action: Extension.Item.Action, pause: Duration?) {
        live?.cancel()
        live = Task {
            if let pause { guard (try? await sleep(pause)) != nil else { return } }
            guard !Task.isCancelled else { return }
            await runLive(action)
        }
    }

    /// The page went away: a live run waiting or running stops.
    func stopLive() {
        live?.cancel()
        live = nil
    }

    /// The newest live run has ended or been cancelled.
    func settled() async { await live?.value }

    /// The live run itself: a run per pause would HUD every keystroke, so its HUD line and its actions are left out (its
    /// answer is the page asked again) and only a failure is said.
    private func runLive(_ action: Extension.Item.Action) async {
        guard let ext, let inputs, case .run(let name, let context) = action.kind, let command = ext.noView(name) else { return }
        changes += 1
        let outcome = await quiet(command, context, action.input, inputs)
        changes += 1
        guard !Task.isCancelled else { return }
        switch outcome {
        case .hud: break
        case .actions(let actions, _): dlog.notice("extension: \(command.actionID, privacy: .public) live run left \(actions.count) actions undone")
        default: ExtensionsModule.show(outcome, of: command, in: ext, act: { _ in })
        }
        await refresh()
    }

    /// Runs `action` as the extension's: a push to one of its no-view commands goes to `push` (its name and context); a run
    /// or a Pilot action changes what it shows, so it asks again as a run ends, a Pilot action a moment later.
    func run(_ action: Extension.Item.Action, act: ExtensionActions.Act, push: (String, JSONValue?) -> Void) {
        guard let ext, let inputs else { return }
        if case .push(let name, let context) = action.kind, ext.noView(name) != nil { push(name, context); return }
        ExtensionActions.followed(act(action, ext, inputs), action) { await self.refresh() }
    }
}

/// An extension's page (story 161; pilot-1-1 T8, Q602): a header (its tile and name; its version, pace and when it last
/// answered; Refresh; Settings when it has preferences) over its blocks in titled panels, the title on each panel's
/// border: each section and each titled list its own panel, the loose blocks between them one untitled panel, two short
/// panels side by side on a wide page. Settings opens the extension's preferences as the first panel, the form the
/// Extensions list's detail draws (Q637); Settings again closes it and the page asks again. An ask that fails or times out
/// keeps the last answer at half strength and puts why and the next try in the header, nothing moving (Q638); before any
/// answer the header stands alone.
struct ExtensionSurfacePage: View {
    @Environment(\.ink) private var ink
    /// The window shows: the page asks on its pace only then.
    let onScreen: Bool
    @State private var model: ExtensionPageModel
    /// Opens the Extensions list at it: the page of one that is gone says so there.
    let settings: (String) -> Void
    /// Runs one of its actions as the extension's; a test's spy.
    var act: ExtensionActions.Act = { ExtensionActions.run($0, in: $1, inputs: $2) }
    /// The page is `wide` or wider: a pushed view opens beside the blocks, else over them, and short panels pair up.
    @State private var wide = false
    /// Its preferences, read from its folder when Settings opens.
    @State private var prefs: ExtensionsSettings
    @State private var settingsOpen = false
    static let wideFrom: CGFloat = 720, paneWidth: CGFloat = 380

    init(id: String, onScreen: Bool, model: ExtensionPageModel? = nil, settings: @escaping (String) -> Void) {
        self.onScreen = onScreen
        let model = model ?? ExtensionPageModel(id: id)
        _model = State(initialValue: model)
        _prefs = State(initialValue: ExtensionsSettings(folder: model.folder, storage: model.storage))
        self.settings = settings
    }

    private var row: ExtensionsPage.Row? { prefs.rows.first { $0.id == model.id } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ink.line.frame(height: 1)
            KitPage {
                VStack(alignment: .leading, spacing: 14) {
                    if settingsOpen, let row, !row.fields.isEmpty {
                        TitledPanel(title: "Settings") { ExtensionSettingsForm(row: row, settings: prefs, columns: wide ? 2 : 1) }
                    }
                    if model.gone {
                        EmptyState(title: "No page", line: "\(model.id) is not installed, or no longer has a page.", action: ("Open Extensions", { settings(model.id) }))
                    } else if let blocks = model.blocks {
                        content(blocks)
                    }
                }
                .padding(.top, 4)
                .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideFrom } action: { wide = $0 }
            }
        }
        // Asked as it shows, then on its pace while the window is on screen; leaving or hiding the page stops it.
        .task(id: onScreen) {
            guard onScreen else { return }
            await model.keepFresh()
        }
        // A setting unset opens Settings, where it is set.
        .task(id: model.needsSettings) { if model.needsSettings { await openSettings() } }
        .onDisappear { model.stopLive() }
    }

    // MARK: The header

    /// Its tile and name over its line; why the last ask has nothing and the next try at the right, then Refresh and
    /// Settings.
    private var header: some View {
        HStack(spacing: 12) {
            EmojiTile(emoji: model.ext?.icon, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.ext?.title ?? model.id).font(ink.ui(15, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(line).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
            }
            Spacer(minLength: 10)
            if let problem = model.problem {
                Text(problem + (model.nextTry.map { " · trying again \(Self.time($0))" } ?? ""))
                    .font(ink.mono(11)).foregroundStyle(ink.text2).lineLimit(2).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay { Capsule().strokeBorder(ink.line2) }
                    .textSelection(.enabled)
                    .help(problem)
            }
            IconButton(symbol: "arrow.clockwise", label: "Refresh", size: 28, glyph: 12) { Task { await model.refresh(reread: true) } }
                .disabled(model.asking)
            if model.ext?.preferences.isEmpty == false {
                Button { Task { settingsOpen ? await closeSettings() : await openSettings() } } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(settingsOpen ? .pilotPrimary : .pilot)
                .accessibilityAddTraits(settingsOpen ? .isSelected : [])
            }
        }
        .padding(.horizontal, ink.pageInset).padding(.vertical, 10)
    }

    /// "3.3.3 · every 60 s · asked 14:02"; while the last ask failed, "the answer from 14:02"; "Asking…" before any.
    private var line: String {
        let asked = model.updated.map { model.problem == nil ? "asked \(Self.time($0))" : "the answer from \(Self.time($0))" }
            ?? (model.problem == nil ? "Asking…" : nil)
        return [model.ext?.version, "every \(model.every) s", asked].compactMap { $0 }.joined(separator: " · ")
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private func openSettings() async {
        await prefs.load()
        withAnimation(Kit.change) { settingsOpen = true }
    }

    /// Settings closed: the page asks again with what was set.
    private func closeSettings() async {
        withAnimation(Kit.change) { settingsOpen = false }
        await model.refresh(reread: true)
    }

    // MARK: The blocks

    @ViewBuilder private func content(_ blocks: [Extension.Block]) -> some View {
        let main = VStack(alignment: .leading, spacing: 14) {
            if blocks.isEmpty { Text("Nothing to show.").font(ink.ui(13)).foregroundStyle(ink.muted) }
            panels(blocks)
        }
        // A failed ask leaves the last answer where it was, at half strength.
        .opacity(model.problem == nil ? 1 : 0.5)
        if let pane = model.pane {
            let close = { model.pane = nil }
            if wide {
                HStack(alignment: .top, spacing: 14) {
                    main.frame(maxWidth: .infinity, alignment: .topLeading)
                    ExtensionPaneView(model: pane, onScreen: onScreen, close: close).frame(width: Self.paneWidth)
                }
            } else {
                ExtensionPaneView(model: pane, onScreen: onScreen, close: close)
            }
        } else {
            main
        }
    }

    /// The panels in rows: two short ones side by side on a wide page, any other alone.
    private func panels(_ blocks: [Extension.Block]) -> some View {
        let panels = Panel.cut(blocks)
        let rows = Panel.rows(panels, pair: wide && model.pane == nil)
        return ForEach(rows.indices, id: \.self) { r in
            HStack(alignment: .top, spacing: 14) {
                ForEach(rows[r], id: \.self) { i in panel(panels[i]) }
            }
        }
    }

    private func panel(_ panel: Panel) -> some View {
        TitledPanel(title: panel.title) {
            VStack(alignment: .leading, spacing: 8) {
                if let note = panel.note { Text(note).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1) }
                ExtensionBlocksView(blocks: panel.blocks, page: .init(change: { await model.change($0, act: act) }, typed: model.typed)) { run($0) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Runs `action` as the extension's; a push to one of its no-view commands opens the pane (Surfaces v2).
    private func run(_ action: Extension.Item.Action) {
        model.run(action, act: act) { name, context in Task { await model.open(name, title: action.title, context: context, act: act) } }
    }

    /// One titled panel of a page: a section's blocks under its title (its plan beside it: "Claude Max"), its subtitle and
    /// aside as a quiet line; a titled list under its title; or the loose blocks between them, untitled.
    struct Panel: Equatable {
        let title: String?, note: String?, blocks: [Extension.Block]

        /// `blocks` cut into panels.
        static func cut(_ blocks: [Extension.Block]) -> [Panel] {
            var panels: [Panel] = [], loose: [Extension.Block] = []
            func flush() { if !loose.isEmpty { panels.append(Panel(title: nil, note: nil, blocks: loose)); loose = [] } }
            for block in blocks {
                switch block {
                case .section(let title, let subtitle, let aside, let asideNote, let inner, _, _):
                    flush()
                    let name = [title, asideNote].compactMap { $0 }.joined(separator: " ")
                    let note = [aside, subtitle].compactMap { $0 }.joined(separator: " · ")
                    panels.append(Panel(title: name.isEmpty ? nil : name, note: note.isEmpty ? nil : note, blocks: inner))
                case .list(let title?, let items, let reorder):
                    flush()
                    panels.append(Panel(title: title, note: nil, blocks: [.list(title: nil, items: items, reorder: reorder)]))
                default:
                    loose.append(block)
                }
            }
            flush()
            return panels
        }

        /// Short: at most three meters, stats, notes or a hero, so two sit side by side.
        var short: Bool {
            blocks.count <= 3 && blocks.allSatisfy { block in
                switch block {
                case .meter, .note, .hero: true
                case .stats(let stats): stats.count <= 3
                default: false
                }
            }
        }

        /// Panel indices in rows: two short panels next to each other share a row when `pair`, the rest one each.
        static func rows(_ panels: [Panel], pair: Bool) -> [[Int]] {
            var rows: [[Int]] = [], i = 0
            while i < panels.count {
                if pair, i + 1 < panels.count, panels[i].short, panels[i + 1].short { rows.append([i, i + 1]); i += 2 }
                else { rows.append([i]); i += 1 }
            }
            return rows
        }
    }
}

/// A page's pane (Surfaces v2): a pushed no-view command's view on a tile, as the popover draws its stack, with close;
/// asked again on its answer's pace only while the window shows.
struct ExtensionPaneView: View {
    @Environment(\.ink) private var ink
    let model: ExtensionPopoverModel
    let onScreen: Bool
    let close: () -> Void

    var body: some View {
        let bottom = model.stack[0]
        Tile {
            ExtensionStackView(model: model, root: bottom.title ?? bottom.command, fallback: model.top.command,
                               title: ink.ui(14, .semibold), accent: ink.accentInk, muted: ink.muted, mono: ink.mono(11)) {
                IconButton(symbol: "xmark", label: "Close", size: 20, glyph: 11, action: close)
            }
            .font(ink.ui(12.5))
        }
        .task(id: onScreen ? model.pace : nil) {
            guard onScreen else { return }
            await model.keepFresh()
        }
    }
}
