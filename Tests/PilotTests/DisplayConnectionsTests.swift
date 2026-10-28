import CoreGraphics
import Foundation
import Testing
@testable import Pilot

@MainActor
@Suite("Display connections")
struct DisplayConnectionsTests {
    static let mode = DisplayMode(id: 1, width: 1920, height: 1080, pixelWidth: 1920, refresh: 60)
    static func screen(_ id: UInt32, _ identity: String, state: ConnectionState = .on, main: Bool = false) -> ConnectionScreen {
        ConnectionScreen(id: id, name: identity, identity: identity, state: state, main: main, builtIn: false, asleep: false,
                         frame: CGRect(x: Int(id) * 100, y: 0, width: 1920, height: 1080), mode: mode, rotation: 0, supported: true)
    }

    final class Store: DisplayConnectionsStore {
        var value = DisplayConnectionsCheckpoint()
        var failSaves = false
        func load() throws -> DisplayConnectionsCheckpoint { value }
        func save(_ checkpoint: DisplayConnectionsCheckpoint) throws {
            if failSaves { throw ConnectionFailure.refused("disk full") }
            value = checkpoint
        }
    }

    final class Hardware: DisplayConnectionsBackend, @unchecked Sendable {
        var screens: [ConnectionScreen]
        var calls: [(Bool, UInt32)] = []
        var failEnable = false
        var ignoreChanges = false
        init(_ screens: [ConnectionScreen]) { self.screens = screens }
        func read(remembered: [ConnectionScreen]) async throws -> [ConnectionScreen] { screens }
        func setEnabled(_ enabled: Bool, screen: ConnectionScreen) async throws {
            calls.append((enabled, screen.id))
            if failEnable { throw ConnectionFailure.refused("native failed") }
            guard !ignoreChanges, let index = screens.firstIndex(where: { $0.id == screen.id && $0.identity == screen.identity && $0.location == screen.location }) else { return }
            screens[index].state = enabled ? .on : .off
        }
        func restoreLayout(_ screens: [ConnectionScreen]) async throws {}
    }

