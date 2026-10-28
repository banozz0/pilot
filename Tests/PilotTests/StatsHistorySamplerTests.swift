import Foundation
import PilotCore
import Testing
@testable import Pilot

/// Stats' 1 hour and Today (card agent-bo-95422992): the sampler keeps a minute history while a history watch is held,
/// reads what the charts draw, never while the screen is locked (card agent-bo-95422839), and never lets those minute-apart
/// readings stretch the 2-minute graphs. A fake reader and a fake clock: nothing is read from this Mac.
@MainActor
@Suite("Stats history sampler")
struct StatsHistorySamplerTests {
    /// Every read a minute after the last, by its reading time and the clock both.
    final class Minutes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0, asked: [SystemStats.Parts] = []
        var reads: Int { lock.withLock { count } }
        var parts: [SystemStats.Parts] { lock.withLock { asked } }
        func read(_ parts: SystemStats.Parts) -> SystemStats.Raw {
            let n = lock.withLock { count += 1; asked.append(parts); return count }
            return SystemSamplerTests.raw(Double(n) * 60, slow: false, processes: false)
        }
        var now: Date { Date(timeIntervalSince1970: 1_791_400_000 + Double(reads) * 60) }
    }

    static func sampler(_ minutes: Minutes) -> SystemSampler {
        SystemSampler(read: { minutes.read($0) }, fetchPublicIP: { nil }, netTop: { nil }, clock: { minutes.now }, historyEvery: .zero)
    }

    @Test("A history watch reads the charts' readings and keeps one point a minute; the 2-minute graph holds only the last 2 minutes")
    func minutePoints() async throws {
        let minutes = Minutes(), sampler = Self.sampler(minutes)
        let watch = Task { await sampler.watch(every: .milliseconds(10), needs: .history) }
        #expect(try await SystemSamplerTests.wait { sampler.minutes.points(.hour, now: minutes.now).count >= 5 })
        watch.cancel()
        await watch.value
        #expect(minutes.parts.first?.isSuperset(of: SystemSampler.historyParts) == true)
        #expect(!(minutes.parts.first?.contains(.processes) ?? true), "the history never lists the processes")
        let points = sampler.minutes.points(.hour, now: minutes.now)
        #expect(Set(points.map(\.time)).count == points.count, "one point a minute")
        #expect(points.allSatisfy { $0.cpu != nil && $0.ram != nil })
        #expect(sampler.history.count <= 2, "readings a minute apart: only those inside 2 minutes stay in the 2-minute graph")
    }

    @Test("Beside a CPU item ticking every 2 s, the history reads its parts once a minute, not on every tick")
    func historyOnItsOwnCadence() async throws {
        let minutes = Minutes()
        let sampler = SystemSampler(read: { minutes.read($0) }, fetchPublicIP: { nil }, netTop: { nil }, clock: { minutes.now },
                                    historyEvery: SystemSamplerTests.hour)
        let history = Task { await sampler.watch(every: SystemSamplerTests.hour, needs: .history) }
        let item = Task { await sampler.watch(every: .milliseconds(10), stats: [.cpu]) }
        #expect(try await SystemSamplerTests.wait { minutes.reads >= 6 })
        item.cancel(); history.cancel()
        await item.value; await history.value
        let full = minutes.parts.filter { $0.isSuperset(of: SystemSampler.historyParts) }
        #expect(full.count == 1, "the first tick reads the history's parts; the CPU item's ticks read only the CPU")
        #expect(minutes.parts.dropFirst().allSatisfy { !$0.contains(.network) && !$0.contains(.diskIO) })
    }

    @Test("Locked, the history watch reads nothing and keeps no point; unlocked, it reads again")
    func lockedReadsNothing() async throws {
        let minutes = Minutes(), sampler = Self.sampler(minutes)
        let watch = Task { await sampler.watch(every: .milliseconds(10), needs: .history) }
        #expect(try await SystemSamplerTests.wait { minutes.reads >= 2 })
        sampler.pause()
        try await Task.sleep(for: .milliseconds(100))   // the pass under way when the lock came ends
        let reads = minutes.reads, kept = sampler.minutes.points(.today, now: minutes.now)
        try await Task.sleep(for: .milliseconds(300))
        #expect(minutes.reads == reads)
        #expect(sampler.minutes.points(.today, now: minutes.now) == kept)
        sampler.resume()
        #expect(try await SystemSamplerTests.wait { minutes.reads > reads })
        watch.cancel()
        await watch.value
    }
}
