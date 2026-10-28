import AppKit
import PilotCore
import SwiftUI

/// Defaults › Configs as mockup D (card agent-bo-95422980; cards agent-bo-95422841, Sven 2026-10-05): each app config on
/// this Mac as a card in its group (Terminal and shell, Windows and keys, Code), read-only: the app's icon and name, when
/// it changed, its path and a dotfiles chip when its real file sits there. A
/// filter and its chips narrow the cards; a click opens the preview under its group; Open edits it in the main editor.
/// Pilot's own files (Q261) close the list, preview and Show in Finder only. Configs › Agents (Sven 2026-10-10) is the
/// same list over everything agents read: their settings (Sven 2026-10-19: "All agents stuff should be in agents") and
/// their instruction files. The files are read as the page opens, off the main thread.
struct ConfigsList: View {
    @Environment(\.ink) private var ink
    /// Which files the list shows: app configs, or agents' settings and instruction files.
    enum Kind {
        case configs, instructions

        var title: String { self == .configs ? "Configs" : "Agents" }
        var noun: String { self == .configs ? "configs" : "agent files" }
        /// Instructions have nothing in dotfiles: no chips.
        var chips: [ConfigFilter] { self == .configs ? ConfigFilter.allCases : [] }

        func note(editor: String) -> String {
            switch self {
            case .configs: "Every app’s settings file Pilot found. Click one to preview it; Open edits it in \(editor)."
            case .instructions: "Agents’ settings and the files they read before they work. Click one to preview it; Open edits it in \(editor)."
            }
        }

        /// The files found in `home` and the known configs that are not there: the apps' configs with Pilot's own last, or
        /// the agents' configs then their instruction files.
        func find(home: URL) -> (found: [FoundConfig], missing: [AppConfig]) {
            let all = AppConfigs.all(home: home)
            guard self == .configs else {
                let agents = AppConfigs.find(home: home, among: all.filter { $0.group == .agents })
                return (agents.found + AgentInstructions.find(home: home), agents.missing)
            }
            let apps = AppConfigs.find(home: home, among: all.filter { $0.group != .agents })
            return (apps.found + AppConfigs.find(home: home, among: AppConfigs.pilotFiles).found, apps.missing)
        }
    }

    /// Where a render or a test starts: a filter typed, a card under the mouse, a preview open.
    struct Start {
        var query = ""
        var hovered: String?
        var previewing: String?
        /// The home folder whose configs show; nil is this Mac's.
        var home: URL?
        /// The moment each config's age counts from; nil is when the list appears.
        var now: Date?
    }

    /// One card, read once as the page appears: its card, its real file and that file written with ~, when it changed
    /// in words, and its path from whole to shortest.
    struct Item: Identifiable, Sendable {
        let card: ConfigCard
        let url: URL
        let real: String
        let changed: String?
        let paths: [String]
        /// The file's first lines that say something, the card's glimpse of it.
        var head: [String] = []
        var id: String { card.config.id }
    }

    /// The open preview: whose it is, its text, and that text's lines.
    struct Opened {
        let id: String
        let preview: AppConfigs.Preview
        let lines: [String]

        init(_ item: Item) {
            id = item.id
            preview = AppConfigs.preview(item.url)
            guard case .text(let text, _) = preview else { lines = []; return }
            var lines = text.components(separatedBy: "\n")
            if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
            self.lines = lines
        }
    }

    let editor: EditorChoice
    let kind: Kind
    @State private var items: [Item] = []
    @State private var missing: [AppConfig] = []
    @State private var counts: [ConfigFilter: Int] = [:]
    @State private var query: String
    @State private var filter = ConfigFilter.all
    @State private var opened: Opened?
    /// Off until the files are read, so the page never flashes No configs found.
    @State private var loaded = false
    private let start: Start

    init(editor: EditorChoice = .shared, kind: Kind = .configs, start: Start = .init()) {
        self.editor = editor
        self.kind = kind
        self.start = start
        _query = State(initialValue: start.query)
    }

