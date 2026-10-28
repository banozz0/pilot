import Darwin
import Foundation
import Testing
@testable import PilotCore

/// Activity (task N3): ps read into apps with their helpers and background processes, sorted, searched, and what each
/// row may be quit with.
@Suite("Activity")
struct ActivityTests {
    /// Shaped on `ps -Ao pid=,ppid=,uid=,pcpu=,rss=,comm=` on Sven's Mac, 2026-10-09 (uid 502 is Sven, 0 root).
    static let ps = """
            1     0     0   0.3  20416 /sbin/launchd
          130     1     0  42.0  15856 /System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds
          420     1   502   0.0  20480 /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow
          600     1   502   1.5  30000 /usr/libexec/photoanalysisd
        34511     1   502   2.0 435664 /Applications/Zen.app/Contents/MacOS/zen
         2204 34511   502  55.0 316320 /Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container
         9546 34511   502   0.5 316912 /Applications/Zen.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container
         7000     1   502   0.1  10000 /Applications/Zen.app/Contents/XPCServices/Updater.xpc/Contents/MacOS/Updater
        69659     1   502   5.8  68768 /Applications/Ghostty.app/Contents/MacOS/ghostty
        69660 69659   502   0.0   2000 /usr/bin/login
        69661 69660   502   0.0   3000 -zsh
        69662 69661   502 180.0 900000 /Users/ada/.cargo/bin/cargo
        47642     1   502   3.7 115680 /Users/ada/code/pilot/build/Pilot.app/Contents/MacOS/Pilot
        47650 47642   502   0.1 167024 /Users/ada/code/pilot/build/Pilot.app/Contents/Helpers/pilot-files
         8000     1   502   0.0   5000 /opt/homebrew/bin/node
         1398     1   502   0.2 150288 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
        not a row
        """

    static let apps = [
        Activity.App(pid: 34511, name: "Zen", bundlePath: "/Applications/Zen.app"),
        Activity.App(pid: 69659, name: "Ghostty", bundlePath: "/Applications/Ghostty.app"),
        Activity.App(pid: 1398, name: "Finder", bundlePath: "/System/Library/CoreServices/Finder.app"),
        // Gone between NSWorkspace and ps: left out.
        Activity.App(pid: 99999, name: "Gone", bundlePath: "/Applications/Gone.app"),
    ]

    static func snapshot(pilotIsApp: Bool = false) -> Activity.Snapshot {
        let apps = Self.apps + (pilotIsApp ? [Activity.App(pid: 47642, name: "Pilot", bundlePath: "/Users/ada/code/pilot/build/Pilot.app")] : [])
        return Activity.snapshot(Activity.parse(ps), apps: apps, me: 502, pilot: 47642)
    }

