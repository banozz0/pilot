import AppKit
import Synchronization

/// The workspaces, numbered from 1 (Sven 2026-10-09: 1 to 9 by default, added and removed on the Workspaces page): never
/// more than nine, one per number key, never fewer than one. Adding one makes the next number; deleting one closes its
/// number, the ones after it moving down (WorkspaceRenumber, Sven's Q233), so Hyper+N is always the Nth workspace. Pilot's own setting (`workspaces.count` in its defaults); the old
/// AeroSpace config's persistent-workspaces list is never read.
public enum Workspaces {
    /// Every workspace Pilot can keep.
    public static let all = (1...9).map(String.init)
    public static let key = "workspaces.count"
    /// How many there were before the count was a setting (card agent-bo-95422744, "I hate 10").
    public static let before = 4

    public static func clamped(_ count: Int) -> Int { min(max(count, 1), all.count) }

    /// The first `count` workspaces.
    public static func names(_ count: Int) -> [String] { Array(all.prefix(clamped(count))) }

    /// The saved count; all nine while none is saved.
    public static func count(in defaults: UserDefaults) -> Int {
        defaults.object(forKey: key) == nil ? all.count : clamped(defaults.integer(forKey: key))
    }

    public static func save(_ count: Int, in defaults: UserDefaults) { defaults.set(clamped(count), forKey: key) }

    /// Which workspaces are kept. A build of 2026-10-17 let Delete leave a gap (1, 3 and 4); Sven's Q233 closes gaps
    /// (WorkspaceList.closeGaps), so the list is 1 to n again once one is read.
    public static let keptKey = "workspaces.kept"

    /// The workspaces kept, in number order: the saved list, else the first `count`.
    public static func kept(in defaults: UserDefaults) -> [String] {
        let saved = all.filter((defaults.stringArray(forKey: keptKey) ?? []).contains)
        return saved.isEmpty ? names(count(in: defaults)) : saved
    }

    /// Saves the list, in number order, and its count with it.
    public static func save(kept: [String], in defaults: UserDefaults) {
        let list = all.filter(kept.contains)
        defaults.set(list, forKey: keptKey)
        save(list.count, in: defaults)
    }

    /// Where a deleted workspace's windows go: the nearest kept one before it, else the nearest after it.
    public static func neighbour(of gone: String, in kept: [String]) -> String? {
        let others = kept.filter { $0 != gone }
        guard let n = Int(gone) else { return others.first }
        return others.last { (Int($0) ?? 0) < n } ?? others.first
    }

    /// The workspace number a go or move action names, nil for any other action.
    public static func number(inAction id: String) -> String? {
        guard ["workspaces.go:", "workspaces.move:", "workspaces.moveFollow:"].contains(where: id.hasPrefix) else { return nil }
        return id.split(separator: ":", maxSplits: 1).last.map(String.init)
    }

    /// A go or move for a workspace past the count: hidden from the menu and the Binds list, and inert when pressed.
    public static func isRemoved(action id: String, kept: [String]) -> Bool {
        number(inAction: id).map { !kept.contains($0) } ?? false
    }

    /// Go and move for all nine (stories 62 and 63): Hyper+N goes there, Hyper+Shift+N moves the focused window and
    /// Hyper+Alt+N moves it and goes along (spec omarchy-ideas T7, Q101); `move` gets the name and whether to follow. Their
    /// default keys seed the bind store. One past the count does nothing but say so, so its key never reaches the app
    /// in front and comes back with the workspace.
    public static func register(into registry: inout ActionRegistry, kept: @escaping @Sendable @MainActor () -> [String],
                                removed: @escaping @Sendable @MainActor (String) -> Void = { _ in },
                                go: @escaping @Sendable @MainActor (String) -> Void,
                                move: @escaping @Sendable @MainActor (_ name: String, _ follow: Bool) -> Void) throws(ActionRegistry.RegistrationError) {
        for name in all {
            try registry.register(Action(id: "workspaces.go:\(name)", label: "Go to workspace \(name)", module: .workspaces,
                                         defaultKey: Key(name), tier: .v1) { kept().contains(name) ? go(name) : removed(name) })
            try registry.register(Action(id: "workspaces.move:\(name)", label: "Move window to workspace \(name)", module: .workspaces,
                                         defaultKey: Key(name, .shift), tier: .v1) { kept().contains(name) ? move(name, false) : removed(name) })
            try registry.register(Action(id: "workspaces.moveFollow:\(name)", label: "Move window to workspace \(name) and follow",
                                         module: .workspaces, defaultKey: Key(name, .alt), tier: .v1) {
                kept().contains(name) ? move(name, true) : removed(name)
            })
        }
    }
}

