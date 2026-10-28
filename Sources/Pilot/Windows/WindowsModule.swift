import AppKit
import OSLog
import PilotCore

/// Every window action (SPEC.md stories 6 to 11 and 67): placements and housekeeping through the Accessibility API on the
/// focused window; focus, swap, resize and display moves through Pilot's tiler for tiled windows (TiledKey).
/// Register once; the Binds screen and the Hyper+K sheet read the registry.
@MainActor
enum WindowsModule {
    /// One resize step, in points. Held keys repeat.
    static let resizeStep: CGFloat = 60

    static func register(into registry: inout ActionRegistry, observers: EngineObservers) {
        let snaps: [(id: String, label: String, key: Key?, placement: Placement)] = [
            ("snapLeft", "Snap left half", Key("left"), .leftHalf),
            ("snapRight", "Snap right half", Key("right"), .rightHalf),
            // The halves of a vertical screen (Arrows preset, Sven's Q439).
            ("snapTop", "Snap top half", nil, .topHalf),
            ("snapBottom", "Snap bottom half", nil, .bottomHalf),
            ("maximise", "Maximise", Key("up"), .maximise),
            ("firstThreeQuarters", "First three quarters", Key("["), .firstThreeQuarters),
            ("lastQuarter", "Last quarter", Key("]"), .lastQuarter),
            ("firstThird", "First third", nil, .firstThird),
            ("middleThird", "Middle third", nil, .middleThird),
            ("lastThird", "Last third", nil, .lastThird),
            ("firstTwoThirds", "First two thirds", nil, .firstTwoThirds),
            ("lastTwoThirds", "Last two thirds", nil, .lastTwoThirds),
            ("centre", "Centre", Key("down"), .centre),
        ]
        let tiler = observers.tiler
        for s in snaps {
            add(&registry, s.id, s.label, s.key) { place(s.id, s.placement, tiler: tiler) }
        }
        // Omarchy's pop-out (spec omarchy-ideas T1) on Hyper+Alt+O: floated, centred and pinned,
        // so it follows every workspace its display shows; again, back in the tiles where you are.
        add(&registry, "popOut", "Pop out", Key("o", .alt)) { popOut(tiler) }
        // Floating windows (stories 65 and 66). Hyper+Shift+T is the old tiler's float key.
        add(&registry, "toggleFloat", "Float or tile window", Key("t", shift: true)) { toggleFloat(tiler) }
        add(&registry, "toggleFloatWorkspace", "Float or tile workspace", Key("t", .ctrl)) { toggleFloatWorkspace(tiler, observers: observers) }
        add(&registry, "minimise", "Minimise", nil) { timed("minimise") { AXWindow.focused()?.minimise() != nil } }
        // Tiled window keys (stories 8, 9, 11 and 67) on the old tiler's keys of the interim layout: focus on Hyper+H J K L,
        // swap with Shift. The Omarchy layout ticket moves them (focus to Hyper+arrows, split flip to Hyper+J). The vim
        // pair is the same action a second time, since a bind holds one trigger: the Omarchy preset puts it on left
        // Alt+H J K L, Shift to swap.
        for d in Direction.allCases {
            let name = d.rawValue.capitalized
            tiled(&registry, tiler, "focus\(name)", "Focus window \(d.rawValue)", Key(d.vimKey),
                  .focus(d)) { focus(d, observers: observers) }
            tiled(&registry, tiler, "swap\(name)", "Swap with window \(d.rawValue)", Key(d.vimKey, .shift),
                  .swap(d)) { swap(d, observers: observers) }
            tiled(&registry, tiler, "vimFocus\(name)", "Focus window \(d.rawValue), vim keys", nil,
                  .focus(d)) { focus(d, observers: observers) }
            tiled(&registry, tiler, "vimSwap\(name)", "Swap with window \(d.rawValue), vim keys", nil,
                  .swap(d)) { swap(d, observers: observers) }
        }
        for (verb, sign, key) in [("grow", 1, "="), ("shrink", -1, "-")] {
            for axis in [AeroCommand.Axis.width, .height] {
                let step = sign * Int(resizeStep), height = axis == .height
                // Height has no key in My binds: Hyper+Shift+= and - grow and shrink both ways, as Hammerspoon's knob
                // binds did; the Omarchy preset puts height there.
                tiled(&registry, tiler, "\(verb)\(axis.rawValue.capitalized)", "\(verb.capitalized) \(axis.rawValue)",
                      height ? nil : Key(key), .resize(axis, by: step)) {
                    resize(dw: height ? 0 : CGFloat(step), dh: height ? CGFloat(step) : 0)
                }
            }
            add(&registry, verb, "\(verb.capitalized) window", Key(key, .shift), repeats: true) {
                resizeBoth(verb, by: sign * Int(resizeStep), tiler)
            }
        }
        for (d, key) in [(Direction.left, ","), (.right, ".")] {
            tiled(&registry, tiler, "focusDisplay\(d.rawValue.capitalized)", "Focus display \(d.rawValue)", Key(key),
                  .focusMonitor(d)) { focusDisplay(d, observers: observers) }
            tiled(&registry, tiler, "sendToDisplay\(d.rawValue.capitalized)", "Move window to display \(d.rawValue)",
                  Key(key, shift: true), .sendToMonitor(d)) { sendToDisplay(d) }
        }
        // The This window ring's upper corners (Q415): the window one workspace on or back, among the kept ones, wrapping;
        // you stay where you are. No key: Hyper+Shift+1–9 send it to one by number.
        for (name, next) in [("Next", true), ("Previous", false)] {
            let id = "sendTo\(name)Workspace"
            add(&registry, id, "Move window to \(name.lowercased()) workspace", nil) {
                Task {
                    await tiler.perform("windows.\(id)") { runner in
                        let window = try await tiler.frontWindow(runner)
                        guard let to = neighbour(of: window.workspace, in: tiler.workspaces, next: next) else { return }
                        try await runner.run(.moveWindow(id: window.id, toWorkspace: to))
                    }
                }
            }
        }
        tiled(&registry, tiler, "flipSplit", "Flip split", Key("/"), .flipSplit)
        tiled(&registry, tiler, "toggleScrolling", "Scrolling on or off", nil, .toggleScrolling)
        // The scrolling layout's column keys (spec scrolling-layout, Sven 2026-10-12): widths round on Hyper+R and back on
        // Hyper+Shift+R, centre on Hyper+Alt+C; outside a strip the tiler refuses them.
        tiled(&registry, tiler, "cycleColumnWidth", "Next column width", Key("r"), .cycleColumnWidth(forward: true))
        tiled(&registry, tiler, "cycleColumnWidthBack", "Previous column width", Key("r", .shift), .cycleColumnWidth(forward: false))
        tiled(&registry, tiler, "centreColumn", "Centre column", Key("c", .alt), .centreColumn)
        // Spec scrolling-layout T10 (Sven's Q372): full width and back on Hyper+Alt+F, out of a stack on Hyper+Alt+U.
        tiled(&registry, tiler, "maximiseColumn", "Maximise column", Key("f", .alt), .maximiseColumn)
        tiled(&registry, tiler, "leaveStack", "Leave stack", Key("u", .alt), .leaveStack)
        // The old tiler's window ring on its old keys, Hyper+Tab and Hyper+Shift+Tab, carried over when Pilot took every Hyper key (card
        // agent-bo-95422751); the Omarchy preset puts it on Omarchy's Alt+Tab and gives Hyper+Tab to the next workspace.
        tiled(&registry, tiler, "focusNext", "Focus next window", Key("tab"), .focusRing(next: true))
        tiled(&registry, tiler, "focusPrevious", "Focus previous window", Key("tab", .shift), .focusRing(next: false))
        // The old tiler's service mode as plain binds (Sven, 2026-10-05), on Hyper+Alt in both presets: join a group (Omarchy's
        // Super+Alt+arrows), reset layout, equal sizes, close the others.
        for d in Direction.allCases {
            tiled(&registry, tiler, "join\(d.rawValue.capitalized)", "Join group \(d.rawValue)", Key(d.rawValue, .alt), .join(d))
        }
        tiled(&registry, tiler, "resetLayout", "Reset layout", Key("r", .alt), .resetLayout)
        tiled(&registry, tiler, "balance", "Equal sizes", Key("b", .alt), .balance)
        tiled(&registry, tiler, "closeOthers", "Close other windows", Key("w", .alt), .closeOthers)
        // Show desktop (Sven, 2026-10-26): the workspace's windows out of the way and back, as the tiler hides an unseen
        // workspace. Never through tiled(): with the desktop clicked Finder is in front, and the press back must still work.
        add(&registry, "showDesktop", "Show desktop", nil) {
            Task { await tiler.perform("windows.showDesktop") { try await $0.run(.toggleDesktop) } }
        }
        // Not F11: on a Mac keyboard the top row sends media events unless "Use F1, F2… as standard function keys" is on.
        add(&registry, "fullscreen", "Fullscreen on or off", Key("f", shift: true)) { timed("fullscreen") { fullscreen() } }
        add(&registry, "close", "Close window", Key("w")) { timed("close") { AXWindow.focused()?.close() ?? false } }
        add(&registry, "closeAll", "Close all windows of the app", nil) { timed("close all") { closeAll() } }
        add(&registry, "cycle", "Next window of the app", nil) { timed("cycle") { cycle(observers: observers) } }
        add(&registry, "cycleBack", "Previous window of the app", nil) { timed("cycle back") { cycleBack(observers: observers) } }
        add(&registry, "defocus", "Defocus on or off", Defocus.defaultKey) { DefocusController.shared.toggle() }
    }

