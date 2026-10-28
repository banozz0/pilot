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

    @Test("Login items: a launchd plist reads as its label, program and app; the disabled store and System Events' list read back")
    func loginItems() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.example.helper", "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/helper", "--quiet"],
            "AssociatedBundleIdentifiers": ["com.example.app"], "RunAtLoad": true,
        ], format: .xml, options: 0)
        let job = try #require(LoginItems.job(plist, path: "/Users/x/Library/LaunchAgents/com.example.helper.plist", kind: .agent))
        #expect(job.label == "com.example.helper" && job.bundleID == "com.example.app")
        #expect(job.appPath == "/Applications/Example.app")
        #expect(job.canSwitch && !job.isPilot)
        #expect(LoginItems.job(Data("not a plist".utf8), path: "/x.plist", kind: .agent) == nil)
        let daemon = LoginItems.Item(label: "com.example.daemon", kind: .daemon, path: "/Library/LaunchDaemons/com.example.daemon.plist")
        #expect(daemon.canSwitch && daemon.needsAdmin && !job.needsAdmin, "a daemon switches as root (Q412)")
        #expect(!LoginItems.Item(label: "com.apple.mdworker", kind: .sharedAgent, path: "/x.plist").canSwitch, "never macOS's own")
        #expect(!LoginItems.Item(label: "x'; rm -rf ~", kind: .daemon, path: "/x.plist").canSwitch, "a label launchctl cannot take as is")
        var helper = LoginItems.Item(label: "dev.banozz.pilot.helper", kind: .agent, path: "/x.plist")
        helper.mark(pilot: "dev.banozz.pilot", path: "/Applications/Pilot.app")
        #expect(!helper.canSwitch, "Pilot's own never")

        let printed = "disabled services = {\n\t\"com.example.on\" => enabled\n\t\"com.example.helper\" => disabled\n}\n"
        #expect(LoginItems.disabled(printDisabled: printed) == ["com.example.helper"])
        let logins = LoginItems.loginItems("Pilot\t/Applications/Pilot.app\nRectangle\t/Applications/Rectangle.app\n\n")
        #expect(logins.map(\.label) == ["Pilot", "Rectangle"] && logins.allSatisfy { $0.kind == .loginItem && $0.canSwitch })
        let (listed, kept) = LoginItems.withRemoved(logins, removed: ["Rectangle": "/Applications/Rectangle.app", "Stats": "/Applications/Stats.app"])
        #expect(kept == ["Stats": "/Applications/Stats.app"], "a name listed again was put back elsewhere")
        #expect(listed.last.map { $0.label == "Stats" && $0.disabled && $0.canSwitch && $0.appPath == "/Applications/Stats.app" } == true)
        var pilot = logins[0]
        pilot.mark(pilot: "dev.banozz.pilot", path: "/Applications/Pilot.app")
        #expect(pilot.isPilot, "Pilot's Open at Login row, by its path")
        #expect(LoginItems.sorted([daemon, job] + logins).map(\.kind) == [.loginItem, .loginItem, .agent, .daemon])

        let off = LoginItems.steps(job, on: false, uid: 502), on = LoginItems.steps(job, on: true, uid: 502)
        #expect(off.now == ["bootout", "gui/502/com.example.helper"] && off.flag == ["disable", "gui/502/com.example.helper"])
        #expect(on.flag == ["enable", "gui/502/com.example.helper"] && on.now == ["bootstrap", "gui/502", job.path])
        #expect(LoginItems.rootLine(daemon, on: false) == "'/bin/launchctl' 'bootout' 'system/com.example.daemon' >/dev/null 2>&1; s=$?; "
            + "'/bin/launchctl' 'disable' 'system/com.example.daemon' || exit 1; case $s in 0|3|113) ;; *) echo not-stopped;; esac")
        #expect(LoginItems.rootLine(daemon, on: true) == "'/bin/launchctl' 'enable' 'system/com.example.daemon' || exit 1; "
            + "'/bin/launchctl' 'bootstrap' 'system' '/Library/LaunchDaemons/com.example.daemon.plist' >/dev/null 2>&1; exit 0")
        #expect(LoginItems.quoted("it's") == #"'it'\''s'"#)
    }
}
