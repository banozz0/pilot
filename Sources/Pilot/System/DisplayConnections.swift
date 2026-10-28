import AppKit
import CoreGraphics
import Foundation
import Observation
import PilotCore

/// A display's membership in this login session. `unavailable` and `unknown` deliberately never mean `off`: neither is
/// safe to reconnect or restore without a fresh native reading.
enum ConnectionState: String, Codable, Equatable, Sendable {
    case on, off, unavailable, unknown
}

/// The stable monitor identity is the durable key; the CoreGraphics id is only a current-session handle and may churn.
struct ConnectionScreen: Codable, Equatable, Identifiable, Sendable {
    struct Binding: Hashable, Sendable {
        let identity: String
        let location: String?
    }
    var binding: Binding { Binding(identity: identity, location: location) }
    /// Unidentified native rows still need distinct UI keys; mutation capabilities always retain physical binding.
    var rowID: AnyHashable {
        if location == nil && identity == "-:-:-:-:-" { return AnyHashable(id) }
        return AnyHashable(binding)
    }
    let id: UInt32
    let name: String
    let identity: String
    /// Native IODisplayLocation, when available; identity remains the durable user-visible key.
    let location: String?
    var state: ConnectionState
    let main: Bool
    let builtIn: Bool
    let asleep: Bool
    /// Native private-symbol availability for this output; state alone never promises a callable backend.
    let supported: Bool
    let frame: CGRect
    let mode: DisplayMode
    let rotation: Int
    var verified: Bool
    /// Personal labels use the display UUID, never the connection fingerprint or registry path.
    let displayUUID: String?

    init(id: UInt32, name: String, identity: String, state: ConnectionState, main: Bool, builtIn: Bool, asleep: Bool,
         frame: CGRect, mode: DisplayMode, rotation: Int, verified: Bool = false, location: String? = nil, supported: Bool = false,
         displayUUID: String? = nil) {
        self.id = id; self.name = name; self.identity = identity; self.state = state
        self.location = location
        self.main = main; self.builtIn = builtIn; self.asleep = asleep; self.frame = frame
        self.mode = mode; self.rotation = rotation; self.verified = verified
        self.supported = supported
        self.displayUUID = displayUUID
    }

}

/// Native code owns the session-scoped connection calls. It must run its private API work away from the event-tap main
/// thread and must not change membership during `read`.
protocol DisplayConnectionsBackend: AnyObject, Sendable {
    func read(remembered: [ConnectionScreen]) async throws -> [ConnectionScreen]
    /// The whole screen is the capability: native code must rebind identity and location before trusting `id`.
    func setEnabled(_ enabled: Bool, screen: ConnectionScreen) async throws
    /// Restore the entire pre-OFF arrangement together so primary/origins cannot be recreated piecemeal.
    func restoreLayout(_ screens: [ConnectionScreen]) async throws
}

struct DisplayConnectionsCheckpoint: Codable, Equatable, Sendable {
    static let version = 1
    let version: Int
    var remembered: [ConnectionScreen]
    /// First complete arrangement before any managed output is removed; never overwritten by survivor promotion.
    var recoveryLayout: [ConnectionScreen]
    /// Physical identities Pilot deliberately removed. Observed inventory is never allowed to erase this recovery set.
    var managedOffIdentities: Set<String>
    var verifiedIdentities: [String: String]

    init(remembered: [ConnectionScreen] = [], recoveryLayout: [ConnectionScreen] = [], managedOffIdentities: Set<String> = [], verifiedIdentities: [String: String] = [:]) {
        version = Self.version
        self.remembered = remembered
        self.recoveryLayout = recoveryLayout
        self.managedOffIdentities = managedOffIdentities
        self.verifiedIdentities = verifiedIdentities
    }
}

/// The seam lets tests prove that no display mutation happens when durable recovery cannot be written.
protocol DisplayConnectionsStore: AnyObject {
    func load() throws -> DisplayConnectionsCheckpoint
    func save(_ checkpoint: DisplayConnectionsCheckpoint) throws
}

final class FileDisplayConnectionsStore: DisplayConnectionsStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pilot/display-connections.json")
    }

    func load() throws -> DisplayConnectionsCheckpoint {
        guard FileManager.default.fileExists(atPath: url.path) else { return DisplayConnectionsCheckpoint() }
        let checkpoint = try JSONDecoder().decode(DisplayConnectionsCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.version == DisplayConnectionsCheckpoint.version else {
            throw ConnectionFailure.unsupported("display connection store version \(checkpoint.version)")
        }
        return checkpoint
    }

    func save(_ checkpoint: DisplayConnectionsCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }
}