/// Deleting a workspace closes its number (Sven's Q233, 2026-10-17): delete 3 of 1 to 5 and 4 becomes 3, 5 becomes 4,
/// each taking what is tied to its number (name, preset, layout, snapshot, app rules, monitor, windows), so Hyper+N is the
/// Nth workspace and there is no gap. The deleted one's windows and app rules go to the one before it (after it, for 1).
/// With nothing deleted it closes the gaps an older build left: 1, 2, 4 become 1, 2, 3.
public struct WorkspaceRenumber: Equatable, Sendable {
    /// A tiler step: every window on `from` moves to `to`.
    public struct Move: Equatable, Sendable {
        public let from: String, to: String
    }

    /// The workspace deleted, by its old number.
    public let gone: String?
    /// The workspaces kept afterwards: 1 to n.
    public let names: [String]
    /// Each kept workspace's new number by its old one.
    public let renamed: [String: String]
    /// Where the deleted one's windows go, by old number.
    public let into: String?

    public init(deleting gone: String?, from kept: [String]) {
        let survivors = kept.filter { $0 != gone }
        names = survivors.indices.map { String($0 + 1) }
        renamed = Dictionary(uniqueKeysWithValues: zip(survivors, names))
        self.gone = gone
        into = gone.flatMap { Workspaces.neighbour(of: $0, in: kept) }
    }

    /// Whether any number changes.
    public var changes: Bool { gone != nil || renamed.contains { $0.key != $0.value } }

    /// What `old` is called afterwards: its new number, the deleted one's the number its windows went to; a number not
    /// kept stays as it was.
    public func new(_ old: String) -> String { old == gone ? into.flatMap { renamed[$0] } ?? old : renamed[old] ?? old }

    /// The windows' moves, in order: the deleted one's into its neighbour, then each kept one down to its new number,
    /// lowest first, so a workspace is always emptied before the next one moves onto it. Deleting 1 moves none of its
    /// windows: 2 becoming 1 joins them.
    public var moves: [Move] {
        let first = gone.flatMap { gone in into.flatMap { renamed[$0] == gone ? nil : Move(from: gone, to: $0) } }
        let down = renamed.filter { $0.key != $0.value }.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map { Move(from: $0.key, to: $0.value) }
        return [first].compactMap { $0 } + down
    }

    /// Anything kept by workspace, under the new numbers: the deleted one's dropped; one for a number not kept stays,
    /// unless a kept one now takes its number.
    public func rekeyed<Value>(_ byWorkspace: [String: Value]) -> [String: Value] {
        var out = byWorkspace.filter { $0.key != gone && renamed[$0.key] == nil && !names.contains($0.key) }
        for (old, new) in renamed { if let value = byWorkspace[old] { out[new] = value } }
        return out
    }

    /// App rules (Always lands here) under the new numbers; the deleted one's go where its windows went.
    public func rules(_ rules: [PilotBlock.AppRule]) -> [PilotBlock.AppRule] {
        rules.map { PilotBlock.AppRule(appId: $0.appId, workspace: new($0.workspace)) }
    }
}

/// Where a workspace opens (N7, Sven 2026-10-09: "3 and 4 always show on monitor 2 and spaces 1 and 2 on main
/// monitor"). No pin is Any: the workspace opens wherever it was last shown.
public enum MonitorPin: Codable, Hashable, Sendable {
    /// Whichever display is main (the one with the menu bar at the origin).
    case main
    /// A display by the name macOS gives it and its display UUID, which survives replugging. A pin carried over from
    /// AeroSpace's table has no id yet: its name is AeroSpace's monitor description, matched as AeroSpace did.
    case display(name: String, id: String?)
}

