import AppKit
import ApplicationServices
import Observation
import os
import PilotCore

/// Show other apps' notifications Pilot's way (spec notifications.html): off until switched on, and while off nothing here
/// runs: no observer, no timer, no lookup. Notification text is never logged or sent; the drawer is saved on the Mac only
/// (`NotificationStore`, deleted when the setting goes off), and logs and `pilot` reads carry shape and counts only. There is nothing to honour Focus with and nothing to read for it: Pilot acts only on banners macOS itself
/// shows, so Do Not Disturb holds by construction.
@Observable @MainActor
final class NotificationSettings {
    static let shared = NotificationSettings()
    static let enabledKey = "notifications.enabled", hideKey = "notifications.hideMacBanners"
    static let showInKey = "notifications.showIn", layerKey = "notifications.layer"

    /// Where they show (Sven, 2026-11-12): floating, the bell and cards on the desktop as they first shipped, or Pilot's top
    /// bar, a bell item there and each card dropping under it. The top bar while it is off falls back to floating.
    enum ShowIn: String, CaseIterable, Sendable {
        case floating, topBar
        var label: String { self == .floating ? "Floating" : "Top bar" }
    }

    /// Floating's layer: above every window, or below them on the desktop as a widget is. A new card shows above apps either
    /// way; only the bell and the list rest below.
    enum Layer: String, CaseIterable, Sendable {
        case above, below
        var label: String { self == .above ? "Above apps" : "Below apps" }
    }

    var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey); PilotNotifications.shared.settingsChanged() } }
    /// macOS's own banners move off screen while Pilot's cards show. A second switch, off by default: it moves
    /// Notification Center's window, so the first look shows both.
    var hideMacBanners: Bool { didSet { defaults.set(hideMacBanners, forKey: Self.hideKey); PilotNotifications.shared.settingsChanged() } }
    /// The panels follow these through observation (NotificationPanels.follow), so they need no call here. Top bar puts
    /// the bar's bell item on, which joins a layout off as every new item does.
    var showIn: ShowIn {
        didSet {
            defaults.set(showIn.rawValue, forKey: Self.showInKey)
            if showIn == .topBar { BarItemsStore.shared.settings.set(.notifications, on: true) }
        }
    }
    var layer: Layer { didSet { defaults.set(layer.rawValue, forKey: Self.layerKey) } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .pilot()) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        hideMacBanners = defaults.bool(forKey: Self.hideKey)
        showIn = defaults.string(forKey: Self.showInKey).flatMap(ShowIn.init) ?? .floating
        layer = defaults.string(forKey: Self.layerKey).flatMap(Layer.init) ?? .above
    }

    /// Where they show now: the top bar only while Pilot's is on, else floating. The one rule the panels, the bar's bell
    /// item, the page and `pilot status` read.
    var placement: ShowIn { showIn == .topBar && topBarOn() ? .topBar : .floating }
    /// Whether Pilot's top bar is on: the engine's; a render stands one in.
    @ObservationIgnored var topBarOn: @MainActor () -> Bool = { Engine.shared?.topBar.isOn ?? false }
    /// The top bar's bell item draws: they are on and show there.
    var inBar: Bool { enabled && placement == .topBar }
}

/// Draws what the feed says: the panels in the app, a recording in the sandbox.
@MainActor
protocol NotificationPresenting: AnyObject {
    /// The bell comes up as the setting goes on.
    func begin()
    func update(cards: [NotificationEntry], drawer: [NotificationEntry], unread: Int)
    func end()
    /// A short tip about a press Pilot couldn't finish.
    func say(_ text: String)
    func toggleDrawer()
    /// The native banner has gone, so its app opens directly.
    func openApp(named: String)
}

/// The watcher: Notification Center's layout changes to the feed, and the feed to the presenter.
@MainActor
final class PilotNotifications {
    static let shared = PilotNotifications()

    /// The coalescing window: one banner fires about three layout changes.
    static let sweepDelay = Duration.milliseconds(120)
    static let watchInterval: TimeInterval = 10
    /// How long macOS's window stays off screen after the last banner goes, so a burst doesn't bring it back between two.
    static let parkHold = Duration.milliseconds(1500)
    /// Where parked; far enough to be wholly off screen on any display arrangement.
    static let parkY: CGFloat = -9999
    static let parkedKey = "notifications.parkedFrom"
    /// How soon to look again while a Control Center banner is up: only its window's creation is observed, so this is how
    /// its going is seen.
    static let systemLook = Duration.seconds(1)

