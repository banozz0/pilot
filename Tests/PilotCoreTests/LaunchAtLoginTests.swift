import Foundation
import Testing
@testable import PilotCore

/// Card agent-bo-95422770: Pilot launches at login from a setting (on by default), as ClipBook did before it goes.
@Suite("Launch at login")
struct LaunchAtLoginTests {
    @Test("The setting registers Pilot when it is not a login item and unregisters it when switched off; otherwise nothing")
    func step() {
        #expect(LaunchAtLogin.step(wanted: true, status: .notRegistered) == .register)
        #expect(LaunchAtLogin.step(wanted: true, status: .notFound) == .register)
        #expect(LaunchAtLogin.step(wanted: true, status: .enabled) == nil)
        #expect(LaunchAtLogin.step(wanted: true, status: .requiresApproval) == nil, "registered, waiting for Sven in System Settings")
        #expect(LaunchAtLogin.step(wanted: false, status: .enabled) == .unregister)
        #expect(LaunchAtLogin.step(wanted: false, status: .requiresApproval) == .unregister)
        #expect(LaunchAtLogin.step(wanted: false, status: .notRegistered) == nil)
    }

    @Test("Only a release Pilot.app installed in an Applications folder owns the login item: never a bare binary, a worktree build, a debug build or a moved home")
    func owns() {
        let app = "/Applications/Pilot.app", bare = "/Users/x/code/pilot-worktrees/3/.build/out/Products/Debug/Pilot"
        #expect(LaunchAtLogin.owns(bundlePath: app, debugBuild: false, environment: [:], testRun: false), "the installed app")
        #expect(LaunchAtLogin.owns(bundlePath: "/Users/x/Applications/Pilot.app", debugBuild: false, environment: [:], home: "/Users/x",
                                   testRun: false), "a test build in ~/Applications")
        #expect(!LaunchAtLogin.owns(bundlePath: "/Users/x/code/pilot-worktrees/2/build/Pilot.app", debugBuild: false, environment: [:],
                                    home: "/Users/x", testRun: false), "a worktree's release build, as Scripts/run.sh opens it")
        #expect(!LaunchAtLogin.owns(bundlePath: "/Applications/Utilities/Pilot.app", debugBuild: false, environment: [:], testRun: false),
                "only the Applications folder itself")
        #expect(!LaunchAtLogin.owns(bundlePath: bare, debugBuild: true, environment: [:], testRun: false), "the bare debug binary of 2026-11-16")
        #expect(!LaunchAtLogin.owns(bundlePath: bare, debugBuild: false, environment: [:], testRun: false), "a bare release binary")
        #expect(!LaunchAtLogin.owns(bundlePath: app, debugBuild: true, environment: [:], testRun: false), "a debug Pilot.app")
        #expect(!LaunchAtLogin.owns(bundlePath: app, debugBuild: false, environment: ["CFFIXED_USER_HOME": "/tmp/sandbox"], testRun: false),
                "a sandboxed home, where the setting reads its default, on")
        #expect(!LaunchAtLogin.owns(bundlePath: app, debugBuild: false, environment: [:]), "a test run, by default")
    }
}