/// A connected display as the Monitor pick offers it.
public struct ConnectedDisplay: Hashable, Sendable {
    public let name: String
    public let id: String
    public init(name: String, id: String) { self.name = name; self.id = id }

    public var pin: MonitorPin { .display(name: name, id: id) }

    /// The displays connected now, in NSScreen's order.
    @MainActor public static var current: [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen in screen.displayUUID.map { ConnectedDisplay(name: screen.localizedName, id: $0) } }
    }

    /// This display is the one `pin` names: by id, or by name for a carried-over pin that has none.
    public func matches(_ pin: MonitorPin) -> Bool {
        guard case .display(let name, let id) = pin else { return false }
        return id.map { $0 == self.id } ?? (name.caseInsensitiveCompare(self.name) == .orderedSame)
    }
}

extension NSScreen {
    /// The display's UUID, which macOS derives from its vendor, model and serial, so it survives replugging. Kept per
    /// display number, since the own tiler reads it each time it lists the monitors, many times per layout.
    public var displayUUID: String? {
        guard let number = (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
        if let known = Self.uuids.withLock({ $0[number] }) { return known }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        let id = CFUUIDCreateString(nil, uuid) as String
        Self.uuids.withLock { $0[number] = id }
        return id
    }

    private static let uuids = Mutex<[CGDirectDisplayID: String]>([:])
}

/// Each workspace's monitor pin, Pilot's own setting (N7), saved in Pilot's defaults and fed to Pilot's tiler. On first
/// read it starts from the workspace-to-monitor-force-assignment table in the old AeroSpace config, read once as an
/// import (card agent-bo-95422997, AC1), so nothing moves under Sven's fingers; after that the table is never read again.
public enum WorkspaceMonitors {
    static let table = "workspace-to-monitor-force-assignment"
    public static let key = "workspaces.monitors"

    /// The table's values by workspace; a value that is not one quoted string is left out.
    public static func carryOver(from file: String) -> [String: String] {
        TOMLLine.walk(file).reduce(into: [:]) { monitors, line in
            guard line.table == table, let key = line.key, let value = line.value, case .string(let monitor) = TOMLValue(value) else { return }
            monitors[String(key.dropFirst(table.count + 1))] = monitor
        }
    }

    /// The saved pins, or on first read the ones `file` (the old AeroSpace config, read once as an import) carries,
    /// saved once there are any. A carried name that is a connected display's becomes that display, id and all; the rest
    /// wait with their name.
    public static func pins(in defaults: UserDefaults, carryingFrom file: @autoclosure () -> String,
                            displays: [ConnectedDisplay]) -> [String: MonitorPin] {
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([String: MonitorPin].self, from: data) { return saved }
        let carried = carryOver(from: file()).mapValues { name in
            if name == "main" { return MonitorPin.main }
            let pin = MonitorPin.display(name: name, id: nil)
            return displays.first { $0.matches(pin) }?.pin ?? pin
        }
        if !carried.isEmpty { save(carried, in: defaults) }
        return carried
    }

    public static func save(_ pins: [String: MonitorPin], in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: key) }
    }

    /// The Monitor pick for a workspace pinned to `pin`: Any, Main, each connected display, and a pinned display that is
    /// unplugged, so the pick still says where the workspace goes once it is back; `picked` is the one `pin` names, a
    /// name-only pin lighting its connected display.
    public static func choices(pinned pin: MonitorPin?, displays: [ConnectedDisplay])
        -> (choices: [(value: MonitorPin?, title: String)], picked: MonitorPin?) {
        var choices: [(value: MonitorPin?, title: String)] = [(nil, "Any"), (.main, "Main")]
        choices += displays.map { ($0.pin, $0.name) }
        guard let pin, case .display(let name, _) = pin else { return (choices, pin) }
        if let display = displays.first(where: { $0.matches(pin) }) { return (choices, display.pin) }
        return (choices + [(pin, "\(name) (unplugged)")], pin)
    }
}
