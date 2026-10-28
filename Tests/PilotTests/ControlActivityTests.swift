import Darwin
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// `pilot processes|quit|stats` (CLI W9), asked through the registry the socket answers from, over a reader, a quit and
/// a sampler of the tests' own: nothing on this Mac is listed, signalled or read, and no Allow prompt shows.
@MainActor
@Suite("Control activity")
struct ControlActivityTests {
    /// What the fakes hand out and saw, across the readers' threads.
    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static let me = getuid()
    /// An app with a helper, one of your background processes, macOS's own, and root's.
    static let processes = [
        Activity.Process(pid: 501, ppid: 1, uid: me, cpu: 12, memory: 400 << 20, path: "/Applications/Test.app/Contents/MacOS/Test"),
        Activity.Process(pid: 502, ppid: 501, uid: me, cpu: 30, memory: 100 << 20, path: "/Applications/Test.app/Contents/Frameworks/Test Helper"),
        Activity.Process(pid: 600, ppid: 1, uid: me, cpu: 80, memory: 50 << 20, path: "/Users/test/bin/busyloop"),
        Activity.Process(pid: 700, ppid: 1, uid: me, cpu: 1, memory: 9 << 20, path: "/usr/libexec/sharingd"),
        Activity.Process(pid: 800, ppid: 1, uid: 0, cpu: 2, memory: 30 << 20, path: "/usr/sbin/systemstats"),
    ]

    @MainActor final class Rig {
        let verbs = ControlVerbs()
        let activity = ControlActivity()
        let stats = ControlStats()
        let listed = Box(ControlActivityTests.processes)
        var asked: [String] = []
        var quits: [(String, Bool)] = []
        var allow = false
        let reads = Box(0)

        init(publicIP: Bool = false) {
            let listed = listed, reads = reads
            activity.monitor = ActivityMonitor(readProcesses: { listed.value },
                                               runningApps: { [.init(pid: 501, name: "Test", bundlePath: "/Applications/Test.app")] })
            activity.gate = ControlGate { [unowned self] ask, _ in
                asked.append(ask.text)
                return allow
            }
            activity.quit = { [unowned self] row, force in
                quits.append((row.id, force))
                listed.value.removeAll { $0.pid == row.pid }
                return true
            }
            activity.settle = .milliseconds(600)
            stats.sampler = SystemSampler(read: { parts in
                reads.value += 1
                return ControlActivityTests.raw(parts, tick: reads.value)
            }, fetchPublicIP: { "203.0.113.7" }, netTop: { nil })
            stats.publicIPOn = { publicIP }
            stats.screens = { 2 }
            stats.every = .milliseconds(30)
            // A ceiling, not a wait: the sampler reads at utility priority, which a busy full suite starves for seconds.
            stats.wait = .seconds(60)
            verbs.registerActivity(activity, stats: stats)
        }

        func ask(_ verb: String, _ args: String...) async -> ControlAnswer {
            await verbs.answer(ControlRequest(verb: verb, args: args), peer: nil)
        }
    }

    /// One reading: the CPU busier each tick, 8 of 16 GB used, 15 GB free on the disk, two processes for the busiest.
    nonisolated static func raw(_ parts: SystemStats.Parts, tick: Int) -> SystemStats.Raw {
        let n = UInt64(tick)
        let page: UInt64 = 16_384, gb: UInt64 = 1 << 30
        var raw = SystemStats.Raw(time: ProcessInfo.processInfo.systemUptime,
                                  cpu: .init(user: 300 * n, system: 100 * n, idle: 600 * n, nice: 0),
                                  memory: .init(total: 16 * gb, pageSize: page, active: 6 * gb / page, inactive: 0, speculative: 0,
                                                wired: 2 * gb / page, compressed: 0, purgeable: 0, external: 0, pressure: .normal,
                                                swapUsed: 0, swapTotal: 0),
                                  network: .init(received: 1000 * n, sent: 100 * n), battery: nil, thermal: .nominal, uptime: 7200, gpu: 0.25)
        raw.parts = parts
        raw.load = [1.5, 1.2, 0.9]
        raw.slow.disk = .init(available: 15_000_000_000, total: 500_000_000_000)
        raw.slow.machine = .init(chip: "Apple M4", model: "Mac16,10", macOS: "26.5")
        if parts.contains(.processes) {
            raw.processes = [.init(pid: 600, cpu: 80, memoryKB: 51_200, name: "busyloop"), .init(pid: 501, cpu: 12, memoryKB: 409_600, name: "Test")]
        }
        return raw
    }

    static func object(_ value: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = value { o } else { [:] } }
    static func array(_ value: JSONValue?) -> [JSONValue] { if case .array(let a)? = value { a } else { [] } }

    @Test("processes lists apps with their helpers, then the background, each with its rights, sorted and searched")
    func processes() async {
        let rig = Rig()
        let answer = await rig.ask("processes")
        let result = Self.object(answer.result)
        let apps = Self.array(result["apps"]).map { Self.object($0) }
        let background = Self.array(result["background"]).map { Self.object($0) }
        #expect(apps.map { $0["id"] } == [.string("app.501")], "\(answer)")
        #expect(apps.first?["cpu"] == .number(42), "the helper's CPU summed in")
        #expect(apps.first?["processes"] == .number(2))
        #expect(Self.array(apps.first?["helpers"]).map { Self.object($0)["id"] } == [.string("pid.502")])
        #expect(background.map { $0["id"] } == [.string("pid.600"), .string("pid.800"), .string("pid.700")], "busiest CPU first")
        #expect(background.first?["heat"] == .string("hog"))
        #expect(background[1]["locked"] == .string("System") && background[1]["quit"] == .bool(false))
        #expect(background[2]["owner"] == .string("macOS") && background[2]["force"] == .bool(false) && background[2]["quit"] == .bool(true))

        let byMemory = Self.array(Self.object(await rig.ask("processes", "--sort", "memory", "--limit", "1").result)["background"])
        #expect(byMemory.map { Self.object($0)["id"] } == [.string("pid.600")])
        let searched = Self.object(await rig.ask("processes", "--query", "helper").result)
        #expect(Self.array(Self.object(Self.array(searched["apps"]).first)["helpers"]).count == 1, "an app keeps the helpers that match")
        #expect(Self.array(searched["background"]).isEmpty)

        #expect(await rig.ask("processes", "--sort", "name").error?.code == .badValue)
        #expect(await rig.ask("processes", "--limit", "0").error?.code == .outOfRange)
        #expect(await rig.ask("processes", "--json").error?.code == .unknownFlag, "--json goes before the verb")
    }