    var body: some View {
        let editorName = AppsModule.appName(editor.app) ?? editor.app
        let shown = Set(AppConfigs.filter(items.map(\.card), query: query, by: filter).map(\.config.id))
        let visible = items.filter { shown.contains($0.id) }
        DefaultsSection(title: kind.title, note: kind.note(editor: editorName)) {
            tools.padding(.top, 2).padding(.bottom, 4)
            if !loaded {} else if visible.isEmpty { empty } else { groups(visible, editor: editorName) }
            if !missing.isEmpty { notHere }
        }
        .task(load)
    }

    // MARK: Filter

    private var tools: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(ink.ui(11)).foregroundStyle(ink.muted).accessibilityHidden(true)
                TextField("Filter \(kind.noun)", text: $query, prompt: Text("Filter \(kind.noun)").foregroundStyle(ink.muted))
                    .textFieldStyle(.plain).foregroundStyle(ink.text)
            }
            .font(ink.ui(12.5))
            .padding(.horizontal, 9).frame(minWidth: 120, idealWidth: 190, maxWidth: 190, minHeight: 28, maxHeight: 28)
            .background {
                // The hairline as a capsule under a 1 pt smaller one: a capsule's stroke draws a stray tick at each end
                // in the offscreen renders.
                Capsule().fill(ink.line).overlay { Capsule().fill(ink.selected).padding(1) }
            }
            Spacer(minLength: 8)
            ForEach(kind.chips, id: \.self) { chip in
                Button { withAnimation(Kit.change) { filter = chip } } label: {
                    Chip(text: "\(chip.label) \(counts[chip] ?? 0)", on: filter == chip, tag: true)
                }
                .buttonStyle(.kitPress)
                .accessibilityAddTraits(filter == chip ? .isSelected : [])
            }
        }
    }

    /// What a filter that found nothing says: the config it would be and where Pilot looks for it, else that none matches.
    private var empty: some View {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let (title, line): (String, String) = if items.isEmpty, kind == .instructions {
            ("No agent files found", "Pilot looks for agents’ settings, CLAUDE.md, AGENTS.md and Hermes souls in your home folder.")
        } else if items.isEmpty {
            ("No configs found", "Pilot looks for \(AppConfigs.known.count { $0.group != .agents }) apps’ configs in your home folder.")
        } else if let looked = AppConfigs.notHere(query: typed, missing: missing) {
            ("No config called “\(typed)” on this Mac", "Pilot looks for \(looked.config.name) at \(looked.path); install it and it shows up here.")
        } else if !typed.isEmpty {
            ("Nothing called “\(typed)” on this Mac", "Try an app’s name or part of its path.")
        } else {
            ("None here", "No config found on this Mac is \(filter.label.lowercased()).")
        }
        return VStack(spacing: 3) {
            Text(title).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
            Text(line).font(ink.ui(12)).foregroundStyle(ink.muted)
        }
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.top, 26).padding(.bottom, 18)
    }

    // MARK: Cards

    private func groups(_ visible: [Item], editor: String) -> some View {
        let groups = ConfigGroup.allCases.map { group in (group: group, items: visible.filter { $0.card.config.group == group }) }
            .filter { !$0.items.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.group) { group in
                GroupHeading(title: group.group.label, count: group.items.count).padding(.top, 14)
                // As wide as the row allows (Sven, 2026-10-07: half the page was empty), each card the same height as its row.
                CardGrid(minimum: 300, fit: true, stretch: true) {
                    ForEach(group.items) { item in
                        ConfigCardView(item: item, editor: editor, previewing: opened?.id == item.id, hovered: start.hovered == item.id,
                                       toggle: { toggle(item) }, open: { open(item) }, show: { reveal(item) })
                    }
                }
                if let opened, let item = group.items.first(where: { $0.id == opened.id }) {
                    ConfigPreview(item: item, opened: opened, show: { reveal(item) }, open: { open(item) })
                        .padding(.top, 8)
                }
            }
        }
    }

    /// The configs Pilot knows that are not here.
    private var notHere: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupHeading(title: "Not on this Mac")
            Flow(spacing: 5, lineSpacing: 5) {
                ForEach(missing, id: \.id) { Chip(text: $0.name, tag: true).opacity(0.75) }
            }
        }
        .padding(.top, 16)
    }

    // MARK: Doing

    /// A render or a test hands in its home and reads it at once, so its first draw has the cards; this Mac's are read
    /// off the main thread (a stat, a resolve and 4 KB per file, some forty of them on Sven's Mac).
    private func load() async {
        let kind = kind, now = start.now
        let read = if let home = start.home { Self.read(kind, home: home, now: now) }
            else { await Task.detached(priority: .userInitiated) { [home = ConfigsModule.home] in Self.read(kind, home: home, now: now) }.value }
        show(read)
    }

    private nonisolated static func read(_ kind: Kind, home: URL, now: Date?) -> (items: [Item], missing: [AppConfig]) {
        let result = kind.find(home: home)
        let items = result.found.map { found in
            let real = found.real, path = AppConfigs.tilde(found.path.path, home: home.path)
            let modified = (try? FileManager.default.attributesOfItem(atPath: real.path))?[.modificationDate] as? Date
            return Item(card: ConfigCard(config: found.config, path: path, inDotfiles: FoundConfig.inDotfiles(real)), url: real,
                        real: AppConfigs.tilde(real.path, home: home.path), changed: modified.map { AppConfigs.changed($0, now: now ?? .now) },
                        paths: AppConfigs.shortenings(path), head: head(real))
        }
        return (items, result.missing)
    }

    private func show(_ read: (items: [Item], missing: [AppConfig])) {
        items = read.items
        missing = read.missing
        loaded = true
        let cards = items.map(\.card)
        counts = Dictionary(uniqueKeysWithValues: ConfigFilter.allCases.map { ($0, AppConfigs.filter(cards, query: "", by: $0).count) })
        if let id = start.previewing, let item = items.first(where: { $0.id == id }) { opened = Opened(item) }
    }

    /// Read from the file's first 4 KB: enough for a card's six lines.
    private nonisolated static func head(_ url: URL) -> [String] {
        guard case .text(let text, _) = AppConfigs.preview(url, cap: 4096) else { return [] }
        return AppConfigs.head(text, 6)
    }

    private func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    private func toggle(_ item: Item) {
        withAnimation(Kit.change) { opened = opened?.id == item.id ? nil : Opened(item) }
    }

    /// A config, an agent's too, opens through its action, which looks it up again; an instruction file opens as it was
    /// found; Pilot's own files never open from here.
    private func open(_ item: Item) {
        if item.card.config.readOnly { return }
        if let action = ConfigsModule.dynamic(AppConfigs.actionID(item.id)) { action.run() } else { ConfigsModule.edit(item.url) }
    }
}

