import AppKit
import Observation
import PilotCore
import SwiftUI

/// Files › Folders (P43, design frame 1): the folders picked, each with its look, and the design to dress them in. Added
/// folders are ticked, but one in a git repository is left out until ticked (Q294's recommendation), with a warning;
/// the folders Pilot dressed before are listed unticked, each with its Reset. Apply and Reset run off the main thread
/// through FolderDesigns; Reset takes back only the icon Pilot set. Your designs (P55) follow Pilot's: pictures added
/// to Pilot's own folder, picked like them, each removable.
@Observable @MainActor
final class FolderDesignsModel {
    struct Row: Identifiable, Equatable {
        let url: URL
        var ticked: Bool
        var look: FolderLook
        /// The folder's icon as Finder shows it, read again when its look changes.
        var icon: NSImage
        let git: Bool, synced: Bool, finderLook: Bool
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
    }

    private func probe(_ urls: [URL]) async -> [Probe] {
        let looks = looks
        return await Task.detached(priority: .userInitiated) {
            urls.map { Probe(url: $0, look: looks.look(of: $0), git: FolderLooks.gitRepository($0) != nil, synced: FolderLooks.synced($0),
                             finderLook: FolderLooks.hasFinderLook($0)) }
        }.value
    }

    /// The folders Pilot dressed, from its record, read as the tab shows (never as the page is built).
    func load() async {
        await loadYours()
        let looks = looks
        let dressed = await Task.detached { looks.records().map { URL(filePath: $0.path, directoryHint: .isDirectory) }.filter { FileManager.default.fileExists(atPath: $0.path) } }.value
        await add(dressed, ticked: false)
    }

    func add(_ urls: [URL], ticked: Bool = true) async {
        for found in await probe(urls.filter { url in !rows.contains { $0.url == url } }) where !rows.contains(where: { $0.url == found.url }) {
            rows.append(Row(url: found.url, ticked: ticked && !found.git, look: found.look, icon: NSWorkspace.shared.icon(forFile: found.url.path),
                            git: found.git, synced: found.synced, finderLook: found.finderLook))
        }
    }

    func tick(_ row: Row.ID) { if let i = rows.firstIndex(where: { $0.id == row }) { rows[i].ticked.toggle() } }

    var ticked: [Row] { rows.filter(\.ticked) }
    /// The ticked folders not already in the picked design.
    var toDress: [Row] { ticked.filter { $0.look != .pilot(choice.design.id) || choice.isOwn } }
    var toReset: [Row] { ticked.filter { if case .pilot = $0.look { true } else { false } } }
    /// The git repositories left out, which the warning names.
    var leftOut: [Row] { rows.filter { $0.git && !$0.ticked } }

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

struct FolderDesignsView: View {
    @Environment(\.ink) private var ink
    @State var model = FolderDesignsModel()
    @State private var targeted = false

    static let intro = "Dress folders in artwork. Pilot sets each folder's icon as Finder's Get Info does; Reset takes back only the icon Pilot set."

    var body: some View {
        let page = KitPage(intro: Self.intro) {
            KitBlock(title: "Folders", symbol: "folder", trailing: { folderHead }) { folders }
                .dropDestination(for: URL.self) { urls, _ in
                    let found = urls.filter(FolderLooks.isFolder)
                    Task { await model.add(found) }
                    return !found.isEmpty
                } isTargeted: { targeted = $0 }
            KitBlock(title: "Design", symbol: "paintbrush", trailing: { Text(model.choice.design.title).font(ink.ui(12)).foregroundStyle(ink.muted) }) {
                designs
                yours
                foot
            }
        }
        return page.task { await model.load() }
    }

    private var folderHead: some View {
        HStack(spacing: 10) {
            if !model.rows.isEmpty {
                Text("\(model.rows.count) picked · \(model.toDress.count) to dress").font(ink.ui(12)).foregroundStyle(ink.muted)
            }
            Button("Add folders…") { choose() }.buttonStyle(.pilot)
        }
    }