    func rig(_ screens: [ConnectionScreen] = [screen(1, "A", main: true), screen(2, "B")]) -> (Hardware, Store, DisplayConnections) {
        let hardware = Hardware(screens), store = Store()
        return (hardware, store, DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {}))
    }

    @Test("Validation round trip certifies identity and OFF removes desktop membership")
    func disconnectsAfterValidation() async {
        let (hardware, store, model) = rig()
        await model.refresh(); await model.validateConnection(id: 2); await model.setConnected(false, id: 2)
        #expect(model.screens.first { $0.id == 2 }?.state == .off)
        #expect(hardware.calls.map(\.0) == [false, true, false])
        #expect(store.value.verifiedIdentities["B"] != nil)
    }

    @Test("Last awake display, stale identity, no-op and failed operations are refused and rolled back")
    func protectsDesktopAndRollsBack() async {
        let (hardware, _, model) = rig([Self.screen(1, "A", main: true)])
        await model.refresh(); await model.validateConnection(id: 1)
        #expect(model.problem?.contains("last awake") == true)
        hardware.screens = [Self.screen(1, "replacement", main: true), Self.screen(2, "B")]
        await model.setConnected(false, id: 1)
        #expect(model.problem?.contains("identity changed") == true)
        hardware.ignoreChanges = true
        await model.refresh(); await model.validateConnection(id: 2)
        #expect(model.problem != nil && hardware.screens[1].state == .on)
    }

    @Test("Saved OFF survives reconstruction; ON restores layout and Restore All retains failed recovery")
    func recoversAcrossControllers() async {
        let (hardware, store, first) = rig()
        await first.refresh(); await first.validateConnection(id: 2); await first.setConnected(false, id: 2)
        let reopened = DisplayConnections(backend: hardware, store: store)
        await reopened.refresh()
        #expect(reopened.screens.first { $0.id == 2 }?.state == .off)
        hardware.failEnable = true
        await reopened.restoreAll()
        #expect(store.value.remembered.first { $0.identity == "B" }?.state == .off)
        hardware.failEnable = false
        await reopened.setConnected(true, id: 2)
        #expect(reopened.screens.first { $0.id == 2 }?.state == .on)
    }

    @Test("Persistence failure happens before native mutation")
    func failsClosedWhenCheckpointCannotSave() async {
        let (hardware, store, model) = rig()
        await model.refresh(); await model.validateConnection(id: 2)
        store.failSaves = true; hardware.calls.removeAll()
        await model.setConnected(false, id: 2)
        #expect(hardware.calls.isEmpty && model.problem?.contains("disk full") == true)
    }

    @Test("Only a captured visible window is rescued after its display leaves")
    func rescuesCapturedVisibleWindowOnly() async {
        let (hardware, store, _) = rig()
        var moved: [CGRect] = []
        var captured = true
        let visible = DisplayConnectionWindowMigration.Window(frame: { captured ? CGRect(x: -9_000, y: 0, width: 600, height: 400) : nil }, move: { moved.append($0) })
        let hidden = DisplayConnectionWindowMigration.Window(frame: { CGRect(x: -9_000, y: 0, width: 600, height: 400) }, move: { moved.append($0) })
        let migration = DisplayConnectionWindowMigration(capture: { _ in captured ? [visible] : [hidden] })
        let model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {}, windowMigration: migration)
        await model.refresh(); await model.validateConnection(id: 2)
        await model.setConnected(false, id: 2)
        #expect(moved.count == 1)
        captured = false
        #expect(moved.count == 1)
    }

    @Test("Window capture accepts only a frame visible on an active display")
    func capturesVisibleFrameOnly() {
        let active = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(DisplayConnectionWindowMigration.captures(CGRect(x: 100, y: 100, width: 300, height: 200), windowID: 10, onScreenIDs: [10], in: [active]))
        #expect(!DisplayConnectionWindowMigration.captures(CGRect(x: 100, y: 100, width: 300, height: 200), windowID: 11, onScreenIDs: [10], in: [active]))
        #expect(!DisplayConnectionWindowMigration.captures(CGRect(x: -9_000, y: 0, width: 300, height: 200), windowID: 10, onScreenIDs: [10], in: [active]))
    }

    @Test("Reconnected physical binding replaces a remembered row with incomplete metadata", arguments: [UInt32(2), UInt32(7)])
    func reconnectDropsPhantomRow(liveID: UInt32) async {
        let location = "IOService:/primary"
        let primary = ConnectionScreen(id: liveID, name: "CU34G4Z", identity: "1507:46104:1010101:serial:64", state: .on,
            main: true, builtIn: false, asleep: false, frame: .zero, mode: Self.mode, rotation: 0, location: location, supported: true)
        let phantom = ConnectionScreen(id: 2, name: "Display 2", identity: "-:-:-:-:-", state: .unavailable,
            main: false, builtIn: false, asleep: false, frame: .zero, mode: Self.mode, rotation: 0, location: location)
        let live = [primary, Self.screen(3, "secondary")]
        let remembered = [primary, live[1], phantom]
        let hardware = Hardware(live + NativeDisplayConnections.missingScreens(live: live, remembered: remembered))
        let store = Store()
        store.value.remembered = remembered
        store.value.recoveryLayout = live
        store.value.verifiedIdentities[primary.identity] = ProcessInfo.processInfo.operatingSystemVersionString
        let model = DisplayConnections(backend: hardware, store: store)
        await model.refresh()
        #expect(model.screens.map(\.identity) == live.map(\.identity))
        #expect(store.value.remembered.count == 2)
        #expect(store.value.recoveryLayout == live)
        #expect(!model.validationNeeded(primary))
        #expect(hardware.calls.isEmpty)
        #expect(NativeDisplayConnections.missingScreens(live: [phantom], remembered: [primary]).isEmpty)
    }

    @Test("Reconciliation keeps an absent monitor even when another physical binding reuses its raw ID")
    func missingBindingKeepsRecovery() {
        let saved = DisplayConnectionRecoveryTests.screen(2, "absent")
        let replacement = DisplayConnectionRecoveryTests.screen(2, "replacement")
        #expect(NativeDisplayConnections.missingScreens(live: [replacement], remembered: [saved]) == [saved])
        #expect(NativeDisplayConnections.missingScreens(live: [], remembered: [saved]) == [saved])
    }

    @Test("A remembered display with no registry location is forgotten once it leaves (Display 12, build 52)")
    func locationlessRememberedRowIsDropped() {
        // A virtual output (headless fallback, Sidecar, AirPlay, an app's virtual display) has no IODisplayLocation and
        // no EDID identity, so it can never be reconnected; once it leaves it is not a row.
        let virtual = ConnectionScreen(id: 12, name: "Display 12", identity: "-:-:-:-:-", state: .unknown, main: false,
            builtIn: false, asleep: false, frame: .zero, mode: Self.mode, rotation: 0)
        let absent = DisplayConnectionRecoveryTests.screen(4, "absent")
        let live = [DisplayConnectionRecoveryTests.screen(2, "primary", main: true)]
        #expect(NativeDisplayConnections.missingScreens(live: live, remembered: live + [virtual, absent]) == [absent])
    }

    @Test("Live inventory is read-only", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveInventory() async throws {
        let remembered = try FileDisplayConnectionsStore().load().remembered
        let screens = try await NativeDisplayConnections().read(remembered: remembered)
        for screen in screens {
            print("display inventory name=\(screen.name) id=\(screen.id) state=\(screen.state.rawValue) asleep=\(screen.asleep) supported=\(screen.supported) hasLocation=\(screen.location != nil)")
        }
        #expect(!screens.isEmpty)
        let locations = screens.compactMap(\.location)
        #expect(Set(locations).count == locations.count)
        #expect(screens.allSatisfy { !$0.name.isEmpty && !$0.identity.isEmpty })
        #expect(screens.allSatisfy { $0.supported || $0.state == .unknown || $0.state == .unavailable })
        #expect(screens.filter(\.supported).allSatisfy { !$0.name.hasPrefix("Display ") && $0.location != nil && !$0.identity.isEmpty })
    }
}
