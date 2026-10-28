import Foundation
import PilotCore

/// The menu's Extension catalogue (2026-10-10): a live picker that shows a row saying the catalogue is being read, then
/// a row per entry (its emoji, title, and "description · Installed | Update to 1.1 | Install"), which Pilot ranks as
/// Sven types. Return installs or updates an entry, or opens an installed one on the Extensions page; Cmd+K offers
/// Install or Update, Uninstall (asked first, as the page asks; to the Trash, settings kept, as its HUD says) and Show on
/// Extensions page. The index is read only now, as the picker opens.
@MainActor
final class ExtensionCatalogueMenu: MenuSource {
    static let actionID = "extensions.catalogue", title = "Extension catalogue"
    /// The row the picker shows while the index is read, and its reason row's prefix when it could not be.
    static let reading = "Reading Pilot's catalogue…"

    var show: ([MenuEntry]) -> Void = { _ in }
    private let model: ExtensionCatalogueModel
    /// What a pick runs once the panel closes: the HUD, and opening the Extensions page at an extension.
    private let hud: (String) -> Void
    private let page: (AppPlace, String) -> Void
    /// The menu's confirm step, Uninstall's question before anything moves (story 158).
    private let confirm: InstallModule.Confirm
    private var task: Task<Void, Never>?
    private var asked = false

    init(model: ExtensionCatalogueModel = .shared, hud: @escaping (String) -> Void = { HUD.tip($0) },
         page: @escaping (AppPlace, String) -> Void = { AppWindowController.shared.open($0, extension: $1) },
         confirm: @escaping InstallModule.Confirm = InstallModule.confirm) {
        self.model = model; self.hud = hud; self.page = page; self.confirm = confirm
    }

    /// The first search reads the catalogue; later ones are Pilot's to rank, since every row is listed once.
    func search(_ query: String) {
        guard !asked else { return }
        asked = true
        show([Self.status(Self.reading)])
        task = Task { [weak self, model] in
            await model.open()
            guard !Task.isCancelled else { return }
            self?.showRows()
        }
    }

    /// The read or the install in flight has finished.
    func settled() async { await task?.value }

    func close() { task?.cancel() }

    /// The rows for where the catalogue stands.
    private func showRows() {
        switch model.load {
        case .failed(let why): show([Self.status(why)])
        case .idle, .loading: show([Self.status(Self.reading)])
        case .loaded:
            let entries = model.entries()
            show(entries.isEmpty ? [Self.status("Pilot's catalogue lists no extensions yet.")] : entries.map(row))
        }
    }

    /// A line in place of rows, never ranked or picked: reading, empty, or why it could not be read.
    static func status(_ text: String) -> MenuEntry {
        MenuEntry(title: text, target: .action("\(actionID)#status"), isAnswer: true, icon: .command(emoji: nil))
    }

    /// An entry as a row, its actions by where it stands, Return's first.
    func row(_ entry: ExtensionCatalogue.Entry) -> MenuEntry {
        let standing = model.standing(of: entry)
        var row = MenuEntry(title: entry.title, target: .action("\(Self.actionID)#\(entry.id)"), keywords: ExtensionCatalogue.keywords(entry),
                            subtitle: ExtensionCatalogue.subtitle(entry, standing), icon: .command(emoji: entry.icon))
        row.ownActions = Self.actions(standing).map { $0.label(entry, standing) }
        return row
    }

    /// What Cmd+K lists for an entry, the first Return's.
    enum Act: Equatable {
        case install, remove, show

        /// "Install", or "Update to 1.1" for one older there.
        func label(_ entry: ExtensionCatalogue.Entry, _ standing: ExtensionCatalogue.Standing) -> String {
            switch self {
            case .install: ExtensionCatalogue.button(entry, standing)   // offered only to install or update
            case .remove: "Uninstall"
            case .show: "Show on Extensions page"
            }
        }
    }

    /// Not installed: Install, Show; older there: Update, Uninstall, Show; installed: Show, Uninstall.
    static func actions(_ standing: ExtensionCatalogue.Standing) -> [Act] {
        switch standing {
        case .install: [.install, .show]
        case .update: [.install, .remove, .show]
        case .installed: [.show, .remove]
        }
    }

    /// Uninstall from the menu, here and on an Extensions branch row (story 158): asked first, in the page's words, then
    /// the folder to the Trash and the HUD's line; nothing moves on Cancel.
    static func askUninstall(_ id: String, title: String, model: ExtensionCatalogueModel = .shared, hud: @escaping (String) -> Void = { HUD.tip($0) },
                             confirm: InstallModule.Confirm = InstallModule.confirm) {
        confirm(ExtensionCatalogue.uninstallQuestion(title), ExtensionCatalogue.uninstallNote) {
            Task { if let line = await model.remove(id) { hud(line) } }
        }
    }

    func pick(_ row: MenuEntry, action index: Int) -> MenuPick {
        guard case .action(let id) = row.target, let hash = id.lastIndex(of: "#"),
              let entry = model.index?.entry(String(id[id.index(after: hash)...])) else { return .stay }
        let acts = Self.actions(model.standing(of: entry))
        guard acts.indices.contains(index) else { return .stay }
        let (model, hud, page, confirm) = (model, hud, page, confirm)
        switch acts[index] {
        case .install:
            return .close {
                hud(model.standing(of: entry) == .update ? "Updating \(entry.title)…" : "Installing \(entry.title)…")
                Task { if let line = await model.install(entry) { hud(line) } }
            }
        case .remove:
            return .close { Self.askUninstall(entry.id, title: entry.title, model: model, hud: hud, confirm: confirm) }
        case .show:
            let place = model.installed[entry.id] == nil ? AppPlace(.extensionCatalogue) : AppPlace(.extensions)
            return .close { page(place, entry.id) }
        }
    }
}