    private static func add(_ registry: inout ActionRegistry, _ id: String, _ label: String, _ key: Key?,
                            repeats: Bool = false, run: @escaping @Sendable @MainActor () -> Void) {
        do { try registry.register(Action(id: "windows.\(id)", label: label, module: .windows, defaultKey: key, tier: .v1, repeats: repeats, run: run)) }
        catch { wlog.error("windows.\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    /// Tiled window keys being run, so a held resize key drops repeats while a step is still with the tiler.
    private static var running: Set<String> = []

    /// A tiled window key: through the tiler or Pilot's own code (`fallback`, nil for keys only the tiler can do), as
    /// TiledKey's route says. Repeats for resize only, the step actions.
    private static func tiled(_ registry: inout ActionRegistry, _ tiler: TilerService, _ id: String, _ label: String,
                              _ key: Key?, _ tiledKey: TiledKey, fallback: (@Sendable @MainActor () -> Bool)? = nil) {
        let repeats = if case .resize = tiledKey { true } else { false }
        add(&registry, id, label, key, repeats: repeats) {
            guard running.insert(id).inserted else { return }
            Task {
                defer { running.remove(id) }
                let up = tiler.isRunning
                var window: AeroWindow?
                if up {
                    do { window = try await tiler.frontWindow(tiler.runner) }
                    catch { wlog.debug("windows.\(id, privacy: .public): \(String(describing: error), privacy: .public)") }
                }
                switch tiledKey.route(running: up, window: window, tiler: tiler.tilerName) {
                case .tiler(let command): await tiler.perform("windows.\(id)") { try await $0.run(command) }
                case .pilot: if let fallback { timed(id, fallback) }
                case .unavailable(let why):
                    wlog.notice("windows.\(id, privacy: .public): \(why, privacy: .public)")
                    HUD.tip(why)
                }
            }
        }
    }

    /// Width and height together, one knob detent (Hammerspoon's Hyper+Shift+= and -): a tiled window through the tiler,
    /// both commands aimed at it by id with the tiler's settle between them; a floating one, or any while
    /// the tiler is off, through Pilot's own frame. Repeats drop while a step is still with the tiler.
    private static func resizeBoth(_ id: String, by step: Int, _ tiler: TilerService) {
        guard running.insert(id).inserted else { return }
        Task {
            defer { running.remove(id) }
            if tiler.isRunning, let w = try? await tiler.frontWindow(tiler.runner), !w.isFloating {
                await tiler.perform("windows.\(id)") {
                    let changed = try await $0.resizeBoth(id: w.id, by: step)
                    if changed.count < 2 {
                        let what = changed.isEmpty ? "no axis changed, no split either way" : "only \(changed[0].rawValue), no split the other way"
                        wlog.notice("windows.\(id, privacy: .public): \(what, privacy: .public)")
                    }
                }
            } else {
                timed(id) { resize(dw: CGFloat(step), dh: CGFloat(step)) }
            }
        }
    }

    /// Runs an action and logs one public line: what, on which app, in how many milliseconds, or why not.
    private static func timed(_ what: String, _ body: () -> Bool) {
        let t0 = ContinuousClock.now
        let ok = body()
        let ms = (ContinuousClock.now - t0) / .milliseconds(1)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let frame = AXWindow.focused()?.frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"
        wlog.notice("\(what, privacy: .public) \(ok ? "done" : "no window", privacy: .public) in \(app, privacy: .public), \(Int(ms), privacy: .public) ms, now \(frame, privacy: .public)")
    }

    // MARK: actions

    /// The focused window and its frame, unless it is fullscreen: AX silently ignores moves and resizes there,
    /// and the way out is the fullscreen action.
    private static func movable() -> (AXWindow, CGRect)? {
        guard let w = AXWindow.focused(), let frame = w.frame, !w.isFullScreen else { return nil }
        return (w, frame)
    }

    private static func snap(to placement: Placement) -> Bool {
        guard let (w, frame) = movable() else { return false }
        w.setFrame(placement.frame(in: Screens.visibleFrame(containing: frame)))
        return true
    }

    /// A placement floats a tiled window first (stories 6 and 7), or the tiler would tile it straight back.
    private static func place(_ id: String, _ placement: Placement, tiler: TilerService) {
        guard tiler.isRunning else { return timed(id) { snap(to: placement) } }
        Task {
            if let w = try? await tiler.frontWindow(tiler.runner), !w.isFloating {
                await tiler.perform("windows.\(id): float first") { try await $0.run(.setFloating(id: w.id, true)) }
            }
            timed(id) { snap(to: placement) }
        }
    }

    /// Floats a tiled window and centres it, since the tiler leaves it pinned top-left (spike test 4); tiles a floating one.
    private static func toggleFloat(_ tiler: TilerService) {
        Task {
            await tiler.perform("windows.toggleFloat") { client in
                let w = try await tiler.frontWindow(client)
                try await client.run(.setFloating(id: w.id, !w.isFloating))
                if !w.isFloating { timed("toggleFloat") { snap(to: .centre) } }
            }
        }
    }

    /// Pins the front window floating and centred, or puts a pinned one back in the tiles; with the tiler off, a plain
    /// centre, since nothing carries a pin then.
    private static func popOut(_ tiler: TilerService) {
        guard tiler.isRunning else { return timed("popOut") { snap(to: .centre) } }
        Task {
            await tiler.perform("windows.popOut") { client in
                let w = try await tiler.frontWindow(client)
                try await client.run(.setPinned(id: w.id, !w.isPinned))
                if !w.isPinned { timed("popOut") { snap(to: .centre) } }
            }
        }
    }

    /// Floats every tiled window on the focused workspace, cascaded from the centre, or tiles them all once none tiles.
    private static func toggleFloatWorkspace(_ tiler: TilerService, observers: EngineObservers) {
        Task {
            await tiler.perform("windows.toggleFloatWorkspace") { client in
                let plan = Floating.toggleWorkspace(try await client.windows(.workspace("focused")))
                for command in plan.commands { try await client.run(command) }
                if plan.float { cascade(plan.ids, observers: observers) }
            }
        }
    }

    /// Places floated windows (the tiler's ids are CGWindowIDs) in a cascade from the centre of the first one's display.
    private static func cascade(_ ids: [Int], observers: EngineObservers) {
        let onScreen = observers.windows()
        let windows = ids.compactMap { id in onScreen.first { $0.id == CGWindowID(id) } }
        guard let first = windows.first else { return }
        let frames = Floating.cascade(windows.count, in: Screens.visibleFrame(containing: first.frame))
        for (window, frame) in zip(windows, frames) { AXWindow.matching(window)?.setFrame(frame) }
    }

    private static func resize(dw: CGFloat, dh: CGFloat) -> Bool {
        guard let (w, frame) = movable() else { return false }
        w.setFrame(WindowGeometry.resized(frame, dw: dw, dh: dh, within: Screens.visibleFrame(containing: frame)))
        return true
    }

    /// On-screen windows big enough to be windows, front to back.
    private static func realWindows(_ observers: EngineObservers) -> [WindowInfo] {
        observers.windows().filter { $0.frame.width > 50 && $0.frame.height > 50 }
    }

    /// The on-screen window nearest in a direction, across every app on the current desktop. The focused window
    /// itself covers its own centre, so the geometry drops it along with anything behind it.
    private static func neighbour(_ d: Direction, of frame: CGRect, observers: EngineObservers) -> WindowInfo? {
        let candidates = realWindows(observers)
        guard let id = WindowGeometry.nearest(from: frame, in: d, among: candidates.map { ($0.id, $0.frame) }) else { return nil }
        return candidates.first { $0.id == id }
    }

    private static func focus(_ d: Direction, observers: EngineObservers) -> Bool {
        guard let frame = AXWindow.focused()?.frame,
              let target = neighbour(d, of: frame, observers: observers), let ax = AXWindow.matching(target) else { return false }
        ax.focus()
        return true
    }

    private static func swap(_ d: Direction, observers: EngineObservers) -> Bool {
        guard let (w, frame) = movable(),
              let target = neighbour(d, of: frame, observers: observers), let other = AXWindow.matching(target),
              let otherFrame = other.frame else { return false }
        other.setFrame(frame)
        w.setFrame(otherFrame)
        return true
    }

    private static func fullscreen() -> Bool {
        guard let w = AXWindow.focused() else { return false }
        w.setFullScreen(!w.isFullScreen)
        return true
    }

    private static func closeAll() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let windows = AXWindow.windows(of: app.processIdentifier)
        for w in windows { w.close() }
        return !windows.isEmpty
    }

    /// Raises the app's rearmost on-screen window (CGWindowList is front to back), so repeated presses walk
    /// through all of them.
    private static func cycle(observers: EngineObservers) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let windows = observers.windows(of: app)
        guard windows.count > 1, let last = windows.last, let ax = AXWindow.matching(last) else { return false }
        ax.focus()
        return true
    }

    /// Next window's way back (Arrows preset, Sven's Q439): AX cannot send the front window to the back, so every other
    /// window is raised, rearmost first, and the one behind the front one last: [A, B, C] becomes [B, C, A].
    private static func cycleBack(observers: EngineObservers) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let windows = observers.windows(of: app).compactMap(AXWindow.matching)
        guard windows.count > 1 else { return false }
        for w in windows.dropFirst(2).reversed() { AXUIElementPerformAction(w.element, kAXRaiseAction as CFString) }
        windows[1].focus()
        return true
    }

