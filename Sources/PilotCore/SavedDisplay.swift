import AppKit
import CoreGraphics
import Synchronization

/// A connected display as a saved screen is matched against: macOS's display UUID and Pilot's identity, the EDID's
/// vendor, model and serial ("1507:46104:1010101", the start of `pilot system`'s identity). The UUID is not lasting:
/// macOS handed Sven's ultrawide a new one at the restarts of 2026-11-16 while the identity stayed, so a saved screen
/// keeps both and the identity wins.
public struct LiveDisplay: Equatable, Sendable {
    public let uuid: String?, identity: String?
    public init(uuid: String?, identity: String?) { self.uuid = uuid; self.identity = identity }

    /// Pilot's identity of `display`: nil when it carries no EDID (no vendor and no model).
    public static func identity(of display: CGDirectDisplayID) -> String? {
        let vendor = CGDisplayVendorNumber(display), model = CGDisplayModelNumber(display)
        guard vendor != 0 || model != 0 else { return nil }
        return "\(vendor):\(model):\(CGDisplaySerialNumber(display))"
    }

    /// The displays connected now, from CoreGraphics, so any thread may read them; in no particular order.
    public static func connected() -> [LiveDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            LiveDisplay(uuid: uuid(of: id), identity: identity(of: id))
        }
    }

    /// macOS's UUID of `display` now, read fresh, as the tiler reads it for its workspaces (QueryCalls).
    public static func uuid(of display: CGDirectDisplayID) -> String? {
        CGDisplayCreateUUIDFromDisplayID(display).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    }

    /// The screens now in NSScreen's order, the main one first, as a placement's index names them; UUIDs read fresh.
    @MainActor public static var screens: [LiveDisplay] { NSScreen.screens.map { LiveDisplay(uuid: $0.freshDisplayUUID, identity: $0.displayIdentity) } }

    /// The index in `live` of the display a saved UUID and identity name: the identity when exactly one display has it
    /// (twins with one serial fall through), else the UUID; nil when neither names a connected display.
    public static func index(uuid: String?, identity: String?, in live: [LiveDisplay]) -> Int? {
        if let identity {
            let hits = live.indices.filter { live[$0].identity == identity }
            if hits.count == 1 { return hits[0] }
        }
        return uuid.flatMap { uuid in live.firstIndex { $0.uuid == uuid } }
    }

    /// The identity to keep beside a saved `uuid`: the connected display's that has that very UUID, else `kept`.
    public static func identity(for uuid: String?, kept: String?, in live: [LiveDisplay]) -> String? {
        uuid.flatMap { uuid in live.first { $0.uuid == uuid } }?.identity ?? kept
    }

    // MARK: Settings kept per display

    /// The key a setting kept per display (a nickname, a rotation, a screen's own wallpaper folders) saves this display
    /// under among `live`: its identity while no other display there shares it, else its UUID.
    public func key(among live: [LiveDisplay]) -> String? {
        if let identity, live.count(where: { $0.identity == identity }) <= 1 { return identity }
        return uuid
    }

    /// The keys such a setting may hold this display under, the first that holds a value winning: its key, then its UUID
    /// (a value saved before identities).
    public func keys(among live: [LiveDisplay]) -> [String] {
        let key = key(among: live)
        return [key, uuid != key ? uuid : nil].compactMap { $0 }
    }

    /// The screens now with their kept UUIDs and identities (cheap, unlike `screens`), in NSScreen's order.
    @MainActor public static var kept: [LiveDisplay] { NSScreen.screens.map { LiveDisplay(uuid: $0.displayUUID, identity: $0.displayIdentity) } }

    /// The connected display a setting names by `uuid` (kept UUIDs first, then fresh reads), and the screens it was found
    /// among; nil when no display has that UUID now.
    @MainActor public static func connected(uuid: String) -> (display: LiveDisplay, among: [LiveDisplay])? {
        let live = kept
        if let found = live.first(where: { $0.uuid == uuid }) { return (found, live) }
        let fresh = screens
        return fresh.first { $0.uuid == uuid }.map { ($0, fresh) }
    }

    /// The key to save a setting under for the display with `uuid` (its identity when unique), the UUID itself while
    /// that display is not connected.
    @MainActor public static func key(forUUID uuid: String) -> String {
        connected(uuid: uuid).flatMap { $0.display.key(among: $0.among) } ?? uuid
    }

    /// The keys a setting may hold the display with `uuid` under, the first that holds a value winning.
    @MainActor public static func keys(forUUID uuid: String) -> [String] {
        connected(uuid: uuid).map { $0.display.keys(among: $0.among) } ?? [uuid]
    }
}

extension Dictionary where Key == String {
    /// The value kept under the first of `keys` that holds one (LiveDisplay.keys).
    public func first(of keys: [String]) -> Value? { keys.lazy.compactMap { self[$0] }.first }
}

extension NSScreen {
    private var number: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }

    /// The display's UUID, kept per display number until the screens change, since the own tiler reads it each time it
    /// lists the monitors, many times per layout. It is not lasting: macOS handed Sven's ultrawide a new one while Pilot
    /// ran (2026-11-16, its EDID serial a placeholder), so a setting kept for good matches `displayIdentity` first, and
    /// what must agree with the tiler's fresh read uses `freshDisplayUUID`.
    public var displayUUID: String? {
        guard let number else { return nil }
        _ = Self.forgetAtScreenChanges
        if let known = Self.uuids.withLock({ $0[number] }) { return known }
        guard let id = LiveDisplay.uuid(of: number) else { return nil }
        Self.uuids.withLock { $0[number] = id }
        return id
    }

    /// The display's UUID read now (66 µs on an M4), as the tiler reads it.
    public var freshDisplayUUID: String? { number.flatMap(LiveDisplay.uuid(of:)) }

    /// Pilot's identity of the display (LiveDisplay.identity), kept per display number until the screens change: a read
    /// is three CoreGraphics calls (185 µs on an M4).
    public var displayIdentity: String? {
        guard let number else { return nil }
        _ = Self.forgetAtScreenChanges
        if let known = Self.identities.withLock({ $0[number] }) { return known }
        let identity = LiveDisplay.identity(of: number)
        Self.identities.withLock { $0[number] = identity }
        return identity
    }

    private static let uuids = Mutex<[CGDirectDisplayID: String]>([:])
    private static let identities = Mutex<[CGDirectDisplayID: String?]>([:])
    /// A screen change forgets both: a display number may come back as another display, and a display a new UUID.
    private static let forgetAtScreenChanges: Void = {
        _ = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { _ in
            uuids.withLock { $0 = [:] }
            identities.withLock { $0 = [:] }
        }
    }()
}

extension Widget.Placement {
    /// The index in `live` (NSScreen's order) of the screen it shows on: its identity's, else its UUID's; the main one
    /// for none. One saved before identities (no `screenIdentity`) whose UUID names no display now shows on the main
    /// one: macOS may have given that display a new UUID, and a widget that shows nowhere cannot be found to move.
    public func screenIndex(in live: [LiveDisplay]) -> Int? {
        guard !live.isEmpty else { return nil }
        guard let screen else { return 0 }
        return LiveDisplay.index(uuid: screen, identity: screenIdentity, in: live) ?? (screenIdentity == nil ? 0 : nil)
    }

    /// Its identity kept beside its UUID from the display that has that UUID now; whether it changed.
    @discardableResult public mutating func fillIdentity(from live: [LiveDisplay]) -> Bool {
        let filled = onHome ? nil : LiveDisplay.identity(for: screen, kept: screenIdentity, in: live)
        defer { screenIdentity = filled }
        return filled != screenIdentity
    }
}
