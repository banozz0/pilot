import AppKit
import OSLog
import PilotCore
import Quartz
import WebApps

/// Quick Look on a file: Space on a file in the menu's Files view (Sven, 2026-10-07).
@MainActor
protocol QuickLooking: AnyObject {
    func preview(_ url: URL)
}

/// The apps that open a file, the suggested (its default first) and the rest, and opening the file in one: Open With…
/// on a file row.
@MainActor
protocol OpeningApps: AnyObject {
    func apps(toOpen url: URL) -> (suggested: [URL], others: [URL])
    func open(_ urls: [URL], with app: URL)
}

/// The menu's file actions beyond a path (Sven, 2026-10-07, "yes to file search idea"): Move to Trash asks first, Open
/// With… picks an app in the menu's own picker, Space previews in Quick Look.
@MainActor
enum FileActions {
    typealias Pick = @MainActor (_ rows: [MenuEntry], _ title: String, _ then: @escaping @MainActor (MenuEntry) -> Void) -> Void
    /// The menu's own picker.
    static let menuPick: Pick = { rows, title, then in PilotMenu.shared.pick(rows, title: title) { row in then(row) } }

    /// Asks with the file's name and path, then moves it to the Trash, where Finder can put it back.
    static func trash(_ path: String, confirm: InstallModule.Confirm = InstallModule.confirm,
                      trash: @escaping @MainActor (URL) throws -> URL = WebAppDirectory.trash) {
        let url = URL(filePath: path)
        confirm("Move \(url.lastPathComponent) to the Trash", path) {
            // A file root owns asks for an administrator, as Finder does (AdminTrash).
            AdminTrash.trash(url, plain: trash) { result in
                switch result {
                case .success(let trashed):
                    // A recording's copy with its pointer drawn in goes with it (Q821), off the main thread: it is large.
                    Task.detached(priority: .utility) { RecordingHandout.forget([url]) }
                    flog.notice("trashed \(path, privacy: .public) to \(trashed.path, privacy: .public)")
                case .failure(let cancelled as AdminTrash.Cancelled):
                    flog.notice("\(path, privacy: .public) not trashed: the password was cancelled")
                    HUD.tip(cancelled.localizedDescription)
                case .failure(let error):
                    flog.error("\(path, privacy: .public) not trashed: \(error.localizedDescription, privacy: .public)")
                    HUD.tip("\(url.lastPathComponent) could not go to the Trash")
                }
            }
        }
    }

    /// The apps that open the first URL as a picker, the suggested under Suggested (the default first, OpenWithApps) and
    /// the rest under Other apps, each an app row (its icon from the app-icon cache), and every URL opened in the one
    /// picked: a file row's Open With…, and the clipboard's (card agent-bo-95422994).
    static func openWith(_ urls: [URL], apps: OpeningApps = WorkspaceApps.shared,
                         pick: Pick = menuPick) {
        guard let first = urls.first else { return }
        var located: [String: URL] = [:]
        let listed = apps.apps(toOpen: first), headed = !listed.suggested.isEmpty && !listed.others.isEmpty
        let rows = [("Suggested", listed.suggested), ("Other apps", listed.others)].flatMap { section, list in
            list.compactMap { app -> MenuEntry? in
                let id = Bundle(url: app)?.bundleIdentifier ?? app.path
                guard located[id] == nil else { return nil }
                located[id] = app
                var row = MenuEntry(title: AppsModule.appName(at: app), target: .app(id))
                if headed { row.section = section }
                return row
            }
        }
        let name = urls.count > 1 ? "\(urls.count) items" : first.isFileURL ? first.lastPathComponent : first.host ?? first.absoluteString
        pick(rows, "Open \(name) with") { row in
            guard case .app(let id) = row.target, let app = located[id] else { return }
            apps.open(urls, with: app)
        }
    }

    static func preview(_ path: String, quickLook: QuickLooking = SystemQuickLook.shared) {
        quickLook.preview(URL(filePath: path))
    }
}

private let flog = Logger(subsystem: "dev.banozz.pilot", category: "files")

/// LaunchServices' apps for a file through NSWorkspace.
final class WorkspaceApps: OpeningApps {
    static let shared = WorkspaceApps()

    func apps(toOpen url: URL) -> (suggested: [URL], others: [URL]) {
        let type = OpenWithApps.type(of: url)
        return OpenWithApps.split(NSWorkspace.shared.urlsForApplications(toOpen: url), type: type, ext: url.isFileURL ? url.pathExtension : nil,
                                  main: NSWorkspace.shared.urlForApplication(toOpen: url))
    }

    func open(_ urls: [URL], with app: URL) {
        if let first = urls.first, let type = OpenWithApps.type(of: first), let id = Bundle(url: app)?.bundleIdentifier {
            OpenWithApps.picked(id, for: type)
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { flog.error("open with: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// QuickLook's own panel, Pilot its data source. Pilot comes forward so the panel takes the keyboard (Escape and Space
/// close it), and the app Sven was in comes back when it closes.
final class SystemQuickLook: NSObject, QuickLooking, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = SystemQuickLook()
    private var item: URL?
    private var previous: NSRunningApplication?

    func preview(_ url: URL) {
        item = url
        let front = NSWorkspace.shared.frontmostApplication
        previous = front
        // Taken from the front app, as WindowFocus does: a plain NSApp.activate() is refused on macOS 26.
        NSRunningApplication.current.activate(from: front ?? .current, options: [])
        guard let panel = QLPreviewPanel.shared() else { return flog.error("quick look: no panel") }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        flog.notice("quick look \(url.path, privacy: .public)")
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { item as NSURL? }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let previous, previous != .current, NSApp.isActive { previous.activate(from: .current, options: []) }
            previous = nil
        }
    }
}
