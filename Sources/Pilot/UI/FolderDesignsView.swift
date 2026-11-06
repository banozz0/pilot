import AppKit
import Observation
import PilotCore
import SwiftUI

/// Files › Folders (P43, design frame 1): the folders picked, each with its look, and the design to dress them in. Added
/// folders are ticked, but one in a git repository is left out until ticked (Q294's recommendation), with a warning;
/// the folders Pilot dressed before are listed unticked, each with its Reset on its menu. Apply and Reset run off the main
/// thread through FolderDesigns; Reset takes back only the icon Pilot set. Your designs (P55) are pictures added to Pilot's
/// own folder, picked like Pilot's, each removable. Pilot's designs are grouped by the kind of folder they suit (T61):
/// the kinds of the ticked folders, the twelve, then every other kind.
@Observable @MainActor
final class FolderDesignsModel {
    struct Row: Identifiable, Equatable {
        let url: URL
        var ticked: Bool
        var look: FolderLook
        /// The folder's icon as Finder shows it, read again when its look changes.
        var icon: NSImage
        let git: Bool, synced: Bool, finderLook: Bool
        /// The kind of folder it is, whose designs list first while it is ticked.
        let kind: FolderDesign.Kind?
        var id: URL { url }
    }

    private(set) var rows: [Row] = []
    var choice: FolderDesigns.Choice = .design(FolderDesign.all[0]) {
        didSet {
            preview = switch choice {
            case .design: nil
            case .yours(let design, _): yours.first { $0.design == design }?.icon
            case .own: FolderDesigns.icon(choice)
            }
        }
    }
    /// A picture of your own or one of Your designs as it will look, made once when picked.
    private(set) var preview: NSImage?
    /// Your designs, each with Pilot's copy and as it will look (nil when the copy cannot be read), read off the main thread.
    private(set) var yours: [(design: FolderDesign, file: URL, icon: NSImage?)] = []
    private(set) var working = false
    /// What the last apply or reset did.
    private(set) var said: String?

    @ObservationIgnored private let looks: FolderLooks
    @ObservationIgnored private let yourDesigns: YourFolderDesigns

    /// A render passes its own looks.
    init(looks: FolderLooks = FolderDesigns.looks, yours: YourFolderDesigns = .standard) { self.looks = looks; yourDesigns = yours }

    /// What a folder's row shows, read off the main thread: its look hashes its icon, the git check walks up its parents.
    private struct Probe: Sendable {
        let url: URL, look: FolderLook, git: Bool, synced: Bool, finderLook: Bool
        let kind: FolderDesign.Kind?
    }

    private func probe(_ urls: [URL]) async -> [Probe] {
        let looks = looks
        return await Task.detached(priority: .userInitiated) {
            urls.map { Probe(url: $0, look: looks.look(of: $0), git: FolderLooks.gitRepository($0) != nil, synced: FolderLooks.synced($0),
                             finderLook: FolderLooks.hasFinderLook($0), kind: FolderDesigns.kind(of: $0)) }
        }.value
    }

    /// The folders Pilot dressed, from its record, read as the tab shows (never as the page is built).
    func load() async {
        await loadYours()
        let looks = looks
        let dressed = await Task.detached { looks.records().map { URL(filePath: $0.path, directoryHint: .isDirectory) }.filter { FileManager.default.fileExists(atPath: $0.path) } }.value
        await add(dressed, ticked: false)
    }

    /// Each folder spelled as Pilot's record spells it (/private/tmp reads /tmp), so a reload finds the same row.
    func add(_ urls: [URL], ticked: Bool = true) async {
        for found in await probe(urls.map(\.standardizedFileURL).filter { url in !rows.contains { $0.url == url } }) where !rows.contains(where: { $0.url == found.url }) {
            rows.append(Row(url: found.url, ticked: ticked && !found.git, look: found.look, icon: NSWorkspace.shared.icon(forFile: found.url.path),
                            git: found.git, synced: found.synced, finderLook: found.finderLook, kind: found.kind))
        }
    }

    func tick(_ row: Row.ID) { if let i = rows.firstIndex(where: { $0.id == row }) { rows[i].ticked.toggle() } }

