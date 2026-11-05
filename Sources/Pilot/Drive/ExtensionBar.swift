import Foundation
import PilotCore

/// The bar items installed extensions declare (story 161; Surfaces v2), each listed in Bar settings by title and every
/// one placed somewhere shown (Sven on build 52: no limit; six until then): each its command's short text and gauges with
/// a tone, its own item in the macOS menu bar or drawn where the top bar's Extensions item sits, as Sven placed it
/// (BarSettings.extensionItems). Asked only while one shows on a bar and the screen is in use (BarReadings holds and
/// pauses it), and only the placed ones: each on its own pace, 60 s at the most often, one run at a time on the one loop,
/// 2 s each, so n placed cost at most n short runs a minute, never two at once; a run of an extension's own command asks
/// its item in a round at once (`ask`). The folder is read again on each round, so an install or an uninstall is
/// followed within one.
@Observable @MainActor
final class ExtensionBar {
    static let shared = ExtensionBar()

    /// One extension's bar item as it last answered.
    struct Item: Equatable, Identifiable {
        let id: String, title: String, icon: String?
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

    /// What `place` draws: the items placed there with something to show.
    func faces(in place: BarPlace) -> [ExtensionBarFace] { items.filter { shows($0.id, place) }.compactMap(\.face) }

    /// An extension's bar item's text as it last answered; nil when it has none.
    func text(for id: String) -> String? { items.first { $0.id == id }?.answer.flatMap { $0.text.isEmpty ? nil : $0.text } }

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

    /// An extension's command just ran (a to-do added): its item is asked in a round now, past its pace, not at its next
    /// turn (Sven on build 23). Nothing runs while no bar shows; the next start asks it anyway.
    func ask(_ id: String) {
        asked[id] = nil
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

    /// Asks every bar item that is due, one at a time, and says how long until the next is; the folder is read off the
    /// main thread, and the items change once, only when an answer did.
    @discardableResult
    func round() async -> Int {
        let folder = folder
        let extensions = await Task.detached { Self.withBar(in: folder) }.value
        // Every one is listed; every one placed is asked.
        let shown = Set(extensions.map(\.id).filter { shows($0, .menuBar) || shows($0, .topBar) })
        var next = extensions.map { ext in
            let last = items.first { $0.id == ext.id }
            return Item(id: ext.id, title: ext.title, icon: ext.icon, hasPage: ext.page != nil, answer: last?.answer, problem: last?.problem)
        }
        asked = asked.filter { id, _ in extensions.contains { $0.id == id } }
        for (index, ext) in extensions.enumerated() {
            // An item placed in neither bar is not asked: it keeps what it last said.
            guard let bar = ext.bar, !Task.isCancelled, shown.contains(ext.id) else { continue }
            if let last = asked[ext.id], now().timeIntervalSince(last) < Double(bar.every) - 1 { continue }
            asked[ext.id] = now()
            var why: String?
            guard let inputs = await ExtensionsModule.inputs(for: ext, storage: storage, hud: { why = $0 }) else {
                (next[index].answer, next[index].problem) = (nil, why)
                continue
            }
            switch await run(bar, inputs) {
            case .bar(let answer): (next[index].answer, next[index].problem) = (answer, nil)
            case .error(let why):
                (next[index].answer, next[index].problem) = (nil, why)
                dlog.error("extension bar: \(ext.id, privacy: .public) \(why, privacy: .private)")
            case .blocks: (next[index].answer, next[index].problem) = (nil, ExtensionRun.unreadable)
            }
        }
        if next != items { items = next }
        // The soonest due, never under the floor.
        let waits = extensions.filter { shown.contains($0.id) }.compactMap { ext in ext.bar.map { bar in
            Int((asked[ext.id].map { Double(bar.every) - now().timeIntervalSince($0) } ?? 0).rounded(.up))
        } }
        return max(waits.min() ?? 120, 60)
    }
}
