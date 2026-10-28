// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/MacApp.swift
import AppKit
import Synchronization

// Potential alternative implementation
// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md
// (only available since macOS 14)
class MacApp: AbstractApp { // Pilot: not final, for OwnApp (Pilot's own windows)
    /*conforms*/ let pid: Int32
    /*conforms*/ let rawAppBundleId: String?
    let appId: KnownBundleId?
    let nsApp: NSRunningApplication
    private let axApp: ThreadGuardedValue<AXUIElement>
    private let appAxSubscriptions: ThreadGuardedValue<[AxSubscription]> // keep subscriptions in memory
    private let windows: ThreadGuardedValue<[UInt32: AxWindow]> = .init([:])
    private let glider: ThreadGuardedValue<Glider> = .init(Glider()) // Pilot (card agent-bo-95423033)
    private var windowsCount = 0
    var lastNativeFocusedWindowId: UInt32? = nil
    private var thread: Thread?
    private var setFrameJobs: [UInt32: RunLoopJob] = [:]
    /// Pilot (AC6): when this app last missed its deadline; for axUnansweredPause after that, cancellable calls on it
    /// give up at once, so one session waits on a hung app once.
    private var unansweredSince: ContinuousClock.Instant? = nil
    /// Pilot (spec scrolling-layout T7): the hand-off under way, and which focus change it is (newFocus).
    @MainActor private(set) static var focusTask: Task<Void, Never>? = nil
    @MainActor private static var focusGeneration = 0

    /// Pilot (spec scrolling-layout T7): a focus change, from any path (MacWindow.nativeFocus, Pilot's own windows too),
    /// stops the hand-off under way, so an older press never brings its app back over a newer one.
    @MainActor static func newFocus() {
        focusTask?.cancel()
        focusGeneration &+= 1
    }

    /*conforms*/ var name: String? { nsApp.localizedName }

    // todo think if it's possible to integrate this global mutable state to https://github.com/nikitabobko/AeroSpace/issues/1215
    //      and make deinitialization automatic in deinit
    @MainActor static var allAppsMap: [pid_t: MacApp] = [:]
    @MainActor private static var wipPids: [pid_t: (latch: AwaitableOneTimeBroadcastLatch, since: ContinuousClock.Instant)] = [:]
    /// Pilot (card agent-bo-95423031): apps whose registration ran past axWaitDeadline, left out until axUnansweredPause ends.
    @MainActor private(set) static var slowSince: [pid_t: ContinuousClock.Instant] = [:]

    init(
        _ nsApp: NSRunningApplication,
        _ axApp: AXUIElement,
        _ axSubscriptions: [AxSubscription],
        _ thread: Thread?, // Pilot: nil for OwnApp, which runs no AX thread
    ) {
        self.nsApp = nsApp
        self.axApp = .init(axApp)
        self.pid = nsApp.processIdentifier
        self.rawAppBundleId = nsApp.bundleIdentifier
        self.appId = nsApp.bundleIdentifier.flatMap(KnownBundleId.init(bundleId:))
        checkSoft(!axSubscriptions.isEmpty || isUnitTest || thread == nil)
        self.appAxSubscriptions = .init(axSubscriptions)
        self.thread = thread
    }

    /// Pilot: OwnApp runs no AX thread, so its unused AX values are dropped at once, under the token they were made with.
    func destroyAxValues() {
        glider.destroy()
        appAxSubscriptions.destroy()
        windows.destroy()
        axApp.destroy()
    }

