import AppKit
import Observation
import OSLog
import PilotCore

let shelflog = Logger(subsystem: "dev.banozz.pilot", category: "shelf")

/// One place on the Window shelf: a shelved window, or a group Sven joined, in the tiler's order; then each window
/// minimized from that workspace (Q690).
struct ShelfItem: Equatable, Identifiable {
    let windows: [AeroWindow]

    /// The group's first window: what a click focuses, which brings the whole group to the stage (ADR 0015).
    var id: Int { windows[0].id }
    /// A minimized window: a click restores it onto the stage.
    var isMinimized: Bool { windows[0].isMinimized }
    /// "Finder · Downloads", or "Chrome · 2 windows" for a group (the previews' variant B).
    var label: String {
        let apps = windows.map(\.appName).uniqued()
        if windows.count == 1 { return windows[0].title.isEmpty ? windows[0].appName : "\(windows[0].appName) · \(windows[0].title)" }
        return apps.count == 1 ? "\(apps[0]) · \(windows.count) windows" : apps.joined(separator: ", ")
    }
}

/// Another workspace, folded into one group on the shelf (the previews' variant A, Q681): its first windows as a stack.
struct ShelfWorkspace: Equatable, Identifiable {
    let name: String
    let windows: [AeroWindow]

    var id: String { name }
    /// The stack's windows, front last: three at most.
    var stack: [AeroWindow] { Array(windows.prefix(3).reversed()) }
    /// "Paper, Chrome": each app once.
    var label: String { windows.map(\.appName).uniqued().joined(separator: ", ") }
}

/// The shelf on one screen: the Stage workspace it shows, that workspace's shelved windows on top, every other workspace
/// with windows folded below.
struct ShelfScreen: Equatable, Identifiable {
    let monitorName: String
    let displayUUID: String?
    let workspace: String
    let items: [ShelfItem]
    let others: [ShelfWorkspace]
    /// The windows on the stage now, so a still is taken of each one the moment it leaves (ShelfPictures).
    let staged: [Int]

    var id: String { displayUUID ?? monitorName }
    /// Every window with a place on the shelf, minimized ones too.
    var shelved: [Int] { items.flatMap { $0.windows.map(\.id) } }
    /// The minimized ones: ScreenCaptureKit may give no picture of one, so it keeps the still it had.
    var minimized: [Int] { items.filter(\.isMinimized).map(\.id) }
    /// The other workspaces' windows their folded cards show.
    var folded: [Int] { others.flatMap { $0.stack.map(\.id) } }
    /// Every window a card on this shelf pictures.
    var pictured: [Int] { shelved + folded }
}

/// Puts the shelf's panels on screen; nothing in tests.
@MainActor
protocol ShelfPresenting: AnyObject {
    /// One panel at the left edge of each of these screens, none on any other.
    func show(_ screens: [ShelfScreen])
    /// The Fly (Q708): `incoming` from its card, drawn at `card` in `screen`'s panel (`flat` under the pointer, else
    /// turned), to the stage that `staged` fill;
    /// nil when it cannot fly there. `landed` once nothing flies.
    func fly(_ incoming: ShelfStill, from card: CGRect, flat: Bool, on screen: ShelfScreen, landed: @escaping @MainActor () -> Void) -> ShelfFlight?
}

extension ShelfPresenting {
    func fly(_ incoming: ShelfStill, from card: CGRect, flat: Bool, on screen: ShelfScreen, landed: @escaping @MainActor () -> Void) -> ShelfFlight? { nil }
}

/// A Fly under way: the stage's windows join it as their stills come in, flying back to the card's place.
@MainActor
protocol ShelfFlight {
    func leave(_ stills: [Int: ShelfStill])
}