    var ticked: [Row] { rows.filter(\.ticked) }
    /// The kinds of the ticked folders, each once, in their order: their designs list first.
    var suggested: [FolderDesign.Kind] { FolderDesigns.distinct(ticked.map(\.kind)) }
    /// The ticked folders not already in the picked design.
    var toDress: [Row] { ticked.filter { $0.look != .pilot(choice.design.id) || choice.isOwn } }
    var toReset: [Row] { ticked.filter { if case .pilot = $0.look { true } else { false } } }

    func applyNow() async {
        guard !working else { return }
        working = true
        let outcome = await FolderDesigns.apply(choice, to: toDress.map(\.url))
        said = outcome.line("Dressed", " in \(choice.design.title)")
        await reread(outcome.done + outcome.left.map(\.0))
        working = false
    }

    func resetNow(_ only: [Row]? = nil) async {
        guard !working else { return }
        working = true
        let outcome = await FolderDesigns.reset((only ?? toReset).map(\.url))
        said = outcome.line("Reset")
        await reread(outcome.done + outcome.left.map(\.0))
        working = false
    }

    private func loadYours() async {
        let store = yourDesigns
        yours = await Task.detached(priority: .userInitiated) {
            store.list().map { ($0.design, $0.file, FolderDesigns.picture($0.file)) }
        }.value
    }

    /// Copies the pictures picked into Your designs and picks the first one added.
    func addDesigns(_ urls: [URL]) async {
        let store = yourDesigns
        let added = await Task.detached(priority: .userInitiated) { store.add(urls) }.value
        await loadYours()
        said = added.isEmpty ? "No new pictures to add: each was there already or could not be read." : "Added \(ExtensionsPageView.plural(added.count, "design"))."
        if let first = added.first { choice = .yours(first.design, first.file) }
    }

    /// Deletes Pilot's copy of one of Your designs; the folders dressed in it keep their icon and still Reset.
    func removeDesign(_ design: FolderDesign) async {
        let store = yourDesigns
        await Task.detached(priority: .userInitiated) { store.remove(design.id) }.value
        if choice.design == design { choice = .design(FolderDesign.all[0]) }
        await loadYours()
        said = "Removed \(design.title). Folders dressed in it keep their icon and still Reset."
    }

    /// The rows of the folders an apply or reset touched, done or left (a Reset that found the icon replaced dropped Pilot's stamp).
    private func reread(_ changed: [URL]) async {
        for found in await probe(changed) {
            guard let i = rows.firstIndex(where: { $0.url == found.url }) else { continue }
            rows[i].look = found.look
            rows[i].icon = NSWorkspace.shared.icon(forFile: found.url.path)
        }
    }
}

/// Files › Folders, layout B (T63, Sven Q873): one Dress bar on top, the folders as toggle chips, the pick and Apply; under
/// it four tabs show one set of designs at a time and only their grid scrolls. The search looks through all of them (Q875).
struct FolderDesignsView: View {
    @Environment(\.ink) private var ink
    @State var model = FolderDesignsModel()
    /// The tab picked by hand; none follows the folders (`shownTab`). A render passes its own, with where its grid starts
    /// scrolled.
    @State var tab: Tab?
    @State var search = ""
    var anchor = UnitPoint.top
    @State private var targeted = false

    enum Tab: String, CaseIterable { case yourFolders = "For your folders", pilot = "Pilot", kinds = "Every kind", yours = "Yours" }

    /// Until a tab is picked by hand: For your folders once a ticked folder is of a kind Pilot draws for, else Pilot, so
    /// a first run, or folders dressed before coming back unticked, never opens on an empty tab.
    private var shownTab: Tab { tab ?? (model.suggested.isEmpty ? .pilot : .yourFolders) }

    /// A design in a tab's grid.
    struct Item: Identifiable {
        enum Source { case pilot, yours(URL, NSImage?), own }
        let design: FolderDesign, title: String, source: Source
        var id: String { design.id }
    }

    /// A run of designs under one title, in one tab: a ticked folder's kind, Pilot's twelve, another kind, or Your designs.
    struct Shelf: Identifiable {
        let id: String, title: String, kind: String, tab: Tab
        var items: [Item]
    }