    /// Pilot: the tests' never-answering app (AC6): built on its own AX thread as getOrRegister does, with no AX
    /// subscriptions and never registered, its thread busy for `hang` seconds before it takes any job. `destroy()` ends it.
    static func unitTestApp(_ nsApp: NSRunningApplication, hangingFor hang: TimeInterval) async -> MacApp {
        await withCheckedContinuation { created in
            Thread {
                $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: nsApp.processIdentifier, idForDebug: nsApp.idForDebug)) {
                    let app = MacApp(nsApp, AXUIElementCreateApplication(nsApp.processIdentifier).withMessagingTimeout(), [], Thread.current)
                    created.resume(returning: app)
                    Thread.sleep(forTimeInterval: hang)
                    RunLoop.current.add(Port(), forMode: .default)
                    CFRunLoopRun()
                    app.glider.destroy()
                    app.appAxSubscriptions.destroy()
                    app.windows.destroy()
                    app.axApp.destroy()
                }
            }.start()
        }
    }

    @MainActor
    @discardableResult
    static func getOrRegister(_ nsApp: NSRunningApplication) async throws -> MacApp? {
        // Don't perceive any of the lock screen windows as real windows
        // Otherwise, false positive ax notifications might trigger that lead to gcWindows
        if nsApp.bundleIdentifier == lockScreenAppBundleId { return nil }
        let pid = nsApp.processIdentifier
        if let existing = allAppsMap[pid] { return existing }
        // AX requests crash if you send them to yourself. Pilot: so its own windows move through AppKit (OwnApp)
        if pid == myPid { return OwnApp.register(nsApp) }
        try checkCancellation()
        return try await registering(pid, nsApp.localizedName ?? "pid \(pid)") { wip in
            let thread = Thread {
                $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: nsApp.idForDebug)) {
                    let axApp = AXUIElementCreateApplication(nsApp.processIdentifier).withMessagingTimeout() // Pilot (AC6)
                    let handlers: HandlerToNotifKeyMapping = unsafe [
                        (refreshObs, [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]),
                    ]
                    let job = RunLoopJob(.cancellable)
                    let subscriptions = (try? unsafe AxSubscription.bulkSubscribe(nsApp, axApp, job, handlers)) ?? []
                    let isGood = !subscriptions.isEmpty
                    let app = isGood ? MacApp(nsApp, axApp, subscriptions, Thread.current) : nil

                    let appAxSubscriptionsThreadGuarded = app?.appAxSubscriptions
                    let windowsThreadGuarded = app?.windows
                    let gliderThreadGuarded = app?.glider
                    let axAppThreadGuarded = app?.axApp

                    Task.startUnstructured { @MainActor in await finishRegistration(pid, app, wip) }
                    if isGood {
                        CFRunLoopRun()

                        // Destroy AX objects in reverse order of their creation
                        gliderThreadGuarded?.destroy()
                        appAxSubscriptionsThreadGuarded?.destroy()
                        windowsThreadGuarded?.destroy()
                        axAppThreadGuarded?.destroy()
                    }
                }
            }
            thread.name = "AxAppThread \(nsApp.idForDebug)"
            thread.start()
        }
    }

    /// Pilot (card agent-bo-95423310): app `pid` once its registration ends, the running one's or one `start` begins, or
    /// nil when it runs past `deadline`. A hung app's registration waits out the messaging timeout on each AX notification
    /// it subscribes to (lane 1: a window bind on a stopped TextEdit took 3.4 s), so the session goes on without it and
    /// the next ones skip it for axUnansweredPause, as `answering` does for a registered app; the registration goes on.
    @MainActor
    static func registering(_ pid: pid_t, _ name: String, deadline: Duration = axWaitDeadline,
                            start: (AwaitableOneTimeBroadcastLatch) -> Void) async throws -> MacApp? {
        if isPaused(slowSince[pid]) { return nil }
        let wip = wipPids[pid] ?? {
            let new = (latch: AwaitableOneTimeBroadcastLatch(), since: ContinuousClock.now)
            wipPids[pid] = new
            start(new.latch)
            return new
        }()
        guard try await registered(wip.latch, since: wip.since, deadline: deadline) else {
            stalled(name, since: &slowSince[pid])
            return nil
        }
        return allAppsMap[pid]
    }

    /// A registration of `pid` ended with `app` (nil: it took no AX subscriptions). One that ran past its deadline left its
    /// app out of the sessions meanwhile, so landing it refreshes once to lay out its windows (Pilot, card agent-bo-95423310).
    /// The landed app keeps that stall as its own (OW P6): a hung app's registration lands too, and a bind on it then waited
    /// axWaitDeadline again; so the refresh comes once the skip ends, when the app is asked again.
    @MainActor
    static func finishRegistration(_ pid: pid_t, _ app: MacApp?, _ wip: AwaitableOneTimeBroadcastLatch,
                                   refresh: @escaping @MainActor () -> Void = { scheduleCancellableCompleteRefreshSession(.ax("late registration")) }) async {
        allAppsMap[pid] = app
        wipPids[pid] = nil
        if let app, let since = slowSince.removeValue(forKey: pid) {
            app.unansweredSince = since
            let left = axUnansweredPause - (ContinuousClock.now - since)
            Task { @MainActor [weak app] in
                try? await Task.sleep(for: left)
                if let app, allAppsMap[pid] === app { refresh() } // not for an app gone or registered again meanwhile
            }
        }
        await wip.signalToAll()
    }

    /// Whether registration `wip`, begun at `since`, ends within `deadline` of its start; false at once past it.
    @MainActor
    static func registered(_ wip: AwaitableOneTimeBroadcastLatch, since: ContinuousClock.Instant, deadline: Duration = axWaitDeadline) async throws -> Bool {
        let left = deadline - (ContinuousClock.now - since)
        guard left > .zero else { return false }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await wip.await(); return true }
            group.addTask { try await Task.sleep(for: left); return false }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
    }

    func closeAndUnregisterAxWindow(_ windowId: UInt32) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        _ = withWindowAsync(windowId, .cancellable) { [windows] window, job in
            guard let closeButton = window.get(Ax.closeButtonAttr) else { return }
            if AXUIElementPerformAction(try closeButton.cast, kAXPressAction as CFString) == .success {
                try windows.modify { _ = $0.removeValue(forKey: windowId) }
            }
        }
    }

    /// Pilot (AC6): a job on this app's AX thread, which gives up at once while the app is known not to answer.
    private func answering<T: Sendable>(_ cm: CancellationMode, _ body: @Sendable @escaping (RunLoopJob) throws -> T?) async throws -> T? {
        guard let thread else { return nil }
        if cm == .cancellable, Self.isPaused(unansweredSince) { throw AxTimeout() }
        do {
            let result = try await thread.runInLoop(cm, body)
            unansweredSince = nil
            return result
        } catch is AxTimeout {
            Self.stalled(name ?? "pid \(pid)", since: &unansweredSince)
            throw AxTimeout()
        }
    }

    /// Pilot: whether an app that stalled at `since` is still skipped (axUnansweredPause).
    private static func isPaused(_ since: ContinuousClock.Instant?) -> Bool {
        since.map { ContinuousClock.now - $0 < axUnansweredPause } ?? false
    }

    /// Pilot (card agent-bo-95423039): an app stalled now; one line per stall, not one per session that meets it.
    private static func stalled(_ name: String, since: inout ContinuousClock.Instant?) {
        if since == nil { axStallLog("\(name) did not answer Accessibility in time: the tiler skips it for \(axUnansweredPause)") }
        since = .now
    }

    func getAxSize(_ windowId: UInt32, _ cm: CancellationMode) async throws -> CGSize? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.sizeAttr)
        }
    }

    // todo merge together with detectNewWindows
    func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
        let windowId = try await answering(cm) { [nsApp, axApp, windows] job in
            try axApp.threadGuarded.get(Ax.focusedWindowAttr)
                .flatMap { focused in try windows.modify { try $0.getOrRegisterAxWindow(windowId: focused.windowId, focused.ax.cast, nsApp, job) } }?
                .windowId
        }
        guard let windowId else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: self)
    }

    @MainActor func nativeFocus(_ windowId: UInt32) {
        // Pilot (spec scrolling-layout T7): each hand-off is one press's; a newer one cancels its raise and stops it bringing
        // the app forward (AppActivation), which starts from the app in front at the press and logs each way it tries.
        let generation = MacApp.focusGeneration, front = NSWorkspace.shared.frontmostApplication, app = name ?? "?"
        // Performance optimization. If possible avoid doing AX requests
        // (important for apps which are slow at responding even such basic AX requests. E.g. Godot)
        // Beware of the macOS bug: https://github.com/nikitabobko/AeroSpace/issues/101
        let raises = !((!NSScreen.screensHaveSeparateSpaces || monitorInfos.count == 1) &&
            (lastNativeFocusedWindowId == windowId || windowsCount == 1))
        let glidingAtCall = isGliding(windowId)
        MacApp.focusTask = Task.startUnstructured { @MainActor [nsApp, axApp] in
            guard let (raised, ways) = await self.raise(windowId, raises: raises, glidingAtCall: glidingAtCall) else { return }
            let outcome = await AppActivation.bringForward(
                ways,
                // Stale once a newer focus change came, or another app came forward on its own (Cmd-Tab, a click)
                isCurrent: {
                    let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    return MacApp.focusGeneration == generation && (now == front?.processIdentifier || now == nsApp.processIdentifier)
                },
                isFront: { NSWorkspace.shared.frontmostApplication?.processIdentifier == nsApp.processIdentifier },
                pause: { try? await Task.sleep(for: .milliseconds(25)) },
            ) { way in
                guard !isUnitTest else { return false } // tests bring nothing forward: a real way would act on the screen
                switch way {
                    case .skyLight: return SkyLight.bringForward(pid: nsApp.processIdentifier, windowId: windowId)
                    case .fromFront: return front.map { nsApp.activate(from: $0, options: []) } ?? false
                    case .axFrontmost:
                        let set = try? await self.answering(.cancellable) { [axApp] _ in
                            AXUIElementSetAttributeValue(try axApp.threadGuarded, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
                        }
                        return set == true
                    case .plain: return nsApp.activate(options: [])
                }
            }
            // A refused hand-off gives the tiler's focus back to macOS's (live bug 2026-10-20, OwnWindowTests)
            if outcome.refused { forgetNativeFocus() }
            Self.logHandOff("window \(windowId) of \(app) \(raised): \(outcome.line)")
        }
    }

    /// Pilot (spec scrolling-layout T7): raises the window before its app comes forward, and gives the line to log and the
    /// ways left to try; nil when the hand-off ends here, logged. Pilot's own windows raise through AppKit (OwnApp).
    @MainActor func raise(_ windowId: UInt32, raises: Bool, glidingAtCall: Bool) async -> (line: String, ways: [AppActivation])? {
        guard raises else { return ("activate only", AppActivation.order) }
        let app = name ?? "?"
        do {
            guard let line = try await withWindow(windowId, .cancellable, { window, job in
                let frame = (try? PilotTiler.getAxRect(window: window, job: job)).flatMap { $0 }
                    .map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "unread"
                // Raise firstly to make sure that by the time we activate the app, the window would be already on top
                let main = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return "at \(frame), gliding \(glidingAtCall) at the call, \(isGliding(windowId)) at the raise, main \(main.rawValue), raise \(raise.rawValue)"
            }) else {
                Self.logHandOff("window \(windowId) of \(app): no AX element")
                return nil
            }
            return (line, AppActivation.order)
        } catch is CancellationError {
            Self.logHandOff("window \(windowId) of \(app): superseded by a newer press")
            return nil
        } catch {
            // A slow app is not raised; SkyLight and activation need no AX, the AX frontmost ask would wait on it too
            return ("not raised (\(error))", AppActivation.order.filter { $0 != .axFrontmost })
        }
    }

    /// Pilot (scrolling focus, 2026-10-12): one hand-off step, then the front app right after and 300 ms on.
    private nonisolated static func logHandOff(_ line: String) {
        tilerLog.notice("focus hand-off: \(line, privacy: .public)")
        Task.startUnstructured { @MainActor in
            let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            try? await Task.sleep(for: .milliseconds(300))
            let later = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            tilerLog.notice("focus hand-off: front app \(now, privacy: .public) right after, \(later, privacy: .public) at 300 ms")
        }
    }

    /// Pilot: with `glidingFrom`, the window glides there from that frame (or from where its running glide has it) on
    /// this app's AX thread for `duration` (card agent-bo-95423033; a scrolling strip glides longer); without, it jumps,
    /// ending any glide. `span`: the x the window keeps within on its way (FrameSteps), a scrolling column's; `screen`:
    /// whose refresh paces the glide. `fromCorner` and `then`, a space-switch slide's (GlideSet.retarget): out of a hide
    /// corner, and into one once it lands.
    func setAxFrame(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?, glidingFrom: Rect? = nil,
                    duration: Duration = GlideSet.duration, span: ClosedRange<CGFloat>? = nil, screen: GlideScreen? = nil,
                    fromCorner: Bool = false, then: CGPoint? = nil) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { [axApp, glider, windows] window, job in
            let glider = try glider.threadGuarded
            guard let topLeft, let size,
                  glider.retarget(windowId, from: glidingFrom, to: Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height),
                                  now: .now, duration: duration, span: span, fromCorner: fromCorner, then: then)
            else {
                glider.stop(windowId)
                try disableAnimations(app: axApp.threadGuarded, job) {
                    glider.minWidths[windowId] = try setFrame(window, topLeft, size, span: span, minWidth: glider.minWidths[windowId] ?? 0, job)
                }
                return TilerFrames.announce([windowId])
            }
            try glider.run(axApp.threadGuarded, windows, on: screen)
        }
    }

    /// Pilot: a write that takes the window's frame over from the pending one, and from its glide.
    private func replaceFrameJob(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement) -> Void) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        setFrameJobs[windowId] = withWindowAsync(windowId, .cancellable) { [glider] window, _ in
            try glider.threadGuarded.stop(windowId)
            body(window)
        }
    }

    func setAxFrameForTermination(_ windowId: UInt32, _ topLeft: CGPoint?, _ size: CGSize?) {
        setFrameJobs.removeValue(forKey: windowId)?.cancel()
        let done = CompletableFuture<Void>()
        let job = withWindowForTermination(windowId) { [axApp, glider] window, job in
            (try? glider.threadGuarded)?.stop(windowId)
            if let window {
                _ = try? disableAnimations(app: axApp.threadGuarded, job) {
                    try setFrame(window, topLeft, size, job)
                }
            }
            done.complete(())
        }
        if !job.isCancelled { _ = done.blockingGet(timeout: Self.terminationWait) }
    }

    func getAxRect(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Rect? {
        try await withWindow(windowId, cm) { window, job in
            try PilotTiler.getAxRect(window: window, job: job)
        }
    }

    func getAxRectForTermination(_ windowId: UInt32) -> Rect? {
        let future = CompletableFuture<Rect?>()
        let job = withWindowForTermination(windowId) { window, job in
            future.complete(window.flatMap { try? PilotTiler.getAxRect(window: $0, job: job) })
        }
        return switch job.isCancelled {
            case true: nil
            case false: future.blockingGet(timeout: Self.terminationWait) ?? nil
        }
    }

    /// How long unparking waits on one window before it moves on (Moody fbYAVj96Ats).
    static let terminationWait: Duration = .seconds(1)

    func isWindowHeuristic(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.isWindowHeuristic(axApp: try axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } == true
    }

    func getAxUiElementWindowType(_ windowId: UInt32, _ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> AxUiElementWindowType {
        return try await withWindow(windowId, cm) { [nsApp, axApp, appId] window, job in
            window.getWindowType(axApp: try axApp.threadGuarded, appId, nsApp.activationPolicy, windowLevel)
        } ?? .window
    }

    func setNativeFullscreen(_ windowId: UInt32, _ value: Bool) {
        replaceFrameJob(windowId) { window in window.set(Ax.isFullscreenAttr, value) }
    }

    func setNativeMinimized(_ windowId: UInt32, _ value: Bool) {
        replaceFrameJob(windowId) { window in window.set(Ax.minimizedAttr, value) }
    }

    func getAxTitle(_ windowId: UInt32, _ cm: CancellationMode) async throws -> String? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.titleAttr)
        }
    }

    func isMacosNativeFullscreen(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.isFullscreenAttr)
        }
    }

    func isMacosNativeMinimized(_ windowId: UInt32, _ cm: CancellationMode) async throws -> Bool? {
        try await withWindow(windowId, cm) { window, job in
            window.get(Ax.minimizedAttr)
        }
    }

    /// Pilot: activationPolicy is a synchronous LaunchServices call, and a refresh asks it of every running process on the
    /// main thread, about 150 calls per app switch that held the key tap (sampled 2026-10-09). Each app's answer is kept
    /// for policyTTL, keyed by the NSRunningApplication itself (its processIdentifier makes the same call) and holding it,
    /// so a dead app's address is never reused by a live one while its answer is kept.
    @MainActor private(set) static var policies: [ObjectIdentifier: (app: AnyObject, policy: NSApplication.ActivationPolicy, at: ContinuousClock.Instant)] = [:]
    static let policyTTL = Duration.seconds(5)

    /// Pilot: `app`'s activation policy, from `ask` only when unknown or older than policyTTL.
    @MainActor
    static func activationPolicy(of app: AnyObject, now: ContinuousClock.Instant = .now,
                                 ask: () -> NSApplication.ActivationPolicy) -> NSApplication.ActivationPolicy {
        if let kept = policies[ObjectIdentifier(app)], now - kept.at < policyTTL { return kept.policy }
        let policy = ask()
        policies[ObjectIdentifier(app)] = (app, policy, now)
        return policy
    }

    /// Pilot: forgets the apps no longer running, and `front`'s answer, so an app that just turned regular is seen at once.
    @MainActor
    static func prunePolicies(keeping live: Set<ObjectIdentifier>, refreshing front: ObjectIdentifier? = nil) {
        policies = policies.filter { live.contains($0.key) && $0.key != front }
    }

    /// The apps a refresh asks for their windows: every regular running app, then each registered app not among them.
    /// "About this Mac" window, TouchID, and a lot of other utility windows: we don't monitor them actively as we do for
    /// regular apps, but if a window of one of those utility apps got focused it will end up in allAppsMap.
    /// Pilot: matched by pid, not by asking the registered app's policy again. One app is several objects (the running
    /// list's, frontmostApplication's, NSRunningApplication.current), each with its own kept policy; after Pilot turned
    /// regular as its window opened, the list's still read accessory and `.current` regular, so neither loop refreshed
    /// Pilot and its window stayed out of the layout for up to policyTTL (Sven 2026-10-12).
    static func appsToRefresh<App>(running: [App], registered: [App], pid: (App) -> pid_t, isRegular: (App) -> Bool) -> [App] {
        let regular = running.filter(isRegular)
        let refreshed = Set(regular.map(pid))
        return regular + registered.filter { !refreshed.contains(pid($0)) }
    }

    @MainActor
    static func refreshAllAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [MacApp: [UInt32]] {
        for (_, app) in MacApp.allAppsMap { // gc dead apps
            try checkCancellation()
            if app.nsApp.isTerminated {
                await app.destroy()
            }
        }
        return try await withThrowingTaskGroup(of: (pid_t, [UInt32]).self, returning: [MacApp: [UInt32]].self) { group in
            func refreshTheApp(_ nsApp: NSRunningApplication) {
                group.addTask { @Sendable @MainActor in
                    guard let app = try await MacApp.getOrRegister(nsApp) else { return (nsApp.processIdentifier, []) }
                    return (nsApp.processIdentifier, try await app.refreshAndGetAliveWindowIds(frontmostAppBundleId: frontmostAppBundleId))
                }
            }
            // Pilot: policies come from the cache, the frontmost app's afresh
            @MainActor func policy(_ nsApp: NSRunningApplication) -> NSApplication.ActivationPolicy {
                activationPolicy(of: nsApp) { nsApp.activationPolicy }
            }
            // Register new apps
            let running = NSWorkspace.shared.runningApplications
            prunePolicies(keeping: Set(running.map(ObjectIdentifier.init)),
                          refreshing: NSWorkspace.shared.frontmostApplication.map(ObjectIdentifier.init))
            for nsApp in appsToRefresh(running: running, registered: MacApp.allAppsMap.values.map(\.nsApp),
                                       pid: \.processIdentifier, isRegular: { policy($0) == .regular }) {
                try checkCancellation()
                refreshTheApp(nsApp)
            }
            var result: [MacApp: [UInt32]] = [:]
            for try await (pid, windowIds) in group {
                if let app = MacApp.allAppsMap[pid] {
                    result[app] = windowIds
                }
            }
            return result
        }
    }

    func refreshAndGetAliveWindowIds(frontmostAppBundleId: String?) async throws -> [UInt32] {
        if nsApp.isTerminated {
            await destroy()
            return []
        }
        let alive: [UInt32], dead: [UInt32]
        do { (alive, dead) = try await answering(.cancellable) { [nsApp, windows, axApp] (job) -> ([UInt32], [UInt32])? in
            var alive: [UInt32: AxWindow] = try windows.threadGuarded
            var dead = [UInt32: AxWindow]()
            // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
            // Second and third lines of defence are technically needed only to avoid potential flickering
            if frontmostAppBundleId != lockScreenAppBundleId {
                (alive, dead) = try alive.partition {
                    try job.checkCancellation()
                    return $0.value.ax.containingWindowId() != nil
                }
            }

            for (id, window) in try axApp.threadGuarded.get(Ax.windowsAttr) ?? [] {
                try job.checkCancellation()
                try alive.getOrRegisterAxWindow(windowId: id, window, nsApp, job)
            }

            try windows.modify { $0 = alive }
            return (Array(alive.keys), Array(dead.keys))
        } ?? ([], []) } catch is AxTimeout {
            // Pilot: an app that did not answer keeps the windows the engine knows until it answers again (AC6)
            return await MacApp.knownWindowIds(pid: pid)
        }
        windowsCount = alive.count
        for windowId in dead {
            setFrameJobs.removeValue(forKey: windowId)?.cancel()
        }
        return alive
    }

    @MainActor private static func knownWindowIds(pid: pid_t) -> [UInt32] {
        MacWindow.allWindowsMap.values.filter { $0.macApp.pid == pid }.map(\.windowId)
    }

    func destroy() async {
        _ = await Task.startUnstructured { @MainActor [pid] in
            _ = MacApp.allAppsMap.removeValue(forKey: pid)
            windowSlots.appQuit(pid: pid) // Pilot: an app is destroyed once it terminated; its windows' slots (card agent-bo-95423036)
        }.result
        for (_, job) in setFrameJobs {
            job.cancel()
        }
        setFrameJobs = [:]
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { job in CFRunLoopStop(CFRunLoopGetCurrent()) }
        thread = nil // Disallow all future job submissions
    }

    private func withWindow<T: Sendable>(
        _ windowId: UInt32,
        _ cm: CancellationMode,
        _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> T?,
    ) async throws -> T? {
        try await answering(cm) { [windows] job in
            guard let window = try windows.threadGuarded[windowId] else { return nil }
            return try body(window.ax, job)
        }
    }

    /// withWindowAsync for the termination waits: the body runs with nil when the app no longer lists the window, so
    /// the waiter always hears back (AeroSpace's version returned without completing, and the wait never ended).
    private func withWindowForTermination(_ windowId: UInt32, _ body: @Sendable @escaping (AXUIElement?, RunLoopJob) -> ()) -> RunLoopJob {
        thread?.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { [windows] job in
            body(try? windows.threadGuarded[windowId]?.ax, job)
        } ?? .cancelled
    }

    private func withWindowAsync(_ windowId: UInt32, _ cm: CancellationMode, _ body: @Sendable @escaping (AXUIElement, RunLoopJob) throws -> ()) -> RunLoopJob {
        thread?.runInLoopAsync(job: RunLoopJob(cm)) { [windows] job in
            guard let window = try? windows.threadGuarded[windowId] else { return }
            try? body(window.ax, job)
        } ?? .cancelled
    }
}

