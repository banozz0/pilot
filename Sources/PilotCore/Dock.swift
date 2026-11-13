import Foundation

/// Pilot's dock (spec Projects/Pilot/specs/pilot-dock.html, look A, Sven 2026-11-13, Q199 and Q200): a centred pill at the
/// bottom of the main screen holding the macOS Dock's pins, then the running apps, then its widgets (DockWidget).
/// While it is on, the macOS Dock hides itself through its own auto-hide; Sven's setting comes back when it goes off or
/// Pilot quits.

/// One app the macOS Dock keeps, as its `persistent-apps` names it.
public struct DockPin: Codable, Equatable, Sendable {
    public let bundleID: String?
    public let url: URL
    public let name: String

    public init(bundleID: String?, url: URL, name: String) { self.bundleID = bundleID; self.url = url; self.name = name }

    /// What Pilot's own pin list knows it by: its bundle id, else its path.
    public var key: String { bundleID ?? url.path(percentEncoded: false) }
}

/// The macOS Dock's pins, read from `com.apple.dock` and never written (spec: "read only, never written").
public enum DockPins {
    /// The Dock shows Finder first whatever its list says, and its list never names it.
    public static let finder = DockPin(bundleID: "com.apple.finder", url: URL(filePath: "/System/Library/CoreServices/Finder.app", directoryHint: .isDirectory),
                                       name: "Finder")