    /// T61's order: the ticked folders' kinds, Pilot's twelve, every other kind, then Your designs and Your own.
    static func shelves(_ model: FolderDesignsModel) -> [Shelf] {
        let suggested = model.suggested
        func pilot(_ designs: [FolderDesign], _ title: (FolderDesign) -> String) -> [Item] { designs.map { Item(design: $0, title: title($0), source: .pilot) } }
        return suggested.map { Shelf(id: $0.id, title: "For \($0.title)", kind: $0.title, tab: .yourFolders, items: pilot($0.designs, treatment)) }
            + [Shelf(id: "pilot", title: "Pilot", kind: "Pilot", tab: .pilot, items: pilot(FolderDesign.classic, \.title))]
            + FolderDesign.kinds.filter { !suggested.contains($0) }
                .map { Shelf(id: $0.id, title: $0.title, kind: $0.title, tab: .kinds, items: pilot($0.designs, treatment)) }
            + [Shelf(id: "yours", title: "Your designs", kind: "Yours, Your designs", tab: .yours,
                     items: model.yours.map { Item(design: $0.design, title: $0.design.title, source: .yours($0.file, $0.icon)) }
                        + [Item(design: .own, title: "Your own", source: .own)])]
    }

    var body: some View {
        let shelves = Self.shelves(model), yours = model.yours.map(\.design)
        let counts = Dictionary(grouping: shelves, by: \.tab).mapValues { $0.reduce(0) { $0 + $1.items.count } }
        let search = SearchBox(prompt: "Search \(counts.values.reduce(0, +))", text: $search).accessibilityLabel("Search designs and kinds")
        return VStack(alignment: .leading, spacing: 0) {
            KitBlock(title: "Dress", symbol: "folder") {
                if model.rows.isEmpty {
                    Text(targeted ? "Drop to add these folders" : "Add folders, or drop them here from Finder. In Finder, select folders and type folder in Hyper+Space.")
                        .font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
                Flow(spacing: 6, lineSpacing: 6) {
                    ForEach(model.rows) { folderChip($0, yours: yours) }
                    Button { choose() } label: { Label("Add", systemImage: "plus") }.buttonStyle(.pilot).controlSize(.small)
                }
                .padding(.vertical, 8)
                foot
            }
            .dropDestination(for: URL.self) { urls, _ in
                let found = urls.filter(FolderLooks.isFolder)
                Task { await model.add(found) }
                return !found.isEmpty
            } isTargeted: { targeted = $0 }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    tabs(counts)
                    Spacer(minLength: 12)
                    search.frame(width: 118)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Flow(spacing: 6, lineSpacing: 6) { tabs(counts) }
                    search
                }
            }
            .padding(.top, 14).padding(.bottom, 8)
            grid(shown(shelves))
        }
        .padding(.horizontal, ink.pageInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await model.load() }
    }

    // MARK: Dress

    /// A folder as a toggle chip: ticked ones are dressed; a git repository is marked and left out until ticked. Its path,
    /// look and warnings are its tooltip, and a Pilot-dressed one Resets from its menu.
    private func folderChip(_ row: FolderDesignsModel.Row, yours: [FolderDesign]) -> some View {
        let name = row.url.lastPathComponent, shape = Capsule()
        return Button { model.tick(row.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: row.ticked ? "checkmark.square.fill" : "square").font(ink.ui(12)).foregroundStyle(row.ticked ? ink.text : ink.muted)
                Image(nsImage: row.icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                Text(name).font(ink.ui(12)).foregroundStyle(row.ticked ? ink.text : ink.muted).lineLimit(1)
                if row.git { Image(systemName: "exclamationmark.triangle.fill").font(ink.ui(11)).foregroundStyle(ink.yellow) }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .overlay { shape.strokeBorder(ink.line2) }
            .contentShape(shape)
        }
        .buttonStyle(.plain).fixedSize()
        .help(Self.detail(row, yours: yours))
        .contextMenu {
            if case .pilot = row.look { Button("Reset \(name)") { Task { await model.resetNow([row]) } }.disabled(model.working) }
        }
        .accessibilityLabel("Dress \(name)").accessibilityValue(Self.spoken(row))
    }

    /// What VoiceOver reads after the chip's name: ticked or not, then the warnings its tooltip and triangle show.
    static func spoken(_ row: FolderDesignsModel.Row) -> String {
        ([row.ticked ? "Ticked." : "Not ticked."] + warnings(row)).joined(separator: " ")
    }

    /// A folder chip's tooltip: where it is, what it wears, and why a git or synced folder needs care.
    static func detail(_ row: FolderDesignsModel.Row, yours: [FolderDesign]) -> String {
        var lines = [AppConfigs.tilde(row.url.path, home: NSHomeDirectory())]
        if let tag = tag(row, yours: yours) { lines.append(tag) }
        return (lines + warnings(row)).joined(separator: "\n")
    }

    /// Why a git or synced folder needs care: the tooltip's last lines, and VoiceOver's after ticked or not.
    static func warnings(_ row: FolderDesignsModel.Row) -> [String] {
        var lines: [String] = []
        if row.git {
            lines.append("A git repository, so it is left out until ticked: a custom icon adds a hidden file named Icon to the folder, which git shows as untracked. Pilot never edits .gitignore.")
        }
        if row.synced { lines.append("Some cloud sync services drop custom icons; it may lose its look on another Mac.") }
        return lines
    }

    /// What the row's look is.
    static func tag(_ row: FolderDesignsModel.Row, yours: [FolderDesign]) -> String? {
        switch row.look {
        case .pilot(let id): "\(FolderDesign.wearing(id, yours: yours)) · by Pilot"
        case .custom: "Custom icon · kept until applied"
        case .plain where row.finderLook: "Finder look · kept until applied"
        case .plain: nil
        }
    }

    /// The ticked folders and the pick, then Reset and Apply ("Save design", Q874).
    private var foot: some View {
        BlockRow {
            Image(systemName: "folder.fill").font(ink.ui(18)).foregroundStyle(ink.muted)
            Image(systemName: "arrow.right").font(ink.ui(11)).foregroundStyle(ink.muted)
            Group {
                if case .design(let design) = model.choice {
                    FolderArtView(id: design.id)
                } else if let preview = model.preview {
                    picture(preview)
                } else {
                    Image(systemName: "photo").foregroundStyle(ink.muted)
                }
            }
            .frame(width: 40, height: 40)
            Text(model.said ?? summary).font(ink.ui(12)).foregroundStyle(ink.text2).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if model.working { ProgressView().controlSize(.small) }
            Button("Reset \(model.toReset.count)") { Task { await model.resetNow() } }
                .buttonStyle(.pilot).disabled(model.toReset.isEmpty || model.working)
                .help("Takes back the icon Pilot set on the ticked folders; what was there before comes back")
            Button("Apply to \(ExtensionsPageView.plural(model.toDress.count, "folder"))") { Task { await model.applyNow() } }
                .buttonStyle(.pilotPrimary).disabled(model.toDress.isEmpty || model.working)
        }
    }

    /// Which ticked folders become the design, and which already are.
    private var summary: String {
        let names = model.toDress.map(\.url.lastPathComponent), already = model.ticked.count - model.toDress.count
        guard !names.isEmpty else { return model.rows.isEmpty ? "Add a folder to dress it." : "Tick the folders to dress." }
        let list = names.count <= 3 ? ListFormatter.localizedString(byJoining: names) : "\(names.count) folders"
        return "\(list) \(names.count == 1 ? "becomes" : "become") \(model.choice.design.title)" + (already > 0 ? "; \(already) already \(already == 1 ? "is" : "are")." : ".")
    }

    // MARK: Tabs and search

    /// The four tabs as a segmented filter, then Add designs; a tab clears the search.
    @ViewBuilder private func tabs(_ counts: [Tab: Int]) -> some View {
        ForEach(Tab.allCases, id: \.self) { t in
            // Yours counts Your designs, not the Your own cell.
            let count = t == .yours ? model.yours.count : counts[t] ?? 0
            let on = search.isEmpty && shownTab == t
            Button { tab = t; search = "" } label: { Chip(text: t.rawValue, on: on, count: "\(count)") }
                .buttonStyle(.kitPress)
                .accessibilityLabel("\(t.rawValue), \(count)").accessibilityAddTraits(on ? .isSelected : [])
        }
        Button("Add designs…") { FolderDesigns.chooseDesigns { urls in Task { await model.addDesigns(urls) } } }
            .buttonStyle(.pilot).controlSize(.small)
    }

    /// The tab's shelves, or, while something is typed, every shelf's designs it finds.
    /// The search is the one the other pages run (FuzzyRanker.Filter): a design's name or its kind's, else a typo of one.
    private func shown(_ shelves: [Shelf]) -> [Shelf] {
        let filter = FuzzyRanker.Filter(search)
        guard !filter.typed.isEmpty else { return shelves.filter { $0.tab == shownTab } }
        return filter.search { holds in
            shelves.compactMap { shelf in
                var found = shelf
                found.items = shelf.items.filter { holds([$0.design.title, shelf.kind]) }
                return found.items.isEmpty ? nil : found
            }
        }
    }

    // MARK: The grid

    /// Only the grid scrolls, under the Dress bar and the tabs.
    private func grid(_ shelves: [Shelf]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if shelves.isEmpty {
                    if search.isEmpty { EmptyState(title: "No designs for these folders", line: "No ticked folder is of a kind Pilot draws for; Pilot and Every kind hold the rest.") }
                    else { EmptyState(title: "Nothing matches “\(search)”", line: "Search looks through every design's name and its kind's.") }
                }
                ForEach(shelves) { shelf in
                    HStack(alignment: .top, spacing: 8) {
                        Text(shelf.title).font(ink.ui(12, .semibold)).lineLimit(2).frame(width: 96, alignment: .leading).padding(.top, 10)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 4)], spacing: 4) {
                            ForEach(shelf.items) { cell($0) }
                        }
                    }
                    .accessibilityElement(children: .contain).accessibilityLabel(shelf.title)
                }
            }
            .padding(.bottom, ink.pageInset)
        }
        .defaultScrollAnchor(anchor)
        .id(shownTab)
    }

    /// A kind's design's own name in its row: Downloads Pour is Pour.
    static func treatment(_ design: FolderDesign) -> String { String(design.id.split(separator: "-").last ?? "").capitalized }

    /// A design to pick: its art over its name, ringed in the signal colour when picked; one of Your designs removes from
    /// its menu or its ×.
    private func cell(_ item: Item) -> some View {
        let on: Bool, pick: () -> Void, remove: (() -> Void)?
        var title = item.title
        switch item.source {
        case .pilot: (on, pick, remove) = (model.choice == .design(item.design), { model.choice = .design(item.design) }, nil)
        case .yours(let file, _):
            (on, pick, remove) = (model.choice.design == item.design, { model.choice = .yours(item.design, file) }, { Task { await model.removeDesign(item.design) } })
        case .own:
            (on, pick, remove) = (model.choice.isOwn, { FolderDesigns.chooseOwn { model.choice = .own($0) } }, nil)
            if !on { title += "…" }
        }
        let shape = RoundedRectangle(cornerRadius: ink.radius(9), style: .continuous)
        return Button(action: pick) {
            VStack(spacing: 3) {
                art(item, on: on).frame(width: 46, height: 46)
                Text(title).font(ink.ui(11)).foregroundStyle(on ? ink.text : ink.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(on ? ink.accent.opacity(0.12) : .clear, in: shape)
            .overlay { if on { shape.strokeBorder(ink.accent, lineWidth: 1.5) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(item.design.title)
        .overlay(alignment: .topTrailing) {
            if on, let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(ink.ui(14)).foregroundStyle(ink.muted) }
                    .buttonStyle(.plain).padding(4).help("Remove from Your designs; folders dressed in it keep their icon")
                    .accessibilityLabel("Remove \(title)")
            }
        }
        .contextMenu { if let remove { Button("Remove from Your designs", action: remove) } }
        .accessibilityLabel(title).accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private func art(_ item: Item, on: Bool) -> some View {
        switch item.source {
        case .pilot: FolderArtView(id: item.design.id)
        case .yours(_, let icon?): picture(icon)
        case .yours(_, nil): Image(systemName: "questionmark.folder").font(ink.ui(22)).foregroundStyle(ink.muted)
        case .own:
            if on, let preview = model.preview { picture(preview) }
            else { Image(systemName: "plus.rectangle.on.folder").font(ink.ui(22)).foregroundStyle(ink.muted) }
        }
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
    }

    /// Panels begin rather than run modal, so the tap keeps going while one is open.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { Task { await model.add(panel.urls) } }
        }
    }
}

/// A folder design's art, as bundled, read once.
struct FolderArtView: View {
    let id: String

    var body: some View {
        if let art = CatalogueIcons.image(FolderDesign.preview(id)) {
            Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fit).accessibilityHidden(true)
        } else {
            Image(systemName: "folder.fill").resizable().aspectRatio(contentMode: .fit).accessibilityHidden(true)
        }
    }
}
