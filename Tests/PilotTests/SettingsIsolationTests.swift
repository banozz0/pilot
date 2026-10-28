import Foundation
import Testing
@testable import Pilot

/// Card agent-bo-95423301: Pilot's stores saved bar items, default apps, the window's page, the switch and more into
/// UserDefaults.standard, which under swift test is the runner's shared domain, so a run read another run's leftovers. Every
/// store saves through UserDefaults.pilot(): the app's defaults, a fresh throwaway suite per store in a test run.
@MainActor
@Suite("Settings isolation")
struct SettingsIsolationTests {
    static let sources = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/Pilot").standardized

    @Test("No Pilot store saves to UserDefaults.standard: each takes UserDefaults.pilot()")
    func noStoreOnStandard() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let standard = #"UserDefaults\.standard|UserDefaults *= *\.standard"#
        let found = try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .filter { $0.element.range(of: standard, options: .regularExpression) != nil }
                // macOS's own dark-mode setting, which only reads the global domain.
                .filter { !$0.element.contains("\"AppleInterfaceStyle\"") }
                .map { "\(file.lastPathComponent):\($0.offset + 1)" }
        }
        #expect(found == [], "these save to UserDefaults.standard instead of UserDefaults.pilot(): \(found)")
    }

    @Test("Stores built without defaults leave the runner's shared defaults as they were")
    func storesLeaveStandardAlone() {
        let shared = UserDefaults.standard
        let keys = ["appWindow.page", "recommendations.show", "snapshots.reopenApps"]
        let before = keys.map { shared.object(forKey: $0) as? NSObject }
        let model = AppWindowModel()
        model.page = model.page == .binds ? .home : .binds
        let recommendations = Recommendations()
        recommendations.show.toggle()
        let snapshots = WorkspaceSnapshots(observers: EngineObservers())
        snapshots.reopenApps.toggle()
        let after = keys.map { shared.object(forKey: $0) as? NSObject }
        // Only a leak is undone, so a red run doesn't leave the runner's defaults changed either.
        if after != before { for (key, value) in zip(keys, before) { shared.set(value, forKey: key) } }
        #expect(after == before, "a store built in a test saved into the runner's shared defaults")
    }

    @Test("Outside a test run a store saves to the app's defaults; in one, each store gets a fresh throwaway suite")
    func seam() {
        #expect(UserDefaults.pilot(testRun: false) === UserDefaults.standard)
        let one = UserDefaults.pilot(), two = UserDefaults.pilot()
        #expect(one !== UserDefaults.standard && two !== UserDefaults.standard && one !== two)
    }

    /// OW P7: tests read Sven's binds.json and ~/.aerospace.toml, so a pass or fail hung on his own files. The home is
    /// the account's, not NSHomeDirectory(), which a render run moves (CFFIXED_USER_HOME).
    @Test("In a test run Binds and the Pilot block's import resolve inside the run's own folder, never the user's home")
    func filesOutsideHome() throws {
        let home = try #require(getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) })
        let paths = ["Binds.url": Binds.url.path, "Binds.fileURL": Binds().fileURL.path, "PilotBlockStore.path": PilotBlockStore.path]
        #expect(paths.filter { $0.value.hasPrefix(home + "/") }.keys.sorted() == [], "these resolve to Sven's real files")
        // No file there, as on a Mac that never ran AeroSpace: nothing to import, no error on the settings pages.
        #expect(PilotBlockStore(tiler: EngineObservers().tiler).lastError == nil)
    }

    /// The real domain is Sven's: a test never runs as Pilot's bundle, nor opens or edits dev.banozz.pilot by name.
    @Test("No test touches the user's real defaults domain, dev.banozz.pilot")
    func realDomainUntouched() throws {
        #expect(Bundle.main.bundleIdentifier != "dev.banozz.pilot")
        let tests = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SettingsIsolationTests.swift" }
        let real = #"(suiteName|forName): *"dev\.banozz\.pilot"|defaults +(write|delete|import) +dev\.banozz\.pilot\b"#
        let found = try files.filter { try String(contentsOf: $0, encoding: .utf8).range(of: real, options: .regularExpression) != nil }
            .map(\.lastPathComponent)
        #expect(found == [], "these open Sven's dev.banozz.pilot defaults: \(found)")
    }
}
