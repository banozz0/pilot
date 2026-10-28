import CoreGraphics
import Testing
@testable import Pilot

@MainActor
@Suite("Display connection recovery")
struct DisplayConnectionRecoveryTests {
    static let mode = DisplayMode(id: 1, width: 1920, height: 1080, pixelWidth: 1920, refresh: 60)
    static func screen(_ id: UInt32, _ name: String, main: Bool = false) -> ConnectionScreen {
        ConnectionScreen(id: id, name: name, identity: name, state: .on, main: main, builtIn: false, asleep: false,
                         frame: CGRect(x: main ? 0 : 1920, y: 0, width: 1920, height: 1080), mode: mode, rotation: 0,
                         location: "IOService:/\(name)", supported: true)
    }

    final class Store: DisplayConnectionsStore {
        var checkpoint = DisplayConnectionsCheckpoint()
        var fail = false
        var corrupt = false
        func load() throws -> DisplayConnectionsCheckpoint {
            if corrupt { throw ConnectionFailure.unsupported("corrupt checkpoint") }
            return checkpoint
        }
        func save(_ checkpoint: DisplayConnectionsCheckpoint) throws {
            if fail { throw ConnectionFailure.refused("disk full") }
            self.checkpoint = checkpoint
        }
    }

    final class PhysicalState: @unchecked Sendable { var screens: [ConnectionScreen]; init(_ screens: [ConnectionScreen]) { self.screens = screens } }

    final class Hardware: DisplayConnectionsBackend, @unchecked Sendable {
        let state: PhysicalState
        var screens: [ConnectionScreen] { get { state.screens } set { state.screens = newValue } }
        var calls: [String] = []
        var ignoreChanges = false
        var failEnable = false
        var failIdentities = Set<String>()
        var delayedReads = 0
        var stale: [ConnectionScreen] = []
        init(_ state: PhysicalState) { self.state = state }
        func read(remembered: [ConnectionScreen]) async throws -> [ConnectionScreen] {
            if delayedReads > 0 { delayedReads -= 1; return stale }
            return screens
        }
        func setEnabled(_ enabled: Bool, screen: ConnectionScreen) async throws {
            calls.append("\(enabled):\(screen.identity)")
            if failEnable || failIdentities.contains(screen.identity) { throw ConnectionFailure.refused("native failed") }
            if ignoreChanges { return }
            guard let i = screens.firstIndex(where: { $0.identity == screen.identity }) else { throw ConnectionFailure.refused("missing") }
            stale = screens
            screens[i].state = enabled ? .on : .off
            if !enabled, let main = screens.firstIndex(where: { $0.main }), main == i,
               let survivor = screens.indices.first(where: { screens[$0].state == .on }) {
                screens[main] = Self.with(screens[main], main: false)
                screens[survivor] = Self.with(screens[survivor], main: true)
            }
        }
        func restoreLayout(_ layout: [ConnectionScreen]) async throws {
            calls.append("restore")
            for saved in layout where saved.state == .on {
                guard let i = screens.firstIndex(where: { $0.binding == saved.binding && $0.state == .on }) else { continue }
                screens[i] = saved
            }
        }
        static func with(_ s: ConnectionScreen, main: Bool) -> ConnectionScreen {
            ConnectionScreen(id: s.id, name: s.name, identity: s.identity, state: s.state, main: main, builtIn: s.builtIn, asleep: s.asleep, frame: s.frame, mode: s.mode, rotation: s.rotation, verified: s.verified, location: s.location, supported: s.supported)
        }
    }

    @Test("fresh adapter recovers an OFF screen and restores original primary layout")
    func freshRecoveryRestoresLayout() async {
        let state = PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")])
        let store = Store(), first = Hardware(state), fresh = Hardware(state)
        let model = DisplayConnections(backend: first, store: store, makeBackend: { fresh }, settle: {})
        await model.refresh(); await model.validateConnection(id: 1); await model.setConnected(false, id: 1)
        #expect(first.screens.first { $0.identity == "A" }?.state == .off)
        #expect(first.screens.first { $0.identity == "B" }?.main == true)
        let reopenedHardware = Hardware(state)
        let reopened = DisplayConnections(backend: reopenedHardware, store: store, makeBackend: { Hardware(state) }, settle: {})
        await reopened.refresh(); await reopened.setConnected(true, id: 1)
        #expect(reopenedHardware.screens.first { $0.identity == "A" }?.main == true)
        #expect(reopenedHardware.screens.first { $0.identity == "B" }?.state == .on)
        #expect(reopenedHardware.calls.contains("true:A"))
    }

