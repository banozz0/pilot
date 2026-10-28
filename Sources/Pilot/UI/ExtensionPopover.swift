import AppKit
import Observation
import PilotCore
import SwiftUI

/// An extension bar item's popover (Surfaces v2, SPEC story 165): a click on its item runs its bar command again with
/// `"surface": "popover"`, its answer's blocks drawn in the bar's own panel (a key panel, so a field in it takes typing);
/// until it answers the popover shows the blocks the bar line last sent. A push to one of its no-view commands opens that
/// command's blocks over it with a ‹ back; any other action runs as the extension's, and a run asks the view showing again
/// as the run ends, a Pilot action 1.5 s later. A view whose answer carries `refresh` is asked again on that pace while it shows (P3).
/// A page's right-hand pane is the same stack, started at the pushed command (`start`) and asked as a page.
@Observable @MainActor
final class ExtensionPopoverModel {
    /// One view of the stack: the command it shows and the context handed on to it, its blocks and why it has none.
    struct View: Equatable {
        let command: String, title: String?, context: JSONValue?
        var blocks: [Extension.Block]?
        var problem: String?
        var updated: Date?
        /// Its answer's own pace in seconds (2 to 60), asked again only while it shows.
        var refresh: Int?
        /// Its last chat block: the popover is wider and scrolls from its newest message.
        var chat: Int? { blocks?.lastIndex(where: \.isChat) }
        /// Its last block's links, when its last block is a links row (Q138): the popover draws them beside Open page.
        var links: [Extension.Block.Link]? { if case .links(let links)? = blocks?.last { links } else { nil } }
    }

    /// What the keep-fresh loop follows: the view on top and its pace; a new one restarts it.
    struct Pace: Hashable { let depth: Int, command: String, every: Int? }

    let id: String
    private(set) var ext: Extension?
    private(set) var stack: [View] = []
    private(set) var asking = false
    @ObservationIgnored private(set) var inputs: ExtensionRun.Inputs?
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let storage: ExtensionStorage
    @ObservationIgnored private let run: @Sendable (Extension.Command, JSONValue?, ExtensionRun.Inputs) async -> SurfaceOutcome
    @ObservationIgnored private let now: () -> Date
    /// Runs an action that is not a push as the extension's, a run handing back its task; a test's spy.
    @ObservationIgnored var act: ExtensionActions.Act = { ExtensionActions.run($0, in: $1, inputs: $2) }

    /// `shown` are the blocks the bar line last sent, shown until the popover's own answer comes.
    init(id: String, shown: [Extension.Block]? = nil, folder: URL = Extension.folder, storage: ExtensionStorage = ExtensionStorage(),
         now: @escaping () -> Date = Date.init,
         run: @escaping @Sendable (Extension.Command, JSONValue?, ExtensionRun.Inputs) async -> SurfaceOutcome = runner(.popover)) {
        self.id = id; self.folder = folder; self.storage = storage; self.now = now; self.run = run
        stack = [View(command: "", title: nil, context: nil, blocks: shown.flatMap { $0.isEmpty ? nil : $0 })]
    }

    /// Runs a command for `surface` with the context handed on.
    nonisolated static func runner(_ surface: Extension.Surface.Kind) -> @Sendable (Extension.Command, JSONValue?, ExtensionRun.Inputs) async -> SurfaceOutcome {
        { await ExtensionRun.blocks($0, surface: surface, context: $1, inputs: $2) }
    }

    /// The view on top.
    var top: View { stack[stack.count - 1] }
    var canGoBack: Bool { stack.count > 1 }
    var pace: Pace { Pace(depth: stack.count, command: top.command, every: top.refresh) }

    /// A page's pane: `command`'s blocks, asked with `context`, its extension and inputs the page's own.
    func start(_ ext: Extension, inputs: ExtensionRun.Inputs, command: String, title: String?, context: JSONValue?) async {
        (self.ext, self.inputs) = (ext, inputs)
        stack = [View(command: command, title: title, context: context)]
        await refresh()
    }

