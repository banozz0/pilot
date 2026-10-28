import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot status` and `pilot link` (CLI W2), asked through the registry the socket answers from, on a test engine with
/// every read of the Mac faked: no folder listing, pgrep, TCC, login item, login shell or sampler runs, and the command
/// link lives in the test's temporary folder.
@MainActor
@Suite("Control status")
struct ControlStatusTests {
    @MainActor final class Rig {
        let engine = Engine()
        let app = ControlStatus()
        let verbs = ControlVerbs()
        let folder = FileManager.default.temporaryDirectory.appending(path: "control-status-\(UUID().uuidString)", directoryHint: .isDirectory)
        var pathReads = 0

        init(updates: [String: Any]? = nil) throws {
            let engine = engine
            engine.gate.seed(trusted: false)
            engine.secureInput.seed(active: false)
            // A bundle's command, so the link has something to point at.
            let command = folder.appending(path: "Pilot.app/Contents/Helpers/pilot")
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: command.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
            app.engine = { engine }
            app.fullDiskAccess = { true }
            app.screenRecording = { _ in nil }
            app.loginItem = { (.requiresApproval, nil) }
            app.link = CommandLineLink(command: command, folder: folder.appending(path: "bin", directoryHint: .isDirectory))
            app.readPath = { [unowned self] _ in pathReads += 1 }
            app.updates = PilotUpdates(info: updates)
            app.folder = folder
            app.systemEvents = { 0 }
            app.clashes = { _ in 2 }
            app.grants = { nil }
            app.sample = { nil }
            app.refreshOccupied = { _ in }
            verbs.registerCore()
            verbs.registerStatus(app)
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer { await ask(verb, args) }

        func ask(_ verb: String, _ args: [String]) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }

        func object(_ verb: String, _ args: String...) async -> [String: JSONValue] {
            let answer = await ask(verb, args)
            guard case .object(let o)? = answer.result else { Issue.record("not an object: \(answer)"); return [:] }
            return o
        }
    }

    static func fields(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = value { o } else { [:] } }

    @Test("a bare status answers every default part from the engine, as Home and General show it")
    func defaults() async throws {
        let rig = try Rig()
        let status = await rig.object("status")
        #expect(Set(status.keys) == Set(ControlStatus.Part.allCases.filter(\.shown).map(\.rawValue)))
        #expect(rig.pathReads == 1, "the PATH is read once while not known")

        guard case .string(let line)? = status["line"] else { Issue.record("no line"); return }
        #expect(line.hasPrefix("Hyper is on. 2 things need you."), "\(line)")
        #expect(Self.fields(status["hyper"]) == ["on": .bool(true), "layerKeys": .array(rig.engine.settings.layerKeys.map { .string($0.rawValue) }),
                                                  "layerKeyLabel": .string(rig.engine.settings.layerKeys.label)])
        #expect(Self.fields(status["permissions"]) == ["accessibility": .bool(false), "fullDiskAccess": .bool(true), "screenRecording": .null])
        let engine = Self.fields(status["engine"])
        #expect(engine["keyEngine"] == .bool(false))
        #expect(engine["secureInput"] == .bool(false))
        #expect(Self.fields(engine["tiler"])["running"] == .bool(false))
        #expect(Self.fields(status["loginItem"])["status"] == .string("requiresApproval"))
        #expect(Self.fields(status["commandLink"])["state"] == .string("notLinked"))
        #expect(Self.fields(status["update"])["state"] == .string("unknown"))
        #expect(status["folder"] == .string(rig.folder.path(percentEncoded: false)))

        // Home's Needs you, each with the command its button runs.
        guard case .array(let problems)? = status["problems"] else { Issue.record("no problems"); return }
        let fixes = problems.map { Self.fields($0)["fix"] }
        #expect(problems.map { Self.fields($0)["kind"] } == [.string("accessibility"), .string("tiler")])
        #expect(fixes == [.string("pilot open permissions"), .string("pilot run engine.restartTiler")])
    }

    @Test("--part reads only the parts named, the Mac's slow ones included")
    func parts() async throws {
        let rig = try Rig()
        rig.engine.observers.tiler.seed(focused: "2", occupied: [OccupiedWorkspace(name: "2", apps: ["Ghostty", "Zen"])])
        let gib: UInt64 = 1 << 30
        var raw = SystemStats.Raw(time: 1, cpu: .init(user: 1, system: 0, idle: 1, nice: 0),
                                  memory: .init(total: 16 * gib, pageSize: 1, active: 6 * gib, inactive: 0, speculative: 0, wired: 0,
                                                compressed: 0, purgeable: 0, external: 0, pressure: .normal, swapUsed: 0, swapTotal: 0),
                                  network: .init(received: 0, sent: 0), battery: nil, thermal: .nominal, uptime: 1, gpu: nil)
        raw.slow.disk = .init(available: 400, total: 1000)
        raw.slow.machine = .init(chip: "Apple M4", model: "Mac16,10", macOS: "26.0")
        rig.app.sample = { (raw, SystemStats.Values(cpu: 0.123, ram: 0.4, gpu: nil, down: nil, up: nil, cores: nil, diskRead: nil, diskWrite: nil, heat: 41.26)) }

        let status = await rig.object("status", "--part", "workspaces,onboarding,mac")
        #expect(Set(status.keys) == ["workspaces", "onboarding", "mac"])
        #expect(Self.fields(status["workspaces"]) == ["focused": .string("2"),
                                                      "occupied": .array([.object(["name": .string("2"), "apps": .array([.string("Ghostty"), .string("Zen")])])])])
        #expect(Self.fields(status["mac"]) == ["chip": .string("Apple M4"), "cpuPercent": .number(12), "memoryUsed": .number(Double(6 * gib)),
                                               "memoryTotal": .number(Double(16 * gib)), "diskAvailable": .number(400), "diskTotal": .number(1000),
                                               "temperature": .number(41.3)])
        guard case .array(let rows)? = status["onboarding"] else { Issue.record("no checklist"); return }
        let done = Dictionary(uniqueKeysWithValues: rows.map { row in
            let f = Self.fields(row)
            return (f["row"].flatMap { if case .string(let s) = $0 { s } else { nil } } ?? "?", f["done"])
        })
        #expect(done == ["accessibility": .bool(false), "systemEvents": .bool(true), "fullDiskAccess": .bool(true), "conflicts": .bool(false),
                         "microphone": .bool(false), "screenRecording": .bool(false), "inputMonitoring": .bool(false),
                         "notifications": .bool(false), "bluetooth": .bool(false), "location": .bool(false), "calendars": .bool(false)])
    }

    @Test("an unknown part or flag, a check on a bare binary and a stopped engine are refused with their codes")
    func refusals() async throws {
        let rig = try Rig()
        #expect(await rig.ask("status", "--part", "nope").error?.code == .badValue)
        #expect(await rig.ask("status", "--part", ",").error?.code == .badRequest)
        #expect(await rig.ask("status", "--verbose").error?.code == .unknownFlag)
        #expect(await rig.ask("status", "--check").error?.code == .badValue, "a bare binary names no commit")
        #expect(await rig.ask("link", "--force").error?.code == .unknownFlag)
        rig.app.engine = { nil }
        #expect(await rig.ask("status").error?.code == .notReady)
    }

    @Test("a built bundle answers its commit and checkout; --part reads that part alone")
    func update() async throws {
        let rig = try Rig(updates: ["PilotCommit": "0123456789abcdef", "PilotSource": "/nonexistent/pilot"])
        let status = await rig.object("status", "--part", "folder")
        #expect(Set(status.keys) == ["folder"])
        let update = Self.fields(await rig.object("status", "--part", "update")["update"])
        #expect(update["commit"] == .string("0123456789abcdef"))
        #expect(update["canCheck"] == .bool(true))
        #expect(update["label"] == .string("Not checked yet"))
    }

    @Test("link makes ~/.local/bin/pilot point at the bundle's command, as General's button does, and answers it linked")
    func link() async throws {
        let rig = try Rig()
        let answer = await rig.object("link")
        #expect(Self.fields(answer["commandLink"])["state"] == .string("linked"))
        let made = try FileManager.default.destinationOfSymbolicLink(atPath: rig.app.link.link.path(percentEncoded: false))
        #expect(made == rig.app.link.command.path(percentEncoded: false))
    }

    @Test("help and schema name every part; Home's and General's buttons are actions")
    func surface() async throws {
        let rig = try Rig()
        guard case .string(let help)? = await rig.ask("help", "status", "mac").result else { Issue.record("no help"); return }
        #expect(help.hasPrefix("pilot status --part mac:"))
        let schema = Self.fields(await rig.ask("schema", "--verb", "status").result)
        guard case .array(let parts)? = Self.fields(schema["schema"])["parts"] else { Issue.record("no parts"); return }
        #expect(parts.count == ControlStatus.Part.allCases.count)
        for id in ["engine.restartTiler", "engine.grantAccessibility", "system.openFullDiskAccess", "engine.tilingOn", "engine.tilingOff", "engine.support"] {
            #expect(rig.engine.registry.actions[id] != nil, "\(id) is registered")
        }
    }
}
