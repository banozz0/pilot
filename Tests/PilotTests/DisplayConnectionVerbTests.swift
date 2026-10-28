import CoreGraphics
import Foundation
import PilotCore
import Testing
@testable import Pilot

@MainActor
@Suite("Display connection command")
struct DisplayConnectionVerbTests {
    static let mode = DisplayMode(id: 1, width: 1920, height: 1080, pixelWidth: 1920, refresh: 60)

    static func screen(_ id: UInt32, _ name: String, _ identity: String, state: ConnectionState = .on, main: Bool = false) -> ConnectionScreen {
        ConnectionScreen(id: id, name: name, identity: identity, state: state, main: main, builtIn: false, asleep: false,
                         frame: .init(x: 0, y: 0, width: 1920, height: 1080), mode: mode, rotation: 0, supported: true)
    }

    final class Store: DisplayConnectionsStore {
        var value = DisplayConnectionsCheckpoint()
        func load() throws -> DisplayConnectionsCheckpoint { value }
        func save(_ checkpoint: DisplayConnectionsCheckpoint) throws { value = checkpoint }
    }

    final class Hardware: DisplayConnectionsBackend, @unchecked Sendable {
        var screens: [ConnectionScreen]
        var calls: [(Bool, UInt32)] = []
        var failEnable = false
        init(_ screens: [ConnectionScreen]) { self.screens = screens }
        func read(remembered: [ConnectionScreen]) async throws -> [ConnectionScreen] { screens }
        func setEnabled(_ enabled: Bool, screen: ConnectionScreen) async throws {
            calls.append((enabled, screen.id))
            if failEnable { throw ConnectionFailure.refused("native recovery failed") }
            screens[screens.firstIndex { $0.id == screen.id && $0.identity == screen.identity }!].state = enabled ? .on : .off
        }
        func restoreLayout(_ screens: [ConnectionScreen]) async throws {}
    }

    @MainActor final class Rig {
        let hardware: Hardware
        let store: Store
        let connections: DisplayConnections
        let system = ControlSystem()
        let verbs = ControlVerbs()

        init(_ connectionScreens: [ConnectionScreen] = [screen(1, "CU34G4Z", "wide", main: true), screen(2, "24G1WG4", "portrait")],
             store: Store? = nil, hardware: Hardware? = nil) {
            self.store = store ?? Store()
            self.hardware = hardware ?? Hardware(connectionScreens)
            connections = DisplayConnections(backend: self.hardware, store: self.store)
            let displays = SetupDisplays(system: SetupDisplaysTests.FakeDisplays(), connections: connections)
            system.displays = { displays }
            system.brightness = { nil }
            verbs.registerSystem(system)
        }

        func ask(_ args: String...) async -> ControlAnswer { await verbs.answer(.init(verb: "system", args: args), peer: nil) }
    }

    static func path(_ value: JSONValue?, _ keys: String...) -> JSONValue? {
        keys.reduce(value) { value, key in
            switch value {
            case .object(let object)?: object[key]
            case .array(let values)?: Int(key).flatMap { values.indices.contains($0) ? values[$0] : nil }
            default: nil
            }
        }
    }

    @Test("Connections report independent state, require a test before OFF, then verify the resulting state")
    func testThenDisconnect() async {
        let rig = Rig()
        let read = await rig.ask("displays")
        #expect(Self.path(read.result, "connections", "0", "state") == .string("on"))
        #expect(Self.path(read.result, "connections", "0", "supported") == .bool(true))
        #expect(Self.path(read.result, "screens", "0", "brightness") == nil, "DDC evidence remains separate from connection state")

        #expect(await rig.ask("display", "24G1WG4", "--connected", "off").error?.message.contains("Validate") == true)
        let tested = await rig.ask("display", "portrait", "--test-connection")
        #expect(tested.error == nil && Self.path(tested.result, "connections", "1", "verified") == .bool(true))
        let off = await rig.ask("display", "2", "--connected", "off")
        #expect(off.error == nil && Self.path(off.result, "connections", "1", "state") == .string("off"))
        #expect(rig.hardware.calls.map(\.0) == [false, true, false])
    }

    @Test("Connection commands reject ambiguous names and mixed display-mode flags")
    func rejectsAmbiguityAndMixedFlags() async {
        let rig = Rig([Self.screen(1, "Same", "one", main: true), Self.screen(2, "Same", "two")])
        #expect(await rig.ask("display", "Same", "--test-connection").error?.message.contains("more than one") == true)
        #expect(await rig.ask("display", "1", "--connected", "off", "--brightness", "50").error?.code == .unknownFlag)
    }

    @Test("Selecting an absent physical display never mutates a replacement sharing its raw ID", arguments: ["off", "on", "test"])
    func absentSelectionCannotMutateReplacement(action: String) async {
        let replacement = Self.screen(2, "Replacement", "replacement", state: action == "on" ? .off : .on)
        let absent = Self.screen(2, "Absent", "absent", state: .unavailable)
        let store = Store()
        store.value.verifiedIdentities[replacement.identity] = ProcessInfo.processInfo.operatingSystemVersionString
        let rig = Rig([Self.screen(1, "Main", "main", main: true), replacement, absent], store: store)
        let args = ["display", "absent"] + (action == "test" ? ["--test-connection"] : ["--connected", action])
        let answer = await rig.verbs.answer(.init(verb: "system", args: args), peer: nil)
        #expect(answer.error != nil)
        #expect(rig.hardware.calls.isEmpty)
        #expect(rig.hardware.screens[1].state == replacement.state)
        #expect(rig.hardware.screens[2].state == .unavailable)
    }

    @Test("A stable identity survives a fresh controller, and a failed Restore All returns its recovery error")
    func restartRecoveryAndRestoreFailure() async {
        let rig = Rig()
        _ = await rig.ask("display", "portrait", "--test-connection")
        _ = await rig.ask("display", "portrait", "--connected", "off")

        let restarted = Rig(store: rig.store, hardware: rig.hardware)
        let afterRestart = await restarted.ask("displays")
        #expect(Self.path(afterRestart.result, "connections", "1", "identity") == .string("portrait"))
        #expect(Self.path(afterRestart.result, "connections", "1", "state") == .string("off"))

        rig.hardware.failEnable = true
        let restore = await restarted.ask("display", "restore-all")
        #expect(restore.error?.message.contains("native recovery failed") == true)
    }
}