    /// Focuses the frontmost window on the display beside the focused window's.
    private static func focusDisplay(_ d: Direction, observers: EngineObservers) -> Bool {
        guard let frame = AXWindow.focused()?.frame,
              let to = WindowGeometry.screen(d, from: Screens.index(containing: frame), among: Screens.visibleFrames) else { return false }
        guard let target = realWindows(observers).first(where: { Screens.index(containing: $0.frame) == to }),
              let ax = AXWindow.matching(target) else { return false }
        ax.focus()
        return true
    }

    /// The kept workspace after `current` (or before it), wrapping; nil when there is no other. A workspace not kept counts
    /// as sitting before the first.
    static func neighbour(of current: String, in kept: [String], next: Bool) -> String? {
        guard let at = kept.firstIndex(of: current) ?? (next ? kept.indices.last : kept.indices.first) else { return nil }
        let to = kept[(at + (next ? 1 : -1) + kept.count) % kept.count]
        return to == current ? nil : to
    }

    /// Moves the focused window to the display beside its own, keeping its placement: a left half stays a left half.
    private static func sendToDisplay(_ d: Direction) -> Bool {
        guard let (w, frame) = movable() else { return false }
        let screens = Screens.visibleFrames, from = Screens.index(containing: frame)
        guard let to = WindowGeometry.screen(d, from: from, among: screens) else { return false }
        w.setFrame(WindowGeometry.moved(frame, from: screens[from], to: screens[to]))
        return true
    }
}