    @ViewBuilder private var folders: some View {
        if model.rows.isEmpty {
            BlockRow(first: true) {
                Text(targeted ? "Drop to add these folders" : "Add folders, or drop them here from Finder. In Finder, select folders and type folder in Hyper+Space.")
                    .font(ink.ui(12)).foregroundStyle(targeted ? ink.accent : ink.muted).padding(.vertical, 6)
            }
        }
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
            BlockRow(first: i == 0) { folderRow(row) }
        }
        ForEach(model.leftOut) { row in
            BlockRow {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ink.yellow)
                (Text("\(row.url.lastPathComponent) is a git repository, so it is left out. ").font(ink.ui(12, .semibold))
                 + Text("A custom icon adds a hidden file named Icon to the folder, which git shows as untracked. Tick it to dress it anyway; Pilot never edits .gitignore.").font(ink.ui(12)))
                    .foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
            }
        }
        if model.rows.contains(where: \.synced) {
            BlockRow { note("Some cloud sync services drop custom icons; a synced folder may lose its look on another Mac.") }
        }
    }

    private func folderRow(_ row: FolderDesignsModel.Row) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { row.ticked }, set: { _ in model.tick(row.id) })).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Dress \(row.url.lastPathComponent)")
            Image(nsImage: row.icon).resizable().interpolation(.high).frame(width: 28, height: 28)
            Text(row.url.lastPathComponent).font(ink.ui(13)).lineLimit(1)
            Text(AppConfigs.tilde(row.url.path, home: NSHomeDirectory())).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let tag = Self.tag(row, yours: model.yours.map(\.design)) { Chip(text: tag, color: row.look == .custom || row.finderLook ? nil : ink.accent) }
            if case .pilot = row.look {
                Button { Task { await model.resetNow([row]) } } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.pilot).disabled(model.working)
            }
        }
        .padding(.vertical, 4)
    }

    /// What the row's look is, beside its path.
    static func tag(_ row: FolderDesignsModel.Row, yours: [FolderDesign]) -> String? {
        switch row.look {
        case .pilot(let id): "\(FolderDesign.wearing(id, yours: yours)) · by Pilot"
        case .custom: "Custom icon · kept until applied"
        case .plain where row.finderLook: "Finder look · kept until applied"
        case .plain: row.git ? "git repository" : nil
        }
    }

    private var designs: some View {
        grid {
            ForEach(FolderDesign.all) { design in
                cell(design.title, on: model.choice == .design(design)) {
                    FolderArtView(id: design.id)
                } pick: { model.choice = .design(design) }
            }
        }
    }

    /// Your designs (P55) after Pilot's, then a picture of your own.
    @ViewBuilder private var yours: some View {
        BlockRow {
            Text("Your designs").font(ink.ui(12, .semibold))
            Text(model.yours.isEmpty ? "Pictures or folders of them; Pilot keeps its own copies." : "\(model.yours.count) · right-click one to remove it")
                .font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
            Spacer(minLength: 8)
            Button("Add designs…") { FolderDesigns.chooseDesigns { urls in Task { await model.addDesigns(urls) } } }.buttonStyle(.pilot)
        }
        grid {
            ForEach(model.yours, id: \.design.id) { design, file, icon in
                cell(design.title, on: model.choice.design == design) {
                    if let icon { picture(icon) } else { Image(systemName: "questionmark.folder").font(ink.ui(24)).foregroundStyle(ink.muted) }
                } pick: { model.choice = .yours(design, file) } remove: { Task { await model.removeDesign(design) } }
            }
            cell(model.choice.isOwn ? "Your own" : "Your own…", on: model.choice.isOwn) {
                if model.choice.isOwn, let preview = model.preview {
                    picture(preview)
                } else {
                    Image(systemName: "plus.rectangle.on.folder").font(ink.ui(24)).foregroundStyle(ink.muted)
                }
            } pick: { FolderDesigns.chooseOwn { model.choice = .own($0) } }
        }
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
    }

    private func grid(@ViewBuilder _ cells: () -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4, content: cells).padding(.vertical, 8)
    }

    private func cell(_ title: String, on: Bool, @ViewBuilder art: () -> some View, pick: @escaping () -> Void,
                      remove: (() -> Void)? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: ink.radius(9), style: .continuous)
        return Button(action: pick) {
            VStack(spacing: 4) {
                art().frame(width: 58, height: 58)
                Text(title).font(ink.ui(11.5)).foregroundStyle(on ? ink.accent : ink.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(on ? ink.accent.opacity(0.12) : .clear, in: shape)
            .overlay { if on { shape.strokeBorder(ink.accent, lineWidth: 1.5) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
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

    private var foot: some View {
        BlockRow {
            Image(systemName: "folder.fill").font(ink.ui(20)).foregroundStyle(ink.muted)
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
            .frame(width: 34, height: 34)
            Text(model.said ?? summary).font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
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

    private func note(_ text: String) -> some View {
        Text(text).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
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
        if let art = CatalogueIcons.image(id, in: "folder-designs") {
            Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fit).accessibilityHidden(true)
        } else {
            Image(systemName: "folder.fill").resizable().aspectRatio(contentMode: .fit).accessibilityHidden(true)
        }
    }
}