private final class AxWindow {
    let windowId: UInt32
    let ax: AXUIElement
    private let axSubscriptions: [AxSubscription] // keep subscriptions in memory

    private init(windowId: UInt32, _ ax: AXUIElement, _ axSubscriptions: [AxSubscription]) {
        self.windowId = windowId
        self.ax = ax
        checkSoft(!axSubscriptions.isEmpty)
        self.axSubscriptions = axSubscriptions
    }

    static func new(windowId: UInt32, _ ax: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        let handlers: HandlerToNotifKeyMapping = unsafe [
            (refreshObs, [kAXUIElementDestroyedNotification, kAXWindowDeminiaturizedNotification, kAXWindowMiniaturizedNotification]),
            (movedObs, [kAXMovedNotification]),
            (resizedObs, [kAXResizedNotification]),
        ]
        // Pilot (AC6): the timeout is per element, so each window's own AX calls get it too
        let subscriptions = try unsafe AxSubscription.bulkSubscribe(nsApp, ax.withMessagingTimeout(), job, handlers)
        guard !subscriptions.isEmpty else { return nil }
        // Pilot (card agent-bo-95423036): its title now and at each change, for its slot when the app quits; a window
        // that posts no title change is still tiled
        let titles = (try? unsafe AxSubscription.bulkSubscribe(nsApp, ax, job, [(titleObs, [kAXTitleChangedNotification])])) ?? []
        publishTitle(windowId, ax)
        return AxWindow(windowId: windowId, ax, subscriptions + titles)
    }
}

