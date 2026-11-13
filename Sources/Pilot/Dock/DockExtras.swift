import AppKit
import Observation
import PilotCore
import SwiftUI

/// What the round 5 widgets read beyond the bar's readers (Sven's Lumabar picks, Q217): Bluetooth's power and Do Not
/// Disturb for Quick toggles, the newest files for Recent files, Notes' scratch for Scratch note, where this time zone's
/// city stands for the sun, the busiest apps for System stats, and the stopwatch. Read only while a widget shows them
/// (`follow`), each on a slow pace or when its panel opens; nothing here asks for a permission.
@Observable @MainActor
final class DockExtras {
    static let shared = DockExtras()
    static let stopwatchKey = "dock.stopwatch"

    private(set) var bluetooth: Bool?
    private(set) var dnd: Bool?
    private(set) var files: [DockStack: [DockFile]] = [:]
    private(set) var scratch: String?
    private(set) var place: (latitude: Double, longitude: Double)?
    var stopwatch: DockStopwatch {
        didSet { defaults.set(try? JSONEncoder().encode(stopwatch), forKey: Self.stopwatchKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var appsWatch: Task<Void, Never>?
    @ObservationIgnored private var followed: Set<DockWidget> = []
    @ObservationIgnored private var stacks: [DockStack] = []
    @ObservationIgnored private var placed: String?
    /// Each watched file's or folder's modification date when last read.
    @ObservationIgnored private var stamps: [URL: Date?] = [:]
    @ObservationIgnored private var recentRead: Date?

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        stopwatch = defaults.data(forKey: Self.stopwatchKey).flatMap { try? JSONDecoder().decode(DockStopwatch.self, from: $0) } ?? DockStopwatch()
    }

    /// The widgets showing now and their choices: a source newly shown is read now; then every 30 s each is read again
    /// only where its file or folder changed (Recent files' Spotlight list every ten minutes, and when its panel opens);
    /// the busiest apps through the sampler's process list every 30 s while System stats picks them.
    func follow(_ widgets: [DockSlot], options: DockWidgetOptions, sampler: SystemSampler = .shared) {
        let now = Set(widgets.compactMap(\.widget)), nowStacks = now.contains(.stacks) ? options.stacks : []
        let added = now.subtracting(followed), addedStacks = nowStacks.filter { !stacks.contains($0) }
        (followed, stacks) = (now, nowStacks)
        let wantsApps = followed.contains(.system) && !options.topApps.isEmpty
        if wantsApps, appsWatch == nil {
            appsWatch = Task { await sampler.watch(every: .seconds(30), needs: [.apps]) }
        } else if !wantsApps {
            appsWatch?.cancel()
            appsWatch = nil
        }
        guard !followed.isDisjoint(with: [.toggles, .stacks, .note, .clock]) else { return stopTimer() }
        // Only what was just shown: an edit on the Dock page (a key typed in a field) reads nothing again.
        if added.contains(.toggles) { readToggles(force: true) }
        if added.contains(.note) { readScratch(force: true) }
        if added.contains(.clock) { readPlace() }
        if !addedStacks.isEmpty { readFiles(addedStacks, force: true) }
        if timer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Each followed source read again where it changed.
    private func tick() {
        if followed.contains(.toggles) { readToggles() }
        if followed.contains(.note) { readScratch() }
        if followed.contains(.clock) { readPlace() }
        if !stacks.isEmpty { readFiles(stacks) }
    }

    /// Whether `url` changed since last asked: its modification date against the one kept. Always true with `force`.
    private func changed(_ url: URL, force: Bool = false) -> Bool {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        defer { stamps[url] = date }
        return force || stamps[url] != date
    }

    func readToggles(force: Bool = false) {
        let now = BluetoothPower.state(SystemModule.bluetooth)
        if now != bluetooth { bluetooth = now }
        let file = PilotFolder.home.appending(path: "Library/DoNotDisturb/DB/Assertions.json")
        guard changed(file, force: force) else { return }
        let on = Self.focusOn((try? Data(contentsOf: file)))
        if on != dnd { dnd = on }
    }

    /// Whether a Focus is on, from macOS's own assertions file: any record in its store. Nil when it cannot be read.
    nonisolated static func focusOn(_ data: Data?) -> Bool? {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return nil }
        return entries.contains { (($0["storeAssertionRecords"] as? [Any]) ?? []).isEmpty == false }
    }

    private func readScratch(force: Bool = false) {
        let file = NotesPanel.shared.folder.appending(path: NoteStore.scratch)
        guard changed(file, force: force) else { return }
        let text = try? String(contentsOf: file, encoding: .utf8)
        if text != scratch { scratch = text }
    }

    private func readPlace() {
        let zone = TimeZone.autoupdatingCurrent.identifier
        guard zone != placed else { return }
        placed = zone
        Task {
            let found = await Task.detached { (try? String(contentsOf: DockZones.table, encoding: .utf8)).flatMap { DockZones.place(zone, in: $0) } }.value
            place = found
        }
    }

    /// The stacks' newest files: Downloads and the captures folder listed, recent files from Spotlight, under Pilot's
    /// home (a test run's own).
    func readFiles(_ asked: [DockStack], force: Bool = false) {
        let captures = CaptureFiles.folder(.capture, picked: CaptureSettingsStore.shared.settings.capturesFolder, home: PilotFolder.home)
        let home = PilotFolder.home
        let folders: [DockStack: URL] = [.downloads: home.appending(path: "Downloads"), .captures: captures]
        let spotlightDue = force || recentRead.map { Date().timeIntervalSince($0) >= 600 } ?? true
        let stacks = asked.filter { stack in folders[stack].map { changed($0, force: force) } ?? spotlightDue }
        guard !stacks.isEmpty else { return }
        if stacks.contains(.recent) { recentRead = Date() }
        Task {
            let read = await Task.detached { () -> [DockStack: [DockFile]] in
                var found: [DockStack: [DockFile]] = [:]
                for stack in stacks {
                    switch stack {
                    case .downloads, .captures: found[stack] = folders[stack].map { DockFile.newest(in: $0) }
                    case .recent: found[stack] = await Self.recentFiles(home)
                    }
                }
                return found
            }.value
            let merged = files.merging(read) { _, new in new }
            if merged != files { files = merged }
        }
    }

    /// The files opened in the last week under `home`, newest first: Spotlight's own list (mdfind in a child), each
    /// file's last open from its metadata. Folders, apps and Library are left out.
    nonisolated static func recentFiles(_ home: URL, limit: Int = 12) async -> [DockFile] {
        guard let found = try? await ChildProcess.run("/usr/bin/mdfind", ["-onlyin", home.path(percentEncoded: false), "kMDItemLastUsedDate >= $time.today(-7)"],
                                                      timeout: .seconds(5), limit: 400_000) else { return [] }
        let paths = found.split(separator: "\n").map(String.init).filter { !$0.contains("/Library/") && !$0.contains("/.") && !$0.hasSuffix(".app") }
        return paths.prefix(300).compactMap { path -> DockFile? in
            let url = URL(filePath: path)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let used = AppsModule.lastUsed(url) else { return nil }
            return DockFile(url: url, date: used)
        }
        .sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    /// Do Not Disturb's toggle: the Shortcut the widget names (macOS gives apps no switch for Focus), else Focus settings.
    func toggleDND(shortcut: String) {
        guard !shortcut.isEmpty else { return openFocusSettings() }
        Task {
            do {
                _ = try await ChildProcess.run("/usr/bin/shortcuts", ["run", shortcut], timeout: .seconds(10))
                docklog.notice("dock: do not disturb shortcut ran")
            } catch {
                docklog.error("dock: do not disturb shortcut: \(String(describing: error), privacy: .public)")
                HUD.tip("No Shortcut named \(shortcut): set it in the Dock page's Quick toggles", seconds: 3)
            }
            try? await Task.sleep(for: .seconds(1))
            readToggles()
        }
    }

    func openFocusSettings() { SystemModule.pane("com.apple.Focus-Settings.extension") }
}

/// A stack's files over its icon: each with its kind's icon, name and when; a pick opens it in Pilot Files, its folder
/// open beside it; Open in Files the folder.
struct DockStackPanel: View {
    @Environment(\.ink) private var ink
    let stack: DockStack
    let files: [DockFile]
    let open: (DockFile) -> Void
    let openFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stack.title.uppercased()).font(ink.mono(11)).foregroundStyle(ink.muted).padding(.horizontal, 10).padding(.bottom, 4)
            if files.isEmpty {
                Text("Nothing here yet").font(ink.ui(13)).foregroundStyle(ink.text2).padding(10)
            }
            ForEach(files, id: \.url) { file in
                Button { open(file) } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path(percentEncoded: false))).resizable().frame(width: 22, height: 22)
                        Text(file.name).font(ink.ui(13)).foregroundStyle(ink.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(file.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated)).font(ink.mono(11)).foregroundStyle(ink.text2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if stack != .recent {
                Divider().padding(.vertical, 4)
                Button(action: openFolder) {
                    Label("Open \(stack.title) in Files", systemImage: "folder").font(ink.ui(13)).foregroundStyle(ink.text2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .barPopover(width: 340)
    }
}