    @Test("quit asks Allow with the page's confirm; a deny quits nothing")
    func quitDenied() async {
        let rig = Rig()
        let answer = await rig.ask("quit", "501")
        #expect(answer.error?.code == .denied)
        #expect(rig.asked == ["Quit Test: pid 501. It may ask to save first."])
        #expect(rig.quits.isEmpty)
        _ = await rig.ask("quit", "pid.600", "--force")
        #expect(rig.asked.last == "Force quit busyloop: pid 600. Anything unsaved in it is lost.")
        #expect(rig.quits.isEmpty)
    }

    @Test("quit after Allow quits the row and answers once it has gone")
    func quitAllowed() async {
        let rig = Rig()
        rig.allow = true
        let answer = Self.object(await rig.ask("quit", "600", "--force").result)
        #expect(rig.quits.map(\.0) == ["pid.600"] && rig.quits.map(\.1) == [true])
        #expect(answer["sent"] == .bool(true) && answer["running"] == .bool(false) && answer["name"] == .string("busyloop"))
        #expect(Self.array(Self.object(await rig.ask("processes").result)["background"]).count == 2, "the row is gone on the next read")
    }

    @Test("quit refuses, unasked, what the page shows no button for, and a pid that runs nothing")
    func quitRefused() async {
        let rig = Rig()
        rig.allow = true
        #expect(await rig.ask("quit", "800").error?.code == .badValue, "root's")
        #expect(await rig.ask("quit", "700", "--force").error?.code == .badValue, "macOS's own is never forced")
        #expect(await rig.ask("quit", "4242").error?.code == .badValue)
        #expect(await rig.ask("quit").error?.code == .badRequest)
        #expect(rig.asked.isEmpty && rig.quits.isEmpty)
    }

    @Test("stats reads one beat: every card with rates, the busiest and the machine line")
    func stats() async {
        let rig = Rig()
        let answer = await rig.ask("stats")
        let result = Self.object(answer.result)
        #expect(Self.object(result["cpu"])["percent"] == .number(40), "\(answer)")
        #expect(Self.object(result["cpu"])["apps"] == .number(30))
        #expect(Self.object(result["cpu"])["load"] == .array([.number(1.5), .number(1.2), .number(0.9)]))
        #expect(Self.object(result["memory"])["percent"] == .number(50))
        #expect(Self.object(result["storage"])["low"] == .bool(true), "15 GB free is under the page's 20")
        #expect(Self.object(result["graphics"])["percent"] == .number(25) && Self.object(result["graphics"])["screens"] == .number(2))
        #expect(Self.object(result["machine"])["chip"] == .string("Apple M4"))
        #expect(Self.object(result["network"])["publicIP"] == nil, "the switch is off: nothing fetched")
        #expect(Self.object(result["batteries"])["battery"] == .null)
        let busiest = Self.array(Self.object(result["busiest"])["cpu"]).map { Self.object($0) }
        #expect(busiest.first?["name"] == .string("busyloop") && busiest.first?["pid"] == .number(600))
    }

    @Test("stats --card narrows, --range adds that card's points, and a bad word is refused")
    func statsCardAndRange() async {
        let rig = Rig()
        let answer = Self.object(await rig.ask("stats", "--card", "cpu", "--range", "2m").result)
        #expect(Set(answer.keys) == ["cpu", "history"])
        let history = Self.object(answer["history"])
        #expect(history["range"] == .string("twoMinutes") && history["every"] == .number(2))
        let points = Self.array(history["points"]).map { Self.object($0) }
        #expect(!points.isEmpty && points.allSatisfy { Set($0.keys) == ["cpu"] })
        #expect(Self.array(Self.object(Self.object(await rig.ask("stats", "--range", "hour").result)["history"])["points"]).isEmpty,
                "no minute history in the test sampler")

        #expect(await rig.ask("stats", "--card", "disk").error?.code == .badValue)
        #expect(await rig.ask("stats", "--range", "week").error?.code == .badValue)
        #expect(await rig.ask("stats", "--card", "busiest", "--range", "today").error?.code == .badValue, "no chart to draw")
        #expect(await rig.ask("stats", "--sort", "cpu").error?.code == .unknownFlag)
    }

    @Test("stats while the screen is locked says so at once, as the sampler reads nothing")
    func statsLocked() async {
        let rig = Rig()
        rig.stats.sampler.pause()
        let answer = await rig.ask("stats")
        #expect(answer.error?.code == .notReady && answer.error?.message.contains("locked") == true, "\(answer)")
    }

    @Test("stats with Public IP on fetches the address for the beat, as the page does")
    func statsPublicIP() async {
        let rig = Rig(publicIP: true)
        let answer = Self.object(await rig.ask("stats", "--card", "network").result)
        #expect(Self.object(answer["network"])["publicIP"] == .string("203.0.113.7"))
    }
}
