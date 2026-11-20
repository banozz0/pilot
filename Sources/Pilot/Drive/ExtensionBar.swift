import Foundation
import PilotCore

/// The bar items installed extensions declare (story 161; Surfaces v2), each listed in Bar settings by title and every
/// one placed somewhere shown (Sven on build 52: no limit; six until then): each its command's short text and gauges
/// with a tone, its own item in the macOS menu bar or drawn where the top bar's Extensions item sits, as Sven placed it
/// (BarSettings.extensionItems). Asked only while one shows on a bar and the screen is in use (BarReadings holds and
/// pauses it), and only the placed ones (and those the pill holds while it shows them): each on its own pace, 60 s at
/// the most often, one run at a time on the one loop, 2 s each (a Raycast item's render 10 s), so n placed cost at most n short runs a minute, never
/// two at once; a run of an extension's own command asks its item in a round at once (`ask`). The folder is read again
/// on each round, so an install or an uninstall is followed within one. A Raycast extension has one item per `menu-bar`
/// command (T12): its first keeps the extension's id, so the dock, the popover and saved places find it, and each
/// later one is `<extension>/<command>`.
@Observable @MainActor
final class ExtensionBar {
    static let shared = ExtensionBar()

    /// One bar item as it last answered: its extension's, or one of a Raycast extension's (`command`, its pace `every`).
    struct Item: Equatable, Identifiable {
        let id: String, title: String, icon: String?
        var command = "", every = 0
        /// Its page, for the dropdown's Open page.
        let hasPage: Bool
        var answer: Extension.BarAnswer?
        /// Why it has nothing to show: an error, a timeout or a setting it needs.
        var problem: String?

        /// What it draws in a bar; nil with nothing to show.
        var face: ExtensionBarFace? { answer.flatMap { $0.shows ? ExtensionBarFace(id: id, title: title, answer: $0) : nil } }
    }

    /// The items, by their extensions' titles; an item asked for the first time has neither answer nor problem.
    private(set) var items: [Item] = []
    /// A round has read the folder: an extension missing from `items` since is not installed (the dock's Set up).
    private(set) var listed = false

    /// What `place` draws: the items placed there with something to show.
    func faces(in place: BarPlace) -> [ExtensionBarFace] { items.filter { shows($0.id, place) }.compactMap(\.face) }

    /// The items of `ids` in that order, as they last answered; one uninstalled since is left out (the pill's and the
    /// Pilot menu's picks).
    func items(_ ids: [String]) -> [Item] { ids.compactMap { id in items.first { $0.id == id } } }

    /// An extension's bar item's text as it last answered; nil when it has none.
    func text(for id: String) -> String? { items.first { $0.id == id }?.answer.flatMap { $0.text.isEmpty ? nil : $0.text } }

    /// Items surfaces beyond the bars hold while they show them (the pill's Extensions view, the Pilot menu's Extensions
    /// card; spec desktop-controls), by holder: asked as a placed item is, and only then.
    @ObservationIgnored private var holders: [String: Set<String>] = [:]
    var held: Set<String> { holders.values.reduce(into: []) { $0.formUnion($1) } }

    /// `holder` now shows `ids` (none: it closed). Newly held ones are asked at once.
    func hold(_ ids: Set<String>, for holder: String) {
        let before = held
        holders[holder] = ids.isEmpty ? nil : ids
        if !held.isSubset(of: before) { nudge() }
    }

    /// Whether an extension's item is placed in a bar now: Engine points it at Sven's placing in Bar settings; every
    /// item shows everywhere until then (tests).
    @ObservationIgnored var shows: @MainActor (_ id: String, _ place: BarPlace) -> Bool = { _, _ in true }

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let storage: ExtensionStorage
    @ObservationIgnored private let run: @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome
    @ObservationIgnored private let now: () -> Date
    /// The wait between rounds; a test's lasts until a nudge ends it.
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    /// When each extension was last asked.
    @ObservationIgnored private var asked: [String: Date] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The wait for the next round, its own task so `nudge` can end it early; `woken` says a nudge came during a round.
    @ObservationIgnored private var nap: Task<Void, Never>?
    @ObservationIgnored private var woken = false

