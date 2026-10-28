import AppKit
@testable import PilotTiler
import Testing

/// A refresh asks every running process its activation policy, a synchronous LaunchServices call each, on the main
/// thread; MacApp keeps each app's answer for policyTTL (sampled 2026-10-09: about 150 calls per app switch).
@MainActor
@Suite
struct ActivationPolicyCacheTests {
    /// Stand-ins for two running apps, so the cache's real entries are left alone.
    let app = NSObject(), other = NSObject()
    var key: ObjectIdentifier { ObjectIdentifier(app) }
    var otherKey: ObjectIdentifier { ObjectIdentifier(other) }

    func forget() { MacApp.prunePolicies(keeping: Set(MacApp.policies.keys).subtracting([key, otherKey])) }

    @Test func aSecondAskWithinTheTTLIsAnsweredFromTheCache() {
        defer { forget() }
        var asked = 0
        let ask = { () -> NSApplication.ActivationPolicy in asked += 1; return .regular }
        let start = ContinuousClock.now
        #expect(MacApp.activationPolicy(of: app, now: start, ask: ask) == .regular)
        #expect(MacApp.activationPolicy(of: app, now: start + .seconds(4), ask: ask) == .regular)
        #expect(asked == 1)
        _ = MacApp.activationPolicy(of: app, now: start + MacApp.policyTTL + .seconds(1), ask: ask)
        #expect(asked == 2)
    }

    @Test func theFrontmostAppIsAskedAfreshEachRefresh() {
        defer { forget() }
        let now = ContinuousClock.now
        _ = MacApp.activationPolicy(of: app, now: now) { .accessory }
        MacApp.prunePolicies(keeping: Set(MacApp.policies.keys), refreshing: key)
        #expect(MacApp.activationPolicy(of: app, now: now) { .regular } == .regular)
    }

    /// Live bug (Sven 2026-10-12, Pilot's window left out of the layout after launch): one app is several objects (the
    /// running list's, frontmostApplication's, NSRunningApplication.current), each with its own kept answer. Pilot turned
    /// regular as its window opened; the list's object still read accessory for up to policyTTL and the registered
    /// `.current` read regular, so neither loop refreshed Pilot and its window was never registered.
    @Test func anAppWhoseObjectsDisagreeOnItsPolicyIsRefreshedOnce() {
        defer { forget() }
        let now = ContinuousClock.now
        _ = MacApp.activationPolicy(of: app, now: now) { .accessory } // kept from a refresh before the window opened
        let listed = (object: app, pid: pid_t(42)), registered = (object: other, pid: pid_t(42))
        let refreshed = MacApp.appsToRefresh(running: [listed], registered: [registered], pid: { $0.pid }) {
            MacApp.activationPolicy(of: $0.object, now: now + .seconds(1)) { .regular } == .regular
        }
        #expect(refreshed.map(\.pid) == [42])
    }

    @Test func aRegularAppIsRefreshedOnceAndAnUnlistedUtilityAppToo() {
        let refreshed = MacApp.appsToRefresh(running: [1, 2], registered: [1, 3], pid: { $0 }) { $0 != 3 }
        #expect(refreshed == [1, 2, 3])
    }

    @Test func anAppNoLongerRunningIsForgotten() {
        defer { forget() }
        let now = ContinuousClock.now
        _ = MacApp.activationPolicy(of: app, now: now) { .regular }
        _ = MacApp.activationPolicy(of: other, now: now) { .regular }
        MacApp.prunePolicies(keeping: Set(MacApp.policies.keys).subtracting([key]))
        #expect(MacApp.policies[key] == nil)
        #expect(MacApp.policies[otherKey] != nil)
    }
}