/// Pilot (live bug, build 49): windows an app reported while the mouse was down, a tab being dragged out among them; each
/// joins the workspace of the display it is dropped on (registrationWorkspace), not the focused one. Written on each app's
/// AX thread.
let windowsSeenInDrag = Mutex<Set<UInt32>>([])

extension [UInt32: AxWindow] {
    @discardableResult
    fileprivate mutating func getOrRegisterAxWindow(windowId id: UInt32, _ axWindow: AXUIElement, _ nsApp: NSRunningApplication, _ job: RunLoopJob) throws -> AxWindow? {
        if let existing = self[id] { return existing }
        // Delay new window detection if mouse is down
        // It helps with apps that allow dragging their tabs out to create new windows
        // https://github.com/nikitabobko/AeroSpace/issues/1001
        if isLeftMouseButtonDown { windowsSeenInDrag.withLock { _ = $0.insert(id) }; return nil }

        if let window = try AxWindow.new(windowId: id, axWindow, nsApp, job) {
            self[id] = window
            return window
        } else {
            return nil
        }
    }
}

private func getAxRect(window: AXUIElement, job: RunLoopJob) throws -> Rect? {
    guard let topLeftCorner = window.get(Ax.topLeftCornerAttr) else { return nil }
    try job.checkCancellation()
    guard let size = window.get(Ax.sizeAttr) else { return nil }
    return Rect(topLeftX: topLeftCorner.x, topLeftY: topLeftCorner.y, width: size.width, height: size.height)
}

