import AppKit
import PilotCore
import SwiftUI

/// The Extensions page's Raycast Store (raycast-extensions T24), on the model Hyper+Space's Raycast Store reads
/// (RaycastStoreModel): its folders A to Z, searched as Sven types, named by the folder until picked; the picked one's
/// package.json is read as it is picked and its detail shows its icon, title, author, description and Install, or
/// Installed with Open commands. The listing is read from GitHub only while the page shows it, kept a day; Refresh
/// reads it again. Drawn in Instrument from the Ink, as the page's own list is.
struct RaycastStoreView: View {
    @Environment(\.ink) private var ink
    let model: RaycastStoreModel
    let onScreen: Bool
    /// An installed one's card on the Extensions page, which lists its commands.
    var showInstalled: (String) -> Void = { _ in }
    @State private var query = ""
    @State private var picked: String?

    init(model: RaycastStoreModel = .shared, onScreen: Bool = true, pick: String? = nil, query: String = "",
         showInstalled: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onScreen = onScreen
        self.showInstalled = showInstalled
        _picked = State(initialValue: pick)
        _query = State(initialValue: query)
    }

    var body: some View {
        let folders = model.folders(matching: query)
        let current = folders.first { $0.name == picked } ?? folders.first
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SearchBox(prompt: "Search \(ExtensionsPageView.plural(model.listing?.folders.count ?? 0, "extension"))", text: $query)
                    IconButton(symbol: "arrow.clockwise", label: "Refresh the store", size: 24, glyph: 11) { Task { await model.refresh() } }
                        .help("Reads Raycast's store from GitHub again")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                list(folders, current: current?.name)
            }
            .frame(width: ExtensionsPageView.listWidth)
            ink.line.frame(width: 1)
            Group {
                if let current { StoreDetail(folder: current, model: model, showInstalled: showInstalled).id(current.name) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: onScreen) { if onScreen { await model.open() } }
    }

    @ViewBuilder private func list(_ folders: [RaycastStore.Folder], current: String?) -> some View {
        switch model.load {
        case .idle, .loading:
            VStack(alignment: .leading, spacing: 6) {
                PartHeading(text: "Raycast Store · Reading…")
                FinePrint(text: "Reading the folders of github.com/raycast/extensions…")
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 8) {
                Text("Raycast's store is out of reach.").font(ink.ui(13, .medium)).foregroundStyle(ink.text)
                FinePrint(text: why)
                Button("Try again") { Task { await model.refresh() } }.buttonStyle(.pilot)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    PartHeading(text: "Raycast Store · \(folders.count)").padding(.horizontal, 10)
                    ForEach(folders, id: \.name) { folder in row(folder, on: folder.name == current) }
                    if folders.isEmpty {
                        Text("Nothing in Raycast's store matches.").font(ink.ui(12)).foregroundStyle(ink.muted).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    FinePrint(text: Self.fine(model)).padding(.horizontal, 10).padding(.top, 10)
                }
                .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 14)
            }
        }
    }

    /// Where the listing came from, and why it is old when a read failed.
    static func fine(_ model: RaycastStoreModel) -> String {
        let when = model.listing.map { " Read \($0.fetched.formatted(date: .abbreviated, time: .shortened)), kept a day." } ?? ""
        return "From github.com/raycast/extensions, without an account.\(when)" + (model.stale.map { " \($0)." } ?? "")
    }

    private func row(_ folder: RaycastStore.Folder, on: Bool) -> some View {
        let installed = model.installedExtension(folder.name) != nil, info = model.infos[folder.name]
        return Button { picked = folder.name } label: {
            KitRow(selected: on) {
                StoreTile(file: model.iconFile(folder.name), size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title(folder.name)).font(ink.ui(13, .semibold)).lineLimit(1)
                    if let line = info?.description, !line.isEmpty { Text(line).font(ink.ui(11.5)).foregroundStyle(ink.rowQuiet(on)).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if installed {
                    Image(systemName: "checkmark").font(ink.ui(10, .semibold)).foregroundStyle(ink.rowQuiet(on)).accessibilityLabel("Installed")
                } else if model.busy.contains(folder.name) {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The picked folder: read as it shows, then its icon, title, "by <author> · raycast/extensions", Install (or Installed
/// and Open commands), Open on GitHub, its description and how many commands it has.
private struct StoreDetail: View {
    @Environment(\.ink) private var ink
    let folder: RaycastStore.Folder
    let model: RaycastStoreModel
    let showInstalled: (String) -> Void

    var body: some View {
        let info = model.infos[folder.name], installed = model.installedExtension(folder.name)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    StoreTile(file: model.iconFile(folder.name), size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title(folder.name)).font(ink.ui(18, .semibold)).foregroundStyle(ink.text).lineLimit(1).accessibilityAddTraits(.isHeader)
                        Text([info?.author.map { "by \($0)" }, installed == nil ? "raycast/extensions" : "installed"].compactMap { $0 }.joined(separator: " · "))
                            .font(ink.ui(12)).foregroundStyle(ink.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if model.busy.contains(folder.name) { ProgressView().controlSize(.small) }
                    Button("Open on GitHub") { NSWorkspace.shared.open(RaycastStore.pageURL(folder.name)) }.buttonStyle(.pilot)
                    if let installed {
                        Button("Open commands") { showInstalled(installed.id) }.buttonStyle(.pilotPrimary)
                    } else {
                        Button("Install") { Task { HUD.tip(await model.installPressed(folder.name, from: "the Extensions page's Raycast Store")) } }
                            .buttonStyle(.pilotPrimary).disabled(model.busy.contains(folder.name) || info == nil)
                            .accessibilityLabel("Install \(model.title(folder.name))")
                    }
                }
                if let failure = model.failures[folder.name] { FinePrint(text: failure, color: ink.red) }
                if let why = model.infoFailures[folder.name], info == nil { FinePrint(text: why, color: ink.red) }
                TitledPanel(title: "What you get") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let info {
                            ExtensionPurpose(description: info.description, examples: [])
                            FinePrint(text: "\(ExtensionsPageView.plural(info.commands, "command")). Install fetches its folder, asks you, then builds it on this Mac.")
                        } else {
                            FinePrint(text: "Reading its package.json…")
                        }
                    }
                }
            }
            .padding(20)
        }
        .task(id: folder) { await model.info(folder.name) }
    }
}

/// A store extension's icon on a key-cap tile, the puzzle piece until it is fetched.
private struct StoreTile: View {
    @Environment(\.ink) private var ink
    let file: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let file, let image = NSImage(contentsOfFile: file) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size * 0.72, height: size * 0.72)
            } else {
                Image(systemName: "puzzlepiece.extension").font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(ink.muted)
            }
        }
        .frame(width: size, height: size)
        .instrumentTile(size)
    }
}
