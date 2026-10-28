import Foundation
import PilotCore
import Testing
@testable import Pilot

@MainActor
@Suite("Display nicknames")
struct DisplayNicknameTests {
    static let wideUUID = "A5A40000-0000-0000-0000-000000000001"
    static let portraitUUID = "A5A40000-0000-0000-0000-000000000002"

    @MainActor final class Rig {
        let screens = SetupDisplaysTests.FakeDisplays()
        let hardware: DisplayConnectionVerbTests.Hardware
        let displays: SetupDisplays
        let verbs = ControlVerbs()

        init(defaults: UserDefaults, ids: [UInt32] = [1, 2], uuids: [String?] = [wideUUID, portraitUUID]) {
            screens.screens = screens.screens.enumerated().map { index, old in
                DisplayInfo(id: ids[index], name: old.name, main: old.main, frame: old.frame, mode: old.mode,
                            rotation: old.rotation, displayUUID: uuids[index])
            }
            hardware = DisplayConnectionVerbTests.Hardware(screens.screens.enumerated().map { index, info in
                ConnectionScreen(id: info.id, name: info.name, identity: "physical-\(index)", state: .on,
                                 main: info.main, builtIn: false, asleep: false, frame: info.frame, mode: info.mode,
                                 rotation: info.rotation, location: "port-\(index)", supported: true, displayUUID: info.displayUUID)
            })
            let connections = DisplayConnections(backend: hardware, store: DisplayConnectionVerbTests.Store())
            displays = SetupDisplays(system: screens, connections: connections, nicknames: DisplayNicknames(defaults: defaults))
            let system = ControlSystem(), displays = displays
            system.displays = { displays }
            system.brightness = { nil }
            verbs.registerSystem(system)
        }

        func ask(_ args: String...) async -> ControlAnswer { await verbs.answer(.init(verb: "system", args: args), peer: nil) }
    }

    @Test("The display command accepts an arbitrary personal name without changing hardware")
    func renameThroughCommand() async {
        let rig = Rig(defaults: .pilot())
        let original = rig.hardware.screens
        let answer = await rig.ask("display", "1", "--name", "Desk — café 🖥️")
        #expect(answer.error == nil)
        #expect(DisplayConnectionVerbTests.path(answer.result, "screens", "0", "label") == .string("Desk — café 🖥️"))
        #expect(DisplayConnectionVerbTests.path(answer.result, "screens", "0", "name") == .string("CU34G4Z"))
        #expect(rig.hardware.calls.isEmpty)
        #expect(rig.hardware.screens == original && rig.screens.applied.isEmpty)
        #expect(DisplayConnectionVerbTests.path(answer.result, "connections", "0", "label") == .string("Desk — café 🖥️"))
        #expect(DisplayConnectionVerbTests.path(answer.result, "screens", "1", "label") == .string("24G1WG4"))
    }

    @Test("A recreated settings store follows the physical UUID when session IDs change or are reused")
    func restartAndReconnect() async {
        let suite = testSuite()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("untouched", forKey: "another-setting")
        let first = Rig(defaults: defaults)
        #expect(await first.ask("display", "1", "--name", "  Desk café 🖥️  ").error == nil)
        #expect(defaults.synchronize())

        let reopened = Rig(defaults: UserDefaults(suiteName: suite)!, ids: [41, 1])
        let read = await reopened.ask("displays")
        #expect(DisplayConnectionVerbTests.path(read.result, "screens", "0", "label") == .string("  Desk café 🖥️  "))
        #expect(DisplayConnectionVerbTests.path(read.result, "screens", "1", "label") == .string("24G1WG4"))
        #expect(DisplayConnectionVerbTests.path(read.result, "connections", "0", "identity") == .string("physical-0"))
        #expect(defaults.string(forKey: "another-setting") == "untouched")
        let anotherUser = Rig(defaults: .pilot())
        #expect(DisplayConnectionVerbTests.path((await anotherUser.ask("displays")).result, "screens", "0", "label") == .string("CU34G4Z"))
        #expect(reopened.hardware.calls.isEmpty && reopened.screens.applied.isEmpty)
    }