/// The Window shelf (ADR 0015, spec pilot-1-1 T12): on each screen showing a Stage workspace, a panel in the room the
/// tiler keeps free at the left edge, listing that workspace's shelved and minimized windows and the other workspaces
/// folded below (Q594, Q660, Q681, Q690). A click focuses a window, which brings its group to the stage, or switches to a workspace.
/// Its own subscription to the tiler's events from launch to quit (it needs them to see a Stage workspace show), since
/// TilerService skips window events so the top bar and Home do not wake on each one. With no shelf shown it acts only on
/// the tiler's `stagesChanged` (a shown workspace became Stage, or its windows or stage changed: a layout cycled, a
/// shelved window closed, the first layout), so a focus change costs nothing; with one shown, every event refreshes it.
/// A burst refreshes once, one refresh at a time, and only a shown Stage workspace's windows are listed (their titles
/// are AX reads). Tiling off, or Show desktop on a Stage workspace, no shelf shows there.
@Observable @MainActor
final class WindowShelf {
    private(set) var screens: [ShelfScreen] = []
    @ObservationIgnored let pictures: ShelfPictures
    @ObservationIgnored private let tiler: TilerService
    @ObservationIgnored private let tiling: @MainActor () -> Bool
    @ObservationIgnored private var panels: (any ShelfPresenting)!
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// An event came while a refresh ran: one more runs after it, since the tiler will not send it again.
    @ObservationIgnored private var dirty = false
    /// Bumped by `stop`, so a refresh still running from before never clears the next one's place.
    @ObservationIgnored private var generation = 0
    /// The card whose window flies to the stage now (the Fly, Q708): its place is empty until the shelf refreshes.
    private(set) var flying: Int?
    /// Where each card's front window is drawn in its screen's panel, by screen and card: the Fly's start.
    @ObservationIgnored private var faces: [String: [Int: (frame: CGRect, flat: Bool)]] = [:]

    /// A burst of tiler events (a swap is a focus change and a layout) refreshes once, this long after the first.
    static let settle: Duration = .milliseconds(120)
    /// How long a card's click waits for the stage's stills before it swaps without them: they fly back only if in.
    static let leaveWait: Duration = .milliseconds(150)

    /// `top`: the room above the shelf's first place on a screen, by the screen's name (the real panels' only).
    /// `tiling`: whether the tiler tiles now (the dropdown's Tiling switch).
    init(tiler: TilerService, pictures: ShelfPictures = .shared, panels: (any ShelfPresenting)? = nil,
         tiling: @escaping @MainActor () -> Bool = { true }, top: @escaping @MainActor (String) -> CGFloat = { _ in 0 }) {
        self.tiler = tiler
        self.tiling = tiling
        self.pictures = pictures
        self.panels = panels ?? ShelfPanels(shelf: self, top: top)
    }