enum ConnectionFailure: LocalizedError {
    case refused(String), unsupported(String)
    var errorDescription: String? {
        switch self { case .refused(let text), .unsupported(let text): text }
    }
}

private actor DisplayConnectionLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// Captures only windows visible on a display immediately before Pilot removes it. Hidden workspace windows are never
/// captured, so topology changes cannot accidentally unhide them.
@MainActor
struct DisplayConnectionWindowMigration {
    struct Window {
        let frame: @MainActor () -> CGRect?
        let move: @MainActor (CGRect) -> Void
    }
    let capture: ([CGRect]) -> [Window]

    static let live = DisplayConnectionWindowMigration(capture: { screens in
        let onScreenIDs = Set(EngineObservers.onScreen().filter { $0.layer == 0 && $0.alpha > 0 }.map(\.info.id))
        return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.flatMap { app in
            AXWindow.windows(of: app.processIdentifier).compactMap { window in
                guard !window.isMinimised, let frame = window.frame,
                      Self.captures(frame, windowID: window.windowID, onScreenIDs: onScreenIDs, in: screens) else { return nil }
                return Window(frame: { window.frame }, move: window.setFrame)
            }
        }
    })
    static let none = DisplayConnectionWindowMigration(capture: { _ in [] })
    /// AX reports windows in hidden Spaces too; their matching window-server id is absent from `optionOnScreenOnly`.
    static func captures(_ frame: CGRect, windowID: CGWindowID?, onScreenIDs: Set<CGWindowID>, in screens: [CGRect]) -> Bool {
        guard let windowID, onScreenIDs.contains(windowID) else { return false }
        return screens.contains { !$0.intersection(frame).isNull }
    }

    func rescue(_ captured: [Window], to visible: CGRect, screens: [CGRect]) {
        guard visible.width > 0, visible.height > 0 else { return }
        let stranded = captured.compactMap { window -> Window? in
            guard let frame = window.frame(), Rescue.isStranded(frame, screens: screens) else { return nil }
            return window
        }
        let frames = stranded.compactMap { $0.frame() }
        for (window, frame) in zip(stranded, Rescue.placements(frames, in: visible)) { window.move(frame) }
    }
}

/// Safety controller for temporary desktop membership. A checkpoint always reaches disk before a private display call;
/// failed reads or no-op writes roll back best-effort and retain the checkpoint for Restore All to retry.
@Observable @MainActor
final class DisplayConnections {
    static let shared = DisplayConnections(backend: NativeDisplayConnections(), store: FileDisplayConnectionsStore(), makeBackend: { NativeDisplayConnections() }, windowMigration: .live)