    @Test("Clearing a nickname by UUID restores the current system name", arguments: ["", " \n\t"])
    func clear(_ blank: String) async {
        let defaults = UserDefaults.pilot()
        let rig = Rig(defaults: defaults)
        #expect(await rig.ask("display", "1", "--name", "My monitor").error == nil)
        let renamedSystem = DisplayInfo(id: 1, name: "New system name", main: true, frame: rig.screens.screens[0].frame,
                                       mode: rig.screens.screens[0].mode, rotation: 0, displayUUID: Self.wideUUID)
        rig.screens.screens[0] = renamedSystem
        let clear = await rig.ask("display", Self.wideUUID, "--name", blank)
        #expect(clear.error == nil)
        #expect(DisplayConnectionVerbTests.path(clear.result, "screens", "0", "label") == .string("New system name"))
        #expect(DisplayConnectionVerbTests.path(clear.result, "screens", "0", "nickname") == nil)
        let reopened = Rig(defaults: defaults)
        #expect(DisplayConnectionVerbTests.path((await reopened.ask("displays")).result, "screens", "0", "label") == .string("CU34G4Z"))
    }

    @Test("Ambiguous names, missing or duplicate UUIDs and mixed hardware flags cannot rename a display")
    func refusedNames() async {
        let rig = Rig(defaults: .pilot())
        #expect(await rig.ask("display", "1", "--name", "Same").error == nil)
        #expect(await rig.ask("display", "2", "--name", "Same").error == nil)
        #expect(await rig.ask("display", "Same", "--name", "Wrong").error?.code == .badValue)
        #expect(await rig.ask("display", "1", "--name", "Wrong", "--connected", "off").error?.code == .unknownFlag)
        #expect(await rig.ask("display", "1", "--name").error?.code == .badRequest)
        #expect(await rig.ask("display", "999", "--name", "Wrong").error?.code == .badValue)
        for ids: [String?] in [[nil, Self.portraitUUID], [Self.wideUUID, Self.wideUUID]] {
            let unnamed = Rig(defaults: .pilot(), uuids: ids)
            #expect(await unnamed.ask("display", "1", "--name", "Wrong").error?.code == .notReady)
            #expect(unnamed.displays.nicknames.nickname(for: Self.wideUUID) == nil)
        }
        #expect(rig.hardware.calls.isEmpty && rig.screens.applied.isEmpty)
    }

    @Test("Unreadable saved nicknames are preserved rather than overwritten")
    func corruptSettings() async {
        let defaults = UserDefaults.pilot()
        defaults.set("unreadable", forKey: "displays.nicknames")
        let rig = Rig(defaults: defaults)
        #expect(await rig.ask("display", "1", "--name", "Wrong").error?.code == .badValue)
        #expect(defaults.string(forKey: "displays.nicknames") == "unreadable")
    }

    @Test("The real pilot executable names and clears a display through an isolated socket")
    func executableBoundary() async throws {
        let rig = Rig(defaults: .pilot())
        let socket = ControlSocket(path: ControlSocketTests.tempPath(), verbs: rig.verbs)
        #expect(socket.start())
        defer { socket.stop() }
        for text in ["Desk \"café\" 🖥️", ""] {
            let run = try await PilotCLITests.pilot(["system", "display", "1", "--name", text], socket: socket.path.path)
            #expect(run.status == 0 && run.err.isEmpty)
            let result = try JSONDecoder().decode(JSONValue.self, from: Data(run.out.utf8))
            #expect(DisplayConnectionVerbTests.path(result, "screens", "0", "label") == .string(text.isEmpty ? "CU34G4Z" : text))
        }
        #expect(rig.hardware.calls.isEmpty && rig.screens.applied.isEmpty)
    }

    @Test("Old recovery checkpoints without a display UUID still decode without changing physical bindings")
    func oldCheckpoints() throws {
        let rig = Rig(defaults: .pilot())
        let original = rig.hardware.screens[0]
        let encoded = try JSONEncoder().encode(original)
        var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "displayUUID")
        let screen = try JSONDecoder().decode(ConnectionScreen.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(screen.displayUUID == nil && screen.binding == original.binding && screen.name == original.name)
    }

    @Test("Native online displays have unique UUIDs; active inventories agree when present, without writes",
          .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func nativeIdentity() async throws {
        let active = CoreGraphicsDisplays().displays()
        let connections = try await NativeDisplayConnections().read(remembered: [])
        #expect(!connections.isEmpty)
        #expect(Set(connections.compactMap(\.displayUUID)).count == connections.count)
        for screen in connections {
            #expect(screen.displayUUID.flatMap(UUID.init(uuidString:)) != nil)
        }
        for screen in active {
            let connection = try #require(connections.first { $0.id == screen.id })
            #expect(connection.displayUUID == screen.displayUUID)
        }
        print("Nickname identity read-only proof: \(connections.count) online displays have unique UUIDs; \(active.count) active adapter comparisons")
    }
}