    /// Finder, then each app tile of `persistent-apps` in the Dock's order; spacers, folders and tiles with no app are skipped.
    public static func parse(_ persistentApps: [Any]?) -> [DockPin] {
        let tiles = (persistentApps ?? []).compactMap { $0 as? [String: Any] }
        let pins = tiles.compactMap { tile -> DockPin? in
            guard (tile["tile-type"] as? String ?? "file-tile") == "file-tile", let data = tile["tile-data"] as? [String: Any],
                  let raw = (data["file-data"] as? [String: Any])?["_CFURLString"] as? String,
                  let url = URL(string: raw), url.isFileURL, url.pathExtension == "app" else { return nil }
            let label = (data["file-label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return DockPin(bundleID: data["bundle-identifier"] as? String, url: url, name: label ?? url.deletingPathExtension().lastPathComponent)
        }
        return [finder] + pins.filter { $0.bundleID != finder.bundleID }
    }

    /// The pins in a Dock preferences file (the sandbox's copy).
    public static func read(file: URL) -> [DockPin] {
        let plist = (try? Data(contentsOf: file)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return parse(plist?["persistent-apps"] as? [Any])
    }

    /// The live Dock's pins, through CFPreferences after a sync, so a pin added since the last read shows.
    public static func readLive() -> [DockPin] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        return parse(CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [Any])
    }
}

/// An app running now, as the dock lists it.
public struct DockRunning: Equatable, Sendable {
    public let bundleID: String?
    public let url: URL?
    public let name: String
    public let pid: Int32

    public init(bundleID: String?, url: URL?, name: String, pid: Int32) { self.bundleID = bundleID; self.url = url; self.name = name; self.pid = pid }
}

/// One icon in the dock.
public struct DockApp: Equatable, Sendable {
    public let bundleID: String?
    public let url: URL?
    public let name: String
    public let pinned: Bool
    /// Its process while it runs.
    public let pid: Int32?
    /// The windows Pilot's tiler lists for it, on every workspace.
    public let windows: Int
    public let front: Bool

    public init(bundleID: String?, url: URL?, name: String, pinned: Bool, pid: Int32?, windows: Int, front: Bool) {
        self.bundleID = bundleID; self.url = url; self.name = name; self.pinned = pinned; self.pid = pid; self.windows = windows; self.front = front
    }

    public var running: Bool { pid != nil }
    /// What Pilot's own pin list knows it by, as DockPin.key.
    public var key: String { bundleID ?? url?.path(percentEncoded: false) ?? name }
    /// The dots under it: one per window, at most three; a running app with no window listed keeps one, as the Dock's does.
    public var dots: Int { running ? min(max(windows, 1), DockApps.mostDots) : 0 }
    /// What a click does: open or bring it forward, focus its one window, or list its windows to pick one.
    public var click: DockClick { windows >= 2 ? .listWindows : windows == 1 ? .focusWindow : .activate }
}

public enum DockClick: String, Equatable, Sendable { case activate, focusWindow, listWindows }

/// An app's right-click menu in the dock (Sven on build 2454): Open, its windows, Show in Files (Pilot's own, Sven
/// 2026-11-13: "show in finder should probably show in pilots finder"), Keep in Dock or Remove
/// from Dock (Pilot's own pins), Quit. Sections, a separator between each.
public enum DockMenuItem: Equatable, Sendable {
    case open
    case window(id: Int, title: String, workspace: String)
    case showInFiles, keepInDock, removeFromDock, quit

    public var title: String {
        switch self {
        case .open: "Open"
        case .window(_, let title, let workspace): "\(title)  ·  WS \(workspace)"
        case .showInFiles: "Show in Files"
        case .keepInDock: "Keep in Dock"
        case .removeFromDock: "Remove from Dock"
        case .quit: "Quit"
        }
    }

    /// `windows` are the app's own, from Pilot's tiler. Finder can be neither taken out nor quit, as in the Dock.
    public static func menu(_ app: DockApp, windows: [AeroWindow]) -> [[DockMenuItem]] {
        let finder = app.bundleID == DockPins.finder.bundleID
        return [
            [.open],
            windows.map { .window(id: $0.id, title: $0.title.isEmpty ? app.name : $0.title, workspace: $0.workspace) },
            app.url == nil ? [] : [.showInFiles],
            finder ? [] : [app.pinned ? .removeFromDock : .keepInDock],
            app.running && !finder ? [.quit] : [],
        ].filter { !$0.isEmpty }
    }
}

public enum DockApps {
    public static let mostDots = 3

    /// The pins in the Dock's order, then every other running app in launch order. `windows` counts each app's windows by
    /// bundle id; `front` is the front app's.
    public static func list(pins: [DockPin], running: [DockRunning], windows: [String: Int], front: String?) -> [DockApp] {
        func app(_ bundleID: String?, url: URL?, name: String, pinned: Bool, pid: Int32?) -> DockApp {
            DockApp(bundleID: bundleID, url: url, name: name, pinned: pinned, pid: pid,
                    windows: pid == nil ? 0 : bundleID.flatMap { windows[$0] } ?? 0, front: pid != nil && bundleID != nil && bundleID == front)
        }
        func matches(_ pin: DockPin, _ run: DockRunning) -> Bool {
            if let id = pin.bundleID, let other = run.bundleID { return id == other }
            return run.url?.standardizedFileURL == pin.url.standardizedFileURL
        }
        var left = running
        let pinned = pins.map { pin in
            let run = left.firstIndex { matches(pin, $0) }.map { left.remove(at: $0) }
            return app(pin.bundleID ?? run?.bundleID, url: pin.url, name: pin.name, pinned: true, pid: run?.pid)
        }
        return pinned + left.map { app($0.bundleID, url: $0.url, name: $0.name, pinned: false, pid: $0.pid) }
    }
}

/// The dock's size: its icons' side in points.
public enum DockSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var icon: Double {
        switch self {
        case .small: 40
        case .medium: 48
        case .large: 56
        }
    }

    /// The room over the icons, the dot's lane under them and its gap, and the room under the lane (look A, round 2).
    public static let top = 8.0, laneGap = 4.0, lane = 5.0, bottom = 5.0
    /// The pill's height: the icon, its dot's lane, and the room above and below.
    public var pill: Double { Self.top + icon + Self.laneGap + Self.lane + Self.bottom }
    /// Hover magnification falls to none `reachIcons` icons either side of the pointer.
    public static let reachIcons = 3.0
    /// What the dock's box adds while the pointer is over its icons at `magnify`: above, the tallest magnified icon's
    /// growth; across, the most the bell widens the row (its area, `reachIcons` icons at half the growth). Never part of
    /// `room`; nothing with magnification off, so no box above the pill ever takes the windows' clicks.
    public func reach(_ magnify: DockMagnification) -> (width: Double, height: Double) {
        let grow = magnify.scale - 1
        return (width: (Self.reachIcons * icon * grow).rounded(.up), height: (icon * grow).rounded(.up))
    }
    /// The pill's gap to the screen's bottom edge.
    public static let margin = 8.0
    /// What the tiler keeps clear at the bottom of the dock's screen.
    public var room: Int { Int((pill + Self.margin).rounded(.up)) }
}

/// Hover magnification (round 4, Sven 2026-11-13: the Dock page's Magnification): the icon under the pointer this many
/// times its size. Medium is round 2's, the Dock's own default look.
public enum DockMagnification: String, Codable, CaseIterable, Sendable {
    case off, small, medium, large