    /// With the tiler: from Engine's start until Pilot quits.
    func start() {
        guard subscription == nil else { return }
        let events = tiler.runner.events()
        subscription = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                // With no shelf shown, only the tiler's word that a Stage workspace shows matters: focus costs nothing.
                if case .stagesChanged = event { schedule() } else if !screens.isEmpty { schedule() }
            }
        }
        schedule()
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        pending?.cancel()
        pending = nil
        dirty = false
        generation += 1
        show([])
    }

    /// One refresh `settle` after the first event of a burst, one at a time; an event during it runs one more after.
    private func schedule() {
        guard pending == nil else { dirty = true; return }
        let mine = generation
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard let self, !Task.isCancelled, mine == generation else { return }
            dirty = false
            await refresh()
            guard mine == generation else { return }
            pending = nil
            if dirty {
                dirty = false
                schedule()
            }
        }
    }

    /// Reads the shown workspaces and, for each Stage one, its windows and the ones minimized from it; the other
    /// workspaces come from the list TilerService keeps.
    func refresh() async {
        let runner = tiler.runner, mine = generation
        guard tiling(), let visible = try? await runner.visibleWorkspaces() else { return mine == generation ? show([]) : () }
        var next: [ShelfScreen] = [], minimized: [AeroWindow]?
        for shown in visible where shown.isStage && !shown.isShowingDesktop {
            guard let windows = try? await runner.windows(.workspace(shown.workspace)) else { continue }
            if minimized == nil { minimized = (try? await runner.windows(.minimized)) ?? [] }
            let tiled = windows.filter { !$0.isFloating }
            let resting = (minimized ?? []).filter { $0.workspace == shown.workspace }
            next.append(ShelfScreen(monitorName: shown.monitorName, displayUUID: shown.displayUUID, workspace: shown.workspace,
                                    items: Self.items(tiled.filter(\.isShelved)) + resting.map { ShelfItem(windows: [$0]) },
                                    others: Self.others(tiler.windows, besides: shown.workspace),
                                    staged: tiled.filter { !$0.isShelved }.map(\.id)))
        }
        guard mine == generation else { return } // stopped while it read
        show(next)
    }

    private func show(_ next: [ShelfScreen]) {
        guard next != screens else { return }
        screens = next
        for id in faces.keys where !next.contains(where: { $0.id == id }) { faces[id] = nil }
        panels.show(next)
        pictures.follow(next)
    }

    /// Shelved windows as the shelf's places: a joined group's windows together, at its first window's place.
    static func items(_ shelved: [AeroWindow]) -> [ShelfItem] {
        var order: [Int] = [], groups: [Int: [AeroWindow]] = [:]
        for window in shelved {
            let key = window.group ?? window.id
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(window)
        }
        return order.compactMap { groups[$0].map(ShelfItem.init) }
    }

    /// Every other workspace with windows, in the dropdown's order (OccupiedWorkspace.list), floating windows too.
    static func others(_ windows: [AeroWindow], besides shown: String) -> [ShelfWorkspace] {
        OccupiedWorkspace.list(windows).filter { $0.name != shown }.map { workspace in
            ShelfWorkspace(name: workspace.name, windows: windows.filter { $0.workspace == workspace.name })
        }
    }

    /// Where a card's front window is drawn in `screen`'s panel (ShelfColumn's `face`).
    func place(_ id: Int, at frame: CGRect, flat: Bool, on screen: String) { faces[screen, default: [:]][id] = (frame, flat) }

    /// A click on a shelved window or group: it takes the stage; a minimized window is restored onto it (macOS animates
    /// that itself). With its picture the card flies to the stage at once (the Fly, Q708), and the stage's windows are
    /// pictured as they leave (ADR 0012) and fly back to its place: the swap waits for those stills `leaveWait` at most.
    func open(_ item: ShelfItem) {
        let command: AeroCommand = item.isMinimized ? .unminimize(id: item.id) : .focusWindow(id: item.id)
        let swap = { [tiler] in
            _ = Task { await tiler.perform("shelf.\(command.arguments[0]):\(item.id)") { try await $0.run(command) } }
        }
        guard !item.isMinimized, let screen = screens.first(where: { $0.items.contains(item) }),
              let card = faces[screen.id]?[item.id], let incoming = item.windows.last.flatMap({ pictures.still(of: $0.id) }),
              let flight = panels.fly(incoming, from: card.frame, flat: card.flat, on: screen, landed: { [weak self] in self?.flying = nil })
        else { return swap() }
        flying = item.id
        let once = Once()
        let go: @MainActor ([Int: ShelfStill]) -> Void = { stills in
            guard once.first() else { return }
            flight.leave(stills)
            swap()
        }
        pictures.leaving(screen.staged) { go($0) }
        Task { try? await Task.sleep(for: Self.leaveWait); go([:]) }
    }

    /// A click on a folded workspace: the screen switches to it.
    func open(_ workspace: ShelfWorkspace) { tiler.go(workspace.name, from: "shelf") }

    /// `pilot status --part shelf`: each screen's shelf as the last refresh left it (a refresh running is waited for) and
    /// the pictures' state. It reads no windows itself, so it never sets off a still.
    func status() async -> JSONValue {
        await pending?.value
        return .object(["screens": .array(screens.map { screen in
            .object(["monitor": .string(screen.monitorName), "workspace": .string(screen.workspace),
                     "staged": .array(screen.staged.map { .number(Double($0)) }),
                     "shelved": .array(screen.items.map { item in
                         .object(["label": .string(item.label), "windows": .array(item.windows.map { .number(Double($0.id)) }),
                                  "minimized": .bool(item.isMinimized)])
                     }),
                     "others": .array(screen.others.map { .object(["workspace": .string($0.name), "label": .string($0.label)]) })])
        }), "pictures": await pictures.status()])
    }
}

/// True the first time only.
@MainActor
private final class Once {
    private var done = false
    func first() -> Bool {
        defer { done = true }
        return !done
    }
}

extension Array where Element: Hashable {
    /// Each element once, first seen first.
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