    @Test("ps's lines read whole, a path with spaces kept, memory in bytes; a line that does not read is left out")
    func parse() {
        let rows = Activity.parse(Self.ps + "\n  12   1 502 0.0 100 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        #expect(rows.count == 17)
        #expect(rows[4] == Activity.Process(pid: 34511, ppid: 1, uid: 502, cpu: 2.0, memory: 435_664 * 1024, path: "/Applications/Zen.app/Contents/MacOS/zen"))
        #expect(rows.last?.name == "Google Chrome")
        #expect(rows[10].name == "-zsh")
    }

    @Test("An app's helpers roll up under it: inside its bundle (a nested .app, an XPC service started by launchd) or started by it (a terminal's shell and its build)")
    func groups() throws {
        let s = Self.snapshot()
        #expect(Set(s.apps.map(\.name)) == ["Zen", "Ghostty", "Finder"])
        let zen = try #require(s.apps.first { $0.name == "Zen" })
        #expect(Set(zen.children.map(\.pid)) == [2204, 9546, 7000])
        #expect(zen.processCount == 4)
        #expect(zen.cpu == 2.0 + 55.0 + 0.5 + 0.1)
        #expect(zen.memory == (435_664 + 316_320 + 316_912 + 10_000) * 1024)
        #expect(zen.bundlePath == "/Applications/Zen.app" && zen.id == "app.34511")
        let ghostty = try #require(s.apps.first { $0.name == "Ghostty" })
        #expect(Set(ghostty.children.map(\.name)) == ["login", "-zsh", "cargo"])
        #expect(Set(s.background.map(\.pid)) == [1, 130, 420, 600, 47642, 47650, 8000])
        #expect(s.background.allSatisfy { $0.children.isEmpty && $0.kind == .process })
        #expect(s.row("pid.2204")?.name == "plugin-container" && s.row("app.1398")?.name == "Finder" && s.row("pid.1") != nil)
        #expect(s.row("app.2204") == nil)
    }

    @Test("Rights: yours quit and force; macOS's own of yours quit only; root, other users, loginwindow and Pilot with what it started never")
    func rights() throws {
        let s = Self.snapshot()
        func rights(_ id: String) throws -> Activity.Rights { try #require(s.row(id)).rights }
        #expect(try rights("app.34511") == .quitAndForce)
        #expect(try rights("pid.2204") == .quitAndForce)
        #expect(try rights("pid.8000") == .quitAndForce)
        #expect(try rights("pid.69662") == .quitAndForce)
        #expect(try rights("pid.600") == .quitOnly, "photoanalysisd is under /usr: asked, never forced")
        #expect(try rights("pid.69660") == .quitOnly)
        #expect(try rights("app.1398") == .quitAndForce, "Finder is an app, quit and forced as any app")
        #expect(try rights("pid.1") == .none(.system))
        #expect(try rights("pid.130") == .none(.system), "root's mds")
        #expect(try rights("pid.420") == .none(.macOS))
        #expect(try rights("pid.47642") == .none(.pilot))
        #expect(try rights("pid.47650") == .none(.pilot), "Pilot's file index, started by Pilot, while Pilot has no Dock icon")
        let pilot = try #require(Self.snapshot(pilotIsApp: true).row("app.47642"))
        #expect(pilot.rights == .none(.pilot) && pilot.children.map(\.rights) == [.none(.pilot)])
        #expect(Activity.Rights.quitOnly.canQuit && !Activity.Rights.quitOnly.canForce)
        #expect(!Activity.Rights.none(.system).canQuit && !Activity.Rights.none(.system).canForce)
    }

    @Test("Sorted heaviest first by CPU or by memory, helpers too; ties by the other reading, then the name")
    func sorting() throws {
        let s = Activity.sorted(Self.snapshot(), by: .cpu)
        #expect(s.apps.map(\.name) == ["Ghostty", "Zen", "Finder"])
        #expect(s.apps[0].children.map(\.name) == ["cargo", "-zsh", "login"])
        #expect(s.background.prefix(2).map(\.pid) == [130, 47642])
        let m = Activity.sorted(Self.snapshot(), by: .memory)
        #expect(m.apps.map(\.name) == ["Zen", "Ghostty", "Finder"])
        #expect(m.apps[0].children.map(\.pid) == [9546, 2204, 7000])
        let ties = [Activity.Row(kind: .process, pid: 2, name: "b", cpu: 1, memory: 5, rights: .quitAndForce),
                    Activity.Row(kind: .process, pid: 3, name: "a", cpu: 1, memory: 5, rights: .quitAndForce),
                    Activity.Row(kind: .process, pid: 4, name: "c", cpu: 1, memory: 9, rights: .quitAndForce)]
        #expect(Activity.sorted(ties, by: .cpu).map(\.name) == ["c", "a", "b"])
    }

    @Test("Search keeps rows whose name holds the words, any case, or whose pid is them; an app keeps only its matching helpers unless its own name matches")
    func search() throws {
        let s = Self.snapshot()
        #expect(Activity.filtered(s, query: "  ") == s)
        let cargo = Activity.filtered(s, query: "CARGO")
        #expect(cargo.apps.map(\.name) == ["Ghostty"] && cargo.apps[0].children.map(\.name) == ["cargo"] && cargo.background.isEmpty)
        let zen = Activity.filtered(s, query: "ze")
        #expect(zen.apps.map(\.name) == ["Zen"] && zen.apps[0].children.count == 3)
        #expect(Activity.filtered(s, query: "8000").background.map(\.name) == ["node"])
        #expect(Activity.filtered(s, query: "nothing like it") == .empty)
    }

    @Test("A hog takes most of a core or a fifth of the memory; busy, a fifth of a core or a twentieth")
    func heat() {
        let ram: UInt64 = 20 << 30
        #expect(Activity.heat(cpu: 1, memory: 100 << 20, physicalMemory: ram) == .calm)
        #expect(Activity.heat(cpu: 20, memory: 0, physicalMemory: ram) == .busy)
        #expect(Activity.heat(cpu: 0, memory: ram / 20, physicalMemory: ram) == .busy)
        #expect(Activity.heat(cpu: 70, memory: 0, physicalMemory: ram) == .hog)
        #expect(Activity.heat(cpu: 0, memory: ram / 5, physicalMemory: ram) == .hog)
        #expect(Activity.Heat.calm < .busy && Activity.Heat.busy < .hog)
    }

    @Test("Quit: an app through macOS, a process by SIGTERM; forced, an app at once and a process by SIGKILL; none past its rights")
    func quit() throws {
        let s = Self.snapshot()
        let zen = try #require(s.row("app.34511")), helper = try #require(s.row("pid.2204"))
        #expect(Activity.quit(zen, force: false) == .app(pid: 34511, force: false))
        #expect(Activity.quit(zen, force: true) == .app(pid: 34511, force: true))
        #expect(Activity.quit(helper, force: false) == .signal(pid: 2204, SIGTERM))
        #expect(Activity.quit(helper, force: true) == .signal(pid: 2204, SIGKILL))
        let macOS = try #require(s.row("pid.600"))
        #expect(Activity.quit(macOS, force: false) == .signal(pid: 600, SIGTERM))
        #expect(Activity.quit(macOS, force: true) == nil)
        for id in ["pid.1", "pid.130", "pid.420", "pid.47642", "pid.47650"] {
            let row = try #require(s.row(id))
            #expect(Activity.quit(row, force: false) == nil && Activity.quit(row, force: true) == nil, "\(id)")
        }
    }

    @Test("Kill a process lists the apps and your background processes Pilot may quit, busiest CPU first, from the same snapshot")
    func entries() throws {
        let entries = Activity.entries(Self.snapshot())
        #expect(entries.map(\.title) == ["Ghostty", "Zen", "photoanalysisd", "Finder", "node"])
        #expect(entries[0].detail == "185.8 % CPU · 951 MB · 4 processes")
        #expect(entries[0].target == .action("app.69659"))
        #expect(entries[2].detail == "1.5 % CPU · 29 MB")
    }
}
