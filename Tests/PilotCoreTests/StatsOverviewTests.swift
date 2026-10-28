import Foundation
import Testing
@testable import PilotCore

/// Stats' Overview (Sven's card layout, 2026-10-12): the rings' slices and Worth a look, from the process listings Stats
/// already reads and the Mac's own readings.
@Suite("Stats overview")
struct StatsOverviewTests {
    static let gib: UInt64 = 1 << 30
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    static func app(_ name: String, cpu: Double = 0, memory: UInt64 = 0) -> Activity.Row {
        Activity.Row(kind: .app, pid: 1, name: name, cpu: cpu, memory: memory, rights: .quitAndForce)
    }

    static func mac(memory: UInt64 = 16 * gib) -> StatsOverview.Mac {
        var mac = StatsOverview.Mac()
        mac.physicalMemory = memory
        return mac
    }

    @Test("A ring keeps the first five with an amount, Other for the rest of the total, never past the total")
    func slices() {
        let items = (1...7).map { StatsOverview.Slice(name: "app\($0)", amount: Double(8 - $0)) }   // 7, 6, ... 1
        let s = StatsOverview.slices(items, total: 40)
        #expect(s.map(\.name) == ["app1", "app2", "app3", "app4", "app5", "Other"])
        #expect(s.last == .init(name: "Other", amount: 15))
        // The listing counts more than the Mac's total (ps' resident sizes overlap): cut at the total, no Other.
        let over = StatsOverview.slices([.init(name: "a", amount: 30), .init(name: "b", amount: 30)], total: 40)
        #expect(over == [.init(name: "a", amount: 30), .init(name: "b", amount: 10)])
        #expect(StatsOverview.slices([.init(name: "idle", amount: 0)], total: 0).isEmpty)
    }

    @Test("Today's average leaves unread minutes out; a per-minute rate totals a minute each")
    func today() {
        #expect(abs((StatsOverview.average([0.2, nil, 0.4]) ?? 0) - 0.3) < 1e-9)
        #expect(StatsOverview.average([nil]) == nil)
        #expect(StatsOverview.total(perMinute: [1000, nil, 500]) == 90_000)
    }

    @Test("An app busy on average for a minute is worth a look; a spike, or under a minute, is not")
    func busy() {
        var watch = StatsOverview.Watch()
        // Seven listings 10 s apart: 60 s of an app at 80 % of a core.
        for i in 0..<6 {
            watch.record([Self.app("Chrome", cpu: 80)], mac: Self.mac(), at: Self.start.addingTimeInterval(Double(i) * 10))
            #expect(watch.findings.isEmpty, "under a minute is not yet worth a look")
        }
        watch.record([Self.app("Chrome", cpu: 72)], mac: Self.mac(), at: Self.start.addingTimeInterval(60))
        let busy = watch.findings.first { $0.tag == .cpu }
        #expect(busy?.title == "Chrome is keeping the CPU busy" && busy?.value == "Now 72.0 %" && busy?.app == "Chrome")
        #expect(busy?.line == "79 % of a core on average for the last minute.")
        #expect(busy?.since == Self.start.addingTimeInterval(60))

        // A spike: one listing at 300 % among idle ones averages under the line.
        var spike = StatsOverview.Watch()
        for i in 0...6 {
            spike.record([Self.app("Xcode", cpu: i == 6 ? 300 : 5)], mac: Self.mac(), at: Self.start.addingTimeInterval(Double(i) * 10))
        }
        #expect(spike.findings.isEmpty)
    }

    @Test("Memory grown by half a GB and a quarter over two minutes is worth a look; a fifth of the Mac's memory too")
    func memory() throws {
        var watch = StatsOverview.Watch()
        watch.record([Self.app("Notes", memory: Self.gib)], mac: Self.mac(), at: Self.start)
        watch.record([Self.app("Notes", memory: Self.gib * 2)], mac: Self.mac(), at: Self.start.addingTimeInterval(60))
        #expect(watch.findings.isEmpty, "not two minutes yet")
        watch.record([Self.app("Notes", memory: Self.gib * 2)], mac: Self.mac(), at: Self.start.addingTimeInterval(180))
        let grown = try #require(watch.findings.first)
        #expect(grown.id == "grow.app.1" && grown.line == "Up 1.0 GB in the last 3 minutes, now 2.0 GB." && grown.value == "Now 2.0 GB")

        // 4 GB of 16, flat: holds a lot (a fifth is 3.2 GB); growing would win over it.
        var big = StatsOverview.Watch()
        big.record([Self.app("Zen", memory: 4 * Self.gib)], mac: Self.mac(), at: Self.start)
        #expect(big.findings.map(\.id) == ["big.app.1"])
        #expect(big.findings.first?.line == "25 % of this Mac's 16.0 GB.")
    }

    @Test("A finding keeps the time it was first seen; gone and back, it counts afresh; past ten minutes is forgotten")
    func since() {
        var watch = StatsOverview.Watch()
        let big = [Self.app("Zen", memory: 4 * Self.gib)]
        watch.record(big, mac: Self.mac(), at: Self.start)
        watch.record(big, mac: Self.mac(), at: Self.start.addingTimeInterval(120))
        #expect(watch.findings.first?.since == Self.start)
        watch.record([], mac: Self.mac(), at: Self.start.addingTimeInterval(130))
        #expect(watch.findings.isEmpty)
        watch.record(big, mac: Self.mac(), at: Self.start.addingTimeInterval(140))
        #expect(watch.findings.first?.since == Self.start.addingTimeInterval(140))
        // Busy for a minute, then idle for ten: the busy minutes leave the window.
        var busy = StatsOverview.Watch()
        for i in 0...6 { busy.record([Self.app("A", cpu: 90)], mac: Self.mac(), at: Self.start.addingTimeInterval(Double(i) * 10)) }
        #expect(!busy.findings.isEmpty)
        busy.record([Self.app("A", cpu: 1)], mac: Self.mac(), at: Self.start.addingTimeInterval(700))
        #expect(busy.findings.isEmpty)
    }