/// A group's heading: its name, a hairline, its count.
private struct GroupHeading: View {
    @Environment(\.ink) private var ink
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            // Instrument's group label is its mono eyebrow, the count a mono number.
            if ink.isInstrument { InstrumentEyebrow(text: title) }
            else { Text(title).accessibilityAddTraits(.isHeader) }
            ink.line.frame(height: 1)
            if let count { Text("\(count)").font(ink.isInstrument ? ink.mono(11) : ink.ui(11, .semibold)) }
        }
        .font(ink.ui(11, .semibold)).foregroundStyle(ink.muted)
        .padding(.horizontal, 2).padding(.bottom, 6)
    }
}

/// One config's card. The mouse over it firms its edge and swaps when it changed for Preview and Open (Show in Finder on
/// Pilot's own files).
private struct ConfigCardView: View {
    @Environment(\.ink) private var ink
    let item: ConfigsList.Item
    let editor: String
    let previewing: Bool
    @State private var hovered: Bool
    let toggle: () -> Void
    let open: () -> Void
    let show: () -> Void

    /// `hovered` starts a render with the mouse over it.
    init(item: ConfigsList.Item, editor: String, previewing: Bool, hovered: Bool, toggle: @escaping () -> Void, open: @escaping () -> Void,
         show: @escaping () -> Void) {
        self.item = item
        self.editor = editor
        self.previewing = previewing
        _hovered = State(initialValue: hovered)
        self.toggle = toggle
        self.open = open
        self.show = show
    }

