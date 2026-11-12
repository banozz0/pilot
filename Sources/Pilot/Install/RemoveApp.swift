import AppKit
import PilotCore
import SwiftUI
import WebApps

/// A running copy of an app, as Remove's quit step needs it: NSRunningApplication, or a test's stand-in.
@MainActor
protocol RunningCopy: AnyObject {
    var isTerminated: Bool { get }
    @discardableResult func terminate() -> Bool
    @discardableResult func forceTerminate() -> Bool
}

extension NSRunningApplication: RunningCopy {}

/// Return on a Remove row for an app (Sven, 2026-11-12, Q181): one ask; an app that runs is quit first (a normal quit,
/// then Force quit offered when it has not gone within a few seconds), and only then moved to the Trash, with the
/// administrator's prompt for an App Store app (AdminTrash). Once it is there, its leftovers in ~/Library are offered,
/// ticked but for any another installed app may share (AppLeftovers); the chosen go to the Trash, never deleted.
@MainActor
enum RemoveApp {
    typealias Running = @MainActor (String) -> [any RunningCopy]
    typealias AskForce = @MainActor (_ name: String) async -> Bool

    /// The running copies of a bundle id; none in an isolated test run, so no test quits one of Sven's apps.
    static let running: Running = { id in
        isIsolatedTestRun ? [] : NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
    }

    /// The running copies of the app at `location`, by the bundle id in its Info.plist (one file read).
    static func copies(of location: URL, running: Running = running) -> [any RunningCopy] {
        AppLeftovers.App.bundleID(at: location).map(running) ?? []
    }

    /// Remove on an app or a web app: the ask, quitting first when it runs, then the Trash, then its leftovers; `then`
    /// runs once the Trash answered (Install › Web apps refreshes its list).
    static func remove(_ name: String, at location: URL, confirm: InstallModule.Confirm, trash: @escaping @MainActor (URL) throws -> URL,
                       running: @escaping Running = running, askForce: @escaping AskForce = menuAskForce, wait: Duration = .seconds(5),
                       leftovers: @escaping @MainActor (AppLeftovers.App) -> Void = offerLeftovers, then: @escaping @MainActor () -> Void = {}) {
        let file = location.lastPathComponent
        quitThen(name, location, ask: "Move \(file) to the Trash", after: "move \(file) to the Trash", confirm: confirm, running: running, askForce: askForce, wait: wait,
                 stillOpen: "so it stays where it is") { reading in
            AdminTrash.trash(location, plain: trash) { result in
                switch result {
                case .success(let trashed):
                    ilog.notice("removed \(name, privacy: .public) to \(trashed.path, privacy: .public)")
                    offer(reading, leftovers)
                case .failure(let error):
                    ilog.error("\(name, privacy: .public) not removed: \(error.localizedDescription, privacy: .public)")
                    HUD.tip(AdminTrash.said(error) ?? "\(name) could not go to the Trash")
                }
                then()
            }
        }
    }

    /// Remove on a cask with an app (Q181): the ask shows the exact command; at the yes the app is quit, then the command
    /// runs in the visible terminal, and its leftovers wait for its `removed` hook.
    static func removeCask(_ name: String, command: String, key: String, app location: URL, confirm: InstallModule.Confirm,
                           run: @escaping InstallModule.Run, running: @escaping Running = running, askForce: @escaping AskForce = menuAskForce,
                           wait: Duration = .seconds(5)) {
        quitThen(name, location, ask: command, after: command, confirm: confirm, running: running, askForce: askForce, wait: wait,
                 stillOpen: "so nothing ran") { reading in
            pending[key] = reading
            run(command, "Remove \(name)", InstallModule.hook("removed", key: key))
        }
    }