    @Test("An app's children count under it as Activity groups them: one row, its CPU and memory summed, and Worth a look names it")
    func grouped() throws {
        // Ghostex (pid 100) runs claude, node and python3, none busy alone; a second claude in the background is its own row.
        let tree = [Activity.Process(pid: 100, ppid: 1, uid: 501, cpu: 20, memory: Self.gib, path: "/Applications/Ghostex.app/Contents/MacOS/Ghostex"),
                    Activity.Process(pid: 101, ppid: 100, uid: 501, cpu: 40, memory: 2 * Self.gib, path: "/opt/homebrew/bin/claude"),
                    Activity.Process(pid: 102, ppid: 101, uid: 501, cpu: 30, memory: Self.gib, path: "/opt/homebrew/bin/node"),
                    Activity.Process(pid: 103, ppid: 100, uid: 501, cpu: 25, memory: Self.gib, path: "/usr/bin/python3"),
                    Activity.Process(pid: 200, ppid: 1, uid: 501, cpu: 45, memory: Self.gib / 2, path: "/opt/homebrew/bin/claude")]
        let apps = [Activity.App(pid: 100, name: "Ghostex", bundlePath: "/Applications/Ghostex.app")]
        let snapshot = Activity.snapshot(tree, apps: apps, me: 501, pilot: 999)
        let ghostex = try #require(snapshot.apps.first)
        #expect(snapshot.apps.count == 1 && ghostex.name == "Ghostex" && ghostex.processCount == 4)
        #expect(ghostex.cpu == 115 && ghostex.memory == 5 * Self.gib)
        #expect(snapshot.background.map(\.name) == ["claude"])

        var watch = StatsOverview.Watch()
        for i in 0...6 {
            watch.record(Array(Activity.sorted(snapshot.all, by: .cpu).prefix(6)), mac: Self.mac(), at: Self.start.addingTimeInterval(Double(i) * 10))
        }
        let busy = watch.findings.filter { $0.tag == .cpu }
        #expect(busy.map(\.title) == ["Ghostex is keeping the CPU busy"], "the background claude at 45 % stays under the line")
        #expect(busy.first?.line == "115 % of a core on average for the last minute, across 4 processes.")
        #expect(busy.first?.app == "Ghostex" && busy.first?.id == "cpu.app.100")
        #expect(!watch.findings.contains { $0.id == "big.app.100" }, "named as busy, it is not named again for its memory")
        // 5 GB of 16 is a fifth or more: on its first listing it holds a lot of memory, counted with its children.
        var first = StatsOverview.Watch()
        first.record(snapshot.all, mac: Self.mac(), at: Self.start)
        #expect(first.findings.first { $0.id == "big.app.100" }?.line == "31 % of this Mac's 16.0 GB, across 4 processes.")
    }

    @Test("Two background processes of one name stay two")
    func sameName() {
        var watch = StatsOverview.Watch()
        let python = { (pid: Int32) in Activity.Row(kind: .process, pid: pid, name: "python3", cpu: 0, memory: 4 * Self.gib, rights: .quitAndForce) }
        watch.record([python(7), python(8)], mac: Self.mac(), at: Self.start)
        #expect(watch.findings.map(\.id).sorted() == ["big.pid.7", "big.pid.8"])
    }

    @Test("The Mac's own: pressure, a nearly full disk, heat and a low battery off the charger")
    func mac() {
        var mac = Self.mac()
        #expect(StatsOverview.Watch.macFindings(mac).isEmpty)
        mac.pressure = .warning
        mac.swapUsed = 3 * Self.gib / 2
        mac.disk = .init(available: 7_400_000_000, total: 245_000_000_000)
        mac.heat = 97
        mac.battery = .init(percent: 12, charging: false, pluggedIn: false, minutesLeft: 25)
        let found = StatsOverview.Watch.macFindings(mac)
        #expect(found.map(\.tag) == [.heat, .memory, .disk, .battery])
        #expect(found[1].value == "Swap 1.5 GB")
        #expect(found[2].line == "7.4 GB free of 245 GB; a macOS update wants about 20 GB.")
        #expect(found[3].line == "12 %, about 25 min left.")
        mac.battery?.pluggedIn = true
        #expect(!StatsOverview.Watch.macFindings(mac).contains { $0.tag == .battery }, "plugged in, a low battery is charging")
    }

    @Test("How long ago a finding was first seen")
    func ago() {
        #expect(StatsOverview.ago(Self.start, now: Self.start.addingTimeInterval(30)) == "just now")
        #expect(StatsOverview.ago(Self.start, now: Self.start.addingTimeInterval(7 * 60 + 5)) == "7 min ago")
        #expect(StatsOverview.ago(Self.start, now: Self.start.addingTimeInterval(2 * 3600)) == "2 h ago")
    }
}
