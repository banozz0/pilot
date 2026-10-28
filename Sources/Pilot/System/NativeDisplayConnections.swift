import CoreGraphics
import Darwin
import Foundation
import IOKit

/// The private SkyLight display-enable transaction, kept separate from the public layout transaction.
/// Missing private symbols are an unavailable feature, never an alternative invocation shape.
final class NativeDisplayConnections: DisplayConnectionsBackend, @unchecked Sendable {
    enum Failure: LocalizedError { case unavailable, unverifiedDisplay, noOtherDisplay, refused(Int32)
        var errorDescription: String? { switch self { case .unavailable: "Display connections are unavailable on this macOS version"; case .unverifiedDisplay: "That physical display is no longer verified"; case .noOtherDisplay: "Pilot will not turn off the last active display"; case let .refused(code): "macOS refused the display change (\(code))" } }
    }

    private typealias Begin = @convention(c) (UnsafeMutablePointer<OpaquePointer?>) -> Int32
    private typealias ConfigureEnabled = @convention(c) (OpaquePointer?, UInt32, Bool) -> Int32
    private typealias Complete = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias Cancel = @convention(c) (OpaquePointer?) -> Int32
    private typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private let begin: Begin?, configureEnabled: ConfigureEnabled?, complete: Complete?, cancel: Cancel?
    private let info: Info?
    private let lock = NSLock()