    public var scale: Double {
        switch self {
        case .off: 1
        case .small: 1.25
        case .medium: 1.5
        case .large: 1.75
        }
    }

    public var title: String { rawValue.capitalized }
}

/// A widget's own choices (round 4, Sven 2026-11-13: "customise widgets aswell"), one field per widget that has any, so
/// a later choice (round 5's battery looks, clocks) is one more field read with its default.
public struct DockWidgetOptions: Codable, Equatable, Sendable {
    /// System stats: the readings it shows, any the top bar's stats items read, in MenuBarStats.Stat's order.
    public var stats: [MenuBarStats.Stat]

    public static let defaultStats: [MenuBarStats.Stat] = [.cpu, .ram]

    public init(stats: [MenuBarStats.Stat] = DockWidgetOptions.defaultStats) { self.stats = stats }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // By name, so a stat a later Pilot adds is dropped here, never the whole list.
        let names = (try? c.decodeIfPresent([String].self, forKey: .stats)) ?? nil
        stats = names.map { $0.compactMap(MenuBarStats.Stat.init(rawValue:)) } ?? Self.defaultStats
    }

    /// Picks `stats` for System stats, each once, in the stats' own order; none leaves them as they are.
    public mutating func pick(_ picked: [MenuBarStats.Stat]) {
        guard !picked.isEmpty else { return }
        stats = MenuBarStats.Stat.allCases.filter(picked.contains)
    }
}

extension TopBarBackground: Codable {}

/// The dock's choices, saved as one (`dock.settings`).
public struct DockSettings: Codable, Equatable, Sendable {
    public var size: DockSize
    /// What it stands on, the top bar's own choice (round 4, Sven 2026-11-13: "solid, glass and clear like everything
    /// else"): Glass by default.
    public var style: TopBarBackground = .glass
    public var magnify: DockMagnification = .medium
    /// Its widgets in Sven's order (design round 3, Q215): any of the eleven, each once, and installed extensions' bar
    /// answers (round 4).
    public var widgets: [DockSlot]
    public var options = DockWidgetOptions()
    /// Pilot's own pins over the macOS Dock's, whose list is read and never written (spec pilot-dock; Sven on build 2454:
    /// Keep in Dock and Remove from Dock): apps kept past the Dock's own, and the Dock's pins taken out, by `DockPin.key`.
    public var kept: [DockPin] = []
    public var removed: [String] = []

    public init(size: DockSize = .medium, widgets: [DockSlot] = DockSlot.defaults) { self.size = size; self.widgets = widgets }

    /// The dock's pins: the macOS Dock's (`dock`, Finder first) less the ones taken out, then the ones kept, in order.
    public func pinned(_ dock: [DockPin]) -> [DockPin] {
        let keys = Set(dock.map(\.key))
        return dock.filter { !removed.contains($0.key) } + kept.filter { !keys.contains($0.key) }
    }