/// Pilot: a size and a place go in FrameSteps' order. With `span` (a scrolling column) the frame is read first, and the
/// size the app took after each size write, so the window never reaches past the span; the width it learns is returned.
@discardableResult
private func setFrame(_ window: AXUIElement, _ topLeft: CGPoint?, _ size: CGSize?, span: ClosedRange<CGFloat>? = nil,
                      minWidth: CGFloat = 0, _ job: RunLoopJob) throws -> CGFloat {
    guard let topLeft, let size else {
        // Set size and then the position. The order is important https://github.com/nikitabobko/AeroSpace/issues/143
        //                                                        https://github.com/nikitabobko/AeroSpace/issues/335
        if let size { window.set(Ax.sizeAttr, size) }
        try job.checkCancellation()
        if let topLeft { window.set(Ax.topLeftCornerAttr, topLeft) }
        return minWidth
    }
    let current = span == nil ? nil : try getAxRect(window: window, job: job)
    let target = Rect(topLeftX: topLeft.x, topLeftY: topLeft.y, width: size.width, height: size.height)
    return try FrameSteps(current: current, target: target, span: span, minWidth: minWidth).run(
        setSize: { size, readBack in
            window.set(Ax.sizeAttr, size)
            try job.checkCancellation()
            return span != nil && readBack ? window.get(Ax.sizeAttr) : nil
        },
        setPosition: {
            window.set(Ax.topLeftCornerAttr, $0)
            try job.checkCancellation()
        },
    )
}