    var body: some View {
        let config = item.card.config
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    config.glyph(size: 26)
                    Text(config.name).font(ink.ui(13.5, .semibold)).foregroundStyle(ink.text)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    if let changed = item.changed {
                        Text(changed).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1).fixedSize().opacity(hovered ? 0 : 1)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    ForEach(item.paths, id: \.self) { Text($0).fixedSize() }
                    Text(item.paths.last ?? item.card.path).truncationMode(.middle)
                }
                .font(ink.mono(11.5)).foregroundStyle(ink.text2).lineLimit(1)
                .padding(.top, 9)
                .help(item.card.path)
                if !item.head.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.head.indices, id: \.self) { ConfigLine.styled(item.head[$0], ink).lineLimit(1).truncationMode(.tail) }
                    }
                    .font(ink.mono(11)).foregroundStyle(ink.text2)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .innerCard()
                    .padding(.top, 10)
                    .accessibilityHidden(true)
                }
                if item.card.inDotfiles || config.generated {
                    Flow(spacing: 5, lineSpacing: 5) {
                        if item.card.inDotfiles { Chip(text: "dotfiles", color: ink.accent, tag: true) }
                        // Rendered from its source; an edit here is overwritten on the next render.
                        if config.generated { Chip(text: "generated", tag: true).help("Rendered from its source: edit that, not this file") }
                    }
                    .padding(.top, 7)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxHeight: .infinity, alignment: .top)
            .blockSurface()
            .overlay { if hovered { shape.strokeBorder(ink.line2, lineWidth: 0.5) } }
            .focusBorder(on: previewing, radius: ink.blockRadius)
            .contentShape(shape)
        }
        .buttonStyle(.kitPress)
        .accessibilityLabel([config.name, item.card.path, item.changed.map { "changed \($0)" }, item.card.inDotfiles ? "in dotfiles" : nil,
                             config.generated ? "generated" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(previewing ? "Hides the preview" : "Shows a preview")
        .accessibilityAction(named: config.readOnly ? "Show in Finder" : "Open in \(editor)", config.readOnly ? show : open)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                CardIconButton(symbol: previewing ? "eye.slash" : "eye", label: previewing ? "Hide \(config.name)" : "Preview \(config.name)", action: toggle)
                if config.readOnly { CardIconButton(symbol: "folder", label: "Show in Finder", action: show) }
                else { CardIconButton(symbol: "arrow.up.forward.square", label: "Open in \(editor)", action: open) }
            }
            .padding(8)
            .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
        }
        .onHover { inside in withAnimation(Kit.change) { hovered = inside } }
    }
}

/// A 26 pt icon button on a card, lit under the mouse.
private struct CardIconButton: View {
    @Environment(\.ink) private var ink
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(ink.ui(13)).foregroundStyle(over ? ink.text : ink.muted)
                .frame(width: 26, height: 26)
                .background(over ? ink.text.opacity(0.08) : .clear, in: .rect(cornerRadius: ink.radius(6), style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.kitPress)
        .help(label).accessibilityLabel(label)
        .onHover { over = $0 }
    }
}

/// The open config: its icon, name and real file, Show in Finder and Open, then its text in mono with line numbers, a
/// comment muted and a setting's key lit; secret-looking values are dots (AppConfigs.hidingSecrets).
private struct ConfigPreview: View {
    @Environment(\.ink) private var ink
    let item: ConfigsList.Item
    let opened: ConfigsList.Opened
    let show: () -> Void
    let open: () -> Void