    @Test("Originally inactive remembered rows do not prevent active-layout recovery", arguments: [ConnectionState.off, .unavailable, .unknown])
    func inactiveRowsDoNotBlockRecovery(inactive: ConnectionState) async throws {
        var absent = Self.screen(3, "Absent")
        absent.state = inactive
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B"), absent]))
        let store = Store(), model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.refresh()
        await model.validateConnection(id: 2)
        try #require(model.problem == nil)
        #expect(model.screens[1].verified)
        await model.setConnected(false, id: 2)
        try #require(model.problem == nil)
        await model.setConnected(true, id: 2)
        try #require(model.problem == nil)
        #expect(store.checkpoint.recoveryLayout.isEmpty && store.checkpoint.managedOffIdentities.isEmpty)
        await model.setConnected(false, id: 2)
        try #require(model.problem == nil)
        await model.restoreAll()
        #expect(model.problem == nil)
        #expect(hardware.screens[0].main && hardware.screens[1].state == .on)
        #expect(hardware.screens[2] == absent)
        #expect(store.checkpoint.recoveryLayout.isEmpty && store.checkpoint.managedOffIdentities.isEmpty)
    }

    @Test("Physical selection survives raw ID churn but refuses a different port", arguments: [false, true])
    func selectionStaysBoundToPhysicalPort(relocated: Bool) async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")]))
        let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh()
        let selected = model.screens[1]
        hardware.screens[1] = ConnectionScreen(id: relocated ? 2 : 7, name: selected.name, identity: selected.identity,
            state: .on, main: false, builtIn: false, asleep: false, frame: selected.frame, mode: selected.mode,
            rotation: selected.rotation, location: relocated ? "IOService:/replacement" : selected.location, supported: true)
        await model.validateConnection(id: selected.id, binding: selected.binding)
        if relocated {
            #expect(hardware.calls.isEmpty)
            #expect(model.problem?.contains("identity changed") == true)
        } else {
            #expect(model.problem == nil)
            #expect(hardware.calls == ["false:B", "true:B", "restore"])
            #expect(model.screens[1].id == 7 && model.screens[1].verified)
        }
    }

    @Test("Calibration preserves another managed-OFF display and its original recovery layout", arguments: [false, true])
    func calibrationPreservesManagedOffLayout(managedPrimary: Bool) async throws {
        let original = [Self.screen(1, "A", main: !managedPrimary), Self.screen(2, "B", main: managedPrimary), Self.screen(3, "C")]
        let hardware = Hardware(PhysicalState(original)), store = Store()
        let model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2)
        try #require(model.problem == nil)
        await model.setConnected(false, id: 2)
        try #require(model.problem == nil)
        let baseline = store.checkpoint.recoveryLayout
        hardware.calls.removeAll()
        await model.validateConnection(id: 3)
        #expect(model.problem == nil)
        #expect(model.screens.first { $0.identity == "C" }?.verified == true)
        #expect(hardware.screens[1].state == .off)
        #expect(hardware.screens[0].main)
        #expect(hardware.calls == ["false:C", "true:C", "restore"])
        #expect(store.checkpoint.managedOffIdentities == Set(["B"]))
        #expect(store.checkpoint.recoveryLayout == baseline)
        await model.setConnected(true, id: 2)
        #expect(model.problem == nil)
        #expect(hardware.screens.map(\.main) == original.map(\.main))
        #expect(hardware.screens.map(\.frame) == original.map(\.frame))
        #expect(hardware.screens.allSatisfy { $0.state == .on })
        #expect(store.checkpoint.recoveryLayout.isEmpty && store.checkpoint.managedOffIdentities.isEmpty)
    }

    @Test("Failed calibration restores the active arrangement without enabling another managed-OFF display")
    func failedCalibrationPreservesActiveLayout() async throws {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A"), Self.screen(2, "B", main: true), Self.screen(3, "C")]))
        let store = Store(), model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2); await model.setConnected(false, id: 2)
        try #require(model.problem == nil)
        let baseline = store.checkpoint.recoveryLayout
        hardware.ignoreChanges = true
        await model.validateConnection(id: 3)
        #expect(model.problem?.contains("did not observe") == true)
        #expect(model.problem?.contains("rollback failed") == false)
        #expect(hardware.screens[0].main && hardware.screens[1].state == .off)
        #expect(store.checkpoint.recoveryLayout == baseline)
        #expect(store.checkpoint.managedOffIdentities.contains("B"))
    }

    @Test("checkpoint save failure makes no private OFF call")
    func saveFailureDoesNotDisconnect() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")])), store = Store()
        let model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2)
        hardware.calls.removeAll(); store.fail = true
        await model.setConnected(false, id: 2)
        #expect(hardware.calls.isEmpty)
        #expect(model.problem?.contains("disk full") == true)
    }

    @Test("no-op OFF is observed, rolled back, and never certified")
    func noOpOffRollsBack() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")]))
        let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2)
        hardware.ignoreChanges = true; hardware.calls.removeAll()
        await model.setConnected(false, id: 2)
        #expect(hardware.calls.first == "false:B")
        #expect(model.problem?.contains("did not observe") == true)
    }

    @Test("duplicate durable identity refuses the operation before OFF")
    func duplicateIdentityRefused() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "same", main: true), Self.screen(2, "same"), Self.screen(3, "C")]))
        let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 1)
        #expect(hardware.calls.isEmpty)
        #expect(model.problem?.contains("Duplicate display identity") == true)
    }

    @Test("Restore All tries later OFF screens after an earlier enable failure")
    func restoreAllContinues() async {
        let state = PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B"), Self.screen(3, "C")])
        let hardware = Hardware(state), store = Store()
        store.checkpoint = DisplayConnectionsCheckpoint(remembered: [Self.screen(1, "A", main: true), ConnectionScreen(id: 2, name: "B", identity: "B", state: .off, main: false, builtIn: false, asleep: false, frame: .zero, mode: Self.mode, rotation: 0, location: "IOService:/B", supported: true), ConnectionScreen(id: 3, name: "C", identity: "C", state: .off, main: false, builtIn: false, asleep: false, frame: .zero, mode: Self.mode, rotation: 0, location: "IOService:/C", supported: true)], recoveryLayout: [Self.screen(1, "A", main: true), Self.screen(2, "B"), Self.screen(3, "C")], managedOffIdentities: ["B", "C"])
        state.screens[1].state = .off; state.screens[2].state = .off
        hardware.failIdentities = ["B"]
        let model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.restoreAll()
        #expect(hardware.calls.contains("true:B") && hardware.calls.contains("true:C"))
        #expect(state.screens[1].state == .off && state.screens[2].state == .on)
        #expect(store.checkpoint.managedOffIdentities == Set(["B", "C"]))
    }

    @Test("corrupt checkpoint never reaches native OFF")
    func corruptCheckpointFailsClosed() async {
        let store = Store(); store.corrupt = true
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")]))
        let model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.setConnected(false, id: 2)
        #expect(hardware.calls.isEmpty)
        #expect(model.problem?.contains("corrupt checkpoint") == true)
    }

    @Test("two managed OFF screens retain their original baseline until both return")
    func multipleOffKeepsBaseline() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B"), Self.screen(3, "C")]))
        let store = Store(), model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2); await model.validateConnection(id: 3)
        await model.setConnected(false, id: 2); await model.setConnected(false, id: 3)
        await model.setConnected(true, id: 2)
        #expect(store.checkpoint.managedOffIdentities == Set(["C"]))
        #expect(!store.checkpoint.recoveryLayout.isEmpty)
    }

    @Test("queued OFF requests leave an awake survivor")
    func queuedOffKeepsSurvivor() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B"), Self.screen(3, "C")]))
        let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2); await model.validateConnection(id: 3)
        async let first: Void = model.setConnected(false, id: 2)
        async let second: Void = model.setConnected(false, id: 3)
        async let third: Void = model.setConnected(false, id: 1)
        _ = await (first, second, third)
        #expect(hardware.screens.filter { $0.state == .on }.count >= 1)
    }

    @Test("last display is refused before any private call")
    func lastDisplayRefused() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true)]))
        let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 1)
        #expect(hardware.calls.isEmpty)
        #expect(model.problem?.contains("last awake") == true)
    }

    @Test("an asleep target is refused before any private call")
    func asleepTargetRefused() async {
        let state = PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")])
        state.screens[1] = ConnectionScreen(id: 2, name: "B", identity: "B", state: .on, main: false, builtIn: false, asleep: true, frame: state.screens[1].frame, mode: Self.mode, rotation: 0, location: "IOService:/B", supported: true)
        let hardware = Hardware(state), model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2)
        #expect(hardware.calls.isEmpty)
        #expect(model.problem?.contains("not awake") == true)
    }

    @Test("Unknown and unavailable targets fail before a native call")
    func unavailableTargetsRefused() async {
        for state in [ConnectionState.unknown, .unavailable] {
            let target = ConnectionScreen(id: 2, name: "B", identity: "B", state: state, main: false, builtIn: false, asleep: false,
                                          frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), mode: Self.mode, rotation: 0,
                                          location: "IOService:/B", supported: true)
            let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), target]))
            let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
            await model.refresh(); await model.setConnected(true, id: 2)
            #expect(hardware.calls.isEmpty)
            #expect(model.problem?.contains("unavailable") == true)
        }
    }

    @Test("Restore All is idempotent when no managed recovery exists")
    func emptyRestoreAllDoesNotCallNative() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")]))
        let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.setConnected(true, id: 2)
        #expect(model.problem?.contains("already on") == true)
        hardware.calls.removeAll()
        await model.restoreAll()
        #expect(hardware.calls.isEmpty)
        #expect(model.problem == nil)
        #expect(model.screens.allSatisfy { $0.state == .on })
    }

    @Test("delayed reconfiguration readback waits for the observed OFF state")
    func delayedReadbackSettles() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")]))
        let model = DisplayConnections(backend: hardware, store: Store(), makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2)
        hardware.delayedReads = 2
        await model.setConnected(false, id: 2)
        #expect(model.screens.first { $0.identity == "B" }?.state == .off)
    }

    @Test("rollback failure keeps durable managed-OFF baseline and reports both failures")
    func rollbackFailureRetainsBaseline() async {
        let hardware = Hardware(PhysicalState([Self.screen(1, "A", main: true), Self.screen(2, "B")]))
        let store = Store(), model = DisplayConnections(backend: hardware, store: store, makeBackend: { hardware }, settle: {})
        await model.refresh(); await model.validateConnection(id: 2)
        hardware.ignoreChanges = true; hardware.failIdentities = ["B"]
        await model.setConnected(false, id: 2)
        #expect(model.problem?.contains("rollback failed") == true)
        #expect(store.checkpoint.managedOffIdentities.contains("B"))
        #expect(!store.checkpoint.recoveryLayout.isEmpty)
    }

    @Test("native binding allows absent disabled IDs only for explicit ON")
    func bindingPredicateFailsClosed() {
        #expect(NativeDisplayConnections.allowsMutation(enable: true, rawIDIsOnline: false, currentBindingMatches: false))
        #expect(!NativeDisplayConnections.allowsMutation(enable: false, rawIDIsOnline: false, currentBindingMatches: false))
        #expect(!NativeDisplayConnections.allowsMutation(enable: true, rawIDIsOnline: true, currentBindingMatches: false))
        #expect(NativeDisplayConnections.allowsMutation(enable: false, rawIDIsOnline: true, currentBindingMatches: true))
    }
}
