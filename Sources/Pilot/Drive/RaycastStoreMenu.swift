import AppKit
import PilotCore

/// Hyper+Space's Raycast Store (raycast-extensions T24): a live picker over Raycast's store (RaycastStoreModel), a row per
/// folder that Pilot ranks as Sven types, named by its folder until its package.json is read. Return on a row not read
/// yet reads it in place (title, description, author, icon) and keeps it picked; on a read one it installs, T6's install
/// with its same question; on an installed one it opens that extension's commands. Cmd+K: Install or Open commands, Open
/// on GitHub, Refresh. The listing is read only as the picker opens, kept a day.
@MainActor
final class RaycastStoreMenu: MenuSource {
    static let actionID = "extensions.raycastStore", title = "Raycast Store"
    static let reading = "Reading Raycast's store from GitHub…"

    var show: ([MenuEntry]) -> Void = { _ in }
    private let model: RaycastStoreModel
    private let hud: (String) -> Void
    private let open: (URL) -> Void
    private var task: Task<Void, Never>?
    private var asked = false
    /// What the search holds as it opens (T25): the words of a root search's Search extensions row, or a folder's name.
    let opening: String
    /// The folder a root search's store row opened it on: read in place as the store opens, so Return installs it.
    private let focus: String?

    init(model: RaycastStoreModel = .shared, opening: String = "", focus: String? = nil, hud: @escaping (String) -> Void = { HUD.tip($0) },
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.model = model; self.opening = opening; self.focus = focus; self.hud = hud; self.open = open
    }

    /// The first search reads the listing; later ones are Pilot's to rank, every folder listed once.
    func search(_ query: String) {
        guard !asked else { return }
        asked = true
        show([Self.status(Self.reading)])
        task = Task { [weak self, model, focus] in
            await model.open()
            guard !Task.isCancelled else { return }
            self?.show(self?.rows() ?? [])
            guard let focus, await model.info(focus) != nil, !Task.isCancelled else { return }
            self?.show(self?.rows() ?? [])
        }
    }

    func close() { task?.cancel() }

    /// The rows again, the row Sven was on kept: after a read in place, or a Refresh.
    func refresh(keeping row: MenuEntry?) async -> MenuEntry.Target? {
        show(rows())
        return row?.target
    }

    /// The rows for where the listing stands.
    func rows() -> [MenuEntry] {
        switch model.load {
        case .failed(let why): return [Self.status(why)]
        case .idle, .loading: return [Self.status(Self.reading)]
        case .loaded:
            let folders = model.folders(matching: "")
            return folders.isEmpty ? [Self.status("Raycast's store lists no extensions.")] : folders.map(row)
        }
    }

    static func status(_ text: String) -> MenuEntry {
        MenuEntry(title: text, target: .action("\(actionID)#status"), isAnswer: true, icon: .glyph("bag", .accent))
    }

    /// A folder as a row: its title once read (the folder's name until then), "Installed" or its description and author,
    /// its icon once fetched; the name stays a keyword, so typing it still finds the row.
    func row(_ folder: RaycastStore.Folder) -> MenuEntry {
        let info = model.infos[folder.name], installed = model.installedExtension(folder.name) != nil
        let line = installed ? "Installed" : info.map { [$0.description, $0.author.map { "by \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
            .flatMap { $0.isEmpty ? nil : $0 }
        var icon = MenuIcon.glyph("puzzlepiece.extension", installed ? .good : .accent)
        icon.file = model.iconFile(folder.name)
        var row = MenuEntry(title: model.title(folder.name), target: .action("\(Self.actionID)#\(folder.name)"),
                            keywords: info == nil ? nil : folder.name, subtitle: line, icon: icon)
        row.ownActions = actions(folder.name).map(\.label)
        return row
    }

    enum Act: Equatable {
        case details, install, commands, github, refresh

        var label: String {
            switch self {
            case .details: "Show details"
            case .install: "Install"
            case .commands: "Open commands"
            case .github: "Open on GitHub"
            case .refresh: "Refresh the store"
            }
        }
    }

    /// Return's first: an installed one's commands, a read one's Install, an unread one's details.
    func actions(_ folder: String) -> [Act] {
        if model.installedExtension(folder) != nil { return [.commands, .github, .refresh] }
        return model.infos[folder] != nil ? [.install, .github, .refresh] : [.details, .install, .github, .refresh]
    }

    func pick(_ row: MenuEntry, action index: Int) -> MenuPick {
        guard case .action(let id) = row.target, let hash = id.lastIndex(of: "#") else { return .stay }
        let folder = String(id[id.index(after: hash)...])
        guard model.listing?.folder(folder) != nil else { return .stay }
        let acts = actions(folder)
        guard acts.indices.contains(index) else { return .stay }
        let (model, hud, open) = (model, hud, open)
        switch acts[index] {
        case .details:
            return .keep(clear: false, back: false) { Task { await model.info(folder) } }
        case .install:
            return .close {
                hud("Installing \(model.title(folder)) from Raycast's store…")
                Task { hud(await model.installPressed(folder, from: "Hyper+Space's Raycast Store")) }
            }
        case .commands:
            guard let ext = model.installedExtension(folder) else { return .stay }
            return .push(ext.title, RaycastStoreCommands(ext))
        case .github:
            return .close { open(RaycastStore.pageURL(folder)) }
        case .refresh:
            return .keep(clear: false, back: false) { Task { await model.refresh() } }
        }
    }
}

/// An installed store extension's commands, pushed from its row: Return runs one, as its own row in Hyper+Space does.
@MainActor
final class RaycastStoreCommands: MenuSource {
    var show: ([MenuEntry]) -> Void = { _ in }
    private let ext: Extension

    init(_ ext: Extension) { self.ext = ext }

    func search(_ query: String) {
        show(ext.listed.map { command in
            var row = MenuEntry(title: command.title, target: .action(command.actionID), subtitle: ext.title, icon: .command(emoji: command.icon))
            row.ownActions = ["Run"]
            return row
        })
    }

    func pick(_ row: MenuEntry, action: Int) -> MenuPick {
        guard case .action(let id) = row.target else { return .stay }
        return .close { Engine.shared?.action(id)?.run() }
    }

    func close() {}
}
