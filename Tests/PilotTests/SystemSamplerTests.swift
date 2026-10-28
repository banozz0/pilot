import AppKit
import SwiftUI
import Foundation
import PilotCore
import Testing
@testable import Pilot

/// This Mac's one sampler (cards agent-bo-95422788 and agent-bo-95422830): Home and the menu-bar items each hold a
/// watch while they show readings; the sampler reads only while a watch is held, once per tick however many watch, at the
/// shortest interval asked, and stops when the last watch ends. The disk is read on a run's first tick and then every
/// 60 s. Home holds its watch only while the window is on screen (AppWindowTests checks onScreen).
@MainActor
@Suite("System sampler")
struct SystemSamplerTests {
    /// Bumped from the reader, which runs off the main thread.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts = (reads: 0, disk: 0, processes: 0, publicIP: 0)
        func bump(slow: Bool, processes: Bool) -> Int {
            lock.withLock {
                counts.reads += 1
                if slow { counts.disk += 1 }
                if processes { counts.processes += 1 }
                return counts.reads
            }
        }
        func fetchedPublicIP() { lock.withLock { counts.publicIP += 1 } }
        private var netTops = 0
        func ranNetTop() { lock.withLock { netTops += 1 } }
        var netTopRuns: Int { lock.withLock { netTops } }
        var reads: Int { lock.withLock { counts.reads } }
        var diskReads: Int { lock.withLock { counts.disk } }
        var processReads: Int { lock.withLock { counts.processes } }
        var publicIPFetches: Int { lock.withLock { counts.publicIP } }
    }

    nonisolated static func raw(_ t: TimeInterval, slow: Bool, processes: Bool) -> SystemStats.Raw {
        var raw = SystemStats.Raw(time: t, cpu: .init(user: UInt64(t) * 10, system: 0, idle: 100 * UInt64(t), nice: 0),
                        memory: .init(total: 1 << 34, pageSize: 16384, active: 1, inactive: 1, speculative: 0, wired: 1, compressed: 0,
                                      purgeable: 0, external: 0, pressure: .normal, swapUsed: 0, swapTotal: 0),
                        network: .init(received: 0, sent: 0), battery: nil,
                        thermal: .nominal, uptime: t, gpu: 0.25)
        if slow { raw.slow.disk = .init(available: 5, total: 10); raw.slow.localIP = "192.168.1.20" }
        if processes { raw.processes = [.init(pid: 7, cpu: 12, memoryKB: 1 << 20, name: "Finder")] }
        return raw
    }

    /// The slow readings hourly, so a test's ticks hold one disk read however slowly they come: on a loaded Mac three ticks
    /// spanned past the real 60 s and read the disk twice.
    static func sampler(_ counter: Counter, historyLength: Int = 60) -> SystemSampler {
        SystemSampler(historyLength: historyLength, slowInterval: hour, read: { parts in
                          let slow = !parts.isDisjoint(with: .slow), processes = parts.contains(.processes)
                          return Self.raw(Double(counter.bump(slow: slow, processes: processes)), slow: slow, processes: processes)
                      },
                      fetchPublicIP: { counter.fetchedPublicIP(); return "203.0.113.7" },
                      netTop: { counter.ranNetTop(); return nil })
    }

    /// Waits for `condition`, since the suite runs other main-actor tests alongside; false past `seconds`, which only
    /// guards against a hang. Nothing rides on how long a wait takes: each main-actor hop of the sampler's loop queues
    /// behind every main-actor test job ahead of it, so on a loaded Mac ten ticks took over two minutes, as long as the
    /// whole suite; what must come "at once" is checked against a pause of an hour.
    static func wait(seconds: TimeInterval = 600, until condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// The pause a test's "at once" is told apart from: far past any wait.
    static let hour: Duration = .seconds(3600)

    /// The sampler's loop has ended and nothing reads after it: "the reads stop", with no window of time to judge.
    static func stopsReading(_ sampler: SystemSampler, reads: () -> Int) async throws -> Bool {
        guard try await wait(until: { !sampler.running }) else { return false }
        let stopped = reads()
        try await Task.sleep(for: .milliseconds(100))
        return reads() == stopped && !sampler.running
    }

    /// Card agent-bo-95422836: with only the CPU and RAM item, Pilot cost more than Stats, as each tick read all of This
    /// Mac and laid out its rows for a Home that was closed.
    @Test("A menu-bar item's watch reads only its parts and leaves This Mac's rows alone; a rows watch reads them all")
    func readsOnlyWhatShows() async throws {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [SystemStats.Parts] = []
            func add(_ parts: SystemStats.Parts) { lock.withLock { list.append(parts) } }
            var all: [SystemStats.Parts] { lock.withLock { list } }
        }
        let asked = Asked()
        let sampler = SystemSampler(read: { parts in
            asked.add(parts)
            var raw = Self.raw(Double(asked.all.count), slow: !parts.isDisjoint(with: .slow), processes: false)
            raw.parts = parts
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
        let item = Task { await sampler.watch(every: .milliseconds(10), needs: [], stats: [.cpu, .ram]) }
        #expect(try await Self.wait { asked.all.count >= 3 })
        #expect(asked.all.allSatisfy { $0 == [.cpu, .memory] })
        #expect(sampler.rows.isEmpty && sampler.latestValues?.cpu != nil)
        let home = Task { await sampler.watch(every: .milliseconds(10), needs: .rows) }
        #expect(try await Self.wait { !sampler.rows.isEmpty })
        #expect(asked.all.contains { $0.isSuperset(of: SystemStats.Parts.all) })
        home.cancel()
        await home.value
        #expect(try await Self.wait { asked.all.last == [.cpu, .memory] })
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = sampler.rows } onChange: { changed = true }
        let reads = asked.all.count
        #expect(try await Self.wait { asked.all.count >= reads + 5 })
        #expect(!changed)
        item.cancel()
        await item.value
    }

    /// Each Bluetooth read starts system_profiler: a Batteries item placed for good ran it every 60 s with the disk's.
    @Test("Bluetooth is read as it first shows and then every bluetoothInterval, not with each of the other slow readings")
    func bluetoothSlower() async throws {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [SystemStats.Parts] = []
            func add(_ parts: SystemStats.Parts) { lock.withLock { list.append(parts) } }
            func count(_ part: SystemStats.Parts) -> Int { lock.withLock { list.count { $0.contains(part) } } }
            var first: SystemStats.Parts? { lock.withLock { list.first } }
            var reads: Int { lock.withLock { list.count } }
        }
        let asked = Asked()
        let sampler = SystemSampler(slowInterval: .zero, bluetoothInterval: Self.hour, read: { parts in
            asked.add(parts)
            var raw = Self.raw(Double(asked.reads), slow: !parts.isDisjoint(with: .slow), processes: false)
            raw.parts = parts
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
        let home = Task { await sampler.watch(every: .milliseconds(10), needs: .rows) }
        #expect(try await Self.wait { asked.count(.diskSpace) >= 3 })
        #expect(asked.first?.contains(.bluetooth) == true)
        #expect(asked.count(.bluetooth) == 1)
        home.cancel()
        await home.value
    }

    @Test("Low-battery alerts read the HID batteries with the slow readings, never system_profiler, and hand each reading on")
    func lowBatteryHID() async throws {
        nonisolated(unsafe) var asked: [SystemStats.Parts] = []
        let sampler = SystemSampler(slowInterval: .zero, read: { parts in
            asked.append(parts)
            var raw = Self.raw(Double(asked.count), slow: false, processes: false)
            raw.parts = parts
            if parts.contains(.bluetoothHID) { raw.slow.bluetooth = [.init(name: "Keychron", level: "19 %")] }
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
        var handed: [[SystemStats.BluetoothDevice]] = []
        sampler.onBluetooth = { handed.append($0) }
        let alerts = Task { await sampler.watch(every: .milliseconds(10), needs: .lowBattery) }
        #expect(try await Self.wait { handed.count >= 2 })
        #expect(asked.contains { $0.contains(.bluetoothHID) } && !asked.contains { $0.contains(.bluetooth) })
        #expect(handed.first == [.init(name: "Keychron", level: "19 %")])
        alerts.cancel()
        await alerts.value
    }

    @Test("The Disk item reads the disk's counters for its graph; a watch that adds what it shows wakes the sampler at once")
    func diskGraphAndWake() async throws {
        let sampler = SystemSampler(read: { parts in
            var raw = Self.raw(Date().timeIntervalSinceReferenceDate, slow: false, processes: false)
            raw.parts = parts
            raw.diskIO = parts.contains(.diskIO) ? .init(read: UInt64(Date().timeIntervalSinceReferenceDate * 1000), written: 0) : nil
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
        let disk = Task { await sampler.watch(every: .milliseconds(10), needs: [], stats: [.disk]) }
        #expect(try await Self.wait { sampler.latestValues?.diskRead != nil })
        disk.cancel()
        await disk.value
        // An hourly menu-bar watch, then Home at the same hour: Home's rows come at once, not after the pause.
        let counter = Counter()
        let paced = Self.sampler(counter)
        let item = Task { await paced.watch(every: Self.hour, needs: [], stats: [.cpu]) }
        // The first reading is set in the same main-actor turn the loop starts its hour's pause in.
        #expect(try await Self.wait { paced.latestValues != nil })
        let home = Task { await paced.watch(every: Self.hour, needs: .rows) }
        #expect(try await Self.wait { !paced.rows.isEmpty })
        home.cancel(); item.cancel()
        await home.value; await item.value
    }

    /// Card agent-bo-95422838: with Home open Pilot cost more than Stats; ps and every process's counters each tick were
    /// most of the reading.
    @Test("The process list is read once per process interval, not every tick, and the busiest lists stay between reads")
    func processesLessOften() async throws {
        let counter = Counter()
        // Hourly, so ten ticks hold one listing however slowly the ticks come; one a tick would make ten.
        let sampler = SystemSampler(processInterval: Self.hour, relistAfter: Self.hour, read: { parts in
            let slow = !parts.isDisjoint(with: .slow), processes = parts.contains(.processes)
            return Self.raw(Double(counter.bump(slow: slow, processes: processes)), slow: slow, processes: processes)
        }, fetchPublicIP: { nil }, netTop: { nil })
        let home = Task { await sampler.watch(every: .milliseconds(10), needs: [.rows, .processes]) }
        #expect(try await Self.wait { counter.reads >= 10 })
        #expect(counter.processReads == 1)
        // Between process reads the lists keep what the last one found, tick after tick.
        var emptied = false
        let reads = counter.reads
        #expect(try await Self.wait { emptied = emptied || sampler.busiestCPU.isEmpty; return counter.reads >= reads + 5 })
        #expect(!emptied)
        home.cancel()
        await home.value
    }

    @Test("Home reads the sensors once per sensor interval and keeps them between; a Temperature item reads them every tick")
    func sensorsLessOften() async throws {
        final class Asked: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [SystemStats.Parts] = []
            func add(_ parts: SystemStats.Parts) { lock.withLock { list.append(parts) } }
            var all: [SystemStats.Parts] { lock.withLock { list } }
        }
        let asked = Asked()
        // Hourly, so ten ticks hold one sensor read however slowly the ticks come; one a tick would make ten.
        let sampler = SystemSampler(sensorInterval: Self.hour, read: { parts in
            asked.add(parts)
            var raw = Self.raw(Double(asked.all.count), slow: false, processes: false)
            raw.parts = parts
            raw.sensors = parts.contains(.sensors) ? .init(temperatures: ["Tp01": 50], fans: [], power: 9) : nil
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil })
        let home = Task { await sampler.watch(every: .milliseconds(10), needs: .rows) }
        #expect(try await Self.wait { asked.all.count >= 10 })
        let withSensors = asked.all.filter { $0.contains(.sensors) }.count
        #expect(withSensors == 1)
        #expect(sampler.rows.contains { $0.name == "CPU heat" })   // kept between reads
        let item = Task { await sampler.watch(every: .milliseconds(10), needs: [], stats: [.sensors]) }
        let from = asked.all.count
        #expect(try await Self.wait { asked.all.count >= from + 5 })
        #expect(asked.all.dropFirst(from + 1).allSatisfy { $0.contains(.sensors) })
        home.cancel(); item.cancel()
        await home.value; await item.value
    }

    @Test("The second process read comes soon after the first, so the busiest by disk shows quickly, then the interval holds; Combined processes re-reads at once")
    func secondListingSoon() async throws {
        let counter = Counter()
        let sampler = SystemSampler(processInterval: Self.hour, relistAfter: .milliseconds(100), read: { parts in
            let slow = !parts.isDisjoint(with: .slow), processes = parts.contains(.processes)
            return Self.raw(Double(counter.bump(slow: slow, processes: processes)), slow: slow, processes: processes)
        }, fetchPublicIP: { nil }, netTop: { nil })
        let home = Task { await sampler.watch(every: .milliseconds(10), needs: [.rows, .processes]) }
        #expect(try await Self.wait { counter.processReads >= 2 })
        let reads = counter.reads
        #expect(try await Self.wait { counter.reads >= reads + 5 })
        #expect(counter.processReads == 2)
        sampler.combineProcesses.toggle()
        #expect(try await Self.wait { counter.processReads == 3 })
        home.cancel()
        await home.value
    }

    @Test("Nothing is read while no one watches")
    func idleWithoutWatch() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter)
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.reads == 0)
        #expect(sampler.rows.isEmpty)
    }

    @Test("A watch reads once a tick, the disk only on the first tick and kept after; ending the watch stops the reads")
    func samplesWhileWatched() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter)
        let watch = Task { await sampler.watch(every: .milliseconds(10), needs: .rows) }
        #expect(try await Self.wait { counter.reads >= 3 })
        #expect(counter.diskReads == 1)
        #expect(sampler.rows.first { $0.name == "Disk" }?.value != "—")
        #expect(sampler.rows.first { $0.name == "CPU" }?.value != "—")
        #expect(sampler.rows.first { $0.name == "GPU" }?.value == "25 %")

        watch.cancel()
        await watch.value
        #expect(try await Self.stopsReading(sampler) { counter.reads })
    }

    @Test("Two watches share one read a tick at the shorter interval")
    func watchesShare() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter)
        let slow = Task { await sampler.watch(every: Self.hour) }
        #expect(try await Self.wait { counter.reads >= 1 })
        // At an hour, five more reads would take five hours; the 30 ms watch brings them now.
        let fast = Task { await sampler.watch(every: .milliseconds(30)) }
        let joined = counter.reads
        #expect(try await Self.wait { counter.reads >= joined + 5 })
        // One loop, not one per watch: the loop waits 30 ms after each read, so it reads at most once per 30 ms of the
        // window however long the window really ran (plus the read under way); two loops would read about twice that.
        let clock = ContinuousClock(), began = clock.now, before = counter.reads
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.reads - before <= Int(began.duration(to: clock.now) / .milliseconds(30)) + 2)
        fast.cancel(); slow.cancel()
        await fast.value; await slow.value
    }

    @Test("Reading goes on while a longer watch outlasts a shorter one, and stops with the last watch")
    func lastWatchEnds() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter)
        let long = Task { await sampler.watch(every: .milliseconds(50)) }
        let short = Task { await sampler.watch(every: .milliseconds(10)) }
        #expect(try await Self.wait { counter.reads >= 3 })
        short.cancel()
        await short.value
        let alone = counter.reads
        #expect(try await Self.wait { counter.reads >= alone + 2 })
        long.cancel()
        await long.value
        #expect(try await Self.stopsReading(sampler) { counter.reads })
    }

    @Test("A watch asking for a shorter interval cuts the loop's current wait short, so a menu-bar item never waits out Home's")
    func shorterWatchWakes() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter)
        let slow = Task { await sampler.watch(every: Self.hour) }
        #expect(try await Self.wait { counter.reads >= 1 })
        let fast = Task { await sampler.watch(every: .milliseconds(20)) }
        // Without the cut, the next read waits out the hour's pause.
        #expect(try await Self.wait { counter.reads >= 5 })
        fast.cancel(); slow.cancel()
        await fast.value; await slow.value
    }

    @Test("The history for mini graphs keeps the newest readings, capped at its length")
    func historyCaps() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter, historyLength: 5)
        let watch = Task { await sampler.watch(every: .milliseconds(5)) }
        #expect(try await Self.wait { counter.reads >= 9 })
        watch.cancel()
        await watch.value
        #expect(sampler.history.count == 5)
        #expect(sampler.history.allSatisfy { $0.gpu == 0.25 && $0.cpu != nil })
    }

    @Test("Processes are listed only while a watch asks for them, and the list goes when that watch ends")
    func processesOnDemand() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter)
        let plain = Task { await sampler.watch(every: .milliseconds(10)) }
        #expect(try await Self.wait { counter.reads >= 3 })
        #expect(counter.processReads == 0 && sampler.busiestCPU.isEmpty)
        let listing = Task { await sampler.watch(every: .milliseconds(10), needs: .processes) }
        #expect(try await Self.wait { !sampler.busiestCPU.isEmpty })
        #expect(sampler.busiestCPU.first?.name == "Finder" && sampler.busiestMemory.first?.value == "1.0 GB")
        listing.cancel()
        await listing.value
        #expect(try await Self.wait { sampler.busiestCPU.isEmpty })
        let after = counter.processReads
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.processReads == after)
        plain.cancel()
        await plain.value
    }

    @Test("Stats' apps group a listing as Activity does: an app's children under it, summed, the process count from the listing")
    func appsGroupedAsActivity() async throws {
        let sampler = SystemSampler(processInterval: .milliseconds(10), read: { parts in
            var raw = Self.raw(1, slow: false, processes: false)
            guard parts.contains(.processes) else { return raw }
            raw.tree = [Activity.Process(pid: 100, ppid: 1, uid: 501, cpu: 20, memory: 1 << 30, path: "/Applications/Ghostex.app/Contents/MacOS/Ghostex"),
                        Activity.Process(pid: 101, ppid: 100, uid: 501, cpu: 40, memory: 2 << 30, path: "/opt/homebrew/bin/claude"),
                        Activity.Process(pid: 102, ppid: 101, uid: 501, cpu: 30, memory: 1 << 30, path: "/opt/homebrew/bin/node"),
                        Activity.Process(pid: 200, ppid: 1, uid: 0, cpu: 3, memory: 1 << 20, path: "/usr/libexec/mds")]
            raw.processes = raw.tree?.map(KillProcess.Row.init)
            return raw
        }, fetchPublicIP: { nil }, netTop: { nil },
           runningApps: { [Activity.App(pid: 100, name: "Ghostex", bundlePath: "/Applications/Ghostex.app")] })
        let listing = Task { await sampler.watch(every: .milliseconds(10), needs: .processes) }
        #expect(try await Self.wait { !sampler.appsByCPU.isEmpty })
        #expect(sampler.appsByCPU.map(\.name) == ["Ghostex", "mds"])
        #expect(sampler.appsByCPU.first?.cpu == 90 && sampler.appsByCPU.first?.memory == 4 << 30 && sampler.appsByCPU.first?.processCount == 3)
        #expect(sampler.processCount == 4)
        // The busiest lists still rank each process on its own.
        #expect(sampler.busiestCPU.first?.name == "claude")
        listing.cancel()
        await listing.value
    }

    @Test("Busiest by disk from each process's counters between reads, by network from nettop snapshots; nettop runs only while the busiest are listed")
    func busiestDiskAndNetwork() async throws {
        final class Ticks: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0, nettops = 0
            func next() -> UInt64 { lock.withLock { n += 1; return UInt64(n) } }
            func nettop() -> Int { lock.withLock { nettops += 1; return nettops } }
            var nettopRuns: Int { lock.withLock { nettops } }
        }
        let ticks = Ticks()
        let sampler = SystemSampler(processInterval: .milliseconds(10), netTopPause: .zero, read: { parts in
            let processes = parts.contains(.processes)
            let n = ticks.next()
            var raw = Self.raw(Double(n), slow: false, processes: processes)
            if processes {
                raw.processes = [.init(pid: 7, cpu: 1, memoryKB: 1, name: "mds"), .init(pid: 8, cpu: 1, memoryKB: 1, name: "Finder")]
                raw.processIO = [7: .init(read: n * 1_000_000, written: 0), 8: .init(read: 5, written: 5)]
            }
            return raw
        }, fetchPublicIP: { nil }, netTop: {
            let n = ticks.nettop()
            try? await Task.sleep(for: .milliseconds(20))
            return "apsd.582,\(n * 50_000),0,\nlaunchd.1,0,0,"
        })
        let plain = Task { await sampler.watch(every: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ticks.nettopRuns == 0)
        let listing = Task { await sampler.watch(every: .milliseconds(10), needs: .processes) }
        #expect(try await Self.wait { sampler.busiestDisk.first?.name == "mds" })
        #expect(sampler.busiestDisk.count == 1)          // Finder did nothing
        #expect(try await Self.wait { sampler.busiestNetwork.first?.name == "apsd" })
        listing.cancel()
        await listing.value
        #expect(try await Self.wait { sampler.busiestDisk.isEmpty && sampler.busiestNetwork.isEmpty })
        let runs = ticks.nettopRuns
        try await Task.sleep(for: .milliseconds(150))
        #expect(ticks.nettopRuns <= runs + 1)            // the one under way may finish; none starts after
        plain.cancel()
        await plain.value
    }

    @Test("The public IP is never fetched while its setting is off; on, it is fetched once and shown; off again, it goes")
    func publicIPOnlyWhenOn() async throws {
        let counter = Counter()
        let sampler = Self.sampler(counter)
        let off = Task { await sampler.watch(every: .milliseconds(10), needs: .rows) }
        #expect(try await Self.wait { counter.reads >= 5 })
        #expect(counter.publicIPFetches == 0)
        #expect(sampler.rows.first { $0.name == "IP" }?.value == "192.168.1.20")
        let on = Task { await sampler.watch(every: .milliseconds(10), needs: .publicIP) }
        #expect(try await Self.wait { sampler.rows.first { $0.name == "IP" }?.value == "192.168.1.20 · public 203.0.113.7" })
        let reads = counter.reads
        #expect(try await Self.wait { counter.reads >= reads + 5 })
        #expect(counter.publicIPFetches == 1)
        on.cancel()
        await on.value
        #expect(try await Self.wait { sampler.rows.first { $0.name == "IP" }?.value == "192.168.1.20" })
        off.cancel()
        await off.value
    }

    /// What the menu-bar items cost: the real sampler at their 1 s for 30 s, this process's CPU time over the wall time,
    /// beside the Stats app's own %CPU when it runs. Opt-in; reads only. The items' drawing is not in it (lane 1 measures
    /// Pilot.app itself).
    @Test("The sampler's cost at the menu bar's 1 s", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveCost() async throws {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let sampler = SystemSampler()
        let watch = Task { await sampler.watch(every: .seconds(1), needs: [], stats: [.cpu, .ram]) }
        try await Task.sleep(for: .seconds(3))   // past the first read's SMC key walk
        let start = cpuSeconds(), began = Date()
        try await Task.sleep(for: .seconds(30))
        let share = (cpuSeconds() - start) / Date().timeIntervalSince(began) * 100
        watch.cancel()
        await watch.value
        print("live: sampler at 1 s, CPU and RAM item, uses \(String(format: "%.2f", share)) % CPU")
        #expect(share < 2)
    }

    /// What every menu-bar item on costs, drawing included: the real sampler at 1 s, and every second all eight readings
    /// drawn as text and the five graphs drawn as graphs into a bitmap, more drawing than the menu bar does. Opt-in; reads
    /// only; nothing shows on screen.
    @Test("Every menu-bar item on, drawn each second", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveCostWithDrawing() async throws {
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        let sampler = SystemSampler()
        var watch = Task { await sampler.watch(every: .seconds(1), needs: [], stats: Set(MenuBarStats.Stat.allCases)) }
        var graphs = BarSettings.defaults
        let readings = BarKind.allCases.filter { $0.stat != nil }
        readings.forEach { graphs.set($0, style: .graph) }
        let every = readings.map(BarSettings.defaults.entry) + readings.map(graphs.entry)
        let svens = [BarSettings.defaults.entry(.cpu), BarSettings.defaults.entry(.memory)]
        let draw = { (entries: [BarEntry]) in
            var i = BarInputs()
            i.latest = sampler.latest; i.values = sampler.latestValues; i.history = sampler.history
            return BarPartsView(items: entries.compactMap { BarParts.parts($0, i) })
        }
        try await Task.sleep(for: .seconds(3))   // past the first read's SMC key walk
        // One view per run, its readings swapped in each second, as a status item's view is.
        for (name, items) in [("every item on", every), ("Sven's CPU and RAM", svens)] {
            if name != "every item on" {
                watch.cancel()
                await watch.value
                watch = Task { await sampler.watch(every: .seconds(1), needs: [], stats: [.cpu, .ram]) }
                try await Task.sleep(for: .seconds(2))
            }
            let view = NSHostingView(rootView: draw(items))
            let start = cpuSeconds(), began = Date()
            for _ in 0..<20 {
                view.rootView = draw(items)
                view.frame.size = view.fittingSize
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try await Task.sleep(for: .seconds(1))
            }
            let share = (cpuSeconds() - start) / Date().timeIntervalSince(began) * 100
            print("live: \(name), drawn each second: \(String(format: "%.2f", share)) % CPU")
            #expect(share < 3)
        }
        watch.cancel()
        await watch.value
    }

    /// The busiest by disk and by network from the real readers (ps, proc_pid_rusage, nettop). Opt-in; reads only.
    @Test("The real busiest lists", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveBusiest() async throws {
        let sampler = SystemSampler()
        let watch = Task { await sampler.watch(every: .seconds(1), needs: .processes) }
        #expect(try await Self.wait(seconds: 20) { !sampler.busiestNetwork.isEmpty && !sampler.busiestDisk.isEmpty })
        for row in sampler.busiestDisk { print("live: disk \(row.name) = \(row.value)") }
        for row in sampler.busiestNetwork { print("live: network \(row.name) = \(row.value)") }
        watch.cancel()
        await watch.value
    }

    /// The real readers on this Mac, read-only: opt-in like every live test.
    @Test("The real readers return this Mac's numbers", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"))
    func liveReaders() async throws {
        let a = await SystemReader.read(SystemStats.Parts.all.union(.processes))
        try await Task.sleep(for: .seconds(1))
        let b = await SystemReader.read(SystemStats.Parts.all.union(.processes))
        #expect(a.memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(b.memory.used > 0 && b.memory.used <= b.memory.total)
        #expect(b.memory.app > 0 && b.memory.app < b.memory.used)
        #expect(b.cpu.idle + b.cpu.user > a.cpu.idle + a.cpu.user)
        #expect((b.slow.disk?.total ?? 0) > 0)
        #expect(b.network.received >= a.network.received && b.network.received > 0)
        #expect(b.gpu != nil)
        #expect(b.cores.count == ProcessInfo.processInfo.processorCount && b.efficiencyCores > 0)
        #expect(b.sensors.map { SystemStats.sensorRows($0).count >= 3 } == true)
        #expect(b.sensors?.temperatures.keys.contains { $0.hasPrefix("Ts") } == true, "the SoC row reads the chip's Ts sensors")
        #expect((b.processes?.count ?? 0) > 10 && b.diskIO != nil && b.slow.localIP != nil)
        for row in SystemStats.rows(previous: a, now: b) { print("live: \(row.name) = \(row.value)") }
        let clock = ContinuousClock()
        print("live: one SMC read takes \(clock.measure { for _ in 0..<20 { _ = SMC.shared.sensors() } } / 20)")
        for row in SystemStats.busiest(b.processes ?? [], by: .cpu) + SystemStats.busiest(b.processes ?? [], by: .memory) {
            print("live: \(row.name) = \(row.value)")
        }
    }
}