    init(folder: URL = Extension.folder, storage: ExtensionStorage = ExtensionStorage(), now: @escaping () -> Date = Date.init,
         run: @escaping @Sendable (Extension.Surface, ExtensionRun.Inputs) async -> SurfaceOutcome = { await ExtensionRun.surface($0, inputs: $1) },
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0, tolerance: $0 / 10) }) {
        self.folder = folder; self.storage = storage; self.now = now; self.sleep = sleep; self.run = run
    }

    var isRunning: Bool { task != nil }

    /// The item shows on a bar again: a round now, then one each time the soonest is due. Only the round holds the bar,
    /// never the sleep between.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.woken = false
                // A loop stopped during its round ends here, never taking the next loop's nap.
                guard let wait = await self?.round(), !Task.isCancelled else { return }
                if self?.woken == true { continue }
                guard let sleep = self?.sleep else { return }
                let nap = Task { await sleep(.seconds(wait)) }
                self?.nap = nap
                await nap.value
            }
        }
    }

    /// An item was just placed in a bar: a round now, not at the next one due; one running finishes first, so two runs
    /// never overlap.
    func nudge() {
        guard task != nil else { return }
        woken = true
        nap?.cancel()
    }

    /// An extension's command just ran (a to-do added): its items are asked in a round now, past their pace, not at their
    /// next turn (Sven on build 23). Nothing runs while no bar shows; the next start asks them anyway.
    func ask(_ id: String) {
        asked = asked.filter { item, _ in item != id && !item.hasPrefix(id + "/") }
        nudge()
    }

    /// The item left every bar or the screen locked: no more runs; the items keep their last answers.
    func stop() {
        task?.cancel()
        nap?.cancel()
        task = nil
    }

    /// The installed extensions that declare a bar item, by title: the order the items are listed and drew in.
    nonisolated static func withBar(in folder: URL) -> [Extension] { Extension.find(in: folder).extensions.filter { $0.bar != nil } }

    /// Each of `ext`'s bar items with its id: the first the extension's own, a later one `<extension>/<command>` (T12).
    nonisolated static func bars(of ext: Extension) -> [(id: String, bar: Extension.Surface)] {
        ext.bars.enumerated().map { index, bar in (index == 0 ? ext.id : "\(ext.id)/\(bar.command.name)", bar) }
    }

    /// The installed extension and bar an item id names, read from `folder`; nil once it is gone.
    nonisolated static func bar(_ id: String, in folder: URL) -> (ext: Extension, bar: Extension.Surface)? {
        let name = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
        guard let ext = Extension.find(in: folder).extensions.first(where: { $0.id == name }) else { return nil }
        return bars(of: ext).first { $0.id == id }.map { (ext, $0.bar) }
    }

    /// Asks every bar item that is due, one at a time, and says how long until the next is; the folder is read off the
    /// main thread, and the items change once, only when an answer did.
    @discardableResult
    func round() async -> Int {
        let folder = folder
        let extensions = await Task.detached { Self.withBar(in: folder) }.value
        let bars = extensions.flatMap { ext in Self.bars(of: ext).map { (ext: ext, id: $0.id, bar: $0.bar) } }
        // Every one is listed; every one placed is asked.
        let shown = Set(bars.map(\.id).filter { shows($0, .menuBar) || shows($0, .topBar) || held.contains($0) })
        var next = bars.map { ext, id, bar in
            let last = items.first { $0.id == id }
            // A later item is titled by its command, after its extension.
            let title = id == ext.id ? ext.title : "\(ext.title): \(bar.command.title)"
            return Item(id: id, title: title, icon: ext.icon, command: bar.command.name, every: bar.every, hasPage: ext.page != nil,
                        answer: last?.answer, problem: last?.problem)
        }
        asked = asked.filter { id, _ in bars.contains { $0.id == id } }
        for (index, (ext, id, bar)) in bars.enumerated() {
            // An item placed in neither bar is not asked: it keeps what it last said.
            guard !Task.isCancelled, shown.contains(id) else { continue }
            if let last = asked[id], now().timeIntervalSince(last) < Double(bar.every) - 1 { continue }
            asked[id] = now()
            var why: String?
            guard let inputs = await ExtensionsModule.inputs(for: ext, command: bar.command, storage: storage, hud: { why = $0 }) else {
                (next[index].answer, next[index].problem) = (nil, why)
                continue
            }
            switch await run(bar, inputs) {
            case .bar(let answer): (next[index].answer, next[index].problem) = (answer, nil)
            case .error(let why):
                (next[index].answer, next[index].problem) = (nil, why)
                dlog.error("extension bar: \(id, privacy: .public) \(why, privacy: .private)")
            case .blocks: (next[index].answer, next[index].problem) = (nil, ExtensionRun.unreadable)
            }
        }
        if next != items { items = next }
        if !listed { listed = true }
        // The soonest due, never under the floor.
        let waits = bars.filter { shown.contains($0.id) }.map { _, id, bar in
            Int((asked[id].map { Double(bar.every) - now().timeIntervalSince($0) } ?? 0).rounded(.up))
        }
        return max(waits.min() ?? 120, 60)
    }
}