    private let settings = NotificationSettings.shared
    private let defaults = UserDefaults.pilot()
    private var source: (any NotificationSource)?
    private var presenter: (any NotificationPresenting)?
    private var vocabulary = NotificationVocabulary.english
    private var watchTimer: Timer?
    private var workspaceWatch: [any NSObjectProtocol] = []
    private var terminateWatch: (any NSObjectProtocol)?
    private var sweepTask: Task<Void, Never>?
    /// Which sweep task is current: one stopped and replaced must not clear its successor as it ends.
    private var sweepGeneration = 0
    private var sweepWanted = false
    private var restoreTask: Task<Void, Never>?
    /// A move of macOS's window in flight: a walk mid-move must not read it as stranded, nor start another.
    private var moving = false
    /// Off once Pilot quits: a park move checks it last, so none lands after the quit's put-back.
    private nonisolated let parkAllowed = OSAllocatedUnfairLock(initialState: true)
    private var attachedPID: pid_t = 0
    /// The first walk since switching on or launching: it logs what it found, banners already up included.
    private var firstWalk = true
    private let store = NotificationStore.standard
    /// What was last written, so a walk that changed only what's live writes nothing.
    private var lastSaved: NotificationFeed.Saved?
    private let saving = DispatchQueue(label: "dev.banozz.pilot.notifications.save", qos: .utility)
    /// Control Center banners moved off screen, by id, and where each was.
    private var systemParked: [String: CGPoint] = [:]
    private var systemLookTask: Task<Void, Never>?
    /// The last Control Center window shapes logged, so a repeat isn't logged again.
    private var lastSystemShapes: [NotificationReader.SystemShape] = []
    /// A host window up with no banner read: its last shape logged and how many looks again it has had.
    private var emptyHost: (shape: String, looks: Int)?
    /// Looks again at a host window up with no banner read: a tree still being built at login settles within these.
    static let emptyHostLookLimit = 3

    private(set) var feed = NotificationFeed()
    private(set) var active = false
    private(set) var attached = false
    private(set) var hostFound = false
    private(set) var panelOpen = false
    private(set) var parkedFrom: CGPoint?
    /// Where the host window was at the last walk, so an already hidden one costs no call.
    private var hostPosition: CGPoint?
    private(set) var sweeps = 0
    private(set) var reattached = 0
    private(set) var lastError: String?

    /// The app's launch: Notification Center's real tree. Tests and the sandbox never call this, so nothing but the app can
    /// observe or move the real thing.
    func startLive(presenter: any NotificationPresenting) {
        source = LiveNotificationSource()
        self.presenter = presenter
        recoverIfLeftParked()
        settingsChanged()
    }

    /// The sandbox's fake source and recording presenter.
    func useSandbox(source: any NotificationSource, presenter: any NotificationPresenting) {
        self.source = source
        self.presenter = presenter
        settingsChanged()
    }

    /// The sandbox's relaunch: memory dropped as a quit drops it, then started again from the saved drawer.
    func relaunchForSandbox() {
        guard active else { return }
        saving.sync {}  // the last save lands first, as it would before a quit
        stop(keepSaved: true)
        start()
    }

    func settingsChanged() {
        settings.enabled ? start() : stop()
        syncParking()
    }

    // MARK: - On and off