    /// Asks the view on top again on its answer's pace for as long as the task runs: the view's own task, cancelled as it
    /// closes or as another view comes on top. Nothing when it asks no pace.
    func keepFresh(sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: $0 / 10) }) async {
        while let every = top.refresh, !Task.isCancelled {
            guard (try? await sleep(.seconds(every))) != nil, !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Reads the extension from its folder, then asks its bar command for the popover.
    func open() async {
        let (folder, id) = (folder, id)
        let found = await Task.detached { Extension.find(in: folder).extensions.first { $0.id == id } }.value
        ext = found
        guard let ext = found, let bar = ext.bar else { return say("\(id) has no bar item now.") }
        var why: String?
        inputs = await ExtensionsModule.inputs(for: ext, storage: storage, hud: { why = $0 })
        guard inputs != nil else { return say(why ?? "\(ext.title) needs a setting first.") }
        stack[0] = View(command: bar.command.name, title: nil, context: nil, blocks: stack[0].blocks)
        await refresh()
    }

    /// Asks the view on top again; the blocks it showed stay over a failure, the failure said.
    func refresh() async {
        guard let ext, let inputs, !top.command.isEmpty, !asking, let command = ext.noView(top.command) else { return }
        asking = true
        defer { asking = false }
        let depth = stack.count, asked = top
        let outcome = await run(command, asked.context, inputs)
        // A back or a push while it ran: the answer is for a view no longer on top.
        guard stack.count == depth, top.command == asked.command, top.context == asked.context else { return }
        switch outcome {
        case .blocks(let blocks, let every):
            (stack[depth - 1].blocks, stack[depth - 1].problem, stack[depth - 1].updated, stack[depth - 1].refresh) = (blocks, nil, now(), every)
        case .error(let why): stack[depth - 1].problem = "\(ext.title) \(why)"
        case .bar: stack[depth - 1].problem = "\(ext.title) \(ExtensionRun.unreadable)"
        }
        if let problem = top.problem { dlog.error("extension popover: \(ext.id, privacy: .public) \(problem, privacy: .private)") }
    }

    /// Opens `command`'s blocks over the view showing, with `context` handed on.
    func push(_ command: String, title: String?, context: JSONValue?) async {
        stack.append(View(command: command, title: title, context: context))
        await refresh()
    }

    func back() {
        guard canGoBack else { return }
        stack.removeLast()
    }

    /// A push to one of its no-view commands stays in the popover; a push to a list or detail and every other action run
    /// as the extension's; a run asks the view again as it ends, a Pilot action a moment later.
    func perform(_ action: Extension.Item.Action) {
        guard let ext, let inputs else { return }
        if case .push(let name, let context) = action.kind, ext.noView(name) != nil {
            Task { await push(name, title: action.title, context: context) }
            return
        }
        ExtensionActions.followed(act(action, ext, inputs), action) { await self.refresh() }
    }

    private func say(_ problem: String) {
        stack[stack.count - 1].problem = problem
    }
}

/// The popover's face: the extension's name (or ‹ and the pushed view's title), when it was read and Refresh, the
/// blocks small, then Open page when it has one, a last links block at its right (Q138). It keeps inside the room under its item: past it the blocks scroll, a
/// chat's reply box and buttons stay under them; a chat's popover is wider, a hero's or a strip's a little (380, as the calendar's).
struct ExtensionPopoverView: View {
    @Environment(\.style) private var style
    @Environment(\.barPopoverRoom) private var room
    @State private var model: ExtensionPopoverModel
    /// The popover's height and its scrolling blocks' height, so the rest of it (its chrome) is known.
    @State private var height: CGFloat = 0
    @State private var scrolled: CGFloat = 0
    static let width: CGFloat = 340, wideWidth = ClockPopover.width, chatWidth: CGFloat = 460
    let title: String, icon: String?, hasPage: Bool
    var openPage: (String) -> Void = { AppWindowController.shared.openExtensionPage($0) }

    init(item: ExtensionBar.Item, model: ExtensionPopoverModel? = nil) {
        _model = State(initialValue: model ?? ExtensionPopoverModel(id: item.id, shown: item.answer?.blocks))
        title = item.title; icon = item.icon; hasPage = item.hasPage
    }

    var body: some View {
        let ink = BarInk(style: style), page = hasPage && !model.canGoBack, links = model.top.links
        VStack(alignment: .leading, spacing: 10) {
            ExtensionStackView(model: model, root: ExtensionPages.Link(id: model.id, title: title, icon: icon).label, fallback: title,
                               title: ink.title, accent: ink.accent, muted: ink.muted, mono: ink.mono(11),
                               fit: room.map { $0 - (height - scrolled) }, scrolled: { scrolled = $0 }, holdsLinks: true) { EmptyView() }
            if page || links != nil {
                HStack(spacing: 10) {
                    if page { Button("Open page") { openPage(model.id) }.barButton() }
                    Spacer(minLength: 4)
                    // Beside Open page a link runs at once: one whose action asks first belongs in the blocks, not last.
                    if let links { ExtensionLinksRow(links: links, compact: true) { model.perform($0) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .barPopover(width: model.top.chat != nil ? Self.chatWidth : model.top.blocks?.contains(where: \.isWide) == true ? Self.wideWidth : Self.width)
        .extensionGlass()
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .task { await model.open() }
        // Asked again on the top view's own pace only while the popover shows: closing it ends the task.
        .task(id: model.pace) { await model.keepFresh() }
    }
}

extension EnvironmentValues {
    /// The tint of the glass an extension's bar popover stands on (Q474); nil: KitPopover's solid face.
    @Entry var popoverGlass: NSColor? = nil
}

extension View {
    /// An extension's bar popover on the top bar's Glass while Look › Glass is on (Sven 2026-10-25, Q474), tinted as the
    /// menu's (Look.glassTint, Transparency's ground strength), its fills see-through as the menu's; solid when Glass is
    /// off, at Transparency 0 or in Toybox. Applied outside its KitPopover, which draws the glass.
    func extensionGlass(_ look: Look = .shared) -> some View { modifier(ExtensionGlass(look: look)) }
}

private struct ExtensionGlass: ViewModifier {
    @Environment(\.style) private var style
    let look: Look

    func body(content: Content) -> some View {
        if look.extensionGlass {
            content.environment(\.popoverGlass, look.glassTint(on: .barPopovers))
                .environment(\.windowLayers, look.layers)
                .environment(\.style, style.seeThrough(look.layers))
        } else {
            content
        }
    }
}

/// A stack's face, the popover's and a page pane's: ‹ and the pushed view's title (`root` at the bottom), when it was read
/// and Refresh, then `trailing`; under it why it has nothing, and its blocks small. With `fit` the blocks scroll past that
/// height, a chat's from its newest message, and the blocks after the last chat (its reply box, its buttons) stay under
/// them, never scrolled away.
struct ExtensionStackView<Trailing: View>: View {
    let model: ExtensionPopoverModel
    /// The bottom view's title, and a pushed view's when its push gave none.
    let root: String, fallback: String
    let title: Font, accent: Color, muted: Color, mono: Font
    /// The most height the scrolling blocks may take; nil: no cap, nothing scrolls (a page's pane).
    var fit: CGFloat? = nil
    /// Told the scrolling blocks' height as it changes.
    var scrolled: (CGFloat) -> Void = { _ in }
    /// A last links block is drawn by the popover beside Open page, so not here (Q138).
    var holdsLinks = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        let top = model.top
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if model.canGoBack {
                    Button { model.back() } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(accent).keyboardShortcut("[", modifiers: .command)
                        .accessibilityLabel("Back")
                }
                Text(model.canGoBack ? top.title ?? fallback : root).font(title).lineLimit(1)
                Spacer(minLength: 8)
                if let updated = top.updated {
                    Text(updated.formatted(date: .omitted, time: .shortened)).font(mono).foregroundStyle(muted)
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(muted).disabled(model.asking).help("Refresh")
                trailing
            }
            if let problem = top.problem { Text(problem).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true) }
            if let all = top.blocks {
                let blocks = holdsLinks && top.links != nil ? Array(all.dropLast()) : all
                if all.isEmpty { Text("Nothing to show.").foregroundStyle(muted) }
                let chat = fit == nil ? nil : top.chat, cut = chat.map { $0 + 1 } ?? blocks.count
                FitScroll(cap: fit, fromBottom: chat != nil, shown: scrolled) {
                    ExtensionBlocksView(blocks: Array(blocks[..<cut]), compact: true) { model.perform($0) }
                }
                if cut < blocks.count { ExtensionBlocksView(blocks: Array(blocks[cut...]), compact: true) { model.perform($0) } }
            } else if top.problem == nil {
                Text("Asking…").foregroundStyle(muted)
            }
        }
    }
}

/// `content` as tall as it is up to `cap`, scrolling past it; `fromBottom` shows its foot first and keeps it there as it
/// grows (a chat's newest message). `shown` is told the height it takes. No cap: `content` as it is.
struct FitScroll<Content: View>: View {
    let cap: CGFloat?, fromBottom: Bool
    let shown: (CGFloat) -> Void
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        if let cap {
            let taken = min(height, max(cap, 0))
            ScrollView {
                content.onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
            }
            .defaultScrollAnchor(fromBottom ? .bottom : .top)
            .frame(height: taken)
            .onChange(of: taken, initial: true) { shown(taken) }
        } else {
            content
        }
    }
}