    /// Remove's shared steps: the app's ids read off the main thread while the ask is up (it is gone after); the ask, "Quit
    /// and remove" with "Quit <name>, then <after>" when it runs, else `ask`; at the yes, the running copies read again and quit; `act`
    /// once none runs, else a tip and nothing done.
    private static func quitThen(_ name: String, _ location: URL, ask: String, after: String, confirm: InstallModule.Confirm, running: @escaping Running,
                                 askForce: @escaping AskForce, wait: Duration, stillOpen: String,
                                 _ act: @escaping @MainActor (Task<AppLeftovers.App?, Never>) -> Void) {
        let reading = Task.detached(priority: .userInitiated) { AppLeftovers.App.read(location) }
        let open = !copies(of: location, running: running).isEmpty
        confirm(open ? "Quit and remove \(name)" : "Remove \(name)", open ? "Quit \(name), then \(after)" : ask) {
            let now = copies(of: location, running: running)
            guard !now.isEmpty else { return act(reading) }
            Task {
                guard await quit(now, name: name, wait: wait, askForce: askForce) else {
                    ilog.notice("\(name, privacy: .public) not removed: still running")
                    return HUD.tip("\(name) is still open, \(stillOpen)")
                }
                act(reading)
            }
        }
    }

    /// The casks whose command runs in the terminal, each with its app as read before, by package key: their leftovers
    /// are offered once the command's `removed` hook comes back; a failed command's stays until the next Remove of it.
    static var pending: [String: Task<AppLeftovers.App?, Never>] = [:]

    /// The `removed` hook for `key`: a cask Remove ran offers its leftovers; any other key nothing.
    static func removed(_ key: String, leftovers: @escaping @MainActor (AppLeftovers.App) -> Void = offerLeftovers) {
        pending.removeValue(forKey: key).map { offer($0, leftovers) }
    }

    private static func offer(_ reading: Task<AppLeftovers.App?, Never>, _ leftovers: @escaping @MainActor (AppLeftovers.App) -> Void) {
        Task { if let app = await reading.value { leftovers(app) } }
    }

    /// Quits every copy: a normal quit, `wait` for it; then, on Force quit's yes, a force quit and `forceWait`. True once
    /// none runs.
    static func quit(_ copies: [any RunningCopy], name: String, wait: Duration = .seconds(5), forceWait: Duration = .seconds(3),
                     askForce: AskForce) async -> Bool {
        copies.forEach { $0.terminate() }
        if await gone(copies, within: wait) { return true }
        ilog.notice("\(name, privacy: .public) did not quit within \(wait, privacy: .public): asking to force quit")
        guard await askForce(name) else { return false }
        copies.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        return await gone(copies, within: forceWait)
    }

    private static func gone(_ copies: [any RunningCopy], within limit: Duration) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end, !copies.allSatisfy(\.isTerminated) { try? await Task.sleep(for: .milliseconds(100)) }
        return copies.allSatisfy(\.isTerminated)
    }

    /// Force quit's ask in the menu's own picker; Escape is a no.
    static let menuAskForce: AskForce = { name in
        await withCheckedContinuation { answer in
            var answered = false
            func say(_ yes: Bool) { if !answered { answered = true; answer.resume(returning: yes) } }
            let force = MenuEntry(title: "Force quit \(name)", target: .action("install.forceQuit"), detail: "Unsaved work in it is lost")
            PilotMenu.shared.pick([force, MenuEntry(title: "Cancel", target: .action("install.cancel"))], title: "\(name) didn't quit",
                                  cancelled: { say(false) }) { say($0 == force) }
        }
    }

    /// Every other app Remove sees, read off the main thread, and `app`'s leftovers measured against them; the panel when
    /// there are any.
    static let offerLeftovers: @MainActor (AppLeftovers.App) -> Void = { app in
        Task {
            let found = await leftovers(of: app)
            guard !found.isEmpty else { return ilog.notice("\(app.name, privacy: .public): no leftovers") }
            LeftoversPanel.show(LeftoversModel(app: app.name, items: found))
        }
    }

    /// `app`'s leftovers, checked against every other app the Apps list scans (its id and name), each measured.
    @concurrent nonisolated static func leftovers(of app: AppLeftovers.App, library: URL = AppLeftovers.library) async -> [AppLeftovers.Item] {
        // Never Pilot: it stamps every web app under its own id (dev.banozz.pilot.webapp.…), but reads none of their files.
        let others = AppsModule.installedAppFiles().filter { $0.bundle != UninstallPlaces.bundleID }
            .map { AppLeftovers.App(bundleID: $0.bundle, name: $0.name, path: $0.url.path(percentEncoded: false)) }
        return AppLeftovers.find(app, others: others, library: library, size: Uninstall.bytes, webApp: app.bundleID.hasPrefix(WebAppSpec.bundleIDPrefix))
    }
}