// Some undocumented magic
// References: https://github.com/koekeishiya/yabai/commit/3fe4c77b001e1a4f613c26f01ea68c0f09327f3a
//             https://github.com/rxhanson/Rectangle/pull/285
private func disableAnimations<T>(app: AXUIElement, _ job: RunLoopJob, _ body: () throws -> T) throws -> T {
    let wasEnabled = app.get(Ax.enhancedUserInterfaceAttr) == true
    if wasEnabled {
        app.set(Ax.enhancedUserInterfaceAttr, false)
    }
    defer {
        if wasEnabled {
            app.set(Ax.enhancedUserInterfaceAttr, true)
        }
    }
    try job.checkCancellation()
    return try body()
}

extension Glider {
    /// Pilot (card agent-bo-95423033): runs this app's glides until each lands, on its AX thread, paced by `screen`'s
    /// refresh. Enhanced UI goes off once for the run, not per frame (it costs the app), and a frame is the move alone,
    /// with the size shrunk before the first one and grown after the last (FrameSteps' order), read back on a scrolling
    /// column so its move keeps inside its span.
    fileprivate func run(_ app: AXUIElement, _ windows: ThreadGuardedValue<[UInt32: AxWindow]>, on screen: GlideScreen?) {
        guard !isRunning else { return }
        enhancedUIWasOn = app.get(Ax.enhancedUserInterfaceAttr) == true
        if enhancedUIWasOn { app.set(Ax.enhancedUserInterfaceAttr, false) }
        startTicking(on: screen?.screen) { [unowned self] in
            let landed = tick(.now) { step in
                guard let ax = try? windows.threadGuarded[step.id]?.ax else { return }
                let steps = FrameSteps(current: step.sizeUnknown ? nil : step.from, target: step.frame, span: step.span,
                                       minWidth: minWidths[step.id] ?? 0, resetSize: false)
                minWidths[step.id] = steps.run(
                    setSize: { size, readBack in
                        ax.set(Ax.sizeAttr, size)
                        return step.span != nil && readBack ? ax.get(Ax.sizeAttr) : nil
                    },
                    setPosition: { ax.set(Ax.topLeftCornerAttr, $0) },
                )
                if let then = step.then { ax.set(Ax.topLeftCornerAttr, then) } // Pilot: a slid-out window's hide (spaceSlide.swift)
            }
            TilerFrames.announce(takeLanded())
            guard landed else { return }
            stopTicking()
            if enhancedUIWasOn { app.set(Ax.enhancedUserInterfaceAttr, true) }
        }
    }
}