    private(set) var screens: [ConnectionScreen] = []
    private(set) var busy = false
    private(set) var problem: String?
    @ObservationIgnored private let backend: any DisplayConnectionsBackend
    @ObservationIgnored private let makeBackend: @Sendable () -> any DisplayConnectionsBackend
    @ObservationIgnored private let settle: @Sendable () async -> Void
    @ObservationIgnored private let windowMigration: DisplayConnectionWindowMigration
    @ObservationIgnored private let store: any DisplayConnectionsStore
    @ObservationIgnored private let lock = DisplayConnectionLock()
    @ObservationIgnored private var checkpoint: DisplayConnectionsCheckpoint
    /// Decode/version failures are permanent until the user repairs the file; write failures may be retried.
    @ObservationIgnored private var loadFailure: Error?
    @ObservationIgnored private var storeFailure: Error?
    @ObservationIgnored private var queuedOperations = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(backend: any DisplayConnectionsBackend, store: any DisplayConnectionsStore,
         makeBackend: (@Sendable () -> any DisplayConnectionsBackend)? = nil,
         settle: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) },
         windowMigration: DisplayConnectionWindowMigration = .none) {
        self.backend = backend; self.store = store; self.makeBackend = makeBackend ?? { backend }; self.settle = settle; self.windowMigration = windowMigration
        do { checkpoint = try store.load() }
        catch {
            checkpoint = DisplayConnectionsCheckpoint()
            loadFailure = error
            problem = "Display connections are unavailable: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        await serial { [self] in
            do { try await read() } catch { markUnknown(); fail(error) }
        }
    }

    /// Observation only: launch, wake and display reconfiguration refresh the model but never reconnect or disconnect.
    func startObserving() {
        guard observers.isEmpty else { return }
        Task { [weak self] in await self?.refresh() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { [weak self] in await self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { [weak self] in await self?.refresh() }
        })
    }

    func canDisconnect(_ screen: ConnectionScreen) -> Bool {
        guard screen.supported, screen.state == .on, !screen.asleep else { return false }
        return Set(screens.filter { $0.supported && $0.state == .on && !$0.asleep }.map(\.identity)).count > 1
    }

    func validationNeeded(_ screen: ConnectionScreen) -> Bool {
        return checkpoint.verifiedIdentities[screen.identity] != Self.osBuild
    }

    /// An attended off/on round trip. It certifies one physical display for this OS build, then leaves it enabled.
    func validateConnection(id: UInt32, binding: ConnectionScreen.Binding? = nil) async {
        await serial { [self] in
            var changed = false
            var temporaryBaseline = false
            var calibrationLayout: [ConnectionScreen] = []
            var target: ConnectionScreen?
            do {
                let screen = try await current(id, binding: binding)
                target = screen
                guard screen.state == .on, !screen.asleep else { throw ConnectionFailure.refused("That display is not awake and connected") }
                guard canDisconnect(screen) else { throw ConnectionFailure.refused("Pilot will not disconnect the last awake display") }
                calibrationLayout = screens.filter { $0.state == .on }
                if checkpoint.recoveryLayout.isEmpty { checkpoint.recoveryLayout = screens; temporaryBaseline = true }
                checkpoint.managedOffIdentities.insert(screen.identity)
                try saveCheckpoint()
                changed = true
                try await backend.setEnabled(false, screen: screen)
                let disconnected = try await observed(screen, state: .off)
                try await requireSurvivor(excluding: disconnected.identity)
                // A fresh adapter proves session recovery does not depend on cached native state.
                try await makeBackend().setEnabled(true, screen: disconnected)
                let reconnected = try await observed(disconnected, state: .on)
                guard !reconnected.asleep else { throw ConnectionFailure.refused("macOS reconnected \(screen.name) asleep") }
                try await backend.restoreLayout(calibrationLayout)
                try await verifyLayout(calibrationLayout, excluding: [])
                checkpoint.verifiedIdentities[screen.identity] = Self.osBuild
                checkpoint.managedOffIdentities.remove(screen.identity)
                if temporaryBaseline { checkpoint.recoveryLayout = [] }
                try saveCheckpoint()
                try await read()
            } catch {
                if let identity = target?.identity { checkpoint.verifiedIdentities.removeValue(forKey: identity) }
                if loadFailure == nil { do { try saveCheckpoint() } catch { fail(ConnectionFailure.refused("\(error.localizedDescription); could not save validation failure")) } }
                if changed, let rollbackError = await rollback(target, layout: calibrationLayout) {
                    fail(ConnectionFailure.refused("\(error.localizedDescription); rollback failed: \(rollbackError)"))
                    return
                }
                fail(error)
            }
        }
    }

    /// OFF requires an attended validation; ON always attempts reconnection and restores the saved arrangement.
    func setConnected(_ connected: Bool, id: UInt32, binding: ConnectionScreen.Binding? = nil) async {
        await serial { [self] in
            var changed = false
            var captured: [DisplayConnectionWindowMigration.Window] = []
            var target: ConnectionScreen?
            do {
                let screen = try await current(id, binding: binding)
                target = screen
                guard screen.supported, !screen.asleep, screen.state == .on || screen.state == .off else {
                    throw ConnectionFailure.refused("That display is unavailable")
                }
                guard connected || canDisconnect(screen) else { throw ConnectionFailure.refused("Pilot will not disconnect the last awake display") }
                guard connected || !validationNeeded(screen) else { throw ConnectionFailure.refused("Validate this display in person before turning it off") }
                guard (connected && screen.state == .off) || (!connected && screen.state == .on) else {
                    throw ConnectionFailure.refused("That display is already \(connected ? "on" : "off")")
                }
                if !connected {
                    if checkpoint.recoveryLayout.isEmpty { checkpoint.recoveryLayout = screens }
                    checkpoint.managedOffIdentities.insert(screen.identity)
                    captured = windowMigration.capture(screens.filter { $0.state == .on && !$0.asleep }.map(\.frame))
                }
                if !connected { try saveCheckpoint() }
                changed = true
                try await backend.setEnabled(connected, screen: screen)
                let result = try await observed(screen, state: connected ? .on : .off)
                if !connected { try await requireSurvivor(excluding: result.identity) }
                if !connected {
                    let active = screens.filter { $0.identity != result.identity && $0.state == .on && !$0.asleep }
                    if let landing = active.first?.frame { windowMigration.rescue(captured, to: landing, screens: active.map(\.frame)) }
                }
                guard connected || !result.asleep else {
                    throw ConnectionFailure.refused("macOS did not \(connected ? "reconnect" : "disconnect") \(screen.name)")
                }
                if connected {
                    let restored = try await observed(result, state: .on)
                    guard !restored.asleep else { throw ConnectionFailure.refused("macOS restored \(screen.name) asleep") }
                    let recovery = checkpoint
                    let remaining = checkpoint.managedOffIdentities.subtracting([screen.identity])
                    if remaining.isEmpty {
                        try await backend.restoreLayout(checkpoint.recoveryLayout.isEmpty ? [screen] : checkpoint.recoveryLayout)
                        try await verifyLayout(checkpoint.recoveryLayout, excluding: [])
                        checkpoint.recoveryLayout = []
                    }
                    checkpoint.managedOffIdentities = remaining
                    do { try saveCheckpoint() } catch { checkpoint = recovery; throw error }
                }
                try await read()
            } catch {
                if changed, let identity = target?.identity {
                    checkpoint.verifiedIdentities.removeValue(forKey: identity)
                    if loadFailure == nil { _ = try? saveCheckpoint() }
                }
                if changed, let rollbackError = await rollback(target) {
                    fail(ConnectionFailure.refused("\(error.localizedDescription); rollback failed: \(rollbackError)"))
                    return
                }
                fail(error)
            }
        }
    }

    /// Recovery is intentionally retryable: only a fully restored screen leaves its remembered off state.
    func restoreAll() async {
        await serial { [self] in
            do {
                try await refreshInventory()
                guard !checkpoint.managedOffIdentities.isEmpty || !checkpoint.recoveryLayout.isEmpty else {
                    try await read()
                    return
                }
                let remembered = checkpoint.remembered.filter { checkpoint.managedOffIdentities.contains($0.identity) }
                var failures: [String] = []
                for screen in remembered {
                    do {
                        try await backend.setEnabled(true, screen: screen)
                        _ = try await observed(screen, state: .on)
                    } catch { failures.append("\(screen.name): \(error.localizedDescription)") }
                }
                guard failures.isEmpty else { throw ConnectionFailure.refused(failures.joined(separator: "; ")) }
                try await backend.restoreLayout(checkpoint.recoveryLayout)
                try await verifyLayout(checkpoint.recoveryLayout, excluding: [])
                let recovery = checkpoint
                checkpoint.managedOffIdentities.removeAll()
                checkpoint.recoveryLayout = []
                do { try saveCheckpoint() } catch { checkpoint = recovery; throw error }
                try await read()
            } catch { fail(error) }
        }
    }

    private static var osBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    private func serial(_ work: @escaping @MainActor () async -> Void) async {
        queuedOperations += 1
        busy = true
        await lock.acquire()
        await work()
        await lock.release()
        queuedOperations -= 1
        busy = queuedOperations > 0
    }

    private func current(_ id: UInt32, binding: ConnectionScreen.Binding?) async throws -> ConnectionScreen {
        if let loadFailure { throw loadFailure }
        let candidates = screens.filter { $0.id == id }
        guard binding != nil || candidates.count <= 1 else { throw ConnectionFailure.refused("Ambiguous display id; select its physical identity") }
        let expected = binding ?? candidates.first?.binding
        let fresh: [ConnectionScreen]
        do { fresh = try await backend.read(remembered: checkpoint.remembered) }
        catch { markUnknown(); throw error }
        screens = fresh.map { item in
            var item = item
            item.verified = checkpoint.verifiedIdentities[item.identity] == Self.osBuild
            return item
        }
        checkpoint.remembered = screens
        guard expected != nil || screens.filter({ $0.id == id }).count <= 1 else { throw ConnectionFailure.refused("Ambiguous display id; select its physical identity") }
        guard let screen = screens.first(where: { expected == nil ? $0.id == id : $0.binding == expected }) else { throw ConnectionFailure.refused("Display identity changed; refresh before trying again") }
        guard screens.filter({ $0.identity == screen.identity }).count == 1 else { throw ConnectionFailure.refused("Duplicate display identity; reconnect a uniquely identified display") }
        return screen
    }

    /// A CoreGraphics id can change while an output leaves and returns; the physical binding must remain the same.
    private func observed(_ expected: ConnectionScreen, state: ConnectionState) async throws -> ConnectionScreen {
        var last: ConnectionScreen?
        for attempt in 0..<20 {
            let inventory = try await backend.read(remembered: checkpoint.remembered)
            screens = inventory.map { item in
                var item = item
                item.verified = checkpoint.verifiedIdentities[item.identity] == Self.osBuild
                return item
            }
            let matches = screens.filter { $0.identity == expected.identity }
            guard matches.count == 1, let screen = matches.first, screen.binding == expected.binding else { throw ConnectionFailure.refused("Display identity changed while Pilot was changing it") }
            if screen.state == state { return screen }
            last = screen
            if attempt < 19 { await settle() }
        }
        throw ConnectionFailure.refused("macOS did not observe \(expected.name) \(state.rawValue) (last \(last?.state.rawValue ?? "missing"))")
    }

    private func requireSurvivor(excluding identity: String) async throws {
        let inventory = try await backend.read(remembered: checkpoint.remembered)
        guard Set(inventory.filter { $0.identity != identity && $0.supported && $0.state == .on && !$0.asleep }.map(\.identity)).count > 0 else {
            throw ConnectionFailure.refused("macOS left no awake usable display")
        }
    }

    private func refreshInventory() async throws {
        let inventory = try await backend.read(remembered: checkpoint.remembered)
        screens = inventory.map { item in
            var item = item
            item.verified = checkpoint.verifiedIdentities[item.identity] == Self.osBuild
            return item
        }
        checkpoint.remembered = screens
    }

    private func verifyLayout(_ expected: [ConnectionScreen], excluding: Set<String>) async throws {
        guard !expected.isEmpty else { return }
        let required = expected.filter { $0.state == .on && !excluding.contains($0.identity) }
        guard !required.isEmpty else { return }
        for attempt in 0..<20 {
            let inventory = try await backend.read(remembered: checkpoint.remembered)
            let restored = required.allSatisfy { saved in
                guard let actual = inventory.first(where: { $0.identity == saved.identity && $0.location == saved.location }),
                      actual.state == .on, actual.main == saved.main, actual.rotation == saved.rotation,
                      actual.mode.size == saved.mode.size, actual.mode.pixelWidth == saved.mode.pixelWidth,
                      abs(actual.mode.refresh - saved.mode.refresh) < 0.5,
                      abs(actual.frame.origin.x - saved.frame.origin.x) < 1,
                      abs(actual.frame.origin.y - saved.frame.origin.y) < 1 else { return false }
                return inventory.filter { $0.identity == saved.identity }.count == 1
            }
            if restored { return }
            if attempt < 19 { await settle() }
        }
        throw ConnectionFailure.refused("macOS did not restore the saved display layout")
    }

    private func read() async throws {
        let fresh = try await backend.read(remembered: checkpoint.remembered)
        let observed = fresh.map { screen in
            var screen = screen
            screen.verified = checkpoint.verifiedIdentities[screen.identity] == Self.osBuild
            return screen
        }
        // Persist only observed layouts. This leaves an off screen in the checkpoint until the native layer confirms on.
        // A corrupt/unreadable store is fail-closed: refresh may show no stale state, but never replaces it.
        if let loadFailure { throw loadFailure }
        var saved = checkpoint
        saved.remembered = observed
        do { try store.save(saved) }
        catch {
            storeFailure = error
            throw error
        }
        checkpoint = saved
        screens = observed
        storeFailure = nil
        problem = nil
    }

    private func saveCheckpoint() throws {
        if let loadFailure { throw loadFailure }
        do { try store.save(checkpoint) }
        catch {
            storeFailure = error
            throw error
        }
        storeFailure = nil
    }

    private func rollback(_ target: ConnectionScreen?, layout: [ConnectionScreen]? = nil) async -> String? {
        guard let target else { return "display disappeared" }
        let screen = screens.first(where: { $0.binding == target.binding }) ?? target
        do {
            try await backend.setEnabled(true, screen: screen)
            _ = try await observed(screen, state: .on)
            let layout = layout ?? (checkpoint.recoveryLayout.isEmpty ? [screen] : checkpoint.recoveryLayout)
            try await backend.restoreLayout(layout)
            try await verifyLayout(layout, excluding: checkpoint.managedOffIdentities)
            try await read()
            return nil
        } catch { return error.localizedDescription }
    }

    private func fail(_ error: Error) {
        problem = error.localizedDescription
        slog.error("display connection: \(error.localizedDescription, privacy: .public)")
    }

    private func markUnknown() {
        screens = screens.map { screen in
            var screen = screen
            screen.state = .unknown
            return screen
        }
    }
}