/// The leftovers panel's state: the items, which are ticked, and the Trash they go to (FileOps': a test run's throwaway
/// one; an item root owns asks for an administrator).
@MainActor @Observable
final class LeftoversModel {
    let app: String
    let items: [AppLeftovers.Item]
    var ticked: Set<String>
    var working = false
    @ObservationIgnored let trash: FileOps.Trash

    init(app: String, items: [AppLeftovers.Item], trash: @escaping FileOps.Trash = FileOps.systemTrash) {
        self.app = app; self.items = items; self.trash = trash
        ticked = Set(items.filter(\.tickedFirst).map(\.id))
    }

    var chosen: [AppLeftovers.Item] { items.filter { ticked.contains($0.id) } }
    var total: Int64 { chosen.compactMap(\.bytes).reduce(0, +) }
    func toggle(_ id: String) { ticked.formSymmetricDifference([id]) }

    /// The chosen to the Trash, one at a time; what it says after: how many went, and each that did not with why.
    func moveToTrash() async -> String {
        working = true
        defer { working = false }
        var failed: [String] = []
        let chosen = chosen
        for item in chosen {
            do { _ = try await trash(item.url) } catch {
                failed.append("\(item.place)/\(item.url.lastPathComponent): \(AdminTrash.said(error) ?? error.localizedDescription)")
            }
        }
        ilog.notice("\(self.app, privacy: .public) leftovers: \(chosen.count - failed.count) of \(chosen.count) to the Trash")
        guard !failed.isEmpty else { return "\(app)'s \(chosen.count == 1 ? "leftover is" : "\(chosen.count) leftovers are") in the Trash" }
        return "\(failed.count) of \(app)'s leftovers did not go to the Trash: " + failed.joined(separator: "; ")
    }
}

/// The leftovers panel (UninstallSheet's rows): each item by place with its size, ticked or not, Keep closing it with
/// nothing moved and Move to Trash moving the ticked.
struct LeftoversView: View {
    @Environment(\.ink) private var ink
    @State var model: LeftoversModel
    let done: @MainActor (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(model.app)'s leftovers").font(ink.ui(16, .semibold))
            Text("\(model.app) is in the Trash. Tick what of its files in your Library goes too; everything goes to the Trash.")
                .font(ink.ui(12)).foregroundStyle(ink.muted).padding(.top, 4).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        if i == 0 || model.items[i - 1].place != item.place { PartHeading(text: item.place) }
                        row(item)
                    }
                }
            }
            .frame(maxHeight: 360).fixedSize(horizontal: false, vertical: true)
            footer.padding(.top, 16)
        }
        .padding(18)
        .frame(width: 480)
    }

    private func row(_ item: AppLeftovers.Item) -> some View {
        TickRow(title: item.url.lastPathComponent, detail: item.logins ? "Its saved logins" : item.sharedWith.map { "\($0) may use it too" },
                size: item.bytes.map(RemoveList.size) ?? "—", ticked: model.ticked.contains(item.id)) { model.toggle(item.id) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Frees \(Text(RemoveList.size(model.total)).foregroundStyle(ink.text).fontWeight(.semibold))")
                .font(ink.ui(12)).foregroundStyle(ink.muted).frame(maxWidth: .infinity, alignment: .leading)
            Button("Keep") { done(nil) }.buttonStyle(.pilot).keyboardShortcut(.cancelAction)
            Button("Move to Trash") { Task { done(await model.moveToTrash()) } }
                .buttonStyle(PilotButtonStyle(primary: true, destructive: true))
                .disabled(model.chosen.isEmpty || model.working)
        }
    }
}

/// The one leftovers panel on screen; a second Remove's replaces it.
@MainActor
enum LeftoversPanel {
    private static var open: KeyPanel?

    static func show(_ model: LeftoversModel) {
        close()
        let panel = HUD.makePanel(LeftoversView(model: model) { said in
            close()
            if let said { HUD.tip(said) }
        })
        panel.escape = { close() }
        panel.orderFrontRegardless()
        panel.makeKey()
        open = panel
        ilog.notice("\(model.app, privacy: .public): \(model.items.count) leftovers offered, \(model.ticked.count) ticked")
    }

    static func close() {
        open?.orderOut(nil)
        open = nil
    }
}