    init() {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? { handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) } }
        begin = load(sky, "SLSBeginDisplayConfiguration", Begin.self) ?? load(sky, "CGSBeginDisplayConfiguration", Begin.self)
        configureEnabled = load(sky, "SLSConfigureDisplayEnabled", ConfigureEnabled.self) ?? load(sky, "CGSConfigureDisplayEnabled", ConfigureEnabled.self)
        complete = load(sky, "SLSCompleteDisplayConfigurationWithOption", Complete.self) ?? load(sky, "CGSCompleteDisplayConfigurationWithOption", Complete.self)
        cancel = load(sky, "SLSCancelDisplayConfiguration", Cancel.self) ?? load(sky, "CGSCancelDisplayConfiguration", Cancel.self)
        info = load(core, "CoreDisplay_DisplayCreateInfoDictionary", Info.self)
    }

    func read(remembered: [ConnectionScreen]) async throws -> [ConnectionScreen] { try await Task.detached { [self] in try lock.withLock { try readNow(remembered) } }.value }
    func setEnabled(_ enabled: Bool, screen: ConnectionScreen) async throws { try await Task.detached { [self] in try lock.withLock { try setNow(enabled, screen: screen) } }.value }
    func restoreLayout(_ screens: [ConnectionScreen]) async throws { try await Task.detached { [self] in try lock.withLock { try restoreNow(screens) } }.value }

    private func readNow(_ remembered: [ConnectionScreen]) throws -> [ConnectionScreen] {
        let ids = try online()
        let live = ids.compactMap { screen($0) }
        let physical = Set(framebufferIdentities())
        return live + Self.missingScreens(live: live, remembered: remembered).map { old in
            var copy = old
            // A physically-present identity absent from the usable desktop is the observed logical-off state.
            let exact = old.location.flatMap(attributes).map { identity(attributes: $0) == old.identity } ?? false
            copy.state = exact && physical.contains(old.identity) ? .off : .unavailable
            copy = ConnectionScreen(id: copy.id, name: copy.name, identity: copy.identity, state: copy.state, main: false, builtIn: copy.builtIn, asleep: false, frame: copy.frame, mode: copy.mode, rotation: copy.rotation, verified: copy.verified, location: copy.location, supported: copy.supported, displayUUID: copy.displayUUID)
            return copy
        }
    }

    static func missingScreens(live: [ConnectionScreen], remembered: [ConnectionScreen]) -> [ConnectionScreen] {
        // CoreDisplay metadata can be incomplete during reconfiguration. A live physical binding supersedes its
        // remembered row even when its fingerprint or session handle changed; raw ID alone is not a binding. A row with no
        // registry location (a virtual output: headless fallback, Sidecar, AirPlay) can never be turned on, so it is
        // forgotten once it leaves instead of lingering as an UNKNOWN row.
        remembered.filter { old in old.location != nil && !live.contains(where: {
            $0.identity == old.identity || (old.location != nil && $0.location == old.location)
        }) }
    }

    private func setNow(_ enabled: Bool, screen: ConnectionScreen) throws {
        guard let begin, let configureEnabled, let complete, let cancel else { throw Failure.unavailable }
        guard let location = screen.location, let attrs = attributes(path: location), identity(attributes: attrs) == screen.identity,
              screen.identity.split(separator: ":").contains(where: { $0 != "-" }) else { throw Failure.unverifiedDisplay }
        let onlineIDs = try online()
        let current = onlineIDs.contains(screen.id) ? self.screen(screen.id) : nil
        let currentMatches = current.map { $0.identity == screen.identity && $0.location == location } ?? false
        guard Self.allowsMutation(enable: enabled, rawIDIsOnline: onlineIDs.contains(screen.id), currentBindingMatches: currentMatches) else {
            throw Failure.unverifiedDisplay
        }
        let awakeActive = try active().compactMap(self.screen).filter { !$0.asleep }
        if !enabled {
            guard awakeActive.contains(where: { $0.id == screen.id && $0.identity == screen.identity && $0.location == screen.location }) else { throw Failure.unverifiedDisplay }
            let survivors = Set(awakeActive.filter { $0.id != screen.id }.map(\.identity))
            if survivors.isEmpty { throw Failure.noOtherDisplay }
        }
        var config: OpaquePointer?
        let started = begin(&config)
        guard started == 0, let config else { throw Failure.refused(started) }
        let configured = configureEnabled(config, screen.id, enabled)
        guard configured == 0 else { _ = cancel(config); throw Failure.refused(configured) }
        let finished = complete(config, 1) // kCGConfigureForSession: survives app exit, resets at logout.
        guard finished == 0 else { throw Failure.refused(finished) }
    }

    private func restoreNow(_ screens: [ConnectionScreen]) throws {
        let current = try active().compactMap(screen)
        let mapped = screens.filter { $0.state == .on }.compactMap { saved in current.first { $0.identity == saved.identity && $0.location == saved.location }.map { (saved, $0) } }
        guard !mapped.isEmpty,
              Set(mapped.map { $0.1.id }).count == mapped.count,
              Set(mapped.map { $0.1.location }).count == mapped.count else { throw Failure.unverifiedDisplay }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { throw Failure.unavailable }
        for (screen, live) in mapped {
            let id = live.id
            guard screen.frame.origin.x.isFinite, screen.frame.origin.y.isFinite,
                  screen.frame.origin.x >= Double(Int32.min), screen.frame.origin.x <= Double(Int32.max),
                  screen.frame.origin.y >= Double(Int32.min), screen.frame.origin.y <= Double(Int32.max),
                  let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
                  live.rotation == screen.rotation,
                  let mode = modes.first(where: { $0.ioDisplayModeID == screen.mode.id && $0.width == screen.mode.width && $0.height == screen.mode.height && $0.pixelWidth == screen.mode.pixelWidth && abs($0.refreshRate - screen.mode.refresh) < 0.1 }) ?? modes.first(where: { $0.width == screen.mode.width && $0.height == screen.mode.height && $0.pixelWidth == screen.mode.pixelWidth && abs($0.refreshRate - screen.mode.refresh) < 0.1 }),
                  CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success,
                  CGConfigureDisplayOrigin(config, id, Int32(screen.frame.origin.x), Int32(screen.frame.origin.y)) == .success
            else { CGCancelDisplayConfiguration(config); throw Failure.unavailable }
        }
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { throw Failure.unavailable }
    }

    private func online() throws -> [UInt32] { try list(CGGetOnlineDisplayList) }
    private func active() throws -> [UInt32] { try list(CGGetActiveDisplayList) }
    private func list(_ call: (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>) -> CGError) throws -> [UInt32] { var n: UInt32 = 0; guard call(0, nil, &n) == .success else { throw Failure.unavailable }; var ids = [UInt32](repeating: 0, count: Int(n)); guard call(n, &ids, &n) == .success else { throw Failure.unavailable }; return Array(ids.prefix(Int(n))) }
    private func screen(_ id: UInt32) -> ConnectionScreen? {
        let dictionary = info?(id)?.takeRetainedValue() as? [String: Any]
        let location = dictionary?["IODisplayLocation"] as? String
        let attributes = attributes(path: location)
        let fingerprint = identity(attributes: attributes)
        let mode = CGDisplayCopyDisplayMode(id)
        let displayMode = mode.map { DisplayMode(id: $0.ioDisplayModeID, width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth, refresh: $0.refreshRate) } ?? DisplayMode(id: 0, width: 0, height: 0, pixelWidth: 0, refresh: 0)
        let validIdentity = location != nil && fingerprint.split(separator: ":").contains(where: { $0 != "-" })
        return ConnectionScreen(id: id, name: (attributes?["ProductAttributes"] as? [String: Any])?["ProductName"] as? String ?? "Display \(id)", identity: fingerprint, state: mode == nil ? .unknown : (CGDisplayIsActive(id) != 0 ? .on : .unknown), main: CGDisplayIsMain(id) != 0, builtIn: CGDisplayIsBuiltin(id) != 0, asleep: CGDisplayIsAsleep(id) != 0, frame: CGDisplayBounds(id), mode: displayMode, rotation: Int(CGDisplayRotation(id)), verified: false, location: location, supported: validIdentity && begin != nil && configureEnabled != nil && complete != nil && cancel != nil, displayUUID: DisplayIdentity.uuid(for: id))
    }
    private func framebufferIdentities() -> [String] {
        ["IOMobileFramebufferShim", "IOMobileFramebuffer", "AppleCLCD2"].flatMap { cls -> [String] in
            var iterator: io_iterator_t = 0
            guard let match = IOServiceMatching(cls), IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
            defer { IOObjectRelease(iterator) }
            var result: [String] = []
            while true {
                let entry = IOIteratorNext(iterator)
                guard entry != 0 else { break }
                defer { IOObjectRelease(entry) }
                if let attributes = attributes(entry: entry) { result.append(identity(attributes: attributes)) }
            }
            return result
        }
    }
    private func attributes(path: String?) -> [String: Any]? { guard let path else { return nil }; let e = IORegistryEntryCopyFromPath(kIOMainPortDefault, path as CFString); guard e != 0 else { return nil }; defer { IOObjectRelease(e) }; return attributes(entry: e) }
    private func attributes(entry: io_registry_entry_t) -> [String: Any]? { var p: Unmanaged<CFMutableDictionary>?; guard IORegistryEntryCreateCFProperties(entry, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS, let d = p?.takeRetainedValue() as? [String: Any] else { return nil }; return d["DisplayAttributes"] as? [String: Any] }
    private func identity(attributes: [String: Any]?) -> String { let p = attributes?["ProductAttributes"] as? [String: Any]; return [p?["LegacyManufacturerID"], p?["ProductID"], p?["SerialNumber"], p?["AlphanumericSerialNumber"], attributes?["PortID"]].map { $0.map { String(describing: $0) } ?? "-" }.joined(separator: ":") }

    /// An OFF display can lose CoreDisplay metadata. Its saved handle is usable only for explicit ON, after the caller
    /// has independently revalidated the exact physical registry location and fingerprint above.
    static func allowsMutation(enable: Bool, rawIDIsOnline: Bool, currentBindingMatches: Bool) -> Bool {
        if rawIDIsOnline { return currentBindingMatches }
        return enable
    }
}