    /// Keep in Dock: an app the Dock's list holds comes back; any other joins the end.
    public mutating func keep(_ pin: DockPin, dock: [DockPin]) {
        removed.removeAll { $0 == pin.key }
        if !dock.contains(where: { $0.key == pin.key }), !kept.contains(where: { $0.key == pin.key }) { kept.append(pin) }
    }

    /// Remove from Dock: one Pilot kept goes; one of the Dock's is taken out of Pilot's dock alone. Finder stays, as in the Dock.
    public mutating func unpin(_ key: String, dock: [DockPin]) {
        guard key != DockPins.finder.key else { return }
        kept.removeAll { $0.key == key }
        if dock.contains(where: { $0.key == key }), !removed.contains(key) { removed.append(key) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = (try? c.decode(DockSize.self, forKey: .size)) ?? .medium
        style = (try? c.decodeIfPresent(TopBarBackground.self, forKey: .style)) ?? .glass
        magnify = (try? c.decodeIfPresent(DockMagnification.self, forKey: .magnify)) ?? .medium
        // Saved as names (DockSlot's Codable): a list from before round 3 reads through DockSlot.migrated.
        widgets = (try? c.decode([String].self, forKey: .widgets)).map(DockSlot.migrated) ?? DockSlot.defaults
        options = (try? c.decodeIfPresent(DockWidgetOptions.self, forKey: .options)) ?? DockWidgetOptions()
        kept = (try? c.decodeIfPresent([DockPin].self, forKey: .kept)) ?? []
        removed = (try? c.decodeIfPresent([String].self, forKey: .removed)) ?? []
    }

    /// Turns `widget` on, at `index` in the order (the end when nil or past it).
    public mutating func add(_ widget: DockSlot, at index: Int? = nil) throws(DockWidgetError) {
        guard !widgets.contains(widget) else { throw .already(widget.name) }
        widgets.insert(widget, at: min(max(index ?? widgets.count, 0), widgets.count))
    }

    public mutating func remove(_ widget: DockSlot) throws(DockWidgetError) {
        guard let index = widgets.firstIndex(of: widget) else { throw .missing(widget.name) }
        widgets.remove(at: index)
    }

    /// Moves an on widget `by` places along the order (negative: toward the icons), held to the ends.
    public mutating func move(_ widget: DockSlot, by: Int) {
        guard let from = widgets.firstIndex(of: widget) else { return }
        let to = min(max(from + by, 0), widgets.count - 1)
        guard to != from else { return }
        widgets.remove(at: from)
        widgets.insert(widget, at: to)
    }
}

public enum DockWidgetError: Error, Equatable, CustomStringConvertible {
    case unknown(String), already(String), missing(String)

    public var description: String {
        switch self {
        case .unknown(let name): "\(name) is no dock widget: " + DockWidget.allCases.map(\.rawValue).joined(separator: ", ") + ", or extension:<id> for an installed extension with a menu bar item"
        case .already(let name): "\(name) is in the dock already"
        case .missing(let name): "\(name) is not in the dock"
        }
    }
}

public typealias DockAutohide = MenuBarAutohide

/// The macOS Dock's reveal delay, its own `autohide-delay` default in seconds; nil while the key is absent (macOS's own
/// delay). Auto-hide alone still slides the Dock up as the pointer touches the screen's foot, over Pilot's pill (Sven on
/// build 2454: his delay was 0, so it rose at once); a delay of `DockSwitch.hiddenDelay` keeps it down. A protocol so
/// tests and the sandbox never touch the real one.
public protocol DockRevealDelay: Sendable {
    func read() async throws -> Double?
    /// Writes `seconds` (nil removes the key), then has the Dock take it.
    func write(_ seconds: Double?) async throws
}

/// The real one: `defaults` in a child process, then `killall Dock`, since the Dock reads its delay only as it starts
/// (launchd starts it again at once). Refuses in a test process, as SystemEventsAutohide does.
public struct DefaultsDockDelay: DockRevealDelay {
    public init() {}

