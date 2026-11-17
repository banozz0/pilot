import AppKit
import CoreGraphics

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
            LiveDisplay(uuid: CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String },
                        identity: identity(of: id))
        }
    }

    /// The screens now in NSScreen's order, the main one first, as a placement's index names them.
    @MainActor public static var screens: [LiveDisplay] { NSScreen.screens.map { LiveDisplay(uuid: $0.displayUUID, identity: $0.displayIdentity) } }

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
}

extension NSScreen {
    /// Pilot's identity of the display (LiveDisplay.identity), read fresh: CoreGraphics answers it from the EDID.
    public var displayIdentity: String? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).flatMap { LiveDisplay.identity(of: $0.uint32Value) }
    }
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