    /// A line's height: 11.5 pt mono at 1.6.
    private static let line: CGFloat = 18.4
    private static let hidden = "••••••"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ink.blockRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                item.card.config.glyph(size: 18)
                Text(item.card.config.name).font(ink.ui(13, .semibold)).foregroundStyle(ink.text).lineLimit(1).fixedSize()
                Text(item.real).font(ink.mono(11.5)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle).help(item.real)
                Spacer(minLength: 8)
                Button(action: show) { HStack(spacing: 6) { Image(systemName: "folder"); Text("Show in Finder") } }
                    .buttonStyle(.pilot).fixedSize()
                if !item.card.config.readOnly {
                    Button(action: open) { HStack(spacing: 6) { Image(systemName: "arrow.up.forward.square"); Text("Open") } }
                        .buttonStyle(.pilotPrimary).fixedSize()
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Open \(item.card.config.name)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            ink.line.frame(height: 1)
            content
        }
        .blockSurface()
        .clipShape(shape)
    }

    @ViewBuilder private var content: some View {
        switch opened.preview {
        case .text(let text, let cut):
            let lines = opened.lines
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { i in
                        HStack(spacing: 14) {
                            Text("\(i + 1)").foregroundStyle(ink.muted.opacity(0.6)).frame(width: 34, alignment: .trailing)
                            ConfigLine.styled(lines[i], ink).lineLimit(1).truncationMode(.tail)
                        }
                        .frame(height: Self.line)
                    }
                }
                .font(ink.mono(11.5)).foregroundStyle(ink.text2)
                .padding(.vertical, 10).padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(height: min(CGFloat(lines.count) * Self.line + 20, 360))
            let hides = text.contains(Self.hidden)
            if cut || hides {
                ink.line.frame(height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    if cut { FinePrint(text: "Showing the first \(AppConfigs.previewCap / 1024) KB; open it for the rest.") }
                    if hides { FinePrint(text: "Values of lines naming a token, secret, password or API key show as dots.") }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        case .notText:
            Text("Not a text file.").foregroundStyle(ink.muted).padding(12)
        case .unreadable(let why):
            Text("Could not read it: \(why)").foregroundStyle(ink.red).padding(12)
        }
    }

}

extension AppConfig {
    /// The tile a config's card shows when none of its apps is installed (mockup D's).
    private static let tiles: [String: (symbol: String, colour: TileColour)] = [
        "ghostty": ("terminal", .accent), "neovim": ("chevron.left.forwardslash.chevron.right", .good), "aerospace": ("rectangle.split.3x1", .third),
        "zsh": ("terminal", .good), "zshenv": ("terminal", .good), "zprofile": ("terminal", .good), "git": ("arrow.triangle.branch", .problem),
        "starship": ("sparkles", .amber), "tmux": ("rectangle.split.2x2", .good),
        "lazygit": ("point.topleft.down.to.point.bottomright.curvepath", .accent), "hammerspoon": ("hammer", .amber),
        "karabiner": ("keyboard", .second), "vscode": ("chevron.left.forwardslash.chevron.right", .accent), "zed": ("bolt", .accent),
        "wezterm": ("terminal", .second), "kitty": ("terminal", .amber), "alacritty": ("terminal", .amber), "fish": ("fish", .third),
        "helix": ("chevron.left.forwardslash.chevron.right", .second), "skhd": ("keyboard", .amber), "yabai": ("rectangle.split.2x1", .second),
        "claude": ("sparkles", .amber), "claude-local": ("sparkles", .amber), "codex": ("terminal", .neutral), "hermes": ("person.2", .third),
        "empryo": ("cpu", .accent), "opencode": ("chevron.left.forwardslash.chevron.right", .good),
        "claude-md": ("sparkles", .amber), "codex-agents": ("terminal", .neutral), "code-workspace": ("folder", .second),
        "pilot-binds": ("keyboard", .accent), "pilot-workspace-presets": ("rectangle.split.3x1", .accent),
    ]

    /// Its tile, mockup D's glyph for a config with no app installed.
    var tile: (symbol: String, colour: TileColour) {
        if let tile = Self.tiles[id] { return tile }
        if id.hasPrefix("hermes-") || id.hasPrefix("soul-") { return ("person.2", .third) }
        return id.hasPrefix("repo-") ? ("folder", .second) : ("doc.text", .neutral)
    }

    /// The app's own icon when one of its apps is installed, else its tile.
    @MainActor func glyph(size: CGFloat) -> some View {
        let tile = self.tile
        return AppGlyph(bundles: bundles, symbol: tile.symbol, colour: tile.colour, size: size)
    }
}

/// A config line as the preview and the cards draw it: comments muted, a setting's key in the accent.
@MainActor enum ConfigLine {
    static func styled(_ line: String, _ ink: Ink) -> Text {
        switch AppConfigs.previewLine(line) {
        case .comment: Text(line).foregroundStyle(ink.muted)
        case .setting(let key, let rest): Text("\(Text(key).foregroundStyle(ink.mark(ink.accentText)))\(rest)")
        case .plain: Text(line)
        }
    }
}