    private func start() {
        guard !active else { return }
        guard let source else { return lastError = "no source" }
        active = true
        lastError = nil
        firstWalk = true
        // The drawer as the last run left it: rows not live until a walk finds their banners still up.
        let saved = store.load()
        lastSaved = saved
        feed = saved.map(NotificationFeed.init(restoring:)) ?? NotificationFeed()
        Task.detached(priority: .utility) { [weak self] in
            let words = source.vocabulary()
            await MainActor.run { self?.vocabulary = words }
        }
        attach(source)
        presenter?.begin()
        if !feed.drawer.isEmpty { publish(save: false) }
        // NSWorkspace's launch notification isn't dependable for an agent app across sleep, so a slow look at the pid, on
        // only while the setting is, catches a Notification Center that came back under a new one.
        let timer = Timer(timeInterval: Self.watchInterval, repeats: true) { _ in
            MainActor.assumeIsolated { PilotNotifications.shared.checkAttachment() }
        }
        timer.tolerance = Self.watchInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
        let center = NSWorkspace.shared.notificationCenter
        terminateWatch = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PilotNotifications.shared.quitting() }
        }
        workspaceWatch = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didWakeNotification]
            .map { name in center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Every app's launch and quit passes through here; only Notification Center's matters (a wake carries no app).
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard app == nil || app == LiveNotificationSource.bundle else { return }
                MainActor.assumeIsolated { PilotNotifications.shared.checkAttachment() }
            } }
        slog.notice("notifications: on, attached=\(self.attached, privacy: .public) pid=\(self.attachedPID, privacy: .public)")
    }

    /// `keepSaved`: a relaunch, not the setting going off, so the saved drawer stays.
    private func stop(keepSaved: Bool = false) {
        guard active else { return }
        active = false
        watchTimer?.invalidate()
        watchTimer = nil
        workspaceWatch.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceWatch = []
        terminateWatch.map(NotificationCenter.default.removeObserver)
        terminateWatch = nil
        sweepTask?.cancel()
        sweepTask = nil
        sweepWanted = false
        systemLookTask?.cancel()
        systemLookTask = nil
        emptyHost = nil
        restoreSystem(Array(systemParked), wait: false)
        systemParked = [:]
        source?.detach()
        attached = false
        attachedPID = 0
        hostFound = false
        panelOpen = false
        restoreHost(wait: false)
        presenter?.end()
        feed = NotificationFeed()
        if !keepSaved {
            let store = store
            lastSaved = nil
            saving.async { store.delete() }
        }
        slog.notice("notifications: off")
    }

    /// Pilot is quitting: macOS's window goes back before the process does.
    func quitting() {
        parkAllowed.withLock { $0 = false }  // a park still in flight won't move it after this
        cancelPutBackRetry()
        if !systemParked.isEmpty { restoreSystem(Array(systemParked), wait: true) }
        systemParked = [:]
        guard active || parkedFrom != nil || savedPark != nil || moving else { return }
        if moving { usleep(300_000) }  // let a move already under way land, then put it back
        let to = parkedFrom ?? savedPark
        parkedFrom = nil
        putBackNow(to: to)
    }

    private func attach(_ source: any NotificationSource) {
        attachedPID = source.currentPID()
        attached = source.attach { [weak self] in self?.sweepSoon() }
        if attached { sweepSoon() } else { lastError = attachedPID == 0 ? "Notification Center isn't running" : "no Accessibility" }
    }

    /// Re-attaches when Notification Center came back under a new pid, or wasn't there to attach to.
    private func checkAttachment() {
        guard active, let source, !attached || !source.stillRunning(attachedPID) else { return }
        source.detach()
        attached = false
        hostFound = false
        parkedFrom = nil  // the old process's window went with it
        savedPark = nil
        attach(source)
        if attached {
            reattached += 1
            lastError = nil
            slog.notice("notifications: re-attached pid=\(self.attachedPID, privacy: .public) times=\(self.reattached, privacy: .public)")
        }
    }

    // MARK: - Sweeps

    private func sweepSoon() {
        sweepWanted = true
        guard sweepTask == nil else { return }
        sweepGeneration += 1
        let generation = sweepGeneration
        sweepTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sweepDelay)
            guard let self, !Task.isCancelled else { return }
            while self.sweepWanted, self.active, !Task.isCancelled {
                self.sweepWanted = false
                await self.sweep()
                try? await Task.sleep(for: Self.sweepDelay)  // layout changes during the walk coalesce too
            }
            if self.sweepGeneration == generation { self.sweepTask = nil }
        }
    }

    /// One walk: the feed takes what's up, then macOS's window goes where the feed wants it.
    private func sweep() async {
        guard let source else { return }
        let words = vocabulary
        let (reading, shapes) = await Task.detached(priority: .utility) { () -> (NotificationReading, [NotificationReader.SystemShape]) in
            var reading = source.root().map { NotificationReader.read($0, vocabulary: words) } ?? NotificationReading()
            // Control Center's own banners join Notification Center's, read only when its walk answered: an unanswered one
            // changes nothing anyway.
            guard reading.answered, !reading.panelOpen, let system = source.systemRoot() else { return (reading, []) }
            let windows = NotificationReader.systemWindows(system)
            reading.banners += windows.compactMap(\.read)
            return (reading, windows.map(\.shape))
        }.value
        guard active else { return }
        if !shapes.isEmpty, shapes != lastSystemShapes {
            // Shape only, never a word: how Control Center's windows looked, so the next banner it draws shows its make-up.
            for shape in shapes { slog.notice("notifications: control center window \(shape.line, privacy: .public) banner=\(shape.isBanner, privacy: .public)") }
        }
        lastSystemShapes = shapes
        sweeps += 1
        hostPosition = reading.hostPosition
        hostFound = reading.hostFound
        panelOpen = reading.panelOpen
        // Off screen while Pilot isn't parking it: a crash, or a restore macOS refused. Every answered walk puts it back.
        if reading.answered, parkedFrom == nil, !moving, let y = reading.hostPosition?.y, y <= Self.parkY + 1 { recoverStrandedHost() }
        // A banner already up at launch or at switching on is new to the feed, so it becomes a card like any other; one the
        // saved drawer holds goes live again with no second row.
        let first = firstWalk && reading.answered
        if first { firstWalk = false }
        let change = feed.update(reading, at: .now)
        syncParking()
        syncSystemParking()
        if feed.live.contains(where: \.isSystem) { lookAgainSoon() }
        noteEmptyHost(reading.emptyHost)
        let system = reading.banners.filter(\.isSystem).count
        if first {
            slog.notice("notifications: first walk banners=\(reading.banners.count, privacy: .public) system=\(system, privacy: .public) hostFound=\(reading.hostFound, privacy: .public) cards=\(self.feed.cards.count, privacy: .public) drawer=\(self.feed.drawer.count, privacy: .public)")
        }
        guard !change.isEmpty else { return }
        slog.notice("notifications: sweep banners=\(reading.banners.count, privacy: .public) system=\(system, privacy: .public) new=\(change.arrived.count, privacy: .public) gone=\(change.gone.count, privacy: .public) cards=\(self.feed.cards.count, privacy: .public) leftToMacOS=\(self.feed.live.filter(\.leftToMacOS).count, privacy: .public)")
        publish()
        // A walk losing a banner is often a timeout, and nothing else would look again until the next layout change.
        if !change.gone.isEmpty { sweepSoon() }
    }

    private func publish(save: Bool = true) {
        presenter?.update(cards: feed.cards, drawer: feed.drawer, unread: feed.unread)
        guard save, active, feed.saved != lastSaved else { return }
        let saved = feed.saved, store = store
        lastSaved = saved
        saving.async {
            do { try store.save(saved) } catch { slog.error("notifications: drawer not saved: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// The host window up with no banner read in it is a misread (it exists only while one is up): its shape is logged
    /// once, never a word, and a few walks a second apart look again.
    private func noteEmptyHost(_ shape: String?) {
        guard let shape else { return emptyHost = nil }
        if shape != emptyHost?.shape { slog.notice("notifications: host up with no banner read \(shape, privacy: .public)") }
        let looks = emptyHost?.looks ?? 0
        emptyHost = (shape, min(looks + 1, Self.emptyHostLookLimit))
        if looks < Self.emptyHostLookLimit { lookAgainSoon() }
    }

    /// While a Control Center banner is up, or the host reads empty: a walk a second from now, which sees it change.
    private func lookAgainSoon() {
        guard systemLookTask == nil else { return }
        systemLookTask = Task { [weak self] in
            try? await Task.sleep(for: Self.systemLook)
            guard let self, !Task.isCancelled else { return }
            self.systemLookTask = nil
            self.sweepSoon()
        }
    }

    // MARK: - Actions

    /// A card's press, through Notification Center so the app gets it just as it does from macOS's banner. What can't be
    /// finished is handed back to macOS's own banner, which comes back on screen for it.
    func press(_ action: NotificationPress, id: String) {
        guard let source else { return }
        let words = vocabulary
        let system = NotificationReader.isSystem(id: id)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = system
                ? source.systemRoot().map { NotificationReader.pressSystem(action, id: id, in: $0, vocabulary: words) } ?? .gone
                : source.root().map { NotificationReader.press(action, id: id, in: $0, vocabulary: words) } ?? .gone
            await MainActor.run { self?.pressed(action, id: id, result) }
            guard !system, result == .done, case .button = action else { return }
            // A button can open a reply field in Notification Center's banner, which only macOS can finish.
            try? await Task.sleep(for: .milliseconds(350))
            let field = source.root().map { NotificationReader.hasField(id: id, in: $0) } ?? false
            guard field else { return }
            await MainActor.run { self?.leaveToMacOS(id, "This one needs macOS's banner to finish") }
        }
    }

    private func pressed(_ action: NotificationPress, id: String, _ result: NotificationPressResult) {
        slog.notice("notifications: press kind=\(action.kind, privacy: .public) result=\(result.rawValue, privacy: .public)")
        if result == .refused {
            leaveToMacOS(id, "macOS didn't take that: use its banner")
        }
        if result == .gone, action == .open, !NotificationReader.isSystem(id: id) { openApp(id) }
        if result == .gone { sweepSoon() }  // the card is out of date: the banner has left
    }

    private func leaveToMacOS(_ id: String, _ tip: String) {
        feed.leaveToMacOS(id)
        publish()
        syncParking()
        syncSystemParking()
        presenter?.say(tip)
    }

    /// The native banner has gone, so opening falls back to the app itself, as a drawer row does.
    private func openApp(_ id: String) {
        guard let name = feed.drawer.first(where: { $0.id == id })?.app else { return }
        presenter?.openApp(named: name)
    }

    // MARK: - The drawer

    /// The bell's click and its action: the drawer, what arrived, kept across a relaunch.
    func toggleDrawer() {
        guard active else { return presenter?.say("Notifications in Pilot are off: Menu bar › Notifications") ?? () }
        markRead()
        presenter?.toggleDrawer()
    }

    /// A drawer row's ×: gone from the list, and macOS's own banner too while it's still up.
    func removeFromDrawer(_ id: String) {
        let live = feed.drawer.first { $0.id == id }?.live == true
        feed.remove(id)
        publish()
        if live { press(.close, id: id) }
    }

    /// The top bar's list opened: what arrived counts as read, as the bell's drawer does.
    func markRead() {
        guard active, feed.unread > 0 else { return }
        feed.markRead()
        publish()
    }

    func clearDrawer() {
        feed.clearDrawer()
        publish()
    }

    // MARK: - Hiding macOS's own banner

    /// Every banner shares one host window, so it goes off screen only while every banner in it has a card (the feed says),
    /// and never over Notification Center's own panel, which lives in it.
    private func syncParking() {
        let parking = feed.parking(allowed: active && settings.hideMacBanners && !panelOpen)
        if parking == .park {
            cancelRestore()
            parkHost()
        } else if parkedFrom != nil, parking == .restore {
            cancelRestore()
            restoreHost(wait: false)
        } else if parkedFrom != nil, restoreTask == nil {
            restoreTask = Task { [weak self] in
                try? await Task.sleep(for: Self.parkHold)
                guard let self, !Task.isCancelled else { return }
                self.restoreTask = nil
                self.restoreHost(wait: false)
            }
        }
    }

    private func cancelRestore() {
        restoreTask?.cancel()
        restoreTask = nil
    }

    /// Where the window was when Pilot parked it, kept so a crash can put it back.
    private var savedPark: CGPoint? {
        get { (defaults.array(forKey: Self.parkedKey) as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
        set {
            if let newValue { defaults.set([newValue.x, newValue.y], forKey: Self.parkedKey) }
            else { defaults.removeObject(forKey: Self.parkedKey) }
        }
    }

    private enum ParkMove: Sendable { case moved(CGPoint), refused, skipped }

    private func parkHost() {
        guard let source, !moving, (hostPosition?.y ?? 0) > Self.parkY + 1 else { return }
        let known = parkedFrom, y = Self.parkY, allowed = parkAllowed
        moving = true
        Task.detached(priority: .utility) { [weak self] in
            var result = ParkMove.skipped  // no window, or already off screen: nothing refused
            if allowed.withLock({ $0 }), let host = source.root().flatMap(NotificationReader.host), let now = host.position, now.y > y + 1 {
                let start = known ?? now
                result = host.setPosition(CGPoint(x: start.x, y: y)) ? .moved(start) : .refused
            }
            await MainActor.run { self?.parked(result) }
        }
    }

    private func parked(_ result: ParkMove) {
        moving = false
        switch result {
        case .skipped: return
        case .refused: lastError = "macOS refused moving its banner window"
        case .moved(let from):
            if parkedFrom == nil { slog.notice("notifications: macOS banners hidden") }
            cancelPutBackRetry()
            lastError = nil
            parkedFrom = from
            hostPosition = CGPoint(x: from.x, y: Self.parkY)
            savedPark = from
            syncParking()  // the setting or the banners may have changed while the move ran
        }
    }

    /// Pilot stops hiding: the window goes back where it was. `wait` for a quit, which must not outrun the move.
    private func restoreHost(wait: Bool) {
        guard let from = parkedFrom else { return }
        parkedFrom = nil
        slog.notice("notifications: macOS banners back")
        if wait { putBackNow(to: from) } else { putBack(to: from) }
    }

    /// How often a refused put-back tries again on its own, and how long it waits between: a walk only runs while the
    /// setting is on, so with it off nothing else would (review round 2, B1).
    static let putBackTries = 5
    static let putBackPause = Duration.seconds(2)
    private var putBackRetry: Task<Void, Never>?

    /// Moves macOS's window back on screen, to `to` or, not known, its own x at the top, with the setting on or off. The
    /// saved place goes only once it lands; then hiding is synced again, so a carded banner can park it at once.
    private func putBack(to: CGPoint?, attempt: Int = 1) {
        guard let source, !moving else { return }
        cancelPutBackRetry()
        let y = Self.parkY
        moving = true
        Task.detached(priority: .utility) { [weak self] in
            let landed = Self.moveBack(source, to: to, parkY: y)
            await MainActor.run { self?.putBackDone(landed, to: to, attempt: attempt) }
        }
    }

    /// Where the window ended up on screen, nil while it is still off screen or can't be found.
    private nonisolated static func moveBack(_ source: any NotificationSource, to: CGPoint?, parkY y: CGFloat) -> CGPoint? {
        guard let host = source.root().flatMap(NotificationReader.host), let now = host.position else { return nil }
        if now.y > y + 1 { return now }  // already back
        let target = to ?? CGPoint(x: now.x, y: 0)
        return host.setPosition(target) ? target : nil
    }

    private func putBackDone(_ landed: CGPoint?, to: CGPoint?, attempt: Int) {
        moving = false
        if let landed {
            savedPark = nil
            lastError = nil
            hostPosition = landed
            slog.notice("notifications: macOS banners on screen")
        } else {
            lastError = "macOS refused moving its banner window back"
            hostPosition = CGPoint(x: to?.x ?? hostPosition?.x ?? 0, y: Self.parkY)
            if attempt < Self.putBackTries {
                putBackRetry = Task { [weak self] in
                    try? await Task.sleep(for: Self.putBackPause)
                    guard let self, !Task.isCancelled else { return }
                    self.putBackRetry = nil
                    self.putBack(to: self.savedPark ?? to, attempt: attempt + 1)
                }
            }
        }
        syncParking()
    }

    private func cancelPutBackRetry() {
        putBackRetry?.cancel()
        putBackRetry = nil
    }

    /// For a quit: blocks up to 1.5 s for the move, so macOS's banners are back before the process goes.
    private func putBackNow(to: CGPoint?) {
        guard let source else { return }
        let y = Self.parkY
        let done = DispatchSemaphore(value: 0)
        let landed = OSAllocatedUnfairLock<CGPoint?>(initialState: nil)
        DispatchQueue.global(qos: .userInitiated).async { let at = Self.moveBack(source, to: to, parkY: y); landed.withLock { $0 = at }; done.signal() }
        if done.wait(timeout: .now() + 1.5) == .success, landed.withLock({ $0 }) != nil { savedPark = nil }
    }

    /// Pilot went away with the window parked and the setting was then turned off: put it back once. Reads one default.
    private func recoverIfLeftParked() {
        guard !settings.enabled, let saved = savedPark else { return }
        putBack(to: saved)
    }

    /// Attached and macOS's window is already off screen while Pilot isn't parking it: a crash, or a put-back refused.
    private func recoverStrandedHost() {
        putBack(to: savedPark)
    }

    /// Control Center's banners with a card go off screen while the switch is on, each its own window; one that loses its
    /// card (left to macOS, the switch off) goes back where it was. A banner that left took its window with it.
    private func syncSystemParking() {
        let want: Set<String> = active && settings.hideMacBanners ? Set(feed.systemCards.map(\.id)) : []
        let park = want.subtracting(systemParked.keys)
        let up = Set(feed.live.map(\.id))
        let back = systemParked.filter { !want.contains($0.key) && up.contains($0.key) }
        systemParked = systemParked.filter { want.contains($0.key) }
        if !back.isEmpty { restoreSystem(Array(back), wait: false) }
        guard !park.isEmpty, let source else { return }
        let y = Self.parkY, allowed = parkAllowed
        Task.detached(priority: .utility) { [weak self] in
            var moved: [(String, CGPoint)] = [], refused = 0
            if let app = source.systemRoot() {
                for id in park where allowed.withLock({ $0 }) {
                    guard let window = NotificationReader.systemWindow(id: id, in: app), let at = window.position, at.y > y + 1 else { continue }
                    if window.setPosition(CGPoint(x: at.x, y: y)) { moved.append((id, at)) } else { refused += 1 }
                }
            }
            await MainActor.run { self?.systemMoved(moved, refused: refused) }
        }
    }

    private func systemMoved(_ moved: [(String, CGPoint)], refused: Int) {
        for (id, at) in moved { systemParked[id] = at }
        if !moved.isEmpty { slog.notice("notifications: control center banners hidden=\(moved.count, privacy: .public)") }
        if refused > 0 { lastError = "macOS refused moving its Control Center banner" }
        // The card or the switch may have changed while the move ran.
        syncSystemParking()
    }

    /// Puts Control Center banners back where they were; `wait` for a quit, which must not outrun the moves.
    private func restoreSystem(_ windows: [(key: String, value: CGPoint)], wait: Bool) {
        guard let source, !windows.isEmpty else { return }
        slog.notice("notifications: control center banners back=\(windows.count, privacy: .public)")
        let move: @Sendable () -> Void = {
            guard let app = source.systemRoot() else { return }
            let found = NotificationReader.systemWindows(app)
            for (id, at) in windows { _ = found.first { $0.read?.id == id }?.window.setPosition(at) }
        }
        guard wait else { return DispatchQueue.global(qos: .utility).async(execute: move) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { move(); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: - Reads

    /// `pilot status --part notifications`: shape and counts, never a word of a notification.
    func status() -> JSONValue {
        let timers = watchTimer == nil ? 0 : 1
        return .object([
            "on": .bool(settings.enabled), "hideMacBanners": .bool(settings.hideMacBanners),
            "showIn": .string(settings.showIn.rawValue), "layer": .string(settings.layer.rawValue), "placement": .string(settings.placement.rawValue),
            "observing": .bool(attached), "pid": .number(Double(attachedPID)), "reattached": .number(Double(reattached)),
            "accessibility": .bool(AXIsProcessTrusted()), "timers": .number(Double(timers)), "workspaceObservers": .number(Double(workspaceWatch.count)),
            "hostFound": .bool(hostFound), "panelOpen": .bool(panelOpen), "hostParked": .bool(parkedFrom != nil), "sweeps": .number(Double(sweeps)),
            "live": .number(Double(feed.live.count)), "cards": .number(Double(feed.cards.count)),
            "systemCards": .number(Double(feed.systemCards.count)), "systemParked": .number(Double(systemParked.count)),
            "leftToMacOS": .number(Double(feed.live.filter(\.leftToMacOS).count)), "drawer": .number(Double(feed.drawer.count)), "unread": .number(Double(feed.unread)),
            "lastError": lastError.map(JSONValue.string) ?? .null,
        ])
    }
}