    public func read() async throws -> Double? {
        guard !SystemEventsAutohide.inTestProcess else { throw SystemEventsAutohide.Refused() }
        do {
            let out = try await ChildProcess.run("/usr/bin/defaults", ["read", "com.apple.dock", "autohide-delay"], timeout: .seconds(10))
            return Double(out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let failure as ChildProcess.Failure where failure.message.contains("does not exist") { return nil }
    }

    public func write(_ seconds: Double?) async throws {
        guard !SystemEventsAutohide.inTestProcess else { throw SystemEventsAutohide.Refused() }
        let args = seconds.map { ["write", "com.apple.dock", "autohide-delay", "-float", String($0)] } ?? ["delete", "com.apple.dock", "autohide-delay"]
        _ = try await ChildProcess.run("/usr/bin/defaults", args, timeout: .seconds(10))
        _ = try await ChildProcess.run("/usr/bin/killall", ["Dock"], timeout: .seconds(10))
    }
}

public enum DockError: Error, CustomStringConvertible {
    case autohide(any Error)
    case delay(any Error)
    case room(any Error)

    public var description: String {
        switch self {
        case .autohide(let e): "The macOS Dock's hiding was not changed (System Events: \(e)); allow Pilot under Privacy & Security › Automation"
        case .delay(let e): "The macOS Dock's reveal delay was not changed: \(e)"
        case .room(let e): "The tiler's room for the dock was not set: \(e)"
        }
    }
}

/// The dock's switch, as the top bar's (TopBarSwitch): on saves the Dock's auto-hide and reveal delay, makes room in
/// Pilot's block, turns auto-hide on, then sets the delay to `hiddenDelay` so the Dock never rises at the screen's foot;
/// off clears the room, then puts both back. Each step that fails undoes the ones before it, so the switch is fully on
/// or as it was. Quitting puts both back and keeps the switch on, so the next launch hides the Dock again (`resumed`).
public struct DockSwitch: Codable, Equatable, Sendable {
    public var isOn: Bool
    /// The Dock's auto-hide as Sven had it, put back by off and by quitting.
    public var savedAutohide: Bool?
    /// The Dock's reveal delay as Sven had it (nil: the key was absent), put back while `delaySaved`. Both optional, so a
    /// switch saved before the delay decodes with none saved.
    public var savedDelay: Double?
    public var delaySaved: Bool?

    public init(isOn: Bool, savedAutohide: Bool?, savedDelay: Double? = nil, delaySaved: Bool? = nil) {
        self.isOn = isOn; self.savedAutohide = savedAutohide; self.savedDelay = savedDelay; self.delaySaved = delaySaved
    }

    public static let off = DockSwitch(isOn: false, savedAutohide: nil)
    /// Seconds the pointer must rest at the screen's foot before the hidden Dock rises: past any real wait.
    public static let hiddenDelay = 1000.0

    public typealias WriteRoom = @Sendable ([PilotBlock.BarInset]) async throws -> Void

    public func switchedOn(_ room: [PilotBlock.BarInset], autohide: any DockAutohide, delay: any DockRevealDelay,
                           writeRoom: WriteRoom) async throws(DockError) -> DockSwitch {
        guard !isOn else { return self }
        let found: Bool, foundDelay: Double?
        do { found = try await autohide.isHidden() } catch { throw .autohide(error) }
        do { foundDelay = try await delay.read() } catch { throw .delay(error) }
        do { try await writeRoom(room) } catch { throw .room(error) }
        do { try await autohide.setHidden(true) } catch {
            try? await writeRoom([])
            throw .autohide(error)
        }
        // Each write restarts the Dock: none when it is at the hidden delay already.
        do { if foundDelay != Self.hiddenDelay { try await delay.write(Self.hiddenDelay) } } catch {
            try? await autohide.setHidden(found)
            try? await writeRoom([])
            throw .delay(error)
        }
        return DockSwitch(isOn: true, savedAutohide: found, savedDelay: foundDelay, delaySaved: true)
    }

    /// `room` is the one kept now, written back when the Dock refuses to come back.
    public func switchedOff(room: [PilotBlock.BarInset], autohide: any DockAutohide, delay: any DockRevealDelay,
                            writeRoom: WriteRoom) async throws(DockError) -> DockSwitch {
        guard isOn else { return self }
        do { try await writeRoom([]) } catch { throw .room(error) }
        do { try await restore(autohide: autohide, delay: delay) } catch {
            try? await autohide.setHidden(true)
            try? await writeRoom(room)
            throw error
        }
        return .off
    }

    /// At launch with the switch on: the Dock's auto-hide now is Sven's when it is off (a clean quit put his back, and he may
    /// have changed it since); on, it is the one a crash left or his own, and the saved value stands. The delay likewise:
    /// any value but `hiddenDelay` is his. Then both are set again.
    public func resumed(autohide: any DockAutohide, delay: any DockRevealDelay) async throws(DockError) -> DockSwitch {
        guard isOn else { return self }
        var next = self
        do {
            let now = try await autohide.isHidden()
            if !now { try await autohide.setHidden(true) }
            next.savedAutohide = now ? savedAutohide ?? true : false
        } catch { throw .autohide(error) }
        do {
            let now = try await delay.read()
            if now != Self.hiddenDelay {
                (next.savedDelay, next.delaySaved) = (now, true)
                try await delay.write(Self.hiddenDelay)
            } else if delaySaved != true {
                // Found at the hidden delay with none saved: a Pilot from before the delay never set it, so macOS's own.
                (next.savedDelay, next.delaySaved) = (nil, true)
            }
        } catch { throw .delay(error) }
        return next
    }

    /// Quitting with the switch on: the saved auto-hide and delay go back; the switch stays on for the next launch.
    public func restoredForQuit(autohide: any DockAutohide, delay: any DockRevealDelay) async throws(DockError) {
        guard isOn else { return }
        try await restore(autohide: autohide, delay: delay)
    }

    /// Sven's auto-hide, then his delay, put back.
    private func restore(autohide: any DockAutohide, delay: any DockRevealDelay) async throws(DockError) {
        do { try await autohide.setHidden(savedAutohide ?? false) } catch { throw .autohide(error) }
        guard delaySaved == true, savedDelay != Self.hiddenDelay else { return }
        do { try await delay.write(savedDelay) } catch { throw .delay(error) }
    }
}

/// How the dock's icons fit its screen (design round 2, look A): at their size while the row fits, smaller down to
/// `smallest` when it does not, then at `smallest` in a row that scrolls. The pill is never wider than `available`, so
/// nothing is cut.
public struct DockFit: Equatable, Sendable {
    public static let smallest = 32.0
    public let icon: Double
    public let scrolls: Bool

    public init(icon: Double, scrolls: Bool) { self.icon = icon; self.scrolls = scrolls }

    /// `fixed` is what the pill spends besides its icons (its ends, the hairline, the widgets); `gapRatio` the gap as a
    /// share of an icon.
    public static func fit(apps: Int, icon: Double, gapRatio: Double, fixed: Double, available: Double, smallest: Double = DockFit.smallest) -> DockFit {
        guard apps > 0 else { return DockFit(icon: icon, scrolls: false) }
        let n = Double(apps), fitted = ((available - fixed) / (n + (n - 1) * gapRatio)).rounded(.down)
        if fitted >= icon { return DockFit(icon: icon, scrolls: false) }
        if fitted >= smallest { return DockFit(icon: fitted, scrolls: false) }
        return DockFit(icon: smallest, scrolls: true)
    }
}
